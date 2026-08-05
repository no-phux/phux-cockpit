const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const createSession = support.createSession;
const createSessions = support.createSessions;
const destroyModelSessions = app.deinitModel;
const startFocusedTerminal = support.startFocusedTerminal;

test "the emulator round-trips output into real cell state" {
    const session = try createSession(40, 6);
    defer session.destroy();
    session.feed("hello \x1b[1;31mworld\x1b[0m\r\n$ ");
    const text = try session.plainText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, text, "$") != null);
}

test "wide CJK cells occupy two columns with a spacer tail" {
    const session = try createSession(20, 4);
    defer session.destroy();
    session.feed("\xe4\xbd\xa0\xe5\xa5\xbd!"); // 你好!
    try session.render.update(session.gpa, &session.term);
    const row = session.render.row_data.get(0);
    const first = row.cells.get(0);
    try testing.expectEqual(vt.page.Cell.Wide.wide, first.raw.wide);
    try testing.expectEqual(vt.page.Cell.Wide.spacer_tail, row.cells.get(1).raw.wide);
    // The '!' lands in column 4 — width semantics held.
    try testing.expectEqual(@as(u21, '!'), row.cells.get(4).raw.codepoint());
}

test "scrollback windows the viewport and the indicator reports it" {
    const session = try createSession(20, 4);
    defer session.destroy();
    var line: [16]u8 = undefined;
    for (0..30) |index| {
        session.feed(std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    var bar = session.scrollbar();
    try testing.expect(bar.total > bar.len);
    const bottom_offset = bar.offset;
    session.scrollLines(-8);
    bar = session.scrollbar();
    try testing.expect(bar.offset < bottom_offset);
    session.scrollToBottom();
    bar = session.scrollbar();
    try testing.expectEqual(bottom_offset, bar.offset);
}

test "keyboard selection selects real text, line and block alike" {
    const session = try createSession(20, 5);
    defer session.destroy();
    session.feed("alpha beta\r\ngamma delta\r\n");
    // Anchor at the cursor (row 2), then walk up-left onto the text.
    session.beginSelection(false);
    session.moveSelection(0, -2, false);
    session.moveSelection(4, 0, true);
    const text = (try session.selectionText(testing.allocator)) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("alpha", text);

    // Block mode: a 2x2 rectangle across both rows.
    session.clearSelection();
    session.beginSelection(false);
    session.moveSelection(0, -2, false);
    session.toggleSelectionBlock();
    session.moveSelection(1, 1, true);
    const block = (try session.selectionText(testing.allocator)) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(block);
    try testing.expect(std.mem.indexOf(u8, block, "al") != null);
    try testing.expect(std.mem.indexOf(u8, block, "ga") != null);
}

test "grid clamping preserves the full bounded viewport" {
    const clamped = grid.Session.clampGrid(4000, 4000);
    try testing.expectEqual(@as(u16, grid.max_cols), clamped.x);
    try testing.expectEqual(@as(u16, grid.max_rows), clamped.y);
    try testing.expectEqual(grid.max_cols * grid.max_rows, grid.max_cells);
    const tiny = grid.Session.clampGrid(1, 1);
    try testing.expectEqual(@as(u16, 2), tiny.x);
    try testing.expectEqual(@as(u16, 2), tiny.y);
}

test "a full multibyte viewport retains clusters beyond the paint text budget" {
    const session = try createSession(120, grid.max_rows);
    defer session.destroy();
    const dense_row = ("\xe2\x82\xac" ** 119) ++ "\r\n";
    for (0..92) |_| session.feed(dense_row);
    session.feed("BOTTOM");

    const snapshot = try session.snapshot(.{}, true, false);
    try testing.expect(session.snap_text_len > canvas.max_display_list_text_bytes);
    var saw_bottom = false;
    for (snapshot.rows) |row| for (row.cells) |cell| {
        if (std.mem.eql(u8, cell.cluster, "B")) saw_bottom = true;
    };
    try testing.expect(saw_bottom);
}

test "local terminals keep scrollback and selection state independent" {
    const sessions = try createSessions(20, 4);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);
    const first = model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    const second = model.provider.terminal(app.initialTerminalRef(1)) orelse return error.TestExpectedTerminal;

    for (0..20) |index| {
        var line: [24]u8 = undefined;
        first.session.feed(std.fmt.bufPrint(&line, "first {d}\r\n", .{index}) catch unreachable);
        second.session.feed(std.fmt.bufPrint(&line, "second {d}\r\n", .{index}) catch unreachable);
    }
    const second_offset = second.session.scrollbar().offset;
    first.session.scrollLines(-3);
    try testing.expect(first.session.scrollbar().offset != second_offset);
    try testing.expectEqual(second_offset, second.session.scrollbar().offset);

    first.session.beginSelection(false);
    first.session.moveSelection(1, -1, true);
    try testing.expect(first.session.selectionActive());
    try testing.expect(!second.session.selectionActive());
}

test "resize re-anchors an armed selection inside the new grid" {
    const session = try createSession(80, 24);
    defer session.destroy();

    // An armed selection with its caret deep in the old grid.
    session.beginSelection(false);
    session.select_head = .{ .x = 70, .y = 20 };
    session.select_anchor = session.select_head;
    try testing.expect(session.selectionActive());

    // Shrinking reflows every cell: coordinates into the old grid are
    // meaningless, so the caret re-anchors clamped inside the new one
    // and the stale range is dropped rather than copied.
    try testing.expect(session.resize(40, 12));
    try testing.expect(session.select_head.x < 40);
    try testing.expect(session.select_head.y < 12);
    try testing.expectEqual(session.select_head, session.select_anchor.?);

    // Selection machinery keeps working after the reflow.
    session.moveSelection(1, 0, true);
    try testing.expect(session.selectionActive());
    try testing.expect(session.select_head.x < 40);
}

test "reset clears the previous session's palette and dynamic color overrides" {
    const session = try createSession(80, 24);
    defer session.destroy();

    // A shell overrides a palette slot (OSC 4) and the dynamic colors
    // (OSC 10/11/12), then exits.
    session.feed("\x1b]4;1;rgb:ff/00/00\x07");
    session.feed("\x1b]10;rgb:12/34/56\x07");
    session.feed("\x1b]11;rgb:65/43/21\x07");
    session.feed("\x1b]12;rgb:ab/cd/ef\x07");
    try testing.expect(session.term.colors.palette.mask.count() > 0);
    try testing.expect(session.term.colors.foreground.override != null);
    try testing.expect(session.term.colors.background.override != null);
    try testing.expect(session.term.colors.cursor.override != null);

    // The restart reset drops every override — the next shell starts on
    // the theme's colors, never tinted by the session that ended.
    session.reset();
    try testing.expectEqual(@as(usize, 0), session.term.colors.palette.mask.count());
    try testing.expect(session.term.colors.foreground.override == null);
    try testing.expect(session.term.colors.background.override == null);
    try testing.expect(session.term.colors.cursor.override == null);
}

test "scrolling into history refreshes the semantic viewport text" {
    const session = try createSession(20, 4);
    defer session.destroy();
    // Ten numbered rows through a four-row viewport: six rows of
    // scrollback above the live screen.
    var row: usize = 0;
    while (row < 10) : (row += 1) {
        var buf: [16]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "row{d}\r\n", .{row}) catch unreachable;
        session.feed(line);
    }
    session.refreshScreenText();
    const bottom = try testing.allocator.dupe(u8, session.screenText());
    defer testing.allocator.free(bottom);
    try testing.expect(std.mem.indexOf(u8, bottom, "row9") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "row0") == null);

    // Scrolling to the top MOVES the viewport: what assistive tech
    // reads (and what the fingerprint hashes) must be the historical
    // rows now painted, never the bottom viewport left behind.
    session.scrollToTop();
    const top = session.screenText();
    try testing.expect(std.mem.indexOf(u8, top, "row0") != null);
    try testing.expect(std.mem.indexOf(u8, top, "row9") == null);
}

test "a failed selection serialization is an error, never a silent no-selection" {
    const session = try createSession(20, 4);
    defer session.destroy();
    session.feed("select me\r\n");
    session.beginSelection(false);
    session.moveSelection(5, 0, true);

    // Nothing selected reads as null...
    session.clearSelection();
    try testing.expectEqual(@as(?[:0]const u8, null), try session.selectionText(testing.allocator));

    // ...but an ACTIVE selection whose serialization cannot allocate is
    // an ERROR the caller must surface (the app keeps the selection and
    // reports the failed copy), never a silent "nothing selected".
    session.beginSelection(false);
    session.moveSelection(5, 0, true);
    try testing.expectError(error.OutOfMemory, session.selectionText(std.testing.failing_allocator));
}

test "wheel scrolling over the grid scrolls history" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    var line: [16]u8 = undefined;
    for (0..120) |index| {
        app_state.model.panes[0].session.feed(std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    const bottom_offset = app_state.model.panes[0].session.scrollbar().offset;
    try testing.expect(bottom_offset > 0);

    // Native tab chrome is outside every terminal hit target.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .scroll,
        .x = 100,
        .y = 30,
        .delta_y = app_state.model.panes[0].session.cell_height * 4,
    } });
    try testing.expectEqual(bottom_offset, app_state.model.panes[0].session.scrollbar().offset);

    // A trackpad swipe (several fractional deltas accumulating past one
    // cell) scrolls into history, like every terminal.
    const cell_h = app_state.model.panes[0].session.cell_height;
    const frame = app.paneFrames(&app_state.model, app_state.model.surface_size)[0];
    for (0..4) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .scroll,
            .x = frame.x + frame.width / 2,
            .y = frame.y + frame.height / 2,
            .delta_y = cell_h,
        } });
    }
    try testing.expect(app_state.model.panes[0].session.scrollbar().offset < bottom_offset);

    // Typing returns the viewport to the live screen.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .text_input,
        .text = "x",
    } });
    try testing.expectEqual(bottom_offset, app_state.model.panes[0].session.scrollbar().offset);
}

test "scrollback chords pause while a selection is armed" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Scrollback to move through, then arm a selection.
    var line: [16]u8 = undefined;
    for (0..120) |index| {
        app_state.model.panes[0].session.feed(std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try testing.expect(app_state.model.panes[0].selecting);

    // The selection's coordinates are viewport-relative and the
    // emulator range is absolute: scrolling under it would desync the
    // painted caret from the copyable text, so the chord is inert.
    const before = app_state.model.panes[0].session.scrollbar().offset;
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "home",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(before, app_state.model.panes[0].session.scrollbar().offset);

    // Selection dismissed, the same chord scrolls again.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "escape",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "home",
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(app_state.model.panes[0].session.scrollbar().offset != before);
}

test "an armed selection follows its text when output scrolls the screen" {
    const session = try createSession(20, 4);
    defer session.destroy();
    session.feed("alpha\r\nbeta\r\ngamma\r\n");
    // Select "beta" (row 1): anchor at the cursor, walk up and extend.
    session.beginSelection(false);
    session.moveSelection(0, -2, false);
    session.moveSelection(3, 0, true);
    const before = (try session.selectionText(testing.allocator)) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("beta", before);
    try testing.expectEqual(@as(u16, 1), session.select_head.y);

    // One more output line scrolls the live screen: the emulator's
    // absolute pins keep marking "beta", and the rebase moves the
    // caret with it — a copy still returns the text the caret names.
    session.feed("one\r\n");
    try testing.expect(session.rebaseSelection());
    try testing.expectEqual(@as(u16, 0), session.select_head.y);
    const after = (try session.selectionText(testing.allocator)) orelse return error.TestExpectedSelection;
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("beta", after);

    // Enough output pushes the range out of the viewport: the rebase
    // clears to the honest no-selection instead of desynchronizing.
    session.feed("two\r\nthree\r\n");
    try testing.expect(!session.rebaseSelection());
    try testing.expect(!session.selectionActive());
}

test "a selection anchors at the live cursor, not the last painted snapshot" {
    const session = try createSession(40, 6);
    defer session.destroy();
    // Output moves the cursor with NO paint in between: the anchor must
    // be the cell the cursor actually occupies (a stale render snapshot
    // would anchor at the origin).
    session.feed("hello");
    session.beginSelection(false);
    try testing.expectEqual(@as(u16, 5), session.select_anchor.?.x);
    try testing.expectEqual(@as(u16, 0), session.select_anchor.?.y);
}

test "PORT: snapshot projects live emulator state into a canvas.TerminalGrid" {
    // The load-bearing new code of the port: `Session.snapshot` must
    // hand the first-party painter a resolved snapshot that matches what
    // the emulator actually holds. If this is wrong, every pixel after
    // it is wrong, and nothing else in the port is worth testing.
    const session = try createSession(20, 4);
    defer session.destroy();

    session.feed("hi\r\n");
    const snap = try session.snapshot(.{}, true, false);

    try testing.expectEqual(@as(usize, 4), snap.rows.len);
    try testing.expectEqual(@as(usize, 20), snap.rows[0].cells.len);
    try testing.expectEqual(@as(u21, 'h'), snap.rows[0].cells[0].cp);
    try testing.expectEqual(@as(u21, 'i'), snap.rows[0].cells[1].cp);
    // An untouched cell carries no ink, per the TerminalCell contract.
    try testing.expectEqual(@as(u21, 0), snap.rows[0].cells[2].cp);
    // The cluster is the cell's UTF-8, staged in the session's arena.
    try testing.expectEqualStrings("h", snap.rows[0].cells[0].cluster);
    // The cursor advanced to row 1 after the CRLF.
    try testing.expect(snap.cursor != null);
    try testing.expectEqual(@as(u16, 1), snap.cursor.?.y);
}

test "PORT: snapshot slices stay valid across a repaint and do not grow" {
    // The painter's contract is that every slice is producer-owned and
    // outlives the build referencing it. We satisfy that with buffers
    // REUSED per frame rather than allocated per paint, so a second
    // snapshot must reset the text arena rather than append to it.
    const session = try createSession(20, 4);
    defer session.destroy();

    session.feed("aaa");
    const first = try session.snapshot(.{}, true, false);
    const first_len = session.snap_text_len;
    try testing.expect(first_len > 0);
    try testing.expectEqual(@as(u21, 'a'), first.rows[0].cells[0].cp);

    const second = try session.snapshot(.{}, true, false);
    try testing.expectEqual(first_len, session.snap_text_len);
    try testing.expectEqual(@as(u21, 'a'), second.rows[0].cells[0].cp);
}
