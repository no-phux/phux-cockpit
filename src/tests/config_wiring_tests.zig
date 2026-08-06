//! The config is only real when it CHANGES something. `config_tests.zig`
//! proves the parser; this file proves each knob reaches the pixels, the
//! emulator, or the geometry it names.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;

test "font-size drives the terminal cell box and leaves the chrome alone" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    const small = canvas.terminalCellMetrics(app.terminalTokens(&state.model));
    state.model.config = app.parseConfig("font-size = 26");
    const large = canvas.terminalCellMetrics(app.terminalTokens(&state.model));

    try testing.expect(large.height > small.height);
    try testing.expect(large.width > small.width);
    try testing.expectEqual(@as(f32, 26), large.font_size);
    // The chrome register does NOT follow the terminal: growing the terminal
    // must not grow the tab strip's labels.
    try testing.expectEqual(small.font_size, canvas.terminalCellMetrics(app.cockpitTokens(&state.model)).font_size);
}

test "a bigger font reflows the pty to fewer columns" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    const pane = state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    const cols_before = pane.cols;
    try testing.expect(cols_before > 2);

    state.model.config = app.parseConfig("font-size = 30");
    // Two pumps: the painter writes the new cell metrics on the first frame,
    // and the viewport pump reads them on the next. Nothing here touches the
    // pty directly — the reflow rides the ordinary onFrame path.
    for (2..8) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = size,
            .scale_factor = 2,
            .frame_index = @intCast(frame_index),
            .timestamp_ns = @as(u64, frame_index) * 1_000_000,
        } });
        try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    }
    try testing.expect(pane.cols < cols_before);
    try testing.expectEqual(pane.cols, pane.session.cols());
}

test "cmd+= cmd+- and cmd+0 step and reset the live font size" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    // The configured size is the origin cmd+0 returns to, not a hardcoded 13.
    state.model.config = app.parseConfig("font-size = 15");
    try testing.expectEqual(@as(f32, 15), state.model.fontSize());

    // Each chord needs its own press/release edge: a consumed shortcut owns
    // its key until key-up, so a HELD cmd+- must not step twice.
    try pressCanvasKey(harness, iface, "=", .{ .primary = true });
    try testing.expectEqual(@as(f32, 16), state.model.fontSize());
    try pressCanvasKey(harness, iface, "=", .{ .primary = true });
    try testing.expectEqual(@as(f32, 16), state.model.fontSize());
    try releaseCanvasKey(harness, iface, "=", .{ .primary = true });

    try pressCanvasKey(harness, iface, "-", .{ .primary = true });
    try releaseCanvasKey(harness, iface, "-", .{ .primary = true });
    try pressCanvasKey(harness, iface, "-", .{ .primary = true });
    try releaseCanvasKey(harness, iface, "-", .{ .primary = true });
    try testing.expectEqual(@as(f32, 14), state.model.fontSize());

    try pressCanvasKey(harness, iface, "0", .{ .primary = true });
    try testing.expectEqual(@as(f32, 15), state.model.fontSize());
}

test "font sizing clamps at both ends without stranding the key" {
    var model: app.Model = .{ .provider = undefined, .config = app.parseConfig("font-size = 71") };
    try testing.expect(model.stepFontSize(1));
    try testing.expectEqual(@as(f32, 72), model.fontSize());
    // At the ceiling the step is refused rather than banked, so ONE step back
    // moves the size instead of unwinding invisible headroom first.
    try testing.expect(!model.stepFontSize(1));
    try testing.expect(!model.stepFontSize(1));
    try testing.expect(model.stepFontSize(-1));
    try testing.expectEqual(@as(f32, 71), model.fontSize());
    // Back at the configured size the offset is genuinely zero, so cmd+0 has
    // nothing to undo and says so.
    try testing.expect(!model.resetFontSize());
    try testing.expect(model.stepFontSize(-10));
    try testing.expectEqual(@as(f32, 61), model.fontSize());
    try testing.expect(model.resetFontSize());
    try testing.expectEqual(@as(f32, 71), model.fontSize());
}

test "background foreground and selection colors reach the terminal tokens" {
    var model: app.Model = .{
        .provider = undefined,
        .config = app.parseConfig(
            \\background = #102030
            \\foreground = #a0b0c0
            \\selection-background = #ff0000
        ),
    };
    const tokens = app.terminalTokens(&model);
    try testing.expectEqual(canvas.Color.rgb8(0x10, 0x20, 0x30), tokens.colors.background);
    try testing.expectEqual(canvas.Color.rgb8(0xa0, 0xb0, 0xc0), tokens.colors.text);
    // The selection wash reads `accent` (see terminal/palette.zig).
    try testing.expectEqual(canvas.Color.rgb8(0xff, 0, 0), tokens.colors.accent);

    // An unset color leaves the app's own register untouched rather than
    // resolving to black.
    var bare: app.Model = .{ .provider = undefined };
    const default_tokens = app.terminalTokens(&bare);
    try testing.expectEqual(app.cockpitTokens(&bare).colors.background, default_tokens.colors.background);
}

test "palette overrides cursor color and cursor style reach the emulator" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    const pane = state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    // Before: the emulator's own ANSI red and no cursor override.
    try testing.expect(pane.session.term.colors.cursor.override == null);
    const default_red = pane.session.term.colors.palette.current[1];

    state.model.config = app.parseConfig(
        \\palette = 1=#ff8800
        \\cursor-color = #00ff00
        \\cursor-style = bar
        \\cursor-style-blink = false
    );
    // Restart is a spawn, and every spawn re-applies the config after the
    // emulator reset that spawning performs.
    pane.phase = .ended;
    try state.dispatch(&harness.runtime, 1, .{ .restart = pane.id });

    try testing.expectEqual(@as(u8, 0xff), pane.session.term.colors.palette.current[1].r);
    try testing.expectEqual(@as(u8, 0x88), pane.session.term.colors.palette.current[1].g);
    try testing.expect(!std.meta.eql(default_red, pane.session.term.colors.palette.current[1]));
    const cursor = pane.session.term.colors.cursor.override orelse return error.TestExpectedCursorOverride;
    try testing.expectEqual(@as(u8, 0xff), cursor.g);
    try testing.expectEqual(@as(u8, 0), cursor.r);
    try testing.expectEqual(@as(?bool, false), pane.session.term.cursor.default_blink);
}

test "restart is not required for the FIRST spawn to be configured" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;

    const session = try support.createDefaultSession();
    var model = app.initialModelWithIo(testing.allocator, testing.io, session) catch |err| {
        session.destroy();
        return err;
    };
    model.config = app.parseConfig("palette = 4=#123456");
    const state = try testing.allocator.create(support.TerminalApp);
    state.* = support.TerminalApp.init(std.heap.page_allocator, model, app.appOptions());
    defer stopCockpit(state);
    state.effects.executor = .fake;
    try harness.start(state.app());
    try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(state.app(), .frame_requested);

    const pane = state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    try testing.expectEqual(@as(u8, 0x12), pane.session.term.colors.palette.current[4].r);
    try testing.expectEqual(@as(u8, 0x56), pane.session.term.colors.palette.current[4].b);
}

test "a new tab and a split start in the focused pane's directory" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    // Nothing reported yet: the new terminal takes the plain argv, exactly as
    // the very first terminal does.
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expectEqualSlices([]const u8, app.paneArgv(0), state.model.provider.slots[1].argv);

    // OSC 7 from the focused shell, then a split.
    try state.dispatch(&harness.runtime, 1, .{ .select_position = 0 });
    try state.effects.feedPtyOutput(app.ptyKey(0), "\x1b]7;file://host/Users/phall/workspace\x1b\\");
    try harness.runtime.dispatchPlatformEvent(iface, .wake);
    try testing.expectEqualStrings("/Users/phall/workspace", state.model.provider.slots[0].pwd());

    try state.dispatch(&harness.runtime, 1, .split_right);
    const split_argv = state.model.provider.slots[2].argv;
    var saw_cwd = false;
    for (split_argv) |word| {
        if (std.mem.indexOf(u8, word, "/Users/phall/workspace") != null) saw_cwd = true;
    }
    try testing.expect(saw_cwd);
    // The argv slices into MODEL-owned storage, which outlives the pane and
    // survives the Restart that re-reads it.
    try testing.expect(@intFromPtr(split_argv.ptr) >= @intFromPtr(&state.model.cwd_argv));
    try testing.expect(@intFromPtr(split_argv.ptr) < @intFromPtr(&state.model.cwd_argv) + @sizeOf(@TypeOf(state.model.cwd_argv)));

    // Turning the knob off restores the plain argv.
    state.model.config = app.parseConfig("inherit-working-directory = false");
    try state.dispatch(&harness.runtime, 1, .new_terminal);
    try testing.expectEqualSlices([]const u8, app.paneArgv(0), state.model.provider.slots[3].argv);
}

test "window-padding moves the content rect and the header band" {
    var tight: app.Model = .{ .provider = undefined, .config = app.parseConfig("window-padding = 0") };
    var loose: app.Model = .{ .provider = undefined, .config = app.parseConfig("window-padding = 24") };
    const size = geometry.SizeF.init(980, 640);
    const tight_chrome = app.workspaceChrome(&tight, size);
    const loose_chrome = app.workspaceChrome(&loose, size);

    try testing.expectEqual(@as(f32, 0), tight_chrome.header.x);
    try testing.expectEqual(@as(f32, 24), loose_chrome.header.x);
    try testing.expect(loose_chrome.content.width < tight_chrome.content.width);
    try testing.expectEqual(@as(f32, 980), tight_chrome.content.width);
}

test "hide-chrome-when-single = false keeps the strip on one healthy tab" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    // The default is to hide: one healthy terminal shows no band at all.
    try testing.expect(!app.chromeRevealed(&state.model));
    state.model.config = app.parseConfig("hide-chrome-when-single = false");
    try testing.expect(app.chromeRevealed(&state.model));
    try testing.expect(app.workspaceChrome(&state.model, geometry.SizeF.init(980, 640)).header.height > 0);
}

test "tab-placement from the config file selects the side rail" {
    try testing.expectEqual(app.ConfigTabPlacement.side, app.parseConfig("tab-placement = sidebar").tab_placement);
    try testing.expectEqual(app.ConfigTabPlacement.top, app.parseConfig("").tab_placement);
}

test "a missing config file is a silent no-op with defaults" {
    // No bytes at all is the NORMAL case, not an error.
    const defaults = app.loadConfigOrDefault(null);
    try testing.expectEqual(@as(usize, 0), defaults.diagnostic_count);
    const pristine: app.Config = .{};
    try testing.expectEqual(pristine.font_size, defaults.font_size);
    try testing.expectEqual(pristine.window_padding, defaults.window_padding);

    // And an unresolvable directory (no HOME) yields no path rather than an
    // error the caller has to decide what to do about.
    var dir_storage: [512]u8 = undefined;
    var path_storage: [512]u8 = undefined;
    try testing.expectEqual(
        @as(?[]const u8, null),
        app.resolveConfigPath(.{}, null, &dir_storage, &path_storage),
    );
}

test "the config path is the app-dirs config directory, and the env override wins" {
    var dir_storage: [512]u8 = undefined;
    var path_storage: [512]u8 = undefined;
    const explicit = app.resolveConfigPath(
        .{ .home = "/Users/alice" },
        "/tmp/somewhere/else",
        &dir_storage,
        &path_storage,
    ) orelse return error.TestExpectedPath;
    try testing.expectEqualStrings("/tmp/somewhere/else", explicit);

    const resolved = app.resolveConfigPath(
        .{ .home = "/Users/alice" },
        null,
        &dir_storage,
        &path_storage,
    ) orelse return error.TestExpectedPath;
    try testing.expect(std.mem.startsWith(u8, resolved, "/Users/alice/"));
    try testing.expect(std.mem.endsWith(u8, resolved, "/config"));
}
