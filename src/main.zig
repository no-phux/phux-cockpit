//! Native spatial cockpit composition root.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const grid = @import("terminal/grid.zig");

const support = @import("cockpit/phux_support.zig");
const local = @import("providers/local/provider.zig");
const topology = @import("cockpit/topology.zig");
const layout = @import("cockpit/layout.zig");
const model_module = @import("cockpit/model.zig");
const app_types = @import("cockpit/app_types.zig");
const runtime = @import("cockpit/terminal_runtime.zig");
const projection = @import("cockpit/native/workspace_projection.zig");
const pointer = @import("cockpit/pointer_input.zig");
const update_module = @import("cockpit/update.zig");
const scene = @import("cockpit/native/scene.zig");
const view_module = @import("cockpit/native/view.zig");
const host = @import("cockpit/native/host.zig");
const config_module = @import("config/config.zig");

const geometry = native_sdk.geometry;

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

pub const ProviderId = support.ProviderId;
pub const LocalTerminalId = support.LocalTerminalId;
pub const RemoteTerminalId = support.RemoteTerminalId;
pub const TerminalId = support.TerminalId;
pub const TerminalRef = support.TerminalRef;
pub const Generation = support.Generation;
pub const ReplicaOwner = support.ReplicaOwner;
pub const PixelSize = support.PixelSize;
pub const Viewport = support.Viewport;
pub const KeyAction = support.KeyAction;
pub const PhysicalKey = support.PhysicalKey;
pub const ModifierMask = support.ModifierMask;
pub const KeyInput = support.KeyInput;
pub const MouseAction = support.MouseAction;
pub const MouseButton = support.MouseButton;
pub const MouseInput = support.MouseInput;
pub const ScrollKind = support.ScrollKind;
pub const Scroll = support.Scroll;
pub const Presentation = support.Presentation;
pub const Phase = support.Phase;
pub const PhuxProvider = support.PhuxProvider;
pub const ProviderKind = support.ProviderKind;
pub const phux_enabled = support.phux_enabled;
pub const phux_channel_key = support.phux_channel_key;
pub const pointer_channel_key = support.pointer_channel_key;
pub const max_remote_terminals = support.max_remote_terminals;
pub const providerKind = support.providerKind;
pub const localRef = support.localRef;
pub const refEql = support.refEql;
pub const localId = @import("provider_contract").localId;

pub const Pane = local.Pane;
pub const LocalProvider = local.LocalProvider;
pub const Provider = local.Provider;
pub const max_terminals = local.max_terminals;
pub const max_tabs = topology.max_tabs;
pub const max_panes_per_tab = layout.max_panes;
pub const clipboard_key = local.clipboard_key;
pub const paste_clipboard_key = local.paste_clipboard_key;
pub const outbound_buffer_bytes = local.outbound_buffer_bytes;
pub const initialTerminalId = local.initialTerminalId;
pub const initialTerminalRef = local.initialTerminalRef;
pub const ptyKey = local.ptyKey;
pub const paneArgv = local.paneArgv;

pub const TabPlacement = topology.TabPlacement;
pub const SurfaceSelection = topology.SurfaceSelection;
pub const SnapshotSelection = topology.SnapshotSelection;
pub const SnapshotTab = topology.SnapshotTab;
pub const SnapshotNode = topology.SnapshotNode;
pub const TopologySnapshot = topology.TopologySnapshot;
pub const LegacyTopologySnapshotV0 = topology.LegacyTopologySnapshotV0;
pub const LegacyTopologySnapshotV1 = topology.LegacyTopologySnapshotV1;
pub const PersistedTopologySnapshot = topology.PersistedTopologySnapshot;
pub const singleLeafTab = topology.singleLeafTab;
pub const Tree = layout.Tree;
pub const Kind = layout.Kind;
pub const LayoutNodeId = layout.NodeId;
pub const layout_none = layout.none;
pub const Orientation = layout.Orientation;
pub const Direction = layout.Direction;
pub const LayoutPane = layout.Pane;
pub const topology_snapshot_version = topology.topology_snapshot_version;
pub const process_restoration_supported = topology.process_restoration_supported;
pub const migrateTopologySnapshot = topology.migrateTopologySnapshot;

pub const PointerModifiers = model_module.PointerModifiers;
pub const TerminalPointerEvent = model_module.TerminalPointerEvent;
pub const PointerDragMode = model_module.PointerDragMode;
pub const PointerCapture = model_module.PointerCapture;
pub const BrowserPage = model_module.BrowserPage;
pub const Model = model_module.Model;
pub const reconcileRemoteRefs = model_module.reconcileRemoteRefs;
pub const initialModelWithPhux = model_module.initialModelWithPhux;
pub const initialModel = model_module.initialModel;
pub const attachPhuxProvider = model_module.attachPhuxProvider;
pub const initialModelWithIo = model_module.initialModelWithIo;
pub const initialProductionModelWithIo = model_module.initialProductionModelWithIo;
pub const restoreModel = model_module.restoreModel;
pub const deinitModel = model_module.deinitModel;

pub const Msg = app_types.Msg;
pub const TerminalApp = app_types.TerminalApp;
pub const Fx = app_types.Fx;

pub const moveResponsesToOutbound = runtime.moveResponsesToOutbound;
pub const update = update_module.update;
pub const remoteFocusTarget = update_module.remoteFocusTarget;

pub const header_height = projection.header_height;
pub const side_rail_width = projection.side_rail_width;
pub const side_rail_gap = projection.side_rail_gap;
pub const side_tab_height = projection.side_tab_height;
pub const split_divider_width = projection.split_divider_width;
pub const split_pane_min_width = projection.split_pane_min_width;
pub const split_pane_min_height = projection.split_pane_min_height;
pub const webkit_parking_extent = projection.webkit_parking_extent;
pub const chrome_command_envelope = projection.chrome_command_envelope;
pub const cockpitTokens = projection.cockpitTokens;
pub const terminalTokens = projection.terminalTokens;
pub const terminalTokensFrom = projection.terminalTokensFrom;
pub const windowPadding = projection.windowPadding;
pub const chromeRevealed = projection.chromeRevealed;
pub const workspaceChrome = projection.workspaceChrome;
pub const resolvePanes = projection.resolvePanes;
pub const paneFrames = projection.paneFrames;
pub const paneAtPoint = projection.paneAtPoint;
pub const paneFrameFor = projection.paneFrameFor;
pub const tabTriggerHeight = projection.tabTriggerHeight;
pub const TabWindow = projection.TabWindow;
pub const visibleTabWindow = projection.visibleTabWindow;
pub const tab_extent = projection.tab_extent;
pub const tab_min_extent = projection.tab_min_extent;
pub const pane_dim_command_id_base = view_module.pane_dim_command_id_base;
pub const terminalNeedsAttention = projection.terminalNeedsAttention;

pub const canvas_label = scene.canvas_label;
pub const webview_label = scene.webview_label;
pub const webview_anchor = scene.webview_anchor;
pub const app_name = scene.app_name;
pub const bundle_id = scene.bundle_id;
pub const main_window_label = scene.main_window_label;
pub const window_min_width = scene.window_min_width;
pub const window_min_height = scene.window_min_height;
pub const web_origins = scene.web_origins;
pub const cockpit_shortcuts = scene.cockpit_shortcuts;
pub const cockpit_menus = scene.cockpit_menus;
pub const shell_scene = scene.shell_scene;

pub const Config = config_module.Config;
pub const ConfigTabPlacement = config_module.TabPlacement;
pub const configPath = config_module.joinPath;
pub const parseConfig = config_module.parse;
pub const loadConfigOrDefault = config_module.loadOrDefault;
pub const paneArgvIn = local.paneArgvIn;
pub const CwdArgv = local.CwdArgv;

pub const view = view_module.view;
pub const webPanes = view_module.webPanes;
pub const onCommand = view_module.onCommand;
pub const tabPlacementFromText = view_module.tabPlacementFromText;
pub const onTimer = view_module.onTimer;
pub const CockpitHost = host.CockpitHost;

pub const selection_autoscroll_timer_id = app_types.selection_autoscroll_timer_id;
const terminal_font_id = scene.terminal_font_id;
const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };

pub fn appOptions() TerminalApp.Options {
    return .{
        .name = app_name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .tokens_fn = cockpitTokens,
        .fonts = &scene.cockpit_fonts,
        .init_fx = update_module.initFx,
        .update_fx = update,
        .view = view,
        .on_key = update_module.onKey,
        .key_release_events = true,
        .on_text = update_module.onText,
        .on_wheel = update_module.onWheel,
        .on_timer = view_module.onTimer,
        .on_chrome = update_module.onChrome,
        .on_lifecycle = update_module.onLifecycle,
        .on_frame = view_module.onFrame,
        .web_panes = webPanes,
        .on_command = onCommand,
        .chrome = .{
            .prefix_commands = chrome_command_envelope,
            .variable_prefix = true,
            .build = view_module.buildChrome,
        },
    };
}

fn createConfiguredPhuxProvider(init: std.process.Init) !?*PhuxProvider {
    if (comptime !phux_enabled) return null;
    var socket_storage: [std.fs.max_path_bytes]u8 = undefined;
    const socket_path = init.environ_map.get("PHUX_SOCKET") orelse blk: {
        if (init.environ_map.get("XDG_RUNTIME_DIR")) |runtime_dir| {
            break :blk try std.fmt.bufPrint(&socket_storage, "{s}/phux/phux.sock", .{runtime_dir});
        }
        const uid_segment = init.environ_map.get("UID") orelse init.environ_map.get("USER") orelse "default";
        break :blk try std.fmt.bufPrint(&socket_storage, "/tmp/phux-{s}/phux.sock", .{uid_segment});
    };
    const session = init.environ_map.get("PHUX_SESSION") orelse "default";
    return try PhuxProvider.create(std.heap.page_allocator, init.io, .{ .unix = socket_path }, session, "phux-cockpit");
}

/// Where the config file lives, resolved through the SDK's `app_dirs`
/// primitive so the platform owns the rule (macOS:
/// `~/Library/Preferences/Phux Cockpit/config`). `PHUX_COCKPIT_CONFIG` names
/// a file directly and wins — that is the seam a test, a second profile, or a
/// `--config` wrapper uses, and it costs one env read.
///
/// Returns null when the platform has no home to resolve against, which is a
/// silent fall back to defaults, never an error: a terminal that refuses to
/// start because it could not find a file the user never wrote is broken.
pub fn resolveConfigPath(env: native_sdk.app_dirs.Env, override_path: ?[]const u8, dir_storage: []u8, path_storage: []u8) ?[]const u8 {
    if (override_path) |explicit| {
        if (explicit.len == 0 or explicit.len > path_storage.len) return null;
        @memcpy(path_storage[0..explicit.len], explicit);
        return path_storage[0..explicit.len];
    }
    const dir = native_sdk.app_dirs.resolveOne(
        .{ .name = app_name },
        native_sdk.app_dirs.currentPlatform(),
        env,
        .config,
        dir_storage,
    ) catch return null;
    return config_module.joinPath(dir, path_storage) catch null;
}

/// The dotfile location: `$XDG_CONFIG_HOME/phux-cockpit/config`, else
/// `~/.config/phux-cockpit/config`.
///
/// `app_dirs` follows each platform's own convention, which on macOS means
/// `~/Library/Preferences/Phux Cockpit/`. That is correct for a Mac app and
/// wrong for this audience: the people most likely to write a config here are
/// arriving from Ghostty, and they will put the file in `~/.config` without
/// looking it up. Checking here FIRST costs one stat and removes an entire
/// class of "my config does nothing" confusion. The platform path still works,
/// so nothing is taken away.
pub fn resolveDotfileConfigPath(env: native_sdk.app_dirs.Env, path_storage: []u8) ?[]const u8 {
    var joined: [std.fs.max_path_bytes]u8 = undefined;
    const base = if (env.xdg_config_home) |xdg| blk: {
        if (xdg.len == 0) break :blk null;
        break :blk xdg;
    } else null;
    const dir = if (base) |explicit|
        config_module.joinDir(explicit, "phux-cockpit", &joined) catch return null
    else dir: {
        const home = env.home orelse return null;
        if (home.len == 0) return null;
        var home_config: [std.fs.max_path_bytes]u8 = undefined;
        const dotconfig = config_module.joinDir(home, ".config", &home_config) catch return null;
        break :dir config_module.joinDir(dotconfig, "phux-cockpit", &joined) catch return null;
    };
    return config_module.joinPath(dir, path_storage) catch null;
}

/// Read and parse the user's config. Every failure — no home, no file, an
/// unreadable file, a file larger than the ceiling — lands on defaults, and a
/// malformed LINE is already a diagnostic rather than a failure inside the
/// parser. There is exactly one way this function does not produce a usable
/// Config, and that is never.
fn loadUserConfig(io: std.Io, init: std.process.Init) Config {
    var dir_storage: [std.fs.max_path_bytes]u8 = undefined;
    var path_storage: [std.fs.max_path_bytes]u8 = undefined;
    var dotfile_storage: [std.fs.max_path_bytes]u8 = undefined;
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const override = init.environ_map.get("PHUX_COCKPIT_CONFIG");

    // An explicit override answers on its own. Otherwise the dotfile location
    // is tried first and the platform location second — first file that opens
    // wins, so someone who has never heard of `~/Library/Preferences` and
    // someone who expects a Mac app to live there are both right.
    if (override) |explicit| {
        if (readConfig(io, explicit)) |parsed| return parsed;
        return .{};
    }
    if (resolveDotfileConfigPath(env, &dotfile_storage)) |dotfile| {
        if (readConfig(io, dotfile)) |parsed| return parsed;
    }
    const path = resolveConfigPath(env, null, &dir_storage, &path_storage) orelse return .{};
    return readConfig(io, path) orelse .{};
}

/// Read and parse one candidate. Null means "there was no usable file here",
/// which is the normal case for every location but one and must never be an
/// error.
fn readConfig(io: std.Io, path: []const u8) ?Config {
    var bytes: [config_module.max_config_bytes]u8 = undefined;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    // A config longer than the ceiling is TRUNCATED, not refused: the bytes
    // that fit are a prefix of whole lines plus at most one partial one, and a
    // partial line is a diagnostic. Refusing the whole file would drop every
    // valid setting above it.
    const read = file.readPositionalAll(io, &bytes, 0) catch return null;
    return config_module.loadOrDefault(bytes[0..read]);
}

pub fn main(init: std.process.Init) !void {
    const session = try grid.Session.create(std.heap.page_allocator, init.io, 80, 24);
    const remote_provider = createConfiguredPhuxProvider(init) catch |err| {
        session.destroy();
        return err;
    };
    var model = initialProductionModelWithIo(std.heap.page_allocator, init.io, session) catch |err| {
        session.destroy();
        if (remote_provider) |remote| remote.destroy();
        return err;
    };
    model.config = loadUserConfig(init.io, init);
    model.tab_placement = switch (model.config.tab_placement) {
        .top => .top,
        .side => .side,
    };
    // The env override stays and stays LAST: it is the debugging knob, and a
    // knob that a config file could silently disable would not be one.
    if (init.environ_map.get("PHUX_COCKPIT_TABS")) |value| {
        if (tabPlacementFromText(value)) |placement| model.tab_placement = placement;
    }
    attachPhuxProvider(&model, remote_provider);
    defer deinitModel(&model);
    const app_state = try std.heap.page_allocator.create(CockpitHost);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.init(std.heap.page_allocator, model, appOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = app_name,
        .window_title = app_name,
        .bundle_id = bundle_id,
        .default_frame = geometry.RectF.init(0, 0, scene.window_width, scene.window_height),
        .restore_state = false,
        .js_window_api = false,
        .shortcuts = &cockpit_shortcuts,
        .menus = &cockpit_menus,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{
                .allowed_origins = &web_origins,
                .external_links = .{ .action = .deny },
            },
        },
    }, init);
}

test "tab placement configuration accepts only documented values" {
    try std.testing.expectEqual(TabPlacement.top, tabPlacementFromText("top").?);
    try std.testing.expectEqual(TabPlacement.side, tabPlacementFromText("side").?);
    try std.testing.expectEqual(TabPlacement.side, tabPlacementFromText("SIDEBAR").?);
    try std.testing.expectEqual(@as(?TabPlacement, null), tabPlacementFromText("left"));
}

test "the terminal face is bundled and selected by the design tokens" {
    const options = appOptions();
    try std.testing.expectEqual(@as(usize, 1), options.fonts.len);
    try std.testing.expectEqual(terminal_font_id, options.fonts[0].id);
    try std.testing.expectEqualStrings("JetBrainsMonoNL Nerd Font Mono Regular", options.fonts[0].name);
    try std.testing.expect(options.fonts[0].ttf.len > 4);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0 }, options.fonts[0].ttf[0..4]);
    var unused_model: Model = undefined;
    try std.testing.expectEqual(terminal_font_id, cockpitTokens(&unused_model).typography.mono_font_id);
}

test "AppKit pointer buttons map to provider mouse buttons" {
    try std.testing.expectEqual(MouseButton.left, pointer.pointerButton(0));
    try std.testing.expectEqual(MouseButton.right, pointer.pointerButton(1));
    try std.testing.expectEqual(MouseButton.middle, pointer.pointerButton(2));
    try std.testing.expectEqual(MouseButton.button_4, pointer.pointerButton(3));
    try std.testing.expectEqual(MouseButton.button_5, pointer.pointerButton(4));
    try std.testing.expectEqual(MouseButton.none, pointer.pointerButton(std.math.maxInt(u32)));
}

test {
    _ = @import("tests/app_contract_tests.zig");
    _ = @import("tests/grid_state_tests.zig");
    _ = @import("tests/grid_rendering_tests.zig");
    _ = @import("tests/cell_attribute_tests.zig");
    _ = @import("tests/provider_identity_tests.zig");
    _ = @import("tests/terminal_keyboard_tests.zig");
    _ = @import("tests/clipboard_tests.zig");
    _ = @import("tests/outbound_io_tests.zig");
    _ = @import("tests/terminal_lifecycle_tests.zig");
    _ = @import("tests/record_replay_tests.zig");
    _ = @import("tests/terminal_registry_tests.zig");
    _ = @import("tests/topology_persistence_tests.zig");
    _ = @import("tests/workspace_layout_tests.zig");
    _ = @import("tests/workspace_chrome_accessibility_tests.zig");
    _ = @import("tests/surface_routing_tests.zig");
    _ = @import("tests/pointer_selection_tests.zig");
    _ = @import("tests/mouse_protocol_tests.zig");
    _ = @import("tests/adversarial_isolation_tests.zig");
    _ = @import("tests/layout_tree_tests.zig");
    _ = @import("tests/config_tests.zig");
    _ = @import("tests/shell_identity_tests.zig");
    _ = @import("tests/config_wiring_tests.zig");
    _ = @import("tests/tab_strip_tests.zig");
}
