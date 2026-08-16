//! Stable work identities, lineage, and provider binding contracts.
//!
//! These values deliberately have no adapters from topology positions, process
//! IDs, effect keys, or provider generations. Those values cannot prove durable
//! continuity. Provider generations remain ephemeral command fences.
//!
//! The exact 16-byte and canonical text ID encodings below are this module's
//! serialization boundary. Composite persistence codecs belong to p1q.10 so
//! this foundation does not create a competing store format.

const std = @import("std");

pub const IdError = error{
    InvalidLength,
    InvalidText,
    InvalidVersion,
    InvalidVariant,
};

pub const IssueError = error{
    TimestampOutOfRange,
    RandomExhausted,
};

fn StableId(comptime type_name: []const u8) type {
    return struct {
        const Self = @This();

        // Zig has no private struct fields. Callers at trust boundaries must use
        // fromStorage/fromBytes/parse rather than struct literals so validation
        // cannot be bypassed accidentally.
        bytes: [16]u8,

        pub const text_length: usize = 36;
        pub const storage_length: usize = 16;

        pub fn fromStorage(encoded: []const u8) IdError!Self {
            if (encoded.len != storage_length) return error.InvalidLength;
            var bytes: [storage_length]u8 = undefined;
            @memcpy(&bytes, encoded);
            return fromBytes(bytes);
        }

        pub fn fromBytes(bytes: [storage_length]u8) IdError!Self {
            if (bytes[6] >> 4 != 7) return error.InvalidVersion;
            if (bytes[8] >> 6 != 2) return error.InvalidVariant;
            return .{ .bytes = bytes };
        }

        pub fn parse(text: []const u8) IdError!Self {
            if (text.len != text_length) return error.InvalidLength;
            if (text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') {
                return error.InvalidText;
            }

            var bytes: [storage_length]u8 = undefined;
            var source: usize = 0;
            for (&bytes) |*byte| {
                while (source == 8 or source == 13 or source == 18 or source == 23) source += 1;
                const high = hexNibble(text[source]) orelse return error.InvalidText;
                const low = hexNibble(text[source + 1]) orelse return error.InvalidText;
                byte.* = (high << 4) | low;
                source += 2;
            }
            return fromBytes(bytes);
        }

        pub fn toStorage(id: Self) [storage_length]u8 {
            return id.bytes;
        }

        pub fn writeText(id: Self, output: *[text_length]u8) []const u8 {
            const alphabet = "0123456789abcdef";
            var target: usize = 0;
            for (id.bytes, 0..) |byte, index| {
                if (index == 4 or index == 6 or index == 8 or index == 10) {
                    output[target] = '-';
                    target += 1;
                }
                output[target] = alphabet[byte >> 4];
                output[target + 1] = alphabet[byte & 0x0f];
                target += 2;
            }
            return output;
        }

        pub fn eql(a: Self, b: Self) bool {
            return std.mem.eql(u8, &a.bytes, &b.bytes);
        }

        pub fn hash(id: Self) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&id.bytes);
            return hasher.final();
        }

        pub const Context = struct {
            pub fn hash(_: Context, id: Self) u64 {
                return id.hash();
            }

            pub fn eql(_: Context, a: Self, b: Self) bool {
                return a.eql(b);
            }
        };

        pub const name = type_name;
    };
}

pub const ObjectiveId = StableId("ObjectiveId");
pub const RunId = StableId("RunId");
pub const SessionId = StableId("SessionId");
pub const ArtifactId = StableId("ArtifactId");
pub const SignalId = StableId("SignalId");
pub const EventId = StableId("EventId");
pub const ProviderInstanceId = StableId("ProviderInstanceId");
pub const SessionBindingId = StableId("SessionBindingId");
pub const AttachmentId = StableId("AttachmentId");

/// A durable local-runner-owned resource ID, not a PID or registry position.
pub const LocalRunnerSessionId = StableId("LocalRunnerSessionId");

/// Stateful, thread-safe UUIDv7 issuer with a monotonic 74-bit random field.
/// A later process restart obtains a fresh random field from secure entropy;
/// the p1q.10 store will transactionally reject the residual collision case.
pub const Issuer = struct {
    context: *anyopaque,
    nowMilliseconds: *const fn (context: *anyopaque) u64,
    fillEntropy: *const fn (context: *anyopaque, output: []u8) anyerror!void,

    mutex: std.atomic.Mutex = .unlocked,
    has_previous: bool = false,
    previous: [16]u8 = [_]u8{0} ** 16,

    pub fn issue(issuer: *Issuer, comptime Id: type) (IssueError || anyerror)!Id {
        while (!issuer.mutex.tryLock()) std.atomic.spinLoopHint();
        defer issuer.mutex.unlock();

        const observed_timestamp = issuer.nowMilliseconds(issuer.context);
        if (observed_timestamp > 0xffff_ffff_ffff) return error.TimestampOutOfRange;

        var bytes: [16]u8 = undefined;
        if (!issuer.has_previous or observed_timestamp > timestampOf(issuer.previous)) {
            try issuer.fillEntropy(issuer.context, &bytes);
            writeTimestamp(&bytes, observed_timestamp);
            bytes[6] = (bytes[6] & 0x0f) | 0x70;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
        } else {
            bytes = issuer.previous;
            if (!incrementRandom(&bytes)) return error.RandomExhausted;
        }

        issuer.previous = bytes;
        issuer.has_previous = true;
        return Id.fromBytes(bytes) catch unreachable;
    }
};

fn timestampOf(bytes: [16]u8) u64 {
    var timestamp: u64 = 0;
    for (bytes[0..6]) |byte| timestamp = (timestamp << 8) | byte;
    return timestamp;
}

fn writeTimestamp(bytes: *[16]u8, timestamp: u64) void {
    bytes[0] = @truncate(timestamp >> 40);
    bytes[1] = @truncate(timestamp >> 32);
    bytes[2] = @truncate(timestamp >> 24);
    bytes[3] = @truncate(timestamp >> 16);
    bytes[4] = @truncate(timestamp >> 8);
    bytes[5] = @truncate(timestamp);
}

fn incrementRandom(bytes: *[16]u8) bool {
    var index: usize = 16;
    while (index > 9) {
        index -= 1;
        if (bytes[index] != 0xff) {
            bytes[index] += 1;
            return true;
        }
        bytes[index] = 0;
    }
    if ((bytes[8] & 0x3f) != 0x3f) {
        bytes[8] += 1;
        return true;
    }
    bytes[8] = 0x80;
    if (bytes[7] != 0xff) {
        bytes[7] += 1;
        return true;
    }
    bytes[7] = 0;
    if ((bytes[6] & 0x0f) != 0x0f) {
        bytes[6] += 1;
        return true;
    }
    bytes[6] = 0x70;
    return false;
}

pub const ObjectiveState = enum { open, satisfied, abandoned };

pub const ObjectiveRecord = struct {
    id: ObjectiveId,
    state: ObjectiveState,
    revision: u64,
};

pub const RunLifecycle = enum { requested, starting, running, succeeded, failed, canceled };

/// objective_id and ordinal identify this immutable attempt; retry mints a new id.
pub const RunRecord = struct {
    id: RunId,
    objective_id: ObjectiveId,
    ordinal: u64,
    lifecycle: RunLifecycle,
};

pub const SessionKind = enum { terminal };

pub const SessionRecord = struct {
    id: SessionId,
    run_id: RunId,
    kind: SessionKind,
};

/// Logical artifact identity with producer lineage; immutable revisions arrive in p1q.10.
pub const ArtifactRecord = struct {
    id: ArtifactId,
    run_id: RunId,
    producer_session_id: ?SessionId,
};

pub const SignalSource = enum { work, provider, runner };
pub const SignalKind = enum { progress, attention, failure, evidence_gap };
pub const SignalSeverity = enum { info, warning, critical };

/// Immutable fact. Mutable acknowledgement/resolution state is a separate projection.
pub const SignalRecord = struct {
    id: SignalId,
    occurrence_event_id: EventId,
    source: SignalSource,
    kind: SignalKind,
    severity: SignalSeverity,
    objective_id: ?ObjectiveId = null,
    run_id: ?RunId = null,
    session_id: ?SessionId = null,
    artifact_id: ?ArtifactId = null,
};

pub const ProviderKind = enum(u8) { local, phux };

/// Nominal wrappers accept every u32 because the provider protocol establishes
/// no narrower range. Zig struct literals remain a language-level trust boundary.
pub const PhuxTerminalKind = struct {
    raw: u32,

    pub fn init(raw: u32) PhuxTerminalKind {
        return .{ .raw = raw };
    }

    pub fn value(kind: PhuxTerminalKind) u32 {
        return kind.raw;
    }
};

pub const PhuxTerminalId = struct {
    raw: u32,

    pub fn init(raw: u32) PhuxTerminalId {
        return .{ .raw = raw };
    }

    pub fn value(id: PhuxTerminalId) u32 {
        return id.raw;
    }
};

pub const PhuxResourceLocatorError = error{HostTooLong};

/// Replaceable Phux source locator. Host text helps locate the current source,
/// but only the separately stored ProviderInstanceId names its authority.
pub const PhuxResourceLocator = struct {
    pub const max_host_bytes: usize = 255;

    terminal_kind: PhuxTerminalKind,
    terminal_id: PhuxTerminalId,
    host_storage: [max_host_bytes]u8 = [_]u8{0} ** max_host_bytes,
    host_len: u8 = 0,

    pub fn init(kind: PhuxTerminalKind, id: PhuxTerminalId, host_name: []const u8) PhuxResourceLocatorError!PhuxResourceLocator {
        if (host_name.len > max_host_bytes) return error.HostTooLong;
        var locator: PhuxResourceLocator = .{ .terminal_kind = kind, .terminal_id = id };
        @memcpy(locator.host_storage[0..host_name.len], host_name);
        locator.host_len = @intCast(host_name.len);
        return locator;
    }

    pub fn host(locator: *const PhuxResourceLocator) []const u8 {
        return locator.host_storage[0..locator.host_len];
    }

    pub fn sameSource(a: PhuxResourceLocator, b: PhuxResourceLocator) bool {
        return a.terminal_kind.raw == b.terminal_kind.raw and a.terminal_id.raw == b.terminal_id.raw;
    }

    pub fn eql(a: PhuxResourceLocator, b: PhuxResourceLocator) bool {
        return a.sameSource(b) and std.mem.eql(u8, a.host(), b.host());
    }

    pub fn hash(locator: PhuxResourceLocator) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&locator.terminal_kind.raw));
        hasher.update(std.mem.asBytes(&locator.terminal_id.raw));
        hasher.update(locator.host());
        return hasher.final();
    }
};

pub const ProviderResourceLocator = union(ProviderKind) {
    local: LocalRunnerSessionId,
    phux: PhuxResourceLocator,

    pub fn kind(locator: ProviderResourceLocator) ProviderKind {
        return std.meta.activeTag(locator);
    }

    pub fn eql(a: ProviderResourceLocator, b: ProviderResourceLocator) bool {
        return switch (a) {
            .local => |id| switch (b) {
                .local => |other| id.eql(other),
                .phux => false,
            },
            .phux => |id| switch (b) {
                .local => false,
                .phux => |other| id.eql(other),
            },
        };
    }

    pub fn hash(locator: ProviderResourceLocator) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const tag: u8 = @intFromEnum(locator.kind());
        hasher.update(std.mem.asBytes(&tag));
        const child_hash = switch (locator) {
            .local => |id| id.hash(),
            .phux => |id| id.hash(),
        };
        hasher.update(std.mem.asBytes(&child_hash));
        return hasher.final();
    }
};

/// A provider-owned source qualified by the installation/coordinator authority.
pub const ProviderResourceRef = struct {
    provider_instance_id: ProviderInstanceId,
    locator: ProviderResourceLocator,

    pub fn sameAuthority(a: ProviderResourceRef, b: ProviderResourceRef) bool {
        return a.provider_instance_id.eql(b.provider_instance_id) and a.locator.kind() == b.locator.kind();
    }

    pub fn eql(a: ProviderResourceRef, b: ProviderResourceRef) bool {
        return a.sameAuthority(b) and a.locator.eql(b.locator);
    }

    pub fn hash(resource: ProviderResourceRef) u64 {
        var hasher = std.hash.Wyhash.init(0);
        const authority_hash = resource.provider_instance_id.hash();
        const locator_hash = resource.locator.hash();
        hasher.update(std.mem.asBytes(&authority_hash));
        hasher.update(std.mem.asBytes(&locator_hash));
        return hasher.final();
    }

    pub const Context = struct {
        pub fn hash(_: Context, resource: ProviderResourceRef) u64 {
            return resource.hash();
        }

        pub fn eql(_: Context, a: ProviderResourceRef, b: ProviderResourceRef) bool {
            return a.eql(b);
        }
    };
};

pub const SessionLineage = struct {
    objective_id: ObjectiveId,
    run_id: RunId,
    session_id: SessionId,

    pub fn init(objective: ObjectiveRecord, run: RunRecord, session: SessionRecord) error{LineageMismatch}!SessionLineage {
        if (!run.objective_id.eql(objective.id) or !session.run_id.eql(run.id)) return error.LineageMismatch;
        return .{ .objective_id = objective.id, .run_id = run.id, .session_id = session.id };
    }

    pub fn eql(a: SessionLineage, b: SessionLineage) bool {
        return a.objective_id.eql(b.objective_id) and a.run_id.eql(b.run_id) and a.session_id.eql(b.session_id);
    }
};

/// Immutable historical binding. Replacing a locator mints another binding;
/// the SessionId and its lineage remain unchanged.
pub const SessionBinding = struct {
    id: SessionBindingId,
    session_id: SessionId,
    resource: ProviderResourceRef,

    pub fn eql(a: SessionBinding, b: SessionBinding) bool {
        return a.id.eql(b.id) and a.session_id.eql(b.session_id) and a.resource.eql(b.resource);
    }
};

pub const GenerationField = enum { authority, attachment, bootstrap, sequence };
pub const GenerationError = error{GenerationExhausted};

/// Ephemeral stale-command fence. last_seq is progress within an owner and is
/// deliberately excluded from sameOwner.
pub const OwnerGeneration = struct {
    authority_epoch: u64,
    attachment_epoch: u64,
    bootstrap_epoch: u64,
    last_seq: u64,

    pub fn sameOwner(a: OwnerGeneration, b: OwnerGeneration) bool {
        return a.authority_epoch == b.authority_epoch and
            a.attachment_epoch == b.attachment_epoch and
            a.bootstrap_epoch == b.bootstrap_epoch;
    }

    pub fn advanced(generation: OwnerGeneration, field: GenerationField) GenerationError!OwnerGeneration {
        var next = generation;
        switch (field) {
            .authority => next.authority_epoch = std.math.add(u64, next.authority_epoch, 1) catch return error.GenerationExhausted,
            .attachment => next.attachment_epoch = std.math.add(u64, next.attachment_epoch, 1) catch return error.GenerationExhausted,
            .bootstrap => next.bootstrap_epoch = std.math.add(u64, next.bootstrap_epoch, 1) catch return error.GenerationExhausted,
            .sequence => next.last_seq = std.math.add(u64, next.last_seq, 1) catch return error.GenerationExhausted,
        }
        return next;
    }
};

pub const CommandTarget = struct {
    session_id: SessionId,
    binding_id: SessionBindingId,
    generation: OwnerGeneration,

    pub const ValidationError = error{ StaleSession, StaleBinding, StaleGeneration };

    pub fn validate(expected: CommandTarget, current: CommandTarget) ValidationError!void {
        if (!expected.session_id.eql(current.session_id)) return error.StaleSession;
        if (!expected.binding_id.eql(current.binding_id)) return error.StaleBinding;
        if (!expected.generation.sameOwner(current.generation)) return error.StaleGeneration;
    }
};

/// Claims are independent: no capability may be inferred from another one.
pub const CapabilityDescriptor = struct {
    schema_version: u16 = 1,
    durable_execution: bool = false,
    detach_survives_client: bool = false,
    detach_survives_runner_restart: bool = false,
    completed_replay: bool = false,
    input_recording: bool = false,
    output_recording: bool = false,
};

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
}
