//! Terminal example tests: the emulator round trip (real cell state,
//! damage, palette honesty), the keyboard encoding paths, and the
//! acceptance story — a session recorded against the scriptable fake
//! pty replays fingerprint-identical offline, no shell present.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const app = @import("main.zig");
const grid = @import("grid.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

fn createSession(cols: u16, rows: u16) !*grid.Session {
    return grid.Session.create(std.heap.page_allocator, testing.io, cols, rows);
}

/// One emulator session per cockpit pane. Test code owns them the same
/// way `main` does: created before the app starts, destroyed after it.
fn createSessions(cols: u16, rows: u16) ![app.pane_count]*grid.Session {
    var sessions: [app.pane_count]*grid.Session = undefined;
    for (&sessions) |*slot| slot.* = try createSession(cols, rows);
    return sessions;
}

fn destroyModelSessions(model: *app.Model) void {
    for (&model.panes) |*pane| pane.session.destroy();
}

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

test "the grid paints real text runs with theme-derived ANSI and exact truecolor" {
    const session = try createSession(30, 4);
    defer session.destroy();
    session.feed("plain \x1b[31mred\x1b[0m \x1b[38;2;10;200;30mexact\x1b[0m\r\n");

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    const list = builder.displayList();

    var saw_plain = false;
    var saw_red = false;
    var saw_exact = false;
    for (list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.indexOf(u8, text.text, "plain") != null) {
                    saw_plain = true;
                    // Default fg is the theme text token.
                    try testing.expectEqual(tokens.colors.text.r, text.color.r);
                }
                if (std.mem.eql(u8, text.text, "red")) {
                    saw_red = true;
                    // ANSI red derives from the destructive token while
                    // the emulator palette entry is untouched.
                    try testing.expectApproxEqAbs(tokens.colors.destructive.r, text.color.r, 0.01);
                }
                if (std.mem.eql(u8, text.text, "exact")) {
                    saw_exact = true;
                    // Truecolor passes through exactly.
                    try testing.expectApproxEqAbs(@as(f32, 10.0 / 255.0), text.color.r, 0.002);
                    try testing.expectApproxEqAbs(@as(f32, 200.0 / 255.0), text.color.g, 0.002);
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_plain);
    try testing.expect(saw_red);
    try testing.expect(saw_exact);
}

test "the custom cursor fills only while focused and live" {
    const session = try createSession(20, 4);
    defer session.destroy();

    var focused_commands: [64]canvas.CanvasCommand = undefined;
    var focused_builder = canvas.Builder.init(&focused_commands);
    try grid.paint(session, &focused_builder, .{
        .frame = geometry.RectF.init(0, 0, 200, 100),
        .tokens = .{},
        .running = true,
        .focused = true,
        .selecting = false,
    });
    try expectCursorPaintKind(focused_builder.displayList(), .filled);

    var blurred_commands: [64]canvas.CanvasCommand = undefined;
    var blurred_builder = canvas.Builder.init(&blurred_commands);
    try grid.paint(session, &blurred_builder, .{
        .frame = geometry.RectF.init(0, 0, 200, 100),
        .tokens = .{},
        .running = true,
        .focused = false,
        .selecting = false,
    });
    try expectCursorPaintKind(blurred_builder.displayList(), .hollow);

    var ended_commands: [64]canvas.CanvasCommand = undefined;
    var ended_builder = canvas.Builder.init(&ended_commands);
    try grid.paint(session, &ended_builder, .{
        .frame = geometry.RectF.init(0, 0, 200, 100),
        .tokens = .{},
        .running = false,
        .focused = true,
        .selecting = false,
    });
    try expectCursorPaintKind(ended_builder.displayList(), .hollow);
}

test "a styled wide character's background covers both of its cells" {
    const session = try createSession(30, 4);
    defer session.destroy();
    // Red background behind a double-width glyph: ghostty styles only
    // the PRIMARY cell, so the spacer tail must extend the same run or
    // the right half renders on the default background.
    session.feed("\x1b[41m\xe7\x95\x8c\x1b[0m\r\n");

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    const cell_w = session.cell_width;
    var saw_two_cell_bg = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                // The ANSI-41 run: destructive-derived red, starting at
                // the row origin — its width must span BOTH cells.
                if (std.math.approxEqAbs(f32, fill.fill.color.r, tokens.colors.destructive.r, 0.01) and
                    fill.rect.x == 0 and fill.rect.width > cell_w * 1.5)
                {
                    saw_two_cell_bg = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_two_cell_bg);
}

test "the glyph budget degrades row-wise before the atlas can overflow" {
    const session = try createSession(30, 4);
    defer session.destroy();
    // Two rows of eight distinct CJK scalars each: sixteen distinct
    // code points total.
    session.feed("\xe4\xb8\x80\xe4\xba\x8c\xe4\xb8\x89\xe5\x9b\x9b\xe4\xba\x94\xe5\x85\xad\xe4\xb8\x83\xe5\x85\xab\r\n");
    session.feed("\xe4\xb9\x9d\xe5\x8d\x81\xe7\x99\xbe\xe5\x8d\x83\xe4\xb8\x87\xe5\x84\x84\xe5\x85\x86\xe4\xba\xac\r\n");

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    // Ten distinct code points allowed: the first row's eight fit, the
    // second row's eight would cross — painting stops BEFORE it instead
    // of failing the whole frame at the atlas. The budget is stated in
    // ATLAS ENTRIES, and the painter charges four subpixel variants per
    // distinct code point, so ten code points is forty entries.
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .glyph_budget = 40,
    });
    var saw_first = false;
    var saw_second = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.indexOf(u8, text.text, "\xe4\xb8\x80") != null) saw_first = true;
                if (std.mem.indexOf(u8, text.text, "\xe4\xb9\x9d") != null) saw_second = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_first);
    try testing.expect(!saw_second);
}

test "a grapheme cluster the emulator holds paints whole - down to the last mark" {
    const session = try createSession(30, 4);
    defer session.destroy();
    // One cell: base + 200 combining acutes + a final enclosing mark.
    // The paint scratch is sized to the WHOLE display-list text store,
    // so any cluster the emulator can hold emits complete — the paint
    // tier is never the binding constraint. (The pinned emulator's own
    // grapheme storage bounds a cluster at roughly 256 scalars; the
    // scratch stays store-sized so larger clusters keep painting whole
    // as that bound moves.)
    const cluster = "a" ++ ("\u{0301}" ** 200) ++ "\u{20DD}";
    session.feed(cluster);

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .running = true,
        .selecting = false,
    });
    var saw_full_cluster = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (text.text.len >= cluster.len and std.mem.indexOf(u8, text.text, cluster) != null) {
                    saw_full_cluster = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_full_cluster);
}

test "a concealed row never blanks the rows painted after it" {
    const session = try createSession(80, 6);
    defer session.destroy();
    // Row 0: sixty concealed cells (SGR 8) — painting emits NO text for
    // them. Row 1: ordinary visible text.
    session.feed("\x1b[8m" ++ ("x" ** 60) ++ "\x1b[0m\r\nvisible\r\n");

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    // Squeeze the text store to less than the concealed row's RAW bytes
    // (but comfortably over the visible row's): a preflight that counts
    // suppressed bytes measures row 0 past the budget, stops painting
    // there, and silently blanks every row after — including "visible",
    // which fits with room to spare.
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 800, 200),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .text_reserve = canvas.max_display_list_text_bytes - 32,
    });
    var saw_visible = false;
    var saw_concealed = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.indexOf(u8, text.text, "visible") != null) saw_visible = true;
                if (std.mem.indexOf(u8, text.text, "x") != null) saw_concealed = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_visible);
    try testing.expect(!saw_concealed);
}

test "inverse video paints text in the background color, not on itself" {
    const session = try createSession(20, 3);
    defer session.destroy();
    // Default colors, reverse-video on: the text must read as the theme
    // background painted over the theme foreground, never foreground on
    // an identical foreground (invisible).
    session.feed("\x1b[7mREV\x1b[0m\r\n");

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    var saw_rev = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| if (std.mem.eql(u8, text.text, "REV")) {
                saw_rev = true;
                // Text is the background token; distinctly not the fg.
                try testing.expectApproxEqAbs(tokens.colors.background.r, text.color.r, 0.01);
                try testing.expect(text.color.r != tokens.colors.text.r);
            },
            else => {},
        }
    }
    try testing.expect(saw_rev);
}

test "the grid never emits past its command budget" {
    const session = try createSession(80, 24);
    defer session.destroy();
    // A worst case for run-merging: alternate the foreground every cell
    // so no two adjacent cells share a style and every cell is its own
    // run. The budget must still hold.
    var line: [512]u8 = undefined;
    for (0..24) |_| {
        var w: usize = 0;
        for (0..80) |col| {
            const code: u8 = if (col % 2 == 0) 31 else 32;
            w += (std.fmt.bufPrint(line[w..], "\x1b[{d}mX", .{code}) catch break).len;
        }
        session.feed(line[0..w]);
        session.feed("\r\n");
    }
    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 900, 560),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .command_budget = 1700,
    });
    try testing.expect(builder.displayList().commands.len <= 1700);
}

test "an OSC 4 palette override is honored even when it equals the default RGB" {
    const session = try createSession(20, 3);
    defer session.destroy();
    const default_red = vt.color.default[1];
    // OSC 4: set ANSI 1 (red) to EXACTLY the emulator's default red RGB,
    // then print red text. RGB equality with the default must not fool
    // the renderer into substituting the theme color — the override
    // mask says the program chose it.
    var seq: [64]u8 = undefined;
    session.feed(std.fmt.bufPrint(&seq, "\x1b]4;1;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x07", .{ default_red.r, default_red.g, default_red.b }) catch unreachable);
    session.feed("\x1b[31mR\x1b[0m\r\n");

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    const tokens: canvas.DesignTokens = .{};
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = tokens,
        .running = true,
        .selecting = false,
    });
    var saw = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| if (std.mem.eql(u8, text.text, "R")) {
                saw = true;
                // The live (overridden) RGB, not the theme destructive.
                try testing.expectApproxEqAbs(@as(f32, @floatFromInt(default_red.r)) / 255.0, text.color.r, 0.004);
                try testing.expect(text.color.r != tokens.colors.destructive.r);
            },
            else => {},
        }
    }
    try testing.expect(saw);
}

test "grid clamping trades rows for columns inside the cell budget" {
    const clamped = grid.Session.clampGrid(4000, 4000, grid.max_cells);
    try testing.expect(@as(usize, clamped.x) <= grid.max_cols);
    try testing.expect(@as(usize, clamped.y) <= grid.max_rows);
    try testing.expect(@as(usize, clamped.x) * @as(usize, clamped.y) <= grid.max_cells);
    const tiny = grid.Session.clampGrid(1, 1, grid.max_cells);
    try testing.expectEqual(@as(u16, 2), tiny.x);
    try testing.expectEqual(@as(u16, 2), tiny.y);
}

// ------------------------------------------------- record/replay pinned

const TerminalApp = native_sdk.UiApp(app.Model, app.Msg);

const CursorPaintKind = enum { filled, hollow };

fn expectCursorPaintKind(display_list: anytype, expected: CursorPaintKind) !void {
    return expectPaneCursorPaintKind(display_list, 0, expected);
}

/// The cursor cue of ONE pane: each pane's cursor carries its own id
/// (`cursorCommandId(paneIdBase(i))`), which is how the retained diff
/// keeps two cursors apart and how a test can tell which pane the
/// keyboard belongs to.
fn expectPaneCursorPaintKind(display_list: anytype, index: usize, expected: CursorPaintKind) !void {
    const id = grid.cursorCommandId(grid.paneIdBase(index));
    const command = display_list.findCommandById(id) orelse return error.TestExpectedCursor;
    switch (command.command) {
        .fill_rect => try testing.expectEqual(CursorPaintKind.filled, expected),
        .stroke_rect => try testing.expectEqual(CursorPaintKind.hollow, expected),
        else => return error.TestUnexpectedCursorCommand,
    }
}

const JournalBuffer = struct {
    bytes: [512 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) native_sdk.runtime.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Drive one recorded terminal session against the scriptable fake pty:
/// spawn (init_fx), a prompt, typed input (echoed by the script), and
/// the exit. Returns the recorded model and the state fingerprint.
const RecordedTerminalSession = struct {
    fingerprint: u64,
    screen: [256]u8 = undefined,
    screen_len: usize = 0,
};

fn recordTerminalSession(
    gpa: std.mem.Allocator,
    buffer: *JournalBuffer,
    store: *native_sdk.runtime.session_blobs.MemoryBlobStore,
) !RecordedTerminalSession {
    const recorder = try std.heap.page_allocator.create(native_sdk.runtime.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = native_sdk.runtime.SessionRecorder.init(buffer.sink());
    recorder.blob_sink = store.sink();
    recorder.begin(.{ .platform_name = "test", .app_name = "terminal", .window_width = 980, .window_height = 640 });

    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.session_recorder = recorder;

    const sessions = try createSessions(80, 24);
    const session = sessions[0];
    defer for (sessions) |each| each.destroy();
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();

    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // init_fx spawned the shell against the fake pty.
    try testing.expectEqual(@as(usize, app.pane_count), app_state.effects.pendingPtyCount());

    // The scripted shell: prompt, then a typed command's echo + output.
    try app_state.effects.feedPtyOutput(1, "demo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.Phase.live, app_state.model.panes[0].phase);

    // Focus the surface with a click (a real session focuses on first
    // click/key), then type: committed text routes to the app as
    // target-less text.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "ls",
    } });
    try testing.expectEqualStrings("ls", app_state.effects.ptyWrittenBytes(1));
    try app_state.effects.feedPtyOutput(1, "ls\r\nREADME.md  src\r\ndemo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // The session ends.
    try app_state.effects.feedPtyExit(1, 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);

    recorder.finish();
    try testing.expect(!recorder.failed);

    var result: RecordedTerminalSession = .{
        .fingerprint = harness.runtime.sessionStateFingerprint(),
    };
    const screen = try session.plainText(gpa);
    defer gpa.free(screen);
    result.screen_len = @min(screen.len, result.screen.len);
    @memcpy(result.screen[0..result.screen_len], screen[0..result.screen_len]);
    return result;
}

test "typing reaches the pty before the first output batch (empty-prompt shell)" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;

    const sessions = try createSessions(80, 24);
    defer for (sessions) |each| each.destroy();
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app_state.deinit();
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();

    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // The shell spawned (init_fx) but produced NO output — phase is
    // still .starting, never .live. Typing must still reach the pty.
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "whoami",
    } });
    try testing.expectEqualStrings("whoami", app_state.effects.ptyWrittenBytes(1));
}

fn startFocusedTerminal(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    const sessions = try createSessions(80, 24);
    const app_state = try gpa.create(TerminalApp);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    // Focus the surface with a click.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    return app_state;
}

test "terminal lifecycle focus rebuilds the custom cursor fill" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try testing.expect(app_state.model.focused);
    try expectCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), .filled);

    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);
    try testing.expect(!app_state.model.focused);
    try expectCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), .hollow);

    try harness.runtime.dispatchPlatformEvent(app_iface, .app_activated);
    try testing.expect(app_state.model.focused);
    try expectCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), .filled);
}

test "IME: a preedit is provisional; only the commit reaches the pty" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Compose Japanese: the preedit must NOT reach the pty (provisional).
    try harness.runtime.dispatchPlatformEvent(app_iface, .{
        .gpu_surface_input = .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .ime_set_composition,
            .text = "\xe3\x81\x8b", // か
        },
    });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // The host commits the marked text UNCHANGED — an empty commit; the
    // composed bytes come from the buffered preedit and reach the pty.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .ime_commit_composition,
        .text = "",
    } });
    try testing.expectEqualStrings("\xe3\x81\x8b", app_state.effects.ptyWrittenBytes(1));
}

test "IME: composition keys never encode into the pty - and the commit releases them" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // DURING the composition, keys belong to the input method: the
    // candidate-navigation arrow and the confirming Enter (which hosts
    // that surface the key before the commit deliver mid-composition)
    // must not reach the emulator's encoder — a CR here would submit
    // the half-composed command.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .ime_set_composition,
        .text = "\xe3\x81\x8b",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // The commit inserts the composed bytes and RELEASES the keys: a
    // candidate can be committed by mouse in the OS popup with no
    // trailing key at all, so the next Enter is genuine typing and
    // encodes CR.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .ime_commit_composition,
        .text = "",
    } });
    try testing.expectEqualStrings("\xe3\x81\x8b", app_state.effects.ptyWrittenBytes(1));
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try testing.expectEqualStrings("\xe3\x81\x8b\r", app_state.effects.ptyWrittenBytes(1));
}

test "a command-chorded text event never types a literal character into the pty" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Some hosts emit a text_input alongside a Ctrl/Cmd shortcut. The
    // chord is not typing: the runtime's text gate (the focused-widget
    // rule, applied target-less too) must stop the literal "c" — the
    // child sees the ENCODED control byte from the key channel only,
    // never the chord plus a stray character.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .key = "c",
        .text = "c",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // Unmodified typing still flows.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "c",
    } });
    try testing.expectEqualStrings("c", app_state.effects.ptyWrittenBytes(1));
}

test "typing carried on the key event reaches the pty - the no-separate-text-event host shape" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Hosts without a separate text event for plain typing deliver the
    // printable on the key_down itself; the committed-text channel must
    // carry it to the pty or typing is silently lost there.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "j",
        .text = "j",
    } });
    try testing.expectEqualStrings("j", app_state.effects.ptyWrittenBytes(1));
}

test "kitty report-all encodes committed text as CSI-u, and legacy passes it raw" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Legacy mode first: a committed "a" reaches the child as the raw
    // byte, exactly as before the encoder routing.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "a",
    } });
    try testing.expectEqualStrings("a", app_state.effects.ptyWrittenBytes(1));

    // The TUI pushes kitty "report all keys as escape codes": the same
    // committed "a" must now encode as CSI 97 u — raw bytes would
    // desynchronize the application's key decoding.
    app_state.model.panes[0].session.feed("\x1b[>8u");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "a",
    } });
    const written = app_state.effects.ptyWrittenBytes(1);
    try testing.expect(std.mem.endsWith(u8, written, "\x1b[97u"));
}

test "kitty event reporting hears key releases; legacy modes never do" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Legacy: a release encodes nothing.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_up,
        .key = "enter",
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // The TUI enables kitty event reporting (with report-all): the
    // release of a printable now reaches the child as a CSI-u release
    // event (`:3` event type) — without it, key-driven state sticks.
    app_state.model.panes[0].session.feed("\x1b[>11u");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "a",
        .text = "a",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_up,
        .key = "a",
    } });
    const written = app_state.effects.ptyWrittenBytes(1);
    try testing.expect(std.mem.indexOf(u8, written, ":3u") != null);
}

test "a second copy while the write is in flight is a no-op, never a false failure" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    app_state.model.panes[0].session.feed("copy me");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .shift = true },
    } });
    // Enter twice before the async result drains: the second press must
    // not issue a duplicate-key request whose rejection would overwrite
    // the first copy's success.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try app_state.effects.feedClipboardResult(app.clipboard_key, .ok, "");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(!app_state.model.panes[0].copy_failed);
    try testing.expect(!app_state.model.panes[0].selecting);
    try testing.expect(!app_state.model.copy_inflight);
}

test "chorded punctuation and function keys encode their control sequences" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Ctrl+\ is SIGQUIT to a terminal user — chorded punctuation has no
    // text-channel fallback, so the encoder must speak or the control
    // byte is silently lost. The emulator's legacy encoding maps it to
    // the FS control byte (0x1C).
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "\\",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("\x1c", app_state.effects.ptyWrittenBytes(1));

    // Ctrl+[ rides the emulator's fixterms CSI-u encoding (the ESC
    // chord stays distinguishable from a bare Escape press) — the same
    // bytes the emulator's own terminal sends for this chord.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "[",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("\x1c\x1b[91;5u", app_state.effects.ptyWrittenBytes(1));

    // F1 encodes its escape sequence (ESC O P) — function keys commit
    // no text, so the encoder is their only road to the child.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "f1",
    } });
    try testing.expectEqualStrings("\x1c\x1b[91;5u\x1bOP", app_state.effects.ptyWrittenBytes(1));
}

test "a primary-aliased Ctrl chord still encodes its C0 byte" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Hosts whose PRIMARY modifier is Ctrl report a bare Ctrl chord
    // with BOTH bits set; the runtime folds primary into `super`. The
    // encoder must still see a clean Ctrl+C and emit ETX (0x03) — a
    // stray super would demote it to a CSI-u chord the foreground shell
    // never treats as an interrupt.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "c",
        .modifiers = .{ .control = true, .primary = true },
    } });
    try testing.expectEqualStrings("\x03", app_state.effects.ptyWrittenBytes(1));
}

test "macOS natural text arrow gestures use shell editing bindings" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Keep the platform-native bindings even after a TUI enables kitty
    // event reporting: Option moves by words (Esc-b/f), Command moves to
    // line boundaries (Ctrl-A/E), Command+Delete clears to the start
    // (Ctrl-U), and a bound release emits nothing.
    app_state.model.panes[0].session.feed("\x1b[>11u");
    const events = [_]native_sdk.platform.GpuSurfaceInputEvent{
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_down,
            .key = "arrowleft",
            .modifiers = .{ .option = true },
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_up,
            .key = "arrowleft",
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_down,
            .key = "arrowright",
            .modifiers = .{ .option = true },
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_up,
            .key = "arrowright",
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_down,
            .key = "arrowleft",
            .modifiers = .{ .primary = true, .command = true },
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_up,
            .key = "arrowleft",
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_down,
            .key = "arrowright",
            .modifiers = .{ .primary = true, .command = true },
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_up,
            .key = "arrowright",
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_down,
            .key = "backspace",
            .modifiers = .{ .primary = true, .command = true },
        },
        .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .key_up,
            .key = "backspace",
        },
    };
    for (events) |event| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = event });
    }
    try testing.expectEqualStrings("\x1bb\x1bf\x01\x05\x15", app_state.effects.ptyWrittenBytes(1));
}

test "stdin order holds: a retained reply reaches the child before newer typing" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const session = app_state.model.panes[0].session;

    // A DSR reply is generated while the ring is full: retained.
    session.feed("\x1b[6n");
    const reply = try gpa.dupe(u8, session.pendingResponses());
    defer gpa.free(reply);
    app_state.effects.fake_pty_write_full = true;
    app_state.model.panes[0].outbound_len = app_state.model.panes[0].outbound_buffer.len;
    app.moveResponsesToOutbound(&app_state.model.panes[0], &app_state.effects);
    try testing.expectEqual(reply.len, session.pendingResponses().len);

    // Typing while the reply is stuck must not jump the stdin queue:
    // the keystroke drops counted, the reply stays first in line.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "y",
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));
    try testing.expectEqual(@as(u64, 1), app_state.model.panes[0].outbound_dropped);
    try testing.expectEqual(reply.len, session.pendingResponses().len);

    // The ring frees (the child read): the next keystroke moves the
    // retained reply FIRST, then itself — the child's stdin order.
    app_state.effects.fake_pty_write_full = false;
    app_state.model.panes[0].outbound_len = 0;
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "x",
    } });
    const written = app_state.effects.ptyWrittenBytes(1);
    try testing.expectEqual(reply.len + 1, written.len);
    try testing.expect(std.mem.startsWith(u8, written, reply));
    try testing.expect(std.mem.endsWith(u8, written, "x"));
    try testing.expectEqual(@as(usize, 0), session.pendingResponses().len);
}

test "retained replies keep accumulating while further output feeds - the buffer grows" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const session = app_state.model.panes[0].session;

    // The outbound ring is full and the child keeps pipelining DSR
    // queries — more reply bytes than the buffer's initial capacity.
    // Every reply must accumulate (the buffer grows), none dropped:
    // clearing or dropping would strand a child blocked on an answer.
    app_state.effects.fake_pty_write_full = true;
    app_state.model.panes[0].outbound_len = app_state.model.panes[0].outbound_buffer.len;
    const burst = "\x1b[6n" ** 6000; // ~36 KiB of replies, > 16 KiB initial
    session.feed(burst);
    app.moveResponsesToOutbound(&app_state.model.panes[0], &app_state.effects);
    try testing.expectEqual(@as(u32, 0), session.responses_dropped);
    try testing.expect(session.pendingResponses().len > grid.Session.response_capacity);

    // The ring drains; the whole accumulated batch moves and clears.
    app_state.effects.fake_pty_write_full = false;
    app_state.model.panes[0].outbound_len = 0;
    app.moveResponsesToOutbound(&app_state.model.panes[0], &app_state.effects);
    try testing.expectEqual(@as(usize, 0), session.pendingResponses().len);
    try testing.expectEqual(@as(u64, 0), app_state.model.panes[0].outbound_dropped);
}

test "a query reply refused by a full ring is retained and retried, never cleared" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    // The child pipelines a DSR query; its reply waits in the
    // emulator's buffer. With the pending ring full RIGHT NOW, the move
    // must leave the reply IN PLACE — clearing it would strand a child
    // blocked on the answer.
    app_state.model.panes[0].session.feed("\x1b[6n");
    const reply_len = app_state.model.panes[0].session.pendingResponses().len;
    try testing.expect(reply_len > 0);
    app_state.effects.fake_pty_write_full = true;
    app_state.model.panes[0].outbound_len = app_state.model.panes[0].outbound_buffer.len;
    app.moveResponsesToOutbound(&app_state.model.panes[0], &app_state.effects);
    try testing.expectEqual(reply_len, app_state.model.panes[0].session.pendingResponses().len);
    try testing.expectEqual(@as(u64, 0), app_state.model.panes[0].outbound_dropped);

    // The ring drains (the child read); the retry moves the reply whole
    // and it reaches the pty.
    app_state.effects.fake_pty_write_full = false;
    app_state.model.panes[0].outbound_len = 0;
    app.moveResponsesToOutbound(&app_state.model.panes[0], &app_state.effects);
    try testing.expectEqual(@as(usize, 0), app_state.model.panes[0].session.pendingResponses().len);
    const written = app_state.effects.ptyWrittenBytes(1);
    try testing.expectEqual(reply_len, written.len);
    try testing.expect(std.mem.startsWith(u8, written, "\x1b["));
}

test "session exit counts retained reply bytes as loss, never silent" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // A DSR reply waits retained when the child dies: those bytes can
    // never land, so they count as outbound loss — a zero tally over
    // vanished bytes would misreport the session as lossless.
    app_state.model.panes[0].session.feed("\x1b[6n");
    const reply_len = app_state.model.panes[0].session.pendingResponses().len;
    try testing.expect(reply_len > 0);
    try app_state.effects.feedPtyExit(1, 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(u64, reply_len), app_state.model.panes[0].outbound_dropped);
    try testing.expectEqual(@as(usize, 0), app_state.model.panes[0].session.pendingResponses().len);
}

test "a payload the outbound ring cannot hold whole is dropped whole, never torn" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // One committed payload larger than the whole pending ring: a
    // prefix cut at the ring edge could tear an escape sequence, so
    // admission is all-or-nothing — dropped whole and counted, nothing
    // queued, nothing written.
    const oversized = try gpa.alloc(u8, app_state.model.panes[0].outbound_buffer.len + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'z');
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = oversized,
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));
    try testing.expectEqual(@as(u64, oversized.len), app_state.model.panes[0].outbound_dropped);

    // The stream is intact past the drop: the next keystroke flows.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "ok",
    } });
    try testing.expectEqualStrings("ok", app_state.effects.ptyWrittenBytes(1));
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

test "restart during starting is a no-op - the original session is not duplicated" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Still .starting (no output yet), one live pty. Cmd+R must not
    // respawn onto the occupied key.
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(usize, app.pane_count), app_state.effects.pendingPtyCount());
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(usize, app.pane_count), app_state.effects.pendingPtyCount());
}

test "a restarted shell starts its refused-write tally at zero" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // The first session ends with transport drops on record: the exit
    // carries them into the model, where the status tally renders them.
    try app_state.effects.feedPtyOutput(1, "demo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try app_state.effects.feedPtyExit(1, 0, 0, .exited, 3);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(u32, 3), app_state.model.panes[0].dropped_writes);

    // Cmd+R: the new shell's tally is its own — zero, not the dead
    // session's drops.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(u32, 0), app_state.model.panes[0].dropped_writes);
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

    // A trackpad swipe (several fractional deltas accumulating past one
    // cell) scrolls into history, like every terminal.
    const cell_h = app_state.model.panes[0].session.cell_height;
    for (0..4) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .scroll,
            .delta_y = cell_h,
        } });
    }
    try testing.expect(app_state.model.panes[0].session.scrollbar().offset < bottom_offset);

    // Typing returns the viewport to the live screen.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = "x",
    } });
    try testing.expectEqual(bottom_offset, app_state.model.panes[0].session.scrollbar().offset);
}

test "box-drawing cells render as edge-to-edge geometry, never glyphs" {
    const session = try createSession(30, 4);
    defer session.destroy();
    // A border fragment: two joined horizontals, a corner, a vertical,
    // and a shade.
    session.feed("\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\r\n\xe2\x94\x82 \xe2\x96\x92\r\n"); // ┌── / │ ▒

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .running = true,
        .selecting = false,
    });
    const cell_w = session.cell_width;
    const cell_h = session.cell_height;
    var box_texts: usize = 0;
    var merged_bar = false;
    var full_height_bar = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |text| {
                // No box character ever reaches a font glyph.
                if (std.mem.indexOf(u8, text.text, "\xe2\x94") != null) box_texts += 1;
                if (std.mem.indexOf(u8, text.text, "\xe2\x96") != null) box_texts += 1;
            },
            .fill_rect => |fill| {
                // The two `─` cells merged into ONE bar spanning both,
                // continuing seamlessly from the corner's stub.
                if (fill.rect.width > cell_w * 1.9 and fill.rect.height < cell_h) merged_bar = true;
                // The `│` runs the FULL cell height - rows abut, so
                // stacked bars join with no seam.
                if (fill.rect.height == cell_h and fill.rect.width < cell_w) full_height_bar = true;
            },
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 0), box_texts);
    try testing.expect(merged_bar);
    try testing.expect(full_height_bar);
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
        .label = "terminal-canvas",
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
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "home",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(before, app_state.model.panes[0].session.scrollbar().offset);

    // Selection dismissed, the same chord scrolls again.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "escape",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "home",
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(app_state.model.panes[0].session.scrollbar().offset != before);
}

test "a selection outlives the copy until the clipboard confirms" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    app_state.model.panes[0].session.feed("copy me");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .shift = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    // The write is in flight: the selection must still stand — a failed
    // result needs something to retry.
    try testing.expect(app_state.model.panes[0].selecting);
    try testing.expect(app_state.model.panes[0].session.selectionActive());

    // A FAILED write keeps it and reports; a retry that succeeds clears.
    try app_state.effects.feedClipboardResult(app.clipboard_key, .rejected, "");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(app_state.model.panes[0].copy_failed);
    try testing.expect(app_state.model.panes[0].selecting);
    try testing.expect(app_state.model.panes[0].session.selectionActive());
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    try app_state.effects.feedClipboardResult(app.clipboard_key, .ok, "");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(!app_state.model.panes[0].copy_failed);
    try testing.expect(!app_state.model.panes[0].selecting);
    try testing.expect(!app_state.model.panes[0].session.selectionActive());
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

test "a copy over a vanished emulator range reports failure, never a quiet no-op" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    app_state.model.panes[0].session.feed("some text\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try testing.expect(app_state.model.panes[0].selecting);

    // Simulate a failed selection re-pin: the emulator range vanished
    // while the model still holds its anchor (`applySelection` clears
    // the highlight when it cannot pin).
    app_state.model.panes[0].session.term.screens.active.clearSelection();
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = "c",
        .modifiers = .{ .primary = true },
    } });
    try testing.expect(app_state.model.panes[0].copy_failed);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));
}

test "painted-output oracle: the prompt and caret reach the surface as pixels" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // The shell prompt arrives (the transport working is NOT the test —
    // the pixels are).
    try app_state.effects.feedPtyOutput(1, "demo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // Render the retained frame HEADLESS through the same machinery the
    // damage oracles use, at scale 1 so a pixel is a point.
    const width: usize = 980;
    const height: usize = 640;
    const pixels = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(scratch);
    const render_commands = try gpa.alloc(canvas.RenderCommand, 4096);
    defer gpa.free(render_commands);
    const render_batches = try gpa.alloc(canvas.RenderBatch, 512);
    defer gpa.free(render_batches);
    const resources = try gpa.alloc(canvas.RenderResource, 1024);
    defer gpa.free(resources);
    const resource_cache_entries = try gpa.alloc(canvas.RenderResourceCacheEntry, 1024);
    defer gpa.free(resource_cache_entries);
    const resource_cache_actions = try gpa.alloc(canvas.RenderResourceCacheAction, 2048);
    defer gpa.free(resource_cache_actions);
    const glyphs = try gpa.alloc(canvas.GlyphAtlasEntry, 8192);
    defer gpa.free(glyphs);
    const glyph_cache_entries = try gpa.alloc(canvas.GlyphAtlasCacheEntry, 8192);
    defer gpa.free(glyph_cache_entries);
    const glyph_cache_actions = try gpa.alloc(canvas.GlyphAtlasCacheAction, 16384);
    defer gpa.free(glyph_cache_actions);
    const text_layout_plans = try gpa.alloc(canvas.TextLayoutPlan, 2048);
    defer gpa.free(text_layout_plans);
    const text_layout_lines = try gpa.alloc(canvas.TextLine, 4096);
    defer gpa.free(text_layout_lines);
    const changes = try gpa.alloc(canvas.DiffChange, 4096);
    defer gpa.free(changes);
    _ = try harness.runtime.presentNextCanvasFramePixels(1, "terminal-canvas", .{
        .frame_index = 2,
        .surface_size = geometry.SizeF.init(@floatFromInt(width), @floatFromInt(height)),
        .scale = 1,
    }, .{
        .render_commands = render_commands,
        .render_batches = render_batches,
        .resources = resources,
        .resource_cache_entries = resource_cache_entries,
        .resource_cache_actions = resource_cache_actions,
        .glyph_atlas_entries = glyphs,
        .glyph_atlas_cache_entries = glyph_cache_entries,
        .glyph_atlas_cache_actions = glyph_cache_actions,
        .text_layout_plans = text_layout_plans,
        .text_layout_lines = text_layout_lines,
        .changes = changes,
    }, pixels, scratch, canvas.Color.rgb8(0, 0, 0));
    // (i) The prompt's cell band holds INK: pixels that differ from the
    // grid background. The first text row starts at the grid origin;
    // sample generously across the first cell row.
    const session = app_state.model.panes[0].session;
    const cell_w: usize = @intFromFloat(@max(1, session.cell_width));
    const cell_h: usize = @intFromFloat(@max(1, session.cell_height));
    // The window is titlebar + grid: the grid starts at its inset.
    const grid_x: usize = 8;
    const grid_y: usize = 8;
    var band_colors = std.AutoHashMap(u32, void).init(gpa);
    defer band_colors.deinit();
    var y: usize = grid_y;
    while (y < grid_y + cell_h) : (y += 1) {
        var x: usize = grid_x;
        while (x < grid_x + cell_w * 8) : (x += 1) {
            const offset = (y * width + x) * 4;
            const value = std.mem.readInt(u32, pixels[offset..][0..4], .little);
            try band_colors.put(value, {});
        }
    }
    // Background alone is one color; ink adds more (glyph coverage is
    // antialiased, so ink contributes MANY distinct values — demand a
    // handful so a single stray pixel cannot pass).
    try testing.expect(band_colors.count() >= 4);

    // (ii) The caret cell paints distinguishably: the cursor sits right
    // after "demo$ " (column 6) and its wash differs from both the
    // background and the row's empty cells.
    const caret_x: usize = @intFromFloat(8.0 + 6.5 * session.cell_width);
    const caret_y = grid_y + cell_h / 2;
    const caret_offset = (caret_y * width + caret_x) * 4;
    const caret_value = std.mem.readInt(u32, pixels[caret_offset..][0..4], .little);
    const empty_x: usize = @intFromFloat(8.0 + 40.0 * session.cell_width);
    const empty_offset = (caret_y * width + empty_x) * 4;
    const empty_value = std.mem.readInt(u32, pixels[empty_offset..][0..4], .little);
    try testing.expect(caret_value != empty_value);
}

test "the session fingerprint covers real cells, not just byte counters" {
    const gpa = testing.allocator;
    // Two sessions fed the SAME number of output bytes with different
    // contents: identical counters, different screens. The grid's
    // accessibility surface carries the viewport text, so the state
    // fingerprint (the a11y-tree hash) must differ — a VT regression
    // that garbles cells while preserving lengths can never verify.
    var fingerprints: [2]u64 = undefined;
    const outputs = [2][]const u8{ "demo$ AB", "demo$ BA" };
    for (outputs, 0..) |output, index| {
        const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
        defer harness.destroy(gpa);
        const app_state = try startFocusedTerminal(gpa, harness);
        defer gpa.destroy(app_state);
        defer destroyModelSessions(&app_state.model);
        defer app_state.deinit();
        const app_iface = app_state.app();
        try app_state.effects.feedPtyOutput(1, output);
        try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
        try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
        fingerprints[index] = harness.runtime.sessionStateFingerprint();
        try testing.expect(fingerprints[index] != 0);
    }
    try testing.expect(fingerprints[0] != fingerprints[1]);
}

test "a recorded terminal session replays byte-identical offline - no shell present" {
    const gpa = testing.allocator;
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    var store = native_sdk.runtime.session_blobs.MemoryBlobStore.init(gpa);
    defer store.deinit();

    const recorded = try recordTerminalSession(gpa, buffer, &store);
    try testing.expect(std.mem.indexOf(u8, recorded.screen[0..recorded.screen_len], "README.md") != null);

    // Replay into a FRESH emulator and app: the journal (events) plus
    // the blob store (output bytes) are the whole world.
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    const sessions = try createSessions(80, 24);
    const session = sessions[0];
    defer for (sessions) |each| each.destroy();
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app_state.deinit();

    const report = try native_sdk.runtime.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
        .blobs = store.source(),
    });
    try testing.expect(report.ok());
    try testing.expect(report.checkpoints_verified > 0);
    // No process ran: the replayed spawn parked, four journaled
    // results fed (two output batches, the typed input's write-admission
    // verdict, one exit).
    try testing.expectEqual(@as(u64, 4), report.effects_fed);
    try testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());

    // The replayed emulator rebuilt the identical screen from the
    // blob-store bytes — byte-identical, offline.
    const screen = try session.plainText(gpa);
    defer gpa.free(screen);
    try testing.expectEqualStrings(recorded.screen[0..recorded.screen_len], screen[0..recorded.screen_len]);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
}

// ------------------------------------------------------- cockpit: two panes

const automation = native_sdk.automation;

/// Distinct baseline rows among a display-list slice's text commands —
/// how many grid rows a paint actually put on screen.
fn distinctTextRows(commands: []const canvas.CanvasCommand) usize {
    var rows: [128]f32 = undefined;
    var count: usize = 0;
    outer: for (commands) |command| {
        switch (command) {
            .draw_text => |text| {
                for (rows[0..count]) |seen| {
                    if (seen == text.origin.y) continue :outer;
                }
                if (count < rows.len) {
                    rows[count] = text.origin.y;
                    count += 1;
                }
            },
            else => {},
        }
    }
    return count;
}

/// A pane's worst case for run merging: every cell its own style, so no
/// two adjacent cells share a run.
fn feedAdversarialRows(session: *grid.Session, cols: usize, rows: usize) void {
    var line: [1024]u8 = undefined;
    for (0..rows) |_| {
        var w: usize = 0;
        for (0..cols) |col| {
            const code: u8 = if (col % 2 == 0) 31 else 32;
            w += (std.fmt.bufPrint(line[w..], "\x1b[{d}mX", .{code}) catch break).len;
        }
        session.feed(line[0..w]);
        session.feed("\r\n");
    }
}

test "two panes paint into distinct id namespaces the diff accepts" {
    const sessions = try createSessions(20, 6);
    defer for (sessions) |each| each.destroy();
    sessions[0].feed("PANEALPHA\r\n");
    sessions[1].feed("PANEBRAVO\r\n");

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    for (sessions, 0..) |session, index| {
        try grid.paint(session, &builder, .{
            .frame = geometry.RectF.init(@as(f32, @floatFromInt(index)) * 200, 0, 190, 200),
            .tokens = .{},
            .running = true,
            .selecting = false,
            .id_base = grid.paneIdBase(index),
        });
    }
    const list = builder.displayList();

    // The retained diff is the real judge: it rejects a display list that
    // repeats an object id, which is exactly what two panes sharing one
    // id base would produce.
    const changes = try testing.allocator.alloc(canvas.DiffChange, 4096);
    defer testing.allocator.free(changes);
    _ = try canvas.DisplayList.diff(.{}, list, changes);

    const first = list.findCommandById(grid.cursorCommandId(grid.paneIdBase(0))) orelse
        return error.TestExpectedCursor;
    const second = list.findCommandById(grid.cursorCommandId(grid.paneIdBase(1))) orelse
        return error.TestExpectedCursor;
    try testing.expect(first.index != second.index);
}

test "the pane command floor holds: neither pane starves its neighbour" {
    const sessions = try createSessions(40, 40);
    defer for (sessions) |each| each.destroy();
    for (sessions) |session| feedAdversarialRows(session, 40, 40);

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    var painted: [app.pane_count]usize = @splat(0);
    for (sessions, 0..) |session, index| {
        const before = builder.displayList().commands.len;
        try grid.paint(session, &builder, .{
            .frame = geometry.RectF.init(@as(f32, @floatFromInt(index)) * 480, 0, 470, 800),
            .tokens = .{},
            .running = true,
            .selecting = false,
            .command_budget = app.paneCommandBudget(index),
            .text_reserve = app.pane_text_reserve,
            .glyph_budget = app.pane_glyph_budget,
            .id_base = grid.paneIdBase(index),
        });
        painted[index] = distinctTextRows(builder.displayList().commands[before..]);
    }
    // Pane 0 is capped at its floor and pane 1 inherits the slack, so a
    // busy pane 0 cannot blank pane 1 and vice versa.
    try testing.expect(painted[0] >= 5);
    try testing.expect(painted[1] >= 5);
    try testing.expect(builder.displayList().commands.len <= app.chrome_command_envelope);
}

test "a screen of double box drawing stays inside the pane command budget" {
    // U+256C costs EIGHT commands (four double sides, two bars each). A
    // four-per-column reserve let the last painted row overshoot the
    // budget, and under `variable_prefix` an overshoot fails the WHOLE
    // frame rather than dropping a row.
    const session = try createSession(40, 24);
    defer session.destroy();
    for (0..24) |_| {
        session.feed("\u{256C}" ** 40);
        session.feed("\r\n");
    }

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 600, 600),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .command_budget = app.paneCommandBudget(0),
        .id_base = grid.paneIdBase(0),
    });
    try testing.expect(builder.displayList().commands.len <= app.paneCommandBudget(0));
}

/// The cockpit under the harness with both ptys live and distinct
/// content on each: the shape tests (d), (e), and (f) all need.
fn startTwoPaneCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    const app_state = try startFocusedTerminal(gpa, harness);
    const app_iface = app_state.app();
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    return app_state;
}

test "each pane's text lands inside its own rect and outside its neighbour's" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const frames = app.paneFrames(&app_state.model, geometry.SizeF.init(980, 640));
    const markers = [app.pane_count][]const u8{ "PANEALPHA", "PANEBRAVO" };
    const list = harness.runtime.views[0].canvasDisplayList();
    var found: [app.pane_count]bool = @splat(false);
    for (list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                for (markers, 0..) |marker, index| {
                    if (std.mem.indexOf(u8, text.text, marker) == null) continue;
                    found[index] = true;
                    const own = frames[index];
                    const other = frames[1 - index];
                    try testing.expect(text.origin.x >= own.x);
                    try testing.expect(text.origin.x < own.x + own.width);
                    try testing.expect(text.origin.x < other.x or text.origin.x >= other.x + other.width);
                }
            },
            else => {},
        }
    }
    try testing.expect(found[0]);
    try testing.expect(found[1]);
}

test "both panes reach the accessibility tree, so both are in the fingerprint" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("cockpit"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PANEALPHA") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PANEBRAVO") != null);
    try testing.expect(harness.runtime.sessionStateFingerprint() != 0);
}

// The eyes: the retained frame rendered offscreen through the
// deterministic reference renderer and written as a PNG, so a human (or
// an agent that can read images) can SEE two live panes side by side.
// Skipped by default, never in CI:
//
//   COCKPIT_SHOTS=1 zig build test -Dplatform=null
const cockpit_shot_path = "/Users/phall/workspace/phux-native-spike/cockpit/zig-out/cockpit-two-panes.png";

test "cockpit two-pane proof shot (env-gated)" {
    if (comptime !@import("builtin").link_libc) return error.SkipZigTest;
    if (std.c.getenv("COCKPIT_SHOTS") == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, "terminal-canvas", null);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, "terminal-canvas", null, pixels, scratch);

    const encoded = try gpa.alloc(u8, try canvas.png.encodedRgba8ByteLen(shot.width, shot.height));
    defer gpa.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, shot.width, shot.height, shot.rgba8);
    const first = writer.buffered();

    // Deterministic: the same retained frame encodes byte-identically.
    const again = try gpa.alloc(u8, encoded.len);
    defer gpa.free(again);
    var second_writer = std.Io.Writer.fixed(again);
    try canvas.png.writeRgba8(&second_writer, shot.width, shot.height, shot.rgba8);
    try testing.expectEqualSlices(u8, first, second_writer.buffered());

    try std.Io.Dir.cwd().createDirPath(io, "/Users/phall/workspace/phux-native-spike/cockpit/zig-out");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cockpit_shot_path, .data = first });
}

// -------------------------------------- cockpit: widgets, focus, routing

/// A full click on the canvas: press then release. `on_press` fires on
/// the RELEASE (`Ui.Tree.msgForPointer` returns null for every other
/// phase), so a lone `pointer_down` focuses the surface without
/// activating anything — which is why the existing single-pane tests
/// still reach pane 0 after clicking into it.
fn clickCanvas(harness: anytype, app_iface: anytype, x: f32, y: f32) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_down,
        .x = x,
        .y = y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .pointer_up,
        .x = x,
        .y = y,
    } });
}

fn typeCanvasText(harness: anytype, app_iface: anytype, text: []const u8) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .text_input,
        .text = text,
    } });
}

fn pressCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_down,
        .key = key,
        .modifiers = modifiers,
    } });
}

/// The laid-out frame of the pane stack whose accessibility label holds
/// a marker — the layout engine's OWN answer, independent of
/// `paneFrames`.
fn paneStackFrame(harness: anytype, marker: []const u8) ?geometry.RectF {
    const layout = harness.runtime.views[0].widgetLayoutTree();
    for (layout.nodes) |node| {
        if (node.widget.kind != .stack) continue;
        if (std.mem.indexOf(u8, node.widget.semantics.label, marker) == null) continue;
        return node.frame;
    }
    return null;
}

fn headerButtonFrame(harness: anytype) ?geometry.RectF {
    const layout = harness.runtime.views[0].widgetLayoutTree();
    for (layout.nodes) |node| {
        if (node.widget.kind == .button) return node.frame;
    }
    return null;
}

fn rectCenter(rect: geometry.RectF) geometry.PointF {
    return geometry.PointF.init(rect.x + rect.width / 2, rect.y + rect.height / 2);
}

test "the widget tree's pane stacks land exactly where paneFrames paints" {
    // THE LOAD-BEARING ONE. `ChromeOptions.build` never receives the
    // laid-out tree, so `paneFrames()` (which places the grids) and
    // `view()` (which places the hit targets) are two independent
    // derivations of the same rectangles. Nothing but this test keeps
    // them from drifting — and a drift means clicks land on the wrong
    // pane while the picture still looks right.
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const frames = app.paneFrames(&app_state.model, size);
    const markers = [app.pane_count][]const u8{ "PANEALPHA", "PANEBRAVO" };
    for (frames, markers) |expected, marker| {
        const laid_out = paneStackFrame(harness, marker) orelse return error.TestExpectedPaneStack;
        // A quarter point. If this fails, reconcile padding/gap/header
        // height — do NOT widen the epsilon.
        try testing.expectApproxEqAbs(expected.x, laid_out.x, 0.25);
        try testing.expectApproxEqAbs(expected.y, laid_out.y, 0.25);
        try testing.expectApproxEqAbs(expected.width, laid_out.width, 0.25);
        try testing.expectApproxEqAbs(expected.height, laid_out.height, 0.25);
    }

    // The header band is real chrome above them, not a gap.
    const button = headerButtonFrame(harness) orelse return error.TestExpectedButton;
    try testing.expect(button.y + button.height <= frames[0].y + 0.25);
}

test "typed keys reach the FOCUSED pane's pty and only that one" {
    // THE ACCEPTANCE GATE for the whole spike: mis-routed input shows
    // up as bytes on the wrong pty, not as a subtle rendering
    // difference.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try testing.expectEqual(@as(u8, 0), app_state.model.focus);
    try typeCanvasText(harness, app_iface, "alpha");
    try testing.expectEqualStrings("alpha", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    // cmd+2 moves the keyboard to pane 1.
    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try testing.expectEqual(@as(u8, 1), app_state.model.focus);
    try typeCanvasText(harness, app_iface, "bravo");
    try testing.expectEqualStrings("bravo", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
    // Pane 0's stream is untouched: the chord itself never reached it.
    try testing.expectEqualStrings("alpha", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));

    // ...and back.
    try pressCanvasKey(harness, app_iface, "1", .{ .primary = true });
    try testing.expectEqual(@as(u8, 0), app_state.model.focus);
    try typeCanvasText(harness, app_iface, "!");
    try testing.expectEqualStrings("alpha!", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("bravo", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "clicking a pane moves focus to it with no chord" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try testing.expectEqual(@as(u8, 0), app_state.model.focus);
    const target = rectCenter(app.paneFrames(&app_state.model, size)[1]);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(@as(u8, 1), app_state.model.focus);

    // A stack is not focusable, so the press RELEASED widget focus and
    // typing goes straight back to the terminal — pane 1's now.
    try typeCanvasText(harness, app_iface, "clicked");
    try testing.expectEqualStrings("clicked", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "the focusable button swallows Enter while it holds focus, and a pane click gives it back" {
    // THE HAZARD, PINNED RATHER THAN DESIGNED AROUND. A real
    // focusable widget on the same surface as a terminal means
    // activation keys belong to whoever holds focus. This is the
    // documented constraint; the recovery is one click on a pane.
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Baseline: Enter reaches the focused pane.
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try testing.expectEqualStrings("\r", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));

    const button = rectCenter(headerButtonFrame(harness) orelse return error.TestExpectedButton);
    try clickCanvas(harness, app_iface, button.x, button.y);
    try testing.expect(harness.runtime.views[0].canvas_widget_focused_id != 0);

    // The button owns the keyboard now: Enter activates IT (a no-op
    // restart on a live pane) and never reaches the shell.
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try testing.expectEqualStrings("\r", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqual(app.Phase.live, app_state.model.panes[0].phase);

    // Clicking a pane stack is the recovery path: a non-focusable press
    // target resolves widget focus to nothing, so keys reach `on_key`.
    const pane0 = rectCenter(app.paneFrames(&app_state.model, size)[0]);
    try clickCanvas(harness, app_iface, pane0.x, pane0.y);
    try testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try testing.expectEqualStrings("\r\r", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "only the focused pane paints a filled cursor, and deactivation hollows both" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 0, .filled);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .hollow);

    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 0, .hollow);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .filled);

    // Window activation is global: a blurred window hollows EVERY pane,
    // not only the unfocused one.
    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 0, .hollow);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .hollow);
}

// ------------------------------------------- the first-party-painter port

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
