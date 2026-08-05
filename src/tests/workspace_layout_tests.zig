const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");
const support = @import("support.zig");

const geometry = native_sdk.geometry;
const testing = std.testing;

const createSessions = support.createSessions;
const destroyModelSessions = app.deinitModel;
const expectPaneCursorPaintKind = support.expectPaneCursorPaintKind;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const clickCanvas = support.clickCanvas;
const typeCanvasText = support.typeCanvasText;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;
const terminalInteractionFrame = support.terminalInteractionFrame;
const rectCenter = support.rectCenter;
const expectDisplayListMarker = support.expectDisplayListMarker;

test "selected terminal defaults to the first tab and paneFrames has one full content frame" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);
    try testing.expect(model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try testing.expectEqual(@as(?u8, 0), model.selectedTerminalIndex());

    const size = geometry.SizeF.init(980, 640);
    var frames = app.paneFrames(&model, size);
    try testing.expectApproxEqAbs(@as(f32, 8), frames[0].x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 964), frames[0].width, 0.0001);
    try testing.expect(frames[0].height > 0);
    try testing.expectEqual(geometry.RectF{}, frames[1]);

    model.selected_surface = .{ .terminal = app.initialTerminalRef(1) };
    frames = app.paneFrames(&model, size);
    try testing.expectEqual(geometry.RectF{}, frames[0]);
    try testing.expect(frames[1].width > 0);

    model.selected_surface = .web;
    frames = app.paneFrames(&model, size);
    try testing.expectEqual(geometry.RectF{}, frames[0]);
    try testing.expectEqual(geometry.RectF{}, frames[1]);

    model.selected_surface = .{ .terminal = app.initialTerminalRef(0) };
    model.layout = .split;
    model.split_fraction = 0.01;
    frames = app.paneFrames(&model, size);
    try testing.expect(frames[0].width >= app.split_pane_min_width - 0.01);
    try testing.expect(frames[1].width >= app.split_pane_min_width - 0.01);
    model.split_fraction = 0.99;
    frames = app.paneFrames(&model, size);
    try testing.expect(frames[0].width >= app.split_pane_min_width - 0.01);
    try testing.expect(frames[1].width >= app.split_pane_min_width - 0.01);
}

test "the selected terminal interaction surface lands exactly where paneFrames paints" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    for ([_][]const u8{ "1", "2" }, [_][]const u8{ "PANEALPHA", "PANEBRAVO" }) |key, marker| {
        try pressCanvasKey(harness, app_state.app(), key, .{ .primary = true });
        try harness.runtime.dispatchPlatformEvent(app_state.app(), .frame_requested);
        const index = app_state.model.focus_placement.index();
        const expected = app.paneFrames(&app_state.model, size)[index];
        const laid_out = terminalInteractionFrame(harness, marker) orelse return error.TestExpectedTerminalInteractionSurface;
        try testing.expectApproxEqAbs(expected.x, laid_out.x, 0.25);
        try testing.expectApproxEqAbs(expected.y, laid_out.y, 0.25);
        try testing.expectApproxEqAbs(expected.width, laid_out.width, 0.25);
        try testing.expectApproxEqAbs(expected.height, laid_out.height, 0.25);
    }
}

test "Cmd+D projects both live terminals without respawning and collapse keeps the active pane" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    const first_session = app_state.model.panes[0].session;
    const second_session = app_state.model.panes[1].session;
    const generations = [_]u64{
        app_state.model.panes[0].session_generation,
        app_state.model.panes[1].session_generation,
    };

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try releaseCanvasKey(harness, app_iface, "d", .{});
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.LayoutMode.split, app_state.model.layout);
    const frames = app.paneFrames(&app_state.model, size);
    try testing.expect(frames[0].width >= app.split_pane_min_width);
    try testing.expect(frames[1].width >= app.split_pane_min_width);
    try testing.expectApproxEqAbs(
        size.width - 2 * 8,
        frames[0].width + app.split_divider_width + frames[1].width,
        0.001,
    );
    try testing.expect(app_state.model.panes[0].session == first_session);
    try testing.expect(app_state.model.panes[1].session == second_session);
    try testing.expectEqual(generations[0], app_state.model.panes[0].session_generation);
    try testing.expectEqual(generations[1], app_state.model.panes[1].session_generation);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEALPHA", frames[0]);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEBRAVO", frames[1]);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 0, .filled);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .hollow);

    const right_target = rectCenter(frames[1]);
    try clickCanvas(harness, app_iface, right_target.x, right_target.y);
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));

    try pressCanvasKey(harness, app_iface, "arrowleft", .{ .primary = true, .option = true });
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try pressCanvasKey(harness, app_iface, "arrowright", .{ .primary = true, .option = true });
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try typeCanvasText(harness, app_iface, "right");
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("right", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.LayoutMode.single, app_state.model.layout);
    const collapsed = app.paneFrames(&app_state.model, size);
    try testing.expectEqual(@as(f32, 0), collapsed[0].width);
    try testing.expect(collapsed[1].width > 0);
}

test "split divider keyboard resize stays in lockstep with terminal chrome and PTYs" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    var divider: ?geometry.RectF = null;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .split_divider) divider = node.frame;
    }
    const target = rectCenter(divider orelse return error.TestExpectedSplitDivider);
    try clickCanvas(harness, app_iface, target.x, target.y);
    const before = app_state.model.split_fraction;
    try pressCanvasKey(harness, app_iface, "arrowright", .{});
    try testing.expect(app_state.model.split_fraction > before);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    divider = null;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .split_divider) divider = node.frame;
    }
    const drag_start = rectCenter(divider orelse return error.TestExpectedSplitDivider);
    const keyboard_fraction = app_state.model.split_fraction;
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = drag_start.x,
        .y = drag_start.y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_drag,
        .x = drag_start.x + 60,
        .y = drag_start.y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_up,
        .x = drag_start.x + 60,
        .y = drag_start.y,
    } });
    try testing.expect(app_state.model.split_fraction > keyboard_fraction);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    const frames = app.paneFrames(&app_state.model, size);
    for ([_][]const u8{ "PANEALPHA", "PANEBRAVO" }, 0..) |marker, index| {
        const laid_out = terminalInteractionFrame(harness, marker) orelse return error.TestExpectedTerminalInteractionSurface;
        try testing.expectApproxEqAbs(frames[index].x, laid_out.x, 0.25);
        try testing.expectApproxEqAbs(frames[index].width, laid_out.width, 0.25);
    }

    for (2..6) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = size,
            .scale_factor = 2,
            .frame_index = @intCast(frame_index),
            .timestamp_ns = @as(u64, frame_index) * 1_000_000,
        } });
    }
    for (app_state.model.panes, frames) |pane, frame| {
        const expected = grid.Session.clampGrid(
            @intFromFloat(@max(2, frame.width / pane.session.cell_width)),
            @intFromFloat(@max(2, frame.height / pane.session.cell_height)),
        );
        try testing.expectEqual(expected.x, pane.cols);
        try testing.expectEqual(expected.y, pane.rows);
    }
}

test "sub-cell frame changes still update surface geometry" {
    const gpa = testing.allocator;
    const base = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = base });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    for (2..4) |frame_index| try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = base,
        .scale_factor = 2,
        .frame_index = @intCast(frame_index),
        .timestamp_ns = @as(u64, frame_index) * 1_000_000,
    } });
    const cols = app_state.model.panes[0].cols;
    const rows = app_state.model.panes[0].rows;
    const changed = geometry.SizeF.init(base.width + 0.25, base.height + 0.25);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = changed,
        .scale_factor = 2,
        .frame_index = 4,
        .timestamp_ns = 4_000_000,
    } });

    try testing.expectEqual(changed.width, app_state.model.surface_size.width);
    try testing.expectEqual(changed.height, app_state.model.surface_size.height);
    try testing.expectEqual(cols, app_state.model.panes[0].cols);
    try testing.expectEqual(rows, app_state.model.panes[0].rows);
}

test "split PTY grids preserve each pane's full bounded viewport" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });

    const large = geometry.SizeF.init(4000, 2400);
    for (2..7) |frame_index| try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = large,
        .scale_factor = 2,
        .frame_index = @intCast(frame_index),
        .timestamp_ns = @as(u64, frame_index) * 1_000_000,
    } });

    for (app_state.model.panes) |pane| {
        const cells = @as(usize, pane.cols) * @as(usize, pane.rows);
        try testing.expect(cells <= grid.max_cells);
        try testing.expectEqual(@as(u16, grid.max_rows), pane.rows);
    }
}

test "tab cycling crosses terminal and Web surfaces without sending terminal bytes" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "]", .{ .primary = true, .shift = true });
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try releaseCanvasKey(harness, app_iface, "]", .{});
    try pressCanvasKey(harness, app_iface, "]", .{ .primary = true, .shift = true });
    try testing.expect(app_state.model.selected_surface.eql(.web));
    try releaseCanvasKey(harness, app_iface, "]", .{});
    try pressCanvasKey(harness, app_iface, "[", .{ .primary = true, .shift = true });
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "extra modifiers bypass exact spatial shortcuts and reach the terminal" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "]", .{ .primary = true, .shift = true, .control = true });
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    const after_bracket = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try testing.expect(after_bracket > 0);

    try pressCanvasKey(harness, app_iface, "arrowright", .{ .primary = true, .option = true, .shift = true });
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > after_bracket);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    const before_single_pane_chord = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    app_state.model.panes[0].session.feed("\x1b[>11u");
    try pressCanvasKey(harness, app_iface, "arrowright", .{ .primary = true, .option = true });
    try testing.expectEqual(app.LayoutMode.single, app_state.model.layout);
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > before_single_pane_chord);
}

test "spatial shortcut releases never leak into kitty-reporting terminals" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions(80, 24);
    const host = try gpa.create(app.CockpitHost);
    defer gpa.destroy(host);
    host.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    host.inner.effects.executor = .fake;
    const app_iface = host.app();
    try harness.start(app_iface);
    for (host.inner.model.panes) |*pane| pane.session.feed("\x1b[>11u");

    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "layout.split",
        .key = "d",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try releaseCanvasKey(harness, app_iface, "d", .{});

    const cases = [_]struct {
        id: []const u8,
        key: []const u8,
        modifiers: native_sdk.platform.ShortcutModifiers,
    }{
        .{ .id = "tab.next", .key = "]", .modifiers = .{ .primary = true, .shift = true } },
        .{ .id = "tab.previous", .key = "[", .modifiers = .{ .primary = true, .shift = true } },
    };
    for (cases) |case| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
            .id = case.id,
            .key = case.key,
            .window_id = 1,
            .modifiers = case.modifiers,
        } });
        try releaseCanvasKey(harness, app_iface, case.key, .{});
    }
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "repeated global shortcut callbacks are idempotent per physical edge" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions(80, 24);
    const host = try gpa.create(app.CockpitHost);
    defer gpa.destroy(host);
    host.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    host.inner.effects.executor = .fake;
    const app_iface = host.app();
    try harness.start(app_iface);

    const shortcut: native_sdk.ShortcutEvent = .{
        .id = "layout.split",
        .key = "d",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    };
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = shortcut });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try testing.expect(host.global_shortcut_keys_held != 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = shortcut });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);

    try releaseCanvasKey(harness, app_iface, "d", .{});
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = shortcut });
    try testing.expectEqual(app.LayoutMode.single, host.inner.model.layout);

    for (&host.inner.model.provider.terminals) |*pane| pane.session.feed("\x1b[>11u");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.1",
        .key = "1",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try releaseCanvasKey(harness, app_iface, "1", .{});
    try releaseCanvasKey(harness, app_iface, "2", .{});
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "Cmd+1 and Cmd+2 select terminal tabs and route text only to that tab" {
    // THE ACCEPTANCE GATE for the whole spike: mis-routed input shows
    // up as bytes on the wrong pty, not as a subtle rendering
    // difference.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try typeCanvasText(harness, app_iface, "alpha");
    try testing.expectEqualStrings("alpha", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    // cmd+2 moves the keyboard to pane 1.
    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try typeCanvasText(harness, app_iface, "bravo");
    try testing.expectEqualStrings("bravo", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
    // Pane 0's stream is untouched: the chord itself never reached it.
    try testing.expectEqualStrings("alpha", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));

    // ...and back.
    try pressCanvasKey(harness, app_iface, "1", .{ .primary = true });
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try typeCanvasText(harness, app_iface, "!");
    try testing.expectEqualStrings("alpha!", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("bravo", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}
