const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../../terminal/grid.zig");
const provider_contract = @import("provider_contract");
const support = @import("../phux_support.zig");
const local_terminal = @import("../../providers/local/provider.zig");
const model_module = @import("../model.zig");
const topology = @import("../topology.zig");
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
const Placement = topology.Placement;
const TabPlacement = topology.TabPlacement;
const TerminalApp = app_types.TerminalApp;
const Msg = app_types.Msg;
const max_terminal_count = local_terminal.max_terminal_count;
const pane_count = local_terminal.pane_count;
const first_terminal_raw = local_terminal.first_terminal_raw;
const providerKind = support.providerKind;
const header_height = projection.header_height;
const side_rail_width = projection.side_rail_width;
const side_rail_gap = projection.side_rail_gap;
const side_tab_height = projection.side_tab_height;
const split_divider_width = projection.split_divider_width;
const split_pane_min_width = projection.split_pane_min_width;
const split_pane_header_height = projection.split_pane_header_height;
const webkit_parking_extent = projection.webkit_parking_extent;
const webview_label = scene_module.webview_label;
const webview_anchor = scene_module.webview_anchor;
const chrome_command_envelope = projection.chrome_command_envelope;
const grid_inset = projection.grid_inset;
const cockpitTokens = projection.cockpitTokens;
const chromeRevealed = projection.chromeRevealed;
const workspaceChrome = projection.workspaceChrome;
const paneFrames = projection.paneFrames;
const terminalNeedsAttention = projection.terminalNeedsAttention;
const paneLifecycleFailed = projection.paneLifecycleFailed;
const paneHasConfirmedLoss = projection.paneHasConfirmedLoss;
const splitAvailable = projection.splitAvailable;
const selectedTerminalCanClose = projection.selectedTerminalCanClose;
const paneReportsMouse = pointer_input.paneReportsMouse;
const validScale = pointer_input.validScale;
const selection_autoscroll_timer_id = app_types.selection_autoscroll_timer_id;
const TerminalUi = TerminalApp.Ui;

/// Phux has one visual register regardless of the system appearance: deep
/// graphite surfaces, porcelain text, and lime reserved for focus/action.
/// The built-in Geist dark controls keep their accessibility behavior while
/// the color register aligns the terminal and native chrome with phux.
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

fn placementAt(index: usize) Placement {
    return Placement.fromIndex(index) orelse unreachable;
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

fn paneStatus(ui: *TerminalUi, model: *const Model, index: usize, show_identity: bool) TerminalUi.Node {
    const terminal_ref = model.attachments[placementAt(index).index()] orelse return emptyStatusNode(ui);
    if (providerKind(terminal_ref) == .phux) {
        const presentation = model.remotePresentation(terminal_ref) orelse return ui.el(.badge, .{
            .size = .sm,
            .variant = .secondary,
            .text = "PHUX / FROZEN",
        }, .{});
        const state = model.remoteUiConst(terminal_ref);
        const activity = if (state != null and state.?.selecting)
            ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "SELECTING" }, .{})
        else if (model.paste_owner.terminal_ref.eql(terminal_ref) and model.paste_inflight)
            ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "PASTING" }, .{})
        else if (model.copy_inflight and model.copy_owner.terminal_ref.eql(terminal_ref))
            ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "COPYING" }, .{})
        else
            emptyStatusNode(ui);
        return ui.row(.{ .gap = 4, .cross = .center }, .{
            ui.text(.{
                .style_tokens = .{ .foreground = .text_muted },
                .semantics = .{ .label = ui.fmt("Phux terminal {s}, {s}", .{
                    presentation.title,
                    remoteLifecycleText(presentation.phase),
                }) },
            }, ui.fmt("{s} / {s}", .{
                if (presentation.title.len == 0) "PHUX" else presentation.title,
                remoteLifecycleText(presentation.phase),
            })),
            activity,
        });
    }
    const pane = model.provider.terminalConst(terminal_ref) orelse return emptyStatusNode(ui);
    const lifecycle = paneLifecycleText(ui, pane);
    const title = ui.fmt("TERMINAL {d}", .{terminalNumber(provider_contract.localId(pane.id) orelse .terminal_1)});
    const lifecycle_failed = paneLifecycleFailed(pane);
    const paste_failed = model.paste_owner.terminal_ref.eql(pane.id) and model.paste_failed;
    const lifecycle_semantics = ui.fmt(
        "{s} / {s}; OUTBOUND LOSS {d}B; REPLY LOSS {d}B; INPUT STALLED {d}; DELIVERY FAILURES {d}; {s}; {s}",
        .{
            title,
            lifecycle,
            pane.outbound_dropped,
            pane.session.response_bytes_dropped,
            pane.write_refusals,
            pane.native_delivery_failures,
            if (pane.copy_failed) "COPY FAILED" else "copy ok",
            if (paste_failed) "PASTE FAILED" else "paste ok",
        },
    );
    const lifecycle_node = if (pane.phase == .live and !show_identity)
        emptyStatusNode(ui)
    else if (pane.phase == .live)
        ui.text(.{
            .style_tokens = .{ .foreground = .text_muted },
            .semantics = .{ .label = lifecycle_semantics },
        }, title)
    else if (pane.phase == .starting)
        ui.text(.{
            .style_tokens = .{ .foreground = .text_muted },
            .semantics = .{ .label = lifecycle_semantics },
        }, ui.fmt("{s} / {s}", .{ title, lifecycle }))
    else
        ui.el(.badge, .{
            .size = .sm,
            .variant = if (lifecycle_failed) .destructive else .secondary,
            .text = ui.fmt("{s} / {s}", .{ title, lifecycle }),
            .semantics = .{ .label = lifecycle_semantics },
        }, .{});
    const issue = if (paneHasConfirmedLoss(pane))
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "I/O LOSS" }, .{})
    else if (pane.native_delivery_failures > 0)
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "DELIVERY FAILED" }, .{})
    else if (paste_failed)
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "PASTE FAILED" }, .{})
    else if (pane.copy_failed)
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "COPY FAILED" }, .{})
    else if (pane.write_refusals > 0)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "INPUT STALLED" }, .{})
    else
        emptyStatusNode(ui);
    const activity = if (pane.selecting)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "SELECTING" }, .{})
    else if (model.paste_owner.terminal_ref.eql(pane.id) and model.paste_inflight)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "PASTING" }, .{})
    else if (model.copy_inflight and model.copy_owner.terminal_ref.eql(pane.id))
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "COPYING" }, .{})
    else if (pane.copied_bytes > 0)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = ui.fmt("COPIED {d}B", .{pane.copied_bytes}) }, .{})
    else
        emptyStatusNode(ui);
    return ui.row(.{ .gap = 4, .cross = .center }, .{
        lifecycle_node,
        if (pane.phase == .ended or pane.phase == .failed)
            ui.button(.{
                .size = .sm,
                .variant = .secondary,
                .on_press = .{ .restart = placementAt(index) },
                .semantics = .{ .label = ui.fmt("Restart {s}", .{terminalTitle(ui, model, pane.id)}) },
            }, "Restart")
        else
            emptyStatusNode(ui),
        issue,
        activity,
    });
}

/// Attention is the one thing a hidden terminal is allowed to shout about.
/// Local panes report their own lifecycle; a remote terminal is abnormal when
/// its provider says so, or when it publishes no presentation at all.
fn terminalTabTrigger(ui: *TerminalUi, model: *const Model, id: TerminalRef, index: usize, placement: TabPlacement) TerminalUi.Node {
    const selected = if (model.selectedTerminalRef()) |current| current.eql(id) else false;
    var attached = false;
    for (model.attachments) |candidate| {
        if (candidate != null and candidate.?.eql(id)) attached = true;
    }
    const title = terminalTitle(ui, model, id);
    const compact = model.terminal_count + 1 > 3;
    const visible_title = if (placement == .top and compact)
        if (provider_contract.localId(id)) |local| ui.fmt("T{d}", .{terminalNumber(local)}) else "PHX"
    else
        title;
    const shortcut = ui.fmt("CMD+{d}", .{index + 1});
    const text = if (terminalNeedsAttention(model, id))
        ui.fmt("{s} !", .{visible_title})
    else
        visible_title;

    const kind_label = if (provider_contract.isLocal(id)) "native terminal" else "phux terminal";
    const semantics = if (model.provider.terminalConst(id)) |terminal|
        if (!attached)
            ui.fmt("{s}, {s}, detached; shortcut {s}{s}", .{ title, kind_label, shortcut, if (selected) ", selected" else "" })
        else
            ui.fmt("{s}, {s}, {s}; outbound loss {d} bytes; reply loss {d} bytes; input stalled {d} times; native delivery failures {d}; copy {s}; paste {s}; shortcut {s}{s}", .{
                title,
                kind_label,
                paneLifecycleText(ui, terminal),
                terminal.outbound_dropped,
                terminal.session.response_bytes_dropped,
                terminal.write_refusals,
                terminal.native_delivery_failures,
                if (terminal.copy_failed) "failed" else "ok",
                if (model.paste_owner.terminal_ref.eql(terminal.id) and model.paste_failed) "failed" else "ok",
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
    return if (placement == .top)
        ui.el(.segmented_control, .{
            .global_key = trigger_key,
            .size = .sm,
            .text = text,
            .selected = selected,
            .on_press = .{ .select_surface = .{ .terminal = id } },
            .semantics = .{ .label = semantics },
        }, .{})
    else
        ui.listItem(.{
            .global_key = trigger_key,
            .size = .sm,
            .height = side_tab_height,
            .width = side_rail_width,
            .selected = selected,
            .on_press = .{ .select_surface = .{ .terminal = id } },
            .semantics = .{ .role = .tab, .label = semantics },
        }, text);
}

fn webTabTrigger(ui: *TerminalUi, model: *const Model, placement: TabPlacement) TerminalUi.Node {
    const selected = model.selected_surface.eql(.web);
    const shortcut = ui.fmt("CMD+{d}", .{model.terminal_count + 1});
    const semantics = ui.fmt("Web, system WebKit, shortcut {s}{s}", .{ shortcut, if (selected) ", selected" else "" });
    const trigger_key: canvas.UiKey = .{ .index = std.math.maxInt(usize) };
    return if (placement == .top)
        ui.el(.segmented_control, .{
            .global_key = trigger_key,
            .size = .sm,
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
    const title = terminalTitle(ui, model, id);
    if (model.provider.terminalConst(id)) |pane| {
        return ui.fmt("{s}, native terminal, {s}", .{ title, paneLifecycleText(ui, pane) });
    }
    const phase = if (model.remotePresentation(id)) |presentation|
        remoteLifecycleText(presentation.phase)
    else
        "UNAVAILABLE";
    return ui.fmt("{s}, phux terminal, {s}", .{ title, phase });
}

fn terminalSurface(ui: *TerminalUi, model: *const Model, index: usize) TerminalUi.Node {
    const placement = placementAt(index);
    const terminal_ref = model.attachments[placement.index()] orelse return ui.el(.stack, .{
        .global_key = .{ .index = index },
        .grow = 1,
        .min_width = split_pane_min_width,
        .semantics = .{ .role = .group, .label = "Detached terminal placement" },
    }, .{});
    // A remote terminal has no local pane: it still contributes a focusable
    // surface with its published screen text, but no local copy/paste menu
    // and no local mouse-protocol policy.
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
            .global_key = .{ .index = index },
            .grow = 1,
            .min_width = split_pane_min_width,
            .opacity = 0,
            .text = screen,
            .on_press = .{ .focus_pane = placement },
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
        .opacity = 0,
        .text = screen,
        .on_press = .{ .focus_pane = placement },
        .context_menu = &context_menu,
        .context_menu_policy = if (paneReportsMouse(local_pane)) .disabled else .automatic,
        .semantics = .{
            .focusable = true,
            .label = terminalSurfaceLabel(ui, model, local_pane.id),
        },
    });
}

fn splitTerminalSurface(ui: *TerminalUi, model: *const Model, index: usize) TerminalUi.Node {
    return ui.column(.{ .grow = 1, .min_width = split_pane_min_width }, .{
        ui.row(.{ .height = split_pane_header_height, .cross = .center }, .{
            paneStatus(ui, model, index, true),
        }),
        terminalSurface(ui, model, index),
    });
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
    var triggers: [max_terminal_count + 1]TerminalUi.Node = undefined;
    for (&triggers) |*node| node.* = ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    for (model.terminal_order[0..model.terminal_count], 0..) |id, index| {
        triggers[index] = terminalTabTrigger(ui, model, id, index, model.tab_placement);
    }
    triggers[model.terminal_count] = webTabTrigger(ui, model, model.tab_placement);

    const terminal_index = model.selectedTerminalIndex();
    const top_context_controls = if (terminal_index) |index|
        if (model.layout == .single)
            paneStatus(ui, model, index, false)
        else
            ui.el(.stack, .{}, .{})
    else
        ui.row(.{ .gap = 6, .cross = .center }, .{
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .github } }, "GitHub"),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .superlogical } }, "Superlogical"),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .article } }, "Mitchell"),
        });

    const close_available = selectedTerminalCanClose(model);
    const top_topology_controls = ui.row(.{ .gap = 4, .cross = .center }, .{
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .disabled = model.terminal_count >= max_terminal_count or model.provider.occupiedCount() >= max_terminal_count,
            .on_press = .new_terminal,
            .semantics = .{ .label = "New Terminal, Command T" },
        }, "New"),
        if (close_available) ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .close_terminal,
            .semantics = .{ .label = "Close Terminal, Command W" },
        }, "Close") else emptyStatusNode(ui),
    });

    const revealed = chromeRevealed(model);
    const top_header = if (revealed and model.tab_placement == .top) ui.row(.{ .height = header_height, .gap = 12, .cross = .center, .window_drag = true }, .{
        ui.el(.tabs, .{ .gap = 2, .semantics = .{ .label = "Surfaces" } }, .{
            triggers[0],
            triggers[1],
            triggers[2],
            triggers[3],
            triggers[4],
        }),
        ui.spacer(1),
        top_context_controls,
        top_topology_controls,
        ui.el(.toggle_button, .{
            .size = .sm,
            .text = "Split",
            .selected = model.layout == .split,
            .disabled = !splitAvailable(model),
            .on_press = .toggle_split,
            .semantics = .{ .label = "Toggle terminal split, Command D" },
        }, .{}),
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .toggle_tab_placement,
            .semantics = .{ .label = "Move tabs to the side" },
        }, "Side tabs"),
    })
        // At rest there is no band at all. Every control it carried stays
        // reachable: New is cmd+T, Close cmd+W, Split cmd+D, and the surfaces
        // are cmd+1..cmd+5 — the band is presentation, never the only path.
        else ui.el(.stack, .{ .height = 0, .semantics = .{ .hidden = true } }, .{});

    const content = if (terminal_index) |index| blk: {
        const terminals = if (model.layout == .split)
            ui.split(.{
                .grow = 1,
                .gap = split_divider_width,
                .value = model.split_fraction,
                .on_resize = TerminalUi.valueMsg(.split_resized),
                .semantics = .{ .label = "Terminal split" },
            }, .{
                splitTerminalSurface(ui, model, 0),
                splitTerminalSurface(ui, model, 1),
            })
        else
            terminalSurface(ui, model, index);
        // Parking the webview at a one-point anchor preserves its native
        // page state without allowing it to cover or receive input over a
        // terminal tab. v0.7.1 has no non-destructive visibility patch.
        break :blk ui.el(.stack, .{ .grow = 1 }, .{
            terminals,
            parkedWebKitAnchor(ui),
        });
    } else ui.panel(.{
        .grow = 1,
        .semantics = .{ .label = webview_anchor },
    }, .{});

    const side_context_controls = if (terminal_index) |index|
        if (model.layout == .single)
            paneStatus(ui, model, index, false)
        else
            emptyStatusNode(ui)
    else
        ui.column(.{ .gap = 4 }, .{
            ui.button(.{ .width = side_rail_width, .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .github } }, "GitHub"),
            ui.button(.{ .width = side_rail_width, .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .superlogical } }, "Superlogical"),
            ui.button(.{ .width = side_rail_width, .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .article } }, "Mitchell"),
        });
    const side_topology_controls = ui.row(.{ .width = side_rail_width, .gap = 4, .cross = .center }, .{
        ui.button(.{
            .grow = 1,
            .size = .sm,
            .variant = .secondary,
            .disabled = model.terminal_count >= max_terminal_count or model.provider.occupiedCount() >= max_terminal_count,
            .on_press = .new_terminal,
            .semantics = .{ .label = "New Terminal, Command T" },
        }, "New"),
        if (close_available) ui.button(.{
            .grow = 1,
            .size = .sm,
            .variant = .secondary,
            .on_press = .close_terminal,
            .semantics = .{ .label = "Close Terminal, Command W" },
        }, "Close") else emptyStatusNode(ui),
    });
    const side_rail_content = ui.column(.{ .width = side_rail_width, .gap = 8 }, .{
        ui.list(.{ .width = side_rail_width, .gap = 3, .semantics = .{ .label = "Surfaces" } }, .{
            triggers[0],
            triggers[1],
            triggers[2],
            triggers[3],
            triggers[4],
        }),
        ui.spacer(1),
        side_context_controls,
        side_topology_controls,
        ui.el(.toggle_button, .{
            .width = side_rail_width,
            .size = .sm,
            .text = "Split",
            .selected = model.layout == .split,
            .disabled = !splitAvailable(model),
            .on_press = .toggle_split,
            .semantics = .{ .label = "Toggle terminal split, Command D" },
        }, .{}),
        ui.button(.{
            .width = side_rail_width,
            .size = .sm,
            .variant = .secondary,
            .on_press = .toggle_tab_placement,
            .semantics = .{ .label = "Move tabs to the top" },
        }, "Top tabs"),
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
    // `window_drag` is a frame where the window cannot be moved at all. The
    // control band above declares it too, but the control band is not always
    // there — this one is. It sits entirely within the titlebar inset, above
    // the first terminal row, so claiming presses here never costs the
    // terminal a click.
    const titlebar_band = @max(0, workspaceChrome(model, model.surface_size).titlebar_height - grid_inset);
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
///
/// The budgets are partitioned per the policy at the top of this file:
/// commands floor-and-slack (cumulative), text mirrored (per-paint
/// local), glyphs halved (per-paint local).
pub fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    if (model.selectedTerminalIndex() == null) return;
    const frames = paneFrames(model, size);
    const split = model.layout == .split;
    const text_share = (canvas.max_display_list_text_bytes - canvas.terminal_grid.widget_text_reserve) / 2;
    const path_share = (canvas.max_chart_path_elements_per_frame - canvas.terminal_grid.widget_path_reserve) / 2;
    var painted: usize = 0;
    for (frames, 0..) |frame, index| {
        if (frame.width <= 0 or frame.height <= 0) continue;
        const placement = placementAt(index);
        const terminal_ref = model.attachments[placement.index()] orelse continue;
        const first_of_split = split and painted == 0;
        const background_frame = if (painted == 0)
            geometry.RectF.init(0, 0, size.width, size.height)
        else
            frame;
        if (model.provider.terminalConst(terminal_ref)) |pane| {
            try grid.paint(pane.session, builder, .{
                .frame = frame,
                .background_frame = background_frame,
                .tokens = tokens,
                .running = pane.phase == .live or pane.phase == .starting,
                .focused = model.focused and model.focus_placement == placement,
                .selecting = pane.selecting,
                .command_budget = if (first_of_split) chrome_command_envelope / 2 else chrome_command_envelope,
                .text_reserve = canvas.terminal_grid.widget_text_reserve + if (first_of_split) text_share else 0,
                .glyph_budget = if (split) canvas.terminal_grid.widget_glyph_budget / 2 else canvas.terminal_grid.widget_glyph_budget,
                .path_reserve = canvas.terminal_grid.widget_path_reserve + if (first_of_split) path_share else 0,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, terminal_ref)),
            });
        } else {
            const remote = model.phuxConst() orelse continue;
            const presentation = remote.presentation(terminal_ref) orelse continue;
            try grid.paintTerminalGrid(presentation.grid, builder, .{
                .frame = frame,
                .background_frame = background_frame,
                .tokens = tokens,
                .running = presentation.phase == .live,
                .focused = model.focused and model.focus_placement == placement,
                .selecting = if (model.remoteUiConst(terminal_ref)) |state| state.selecting else false,
                .command_budget = if (first_of_split) chrome_command_envelope / 2 else chrome_command_envelope,
                .text_reserve = canvas.terminal_grid.widget_text_reserve + if (first_of_split) text_share else 0,
                .glyph_budget = if (split) canvas.terminal_grid.widget_glyph_budget / 2 else canvas.terminal_grid.widget_glyph_budget,
                .path_reserve = canvas.terminal_grid.widget_path_reserve + if (first_of_split) path_share else 0,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, terminal_ref)),
            });
        }
        painted += 1;
    }
}

/// Frame pump: resize each visible terminal against its actual pane. One
/// resize message is emitted per frame; a second changed split pane follows
/// on the next frame without ever coupling either PTY's lifetime to layout.
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const frame_scale = if (validScale(frame.scale_factor)) frame.scale_factor else model.surface_scale_factor;
    const frames = paneFrames(model, frame.size);
    var pending = false;
    for (0..max_terminal_count) |index| {
        if (model.provider.states[index] != .active) continue;
        const pane = model.provider.slotConst(index);
        if (pane.outbound_len > 0 or pane.session.response_len > 0) pending = true;
    }
    if (model.selectedTerminalIndex() != null) {
        for (frames, 0..) |inner, index| {
            if (inner.width <= 0 or inner.height <= 0) continue;
            const placement = placementAt(index);
            const terminal_ref = model.attachments[placement.index()] orelse continue;
            if (model.provider.terminalConst(terminal_ref)) |pane| {
                const session = pane.session;
                if (session.cell_width <= 0 or session.cell_height <= 0) return if (pending) .flush_outbound else null;
                const proposed = grid.Session.clampGrid(
                    @intFromFloat(@max(2, inner.width / session.cell_width)),
                    @intFromFloat(@max(2, inner.height / session.cell_height)),
                );
                if (proposed.x != pane.cols or proposed.y != pane.rows) {
                    return .{
                        .viewport = .{
                            .terminal_ref = terminal_ref,
                            .cols = proposed.x,
                            .rows = proposed.y,
                            .size = frame.size,
                            // Carry the real scale: the `.viewport` arm commits
                            // whatever arrives, and the field's `= 1` default
                            // would silently reset a Retina surface to 1x on every
                            // local grid resize.
                            .scale_factor = frame_scale,
                        },
                    };
                }
                continue;
            }
            const remote = model.phuxConst() orelse continue;
            if (remote.presentation(terminal_ref) == null) continue;
            const metrics = canvas.terminalCellMetrics(cockpitTokens(model));
            const proposed = grid.Session.clampGrid(
                @intFromFloat(@max(2, inner.width / metrics.width)),
                @intFromFloat(@max(2, inner.height / metrics.height)),
            );
            const viewport: Viewport = .{ .cols = proposed.x, .rows = proposed.y };
            if (remote.lastViewport(terminal_ref) == null or !remote.lastViewport(terminal_ref).?.eql(viewport)) {
                return .{ .viewport = .{
                    .terminal_ref = terminal_ref,
                    .cols = proposed.x,
                    .rows = proposed.y,
                    .size = frame.size,
                    .scale_factor = frame_scale,
                } };
            }
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
    if (std.mem.eql(u8, name, "layout.split")) return .toggle_split;
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
