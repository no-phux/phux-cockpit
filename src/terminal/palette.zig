//! Emulator-color resolution for terminal grid projection.

const std = @import("std");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");

const canvas = native_sdk.canvas;

/// A theme token color (f32 rgba 0..1) as the emulator's 8-bit RGB.
pub fn themeRgb(color: canvas.Color) vt.color.RGB {
    return .{
        .r = @intFromFloat(std.math.clamp(color.r, 0, 1) * 255 + 0.5),
        .g = @intFromFloat(std.math.clamp(color.g, 0, 1) * 255 + 0.5),
        .b = @intFromFloat(std.math.clamp(color.b, 0, 1) * 255 + 0.5),
    };
}

fn rgbToColor(rgb: vt.color.RGB) canvas.Color {
    return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
}

/// The emulator's color state, resolved for the painter.
///
/// The whole 256-entry palette comes from the EMULATOR, not the UI theme.
/// ANSI-16 used to be derived from `destructive`/`success`/`warning` design
/// tokens plus three hardcoded Tailwind hexes, which is why colored terminal
/// output looked wrong: `\x1b[31m` is a terminal red with a fixed, decades-old
/// meaning that `ls`, diff coloring, and every prompt theme are calibrated
/// against — it is not the UI's "something went wrong" accent. libghostty ships
/// the real defaults (`vt.color.default`, installed by `Terminal.init`), so the
/// projection reads them back verbatim. The cube, grayscale ramp, truecolor,
/// and OSC 4 overrides pass through the same single lookup.
///
/// Only foreground, background, and cursor stay theme-derived, and those the
/// EMULATOR composes: the session pushes tokens into `colors.*.default` so an
/// application's OSC 10/11/12 override still wins.
pub const Palette = struct {
    background: canvas.Color,
    foreground: canvas.Color,
    cursor: canvas.Color,
    selection: canvas.Color,
    terminal: *const vt.RenderState.Colors,
    /// The emulator's live 256-color palette, overrides applied. Read directly
    /// (rather than mirrored into a local array) so OSC 4 lands the same frame.
    dynamic: *const vt.color.DynamicPalette,

    pub fn init(tokens: canvas.DesignTokens, terminal_colors: *const vt.RenderState.Colors, dynamic: *const vt.color.DynamicPalette) Palette {
        const colors = tokens.colors;
        // Resolved render colors already include theme defaults, OSC overrides,
        // and DECSCNM reverse swap.
        return .{
            .background = rgbToColor(terminal_colors.background),
            .foreground = rgbToColor(terminal_colors.foreground),
            .cursor = if (terminal_colors.cursor) |cur| rgbToColor(cur) else colors.accent,
            .selection = colors.accent,
            .terminal = terminal_colors,
            .dynamic = dynamic,
        };
    }

    pub fn indexed(palette: *const Palette, index: u8) canvas.Color {
        const live = palette.dynamic.current[index];
        return canvas.Color.rgb8(live.r, live.g, live.b);
    }

    pub fn resolveFg(palette: *const Palette, style: vt.Style, bg: ?canvas.Color) canvas.Color {
        _ = bg;
        if (style.flags.inverse) return palette.resolveBgRaw(style);
        var color = palette.resolveFgRaw(style);
        if (style.flags.faint) color = blend(color, palette.background, 0.5);
        return color;
    }

    pub fn resolveFgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.fg_color) {
            .none => palette.foreground,
            // Bold-as-bright over the ANSI-8 range, the convention every
            // terminal ships and every prompt theme assumes: `\x1b[1;31m` is
            // bright red. It is the ONLY channel bold has here — the painter
            // draws one mono face and cannot carry a weight axis — so without
            // it a bold-red prompt and a plain-red error render identically.
            // Deliberately NOT applied to the bright range (8-15, already
            // bright), the cube, or truecolor, where the application named an
            // exact color.
            .palette => |index| palette.indexed(
                if (style.flags.bold and index < 8) index + 8 else index,
            ),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }

    fn resolveBgRaw(palette: *const Palette, style: vt.Style) canvas.Color {
        return switch (style.bg_color) {
            .none => palette.background,
            .palette => |index| palette.indexed(index),
            .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
        };
    }
};

pub fn cellBackground(cell: anytype, palette: *const Palette) ?canvas.Color {
    switch (cell.raw.content_tag) {
        .bg_color_palette => return palette.indexed(cell.raw.content.color_palette.data),
        .bg_color_rgb => {
            const rgb = cell.raw.content.color_rgb;
            return canvas.Color.rgb8(rgb.r, rgb.g, rgb.b);
        },
        else => {},
    }
    if (cell.raw.style_id == 0) return null;
    const style = cell.style;
    if (style.flags.inverse) return palette.resolveFgRaw(style);
    return switch (style.bg_color) {
        .none => null,
        .palette => |index| palette.indexed(index),
        .rgb => |rgb| canvas.Color.rgb8(rgb.r, rgb.g, rgb.b),
    };
}

fn blend(a: canvas.Color, b: canvas.Color, t: f32) canvas.Color {
    return canvas.Color.rgba(
        a.r + (b.r - a.r) * t,
        a.g + (b.g - a.g) * t,
        a.b + (b.b - a.b) * t,
        1,
    );
}

fn scale(color: canvas.Color, factor: f32) canvas.Color {
    return canvas.Color.rgba(
        @min(1, color.r * factor),
        @min(1, color.g * factor),
        @min(1, color.b * factor),
        1,
    );
}
