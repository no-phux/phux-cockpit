//! The seams this app opened onto the toolkit's v0.9.0 surface, and what each
//! of them must do.
//!
//! Every test here covers a channel Cockpit had no answer for until the pin
//! moved: the menu-bar extra, the background-bell notification, file drop,
//! pinch, `theme = auto`, the Minimize verb, the tab's own menu, and tab
//! dragging. They are grouped in one file because they share one cause — the
//! app was several toolkit releases behind its own SDK — and because each is
//! small enough that a file per feature would be more ceremony than test.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const geometry = native_sdk.geometry;
const testing = std.testing;
const startCockpit = support.startCockpit;
const startFocusedTerminal = support.startFocusedTerminal;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const stopCockpit = support.stopCockpit;
const destroyModelSessions = app.deinitModel;

const surface = geometry.SizeF.init(980, 640);

// --------------------------------------------------------- shell quoting

test "a dropped path cannot break out of its shell word" {
    var out: [512]u8 = undefined;
    // Every byte a shell would otherwise act on: a space, a quote, a
    // substitution, a command separator, and a newline.
    const hostile = "/tmp/it's $(rm -rf ~); a\nb/report.txt";
    const quoted = app.quotePaths(&.{hostile}, &out) orelse return error.TestExpectedQuotedPaths;
    try testing.expectEqualStrings("'/tmp/it'\\''s $(rm -rf ~); a\nb/report.txt' ", quoted);
    // The only unquoted quotes in the result are the four the escape itself
    // produces: open, close-for-escape, the escaped literal's own, reopen.
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, quoted, "'"));
}

test "several paths become several words, with a trailing space to type after" {
    var out: [512]u8 = undefined;
    const quoted = app.quotePaths(&.{ "/a/one", "/b/two" }, &out) orelse return error.TestExpectedQuotedPaths;
    try testing.expectEqualStrings("'/a/one' '/b/two' ", quoted);
}

test "a drop that does not fit is refused whole, never truncated" {
    // A buffer that fits the first path and not the second. A partial answer
    // here would paste a DIFFERENT path list than the one dropped.
    var out: [12]u8 = undefined;
    try testing.expect(app.quotePaths(&.{ "/a/one", "/b/two" }, &out) == null);

    var roomy: [512]u8 = undefined;
    try testing.expect(app.quotePaths(&.{}, &roomy) == null);
    try testing.expect(app.quotePaths(&.{""}, &roomy) == null);
    try testing.expect(app.quotePaths(&.{"/a\x00b"}, &roomy) == null);
}

// ------------------------------------------------------------ pinch zoom

test "pinch magnification buys whole points, and only past the threshold" {
    var model: app.Model = .{ .provider = undefined };

    // A twitch is not a resize.
    try testing.expectEqual(@as(i8, 0), model.pinchStep(.change, 0.01));
    try testing.expectEqual(@as(i8, 0), model.pinchStep(.change, 0.01));

    // Enough accumulated magnification steps exactly one point, and the
    // remainder stays for the next event rather than being thrown away.
    try testing.expectEqual(@as(i8, 1), model.pinchStep(.change, app.pinch_points_per_step));
    try testing.expect(model.pinch_scale > 0);

    // Pinching the other way steps down.
    try testing.expectEqual(@as(i8, -1), model.pinchStep(.change, -app.pinch_points_per_step * 2));
}

test "a new gesture does not inherit the last one's leftovers" {
    var model: app.Model = .{ .provider = undefined };
    // Just under a step's worth, twice: without the reset on `.begin` the
    // second gesture would step immediately on a barely-moved finger.
    try testing.expectEqual(@as(i8, 0), model.pinchStep(.change, app.pinch_points_per_step * 0.9));
    try testing.expectEqual(@as(i8, 0), model.pinchStep(.begin, 0));
    try testing.expectEqual(@as(f32, 0), model.pinch_scale);
    try testing.expectEqual(@as(i8, 0), model.pinchStep(.change, app.pinch_points_per_step * 0.9));
}

test "a pinch resizes the type through the same path the chords use" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    const before = state.model.fontSize();
    try state.dispatch(&harness.runtime, 1, .{ .pinch = .{ .phase = .begin } });
    try state.dispatch(&harness.runtime, 1, .{ .pinch = .{ .phase = .change, .scale = app.pinch_points_per_step } });
    try testing.expectEqual(before + 1, state.model.fontSize());
}

// ------------------------------------------------------------ theme = auto

test "theme = auto follows the system into dark and back into light" {
    var config = app.parseConfig("theme = auto");
    try testing.expect(config.follow_system_theme);
    // Something real is in effect before the first appearance event, so no
    // frame is ever painted against a theme that does not exist.
    try testing.expect(config.resolvedTheme() != null);

    try testing.expect(config.adoptSystemTheme(.light));
    try testing.expectEqualStrings(app.theme_auto_light, config.theme.slice());
    try testing.expect(config.adoptSystemTheme(.dark));
    try testing.expectEqualStrings(app.theme_auto_dark, config.theme.slice());
    // Re-reporting the same scheme changes nothing, so nothing downstream
    // repaints for an event that carried no news.
    try testing.expect(!config.adoptSystemTheme(.dark));
}

test "a named theme does not follow the system" {
    var config = app.parseConfig("theme = nord");
    try testing.expect(!config.follow_system_theme);
    try testing.expect(!config.adoptSystemTheme(.light));
    try testing.expectEqualStrings("nord", config.theme.slice());
}

test "choosing a theme ends the subscription" {
    var config = app.parseConfig("theme = auto");
    try testing.expect(config.follow_system_theme);
    // The settings surface's own gesture.
    try testing.expect(config.setTheme("gruvbox-dark"));
    try testing.expect(!config.follow_system_theme);
    // Sunset must not overrule the choice.
    try testing.expect(!config.adoptSystemTheme(.light));
    try testing.expectEqualStrings("gruvbox-dark", config.theme.slice());
}

test "an appearance event reaches the config through update" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    state.model.config = app.parseConfig("theme = auto");
    try state.dispatch(&harness.runtime, 1, .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualStrings(app.theme_auto_light, state.model.config.theme.slice());
}

// ------------------------------------------------- the background-bell banner

test "a bell that rings while the app is in the background notifies once" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const app_iface = state.app();

    try state.dispatch(&harness.runtime, 1, .{ .focus_changed = false });
    try state.effects.feedPtyOutput(app.ptyKey(0), "build finished\x07");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    try testing.expectEqual(@as(u32, 1), state.model.notification_count);
    try testing.expectEqualStrings("Terminal 1", state.model.notifiedTitle());

    // More output while the same bell is still unacknowledged is not a second
    // bell. Without the rising-edge check this is one banner per chunk of
    // output for as long as the latch stands.
    try state.effects.feedPtyOutput(app.ptyKey(0), "more output\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(@as(u32, 1), state.model.notification_count);
}

test "a bell in the window you are looking at is not a notification" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const app_iface = state.app();

    try testing.expect(state.model.focused);
    try state.effects.feedPtyOutput(app.ptyKey(0), "done\x07");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(@as(u32, 0), state.model.notification_count);
}

// ------------------------------------------------------------- file drop

test "dropped paths land in the pane under the pointer, as one bracketed paste" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(state);
    defer destroyModelSessions(&state.model);
    defer state.deinit();

    // A shell that asked for bracketed paste (DECSET 2004), which is the mode
    // a modern prompt turns on and the reason a drop must go through the paste
    // encoder rather than writing bytes at the pty: it is what tells the shell
    // the filenames arriving are DATA, so one with a newline in it cannot run
    // as a command.
    try state.effects.feedPtyOutput(app.ptyKey(0), "\x1b[?2004h");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);

    try state.dispatch(&harness.runtime, 1, .{ .files_dropped = .{
        .view_label = app.canvas_label,
        .point = geometry.PointF.init(200, 200),
        .paths = &.{ "/tmp/a b.txt", "/tmp/second" },
    } });

    const written = state.effects.ptyWrittenBytes(app.ptyKey(0));
    try testing.expect(std.mem.startsWith(u8, written, "\x1b[200~"));
    try testing.expect(std.mem.endsWith(u8, written, "\x1b[201~"));
    try testing.expect(std.mem.indexOf(u8, written, "'/tmp/a b.txt' '/tmp/second' ") != null);
}

test "a drop the host could not place still reaches the focused terminal" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(state);
    defer destroyModelSessions(&state.model);
    defer state.deinit();

    try state.dispatch(&harness.runtime, 1, .{ .files_dropped = .{
        .view_label = app.canvas_label,
        .paths = &.{"/tmp/placeless"},
    } });
    try testing.expect(std.mem.indexOf(u8, state.effects.ptyWrittenBytes(app.ptyKey(0)), "'/tmp/placeless'") != null);
}

test "an empty drop is not a message at all" {
    try testing.expect(app.onDrop(.{ .view_label = app.canvas_label, .paths = &.{} }) == null);
}

// ---------------------------------------------------------- window verbs

test "Cmd+M minimizes the focused window" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try testing.expectEqual(@as(u32, 0), state.effects.window_action_state.minimize_count);
    try state.dispatch(&harness.runtime, 1, .minimize_window);
    try testing.expectEqual(@as(u32, 1), state.effects.window_action_state.minimize_count);
    try testing.expectEqualStrings(app.main_window_label, state.effects.window_action_state.lastLabel());
}

test "the menu bar and the chord name the same command" {
    try testing.expectEqual(app.Msg.minimize_window, app.onCommand("window.minimize").?);
    // The chord has to be REGISTERED as well, or AppKit beeps at a key the app
    // answers — which is exactly how Minimize went missing in the first place.
    var registered = false;
    for (app.cockpit_shortcuts) |shortcut| {
        if (std.mem.eql(u8, shortcut.id, "window.minimize")) registered = true;
    }
    try testing.expect(registered);
}

// -------------------------------------------------------- the tab's menu

test "Close Others keeps the tab it was invoked on, not the selected one" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expectEqual(@as(usize, 3), state.model.wsConst().tab_count);
    const kept = state.model.wsConst().tabTerminal(0) orelse return error.TestExpectedTerminal;

    // Selection is on the newest tab; the menu was opened on the first.
    try state.dispatch(&harness.runtime, 1, .{ .close_other_tabs = 0 });
    try testing.expectEqual(@as(usize, 1), state.model.wsConst().tab_count);
    try testing.expect(app.refEql(kept, state.model.wsConst().tabTerminal(0).?));
}

test "Move Right moves the tab the menu was opened on" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    const first = state.model.wsConst().tabTerminal(0) orelse return error.TestExpectedTerminal;
    const second = state.model.wsConst().tabTerminal(1) orelse return error.TestExpectedTerminal;
    // Selection is on tab 1; the menu acts on tab 0.
    try testing.expectEqual(@as(usize, 1), state.model.wsConst().selected_tab);

    try state.dispatch(&harness.runtime, 1, .{ .move_tab = .{ .index = 0, .delta = 1 } });
    try testing.expect(app.refEql(second, state.model.wsConst().tabTerminal(0).?));
    try testing.expect(app.refEql(first, state.model.wsConst().tabTerminal(1).?));
}

test "the tab strip declares the menu, with its ends disabled" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const app_iface = state.app();

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    var seen_tabs: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.semantics.role != .tab) continue;
        const menu = node.widget.context_menu;
        if (menu.len == 0) continue;
        seen_tabs += 1;
        // Every tab offers the same verbs in the same order; only their
        // enabled-ness moves.
        try testing.expectEqualStrings("New Terminal", menu[0].label);
        try testing.expectEqualStrings("Move Left", menu[2].label);
        try testing.expectEqualStrings("Move Right", menu[3].label);
        try testing.expectEqualStrings("Close", menu[5].label);
        try testing.expectEqualStrings("Close Others", menu[6].label);
    }
    try testing.expect(seen_tabs >= 2);
}

// ---------------------------------------------------------- tab dragging

test "dragging a tab past its neighbour reorders it, live" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    const first = state.model.wsConst().tabTerminal(0) orelse return error.TestExpectedTerminal;
    const extent = app.visibleTabWindow(&state.model, surface.width).extent;

    // Pick tab 0 up and carry it one whole tab to the right.
    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 0, .x = 100 } });
    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 0, .x = 100 + extent } });
    try testing.expect(app.refEql(first, state.model.wsConst().tabTerminal(1).?));

    // The drop has nothing left to do: the tabs are already where they look.
    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 1 } });
    try testing.expect(state.model.tab_drag == null);
    try testing.expect(app.refEql(first, state.model.wsConst().tabTerminal(1).?));
}

test "a cancelled drag puts the tab back where it was picked up" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    const first = state.model.wsConst().tabTerminal(0) orelse return error.TestExpectedTerminal;
    const extent = app.visibleTabWindow(&state.model, surface.width).extent;

    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 0, .x = 100 } });
    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 0, .x = 100 + extent } });
    try testing.expect(app.refEql(first, state.model.wsConst().tabTerminal(1).?));

    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 2 } });
    try testing.expect(state.model.tab_drag == null);
    try testing.expect(app.refEql(first, state.model.wsConst().tabTerminal(0).?));
}

test "a drag that never leaves its own tab moves nothing" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    const first = state.model.wsConst().tabTerminal(0) orelse return error.TestExpectedTerminal;
    const extent = app.visibleTabWindow(&state.model, surface.width).extent;

    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 0, .x = 100 } });
    try state.dispatch(&harness.runtime, 1, .{ .tab_drag = .{ .sourceId = 0, .phase = 0, .x = 100 + extent * 0.4 } });
    try testing.expect(app.refEql(first, state.model.wsConst().tabTerminal(0).?));
}

// --------------------------------------------------------- menu-bar extra

test "the menu-bar extra names every terminal and offers a new one" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);

    var scratch: app.TerminalApp.StatusItemScratch = .{};
    const item = app.statusItem(&state.model, &scratch);
    try testing.expectEqualStrings("PX 2", item.title);
    try testing.expectEqual(native_sdk.platform.TrayTone.normal, item.presentation.tone);

    // Two terminals, a separator, and the trailer.
    try testing.expectEqual(@as(usize, 4), item.items.len);
    try testing.expectEqualStrings("Terminal 1", item.items[0].label);
    try testing.expectEqualStrings("tray.select.0", item.items[0].command);
    try testing.expectEqualStrings("tray.select.1", item.items[1].command);
    try testing.expect(item.items[2].separator);
    try testing.expectEqualStrings("New Terminal", item.items[3].label);
    // Ids are the platform's handle for a row and must be non-zero.
    for (item.items) |row| try testing.expect(row.id != 0);
}

test "a terminal that wants something says so in the menu bar" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const app_iface = state.app();

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    // A bell in a tab nobody is looking at — the case the extra exists for.
    try state.dispatch(&harness.runtime, 1, .{ .focus_changed = false });
    try state.effects.feedPtyOutput(app.ptyKey(0), "\x07");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    var scratch: app.TerminalApp.StatusItemScratch = .{};
    const item = app.statusItem(&state.model, &scratch);
    try testing.expectEqual(native_sdk.platform.TrayTone.warning, item.presentation.tone);
    try testing.expectEqualStrings("needs attention", item.items[0].detail);
    try testing.expectEqualStrings("", item.items[1].detail);
}

test "a menu-bar row goes to its terminal and brings the window forward" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface });
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expectEqual(@as(usize, 1), state.model.wsConst().selected_tab);

    try testing.expectEqual(app.Msg{ .tray_select = 0 }, app.onCommand("tray.select.0").?);
    try state.dispatch(&harness.runtime, 1, .{ .tray_select = 0 });
    try testing.expectEqual(@as(usize, 0), state.model.wsConst().selected_tab);
    // Selecting a tab in a window the user cannot see would be a gesture with
    // no visible effect.
    try testing.expectEqual(@as(u32, 1), state.effects.window_action_state.show_count);
}

test "a tray command naming a tab that cannot exist is refused" {
    try testing.expect(app.onCommand("tray.select.999") == null);
    try testing.expect(app.onCommand("tray.select.") == null);
    try testing.expect(app.onCommand("tray.select.x") == null);
}
