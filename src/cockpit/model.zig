const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../terminal/grid.zig");
const provider_contract = @import("provider_contract");
const support = @import("phux_support.zig");
const local = @import("../providers/local/provider.zig");
const topology = @import("topology.zig");

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
pub const Placement = topology.Placement;
pub const LayoutMode = topology.LayoutMode;
pub const TabPlacement = topology.TabPlacement;
pub const SurfaceSelection = topology.SurfaceSelection;
pub const TopologySnapshot = topology.TopologySnapshot;
pub const SnapshotSelection = topology.SnapshotSelection;
pub const PersistedTopologySnapshot = topology.PersistedTopologySnapshot;
pub const pane_count = local.pane_count;
pub const max_terminal_count = local.max_terminal_count;
pub const max_remote_terminals = support.max_remote_terminals;

pub const max_held_terminal_keys: usize = 16;
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

pub const Model = struct {
    provider: *LocalProvider,
    phux_provider: ?*PhuxProvider = null,
    remote_ui: [max_remote_terminals]RemoteUiState = [_]RemoteUiState{.{}} ** max_remote_terminals,
    pointer_state: ?*PointerState = null,
    panes: *[pane_count]Pane,
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
    selected_surface: SurfaceSelection = .{ .terminal = provider_contract.localTerminalRef(.terminal_1) },
    layout: LayoutMode = .single,
    tab_placement: TabPlacement = .top,
    split_fraction: f32 = 0.5,
    browser_page: BrowserPage = .github,
    browser_navigation_token: u64 = 0,
    focus_placement: Placement = .primary,
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

    pub fn reconcileRemoteTerminals(model: *Model) void {
        const remote = model.phuxConst() orelse return;
        var refs: [max_remote_terminals]TerminalRef = undefined;
        const count = remote.terminalRefs(&refs);
        var order_index: usize = 0;
        while (order_index < model.terminal_count) {
            const current = model.terminal_order[order_index];
            if (support.providerKind(current) != .phux) {
                order_index += 1;
                continue;
            }
            var retained = false;
            for (refs[0..count]) |candidate| if (current.eql(candidate)) {
                retained = true;
                break;
            };
            if (retained) order_index += 1 else model.dropFromOrder(order_index);
        }
        for (refs[0..count]) |candidate| _ = model.admitToOrder(candidate);
        reconcileRemoteRefs(&model.attachments, model.terminal_order[0..model.terminal_count]);
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
        for (model.terminal_order[0..model.terminal_count], 0..) |candidate, index| if (candidate.eql(id)) return index;
        return null;
    }

    pub fn admitToOrder(model: *Model, id: TerminalRef) bool {
        if (model.terminalOrderIndex(id) != null) return true;
        if (model.terminal_count >= max_terminal_count) return false;
        model.terminal_order[model.terminal_count] = id;
        model.terminal_count += 1;
        return true;
    }

    pub fn dropFromOrder(model: *Model, index: usize) void {
        if (index >= model.terminal_count) return;
        var cursor = index;
        while (cursor + 1 < model.terminal_count) : (cursor += 1) model.terminal_order[cursor] = model.terminal_order[cursor + 1];
        model.terminal_count -= 1;
    }

    pub const AttachError = error{ UnknownTerminal, TerminalAlreadyAttached, PlacementOccupied };

    pub fn reconcileAttachmentFocus(model: *Model) void {
        var fallback: ?Placement = null;
        for (model.attachments, 0..) |attached, index| if (attached != null) {
            fallback = Placement.fromIndex(index).?;
            break;
        };
        if (model.selectedTerminalRef() != null and model.selectedPlacement() == null) {
            if (fallback) |replacement| model.selected_surface = .{ .terminal = model.attachments[replacement.index()].? };
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
        for (model.attachments) |attached| if (attached != null and attached.?.eql(terminal_ref)) return error.TerminalAlreadyAttached;
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
        for (model.attachments, 0..) |attached, index| if (attached != null and attached.?.eql(id)) {
            model.focus_placement = Placement.fromIndex(index).?;
            return;
        };
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
        for (&model.attachments) |*attached| if (attached.* != null and !model.containsTerminal(attached.*.?)) {
            attached.* = null;
        };
        if (model.terminal_count == 0) {
            model.selected_surface = .web;
            model.layout = .single;
            model.attachments = .{ null, null };
            return;
        }
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
                for (model.terminal_order[0..model.terminal_count]) |candidate| if (!candidate.eql(selected)) {
                    model.attachments[other_index] = candidate;
                    break;
                };
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

    pub fn topologySnapshot(model: *const Model) !TopologySnapshot {
        var snapshot: TopologySnapshot = .{
            .layout = model.layout,
            .split_fraction = model.split_fraction,
            .focused_attachment = model.focus_placement,
            .tab_placement = model.tab_placement,
        };
        var count: u8 = 0;
        for (model.terminal_order[0..model.terminal_count]) |id| {
            const local_id = provider_contract.localId(id) orelse continue;
            snapshot.terminal_order[count] = local_id;
            count += 1;
        }
        snapshot.terminal_count = count;
        for (model.attachments, 0..) |attached, index| snapshot.attachments[index] = if (attached) |id| provider_contract.localId(id) else null;
        snapshot.selection = switch (model.selected_surface) {
            .terminal => |id| if (provider_contract.localId(id)) |local_id| SnapshotSelection{ .terminal = local_id } else .web,
            .web => .web,
        };
        if (snapshot.terminal_count == 0) {
            snapshot.selection = .web;
            snapshot.layout = .single;
            snapshot.attachments = .{ null, null };
            snapshot.focused_attachment = .primary;
        } else {
            if (snapshot.layout == .split and (snapshot.attachments[0] == null or snapshot.attachments[1] == null)) snapshot.layout = .single;
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
                for (snapshot.attachments, 0..) |attached, index| if (attached != null) {
                    snapshot.focused_attachment = Placement.fromIndex(index).?;
                    break;
                };
            }
        }
        try snapshot.validate();
        return snapshot;
    }
};

pub fn reconcileRemoteRefs(attachments: *[pane_count]?TerminalRef, live_refs: []const TerminalRef) void {
    for (attachments) |*attached| {
        const current = attached.* orelse continue;
        if (support.providerKind(current) != .phux) continue;
        var retained = false;
        for (live_refs) |candidate| if (current.eql(candidate)) {
            retained = true;
            break;
        };
        if (!retained) attached.* = null;
    }
}

pub fn initialModelWithPhux(sessions: [pane_count]*grid.Session, phux_provider: ?*PhuxProvider) Model {
    const local_provider = LocalProvider.create(std.heap.page_allocator, sessions) catch @panic("failed to allocate local terminal provider");
    var pointer_state: ?*PointerState = null;
    if (comptime support.phux_enabled) if (phux_provider != null) {
        pointer_state = std.heap.page_allocator.create(PointerState) catch @panic("failed to allocate pointer monitor state");
        pointer_state.?.* = .{};
    };
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

pub fn attachPhuxProvider(model: *Model, phux_provider: ?*PhuxProvider) void {
    if (comptime !support.phux_enabled) return;
    const remote = phux_provider orelse return;
    model.phux_provider = remote;
    if (model.pointer_state != null) return;
    const pointer_state = std.heap.page_allocator.create(PointerState) catch @panic("failed to allocate pointer monitor state");
    pointer_state.* = .{};
    model.pointer_state = pointer_state;
}

pub fn initialModelWithIo(gpa: std.mem.Allocator, io: std.Io, sessions: [pane_count]*grid.Session) !Model {
    const provider = try LocalProvider.createWithIo(gpa, io, sessions);
    return .{ .provider = provider, .panes = &provider.terminals };
}

pub fn initialProductionModelWithIo(gpa: std.mem.Allocator, io: std.Io, session: *grid.Session) !Model {
    const provider = try LocalProvider.createSingleWithIo(gpa, io, session);
    return .{
        .provider = provider,
        .panes = &provider.terminals,
        .terminal_count = 1,
        .attachments = .{ local.initialTerminalRef(0), null },
    };
}

pub fn restoreModel(gpa: std.mem.Allocator, io: std.Io, persisted: PersistedTopologySnapshot) !Model {
    const snapshot = try topology.migrateTopologySnapshot(persisted);
    const provider = try gpa.create(LocalProvider);
    errdefer gpa.destroy(provider);
    provider.* = .{
        .gpa = gpa,
        .io = io,
        .terminals = undefined,
        .states = [_]local.RegistryState{.vacant} ** max_terminal_count,
        .next_terminal_raw = local.first_terminal_raw,
        .next_pty_key = 1,
    };
    var created: usize = 0;
    errdefer for (0..created) |index| provider.slot(index).session.destroy();
    while (created < snapshot.terminal_count) : (created += 1) {
        const session = try grid.Session.create(gpa, io, 80, 24);
        const local_id = snapshot.terminal_order[created];
        const pane = provider.slot(created);
        pane.* = .{
            .id = local.localRef(local_id),
            .session = session,
            .pty_key = provider.next_pty_key,
            .argv = local.paneArgv(0),
        };
        provider.states[created] = .active;
        provider.next_pty_key += 1;
        provider.next_terminal_raw = @max(provider.next_terminal_raw, @intFromEnum(local_id) + 1);
    }
    var result: Model = .{
        .provider = provider,
        .panes = &provider.terminals,
        .terminal_count = snapshot.terminal_count,
        .layout = snapshot.layout,
        .split_fraction = snapshot.split_fraction,
        .focus_placement = snapshot.focused_attachment,
        .tab_placement = snapshot.tab_placement,
        .selected_surface = switch (snapshot.selection) {
            .terminal => |id| .{ .terminal = local.localRef(id) },
            .web => .web,
        },
    };
    for (snapshot.terminal_order, 0..) |id, index| result.terminal_order[index] = local.localRef(id);
    for (snapshot.attachments, 0..) |attached, index| result.attachments[index] = if (attached) |id| local.localRef(id) else null;
    return result;
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
