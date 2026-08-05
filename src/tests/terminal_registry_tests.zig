const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const geometry = native_sdk.geometry;
const testing = std.testing;

const createDefaultSessions = support.createDefaultSessions;
const destroyModelSessions = app.deinitModel;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;
const typeCanvasText = support.typeCanvasText;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;

test "detached terminal stays live and moved input and resize follow identity" {
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

    app.update(model, .{ .detach_terminal = .primary }, &app_state.effects);
    try testing.expectEqual(@as(?app.TerminalRef, null), model.attachments[app.Placement.primary.index()]);
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "DETACHED LIVE\r\n");
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    try testing.expectEqual(app.Phase.live, terminal.phase);
    try testing.expect(std.mem.indexOf(u8, terminal.session.screenText(), "DETACHED LIVE") != null);

    app.update(model, .{ .detach_terminal = .secondary }, &app_state.effects);
    app.update(model, .{ .attach_terminal = .{ .placement = .secondary, .terminal_ref = app.initialTerminalRef(0) } }, &app_state.effects);
    app.update(model, .{ .select_surface = .{ .terminal = app.initialTerminalRef(0) } }, &app_state.effects);
    try testing.expect(model.terminalAt(.secondary).?.session == original_session);

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

test "attachment changes keep selected and focused placements routable" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const model = &app_state.model;

    app.update(model, .{ .detach_terminal = .primary }, &app_state.effects);
    try testing.expect(model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    try testing.expectEqual(app.Placement.secondary, model.focus_placement);

    app.update(model, .{ .detach_terminal = .secondary }, &app_state.effects);
    try testing.expectEqual(@as(?app.TerminalRef, null), model.focusedTerminalRef());
    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    try releaseCanvasKey(harness, app_state.app(), "f1", .{});
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .frame_requested);
    var saw_detached_semantics = false;
    var saw_disabled_split = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.indexOf(u8, layout.widget.semantics.label, "Terminal 2, native terminal, detached") != null) {
            saw_detached_semantics = true;
        }
        if (std.mem.eql(u8, layout.widget.text, "Split") and layout.widget.state.disabled) {
            saw_disabled_split = true;
        }
    }
    try testing.expect(saw_detached_semantics);
    try testing.expect(saw_disabled_split);

    app.update(model, .{ .attach_terminal = .{ .placement = .primary, .terminal_ref = app.initialTerminalRef(0) } }, &app_state.effects);
    try testing.expect(model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    try testing.expectEqual(app.Placement.primary, model.focus_placement);
    try typeCanvasText(harness, app_state.app(), "reattached");
    try testing.expectEqualStrings("reattached", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "terminal key release follows its press across attachment focus changes" {
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
    app.update(&app_state.model, .{ .detach_terminal = .primary }, &app_state.effects);
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try releaseCanvasKey(harness, app_state.app(), "f1", .{});

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
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    app.update(&app_state.model, .{ .restart = .primary }, &app_state.effects);
    const replacement_bytes = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;

    try releaseCanvasKey(harness, app_state.app(), "f1", .{});
    try testing.expectEqual(replacement_bytes, app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "topology registry creates four unique terminals and refuses a fifth" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    try testing.expectEqual(@as(usize, 2), state.model.terminal_count);
    try testing.expectEqual(@as(usize, 2), state.effects.pendingPtyCount());
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .shortcut = .{
        .id = "terminal.new",
        .key = "t",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, app.max_terminal_count), state.model.terminal_count);
    try testing.expectEqual(@as(usize, app.max_terminal_count), state.model.provider.activeCount());
    try testing.expectEqual(@as(usize, app.max_terminal_count), state.effects.pendingPtyCount());

    for (state.model.terminal_order[0..state.model.terminal_count], 0..) |id, index| {
        const pane = state.model.provider.terminal(id) orelse return error.TestExpectedTerminal;
        try testing.expectEqual(@as(u64, index + 1), pane.pty_key);
        try testing.expectEqualSlices([]const u8, app.paneArgv(0), pane.argv);
        for (state.model.terminal_order[0..index]) |prior| try testing.expect(!prior.eql(id));
    }

    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, app.max_terminal_count), state.model.terminal_count);
    try testing.expectEqual(@as(usize, app.max_terminal_count), state.effects.pendingPtyCount());
    app.update(&state.model, .{ .select_surface = .web }, &state.effects);
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .shortcut = .{
        .id = "terminal.close",
        .key = "w",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(state.model.selected_surface.eql(.web));
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        try testing.expect(!std.mem.eql(u8, node.widget.text, "Close"));
    }
    try testing.expectEqual(@as(usize, app.max_terminal_count), state.model.terminal_count);
    try testing.expect(app.onCommand("terminal.new") != null);
    try testing.expect(app.onCommand("terminal.close") != null);
    try testing.expect(app.onCommand("tab.move-left") != null);
    try testing.expect(app.onCommand("tab.move-right") != null);
}

test "close tombstones one PTY and stale events cannot reach its replacement" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .new_terminal, &state.effects);

    const closed_id = state.model.selectedTerminalId() orelse return error.TestExpectedTerminal;
    const closed = state.model.provider.terminal(closed_id) orelse return error.TestExpectedTerminal;
    const closed_key = closed.pty_key;
    var survivor_keys: [app.max_terminal_count - 1]u64 = undefined;
    var survivor_count: usize = 0;
    for (state.model.terminal_order[0..state.model.terminal_count]) |id| {
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
    try testing.expectEqual(@as(usize, 3), state.model.terminal_count);
    try testing.expect(state.model.selectedTerminalId() != null);
    try testing.expect(state.model.selectedPlacement() != null);
    try testing.expect(state.model.focusedTerminalId() != null);
    try testing.expect(state.model.provider.terminal(state.model.focusedTerminalId().?) != null);
    try testing.expect(state.model.provider.terminal(closed_id) == null);
    try testing.expect(state.model.provider.terminalForPty(closed_key) != null);
    try testing.expect(state.effects.ptyKillRequested(closed_key));
    for (survivor_keys[0..survivor_count]) |key| try testing.expect(!state.effects.ptyKillRequested(key));

    // All four provider slots remain occupied until this exact kill exits.
    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, 3), state.model.terminal_count);
    try state.effects.feedPtyOutput(closed_key, "late but still owned");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try state.effects.feedPtyExit(closed_key, -1, 0, .cancelled, 0);
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try testing.expect(state.model.provider.terminalForPty(closed_key) == null);

    app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(@as(usize, 4), state.model.terminal_count);
    const replacement_id = state.model.selectedTerminalId() orelse return error.TestExpectedTerminal;
    const replacement = state.model.provider.terminal(replacement_id) orelse return error.TestExpectedTerminal;
    try testing.expect(!replacement_id.eql(closed_id));
    try testing.expect(replacement.pty_key > closed_key);
    const replacement_bytes = replacement.output_bytes;

    app.update(&state.model, .{ .shell = .{
        .key = closed_key,
        .kind = .output,
        .bytes = "stale after retirement",
    } }, &state.effects);
    try testing.expectEqual(replacement_bytes, replacement.output_bytes);
    try testing.expectEqual(app.Phase.starting, replacement.phase);
}

test "reordering preserves terminal identity process generation and attachments" {
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

    try testing.expectEqual(selected, state.model.selectedTerminalId().?);
    try testing.expectEqual(@as(usize, 1), state.model.terminalOrderIndex(selected).?);
    const moved = state.model.provider.terminal(selected) orelse return error.TestExpectedTerminal;
    try testing.expect(moved.session == session);
    try testing.expectEqual(key, moved.pty_key);
    try testing.expectEqual(generation, moved.session_generation);
    try testing.expectEqual(@as(usize, 4), state.effects.pendingPtyCount());
    try testing.expect(state.model.selectedPlacement() != null);

    app.update(&state.model, .toggle_split, &state.effects);
    try testing.expectEqual(app.LayoutMode.split, state.model.layout);
    try testing.expect(state.model.attachments[0] != null);
    try testing.expect(state.model.attachments[1] != null);
    try testing.expect(!state.model.attachments[0].?.eql(state.model.attachments[1].?));
    for (state.model.attachments) |attached| try testing.expect(state.model.provider.terminal(attached.?) != null);
}

test "closing terminal discards stale output and generated replies until its exact exit" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    const closed_id = state.model.selectedTerminalId().?;
    const closed = state.model.provider.terminal(closed_id).?;
    const key = closed.pty_key;
    const bytes_before = closed.output_bytes;
    const writes_before = state.effects.ptyWrittenBytes(key).len;
    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expect(state.model.provider.isClosing(closed_id));

    // DSR would mutate the screen and enqueue a cursor-position reply if the
    // closing resource were still allowed to ingest output.
    try state.effects.feedPtyOutput(key, "STALE\x1b[6n\r\n");
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try testing.expectEqual(bytes_before, closed.output_bytes);
    try testing.expectEqual(@as(usize, 0), closed.session.pendingResponses().len);
    try testing.expectEqual(writes_before, state.effects.ptyWrittenBytes(key).len);
    try testing.expect(std.mem.indexOf(u8, closed.session.screenText(), "STALE") == null);
    try testing.expect(state.model.provider.isClosing(closed_id));

    try state.effects.feedPtyExit(key, -1, 0, .cancelled, 0);
    try harness.runtime.dispatchPlatformEvent(state.app(), .wake);
    try testing.expect(state.model.provider.terminalForPty(key) == null);
}

test "terminal identity allocation rejects exhaustion reserved keys and duplicates" {
    const sessions = try createDefaultSessions();
    var model = try app.initialModelWithIo(testing.allocator, testing.io, sessions);
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
