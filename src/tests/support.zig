const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

pub const TerminalApp = native_sdk.UiApp(app.Model, app.Msg);

pub fn createSession(cols: u16, rows: u16) !*grid.Session {
    return grid.Session.create(std.heap.page_allocator, testing.io, cols, rows);
}

/// The app now opens with exactly ONE terminal and mints the rest lazily, so
/// the fixtures hand over one session and ask the model for more.
pub fn createDefaultSession() !*grid.Session {
    return grid.Session.create(testing.allocator, testing.io, 80, 24);
}

/// A bare pair of emulators for tests that paint or feed sessions directly,
/// with no model or provider involved.
pub fn createSessions(cols: u16, rows: u16) ![2]*grid.Session {
    var sessions: [2]*grid.Session = undefined;
    var created: usize = 0;
    errdefer for (sessions[0..created]) |session| session.destroy();
    while (created < sessions.len) : (created += 1) {
        sessions[created] = try createSession(cols, rows);
    }
    return sessions;
}

/// The registry's live panes, as a slice. Valid only while no slot has been
/// freed, which holds for fixtures that only ever ADD terminals — a closed
/// terminal leaves a hole whose session is gone.
pub fn activeSlots(model: *app.Model) []app.Pane {
    var end: usize = 0;
    for (model.provider.states, 0..) |state, index| {
        if (state == .active) end = index + 1;
    }
    return model.provider.slots[0..end];
}

pub fn remoteTerminalRef(id: u32) !app.TerminalRef {
    return .{
        .provider_id = .phux,
        .terminal_id = .{ .phux = try app.RemoteTerminalId.fromPhux(0, id, "local") },
    };
}

pub const CursorPaintKind = enum { filled, hollow };

pub fn expectCursorPaintKind(display_list: anytype, expected: CursorPaintKind) !void {
    return expectPaneCursorPaintKind(display_list, 0, expected);
}

pub fn expectPaneCursorPaintKind(display_list: anytype, index: usize, expected: CursorPaintKind) !void {
    const id = grid.cursorCommandId(grid.paneIdBase(index));
    const command = display_list.findCommandById(id) orelse return error.TestExpectedCursor;
    switch (command.command) {
        .fill_rect => try testing.expectEqual(CursorPaintKind.filled, expected),
        .stroke_rect => try testing.expectEqual(CursorPaintKind.hollow, expected),
        else => return error.TestUnexpectedCursorCommand,
    }
}

pub fn startFocusedTerminal(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const session = try createSession(80, 24);
    const app_state = gpa.create(TerminalApp) catch |err| {
        session.destroy();
        return err;
    };
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(session), app.appOptions());
    errdefer {
        app_state.deinit();
        app.deinitModel(&app_state.model);
        gpa.destroy(app_state);
    }
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    return app_state;
}

/// Two TABS, each with one terminal — the shape most routing tests want.
/// The second terminal is minted through the real `new_terminal` path, so
/// the fixture exercises lazy session allocation instead of pre-seeding it.
pub fn startTwoPaneCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    const app_state = try startFocusedTerminal(gpa, harness);
    errdefer {
        app_state.deinit();
        app.deinitModel(&app_state.model);
        gpa.destroy(app_state);
    }
    const app_iface = app_state.app();
    try app_state.dispatch(&harness.runtime, 1, .new_terminal);
    try app_state.dispatch(&harness.runtime, 1, .{ .select_position = 0 });
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    // Land canvas widget focus on the selected terminal AFTER the tab list
    // settled: a rebuild between the click and the assertion clears it.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    return app_state;
}

/// Two PANES in ONE tab, produced by a real split. `PANEALPHA` is the
/// original (left/top), `PANEBRAVO` the pane the split created.
pub fn startSplitCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    const app_state = try startFocusedTerminal(gpa, harness);
    errdefer {
        app_state.deinit();
        app.deinitModel(&app_state.model);
        gpa.destroy(app_state);
    }
    const app_iface = app_state.app();
    try app_state.dispatch(&harness.runtime, 1, .split_right);
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    return app_state;
}

/// The pane rects the painter, the hit targets, and the PTY pump all use.
pub fn resolvedPanes(model: *const app.Model, size: geometry.SizeF, out: []app.LayoutPane) usize {
    return app.resolvePanes(model, size, out);
}

pub fn paneRect(model: *const app.Model, size: geometry.SizeF, terminal_ref: app.TerminalRef) ?geometry.RectF {
    return app.paneFrameFor(model, size, terminal_ref);
}

pub fn startCockpit(harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const session = try createDefaultSession();
    const model = app.initialModelWithIo(testing.allocator, testing.io, session) catch |err| {
        session.destroy();
        return err;
    };
    const state = testing.allocator.create(TerminalApp) catch |err| {
        var owned_model = model;
        app.deinitModel(&owned_model);
        return err;
    };
    state.* = TerminalApp.init(std.heap.page_allocator, model, app.appOptions());
    errdefer stopCockpit(state);
    state.effects.executor = .fake;
    try harness.start(state.app());
    try dispatchInitialFrame(harness, state.app());
    return state;
}

pub fn startProductionCockpit(harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const session = try grid.Session.create(testing.allocator, testing.io, 80, 24);
    const model = app.initialProductionModelWithIo(testing.allocator, testing.io, session) catch |err| {
        session.destroy();
        return err;
    };
    const state = testing.allocator.create(TerminalApp) catch |err| {
        var owned_model = model;
        app.deinitModel(&owned_model);
        return err;
    };
    state.* = TerminalApp.init(std.heap.page_allocator, model, app.appOptions());
    errdefer stopCockpit(state);
    state.effects.executor = .fake;
    try harness.start(state.app());
    try dispatchInitialFrame(harness, state.app());
    return state;
}

fn dispatchInitialFrame(harness: anytype, app_iface: native_sdk.App) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
}

pub fn stopCockpit(state: *TerminalApp) void {
    state.deinit();
    app.deinitModel(&state.model);
    testing.allocator.destroy(state);
}

pub fn clickCanvas(harness: anytype, app_iface: anytype, x: f32, y: f32) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = x,
        .y = y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_up,
        .x = x,
        .y = y,
    } });
}

pub fn typeCanvasText(harness: anytype, app_iface: anytype, text: []const u8) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .text_input,
        .text = text,
    } });
}

pub fn pressCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = key,
        .modifiers = modifiers,
    } });
}

pub fn releaseCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = key,
        .modifiers = modifiers,
    } });
}

pub fn terminalInteractionFrame(harness: anytype, marker: []const u8) ?geometry.RectF {
    const layout = harness.runtime.views[0].widgetLayoutTree();
    for (layout.nodes) |node| {
        if (node.widget.kind != .terminal) continue;
        if (std.mem.indexOf(u8, node.widget.text, marker) == null) continue;
        return node.frame;
    }
    return null;
}

pub fn widgetFrameBySemantics(harness: anytype, label: []const u8) ?geometry.RectF {
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.frame;
    }
    return null;
}

pub fn rectCenter(rect: geometry.RectF) geometry.PointF {
    return geometry.PointF.init(rect.x + rect.width / 2, rect.y + rect.height / 2);
}

pub fn expectDisplayListMarker(display_list: anytype, marker: []const u8, frame: geometry.RectF) !void {
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| if (std.mem.indexOf(u8, text.text, marker) != null) {
                try testing.expect(text.origin.x >= frame.x);
                try testing.expect(text.origin.x < frame.x + frame.width);
                return;
            },
            else => {},
        }
    }
    return error.TestExpectedMarker;
}

pub fn expectDisplayListMissingMarker(display_list: anytype, marker: []const u8) !void {
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| try testing.expect(std.mem.indexOf(u8, text.text, marker) == null),
            else => {},
        }
    }
}
