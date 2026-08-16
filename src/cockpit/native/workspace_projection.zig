const std = @import("std");
const native_sdk = @import("native_sdk");
const provider_contract = @import("provider_contract");
const grid = @import("../../terminal/grid.zig");
const support = @import("../phux_support.zig");
const local = @import("../../providers/local/provider.zig");
const model_module = @import("../model.zig");
const topology = @import("../topology.zig");
const layout = @import("../layout.zig");
const scene = @import("scene.zig");
const config_module = @import("../../config/config.zig");
const theme_module = @import("../../config/theme.zig");

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

/// THE CHROME REGISTER: five numbers, and every band in the app is built out
/// of them.
///
/// The toolkit is explicit that a row reads as ONE height exactly when every
/// control in it carries the same size rung, and that a hand-sized pressable
/// panel never lands on the scale at all. This app had four bands at four
/// different paddings hosting controls at four different extents, which is the
/// long way of saying nobody could tell you what a band was.
///
/// A band is one DEFAULT-register control tall and hosts SMALL-register
/// controls with `spacing.xs` shoulders: 40 = 32 + 4 + 4. That is the whole
/// system, and it is the Geist pack's own ladder rather than a scale invented
/// here — `metrics.control_height` is 40, `control_height_sm` is 32, and
/// `spacing.xs` is 4. See docs/DESIGN_SYSTEM.md for the derivations and the
/// sources.
pub const chrome_band_height: f32 = 40;
pub const chrome_band_inset: f32 = 4;
pub const chrome_control_extent: f32 = 32;
/// Every inline icon in the chrome, from three derivations that agree: the
/// SDK's own `label_size + icon_text_step` (13 + 2 = 15), the cap-height recipe
/// (1.65 x cap = 1.163 x size = 15.1), and Carbon's shipped 16px-against-14px
/// pairing. 15.1 rounds to the artboard every icon system ships, and 16 centres
/// on whole device pixels at 1x and 2x where 15 does not.
pub const chrome_icon_extent: f32 = 16;
pub const chrome_gap: f32 = 8;

/// The floor for anything the pointer has to hit. WCAG 2.2 SC 2.5.8 asks 24x24
/// for AA; Apple's macOS guidance is a 28pt default over a 20pt minimum, which
/// is the POINTER figure — the 44pt number on Apple's Buttons page is written
/// for fingertips and chasing it would cost this app the density that makes a
/// terminal a terminal. 24 clears the AA floor exactly, sits between Apple's
/// two numbers, and leaves the toolkit's own 18pt audit floor a real margin
/// instead of passing it by zero, which is what an 18pt control did.
pub const chrome_hit_target: f32 = 24;

/// The tab band's fallback height. It must be at least the register's own trigger
/// height, or the strip overflows the band and paints its hairline and
/// underline indicator down into the terminal's first row. The Geist pack
/// computes 50 at the default control size (`metrics.tabs_trigger_height`),
/// and `headerHeightCoversTriggers` pins the two together.
pub const header_height: f32 = 50;
/// Tab geometry. Lives here rather than in the view because the visible-window
/// derivation below is the thing tests pin, and it needs the same numbers the
/// strip lays out with.
pub const tab_extent: f32 = 168;
/// Tabs SHRINK before the strip windows, the way every real tab bar does, and
/// this is where they stop.
///
/// DERIVED, not chosen. A tab's furniture is fixed whatever its width — two
/// `chrome_gap` shoulders (16), the attention slot (16), two gaps between the
/// three children (16), and the close affordance (24) — which is 72pt before a
/// single glyph of title. 120 leaves 48pt of label: six to seven characters of
/// the pack's 13pt sans, and more room than any other single thing in the tab.
///
/// It was 92, against furniture that was then 54, so the old floor left 38pt —
/// five characters — while its comment claimed ten. Raising the close
/// affordance to a real pointer target had to move this with it or the strip
/// would have windowed down to tabs that were all furniture. The cost is
/// visible tab count at a given width, and it is the right trade: the switcher
/// (cmd+shift+P) reaches every tab in constant time, so the strip's job is to
/// be READABLE, not to be complete.
pub const tab_min_extent: f32 = 120;
/// One default-register control (`metrics.control_height`). It rides a titlebar
/// band measured at 62pt on this machine, so `titlebar_tab_band_min` clears it
/// with 14pt to spare.
pub const tab_height: f32 = chrome_band_height;
pub const tab_control_extent: f32 = chrome_hit_target;
pub const tab_marker_extent: f32 = chrome_icon_extent;
/// The selected tab's accent bar — the Geist pack's own
/// `metrics.tabs_indicator_thickness`, which is the vocabulary its underline
/// tab register already speaks.
pub const tab_indicator_thickness: f32 = 2;
/// Room held back at the right of the band for the `+` button and the focused
/// pane's status, so a full strip never pushes either off the edge.
pub const tab_strip_trailing_reserve: f32 = 220;

/// One EDGE CUE: the chevron the strip shows at whichever end it is hiding
/// tabs behind.
///
/// `chrome_hit_target`, the same 24 the tab's own close `x` uses, because it is
/// the same kind of thing — a small ghost icon control riding inside a tab-band
/// row — and because the cue has to be pressable: it opens the switcher, which
/// is the only way an AX user who just learned tabs are hidden can reach them.
///
/// It is deliberately NOT `chrome_control_extent` (32, the `+`'s rung). The
/// reserve below is paid twice out of the room the tabs lay out in, and the
/// difference is a whole tab: at the 660pt window this bug was measured in,
/// `floor((644 - 220 - 2*(24 + 4)) / 120)` is 3 and the same expression with 32
/// is 2. A cue that costs a tab to announce a tab is not a trade worth making.
pub const tab_overflow_cue_extent: f32 = chrome_hit_target;

/// What one cue costs the strip: itself plus the row's own gap before it.
const tab_overflow_cue_reserve: f32 = tab_overflow_cue_extent + chrome_band_inset;

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
    /// How many tabs the workspace actually has. Carried rather than left to
    /// the caller to re-read, because it is what turns this struct from "here
    /// is a run of tabs" into "here is a run of tabs AND how much of the list
    /// it is not". The strip cannot draw an honest edge cue without it, and
    /// every caller that asked the workspace separately was one refactor away
    /// from asking a different workspace.
    total: usize = 0,
    /// The width each visible tab lays out at, between `tab_min_extent` and
    /// `tab_extent`.
    extent: f32 = tab_extent,

    pub fn contains(window: TabWindow, index: usize) bool {
        return index >= window.first and index < window.first + window.count;
    }

    /// Whether this run is a WINDOW onto a longer list rather than the list.
    pub fn windowed(window: TabWindow) bool {
        return window.count < window.total;
    }

    pub fn hiddenBefore(window: TabWindow) usize {
        return window.first;
    }

    pub fn hiddenAfter(window: TabWindow) usize {
        return window.total - window.first - window.count;
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
    if (capacity >= workspace.tab_count) {
        // Every tab fits. No cue is drawn and none is paid for, which is why
        // this case has to be decided BEFORE the reserve below: charging a
        // strip that shows the whole list for an edge cue it will never draw
        // would shrink tabs for nothing.
        const extent = @min(tab_extent, usable / @as(f32, @floatFromInt(workspace.tab_count)));
        return .{ .first = 0, .count = workspace.tab_count, .total = workspace.tab_count, .extent = extent };
    }

    // From here the strip IS a window onto a longer list, and it says so at
    // both ends. Room is held for BOTH cues even when only one of them is
    // drawn — the leading one is absent exactly while `first` is 0 — because
    // the alternative is that every tab in the strip changes width the moment
    // the selection walks past the right edge, which is the same "tabs jump
    // under the pointer" the anchoring rule below exists to avoid. A fixed
    // reserve also keeps this derivation non-circular: the cue count depends
    // on `first`, `first` depends on how many tabs fit, and how many fit would
    // otherwise depend on the cue count.
    const cued = @max(tab_min_extent, usable - 2 * tab_overflow_cue_reserve);
    const shown: usize = @max(1, @as(usize, @intFromFloat(@floor(cued / tab_min_extent))));
    const extent = @min(tab_extent, cued / @as(f32, @floatFromInt(shown)));
    const selected = @min(workspace.selected_tab, workspace.tab_count - 1);
    // Anchor at the left until the selection walks past the right edge, then
    // keep the selection as the LAST visible tab. Recentering on every step
    // would make neighbouring tabs jump under the pointer.
    const first = if (selected < shown) 0 else selected - shown + 1;
    return .{ .first = first, .count = shown, .total = workspace.tab_count, .extent = extent };
}

pub const side_rail_width: f32 = 184;
pub const side_rail_gap: f32 = chrome_gap;
/// The rail's rows are the same control as the strip's tabs, at the same
/// height, because they ARE the same control — a rail that sized its rows
/// differently would make toggling placement look like a different app.
pub const side_tab_height: f32 = tab_height;
/// The grab band between two panes. 8, not 9: an odd extent cannot centre on a
/// whole point between two halves, so the divider's own hairline landed on a
/// half-pixel column at 1x and the two panes were never symmetric about it.
/// 8 is `spacing.sm`, and it is still a wide enough band to grab.
pub const split_divider_width: f32 = chrome_gap;
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
/// painter would silently drop it and fall back to the estimator — a cell
/// width nothing else in the app agrees with, which is exactly how a
/// default-config launch would start reporting mouse positions against a grid
/// it is not painting.
///
/// That fallback is NOT `label_size * 0.6`, which this comment claimed until
/// 2026-08-12 and which made the hazard sound survivable. `0.6` is what the
/// estimator returns for `canvas.default_mono_font_id`; cockpit's face is
/// registered at 64, so the estimator uses its proportional SANS table
/// instead and comes out 46 percent wide. See `terminalCellMetricsFor`.
pub fn terminalTokensFrom(base: canvas.DesignTokens, model: *const Model) canvas.DesignTokens {
    var tokens = base;
    const cfg = &model.config;
    tokens.typography.label_size = model.fontSize();
    // Background/foreground land in the emulator's own DEFAULTS through
    // `Session.snapshot`, so an application's OSC 10/11 still wins over them.
    //
    // RESOLVED, not raw: `theme = <name>` fills these in and an explicit
    // `background`/`foreground` key outranks it. The precedence lives in
    // `Config.resolvedBackground` and friends so this site cannot hold a
    // second, differing copy of the rule. Because this whole function runs
    // again on every frame, changing either the theme or a colour repaints
    // LIVE — there is no cached token set to invalidate.
    if (cfg.resolvedBackground()) |color| tokens.colors.background = canvas.Color.rgb8(color.r, color.g, color.b);
    if (cfg.resolvedForeground()) |color| tokens.colors.text = canvas.Color.rgb8(color.r, color.g, color.b);
    // The selection wash reads `colors.accent` (see `palette.Palette.init`).
    // The cursor does NOT come through here — `applySessionConfig` gives it
    // the emulator's override channel so the two knobs stay independent.
    if (cfg.resolvedSelectionBackground()) |color| tokens.colors.accent = canvas.Color.rgb8(color.r, color.g, color.b);
    return tokens;
}

/// What the terminal's text and ground ACTUALLY are, and how far apart they
/// are, right now.
///
/// THE INSTRUMENT. `phux-cockpit-aht` cost four rounds of "the text is
/// see-through or black or something" precisely because nothing in the app
/// could answer "how legible is this" without an agent measuring pixels. This
/// reads the same `DesignTokens` the painter is about to paint with — not the
/// config, not the theme table — so it cannot report a colour the screen is
/// not showing. A colour that reaches the tokens reaches this, and a colour
/// that does not reach the tokens is exactly the bug worth seeing.
pub const Legibility = struct {
    foreground: canvas.Color,
    background: canvas.Color,
    /// WCAG 2.x contrast ratio, 1.0 (identical) through 21.0 (black on white).
    ratio: f32,
    grade: theme_module.Legibility,

    pub fn readable(self: Legibility) bool {
        return self.grade.readable();
    }
};

pub fn legibility(model: *const Model) Legibility {
    return legibilityOf(terminalTokens(model));
}

/// The same derivation over an already-resolved token set, so the painter and
/// a test can both ask about the exact tokens in hand.
pub fn legibilityOf(tokens: canvas.DesignTokens) Legibility {
    const fg = tokens.colors.text;
    const bg = tokens.colors.background;
    const ratio = theme_module.contrastRatioLuminance(
        theme_module.relativeLuminance(fg.r, fg.g, fg.b),
        theme_module.relativeLuminance(bg.r, bg.g, bg.b),
    );
    return .{
        .foreground = fg,
        .background = bg,
        .ratio = ratio,
        .grade = theme_module.Legibility.of(ratio),
    };
}

/// `canvas.terminalCellMetrics`, corrected for the case the comment above
/// describes: tokens that carry NO text-measure provider.
///
/// Use this everywhere outside the painter. The painter has the runtime's
/// provider and should keep calling `canvas.terminalCellMetrics` directly.
///
/// WHY THIS EXISTS. Without a provider the SDK estimates, and its estimator
/// is keyed by FONT ID: `estimateTextAdvanceForBytes` returns the 0.6 em mono
/// pitch only for `canvas.default_mono_font_id` (2) and otherwise walks a
/// per-character SANS advance table. Cockpit's terminal face is registered at
/// `canvas.min_registered_font_id` (64), so the estimator has no way to know
/// it is looking at a monospace face and prices it as proportional text. The
/// probe the SDK measures with is "MMMM..." — the widest capital — so the
/// error is not small:
///
///   font-size 26, tokens with no provider, mono_font_id = 64
///     estimated cell width  22.802 pt   (26 * 0.877 em, Geist sans 'M')
///     true mono cell width  15.600 pt   (26 * 0.6 em)
///     ratio                 1.4617      -> 46.2 percent too wide
///
/// Measured on 2026-08-12 by printing both from `terminalTokens(&model)` with
/// `font-size = 26`; the bead's estimate of "roughly 35 percent" was low.
/// Remote (phux) panes sized through that number, so every one of them was
/// told it had about a third fewer columns than it had room for.
///
/// The correction is to ask the estimator about the id whose metrics class it
/// actually knows. That is sound rather than a fudge because cockpit's
/// terminal face IS a 0.6 em monospace: with a real provider stamped,
/// measuring font 64 at size 13 returns 7.800001, and 13 * 0.6 = 7.8. The
/// test "the registered terminal face is a 0.6 em monospace" pins that, so a
/// font swap to a different pitch fails there instead of quietly re-opening
/// this bug.
pub fn terminalCellMetricsFor(tokens: canvas.DesignTokens) canvas.TerminalCellMetrics {
    if (tokens.text_measure != null) return canvas.terminalCellMetrics(tokens);
    var estimating = tokens;
    estimating.typography.mono_font_id = canvas.default_mono_font_id;
    return canvas.terminalCellMetrics(estimating);
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

/// The most a terminal's name can take. Long enough for a shell title anybody
/// writes on purpose, short enough that a runaway OSC 0 cannot push a menu row
/// off a screen.
pub const max_terminal_title_bytes: usize = 96;

/// Where a terminal LIVES, in the only coordinates anyone can act on: which
/// tab holds it, and which pane inside that tab. Both 1-based, because both
/// are read aloud and written on screen rather than used to index anything.
///
/// `tab` is exactly the digit `cmd+N` carries.
pub const TerminalAddress = struct {
    tab: usize,
    pane: usize,
    /// How many panes the tab holds. One means `pane` says nothing `tab` has
    /// not already said, and the name drops it.
    pane_count: usize,
};

/// The address a terminal answers to, or null when it sits in no tab at all.
///
/// This is deliberately NOT the registry slot, which is what the `Terminal N`
/// fallback used to number by. The slot is MINT ORDER and only ever moves
/// forward — `LocalProvider.next_terminal_raw` is incremented on every create
/// and never rewound, because an identity that repeated would let a late event
/// for a retired terminal resolve to a live one. That is right for identity
/// and wrong for a name: one cmd+W followed by one cmd+T left the fourth tab
/// holding slot 5 while cmd+4 went on selecting it, and the tab announced BOTH
/// numbers in a single sentence —
///
///   "Terminal 5, native terminal, 1 pane(s); …; shortcut CMD+4"
///
/// Two integers in the same row, in the same font, one of them wrong; every
/// further close/open widened the gap. Position cannot drift from the chord
/// because it IS the chord.
///
/// The pane half is what keeps position from LOSING something the slot had.
/// Two panes split inside one tab share a tab digit, so numbering by tab alone
/// would name both of them "Terminal 3" and offer two identical "Restart
/// Terminal 3" buttons — trading a wrong number for an ambiguous one. The pane
/// digit is the tab's own leaf order (`Tree.terminals`), which is the order the
/// splits laid them out in and the order `cycle_pane` walks.
pub fn terminalAddress(model: *const Model, id: TerminalRef) ?TerminalAddress {
    const where = model.locateTerminal(id) orelse return null;
    const workspace = model.wsAtConst(where.window) orelse return null;
    const tree = workspace.treeConst(where.tab) orelse return null;
    var refs: [layout.max_panes]TerminalRef = undefined;
    const count = tree.terminals(&refs);
    for (refs[0..count], 0..) |ref, index| {
        if (!ref.eql(id)) continue;
        return .{ .tab = where.tab + 1, .pane = index + 1, .pane_count = count };
    }
    // `locateTerminal` found this terminal by walking the same trees, so
    // failing to find it here means the two walks disagree. Null rather than a
    // tab-only address: a plausible answer assembled from half a lookup is how
    // the contradiction above stayed invisible for as long as it did.
    return null;
}

/// The name for a terminal, in the order a terminal user reads it:
///
///   1. the SHELL's own title (OSC 0/2). A prompt with title integration is
///      already saying what this is — "vim src/main.zig", "npm run dev" — and
///      nothing this app invents beats that.
///   2. the last component of the working directory (OSC 7), which is what
///      Ghostty and Terminal.app fall back to and what most shells report even
///      without title integration.
///   3. `Terminal N`, or `Terminal N.M` for one pane of a split — the terminal's
///      ADDRESS. See `terminalAddress` for why this is not the registry slot.
///
/// A Phux terminal borrows the title its coordinator published; the local
/// chain does not apply because there is no local session to ask.
///
/// The caller's buffer is only ever used for case 3, so the common answers are
/// borrowed from the pane and cost nothing. It lives HERE rather than in the
/// view because the view is no longer the only caller: a menu-bar row and a
/// notification banner are the same name, and a second implementation of this
/// chain is a second set of titles to keep in agreement.
pub fn terminalTitleInto(model: *const Model, id: TerminalRef, out: []u8) []const u8 {
    if (provider_contract.isLocal(id)) {
        if (model.provider.terminalConst(id)) |pane| {
            const shell_title = pane.title();
            if (shell_title.len > 0) return clampTitle(shell_title);
            const cwd = pane.pwd();
            if (cwd.len > 0) {
                // `basename("/")` is empty and `basename("")` is empty; both
                // fall through to the number rather than painting a blank tab.
                const leaf = std.fs.path.basename(cwd);
                if (leaf.len > 0) return clampTitle(leaf);
            }
        }
        // The tree walk this costs runs only on THIS branch — a terminal with
        // a shell title or a pwd, which is nearly every terminal a second
        // after it starts, has already returned — so the strip pays it for
        // unnamed panes and nothing else.
        const at = terminalAddress(model, id) orelse return "Terminal";
        if (at.pane_count <= 1) return std.fmt.bufPrint(out, "Terminal {d}", .{at.tab}) catch "Terminal";
        return std.fmt.bufPrint(out, "Terminal {d}.{d}", .{ at.tab, at.pane }) catch "Terminal";
    }
    const presentation = model.remotePresentation(id) orelse return "Phux";
    return if (presentation.title.len == 0) "Phux" else clampTitle(presentation.title);
}

/// Cut an over-long title at a UTF-8 boundary rather than mid-codepoint: a
/// half-written codepoint is a tofu box on every surface that draws it.
fn clampTitle(title: []const u8) []const u8 {
    if (title.len <= max_terminal_title_bytes) return title;
    var end = max_terminal_title_bytes;
    while (end > 0 and title[end] & 0xc0 == 0x80) end -= 1;
    return title[0..end];
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
    // Same rule for the shell ceiling, and it matters more at ONE tab: that is
    // exactly the state a refused cmd+D leaves behind, and with the band
    // hidden the chord would look unbound rather than refused.
    if (model.terminal_limit_refused) return true;
    // And for a save the config file refused. At one tab with the chrome
    // hidden there is nowhere else for it to appear, and the whole defect this
    // latch exists for is a theme change that reported nothing at all.
    if (model.config_write_refused) return true;
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

/// The scrollback-search band's height: one band (`chrome_band_height`), like
/// every other band in the app.
///
/// It was 34, which held a 22pt control that was on no register at all. 40 is
/// the register, and the 6pt it costs the terminal is a third of one row at the
/// default cell.
///
/// The band takes its room from the CONTENT rect rather than floating over
/// the grid. Painter, widget tree, and PTY sizing pump all derive from
/// `workspaceChrome`, so an overlay would leave the three disagreeing about
/// how tall the terminal is — which is the same class of bug that once left a
/// zone of painted text with no hit target behind it.
pub const search_bar_height: f32 = chrome_band_height;

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

/// The config band's height. The SEARCH band's height, deliberately: two bands
/// that can be on screen at once, stacked over one grid, at two different
/// heights read as a layout accident, and this metric is already proven to hold
/// a line of chrome text plus its controls.
pub const config_notice_height: f32 = search_bar_height;

/// Whether the config band is up.
///
/// It takes no workspace, unlike every other reveal here, and that IS the
/// design: a config file belongs to the app, so the band is drawn in every open
/// window and dismissed in all of them at once. A per-window answer would mean
/// four dismissals for one typo, and a notice you can miss by looking at the
/// other window.
pub fn configNoticeRevealed(model: *const Model) bool {
    return model.configNoticeVisible();
}

/// The longest line `configNoticeLine` can produce, DERIVED rather than picked:
/// whichever of the two forms is longer, at their worst inputs.
pub const config_notice_bytes: usize = @max(
    // "Config line 4294967295: understood, but does nothing in this build 'x…'"
    "Config line 4294967295: ".len + longest_summary + " ''".len + config_module.max_diagnostic_text_bytes,
    // "Config: 16 lines were not applied (lines 4294967295, …)"
    "Config: 16 lines were not applied (lines )".len +
        config_module.max_diagnostics * "4294967295, ".len,
);

const longest_summary = blk: {
    var longest: usize = 0;
    for (std.enums.values(config_module.Diagnostic.Kind)) |kind| {
        longest = @max(longest, kind.summary().len);
    }
    break :blk longest;
};

/// What the config band says, in one line.
///
/// ONE derivation, called by the band that draws it and by the tests that pin
/// it. The line NAMES LINE NUMBERS, because that is the only thing that turns
/// "something in your config did not apply" into an edit someone can make — and
/// for a single problem it names the problem too, since there is room.
///
/// Returns a slice of `out`; `out` must be `config_notice_bytes` long. An empty
/// answer means there is nothing to say.
pub fn configNoticeLine(model: *const Model, out: []u8) []const u8 {
    const notes = model.config.diagnosticSlice();
    if (notes.len == 0) return "";
    var writer = std.Io.Writer.fixed(out);
    if (notes.len == 1) {
        const only = notes[0];
        // A `missing_separator` carries the WHOLE line as its text, and the
        // line number has already located that for the user — quoting it back
        // spends the band's one line on something they can see in their editor.
        // Every other kind carries a key or a value, which is the part that is
        // not obvious from the line number alone.
        const detail = if (only.kind == .missing_separator) "" else only.text();
        if (detail.len == 0) {
            writer.print("Config line {d}: {s}", .{ only.line, only.kind.summary() }) catch {};
        } else {
            writer.print("Config line {d}: {s} '{s}'", .{ only.line, only.kind.summary(), detail }) catch {};
        }
        return writer.buffered();
    }
    writer.print("Config: {d} lines were not applied (lines ", .{notes.len}) catch {};
    for (notes, 0..) |diagnostic, index| {
        writer.print("{s}{d}", .{ if (index == 0) "" else ", ", diagnostic.line }) catch {};
    }
    writer.print(")", .{}) catch {};
    return writer.buffered();
}

pub const WorkspaceChrome = struct {
    titlebar_height: f32,
    /// The band's own rect, so the header ground and its separator paint
    /// exactly where the strip is laid out. Zero-height when at rest.
    header: geometry.RectF,
    /// The config-diagnostic band. Zero-height once dismissed, and when the
    /// config had nothing to complain about — which is almost every launch.
    notice: geometry.RectF,
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

/// The most rows the switcher DRAWS at once.
///
/// A cap is not a limit on what the switcher can REACH — `paletteRowsIn` above
/// is still the whole match set, and the cursor still walks all of it — it is a
/// limit on what the panel is tall enough to be. Without one the panel grew a
/// row per match and at the tab ceiling stood 624pt tall inside a window whose
/// declared minimum height is 420, so the bottom of the list was simply painted
/// off the window.
///
/// EIGHT, and Hick's law is not the reason. That law's own statement of scope
/// excludes a filtered list: scanning an unordered list is linear, and a
/// palette you type into is a recall task whose cost is roughly constant in the
/// match count — which is the argument FOR a switcher, not for a short one.
/// What bounds it is the fixation: eight rows is inside Miller's 7±2 and it is
/// what fits above the minimum window with the panel's own inset.
pub const palette_max_visible_rows: usize = 8;

/// The contiguous run of MATCHES the switcher draws, always containing the
/// cursor. Deliberately the same shape and the same anchoring rule as
/// `visibleTabWindow`: anchor at the top until the cursor walks past the last
/// drawn row, then keep the cursor as the last one, because recentring on every
/// step makes the rows under the pointer jump.
pub const PaletteWindow = struct {
    first: usize = 0,
    count: usize = 0,

    pub fn contains(window: PaletteWindow, offset: usize) bool {
        return offset >= window.first and offset < window.first + window.count;
    }
};

pub fn paletteWindowFor(match_count: usize, cursor: usize) PaletteWindow {
    if (match_count == 0) return .{};
    const shown = @min(palette_max_visible_rows, match_count);
    if (shown == match_count) return .{ .first = 0, .count = shown };
    const clamped = @min(cursor, match_count - 1);
    const first = if (clamped < shown) 0 else clamped - shown + 1;
    return .{ .first = first, .count = shown };
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
    // The config band takes its room out of the content rect exactly as the
    // search band does, and for the same reason: the painter, the hit-test
    // tree, and the PTY sizing pump all derive from here, so a band that
    // floated over the grid would leave the three disagreeing about how tall
    // the terminal is. It sits ABOVE the search band because it is about the
    // whole app rather than about the focused pane, and because the search
    // band has to stay adjacent to the grid it is searching.
    const notice_extent = if (configNoticeRevealed(model)) config_notice_height else 0;
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
        .notice = geometry.RectF.init(
            inset + side_extent,
            titlebar + top_extent,
            body_width,
            notice_extent,
        ),
        .search = geometry.RectF.init(
            inset + side_extent,
            titlebar + top_extent + notice_extent,
            body_width,
            search_extent,
        ),
        .content = geometry.RectF.init(
            inset + side_extent,
            titlebar + top_extent + notice_extent + search_extent,
            body_width,
            @max(0, size.height - titlebar - top_extent - notice_extent - search_extent - inset),
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

pub const PaneViewport = struct {
    terminal: support.TerminalRef,
    cols: u16,
    rows: u16,
};

/// Every pane's proposed grid for a surface of `size`, in resolve order.
///
/// ONE derivation, shared by the two sides that used to disagree about scope:
/// the frame pump reports the FIRST pane whose grid is wrong, and the commit
/// path converges ALL of them in that same dispatch. Deriving the proposal
/// twice — once to report, once to commit — is exactly the kind of split that
/// `resolvePanes` exists to prevent.
pub const ProposedViewports = struct {
    items: [layout.max_panes]PaneViewport = undefined,
    count: usize = 0,
    /// A local pane whose painter has not yet written cell metrics, so nothing
    /// after it in resolve order was measured either. The frame pump treats
    /// this as "not ready" and proposes nothing rather than sizing a pane
    /// against metrics that do not exist yet.
    incomplete: bool = false,

    pub fn slice(self: *const ProposedViewports) []const PaneViewport {
        return self.items[0..self.count];
    }
};

pub fn proposedViewportsIn(
    model: *const Model,
    workspace: *const Workspace,
    size: geometry.SizeF,
) ProposedViewports {
    var result: ProposedViewports = .{};
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolvePanesIn(model, workspace, size, &panes);
    // Cell metrics for a LOCAL pane come from the session's MEASURED box,
    // which the painter wrote from the live terminal tokens. Deriving them
    // here instead would be wrong, not merely redundant: only the painter's
    // tokens carry the runtime's text-measure provider, so a token derivation
    // here estimates and proposes a different column count than the one being
    // painted.
    //
    // `metrics` below is that estimate, and it is used ONLY for REMOTE panes,
    // which have no local session to have measured. It goes through
    // `terminalCellMetricsFor` rather than `canvas.terminalCellMetrics` so the
    // estimate is at least the right metrics CLASS — this line used to hand
    // remote panes a proportional cell 46 percent too wide.
    const metrics = terminalCellMetricsFor(terminalTokens(model));
    for (panes[0..count]) |pane| {
        const inner = pane.rect;
        if (inner.width <= 0 or inner.height <= 0) continue;
        if (model.provider.terminalConst(pane.terminal)) |terminal| {
            const session = terminal.session;
            // Nothing has painted this pane yet, so its cell box has never
            // been measured. Propose NOTHING rather than a column count
            // derived from a guess: the proposal is committed straight to the
            // pty as a SIGWINCH, and a wrong first one makes the shell redraw
            // its prompt at a width it is about to be told to abandon.
            //
            // This is the guard that used to read `cell_width <= 0` and could
            // never fire, because the fields defaulted to 8 and 18. It fires
            // now — see `grid.CellBox`.
            const cell = session.measuredCell() orelse {
                result.incomplete = true;
                return result;
            };
            const proposed = grid.Session.clampGrid(
                @intFromFloat(@max(2, inner.width / cell.width)),
                @intFromFloat(@max(2, inner.height / cell.height)),
            );
            result.items[result.count] = .{ .terminal = pane.terminal, .cols = proposed.x, .rows = proposed.y };
            result.count += 1;
            continue;
        }
        const remote = model.phuxConst() orelse continue;
        if (remote.presentation(pane.terminal) == null) continue;
        const proposed = grid.Session.clampGrid(
            @intFromFloat(@max(2, inner.width / metrics.width)),
            @intFromFloat(@max(2, inner.height / metrics.height)),
        );
        result.items[result.count] = .{ .terminal = pane.terminal, .cols = proposed.x, .rows = proposed.y };
        result.count += 1;
    }
    return result;
}

/// Whether `proposal` disagrees with what that terminal is currently at.
///
/// Local panes compare against the model's committed cols/rows; remote ones
/// against the last viewport the provider was told, because a remote terminal
/// has no local grid to read.
pub fn viewportDiffers(model: *const Model, proposal: PaneViewport) bool {
    if (model.provider.terminalConst(proposal.terminal)) |terminal| {
        return proposal.cols != terminal.cols or proposal.rows != terminal.rows;
    }
    const remote = model.phuxConst() orelse return false;
    const last = remote.lastViewport(proposal.terminal) orelse return true;
    return !last.eql(.{ .cols = proposal.cols, .rows = proposal.rows });
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
