const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const automation = native_sdk.automation;
const TerminalApp = support.TerminalApp;

const createDefaultSession = support.createDefaultSession;
const activeSlots = support.activeSlots;
const destroyModelSessions = app.deinitModel;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const startCockpit = support.startCockpit;
const startProductionCockpit = support.startProductionCockpit;
const stopCockpit = support.stopCockpit;
const pressCanvasKey = support.pressCanvasKey;
const expectDisplayListMarker = support.expectDisplayListMarker;
const expectDisplayListMissingMarker = support.expectDisplayListMissingMarker;

const cockpit_shot_path = "zig-out/cockpit-native-tabs.png";

test "only the selected terminal paints and hidden terminal state remains live" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const size = geometry.SizeF.init(980, 640);
    // Two TABS: only the selected tab's tree resolves any pane at all.
    var frames = app.paneFrames(&app_state.model, size);
    try testing.expect(frames[0].width > 0);
    try testing.expectEqual(@as(f32, 0), frames[1].width);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEALPHA", frames[0]);
    try expectDisplayListMissingMarker(harness.runtime.views[0].canvasDisplayList(), "PANEBRAVO");

    // Tab 2 accepted output while hidden. Selecting it reveals its existing
    // emulator rather than creating or resetting a surface.
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "HIDDEN STATE\r\n");
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    const hidden_bytes = app_state.model.provider.slots[1].output_bytes;
    try pressCanvasKey(harness, app_state.app(), "2", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .frame_requested);
    frames = app.paneFrames(&app_state.model, size);
    try testing.expect(frames[0].width > 0);
    try testing.expectEqual(@as(f32, 0), frames[1].width);
    try testing.expectEqual(hidden_bytes, app_state.model.provider.slots[1].output_bytes);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEBRAVO", frames[0]);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "HIDDEN STATE", frames[0]);
    try expectDisplayListMissingMarker(harness.runtime.views[0].canvasDisplayList(), "PANEALPHA");
}

test "native tabs and only the selected terminal surface reach accessibility" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    app_state.model.provider.slots[0].copy_failed = true;
    app_state.model.provider.slots[0].outbound_dropped = 7;
    app_state.model.provider.slots[0].session.response_bytes_dropped = 2;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .app_deactivated);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("cockpit"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal tabs") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal 1, native terminal, RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal 2, native terminal, RUNNING") != null);
    // The web surface no longer occupies a seat in a TERMINAL tab strip. It
    // is still reachable — the chord and the View menu both name it — but the
    // strip speaks terminals only.
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Web, system WebKit") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal tabs") != null);
    try testing.expect(app.onCommand("surface.web") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 1 / RUNNING") == null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "outbound loss 7 bytes; reply loss 2 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "copy failed") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal 1") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PANEALPHA") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PANEBRAVO") == null);
    try testing.expect(harness.runtime.sessionStateFingerprint() != 0);

    var terminal_nodes: usize = 0;
    const terminal_id = canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(app.LocalTerminalId.terminal_1)) });
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (layout.widget.id != terminal_id) continue;
        terminal_nodes += 1;
        try testing.expectEqual(canvas.WidgetKind.terminal, layout.widget.kind);
        try testing.expect(std.mem.startsWith(u8, layout.widget.semantics.label, "Terminal 1, native terminal"));
        try testing.expectEqualStrings("PANEALPHA", layout.widget.text[0.."PANEALPHA".len]);
        try testing.expectEqual(@as(?f32, null), layout.widget.semantics.value);
        try testing.expect(layout.widget.semantics.focusable);
    }
    try testing.expectEqual(@as(usize, 1), terminal_nodes);

    // The diagnostic telemetry lives in the accessibility label ONLY. A
    // screen reader keeps everything; the eye keeps nothing. These badges
    // used to be painted as product chrome.
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        for ([_][]const u8{ "I/O LOSS", "DELIVERY FAILED", "INPUT STALLED", "PASTE FAILED", "SELECTING", "PASTING" }) |badge| {
            try testing.expect(!std.mem.eql(u8, layout.widget.text, badge));
        }
        try testing.expect(std.mem.indexOf(u8, layout.widget.text, "COPIED ") == null);
        // The old compaction turned tabs into `T1`/`PHX`, and attention was
        // spelled by appending " !" to the terminal's own name.
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "T1"));
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "PHX"));
        try testing.expect(!std.mem.endsWith(u8, layout.widget.text, " !"));
    }
}

test "cockpit native-tab proof shot (env-gated)" {
    if (comptime !@import("builtin").link_libc) return error.SkipZigTest;
    if (std.c.getenv("COCKPIT_SHOTS") == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, null);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, null, pixels, scratch);

    const encoded = try gpa.alloc(u8, try canvas.png.encodedRgba8ByteLen(shot.width, shot.height));
    defer gpa.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, shot.width, shot.height, shot.rgba8);
    const first = writer.buffered();

    // Deterministic: the same retained frame encodes byte-identically.
    const again = try gpa.alloc(u8, encoded.len);
    defer gpa.free(again);
    var second_writer = std.Io.Writer.fixed(again);
    try canvas.png.writeRgba8(&second_writer, shot.width, shot.height, shot.rgba8);
    try testing.expectEqualSlices(u8, first, second_writer.buffered());

    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cockpit_shot_path, .data = first });
}

const one_terminal_shot_path = "zig-out/cockpit-one-terminal.png";
const four_terminal_shot_path = "zig-out/cockpit-four-terminals.png";
const side_tabs_shot_path = "zig-out/cockpit-side-tabs.png";

/// Four TABS, made through the real `new_terminal` path. The fixture used
/// to start with two eager terminals; the app now starts with one.
fn fillTerminalCapacity(harness: anytype, state: *TerminalApp) !void {
    while (state.model.tab_count < 4) try state.dispatch(&harness.runtime, 1, .new_terminal);
}

test "production launch owns exactly one terminal and New spawns the second child" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startProductionCockpit(harness);
    defer stopCockpit(state);

    try testing.expectEqual(@as(usize, 1), state.model.tab_count);
    try testing.expectEqual(@as(usize, 1), state.model.tabs[0].paneCount());
    try testing.expectEqual(@as(usize, 1), state.model.provider.activeCount());
    try testing.expectEqual(@as(usize, 1), state.model.provider.occupiedCount());
    try testing.expectEqual(@as(usize, 1), state.effects.pendingPtyCount());
    try testing.expect(state.model.tabTerminal(0).?.eql(app.initialTerminalRef(0)));
    try testing.expect(state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try testing.expectEqual(@as(u64, 1), state.model.provider.terminal(app.initialTerminalRef(0)).?.pty_key);
    try testing.expectEqual(@as(u64, 1), state.model.provider.terminal(app.initialTerminalRef(0)).?.session_generation);

    const initial_snapshot = try state.model.topologySnapshot();
    try initial_snapshot.validate();
    try testing.expectEqual(@as(u8, 1), initial_snapshot.tab_count);
    try testing.expect(initial_snapshot.selection.eql(.{ .tab = 0 }));

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expectEqual(@as(usize, 2), state.model.tab_count);
    try testing.expectEqual(@as(usize, 2), state.model.provider.activeCount());
    try testing.expectEqual(@as(usize, 2), state.effects.pendingPtyCount());
    const second = state.model.provider.terminal(app.initialTerminalRef(1)) orelse return error.TestExpectedTerminal;
    try testing.expectEqual(@as(u64, 2), second.pty_key);
    try testing.expectEqual(@as(u64, 1), second.session_generation);
}

test "one terminal shows no control band, and Cmd+D still splits it" {
    // Rewritten: the old gate refused to split until a SECOND tab existed,
    // which is exactly the bug — a fresh window's single terminal is the
    // most ordinary thing there is to split.
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startProductionCockpit(harness);
    defer stopCockpit(state);

    // At rest Cockpit is a terminal, not a frame around one: the band is
    // absent entirely rather than present-and-disabled.
    try testing.expect(!app.chromeRevealed(&state.model));
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        try testing.expect(!std.mem.eql(u8, node.widget.text, "Split"));
        try testing.expect(!std.mem.eql(u8, node.widget.text, "New"));
        try testing.expect(node.widget.kind != .segmented_control);
    }

    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "d",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(@as(usize, 2), state.model.tabs[0].paneCount());
    try testing.expect(state.model.consumed_shortcut_keys_held != 0);
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = "d",
    } });

    // Splitting alone does not summon the band: one tab is still one tab.
    try testing.expect(!app.chromeRevealed(&state.model));

    // A second TAB is real structure, so the band emerges with it — with a
    // tab strip and nothing else. No New/Close/Split/Side-tabs buttons and
    // no hardcoded bookmark buttons.
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expect(app.chromeRevealed(&state.model));
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        for ([_][]const u8{ "New", "Close", "Split", "Side tabs", "Top tabs", "GitHub", "Superlogical", "Mitchell" }) |gone| {
            try testing.expect(!std.mem.eql(u8, node.widget.text, gone));
        }
    }
}

test "one-terminal production accessibility is the terminal alone, and the band emerges with the second" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startProductionCockpit(harness);
    defer stopCockpit(state);
    try state.effects.feedPtyOutput(1, "ONE TERMINAL\r\n");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    const buffer = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("one-terminal"), &writer);
    const a11y = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, a11y, "Terminal 1, native terminal") != null);
    try testing.expect(std.mem.indexOf(u8, a11y, "Terminal 2") == null);
    try testing.expect(std.mem.indexOf(u8, a11y, "ONE TERMINAL") != null);
    // No band at rest means no tab strip and no topology controls in the
    // accessibility tree either — a screen reader hears one terminal, which is
    // what is actually there. cmd+T, cmd+W, and cmd+D still reach the model.
    try testing.expect(std.mem.indexOf(u8, a11y, "Web, system WebKit") == null);
    try testing.expect(std.mem.indexOf(u8, a11y, "New Terminal, Command T") == null);

    var tab_count: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .segmented_control) tab_count += 1;
        try testing.expect(!std.mem.eql(u8, node.widget.text, "TERMINAL 1 / RUNNING"));
    }
    try testing.expectEqual(@as(usize, 0), tab_count);

    // The window stays movable with no band: the titlebar inset carries the
    // drag region unconditionally.
    var saw_window_drag = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.window_drag) saw_window_drag = true;
    }
    try testing.expect(saw_window_drag);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
    var revealed_tabs: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.semantics.role == .tab) revealed_tabs += 1;
    }
    // Two terminals. Nothing else: the strip is terminals only now.
    try testing.expectEqual(@as(usize, 2), revealed_tabs);
}

test "a terminal that needs attention pulls the band back even when it is alone" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startProductionCockpit(harness);
    defer stopCockpit(state);
    try testing.expect(!app.chromeRevealed(&state.model));

    // A lone terminal whose process dies is exactly the case where calm must
    // yield: the band returns so its state and Restart are reachable.
    try state.effects.feedPtyExit(app.ptyKey(0), 1, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try testing.expect(app.chromeRevealed(&state.model));
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    var saw_restart = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.eql(u8, node.widget.text, "Restart")) saw_restart = true;
    }
    try testing.expect(saw_restart);
}

test "revealing the band is the only thing that resizes the content area" {
    const session = try createDefaultSession();
    var model = app.initialModel(session);
    defer app.deinitModel(&model);
    const size = native_sdk.geometry.SizeF.init(980, 640);

    // A second TAB reveals the band.
    const second = try model.provider.createTerminal();
    _ = model.admitTab(second.id);
    try testing.expect(app.chromeRevealed(&model));
    const revealed = app.paneFrames(&model, size)[0];

    // Collapse to one healthy terminal and the content area reclaims exactly
    // the band's height — no more, no less.
    model.dropTab(1);
    _ = model.provider.destroyTerminal(second.id);
    try testing.expect(!app.chromeRevealed(&model));
    const bare = app.paneFrames(&model, size)[0];

    try testing.expectApproxEqAbs(revealed.y - app.header_height, bare.y, 0.0001);
    try testing.expectApproxEqAbs(revealed.height + app.header_height, bare.height, 0.0001);
    try testing.expectApproxEqAbs(revealed.x, bare.x, 0.0001);
    try testing.expectApproxEqAbs(revealed.width, bare.width, 0.0001);
}

test "one-terminal production screenshot (env-gated)" {
    if (comptime !@import("builtin").link_libc) return error.SkipZigTest;
    if (std.c.getenv("COCKPIT_SHOTS") == null) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startProductionCockpit(harness);
    defer stopCockpit(state);
    try state.effects.feedPtyOutput(1, "ONE TERMINAL\r\n");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, null);
    const pixels = try testing.allocator.alloc(u8, pixel_size.byte_len);
    defer testing.allocator.free(pixels);
    const scratch = try testing.allocator.alloc(u8, pixel_size.byte_len);
    defer testing.allocator.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, null, pixels, scratch);
    const encoded = try testing.allocator.alloc(u8, try canvas.png.encodedRgba8ByteLen(shot.width, shot.height));
    defer testing.allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, shot.width, shot.height, shot.rgba8);
    try std.Io.Dir.cwd().createDirPath(testing.io, "zig-out");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = one_terminal_shot_path, .data = writer.buffered() });
}

test "four-terminal accessibility is compact ordered and keyboard-complete" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    try fillTerminalCapacity(harness, state);
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = native_sdk.geometry.SizeF.init(app.window_min_width, app.window_min_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    const buffer = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("four-terminals"), &writer);
    const a11y = writer.buffered();
    for (1..5) |number| {
        var expected: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&expected, "Terminal {d}, native terminal", .{number});
        try testing.expect(std.mem.indexOf(u8, a11y, label) != null);
    }
    try testing.expect(std.mem.indexOf(u8, a11y, "Web, system WebKit") == null);
    // The band carries the tab strip and nothing else: New/Close/Split and
    // the bookmark buttons are gone, and each remains reachable by chord.
    try testing.expect(std.mem.indexOf(u8, a11y, "New Terminal, Command T") == null);
    try testing.expect(std.mem.indexOf(u8, a11y, "Close Terminal, Command W") == null);
    try testing.expect(std.mem.indexOf(u8, a11y, "Move terminal tab left") == null);
    try testing.expect(std.mem.indexOf(u8, a11y, "DETACHED") == null);

    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "5",
        .modifiers = .{ .primary = true },
    } });
    // Four tabs, so cmd+5 addresses nothing. It used to fall through to the
    // Web surface, which meant the chord for a given terminal shifted every
    // time a tab opened; the selection is simply unchanged now.
    try testing.expect(!state.model.web_selected);
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = "5",
    } });
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "4",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(state.model.tabTerminal(3).?, state.model.selectedTerminalId().?);
    try testing.expect(app.onCommand("surface.5") != null);
    // Every menu command the bar declares has to resolve to a message, or the
    // item is a dead entry in a real macOS menu.
    for (app.cockpit_menus) |menu| {
        for (menu.items) |item| {
            if (item.separator) continue;
            try testing.expect(app.onCommand(item.command) != null);
        }
    }
}

test "four-terminal tab layout stays inside the minimum window and shows terminals only" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    try fillTerminalCapacity(harness, state);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    var tab_frames: [app.max_tabs + 1]native_sdk.geometry.RectF = undefined;
    var tab_labels: [app.max_tabs + 1][]const u8 = undefined;
    var tab_count: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.semantics.role != .tab) continue;
        tab_frames[tab_count] = node.frame;
        tab_labels[tab_count] = node.widget.semantics.label;
        tab_count += 1;
    }
    // Four terminals, four tabs. The Web surface is not one of them.
    try testing.expectEqual(@as(usize, 4), tab_count);
    for (tab_frames[0..tab_count], 0..) |frame, index| {
        try testing.expect(frame.width > 0 and frame.height > 0);
        try testing.expect(frame.x >= 0 and frame.x + frame.width <= app.window_min_width);
        if (index > 0) try testing.expect(frame.x >= tab_frames[index - 1].x + tab_frames[index - 1].width);
    }
    // Labels stay WHOLE. The old compaction turned every tab into `T1`/`PHX`
    // as soon as a fourth surface existed, which is not a tab strip.
    try testing.expect(std.mem.startsWith(u8, tab_labels[0], "Terminal 1,"));
    try testing.expect(std.mem.startsWith(u8, tab_labels[3], "Terminal 4,"));
    for (tab_labels[0..tab_count]) |label| {
        try testing.expect(std.mem.indexOf(u8, label, "Web") == null);
    }

    // Every tab carries a close affordance reachable without the keyboard,
    // and the strip ends in a New Terminal button.
    var saw_close = false;
    var saw_new = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.startsWith(u8, node.widget.semantics.label, "Close Terminal")) saw_close = true;
        if (std.mem.startsWith(u8, node.widget.semantics.label, "New terminal")) saw_new = true;
    }
    try testing.expect(saw_close);
    try testing.expect(saw_new);
}

test "side tabs remain accessible and bounded at the minimum window" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    try fillTerminalCapacity(harness, state);
    try state.dispatch(&harness.runtime, 1, .toggle_tab_placement);
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = native_sdk.geometry.SizeF.init(app.window_min_width, app.window_min_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    var previous_y: f32 = -1;
    var tab_count: usize = 0;
    var saw_scroll_region = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .scroll_view and std.mem.eql(u8, node.widget.semantics.label, "Workspace controls")) {
            saw_scroll_region = true;
            try testing.expect(node.frame.y >= 0);
            try testing.expect(node.frame.y + node.frame.height <= app.window_min_height);
        }
        if (node.widget.kind != .list_item) continue;
        try testing.expectEqual(canvas.WidgetRole.tab, node.widget.semantics.role);
        try testing.expect(node.frame.x >= 0 and node.frame.x + node.frame.width <= app.side_rail_width + 8);
        try testing.expect(node.frame.y > previous_y);
        previous_y = node.frame.y;
        tab_count += 1;
    }
    try testing.expect(saw_scroll_region);
    try testing.expectEqual(@as(usize, 4), tab_count);
}

test "four-terminal compact chrome screenshot (env-gated)" {
    if (comptime !@import("builtin").link_libc) return error.SkipZigTest;
    if (std.c.getenv("COCKPIT_SHOTS") == null) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    try fillTerminalCapacity(harness, state);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, null);
    const pixels = try testing.allocator.alloc(u8, pixel_size.byte_len);
    defer testing.allocator.free(pixels);
    const scratch = try testing.allocator.alloc(u8, pixel_size.byte_len);
    defer testing.allocator.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, null, pixels, scratch);
    const encoded = try testing.allocator.alloc(u8, try canvas.png.encodedRgba8ByteLen(shot.width, shot.height));
    defer testing.allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, shot.width, shot.height, shot.rgba8);
    try std.Io.Dir.cwd().createDirPath(testing.io, "zig-out");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = four_terminal_shot_path, .data = writer.buffered() });
}

test "side tabs and bundled terminal glyphs screenshot (env-gated)" {
    if (comptime !@import("builtin").link_libc) return error.SkipZigTest;
    if (std.c.getenv("COCKPIT_SHOTS") == null) return error.SkipZigTest;
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    try fillTerminalCapacity(harness, state);
    try state.dispatch(&harness.runtime, 1, .toggle_tab_placement);
    try state.dispatch(&harness.runtime, 1, .{ .select_surface = .{ .terminal = app.initialTerminalRef(0) } });
    const pane = state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    try state.effects.feedPtyOutput(pane.pty_key, "\x1b[38;2;190;242;100m\u{f120}  PHUX COCKPIT\x1b[0m\r\n\u{e0a0} main   \u{f013} native agent terminal\r\n");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, null);
    const pixels = try testing.allocator.alloc(u8, pixel_size.byte_len);
    defer testing.allocator.free(pixels);
    const scratch = try testing.allocator.alloc(u8, pixel_size.byte_len);
    defer testing.allocator.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, null, pixels, scratch);
    const encoded = try testing.allocator.alloc(u8, try canvas.png.encodedRgba8ByteLen(shot.width, shot.height));
    defer testing.allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, shot.width, shot.height, shot.rgba8);
    try std.Io.Dir.cwd().createDirPath(testing.io, "zig-out");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = side_tabs_shot_path, .data = writer.buffered() });
}
