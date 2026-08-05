const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const testing = std.testing;

const createDefaultSession = support.createDefaultSession;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;
const remoteRef = support.remoteTerminalRef;

test "versioned snapshot restores the tab trees into fresh sessions without process state" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .{ .move_terminal = -1 }, &state.effects);
    // A real split inside the selected tab: the snapshot has to carry a
    // BRANCH, which the old two-pane schema could not express.
    app.update(&state.model, .split_down, &state.effects);
    const branch = state.model.tabs[state.model.selected_tab].root;
    state.model.tabs[state.model.selected_tab].setFraction(branch, 0.63);
    state.model.tab_placement = .side;
    const live_id = state.model.selectedTerminalId().?;
    const live_session = state.model.provider.terminal(live_id).?.session;
    live_session.feed("runtime state is intentionally not persisted");

    const snapshot = try state.model.topologySnapshot();
    try snapshot.validate();
    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v2 = snapshot });
    defer app.deinitModel(&restored);
    try testing.expectEqual(snapshot.version, app.topology_snapshot_version);
    try testing.expectEqual(state.model.tab_count, restored.tab_count);
    try testing.expectEqual(state.model.selected_tab, restored.selected_tab);
    try testing.expectEqual(state.model.tab_placement, restored.tab_placement);

    // The tree shape survives, fraction and focus included.
    for (0..state.model.tab_count) |index| {
        const source = state.model.treeConst(index).?;
        const target = restored.treeConst(index).?;
        try testing.expectEqual(source.paneCount(), target.paneCount());
        try testing.expectEqual(source.focus, target.focus);
        try testing.expectEqual(source.isSplit(), target.isSplit());
    }
    const restored_branch = restored.tabs[restored.selected_tab].root;
    try testing.expectApproxEqAbs(
        @as(f32, 0.63),
        restored.tabs[restored.selected_tab].node(restored_branch).fraction,
        0.0001,
    );
    try testing.expectEqual(
        app.Orientation.vertical,
        restored.tabs[restored.selected_tab].node(restored_branch).orientation,
    );

    const fresh = restored.provider.terminal(live_id) orelse return error.TestExpectedTerminal;
    try testing.expect(fresh.session != live_session);
    try testing.expectEqual(@as(u64, 0), fresh.output_bytes);
    try testing.expectEqual(app.Phase.starting, fresh.phase);
    try testing.expectEqual(@as(u64, 0), fresh.session_generation);
    const text = try fresh.session.plainText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "runtime state") == null);
}

test "legacy migration turns each old terminal into a tab and an old split into a branch" {
    // v0 had no tab/pane distinction at all; v1 had a fixed two-pane
    // workspace. Both are readable ONLY through migration — `validate`
    // rejects either payload handed in as current.
    const migrated = try app.migrateTopologySnapshot(.{ .v0 = .{
        .terminal_count = 4,
        .selected_index = 3,
        .split = true,
        .split_fraction = 0.7,
    } });
    try testing.expectEqual(app.topology_snapshot_version, migrated.version);
    // Four terminals, of which two merged into one split tab: three tabs.
    try testing.expectEqual(@as(u8, 3), migrated.tab_count);
    // The split's two terminals merge into ONE tab, placed where the FIRST
    // of them stood in the old tab order (terminal 4, the selected one), and
    // that tab inherits the selection.
    try testing.expect(migrated.selection.eql(.{ .tab = 2 }));
    const split_tab = migrated.tabs[2];
    try testing.expectEqual(app.Kind.branch, split_tab.nodes[split_tab.root].kind);
    try testing.expectApproxEqAbs(@as(f32, 0.7), split_tab.nodes[split_tab.root].fraction, 0.0001);

    var future = migrated;
    future.version = 99;
    try testing.expectError(error.UnsupportedTopologyVersion, app.migrateTopologySnapshot(.{ .v2 = future }));
    try testing.expectError(error.InvalidTopology, app.migrateTopologySnapshot(.{ .v0 = .{ .terminal_count = 5 } }));

    // A v1 payload with one terminal per tab migrates one-for-one.
    const from_v1 = try app.migrateTopologySnapshot(.{ .v1 = .{
        .terminal_count = 2,
        .terminal_order = .{ .terminal_1, .terminal_2, .terminal_1, .terminal_1 },
        .selection = .terminal_2,
        .attachments = .{ .terminal_1, null },
        .tab_placement = .side,
    } });
    try testing.expectEqual(@as(u8, 2), from_v1.tab_count);
    try testing.expect(from_v1.selection.eql(.{ .tab = 1 }));
    try testing.expectEqual(app.TabPlacement.side, from_v1.tab_placement);
    // A duplicate in the old tab order is not migratable topology.
    try testing.expectError(error.InvalidTopology, app.migrateTopologySnapshot(.{ .v1 = .{
        .terminal_count = 2,
        .terminal_order = .{ .terminal_1, .terminal_1, .terminal_1, .terminal_1 },
    } }));
}

test "canonical snapshots reject topology rewrites and round trip exactly" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    app.update(&state.model, .new_terminal, &state.effects);
    app.update(&state.model, .split_right, &state.effects);
    const branch = state.model.tabs[state.model.selected_tab].root;
    state.model.tabs[state.model.selected_tab].setFraction(branch, 0.63);

    const snapshot = try state.model.topologySnapshot();
    var restored = try app.restoreModel(testing.allocator, testing.io, .{ .v2 = snapshot });
    defer app.deinitModel(&restored);
    try testing.expectEqualDeep(snapshot, try restored.topologySnapshot());
    try testing.expect(!app.process_restoration_supported);

    const selected: usize = switch (snapshot.selection) {
        .tab => |index| index,
        .web => return error.TestExpectedTabSelection,
    };

    // A tab whose focus is a BRANCH is not a workspace: focus is a pane.
    var invalid = snapshot;
    invalid.tabs[selected].focus = invalid.tabs[selected].root;
    try testing.expectError(error.InvalidTopology, invalid.validate());

    // Two panes may never name the SAME terminal, in this tab or another.
    invalid = snapshot;
    const root_node = invalid.tabs[selected].nodes[invalid.tabs[selected].root];
    invalid.tabs[selected].nodes[root_node.second].terminal = invalid.tabs[selected].nodes[root_node.first].terminal;
    try testing.expectError(error.InvalidTopology, invalid.validate());

    // A branch fraction outside the layout bounds is refused.
    invalid = snapshot;
    invalid.tabs[selected].nodes[invalid.tabs[selected].root].fraction = 0.99;
    try testing.expectError(error.InvalidTopology, invalid.validate());

    // A selection naming a tab that is not there is refused.
    invalid = snapshot;
    invalid.selection = .{ .tab = invalid.tab_count };
    try testing.expectError(error.InvalidTopology, invalid.validate());

    // A terminal id past the registry ceiling is refused.
    invalid = snapshot;
    invalid.tabs[0].nodes[invalid.tabs[0].focus].terminal = @enumFromInt(std.math.maxInt(u64) - 1);
    try testing.expectError(error.InvalidTopology, invalid.validate());
}

test "normalizing topology drops panes whose terminal is gone and collapses empty tabs" {
    const session = try createDefaultSession();
    var model = app.initialModel(session);
    defer app.deinitModel(&model);

    // A tab whose only pane names a terminal nobody has is not a tab.
    _ = model.admitTab(try remoteRef(72));
    try testing.expectEqual(@as(usize, 2), model.tab_count);
    model.normalizeTopology();
    try testing.expectEqual(@as(usize, 1), model.tab_count);
    try testing.expect(model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));

    // Web stays a CHOICE: normalization must not yank the operator back to
    // a terminal just because the web surface is up.
    model.selectWeb();
    model.normalizeTopology();
    try testing.expect(model.selectedSurface().eql(.web));
}
