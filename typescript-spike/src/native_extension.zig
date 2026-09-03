//! Cockpit's TypeScript runner extension: the native side of the seam.
//!
//! The generated runner calls the three entry points at the bottom. Between
//! them this file installs one host-call binding for the `cockpit.` namespace
//! and keeps one `Engine` alive for the process. The core sends intents with
//! `Cmd.host("cockpit.intent")`, asks for state with
//! `Cmd.request("cockpit.snapshot")`, and hears that state moved on the
//! channel it opened under `protocol.event_channel_key`.
//!
//! Every crossing happens on the effects loop thread. A snapshot request is
//! answered through the binding's poll seam rather than by feeding the result
//! from inside the request callback, because that seam is the one the runtime
//! documents for completions and the one that copies bytes on delivery.

const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("core");
const cockpit = @import("cockpit_engine");

const Engine = cockpit.Engine;
const protocol = cockpit.protocol;
const Adapter = native_sdk.TsUiApp(core);
const Effects = Adapter.Effects;
const canvas = native_sdk.canvas;

const HostChannelBinding = channelBindingType();

fn channelBindingType() type {
    const field = @FieldType(native_sdk.HostCallBinding, "bind_channels_fn");
    const function = @typeInfo(@typeInfo(field).optional.child).pointer.child;
    return @typeInfo(function).@"fn".params[1].type.?;
}

const Bridge = struct {
    engine: ?*Engine = null,
    channels: ?HostChannelBinding = null,
    /// The adapter's effects, known once the runner has built the app. Until
    /// then there is nothing to spawn shells through, and `spawnShells` is
    /// idempotent so the first frame catches up.
    effects: ?*Effects = null,
    /// Tests that want no child processes clear this before starting.
    shells: bool = true,
    /// The one snapshot completion in flight. A newer request overwrites an
    /// unpolled older one; the runtime cancels the replaced key itself.
    pending: bool = false,
    pending_key: u64 = 0,
    pending_ok: bool = false,
    pending_len: usize = 0,
    buffer: [cockpit.snapshot.max_bytes]u8 = undefined,
    /// Kept for tests: the post outcomes the runtime handed back.
    posts_accepted: usize = 0,
    posts_unroutable: usize = 0,

    fn binding(self: *Bridge) native_sdk.HostCallBinding {
        return .{
            .context = self,
            .send_fn = send,
            .request_fn = request,
            .cancel_fn = cancel,
            .poll_fn = poll,
            .pending_fn = hasPending,
            .bind_channels_fn = bindChannels,
        };
    }

    fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, name, protocol.intent_command)) return;
        const engine = self.engine orelse return;
        if (self.effects) |fx| {
            _ = engine.applyIntent(payload, fx);
            self.spawnShells(engine, fx);
        } else {
            _ = engine.applyIntent(payload, &cockpit.NoShells{});
        }
        self.announce(engine);
    }

    fn spawnShells(self: *Bridge, engine: *Engine, fx: *Effects) void {
        if (!self.shells) return;
        engine.spawnShells(fx, shellEvent);
    }

    /// Tell the core that state moved. Silence when the channel is not open
    /// yet is correct: the core requests a snapshot at boot regardless, and
    /// an intent it sent before opening the channel cannot exist.
    fn announce(self: *Bridge, engine: *const Engine) void {
        const channels = self.channels orelse {
            self.posts_unroutable += 1;
            return;
        };
        const handle = channels.acquire_fn(channels.context, protocol.event_channel_key) orelse {
            self.posts_unroutable += 1;
            return;
        };
        const bytes = engine.invalidation();
        switch (handle.post(&bytes)) {
            .accepted => self.posts_accepted += 1,
            else => self.posts_unroutable += 1,
        }
    }

    fn request(context: *anyopaque, name: []const u8, key: u64, _: []const u8) void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        self.pending = true;
        self.pending_key = key;
        if (!std.mem.eql(u8, name, protocol.snapshot_request)) {
            self.pending_ok = false;
            self.pending_len = copyInto(&self.buffer, "unknown cockpit request");
            return;
        }
        const engine = self.engine orelse {
            self.pending_ok = false;
            self.pending_len = copyInto(&self.buffer, "engine unavailable");
            return;
        };
        const bytes = engine.snapshot(&self.buffer) catch {
            self.pending_ok = false;
            self.pending_len = copyInto(&self.buffer, "snapshot too large");
            return;
        };
        self.pending_ok = true;
        self.pending_len = bytes.len;
    }

    fn copyInto(buffer: []u8, text: []const u8) usize {
        @memcpy(buffer[0..text.len], text);
        return text.len;
    }

    fn cancel(context: *anyopaque, key: u64) void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (self.pending and self.pending_key == key) self.pending = false;
    }

    fn poll(context: *anyopaque) ?native_sdk.HostCallCompletion {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (!self.pending) return null;
        self.pending = false;
        return .{ .key = self.pending_key, .ok = self.pending_ok, .bytes = self.buffer[0..self.pending_len] };
    }

    fn hasPending(context: *anyopaque) bool {
        const self: *Bridge = @ptrCast(@alignCast(context));
        return self.pending;
    }

    fn bindChannels(context: *anyopaque, channels: HostChannelBinding) void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        self.channels = channels;
    }
};

var bridge = Bridge{};

// ------------------------------------------------- native seams (no TS)

/// The pty event constructor the adapter's effects call for every shell
/// event. The bytes are consumed here, into the pane's emulator, and the
/// core receives only a void wake so it re-renders; no terminal byte enters
/// the compiled core.
fn shellEvent(event: native_sdk.EffectPtyEvent) core.Msg {
    if (bridge.engine) |engine| {
        if (bridge.effects) |fx| engine.onShellEvent(fx, event);
    }
    return .engine_wake;
}

/// Keys no markup widget claimed. The palette and settings surfaces are the
/// core's, so while either is open the shell must not see typing meant for
/// them; the core's model says which, and the view fn below reads it.
/// Keys the overlays answer to that no widget of theirs claims: Escape
/// dismisses, the arrows move the highlight, Enter commits the settings
/// surface (the switcher's Enter is its input's own on-submit). Delivered
/// as core Msgs, because the overlays are the core's; the shell never sees
/// them while an overlay owns the keyboard.
fn overlayKey(event: canvas.WidgetKeyboardEvent) ?core.Msg {
    if (event.phase == .key_up) return null;
    const key = event.key;
    if (std.mem.eql(u8, key, "Escape")) return if (palette_open) .palette_close else .settings_close;
    if (std.mem.eql(u8, key, "ArrowDown")) return if (palette_open) .{ .palette_move = 1 } else .{ .settings_move = 1 };
    if (std.mem.eql(u8, key, "ArrowUp")) return if (palette_open) .{ .palette_move = -1 } else .{ .settings_move = -1 };
    if (std.mem.eql(u8, key, "Enter") and !palette_open) return .settings_commit;
    return null;
}

fn onKey(event: canvas.WidgetKeyboardEvent) ?core.Msg {
    if (overlay_open) return overlayKey(event);
    const engine = bridge.engine orelse return null;
    const fx = bridge.effects orelse return null;
    engine.onKey(fx, event);
    return null;
}

fn onText(event: canvas.WidgetKeyboardEvent) ?core.Msg {
    if (overlay_open) return null;
    const engine = bridge.engine orelse return null;
    const fx = bridge.effects orelse return null;
    engine.onText(fx, event);
    return null;
}

/// Set by the paint pass, which sees the committed core model: the only
/// place the extension learns whether an overlay owns the keyboard.
var overlay_open: bool = false;
var palette_open: bool = false;

fn onFrame(_: *const core.Model, frame: native_sdk.platform.GpuFrame) ?core.Msg {
    const engine = bridge.engine orelse return null;
    const fx = bridge.effects orelse return null;
    bridge.spawnShells(engine, fx);
    engine.pumpViewports(fx, frame);
    // A frame that moved the run (a resize, the first frame after a
    // placement flip) is announced like an intent: the core's chrome is
    // wrong until it resyncs, and only the engine knows.
    if (engine.refreshRun()) bridge.announce(engine);
    return null;
}

fn paintChrome(model: *const core.Model, builder: *canvas.Builder, size: native_sdk.geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    overlay_open = model.paletteOpen or model.settingsOpen;
    palette_open = model.paletteOpen;
    const engine = bridge.engine orelse return;
    engine.model.tab_placement = if (model.tabPlacement == .side) .side else .top;
    return engine.paint(builder, size, tokens);
}

fn installEngine(options: *Adapter.CoreOptions, gpa: std.mem.Allocator, io: std.Io) void {
    bridge = .{};
    bridge.engine = Engine.create(gpa, io) catch null;
    options.host_calls = bridge.binding();
}

pub fn configureCoreOptions(options: *Adapter.CoreOptions, init: std.process.Init) void {
    installEngine(options, std.heap.page_allocator, init.io);
}

fn configureOptionsValue(options: *Adapter.Options) void {
    options.chrome = .{
        .prefix_commands = cockpit.projection.chrome_command_envelope,
        .variable_prefix = true,
        .build = paintChrome,
    };
    options.on_key = onKey;
    options.key_release_events = true;
    options.on_text = onText;
    options.on_frame = onFrame;
}

pub fn configureOptions(options: *Adapter.Options, _: std.process.Init) void {
    configureOptionsValue(options);
}

pub fn app(app_state: *Adapter.App) native_sdk.App {
    bridge.effects = &app_state.effects;
    return app_state.app();
}

// ------------------------------------------------------------------ tests

const canvas_label = "phux-cockpit-canvas";
const test_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const test_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Phux Cockpit TS",
    .width = 1100,
    .height = 640,
    .views = &test_views,
}};
const test_scene: native_sdk.ShellConfig = .{ .windows = &test_windows };

const Rig = struct {
    app_state: *Adapter.App,
    decorated: native_sdk.App,
    harness: *native_sdk.TestHarness(),
    frame_index: u64 = 1,

    fn start() !Rig {
        var core_options: Adapter.CoreOptions = .{};
        installEngine(&core_options, std.testing.allocator, std.testing.io);
        try std.testing.expect(bridge.engine != null);
        bridge.shells = false;
        var options: Adapter.Options = .{
            .name = "phux-cockpit-typescript-spike",
            .scene = test_scene,
            .canvas_label = canvas_label,
            .markup = .{ .source = @embedFile("app.native") },
        };
        configureOptionsValue(&options);
        const app_state = try Adapter.create(std.heap.page_allocator, core_options, options);
        errdefer app_state.destroy();
        const decorated = app(app_state);
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = native_sdk.geometry.SizeF.init(1100, 640),
        });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        try harness.start(decorated);
        try harness.runtime.dispatchPlatformEvent(decorated, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = native_sdk.geometry.SizeF.init(1100, 640),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1,
        } });
        // The frame request is what commits the widget tree; input routed
        // before it has no tree to fall through and reaches nothing.
        try harness.runtime.dispatchPlatformEvent(decorated, .frame_requested);
        // A press on the grid gives the surface keyboard focus, as a person's
        // first click does; unfocused input routes nowhere.
        try harness.runtime.dispatchPlatformEvent(decorated, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_down,
            .x = 400,
            .y = 300,
        } });
        return .{ .app_state = app_state, .decorated = decorated, .harness = harness };
    }

    fn stop(self: *Rig) void {
        self.harness.destroy(std.testing.allocator);
        self.app_state.destroy();
        if (bridge.engine) |engine| engine.destroy();
        bridge = .{};
    }

    /// Drain the effects loop until the core has heard engine announcement
    /// `sequence` and shows `status`, or give up after a bounded number of
    /// wakes. Each seam crossing (completion, channel event, re-request)
    /// needs its own drain, and the status alone cannot be waited on: it
    /// already reads READY before a fresh announcement has been drained.
    fn settle(self: *Rig, sequence: i64, status: []const u8) !void {
        var wakes: usize = 0;
        while (wakes < 8) : (wakes += 1) {
            const model = self.app_state.model;
            if (model.engineSequence.lo == sequence and std.mem.eql(u8, model.status, status)) return;
            try self.harness.runtime.dispatchPlatformEvent(self.decorated, .wake);
        }
        std.debug.print("settled at sequence {d} status '{s}', wanted {d} '{s}'\n", .{
            self.app_state.model.engineSequence.lo,
            self.app_state.model.status,
            sequence,
            status,
        });
        return error.TestUnexpectedResult;
    }

    fn dispatch(self: *Rig, msg: core.Msg) !void {
        self.app_state.dispatch(&self.harness.runtime, 1, msg) catch |err| {
            std.debug.print("dispatch of {s} failed: {s}\n", .{ @tagName(msg), @errorName(err) });
            return err;
        };
    }

    /// Present a frame at `size`; the engine re-derives the run and, when it
    /// moved, announces so the core resyncs. Settled either way.
    fn resize(self: *Rig, size: native_sdk.geometry.SizeF) !void {
        self.frame_index += 1;
        const before = self.app_state.model.engineSequence.lo;
        const engine = bridge.engine.?;
        const was = engine.currentRun();
        try self.harness.runtime.dispatchPlatformEvent(self.decorated, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = size,
            .scale_factor = 1,
            .frame_index = self.frame_index,
            .timestamp_ns = self.frame_index * 16_000_000,
        } });
        const now = engine.currentRun();
        const moved = was.first != now.first or was.count != now.count or was.extent != now.extent;
        try self.settle(if (moved) before + 1 else before, "READY");
    }

    /// Drive the real core and engine into `state`: the tab count through
    /// intents and resync, the placement and overlays through their Msgs.
    fn reach(self: *Rig, state: ChromeState) !void {
        const engine = bridge.engine.?;
        while (engine.model.wsConst().tab_count < state.tabs) {
            const before = self.app_state.model.engineSequence.lo;
            try self.dispatch(.new_terminal);
            try self.settle(before + 1, "READY");
        }
        while (engine.model.wsConst().tab_count > state.tabs) {
            const before = self.app_state.model.engineSequence.lo;
            try self.dispatch(.close_selected_tab);
            try self.settle(before + 1, "READY");
        }
        try self.dispatch(.{ .select_tab = 0 });
        const before_select = self.app_state.model.engineSequence.lo;
        try self.settle(before_select + 1, "READY");
        if ((self.app_state.model.tabPlacement == .side) != (state.placement == .side)) {
            const before = self.app_state.model.engineSequence.lo;
            try self.dispatch(.toggle_tab_placement);
            try self.settle(before + 1, "READY");
        }
        // The overlays are mutually exclusive in the core as in the shipping
        // app; settings is asked for last so a "both" state ends on it.
        // Opening settings probes the config file through the seam, which
        // is one announcement to wait for.
        try self.dispatch(if (state.palette) .palette_open else .palette_close);
        if (state.settings != self.app_state.model.settingsOpen) {
            const before = self.app_state.model.engineSequence.lo;
            try self.dispatch(if (state.settings) .settings_open else .settings_close);
            if (state.settings) try self.settle(before + 1, "READY");
        }
        try std.testing.expectEqual(state.tabs, self.app_state.model.tabs.len);
    }
};

// GUARD: ts-engine-boot
test "the core boots from the engine's snapshot, not from its own defaults" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    const model = rig.app_state.model;
    try std.testing.expect(model.engineConnected);
    try std.testing.expectEqual(@as(usize, 1), model.tabs.len);
    try std.testing.expect(model.tabs[0].id != 0);
    try std.testing.expectEqual(@as(i64, 1), model.engineRevision.lo);
}

// GUARD: ts-engine-intent
test "an intent moves the engine and the core resyncs to the new revision" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    const before = bridge.posts_accepted;

    try rig.dispatch(.new_terminal);
    try std.testing.expectEqual(before + 1, bridge.posts_accepted);
    try std.testing.expectEqual(@as(usize, 2), bridge.engine.?.model.wsConst().tab_count);

    // The announcement, the re-request and the completion each ride one
    // drain; the status walks SYNCING back to READY as they land.
    try rig.settle(1, "READY");
    const model = rig.app_state.model;
    try std.testing.expectEqual(@as(usize, 2), model.tabs.len);
    try std.testing.expectEqual(@as(i64, 1), model.selectedTab);
    try std.testing.expectEqual(@as(i64, 2), model.engineRevision.lo);
    try std.testing.expect(model.tabs[0].id != model.tabs[1].id);
}

// GUARD: ts-engine-fence
test "a stale intent is refused, announced, and surfaced instead of applied" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    const engine = bridge.engine.?;
    const host = bridge.binding();

    // Two tabs, so a close has something to do: against one tab the last-tab
    // rule refuses it for its own reason and the fence is never exercised.
    try rig.dispatch(.new_terminal);
    try rig.settle(1, "READY");
    try std.testing.expectEqual(@as(usize, 2), engine.model.wsConst().tab_count);
    try std.testing.expectEqual(@as(u64, 2), engine.revision);

    // A close computed against revision 1, after the engine moved to 2: the
    // tab at index 0 may no longer be the one that close meant.
    const stale = protocol.encodeIntent(.{ .kind = .close_tab, .expected_revision = 1, .argument = 0 });
    host.send_fn(host.context, protocol.intent_command, &stale);
    try std.testing.expect(engine.intent_refused);
    try std.testing.expectEqual(@as(usize, 2), engine.model.wsConst().tab_count);
    try std.testing.expectEqual(@as(u64, 2), engine.revision);

    try rig.settle(2, "ACTION REFUSED");
    try std.testing.expectEqual(@as(usize, 2), rig.app_state.model.tabs.len);

    // The next well-fenced intent clears the refusal.
    try rig.dispatch(.toggle_tab_placement);
    try std.testing.expect(!engine.intent_refused);
    try rig.settle(3, "READY");
    try std.testing.expectEqual(core.TabPlacement.side, rig.app_state.model.tabPlacement);
}

// GUARD: ts-engine-keys
test "unclaimed keys and text reach the focused pane's outbound ring and never the core" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    const engine = bridge.engine.?;
    const pane = engine.model.provider.terminal(engine.model.focusedTerminalRef().?).?;
    try std.testing.expectEqual(@as(usize, 0), pane.outbound_len);

    // Through the platform, so the SDK's own widget-precedence routing is
    // what hands the input to the extension: nothing in the markup claims
    // typing, so committed text and a bare Enter fall through. No shell is
    // live in the rig, so the encoded bytes stay queued in the ring, which
    // is exactly where the shipping app parks them too.
    try rig.harness.runtime.dispatchPlatformEvent(rig.decorated, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .text_input,
        .text = "ls",
    } });
    try std.testing.expectEqual(@as(usize, 2), pane.outbound_len);
    try rig.harness.runtime.dispatchPlatformEvent(rig.decorated, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "Enter",
    } });
    try std.testing.expectEqual(@as(usize, 3), pane.outbound_len);

    // With an overlay open the same input is the core's, not the shell's.
    overlay_open = true;
    defer overlay_open = false;
    try rig.harness.runtime.dispatchPlatformEvent(rig.decorated, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .text_input,
        .text = "x",
    } });
    try std.testing.expectEqual(@as(usize, 3), pane.outbound_len);
}

// GUARD: ts-engine-shells
test "every registered pane gets exactly one shell request and a closed tab kills its own" {
    const Recorder = struct {
        spawned: usize = 0,
        killed: usize = 0,
        last_killed: u64 = 0,
        pub fn hostSend(_: *@This(), _: []const u8, _: []const u8) void {}
        pub fn ptySpawn(self: *@This(), _: anytype) void {
            self.spawned += 1;
        }
        pub fn ptyWrite(_: *@This(), _: u64, _: []const u8) bool {
            return false;
        }
        pub fn ptyResize(_: *@This(), _: u64, _: u16, _: u16) void {}
        pub fn ptyKill(self: *@This(), key: u64) void {
            self.killed += 1;
            self.last_killed = key;
        }
    };
    const engine = try Engine.create(std.testing.allocator, std.testing.io);
    defer engine.destroy();
    var fx = Recorder{};

    engine.spawnShells(&fx, shellEvent);
    engine.spawnShells(&fx, shellEvent);
    try std.testing.expectEqual(@as(usize, 1), fx.spawned);

    const open = protocol.encodeIntent(.{ .kind = .new_terminal, .expected_revision = 1, .argument = 0 });
    try std.testing.expect(engine.applyIntent(&open, &fx));
    engine.spawnShells(&fx, shellEvent);
    try std.testing.expectEqual(@as(usize, 2), fx.spawned);

    const second = engine.model.provider.terminal(engine.model.focusedTerminalRef().?).?;
    const second_key = second.pty_key;
    const close = protocol.encodeIntent(.{ .kind = .close_tab, .expected_revision = 2, .argument = 1 });
    try std.testing.expect(engine.applyIntent(&close, &fx));
    try std.testing.expectEqual(@as(usize, 1), fx.killed);
    try std.testing.expectEqual(second_key, fx.last_killed);
    engine.spawnShells(&fx, shellEvent);
    try std.testing.expectEqual(@as(usize, 2), fx.spawned);
}

// MEASURED: the cost of the route docs/DECISIONS.md chose by reuse. A full
// 80x24 grid of text painted as the chrome prefix, on the engine's model, the
// way every frame paints it. Print with:
//
//   zig build test -Dtypescript-spike=true -Dplatform=null -Dmeasure=true
//
// The number a media-surface leaf would have to beat is the per-paint time
// below plus the display-list decode it saves; the leaf route is not built,
// so this is the baseline half of that comparison, not the comparison.
test "MEASURED: the chrome-prefix paint of a full grid on the engine model" {
    const engine = try Engine.create(std.testing.allocator, std.testing.io);
    defer engine.destroy();
    const pane = engine.model.provider.terminal(engine.model.focusedTerminalRef().?).?;
    var line: [81]u8 = undefined;
    for (0..24) |row| {
        for (0..80) |col| line[col] = @intCast('!' + ((row * 7 + col) % 90));
        line[80] = '\n';
        pane.session.feed(&line);
    }
    pane.session.refreshScreenText();
    const size = native_sdk.geometry.SizeF.init(1100, 640);
    engine.model.ws().surface_size = size;
    engine.model.ws().surface_scale_factor = 2;
    const tokens = cockpit.projection.cockpitTokens(engine.model);

    const commands = try std.testing.allocator.alloc(canvas.CanvasCommand, cockpit.projection.chrome_command_envelope);
    defer std.testing.allocator.free(commands);
    // One warm paint measures the cell box and primes the painter's caches.
    var builder = canvas.Builder.init(commands);
    try engine.paint(&builder, size, tokens);
    const first = builder.displayList().commands.len;
    try std.testing.expect(first > 0);

    const iterations: usize = 200;
    const started = std.Io.Clock.awake.now(std.testing.io);
    for (0..iterations) |_| {
        builder.reset();
        try engine.paint(&builder, size, tokens);
    }
    const finished = std.Io.Clock.awake.now(std.testing.io);
    const total_ns: u64 = @intCast(finished.nanoseconds - started.nanoseconds);
    cockpit.measured.print(
        "\nMEASURED chrome_prefix_paint: grid=80x24 size=1100x640 scale=2 commands={d} paints={d} per_paint_us={d}\n",
        .{ first, iterations, total_ns / iterations / std.time.ns_per_us },
    );
}

// ------------------------------------------------------ parity harness
//
// What chrome_register_tests.zig is for the Zig chrome, for the markup tree:
// the compiled app.native is solved at every declared window size and
// density, in every chrome state the core can be in, and audited with the
// same toolkit audit the Zig ladder answers to. A finding is a real defect
// (overlap, a target under the WCAG floor, a widget off its grid), printed
// the way the Zig audit prints it. The engine's grids are painted beneath
// this tree and are not widgets; their geometry is the shipping painter's.

const CompiledChrome = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));

const parity_sizes = [_]native_sdk.geometry.SizeF{
    native_sdk.geometry.SizeF.init(900, 420),
    native_sdk.geometry.SizeF.init(1100, 640),
    native_sdk.geometry.SizeF.init(1680, 1000),
};

const ChromeState = struct {
    label: []const u8,
    placement: core.TabPlacement = .top,
    tabs: usize = 1,
    palette: bool = false,
    settings: bool = false,
};

const parity_states = [_]ChromeState{
    .{ .label = "one tab, strip" },
    .{ .label = "one tab, rail", .placement = .side },
    .{ .label = "full strip", .tabs = 16 },
    .{ .label = "full rail", .tabs = 16, .placement = .side },
    .{ .label = "palette over strip", .palette = true },
    .{ .label = "settings over rail", .settings = true, .placement = .side },
    .{ .label = "both overlays, full strip", .tabs = 16, .palette = true, .settings = true },
};

fn auditChromeAt(model: *const core.Model, size: native_sdk.geometry.SizeF, density: canvas.Density, label: []const u8) !usize {
    const arena_bytes = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(arena_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(arena_bytes);
    var ui = Adapter.Ui.init(fixed.allocator());

    var tokens = cockpit.projection.cockpitTokens(bridge.engine.?.model);
    tokens.density = density;
    const node = CompiledChrome.build(&ui, model);
    const tree = try ui.finalizeWithTokens(node, tokens);

    const nodes = try std.testing.allocator.alloc(canvas.WidgetLayoutNode, canvas.max_layout_audit_nodes);
    defer std.testing.allocator.free(nodes);
    const bounds = native_sdk.geometry.RectF.init(0, 0, size.width, size.height);
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, nodes);

    var storage: [canvas.max_layout_audit_findings]canvas.LayoutAuditFinding = undefined;
    const issues = canvas.auditWidgetLayout(layout, bounds, tokens, &storage);
    if (issues.total == 0) return 0;
    std.debug.print(
        "\nmarkup layout audit: {d} finding(s) in \"{s}\" at {d:.0}x{d:.0}, {s} density\n",
        .{ issues.total, label, size.width, size.height, @tagName(density) },
    );
    // The first three findings of a state say what is wrong; the rest of a
    // sixteen-tab overflow say it again.
    for (issues.findings, 0..) |finding, index| {
        if (index == 3) {
            std.debug.print("  - ... {d} more\n", .{issues.findings.len - 3});
            break;
        }
        var message: [1400]u8 = undefined;
        var writer = std.Io.Writer.fixed(&message);
        canvas.formatLayoutAuditFinding(layout, finding, &writer) catch {};
        std.debug.print("  - {s}\n", .{writer.buffered()});
    }
    return issues.total;
}

// GUARD: ts-chrome-parity
test "the markup chrome passes the layout audit at every declared size, density and state" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    var total: usize = 0;
    for (parity_states) |state| {
        try rig.reach(state);
        for (parity_sizes) |size| {
            try rig.resize(size);
            for ([_]canvas.Density{ .compact, .regular, .spacious }) |density| {
                total += try auditChromeAt(&rig.app_state.model, size, density, state.label);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), total);
}

// GUARD: ts-overlay-switcher
test "the switcher filters the engine's tabs by position or title and selects through the seam" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    try rig.reach(.{ .label = "three tabs", .tabs = 3 });
    const engine = bridge.engine.?;

    try rig.dispatch(.palette_open);
    try std.testing.expectEqual(@as(usize, 3), rig.app_state.model.paletteRows.len);
    try rig.dispatch(.{ .palette_edit = .{ .insert_text = "3" } });
    try std.testing.expectEqual(@as(usize, 1), rig.app_state.model.paletteRows.len);
    try std.testing.expectEqual(@as(i64, 2), rig.app_state.model.paletteRows[0].index);

    // Enter on the input is its own on-submit; the core sends a fenced
    // select intent and the engine's selection moves.
    const before = rig.app_state.model.engineSequence.lo;
    try rig.dispatch(.palette_submit);
    try std.testing.expect(!rig.app_state.model.paletteOpen);
    try rig.settle(before + 1, "READY");
    try std.testing.expectEqual(@as(usize, 2), engine.model.wsConst().selected_tab);
    try std.testing.expectEqual(@as(i64, 2), rig.app_state.model.selectedTab);
}

// GUARD: ts-overlay-settings
test "the settings surface shows the engine's theme catalog and saves through the seam" {
    var rig = try Rig.start();
    defer rig.stop();
    try rig.settle(0, "READY");
    const engine = bridge.engine.?;

    // Opening probes the config file once, through the seam; the catalog
    // rides every snapshot.
    const before = rig.app_state.model.engineSequence.lo;
    try rig.dispatch(.settings_open);
    try rig.settle(before + 1, "READY");
    try std.testing.expect(engine.config_probe.probed);
    try std.testing.expectEqual(@as(usize, 6), rig.app_state.model.themes.len);
    try std.testing.expect(rig.app_state.model.configNotice.len > 0);

    try rig.dispatch(.{ .settings_pick = 3 });
    try std.testing.expect(rig.app_state.model.themes[3].highlighted);
    const before_save = rig.app_state.model.engineSequence.lo;
    try rig.dispatch(.settings_commit);
    try std.testing.expect(!rig.app_state.model.settingsOpen);
    try rig.settle(before_save + 1, "READY");
    try std.testing.expectEqualStrings("nord", engine.model.config.theme.slice());
    try std.testing.expect(rig.app_state.model.themes[3].active);
}
