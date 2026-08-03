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
    app.deinitModel(model);
}

test "Phux Cockpit identity and macOS pane commands are exact" {
    try testing.expectEqualStrings("Phux Cockpit", app.app_name);
    try testing.expectEqualStrings("dev.phux.cockpit", app.bundle_id);
    try testing.expectEqualStrings("phux-cockpit-canvas", app.canvas_label);
    try testing.expectEqualStrings(app.app_name, app.shell_scene.windows[0].title.?);
    try testing.expectEqualStrings(app.canvas_label, app.shell_scene.windows[0].views[0].label);
    try testing.expectEqualStrings(app.app_name, app.appOptions().name);
    try testing.expectEqualStrings(app.canvas_label, app.appOptions().canvas_label);

    if (comptime builtin.os.tag != .macos) return;
    try testing.expectEqualSlices([]const u8, &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }, app.paneArgv(0));
    try testing.expectEqualSlices([]const u8, &.{ "/bin/zsh", "-l", "-c", "cd \"$HOME\" && exec /bin/zsh -i" }, app.paneArgv(1));
}

test "Phux Cockpit owns its dark graphite and lime visual register" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);
    const tokens = app.cockpitTokens(&model);
    try testing.expectEqual(canvas.Color.rgb8(9, 11, 15), tokens.colors.background);
    try testing.expectEqual(canvas.Color.rgb8(17, 20, 27), tokens.colors.surface);
    try testing.expectEqual(canvas.Color.rgb8(244, 247, 251), tokens.colors.text);
    try testing.expectEqual(canvas.Color.rgb8(190, 242, 100), tokens.colors.accent);
}

test "retained response capacity matches the outbound ring" {
    try testing.expectEqual(app.outbound_buffer_bytes, grid.Session.response_capacity_max);
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

test "typed terminal attachments reject duplicates and preserve provider-owned state" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);

    const id = app.initialTerminalRef(0);
    const terminal = model.provider.terminal(id) orelse return error.TestExpectedTerminal;
    terminal.session.feed("durable state");
    try testing.expectError(error.TerminalAlreadyAttached, model.attach(.secondary, id));

    try testing.expectEqual(id, model.detach(.primary).?);
    try testing.expect(model.provider.terminal(id) == terminal);
    const detached_text = try terminal.session.plainText(testing.allocator);
    defer testing.allocator.free(detached_text);
    try testing.expect(std.mem.indexOf(u8, detached_text, "durable state") != null);

    try testing.expectError(error.PlacementOccupied, model.attach(.secondary, id));
    _ = model.detach(.secondary);
    try model.attach(.secondary, id);
    try testing.expectEqual(id, model.attachments[app.Placement.secondary.index()].?);
    try testing.expect(model.terminalAt(.secondary) == terminal);
}

fn remoteTerminalRef(id: u32) !app.TerminalRef {
    return .{
        .provider_id = .phux,
        .terminal_id = .{ .phux = try app.RemoteTerminalId.fromPhux(0, id, "local") },
    };
}

test "local and remote terminal identities never collide" {
    const local = app.initialTerminalRef(0);
    const remote = try remoteTerminalRef(@truncate(@intFromEnum(app.initialTerminalId(0))));
    try testing.expect(!local.eql(remote));
    try testing.expectEqual(app.ProviderKind.local, app.providerKind(local));
    try testing.expectEqual(app.ProviderKind.phux, app.providerKind(remote));
}

test "two remote terminals occupy independent existing placements" {
    const first = try remoteTerminalRef(11);
    const second = try remoteTerminalRef(12);
    var attachments: [app.pane_count]?app.TerminalRef = .{
        app.initialTerminalRef(0),
        app.initialTerminalRef(1),
    };
    app.reconcileRemoteRefs(&attachments, &.{ first, second });
    try testing.expect(attachments[0].?.eql(first));
    try testing.expect(attachments[1].?.eql(second));
    try testing.expect(!attachments[0].?.eql(attachments[1].?));
}

test "remote enumeration reorder retains stable placement identity" {
    const first = try remoteTerminalRef(21);
    const second = try remoteTerminalRef(22);
    var attachments: [app.pane_count]?app.TerminalRef = .{
        app.initialTerminalRef(0),
        app.initialTerminalRef(1),
    };
    app.reconcileRemoteRefs(&attachments, &.{ first, second });
    const before = attachments;
    app.reconcileRemoteRefs(&attachments, &.{ second, first });
    try testing.expect(attachments[0].?.eql(before[0].?));
    try testing.expect(attachments[1].?.eql(before[1].?));
}

test "provider dispatch refuses a provider-qualified remote identity at the local backend" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);

    const local = app.initialTerminalRef(0);
    const remote = try remoteTerminalRef(1);
    try testing.expect(model.containsTerminal(local));
    try testing.expect(!model.containsTerminal(remote));
    try testing.expect(model.terminalOwner(local) != null);
    try testing.expect(model.terminalOwner(remote) == null);
    _ = model.detach(.primary);
    try testing.expectError(error.UnknownTerminal, model.attach(.primary, remote));
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
    recorder.begin(.{ .platform_name = "test", .app_name = app.app_name, .window_width = 980, .window_height = 640 });

    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.session_recorder = recorder;

    const sessions = try createSessions(80, 24);
    const session = sessions[0];
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app.deinitModel(&app_state.model);
    defer app_state.deinit();
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
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;

    const sessions = try createSessions(80, 24);
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app.deinitModel(&app_state.model);
    defer app_state.deinit();
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

    // The shell spawned (init_fx) but produced NO output — phase is
    // still .starting, never .live. Typing must still reach the pty.
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .text_input,
        .text = "whoami",
    } });
    try testing.expectEqualStrings("whoami", app_state.effects.ptyWrittenBytes(1));
}

fn startFocusedTerminal(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions(80, 24);
    const app_state = try gpa.create(TerminalApp);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
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
    // Focus the surface with a click.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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

test "inactive application gates terminal key and text input" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try typeCanvasText(harness, app_iface, "blocked");
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));

    try harness.runtime.dispatchPlatformEvent(app_iface, .app_activated);
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try typeCanvasText(harness, app_iface, "live");
    try testing.expectEqualStrings("\rlive", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
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
            .label = app.canvas_label,
            .kind = .ime_set_composition,
            .text = "\xe3\x81\x8b", // か
        },
    });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // The host commits the marked text UNCHANGED — an empty commit; the
    // composed bytes come from the buffered preedit and reach the pty.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
        .kind = .ime_set_composition,
        .text = "\xe3\x81\x8b",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "arrowdown",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
        .kind = .ime_commit_composition,
        .text = "",
    } });
    try testing.expectEqualStrings("\xe3\x81\x8b", app_state.effects.ptyWrittenBytes(1));
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
        .kind = .text_input,
        .key = "c",
        .text = "c",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));

    // Unmodified typing still flows.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "a",
        .text = "a",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = "a",
    } });
    const written = app_state.effects.ptyWrittenBytes(1);
    try testing.expect(std.mem.indexOf(u8, written, ":3u") != null);
}

test "consumed app shortcut releases never leak under kitty reporting" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Both children request key-release reports. Releases deliberately
    // omit Command to model the modifier coming up before the key.
    for (app_state.model.panes) |*pane| pane.session.feed("\x1b[>11u");

    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true, .command = true });
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);
    try releaseCanvasKey(harness, app_iface, "2", .{});
    try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);

    // Toggle selection on and back off. The second release arrives while
    // selection is no longer armed, so only the app-level latch can stop it.
    for (0..2) |_| {
        try pressCanvasKey(harness, app_iface, "space", .{ .primary = true, .command = true, .shift = true });
        try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);
        try releaseCanvasKey(harness, app_iface, "space", .{});
        try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);
    }
    try testing.expect(!app_state.model.panes[1].selecting);

    // An emulator selection can be copied without keyboard-selection mode.
    // That keeps the release path otherwise open and proves copy is latched.
    app_state.model.panes[1].session.feed("copy");
    app_state.model.panes[1].session.beginSelection(false);
    try pressCanvasKey(harness, app_iface, "c", .{ .primary = true, .command = true });
    try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);
    try releaseCanvasKey(harness, app_iface, "c", .{});
    try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);

    try pressCanvasKey(harness, app_iface, "arrowup", .{ .primary = true, .command = true });
    try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);
    try releaseCanvasKey(harness, app_iface, "arrowup", .{});
    try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);

    // Escape turns selection off immediately, and Enter may turn it off
    // before key-up when clipboard completion is fast. Both releases still
    // belong to the app action rather than the kitty-reporting child.
    app_state.model.panes[1].session.feed("select me");
    app_state.model.panes[1].selecting = true;
    app_state.model.panes[1].session.beginSelection(false);
    try pressCanvasKey(harness, app_iface, "escape", .{});
    try testing.expect(!app_state.model.panes[1].selecting);
    try releaseCanvasKey(harness, app_iface, "escape", .{});

    app_state.model.panes[1].selecting = true;
    app_state.model.panes[1].session.beginSelection(false);
    app_state.model.panes[1].session.moveSelection(-1, 0, true);
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try app_state.effects.feedClipboardResult(app.clipboard_key, .ok, "");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(!app_state.model.panes[1].selecting);
    try releaseCanvasKey(harness, app_iface, "enter", .{});

    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true, .command = true });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[1].phase);
    try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);
    try releaseCanvasKey(harness, app_iface, "r", .{});
    try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);

    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "a non-shortcut re-press supersedes a stranded app shortcut latch" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    app_state.model.panes[0].session.feed("\x1b[>11u");
    try pressCanvasKey(harness, app_iface, "arrowup", .{ .primary = true, .command = true });
    try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);

    // The key repeats after Command came up. This is now terminal input,
    // so the old app latch must not swallow its eventual release.
    try pressCanvasKey(harness, app_iface, "arrowup", .{});
    try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);
    const before_release = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try releaseCanvasKey(harness, app_iface, "arrowup", .{});
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > before_release);
}

test "Cmd+V reads the clipboard and normalizes plain-paste newlines" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    for (0..120) |index| {
        var line: [24]u8 = undefined;
        app_state.model.panes[0].session.feed(std.fmt.bufPrint(&line, "history {d}\r\n", .{index}) catch unreachable);
    }
    app_state.model.panes[0].session.scrollToTop();
    const history_offset = app_state.model.panes[0].session.scrollbar().offset;

    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try testing.expect(app_state.model.paste_inflight);
    try testing.expect(app_state.model.paste_owner.eql(
        app_state.model.provider.owner(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminalOwner,
    ));
    try testing.expect(app.paste_clipboard_key != app.clipboard_key);
    const request = app_state.effects.pendingClipboardAt(0) orelse return error.TestExpectedClipboardRead;
    try testing.expectEqual(app.paste_clipboard_key, request.key);
    try testing.expectEqual(native_sdk.EffectClipboardOp.read, request.op);

    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "alpha\nbeta\r\ngamma");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqualStrings("alpha\rbeta\r\rgamma", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expect(!app_state.model.paste_inflight);
    try testing.expect(!app_state.model.paste_failed);
    try testing.expect(app_state.model.panes[0].session.scrollbar().offset > history_offset);
}

test "Cmd+V uses bracketed paste framing and preserves newlines" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    app_state.model.panes[0].session.feed("\x1b[?2004h");
    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "alpha\nbeta");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    try testing.expectEqualStrings(
        "\x1b[200~alpha\nbeta\x1b[201~",
        app_state.effects.ptyWrittenBytes(app.ptyKey(0)),
    );
}

test "Cmd+V replaces dangerous control bytes before writing" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "one\x03two\x1bthree\x00");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqualStrings("one two three ", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "clipboard paste stays with its requesting terminal while Web is selected" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try pressCanvasKey(harness, app_iface, "3", .{ .primary = true, .command = true });
    try testing.expectEqual(app.TabId.web, app_state.model.selected_tab);
    try testing.expectEqual(@as(?u8, null), app_state.model.selectedTerminalIndex());
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "original owner");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    try testing.expectEqualStrings("original owner", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "clipboard read failure is visible on the requesting pane" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .failed, "");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(app_state.model.paste_failed);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("paste-failed"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 1 / STARTING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PASTE FAILED") != null);
}

test "clipboard result after pane exit is a visible paste failure" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "too late");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    try testing.expect(app_state.model.paste_failed);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqual(@as(usize, 0), app_state.model.panes[0].outbound_len);
}

test "Cmd+V release never leaks under kitty reporting" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    app_state.model.panes[0].session.feed("\x1b[>11u");
    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try testing.expect(app_state.model.consumed_shortcut_keys_held != 0);
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "paste");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    // Hosts commonly omit Command when the key comes up after the
    // modifier. The app-level latch still owns this physical release.
    try releaseCanvasKey(harness, app_iface, "v", .{});
    try testing.expectEqual(@as(u32, 0), app_state.model.consumed_shortcut_keys_held);
    try testing.expectEqualStrings("paste", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "paste follows retained replies and atomic admission refuses every byte" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const pane = &app_state.model.panes[0];

    // A terminal query reply predates the paste. It must reach stdin
    // first even though its ring admission was initially blocked.
    pane.session.feed("\x1b[6n");
    const reply = try gpa.dupe(u8, pane.session.pendingResponses());
    defer gpa.free(reply);
    app_state.effects.fake_pty_write_full = true;
    pane.outbound_len = pane.outbound_buffer.len;
    app.moveResponsesToOutbound(pane, &app_state.effects);
    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    app_state.effects.fake_pty_write_full = false;
    pane.outbound_len = 0;
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "after");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    const ordered = app_state.effects.ptyWrittenBytes(app.ptyKey(0));
    try testing.expect(std.mem.startsWith(u8, ordered, reply));
    try testing.expect(std.mem.endsWith(u8, ordered, "after"));
    try releaseCanvasKey(harness, app_iface, "v", .{});

    // In bracketed mode, less free ring space than the complete framed
    // paste refuses it whole: no opening fence can be queued by itself.
    pane.session.feed("\x1b[?2004h");
    app_state.effects.fake_pty_write_full = true;
    pane.outbound_head = 0;
    pane.outbound_len = pane.outbound_buffer.len - 4;
    const before_len = pane.outbound_len;
    const before_loss = pane.outbound_dropped;
    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "body");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(before_len, pane.outbound_len);
    try testing.expectEqual(before_loss + "\x1b[200~body\x1b[201~".len, pane.outbound_dropped);
    try testing.expect(app_state.model.paste_failed);
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
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .shift = true },
    } });
    // Enter twice before the async result drains: the second press must
    // not issue a duplicate-key request whose rejection would overwrite
    // the first copy's success.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "enter",
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "[",
        .modifiers = .{ .control = true },
    } });
    try testing.expectEqualStrings("\x1c\x1b[91;5u", app_state.effects.ptyWrittenBytes(1));

    // F1 encodes its escape sequence (ESC O P) — function keys commit
    // no text, so the encoder is their only road to the child.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
            .label = app.canvas_label,
            .kind = .key_down,
            .key = "arrowleft",
            .modifiers = .{ .option = true },
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_up,
            .key = "arrowleft",
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_down,
            .key = "arrowright",
            .modifiers = .{ .option = true },
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_up,
            .key = "arrowright",
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_down,
            .key = "arrowleft",
            .modifiers = .{ .primary = true, .command = true },
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_up,
            .key = "arrowleft",
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_down,
            .key = "arrowright",
            .modifiers = .{ .primary = true, .command = true },
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_up,
            .key = "arrowright",
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .key_down,
            .key = "backspace",
            .modifiers = .{ .primary = true, .command = true },
        },
        .{
            .window_id = 1,
            .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
    try testing.expectEqual(@as(u64, 0), session.response_bytes_dropped);
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

test "retryable pty backpressure clears after the queue drains" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const pane = &app_state.model.panes[0];

    app_state.effects.fake_pty_write_full = true;
    try typeCanvasText(harness, app_iface, "retry");
    try testing.expectEqual(@as(usize, "retry".len), pane.outbound_len);
    try testing.expect(pane.write_refusals > 0);
    try testing.expectEqual(@as(u64, 0), pane.outbound_dropped);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("write-refusal"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "INPUT STALLED") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "OUTBOUND LOSS 0B") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "I/O LOSS") == null);

    app_state.effects.fake_pty_write_full = false;
    app.update(&app_state.model, .flush_outbound, &app_state.effects);
    try testing.expectEqual(@as(usize, 0), pane.outbound_len);
    try testing.expectEqualStrings("retry", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqual(@as(u64, 0), pane.outbound_dropped);
    try testing.expectEqual(@as(u32, 0), pane.write_refusals);
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
        .label = app.canvas_label,
        .kind = .text_input,
        .text = oversized,
    } });
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(1));
    try testing.expectEqual(@as(u64, oversized.len), app_state.model.panes[0].outbound_dropped);

    // The stream is intact past the drop: the next keystroke flows.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(usize, app.pane_count), app_state.effects.pendingPtyCount());
}

test "restart resets every per-session counter and exit field" {
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
    try app_state.effects.feedPtyExit(1, 0, 9, .signaled, 3);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(u32, 3), app_state.model.panes[0].native_delivery_failures);
    const pane = &app_state.model.panes[0];
    const previous_generation = pane.session_generation;
    pane.selecting = true;
    pane.copied_bytes = 12;
    pane.copy_failed = true;
    pane.macos_natural_keys_held = 7;
    pane.wheel_accum = 4.5;
    pane.outbound_head = 9;
    pane.outbound_len = 11;
    pane.outbound_dropped = 13;
    pane.session.response_bytes_dropped = 2;
    app_state.model.paste_owner = app_state.model.provider.owner(pane.id) orelse return error.TestExpectedTerminalOwner;
    app_state.model.paste_failed = true;
    try testing.expect(pane.output_batches > 0);
    try testing.expect(pane.output_bytes > 0);
    try testing.expectEqual(@as(i32, -1), pane.exit_code);
    try testing.expectEqual(@as(i32, 9), pane.exit_signal);

    // Cmd+R: the new shell's tally is its own — zero, not the dead
    // session's drops.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, pane.phase);
    try testing.expectEqual(@as(i32, 0), pane.exit_code);
    try testing.expectEqual(@as(i32, 0), pane.exit_signal);
    try testing.expectEqual(native_sdk.EffectExitReason.exited, pane.exit_reason);
    try testing.expect(!pane.selecting);
    try testing.expectEqual(@as(u64, 0), pane.copied_bytes);
    try testing.expect(!pane.copy_failed);
    try testing.expectEqual(@as(u8, 0), pane.macos_natural_keys_held);
    try testing.expectEqual(@as(f32, 0), pane.wheel_accum);
    try testing.expectEqual(@as(u64, 0), pane.output_batches);
    try testing.expectEqual(@as(u64, 0), pane.output_bytes);
    try testing.expectEqual(@as(u32, 0), pane.write_refusals);
    try testing.expectEqual(@as(u32, 0), pane.write_refusals_total);
    try testing.expectEqual(@as(u32, 0), pane.native_delivery_failures);
    try testing.expectEqual(@as(usize, 0), pane.outbound_head);
    try testing.expectEqual(@as(usize, 0), pane.outbound_len);
    try testing.expectEqual(@as(u64, 0), pane.outbound_dropped);
    try testing.expectEqual(@as(u64, 0), pane.session.response_bytes_dropped);
    try testing.expect(pane.session_generation != previous_generation);
    try testing.expect(!app_state.model.paste_failed);
}

test "restart cancels an owned clipboard read and ignores its stale result" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true, .command = true });
    const old_generation = app_state.model.panes[0].session_generation;
    try testing.expect(app_state.model.paste_inflight);
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true, .command = true });
    try testing.expect(app_state.model.panes[0].session_generation != old_generation);
    try testing.expect(app_state.model.paste_inflight);

    // The cancellation terminal is delivered after the replacement
    // shell exists. Generation pinning makes it state-only cleanup: no
    // bytes and no failure are attributed to the new session.
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(!app_state.model.paste_inflight);
    try testing.expect(!app_state.model.paste_failed);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "restart cancels an owned clipboard write and ignores its stale result" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const pane = &app_state.model.panes[0];

    pane.session.feed("copy me");
    pane.selecting = true;
    pane.session.beginSelection(false);
    pane.session.moveSelection(-1, 0, true);
    try pressCanvasKey(harness, app_iface, "enter", .{});
    const old_generation = pane.session_generation;
    try testing.expect(app_state.model.copy_inflight);

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true, .command = true });
    try testing.expect(pane.session_generation != old_generation);
    try testing.expect(app_state.model.copy_inflight);

    // Cancellation arrives after reset and cannot clear or fail a selection
    // belonging to the replacement shell.
    pane.selecting = true;
    pane.session.beginSelection(false);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(!app_state.model.copy_inflight);
    try testing.expect(pane.selecting);
    try testing.expect(!pane.copy_failed);
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
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "space",
        .modifiers = .{ .primary = true, .shift = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "arrowleft",
        .modifiers = .{ .shift = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
    try releaseCanvasKey(harness, app_iface, "enter", .{});
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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
        .label = app.canvas_label,
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

    // Render a full retained-scene screenshot. A damage-only present into
    // fresh pixels is no longer a valid oracle once Work/Web transitions
    // can add independent frame transactions.
    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, 1);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, 1, pixels, scratch);
    const width: usize = shot.width;
    const height: usize = shot.height;
    try testing.expectEqual(@as(usize, 980), width);
    try testing.expectEqual(@as(usize, 640), height);
    // (i) The prompt's cell band holds INK: pixels that differ from the
    // grid background. The first text row starts at the grid origin;
    // sample generously across the first cell row.
    const session = app_state.model.panes[0].session;
    const cell_w: usize = @intFromFloat(@max(1, session.cell_width));
    const cell_h: usize = @intFromFloat(@max(1, session.cell_height));
    const pane_frame = app.paneFrames(&app_state.model, geometry.SizeF.init(@floatFromInt(width), @floatFromInt(height)))[0];
    const grid_x: usize = @intFromFloat(pane_frame.x);
    const grid_y: usize = @intFromFloat(pane_frame.y);
    var band_colors = std.AutoHashMap(u32, void).init(gpa);
    defer band_colors.deinit();
    var y: usize = grid_y;
    while (y < grid_y + cell_h) : (y += 1) {
        var x: usize = grid_x;
        while (x < grid_x + cell_w * 8) : (x += 1) {
            const offset = (y * width + x) * 4;
            const value = std.mem.readInt(u32, shot.rgba8[offset..][0..4], .little);
            try band_colors.put(value, {});
        }
    }
    var retained_prompt = false;
    for (harness.runtime.views[0].canvasDisplayList().commands) |command| switch (command) {
        .draw_text => |text| if (std.mem.indexOf(u8, text.text, "demo$") != null) {
            retained_prompt = true;
        },
        else => {},
    };
    try testing.expect(retained_prompt);
    // Background alone is one color; ink adds more (glyph coverage is
    // antialiased, so ink contributes MANY distinct values — demand a
    // handful so a single stray pixel cannot pass).
    try testing.expect(band_colors.count() >= 4);

    // (ii) The caret cell paints distinguishably: the cursor sits right
    // after "demo$ " (column 6) and its wash differs from both the
    // background and the row's empty cells.
    const caret_x: usize = @intFromFloat(pane_frame.x + 6.5 * session.cell_width);
    const caret_y = grid_y + cell_h / 2;
    const caret_offset = (caret_y * width + caret_x) * 4;
    const caret_value = std.mem.readInt(u32, shot.rgba8[caret_offset..][0..4], .little);
    const empty_x: usize = @intFromFloat(pane_frame.x + 40.0 * session.cell_width);
    const empty_offset = (caret_y * width + empty_x) * 4;
    const empty_value = std.mem.readInt(u32, shot.rgba8[empty_offset..][0..4], .little);
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
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    const sessions = try createSessions(80, 24);
    const session = sessions[0];
    const app_state = try gpa.create(TerminalApp);
    defer gpa.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app.deinitModel(&app_state.model);
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

// ----------------------------------------------------- cockpit: tab surfaces

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

test "switching terminal Works retains distinct id namespaces the diff accepts" {
    const sessions = try createSessions(20, 6);
    defer for (sessions) |each| each.destroy();
    sessions[0].feed("PANEALPHA\r\n");
    sessions[1].feed("PANEBRAVO\r\n");

    var command_storage: [app.pane_count][1024]canvas.CanvasCommand = undefined;
    var lists: [app.pane_count]canvas.DisplayList = undefined;
    for (sessions, 0..) |session, index| {
        var builder = canvas.Builder.init(&command_storage[index]);
        try grid.paint(session, &builder, .{
            .frame = geometry.RectF.init(226, 60, 746, 572),
            .tokens = .{},
            .running = true,
            .selecting = false,
            .id_base = grid.paneIdBase(index),
        });
        lists[index] = builder.displayList();
    }

    // A tab switch diffs one selected terminal frame into the other.
    const changes = try testing.allocator.alloc(canvas.DiffChange, 4096);
    defer testing.allocator.free(changes);
    _ = try canvas.DisplayList.diff(lists[0], lists[1], changes);

    const first = lists[0].findCommandById(grid.cursorCommandId(grid.paneIdBase(0))) orelse
        return error.TestExpectedCursor;
    const second = lists[1].findCommandById(grid.cursorCommandId(grid.paneIdBase(1))) orelse
        return error.TestExpectedCursor;
    try testing.expect(first.command.objectId().? != second.command.objectId().?);
}

test "each selected terminal receives the full chrome command envelope" {
    const sessions = try createSessions(40, 40);
    defer for (sessions) |each| each.destroy();
    for (sessions) |session| feedAdversarialRows(session, 40, 40);

    var painted: [app.pane_count]usize = @splat(0);
    for (sessions, 0..) |session, index| {
        var commands: [2048]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try grid.paint(session, &builder, .{
            .frame = geometry.RectF.init(0, 0, 746, 580),
            .tokens = .{},
            .running = true,
            .selecting = false,
            .command_budget = app.chrome_command_envelope,
            .text_reserve = canvas.terminal_grid.widget_text_reserve,
            .glyph_budget = canvas.terminal_grid.widget_glyph_budget,
            .id_base = grid.paneIdBase(index),
        });
        painted[index] = distinctTextRows(builder.displayList().commands);
        try testing.expect(builder.displayList().commands.len <= app.chrome_command_envelope);
    }
    try testing.expect(painted[0] >= 5);
    try testing.expectEqual(painted[0], painted[1]);
}

test "a screen of double box drawing stays inside the selected terminal budget" {
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
        .command_budget = app.chrome_command_envelope,
        .id_base = grid.paneIdBase(0),
    });
    try testing.expect(builder.displayList().commands.len <= app.chrome_command_envelope);
}

/// The cockpit under the harness with both ptys live and distinct, even
/// though only the selected tab is presented in single mode.
fn startTwoPaneCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    const app_state = try startFocusedTerminal(gpa, harness);
    const app_iface = app_state.app();
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    return app_state;
}

test "detached terminal stays live and moved input and resize follow identity" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const model = &app_state.model;
    const terminal = model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    const original_session = terminal.session;

    app.update(model, .{ .detach_terminal = .primary }, &app_state.effects);
    try testing.expectEqual(@as(?app.TerminalRef, null), model.attachments[app.Placement.primary.index()]);
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "DETACHED LIVE\r\n");
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    try testing.expectEqual(app.Phase.live, terminal.phase);
    try testing.expect(std.mem.indexOf(u8, terminal.session.screenText(), "DETACHED LIVE") != null);

    app.update(model, .{ .detach_terminal = .secondary }, &app_state.effects);
    app.update(model, .{ .attach_terminal = .{ .placement = .secondary, .terminal_ref = app.initialTerminalRef(0) } }, &app_state.effects);
    app.update(model, .{ .select_tab = .terminal_2 }, &app_state.effects);
    try testing.expect(model.terminalAt(.secondary).?.session == original_session);

    try typeCanvasText(harness, app_state.app(), "moved");
    try testing.expect(std.mem.endsWith(u8, app_state.effects.ptyWrittenBytes(app.ptyKey(0)), "moved"));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    const other = model.provider.terminal(app.initialTerminalRef(1)) orelse return error.TestExpectedTerminal;
    const other_cols = other.cols;
    const other_rows = other.rows;
    app.update(model, .{ .viewport = .{
        .terminal_ref = app.initialTerminalRef(0),
        .cols = 61,
        .rows = 17,
        .size = geometry.SizeF.init(701, 411),
    } }, &app_state.effects);
    try testing.expectEqual(@as(u16, 61), terminal.cols);
    try testing.expectEqual(@as(u16, 17), terminal.rows);
    try testing.expectEqual(other_cols, other.cols);
    try testing.expectEqual(other_rows, other.rows);
}

test "clipboard completion follows terminal identity across attachment moves" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const model = &app_state.model;

    try pressCanvasKey(harness, app_state.app(), "v", .{ .primary = true, .command = true });
    try testing.expect(model.paste_owner.eql(
        model.provider.owner(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminalOwner,
    ));
    app.update(model, .{ .detach_terminal = .primary }, &app_state.effects);
    app.update(model, .{ .detach_terminal = .secondary }, &app_state.effects);
    app.update(model, .{ .attach_terminal = .{ .placement = .secondary, .terminal_ref = app.initialTerminalRef(0) } }, &app_state.effects);
    app.update(model, .{ .select_tab = .terminal_2 }, &app_state.effects);

    try app_state.effects.feedClipboardResult(app.paste_clipboard_key, .ok, "identity paste");
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    try testing.expectEqualStrings("identity paste", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "attachment changes keep selected and focused placements routable" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const model = &app_state.model;

    app.update(model, .{ .detach_terminal = .primary }, &app_state.effects);
    try testing.expectEqual(app.TabId.terminal_2, model.selected_tab);
    try testing.expectEqual(app.Placement.secondary, model.focus_placement);

    app.update(model, .{ .detach_terminal = .secondary }, &app_state.effects);
    try testing.expectEqual(@as(?app.TerminalRef, null), model.focusedTerminalRef());
    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    try releaseCanvasKey(harness, app_state.app(), "f1", .{});
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .frame_requested);
    var saw_detached_semantics = false;
    var saw_disabled_split = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.indexOf(u8, layout.widget.semantics.label, "Terminal 2, native terminal, detached") != null) {
            saw_detached_semantics = true;
        }
        if (std.mem.eql(u8, layout.widget.text, "Split") and layout.widget.state.disabled) {
            saw_disabled_split = true;
        }
    }
    try testing.expect(saw_detached_semantics);
    try testing.expect(saw_disabled_split);

    app.update(model, .{ .attach_terminal = .{ .placement = .primary, .terminal_ref = app.initialTerminalRef(0) } }, &app_state.effects);
    try testing.expectEqual(app.TabId.terminal_1, model.selected_tab);
    try testing.expectEqual(app.Placement.primary, model.focus_placement);
    try typeCanvasText(harness, app_state.app(), "reattached");
    try testing.expectEqualStrings("reattached", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "terminal key release follows its press across attachment focus changes" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const pane = app_state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    pane.session.feed("\x1b[>11u");

    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    const after_press = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try testing.expect(after_press > 0);
    app.update(&app_state.model, .{ .detach_terminal = .primary }, &app_state.effects);
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try releaseCanvasKey(harness, app_state.app(), "f1", .{});

    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > after_press);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "terminal key release from an ended generation cannot reach its replacement" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const pane = app_state.model.provider.terminal(app.initialTerminalRef(0)) orelse return error.TestExpectedTerminal;
    pane.session.feed("\x1b[>11u");

    try pressCanvasKey(harness, app_state.app(), "f1", .{});
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    app.update(&app_state.model, .{ .restart = .primary }, &app_state.effects);
    const replacement_bytes = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;

    try releaseCanvasKey(harness, app_state.app(), "f1", .{});
    try testing.expectEqual(replacement_bytes, app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

fn expectDisplayListMarker(display_list: anytype, marker: []const u8, frame: geometry.RectF) !void {
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| if (std.mem.indexOf(u8, text.text, marker) != null) {
                try testing.expect(text.origin.x >= frame.x);
                try testing.expect(text.origin.x < frame.x + frame.width);
                return;
            },
            else => {},
        }
    }
    return error.TestExpectedMarker;
}

fn expectDisplayListMissingMarker(display_list: anytype, marker: []const u8) !void {
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| try testing.expect(std.mem.indexOf(u8, text.text, marker) == null),
            else => {},
        }
    }
}

test "only the selected terminal paints and hidden terminal state remains live" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    const size = geometry.SizeF.init(980, 640);
    var frames = app.paneFrames(&app_state.model, size);
    try testing.expect(frames[0].width > 0);
    try testing.expectEqual(@as(f32, 0), frames[1].width);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEALPHA", frames[0]);
    try expectDisplayListMissingMarker(harness.runtime.views[0].canvasDisplayList(), "PANEBRAVO");

    // Pane 1 accepted output while hidden. Selecting Terminal 2 reveals its
    // existing emulator rather than creating or resetting a surface.
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "HIDDEN STATE\r\n");
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .wake);
    const hidden_bytes = app_state.model.panes[1].output_bytes;
    try pressCanvasKey(harness, app_state.app(), "2", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .frame_requested);
    frames = app.paneFrames(&app_state.model, size);
    try testing.expectEqual(@as(f32, 0), frames[0].width);
    try testing.expect(frames[1].width > 0);
    try testing.expectEqual(hidden_bytes, app_state.model.panes[1].output_bytes);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEBRAVO", frames[1]);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "HIDDEN STATE", frames[1]);
    try expectDisplayListMissingMarker(harness.runtime.views[0].canvasDisplayList(), "PANEALPHA");
}

test "selected terminal status is concise and the hidden status is absent" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    var saw_workspace = false;
    var saw_scratch = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "TERMINAL 1 / RUNNING")) {
            saw_workspace = true;
            try testing.expectEqual(canvas.WidgetKind.text, layout.widget.kind);
        }
        if (std.mem.eql(u8, layout.widget.text, "TERMINAL 2 / RUNNING")) saw_scratch = true;
    }
    try testing.expect(saw_workspace);
    try testing.expect(!saw_scratch);
}

test "split exposes lifecycle status for both visible terminals" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try releaseCanvasKey(harness, app_iface, "d", .{});
    try app_state.effects.feedPtyExit(app.ptyKey(1), 9, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("split-status"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 1 / RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 2 / EXIT 9") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Restart Terminal 2") != null);
}

test "hidden terminal spawn failures mark tabs and distinguish failure reasons" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .spawn_failed, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.TabId.terminal_1, app_state.model.selected_tab);

    var saw_hidden_marker = false;
    var saw_hidden_reason = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "Terminal 2 !  CMD+2")) saw_hidden_marker = true;
        if (std.mem.indexOf(u8, layout.widget.semantics.label, "SPAWN FAILED") != null) saw_hidden_reason = true;
    }
    try testing.expect(saw_hidden_marker);
    try testing.expect(saw_hidden_reason);

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .rejected, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    var saw_rejected = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "TERMINAL 1 / SPAWN REJECTED")) saw_rejected = true;
    }
    try testing.expect(saw_rejected);
}

test "lifecycle and loss diagnostics remain visible beside native delivery failures" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(0), 23, 0, .exited, 4);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    const pane = &app_state.model.panes[0];
    pane.outbound_dropped = 7;
    pane.session.response_bytes_dropped = 2;
    pane.copy_failed = true;
    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("terminal-diagnostics"), &writer);
    const snapshot = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, snapshot, "TERMINAL 1 / EXIT 23") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "OUTBOUND LOSS 7B") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "REPLY LOSS 2B") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "DELIVERY FAILURES 4") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "COPY FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "I/O LOSS") != null);
}

test "restart controls target their placement and Cmd+R targets focus" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try releaseCanvasKey(harness, app_iface, "d", .{});
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try app_state.effects.feedPtyExit(app.ptyKey(1), 9, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    const secondary_restart = widgetFrameBySemantics(harness, "Restart Terminal 2") orelse return error.TestExpectedRestart;
    const secondary_generation = app_state.model.panes[1].session_generation;
    const secondary_target = rectCenter(secondary_restart);
    try clickCanvas(harness, app_iface, secondary_target.x, secondary_target.y);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[1].phase);
    try testing.expect(app_state.model.panes[1].session_generation != secondary_generation);

    const primary_restart = widgetFrameBySemantics(harness, "Restart Terminal 1") orelse return error.TestExpectedRestart;
    const primary_target = rectCenter(primary_restart);
    try clickCanvas(harness, app_iface, primary_target.x, primary_target.y);
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);

    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    app.update(&app_state.model, .{ .focus_pane = .secondary }, &app_state.effects);
    const cmd_generation = app_state.model.panes[1].session_generation;
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[1].phase);
    try testing.expect(app_state.model.panes[1].session_generation != cmd_generation);
}

test "terminal exit and selection mode are actionable in native chrome" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(0), 127, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    var saw_missing = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "TERMINAL 1 / EXIT 127")) {
            saw_missing = true;
            try testing.expectEqual(canvas.WidgetVariant.destructive, layout.widget.variant);
        }
    }
    try testing.expect(saw_missing);

    // The second terminal remains usable and exposes selection state without
    // turning the command band into a permanent shortcut legend.
    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try pressCanvasKey(harness, app_iface, "space", .{ .primary = true, .shift = true });
    var saw_selecting = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "SELECTING")) saw_selecting = true;
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "Arrows move | Shift extends | Enter copies | Esc cancels"));
    }
    try testing.expect(saw_selecting);
}

test "native tabs and only the selected terminal surface reach accessibility" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    app_state.model.panes[0].copy_failed = true;
    app_state.model.panes[0].outbound_dropped = 7;
    app_state.model.panes[0].session.response_bytes_dropped = 2;
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .app_deactivated);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("cockpit"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Surfaces") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal 1, native terminal, RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal 2, native terminal, RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Web, system WebKit, shortcut") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 1 / RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "OUTBOUND LOSS 7B") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "REPLY LOSS 2B") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "COPY FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "outbound loss 7 bytes; reply loss 2 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Terminal 1") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PANEALPHA") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "PANEBRAVO") == null);
    try testing.expect(harness.runtime.sessionStateFingerprint() != 0);

    var saw_loss = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "I/O LOSS")) {
            saw_loss = true;
            try testing.expectEqual(canvas.WidgetVariant.destructive, layout.widget.variant);
        }
    }
    try testing.expect(saw_loss);
}

// The eyes: the retained frame rendered offscreen through the
// deterministic reference renderer and written as a PNG, so a human (or
// an agent that can read images) can inspect the native tab substrate.
// Skipped by default, never in CI:
//
//   COCKPIT_SHOTS=1 zig build test -Dplatform=null
const cockpit_shot_path = "zig-out/cockpit-native-tabs.png";

test "cockpit native-tab proof shot (env-gated)" {
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

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, null);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, null, pixels, scratch);

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

    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
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

fn typeCanvasText(harness: anytype, app_iface: anytype, text: []const u8) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .text_input,
        .text = text,
    } });
}

fn pressCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = key,
        .modifiers = modifiers,
    } });
}

fn releaseCanvasKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
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

fn widgetFrameBySemantics(harness: anytype, label: []const u8) ?geometry.RectF {
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, label)) return node.frame;
    }
    return null;
}

fn rectCenter(rect: geometry.RectF) geometry.PointF {
    return geometry.PointF.init(rect.x + rect.width / 2, rect.y + rect.height / 2);
}

test "selected terminal defaults to the first tab and paneFrames has one full content frame" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);
    try testing.expectEqual(app.TabId.terminal_1, model.selected_tab);
    try testing.expectEqual(@as(?u8, 0), model.selectedTerminalIndex());

    const size = geometry.SizeF.init(980, 640);
    var frames = app.paneFrames(&model, size);
    try testing.expectApproxEqAbs(@as(f32, 8), frames[0].x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 964), frames[0].width, 0.0001);
    try testing.expect(frames[0].height > 0);
    try testing.expectEqual(geometry.RectF{}, frames[1]);

    model.selected_tab = .terminal_2;
    frames = app.paneFrames(&model, size);
    try testing.expectEqual(geometry.RectF{}, frames[0]);
    try testing.expect(frames[1].width > 0);

    model.selected_tab = .web;
    frames = app.paneFrames(&model, size);
    try testing.expectEqual(geometry.RectF{}, frames[0]);
    try testing.expectEqual(geometry.RectF{}, frames[1]);

    model.selected_tab = .terminal_1;
    model.layout = .split;
    model.split_fraction = 0.01;
    frames = app.paneFrames(&model, size);
    try testing.expect(frames[0].width >= app.split_pane_min_width - 0.01);
    try testing.expect(frames[1].width >= app.split_pane_min_width - 0.01);
    model.split_fraction = 0.99;
    frames = app.paneFrames(&model, size);
    try testing.expect(frames[0].width >= app.split_pane_min_width - 0.01);
    try testing.expect(frames[1].width >= app.split_pane_min_width - 0.01);
}

test "the selected terminal stack lands exactly where paneFrames paints" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    for ([_][]const u8{ "1", "2" }, [_][]const u8{ "PANEALPHA", "PANEBRAVO" }) |key, marker| {
        try pressCanvasKey(harness, app_state.app(), key, .{ .primary = true });
        try harness.runtime.dispatchPlatformEvent(app_state.app(), .frame_requested);
        const index = app_state.model.focus_placement.index();
        const expected = app.paneFrames(&app_state.model, size)[index];
        const laid_out = paneStackFrame(harness, marker) orelse return error.TestExpectedPaneStack;
        try testing.expectApproxEqAbs(expected.x, laid_out.x, 0.25);
        try testing.expectApproxEqAbs(expected.y, laid_out.y, 0.25);
        try testing.expectApproxEqAbs(expected.width, laid_out.width, 0.25);
        try testing.expectApproxEqAbs(expected.height, laid_out.height, 0.25);
    }
}

test "Cmd+D projects both live terminals without respawning and collapse keeps the active pane" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    const first_session = app_state.model.panes[0].session;
    const second_session = app_state.model.panes[1].session;
    const generations = [_]u64{
        app_state.model.panes[0].session_generation,
        app_state.model.panes[1].session_generation,
    };

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try releaseCanvasKey(harness, app_iface, "d", .{});
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.LayoutMode.split, app_state.model.layout);
    const frames = app.paneFrames(&app_state.model, size);
    try testing.expect(frames[0].width >= app.split_pane_min_width);
    try testing.expect(frames[1].width >= app.split_pane_min_width);
    try testing.expectApproxEqAbs(
        size.width - 2 * 8,
        frames[0].width + app.split_divider_width + frames[1].width,
        0.001,
    );
    try testing.expect(app_state.model.panes[0].session == first_session);
    try testing.expect(app_state.model.panes[1].session == second_session);
    try testing.expectEqual(generations[0], app_state.model.panes[0].session_generation);
    try testing.expectEqual(generations[1], app_state.model.panes[1].session_generation);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEALPHA", frames[0]);
    try expectDisplayListMarker(harness.runtime.views[0].canvasDisplayList(), "PANEBRAVO", frames[1]);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 0, .filled);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .hollow);

    const right_target = rectCenter(frames[1]);
    try clickCanvas(harness, app_iface, right_target.x, right_target.y);
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);

    try pressCanvasKey(harness, app_iface, "arrowleft", .{ .primary = true, .option = true });
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try pressCanvasKey(harness, app_iface, "arrowright", .{ .primary = true, .option = true });
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);
    try typeCanvasText(harness, app_iface, "right");
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("right", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expectEqual(app.LayoutMode.single, app_state.model.layout);
    const collapsed = app.paneFrames(&app_state.model, size);
    try testing.expectEqual(@as(f32, 0), collapsed[0].width);
    try testing.expect(collapsed[1].width > 0);
}

test "split divider keyboard resize stays in lockstep with terminal chrome and PTYs" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    var divider: ?geometry.RectF = null;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .split_divider) divider = node.frame;
    }
    const target = rectCenter(divider orelse return error.TestExpectedSplitDivider);
    try clickCanvas(harness, app_iface, target.x, target.y);
    const before = app_state.model.split_fraction;
    try pressCanvasKey(harness, app_iface, "arrowright", .{});
    try testing.expect(app_state.model.split_fraction > before);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    divider = null;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (node.widget.kind == .split_divider) divider = node.frame;
    }
    const drag_start = rectCenter(divider orelse return error.TestExpectedSplitDivider);
    const keyboard_fraction = app_state.model.split_fraction;
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = drag_start.x,
        .y = drag_start.y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_drag,
        .x = drag_start.x + 60,
        .y = drag_start.y,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_up,
        .x = drag_start.x + 60,
        .y = drag_start.y,
    } });
    try testing.expect(app_state.model.split_fraction > keyboard_fraction);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    const frames = app.paneFrames(&app_state.model, size);
    for ([_][]const u8{ "PANEALPHA", "PANEBRAVO" }, 0..) |marker, index| {
        const laid_out = paneStackFrame(harness, marker) orelse return error.TestExpectedPaneStack;
        try testing.expectApproxEqAbs(frames[index].x, laid_out.x, 0.25);
        try testing.expectApproxEqAbs(frames[index].width, laid_out.width, 0.25);
    }

    for (2..6) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = size,
            .scale_factor = 2,
            .frame_index = @intCast(frame_index),
            .timestamp_ns = @as(u64, frame_index) * 1_000_000,
        } });
    }
    for (app_state.model.panes, frames) |pane, frame| {
        const expected = grid.Session.clampGrid(
            @intFromFloat(@max(2, frame.width / pane.session.cell_width)),
            @intFromFloat(@max(2, frame.height / pane.session.cell_height)),
            grid.max_cells / app.pane_count,
        );
        try testing.expectEqual(expected.x, pane.cols);
        try testing.expectEqual(expected.y, pane.rows);
    }
}

test "sub-cell frame changes still update surface geometry" {
    const gpa = testing.allocator;
    const base = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = base });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    for (2..4) |frame_index| try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = base,
        .scale_factor = 2,
        .frame_index = @intCast(frame_index),
        .timestamp_ns = @as(u64, frame_index) * 1_000_000,
    } });
    const cols = app_state.model.panes[0].cols;
    const rows = app_state.model.panes[0].rows;
    const changed = geometry.SizeF.init(base.width + 0.25, base.height + 0.25);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = changed,
        .scale_factor = 2,
        .frame_index = 4,
        .timestamp_ns = 4_000_000,
    } });

    try testing.expectEqual(changed.width, app_state.model.surface_size.width);
    try testing.expectEqual(changed.height, app_state.model.surface_size.height);
    try testing.expectEqual(cols, app_state.model.panes[0].cols);
    try testing.expectEqual(rows, app_state.model.panes[0].rows);
}

test "split PTY grids share one cell-capacity budget" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });

    const large = geometry.SizeF.init(4000, 1800);
    for (2..7) |frame_index| try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = large,
        .scale_factor = 2,
        .frame_index = @intCast(frame_index),
        .timestamp_ns = @as(u64, frame_index) * 1_000_000,
    } });

    var total_cells: usize = 0;
    for (app_state.model.panes) |pane| {
        const cells = @as(usize, pane.cols) * @as(usize, pane.rows);
        try testing.expect(cells <= grid.max_cells / app.pane_count);
        total_cells += cells;
    }
    try testing.expect(total_cells <= grid.max_cells);
}

test "tab cycling crosses terminal and Web surfaces without sending terminal bytes" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "]", .{ .primary = true, .shift = true });
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);
    try releaseCanvasKey(harness, app_iface, "]", .{});
    try pressCanvasKey(harness, app_iface, "]", .{ .primary = true, .shift = true });
    try testing.expectEqual(app.TabId.web, app_state.model.selected_tab);
    try releaseCanvasKey(harness, app_iface, "]", .{});
    try pressCanvasKey(harness, app_iface, "[", .{ .primary = true, .shift = true });
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "extra modifiers bypass exact spatial shortcuts and reach the terminal" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "]", .{ .primary = true, .shift = true, .control = true });
    try testing.expectEqual(app.TabId.terminal_1, app_state.model.selected_tab);
    const after_bracket = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try testing.expect(after_bracket > 0);

    try pressCanvasKey(harness, app_iface, "arrowright", .{ .primary = true, .option = true, .shift = true });
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > after_bracket);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    const before_single_pane_chord = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    app_state.model.panes[0].session.feed("\x1b[>11u");
    try pressCanvasKey(harness, app_iface, "arrowright", .{ .primary = true, .option = true });
    try testing.expectEqual(app.LayoutMode.single, app_state.model.layout);
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len > before_single_pane_chord);
}

test "spatial shortcut releases never leak into kitty-reporting terminals" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions(80, 24);
    const host = try gpa.create(app.CockpitHost);
    defer gpa.destroy(host);
    host.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    host.inner.effects.executor = .fake;
    const app_iface = host.app();
    try harness.start(app_iface);
    for (host.inner.model.panes) |*pane| pane.session.feed("\x1b[>11u");

    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "layout.split",
        .key = "d",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try releaseCanvasKey(harness, app_iface, "d", .{});

    const cases = [_]struct {
        id: []const u8,
        key: []const u8,
        modifiers: native_sdk.platform.ShortcutModifiers,
    }{
        .{ .id = "tab.next", .key = "]", .modifiers = .{ .primary = true, .shift = true } },
        .{ .id = "tab.previous", .key = "[", .modifiers = .{ .primary = true, .shift = true } },
    };
    for (cases) |case| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
            .id = case.id,
            .key = case.key,
            .window_id = 1,
            .modifiers = case.modifiers,
        } });
        try releaseCanvasKey(harness, app_iface, case.key, .{});
    }
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "repeated global shortcut callbacks are idempotent per physical edge" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions(80, 24);
    const host = try gpa.create(app.CockpitHost);
    defer gpa.destroy(host);
    host.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    host.inner.effects.executor = .fake;
    const app_iface = host.app();
    try harness.start(app_iface);

    const shortcut: native_sdk.ShortcutEvent = .{
        .id = "layout.split",
        .key = "d",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    };
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = shortcut });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try testing.expect(host.global_shortcut_keys_held != 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = shortcut });
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);

    try releaseCanvasKey(harness, app_iface, "d", .{});
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = shortcut });
    try testing.expectEqual(app.LayoutMode.single, host.inner.model.layout);

    for (&host.inner.model.provider.terminals) |*pane| pane.session.feed("\x1b[>11u");
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.terminal-1",
        .key = "1",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.terminal-2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try releaseCanvasKey(harness, app_iface, "1", .{});
    try releaseCanvasKey(harness, app_iface, "2", .{});
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "Cmd+1 and Cmd+2 select terminal tabs and route text only to that tab" {
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

    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expectEqual(app.TabId.terminal_1, app_state.model.selected_tab);
    try typeCanvasText(harness, app_iface, "alpha");
    try testing.expectEqualStrings("alpha", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    // cmd+2 moves the keyboard to pane 1.
    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);
    try typeCanvasText(harness, app_iface, "bravo");
    try testing.expectEqualStrings("bravo", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
    // Pane 0's stream is untouched: the chord itself never reached it.
    try testing.expectEqualStrings("alpha", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));

    // ...and back.
    try pressCanvasKey(harness, app_iface, "1", .{ .primary = true });
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expectEqual(app.TabId.terminal_1, app_state.model.selected_tab);
    try typeCanvasText(harness, app_iface, "!");
    try testing.expectEqualStrings("alpha!", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("bravo", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "tab IDs and browser messages make focused model transitions" {
    const sessions = try createSessions(80, 24);
    var app_state = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer app.deinitModel(&app_state.model);
    defer app_state.deinit();
    app_state.effects.executor = .fake;

    try testing.expectEqual(app.TabId.terminal_1, app_state.model.selected_tab);
    try testing.expectEqual(app.BrowserPage.github, app_state.model.browser_page);
    try testing.expectEqual(@as(?u8, 0), app_state.model.selectedTerminalIndex());

    app.update(&app_state.model, .{ .select_tab = .terminal_2 }, &app_state.effects);
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try testing.expectEqual(@as(?u8, 1), app_state.model.selectedTerminalIndex());

    app.update(&app_state.model, .{ .browser_page = .article }, &app_state.effects);
    try testing.expectEqual(app.TabId.web, app_state.model.selected_tab);
    try testing.expectEqual(app.BrowserPage.article, app_state.model.browser_page);
    try testing.expectEqual(@as(?u8, null), app_state.model.selectedTerminalIndex());
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);

    try testing.expectEqual(@as(u64, 1), app_state.model.browser_navigation_token);
    app.update(&app_state.model, .{ .select_tab = .terminal_1 }, &app_state.effects);
    try testing.expectEqual(app.Placement.primary, app_state.model.focus_placement);
    try testing.expectEqual(app.BrowserPage.article, app_state.model.browser_page);
}

test "Cmd+3 selects accessible Web and non-terminal selection blocks terminal input" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    var line: [24]u8 = undefined;
    for (0..80) |index| app_state.model.panes[0].session.feed(std.fmt.bufPrint(&line, "history {d}\r\n", .{index}) catch unreachable);
    const bottom = app_state.model.panes[0].session.scrollbar().offset;
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);

    try pressCanvasKey(harness, app_iface, "3", .{ .primary = true });
    try testing.expectEqual(app.TabId.web, app_state.model.selected_tab);
    try testing.expectEqual(@as(?u8, null), app_state.model.selectedTerminalIndex());
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingClipboardCount());

    const before0 = app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    const before1 = app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len;
    try pressCanvasKey(harness, app_iface, "arrowup", .{});
    try typeCanvasText(harness, app_iface, "blocked");
    try pressCanvasKey(harness, app_iface, "v", .{ .primary = true });
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true });
    for ([_]f32{ 100, 500 }) |x| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .scroll,
            .x = x,
            .y = 300,
            .delta_y = app_state.model.panes[0].session.cell_height * 4,
        } });
    }
    try testing.expectEqual(before0, app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
    try testing.expectEqual(before1, app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len);
    try testing.expectEqual(@as(usize, 0), app_state.effects.pendingClipboardCount());
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(bottom, app_state.model.panes[0].session.scrollbar().offset);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("web"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Web, system WebKit") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), app.webview_anchor) != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "GitHub") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "GitHub") != null);

    // The platform shortcut path, not a synthetic canvas key, escapes native
    // WebKit focus. Its later physical release is latched and cannot leak to
    // a terminal using kitty key-release reporting.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.terminal-2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.TabId.terminal_2, app_state.model.selected_tab);
    const scratch_before_release = app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len;
    try releaseCanvasKey(harness, app_iface, "2", .{});
    try testing.expectEqual(scratch_before_release, app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len);
}

test "web pane root-navigation bindings are exact" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    try testing.expectEqualStrings("https://github.com/phall1", app.BrowserPage.github.url());
    try testing.expectEqualStrings("https://www.superlogical.com/", app.BrowserPage.superlogical.url());
    try testing.expectEqualStrings("https://mitchellh.com/writing/superlogical", app.BrowserPage.article.url());

    var panes: [1]TerminalApp.WebViewPane = undefined;
    try testing.expectEqual(@as(usize, 1), app.webPanes(&app_state.model, &panes));
    try testing.expectEqualStrings(app.webview_label, panes[0].label);
    try testing.expectEqualStrings(app.webview_anchor, panes[0].anchor.?);
    try testing.expectEqualStrings(app.BrowserPage.github.url(), panes[0].url);
    try testing.expectEqual(@as(u64, 0), panes[0].reload_token);

    try testing.expectEqual(@as(usize, 1), harness.null_platform.webview_count);
    try testing.expectEqualStrings(app.webview_label, harness.null_platform.webviews[0].label);
    try testing.expect(harness.null_platform.webviews[0].frame.width <= app.webkit_parking_extent);
    try testing.expect(harness.null_platform.webviews[0].frame.height <= app.webkit_parking_extent);
    const navigations = harness.null_platform.webview_navigate_count;
    try app_state.dispatch(&harness.runtime, 1, .{ .browser_page = .superlogical });
    try testing.expectEqual(app.TabId.web, app_state.model.selected_tab);
    try testing.expectEqualStrings(app.BrowserPage.superlogical.url(), harness.null_platform.webviews[0].url);
    try testing.expectEqual(navigations + 1, harness.null_platform.webview_navigate_count);
    try testing.expectEqual(@as(u64, 1), app_state.model.browser_navigation_token);
    const web_frame = harness.null_platform.webviews[0].frame;
    try testing.expect(web_frame.x >= 0);
    try testing.expect(web_frame.y >= app.header_height);
    try testing.expect(web_frame.width > 500);
    try testing.expect(web_frame.height > 300);

    // Reopening the same root forces a fresh app-owned navigation even if
    // WebKit followed links without a committed-navigation callback.
    try app_state.dispatch(&harness.runtime, 1, .{ .browser_page = .superlogical });
    try testing.expectEqualStrings(app.BrowserPage.superlogical.url(), harness.null_platform.webviews[0].url);
    try testing.expectEqual(navigations + 2, harness.null_platform.webview_navigate_count);
    try testing.expectEqual(@as(u64, 2), app_state.model.browser_navigation_token);
}

test "native tab shortcuts transfer first responder between canvas and WebKit" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;

    const sessions = try createSessions(80, 24);
    const host = try gpa.create(app.CockpitHost);
    defer gpa.destroy(host);
    host.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    host.inner.effects.executor = .fake;
    const app_iface = host.app();
    try harness.start(app_iface);

    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.web",
        .key = "3",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.TabId.web, host.inner.model.selected_tab);
    var views_buffer: [4]native_sdk.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    var canvas_focused = false;
    var web_focused = false;
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.canvas_label)) canvas_focused = item.focused;
        if (std.mem.eql(u8, item.label, app.webview_label)) web_focused = item.focused;
    }
    try testing.expect(!canvas_focused);
    try testing.expect(web_focused);

    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.terminal-2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.TabId.terminal_2, host.inner.model.selected_tab);
    views = harness.runtime.listViews(1, &views_buffer);
    canvas_focused = false;
    web_focused = false;
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.canvas_label)) canvas_focused = item.focused;
        if (std.mem.eql(u8, item.label, app.webview_label)) web_focused = item.focused;
    }
    try testing.expect(canvas_focused);
    try testing.expect(!web_focused);

    // Key-up for Cmd+3 stayed with WebKit, but a later Cmd+3 must still work.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.web",
        .key = "3",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.TabId.web, host.inner.model.selected_tab);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .shortcut = .{
        .id = "tab.terminal-2",
        .key = "2",
        .window_id = 1,
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.TabId.terminal_2, host.inner.model.selected_tab);
}

test "pointer tab actions return focus to terminal content and hand off WebKit" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;

    const sessions = try createSessions(80, 24);
    const host = try gpa.create(app.CockpitHost);
    defer gpa.destroy(host);
    host.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    defer destroyModelSessions(&host.inner.model);
    defer host.deinit();
    host.inner.effects.executor = .fake;
    const app_iface = host.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    var terminal_2_frame: ?geometry.RectF = null;
    var web_frame: ?geometry.RectF = null;
    var split_frame: ?geometry.RectF = null;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.indexOf(u8, node.widget.semantics.label, "Terminal 2, native terminal") != null) terminal_2_frame = node.frame;
        if (std.mem.indexOf(u8, node.widget.semantics.label, "Web, system WebKit") != null) web_frame = node.frame;
        if (std.mem.eql(u8, node.widget.text, "Split")) split_frame = node.frame;
    }
    var terminal_1_id: ?canvas.ObjectId = null;
    var web_id: ?canvas.ObjectId = null;
    for (harness.runtime.views[0].widgetSemantics()) |node| {
        if (std.mem.indexOf(u8, node.label, "Terminal 1, native terminal") != null) terminal_1_id = node.id;
        if (std.mem.indexOf(u8, node.label, "Web, system WebKit") != null) web_id = node.id;
    }
    var target = rectCenter(split_frame orelse return error.TestExpectedSplitControl);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.LayoutMode.split, host.inner.model.layout);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.LayoutMode.single, host.inner.model.layout);

    target = rectCenter(terminal_2_frame orelse return error.TestExpectedTab);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.Placement.secondary, host.inner.model.focus_placement);
    try testing.expectEqual(app.TabId.terminal_2, host.inner.model.selected_tab);
    try testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);

    try pressCanvasKey(harness, app_iface, "enter", .{});
    try pressCanvasKey(harness, app_iface, "space", .{});
    try pressCanvasKey(harness, app_iface, "arrowup", .{});
    try testing.expect(host.inner.effects.ptyWrittenBytes(app.ptyKey(1)).len > 2);
    try testing.expectEqualStrings("", host.inner.effects.ptyWrittenBytes(app.ptyKey(0)));

    target = rectCenter(web_frame orelse return error.TestExpectedTab);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.TabId.web, host.inner.model.selected_tab);
    var views_buffer: [4]native_sdk.ViewInfo = undefined;
    var views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.webview_label)) try testing.expect(item.focused);
    }

    // The tab band remains canvas-owned above WebKit, so it can bring the
    // terminal back and clear the tab control's own widget focus atomically.
    target = rectCenter(terminal_2_frame.?);
    try clickCanvas(harness, app_iface, target.x, target.y);
    try testing.expectEqual(app.TabId.terminal_2, host.inner.model.selected_tab);
    try testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| {
        if (std.mem.eql(u8, item.label, app.canvas_label)) try testing.expect(item.focused);
        if (std.mem.eql(u8, item.label, app.webview_label)) try testing.expect(!item.focused);
    }

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app_iface, 1, app.canvas_label, .{
        .id = web_id orelse return error.TestExpectedTab,
        .action = .press,
    });
    try testing.expectEqual(app.TabId.web, host.inner.model.selected_tab);
    views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| if (std.mem.eql(u8, item.label, app.webview_label)) try testing.expect(item.focused);

    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app_iface, 1, app.canvas_label, .{
        .id = terminal_1_id orelse return error.TestExpectedTab,
        .action = .press,
    });
    try testing.expectEqual(app.TabId.terminal_1, host.inner.model.selected_tab);
    views = harness.runtime.listViews(1, &views_buffer);
    for (views) |item| if (std.mem.eql(u8, item.label, app.canvas_label)) try testing.expect(item.focused);
}

test "native tabs are keyboard focusable without stealing initial terminal input" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    var tab_count: usize = 0;
    for (harness.runtime.views[0].widgetSemantics()) |node| {
        if (node.role == .tab) {
            try testing.expect(node.focusable);
            tab_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), tab_count);
    try testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_focused_id);
    try pressCanvasKey(harness, app_iface, "enter", .{});
    try testing.expectEqualStrings("\r", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "only the selected terminal has a cursor command and deactivation hollows it" {
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
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(grid.cursorCommandId(grid.paneIdBase(1))) == null);

    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(grid.cursorCommandId(grid.paneIdBase(0))) == null);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .filled);

    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);
    try expectPaneCursorPaintKind(harness.runtime.views[0].canvasDisplayList(), 1, .hollow);
    try testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(grid.cursorCommandId(grid.paneIdBase(0))) == null);
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
