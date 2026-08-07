//! Borrowed Phux C-grid translation into reusable canvas presentation buffers.

const std = @import("std");
const native_sdk = @import("native_sdk");
const c = @import("abi.zig").c;

const canvas = native_sdk.canvas;

/// Admission is bounded independently from one frame's text budget. The
/// painter degrades rows atomically while this store retains the complete valid
/// viewport instead of disconnecting on ordinary dense Unicode content.
pub const max_cell_utf8_bytes: usize = 64;
pub const max_grid_utf8_bytes: usize = canvas.max_terminal_cells * max_cell_utf8_bytes;

pub const CanvasStore = struct {
    cells: std.ArrayListUnmanaged(canvas.TerminalCell) = .empty,
    rows: std.ArrayListUnmanaged(canvas.TerminalRow) = .empty,
    utf8: std.ArrayListUnmanaged(u8) = .empty,
    screen_text: std.ArrayListUnmanaged(u8) = .empty,
    cursor: ?canvas.TerminalCursor = null,
    scrollbar: canvas.TerminalScrollbar = .{},
    selection_active: bool = false,

    pub fn deinit(store: *CanvasStore, gpa: std.mem.Allocator) void {
        store.cells.deinit(gpa);
        store.rows.deinit(gpa);
        store.utf8.deinit(gpa);
        store.screen_text.deinit(gpa);
    }

    fn reserve(store: *CanvasStore, gpa: std.mem.Allocator) !void {
        try store.utf8.ensureTotalCapacity(gpa, max_grid_utf8_bytes);
        try store.cells.ensureTotalCapacity(gpa, canvas.max_terminal_cells);
        try store.rows.ensureTotalCapacity(gpa, canvas.max_terminal_rows);
        try store.screen_text.ensureTotalCapacity(gpa, max_grid_utf8_bytes + canvas.max_terminal_rows);
    }

    pub fn copyBorrowed(store: *CanvasStore, gpa: std.mem.Allocator, view: *const c.PhuxTerminalGridView) !void {
        const cols: usize = view.cols;
        const rows: usize = view.rows;
        if (cols > canvas.max_terminal_cols or rows > canvas.max_terminal_rows) return error.Protocol;
        if (view.cell_count > canvas.max_terminal_cells or view.cell_count != cols * rows) return error.Protocol;
        if (view.cell_count != 0 and view.cells == null) return error.Protocol;
        if (view.utf8.len != 0 and view.utf8.data == null) return error.Protocol;
        const source_cells: []const c.PhuxTerminalCell = if (view.cell_count == 0) &.{} else view.cells[0..view.cell_count];
        const source_utf8 = view.utf8.data;
        var visible_utf8_len: usize = 0;
        const screen_text_limit = max_grid_utf8_bytes + canvas.max_terminal_rows;
        var screen_text_len: usize = if (rows == 0) 0 else rows - 1;
        for (source_cells) |raw| {
            const start: usize = raw.utf8_offset;
            const len: usize = raw.utf8_len;
            if (start > view.utf8.len or len > view.utf8.len - start) return error.Protocol;
            const cluster: []const u8 = if (len == 0) &.{} else source_utf8[start..][0..len];
            if (cluster.len != 0) _ = std.unicode.Utf8View.init(cluster) catch return error.Protocol;
            if (visible_utf8_len > max_grid_utf8_bytes or len > max_grid_utf8_bytes - visible_utf8_len) return error.Protocol;
            visible_utf8_len += len;
            if (screen_text_len > screen_text_limit or len > screen_text_limit - screen_text_len) return error.Protocol;
            screen_text_len += len;
        }
        if (screen_text_len > screen_text_limit) return error.Protocol;
        try store.reserve(gpa);
        store.utf8.clearRetainingCapacity();
        store.cells.items.len = view.cell_count;
        store.rows.items.len = rows;
        store.screen_text.clearRetainingCapacity();
        store.selection_active = false;

        for (store.cells.items, 0..) |*cell, index| {
            const raw = source_cells[index];
            const start: usize = raw.utf8_offset;
            const len: usize = raw.utf8_len;
            const source_cluster: []const u8 = if (len == 0) &.{} else source_utf8[start..][0..len];
            const compact_start = store.utf8.items.len;
            store.utf8.appendSliceAssumeCapacity(source_cluster);
            const cluster = store.utf8.items[compact_start..][0..len];
            const decoded: u21 = if (cluster.len == 0) 0 else firstCodepoint(cluster) catch return error.Protocol;
            var fg = canvas.Color.rgb8(raw.foreground_r, raw.foreground_g, raw.foreground_b);
            var bg = canvas.Color.rgb8(raw.background_r, raw.background_g, raw.background_b);
            if (raw.flags & c.PHUX_CLIENT_CELL_INVERSE != 0) std.mem.swap(canvas.Color, &fg, &bg);
            const invisible = raw.flags & c.PHUX_CLIENT_CELL_INVISIBLE != 0;
            const cp: u21 = if (invisible) 0 else decoded;
            cell.* = .{
                .cp = cp,
                .cluster = if (cp == 0 or canvas.terminal_box.isBoxDrawing(cp)) "" else cluster,
                .fg = fg,
                .bg = bg,
                .underline = raw.underline != c.PHUX_UNDERLINE_NONE,
                .wide = switch (raw.wide) {
                    c.PHUX_CELL_WIDE => .wide,
                    c.PHUX_CELL_SPACER_TAIL, c.PHUX_CELL_SPACER_HEAD => .spacer,
                    else => .narrow,
                },
            };
            store.selection_active = store.selection_active or raw.flags & c.PHUX_CLIENT_CELL_SELECTED != 0;
        }

        for (store.rows.items, 0..) |*row, row_index| {
            const first = row_index * cols;
            const last = first + cols;
            row.* = .{ .cells = store.cells.items[first..last] };
            var selected_first: ?u16 = null;
            var selected_last: u16 = 0;
            for (source_cells[first..last], 0..) |raw, col| {
                if (raw.flags & c.PHUX_CLIENT_CELL_SELECTED != 0) {
                    if (selected_first == null) selected_first = @intCast(col);
                    selected_last = @intCast(col);
                }
                const start: usize = raw.utf8_offset;
                const len: usize = raw.utf8_len;
                const source_cluster: []const u8 = if (len == 0) &.{} else source_utf8[start..][0..len];
                store.screen_text.appendSliceAssumeCapacity(source_cluster);
            }
            if (selected_first) |first_selected| row.selection = .{ first_selected, selected_last };
            if (row_index + 1 < rows) store.screen_text.appendAssumeCapacity('\n');
        }

        store.cursor = if (view.cursor_visible) .{
            .x = view.cursor_col,
            .y = view.cursor_row,
            .shape = switch (view.cursor_style) {
                c.PHUX_CURSOR_BAR => .bar,
                c.PHUX_CURSOR_UNDERLINE => .underline,
                else => .block,
            },
        } else null;
        store.scrollbar = .{
            .offset = saturatingU32(view.history_viewport_offset),
            .len = saturatingU32(view.history_visible_rows),
            .total = saturatingU32(view.history_total_rows),
        };
    }

    pub fn grid(store: *const CanvasStore, running: bool) canvas.TerminalGrid {
        return .{
            .rows = store.rows.items,
            .background = canvas.Color.rgb8(13, 17, 23),
            .foreground = canvas.Color.rgb8(230, 237, 243),
            .cursor_color = canvas.Color.rgb8(88, 166, 255),
            .selection_color = canvas.Color.rgb8(56, 139, 253),
            .cursor = store.cursor,
            .running = running,
            .scrollbar = store.scrollbar,
            .screen_text = store.screen_text.items,
            .selection_active = store.selection_active,
        };
    }
};

fn firstCodepoint(cluster: []const u8) !u21 {
    const sequence_len = try std.unicode.utf8ByteSequenceLength(cluster[0]);
    if (sequence_len > cluster.len) return error.InvalidUtf8;
    return std.unicode.utf8Decode(cluster[0..sequence_len]);
}

fn saturatingU32(value: u64) u32 {
    return @intCast(@min(value, @as(u64, std.math.maxInt(u32))));
}

test "dense text is compacted from a hyperlink-heavy remote UTF-8 arena" {
    // The claim is that the projection keeps every visible byte even when the
    // PAINTER's text store cannot carry them all, so the screen has to
    // genuinely outgrow that store or the test proves nothing. Both extents
    // are derived from the SDK's own constants rather than written down: a
    // fixed 120x96 stopped exceeding the budget the moment the store grew
    // from 32 KiB to 64 KiB, and the assertion below went quietly vacuous
    // until CI caught it.
    // Every cell here inks one three-byte euro sign. Note this is NOT
    // `max_cell_utf8_bytes` (64) — that is the per-cell CEILING a cluster may
    // reach, and sizing against it would ask for 20x fewer columns than the
    // fixture actually needs.
    const cell_utf8_bytes: usize = 3;
    const rows: usize = canvas.max_terminal_rows;
    const cols: usize = @min(
        canvas.max_terminal_cols,
        canvas.max_display_list_text_bytes / cell_utf8_bytes / rows + 2,
    );
    const cell_count = cols * rows;
    comptime {
        // The densest grid the projection accepts must still outgrow the
        // painter's store, or no choice of cols could make this test bite.
        std.debug.assert(canvas.max_terminal_cols * canvas.max_terminal_rows * cell_utf8_bytes >
            canvas.max_display_list_text_bytes);
    }
    const cells = try std.testing.allocator.alloc(c.PhuxTerminalCell, cell_count);
    defer std.testing.allocator.free(cells);
    const visible_len = cell_count * 3;
    const utf8 = try std.testing.allocator.alloc(u8, 65 * 1024 * 1024);
    defer std.testing.allocator.free(utf8);
    @memset(cells, std.mem.zeroes(c.PhuxTerminalCell));
    for (cells, 0..) |*cell, index| {
        const start = index * 3;
        @memcpy(utf8[start..][0..3], "\xe2\x82\xac");
        cell.utf8_offset = @intCast(start);
        cell.utf8_len = 3;
        cell.hyperlink_offset = @intCast(visible_len);
        cell.hyperlink_len = @intCast(utf8.len - visible_len);
    }
    @memcpy(utf8[0..3], "\xe2\x94\x80");
    try std.testing.expect(visible_len > canvas.max_display_list_text_bytes);
    try std.testing.expect(utf8.len > max_grid_utf8_bytes);

    var view = std.mem.zeroes(c.PhuxTerminalGridView);
    view.cols = cols;
    view.rows = rows;
    view.cells = cells.ptr;
    view.cell_count = cell_count;
    view.utf8 = .{ .data = utf8.ptr, .len = utf8.len };
    var store: CanvasStore = .{};
    defer store.deinit(std.testing.allocator);
    try store.copyBorrowed(std.testing.allocator, &view);
    try std.testing.expectEqual(visible_len, store.utf8.items.len);
    try std.testing.expectEqualStrings("", store.rows.items[0].cells[0].cluster);
    try std.testing.expect(std.mem.startsWith(u8, store.screen_text.items, "\xe2\x94\x80"));
    try std.testing.expectEqualStrings("\xe2\x82\xac", store.rows.items[rows - 1].cells[cols - 1].cluster);
}
