//! Native spatial cockpit composition root.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const grid = @import("terminal/grid.zig");

const support = @import("cockpit/phux_support.zig");
const local = @import("providers/local/provider.zig");
const topology = @import("cockpit/topology.zig");
const model_module = @import("cockpit/model.zig");
const app_types = @import("cockpit/app_types.zig");
const runtime = @import("cockpit/terminal_runtime.zig");
const projection = @import("cockpit/native/workspace_projection.zig");
const pointer = @import("cockpit/pointer_input.zig");
const update_module = @import("cockpit/update.zig");
const scene = @import("cockpit/native/scene.zig");
const view_module = @import("cockpit/native/view.zig");
const host = @import("cockpit/native/host.zig");

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

pub const Pane = local.Pane;
pub const LocalProvider = local.LocalProvider;
pub const Provider = local.Provider;
pub const pane_count = local.pane_count;
pub const max_terminal_count = local.max_terminal_count;
pub const clipboard_key = local.clipboard_key;
pub const paste_clipboard_key = local.paste_clipboard_key;
pub const outbound_buffer_bytes = local.outbound_buffer_bytes;
pub const initialTerminalId = local.initialTerminalId;
pub const initialTerminalRef = local.initialTerminalRef;
pub const ptyKey = local.ptyKey;
pub const paneArgv = local.paneArgv;

pub const TabPlacement = topology.TabPlacement;
pub const LayoutMode = topology.LayoutMode;
pub const Placement = topology.Placement;
pub const SurfaceSelection = topology.SurfaceSelection;
pub const SnapshotSelection = topology.SnapshotSelection;
pub const TopologySnapshot = topology.TopologySnapshot;
pub const LegacyTopologySnapshotV0 = topology.LegacyTopologySnapshotV0;
pub const PersistedTopologySnapshot = topology.PersistedTopologySnapshot;
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
pub const split_pane_header_height = projection.split_pane_header_height;
pub const webkit_parking_extent = projection.webkit_parking_extent;
pub const chrome_command_envelope = projection.chrome_command_envelope;
pub const cockpitTokens = projection.cockpitTokens;
pub const chromeRevealed = projection.chromeRevealed;
pub const paneFrames = projection.paneFrames;

pub const canvas_label = scene.canvas_label;
pub const webview_label = scene.webview_label;
pub const webview_anchor = scene.webview_anchor;
pub const app_name = scene.app_name;
pub const bundle_id = scene.bundle_id;
pub const window_min_width = scene.window_min_width;
pub const window_min_height = scene.window_min_height;
pub const web_origins = scene.web_origins;
pub const cockpit_shortcuts = scene.cockpit_shortcuts;
pub const shell_scene = scene.shell_scene;

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
}
