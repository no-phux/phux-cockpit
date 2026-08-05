const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const provider_contract = @import("provider_contract");
const support = @import("phux_support.zig");
const local = @import("../providers/local/provider.zig");
const topology = @import("topology.zig");
const model_module = @import("model.zig");
const app_types = @import("app_types.zig");
const runtime = @import("terminal_runtime.zig");
const pointer_input = @import("pointer_input.zig");
const projection = @import("native/workspace_projection.zig");
const scene = @import("native/scene.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Model = model_module.Model;
const RemoteUiState = model_module.RemoteUiState;
const Msg = app_types.Msg;
const Fx = app_types.Fx;
const Pane = local.Pane;
const Placement = topology.Placement;
const TerminalRef = support.TerminalRef;
const ReplicaOwner = support.ReplicaOwner;
const PhysicalKey = support.PhysicalKey;
const ModifierMask = support.ModifierMask;
const KeyInput = support.KeyInput;
const Viewport = support.Viewport;
const phux_enabled = support.phux_enabled;
const phux_channel_key = support.phux_channel_key;
const pointer_channel_key = support.pointer_channel_key;
const pointer_module = support.pointer_module;
const providerKind = support.providerKind;
const optRefEql = support.optRefEql;
const optOwnerEql = support.optOwnerEql;
const max_terminal_count = local.max_terminal_count;
const pane_count = local.pane_count;
const clipboard_key = local.clipboard_key;
const paste_clipboard_key = local.paste_clipboard_key;
const max_held_terminal_keys = model_module.max_held_terminal_keys;
const replicaOwnerForPane = local.replicaOwnerForPane;
const spawnPane = runtime.spawnPane;
const paneForKey = runtime.paneForKey;
const feedOutput = runtime.feedOutput;
const flushOutbound = runtime.flushOutbound;
const moveResponsesToOutbound = runtime.moveResponsesToOutbound;
const enqueueOutbound = runtime.enqueueOutbound;
const enqueueTransient = runtime.enqueueTransient;
const encodeKeyEvent = runtime.encodeKeyEvent;
const sendCommittedText = runtime.sendCommittedText;
const keyIs = runtime.keyIs;
const drainPointerEvents = pointer_input.drainPointerEvents;
const handleTerminalPointer = pointer_input.handleTerminalPointer;
const endCapturesForTerminal = pointer_input.endCapturesForTerminal;
const endMismatchedMouseCaptures = pointer_input.endMismatchedMouseCaptures;
const endAllCaptures = pointer_input.endAllCaptures;
const endHiddenCaptures = pointer_input.endHiddenCaptures;
const handleSelectionAutoscroll = pointer_input.handleSelectionAutoscroll;
const terminalRefAtPoint = pointer_input.terminalRefAtPoint;
const paneFrameForTerminal = pointer_input.paneFrameForTerminal;
const validScale = pointer_input.validScale;
const syncMouseProtocol = pointer_input.syncMouseProtocol;
const cockpit_shortcuts = scene.cockpit_shortcuts;
const cockpitTokens = projection.cockpitTokens;
const splitAvailable = projection.splitAvailable;
const selectedTerminalCanClose = projection.selectedTerminalCanClose;
pub fn initFx(model: *Model, fx: *Fx) void {
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
            const pane = paneForKey(model, event.key) orelse return;
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
                    pane.session.refreshScreenText();
                    if (pane.selecting and !pane.session.rebaseSelection()) {
                        pane.selecting = false;
                    }
                    flushOutbound(pane, fx);
                    moveResponsesToOutbound(pane, fx);
                },
                .exit => {
                    pane.phase = if (event.reason == .rejected or event.reason == .spawn_failed) .failed else .ended;
                    pane.exit_code = event.code;
                    pane.exit_signal = event.signal;
                    pane.exit_reason = event.reason;
                    endCapturesForTerminal(model, fx, pane.id);
                    pane.native_delivery_failures = event.dropped_writes -| pane.write_refusals_total;
                    pane.write_refusals = 0;
                    pane.outbound_dropped += pane.outbound_len;
                    pane.outbound_dropped += pane.session.pendingResponses().len;
                    pane.outbound_head = 0;
                    pane.outbound_len = 0;
                    pane.session.clearResponses();
                },
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

pub fn onKey(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .key = event };
}

pub fn onText(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .text = event };
}

pub fn onWheel(wheel: native_sdk.platform.WheelEvent) ?Msg {
    if (wheel.delta_y == 0) return null;
    return .{ .wheel_fallback = .{ .x = wheel.x, .y = wheel.y, .delta = wheel.delta_y } };
}

pub fn onChrome(chrome: native_sdk.platform.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

pub fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
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

pub fn appShortcutKeyMask(key: []const u8) u32 {
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

pub fn commandShortcutKeyMask(name: []const u8) u32 {
    // Split is intentionally not globally registered while one terminal may
    // be active, but injected/menu shortcut events still need duplicate-edge
    // suppression once they reach this host.
    if (std.mem.eql(u8, name, "layout.split")) return appShortcutKeyMask("d");
    for (cockpit_shortcuts) |shortcut| {
        if (std.mem.eql(u8, name, shortcut.id)) return appShortcutKeyMask(shortcut.key);
    }
    return 0;
}
