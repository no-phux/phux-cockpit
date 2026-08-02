//! Cockpit-owned raw pointer seam.
//!
//! native-sdk routes pointer samples internally to widgets and exposes no
//! application callback for terminal mouse forwarding. On macOS this module
//! installs a scoped AppKit local monitor; other hosts report the capability as
//! unavailable rather than silently dropping terminal mouse input.

const builtin = @import("builtin");

pub const Event = extern struct {
    kind: c_uint,
    button: c_uint,
    modifiers: u16,
    x: f64,
    y: f64,
};

pub const Callback = *const fn (?*anyopaque, *const Event) callconv(.c) void;

pub const Error = error{ Unsupported, InstallFailed };

pub const Monitor = struct {
    raw: ?*anyopaque = null,

    pub fn start(context: ?*anyopaque, callback: Callback) Error!Monitor {
        if (comptime builtin.os.tag != .macos) return error.Unsupported;
        const raw = phux_pointer_monitor_start(context, callback) orelse return error.InstallFailed;
        return .{ .raw = raw };
    }

    pub fn stop(monitor: *Monitor) void {
        const raw = monitor.raw orelse return;
        monitor.raw = null;
        if (comptime builtin.os.tag == .macos) phux_pointer_monitor_stop(raw);
    }
};

extern fn phux_pointer_monitor_start(context: ?*anyopaque, callback: Callback) ?*anyopaque;
extern fn phux_pointer_monitor_stop(monitor: *anyopaque) void;
