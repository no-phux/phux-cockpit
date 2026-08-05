const native_sdk = @import("native_sdk");
const support = @import("phux_support.zig");
const model_module = @import("model.zig");
const topology = @import("topology.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const Model = model_module.Model;
pub const TerminalRef = support.TerminalRef;
pub const BrowserPage = model_module.BrowserPage;
pub const Placement = topology.Placement;
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
    focus_pane: Placement,
    attach_terminal: struct { placement: Placement, terminal_ref: TerminalRef },
    detach_terminal: Placement,
    flush_outbound,
    selection_autoscroll,
    pointer: TerminalPointerEvent,
    wheel_fallback: struct { x: f32, y: f32, delta: f32 },
    chrome_changed: native_sdk.platform.WindowChrome,
    focus_changed: bool,
};

pub const TerminalApp = native_sdk.UiApp(Model, Msg);
pub const Fx = TerminalApp.Effects;
