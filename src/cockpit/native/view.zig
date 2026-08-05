const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../../terminal/grid.zig");
const provider_contract = @import("provider_contract");
const support = @import("../phux_support.zig");
const local_terminal = @import("../../providers/local/provider.zig");
const model_module = @import("../model.zig");
const topology = @import("../topology.zig");
const layout = @import("../layout.zig");
const app_types = @import("../app_types.zig");
const pointer_input = @import("../pointer_input.zig");
const projection = @import("workspace_projection.zig");
const scene_module = @import("scene.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Model = model_module.Model;
const Pane = local_terminal.Pane;
const LocalTerminalId = support.LocalTerminalId;
const Phase = support.Phase;
const TerminalRef = support.TerminalRef;
const Viewport = support.Viewport;
const TabPlacement = topology.TabPlacement;
const TerminalApp = app_types.TerminalApp;
const Msg = app_types.Msg;
const max_terminals = local_terminal.max_terminals;
const max_tabs = topology.max_tabs;
const first_terminal_raw = local_terminal.first_terminal_raw;
const providerKind = support.providerKind;
const header_height = projection.header_height;
const side_rail_width = projection.side_rail_width;
const side_rail_gap = projection.side_rail_gap;
const side_tab_height = projection.side_tab_height;
const split_divider_width = projection.split_divider_width;
const split_pane_min_width = projection.split_pane_min_width;
const split_pane_min_height = projection.split_pane_min_height;
const webkit_parking_extent = projection.webkit_parking_extent;
const webview_label = scene_module.webview_label;
const webview_anchor = scene_module.webview_anchor;
const chrome_command_envelope = projection.chrome_command_envelope;
const grid_inset = projection.grid_inset;
const cockpitTokens = projection.cockpitTokens;
const chromeRevealed = projection.chromeRevealed;
const workspaceChrome = projection.workspaceChrome;
const resolvePanes = projection.resolvePanes;
const terminalNeedsAttention = projection.terminalNeedsAttention;
const paneLifecycleFailed = projection.paneLifecycleFailed;
const paneHasConfirmedLoss = projection.paneHasConfirmedLoss;
const selectedTerminalCanClose = projection.selectedTerminalCanClose;
const paneReportsMouse = pointer_input.paneReportsMouse;
const validScale = pointer_input.validScale;
const selection_autoscroll_timer_id = app_types.selection_autoscroll_timer_id;
const TerminalUi = TerminalApp.Ui;

/// The strip shows at most this many tabs plus the Web trigger. The tab
/// ceiling is `max_tabs`; the strip is a fixed-arity element, so the visible
/// count is bounded here and the tail is blank.
const visible_tab_slots: usize = 8;

/// Retained ids for the app's own chrome grounds. Disjoint from the grid
/// painter's namespace (`render.paneIdBase` starts at 0x7e21), so damage
/// tracking treats them as their own stable commands.
pub const window_ground_command_id: u64 = 0x0c01;
pub const header_ground_command_id: u64 = 0x0c02;
pub const header_rule_command_id: u64 = 0x0c03;

/// Phux has one visual register regardless of the system appearance: deep
/// graphite surfaces, porcelain text, and lime reserved for focus/action.
fn terminalNumber(id: LocalTerminalId) u64 {
    return @intFromEnum(id) - first_terminal_raw + 1;
}

/// The tab label for a terminal. Local terminals are numbered by mint order;
/// a Phux terminal borrows the title its coordinator published.
fn terminalTitle(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    if (provider_contract.localId(id)) |local| {
        return ui.fmt("Terminal {d}", .{terminalNumber(local)});
    }
    const presentation = model.remotePresentation(id) orelse return "Phux";
    return if (presentation.title.len == 0) "Phux" else presentation.title;
}

/// The retained-command id namespace a terminal paints into. Local terminals
/// take their registry slot, which is bounded and collision-free by
/// construction; remote terminals derive a disjoint namespace from their
/// identity hash, with the high bit set so the two spaces cannot overlap.
fn terminalPaintIndex(model: *const Model, terminal_ref: TerminalRef) usize {
    if (provider_contract.isLocal(terminal_ref)) {
        return model.provider.slotIndex(terminal_ref) orelse 0;
    }
    return @intCast(0x0000_8000_0000_0000 | (terminal_ref.hash() & 0x0000_7fff_ffff_ffff));
}

/// A divider drag has to say WHICH branch moved, and the SDK's resize
/// callback carries only the fraction. One handler per node id closes that
/// gap at comptime rather than guessing at dispatch.
fn splitResizeHandler(comptime node: layout.NodeId) TerminalUi.ValueMsgFn {
    return struct {
        fn make(value: f32) Msg {
            return .{ .split_resized = .{ .node = node, .value = value } };
        }
    }.make;
}

const split_resize_handlers: [layout.max_nodes]TerminalUi.ValueMsgFn = blk: {
    var table: [layout.max_nodes]TerminalUi.ValueMsgFn = undefined;
    for (0..layout.max_nodes) |index| table[index] = splitResizeHandler(@intCast(index));
    break :blk table;
};

fn paneLifecycleText(ui: *TerminalUi, pane: *const Pane) []const u8 {
    return switch (pane.phase) {
        .starting => "STARTING",
        .attaching => "ATTACHING",
        .live => "RUNNING",
        .reconnecting => "RECONNECTING",
        .tombstoned => "REMOVED",
        .frozen => "FROZEN",
        .ended => switch (pane.exit_reason) {
            .exited => ui.fmt("EXIT {d}", .{pane.exit_code}),
            .signaled => ui.fmt("SIGNAL {d}", .{pane.exit_signal}),
            .cancelled => "CANCELLED",
            else => "ENDED",
        },
        .failed => switch (pane.exit_reason) {
            .rejected => "SPAWN REJECTED",
            .spawn_failed => "SPAWN FAILED",
            else => "FAILED",
        },
    };
}

fn remoteLifecycleText(phase: Phase) []const u8 {
    return switch (phase) {
        .starting => "STARTING",
        .attaching => "ATTACHING",
        .live => "RUNNING",
        .reconnecting => "RECONNECTING",
        .tombstoned => "REMOVED",
        .frozen => "FROZEN",
        .ended => "ENDED",
        .failed => "FAILED",
    };
}

fn emptyStatusNode(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.stack, .{}, .{});
}

/// The full diagnostic sentence for a local pane. It lives in the
/// accessibility label ONLY: a screen reader keeps everything, the eye keeps
/// nothing. `COPIED nB`, `I/O LOSS`, `INPUT STALLED` and friends used to be
/// painted as product chrome, which made ordinary terminal use look like a
/// telemetry dashboard.
fn paneDiagnostics(ui: *TerminalUi, model: *const Model, pane: *const Pane) []const u8 {
    const paste_failed = model.paste_owner.terminal_ref.eql(pane.id) and model.paste_failed;
    return ui.fmt(
        "{s}, native terminal, {s}; outbound loss {d} bytes; reply loss {d} bytes; input stalled {d} times; native delivery failures {d}; copy {s}; paste {s}; copied {d} bytes",
        .{
            terminalTitle(ui, model, pane.id),
            paneLifecycleText(ui, pane),
            pane.outbound_dropped,
            pane.session.response_bytes_dropped,
            pane.write_refusals,
            pane.native_delivery_failures,
            if (pane.copy_failed) "failed" else "ok",
            if (paste_failed) "failed" else "ok",
            pane.copied_bytes,
        },
    );
}

/// The one piece of pane status that survives as CHROME: a terminal whose
/// process ended abnormally offers Restart. A clean exit closes its pane, so
/// it never reaches here.
fn paneStatus(ui: *TerminalUi, model: *const Model, terminal_ref: TerminalRef) TerminalUi.Node {
    if (providerKind(terminal_ref) == .phux) return emptyStatusNode(ui);
    const pane = model.provider.terminalConst(terminal_ref) orelse return emptyStatusNode(ui);
    if (!paneLifecycleFailed(pane)) return emptyStatusNode(ui);
    return ui.row(.{ .gap = 6, .cross = .center }, .{
        ui.el(.badge, .{
            .variant = .destructive,
            .text = paneLifecycleText(ui, pane),
            .semantics = .{ .label = paneDiagnostics(ui, model, pane) },
        }, .{}),
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .{ .restart = pane.id },
            .semantics = .{ .label = ui.fmt("Restart {s}", .{terminalTitle(ui, model, pane.id)}) },
        }, "Restart"),
    });
}

/// Attention is the one thing a hidden tab is allowed to signal, and it does
/// it with a MARKER, not by mangling the label into `Terminal 1 !`.
fn terminalTabTrigger(ui: *TerminalUi, model: *const Model, tab_index: usize, placement: TabPlacement) TerminalUi.Node {
    const id = model.tabTerminal(tab_index) orelse return ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    const selected = !model.web_selected and model.selected_tab == tab_index;
    const title = terminalTitle(ui, model, id);
    const shortcut = ui.fmt("CMD+{d}", .{tab_index + 1});
    const needs_attention = terminalNeedsAttention(model, id);
    // Labels stay whole. The old compaction turned every tab into `T1`/`PHX`
    // as soon as a fourth surface existed, which is not a tab strip, and the
    // `" !"` suffix put a punctuation mark inside the terminal's name.
    const panes_in_tab = if (model.treeConst(tab_index)) |current| current.paneCount() else 1;

    const kind_label = if (provider_contract.isLocal(id)) "native terminal" else "phux terminal";
    const semantics = if (model.provider.terminalConst(id)) |terminal|
        ui.fmt("{s}, {s}, {d} pane(s); {s}; shortcut {s}{s}", .{
            title,
            kind_label,
            panes_in_tab,
            paneDiagnostics(ui, model, terminal),
            shortcut,
            if (selected) ", selected" else "",
        })
    else
        ui.fmt("{s}, {s}, {s}; shortcut {s}{s}", .{
            title,
            kind_label,
            if (model.remotePresentation(id)) |presentation| remoteLifecycleText(presentation.phase) else "UNAVAILABLE",
            shortcut,
            if (selected) ", selected" else "",
        });

    const trigger_key: canvas.UiKey = .{ .index = terminalPaintIndex(model, id) };
    // A real MARKER — the register's own leading icon slot — not a `" !"`
    // welded onto the end of the terminal's name.
    const marker: []const u8 = if (needs_attention) "circle-dot" else "";
    return if (placement == .top)
        ui.el(.segmented_control, .{
            .global_key = trigger_key,
            .text = title,
            .icon = marker,
            .selected = selected,
            .on_press = .{ .select_position = @intCast(tab_index) },
            .semantics = .{ .label = semantics },
        }, .{})
    else
        ui.listItem(.{
            .global_key = trigger_key,
            .size = .sm,
            .height = side_tab_height,
            .width = side_rail_width,
            .icon = marker,
            .selected = selected,
            .on_press = .{ .select_position = @intCast(tab_index) },
            .semantics = .{ .role = .tab, .label = semantics },
        }, title);
}

fn webTabTrigger(ui: *TerminalUi, model: *const Model, placement: TabPlacement) TerminalUi.Node {
    const selected = model.web_selected;
    const shortcut = ui.fmt("CMD+{d}", .{model.tab_count + 1});
    const semantics = ui.fmt("Web, system WebKit, shortcut {s}{s}", .{ shortcut, if (selected) ", selected" else "" });
    const trigger_key: canvas.UiKey = .{ .index = std.math.maxInt(usize) };
    return if (placement == .top)
        ui.el(.segmented_control, .{
            .global_key = trigger_key,
            .text = "Web",
            .selected = selected,
            .on_press = .{ .select_surface = .web },
            .semantics = .{ .label = semantics },
        }, .{})
    else
        ui.listItem(.{
            .global_key = trigger_key,
            .size = .sm,
            .height = side_tab_height,
            .width = side_rail_width,
            .selected = selected,
            .on_press = .{ .select_surface = .web },
            .semantics = .{ .role = .tab, .label = semantics },
        }, "Web");
}

/// The spoken identity of a terminal SURFACE.
///
/// This is deliberately self-sufficient rather than leaning on the tab that
/// usually sits above it: at rest there is no band, so the surface is the only
/// thing in the tree that can tell a screen reader what this terminal is and
/// how it is doing.
fn terminalSurfaceLabel(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    if (model.provider.terminalConst(id)) |pane| return paneDiagnostics(ui, model, pane);
    const phase = if (model.remotePresentation(id)) |presentation|
        remoteLifecycleText(presentation.phase)
    else
        "UNAVAILABLE";
    return ui.fmt("{s}, phux terminal, {s}", .{ terminalTitle(ui, model, id), phase });
}

/// A single pane's interaction surface. No pane header: Ghostty has none,
/// and the 24pt `TERMINAL 2 / PHUX / RUNNING` strip cost every split pane a
/// row of grid for information the tab strip already carries.
fn terminalSurface(ui: *TerminalUi, model: *const Model, node: layout.NodeId, terminal_ref: TerminalRef, rect: geometry.RectF) TerminalUi.Node {
    const pane = model.provider.terminalConst(terminal_ref);
    const screen = if (pane) |local|
        local.session.screenText()
    else if (model.remotePresentation(terminal_ref)) |presentation|
        presentation.grid.screen_text
    else
        "";
    const local_id = provider_contract.localId(terminal_ref);
    if (pane == null or local_id == null) {
        return ui.el(.stack, .{
            .global_key = .{ .index = terminalPaintIndex(model, terminal_ref) },
            .grow = 1,
            .min_width = split_pane_min_width,
            .height = rect.height,
            .opacity = 0,
            .text = screen,
            .on_press = .{ .focus_pane = node },
            .semantics = .{
                .focusable = true,
                .label = terminalSurfaceLabel(ui, model, terminal_ref),
            },
        }, .{});
    }
    const local_pane = pane.?;
    const context_menu = [_]TerminalUi.ContextMenuItem{
        .{ .label = "Copy", .msg = .{ .copy_terminal = local_pane.id }, .enabled = local_pane.session.selectionActive() },
        .{ .label = "Paste", .msg = .{ .paste_terminal = local_pane.id }, .enabled = local_pane.acceptsInput() },
    };
    // One unbound terminal contributes native interaction and semantics over
    // the app-owned libghostty painter. pty=0 prevents SDK session input;
    // opacity=0 prevents duplicate pixels. Policy disabled keeps a live TUI's
    // secondary stream routed; automatic lets the declared local menu win.
    return ui.terminal(.{
        .global_key = .{ .index = @intCast(@intFromEnum(local_id.?)) },
        .grow = 1,
        .min_width = split_pane_min_width,
        .height = rect.height,
        .opacity = 0,
        .text = screen,
        .on_press = .{ .focus_pane = node },
        .context_menu = &context_menu,
        .context_menu_policy = if (paneReportsMouse(local_pane)) .disabled else .automatic,
        .semantics = .{
            .focusable = true,
            .label = terminalSurfaceLabel(ui, model, local_pane.id),
        },
    });
}

/// The widget tree for a subtree, laid out on EXACTLY the rects
/// `layout.splitRect` resolves — the same primitive `resolvePanes` walks.
///
/// A horizontal branch becomes an SDK `.split`, whose own fraction clamp is
/// the same formula (`splitFractionBounds` == `layout.effectiveFraction` for
/// equal minimums), so it keeps a real draggable divider. A vertical branch
/// becomes a column with explicit child heights, because the SDK's splitter
/// is horizontal-only.
fn paneSubtree(ui: *TerminalUi, model: *const Model, node: layout.NodeId, rect: geometry.RectF) TerminalUi.Node {
    const current = model.selectedTreeConst() orelse return emptyStatusNode(ui);
    const entry = current.node(node);
    switch (entry.kind) {
        .free => return emptyStatusNode(ui),
        .leaf => {
            const terminal_ref = entry.terminal orelse return emptyStatusNode(ui);
            return terminalSurface(ui, model, node, terminal_ref, rect);
        },
        .branch => {
            const halves = layout.splitRect(
                rect,
                entry.orientation,
                entry.fraction,
                split_divider_width,
                split_pane_min_width,
                split_pane_min_height,
            );
            const first = paneSubtree(ui, model, entry.first, halves[0]);
            const second = paneSubtree(ui, model, entry.second, halves[1]);
            return switch (entry.orientation) {
                .horizontal => ui.split(.{
                    .grow = 1,
                    .height = rect.height,
                    .gap = split_divider_width,
                    .value = entry.fraction,
                    .on_resize = split_resize_handlers[node],
                    .semantics = .{ .label = "Terminal split" },
                }, .{ first, second }),
                .vertical => ui.column(.{
                    .grow = 1,
                    .height = rect.height,
                    .gap = split_divider_width,
                }, .{ first, second }),
            };
        },
    }
}

fn parkedWebKitAnchor(ui: *TerminalUi) TerminalUi.Node {
    return ui.panel(.{
        .width = webkit_parking_extent,
        .height = webkit_parking_extent,
        .opacity = 0,
        .semantics = .{ .label = webview_anchor, .hidden = true },
    }, .{});
}

pub fn view(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    var triggers: [visible_tab_slots + 1]TerminalUi.Node = undefined;
    for (&triggers) |*node| node.* = ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    const shown = @min(model.tab_count, visible_tab_slots);
    for (0..shown) |index| {
        triggers[index] = terminalTabTrigger(ui, model, index, model.tab_placement);
    }
    triggers[shown] = webTabTrigger(ui, model, model.tab_placement);

    const tokens = cockpitTokens(model);
    const chrome = workspaceChrome(model, model.surface_size);
    const focused_ref = model.selectedTerminalRef();
    const status = if (focused_ref) |id| paneStatus(ui, model, id) else emptyStatusNode(ui);

    const revealed = chromeRevealed(model);
    // No `.gap`: the Geist register's own `tabs_gap` (24) applies only when
    // the author leaves it at 0, and the old `.gap = 2` made every label
    // touch its neighbour. No `.size = .sm` on the triggers either — at that
    // rung the computed trigger inset is 0, i.e. no horizontal padding at all.
    const top_header = if (revealed and model.tab_placement == .top) ui.row(.{ .height = header_height, .gap = 12, .cross = .center, .window_drag = true }, .{
        ui.el(.tabs, .{ .semantics = .{ .label = "Surfaces" } }, .{
            triggers[0],
            triggers[1],
            triggers[2],
            triggers[3],
            triggers[4],
            triggers[5],
            triggers[6],
            triggers[7],
            triggers[8],
        }),
        ui.spacer(1),
        status,
    })
        // At rest there is no band at all. Every control it carried stays
        // reachable: New is cmd+T, Close cmd+W, Split cmd+D, and the surfaces
        // are cmd+1..cmd+N — the band is presentation, never the only path.
        else ui.el(.stack, .{ .height = 0, .semantics = .{ .hidden = true } }, .{});

    const content = if (model.selectedTreeConst()) |current| blk: {
        // Parking the webview at a one-point anchor preserves its native
        // page state without allowing it to cover or receive input over a
        // terminal tab.
        break :blk ui.el(.stack, .{ .grow = 1 }, .{
            paneSubtree(ui, model, current.root, chrome.content),
            parkedWebKitAnchor(ui),
        });
    } else ui.panel(.{
        .grow = 1,
        .semantics = .{ .label = webview_anchor },
    }, .{});

    const side_rail_content = ui.column(.{ .width = side_rail_width, .gap = 8 }, .{
        ui.list(.{ .width = side_rail_width, .gap = 3, .semantics = .{ .label = "Surfaces" } }, .{
            triggers[0],
            triggers[1],
            triggers[2],
            triggers[3],
            triggers[4],
            triggers[5],
            triggers[6],
            triggers[7],
            triggers[8],
        }),
        ui.spacer(1),
        status,
    });
    const side_rail = if (revealed and model.tab_placement == .side)
        ui.scroll(.{
            .width = side_rail_width,
            .grow = 1,
            .semantics = .{ .label = "Workspace controls" },
        }, side_rail_content)
    else
        ui.el(.stack, .{ .width = 0, .semantics = .{ .hidden = true } }, .{});

    const workspace = if (revealed and model.tab_placement == .side)
        ui.row(.{ .grow = 1, .gap = side_rail_gap }, .{ side_rail, content })
    else
        ui.column(.{ .grow = 1 }, .{ top_header, content });

    // The hidden-inset titlebar band. It carries `window_drag` UNCONDITIONALLY,
    // because it is the only element that can: the SDK has no
    // movable-by-background fallback, so a frame where nothing declares
    // `window_drag` is a frame where the window cannot be moved at all.
    const titlebar_band = @max(0, chrome.titlebar_height - grid_inset);
    _ = tokens;
    return ui.column(.{ .padding = grid_inset }, .{
        ui.el(.stack, .{
            .height = titlebar_band,
            .window_drag = true,
            .semantics = .{ .label = "Phux Cockpit window" },
        }, .{}),
        workspace,
    });
}

/// The grids, painted as a variable-length chrome prefix beneath the
/// widget tree: real text through the canvas primitives, damage kept
/// row-shaped by stable command ids, one id namespace per pane.
pub fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    // The window's own ground is painted ONCE, before any pane. The first
    // pane used to be handed the whole window as its background frame, so
    // the emulator's background (OSC 11 included) bled under the tab strip
    // and the titlebar.
    try builder.fillRect(.{
        .id = window_ground_command_id,
        .rect = geometry.RectF.init(0, 0, size.width, size.height),
        .fill = .{ .color = tokens.colors.background },
    });

    const chrome = workspaceChrome(model, size);
    if (chrome.header.height > 0) {
        // The band gets a real ground and a separator, so it reads as chrome
        // instead of as a floating strip over the terminal.
        try builder.fillRect(.{
            .id = header_ground_command_id,
            .rect = chrome.header,
            .fill = .{ .color = tokens.colors.surface },
        });
        try builder.fillRect(.{
            .id = header_rule_command_id,
            .rect = geometry.RectF.init(chrome.header.x, chrome.header.y + chrome.header.height - 1, chrome.header.width, 1),
            .fill = .{ .color = tokens.colors.border },
        });
    }

    // The app's own grounds are chrome, not grid: the panes' command
    // envelope is measured from HERE, so adding a background fill can never
    // shave commands off the last pane's share.
    const prologue = builder.len;

    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolvePanes(model, size, &panes);
    if (count == 0) return;

    // The budgets are partitioned by kind, exactly as the two-pane painter
    // did, generalized to N panes:
    //   commands  — CUMULATIVE across the prefix, so pane i may spend up to
    //               its share of the running total and the LAST pane may
    //               spend the whole envelope;
    //   text/path — RESERVES, so a pane holds back the shares belonging to
    //               the panes that paint after it;
    //   glyphs    — per-paint local, so each pane takes an equal slice.
    const share_divisor: usize = @max(1, count);
    const text_share = (canvas.max_display_list_text_bytes - canvas.terminal_grid.widget_text_reserve) / share_divisor;
    const path_share = (canvas.max_chart_path_elements_per_frame - canvas.terminal_grid.widget_path_reserve) / share_divisor;
    const focus_node = if (model.selectedTreeConst()) |current| current.focus else layout.none;

    for (panes[0..count], 0..) |pane, index| {
        if (pane.rect.width <= 0 or pane.rect.height <= 0) continue;
        const remaining = count - 1 - index;
        // The command budget is measured against the builder's RUNNING
        // length, so each pane is granted its own equal slice above whatever
        // the panes before it spent. A fixed cumulative ladder starved the
        // later panes whenever an earlier one filled its share.
        // A CUMULATIVE ladder measured from the chrome prologue: pane i may
        // spend up to its share of the running total, and the LAST pane may
        // spend the whole envelope. A per-pane slice would strand the tail
        // of the envelope unused whenever an early pane came in cheap.
        const command_budget = prologue + chrome_command_envelope * (index + 1) / share_divisor;
        const text_reserve = canvas.terminal_grid.widget_text_reserve + text_share * remaining;
        const path_reserve = canvas.terminal_grid.widget_path_reserve + path_share * remaining;
        const glyph_budget = canvas.terminal_grid.widget_glyph_budget / share_divisor;
        // Each pane owns its OWN background frame. Nothing paints outside
        // the pane it belongs to.
        const options_focused = model.focused and pane.node == focus_node;
        if (model.provider.terminalConst(pane.terminal)) |terminal| {
            try grid.paint(terminal.session, builder, .{
                .frame = pane.rect,
                .background_frame = pane.rect,
                .tokens = tokens,
                .running = terminal.phase == .live or terminal.phase == .starting,
                .focused = options_focused,
                .selecting = terminal.selecting,
                .command_budget = command_budget,
                .text_reserve = text_reserve,
                .glyph_budget = glyph_budget,
                .path_reserve = path_reserve,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, pane.terminal)),
            });
        } else {
            const remote = model.phuxConst() orelse continue;
            const presentation = remote.presentation(pane.terminal) orelse continue;
            try grid.paintTerminalGrid(presentation.grid, builder, .{
                .frame = pane.rect,
                .background_frame = pane.rect,
                .tokens = tokens,
                .running = presentation.phase == .live,
                .focused = options_focused,
                .selecting = if (model.remoteUiConst(pane.terminal)) |state| state.selecting else false,
                .command_budget = command_budget,
                .text_reserve = text_reserve,
                .glyph_budget = glyph_budget,
                .path_reserve = path_reserve,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, pane.terminal)),
            });
        }
    }
}

/// Frame pump: resize each visible terminal against its actual pane. One
/// resize message is emitted per frame; further changed panes follow on
/// later frames without ever coupling a PTY's lifetime to layout.
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const frame_scale = if (validScale(frame.scale_factor)) frame.scale_factor else model.surface_scale_factor;
    var pending = false;
    for (0..max_terminals) |index| {
        if (model.provider.states[index] != .active) continue;
        const pane = model.provider.slotConst(index);
        if (pane.outbound_len > 0 or pane.session.response_len > 0) pending = true;
    }

    // The SAME resolve the painter and the widget tree use.
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolvePanes(model, frame.size, &panes);
    for (panes[0..count]) |pane| {
        const inner = pane.rect;
        if (inner.width <= 0 or inner.height <= 0) continue;
        if (model.provider.terminalConst(pane.terminal)) |terminal| {
            const session = terminal.session;
            if (session.cell_width <= 0 or session.cell_height <= 0) return if (pending) .flush_outbound else null;
            const proposed = grid.Session.clampGrid(
                @intFromFloat(@max(2, inner.width / session.cell_width)),
                @intFromFloat(@max(2, inner.height / session.cell_height)),
            );
            if (proposed.x != terminal.cols or proposed.y != terminal.rows) {
                return .{
                    .viewport = .{
                        .terminal_ref = pane.terminal,
                        .cols = proposed.x,
                        .rows = proposed.y,
                        .size = frame.size,
                        // Carry the real scale: the `.viewport` arm commits
                        // whatever arrives, and the field's `= 1` default
                        // would silently reset a Retina surface to 1x.
                        .scale_factor = frame_scale,
                    },
                };
            }
            continue;
        }
        const remote = model.phuxConst() orelse continue;
        if (remote.presentation(pane.terminal) == null) continue;
        const metrics = canvas.terminalCellMetrics(cockpitTokens(model));
        const proposed = grid.Session.clampGrid(
            @intFromFloat(@max(2, inner.width / metrics.width)),
            @intFromFloat(@max(2, inner.height / metrics.height)),
        );
        const viewport: Viewport = .{ .cols = proposed.x, .rows = proposed.y };
        if (remote.lastViewport(pane.terminal) == null or !remote.lastViewport(pane.terminal).?.eql(viewport)) {
            return .{ .viewport = .{
                .terminal_ref = pane.terminal,
                .cols = proposed.x,
                .rows = proposed.y,
                .size = frame.size,
                .scale_factor = frame_scale,
            } };
        }
    }
    if (model.surface_size.width != frame.size.width or model.surface_size.height != frame.size.height or
        model.surface_scale_factor != frame_scale)
    {
        return .{ .surface_resized = .{ .size = frame.size, .scale_factor = frame_scale } };
    }
    if (pending) return .flush_outbound;
    return null;
}

pub fn webPanes(model: *const Model, out: []TerminalApp.WebViewPane) usize {
    out[0] = .{
        .label = webview_label,
        .anchor = webview_anchor,
        .url = model.browser_page.url(),
        .reload_token = model.browser_navigation_token,
    };
    return 1;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "surface.1")) return .{ .select_position = 0 };
    if (std.mem.eql(u8, name, "surface.2")) return .{ .select_position = 1 };
    if (std.mem.eql(u8, name, "surface.3")) return .{ .select_position = 2 };
    if (std.mem.eql(u8, name, "surface.4")) return .{ .select_position = 3 };
    if (std.mem.eql(u8, name, "surface.5")) return .{ .select_position = 4 };
    if (std.mem.eql(u8, name, "tab.previous")) return .{ .cycle_tab = -1 };
    if (std.mem.eql(u8, name, "tab.next")) return .{ .cycle_tab = 1 };
    if (std.mem.eql(u8, name, "pane.split-right")) return .split_right;
    if (std.mem.eql(u8, name, "pane.split-down")) return .split_down;
    if (std.mem.eql(u8, name, "terminal.new")) return .new_terminal;
    if (std.mem.eql(u8, name, "terminal.close")) return .close_terminal;
    if (std.mem.eql(u8, name, "tab.move-left")) return .{ .move_terminal = -1 };
    if (std.mem.eql(u8, name, "tab.move-right")) return .{ .move_terminal = 1 };
    if (std.mem.eql(u8, name, "tabs.toggle-placement")) return .toggle_tab_placement;
    if (std.mem.eql(u8, name, "pane.previous")) return .{ .cycle_pane = -1 };
    if (std.mem.eql(u8, name, "pane.next")) return .{ .cycle_pane = 1 };
    return null;
}

pub fn tabPlacementFromText(value: []const u8) ?TabPlacement {
    if (std.ascii.eqlIgnoreCase(value, "top")) return .top;
    if (std.ascii.eqlIgnoreCase(value, "side") or std.ascii.eqlIgnoreCase(value, "sidebar")) return .side;
    return null;
}

pub fn onTimer(id: u64, _: u64) ?Msg {
    return if (id == selection_autoscroll_timer_id) .selection_autoscroll else null;
}
