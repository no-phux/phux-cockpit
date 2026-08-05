//! One libghostty emulator session and its canvas-grid projection.
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
//! it. All of that is the framework's now. What stays here is the local
//! provider's libghostty session and its byte-injection path. The framework's
//! own session store (`runtime/terminal_session.zig`) is capped at four ptys and
//! has no inbound byte-injection path. Other providers project their
//! authoritative model straight into the shared painter below.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const palette_module = @import("palette.zig");

const canvas = native_sdk.canvas;
const Palette = palette_module.Palette;
const cellBackground = palette_module.cellBackground;
const themeRgb = palette_module.themeRgb;

/// Ghostty's standard terminal word boundaries. The pinned VT module exports
/// SelectionGesture but keeps its default codepoint policy private.
const pointer_word_boundaries = [_]u21{
    0,   ' ', '\t', '\'', '"',
    '│',
    '`', '|', ':',  ';',  ',',
    '(', ')', '[',  ']',  '{',
    '}', '<', '>',  '$',
};

/// Grid ceilings bound allocation and command-id geometry. Painter resources
/// are content-dependent: a screen full of repeated ASCII does not consume one
/// glyph-atlas entry per cell, so cell count must never shrink the PTY below its
/// visible pane.
pub const max_cols: usize = 320;
pub const max_rows: usize = 96;
pub const max_cells: usize = max_cols * max_rows;
/// Four bytes per cell preserves every primary Unicode scalar across the full
/// viewport. Combining data that exceeds this bound becomes an atomic
/// paint-budget stop rather than silently blank cells.
pub const snapshot_text_capacity: usize = max_cells * 4;
const snapshot_text_overflow_cluster = " " ** (canvas.max_display_list_text_bytes + 1);

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
    response_bytes_dropped: u64 = 0,
    /// Cached viewport plain text (see `screenText`): the grid's
    /// accessibility surface and the fingerprint's cell-state coverage.
    /// Heap-owned, GROWN TO FIT, and reused across refreshes — the
    /// serialization is O(viewport) and used to run on every pty output
    /// batch, for background tabs nobody paints, reallocating each time.
    /// It is now computed LAZILY: writers mark `screen_text_dirty` and
    /// only `screenText` pays, so a session that is never read never
    /// serializes. The stored text is EXACT (never truncated or cut
    /// mid-scalar): what paints is what assistive tech reads and what
    /// the fingerprint hashes. A zero length means "unknown", never
    /// "same as before".
    screen_text_buf: []u8 = &.{},
    screen_text_len: usize = 0,
    /// The screen changed since the cached text was produced. Starts set
    /// so a session read before any feed still serializes once.
    screen_text_dirty: bool = true,
    /// Keyboard-selection state: the anchor stays put, the head moves.
    select_anchor: ?CellPos = null,
    select_head: CellPos = .{},
    select_block: bool = false,
    /// Ghostty's native pointer-selection gesture. Its pins survive output
    /// and viewport movement while a drag is active; the model only owns
    /// which terminal/generation receives subsequent pointer phases.
    pointer_selection: vt.SelectionGesture = .init,
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

    pub const PointerSelectionEvent = struct {
        phase: canvas.WidgetPointerPhase,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        click_count: u8 = 1,
    };

    pub const PointerAutoscrollEvent = struct {
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    };

    /// Query-answer buffer's INITIAL size (it grows to fit).
    pub const response_capacity: usize = 16 * 1024;

    /// The growth ceiling — matched to the app's pending-outbound ring:
    /// retained replies past this could never be enqueued whole anyway,
    /// so growing further would only defer the same counted drop.
    pub const response_capacity_max: usize = 64 * 1024;

    /// The app feeds output in sub-slices no larger than this, draining
    /// answers after each, so a burst of pipelined query replies cannot
    /// outrun the response buffer within one feed.
    ///
    /// Matched to the response buffer rather than a fraction of it: the
    /// slice size is a PARSER-THROUGHPUT knob, and a 1 KiB slice split a
    /// routine 64 KiB pty batch into 64 parser entries, each followed by
    /// a full response drain and outbound flush — 64x the per-slice
    /// overhead on the hottest path in the app. The response buffer no
    /// longer needs the safety factor a fixed-capacity buffer did: it
    /// GROWS TO FIT up to `response_capacity_max` (see `writePtyResponse`),
    /// so a slice that does out-answer the initial capacity reallocates
    /// instead of dropping, and `response_bytes_dropped` stays the honest
    /// count should a reply ever overflow the ceiling anyway.
    pub const feed_slice_bytes: usize = response_capacity;

    /// Scrollback ceiling in BYTES (what libghostty's PageList takes),
    /// not lines. The previous 1 MB was roughly a couple of PageList
    /// pages — a few hundred rows — which is not scrollback, it is a
    /// slightly taller screen. 50 MB is Ghostty's own default and holds
    /// the hundreds of thousands of rows a build log or a `git log`
    /// actually produces. The pages are allocated on demand, so an idle
    /// session still costs one page.
    pub const max_scrollback: usize = 50_000_000;

    pub fn create(gpa: std.mem.Allocator, io: std.Io, initial_cols: u16, initial_rows: u16) !*Session {
        const session = try gpa.create(Session);
        errdefer gpa.destroy(session);
        session.* = .{
            .gpa = gpa,
            .term = try vt.Terminal.init(io, gpa, .{
                .cols = @intCast(@min(initial_cols, max_cols)),
                .rows = @intCast(@min(initial_rows, max_rows)),
                .max_scrollback = max_scrollback,
            }),
            .stream = undefined,
            .render = .empty,
        };
        errdefer session.term.deinit(gpa);
        session.response_buffer = try gpa.alloc(u8, response_capacity);
        session.snap_rows = try gpa.alloc(canvas.TerminalRow, max_rows);
        session.snap_cells = try gpa.alloc(canvas.TerminalCell, max_cells);
        session.snap_text = try gpa.alloc(u8, snapshot_text_capacity);
        session.stream = .initAlloc(gpa, .init(&session.term));
        session.installStreamEffects();
        return session;
    }

    /// Project the emulator's live viewport into a `canvas.TerminalGrid`
    /// — the resolved, allocation-free snapshot the first-party painter
    /// consumes (`canvas.terminal_grid.paint`).
    ///
    /// The local provider keeps its own `Session` rather than using the
    /// framework terminal widget because the latter has no inbound
    /// byte-injection API. A provider with its own authoritative terminal model
    /// instead supplies `canvas.TerminalGrid` directly to
    /// `paintTerminalGrid`; it never creates a `Session` or second emulator.
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
        //
        // The ANSI-16 palette is deliberately NOT pushed from here. It is
        // the emulator's own (`vt.color.default`, installed by
        // `Terminal.init`) and the projection reads it back verbatim: a
        // terminal red must be a terminal red, not the UI's destructive
        // token. Theming the palette is a `DynamicPalette.changeDefault`
        // call away (it preserves OSC 4 overrides) whenever a real
        // terminal color scheme exists to install; design tokens are not
        // one.
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
                    // `resolveFg` folds every attribute the painter can
                    // actually carry into the resolved color: inverse
                    // (fg/bg swap), faint (blend toward the background),
                    // and bold-as-bright over the ANSI-8 range.
                    //
                    // `canvas.TerminalCell` carries a code point, a
                    // cluster, two colors, ONE boolean underline, and a
                    // wide flag — so italic, strikethrough, overline, the
                    // underline STYLE (double/curly/dotted/dashed), the
                    // underline COLOR, and a real bold weight have nowhere
                    // to go and are dropped here rather than faked. Every
                    // underline style collapses to the single line the
                    // painter draws, which is the honest degradation:
                    // "underlined" survives, its flavor does not.
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
                    var overflow = false;
                    const primary_len = std.unicode.utf8CodepointSequenceLength(cp) catch 0;
                    if (primary_len == 0 or primary_len > session.snap_text.len - session.snap_text_len) {
                        overflow = true;
                    } else {
                        session.snap_text_len += std.unicode.utf8Encode(
                            cp,
                            session.snap_text[session.snap_text_len..],
                        ) catch 0;
                    }
                    if (!overflow and cell.raw.content_tag == .codepoint_grapheme) {
                        for (cell.grapheme) |extra| {
                            const extra_len = std.unicode.utf8CodepointSequenceLength(extra) catch 0;
                            if (extra_len == 0 or extra_len > session.snap_text.len - session.snap_text_len) {
                                overflow = true;
                                break;
                            }
                            session.snap_text_len += std.unicode.utf8Encode(
                                extra,
                                session.snap_text[session.snap_text_len..],
                            ) catch 0;
                        }
                    }
                    if (overflow) {
                        // The valid UTF-8 sentinel exceeds the painter ceiling,
                        // forcing this row to degrade whole. An empty cluster
                        // would erase ink without charging any text budget.
                        session.snap_text_len = start;
                        cluster = snapshot_text_overflow_cluster;
                    } else {
                        cluster = session.snap_text[start..session.snap_text_len];
                    }
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
        //
        // Not projected, because `canvas.TerminalCursor` has nowhere to
        // put them: the DECSCUSR blink bit (`rs.cursor.blinking`) and the
        // two-column extent of a cursor sitting on a wide cell. Ghostty's
        // custom hollow-block style collapses onto `.block` — the painter
        // reserves hollow for the UNFOCUSED cue, which it drives itself
        // from `TerminalPaintOptions.focused`.
        const cursor: ?canvas.TerminalCursor = blk: {
            if (!rs.cursor.visible) break :blk null;
            const vp = rs.cursor.viewport orelse break :blk null;
            const x: u16 = @intCast(vp.x);
            break :blk .{
                // A cursor whose left neighbor is a wide cell is sitting
                // on that cell's SPACER tail — the half with no ink. Draw
                // it on the primary instead, or a block cursor covers the
                // blank half of a CJK character and the glyph itself
                // stays unmarked.
                .x = if (vp.wide_tail and x > 0) x - 1 else x,
                .y = @intCast(vp.y),
                .shape = switch (rs.cursor.visual_style) {
                    .bar => .bar,
                    .underline => .underline,
                    .block, .block_hollow => .block,
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
            .screen_text = session.screenText(),
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
        session.pointer_selection.deinit(&session.term);
        session.render.deinit(gpa);
        session.stream.deinit();
        session.term.deinit(gpa);
        gpa.free(session.response_buffer);
        gpa.free(session.snap_rows);
        gpa.free(session.snap_cells);
        gpa.free(session.snap_text);
        if (session.screen_text_buf.len > 0) gpa.free(session.screen_text_buf);
        gpa.destroy(session);
    }

    /// Feed one pty output batch through the VT stream. Parser state
    /// persists across batches (escape sequences split at a chunk
    /// boundary keep parsing).
    pub fn feed(session: *Session, bytes: []const u8) void {
        session.stream.nextSlice(bytes);
        // Output is the overwhelmingly common screen change; marking here
        // (rather than serializing here) is what keeps the semantic text
        // off the hot path entirely for panes nobody reads.
        session.screen_text_dirty = true;
    }

    /// Hard-reset the emulator for a fresh session (a RIS): clears the
    /// screen, scrollback, modes (application-cursor, reverse video),
    /// palette overrides, and — by rebuilding the stream — any partial
    /// escape sequence left mid-parse. Without this, restarting a shell
    /// after the previous one exited mid-sequence or in a non-default
    /// mode would misencode the new shell's keys or misparse its first
    /// output as a continuation of the old stream.
    pub fn reset(session: *Session) void {
        session.pointer_selection.reset(&session.term);
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
        session.response_bytes_dropped = 0;
        session.clearSelection();
        session.select_head = .{};
        session.select_block = false;
        session.screen_text_dirty = true;
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
                session.response_bytes_dropped +|= bytes.len;
                return;
            }
            var new_cap = @max(session.response_buffer.len * 2, response_capacity);
            while (new_cap < needed) new_cap *= 2;
            if (new_cap > response_capacity_max) new_cap = response_capacity_max;
            if (session.gpa.realloc(session.response_buffer, new_cap)) |grown| {
                session.response_buffer = grown;
            } else |_| {
                session.response_bytes_dropped +|= bytes.len;
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
        // Reflow rewrites the viewport: the cached semantic text describes
        // a grid that no longer exists.
        session.screen_text_dirty = true;
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

    /// Clamp a proposed grid to allocation and command-id geometry bounds.
    /// Distinct-glyph, text, path, and command budgets are fenced at paint.
    pub fn clampGrid(proposed_cols: usize, proposed_rows: usize) Session.CellPos {
        return .{
            .x = @intCast(std.math.clamp(proposed_cols, 2, max_cols)),
            .y = @intCast(std.math.clamp(proposed_rows, 2, max_rows)),
        };
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
    /// text is invalidated with it — scrollback browsing must read (to
    /// assistive tech) and fingerprint as the rows it paints, never the
    /// bottom viewport it left. The offset compare keeps the common
    /// no-op (`scrollToBottom` before typing while already pinned) from
    /// invalidating the screen text every keystroke.
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
        return session.select_anchor != null or session.term.screens.active.selection != null;
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
        session.pointer_selection.reset(&session.term);
        session.select_anchor = null;
        session.term.screens.active.clearSelection();
    }

    /// Primary-pointer selection using Ghostty's own cell/word/line gesture.
    /// Coordinates are relative to the exact retained terminal-widget frame;
    /// captured drags may extend beyond it and clamp to the nearest edge.
    pub fn pointerSelection(session: *Session, event: PointerSelectionEvent) bool {
        if (!std.math.isFinite(event.x) or !std.math.isFinite(event.y) or
            !std.math.isFinite(event.width) or !std.math.isFinite(event.height) or
            event.width <= 0 or event.height <= 0 or
            session.cell_width <= 0 or session.cell_height <= 0)
        {
            return false;
        }

        const screen = session.term.screens.active;
        switch (event.phase) {
            .down => {
                const pin = session.pointerPin(event) orelse return false;
                session.select_anchor = null;
                session.pointer_selection.reset(&session.term);
                const behavior: vt.SelectionGesture.Behavior = if (event.click_count >= 3)
                    .line
                else if (event.click_count == 2)
                    .word
                else
                    .cell;
                const behaviors = [3]vt.SelectionGesture.Behavior{ behavior, behavior, behavior };
                const selected = session.pointer_selection.press(&session.term, .{
                    .time = null,
                    .pin = pin,
                    .xpos = event.x,
                    .ypos = event.y,
                    .max_distance = @max(1, session.cell_width),
                    .repeat_interval = 0,
                    .word_boundary_codepoints = &pointer_word_boundaries,
                    .behaviors = &behaviors,
                }) catch {
                    screen.clearSelection();
                    return true;
                };
                if (selected) |selection| {
                    screen.select(selection) catch screen.clearSelection();
                } else {
                    screen.clearSelection();
                }
                return true;
            },
            .move => return session.applyPointerDrag(event),
            .up => {
                const pin = session.pointerPin(event);
                const changed = session.applyPointerDrag(event);
                session.pointer_selection.release(&session.term, .{ .pin = pin });
                return changed;
            },
            .cancel => {
                session.pointer_selection.reset(&session.term);
                return false;
            },
            .hover, .wheel => return false,
        }
    }

    fn applyPointerDrag(session: *Session, event: PointerSelectionEvent) bool {
        const pin = session.pointerPin(event) orelse return false;
        const selection = session.pointer_selection.drag(&session.term, .{
            .pin = pin,
            .xpos = event.x,
            .ypos = event.y,
            .rectangle = false,
            .word_boundary_codepoints = &pointer_word_boundaries,
            .geometry = .{
                .columns = session.cols(),
                .cell_width = @intFromFloat(@max(1, @round(session.cell_width))),
                .padding_left = 0,
                .screen_height = @intFromFloat(@max(1, @round(event.height))),
            },
        }) orelse return false;
        session.term.screens.active.select(selection) catch return false;
        return true;
    }

    pub fn pointerAutoscrollActive(session: *const Session) bool {
        return session.pointer_selection.left_drag_autoscroll != .none;
    }

    /// Advance an edge drag by one Ghostty-owned row. The host supplies the
    /// cadence; one invocation is deliberately bounded to one viewport row.
    pub fn pointerAutoscroll(session: *Session, event: PointerAutoscrollEvent) bool {
        if (!session.pointerAutoscrollActive() or
            !std.math.isFinite(event.x) or !std.math.isFinite(event.y) or
            !std.math.isFinite(event.width) or !std.math.isFinite(event.height) or
            event.width <= 0 or event.height <= 0 or
            session.cell_width <= 0 or session.cell_height <= 0)
        {
            return false;
        }
        const coordinate = session.pointerViewportCoordinate(event.x, event.y) orelse return false;
        const selection = session.pointer_selection.autoscrollTick(&session.term, .{
            .viewport = coordinate,
            .xpos = event.x,
            .ypos = event.y,
            .rectangle = false,
            .word_boundary_codepoints = &pointer_word_boundaries,
            .geometry = .{
                .columns = session.cols(),
                .cell_width = @intFromFloat(@max(1, @round(session.cell_width))),
                .padding_left = 0,
                .screen_height = @intFromFloat(@max(1, @round(event.height))),
            },
        }) orelse return false;
        session.term.screens.active.select(selection) catch return false;
        session.refreshScreenText();
        return true;
    }

    fn pointerPin(session: *Session, event: PointerSelectionEvent) ?vt.Pin {
        const coordinate = session.pointerViewportCoordinate(event.x, event.y) orelse return null;
        return session.term.screens.active.pages.pin(.{ .viewport = coordinate });
    }

    fn pointerViewportCoordinate(session: *const Session, x: f32, y: f32) ?vt.Coordinate {
        const cols_count = session.cols();
        const rows_count = session.rows();
        if (cols_count == 0 or rows_count == 0) return null;
        const max_x: f32 = @floatFromInt(cols_count - 1);
        const max_y: f32 = @floatFromInt(rows_count - 1);
        const cell_x = std.math.clamp(@floor(x / session.cell_width), 0, max_x);
        const cell_y = std.math.clamp(@floor(y / session.cell_height), 0, max_y);
        return .{
            .x = @intFromFloat(cell_x),
            .y = @intFromFloat(cell_y),
        };
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

    /// INVALIDATE the cached viewport text — the grid's ACCESSIBILITY
    /// surface (a terminal's semantic content IS its text) and, through
    /// the a11y tree, the session-fingerprint coverage of real cell
    /// state: two screens with identical byte counters but different
    /// cells must never fingerprint alike.
    ///
    /// This used to SERIALIZE the whole viewport, and it is called from
    /// every path that changes the screen — every pty output batch
    /// included, for every session, painted or not. That put an
    /// O(viewport) walk plus a fresh heap allocation on the hot path for
    /// terminals nobody was looking at. It now only sets a flag;
    /// `screenText` pays, once, and only when something actually reads.
    pub fn refreshScreenText(session: *Session) void {
        session.screen_text_dirty = true;
    }

    /// The cached viewport text, recomputed on demand when the screen
    /// moved under it (see `refreshScreenText`).
    pub fn screenText(session: *Session) []const u8 {
        if (session.screen_text_dirty) session.renderScreenText();
        return session.screen_text_buf[0..session.screen_text_len];
    }

    /// Serialize the viewport into the reused, grown-to-fit text buffer.
    /// `Writer.Allocating` keeps the previous frame's allocation and only
    /// grows when a screen needs more than it already holds, so a steady
    /// terminal serializes without touching the allocator at all.
    fn renderScreenText(session: *Session) void {
        const screen = session.term.screens.active;
        var writer: std.Io.Writer.Allocating = .initOwnedSlice(session.gpa, session.screen_text_buf);
        // The buffer is reclaimed on EVERY exit path — the allocating
        // writer owns it while it runs and would free it on `deinit`.
        defer session.screen_text_buf = writer.writer.buffer;
        session.screen_text_dirty = false;
        session.screen_text_len = 0;
        const br = screen.pages.getBottomRight(.viewport) orelse return;
        // Unknown beats stale: a screen we could not render must not keep
        // reading (to assistive tech) or fingerprinting as the previous
        // one — the emulator and the painted grid have already advanced.
        // Empty is the loud degraded state (the view falls back to its
        // static label, and any checkpoint over it diverges rather than
        // false-verifying), and it persists until the next invalidation
        // rather than retrying on every read.
        screen.dumpString(&writer.writer, .{
            .tl = screen.pages.getTopLeft(.viewport),
            .br = br,
            .unwrap = false,
        }) catch return;
        session.screen_text_len = writer.writer.end;
    }
};
