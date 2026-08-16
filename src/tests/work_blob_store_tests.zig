const std = @import("std");
const blob = @import("../work/blob.zig");
const event = @import("../work/event.zig");
const identity = @import("../work/identity.zig");
const store_mod = @import("../work/store.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sqlite3.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
const testing = std.testing;

fn discard(_: *anyopaque, _: []const u8) blob.Error!void {}

fn sqliteExec(path: [*:0]const u8, sql: [*:0]const u8) !void {
    var db_opt: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(path, &db_opt, c.SQLITE_OPEN_READWRITE, null));
    const db = db_opt.?;
    defer _ = c.sqlite3_close(db);
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, sql, null, null, null));
}

fn id(comptime Id: type, suffix: u16) Id {
    var bytes = [_]u8{0} ** 16;
    bytes[6] = 0x70;
    bytes[8] = 0x80;
    std.mem.writeInt(u16, bytes[14..16], suffix, .big);
    return Id.fromBytes(bytes) catch unreachable;
}

fn tempPath(tmp: *testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(testing.io, buffer);
    const z = try testing.allocator.dupeZ(u8, buffer[0..length]);
    defer testing.allocator.free(z);
    if (c.chmod(z.ptr, 0o700) != 0) return error.TestChmod;
    return buffer[0..length];
}

fn revisionFact(allocator: std.mem.Allocator, published: blob.PublishedBlob, event_suffix: u16, ordinal: u64, trust: event.Trust, media: []const u8) !struct { value: event.WorkEvent, payload: []u8 } {
    const artifact = id(identity.ArtifactId, 3);
    const payload = try (event.ArtifactRevisionPayload{
        .artifact_id = artifact.bytes,
        .revision_ordinal = ordinal,
        .digest = published.digest.bytes,
        .byte_length = published.length,
        .media_kind = .artifact,
        .redaction = .none,
        .producer_session_id = null,
        .media_type = media,
    }).encode(allocator);
    return .{ .value = .{
        .event_id = id(identity.EventId, event_suffix),
        .source_provider_id = id(identity.ProviderInstanceId, 2),
        .stream_kind = .artifact,
        .stream_id = artifact.bytes,
        .stream_incarnation = 1,
        .stream_seq = ordinal,
        .occurred_at_ns = 1,
        .ingested_at_ns = 2,
        .ids = .{ .run_id = id(identity.RunId, 4), .artifact_id = artifact },
        .payload_kind = @intFromEnum(event.PayloadKind.artifact_revision_committed),
        .payload = payload,
        .trust = trust,
        .provenance = if (trust == .local) .local_authority else .provider_event,
        .normalization_version = 1,
    }, .payload = payload };
}

test "blob digest uses strict lowercase BLAKE3 codec" {
    const digest = blob.BlobDigest.hash("abc");
    const encoded = digest.format();
    try testing.expectEqualStrings("6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85", &encoded);
    try testing.expect(digest.eql(try blob.BlobDigest.parse(&encoded)));
    try testing.expectError(error.InvalidDigest, blob.BlobDigest.parse("6437B3AC38465133FFB63B75273A8DB548C558465D79DB03FD359C6CD5BD9D85"));
}

const RepeatingSource = struct {
    remaining: usize,
    fn read(raw: *anyopaque, out: []u8) blob.Error!usize {
        const self: *RepeatingSource = @ptrCast(@alignCast(raw));
        const count = @min(self.remaining, out.len);
        @memset(out[0..count], 0xa5);
        self.remaining -= count;
        return count;
    }
};

test "streaming publication enforces injected policy at N plus one without whole allocation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var blobs = try blob.BlobStore.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer blobs.close();
    var source = RepeatingSource{ .remaining = 4097 };
    try testing.expectError(error.BlobTooLarge, blobs.putStream(.{ .context = &source, .read_fn = RepeatingSource.read }, .{ .max_bytes = 4096 }));
    var exact = RepeatingSource{ .remaining = 4096 };
    const published = try blobs.putStream(.{ .context = &exact, .read_fn = RepeatingSource.read }, .{ .max_bytes = 4096 });
    try testing.expectEqual(@as(u64, 4096), published.length);
    try testing.expectEqual(blob.VerifyResult.verified, try blobs.verify(published.digest, published.length));
}

test "publication unit failpoints expose old-or-new state at each durability seam" {
    inline for (.{ blob.Failpoint.temp_write, .temp_fsync, .publish, .directory_fsync }) |point| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var blobs = try blob.BlobStore.open(testing.allocator, try tempPath(&tmp, &buffer));
        defer blobs.close();
        const bytes = "barrier bytes";
        const digest = blob.BlobDigest.hash(bytes);
        blobs.setFailpoint(point);
        try testing.expectError(error.InjectedFailure, blobs.putBytes(bytes));
        const result = try blobs.verify(digest, bytes.len);
        if (point == .temp_write or point == .temp_fsync)
            try testing.expectEqual(blob.VerifyResult{ .gap = .missing }, result)
        else
            try testing.expectEqual(blob.VerifyResult.verified, result);
    }
}

test "verified streaming emits the private snapshot after addressable source replacement" {
    const Context = struct {
        target: [*:0]const u8,
        replacement: [*:0]const u8,
        replaced: bool = false,
        fn replace(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.replaced = c.rename(self.replacement, self.target) == 0;
        }
    };
    const Sink = struct {
        bytes: std.ArrayList(u8) = .empty,
        fn write(raw: *anyopaque, bytes: []const u8) blob.Error!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.bytes.appendSlice(testing.allocator, bytes);
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var blobs = try blob.BlobStore.open(testing.allocator, path);
    defer blobs.close();
    const original = "verified snapshot";
    const published = try blobs.putBytes(original);
    const hex = published.digest.format();
    const target = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/blobs/{s}/{s}", .{ path, hex[0..2], hex[2..] }, 0);
    defer testing.allocator.free(target);
    const replacement = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/replacement", .{path}, 0);
    defer testing.allocator.free(replacement);
    const replacement_fd = c.open(replacement.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL, @as(c_uint, 0o600));
    try testing.expect(replacement_fd >= 0);
    try testing.expectEqual(@as(isize, original.len), c.write(replacement_fd, "mutated snapshot", original.len));
    _ = c.close(replacement_fd);
    var context = Context{ .target = target.ptr, .replacement = replacement.ptr };
    blobs.setSnapshotHook(.{ .context = &context, .run_fn = Context.replace });
    var sink = Sink{};
    defer sink.bytes.deinit(testing.allocator);
    try testing.expectEqual(blob.VerifyResult.verified, try blobs.streamVerified(published.digest, published.length, .{ .context = &sink, .write_fn = Sink.write }));
    try testing.expect(context.replaced);
    try testing.expectEqualStrings(original, sink.bytes.items);
}

test "exclusive rename publication deduplicates and never leaves a hardlinked target" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var blobs = try blob.BlobStore.open(testing.allocator, path);
    defer blobs.close();
    const first = try blobs.putBytes("same bytes");
    const second = try blobs.putBytes("same bytes");
    try testing.expect(!first.deduplicated and second.deduplicated);
    const hex = first.digest.format();
    const target = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/blobs/{s}/{s}", .{ path, hex[0..2], hex[2..] }, 0);
    defer testing.allocator.free(target);
    var status: c.struct_stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.stat(target.ptr, &status));
    try testing.expectEqual(@as(c.nlink_t, 1), status.st_nlink);
}

test "dedupe unit failpoint occurs only after shard and blob-root sync seams" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var blobs = try blob.BlobStore.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer blobs.close();
    const first = try blobs.putBytes("dedupe sync");
    blobs.setFailpoint(.directory_fsync);
    try testing.expectError(error.InjectedFailure, blobs.putBytes("dedupe sync"));
    try testing.expectEqual(blob.VerifyResult.verified, try blobs.verify(first.digest, first.length));
}

test "concurrent same-digest publishers converge on one verified inode" {
    const Worker = struct {
        fn run(path: []const u8, result: *blob.PublishedBlob) void {
            var store = blob.BlobStore.open(std.heap.c_allocator, path) catch unreachable;
            defer store.close();
            result.* = store.putBytes("concurrent bytes") catch unreachable;
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var first: blob.PublishedBlob = undefined;
    var second: blob.PublishedBlob = undefined;
    const one = try std.Thread.spawn(.{}, Worker.run, .{ path, &first });
    const two = try std.Thread.spawn(.{}, Worker.run, .{ path, &second });
    one.join();
    two.join();
    try testing.expect(first.digest.eql(second.digest));
    try testing.expect(first.deduplicated != second.deduplicated);
}

test "verified retrieval rejects hardlinked content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var blobs = try blob.BlobStore.open(testing.allocator, path);
    defer blobs.close();
    const published = try blobs.putBytes("single link only");
    const hex = published.digest.format();
    const target = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/blobs/{s}/{s}", .{ path, hex[0..2], hex[2..] }, 0);
    defer testing.allocator.free(target);
    const alias = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/alias", .{path}, 0);
    defer testing.allocator.free(alias);
    try testing.expectEqual(@as(c_int, 0), c.link(target.ptr, alias.ptr));
    try testing.expectEqual(blob.VerifyResult{ .gap = .corrupt }, try blobs.verify(published.digest, published.length));
}

test "artifact append and immutable revision are atomic and ambiguity reconciles exact tuple" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    const published = try store.publishBytes("durable evidence");
    const fact = try revisionFact(testing.allocator, published, 1, 1, .local, "text/plain");
    defer testing.allocator.free(fact.payload);
    try testing.expectError(error.InvalidArtifactRevision, store.append(0, fact.value));
    store.setFailpoint(.after_revision_insert);
    try testing.expectError(error.InjectedFailure, store.commitArtifactRevision(0, fact.value, published));
    try testing.expect(!(try store.reconcileArtifactRevision(fact.value)));
    store.setFailpoint(.after_reference_commit);
    try testing.expectError(error.CommitOutcomeUnknown, store.commitArtifactRevision(0, fact.value, published));
    try testing.expect(try store.reconcileArtifactRevision(fact.value));
    try testing.expectEqual(@as(u64, 1), try store.blobReferenceCount(published.digest));
}

test "shared digest retains independent revision context and rejects caller trust elevation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    const published = try store.publishBytes("shared");
    const local = try revisionFact(testing.allocator, published, 1, 1, .local, "text/plain");
    defer testing.allocator.free(local.payload);
    _ = try store.commitArtifactRevision(0, local.value, published);
    const remote = try revisionFact(testing.allocator, published, 2, 2, .unverified_provider, "application/octet-stream");
    defer testing.allocator.free(remote.payload);
    _ = try store.commitArtifactRevision(1, remote.value, published);
    try testing.expectEqual(@as(u64, 2), try store.blobReferenceCount(published.digest));
    var elevated = remote.value;
    elevated.trust = .local;
    try testing.expectError(error.InvalidArtifactRevision, store.commitArtifactRevision(2, elevated, published));
}

test "artifact trust admission enforces the exact unauthenticated matrix" {
    const trusts = [_]event.Trust{ .local, .verified_provider, .unverified_provider };
    const provenances = [_]event.Provenance{ .local_authority, .provider_event, .imported };
    for (provenances) |provenance| for (trusts) |trust| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
        defer store.close();
        const published = try store.publishBytes("matrix");
        var fact_value = try revisionFact(testing.allocator, published, 1, 1, trust, "text/plain");
        defer testing.allocator.free(fact_value.payload);
        fact_value.value.provenance = provenance;
        const valid = (provenance == .local_authority and trust == .local) or
            ((provenance == .provider_event or provenance == .imported) and trust == .unverified_provider);
        if (valid)
            _ = try store.commitArtifactRevision(0, fact_value.value, published)
        else
            try testing.expectError(error.InvalidArtifactRevision, store.commitArtifactRevision(0, fact_value.value, published));
    };
}

test "artifact event identity and digest mismatches are rejected before transaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    const published = try store.publishBytes("expected bytes");
    const other = try store.publishBytes("other bytes");
    const fact = try revisionFact(testing.allocator, published, 1, 1, .local, "text/plain");
    defer testing.allocator.free(fact.payload);
    try testing.expectError(error.InvalidArtifactRevision, store.commitArtifactRevision(0, fact.value, other));
    var wrong_artifact = fact.value;
    wrong_artifact.stream_id = id(identity.ArtifactId, 99).bytes;
    try testing.expectError(error.InvalidArtifactRevisionPayload, store.commitArtifactRevision(0, wrong_artifact, published));
}

test "artifact revision ordinal is independent of artifact stream sequence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();

    const artifact = id(identity.ArtifactId, 3);
    const declaration: event.WorkEvent = .{
        .event_id = id(identity.EventId, 10),
        .source_provider_id = id(identity.ProviderInstanceId, 2),
        .stream_kind = .artifact,
        .stream_id = artifact.bytes,
        .stream_incarnation = 1,
        .stream_seq = 1,
        .occurred_at_ns = 1,
        .ingested_at_ns = 2,
        .ids = .{ .artifact_id = artifact },
        .payload_kind = @intFromEnum(event.PayloadKind.artifact_declared),
        .payload = "declared",
        .trust = .local,
        .provenance = .local_authority,
        .normalization_version = 1,
    };
    _ = try store.append(0, declaration);

    const published = try store.publishBytes("later revision");
    var revision = try revisionFact(testing.allocator, published, 11, 7, .local, "text/plain");
    defer testing.allocator.free(revision.payload);
    revision.value.stream_seq = 2;
    _ = try store.commitArtifactRevision(1, revision.value, published);
    try testing.expect(try store.reconcileArtifactRevision(revision.value));
}

test "commit versus purge lifecycle fence is deterministic in both barrier orders" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    const first_blob = try store.publishBytes("commit wins");
    const first = try revisionFact(testing.allocator, first_blob, 1, 1, .local, "text/plain");
    defer testing.allocator.free(first.payload);
    _ = try store.commitArtifactRevision(0, first.value, first_blob);
    try testing.expectError(error.BlobStillReferenced, store.purgeUnreferencedBlob(first_blob.digest));

    const second_blob = try store.publishBytes("purge checks first");
    try testing.expect(!(try store.purgeUnreferencedBlob(second_blob.digest)));
    const second = try revisionFact(testing.allocator, second_blob, 2, 2, .local, "text/plain");
    defer testing.allocator.free(second.payload);
    _ = try store.commitArtifactRevision(1, second.value, second_blob);
}

test "missing referenced bytes return a contextual transient evidence gap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    const published = try store.publishBytes("gap");
    const fact = try revisionFact(testing.allocator, published, 1, 1, .local, "text/plain");
    defer testing.allocator.free(fact.payload);
    _ = try store.commitArtifactRevision(0, fact.value, published);
    try testing.expect(try store.blobs.remove(published.digest));
    var ignored: u8 = 0;
    const result = try store.streamArtifactRevision(fact.value.event_id, .{ .context = &ignored, .write_fn = discard });
    try testing.expect(result == .gap);
    try testing.expectEqualDeep(fact.value.event_id, result.gap.event_id);
    try testing.expectEqual(@as(u64, 1), result.gap.revision_ordinal);
}

test "orphan final cleanup is grace-aware bounded and cursor-driven" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    const orphan = try store.publishBytes("unreferenced final");
    try testing.expectEqual(@as(usize, 0), try store.reconcileOrphanFiles(0, 60, 4));
    var removed: usize = 0;
    var calls: usize = 0;
    while (removed == 0 and calls < 256) : (calls += 1)
        removed += try store.reconcileOrphanFiles(std.math.maxInt(i64), 60, 4);
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(blob.VerifyResult{ .gap = .missing }, try store.blobs.verify(orphan.digest, orphan.length));
}

test "same-shard orphan continuation drains more entries than one page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var store = try store_mod.Store.open(testing.allocator, try tempPath(&tmp, &buffer));
    defer store.close();
    var chosen: ?u8 = null;
    var published: usize = 0;
    var candidate: usize = 0;
    while (published < 12) : (candidate += 1) {
        var bytes: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&bytes, "same-shard-{d}", .{candidate});
        const digest = blob.BlobDigest.hash(text);
        const shard = digest.bytes[0];
        if (chosen == null) chosen = shard;
        if (shard != chosen.?) continue;
        _ = try store.publishBytes(text);
        published += 1;
    }
    var removed: usize = 0;
    var calls: usize = 0;
    while (removed < published and calls < 4096) : (calls += 1)
        removed += try store.reconcileOrphanFiles(std.math.maxInt(i64), 0, 3);
    try testing.expectEqual(published, removed);
}

test "startup deterministically completes interrupted deleting inventory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    const published = try store.publishBytes("interrupted purge");
    store.close();

    const database = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/work.sqlite3", .{path}, 0);
    defer testing.allocator.free(database);
    const hex = published.digest.format();
    const sql = try std.fmt.allocPrintSentinel(testing.allocator, "INSERT INTO blobs(algorithm,digest,length,state,reference_count) VALUES(1,X'{s}',{d},1,0)", .{ &hex, published.length }, 0);
    defer testing.allocator.free(sql);
    var db_opt: ?*c.sqlite3 = null;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(database.ptr, &db_opt, c.SQLITE_OPEN_READWRITE, null));
    const db = db_opt.?;
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, sql.ptr, null, null, null));
    try testing.expectEqual(c.SQLITE_OK, c.sqlite3_close(db));

    var recovered = try store_mod.Store.open(testing.allocator, path);
    defer recovered.close();
    try testing.expectEqual(blob.VerifyResult{ .gap = .missing }, try recovered.blobs.verify(published.digest, published.length));
    try testing.expect(!(try recovered.purgeUnreferencedBlob(published.digest)));
}

test "bounded deleting recovery pages drain every ordered row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    defer store.close();
    const database = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/work.sqlite3", .{path}, 0);
    defer testing.allocator.free(database);
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(testing.allocator);
    try sql.appendSlice(testing.allocator, "BEGIN;");
    for (0..9) |index| {
        var bytes: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&bytes, "recovery-{d}", .{index});
        const item = try store.publishBytes(text);
        const hex = item.digest.format();
        const insert = try std.fmt.allocPrint(testing.allocator, "INSERT INTO blobs VALUES(1,X'{s}',{d},1,0);", .{ &hex, item.length });
        defer testing.allocator.free(insert);
        try sql.appendSlice(testing.allocator, insert);
    }
    try sql.appendSlice(testing.allocator, "COMMIT;\x00");
    try sqliteExec(database.ptr, @ptrCast(sql.items.ptr));
    var processed: usize = 0;
    while (true) {
        const page = try store.recoverDeletingBlobsPage(3);
        processed += page.processed;
        if (!page.has_more) break;
    }
    try testing.expectEqual(@as(usize, 9), processed);
}

test "purge retry completes an unknown mark and permits identical republication" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempPath(&tmp, &buffer);
    var store = try store_mod.Store.open(testing.allocator, path);
    defer store.close();
    const first = try store.publishBytes("republish me");
    const database = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/work.sqlite3", .{path}, 0);
    defer testing.allocator.free(database);
    const hex = first.digest.format();
    const insert = try std.fmt.allocPrintSentinel(testing.allocator, "INSERT INTO blobs VALUES(1,X'{s}',{d},0,0)", .{ &hex, first.length }, 0);
    defer testing.allocator.free(insert);
    try sqliteExec(database.ptr, insert.ptr);
    store.setFailpoint(.after_purge_mark);
    try testing.expectError(error.CommitOutcomeUnknown, store.purgeUnreferencedBlob(first.digest));
    try testing.expect(try store.purgeUnreferencedBlob(first.digest));
    try testing.expect(!(try store.purgeUnreferencedBlob(first.digest)));
    const second = try store.publishBytes("republish me");
    try testing.expect(first.digest.eql(second.digest));
    try testing.expect(!second.deduplicated);
    const fact_value = try revisionFact(testing.allocator, second, 1, 1, .local, "text/plain");
    defer testing.allocator.free(fact_value.payload);
    _ = try store.commitArtifactRevision(0, fact_value.value, second);
}

test "artifact projection verification rejects storage type and lineage divergence" {
    inline for (.{
        "PRAGMA ignore_check_constraints=ON; UPDATE artifact_revisions SET digest=lower(hex(digest))",
        "PRAGMA ignore_check_constraints=ON; UPDATE artifact_revisions SET producer_session_id=zeroblob(16)",
    }) |corruption| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try tempPath(&tmp, &buffer);
        var store = try store_mod.Store.open(testing.allocator, path);
        const published = try store.publishBytes("projection");
        const fact_value = try revisionFact(testing.allocator, published, 1, 1, .local, "text/plain");
        defer testing.allocator.free(fact_value.payload);
        _ = try store.commitArtifactRevision(0, fact_value.value, published);
        store.close();
        const database = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/work.sqlite3", .{path}, 0);
        defer testing.allocator.free(database);
        try sqliteExec(database.ptr, corruption);
        try testing.expectError(error.IntegrityFailure, store_mod.Store.open(testing.allocator, path));
    }
}
