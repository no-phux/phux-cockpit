const native_sdk = @import("native_sdk");
const grid = @import("../../terminal/grid.zig");
const support = @import("../phux_support.zig");
const local = @import("../../providers/local/provider.zig");
const model_module = @import("../model.zig");
const topology = @import("../topology.zig");
const layout = @import("../layout.zig");
const scene = @import("scene.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Model = model_module.Model;
const Pane = local.Pane;
const TerminalRef = support.TerminalRef;

/// The default gutter between the window edge and the terminal. `window-padding`
/// overrides it; `windowPadding` is the accessor everything geometric uses so
/// the painter, the widget tree, and the PTY pump cannot disagree.
pub const grid_inset: f32 = 8;

/// The configured gutter, clamped to what the config parser already accepts
/// (0..64). Kept as a function rather than a field read so a future
/// per-window padding has one seam to change.
pub fn windowPadding(model: *const Model) f32 {
    return @max(0, model.config.window_padding);
}
/// The tab band's height. It must be at least the register's own trigger
/// height, or the strip overflows the band and paints its hairline and
/// underline indicator down into the terminal's first row. The Geist pack
/// computes 50 at the default control size (`metrics.tabs_trigger_height`),
/// and `headerHeightCoversTriggers` pins the two together.
pub const header_height: f32 = 50;
/// Tab geometry. Lives here rather than in the view because the visible-window
/// derivation below is the thing tests pin, and it needs the same numbers the
/// strip lays out with.
pub const tab_extent: f32 = 168;
/// Tabs SHRINK before the strip windows, the way every real tab bar does. 92pt
/// still holds a readable ~10-character title plus the marker and the close
/// affordance; below that a tab is a swatch, not a label.
pub const tab_min_extent: f32 = 92;
pub const tab_height: f32 = 34;
pub const tab_control_extent: f32 = 18;
pub const tab_marker_extent: f32 = 8;
pub const tab_indicator_thickness: f32 = 2;
/// Room held back at the right of the band for the `+` button and the focused
/// pane's status, so a full strip never pushes either off the edge.
pub const tab_strip_trailing_reserve: f32 = 220;

pub const TabWindow = struct {
    first: usize = 0,
    count: usize = 0,
    /// The width each visible tab lays out at, between `tab_min_extent` and
    /// `tab_extent`.
    extent: f32 = tab_extent,

    pub fn contains(window: TabWindow, index: usize) bool {
        return index >= window.first and index < window.first + window.count;
    }
};

/// The contiguous run of tabs the strip shows, ALWAYS containing the selected
/// one.
///
/// This replaces the old fixed 8-slot tuple, which simply did not draw tabs
/// 9..16 at all. It is deliberately a derivation rather than a scroll widget:
/// the toolkit's `scroll_view` is keyboard-focusable and consumes arrow keys,
/// so a scroller in the tab band means a shell's Tab key can move focus onto
/// the strip and the NEXT arrow key scrolls tabs instead of walking history.
/// A window that follows selection gives scroll-into-view without putting a
/// keyboard trap above the terminal.
pub fn visibleTabWindow(model: *const Model, band_width: f32) TabWindow {
    if (model.tab_count == 0) return .{};
    const usable = @max(tab_min_extent, band_width - tab_strip_trailing_reserve);
    // Shrink first, window second. A strip that windowed at full tab width
    // would hide tab 4 in a 900pt window while leaving 200pt of gutter.
    const capacity: usize = @max(1, @as(usize, @intFromFloat(@floor(usable / tab_min_extent))));
    const shown = @min(capacity, model.tab_count);
    const extent = @min(tab_extent, usable / @as(f32, @floatFromInt(shown)));
    if (shown == model.tab_count) return .{ .first = 0, .count = shown, .extent = extent };
    const selected = @min(model.selected_tab, model.tab_count - 1);
    // Anchor at the left until the selection walks past the right edge, then
    // keep the selection as the LAST visible tab. Recentering on every step
    // would make neighbouring tabs jump under the pointer.
    const first = if (selected < shown) 0 else selected - shown + 1;
    return .{ .first = first, .count = shown, .extent = extent };
}

pub const side_rail_width: f32 = 184;
pub const side_rail_gap: f32 = 8;
pub const side_tab_height: f32 = 34;
pub const split_divider_width: f32 = 9;
pub const split_pane_min_width: f32 = 240;
pub const split_pane_min_height: f32 = 80;
pub const webkit_parking_extent = scene.webkit_parking_extent;
const widget_command_reserve: usize = canvas.terminal_grid.widget_command_reserve;
pub const chrome_command_envelope: usize = native_sdk.runtime.max_canvas_commands_per_view - widget_command_reserve;

pub fn cockpitTokens(_: *const Model) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.themeWithOverrides(
        .{ .color_scheme = .dark, .pack = .geist },
        canvas.accentOverrides(canvas.Color.rgb8(190, 242, 100), .dark),
    );
    tokens.colors.background = canvas.Color.rgb8(9, 11, 15);
    tokens.colors.surface = canvas.Color.rgb8(17, 20, 27);
    tokens.colors.surface_subtle = canvas.Color.rgb8(23, 27, 35);
    tokens.colors.surface_pressed = canvas.Color.rgb8(35, 41, 52);
    tokens.colors.text = canvas.Color.rgb8(244, 247, 251);
    tokens.colors.text_muted = canvas.Color.rgb8(154, 164, 178);
    tokens.colors.border = canvas.Color.rgb8(52, 58, 70);
    tokens.colors.accent = canvas.Color.rgb8(190, 242, 100);
    tokens.colors.accent_text = canvas.Color.rgb8(9, 11, 15);
    tokens.colors.warning = canvas.Color.rgb8(253, 224, 71);
    tokens.colors.destructive = canvas.Color.rgb8(248, 113, 113);
    tokens.typography.mono_font_id = scene.terminal_font_id;
    // Naming the companions is what turns a carried `bold`/`italic` flag into
    // a different glyph. Left unset, the renderers synthesize instead — which
    // they do consistently, but a double-struck regular is not a bold face.
    tokens.typography.mono_bold_font_id = scene.terminal_bold_font_id;
    tokens.typography.mono_italic_font_id = scene.terminal_italic_font_id;
    tokens.typography.mono_bold_italic_font_id = scene.terminal_bold_italic_font_id;
    return tokens;
}

/// The tokens the TERMINAL GRIDS paint with — deliberately not the chrome's.
///
/// `canvas.terminalCellMetrics` derives the cell box from
/// `typography.label_size`, and that same token sizes every widget label in
/// the app. Driving one token from the `font-size` knob would grow the tab
/// strip along with the terminal, which no Mac terminal does. Splitting the
/// two here costs one extra token value per frame and keeps the chrome fixed
/// while cmd+= walks the grid.
pub fn terminalTokens(model: *const Model) canvas.DesignTokens {
    return terminalTokensFrom(cockpitTokens(model), model);
}

/// The same derivation over an ALREADY-RESOLVED token set.
///
/// Taking a base rather than rebuilding one is load-bearing. The runtime
/// stamps its text-measure provider onto the tokens it hands the chrome
/// builder, and `canvas.terminalCellMetrics` measures the mono face's real
/// advance through that provider. Rebuilding from `cockpitTokens` inside the
/// painter would silently drop it and fall back to the `label_size * 0.6`
/// estimate — a cell width nothing else in the app agrees with, which is
/// exactly how a default-config launch would start reporting mouse positions
/// against a grid it is not painting.
pub fn terminalTokensFrom(base: canvas.DesignTokens, model: *const Model) canvas.DesignTokens {
    var tokens = base;
    const cfg = &model.config;
    tokens.typography.label_size = model.fontSize();
    // Background/foreground land in the emulator's own DEFAULTS through
    // `Session.snapshot`, so an application's OSC 10/11 still wins over them.
    if (cfg.background) |color| tokens.colors.background = canvas.Color.rgb8(color.r, color.g, color.b);
    if (cfg.foreground) |color| tokens.colors.text = canvas.Color.rgb8(color.r, color.g, color.b);
    // The selection wash reads `colors.accent` (see `palette.Palette.init`).
    // The cursor does NOT come through here — `applySessionConfig` gives it
    // the emulator's override channel so the two knobs stay independent.
    if (cfg.selection_background) |color| tokens.colors.accent = canvas.Color.rgb8(color.r, color.g, color.b);
    return tokens;
}

/// The band must be able to contain the tab triggers it hosts. The register
/// sizes an underline trigger from `metrics.tabs_trigger_height`, scaled by
/// density and the widget's size rung; the strip declares no size rung, so
/// the metric IS the height.
pub fn tabTriggerHeight(model: *const Model) f32 {
    return cockpitTokens(model).metrics.tabs_trigger_height;
}

pub fn paneLifecycleFailed(pane: *const Pane) bool {
    return pane.phase == .failed or (pane.phase == .ended and (pane.exit_reason != .exited or pane.exit_code != 0));
}

pub fn paneHasConfirmedLoss(pane: *const Pane) bool {
    return pane.outbound_dropped > 0 or pane.session.response_bytes_dropped > 0;
}

fn paneNeedsAttention(model: *const Model, pane: *const Pane) bool {
    const paste_failed = model.paste_owner.terminal_ref.eql(pane.id) and model.paste_failed;
    // The BELL is the signal a shell actually sends on purpose — a finished
    // build, a prompt waiting on input — and it was being dropped on the
    // floor. It latches until the tab is looked at (`acknowledgeVisibleBells`),
    // so it survives arriving while the tab is hidden, which is the only time
    // it matters.
    return pane.bellRung() or
        pane.phase == .ended or pane.phase == .failed or paneHasConfirmedLoss(pane) or
        pane.write_refusals > 0 or pane.native_delivery_failures > 0 or pane.copy_failed or paste_failed;
}

pub fn terminalNeedsAttention(model: *const Model, id: TerminalRef) bool {
    if (model.provider.terminalConst(id)) |pane| return paneNeedsAttention(model, pane);
    const presentation = model.remotePresentation(id) orelse return true;
    return presentation.phase == .failed or presentation.phase == .tombstoned;
}

pub fn selectedTerminalCanClose(model: *const Model) bool {
    const terminal_ref = model.selectedTerminalRef() orelse return false;
    return support.providerKind(terminal_ref) == .local;
}

pub fn chromeRevealed(model: *const Model) bool {
    // `hide-chrome-when-single = false` means "I want my tab strip", full
    // stop — the at-rest hide is a default, not a law.
    if (!model.config.hide_chrome_when_single) return true;
    if (model.tab_count > 1) return true;
    if (model.selectedTerminalRef() == null) return true;
    for (model.tabs[0..model.tab_count], 0..) |_, index| {
        const current = model.treeConst(index) orelse continue;
        var refs: [layout.max_panes]TerminalRef = undefined;
        const count = current.terminals(&refs);
        for (refs[0..count]) |id| {
            if (terminalNeedsAttention(model, id)) return true;
        }
    }
    return false;
}

/// The scrollback-search band's height.
///
/// The band takes its room from the CONTENT rect rather than floating over
/// the grid. Painter, widget tree, and PTY sizing pump all derive from
/// `workspaceChrome`, so an overlay would leave the three disagreeing about
/// how tall the terminal is — which is the same class of bug that once left a
/// zone of painted text with no hit target behind it.
pub const search_bar_height: f32 = 34;

/// Whether the focused terminal has its search field open. Derived, with no
/// stored copy to drift: search state lives on the session, so a tab switch
/// changes this answer without anything having to remember to update it.
pub fn searchRevealed(model: *const Model) bool {
    const terminal_ref = model.selectedTerminalRef() orelse return false;
    const pane = model.provider.terminalConst(terminal_ref) orelse return false;
    return pane.session.search.open;
}

pub const WorkspaceChrome = struct {
    titlebar_height: f32,
    /// The band's own rect, so the header ground and its separator paint
    /// exactly where the strip is laid out. Zero-height when at rest.
    header: geometry.RectF,
    /// The scrollback-search band. Zero-height when no search is open.
    search: geometry.RectF,
    content: geometry.RectF,
};

/// The band's reveal is a STEP, deliberately, and it must stay one.
///
/// It reads as an abrupt layout flip and the SDK does have a layout-tween
/// primitive (`Runtime.startCanvasWidgetLayoutTween`, driven from
/// `UiApp.scheduleLayoutTweens`) that nothing here uses. Easing this extent
/// with it is still the wrong move, for two independent reasons:
///
///   1. The tween animates the WIDGET layout tree only. The painter
///      (`view.buildChrome`), the hit targets, and the PTY sizing pump all
///      derive their rects from THIS function instead — see `resolvePanes` —
///      so an eased widget tree over a stepped `content` would leave the
///      three disagreeing for the length of the animation. That is the exact
///      failure the comment on `resolvePanes` records, replayed once per tab
///      open and close.
///   2. Easing the extent HERE instead, so all three stay in lockstep, moves
///      `content.height` every frame. `view.onFrame` emits a `.viewport` the
///      moment the proposed row count changes, and that arm calls
///      `fx.ptyResize` — a SIGWINCH. `header_height` is 50pt over a ~17.5pt
///      cell, so a single reveal would cost three resizes per pane instead of
///      one: three full redraws of whatever TUI is running, per tab.
///
/// The band's CONTENTS may be animated freely — opacity, a slide inside the
/// band's own rect — because none of that moves `content`. Only the extent is
/// load-bearing, and only the extent is forbidden to move gradually.
pub fn workspaceChrome(model: *const Model, size: geometry.SizeF) WorkspaceChrome {
    const inset = windowPadding(model);
    const titlebar = @max(inset, model.chrome_top + 4);
    const revealed = chromeRevealed(model);
    const side_extent = if (revealed and model.tab_placement == .side) side_rail_width + side_rail_gap else 0;
    const top_extent = if (revealed and model.tab_placement == .top) header_height else 0;
    const search_extent = if (searchRevealed(model)) search_bar_height else 0;
    const body_width = @max(0, size.width - inset * 2 - side_extent);
    return .{
        .titlebar_height = titlebar,
        .header = geometry.RectF.init(
            inset,
            titlebar,
            @max(0, size.width - inset * 2),
            top_extent,
        ),
        .search = geometry.RectF.init(
            inset + side_extent,
            titlebar + top_extent,
            body_width,
            search_extent,
        ),
        .content = geometry.RectF.init(
            inset + side_extent,
            titlebar + top_extent + search_extent,
            body_width,
            @max(0, size.height - titlebar - top_extent - search_extent - inset),
        ),
    };
}

/// THE geometry derivation. The painter, the widget tree that carries the hit
/// targets, and the PTY sizing pump all call this — three independent
/// derivations is what left a 294pt zone of painted text with no hit target
/// behind it.
pub fn resolvePanes(model: *const Model, size: geometry.SizeF, out: []layout.Pane) usize {
    const current = model.selectedTreeConst() orelse return 0;
    return current.resolve(
        workspaceChrome(model, size).content,
        split_divider_width,
        split_pane_min_width,
        split_pane_min_height,
        out,
    );
}

/// The pane under a view point, or null over the band, a divider, or a
/// gutter. Same bounds and same clamps as `resolvePanes` by construction.
pub fn paneAtPoint(model: *const Model, size: geometry.SizeF, x: f32, y: f32) ?layout.Pane {
    const current = model.selectedTreeConst() orelse return null;
    return current.paneAt(
        workspaceChrome(model, size).content,
        split_divider_width,
        split_pane_min_width,
        split_pane_min_height,
        x,
        y,
    );
}

/// The resolved pane rects in LAYOUT order, zero-filled past the live count.
/// A convenience over `resolvePanes` for callers that only want geometry.
pub fn paneFrames(model: *const Model, size: geometry.SizeF) [layout.max_panes]geometry.RectF {
    var frames = [_]geometry.RectF{.{}} ** layout.max_panes;
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolvePanes(model, size, &panes);
    for (panes[0..count], 0..) |pane, index| frames[index] = pane.rect;
    return frames;
}

pub fn paneFrameFor(model: *const Model, size: geometry.SizeF, id: TerminalRef) ?geometry.RectF {
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolvePanes(model, size, &panes);
    for (panes[0..count]) |pane| {
        if (pane.terminal.eql(id)) return pane.rect;
    }
    return null;
}
