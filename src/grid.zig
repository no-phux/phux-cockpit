//! One emulator session, projected for the first-party painter.
//!
//! libghostty-vt owns cell state, damage, scrollback, and selection. This
//! module owns the session and PROJECTS its viewport into a
//! `canvas.TerminalGrid` (see `Session.snapshot`), which
//! `canvas.terminal_grid.paint` turns into pixels. The palette is
//! theme-derived where the emulator still holds its defaults (the honest
//! ANSI-16 story) and exact everywhere an application chose a color: the
//! 256-color cube, the grayscale ramp, and truecolor pass through
//! untouched.
//!
//! It used to emit canvas commands itself — run merging, per-row ids,
//! glyph and text accounting, box-drawing geometry, roughly 375 lines of
//! it. All of that is the framework's now. What stays here is what the
//! framework cannot do for us: own a libghostty session whose bytes come
//! from wherever we choose. The framework's own session store
//! (`runtime/terminal_session.zig`) is capped at four ptys and has no
//! inbound byte-injection path, so a phux-fed fleet needs this layer.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

/// Grid ceilings, derived from the per-view canvas budgets: the glyph
/// budget (8192) bounds how many cells can hold ink at once, and the
/// command budget bounds per-row style runs. A viewport is clamped to
/// these before it reaches the emulator, so a huge window degrades to a
/// bounded grid instead of a budget error.
pub const max_cols: usize = 320;
pub const max_rows: usize = 96;
pub const max_cells: usize = 7168;

/// Our caller id for a grid painted with no explicit pane index. The
/// first-party painter treats id 0 as the framework's ANONYMOUS
/// convention (every command emitted with id 0, no retained identity),
/// so the default has to be nonzero for the retained renderer to match
/// rows across rebuilds.
const grid_id_base: u64 = 0x7e21;

/// The caller id for pane `index`. Under the first-party painter this is
/// a plain small integer, not a hand-built stride: the painter scales it
/// by 2^24 itself (`canvas.terminal_grid.paintIdBase`) and guarantees
/// that grids whose ids differ modulo 2^40 can never collide. The
/// forked painter needed a 2^40 stride here because it emitted raw
/// offsets from the base; that arithmetic is now the framework's.
pub fn paneIdBase(index: usize) u64 {
    return grid_id_base + index;
}

/// The cursor's command id for a grid painted from caller id `id_base`,
/// derived from the painter's own scheme rather than a local guess:
/// `paintIdBase` applies the 2^24 stride and the painter emits its
/// cursor at offset 0x61_0002.
pub fn cursorCommandId(id_base: u64) u64 {
    return canvas.terminal_grid.paintIdBase(id_base) +% 0x61_0002;
}

pub const cursor_command_id: u64 = cursorCommandId(grid_id_base);

/// One live emulator session. Heap-owned by the app (the model holds a
/// pointer): the emulator allocates internally and its state is derived
/// entirely from journaled inputs — fed pty bytes, resizes, and
/// selection edits — so a replayed session rebuilds it byte-identical.
pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState,
    /// Terminal answers to queries (DSR, DA1, XTVERSION, ...) produced
    /// while feeding output; the app drains this after every feed and
    /// writes it back to the pty. Heap-allocated and GROWN TO FIT (up to
    /// `response_capacity_max`): replies may sit retained here while the
    /// app's outbound ring is full, and further output keeps feeding —
    /// its replies must accumulate, not evaporate. A reply past the max
    /// (a child that ignored the whole pending ring while pipelining
    /// queries) is dropped WHOLE (never cut, which would desync the
    /// child's parser) and counted — the honest record that a reply was
    /// lost, checkable by the app.
    response_buffer: []u8 = &.{},
    response_len: usize = 0,
    responses_dropped: u32 = 0,
    /// Cached viewport plain text (see `refreshScreenText`): the grid's
    /// accessibility surface and the fingerprint's cell-state coverage.
    /// Heap-owned and EXACT — each refresh keeps the renderer's whole
    /// allocation, so the semantic text is never truncated (or cut
    /// mid-scalar) by an intermediate buffer: what paints is what
    /// assistive tech reads and what the fingerprint hashes. Empty
    /// means "unknown", never "same as before".
    screen_text: []const u8 = &.{},
    /// Keyboard-selection state: the anchor stays put, the head moves.
    select_anchor: ?CellPos = null,
    select_head: CellPos = .{},
    select_block: bool = false,
    /// Cell metrics for the mono face at the terminal type size,
    /// refreshed whenever tokens/scale reach the painter.
    cell_width: f32 = 8,
    cell_height: f32 = 18,
    font_size: f32 = 13,
    /// Reused projection buffers for `snapshot` (see that function). The
    /// first-party painter takes a RESOLVED snapshot whose every slice
    /// must outlive the build referencing it, so these are owned per
    /// session and rewritten in place each frame — never allocated per
    /// paint. Sized to the painter's own ceilings, so a snapshot this
    /// session can produce is always one the painter can hold.
    snap_rows: []canvas.TerminalRow = &.{},
    snap_cells: []canvas.TerminalCell = &.{},
    snap_text: []u8 = &.{},
    snap_text_len: usize = 0,

    pub const CellPos = struct { x: u16 = 0, y: u16 = 0 };

    /// Query-answer buffer's INITIAL size (it grows to fit).
    pub const response_capacity: usize = 16 * 1024;

    /// The growth ceiling — matched to the app's pending-outbound ring:
    /// retained replies past this could never be enqueued whole anyway,
    /// so growing further would only defer the same counted drop.
    pub const response_capacity_max: usize = 256 * 1024;

    /// The app feeds output in sub-slices no larger than this, draining
    /// answers after each, so a burst of pipelined query replies cannot
    /// outrun the response buffer within one feed. A reply can be several
    /// times its triggering query (XTVERSION and the primary DA answer a
    /// ~4-byte request with ~25 bytes), so the slice is the buffer scaled
    /// down by a generous worst-case expansion factor: even an unbroken
    /// run of the shortest high-expansion query across a full slice
    /// produces fewer reply bytes than the buffer holds. That keeps the
    /// write-back lossless; `responses_dropped` stays the honest fallback
    /// count should a reply ever overflow anyway.
    pub const feed_slice_bytes: usize = response_capacity / 16;

    pub fn create(gpa: std.mem.Allocator, io: std.Io, initial_cols: u16, initial_rows: u16) !*Session {
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{
            .gpa = gpa,
            .term = try vt.Terminal.init(io, gpa, .{
                .cols = @intCast(@min(initial_cols, max_cols)),
                .rows = @intCast(@min(initial_rows, max_rows)),
                .max_scrollback = 1_000_000,
            }),
            .stream = undefined,
            .render = .empty,
        };
        errdefer session.term.deinit(gpa);
        session.response_buffer = try gpa.alloc(u8, response_capacity);
        session.snap_rows = try gpa.alloc(canvas.TerminalRow, max_rows);
        session.snap_cells = try gpa.alloc(canvas.TerminalCell, max_cells);
        session.snap_text = try gpa.alloc(u8, canvas.max_display_list_text_bytes);
        session.stream = .initAlloc(gpa, .init(&session.term));
        session.installStreamEffects();
        return session;
    }

    /// Project the emulator's live viewport into a `canvas.TerminalGrid`
    /// — the resolved, allocation-free snapshot the first-party painter
    /// consumes (`canvas.terminal_grid.paint`).
    ///
    /// This is the whole reason the cockpit keeps its own `Session`
    /// rather than the framework's terminal widget: the framework's
    /// session store is capped at `effects.max_effect_ptys` (4) and has
    /// no inbound byte-injection API, so a phux-fed fleet cannot use it.
    /// The PAINTER, by contrast, is pure — it takes cells, not a
    /// terminal — so a phux-fed pane and a local-pty pane project
    /// identically through here.
    ///
    /// Every returned slice points into this session's own buffers and
    /// stays valid until the next `snapshot` call, which satisfies the
    /// painter's producer-owned-lifetime contract for one frame.
    ///
    /// Box drawing is deliberately NOT special-cased here: the painter
    /// renders box code points as geometry at exact cell bounds under
    /// its own `path_reserve`, so the cluster is left empty for them and
    /// `box.zig`'s hand-rolled segments are no longer needed.
    pub fn snapshot(
        session: *Session,
        tokens: canvas.DesignTokens,
        running: bool,
        selecting: bool,
    ) !canvas.TerminalGrid {
        // Push theme colors into the emulator's DEFAULTS (not the OSC
        // overrides) so ghostty itself composes the final foreground,
        // background, and cursor. Unchanged from the forked painter:
        // one color policy, owned by the emulator.
        session.term.colors.foreground.default = themeRgb(tokens.colors.text);
        session.term.colors.background.default = themeRgb(tokens.colors.background);
        session.term.colors.cursor.default = themeRgb(tokens.colors.accent);

        try session.render.update(session.gpa, &session.term);
        const rs = &session.render;
        const palette = Palette.init(tokens, &rs.colors, &session.term.colors.palette);

        session.snap_text_len = 0;
        var row_count: usize = 0;
        var cell_cursor: usize = 0;

        var row_index: usize = 0;
        while (row_index < rs.row_data.len and row_count < session.snap_rows.len) : (row_index += 1) {
            const row = rs.row_data.get(row_index);
            const width = @min(row.cells.len, session.snap_cells.len - cell_cursor);
            const out = session.snap_cells[cell_cursor..][0..width];

            var x: usize = 0;
            while (x < width) : (x += 1) {
                const cell = row.cells.get(x);
                var cp: u21 = switch (cell.raw.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.raw.content.codepoint.data,
                    else => 0,
                };
                var fg = palette.foreground;
                var underline = false;
                const bg = cellBackground(cell, &palette);
                if (cp != 0 and cell.raw.style_id != 0) {
                    const style = cell.style;
                    fg = palette.resolveFg(style, bg);
                    underline = style.flags.underline != .none;
                    // An invisible cell resolves to "no ink" HERE so the
                    // painter's measure and paint cannot disagree — the
                    // contract `TerminalCell.cp == 0` states.
                    if (style.flags.invisible) cp = 0;
                }

                // A box-drawing cell carries no cluster: the painter
                // draws it as geometry. Everything else stages its full
                // grapheme (primary plus combining marks) into the
                // session's text arena.
                var cluster: []const u8 = "";
                if (cp != 0 and !canvas.terminal_box.isBoxDrawing(cp)) {
                    const start = session.snap_text_len;
                    session.snap_text_len += std.unicode.utf8Encode(
                        cp,
                        session.snap_text[session.snap_text_len..],
                    ) catch 0;
                    if (cell.raw.content_tag == .codepoint_grapheme) {
                        for (cell.grapheme) |extra| {
                            // Stop BETWEEN marks so the staged bytes are
                            // always valid UTF-8. Defensive: the arena is
                            // the painter's own text ceiling.
                            if (session.snap_text_len + 8 > session.snap_text.len) break;
                            session.snap_text_len += std.unicode.utf8Encode(
                                extra,
                                session.snap_text[session.snap_text_len..],
                            ) catch 0;
                        }
                    }
                    cluster = session.snap_text[start..session.snap_text_len];
                }

                out[x] = .{
                    .cp = cp,
                    .cluster = cluster,
                    .fg = fg,
                    .bg = bg,
                    .underline = underline,
                    .wide = switch (cell.raw.wide) {
                        .wide => .wide,
                        .spacer_tail, .spacer_head => .spacer,
                        else => .narrow,
                    },
                };
            }

            session.snap_rows[row_count] = .{
                .cells = out,
                .selection = if (row.selection) |range| .{
                    @intCast(range[0]),
                    @intCast(range[1]),
                } else null,
            };
            cell_cursor += width;
            row_count += 1;
        }

        const bar = session.scrollbar();
        // The cursor comes from the render snapshot, not the emulator
        // directly: `rs.cursor.viewport` is null when the cursor sits
        // outside the visible viewport (scrolled into history), which is
        // exactly the painter's "no cursor" case.
        const cursor: ?canvas.TerminalCursor = blk: {
            if (!rs.cursor.visible) break :blk null;
            const vp = rs.cursor.viewport orelse break :blk null;
            break :blk .{
                .x = @intCast(vp.x),
                .y = @intCast(vp.y),
                .shape = switch (rs.cursor.visual_style) {
                    .bar => .bar,
                    .underline => .underline,
                    else => .block,
                },
            };
        };

        return .{
            .rows = session.snap_rows[0..row_count],
            .background = palette.background,
            .foreground = palette.foreground,
            .cursor_color = palette.cursor,
            .selection_color = palette.selection,
            .cursor = cursor,
            .running = running,
            .select_head = if (selecting)
                .{ .x = session.select_head.x, .y = session.select_head.y }
            else
                null,
            .scrollbar = .{
                .offset = @intCast(bar.offset),
                .len = @intCast(bar.len),
                .total = @intCast(bar.total),
            },
            .screen_text = session.screen_text,
        };
    }

    /// Wire the stream handler's effect callbacks — only `write_pty`
    /// (query answers routed back to the pty); everything else stays
    /// null (the emulator's read-only defaults). Called at create and
    /// after `reset` rebuilds the stream.
    fn installStreamEffects(session: *Session) void {
        session.stream.handler.effects = .{
            .bell = null,
            .clipboard_write = null,
            .color_scheme = null,
            .device_attributes = null,
            .enquiry = null,
            .size = null,
            .title_changed = null,
            .pwd_changed = null,
            .write_pty = writePtyResponse,
            .xtversion = null,
        };
    }

    pub fn destroy(session: *Session) void {
        const gpa = session.gpa;
        session.render.deinit(gpa);
        session.stream.deinit();
        session.term.deinit(gpa);
        gpa.free(session.response_buffer);
        gpa.free(session.snap_rows);
        gpa.free(session.snap_cells);
        gpa.free(session.snap_text);
        if (session.screen_text.len > 0) gpa.free(session.screen_text);
        gpa.destroy(session);
    }

    /// Feed one pty output batch through the VT stream. Parser state
    /// persists across batches (escape sequences split at a chunk
    /// boundary keep parsing).
    pub fn feed(session: *Session, bytes: []const u8) void {
        session.stream.nextSlice(bytes);
    }

    /// Hard-reset the emulator for a fresh session (a RIS): clears the
    /// screen, scrollback, modes (application-cursor, reverse video),
    /// palette overrides, and — by rebuilding the stream — any partial
    /// escape sequence left mid-parse. Without this, restarting a shell
    /// after the previous one exited mid-sequence or in a non-default
    /// mode would misencode the new shell's keys or misparse its first
    /// output as a continuation of the old stream.
    pub fn reset(session: *Session) void {
        session.term.fullReset();
        // `fullReset` (a RIS) leaves the OSC color state alone, so clear
        // it here: a shell that overrode palette entries (OSC 4) or the
        // foreground/background/cursor colors (OSC 10/11/12) and exited
        // must not tint the next session. Overrides drop; the theme
        // defaults stay (paint refreshes them every frame anyway).
        session.term.colors.foreground.override = null;
        session.term.colors.background.override = null;
        session.term.colors.cursor.override = null;
        session.term.colors.palette.resetAll();
        session.stream.deinit();
        session.stream = .initAlloc(session.gpa, .init(&session.term));
        session.installStreamEffects();
        session.response_len = 0;
        session.responses_dropped = 0;
        session.clearSelection();
        session.select_head = .{};
        session.select_block = false;
    }

    /// Terminal query answers accumulated by the last feeds; the caller
    /// writes them to the pty and calls `clearResponses`.
    pub fn pendingResponses(session: *const Session) []const u8 {
        return session.response_buffer[0..session.response_len];
    }

    pub fn clearResponses(session: *Session) void {
        session.response_len = 0;
    }

    fn writePtyResponse(handler: *vt.TerminalStream.Handler, bytes: [:0]const u8) void {
        const session: *Session = @alignCast(@fieldParentPtr("term", handler.terminal));
        const needed = session.response_len + bytes.len;
        if (needed > session.response_buffer.len) {
            // Grow to fit (doubling), up to the ceiling: replies may be
            // retained here across feeds while the app's outbound ring
            // is full, so accumulation is normal, not exceptional. Past
            // the ceiling — or under allocation failure — the reply
            // drops WHOLE and counted, never cut.
            if (needed > response_capacity_max) {
                session.responses_dropped +|= 1;
                return;
            }
            var new_cap = @max(session.response_buffer.len * 2, response_capacity);
            while (new_cap < needed) new_cap *= 2;
            if (new_cap > response_capacity_max) new_cap = response_capacity_max;
            if (session.gpa.realloc(session.response_buffer, new_cap)) |grown| {
                session.response_buffer = grown;
            } else |_| {
                session.responses_dropped +|= 1;
                return;
            }
        }
        @memcpy(session.response_buffer[session.response_len..needed], bytes);
        session.response_len += bytes.len;
    }

    pub fn cols(session: *const Session) u16 {
        return @intCast(session.term.cols);
    }

    pub fn rows(session: *const Session) u16 {
        return @intCast(session.term.rows);
    }

    /// Resize the emulator grid (reflow included). Returns whether the
    /// grid now matches the request: a no-op (already that size) and a
    /// successful reflow both return true; an allocation failure returns
    /// false so the caller leaves its model dimensions unchanged and
    /// retries on the next frame, keeping the emulator and the pty from
    /// disagreeing about the size under memory pressure.
    pub fn resize(session: *Session, new_cols: u16, new_rows: u16) bool {
        const c: vt.size.CellCountInt = @intCast(std.math.clamp(@as(usize, new_cols), 2, max_cols));
        const r: vt.size.CellCountInt = @intCast(std.math.clamp(@as(usize, new_rows), 2, max_rows));
        if (c == session.term.cols and r == session.term.rows) return true;
        session.term.resize(session.gpa, .{ .cols = c, .rows = r }) catch return false;
        // Reflow moves every cell, so keyboard-selection coordinates
        // into the OLD grid are meaningless (and a caret past the new
        // edge would strand Shift+Arrow and copy on cells that no
        // longer exist). Re-anchor at the clamped head: selection mode
        // stays armed, the caret lands inside the new grid, and the
        // stale range is dropped rather than copied.
        if (session.select_anchor != null) {
            session.select_head = .{
                .x = @intCast(@min(@as(usize, session.select_head.x), @as(usize, session.term.cols) - 1)),
                .y = @intCast(@min(@as(usize, session.select_head.y), @as(usize, session.term.rows) - 1)),
            };
            session.select_anchor = session.select_head;
            session.applySelection();
        }
        return true;
    }

    /// Clamp a proposed grid to the canvas budgets: the glyph budget
    /// bounds total cells, so very wide windows trade rows for columns
    /// honestly instead of overflowing the frame. `cell_ceiling` is the
    /// caller's share of `max_cells` — a single-grid window passes the
    /// whole thing; a cockpit of N panes passes its per-pane slice, so
    /// the panes together can never outgrow one view's budgets.
    pub fn clampGrid(proposed_cols: usize, proposed_rows: usize, cell_ceiling: usize) Session.CellPos {
        const cells = @max(4, @min(cell_ceiling, max_cells));
        var c = std.math.clamp(proposed_cols, 2, max_cols);
        var r = std.math.clamp(proposed_rows, 2, max_rows);
        if (c * r > cells) r = @max(2, cells / c);
        if (c * r > cells) c = @max(2, cells / r);
        return .{ .x = @intCast(c), .y = @intCast(r) };
    }

    // ---------------------------------------------------- scrollback

    /// Scroll the viewport into history (negative = toward the top).
    pub fn scrollLines(session: *Session, delta: isize) void {
        session.scrollTracked(.{ .delta_row = delta });
    }

    pub fn scrollToBottom(session: *Session) void {
        session.scrollTracked(.{ .active = {} });
    }

    pub fn scrollToTop(session: *Session) void {
        session.scrollTracked(.{ .top = {} });
    }

    /// Every scroll goes through here: a scroll that actually MOVED the
    /// viewport changes what the screen shows, so the cached semantic
    /// text refreshes with it — scrollback browsing must read (to
    /// assistive tech) and fingerprint as the rows it paints, never the
    /// bottom viewport it left. The offset compare keeps the common
    /// no-op (`scrollToBottom` before typing while already pinned) from
    /// re-rendering the screen text every keystroke.
    fn scrollTracked(session: *Session, behavior: vt.PageList.Scroll) void {
        const before = session.scrollbar().offset;
        session.term.screens.active.pages.scroll(behavior);
        if (session.scrollbar().offset != before) session.refreshScreenText();
    }

    /// Rows of history above the viewport (0 = pinned to the live
    /// screen) plus the total row count, for the scroll indicator.
    pub fn scrollbar(session: *Session) vt.PageList.Scrollbar {
        return session.term.screens.active.pages.scrollbar();
    }

    // ---------------------------------------------------- selection

    pub fn selectionActive(session: *const Session) bool {
        return session.select_anchor != null;
    }

    /// Begin a keyboard selection at the terminal cursor (or extend the
    /// existing one). `block` selects a rectangle; otherwise the
    /// selection flows line-wise like every text surface.
    pub fn beginSelection(session: *Session, block: bool) void {
        // Anchor from LIVE terminal state, never the last painted
        // snapshot: output that moved the cursor since the previous
        // paint (or a session that has not painted yet) must anchor at
        // the cell the cursor actually occupies. A cursor scrolled out
        // of the viewport anchors at the origin, the render snapshot's
        // own fallback.
        const screen = session.term.screens.active;
        const anchor: CellPos = blk: {
            if (screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*)) |point| {
                const coord = point.coord();
                break :blk .{ .x = @intCast(coord.x), .y = @intCast(coord.y) };
            }
            break :blk .{ .x = 0, .y = 0 };
        };
        session.select_anchor = anchor;
        session.select_head = anchor;
        session.select_block = block;
        session.applySelection();
    }

    pub fn toggleSelectionBlock(session: *Session) void {
        if (session.select_anchor == null) return;
        session.select_block = !session.select_block;
        session.applySelection();
    }

    /// Move the selection head one step; `extend` keeps the anchor
    /// (shift held), otherwise anchor follows head (caret move).
    pub fn moveSelection(session: *Session, dx: i32, dy: i32, extend: bool) void {
        if (session.select_anchor == null) return;
        const grid_cols: i32 = @intCast(session.term.cols);
        const grid_rows: i32 = @intCast(session.term.rows);
        var x: i32 = @as(i32, session.select_head.x) + dx;
        var y: i32 = @as(i32, session.select_head.y) + dy;
        x = std.math.clamp(x, 0, grid_cols - 1);
        y = std.math.clamp(y, 0, grid_rows - 1);
        session.select_head = .{ .x = @intCast(x), .y = @intCast(y) };
        if (!extend) session.select_anchor = session.select_head;
        session.applySelection();
    }

    pub fn clearSelection(session: *Session) void {
        session.select_anchor = null;
        session.term.screens.active.clearSelection();
    }

    /// Re-derive the viewport-relative selection coordinates from the
    /// emulator's ABSOLUTE pins after content moved (an output feed
    /// scrolled the live screen). The pins track the selected TEXT —
    /// the painted highlight already follows it — so the caret and the
    /// next Shift+Arrow must follow the same cells, or a copy would
    /// return text the caret no longer names. Returns whether a
    /// selection is still armed: a range that scrolled out of the
    /// viewport (or that the emulator dropped) clears to the honest
    /// no-selection instead of desynchronizing.
    pub fn rebaseSelection(session: *Session) bool {
        if (session.select_anchor == null) return false;
        const screen = session.term.screens.active;
        const selection = screen.selection orelse {
            session.clearSelection();
            return false;
        };
        const anchor_point = screen.pages.pointFromPin(.viewport, selection.start()) orelse {
            session.clearSelection();
            return false;
        };
        const head_point = screen.pages.pointFromPin(.viewport, selection.end()) orelse {
            session.clearSelection();
            return false;
        };
        const anchor_coord = anchor_point.coord();
        const head_coord = head_point.coord();
        session.select_anchor = .{ .x = @intCast(anchor_coord.x), .y = @intCast(anchor_coord.y) };
        session.select_head = .{ .x = @intCast(head_coord.x), .y = @intCast(head_coord.y) };
        return true;
    }

    fn applySelection(session: *Session) void {
        const anchor = session.select_anchor orelse return;
        const screen = session.term.screens.active;
        // Any failure below CLEARS the emulator selection rather than
        // leaving the previous range live: the model caret has already
        // moved, so a copy against the stale range would return text
        // the painted outline no longer describes. No-selection is the
        // honest degraded state — the caret keeps painting from
        // `select_head`, and the next successful move re-establishes
        // the highlight.
        const tl = screen.pages.pin(.{ .viewport = .{ .x = anchor.x, .y = anchor.y } }) orelse {
            screen.clearSelection();
            return;
        };
        const br = screen.pages.pin(.{ .viewport = .{ .x = session.select_head.x, .y = session.select_head.y } }) orelse {
            screen.clearSelection();
            return;
        };
        screen.select(vt.Selection.init(tl, br, session.select_block)) catch screen.clearSelection();
    }

    /// The selected text, caller-owned (freed with the sentinel).
    /// Null means exactly "nothing is selected" — a serialization
    /// failure over an ACTIVE selection is an error, never a silent
    /// null: the caller owes the user a failure signal when a copy
    /// cannot be produced.
    pub fn selectionText(session: *Session, gpa: std.mem.Allocator) !?[:0]const u8 {
        const screen = session.term.screens.active;
        const selection = screen.selection orelse return null;
        return try screen.selectionString(gpa, .{ .sel = selection, .trim = true });
    }

    /// The viewport as plain text — the test and automation view of the
    /// grid (real cell state, no pixels).
    pub fn plainText(session: *Session, gpa: std.mem.Allocator) ![]const u8 {
        return session.term.plainString(gpa);
    }

    /// Refresh the cached viewport text — the grid's ACCESSIBILITY
    /// surface (a terminal's semantic content IS its text) and, through
    /// the a11y tree, the session-fingerprint coverage of real cell
    /// state: two screens with identical byte counters but different
    /// cells must never fingerprint alike. Called wherever the visible
    /// screen changes (output feeds, resizes, the restart reset, and
    /// scrolls that moved the viewport).
    pub fn refreshScreenText(session: *Session) void {
        const text = session.term.plainString(session.gpa) catch {
            // Unknown beats stale: a screen we could not render must
            // not keep reading (to assistive tech) or fingerprinting as
            // the previous one — the emulator and the painted grid have
            // already advanced. Empty is the loud degraded state (the
            // view falls back to its static label, and any checkpoint
            // over it diverges rather than false-verifying).
            if (session.screen_text.len > 0) session.gpa.free(session.screen_text);
            session.screen_text = &.{};
            return;
        };
        if (session.screen_text.len > 0) session.gpa.free(session.screen_text);
        session.screen_text = text;
    }

    /// The cached viewport text (see `refreshScreenText`).
    pub fn screenText(session: *const Session) []const u8 {
        return session.screen_text;
    }
};

// ------------------------------------------------------------- painting

/// Everything one paint needs beyond the session.
pub const PaintOptions = struct {
    /// Grid origin and extent in canvas points.
    frame: geometry.RectF,
    tokens: canvas.DesignTokens,
    /// The pty is live (cursor paints filled; an ended session paints
    /// the cursor hollow).
    running: bool,
    /// Whether this terminal window currently owns keyboard focus.
    /// A live cursor fills only while focused; blur leaves its outline
    /// in place as the conventional inactive-terminal cue.
    focused: bool = true,
    /// Selection mode is armed (the head cell paints a focus outline).
    selecting: bool,
    /// Hard ceiling on display-list commands this paint may emit — the
    /// chrome prefix budget the app reserved. A pathological screen
    /// (every cell a different style, so no run merges) can generate
    /// more commands than the budget; painting stops row-wise at the
    /// ceiling rather than overflowing the frame, so a busy screen
    /// degrades to fewer painted rows instead of a failed render. 0
    /// means unbounded (tests that size their own builder).
    command_budget: usize = 0,
    /// Display-list TEXT bytes to hold back from the grid for the widgets
    /// the app appends AFTER this chrome prefix (a header, a status line).
    /// Those widgets draw their own glyphs into the SAME per-view text
    /// store (`canvas.max_display_list_text_bytes`), so a grapheme-heavy
    /// grid that consumed all of it would push the combined display list
    /// over the runtime limit and fail the whole frame — leaving stale
    /// content. Reserving their worst-case text here makes the grid
    /// degrade to a few fewer painted rows instead, and the widgets
    /// always fit. 0 means the grid may use the whole store (tests that
    /// paint no widgets).
    text_reserve: usize = 0,
    /// The rect the full-bleed theme background fills - the WHOLE
    /// window under hidden-inset chrome, so the titlebar band reads as
    /// part of the terminal and the window is one seamless surface.
    /// Null fills `frame` (tests that paint the grid alone).
    background_frame: ?geometry.RectF = null,
    /// Ceiling on DISTINCT code points the grid may put on screen in one
    /// paint — a proxy bound for the runtime's per-view glyph-atlas
    /// entries, which an adversarial screen (thousands of distinct
    /// scalars plus distinct combining marks) can exhaust long before
    /// the command or text budgets bind, failing the whole frame
    /// instead of a row. Painting stops row-atomically BEFORE the row
    /// whose new code points would cross it. 0 means unbounded (tests
    /// that size their own builder).
    glyph_budget: usize = 0,
    /// Vector path elements held back for widgets the app appends after
    /// the grid. New under the first-party painter: it renders box
    /// drawing as GEOMETRY under a path budget, so box-heavy content now
    /// competes for paths rather than for the per-column command reserve
    /// the forked painter had to widen by hand.
    path_reserve: usize = 0,
    /// The caller id this paint emits under. One window can hold several
    /// grids side by side (the cockpit's panes); each needs its own id or
    /// their row commands would collide and the retained diff would
    /// reject the frame. `grid.paneIdBase(i)` mints them; the default is
    /// the single-grid id. Zero selects the framework's anonymous
    /// convention (no retained identity), so it is deliberately not the
    /// default.
    id_base: u64 = grid_id_base,
};

/// Paint the session's viewport into the display list: per-row
/// background runs, the selection wash, per-run text, decorations, the
/// cursor, and the scrollback indicator. Row commands carry stable ids
/// so the retained renderer's diff keeps damage row-shaped.
pub fn paint(session: *Session, builder: *canvas.Builder, options: PaintOptions) !void {
    // Cell metrics come from the painter's OWN seam
    // (`canvas.terminalCellMetrics`) rather than a second local
    // measurement. The framework documents it as the one seam shared by
    // the painter and the runtime's grid sizing, so the cells painted and
    // the cols/rows pushed to the pty cannot disagree — the forked
    // painter measured "M" itself and had to keep that in step by hand.
    const metrics = canvas.terminalCellMetrics(options.tokens);
    session.font_size = metrics.font_size;
    session.cell_width = metrics.width;
    session.cell_height = metrics.height;

    const snap = try session.snapshot(options.tokens, options.running, options.selecting);
    try paintTerminalGrid(snap, builder, options);
}

/// Paint one already-borrowed frontend-neutral grid through the same
/// first-party painter and per-pane identity policy as a local fixture.
///
/// The grid and every nested slice need remain valid only for this call.
/// This is the production seam used by the phux client FFI; it neither owns
/// terminal state nor copies frame payloads through the native-sdk event
/// channel.
pub fn paintTerminalGrid(
    snapshot: canvas.TerminalGrid,
    builder: *canvas.Builder,
    options: PaintOptions,
) !void {
    try canvas.terminal_grid.paint(snapshot, builder, .{
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

fn cellBackground(cell: anytype, palette: *const Palette) ?canvas.Color {
    switch (cell.raw.content_tag) {
        .bg_color_palette => return palette.indexed(cell.raw.content.color_palette.data),
        .bg_color_rgb => {
            const rgb = cell.raw.content.color_rgb;
            return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
        },
        else => {},
    }
    if (cell.raw.style_id == 0) return null;
    const style = cell.style;
    if (style.flags.inverse) {
        return palette.resolveFgRaw(style);
    }
    return switch (style.bg_color) {
        .none => null,
        .palette => |index| palette.indexed(index),
        .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
    };
}

// ------------------------------------------------------------- palette

/// The theme mapping, stated honestly: where the emulator's palette
/// entry still holds its DEFAULT value, the ANSI-16 slot derives from
/// the active theme tokens (background/text neutrals; red, green, and
/// yellow from the semantic hues) so a themed app and its terminal read
/// as one surface. The moment a program restyles an entry (OSC 4), the
/// programmed color wins verbatim — and the cube (16..231), the
/// grayscale ramp (232..255), and truecolor always pass through exactly.
/// A theme token color (f32 rgba 0..1) as the emulator's 8-bit RGB.
fn themeRgb(color: canvas.Color) vt.color.RGB {
    return .{
        .r = @intFromFloat(std.math.clamp(color.r, 0, 1) * 255 + 0.5),
        .g = @intFromFloat(std.math.clamp(color.g, 0, 1) * 255 + 0.5),
        .b = @intFromFloat(std.math.clamp(color.b, 0, 1) * 255 + 0.5),
    };
}

fn rgbToColor(rgb: vt.color.RGB) canvas.Color {
    return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
}

const Palette = struct {
    background: canvas.Color,
    foreground: canvas.Color,
    cursor: canvas.Color,
    selection: canvas.Color,
    ansi: [16]canvas.Color,
    terminal: *const vt.RenderState.Colors,
    /// The emulator's live palette WITH its override mask, so an
    /// explicit OSC 4 set is honored even when it happens to equal the
    /// default RGB — the mask, not RGB equality, decides "untouched".
    dynamic: *const vt.color.DynamicPalette,

    fn init(tokens: canvas.DesignTokens, terminal_colors: *const vt.RenderState.Colors, dynamic: *const vt.color.DynamicPalette) Palette {
        const colors = tokens.colors;
        const dark = colors.background.r + colors.background.g + colors.background.b < 1.5;
        const dim: f32 = if (dark) 0.85 else 1.0;
        const bright: f32 = if (dark) 1.0 else 0.8;
        // Primary colors come from the emulator's resolved render state
        // — which already folded in the theme defaults pushed above plus
        // any OSC 10/11/12 override and DECSCNM reverse swap — so an
        // application that recolors its terminal is honored exactly.
        // (`background`/`foreground` are always populated once a default
        // is set; `cursor` falls back to the accent if the emulator left
        // it unset.)
        return .{
            .background = rgbToColor(terminal_colors.background),
            .foreground = rgbToColor(terminal_colors.foreground),
            .cursor = if (terminal_colors.cursor) |cur| rgbToColor(cur) else colors.accent,
            .selection = colors.accent,
            .terminal = terminal_colors,
            .dynamic = dynamic,
            .ansi = .{
                // 0-7: black, red, green, yellow, blue, magenta, cyan, white.
                blend(colors.text, colors.background, if (dark) 0.35 else 0.95),
                scale(colors.destructive, dim),
                scale(colors.success, dim),
                scale(colors.warning, dim),
                scale(canvas.Color.rgb8(37, 99, 235), dim),
                scale(canvas.Color.rgb8(147, 51, 234), dim),
                scale(canvas.Color.rgb8(8, 145, 178), dim),
                blend(colors.text, colors.background, if (dark) 0.75 else 0.35),
                // 8-15: the bright ramp.
                blend(colors.text, colors.background, if (dark) 0.5 else 0.75),
                scale(colors.destructive, bright),
                scale(colors.success, bright),
                scale(colors.warning, bright),
                scale(canvas.Color.rgb8(59, 130, 246), bright),
                scale(canvas.Color.rgb8(168, 85, 247), bright),
                scale(canvas.Color.rgb8(34, 211, 238), bright),
                colors.text,
            },
        };
    }

    /// Palette index -> color: theme-derived for UNTOUCHED ANSI-16
    /// entries, the emulator's live palette everywhere else. "Untouched"
    /// is the emulator's own override mask, not RGB equality — a program
    /// that OSC-4-sets a slot to exactly the default RGB has still
    /// chosen it, and its choice is honored rather than replaced by the
    /// theme color.
    fn indexed(palette: *const Palette, index: u8) canvas.Color {
        if (index < 16 and !palette.dynamic.mask.isSet(index)) {
            return palette.ansi[index];
        }
        const live = palette.dynamic.current[index];
        return canvas.Color.rgb8(live.r, live.g, live.b);
    }

    fn resolveFg(palette: *const Palette, style: vt.Style, bg: ?canvas.Color) canvas.Color {
        _ = bg;
        if (style.flags.inverse) {
            // Inverse paints the text in the cell's BACKGROUND color
            // (the theme background when the cell chose none) — the
            // opposite of `cellBackground`, which paints the swapped
            // foreground behind it. Resolving the real bg here, rather
            // than the already-swapped `bg` argument, is what keeps
            // default inverse text visible instead of foreground on
            // an identical foreground.
            return palette.resolveBgRaw(style);
        }
        var color = palette.resolveFgRaw(style);
        if (style.flags.faint) color = blend(color, palette.background, 0.5);
        return color;
    }

    fn resolveFgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.fg_color) {
            .none => palette.foreground,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn resolveBgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.bg_color) {
            .none => palette.background,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn blend(a: canvas.Color, b: canvas.Color, t: f32) canvas.Color {
        return canvas.Color.rgba(
            a.r + (b.r - a.r) * t,
            a.g + (b.g - a.g) * t,
            a.b + (b.b - a.b) * t,
            1,
        );
    }

    fn scale(color: canvas.Color, factor: f32) canvas.Color {
        return canvas.Color.rgba(
            @min(1, color.r * factor),
            @min(1, color.g * factor),
            @min(1, color.b * factor),
            1,
        );
    }
};
