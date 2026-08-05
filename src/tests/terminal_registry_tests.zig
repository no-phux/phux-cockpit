//! The local terminal registry under the tab/tree model.
//!
//! Detach/attach are gone — a terminal is a LEAF of a tab's tree, not the
//! occupant of a placement slot — so these were rewritten to pin the
//! invariants that actually survive: identity is stable and never reissued,
//! a hidden terminal stays live, and closing FREES its emulator instead of
//! parking a tombstone against capacity.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const geometry = native_sdk.geometry;
const testing = std.testing;

const createDefaultSession = support.createDefaultSession;
const activeSlots = support.activeSlots;
const destroyModelSessions = app.deinitModel;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;
const typeCanvasText = support.typeCanvasText;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;

test "a hidden tab's terminal stays live and input and resize follow identity" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const model = &app_state.model;
    const terminal = model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    const original_session = terminal.session;

    app.update(model, .{ .select_position = 1 }, &app_state.effects);
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "HIDDEN LIVE\r\n");
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    try testing.expectEqual(app.Phase.live, terminal.phase);
    try testing.expect(std.mem.indexOf(u8, terminal.session.screenText(), "HIDDEN LIVE") != null);

    // Selecting it back reveals the SAME emulator; nothing is recreated.
    app.update(model, .{ .select_surface = .{ .terminal = app.initialTerminalRef(0) } }, &app_state.effects);
    try testing.expect(model.provider.terminal(app.initialTerminalRef(0)).?.session == original_session);

    try typeCanvasText(harness, app_state.app(), "moved");
    try testing.expect(std.mem.endsWith(u8, app_state.effects.ptyWrittenBytes(app.ptyKey(0)), "moved"));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    const other = model.provider.terminal(app.initialTerminalRef(1)) orelse return error.TestExpectedTerminal;
    const other_cols = other.cols;
    const other_rows = other.rows;
    app.update(model, .{ .viewport = .{
        .terminal_ref = app.initialTerminalRef(0),
        .cols = 61,
        .rows = 17,
        .size = geometry.SizeF.init(701, 411),
    } }, &app_state.effects);
    try testing.expectEqual(@as(u16, 61), terminal.cols);
    try testing.expectEqual(@as(u16, 17), terminal.rows);
    try testing.expectEqual(other_cols, other.cols);
    try testing.expectEqual(other_rows, other.rows);
}

test "leaving for Web leaves nothing routable, and returning restores the tab" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const model = &app_state.model;

    app.update(model, .{ .select_position = 1 }, &app_state.effects);
    try testing.expect(model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));

    app.update(model, .{ .select_surface = .web }, &app_state.effects);
    try testing.expectEqual(@as(?app.TerminalRef, null), model.focusedTerminalRef());
    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    try releaseCanvasKey(harness, app_state.app(), "f1", .{});
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    app.update(model, .{ .select_surface = .{ .terminal = app.initialTerminalRef(0) } }, &app_state.effects);
    try testing.expect(model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try typeCanvasText(harness, app_state.app(), "back");
    try testing.expectEqualStrings("back", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "terminal key release follows its press across tab focus changes" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const pane = app_state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    pane.session.feed("\x1b[>11u");

    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    const after_press = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try testing.expect(after_press > 0);
    app.update(&app_state.model, .{ .select_position = 1 }, &app_state.effects);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try releaseCanvasKey(harness, app_state.app(), "f1", .{});

    // The release belongs to the terminal that saw the press, not to
    // whatever holds focus when it arrives.
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > after_press);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "terminal key release from an ended generation cannot reach its replacement" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const pane = app_state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    pane.session.feed("\x1b[>11u");

    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    // An ABNORMAL exit, so the pane survives and can be restarted; a clean
    // one would close the pane and take the terminal with it.
    try app_state.effects.feedPtyExit(app.ptyKey(0), 2, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    app.update(&app_state.model, .{ .restart = app.initialTerminalRef(0) }, &app_state.effects);
    const replacement_bytes = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;

    try releaseCanvasKey(harness, app_state.app(), "f1", .{});
    try testing.expectEqual(replacement_bytes, app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "the registry mints unique terminals up to its raised ceiling" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    // One terminal at launch, not two: sessions are allocated when a
    // terminal is asked for.
    try testing.expectEqual(@as(usize, 1), state.model.tab_count);
    try testing.expectEqual(@as(usize, 1), state.effects.pendingPtyCount());
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .shortcut = .{
        .id = "terminal.new",
        .key = "t",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(@as(usize, 2), state.model.tab_count);

    // Four terminals is what the fake pty executor can hold in flight, so
    // that is where the identity checks run.
    while (state.model.tab_count < 4) app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, 4), state.model.tab_count);
    try testing.expectEqual(@as(usize, 4), state.model.provider.activeCount());
    try testing.expectEqual(@as(usize, 4), state.effects.pendingPtyCount());

    var seen: [app.max_tabs]app.TerminalRef = undefined;
    for (0..state.model.tab_count) |index| {
        const id = state.model.tabTerminal(index) orelse return error.TestExpectedTerminal;
        const pane = state.model.provider.terminal(id) orelse return error.TestExpectedTerminal;
        try testing.expectEqual(@as(u64, index + 1), pane.pty_key);
        try testing.expectEqualSlices([]const u8, app.paneArgv(0), pane.argv);
        for (seen[0..index]) |prior| try testing.expect(!prior.eql(id));
        seen[index] = id;
    }

    // The old ceiling was FOUR terminals for the whole app. Keep going: the
    // registry now holds 32 and the tab list 16.
    while (state.model.tab_count < app.max_tabs) app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(app.max_tabs, state.model.tab_count);
    try testing.expectEqual(app.max_tabs, state.model.provider.activeCount());

    // Past the tab ceiling nothing is minted, and no orphan terminal is left
    // behind in the registry either.
    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(app.max_tabs, state.model.tab_count);
    try testing.expectEqual(app.max_tabs, state.model.provider.activeCount());

    // Cmd+W over the Web surface owns no terminal, so it closes nothing.
    app.update(&state.model, .{ .select_surface = .web }, &state.effects);
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .shortcut = .{
        .id = "terminal.close",
        .key = "w",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(state.model.selectedSurface().eql(.web));
    try testing.expectEqual(app.max_tabs, state.model.tab_count);
    try testing.expect(app.onCommand("terminal.new") != null);
    try testing.expect(app.onCommand("terminal.close") != null);
    try testing.expect(app.onCommand("pane.split-right") != null);
    try testing.expect(app.onCommand("pane.split-down") != null);
    try testing.expect(app.onCommand("tab.move-left") != null);
    try testing.expect(app.onCommand("tab.move-right") != null);
}

test "close frees the terminal eagerly and its slot is immediately reusable" {
    // The `.closing` tombstone is gone. It held a registry slot and leaked a
    // whole emulator until a pty exit that might never arrive.
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, 3), state.model.tab_count);

    const closed_id = state.model.selectedTerminalId() orelse return error.TestExpectedTerminal;
    const closed_key = state.model.provider.terminal(closed_id).?.pty_key;
    var survivor_keys: [app.max_tabs]u64 = undefined;
    var survivor_count: usize = 0;
    for (0..state.model.tab_count) |index| {
        const id = state.model.tabTerminal(index) orelse continue;
        if (id.eql(closed_id)) continue;
        survivor_keys[survivor_count] = state.model.provider.terminal(id).?.pty_key;
        survivor_count += 1;
    }

    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .shortcut = .{
        .id = "terminal.close",
        .key = "w",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(@as(usize, 2), state.model.tab_count);
    try testing.expect(state.model.selectedTerminalId() != null);
    try testing.expect(state.model.provider.terminal(state.model.focusedTerminalId().?) != null);
    // Gone from the registry the moment it closed, not parked.
    try testing.expect(state.model.provider.terminal(closed_id) == null);
    try testing.expect(state.model.provider.terminalForPty(closed_key) == null);
    try testing.expectEqual(@as(usize, 2), state.model.provider.activeCount());
    try testing.expect(state.effects.ptyKillRequested(closed_key));
    for (survivor_keys[0..survivor_count]) |key| try testing.expect(!state.effects.ptyKillRequested(key));

    // The freed slot is available RIGHT AWAY, with fresh identity.
    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, 3), state.model.tab_count);
    const replacement_id = state.model.selectedTerminalId() orelse return error.TestExpectedTerminal;
    const replacement = state.model.provider.terminal(replacement_id) orelse return error.TestExpectedTerminal;
    try testing.expect(!replacement_id.eql(closed_id));
    try testing.expect(replacement.pty_key > closed_key);
    const replacement_bytes = replacement.output_bytes;

    // Late events for the retired key resolve to no slot and are dropped.
    app.update(&state.model, .{ .shell = .{
        .key = closed_key,
        .kind = .output,
        .bytes = "stale after retirement",
    } }, &state.effects);
    try testing.expectEqual(replacement_bytes, replacement.output_bytes);
    try testing.expectEqual(app.Phase.starting, replacement.phase);
    app.update(&state.model, .{ .shell = .{
        .key = closed_key,
        .kind = .exit,
        .code = -1,
        .reason = .cancelled,
    } }, &state.effects);
    try testing.expectEqual(@as(usize, 3), state.model.tab_count);
}

test "reordering preserves terminal identity, process generation, and pane structure" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .new_terminal, &state.effects);

    const selected = state.model.selectedTerminalId() orelse return error.TestExpectedTerminal;
    const pane = state.model.provider.terminal(selected) orelse return error.TestExpectedTerminal;
    const session = pane.session;
    const key = pane.pty_key;
    const generation = pane.session_generation;
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .shortcut = .{
        .id = "tab.move-left",
        .key = "arrowleft",
        .window_id = 1,
        .modifiers = .{ .primary = true, .shift = true },
    } });
    app.update(&state.model, .{ .move_terminal = -1 }, &state.effects);

    // Moving a tab moves the WHOLE tree, and selection rides along with it.
    try testing.expectEqual(selected, state.model.selectedTerminalId().?);
    try testing.expectEqual(@as(usize, 0), state.model.tabOfTerminal(selected).?);
    try testing.expectEqual(@as(usize, 0), state.model.selected_tab);
    const moved = state.model.provider.terminal(selected) orelse return error.TestExpectedTerminal;
    try testing.expect(moved.session == session);
    try testing.expectEqual(key, moved.pty_key);
    try testing.expectEqual(generation, moved.session_generation);
    try testing.expectEqual(@as(usize, 3), state.effects.pendingPtyCount());

    // Splitting that tab adds a pane to the tab that moved, not a new tab.
    app.update(&state.model, .split_right, &state.effects);
    try testing.expectEqual(@as(usize, 3), state.model.tab_count);
    try testing.expectEqual(@as(usize, 2), state.model.tabs[0].paneCount());
    var refs: [app.max_panes_per_tab]app.TerminalRef = undefined;
    const count = state.model.tabs[0].terminals(&refs);
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(!refs[0].eql(refs[1]));
    for (refs[0..count]) |id| try testing.expect(state.model.provider.terminal(id) != null);
}

test "closing a live terminal kills its pty and stops accepting its output" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);

    const closed_id = state.model.selectedTerminalId().?;
    const key = state.model.provider.terminal(closed_id).?.pty_key;
    const writes_before = state.effects.ptyWrittenBytes(key).len;
    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expect(state.model.provider.terminal(closed_id) == null);
    try testing.expect(state.effects.ptyKillRequested(key));

    // DSR would enqueue a cursor-position reply if the retired terminal
    // could still ingest output. It resolves to no slot, so nothing happens.
    try state.effects.feedPtyOutput(key, "STALE\x1b[6n\r\n");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try testing.expectEqual(writes_before, state.effects.ptyWrittenBytes(key).len);

    try state.effects.feedPtyExit(key, -1, 0, .cancelled, 0);
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try testing.expect(state.model.provider.terminalForPty(key) == null);
    try testing.expectEqual(@as(usize, 1), state.model.tab_count);
}

test "terminal identity allocation rejects exhaustion reserved keys and duplicates" {
    const session = try createDefaultSession();
    var model = try app.initialModelWithIo(testing.allocator, testing.io, session);
    defer app.deinitModel(&model);

    model.provider.next_terminal_raw = std.math.maxInt(u64) - 1;
    try testing.expectError(error.TerminalIdentityExhausted, model.provider.createTerminal());
    model.provider.next_terminal_raw = @intFromEnum(app.LocalTerminalId.terminal_1);
    try testing.expectError(error.TerminalIdentityCollision, model.provider.createTerminal());
    model.provider.next_terminal_raw = @intFromEnum(app.LocalTerminalId.terminal_2) + 1;

    model.provider.next_pty_key = std.math.maxInt(u64) - 1;
    try testing.expectError(error.TerminalIdentityExhausted, model.provider.createTerminal());
    model.provider.next_pty_key = app.ptyKey(0);
    try testing.expectError(error.TerminalIdentityCollision, model.provider.createTerminal());
    model.provider.next_pty_key = app.clipboard_key;
    try testing.expectError(error.TerminalIdentityCollision, model.provider.createTerminal());
}
