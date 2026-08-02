//! Thread-safe socket/readiness boundary for the phux host.
//!
//! The native-sdk extension stages complete frames here and posts only
//! [`wake_payload`]. The UI thread owns and calls `PhuxClient` while draining.

const std = @import("std");

/// Entire native-sdk external-channel payload; frames bypass that channel.
pub const wake_payload = [_]u8{1};
/// Protocol hard bound for one complete frame, including its 4-byte prefix.
pub const max_frame_bytes: usize = 16 * 1024 * 1024 + 4;

pub const max_queued_frames: usize = 128;
pub const max_queued_bytes: usize = 32 * 1024 * 1024;

pub const DisconnectReason = enum { socket_lost, oversized_frame, queue_overflow, stopped };
/// Explicit live/harness connection configuration.
pub const Config = struct {
    host: []const u8,
    port: u16,
    session: []const u8,
    cols: u16 = 80,
    rows: u16 = 24,

    /// Parse deterministic `host:port/session` syntax.
    pub fn parse(spec: []const u8) error{InvalidConfig}!Config {
        const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.InvalidConfig;
        const endpoint = spec[0..slash];
        const colon = std.mem.lastIndexOfScalar(u8, endpoint, ':') orelse return error.InvalidConfig;
        const host = endpoint[0..colon];
        const session = spec[slash + 1 ..];
        if (host.len == 0 or session.len == 0) return error.InvalidConfig;
        const port = std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10) catch return error.InvalidConfig;
        if (port == 0) return error.InvalidConfig;
        return .{ .host = host, .port = port, .session = session };
    }
};

/// Owned frame queue crossing between the socket extension and UI owner.
pub const FrameQueue = struct {
    gpa: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    pending_bytes: usize = 0,
    disconnect: ?DisconnectReason = null,
    frames: std.ArrayListUnmanaged([]u8) = .empty,
    read_index: usize = 0,

    pub fn init(gpa: std.mem.Allocator) FrameQueue {
        return .{ .gpa = gpa };
    }

    pub fn deinit(queue: *FrameQueue) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        for (queue.frames.items[queue.read_index..]) |frame| queue.gpa.free(frame);
        queue.frames.deinit(queue.gpa);
    }

    /// Copy one complete frame out of ephemeral FFI scratch.
    pub fn stage(queue: *FrameQueue, frame: []const u8) bool {
        if (frame.len == 0 or frame.len > max_frame_bytes) {
            queue.markDisconnected(.oversized_frame);
            return false;
        }
        const owned = queue.gpa.dupe(u8, frame) catch {
            queue.markDisconnected(.queue_overflow);
            return false;
        };
        return queue.stageOwned(owned);
    }

    /// Transfer one allocator-owned frame into the queue without copying.
    /// Ownership transfers on every return path; failure frees `frame`.
    pub fn stageOwned(queue: *FrameQueue, frame: []u8) bool {
        if (frame.len == 0 or frame.len > max_frame_bytes) {
            queue.gpa.free(frame);
            queue.markDisconnected(.oversized_frame);
            return false;
        }
        queue.mutex.lock();
        defer queue.mutex.unlock();
        if (queue.disconnect != null or
            queue.frames.items.len - queue.read_index == max_queued_frames or
            frame.len > max_queued_bytes - queue.pending_bytes)
        {
            queue.disconnect = .queue_overflow;
            queue.gpa.free(frame);
            return false;
        }
        queue.frames.append(queue.gpa, frame) catch {
            queue.disconnect = .queue_overflow;
            queue.gpa.free(frame);
            return false;
        };
        queue.pending_bytes += frame.len;
        return true;
    }

    /// Transfer one owned frame to the consumer; release it after use.
    pub fn take(queue: *FrameQueue) ?[]u8 {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        if (queue.read_index == queue.frames.items.len) {
            queue.frames.clearRetainingCapacity();
            queue.read_index = 0;
            return null;
        }
        const frame = queue.frames.items[queue.read_index];
        queue.read_index += 1;
        queue.pending_bytes -= frame.len;
        return frame;
    }

    pub fn release(queue: *FrameQueue, frame: []u8) void {
        queue.gpa.free(frame);
    }

    pub fn markDisconnected(queue: *FrameQueue, reason: DisconnectReason) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        if (queue.disconnect == null) queue.disconnect = reason;
    }

    pub fn takeDisconnect(queue: *FrameQueue) ?DisconnectReason {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        const reason = queue.disconnect;
        queue.disconnect = null;
        return reason;
    }

    /// Drop one retired connection while retaining queue capacity for retry.
    pub fn reset(queue: *FrameQueue) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        for (queue.frames.items[queue.read_index..]) |frame| queue.gpa.free(frame);
        queue.frames.clearRetainingCapacity();
        queue.read_index = 0;
        queue.pending_bytes = 0;
        queue.disconnect = null;
    }

    pub fn retainedCapacity(queue: *FrameQueue) usize {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        return queue.frames.capacity;
    }
};

/// Full-duplex staging. UI drains incoming and fills outgoing; the native-sdk
/// readiness extension does the inverse. Neither queue calls the Rust bridge.
pub const Bridge = struct {
    incoming: FrameQueue,
    outgoing: FrameQueue,

    pub fn init(gpa: std.mem.Allocator) Bridge {
        return .{ .incoming = .init(gpa), .outgoing = .init(gpa) };
    }

    pub fn deinit(bridge: *Bridge) void {
        bridge.incoming.deinit();
        bridge.outgoing.deinit();
    }
};

/// Noninteractive harness using the exact live queues without a socket.
pub const Harness = struct {
    bridge: Bridge,

    pub fn init(gpa: std.mem.Allocator) Harness {
        return .{ .bridge = .init(gpa) };
    }

    pub fn deinit(harness: *Harness) void {
        harness.bridge.deinit();
    }

    pub fn serverFrame(harness: *Harness, frame: []const u8) bool {
        return harness.bridge.incoming.stage(frame);
    }

    pub fn clientFrame(harness: *Harness) ?[]u8 {
        return harness.bridge.outgoing.take();
    }
};

test "explicit config and large-frame channel bypass" {
    const testing = std.testing;
    const config = try Config.parse("127.0.0.1:8022/work");
    try testing.expectEqualStrings("127.0.0.1", config.host);
    try testing.expectEqual(@as(u16, 8022), config.port);
    try testing.expectEqualStrings("work", config.session);
    try testing.expectError(error.InvalidConfig, Config.parse("127.0.0.1/work"));

    var harness = Harness.init(testing.allocator);
    defer harness.deinit();
    const large = try testing.allocator.alloc(u8, 32 * 1024);
    defer testing.allocator.free(large);
    @memset(large, 0xa5);
    try testing.expect(harness.serverFrame(large));
    try testing.expectEqual(@as(usize, 1), wake_payload.len);
    const received = harness.bridge.incoming.take().?;
    defer harness.bridge.incoming.release(received);
    try testing.expectEqualSlices(u8, large, received);
}

test "owned inbound frame transfers without payload allocation" {
    const testing = std.testing;
    var queue = FrameQueue.init(testing.allocator);
    defer queue.deinit();
    const owned = try testing.allocator.dupe(u8, "\x00\x00\x00\x01x");
    const original_ptr = owned.ptr;
    try testing.expect(queue.stageOwned(owned));
    const received = queue.take().?;
    try testing.expectEqual(original_ptr, received.ptr);
    queue.release(received);
}

test "queue retains high-water metadata capacity" {
    const testing = std.testing;
    var queue = FrameQueue.init(testing.allocator);
    defer queue.deinit();
    for (0..32) |_| try testing.expect(queue.stage("frame"));
    while (queue.take()) |frame| queue.release(frame);
    const high_water = queue.retainedCapacity();
    try testing.expect(high_water >= 32);
    try testing.expect(queue.stage("again"));
    queue.release(queue.take().?);
    try testing.expectEqual(high_water, queue.retainedCapacity());
}
