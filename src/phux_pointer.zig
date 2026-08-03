//! Bounded raw-pointer staging for the deterministic Cockpit UI loop.
//!
//! The AppKit monitor copies samples into `EventQueue` and posts only a
//! one-byte wake. It has no model pointer and cannot call the phux client. The
//! main layer remains responsible for header, divider, provider, and Web-view
//! filtering when it drains the queue.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");

pub const wake_payload = [_]u8{2};
pub const max_queued_events: usize = 256;

pub const EventKind = enum(c_uint) {
    button_down = 0,
    button_up = 1,
    motion = 2,
};

/// ABI-stable value copied from AppKit. Coordinates are content-view points,
/// with the origin at the top-left. Identity and hit testing are deliberately
/// absent from this transport value.
pub const Event = extern struct {
    kind: c_uint,
    button: c_uint,
    modifiers: u16,
    x: f64,
    y: f64,

    pub fn eventKind(event: Event) ?EventKind {
        return switch (event.kind) {
            0 => .button_down,
            1 => .button_up,
            2 => .motion,
            else => null,
        };
    }
};

const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(mutex: *SpinMutex) void {
        while (!mutex.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(mutex: *SpinMutex) void {
        mutex.inner.unlock();
    }
};

/// Fixed-storage multi-producer/single-consumer queue. `stage` returns true
/// only when the UI loop needs a new wake: on an empty-to-nonempty transition
/// or when overflow first becomes observable.
pub const EventQueue = struct {
    mutex: SpinMutex = .{},
    events: [max_queued_events]Event = undefined,
    read_index: usize = 0,
    write_index: usize = 0,
    count: usize = 0,
    overflow: bool = false,

    pub fn stage(queue: *EventQueue, event: Event) bool {
        queue.mutex.lock();
        defer queue.mutex.unlock();

        const was_empty = queue.count == 0;
        if (queue.coalesceMotion(event)) return false;

        var overflow_became_visible = false;
        if (queue.count == max_queued_events) {
            // Preserve button transitions when possible by sacrificing the
            // oldest motion sample. The sticky overflow bit tells the main
            // layer that capture state may need reconciliation.
            if (event.eventKind() != .motion and queue.removeOldestMotion()) {
                overflow_became_visible = !queue.overflow;
                queue.overflow = true;
            } else {
                overflow_became_visible = !queue.overflow;
                queue.overflow = true;
                return overflow_became_visible;
            }
        }

        queue.events[queue.write_index] = event;
        queue.write_index = (queue.write_index + 1) % max_queued_events;
        queue.count += 1;
        return was_empty or overflow_became_visible;
    }

    pub fn take(queue: *EventQueue) ?Event {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        if (queue.count == 0) return null;
        const event = queue.events[queue.read_index];
        queue.read_index = (queue.read_index + 1) % max_queued_events;
        queue.count -= 1;
        if (queue.count == 0) {
            // Keep indices deterministic and avoid lifetime-dependent wrap
            // positions after a complete drain.
            queue.read_index = 0;
            queue.write_index = 0;
        }
        return event;
    }

    /// Consume the sticky indication that one or more samples were dropped.
    pub fn takeOverflow(queue: *EventQueue) bool {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        const result = queue.overflow;
        queue.overflow = false;
        return result;
    }

    pub fn reset(queue: *EventQueue) void {
        queue.mutex.lock();
        defer queue.mutex.unlock();
        queue.read_index = 0;
        queue.write_index = 0;
        queue.count = 0;
        queue.overflow = false;
    }

    fn coalesceMotion(queue: *EventQueue, event: Event) bool {
        if (queue.count == 0 or event.eventKind() != .motion) return false;
        const last_index = (queue.write_index + max_queued_events - 1) % max_queued_events;
        const previous = queue.events[last_index];
        if (previous.eventKind() != .motion or previous.button != event.button) return false;
        queue.events[last_index] = event;
        return true;
    }

    fn removeOldestMotion(queue: *EventQueue) bool {
        var logical_index: usize = 0;
        while (logical_index < queue.count) : (logical_index += 1) {
            const physical = (queue.read_index + logical_index) % max_queued_events;
            if (queue.events[physical].eventKind() != .motion) continue;

            var shift = logical_index;
            while (shift + 1 < queue.count) : (shift += 1) {
                const destination = (queue.read_index + shift) % max_queued_events;
                const source = (queue.read_index + shift + 1) % max_queued_events;
                queue.events[destination] = queue.events[source];
            }
            queue.write_index = (queue.write_index + max_queued_events - 1) % max_queued_events;
            queue.count -= 1;
            return true;
        }
        return false;
    }
};

pub const Error = error{ Unsupported, InstallFailed };

const MonitorState = struct {
    queue: *EventQueue,
    handle: native_sdk.ChannelHandle,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    callbacks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    raw: ?*anyopaque,
    state: *MonitorState,

    /// `queue` must have a stable address and outlive the returned monitor.
    /// The handle is used solely for one-byte readiness posts.
    pub fn start(
        gpa: std.mem.Allocator,
        queue: *EventQueue,
        handle: native_sdk.ChannelHandle,
    ) (Error || std.mem.Allocator.Error)!Monitor {
        if (comptime builtin.os.tag != .macos) return error.Unsupported;

        const state = try gpa.create(MonitorState);
        errdefer gpa.destroy(state);
        state.* = .{ .queue = queue, .handle = handle };
        const raw = phux_pointer_monitor_start(state, stageRaw) orelse return error.InstallFailed;
        return .{ .gpa = gpa, .raw = raw, .state = state };
    }

    /// Unregister first, then wait for any callback already in flight before
    /// releasing its state. No queue mutation or wake post can occur after this
    /// method returns.
    pub fn stop(monitor: *Monitor) void {
        const raw = monitor.raw orelse return;
        monitor.raw = null;
        monitor.state.stopping.store(true, .release);
        if (comptime builtin.os.tag == .macos) phux_pointer_monitor_stop(raw);
        while (monitor.state.callbacks.load(.acquire) != 0) std.atomic.spinLoopHint();
        monitor.gpa.destroy(monitor.state);
    }
};

fn stageRaw(raw_context: ?*anyopaque, raw_event: *const Event) callconv(.c) void {
    const context = raw_context orelse return;
    const state: *MonitorState = @ptrCast(@alignCast(context));
    _ = state.callbacks.fetchAdd(1, .acq_rel);
    defer _ = state.callbacks.fetchSub(1, .acq_rel);

    if (state.stopping.load(.acquire)) return;
    const needs_wake = state.queue.stage(raw_event.*);
    if (needs_wake and !state.stopping.load(.acquire)) {
        _ = state.handle.post(&wake_payload);
    }
}

extern fn phux_pointer_monitor_start(
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, *const Event) callconv(.c) void,
) ?*anyopaque;
extern fn phux_pointer_monitor_stop(monitor: *anyopaque) void;

test "motion samples coalesce without losing button transitions" {
    var queue: EventQueue = .{};
    const move_one: Event = .{ .kind = @intFromEnum(EventKind.motion), .button = std.math.maxInt(c_uint), .modifiers = 0, .x = 1, .y = 2 };
    var move_two = move_one;
    move_two.x = 3;
    const down: Event = .{ .kind = @intFromEnum(EventKind.button_down), .button = 0, .modifiers = 0, .x = 3, .y = 2 };

    try std.testing.expect(queue.stage(move_one));
    try std.testing.expect(!queue.stage(move_two));
    try std.testing.expect(!queue.stage(down));
    try std.testing.expectEqual(@as(f64, 3), queue.take().?.x);
    try std.testing.expectEqual(EventKind.button_down, queue.take().?.eventKind().?);
    try std.testing.expect(queue.take() == null);
}

test "event queue exposes bounded overflow" {
    var queue: EventQueue = .{};
    for (0..max_queued_events) |index| {
        const event: Event = .{
            .kind = @intFromEnum(EventKind.button_down),
            .button = @intCast(index),
            .modifiers = 0,
            .x = 0,
            .y = 0,
        };
        _ = queue.stage(event);
    }
    const extra: Event = .{ .kind = @intFromEnum(EventKind.button_up), .button = 0, .modifiers = 0, .x = 0, .y = 0 };
    try std.testing.expect(queue.stage(extra));
    try std.testing.expect(queue.takeOverflow());
    try std.testing.expect(!queue.takeOverflow());

    var count: usize = 0;
    while (queue.take() != null) count += 1;
    try std.testing.expectEqual(max_queued_events, count);
}

test "overflow sacrifices motion while preserving every queued button transition" {
    var queue: EventQueue = .{};
    const motion: Event = .{
        .kind = @intFromEnum(EventKind.motion),
        .button = std.math.maxInt(c_uint),
        .modifiers = 0,
        .x = 12,
        .y = 34,
    };
    try std.testing.expect(queue.stage(motion));

    for (0..max_queued_events - 1) |index| {
        const down: Event = .{
            .kind = @intFromEnum(EventKind.button_down),
            .button = @intCast(index),
            .modifiers = 0,
            .x = @floatFromInt(index),
            .y = 0,
        };
        try std.testing.expect(!queue.stage(down));
    }

    const final_up: Event = .{
        .kind = @intFromEnum(EventKind.button_up),
        .button = 99,
        .modifiers = 0,
        .x = 999,
        .y = 0,
    };
    try std.testing.expect(queue.stage(final_up));
    try std.testing.expect(!queue.stage(motion));

    for (0..max_queued_events - 1) |index| {
        const event = queue.take().?;
        try std.testing.expectEqual(EventKind.button_down, event.eventKind().?);
        try std.testing.expectEqual(@as(c_uint, @intCast(index)), event.button);
    }
    const preserved_up = queue.take().?;
    try std.testing.expectEqual(EventKind.button_up, preserved_up.eventKind().?);
    try std.testing.expectEqual(@as(c_uint, 99), preserved_up.button);
    try std.testing.expect(queue.take() == null);

    // Overflow survives a complete drain and repeated drops until explicitly
    // acknowledged by the owning UI loop.
    try std.testing.expect(queue.takeOverflow());
    try std.testing.expect(!queue.takeOverflow());
}

test "motion coalescing is consecutive and does not cross a transition" {
    var queue: EventQueue = .{};
    const first: Event = .{
        .kind = @intFromEnum(EventKind.motion),
        .button = std.math.maxInt(c_uint),
        .modifiers = 0,
        .x = 1,
        .y = 1,
    };
    var replacement = first;
    replacement.x = 2;
    const down: Event = .{
        .kind = @intFromEnum(EventKind.button_down),
        .button = 0,
        .modifiers = 0,
        .x = 2,
        .y = 1,
    };
    var after_transition = first;
    after_transition.x = 3;

    try std.testing.expect(queue.stage(first));
    try std.testing.expect(!queue.stage(replacement));
    try std.testing.expect(!queue.stage(down));
    try std.testing.expect(!queue.stage(after_transition));

    try std.testing.expectEqual(@as(f64, 2), queue.take().?.x);
    try std.testing.expectEqual(EventKind.button_down, queue.take().?.eventKind().?);
    try std.testing.expectEqual(@as(f64, 3), queue.take().?.x);
    try std.testing.expect(queue.take() == null);
}
