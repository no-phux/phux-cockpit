//! Native-sdk socket extension for phux length framing.
//!
//! This worker owns only the socket. `PhuxClient` remains on the UI thread.
//! Complete frames cross `Bridge`; only a one-byte wake crosses ChannelHandle.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const transport = @import("phux_transport.zig");
const posix = std.posix;

pub const Endpoint = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    unix: []const u8,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    bridge: *transport.Bridge,
    handle: native_sdk.ChannelHandle,
    endpoint: Endpoint,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fd: std.atomic.Value(posix.fd_t) = std.atomic.Value(posix.fd_t).init(-1),

    pub fn start(
        gpa: std.mem.Allocator,
        bridge: *transport.Bridge,
        handle: native_sdk.ChannelHandle,
        endpoint: Endpoint,
    ) !*Worker {
        const worker = try gpa.create(Worker);
        errdefer gpa.destroy(worker);
        worker.* = .{ .gpa = gpa, .bridge = bridge, .handle = handle, .endpoint = endpoint };
        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    /// Shutdown precedes join, so a blocked read cannot outlive its queues or
    /// owning UI client. No wake callback is possible after this returns.
    pub fn stop(worker: *Worker) void {
        worker.stopping.store(true, .release);
        const fd = worker.fd.load(.acquire);
        if (fd >= 0) posix.shutdown(fd, .both) catch {};
        if (worker.thread) |thread| thread.join();
        worker.gpa.destroy(worker);
    }

    fn run(worker: *Worker) void {
        const fd = connect(worker.endpoint) catch {
            worker.bridge.incoming.markDisconnected(.socket_lost);
            worker.wake();
            return;
        };
        configureSocket(fd) catch {
            posix.close(fd);
            worker.bridge.incoming.markDisconnected(.socket_lost);
            worker.wake();
            return;
        };
        worker.fd.store(fd, .release);
        defer {
            _ = worker.fd.swap(-1, .acq_rel);
            posix.close(fd);
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

fn connect(endpoint: Endpoint) !posix.fd_t {
    return switch (endpoint) {
        .tcp => |tcp| connectTcp(tcp.host, tcp.port),
        .unix => |path| connectUnix(path),
    };
}

fn connectTcp(host: []const u8, port: u16) !posix.fd_t {
    const address = try std.net.Address.resolveIp(host, port);
    const fd = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    errdefer posix.close(fd);
    try posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
}

fn connectUnix(path: []const u8) !posix.fd_t {
    const address = try std.net.Address.initUnix(path);
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &address.any, address.getOsSockLen());
    return fd;
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
    defer posix.close(sockets[0]);
    posix.close(sockets[1]);
    try configureSocket(sockets[0]);
    try std.testing.expect(!writeExact(sockets[0], "terminal reply"));
}

test "final complete frame remains readable when peer has shut down" {
    const sockets = try socketPair();
    defer posix.close(sockets[0]);
    defer posix.close(sockets[1]);
    const frame = [_]u8{ 0, 0, 0, 1, 0x42 };
    try std.testing.expect(writeExact(sockets[0], &frame));
    try posix.shutdown(sockets[0], .send);

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
