//! URL detection over terminal output.
//!
//! The bar is not "finds URLs". It is "never turns arbitrary program output
//! into something the OS will open". Every test that refuses something is
//! carrying more weight than the ones that find something.

const std = @import("std");
const url = @import("../terminal/url.zig");
const support = @import("support.zig");

const testing = std.testing;

fn spanText(row: []const u8, at: usize) ?[]const u8 {
    const span = url.spanAt(row, at) orelse return null;
    return span.slice(row);
}

test "a bare URL is found from any byte inside it" {
    const row = "see https://example.com/docs for more";
    const start = std.mem.indexOf(u8, row, "https").?;
    const end = start + "https://example.com/docs".len;

    // Every byte of the URL resolves to the whole URL...
    var at = start;
    while (at < end) : (at += 1) {
        try testing.expectEqualStrings("https://example.com/docs", spanText(row, at) orelse return error.TestExpectedUrl);
    }
    // ...and nothing outside it does.
    try testing.expect(spanText(row, start - 1) == null);
    try testing.expect(spanText(row, end) == null);
}

test "trailing prose punctuation is not part of the link" {
    try testing.expectEqualStrings("https://example.com", spanText("go to https://example.com.", 10) orelse return error.TestExpectedUrl);
    try testing.expectEqualStrings("https://example.com", spanText("https://example.com, then", 3) orelse return error.TestExpectedUrl);
    try testing.expectEqualStrings("https://example.com", spanText("(https://example.com)", 5) orelse return error.TestExpectedUrl);
}

test "a bracket the URL opened itself is kept" {
    const row = "https://en.wikipedia.org/wiki/Foo_(bar)";
    try testing.expectEqualStrings(row, spanText(row, 0) orelse return error.TestExpectedUrl);
    // ...and a wrapping pair around that same URL still comes off.
    const wrapped = "(https://en.wikipedia.org/wiki/Foo_(bar))";
    try testing.expectEqualStrings(row, spanText(wrapped, 5) orelse return error.TestExpectedUrl);
}

test "REFUSED: schemes that are not documents" {
    // The whole point. A terminal prints these all the time.
    try testing.expect(spanText("javascript:alert(1)", 4) == null);
    try testing.expect(spanText("file:///etc/passwd", 4) == null);
    try testing.expect(spanText("data:text/html;base64,PHNjcmlwdD4=", 4) == null);
    try testing.expect(spanText("vbscript:msgbox(1)", 4) == null);
}

test "REFUSED: a scheme buried inside a longer word" {
    try testing.expect(spanText("nothttps://example.com", 8) == null);
    try testing.expect(spanText("xhttp://example.com", 5) == null);
}

test "REFUSED: a scheme with nothing after it" {
    try testing.expect(spanText("https://", 2) == null);
    try testing.expect(spanText("see http:// here", 6) == null);
}

test "REFUSED: an absurdly long run is not a link" {
    const gpa = testing.allocator;
    const row = try gpa.alloc(u8, url.max_url_bytes + 64);
    defer gpa.free(row);
    @memcpy(row[0.."https://".len], "https://");
    @memset(row["https://".len..], 'a');
    try testing.expect(spanText(row, 10) == null);
}

test "two URLs on one row resolve independently" {
    const row = "https://a.example.com and https://b.example.com";
    try testing.expectEqualStrings("https://a.example.com", spanText(row, 3) orelse return error.TestExpectedUrl);
    try testing.expectEqualStrings("https://b.example.com", spanText(row, 30) orelse return error.TestExpectedUrl);
    // The gap between them is not a link.
    const gap = std.mem.indexOf(u8, row, " and ").? + 2;
    try testing.expect(spanText(row, gap) == null);
}

test "mailto is linkified, http and https are case-insensitive" {
    try testing.expectEqualStrings("mailto:a@example.com", spanText("mailto:a@example.com", 3) orelse return error.TestExpectedUrl);
    try testing.expectEqualStrings("HTTPS://EXAMPLE.COM", spanText("HTTPS://EXAMPLE.COM", 3) orelse return error.TestExpectedUrl);
}

test "a column maps to the right byte even after multi-byte text" {
    // A URL preceded by non-ASCII: the column-to-byte mapping has to count
    // scalars, not bytes, or the hover lands in the middle of the scheme.
    const row = "héllo → https://example.com";
    const start = std.mem.indexOf(u8, row, "https").?;
    // "héllo → " is 8 scalars.
    const offset = url.byteOffsetForColumn(row, 8) orelse return error.TestExpectedOffset;
    try testing.expectEqual(start, offset);
    try testing.expectEqualStrings("https://example.com", spanText(row, offset) orelse return error.TestExpectedUrl);
}

test "the pointer resolves a URL printed by a real session" {
    const session = try support.createSession(80, 24);
    defer session.destroy();
    // A 10x20 cell so the column arithmetic below is readable by hand.
    // Through the setter, because that is the only way to record a
    // measurement — see `grid.CellBox`.
    session.setMeasuredCell(10, 20);
    session.feed("open https://example.com/docs now\r\n");
    session.refreshScreenText();

    // Column 8 of row 0 is inside the URL; column 0 is the word "open".
    try testing.expectEqualStrings(
        "https://example.com/docs",
        session.urlAtPoint(85, 5) orelse return error.TestExpectedUrl,
    );
    try testing.expect(session.urlAtPoint(5, 5) == null);
    // Below the printed row there is nothing to open.
    try testing.expect(session.urlAtPoint(85, 105) == null);
}
