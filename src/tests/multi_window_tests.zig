//! Windows: cmd+N, per-window workspaces, and the close cascade that decides
//! when the app is actually over.
//!
//! The two claims worth stating up front, because both were wrong before this
//! file existed:
//!
//!   1. A terminal belongs to exactly ONE window. The registry stays global
//!      (32 slots, one pty-key namespace, one clipboard latch), and ownership
//!      is the tab tree that holds the terminal — so `Model.admitTab` refuses
//!      a terminal another window already has, and `locateTerminal` is how a
//!      pty event finds its window at all.
//!   2. Quitting is a property of the LAST window, not of any window. The old
//!      cascade called `quitApp` the moment a tab count reached zero, which
//!      with two windows open meant emptying the second one killed the first
//!      one's live shells.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;

const surface = geometry.SizeF.init(980, 640);

// ------------------------------------------------------------- the model

test "a workspace is per window, and window 1..N are heap allocated on demand" {
    // The whole reason for the inline/heap split: a model that carried five
    // workspaces by value would carry ~755 KB of trees through every
    // `TerminalApp.init`, and this repo has already taken a main-thread stack
    // overflow from exactly that shape.
    try testing.expect(@sizeOf(app.Workspace) > 100 * 1024);
    try testing.expect(@sizeOf(app.Model) < 2 * @sizeOf(app.Workspace));
    try testing.expectEqual(@as(usize, 5), app.max_windows);
    try testing.expectEqual(@as(usize, 4), app.max_secondary_windows);
}

test "cmd+N opens a window with its own workspace and one terminal" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try testing.expectEqual(@as(usize, 1), state.model.openWindowCount());
    try testing.expectEqual(@as(usize, 1), state.model.primary.tab_count);

    app.update(&state.model, .new_window, &state.effects);

    try testing.expectEqual(@as(usize, 2), state.model.openWindowCount());
    // Input follows the new window, so the next cmd+T lands in it.
    try testing.expectEqual(@as(usize, 1), state.model.active_window);
    const second = state.model.wsAt(1) orelse return error.TestExpectedWindow;
    try testing.expectEqual(@as(usize, 1), second.tab_count);
    try testing.expect(!second.web_selected);
    // The FIRST window is untouched: same tab, same terminal.
    try testing.expectEqual(@as(usize, 1), state.model.primary.tab_count);

    // Two windows, two DISTINCT terminals — never one terminal on two trees.
    const first_id = state.model.primary.focusedTerminalRef() orelse return error.TestExpectedTerminal;
    const second_id = second.focusedTerminalRef() orelse return error.TestExpectedTerminal;
    try testing.expect(!first_id.eql(second_id));
    try testing.expectEqual(@as(usize, 2), state.model.provider.activeCount());
}

test "a terminal belongs to exactly one window and cannot be admitted into another" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const first_id = state.model.primary.focusedTerminalRef() orelse return error.TestExpectedTerminal;

    app.update(&state.model, .new_window, &state.effects);
    // Window 1 is active; the first window's terminal is refused rather than
    // duplicated, because two trees holding one terminal would be two panes
    // driving one emulator.
    try testing.expect(!state.model.admitTab(first_id));
    const second = state.model.wsAt(1) orelse return error.TestExpectedWindow;
    try testing.expectEqual(@as(usize, 1), second.tab_count);
    try testing.expect(second.tabOfTerminal(first_id) == null);

    // And the lookup that a pty event uses finds it in window 0 regardless of
    // which window is in front.
    const located = state.model.locateTerminal(first_id) orelse return error.TestExpectedLocation;
    try testing.expectEqual(@as(usize, 0), located.window);
}

test "each window keeps its own tabs, selection, and surface geometry" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    // Two more tabs and a split, all in the SECOND window.
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .split_right, &state.effects);
    const second = state.model.wsAt(1) orelse return error.TestExpectedWindow;
    try testing.expectEqual(@as(usize, 2), second.tab_count);
    try testing.expectEqual(@as(usize, 2), second.selectedTreeConst().?.paneCount());
    // The first window still has exactly what it started with.
    try testing.expectEqual(@as(usize, 1), state.model.primary.tab_count);
    try testing.expectEqual(@as(usize, 1), state.model.primary.selectedTreeConst().?.paneCount());

    // Geometry is per window too: a resize of one is not a resize of the
    // other, which is what lets two windows sit on differently sized screens.
    app.update(&state.model, .{ .surface_resized = .{
        .size = geometry.SizeF.init(640, 400),
        .scale_factor = 1,
        .window = 1,
        .window_id = 7,
    } }, &state.effects);
    try testing.expectEqual(@as(f32, 640), second.surface_size.width);
    try testing.expectEqual(@as(native_sdk.platform.WindowId, 7), second.window_id);
    try testing.expect(state.model.primary.surface_size.width != 640);
}

// --------------------------------------------------------------- the close

test "closing the last tab of a second window closes THAT window and never quits" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    try testing.expectEqual(@as(usize, 2), state.model.openWindowCount());
    const quits_before = state.effects.window_action_state.quit_count;

    app.update(&state.model, .close_terminal, &state.effects);

    // The second window is gone, the first is untouched and still has its
    // shell, and nothing asked the app to exit.
    try testing.expectEqual(@as(usize, 1), state.model.openWindowCount());
    try testing.expect(state.model.wsAt(1) == null);
    try testing.expect(state.model.primary_open);
    try testing.expectEqual(@as(usize, 1), state.model.primary.tab_count);
    try testing.expectEqual(quits_before, state.effects.window_action_state.quit_count);
    // Input fell back to the window that is still there.
    try testing.expectEqual(@as(usize, 0), state.model.active_window);
}

test "the app quits only when the LAST window's last tab closes" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);

    // Empty the MAIN window first, while the second window is still open. It
    // stands on its web surface; the app keeps running.
    app.update(&state.model, .{ .focus_window = 0 }, &state.effects);
    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expectEqual(@as(u32, 0), state.effects.window_action_state.quit_count);
    try testing.expectEqual(@as(usize, 0), state.model.primary.tab_count);
    try testing.expect(state.model.primary.web_selected);
    try testing.expect(state.model.wsAt(1) != null);

    // Now the second window's last tab: nothing is left, so this is the quit.
    app.update(&state.model, .{ .focus_window = 1 }, &state.effects);
    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expectEqual(@as(u32, 1), state.effects.window_action_state.quit_count);
    try testing.expect(!state.model.primary_open);
    try testing.expectEqualStrings(app.main_window_label, state.effects.window_action_state.lastLabel());
}

test "a single window still quits on its last tab, exactly as before" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expectEqual(@as(u32, 1), state.effects.window_action_state.quit_count);
    try testing.expect(state.model.primary.web_selected);
}

test "an OS-initiated window close drains that window's shells and leaves the others" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    app.update(&state.model, .split_right, &state.effects);
    try testing.expectEqual(@as(usize, 3), state.model.provider.activeCount());

    app.update(&state.model, .{ .window_closed = 1 }, &state.effects);

    // Both of the second window's shells are gone with it; the first window's
    // is not.
    try testing.expectEqual(@as(usize, 1), state.model.provider.activeCount());
    try testing.expect(state.model.wsAt(1) == null);
    try testing.expectEqual(@as(u32, 0), state.effects.window_action_state.quit_count);
}

test "the sixth window is refused visibly, not silently" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    for (0..app.max_secondary_windows) |_| app.update(&state.model, .new_window, &state.effects);
    try testing.expectEqual(app.max_windows, state.model.openWindowCount());
    try testing.expect(!state.model.window_limit_refused);

    const before = state.model.provider.activeCount();
    app.update(&state.model, .new_window, &state.effects);
    // No sixth window, no orphan terminal minted for it, and a latch the
    // chrome shows so the chord is not indistinguishable from an unbound one.
    try testing.expectEqual(app.max_windows, state.model.openWindowCount());
    try testing.expectEqual(before, state.model.provider.activeCount());
    try testing.expect(state.model.window_limit_refused);
    try testing.expect(app.chromeRevealed(&state.model));

    // Closing a window frees a slot, so the refusal stops being true.
    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expect(!state.model.window_limit_refused);
}

// -------------------------------------------------------------- declaration

test "the declared window set is exactly the open secondary workspaces" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    var scratch: support.TerminalApp.WindowsScratch = .{};
    try testing.expectEqual(@as(usize, 0), app.declaredWindows(&state.model, &scratch).len);

    app.update(&state.model, .new_window, &state.effects);
    const declared = app.declaredWindows(&state.model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings(app.windowLabelFor(1), declared[0].label);
    // Its OWN canvas: a shared label would merge two windows' surfaces, and
    // the per-window chrome builder discriminates on exactly this string.
    try testing.expectEqualStrings(app.canvasLabelFor(1), declared[0].canvas_label);
    try testing.expect(!std.mem.eql(u8, declared[0].canvas_label, app.canvas_label));
    // A user close comes back as the Msg that retires the slot.
    try testing.expect(declared[0].on_close != null);

    // Labels are unique across the whole set, main included.
    try testing.expect(app.windowIndexForCanvas(app.canvas_label).? == 0);
    for (app.secondary_canvas_labels, 0..) |label, offset| {
        try testing.expectEqual(offset + 1, app.windowIndexForCanvas(label).?);
    }
    try testing.expect(app.windowIndexForCanvas("not-ours") == null);
}

test "the second window paints its own live terminal cells" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    const second = state.model.wsAt(1) orelse return error.TestExpectedWindow;
    second.surface_size = surface;
    const second_id = second.focusedTerminalRef() orelse return error.TestExpectedTerminal;
    const pane = state.model.provider.terminal(second_id) orelse return error.TestExpectedTerminal;
    pane.session.feed("WINDOWTWO\r\n");
    pane.session.refreshScreenText();

    // The window-1 canvas, through the SAME entry point the runtime calls for
    // a secondary window slot. Before `build_window` this painted nothing at
    // all: the runtime installed an app-owned chrome list for the main canvas
    // only, so a second window rendered its tab strip over an empty surface.
    var commands: [native_sdk.runtime.max_canvas_commands_per_view]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try app.buildChromeWindow(&state.model, &builder, .{
        .canvas_label = app.canvasLabelFor(1),
        .window_id = 2,
        .size = surface,
        .tokens = app.cockpitTokens(&state.model),
        .is_main = false,
    });
    const list = builder.displayList();
    const view = try support.expectCellGrid(list);
    try testing.expect(view.find("WINDOWTWO") != null);
}

test "a background window's frames resize its own terminals, not the front window's" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    app.update(&state.model, .{ .focus_window = 0 }, &state.effects);
    const second = state.model.wsAt(1) orelse return error.TestExpectedWindow;

    // A frame for the SECOND window's canvas while the FIRST is active.
    const msg = app.onFrame(&state.model, .{
        .label = app.canvasLabelFor(1),
        .window_id = 9,
        .size = geometry.SizeF.init(700, 500),
        .scale_factor = 2,
    }) orelse return error.TestExpectedFrameMessage;
    app.update(&state.model, msg, &state.effects);
    // Whatever it asked for landed on window 1 and left window 0 alone.
    try testing.expectEqual(@as(usize, 0), state.model.active_window);
    try testing.expect(second.window_id == 9 or second.surface_size.width == 700);
    try testing.expect(state.model.primary.window_id != 9);

    // A frame for a canvas this app does not own is ignored outright.
    try testing.expect(app.onFrame(&state.model, .{
        .label = "somebody-elses-canvas",
        .size = geometry.SizeF.init(700, 500),
    }) == null);
}

// -------------------------------------------------------------- fullscreen

test "the fullscreen chord targets the FOCUSED window" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .toggle_fullscreen, &state.effects);
    try testing.expectEqual(@as(u32, 1), state.effects.window_action_state.fullscreen_count);
    try testing.expectEqualStrings(app.main_window_label, state.effects.window_action_state.lastLabel());

    app.update(&state.model, .new_window, &state.effects);
    app.update(&state.model, .toggle_fullscreen, &state.effects);
    try testing.expectEqual(@as(u32, 2), state.effects.window_action_state.fullscreen_count);
    try testing.expectEqualStrings(app.windowLabelFor(1), state.effects.window_action_state.lastLabel());
}

test "the fullscreen and new-window commands are bound in both the menu and the chord table" {
    try testing.expectEqual(app.Msg.toggle_fullscreen, app.onCommand("window.fullscreen").?);
    try testing.expectEqual(app.Msg.new_window, app.onCommand("window.new").?);

    var fullscreen_shortcut = false;
    var new_window_shortcut = false;
    for (app.cockpit_shortcuts) |shortcut| {
        if (std.mem.eql(u8, shortcut.id, "window.fullscreen")) {
            fullscreen_shortcut = true;
            // ctrl+cmd+F, the chord macOS itself uses.
            try testing.expect(shortcut.modifiers.primary and shortcut.modifiers.control);
            try testing.expectEqualStrings("f", shortcut.key);
        }
        if (std.mem.eql(u8, shortcut.id, "window.new")) {
            new_window_shortcut = true;
            try testing.expect(shortcut.modifiers.primary and !shortcut.modifiers.shift);
            try testing.expectEqualStrings("n", shortcut.key);
        }
    }
    try testing.expect(fullscreen_shortcut);
    try testing.expect(new_window_shortcut);

    var fullscreen_item = false;
    var new_window_item = false;
    for (app.cockpit_menus) |menu| {
        for (menu.items) |item| {
            if (std.mem.eql(u8, item.command, "window.fullscreen")) fullscreen_item = true;
            if (std.mem.eql(u8, item.command, "window.new")) new_window_item = true;
        }
    }
    try testing.expect(fullscreen_item);
    try testing.expect(new_window_item);
}

// ------------------------------------------------------------- persistence

test "the snapshot carries every window and restores them as windows" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .split_right, &state.effects);

    const snapshot = try state.model.topologySnapshot();
    try snapshot.validate();
    try testing.expectEqual(@as(u8, 2), snapshot.window_count);
    try testing.expectEqual(@as(u8, 1), snapshot.windows[0].tab_count);
    try testing.expectEqual(@as(u8, 2), snapshot.windows[1].tab_count);
    try testing.expectEqual(@as(u8, 3), snapshot.tab_count);
    // The selection is window-RELATIVE: the second window's second tab is
    // `tab 1` in its own run, not `tab 2` in the flat array.
    try testing.expect(snapshot.windows[1].selection.eql(.{ .tab = 1 }));

    // Through the file and back, byte for byte.
    var bytes: [app.max_state_bytes]u8 = undefined;
    const encoded = try app.serializeWorkspaceState(&snapshot, &bytes);
    try testing.expect(std.mem.startsWith(u8, encoded, "phux-cockpit-state 4\n"));
    var parsed: app.PersistedTopologySnapshot = undefined;
    try testing.expect(app.parseWorkspaceState(encoded, &parsed));
    try testing.expectEqualDeep(snapshot, try app.migrateTopologySnapshot(parsed));

    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v4 = snapshot });
    defer app.deinitModel(&restored);
    try testing.expectEqual(@as(usize, 2), restored.openWindowCount());
    try testing.expectEqual(@as(usize, 1), restored.primary.tab_count);
    const restored_second = restored.wsAt(1) orelse return error.TestExpectedWindow;
    try testing.expectEqual(@as(usize, 2), restored_second.tab_count);
    try testing.expectEqual(@as(usize, 1), restored_second.selected_tab);
    try testing.expectEqual(@as(usize, 2), restored_second.selectedTreeConst().?.paneCount());
}

test "a pre-multi-window snapshot restores as exactly one window" {
    // A v3 file: one window's worth of tabs and one file-level selection.
    const legacy_text =
        "phux-cockpit-state 3\n" ++
        "placement top\n" ++
        "selection tab 1\n" ++
        "tab 0 0\n" ++
        "node 0 leaf - 0\n" ++
        "tab 0 0\n" ++
        "node 0 leaf - 1\n" ++
        "end\n";
    var parsed: app.PersistedTopologySnapshot = undefined;
    try testing.expect(app.parseWorkspaceState(legacy_text, &parsed));
    try testing.expect(parsed == .v3);

    const migrated = try app.migrateTopologySnapshot(parsed);
    try testing.expectEqual(@as(u8, 1), migrated.window_count);
    try testing.expectEqual(@as(u8, 2), migrated.tab_count);
    try testing.expectEqual(@as(u8, 2), migrated.windows[0].tab_count);
    try testing.expect(migrated.windows[0].selection.eql(.{ .tab = 1 }));

    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v4 = migrated });
    defer app.deinitModel(&restored);
    try testing.expectEqual(@as(usize, 1), restored.openWindowCount());
    try testing.expect(restored.wsAt(1) == null);
    try testing.expectEqual(@as(usize, 2), restored.primary.tab_count);
    try testing.expectEqual(@as(usize, 1), restored.primary.selected_tab);
}

test "a window's tabs may not be claimed by another window's count" {
    // The structural claim the flat tab array rests on: the windows' counts
    // have to account for the tab list exactly, or a restore would either
    // strand tabs no window owns or read past its own run.
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_window, &state.effects);

    const snapshot = try state.model.topologySnapshot();
    var short = snapshot;
    short.windows[1].tab_count = 0;
    try testing.expectError(error.InvalidTopology, short.validate());

    var long = snapshot;
    long.windows[1].tab_count = 2;
    try testing.expectError(error.InvalidTopology, long.validate());

    var ghost = snapshot;
    ghost.window_count = 1;
    try testing.expectError(error.InvalidTopology, ghost.validate());
}

test "the topology fingerprint moves when a background window changes" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    app.update(&state.model, .new_window, &state.effects);
    app.update(&state.model, .{ .focus_window = 0 }, &state.effects);
    const before = state.model.topologyFingerprint();

    // A tab opened in the window BEHIND the one in front still changes what a
    // restore should produce, so the save has to be armed by it.
    const second = state.model.wsAt(1) orelse return error.TestExpectedWindow;
    const pane = try state.model.provider.createTerminal();
    try testing.expect(second.admitTab(pane.id));
    try testing.expect(state.model.topologyFingerprint() != before);
}
