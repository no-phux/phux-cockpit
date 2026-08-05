//! User configuration.
//!
//! A terminal someone actually lives in has to be theirs: their font, their
//! size, their colors, their shell. Until now Cockpit had no knob at all —
//! every one of these was a literal in the source.
//!
//! The syntax is deliberately Ghostty's, because that is what the people
//! switching already have in their fingers: one `key = value` per line,
//! `#` starts a comment, blank lines are ignored, and an unknown key is a
//! warning rather than a fatal error so a config written for a newer build
//! still loads on an older one.
//!
//! Parsing is allocation-free. Strings are copied into fixed buffers owned
//! by the `Config` itself, so a loaded config outlives the file bytes and
//! can be embedded directly in the model.

const std = @import("std");

/// Bounds. These are generous for their purpose and keep `Config` a plain
/// value type that can be copied without an allocator.
pub const max_font_family_bytes: usize = 128;
pub const max_shell_bytes: usize = 512;
pub const max_theme_name_bytes: usize = 64;
pub const max_diagnostics: usize = 16;
pub const max_config_bytes: usize = 64 * 1024;

pub const palette_len: usize = 16;

pub const CursorStyle = enum {
    block,
    bar,
    underline,

    pub fn parse(text: []const u8) ?CursorStyle {
        if (eq(text, "block")) return .block;
        if (eq(text, "bar") or eq(text, "beam")) return .bar;
        if (eq(text, "underline")) return .underline;
        return null;
    }
};

pub const TabPlacement = enum {
    top,
    side,

    pub fn parse(text: []const u8) ?TabPlacement {
        if (eq(text, "top")) return .top;
        if (eq(text, "side") or eq(text, "sidebar")) return .side;
        return null;
    }
};

pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// Accepts `#rrggbb`, `rrggbb`, and the `#rgb` shorthand, which is what
    /// people paste out of a theme file.
    pub fn parse(text: []const u8) ?Rgb {
        const body = if (text.len > 0 and text[0] == '#') text[1..] else text;
        switch (body.len) {
            3 => {
                const r = hexDigit(body[0]) orelse return null;
                const g = hexDigit(body[1]) orelse return null;
                const b = hexDigit(body[2]) orelse return null;
                // `#abc` means `#aabbcc`, not `#0a0b0c`.
                return .{ .r = r * 17, .g = g * 17, .b = b * 17 };
            },
            6 => {
                const r = hexByte(body[0..2]) orelse return null;
                const g = hexByte(body[2..4]) orelse return null;
                const b = hexByte(body[4..6]) orelse return null;
                return .{ .r = r, .g = g, .b = b };
            },
            else => return null,
        }
    }
};

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexByte(pair: []const u8) ?u8 {
    const high = hexDigit(pair[0]) orelse return null;
    const low = hexDigit(pair[1]) orelse return null;
    return high * 16 + low;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// A parse problem, kept rather than thrown. A single bad line must not cost
/// someone every other setting in the file.
pub const Diagnostic = struct {
    pub const Kind = enum { unknown_key, bad_value, missing_separator, too_long };

    line: u32 = 0,
    kind: Kind = .bad_value,
    /// Borrowed from the source bytes; only valid while they live. Callers
    /// that outlive the bytes should render diagnostics before dropping them.
    text: []const u8 = "",
};

/// A bounded string field that owns its bytes.
fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = [_]u8{0} ** capacity,
        len: usize = 0,

        pub fn init(value: []const u8) Self {
            var self: Self = .{};
            self.set(value) catch {};
            return self;
        }

        pub fn set(self: *Self, value: []const u8) error{TooLong}!void {
            if (value.len > capacity) return error.TooLong;
            @memcpy(self.bytes[0..value.len], value);
            self.len = value.len;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

pub const FontFamily = Text(max_font_family_bytes);
pub const Shell = Text(max_shell_bytes);
pub const ThemeName = Text(max_theme_name_bytes);

/// Font size bounds. Below 4pt the grid degenerates; above 72pt a default
/// window holds almost no cells. Both ends are clamps, not errors, so a
/// runaway cmd+= cannot wedge the app.
pub const min_font_size: f32 = 4;
pub const max_font_size: f32 = 72;
pub const default_font_size: f32 = 13;

/// Scrollback bounds, in bytes. Ghostty's default is 50 MB and that is what
/// a daily driver needs; the old 1 MB held only a few hundred rows.
pub const default_scrollback_bytes: u64 = 50 * 1024 * 1024;
pub const max_scrollback_bytes: u64 = 2 * 1024 * 1024 * 1024;

pub const Config = struct {
    font_family: FontFamily = FontFamily.init(""),
    font_size: f32 = default_font_size,
    theme: ThemeName = ThemeName.init(""),

    /// Null means "the palette the terminal engine ships", which is a real
    /// terminal palette. Only an explicit `palette = N=#rrggbb` overrides it.
    palette: [palette_len]?Rgb = [_]?Rgb{null} ** palette_len,
    background: ?Rgb = null,
    foreground: ?Rgb = null,
    cursor_color: ?Rgb = null,
    selection_background: ?Rgb = null,
    selection_foreground: ?Rgb = null,

    cursor_style: CursorStyle = .block,
    cursor_style_blink: bool = true,

    scrollback_bytes: u64 = default_scrollback_bytes,

    /// Empty means "the user's login shell", resolved at spawn time.
    shell: Shell = Shell.init(""),

    /// A new terminal or split starts in the focused pane's directory, the
    /// way Ghostty does, unless this is turned off.
    inherit_working_directory: bool = true,

    tab_placement: TabPlacement = .top,
    /// At rest a single healthy terminal shows no chrome at all.
    hide_chrome_when_single: bool = true,

    window_padding: f32 = 8,

    diagnostics: [max_diagnostics]Diagnostic = [_]Diagnostic{.{}} ** max_diagnostics,
    diagnostic_count: usize = 0,

    pub fn fontSize(config: *const Config) f32 {
        return std.math.clamp(config.font_size, min_font_size, max_font_size);
    }

    /// Font sizing steps by whole points, which is what cmd+= / cmd+- do in
    /// every Mac terminal. Returns the clamped result so callers can tell
    /// when they hit the end of the range.
    pub fn withFontSize(config: Config, size: f32) Config {
        var next = config;
        next.font_size = std.math.clamp(size, min_font_size, max_font_size);
        return next;
    }

    fn note(config: *Config, line: u32, kind: Diagnostic.Kind, text: []const u8) void {
        if (config.diagnostic_count >= max_diagnostics) return;
        config.diagnostics[config.diagnostic_count] = .{ .line = line, .kind = kind, .text = text };
        config.diagnostic_count += 1;
    }

    pub fn diagnosticSlice(config: *const Config) []const Diagnostic {
        return config.diagnostics[0..config.diagnostic_count];
    }
};

/// Parse a config file's bytes. Never fails: a malformed line becomes a
/// diagnostic and the remaining lines still apply. This is deliberate —
/// a typo in one setting must not drop someone into a default terminal.
pub fn parse(source: []const u8) Config {
    var config: Config = .{};
    var line_number: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line = trim(stripComment(raw_line));
        if (line.len == 0) continue;

        const separator = std.mem.indexOfScalar(u8, line, '=') orelse {
            config.note(line_number, .missing_separator, line);
            continue;
        };
        const key = trim(line[0..separator]);
        const value = trim(line[separator + 1 ..]);
        if (key.len == 0) {
            config.note(line_number, .missing_separator, line);
            continue;
        }
        applyPair(&config, line_number, key, value);
    }
    return config;
}

fn applyPair(config: *Config, line: u32, key: []const u8, value: []const u8) void {
    // `palette = N=#rrggbb` is the one compound key, and it is the shape
    // Ghostty themes are written in, so it is worth the special case.
    if (eq(key, "palette")) {
        applyPalette(config, line, value);
        return;
    }

    if (eq(key, "font-family")) {
        config.font_family.set(value) catch config.note(line, .too_long, value);
        return;
    }
    if (eq(key, "font-size")) {
        const parsed = std.fmt.parseFloat(f32, value) catch {
            config.note(line, .bad_value, value);
            return;
        };
        if (!std.math.isFinite(parsed)) {
            config.note(line, .bad_value, value);
            return;
        }
        // Out-of-range is clamped rather than refused: the intent is clear.
        config.font_size = std.math.clamp(parsed, min_font_size, max_font_size);
        return;
    }
    if (eq(key, "theme")) {
        config.theme.set(value) catch config.note(line, .too_long, value);
        return;
    }
    if (eq(key, "background")) return setColor(config, line, &config.background, value);
    if (eq(key, "foreground")) return setColor(config, line, &config.foreground, value);
    if (eq(key, "cursor-color")) return setColor(config, line, &config.cursor_color, value);
    if (eq(key, "selection-background")) return setColor(config, line, &config.selection_background, value);
    if (eq(key, "selection-foreground")) return setColor(config, line, &config.selection_foreground, value);

    if (eq(key, "cursor-style")) {
        config.cursor_style = CursorStyle.parse(value) orelse {
            config.note(line, .bad_value, value);
            return;
        };
        return;
    }
    if (eq(key, "cursor-style-blink")) return setBool(config, line, &config.cursor_style_blink, value);
    if (eq(key, "inherit-working-directory")) return setBool(config, line, &config.inherit_working_directory, value);
    if (eq(key, "hide-chrome-when-single")) return setBool(config, line, &config.hide_chrome_when_single, value);

    if (eq(key, "scrollback-limit")) {
        const parsed = std.fmt.parseInt(u64, value, 10) catch {
            config.note(line, .bad_value, value);
            return;
        };
        config.scrollback_bytes = @min(parsed, max_scrollback_bytes);
        return;
    }
    if (eq(key, "shell") or eq(key, "command")) {
        config.shell.set(value) catch config.note(line, .too_long, value);
        return;
    }
    if (eq(key, "tab-placement")) {
        config.tab_placement = TabPlacement.parse(value) orelse {
            config.note(line, .bad_value, value);
            return;
        };
        return;
    }
    if (eq(key, "window-padding")) {
        const parsed = std.fmt.parseFloat(f32, value) catch {
            config.note(line, .bad_value, value);
            return;
        };
        if (!std.math.isFinite(parsed) or parsed < 0 or parsed > 64) {
            config.note(line, .bad_value, value);
            return;
        }
        config.window_padding = parsed;
        return;
    }

    config.note(line, .unknown_key, key);
}

fn applyPalette(config: *Config, line: u32, value: []const u8) void {
    const separator = std.mem.indexOfScalar(u8, value, '=') orelse {
        config.note(line, .bad_value, value);
        return;
    };
    const index_text = trim(value[0..separator]);
    const color_text = trim(value[separator + 1 ..]);
    const index = std.fmt.parseInt(usize, index_text, 10) catch {
        config.note(line, .bad_value, value);
        return;
    };
    // Only the ANSI-16 range is overridable here; 16-255 is the standard
    // cube and greyscale ramp, which the engine derives.
    if (index >= palette_len) {
        config.note(line, .bad_value, value);
        return;
    }
    const color = Rgb.parse(color_text) orelse {
        config.note(line, .bad_value, value);
        return;
    };
    config.palette[index] = color;
}

fn setColor(config: *Config, line: u32, field: *?Rgb, value: []const u8) void {
    field.* = Rgb.parse(value) orelse {
        config.note(line, .bad_value, value);
        return;
    };
}

fn setBool(config: *Config, line: u32, field: *bool, value: []const u8) void {
    if (eq(value, "true") or eq(value, "yes") or eq(value, "1") or eq(value, "on")) {
        field.* = true;
        return;
    }
    if (eq(value, "false") or eq(value, "no") or eq(value, "0") or eq(value, "off")) {
        field.* = false;
        return;
    }
    config.note(line, .bad_value, value);
}

/// A `#` starts a comment ONLY at the start of a line (after any leading
/// whitespace). There are deliberately no trailing comments: `#` is also
/// how every color value begins, and a rule like "a `#` after whitespace
/// ends the line" silently eats `background = #1e1e2e`. Ghostty makes the
/// same call, so a config carried over from it behaves identically.
fn stripComment(line: []const u8) []const u8 {
    const body = std.mem.trimStart(u8, line, " \t");
    if (body.len > 0 and body[0] == '#') return line[0..0];
    return line;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

/// The file name inside the resolved config directory. The caller resolves
/// the directory itself (the SDK's `app_dirs` knows the platform rules), so
/// this module keeps no ambient dependency and stays unit-testable.
pub const file_name = "config";

/// Join a resolved config directory with the config file name.
pub fn joinPath(config_dir: []const u8, output: []u8) error{NoSpaceLeft}![]const u8 {
    const separator: []const u8 = if (config_dir.len > 0 and config_dir[config_dir.len - 1] == '/') "" else "/";
    const total = config_dir.len + separator.len + file_name.len;
    if (total > output.len) return error.NoSpaceLeft;
    @memcpy(output[0..config_dir.len], config_dir);
    @memcpy(output[config_dir.len..][0..separator.len], separator);
    @memcpy(output[config_dir.len + separator.len ..][0..file_name.len], file_name);
    return output[0..total];
}

/// Parse bytes the caller read, or fall back to defaults when there were
/// none. A missing config is the normal case, not an error — file IO stays
/// with the caller so this module has no ambient dependency and stays
/// trivially testable.
pub fn loadOrDefault(bytes: ?[]const u8) Config {
    return parse(bytes orelse return .{});
}
