const std = @import("std");
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
const Workspace = model_module.Workspace;
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

/// Room at the LEADING edge of the titlebar band for the three traffic
/// lights, so a strip hosted there starts clear of them.
///
/// AppKit places them at 20, 40 and 60 points from the window's left edge at
/// the standard size; 78 clears the last one with a gutter. It is a platform
/// constant, not a taste one — a smaller value puts a tab under the close
/// button.
pub const titlebar_tab_leading_reserve: f32 = 78;

/// The shortest titlebar band that can host the tab strip.
pub const titlebar_tab_band_min: f32 = tab_height + 8;

/// Whether this window's titlebar band hosts the tab strip.
///
/// THE change that makes the band cheap. A `hidden_inset_tall` titlebar is
/// already ~66pt of window that holds three traffic lights and nothing else,
/// and its height does not depend on how many tabs exist — so a strip drawn
/// inside it costs no content height, in any state, ever. Revealing tabs stops
/// resizing the terminal not because the resize got cheaper but because there
/// is no longer a resize: `content.y` does not move.
///
/// The band can still be too short to host anything — a window in fullscreen
/// has no titlebar at all, and `chrome_top` goes to zero with it. That case
/// falls back to the old separate `header_height` band, which is the honest
/// answer: the room has to come from somewhere when the platform stops
/// providing it.
pub fn tabsRideTitlebarIn(model: *const Model, workspace: *const Workspace) bool {
    if (model.tab_placement != .top) return false;
    return titlebarBandHeight(model, workspace) >= titlebar_tab_band_min;
}

/// The titlebar band's own height, inside the window's padding.
fn titlebarBandHeight(model: *const Model, workspace: *const Workspace) f32 {
    const inset = windowPadding(model);
    return @max(0, @max(inset, workspace.chrome_top + 4) - inset);
}

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
    return visibleTabWindowIn(model.wsConst(), band_width);
}

pub fn visibleTabWindowIn(workspace: *const Workspace, band_width: f32) TabWindow {
    if (workspace.tab_count == 0) return .{};
    const usable = @max(tab_min_extent, band_width - tab_strip_trailing_reserve);
    // Shrink first, window second. A strip that windowed at full tab width
    // would hide tab 4 in a 900pt window while leaving 200pt of gutter.
    const capacity: usize = @max(1, @as(usize, @intFromFloat(@floor(usable / tab_min_extent))));
    const shown = @min(capacity, workspace.tab_count);
    const extent = @min(tab_extent, usable / @as(f32, @floatFromInt(shown)));
    if (shown == workspace.tab_count) return .{ .first = 0, .count = shown, .extent = extent };
    const selected = @min(workspace.selected_tab, workspace.tab_count - 1);
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

/// A pane that never got a process, and so has nothing to close TO.
///
/// This is deliberately NOT "the shell exited badly". A shell that ran and
/// then ended — cleanly, with a non-zero status, or on a signal — is DONE, and
/// its pane closes like any other (see the `.exit` arm in `update`). Keeping a
/// dead grid alive behind an `EXIT 1` badge was the single worst thing this app
/// did: `exit` in a shell inherits the last command's status, so an ordinary
/// session ended by an ordinary failed command left a husk holding a full pane
/// rect forever, and the sibling never reclaimed the space.
///
/// A SPAWN failure is the one case that still earns a tombstone. There is no
/// process to have exited and no output to have seen; a pane that vanished
/// instead would make `cmd+D` look like it did nothing at all, which is a
/// worse answer than a Restart affordance.
pub fn paneLifecycleFailed(pane: *const Pane) bool {
    return pane.phase == .failed;
}

/// Whether this pane has EVER lost bytes. The diagnostic answer, for the
/// accessibility label — cumulative on purpose, and never the basis for
/// chrome.
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
    // Deliberately the UNACKNOWLEDGED loss, not the cumulative count. Reading
    // `paneHasConfirmedLoss` here made attention a one-way latch: the counters
    // never come back down inside a session, so a single dropped byte pinned
    // the tab band open forever — and every reveal and retraction of that band
    // resizes a live PTY.
    return pane.bellRung() or
        pane.phase == .ended or pane.phase == .failed or
        pane.hasUnacknowledgedLoss() or pane.copy_failed or paste_failed;
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
    return chromeRevealedIn(model, model.wsConst());
}

pub fn chromeRevealedIn(model: *const Model, workspace: *const Workspace) bool {
    // `hide-chrome-when-single = false` means "I want my tab strip", full
    // stop — the at-rest hide is a default, not a law.
    if (!model.config.hide_chrome_when_single) return true;
    if (workspace.tab_count > 1) return true;
    // A refusal has to be visible somewhere, and the band is the only chrome
    // this app has: a cmd+N at the window ceiling reveals it rather than
    // doing nothing at all.
    if (model.window_limit_refused) return true;
    if (workspaceTerminalRef(model, workspace) == null) return true;
    for (0..workspace.tab_count) |index| {
        const current = workspace.treeConst(index) orelse continue;
        var refs: [layout.max_panes]TerminalRef = undefined;
        const count = current.terminals(&refs);
        for (refs[0..count]) |id| {
            if (terminalNeedsAttention(model, id)) return true;
        }
    }
    return false;
}

/// The focused terminal of ONE workspace, filtered to a ref a provider still
/// vouches for. `Model.selectedTerminalRef` is this over the ACTIVE window;
/// the per-window painter and view need it over the window they are drawing.
pub fn workspaceTerminalRef(model: *const Model, workspace: *const Workspace) ?TerminalRef {
    const id = workspace.focusedTerminalRef() orelse return null;
    return if (model.containsTerminal(id)) id else null;
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
    return searchRevealedIn(model, model.wsConst());
}

pub fn searchRevealedIn(model: *const Model, workspace: *const Workspace) bool {
    const terminal_ref = workspaceTerminalRef(model, workspace) orelse return false;
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

/// The tab indices the summoned switcher is showing, in tab order.
///
/// THE derivation, called by both the view that draws the rows and the commit
/// that acts on the highlighted one. Two derivations would mean Enter could
/// select a different tab from the one under the highlight — the same class of
/// bug `resolvePanes` exists to prevent for pane rects.
///
/// Matching is case-insensitive substring against what the tab actually
/// shows — the shell's own title (OSC 0/2), then its working directory — plus
/// the tab's 1-based POSITION as digits, because that is the handle the user
/// already has from `cmd+1`..`cmd+5` and it is the only thing a shell without
/// title integration offers. A tab whose shell reports neither title nor
/// directory is therefore findable by its number and by nothing else, which is
/// the honest answer rather than a fabricated one.
pub fn paletteRowsIn(model: *const Model, workspace: *const Workspace, out: []usize) usize {
    const needle = workspace.palette.needle();
    var written: usize = 0;
    for (0..workspace.tab_count) |index| {
        if (written >= out.len) break;
        if (needle.len == 0 or paletteTabMatches(model, workspace, index, needle)) {
            out[written] = index;
            written += 1;
        }
    }
    return written;
}

fn paletteTabMatches(model: *const Model, workspace: *const Workspace, index: usize, needle: []const u8) bool {
    // The position, as the user reads it off the strip and the cmd+N chords.
    var digits: [4]u8 = undefined;
    const position = std.fmt.bufPrint(&digits, "{d}", .{index + 1}) catch "";
    if (containsIgnoreCase(position, needle)) return true;

    const id = workspace.tabTerminal(index) orelse return false;
    if (model.provider.terminalConst(id)) |pane| {
        if (containsIgnoreCase(pane.title(), needle)) return true;
        const cwd = pane.pwd();
        if (cwd.len > 0 and containsIgnoreCase(std.fs.path.basename(cwd), needle)) return true;
        return false;
    }
    const presentation = model.remotePresentation(id) orelse return false;
    return containsIgnoreCase(presentation.title, needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |want, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(want)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

/// The tab the switcher's highlight is on, or null when nothing matches.
pub fn paletteSelectedTabIn(model: *const Model, workspace: *const Workspace) ?usize {
    var rows: [model_module.max_tabs]usize = undefined;
    const count = paletteRowsIn(model, workspace, &rows);
    if (count == 0) return null;
    return rows[@min(workspace.palette.cursor, count - 1)];
}

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
    return workspaceChromeIn(model, model.wsConst(), size);
}

pub fn workspaceChromeIn(model: *const Model, workspace: *const Workspace, size: geometry.SizeF) WorkspaceChrome {
    const inset = windowPadding(model);
    const titlebar = @max(inset, workspace.chrome_top + 4);
    const revealed = chromeRevealedIn(model, workspace);
    const side_extent = if (revealed and model.tab_placement == .side) side_rail_width + side_rail_gap else 0;
    // Zero whenever the titlebar band can host the strip, which is every
    // ordinary window. The separate band survives only for the case the
    // platform stops providing one — see `tabsRideTitlebarIn`.
    const top_extent = if (revealed and model.tab_placement == .top and !tabsRideTitlebarIn(model, workspace))
        header_height
    else
        0;
    const search_extent = if (searchRevealedIn(model, workspace)) search_bar_height else 0;
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
    return resolvePanesIn(model, model.wsConst(), size, out);
}

pub fn resolvePanesIn(model: *const Model, workspace: *const Workspace, size: geometry.SizeF, out: []layout.Pane) usize {
    const current = workspace.selectedTreeConst() orelse return 0;
    return current.resolve(
        workspaceChromeIn(model, workspace, size).content,
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
