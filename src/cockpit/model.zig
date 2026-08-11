const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../terminal/grid.zig");
const provider_contract = @import("provider_contract");
const support = @import("phux_support.zig");
const local = @import("../providers/local/provider.zig");
const topology = @import("topology.zig");
const layout = @import("layout.zig");
const config_module = @import("../config/config.zig");
const session_state = @import("session_state.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const PhuxProvider = support.PhuxProvider;
pub const TerminalRef = support.TerminalRef;
pub const LocalTerminalId = support.LocalTerminalId;
pub const ReplicaOwner = support.ReplicaOwner;
pub const Presentation = support.Presentation;
pub const MouseButton = support.MouseButton;
pub const Pane = local.Pane;
pub const LocalProvider = local.LocalProvider;
pub const Config = config_module.Config;
pub const TabPlacement = topology.TabPlacement;
pub const SurfaceSelection = topology.SurfaceSelection;
pub const TopologySnapshot = topology.TopologySnapshot;
pub const SnapshotSelection = topology.SnapshotSelection;
pub const PersistedTopologySnapshot = topology.PersistedTopologySnapshot;
pub const max_terminals = local.max_terminals;
pub const max_tabs = topology.max_tabs;
pub const max_remote_terminals = support.max_remote_terminals;

pub const max_held_terminal_keys: usize = 16;

/// Path ceiling for the layout state file, matching the SDK's own
/// `max_effect_file_path_bytes` — a path the write effect would refuse is a
/// path there is no point storing.
pub const max_state_path_bytes: usize = 1024;

/// Layout-persistence bookkeeping.
///
/// The path is resolved ONCE at startup and copied here, because `update` has
/// no environment and no `Io`: by the time a topology change wants writing,
/// the only thing that can still answer "where" is the model.
///
/// `fingerprint` is the topology hash as of the end of the previous `update`.
/// Comparing against it is what makes a save EDGE-triggered — a keystroke
/// leaves it unchanged and arms nothing, while a divider drag changes it every
/// frame and re-arms the same one-shot timer, which is the debounce.
pub const StatePersistence = struct {
    path_storage: [max_state_path_bytes]u8 = undefined,
    path_len: usize = 0,
    fingerprint: u64 = 0,
    /// A write effect is outstanding on the state-file key. A second write on
    /// a live key is rejected by the SDK, so one waits rather than racing.
    inflight: bool = false,
    /// The topology moved while that write was in flight, so another is owed
    /// the moment it lands.
    pending: bool = false,

    pub fn path(state: *const StatePersistence) []const u8 {
        return state.path_storage[0..state.path_len];
    }

    pub fn enabled(state: *const StatePersistence) bool {
        return state.path_len != 0;
    }

    /// Adopt a resolved path, or disable persistence when there is none to
    /// adopt. A window that cannot find a state directory still runs.
    pub fn setPath(state: *StatePersistence, value: ?[]const u8) void {
        const resolved = value orelse "";
        if (resolved.len == 0 or resolved.len > max_state_path_bytes) {
            state.path_len = 0;
            return;
        }
        @memcpy(state.path_storage[0..resolved.len], resolved);
        state.path_len = resolved.len;
    }
};

/// Sentinel for "the pointer is over no tab". `max_tabs` is a valid index in
/// no tab list, so it can never collide with a real hover.
pub const no_hovered_tab: usize = std.math.maxInt(usize);
pub const max_pointer_captures: usize = 8;

pub const HeldTerminalKey = struct {
    fingerprint: u64 = 0,
    owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
};

pub const MonitorPointerCapture = struct {
    owner: ReplicaOwner,
    button: MouseButton,
};

pub const PointerState = struct {
    queue: support.pointer_module.EventQueue = .{},
    monitor: ?support.pointer_module.Monitor = null,
    capture: ?MonitorPointerCapture = null,
    last_x: f64 = 0,
    last_y: f64 = 0,
};

pub const RemoteUiState = struct {
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

/// Destination of an in-flight clipboard read. See `Model.paste_target`.
pub const PasteTarget = enum { terminal, search_needle };

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

/// Model-declared secondary windows the toolkit budgets
/// (`canvas_limits.max_ui_app_windows`). Restated here rather than imported
/// because `UiApp` is parameterized on this very model, so naming the app type
/// from inside it is circular; `app_types.zig` carries the comptime assertion
/// that the two agree, which is where the app type is actually in scope.
pub const max_secondary_windows: usize = 4;

/// Windows the app can have open at once: the scene's own plus the
/// secondaries. The ceiling is the TOOLKIT's, not a policy of this app's.
pub const max_windows: usize = 1 + max_secondary_windows;

/// ONE window's workspace: a list of TABS, each owning a `layout.Tree` of
/// panes, plus the surface geometry that window was last measured at.
///
/// The selected tab plus that tree's own `focus` fully determine what is
/// focused — there is no second focus variable to keep in sync. `web_selected`
/// is the one thing outside the tab model: the WebKit surface takes over the
/// content area without belonging to a tab.
///
/// Extracted out of `Model` so a second window is a second workspace rather
/// than a second model: everything below is per-window by construction, and
/// everything that stayed on `Model` (the provider, the config, the clipboard
/// latches, the shortcut latch) is genuinely app-wide.
/// The longest needle the summoned switcher will hold. A tab is found by a
/// few characters of its name or by its position; nobody types a sentence at
/// a switcher, and a fixed buffer keeps the workspace allocation-free.
pub const max_palette_query_bytes: usize = 64;

/// The summoned tab switcher's state.
///
/// It is a WORKSPACE's, not the model's: each window has its own tabs, so each
/// window has its own switcher, and a palette open in the window behind must
/// not eat the keys typed in the window in front.
///
/// Deliberately shaped like the scrollback search beside it — a drawn field
/// with an app-routed needle rather than a text-entry widget. The app already
/// routes every canvas key itself, and the requirement that decides this is
/// that a keystroke aimed at the switcher can never reach the shell. That is a
/// property of the routing, so the field is drawn where the routing lives.
pub const Palette = struct {
    open: bool = false,
    query: [max_palette_query_bytes]u8 = [_]u8{0} ** max_palette_query_bytes,
    query_len: usize = 0,
    /// An index into the FILTERED list, not into `tabs`. Filtering changes
    /// what row 0 means on every keystroke, and an index into the unfiltered
    /// list would silently point at a row the user cannot see.
    cursor: usize = 0,

    pub fn needle(palette: *const Palette) []const u8 {
        return palette.query[0..palette.query_len];
    }

    pub fn reset(palette: *Palette) void {
        palette.open = false;
        palette.query_len = 0;
        palette.cursor = 0;
    }

    /// Append typed text, dropping anything past the buffer rather than
    /// truncating mid-codepoint on the next comparison.
    pub fn append(palette: *Palette, text: []const u8) void {
        for (text) |byte| {
            if (byte < 0x20 or byte == 0x7f) continue;
            if (palette.query_len >= palette.query.len) return;
            palette.query[palette.query_len] = byte;
            palette.query_len += 1;
        }
        palette.cursor = 0;
    }

    /// Delete one BYTE, then walk back off any UTF-8 continuation bytes so a
    /// multi-byte character leaves as one keystroke rather than as four
    /// mangled ones.
    pub fn backspace(palette: *Palette) void {
        if (palette.query_len == 0) return;
        palette.query_len -= 1;
        while (palette.query_len > 0 and (palette.query[palette.query_len] & 0xc0) == 0x80) {
            palette.query_len -= 1;
        }
        palette.cursor = 0;
    }
};

pub const Workspace = struct {
    tabs: [max_tabs]layout.Tree = [_]layout.Tree{.{}} ** max_tabs,
    /// The summoned tab switcher. Presentational plus a keyboard mode, and
    /// deliberately NOT part of `topologySnapshot`: an open switcher is not a
    /// workspace shape and must never be restored on launch.
    palette: Palette = .{},
    tab_count: usize = 0,
    selected_tab: usize = 0,
    /// The web surface owns the content area. Independent of `selected_tab`,
    /// so returning from Web restores the tab that was there. Only the MAIN
    /// window can raise it: the webview is a scene-declared view of window 0.
    web_selected: bool = false,
    /// The tab the pointer is over, or `no_hovered_tab`. Purely presentational
    /// — it decides whether that tab shows its close `x` — but it lives here
    /// because the view is a pure function of it.
    hovered_tab: usize = no_hovered_tab,
    /// This window's titlebar inset, from its own chrome event.
    chrome_top: f32 = 0,
    /// This window's canvas size and device scale. Per-window because two
    /// windows can sit on different monitors at different densities, and every
    /// geometric derivation (pane rects, hit tests, the PTY sizing pump) reads
    /// them.
    surface_size: geometry.SizeF = geometry.SizeF.init(1100, 640),
    surface_scale_factor: f32 = 1,
    /// The platform window id this workspace is currently rendered into,
    /// learned from its own frame events. Zero until the first frame.
    ///
    /// Needed because a SHORTCUT event carries a window id and no label, so it
    /// is the only way "cmd+W in the window I am looking at" resolves to a
    /// workspace. The id is the platform's, not ours: it is not stable across
    /// a close and reopen, which is exactly why it is learned per frame rather
    /// than assigned.
    window_id: native_sdk.platform.WindowId = 0,

    pub fn tree(workspace: *Workspace, index: usize) ?*layout.Tree {
        if (index >= workspace.tab_count) return null;
        return &workspace.tabs[index];
    }

    pub fn treeConst(workspace: *const Workspace, index: usize) ?*const layout.Tree {
        if (index >= workspace.tab_count) return null;
        return &workspace.tabs[index];
    }

    pub fn selectedTree(workspace: *Workspace) ?*layout.Tree {
        if (workspace.web_selected) return null;
        return workspace.tree(workspace.selected_tab);
    }

    pub fn selectedTreeConst(workspace: *const Workspace) ?*const layout.Tree {
        if (workspace.web_selected) return null;
        return workspace.treeConst(workspace.selected_tab);
    }

    /// Keyboard focus follows the selected tab's own focused pane. Unfiltered
    /// on purpose: remote focus publication needs the ref the tree names even
    /// in the instant before the provider's bookkeeping catches up.
    pub fn focusedTerminalRef(workspace: *const Workspace) ?TerminalRef {
        const current = workspace.selectedTreeConst() orelse return null;
        return current.focusedTerminal();
    }

    /// The tab index whose tree holds `id` in any pane.
    pub fn tabOfTerminal(workspace: *const Workspace, id: TerminalRef) ?usize {
        for (workspace.tabs[0..workspace.tab_count], 0..) |candidate, index| {
            if (candidate.find(id) != null) return index;
        }
        return null;
    }

    /// The label identity of a tab: its focused pane's terminal.
    pub fn tabTerminal(workspace: *const Workspace, index: usize) ?TerminalRef {
        const current = workspace.treeConst(index) orelse return null;
        return current.focusedTerminal();
    }

    /// Give `id` a tab of its own. Idempotent: a terminal already living in
    /// some pane keeps the tab it is in.
    pub fn admitTab(workspace: *Workspace, id: TerminalRef) bool {
        if (workspace.tabOfTerminal(id) != null) return true;
        if (workspace.tab_count >= max_tabs) return false;
        workspace.tabs[workspace.tab_count] = layout.Tree.initLeaf(id);
        workspace.tab_count += 1;
        return true;
    }

    pub fn dropTab(workspace: *Workspace, index: usize) void {
        if (index >= workspace.tab_count) return;
        var cursor = index;
        while (cursor + 1 < workspace.tab_count) : (cursor += 1) workspace.tabs[cursor] = workspace.tabs[cursor + 1];
        workspace.tab_count -= 1;
        workspace.tabs[workspace.tab_count] = .{};
        if (workspace.tab_count == 0) {
            workspace.selected_tab = 0;
            return;
        }
        if (workspace.selected_tab >= workspace.tab_count) workspace.selected_tab = workspace.tab_count - 1;
    }

    pub fn selectTab(workspace: *Workspace, index: usize) bool {
        if (index >= workspace.tab_count) return false;
        workspace.selected_tab = index;
        workspace.web_selected = false;
        return true;
    }

    /// Select the tab holding `id` AND focus the pane that holds it. This is
    /// what a tab click and cmd+T mean; it can never invent a pane.
    pub fn selectTerminal(workspace: *Workspace, id: TerminalRef) bool {
        const index = workspace.tabOfTerminal(id) orelse return false;
        workspace.selected_tab = index;
        workspace.web_selected = false;
        _ = workspace.tabs[index].focusTerminal(id);
        return true;
    }

    pub fn selectWeb(workspace: *Workspace) void {
        workspace.web_selected = true;
    }

    pub fn moveTerminal(workspace: *Workspace, id: TerminalRef, delta: i8) bool {
        const current = workspace.tabOfTerminal(id) orelse return false;
        const target_signed = @as(isize, @intCast(current)) + delta;
        if (target_signed < 0 or target_signed >= workspace.tab_count) return false;
        const target: usize = @intCast(target_signed);
        std.mem.swap(layout.Tree, &workspace.tabs[current], &workspace.tabs[target]);
        if (workspace.selected_tab == current) {
            workspace.selected_tab = target;
        } else if (workspace.selected_tab == target) {
            workspace.selected_tab = current;
        }
        return true;
    }
};

/// A window and a tab inside it — what a terminal-to-topology lookup has to
/// answer once there is more than one window, because a pty event names a
/// terminal and nothing else.
pub const TerminalLocation = struct { window: usize, tab: usize };

pub const Model = struct {
    provider: *LocalProvider,
    /// The user's config, loaded once at startup and then MODEL STATE: the
    /// font-size chords mutate it, so everything downstream (design tokens,
    /// cell metrics, the PTY sizing pump) reads it from here rather than
    /// from the file it came from.
    config: Config = .{},
    /// Live cmd+= / cmd+- delta over `config.font_size`, in points.
    font_size_offset: f32 = 0,
    /// Backing storage for the cwd-carrying argv of each registry slot.
    ///
    /// `Pane.argv` is a SLICE, and `spawnPane` re-reads it on every Restart,
    /// so the bytes have to outlive the spawn that first used them — stack
    /// storage at the spawn site would dangle the instant it returned. The
    /// storage lives HERE rather than on `Pane` because the pane's layout is
    /// owned by the provider, and because the model outlives every pane in
    /// it: a slot reused by a new terminal is rewritten before that
    /// terminal's first spawn, so no live argv ever aliases a dead one.
    cwd_argv: [max_terminals]local.CwdArgv = [_]local.CwdArgv{.{}} ** max_terminals,
    phux_provider: ?*PhuxProvider = null,
    remote_ui: [max_remote_terminals]RemoteUiState = [_]RemoteUiState{.{}} ** max_remote_terminals,
    pointer_state: ?*PointerState = null,
    /// Window 0's workspace, INLINE.
    ///
    /// Deliberately not one of N by-value slots. A `layout.Tree` is 9,432
    /// bytes and there are `max_tabs` of them, so a workspace is ~151 KB;
    /// five of those inside a model that is itself passed by value through
    /// `TerminalApp.init` would be three quarters of a megabyte of stack per
    /// construction, and this repo has already taken a real main-thread stack
    /// overflow from exactly that shape (see the comment on
    /// `tests/support.zig:initTerminalApp`). Window 0 always exists, so it
    /// costs nothing to keep here; windows 1..N are minted on demand.
    primary: Workspace = .{},
    /// Windows 1..`max_secondary_windows`, heap-allocated when cmd+N opens
    /// them and freed when they close. A null slot IS a closed window: the
    /// declared-window set the runtime reconciles is derived from this array,
    /// so there is no second "is it open" flag to drift.
    secondary: [max_secondary_windows]?*Workspace = @splat(null),
    /// Which window input is currently addressed to. Every message that
    /// reshapes a workspace acts on THIS one; the host moves it as input
    /// arrives from a window, and `.focus_window` is the seam a test drives.
    active_window: usize = 0,
    /// Whether the scene's own window is still on screen. cmd+W through the
    /// main window's last tab closes it while secondaries are still open, and
    /// the app quits only once nothing is left.
    primary_open: bool = true,
    /// A cmd+N was refused because every window slot is taken.
    ///
    /// A latch rather than a transient, because the refusal has to be VISIBLE:
    /// a chord that silently does nothing is indistinguishable from a chord
    /// that is not bound. The chrome reads it, and the next successful window
    /// open — or any other window closing — clears it.
    window_limit_refused: bool = false,
    tab_placement: TabPlacement = .top,
    browser_page: BrowserPage = .github,
    browser_navigation_token: u64 = 0,
    focused: bool = true,
    consumed_shortcut_keys_held: u64 = 0,
    held_terminal_keys: [max_held_terminal_keys]HeldTerminalKey = [_]HeldTerminalKey{.{}} ** max_held_terminal_keys,
    pointer_captures: [max_pointer_captures]PointerCapture = [_]PointerCapture{.{ .terminal_id = .terminal_1 }} ** max_pointer_captures,
    copy_inflight: bool = false,
    copy_owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
    paste_inflight: bool = false,
    paste_owner: ReplicaOwner = .{
        .terminal_ref = provider_contract.localTerminalRef(.terminal_1),
        .generation = .{},
    },
    paste_failed: bool = false,
    /// Where the in-flight clipboard read is going to land. A paste issued
    /// while the scrollback search field is up belongs to the NEEDLE, not to
    /// the child process, and the two differ in more than destination: a
    /// needle paste is legitimate against a pane that no longer accepts input,
    /// because searching a dead session's scrollback is ordinary work.
    paste_target: PasteTarget = .terminal,
    /// Where the layout snapshot goes and what is owed to it. Disabled by
    /// default so every test and every fixture stays free of disk traffic
    /// until a composition root hands it a real path.
    state: StatePersistence = .{},

    // -------------------------------------------------------- windows

    /// The workspace of the window input is currently addressed to.
    ///
    /// Window 0 is the fallback for an `active_window` whose slot has since
    /// closed: a message that arrives one dispatch after its window went away
    /// must land somewhere real rather than reach through a null.
    pub fn ws(model: *Model) *Workspace {
        return model.wsAt(model.active_window) orelse &model.primary;
    }

    pub fn wsConst(model: *const Model) *const Workspace {
        return model.wsAtConst(model.active_window) orelse &model.primary;
    }

    pub fn wsAt(model: *Model, index: usize) ?*Workspace {
        if (index == 0) return &model.primary;
        if (index > max_secondary_windows) return null;
        return model.secondary[index - 1];
    }

    pub fn wsAtConst(model: *const Model, index: usize) ?*const Workspace {
        if (index == 0) return &model.primary;
        if (index > max_secondary_windows) return null;
        return model.secondary[index - 1];
    }

    /// Whether window `index` is on screen. Window 0 answers `primary_open`
    /// because its window is the SCENE's and is not declared by the model;
    /// every other window's existence is its slot.
    pub fn windowOpen(model: *const Model, index: usize) bool {
        if (index == 0) return model.primary_open;
        if (index > max_secondary_windows) return false;
        return model.secondary[index - 1] != null;
    }

    pub fn openWindowCount(model: *const Model) usize {
        var count: usize = 0;
        for (0..max_windows) |index| {
            if (model.windowOpen(index)) count += 1;
        }
        return count;
    }

    /// The lowest free secondary slot, or null at the ceiling. Lowest-first so
    /// a closed-and-reopened window reuses its label and its declared canvas
    /// rather than walking up the namespace until it runs out.
    pub fn freeWindowIndex(model: *const Model) ?usize {
        for (model.secondary, 0..) |slot, offset| {
            if (slot == null) return offset + 1;
        }
        return null;
    }

    /// Mint window `index`'s workspace. The caller owns the decision that the
    /// slot is free; a slot already taken is left exactly as it was.
    pub fn openWindow(model: *Model, index: usize) ?*Workspace {
        if (index == 0) {
            model.primary_open = true;
            return &model.primary;
        }
        if (index > max_secondary_windows) return null;
        if (model.secondary[index - 1]) |existing| return existing;
        const workspace = std.heap.page_allocator.create(Workspace) catch return null;
        workspace.* = .{};
        model.secondary[index - 1] = workspace;
        return workspace;
    }

    /// Retire window `index`. The workspace's tabs are NOT torn down here —
    /// every close path drains them through the ordinary pane-close cascade
    /// first, so this only releases storage the model no longer names.
    pub fn closeWindow(model: *Model, index: usize) void {
        if (index == 0) {
            model.primary_open = false;
            model.primary = .{};
        } else if (index <= max_secondary_windows) {
            if (model.secondary[index - 1]) |workspace| {
                std.heap.page_allocator.destroy(workspace);
                model.secondary[index - 1] = null;
            }
        }
        if (model.active_window == index) model.active_window = model.firstOpenWindow();
    }

    /// The lowest-numbered window still open, or 0 when none is. Used as the
    /// landing place for input after the active window goes away.
    pub fn firstOpenWindow(model: *const Model) usize {
        for (0..max_windows) |index| {
            if (model.windowOpen(index)) return index;
        }
        return 0;
    }

    /// Where a terminal lives, across EVERY window.
    ///
    /// A pty exit event names a terminal and nothing else, and the terminal
    /// may belong to a window that is not the active one — so the close
    /// cascade cannot ask the active workspace and take null for an answer.
    pub fn locateTerminal(model: *const Model, id: TerminalRef) ?TerminalLocation {
        for (0..max_windows) |index| {
            const workspace = model.wsAtConst(index) orelse continue;
            if (workspace.tabOfTerminal(id)) |tab| return .{ .window = index, .tab = tab };
        }
        return null;
    }

    pub fn phux(model: *Model) ?*PhuxProvider {
        if (comptime !support.phux_enabled) return null;
        return model.phux_provider;
    }

    pub fn phuxConst(model: *const Model) ?*const PhuxProvider {
        if (comptime !support.phux_enabled) return null;
        return model.phux_provider;
    }

    pub fn containsTerminal(model: *const Model, terminal_ref: TerminalRef) bool {
        return switch (support.providerKind(terminal_ref)) {
            .local => model.provider.contains(terminal_ref),
            .phux => if (model.phuxConst()) |remote| remote.contains(terminal_ref) else false,
        };
    }

    pub fn terminalOwner(model: *const Model, terminal_ref: TerminalRef) ?ReplicaOwner {
        return switch (support.providerKind(terminal_ref)) {
            .local => model.provider.owner(terminal_ref),
            .phux => if (model.phuxConst()) |remote| remote.owner(terminal_ref) else null,
        };
    }

    pub fn ownerIsCurrent(model: *const Model, owner_value: ReplicaOwner) bool {
        return switch (support.providerKind(owner_value.terminal_ref)) {
            .local => model.provider.ownerIsCurrent(owner_value),
            .phux => if (model.phuxConst()) |remote| remote.ownerIsCurrent(owner_value) else false,
        };
    }

    pub fn remotePresentation(model: *const Model, terminal_ref: TerminalRef) ?Presentation {
        if (support.providerKind(terminal_ref) != .phux) return null;
        const remote = model.phuxConst() orelse return null;
        return remote.presentation(terminal_ref);
    }

    pub fn remoteUi(model: *Model, terminal_ref: TerminalRef) ?*RemoteUiState {
        const current_owner = model.terminalOwner(terminal_ref) orelse return null;
        var vacant: ?*RemoteUiState = null;
        for (&model.remote_ui) |*state| {
            if (state.terminal_ref) |known| {
                if (!known.eql(terminal_ref)) continue;
                if (!state.owner.eql(current_owner)) state.* = .{ .terminal_ref = terminal_ref, .owner = current_owner };
                return state;
            }
            if (vacant == null) vacant = state;
        }
        const state = vacant orelse return null;
        state.* = .{ .terminal_ref = terminal_ref, .owner = current_owner };
        return state;
    }

    pub fn remoteUiConst(model: *const Model, terminal_ref: TerminalRef) ?*const RemoteUiState {
        for (&model.remote_ui) |*state| {
            if (state.terminal_ref) |known| if (known.eql(terminal_ref)) return state;
        }
        return null;
    }

    // ------------------------------------------------------------ tabs
    //
    // Everything below addresses the ACTIVE window's workspace. These stayed
    // on `Model` rather than being spelled `model.ws().x` at every call site
    // because the two say the same thing and the shorter one keeps the ~120
    // callers honest; the explicit `wsAt(index)` form is what a caller that
    // means a SPECIFIC window (the per-window view, the per-window painter)
    // reaches for, and the type system keeps the two apart.

    pub fn tree(model: *Model, index: usize) ?*layout.Tree {
        return model.ws().tree(index);
    }

    pub fn treeConst(model: *const Model, index: usize) ?*const layout.Tree {
        return model.wsConst().treeConst(index);
    }

    pub fn selectedTree(model: *Model) ?*layout.Tree {
        return model.ws().selectedTree();
    }

    pub fn selectedTreeConst(model: *const Model) ?*const layout.Tree {
        return model.wsConst().selectedTreeConst();
    }

    /// The surface the content area shows. Derived: there is no stored copy
    /// to drift from the tab list.
    pub fn selectedSurface(model: *const Model) SurfaceSelection {
        const terminal_ref = model.focusedTerminalRef() orelse return .web;
        return .{ .terminal = terminal_ref };
    }

    /// The focused pane's terminal, filtered to one a provider still vouches
    /// for. Callers that route INPUT use this: a ref no provider owns must
    /// not be treated as a live selection.
    pub fn selectedTerminalRef(model: *const Model) ?TerminalRef {
        const id = model.focusedTerminalRef() orelse return null;
        return if (model.containsTerminal(id)) id else null;
    }

    pub fn selectedTerminalId(model: *const Model) ?TerminalRef {
        return model.selectedTerminalRef();
    }

    /// Keyboard focus follows the selected tab's own focused pane. Selection
    /// and focus were separate fields under the two-pane model and could
    /// disagree; a tree has exactly one focused leaf. Unfiltered on purpose:
    /// remote focus publication needs the ref the tree names even in the
    /// instant before the provider's own bookkeeping catches up.
    pub fn focusedTerminalRef(model: *const Model) ?TerminalRef {
        return model.wsConst().focusedTerminalRef();
    }

    pub fn focusedTerminalId(model: *const Model) ?TerminalRef {
        return model.focusedTerminalRef();
    }

    pub fn focusedPane(model: *Model) ?*Pane {
        const id = model.focusedTerminalRef() orelse return null;
        return model.provider.terminal(id);
    }

    /// The tab index whose tree holds `id` in any pane of the ACTIVE window.
    pub fn tabOfTerminal(model: *const Model, id: TerminalRef) ?usize {
        return model.wsConst().tabOfTerminal(id);
    }

    pub fn terminalOrderIndex(model: *const Model, id: TerminalRef) ?usize {
        return model.tabOfTerminal(id);
    }

    /// The label identity of a tab: its focused pane's terminal.
    pub fn tabTerminal(model: *const Model, index: usize) ?TerminalRef {
        return model.wsConst().tabTerminal(index);
    }

    /// Give `id` a tab of its own in the active window. Idempotent: a
    /// terminal already living in some pane keeps the tab it is in.
    ///
    /// A terminal that belongs to ANOTHER window is refused rather than
    /// duplicated: two windows holding one terminal would be two trees
    /// driving one emulator, which is the exact invariant `validate` already
    /// enforces within a window.
    pub fn admitTab(model: *Model, id: TerminalRef) bool {
        if (model.locateTerminal(id)) |where| return where.window == model.active_window;
        return model.ws().admitTab(id);
    }

    /// Backwards-compatible alias: admitting a terminal now means giving it
    /// a tab.
    pub fn admitToOrder(model: *Model, id: TerminalRef) bool {
        return model.admitTab(id);
    }

    pub fn dropTab(model: *Model, index: usize) void {
        model.ws().dropTab(index);
    }

    pub fn dropFromOrder(model: *Model, index: usize) void {
        model.dropTab(index);
    }

    pub fn selectTab(model: *Model, index: usize) bool {
        return model.ws().selectTab(index);
    }

    /// Select the tab holding `id` AND focus the pane that holds it. This is
    /// what a tab click and cmd+T mean; it can never invent a pane.
    pub fn selectTerminal(model: *Model, id: TerminalRef) bool {
        return model.ws().selectTerminal(id);
    }

    pub fn selectWeb(model: *Model) void {
        model.ws().selectWeb();
    }

    pub fn moveTerminal(model: *Model, id: TerminalRef, delta: i8) bool {
        return model.ws().moveTerminal(id, delta);
    }

    /// Drop panes whose terminal no longer exists, then drop tabs that lost
    /// every pane. Called after any provider publication.
    ///
    /// Runs over EVERY window: a provider publication is app-wide, and a
    /// retired terminal has to leave whichever window's tree happened to hold
    /// it, not only the one that is in front.
    pub fn normalizeTopology(model: *Model) void {
        for (0..max_windows) |window_index| {
            const workspace = model.wsAt(window_index) orelse continue;
            var index: usize = 0;
            while (index < workspace.tab_count) {
                var current = &workspace.tabs[index];
                var refs: [layout.max_panes]TerminalRef = undefined;
                const count = current.terminals(&refs);
                for (refs[0..count]) |candidate| {
                    if (!model.containsTerminal(candidate)) _ = current.closeTerminal(candidate);
                }
                if (current.isEmpty()) workspace.dropTab(index) else index += 1;
            }
            if (workspace.tab_count == 0) {
                // Only the MAIN window has a web surface to fall back to; a
                // secondary window with no tabs is a window with nothing in
                // it, which the close cascade retires.
                workspace.web_selected = window_index == 0;
                workspace.selected_tab = 0;
                continue;
            }
            if (workspace.selected_tab >= workspace.tab_count) workspace.selected_tab = workspace.tab_count - 1;
        }
    }

    pub fn reconcileRemoteTerminals(model: *Model) void {
        const remote = model.phuxConst() orelse return;
        var refs: [max_remote_terminals]TerminalRef = undefined;
        const count = remote.terminalRefs(&refs);
        // Remote panes whose terminal the coordinator retired leave the tree;
        // `normalizeTopology` then collapses tabs that lost every pane.
        model.normalizeTopology();
        for (refs[0..count]) |candidate| _ = model.admitTab(candidate);
        for (&model.remote_ui) |*state| {
            const known = state.terminal_ref orelse continue;
            var retained = false;
            for (refs[0..count]) |terminal_ref| if (known.eql(terminal_ref)) {
                retained = true;
                break;
            };
            if (!retained) state.* = .{};
        }
        for (refs[0..count]) |terminal_ref| _ = model.remoteUi(terminal_ref);
    }

    /// The LIVE terminal type size. `font_size_offset` is the live delta the
    /// cmd+= / cmd+- chords own; the config's own size is the origin cmd+0
    /// returns to, which is why the two are separate — resetting to a
    /// hardcoded 13 would throw away the `font-size` the user wrote down.
    pub fn fontSize(model: *const Model) f32 {
        return std.math.clamp(
            model.config.fontSize() + model.font_size_offset,
            config_module.min_font_size,
            config_module.max_font_size,
        );
    }

    /// Step the terminal type size by whole points and say whether it moved.
    /// A step at the clamp is a no-op rather than a silently growing number
    /// that reflows nothing.
    pub fn stepFontSize(model: *Model, delta: f32) bool {
        const before = model.fontSize();
        model.font_size_offset += delta;
        const after = model.fontSize();
        if (after == before) {
            // Undo the step that fell off the end, so the offset cannot
            // accumulate an arbitrarily long way past the clamp and make
            // the first step back a dead key.
            model.font_size_offset -= delta;
            return false;
        }
        return true;
    }

    pub fn resetFontSize(model: *Model) bool {
        if (model.font_size_offset == 0) return false;
        model.font_size_offset = 0;
        return true;
    }

    // ------------------------------------------------------ persistence

    pub fn topologySnapshot(model: *const Model) !TopologySnapshot {
        var snapshot: TopologySnapshot = .{ .tab_placement = model.tab_placement };
        var written: u8 = 0;
        var windows: u8 = 0;
        // Windows are written in INDEX order and renumbered densely, because
        // the slot a window happened to occupy is an allocation detail: a
        // session whose second window was closed must not restore as a hole.
        for (0..max_windows) |window_index| {
            if (!model.windowOpen(window_index)) continue;
            const workspace = model.wsAtConst(window_index) orelse continue;
            var selected: ?u8 = null;
            const first = written;
            for (workspace.tabs[0..workspace.tab_count], 0..) |current, index| {
                if (written >= topology.max_snapshot_tabs) break;
                const encoded = encodeTab(current) orelse continue;
                snapshot.tabs[written] = encoded;
                if (!workspace.web_selected and index == workspace.selected_tab) selected = written - first;
                written += 1;
            }
            // A window that contributed no persistable tab is still a window
            // the user has open — except window 0, whose absence from the
            // snapshot is what "there is nothing to restore" has always meant.
            snapshot.windows[windows] = .{
                .tab_count = written - first,
                .selection = if (selected) |value| .{ .tab = value } else .web,
            };
            windows += 1;
        }
        snapshot.window_count = windows;
        snapshot.tab_count = written;

        // Directories are read off the LIVE panes rather than carried in the
        // tree, because the tree does not know them: a cwd is whatever the
        // shell last reported through OSC 7, and a pane that never reported
        // one records nothing (which restores as "$HOME", the first
        // terminal's behaviour, not as "/").
        for (snapshot.tabs[0..written]) |tab| {
            for (tab.nodes) |node| {
                if (node.kind != .leaf or !node.has_terminal) continue;
                const pane = model.provider.terminalConst(local.localRef(node.terminal)) orelse continue;
                snapshot.setCwd(node.terminal, pane.pwd());
            }
        }

        try snapshot.validate();
        return snapshot;
    }

    /// A cheap hash of everything the SNAPSHOT would carry about shape:
    /// the tab list, each tab's tree, which tab is selected, and where the
    /// strip sits.
    ///
    /// Deliberately excludes working directories. A cwd changes on every `cd`,
    /// and folding it in here would turn ordinary shell navigation into a disk
    /// write per debounce window for no layout reason. Directories are still
    /// captured accurately, because every save serializes the CURRENT panes
    /// and the shutdown flush always writes one.
    /// Folds in EVERY window: a tab opened in the window behind the one in
    /// front still changes what a restore should produce, so a hash that only
    /// saw the active workspace would leave that change unwritten until
    /// something else happened to move the shape.
    pub fn topologyFingerprint(model: *const Model) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, model.tab_placement);
        for (0..max_windows) |window_index| {
            const open = model.windowOpen(window_index);
            std.hash.autoHash(&hasher, open);
            if (!open) continue;
            const workspace = model.wsAtConst(window_index) orelse continue;
            std.hash.autoHash(&hasher, workspace.tab_count);
            std.hash.autoHash(&hasher, workspace.selected_tab);
            std.hash.autoHash(&hasher, workspace.web_selected);
            for (workspace.tabs[0..workspace.tab_count]) |tab| {
                std.hash.autoHash(&hasher, tab.root);
                std.hash.autoHash(&hasher, tab.focus);
                for (tab.nodes) |node| {
                    std.hash.autoHash(&hasher, node.kind);
                    if (node.kind == .free) continue;
                    std.hash.autoHash(&hasher, node.parent);
                    std.hash.autoHash(&hasher, node.first);
                    std.hash.autoHash(&hasher, node.second);
                    std.hash.autoHash(&hasher, node.orientation);
                    // A fraction is a float, which `autoHash` refuses; its bits
                    // are the identity that matters for "did the divider move".
                    std.hash.autoHash(&hasher, @as(u32, @bitCast(node.fraction)));
                    // Only LOCAL identity is folded in. A tab holding a remote
                    // pane is not persistable at all (`encodeTab` drops it), so
                    // there is no saved state for one to invalidate — and
                    // hashing a `RemoteTerminalId`'s inline host storage would
                    // cost a quarter-kilobyte per node on every message.
                    if (node.terminal) |id| {
                        const raw: u64 = if (provider_contract.localId(id)) |local_id| @intFromEnum(local_id) else 0;
                        std.hash.autoHash(&hasher, raw);
                    }
                }
            }
        }
        return hasher.final();
    }

    /// Write the layout SYNCHRONOUSLY, right now, on the calling thread.
    ///
    /// The debounced effect covers everything that happens while the app runs;
    /// this covers the interval between the last change and the debounce expiring
    /// — which is exactly "open a tab, then quit". It cannot be an effect: by the
    /// time shutdown is known, nothing will drain another effect queue, and a
    /// write posted to a worker thread would race the process out the door.
    ///
    /// Failure is silent by design, at every step. An app that refuses to exit
    /// because it could not write a layout file is worse than one that opens with
    /// the previous layout.
    pub fn writeWorkspaceState(model: *const Model, io: std.Io) void {
        if (!model.state.enabled()) return;
        var bytes: [session_state.max_state_bytes]u8 = undefined;
        const snapshot = model.topologySnapshot() catch return;
        const encoded = session_state.serialize(&snapshot, &bytes) catch return;
        const cwd = std.Io.Dir.cwd();
        const path = model.state.path();
        if (std.fs.path.dirname(path)) |parent| cwd.createDirPath(io, parent) catch return;
        cwd.writeFile(io, .{ .sub_path = path, .data = encoded }) catch return;
    }
};

/// Put every restored pane's shell in the directory the snapshot recorded.
///
/// Split out of `restoreModel` rather than done inside it because `Pane.argv`
/// is a SLICE into `Model.cwd_argv`, and `restoreModel` returns its model BY
/// VALUE — an argv written there would point into a model that is about to be
/// copied into its real home and then go out of scope. This runs against the
/// model in its final storage, which is the only place the slice is allowed to
/// point.
pub fn applyRestoredWorkingDirectories(model: *Model, snapshot: *const TopologySnapshot) void {
    for (0..max_terminals) |index| {
        if (model.provider.states[index] != .active) continue;
        const pane = model.provider.slot(index);
        const id = provider_contract.localId(pane.id) orelse continue;
        const cwd = snapshot.cwdFor(id);
        if (cwd.len == 0) continue;
        pane.argv = local.paneArgvIn(cwd, &model.cwd_argv[index]);
    }
}

/// Serialize one tree. A tab holding a REMOTE terminal is not persistable —
/// a phux terminal exists because its coordinator says so, and restoring it
/// locally would invent one — so such a tab is dropped from the snapshot.
fn encodeTab(current: layout.Tree) ?topology.SnapshotTab {
    if (current.isEmpty()) return null;
    var tab: topology.SnapshotTab = .{ .root = current.root, .focus = current.focus };
    for (current.nodes, 0..) |node, index| {
        switch (node.kind) {
            .free => continue,
            .leaf => {
                const held = node.terminal orelse return null;
                const local_id = provider_contract.localId(held) orelse return null;
                tab.nodes[index] = .{
                    .kind = .leaf,
                    .parent = node.parent,
                    .terminal = local_id,
                    .has_terminal = true,
                };
            },
            .branch => tab.nodes[index] = .{
                .kind = .branch,
                .parent = node.parent,
                .orientation = node.orientation,
                .fraction = node.fraction,
                .first = node.first,
                .second = node.second,
            },
        }
    }
    return tab;
}

fn decodeTab(tab: topology.SnapshotTab) layout.Tree {
    var current: layout.Tree = .{ .root = tab.root, .focus = tab.focus };
    for (tab.nodes, 0..) |node, index| {
        current.nodes[index] = switch (node.kind) {
            .free => .{},
            .leaf => .{
                .kind = .leaf,
                .parent = node.parent,
                .terminal = local.localRef(node.terminal),
            },
            .branch => .{
                .kind = .branch,
                .parent = node.parent,
                .orientation = node.orientation,
                .fraction = node.fraction,
                .first = node.first,
                .second = node.second,
            },
        };
    }
    return current;
}

/// Push the settings only an EMULATOR can hold into one session.
///
/// The split is deliberate. Background, foreground, and the selection wash
/// reach the painter through the design tokens (`terminalTokens`), because
/// those are the ones the emulator composes from its own defaults and an
/// application's OSC 10/11 must still be able to win. These three cannot go
/// that way:
///
///   palette      the ANSI-16 slots are the EMULATOR's (`vt.color.default`),
///                read back verbatim by the projection, so an override has
///                to land in the emulator's dynamic palette;
///   cursor color a user's `cursor-color` is an explicit choice, not a theme
///                default — it is exactly OSC 12's override channel, and
///                using `.default` would have the token accent overwrite it
///                on the next snapshot;
///   cursor style DECSCUSR state, which only the emulator carries.
///
/// Called AFTER `spawnPane`, which hard-resets the emulator: applying before
/// the reset would drop every one of these on the floor.
pub fn applySessionConfig(cfg: *const Config, session: *grid.Session) void {
    for (cfg.palette, 0..) |maybe_color, index| {
        const color = maybe_color orelse continue;
        session.term.colors.palette.set(@intCast(index), .{ .r = color.r, .g = color.g, .b = color.b });
    }
    if (cfg.cursor_color) |color| {
        session.term.colors.cursor.set(.{ .r = color.r, .g = color.g, .b = color.b });
    }
    session.term.setDefaultCursorStyle(switch (cfg.cursor_style) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
    });
    session.term.setDefaultCursorBlink(cfg.cursor_style_blink);
}

pub fn initialModelWithPhux(session: *grid.Session, phux_provider: ?*PhuxProvider) Model {
    const local_provider = LocalProvider.create(std.heap.page_allocator, session) catch @panic("failed to allocate local terminal provider");
    var pointer_state: ?*PointerState = null;
    if (comptime support.phux_enabled) if (phux_provider != null) {
        pointer_state = std.heap.page_allocator.create(PointerState) catch @panic("failed to allocate pointer monitor state");
        pointer_state.?.* = .{};
    };
    var model: Model = .{
        .provider = local_provider,
        .phux_provider = phux_provider,
        .pointer_state = pointer_state,
    };
    _ = model.admitTab(local.initialTerminalRef(0));
    return model;
}

pub fn initialModel(session: *grid.Session) Model {
    return initialModelWithPhux(session, null);
}

pub fn attachPhuxProvider(model: *Model, phux_provider: ?*PhuxProvider) void {
    if (comptime !support.phux_enabled) return;
    const remote = phux_provider orelse return;
    model.phux_provider = remote;
    if (model.pointer_state != null) return;
    const pointer_state = std.heap.page_allocator.create(PointerState) catch @panic("failed to allocate pointer monitor state");
    pointer_state.* = .{};
    model.pointer_state = pointer_state;
}

pub fn initialModelWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !Model {
    const provider = try LocalProvider.createWithIo(gpa, io, session);
    var model: Model = .{ .provider = provider };
    _ = model.admitTab(local.initialTerminalRef(0));
    return model;
}

pub fn initialProductionModelWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !Model {
    return initialModelWithIo(gpa, io, session);
}

pub fn restoreModel(gpa: std.mem.Allocator, io: std.Io, persisted: PersistedTopologySnapshot) !Model {
    return restoreModelWithScrollback(gpa, io, persisted, grid.Session.max_scrollback);
}

/// Restore with an explicit scrollback ceiling, so a restored window's panes
/// honour `scrollback-limit` too. Every restored leaf gets a fresh session
/// built HERE, which is why the limit has to arrive as a parameter rather than
/// being set on the provider afterwards.
pub fn restoreModelWithScrollback(
    gpa: std.mem.Allocator,
    io: std.Io,
    persisted: PersistedTopologySnapshot,
    max_scrollback_bytes: usize,
) !Model {
    const snapshot = try topology.migrateTopologySnapshot(persisted);
    const provider = try gpa.create(LocalProvider);
    errdefer gpa.destroy(provider);
    provider.* = .{ .gpa = gpa, .io = io, .max_scrollback_bytes = max_scrollback_bytes };

    var model: Model = .{
        .provider = provider,
        .tab_placement = snapshot.tab_placement,
    };
    errdefer provider.destroy();
    errdefer for (model.secondary) |slot| if (slot) |workspace| std.heap.page_allocator.destroy(workspace);

    // Every persisted leaf gets a FRESH session: process state is explicitly
    // not restored (`process_restoration_supported`), only the shape.
    //
    // Windows are restored in the order they were written, which is the order
    // they were numbered: window 0 into the inline workspace, the rest into
    // freshly minted secondary slots. A snapshot from before windows existed
    // migrates to exactly one window, so it lands entirely in `primary`.
    for (0..snapshot.window_count) |window_index| {
        const workspace = model.openWindow(window_index) orelse return error.WindowCapacityReached;
        const tabs = snapshot.windowTabs(window_index);
        workspace.tab_count = tabs.len;
        workspace.web_selected = snapshot.windows[window_index].selection == .web;
        workspace.selected_tab = switch (snapshot.windows[window_index].selection) {
            .tab => |index| index,
            .web => 0,
        };
        for (tabs, 0..) |tab, tab_index| {
            workspace.tabs[tab_index] = decodeTab(tab);
            for (tab.nodes) |node| {
                if (node.kind != .leaf or !node.has_terminal) continue;
                const session = try grid.Session.createWithScrollback(gpa, io, 80, 24, provider.max_scrollback_bytes);
                errdefer session.destroy();
                var index: usize = 0;
                while (index < max_terminals and provider.states[index] != .vacant) : (index += 1) {}
                if (index == max_terminals) return error.TerminalCapacityReached;
                provider.slots[index] = .{
                    .id = local.localRef(node.terminal),
                    .session = session,
                    .pty_key = provider.next_pty_key,
                    .argv = local.paneArgv(0),
                };
                provider.states[index] = .active;
                provider.next_pty_key += 1;
                provider.next_terminal_raw = @max(provider.next_terminal_raw, @intFromEnum(node.terminal) + 1);
            }
        }
    }
    return model;
}

pub fn deinitModel(model: *Model) void {
    if (comptime support.phux_enabled) {
        if (model.pointer_state) |pointer_state| {
            if (pointer_state.monitor) |*monitor| monitor.stop();
            std.heap.page_allocator.destroy(pointer_state);
            model.pointer_state = null;
        }
        if (model.phux_provider) |remote| remote.destroy();
        model.phux_provider = null;
    }
    for (&model.secondary) |*slot| {
        if (slot.*) |workspace| std.heap.page_allocator.destroy(workspace);
        slot.* = null;
    }
    model.provider.destroy();
}
