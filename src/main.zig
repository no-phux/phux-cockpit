//! Native spatial cockpit over terminal and web surfaces. The pty
//! effect vocabulary owns the transport (`fx.ptySpawn` and friends),
//! libghostty-vt owns cell state, damage, scrollback, and selection, and
//! the canvas paints the viewport as real text — theme-mapped ANSI-16,
//! exact 256-color and truecolor. Record a session and it replays
//! byte-identical offline: no shell runs, the journaled output batches
//! (bytes in the session blob store) and exit ARE the session.
//!
//! Keyboard-first by design: typing goes to the pty (committed text via
//! the IME-correct text channel; chords and specials through the
//! emulator's key encoder, so application cursor-key modes hold).
//! cmd/ctrl+shift+space arms cell selection (arrows move, shift+arrows
//! extend, B toggles block/line, cmd/ctrl+C copies, escape clears),
//! cmd/ctrl+V safely pastes the system clipboard into the pane that
//! requested it, and cmd/ctrl+arrows page the scrollback.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const grid = @import("grid.zig");
const provider_contract = @import("provider_contract");
const phux_options = @import("phux_options");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "phux-cockpit-canvas";
pub const webview_label = "phux-cockpit-web";
pub const webview_anchor = "phux-cockpit-web-pane";
pub const app_name = "Phux Cockpit";
pub const bundle_id = "dev.phux.cockpit";
const window_width: f32 = 1100;
const window_height: f32 = 640;
pub const window_min_width: f32 = 900;
pub const window_min_height: f32 = 420;

/// The grid's padding inside the window.
const grid_inset: f32 = 8;

/// The tab and control band, when it is present at all.
///
/// Cockpit at rest is a TERMINAL, not an application frame around one: a
/// single healthy terminal gets the whole content area and no band. The band
/// emerges when the workspace actually has structure to show — a second
/// terminal, a split, the Web surface, or a terminal that needs attention —
/// and retracts when that structure goes away. See `chromeRevealed`.
///
/// Reveal is driven only by DISCRETE state the operator caused. Nothing
/// incidental (a pointer passing near the top edge, a transient repaint) may
/// move this band: every change to it reflows the content area and resizes a
/// live PTY, and a terminal that reflows under the cursor is the exact jank
/// this design exists to remove.
pub const header_height: f32 = 40;
pub const side_rail_width: f32 = 184;
pub const side_rail_gap: f32 = 8;
pub const side_tab_height: f32 = 34;
pub const split_divider_width: f32 = 9;
pub const split_pane_min_width: f32 = 240;
pub const split_pane_header_height: f32 = 24;

/// WebKit has no non-destructive hidden state in native-sdk v0.7.1. Keep its
/// live view parked on this inert one-point anchor while a terminal is shown.
pub const webkit_parking_extent: f32 = 1;

/// At most two terminals are attached to visible placements. The provider
/// registry can own four independent PTYs, matching native-sdk's hard limit.
pub const pane_count: usize = 2;
pub const max_terminal_count: usize = 4;

pub const ProviderId = provider_contract.ProviderId;
pub const LocalTerminalId = provider_contract.LocalTerminalId;
pub const RemoteTerminalId = provider_contract.RemoteTerminalId;
pub const TerminalId = provider_contract.TerminalId;
pub const TerminalRef = provider_contract.TerminalRef;
pub const Generation = provider_contract.Generation;
pub const ReplicaOwner = provider_contract.ReplicaOwner;
pub const PixelSize = provider_contract.PixelSize;
pub const Viewport = provider_contract.Viewport;
pub const KeyAction = provider_contract.KeyAction;
pub const PhysicalKey = provider_contract.PhysicalKey;
pub const ModifierMask = provider_contract.ModifierMask;
pub const KeyInput = provider_contract.KeyInput;
pub const MouseAction = provider_contract.MouseAction;
pub const MouseButton = provider_contract.MouseButton;
pub const MouseInput = provider_contract.MouseInput;
pub const ScrollKind = provider_contract.ScrollKind;
pub const Scroll = provider_contract.Scroll;
pub const Presentation = provider_contract.Presentation;

/// The optional provider module is selected by build configuration. Merely
/// importing this boolean in the default lane brings in no C ABI or archive.
pub const phux_enabled = phux_options.enabled;

const DisabledPhuxProvider = struct {
    const State = enum { new };
    const Anchor = struct { opaque_id: u64 = 0 };
    const SyncDelta = struct {
        ready_published: bool = false,
        generation_changed: bool = false,
        detached: bool = false,
        added_count: usize = 0,
        removed_count: usize = 0,
    };

    fn create(
        _: std.mem.Allocator,
        _: std.Io,
        _: anytype,
        _: []const u8,
        _: []const u8,
    ) error{Disabled}!*DisabledPhuxProvider {
        return error.Disabled;
    }
    fn destroy(_: *DisabledPhuxProvider) void {}
    fn open(_: *DisabledPhuxProvider, _: native_sdk.ChannelHandle) error{Disabled}!void {
        return error.Disabled;
    }
    fn reconnect(_: *DisabledPhuxProvider, _: native_sdk.ChannelHandle) error{Disabled}!void {
        return error.Disabled;
    }
    fn stop(_: *DisabledPhuxProvider) void {}
    fn state(_: *const DisabledPhuxProvider) State {
        return .new;
    }
    fn drainReadiness(_: *DisabledPhuxProvider) error{Disabled}!SyncDelta {
        return error.Disabled;
    }
    fn terminalRefs(_: *const DisabledPhuxProvider, _: []TerminalRef) usize {
        return 0;
    }
    fn contains(_: *const DisabledPhuxProvider, _: TerminalRef) bool {
        return false;
    }
    fn owner(_: *const DisabledPhuxProvider, _: TerminalRef) ?ReplicaOwner {
        return null;
    }
    fn ownerIsCurrent(_: *const DisabledPhuxProvider, _: ReplicaOwner) bool {
        return false;
    }
    fn presentation(_: *const DisabledPhuxProvider, _: TerminalRef) ?Presentation {
        return null;
    }
    fn lastViewport(_: *const DisabledPhuxProvider, _: TerminalRef) ?Viewport {
        return null;
    }
    fn viewportResize(_: *DisabledPhuxProvider, _: TerminalRef, _: Viewport) error{Disabled}!void {
        return error.Disabled;
    }
    fn sendKey(_: *DisabledPhuxProvider, _: ReplicaOwner, _: *const KeyInput) error{Disabled}!void {
        return error.Disabled;
    }
    fn sendFocus(_: *DisabledPhuxProvider, _: ReplicaOwner, _: bool) error{Disabled}!void {
        return error.Disabled;
    }
    fn sendPaste(_: *DisabledPhuxProvider, _: ReplicaOwner, _: []const u8, _: bool) error{Disabled}!void {
        return error.Disabled;
    }
    fn scrollViewport(_: *DisabledPhuxProvider, _: ReplicaOwner, _: Scroll) error{Disabled}!void {
        return error.Disabled;
    }
    fn createAnchor(_: *DisabledPhuxProvider, _: ReplicaOwner, _: anytype) error{Disabled}!Anchor {
        return error.Disabled;
    }
    fn releaseAnchor(_: *DisabledPhuxProvider, _: ReplicaOwner, _: Anchor) void {}
    fn setSelection(_: *DisabledPhuxProvider, _: ReplicaOwner, _: Anchor, _: Anchor, _: bool) error{Disabled}!void {
        return error.Disabled;
    }
    fn clearSelection(_: *DisabledPhuxProvider, _: ReplicaOwner) error{Disabled}!void {
        return error.Disabled;
    }
    fn selectionText(_: *DisabledPhuxProvider, _: ReplicaOwner, _: std.mem.Allocator) error{Disabled}![]u8 {
        return error.Disabled;
    }
};

pub const PhuxProvider = if (phux_enabled)
    @import("phux_provider").PhuxProvider
else
    DisabledPhuxProvider;
const DisabledPointerModule = struct {
    pub const EventQueue = struct {};
    pub const Monitor = struct {};
};
const pointer_module = if (phux_enabled) @import("phux_pointer") else DisabledPointerModule;

pub const phux_channel_key: u64 = 102;
pub const pointer_channel_key: u64 = 103;
pub const max_remote_terminals: usize = 64;

pub const ProviderKind = enum { local, phux };

/// Tab placement changes presentation only, never terminal identity, provider
/// ownership, attachments, or process lifetime.
pub const TabPlacement = enum { top, side };

pub fn providerKind(terminal_ref: TerminalRef) ProviderKind {
    return if (terminal_ref.provider_id == .local) .local else .phux;
}

/// The local registry mints durable ids by counting up from the first
/// well-known local identity, so a created terminal never reuses a closed
/// terminal's identity inside one process.
const first_terminal_raw: u64 = @intFromEnum(LocalTerminalId.terminal_1);

/// Topology-level identity helpers. The dynamic registry is keyed by
/// `LocalTerminalId`; everything above it — tab order, attachments,
/// selection, pointer capture — stores provider-qualified `TerminalRef`
/// so a Phux terminal occupies the same product structure as a local one.
pub fn localRef(id: LocalTerminalId) TerminalRef {
    return provider_contract.localTerminalRef(id);
}

pub fn refEql(a: TerminalRef, b: TerminalRef) bool {
    return a.eql(b);
}

fn optRefEql(a: ?TerminalRef, b: ?TerminalRef) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn optOwnerEql(a: ?ReplicaOwner, b: ?ReplicaOwner) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

const max_held_terminal_keys: usize = 16;
const max_pointer_captures: usize = 8;
const max_mouse_reports_per_event: usize = 64;
pub const selection_autoscroll_timer_id: u64 = 1;
const selection_autoscroll_interval_ns: u64 = 15 * std.time.ns_per_ms;
const max_mouse_coordinate: f32 = 1_000_000;

const HeldTerminalKey = struct {
    fingerprint: u64 = 0,
    owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
};
/// The NSEvent-monitor capture used by the remote (Phux) pointer path. It is
/// deliberately distinct from `PointerCapture`, which owns the routed
/// canvas-widget pointer stream for local terminals.
const MonitorPointerCapture = struct {
    owner: ReplicaOwner,
    button: MouseButton,
};

const PointerState = struct {
    queue: pointer_module.EventQueue = .{},
    monitor: ?pointer_module.Monitor = null,
    capture: ?MonitorPointerCapture = null,
    last_x: f64 = 0,
    last_y: f64 = 0,
};

const RemoteUiState = struct {
    terminal_ref: ?TerminalRef = null,
    owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
    selecting: bool = false,
    rectangle: bool = false,
    start_anchor: u64 = 0,
    end_anchor: u64 = 0,
    head_x: u16 = 0,
    head_y: u32 = 0,
    copied_bytes: u64 = 0,
    copy_failed: bool = false,
    wheel_accum: f32 = 0,
};

pub const PointerModifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const TerminalPointerEvent = struct {
    window_id: native_sdk.platform.WindowId = 1,
    terminal_id: LocalTerminalId,
    generation: u64,
    phase: canvas.WidgetPointerPhase,
    pointer_id: u64 = 0,
    button: i32 = 0,
    click_count: u8 = 1,
    point: geometry.PointF,
    frame: geometry.RectF,
    delta: geometry.OffsetF = .{},
    modifiers: PointerModifiers = .{},
};

pub const PointerDragMode = enum { local_selection, mouse_report };

pub const PointerCapture = struct {
    active: bool = false,
    window_id: native_sdk.platform.WindowId = 0,
    terminal_id: LocalTerminalId,
    generation: u64 = 0,
    pointer_id: u64 = 0,
    button: i32 = 0,
    mode: PointerDragMode = .local_selection,
    mouse_protocol_fingerprint: u8 = 0,
    frame: geometry.RectF = .{},
    last_point: geometry.PointF = .{},
    modifiers: PointerModifiers = .{},
};

/// Fixed UI slots in the current two-pane cockpit. Attachments map these
/// placements to durable terminal identities; placement does not own lifetime.
pub const Placement = enum(u8) {
    primary,
    secondary,

    pub fn index(placement: Placement) usize {
        return @intFromEnum(placement);
    }

    pub fn fromIndex(raw_index: usize) ?Placement {
        return switch (raw_index) {
            0 => .primary,
            1 => .secondary,
            else => null,
        };
    }
};

pub fn initialTerminalId(index: usize) LocalTerminalId {
    return provider_contract.localTerminalId(index);
}

pub fn initialTerminalRef(index: usize) TerminalRef {
    return provider_contract.localTerminalRefForIndex(index);
}

/// One keyed-effect space spans pty, clipboard, spawn, and fetch
/// (`effects.keyOccupiedUntilDelivery`), so pane, copy, and paste keys
/// must not collide. Pane i owns key 1+i; clipboard effects sit far clear
/// of them. Copy and paste use distinct keys so one direction can be in
/// flight without rejecting the other.
pub fn ptyKey(index: usize) u64 {
    return 1 + index;
}
pub const clipboard_key: u64 = 100;
pub const paste_clipboard_key: u64 = 101;

/// The selected terminal owns the complete retained-chrome envelope. Hidden
/// terminals ingest bytes but emit no display-list commands.
const widget_command_reserve: usize = canvas.terminal_grid.widget_command_reserve;
pub const chrome_command_envelope: usize = native_sdk.runtime.max_canvas_commands_per_view - widget_command_reserve;

/// The per-pane pending-outbound ring. 64 KiB matches the pty's stdin
/// FIFO exactly; at two panes that is 128 KiB of model, HALF the single
/// pane's former 256 KiB. Only a paste or reply burst larger than the
/// whole ring, into a child that never reads, reaches the drop path —
/// and even then the drop is counted and shown, never silent.
pub const outbound_buffer_bytes: usize = 64 * 1024;

/// The default interactive shell per platform — a deterministic pick so
/// a replayed update issues the identical spawn (reading $SHELL here
/// would be nondeterminism outside the effect boundary). macOS's login
/// shell has been zsh since Catalina; Linux uses `/bin/sh`, the only
/// interpreter POSIX guarantees present (a bare `/bin/bash` is absent on
/// Alpine and other minimal installs); Windows uses cmd.exe, present on
/// every install (PowerShell's location and edition vary).
const default_shell: []const u8 = if (builtin.os.tag == .macos)
    "/bin/zsh"
else if (builtin.os.tag == .windows)
    "cmd.exe"
else
    "/bin/sh";

/// The spawn argv around that shell: the POSIX shells take `-i`
/// (interactive even though stdin is a pty the shell might not
/// recognize as a login session); cmd.exe is interactive by default
/// and has no such flag.
const default_shell_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{default_shell}
else
    &.{ default_shell, "-i" };

/// The initial terminal and any terminals created with New are native surfaces
/// over ordinary login-configured interactive shells. Cockpit no longer embeds
/// the phux TUI as its primary UI.
const terminal_1_argv: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }
else
    default_shell_argv;
const terminal_2_argv: []const []const u8 = if (builtin.os.tag == .macos)
    &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }
else
    default_shell_argv;

pub fn paneArgv(index: usize) []const []const u8 {
    return if (index == 0) terminal_1_argv else terminal_2_argv;
}

pub const BrowserPage = enum {
    github,
    superlogical,
    article,

    pub fn url(page: BrowserPage) []const u8 {
        return switch (page) {
            .github => "https://github.com/phall1",
            .superlogical => "https://www.superlogical.com/",
            .article => "https://mitchellh.com/writing/superlogical",
        };
    }
};

/// Stable surface selection. Positional UI and keyboard navigation resolve to
/// one of these identities at the input edge; model state never stores a tab
/// slot that can silently identify a different terminal after reordering.
pub const SurfaceSelection = union(enum) {
    terminal: TerminalRef,
    web,

    pub fn eql(a: SurfaceSelection, b: SurfaceSelection) bool {
        return switch (a) {
            .terminal => |id| switch (b) {
                .terminal => |other| id.eql(other),
                .web => false,
            },
            .web => switch (b) {
                .web => true,
                .terminal => false,
            },
        };
    }
};

pub const web_origins = [_][]const u8{
    "zero://inline",
    "zero://app",
    "https://github.com",
    "https://www.superlogical.com",
    "https://mitchellh.com",
};

pub const cockpit_shortcuts = [_]native_sdk.Shortcut{
    .{ .id = "surface.1", .key = "1", .modifiers = .{ .primary = true } },
    .{ .id = "surface.2", .key = "2", .modifiers = .{ .primary = true } },
    .{ .id = "surface.3", .key = "3", .modifiers = .{ .primary = true } },
    .{ .id = "surface.4", .key = "4", .modifiers = .{ .primary = true } },
    .{ .id = "surface.5", .key = "5", .modifiers = .{ .primary = true } },
    .{ .id = "tab.previous", .key = "[", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "tab.next", .key = "]", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "terminal.new", .key = "t", .modifiers = .{ .primary = true } },
    .{ .id = "terminal.close", .key = "w", .modifiers = .{ .primary = true } },
    .{ .id = "tab.move-left", .key = "arrowleft", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "tab.move-right", .key = "arrowright", .modifiers = .{ .primary = true, .shift = true } },
};

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Phux Cockpit canvas", .accessibility_label = "Phux Cockpit", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    .{ .label = webview_label, .kind = .webview, .parent = canvas_label, .url = BrowserPage.github.url(), .x = 0, .y = 0, .width = webkit_parking_extent, .height = webkit_parking_extent, .layer = 20 },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = app_name,
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Phase = provider_contract.Phase;
pub const LayoutMode = enum { single, split };

/// ONE terminal pane: its emulator session, its pty, and every piece of
/// state that belongs to that pty rather than to the window. Everything
/// here was a field of `Model` in the single-terminal original and keeps
/// its name, so the behaviour is the same code operating on a pane
/// pointer instead of the model.
pub const Pane = struct {
    id: TerminalRef,
    /// The emulator session, owned with this record by `LocalProvider`;
    /// everything inside derives from journaled inputs.
    session: *grid.Session,
    /// This pane's key in the app's one keyed-effect space.
    pty_key: u64 = 1,
    /// The spawn argv for this pane's child (and its restart).
    argv: []const []const u8 = default_shell_argv,
    phase: Phase = .starting,
    /// Incremented for every spawn so an asynchronous clipboard read
    /// from a restarted session cannot paste into its replacement.
    session_generation: u64 = 0,
    exit_code: i32 = 0,
    exit_signal: i32 = 0,
    exit_reason: native_sdk.EffectExitReason = .exited,
    cols: u16 = 80,
    rows: u16 = 24,
    /// Keyboard selection mode (the caret the grid outlines).
    selecting: bool = false,
    /// Copy feedback for the status line, cleared by the next copy.
    copied_bytes: u64 = 0,
    /// Physical macOS natural-editing keys whose press was sent as a
    /// legacy shell binding. Matching releases are swallowed by key
    /// identity even if Command/Option came up first.
    macos_natural_keys_held: u8 = 0,
    /// The last copy FAILED (selection serialization or the clipboard
    /// write) with a selection active: the status line says so and the
    /// selection stays live for a retry. Cleared by the next copy
    /// attempt and by a restart.
    copy_failed: bool = false,
    /// Local scrollback and child mouse reporting are separate consumers.
    /// A protocol transition must not erase a user's partial local scroll.
    scrollback_wheel_accum: f32 = 0,
    mouse_wheel_y_accum: f32 = 0,
    mouse_wheel_x_accum: f32 = 0,
    mouse_wheel_next_horizontal: bool = false,
    /// Ghostty mouse-motion deduplication and the button currently owned by
    /// the TUI report stream. Both are session-generation state.
    mouse_last_cell: ?vt.Coordinate = null,
    mouse_protocol_fingerprint: u8 = 0,
    /// Delivered output accounting for the status line (and the
    /// replay fingerprint: byte totals pin the fed stream).
    output_batches: u64 = 0,
    output_bytes: u64 = 0,
    /// Consecutive ptyWrite admission refusals while bytes remain queued.
    /// A successful retry clears this current-stall signal.
    write_refusals: u32 = 0,
    /// Lifetime refusals in this generation, used to separate known app-side
    /// retries from native-sdk's aggregate exit delivery count.
    write_refusals_total: u32 = 0,
    /// Native writes accepted from Cockpit but reported undelivered on exit.
    /// The SDK exposes a record count rather than a byte count.
    native_delivery_failures: u32 = 0,
    /// The window's traffic-light inset so the header clears it.
    /// Pending outbound bytes toward the child's stdin — typed keys,
    /// pastes, AND emulator query replies, in one stream-ordered ring
    /// drained as the pty's 64 KiB stdin FIFO accepts them. A single
    /// queue is why nothing is lost: `ptyWrite` reports acceptance (it
    /// alone knows the byte- and record-ring limits), so a refused write
    /// is retried from here rather than dropped, and a reply cannot be
    /// discarded before it lands. Ordering is the child's own stdin
    /// order — a keystroke after a paste, a reply after the output that
    /// provoked it — exactly what a real terminal delivers.
    outbound_buffer: [outbound_buffer_bytes]u8 = undefined,
    outbound_head: usize = 0,
    outbound_len: usize = 0,
    /// Bytes dropped because the pending ring was full (a paste far
    /// larger than the ring, or a reply burst, into a child that never
    /// reads). Surfaced on the status line — never a silent loss.
    outbound_dropped: u64 = 0,

    /// Input flows to the pty from the moment it is spawned — not only
    /// after the first output batch flips the phase to `.live`. A shell
    /// with an empty prompt and no startup banner never produces that
    /// first batch, and gating input on `.live` would strand it waiting
    /// for keystrokes it discards. Only an ended or failed session
    /// refuses input.
    pub fn acceptsInput(pane: *const Pane) bool {
        return pane.phase == .starting or pane.phase == .live;
    }
};

const RegistryState = enum { vacant, active, closing };

fn replicaOwnerForPane(pane: *const Pane) ReplicaOwner {
    return provider_contract.localReplicaOwner(pane.id, pane.session_generation);
}

/// Concrete local terminal backend. It owns every session and all state tied
/// to that execution: PTY lifecycle/key, emulator, transport queues, and
/// generation. The model only borrows this provider and attaches identities
/// into UI placements.
pub const LocalProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The first two inline records preserve the established two-pane model
    /// ABI. `overflow` supplies the remaining native-sdk PTY capacity.
    terminals: [pane_count]Pane,
    overflow: [max_terminal_count - pane_count]Pane = undefined,
    states: [max_terminal_count]RegistryState = .{ .active, .active, .vacant, .vacant },
    next_terminal_raw: u64 = first_terminal_raw + pane_count,
    next_pty_key: u64 = pane_count + 1,

    pub fn create(gpa: std.mem.Allocator, sessions: [pane_count]*grid.Session) !*LocalProvider {
        return createWithIo(gpa, std.Io.failing, sessions);
    }

    pub fn createWithIo(gpa: std.mem.Allocator, io: std.Io, sessions: [pane_count]*grid.Session) !*LocalProvider {
        const provider = try gpa.create(LocalProvider);
        provider.* = .{ .gpa = gpa, .io = io, .terminals = undefined };
        for (&provider.terminals, sessions, 0..) |*entry, session, index| {
            entry.* = .{
                .id = initialTerminalRef(index),
                .session = session,
                .pty_key = ptyKey(index),
                .argv = paneArgv(index),
            };
        }
        return provider;
    }

    pub fn createSingleWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !*LocalProvider {
        const provider = try gpa.create(LocalProvider);
        provider.* = .{
            .gpa = gpa,
            .io = io,
            .terminals = undefined,
            .states = .{ .active, .vacant, .vacant, .vacant },
            .next_terminal_raw = first_terminal_raw + 1,
            .next_pty_key = 2,
        };
        provider.terminals[0] = .{
            .id = initialTerminalRef(0),
            .session = session,
            .pty_key = ptyKey(0),
            .argv = paneArgv(0),
        };
        return provider;
    }

    pub fn destroy(provider: *LocalProvider) void {
        const gpa = provider.gpa;
        for (0..max_terminal_count) |index| {
            if (provider.states[index] != .vacant) provider.slot(index).session.destroy();
        }
        gpa.destroy(provider);
    }

    pub fn slot(provider: *LocalProvider, index: usize) *Pane {
        return if (index < pane_count)
            &provider.terminals[index]
        else
            &provider.overflow[index - pane_count];
    }

    pub fn slotConst(provider: *const LocalProvider, index: usize) *const Pane {
        return if (index < pane_count)
            &provider.terminals[index]
        else
            &provider.overflow[index - pane_count];
    }

    pub fn activeCount(provider: *const LocalProvider) usize {
        var count: usize = 0;
        for (provider.states) |state| if (state == .active) {
            count += 1;
        };
        return count;
    }

    pub fn occupiedCount(provider: *const LocalProvider) usize {
        var count: usize = 0;
        for (provider.states) |state| if (state != .vacant) {
            count += 1;
        };
        return count;
    }

    pub fn slotIndex(provider: *const LocalProvider, terminal_ref: TerminalRef) ?usize {
        if (!provider_contract.isLocal(terminal_ref)) return null;
        for (0..max_terminal_count) |index| {
            if (provider.states[index] == .vacant) continue;
            if (provider.slotConst(index).id.eql(terminal_ref)) return index;
        }
        return null;
    }

    pub fn terminal(provider: *LocalProvider, terminal_ref: TerminalRef) ?*Pane {
        if (!provider_contract.isLocal(terminal_ref)) return null;
        for (0..max_terminal_count) |index| {
            if (provider.states[index] != .active) continue;
            const candidate = provider.slot(index);
            if (candidate.id.eql(terminal_ref)) return candidate;
        }
        return null;
    }

    pub fn terminalConst(provider: *const LocalProvider, terminal_ref: TerminalRef) ?*const Pane {
        if (!provider_contract.isLocal(terminal_ref)) return null;
        for (0..max_terminal_count) |index| {
            if (provider.states[index] != .active) continue;
            const candidate = provider.slotConst(index);
            if (candidate.id.eql(terminal_ref)) return candidate;
        }
        return null;
    }

    /// Every ACTIVE local identity, in slot order. Closing tombstones are
    /// deliberately excluded: they no longer accept attachment.
    pub fn terminalRefs(provider: *const LocalProvider, out: []TerminalRef) usize {
        var count: usize = 0;
        for (0..max_terminal_count) |index| {
            if (count == out.len) break;
            if (provider.states[index] != .active) continue;
            out[count] = provider.slotConst(index).id;
            count += 1;
        }
        return count;
    }

    pub fn contains(provider: *const LocalProvider, terminal_ref: TerminalRef) bool {
        return provider.terminalConst(terminal_ref) != null;
    }

    pub fn owner(provider: *const LocalProvider, terminal_ref: TerminalRef) ?ReplicaOwner {
        const pane = provider.terminalConst(terminal_ref) orelse return null;
        return replicaOwnerForPane(pane);
    }

    pub fn ownerIsCurrent(provider: *const LocalProvider, owner_value: ReplicaOwner) bool {
        const current = provider.owner(owner_value.terminal_ref) orelse return false;
        return current.eql(owner_value);
    }

    pub fn terminalForPty(provider: *LocalProvider, key: u64) ?*Pane {
        for (0..max_terminal_count) |index| {
            if (provider.states[index] == .vacant) continue;
            const candidate = provider.slot(index);
            if (candidate.pty_key == key) return candidate;
        }
        return null;
    }

    pub fn createTerminal(provider: *LocalProvider) !*Pane {
        if (provider.occupiedCount() >= max_terminal_count) return error.TerminalCapacityReached;
        if (provider.next_terminal_raw >= std.math.maxInt(u64) - 1 or provider.next_pty_key >= std.math.maxInt(u64) - 1) {
            return error.TerminalIdentityExhausted;
        }
        const next_ref = localRef(@enumFromInt(provider.next_terminal_raw));
        for (0..max_terminal_count) |occupied| {
            if (provider.states[occupied] == .vacant) continue;
            const existing = provider.slotConst(occupied);
            if (existing.id.eql(next_ref) or existing.pty_key == provider.next_pty_key) {
                return error.TerminalIdentityCollision;
            }
        }
        if (provider.next_pty_key == clipboard_key or provider.next_pty_key == paste_clipboard_key) {
            return error.TerminalIdentityCollision;
        }
        var index: usize = 0;
        while (index < max_terminal_count and provider.states[index] != .vacant) : (index += 1) {}
        if (index == max_terminal_count) return error.TerminalCapacityReached;
        const session = try grid.Session.create(provider.gpa, provider.io, 80, 24);
        errdefer session.destroy();
        const pane = provider.slot(index);
        pane.* = .{
            .id = next_ref,
            .session = session,
            .pty_key = provider.next_pty_key,
            .argv = terminal_1_argv,
        };
        provider.next_terminal_raw += 1;
        provider.next_pty_key += 1;
        provider.states[index] = .active;
        return pane;
    }

    pub fn beginClose(provider: *LocalProvider, id: TerminalRef) ?*Pane {
        const index = provider.slotIndex(id) orelse return null;
        if (provider.states[index] != .active) return null;
        provider.states[index] = .closing;
        return provider.slot(index);
    }

    pub fn isClosing(provider: *const LocalProvider, id: TerminalRef) bool {
        const index = provider.slotIndex(id) orelse return false;
        return provider.states[index] == .closing;
    }

    pub fn retireClosing(provider: *LocalProvider, id: TerminalRef) void {
        const index = provider.slotIndex(id) orelse return;
        if (provider.states[index] != .closing) return;
        provider.slot(index).session.destroy();
        provider.states[index] = .vacant;
    }
};

pub const Provider = LocalProvider;

pub const Model = struct {
    provider: *LocalProvider,
    phux_provider: ?*PhuxProvider = null,
    remote_ui: [max_remote_terminals]RemoteUiState = [_]RemoteUiState{.{}} ** max_remote_terminals,
    pointer_state: ?*PointerState = null,
    /// Compatibility view for the existing fixed two-terminal UI. Storage and
    /// ownership remain in `provider`; attachment routing never uses this alias.
    panes: *[pane_count]Pane,
    /// Tab order over provider-qualified identities. Local terminals enter it
    /// through New; Phux terminals enter it through provider reconciliation.
    /// Order is presentation only — it never owns execution identity.
    terminal_order: [max_terminal_count]TerminalRef = .{
        provider_contract.localTerminalRef(.terminal_1),
        provider_contract.localTerminalRef(.terminal_2),
        provider_contract.localTerminalRef(.terminal_1),
        provider_contract.localTerminalRef(.terminal_1),
    },
    terminal_count: usize = pane_count,
    attachments: [pane_count]?TerminalRef = .{
        provider_contract.localTerminalRef(.terminal_1),
        provider_contract.localTerminalRef(.terminal_2),
    },
    /// Surface selection is a durable identity, independent from tab order.
    selected_surface: SurfaceSelection = .{ .terminal = provider_contract.localTerminalRef(.terminal_1) },
    /// Placement is independent from execution identity. Split mode projects
    /// both existing terminal surfaces without respawning either process.
    layout: LayoutMode = .single,
    tab_placement: TabPlacement = .top,
    split_fraction: f32 = 0.5,
    browser_page: BrowserPage = .github,
    /// Forces an app-owned root navigation even when the chosen root did not
    /// change while WebKit navigated internally.
    browser_navigation_token: u64 = 0,
    /// Which pane keyboard input reaches. Window activation is global,
    /// pane focus is not: exactly one pane is the keyboard target and
    /// only that one paints a filled cursor.
    focus_placement: Placement = .primary,
    /// This single-window app owns terminal keyboard input exactly while
    /// the application is active. Lifecycle messages rebuild the custom
    /// chrome so the cursor fills on focus and hollows on blur.
    focused: bool = true,
    /// Physical keys whose presses were consumed as app shortcuts. A
    /// matching release must also be consumed when a child enabled kitty
    /// release reporting, even if modifiers or pane focus changed first.
    consumed_shortcut_keys_held: u32 = 0,
    /// Terminal key releases return to the terminal that received the press,
    /// even when attachment or focus changes while the key is held.
    held_terminal_keys: [max_held_terminal_keys]HeldTerminalKey = [_]HeldTerminalKey{.{}} ** max_held_terminal_keys,
    /// Captures are keyed by physical window+pointer and pin durable terminal
    /// identity plus process generation. Unrelated pointers never share state.
    pointer_captures: [max_pointer_captures]PointerCapture = [_]PointerCapture{.{ .terminal_id = .terminal_1 }} ** max_pointer_captures,
    /// A clipboard write is IN FLIGHT: further copies are no-ops until
    /// its result lands. The provider-qualified owner also fences the
    /// completion to the exact local replica that issued it.
    copy_inflight: bool = false,
    copy_owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
    /// One clipboard read may be in flight for the window. Focus and
    /// attachment changes cannot retarget its provider-qualified owner.
    paste_inflight: bool = false,
    paste_owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
    /// The last paste read or atomic queue admission failed. This is
    /// window-level feedback displayed on `paste_owner`'s badge.
    paste_failed: bool = false,
    /// The OS titlebar band height (hidden-inset chrome): the grid's
    /// text starts below it while the terminal background runs under
    /// it, so the window reads as one seamless surface with only the
    /// traffic lights floating over it.
    chrome_top: f32 = 0,
    /// The last surface size the frame pump reported, carried on the
    /// `.viewport` message. `update` has no view size of its own, and
    /// the wheel hit test needs one to resolve whether the pointer stands
    /// over the selected terminal — `on_wheel` cannot do it (no model access) and
    /// `on_frame` cannot mutate. A dedicated `surface_resized` message
    /// carries even sub-cell frame changes that do not resize a PTY, so
    /// pointer hit testing always uses the actual surface geometry.
    ///
    /// SEEDED with the window's CONFIGURED size rather than left zero.
    /// Zero made every pre-first-frame wheel miss the terminal frame,
    /// which the adversarial suite caught and pinned.
    /// `app.zon` declares `restore_state = false` with
    /// `center_on_primary`, so the window always opens at exactly this
    /// size: the seed is not a guess about the first frame, it is the
    /// same number the shell config gives the platform. A restore policy
    /// that ever honored a different size would leave this stale for one
    /// frame, no worse than the resize lag documented above.
    surface_size: geometry.SizeF = geometry.SizeF.init(window_width, window_height),
    /// Backing pixels per canvas point from the latest accepted frame.
    surface_scale_factor: f32 = 1,

    pub fn phux(model: *Model) ?*PhuxProvider {
        if (comptime !phux_enabled) return null;
        return model.phux_provider;
    }

    pub fn phuxConst(model: *const Model) ?*const PhuxProvider {
        if (comptime !phux_enabled) return null;
        return model.phux_provider;
    }

    pub fn containsTerminal(model: *const Model, terminal_ref: TerminalRef) bool {
        return switch (providerKind(terminal_ref)) {
            .local => model.provider.contains(terminal_ref),
            .phux => if (model.phuxConst()) |remote| remote.contains(terminal_ref) else false,
        };
    }

    pub fn terminalOwner(model: *const Model, terminal_ref: TerminalRef) ?ReplicaOwner {
        return switch (providerKind(terminal_ref)) {
            .local => model.provider.owner(terminal_ref),
            .phux => if (model.phuxConst()) |remote| remote.owner(terminal_ref) else null,
        };
    }

    pub fn ownerIsCurrent(model: *const Model, owner_value: ReplicaOwner) bool {
        return switch (providerKind(owner_value.terminal_ref)) {
            .local => model.provider.ownerIsCurrent(owner_value),
            .phux => if (model.phuxConst()) |remote| remote.ownerIsCurrent(owner_value) else false,
        };
    }

    pub fn remotePresentation(model: *const Model, terminal_ref: TerminalRef) ?Presentation {
        if (providerKind(terminal_ref) != .phux) return null;
        const remote = model.phuxConst() orelse return null;
        return remote.presentation(terminal_ref);
    }

    fn remoteUi(model: *Model, terminal_ref: TerminalRef) ?*RemoteUiState {
        const current_owner = model.terminalOwner(terminal_ref) orelse return null;
        var vacant: ?*RemoteUiState = null;
        for (&model.remote_ui) |*state| {
            if (state.terminal_ref) |known| {
                if (!known.eql(terminal_ref)) continue;
                if (!state.owner.eql(current_owner)) {
                    state.* = .{ .terminal_ref = terminal_ref, .owner = current_owner };
                }
                return state;
            }
            if (vacant == null) vacant = state;
        }
        const state = vacant orelse return null;
        state.* = .{ .terminal_ref = terminal_ref, .owner = current_owner };
        return state;
    }

    fn remoteUiConst(model: *const Model, terminal_ref: TerminalRef) ?*const RemoteUiState {
        for (&model.remote_ui) |*state| {
            if (state.terminal_ref) |known| if (known.eql(terminal_ref)) return state;
        }
        return null;
    }

    /// Remote terminals enter the SAME bounded tab topology as local ones:
    /// a Phux terminal that appears becomes a tab, and one that disappears
    /// leaves tab order and any placement it held. It never displaces a live
    /// local terminal — the order is append-only up to capacity, so a busy
    /// cockpit does not reshuffle under the operator.
    pub fn reconcileRemoteTerminals(model: *Model) void {
        const remote = model.phuxConst() orelse return;
        var refs: [max_remote_terminals]TerminalRef = undefined;
        const count = remote.terminalRefs(&refs);

        var order_index: usize = 0;
        while (order_index < model.terminal_count) {
            const current = model.terminal_order[order_index];
            if (providerKind(current) != .phux) {
                order_index += 1;
                continue;
            }
            var retained = false;
            for (refs[0..count]) |candidate| {
                if (current.eql(candidate)) {
                    retained = true;
                    break;
                }
            }
            if (retained) {
                order_index += 1;
            } else {
                model.dropFromOrder(order_index);
            }
        }
        for (refs[0..count]) |candidate| _ = model.admitToOrder(candidate);

        reconcileRemoteRefs(&model.attachments, model.terminal_order[0..model.terminal_count]);
        for (&model.remote_ui) |*state| {
            const known = state.terminal_ref orelse continue;
            var retained = false;
            for (refs[0..count]) |terminal_ref| {
                if (known.eql(terminal_ref)) {
                    retained = true;
                    break;
                }
            }
            if (!retained) state.* = .{};
        }
        for (refs[0..count]) |terminal_ref| _ = model.remoteUi(terminal_ref);
        model.normalizeTopology();
        model.reconcileAttachmentFocus();
    }

    pub fn terminalAt(model: *Model, placement: Placement) ?*Pane {
        const id = model.attachments[placement.index()] orelse return null;
        return model.provider.terminal(id);
    }

    pub fn terminalAtConst(model: *const Model, placement: Placement) ?*const Pane {
        const id = model.attachments[placement.index()] orelse return null;
        return model.provider.terminalConst(id);
    }

    pub fn focusedPane(model: *Model) *Pane {
        return model.terminalAt(model.focus_placement) orelse unreachable;
    }

    pub fn focusedTerminalRef(model: *const Model) ?TerminalRef {
        return model.attachments[model.focus_placement.index()];
    }

    pub fn focusedTerminalId(model: *const Model) ?TerminalRef {
        return model.focusedTerminalRef();
    }

    pub fn selectedPlacement(model: *const Model) ?Placement {
        const id = model.selectedTerminalRef() orelse return null;
        for (model.attachments, 0..) |attached, index| {
            if (attached != null and attached.?.eql(id)) return Placement.fromIndex(index).?;
        }
        return null;
    }

    /// The selected surface's durable identity, or null when the Web surface
    /// is selected or the selection names a terminal no provider still owns.
    pub fn selectedTerminalRef(model: *const Model) ?TerminalRef {
        return switch (model.selected_surface) {
            .terminal => |id| if (model.containsTerminal(id)) id else null,
            .web => null,
        };
    }

    pub fn selectedTerminalId(model: *const Model) ?TerminalRef {
        return model.selectedTerminalRef();
    }

    pub fn selectedTerminalIndex(model: *const Model) ?u8 {
        const placement = model.selectedPlacement() orelse return null;
        return @intFromEnum(placement);
    }

    pub fn terminalOrderIndex(model: *const Model, id: TerminalRef) ?usize {
        for (model.terminal_order[0..model.terminal_count], 0..) |candidate, index| {
            if (candidate.eql(id)) return index;
        }
        return null;
    }

    /// Append a provider-qualified identity to tab order if it is not already
    /// present. Returns false when the bounded order is full.
    fn admitToOrder(model: *Model, id: TerminalRef) bool {
        if (model.terminalOrderIndex(id) != null) return true;
        if (model.terminal_count >= max_terminal_count) return false;
        model.terminal_order[model.terminal_count] = id;
        model.terminal_count += 1;
        return true;
    }

    fn dropFromOrder(model: *Model, index: usize) void {
        if (index >= model.terminal_count) return;
        var cursor = index;
        while (cursor + 1 < model.terminal_count) : (cursor += 1) {
            model.terminal_order[cursor] = model.terminal_order[cursor + 1];
        }
        model.terminal_count -= 1;
    }

    pub const AttachError = error{ UnknownTerminal, TerminalAlreadyAttached, PlacementOccupied };

    fn reconcileAttachmentFocus(model: *Model) void {
        var fallback: ?Placement = null;
        for (model.attachments, 0..) |attached, index| {
            if (attached != null) {
                fallback = Placement.fromIndex(index).?;
                break;
            }
        }
        if (model.selectedTerminalRef() != null and model.selectedPlacement() == null) {
            if (fallback) |replacement| {
                const replacement_id = model.attachments[replacement.index()].?;
                model.selected_surface = .{ .terminal = replacement_id };
            }
        }
        if (model.attachments[model.focus_placement.index()] == null) {
            if (model.selectedPlacement()) |placement| {
                if (model.attachments[placement.index()] != null) {
                    model.focus_placement = placement;
                    return;
                }
            }
            if (fallback) |replacement| model.focus_placement = replacement;
        }
    }

    pub fn attach(model: *Model, placement: Placement, terminal_ref: TerminalRef) AttachError!void {
        if (!model.containsTerminal(terminal_ref)) return error.UnknownTerminal;
        for (model.attachments) |attached| {
            if (attached != null and attached.?.eql(terminal_ref)) return error.TerminalAlreadyAttached;
        }
        if (model.attachments[placement.index()] != null) return error.PlacementOccupied;
        model.attachments[placement.index()] = terminal_ref;
        if (model.selectedPlacement() == placement) model.focus_placement = placement;
        model.reconcileAttachmentFocus();
    }

    pub fn detach(model: *Model, placement: Placement) ?TerminalRef {
        const index = placement.index();
        const detached = model.attachments[index] orelse return null;
        model.attachments[index] = null;
        model.reconcileAttachmentFocus();
        return detached;
    }

    fn attachForSelection(model: *Model, id: TerminalRef) void {
        for (model.attachments, 0..) |attached, index| {
            if (attached != null and attached.?.eql(id)) {
                model.focus_placement = Placement.fromIndex(index).?;
                return;
            }
        }
        const target = if (model.layout == .single) Placement.primary else model.focus_placement;
        model.attachments[target.index()] = id;
        model.focus_placement = target;
    }

    pub fn selectTerminal(model: *Model, id: TerminalRef) bool {
        if (!model.containsTerminal(id)) return false;
        model.selected_surface = .{ .terminal = id };
        model.attachForSelection(id);
        return true;
    }

    pub fn normalizeTopology(model: *Model) void {
        for (&model.attachments) |*attached| {
            if (attached.* != null and !model.containsTerminal(attached.*.?)) attached.* = null;
        }
        if (model.terminal_count == 0) {
            model.selected_surface = .web;
            model.layout = .single;
            model.attachments = .{ null, null };
            return;
        }
        // `.web` is a CHOICE, not a dangling selection — and
        // `selectedTerminalRef` returns null for both. Normalization runs on
        // every provider publication, so conflating them would yank an
        // operator off the Web surface the moment a coordinator announced a
        // session. Only repair a selection that named a terminal which is
        // gone; leave an explicit Web selection alone.
        if (model.selected_surface == .web) {
            model.layout = .single;
            return;
        }
        const selected = model.selectedTerminalRef() orelse model.terminal_order[0];
        model.selected_surface = .{ .terminal = selected };
        model.attachForSelection(selected);
        if (model.layout == .split) {
            const other_index = 1 - model.focus_placement.index();
            const other_stale = if (model.attachments[other_index]) |other| other.eql(selected) else true;
            if (other_stale) {
                model.attachments[other_index] = null;
                for (model.terminal_order[0..model.terminal_count]) |candidate| {
                    if (!candidate.eql(selected)) {
                        model.attachments[other_index] = candidate;
                        break;
                    }
                }
            }
            if (model.attachments[other_index] == null) model.layout = .single;
        }
    }

    pub fn moveTerminal(model: *Model, id: TerminalRef, delta: i8) bool {
        const current = model.terminalOrderIndex(id) orelse return false;
        const target_signed = @as(isize, @intCast(current)) + delta;
        if (target_signed < 0 or target_signed >= model.terminal_count) return false;
        const target: usize = @intCast(target_signed);
        std.mem.swap(TerminalRef, &model.terminal_order[current], &model.terminal_order[target]);
        return true;
    }

    /// The versioned persistence boundary. Remote identities are filtered out
    /// rather than serialized: their existence is the coordinator's to assert,
    /// and persisting them would claim a durability this app does not have.
    pub fn topologySnapshot(model: *const Model) !TopologySnapshot {
        var snapshot: TopologySnapshot = .{
            .layout = model.layout,
            .split_fraction = model.split_fraction,
            .focused_attachment = model.focus_placement,
            .tab_placement = model.tab_placement,
        };

        var count: u8 = 0;
        for (model.terminal_order[0..model.terminal_count]) |id| {
            const local = provider_contract.localId(id) orelse continue;
            snapshot.terminal_order[count] = local;
            count += 1;
        }
        snapshot.terminal_count = count;

        for (model.attachments, 0..) |attached, index| {
            snapshot.attachments[index] = if (attached) |id|
                provider_contract.localId(id)
            else
                null;
        }

        snapshot.selection = switch (model.selected_surface) {
            .terminal => |id| if (provider_contract.localId(id)) |local|
                SnapshotSelection{ .terminal = local }
            else
                .web,
            .web => .web,
        };

        // A dropped remote identity can leave the persisted selection, layout,
        // or focus inconsistent with what remains. Settle those here rather
        // than emitting a snapshot `validate` would reject.
        if (snapshot.terminal_count == 0) {
            snapshot.selection = .web;
            snapshot.layout = .single;
            snapshot.attachments = .{ null, null };
            snapshot.focused_attachment = .primary;
        } else {
            if (snapshot.layout == .split and
                (snapshot.attachments[0] == null or snapshot.attachments[1] == null))
            {
                snapshot.layout = .single;
            }
            switch (snapshot.selection) {
                .terminal => |id| {
                    const focused = snapshot.attachments[snapshot.focused_attachment.index()];
                    if (focused == null or focused.? != id) {
                        for (snapshot.attachments, 0..) |attached, index| {
                            if (attached != null and attached.? == id) {
                                snapshot.focused_attachment = Placement.fromIndex(index).?;
                                break;
                            }
                        } else snapshot.selection = .web;
                    }
                },
                .web => {},
            }
            if (snapshot.selection == .web and
                (snapshot.attachments[0] != null or snapshot.attachments[1] != null) and
                snapshot.attachments[snapshot.focused_attachment.index()] == null)
            {
                for (snapshot.attachments, 0..) |attached, index| {
                    if (attached != null) {
                        snapshot.focused_attachment = Placement.fromIndex(index).?;
                        break;
                    }
                }
            }
        }

        try snapshot.validate();
        return snapshot;
    }
};

/// Prune placements whose remote terminal is gone.
///
/// This deliberately does NOT claim a placement for a newly discovered remote
/// terminal. A Phux terminal that appears becomes a TAB (see
/// `Model.reconcileRemoteTerminals`); it takes a visible pane only when the
/// operator selects it. Auto-claiming would evict a live local terminal from
/// under the operator's cursor the moment a coordinator published a session —
/// placement never owns identity, and discovery is not intent.
///
/// `live_refs` is the full set of identities that still exist, local and
/// remote alike; only remote placements are subject to pruning here, because
/// local lifetime is owned by `LocalProvider`'s registry states.
pub fn reconcileRemoteRefs(
    attachments: *[pane_count]?TerminalRef,
    live_refs: []const TerminalRef,
) void {
    for (attachments) |*attached| {
        const current = attached.* orelse continue;
        if (providerKind(current) != .phux) continue;
        var retained = false;
        for (live_refs) |candidate| {
            if (current.eql(candidate)) {
                retained = true;
                break;
            }
        }
        if (!retained) attached.* = null;
    }
}

/// The initial cockpit model over `pane_count` heap-owned sessions: pane
/// i takes pty key i+1 and its own spawn argv.
pub fn initialModelWithPhux(
    sessions: [pane_count]*grid.Session,
    phux_provider: ?*PhuxProvider,
) Model {
    const local_provider = LocalProvider.create(std.heap.page_allocator, sessions) catch @panic("failed to allocate local terminal provider");
    var pointer_state: ?*PointerState = null;
    if (comptime phux_enabled) {
        if (phux_provider != null) {
            pointer_state = std.heap.page_allocator.create(PointerState) catch
                @panic("failed to allocate pointer monitor state");
            pointer_state.?.* = .{};
        }
    }
    return .{
        .provider = local_provider,
        .phux_provider = phux_provider,
        .pointer_state = pointer_state,
        .panes = &local_provider.terminals,
    };
}

pub fn initialModel(sessions: [pane_count]*grid.Session) Model {
    return initialModelWithPhux(sessions, null);
}

/// Bind an already-created Phux provider to a model built by one of the local
/// initializers, allocating the pointer-monitor state the remote path needs.
pub fn attachPhuxProvider(model: *Model, phux_provider: ?*PhuxProvider) void {
    if (comptime !phux_enabled) return;
    const remote = phux_provider orelse return;
    model.phux_provider = remote;
    if (model.pointer_state != null) return;
    const pointer_state = std.heap.page_allocator.create(PointerState) catch
        @panic("failed to allocate pointer monitor state");
    pointer_state.* = .{};
    model.pointer_state = pointer_state;
}

pub fn initialModelWithIo(gpa: std.mem.Allocator, io: std.Io, sessions: [pane_count]*grid.Session) !Model {
    const provider = try LocalProvider.createWithIo(gpa, io, sessions);
    return .{ .provider = provider, .panes = &provider.terminals };
}

/// Production launch starts with one provider resource. The two-session
/// initializer above remains the dense multi-terminal fixture used by existing
/// product, lifecycle, and adversarial tests.
pub fn initialProductionModelWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !Model {
    const provider = try LocalProvider.createSingleWithIo(gpa, io, session);
    return .{
        .provider = provider,
        .panes = &provider.terminals,
        .terminal_count = 1,
        .attachments = .{ initialTerminalRef(0), null },
    };
}

pub const topology_snapshot_version: u16 = 1;
pub const process_restoration_supported = false;

/// The persisted form of a surface selection. Snapshots carry LOCAL topology
/// only: a Phux terminal exists because the coordinator says so, and claiming
/// otherwise across a restart would be a fake durability promise. A selection
/// pointing at a remote terminal persists as `.web` and re-resolves when the
/// provider republishes.
pub const SnapshotSelection = union(enum) {
    terminal: LocalTerminalId,
    web,

    pub fn eql(a: SnapshotSelection, b: SnapshotSelection) bool {
        return switch (a) {
            .terminal => |id| switch (b) {
                .terminal => |other| id == other,
                .web => false,
            },
            .web => b == .web,
        };
    }
};

/// Persisted presentation topology only. It deliberately contains no PID,
/// PTY key, emulator bytes, process phase, or claim that a process survived.
pub const TopologySnapshot = struct {
    version: u16 = topology_snapshot_version,
    terminal_count: u8 = 0,
    terminal_order: [max_terminal_count]LocalTerminalId = [_]LocalTerminalId{.terminal_1} ** max_terminal_count,
    selection: SnapshotSelection = .web,
    layout: LayoutMode = .single,
    split_fraction: f32 = 0.5,
    attachments: [pane_count]?LocalTerminalId = .{ null, null },
    focused_attachment: Placement = .primary,
    tab_placement: TabPlacement = .top,

    pub fn validate(snapshot: TopologySnapshot) !void {
        if (snapshot.version != topology_snapshot_version) return error.UnsupportedTopologyVersion;
        if (snapshot.terminal_count > max_terminal_count) return error.InvalidTopology;
        const count: usize = snapshot.terminal_count;
        for (snapshot.terminal_order[0..count], 0..) |id, index| {
            const raw = @intFromEnum(id);
            if (raw < first_terminal_raw or raw >= std.math.maxInt(u64) - 1) return error.InvalidTopology;
            for (snapshot.terminal_order[0..index]) |prior| {
                if (prior == id) return error.InvalidTopology;
            }
        }
        for (snapshot.terminal_order[count..]) |id| {
            if (id != .terminal_1) return error.InvalidTopology;
        }
        switch (snapshot.selection) {
            .terminal => |id| if (indexOfSnapshotTerminal(snapshot, id) == null) return error.InvalidTopology,
            .web => {},
        }
        for (snapshot.attachments) |attached| if (attached) |id| {
            if (indexOfSnapshotTerminal(snapshot, id) == null) return error.InvalidTopology;
        };
        if (snapshot.attachments[0] != null and snapshot.attachments[1] != null and
            snapshot.attachments[0].? == snapshot.attachments[1].?) return error.InvalidTopology;
        if (!std.math.isFinite(snapshot.split_fraction) or snapshot.split_fraction < 0.05 or snapshot.split_fraction > 0.95) {
            return error.InvalidTopology;
        }
        if (count == 0) {
            if (!snapshot.selection.eql(.web) or snapshot.layout != .single or
                snapshot.attachments[0] != null or snapshot.attachments[1] != null or
                snapshot.focused_attachment != .primary) return error.InvalidTopology;
            return;
        }
        if (snapshot.layout == .split and (snapshot.attachments[0] == null or snapshot.attachments[1] == null)) {
            return error.InvalidTopology;
        }
        const focused = snapshot.attachments[snapshot.focused_attachment.index()];
        switch (snapshot.selection) {
            .terminal => |id| if (focused == null or focused.? != id) return error.InvalidTopology,
            .web => {
                if ((snapshot.attachments[0] != null or snapshot.attachments[1] != null) and focused == null) {
                    return error.InvalidTopology;
                }
            },
        }
    }
};

pub const LegacyTopologySnapshotV0 = struct {
    terminal_count: u8 = pane_count,
    selected_index: u8 = 0,
    split: bool = false,
    split_fraction: f32 = 0.5,
};

pub const PersistedTopologySnapshot = union(enum) {
    v0: LegacyTopologySnapshotV0,
    v1: TopologySnapshot,
};

fn indexOfSnapshotTerminal(snapshot: TopologySnapshot, id: LocalTerminalId) ?usize {
    for (snapshot.terminal_order[0..snapshot.terminal_count], 0..) |candidate, index| {
        if (candidate == id) return index;
    }
    return null;
}

pub fn migrateTopologySnapshot(persisted: PersistedTopologySnapshot) !TopologySnapshot {
    const snapshot = switch (persisted) {
        .v1 => |current| current,
        .v0 => |legacy| blk: {
            if (legacy.terminal_count > max_terminal_count or !std.math.isFinite(legacy.split_fraction)) {
                return error.InvalidTopology;
            }
            var migrated: TopologySnapshot = .{
                .terminal_count = legacy.terminal_count,
                .layout = if (legacy.split and legacy.terminal_count >= 2) .split else .single,
                .split_fraction = std.math.clamp(legacy.split_fraction, 0.05, 0.95),
            };
            for (0..legacy.terminal_count) |index| {
                migrated.terminal_order[index] = @enumFromInt(first_terminal_raw + index);
            }
            if (legacy.terminal_count > 0) {
                const selected = @min(@as(usize, legacy.selected_index), legacy.terminal_count - 1);
                migrated.selection = .{ .terminal = migrated.terminal_order[selected] };
                migrated.attachments[0] = migrated.terminal_order[selected];
                if (migrated.layout == .split) {
                    migrated.attachments[1] = migrated.terminal_order[if (selected == 0) 1 else 0];
                }
            }
            break :blk migrated;
        },
    };
    try snapshot.validate();
    return snapshot;
}

pub fn restoreModel(gpa: std.mem.Allocator, io: std.Io, persisted: PersistedTopologySnapshot) !Model {
    const snapshot = try migrateTopologySnapshot(persisted);
    const provider = try gpa.create(LocalProvider);
    errdefer gpa.destroy(provider);
    provider.* = .{
        .gpa = gpa,
        .io = io,
        .terminals = undefined,
        .states = [_]RegistryState{.vacant} ** max_terminal_count,
        .next_terminal_raw = first_terminal_raw,
        .next_pty_key = 1,
    };
    var created: usize = 0;
    errdefer for (0..created) |index| provider.slot(index).session.destroy();
    while (created < snapshot.terminal_count) : (created += 1) {
        const session = try grid.Session.create(gpa, io, 80, 24);
        const local_id = snapshot.terminal_order[created];
        const pane = provider.slot(created);
        pane.* = .{
            .id = localRef(local_id),
            .session = session,
            .pty_key = provider.next_pty_key,
            .argv = terminal_1_argv,
        };
        provider.states[created] = .active;
        provider.next_pty_key += 1;
        provider.next_terminal_raw = @max(provider.next_terminal_raw, @intFromEnum(local_id) + 1);
    }

    var model: Model = .{
        .provider = provider,
        .panes = &provider.terminals,
        .terminal_count = snapshot.terminal_count,
        .layout = snapshot.layout,
        .split_fraction = snapshot.split_fraction,
        .focus_placement = snapshot.focused_attachment,
        .tab_placement = snapshot.tab_placement,
        .selected_surface = switch (snapshot.selection) {
            .terminal => |id| .{ .terminal = localRef(id) },
            .web => .web,
        },
    };
    for (snapshot.terminal_order, 0..) |id, index| model.terminal_order[index] = localRef(id);
    for (snapshot.attachments, 0..) |attached, index| {
        model.attachments[index] = if (attached) |id| localRef(id) else null;
    }
    return model;
}

pub fn deinitModel(model: *Model) void {
    if (comptime phux_enabled) {
        if (model.pointer_state) |pointer_state| {
            if (pointer_state.monitor) |*monitor| monitor.stop();
            std.heap.page_allocator.destroy(pointer_state);
            model.pointer_state = null;
        }
    }
    if (comptime phux_enabled) {
        if (model.phux_provider) |remote| remote.destroy();
        model.phux_provider = null;
    }
    model.provider.destroy();
}

pub const Msg = union(enum) {
    shell: native_sdk.EffectPtyEvent,
    phux_channel: native_sdk.EffectChannelEvent,
    pointer_channel: native_sdk.EffectChannelEvent,
    key: canvas.WidgetKeyboardEvent,
    text: canvas.WidgetKeyboardEvent,
    viewport: struct {
        terminal_ref: TerminalRef,
        cols: u16,
        rows: u16,
        size: geometry.SizeF,
        scale_factor: f32 = 1,
    },
    surface_resized: struct { size: geometry.SizeF, scale_factor: f32 },
    clipboard: native_sdk.EffectClipboardResult,
    paste_clipboard: native_sdk.EffectClipboardResult,
    copy_selection,
    copy_terminal: TerminalRef,
    paste_terminal: TerminalRef,
    restart: Placement,
    select_surface: SurfaceSelection,
    select_position: u8,
    cycle_tab: i8,
    new_terminal,
    close_terminal,
    move_terminal: i8,
    toggle_tab_placement,
    toggle_split,
    split_resized: f32,
    cycle_pane: i8,
    browser_page: BrowserPage,
    /// Move keyboard focus to a placement (cmd+1/cmd+2, or a press on the
    /// placement's own stack). Detached placements are ignored.
    focus_pane: Placement,
    attach_terminal: struct { placement: Placement, terminal_ref: TerminalRef },
    detach_terminal: Placement,
    /// The frame pump asks the update loop (which holds `fx`) to push
    /// more pending outbound bytes now that a frame elapsed — the child
    /// may have read and freed FIFO space without producing output to
    /// trigger a flush.
    flush_outbound,
    selection_autoscroll,
    /// The SDK-routed retained-widget event, stamped with durable identity and
    /// generation by CockpitHost's narrow v0.7.1 adapter.
    pointer: TerminalPointerEvent,
    /// Direct UiApp embeddings lack CockpitHost's routed-pointer adapter.
    /// Keep wheel behavior available there for headless harnesses.
    wheel_fallback: struct { x: f32, y: f32, delta: f32 },
    chrome_changed: native_sdk.platform.WindowChrome,
    focus_changed: bool,
};

const TerminalApp = native_sdk.UiApp(Model, Msg);
const Fx = TerminalApp.Effects;

/// UiApp owns the deterministic model/view/effects loop. This host adds the
/// one imperative operation native surface switching requires: moving the OS
/// first responder after a global tab shortcut. Without it, a parked WebKit
/// view can keep consuming text after the model has returned to a terminal.
pub const CockpitHost = struct {
    inner: TerminalApp = undefined,
    inner_app: native_sdk.App = undefined,
    /// Global AppKit shortcuts and canvas key delivery can describe the same
    /// physical edge. Suppress only the duplicate canvas edge; the model's
    /// latch remains reserved for shortcuts originating on the canvas itself.
    suppressed_canvas_shortcuts: u32 = 0,
    /// Platform shortcut callbacks have no key phase. Hold the physical key
    /// until a canvas release or a different shortcut edge so repeated
    /// callbacks for one edge execute the command exactly once.
    global_shortcut_keys_held: u32 = 0,
    selection_autoscroll_timer_active: bool = false,

    pub fn init(self: *CockpitHost, allocator: std.mem.Allocator, model: Model, options: TerminalApp.Options) void {
        var host_options = options;
        // Production wheel input is routed by the retained terminal overlay
        // below; disable the app-global geometry fallback to avoid a duplicate.
        host_options.on_wheel = null;
        self.inner = TerminalApp.init(allocator, model, host_options);
        self.inner_app = self.inner.app();
        self.suppressed_canvas_shortcuts = 0;
        self.global_shortcut_keys_held = 0;
        self.selection_autoscroll_timer_active = false;
    }

    pub fn deinit(self: *CockpitHost) void {
        self.inner.deinit();
    }

    pub fn app(self: *CockpitHost) native_sdk.App {
        return .{
            .context = self,
            .name = self.inner_app.name,
            .source = self.inner_app.source,
            .source_fn = if (self.inner_app.source_fn != null) source else null,
            .scene_fn = if (self.inner_app.scene_fn != null) scene else null,
            .start_fn = if (self.inner_app.start_fn != null) start else null,
            .event_fn = if (self.inner_app.event_fn != null) event else null,
            .stop_fn = if (self.inner_app.stop_fn != null) stop else null,
            .replay_fn = if (self.inner_app.replay_fn != null) replay else null,
        };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.platform.WebViewSource {
        const self: *CockpitHost = @ptrCast(@alignCast(context));
        return self.inner_app.webViewSource();
    }

    fn scene(context: *anyopaque) anyerror!native_sdk.ShellConfig {
        const self: *CockpitHost = @ptrCast(@alignCast(context));
        return (try self.inner_app.scene()) orelse return error.SceneUnavailable;
    }

    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *CockpitHost = @ptrCast(@alignCast(context));
        try self.inner_app.start(runtime);
    }

    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, event_value: native_sdk.Event) anyerror!void {
        const self: *CockpitHost = @ptrCast(@alignCast(context));
        defer self.syncSelectionAutoscrollTimer(runtime) catch {};
        switch (event_value) {
            .command => |command| {
                if (command.source == .shortcut) {
                    const mask = commandShortcutKeyMask(command.name);
                    if (mask != 0 and
                        ((self.inner.model.consumed_shortcut_keys_held & mask) != 0 or
                            (self.global_shortcut_keys_held & mask) != 0)) return;
                    // Preserve a still-held older shortcut until its canvas
                    // release arrives. A new global edge for this key clears
                    // stale duplicate suppression left by WebKit focus.
                    self.suppressed_canvas_shortcuts &= ~mask;
                    self.suppressed_canvas_shortcuts |= self.global_shortcut_keys_held;
                    self.global_shortcut_keys_held = mask;
                }
            },
            .gpu_surface_input => |input| {
                const mask = appShortcutKeyMask(input.key);
                const global_owned = mask != 0 and (self.global_shortcut_keys_held & mask) != 0;
                if (input.kind == .key_up) self.global_shortcut_keys_held &= ~mask;
                if (global_owned) {
                    if (input.kind == .key_up) self.suppressed_canvas_shortcuts &= ~mask;
                    return;
                }
                if (mask != 0 and (self.suppressed_canvas_shortcuts & mask) != 0) {
                    if (input.kind == .key_up) self.suppressed_canvas_shortcuts &= ~mask;
                    return;
                }
            },
            .canvas_widget_pointer => |pointer_event| {
                if (try self.routeTerminalPointer(runtime, pointer_event)) return;
            },
            .shortcut => |shortcut| {
                const mask = appShortcutKeyMask(shortcut.key);
                if (mask != 0 and (self.inner.model.consumed_shortcut_keys_held & mask) != 0) {
                    // Canvas handled key-down first. Do not execute the global
                    // copy, but own its eventual canvas release after focus.
                    if (self.inner.model.selectedTerminalIndex() == null) {
                        self.inner.model.consumed_shortcut_keys_held &= ~mask;
                    } else {
                        self.suppressed_canvas_shortcuts |= mask;
                    }
                    try self.focusSelectedContent(runtime, shortcut.window_id);
                    return;
                }
                if (mask != 0 and (self.global_shortcut_keys_held & mask) != 0) {
                    try self.focusSelectedContent(runtime, shortcut.window_id);
                    return;
                }
            },
            .lifecycle => |lifecycle| if (lifecycle == .deactivate) {
                self.suppressed_canvas_shortcuts = 0;
                self.global_shortcut_keys_held = 0;
            },
            else => {},
        }
        const selected_before = self.inner.model.selected_surface;
        try self.inner_app.event(runtime, event_value);
        if (!selected_before.eql(self.inner.model.selected_surface)) {
            const window_id = switch (event_value) {
                .shortcut => |shortcut| shortcut.window_id,
                .gpu_surface_input => |input| input.window_id,
                else => 1,
            };
            try self.focusSelectedContent(runtime, window_id);
            return;
        }
        switch (event_value) {
            .shortcut => |shortcut| {
                if (!std.mem.startsWith(u8, shortcut.id, "tab.") and
                    !std.mem.startsWith(u8, shortcut.id, "layout.") and
                    !std.mem.startsWith(u8, shortcut.id, "pane.")) return;
                try self.focusSelectedContent(runtime, shortcut.window_id);
                if (self.inner.model.selectedTerminalIndex() != null) {
                    self.suppressed_canvas_shortcuts |= appShortcutKeyMask(shortcut.key);
                }
            },
            .gpu_surface_input => |input| {
                if (input.kind != .pointer_up or !std.mem.eql(u8, input.label, canvas_label)) return;
                if (canvasActionControlFocused(runtime, input.window_id)) {
                    try self.focusSelectedContent(runtime, input.window_id);
                }
            },
            else => {},
        }
    }

    fn focusSelectedContent(self: *CockpitHost, runtime: *native_sdk.Runtime, window_id: native_sdk.platform.WindowId) !void {
        const target = if (self.inner.model.selectedTerminalIndex() == null) webview_label else canvas_label;
        try runtime.focusView(window_id, target);
        if (std.mem.eql(u8, target, canvas_label)) clearCanvasWidgetFocus(runtime, window_id);
    }

    fn canvasActionControlFocused(runtime: *native_sdk.Runtime, window_id: native_sdk.platform.WindowId) bool {
        for (runtime.views[0..runtime.view_count]) |*runtime_view| {
            if (runtime_view.window_id != window_id or !std.mem.eql(u8, runtime_view.label, canvas_label)) continue;
            const focused = runtime_view.canvas_widget_focused_id;
            if (focused == 0) return false;
            const node = runtime_view.widgetLayoutTree().findById(focused) orelse return false;
            return node.widget.kind == .segmented_control or
                node.widget.kind == .toggle_button or
                node.widget.kind == .button;
        }
        return false;
    }

    fn clearCanvasWidgetFocus(runtime: *native_sdk.Runtime, window_id: native_sdk.platform.WindowId) void {
        for (runtime.views[0..runtime.view_count]) |*runtime_view| {
            if (runtime_view.window_id != window_id or !std.mem.eql(u8, runtime_view.label, canvas_label)) continue;
            runtime_view.canvas_widget_focused_id = 0;
            runtime_view.canvas_widget_focus_visible_id = 0;
            runtime_view.canvas_widget_focus_visible_keyboard = false;
            return;
        }
    }

    /// Narrow v0.7.1 adapter: consume the SDK's already-routed/captured widget
    /// event exactly once. Custom widgets cannot bind a continuous pointer Msg,
    /// and the SDK keeps only one pressed-widget register per canvas, so model
    /// capture below supplies the missing per-window/per-pointer ownership.
    fn routeTerminalPointer(
        self: *CockpitHost,
        runtime: *native_sdk.Runtime,
        routed: native_sdk.runtime.CanvasWidgetPointerEvent,
    ) !bool {
        if (!std.mem.eql(u8, routed.view_label, canvas_label)) return false;
        const pointer = routed.pointer;
        // A new down supersedes only this physical pointer's old capture,
        // even when the new target is chrome rather than another terminal.
        if (pointer.phase == .down) {
            if (pointerCaptureFor(&self.inner.model, routed.window_id, pointer.pointer_id)) |previous| {
                try self.inner.dispatch(runtime, routed.window_id, .{ .pointer = .{
                    .window_id = previous.window_id,
                    .terminal_id = previous.terminal_id,
                    .generation = previous.generation,
                    .phase = .cancel,
                    .pointer_id = previous.pointer_id,
                    .button = previous.button,
                    .point = previous.last_point,
                    .frame = previous.frame,
                    .modifiers = previous.modifiers,
                } });
            }
        }
        const capture = switch (pointer.phase) {
            .move, .up, .cancel => pointerCaptureFor(&self.inner.model, routed.window_id, pointer.pointer_id),
            .hover, .down, .wheel => null,
        };

        var terminal_id: LocalTerminalId = undefined;
        var generation: u64 = 0;
        var frame: geometry.RectF = .{};
        if (capture) |owned| {
            terminal_id = owned.terminal_id;
            generation = owned.generation;
            frame = if (routed.target) |target|
                if (target.id == terminalInteractionWidgetId(owned.terminal_id)) target.bounds else terminalInteractionFrame(runtime, routed.window_id, owned.terminal_id) orelse owned.frame
            else
                terminalInteractionFrame(runtime, routed.window_id, owned.terminal_id) orelse owned.frame;
        } else {
            if (pointer.phase == .up or pointer.phase == .cancel or pointer.phase == .move) {
                // A stale/unrelated terminal edge cannot borrow the SDK's
                // canvas-global pressed id and disturb another pointer.
                if (routed.target) |target| {
                    if (terminalIdForInteractionWidget(&self.inner.model, target.id) != null) return true;
                }
                return false;
            }
            const target = routed.target orelse return false;
            terminal_id = terminalIdForInteractionWidget(&self.inner.model, target.id) orelse return false;
            const pane = self.inner.model.provider.terminal(localRef(terminal_id)) orelse return true;
            generation = pane.session_generation;
            frame = target.bounds;
        }

        try self.inner.dispatch(runtime, routed.window_id, .{ .pointer = .{
            .window_id = routed.window_id,
            .terminal_id = terminal_id,
            .generation = generation,
            .phase = pointer.phase,
            .pointer_id = pointer.pointer_id,
            .button = pointer.button,
            .click_count = pointer.click_count,
            .point = pointer.point,
            .frame = frame,
            .delta = pointer.delta,
            .modifiers = .{
                .shift = pointer.modifiers.shift,
                .control = pointer.modifiers.control,
                .alt = pointer.modifiers.alt,
                .super = pointer.modifiers.super,
            },
        } });
        if (pointer.phase == .down) try self.focusSelectedContent(runtime, routed.window_id);
        return true;
    }

    fn syncSelectionAutoscrollTimer(self: *CockpitHost, runtime: *native_sdk.Runtime) !void {
        const needed = modelHasSelectionAutoscroll(&self.inner.model);
        if (needed == self.selection_autoscroll_timer_active) return;
        if (needed) {
            try runtime.startTimer(selection_autoscroll_timer_id, selection_autoscroll_interval_ns, true);
        } else {
            try runtime.cancelTimer(selection_autoscroll_timer_id);
        }
        self.selection_autoscroll_timer_active = needed;
    }

    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *CockpitHost = @ptrCast(@alignCast(context));
        if (self.selection_autoscroll_timer_active) {
            runtime.cancelTimer(selection_autoscroll_timer_id) catch {};
            self.selection_autoscroll_timer_active = false;
        }
        try self.inner_app.stop(runtime);
    }

    fn replay(context: *anyopaque, control: native_sdk.runtime.ReplayControl) anyerror!void {
        const self: *CockpitHost = @ptrCast(@alignCast(context));
        try self.inner_app.replayControl(control);
    }
};

fn terminalInteractionWidgetId(id: LocalTerminalId) canvas.ObjectId {
    return canvas.globalWidgetId(.terminal, .{ .index = @intCast(@intFromEnum(id)) });
}

/// Routed widget pointer input reaches LOCAL terminals only: the remote path
/// runs through the NSEvent monitor, which carries its own hit testing.
fn terminalIdForInteractionWidget(model: *const Model, widget_id: canvas.ObjectId) ?LocalTerminalId {
    for (model.terminal_order[0..model.terminal_count]) |id| {
        const local = provider_contract.localId(id) orelse continue;
        if (terminalInteractionWidgetId(local) == widget_id) return local;
    }
    return null;
}

fn terminalInteractionFrame(
    runtime: *native_sdk.Runtime,
    window_id: native_sdk.platform.WindowId,
    id: LocalTerminalId,
) ?geometry.RectF {
    const widget_id = terminalInteractionWidgetId(id);
    for (runtime.views[0..runtime.view_count]) |*runtime_view| {
        if (runtime_view.window_id != window_id or !std.mem.eql(u8, runtime_view.label, canvas_label)) continue;
        const node = runtime_view.widgetLayoutTree().findById(widget_id) orelse return null;
        if (node.widget.kind != .terminal) return null;
        return node.frame;
    }
    return null;
}

fn initFx(model: *Model, fx: *Fx) void {
    for (0..max_terminal_count) |index| {
        if (model.provider.states[index] == .active) spawnPane(model.provider.slot(index), fx);
    }
    openPhuxChannel(model, fx, false);
    openPointerMonitor(model, fx);
}

fn openPhuxChannel(model: *Model, fx: *Fx, reconnect: bool) void {
    const remote = model.phux() orelse return;
    const handle = fx.openChannel(.{
        .key = phux_channel_key,
        .on_event = Fx.channelMsg(.phux_channel),
        .max_pending = 1,
    });
    if (!handle.live()) return;
    if (reconnect) {
        remote.reconnect(handle) catch {
            fx.closeChannel(phux_channel_key);
            return;
        };
    } else {
        remote.open(handle) catch {
            fx.closeChannel(phux_channel_key);
            return;
        };
    }
}
fn openPointerMonitor(model: *Model, fx: *Fx) void {
    if (comptime !phux_enabled) return;
    const pointer_state = model.pointer_state orelse return;
    if (pointer_state.monitor != null) return;
    const handle = fx.openChannel(.{
        .key = pointer_channel_key,
        .on_event = Fx.channelMsg(.pointer_channel),
        .max_pending = 1,
    });
    if (!handle.live()) return;
    pointer_state.monitor = pointer_module.Monitor.start(
        std.heap.page_allocator,
        &pointer_state.queue,
        handle,
    ) catch {
        fx.closeChannel(pointer_channel_key);
        return;
    };
}

fn spawnPane(pane: *Pane, fx: *Fx) void {
    const model = pane;
    model.session_generation +%= 1;
    if (model.session_generation == 0) model.session_generation = 1;
    model.phase = .starting;
    model.exit_code = 0;
    model.exit_signal = 0;
    model.exit_reason = .exited;
    // Leave selection mode: reset() clears the emulator's selection, so
    // a lingering `selecting` flag would show a caret over no selection
    // AND make the new shell reject all typed text until Escape.
    model.selecting = false;
    // The copy feedback belonged to the session that ended — the new
    // shell's status line must not claim its predecessor's clipboard.
    model.copied_bytes = 0;
    model.copy_failed = false;
    model.macos_natural_keys_held = 0;
    model.scrollback_wheel_accum = 0;
    model.mouse_wheel_y_accum = 0;
    model.mouse_wheel_x_accum = 0;
    model.mouse_wheel_next_horizontal = false;
    model.mouse_last_cell = null;
    model.mouse_protocol_fingerprint = 0;
    model.output_batches = 0;
    model.output_bytes = 0;
    // Drop any bytes still queued for the session that just ended — a
    // restarted shell must not receive the dead one's unsent keystrokes.
    model.outbound_head = 0;
    model.outbound_len = 0;
    model.outbound_dropped = 0;
    // Delivery accounting is generation-local.
    model.write_refusals = 0;
    model.write_refusals_total = 0;
    model.native_delivery_failures = 0;
    // Hard-reset the emulator so a restarted shell starts from a clean
    // terminal — no leftover mode (application-cursor, reverse video),
    // scrollback, palette override, or partial escape sequence from the
    // session that just ended. (A no-op on the first spawn.)
    model.session.reset();
    model.session.refreshScreenText();
    fx.ptySpawn(.{
        .key = model.pty_key,
        .argv = model.argv,
        .cols = model.cols,
        .rows = model.rows,
        .on_event = Fx.ptyMsg(.shell),
    });
}

/// The pane owning a keyed pty event. An event for a key no pane holds
/// (a stale exit after a restart raced) is ignored rather than applied
/// to the wrong terminal.
fn paneForKey(model: *Model, key: u64) ?*Pane {
    return model.provider.terminalForPty(key);
}

/// The terminal that should currently believe it holds keyboard focus, or
/// null when nothing remote should.
///
/// Remote focus is DERIVED, never announced by individual message arms. Focus
/// moves through many paths — tab shortcuts, tab cycling, a pointer press, New,
/// Close, attach/detach, leaving for the Web surface, the window itself losing
/// key — and every arm that has to remember to publish it is an arm that can
/// forget. Several already had: keyboard tab selection left a Phux terminal
/// latched focused while typing went elsewhere, and returning from Web
/// re-selected a terminal that had been told it was blurred.
pub fn remoteFocusTarget(model: *const Model) ?TerminalRef {
    if (!model.focused) return null;
    if (model.selected_surface == .web) return null;
    const terminal_ref = model.focusedTerminalRef() orelse return null;
    if (providerKind(terminal_ref) != .phux) return null;
    return terminal_ref;
}

fn remoteFocusOwner(model: *const Model) ?ReplicaOwner {
    const terminal_ref = remoteFocusTarget(model) orelse return null;
    return model.terminalOwner(terminal_ref);
}

pub fn update(model: *Model, msg: Msg, fx: *Fx) void {
    const focus_before = remoteFocusTarget(model);
    const owner_before = remoteFocusOwner(model);
    updateModel(model, msg, fx);
    const focus_after = remoteFocusTarget(model);
    const owner_after = remoteFocusOwner(model);
    if (!optRefEql(focus_before, focus_after)) {
        // Blur first, then focus: a provider that sees two focused terminals
        // for even one message would have to guess which owns the keyboard.
        if (focus_before) |terminal_ref| sendRemoteFocus(model, terminal_ref, false);
        if (focus_after) |terminal_ref| sendRemoteFocus(model, terminal_ref, true);
    } else if (!optOwnerEql(owner_before, owner_after)) {
        // Same identity, new replica: it has never received current focus.
        if (focus_after) |terminal_ref| sendRemoteFocus(model, terminal_ref, true);
    }
}

fn updateModel(model: *Model, msg: Msg, fx: *Fx) void {
    switch (msg) {
        .shell => |event| {
            // Every pty event carries its own key: route it to the pane
            // that owns that key, never to "the" terminal.
            const pane = paneForKey(model, event.key) orelse return;
            // Closing resources retain their exact transport key solely for
            // the terminal exit acknowledgement. Late output, including VT
            // queries that would synthesize replies, is discarded untouched.
            if (model.provider.isClosing(pane.id)) {
                if (event.kind == .exit) model.provider.retireClosing(pane.id);
                return;
            }
            switch (event.kind) {
                .output => {
                    pane.phase = .live;
                    pane.output_batches += 1;
                    pane.output_bytes += event.bytes.len;
                    const pointer_protocol_before = pane.mouse_protocol_fingerprint;
                    feedOutput(pane, fx, event.bytes);
                    syncMouseProtocol(pane);
                    if (pointer_protocol_before != 0 and pointer_protocol_before != pane.mouse_protocol_fingerprint) {
                        endMismatchedMouseCaptures(model, fx, pane);
                    }
                    // Cells changed: refresh the grid's accessibility text
                    // (which also carries real cell state into the session
                    // fingerprint — byte counters alone would verify a
                    // wrong screen).
                    pane.session.refreshScreenText();
                    // An armed selection follows the TEXT the emulator's
                    // absolute pins track — output that scrolled the screen
                    // moves the caret with the selected cells, and a range
                    // that left the viewport clears selection mode rather
                    // than desynchronizing the caret from the copyable text.
                    if (pane.selecting and !pane.session.rebaseSelection()) {
                        pane.selecting = false;
                    }
                    // The child produced output, so it is reading: its stdin
                    // FIFO likely has room now — push any pending outbound,
                    // then let a reply the full ring retained take the room
                    // the flush just freed (stdin order: it is older than
                    // anything a later dispatch could enqueue).
                    flushOutbound(pane, fx);
                    moveResponsesToOutbound(pane, fx);
                },
                .exit => {
                    pane.phase = if (event.reason == .rejected or event.reason == .spawn_failed) .failed else .ended;
                    pane.exit_code = event.code;
                    pane.exit_signal = event.signal;
                    pane.exit_reason = event.reason;
                    // The exit report proves this generation is no longer
                    // live. Retire captures without synthesizing input to it.
                    endCapturesForTerminal(model, fx, pane.id);
                    pane.native_delivery_failures = event.dropped_writes -| pane.write_refusals_total;
                    pane.write_refusals = 0;
                    // The child is gone: bytes still queued can never land —
                    // drop them COUNTED (they are outbound loss like any
                    // other), and drop retained emulator replies too — ALSO
                    // counted (a DSR reply the full ring retained is outbound
                    // loss the same way) — or the frame pump would retry
                    // flushing them against the dead key until restart.
                    pane.outbound_dropped += pane.outbound_len;
                    pane.outbound_dropped += pane.session.pendingResponses().len;
                    pane.outbound_head = 0;
                    pane.outbound_len = 0;
                    pane.session.clearResponses();
                },
                // Write-admission verdicts are journal-only (replay
                // machinery); the engine never delivers one as an event.
                .write => unreachable,
            }
        },
        .phux_channel => |event| {
            if (event.key != phux_channel_key) return;
            const remote = model.phux() orelse return;
            switch (event.kind) {
                .data => {
                    const delta = remote.drainReadiness() catch {
                        remote.stop();
                        fx.closeChannel(phux_channel_key);
                        return;
                    };
                    if (delta.detached) {
                        remote.stop();
                        fx.closeChannel(phux_channel_key);
                        return;
                    }
                    const terminal_set_changed =
                        delta.ready_published or delta.added_count != 0 or delta.removed_count != 0;
                    if (terminal_set_changed) model.reconcileRemoteTerminals();
                },
                .closed, .rejected => {
                    remote.stop();
                    openPhuxChannel(model, fx, remote.state() != .new);
                },
            }
        },
        .pointer_channel => |event| {
            if (comptime !phux_enabled) return;
            if (event.key != pointer_channel_key) return;
            const pointer_state = model.pointer_state orelse return;
            switch (event.kind) {
                .data => drainPointerEvents(model),
                .closed, .rejected => {
                    if (pointer_state.monitor) |*monitor| monitor.stop();
                    pointer_state.monitor = null;
                    pointer_state.queue.reset();
                    pointer_state.capture = null;
                    openPointerMonitor(model, fx);
                },
            }
        },
        .key => |event| handleKey(model, fx, event),
        .text => |event| {
            if (!model.focused or model.selectedTerminalRef() == null or event.text.len == 0) return;
            const terminal_ref = model.focusedTerminalRef() orelse return;
            if (model.provider.terminal(terminal_ref)) |pane| {
                if (pane.selecting or !pane.acceptsInput()) return;
                if (pane.session.selectionActive()) pane.session.clearSelection();
                pane.session.scrollToBottom();
                sendCommittedText(pane, fx, event.text);
                return;
            }
            const state = model.remoteUi(terminal_ref) orelse return;
            if (state.selecting) return;
            const remote = model.phux() orelse return;
            remote.scrollViewport(state.owner, .{ .kind = .bottom }) catch return;
            var input: KeyInput = .{
                .action = .press,
                .physical = @enumFromInt(0),
                .modifiers = providerModifiers(event),
                .text = event.text,
            };
            remote.sendKey(state.owner, &input) catch {};
        },
        .viewport => |size| {
            // Remember the surface the frame pump measured against, so
            // the wheel hit test has rectangles to resolve into.
            model.surface_size = size.size;
            if (validScale(size.scale_factor)) model.surface_scale_factor = size.scale_factor;
            if (model.provider.terminal(size.terminal_ref)) |pane| {
                // Commit the new size only once the emulator actually took
                // it: on an allocation failure the model keeps its old
                // dimensions and the frame pump retries next frame, so the
                // emulator and the pty never disagree about the grid.
                if (!pane.session.resize(size.cols, size.rows)) return;
                pane.cols = size.cols;
                pane.rows = size.rows;
                pane.session.refreshScreenText();
                fx.ptyResize(pane.pty_key, size.cols, size.rows);
                flushOutbound(pane, fx);
                return;
            }
            const remote = model.phux() orelse return;
            remote.viewportResize(size.terminal_ref, .{
                .cols = size.cols,
                .rows = size.rows,
            }) catch {};
        },
        .surface_resized => |surface| {
            model.surface_size = surface.size;
            if (validScale(surface.scale_factor)) model.surface_scale_factor = surface.scale_factor;
        },
        .flush_outbound => {
            for (0..max_terminal_count) |index| {
                if (model.provider.states[index] != .active) continue;
                const pane = model.provider.slot(index);
                flushOutbound(pane, fx);
                // The drain may have freed room for query replies a full
                // ring left retained in the emulator's buffer.
                moveResponsesToOutbound(pane, fx);
            }
        },
        .selection_autoscroll => handleSelectionAutoscroll(model, fx),
        .chrome_changed => |chrome| {
            model.chrome_top = chrome.insets.top;
        },
        .focus_changed => |focused| {
            if (model.focused == focused) return;
            model.focused = focused;
            // Window blur strands every pane's held-key latches, not
            // only the focused one's.
            if (!focused) {
                endAllCaptures(model, fx);
                for (0..max_terminal_count) |index| {
                    if (model.provider.states[index] != .vacant) model.provider.slot(index).macos_natural_keys_held = 0;
                }
                model.consumed_shortcut_keys_held = 0;
                for (&model.held_terminal_keys) |*held| held.* = .{};
            }
        },
        .pointer => |pointer| handleTerminalPointer(model, fx, pointer),
        .wheel_fallback => |wheel| {
            if (model.selectedTerminalRef() == null) return;
            const terminal_ref = terminalRefAtPoint(model, wheel.x, wheel.y) orelse return;
            if (model.provider.terminal(terminal_ref)) |pane| {
                handleTerminalPointer(model, fx, .{
                    .terminal_id = provider_contract.localId(pane.id) orelse return,
                    .generation = pane.session_generation,
                    .phase = .wheel,
                    .point = geometry.PointF.init(wheel.x, wheel.y),
                    .frame = paneFrameForTerminal(model, pane.id) orelse return,
                    .delta = geometry.OffsetF.init(0, wheel.delta),
                });
                return;
            }
            // A remote terminal has no local emulator to scroll: accumulate
            // against the shared cell metric and ask the provider to move its
            // own viewport.
            const state = model.remoteUi(terminal_ref) orelse return;
            if (state.selecting) return;
            const cell_h = @max(1, canvas.terminalCellMetrics(cockpitTokens(model)).height);
            state.wheel_accum += wheel.delta;
            const rows = @trunc(state.wheel_accum / cell_h);
            if (rows != 0) {
                state.wheel_accum -= rows * cell_h;
                const remote = model.phux() orelse return;
                remote.scrollViewport(state.owner, .{
                    .kind = .delta,
                    .value = -@as(i64, @intFromFloat(rows)),
                }) catch {};
            }
        },
        .copy_selection => {
            if (model.selectedTerminalId() == null) return;
            copySelection(model, fx, model.focusedPane().id);
        },
        .copy_terminal => |id| copySelection(model, fx, id),
        .paste_terminal => |id| requestPaste(model, fx, id),
        .clipboard => |result| {
            if (!model.copy_inflight) return;
            model.copy_inflight = false;
            if (!model.ownerIsCurrent(model.copy_owner)) return;
            if (model.provider.terminal(model.copy_owner.terminal_ref)) |pane| {
                if (result.outcome == .ok) {
                    // Native terminals keep the copied range highlighted, as
                    // every macOS terminal does. Typing, a new selection, or a
                    // restart clears it; a successful copy does not.
                    pane.selecting = false;
                } else {
                    pane.copied_bytes = 0;
                    pane.copy_failed = true;
                }
                return;
            }
            const state = model.remoteUi(model.copy_owner.terminal_ref) orelse return;
            if (result.outcome == .ok) {
                clearRemoteSelection(model, state);
            } else {
                state.copied_bytes = 0;
                state.copy_failed = true;
            }
        },
        .paste_clipboard => |result| {
            if (!model.paste_inflight) return;
            model.paste_inflight = false;
            if (!model.ownerIsCurrent(model.paste_owner)) return;
            if (result.outcome != .ok) {
                model.paste_failed = true;
                return;
            }
            if (model.provider.terminal(model.paste_owner.terminal_ref)) |pane| {
                if (!pane.acceptsInput()) {
                    model.paste_failed = true;
                    return;
                }
                model.paste_failed = false;
                pasteClipboardText(model, pane, fx, result.text);
                return;
            }
            const remote = model.phux() orelse return;
            remote.sendPaste(model.paste_owner, result.text, false) catch {
                model.paste_failed = true;
                return;
            };
            model.paste_failed = false;
        },
        .restart => |placement| {
            // Restart ONLY a genuinely finished session. During
            // `.starting` (spawned, no output yet) or `.live` the pty
            // still holds the key, so respawning would collide on the
            // same key — a rejected exit that strands the running
            // original with no input.
            const pane = model.terminalAt(placement) orelse return;
            if (pane.phase != .ended and pane.phase != .failed) return;
            // Keep the clipboard key occupied until cancellation delivers;
            // the generation check above discards the stale result.
            if (model.copy_inflight and model.copy_owner.terminal_ref.eql(pane.id)) fx.cancel(clipboard_key);
            // Keep the read latched until its cancellation terminal
            // arrives, preventing key reuse while the old effect still
            // owns it. The generation fence above discards that result.
            if (model.paste_owner.terminal_ref.eql(pane.id)) {
                model.paste_failed = false;
                if (model.paste_inflight) fx.cancel(paste_clipboard_key);
            }
            endCapturesForTerminal(model, fx, pane.id);
            spawnPane(pane, fx);
        },
        .focus_pane => |requested| {
            if (model.attachments[requested.index()] == null) return;
            if (requested == model.focus_placement) return;
            model.focus_placement = requested;
            model.selected_surface = .{ .terminal = model.attachments[requested.index()].? };
            endHiddenCaptures(model, fx);
        },
        .select_surface => |surface| {
            if (surface.eql(model.selected_surface)) return;
            switch (surface) {
                .terminal => |id| {
                    if (!model.selectTerminal(id)) return;
                },
                .web => model.selected_surface = .web,
            }
            endHiddenCaptures(model, fx);
        },
        .select_position => |position| {
            if (position < model.terminal_count) {
                _ = model.selectTerminal(model.terminal_order[position]);
            } else if (position == model.terminal_count) {
                model.selected_surface = .web;
            }
            endHiddenCaptures(model, fx);
        },
        .cycle_tab => |delta| {
            const count: i8 = @intCast(model.terminal_count + 1);
            const current: i8 = if (model.selectedTerminalId()) |id|
                @intCast(model.terminalOrderIndex(id) orelse 0)
            else
                @intCast(model.terminal_count);
            const next: usize = @intCast(@mod(current + delta, count));
            if (next == model.terminal_count) {
                model.selected_surface = .web;
            } else {
                _ = model.selectTerminal(model.terminal_order[next]);
            }
            endHiddenCaptures(model, fx);
        },
        .new_terminal => {
            // Tab order is the binding capacity, not the local registry:
            // remote terminals occupy the same bounded order.
            if (model.terminal_count >= max_terminal_count) return;
            const pane = model.provider.createTerminal() catch return;
            _ = model.admitToOrder(pane.id);
            _ = model.selectTerminal(pane.id);
            endHiddenCaptures(model, fx);
            spawnPane(pane, fx);
        },
        .close_terminal => {
            const id = model.selectedTerminalRef() orelse return;
            // Close owns LOCAL lifetime only. A Phux terminal exists because
            // its coordinator says so; cmd+W must not pretend to end it.
            if (providerKind(id) != .local) return;
            const order_index = model.terminalOrderIndex(id) orelse return;
            endCapturesForTerminal(model, fx, id);
            const pane = model.provider.beginClose(id) orelse return;
            const had_live_pty = pane.phase == .starting or pane.phase == .live;
            if (model.copy_inflight and model.copy_owner.terminal_ref.eql(id)) fx.cancel(clipboard_key);
            if (model.paste_inflight and model.paste_owner.terminal_ref.eql(id)) fx.cancel(paste_clipboard_key);
            model.dropFromOrder(order_index);
            for (&model.attachments) |*attached| {
                if (attached.* != null and attached.*.?.eql(id)) attached.* = null;
            }
            if (model.terminal_count == 0) {
                model.selected_surface = .web;
                model.layout = .single;
                model.attachments = .{ null, null };
                model.focus_placement = .primary;
            } else {
                const next_index = @min(order_index, model.terminal_count - 1);
                model.selected_surface = .{ .terminal = model.terminal_order[next_index] };
                model.normalizeTopology();
                model.reconcileAttachmentFocus();
            }
            endHiddenCaptures(model, fx);
            if (had_live_pty) {
                fx.ptyKill(pane.pty_key);
            } else {
                model.provider.retireClosing(id);
            }
        },
        .move_terminal => |delta| {
            const id = model.selectedTerminalId() orelse return;
            _ = model.moveTerminal(id, delta);
        },
        .toggle_tab_placement => {
            model.tab_placement = if (model.tab_placement == .top) .side else .top;
            endHiddenCaptures(model, fx);
        },
        .toggle_split => {
            if (!splitAvailable(model)) return;
            model.layout = if (model.layout == .single) .split else .single;
            model.normalizeTopology();
            endHiddenCaptures(model, fx);
        },
        .split_resized => |fraction| {
            if (!std.math.isFinite(fraction)) return;
            model.split_fraction = std.math.clamp(fraction, 0.05, 0.95);
        },
        .cycle_pane => |delta| {
            if (model.layout != .split or model.selectedTerminalId() == null) return;
            const current: i8 = @intCast(@intFromEnum(model.focus_placement));
            const next = @mod(current + delta, @as(i8, @intCast(pane_count)));
            const placement = Placement.fromIndex(@intCast(next)).?;
            if (model.attachments[placement.index()] != null) updateModel(model, .{ .focus_pane = placement }, fx);
        },
        .browser_page => |page| {
            model.browser_page = page;
            model.browser_navigation_token +%= 1;
            model.selected_surface = .web;
            endHiddenCaptures(model, fx);
        },
        .attach_terminal => |attachment| {
            model.attach(attachment.placement, attachment.terminal_ref) catch return;
        },
        .detach_terminal => |placement| {
            if (model.attachments[placement.index()]) |id| endCapturesForTerminal(model, fx, id);
            _ = model.detach(placement);
            endHiddenCaptures(model, fx);
        },
    }
}

fn paneFrameForTerminal(model: *const Model, id: TerminalRef) ?geometry.RectF {
    const frames = paneFrames(model, model.surface_size);
    for (model.attachments, 0..) |attached, index| {
        if (attached != null and attached.?.eql(id) and !frames[index].isEmpty()) return frames[index];
    }
    return null;
}

/// The provider-qualified terminal whose rect contains a view point, or null
/// when the point stands over chrome, a gutter, or outside the panes.
fn terminalRefAtPoint(model: *const Model, x: f32, y: f32) ?TerminalRef {
    const frames = paneFrames(model, model.surface_size);
    for (frames, 0..) |frame, index| {
        if (frame.width <= 0 or frame.height <= 0) continue;
        if (x >= frame.x and x < frame.x + frame.width and
            y >= frame.y and y < frame.y + frame.height)
        {
            return model.attachments[Placement.fromIndex(index).?.index()];
        }
    }
    return null;
}
fn terminalFrame(model: *const Model, terminal_ref: TerminalRef) ?geometry.RectF {
    const frames = paneFrames(model, model.surface_size);
    for (model.attachments, 0..) |attached, index| {
        if (attached) |value| {
            if (value.eql(terminal_ref)) return frames[index];
        }
    }
    return null;
}

fn pointerButton(button: u32) MouseButton {
    return switch (button) {
        0 => .left,
        1 => .right,
        2 => .middle,
        3 => .button_4,
        4 => .button_5,
        else => .none,
    };
}

fn sendPointerToOwner(
    model: *Model,
    owner: ReplicaOwner,
    action: MouseAction,
    button: MouseButton,
    modifiers: ModifierMask,
    x: f64,
    y: f64,
) bool {
    if (comptime !phux_enabled) return false;
    if (!model.ownerIsCurrent(owner)) return false;
    const frame = terminalFrame(model, owner.terminal_ref) orelse return false;
    const presentation = model.remotePresentation(owner.terminal_ref) orelse return false;
    if (frame.width <= 0 or frame.height <= 0 or presentation.cols == 0 or presentation.rows == 0)
        return false;
    const remote = model.phux() orelse return false;
    if (!(remote.mouseTracking(owner) catch return false)) return false;

    const local_x = @max(0, @min(
        @as(f64, @floatCast(frame.width)) - 1,
        x - @as(f64, @floatCast(frame.x)),
    ));
    const local_y = @max(0, @min(
        @as(f64, @floatCast(frame.height)) - 1,
        y - @as(f64, @floatCast(frame.y)),
    ));
    const cell_x = @min(
        @as(u16, @intFromFloat(@floor(
            local_x * @as(f64, @floatFromInt(presentation.cols)) /
                @as(f64, @floatCast(frame.width)),
        ))),
        presentation.cols - 1,
    );
    const cell_y = @min(
        @as(u16, @intFromFloat(@floor(
            local_y * @as(f64, @floatFromInt(presentation.rows)) /
                @as(f64, @floatCast(frame.height)),
        ))),
        presentation.rows - 1,
    );
    remote.sendMouse(owner, &.{
        .action = action,
        .button = button,
        .modifiers = modifiers,
        .x = @floatFromInt(cell_x),
        .y = @floatFromInt(cell_y),
    }) catch return false;
    return true;
}

fn dispatchPointerEvent(model: *Model, event: anytype) void {
    if (comptime !phux_enabled) return;
    const pointer_state = model.pointer_state orelse return;
    pointer_state.last_x = event.x;
    pointer_state.last_y = event.y;
    const action: MouseAction = switch (event.eventKind() orelse return) {
        .button_down => .press,
        .button_up => .release,
        .motion => .move,
    };
    const button = pointerButton(event.button);

    var owner = if (pointer_state.capture) |capture|
        capture.owner
    else blk: {
        const terminal_ref = terminalRefAtPoint(
            model,
            @floatCast(event.x),
            @floatCast(event.y),
        ) orelse return;
        if (providerKind(terminal_ref) != .phux) return;
        break :blk model.terminalOwner(terminal_ref) orelse return;
    };
    if (!model.ownerIsCurrent(owner)) {
        pointer_state.capture = null;
        const terminal_ref = terminalRefAtPoint(
            model,
            @floatCast(event.x),
            @floatCast(event.y),
        ) orelse return;
        if (providerKind(terminal_ref) != .phux) return;
        owner = model.terminalOwner(terminal_ref) orelse return;
    }

    const sent = sendPointerToOwner(
        model,
        owner,
        action,
        button,
        @bitCast(event.modifiers),
        event.x,
        event.y,
    );
    if (action == .press and sent and button != .none) {
        pointer_state.capture = .{ .owner = owner, .button = button };
    } else if (action == .release) {
        pointer_state.capture = null;
    }
}

fn releasePointerCapture(model: *Model) void {
    if (comptime !phux_enabled) return;
    const pointer_state = model.pointer_state orelse return;
    const capture = pointer_state.capture orelse return;
    _ = sendPointerToOwner(
        model,
        capture.owner,
        .release,
        capture.button,
        .{},
        pointer_state.last_x,
        pointer_state.last_y,
    );
    pointer_state.capture = null;
}

fn drainPointerEvents(model: *Model) void {
    if (comptime !phux_enabled) return;
    const pointer_state = model.pointer_state orelse return;
    while (pointer_state.queue.take()) |event| dispatchPointerEvent(model, event);
    if (pointer_state.queue.takeOverflow()) releasePointerCapture(model);
}

fn paneAtPoint(model: *Model, x: f32, y: f32) ?*Pane {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    const frames = paneFrames(model, model.surface_size);
    for (frames, 0..) |frame, index| {
        if (!frame.normalized().containsPoint(geometry.PointF.init(x, y))) continue;
        return model.terminalAt(Placement.fromIndex(index).?);
    }
    return null;
}

fn pointerCaptureIndex(model: *const Model, window_id: native_sdk.platform.WindowId, pointer_id: u64) ?usize {
    for (model.pointer_captures, 0..) |capture, index| {
        if (capture.active and capture.window_id == window_id and capture.pointer_id == pointer_id) return index;
    }
    return null;
}

fn pointerCaptureFor(model: *const Model, window_id: native_sdk.platform.WindowId, pointer_id: u64) ?PointerCapture {
    const index = pointerCaptureIndex(model, window_id, pointer_id) orelse return null;
    return model.pointer_captures[index];
}

fn freePointerCaptureIndex(model: *const Model) ?usize {
    for (model.pointer_captures, 0..) |capture, index| if (!capture.active) return index;
    return null;
}

fn terminalVisible(model: *const Model, id: TerminalRef) bool {
    const selected = model.selectedTerminalRef() orelse return false;
    if (model.layout == .single) return selected.eql(id);
    for (model.attachments) |attached| if (attached != null and attached.?.eql(id)) return true;
    return false;
}

fn paneReportsMouse(pane: *const Pane) bool {
    return pane.acceptsInput() and pane.session.term.flags.mouse_event != .none;
}

fn validPointerGeometry(event: TerminalPointerEvent) bool {
    return std.math.isFinite(event.point.x) and std.math.isFinite(event.point.y) and
        std.math.isFinite(event.frame.x) and std.math.isFinite(event.frame.y) and
        std.math.isFinite(event.frame.width) and std.math.isFinite(event.frame.height) and
        event.frame.width > 0 and event.frame.height > 0;
}

fn handleTerminalPointer(model: *Model, fx: *Fx, event: TerminalPointerEvent) void {
    switch (event.phase) {
        .down => {
            // A second down for the same physical pointer terminates its old
            // lease first. Other pointers remain completely independent.
            if (pointerCaptureIndex(model, event.window_id, event.pointer_id)) |index| endPointerCapture(model, fx, index, true);
            const pane = model.provider.terminal(localRef(event.terminal_id)) orelse return;
            if (pane.session_generation != event.generation or !terminalVisible(model, pane.id)) return;
            if (!validPointerGeometry(event)) return;
            syncMouseProtocol(pane);
            if (event.button == 0 or event.button == 1) {
                for (model.attachments, 0..) |attached, index| {
                    if (attached != null and attached.?.eql(pane.id)) {
                        model.focus_placement = Placement.fromIndex(index).?;
                        model.selected_surface = .{ .terminal = pane.id };
                        break;
                    }
                }
            }

            const slot = freePointerCaptureIndex(model) orelse return;
            const local = geometry.PointF.init(event.point.x - event.frame.x, event.point.y - event.frame.y);
            // An ended child cannot own pointer input. Its last mode flags may
            // still say mouse reporting, but the static viewport must revert to
            // ordinary terminal selection without requiring Shift.
            const mouse_reporting = paneReportsMouse(pane);
            const local_selection = event.button == 0 and (!mouse_reporting or event.modifiers.shift);
            if (local_selection) {
                pane.selecting = false;
                _ = pane.session.pointerSelection(.{
                    .phase = .down,
                    .x = local.x,
                    .y = local.y,
                    .width = event.frame.width,
                    .height = event.frame.height,
                    .click_count = event.click_count,
                });
                model.pointer_captures[slot] = .{
                    .active = true,
                    .window_id = event.window_id,
                    .terminal_id = event.terminal_id,
                    .generation = pane.session_generation,
                    .pointer_id = event.pointer_id,
                    .button = event.button,
                    .mode = .local_selection,
                    .frame = event.frame,
                    .last_point = event.point,
                    .modifiers = event.modifiers,
                };
                return;
            }

            const button = terminalMouseButton(event.button) orelse return;
            if (!mouse_reporting or !pane.acceptsInput()) return;
            pane.selecting = false;
            // A secondary report belongs to the TUI but does not revoke a
            // Shift-created local selection; Cmd+C remains available while
            // mouse reporting owns the native context-click gesture.
            if (event.button != 1) pane.session.clearSelection();
            model.pointer_captures[slot] = .{
                .active = true,
                .window_id = event.window_id,
                .terminal_id = event.terminal_id,
                .generation = pane.session_generation,
                .pointer_id = event.pointer_id,
                .button = event.button,
                .mode = .mouse_report,
                .mouse_protocol_fingerprint = pane.mouse_protocol_fingerprint,
                .frame = event.frame,
                .last_point = event.point,
                .modifiers = event.modifiers,
            };
            if (!encodeMouseReport(model, pane, fx, .press, button, local, event.frame, event.modifiers)) {
                model.pointer_captures[slot].active = false;
            }
        },
        .move => {
            const capture_index = pointerCaptureIndex(model, event.window_id, event.pointer_id);
            if (capture_index) |index| {
                const capture = model.pointer_captures[index];
                const pane = model.provider.terminal(localRef(capture.terminal_id)) orelse {
                    endPointerCapture(model, fx, index, true);
                    return;
                };
                if (pane.session_generation != capture.generation or !terminalVisible(model, pane.id) or
                    (capture.mode == .mouse_report and
                        (!pane.acceptsInput() or !mouseCaptureProtocolMatches(pane, capture))))
                {
                    endPointerCapture(model, fx, index, true);
                    return;
                }
                if (!validPointerGeometry(event)) return;
                model.pointer_captures[index].frame = event.frame;
                model.pointer_captures[index].last_point = event.point;
                model.pointer_captures[index].modifiers = event.modifiers;
                const local = geometry.PointF.init(event.point.x - event.frame.x, event.point.y - event.frame.y);
                switch (capture.mode) {
                    .local_selection => _ = pane.session.pointerSelection(.{
                        .phase = .move,
                        .x = local.x,
                        .y = local.y,
                        .width = event.frame.width,
                        .height = event.frame.height,
                        .click_count = event.click_count,
                    }),
                    .mouse_report => _ = encodeMouseReport(
                        model,
                        pane,
                        fx,
                        .motion,
                        terminalMouseButton(capture.button),
                        local,
                        event.frame,
                        event.modifiers,
                    ),
                }
                return;
            }
            const pane = model.provider.terminal(localRef(event.terminal_id)) orelse return;
            if (pane.session_generation != event.generation or !terminalVisible(model, pane.id) or
                !pane.acceptsInput() or !validPointerGeometry(event)) return;
            syncMouseProtocol(pane);
            if (pane.session.term.flags.mouse_event == .none or event.modifiers.shift) return;
            const local = geometry.PointF.init(event.point.x - event.frame.x, event.point.y - event.frame.y);
            _ = encodeMouseReport(model, pane, fx, .motion, null, local, event.frame, event.modifiers);
        },
        .up, .cancel => {
            const index = pointerCaptureIndex(model, event.window_id, event.pointer_id) orelse return;
            if (validPointerGeometry(event)) {
                model.pointer_captures[index].frame = event.frame;
                model.pointer_captures[index].last_point = event.point;
                model.pointer_captures[index].modifiers = event.modifiers;
            }
            endPointerCapture(model, fx, index, event.phase == .cancel);
        },
        .wheel => {
            const pane = model.provider.terminal(localRef(event.terminal_id)) orelse return;
            if (pane.session_generation != event.generation or !terminalVisible(model, pane.id) or !validPointerGeometry(event)) return;
            const finite_x = std.math.isFinite(event.delta.dx);
            const finite_y = std.math.isFinite(event.delta.dy);
            if ((!finite_x or event.delta.dx == 0) and (!finite_y or event.delta.dy == 0)) return;
            syncMouseProtocol(pane);
            const local = geometry.PointF.init(event.point.x - event.frame.x, event.point.y - event.frame.y);
            if (pane.acceptsInput() and pane.session.term.flags.mouse_event != .none and !event.modifiers.shift) {
                pane.selecting = false;
                pane.session.clearSelection();
                accumulateWheel(&pane.mouse_wheel_y_accum, if (finite_y) event.delta.dy else 0, pane.session.cell_height);
                accumulateWheel(&pane.mouse_wheel_x_accum, if (finite_x) event.delta.dx else 0, pane.session.cell_width);
                flushMouseWheels(model, pane, fx, local, event.frame, event.modifiers);
                return;
            }
            if (pane.selecting or !finite_y) return;
            const cell_h = finiteQuantum(pane.session.cell_height);
            accumulateWheel(&pane.scrollback_wheel_accum, event.delta.dy, cell_h);
            const report_bound: f32 = @floatFromInt(max_mouse_reports_per_event);
            const rows = std.math.clamp(@trunc(pane.scrollback_wheel_accum / cell_h), -report_bound, report_bound);
            if (rows != 0) {
                pane.scrollback_wheel_accum -= rows * cell_h;
                pane.session.scrollLines(-@as(isize, @intFromFloat(rows)));
            }
        },
        .hover => {
            const pane = model.provider.terminal(localRef(event.terminal_id)) orelse return;
            if (pane.session_generation != event.generation or !terminalVisible(model, pane.id) or
                !pane.acceptsInput() or !validPointerGeometry(event)) return;
            syncMouseProtocol(pane);
            if (pane.session.term.flags.mouse_event != .any or event.modifiers.shift) return;
            const local = geometry.PointF.init(event.point.x - event.frame.x, event.point.y - event.frame.y);
            _ = encodeMouseReport(model, pane, fx, .motion, null, local, event.frame, event.modifiers);
        },
    }
}

fn endPointerCapture(model: *Model, fx: *Fx, index: usize, cancelled: bool) void {
    if (index >= model.pointer_captures.len or !model.pointer_captures[index].active) return;
    const capture = model.pointer_captures[index];
    model.pointer_captures[index].active = false;
    const pane = model.provider.terminal(localRef(capture.terminal_id)) orelse return;
    if (pane.session_generation != capture.generation) return;
    const local = geometry.PointF.init(capture.last_point.x - capture.frame.x, capture.last_point.y - capture.frame.y);
    switch (capture.mode) {
        .local_selection => _ = pane.session.pointerSelection(.{
            .phase = if (cancelled) .cancel else .up,
            .x = local.x,
            .y = local.y,
            .width = capture.frame.width,
            .height = capture.frame.height,
        }),
        .mouse_report => if (pane.acceptsInput() and mouseCaptureProtocolMatches(pane, capture)) {
            _ = encodeMouseReport(model, pane, fx, .release, terminalMouseButton(capture.button), local, capture.frame, capture.modifiers);
        },
    }
}

fn endCapturesForTerminal(model: *Model, fx: *Fx, id: TerminalRef) void {
    const local = provider_contract.localId(id) orelse return;
    for (0..model.pointer_captures.len) |index| {
        if (model.pointer_captures[index].active and model.pointer_captures[index].terminal_id == local) {
            endPointerCapture(model, fx, index, true);
        }
    }
}

fn endMismatchedMouseCaptures(model: *Model, fx: *Fx, pane: *Pane) void {
    for (0..model.pointer_captures.len) |index| {
        const capture = model.pointer_captures[index];
        if (capture.active and capture.mode == .mouse_report and
            localRef(capture.terminal_id).eql(pane.id) and capture.generation == pane.session_generation and
            capture.mouse_protocol_fingerprint != pane.mouse_protocol_fingerprint)
        {
            endPointerCapture(model, fx, index, true);
        }
    }
}

fn endAllCaptures(model: *Model, fx: *Fx) void {
    for (0..model.pointer_captures.len) |index| endPointerCapture(model, fx, index, true);
}

fn endHiddenCaptures(model: *Model, fx: *Fx) void {
    for (0..model.pointer_captures.len) |index| {
        if (model.pointer_captures[index].active and !terminalVisible(model, localRef(model.pointer_captures[index].terminal_id))) {
            endPointerCapture(model, fx, index, true);
        }
    }
}

fn modelHasSelectionAutoscroll(model: *const Model) bool {
    for (model.pointer_captures) |capture| {
        if (!capture.active or capture.mode != .local_selection) continue;
        const pane = model.provider.terminalConst(localRef(capture.terminal_id)) orelse continue;
        if (pane.session_generation == capture.generation and
            terminalVisible(model, pane.id) and pane.session.pointerAutoscrollActive()) return true;
    }
    return false;
}

fn handleSelectionAutoscroll(model: *Model, fx: *Fx) void {
    for (0..model.pointer_captures.len) |index| {
        const capture = model.pointer_captures[index];
        if (!capture.active or capture.mode != .local_selection) continue;
        const pane = model.provider.terminal(localRef(capture.terminal_id)) orelse {
            endPointerCapture(model, fx, index, true);
            continue;
        };
        if (pane.session_generation != capture.generation or !terminalVisible(model, pane.id)) {
            endPointerCapture(model, fx, index, true);
            continue;
        }
        _ = pane.session.pointerAutoscroll(.{
            .x = capture.last_point.x - capture.frame.x,
            .y = capture.last_point.y - capture.frame.y,
            .width = capture.frame.width,
            .height = capture.frame.height,
        });
    }
}

fn terminalMouseButton(button: i32) ?vt.input.MouseButton {
    return switch (button) {
        0 => .left,
        1 => .right,
        2 => .middle,
        3 => .four,
        4 => .five,
        5 => .six,
        6 => .seven,
        7 => .eight,
        8 => .nine,
        else => null,
    };
}

fn encodeMouseReport(
    model: *const Model,
    pane: *Pane,
    fx: *Fx,
    action: vt.input.MouseAction,
    button: ?vt.input.MouseButton,
    local: geometry.PointF,
    frame: geometry.RectF,
    modifiers: PointerModifiers,
) bool {
    const session = pane.session;
    syncMouseProtocol(pane);
    if (session.term.flags.mouse_event == .none or !validScale(model.surface_scale_factor) or
        !std.math.isFinite(local.x) or !std.math.isFinite(local.y) or
        !std.math.isFinite(frame.width) or !std.math.isFinite(frame.height) or
        frame.width <= 0 or frame.height <= 0) return false;

    const pixel_protocol = session.term.flags.mouse_format == .sgr_pixels;
    const scaled_width = frame.width * model.surface_scale_factor;
    const scaled_height = frame.height * model.surface_scale_factor;
    const scaled_x = local.x * model.surface_scale_factor;
    const scaled_y = local.y * model.surface_scale_factor;
    if (pixel_protocol and (!std.math.isFinite(scaled_width) or !std.math.isFinite(scaled_height) or
        !std.math.isFinite(scaled_x) or !std.math.isFinite(scaled_y))) return false;
    const screen_width: u32 = if (pixel_protocol)
        boundedMouseDimension(scaled_width)
    else
        session.cols();
    const screen_height: u32 = if (pixel_protocol)
        boundedMouseDimension(scaled_height)
    else
        session.rows();
    const x = if (pixel_protocol)
        boundedMouseCoordinate(scaled_x)
    else
        boundedMouseCoordinate(local.x / finiteQuantum(session.cell_width));
    const y = if (pixel_protocol)
        boundedMouseCoordinate(scaled_y)
    else
        boundedMouseCoordinate(local.y / finiteQuantum(session.cell_height));

    var options: vt.input.MouseEncodeOptions = .{
        .event = session.term.flags.mouse_event,
        .format = session.term.flags.mouse_format,
        .size = .{
            .screen = .{ .width = screen_width, .height = screen_height },
            .cell = .{ .width = 1, .height = 1 },
            .padding = .{},
        },
        .any_button_pressed = paneHasReportingCapture(model, pane.id, pane.session_generation),
        .last_cell = if (pixel_protocol) null else &pane.mouse_last_cell,
    };
    if (action == .release) options.any_button_pressed = false;

    var bytes: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    vt.input.encodeMouse(&writer, .{
        .action = action,
        .button = button,
        .mods = .{
            .shift = modifiers.shift,
            .ctrl = modifiers.control,
            .alt = modifiers.alt,
            .super = modifiers.super,
        },
        .pos = .{ .x = x, .y = y },
    }, options) catch return false;
    const encoded = writer.buffered();
    if (encoded.len == 0) return false;
    enqueueTransient(pane, fx, encoded);
    return true;
}

fn paneHasReportingCapture(model: *const Model, id: TerminalRef, generation: u64) bool {
    const local = provider_contract.localId(id) orelse return false;
    for (model.pointer_captures) |capture| {
        if (capture.active and capture.mode == .mouse_report and capture.terminal_id == local and capture.generation == generation) return true;
    }
    return false;
}

fn mouseCaptureProtocolMatches(pane: *Pane, capture: PointerCapture) bool {
    syncMouseProtocol(pane);
    return capture.mouse_protocol_fingerprint != 0 and
        capture.mouse_protocol_fingerprint == pane.mouse_protocol_fingerprint and
        pane.session.term.flags.mouse_event != .none;
}

fn validScale(scale: f32) bool {
    return std.math.isFinite(scale) and scale > 0;
}

fn finiteQuantum(value: f32) f32 {
    return if (std.math.isFinite(value) and value >= 1)
        @min(value, max_mouse_coordinate)
    else
        1;
}

fn boundedMouseCoordinate(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, -max_mouse_coordinate, max_mouse_coordinate);
}

fn boundedMouseDimension(value: f32) u32 {
    return @intFromFloat(@max(1, @ceil(std.math.clamp(value, 1, max_mouse_coordinate))));
}

fn accumulateWheel(accum: *f32, delta: f32, quantum_value: f32) void {
    if (!std.math.isFinite(accum.*)) accum.* = 0;
    if (!std.math.isFinite(delta) or delta == 0) return;
    const quantum = finiteQuantum(quantum_value);
    const bound = quantum * @as(f32, max_mouse_reports_per_event);
    accum.* = std.math.clamp(accum.* + std.math.clamp(delta, -bound, bound), -bound, bound);
}

fn flushMouseWheelOnce(
    model: *const Model,
    pane: *Pane,
    fx: *Fx,
    accum: *f32,
    positive: vt.input.MouseButton,
    negative: vt.input.MouseButton,
    quantum_value: f32,
    local: geometry.PointF,
    frame: geometry.RectF,
    modifiers: PointerModifiers,
) bool {
    const quantum = finiteQuantum(quantum_value);
    if (@abs(accum.*) < quantum) return false;
    const button = if (accum.* > 0) positive else negative;
    _ = encodeMouseReport(model, pane, fx, .press, button, local, frame, modifiers);
    accum.* += if (accum.* > 0) -quantum else quantum;
    return true;
}

fn flushMouseWheels(
    model: *const Model,
    pane: *Pane,
    fx: *Fx,
    local: geometry.PointF,
    frame: geometry.RectF,
    modifiers: PointerModifiers,
) void {
    var budget = max_mouse_reports_per_event;
    while (budget > 0) : (budget -= 1) {
        const horizontal_first = pane.mouse_wheel_next_horizontal;
        const first = if (horizontal_first)
            flushMouseWheelOnce(model, pane, fx, &pane.mouse_wheel_x_accum, .six, .seven, pane.session.cell_width, local, frame, modifiers)
        else
            flushMouseWheelOnce(model, pane, fx, &pane.mouse_wheel_y_accum, .four, .five, pane.session.cell_height, local, frame, modifiers);
        const second = if (first)
            false
        else if (horizontal_first)
            flushMouseWheelOnce(model, pane, fx, &pane.mouse_wheel_y_accum, .four, .five, pane.session.cell_height, local, frame, modifiers)
        else
            flushMouseWheelOnce(model, pane, fx, &pane.mouse_wheel_x_accum, .six, .seven, pane.session.cell_width, local, frame, modifiers);
        if (!first and !second) return;
        pane.mouse_wheel_next_horizontal = !horizontal_first;
    }
}

fn mouseProtocolFingerprint(pane: *const Pane) u8 {
    return 1 + (@as(u8, @intCast(@intFromEnum(pane.session.term.flags.mouse_event))) << 4) +
        @as(u8, @intCast(@intFromEnum(pane.session.term.flags.mouse_format)));
}

fn syncMouseProtocol(pane: *Pane) void {
    const fingerprint = mouseProtocolFingerprint(pane);
    if (pane.mouse_protocol_fingerprint == fingerprint) return;
    pane.mouse_protocol_fingerprint = fingerprint;
    pane.mouse_last_cell = null;
    pane.mouse_wheel_y_accum = 0;
    pane.mouse_wheel_x_accum = 0;
    pane.mouse_wheel_next_horizontal = false;
}

/// Append outbound bytes (typed keys, pastes, or query replies) to the
/// pending ring in stream order, then flush what the pty's stdin FIFO
/// will take. A large payload is not submitted all at once: `flushOutbound`
/// paces it as the child reads, so the tail is never dropped. Admission
/// is ALL-OR-NOTHING — a query reply or encoded key cut mid-sequence
/// would feed the child a malformed control sequence, which is worse
/// than a whole loss — and the RESULT says which disposal the caller
/// must apply: `true` means the payload is DISPOSED (queued whole, or
/// impossible — larger than the ring itself — and counted as dropped);
/// `false` means it merely does not fit RIGHT NOW, is untouched and
/// uncounted, and the caller retains it to retry as the ring drains.
fn enqueueOutbound(model: *Pane, fx: *Fx, bytes: []const u8) bool {
    const cap = model.outbound_buffer.len;
    if (bytes.len > cap) {
        model.outbound_dropped += bytes.len;
        return true;
    }
    if (bytes.len > cap - model.outbound_len) {
        // The occupancy may be STALE — the child may have resumed
        // reading since the ring filled — so drain what the FIFO will
        // take before refusing: a keystroke arriving between periodic
        // flushes must not drop when flushing would make room now.
        flushOutbound(model, fx);
        if (bytes.len > cap - model.outbound_len) return false;
    }
    for (bytes, 0..) |byte, i| {
        model.outbound_buffer[(model.outbound_head + model.outbound_len + i) % cap] = byte;
    }
    model.outbound_len += bytes.len;
    flushOutbound(model, fx);
    return true;
}

/// Enqueue a TRANSIENT payload (typed text, an encoded key): the event's
/// bytes do not outlive this dispatch, so a right-now refusal cannot be
/// retried later — it is counted as dropped instead, never silent.
/// Hitting this at all means the child ignored the whole 64 KiB ring.
///
/// STDIN ORDER comes first: a query reply retained behind a full ring is
/// OLDER than this keystroke and must reach the child before it. The
/// retained reply gets its retry now; if it still cannot enter the ring,
/// the keystroke must not jump the queue — it drops counted rather than
/// arrive before an answer the child may be parsing toward.
fn enqueueTransient(model: *Pane, fx: *Fx, bytes: []const u8) void {
    moveResponsesToOutbound(model, fx);
    if (model.session.response_len > 0) {
        model.outbound_dropped += bytes.len;
        return;
    }
    if (!enqueueOutbound(model, fx, bytes)) {
        model.outbound_dropped += bytes.len;
    }
}

/// Push as much pending outbound as the pty's stdin FIFO will accept, in
/// per-write-bound chunks. `ptyWrite` reports acceptance — it alone knows
/// the byte- and record-ring limits — so a refused chunk stays in the
/// ring and is retried on the next output, resize, or frame: a
/// non-reading child pauses the stream instead of losing its tail, and a
/// reply is never removed before it actually lands.
fn flushOutbound(model: *Pane, fx: *Fx) void {
    const cap = model.outbound_buffer.len;
    while (model.outbound_len > 0) {
        const run_to_end = cap - model.outbound_head;
        const n = @min(
            native_sdk.max_effect_pty_write_bytes,
            @min(model.outbound_len, run_to_end),
        );
        if (!fx.ptyWrite(model.pty_key, model.outbound_buffer[model.outbound_head .. model.outbound_head + n])) {
            model.write_refusals +|= 1;
            model.write_refusals_total +|= 1;
            break;
        }
        model.write_refusals = 0;
        model.outbound_head = (model.outbound_head + n) % cap;
        model.outbound_len -= n;
    }
}

/// Feed one pty output batch and return the emulator's query answers to
/// the child. A batch can be many times the response buffer, and a
/// pathological all-query batch (thousands of pipelined DSR/DA1 requests)
/// could produce more replies than the buffer holds in one pass — so the
/// batch is fed in sub-slices no larger than the response buffer, with
/// the answers drained after each. The VT stream keeps parser state
/// across slices, so splitting mid-escape-sequence is invisible; each
/// query's reply is well under a slice's worth of input, so the buffer
/// never overflows and no reply is dropped. This keeps the write-back
/// lossless: a child that blocks on a DSR answer never hangs.
fn feedOutput(model: *Pane, fx: *Fx, bytes: []const u8) void {
    const slice_bytes = grid.Session.feed_slice_bytes;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + slice_bytes, bytes.len);
        model.session.feed(bytes[offset..end]);
        moveResponsesToOutbound(model, fx);
        offset = end;
    }
    // A zero-length batch never reaches here (the engine coalesces only
    // non-empty reads), but a batch that produced no output still drains
    // any answer a prior partial sequence completed.
    if (bytes.len == 0) moveResponsesToOutbound(model, fx);
}

/// Move the emulator's query answers (DSR, DA1, ...) into the pending
/// outbound ring, in stream order after whatever input preceded them,
/// then flush. Routing them through the SAME ring as typed input is what
/// makes them lossless: a reply refused by a full FIFO stays queued and
/// retries, never cleared before it lands (which would hang a child
/// blocking on it). Replies are DURABLE (the emulator's buffer holds
/// them), so a ring too full right now leaves them IN PLACE — uncleared,
/// retried on the next output, resize, or frame — instead of discarding
/// an answer the child may be blocked on. Only a queued (or impossible,
/// counted) batch clears; never a torn escape sequence either way.
pub fn moveResponsesToOutbound(model: *Pane, fx: *Fx) void {
    const pending = model.session.pendingResponses();
    if (pending.len > 0) {
        if (!enqueueOutbound(model, fx, pending)) return;
    }
    model.session.clearResponses();
}

/// ONE copy in flight: the clipboard write reuses a fixed key, so a second
/// request before the first result drains would be rejected as a duplicate —
/// and that rejection would overwrite the first copy's success with
/// `copy_failed`. There is one system clipboard, so this holds ACROSS
/// terminals and providers, not per terminal.
fn copySelection(model: *Model, fx: *Fx, terminal_ref: TerminalRef) void {
    if (model.copy_inflight) return;
    if (model.provider.terminal(terminal_ref)) |pane| {
        pane.copy_failed = false;
        const text = (pane.session.selectionText(pane.session.gpa) catch {
            // Serialization failed with a selection ACTIVE: keep the
            // selection for a retry and say so in the status — a copy that
            // silently does nothing would leave the user pasting stale
            // clipboard content.
            pane.copy_failed = true;
            pane.copied_bytes = 0;
            return;
        }) orelse {
            // No emulator range while the MODEL still holds an anchor: a
            // prior selection re-pin failed and cleared the highlight (see
            // `applySelection`), so this copy has nothing to serialize —
            // that is a failed copy, not a quiet no-op.
            if (pane.session.selectionActive()) {
                pane.copy_failed = true;
                pane.copied_bytes = 0;
            }
            return;
        };
        defer pane.session.gpa.free(text);
        pane.copied_bytes = text.len;
        model.copy_inflight = true;
        model.copy_owner = replicaOwnerForPane(pane);
        fx.writeClipboard(.{
            .key = clipboard_key,
            .text = text,
            .on_result = Fx.clipboardMsg(.clipboard),
        });
        return;
    }

    const state = model.remoteUi(terminal_ref) orelse return;
    state.copy_failed = false;
    const remote = model.phux() orelse return;
    const text = remote.selectionText(state.owner, std.heap.page_allocator) catch {
        state.copy_failed = true;
        state.copied_bytes = 0;
        return;
    };
    defer std.heap.page_allocator.free(text);
    state.copied_bytes = text.len;
    model.copy_inflight = true;
    model.copy_owner = state.owner;
    fx.writeClipboard(.{
        .key = clipboard_key,
        .text = text,
        .on_result = Fx.clipboardMsg(.clipboard),
    });
    // Keep the range highlighted after submission and completion. A failed
    // write remains retryable; a successful copy follows native terminal
    // convention until typing, a new selection, or restart clears it.
}

/// One read in flight: the fixed paste key remains occupied until its result
/// is delivered. A repeated Cmd+V is consumed but cannot issue a duplicate
/// request that would only be rejected.
fn requestPaste(model: *Model, fx: *Fx, terminal_ref: TerminalRef) void {
    if (model.paste_inflight) return;
    model.paste_owner = model.terminalOwner(terminal_ref) orelse return;
    model.paste_failed = false;
    if (model.provider.terminal(terminal_ref)) |pane| {
        if (!pane.acceptsInput()) {
            model.paste_failed = true;
            return;
        }
    } else {
        const presentation = model.remotePresentation(terminal_ref) orelse {
            model.paste_failed = true;
            return;
        };
        if (presentation.phase != .live) {
            model.paste_failed = true;
            return;
        }
    }
    model.paste_inflight = true;
    fx.readClipboard(.{
        .key = paste_clipboard_key,
        .on_result = Fx.clipboardMsg(.paste_clipboard),
    });
}

/// Encode a clipboard result exactly as this terminal expects, then
/// admit the complete framing and body as one outbound payload. The
/// clipboard result is dispatch scratch, so the mutable staging buffer
/// also gives `encodePaste` room to normalize newlines and replace unsafe
/// control bytes before the result returns.
fn pasteClipboardText(model: *Model, pane: *Pane, fx: *Fx, text: []const u8) void {
    const fence_bytes = "\x1b[200~".len;
    const staging = pane.session.gpa.alloc(u8, text.len + fence_bytes * 2) catch {
        model.paste_failed = true;
        return;
    };
    defer pane.session.gpa.free(staging);

    const body = staging[fence_bytes .. fence_bytes + text.len];
    @memcpy(body, text);
    const parts = vt.input.encodePaste(body, .fromTerminal(&pane.session.term));
    const start = fence_bytes - parts[0].len;
    @memcpy(staging[start..fence_bytes], parts[0]);
    @memcpy(staging[fence_bytes + text.len .. fence_bytes + text.len + parts[2].len], parts[2]);
    const encoded = staging[start .. fence_bytes + text.len + parts[2].len];

    pane.session.scrollToBottom();
    // Retained terminal replies predate this user input and must enter
    // the shared stream first. If they still cannot move, refusing the
    // whole paste is the only ordering-safe outcome.
    moveResponsesToOutbound(pane, fx);
    if (pane.session.response_len > 0 or encoded.len > pane.outbound_buffer.len) {
        pane.outbound_dropped += encoded.len;
        model.paste_failed = true;
        return;
    }
    if (!enqueueOutbound(pane, fx, encoded)) {
        pane.outbound_dropped += encoded.len;
        model.paste_failed = true;
    }
}

// ------------------------------------------------------------- keyboard

fn onKey(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .key = event };
}

fn onText(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .text = event };
}

fn onWheel(wheel: native_sdk.platform.WheelEvent) ?Msg {
    if (wheel.delta_y == 0) return null;
    return .{ .wheel_fallback = .{ .x = wheel.x, .y = wheel.y, .delta = wheel.delta_y } };
}

fn onChrome(chrome: native_sdk.platform.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
    return switch (event) {
        .activate => .{ .focus_changed = true },
        .deactivate => .{ .focus_changed = false },
        else => null,
    };
}

fn handleKey(model: *Model, fx: *Fx, event: canvas.WidgetKeyboardEvent) void {
    if (!model.focused) return;
    const mods = event.modifiers;
    const primary = mods.hasCommandModifier();

    // A consumed app-shortcut press owns its release too. The latch is
    // window-level because a focus shortcut changes panes before its
    // release arrives.
    if (event.phase == .key_up) {
        const shortcut_mask = appShortcutKeyMask(event.key);
        if (shortcut_mask != 0 and (model.consumed_shortcut_keys_held & shortcut_mask) != 0) {
            model.consumed_shortcut_keys_held &= ~shortcut_mask;
            return;
        }
        const owner = switch (takeHeldTerminalKeyOwner(model, event.key)) {
            .owner => |value| value,
            .consume => return,
            .none => blk: {
                const terminal_ref = model.focusedTerminalRef() orelse return;
                break :blk model.terminalOwner(terminal_ref) orelse return;
            },
        };
        dispatchKeyEvent(model, fx, owner, event, .release);
        return;
    }

    // A registered app shortcut can reach us through both the platform
    // shortcut channel and the canvas key channel. The first delivery owns
    // the physical edge; a duplicate press is consumed until key-up clears it.
    const pressed_shortcut_mask = appShortcutKeyMask(event.key);
    if (pressed_shortcut_mask != 0 and (model.consumed_shortcut_keys_held & pressed_shortcut_mask) != 0) {
        if (primary) return;
        model.consumed_shortcut_keys_held &= ~pressed_shortcut_mask;
    }

    // Tab selection is global and remains available while native WebKit
    // owns the content surface. Releases are latched by physical key above.
    if (primary and !mods.shift and !mods.alt and !mods.control and event.key.len == 1 and event.key[0] >= '1' and event.key[0] <= '5') {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .select_position = event.key[0] - '1' }, fx);
        return;
    }
    if (primary and mods.shift and !mods.alt and !mods.control and keyIs(event.key, "[")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .cycle_tab = -1 }, fx);
        return;
    }
    if (primary and mods.shift and !mods.alt and !mods.control and keyIs(event.key, "]")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .cycle_tab = 1 }, fx);
        return;
    }
    if (splitAvailable(model) and primary and !mods.shift and !mods.alt and !mods.control and keyIs(event.key, "d")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .toggle_split, fx);
        return;
    }
    if (primary and !mods.shift and !mods.alt and !mods.control and keyIs(event.key, "t")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .new_terminal, fx);
        return;
    }
    if (primary and !mods.shift and !mods.alt and !mods.control and keyIs(event.key, "w")) {
        if (!selectedTerminalCanClose(model)) return;
        latchAppShortcut(model, event.key);
        updateModel(model, .close_terminal, fx);
        return;
    }
    if (primary and mods.shift and !mods.alt and !mods.control and keyIs(event.key, "arrowleft")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .move_terminal = -1 }, fx);
        return;
    }
    if (primary and mods.shift and !mods.alt and !mods.control and keyIs(event.key, "arrowright")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .move_terminal = 1 }, fx);
        return;
    }
    if (model.layout == .split and model.selectedTerminalId() != null and primary and mods.alt and !mods.shift and !mods.control and keyIs(event.key, "arrowleft")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .cycle_pane = -1 }, fx);
        return;
    }
    if (model.layout == .split and model.selectedTerminalId() != null and primary and mods.alt and !mods.shift and !mods.control and keyIs(event.key, "arrowright")) {
        latchAppShortcut(model, event.key);
        updateModel(model, .{ .cycle_pane = 1 }, fx);
        return;
    }

    // A webview is a real native input surface. Unclaimed canvas events
    // must never leak into whichever terminal happened to be focused last.
    if (model.selectedTerminalId() == null) return;

    const terminal_ref = model.focusedTerminalRef() orelse return;
    if (providerKind(terminal_ref) == .phux) {
        handleRemoteKey(model, fx, terminal_ref, event);
        return;
    }

    // Keyboard input belongs to the active terminal tab.
    const pane = model.provider.terminal(terminal_ref) orelse return;
    const session = pane.session;
    // scrollback, restart.
    //
    if (primary and mods.shift and keyIs(event.key, "space")) {
        latchAppShortcut(model, event.key);
        if (pane.selecting) {
            pane.selecting = false;
            session.clearSelection();
        } else {
            pane.selecting = true;
            session.beginSelection(false);
        }
        return;
    }
    if (primary and keyIs(event.key, "c") and (pane.selecting or session.selectionActive())) {
        latchAppShortcut(model, event.key);
        copySelection(model, fx, pane.id);
        return;
    }
    if (primary and keyIs(event.key, "v")) {
        latchAppShortcut(model, event.key);
        requestPaste(model, fx, pane.id);
        return;
    }
    if (primary and keyIs(event.key, "r") and (pane.phase == .ended or pane.phase == .failed)) {
        latchAppShortcut(model, event.key);
        update(model, .{ .restart = model.focus_placement }, fx);
        return;
    }
    // Scrollback chords pause while a keyboard selection is armed: the
    // selection's anchor and head are VIEWPORT coordinates and the
    // emulator range is pinned to absolute cells, so scrolling under an
    // armed selection would leave the painted caret naming different
    // text than a copy returns. (The chords fall through to the
    // selection block below, where primary+arrows are simply inert.)
    if (!pane.selecting) {
        if (primary and keyIs(event.key, "arrowup")) {
            latchAppShortcut(model, event.key);
            session.scrollLines(-if (mods.shift) @as(isize, pane.rows) else 1);
            return;
        }
        if (primary and keyIs(event.key, "arrowdown")) {
            latchAppShortcut(model, event.key);
            session.scrollLines(if (mods.shift) @as(isize, pane.rows) else 1);
            return;
        }
        if (primary and keyIs(event.key, "home")) {
            latchAppShortcut(model, event.key);
            session.scrollToTop();
            return;
        }
        if (primary and keyIs(event.key, "end")) {
            latchAppShortcut(model, event.key);
            session.scrollToBottom();
            return;
        }
    }

    if (pane.selecting) {
        if (keyIs(event.key, "escape")) {
            latchAppShortcut(model, event.key);
            pane.selecting = false;
            session.clearSelection();
            return;
        }
        if (keyIs(event.key, "b")) {
            session.toggleSelectionBlock();
            return;
        }
        if (keyIs(event.key, "enter")) {
            latchAppShortcut(model, event.key);
            copySelection(model, fx, pane.id);
            return;
        }
        const step: i32 = 1;
        if (keyIs(event.key, "arrowleft")) return session.moveSelection(-step, 0, mods.shift);
        if (keyIs(event.key, "arrowright")) return session.moveSelection(step, 0, mods.shift);
        if (keyIs(event.key, "arrowup")) return session.moveSelection(0, -step, mods.shift);
        if (keyIs(event.key, "arrowdown")) return session.moveSelection(0, step, mods.shift);
        return;
    }

    if (!pane.acceptsInput()) return;

    // Everything else is terminal input: specials and chords encode
    // through the emulator (application cursor-key mode, kitty
    // protocol, and modifier encodings all honored); plain printable
    // presses arrive through `.text` instead and are ignored here.
    if (pane.session.selectionActive()) pane.session.clearSelection();
    rememberHeldTerminalKey(model, replicaOwnerForPane(pane), event.key);
    encodeKeyEvent(pane, fx, event, .press);
}

fn providerModifiers(event: canvas.WidgetKeyboardEvent) ModifierMask {
    return .{
        .shift = event.modifiers.shift,
        .control = event.modifiers.control,
        .alt = event.modifiers.alt,
        .super = event.modifiers.super and !event.modifiers.control,
    };
}

fn physicalKeyForEvent(event: canvas.WidgetKeyboardEvent) PhysicalKey {
    const key = event.key;
    if (key.len == 1) {
        const byte = std.ascii.toLower(key[0]);
        if (byte >= 'a' and byte <= 'z') return @enumFromInt(20 + byte - 'a');
        if (byte >= '0' and byte <= '9') return @enumFromInt(6 + byte - '0');
        const value: u32 = switch (byte) {
            '`' => 1,
            '\\' => 2,
            '[' => 3,
            ']' => 4,
            ',' => 5,
            '=' => 16,
            '-' => 46,
            '.' => 47,
            '\'' => 48,
            ';' => 49,
            '/' => 50,
            ' ' => 63,
            else => 0,
        };
        return @enumFromInt(value);
    }
    const value: u32 =
        if (keyIs(key, "alt") or keyIs(key, "option")) 51 else if (keyIs(key, "capslock")) 54 else if (keyIs(key, "control") or keyIs(key, "ctrl")) 56 else if (keyIs(key, "meta") or keyIs(key, "command")) 59 else if (keyIs(key, "shift")) 61 else if (keyIs(key, "backspace")) 53 else if (keyIs(key, "enter")) 58 else if (keyIs(key, "tab")) 64 else if (keyIs(key, "delete")) 68 else if (keyIs(key, "end")) 69 else if (keyIs(key, "home")) 71 else if (keyIs(key, "insert")) 72 else if (keyIs(key, "pagedown")) 73 else if (keyIs(key, "pageup")) 74 else if (keyIs(key, "arrowdown")) 75 else if (keyIs(key, "arrowleft")) 76 else if (keyIs(key, "arrowright")) 77 else if (keyIs(key, "arrowup")) 78 else if (keyIs(key, "escape")) 120 else if (key.len >= 2 and (key[0] == 'f' or key[0] == 'F')) blk: {
            const number = std.fmt.parseInt(u8, key[1..], 10) catch break :blk 0;
            break :blk if (number >= 1 and number <= 25) 120 + number else 0;
        } else 0;
    return @enumFromInt(value);
}

fn dispatchKeyEvent(
    model: *Model,
    fx: *Fx,
    owner: ReplicaOwner,
    event: canvas.WidgetKeyboardEvent,
    action: vt.input.KeyAction,
) void {
    if (!model.ownerIsCurrent(owner)) return;
    if (model.provider.terminal(owner.terminal_ref)) |pane| {
        if (pane.selecting or !pane.acceptsInput()) return;
        encodeKeyEvent(pane, fx, event, action);
        return;
    }
    const remote = model.phux() orelse return;
    const physical = physicalKeyForEvent(event);
    if (@intFromEnum(physical) == 0) return;
    var input: KeyInput = .{
        .action = switch (action) {
            .release => .release,
            .repeat => .repeat,
            else => .press,
        },
        .physical = physical,
        .modifiers = providerModifiers(event),
    };
    remote.sendKey(owner, &input) catch {};
}

fn sendRemoteFocus(model: *Model, terminal_ref: ?TerminalRef, focused: bool) void {
    const ref = terminal_ref orelse return;
    if (providerKind(ref) != .phux) return;
    const owner = model.terminalOwner(ref) orelse return;
    const remote = model.phux() orelse return;
    remote.sendFocus(owner, focused) catch {};
}

fn beginRemoteSelection(model: *Model, terminal_ref: TerminalRef, state: *RemoteUiState) void {
    const presentation = model.remotePresentation(terminal_ref) orelse return;
    const cursor = presentation.grid.cursor orelse canvas.TerminalCursor{};
    const remote = model.phux() orelse return;
    const point: provider_contract.DocumentPoint = .{
        .space = .viewport,
        .row = @as(u32, cursor.y),
        .column = cursor.x,
    };
    const start = remote.createAnchor(state.owner, point) catch return;
    const end = remote.createAnchor(state.owner, point) catch {
        remote.releaseAnchor(state.owner, start);
        return;
    };
    remote.setSelection(state.owner, start, end, false) catch {
        remote.releaseAnchor(state.owner, start);
        remote.releaseAnchor(state.owner, end);
        return;
    };
    state.selecting = true;
    state.rectangle = false;
    state.start_anchor = start.opaque_id;
    state.end_anchor = end.opaque_id;
    state.head_x = cursor.x;
    state.head_y = cursor.y;
}

fn applyRemoteSelection(model: *Model, state: *RemoteUiState) void {
    const remote = model.phux() orelse return;
    const next = remote.createAnchor(state.owner, .{
        .space = .viewport,
        .row = state.head_y,
        .column = state.head_x,
    }) catch return;
    remote.setSelection(
        state.owner,
        .{ .opaque_id = state.start_anchor },
        next,
        state.rectangle,
    ) catch {
        remote.releaseAnchor(state.owner, next);
        return;
    };
    if (state.end_anchor != 0 and state.end_anchor != state.start_anchor)
        remote.releaseAnchor(state.owner, .{ .opaque_id = state.end_anchor });
    state.end_anchor = next.opaque_id;
}

fn moveRemoteSelection(model: *Model, terminal_ref: TerminalRef, state: *RemoteUiState, dx: i32, dy: i32) void {
    const presentation = model.remotePresentation(terminal_ref) orelse return;
    const max_x: i32 = @max(0, @as(i32, presentation.cols) - 1);
    const max_y: i64 = @max(0, @as(i64, presentation.rows) - 1);
    state.head_x = @intCast(std.math.clamp(@as(i32, state.head_x) + dx, 0, max_x));
    state.head_y = @intCast(std.math.clamp(@as(i64, state.head_y) + dy, 0, max_y));
    applyRemoteSelection(model, state);
}

fn clearRemoteSelection(model: *Model, state: *RemoteUiState) void {
    const remote = model.phux() orelse return;
    remote.clearSelection(state.owner) catch return;
    if (state.start_anchor != 0)
        remote.releaseAnchor(state.owner, .{ .opaque_id = state.start_anchor });
    if (state.end_anchor != 0 and state.end_anchor != state.start_anchor)
        remote.releaseAnchor(state.owner, .{ .opaque_id = state.end_anchor });
    state.selecting = false;
    state.rectangle = false;
    state.start_anchor = 0;
    state.end_anchor = 0;
}

fn handleRemoteKey(model: *Model, fx: *Fx, terminal_ref: TerminalRef, event: canvas.WidgetKeyboardEvent) void {
    const state = model.remoteUi(terminal_ref) orelse return;
    const mods = event.modifiers;
    const primary = mods.hasCommandModifier();
    const remote = model.phux() orelse return;

    if (primary and mods.shift and keyIs(event.key, "space")) {
        latchAppShortcut(model, event.key);
        if (state.selecting) clearRemoteSelection(model, state) else beginRemoteSelection(model, terminal_ref, state);
        return;
    }
    if (primary and keyIs(event.key, "c") and state.selecting) {
        latchAppShortcut(model, event.key);
        copySelection(model, fx, terminal_ref);
        return;
    }
    if (primary and keyIs(event.key, "v")) {
        latchAppShortcut(model, event.key);
        requestPaste(model, fx, terminal_ref);
        return;
    }
    if (!state.selecting and primary) {
        if (keyIs(event.key, "arrowup") or keyIs(event.key, "arrowdown")) {
            latchAppShortcut(model, event.key);
            const amount: i64 = if (mods.shift) @intCast((model.remotePresentation(terminal_ref) orelse return).rows) else 1;
            remote.scrollViewport(state.owner, .{
                .kind = .delta,
                .value = if (keyIs(event.key, "arrowup")) -amount else amount,
            }) catch {};
            return;
        }
        if (keyIs(event.key, "home") or keyIs(event.key, "end")) {
            latchAppShortcut(model, event.key);
            remote.scrollViewport(state.owner, .{
                .kind = if (keyIs(event.key, "home")) .top else .bottom,
            }) catch {};
            return;
        }
    }
    if (state.selecting) {
        if (keyIs(event.key, "escape")) {
            latchAppShortcut(model, event.key);
            clearRemoteSelection(model, state);
            return;
        }
        if (keyIs(event.key, "b")) {
            state.rectangle = !state.rectangle;
            applyRemoteSelection(model, state);
            return;
        }
        if (keyIs(event.key, "enter")) {
            latchAppShortcut(model, event.key);
            copySelection(model, fx, terminal_ref);
            return;
        }
        if (keyIs(event.key, "arrowleft")) return moveRemoteSelection(model, terminal_ref, state, -1, 0);
        if (keyIs(event.key, "arrowright")) return moveRemoteSelection(model, terminal_ref, state, 1, 0);
        if (keyIs(event.key, "arrowup")) return moveRemoteSelection(model, terminal_ref, state, 0, -1);
        if (keyIs(event.key, "arrowdown")) return moveRemoteSelection(model, terminal_ref, state, 0, 1);
        return;
    }
    const presentation = model.remotePresentation(terminal_ref) orelse return;
    if (presentation.phase != .live) return;
    rememberHeldTerminalKey(model, state.owner, event.key);
    dispatchKeyEvent(model, fx, state.owner, event, .press);
}

fn terminalKeyFingerprint(key: []const u8) u64 {
    var fingerprint: u64 = 14695981039346656037;
    for (key) |byte| {
        fingerprint ^= std.ascii.toLower(byte);
        fingerprint *%= 1099511628211;
    }
    return if (fingerprint == 0) 1 else fingerprint;
}

fn rememberHeldTerminalKey(model: *Model, owner: ReplicaOwner, key: []const u8) void {
    const fingerprint = terminalKeyFingerprint(key);
    var target: usize = @intCast(fingerprint % max_held_terminal_keys);
    for (&model.held_terminal_keys, 0..) |*held, index| {
        if (held.fingerprint == fingerprint) {
            target = index;
            break;
        }
        if (held.fingerprint == 0) target = index;
    }
    model.held_terminal_keys[target] = .{
        .fingerprint = fingerprint,
        .owner = owner,
    };
}

const HeldTerminalKeyOwner = union(enum) {
    none,
    consume,
    owner: ReplicaOwner,
};

fn takeHeldTerminalKeyOwner(model: *Model, key: []const u8) HeldTerminalKeyOwner {
    const fingerprint = terminalKeyFingerprint(key);
    for (&model.held_terminal_keys) |*held| {
        if (held.fingerprint != fingerprint) continue;
        const owner = held.owner;
        held.* = .{};
        if (!model.ownerIsCurrent(owner)) return .consume;
        return .{ .owner = owner };
    }
    return .none;
}

fn latchAppShortcut(model: *Model, key: []const u8) void {
    model.consumed_shortcut_keys_held |= appShortcutKeyMask(key);
}

fn appShortcutKeyMask(key: []const u8) u32 {
    if (keyIs(key, "1")) return 1 << 0;
    if (keyIs(key, "2")) return 1 << 1;
    if (keyIs(key, "3")) return 1 << 12;
    if (keyIs(key, "4")) return 1 << 20;
    if (keyIs(key, "5")) return 1 << 21;
    if (keyIs(key, "space")) return 1 << 2;
    if (keyIs(key, "c")) return 1 << 3;
    if (keyIs(key, "r")) return 1 << 4;
    if (keyIs(key, "arrowup")) return 1 << 5;
    if (keyIs(key, "arrowdown")) return 1 << 6;
    if (keyIs(key, "home")) return 1 << 7;
    if (keyIs(key, "end")) return 1 << 8;
    if (keyIs(key, "v")) return 1 << 9;
    if (keyIs(key, "escape")) return 1 << 10;
    if (keyIs(key, "enter")) return 1 << 11;
    if (keyIs(key, "d")) return 1 << 13;
    if (keyIs(key, "[")) return 1 << 14;
    if (keyIs(key, "]")) return 1 << 15;
    if (keyIs(key, "arrowleft")) return 1 << 16;
    if (keyIs(key, "arrowright")) return 1 << 17;
    if (keyIs(key, "t")) return 1 << 18;
    if (keyIs(key, "w")) return 1 << 19;
    return 0;
}

fn commandShortcutKeyMask(name: []const u8) u32 {
    // Split is intentionally not globally registered while one terminal may
    // be active, but injected/menu shortcut events still need duplicate-edge
    // suppression once they reach this host.
    if (std.mem.eql(u8, name, "layout.split")) return appShortcutKeyMask("d");
    for (cockpit_shortcuts) |shortcut| {
        if (std.mem.eql(u8, name, shortcut.id)) return appShortcutKeyMask(shortcut.key);
    }
    return 0;
}

/// Encode one key transition and push the bytes toward the child. macOS
/// natural-text arrow gestures use conventional shell bindings;
/// everything else goes through the emulator's encoder. Releases ride
/// the same path with `.release`: the encoder emits them only under the
/// kitty protocol's negotiated event reporting and stays silent in
/// legacy modes. (Key REPEAT is the one event type the hosts do not
/// distinguish from a fresh press, so a TUI that enabled event reporting
/// sees repeats as presses.)
fn encodeKeyEvent(model: *Pane, fx: *Fx, event: canvas.WidgetKeyboardEvent, action: vt.input.KeyAction) void {
    const session = model.session;
    const natural_key_mask = macosNaturalTextKeyMask(event.key);
    if (action == .release and natural_key_mask != 0 and
        (model.macos_natural_keys_held & natural_key_mask) != 0)
    {
        model.macos_natural_keys_held &= ~natural_key_mask;
        return;
    }
    // A fresh press supersedes a stale latch, then re-arms it below when
    // this is another natural-editing gesture (auto-repeat included).
    if (action == .press and natural_key_mask != 0) {
        model.macos_natural_keys_held &= ~natural_key_mask;
    }
    if (macosNaturalTextSequence(event)) |sequence| {
        // Natural-text bindings consume the whole gesture. In
        // particular, a child using kitty event reporting must not
        // receive a release for a modified arrow whose press arrived as
        // legacy editing bytes.
        if (action == .release) return;
        model.macos_natural_keys_held |= natural_key_mask;
        session.scrollToBottom();
        enqueueTransient(model, fx, sequence);
        return;
    }
    const mods = event.modifiers;
    const key = mapKey(event) orelse blk: {
        // A release of a plain printable never maps (its PRESS came
        // through the text channel): synthesize the codepoint-keyed
        // event so kitty event reporting hears the release too.
        if (action != .release) return;
        break :blk mapPrintable(event.key) orelse return;
    };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const encode_options: vt.input.KeyEncodeOptions = .fromTerminal(&session.term);
    // The runtime folds the platform's PRIMARY modifier into `super`.
    // On macOS primary IS the GUI key, so the fold is harmless there —
    // but on hosts whose primary is Ctrl, a bare Ctrl chord arrives as
    // ctrl+super and the encoder would skip its C0 byte (Ctrl+C must
    // deliver ETX and interrupt the child, never a CSI-u chord). Undo
    // the alias for the encoder: super counts only when Ctrl is not the
    // key raising it. (The one loss is the GUI+Ctrl double chord, which
    // encodes as plain Ctrl — the convention terminals follow anyway.)
    const encoder_super = mods.super and !mods.control;
    _ = vt.input.encodeKey(&writer, .{
        .key = key.key,
        .action = action,
        .mods = .{
            .shift = mods.shift,
            .ctrl = mods.control,
            .alt = mods.alt,
            .super = encoder_super,
        },
        .utf8 = key.utf8,
        .unshifted_codepoint = key.unshifted,
    }, encode_options) catch return;
    if (writer.end == 0) return;
    session.scrollToBottom();
    // Through the pending ring like committed text, so an encoded key
    // typed while a paste is still draining lands after it in the stream.
    enqueueTransient(model, fx, buffer[0..writer.end]);
}

fn macosNaturalTextKeyMask(key: []const u8) u8 {
    if (comptime builtin.os.tag != .macos) return 0;
    if (keyIs(key, "arrowleft")) return 1 << 0;
    if (keyIs(key, "arrowright")) return 1 << 1;
    if (keyIs(key, "backspace")) return 1 << 2;
    return 0;
}

/// Match macOS terminals' "natural text editing" bindings. These are
/// exact bare-modifier gestures: shifted or combined chords continue
/// through the key encoder so terminal applications can distinguish
/// them. The raw bindings intentionally bypass negotiated kitty
/// reporting, just as Ghostty's own default keybinds do.
fn macosNaturalTextSequence(event: canvas.WidgetKeyboardEvent) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const mods = event.modifiers;
    if (mods.shift or mods.control) return null;
    if (mods.alt and !mods.super) {
        if (keyIs(event.key, "arrowleft")) return "\x1bb";
        if (keyIs(event.key, "arrowright")) return "\x1bf";
    }
    if (mods.super and !mods.alt) {
        if (keyIs(event.key, "arrowleft")) return "\x01";
        if (keyIs(event.key, "arrowright")) return "\x05";
        // The physical macOS Delete key is normalized as Backspace.
        if (keyIs(event.key, "backspace")) return "\x15";
    }
    return null;
}

/// Committed text reaches the child through the emulator's key encoder
/// when it is a single scalar: byte-identical to the raw text under
/// legacy modes (the encoder writes unmodified text through untouched)
/// and the negotiated CSI-u form when a TUI enabled the kitty
/// protocol's report-all mode — raw bytes there would desynchronize the
/// application's key decoding. Multi-scalar commits (IME words, paste)
/// stay raw text, the protocol's rule for composed input.
fn sendCommittedText(model: *Pane, fx: *Fx, text: []const u8) void {
    single: {
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch break :single;
        if (text.len != len) break :single;
        const cp = std.unicode.utf8Decode(text[0..len]) catch break :single;
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        _ = vt.input.encodeKey(&writer, .{
            .key = .unidentified,
            .action = .press,
            .utf8 = text,
            .unshifted_codepoint = cp,
        }, .fromTerminal(&model.session.term)) catch break :single;
        if (writer.end == 0) break :single;
        enqueueTransient(model, fx, buffer[0..writer.end]);
        return;
    }
    enqueueTransient(model, fx, text);
}

fn keyIs(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

const MappedKey = struct {
    key: vt.input.Key,
    utf8: []const u8 = "",
    unshifted: u21 = 0,
};

/// Host key names -> emulator key codes, for keys that do not commit
/// A plain printable's codepoint-keyed event, for RELEASE encoding
/// only: its press travels the committed-text channel, but kitty event
/// reporting still owes the child the release of the same key. No text
/// rides a release.
fn mapPrintable(key: []const u8) ?MappedKey {
    if (key.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(key[0]) catch return null;
    if (key.len != len) return null;
    const cp = std.unicode.utf8Decode(key[0..len]) catch return null;
    return .{ .key = .unidentified, .unshifted = cp };
}

/// text (specials always; letters/digits only under a chord modifier,
/// where the text channel stays silent and the encoder must speak).
fn mapKey(event: canvas.WidgetKeyboardEvent) ?MappedKey {
    const key = event.key;
    const specials = [_]struct { name: []const u8, key: vt.input.Key }{
        .{ .name = "enter", .key = .enter },
        .{ .name = "tab", .key = .tab },
        .{ .name = "escape", .key = .escape },
        .{ .name = "backspace", .key = .backspace },
        .{ .name = "delete", .key = .delete },
        .{ .name = "arrowup", .key = .arrow_up },
        .{ .name = "arrowdown", .key = .arrow_down },
        .{ .name = "arrowleft", .key = .arrow_left },
        .{ .name = "arrowright", .key = .arrow_right },
        .{ .name = "home", .key = .home },
        .{ .name = "end", .key = .end },
        .{ .name = "pageup", .key = .page_up },
        .{ .name = "pagedown", .key = .page_down },
        .{ .name = "insert", .key = .insert },
        // Function keys produce no committed text, so the encoder must
        // build their escape sequences or the child never sees them.
        .{ .name = "f1", .key = .f1 },
        .{ .name = "f2", .key = .f2 },
        .{ .name = "f3", .key = .f3 },
        .{ .name = "f4", .key = .f4 },
        .{ .name = "f5", .key = .f5 },
        .{ .name = "f6", .key = .f6 },
        .{ .name = "f7", .key = .f7 },
        .{ .name = "f8", .key = .f8 },
        .{ .name = "f9", .key = .f9 },
        .{ .name = "f10", .key = .f10 },
        .{ .name = "f11", .key = .f11 },
        .{ .name = "f12", .key = .f12 },
    };
    for (specials) |entry| {
        if (keyIs(key, entry.name)) return .{ .key = entry.key };
    }
    // Chorded character keys (ctrl+c, alt+f, ...): the text channel is
    // silent for these, so the encoder builds the control sequence.
    // Alt is a chord EXCEPT on macOS, where Option is a compose key —
    // Option+F commits the composed `ƒ` through the text channel, so
    // encoding an Alt-F escape here too would double the input (the
    // child would see both). On macOS, Option composes; everywhere else
    // Alt is Meta (ESC prefix, no composed text) — EXCEPT Ctrl+Alt
    // together ON WINDOWS, which is how that host represents AltGr:
    // the combination composes text there (AltGr+Q commits `@` through
    // the text channel), so encoding it as a chord would send wrong
    // bytes AND shadow the composed character. Linux keeps Ctrl+Alt as
    // a genuine chord — its AltGr is a distinct modifier that never
    // reports as ctrl+alt, so Ctrl+Alt+C must still encode.
    const altgr = event.modifiers.control and event.modifiers.alt and builtin.os.tag == .windows;
    const alt_is_chord = event.modifiers.alt and builtin.os.tag != .macos;
    const chorded = (event.modifiers.control or event.modifiers.super or alt_is_chord) and !altgr;
    if (!chorded) return null;
    if (key.len == 1) {
        // The emulator's encoder expects the pressed CHARACTER as UTF-8
        // alongside the logical key — the shape its host normally
        // supplies — and derives the chord bytes from it: legacy C0
        // sequences (Ctrl+C -> 0x03, Ctrl+\ -> 0x1C) where they exist,
        // and the fixterms CSI-u encoding for the exceptions (Ctrl+[,
        // Ctrl+I, Ctrl+M keep their unchorded bytes unambiguous).
        const ch = key[0];
        const utf8 = key[0..1];
        if (ch >= 'a' and ch <= 'z') {
            const base = @intFromEnum(vt.input.Key.key_a);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - 'a')),
                .utf8 = utf8,
                .unshifted = ch,
            };
        }
        if (ch >= '0' and ch <= '9') {
            const base = @intFromEnum(vt.input.Key.digit_0);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - '0')),
                .utf8 = utf8,
                .unshifted = ch,
            };
        }
        // Chorded punctuation carries real control meaning a terminal
        // user expects — Ctrl+[ is the ESC chord, Ctrl+\ is SIGQUIT,
        // Ctrl+] exits telnet — and has no text-channel fallback, so an
        // unmapped key here is silently lost input.
        const punctuation = [_]struct { ch: u8, key: vt.input.Key }{
            .{ .ch = '[', .key = .bracket_left },
            .{ .ch = ']', .key = .bracket_right },
            .{ .ch = '\\', .key = .backslash },
            .{ .ch = ';', .key = .semicolon },
            .{ .ch = '\'', .key = .quote },
            .{ .ch = ',', .key = .comma },
            .{ .ch = '.', .key = .period },
            .{ .ch = '/', .key = .slash },
            .{ .ch = '-', .key = .minus },
            .{ .ch = '=', .key = .equal },
            .{ .ch = '`', .key = .backquote },
        };
        for (punctuation) |entry| {
            if (ch == entry.ch) return .{ .key = entry.key, .utf8 = utf8, .unshifted = entry.ch };
        }
    }
    if (keyIs(key, "space")) return .{ .key = .space, .utf8 = " ", .unshifted = ' ' };
    return null;
}

// ------------------------------------------------------------------ view

const TerminalUi = TerminalApp.Ui;
const terminal_font_id: canvas.FontId = canvas.min_registered_font_id;
const cockpit_fonts = [_]TerminalApp.FontRegistration{.{
    .id = terminal_font_id,
    .name = "JetBrainsMonoNL Nerd Font Mono Regular",
    .ttf = @embedFile("fonts/JetBrainsMonoNLNerdFontMono-Regular.ttf"),
}};

/// Phux has one visual register regardless of the system appearance: deep
/// graphite surfaces, porcelain text, and lime reserved for focus/action.
/// The built-in Geist dark controls keep their accessibility behavior while
/// the color register aligns the terminal and native chrome with phux.
pub fn cockpitTokens(_: *const Model) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.themeWithOverrides(
        .{ .color_scheme = .dark, .pack = .geist },
        canvas.accentOverrides(canvas.Color.rgb8(190, 242, 100), .dark),
    );
    tokens.colors.background = canvas.Color.rgb8(9, 11, 15);
    tokens.colors.surface = canvas.Color.rgb8(17, 20, 27);
    tokens.colors.surface_subtle = canvas.Color.rgb8(23, 27, 35);
    tokens.colors.surface_pressed = canvas.Color.rgb8(35, 41, 52);
    tokens.colors.text = canvas.Color.rgb8(244, 247, 251);
    tokens.colors.text_muted = canvas.Color.rgb8(154, 164, 178);
    tokens.colors.border = canvas.Color.rgb8(52, 58, 70);
    tokens.colors.accent = canvas.Color.rgb8(190, 242, 100);
    tokens.colors.accent_text = canvas.Color.rgb8(9, 11, 15);
    tokens.colors.warning = canvas.Color.rgb8(253, 224, 71);
    tokens.colors.destructive = canvas.Color.rgb8(248, 113, 113);
    tokens.typography.mono_font_id = terminal_font_id;
    return tokens;
}

fn terminalNumber(id: LocalTerminalId) u64 {
    return @intFromEnum(id) - first_terminal_raw + 1;
}

/// The tab label for a terminal. Local terminals are numbered by mint order;
/// a Phux terminal borrows the title its coordinator published.
fn terminalTitle(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    if (provider_contract.localId(id)) |local| {
        return ui.fmt("Terminal {d}", .{terminalNumber(local)});
    }
    const presentation = model.remotePresentation(id) orelse return "Phux";
    return if (presentation.title.len == 0) "Phux" else presentation.title;
}

fn placementAt(index: usize) Placement {
    return Placement.fromIndex(index) orelse unreachable;
}

/// The retained-command id namespace a terminal paints into. Local terminals
/// take their registry slot, which is bounded and collision-free by
/// construction; remote terminals derive a disjoint namespace from their
/// identity hash, with the high bit set so the two spaces cannot overlap.
fn terminalPaintIndex(model: *const Model, terminal_ref: TerminalRef) usize {
    if (provider_contract.isLocal(terminal_ref)) {
        return model.provider.slotIndex(terminal_ref) orelse 0;
    }
    return @intCast(0x0000_8000_0000_0000 | (terminal_ref.hash() & 0x0000_7fff_ffff_ffff));
}

fn paneLifecycleText(ui: *TerminalUi, pane: *const Pane) []const u8 {
    return switch (pane.phase) {
        .starting => "STARTING",
        .attaching => "ATTACHING",
        .live => "RUNNING",
        .reconnecting => "RECONNECTING",
        .tombstoned => "REMOVED",
        .frozen => "FROZEN",
        .ended => switch (pane.exit_reason) {
            .exited => ui.fmt("EXIT {d}", .{pane.exit_code}),
            .signaled => ui.fmt("SIGNAL {d}", .{pane.exit_signal}),
            .cancelled => "CANCELLED",
            else => "ENDED",
        },
        .failed => switch (pane.exit_reason) {
            .rejected => "SPAWN REJECTED",
            .spawn_failed => "SPAWN FAILED",
            else => "FAILED",
        },
    };
}

fn remoteLifecycleText(phase: Phase) []const u8 {
    return switch (phase) {
        .starting => "STARTING",
        .attaching => "ATTACHING",
        .live => "RUNNING",
        .reconnecting => "RECONNECTING",
        .tombstoned => "REMOVED",
        .frozen => "FROZEN",
        .ended => "ENDED",
        .failed => "FAILED",
    };
}

fn paneLifecycleFailed(pane: *const Pane) bool {
    return pane.phase == .failed or
        (pane.phase == .ended and (pane.exit_reason != .exited or pane.exit_code != 0));
}

fn paneHasConfirmedLoss(pane: *const Pane) bool {
    return pane.outbound_dropped > 0 or pane.session.response_bytes_dropped > 0;
}

fn paneNeedsAttention(model: *const Model, pane: *const Pane) bool {
    const paste_failed = model.paste_owner.terminal_ref.eql(pane.id) and model.paste_failed;
    return pane.phase == .ended or pane.phase == .failed or paneHasConfirmedLoss(pane) or
        pane.write_refusals > 0 or pane.native_delivery_failures > 0 or pane.copy_failed or paste_failed;
}

fn emptyStatusNode(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.stack, .{}, .{});
}

fn paneStatus(ui: *TerminalUi, model: *const Model, index: usize, show_identity: bool) TerminalUi.Node {
    const terminal_ref = model.attachments[placementAt(index).index()] orelse return emptyStatusNode(ui);
    if (providerKind(terminal_ref) == .phux) {
        const presentation = model.remotePresentation(terminal_ref) orelse return ui.el(.badge, .{
            .size = .sm,
            .variant = .secondary,
            .text = "PHUX / FROZEN",
        }, .{});
        const state = model.remoteUiConst(terminal_ref);
        const activity = if (state != null and state.?.selecting)
            ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "SELECTING" }, .{})
        else if (model.paste_owner.terminal_ref.eql(terminal_ref) and model.paste_inflight)
            ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "PASTING" }, .{})
        else if (model.copy_inflight and model.copy_owner.terminal_ref.eql(terminal_ref))
            ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "COPYING" }, .{})
        else
            emptyStatusNode(ui);
        return ui.row(.{ .gap = 4, .cross = .center }, .{
            ui.text(.{
                .style_tokens = .{ .foreground = .text_muted },
                .semantics = .{ .label = ui.fmt("Phux terminal {s}, {s}", .{
                    presentation.title,
                    remoteLifecycleText(presentation.phase),
                }) },
            }, ui.fmt("{s} / {s}", .{
                if (presentation.title.len == 0) "PHUX" else presentation.title,
                remoteLifecycleText(presentation.phase),
            })),
            activity,
        });
    }
    const pane = model.provider.terminalConst(terminal_ref) orelse return emptyStatusNode(ui);
    const lifecycle = paneLifecycleText(ui, pane);
    const title = ui.fmt("TERMINAL {d}", .{terminalNumber(provider_contract.localId(pane.id) orelse .terminal_1)});
    const lifecycle_failed = paneLifecycleFailed(pane);
    const paste_failed = model.paste_owner.terminal_ref.eql(pane.id) and model.paste_failed;
    const lifecycle_semantics = ui.fmt(
        "{s} / {s}; OUTBOUND LOSS {d}B; REPLY LOSS {d}B; INPUT STALLED {d}; DELIVERY FAILURES {d}; {s}; {s}",
        .{
            title,
            lifecycle,
            pane.outbound_dropped,
            pane.session.response_bytes_dropped,
            pane.write_refusals,
            pane.native_delivery_failures,
            if (pane.copy_failed) "COPY FAILED" else "copy ok",
            if (paste_failed) "PASTE FAILED" else "paste ok",
        },
    );
    const lifecycle_node = if (pane.phase == .live and !show_identity)
        emptyStatusNode(ui)
    else if (pane.phase == .live)
        ui.text(.{
            .style_tokens = .{ .foreground = .text_muted },
            .semantics = .{ .label = lifecycle_semantics },
        }, title)
    else if (pane.phase == .starting)
        ui.text(.{
            .style_tokens = .{ .foreground = .text_muted },
            .semantics = .{ .label = lifecycle_semantics },
        }, ui.fmt("{s} / {s}", .{ title, lifecycle }))
    else
        ui.el(.badge, .{
            .size = .sm,
            .variant = if (lifecycle_failed) .destructive else .secondary,
            .text = ui.fmt("{s} / {s}", .{ title, lifecycle }),
            .semantics = .{ .label = lifecycle_semantics },
        }, .{});
    const issue = if (paneHasConfirmedLoss(pane))
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "I/O LOSS" }, .{})
    else if (pane.native_delivery_failures > 0)
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "DELIVERY FAILED" }, .{})
    else if (paste_failed)
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "PASTE FAILED" }, .{})
    else if (pane.copy_failed)
        ui.el(.badge, .{ .size = .sm, .variant = .destructive, .text = "COPY FAILED" }, .{})
    else if (pane.write_refusals > 0)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "INPUT STALLED" }, .{})
    else
        emptyStatusNode(ui);
    const activity = if (pane.selecting)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "SELECTING" }, .{})
    else if (model.paste_owner.terminal_ref.eql(pane.id) and model.paste_inflight)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "PASTING" }, .{})
    else if (model.copy_inflight and model.copy_owner.terminal_ref.eql(pane.id))
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = "COPYING" }, .{})
    else if (pane.copied_bytes > 0)
        ui.el(.badge, .{ .size = .sm, .variant = .secondary, .text = ui.fmt("COPIED {d}B", .{pane.copied_bytes}) }, .{})
    else
        emptyStatusNode(ui);
    return ui.row(.{ .gap = 4, .cross = .center }, .{
        lifecycle_node,
        if (pane.phase == .ended or pane.phase == .failed)
            ui.button(.{
                .size = .sm,
                .variant = .secondary,
                .on_press = .{ .restart = placementAt(index) },
                .semantics = .{ .label = ui.fmt("Restart {s}", .{terminalTitle(ui, model, pane.id)}) },
            }, "Restart")
        else
            emptyStatusNode(ui),
        issue,
        activity,
    });
}

/// Attention is the one thing a hidden terminal is allowed to shout about.
/// Local panes report their own lifecycle; a remote terminal is abnormal when
/// its provider says so, or when it publishes no presentation at all.
fn terminalNeedsAttention(model: *const Model, id: TerminalRef) bool {
    if (model.provider.terminalConst(id)) |pane| return paneNeedsAttention(model, pane);
    const presentation = model.remotePresentation(id) orelse return true;
    return presentation.phase == .failed or presentation.phase == .tombstoned;
}

fn terminalTabTrigger(ui: *TerminalUi, model: *const Model, id: TerminalRef, index: usize, placement: TabPlacement) TerminalUi.Node {
    const selected = if (model.selectedTerminalRef()) |current| current.eql(id) else false;
    var attached = false;
    for (model.attachments) |candidate| {
        if (candidate != null and candidate.?.eql(id)) attached = true;
    }
    const title = terminalTitle(ui, model, id);
    const compact = model.terminal_count + 1 > 3;
    const visible_title = if (placement == .top and compact)
        if (provider_contract.localId(id)) |local| ui.fmt("T{d}", .{terminalNumber(local)}) else "PHX"
    else
        title;
    const shortcut = ui.fmt("CMD+{d}", .{index + 1});
    const text = if (terminalNeedsAttention(model, id))
        ui.fmt("{s} !", .{visible_title})
    else
        visible_title;

    const kind_label = if (provider_contract.isLocal(id)) "native terminal" else "phux terminal";
    const semantics = if (model.provider.terminalConst(id)) |terminal|
        if (!attached)
            ui.fmt("{s}, {s}, detached; shortcut {s}{s}", .{ title, kind_label, shortcut, if (selected) ", selected" else "" })
        else
            ui.fmt("{s}, {s}, {s}; outbound loss {d} bytes; reply loss {d} bytes; input stalled {d} times; native delivery failures {d}; copy {s}; paste {s}; shortcut {s}{s}", .{
                title,
                kind_label,
                paneLifecycleText(ui, terminal),
                terminal.outbound_dropped,
                terminal.session.response_bytes_dropped,
                terminal.write_refusals,
                terminal.native_delivery_failures,
                if (terminal.copy_failed) "failed" else "ok",
                if (model.paste_owner.terminal_ref.eql(terminal.id) and model.paste_failed) "failed" else "ok",
                shortcut,
                if (selected) ", selected" else "",
            })
    else
        ui.fmt("{s}, {s}, {s}; shortcut {s}{s}", .{
            title,
            kind_label,
            if (model.remotePresentation(id)) |presentation| remoteLifecycleText(presentation.phase) else "UNAVAILABLE",
            shortcut,
            if (selected) ", selected" else "",
        });

    const trigger_key: canvas.UiKey = .{ .index = terminalPaintIndex(model, id) };
    return if (placement == .top)
        ui.el(.segmented_control, .{
            .global_key = trigger_key,
            .size = .sm,
            .text = text,
            .selected = selected,
            .on_press = .{ .select_surface = .{ .terminal = id } },
            .semantics = .{ .label = semantics },
        }, .{})
    else
        ui.listItem(.{
            .global_key = trigger_key,
            .size = .sm,
            .height = side_tab_height,
            .width = side_rail_width,
            .selected = selected,
            .on_press = .{ .select_surface = .{ .terminal = id } },
            .semantics = .{ .role = .tab, .label = semantics },
        }, text);
}

fn webTabTrigger(ui: *TerminalUi, model: *const Model, placement: TabPlacement) TerminalUi.Node {
    const selected = model.selected_surface.eql(.web);
    const shortcut = ui.fmt("CMD+{d}", .{model.terminal_count + 1});
    const semantics = ui.fmt("Web, system WebKit, shortcut {s}{s}", .{ shortcut, if (selected) ", selected" else "" });
    const trigger_key: canvas.UiKey = .{ .index = std.math.maxInt(usize) };
    return if (placement == .top)
        ui.el(.segmented_control, .{
            .global_key = trigger_key,
            .size = .sm,
            .text = "Web",
            .selected = selected,
            .on_press = .{ .select_surface = .web },
            .semantics = .{ .label = semantics },
        }, .{})
    else
        ui.listItem(.{
            .global_key = trigger_key,
            .size = .sm,
            .height = side_tab_height,
            .width = side_rail_width,
            .selected = selected,
            .on_press = .{ .select_surface = .web },
            .semantics = .{ .role = .tab, .label = semantics },
        }, "Web");
}

/// The spoken identity of a terminal SURFACE.
///
/// This is deliberately self-sufficient rather than leaning on the tab that
/// usually sits above it: at rest there is no band, so the surface is the only
/// thing in the tree that can tell a screen reader what this terminal is and
/// how it is doing.
fn terminalSurfaceLabel(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    const title = terminalTitle(ui, model, id);
    if (model.provider.terminalConst(id)) |pane| {
        return ui.fmt("{s}, native terminal, {s}", .{ title, paneLifecycleText(ui, pane) });
    }
    const phase = if (model.remotePresentation(id)) |presentation|
        remoteLifecycleText(presentation.phase)
    else
        "UNAVAILABLE";
    return ui.fmt("{s}, phux terminal, {s}", .{ title, phase });
}

fn terminalSurface(ui: *TerminalUi, model: *const Model, index: usize) TerminalUi.Node {
    const placement = placementAt(index);
    const terminal_ref = model.attachments[placement.index()] orelse return ui.el(.stack, .{
        .global_key = .{ .index = index },
        .grow = 1,
        .min_width = split_pane_min_width,
        .semantics = .{ .role = .group, .label = "Detached terminal placement" },
    }, .{});
    // A remote terminal has no local pane: it still contributes a focusable
    // surface with its published screen text, but no local copy/paste menu
    // and no local mouse-protocol policy.
    const pane = model.provider.terminalConst(terminal_ref);
    const screen = if (pane) |local|
        local.session.screenText()
    else if (model.remotePresentation(terminal_ref)) |presentation|
        presentation.grid.screen_text
    else
        "";
    const local_id = provider_contract.localId(terminal_ref);
    if (pane == null or local_id == null) {
        return ui.el(.stack, .{
            .global_key = .{ .index = index },
            .grow = 1,
            .min_width = split_pane_min_width,
            .opacity = 0,
            .text = screen,
            .on_press = .{ .focus_pane = placement },
            .semantics = .{
                .focusable = true,
                .label = terminalSurfaceLabel(ui, model, terminal_ref),
            },
        }, .{});
    }
    const local_pane = pane.?;
    const context_menu = [_]TerminalUi.ContextMenuItem{
        .{ .label = "Copy", .msg = .{ .copy_terminal = local_pane.id }, .enabled = local_pane.session.selectionActive() },
        .{ .label = "Paste", .msg = .{ .paste_terminal = local_pane.id }, .enabled = local_pane.acceptsInput() },
    };
    // One unbound terminal contributes native interaction and semantics over
    // the app-owned libghostty painter. pty=0 prevents SDK session input;
    // opacity=0 prevents duplicate pixels. Policy disabled keeps a live TUI's
    // secondary stream routed; automatic lets the declared local menu win.
    return ui.terminal(.{
        .global_key = .{ .index = @intCast(@intFromEnum(local_id.?)) },
        .grow = 1,
        .min_width = split_pane_min_width,
        .opacity = 0,
        .text = screen,
        .on_press = .{ .focus_pane = placement },
        .context_menu = &context_menu,
        .context_menu_policy = if (paneReportsMouse(local_pane)) .disabled else .automatic,
        .semantics = .{
            .focusable = true,
            .label = terminalSurfaceLabel(ui, model, local_pane.id),
        },
    });
}

fn splitTerminalSurface(ui: *TerminalUi, model: *const Model, index: usize) TerminalUi.Node {
    return ui.column(.{ .grow = 1, .min_width = split_pane_min_width }, .{
        ui.row(.{ .height = split_pane_header_height, .cross = .center }, .{
            paneStatus(ui, model, index, true),
        }),
        terminalSurface(ui, model, index),
    });
}

fn parkedWebKitAnchor(ui: *TerminalUi) TerminalUi.Node {
    return ui.panel(.{
        .width = webkit_parking_extent,
        .height = webkit_parking_extent,
        .opacity = 0,
        .semantics = .{ .label = webview_anchor, .hidden = true },
    }, .{});
}

fn splitAvailable(model: *const Model) bool {
    // An existing split must always be collapsible, including while a close is
    // waiting for its exact PTY exit or when one surface belongs to Phux.
    if (model.layout == .split) return true;
    return model.terminal_count >= 2 and model.selectedPlacement() != null;
}

fn selectedTerminalCanClose(model: *const Model) bool {
    const terminal_ref = model.selectedTerminalRef() orelse return false;
    return providerKind(terminal_ref) == .local;
}

/// Whether the tab and control band is part of the layout this frame.
///
/// Each clause is a piece of structure the operator can SEE the reason for:
///
/// - more than one terminal: tab order is now load-bearing, and the second
///   terminal may be a Phux session the coordinator just published — this is
///   how remote work announces itself without a permanent fleet panel;
/// - the Web surface: it is not a terminal and needs its own controls;
/// - split: two placements need to be told apart;
/// - attention: a terminal exited, failed, lost I/O, or stalled. A hidden
///   terminal in trouble is exactly the case where a marker must be able to
///   reach the operator, so this clause outranks calm.
///
/// Everything else — one healthy terminal — is a bare terminal.
pub fn chromeRevealed(model: *const Model) bool {
    if (model.terminal_count > 1) return true;
    if (model.selectedTerminalRef() == null) return true;
    if (model.layout == .split) return true;
    for (model.terminal_order[0..model.terminal_count]) |id| {
        if (terminalNeedsAttention(model, id)) return true;
    }
    return false;
}

const WorkspaceChrome = struct {
    titlebar_height: f32,
    content: geometry.RectF,
};

/// One geometry policy feeds retained layout, custom terminal painting, PTY
/// sizing, pointer hit-testing, wheel routing, and WebKit anchoring. Placement
/// changes are discrete: the PTY receives one final size, never animated
/// intermediate geometry.
fn workspaceChrome(model: *const Model, size: geometry.SizeF) WorkspaceChrome {
    const titlebar = @max(grid_inset, model.chrome_top + 4);
    const revealed = chromeRevealed(model);
    const side_extent = if (revealed and model.tab_placement == .side) side_rail_width + side_rail_gap else 0;
    const top_extent = if (revealed and model.tab_placement == .top) header_height else 0;
    return .{
        .titlebar_height = titlebar,
        .content = geometry.RectF.init(
            grid_inset + side_extent,
            titlebar + top_extent,
            @max(0, size.width - grid_inset * 2 - side_extent),
            @max(0, size.height - titlebar - top_extent - grid_inset),
        ),
    };
}

pub fn view(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    var triggers: [max_terminal_count + 1]TerminalUi.Node = undefined;
    for (&triggers) |*node| node.* = ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    for (model.terminal_order[0..model.terminal_count], 0..) |id, index| {
        triggers[index] = terminalTabTrigger(ui, model, id, index, model.tab_placement);
    }
    triggers[model.terminal_count] = webTabTrigger(ui, model, model.tab_placement);

    const terminal_index = model.selectedTerminalIndex();
    const top_context_controls = if (terminal_index) |index|
        if (model.layout == .single)
            paneStatus(ui, model, index, false)
        else
            ui.el(.stack, .{}, .{})
    else
        ui.row(.{ .gap = 6, .cross = .center }, .{
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .github } }, "GitHub"),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .superlogical } }, "Superlogical"),
            ui.button(.{ .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .article } }, "Mitchell"),
        });

    const close_available = selectedTerminalCanClose(model);
    const top_topology_controls = ui.row(.{ .gap = 4, .cross = .center }, .{
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .disabled = model.terminal_count >= max_terminal_count or model.provider.occupiedCount() >= max_terminal_count,
            .on_press = .new_terminal,
            .semantics = .{ .label = "New Terminal, Command T" },
        }, "New"),
        if (close_available) ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .close_terminal,
            .semantics = .{ .label = "Close Terminal, Command W" },
        }, "Close") else emptyStatusNode(ui),
    });

    const revealed = chromeRevealed(model);
    const top_header = if (revealed and model.tab_placement == .top) ui.row(.{ .height = header_height, .gap = 12, .cross = .center, .window_drag = true }, .{
        ui.el(.tabs, .{ .gap = 2, .semantics = .{ .label = "Surfaces" } }, .{
            triggers[0],
            triggers[1],
            triggers[2],
            triggers[3],
            triggers[4],
        }),
        ui.spacer(1),
        top_context_controls,
        top_topology_controls,
        ui.el(.toggle_button, .{
            .size = .sm,
            .text = "Split",
            .selected = model.layout == .split,
            .disabled = !splitAvailable(model),
            .on_press = .toggle_split,
            .semantics = .{ .label = "Toggle terminal split, Command D" },
        }, .{}),
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .toggle_tab_placement,
            .semantics = .{ .label = "Move tabs to the side" },
        }, "Side tabs"),
    })
        // At rest there is no band at all. Every control it carried stays
        // reachable: New is cmd+T, Close cmd+W, Split cmd+D, and the surfaces
        // are cmd+1..cmd+5 — the band is presentation, never the only path.
        else ui.el(.stack, .{ .height = 0, .semantics = .{ .hidden = true } }, .{});

    const content = if (terminal_index) |index| blk: {
        const terminals = if (model.layout == .split)
            ui.split(.{
                .grow = 1,
                .gap = split_divider_width,
                .value = model.split_fraction,
                .on_resize = TerminalUi.valueMsg(.split_resized),
                .semantics = .{ .label = "Terminal split" },
            }, .{
                splitTerminalSurface(ui, model, 0),
                splitTerminalSurface(ui, model, 1),
            })
        else
            terminalSurface(ui, model, index);
        // Parking the webview at a one-point anchor preserves its native
        // page state without allowing it to cover or receive input over a
        // terminal tab. v0.7.1 has no non-destructive visibility patch.
        break :blk ui.el(.stack, .{ .grow = 1 }, .{
            terminals,
            parkedWebKitAnchor(ui),
        });
    } else ui.panel(.{
        .grow = 1,
        .semantics = .{ .label = webview_anchor },
    }, .{});

    const side_context_controls = if (terminal_index) |index|
        if (model.layout == .single)
            paneStatus(ui, model, index, false)
        else
            emptyStatusNode(ui)
    else
        ui.column(.{ .gap = 4 }, .{
            ui.button(.{ .width = side_rail_width, .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .github } }, "GitHub"),
            ui.button(.{ .width = side_rail_width, .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .superlogical } }, "Superlogical"),
            ui.button(.{ .width = side_rail_width, .size = .sm, .variant = .secondary, .on_press = .{ .browser_page = .article } }, "Mitchell"),
        });
    const side_topology_controls = ui.row(.{ .width = side_rail_width, .gap = 4, .cross = .center }, .{
        ui.button(.{
            .grow = 1,
            .size = .sm,
            .variant = .secondary,
            .disabled = model.terminal_count >= max_terminal_count or model.provider.occupiedCount() >= max_terminal_count,
            .on_press = .new_terminal,
            .semantics = .{ .label = "New Terminal, Command T" },
        }, "New"),
        if (close_available) ui.button(.{
            .grow = 1,
            .size = .sm,
            .variant = .secondary,
            .on_press = .close_terminal,
            .semantics = .{ .label = "Close Terminal, Command W" },
        }, "Close") else emptyStatusNode(ui),
    });
    const side_rail_content = ui.column(.{ .width = side_rail_width, .gap = 8 }, .{
        ui.list(.{ .width = side_rail_width, .gap = 3, .semantics = .{ .label = "Surfaces" } }, .{
            triggers[0],
            triggers[1],
            triggers[2],
            triggers[3],
            triggers[4],
        }),
        ui.spacer(1),
        side_context_controls,
        side_topology_controls,
        ui.el(.toggle_button, .{
            .width = side_rail_width,
            .size = .sm,
            .text = "Split",
            .selected = model.layout == .split,
            .disabled = !splitAvailable(model),
            .on_press = .toggle_split,
            .semantics = .{ .label = "Toggle terminal split, Command D" },
        }, .{}),
        ui.button(.{
            .width = side_rail_width,
            .size = .sm,
            .variant = .secondary,
            .on_press = .toggle_tab_placement,
            .semantics = .{ .label = "Move tabs to the top" },
        }, "Top tabs"),
    });
    const side_rail = if (revealed and model.tab_placement == .side)
        ui.scroll(.{
            .width = side_rail_width,
            .grow = 1,
            .semantics = .{ .label = "Workspace controls" },
        }, side_rail_content)
    else
        ui.el(.stack, .{ .width = 0, .semantics = .{ .hidden = true } }, .{});

    const workspace = if (revealed and model.tab_placement == .side)
        ui.row(.{ .grow = 1, .gap = side_rail_gap }, .{ side_rail, content })
    else
        ui.column(.{ .grow = 1 }, .{ top_header, content });

    // The hidden-inset titlebar band. It carries `window_drag` UNCONDITIONALLY,
    // because it is the only element that can: the SDK has no
    // movable-by-background fallback, so a frame where nothing declares
    // `window_drag` is a frame where the window cannot be moved at all. The
    // control band above declares it too, but the control band is not always
    // there — this one is. It sits entirely within the titlebar inset, above
    // the first terminal row, so claiming presses here never costs the
    // terminal a click.
    const titlebar_band = @max(0, workspaceChrome(model, model.surface_size).titlebar_height - grid_inset);
    return ui.column(.{ .padding = grid_inset }, .{
        ui.el(.stack, .{
            .height = titlebar_band,
            .window_drag = true,
            .semantics = .{ .label = "Phux Cockpit window" },
        }, .{}),
        workspace,
    });
}

/// The grids, painted as a variable-length chrome prefix beneath the
/// widget tree: real text through the canvas primitives, damage kept
/// row-shaped by stable command ids, one id namespace per pane.
///
/// The budgets are partitioned per the policy at the top of this file:
/// commands floor-and-slack (cumulative), text mirrored (per-paint
/// local), glyphs halved (per-paint local).
fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    if (model.selectedTerminalIndex() == null) return;
    const frames = paneFrames(model, size);
    const split = model.layout == .split;
    const text_share = (canvas.max_display_list_text_bytes - canvas.terminal_grid.widget_text_reserve) / 2;
    const path_share = (canvas.max_chart_path_elements_per_frame - canvas.terminal_grid.widget_path_reserve) / 2;
    var painted: usize = 0;
    for (frames, 0..) |frame, index| {
        if (frame.width <= 0 or frame.height <= 0) continue;
        const placement = placementAt(index);
        const terminal_ref = model.attachments[placement.index()] orelse continue;
        const first_of_split = split and painted == 0;
        const background_frame = if (painted == 0)
            geometry.RectF.init(0, 0, size.width, size.height)
        else
            frame;
        if (model.provider.terminalConst(terminal_ref)) |pane| {
            try grid.paint(pane.session, builder, .{
                .frame = frame,
                .background_frame = background_frame,
                .tokens = tokens,
                .running = pane.phase == .live or pane.phase == .starting,
                .focused = model.focused and model.focus_placement == placement,
                .selecting = pane.selecting,
                .command_budget = if (first_of_split) chrome_command_envelope / 2 else chrome_command_envelope,
                .text_reserve = canvas.terminal_grid.widget_text_reserve + if (first_of_split) text_share else 0,
                .glyph_budget = if (split) canvas.terminal_grid.widget_glyph_budget / 2 else canvas.terminal_grid.widget_glyph_budget,
                .path_reserve = canvas.terminal_grid.widget_path_reserve + if (first_of_split) path_share else 0,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, terminal_ref)),
            });
        } else {
            const remote = model.phuxConst() orelse continue;
            const presentation = remote.presentation(terminal_ref) orelse continue;
            try grid.paintTerminalGrid(presentation.grid, builder, .{
                .frame = frame,
                .background_frame = background_frame,
                .tokens = tokens,
                .running = presentation.phase == .live,
                .focused = model.focused and model.focus_placement == placement,
                .selecting = if (model.remoteUiConst(terminal_ref)) |state| state.selecting else false,
                .command_budget = if (first_of_split) chrome_command_envelope / 2 else chrome_command_envelope,
                .text_reserve = canvas.terminal_grid.widget_text_reserve + if (first_of_split) text_share else 0,
                .glyph_budget = if (split) canvas.terminal_grid.widget_glyph_budget / 2 else canvas.terminal_grid.widget_glyph_budget,
                .path_reserve = canvas.terminal_grid.widget_path_reserve + if (first_of_split) path_share else 0,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, terminal_ref)),
            });
        }
        painted += 1;
    }
}

/// Terminal placement inside the shared top/side workspace content frame.
/// Single mode gives the selected terminal the content frame; split mode
/// projects both live sessions around the same divider geometry as `ui.split`.
///
/// This is the SECOND derivation of these rectangles — `view()` is the
/// first, and the layout engine owns that one. `ChromeOptions.build`
/// never receives the laid-out tree, so the two cannot share a result;
/// the layout-agreement test is what keeps them honest. Both sides now read
/// `workspaceChrome`, so placement and reveal cannot drift between them.
pub fn paneFrames(model: *const Model, size: geometry.SizeF) [pane_count]geometry.RectF {
    const content = workspaceChrome(model, size).content;
    var frames = [_]geometry.RectF{.{}} ** pane_count;
    if (model.selectedTerminalIndex()) |selected| {
        if (model.layout == .single) {
            frames[selected] = content;
        } else {
            const available = @max(0, content.width - split_divider_width);
            const fraction = canvas.splitEffectiveFraction(
                model.split_fraction,
                available,
                split_pane_min_width,
                split_pane_min_width,
            );
            const first_width = available * fraction;
            const terminal_top = content.y + split_pane_header_height;
            const terminal_height = @max(0, content.height - split_pane_header_height);
            frames[0] = geometry.RectF.init(content.x, terminal_top, first_width, terminal_height);
            frames[1] = geometry.RectF.init(
                content.x + first_width + split_divider_width,
                terminal_top,
                @max(0, available - first_width),
                terminal_height,
            );
        }
    }
    return frames;
}

/// Frame pump: resize each visible terminal against its actual pane. One
/// resize message is emitted per frame; a second changed split pane follows
/// on the next frame without ever coupling either PTY's lifetime to layout.
fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const frame_scale = if (validScale(frame.scale_factor)) frame.scale_factor else model.surface_scale_factor;
    const frames = paneFrames(model, frame.size);
    var pending = false;
    for (0..max_terminal_count) |index| {
        if (model.provider.states[index] != .active) continue;
        const pane = model.provider.slotConst(index);
        if (pane.outbound_len > 0 or pane.session.response_len > 0) pending = true;
    }
    if (model.selectedTerminalIndex() != null) {
        for (frames, 0..) |inner, index| {
            if (inner.width <= 0 or inner.height <= 0) continue;
            const placement = placementAt(index);
            const terminal_ref = model.attachments[placement.index()] orelse continue;
            if (model.provider.terminalConst(terminal_ref)) |pane| {
                const session = pane.session;
                if (session.cell_width <= 0 or session.cell_height <= 0) return if (pending) .flush_outbound else null;
                const proposed = grid.Session.clampGrid(
                    @intFromFloat(@max(2, inner.width / session.cell_width)),
                    @intFromFloat(@max(2, inner.height / session.cell_height)),
                );
                if (proposed.x != pane.cols or proposed.y != pane.rows) {
                    return .{
                        .viewport = .{
                            .terminal_ref = terminal_ref,
                            .cols = proposed.x,
                            .rows = proposed.y,
                            .size = frame.size,
                            // Carry the real scale: the `.viewport` arm commits
                            // whatever arrives, and the field's `= 1` default
                            // would silently reset a Retina surface to 1x on every
                            // local grid resize.
                            .scale_factor = frame_scale,
                        },
                    };
                }
                continue;
            }
            const remote = model.phuxConst() orelse continue;
            if (remote.presentation(terminal_ref) == null) continue;
            const metrics = canvas.terminalCellMetrics(cockpitTokens(model));
            const proposed = grid.Session.clampGrid(
                @intFromFloat(@max(2, inner.width / metrics.width)),
                @intFromFloat(@max(2, inner.height / metrics.height)),
            );
            const viewport: Viewport = .{ .cols = proposed.x, .rows = proposed.y };
            if (remote.lastViewport(terminal_ref) == null or !remote.lastViewport(terminal_ref).?.eql(viewport)) {
                return .{ .viewport = .{
                    .terminal_ref = terminal_ref,
                    .cols = proposed.x,
                    .rows = proposed.y,
                    .size = frame.size,
                    .scale_factor = frame_scale,
                } };
            }
        }
    }
    if (model.surface_size.width != frame.size.width or model.surface_size.height != frame.size.height or
        model.surface_scale_factor != frame_scale)
    {
        return .{ .surface_resized = .{ .size = frame.size, .scale_factor = frame_scale } };
    }
    if (pending) return .flush_outbound;
    return null;
}

pub fn webPanes(model: *const Model, out: []TerminalApp.WebViewPane) usize {
    out[0] = .{
        .label = webview_label,
        .anchor = webview_anchor,
        .url = model.browser_page.url(),
        .reload_token = model.browser_navigation_token,
    };
    return 1;
}

pub fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "surface.1")) return .{ .select_position = 0 };
    if (std.mem.eql(u8, name, "surface.2")) return .{ .select_position = 1 };
    if (std.mem.eql(u8, name, "surface.3")) return .{ .select_position = 2 };
    if (std.mem.eql(u8, name, "surface.4")) return .{ .select_position = 3 };
    if (std.mem.eql(u8, name, "surface.5")) return .{ .select_position = 4 };
    if (std.mem.eql(u8, name, "tab.previous")) return .{ .cycle_tab = -1 };
    if (std.mem.eql(u8, name, "tab.next")) return .{ .cycle_tab = 1 };
    if (std.mem.eql(u8, name, "layout.split")) return .toggle_split;
    if (std.mem.eql(u8, name, "terminal.new")) return .new_terminal;
    if (std.mem.eql(u8, name, "terminal.close")) return .close_terminal;
    if (std.mem.eql(u8, name, "tab.move-left")) return .{ .move_terminal = -1 };
    if (std.mem.eql(u8, name, "tab.move-right")) return .{ .move_terminal = 1 };
    if (std.mem.eql(u8, name, "tabs.toggle-placement")) return .toggle_tab_placement;
    if (std.mem.eql(u8, name, "pane.previous")) return .{ .cycle_pane = -1 };
    if (std.mem.eql(u8, name, "pane.next")) return .{ .cycle_pane = 1 };
    return null;
}

pub fn tabPlacementFromText(value: []const u8) ?TabPlacement {
    if (std.ascii.eqlIgnoreCase(value, "top")) return .top;
    if (std.ascii.eqlIgnoreCase(value, "side") or std.ascii.eqlIgnoreCase(value, "sidebar")) return .side;
    return null;
}

pub fn onTimer(id: u64, _: u64) ?Msg {
    return if (id == selection_autoscroll_timer_id) .selection_autoscroll else null;
}

// ------------------------------------------------------------------ main

pub fn appOptions() TerminalApp.Options {
    return .{
        .name = app_name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .tokens_fn = cockpitTokens,
        .fonts = &cockpit_fonts,
        .init_fx = initFx,
        .update_fx = update,
        .view = view,
        .on_key = onKey,
        // Key releases feed the encoder for the kitty protocol's event
        // reporting; `handleKey` branches on the phase.
        .key_release_events = true,
        .on_text = onText,
        .on_wheel = onWheel,
        .on_timer = onTimer,
        .on_chrome = onChrome,
        .on_lifecycle = onLifecycle,
        .on_frame = onFrame,
        .web_panes = webPanes,

        .on_command = onCommand,
        .chrome = .{
            .prefix_commands = chrome_command_envelope,
            .variable_prefix = true,
            .build = buildChrome,
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
        const uid_segment = init.environ_map.get("UID") orelse
            init.environ_map.get("USER") orelse
            "default";
        break :blk try std.fmt.bufPrint(&socket_storage, "/tmp/phux-{s}/phux.sock", .{uid_segment});
    };
    const session = init.environ_map.get("PHUX_SESSION") orelse "default";
    return try PhuxProvider.create(
        std.heap.page_allocator,
        init.io,
        .{ .unix = socket_path },
        session,
        "phux-cockpit",
    );
}

pub fn main(init: std.process.Init) !void {
    // Launch is ONE terminal and one shell process. Additional terminals are
    // minted on demand; Phux terminals arrive from the coordinator.
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
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
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
    try std.testing.expectEqual(MouseButton.left, pointerButton(0));
    try std.testing.expectEqual(MouseButton.right, pointerButton(1));
    try std.testing.expectEqual(MouseButton.middle, pointerButton(2));
    try std.testing.expectEqual(MouseButton.button_4, pointerButton(3));
    try std.testing.expectEqual(MouseButton.button_5, pointerButton(4));
    try std.testing.expectEqual(MouseButton.none, pointerButton(std.math.maxInt(u32)));
}

test {
    _ = @import("tests.zig");
    _ = @import("adversarial_tests.zig");
    _ = @import("topology_tests.zig");
}
