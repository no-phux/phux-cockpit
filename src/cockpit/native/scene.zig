const native_sdk = @import("native_sdk");
const model_module = @import("../model.zig");
const app_types = @import("../app_types.zig");

const canvas = native_sdk.canvas;
const TerminalApp = app_types.TerminalApp;

pub const canvas_label = "phux-cockpit-canvas";
pub const webview_label = "phux-cockpit-web";
pub const webview_anchor = "phux-cockpit-web-pane";
pub const app_name = "Phux Cockpit";
pub const bundle_id = "dev.phux.cockpit";
pub const window_width: f32 = 1100;
pub const window_height: f32 = 640;
pub const window_min_width: f32 = 900;
pub const window_min_height: f32 = 420;
pub const webkit_parking_extent: f32 = 1;

pub const web_origins = [_][]const u8{
    "zero://inline",
    "zero://app",
    "https://github.com",
    "https://www.superlogical.com",
    "https://mitchellh.com",
};

pub const cockpit_shortcuts = [_]native_sdk.Shortcut{
    .{ .id = "surface.1", .key = "1", .modifiers = .{ .primary = true } },
    .{ .id = "surface.2", .key = "2", .modifiers = .{ .primary = true } },
    .{ .id = "surface.3", .key = "3", .modifiers = .{ .primary = true } },
    .{ .id = "surface.4", .key = "4", .modifiers = .{ .primary = true } },
    .{ .id = "surface.5", .key = "5", .modifiers = .{ .primary = true } },
    .{ .id = "tab.previous", .key = "[", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "tab.next", .key = "]", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "terminal.new", .key = "t", .modifiers = .{ .primary = true } },
    .{ .id = "terminal.close", .key = "w", .modifiers = .{ .primary = true } },
    // Splitting is unconditional now: one terminal on a fresh window is a
    // perfectly good thing to split, so the chord registers globally.
    .{ .id = "pane.split-right", .key = "d", .modifiers = .{ .primary = true } },
    .{ .id = "pane.split-down", .key = "d", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "pane.previous", .key = "[", .modifiers = .{ .primary = true } },
    .{ .id = "pane.next", .key = "]", .modifiers = .{ .primary = true } },
    .{ .id = "tab.move-left", .key = "arrowleft", .modifiers = .{ .primary = true, .shift = true } },
    .{ .id = "tab.move-right", .key = "arrowright", .modifiers = .{ .primary = true, .shift = true } },
};

const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Phux Cockpit canvas", .accessibility_label = "Phux Cockpit", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    .{ .label = webview_label, .kind = .webview, .parent = canvas_label, .url = model_module.BrowserPage.github.url(), .x = 0, .y = 0, .width = webkit_parking_extent, .height = webkit_parking_extent, .layer = 20 },
};
/// The window's declared label. `fx.closeWindow` addresses a window by this
/// name, and closing the last tab is how the app exits.
pub const main_window_label = "main";

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = main_window_label,
    .title = app_name,
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub const terminal_font_id: canvas.FontId = canvas.min_registered_font_id;
pub const cockpit_fonts = [_]TerminalApp.FontRegistration{.{
    .id = terminal_font_id,
    .name = "JetBrainsMonoNL Nerd Font Mono Regular",
    .ttf = @embedFile("../../fonts/JetBrainsMonoNLNerdFontMono-Regular.ttf"),
}};
