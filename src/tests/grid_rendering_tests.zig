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
const activeSlots = support.activeSlots;
const destroyModelSessions = app.deinitModel;
const expectCursorPaintKind = support.expectCursorPaintKind;
const expectPaneCursorPaintKind = support.expectPaneCursorPaintKind;
const startFocusedTerminal = support.startFocusedTerminal;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const pressCanvasKey = support.pressCanvasKey;

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

test "the grid paints real text runs with the engine's ANSI palette and exact truecolor" {
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
                    // ANSI 1 is the TERMINAL's red, not the UI's error color.
                    // This used to resolve through `tokens.colors.destructive`,
                    // which meant `\x1b[31m` painted whatever hue the design
                    // system happened to use for destructive buttons — a
                    // number with no relationship to what every other terminal
                    // shows. It now comes from the emulator's own palette.
                    const expected = vt.color.default[1];
                    try testing.expectApproxEqAbs(
                        @as(f32, @floatFromInt(expected.r)) / 255.0,
                        text.color.r,
                        0.01,
                    );
                    try testing.expectApproxEqAbs(
                        @as(f32, @floatFromInt(expected.g)) / 255.0,
                        text.color.g,
                        0.01,
                    );
                    try testing.expectApproxEqAbs(
                        @as(f32, @floatFromInt(expected.b)) / 255.0,
                        text.color.b,
                        0.01,
                    );
                    // And it is specifically NOT the design token any more.
                    try testing.expect(@abs(tokens.colors.destructive.r - text.color.r) > 0.01);
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
    // ANSI 41 is the engine's own red now, not the destructive design token,
    // so the run is identified by the palette entry the emulator actually
    // resolves. What is under test here is the GEOMETRY — that the spacer
    // tail extends the run — not which red it is.
    const ansi_red = vt.color.default[1];
    const expected_r = @as(f32, @floatFromInt(ansi_red.r)) / 255.0;
    var saw_two_cell_bg = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .fill_rect => |fill| {
                if (std.math.approxEqAbs(f32, fill.fill.color.r, expected_r, 0.01) and
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

test "a tall sparse terminal paints its bottom row" {
    const session = try createSession(60, grid.max_rows);
    defer session.destroy();
    for (0..grid.max_rows - 1) |row| {
        if (row % 7 == 0) session.feed("\x1b[32m.\x1b[0m");
        session.feed("\r\n");
    }
    session.feed("\x1b[92mBOTTOM\x1b[0m");

    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try grid.paint(session, &builder, .{
        .frame = geometry.RectF.init(0, 0, 1200, 2400),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .command_budget = 1792,
    });
    var saw_bottom = false;
    for (builder.displayList().commands) |command| switch (command) {
        .draw_text => |text| if (std.mem.indexOf(u8, text.text, "BOTTOM") != null) {
            saw_bottom = true;
        },
        else => {},
    };
    try testing.expect(saw_bottom);
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
    const session = app_state.model.provider.slots[0].session;
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

test "switching terminal Works retains distinct id namespaces the diff accepts" {
    const sessions = try createSessions(20, 6);
    defer for (sessions) |each| each.destroy();
    sessions[0].feed("PANEALPHA\r\n");
    sessions[1].feed("PANEBRAVO\r\n");

    var command_storage: [2][1024]canvas.CanvasCommand = undefined;
    var lists: [2]canvas.DisplayList = undefined;
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

    var painted: [2]usize = @splat(0);
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
