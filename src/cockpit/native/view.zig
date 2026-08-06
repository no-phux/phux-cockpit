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
const windowPadding = projection.windowPadding;
const cockpitTokens = projection.cockpitTokens;
const terminalTokens = projection.terminalTokens;
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

const tab_height = projection.tab_height;
const tab_control_extent = projection.tab_control_extent;
const tab_marker_extent = projection.tab_marker_extent;
const visibleTabWindow = projection.visibleTabWindow;
/// The attention marker's icon name. One constant, because both placements
/// paint it and a test pins it.
const attention_marker_icon = "circle-dot";

/// Retained ids for the app's own chrome grounds. Disjoint from the grid
/// painter's namespace (`render.paneIdBase` starts at 0x7e21), so damage
/// tracking treats them as their own stable commands.
pub const window_ground_command_id: u64 = 0x0c01;
pub const header_ground_command_id: u64 = 0x0c02;
pub const header_rule_command_id: u64 = 0x0c03;
/// Base for the unfocused-pane scrim, one retained id per resolved pane.
/// Disjoint from the three above and from `render.paneIdBase` (0x7e21+).
pub const pane_dim_command_id_base: u64 = 0x0c10;

/// Phux has one visual register regardless of the system appearance: deep
/// graphite surfaces, porcelain text, and lime reserved for focus/action.
fn terminalNumber(id: LocalTerminalId) u64 {
    return @intFromEnum(id) - first_terminal_raw + 1;
}

/// The tab label for a terminal, in the order a terminal user reads it:
///
///   1. the SHELL's own title (OSC 0/2). A prompt with title integration is
///      already saying what the tab is — "vim src/main.zig", "npm run dev" —
///      and nothing this app invents beats that.
///   2. the last component of the working directory (OSC 7), which is what
///      Ghostty and Terminal.app fall back to and what most shells report
///      even without title integration.
///   3. `Terminal N`, the mint-order number, which is always true and never
///      useful.
///
/// A Phux terminal borrows the title its coordinator published; the local
/// chain does not apply because there is no local session to ask.
fn terminalTitle(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    if (provider_contract.localId(id)) |local| {
        if (model.provider.terminalConst(id)) |pane| {
            const shell_title = pane.title();
            if (shell_title.len > 0) return shell_title;
            const cwd = pane.pwd();
            if (cwd.len > 0) {
                // `basename("/")` is empty and `basename("")` is empty; both
                // fall through to the number rather than painting a blank tab.
                const leaf = std.fs.path.basename(cwd);
                if (leaf.len > 0) return leaf;
            }
        }
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

/// The spoken description of one tab. Unchanged in content from the old
/// strip: a screen reader still gets the whole diagnostic sentence the eye no
/// longer sees.
fn tabSemantics(ui: *TerminalUi, model: *const Model, tab_index: usize, id: TerminalRef, title: []const u8, selected: bool) []const u8 {
    const shortcut = ui.fmt("CMD+{d}", .{tab_index + 1});
    const panes_in_tab = if (model.treeConst(tab_index)) |current| current.paneCount() else 1;
    const kind_label = if (provider_contract.isLocal(id)) "native terminal" else "phux terminal";
    return if (model.provider.terminalConst(id)) |terminal|
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
}

/// The attention marker: a DOT in a fixed slot, never a `!` welded onto the
/// terminal's name. The slot is reserved whether or not the dot is drawn, so
/// a bell does not shove the label sideways.
fn tabAttentionMarker(ui: *TerminalUi, model: *const Model, id: TerminalRef, tokens: canvas.DesignTokens) TerminalUi.Node {
    if (!terminalNeedsAttention(model, id)) {
        return ui.el(.stack, .{ .width = tab_marker_extent, .semantics = .{ .hidden = true } }, .{});
    }
    // The EXPLICIT icon channel (`Widget.icon`), the way `Ui.appIcon` does
    // it — `Ui.icon` puts the name in `text`, and this leaf's text is read by
    // damage tracking and by the a11y fingerprint as content.
    return ui.el(.icon, .{
        .width = tab_marker_extent,
        .height = tab_marker_extent,
        .icon = attention_marker_icon,
        .style = .{ .foreground = tokens.colors.warning },
        .semantics = .{ .label = "Needs attention" },
    }, .{});
}

/// One tab in the top strip.
///
/// Built from a `.stack` rather than the register's `segmented_control`
/// because a segmented trigger is a LEAF: it carries a label and one icon and
/// nothing else, so it can never host a close affordance. This is the shape
/// the toolkit's own code-editor example uses for exactly that reason — press
/// target on the container, controls as real children inside it.
fn terminalTabTrigger(ui: *TerminalUi, model: *const Model, tab_index: usize, tokens: canvas.DesignTokens, extent: f32) TerminalUi.Node {
    const id = model.tabTerminal(tab_index) orelse return ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    const selected = !model.web_selected and model.selected_tab == tab_index;
    const title = terminalTitle(ui, model, id);
    const semantics = tabSemantics(ui, model, tab_index, id, title, selected);
    const trigger_key: canvas.UiKey = .{ .index = terminalPaintIndex(model, id) };

    // The close `x` shows on the SELECTED tab and on whatever the pointer is
    // over. Showing it on every tab turns a strip of names into a strip of
    // buttons; showing it on none makes closing a mouse-only user's problem.
    const show_close = selected or model.hovered_tab == tab_index;
    const close_node = if (show_close)
        ui.button(.{
            .width = tab_control_extent,
            .height = tab_control_extent,
            .size = .icon,
            .variant = .ghost,
            .icon = "x",
            .on_press = .{ .close_tab = @intCast(tab_index) },
            .semantics = .{ .label = ui.fmt("Close {s}", .{title}) },
        }, "")
    else
        ui.el(.stack, .{ .width = tab_control_extent, .semantics = .{ .hidden = true } }, .{});

    // ONE selection signal, not two. The list item's own rounded selected
    // fill plus the brighter label already say which tab is current; an
    // accent rule under a rounded pill reads as a second, competing marker
    // (and is clipped by the pill's own radius anyway).
    const body = ui.row(.{ .height = tab_height, .gap = 6, .cross = .center, .padding = 8 }, .{
        tabAttentionMarker(ui, model, id, tokens),
        ui.text(.{
            .grow = 1,
            .wrap = false,
            .overflow = .ellipsis,
            .style = .{ .foreground = if (selected) tokens.colors.text else tokens.colors.text_muted },
        }, title),
        close_node,
    });

    // `.list_item`, not `.stack`. A plain container is invisible to the
    // keyboard AND to assistive activation: `widgetKeyboardControlIntent`
    // has no arm for it, so Enter over a focused stack does nothing and an
    // advertised `press` action would be one an AX user cannot invoke. A
    // list item is focusable, answers Enter with `select`, and — unlike the
    // `segmented_control` this replaces — is a real container, which is what
    // lets a close affordance live inside the tab.
    return ui.el(.list_item, .{
        .global_key = trigger_key,
        .width = extent,
        .height = tab_height,
        .selected = selected,
        .on_press = .{ .select_position = @intCast(tab_index) },
        .on_hover_enter = .{ .hover_tab = @intCast(tab_index) },
        .on_hover_leave = .unhover_tab,
        .style = .{ .background = if (selected) tokens.colors.surface_subtle else tokens.colors.surface },
        .semantics = .{ .role = .tab, .label = semantics },
    }, .{body});
}

/// The side rail's row for one tab. The rail is a vertical list, so the
/// register's own `list_item` still fits — it has a leading icon slot and a
/// selected state, and the close affordance rides the row beside it.
fn terminalRailTrigger(ui: *TerminalUi, model: *const Model, tab_index: usize) TerminalUi.Node {
    const id = model.tabTerminal(tab_index) orelse return ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    const selected = !model.web_selected and model.selected_tab == tab_index;
    const title = terminalTitle(ui, model, id);
    const marker: []const u8 = if (terminalNeedsAttention(model, id)) attention_marker_icon else "";
    return ui.listItem(.{
        .global_key = .{ .index = terminalPaintIndex(model, id) },
        .size = .sm,
        .height = side_tab_height,
        .width = side_rail_width,
        .icon = marker,
        .selected = selected,
        .on_press = .{ .select_position = @intCast(tab_index) },
        .semantics = .{ .role = .tab, .label = tabSemantics(ui, model, tab_index, id, title, selected) },
    }, title);
}

fn newTabButton(ui: *TerminalUi) TerminalUi.Node {
    return ui.button(.{
        .width = tab_height,
        .height = tab_control_extent + 6,
        .size = .icon,
        .variant = .ghost,
        .icon = "plus",
        .on_press = .new_terminal,
        .semantics = .{ .label = "New terminal, shortcut CMD+T" },
    }, "");
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
    const surface = ui.terminal(.{
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

    // A dead pane you are NOT focused on had no signal at all: the band's
    // Restart is scoped to the focused pane, so a shell that died while you
    // were in the split next to it just stopped, silently, until you cycled
    // into it. The overlay is deliberately only for the UNFOCUSED case — the
    // focused pane already has the band, and two Restart buttons for one
    // terminal is worse than one in the wrong place.
    const focused_node = if (model.selectedTreeConst()) |current| current.focus else layout.none;
    if (node == focused_node or !paneLifecycleFailed(local_pane)) return surface;
    return ui.el(.stack, .{
        .grow = 1,
        .min_width = split_pane_min_width,
        .height = rect.height,
    }, .{
        surface,
        ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = 8 }, .{
            ui.el(.badge, .{
                .variant = .destructive,
                .text = paneLifecycleText(ui, local_pane),
                .semantics = .{ .label = paneDiagnostics(ui, model, local_pane) },
            }, .{}),
            ui.button(.{
                .size = .sm,
                .variant = .secondary,
                .on_press = .{ .restart = local_pane.id },
                .semantics = .{ .label = ui.fmt("Restart {s}", .{terminalTitle(ui, model, local_pane.id)}) },
            }, "Restart"),
        }),
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
    const tokens = cockpitTokens(model);
    // A REAL slice, not a fixed tuple: tabs 9..16 used to exist in the model
    // and simply not be drawn, which is not a tab strip, it is a window into
    // one. `Ui.el` copies the slice into its own arena, so a stack array is
    // the right storage here.
    //
    // The top strip draws a derived window that always contains the selected
    // tab; the side rail is a vertical list and draws every tab.
    const window = visibleTabWindow(model, model.surface_size.width - windowPadding(model) * 2);
    var strip_nodes: [max_tabs]TerminalUi.Node = undefined;
    var rail_nodes: [max_tabs]TerminalUi.Node = undefined;
    for (0..window.count) |offset| {
        strip_nodes[offset] = terminalTabTrigger(ui, model, window.first + offset, tokens, window.extent);
    }
    for (0..model.tab_count) |index| {
        rail_nodes[index] = terminalRailTrigger(ui, model, index);
    }
    const strip_slice = strip_nodes[0..window.count];
    const rail_slice = rail_nodes[0..model.tab_count];

    const chrome = workspaceChrome(model, model.surface_size);
    const focused_ref = model.selectedTerminalRef();
    const status = if (focused_ref) |id| paneStatus(ui, model, id) else emptyStatusNode(ui);

    const revealed = chromeRevealed(model);
    // The strip is TERMINALS ONLY. The web surface kept its pane, its scene
    // wiring and its reload token; what it lost is a permanent seat in a
    // terminal's tab bar, where it was pinned last regardless of how many
    // terminals were open. It is cmd+shift+B and View > Web Surface now.
    //
    // A horizontal scroller carries the strip so tab 16 is reachable by
    // scrolling rather than only by cycling, and the runtime reveals the
    // selected tab when it scrolls out of view.
    const tab_strip = ui.row(.{
        .grow = 1,
        .height = tab_height,
        .gap = 2,
        .cross = .center,
        .semantics = .{ .label = "Terminal tabs" },
    }, .{
        strip_slice,
        newTabButton(ui),
        ui.spacer(1),
    });

    const top_header = if (revealed and model.tab_placement == .top) ui.row(.{ .height = header_height, .gap = 12, .cross = .center, .window_drag = true }, .{
        tab_strip,
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
        ui.list(.{ .width = side_rail_width, .gap = 3, .semantics = .{ .label = "Terminal tabs" } }, rail_slice),
        newTabButton(ui),
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
    const inset = windowPadding(model);
    const titlebar_band = @max(0, chrome.titlebar_height - inset);
    return ui.column(.{ .padding = inset }, .{
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
    // The grids paint with the TERMINAL tokens (the configured type size and
    // colors); everything else on this surface is chrome and keeps the app's
    // own register. See `projection.terminalTokens`.
    const grid_tokens = projection.terminalTokensFrom(tokens, model);
    // The window's own ground is painted ONCE, before any pane. The first
    // pane used to be handed the whole window as its background frame, so
    // the emulator's background (OSC 11 included) bled under the tab strip
    // and the titlebar. It takes the terminal's background so a configured
    // `background` reaches the gutter too, rather than leaving a frame of
    // the app's default graphite around a themed terminal.
    try builder.fillRect(.{
        .id = window_ground_command_id,
        .rect = geometry.RectF.init(0, 0, size.width, size.height),
        .fill = .{ .color = grid_tokens.colors.background },
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
    // Cells are the budget that actually bounds a terminal now, and unlike
    // text and paths they have no widget floor to hold back: nothing but a
    // terminal grid emits into the packed cell store. So the WHOLE store is
    // divided among the panes and each one reserves the shares belonging to
    // the panes painting after it.
    //
    // Deliberately not `terminal_grid.widget_cell_reserve`. Despite the name
    // that constant is `max/2` — the SDK's even split for exactly TWO panes,
    // not a widget reserve. Using it as a floor would hold back half the
    // store at every pane count: a lone full-screen terminal would get 16384
    // cells and a 320x96 grid needs 30720, so the single-pane case — the
    // common one — would start silently truncating again.
    const cell_share = canvas.max_display_list_cells / share_divisor;
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
        const cell_reserve = cell_share * remaining;
        // Each pane owns its OWN background frame. Nothing paints outside
        // the pane it belongs to.
        const options_focused = model.focused and pane.node == focus_node;
        if (model.provider.terminalConst(pane.terminal)) |terminal| {
            try grid.paint(terminal.session, builder, .{
                .frame = pane.rect,
                .background_frame = pane.rect,
                .tokens = grid_tokens,
                .running = terminal.phase == .live or terminal.phase == .starting,
                .focused = options_focused,
                .selecting = terminal.selecting,
                .command_budget = command_budget,
                .text_reserve = text_reserve,
                .glyph_budget = glyph_budget,
                .path_reserve = path_reserve,
                .cell_reserve = cell_reserve,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, pane.terminal)),
            });
        } else {
            const remote = model.phuxConst() orelse continue;
            const presentation = remote.presentation(pane.terminal) orelse continue;
            try grid.paintTerminalGrid(presentation.grid, builder, .{
                .frame = pane.rect,
                .background_frame = pane.rect,
                .tokens = grid_tokens,
                .running = presentation.phase == .live,
                .focused = options_focused,
                .selecting = if (model.remoteUiConst(pane.terminal)) |state| state.selecting else false,
                .command_budget = command_budget,
                .text_reserve = text_reserve,
                .glyph_budget = glyph_budget,
                .path_reserve = path_reserve,
                .cell_reserve = cell_reserve,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, pane.terminal)),
            });
        }

        // Ghostty dims the splits you are not in, and it is the right answer:
        // with per-pane headers gone, a solid-versus-hollow cursor was the
        // ONLY thing telling you where your keystrokes were going, and a
        // cursor is a few pixels on a screen full of text.
        //
        // A scrim in the window's own ground color, not a border: a border
        // costs a row of cells at every pane edge and reads as chrome, which
        // is exactly what this app spent its last round removing. One pane
        // never dims — there is nothing to disambiguate — and neither does a
        // window that does not have key, where nothing is focused at all.
        if (count > 1 and model.focused and pane.node != focus_node) {
            try builder.fillRect(.{
                .id = pane_dim_command_id_base + index,
                .rect = pane.rect,
                .fill = .{ .color = dimScrim(tokens) },
            });
        }
    }
}

/// The unfocused-pane scrim: the window ground at low alpha, which reads as
/// "further away" rather than as a tint.
fn dimScrim(tokens: canvas.DesignTokens) canvas.Color {
    const ground = tokens.colors.background;
    return canvas.Color.rgba(ground.r, ground.g, ground.b, 0.36);
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
    // Cell metrics for a LOCAL pane come from `session.cell_*`, which the
    // painter wrote from the live terminal tokens. Deriving them here instead
    // would be wrong, not merely redundant: only the painter's tokens carry
    // the runtime's text-measure provider, so a token derivation here falls
    // back to the `label_size * 0.6` estimate and proposes a different column
    // count than the one being painted. The cost is that a font-size change
    // reflows on the frame AFTER the first repaint at the new size, which is
    // one timer tick.
    const metrics = canvas.terminalCellMetrics(terminalTokens(model));
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
    if (std.mem.eql(u8, name, "surface.web")) return .{ .select_surface = .web };
    if (std.mem.eql(u8, name, "terminal.copy")) return .copy_selection;
    if (std.mem.eql(u8, name, "terminal.paste")) return .paste_focused;
    if (std.mem.eql(u8, name, "terminal.select-all")) return .select_all;
    if (std.mem.eql(u8, name, "terminal.clear")) return .clear_terminal;
    if (std.mem.eql(u8, name, "view.font-larger")) return .{ .font_size_step = 1 };
    if (std.mem.eql(u8, name, "view.font-smaller")) return .{ .font_size_step = -1 };
    if (std.mem.eql(u8, name, "view.font-reset")) return .font_size_reset;
    if (std.mem.eql(u8, name, "pane.focus-left")) return .{ .focus_direction = .left };
    if (std.mem.eql(u8, name, "pane.focus-right")) return .{ .focus_direction = .right };
    if (std.mem.eql(u8, name, "pane.focus-up")) return .{ .focus_direction = .up };
    if (std.mem.eql(u8, name, "pane.focus-down")) return .{ .focus_direction = .down };
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
