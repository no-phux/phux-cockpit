const std = @import("std");
const local = @import("../providers/local/provider.zig");
const support = @import("phux_support.zig");

pub const LocalTerminalId = support.LocalTerminalId;
pub const TerminalRef = support.TerminalRef;
pub const pane_count = local.pane_count;
pub const max_terminal_count = local.max_terminal_count;

pub const TabPlacement = enum { top, side };
pub const LayoutMode = enum { single, split };

pub const Placement = enum(u8) {
    primary,
    secondary,

    pub fn index(placement: Placement) usize {
        return @intFromEnum(placement);
    }

    pub fn fromIndex(raw_index: usize) ?Placement {
        return switch (raw_index) {
            0 => .primary,
            1 => .secondary,
            else => null,
        };
    }
};

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

pub const topology_snapshot_version: u16 = 1;
pub const process_restoration_supported = false;

pub const SnapshotSelection = union(enum) {
    terminal: LocalTerminalId,
    web,

    pub fn eql(a: SnapshotSelection, b: SnapshotSelection) bool {
        return switch (a) {
            .terminal => |id| switch (b) {
                .terminal => |other| id == other,
                .web => false,
            },
            .web => b == .web,
        };
    }
};

pub const TopologySnapshot = struct {
    version: u16 = topology_snapshot_version,
    terminal_count: u8 = 0,
    terminal_order: [max_terminal_count]LocalTerminalId = [_]LocalTerminalId{.terminal_1} ** max_terminal_count,
    selection: SnapshotSelection = .web,
    layout: LayoutMode = .single,
    split_fraction: f32 = 0.5,
    attachments: [pane_count]?LocalTerminalId = .{ null, null },
    focused_attachment: Placement = .primary,
    tab_placement: TabPlacement = .top,

    pub fn validate(snapshot: TopologySnapshot) !void {
        if (snapshot.version != topology_snapshot_version) return error.UnsupportedTopologyVersion;
        if (snapshot.terminal_count > max_terminal_count) return error.InvalidTopology;
        const count: usize = snapshot.terminal_count;
        for (snapshot.terminal_order[0..count], 0..) |id, index| {
            const raw = @intFromEnum(id);
            if (raw < local.first_terminal_raw or raw >= std.math.maxInt(u64) - 1) return error.InvalidTopology;
            for (snapshot.terminal_order[0..index]) |prior| {
                if (prior == id) return error.InvalidTopology;
            }
        }
        for (snapshot.terminal_order[count..]) |id| {
            if (id != .terminal_1) return error.InvalidTopology;
        }
        switch (snapshot.selection) {
            .terminal => |id| if (indexOfSnapshotTerminal(snapshot, id) == null) return error.InvalidTopology,
            .web => {},
        }
        for (snapshot.attachments) |attached| if (attached) |id| {
            if (indexOfSnapshotTerminal(snapshot, id) == null) return error.InvalidTopology;
        };
        if (snapshot.attachments[0] != null and snapshot.attachments[1] != null and
            snapshot.attachments[0].? == snapshot.attachments[1].?) return error.InvalidTopology;
        if (!std.math.isFinite(snapshot.split_fraction) or snapshot.split_fraction < 0.05 or snapshot.split_fraction > 0.95) return error.InvalidTopology;
        if (count == 0) {
            if (!snapshot.selection.eql(.web) or snapshot.layout != .single or
                snapshot.attachments[0] != null or snapshot.attachments[1] != null or
                snapshot.focused_attachment != .primary) return error.InvalidTopology;
            return;
        }
        if (snapshot.layout == .split and (snapshot.attachments[0] == null or snapshot.attachments[1] == null)) return error.InvalidTopology;
        const focused = snapshot.attachments[snapshot.focused_attachment.index()];
        switch (snapshot.selection) {
            .terminal => |id| if (focused == null or focused.? != id) return error.InvalidTopology,
            .web => {
                if ((snapshot.attachments[0] != null or snapshot.attachments[1] != null) and focused == null) return error.InvalidTopology;
            },
        }
    }
};

pub const LegacyTopologySnapshotV0 = struct {
    terminal_count: u8 = pane_count,
    selected_index: u8 = 0,
    split: bool = false,
    split_fraction: f32 = 0.5,
};

pub const PersistedTopologySnapshot = union(enum) {
    v0: LegacyTopologySnapshotV0,
    v1: TopologySnapshot,
};

fn indexOfSnapshotTerminal(snapshot: TopologySnapshot, id: LocalTerminalId) ?usize {
    for (snapshot.terminal_order[0..snapshot.terminal_count], 0..) |candidate, index| {
        if (candidate == id) return index;
    }
    return null;
}

pub fn migrateTopologySnapshot(persisted: PersistedTopologySnapshot) !TopologySnapshot {
    const snapshot = switch (persisted) {
        .v1 => |current| current,
        .v0 => |legacy| blk: {
            if (legacy.terminal_count > max_terminal_count or !std.math.isFinite(legacy.split_fraction)) return error.InvalidTopology;
            var migrated: TopologySnapshot = .{
                .terminal_count = legacy.terminal_count,
                .layout = if (legacy.split and legacy.terminal_count >= 2) .split else .single,
                .split_fraction = std.math.clamp(legacy.split_fraction, 0.05, 0.95),
            };
            for (0..legacy.terminal_count) |index| {
                migrated.terminal_order[index] = @enumFromInt(local.first_terminal_raw + index);
            }
            if (legacy.terminal_count > 0) {
                const selected = @min(@as(usize, legacy.selected_index), legacy.terminal_count - 1);
                migrated.selection = .{ .terminal = migrated.terminal_order[selected] };
                migrated.attachments[0] = migrated.terminal_order[selected];
                if (migrated.layout == .split) migrated.attachments[1] = migrated.terminal_order[if (selected == 0) 1 else 0];
            }
            break :blk migrated;
        },
    };
    try snapshot.validate();
    return snapshot;
}
