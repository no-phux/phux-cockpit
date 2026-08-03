const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("main.zig");
const grid = @import("grid.zig");

const testing = std.testing;
const automation = native_sdk.automation;
const canvas = native_sdk.canvas;
const TerminalApp = native_sdk.UiApp(app.Model, app.Msg);

fn createSessions() ![app.pane_count]*grid.Session {
    var sessions: [app.pane_count]*grid.Session = undefined;
    var created: usize = 0;
    errdefer for (sessions[0..created]) |session| session.destroy();
    while (created < sessions.len) : (created += 1) {
        sessions[created] = try grid.Session.create(testing.allocator, testing.io, 80, 24);
    }
    return sessions;
}

fn startCockpit(harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions();
    errdefer for (sessions) |session| session.destroy();
    const model = try app.initialModelWithIo(testing.allocator, testing.io, sessions);
    const state = try testing.allocator.create(TerminalApp);
    errdefer testing.allocator.destroy(state);
    state.* = TerminalApp.init(std.heap.page_allocator, model, app.appOptions());
    state.effects.executor = .fake;
    try harness.start(state.app());
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = native_sdk.geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);
    return state;
}

fn stopCockpit(state: *TerminalApp) void {
    state.deinit();
    app.deinitModel(&state.model);
    testing.allocator.destroy(state);
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
        for (state.model.terminal_order[0..index]) |prior| try testing.expect(prior != id);
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
        if (id == closed_id) continue;
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
    try testing.expect(replacement_id != closed_id);
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
    try testing.expect(state.model.attachments[0].? != state.model.attachments[1].?);
    for (state.model.attachments) |attached| try testing.expect(state.model.provider.terminal(attached.?) != null);
}

test "versioned snapshot restores topology into fresh sessions without process state" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .{ .move_terminal = -1 }, &state.effects);
    app.update(&state.model, .toggle_split, &state.effects);
    state.model.split_fraction = 0.63;
    const live_id = state.model.selectedTerminalId().?;
    const live_session = state.model.provider.terminal(live_id).?.session;
    live_session.feed("runtime state is intentionally not persisted");

    const snapshot = try state.model.topologySnapshot();
    try snapshot.validate();
    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v1 = snapshot });
    defer app.deinitModel(&restored);
    try testing.expectEqual(snapshot.version, app.topology_snapshot_version);
    try testing.expectEqual(state.model.terminal_count, restored.terminal_count);
    try testing.expectEqualSlices(app.TerminalId, state.model.terminal_order[0..state.model.terminal_count], restored.terminal_order[0..restored.terminal_count]);
    try testing.expectEqual(state.model.selectedTerminalId().?, restored.selectedTerminalId().?);
    try testing.expectEqual(state.model.layout, restored.layout);
    try testing.expectApproxEqAbs(state.model.split_fraction, restored.split_fraction, 0.0001);
    try testing.expectEqualDeep(state.model.attachments, restored.attachments);
    const fresh = restored.provider.terminal(live_id) orelse return error.TestExpectedTerminal;
    try testing.expect(fresh.session != live_session);
    try testing.expectEqual(@as(u64, 0), fresh.output_bytes);
    try testing.expectEqual(app.Phase.starting, fresh.phase);
    try testing.expectEqual(@as(u64, 0), fresh.session_generation);
    const text = try fresh.session.plainText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "runtime state") == null);
}

test "legacy topology migration is bounded normalized and validated" {
    const migrated = try app.migrateTopologySnapshot(.{ .v0 = .{
        .terminal_count = 4,
        .selected_index = 3,
        .split = true,
        .split_fraction = 0.7,
    } });
    try testing.expectEqual(app.topology_snapshot_version, migrated.version);
    try testing.expectEqual(@as(u8, 4), migrated.terminal_count);
    try testing.expectEqual(migrated.terminal_order[3], migrated.selection.terminal);
    try testing.expectEqual(app.LayoutMode.split, migrated.layout);
    try testing.expectEqual(migrated.terminal_order[3], migrated.attachments[0].?);
    try testing.expectEqual(migrated.terminal_order[0], migrated.attachments[1].?);

    var duplicate = migrated;
    duplicate.terminal_order[2] = duplicate.terminal_order[0];
    try testing.expectError(error.InvalidTopology, duplicate.validate());
    var future = migrated;
    future.version = 99;
    try testing.expectError(error.UnsupportedTopologyVersion, app.migrateTopologySnapshot(.{ .v1 = future }));
    var dangling = migrated;
    dangling.selection = .{ .terminal = @enumFromInt(@intFromEnum(migrated.terminal_order[3]) + 100) };
    try testing.expectError(error.InvalidTopology, dangling.validate());
    try testing.expectError(error.InvalidTopology, app.migrateTopologySnapshot(.{ .v0 = .{ .terminal_count = 5 } }));
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
    const sessions = try createSessions();
    var model = try app.initialModelWithIo(testing.allocator, testing.io, sessions);
    defer app.deinitModel(&model);

    model.provider.next_terminal_raw = std.math.maxInt(u64) - 1;
    try testing.expectError(error.TerminalIdentityExhausted, model.provider.createTerminal());
    model.provider.next_terminal_raw = @intFromEnum(app.TerminalId.terminal_1);
    try testing.expectError(error.TerminalIdentityCollision, model.provider.createTerminal());
    model.provider.next_terminal_raw = @intFromEnum(app.TerminalId.terminal_2) + 1;

    model.provider.next_pty_key = std.math.maxInt(u64) - 1;
    try testing.expectError(error.TerminalIdentityExhausted, model.provider.createTerminal());
    model.provider.next_pty_key = app.ptyKey(0);
    try testing.expectError(error.TerminalIdentityCollision, model.provider.createTerminal());
    model.provider.next_pty_key = app.clipboard_key;
    try testing.expectError(error.TerminalIdentityCollision, model.provider.createTerminal());
}

test "canonical snapshots reject topology rewrites and round trip exactly" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .toggle_split, &state.effects);
    state.model.split_fraction = 0.63;

    const snapshot = try state.model.topologySnapshot();
    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v1 = snapshot });
    defer app.deinitModel(&restored);
    try testing.expectEqualDeep(snapshot, try restored.topologySnapshot());
    try testing.expect(!app.process_restoration_supported);

    var invalid = snapshot;
    invalid.attachments[invalid.focused_attachment.index()] = null;
    try testing.expectError(error.InvalidTopology, invalid.validate());
    invalid = snapshot;
    invalid.layout = .split;
    invalid.attachments[1] = null;
    try testing.expectError(error.InvalidTopology, invalid.validate());
    invalid = snapshot;
    invalid.split_fraction = 0.99;
    try testing.expectError(error.InvalidTopology, invalid.validate());
    invalid = snapshot;
    const exhausted: app.TerminalId = @enumFromInt(std.math.maxInt(u64) - 1);
    const old_id = invalid.terminal_order[0];
    invalid.terminal_order[0] = exhausted;
    if (invalid.selection.eql(.{ .terminal = old_id })) invalid.selection = .{ .terminal = exhausted };
    for (&invalid.attachments) |*attached| {
        if (attached.* != null and attached.*.? == old_id) attached.* = exhausted;
    }
    try testing.expectError(error.InvalidTopology, invalid.validate());
}

fn fillTerminalCapacity(harness: anytype, state: *TerminalApp) !void {
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try state.dispatch(&harness.runtime, 1, .new_terminal);
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
    try testing.expect(std.mem.indexOf(u8, a11y, "Web, system WebKit, shortcut CMD+5") != null);
    try testing.expect(std.mem.indexOf(u8, a11y, "New Terminal, Command T") != null);
    try testing.expect(std.mem.indexOf(u8, a11y, "Close Terminal, Command W") != null);
    try testing.expect(std.mem.indexOf(u8, a11y, "Move terminal tab left") == null);
    try testing.expect(std.mem.indexOf(u8, a11y, "DETACHED") == null);

    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "5",
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(state.model.selected_surface.eql(.web));
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
    try testing.expectEqual(state.model.terminal_order[3], state.model.selectedTerminalId().?);
    try testing.expect(app.onCommand("surface.5") != null);
}

test "four-terminal tab layout stays inside the minimum window with Web last" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    try fillTerminalCapacity(harness, state);
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    var tab_frames: [app.max_terminal_count + 1]native_sdk.geometry.RectF = undefined;
    var tab_labels: [app.max_terminal_count + 1][]const u8 = undefined;
    var tab_count: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind != .segmented_control) continue;
        tab_frames[tab_count] = node.frame;
        tab_labels[tab_count] = node.widget.text;
        tab_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), tab_count);
    for (tab_frames[0..tab_count], 0..) |frame, index| {
        try testing.expect(frame.width > 0 and frame.height > 0);
        try testing.expect(frame.x >= 0 and frame.x + frame.width <= app.window_min_width);
        if (index > 0) try testing.expect(frame.x >= tab_frames[index - 1].x + tab_frames[index - 1].width);
    }
    try testing.expectEqualStrings("T1", tab_labels[0]);
    try testing.expectEqualStrings("T4", tab_labels[3]);
    try testing.expectEqualStrings("Web", tab_labels[4]);
}

const four_terminal_shot_path = "zig-out/cockpit-four-terminals.png";

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
