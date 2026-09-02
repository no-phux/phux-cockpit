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
fn onKey(event: canvas.WidgetKeyboardEvent) ?core.Msg {
    if (overlay_open) return null;
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

fn onFrame(_: *const core.Model, frame: native_sdk.platform.GpuFrame) ?core.Msg {
    const engine = bridge.engine orelse return null;
    const fx = bridge.effects orelse return null;
    bridge.spawnShells(engine, fx);
    engine.pumpViewports(fx, frame);
    return null;
}

fn paintChrome(model: *const core.Model, builder: *canvas.Builder, size: native_sdk.geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    overlay_open = model.paletteOpen or model.settingsOpen;
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
        try self.app_state.dispatch(&self.harness.runtime, 1, msg);
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
