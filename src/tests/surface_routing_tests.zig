const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const automation = native_sdk.automation;
const TerminalApp = support.TerminalApp;

const createSessions = support.createSessions;
const createDefaultSessions = support.createDefaultSessions;
const destroyModelSessions = app.deinitModel;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const startProductionCockpit = support.startProductionCockpit;
const stopCockpit = support.stopCockpit;
const clickCanvas = support.clickCanvas;
const typeCanvasText = support.typeCanvasText;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;
const rectCenter = support.rectCenter;

const pointer_support = @import("pointer_support.zig");
const startPointerHost = pointer_support.startPointerHost;
const pointerInput = pointer_support.pointerInput;
const activePointerCaptureCount = pointer_support.activePointerCaptureCount;
const remoteRef = support.remoteTerminalRef;

test "stable surface IDs and browser messages make focused model transitions" {
    const sessions = try createSessions(80, 24);
    var app_state = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app.deinitModel(&app_state.model);
    defer app_state.deinit();
    app_state.effects.executor = .fake;

    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try testing.expectEqual(app.BrowserPage.github, app_state.model.browser_page);
    try testing.expectEqual(@as(?u8, 0), app_state.model.selectedTerminalIndex());

    app.update(&app_state.model, .{ .select_surface = .{ .terminal = app.initialTerminalRef(1) } }, &app_state.effects);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expectEqual(@as(?u8, 1), app_state.model.selectedTerminalIndex());

    app.update(&app_state.model, .{ .browser_page = .article }, &app_state.effects);
    try testing.expect(app_state.model.selected_surface.eql(.web));
    try testing.expectEqual(app.BrowserPage.article, app_state.model.browser_page);
    try testing.expectEqual(@as(?u8, null), app_state.model.selectedTerminalIndex());
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);

    try testing.expectEqual(@as(u64, 1), app_state.model.browser_navigation_token);
    app.update(&app_state.model, .{ .select_surface = .{ .terminal = app.initialTerminalRef(0) } }, &app_state.effects);
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expectEqual(app.BrowserPage.article, app_state.model.browser_page);
}

test "Cmd+3 selects accessible Web and non-terminal selection blocks terminal input" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    var line: [24]u8 = undefined;
    for (0..80) |index| app_state.model.panes[0].session.feed(std.fmt.bufPrint(&line, "history {d}\r\n", .{index}) catch unreachable);
    const bottom = app_state.model.panes[0].session.scrollbar().offset;
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);

    try pressCanvasKey(harness, app_iface, "3", .{ .primary = true });
    try testing.expect(app_state.model.selected_surface.eql(.web));
    try testing.expectEqual(@as(?u8, null), app_state.model.selectedTerminalIndex());
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingClipboardCount());

    const before0 = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    const before1 = app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len;
    try pressCanvasKey(harness, app_iface, "arrowup", .{});
    try typeCanvasText(harness, app_iface, "blocked");
    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true });
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true });
    for ([_]f32{ 100, 500 }) |x| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .scroll,
            .x = x,
            .y = 300,
            .delta_y = app_state.model.panes[0].session.cell_height * 4,
        } });
    }
    try testing.expectEqual(before0, app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
    try testing.expectEqual(before1, app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len);
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingClipboardCount());
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(bottom, app_state.model.panes[0].session.scrollbar().offset);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("web"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Web, system WebKit") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), app.webview_anchor) != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "GitHub") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "GitHub") != null);

    // The platform shortcut path, not a synthetic canvas key, escapes native
    // WebKit focus. Its later physical release is latched and cannot leak to
    // a terminal using kitty key-release reporting.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    const scratch_before_release = app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len;
    try releaseCanvasKey(harness, app_iface, "2", .{});
    try testing.expectEqual(scratch_before_release, app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len);
}

test "web pane root-navigation bindings are exact" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    try testing.expectEqualStrings("https://github.com/phall1", app.BrowserPage.github.url());
    try testing.expectEqualStrings("https://www.superlogical.com/", app.BrowserPage.superlogical.url());
    try testing.expectEqualStrings("https://mitchellh.com/writing/superlogical", app.BrowserPage.article.url());

    var panes: [1]TerminalApp.WebViewPane = undefined;
    try testing.expectEqual(@as(usize, 1), app.webPanes(&app_state.model, &panes));
    try testing.expectEqualStrings(app.webview_label, panes[0].label);
    try testing.expectEqualStrings(app.webview_anchor, panes[0].anchor.?);
    try testing.expectEqualStrings(app.BrowserPage.github.url(), panes[0].url);
    try testing.expectEqual(@as(u64, 0), panes[0].reload_token);

    try testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
    try testing.expectEqualStrings(app.webview_label, harness.null_platform.webviews[0].label);
    try testing.expect(harness.null_platform.webviews[0].frame.width <= app.webkit_parking_extent);
    try testing.expect(harness.null_platform.webviews[0].frame.height <= app.webkit_parking_extent);
    const navigations = harness.null_platform.webview_navigate_count;
    try app_state.dispatch(&harness.runtime, 1, .{ .browser_page = .superlogical });
    try testing.expect(app_state.model.selected_surface.eql(.web));
    try testing.expectEqualStrings(app.BrowserPage.superlogical.url(), harness.null_platform.webviews[0].url);
    try testing.expectEqual(navigations + 1, harness.null_platform.webview_navigate_count);
    try testing.expectEqual(@as(u64, 1), app_state.model.browser_navigation_token);
    const web_frame = harness.null_platform.webviews[0].frame;
    try testing.expect(web_frame.x >= 0);
    try testing.expect(web_frame.y >= app.header_height);
    try testing.expect(web_frame.width > 500);
    try testing.expect(web_frame.height > 300);

    // Reopening the same root forces a fresh app-owned navigation even if
    // WebKit followed links without a committed-navigation callback.
    try app_state.dispatch(&harness.runtime, 1, .{ .browser_page = .superlogical });
    try testing.expectEqualStrings(app.BrowserPage.superlogical.url(), harness.null_platform.webviews[0].url);
    try testing.expectEqual(navigations + 2, harness.null_platform.webview_navigate_count);
    try testing.expectEqual(@as(u64, 2), app_state.model.browser_navigation_token);
}

test "native tab shortcuts transfer first responder between canvas and WebKit" {
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

    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.3",
        .key = "3",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(host.inner.model.selected_surface.eql(.web));
    var views_buffer: [4]native_sdk.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    var canvas_focused = false;
    var web_focused = false;
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.canvas_label)) canvas_focused = item.focused;
        if (std.mem.eql(u8, item.label, app.webview_label)) web_focused = item.focused;
    }
    try testing.expect(!canvas_focused);
    try testing.expect(web_focused);

    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(host.inner.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    views = harness.runtime.listViews(1, &views_buffer);
    canvas_focused = false;
    web_focused = false;
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.canvas_label)) canvas_focused = item.focused;
        if (std.mem.eql(u8, item.label, app.webview_label)) web_focused = item.focused;
    }
    try testing.expect(canvas_focused);
    try testing.expect(!web_focused);

    // Key-up for Cmd+3 stayed with WebKit, but a later Cmd+3 must still work.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.3",
        .key = "3",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(host.inner.model.selected_surface.eql(.web));
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "surface.2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(host.inner.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
}

test "pointer tab actions return focus to terminal content and hand off WebKit" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
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
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    var terminal_2_frame: ?geometry.RectF = null;
    var web_frame: ?geometry.RectF = null;
    var split_frame: ?geometry.RectF = null;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .segmented_control and
            std.mem.indexOf(u8, node.widget.semantics.label, "Terminal 2, native terminal") != null) terminal_2_frame = node.frame;
        if (std.mem.indexOf(u8, node.widget.semantics.label, "Web, system WebKit") != null) web_frame = node.frame;
        if (std.mem.eql(u8, node.widget.text, "Split")) split_frame = node.frame;
    }
    var terminal_1_id: ?canvas.ObjectId = null;
    var web_id: ?canvas.ObjectId = null;
    for (harness.runtime.views[0].widgetSemantics()) |node| {
        // Only a TAB label carries its shortcut; the terminal surface shares
        // the descriptive prefix but is not a selector.
        if (std.mem.indexOf(u8, node.label, "Terminal 1, native terminal") != null and
            std.mem.indexOf(u8, node.label, "shortcut CMD+") != null) terminal_1_id = node.id;
        if (std.mem.indexOf(u8, node.label, "Web, system WebKit") != null) web_id = node.id;
    }
    var target = rectCenter(split_frame orelse return error.TestExpectedSplitControl);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.LayoutMode.single, host.inner.model.layout);

    target = rectCenter(terminal_2_frame orelse return error.TestExpectedTab);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.Placement.secondary, host.inner.model.focus_placement);
    try testing.expect(host.inner.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);

    try pressCanvasKey(harness, app_iface, "enter", .{});
    try pressCanvasKey(harness, app_iface, "space", .{});
    try pressCanvasKey(harness, app_iface, "arrowup", .{});
    try testing.expect(host.inner.effects.ptyWrittenBytes(app.ptyKey(1)).len > 2);
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));

    target = rectCenter(web_frame orelse return error.TestExpectedTab);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expect(host.inner.model.selected_surface.eql(.web));
    var views_buffer: [4]native_sdk.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.webview_label)) try testing.expect(item.focused);
    }

    // The tab band remains canvas-owned above WebKit, so it can bring the
    // terminal back and clear the tab control's own widget focus atomically.
    target = rectCenter(terminal_2_frame.?);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expect(host.inner.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.canvas_label)) try testing.expect(item.focused);
        if (std.mem.eql(u8, item.label, app.webview_label)) try testing.expect(!item.focused);
    }

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app_iface, 1, app.canvas_label, .{
        .id = web_id orelse return error.TestExpectedTab,
        .action = .press,
    });
    try testing.expect(host.inner.model.selected_surface.eql(.web));
    views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| if (std.mem.eql(u8, item.label, app.webview_label)) try testing.expect(item.focused);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app_iface, 1, app.canvas_label, .{
        .id = terminal_1_id orelse return error.TestExpectedTab,
        .action = .press,
    });
    try testing.expect(host.inner.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| if (std.mem.eql(u8, item.label, app.canvas_label)) try testing.expect(item.focused);
}

test "native tabs are keyboard focusable without stealing initial terminal input" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    var tab_count: usize = 0;
    for (harness.runtime.views[0].widgetSemantics()) |node| {
        if (node.role == .tab) {
            try testing.expect(node.focusable);
            tab_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), tab_count);
    try testing.expectEqual(
        canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(app.LocalTerminalId.terminal_1)) }),
        harness.runtime.views[0].canvas_widget_focused_id,
    );
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try testing.expectEqualStrings("\r", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "terminal overlays are stable identity-keyed and isolate chrome divider and Web" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const host = try startPointerHost(gpa, harness, size);
    defer gpa.destroy(host);
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    const app_iface = host.app();

    try host.inner.dispatch(&harness.runtime, 1, .toggle_split);
    const expected = app.paneFrames(&host.inner.model, size);
    var overlays: [app.pane_count]geometry.RectF = @splat(.{});
    var overlay_count: usize = 0;
    var divider: geometry.RectF = .{};
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .terminal and
            (node.widget.id == canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(app.LocalTerminalId.terminal_1)) }) or
                node.widget.id == canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(app.LocalTerminalId.terminal_2)) })))
        {
            const id: usize = if (node.widget.id == canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(app.LocalTerminalId.terminal_1)) }))
                0
            else if (node.widget.id == canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(app.LocalTerminalId.terminal_2)) }))
                1
            else
                return error.UnexpectedTerminalOverlay;
            overlays[id] = node.frame;
            overlay_count += 1;
            try testing.expectEqual(@as(f32, 0), node.widget.opacity);
            try testing.expect(node.widget.semantics.focusable);
        }
        if (node.widget.kind == .split_divider) divider = node.frame;
    }
    try testing.expectEqual(app.pane_count, overlay_count);
    for (overlays, expected) |actual, frame| try testing.expectEqualDeep(frame, actual);

    const header_point = geometry.PointF.init(size.width / 2, expected[0].y - 8);
    try pointerInput(harness, app_iface, .pointer_down, header_point, 0, .{}, 0);
    try pointerInput(harness, app_iface, .pointer_up, header_point, 0, .{}, 0);
    try testing.expectEqual(@as(usize, 0), activePointerCaptureCount(&host.inner.model));
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(1)));

    const divider_point = rectCenter(divider);
    try pointerInput(harness, app_iface, .pointer_down, divider_point, 0, .{}, 0);
    try testing.expectEqual(@as(usize, 0), activePointerCaptureCount(&host.inner.model));

    try host.inner.dispatch(&harness.runtime, 1, .{ .select_surface = .web });
    try pointerInput(harness, app_iface, .pointer_down, rectCenter(expected[0]), 0, .{}, 0);
    try testing.expectEqual(@as(usize, 0), activePointerCaptureCount(&host.inner.model));
}

test "remote focus is derived from selection, attachment, and window key state" {
    const sessions = try createDefaultSessions();
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);

    const remote = try remoteRef(71);
    model.attachments[0] = remote;
    model.focus_placement = .primary;
    model.selected_surface = .{ .terminal = remote };
    model.focused = true;
    try testing.expect(app.remoteFocusTarget(&model).?.eql(remote));

    // Leaving for Web must retract remote focus, and RETURNING to the very
    // same attachment must restore it. Publishing per message arm missed the
    // return, because the attachment never changed.
    model.selected_surface = .web;
    try testing.expectEqual(@as(?app.TerminalRef, null), app.remoteFocusTarget(&model));
    model.selected_surface = .{ .terminal = remote };
    try testing.expect(app.remoteFocusTarget(&model).?.eql(remote));

    // The window losing key retracts it too.
    model.focused = false;
    try testing.expectEqual(@as(?app.TerminalRef, null), app.remoteFocusTarget(&model));
    model.focused = true;

    // A local terminal is not a remote focus target at all.
    model.attachments[0] = app.initialTerminalRef(0);
    model.selected_surface = .{ .terminal = app.initialTerminalRef(0) };
    try testing.expectEqual(@as(?app.TerminalRef, null), app.remoteFocusTarget(&model));
}

test "a local grid resize preserves the surface scale factor" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startProductionCockpit(harness);
    defer stopCockpit(state);

    // The first frame lands before the grid has cell metrics, so drive frames
    // until the local grid actually moves off its 80x24 default. That resize
    // is the message under test: it must carry the real scale, because the
    // `.viewport` arm commits whatever arrives and the field's `= 1` default
    // would silently drop a Retina surface to 1x.
    var frame_index: u64 = 2;
    while (frame_index < 8 and state.model.provider.terminals[0].cols == 80) : (frame_index += 1) {
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = native_sdk.geometry.SizeF.init(700, 420),
            .scale_factor = 2,
            .frame_index = frame_index,
            .timestamp_ns = frame_index * 1_000_000,
        } });
        try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
    }
    try testing.expect(state.model.provider.terminals[0].cols != 80);
    try testing.expectApproxEqAbs(@as(f32, 2), state.model.surface_scale_factor, 0.0001);
}
