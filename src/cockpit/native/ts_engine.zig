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
const model_module = @import("../model.zig");
const support = @import("../phux_support.zig");
const layout = @import("../layout.zig");
const grid = @import("../../terminal/grid.zig");
const protocol = @import("ts_protocol.zig");
const ts_snapshot = @import("ts_snapshot.zig");

const Model = model_module.Model;
const TerminalRef = support.TerminalRef;

/// Snapshot flag bit reserved for the engine: the last intent was refused
/// because it named a revision the engine had already moved past (or could
/// not be decoded at all). Bits 0..6 belong to `ts_snapshot.snapshotFlags`.
pub const intent_refused_flag: u8 = 1 << 7;

pub const Engine = struct {
    model: *Model,
    sequence: u64 = 0,
    revision: u64 = 1,
    intent_refused: bool = false,

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
    /// a core that sent a stale intent must learn that it is stale.
    pub fn applyIntent(self: *Engine, bytes: []const u8) bool {
        self.sequence +%= 1;
        const intent = protocol.decodeIntent(bytes) orelse return self.refuse();
        if (intent.expected_revision != self.revision) return self.refuse();
        const changed = switch (intent.kind) {
            .select_tab => self.model.selectTab(intent.argument),
            .new_terminal => self.newTerminal(),
            .close_tab => self.closeTab(intent.argument),
            .set_tab_placement => self.setPlacement(intent.argument),
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

    /// Mirrors `update.zig`'s `.new_terminal` transaction minus the PTY
    /// spawn, which is an effect this engine does not yet own (the terminal
    /// pixel path is the next seam). Refusals stay visible through the same
    /// model flags the shipping app uses.
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
    fn closeTab(self: *Engine, index: u8) bool {
        const model = self.model;
        const workspace = model.wsConst();
        if (workspace.tab_count <= 1) return false;
        const tree = workspace.treeConst(index) orelse return false;
        var refs: [layout.max_panes]TerminalRef = undefined;
        const count = tree.terminals(&refs);
        model.dropTab(index);
        for (refs[0..count]) |id| _ = model.provider.destroyTerminal(id);
        return true;
    }

    fn setPlacement(self: *Engine, argument: u8) bool {
        const placement: model_module.TabPlacement = if (argument == 1) .side else .top;
        if (self.model.tab_placement == placement) return false;
        self.model.tab_placement = placement;
        return true;
    }

    pub fn snapshot(self: *const Engine, out: []u8) ts_snapshot.Error![]const u8 {
        const bytes = ts_snapshot.encode(self.model, self.sequence, self.revision, out);
        if (self.intent_refused) out[22] |= intent_refused_flag;
        return bytes;
    }

    pub fn invalidation(self: *const Engine) [protocol.invalidation_len]u8 {
        return protocol.encodeInvalidation(self.sequence, self.revision);
    }
};
