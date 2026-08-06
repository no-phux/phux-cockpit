//! The on-disk form of the workspace layout.
//!
//! FORMAT CHOICE: a line-oriented text file, hand written and hand read, the
//! same shape `config/config.zig` already uses for the config file.
//!
//! The alternatives were ZON (already the language of `app.zon`) and JSON (the
//! SDK ships a `native_sdk.json` primitive). Both were rejected for the same
//! reason: this file is read at STARTUP, from a path a user can edit, after a
//! crash, off a disk that may have half-written it — so the parser's worst
//! case matters more than its expressiveness. A recursive-descent parser over
//! a nested document has a stack depth proportional to the input, which makes
//! "a file of random bytes must never crash" a claim about how deeply the
//! fuzzer happened to nest its brackets. This grammar has NO nesting: one
//! forward pass, one line at a time, fixed work per line, no recursion
//! anywhere. It cannot overflow a stack and it cannot loop. The SDK's JSON
//! primitive was additionally out of the question on capability alone — it
//! reads flat scalar fields out of one object and cannot express an array of
//! trees at all.
//!
//! The snapshot is also a poor fit for a document format: it is fixed-size
//! arrays of scalars, and `TopologySnapshot.validate` already owns every
//! structural claim (reachability, cycles, duplicate terminals, fraction
//! bounds). So the parser's whole job is to fill fields and let `validate`
//! refuse nonsense — which is exactly what it does, and why a hostile file
//! costs one linear scan and a rejection rather than a crash.
//!
//! Truncation is detected rather than inferred: the file ends with an `end`
//! line, so a write cut short — or a read cut at the buffer ceiling — fails
//! the terminator check instead of parsing as a smaller but plausible
//! workspace.

const std = @import("std");
const local = @import("../providers/local/provider.zig");
const layout = @import("layout.zig");
const topology = @import("topology.zig");

pub const TopologySnapshot = topology.TopologySnapshot;
pub const PersistedTopologySnapshot = topology.PersistedTopologySnapshot;
pub const SnapshotTab = topology.SnapshotTab;
pub const SnapshotCwd = topology.SnapshotCwd;
pub const SnapshotSelection = topology.SnapshotSelection;
pub const TabPlacement = topology.TabPlacement;

const max_tabs = topology.max_tabs;
const max_terminals = local.max_terminals;

/// The first token of a well-formed file. A file that does not begin with it
/// is somebody else's file, or noise, and is never parsed further.
pub const magic = "phux-cockpit-state";

/// The last line of a well-formed file.
pub const terminator = "end";

/// The state file's name inside the platform STATE directory. Layout is
/// STATE, not configuration: nobody hand-writes it and losing it costs a
/// session shape, not a setting.
pub const file_name = "workspace.state";

/// Byte ceiling for a whole state file.
///
/// The real bound is small and structural: across the whole window there are
/// at most `max_terminals` leaves and therefore at most `2 * max_terminals - 1`
/// live tree nodes plus `max_tabs` tab headers, and at most `max_terminals`
/// directory lines. 24 KiB is several times that and still a stack-safe
/// buffer for the serializer.
pub const max_state_bytes: usize = 24 * 1024;

/// The oldest on-disk version this reader understands. Older files, and every
/// version from the future, fall back to a fresh launch.
pub const min_readable_version: u16 = 2;

pub fn joinPath(state_dir: []const u8, out: []u8) error{NoSpaceLeft}![]const u8 {
    const separator: []const u8 = if (state_dir.len > 0 and state_dir[state_dir.len - 1] == '/') "" else "/";
    const total = state_dir.len + separator.len + file_name.len;
    if (total > out.len) return error.NoSpaceLeft;
    @memcpy(out[0..state_dir.len], state_dir);
    @memcpy(out[state_dir.len..][0..separator.len], separator);
    @memcpy(out[state_dir.len + separator.len ..][0..file_name.len], file_name);
    return out[0..total];
}

/// Append-only cursor over a fixed buffer. Every write is bounds checked, so
/// a snapshot larger than the ceiling fails the whole serialization rather
/// than emitting a prefix that would read back as a smaller workspace.
const Emitter = struct {
    out: []u8,
    len: usize = 0,

    fn print(emitter: *Emitter, comptime fmt: []const u8, args: anytype) error{NoSpaceLeft}!void {
        const written = try std.fmt.bufPrint(emitter.out[emitter.len..], fmt, args);
        emitter.len += written.len;
    }

    fn raw(emitter: *Emitter, bytes: []const u8) error{NoSpaceLeft}!void {
        if (emitter.len + bytes.len > emitter.out.len) return error.NoSpaceLeft;
        @memcpy(emitter.out[emitter.len..][0..bytes.len], bytes);
        emitter.len += bytes.len;
    }
};

/// A node id, with `layout.none` written as `-` so "no node" is a token and
/// not a magic number a reader has to know.
fn emitNodeId(emitter: *Emitter, id: layout.NodeId) error{NoSpaceLeft}!void {
    if (id == layout.none) return emitter.raw("-");
    return emitter.print("{d}", .{id});
}

fn parseNodeId(text: []const u8) ?layout.NodeId {
    if (std.mem.eql(u8, text, "-")) return layout.none;
    const value = std.fmt.parseInt(layout.NodeId, text, 10) catch return null;
    if (value >= layout.max_nodes) return null;
    return value;
}

/// Terminals are written as REGISTRY OFFSETS, not as their raw 64-bit enum
/// values: `validate` already proves every leaf's offset is inside the
/// registry, so the offset is lossless, and it keeps the file readable.
fn parseTerminalOffset(text: []const u8) ?usize {
    const value = std.fmt.parseInt(usize, text, 10) catch return null;
    if (value >= max_terminals) return null;
    return value;
}

fn terminalForOffset(offset: usize) topology.LocalTerminalId {
    return @enumFromInt(local.first_terminal_raw + offset);
}

pub const SerializeError = error{ NoSpaceLeft, UnpersistableTerminal };

pub fn serialize(snapshot: *const TopologySnapshot, out: []u8) SerializeError![]const u8 {
    var emitter: Emitter = .{ .out = out };
    try emitter.print("{s} {d}\n", .{ magic, snapshot.version });
    try emitter.print("placement {s}\n", .{@tagName(snapshot.tab_placement)});
    switch (snapshot.selection) {
        .web => try emitter.raw("selection web\n"),
        .tab => |index| try emitter.print("selection tab {d}\n", .{index}),
    }

    for (snapshot.tabs[0..snapshot.tab_count]) |tab| {
        try emitter.raw("tab ");
        try emitNodeId(&emitter, tab.root);
        try emitter.raw(" ");
        try emitNodeId(&emitter, tab.focus);
        try emitter.raw("\n");
        for (tab.nodes, 0..) |node, index| {
            switch (node.kind) {
                .free => continue,
                .leaf => {
                    // A leaf that never got a terminal is not persistable
                    // structure; `validate` refuses it on the way back in, so
                    // refusing to write it keeps the file honest.
                    const offset = topology.terminalOffset(node.terminal) orelse return error.UnpersistableTerminal;
                    try emitter.print("node {d} leaf ", .{index});
                    try emitNodeId(&emitter, node.parent);
                    try emitter.print(" {d}\n", .{offset});
                },
                .branch => {
                    try emitter.print("node {d} branch ", .{index});
                    try emitNodeId(&emitter, node.parent);
                    // `{d}` on a float is the shortest decimal that reads
                    // back as the same f32, so a divider position survives a
                    // save/load cycle bit for bit.
                    try emitter.print(" {s} {d} ", .{ @tagName(node.orientation), node.fraction });
                    try emitNodeId(&emitter, node.first);
                    try emitter.raw(" ");
                    try emitNodeId(&emitter, node.second);
                    try emitter.raw("\n");
                },
            }
        }
    }

    for (snapshot.cwds, 0..) |cwd, offset| {
        const path = cwd.slice();
        if (path.len == 0) continue;
        try emitter.print("cwd {d} {s}\n", .{ offset, path });
    }

    try emitter.print("{s}\n", .{terminator});
    return emitter.out[0..emitter.len];
}

/// Where a parsed file's tab structure lands. Two on-disk versions share one
/// tree schema, so the parser writes THROUGH pointers into whichever union arm
/// the version selected instead of parsing into a scratch snapshot and copying
/// twenty kilobytes. `cwds` is null for a version that had no working
/// directories, which makes a `cwd` line in a v2 file a parse failure rather
/// than a silently ignored line.
const Sink = struct {
    tabs: *[max_tabs]SnapshotTab,
    tab_count: *u8,
    selection: *SnapshotSelection,
    tab_placement: *TabPlacement,
    cwds: ?*[max_terminals]SnapshotCwd,
};

/// Read a state file. `true` means `out` holds a payload worth migrating;
/// `false` means "there was no usable state here", which is the normal case
/// for a first launch and the ONLY outcome for anything corrupt, truncated,
/// empty, or from a future version.
///
/// Strict on purpose: an unknown keyword, a malformed number, a missing
/// terminator, or a second `selection` line rejects the WHOLE file. A layout
/// half-read from a damaged file is worse than a fresh window, because the
/// user cannot tell which of their tabs the parser decided to keep.
pub fn parse(bytes: []const u8, out: *PersistedTopologySnapshot) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = std.mem.trimEnd(u8, lines.next() orelse return false, "\r");
    var header_fields = std.mem.tokenizeScalar(u8, header, ' ');
    if (!std.mem.eql(u8, header_fields.next() orelse return false, magic)) return false;
    const version = std.fmt.parseInt(u16, header_fields.next() orelse return false, 10) catch return false;
    if (header_fields.next() != null) return false;
    if (version < min_readable_version or version > topology.topology_snapshot_version) return false;

    const sink: Sink = switch (version) {
        2 => blk: {
            out.* = .{ .v2 = .{} };
            break :blk .{
                .tabs = &out.v2.tabs,
                .tab_count = &out.v2.tab_count,
                .selection = &out.v2.selection,
                .tab_placement = &out.v2.tab_placement,
                .cwds = null,
            };
        },
        else => blk: {
            out.* = .{ .v3 = .{} };
            break :blk .{
                .tabs = &out.v3.tabs,
                .tab_count = &out.v3.tab_count,
                .selection = &out.v3.selection,
                .tab_placement = &out.v3.tab_placement,
                .cwds = &out.v3.cwds,
            };
        },
    };

    var placement_seen = false;
    var selection_seen = false;
    var terminated = false;
    var tabs: usize = 0;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        // Nothing may follow the terminator: trailing structure means the
        // file was concatenated or rewritten over a longer one.
        if (terminated) return false;

        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const keyword = fields.next() orelse continue;

        if (std.mem.eql(u8, keyword, terminator)) {
            if (fields.next() != null) return false;
            terminated = true;
            continue;
        }

        if (std.mem.eql(u8, keyword, "placement")) {
            if (placement_seen) return false;
            placement_seen = true;
            const value = fields.next() orelse return false;
            if (fields.next() != null) return false;
            if (std.mem.eql(u8, value, "top")) {
                sink.tab_placement.* = .top;
            } else if (std.mem.eql(u8, value, "side")) {
                sink.tab_placement.* = .side;
            } else return false;
            continue;
        }

        if (std.mem.eql(u8, keyword, "selection")) {
            if (selection_seen) return false;
            selection_seen = true;
            const value = fields.next() orelse return false;
            if (std.mem.eql(u8, value, "web")) {
                if (fields.next() != null) return false;
                sink.selection.* = .web;
            } else if (std.mem.eql(u8, value, "tab")) {
                const index = std.fmt.parseInt(u8, fields.next() orelse return false, 10) catch return false;
                if (fields.next() != null) return false;
                sink.selection.* = .{ .tab = index };
            } else return false;
            continue;
        }

        if (std.mem.eql(u8, keyword, "tab")) {
            if (tabs >= max_tabs) return false;
            const root = parseNodeId(fields.next() orelse return false) orelse return false;
            const focus = parseNodeId(fields.next() orelse return false) orelse return false;
            if (fields.next() != null) return false;
            sink.tabs[tabs] = .{ .root = root, .focus = focus };
            tabs += 1;
            continue;
        }

        if (std.mem.eql(u8, keyword, "node")) {
            // A node line before any `tab` line has no tree to belong to.
            if (tabs == 0) return false;
            const tab = &sink.tabs[tabs - 1];
            const index = std.fmt.parseInt(usize, fields.next() orelse return false, 10) catch return false;
            if (index >= layout.max_nodes) return false;
            // Two lines writing one slot is a corrupt file, not a last-writer
            // -wins update: `validate` would accept the survivor and the user
            // would silently lose a pane.
            if (tab.nodes[index].kind != .free) return false;
            const kind = fields.next() orelse return false;
            const parent = parseNodeId(fields.next() orelse return false) orelse return false;

            if (std.mem.eql(u8, kind, "leaf")) {
                const offset = parseTerminalOffset(fields.next() orelse return false) orelse return false;
                if (fields.next() != null) return false;
                tab.nodes[index] = .{
                    .kind = .leaf,
                    .parent = parent,
                    .terminal = terminalForOffset(offset),
                    .has_terminal = true,
                };
                continue;
            }
            if (std.mem.eql(u8, kind, "branch")) {
                const orientation_text = fields.next() orelse return false;
                const orientation: layout.Orientation = if (std.mem.eql(u8, orientation_text, "horizontal"))
                    .horizontal
                else if (std.mem.eql(u8, orientation_text, "vertical"))
                    .vertical
                else
                    return false;
                const fraction = std.fmt.parseFloat(f32, fields.next() orelse return false) catch return false;
                // A non-finite fraction would survive into `splitRect`; the
                // structural validator refuses it too, but refusing here keeps
                // NaN out of the snapshot entirely.
                if (!std.math.isFinite(fraction)) return false;
                const first = parseNodeId(fields.next() orelse return false) orelse return false;
                const second = parseNodeId(fields.next() orelse return false) orelse return false;
                if (fields.next() != null) return false;
                tab.nodes[index] = .{
                    .kind = .branch,
                    .parent = parent,
                    .orientation = orientation,
                    .fraction = fraction,
                    .first = first,
                    .second = second,
                };
                continue;
            }
            return false;
        }

        if (std.mem.eql(u8, keyword, "cwd")) {
            const cwds = sink.cwds orelse return false;
            const offset_text = fields.next() orelse return false;
            const offset = parseTerminalOffset(offset_text) orelse return false;
            // The path is the REST of the line, verbatim: directory names
            // contain spaces, and splitting on them would corrupt one. The
            // rest starts one byte past the offset token inside `line`.
            const consumed = (@intFromPtr(offset_text.ptr) - @intFromPtr(line.ptr)) + offset_text.len;
            if (consumed + 1 >= line.len) return false;
            cwds[offset].set(line[consumed + 1 ..]);
            continue;
        }

        return false;
    }

    if (!terminated) return false;
    sink.tab_count.* = @intCast(tabs);
    return true;
}
