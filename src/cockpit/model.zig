const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../terminal/grid.zig");
const provider_contract = @import("provider_contract");
const support = @import("phux_support.zig");
const local = @import("../providers/local/provider.zig");
const topology = @import("topology.zig");
const layout = @import("layout.zig");
const config_module = @import("../config/config.zig");

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

/// The workspace: a list of TABS, each owning a `layout.Tree` of panes.
///
/// The selected tab plus that tree's own `focus` fully determine what is
/// focused — there is no second focus variable to keep in sync. `web_selected`
/// is the one thing outside the tab model: the WebKit surface takes over the
/// content area without belonging to a tab.
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
    tabs: [max_tabs]layout.Tree = [_]layout.Tree{.{}} ** max_tabs,
    tab_count: usize = 0,
    selected_tab: usize = 0,
    /// The web surface owns the content area. Independent of `selected_tab`,
    /// so returning from Web restores the tab that was there.
    web_selected: bool = false,
    tab_placement: TabPlacement = .top,
    /// The tab the pointer is over, or `no_hovered_tab`. Purely presentational
    /// — it decides whether that tab shows its close `x` — but it lives on the
    /// model because the view is a pure function of it.
    hovered_tab: usize = no_hovered_tab,
    browser_page: BrowserPage = .github,
    browser_navigation_token: u64 = 0,
    focused: bool = true,
    consumed_shortcut_keys_held: u32 = 0,
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
    chrome_top: f32 = 0,
    surface_size: geometry.SizeF = geometry.SizeF.init(1100, 640),
    surface_scale_factor: f32 = 1,

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

    pub fn tree(model: *Model, index: usize) ?*layout.Tree {
        if (index >= model.tab_count) return null;
        return &model.tabs[index];
    }

    pub fn treeConst(model: *const Model, index: usize) ?*const layout.Tree {
        if (index >= model.tab_count) return null;
        return &model.tabs[index];
    }

    pub fn selectedTree(model: *Model) ?*layout.Tree {
        if (model.web_selected) return null;
        return model.tree(model.selected_tab);
    }

    pub fn selectedTreeConst(model: *const Model) ?*const layout.Tree {
        if (model.web_selected) return null;
        return model.treeConst(model.selected_tab);
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
        const current = model.selectedTreeConst() orelse return null;
        return current.focusedTerminal();
    }

    pub fn focusedTerminalId(model: *const Model) ?TerminalRef {
        return model.focusedTerminalRef();
    }

    pub fn focusedPane(model: *Model) ?*Pane {
        const id = model.focusedTerminalRef() orelse return null;
        return model.provider.terminal(id);
    }

    /// The tab index whose tree holds `id` in any pane.
    pub fn tabOfTerminal(model: *const Model, id: TerminalRef) ?usize {
        for (model.tabs[0..model.tab_count], 0..) |candidate, index| {
            if (candidate.find(id) != null) return index;
        }
        return null;
    }

    pub fn terminalOrderIndex(model: *const Model, id: TerminalRef) ?usize {
        return model.tabOfTerminal(id);
    }

    /// The label identity of a tab: its focused pane's terminal.
    pub fn tabTerminal(model: *const Model, index: usize) ?TerminalRef {
        const current = model.treeConst(index) orelse return null;
        return current.focusedTerminal();
    }

    /// Give `id` a tab of its own. Idempotent: a terminal already living in
    /// some pane keeps the tab it is in.
    pub fn admitTab(model: *Model, id: TerminalRef) bool {
        if (model.tabOfTerminal(id) != null) return true;
        if (model.tab_count >= max_tabs) return false;
        model.tabs[model.tab_count] = layout.Tree.initLeaf(id);
        model.tab_count += 1;
        return true;
    }

    /// Backwards-compatible alias: admitting a terminal now means giving it
    /// a tab.
    pub fn admitToOrder(model: *Model, id: TerminalRef) bool {
        return model.admitTab(id);
    }

    pub fn dropTab(model: *Model, index: usize) void {
        if (index >= model.tab_count) return;
        var cursor = index;
        while (cursor + 1 < model.tab_count) : (cursor += 1) model.tabs[cursor] = model.tabs[cursor + 1];
        model.tab_count -= 1;
        model.tabs[model.tab_count] = .{};
        if (model.tab_count == 0) {
            model.selected_tab = 0;
            return;
        }
        if (model.selected_tab >= model.tab_count) model.selected_tab = model.tab_count - 1;
    }

    pub fn dropFromOrder(model: *Model, index: usize) void {
        model.dropTab(index);
    }

    pub fn selectTab(model: *Model, index: usize) bool {
        if (index >= model.tab_count) return false;
        model.selected_tab = index;
        model.web_selected = false;
        return true;
    }

    /// Select the tab holding `id` AND focus the pane that holds it. This is
    /// what a tab click and cmd+N mean; it can never invent a pane.
    pub fn selectTerminal(model: *Model, id: TerminalRef) bool {
        const index = model.tabOfTerminal(id) orelse return false;
        model.selected_tab = index;
        model.web_selected = false;
        _ = model.tabs[index].focusTerminal(id);
        return true;
    }

    pub fn selectWeb(model: *Model) void {
        model.web_selected = true;
    }

    pub fn moveTerminal(model: *Model, id: TerminalRef, delta: i8) bool {
        const current = model.tabOfTerminal(id) orelse return false;
        const target_signed = @as(isize, @intCast(current)) + delta;
        if (target_signed < 0 or target_signed >= model.tab_count) return false;
        const target: usize = @intCast(target_signed);
        std.mem.swap(layout.Tree, &model.tabs[current], &model.tabs[target]);
        if (model.selected_tab == current) {
            model.selected_tab = target;
        } else if (model.selected_tab == target) {
            model.selected_tab = current;
        }
        return true;
    }

    /// Drop panes whose terminal no longer exists, then drop tabs that lost
    /// every pane. Called after any provider publication.
    pub fn normalizeTopology(model: *Model) void {
        var index: usize = 0;
        while (index < model.tab_count) {
            var current = &model.tabs[index];
            var refs: [layout.max_panes]TerminalRef = undefined;
            const count = current.terminals(&refs);
            for (refs[0..count]) |candidate| {
                if (!model.containsTerminal(candidate)) _ = current.closeTerminal(candidate);
            }
            if (current.isEmpty()) model.dropTab(index) else index += 1;
        }
        if (model.tab_count == 0) {
            model.web_selected = true;
            model.selected_tab = 0;
            return;
        }
        if (model.selected_tab >= model.tab_count) model.selected_tab = model.tab_count - 1;
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
        var selected: ?u8 = null;
        for (model.tabs[0..model.tab_count], 0..) |current, index| {
            const encoded = encodeTab(current) orelse continue;
            snapshot.tabs[written] = encoded;
            if (!model.web_selected and index == model.selected_tab) selected = written;
            written += 1;
        }
        snapshot.tab_count = written;
        snapshot.selection = if (selected) |value| .{ .tab = value } else .web;
        try snapshot.validate();
        return snapshot;
    }
};

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
    const snapshot = try topology.migrateTopologySnapshot(persisted);
    const provider = try gpa.create(LocalProvider);
    errdefer gpa.destroy(provider);
    provider.* = .{ .gpa = gpa, .io = io };

    var model: Model = .{
        .provider = provider,
        .tab_count = snapshot.tab_count,
        .tab_placement = snapshot.tab_placement,
        .web_selected = snapshot.selection == .web,
        .selected_tab = switch (snapshot.selection) {
            .tab => |index| index,
            .web => 0,
        },
    };
    errdefer provider.destroy();

    // Every persisted leaf gets a FRESH session: process state is explicitly
    // not restored (`process_restoration_supported`), only the shape.
    for (snapshot.tabs[0..snapshot.tab_count], 0..) |tab, tab_index| {
        model.tabs[tab_index] = decodeTab(tab);
        for (tab.nodes) |node| {
            if (node.kind != .leaf or !node.has_terminal) continue;
            const session = try grid.Session.create(gpa, io, 80, 24);
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
    model.provider.destroy();
}
