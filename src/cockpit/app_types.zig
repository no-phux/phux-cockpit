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
    /// Paste into whatever is focused. `paste_terminal` needs a ref the caller
    /// already has; a menu item does not have one.
    paste_focused,
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
    /// cmd+= / cmd+- step the terminal type size by whole points; cmd+0
    /// returns to the size the config file names. The grid reflow rides the
    /// existing onFrame viewport pump — nothing here touches a PTY directly.
    font_size_step: i8,
    font_size_reset,
    /// cmd+A over the focused terminal: arm a selection covering the whole
    /// visible screen, so the very next cmd+C copies it.
    select_all,
    /// cmd+K: clear the screen AND the scrollback, the way `clear` does.
    clear_terminal,
    /// cmd+F: open the scrollback search field over the focused terminal.
    /// Idempotent — a second cmd+F on an open field changes nothing, and in
    /// particular must not re-record the restore position.
    search_open,
    /// Escape, or the field's own close control: dismiss the field and put
    /// the viewport back where the search found it.
    search_close,
    /// cmd+G / cmd+shift+G, and Enter / shift+Enter while the field is open.
    ///
    /// POSITIVE steps toward OLDER output (up the screen), negative toward
    /// newer. That is the direction libghostty calls `.next`, and it is the
    /// useful one here: a fresh search lands on the newest match because that
    /// is where the user already is, so stepping means walking back through
    /// the log.
    search_step: i8,
    /// Close a tab by index — what the strip's own `x` presses.
    close_tab: u8,
    /// Pointer entered/left a tab. Only the close affordance reads it.
    hover_tab: u8,
    unhover_tab,
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
    /// The layout-snapshot debounce expired: write the workspace shape now.
    /// Arriving as a Msg rather than as a direct write inside every topology
    /// arm is the whole debounce — the timer is re-armed on each change and
    /// only its final expiry reaches here.
    persist_topology: native_sdk.EffectTimer,
    /// The snapshot write finished. Terminal for its key, so it is also the
    /// only place a queued follow-up write may start.
    topology_persisted: native_sdk.EffectFileResult,
    /// The runtime is shutting down. The LAST message this model will ever
    /// see, and the only chance to put a change made inside the debounce
    /// window on disk — nothing will drain another effect queue after it.
    shutdown,
};

pub const TerminalApp = native_sdk.UiApp(Model, Msg);
pub const Fx = TerminalApp.Effects;
