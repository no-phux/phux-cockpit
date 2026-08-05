const native_sdk = @import("native_sdk");
const grid = @import("../../terminal/grid.zig");
const support = @import("../phux_support.zig");
const local = @import("../../providers/local/provider.zig");
const model_module = @import("../model.zig");
const topology = @import("../topology.zig");
const scene = @import("scene.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Model = model_module.Model;
const Pane = local.Pane;
const TerminalRef = support.TerminalRef;

pub const grid_inset: f32 = 8;
pub const header_height: f32 = 40;
pub const side_rail_width: f32 = 184;
pub const side_rail_gap: f32 = 8;
pub const side_tab_height: f32 = 34;
pub const split_divider_width: f32 = 9;
pub const split_pane_min_width: f32 = 240;
pub const split_pane_header_height: f32 = 24;
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

pub fn splitAvailable(model: *const Model) bool {
    if (model.layout == .split) return true;
    return model.terminal_count >= 2 and model.selectedPlacement() != null;
}

pub fn selectedTerminalCanClose(model: *const Model) bool {
    const terminal_ref = model.selectedTerminalRef() orelse return false;
    return support.providerKind(terminal_ref) == .local;
}

pub fn chromeRevealed(model: *const Model) bool {
    if (model.terminal_count > 1) return true;
    if (model.selectedTerminalRef() == null) return true;
    if (model.layout == .split) return true;
    for (model.terminal_order[0..model.terminal_count]) |id| {
        if (terminalNeedsAttention(model, id)) return true;
    }
    return false;
}

pub const WorkspaceChrome = struct {
    titlebar_height: f32,
    content: geometry.RectF,
};

pub fn workspaceChrome(model: *const Model, size: geometry.SizeF) WorkspaceChrome {
    const titlebar = @max(grid_inset, model.chrome_top + 4);
    const revealed = chromeRevealed(model);
    const side_extent = if (revealed and model.tab_placement == .side) side_rail_width + side_rail_gap else 0;
    const top_extent = if (revealed and model.tab_placement == .top) header_height else 0;
    return .{
        .titlebar_height = titlebar,
        .content = geometry.RectF.init(
            grid_inset + side_extent,
            titlebar + top_extent,
            @max(0, size.width - grid_inset * 2 - side_extent),
            @max(0, size.height - titlebar - top_extent - grid_inset),
        ),
    };
}

pub fn paneFrames(model: *const Model, size: geometry.SizeF) [local.pane_count]geometry.RectF {
    const content = workspaceChrome(model, size).content;
    var frames = [_]geometry.RectF{.{}} ** local.pane_count;
    if (model.selectedTerminalIndex()) |selected| {
        if (model.layout == .single) {
            frames[selected] = content;
        } else {
            const available = @max(0, content.width - split_divider_width);
            const fraction = canvas.splitEffectiveFraction(
                model.split_fraction,
                available,
                split_pane_min_width,
                split_pane_min_width,
            );
            const first_width = available * fraction;
            const terminal_top = content.y + split_pane_header_height;
            const terminal_height = @max(0, content.height - split_pane_header_height);
            frames[0] = geometry.RectF.init(content.x, terminal_top, first_width, terminal_height);
            frames[1] = geometry.RectF.init(
                content.x + first_width + split_divider_width,
                terminal_top,
                @max(0, available - first_width),
                terminal_height,
            );
        }
    }
    return frames;
}
