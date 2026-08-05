const native_sdk = @import("native_sdk");
const support = @import("phux_support.zig");
const model_module = @import("model.zig");
const topology = @import("topology.zig");
const layout = @import("layout.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const Model = model_module.Model;
pub const TerminalRef = support.TerminalRef;
pub const BrowserPage = model_module.BrowserPage;
pub const SurfaceSelection = topology.SurfaceSelection;
pub const TerminalPointerEvent = model_module.TerminalPointerEvent;

pub const selection_autoscroll_timer_id: u64 = 1;

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
    /// Restart names the terminal, not a pane slot: a pane's identity is its
    /// terminal, and the tree it sits in can reshape between press and
    /// dispatch.
    restart: TerminalRef,
    select_surface: SurfaceSelection,
    select_position: u8,
    cycle_tab: i8,
    new_terminal,
    /// cmd+W: close the FOCUSED PANE. The tab goes when its last pane does,
    /// and the window goes when its last tab does.
    close_terminal,
    move_terminal: i8,
    toggle_tab_placement,
    /// A real split: mint a new terminal and divide the focused pane.
    split_right,
    split_down,
    /// A divider drag, addressed to the branch it belongs to.
    split_resized: struct { node: layout.NodeId, value: f32 },
    cycle_pane: i8,
    focus_direction: layout.Direction,
    browser_page: BrowserPage,
    /// Focus a pane of the selected tab by its node id.
    focus_pane: layout.NodeId,
    flush_outbound,
    selection_autoscroll,
    pointer: TerminalPointerEvent,
    wheel_fallback: struct { x: f32, y: f32, delta: f32 },
    chrome_changed: native_sdk.platform.WindowChrome,
    focus_changed: bool,
};

pub const TerminalApp = native_sdk.UiApp(Model, Msg);
pub const Fx = TerminalApp.Effects;
