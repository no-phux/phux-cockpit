const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const testing = std.testing;

const createDefaultSessions = support.createDefaultSessions;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;
const remoteRef = support.remoteTerminalRef;

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
    state.model.tab_placement = .side;
    const live_id = state.model.selectedTerminalId().?;
    const live_session = state.model.provider.terminal(live_id).?.session;
    live_session.feed("runtime state is intentionally not persisted");

    const snapshot = try state.model.topologySnapshot();
    try snapshot.validate();
    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v1 = snapshot });
    defer app.deinitModel(&restored);
    try testing.expectEqual(snapshot.version, app.topology_snapshot_version);
    try testing.expectEqual(state.model.terminal_count, restored.terminal_count);
    for (state.model.terminal_order[0..state.model.terminal_count], restored.terminal_order[0..restored.terminal_count]) |expected, actual| try testing.expect(expected.eql(actual));
    try testing.expect(state.model.selectedTerminalRef().?.eql(restored.selectedTerminalRef().?));
    try testing.expectEqual(state.model.layout, restored.layout);
    try testing.expectEqual(state.model.tab_placement, restored.tab_placement);
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
    const exhausted: app.LocalTerminalId = @enumFromInt(std.math.maxInt(u64) - 1);
    const old_id = invalid.terminal_order[0];
    invalid.terminal_order[0] = exhausted;
    if (invalid.selection.eql(.{ .terminal = old_id })) invalid.selection = .{ .terminal = exhausted };
    for (&invalid.attachments) |*attached| {
        if (attached.* != null and attached.*.? == old_id) attached.* = exhausted;
    }
    try testing.expectError(error.InvalidTopology, invalid.validate());
}

test "normalizing topology leaves an explicit Web selection alone" {
    const sessions = try createDefaultSessions();
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);

    // Web is a choice, not a dangling selection. Normalization runs on every
    // provider publication, so it must not yank the operator back to a
    // terminal just because no terminal is selected.
    model.selected_surface = .web;
    model.normalizeTopology();
    try testing.expect(model.selected_surface.eql(.web));
    try testing.expectEqual(app.LayoutMode.single, model.layout);

    // A selection naming a terminal that is gone IS repaired.
    model.selected_surface = .{ .terminal = try remoteRef(72) };
    model.normalizeTopology();
    try testing.expect(model.selectedTerminalRef() != null);
    try testing.expect(model.selectedTerminalRef().?.eql(model.terminal_order[0]));
}
