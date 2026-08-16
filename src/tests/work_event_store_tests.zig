const std = @import("std");
const event = @import("../work/event.zig");
const identity = @import("../work/identity.zig");
const store_mod = @import("../work/store.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const testing = std.testing;

fn id(comptime Id: type, suffix: u16) Id {
    var bytes = [_]u8{0} ** 16;
    bytes[6] = 0x70;
    bytes[8] = 0x80;
    std.mem.writeInt(u16, bytes[14..16], suffix, .big);
    return Id.fromBytes(bytes) catch unreachable;
}

fn fact(event_suffix: u16, sequence: u64, payload: []const u8) event.WorkEvent {
    return .{
        .event_id = id(identity.EventId, event_suffix),
        .source_provider_id = id(identity.ProviderInstanceId, 90),
        .stream_kind = .session,
        .stream_id = id(identity.SessionId, 42).bytes,
        .stream_incarnation = 7,
        .stream_seq = sequence,
        .occurred_at_ns = 100,
        .ingested_at_ns = 110,
        .ids = .{ .session_id = id(identity.SessionId, 42) },
        .payload_kind = @intFromEnum(event.PayloadKind.terminal_metadata),
        .payload = payload,
        .trust = .local,
        .provenance = .local_authority,
        .normalization_version = 1,
    };
}

fn transitionFact(event_suffix: u16, incarnation: u64, source: identity.ProviderInstanceId, previous: *const [16]u8) event.WorkEvent {
    var value = fact(event_suffix, 1, previous);
    value.source_provider_id = source;
    value.stream_incarnation = incarnation;
    value.payload_kind = @intFromEnum(event.PayloadKind.source_transition);
    return value;
}

fn tempPath(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(testing.io, buffer);
    const path_z = try testing.allocator.dupeZ(u8, buffer[0..length]);
    defer testing.allocator.free(path_z);
    if (c.chmod(path_z.ptr, 0o700) != 0) return error.TestChmod;
    return buffer[0..length];
}

fn childPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ parent, name }, 0);
}

fn sqliteExec(path: [*:0]const u8, sql: [*:0]const u8) !void {
    var db_opt: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path, &db_opt, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK)
        return error.TestSqliteOpen;
    const db = db_opt.?;
    defer _ = c.sqlite3_close(db);
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) return error.TestSqliteExec;
}

fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = c.open(path, c.O_RDONLY);
    if (fd < 0) return error.TestOpen;
    defer _ = c.close(fd);
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0 or status.st_size < 0) return error.TestStat;
    const bytes = try allocator.alloc(u8, @intCast(status.st_size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (count <= 0) return error.TestRead;
        offset += @intCast(count);
    }
    return bytes;
}

fn expectEmpty(store: *store_mod.Store) !void {
    var page = try store.replayPage(testing.allocator, 0, .{});
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), page.events.len);
}

test "event codec is canonical bounded opaque for unknown versions and validates signed domains" {
    const original = fact(1, 1, "opaque provider bytes");
    const encoded = try event.encode(testing.allocator, original);
    defer testing.allocator.free(encoded);
    const decoded = try event.decode(testing.allocator, encoded);
    defer testing.allocator.free(decoded.payload);
    try testing.expectEqualDeep(original.event_id, decoded.event_id);
    try testing.expectEqualStrings(original.payload, decoded.payload);

    var unknown = original;
    unknown.payload_kind = 65000;
    unknown.payload_version = 77;
    const unknown_bytes = try event.encode(testing.allocator, unknown);
    defer testing.allocator.free(unknown_bytes);
    var retained = try event.decode(testing.allocator, unknown_bytes);
    defer testing.allocator.free(retained.payload);
    try testing.expect(!retained.projectable());
    try testing.expectEqualStrings(unknown.payload, retained.payload);
    try testing.expect(!original.projectable());

    var malformed_gap = original;
    malformed_gap.payload_kind = @intFromEnum(event.PayloadKind.evidence_gap);
    try testing.expectError(error.InvalidEvidenceGapPayload, malformed_gap.validate());

    try testing.expectError(error.Truncated, event.decode(testing.allocator, encoded[0..20]));
    var corrupt = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try testing.expectError(error.ChecksumMismatch, event.decode(testing.allocator, corrupt));
    var future = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(future);
    future[4] = 2;
    try testing.expectError(error.UnsupportedEnvelopeVersion, event.decode(testing.allocator, future));
    const oversized = try testing.allocator.alloc(u8, event.max_payload_bytes + 1);
    defer testing.allocator.free(oversized);
    var oversized_event = original;
    oversized_event.payload = oversized;
    try testing.expectError(error.EnvelopeTooLarge, oversized_event.validate());

    var invalid = original;
    invalid.stream_incarnation = 0;
    try testing.expectError(error.InvalidStreamIncarnation, invalid.validate());
    invalid.stream_incarnation = @as(u64, std.math.maxInt(i64)) + 1;
    try testing.expectError(error.InvalidStreamIncarnation, invalid.validate());
    invalid = original;
    invalid.stream_seq = @as(u64, std.math.maxInt(i64)) + 1;
    try testing.expectError(error.InvalidStreamSequence, invalid.validate());
}

test "artifact revision payload is strict canonical and commits digest context" {
    const artifact = id(identity.ArtifactId, 7);
    const payload = event.ArtifactRevisionPayload{
        .artifact_id = artifact.bytes,
        .revision_ordinal = 1,
        .digest = [_]u8{0xa5} ** 32,
        .byte_length = 42,
        .media_kind = .artifact,
        .redaction = .contains_secrets,
        .producer_session_id = null,
        .media_type = "application/octet-stream",
    };
    const encoded = try payload.encode(testing.allocator);
    defer testing.allocator.free(encoded);
    const decoded = try event.ArtifactRevisionPayload.decode(encoded);
    try testing.expectEqualDeep(payload.digest, decoded.digest);
    try testing.expectEqualStrings(payload.media_type, decoded.media_type);
    var malformed = try testing.allocator.dupe(u8, encoded);
    defer testing.allocator.free(malformed);
    malformed[24] = 99;
    try testing.expectError(error.InvalidArtifactRevisionPayload, event.ArtifactRevisionPayload.decode(malformed));
}

test "append is ordered idempotent paged and integrity replay stays bounded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    defer store.close();

    store.setFailpoint(.after_insert);
    try testing.expectError(error.InjectedFailure, store.append(0, fact(1, 1, "one")));
    try expectEmpty(&store);

    const first = try store.append(0, fact(1, 1, "one"));
    try testing.expectEqual(@as(u64, 1), first.appended);
    const duplicate = try store.append(0, fact(1, 1, "one"));
    try testing.expectEqual(first.appended, duplicate.duplicate);
    try testing.expectError(error.DuplicateConflict, store.append(1, fact(1, 1, "changed")));
    try testing.expectError(error.SequenceGap, store.append(1, fact(3, 3, "three")));
    try testing.expectError(error.ConcurrentAppend, store.append(0, fact(2, 2, "two")));
    try testing.expectError(error.ReorderedEvent, store.append(1, fact(4, 1, "reordered")));
    var reset = fact(5, 2, "wrong authority");
    reset.source_provider_id = id(identity.ProviderInstanceId, 91);
    try testing.expectError(error.SourceReset, store.append(1, reset));

    var sequence: u64 = 2;
    while (sequence <= 41) : (sequence += 1) {
        _ = try store.append(sequence - 1, fact(@intCast(sequence), sequence, "bounded row"));
    }
    var cursor: u64 = 0;
    var total: usize = 0;
    while (true) {
        var page = try store.replayPage(testing.allocator, cursor, .{ .max_events = 7, .max_bytes = event.max_envelope_bytes });
        defer page.deinit(testing.allocator);
        try testing.expect(page.events.len <= 7);
        total += page.events.len;
        cursor = page.next_store_sequence;
        if (!page.has_more) break;
    }
    try testing.expectEqual(@as(usize, 41), total);
    try store.verifyIntegrity();
    try testing.expectError(error.InvalidPageBudget, store.replayPage(testing.allocator, 0, .{ .max_events = 1, .max_bytes = 1 }));
    try testing.expectError(error.InvalidStoreSequence, store.replayPage(testing.allocator, @as(u64, std.math.maxInt(i64)) + 1, .{}));
}

test "large-store startup integrity and byte-budget replay do not allocate the whole log" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    const payload = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(payload);
    @memset(payload, 0xa5);

    var writer = try store_mod.Store.open(testing.allocator, path);
    var sequence: u64 = 1;
    while (sequence <= 24) : (sequence += 1)
        _ = try writer.append(sequence - 1, fact(@intCast(sequence), sequence, payload));
    writer.close();

    const startup_backing = try testing.allocator.alloc(u8, 512 * 1024);
    defer testing.allocator.free(startup_backing);
    var startup_fba = std.heap.FixedBufferAllocator.init(startup_backing);
    var bounded = try store_mod.Store.open(startup_fba.allocator(), path);
    bounded.close();

    var reader = try store_mod.Store.open(testing.allocator, path);
    defer reader.close();
    const replay_backing = try testing.allocator.alloc(u8, 1100 * 1024);
    defer testing.allocator.free(replay_backing);
    var replay_fba = std.heap.FixedBufferAllocator.init(replay_backing);
    var page = try reader.replayPage(replay_fba.allocator(), 0, .{
        .max_events = 100,
        .max_bytes = event.max_envelope_bytes,
    });
    defer page.deinit(replay_fba.allocator());
    try testing.expectEqual(@as(usize, 3), page.events.len);
    try testing.expect(page.has_more);
}

test "source transitions are explicit monotonic race-fenced and cannot reuse incarnations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    defer store.close();
    _ = try store.append(0, fact(1, 1, "initial"));

    var bypass = fact(2, 1, "bypass");
    bypass.stream_incarnation = 8;
    try testing.expectError(error.SourceTransitionRequired, store.append(0, bypass));

    const old_source = id(identity.ProviderInstanceId, 90).bytes;
    const new_source = id(identity.ProviderInstanceId, 91);
    const changed = transitionFact(2, 8, new_source, &old_source);
    try testing.expectError(error.InvalidSourceTransition, store.append(1, changed));
    _ = try store.transitionSource(old_source, 7, changed);
    const retried = try store.transitionSource(old_source, 7, changed);
    try testing.expectEqual(@as(u64, 2), retried.duplicate);

    const reused = transitionFact(3, 7, id(identity.ProviderInstanceId, 92), &new_source.bytes);
    try testing.expectError(error.InvalidSourceTransition, store.transitionSource(new_source.bytes, 8, reused));
    const raced = transitionFact(4, 9, id(identity.ProviderInstanceId, 92), &old_source);
    try testing.expectError(error.ConcurrentAppend, store.transitionSource(old_source, 7, raced));

    var next = fact(5, 2, "new authority advances");
    next.source_provider_id = new_source;
    next.stream_incarnation = 8;
    _ = try store.append(1, next);
}

test "commit ambiguity reconciles by EventId and retry is exactly once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    defer store.close();

    const value = fact(1, 1, "durable unknown outcome");
    store.setFailpoint(.after_commit);
    try testing.expectError(error.CommitOutcomeUnknown, store.append(0, value));
    var found = (try store.lookup(testing.allocator, value.event_id)).?;
    defer found.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 1), found.store_seq);
    const retry = try store.append(0, value);
    try testing.expectEqual(@as(u64, 1), retry.duplicate);
}

test "all precommit failpoints are definite failures and roll back" {
    inline for (.{ store_mod.Failpoint.before_begin, .after_begin, .after_insert, .before_commit }) |point| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tempPath(&tmp, &path_buffer);
        var store = try store_mod.Store.open(testing.allocator, path);
        defer store.close();
        store.setFailpoint(point);
        try testing.expectError(error.InjectedFailure, store.append(0, fact(1, 1, "precommit")));
        try expectEmpty(&store);
    }
}

test "checkpoint exposes a distinct failure seam" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    defer store.close();
    _ = try store.append(0, fact(1, 1, "checkpoint"));
    store.setFailpoint(.before_checkpoint);
    try testing.expectError(error.CheckpointFailure, store.checkpoint());
    try store.checkpoint();
}

test "state directory lock and database path validation refuses unsafe existing targets without chmod" {
    var permissive_tmp = testing.tmpDir(.{});
    defer permissive_tmp.cleanup();
    var permissive_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const permissive_path = try tempPath(&permissive_tmp, &permissive_buffer);
    const permissive_z = try testing.allocator.dupeZ(u8, permissive_path);
    defer testing.allocator.free(permissive_z);
    try testing.expectEqual(@as(c_int, 0), c.chmod(permissive_z.ptr, 0o755));
    try testing.expectError(error.PermissionDenied, store_mod.Store.open(testing.allocator, permissive_path));
    var status: c.struct_stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.stat(permissive_z.ptr, &status));
    try testing.expectEqual(@as(c_uint, 0o755), status.st_mode & 0o777);

    var symlink_tmp = testing.tmpDir(.{});
    defer symlink_tmp.cleanup();
    var symlink_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const symlink_root = try tempPath(&symlink_tmp, &symlink_buffer);
    const target = try childPath(testing.allocator, symlink_root, "target");
    defer testing.allocator.free(target);
    const linked = try childPath(testing.allocator, symlink_root, "linked");
    defer testing.allocator.free(linked);
    try testing.expectEqual(@as(c_int, 0), c.mkdir(target.ptr, 0o700));
    try testing.expectEqual(@as(c_int, 0), c.symlink(target.ptr, linked.ptr));
    try testing.expectError(error.UnsafeStatePath, store_mod.Store.open(testing.allocator, linked));
    const target_child = try childPath(testing.allocator, target, "child");
    defer testing.allocator.free(target_child);
    const linked_child = try childPath(testing.allocator, linked, "child");
    defer testing.allocator.free(linked_child);
    try testing.expectEqual(@as(c_int, 0), c.mkdir(target_child.ptr, 0o700));
    try testing.expectError(error.UnsafeStatePath, store_mod.Store.open(testing.allocator, linked_child));

    var lock_tmp = testing.tmpDir(.{});
    defer lock_tmp.cleanup();
    var lock_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_root = try tempPath(&lock_tmp, &lock_buffer);
    const lock = try childPath(testing.allocator, lock_root, "work.lock");
    defer testing.allocator.free(lock);
    try testing.expectEqual(@as(c_int, 0), c.symlink("/dev/null", lock.ptr));
    try testing.expectError(error.UnsafeStatePath, store_mod.Store.open(testing.allocator, lock_root));

    var db_tmp = testing.tmpDir(.{});
    defer db_tmp.cleanup();
    var db_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_root = try tempPath(&db_tmp, &db_buffer);
    const db = try childPath(testing.allocator, db_root, "work.sqlite3");
    defer testing.allocator.free(db);
    try testing.expectEqual(@as(c_int, 0), c.mkdir(db.ptr, 0o700));
    try testing.expectError(error.UnsafeStatePath, store_mod.Store.open(testing.allocator, db_root));

    var mode_tmp = testing.tmpDir(.{});
    defer mode_tmp.cleanup();
    var mode_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const mode_root = try tempPath(&mode_tmp, &mode_buffer);
    var mode_store = try store_mod.Store.open(testing.allocator, mode_root);
    mode_store.close();
    const mode_db = try childPath(testing.allocator, mode_root, "work.sqlite3");
    defer testing.allocator.free(mode_db);
    try testing.expectEqual(@as(c_int, 0), c.chmod(mode_db.ptr, 0o644));
    try testing.expectError(error.PermissionDenied, store_mod.Store.open(testing.allocator, mode_root));
    try testing.expectEqual(@as(c_int, 0), c.stat(mode_db.ptr, &status));
    try testing.expectEqual(@as(c_uint, 0o644), status.st_mode & 0o777);

    var lock_mode_tmp = testing.tmpDir(.{});
    defer lock_mode_tmp.cleanup();
    var lock_mode_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_mode_root = try tempPath(&lock_mode_tmp, &lock_mode_buffer);
    const lock_mode = try childPath(testing.allocator, lock_mode_root, "work.lock");
    defer testing.allocator.free(lock_mode);
    const lock_fd = c.open(lock_mode.ptr, c.O_RDWR | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o644));
    try testing.expect(lock_fd >= 0);
    _ = c.close(lock_fd);
    try testing.expectError(error.PermissionDenied, store_mod.Store.open(testing.allocator, lock_mode_root));
    try testing.expectEqual(@as(c_int, 0), c.stat(lock_mode.ptr, &status));
    try testing.expectEqual(@as(c_uint, 0o644), status.st_mode & 0o777);
}

test "foreign and newer stores are refused before side effects or byte mutation" {
    var foreign_tmp = testing.tmpDir(.{});
    defer foreign_tmp.cleanup();
    var foreign_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const foreign_path = try tempPath(&foreign_tmp, &foreign_buffer);
    const foreign_db = try childPath(testing.allocator, foreign_path, "work.sqlite3");
    defer testing.allocator.free(foreign_db);
    try sqliteExec(foreign_db.ptr, "CREATE TABLE unrelated(value TEXT); PRAGMA user_version=0");
    try testing.expectEqual(@as(c_int, 0), c.chmod(foreign_db.ptr, 0o600));
    const before = try readFile(testing.allocator, foreign_db.ptr);
    defer testing.allocator.free(before);
    try testing.expectError(error.ForeignStore, store_mod.Store.open(testing.allocator, foreign_path));
    const after = try readFile(testing.allocator, foreign_db.ptr);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    const foreign_lock = try childPath(testing.allocator, foreign_path, "work.lock");
    defer testing.allocator.free(foreign_lock);
    try testing.expect(c.access(foreign_lock.ptr, c.F_OK) != 0);

    var newer_tmp = testing.tmpDir(.{});
    defer newer_tmp.cleanup();
    var newer_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const newer_path = try tempPath(&newer_tmp, &newer_buffer);
    var newer = try store_mod.Store.open(testing.allocator, newer_path);
    newer.close();
    const newer_db = try childPath(testing.allocator, newer_path, "work.sqlite3");
    defer testing.allocator.free(newer_db);
    const newer_lock = try childPath(testing.allocator, newer_path, "work.lock");
    defer testing.allocator.free(newer_lock);
    try testing.expectEqual(@as(c_int, 0), c.unlink(newer_lock.ptr));
    try sqliteExec(newer_db.ptr, "PRAGMA user_version=99");
    const newer_before = try readFile(testing.allocator, newer_db.ptr);
    defer testing.allocator.free(newer_before);
    try testing.expectError(error.NewerSchema, store_mod.Store.open(testing.allocator, newer_path));
    const newer_after = try readFile(testing.allocator, newer_db.ptr);
    defer testing.allocator.free(newer_after);
    try testing.expectEqualSlices(u8, newer_before, newer_after);
    try testing.expect(c.access(newer_lock.ptr, c.F_OK) != 0);
}

test "unsupported unshipped draft schemas are refused rather than assigned fabricated context" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var initialized = try store_mod.Store.open(testing.allocator, path);
    initialized.close();
    const database = try childPath(testing.allocator, path, "work.sqlite3");
    defer testing.allocator.free(database);
    try sqliteExec(database.ptr, "PRAGMA journal_mode=DELETE; PRAGMA user_version=2");
    try testing.expectError(error.UnsupportedDraftSchema, store_mod.Store.open(testing.allocator, path));
}

test "newer schema present only in WAL is refused without mutating files or creating lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var initialized = try store_mod.Store.open(testing.allocator, path);
    initialized.close();
    const database = try childPath(testing.allocator, path, "work.sqlite3");
    defer testing.allocator.free(database);
    const wal = try childPath(testing.allocator, path, "work.sqlite3-wal");
    defer testing.allocator.free(wal);
    const lock = try childPath(testing.allocator, path, "work.lock");
    defer testing.allocator.free(lock);
    try testing.expectEqual(@as(c_int, 0), c.unlink(lock.ptr));

    var db_opt: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(database.ptr, &db_opt, c.SQLITE_OPEN_READWRITE, null));
    const db = db_opt.?;
    defer _ = c.sqlite3_close(db);
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, "PRAGMA wal_autocheckpoint=0; PRAGMA user_version=99", null, null, null));

    const database_before = try readFile(testing.allocator, database.ptr);
    defer testing.allocator.free(database_before);
    const wal_before = try readFile(testing.allocator, wal.ptr);
    defer testing.allocator.free(wal_before);
    try testing.expectError(error.NewerSchema, store_mod.Store.open(testing.allocator, path));
    const database_after = try readFile(testing.allocator, database.ptr);
    defer testing.allocator.free(database_after);
    const wal_after = try readFile(testing.allocator, wal.ptr);
    defer testing.allocator.free(wal_after);
    try testing.expectEqualSlices(u8, database_before, database_after);
    try testing.expectEqualSlices(u8, wal_before, wal_after);
    try testing.expect(c.access(lock.ptr, c.F_OK) != 0);
}

test "indexed column row checksum type confusion and oversized encoded rows fail integrity" {
    inline for (.{
        "PRAGMA ignore_check_constraints=ON; UPDATE events SET stream_seq=2 WHERE store_seq=1",
        "PRAGMA ignore_check_constraints=ON; UPDATE events SET encoded=1 WHERE store_seq=1",
        "PRAGMA ignore_check_constraints=ON; UPDATE events SET encoded=zeroblob(1048577) WHERE store_seq=1",
    }) |corruption| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tempPath(&tmp, &path_buffer);
        var store = try store_mod.Store.open(testing.allocator, path);
        _ = try store.append(0, fact(1, 1, "intact"));
        store.close();
        const database = try childPath(testing.allocator, path, "work.sqlite3");
        defer testing.allocator.free(database);
        try sqliteExec(database.ptr, corruption);
        try testing.expectError(error.IntegrityFailure, store_mod.Store.open(testing.allocator, path));
    }
}

test "store refuses concurrent writers and preserves explicit evidence gaps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &path_buffer);
    var first = try store_mod.Store.open(testing.allocator, path);
    defer first.close();
    try testing.expectError(error.ConcurrentWriter, store_mod.Store.open(testing.allocator, path));

    var gap = fact(1, 1, "source bytes 100..199 unavailable");
    const gap_payload = try (event.EvidenceGap{ .first_missing = 100, .last_missing = 199 }).encode();
    gap.payload_kind = @intFromEnum(event.PayloadKind.evidence_gap);
    gap.payload = &gap_payload;
    _ = try first.append(0, gap);
    var page = try first.replayPage(testing.allocator, 0, .{});
    defer page.deinit(testing.allocator);
    try testing.expect(page.events[0].event.isEvidenceGap());
}

test "invalid state paths fail explicitly" {
    try testing.expectError(error.InvalidStatePath, store_mod.Store.open(testing.allocator, "relative/store"));
    try testing.expectError(error.InvalidStatePath, store_mod.Store.open(testing.allocator, "/dev/null/phux-work"));
}
