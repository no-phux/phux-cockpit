//! Built-in colour themes, and the contrast arithmetic that says whether one
//! is readable.
//!
//! WHY A THEME KEY AT ALL. `foreground`, `background` and `selection-background`
//! have existed and worked for a while, and the owner still could not change
//! the colour of their terminal — because doing it meant knowing three key
//! names, three hex values that go together, and where the file lives. A named
//! theme is one word for a set of colours somebody already checked. The
//! explicit keys are not replaced by it; they OUTRANK it (see
//! `Config.resolvedForeground` and friends), so a theme is a starting point
//! rather than a thing that fights you.
//!
//! WHAT A THEME CARRIES, AND WHAT IT DELIBERATELY DOES NOT.
//!
//! A theme sets exactly three colours: `background`, `foreground`, and
//! `selection_background`. Those three, and only those three, reach the
//! terminal through the DESIGN TOKENS — `workspace_projection.terminalTokensFrom`
//! rebuilds them from `model.config` on every frame and `Session.snapshot`
//! pushes them into the emulator's defaults on every frame. That is what makes
//! a theme change repaint LIVE with no invalidation step, no per-session
//! fix-up, and nothing to forget: there is no stored copy of a theme colour
//! anywhere for a stale value to hide in.
//!
//! It deliberately does NOT carry the ANSI-16 palette, the cursor colour, or
//! the cursor style. Those three land in the EMULATOR (see
//! `model.applySessionConfig`) rather than in the tokens, which means they are
//! written once per session and would need an explicit re-apply — and a
//! re-apply has an unsolved half: switching from a theme that sets slot 1 to
//! one that does not cannot un-set it, because the emulator's dynamic palette
//! takes overrides and has no "revert this slot" call here. A knob that
//! applies but cannot un-apply is exactly the trap
//! `Diagnostic.Kind.unsupported_key` exists to avoid. The ANSI-16 slots are
//! also libghostty's own real terminal defaults (see `terminal/palette.zig`),
//! and a terminal red should stay a terminal red. `palette = N=#rrggbb`,
//! `cursor-color` and `cursor-style` remain the explicit knobs for anyone who
//! wants them.

const std = @import("std");

/// A colour, byte per channel. Structurally identical to `config.Rgb` and
/// deliberately declared HERE rather than imported from there: `config.zig`
/// imports this module for theme lookup, and the reverse import would be a
/// cycle.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Theme = struct {
    /// The name `theme = <name>` matches, case-insensitively.
    name: []const u8,
    /// One line for the settings surface. Present tense, no marketing.
    summary: []const u8,
    background: Rgb,
    foreground: Rgb,
    selection_background: Rgb,
};

/// The built-in set, in the order the settings surface lists them.
///
/// `phux-dark` is first because it is what the app already paints with when no
/// theme is named: `cockpitTokens` sets text #f4f7fb on background #090b0f and
/// accent #bef264, and this entry restates exactly those three so that
/// selecting it is a no-op rather than a subtle shift.
///
/// EVERY entry clears WCAG AA for body text (4.5:1). That is not a taste
/// claim, it is pinned by a test — see `settings_theme_tests.zig`, "every
/// built-in theme clears the readout's own AA threshold". Shipping a theme the
/// app's own legibility readout flags would make the readout advice nobody
/// could act on.
///
/// Ratios, from `contrastRatio(foreground, background)`:
///   phux-dark       18.33:1
///   phux-light      17.98:1
///   high-contrast   21.00:1
///   nord             9.25:1
///   gruvbox-dark    10.75:1
///   solarized-dark   5.61:1
pub const builtins = [_]Theme{
    .{
        .name = "phux-dark",
        .summary = "The app's own register: porcelain on deep graphite",
        .background = .{ .r = 0x09, .g = 0x0b, .b = 0x0f },
        .foreground = .{ .r = 0xf4, .g = 0xf7, .b = 0xfb },
        .selection_background = .{ .r = 0xbe, .g = 0xf2, .b = 0x64 },
    },
    .{
        .name = "phux-light",
        .summary = "The same register inverted, for a bright room",
        .background = .{ .r = 0xfb, .g = 0xfc, .b = 0xfe },
        .foreground = .{ .r = 0x10, .g = 0x14, .b = 0x1b },
        .selection_background = .{ .r = 0x84, .g = 0xcc, .b = 0x16 },
    },
    .{
        .name = "high-contrast",
        .summary = "Pure white on pure black, the maximum this display can do",
        .background = .{ .r = 0x00, .g = 0x00, .b = 0x00 },
        .foreground = .{ .r = 0xff, .g = 0xff, .b = 0xff },
        .selection_background = .{ .r = 0xff, .g = 0xd4, .b = 0x00 },
    },
    .{
        .name = "nord",
        .summary = "Cool arctic greys",
        .background = .{ .r = 0x2e, .g = 0x34, .b = 0x40 },
        .foreground = .{ .r = 0xd8, .g = 0xde, .b = 0xe9 },
        .selection_background = .{ .r = 0x88, .g = 0xc0, .b = 0xd0 },
    },
    .{
        .name = "gruvbox-dark",
        .summary = "Warm retro cream on charcoal",
        .background = .{ .r = 0x28, .g = 0x28, .b = 0x28 },
        .foreground = .{ .r = 0xeb, .g = 0xdb, .b = 0xb2 },
        .selection_background = .{ .r = 0xd7, .g = 0x99, .b = 0x21 },
    },
    .{
        .name = "solarized-dark",
        .summary = "The classic low-glare blue-green",
        .background = .{ .r = 0x00, .g = 0x2b, .b = 0x36 },
        .foreground = .{ .r = 0x93, .g = 0xa1, .b = 0xa1 },
        .selection_background = .{ .r = 0x26, .g = 0x8b, .b = 0xd2 },
    },
};

/// The value of `theme` that means "follow the system", and the pair it
/// follows into.
///
/// The pair is `phux-dark` / `phux-light` and nothing else: they are the same
/// register inverted, so a machine crossing sunset changes brightness rather
/// than identity. A `theme = auto` that landed on nord in the dark and
/// solarized in the light would be two terminals wearing one config line.
pub const auto_name = "auto";
pub const auto_dark = "phux-dark";
pub const auto_light = "phux-light";

/// The platform's own light/dark answer, restated here so `config.zig` — which
/// cannot see the SDK — can take one without importing it.
pub const ColorScheme = enum { light, dark };

pub fn isAutoName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, auto_name);
}

/// The theme name a system appearance selects. Total by construction: there is
/// no third scheme, and a missing member of the pair would be a compile error
/// through `builtins` below rather than a runtime fallback.
pub fn forScheme(scheme: ColorScheme) []const u8 {
    return switch (scheme) {
        .dark => auto_dark,
        .light => auto_light,
    };
}

comptime {
    // The pair has to name real themes. Both are built in above, and a rename
    // that broke this would otherwise surface as a `theme = auto` that
    // silently stopped changing anything.
    if (byNameComptime(auto_dark) == null) @compileError("theme.auto_dark names no built-in theme");
    if (byNameComptime(auto_light) == null) @compileError("theme.auto_light names no built-in theme");
}

fn byNameComptime(comptime name: []const u8) ?*const Theme {
    for (&builtins) |*theme| {
        if (std.mem.eql(u8, theme.name, name)) return theme;
    }
    return null;
}

/// The theme a name selects, or null for a name this build does not ship.
/// Case-insensitive, matching every other value the config parser accepts.
pub fn byName(name: []const u8) ?*const Theme {
    for (&builtins) |*theme| {
        if (std.ascii.eqlIgnoreCase(theme.name, name)) return theme;
    }
    return null;
}

/// The index of a named theme in `builtins`, for a settings cursor that has to
/// open ON the theme already in effect rather than at row zero.
pub fn indexOf(name: []const u8) ?usize {
    for (&builtins, 0..) |*theme, index| {
        if (std.ascii.eqlIgnoreCase(theme.name, name)) return index;
    }
    return null;
}

// ------------------------------------------------------------------ contrast

/// The WCAG AA contrast minimum for BODY text (Success Criterion 1.4.3,
/// Contrast (Minimum)). 3:1 is the large-text allowance and does not apply
/// here: a terminal is body text at every size anyone reads it at.
pub const wcag_aa_body_text: f32 = 4.5;
/// The AAA minimum (SC 1.4.6), reported but never used as the pass/fail line.
pub const wcag_aaa_body_text: f32 = 7.0;

/// One sRGB channel, 0..1, linearized.
///
/// WCAG 2.x, "relative luminance":
///   if c <= 0.03928 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
/// The 0.03928 knee is the value the WCAG text itself publishes (the sRGB
/// specification's own knee is 0.04045; the difference is below one 8-bit
/// step and the accessibility threshold is defined against WCAG's number, so
/// WCAG's number is the one used).
fn linearize(channel: f32) f32 {
    if (channel <= 0.03928) return channel / 12.92;
    return std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

/// Relative luminance of an sRGB colour whose channels are already 0..1.
///
/// WCAG 2.x: L = 0.2126 R + 0.7152 G + 0.0722 B over the linearized channels.
/// Taking normalized channels rather than bytes is deliberate: the canvas's
/// own `Color` is f32 0..1, so the app can measure the colour it is ACTUALLY
/// painting with instead of a byte round-trip of the colour it meant to.
pub fn relativeLuminance(r: f32, g: f32, b: f32) f32 {
    return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b);
}

pub fn relativeLuminanceRgb(color: Rgb) f32 {
    return relativeLuminance(
        @as(f32, @floatFromInt(color.r)) / 255.0,
        @as(f32, @floatFromInt(color.g)) / 255.0,
        @as(f32, @floatFromInt(color.b)) / 255.0,
    );
}

/// The contrast ratio between two relative luminances.
///
/// WCAG 2.x: (L_lighter + 0.05) / (L_darker + 0.05). It is SYMMETRIC — which
/// order the two arrive in cannot matter, because "is this readable" is not a
/// question about which one is the ink. Range is 1.0 (identical) to 21.0
/// (black on white).
pub fn contrastRatioLuminance(a: f32, b: f32) f32 {
    const lighter = @max(a, b);
    const darker = @min(a, b);
    return (lighter + 0.05) / (darker + 0.05);
}

pub fn contrastRatio(a: Rgb, b: Rgb) f32 {
    return contrastRatioLuminance(relativeLuminanceRgb(a), relativeLuminanceRgb(b));
}

/// How the readout GRADES a ratio. Three bands rather than a bare number,
/// because a number alone still needs the reader to remember 4.5.
pub const Legibility = enum {
    /// Below 4.5:1. This is the state the owner has been staring at for four
    /// rounds without a way to name it.
    fails_aa,
    /// 4.5:1 or better, below 7:1.
    passes_aa,
    /// 7:1 or better.
    passes_aaa,

    pub fn of(ratio: f32) Legibility {
        if (ratio < wcag_aa_body_text) return .fails_aa;
        if (ratio < wcag_aaa_body_text) return .passes_aa;
        return .passes_aaa;
    }

    pub fn readable(self: Legibility) bool {
        return self != .fails_aa;
    }
};
