//! Single-writer crash-safe SQLite event store.

const std = @import("std");
const event = @import("event.zig");
const identity = @import("identity.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("sys/file.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const schema_version: u32 = 1;
pub const application_id: u32 = 0x50485558; // "PHUX"
pub const default_page_budget: PageBudget = .{};

pub const PageBudget = struct {
    max_events: usize = 256,
    max_bytes: usize = 8 * 1024 * 1024,
};

pub const ReplayPage = struct {
    events: []event.StoredEvent,
    next_store_sequence: u64,
    has_more: bool,

    pub fn deinit(page: *ReplayPage, allocator: std.mem.Allocator) void {
        for (page.events) |*item| item.deinit(allocator);
        allocator.free(page.events);
        page.* = undefined;
    }
};

pub const Failpoint = enum {
    none,
    before_begin,
    after_begin,
    after_insert,
    before_commit,
    after_commit,
    before_checkpoint,
};

pub const AppendResult = union(enum) {
    appended: u64,
    duplicate: u64,
};

pub const Error = event.Error || std.mem.Allocator.Error || error{
    InvalidStatePath,
    UnsafeStatePath,
    PermissionDenied,
    ConcurrentWriter,
    OpenFailed,
    SqliteFailure,
    DiskFull,
    ReadOnly,
    IntegrityFailure,
    ForeignStore,
    NewerSchema,
    MigrationFailure,
    DuplicateConflict,
    ConcurrentAppend,
    SequenceGap,
    ReorderedEvent,
    SourceReset,
    SourceTransitionRequired,
    InvalidSourceTransition,
    InjectedFailure,
    CommitOutcomeUnknown,
    CheckpointFailure,
    StoreSequenceOverflow,
    InvalidStoreSequence,
    InvalidPageBudget,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    lock_fd: c_int,
    failpoint: Failpoint = .none,

    pub fn open(allocator: std.mem.Allocator, state_dir: []const u8) Error!Store {
        if (state_dir.len == 0 or state_dir[0] != '/' or std.mem.indexOfScalar(u8, state_dir, 0) != null)
            return error.InvalidStatePath;

        _ = try ensureStateDirectory(allocator, state_dir);
        const dir_z = try allocator.dupeZ(u8, state_dir);
        defer allocator.free(dir_z);
        const dir_fd = c.open(dir_z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (dir_fd < 0) return pathError();
        defer _ = c.close(dir_fd);
        try validateFd(dir_fd, true);

        // Refuse foreign/newer bytes before creating a lock or allowing SQLite
        // to create journals and sidecars.
        const database_exists = try preflightDatabase(dir_fd);
        try validateKnownFile(dir_fd, "work.lock");
        try validateKnownFile(dir_fd, "work.sqlite3-wal");
        try validateKnownFile(dir_fd, "work.sqlite3-shm");

        const lock_fd = c.openat(dir_fd, "work.lock", c.O_RDWR | c.O_CREAT | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (lock_fd < 0) return pathError();
        errdefer _ = c.close(lock_fd);
        try validateFd(lock_fd, false);
        if (c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            if (errno() == c.EWOULDBLOCK) return error.ConcurrentWriter;
            return pathError();
        }

        var initialized_file = false;
        if (!database_exists) {
            const fd = c.openat(dir_fd, "work.sqlite3", c.O_RDWR | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
            if (fd < 0) return pathError();
            initialized_file = true;
            _ = c.close(fd);
        }
        errdefer if (initialized_file) {
            _ = c.unlinkat(dir_fd, "work.sqlite3-wal", 0);
            _ = c.unlinkat(dir_fd, "work.sqlite3-shm", 0);
            _ = c.unlinkat(dir_fd, "work.sqlite3", 0);
        };

        const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}/work.sqlite3", .{state_dir}, 0);
        defer allocator.free(db_path);
        var db_opt: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_FULLMUTEX | c.SQLITE_OPEN_NOFOLLOW;
        if (c.sqlite3_open_v2(db_path.ptr, &db_opt, flags, null) != c.SQLITE_OK) {
            if (db_opt) |db| _ = c.sqlite3_close(db);
            return error.OpenFailed;
        }
        const db = db_opt.?;
        errdefer _ = c.sqlite3_close(db);
        if (c.sqlite3_limit(db, c.SQLITE_LIMIT_LENGTH, @intCast(event.max_envelope_bytes)) < 0)
            return error.SqliteFailure;

        var store: Store = .{ .allocator = allocator, .db = db, .lock_fd = lock_fd };
        try store.configureBase();
        try store.migrate(initialized_file);
        try store.configureDurability();
        try validateKnownFile(dir_fd, "work.sqlite3");
        try validateKnownFile(dir_fd, "work.sqlite3-wal");
        try validateKnownFile(dir_fd, "work.sqlite3-shm");
        try store.verifyIntegrity();
        return store;
    }

    pub fn close(store: *Store) void {
        _ = c.sqlite3_close(store.db);
        _ = c.flock(store.lock_fd, c.LOCK_UN);
        _ = c.close(store.lock_fd);
        store.* = undefined;
    }

    pub fn setFailpoint(store: *Store, failpoint: Failpoint) void {
        store.failpoint = failpoint;
    }

    pub fn append(store: *Store, expected_prior_sequence: u64, value: event.WorkEvent) Error!AppendResult {
        try value.validate();
        if (value.payload_kind == @intFromEnum(event.PayloadKind.source_transition))
            return error.InvalidSourceTransition;
        if (expected_prior_sequence > std.math.maxInt(i64)) return error.InvalidStreamSequence;
        return store.appendInternal(expected_prior_sequence, null, value);
    }

    /// Changes a logical stream's authority/incarnation. The transition event's
    /// payload is the previous producer ID, making the fence durable evidence.
    pub fn transitionSource(
        store: *Store,
        expected_source: [16]u8,
        expected_incarnation: u64,
        value: event.WorkEvent,
    ) Error!AppendResult {
        try value.validate();
        if (expected_incarnation == 0 or expected_incarnation > std.math.maxInt(i64))
            return error.InvalidStreamIncarnation;
        if (value.payload_kind != @intFromEnum(event.PayloadKind.source_transition) or
            value.payload_version != 1 or
            !std.mem.eql(u8, value.payload, &expected_source) or value.stream_seq != 1)
            return error.InvalidSourceTransition;
        return store.appendInternal(0, .{
            .source = expected_source,
            .incarnation = expected_incarnation,
        }, value);
    }

    pub fn lookup(store: *Store, allocator: std.mem.Allocator, event_id: identity.EventId) Error!?event.StoredEvent {
        const statement = try store.prepare(
            "SELECT store_seq,event_id,source_provider_id,stream_kind,stream_id,stream_incarnation,stream_seq,encoded,row_checksum " ++
                "FROM events WHERE event_id=?1",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindBlob(statement, 1, &event_id.bytes);
        const rc = c.sqlite3_step(statement);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return store.sqliteError();
        return try decodeRow(statement, allocator);
    }

    pub fn replayPage(
        store: *Store,
        allocator: std.mem.Allocator,
        after_store_sequence: u64,
        budget: PageBudget,
    ) Error!ReplayPage {
        if (after_store_sequence > std.math.maxInt(i64)) return error.InvalidStoreSequence;
        if (budget.max_events == 0 or budget.max_events >= std.math.maxInt(i64) or
            budget.max_bytes < event.max_envelope_bytes)
            return error.InvalidPageBudget;

        const statement = try store.prepare(
            "SELECT store_seq,event_id,source_provider_id,stream_kind,stream_id,stream_incarnation,stream_seq,encoded,row_checksum " ++
                "FROM events WHERE store_seq>?1 ORDER BY store_seq ASC LIMIT ?2",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, after_store_sequence, error.InvalidStoreSequence);
        try bindI64(statement, 2, @as(i64, @intCast(budget.max_events + 1)));

        var result: std.ArrayList(event.StoredEvent) = .empty;
        errdefer {
            for (result.items) |*item| item.deinit(allocator);
            result.deinit(allocator);
        }
        var encoded_bytes: usize = 0;
        var has_more = false;
        while (true) {
            const rc = c.sqlite3_step(statement);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return store.sqliteError();
            const length = try checkedBlobLength(statement, 7, event.max_envelope_bytes);
            if (result.items.len == budget.max_events or length > budget.max_bytes - encoded_bytes) {
                has_more = true;
                break;
            }
            var decoded = try decodeRow(statement, allocator);
            errdefer decoded.deinit(allocator);
            encoded_bytes += length;
            try result.append(allocator, decoded);
        }
        const next = if (result.items.len == 0) after_store_sequence else result.items[result.items.len - 1].store_seq;
        return .{
            .events = try result.toOwnedSlice(allocator),
            .next_store_sequence = next,
            .has_more = has_more,
        };
    }

    pub fn verifyIntegrity(store: *Store) Error!void {
        try store.expectPragmaOk("PRAGMA quick_check");
        try store.requireNoForeignKeyViolations();

        const statement = try store.prepare(
            "SELECT store_seq,event_id,source_provider_id,stream_kind,stream_id,stream_incarnation,stream_seq,encoded,row_checksum " ++
                "FROM events ORDER BY store_seq ASC",
        );
        defer _ = c.sqlite3_finalize(statement);
        while (true) {
            const rc = c.sqlite3_step(statement);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return store.sqliteError();
            var decoded = decodeRow(statement, store.allocator) catch return error.IntegrityFailure;
            decoded.deinit(store.allocator);
        }
        try store.verifyStreamHeads();
    }

    pub fn checkpoint(store: *Store) Error!void {
        if (store.failpoint == .before_checkpoint) {
            store.failpoint = .none;
            return error.CheckpointFailure;
        }
        var log_frames: c_int = 0;
        var checkpointed: c_int = 0;
        if (c.sqlite3_wal_checkpoint_v2(store.db, null, c.SQLITE_CHECKPOINT_FULL, &log_frames, &checkpointed) != c.SQLITE_OK)
            return error.CheckpointFailure;
        if (log_frames != checkpointed) return error.CheckpointFailure;
    }

    /// Metadata boundary for later blob materialization. The event store does
    /// not claim a blob is durable until a later writer commits a reference.
    pub const BlobMetadata = struct {
        digest: [32]u8,
        length: u64,
        media_type: []const u8,
        reference_count: u64,
    };

    const TransitionFence = struct { source: [16]u8, incarnation: u64 };
    const Head = struct { sequence: u64, source: [16]u8, incarnation: u64 };

    fn appendInternal(
        store: *Store,
        expected_prior_sequence: u64,
        transition: ?TransitionFence,
        value: event.WorkEvent,
    ) Error!AppendResult {
        const encoded = try event.encode(store.allocator, value);
        defer store.allocator.free(encoded);

        try store.fire(.before_begin);
        try store.exec("BEGIN IMMEDIATE");
        var committed = false;
        defer if (!committed) store.exec("ROLLBACK") catch {};
        try store.fire(.after_begin);

        if (try store.findDuplicate(&value.event_id.bytes, encoded)) |result| {
            try store.exec("COMMIT");
            committed = true;
            return result;
        }

        const head = try store.streamHead(value.stream_kind, value.stream_id);
        if (transition) |fence| {
            const current = head orelse return error.InvalidSourceTransition;
            if (!std.mem.eql(u8, &current.source, &fence.source) or current.incarnation != fence.incarnation)
                return error.ConcurrentAppend;
            if (value.stream_incarnation <= current.incarnation) return error.InvalidSourceTransition;
        } else if (head) |current| {
            if (value.stream_incarnation != current.incarnation) return error.SourceTransitionRequired;
            if (!std.mem.eql(u8, &current.source, &value.source_provider_id.bytes)) return error.SourceReset;
            if (expected_prior_sequence != current.sequence) return error.ConcurrentAppend;
            if (value.stream_seq <= current.sequence) return error.ReorderedEvent;
            if (value.stream_seq != current.sequence + 1) return error.SequenceGap;
        } else {
            if (expected_prior_sequence != 0) return error.ConcurrentAppend;
            if (value.stream_seq != 1) return error.SequenceGap;
        }

        const store_sequence = try store.nextStoreSequence();
        const row_checksum = rowChecksum(store_sequence, value, encoded);
        const statement = try store.prepare(
            "INSERT INTO events(store_seq,event_id,source_provider_id,stream_kind,stream_id,stream_incarnation,stream_seq,encoded,row_checksum) " ++
                "VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindU64(statement, 1, store_sequence, error.InvalidStoreSequence);
        try bindBlob(statement, 2, &value.event_id.bytes);
        try bindBlob(statement, 3, &value.source_provider_id.bytes);
        try bindI64(statement, 4, @intFromEnum(value.stream_kind));
        try bindBlob(statement, 5, &value.stream_id);
        try bindU64(statement, 6, value.stream_incarnation, error.InvalidStreamIncarnation);
        try bindU64(statement, 7, value.stream_seq, error.InvalidStreamSequence);
        try bindBlob(statement, 8, encoded);
        try bindBlob(statement, 9, &row_checksum);
        try store.stepDone(statement);

        const update = try store.prepare(
            "INSERT INTO stream_heads(stream_kind,stream_id,source_provider_id,stream_incarnation,stream_seq) VALUES(?1,?2,?3,?4,?5) " ++
                "ON CONFLICT(stream_kind,stream_id) DO UPDATE SET source_provider_id=excluded.source_provider_id," ++
                "stream_incarnation=excluded.stream_incarnation,stream_seq=excluded.stream_seq",
        );
        defer _ = c.sqlite3_finalize(update);
        try bindI64(update, 1, @intFromEnum(value.stream_kind));
        try bindBlob(update, 2, &value.stream_id);
        try bindBlob(update, 3, &value.source_provider_id.bytes);
        try bindU64(update, 4, value.stream_incarnation, error.InvalidStreamIncarnation);
        try bindU64(update, 5, value.stream_seq, error.InvalidStreamSequence);
        try store.stepDone(update);

        try store.fire(.after_insert);
        try store.fire(.before_commit);
        try store.exec("COMMIT");
        committed = true;
        if (store.failpoint == .after_commit) {
            store.failpoint = .none;
            return error.CommitOutcomeUnknown;
        }
        return .{ .appended = store_sequence };
    }

    fn configureBase(store: *Store) Error!void {
        try store.exec("PRAGMA foreign_keys=ON");
        try store.exec("PRAGMA synchronous=FULL");
        try store.exec("PRAGMA busy_timeout=0");
    }

    fn configureDurability(store: *Store) Error!void {
        try store.expectPragmaText("PRAGMA journal_mode=WAL", "wal");
        try store.exec("PRAGMA synchronous=FULL");
        try store.expectPragmaInt("PRAGMA synchronous", 2);
        try store.exec("PRAGMA wal_autocheckpoint=1000");
    }

    fn migrate(store: *Store, new_file: bool) Error!void {
        const version = try store.pragmaInt("PRAGMA user_version");
        const app_id = try store.pragmaInt("PRAGMA application_id");
        if (version > schema_version) return error.NewerSchema;
        if (!new_file and app_id != application_id) return error.ForeignStore;
        if (version == schema_version) {
            try store.verifyStoreMeta();
            return;
        }
        if (!new_file) return error.ForeignStore;
        if (version != 0) return error.MigrationFailure;

        try store.exec("BEGIN EXCLUSIVE");
        var committed = false;
        defer if (!committed) store.exec("ROLLBACK") catch {};
        try store.exec(
            "PRAGMA application_id=1346917720;" ++
                "CREATE TABLE store_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);" ++
                "INSERT INTO store_meta VALUES('format','phux-work-event-store');" ++
                "INSERT INTO store_meta VALUES('schema_version','1');" ++
                "CREATE TABLE events(" ++
                " store_seq INTEGER PRIMARY KEY CHECK(store_seq>0)," ++
                " event_id BLOB NOT NULL UNIQUE CHECK(typeof(event_id)='blob' AND length(event_id)=16)," ++
                " source_provider_id BLOB NOT NULL CHECK(typeof(source_provider_id)='blob' AND length(source_provider_id)=16)," ++
                " stream_kind INTEGER NOT NULL CHECK(typeof(stream_kind)='integer' AND stream_kind BETWEEN 0 AND 5)," ++
                " stream_id BLOB NOT NULL CHECK(typeof(stream_id)='blob' AND length(stream_id)=16)," ++
                " stream_incarnation INTEGER NOT NULL CHECK(typeof(stream_incarnation)='integer' AND stream_incarnation>0)," ++
                " stream_seq INTEGER NOT NULL CHECK(typeof(stream_seq)='integer' AND stream_seq>0)," ++
                " encoded BLOB NOT NULL CHECK(typeof(encoded)='blob' AND length(encoded)<=1048576)," ++
                " row_checksum BLOB NOT NULL CHECK(typeof(row_checksum)='blob' AND length(row_checksum)=32)," ++
                " UNIQUE(stream_kind,stream_id,stream_incarnation,stream_seq));" ++
                "CREATE INDEX events_stream_order ON events(stream_kind,stream_id,stream_incarnation,stream_seq);" ++
                "CREATE TABLE stream_heads(" ++
                " stream_kind INTEGER NOT NULL,stream_id BLOB NOT NULL,source_provider_id BLOB NOT NULL," ++
                " stream_incarnation INTEGER NOT NULL,stream_seq INTEGER NOT NULL," ++
                " PRIMARY KEY(stream_kind,stream_id));" ++
                "CREATE TABLE blobs(digest BLOB PRIMARY KEY CHECK(typeof(digest)='blob' AND length(digest)=32)," ++
                "length INTEGER NOT NULL,media_type TEXT NOT NULL,reference_count INTEGER NOT NULL CHECK(reference_count>=0));" ++
                "PRAGMA user_version=1",
        );
        try store.requireNoForeignKeyViolations();
        try store.verifyStoreMeta();
        try store.exec("COMMIT");
        committed = true;
    }

    fn verifyStoreMeta(store: *Store) Error!void {
        const statement = try store.prepare(
            "SELECT (SELECT value FROM store_meta WHERE key='format')," ++
                "(SELECT value FROM store_meta WHERE key='schema_version')",
        );
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return error.ForeignStore;
        if (c.sqlite3_column_type(statement, 0) != c.SQLITE_TEXT or c.sqlite3_column_type(statement, 1) != c.SQLITE_TEXT)
            return error.ForeignStore;
        const format_length = c.sqlite3_column_bytes(statement, 0);
        const format = c.sqlite3_column_text(statement, 0) orelse return error.ForeignStore;
        const version_length = c.sqlite3_column_bytes(statement, 1);
        const version = c.sqlite3_column_text(statement, 1) orelse return error.ForeignStore;
        if (format_length != 21 or !std.mem.eql(u8, format[0..21], "phux-work-event-store") or
            version_length != 1 or !std.mem.eql(u8, version[0..1], "1"))
            return error.ForeignStore;
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.ForeignStore;
    }

    fn streamHead(store: *Store, kind: event.StreamKind, id: [16]u8) Error!?Head {
        const statement = try store.prepare(
            "SELECT stream_seq,source_provider_id,stream_incarnation FROM stream_heads WHERE stream_kind=?1 AND stream_id=?2",
        );
        defer _ = c.sqlite3_finalize(statement);
        try bindI64(statement, 1, @intFromEnum(kind));
        try bindBlob(statement, 2, &id);
        const rc = c.sqlite3_step(statement);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return store.sqliteError();
        const sequence = try positiveInteger(statement, 0);
        const source_raw = try checkedBlob(statement, 1, 16, 16);
        const incarnation = try positiveInteger(statement, 2);
        var source: [16]u8 = undefined;
        @memcpy(&source, source_raw);
        return .{ .sequence = sequence, .source = source, .incarnation = incarnation };
    }

    fn findDuplicate(store: *Store, id: *const [16]u8, encoded: []const u8) Error!?AppendResult {
        const typed_id = identity.EventId.fromStorage(id) catch return error.InvalidId;
        const found = try store.lookup(store.allocator, typed_id) orelse return null;
        var previous = found;
        defer previous.deinit(store.allocator);
        const canonical = try event.encode(store.allocator, previous.event);
        defer store.allocator.free(canonical);
        if (!std.mem.eql(u8, canonical, encoded)) return error.DuplicateConflict;
        return .{ .duplicate = previous.store_seq };
    }

    fn nextStoreSequence(store: *Store) Error!u64 {
        const statement = try store.prepare("SELECT COALESCE(MAX(store_seq),0) FROM events");
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW) return store.sqliteError();
        if (c.sqlite3_column_type(statement, 0) != c.SQLITE_INTEGER) return error.IntegrityFailure;
        const current = c.sqlite3_column_int64(statement, 0);
        if (current < 0 or current == std.math.maxInt(i64)) return error.StoreSequenceOverflow;
        return @intCast(current + 1);
    }

    fn verifyStreamHeads(store: *Store) Error!void {
        const statement = try store.prepare(
            "SELECT h.stream_kind,h.stream_id,h.source_provider_id,h.stream_incarnation,h.stream_seq " ++
                "FROM stream_heads h WHERE NOT EXISTS (SELECT 1 FROM events e WHERE " ++
                "e.stream_kind=h.stream_kind AND e.stream_id=h.stream_id AND e.source_provider_id=h.source_provider_id AND " ++
                "e.stream_incarnation=h.stream_incarnation AND e.stream_seq=h.stream_seq) OR EXISTS (SELECT 1 FROM events e WHERE " ++
                "e.stream_kind=h.stream_kind AND e.stream_id=h.stream_id AND " ++
                "(e.stream_incarnation>h.stream_incarnation OR (e.stream_incarnation=h.stream_incarnation AND e.stream_seq>h.stream_seq))) LIMIT 1",
        );
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return error.IntegrityFailure;
    }

    fn requireNoForeignKeyViolations(store: *Store) Error!void {
        const statement = try store.prepare("PRAGMA foreign_key_check");
        defer _ = c.sqlite3_finalize(statement);
        while (true) {
            const rc = c.sqlite3_step(statement);
            if (rc == c.SQLITE_DONE) return;
            if (rc == c.SQLITE_ROW) return error.IntegrityFailure;
            return store.sqliteError();
        }
    }

    fn fire(store: *Store, point: Failpoint) Error!void {
        if (store.failpoint == point) {
            store.failpoint = .none;
            return error.InjectedFailure;
        }
    }

    fn prepare(store: *Store, sql: [*:0]const u8) Error!*c.sqlite3_stmt {
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(store.db, sql, -1, &statement, null) != c.SQLITE_OK) return store.sqliteError();
        return statement orelse error.SqliteFailure;
    }

    fn exec(store: *Store, sql: [*:0]const u8) Error!void {
        if (c.sqlite3_exec(store.db, sql, null, null, null) != c.SQLITE_OK) return store.sqliteError();
    }

    fn stepDone(store: *Store, statement: *c.sqlite3_stmt) Error!void {
        if (c.sqlite3_step(statement) != c.SQLITE_DONE) return store.sqliteError();
    }

    fn pragmaInt(store: *Store, sql: [*:0]const u8) Error!u32 {
        const statement = try store.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_type(statement, 0) != c.SQLITE_INTEGER)
            return error.IntegrityFailure;
        const value = c.sqlite3_column_int64(statement, 0);
        if (value < 0 or value > std.math.maxInt(u32)) return error.IntegrityFailure;
        return @intCast(value);
    }

    fn expectPragmaInt(store: *Store, sql: [*:0]const u8, expected: i64) Error!void {
        const statement = try store.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_type(statement, 0) != c.SQLITE_INTEGER or
            c.sqlite3_column_int64(statement, 0) != expected)
            return error.IntegrityFailure;
    }

    fn expectPragmaText(store: *Store, sql: [*:0]const u8, expected: []const u8) Error!void {
        const statement = try store.prepare(sql);
        defer _ = c.sqlite3_finalize(statement);
        if (c.sqlite3_step(statement) != c.SQLITE_ROW or c.sqlite3_column_type(statement, 0) != c.SQLITE_TEXT)
            return error.IntegrityFailure;
        const length = c.sqlite3_column_bytes(statement, 0);
        const text = c.sqlite3_column_text(statement, 0) orelse return error.IntegrityFailure;
        if (length != expected.len or !std.mem.eql(u8, text[0..expected.len], expected)) return error.IntegrityFailure;
    }

    fn expectPragmaOk(store: *Store, sql: [*:0]const u8) Error!void {
        try store.expectPragmaText(sql, "ok");
    }

    fn sqliteError(store: *Store) Error {
        return switch (c.sqlite3_extended_errcode(store.db) & 0xff) {
            c.SQLITE_FULL => error.DiskFull,
            c.SQLITE_READONLY => error.ReadOnly,
            c.SQLITE_PERM, c.SQLITE_CANTOPEN => error.PermissionDenied,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.ConcurrentWriter,
            c.SQLITE_CORRUPT, c.SQLITE_NOTADB, c.SQLITE_CONSTRAINT, c.SQLITE_TOOBIG => error.IntegrityFailure,
            else => error.SqliteFailure,
        };
    }
};

fn decodeRow(statement: *c.sqlite3_stmt, allocator: std.mem.Allocator) Error!event.StoredEvent {
    const store_sequence = try positiveInteger(statement, 0);
    const event_id = try checkedBlob(statement, 1, 16, 16);
    const source = try checkedBlob(statement, 2, 16, 16);
    const kind_value = try positiveOrZeroInteger(statement, 3);
    const stream_id = try checkedBlob(statement, 4, 16, 16);
    const incarnation = try positiveInteger(statement, 5);
    const sequence = try positiveInteger(statement, 6);
    const encoded = try checkedBlob(statement, 7, event.checksum_size, event.max_envelope_bytes);
    const stored_checksum = try checkedBlob(statement, 8, event.checksum_size, event.checksum_size);

    var checksum_value: [event.checksum_size]u8 = undefined;
    @memcpy(&checksum_value, stored_checksum);
    const decoded = event.decode(allocator, encoded) catch return error.IntegrityFailure;
    errdefer allocator.free(decoded.payload);
    if (kind_value > std.math.maxInt(u8) or
        !std.mem.eql(u8, event_id, &decoded.event_id.bytes) or
        !std.mem.eql(u8, source, &decoded.source_provider_id.bytes) or
        kind_value != @intFromEnum(decoded.stream_kind) or
        !std.mem.eql(u8, stream_id, &decoded.stream_id) or
        incarnation != decoded.stream_incarnation or sequence != decoded.stream_seq)
        return error.IntegrityFailure;
    const expected = rowChecksum(store_sequence, decoded, encoded);
    if (!std.mem.eql(u8, &expected, &checksum_value)) return error.IntegrityFailure;
    return .{ .store_seq = store_sequence, .event = decoded, .checksum = checksum_value };
}

fn rowChecksum(store_sequence: u64, value: event.WorkEvent, encoded: []const u8) [event.checksum_size]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("phux-work-store-row-v1\x00");
    hashInt(&hash, store_sequence);
    hash.update(&value.event_id.bytes);
    hash.update(&value.source_provider_id.bytes);
    hashInt(&hash, @as(u64, @intFromEnum(value.stream_kind)));
    hash.update(&value.stream_id);
    hashInt(&hash, value.stream_incarnation);
    hashInt(&hash, value.stream_seq);
    hash.update(encoded);
    var digest: [event.checksum_size]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn hashInt(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn bindBlob(statement: *c.sqlite3_stmt, index: c_int, bytes: []const u8) Error!void {
    if (bytes.len > std.math.maxInt(c_int)) return error.EnvelopeTooLarge;
    if (c.sqlite3_bind_blob(statement, index, bytes.ptr, @intCast(bytes.len), null) != c.SQLITE_OK)
        return error.SqliteFailure;
}

fn bindI64(statement: *c.sqlite3_stmt, index: c_int, value: anytype) Error!void {
    if (c.sqlite3_bind_int64(statement, index, @intCast(value)) != c.SQLITE_OK) return error.SqliteFailure;
}

fn bindU64(statement: *c.sqlite3_stmt, index: c_int, value: u64, comptime overflow_error: Error) Error!void {
    if (value > std.math.maxInt(i64)) return overflow_error;
    try bindI64(statement, index, value);
}

fn positiveInteger(statement: *c.sqlite3_stmt, column: c_int) Error!u64 {
    if (c.sqlite3_column_type(statement, column) != c.SQLITE_INTEGER) return error.IntegrityFailure;
    const value = c.sqlite3_column_int64(statement, column);
    if (value <= 0) return error.IntegrityFailure;
    return @intCast(value);
}

fn positiveOrZeroInteger(statement: *c.sqlite3_stmt, column: c_int) Error!u64 {
    if (c.sqlite3_column_type(statement, column) != c.SQLITE_INTEGER) return error.IntegrityFailure;
    const value = c.sqlite3_column_int64(statement, column);
    if (value < 0) return error.IntegrityFailure;
    return @intCast(value);
}

fn checkedBlobLength(statement: *c.sqlite3_stmt, column: c_int, maximum: usize) Error!usize {
    if (c.sqlite3_column_type(statement, column) != c.SQLITE_BLOB) return error.IntegrityFailure;
    const length = c.sqlite3_column_bytes(statement, column);
    if (length < 0 or length > maximum) return error.IntegrityFailure;
    return @intCast(length);
}

fn checkedBlob(statement: *c.sqlite3_stmt, column: c_int, minimum: usize, maximum: usize) Error![]const u8 {
    const length = try checkedBlobLength(statement, column, maximum);
    if (length < minimum) return error.IntegrityFailure;
    const pointer = c.sqlite3_column_blob(statement, column) orelse return error.IntegrityFailure;
    return @as([*]const u8, @ptrCast(pointer))[0..length];
}

fn ensureStateDirectory(allocator: std.mem.Allocator, path: []const u8) Error!bool {
    var end: usize = 1;
    while (end <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, end, '/') orelse path.len;
        if (slash > 1) {
            const prefix = try allocator.dupeZ(u8, path[0..slash]);
            defer allocator.free(prefix);
            var status: c.struct_stat = undefined;
            if (c.lstat(prefix.ptr, &status) != 0) {
                if (errno() == c.ENOENT and slash == path.len) {
                    if (c.mkdir(prefix.ptr, 0o700) != 0) return pathError();
                    return true;
                }
                return pathError();
            }
            if ((status.st_mode & c.S_IFMT) == c.S_IFLNK) return error.UnsafeStatePath;
            if ((status.st_mode & c.S_IFMT) != c.S_IFDIR) return error.InvalidStatePath;
            if (slash == path.len) try validateStat(status, true);
        }
        if (slash == path.len) break;
        end = slash + 1;
    }
    return false;
}

fn preflightDatabase(dir_fd: c_int) Error!bool {
    const fd = c.openat(dir_fd, "work.sqlite3", c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        if (errno() == c.ENOENT) return false;
        return pathError();
    }
    defer _ = c.close(fd);
    try validateFd(fd, false);
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return pathError();
    if (status.st_size < 100) return error.ForeignStore;
    var header: [100]u8 = undefined;
    if (c.pread(fd, &header, header.len, 0) != header.len) return error.ForeignStore;
    if (!std.mem.eql(u8, header[0..16], "SQLite format 3\x00")) return error.ForeignStore;
    const version = std.mem.readInt(u32, header[60..64], .big);
    const app_id = std.mem.readInt(u32, header[68..72], .big);
    if (app_id != application_id) return error.ForeignStore;
    if (version > schema_version) return error.NewerSchema;
    if (version == 0) return error.ForeignStore;
    const encoded_page_size = std.mem.readInt(u16, header[16..18], .big);
    const page_size: usize = if (encoded_page_size == 1) 65536 else encoded_page_size;
    if (page_size < 512 or !std.math.isPowerOfTwo(page_size)) return error.IntegrityFailure;
    try preflightWal(dir_fd, page_size);
    return true;
}

fn preflightWal(dir_fd: c_int, page_size: usize) Error!void {
    const fd = c.openat(dir_fd, "work.sqlite3-wal", c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        if (errno() == c.ENOENT) return;
        return pathError();
    }
    defer _ = c.close(fd);
    try validateFd(fd, false);
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return error.IntegrityFailure;
    if (status.st_size == 0) return;
    if (status.st_size < 32) return error.IntegrityFailure;

    var wal_header: [32]u8 = undefined;
    try preadExact(fd, &wal_header, 0);
    const magic = std.mem.readInt(u32, wal_header[0..4], .big);
    if (magic != 0x377f0682 and magic != 0x377f0683) return error.IntegrityFailure;
    if (std.mem.readInt(u32, wal_header[8..12], .big) != page_size) return error.IntegrityFailure;

    const frame_size = 24 + page_size;
    var offset: usize = 32;
    while (offset <= @as(usize, @intCast(status.st_size)) -| frame_size) : (offset += frame_size) {
        var frame_header: [24]u8 = undefined;
        try preadExact(fd, &frame_header, offset);
        if (std.mem.readInt(u32, frame_header[0..4], .big) != 1) continue;
        var page_header: [100]u8 = undefined;
        try preadExact(fd, &page_header, offset + 24);
        if (!std.mem.eql(u8, page_header[0..16], "SQLite format 3\x00")) return error.IntegrityFailure;
        const version = std.mem.readInt(u32, page_header[60..64], .big);
        const app_id = std.mem.readInt(u32, page_header[68..72], .big);
        if (app_id != application_id or version == 0) return error.ForeignStore;
        if (version > schema_version) return error.NewerSchema;
    }
}

fn preadExact(fd: c_int, bytes: []u8, offset: usize) Error!void {
    var read_offset: usize = 0;
    while (read_offset < bytes.len) {
        const count = c.pread(fd, bytes.ptr + read_offset, bytes.len - read_offset, @intCast(offset + read_offset));
        if (count <= 0) return error.IntegrityFailure;
        read_offset += @intCast(count);
    }
}

fn validateKnownFile(dir_fd: c_int, name: [*:0]const u8) Error!void {
    const fd = c.openat(dir_fd, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) {
        if (errno() == c.ENOENT) return;
        return pathError();
    }
    defer _ = c.close(fd);
    try validateFd(fd, false);
}

fn validateFd(fd: c_int, directory: bool) Error!void {
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return pathError();
    try validateStat(status, directory);
}

fn validateStat(status: c.struct_stat, directory: bool) Error!void {
    const expected: c_uint = if (directory) c.S_IFDIR else c.S_IFREG;
    if ((status.st_mode & c.S_IFMT) != expected) return error.UnsafeStatePath;
    if (status.st_uid != c.geteuid()) return error.PermissionDenied;
    if ((status.st_mode & 0o077) != 0) return error.PermissionDenied;
}

fn pathError() Error {
    return switch (errno()) {
        c.EACCES, c.EPERM, c.EROFS => error.PermissionDenied,
        c.ENOSPC => error.DiskFull,
        c.ELOOP => error.UnsafeStatePath,
        c.ENOTDIR => error.InvalidStatePath,
        else => error.OpenFailed,
    };
}

fn errno() c_int {
    return c.__error().*;
}
