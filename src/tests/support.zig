const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

pub const TerminalApp = native_sdk.UiApp(app.Model, app.Msg);

pub fn createSession(cols: u16, rows: u16) !*grid.Session {
    return grid.Session.create(std.heap.page_allocator, testing.io, cols, rows);
}

/// The app now opens with exactly ONE terminal and mints the rest lazily, so
/// the fixtures hand over one session and ask the model for more.
pub fn createDefaultSession() !*grid.Session {
    return grid.Session.create(testing.allocator, testing.io, 80, 24);
}

/// A bare pair of emulators for tests that paint or feed sessions directly,
/// with no model or provider involved.
pub fn createSessions(cols: u16, rows: u16) ![2]*grid.Session {
    var sessions: [2]*grid.Session = undefined;
    var created: usize = 0;
    errdefer for (sessions[0..created]) |session| session.destroy();
    while (created < sessions.len) : (created += 1) {
        sessions[created] = try createSession(cols, rows);
    }
    return sessions;
}

/// The registry's live panes, as a slice. Valid only while no slot has been
/// freed, which holds for fixtures that only ever ADD terminals — a closed
/// terminal leaves a hole whose session is gone.
pub fn activeSlots(model: *app.Model) []app.Pane {
    var end: usize = 0;
    for (model.provider.states, 0..) |state, index| {
        if (state == .active) end = index + 1;
    }
    return model.provider.slots[0..end];
}

pub fn remoteTerminalRef(id: u32) !app.TerminalRef {
    return .{
        .provider_id = .phux,
        .terminal_id = .{ .phux = try app.RemoteTerminalId.fromPhux(0, id, "local") },
    };
}

// --------------------------------------------------------- cell grids
//
// A terminal screen is now ONE display-list command: `cell_grid`, a
// packed cols x rows lattice of 20-byte cells, each carrying its own
// background, cluster (an offset into the grid's interned byte pool),
// foreground, underline colour, and style bits. Every renderer expands
// the lattice itself.
//
// What that means for a TEST: there are no per-run `fill_rect` /
// `draw_text` commands for terminal CONTENT any more, so a test that
// wants to know what reached the glass reads CELLS. It also means a
// screen costs a CONSTANT number of commands (surface fill, clip push,
// the grid, the cursor, clip pop) whatever it contains — command counts
// no longer measure content, and cells and painted rows do.
//
// Everything below is that one seam. No test decodes a cell by hand.

/// One `cell_grid` command, with lookup by (col, row).
pub const CellGridView = struct {
    grid: canvas.CellGrid,

    pub fn cols(self: CellGridView) usize {
        return self.grid.cols;
    }

    /// Rows the painter actually PUT on the glass. The painter emits the
    /// lattice at its painted height, so this is the migrated form of
    /// "how many distinct text baselines did the paint produce".
    pub fn rows(self: CellGridView) usize {
        return self.grid.rows;
    }

    pub fn cellCount(self: CellGridView) usize {
        return self.grid.cellCount();
    }

    pub fn at(self: CellGridView, x: usize, y: usize) ?canvas.Cell {
        return self.grid.at(x, y);
    }

    /// The rect cell (x, y) covers — geometry is implied by the INDEX
    /// now, so a cell's position can no longer drift with its face.
    pub fn cellRect(self: CellGridView, x: usize, y: usize) geometry.RectF {
        return self.grid.cellRect(x, y);
    }

    /// The cell's grapheme cluster bytes; empty for a cell that inks
    /// nothing (a blank, a wide cell's spacer, a box-drawing cell whose
    /// ink is geometry).
    pub fn cluster(self: CellGridView, x: usize, y: usize) []const u8 {
        const cell = self.grid.at(x, y) orelse return "";
        return cell.cluster(self.grid.text);
    }

    pub fn style(self: CellGridView, x: usize, y: usize) ?canvas.CellFlags {
        const cell = self.grid.at(x, y) orelse return null;
        return cell.style();
    }

    /// The cell's resolved foreground, at the terminal's own 8-bit
    /// precision.
    pub fn foreground(self: CellGridView, x: usize, y: usize) ?canvas.CellColor {
        const cell = self.grid.at(x, y) orelse return null;
        return cell.fg;
    }

    /// The cell's own background, or null when it paints none and the
    /// grid's surface shows through. The distinction is load-bearing:
    /// `has_background` is what says a cell painted a background at all.
    pub fn background(self: CellGridView, x: usize, y: usize) ?canvas.CellColor {
        const cell = self.grid.at(x, y) orelse return null;
        if (!cell.style().has_background) return null;
        return cell.bg;
    }

    /// The cell's SGR 58 underline colour, or null when it named none
    /// and the underline takes the cell foreground. `has_underline_color`
    /// is what says the cell carried one at all, exactly as
    /// `has_background` does for the background — the stored colour is
    /// zeroed, not absent, so reading the field alone would report opaque
    /// black for every cell that never set one.
    pub fn underlineColor(self: CellGridView, x: usize, y: usize) ?canvas.CellColor {
        const cell = self.grid.at(x, y) orelse return null;
        if (!cell.style().has_underline_color) return null;
        return cell.underline_color;
    }

    /// Row `y` as a renderer would ink it: every cell's cluster bytes,
    /// left to right. Cells that ink nothing contribute nothing, so a
    /// row's trailing blanks never reach the string.
    pub fn rowText(self: CellGridView, y: usize, out: []u8) []const u8 {
        var len: usize = 0;
        var x: usize = 0;
        while (x < self.grid.cols) : (x += 1) {
            const bytes = self.cluster(x, y);
            if (len + bytes.len > out.len) break;
            @memcpy(out[len..][0..bytes.len], bytes);
            len += bytes.len;
        }
        return out[0..len];
    }

    /// Where `needle` starts in the grid, scanning rows top to bottom —
    /// the column of the first CELL whose cluster begins the match.
    /// Null when no row carries it.
    pub fn find(self: CellGridView, needle: []const u8) ?CellPos {
        var y: usize = 0;
        while (y < self.grid.rows) : (y += 1) {
            if (self.findInRow(y, needle)) |x| return .{ .x = x, .y = y };
        }
        return null;
    }

    /// Where `needle` starts in row `y`, as a COLUMN. Built by walking
    /// the row's clusters and remembering which column each byte came
    /// from, so a multi-byte or multi-cell match still reports the cell
    /// it began in.
    pub fn findInRow(self: CellGridView, y: usize, needle: []const u8) ?usize {
        if (needle.len == 0) return null;
        var text: [row_text_capacity]u8 = undefined;
        var columns: [row_text_capacity]u16 = undefined;
        var len: usize = 0;
        var x: usize = 0;
        while (x < self.grid.cols) : (x += 1) {
            const bytes = self.cluster(x, y);
            if (len + bytes.len > text.len) break;
            for (bytes, 0..) |byte, offset| {
                text[len + offset] = byte;
                columns[len + offset] = @intCast(x);
            }
            len += bytes.len;
        }
        const hit = std.mem.indexOf(u8, text[0..len], needle) orelse return null;
        return columns[hit];
    }

    /// Cells that put ink on the glass — a cluster, an underline, a
    /// strikethrough, or an overline. The migrated measure of "this
    /// terminal genuinely painted content", now that a screen's command
    /// count is a constant.
    pub fn inkedCells(self: CellGridView) usize {
        var total: usize = 0;
        var y: usize = 0;
        while (y < self.grid.rows) : (y += 1) {
            var x: usize = 0;
            while (x < self.grid.cols) : (x += 1) {
                const cell = self.grid.at(x, y) orelse continue;
                if (cell.hasInk()) total += 1;
            }
        }
        return total;
    }
};

pub const CellPos = struct { x: usize, y: usize };

/// A row's cluster bytes can exceed one byte per column (combining
/// marks, wide clusters); sized well past `terminal_grid.max_cols` so a
/// dense row still resolves whole.
const row_text_capacity = 8192;

/// The first `cell_grid` command in a display list — the shape a
/// single-terminal paint produces.
pub fn findCellGrid(display_list: anytype) ?CellGridView {
    for (display_list.commands) |command| {
        if (command == .cell_grid) return .{ .grid = command.cell_grid };
    }
    return null;
}

pub fn expectCellGrid(display_list: anytype) !CellGridView {
    return findCellGrid(display_list) orelse error.TestExpectedCellGrid;
}

/// The grid belonging to pane `index`, by the painter's own command id.
/// A split emits one grid per pane, so tests that care WHICH terminal
/// they are reading go through here rather than taking the first.
pub fn findPaneCellGrid(display_list: anytype, index: usize) ?CellGridView {
    const id = grid.cellGridCommandId(grid.paneIdBase(index));
    const command = display_list.findCommandById(id) orelse return null;
    if (command.command != .cell_grid) return null;
    return .{ .grid = command.command.cell_grid };
}

pub fn expectPaneCellGrid(display_list: anytype, index: usize) !CellGridView {
    return findPaneCellGrid(display_list, index) orelse error.TestExpectedCellGrid;
}

/// Every `cell_grid` in the list, in emission order.
pub fn collectCellGrids(display_list: anytype, out: []CellGridView) []CellGridView {
    var count: usize = 0;
    for (display_list.commands) |command| {
        if (command != .cell_grid) continue;
        if (count == out.len) break;
        out[count] = .{ .grid = command.cell_grid };
        count += 1;
    }
    return out[0..count];
}

pub const CursorPaintKind = enum { filled, hollow };

pub fn expectCursorPaintKind(display_list: anytype, expected: CursorPaintKind) !void {
    return expectPaneCursorPaintKind(display_list, 0, expected);
}

pub fn expectPaneCursorPaintKind(display_list: anytype, index: usize, expected: CursorPaintKind) !void {
    const id = grid.cursorCommandId(grid.paneIdBase(index));
    const command = display_list.findCommandById(id) orelse return error.TestExpectedCursor;
    switch (command.command) {
        .fill_rect => try testing.expectEqual(CursorPaintKind.filled, expected),
        .stroke_rect => try testing.expectEqual(CursorPaintKind.hollow, expected),
        else => return error.TestUnexpectedCursorCommand,
    }
}

/// Build a `TerminalApp` DIRECTLY into caller-owned storage.
///
/// `TerminalApp` is ~4.5 MB by value, and a debug build materialises a
/// returned aggregate as a temporary in the CALLER's frame that then
/// lives for the rest of that function — so every fixture that wrote
/// `app_state.* = TerminalApp.init(...)` inline was carrying 4.5 MB of
/// dead stack through its whole body, and a fixture that also built one
/// other multi-megabyte value carried both at once.
///
/// That never mattered until the packed cell grid landed: `canvas.Builder`
/// now embeds a 32k-cell store (640 KB), and the SDK's chrome installer
/// holds TWO builders plus two per-view command arrays on one frame,
/// ~4.1 MB. Deep fixtures plus that frame overran the 16 MB main-thread
/// stack. Constructing in a LEAF helper keeps the temporary in a frame
/// that pops immediately, which is the difference between ~9 MB of live
/// stack at the deepest point and ~17 MB.
pub fn initTerminalApp(slot: *TerminalApp, session: *grid.Session) void {
    slot.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(session), app.appOptions());
}

pub fn startFocusedTerminal(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const session = try createSession(80, 24);
    const app_state = gpa.create(TerminalApp) catch |err| {
        session.destroy();
        return err;
    };
    initTerminalApp(app_state, session);
    errdefer {
        app_state.deinit();
        app.deinitModel(&app_state.model);
        gpa.destroy(app_state);
    }
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    return app_state;
}

/// Two TABS, each with one terminal — the shape most routing tests want.
/// The second terminal is minted through the real `new_terminal` path, so
/// the fixture exercises lazy session allocation instead of pre-seeding it.
pub fn startTwoPaneCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    const app_state = try startFocusedTerminal(gpa, harness);
    errdefer {
        app_state.deinit();
        app.deinitModel(&app_state.model);
        gpa.destroy(app_state);
    }
    const app_iface = app_state.app();
    try app_state.dispatch(&harness.runtime, 1, .new_terminal);
    try app_state.dispatch(&harness.runtime, 1, .{ .select_position = 0 });
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    // Land canvas widget focus on the selected terminal AFTER the tab list
    // settled: a rebuild between the click and the assertion clears it.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    return app_state;
}

/// Two PANES in ONE tab, produced by a real split. `PANEALPHA` is the
/// original (left/top), `PANEBRAVO` the pane the split created.
pub fn startSplitCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    const app_state = try startFocusedTerminal(gpa, harness);
    errdefer {
        app_state.deinit();
        app.deinitModel(&app_state.model);
        gpa.destroy(app_state);
    }
    const app_iface = app_state.app();
    try app_state.dispatch(&harness.runtime, 1, .split_right);
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    return app_state;
}

/// The pane rects the painter, the hit targets, and the PTY pump all use.
pub fn resolvedPanes(model: *const app.Model, size: geometry.SizeF, out: []app.LayoutPane) usize {
    return app.resolvePanes(model, size, out);
}

pub fn paneRect(model: *const app.Model, size: geometry.SizeF, terminal_ref: app.TerminalRef) ?geometry.RectF {
    return app.paneFrameFor(model, size, terminal_ref);
}

pub fn startCockpit(harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const session = try createDefaultSession();
    const model = app.initialModelWithIo(testing.allocator, testing.io, session) catch |err| {
        session.destroy();
        return err;
    };
    const state = testing.allocator.create(TerminalApp) catch |err| {
        var owned_model = model;
        app.deinitModel(&owned_model);
        return err;
    };
    state.* = TerminalApp.init(std.heap.page_allocator, model, app.appOptions());
    errdefer stopCockpit(state);
    state.effects.executor = .fake;
    try harness.start(state.app());
    try dispatchInitialFrame(harness, state.app());
    return state;
}

pub fn startProductionCockpit(harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const session = try grid.Session.create(testing.allocator, testing.io, 80, 24);
    const model = app.initialProductionModelWithIo(testing.allocator, testing.io, session) catch |err| {
        session.destroy();
        return err;
    };
    const state = testing.allocator.create(TerminalApp) catch |err| {
        var owned_model = model;
        app.deinitModel(&owned_model);
        return err;
    };
    state.* = TerminalApp.init(std.heap.page_allocator, model, app.appOptions());
    errdefer stopCockpit(state);
    state.effects.executor = .fake;
    try harness.start(state.app());
    try dispatchInitialFrame(harness, state.app());
    return state;
}

fn dispatchInitialFrame(harness: anytype, app_iface: native_sdk.App) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
}

pub fn stopCockpit(state: *TerminalApp) void {
    state.deinit();
    app.deinitModel(&state.model);
    testing.allocator.destroy(state);
}

pub fn clickCanvas(harness: anytype, app_iface: anytype, x: f32, y: f32) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = x,
        .y = y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_up,
        .x = x,
        .y = y,
    } });
}

pub fn typeCanvasText(harness: anytype, app_iface: anytype, text: []const u8) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .text_input,
        .text = text,
    } });
}

pub fn pressCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = key,
        .modifiers = modifiers,
    } });
}

pub fn releaseCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = key,
        .modifiers = modifiers,
    } });
}

pub fn terminalInteractionFrame(harness: anytype, marker: []const u8) ?geometry.RectF {
    const layout = harness.runtime.views[0].widgetLayoutTree();
    for (layout.nodes) |node| {
        if (node.widget.kind != .terminal) continue;
        if (std.mem.indexOf(u8, node.widget.text, marker) == null) continue;
        return node.frame;
    }
    return null;
}

pub fn widgetFrameBySemantics(harness: anytype, label: []const u8) ?geometry.RectF {
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.frame;
    }
    return null;
}

pub fn rectCenter(rect: geometry.RectF) geometry.PointF {
    return geometry.PointF.init(rect.x + rect.width / 2, rect.y + rect.height / 2);
}

/// A terminal's text reached the glass INSIDE `frame`.
///
/// Same two claims as before the cell grid landed — the marker is on
/// screen, and it is horizontally inside the pane that owns it — read
/// off cells instead of `draw_text` runs. The x check is now exact
/// rather than approximate: a cell's rect comes from its INDEX, so this
/// pins the column the marker actually occupies, not where a text run
/// happened to start.
pub fn expectDisplayListMarker(display_list: anytype, marker: []const u8, frame: geometry.RectF) !void {
    var grids: [max_cell_grids]CellGridView = undefined;
    for (collectCellGrids(display_list, &grids)) |view| {
        const at = view.find(marker) orelse continue;
        const rect = view.cellRect(at.x, at.y);
        try testing.expect(rect.x >= frame.x);
        try testing.expect(rect.x < frame.x + frame.width);
        try testing.expect(rect.x + rect.width <= frame.x + frame.width + 0.5);
        return;
    }
    return error.TestExpectedMarker;
}

/// No terminal on this frame carries `marker` — the hidden-pane claim.
pub fn expectDisplayListMissingMarker(display_list: anytype, marker: []const u8) !void {
    var grids: [max_cell_grids]CellGridView = undefined;
    for (collectCellGrids(display_list, &grids)) |view| {
        try testing.expect(view.find(marker) == null);
    }
}

/// Grids one frame can hold: one per pane, with slack.
const max_cell_grids = 16;
