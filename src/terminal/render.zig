//! Shared retained-canvas paint seam for local and provider-projected grids.

const native_sdk = @import("native_sdk");
const session_module = @import("session.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Session = session_module.Session;

const grid_id_base: u64 = 0x7e21;

/// The caller id for pane `index`. The framework applies its own retained-ID
/// stride, so each pane needs only a distinct small caller id.
pub fn paneIdBase(index: usize) u64 {
    return grid_id_base + index;
}

pub fn cursorCommandId(id_base: u64) u64 {
    return canvas.terminal_grid.paintIdBase(id_base) +% 0x61_0002;
}

pub const cursor_command_id: u64 = cursorCommandId(grid_id_base);

pub const PaintOptions = struct {
    frame: geometry.RectF,
    tokens: canvas.DesignTokens,
    running: bool,
    focused: bool = true,
    selecting: bool,
    /// Zero leaves the corresponding painter budget unbounded.
    command_budget: usize = 0,
    text_reserve: usize = 0,
    background_frame: ?geometry.RectF = null,
    glyph_budget: usize = 0,
    path_reserve: usize = 0,
    /// Use `paneIdBase` for multiple grids in one retained view.
    id_base: u64 = grid_id_base,
};

/// Project and paint one local emulator session through the shared painter.
pub fn paint(session: *Session, builder: *canvas.Builder, options: PaintOptions) !void {
    const metrics = canvas.terminalCellMetrics(options.tokens);
    session.font_size = metrics.font_size;
    session.cell_width = metrics.width;
    session.cell_height = metrics.height;

    const snap = try session.snapshot(options.tokens, options.running, options.selecting);
    try paintTerminalGrid(snap, builder, options);
}

/// Paint an already-projected provider grid with the same budgets and retained
/// identity behavior as a local session.
pub fn paintTerminalGrid(terminal_grid: canvas.TerminalGrid, builder: *canvas.Builder, options: PaintOptions) !void {
    try canvas.terminal_grid.paint(terminal_grid, builder, .{
        .frame = options.frame,
        .tokens = options.tokens,
        .focused = options.focused,
        .background_frame = options.background_frame,
        .id_base = options.id_base,
        .command_budget = options.command_budget,
        .text_reserve = options.text_reserve,
        .path_reserve = options.path_reserve,
        .glyph_budget = options.glyph_budget,
    });
}
