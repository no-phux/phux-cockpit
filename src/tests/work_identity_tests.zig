const std = @import("std");
const work = @import("../work/identity.zig");

const testing = std.testing;

const expected_bytes = [16]u8{
    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0x76, 0x07,
    0x88, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
};
const expected_text = "01234567-89ab-7607-8809-0a0b0c0d0e0f";

test "work ID types are nominally separate 128-bit values" {
    try testing.expect(work.ObjectiveId != work.RunId);
    try testing.expect(work.RunId != work.SessionId);
    try testing.expect(work.SessionId != work.ArtifactId);
    try testing.expect(work.ArtifactId != work.AttachmentId);
    try testing.expect(work.AttachmentId != work.SignalId);
    try testing.expect(work.SignalId != work.EventId);
    try testing.expect(work.EventId != work.ProviderInstanceId);
    try testing.expect(work.ProviderInstanceId != work.SessionBindingId);
    try testing.expect(work.PhuxTerminalKind != work.PhuxTerminalId);
    try testing.expectEqual(@as(usize, 16), @sizeOf(work.ObjectiveId));
}

test "canonical text and exact storage codecs round trip expected UUIDv7 bytes" {
    const session_id = try work.SessionId.fromStorage(&expected_bytes);
    const storage = session_id.toStorage();
    try testing.expectEqualSlices(u8, &expected_bytes, &storage);

    var text: [work.SessionId.text_length]u8 = undefined;
    try testing.expectEqualStrings(expected_text, session_id.writeText(&text));
    const parsed = try work.SessionId.parse(expected_text);
    try testing.expect(session_id.eql(parsed));
    try testing.expectEqual(session_id.hash(), parsed.hash());

    var map = std.HashMap(work.SessionId, u8, work.SessionId.Context, std.hash_map.default_max_load_percentage).init(testing.allocator);
    defer map.deinit();
    try map.put(session_id, 7);
    try testing.expectEqual(@as(?u8, 7), map.get(parsed));
}

test "ID codecs reject malformed length case hex version and variant" {
    try testing.expectError(error.InvalidLength, work.SessionId.fromStorage(expected_bytes[0..15]));
    try testing.expectError(error.InvalidLength, work.SessionId.parse(expected_text[0..35]));
    try testing.expectError(error.InvalidText, work.SessionId.parse("01234567-89AB-7607-8809-0a0b0c0d0e0f"));
    try testing.expectError(error.InvalidText, work.SessionId.parse("01234567_89ab-7607-8809-0a0b0c0d0e0f"));
    try testing.expectError(error.InvalidText, work.SessionId.parse("g1234567-89ab-7607-8809-0a0b0c0d0e0f"));
    try testing.expectError(error.InvalidVersion, work.SessionId.parse("01234567-89ab-6607-8809-0a0b0c0d0e0f"));
    try testing.expectError(error.InvalidVariant, work.SessionId.parse("01234567-89ab-7607-4809-0a0b0c0d0e0f"));
}

const DeterministicSource = struct {
    timestamp: u64,
    entropy: [16]u8,
    entropy_error: bool = false,

    fn now(context: *anyopaque) u64 {
        const source: *DeterministicSource = @ptrCast(@alignCast(context));
        return source.timestamp;
    }

    fn fill(context: *anyopaque, output: []u8) !void {
        const source: *DeterministicSource = @ptrCast(@alignCast(context));
        if (source.entropy_error) return error.EntropyUnavailable;
        @memcpy(output, &source.entropy);
    }
};

fn issuerFor(source: *DeterministicSource) work.Issuer {
    return .{
        .context = source,
        .nowMilliseconds = DeterministicSource.now,
        .fillEntropy = DeterministicSource.fill,
    };
}

fn idTimestamp(id: anytype) u64 {
    const bytes = id.toStorage();
    var timestamp: u64 = 0;
    for (bytes[0..6]) |byte| timestamp = (timestamp << 8) | byte;
    return timestamp;
}

test "UUIDv7 issuance is deterministic and enforces timestamp boundary" {
    var source: DeterministicSource = .{
        .timestamp = 0x0123_4567_89ab,
        .entropy = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    };
    var issuer = issuerFor(&source);
    const event_id = try issuer.issue(work.EventId);
    try testing.expectEqualSlices(u8, &expected_bytes, &event_id.toStorage());

    source.timestamp = 0xffff_ffff_ffff;
    try testing.expectEqual(source.timestamp, idTimestamp(try issuer.issue(work.EventId)));
    source.timestamp += 1;
    try testing.expectError(error.TimestampOutOfRange, issuer.issue(work.EventId));
}

test "same millisecond and rollback increment the monotonic random field" {
    var source: DeterministicSource = .{ .timestamp = 100, .entropy = [_]u8{0} ** 16 };
    var issuer = issuerFor(&source);
    const first = try issuer.issue(work.EventId);
    const second = try issuer.issue(work.EventId);
    source.timestamp = 90;
    const rollback = try issuer.issue(work.EventId);

    try testing.expectEqual(@as(u64, 100), idTimestamp(first));
    try testing.expectEqual(@as(u64, 100), idTimestamp(second));
    try testing.expectEqual(@as(u64, 100), idTimestamp(rollback));
    try testing.expect(!first.eql(second));
    try testing.expect(!second.eql(rollback));
}

test "entropy errors propagate without consuming issuer state" {
    var source: DeterministicSource = .{ .timestamp = 1, .entropy = [_]u8{0} ** 16, .entropy_error = true };
    var issuer = issuerFor(&source);
    try testing.expectError(error.EntropyUnavailable, issuer.issue(work.EventId));
    source.entropy_error = false;
    _ = try issuer.issue(work.EventId);
}

test "monotonic random field exhaustion is explicit" {
    var source: DeterministicSource = .{ .timestamp = 1, .entropy = [_]u8{0xff} ** 16 };
    var issuer = issuerFor(&source);
    _ = try issuer.issue(work.EventId);
    try testing.expectError(error.RandomExhausted, issuer.issue(work.EventId));
}

const ConcurrentWorker = struct {
    fn run(issuer: *work.Issuer, output: []work.EventId) void {
        for (output) |*id| id.* = issuer.issue(work.EventId) catch unreachable;
    }
};

test "concurrent issuance from one issuer has no duplicates" {
    const thread_count = 4;
    const ids_per_thread = 64;
    var source: DeterministicSource = .{ .timestamp = 500, .entropy = [_]u8{0} ** 16 };
    var issuer = issuerFor(&source);
    var ids: [thread_count * ids_per_thread]work.EventId = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        const start = index * ids_per_thread;
        thread.* = try std.Thread.spawn(.{}, ConcurrentWorker.run, .{ &issuer, ids[start .. start + ids_per_thread] });
    }
    for (threads) |thread| thread.join();

    var seen = std.HashMap(work.EventId, void, work.EventId.Context, std.hash_map.default_max_load_percentage).init(testing.allocator);
    defer seen.deinit();
    for (ids) |id| {
        const result = try seen.getOrPut(id);
        try testing.expect(!result.found_existing);
    }
}

fn stableId(comptime Id: type, tail: u8) Id {
    var bytes = expected_bytes;
    bytes[15] = tail;
    return Id.fromBytes(bytes) catch unreachable;
}

fn phuxResource(instance_tail: u8, host: []const u8, source_id: u32) !work.ProviderResourceRef {
    return .{
        .provider_instance_id = stableId(work.ProviderInstanceId, instance_tail),
        .locator = .{ .phux = try work.PhuxResourceLocator.init(work.PhuxTerminalKind.init(3), work.PhuxTerminalId.init(source_id), host) },
    };
}

test "provider instance qualifies reused source IDs and host rename is not authority" {
    const first = try phuxResource(1, "old-host", 42);
    const renamed = try phuxResource(1, "new-host", 42);
    const another_coordinator = try phuxResource(2, "old-host", 42);

    try testing.expect(first.sameAuthority(renamed));
    try testing.expect(!first.eql(renamed));
    try testing.expect(!first.sameAuthority(another_coordinator));
    try testing.expect(!first.eql(another_coordinator));

    var map = std.HashMap(work.ProviderResourceRef, u8, work.ProviderResourceRef.Context, std.hash_map.default_max_load_percentage).init(testing.allocator);
    defer map.deinit();
    try map.put(first, 1);
    try map.put(another_coordinator, 2);
    try testing.expectEqual(@as(?u8, 1), map.get(first));
    try testing.expectEqual(@as(?u8, 2), map.get(another_coordinator));
}

test "Phux host maximum is exact and wrappers retain all u32 values" {
    var maximum = [_]u8{'h'} ** work.PhuxResourceLocator.max_host_bytes;
    const locator = try work.PhuxResourceLocator.init(work.PhuxTerminalKind.init(std.math.maxInt(u32)), work.PhuxTerminalId.init(0), &maximum);
    try testing.expectEqualSlices(u8, &maximum, locator.host());
    try testing.expectEqual(std.math.maxInt(u32), locator.terminal_kind.value());
    try testing.expectError(error.HostTooLong, work.PhuxResourceLocator.init(work.PhuxTerminalKind.init(1), work.PhuxTerminalId.init(2), "h" ** 256));
}

test "records preserve lineage and retry creates a distinct Run" {
    const objective: work.ObjectiveRecord = .{ .id = stableId(work.ObjectiveId, 1), .state = .open, .revision = 4 };
    const first_run: work.RunRecord = .{ .id = stableId(work.RunId, 2), .objective_id = objective.id, .ordinal = 1, .lifecycle = .failed };
    const retry: work.RunRecord = .{ .id = stableId(work.RunId, 3), .objective_id = objective.id, .ordinal = 2, .lifecycle = .running };
    const session: work.SessionRecord = .{ .id = stableId(work.SessionId, 4), .run_id = retry.id, .kind = .terminal };
    const lineage = try work.SessionLineage.init(objective, retry, session);
    const artifact: work.ArtifactRecord = .{ .id = stableId(work.ArtifactId, 5), .run_id = retry.id, .producer_session_id = session.id };
    const signal: work.SignalRecord = .{ .id = stableId(work.SignalId, 6), .occurrence_event_id = stableId(work.EventId, 7), .source = .runner, .kind = .failure, .severity = .critical, .objective_id = objective.id, .run_id = first_run.id };

    try testing.expect(!first_run.id.eql(retry.id));
    try testing.expect(lineage.objective_id.eql(objective.id));
    try testing.expect(lineage.run_id.eql(retry.id));
    try testing.expect(artifact.producer_session_id.?.eql(session.id));
    try testing.expect(signal.run_id.?.eql(first_run.id));
    try testing.expect(signal.occurrence_event_id.eql(stableId(work.EventId, 7)));
    try testing.expect(!@hasField(work.SignalRecord, "attention_state"));

    var unrelated_session = session;
    unrelated_session.run_id = first_run.id;
    try testing.expectError(error.LineageMismatch, work.SessionLineage.init(objective, retry, unrelated_session));
}

test "moving and rebinding keep SessionId stable" {
    const session_id = stableId(work.SessionId, 10);
    const old_binding: work.SessionBinding = .{ .id = stableId(work.SessionBindingId, 11), .session_id = session_id, .resource = try phuxResource(12, "old-host", 13) };
    const new_binding: work.SessionBinding = .{ .id = stableId(work.SessionBindingId, 14), .session_id = session_id, .resource = try phuxResource(12, "new-host", 13) };

    try testing.expect(old_binding.session_id.eql(new_binding.session_id));
    try testing.expect(!old_binding.eql(new_binding));
    try testing.expect(!@hasDecl(work.SessionId, "fromPid"));
    try testing.expect(!@hasDecl(work.SessionId, "fromTopologyOffset"));
}

test "owner generation treats sequence as progress and checks every advance" {
    const generation: work.OwnerGeneration = .{ .authority_epoch = 1, .attachment_epoch = 2, .bootstrap_epoch = 3, .last_seq = 4 };
    const sequence = try generation.advanced(.sequence);
    try testing.expect(generation.sameOwner(sequence));
    try testing.expect(!generation.sameOwner(try generation.advanced(.authority)));
    try testing.expect(!generation.sameOwner(try generation.advanced(.attachment)));
    try testing.expect(!generation.sameOwner(try generation.advanced(.bootstrap)));

    const exhausted: work.OwnerGeneration = .{ .authority_epoch = std.math.maxInt(u64), .attachment_epoch = 0, .bootstrap_epoch = 0, .last_seq = 0 };
    try testing.expectError(error.GenerationExhausted, exhausted.advanced(.authority));
}

test "command target rejects stale session binding and owner but not sequence progress" {
    const current: work.CommandTarget = .{
        .session_id = stableId(work.SessionId, 1),
        .binding_id = stableId(work.SessionBindingId, 2),
        .generation = .{ .authority_epoch = 3, .attachment_epoch = 4, .bootstrap_epoch = 5, .last_seq = 10 },
    };
    var expected = current;
    expected.generation.last_seq = 1;
    try expected.validate(current);
    expected.session_id = stableId(work.SessionId, 8);
    try testing.expectError(error.StaleSession, expected.validate(current));
    expected = current;
    expected.binding_id = stableId(work.SessionBindingId, 9);
    try testing.expectError(error.StaleBinding, expected.validate(current));
    expected = current;
    expected.generation.attachment_epoch -= 1;
    try testing.expectError(error.StaleGeneration, expected.validate(current));
}

test "capability claims remain independent and honest" {
    const live_only: work.CapabilityDescriptor = .{};
    try testing.expectEqual(@as(u16, 1), live_only.schema_version);
    try testing.expect(!live_only.durable_execution);
    try testing.expect(!live_only.detach_survives_client);
    try testing.expect(!live_only.detach_survives_runner_restart);
    try testing.expect(!live_only.completed_replay);
    try testing.expect(!live_only.input_recording);
    try testing.expect(!live_only.output_recording);

    var replay_only: work.CapabilityDescriptor = .{};
    replay_only.completed_replay = true;
    try testing.expect(replay_only.completed_replay);
    try testing.expect(!replay_only.durable_execution);
    try testing.expect(!replay_only.detach_survives_client);
    try testing.expect(!replay_only.detach_survives_runner_restart);
}
