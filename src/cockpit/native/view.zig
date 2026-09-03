const std = @import("std");
const native_sdk = @import("native_sdk");
const grid = @import("../../terminal/grid.zig");
const url_module = @import("../../terminal/url.zig");
const provider_contract = @import("provider_contract");
const support = @import("../phux_support.zig");
const local_terminal = @import("../../providers/local/provider.zig");
const model_module = @import("../model.zig");
const topology = @import("../topology.zig");
const layout = @import("../layout.zig");
const app_types = @import("../app_types.zig");
const pointer_input = @import("../pointer_input.zig");
const projection = @import("workspace_projection.zig");
const scene_module = @import("scene.zig");
const theme_module = @import("../../config/theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const Model = model_module.Model;
const Workspace = model_module.Workspace;
const Pane = local_terminal.Pane;
const LocalTerminalId = support.LocalTerminalId;
const Phase = support.Phase;
const TerminalRef = support.TerminalRef;
const Viewport = support.Viewport;
const TabPlacement = topology.TabPlacement;
const TerminalApp = app_types.TerminalApp;
const Msg = app_types.Msg;
const max_terminals = local_terminal.max_terminals;
const max_tabs = topology.max_tabs;
const first_terminal_raw = local_terminal.first_terminal_raw;
const providerKind = support.providerKind;
const header_height = projection.header_height;
const side_rail_width = projection.side_rail_width;
const side_rail_gap = projection.side_rail_gap;
const side_tab_height = projection.side_tab_height;
const split_divider_width = projection.split_divider_width;
const split_pane_min_width = projection.split_pane_min_width;
const split_pane_min_height = projection.split_pane_min_height;
const webkit_parking_extent = projection.webkit_parking_extent;
const webview_label = scene_module.webview_label;
const webview_anchor = scene_module.webview_anchor;
const chrome_command_envelope = projection.chrome_command_envelope;
const windowPadding = projection.windowPadding;
const cockpitTokens = projection.cockpitTokens;
const terminalTokens = projection.terminalTokens;
const chromeRevealed = projection.chromeRevealed;
const workspaceChrome = projection.workspaceChrome;
const resolvePanes = projection.resolvePanes;
const terminalNeedsAttention = projection.terminalNeedsAttention;
const paneLifecycleFailed = projection.paneLifecycleFailed;

const PaletteRow = struct {
    label: []const u8,
    detail: []const u8,
    on_press: Msg,
    semantics: []const u8,
    terminal: ?TerminalRef,
    placed: bool,
};
const paneHasConfirmedLoss = projection.paneHasConfirmedLoss;
const selectedTerminalCanClose = projection.selectedTerminalCanClose;
const paneReportsMouse = pointer_input.paneReportsMouse;
const validScale = pointer_input.validScale;
const selection_autoscroll_timer_id = app_types.selection_autoscroll_timer_id;
const TerminalUi = TerminalApp.Ui;

const tab_height = projection.tab_height;
const tab_control_extent = projection.tab_control_extent;
const tab_marker_extent = projection.tab_marker_extent;
const visibleTabWindow = projection.visibleTabWindow;
/// The attention marker's icon name. One constant, because both placements
/// paint it and a test pins it.
const attention_marker_icon = "circle-dot";

/// Retained ids for the app's own chrome grounds. Disjoint from the grid
/// painter's namespace (`render.paneIdBase` starts at 0x7e21), so damage
/// tracking treats them as their own stable commands.
pub const window_ground_command_id: u64 = 0x0c01;
pub const header_ground_command_id: u64 = 0x0c02;
pub const header_rule_command_id: u64 = 0x0c03;
/// The drawn caret, in the two fields this app routes keys to itself.
///
/// The one place in the chrome that takes its size from the TERMINAL rather
/// than from the chrome register, and deliberately: it is imitating the cursor
/// two rows below it, so a caret on the 4pt grid would be a caret that does not
/// match the thing it is pretending to be. At the default 13pt the bundled
/// 0.6em face gives a 7.8 x 17.16 cell, and 8 x 16 is the whole-point box
/// nearest it. This is a MARK, not a spacing value; docs/DESIGN_SYSTEM.md's
/// rule against deriving chrome spacing from cell metrics still holds
/// everywhere else.
///
/// One pair, not two. The search band drew 7x16 and the switcher drew 7x15,
/// and neither site recorded why they differed.
pub const field_caret_width: f32 = 8;
pub const field_caret_height: f32 = 16;

/// The summoned switcher's geometry. Wide enough for a real shell title
/// beside its chord, short enough that it reads as a panel over the terminal
/// rather than as a second window.
///
/// Its rows are `chrome_control_extent` — the same small-register control the
/// search band hosts — and its padding is `chrome_gap`. A floating panel and a
/// docked band are the same system; what separates them is the scrim behind
/// this one, not a second set of metrics.
pub const palette_width: f32 = 460;
pub const palette_row_height: f32 = projection.chrome_control_extent;
/// The panel's own padding, and the row width inside it.
pub const palette_padding: f32 = projection.chrome_gap;
pub const palette_row_width: f32 = palette_width - palette_padding * 2;
/// How far down the content the panel sits. Not centred: a switcher pinned to
/// the vertical middle covers the prompt, which is the one row the user was
/// looking at when they summoned it.
///
/// 40, not 72. The inset is applied on every side (`ElementOptions.padding` is
/// symmetric), so it is subtracted from the panel's available height twice: at
/// 72 a full eight-row switcher needed 336pt inside the 276 that a
/// minimum-height window left it, and the tail of the list was painted past the
/// bottom edge. 40 leaves 340 for the same 336, which the layout audit is what
/// proves rather than this arithmetic.
pub const palette_top_inset: f32 = 40;
/// The scrim behind it — black, for the same reason `dim_scrim` is: it has to
/// darken whatever the terminal's own background happens to be.
///
/// Deeper than `dim_scrim` on purpose, and the difference is the point. An
/// unfocused split is still being read, so its wash has to stay shallow; the
/// grid behind an open switcher is explicitly NOT being read, and pushing it
/// back is what stops the palette's own rows competing with a screen of text.
const palette_scrim: canvas.Color = canvas.Color.rgba(0, 0, 0, 0.5);

/// The settings surface's geometry. Wider than the switcher because each row
/// carries a name, a one-line summary, and its measured contrast, and none of
/// the three is worth eliding.
pub const settings_width: f32 = 560;
pub const settings_row_height: f32 = projection.chrome_control_extent;
pub const settings_padding: f32 = projection.chrome_gap;
pub const settings_row_width: f32 = settings_width - settings_padding * 2;
/// The panel's margin from the window edge, and it is a MARGIN now rather than
/// a top inset: the panel is centred.
///
/// The old arrangement pinned it 56pt from the top, which is the palette's
/// reasoning — do not cover the prompt — applied to a surface that reasoning
/// does not describe. The switcher is a lightweight overlay you read the
/// terminal around; the settings panel is modal, takes the keyboard, and lays a
/// 62% scrim over everything behind it. There is no prompt left to preserve, so
/// the panel goes where a modal goes.
///
/// It also has to: at 56 on every side the panel needed 385pt inside the 308 a
/// minimum-height window left it. Centred at a 16pt margin it gets 388.
pub const settings_margin: f32 = 16;

/// THE SETTINGS SURFACE'S OWN COLOURS, AND WHY THEY ARE LITERALS.
///
/// This panel is what you open when the terminal has become unreadable. If it
/// painted with the tokens the user is trying to FIX, then the one
/// configuration it exists to rescue — text you cannot see — would make the
/// rescue itself invisible. A settings page you cannot read when things are
/// wrong is worse than no settings page at all, because it costs someone the
/// time to find it before it fails them. That is not hypothetical here:
/// `phux-cockpit-aht` is four rounds of "I can't see the text".
///
/// Today `cockpitTokens` happens to be independent of the user's config — only
/// `terminalTokensFrom` applies `foreground`/`background`, and only the grids
/// paint with those. That is NOT a reason to lean on the tokens here. A theming
/// feature is precisely the change that starts colouring the chrome; it is the
/// obvious next request, and on the day it lands every other panel can afford
/// to follow the theme and this one still cannot. Pinning the values AT THE
/// SITE makes wiring this panel to a theme something a person has to
/// deliberately undo rather than something they can do by accident.
///
/// These four are also not chosen by eye. Every one is measured against the
/// ground it sits on with the same WCAG formula the panel itself reports, and
/// every one clears AA (4.5:1) on BOTH grounds. Derived with:
///
///   python3 -c 'def L(h):
///    c=[int(h[i:i+2],16)/255 for i in (1,3,5)]
///    f=lambda x: x/12.92 if x<=0.03928 else ((x+0.055)/1.055)**2.4
///    r,g,b=[f(x) for x in c]; return .2126*r+.7152*g+.0722*b
///   cr=lambda a,b:(max(L(a),L(b))+.05)/(min(L(a),L(b))+.05)
///   print([round(cr(x,"#101010"),2) for x in ("#ffffff","#b3b3b3","#7ee787","#ff7b72")])'
///
///                       on #101010   on #262626
///   settings_ink          19.03         15.13
///   settings_ink_muted     9.08          7.22
///   settings_pass         12.38          9.85
///   settings_fail          7.55          6.00
///
/// `settings_border` is a hairline and not text, so no text threshold applies
/// to it.
const settings_ground: canvas.Color = canvas.Color.rgb8(0x10, 0x10, 0x10);
const settings_ground_raised: canvas.Color = canvas.Color.rgb8(0x26, 0x26, 0x26);
const settings_ink: canvas.Color = canvas.Color.rgb8(0xff, 0xff, 0xff);
const settings_ink_muted: canvas.Color = canvas.Color.rgb8(0xb3, 0xb3, 0xb3);
const settings_pass: canvas.Color = canvas.Color.rgb8(0x7e, 0xe7, 0x87);
const settings_fail: canvas.Color = canvas.Color.rgb8(0xff, 0x7b, 0x72);
const settings_border: canvas.Color = canvas.Color.rgb8(0x3d, 0x3d, 0x3d);
/// The scrim behind the panel. Deeper than the palette's, because the grid
/// behind a settings panel may be the very thing that is illegible and pushing
/// it further back is what stops it competing with the readout.
const settings_scrim: canvas.Color = canvas.Color.rgba(0, 0, 0, 0.62);

/// The spoken name of the panel itself. Also the handle a test uses to find
/// the panel's own ground, so the "this stays readable" invariant can be
/// measured against the colour actually painted rather than a copy of it.
pub const settings_panel_label = "Settings";
/// The spoken name of the two swatches that deliberately paint in the USER's
/// colours. They are the only text in the panel exempt from its own legibility
/// invariant, because showing an unreadable pair is precisely their job.
pub const settings_sample_label = "colour sample";
/// Prefix for the read-only transport disclosure in Settings. "Location" is
/// deliberate: a socket path says where to connect, never who is authoritative.
pub const settings_phux_transport_label = "Phux transport location";

/// Base for the unfocused-pane scrim, one retained id per resolved pane.
/// Disjoint from the three above and from `render.paneIdBase` (0x7e21+).
pub const pane_dim_command_id_base: u64 = 0x0c10;
/// The focused pane's accent edge: four hairlines, so exactly four ids.
/// `pane_dim_command_id_base` spans at most `layout.max_panes` (16) ids from
/// 0x0c10, so 0x0c30 clears it with room.
pub const pane_focus_command_id_base: u64 = 0x0c30;
/// The focus edge's thickness, in points.
pub const pane_focus_edge_thickness: f32 = 1;
/// Pane-local OSC 8 target preview commands.
pub const link_preview_ground_command_id_base: u64 = 0x0c50;
pub const link_preview_text_command_id_base: u64 = 0x0c70;
pub const link_preview_authority_command_id_base: u64 = 0x0c90;
const link_preview_command_count: usize = 3;

pub fn linkPreviewCommandReserve(session: *grid.Session) usize {
    const target = session.hoveredOsc8Target() orelse return 0;
    const identity = url_module.targetIdentity(target) orelse return 0;
    return if (identity.effective_authority != null) link_preview_command_count else 0;
}

// A `terminalNumber(LocalTerminalId)` used to sit here, turning a registry
// slot into a display number, with no callers left and a doc comment about the
// colour register that had drifted onto it. It is deleted rather than left
// dormant: a second answer to "what number is this terminal" is exactly what
// produced a tab named "Terminal 5" wearing the CMD+4 chord, and the next
// reader in a hurry would have found it first. `projection.terminalAddress` is
// the only answer now.

/// The tab label for a terminal. The chain itself lives in
/// `workspace_projection.terminalTitleInto`, because the tab strip is no
/// longer its only reader — the menu-bar extra and the background-bell banner
/// name the same terminals, and two implementations of one chain are two sets
/// of names to keep in agreement.
///
/// The build arena is the buffer: only the `Terminal N` fallback needs one,
/// and it lives exactly as long as this view build.
fn terminalTitle(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    const scratch = ui.arena.alloc(u8, projection.max_terminal_title_bytes) catch return "Terminal";
    return projection.terminalTitleInto(model, id, scratch);
}

/// The tab label as it will be PAINTED, which at the strip's shrink floor is
/// not the same string as the name.
///
/// `projection.elideTitleMiddleInto` explains why the middle goes rather than
/// the tail. What belongs here is why the app does it at all instead of leaving
/// it to the renderer's own `.overflow = .ellipsis`: the elided string is what
/// the accessibility tree and `native automate snapshot` report, so doing it
/// here is what makes an unreadable strip visible to automation. It was not,
/// and that is why a strip painting `Termi…` seven times shipped — the snapshot
/// said `Terminal 10`, `Terminal 11`, and only the composited pixels disagreed.
///
/// The full title still reaches the SEMANTICS label and the close button's, so
/// nothing an assistive reader is told gets shorter.
fn paintedTabLabel(ui: *TerminalUi, tokens: canvas.DesignTokens, title: []const u8, label_width: f32) []const u8 {
    const scratch = ui.arena.alloc(u8, projection.max_painted_title_bytes) catch return title;
    return projection.elideTitleMiddleInto(tokens, title, label_width, scratch);
}

/// The retained-command id namespace a terminal paints into. Local terminals
/// take their registry slot, which is bounded and collision-free by
/// construction; remote terminals derive a disjoint namespace from their
/// identity hash, with the high bit set so the two spaces cannot overlap.
fn terminalPaintIndex(model: *const Model, terminal_ref: TerminalRef) usize {
    if (provider_contract.isLocal(terminal_ref)) {
        return model.provider.slotIndex(terminal_ref) orelse 0;
    }
    return @intCast(0x0000_8000_0000_0000 | (terminal_ref.hash() & 0x0000_7fff_ffff_ffff));
}

/// A divider drag has to say WHICH branch moved, and the SDK's resize
/// callback carries only the fraction. One handler per node id closes that
/// gap at comptime rather than guessing at dispatch.
fn splitResizeHandler(comptime node: layout.NodeId) TerminalUi.ValueMsgFn {
    return struct {
        fn make(value: f32) Msg {
            return .{ .split_resized = .{ .node = node, .value = value } };
        }
    }.make;
}

const split_resize_handlers: [layout.max_nodes]TerminalUi.ValueMsgFn = blk: {
    var table: [layout.max_nodes]TerminalUi.ValueMsgFn = undefined;
    for (0..layout.max_nodes) |index| table[index] = splitResizeHandler(@intCast(index));
    break :blk table;
};

fn paneLifecycleText(ui: *TerminalUi, pane: *const Pane) []const u8 {
    return switch (pane.phase) {
        .starting => "STARTING",
        .attaching => "ATTACHING",
        .live => "RUNNING",
        .reconnecting => "RECONNECTING",
        .tombstoned => "REMOVED",
        .frozen => "FROZEN",
        .ended => switch (pane.exit_reason) {
            .exited => ui.fmt("EXIT {d}", .{pane.exit_code}),
            .signaled => ui.fmt("SIGNAL {d}", .{pane.exit_signal}),
            .cancelled => "CANCELLED",
            else => "ENDED",
        },
        .failed => switch (pane.exit_reason) {
            .rejected => "SPAWN REJECTED",
            .spawn_failed => "SPAWN FAILED",
            else => "FAILED",
        },
    };
}

fn remoteLifecycleText(phase: Phase) []const u8 {
    return switch (phase) {
        .starting => "STARTING",
        .attaching => "ATTACHING",
        .live => "RUNNING",
        .reconnecting => "RECONNECTING",
        .tombstoned => "REMOVED",
        .frozen => "FROZEN",
        .ended => "ENDED",
        .failed => "FAILED",
    };
}
fn placedPaletteRow(
    ui: *TerminalUi,
    model: *const Model,
    placed: model_module.PlacedTerminalDestination,
    highlighted: bool,
) PaletteRow {
    const title = terminalTitle(ui, model, placed.terminal_ref);
    if (providerKind(placed.terminal_ref) == .local) {
        const lifecycle = if (model.provider.terminalConst(placed.terminal_ref)) |pane|
            paneLifecycleText(ui, pane)
        else
            "UNAVAILABLE";
        return .{
            .label = title,
            .detail = ui.fmt("WINDOW {d} / TAB {d} / LOCAL", .{ placed.window + 1, placed.tab + 1 }),
            .on_press = .{ .palette_activate = .{ .placed_terminal = placed } },
            .semantics = ui.fmt("{s}, open in window {d}, tab {d}, local, {s}{s}", .{
                title,
                placed.window + 1,
                placed.tab + 1,
                lifecycle,
                if (highlighted) ", highlighted" else "",
            }),
            .terminal = placed.terminal_ref,
            .placed = true,
        };
    }
    const lifecycle = if (model.remotePresentation(placed.terminal_ref)) |presentation|
        remoteLifecycleText(presentation.phase)
    else
        "UNAVAILABLE";
    return .{
        .label = title,
        .detail = ui.fmt("WINDOW {d} / TAB {d} / PHUX / {s}", .{
            placed.window + 1,
            placed.tab + 1,
            lifecycle,
        }),
        .on_press = .{ .palette_activate = .{ .placed_terminal = placed } },
        .semantics = ui.fmt("{s}, open in window {d}, tab {d}, Phux, {s}{s}", .{
            title,
            placed.window + 1,
            placed.tab + 1,
            lifecycle,
            if (highlighted) ", highlighted" else "",
        }),
        .terminal = placed.terminal_ref,
        .placed = true,
    };
}

fn availablePaletteRow(
    ui: *TerminalUi,
    model: *const Model,
    terminal_ref: TerminalRef,
    highlighted: bool,
) PaletteRow {
    const title = terminalTitle(ui, model, terminal_ref);
    const lifecycle = if (model.remotePresentation(terminal_ref)) |presentation|
        remoteLifecycleText(presentation.phase)
    else
        "UNAVAILABLE";
    return .{
        .label = title,
        .detail = ui.fmt("PHUX / {s}", .{lifecycle}),
        .on_press = .{ .palette_activate = .{ .available_terminal = terminal_ref } },
        .semantics = ui.fmt("{s}, available in Phux, {s}{s}", .{
            title,
            lifecycle,
            if (highlighted) ", highlighted" else "",
        }),
        .terminal = null,
        .placed = false,
    };
}

fn sessionPaletteRow(
    ui: *TerminalUi,
    model: *const Model,
    session_id: u32,
    highlighted: bool,
) ?PaletteRow {
    const remote = model.phuxConst() orelse return null;
    for (remote.sessionCatalog()) |session| {
        if (session.id != session_id) continue;
        const selected = remote.selectedSessionId() == session.id;
        return .{
            .label = ui.fmt("{s}", .{session.name}),
            .detail = ui.fmt("{d} WIN / {d} CLIENT{s}", .{
                session.window_count,
                session.attached_client_count,
                if (selected) " / CURRENT" else "",
            }),
            .on_press = .{ .palette_activate = .{ .session = session.id } },
            .semantics = ui.fmt("{s}, Phux session {d}, {d} windows, {d} attached clients{s}{s}", .{
                session.name,
                session.id,
                session.window_count,
                session.attached_client_count,
                if (selected) ", current" else "",
                if (highlighted) ", highlighted" else "",
            }),
            .terminal = null,
            .placed = false,
        };
    }
    return null;
}

fn paletteRowFor(
    ui: *TerminalUi,
    model: *const Model,
    entry: projection.PaletteEntry,
    highlighted: bool,
) ?PaletteRow {
    return switch (entry) {
        .placed_terminal => |placed| placedPaletteRow(ui, model, placed, highlighted),
        .available_terminal => |terminal_ref| availablePaletteRow(ui, model, terminal_ref, highlighted),
        .session => |session_id| sessionPaletteRow(ui, model, session_id, highlighted),
    };
}

fn paletteSectionLabel(section: projection.PaletteSection) []const u8 {
    return switch (section) {
        .open => "OPEN",
        .available => "AVAILABLE IN PHUX",
        .sessions => "SESSIONS",
    };
}
fn paletteSectionChanged(previous: ?projection.PaletteSection, current: projection.PaletteSection) bool {
    return previous == null or previous.? != current;
}

fn paletteSectionNode(
    ui: *TerminalUi,
    section: projection.PaletteSection,
    tokens: canvas.DesignTokens,
) TerminalUi.Node {
    const label = paletteSectionLabel(section);
    return ui.el(.stack, .{
        .width = palette_row_width,
        .height = projection.chrome_icon_extent,
        .semantics = .{ .label = ui.fmt("{s} destinations", .{label}) },
    }, .{
        ui.text(.{
            .wrap = false,
            .style = .{ .foreground = tokens.colors.text_muted },
        }, label),
    });
}

fn paletteSelectableNode(
    ui: *TerminalUi,
    model: *const Model,
    row: PaletteRow,
    highlighted: bool,
    tokens: canvas.DesignTokens,
) TerminalUi.Node {
    return ui.el(.list_item, .{
        .width = palette_row_width,
        .height = palette_row_height,
        .selected = highlighted,
        .on_press = row.on_press,
        .style = .{ .background = if (highlighted) tokens.colors.surface_pressed else tokens.colors.surface },
        .semantics = .{
            .role = if (row.placed) .tab else .button,
            .label = row.semantics,
        },
    }, .{
        ui.row(.{ .width = palette_row_width, .height = palette_row_height, .cross = .center }, .{
            // A 3:1 accent rail carries selection state; the surface wash
            // alone is intentionally too quiet to do that accessibly.
            ui.el(.stack, .{
                .width = projection.tab_indicator_thickness,
                .height = palette_row_height,
                .style = .{ .background = if (highlighted) tokens.colors.accent else tokens.colors.surface },
            }, .{}),
            ui.row(.{ .grow = 1, .gap = projection.chrome_gap, .cross = .center, .padding = projection.chrome_gap }, .{
                if (row.terminal) |id| tabAttentionMarker(ui, model, id, tokens) else ui.spacer(projection.chrome_icon_extent),
                ui.text(.{
                    .grow = 1,
                    .wrap = false,
                    .overflow = .ellipsis,
                    .style = .{ .foreground = if (highlighted) tokens.colors.text else tokens.colors.text_muted },
                }, row.label),
                ui.text(.{
                    .wrap = false,
                    .style = .{ .foreground = tokens.colors.text_muted },
                }, row.detail),
            }),
        }),
    });
}

fn paletteSearchField(
    ui: *TerminalUi,
    needle: []const u8,
    tokens: canvas.DesignTokens,
) TerminalUi.Node {
    const empty = needle.len == 0;
    return ui.row(.{ .width = palette_row_width, .height = palette_row_height, .gap = projection.chrome_gap, .cross = .center, .padding = projection.chrome_gap }, .{
        ui.icon(.{
            .width = projection.chrome_icon_extent,
            .height = projection.chrome_icon_extent,
            .style = .{ .foreground = tokens.colors.text_muted },
        }, "search"),
        ui.text(.{
            .wrap = false,
            .overflow = .ellipsis,
            .style = .{ .foreground = if (empty) tokens.colors.text_muted else tokens.colors.text },
        }, if (empty) "Go to terminal or session…" else needle),
        ui.el(.stack, .{
            .width = field_caret_width,
            .height = field_caret_height,
            .style = .{ .background = tokens.colors.accent },
        }, .{}),
        ui.spacer(1),
    });
}

fn emptyStatusNode(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.stack, .{}, .{});
}

/// The full diagnostic sentence for a local pane. It lives in the
/// accessibility label ONLY: a screen reader keeps everything, the eye keeps
/// nothing. `COPIED nB`, `I/O LOSS`, `INPUT STALLED` and friends used to be
/// painted as product chrome, which made ordinary terminal use look like a
/// telemetry dashboard.
fn paneDiagnostics(ui: *TerminalUi, model: *const Model, pane: *const Pane) []const u8 {
    const paste_failed = model.paste_owner.terminal_ref.eql(pane.id) and model.paste_failed;
    return ui.fmt(
        "{s}, native terminal, {s}; outbound loss {d} bytes; reply loss {d} bytes; input stalled {d} times; native delivery failures {d}; copy {s}; paste {s}; copied {d} bytes",
        .{
            terminalTitle(ui, model, pane.id),
            paneLifecycleText(ui, pane),
            pane.outbound_dropped,
            pane.session.response_bytes_dropped,
            pane.write_refusals,
            pane.native_delivery_failures,
            if (pane.copy_failed) "failed" else "ok",
            if (paste_failed) "failed" else "ok",
            pane.copied_bytes,
        },
    );
}

/// The one piece of pane status that survives as CHROME: a terminal that never
/// got a process offers Restart. A shell that RAN and ended closes its pane at
/// any status, so it never reaches here.
fn paneStatus(ui: *TerminalUi, model: *const Model, terminal_ref: TerminalRef) TerminalUi.Node {
    if (providerKind(terminal_ref) == .phux) return emptyStatusNode(ui);
    const pane = model.provider.terminalConst(terminal_ref) orelse return emptyStatusNode(ui);
    if (!paneLifecycleFailed(pane)) return emptyStatusNode(ui);
    return ui.row(.{ .gap = projection.chrome_gap, .cross = .center }, .{
        ui.el(.badge, .{
            .variant = .destructive,
            .text = paneLifecycleText(ui, pane),
            .semantics = .{ .label = paneDiagnostics(ui, model, pane) },
        }, .{}),
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .{ .restart = pane.id },
            .semantics = .{ .label = ui.fmt("Restart {s}", .{terminalTitle(ui, model, pane.id)}) },
        }, "Restart"),
    });
}

/// The spoken description of one tab. Unchanged in content from the old
/// strip: a screen reader still gets the whole diagnostic sentence the eye no
/// longer sees.
fn tabSemantics(ui: *TerminalUi, model: *const Model, ws: *const Workspace, tab_index: usize, id: TerminalRef, title: []const u8, selected: bool) []const u8 {
    // The digit spoken here and the digit that opens `title` are the SAME
    // CALL, not two derivations that happen to agree. They did not agree: this
    // line read `tab_index + 1` while the name came from the registry slot, so
    // one close-then-open was enough to make a tab say "Terminal 5 … shortcut
    // CMD+4" out loud. `terminalAddress` is now the only place either number
    // is decided.
    //
    // A terminal the model cannot locate is announced with no digit at all
    // rather than with `tab_index + 1`: a strip drawing an id that lives in no
    // tab is a broken invariant, and answering it with a plausible-looking
    // number is how the original contradiction stayed invisible for so long.
    const shortcut = if (projection.terminalAddress(model, id)) |at|
        if (at.tab <= 5) ui.fmt("CMD+{d}", .{at.tab}) else "not assigned"
    else
        "unavailable";
    const panes_in_tab = if (ws.treeConst(tab_index)) |current| current.paneCount() else 1;
    const kind_label = if (provider_contract.isLocal(id)) "native terminal" else "phux terminal";
    return if (model.provider.terminalConst(id)) |terminal|
        ui.fmt("{s}, {s}, {d} pane(s); {s}; shortcut {s}{s}", .{
            title,
            kind_label,
            panes_in_tab,
            paneDiagnostics(ui, model, terminal),
            shortcut,
            if (selected) ", selected" else "",
        })
    else
        ui.fmt("{s}, {s}, {s}; shortcut {s}{s}", .{
            title,
            kind_label,
            if (model.remotePresentation(id)) |presentation| remoteLifecycleText(presentation.phase) else "UNAVAILABLE",
            shortcut,
            if (selected) ", selected" else "",
        });
}

/// The attention marker: a DOT in a fixed slot, never a `!` welded onto the
/// terminal's name. The slot is reserved whether or not the dot is drawn, so
/// a bell does not shove the label sideways.
///
/// `tab_marker_extent` is `chrome_icon_extent` — the app's ONE inline-icon
/// size — rather than the 8pt it used to be. At 8pt `circle-dot` has a ring and
/// a dot to draw inside eight points and renders as a smudge; the register's
/// own answer for an icon beside 13pt text is 15 and the cap-height recipe says
/// 15.1, so 16 is the artboard both round to. No extra room is held for the
/// fact that it is a CIRCLE — circles do want 111-113% of an equivalent square
/// to read the same size, but this is a vector icon on the toolkit's own icon
/// grid, which has already applied that correction; adding it again here would
/// double it.
fn tabAttentionMarker(ui: *TerminalUi, model: *const Model, id: TerminalRef, tokens: canvas.DesignTokens) TerminalUi.Node {
    if (!terminalNeedsAttention(model, id)) {
        return ui.el(.stack, .{ .width = tab_marker_extent, .semantics = .{ .hidden = true } }, .{});
    }
    // The EXPLICIT icon channel (`Widget.icon`), the way `Ui.appIcon` does
    // it — `Ui.icon` puts the name in `text`, and this leaf's text is read by
    // damage tracking and by the a11y fingerprint as content.
    return ui.el(.icon, .{
        .width = tab_marker_extent,
        .height = tab_marker_extent,
        .icon = attention_marker_icon,
        .style = .{ .foreground = tokens.colors.warning },
        .semantics = .{ .label = "Needs attention" },
    }, .{});
}

/// One tab in the top strip.
///
/// Built from a `.stack` rather than the register's `segmented_control`
/// because a segmented trigger is a LEAF: it carries a label and one icon and
/// nothing else, so it can never host a close affordance. This is the shape
/// the toolkit's own code-editor example uses for exactly that reason — press
/// target on the container, controls as real children inside it.
fn terminalTabTrigger(ui: *TerminalUi, model: *const Model, ws: *const Workspace, tab_index: usize, tokens: canvas.DesignTokens, extent: f32) TerminalUi.Node {
    const id = ws.tabTerminal(tab_index) orelse return ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    const selected = !ws.web_selected and ws.selected_tab == tab_index;
    const title = terminalTitle(ui, model, id);
    const semantics = tabSemantics(ui, model, ws, tab_index, id, title, selected);
    const trigger_key: canvas.UiKey = .{ .index = terminalPaintIndex(model, id) };

    // The close `x` shows on the SELECTED tab and on whatever the pointer is
    // over. Showing it on every tab turns a strip of names into a strip of
    // buttons; showing it on none makes closing a mouse-only user's problem.
    const show_close = projection.tabCanClose(id) and (selected or ws.hovered_tab == tab_index);
    const close_node = if (show_close)
        ui.button(.{
            .width = tab_control_extent,
            .height = tab_control_extent,
            .size = .icon,
            .variant = .ghost,
            .icon = "x",
            .on_press = .{ .close_tab = @intCast(tab_index) },
            .semantics = .{ .label = ui.fmt("Close {s}", .{title}) },
        }, "")
    else
        ui.el(.stack, .{ .width = tab_control_extent, .semantics = .{ .hidden = true } }, .{});

    // The tab's own menu. Every verb here has a chord already; what the menu
    // adds is that they act on THIS tab rather than on the selected one, which
    // is the whole reason a right-click on a tab exists. `Close Others` has no
    // chord at all and is the one people reach for after an afternoon.
    //
    // Disabled rather than absent at the ends of the strip: a menu whose items
    // move depending on where the tab sits is a menu nobody can learn.
    const last_tab = ws.tab_count -| 1;
    const tab_menu = [_]TerminalUi.ContextMenuItem{
        .{ .label = "New Terminal", .msg = .new_terminal },
        .{ .separator = true },
        .{
            .label = "Move Left",
            .msg = .{ .move_tab = .{ .index = @intCast(tab_index), .delta = -1 } },
            .enabled = tab_index > 0,
        },
        .{
            .label = "Move Right",
            .msg = .{ .move_tab = .{ .index = @intCast(tab_index), .delta = 1 } },
            .enabled = tab_index < last_tab,
        },
        .{ .separator = true },
        .{
            .label = "Close",
            .msg = .{ .close_tab = @intCast(tab_index) },
            // A Phux terminal's lifetime belongs to its coordinator, exactly
            // as it does for cmd+W: an item that looks live and does nothing
            // is worse than one that says it cannot.
            .enabled = projection.tabCanClose(id),
        },
        .{
            .label = "Close Others",
            .msg = .{ .close_other_tabs = @intCast(tab_index) },
            .enabled = ws.tab_count > 1,
        },
    };

    // TWO selection signals, and the second one is not redundancy — it is the
    // only one that carries.
    //
    // The lighter fill alone was the whole signal here, on the argument that a
    // second marker would compete with it. Measured, that fill is
    // `surface_subtle` over `surface`: 1.07 to 1. WCAG 2.1 SC 1.4.11 asks 3:1
    // of anything that indicates STATE, and this is not a palette that was
    // picked badly — it is the ceiling. Material's dark-theme elevation model
    // runs 5% white at 1dp to 16% at 24dp, and the whole of that range spans
    // 1.00:1 to 1.60:1. Reaching 3:1 against this ground needs a mid grey, at
    // which point the selected tab has stopped being a tab and become a button.
    //
    // So elevation says NEAR and the accent says HERE, which is the same verb
    // the focused pane's edge already uses. `accent` on `surface` measures
    // 14.10:1. The bar is the Geist pack's own `tabs_indicator_thickness`, and
    // it is inset by a full gap on each side so it clears the pill's 6pt corner
    // radius instead of being clipped by it — which is the real reason the
    // earlier underline did not survive.
    const body = ui.column(.{ .width = extent, .height = tab_height }, .{
        ui.row(.{ .grow = 1, .gap = projection.chrome_gap, .cross = .center, .padding = projection.chrome_gap }, .{
            tabAttentionMarker(ui, model, id, tokens),
            // `.ellipsis` stays, and is now a BACKSTOP rather than the policy:
            // the string handed over already fits the box (`paintedTabLabel`),
            // so the renderer's own tail elision is what catches the case where
            // its measurement and ours disagree by a hair. Losing a hair off
            // the tail is a blemish; losing the whole tail was the bug.
            ui.text(.{
                .grow = 1,
                .wrap = false,
                .overflow = .ellipsis,
                .style = .{ .foreground = if (selected) tokens.colors.text else tokens.colors.text_muted },
            }, paintedTabLabel(ui, tokens, title, projection.tabLabelWidth(extent))),
            close_node,
        }),
        // The unselected bar is painted in the tab's OWN ground rather than
        // omitted: a slot that appears only when selected would move the label
        // by two points every time the selection changed. It is deliberately
        // unnamed rather than `semantics.hidden`, because that flag suppresses
        // RENDERING as well as the accessibility node.
        ui.row(.{ .width = extent, .height = projection.tab_indicator_thickness, .main = .center }, .{
            ui.el(.stack, .{
                .width = @max(0, extent - projection.chrome_gap * 2),
                .height = projection.tab_indicator_thickness,
                .style = .{ .background = if (selected) tokens.colors.accent else tokens.colors.surface },
            }, .{}),
        }),
    });

    // `.list_item`, not `.stack`. A plain container is invisible to the
    // keyboard AND to assistive activation: `widgetKeyboardControlIntent`
    // has no arm for it, so Enter over a focused stack does nothing and an
    // advertised `press` action would be one an AX user cannot invoke. A
    // list item is focusable, answers Enter with `select`, and — unlike the
    // `segmented_control` this replaces — is a real container, which is what
    // lets a close affordance live inside the tab.
    return ui.el(.list_item, .{
        .global_key = trigger_key,
        .width = extent,
        .height = tab_height,
        .selected = selected,
        .on_press = .{ .select_position = @intCast(tab_index) },
        // Drag to reorder. The toolkit's drag record is closed at six fields
        // and the runtime injects five of them, so `sourceId` is the only
        // channel this app has for saying WHICH tab was picked up — which is
        // exactly what it carries. The gesture crosses the runtime's own drag
        // slop before a single event arrives, so an ordinary click still
        // selects and only a real drag reorders.
        .on_drag = .{ .tab_drag = .{ .sourceId = @intCast(tab_index) } },
        .on_hover_enter = .{ .hover_tab = @intCast(tab_index) },
        .on_hover_leave = .unhover_tab,
        .context_menu = &tab_menu,
        .style = .{ .background = if (selected) tokens.colors.surface_subtle else tokens.colors.surface },
        .semantics = .{ .role = .tab, .label = semantics },
    }, .{body});
}

/// The side rail's row for one tab. The outer `list_item` remains the native
/// hit target and accessibility control; its child row adds the same leading
/// accent rail the switcher's vertical list uses to say where selection is.
fn terminalRailTrigger(ui: *TerminalUi, model: *const Model, ws: *const Workspace, tab_index: usize, tokens: canvas.DesignTokens) TerminalUi.Node {
    const id = ws.tabTerminal(tab_index) orelse return ui.el(.stack, .{ .semantics = .{ .hidden = true } }, .{});
    const selected = !ws.web_selected and ws.selected_tab == tab_index;
    const title = terminalTitle(ui, model, id);
    return ui.el(.list_item, .{
        .global_key = .{ .index = terminalPaintIndex(model, id) },
        .size = .sm,
        .height = side_tab_height,
        .width = side_rail_width,
        .selected = selected,
        .on_press = .{ .select_position = @intCast(tab_index) },
        .style = .{ .background = if (selected) tokens.colors.surface_subtle else tokens.colors.surface },
        .semantics = .{ .role = .tab, .label = tabSemantics(ui, model, ws, tab_index, id, title, selected) },
    }, .{
        ui.row(.{ .width = side_rail_width, .height = side_tab_height, .cross = .center }, .{
            // Keep the slot in every row: changing selection changes ink, not
            // geometry. Two points is the pack's tab indicator thickness.
            ui.el(.stack, .{
                .width = projection.tab_indicator_thickness,
                .height = side_tab_height,
                .style = .{ .background = if (selected) tokens.colors.accent else tokens.colors.surface },
            }, .{}),
            ui.row(.{ .grow = 1, .gap = projection.chrome_gap, .cross = .center, .padding = projection.chrome_gap }, .{
                tabAttentionMarker(ui, model, id, tokens),
                ui.text(.{
                    .grow = 1,
                    .wrap = false,
                    .overflow = .ellipsis,
                    .style = .{ .foreground = if (selected) tokens.colors.text else tokens.colors.text_muted },
                }, title),
            }),
        }),
    });
}

/// A control plus the name it does not otherwise show.
///
/// An icon-only button has an accessibility label and nothing a sighted mouse
/// user can read, which leaves `+`, `x` and two chevrons to be learned by
/// pressing them. The toolkit's tooltip is the answer and costs this app no
/// state at all: the RUNTIME owns hover intent — delay, keyboard-focus reveal,
/// Escape, the warm window that makes the second tooltip in a row instant —
/// and the model never hears about hover.
///
/// Deliberately not on every tab. Anchored surfaces are budgeted at 16 per
/// view (`max_canvas_widget_anchored_per_view`, a loud
/// `error.WidgetAnchoredSurfaceLimitReached`), and a strip of 16 tabs would
/// spend the entire budget before the chrome around it got one. The controls
/// tipped here are FIXED chrome — four of them, whatever the tab count.
fn tipped(ui: *TerminalUi, trigger: TerminalUi.Node, text: []const u8) TerminalUi.Node {
    return ui.el(.stack, .{}, .{
        trigger,
        ui.el(.tooltip, .{
            .anchor = .below,
            .text = text,
            // The tip repeats the control's own accessible name, so a reader
            // that announced the button would announce it twice.
            .semantics = .{ .decorative = true },
        }, .{}),
    });
}

/// The `+`. One SMALL-register control (`chrome_control_extent`), square,
/// which is what puts it on the same rung as every other standalone control in
/// the chrome. It was 34x24 — a third height in a row that already had two.
fn newTabButton(ui: *TerminalUi) TerminalUi.Node {
    return tipped(ui, ui.button(.{
        .width = projection.chrome_control_extent,
        .height = projection.chrome_control_extent,
        .size = .icon,
        .variant = .ghost,
        .icon = "plus",
        .on_press = .new_terminal,
        .semantics = .{ .label = "New terminal, shortcut CMD+T" },
        // Spelled out rather than ⌘: the bundled face is a terminal font, and
        // the toolkit's own coverage guard names ⌘ as one of the codepoints
        // that renders as a tofu box on the reference and mobile paths.
    }, ""), "New Terminal (Cmd+T)");
}

/// Which end of the strip a cue speaks for.
const TabOverflowSide = enum { before, after };

/// The EDGE CUE: what a windowed strip says about the tabs it is not drawing.
///
/// Until this existed the strip drew its contiguous run and stopped, and
/// nothing anywhere said the run was a window. Measured on the real app at 4
/// terminals in a 660pt window: 4 tray items in the model, 3 `role=tab` widgets
/// in the tree, and `grep -icE 'more|overflow|chevron|scroll'` over the whole
/// published snapshot returned 0. "Terminal 1" was not faint or clipped or
/// scrolled off — it was not in the accessibility tree at all, so a screen
/// reader user could not discover it existed, and the `+` sitting immediately
/// after the last drawn tab read as the end of the list. That is this repo's
/// dominant bug class exactly: a thing that silently does nothing and says
/// nothing about it.
///
/// So the cue is three separate answers to that, not one:
///   - a chevron in the PIXELS, at the end that is hiding tabs, which is what
///     every tab bar that windows shows;
///   - the exact count in the ACCESSIBILITY NAME, so the tree carries what the
///     strip cannot draw;
///   - `palette_open` on press, because a cue that announces unreachable tabs
///     and offers no way to reach them has only moved the problem. The
///     switcher (cmd+shift+P) lists every tab and always did; what it lacked
///     was anything that told you to go looking for it.
///
/// The empty case is a HIDDEN SPACER of the same width rather than nothing.
/// `visibleTabWindowIn` reserves both ends whenever the strip windows, so a
/// collapsing slot would slide every tab sideways by 28pt the moment the
/// selection walked past the right edge and the leading cue appeared.
fn tabOverflowCue(ui: *TerminalUi, side: TabOverflowSide, hidden: usize) TerminalUi.Node {
    if (hidden == 0) return ui.el(.stack, .{
        .width = projection.tab_overflow_cue_extent,
        .semantics = .{ .hidden = true },
    }, .{});
    const where = switch (side) {
        .before => "before",
        .after => "after",
    };
    const plural = if (hidden == 1) "" else "s";
    return tipped(ui, ui.button(.{
        .width = projection.tab_overflow_cue_extent,
        .height = projection.tab_overflow_cue_extent,
        .size = .icon,
        .variant = .ghost,
        .icon = switch (side) {
            .before => "chevron-left",
            .after => "chevron-right",
        },
        .on_press = .palette_open,
        // Spelled out rather than ⌘, for the reason `newTabButton` gives.
        .semantics = .{ .label = ui.fmt(
            "{d} more tab{s} {s} this one, not shown in the strip; open the tab switcher, shortcut CMD+SHIFT+P",
            .{ hidden, plural, where },
        ) },
    }, ""), ui.fmt("{d} more tab{s} {s} (Cmd+Shift+P)", .{ hidden, plural, where }));
}

/// The spoken identity of a terminal SURFACE.
///
/// This is deliberately self-sufficient rather than leaning on the tab that
/// usually sits above it: at rest there is no band, so the surface is the only
/// thing in the tree that can tell a screen reader what this terminal is and
/// how it is doing.
fn terminalSurfaceLabel(ui: *TerminalUi, model: *const Model, id: TerminalRef) []const u8 {
    if (model.provider.terminalConst(id)) |pane| {
        const diagnostics = paneDiagnostics(ui, model, pane);
        if (pane.session.hoveredOsc8Target()) |target| {
            const identity = url_module.targetIdentity(target).?;
            if (identity.effective_authority) |authority| {
                return ui.fmt("{s}; link target {s}; effective authority {s}", .{ diagnostics, target, authority });
            }
            return ui.fmt("{s}; link target {s}; mismatched non-HTTP targets remain disabled", .{ diagnostics, target });
        }
        return diagnostics;
    }
    const phase = if (model.remotePresentation(id)) |presentation|
        remoteLifecycleText(presentation.phase)
    else
        "UNAVAILABLE";
    return ui.fmt("{s}, phux terminal, {s}", .{ terminalTitle(ui, model, id), phase });
}

/// Paint the allowlisted OSC 8 href over the bottom of its pane without
/// changing the pane rect, grid rect, widget tree, or PTY dimensions.
fn authorityPreviewText(builder: *canvas.Builder, tokens: canvas.DesignTokens, authority: []const u8, width: f32) !?[]const u8 {
    var canonical_buf: [url_module.max_url_bytes]u8 = undefined;
    for (authority, 0..) |byte, index| canonical_buf[index] = std.ascii.toLower(byte);
    const canonical = canonical_buf[0..authority.len];
    const text_size = tokens.typography.label_size;
    if (canvas.measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, canonical, text_size) <= width) {
        return try builder.allocTextBytes(canonical);
    }
    const marker = "...";
    if (canvas.measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, marker ++ "x", text_size) > width) return null;

    var start = canonical.len;
    while (start > 0) {
        start -= 1;
        const candidate_width = canvas.measureTextWidthForFont(
            tokens.text_measure,
            tokens.typography.font_id,
            canonical[start..],
            text_size,
        );
        const marker_width = canvas.measureTextWidthForFont(tokens.text_measure, tokens.typography.font_id, marker, text_size);
        if (candidate_width + marker_width > width) {
            start += 1;
            break;
        }
    }
    var staged: [url_module.max_url_bytes]u8 = undefined;
    @memcpy(staged[0..marker.len], marker);
    @memcpy(staged[marker.len..][0 .. canonical.len - start], canonical[start..]);
    return try builder.allocTextBytes(staged[0 .. marker.len + canonical.len - start]);
}

fn paintLinkTargetPreview(
    pane: *const Pane,
    pane_index: usize,
    rect: geometry.RectF,
    tokens: canvas.DesignTokens,
    builder: *canvas.Builder,
    target: []const u8,
) !void {
    const identity = url_module.targetIdentity(target) orelse return;
    // Non-authority schemes are still announced, but a URL-shaped mismatch
    // remains conservative because there is no HTTP authority to isolate.
    const authority = identity.effective_authority orelse return;
    const inset = projection.chrome_band_inset;
    const height = projection.chrome_band_height;
    const frame = geometry.RectF.init(
        rect.x + inset,
        rect.y + @max(0, rect.height - height - inset),
        @max(0, rect.width - inset * 2),
        @min(height, rect.height),
    );
    if (frame.width <= 0 or frame.height <= 0) return;
    const text_width = @max(0, frame.width - inset * 2);
    const authority_text = try authorityPreviewText(builder, tokens, authority, text_width) orelse return;

    try builder.fillRect(.{
        .id = link_preview_ground_command_id_base + pane_index,
        .rect = frame,
        .fill = .{ .color = tokens.colors.surface },
    });
    const text_size = tokens.typography.label_size;
    const line_height = frame.height / 2;
    try builder.drawText(.{
        .id = link_preview_authority_command_id_base + pane_index,
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = geometry.PointF.init(
            frame.x + inset,
            frame.y + (line_height + text_size * 0.7) * 0.5,
        ),
        .color = tokens.colors.accent,
        .text = authority_text,
        .text_layout = .{
            .max_width = text_width,
            .line_height = line_height,
            .wrap = .none,
            .overflow = .clip,
            .measure = tokens.text_measure,
        },
    });
    try builder.drawText(.{
        .id = link_preview_text_command_id_base + pane_index,
        .font_id = tokens.typography.font_id,
        .size = text_size,
        .origin = geometry.PointF.init(
            frame.x + inset,
            frame.y + line_height + (line_height + text_size * 0.7) * 0.5,
        ),
        .color = tokens.colors.text,
        .text = target,
        .text_layout = .{
            .max_width = text_width,
            .line_height = line_height,
            .wrap = .none,
            .measure = tokens.text_measure,
        },
    });
    // Receipt is written only after every command needed to identify the
    // destination made it into the display list.
    pane.session.markOsc8PreviewRendered(target);
}

/// A single pane's interaction surface. No pane header: Ghostty has none,
/// and the 24pt `TERMINAL 2 / PHUX / RUNNING` strip cost every split pane a
/// row of grid for information the tab strip already carries.
fn terminalSurface(ui: *TerminalUi, model: *const Model, ws: *const Workspace, node: layout.NodeId, terminal_ref: TerminalRef, rect: geometry.RectF) TerminalUi.Node {
    const pane = model.provider.terminalConst(terminal_ref);
    const screen = if (pane) |local|
        local.session.screenText()
    else if (model.remotePresentation(terminal_ref)) |presentation|
        presentation.grid.screen_text
    else
        "";
    const local_id = provider_contract.localId(terminal_ref);
    if (pane == null or local_id == null) {
        return ui.el(.stack, .{
            .global_key = .{ .index = terminalPaintIndex(model, terminal_ref) },
            .grow = 1,
            .min_width = split_pane_min_width,
            .height = rect.height,
            .opacity = 0,
            .text = screen,
            .on_press = .{ .focus_pane = node },
            .semantics = .{
                .focusable = true,
                .label = terminalSurfaceLabel(ui, model, terminal_ref),
            },
        }, .{});
    }
    const local_pane = pane.?;
    const context_menu = [_]TerminalUi.ContextMenuItem{
        .{ .label = "Copy", .msg = .{ .copy_terminal = local_pane.id }, .enabled = local_pane.session.selectionActive() },
        .{ .label = "Paste", .msg = .{ .paste_terminal = local_pane.id }, .enabled = local_pane.acceptsInput() },
    };
    // One unbound terminal contributes native interaction and semantics over
    // the app-owned libghostty painter. pty=0 prevents SDK session input;
    // opacity=0 prevents duplicate pixels. Policy disabled keeps a live TUI's
    // secondary stream routed; automatic lets the declared local menu win.
    const surface = ui.terminal(.{
        .global_key = .{ .index = @intCast(@intFromEnum(local_id.?)) },
        .grow = 1,
        .min_width = split_pane_min_width,
        .height = rect.height,
        .opacity = 0,
        .text = screen,
        .on_press = .{ .focus_pane = node },
        .context_menu = &context_menu,
        .context_menu_policy = if (paneReportsMouse(local_pane)) .disabled else .automatic,
        .semantics = .{
            .focusable = true,
            .label = terminalSurfaceLabel(ui, model, local_pane.id),
        },
    });

    // A dead pane you are NOT focused on had no signal at all: the band's
    // Restart is scoped to the focused pane, so a shell that died while you
    // were in the split next to it just stopped, silently, until you cycled
    // into it. The overlay is deliberately only for the UNFOCUSED case — the
    // focused pane already has the band, and two Restart buttons for one
    // terminal is worse than one in the wrong place.
    const focused_node = if (ws.selectedTreeConst()) |current| current.focus else layout.none;
    if (node == focused_node or !paneLifecycleFailed(local_pane)) return surface;
    return ui.el(.stack, .{
        .grow = 1,
        .min_width = split_pane_min_width,
        .height = rect.height,
    }, .{
        surface,
        ui.column(.{ .grow = 1, .main = .center, .cross = .center, .gap = projection.chrome_gap }, .{
            ui.el(.badge, .{
                .variant = .destructive,
                .text = paneLifecycleText(ui, local_pane),
                .semantics = .{ .label = paneDiagnostics(ui, model, local_pane) },
            }, .{}),
            ui.button(.{
                .size = .sm,
                .variant = .secondary,
                .on_press = .{ .restart = local_pane.id },
                .semantics = .{ .label = ui.fmt("Restart {s}", .{terminalTitle(ui, model, local_pane.id)}) },
            }, "Restart"),
        }),
    });
}

/// The widget tree for a subtree, laid out on EXACTLY the rects
/// `layout.splitRect` resolves — the same primitive `resolvePanes` walks.
///
/// A horizontal branch becomes an SDK `.split`, whose own fraction clamp is
/// the same formula (`splitFractionBounds` == `layout.effectiveFraction` for
/// equal minimums), so it keeps a real draggable divider. A vertical branch
/// becomes a column with explicit child heights, because the SDK's splitter
/// is horizontal-only.
fn paneSubtree(ui: *TerminalUi, model: *const Model, ws: *const Workspace, node: layout.NodeId, rect: geometry.RectF) TerminalUi.Node {
    const current = ws.selectedTreeConst() orelse return emptyStatusNode(ui);
    const entry = current.node(node);
    switch (entry.kind) {
        .free => return emptyStatusNode(ui),
        .leaf => {
            const terminal_ref = entry.terminal orelse return emptyStatusNode(ui);
            return terminalSurface(ui, model, ws, node, terminal_ref, rect);
        },
        .branch => {
            const halves = layout.splitRect(
                rect,
                entry.orientation,
                entry.fraction,
                split_divider_width,
                split_pane_min_width,
                split_pane_min_height,
            );
            const first = paneSubtree(ui, model, ws, entry.first, halves[0]);
            const second = paneSubtree(ui, model, ws, entry.second, halves[1]);
            return switch (entry.orientation) {
                .horizontal => ui.split(.{
                    .grow = 1,
                    .height = rect.height,
                    .gap = split_divider_width,
                    .value = entry.fraction,
                    .on_resize = split_resize_handlers[node],
                    .semantics = .{ .label = "Terminal split" },
                }, .{ first, second }),
                .vertical => ui.column(.{
                    .grow = 1,
                    .height = rect.height,
                    .gap = split_divider_width,
                }, .{ first, second }),
            };
        },
    }
}

/// What the field shows before anything is typed. Deliberately not "No
/// matches": a field with nothing in it has not searched for anything yet,
/// and reporting a failure the user did not cause is worse than saying
/// nothing.
const search_placeholder = "Search scrollback";

/// The scrollback-search band for the focused terminal.
///
/// The needle is drawn rather than hosted in a text-entry widget on purpose.
/// The app routes every canvas key itself (`update.handleKey`), and the one
/// requirement that matters here is that a keystroke aimed at the field can
/// never reach the child — which is a property of that routing, not of which
/// widget happens to hold canvas focus. Drawing the field keeps the two in
/// one place; the caret below is what tells the user the keyboard is here.
fn searchBar(ui: *TerminalUi, model: *const Model, ws: *const Workspace, tokens: canvas.DesignTokens) TerminalUi.Node {
    const terminal_ref = projection.workspaceTerminalRef(model, ws) orelse return emptyStatusNode(ui);
    const pane = model.provider.terminalConst(terminal_ref) orelse return emptyStatusNode(ui);
    const session = pane.session;
    const needle = session.searchNeedle();
    const total = session.searchMatchCount();
    const empty = needle.len == 0;
    const missing = !empty and total == 0;
    const status = if (empty)
        ""
    else if (missing)
        "No matches"
    else
        ui.fmt("{d} of {d}", .{ session.searchMatchOrdinal(), total });

    // The band's controls are the register's SMALL rung, not a height derived
    // from the band by subtraction. `search_bar_height - 12` produced 22, which
    // is on no ladder the toolkit knows: a row reads as one height exactly when
    // every control in it declares the same size, and 22 was the reason this
    // band read as a strip of odds and ends.
    const control_extent = projection.chrome_control_extent;
    return ui.row(.{
        .height = projection.search_bar_height,
        .gap = projection.chrome_gap,
        .cross = .center,
        .padding = projection.chrome_band_inset,
        .style = .{ .background = tokens.colors.surface_subtle },
        .semantics = .{
            .label = ui.fmt("Scrollback search, {s}, {s}", .{
                if (empty) "empty" else needle,
                if (empty) "type to search" else status,
            }),
        },
    }, .{
        // Decorative, and deliberately NOT `semantics.hidden`: that flag
        // suppresses RENDERING as well as the accessibility node
        // (`widget_render.zig` returns early on it), so a "hidden from
        // assistive tech" icon is simply an icon that never paints. It stays
        // unnamed instead — the band's own label above already says
        // everything a reader needs.
        ui.icon(.{
            .width = projection.chrome_icon_extent,
            .height = projection.chrome_icon_extent,
            .style = .{ .foreground = tokens.colors.text_muted },
        }, "search"),
        ui.row(.{ .grow = 1, .gap = 1, .cross = .center }, .{
            ui.text(.{
                .wrap = false,
                .overflow = .ellipsis,
                .style = .{ .foreground = if (empty) tokens.colors.text_muted else tokens.colors.text },
            }, if (empty) search_placeholder else needle),
            // The caret. The field has no widget focus to show, so this is
            // the only thing on screen that says the keyboard is pointed at
            // the search and not at the shell — which makes it worth more
            // than a hairline. It is a BLOCK, matching the terminal's own
            // cursor two rows below: a 2pt bar was invisible against the
            // band at 1x, and an invisible focus cue is not one.
            ui.el(.stack, .{
                .width = field_caret_width,
                .height = field_caret_height,
                .style = .{ .background = tokens.colors.accent },
            }, .{}),
            ui.spacer(1),
        }),
        ui.text(.{
            .wrap = false,
            .style = .{ .foreground = if (missing) tokens.colors.warning else tokens.colors.text_muted },
        }, status),
        // Labelled by DIRECTION, not by "next"/"previous". The search lands
        // on the newest match (that is where the user already is), so the
        // useful step is backwards through the log — and a button that says
        // "next" while the screen moves UP is a button that has to be
        // learned. The menu keeps the platform's Find Next/Find Previous
        // vocabulary over the same two messages.
        tipped(ui, ui.button(.{
            .width = control_extent,
            .height = control_extent,
            .size = .icon,
            .variant = .ghost,
            .icon = "chevron-up",
            .on_press = .{ .search_step = 1 },
            .semantics = .{ .label = "Older match" },
        }, ""), "Older match (Cmd+G)"),
        tipped(ui, ui.button(.{
            .width = control_extent,
            .height = control_extent,
            .size = .icon,
            .variant = .ghost,
            .icon = "chevron-down",
            .on_press = .{ .search_step = -1 },
            .semantics = .{ .label = "Newer match" },
        }, ""), "Newer match (Cmd+Shift+G)"),
        tipped(ui, ui.button(.{
            .width = control_extent,
            .height = control_extent,
            .size = .icon,
            .variant = .ghost,
            .icon = "x",
            .on_press = .search_close,
            .semantics = .{ .label = "Close search" },
        }, ""), "Close search (Esc)"),
    });
}

/// What the config file did that the user did not ask for, said in the app.
///
/// The parser has always collected diagnostics, and until this band the only
/// place they went was the startup log — which from a bundled `.app` is the
/// unified log, i.e. nowhere. Someone who typo'd a key got a terminal that
/// quietly behaved differently and no way to find out short of Console.
///
/// Three properties, and each one is load-bearing:
///
///   1. it NAMES LINE NUMBERS. "Your config has a problem" is not actionable;
///      "line 7" is an edit. A single problem also gets its own text, because
///      one line has room for it.
///   2. it is NOT modal, and holds no chord. A benign diagnostic — an
///      `unsupported_key` for a setting this build cannot honour — must never
///      stand between someone and a prompt. The keyboard is untouched: the
///      shell has focus the whole time the band is up.
///   3. it DISMISSES ON PRESS, anywhere in the band, with an explicit `x` for
///      the people who look for one. Anywhere-presses also mean the band has a
///      hit target over every point it covers, so no press can fall through to
///      a grid that is painted underneath it.
fn configNoticeBand(ui: *TerminalUi, model: *const Model, tokens: canvas.DesignTokens) TerminalUi.Node {
    var storage: [projection.config_notice_bytes]u8 = undefined;
    // `ui.fmt` copies into the UI's own arena; this buffer dies with the frame.
    const line = ui.fmt("{s}", .{projection.configNoticeLine(model, &storage)});
    // The register, not a subtraction from the band — same reasoning as the
    // search band above, and the two bands now agree by construction rather
    // than by two sites happening to pick the same arithmetic.
    const control_extent = projection.chrome_control_extent;
    return ui.row(.{
        .height = projection.config_notice_height,
        .gap = projection.chrome_gap,
        .cross = .center,
        .padding = projection.chrome_band_inset,
        .style = .{ .background = tokens.colors.surface_subtle },
        .on_press = .config_notice_dismissed,
        .semantics = .{ .label = ui.fmt("{s}. Press to dismiss.", .{line}) },
    }, .{
        // Unnamed for the same reason the search band's icon is: `hidden`
        // suppresses RENDERING as well as the accessibility node, and the
        // row's own label above already says everything a reader needs.
        ui.icon(.{
            .width = projection.chrome_icon_extent,
            .height = projection.chrome_icon_extent,
            .style = .{ .foreground = tokens.colors.warning },
        }, "alert"),
        // Ellipsis rather than a truncation of my own: the line is bounded by
        // `config_notice_bytes` and the widget knows the width it actually got,
        // which no constant here could.
        ui.text(.{
            .grow = 1,
            .wrap = false,
            .overflow = .ellipsis,
            .style = .{ .foreground = tokens.colors.text },
        }, line),
        ui.button(.{
            .width = control_extent,
            .height = control_extent,
            .size = .icon,
            .variant = .ghost,
            .icon = "x",
            .on_press = .config_notice_dismissed,
            .semantics = .{ .label = "Dismiss the configuration notice" },
        }, ""),
    });
}

/// The summoned working-set index.
///
/// It FLOATS. Every other piece of chrome in this app takes its room out of
/// the content rect, because the painter, the hit-test tree and the PTY sizing
/// pump all derive from `workspaceChrome` and a floating band would leave the
/// three disagreeing. The palette is the one thing that must not: it is
/// transient, and taking three rows away from every terminal in the tab for as
/// long as a switcher is up — then giving them back — is exactly the SIGWINCH
/// churn this round set out to remove. So it is drawn as an overlay in a
/// `.stack` above the panes, and `workspaceChrome` never hears about it.
fn palettePanel(ui: *TerminalUi, model: *const Model, ws: *const Workspace, tokens: canvas.DesignTokens) TerminalUi.Node {
    const count = projection.paletteEntryCountIn(model, ws);
    const needle = ws.palette.needle();
    const cursor = if (count == 0) 0 else @min(ws.palette.cursor, count - 1);
    const window = projection.paletteWindowFor(count, cursor);
    var rows: [projection.palette_max_visible_rows]projection.PaletteEntry = undefined;
    const visible_count = projection.paletteEntriesWindowIn(model, ws, window, &rows);

    const max_section_labels = std.meta.fields(projection.PaletteSection).len;
    var body_nodes: [projection.palette_max_visible_rows + max_section_labels]TerminalUi.Node = undefined;
    var node_count: usize = 0;
    var last_section: ?projection.PaletteSection = null;

    for (rows[0..visible_count], 0..) |entry, offset| {
        const highlighted = window.first + offset == cursor;
        const row = paletteRowFor(ui, model, entry, highlighted) orelse continue;
        const section = projection.paletteSection(entry);
        if (paletteSectionChanged(last_section, section)) {
            body_nodes[node_count] = paletteSectionNode(ui, section, tokens);
            node_count += 1;
            last_section = section;
        }

        body_nodes[node_count] = paletteSelectableNode(ui, model, row, highlighted, tokens);
        node_count += 1;
    }

    const body = if (count == 0)
        ui.el(.stack, .{ .height = palette_row_height, .padding = projection.chrome_gap }, .{
            ui.text(.{ .style = .{ .foreground = tokens.colors.warning } }, "No destination matches"),
        })
    else
        ui.list(.{
            .gap = projection.chrome_band_inset,
            .semantics = .{ .label = "Working set destinations" },
        }, body_nodes[0..node_count]);

    return ui.column(.{
        .width = palette_width,
        .gap = projection.chrome_band_inset,
        .padding = palette_padding,
        .style = .{ .background = tokens.colors.surface },
        .semantics = .{
            .label = ui.fmt("Working set, {s}, {d} matching", .{
                if (needle.len == 0) "type to filter" else needle,
                count,
            }),
        },
    }, .{
        // The needle is drawn rather than hosted: the app routes every key, so
        // no keystroke aimed here can leak into a shell.
        paletteSearchField(ui, needle, tokens),
        body,
    });
}

/// A canvas colour written the way a config file spells it, so what the panel
/// reports can be pasted straight back into `~/.config/phux-cockpit/config`.
/// Rounded rather than truncated: 0xf4/255 * 255 is not exactly 244 in f32,
/// and a readout that says `#f3f6fa` for a colour written `#f4f7fb` would send
/// somebody hunting for a bug that is not there.
fn colorHex(ui: *TerminalUi, color: canvas.Color) []const u8 {
    return ui.fmt("#{x:0>2}{x:0>2}{x:0>2}", .{
        channelByte(color.r),
        channelByte(color.g),
        channelByte(color.b),
    });
}

fn channelByte(channel: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(channel * 255), 0, 255));
}

/// THE LEGIBILITY READOUT: what the terminal's own text-on-ground contrast
/// currently is, in a panel that is guaranteed to be readable while it says so.
///
/// This is the instrument `phux-cockpit-aht` needed and did not have. Four
/// rounds went into "the text is see-through or black or something" and every
/// one of them was an agent measuring pixels, because nothing in the running
/// app could answer the question. It reads `projection.legibility`, which
/// derives from the SAME `DesignTokens` the painter is about to paint the
/// grid with — not from the config, not from the theme table — so it cannot
/// report a colour the screen is not actually showing.
fn legibilityReadout(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    const reading = projection.legibility(model);
    const verdict_color = if (reading.readable()) settings_pass else settings_fail;
    const verdict = switch (reading.grade) {
        .fails_aa => "BELOW AA - needs 4.5:1 for body text",
        .passes_aa => "passes WCAG AA (4.5:1)",
        .passes_aaa => "passes WCAG AAA (7:1)",
    };
    return ui.row(.{
        .width = settings_row_width,
        // One BAND tall, which is what this row is: a readout, not a list row.
        .height = projection.chrome_band_height,
        .gap = projection.chrome_gap,
        .cross = .center,
        .padding = projection.chrome_band_inset,
        .style = .{ .background = settings_ground_raised },
        .semantics = .{ .label = ui.fmt(
            "Legibility: foreground {s} on background {s}, contrast ratio {d:.2} to 1, {s}",
            .{ colorHex(ui, reading.foreground), colorHex(ui, reading.background), reading.ratio, verdict },
        ) },
    }, .{
        // A LIVE SAMPLE, painted with the terminal's actual pair. The panel
        // around it stays legible by construction, so this swatch is the one
        // place on screen where "what does my text look like" is answerable by
        // looking rather than by squinting at a whole screen of it.
        ui.el(.stack, .{
            .width = 48,
            .height = 24,
            .style = .{ .background = reading.background },
        }, .{
            ui.row(.{ .grow = 1, .main = .center, .cross = .center }, .{
                ui.text(.{
                    .wrap = false,
                    .style = .{ .foreground = reading.foreground },
                    .semantics = .{ .label = settings_sample_label },
                }, "Aa"),
            }),
        }),
        ui.column(.{ .grow = 1, .gap = 2 }, .{
            ui.text(.{
                .wrap = false,
                .style = .{ .foreground = verdict_color },
            }, ui.fmt("{d:.2}:1  {s}", .{ reading.ratio, verdict })),
            ui.text(.{
                .wrap = false,
                .overflow = .ellipsis,
                .style = .{ .foreground = settings_ink_muted },
            }, ui.fmt("text {s} on {s}", .{
                colorHex(ui, reading.foreground),
                colorHex(ui, reading.background),
            })),
        }),
    });
}

/// A hairline between the panel's sections.
///
/// Deliberately carries NO `semantics.hidden`. That flag suppresses RENDERING
/// as well as the accessibility node (`widget_render.zig` returns early on it),
/// so a "hidden from assistive tech" rule is simply a rule that never paints —
/// the same trap the search band's icon comment records. It stays unnamed
/// instead, which is what a decoration should be.
fn settingsRule(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.stack, .{
        .width = settings_row_width,
        .height = 1,
        .style = .{ .background = settings_border },
    }, .{});
}

/// One theme row: its name, its one-line summary, and the contrast it would
/// produce. The ratio is shown per row so the choice can be made on evidence
/// rather than on the name — which is the difference between a theme picker
/// and this.
fn settingsThemeRow(ui: *TerminalUi, index: usize, highlighted: bool, active: bool) TerminalUi.Node {
    const entry = &theme_module.builtins[index];
    const ratio = theme_module.contrastRatio(entry.foreground, entry.background);
    return ui.el(.list_item, .{
        .width = settings_row_width,
        .height = settings_row_height,
        .selected = highlighted,
        .on_press = .{ .settings_select = @intCast(index) },
        .style = .{ .background = if (highlighted) settings_ground_raised else settings_ground },
        .semantics = .{
            .role = .tab,
            .label = ui.fmt("{s}: {s}; contrast {d:.2} to 1{s}{s}", .{
                entry.name,
                entry.summary,
                ratio,
                if (active) ", in effect" else "",
                if (highlighted) ", highlighted" else "",
            }),
        },
    }, .{
        ui.row(.{ .width = settings_row_width, .height = settings_row_height, .gap = projection.chrome_gap, .cross = .center, .padding = projection.chrome_gap }, .{
            // The theme's own pair, as a swatch. Two colours are faster to
            // compare than two hex strings.
            ui.el(.stack, .{
                .width = 24,
                .height = 16,
                .style = .{ .background = canvas.Color.rgb8(entry.background.r, entry.background.g, entry.background.b) },
            }, .{
                ui.row(.{ .grow = 1, .main = .center, .cross = .center }, .{
                    ui.text(.{
                        .wrap = false,
                        .style = .{ .foreground = canvas.Color.rgb8(entry.foreground.r, entry.foreground.g, entry.foreground.b) },
                        // NAMED as a sample, which is what lets the panel's own
                        // legibility invariant be checked: this is the one text
                        // in the tree deliberately painted in colours that may
                        // be unreadable, because showing them is the job.
                        .semantics = .{ .label = settings_sample_label },
                    }, "A"),
                }),
            }),
            ui.text(.{
                .wrap = false,
                .style = .{ .foreground = if (highlighted) settings_ink else settings_ink_muted },
            }, entry.name),
            ui.text(.{
                .grow = 1,
                .wrap = false,
                .overflow = .ellipsis,
                .style = .{ .foreground = settings_ink_muted },
            }, entry.summary),
            ui.text(.{
                .wrap = false,
                .style = .{ .foreground = if (ratio >= theme_module.wcag_aa_body_text) settings_pass else settings_fail },
            }, ui.fmt("{d:.1}:1", .{ratio})),
        }),
    });
}

/// Read-only startup provenance, fitted into the existing Configuration
/// heading row so the minimum-height panel does not grow. This is disclosure,
/// not an editor: changing coordinator/session remains config-file territory.
fn settingsPhuxTransport(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    const socket = model.config.phux_socket.slice();
    const location = if (socket.len == 0) "not resolved" else socket;
    const selected = model.config.phux_session.slice();
    const session = if (selected.len == 0) "current/Last" else selected;
    return ui.text(.{
        .grow = 1,
        .wrap = false,
        .overflow = .ellipsis,
        .style = .{ .foreground = settings_ink_muted },
        .semantics = .{ .label = ui.fmt(
            "{s}: {s}; source: {s}. Session: {s}; source: {s}.",
            .{
                settings_phux_transport_label,
                location,
                model.config.phux_socket_source.label(),
                session,
                model.config.phux_session_source.label(),
            },
        ) },
    }, ui.fmt("Phux {s} [{s}] · session {s} [{s}]", .{
        location,
        model.config.phux_socket_source.label(),
        session,
        model.config.phux_session_source.label(),
    }));
}

/// The in-app settings surface.
///
/// It FLOATS, for the same reason the palette does: it is transient, and taking
/// rows away from every terminal in the tab while it is up — then giving them
/// back — is a SIGWINCH per pane per open. See the comment on `palettePanel`.
///
/// Every colour in here is a literal from the `settings_*` block above rather
/// than a token. That is the whole point of the surface and the reasoning is
/// written down at the constants.
fn settingsPanel(ui: *TerminalUi, model: *const Model, ws: *const Workspace) TerminalUi.Node {
    const count = theme_module.builtins.len;
    const cursor = @min(ws.settings.cursor, count - 1);
    const active_name = model.config.theme.slice();

    var rows: [theme_module.builtins.len]TerminalUi.Node = undefined;
    for (0..count) |index| {
        rows[index] = settingsThemeRow(
            ui,
            index,
            index == cursor,
            std.ascii.eqlIgnoreCase(theme_module.builtins[index].name, active_name),
        );
    }
    // An explicit slice: `rows[0..count]` with a comptime-known `count` is a
    // pointer-to-array, and `Ui.el` takes a Node, a `[]const Node`, or a tuple.
    const row_slice: []const TerminalUi.Node = &rows;

    return ui.column(.{
        .width = settings_width,
        .gap = projection.chrome_gap,
        .padding = settings_padding,
        .style = .{ .background = settings_ground },
        .semantics = .{ .label = settings_panel_label },
    }, .{
        ui.row(.{ .width = settings_row_width, .gap = projection.chrome_gap, .cross = .center }, .{
            ui.text(.{ .wrap = false, .style = .{ .foreground = settings_ink } }, "Settings"),
            ui.spacer(1),
            ui.text(.{
                .wrap = false,
                .style = .{ .foreground = settings_ink_muted },
            }, "up/down preview   return save   esc cancel"),
        }),
        settingsRule(ui),
        legibilityReadout(ui, model),
        settingsRule(ui),
        // Gap ZERO, not one. The theme rows are a table read down a column,
        // and the highlight is what separates them; a one-point gutter is
        // neither a gap nor a rule, and it is the only spacing value in this
        // panel that was on no scale at all.
        ui.list(.{ .gap = 0, .semantics = .{ .label = "Themes" } }, row_slice),
        settingsRule(ui),
        ui.row(.{ .width = settings_row_width, .gap = projection.chrome_gap, .cross = .center }, .{
            ui.text(.{ .wrap = false, .style = .{ .foreground = settings_ink } }, "Configuration"),
            if (support.phux_enabled) settingsPhuxTransport(ui, model) else ui.spacer(1),
            if (ws.settings.config_exists)
                settingsAction(ui, "Show in Finder", .settings_reveal_config, false)
            else
                ui.el(.stack, .{ .width = 88, .height = projection.chrome_control_extent, .semantics = .{ .hidden = true } }, .{}),
        }),
        ui.text(.{
            .wrap = false,
            .overflow = .ellipsis,
            .style = .{ .foreground = if (model.config_file.enabled() and !ws.settings.config_writable)
                settings_fail
            else
                settings_ink_muted },
            .semantics = .{ .label = if (model.config_file.enabled())
                ui.fmt("Active configuration file: {s}", .{model.config_file.path()})
            else
                "No configuration file location could be resolved" },
        }, if (!model.config_file.enabled())
            "No config location could be resolved; changes apply to this run only."
        else if (!ws.settings.config_writable)
            ui.fmt("{s} is read-only; changes apply to this run only.", .{model.config_file.path()})
        else if (!ws.settings.config_exists)
            ui.fmt("{s} will be created when you save.", .{model.config_file.path()})
        else
            model.config_file.path()),
        // A pointer path to both verbs. The panel is keyboard-first, but a
        // surface reachable only by keys is one a pointer user cannot finish.
        ui.row(.{ .width = settings_row_width, .gap = projection.chrome_gap, .cross = .center }, .{
            ui.spacer(1),
            settingsAction(ui, "Cancel", .settings_close, false),
            settingsAction(ui, "Save", .settings_commit, true),
        }),
    });
}

/// A footer verb. Built from a `.stack` with explicit colours rather than from
/// `ui.button`, because the register's button variants take their fill and
/// their label colour from the DESIGN TOKENS — which is the one thing nothing
/// on this panel is allowed to do.
fn settingsAction(ui: *TerminalUi, label: []const u8, msg: Msg, emphasis: bool) TerminalUi.Node {
    return ui.el(.stack, .{
        .width = 88,
        // The small register, like every other standalone control in the
        // chrome. 26 was on no ladder, and a footer verb below the pointer
        // floor is the last place to save four points.
        .height = projection.chrome_control_extent,
        .on_press = msg,
        .style = .{ .background = if (emphasis) settings_ground_raised else settings_ground },
        .semantics = .{ .role = .button, .label = label },
    }, .{
        ui.row(.{ .grow = 1, .main = .center, .cross = .center }, .{
            ui.text(.{
                .wrap = false,
                .style = .{ .foreground = if (emphasis) settings_ink else settings_ink_muted },
            }, label),
        }),
    });
}

/// What a cmd+N at the window ceiling says.
///
/// It says something on purpose. The toolkit budgets four declared windows on
/// top of the scene's own, so the fifth cmd+N has nowhere to go — and a chord
/// that quietly does nothing reads as a chord that is not bound, which is the
/// worse of the two failures. The band reveals itself to carry this (see
/// `chromeRevealedIn`), so the message is visible even in the at-rest chrome
/// the app normally hides.
fn windowLimitNotice(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.badge, .{
        .variant = .destructive,
        .text = ui.fmt("{d} WINDOW LIMIT", .{model_module.max_windows}),
        .semantics = .{ .label = ui.fmt(
            "Window limit reached: {d} windows is the maximum this app can open",
            .{model_module.max_windows},
        ) },
    }, .{});
}

/// What a cmd+T at the active workspace's tab ceiling says.
fn tabLimitNotice(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.badge, .{
        .variant = .destructive,
        .text = ui.fmt("{d} TAB LIMIT", .{max_tabs}),
        .semantics = .{ .label = ui.fmt(
            "Tab limit reached: {d} tabs is the maximum one window can open; close one to open another",
            .{max_tabs},
        ) },
    }, .{});
}

/// What a cmd+T or cmd+D at the SHELL ceiling says.
///
/// The window notice above exists because a chord that quietly does nothing
/// reads as a chord that is not bound. This one exists because the failure it
/// replaces was louder and worse: the chord USED to work, opening a tab or
/// dividing a pane, and then left a grid that stayed blank forever because the
/// effects layer had refused its spawn (phux-cockpit-pg1). A refusal you can
/// read beats a tab that lies about being a terminal.
fn terminalLimitNotice(ui: *TerminalUi) TerminalUi.Node {
    return ui.el(.badge, .{
        .variant = .destructive,
        .text = ui.fmt("{d} SHELL LIMIT", .{local_terminal.max_live_shells}),
        .semantics = .{ .label = ui.fmt(
            "Shell limit reached: {d} running terminals is the maximum this app can spawn; close one to open another",
            .{local_terminal.max_live_shells},
        ) },
    }, .{});
}

/// What a settings commit the config file refused says.
///
/// The third of these, and the one whose silent version was worst. A refused
/// cmd+N does nothing, which at least matches what the user sees; a refused
/// SAVE applies the theme, closes the panel and looks exactly like the save
/// that worked. Nothing was wrong until the next launch, where the old theme
/// came back with no explanation available anywhere in the app.
///
/// The badge is short because the band is one row; the SPOKEN label carries
/// the path, because "which file" is the first thing anybody asks and the
/// panel that named it has already closed.
fn configWriteNotice(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    return ui.el(.badge, .{
        .variant = .destructive,
        .text = "THEME NOT SAVED",
        .semantics = .{ .label = ui.fmt(
            "Theme could not be saved: {s} could not be written, so this theme applies to this run only",
            .{model.config_file.path()},
        ) },
    }, .{});
}

/// A state file that exists but cannot be restored remains untouched. This is
/// deliberately a calm, persistent status rather than a modal error: the fresh
/// terminal is usable, while the spoken label names the preserved source and
/// the launch-scoped persistence boundary.
fn topologyRestoreNotice(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    return ui.el(.badge, .{
        .variant = .secondary,
        .text = "LAYOUT NOT RESTORED",
        .semantics = .{ .label = ui.fmt(
            "Workspace layout was not restored from {s}. The file was preserved, and layout saving is disabled for this launch.",
            .{model.state.path()},
        ) },
    }, .{});
}

/// What an exhausted workspace-state write says. It shares the existing save
/// notice slot: both are destructive badges about a file that did not land.
fn topologyWriteNotice(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    return ui.el(.badge, .{
        .variant = .destructive,
        .text = "LAYOUT UNSAVED",
        .semantics = .{ .label = ui.fmt(
            "Workspace layout could not be saved: {s} could not be written; changes may be lost if the app exits unexpectedly",
            .{model.state.path()},
        ) },
    }, .{});
}
/// A Phux-enabled launch stays useful when no server session can be attached,
/// but the local shell is ephemeral. Keep that authority boundary visible
/// instead of silently presenting the fallback as durable work.
fn phuxUnavailableNotice(ui: *TerminalUi) TerminalUi.Node {
    return ui.row(.{ .gap = projection.chrome_gap, .cross = .center }, .{
        ui.el(.badge, .{
            .variant = .destructive,
            .text = "PHUX OFFLINE",
            .semantics = .{ .label = "No Phux session is attached. This local terminal ends with Cockpit." },
        }, .{}),
        ui.button(.{
            .size = .sm,
            .variant = .secondary,
            .on_press = .phux_reconnect,
            .semantics = .{ .label = "Retry attaching the running Phux server" },
        }, "Retry"),
    });
}

/// KEEP IN STEP with `projection.tabStripStatusReserveIn`, which decides how
/// much room the tab run gives up for this node. Immediate gesture refusals
/// outrank persistent file notices; each lower status gets the row back when
/// the higher one clears.
fn trailingStatus(
    ui: *TerminalUi,
    model: *const Model,
    ws: *const Workspace,
    focused_ref: ?TerminalRef,
) TerminalUi.Node {
    if (model.window_limit_refused) return windowLimitNotice(ui);
    if (ws.tab_limit_refused) return tabLimitNotice(ui);
    if (model.terminal_limit_refused) return terminalLimitNotice(ui);
    if (model.state.rejectedExisting()) return topologyRestoreNotice(ui, model);
    if (model.config_write_refused) return configWriteNotice(ui, model);
    if (model.state.write_failed) return topologyWriteNotice(ui, model);
    if (model.phux_connection_unavailable) return phuxUnavailableNotice(ui);
    if (focused_ref) |id| return paneStatus(ui, model, id);
    return emptyStatusNode(ui);
}

fn parkedWebKitAnchor(ui: *TerminalUi) TerminalUi.Node {
    return ui.panel(.{
        .width = webkit_parking_extent,
        .height = webkit_parking_extent,
        .opacity = 0,
        .semantics = .{ .label = webview_anchor, .hidden = true },
    }, .{});
}

/// The MAIN window's tree. Window 0 by construction: the scene declares
/// exactly one canvas and the runtime builds it through `Options.view`.
pub fn view(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    return viewWindow(ui, model, 0);
}

/// A DECLARED secondary window's tree, keyed by its window label.
///
/// An unknown label cannot happen (the runtime only builds windows the model
/// declared) but falls back to window 0's tree rather than to an empty node:
/// a window that renders nothing is indistinguishable from a broken one.
pub fn windowView(ui: *TerminalUi, model: *const Model, window_label: []const u8) TerminalUi.Node {
    return viewWindow(ui, model, scene_module.windowIndexForWindow(window_label) orelse 0);
}

/// ONE window's widget tree. Every function below it takes the workspace it is
/// drawing rather than reading the active one, which is what makes two windows
/// with different tabs, splits, and search state render side by side.
pub fn viewWindow(ui: *TerminalUi, model: *const Model, window_index: usize) TerminalUi.Node {
    const tokens = cockpitTokens(model);
    const ws = model.wsAtConst(window_index) orelse return ui.el(.stack, .{ .grow = 1 }, .{});
    const is_main = window_index == 0;
    // A REAL slice, not a fixed tuple: tabs 9..16 used to exist in the model
    // and simply not be drawn, which is not a tab strip, it is a window into
    // one. `Ui.el` copies the slice into its own arena, so a stack array is
    // the right storage here.
    //
    // The top strip draws a derived window that always contains the selected
    // tab; the side rail is a vertical list and draws every tab.
    //
    // A windowed strip carries a cue at each end (`tabOverflowCue`), so the
    // array is two wider than the tab ceiling. They are part of the SLICE
    // rather than siblings of it in the row's tuple because a windowed strip
    // and a complete one need a different number of children, and a row child
    // that collapses to zero width still costs the row its gap.
    const window = projection.visibleTabWindowIn(model, ws, ws.surface_size.width - windowPadding(model) * 2);
    var strip_nodes: [max_tabs + 2]TerminalUi.Node = undefined;
    var rail_nodes: [max_tabs]TerminalUi.Node = undefined;
    var strip_written: usize = 0;
    var rail_written: usize = 0;
    if (model.tab_placement == .top) {
        if (window.windowed()) {
            strip_nodes[strip_written] = tabOverflowCue(ui, .before, window.hiddenBefore());
            strip_written += 1;
        }
        for (0..window.count) |offset| {
            strip_nodes[strip_written] = terminalTabTrigger(ui, model, ws, window.first + offset, tokens, window.extent);
            strip_written += 1;
        }
        if (window.windowed()) {
            strip_nodes[strip_written] = tabOverflowCue(ui, .after, window.hiddenAfter());
            strip_written += 1;
        }
    } else {
        for (0..ws.tab_count) |index| {
            rail_nodes[index] = terminalRailTrigger(ui, model, ws, index, tokens);
            rail_written += 1;
        }
    }
    const strip_slice = strip_nodes[0..strip_written];
    const rail_slice = rail_nodes[0..rail_written];

    const chrome = projection.workspaceChromeIn(model, ws, ws.surface_size);
    const focused_ref = projection.workspaceTerminalRef(model, ws);
    const status = trailingStatus(ui, model, ws, focused_ref);

    const revealed = projection.chromeRevealedIn(model, ws);
    // The strip is TERMINALS ONLY. The web surface kept its pane, its scene
    // wiring and its reload token; what it lost is a permanent seat in a
    // terminal's tab bar, where it was pinned last regardless of how many
    // terminals were open. It is cmd+shift+B and View > Web Surface now.
    //
    // A horizontal scroller carries the strip so tab 16 is reachable by
    // scrolling rather than only by cycling, and the runtime reveals the
    // selected tab when it scrolls out of view.
    const tab_strip = ui.row(.{
        .grow = 1,
        .height = tab_height,
        // `spacing.xs`. Two points was a gutter you cannot see and cannot land
        // on a device pixel column at 1x; four reads as a seam between tabs.
        .gap = projection.chrome_band_inset,
        .cross = .center,
        .semantics = .{ .label = "Terminal tabs" },
    }, .{
        strip_slice,
        newTabButton(ui),
        ui.spacer(1),
    });

    // Where the strip lives when the placement is `top`. Riding the titlebar
    // costs no content height at all; the separate band below it is the
    // fallback for a window the platform gave no titlebar (fullscreen).
    const rides_titlebar = projection.tabsRideTitlebarIn(model, ws);
    const show_top_strip = revealed and model.tab_placement == .top;

    const top_header = if (show_top_strip and !rides_titlebar) ui.row(.{ .height = header_height, .gap = projection.chrome_gap, .cross = .center, .window_drag = true }, .{
        tab_strip,
        status,
    })
        // At rest there is no band at all. Every control it carried stays
        // reachable: New is cmd+T, Close cmd+W, Split cmd+D, and the surfaces
        // are cmd+1..cmd+N — the band is presentation, never the only path.
        else ui.el(.stack, .{ .height = 0, .semantics = .{ .hidden = true } }, .{});

    // The WebKit surface is a scene-declared view of the MAIN window, so only
    // the main window's tree carries its anchor. A secondary window paints its
    // panes and nothing else — the alternative, an anchor in every window,
    // would have the last window rebuilt win the argument about where the one
    // webview lives.
    const content = if (ws.selectedTreeConst()) |current| blk: {
        const panes = paneSubtree(ui, model, ws, current.root, chrome.content);
        if (!is_main) break :blk panes;
        // Parking the webview at a one-point anchor preserves its native
        // page state without allowing it to cover or receive input over a
        // terminal tab.
        break :blk ui.el(.stack, .{ .grow = 1 }, .{
            panes,
            parkedWebKitAnchor(ui),
        });
    } else if (is_main) ui.panel(.{
        .grow = 1,
        .semantics = .{ .label = webview_anchor },
    }, .{}) else ui.el(.stack, .{ .grow = 1 }, .{});

    const side_rail_content = ui.column(.{ .width = side_rail_width, .gap = projection.chrome_gap }, .{
        ui.list(.{ .width = side_rail_width, .gap = projection.chrome_band_inset, .semantics = .{ .label = "Terminal tabs" } }, rail_slice),
        newTabButton(ui),
        ui.spacer(1),
        status,
    });
    const side_rail = if (revealed and model.tab_placement == .side)
        ui.scroll(.{
            .width = side_rail_width,
            .grow = 1,
            .semantics = .{ .label = "Workspace controls" },
        }, side_rail_content)
    else
        ui.el(.stack, .{ .width = 0, .semantics = .{ .hidden = true } }, .{});

    // The search band sits above the content in BOTH placements, and the
    // wrapper only exists while a search does: an unconditional column would
    // change the widget tree of every frame that has no search in it.
    const searched = if (projection.searchRevealedIn(model, ws))
        ui.column(.{ .grow = 1 }, .{ searchBar(ui, model, ws, tokens), content })
    else
        content;

    // The config band above both, matching `workspaceChromeIn`'s stacking. It
    // is drawn in EVERY open window on purpose: the config is the app's, so a
    // notice that only reached the window that happened to be in front would
    // be a notice the user can miss by looking at the other one. Dismissing it
    // anywhere clears it everywhere, because the latch is on the model.
    const body = if (projection.configNoticeRevealed(model))
        ui.column(.{ .grow = 1 }, .{ configNoticeBand(ui, model, tokens), searched })
    else
        searched;

    const laid_out = if (revealed and model.tab_placement == .side)
        ui.row(.{ .grow = 1, .gap = side_rail_gap }, .{ side_rail, body })
    else
        ui.column(.{ .grow = 1 }, .{ top_header, body });

    // The palette rides ABOVE the whole workspace, including the side rail, so
    // it is in the same place whichever placement is active. The wrapper only
    // exists while it is open — an unconditional stack would change the widget
    // tree of every frame that has no palette in it.
    const workspace = if (ws.settings.open)
        // The settings surface rides above everything, on the same terms as
        // the palette below, and takes precedence over it in the tree because
        // the two can never both be open: `settings_open` dismisses the
        // palette and `palette_open` dismisses settings. This `else if` is a
        // belt-and-braces ordering, not the thing that enforces the
        // invariant — when it WAS the only thing enforcing it, the surface it
        // hid was still open in the model and surfaced on the next Escape.
        ui.el(.stack, .{ .grow = 1 }, .{
            laid_out,
            ui.el(.stack, .{
                .grow = 1,
                .style = .{ .background = settings_scrim },
                .on_press = .settings_close,
                .semantics = .{ .label = "Dismiss settings without saving" },
            }, .{}),
            ui.row(.{ .grow = 1, .main = .center, .cross = .center, .padding = settings_margin }, .{
                settingsPanel(ui, model, ws),
            }),
        })
    else if (ws.palette.open)
        ui.el(.stack, .{ .grow = 1 }, .{
            laid_out,
            // A scrim over the grid: the palette is modal to the keyboard, and
            // chrome that takes the keyboard without saying so is how a user
            // ends up typing a needle into a shell they thought was focused.
            ui.el(.stack, .{
                .grow = 1,
                .style = .{ .background = palette_scrim },
                .on_press = .palette_close,
                .semantics = .{ .label = "Dismiss the terminal switcher" },
            }, .{}),
            ui.row(.{ .grow = 1, .main = .center, .cross = .start, .padding = palette_top_inset }, .{
                palettePanel(ui, model, ws, tokens),
            }),
        })
    else
        laid_out;

    // The hidden-inset titlebar band. It carries `window_drag` UNCONDITIONALLY,
    // because it is the only element that can: the SDK has no
    // movable-by-background fallback, so a frame where nothing declares
    // `window_drag` is a frame where the window cannot be moved at all.
    //
    // When the strip rides it, the tabs are CHILDREN of the drag region. That
    // is the arrangement the separate band already used and it works: a child
    // with its own `on_press` wins the hit test, so a tab click selects and a
    // click on the gutter beside it moves the window.
    const inset = windowPadding(model);
    const titlebar_band = @max(0, chrome.titlebar_height - inset);
    const titlebar = if (show_top_strip and rides_titlebar) ui.row(.{
        .height = titlebar_band,
        .gap = projection.chrome_gap,
        .cross = .center,
        .window_drag = true,
        .semantics = .{ .label = "Phux Cockpit window" },
    }, .{
        // The traffic lights are platform-drawn and are not in this tree, so
        // the room for them has to be held explicitly or the first tab lands
        // under the close button.
        ui.el(.stack, .{
            .width = projection.titlebar_tab_leading_reserve,
            .window_drag = true,
            .semantics = .{ .hidden = true },
        }, .{}),
        tab_strip,
        status,
    }) else ui.el(.stack, .{
        .height = titlebar_band,
        .window_drag = true,
        .semantics = .{ .label = "Phux Cockpit window" },
    }, .{});

    return ui.column(.{ .padding = inset }, .{ titlebar, workspace });
}

/// THE per-window chrome builder, and the one this app registers.
///
/// `ChromeOptions.build` paints the main canvas only, because its signature
/// cannot say which window it is drawing — and for an app whose terminals ARE
/// chrome commands, that meant a second window rendered its tab strip, its
/// dividers, and empty rectangles where the cells belonged (verified in the
/// running app before `build_window` existed). The context names the canvas,
/// which names the workspace, which is the whole difference.
pub fn buildChromeWindow(model: *const Model, builder: *canvas.Builder, context: TerminalApp.ChromeContext) anyerror!void {
    const window_index = scene_module.windowIndexForCanvas(context.canvas_label) orelse return;
    return paintWindow(model, builder, window_index, context.size, context.tokens);
}

/// The same, addressed by index for a host whose ChromeContext is another
/// app type's (the TypeScript-core graph paints through its adapter's).
pub fn paintWindowIndex(model: *const Model, builder: *canvas.Builder, window_index: usize, size: geometry.SizeF, tokens: canvas.DesignTokens, _: native_sdk.platform.WindowId) anyerror!void {
    return paintWindow(model, builder, window_index, size, tokens);
}

/// The main window's chrome through the legacy single-window seam. Kept so
/// the tests that paint one window directly keep a stable entry point, and so
/// an `Options.chrome.build` fallback still produces the right pixels.
pub fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    return paintWindow(model, builder, 0, size, tokens);
}

/// The grids of ONE window, painted as a variable-length chrome prefix beneath
/// that window's widget tree: real text through the canvas primitives, damage
/// kept row-shaped by stable command ids, one id namespace per pane.
///
/// Pane id namespaces are the REGISTRY slot, which is global — so two windows
/// showing different terminals never collide, and no window can ever show the
/// same terminal as another (`Model.admitTab` refuses it).
fn paintWindow(model: *const Model, builder: *canvas.Builder, window_index: usize, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    const ws = model.wsAtConst(window_index) orelse return;
    // The grids paint with the TERMINAL tokens (the configured type size and
    // colors); everything else on this surface is chrome and keeps the app's
    // own register. See `projection.terminalTokens`.
    const grid_tokens = projection.terminalTokensFrom(tokens, model);
    // The window's own ground is painted ONCE, before any pane. The first
    // pane used to be handed the whole window as its background frame, so
    // the emulator's background (OSC 11 included) bled under the tab strip
    // and the titlebar. It takes the terminal's background so a configured
    // `background` reaches the gutter too, rather than leaving a frame of
    // the app's default graphite around a themed terminal.
    try builder.fillRect(.{
        .id = window_ground_command_id,
        .rect = geometry.RectF.init(0, 0, size.width, size.height),
        .fill = .{ .color = grid_tokens.colors.background },
    });

    const chrome = projection.workspaceChromeIn(model, ws, size);
    if (chrome.header.height > 0) {
        // The band gets a real ground and a separator, so it reads as chrome
        // instead of as a floating strip over the terminal.
        try builder.fillRect(.{
            .id = header_ground_command_id,
            .rect = chrome.header,
            .fill = .{ .color = tokens.colors.surface },
        });
        try builder.fillRect(.{
            .id = header_rule_command_id,
            .rect = geometry.RectF.init(chrome.header.x, chrome.header.y + chrome.header.height - 1, chrome.header.width, 1),
            .fill = .{ .color = tokens.colors.border },
        });
    }

    // The app's own grounds are chrome, not grid: the panes' command
    // envelope is measured from HERE, so adding a background fill can never
    // shave commands off the last pane's share.
    const prologue = builder.len;

    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = projection.resolvePanesIn(model, ws, size, &panes);
    if (count == 0) return;

    // The budgets are partitioned by kind, exactly as the two-pane painter
    // did, generalized to N panes:
    //   commands  — CUMULATIVE across the prefix, so pane i may spend up to
    //               its share of the running total and the LAST pane may
    //               spend the whole envelope;
    //   text/path — RESERVES, so a pane holds back the shares belonging to
    //               the panes that paint after it;
    //   glyphs    — per-paint local, so each pane takes an equal slice.
    const share_divisor: usize = @max(1, count);
    const text_share = (canvas.max_display_list_text_bytes - canvas.terminal_grid.widget_text_reserve) / share_divisor;
    const path_share = (canvas.max_chart_path_elements_per_frame - canvas.terminal_grid.widget_path_reserve) / share_divisor;
    // Cells are the budget that actually bounds a terminal now, and unlike
    // text and paths they have no widget floor to hold back: nothing but a
    // terminal grid emits into the packed cell store. So the WHOLE store is
    // divided among the panes and each one reserves the shares belonging to
    // the panes painting after it.
    //
    // Deliberately not `terminal_grid.widget_cell_reserve`. Despite the name
    // that constant is `max/2` — the SDK's even split for exactly TWO panes,
    // not a widget reserve. Using it as a floor would hold back half the
    // store at every pane count: a lone full-screen terminal would get 16384
    // cells and a 320x96 grid needs 30720, so the single-pane case — the
    // common one — would start silently truncating again.
    const cell_share = canvas.max_display_list_cells / share_divisor;
    const focus_node = if (ws.selectedTreeConst()) |current| current.focus else layout.none;

    for (panes[0..count], 0..) |pane, index| {
        if (pane.rect.width <= 0 or pane.rect.height <= 0) continue;
        const remaining = count - 1 - index;
        // The command budget is measured against the builder's RUNNING
        // length, so each pane is granted its own equal slice above whatever
        // the panes before it spent. A fixed cumulative ladder starved the
        // later panes whenever an earlier one filled its share.
        // A CUMULATIVE ladder measured from the chrome prologue: pane i may
        // spend up to its share of the running total, and the LAST pane may
        // spend the whole envelope. A per-pane slice would strand the tail
        // of the envelope unused whenever an early pane came in cheap.
        const command_budget = prologue + chrome_command_envelope * (index + 1) / share_divisor;
        const text_reserve = canvas.terminal_grid.widget_text_reserve + text_share * remaining;
        const path_reserve = canvas.terminal_grid.widget_path_reserve + path_share * remaining;
        const glyph_budget = canvas.terminal_grid.widget_glyph_budget / share_divisor;
        const cell_reserve = cell_share * remaining;
        // Each pane owns its OWN background frame. Nothing paints outside
        // the pane it belongs to.
        // A window that is not the one the user is in shows no focused pane:
        // two windows both drawing a solid cursor would both claim the
        // keyboard, and only one of them has it.
        const window_active = model.focused and window_index == model.active_window;
        const options_focused = window_active and pane.node == focus_node;
        if (model.provider.terminalConst(pane.terminal)) |terminal| {
            const preview_target = terminal.session.hoveredOsc8Target();
            const preview_reserve = linkPreviewCommandReserve(terminal.session);
            try grid.paint(terminal.session, builder, .{
                .frame = pane.rect,
                .background_frame = pane.rect,
                .tokens = grid_tokens,
                .running = terminal.phase == .live or terminal.phase == .starting,
                .focused = options_focused,
                .selecting = terminal.selecting,
                // Reserve only while a preview is actually pending. Quiet and
                // saturated grids retain the entire terminal envelope.
                .command_budget = command_budget -| preview_reserve,
                .text_reserve = text_reserve,
                .glyph_budget = glyph_budget,
                .path_reserve = path_reserve,
                .cell_reserve = cell_reserve,
                .minimum_contrast = model.config.minimum_contrast,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, pane.terminal)),
            });
            if (preview_target) |target| try paintLinkTargetPreview(terminal, index, pane.rect, tokens, builder, target);
        } else {
            const remote = model.phuxConst() orelse continue;
            const presentation = remote.presentation(pane.terminal) orelse continue;
            try grid.paintTerminalGrid(presentation.grid, builder, .{
                .frame = pane.rect,
                .background_frame = pane.rect,
                .tokens = grid_tokens,
                .running = presentation.phase == .live,
                .focused = options_focused,
                .selecting = if (model.remoteUiConst(pane.terminal)) |state| state.selecting else false,
                .command_budget = command_budget,
                .text_reserve = text_reserve,
                .glyph_budget = glyph_budget,
                .path_reserve = path_reserve,
                .cell_reserve = cell_reserve,
                .id_base = grid.paneIdBase(terminalPaintIndex(model, pane.terminal)),
            });
        }

        // Ghostty dims the splits you are not in, and it is the right answer:
        // with per-pane headers gone, a solid-versus-hollow cursor was the
        // ONLY thing telling you where your keystrokes were going, and a
        // cursor is a few pixels on a screen full of text.
        //
        // One pane never dims — there is nothing to disambiguate — and
        // neither does a window that does not have key, where nothing is
        // focused at all.
        if (count > 1 and window_active and pane.node != focus_node) {
            try builder.fillRect(.{
                .id = pane_dim_command_id_base + index,
                .rect = pane.rect,
                .fill = .{ .color = dim_scrim },
            });
        }
    }

    // The focused pane's edge, painted AFTER every pane and every scrim so a
    // neighbour's dim can never lie on top of it.
    //
    // The scrim alone is not enough and never was. It dims toward black, and a
    // terminal configured black — or one an application put there with OSC 11 —
    // has nothing left to take away, which is exactly the setup a terminal user
    // is most likely to be running. The edge is the signal that survives it.
    if (count > 1 and model.focused and window_index == model.active_window) {
        for (panes[0..count]) |pane| {
            if (pane.node != focus_node) continue;
            if (pane.rect.width <= 0 or pane.rect.height <= 0) continue;
            const t = @min(pane_focus_edge_thickness, @min(pane.rect.width, pane.rect.height) / 2);
            const edges = [4]geometry.RectF{
                geometry.RectF.init(pane.rect.x, pane.rect.y, pane.rect.width, t),
                geometry.RectF.init(pane.rect.x, pane.rect.y + pane.rect.height - t, pane.rect.width, t),
                geometry.RectF.init(pane.rect.x, pane.rect.y, t, pane.rect.height),
                geometry.RectF.init(pane.rect.x + pane.rect.width - t, pane.rect.y, t, pane.rect.height),
            };
            for (edges, 0..) |edge, edge_index| {
                try builder.fillRect(.{
                    .id = pane_focus_command_id_base + edge_index,
                    .rect = edge,
                    .fill = .{ .color = tokens.colors.accent },
                });
            }
            break;
        }
    }
}

/// The unfocused-pane scrim: BLACK at low alpha, which reads as "further
/// away" rather than as a tint.
///
/// It used to be the window's own ground colour at 0.36, and that was a no-op
/// in the default configuration and in most others. The scrim is painted over
/// panes whose background is that same ground, and compositing a colour over
/// itself yields that colour at every alpha — so the dim drew literally
/// nothing, and the only thing distinguishing the focused split in a four-way
/// was a solid-versus-hollow cursor.
///
/// Dimming toward black instead makes it independent of what the pane beneath
/// happens to be: a configured `background`, a theme, or an application's
/// OSC 11 all darken. The one case it still cannot serve is a terminal that is
/// already black, which is why `paintWindow` also draws an accent edge.
///
/// The DEPTH is 0.15, and it is deliberately shallow. Ghostty's
/// `unfocused-split-opacity` defaults to 0.85 — the same 15% — and that is not
/// a coincidence of taste: an unfocused split is still a split you are READING,
/// and a shell prompt is already full of deliberately dim colours that a heavy
/// wash takes below legibility. The first fix for the no-op overshot to 0.42
/// and made unfocused panes genuinely hard to read, which traded one real
/// problem for another. The accent edge carries the signal; the scrim only has
/// to whisper.
const dim_scrim: canvas.Color = canvas.Color.rgba(0, 0, 0, 0.15);

/// Frame pump: resize each visible terminal against its actual pane. One
/// resize message is emitted per frame; further changed panes follow on
/// later frames without ever coupling a PTY's lifetime to layout.
///
/// Runs PER WINDOW — the runtime hands each slot's own `gpuSurfaceFrame` here
/// — so the pump's whole job is to answer against the window the frame names
/// rather than against whichever one is in front. A frame for a label this app
/// does not own is ignored; a frame for a window that is not the active one
/// still resizes ITS terminals, which is the difference between a background
/// window's shells tracking their pane and keeping the grid they were born
/// with.
pub fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const window_index = scene_module.windowIndexForCanvas(frame.label) orelse return null;
    const ws = model.wsAtConst(window_index) orelse return null;
    const window: u8 = @intCast(window_index);
    const frame_scale = if (validScale(frame.scale_factor)) frame.scale_factor else ws.surface_scale_factor;
    var pending = false;
    for (0..max_terminals) |index| {
        if (model.provider.states[index] != .active) continue;
        const pane = model.provider.slotConst(index);
        if (pane.outbound_len > 0 or pane.session.response_len > 0) pending = true;
    }

    // The SAME resolve the painter and the widget tree use, through the same
    // derivation the COMMIT path uses — see `projection.proposedViewportsIn`.
    // The cost of deriving metrics from the painter's tokens is that a
    // font-size change reflows on the frame AFTER the first repaint at the new
    // size, which is one timer tick.
    const proposals = projection.proposedViewportsIn(model, ws, frame.size);
    for (proposals.slice()) |proposal| {
        if (!projection.viewportDiffers(model, proposal)) continue;
        return .{
            .viewport = .{
                .terminal_ref = proposal.terminal,
                .cols = proposal.cols,
                .rows = proposal.rows,
                .size = frame.size,
                // Carry the real scale: the `.viewport` arm commits whatever
                // arrives, and the field's `= 1` default would silently reset
                // a Retina surface to 1x.
                .scale_factor = frame_scale,
                .window = window,
                .window_id = frame.window_id,
            },
        };
    }
    // A pane whose metrics the painter has not written yet: propose nothing
    // this frame rather than sizing against metrics that do not exist.
    if (proposals.incomplete) return if (pending) .flush_outbound else null;
    // Incremental scrollback search, one bounded slice per frame. It sits
    // BELOW resize convergence — a pane at the wrong grid is a visible defect
    // and a still-streaming match count is not — and above the surface
    // bookkeeping only because the `.search_tick` arm drains outbound itself,
    // so it cannot starve a pane's pending writes the way a bare return would.
    for (0..max_terminals) |index| {
        if (model.provider.states[index] != .active) continue;
        if (model.provider.slotConst(index).session.searchPending()) return .search_tick;
    }
    if (ws.surface_size.width != frame.size.width or ws.surface_size.height != frame.size.height or
        ws.surface_scale_factor != frame_scale or ws.window_id != frame.window_id)
    {
        return .{ .surface_resized = .{
            .size = frame.size,
            .scale_factor = frame_scale,
            .window = window,
            .window_id = frame.window_id,
        } };
    }
    if (pending) return .flush_outbound;
    return null;
}

/// The webview panes belonging to ONE window.
///
/// The web surface lives in the main window: its anchor widget is only ever
/// built into the scene's own canvas. Answering with it for every window made
/// every secondary window's rebuild resolve the anchor against a widget tree
/// that does not contain it, logging "no canvas widget carries semantics
/// label ..." on every rebuild of every other window. The behaviour was always
/// correct — the pane is found and snapped in the window that owns it — but
/// the noise buried real warnings.
///
/// Zero is the right answer for a window that hosts no webview.
pub fn webPanes(model: *const Model, context: TerminalApp.ChromeContext, out: []TerminalApp.WebViewPane) usize {
    if (!context.is_main) return 0;
    out[0] = .{
        .label = webview_label,
        .anchor = webview_anchor,
        .url = model.browser_page.url(),
        .reload_token = model.browser_navigation_token,
    };
    return 1;
}

/// The secondary windows the model currently declares. Presence IS
/// visibility: a slot the model stops naming is a window the runtime closes,
/// so `Model.closeWindow` is the whole close path and there is no second flag
/// saying whether a declared window is showing.
pub fn windows(model: *const Model, scratch: *TerminalApp.WindowsScratch) []const TerminalApp.WindowDescriptor {
    var count: usize = 0;
    for (0..model_module.max_secondary_windows) |offset| {
        const index = offset + 1;
        if (!model.windowOpen(index)) continue;
        scratch.windows[count] = .{
            .label = scene_module.windowLabelFor(index),
            .canvas_label = scene_module.canvasLabelFor(index),
            .title = scene_module.app_name,
            .width = scene_module.window_width,
            .height = scene_module.window_height,
            .min_width = scene_module.window_min_width,
            .min_height = scene_module.window_min_height,
            // The same hidden-inset band the scene's own window declares, so
            // a second window is the same window, not a stock-chrome cousin.
            .titlebar = .hidden_inset_tall,
            .on_close = .{ .window_closed = @intCast(index) },
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

/// The command name the menu-bar row for tab `index` dispatches. A comptime
/// table rather than a formatted string, because `on_command` is handed a
/// borrowed name and answers with a Msg — there is nowhere in that signature
/// for an allocation to live.
const tray_select_prefix = "tray.select.";

const tray_select_commands = blk: {
    var names: [max_tabs][]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = std.fmt.comptimePrint("tray.select.{d}", .{index});
    break :blk names;
};

/// The menu-bar extra, derived from the model on every rebuild.
///
/// What it answers, from a machine whose front window belongs to something
/// else entirely: how many terminals are open, whether any of them wants
/// something, which one, and — through the rows — a way straight to it.
///
/// The ACTIVE window's tabs, not every window's: the rows dispatch
/// `select_position`, which is a position inside one workspace, and a flat
/// list mixing four windows' tabs would have two rows called "Terminal 2" that
/// went to different places. The count in the title is the same scope, so the
/// two agree.
pub fn statusItem(model: *const Model, scratch: *TerminalApp.StatusItemScratch) TerminalApp.StatusItemState {
    const ws = model.wsConst();
    var count: usize = 0;
    var attention: usize = 0;
    var arena_used: usize = 0;
    // Two rows are reserved for the trailer below, so a workspace at the tab
    // ceiling cannot push New Terminal out of its own menu.
    const row_ceiling = @min(max_tabs, scratch.items.len -| 2);
    for (0..ws.tab_count) |index| {
        if (count >= row_ceiling) break;
        const id = ws.tabTerminal(index) orelse continue;
        const needs = projection.terminalNeedsAttention(model, id);
        if (needs) attention += 1;
        // Titles come from the pane and are borrowed, except the `Terminal N`
        // fallback — which needs a buffer that outlives this call, and the
        // scratch is exactly that (it lives on the app struct, valid until the
        // next apply).
        const room = scratch.arena_buffer[arena_used..];
        const label = projection.terminalTitleInto(model, id, room);
        if (label.ptr == room.ptr) arena_used += label.len;
        scratch.items[count] = .{
            // Item ids are the platform's own handle for a row and must be
            // non-zero; the tab position plus one is stable for as long as the
            // menu is open, which is the only lifetime that matters.
            .id = @intCast(index + 1),
            .label = label,
            .command = tray_select_commands[index],
            // The marker is a WORD, not a dot: a status menu is read, not
            // scanned, and "needs attention" says what a coloured dot only
            // hints at.
            .detail = if (needs) "needs attention" else "",
            // `.agent` is the toolkit's role for a row that BOTH acts and
            // reports — a `.command` row carrying a detail is refused whole
            // (`validateTrayMenuItems`), and a `.info` row cannot carry a
            // command. A terminal is exactly the thing that has to be both.
            .role = .agent,
            .enabled = true,
        };
        count += 1;
    }
    scratch.items[count] = .{ .separator = true, .id = @intCast(count + 1) };
    count += 1;
    scratch.items[count] = .{
        .id = @intCast(count + 1),
        .label = "New Terminal",
        .command = "terminal.new",
        .key = "t",
        .modifiers = .{ .primary = true },
    };
    count += 1;

    const title = std.fmt.bufPrint(
        &scratch.title_buffer,
        "{s} {d}",
        .{ scene_module.status_item_prefix, ws.tab_count },
    ) catch scene_module.status_item_prefix;
    return .{
        .title = title,
        .presentation = .{
            .title = title,
            // The whole point of the extra is the glance, so attention is the
            // one thing it says without being opened. Tone rather than an
            // extra glyph: the menu bar is a shared strip, and an app that
            // grows a character when it wants something shoves everything to
            // its left.
            .tone = if (attention > 0) .warning else .normal,
        },
        .items = scratch.items[0..count],
    };
}

pub fn onCommand(name: []const u8) ?Msg {
    // The menu-bar rows, which carry the tab position in the command name —
    // the tray channel has no payload of its own.
    if (std.mem.startsWith(u8, name, tray_select_prefix)) {
        const index = std.fmt.parseInt(u8, name[tray_select_prefix.len..], 10) catch return null;
        if (index >= max_tabs) return null;
        return .{ .tray_select = index };
    }
    // Every menu open re-reads the derivation for free (the runtime consults
    // `status_item_fn` after each dispatch), so the command needs no arm of
    // its own beyond being a message at all.
    if (std.mem.eql(u8, name, "tray.opened")) return .tray_opened;
    if (std.mem.eql(u8, name, "window.new")) return .new_window;
    if (std.mem.eql(u8, name, "window.fullscreen")) return .toggle_fullscreen;
    if (std.mem.eql(u8, name, "window.minimize")) return .minimize_window;
    if (std.mem.eql(u8, name, "surface.1")) return .{ .select_position = 0 };
    if (std.mem.eql(u8, name, "surface.2")) return .{ .select_position = 1 };
    if (std.mem.eql(u8, name, "surface.3")) return .{ .select_position = 2 };
    if (std.mem.eql(u8, name, "surface.4")) return .{ .select_position = 3 };
    if (std.mem.eql(u8, name, "surface.5")) return .{ .select_position = 4 };
    if (std.mem.eql(u8, name, "tab.previous")) return .{ .cycle_tab = -1 };
    if (std.mem.eql(u8, name, "tab.next")) return .{ .cycle_tab = 1 };
    if (std.mem.eql(u8, name, "pane.split-right")) return .split_right;
    if (std.mem.eql(u8, name, "pane.split-down")) return .split_down;
    if (std.mem.eql(u8, name, "terminal.new")) return .new_terminal;
    if (std.mem.eql(u8, name, "terminal.close")) return .close_terminal;
    if (std.mem.eql(u8, name, "tab.move-left")) return .{ .move_terminal = -1 };
    if (std.mem.eql(u8, name, "tab.move-right")) return .{ .move_terminal = 1 };
    if (std.mem.eql(u8, name, "tabs.toggle-placement")) return .toggle_tab_placement;
    if (std.mem.eql(u8, name, "pane.previous")) return .{ .cycle_pane = -1 };
    if (std.mem.eql(u8, name, "pane.next")) return .{ .cycle_pane = 1 };
    if (std.mem.eql(u8, name, "surface.web")) return .{ .select_surface = .web };
    if (std.mem.eql(u8, name, "tabs.palette")) return .palette_open;
    if (std.mem.eql(u8, name, "settings.open")) return .settings_open;
    if (std.mem.eql(u8, name, "terminal.copy")) return .copy_selection;
    if (std.mem.eql(u8, name, "terminal.paste")) return .paste_focused;
    if (std.mem.eql(u8, name, "terminal.select-all")) return .select_all;
    if (std.mem.eql(u8, name, "terminal.clear")) return .clear_terminal;
    if (std.mem.eql(u8, name, "terminal.find")) return .search_open;
    if (std.mem.eql(u8, name, "terminal.find-next")) return .{ .search_step = 1 };
    if (std.mem.eql(u8, name, "terminal.find-previous")) return .{ .search_step = -1 };
    if (std.mem.eql(u8, name, "view.font-larger")) return .{ .font_size_step = 1 };
    if (std.mem.eql(u8, name, "view.font-smaller")) return .{ .font_size_step = -1 };
    if (std.mem.eql(u8, name, "view.font-reset")) return .font_size_reset;
    if (std.mem.eql(u8, name, "pane.focus-left")) return .{ .focus_direction = .left };
    if (std.mem.eql(u8, name, "pane.focus-right")) return .{ .focus_direction = .right };
    if (std.mem.eql(u8, name, "pane.focus-up")) return .{ .focus_direction = .up };
    if (std.mem.eql(u8, name, "pane.focus-down")) return .{ .focus_direction = .down };
    return null;
}

pub fn tabPlacementFromText(value: []const u8) ?TabPlacement {
    if (std.ascii.eqlIgnoreCase(value, "top")) return .top;
    if (std.ascii.eqlIgnoreCase(value, "side") or std.ascii.eqlIgnoreCase(value, "sidebar")) return .side;
    return null;
}

pub fn onTimer(id: u64, _: u64) ?Msg {
    return if (id == selection_autoscroll_timer_id) .selection_autoscroll else null;
}
