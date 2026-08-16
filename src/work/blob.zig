//! Bounded, streaming, content-addressed evidence blob storage.

const std = @import("std");

const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

extern "c" fn arc4random_buf(buffer: *anyopaque, length: usize) void;

pub const default_max_blob_bytes: u64 = 2 * 1024 * 1024 * 1024;
pub const max_put_bytes: usize = 1024 * 1024;
pub const digest_bytes = 32;
pub const digest_hex_bytes = digest_bytes * 2;
pub const io_buffer_bytes = 64 * 1024;

pub const BlobDigest = struct {
    bytes: [digest_bytes]u8,

    pub fn hash(bytes: []const u8) BlobDigest {
        var digest: BlobDigest = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest.bytes, .{});
        return digest;
    }

    pub fn parse(text: []const u8) Error!BlobDigest {
        if (text.len != digest_hex_bytes) return error.InvalidDigest;
        var result: BlobDigest = undefined;
        for (0..digest_bytes) |index| {
            const high = hexValue(text[index * 2]) orelse return error.InvalidDigest;
            const low = hexValue(text[index * 2 + 1]) orelse return error.InvalidDigest;
            result.bytes[index] = (high << 4) | low;
        }
        return result;
    }

    pub fn format(value: BlobDigest) [digest_hex_bytes]u8 {
        const alphabet = "0123456789abcdef";
        var result: [digest_hex_bytes]u8 = undefined;
        for (value.bytes, 0..) |byte, index| {
            result[index * 2] = alphabet[byte >> 4];
            result[index * 2 + 1] = alphabet[byte & 0x0f];
        }
        return result;
    }

    pub fn eql(a: BlobDigest, b: BlobDigest) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

pub const Policy = struct { max_bytes: u64 = default_max_blob_bytes };
pub const PublishedBlob = struct { digest: BlobDigest, length: u64, deduplicated: bool };
pub const IntegrityGap = enum { missing, corrupt };
pub const VerifyResult = union(enum) { verified, gap: IntegrityGap };

pub const StreamSource = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) Error!usize,
};

pub const StreamSink = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, []const u8) Error!void,
};

pub const Failpoint = enum { none, temp_write, temp_fsync, publish, directory_fsync };
pub const SnapshotHook = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) void,
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidStatePath,
    UnsafeStatePath,
    PermissionDenied,
    OpenFailed,
    DiskFull,
    BlobTooLarge,
    InvalidDigest,
    IntegrityFailure,
    InjectedFailure,
};

pub const BlobStore = struct {
    allocator: std.mem.Allocator,
    root_fd: c_int,
    failpoint: Failpoint = .none,
    snapshot_hook: ?SnapshotHook = null,
    mutex: std.atomic.Mutex = .unlocked,

    pub const PhysicalGuard = struct {
        store: *BlobStore,

        pub fn release(guard: *PhysicalGuard) void {
            guard.store.mutex.unlock();
            guard.* = undefined;
        }

        pub fn rootFd(guard: *PhysicalGuard) c_int {
            return guard.store.root_fd;
        }

        pub fn verify(guard: *PhysicalGuard, digest: BlobDigest, expected_length: u64) Error!VerifyResult {
            return guard.store.streamVerifiedUnlocked(digest, expected_length, null);
        }

        pub fn remove(guard: *PhysicalGuard, digest: BlobDigest) Error!bool {
            return guard.store.removeUnlocked(digest);
        }
    };

    pub fn open(allocator: std.mem.Allocator, state_dir: []const u8) Error!BlobStore {
        const state_fd = try openAbsoluteDirectory(state_dir, false);
        defer _ = c.close(state_fd);
        return openAt(allocator, state_fd);
    }

    pub fn openAt(allocator: std.mem.Allocator, state_fd: c_int) Error!BlobStore {
        try validateFd(state_fd, true, false);
        var created = false;
        if (c.mkdirat(state_fd, "blobs", 0o700) != 0) {
            if (errno() != c.EEXIST) return pathError();
        } else created = true;
        const root_fd = c.openat(state_fd, "blobs", c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (root_fd < 0) return pathError();
        errdefer _ = c.close(root_fd);
        try validateFd(root_fd, true, false);
        if (created and c.fsync(state_fd) != 0) return pathError();
        return .{ .allocator = allocator, .root_fd = root_fd };
    }

    pub fn close(store: *BlobStore) void {
        _ = c.close(store.root_fd);
        store.* = undefined;
    }

    pub fn setFailpoint(store: *BlobStore, point: Failpoint) void {
        store.failpoint = point;
    }

    /// Deterministic unit-test seam invoked after a verified private snapshot
    /// is complete and before its bytes are delivered.
    pub fn setSnapshotHook(store: *BlobStore, hook: ?SnapshotHook) void {
        store.snapshot_hook = hook;
    }

    pub fn lockPhysical(store: *BlobStore) PhysicalGuard {
        lock(&store.mutex);
        return .{ .store = store };
    }

    pub fn putBytes(store: *BlobStore, bytes: []const u8) Error!PublishedBlob {
        if (bytes.len > max_put_bytes) return error.BlobTooLarge;
        var context = BytesSource{ .bytes = bytes };
        return store.putStream(.{ .context = &context, .read_fn = BytesSource.read }, .{ .max_bytes = max_put_bytes });
    }

    pub fn putStream(store: *BlobStore, source: StreamSource, policy: Policy) Error!PublishedBlob {
        if (policy.max_bytes > std.math.maxInt(i64)) return error.BlobTooLarge;
        lock(&store.mutex);
        defer store.mutex.unlock();

        var temp_name: [38:0]u8 = undefined;
        var temp_fd: c_int = -1;
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            var random: [16]u8 = undefined;
            arc4random_buf(&random, random.len);
            const hex = formatRandom(random);
            @memcpy(temp_name[0..5], ".tmp-");
            @memcpy(temp_name[5..37], &hex);
            temp_name[37] = 0;
            temp_fd = c.openat(store.root_fd, &temp_name, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
            if (temp_fd >= 0) break;
            if (errno() != c.EEXIST) return pathError();
        }
        if (temp_fd < 0) return error.OpenFailed;
        var temp_exists = true;
        defer _ = c.close(temp_fd);
        defer {
            if (temp_exists) _ = c.unlinkat(store.root_fd, &temp_name, 0);
        }
        try validateFd(temp_fd, false, true);

        var hash = std.crypto.hash.Blake3.init(.{});
        var total: u64 = 0;
        var buffer: [io_buffer_bytes]u8 = undefined;
        while (true) {
            const count = try source.read_fn(source.context, &buffer);
            if (count > buffer.len) return error.IntegrityFailure;
            if (count == 0) break;
            if (count > policy.max_bytes -| total) return error.BlobTooLarge;
            writeExact(temp_fd, buffer[0..count]) catch |err| return err;
            hash.update(buffer[0..count]);
            total += count;
        }
        try store.fire(.temp_write);
        if (c.fsync(temp_fd) != 0) return pathError();
        try store.fire(.temp_fsync);

        var digest: BlobDigest = undefined;
        hash.final(&digest.bytes);
        const names = try openShard(store.root_fd, digest, true);
        defer _ = c.close(names.fd);
        if (names.created and c.fsync(store.root_fd) != 0) return pathError();

        var deduplicated = false;
        if (c.renameatx_np(store.root_fd, &temp_name, names.fd, &names.file_name, c.RENAME_EXCL) != 0) {
            if (errno() != c.EEXIST) return pathError();
            deduplicated = true;
            try verifyFile(names.fd, &names.file_name, digest, total);
            if (c.unlinkat(store.root_fd, &temp_name, 0) != 0) return pathError();
        }
        temp_exists = false;
        try store.fire(.publish);
        if (c.fsync(names.fd) != 0) return pathError();
        // Publication crosses blob-root and shard directories, including the
        // dedupe unlink path, so both directory entries must be durable.
        if (c.fsync(store.root_fd) != 0) return pathError();
        try store.fire(.directory_fsync);
        return .{ .digest = digest, .length = total, .deduplicated = deduplicated };
    }

    pub fn verify(store: *BlobStore, digest: BlobDigest, expected_length: u64) Error!VerifyResult {
        return store.streamVerified(digest, expected_length, null);
    }

    /// A non-null sink receives only a verified private snapshot. This closes
    /// the userspace verification/delivery race; it is not a hostile-kernel
    /// integrity claim.
    pub fn streamVerified(store: *BlobStore, digest: BlobDigest, expected_length: u64, sink: ?StreamSink) Error!VerifyResult {
        lock(&store.mutex);
        defer store.mutex.unlock();
        return store.streamVerifiedUnlocked(digest, expected_length, sink);
    }

    fn streamVerifiedUnlocked(store: *BlobStore, digest: BlobDigest, expected_length: u64, sink: ?StreamSink) Error!VerifyResult {
        if (expected_length > std.math.maxInt(i64)) return .{ .gap = .corrupt };
        const names = openShard(store.root_fd, digest, false) catch |err| return if (err == error.OpenFailed) .{ .gap = .missing } else err;
        defer _ = c.close(names.fd);
        const fd = c.openat(names.fd, &names.file_name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (fd < 0) return if (errno() == c.ENOENT) .{ .gap = .missing } else .{ .gap = .corrupt };
        defer _ = c.close(fd);
        validateFd(fd, false, true) catch return .{ .gap = .corrupt };
        const target = sink orelse {
            verifyOpenFile(fd, digest, expected_length) catch return .{ .gap = .corrupt };
            return .verified;
        };

        const spool_fd = try store.createUnlinkedSpool();
        defer _ = c.close(spool_fd);
        var hash = std.crypto.hash.Blake3.init(.{});
        var total: u64 = 0;
        var buffer: [io_buffer_bytes]u8 = undefined;
        defer @memset(&buffer, 0);
        while (true) {
            const count = c.read(fd, &buffer, buffer.len);
            if (count < 0) return pathError();
            if (count == 0) break;
            const amount: usize = @intCast(count);
            if (amount > expected_length -| total) return .{ .gap = .corrupt };
            try writeExact(spool_fd, buffer[0..amount]);
            hash.update(buffer[0..amount]);
            total += amount;
        }
        var actual: [digest_bytes]u8 = undefined;
        defer @memset(&actual, 0);
        hash.final(&actual);
        if (total != expected_length or !std.mem.eql(u8, &actual, &digest.bytes)) return .{ .gap = .corrupt };
        if (c.lseek(spool_fd, 0, c.SEEK_SET) != 0) return error.OpenFailed;
        if (store.snapshot_hook) |hook| hook.run_fn(hook.context);
        while (true) {
            const count = c.read(spool_fd, &buffer, buffer.len);
            if (count < 0) return pathError();
            if (count == 0) break;
            try target.write_fn(target.context, buffer[0..@intCast(count)]);
        }
        return .verified;
    }

    pub fn remove(store: *BlobStore, digest: BlobDigest) Error!bool {
        lock(&store.mutex);
        defer store.mutex.unlock();
        return store.removeUnlocked(digest);
    }

    fn removeUnlocked(store: *BlobStore, digest: BlobDigest) Error!bool {
        const names = openShard(store.root_fd, digest, false) catch |err| return if (err == error.OpenFailed) false else err;
        defer _ = c.close(names.fd);
        if (c.unlinkat(names.fd, &names.file_name, 0) != 0) return if (errno() == c.ENOENT) false else pathError();
        if (c.fsync(names.fd) != 0) return pathError();
        return true;
    }

    fn createUnlinkedSpool(store: *BlobStore) Error!c_int {
        var name: [40:0]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 16) : (attempts += 1) {
            var random: [16]u8 = undefined;
            defer @memset(&random, 0);
            arc4random_buf(&random, random.len);
            const hex = formatRandom(random);
            @memcpy(name[0..7], ".spool-");
            @memcpy(name[7..39], &hex);
            name[39] = 0;
            const fd = c.openat(store.root_fd, &name, c.O_RDWR | c.O_CREAT | c.O_EXCL | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
            if (fd < 0) {
                if (errno() == c.EEXIST) continue;
                return pathError();
            }
            if (c.unlinkat(store.root_fd, &name, 0) != 0) {
                _ = c.close(fd);
                return pathError();
            }
            validateFd(fd, false, false) catch |err| {
                _ = c.close(fd);
                return err;
            };
            return fd;
        }
        return error.OpenFailed;
    }

    /// Exclusive-owner startup recovery. `entry_budget` counts every directory
    /// entry examined, including unrelated names, so adversarial debris is bounded.
    pub fn recoverTemps(store: *BlobStore, now_seconds: i64, grace_seconds: u64, entry_budget: usize) Error!usize {
        lock(&store.mutex);
        defer store.mutex.unlock();
        if (entry_budget == 0) return 0;
        const duplicate = c.dup(store.root_fd);
        if (duplicate < 0) return pathError();
        const directory = c.fdopendir(duplicate) orelse {
            _ = c.close(duplicate);
            return pathError();
        };
        defer _ = c.closedir(directory);
        var removed: usize = 0;
        var examined: usize = 0;
        while (examined < entry_budget) {
            const entry = c.readdir(directory) orelse break;
            examined += 1;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            if (!std.mem.startsWith(u8, name, ".tmp-")) continue;
            var status: c.struct_stat = undefined;
            if (c.fstatat(store.root_fd, @ptrCast(&entry.*.d_name), &status, c.AT_SYMLINK_NOFOLLOW) != 0) continue;
            if ((status.st_mode & c.S_IFMT) != c.S_IFREG or status.st_uid != c.geteuid() or status.st_nlink != 1) continue;
            const age = if (now_seconds > status.st_mtimespec.tv_sec) @as(u64, @intCast(now_seconds - status.st_mtimespec.tv_sec)) else 0;
            if (age >= grace_seconds and c.unlinkat(store.root_fd, @ptrCast(&entry.*.d_name), 0) == 0) removed += 1;
        }
        if (removed != 0 and c.fsync(store.root_fd) != 0) return pathError();
        return removed;
    }

    fn fire(store: *BlobStore, point: Failpoint) Error!void {
        if (store.failpoint == point) {
            store.failpoint = .none;
            return error.InjectedFailure;
        }
    }
};

const BytesSource = struct {
    bytes: []const u8,
    offset: usize = 0,
    fn read(raw: *anyopaque, out: []u8) Error!usize {
        const self: *BytesSource = @ptrCast(@alignCast(raw));
        const count = @min(out.len, self.bytes.len - self.offset);
        @memcpy(out[0..count], self.bytes[self.offset..][0..count]);
        self.offset += count;
        return count;
    }
};

const Shard = struct { fd: c_int, file_name: [63:0]u8, created: bool };

fn openShard(root_fd: c_int, digest: BlobDigest, create: bool) Error!Shard {
    const hex = digest.format();
    var shard_name: [3:0]u8 = .{ hex[0], hex[1], 0 };
    var created = false;
    if (create) {
        if (c.mkdirat(root_fd, &shard_name, 0o700) != 0) {
            if (errno() != c.EEXIST) return pathError();
        } else created = true;
    }
    const fd = c.openat(root_fd, &shard_name, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return pathError();
    errdefer _ = c.close(fd);
    try validateFd(fd, true, false);
    var file_name: [63:0]u8 = undefined;
    @memcpy(file_name[0..62], hex[2..]);
    file_name[62] = 0;
    return .{ .fd = fd, .file_name = file_name, .created = created };
}

fn verifyFile(dir_fd: c_int, name: [*:0]const u8, digest: BlobDigest, length: u64) Error!void {
    const fd = c.openat(dir_fd, name, c.O_RDONLY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return pathError();
    defer _ = c.close(fd);
    try validateFd(fd, false, true);
    try verifyOpenFile(fd, digest, length);
}

fn verifyOpenFile(fd: c_int, digest: BlobDigest, length: u64) Error!void {
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0 or status.st_size < 0 or @as(u64, @intCast(status.st_size)) != length) return error.IntegrityFailure;
    var hash = std.crypto.hash.Blake3.init(.{});
    var buffer: [io_buffer_bytes]u8 = undefined;
    while (true) {
        const count = c.read(fd, &buffer, buffer.len);
        if (count < 0) return pathError();
        if (count == 0) break;
        hash.update(buffer[0..@intCast(count)]);
    }
    var actual: [digest_bytes]u8 = undefined;
    hash.final(&actual);
    if (!std.mem.eql(u8, &actual, &digest.bytes)) return error.IntegrityFailure;
}

fn writeExact(fd: c_int, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count <= 0) return pathError();
        offset += @intCast(count);
    }
}

pub fn openAbsoluteDirectory(path: []const u8, create_final: bool) Error!c_int {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidStatePath;
    var fd = c.open("/", c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (fd < 0) return pathError();
    errdefer _ = c.close(fd);
    var iterator = std.mem.tokenizeScalar(u8, path[1..], '/');
    while (iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidStatePath;
        const name = std.heap.c_allocator.dupeZ(u8, component) catch return error.OpenFailed;
        defer std.heap.c_allocator.free(name);
        var next = c.openat(fd, name.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (next < 0 and create_final and iterator.peek() == null and errno() == c.ENOENT) {
            if (c.mkdirat(fd, name.ptr, 0o700) != 0) return pathError();
            if (c.fsync(fd) != 0) return pathError();
            next = c.openat(fd, name.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        }
        if (next < 0) {
            var status: c.struct_stat = undefined;
            if (c.fstatat(fd, name.ptr, &status, c.AT_SYMLINK_NOFOLLOW) == 0 and (status.st_mode & c.S_IFMT) == c.S_IFLNK)
                return error.UnsafeStatePath;
            return pathError();
        }
        _ = c.close(fd);
        fd = next;
    }
    try validateFd(fd, true, false);
    return fd;
}

fn validateFd(fd: c_int, directory: bool, require_single_link: bool) Error!void {
    var status: c.struct_stat = undefined;
    if (c.fstat(fd, &status) != 0) return pathError();
    const expected: c_uint = if (directory) c.S_IFDIR else c.S_IFREG;
    if ((status.st_mode & c.S_IFMT) != expected) return error.UnsafeStatePath;
    if (status.st_uid != c.geteuid()) return error.PermissionDenied;
    if ((status.st_mode & 0o077) != 0) return error.PermissionDenied;
    if (require_single_link and status.st_nlink != 1) return error.IntegrityFailure;
}

fn formatRandom(bytes: [16]u8) [32]u8 {
    const alphabet = "0123456789abcdef";
    var out: [32]u8 = undefined;
    for (bytes, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 15];
    }
    return out;
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => null,
    };
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
