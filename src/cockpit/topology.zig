const std = @import("std");
const local = @import("../providers/local/provider.zig");
const layout = @import("layout.zig");
const support = @import("phux_support.zig");

pub const LocalTerminalId = support.LocalTerminalId;
pub const TerminalRef = support.TerminalRef;
pub const max_terminals = local.max_terminals;

/// Tabs per window. A tab owns a `layout.Tree`; the tree owns up to
/// `layout.max_panes` terminals. Both ceilings are structural, not policy.
pub const max_tabs: usize = 16;

pub const TabPlacement = enum { top, side };

pub const SurfaceSelection = union(enum) {
    terminal: TerminalRef,
    web,

    pub fn eql(a: SurfaceSelection, b: SurfaceSelection) bool {
        return switch (a) {
            .terminal => |id| switch (b) {
                .terminal => |other| id.eql(other),
                .web => false,
            },
            .web => switch (b) {
                .web => true,
                .terminal => false,
            },
        };
    }
};

/// v2 is the tree schema. v1 encoded a fixed two-pane workspace
/// (`layout: {single,split}`, `attachments[2]`, one `split_fraction`,
/// `focused_attachment`) and cannot express a tab that owns a nested tree,
/// so it is MIGRATED, not read: every v1 terminal becomes its own tab, and a
/// v1 split becomes a horizontal split inside the focused tab.
pub const topology_snapshot_version: u16 = 2;
pub const process_restoration_supported = false;

pub const SnapshotSelection = union(enum) {
    tab: u8,
    web,

    pub fn eql(a: SnapshotSelection, b: SnapshotSelection) bool {
        return switch (a) {
            .tab => |index| switch (b) {
                .tab => |other| index == other,
                .web => false,
            },
            .web => b == .web,
        };
    }
};

/// One node of a serialized tree, in the same index space the live tree
/// uses. `terminal` is meaningful for leaves; `first`/`second`/`fraction`
/// for branches.
pub const SnapshotNode = struct {
    kind: layout.Kind = .free,
    parent: layout.NodeId = layout.none,
    terminal: LocalTerminalId = .terminal_1,
    has_terminal: bool = false,
    orientation: layout.Orientation = .horizontal,
    fraction: f32 = 0.5,
    first: layout.NodeId = layout.none,
    second: layout.NodeId = layout.none,
};

/// A serialized tab: its whole tree plus which leaf held focus.
pub const SnapshotTab = struct {
    nodes: [layout.max_nodes]SnapshotNode = [_]SnapshotNode{.{}} ** layout.max_nodes,
    root: layout.NodeId = layout.none,
    focus: layout.NodeId = layout.none,
};

pub const TopologySnapshot = struct {
    version: u16 = topology_snapshot_version,
    tab_count: u8 = 0,
    tabs: [max_tabs]SnapshotTab = [_]SnapshotTab{.{}} ** max_tabs,
    selection: SnapshotSelection = .web,
    tab_placement: TabPlacement = .top,

    pub fn validate(snapshot: TopologySnapshot) !void {
        if (snapshot.version != topology_snapshot_version) return error.UnsupportedTopologyVersion;
        if (snapshot.tab_count > max_tabs) return error.InvalidTopology;
        const count: usize = snapshot.tab_count;

        // Terminal identity is window-wide: the same terminal may never be a
        // leaf in two panes, in this tab or another, because two panes would
        // then drive one emulator.
        var seen: [max_terminals]bool = @splat(false);
        var total_panes: usize = 0;

        for (snapshot.tabs[0..count]) |tab| {
            if (tab.root == layout.none or tab.root >= layout.max_nodes) return error.InvalidTopology;
            if (tab.focus == layout.none or tab.focus >= layout.max_nodes) return error.InvalidTopology;
            if (tab.nodes[tab.focus].kind != .leaf) return error.InvalidTopology;
            if (tab.nodes[tab.root].parent != layout.none) return error.InvalidTopology;

            var reachable: [layout.max_nodes]bool = @splat(false);
            try walkSnapshotNode(tab, tab.root, &reachable);
            if (!reachable[tab.focus]) return error.InvalidTopology;

            for (tab.nodes, 0..) |node, index| {
                if (node.kind == .free) continue;
                if (!reachable[index]) return error.InvalidTopology;
                if (node.kind != .leaf) continue;
                if (!node.has_terminal) return error.InvalidTopology;
                const raw = @intFromEnum(node.terminal);
                if (raw < local.first_terminal_raw or raw >= std.math.maxInt(u64) - 1) return error.InvalidTopology;
                const offset = raw - local.first_terminal_raw;
                if (offset >= max_terminals) return error.InvalidTopology;
                if (seen[offset]) return error.InvalidTopology;
                seen[offset] = true;
                total_panes += 1;
            }
        }
        if (total_panes > max_terminals) return error.InvalidTopology;

        // Tabs past the count must be blank, so a truncated write cannot be
        // read back as extra structure.
        for (snapshot.tabs[count..]) |tab| {
            if (tab.root != layout.none or tab.focus != layout.none) return error.InvalidTopology;
        }

        switch (snapshot.selection) {
            .tab => |index| if (index >= count) return error.InvalidTopology,
            .web => {},
        }
        if (count == 0 and snapshot.selection != .web) return error.InvalidTopology;
    }
};

fn walkSnapshotNode(tab: SnapshotTab, id: layout.NodeId, reachable: *[layout.max_nodes]bool) !void {
    if (id >= layout.max_nodes) return error.InvalidTopology;
    if (reachable[id]) return error.InvalidTopology; // a cycle or a shared child
    reachable[id] = true;
    const node = tab.nodes[id];
    switch (node.kind) {
        .free => return error.InvalidTopology,
        .leaf => {
            if (node.first != layout.none or node.second != layout.none) return error.InvalidTopology;
        },
        .branch => {
            if (node.first == layout.none or node.second == layout.none) return error.InvalidTopology;
            if (!std.math.isFinite(node.fraction) or
                node.fraction < layout.min_fraction or node.fraction > layout.max_fraction) return error.InvalidTopology;
            if (tab.nodes[node.first].parent != id or tab.nodes[node.second].parent != id) return error.InvalidTopology;
            try walkSnapshotNode(tab, node.first, reachable);
            try walkSnapshotNode(tab, node.second, reachable);
        },
    }
}

/// The pre-tree schemas. v0 was a bare count-and-flag; v1 was the two-pane
/// attachment model. Both are readable only through migration.
pub const LegacyTopologySnapshotV0 = struct {
    terminal_count: u8 = 1,
    selected_index: u8 = 0,
    split: bool = false,
    split_fraction: f32 = 0.5,
};

pub const LegacyTopologySnapshotV1 = struct {
    terminal_count: u8 = 0,
    terminal_order: [4]LocalTerminalId = [_]LocalTerminalId{.terminal_1} ** 4,
    /// null selects the web surface, matching v1's `SnapshotSelection`.
    selection: ?LocalTerminalId = null,
    split: bool = false,
    split_fraction: f32 = 0.5,
    attachments: [2]?LocalTerminalId = .{ null, null },
    focused_attachment: u8 = 0,
    tab_placement: TabPlacement = .top,
};

pub const PersistedTopologySnapshot = union(enum) {
    v0: LegacyTopologySnapshotV0,
    v1: LegacyTopologySnapshotV1,
    v2: TopologySnapshot,
};

/// Build a one-leaf tab. Every migration path lands here: a legacy terminal
/// had no pane structure of its own, so it becomes a tab holding one pane.
pub fn singleLeafTab(id: LocalTerminalId) SnapshotTab {
    var tab: SnapshotTab = .{};
    tab.nodes[0] = .{ .kind = .leaf, .parent = layout.none, .terminal = id, .has_terminal = true };
    tab.root = 0;
    tab.focus = 0;
    return tab;
}

/// Two leaves under one branch, for a migrated v1 split.
fn splitTab(first: LocalTerminalId, second: LocalTerminalId, fraction: f32, focus_second: bool) SnapshotTab {
    var tab: SnapshotTab = .{};
    tab.nodes[0] = .{ .kind = .leaf, .parent = 2, .terminal = first, .has_terminal = true };
    tab.nodes[1] = .{ .kind = .leaf, .parent = 2, .terminal = second, .has_terminal = true };
    tab.nodes[2] = .{
        .kind = .branch,
        .parent = layout.none,
        .orientation = .horizontal,
        .fraction = std.math.clamp(fraction, layout.min_fraction, layout.max_fraction),
        .first = 0,
        .second = 1,
    };
    tab.root = 2;
    tab.focus = if (focus_second) 1 else 0;
    return tab;
}

pub fn migrateTopologySnapshot(persisted: PersistedTopologySnapshot) !TopologySnapshot {
    const snapshot = switch (persisted) {
        .v2 => |current| current,
        .v1 => |legacy| try migrateV1(legacy),
        .v0 => |legacy| blk: {
            if (legacy.terminal_count > max_tabs or !std.math.isFinite(legacy.split_fraction)) return error.InvalidTopology;
            var v1: LegacyTopologySnapshotV1 = .{
                .terminal_count = legacy.terminal_count,
                .split = legacy.split and legacy.terminal_count >= 2,
                .split_fraction = std.math.clamp(legacy.split_fraction, 0.05, 0.95),
            };
            if (legacy.terminal_count > 4) return error.InvalidTopology;
            for (0..legacy.terminal_count) |index| {
                v1.terminal_order[index] = @enumFromInt(local.first_terminal_raw + index);
            }
            if (legacy.terminal_count > 0) {
                const selected = @min(@as(usize, legacy.selected_index), legacy.terminal_count - 1);
                v1.selection = v1.terminal_order[selected];
                v1.attachments[0] = v1.terminal_order[selected];
                if (v1.split) v1.attachments[1] = v1.terminal_order[if (selected == 0) 1 else 0];
            }
            break :blk try migrateV1(v1);
        },
    };
    try snapshot.validate();
    return snapshot;
}

/// v1 → v2: every terminal in the old tab order becomes its own tab. A v1
/// split had TWO terminals sharing the content area while both also appeared
/// in the tab strip; the tree model has no such duality, so the split's two
/// terminals merge into ONE tab holding a horizontal branch and the second
/// terminal loses its separate tab.
fn migrateV1(legacy: LegacyTopologySnapshotV1) !TopologySnapshot {
    if (legacy.terminal_count > legacy.terminal_order.len) return error.InvalidTopology;
    if (!std.math.isFinite(legacy.split_fraction)) return error.InvalidTopology;
    if (legacy.focused_attachment > 1) return error.InvalidTopology;
    const count: usize = legacy.terminal_count;
    for (legacy.terminal_order[0..count], 0..) |id, index| {
        const raw = @intFromEnum(id);
        if (raw < local.first_terminal_raw or raw >= std.math.maxInt(u64) - 1) return error.InvalidTopology;
        for (legacy.terminal_order[0..index]) |prior| if (prior == id) return error.InvalidTopology;
    }

    const split_pair: ?[2]LocalTerminalId = if (legacy.split and legacy.attachments[0] != null and legacy.attachments[1] != null)
        .{ legacy.attachments[0].?, legacy.attachments[1].? }
    else
        null;

    var migrated: TopologySnapshot = .{ .tab_placement = legacy.tab_placement };
    var tabs: u8 = 0;
    var selected: ?u8 = null;
    for (legacy.terminal_order[0..count]) |id| {
        if (split_pair) |pair| {
            // The split's second terminal is absorbed by the first's tab.
            if (id == pair[1]) continue;
            if (id == pair[0]) {
                migrated.tabs[tabs] = splitTab(
                    pair[0],
                    pair[1],
                    std.math.clamp(legacy.split_fraction, layout.min_fraction, layout.max_fraction),
                    legacy.focused_attachment == 1,
                );
                if (legacy.selection) |chosen| {
                    if (chosen == pair[0] or chosen == pair[1]) selected = tabs;
                }
                tabs += 1;
                continue;
            }
        }
        migrated.tabs[tabs] = singleLeafTab(id);
        if (legacy.selection) |chosen| {
            if (chosen == id) selected = tabs;
        }
        tabs += 1;
    }
    migrated.tab_count = tabs;
    migrated.selection = if (selected) |index| .{ .tab = index } else .web;
    return migrated;
}
