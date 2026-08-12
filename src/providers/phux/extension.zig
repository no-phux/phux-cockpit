//! Native-sdk socket extension for phux length framing.
//!
//! This worker owns only the socket. Client state and client FFI remain on the
//! deterministic UI thread. Complete frames cross `Bridge`; only a one-byte
//! wake crosses `ChannelHandle`.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const transport = @import("phux_transport");
const posix = std.posix;
const max_flush_batch: usize = 16;

/// Endpoint slices are borrowed and must remain alive until `Worker.stop` has
/// returned.
pub const Endpoint = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    unix: []const u8,
};

const max_resolved_addresses = 16;
const ResolvedAddresses = struct {
    items: [max_resolved_addresses]std.Io.net.IpAddress = undefined,
    len: usize = 0,
};

/// DNS is isolated because the platform resolver is blocking. This detached
/// context owns everything it reads and frees itself if cancellation wins.
const ResolveContext = struct {
    host: [std.Io.net.HostName.max_len:0]u8 = @splat(0),
    host_len: usize,
    port: u16,
    // 0 = resolving, 1 = complete, 2 = abandoned by the worker.
    state: std.atomic.Value(u8) = .init(0),
    result: ResolvedAddresses = .{},

    fn run(context: *ResolveContext) void {
        context.result = resolveBlocking(context.host[0..context.host_len :0], context.port);
        const previous = context.state.cmpxchgStrong(0, 1, .release, .acquire);
        if (previous == 2) std.heap.page_allocator.destroy(context);
    }
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    bridge: *transport.Bridge,
    handle: native_sdk.ChannelHandle,
    endpoint: Endpoint,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // The lock prevents a descriptor from being closed and reused between a
    // stop-side load and shutdown. It is held only for publish/shutdown/close.
    fd_mutex: std.atomic.Mutex = .unlocked,
    fd: posix.fd_t = -1,

    pub fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        bridge: *transport.Bridge,
        handle: native_sdk.ChannelHandle,
        endpoint: Endpoint,
    ) !*Worker {
        const worker = try gpa.create(Worker);
        errdefer gpa.destroy(worker);
        worker.* = .{ .gpa = gpa, .io = io, .bridge = bridge, .handle = handle, .endpoint = endpoint };
        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    /// Cancellation and socket shutdown precede join, so a blocked read,
    /// write, connect, or resolver wait cannot outlive the queues. Joining also
    /// guarantees that no channel post can occur after this method returns.
    pub fn stop(worker: *Worker) void {
        worker.stopping.store(true, .release);
        worker.lockFd();
        if (worker.fd >= 0) _ = std.c.shutdown(worker.fd, std.c.SHUT.RDWR);
        worker.unlockFd();
        if (worker.thread) |thread| thread.join();
        worker.gpa.destroy(worker);
    }

    fn lockFd(worker: *Worker) void {
        while (!worker.fd_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlockFd(worker: *Worker) void {
        worker.fd_mutex.unlock();
    }

    /// Publishes a newly opened descriptor unless cancellation already won.
    fn publishFd(worker: *Worker, fd: posix.fd_t) bool {
        worker.lockFd();
        defer worker.unlockFd();
        if (worker.stopping.load(.acquire)) return false;
        worker.fd = fd;
        return true;
    }

    fn closeFd(worker: *Worker, fd: posix.fd_t) void {
        worker.lockFd();
        defer worker.unlockFd();
        if (worker.fd == fd) worker.fd = -1;
        _ = std.c.close(fd);
    }

    fn run(worker: *Worker) void {
        const fd = connect(worker) catch {
            worker.disconnected(.socket_lost);
            return;
        };
        configureSocket(fd) catch {
            worker.closeFd(fd);
            worker.disconnected(.socket_lost);
            return;
        };
        defer {
            worker.closeFd(fd);
            worker.disconnected(.socket_lost);
        }

        var header: [4]u8 = undefined;
        while (!worker.stopping.load(.acquire)) {
            if (!flushOutgoing(worker, fd, null)) return;
            var poll_fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const timeout: i32 = if (worker.bridge.outgoing.hasPending()) 0 else 50;
            const ready = posix.poll(&poll_fds, timeout) catch return;
            if (ready == 0) continue;
            if (poll_fds[0].revents & posix.POLL.IN == 0) {
                if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return;
                continue;
            }

            var frame_started: ?posix.timespec = monotonicTime() orelse return;
            if (!readExact(worker, fd, &header, &frame_started)) return;
            const len: usize = std.mem.readInt(u32, &header, .big);
            if (len == 0 or len > transport.max_frame_bytes - header.len) {
                worker.bridge.incoming.markDisconnected(.oversized_frame);
                worker.wake();
                return;
            }

            const frame = worker.gpa.alloc(u8, header.len + len) catch {
                worker.bridge.incoming.markDisconnected(.queue_overflow);
                worker.wake();
                return;
            };
            @memcpy(frame[0..header.len], &header);
            if (!readExact(worker, fd, frame[header.len..], &frame_started)) {
                worker.gpa.free(frame);
                return;
            }
            if (!worker.bridge.incoming.stageOwned(frame)) {
                worker.wake();
                return;
            }
            worker.wake();
        }
        worker.bridge.incoming.markDisconnected(.stopped);
    }

    fn disconnected(worker: *Worker, reason: transport.DisconnectReason) void {
        if (worker.stopping.load(.acquire)) return;
        worker.bridge.incoming.markDisconnected(reason);
        worker.wake();
    }

    fn wake(worker: *Worker) void {
        if (worker.stopping.load(.acquire)) return;
        _ = worker.handle.post(&transport.wake_payload);
    }
};

fn flushOutgoing(worker: *Worker, fd: posix.fd_t, frame_started: ?posix.timespec) bool {
    for (0..max_flush_batch) |_| {
        const frame = worker.bridge.outgoing.take() orelse break;
        defer worker.bridge.outgoing.release(frame);
        if (frame.len < 5 or frame.len > transport.max_frame_bytes) return false;
        var header: [4]u8 = undefined;
        @memcpy(header[0..], frame[0..4]);
        const declared = std.mem.readInt(u32, &header, .big);
        if (declared == 0 or @as(usize, declared) != frame.len - 4) return false;
        if (!writeExact(worker, fd, frame, frame_started)) return false;
    }
    if (worker.bridge.outgoing.takeDisconnect() != null) return false;
    return true;
}

fn readExact(worker: *Worker, fd: posix.fd_t, output: []u8, frame_started: *?posix.timespec) bool {
    var offset: usize = 0;
    while (offset < output.len) {
        if (frame_started.*) |value| {
            const now = monotonicTime() orelse return false;
            if (elapsedNanos(value, now) >= 5 * std.time.ns_per_s) return false;
        }
        if (worker.stopping.load(.acquire)) return false;
        // Replies are flushed between partial reads so a peer waiting for a
        // response cannot deadlock a large incoming frame.
        if (!flushOutgoing(worker, fd, frame_started.*)) return false;
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&poll_fds, 50) catch return false;
        if (ready == 0) continue;
        if (poll_fds[0].revents & posix.POLL.IN == 0) {
            if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return false;
            continue;
        }
        const count = posix.read(fd, output[offset..]) catch return false;
        if (count == 0) return false;
        offset += count;
        if (frame_started.* == null) frame_started.* = monotonicTime() orelse return false;
    }
    return true;
}

/// Send `input` in full within one second, or give up and report failure.
///
/// The one-second budget is this function's contract with its callers: a peer
/// that has stopped reading must not be able to park the extension worker on a
/// single frame. That budget can only be evaluated BETWEEN send() calls, so the
/// contract holds only if send() itself never blocks.
///
/// MSG.DONTWAIT does not buy that on macOS. Darwin ignores MSG_DONTWAIT on an
/// AF_UNIX socket that is blocking at the descriptor level; only O_NONBLOCK
/// makes the kernel return EAGAIN. Because the flag is present as a decl, the
/// comptime @hasDecl guard below compiles happily and the code reads as though
/// it were non-blocking while the syscall sleeps indefinitely. That is exactly
/// how the deadline came to be unreachable.
///
/// Measured by scripts/measure-send-blocking.c (SNDBUF 4096, 16 MiB payload,
/// peer never reads) on macOS 25.5 / arm64:
///
///   blocking fd + MSG_DONTWAIT   still inside send() when a 5s alarm fired
///   O_NONBLOCK fd                EAGAIN after 0.000s, 4096 bytes written
///   blocking fd + SO_SNDTIMEO=1s EAGAIN after 2.004s
///
/// So SO_SNDTIMEO is rejected as the fix: Darwin overshoots it by a consistent
/// factor of two (250ms -> 0.503s, 500ms -> 1.004s, 1s -> 2.004s, 2s -> 4.004s),
/// which would quietly turn this one-second budget into a two-second one.
/// O_NONBLOCK is exact, so the descriptor is switched for the duration of the
/// write and put back the way it was found.
///
/// Restoring matters as much as setting. connectAddress deliberately hands back
/// a BLOCKING descriptor, and readExact treats any read error as a dead
/// connection -- so leaking O_NONBLOCK out of this function would let a benign
/// EAGAIN on the read side tear down a healthy session.
fn writeExact(worker: ?*Worker, fd: posix.fd_t, input: []const u8, frame_started: ?posix.timespec) bool {
    const was_nonblocking = isNonblocking(fd) catch return false;
    if (!was_nonblocking) setNonblocking(fd, true) catch return false;
    defer if (!was_nonblocking) {
        setNonblocking(fd, false) catch {};
    };

    var offset: usize = 0;
    const started = monotonicTime() orelse return false;
    while (offset < input.len) {
        const now = monotonicTime() orelse return false;
        const elapsed_ns = elapsedNanos(started, now);
        if (elapsed_ns >= std.time.ns_per_s) return false;
        if (frame_started) |value| {
            if (elapsedNanos(value, now) >= 5 * std.time.ns_per_s) return false;
        }
        if (worker) |value| {
            if (value.stopping.load(.acquire)) return false;
        }
        const flags: u32 = (if (comptime @hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0) |
            (if (comptime @hasDecl(posix.MSG, "DONTWAIT")) posix.MSG.DONTWAIT else 0);
        const rc = std.c.send(fd, input[offset..].ptr, input.len - offset, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                offset += @intCast(rc);
            },
            .INTR => continue,
            .AGAIN => {
                var poll_fds = [_]posix.pollfd{.{
                    .fd = fd,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                }};
                const ready = posix.poll(&poll_fds, 50) catch return false;
                if (ready == 0) continue;
                if (poll_fds[0].revents & posix.POLL.OUT == 0) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn monotonicTime() ?posix.timespec {
    var value: posix.timespec = undefined;
    return switch (posix.errno(posix.system.clock_gettime(.MONOTONIC, &value))) {
        .SUCCESS => value,
        else => null,
    };
}

fn elapsedNanos(started: posix.timespec, now: posix.timespec) i128 {
    return (@as(i128, now.sec) - @as(i128, started.sec)) * std.time.ns_per_s +
        (@as(i128, now.nsec) - @as(i128, started.nsec));
}

fn configureSocket(fd: posix.fd_t) !void {
    // Linux supports per-send MSG_NOSIGNAL; Darwin uses SO_NOSIGPIPE. Applying
    // both conditionally avoids changing process-global SIGPIPE disposition.
    if (comptime @hasDecl(posix.SO, "NOSIGPIPE")) {
        const enabled: c_int = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, std.mem.asBytes(&enabled));
    }
}

fn connect(worker: *Worker) !posix.fd_t {
    return switch (worker.endpoint) {
        .tcp => |tcp| connectTcp(worker, tcp.host, tcp.port),
        .unix => |path| connectUnix(worker, path),
    };
}

fn connectTcp(worker: *Worker, host: []const u8, port: u16) !posix.fd_t {
    if (port == 0) return error.InvalidPort;
    if (std.Io.net.IpAddress.parse(host, port)) |address| {
        return connectIpAddress(worker, address);
    } else |_| {}

    const addresses = try resolveHost(worker, host, port);
    var last_error: ?anyerror = null;
    for (addresses.items[0..addresses.len]) |address| {
        return connectIpAddress(worker, address) catch |err| {
            if (worker.stopping.load(.acquire)) return error.Canceled;
            last_error = err;
            continue;
        };
    }
    return last_error orelse error.UnknownHostName;
}

fn connectIpAddress(worker: *Worker, address: std.Io.net.IpAddress) !posix.fd_t {
    return switch (address) {
        .ip4 => |ip4| {
            var socket_address: posix.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            };
            return connectAddress(
                worker,
                @ptrCast(&socket_address),
                @sizeOf(@TypeOf(socket_address)),
                posix.AF.INET,
            );
        },
        .ip6 => |ip6| {
            var socket_address: posix.sockaddr.in6 = .{
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = ip6.flow,
                .addr = ip6.bytes,
                .scope_id = ip6.interface.index,
            };
            return connectAddress(
                worker,
                @ptrCast(&socket_address),
                @sizeOf(@TypeOf(socket_address)),
                posix.AF.INET6,
            );
        },
    };
}

fn resolveHost(worker: *Worker, host: []const u8, port: u16) !ResolvedAddresses {
    _ = try std.Io.net.HostName.init(host);
    const context = try std.heap.page_allocator.create(ResolveContext);
    context.* = .{ .host_len = host.len, .port = port };
    @memcpy(context.host[0..host.len], host);
    const thread = std.Thread.spawn(.{}, ResolveContext.run, .{context}) catch |err| {
        std.heap.page_allocator.destroy(context);
        return err;
    };
    thread.detach();

    while (true) {
        if (context.state.load(.acquire) == 1) {
            const result = context.result;
            std.heap.page_allocator.destroy(context);
            if (result.len == 0) return error.UnknownHostName;
            return result;
        }
        if (worker.stopping.load(.acquire)) {
            const previous = context.state.cmpxchgStrong(0, 2, .release, .acquire);
            if (previous == 1) std.heap.page_allocator.destroy(context);
            return error.Canceled;
        }
        std.Io.sleep(worker.io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
}

fn resolveBlocking(host: [:0]const u8, port: u16) ResolvedAddresses {
    var output: ResolvedAddresses = .{};
    var port_buffer: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buffer, "{d}", .{port}) catch return output;
    const hints: posix.addrinfo = .{
        .flags = .{ .NUMERICSERV = true },
        .family = posix.AF.UNSPEC,
        .socktype = posix.SOCK.STREAM,
        .protocol = posix.IPPROTO.TCP,
        .canonname = null,
        .addr = null,
        .addrlen = 0,
        .next = null,
    };
    var result: ?*posix.addrinfo = null;
    if (posix.system.getaddrinfo(host.ptr, port_z.ptr, &hints, &result) != @as(posix.system.EAI, @enumFromInt(0)))
        return output;
    defer if (result) |head| posix.system.freeaddrinfo(head);
    var cursor = result;
    while (cursor) |info| : (cursor = info.next) {
        if (output.len == output.items.len) break;
        const address = info.addr orelse continue;
        if (address.family != posix.AF.INET and address.family != posix.AF.INET6) continue;
        const wrapped: *const std.Io.Threaded.PosixAddress = @alignCast(@fieldParentPtr("any", address));
        output.items[output.len] = std.Io.Threaded.addressFromPosix(wrapped);
        output.len += 1;
    }
    return output;
}

fn connectUnix(worker: *Worker, path: []const u8) !posix.fd_t {
    if (path.len == 0 or path.len >= @sizeOf(@FieldType(posix.sockaddr.un, "path"))) return error.InvalidUnixPath;
    var socket_address = std.mem.zeroes(posix.sockaddr.un);
    socket_address.len = @intCast(@offsetOf(posix.sockaddr.un, "path") + path.len + 1);
    socket_address.family = posix.AF.UNIX;
    @memcpy(socket_address.path[0..path.len], path);
    return connectAddress(
        worker,
        @ptrCast(&socket_address),
        socket_address.len,
        posix.AF.UNIX,
    );
}

fn connectAddress(
    worker: *Worker,
    address: *const posix.sockaddr,
    address_len: posix.socklen_t,
    family: posix.sa_family_t,
) !posix.fd_t {
    if (worker.stopping.load(.acquire)) return error.Canceled;
    const fd = std.c.socket(@intCast(family), posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketOpenFailed;
    if (!worker.publishFd(fd)) {
        _ = std.c.close(fd);
        return error.Canceled;
    }
    errdefer worker.closeFd(fd);

    try setNonblocking(fd, true);
    const rc = std.c.connect(fd, address, address_len);
    if (rc != 0 and posix.errno(rc) != .INPROGRESS) return error.ConnectFailed;
    if (rc != 0) try waitConnected(fd, &worker.stopping);
    try setNonblocking(fd, false);
    return fd;
}

pub fn waitConnected(fd: posix.fd_t, stopping: *const std.atomic.Value(bool)) !void {
    while (!stopping.load(.acquire)) {
        var poll_fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        const ready = try posix.poll(&poll_fds, 50);
        if (ready == 0) continue;
        var socket_error: c_int = 0;
        var error_len: posix.socklen_t = @sizeOf(c_int);
        if (std.c.getsockopt(fd, posix.SOL.SOCKET, posix.SO.ERROR, &socket_error, &error_len) != 0)
            return error.ConnectFailed;
        if (socket_error != 0) return error.ConnectFailed;
        return;
    }
    return error.Canceled;
}

/// Read back what setNonblocking would set, so writeExact can leave a
/// descriptor exactly as it found it rather than assuming it arrived blocking.
fn isNonblocking(fd: posix.fd_t) !bool {
    const raw_flags = std.c.fcntl(fd, posix.F.GETFL);
    if (raw_flags < 0) return error.FcntlFailed;
    const flags: posix.O = @bitCast(@as(u32, @intCast(raw_flags)));
    return flags.NONBLOCK;
}

pub fn setNonblocking(fd: posix.fd_t, enabled: bool) !void {
    const raw_flags = std.c.fcntl(fd, posix.F.GETFL);
    if (raw_flags < 0) return error.FcntlFailed;
    var flags: posix.O = @bitCast(@as(u32, @intCast(raw_flags)));
    flags.NONBLOCK = enabled;
    if (std.c.fcntl(fd, posix.F.SETFL, @as(c_int, @bitCast(flags))) < 0) return error.FcntlFailed;
}

fn socketPair() ![2]posix.fd_t {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var sockets: [2]posix.fd_t = undefined;
    if (std.c.socketpair(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0, &sockets) != 0)
        return error.SocketPairFailed;
    return sockets;
}

test "write after peer teardown reports failure without process signal" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    try configureSocket(sockets[0]);
    _ = std.c.close(sockets[1]);
    try std.testing.expect(!writeExact(null, sockets[0], "terminal reply", null));
}

test "a non-reading peer cannot hold one frame writer forever" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const small_buffer: c_int = 4096;
    try posix.setsockopt(sockets[0], posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&small_buffer));
    const payload = try std.testing.allocator.alloc(u8, 16 * 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    // Nobody ever reads sockets[1], so this write can never complete. Until
    // writeExact forced O_NONBLOCK, this call sat inside send() indefinitely
    // and took the whole test binary with it: rooting extension.zig reported
    // "5 pass, 1 crash" only after the run was killed at 180 seconds.
    const started = monotonicTime() orelse return error.SkipZigTest;
    try std.testing.expect(!writeExact(null, sockets[0], payload, null));
    const elapsed_ns = elapsedNanos(started, monotonicTime() orelse return error.SkipZigTest);

    // Both bounds carry weight. The upper bound is the invariant this test is
    // named for -- the budget is one second plus at most one 50ms poll, so
    // crossing three seconds means the deadline has become unreachable again.
    // The lower bound guards the opposite regression: a writeExact that treated
    // EAGAIN as fatal would return false immediately, satisfy the assertion
    // above, and silently fail frames that were merely waiting for buffer.
    try std.testing.expect(elapsed_ns >= 900 * std.time.ns_per_ms);
    try std.testing.expect(elapsed_ns < 3 * std.time.ns_per_s);
}

test "writeExact restores the blocking mode it was handed" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);

    // connectAddress deliberately hands framed IO a BLOCKING descriptor, and
    // readExact treats any read error as a dead connection. O_NONBLOCK leaking
    // out of writeExact would therefore let a benign EAGAIN on the read side
    // tear down a perfectly healthy session.
    try std.testing.expectEqual(false, try isNonblocking(sockets[0]));
    try std.testing.expect(writeExact(null, sockets[0], "frame", null));
    try std.testing.expectEqual(false, try isNonblocking(sockets[0]));

    // A descriptor that arrives non-blocking has to stay non-blocking; the
    // restore must put back what was there, not a fixed assumption.
    try setNonblocking(sockets[0], true);
    try std.testing.expect(writeExact(null, sockets[0], "frame", null));
    try std.testing.expectEqual(true, try isNonblocking(sockets[0]));
}

test "final complete frame remains readable when peer has shut down" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const frame = [_]u8{ 0, 0, 0, 1, 0x42 };
    try std.testing.expect(writeExact(null, sockets[0], &frame, null));
    try std.testing.expectEqual(@as(c_int, 0), std.c.shutdown(sockets[0], std.c.SHUT.WR));

    var poll_fds = [_]posix.pollfd{.{
        .fd = sockets[1],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try posix.poll(&poll_fds, 1000));
    try std.testing.expect(poll_fds[0].revents & posix.POLL.IN != 0);

    var received: [frame.len]u8 = undefined;
    var offset: usize = 0;
    while (offset < received.len) {
        const count = try posix.read(sockets[1], received[offset..]);
        try std.testing.expect(count > 0);
        offset += count;
    }
    try std.testing.expectEqualSlices(u8, &frame, &received);
}

test "connect wait observes cancellation without a blocking syscall" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const stopping = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, waitConnected(sockets[0], &stopping));
}

test "nonblocking connect mode can be restored for framed IO" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    try setNonblocking(sockets[0], true);
    try setNonblocking(sockets[0], false);
    try std.testing.expect(writeExact(null, sockets[0], "frame", null));
}

test "localhost resolves without requiring a numeric TCP address" {
    const addresses = resolveBlocking("localhost", 4321);
    try std.testing.expect(addresses.len > 0);
    for (addresses.items[0..addresses.len]) |address|
        try std.testing.expectEqual(@as(u16, 4321), address.getPort());
}
