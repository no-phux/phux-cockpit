//! OSC 8 hyperlinks, and the hover underline that advertises a link.
//!
//! Every test here starts from the ESCAPE SEQUENCE a program actually writes,
//! never from a hand-built link: OSC 8 is parsed by libghostty-vt and the
//! whole point of this work is that the parse reaches the pointer and the
//! painted cell. A hand-built fixture would pass with the plumbing deleted.
//!
//! The refusals carry more weight than the resolutions. OSC 8 is the one
//! channel where remote output picks BOTH what the user reads and where the
//! click goes, so most of what follows is about that gap staying closed.

const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../terminal/grid.zig");
const url = @import("../terminal/url.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const createSession = support.createSession;

/// OSC 8, no id parameter: `open ++ href ++ st` starts a hyperlink and
/// `close_link` ends it. Split into pieces rather than wrapped in a helper so
/// every call site stays a comptime string concatenation.
const open_link = "\x1b]8;;";
const st = "\x1b\\";
const close_link = open_link ++ st;

/// Paint one session and hand back its lattice. Same seam
/// `cell_attribute_tests` uses: the view borrows the builder's stores, so the
/// builder outlives it in the caller's frame.
fn paintGrid(session: *grid.Session, builder: *canvas.Builder) !support.CellGridView {
    try grid.paint(session, builder, .{
        .frame = geometry.RectF.init(0, 0, 400, 200),
        .tokens = .{},
        .running = true,
        .selecting = false,
    });
    return support.expectCellGrid(builder.displayList());
}

/// The middle of cell (col, row), in widget points.
///
/// MEASURED, never assumed: the cell box comes from the painter that just ran
/// (`Session.setMeasuredCell` is its only writer), so this stays right at any
/// font size rather than encoding the estimate for one.
fn cellPoint(session: *grid.Session, col: usize, row: usize) grid.Session.HoverPoint {
    const cell = session.measuredCell().?;
    return .{
        .x = (@as(f32, @floatFromInt(col)) + 0.5) * cell.width,
        .y = (@as(f32, @floatFromInt(row)) + 0.5) * cell.height,
    };
}

fn linkAtCell(session: *grid.Session, col: usize, row: usize) ?grid.Session.Link {
    const point = cellPoint(session, col, row);
    return session.linkAtPoint(point.x, point.y);
}

/// Whether the painted cell carries any underline at all.
fn underlined(view: support.CellGridView, x: usize, y: usize) !bool {
    const flags = view.style(x, y) orelse return error.TestExpectedCell;
    return flags.underline != .none;
}

/// Assert exactly `[start, end)` of row `y` is underlined, out to `width`.
/// The negative half is the load-bearing half: an underline applied to the
/// whole row would satisfy any positive assertion on its own.
fn expectUnderlinedRange(view: support.CellGridView, y: usize, start: usize, end: usize, width: usize) !void {
    var x: usize = 0;
    while (x < width) : (x += 1) {
        const want = x >= start and x < end;
        const got = try underlined(view, x, y);
        if (want != got) {
            std.debug.print(
                "column {d} of row {d}: expected underline={}, got {}\n",
                .{ x, y, want, got },
            );
            return error.TestUnexpectedUnderline;
        }
    }
}

test "an OSC 8 hyperlink resolves through display text that is not a URL" {
    const session = try createSession(40, 6);
    defer session.destroy();
    session.setMeasuredCell(10, 20);

    // ABSENT FIRST: the same words with no OSC 8 around them are not a link,
    // so the assertion below cannot be passing on the text alone.
    session.feed("click here\r\n");
    session.refreshScreenText();
    try testing.expect(linkAtCell(session, 3, 0) == null);

    session.reset();
    session.setMeasuredCell(10, 20);
    session.feed(open_link ++ "https://example.com/docs" ++ st ++ "click here" ++ close_link ++ "\r\n");
    session.refreshScreenText();

    const link = linkAtCell(session, 3, 0) orelse return error.TestExpectedLink;
    try testing.expectEqualStrings("https://example.com/docs", link.url);
    try testing.expectEqual(grid.Session.LinkSource.osc8, link.source);
    // The cells AFTER the link are not part of it.
    try testing.expect(linkAtCell(session, 12, 0) == null);
}

test "REFUSED: an OSC 8 href whose scheme is not a document" {
    // The whole reason the explicit channel needs its own gate. `ls
    // --hyperlink` emits file:// for every name it prints, and a hostile
    // program can emit anything at all.
    const cases = [_][]const u8{
        "file:///etc/passwd",
        "javascript:alert(1)",
        "data:text/html;base64,PHNjcmlwdD4=",
        "vbscript:msgbox(1)",
    };
    for (cases) |href| {
        const session = try createSession(60, 6);
        defer session.destroy();
        session.setMeasuredCell(10, 20);
        session.feed("\x1b]8;;");
        session.feed(href);
        session.feed("\x1b\\report" ++ close_link ++ "\r\n");
        session.refreshScreenText();
        try testing.expect(linkAtCell(session, 2, 0) == null);
    }
}

test "REFUSED: an OSC 8 href carrying control bytes or no target at all" {
    const session = try createSession(60, 6);
    defer session.destroy();
    session.setMeasuredCell(10, 20);
    // A scheme with nothing after it names no destination.
    session.feed(open_link ++ "https://" ++ st ++ "bare" ++ close_link ++ "\r\n");
    session.refreshScreenText();
    try testing.expect(linkAtCell(session, 1, 0) == null);

    // Refused at the module seam too, where the reasoning lives.
    try testing.expect(!url.isAllowedTarget("https://ok.example\x00javascript:alert(1)"));
    try testing.expect(!url.isAllowedTarget("https://ok.example/a b"));
    try testing.expect(!url.isAllowedTarget("https://"));
    try testing.expect(!url.isAllowedTarget(""));
    try testing.expect(url.isAllowedTarget("https://ok.example/a"));
    try testing.expect(url.isAllowedTarget("mailto:a@example.com"));
}

test "a display text that disagrees with its href opens what is on screen" {
    const session = try createSession(60, 6);
    defer session.destroy();
    session.setMeasuredCell(10, 20);
    // The phishing shape: reads as the bank, points at the attacker.
    session.feed(open_link ++ "https://evil.example/steal" ++ st ++ "https://bank.example" ++ close_link ++ "\r\n");
    session.refreshScreenText();

    const link = linkAtCell(session, 5, 0) orelse return error.TestExpectedLink;
    try testing.expectEqualStrings("https://bank.example", link.url);
    // ...and it is reported as read from the TEXT, because that is what it is:
    // the explicit channel lost its indirection, not just its destination.
    try testing.expectEqual(grid.Session.LinkSource.text, link.source);
}

test "a display text that AGREES with its href stays an explicit link" {
    // The control for the test above. Same shape, same code path, and the
    // only difference is that the two destinations match — so a guard that
    // simply refused every URL-shaped display text would fail here.
    const session = try createSession(60, 6);
    defer session.destroy();
    session.setMeasuredCell(10, 20);
    session.feed(open_link ++ "https://bank.example" ++ st ++ "https://bank.example" ++ close_link ++ "\r\n");
    session.refreshScreenText();

    const link = linkAtCell(session, 5, 0) orelse return error.TestExpectedLink;
    try testing.expectEqualStrings("https://bank.example", link.url);
    try testing.expectEqual(grid.Session.LinkSource.osc8, link.source);
}

test "an OSC 8 link beats the URL its own display text happens to contain" {
    // Not a mismatch, because the display text is not a URL at all: the
    // heuristic finds nothing to disagree with, so the explicit target wins
    // over text that merely mentions a host.
    const session = try createSession(60, 6);
    defer session.destroy();
    session.setMeasuredCell(10, 20);
    session.feed(open_link ++ "https://example.com/issue/7" ++ st ++ "issue #7" ++ close_link ++ "\r\n");
    session.refreshScreenText();

    const link = linkAtCell(session, 2, 0) orelse return error.TestExpectedLink;
    try testing.expectEqualStrings("https://example.com/issue/7", link.url);
}

test "hovering an OSC 8 link underlines its whole run and nothing else" {
    const session = try createSession(40, 6);
    defer session.destroy();
    session.feed("ab" ++ open_link ++ "https://example.com/a" ++ st ++ "click here" ++ close_link ++ "cd\r\n");
    session.refreshScreenText();

    // ABSENT: nothing is hovered, so nothing on the row is underlined.
    var before_commands: [512]canvas.CanvasCommand = undefined;
    var before_builder = canvas.Builder.init(&before_commands);
    const before = try paintGrid(session, &before_builder);
    try expectUnderlinedRange(before, 0, 0, 0, 14);

    // ACT: put the pointer inside the link's display text.
    _ = session.setHoverPoint(cellPoint(session, 4, 0));

    // PRESENT: exactly the link's cells, columns 2..12 ("click here"). The
    // "ab" before it and the "cd" after it stay bare.
    var after_commands: [512]canvas.CanvasCommand = undefined;
    var after_builder = canvas.Builder.init(&after_commands);
    const after = try paintGrid(session, &after_builder);
    try expectUnderlinedRange(after, 0, 2, 12, 14);
}

test "hovering a bare URL underlines the run the click would open" {
    const session = try createSession(60, 6);
    defer session.destroy();
    const url_text = "https://example.com/docs";
    session.feed("see " ++ url_text ++ " now\r\n");
    session.refreshScreenText();

    var before_commands: [512]canvas.CanvasCommand = undefined;
    var before_builder = canvas.Builder.init(&before_commands);
    const before = try paintGrid(session, &before_builder);
    try expectUnderlinedRange(before, 0, 0, 0, 32);

    _ = session.setHoverPoint(cellPoint(session, 8, 0));

    var after_commands: [512]canvas.CanvasCommand = undefined;
    var after_builder = canvas.Builder.init(&after_commands);
    const after = try paintGrid(session, &after_builder);
    // "see " is 4 columns; the URL is ASCII so its columns are its bytes.
    try expectUnderlinedRange(after, 0, 4, 4 + url_text.len, 32);
}

test "a hover over ordinary text underlines nothing" {
    const session = try createSession(60, 6);
    defer session.destroy();
    session.feed("see https://example.com/docs now\r\n");
    session.refreshScreenText();

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    _ = try paintGrid(session, &builder);
    // Column 1 is inside the word "see". The pointer is armed and over the
    // same ROW as a link — only the cell it is actually on decides.
    _ = session.setHoverPoint(cellPoint(session, 1, 0));

    var after_commands: [512]canvas.CanvasCommand = undefined;
    var after_builder = canvas.Builder.init(&after_commands);
    const after = try paintGrid(session, &after_builder);
    try expectUnderlinedRange(after, 0, 0, 0, 32);
}

test "a refused OSC 8 href underlines nothing either" {
    // The gate reaches the GLASS, not just the click: a link the app would
    // refuse to open must not be advertised as one it would.
    const session = try createSession(40, 6);
    defer session.destroy();
    session.feed(open_link ++ "file:///etc/passwd" ++ st ++ "passwd" ++ close_link ++ "\r\n");
    session.refreshScreenText();

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    _ = try paintGrid(session, &builder);
    _ = session.setHoverPoint(cellPoint(session, 2, 0));

    var after_commands: [512]canvas.CanvasCommand = undefined;
    var after_builder = canvas.Builder.init(&after_commands);
    const after = try paintGrid(session, &after_builder);
    try expectUnderlinedRange(after, 0, 0, 0, 10);
}

test "the underline follows its text when output scrolls under the pointer" {
    // Why the session stores a POINT and resolves it per frame instead of
    // caching the span the pointer event found: a stationary pointer over a
    // link that scrolls up is no longer over that link, and an underline left
    // behind would be pointing at whatever moved into those cells.
    const session = try createSession(40, 6);
    defer session.destroy();
    session.feed(open_link ++ "https://example.com/a" ++ st ++ "click here" ++ close_link ++ "\r\n");
    session.refreshScreenText();

    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    _ = try paintGrid(session, &builder);
    _ = session.setHoverPoint(cellPoint(session, 4, 0));

    var armed_commands: [512]canvas.CanvasCommand = undefined;
    var armed_builder = canvas.Builder.init(&armed_commands);
    const armed = try paintGrid(session, &armed_builder);
    try expectUnderlinedRange(armed, 0, 0, 10, 14);

    // Print a plain line at the top, pushing the link down a row without the
    // pointer moving at all.
    session.feed("\x1b[H\x1b[Lplain\r\n");
    session.refreshScreenText();

    var moved_commands: [512]canvas.CanvasCommand = undefined;
    var moved_builder = canvas.Builder.init(&moved_commands);
    const moved = try paintGrid(session, &moved_builder);
    // Row 0 now holds "plain", which is not a link; the pointer is still on
    // row 0, so nothing is underlined anywhere.
    try expectUnderlinedRange(moved, 0, 0, 0, 14);
    try expectUnderlinedRange(moved, 1, 0, 0, 14);
}
