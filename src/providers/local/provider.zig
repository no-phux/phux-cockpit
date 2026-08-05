const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const grid = @import("../../terminal/grid.zig");
const provider_contract = @import("provider_contract");

pub const LocalTerminalId = provider_contract.LocalTerminalId;
pub const TerminalRef = provider_contract.TerminalRef;
pub const ReplicaOwner = provider_contract.ReplicaOwner;
pub const Phase = provider_contract.Phase;

/// The local registry ceiling. A tab owns a tree of at most
/// `layout.max_panes` panes and there can be many tabs, so the registry is
/// sized for the whole window rather than for one pane pair. 32 is far past
/// what a person keeps alive and still leaves the registry a flat, scannable
/// array.
pub const max_terminals: usize = 32;
pub const first_terminal_raw: u64 = @intFromEnum(LocalTerminalId.terminal_1);
pub const clipboard_key: u64 = 100;
pub const paste_clipboard_key: u64 = 101;
pub const outbound_buffer_bytes: usize = 64 * 1024;

const default_shell: []const u8 = if (builtin.os.tag == .macos)
    "/bin/zsh"
else if (builtin.os.tag == .windows)
    "cmd.exe"
else
    "/bin/sh";

const default_shell_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{default_shell}
else
    &.{ default_shell, "-i" };

/// Every local terminal spawns the SAME login shell. There was never a
/// per-slot argv distinction — the old `terminal_1_argv`/`terminal_2_argv`
/// pair held identical text — and a registry of 32 uniform slots cannot
/// carry a per-index table anyway.
const shell_argv: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }
else
    default_shell_argv;

pub fn localRef(id: LocalTerminalId) TerminalRef {
    return .{ .provider_id = .local, .terminal_id = .{ .local = id } };
}

pub fn initialTerminalId(index: usize) LocalTerminalId {
    return @enumFromInt(first_terminal_raw + index);
}

pub fn initialTerminalRef(index: usize) TerminalRef {
    return localRef(initialTerminalId(index));
}

pub fn ptyKey(index: usize) u64 {
    return 1 + index;
}

pub fn paneArgv(_: usize) []const []const u8 {
    return shell_argv;
}

pub const Pane = struct {
    id: TerminalRef,
    session: *grid.Session,
    pty_key: u64 = 1,
    argv: []const []const u8 = default_shell_argv,
    phase: Phase = .starting,
    session_generation: u64 = 0,
    exit_code: i32 = 0,
    exit_signal: i32 = 0,
    exit_reason: native_sdk.EffectExitReason = .exited,
    cols: u16 = 80,
    rows: u16 = 24,
    selecting: bool = false,
    copied_bytes: u64 = 0,
    macos_natural_keys_held: u8 = 0,
    copy_failed: bool = false,
    scrollback_wheel_accum: f32 = 0,
    mouse_wheel_y_accum: f32 = 0,
    mouse_wheel_x_accum: f32 = 0,
    mouse_wheel_next_horizontal: bool = false,
    mouse_last_cell: ?vt.Coordinate = null,
    mouse_protocol_fingerprint: u8 = 0,
    output_batches: u64 = 0,
    output_bytes: u64 = 0,
    write_refusals: u32 = 0,
    write_refusals_total: u32 = 0,
    native_delivery_failures: u32 = 0,
    outbound_buffer: [outbound_buffer_bytes]u8 = undefined,
    outbound_head: usize = 0,
    outbound_len: usize = 0,
    outbound_dropped: u64 = 0,

    pub fn acceptsInput(pane: *const Pane) bool {
        return pane.phase == .starting or pane.phase == .live;
    }
};

/// A slot is either free or holds a live terminal. There is no `.closing`
/// tombstone: close destroys the session eagerly and frees the slot, because
/// a tombstone waiting on a pty exit that may never arrive held both a
/// registry slot and a whole emulator hostage. Identity never repeats
/// (`next_terminal_raw` and `next_pty_key` only move forward), so a late
/// event for a retired terminal resolves to no slot and is ignored.
pub const RegistryState = enum { vacant, active };

pub fn replicaOwnerForPane(pane: *const Pane) ReplicaOwner {
    return provider_contract.localReplicaOwner(pane.id, pane.session_generation);
}

pub const LocalProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// ONE uniform array. The old split between an eager `terminals[2]` and
    /// an `overflow` tail encoded the two-pane workspace in the registry and
    /// forced every caller through an index-translating accessor.
    slots: [max_terminals]Pane = undefined,
    states: [max_terminals]RegistryState = @splat(.vacant),
    next_terminal_raw: u64 = first_terminal_raw,
    next_pty_key: u64 = 1,

    pub fn create(gpa: std.mem.Allocator, session: *grid.Session) !*LocalProvider {
        return createWithIo(gpa, std.Io.failing, session);
    }

    /// The window opens with exactly ONE terminal. Every further terminal is
    /// minted by `createTerminal`, which allocates its session then — the app
    /// no longer pre-allocates emulators for panes nobody asked for.
    pub fn createWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !*LocalProvider {
        const provider = try gpa.create(LocalProvider);
        provider.* = .{ .gpa = gpa, .io = io };
        provider.slots[0] = .{
            .id = initialTerminalRef(0),
            .session = session,
            .pty_key = ptyKey(0),
            .argv = shell_argv,
        };
        provider.states[0] = .active;
        provider.next_terminal_raw = first_terminal_raw + 1;
        provider.next_pty_key = 2;
        return provider;
    }

    pub fn createSingleWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !*LocalProvider {
        return createWithIo(gpa, io, session);
    }

    pub fn destroy(provider: *LocalProvider) void {
        const gpa = provider.gpa;
        for (0..max_terminals) |index| {
            if (provider.states[index] == .active) provider.slots[index].session.destroy();
        }
        gpa.destroy(provider);
    }

    pub fn slot(provider: *LocalProvider, index: usize) *Pane {
        return &provider.slots[index];
    }

    pub fn slotConst(provider: *const LocalProvider, index: usize) *const Pane {
        return &provider.slots[index];
    }

    pub fn activeCount(provider: *const LocalProvider) usize {
        var count: usize = 0;
        for (provider.states) |state| if (state == .active) {
            count += 1;
        };
        return count;
    }

    /// Occupancy IS the active count now that closing frees eagerly. Kept as
    /// its own name because callers ask two different questions of it.
    pub fn occupiedCount(provider: *const LocalProvider) usize {
        return provider.activeCount();
    }

    pub fn slotIndex(provider: *const LocalProvider, terminal_ref: TerminalRef) ?usize {
        if (!provider_contract.isLocal(terminal_ref)) return null;
        for (0..max_terminals) |index| {
            if (provider.states[index] != .active) continue;
            if (provider.slots[index].id.eql(terminal_ref)) return index;
        }
        return null;
    }

    pub fn terminal(provider: *LocalProvider, terminal_ref: TerminalRef) ?*Pane {
        const index = provider.slotIndex(terminal_ref) orelse return null;
        return &provider.slots[index];
    }

    pub fn terminalConst(provider: *const LocalProvider, terminal_ref: TerminalRef) ?*const Pane {
        const index = provider.slotIndex(terminal_ref) orelse return null;
        return &provider.slots[index];
    }

    pub fn terminalRefs(provider: *const LocalProvider, out: []TerminalRef) usize {
        var count: usize = 0;
        for (0..max_terminals) |index| {
            if (count == out.len) break;
            if (provider.states[index] != .active) continue;
            out[count] = provider.slots[index].id;
            count += 1;
        }
        return count;
    }

    pub fn contains(provider: *const LocalProvider, terminal_ref: TerminalRef) bool {
        return provider.terminalConst(terminal_ref) != null;
    }

    pub fn owner(provider: *const LocalProvider, terminal_ref: TerminalRef) ?ReplicaOwner {
        const pane = provider.terminalConst(terminal_ref) orelse return null;
        return replicaOwnerForPane(pane);
    }

    pub fn ownerIsCurrent(provider: *const LocalProvider, owner_value: ReplicaOwner) bool {
        const current = provider.owner(owner_value.terminal_ref) orelse return false;
        return current.eql(owner_value);
    }

    pub fn terminalForPty(provider: *LocalProvider, key: u64) ?*Pane {
        for (0..max_terminals) |index| {
            if (provider.states[index] != .active) continue;
            if (provider.slots[index].pty_key == key) return &provider.slots[index];
        }
        return null;
    }

    pub fn createTerminal(provider: *LocalProvider) !*Pane {
        if (provider.activeCount() >= max_terminals) return error.TerminalCapacityReached;
        if (provider.next_terminal_raw >= std.math.maxInt(u64) - 1 or provider.next_pty_key >= std.math.maxInt(u64) - 1) return error.TerminalIdentityExhausted;
        const next_ref = localRef(@enumFromInt(provider.next_terminal_raw));
        for (0..max_terminals) |occupied| {
            if (provider.states[occupied] != .active) continue;
            const existing = provider.slots[occupied];
            if (existing.id.eql(next_ref) or existing.pty_key == provider.next_pty_key) return error.TerminalIdentityCollision;
        }
        if (provider.next_pty_key == clipboard_key or provider.next_pty_key == paste_clipboard_key) return error.TerminalIdentityCollision;
        var index: usize = 0;
        while (index < max_terminals and provider.states[index] != .vacant) : (index += 1) {}
        if (index == max_terminals) return error.TerminalCapacityReached;
        // The session is allocated HERE, at the moment a terminal is asked
        // for, not eagerly at startup for panes that may never exist.
        const session = try grid.Session.create(provider.gpa, provider.io, 80, 24);
        errdefer session.destroy();
        provider.slots[index] = .{
            .id = next_ref,
            .session = session,
            .pty_key = provider.next_pty_key,
            .argv = shell_argv,
        };
        provider.next_terminal_raw += 1;
        provider.next_pty_key += 1;
        provider.states[index] = .active;
        return &provider.slots[index];
    }

    /// Retire a terminal for good: the emulator is freed immediately and the
    /// slot returns to the pool. The caller is responsible for having already
    /// killed the pty and ended any effect keyed to this terminal — nothing
    /// here can be reached through the freed session afterwards.
    pub fn destroyTerminal(provider: *LocalProvider, id: TerminalRef) bool {
        const index = provider.slotIndex(id) orelse return false;
        provider.slots[index].session.destroy();
        provider.states[index] = .vacant;
        return true;
    }
};

pub const Provider = LocalProvider;
