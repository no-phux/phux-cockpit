const std = @import("std");
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
        /// Which window's surface was measured. The frame pump runs per
        /// window slot, so a resize from the window behind must not commit
        /// its geometry onto the window in front.
        window: u8 = 0,
        /// The platform id behind that window, learned from the frame event.
        /// It is how a later shortcut — which carries a window id and no
        /// label — resolves back to a workspace.
        window_id: native_sdk.platform.WindowId = 1,
    },
    surface_resized: struct {
        size: geometry.SizeF,
        scale_factor: f32,
        window: u8 = 0,
        window_id: native_sdk.platform.WindowId = 1,
    },
    /// One slice of incremental scrollback search, driven by the frame pump.
    ///
    /// Scrollback search cannot run on a background thread — `vt.search.Thread`
    /// is `void` in a library-artifact libghostty-vt — so walking a deep
    /// history on every keystroke stuttered the dispatch thread. The engine
    /// makes bounded progress per slice instead, and this is the tick that
    /// asks for the next one.
    search_tick,
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
    /// cmd+N: a whole new WINDOW, with its own workspace and one terminal in
    /// it. Refused visibly at the ceiling rather than silently — see
    /// `Model.window_limit_refused`.
    new_window,
    /// Input arrived from a window, so that window owns the next messages.
    /// The one seam through which `Model.active_window` moves: the host
    /// resolves a canvas label or a platform window id to an index and
    /// dispatches this, so `update` stays the only mutator.
    focus_window: u8,
    /// The user closed a window through the OS (the red button, cmd+W on the
    /// title bar, the Window menu) rather than through the last tab. The
    /// dismissal precedent: the window is already gone, and this is the model
    /// catching up.
    window_closed: u8,
    /// ctrl+cmd+F, or View > Enter Full Screen: flip the FOCUSED window.
    toggle_fullscreen,
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
    /// SCROLLBACK — not merely the visible screen — so the very next cmd+C
    /// copies all of it.
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
    /// cmd+shift+P: the summoned tab switcher.
    ///
    /// It exists because a strip does not scale. The strip windows past what
    /// fits and shrinks pills before that; the switcher is the path that still
    /// works at thirty terminals, and it is the seam the product direction's
    /// "hundreds of agents" eventually arrives through. Idempotent — a second
    /// chord on an open palette changes nothing.
    palette_open,
    /// Escape, a click outside, or a committed pick.
    palette_close,
    /// Arrow keys and ctrl+N/P: move the highlight through the FILTERED rows.
    palette_step: i8,
    /// Enter: select the highlighted tab and dismiss.
    palette_commit,
    /// A typed character reaching the needle rather than the shell.
    palette_input: []const u8,
    palette_backspace,
    /// The startup config band was read: put it away for this launch.
    ///
    /// A press, never a key. The band is deliberately NOT modal — the whole
    /// point is that a benign diagnostic must not stand between someone and a
    /// prompt — so it holds no chord, and Escape keeps belonging to the search
    /// field, the palette, and the shell.
    config_notice_dismissed,
    /// cmd+, — the settings surface, on the chord every Mac app uses.
    ///
    /// It exists because `phux-cockpit-aht` spent four rounds on "the text is
    /// see-through or black or something" without the owner ever being able to
    /// simply change the colour and look. Idempotent, like `palette_open`: a
    /// second chord on an open panel must not throw away the preview state.
    settings_open,
    /// Escape, or a click outside: dismiss AND put back the theme that was in
    /// effect when the panel opened. Cancelling a preview has to actually
    /// cancel it, or previewing would be a trap.
    settings_close,
    /// Arrow keys and ctrl+N/P: move the highlight, and APPLY the theme under
    /// it immediately. Live preview is the whole point — a settings page you
    /// have to commit to before you can see it is a form, not an instrument.
    settings_step: i8,
    /// Enter: keep the previewed theme and write it to the config file.
    settings_commit,
    /// A pointer press on a theme row: put the highlight there and preview it,
    /// which is exactly what an arrow key does. The commit stays a separate
    /// gesture so a click cannot write the file by accident.
    settings_select: u8,
    /// X, or a press on the override band: delete the explicit `foreground` /
    /// `background` / `selection-background` keys so the chosen theme is what
    /// reaches the screen.
    ///
    /// The one message in this panel that WRITES THE FILE WITHOUT A COMMIT, and
    /// deliberately so. Every other gesture here is a preview that Escape can
    /// take back, but a preview of "your override is gone" is exactly the trap
    /// the panel already had: the user would watch the colours come right,
    /// press Escape because they were only looking, and be back where they
    /// started with no way to tell which of the two states was real. Clearing
    /// is the remedy the band names, so it lands, once, when it is asked for.
    settings_clear_overrides,
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
    /// A window's titlebar inset, addressed to that window. `on_chrome` has
    /// no window identity of its own, so the plain `chrome_changed` above
    /// lands on the active window; this arm is what a test and a future
    /// per-window chrome event use.
    window_chrome_changed: struct { window: u8, top: f32 },
    focus_changed: bool,
    /// The system flipped light/dark. `theme = auto` is the only thing that
    /// reads it: a config that NAMES a theme is a choice, and a choice does
    /// not move when the OS does.
    ///
    /// The host emits this before the run loop arms, so a following config is
    /// already on the right side of the flip in the first painted frame —
    /// there is no dark-then-light blink to design around.
    appearance_changed: native_sdk.platform.Appearance,
    /// A trackpad pinch over a canvas surface.
    ///
    /// The platform's `scale` is a MULTIPLICATIVE per-event delta, and a
    /// terminal's type size is a discrete number of points, so this arm
    /// accumulates the gesture and steps whole points across a threshold —
    /// see `Model.pinchStep`.
    pinch: native_sdk.platform.PinchEvent,
    /// Finder (or any app that drags files) dropped paths on a surface.
    ///
    /// The paths are BORROWED for the dispatch, exactly like `key`'s bytes:
    /// the arm quotes them into the pane's outbound buffer and keeps nothing.
    files_dropped: native_sdk.platform.FileDropEvent,
    /// cmd+M, and Window > Minimize.
    minimize_window,
    /// A row of the menu-bar extra: go to that terminal.
    ///
    /// Distinct from `select_position`, which the strip and the chords use,
    /// because a pick made from the menu bar is a pick made while this app is
    /// NOT in front — selecting a tab in a window the user cannot see would be
    /// a gesture with no visible effect. This one raises the window too.
    tray_select: u8,
    /// The menu-bar menu was opened. It carries no state of its own: the
    /// derivation behind the menu is re-read after every dispatch, so being a
    /// message at all is the whole job.
    tray_opened,
    /// The tab context menu's verbs. Addressed by tab INDEX rather than by
    /// "the selected tab": a right-click acts on the tab under the pointer,
    /// which is very often not the one that is selected.
    close_other_tabs: u8,
    move_tab: struct { index: u8, delta: i8 },
    /// A live tab drag. The field NAMES are the toolkit's closed drag record
    /// (six fields, exactly these spellings) — `Tree.msgForDragTemplate`
    /// injects `phase`, `x`, `y` and the view extent into whatever the view
    /// authored, and leaves `sourceId` alone, which is why the tab index
    /// rides in it.
    ///
    /// `phase` is the wire's own numbering: 0 change, 1 end, 2 cancel.
    tab_drag: struct {
        sourceId: u32 = 0,
        phase: u8 = 0,
        x: f32 = 0,
        y: f32 = 0,
        viewWidth: f32 = 0,
        viewHeight: f32 = 0,
    },
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

comptime {
    // `Model` cannot name `TerminalApp` — the app type is parameterized on the
    // model — so the secondary-window ceiling is restated there and pinned
    // here, where the toolkit's own budget is finally in scope. A drift means
    // either windows the model can declare and the runtime will drop, or slots
    // the model refuses to use.
    std.debug.assert(model_module.max_secondary_windows == TerminalApp.max_ui_windows);
}
