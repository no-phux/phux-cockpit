const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const createSession = support.createSession;
const activeSlots = support.activeSlots;

test "Phux Cockpit identity and macOS pane commands are exact" {
    try testing.expectEqualStrings("Phux Cockpit", app.app_name);
    try testing.expectEqualStrings("dev.phux.cockpit", app.bundle_id);
    try testing.expectEqualStrings("phux-cockpit-canvas", app.canvas_label);
    try testing.expectEqualStrings(app.app_name, app.shell_scene.windows[0].title.?);
    try testing.expectEqualStrings(app.canvas_label, app.shell_scene.windows[0].views[0].label);
    try testing.expectEqualStrings(app.app_name, app.appOptions().name);
    try testing.expectEqualStrings(app.canvas_label, app.appOptions().canvas_label);

    if (comptime builtin.os.tag != .macos) return;
    try testing.expectEqualSlices([]const u8, &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }, app.paneArgv(0));
    try testing.expectEqualSlices([]const u8, &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }, app.paneArgv(1));
}

test "Phux Cockpit owns its dark graphite and lime visual register" {
    const session = try createSession(80, 24);
    var model = app.initialModel(session);
    defer app.deinitModel(&model);
    const tokens = app.cockpitTokens(&model);
    try testing.expectEqual(canvas.Color.rgb8(9, 11, 15), tokens.colors.background);
    try testing.expectEqual(canvas.Color.rgb8(17, 20, 27), tokens.colors.surface);
    try testing.expectEqual(canvas.Color.rgb8(244, 247, 251), tokens.colors.text);
    try testing.expectEqual(canvas.Color.rgb8(190, 242, 100), tokens.colors.accent);
}

test "retained response capacity matches the outbound ring" {
    try testing.expectEqual(app.outbound_buffer_bytes, grid.Session.response_capacity_max);
}
