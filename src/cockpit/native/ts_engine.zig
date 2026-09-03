//! The native engine behind the TypeScript core's seam.
//!
//! The compiled core owns chrome presentation; this owns the durable chrome
//! STATE it presents — a real Cockpit `Model` with a real local provider —
//! and answers the three things the seam allows: apply a fenced intent,
//! serialize a snapshot, announce that state moved. Nothing else crosses.
//!
//! Two counters carry the ordering contract. `sequence` advances on every
//! announcement, applied or refused, so the core can detect a gap in what it
//! heard. `revision` advances only when state actually changed; every
//! positional intent names the revision it was computed against, and one
//! computed against an older revision is refused rather than applied to tabs
//! that may have moved underneath it. That refusal is itself state (bit 7 of
//! the snapshot flags), so the core can show it instead of guessing.

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_module = @import("../model.zig");
const support = @import("../phux_support.zig");
const layout = @import("../layout.zig");
const grid = @import("../../terminal/grid.zig");
const vt = @import("ghostty-vt");
const terminal_runtime = @import("../terminal_runtime.zig");
const projection = @import("workspace_projection.zig");
const view = @import("view.zig");
const protocol = @import("ts_protocol.zig");
const ts_snapshot = @import("ts_snapshot.zig");
const theme_module = @import("../../config/theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Model = model_module.Model;
const TerminalRef = support.TerminalRef;
const max_terminals = model_module.max_terminals;

/// What the engine asks of an effects instance. Both this app's own
/// `TerminalApp.Effects` and the TypeScript adapter's satisfy it; tests
/// that want no processes pass `NoShells`.
pub const NoShells = struct {
    pub fn hostSend(_: *const NoShells, _: []const u8, _: []const u8) void {}
    pub fn ptySpawn(_: *const NoShells, _: anytype) void {}
    pub fn ptyWrite(_: *const NoShells, _: u64, _: []const u8) bool {
        return false;
    }
    pub fn ptyResize(_: *const NoShells, _: u64, _: u16, _: u16) void {}
    pub fn ptyKill(_: *const NoShells, _: u64) void {}
};

/// Snapshot flag bit reserved for the engine: the last intent was refused
/// because it named a revision the engine had already moved past (or could
/// not be decoded at all). Bits 0..6 belong to `ts_snapshot.snapshotFlags`.
pub const intent_refused_flag: u8 = 1 << 7;

pub const Engine = struct {
    model: *Model,
    sequence: u64 = 0,
    revision: u64 = 1,
    intent_refused: bool = false,
    /// The pty key each registry slot was last spawned for, so `spawnShells`
    /// is idempotent across frames and a reused slot spawns again.
    spawned_keys: [max_terminals]u64 = [_]u64{0} ** max_terminals,
    /// The run the last snapshot carried. A frame that changes it (a resize,
    /// a placement flip) is announced like an intent, because the core's
    /// chrome is wrong until it resyncs.
    last_run: ts_snapshot.TabRun = .{},
    /// The config file's state as of the last `probe_config` intent.
    config_probe: ts_snapshot.ConfigProbe = .{},

    /// The model is multi-MB and lives on the heap for the process lifetime;
    /// `gpa` sizes the emulator sessions the provider mints, `io` is what the
    /// provider spawns through later. The first terminal exists from birth,
    /// exactly as the shipping app boots.
    pub fn create(gpa: std.mem.Allocator, io: std.Io) !*Engine {
        const session = try grid.Session.create(gpa, io, 80, 24);
        errdefer session.destroy();
        const model = try std.heap.page_allocator.create(Model);
        errdefer std.heap.page_allocator.destroy(model);
        model.* = try model_module.initialModelWithIo(gpa, io, session);
        const engine = try std.heap.page_allocator.create(Engine);
        engine.* = .{ .model = model };
        return engine;
    }

    pub fn destroy(self: *Engine) void {
        model_module.deinitModel(self.model);
        std.heap.page_allocator.destroy(self.model);
        std.heap.page_allocator.destroy(self);
    }

    /// Apply one wire intent. Returns whether state changed. Sequence always
    /// advances so the caller announces every outcome, including a refusal:
    /// a core that sent a stale intent must learn that it is stale. `fx`
    /// receives the pty consequences (a closed tab's shells are killed).
    pub fn applyIntent(self: *Engine, bytes: []const u8, fx: anytype) bool {
        self.sequence +%= 1;
        const intent = protocol.decodeIntent(bytes) orelse return self.refuse();
        if (intent.expected_revision != self.revision) return self.refuse();
        const changed = switch (intent.kind) {
            .select_tab => self.model.selectTab(intent.argument),
            .new_terminal => self.newTerminal(),
            .close_tab => self.closeTab(intent.argument, fx),
            .set_tab_placement => self.setPlacement(intent.argument),
            .set_theme => self.setTheme(intent.argument),
            .reveal_config => self.revealConfig(fx),
            .probe_config => self.probeConfig(),
        };
        if (!changed) return self.refuse();
        self.intent_refused = false;
        self.revision +%= 1;
        return true;
    }

    fn refuse(self: *Engine) bool {
        self.intent_refused = true;
        return false;
    }

    /// Mirrors `update.zig`'s `.new_terminal` transaction. The shell itself
    /// is spawned by the next `spawnShells`, which the extension runs after
    /// every intent and every frame; the pane exists and is selected first,
    /// exactly as in the shipping app. Refusals stay visible through the
    /// same model flags the shipping app uses.
    fn newTerminal(self: *Engine) bool {
        const model = self.model;
        const pane = model.provider.createTerminal() catch {
            model.terminal_limit_refused = true;
            return false;
        };
        if (!model.admitTab(pane.id)) {
            _ = model.provider.destroyTerminal(pane.id);
            model.ws().tab_limit_refused = true;
            return false;
        }
        _ = model.selectTerminal(pane.id);
        model.terminal_limit_refused = false;
        model.ws().tab_limit_refused = false;
        return true;
    }

    /// The last tab is never closed here: in the shipping app that closes
    /// the window, and window lifecycle is not this seam's to decide.
    fn closeTab(self: *Engine, index: u8, fx: anytype) bool {
        const model = self.model;
        const workspace = model.wsConst();
        if (workspace.tab_count <= 1) return false;
        const tree = workspace.treeConst(index) orelse return false;
        var refs: [layout.max_panes]TerminalRef = undefined;
        const count = tree.terminals(&refs);
        model.dropTab(index);
        for (refs[0..count]) |id| {
            if (model.provider.terminal(id)) |pane| fx.ptyKill(pane.pty_key);
            _ = model.provider.destroyTerminal(id);
        }
        return true;
    }

    /// The settings surface's Save: mirrors update.zig's .settings_commit,
    /// including the write and its refusal flag, minus the preview/restore
    /// dance the core keeps to itself.
    fn setTheme(self: *Engine, index: u8) bool {
        if (index >= theme_module.builtins.len) return false;
        const model = self.model;
        if (!model.config.setTheme(theme_module.builtins[index].name)) return false;
        switch (model.writeConfigTheme(model.provider.io)) {
            .written => model.config_write_refused = false,
            .refused => model.config_write_refused = true,
            .no_destination => {},
        }
        return true;
    }

    fn revealConfig(self: *Engine, fx: anytype) bool {
        const model = self.model;
        if (!model.config_file.enabled() or !self.config_probe.exists) return false;
        fx.hostSend("native-sdk.os.revealPath", model.config_file.path());
        return true;
    }

    /// Asked once, when the surface opens, exactly as the shipping app asks:
    /// a view is pure and must not touch a disk, and the answer only has to
    /// be true at the moment the person reads the line.
    fn probeConfig(self: *Engine) bool {
        const model = self.model;
        self.config_probe = .{
            .exists = model.configFileExists(model.provider.io),
            .writable = model.configFileWritable(model.provider.io),
            .probed = true,
        };
        return true;
    }

    // ------------------------------------------------------------ shells

    /// Spawn a shell for every registered pane that does not have one, the
    /// way `update.initFx` does at boot. Idempotent: a slot keeps its shell
    /// until the pane is destroyed, and a reused slot carries a new pty key.
    pub fn spawnShells(self: *Engine, fx: anytype, on_event: anytype) void {
        const model = self.model;
        for (0..max_terminals) |index| {
            if (model.provider.states[index] != .active) {
                self.spawned_keys[index] = 0;
                continue;
            }
            const pane = model.provider.slot(index);
            if (self.spawned_keys[index] == pane.pty_key) continue;
            terminal_runtime.spawnPane(pane, fx, on_event);
            model_module.applySessionConfig(&model.config, pane.session);
            self.spawned_keys[index] = pane.pty_key;
        }
    }

    /// One pty event, applied the way `update.zig`'s `.shell` arm applies it
    /// minus the bell, pointer-protocol and selection bookkeeping that belong
    /// to chrome this graph does not paint natively yet. `event.bytes` is
    /// drain scratch: the emulator is fed inside this call.
    pub fn onShellEvent(self: *Engine, fx: anytype, event: native_sdk.EffectPtyEvent) void {
        const pane = terminal_runtime.paneForKey(self.model, event.key) orelse return;
        switch (event.kind) {
            .output => {
                pane.phase = .live;
                pane.output_batches += 1;
                pane.output_bytes += event.bytes.len;
                terminal_runtime.feedOutput(pane, fx, event.bytes);
                pane.session.refreshScreenText();
                terminal_runtime.flushOutbound(pane, fx);
                terminal_runtime.moveResponsesToOutbound(pane, fx);
            },
            .exit => {
                pane.phase = if (event.reason == .rejected or event.reason == .spawn_failed) .failed else .ended;
                pane.exit_code = event.code;
                pane.exit_signal = event.signal;
                pane.exit_reason = event.reason;
            },
            // Write acknowledgements never reach a pty event constructor;
            // the shipping app marks the arm unreachable for the same reason.
            .write => {},
        }
    }

    // ------------------------------------------------------------- input

    /// A key that no chrome widget claimed goes to the focused pane's
    /// emulator encoder, which is the only thing that knows the live modes
    /// (kitty event reporting, application cursor keys) the bytes depend on.
    pub fn onKey(self: *Engine, fx: anytype, event: canvas.WidgetKeyboardEvent) void {
        const pane = self.focusedPane() orelse return;
        const action: vt.input.KeyAction = if (event.phase == .key_up) .release else .press;
        terminal_runtime.encodeKeyEvent(pane, fx, event, action);
    }

    pub fn onText(self: *Engine, fx: anytype, event: canvas.WidgetKeyboardEvent) void {
        const pane = self.focusedPane() orelse return;
        if (event.text.len == 0) return;
        terminal_runtime.sendCommittedText(pane, fx, event.text);
    }

    fn focusedPane(self: *Engine) ?*model_module.Pane {
        const terminal_ref = self.model.focusedTerminalRef() orelse return null;
        return self.model.provider.terminal(terminal_ref);
    }

    // ------------------------------------------------------------- frames

    /// The resize pump: converge every pane of the main window on the grid
    /// the painter measured, and tell each child. The same derivation the
    /// shipping app's frame pump uses (`proposedViewportsIn`), so the painter,
    /// the hit tests and the pty never disagree about a pane's cells.
    pub fn pumpViewports(self: *Engine, fx: anytype, frame: native_sdk.platform.GpuFrame) void {
        if (frame.size.width <= 0 or frame.size.height <= 0) return;
        const model = self.model;
        const workspace = model.ws();
        workspace.surface_size = frame.size;
        if (frame.scale_factor > 0) workspace.surface_scale_factor = frame.scale_factor;
        const proposals = projection.proposedViewportsIn(model, workspace, frame.size);
        for (proposals.slice()) |proposal| {
            const pane = model.provider.terminal(proposal.terminal) orelse continue;
            if (pane.cols == proposal.cols and pane.rows == proposal.rows) continue;
            if (!pane.session.resize(proposal.cols, proposal.rows)) continue;
            pane.cols = proposal.cols;
            pane.rows = proposal.rows;
            pane.session.refreshScreenText();
            fx.ptyResize(pane.pty_key, proposal.cols, proposal.rows);
        }
    }

    /// Paint the main window's grids beneath the markup chrome: the shipping
    /// painter, unchanged, on this engine's model. Markup owns the strip or
    /// rail above; the grids take the rest, sized by the same geometry.
    pub fn paint(self: *const Engine, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
        return view.buildChrome(self.model, builder, size, tokens);
    }

    fn setPlacement(self: *Engine, argument: u8) bool {
        const placement: model_module.TabPlacement = if (argument == 1) .side else .top;
        if (self.model.tab_placement == placement) return false;
        self.model.tab_placement = placement;
        return true;
    }

    pub fn snapshot(self: *Engine, out: []u8) ts_snapshot.Error![]const u8 {
        self.last_run = self.currentRun();
        const bytes = ts_snapshot.encode(self.model, self.sequence, self.revision, self.last_run, self.config_probe, out);
        if (self.intent_refused) out[22] |= intent_refused_flag;
        return bytes;
    }

    /// The tabs the band has room for, by the shipping projection's rule. The
    /// strip hands `visibleTabRun` the width the markup leaves it: the surface
    /// minus the traffic-light spacer and the row padding (app.native's own
    /// numbers). The rail is rows of 32pt in the height its own furniture
    /// leaves (an 8pt padding, a 40pt header, four 8pt gaps, three 28pt
    /// rows), with a 40pt cue reserved once anything is hidden. Before the
    /// first frame the surface is unknown and every tab is in the run.
    pub fn currentRun(self: *const Engine) ts_snapshot.TabRun {
        const workspace = self.model.wsConst();
        const total = workspace.tab_count;
        if (total == 0) return .{};
        const size = workspace.surface_size;
        if (size.width <= 0 or size.height <= 0) return .{ .first = 0, .count = @intCast(total), .extent = 168 };
        if (self.model.tab_placement == .top) {
            const run_width = projection.tabRunWidthIn(self.model, workspace, size.width - 78 - 8);
            const window = projection.visibleTabRun(workspace, run_width);
            return .{
                .first = @intCast(window.first),
                .count = @intCast(window.count),
                .extent = @intFromFloat(@max(0, @min(65535, window.extent))),
            };
        }
        const row: f32 = 32;
        const furniture: f32 = 8 + 40 + 32 + 84;
        const usable = @max(row, size.height - furniture);
        var count: usize = @max(1, @as(usize, @intFromFloat(@floor(usable / row))));
        if (count < total) {
            const cued = @max(row, usable - 40);
            count = @max(1, @as(usize, @intFromFloat(@floor(cued / row))));
        }
        count = @min(count, total);
        const selected = @min(workspace.selected_tab, total - 1);
        const first: usize = if (selected >= count) selected - count + 1 else 0;
        return .{ .first = @intCast(first), .count = @intCast(count), .extent = 168 };
    }

    /// Re-derive the run after a frame; true when it moved, in which case
    /// the caller announces so the core resyncs. Sequence advances then too:
    /// it counts announcements, and this is one.
    pub fn refreshRun(self: *Engine) bool {
        const run = self.currentRun();
        if (run.first == self.last_run.first and run.count == self.last_run.count and run.extent == self.last_run.extent) return false;
        self.last_run = run;
        self.sequence +%= 1;
        return true;
    }

    pub fn invalidation(self: *const Engine) [protocol.invalidation_len]u8 {
        return protocol.encodeInvalidation(self.sequence, self.revision);
    }
};
