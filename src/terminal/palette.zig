//! Theme and emulator-color resolution for terminal grid projection.

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

/// The theme mapping, stated honestly: where the emulator's palette entry
/// still holds its default value, ANSI-16 derives from active theme tokens.
/// Programmed colors, the cube, grayscale ramp, and truecolor pass through.
pub const Palette = struct {
    background: canvas.Color,
    foreground: canvas.Color,
    cursor: canvas.Color,
    selection: canvas.Color,
    ansi: [16]canvas.Color,
    terminal: *const vt.RenderState.Colors,
    /// The emulator's live palette with its override mask, so OSC 4 wins even
    /// when the programmed value happens to equal the default RGB.
    dynamic: *const vt.color.DynamicPalette,

    pub fn init(tokens: canvas.DesignTokens, terminal_colors: *const vt.RenderState.Colors, dynamic: *const vt.color.DynamicPalette) Palette {
        const colors = tokens.colors;
        const dark = colors.background.r + colors.background.g + colors.background.b < 1.5;
        const dim: f32 = if (dark) 0.85 else 1.0;
        const bright: f32 = if (dark) 1.0 else 0.8;
        // Resolved render colors already include theme defaults, OSC overrides,
        // and DECSCNM reverse swap.
        return .{
            .background = rgbToColor(terminal_colors.background),
            .foreground = rgbToColor(terminal_colors.foreground),
            .cursor = if (terminal_colors.cursor) |cur| rgbToColor(cur) else colors.accent,
            .selection = colors.accent,
            .terminal = terminal_colors,
            .dynamic = dynamic,
            .ansi = .{
                blend(colors.text, colors.background, if (dark) 0.35 else 0.95),
                scale(colors.destructive, dim),
                scale(colors.success, dim),
                scale(colors.warning, dim),
                scale(canvas.Color.rgb8(37, 99, 235), dim),
                scale(canvas.Color.rgb8(147, 51, 234), dim),
                scale(canvas.Color.rgb8(8, 145, 178), dim),
                blend(colors.text, colors.background, if (dark) 0.75 else 0.35),
                blend(colors.text, colors.background, if (dark) 0.5 else 0.75),
                scale(colors.destructive, bright),
                scale(colors.success, bright),
                scale(colors.warning, bright),
                scale(canvas.Color.rgb8(59, 130, 246), bright),
                scale(canvas.Color.rgb8(168, 85, 247), bright),
                scale(canvas.Color.rgb8(34, 211, 238), bright),
                colors.text,
            },
        };
    }

    pub fn indexed(palette: *const Palette, index: u8) canvas.Color {
        if (index < 16 and !palette.dynamic.mask.isSet(index)) return palette.ansi[index];
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
            .palette => |index| palette.indexed(index),
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
