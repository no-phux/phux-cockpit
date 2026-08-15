//! Turning filesystem paths into shell words.
//!
//! A drop from Finder hands this app absolute paths that came from somewhere
//! else entirely — a downloads folder, a shared volume, a repository whose
//! directory names somebody else chose. They land in a shell as a COMMAND
//! LINE, so every byte in them is a byte the shell will interpret unless the
//! quoting stops it.
//!
//! The rule is the same one `providers/local/provider.zig` uses for the
//! inherited working directory, and for the same reason: SINGLE quotes are the
//! only POSIX quoting with no escape sequences of their own, so `$`, backtick,
//! `"`, `\`, `;`, `&`, newlines and spaces are all literal inside them. The one
//! byte that can end the word is `'` itself, which closes, passes an escaped
//! literal, and reopens — `'\''`, four bytes for one.
//!
//! Refusal is WHOLE, never partial. A path list cut short at a buffer edge is
//! not a shorter path list: it is a different path, and pasting a different
//! path into somebody's shell is the failure this module exists to prevent.

const std = @import("std");

/// The most paths one drop contributes. Finder will happily hand over a
/// thousand selected files; a shell line built from a thousand paths is not a
/// command anybody meant to run.
pub const max_dropped_paths: usize = 32;

/// The most quoted bytes one drop contributes, which bounds the caller's
/// staging buffer. Sized so 32 paths average 128 bytes each and a single deep
/// path still fits whole.
pub const max_quoted_bytes: usize = 4096;

/// Quote `paths` into `out` as space-separated shell words, with a trailing
/// space so the next thing typed is a new word rather than a suffix on the
/// last path.
///
/// Null means the drop is refused: too many paths, a path holding a NUL (which
/// no pty write should carry and no path on this platform contains), an empty
/// path, or a result that does not fit. Nothing partial is ever written back to
/// the caller — `out` may have been scribbled in, but the answer is null and
/// the caller has nothing to send.
pub fn quotePaths(paths: []const []const u8, out: []u8) ?[]const u8 {
    if (paths.len == 0 or paths.len > max_dropped_paths) return null;
    var written: usize = 0;
    for (paths) |path| {
        if (path.len == 0) return null;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
        if (!appendByte(out, &written, '\'')) return null;
        for (path) |byte| {
            const piece: []const u8 = if (byte == '\'') "'\\''" else (&byte)[0..1];
            if (!appendSlice(out, &written, piece)) return null;
        }
        if (!appendByte(out, &written, '\'')) return null;
        if (!appendByte(out, &written, ' ')) return null;
    }
    return out[0..written];
}

fn appendByte(out: []u8, written: *usize, byte: u8) bool {
    if (written.* + 1 > out.len) return false;
    out[written.*] = byte;
    written.* += 1;
    return true;
}

fn appendSlice(out: []u8, written: *usize, bytes: []const u8) bool {
    if (written.* + bytes.len > out.len) return false;
    @memcpy(out[written.*..][0..bytes.len], bytes);
    written.* += bytes.len;
    return true;
}
