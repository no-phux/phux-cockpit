//! The tab strip, the split focus treatment, and the in-pane dead-terminal
//! affordance. The complaint these answer was "no thought put in to the tab
//! bar": a fixed 8-slot strip that pinned a web browser as the last terminal
//! tab, offered no close and no new, and named every tab after a number.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const startCockpit = support.startCockpit;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const startSplitCockpit = support.startSplitCockpit;
const stopCockpit = support.stopCockpit;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;

const surface = geometry.SizeF.init(980, 640);

fn tabLabels(harness: anytype, out: [][]const u8) usize {
    var count: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.semantics.role != .tab) continue;
        if (count == out.len) break;
        out[count] = node.widget.semantics.label;
        count += 1;
    }
    return count;
}

fn hasSemanticsPrefix(harness: anytype, prefix: []const u8) bool {
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.startsWith(u8, node.widget.semantics.label, prefix)) return true;
    }
    return false;
}

// ------------------------------------------------------------- the window

test "the visible tab window shrinks tabs before it hides any" {
    var model: app.Model = .{ .provider = undefined };
    model.ws().tab_count = 4;
    // A 900pt window: four tabs at full width would not fit, so they shrink
    // rather than the fourth disappearing.
    const four = app.visibleTabWindow(&model, 900);
    try testing.expectEqual(@as(usize, 0), four.first);
    try testing.expectEqual(@as(usize, 4), four.count);
    try testing.expect(four.extent >= app.tab_min_extent);
    try testing.expect(four.extent <= app.tab_extent);

    // Two tabs in a wide window get the full width, not a stretched one.
    model.ws().tab_count = 2;
    try testing.expectEqual(app.tab_extent, app.visibleTabWindow(&model, 1600).extent);
}

test "every tab is reachable: the window follows the selection past the edge" {
    var model: app.Model = .{ .provider = undefined };
    model.ws().tab_count = app.max_tabs;

    model.ws().selected_tab = 0;
    const head = app.visibleTabWindow(&model, 900);
    try testing.expect(head.count < app.max_tabs);
    try testing.expect(head.contains(0));

    // The tab the old strip could never draw. It is the LAST visible one, and
    // the window is still contiguous and inside the tab list.
    model.ws().selected_tab = app.max_tabs - 1;
    const tail = app.visibleTabWindow(&model, 900);
    try testing.expect(tail.contains(app.max_tabs - 1));
    try testing.expectEqual(tail.first + tail.count, app.max_tabs);
    try testing.expectEqual(head.count, tail.count);

    // Every index is inside SOME window, which is what "reachable" means.
    for (0..app.max_tabs) |index| {
        model.ws().selected_tab = index;
        try testing.expect(app.visibleTabWindow(&model, 900).contains(index));
    }
}

// -------------------------------------------------------------- the strip

test "the strip shows terminals only and still reaches the web surface" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();

    var labels: [8][]const u8 = undefined;
    const count = tabLabels(harness, &labels);
    try testing.expectEqual(@as(usize, 2), count);
    for (labels[0..count]) |label| {
        try testing.expect(std.mem.indexOf(u8, label, "Web") == null);
    }

    // Kept, not deleted: the surface, its pane declaration and its scene
    // wiring are all still there, and two paths reach it.
    var panes: [2]app.TerminalApp.WebViewPane = undefined;
    try testing.expectEqual(@as(usize, 1), app.webPanes(&state.model, support.mainChromeContext(), &panes));
    try testing.expectEqualStrings(app.webview_label, panes[0].label);
    try testing.expect(app.onCommand("surface.web") != null);

    try pressCanvasKey(harness, state.app(), "b", .{ .primary = true, .shift = true });
    try testing.expect(state.model.ws().web_selected);
}

test "a tab carries a close affordance and the strip ends in a new-tab button" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();

    try testing.expect(hasSemanticsPrefix(harness, "Close Terminal"));
    try testing.expect(hasSemanticsPrefix(harness, "New terminal"));

    // The `x` closes the WHOLE tab, panes and all — that is what a tab's
    // close means, as distinct from cmd+W closing one pane.
    try state.dispatch(&harness.runtime, 1, .split_right);
    try testing.expectEqual(@as(usize, 2), state.model.ws().tab_count);
    try testing.expectEqual(@as(usize, 2), state.model.treeConst(state.model.ws().selected_tab).?.paneCount());
    const doomed = state.model.ws().selected_tab;
    try state.dispatch(&harness.runtime, 1, .{ .close_tab = @intCast(doomed) });
    try testing.expectEqual(@as(usize, 1), state.model.ws().tab_count);
}

test "the new-tab button mints a tab through the same path as cmd+T" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try testing.expectEqual(@as(usize, 1), state.model.ws().tab_count);
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expectEqual(@as(usize, 2), state.model.ws().tab_count);
    try testing.expectEqual(@as(usize, 1), state.model.ws().selected_tab);
}

test "the close affordance appears on the selected tab and on the hovered one" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const iface = state.app();

    // Tab 0 is selected, so exactly one close button exists.
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    var closes: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.startsWith(u8, node.widget.semantics.label, "Close ")) closes += 1;
    }
    try testing.expectEqual(@as(usize, 1), closes);

    // Hovering the OTHER tab reveals its own, without turning the strip into
    // a row of buttons.
    try state.dispatch(&harness.runtime, 1, .{ .hover_tab = 1 });
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    closes = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.startsWith(u8, node.widget.semantics.label, "Close ")) closes += 1;
    }
    try testing.expectEqual(@as(usize, 2), closes);

    try state.dispatch(&harness.runtime, 1, .unhover_tab);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    closes = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.startsWith(u8, node.widget.semantics.label, "Close ")) closes += 1;
    }
    try testing.expectEqual(@as(usize, 1), closes);
}

// ------------------------------------------------------------- tab titles

test "a tab prefers the shell title, then the pwd leaf, then its number" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    var labels: [4][]const u8 = undefined;

    // 3. No title, no pwd: the number, which is always true.
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    // One healthy tab hides the band, so ask the projection directly by
    // opening a second tab first.
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    var count = tabLabels(harness, &labels);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(std.mem.startsWith(u8, labels[0], "Terminal 1,"));

    // 2. OSC 7 alone gives the directory's LAST component, not the whole path.
    try state.effects.feedPtyOutput(app.ptyKey(0), "\x1b]7;file://host/Users/phall/workspace/phux-cockpit\x1b\\");
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    count = tabLabels(harness, &labels);
    try testing.expect(std.mem.startsWith(u8, labels[0], "phux-cockpit,"));

    // 1. A shell title outranks the directory.
    try state.effects.feedPtyOutput(app.ptyKey(0), "\x1b]2;zig build test\x07");
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    count = tabLabels(harness, &labels);
    try testing.expect(std.mem.startsWith(u8, labels[0], "zig build test,"));
}

// ---------------------------------------------------------------- the bell

test "a bell on a hidden tab raises the marker and looking at it clears it" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const iface = state.app();

    const hidden = state.model.tabTerminal(1).?;
    try testing.expect(!app.terminalNeedsAttention(&state.model, hidden));

    // BEL on the tab you are NOT looking at.
    try state.effects.feedPtyOutput(app.ptyKey(1), "build done\x07");
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    try testing.expect(app.terminalNeedsAttention(&state.model, hidden));

    // It paints as a dot, not as punctuation in the terminal's name.
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    var saw_marker = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.eql(u8, node.widget.icon, "circle-dot")) saw_marker = true;
        try testing.expect(std.mem.indexOf(u8, node.widget.text, "!") == null);
    }
    try testing.expect(saw_marker);

    // Selecting the tab is the acknowledgement.
    try state.dispatch(&harness.runtime, 1, .{ .select_position = 1 });
    try testing.expect(!app.terminalNeedsAttention(&state.model, hidden));
}

test "a bell that rings while the window is in the background survives" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    try harness.runtime.dispatchPlatformEvent(iface, .app_deactivated);
    try state.effects.feedPtyOutput(app.ptyKey(0), "\x07");
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    // Backgrounded: the bell is exactly the one worth keeping, so the marker
    // is still up when the user comes back.
    try testing.expect(app.terminalNeedsAttention(&state.model, app.initialTerminalRef(0)));
}

// ------------------------------------------------------- split focus + dead

test "an unfocused split pane is dimmed and a lone pane is not" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    // One pane: nothing to disambiguate, so no scrim at all.
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(app.pane_dim_command_id_base) == null);
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(app.pane_dim_command_id_base + 1) == null);

    try state.dispatch(&harness.runtime, 1, .split_right);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);

    // Exactly ONE of the two panes is dimmed: the one that is not focused.
    const first = harness.runtime.views[0].canvasDisplayList().findCommandById(app.pane_dim_command_id_base);
    const second = harness.runtime.views[0].canvasDisplayList().findCommandById(app.pane_dim_command_id_base + 1);
    try testing.expect((first == null) != (second == null));
    const scrim = first orelse second.?;
    switch (scrim.command) {
        .fill_rect => |fill| {
            try testing.expect(fill.rect.width > 0 and fill.rect.height > 0);
            // A SCRIM, not a paint-over: the terminal beneath still reads.
            try testing.expect(fill.fill.color.a > 0 and fill.fill.color.a < 1);
        },
        else => return error.TestExpectedScrim,
    }

    // Losing key focus stops the dimming: with nothing focused, marking one
    // pane as "the other one" would be a lie.
    try harness.runtime.dispatchPlatformEvent(iface, .app_deactivated);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(app.pane_dim_command_id_base) == null);
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(app.pane_dim_command_id_base + 1) == null);
}

test "a dead UNFOCUSED pane offers Restart inside its own rect" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startSplitCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const iface = state.app();

    // The split focuses the NEW pane, so pane 0 is the unfocused one. Kill it
    // abnormally: a clean exit closes its pane instead of tombstoning it.
    try state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .spawn_failed, 0);
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    try testing.expectEqual(app.Phase.failed, state.model.provider.slots[0].phase);

    const dead = app.initialTerminalRef(0);
    const rect = app.paneFrameFor(&state.model, surface, dead) orelse return error.TestExpectedPane;

    // Restart is INSIDE the dead pane, not only in the band — which is scoped
    // to the focused pane and therefore said nothing about this one.
    var restart_in_pane = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (!std.mem.eql(u8, node.widget.text, "Restart")) continue;
        if (node.frame.x >= rect.x and node.frame.x + node.frame.width <= rect.x + rect.width and
            node.frame.y >= rect.y and node.frame.y + node.frame.height <= rect.y + rect.height)
        {
            restart_in_pane = true;
        }
    }
    try testing.expect(restart_in_pane);

    // And it restarts THAT terminal, not the focused one.
    try state.dispatch(&harness.runtime, 1, .{ .restart = dead });
    try testing.expectEqual(app.Phase.starting, state.model.provider.slots[0].phase);
}

// -------------------------------------------------------------- Mac chords

test "cmd+A arms a selection over the whole scrollback, not just the viewport" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    try state.effects.feedPtyOutput(app.ptyKey(0), "alpha\r\nbravo\r\n");
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    const pane = state.model.provider.terminal(app.initialTerminalRef(0)).?;
    try testing.expect(!pane.session.selectionActive());

    try pressCanvasKey(harness, iface, "a", .{ .primary = true });
    try testing.expect(pane.session.selectionActive());
    // Keyboard-selection mode stays DISARMED: this selection is absolute
    // pins with no viewport caret, so there is nothing for the scrollback
    // chords to fall out of sync with.
    try testing.expect(!pane.selecting);

    const text = (try pane.session.selectionText(testing.allocator)) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, text, "bravo") != null);
}

test "cmd+A reaches text that has scrolled out of the viewport" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    const pane = state.model.provider.terminal(app.initialTerminalRef(0)).?;
    // Fed straight into the emulator so this exercises the scrollback rather
    // than the effect queue, the same way the cmd+K test does.
    var line: [32]u8 = undefined;
    for (0..120) |index| {
        pane.session.feed(std.fmt.bufPrint(&line, "history {d}\r\n", .{index}) catch unreachable);
    }
    pane.session.refreshScreenText();
    // The oldest line is genuinely off-screen: the viewport no longer holds it.
    try testing.expect(std.mem.indexOf(u8, pane.session.screenText(), "history 0\n") == null);

    try pressCanvasKey(harness, iface, "a", .{ .primary = true });

    const text = (try pane.session.selectionText(testing.allocator)) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(text);
    // The whole history, both ends of it. The old viewport-clamped select-all
    // could only ever return the tail, which is exactly how someone loses half
    // the output they meant to copy.
    try testing.expect(std.mem.indexOf(u8, text, "history 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "history 119") != null);
}

test "cmd+K clears the screen and the scrollback" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    const pane = state.model.provider.terminal(app.initialTerminalRef(0)).?;
    // Fed straight into the emulator: this is about the emulator's scrollback,
    // and 120 separate pty batches would only exercise the effect queue.
    var line: [32]u8 = undefined;
    for (0..120) |index| {
        pane.session.feed(std.fmt.bufPrint(&line, "history {d}\r\n", .{index}) catch unreachable);
    }
    pane.session.refreshScreenText();
    try testing.expect(std.mem.indexOf(u8, pane.session.screenText(), "history 119") != null);
    try testing.expect(pane.session.scrollbar().total > pane.rows);

    try pressCanvasKey(harness, iface, "k", .{ .primary = true });
    pane.session.refreshScreenText();
    try testing.expect(std.mem.indexOf(u8, pane.session.screenText(), "history") == null);
    // `CSI 3 J` is the part that makes this "clear scrollback" rather than
    // "scroll the screen up".
    try testing.expectEqual(@as(u32, 0), pane.session.scrollbar().offset);
    try testing.expect(pane.session.scrollbar().total <= pane.rows);
}

test "shift+PageUp and shift+PageDown page the scrollback" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    const pane = state.model.provider.terminal(app.initialTerminalRef(0)).?;
    var line: [32]u8 = undefined;
    for (0..200) |index| {
        pane.session.feed(std.fmt.bufPrint(&line, "row {d}\r\n", .{index}) catch unreachable);
    }
    pane.session.refreshScreenText();
    const bottom = pane.session.scrollbar().offset;

    try pressCanvasKey(harness, iface, "pageup", .{ .shift = true });
    const paged = pane.session.scrollbar().offset;
    try testing.expect(paged < bottom);
    // A PAGE, not a line.
    try testing.expect(bottom - paged >= pane.rows - 1);

    try releaseCanvasKey(harness, iface, "pageup", .{ .shift = true });
    try pressCanvasKey(harness, iface, "pagedown", .{ .shift = true });
    try testing.expectEqual(bottom, pane.session.scrollbar().offset);
    // Neither chord leaked bytes to the child.
    try testing.expectEqualStrings("", state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

// ------------------------------------------------------------- the menu bar

test "the application menu declares only commands the app answers" {
    var items: usize = 0;
    for (app.cockpit_menus) |menu| {
        try testing.expect(menu.title.len > 0);
        for (menu.items) |item| {
            if (item.separator) continue;
            items += 1;
            try testing.expect(item.label.len > 0);
            // A menu item whose command has no message is a dead row in a
            // real macOS menu bar.
            try testing.expect(app.onCommand(item.command) != null);
            try native_sdk.platform.validateMenuItem(item);
        }
    }
    try testing.expect(items >= 12);
    try native_sdk.platform.validateMenus(&app.cockpit_menus);
}

test "the three formerly dead onCommand entries are now reachable from the menu" {
    // `pane.split-right`, `pane.split-down` and `tabs.toggle-placement` had
    // handlers and no way to fire them.
    const reachable = [_][]const u8{ "pane.split-right", "pane.split-down", "tabs.toggle-placement" };
    for (reachable) |name| {
        var found = false;
        for (app.cockpit_menus) |menu| {
            for (menu.items) |item| {
                if (!item.separator and std.mem.eql(u8, item.command, name)) found = true;
            }
        }
        try testing.expect(found);
        try testing.expect(app.onCommand(name) != null);
    }
}

test "every registered shortcut resolves to a message" {
    for (app.cockpit_shortcuts) |shortcut| {
        try native_sdk.platform.validateShortcut(shortcut);
        try testing.expect(app.onCommand(shortcut.id) != null);
    }
}

test "the summoned switcher filters, commits, and never leaks a key to the shell" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const app_iface = state.app();

    try testing.expect(!state.model.ws().palette.open);
    try testing.expectEqual(@as(usize, 0), state.model.ws().selected_tab);

    try pressCanvasKey(harness, app_iface, "p", .{ .primary = true, .shift = true });
    try testing.expect(state.model.ws().palette.open);

    // An empty needle shows every tab, in tab order.
    var rows: [app.max_tabs]usize = undefined;
    try testing.expectEqual(@as(usize, 2), app.paletteRowsIn(&state.model, state.model.wsConst(), &rows));

    // THE gate. While the palette is up, nothing typed reaches the child —
    // not the needle, not Enter, not an arrow. A switcher that leaks into a
    // running program is worse than no switcher at all.
    const before = state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try support.typeCanvasText(harness, app_iface, "2");
    try pressCanvasKey(harness, app_iface, "arrowdown", .{});
    try testing.expectEqual(before, state.effects.ptyWrittenBytes(app.ptyKey(0)).len);

    // "2" is the second tab's POSITION, which is the handle a shell without
    // title integration still gives you.
    try testing.expectEqualStrings("2", state.model.ws().palette.needle());
    const matched = app.paletteRowsIn(&state.model, state.model.wsConst(), &rows);
    try testing.expectEqual(@as(usize, 1), matched);
    try testing.expectEqual(@as(usize, 1), rows[0]);

    // Enter commits the highlighted row and dismisses.
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try testing.expect(!state.model.ws().palette.open);
    try testing.expectEqual(@as(usize, 1), state.model.ws().selected_tab);
    try testing.expectEqual(before, state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
}

test "escape leaves the switcher without moving the selection" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const app_iface = state.app();

    try pressCanvasKey(harness, app_iface, "p", .{ .primary = true, .shift = true });
    try support.typeCanvasText(harness, app_iface, "2");
    try pressCanvasKey(harness, app_iface, "escape", .{});

    try testing.expect(!state.model.ws().palette.open);
    // The needle is gone with it: a switcher that reopens holding yesterday's
    // filter is a switcher that appears broken.
    try testing.expectEqual(@as(usize, 0), state.model.ws().palette.needle().len);
    try testing.expectEqual(@as(usize, 0), state.model.ws().selected_tab);
}

test "the switcher floats and never takes a row from the terminal" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = surface });
    defer harness.destroy(gpa);
    const state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const app_iface = state.app();

    const closed = app.workspaceChrome(&state.model, surface).content;
    try pressCanvasKey(harness, app_iface, "p", .{ .primary = true, .shift = true });
    const open = app.workspaceChrome(&state.model, surface).content;

    // Every other piece of chrome in this app takes its room out of the
    // content rect. This one must not: a transient panel that resizes every
    // PTY under it — and again on dismissal — is the exact churn this round
    // set out to remove.
    try testing.expectApproxEqAbs(closed.y, open.y, 0.0001);
    try testing.expectApproxEqAbs(closed.height, open.height, 0.0001);
    try testing.expectApproxEqAbs(closed.x, open.x, 0.0001);
    try testing.expectApproxEqAbs(closed.width, open.width, 0.0001);
}
