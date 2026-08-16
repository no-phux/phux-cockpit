//! Bounded, canonical durable work-event envelope.

const std = @import("std");
const identity = @import("identity.zig");

pub const schema_version: u16 = 1;
pub const max_envelope_bytes: usize = 1024 * 1024;
pub const max_payload_bytes: usize = max_envelope_bytes - fixed_size;
pub const terminal_output_max_bytes: usize = 64 * 1024;
pub const checksum_size: usize = 32;

pub const StreamKind = enum(u8) { objective, run, session, artifact, signal, provider };
pub const Trust = enum(u8) { local, verified_provider, unverified_provider };
pub const Provenance = enum(u8) { local_authority, provider_event, imported };

pub const PayloadKind = enum(u16) {
    objective_created = 1,
    objective_changed,
    objective_closed,
    run_created,
    run_started,
    run_cancel_requested,
    run_finished,
    session_created,
    binding_added,
    binding_retired,
    attachment_opened,
    attachment_closed,
    attachment_rejected,
    session_snapshot,
    terminal_output,
    terminal_resized,
    terminal_metadata,
    session_input_accepted,
    session_input_rejected,
    artifact_declared,
    artifact_revision_committed,
    artifact_purged,
    provider_notice_observed,
    signal_opened,
    signal_updated,
    signal_acknowledged,
    signal_resolved,
    evidence_gap,
    retention_applied,
    source_transition,
};

pub const OptionalIds = struct {
    causation_event_id: ?identity.EventId = null,
    correlation_id: ?[16]u8 = null,
    objective_id: ?identity.ObjectiveId = null,
    run_id: ?identity.RunId = null,
    session_id: ?identity.SessionId = null,
    artifact_id: ?identity.ArtifactId = null,
    signal_id: ?identity.SignalId = null,
};

pub const WorkEvent = struct {
    envelope_version: u16 = schema_version,
    event_id: identity.EventId,
    source_provider_id: identity.ProviderInstanceId,
    stream_kind: StreamKind,
    stream_id: [16]u8,
    stream_incarnation: u64,
    stream_seq: u64,
    occurred_at_ns: i64,
    ingested_at_ns: i64,
    ids: OptionalIds = .{},
    payload_kind: u16,
    payload_version: u16 = 1,
    payload: []const u8,
    trust: Trust,
    provenance: Provenance,
    normalization_version: u16,

    pub fn validate(value: WorkEvent) Error!void {
        if (value.envelope_version != schema_version) return error.UnsupportedEnvelopeVersion;
        _ = identity.EventId.fromStorage(&value.event_id.bytes) catch return error.InvalidId;
        _ = identity.ProviderInstanceId.fromStorage(&value.source_provider_id.bytes) catch return error.InvalidId;
        try validateStreamId(value.stream_id);
        try validateOptionalIds(value.ids);
        if (value.stream_incarnation == 0 or value.stream_incarnation > std.math.maxInt(i64))
            return error.InvalidStreamIncarnation;
        if (value.stream_seq == 0 or value.stream_seq > std.math.maxInt(i64))
            return error.InvalidStreamSequence;
        if (value.payload.len > max_payload_bytes) return error.EnvelopeTooLarge;
        if (value.payload_kind == @intFromEnum(PayloadKind.terminal_output) and value.payload.len > terminal_output_max_bytes)
            return error.TerminalOutputTooLarge;
        if (value.payload_version == 0 or value.normalization_version == 0) return error.InvalidVersion;
        if (value.payload_version == 1 and value.payload_kind == @intFromEnum(PayloadKind.evidence_gap))
            _ = try EvidenceGap.decode(value.payload);
        if (value.payload_version == 1 and value.payload_kind == @intFromEnum(PayloadKind.source_transition))
            _ = try SourceTransition.decode(value.payload);
    }

    pub fn projectable(value: WorkEvent) bool {
        if (value.payload_version != 1) return false;
        const kind = std.enums.fromInt(PayloadKind, value.payload_kind) orelse return false;
        return kind == .evidence_gap or kind == .source_transition;
    }

    pub fn isEvidenceGap(value: WorkEvent) bool {
        return value.payload_kind == @intFromEnum(PayloadKind.evidence_gap) and value.payload_version == 1;
    }
};

pub const EvidenceGap = struct {
    first_missing: u64,
    last_missing: u64,

    pub fn encode(value: EvidenceGap) Error![16]u8 {
        if (value.first_missing == 0 or value.first_missing > value.last_missing) return error.InvalidEvidenceGapPayload;
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], value.first_missing, .little);
        std.mem.writeInt(u64, bytes[8..16], value.last_missing, .little);
        return bytes;
    }

    pub fn decode(bytes: []const u8) Error!EvidenceGap {
        if (bytes.len != 16) return error.InvalidEvidenceGapPayload;
        const value: EvidenceGap = .{
            .first_missing = std.mem.readInt(u64, bytes[0..8], .little),
            .last_missing = std.mem.readInt(u64, bytes[8..16], .little),
        };
        if (value.first_missing == 0 or value.first_missing > value.last_missing) return error.InvalidEvidenceGapPayload;
        return value;
    }
};

pub const SourceTransition = struct {
    previous_source_provider_id: [16]u8,

    pub fn encode(value: SourceTransition) Error![16]u8 {
        _ = identity.ProviderInstanceId.fromStorage(&value.previous_source_provider_id) catch
            return error.InvalidSourceTransitionPayload;
        return value.previous_source_provider_id;
    }

    pub fn decode(bytes: []const u8) Error!SourceTransition {
        if (bytes.len != 16) return error.InvalidSourceTransitionPayload;
        const previous = identity.ProviderInstanceId.fromStorage(bytes) catch return error.InvalidSourceTransitionPayload;
        return .{ .previous_source_provider_id = previous.bytes };
    }
};

pub const StoredEvent = struct {
    store_seq: u64,
    event: WorkEvent,
    checksum: [checksum_size]u8,

    pub fn deinit(value: *StoredEvent, allocator: std.mem.Allocator) void {
        allocator.free(value.event.payload);
        value.* = undefined;
    }
};

pub const Error = error{
    EnvelopeTooLarge,
    Truncated,
    TrailingData,
    BadMagic,
    UnsupportedEnvelopeVersion,
    InvalidEnum,
    InvalidId,
    InvalidStreamIncarnation,
    InvalidStreamSequence,
    InvalidVersion,
    TerminalOutputTooLarge,
    InvalidEvidenceGapPayload,
    InvalidSourceTransitionPayload,
    ChecksumMismatch,
} || std.mem.Allocator.Error;

const magic = "PWE1";
const optional_count = 7;
// magic + scalar fields + seven presence-tagged IDs + payload length + checksum
const fixed_size = 4 + 2 + 16 + 16 + 1 + 16 + 8 + 8 + 8 + 8 +
    optional_count * 17 + 2 + 2 + 1 + 1 + 2 + 4 + checksum_size;

pub fn encode(allocator: std.mem.Allocator, value: WorkEvent) Error![]u8 {
    try value.validate();
    const total = fixed_size + value.payload.len;
    if (total > max_envelope_bytes) return error.EnvelopeTooLarge;
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    var cursor: usize = 0;
    putBytes(out, &cursor, magic);
    putInt(u16, out, &cursor, value.envelope_version);
    putBytes(out, &cursor, &value.event_id.bytes);
    putBytes(out, &cursor, &value.source_provider_id.bytes);
    putInt(u8, out, &cursor, @intFromEnum(value.stream_kind));
    putBytes(out, &cursor, &value.stream_id);
    putInt(u64, out, &cursor, value.stream_incarnation);
    putInt(u64, out, &cursor, value.stream_seq);
    putInt(i64, out, &cursor, value.occurred_at_ns);
    putInt(i64, out, &cursor, value.ingested_at_ns);
    putOptional(out, &cursor, value.ids.causation_event_id, identity.EventId);
    putOptionalBytes(out, &cursor, value.ids.correlation_id);
    putOptional(out, &cursor, value.ids.objective_id, identity.ObjectiveId);
    putOptional(out, &cursor, value.ids.run_id, identity.RunId);
    putOptional(out, &cursor, value.ids.session_id, identity.SessionId);
    putOptional(out, &cursor, value.ids.artifact_id, identity.ArtifactId);
    putOptional(out, &cursor, value.ids.signal_id, identity.SignalId);
    putInt(u16, out, &cursor, value.payload_kind);
    putInt(u16, out, &cursor, value.payload_version);
    putInt(u8, out, &cursor, @intFromEnum(value.trust));
    putInt(u8, out, &cursor, @intFromEnum(value.provenance));
    putInt(u16, out, &cursor, value.normalization_version);
    putInt(u32, out, &cursor, @intCast(value.payload.len));
    putBytes(out, &cursor, value.payload);
    const digest = checksum(out[0..cursor]);
    putBytes(out, &cursor, &digest);
    std.debug.assert(cursor == total);
    return out;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!WorkEvent {
    if (bytes.len < fixed_size) return error.Truncated;
    if (bytes.len > max_envelope_bytes) return error.EnvelopeTooLarge;
    var cursor: usize = 0;
    if (!std.mem.eql(u8, take(bytes, &cursor, 4) catch return error.Truncated, magic)) return error.BadMagic;
    const version = getInt(u16, bytes, &cursor) catch return error.Truncated;
    if (version != schema_version) return error.UnsupportedEnvelopeVersion;
    const event_id = identity.EventId.fromStorage(take(bytes, &cursor, 16) catch return error.Truncated) catch return error.InvalidId;
    const provider_id = identity.ProviderInstanceId.fromStorage(take(bytes, &cursor, 16) catch return error.Truncated) catch return error.InvalidId;
    const stream_kind = std.enums.fromInt(StreamKind, getInt(u8, bytes, &cursor) catch return error.Truncated) orelse return error.InvalidEnum;
    var stream_id: [16]u8 = undefined;
    @memcpy(&stream_id, take(bytes, &cursor, 16) catch return error.Truncated);
    try validateStreamId(stream_id);
    const incarnation = getInt(u64, bytes, &cursor) catch return error.Truncated;
    const sequence = getInt(u64, bytes, &cursor) catch return error.Truncated;
    if (incarnation == 0 or incarnation > std.math.maxInt(i64)) return error.InvalidStreamIncarnation;
    if (sequence == 0 or sequence > std.math.maxInt(i64)) return error.InvalidStreamSequence;
    const occurred = getInt(i64, bytes, &cursor) catch return error.Truncated;
    const ingested = getInt(i64, bytes, &cursor) catch return error.Truncated;
    const ids: OptionalIds = .{
        .causation_event_id = try getOptional(identity.EventId, bytes, &cursor),
        .correlation_id = try getOptionalBytes(bytes, &cursor),
        .objective_id = try getOptional(identity.ObjectiveId, bytes, &cursor),
        .run_id = try getOptional(identity.RunId, bytes, &cursor),
        .session_id = try getOptional(identity.SessionId, bytes, &cursor),
        .artifact_id = try getOptional(identity.ArtifactId, bytes, &cursor),
        .signal_id = try getOptional(identity.SignalId, bytes, &cursor),
    };
    const payload_kind = getInt(u16, bytes, &cursor) catch return error.Truncated;
    const payload_version = getInt(u16, bytes, &cursor) catch return error.Truncated;
    const trust = std.enums.fromInt(Trust, getInt(u8, bytes, &cursor) catch return error.Truncated) orelse return error.InvalidEnum;
    const provenance = std.enums.fromInt(Provenance, getInt(u8, bytes, &cursor) catch return error.Truncated) orelse return error.InvalidEnum;
    const normalization = getInt(u16, bytes, &cursor) catch return error.Truncated;
    const payload_len: usize = getInt(u32, bytes, &cursor) catch return error.Truncated;
    if (payload_len > max_payload_bytes) return error.EnvelopeTooLarge;
    if (payload_len > bytes.len - cursor) return error.Truncated;
    if (bytes.len - cursor != payload_len + checksum_size) return error.TrailingData;
    const payload_source = take(bytes, &cursor, payload_len) catch return error.Truncated;
    const expected = checksum(bytes[0..cursor]);
    const actual = take(bytes, &cursor, checksum_size) catch return error.Truncated;
    if (!std.mem.eql(u8, &expected, actual)) return error.ChecksumMismatch;
    const payload = try allocator.dupe(u8, payload_source);
    var value: WorkEvent = .{
        .envelope_version = version,
        .event_id = event_id,
        .source_provider_id = provider_id,
        .stream_kind = stream_kind,
        .stream_id = stream_id,
        .stream_incarnation = incarnation,
        .stream_seq = sequence,
        .occurred_at_ns = occurred,
        .ingested_at_ns = ingested,
        .ids = ids,
        .payload_kind = payload_kind,
        .payload_version = payload_version,
        .payload = payload,
        .trust = trust,
        .provenance = provenance,
        .normalization_version = normalization,
    };
    value.validate() catch |err| {
        allocator.free(payload);
        return err;
    };
    return value;
}

pub fn checksum(bytes: []const u8) [checksum_size]u8 {
    var digest: [checksum_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub fn canonicalChecksum(allocator: std.mem.Allocator, value: WorkEvent) Error![checksum_size]u8 {
    const bytes = try encode(allocator, value);
    defer allocator.free(bytes);
    return checksum(bytes[0 .. bytes.len - checksum_size]);
}

fn validateStreamId(bytes: [16]u8) Error!void {
    // Stream IDs are one of the stable UUIDv7 identities; all share this codec.
    _ = identity.EventId.fromStorage(&bytes) catch return error.InvalidId;
}

fn validateOptionalIds(ids: OptionalIds) Error!void {
    if (ids.causation_event_id) |id| _ = identity.EventId.fromStorage(&id.bytes) catch return error.InvalidId;
    if (ids.objective_id) |id| _ = identity.ObjectiveId.fromStorage(&id.bytes) catch return error.InvalidId;
    if (ids.run_id) |id| _ = identity.RunId.fromStorage(&id.bytes) catch return error.InvalidId;
    if (ids.session_id) |id| _ = identity.SessionId.fromStorage(&id.bytes) catch return error.InvalidId;
    if (ids.artifact_id) |id| _ = identity.ArtifactId.fromStorage(&id.bytes) catch return error.InvalidId;
    if (ids.signal_id) |id| _ = identity.SignalId.fromStorage(&id.bytes) catch return error.InvalidId;
    if (ids.correlation_id) |id| try validateStreamId(id);
}

fn putBytes(out: []u8, cursor: *usize, value: []const u8) void {
    @memcpy(out[cursor.*..][0..value.len], value);
    cursor.* += value.len;
}

fn putInt(comptime T: type, out: []u8, cursor: *usize, value: T) void {
    std.mem.writeInt(T, out[cursor.*..][0..@sizeOf(T)], value, .little);
    cursor.* += @sizeOf(T);
}

fn putOptional(out: []u8, cursor: *usize, value: anytype, comptime Id: type) void {
    if (value) |id| {
        putInt(u8, out, cursor, 1);
        putBytes(out, cursor, &id.bytes);
    } else {
        putInt(u8, out, cursor, 0);
        putBytes(out, cursor, &([_]u8{0} ** Id.storage_length));
    }
}

fn putOptionalBytes(out: []u8, cursor: *usize, value: ?[16]u8) void {
    if (value) |id| {
        putInt(u8, out, cursor, 1);
        putBytes(out, cursor, &id);
    } else {
        putInt(u8, out, cursor, 0);
        putBytes(out, cursor, &([_]u8{0} ** 16));
    }
}

fn take(bytes: []const u8, cursor: *usize, length: usize) error{Truncated}![]const u8 {
    if (length > bytes.len - cursor.*) return error.Truncated;
    defer cursor.* += length;
    return bytes[cursor.*..][0..length];
}

fn getInt(comptime T: type, bytes: []const u8, cursor: *usize) error{Truncated}!T {
    const raw = try take(bytes, cursor, @sizeOf(T));
    return std.mem.readInt(T, @ptrCast(raw.ptr), .little);
}

fn getOptional(comptime Id: type, bytes: []const u8, cursor: *usize) Error!?Id {
    const present = getInt(u8, bytes, cursor) catch return error.Truncated;
    const raw = take(bytes, cursor, 16) catch return error.Truncated;
    return switch (present) {
        0 => if (std.mem.allEqual(u8, raw, 0)) null else error.InvalidId,
        1 => Id.fromStorage(raw) catch error.InvalidId,
        else => error.InvalidId,
    };
}

fn getOptionalBytes(bytes: []const u8, cursor: *usize) Error!?[16]u8 {
    const present = getInt(u8, bytes, cursor) catch return error.Truncated;
    const raw = take(bytes, cursor, 16) catch return error.Truncated;
    if (present == 0) return if (std.mem.allEqual(u8, raw, 0)) null else error.InvalidId;
    if (present != 1) return error.InvalidId;
    var id: [16]u8 = undefined;
    @memcpy(&id, raw);
    try validateStreamId(id);
    return id;
}
