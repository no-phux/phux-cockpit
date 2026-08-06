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
    .{ .id = "surface.web", .key = "b", .modifiers = .{ .primary = true, .shift = true } },
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
    .{ .id = "terminal.select-all", .key = "a", .modifiers = .{ .primary = true } },
    .{ .id = "terminal.copy", .key = "c", .modifiers = .{ .primary = true } },
    .{ .id = "terminal.paste", .key = "v", .modifiers = .{ .primary = true } },
    .{ .id = "terminal.clear", .key = "k", .modifiers = .{ .primary = true } },
    // `=` is the physical key; the platform reports the chord as cmd+`=`
    // whether or not shift is down, so ONE registration covers cmd+= and
    // cmd++.
    .{ .id = "view.font-larger", .key = "=", .modifiers = .{ .primary = true } },
    .{ .id = "view.font-smaller", .key = "-", .modifiers = .{ .primary = true } },
    .{ .id = "view.font-reset", .key = "0", .modifiers = .{ .primary = true } },
    .{ .id = "pane.focus-left", .key = "arrowleft", .modifiers = .{ .primary = true, .option = true } },
    .{ .id = "pane.focus-right", .key = "arrowright", .modifiers = .{ .primary = true, .option = true } },
    .{ .id = "pane.focus-up", .key = "arrowup", .modifiers = .{ .primary = true, .option = true } },
    .{ .id = "pane.focus-down", .key = "arrowdown", .modifiers = .{ .primary = true, .option = true } },
};

/// The application menu bar.
///
/// Supplying ANY menu replaces the toolkit's stock File/Edit/View/Window bar
/// wholesale (`appkit_host.m` rebuilds `mainMenu` as the app menu plus these),
/// so everything a terminal user reaches for has to be re-stated here — the
/// stock Edit menu's Copy/Paste went through the AppKit responder chain and
/// never reached a terminal pane anyway, which is exactly why three
/// `onCommand` entries had no way to fire.
///
/// Every item's `command` is a name `view.onCommand` already answers, so the
/// menu adds a surface, never a second code path. The key equivalents mirror
/// the registered shortcuts on purpose: the model's shortcut latch keys on the
/// physical key, so one edge executes once regardless of which channel
/// delivered it.
const shell_menu_items = [_]native_sdk.MenuItem{
    .{ .label = "New Tab", .command = "terminal.new", .key = "t", .modifiers = .{ .primary = true } },
    .{ .label = "Split Right", .command = "pane.split-right", .key = "d", .modifiers = .{ .primary = true } },
    .{ .label = "Split Down", .command = "pane.split-down", .key = "d", .modifiers = .{ .primary = true, .shift = true } },
    .{ .separator = true },
    .{ .label = "Close", .command = "terminal.close", .key = "w", .modifiers = .{ .primary = true } },
};

const edit_menu_items = [_]native_sdk.MenuItem{
    .{ .label = "Copy", .command = "terminal.copy", .key = "c", .modifiers = .{ .primary = true } },
    .{ .label = "Paste", .command = "terminal.paste", .key = "v", .modifiers = .{ .primary = true } },
    .{ .separator = true },
    .{ .label = "Select All", .command = "terminal.select-all", .key = "a", .modifiers = .{ .primary = true } },
    .{ .label = "Clear", .command = "terminal.clear", .key = "k", .modifiers = .{ .primary = true } },
};

const view_menu_items = [_]native_sdk.MenuItem{
    .{ .label = "Increase Font Size", .command = "view.font-larger", .key = "=", .modifiers = .{ .primary = true } },
    .{ .label = "Decrease Font Size", .command = "view.font-smaller", .key = "-", .modifiers = .{ .primary = true } },
    .{ .label = "Reset Font Size", .command = "view.font-reset", .key = "0", .modifiers = .{ .primary = true } },
    .{ .separator = true },
    .{ .label = "Toggle Tab Placement", .command = "tabs.toggle-placement" },
    .{ .label = "Web Surface", .command = "surface.web", .key = "b", .modifiers = .{ .primary = true, .shift = true } },
};

const window_menu_items = [_]native_sdk.MenuItem{
    .{ .label = "Previous Tab", .command = "tab.previous", .key = "[", .modifiers = .{ .primary = true, .shift = true } },
    .{ .label = "Next Tab", .command = "tab.next", .key = "]", .modifiers = .{ .primary = true, .shift = true } },
    .{ .separator = true },
    .{ .label = "Move Tab Left", .command = "tab.move-left", .key = "arrowleft", .modifiers = .{ .primary = true, .shift = true } },
    .{ .label = "Move Tab Right", .command = "tab.move-right", .key = "arrowright", .modifiers = .{ .primary = true, .shift = true } },
    .{ .separator = true },
    .{ .label = "Previous Pane", .command = "pane.previous", .key = "[", .modifiers = .{ .primary = true } },
    .{ .label = "Next Pane", .command = "pane.next", .key = "]", .modifiers = .{ .primary = true } },
};

pub const cockpit_menus = [_]native_sdk.Menu{
    .{ .title = "Shell", .items = &shell_menu_items },
    .{ .title = "Edit", .items = &edit_menu_items },
    .{ .title = "View", .items = &view_menu_items },
    .{ .title = "Window", .items = &window_menu_items },
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
