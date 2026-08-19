//! Heuristic URL detection over a row of terminal text.
//!
//! Terminal output is not markup: there is no author to tell us where a link
//! starts and stops, only bytes that a human recognises as a URL because of
//! their shape. So this is a heuristic, and it is written to fail toward "not
//! a link" — a missed URL costs a click, a wrong one hands arbitrary terminal
//! output to the OS as something to open.
//!
//! OSC 8 hyperlinks are a separate, EXPLICIT channel the engine already parses;
//! where one exists it should win over anything found here. An explicit target
//! arrives as bytes a program CHOSE rather than bytes a human recognised, so it
//! carries none of the shape guarantees the heuristic gets for free — see
//! `isAllowedTarget`, which is where an OSC 8 href has to earn the same trust
//! this module's own output has by construction.

const std = @import("std");

/// Schemes worth linkifying from raw output.
///
/// Deliberately short. `file:` is absent because a terminal that prints a
/// path should not be able to make the OS open a local file on one click, and
/// `javascript:` because it is not a document at all. The effect layer
/// validates again — this list is the first of two gates, not the only one.
const schemes = [_][]const u8{ "https://", "http://", "mailto:" };

/// The longest run this will call a URL. Long enough for any real link,
/// short enough that a screenful of base64 cannot become one.
pub const max_url_bytes: usize = 2048;

/// Whether an EXPLICITLY supplied target — an OSC 8 href — may be handed on
/// as something to open.
///
/// The heuristic above cannot produce a bad scheme: it only ever returns bytes
/// it matched a scheme in, from text a human can read on screen. An OSC 8 href
/// has neither property. The program picks it, it never has to appear on the
/// glass, and nothing about the DISPLAY text constrains it — so `file://`,
/// `javascript:`, a NUL splice, or a megabyte of base64 all arrive here as
/// ordinary parser output. Every one of them is refused WHOLE (nothing is
/// trimmed, escaped, or coerced into a valid URL), because a target that has
/// to be repaired is a target nobody vetted.
///
/// Deliberately the same shape as the SDK's `validation.validateOpenUrl`,
/// which is the SECOND gate every opened URL still passes. Two gates, not one,
/// and this is the one that runs while the app still knows the bytes came out
/// of a terminal.
pub fn isAllowedTarget(target: []const u8) bool {
    if (target.len == 0 or target.len > max_url_bytes) return false;
    // Control bytes, whitespace, and DEL: a NUL truncates the URL at the C
    // boundary the platform crosses, and the rest never appear in a
    // well-formed URL. Refusing the class means `https://ok\x00javascript:...`
    // cannot survive as its harmless-looking prefix.
    for (target) |byte| {
        // OSC 8 has no visual target of its own. Keep its destination in the
        // same ASCII alphabet as the heuristic so Unicode bidi/formatting
        // controls cannot make the hover preview read as a different URL.
        // Internationalized destinations remain representable in their URL
        // forms (punycode and percent encoding).
        if (byte <= 0x20 or byte >= 0x7f) return false;
    }
    const scheme = matchScheme(target) orelse return false;
    // A bare scheme names no target.
    return target.len > scheme.len;
}

pub const TargetIdentity = struct {
    scheme: []const u8,
    /// The authority that actually receives an HTTP(S) request, excluding
    /// userinfo. Null for non-authority schemes such as mailto.
    effective_authority: ?[]const u8,
};

/// Security identity for an already-allowlisted target.
///
/// HTTP userinfo can be arbitrarily long and can contain host-looking text;
/// only bytes after the LAST `@` decide where navigation goes. Backslashes
/// and percent escapes in the authority are refused because URL consumers do
/// not agree on whether they are separators or decoded host bytes.
pub fn targetIdentity(target: []const u8) ?TargetIdentity {
    if (!isAllowedTarget(target)) return null;
    const scheme = matchScheme(target) orelse return null;
    if (std.ascii.eqlIgnoreCase(scheme, "mailto:")) {
        return .{ .scheme = scheme, .effective_authority = null };
    }

    const rest = target[scheme.len..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '\\') != null) return null;
    const effective = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
        authority[at + 1 ..]
    else
        authority;
    if (effective.len == 0 or std.mem.indexOfScalar(u8, effective, '%') != null) return null;
    if (!validEffectiveAuthority(effective)) return null;
    return .{ .scheme = scheme, .effective_authority = effective };
}

fn validEffectiveAuthority(authority: []const u8) bool {
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        const host = authority[1..close];
        if (host.len == 0) return false;
        for (host) |byte| if (!std.ascii.isHex(byte) and byte != ':' and byte != '.') return false;
        const suffix = authority[close + 1 ..];
        return suffix.len == 0 or (suffix[0] == ':' and validPort(suffix[1..]));
    }

    const colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    const host = if (colon) |at| authority[0..at] else authority;
    if (colon) |at| if (!validPort(authority[at + 1 ..])) return false;
    if (host.len == 0 or host.len > 253) return false;

    var labels = std.mem.splitScalar(u8, host, '.');
    var all_numeric = true;
    var numeric_parts: usize = 0;
    while (labels.next()) |label| {
        if (label.len == 0) return false;
        if (label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        var numeric = true;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
            if (!std.ascii.isDigit(byte)) numeric = false;
        }
        if (numeric) {
            numeric_parts += 1;
            if (label.len > 1 and label[0] == '0') return false;
            const value = std.fmt.parseInt(u8, label, 10) catch return false;
            _ = value;
        } else {
            all_numeric = false;
        }
    }
    // Numeric hosts have several legacy interpretations. Accept only the one
    // unambiguous form browsers agree on: four decimal octets.
    return !all_numeric or numeric_parts == 4;
}

fn validPort(port: []const u8) bool {
    if (port.len == 0 or port.len > 5) return false;
    for (port) |byte| if (!std.ascii.isDigit(byte)) return false;
    const value = std.fmt.parseInt(u16, port, 10) catch return false;
    return value != 0;
}

pub const Span = struct {
    start: usize,
    end: usize,

    pub fn slice(self: Span, row: []const u8) []const u8 {
        return row[self.start..self.end];
    }
};

/// Whether `byte` may appear inside a URL body.
///
/// RFC 3986's unreserved + reserved sets, minus the ones that in practice end
/// a URL when it is embedded in prose or in a log line. Whitespace and control
/// bytes end it; so do quotes, angle brackets, backticks and pipes, which
/// terminals and humans both use to wrap a link.
fn isBodyByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@' => true,
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%' => true,
        else => false,
    };
}

/// The RFC 3986 scheme charset. Used only for the word-boundary guard in
/// `nextFrom` — a scheme preceded by one of these is part of a longer word.
fn isSchemeByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => true,
        else => false,
    };
}

/// Trailing bytes that are almost always punctuation around a link rather than
/// part of it: `see https://example.com.` and `(https://example.com)`.
fn trimTrailing(row: []const u8, start: usize, end_in: usize) usize {
    var end = end_in;
    while (end > start) {
        const last = row[end - 1];
        switch (last) {
            '.', ',', ';', ':', '!', '?', '\'' => end -= 1,
            ')', ']' => {
                // Keep a closing bracket only when the URL opened one, so
                // `(https://en.wikipedia.org/wiki/Foo_(bar))` keeps its inner
                // pair and loses the wrapping one.
                const open: u8 = if (last == ')') '(' else '[';
                var depth: isize = 0;
                for (row[start .. end - 1]) |byte| {
                    if (byte == open) depth += 1;
                    if (byte == last) depth -= 1;
                }
                if (depth > 0) break;
                end -= 1;
            },
            else => break,
        }
    }
    return end;
}

/// The URL span covering byte offset `at`, or null when that byte is not
/// inside one.
pub fn spanAt(row: []const u8, at: usize) ?Span {
    if (at >= row.len) return null;
    var index: usize = 0;
    while (index < row.len) {
        const found = nextFrom(row, index) orelse return null;
        if (at < found.start) return null;
        if (at < found.end) return found;
        index = if (found.end > index) found.end else index + 1;
    }
    return null;
}

/// The first URL at or after `from`.
pub fn nextFrom(row: []const u8, from: usize) ?Span {
    var index = from;
    while (index < row.len) : (index += 1) {
        const rest = row[index..];
        const scheme = matchScheme(rest) orelse continue;
        // A scheme has to start on a WORD boundary, or `nothttps://x`
        // linkifies as `https://x` from inside a longer word.
        //
        // The guard is the RFC 3986 scheme charset, not the body charset:
        // brackets and quotes are body bytes (they can appear inside a URL)
        // but they are also exactly how a link gets wrapped in prose, so
        // treating them as "inside a word" refused `(https://example.com)`
        // outright.
        if (index > 0 and isSchemeByte(row[index - 1])) continue;
        var end = index + scheme.len;
        while (end < row.len and isBodyByte(row[end])) end += 1;
        if (end - index > max_url_bytes) {
            index = end;
            continue;
        }
        const trimmed = trimTrailing(row, index, end);
        // Scheme alone is not a link: `https://` with nothing after it has no
        // host to open.
        if (trimmed <= index + scheme.len) {
            index = end;
            continue;
        }
        return .{ .start = index, .end = trimmed };
    }
    return null;
}

fn matchScheme(rest: []const u8) ?[]const u8 {
    for (schemes) |scheme| {
        if (rest.len < scheme.len) continue;
        if (std.ascii.eqlIgnoreCase(rest[0..scheme.len], scheme)) return scheme;
    }
    return null;
}

/// Display COLUMN of byte offset `offset` in `row` — the inverse of
/// `byteOffsetForColumn`, and carrying exactly the same wide-scalar caveat.
///
/// This is what turns a found span back into the cells to underline, so the
/// underline marks the same characters the click resolves. An offset past the
/// row's end reports the column one past its last scalar, which is the honest
/// answer for an exclusive end.
pub fn columnForByteOffset(row: []const u8, offset: usize) usize {
    var cursor: usize = 0;
    var column: usize = 0;
    while (cursor < row.len and cursor < offset) : (column += 1) {
        const length = std.unicode.utf8ByteSequenceLength(row[cursor]) catch 1;
        cursor += @min(length, row.len - cursor);
    }
    return column;
}

/// Byte offset of display COLUMN `column` in `row`.
///
/// Counts UTF-8 scalars, one per column. Wide (double-width) scalars will
/// drift a column per occurrence; URLs are ASCII, so this is only reachable
/// when wide text precedes one on the same row, and the cost is a hover
/// landing on a neighbouring character rather than a wrong link.
pub fn byteOffsetForColumn(row: []const u8, column: usize) ?usize {
    var offset: usize = 0;
    var seen: usize = 0;
    while (offset < row.len) {
        if (seen == column) return offset;
        const length = std.unicode.utf8ByteSequenceLength(row[offset]) catch 1;
        offset += @min(length, row.len - offset);
        seen += 1;
    }
    return if (seen == column) offset else null;
}
