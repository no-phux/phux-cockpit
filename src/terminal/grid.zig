//! Compatibility facade for terminal session, projection, and painting seams.

const session = @import("session.zig");
const render = @import("render.zig");

pub const max_cols = session.max_cols;
pub const max_rows = session.max_rows;
pub const max_cells = session.max_cells;
pub const snapshot_text_capacity = session.snapshot_text_capacity;
pub const Session = session.Session;

pub const PaintOptions = render.PaintOptions;
pub const paneIdBase = render.paneIdBase;
pub const cursorCommandId = render.cursorCommandId;
pub const cellGridCommandId = render.cellGridCommandId;
pub const cursor_command_id = render.cursor_command_id;
pub const paint = render.paint;
pub const paintTerminalGrid = render.paintTerminalGrid;
