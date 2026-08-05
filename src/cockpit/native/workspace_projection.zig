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

pub const grid_inset: f32 = 8;
/// The tab band's height. It must be at least the register's own trigger
/// height, or the strip overflows the band and paints its hairline and
/// underline indicator down into the terminal's first row. The Geist pack
/// computes 50 at the default control size (`metrics.tabs_trigger_height`),
/// and `headerHeightCoversTriggers` pins the two together.
pub const header_height: f32 = 50;
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
    return pane.phase == .ended or pane.phase == .failed or paneHasConfirmedLoss(pane) or
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

pub const WorkspaceChrome = struct {
    titlebar_height: f32,
    /// The band's own rect, so the header ground and its separator paint
    /// exactly where the strip is laid out. Zero-height when at rest.
    header: geometry.RectF,
    content: geometry.RectF,
};

pub fn workspaceChrome(model: *const Model, size: geometry.SizeF) WorkspaceChrome {
    const titlebar = @max(grid_inset, model.chrome_top + 4);
    const revealed = chromeRevealed(model);
    const side_extent = if (revealed and model.tab_placement == .side) side_rail_width + side_rail_gap else 0;
    const top_extent = if (revealed and model.tab_placement == .top) header_height else 0;
    return .{
        .titlebar_height = titlebar,
        .header = geometry.RectF.init(
            grid_inset,
            titlebar,
            @max(0, size.width - grid_inset * 2),
            top_extent,
        ),
        .content = geometry.RectF.init(
            grid_inset + side_extent,
            titlebar + top_extent,
            @max(0, size.width - grid_inset * 2 - side_extent),
            @max(0, size.height - titlebar - top_extent - grid_inset),
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
