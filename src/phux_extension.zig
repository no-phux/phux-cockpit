//! Native-sdk socket extension for phux length framing.
//!
//! This worker owns only the socket. `PhuxClient` remains on the UI thread.
//! Complete frames cross `Bridge`; only a one-byte wake crosses ChannelHandle.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const transport = @import("phux_transport");
const posix = std.posix;

pub const Endpoint = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    unix: []const u8,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    bridge: *transport.Bridge,
    handle: native_sdk.ChannelHandle,
    endpoint: Endpoint,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fd: std.atomic.Value(posix.fd_t) = std.atomic.Value(posix.fd_t).init(-1),

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

    /// Shutdown precedes join, so a blocked read cannot outlive its queues or
    /// owning UI client. No wake callback is possible after this returns.
    pub fn stop(worker: *Worker) void {
        worker.stopping.store(true, .release);
        const fd = worker.fd.load(.acquire);
        if (fd >= 0) _ = std.c.shutdown(fd, std.c.SHUT.RDWR);
        if (worker.thread) |thread| thread.join();
        worker.gpa.destroy(worker);
    }

    fn run(worker: *Worker) void {
        const fd = connect(worker) catch {
            if (!worker.stopping.load(.acquire)) {
                worker.bridge.incoming.markDisconnected(.socket_lost);
                worker.wake();
            }
            return;
        };
        configureSocket(fd) catch {
            _ = worker.fd.swap(-1, .acq_rel);
            _ = std.c.close(fd);
            if (!worker.stopping.load(.acquire)) {
                worker.bridge.incoming.markDisconnected(.socket_lost);
                worker.wake();
            }
            return;
        };
        defer {
            _ = worker.fd.swap(-1, .acq_rel);
            _ = std.c.close(fd);
            if (!worker.stopping.load(.acquire)) {
                worker.bridge.incoming.markDisconnected(.socket_lost);
                worker.wake();
            }
        }

        var header: [4]u8 = undefined;
        while (!worker.stopping.load(.acquire)) {
            if (!flushOutgoing(worker, fd)) return;
            var poll_fds = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = posix.poll(&poll_fds, 50) catch return;
            if (ready == 0) continue;
            if (poll_fds[0].revents & posix.POLL.IN == 0) {
                if (poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0) return;
                continue;
            }
            if (!readExact(worker, fd, &header)) return;
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
            if (!readExact(worker, fd, frame[header.len..])) {
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

    fn wake(worker: *Worker) void {
        _ = worker.handle.post(&transport.wake_payload);
    }
};

fn flushOutgoing(worker: *Worker, fd: posix.fd_t) bool {
    while (worker.bridge.outgoing.take()) |frame| {
        defer worker.bridge.outgoing.release(frame);
        if (frame.len < 5 or frame.len > transport.max_frame_bytes) return false;
        var header: [4]u8 = undefined;
        @memcpy(header[0..], frame[0..4]);
        const declared = std.mem.readInt(u32, &header, .big);
        if (declared == 0 or @as(usize, declared) != frame.len - 4) return false;
        if (!writeExact(fd, frame)) return false;
    }
    if (worker.bridge.outgoing.takeDisconnect() != null) return false;
    return true;
}

fn readExact(worker: *Worker, fd: posix.fd_t, output: []u8) bool {
    var offset: usize = 0;
    while (offset < output.len) {
        if (worker.stopping.load(.acquire)) return false;
        if (!flushOutgoing(worker, fd)) return false;
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
    }
    return true;
}

fn writeExact(fd: posix.fd_t, input: []const u8) bool {
    var offset: usize = 0;
    while (offset < input.len) {
        const flags: u32 = if (comptime @hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0;
        const rc = std.c.send(fd, input[offset..].ptr, input.len - offset, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                offset += @intCast(rc);
            },
            .INTR => continue,
            else => return false,
        }
    }
    return true;
}

fn configureSocket(fd: posix.fd_t) !void {
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
    const address = try std.Io.net.IpAddress.parse(host, port);
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
                .scope_id = 0,
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
    const fd = std.c.socket(@intCast(family), posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketOpenFailed;
    worker.fd.store(fd, .release);
    errdefer {
        _ = worker.fd.swap(-1, .acq_rel);
        _ = std.c.close(fd);
    }
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
    try std.testing.expect(!writeExact(sockets[0], "terminal reply"));
}

test "final complete frame remains readable when peer has shut down" {
    const sockets = try socketPair();
    defer _ = std.c.close(sockets[0]);
    defer _ = std.c.close(sockets[1]);
    const frame = [_]u8{ 0, 0, 0, 1, 0x42 };
    try std.testing.expect(writeExact(sockets[0], &frame));
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
    try std.testing.expect(writeExact(sockets[0], "frame"));
}
