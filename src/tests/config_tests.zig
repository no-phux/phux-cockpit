//! User config parsing.
//!
//! The load path must be forgiving in one specific way: a person's typo in
//! one setting must never cost them the rest of the file, or a broken line
//! silently drops them into a default terminal with no explanation.

const std = @import("std");
const config = @import("../config/config.zig");
const app = @import("../main.zig");

test "an empty or absent config yields usable defaults" {
    const absent = config.loadOrDefault(null);
    try std.testing.expectEqual(config.default_font_size, absent.font_size);
    try std.testing.expectEqual(config.default_scrollback_bytes, absent.scrollback_bytes);
    try std.testing.expectEqual(config.CursorStyle.block, absent.cursor_style);
    try std.testing.expect(absent.inherit_working_directory);
    try std.testing.expectEqual(@as(usize, 0), absent.diagnostic_count);

    const empty = config.parse("");
    try std.testing.expectEqual(config.default_font_size, empty.font_size);
    try std.testing.expectEqual(@as(usize, 0), empty.diagnostic_count);
}

test "the common settings round-trip" {
    const parsed = config.parse(
        \\font-family = JetBrains Mono
        \\font-size = 15.5
        \\cursor-style = bar
        \\cursor-style-blink = false
        \\scrollback-limit = 1048576
        \\shell = /bin/fish
        \\tab-placement = side
        \\window-padding = 12
    );
    try std.testing.expectEqualStrings("JetBrains Mono", parsed.font_family.slice());
    try std.testing.expectApproxEqAbs(@as(f32, 15.5), parsed.font_size, 0.001);
    try std.testing.expectEqual(config.CursorStyle.bar, parsed.cursor_style);
    try std.testing.expect(!parsed.cursor_style_blink);
    try std.testing.expectEqual(@as(u64, 1048576), parsed.scrollback_bytes);
    try std.testing.expectEqualStrings("/bin/fish", parsed.shell.slice());
    try std.testing.expectEqual(config.TabPlacement.side, parsed.tab_placement);
    try std.testing.expectApproxEqAbs(@as(f32, 12), parsed.window_padding, 0.001);
    // `font-family` parses and stores but cannot take effect in this build, so
    // it is reported. Everything else here is honoured silently.
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostic_count);
    try std.testing.expectEqual(config.Diagnostic.Kind.unsupported_key, parsed.diagnosticSlice()[0].kind);
    try std.testing.expectEqualStrings("font-family", parsed.diagnosticSlice()[0].text);
}

test "a key that parses but cannot take effect says so" {
    // The trap this closes: a knob that accepts a value and silently does
    // nothing sends someone hunting for a bug in their terminal instead of
    // reading a line that says the setting is not supported here.
    const parsed = config.parse(
        \\font-family = Comic Mono
        \\selection-foreground = #ff0000
    );
    try std.testing.expectEqual(@as(usize, 2), parsed.diagnostic_count);
    for (parsed.diagnosticSlice()) |diagnostic| {
        try std.testing.expectEqual(config.Diagnostic.Kind.unsupported_key, diagnostic.kind);
    }
    // Still parsed and stored, so the day the capability lands the value is
    // already there.
    try std.testing.expectEqualStrings("Comic Mono", parsed.font_family.slice());
    try std.testing.expect(parsed.selection_foreground != null);
}

test "an unsupported key with a BAD value reports the value, not the support" {
    // One diagnostic per line, and the actionable one wins: the user has to
    // fix the colour before the support question is even interesting.
    const parsed = config.parse("selection-foreground = not-a-color");
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostic_count);
    try std.testing.expectEqual(config.Diagnostic.Kind.bad_value, parsed.diagnosticSlice()[0].kind);
}

test "whitespace and blank lines are irrelevant" {
    const parsed = config.parse("\n   font-size=20\n\n\tcursor-style   =    underline\t\n\n");
    try std.testing.expectApproxEqAbs(@as(f32, 20), parsed.font_size, 0.001);
    try std.testing.expectEqual(config.CursorStyle.underline, parsed.cursor_style);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostic_count);
}

test "whole-line comments are stripped and hex colors are never mistaken for one" {
    const parsed = config.parse(
        \\# a leading comment
        \\background = #1e1e2e
        \\   # an indented comment
        \\foreground = #cdd6f4
        \\font-size = 14
    );
    // The `#` of a color must survive. A "comment starts at any `#` after
    // whitespace" rule would eat both of these.
    try std.testing.expect(parsed.background.?.eql(.{ .r = 0x1e, .g = 0x1e, .b = 0x2e }));
    try std.testing.expect(parsed.foreground.?.eql(.{ .r = 0xcd, .g = 0xd6, .b = 0xf4 }));
    try std.testing.expectApproxEqAbs(@as(f32, 14), parsed.font_size, 0.001);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostic_count);
}

test "a trailing comment is not a comment, and says so instead of guessing" {
    // Trailing comments are unsupported by design. The value is taken
    // literally, fails to parse, and reports — which is recoverable. The
    // alternative rule silently corrupts every color in the file.
    const parsed = config.parse("font-size = 14 # not a comment");
    try std.testing.expectEqual(config.default_font_size, parsed.font_size);
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostic_count);
    try std.testing.expectEqual(config.Diagnostic.Kind.bad_value, parsed.diagnosticSlice()[0].kind);
}

test "colors accept the three shorthand forms" {
    try std.testing.expect(config.Rgb.parse("#ff8000").?.eql(.{ .r = 255, .g = 128, .b = 0 }));
    try std.testing.expect(config.Rgb.parse("ff8000").?.eql(.{ .r = 255, .g = 128, .b = 0 }));
    // `#abc` expands to `#aabbcc`, not `#0a0b0c`.
    try std.testing.expect(config.Rgb.parse("#abc").?.eql(.{ .r = 0xaa, .g = 0xbb, .b = 0xcc }));
    try std.testing.expectEqual(@as(?config.Rgb, null), config.Rgb.parse("#gg0000"));
    try std.testing.expectEqual(@as(?config.Rgb, null), config.Rgb.parse("#12345"));
    try std.testing.expectEqual(@as(?config.Rgb, null), config.Rgb.parse(""));
}

test "palette entries override only the ANSI-16 range" {
    const parsed = config.parse(
        \\palette = 0=#000000
        \\palette = 1=#f38ba8
        \\palette = 15=#ffffff
        \\palette = 16=#123456
        \\palette = 999=#123456
    );
    try std.testing.expect(parsed.palette[0].?.eql(.{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expect(parsed.palette[1].?.eql(.{ .r = 0xf3, .g = 0x8b, .b = 0xa8 }));
    try std.testing.expect(parsed.palette[15].?.eql(.{ .r = 255, .g = 255, .b = 255 }));
    // Out-of-range indices are refused, not clamped onto a real slot.
    try std.testing.expectEqual(@as(usize, 2), parsed.diagnostic_count);
    // Everything not named keeps the engine's own palette.
    try std.testing.expectEqual(@as(?config.Rgb, null), parsed.palette[7]);
}

test "one bad line never costs the rest of the file" {
    const parsed = config.parse(
        \\font-size = enormous
        \\cursor-style = spiral
        \\this-key-does-not-exist = 1
        \\a line with no separator
        \\font-family = Berkeley Mono
        \\tab-placement = side
    );
    // The good settings after the bad ones still applied.
    try std.testing.expectEqualStrings("Berkeley Mono", parsed.font_family.slice());
    try std.testing.expectEqual(config.TabPlacement.side, parsed.tab_placement);
    // The broken ones kept their defaults rather than taking garbage.
    try std.testing.expectEqual(config.default_font_size, parsed.font_size);
    try std.testing.expectEqual(config.CursorStyle.block, parsed.cursor_style);
    // Four broken lines, plus the `font-family` line which parses fine but
    // cannot take effect in this build.
    try std.testing.expectEqual(@as(usize, 5), parsed.diagnostic_count);

    const notes = parsed.diagnosticSlice();
    try std.testing.expectEqual(config.Diagnostic.Kind.bad_value, notes[0].kind);
    try std.testing.expectEqual(@as(u32, 1), notes[0].line);
    try std.testing.expectEqual(config.Diagnostic.Kind.unknown_key, notes[2].kind);
    try std.testing.expectEqual(config.Diagnostic.Kind.missing_separator, notes[3].kind);
}

test "font size is clamped rather than refused, and cannot be wedged" {
    const huge = config.parse("font-size = 9999");
    try std.testing.expectApproxEqAbs(config.max_font_size, huge.font_size, 0.001);
    const tiny = config.parse("font-size = 0.1");
    try std.testing.expectApproxEqAbs(config.min_font_size, tiny.font_size, 0.001);

    // A non-finite value is a diagnostic, not a poisoned layout.
    const bad = config.parse("font-size = nan");
    try std.testing.expectEqual(config.default_font_size, bad.font_size);
    try std.testing.expectEqual(@as(usize, 1), bad.diagnostic_count);

    // The runtime cmd+= / cmd+- path clamps at the same bounds.
    const base = config.Config{};
    try std.testing.expectApproxEqAbs(config.max_font_size, base.withFontSize(1000).font_size, 0.001);
    try std.testing.expectApproxEqAbs(config.min_font_size, base.withFontSize(-5).font_size, 0.001);
}

test "booleans accept the spellings people actually write" {
    for ([_][]const u8{ "true", "yes", "1", "on", "TRUE", "Yes" }) |text| {
        var buffer: [64]u8 = undefined;
        const source = std.fmt.bufPrint(&buffer, "cursor-style-blink = {s}", .{text}) catch unreachable;
        try std.testing.expect(config.parse(source).cursor_style_blink);
    }
    for ([_][]const u8{ "false", "no", "0", "off", "FALSE", "Off" }) |text| {
        var buffer: [64]u8 = undefined;
        const source = std.fmt.bufPrint(&buffer, "cursor-style-blink = {s}", .{text}) catch unreachable;
        try std.testing.expect(!config.parse(source).cursor_style_blink);
    }
    const bad = config.parse("cursor-style-blink = maybe");
    try std.testing.expect(bad.cursor_style_blink); // default preserved
    try std.testing.expectEqual(@as(usize, 1), bad.diagnostic_count);
}

test "scrollback is capped so a typo cannot demand two gigabytes of pages" {
    const parsed = config.parse("scrollback-limit = 999999999999999");
    try std.testing.expectEqual(config.max_scrollback_bytes, parsed.scrollback_bytes);
}

test "an over-long value is reported instead of truncating silently" {
    var buffer: [config.max_font_family_bytes * 2]u8 = undefined;
    @memset(&buffer, 'x');
    var source: [buffer.len + 32]u8 = undefined;
    const text = std.fmt.bufPrint(&source, "font-family = {s}", .{buffer}) catch unreachable;
    const parsed = config.parse(text);
    try std.testing.expectEqual(@as(usize, 0), parsed.font_family.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostic_count);
    try std.testing.expectEqual(config.Diagnostic.Kind.too_long, parsed.diagnosticSlice()[0].kind);
}

test "the diagnostic list is bounded and does not overflow on a hostile file" {
    var source: [4096]u8 = undefined;
    var written: usize = 0;
    for (0..200) |_| {
        const chunk = "nonsense-key = 1\n";
        if (written + chunk.len > source.len) break;
        @memcpy(source[written..][0..chunk.len], chunk);
        written += chunk.len;
    }
    const parsed = config.parse(source[0..written]);
    try std.testing.expectEqual(config.max_diagnostics, parsed.diagnostic_count);
}

test "keys are case-insensitive the way the rest of the format is" {
    const parsed = config.parse(
        \\FONT-SIZE = 18
        \\Cursor-Style = Bar
    );
    try std.testing.expectApproxEqAbs(@as(f32, 18), parsed.font_size, 0.001);
    try std.testing.expectEqual(config.CursorStyle.bar, parsed.cursor_style);
}

test "carriage returns from a CRLF file do not corrupt values" {
    const parsed = config.parse("font-size = 16\r\ncursor-style = bar\r\n");
    try std.testing.expectApproxEqAbs(@as(f32, 16), parsed.font_size, 0.001);
    try std.testing.expectEqual(config.CursorStyle.bar, parsed.cursor_style);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostic_count);
}

test "path joining normalizes a trailing slash instead of doubling it" {
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/a/b", try config.joinDir("/a", "b", &out));
    try std.testing.expectEqualStrings("/a/b", try config.joinDir("/a/", "b", &out));
    try std.testing.expectEqualStrings("/a/config", try config.joinPath("/a", &out));
    try std.testing.expectEqualStrings("/a/config", try config.joinPath("/a/", &out));

    // A destination that cannot hold the result is refused, not truncated — a
    // truncated path is a DIFFERENT path, and silently reading the wrong file
    // is worse than reading none.
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, config.joinDir("/aaa", "bbb", &tiny));
    try std.testing.expectError(error.NoSpaceLeft, config.joinPath("/aaa", &tiny));
}

test "the dotfile config location is where someone coming from Ghostty would put it" {
    var out: [std.fs.max_path_bytes]u8 = undefined;

    // Without XDG set this is ~/.config/phux-cockpit/config, NOT the macOS
    // platform directory app_dirs would choose. Both are searched; this one is
    // searched first, because it is the one people actually write to.
    try std.testing.expectEqualStrings(
        "/Users/someone/.config/phux-cockpit/config",
        app.resolveDotfileConfigPath(.{ .home = "/Users/someone" }, &out).?,
    );

    // XDG_CONFIG_HOME wins when set, which is the entire point of it.
    try std.testing.expectEqualStrings(
        "/elsewhere/phux-cockpit/config",
        app.resolveDotfileConfigPath(
            .{ .home = "/Users/someone", .xdg_config_home = "/elsewhere" },
            &out,
        ).?,
    );

    // An empty XDG value is treated as unset rather than as the filesystem
    // root, so a stray `export XDG_CONFIG_HOME=` cannot aim the config at
    // /phux-cockpit/config.
    try std.testing.expectEqualStrings(
        "/Users/someone/.config/phux-cockpit/config",
        app.resolveDotfileConfigPath(
            .{ .home = "/Users/someone", .xdg_config_home = "" },
            &out,
        ).?,
    );

    // With nothing to anchor on there is no dotfile candidate at all and the
    // caller falls through to the platform location rather than guessing.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        app.resolveDotfileConfigPath(.{}, &out),
    );
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        app.resolveDotfileConfigPath(.{ .home = "" }, &out),
    );
}
