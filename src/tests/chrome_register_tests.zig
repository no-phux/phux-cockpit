//! THE CHROME REGISTER, pinned.
//!
//! Two instruments, and they answer different questions.
//!
//! The first is arithmetic over the constants: every band, control, icon and
//! gutter has to trace back to the Geist pack's own token ladder or to the 4pt
//! grid, and the point of asserting that here is that the next person to reach
//! for `height = 30` has to argue with a test instead of with a comment.
//! docs/DESIGN_SYSTEM.md is where the derivations and the sources live.
//!
//! The second is the toolkit's own layout audit, which this app was not using.
//! It walks the SOLVED tree and reports text that silently loses glyphs,
//! siblings that overlap, widgets that escape their clip scope, and controls
//! under the pointer floor — with widget-path precision, at the real window
//! sizes this app declares, in every state its chrome has. It is geometry-only
//! and deterministic, and it re-uses the exact measurement seam layout and
//! paint use, so what it predicts is what gets inked.
//!
//! It caught two overflows that had been shipping: the switcher grew a row per
//! tab until it was 624pt tall inside a 420pt-minimum window, and the settings
//! panel needed 385pt inside the 308 its own top inset left it.
//!
//! What it does NOT see, stated so nobody reads more into a green run than is
//! there: these tokens carry no `text_measure` provider, so text widths come
//! from the SDK's deterministic estimator rather than from CoreText. That is
//! the right instrument for geometry — it is the same estimator the audit
//! predicts paint with, so the two cannot disagree — but it means a finding
//! here is about LAYOUT and never about what a glyph looks like. For that,
//! read docs/RENDER_FIDELITY.md; it is not a question any test in this repo
//! can answer.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");
const theme_module = @import("../config/theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

// --------------------------------------------------------------- the ladder

/// The pack this app actually resolves, read through the same call the view
/// makes. Pinning against a hand-written copy of the numbers would pass on the
/// day the pack changed underneath the app, which is the one day it matters.
fn packTokens() canvas.DesignTokens {
    var model: app.Model = .{ .provider = undefined };
    return app.cockpitTokens(&model);
}

test "the chrome register is the pack's own control ladder, not numbers we liked" {
    const tokens = packTokens();

    // A band is exactly one DEFAULT-register control tall and hosts SMALL-register
    // controls with `spacing.xs` shoulders. That one sentence is the band system.
    try testing.expectEqual(tokens.metrics.control_height, app.chrome_band_height);
    try testing.expectEqual(tokens.metrics.control_height_sm, app.chrome_control_extent);
    try testing.expectEqual(tokens.spacing.xs, app.chrome_band_inset);
    try testing.expectEqual(tokens.spacing.sm, app.chrome_gap);
    try testing.expectEqual(
        app.chrome_band_height,
        app.chrome_control_extent + app.chrome_band_inset * 2,
    );

    // The icon extent, from the toolkit's own rule: an inline icon sizes just
    // above its companion text. 13 + 2 = 15, and 16 is the artboard it rounds
    // to — within one point, which is the tolerance this asserts rather than
    // pretending the two are equal.
    const derived = tokens.typography.label_size + tokens.metrics.icon_text_step;
    try testing.expect(@abs(app.chrome_icon_extent - derived) <= 1);

    // The selected-tab bar is the pack's own indicator weight, not a 2 that
    // happens to match.
    try testing.expectEqual(tokens.metrics.tabs_indicator_thickness, app.tab_indicator_thickness);
}

test "every chrome extent lands on the 4pt grid, or is a pack token" {
    // The caret is a deliberate exception to where its SIZE comes from (the
    // terminal cell, not the register) and is listed anyway because it happens
    // to be grid-true as well. Everything else is a band, a control, a gutter
    // or a panel.
    const extents = [_]f32{
        app.chrome_band_height,  app.chrome_band_inset,  app.chrome_control_extent,
        app.chrome_icon_extent,  app.chrome_gap,         app.chrome_hit_target,
        app.tab_height,          app.tab_extent,         app.tab_min_extent,
        app.side_tab_height,     app.side_rail_width,    app.side_rail_gap,
        app.split_divider_width, app.search_bar_height,  app.config_notice_height,
        app.palette_width,       app.palette_row_height, app.palette_padding,
        app.palette_top_inset,   app.settings_width,     app.settings_row_height,
        app.settings_padding,    app.settings_margin,    app.field_caret_width,
        app.field_caret_height,  app.grid_inset,
    };
    for (extents) |extent| {
        try testing.expectEqual(@as(f32, 0), @mod(extent, 4));
    }

    // `header_height` is the one extent that is NOT on the grid, and it is not
    // ours to move: 50 is the pack's `tabs_trigger_height`, and the band exists
    // to be tall enough to contain a trigger the pack sizes. A pack token
    // outranks the grid — the rule is that every number traces to one or the
    // other, not that everything divides by four.
    try testing.expectEqual(@as(f32, 2), @mod(app.header_height, 4));
    var model: app.Model = .{ .provider = undefined };
    try testing.expectEqual(app.tabTriggerHeight(&model), app.header_height);
}

test "the band system has one height and one inset, not four" {
    // The complaint this answers: four bands at four paddings hosting controls
    // at four extents. They are the same band now, by construction.
    try testing.expectEqual(app.chrome_band_height, app.search_bar_height);
    try testing.expectEqual(app.chrome_band_height, app.config_notice_height);
    try testing.expectEqual(app.chrome_band_height, app.tab_height);
    try testing.expectEqual(app.tab_height, app.side_tab_height);
    // The floating panels host the same small-register row the bands do.
    try testing.expectEqual(app.chrome_control_extent, app.palette_row_height);
    try testing.expectEqual(app.chrome_control_extent, app.settings_row_height);
}

test "a pointer target clears WCAG 2.2 AA and the toolkit's own audit floor" {
    // 24x24 is SC 2.5.8 Target Size (Minimum) at AA, and it sits between
    // Apple's macOS minimum (20) and default (28). The toolkit's own floor is
    // 18; the close affordance used to BE 18, which is passing by zero.
    try testing.expect(app.chrome_hit_target >= 24);
    try testing.expect(app.chrome_hit_target > canvas.min_pointer_hit_target);
    try testing.expectEqual(app.chrome_hit_target, app.tab_control_extent);
}

test "a tab at its minimum extent still has room for a label" {
    // DERIVED, so the number cannot drift away from the furniture it has to
    // hold: two shoulders, the attention slot, two inter-child gaps, and the
    // close affordance. The old floor was 92 against 54pt of furniture — 38pt,
    // five characters — under a comment claiming ten.
    const furniture = app.chrome_gap * 2 + app.tab_marker_extent + app.chrome_gap * 2 + app.tab_control_extent;
    const label_room = app.tab_min_extent - furniture;
    try testing.expectEqual(@as(f32, 72), furniture);
    // And the constant the strip and the elision both size themselves against
    // is that same derivation, not a second copy of the number.
    try testing.expectEqual(furniture, app.tab_label_furniture);
    try testing.expectEqual(label_room, app.tabLabelWidth(app.tab_min_extent));
    // 48pt, which is six to seven characters of the pack's 13pt sans at its
    // average advance. The number is stated rather than computed from a
    // per-character guess because a guess is what let the old floor claim ten
    // characters while delivering five.
    try testing.expectEqual(@as(f32, 48), label_room);
    // And the label must be the largest single thing in the tab even at the
    // floor, which is the property that actually makes it a tab and not a chip.
    try testing.expect(label_room > app.tab_control_extent);
    try testing.expect(app.tab_min_extent < app.tab_extent);
}

test "the titlebar band this app is given can host the strip it puts there" {
    // Measured on this machine, not assumed: `native automate snapshot` reports
    // the hidden-inset band as `bounds=(8,8 1084x62)` at a default window, so
    // `chrome_top` is 66. A tab that outgrew that band would silently fall back
    // to the separate `header_height` band and cost every window a strip of
    // content height.
    const measured_chrome_top: f32 = 66;
    const measured_band = measured_chrome_top + 4 - app.grid_inset;
    try testing.expectEqual(@as(f32, 62), measured_band);
    try testing.expect(measured_band >= app.tab_height + 8);
    // And the fullscreen fallback band still covers a trigger.
    var model: app.Model = .{ .provider = undefined };
    try testing.expect(app.header_height >= app.tabTriggerHeight(&model));
    try testing.expect(app.header_height >= app.tab_height);
}

// ------------------------------------------------------------- the contrast

fn ratio(a: canvas.Color, b: canvas.Color) f32 {
    return theme_module.contrastRatioLuminance(
        theme_module.relativeLuminance(a.r, a.g, a.b),
        theme_module.relativeLuminance(b.r, b.g, b.b),
    );
}

test "state is said with the accent, because elevation cannot say it" {
    const colors = packTokens().colors;

    // THE MEASUREMENT this whole treatment rests on. The selected tab's fill
    // against the unselected tab's, and the switcher's cursor row against an
    // ordinary one. WCAG 2.1 SC 1.4.11 asks 3:1 of anything indicating STATE,
    // and neither of these is within sight of it — not because the palette is
    // bad but because Material's whole dark elevation range (5% white at 1dp
    // through 16% at 24dp) spans 1.00:1 to 1.60:1. This assertion exists to
    // stop someone "fixing" the accent marker by lightening a surface.
    try testing.expect(ratio(colors.surface_subtle, colors.surface) < 1.5);
    try testing.expect(ratio(colors.surface_pressed, colors.surface) < 1.5);

    // So the signal is chromatic, and it clears the floor by four times over.
    try testing.expect(ratio(colors.accent, colors.surface) >= 3);
    try testing.expect(ratio(colors.accent, colors.surface_subtle) >= 3);
    try testing.expect(ratio(colors.accent, colors.surface_pressed) >= 3);
    try testing.expect(ratio(colors.accent, colors.background) >= 3);
}

test "every ink the chrome paints clears AA on every ground it paints on" {
    const colors = packTokens().colors;
    const inks = [_]canvas.Color{ colors.text, colors.text_muted, colors.accent, colors.warning, colors.destructive };
    const grounds = [_]canvas.Color{ colors.background, colors.surface, colors.surface_subtle, colors.surface_pressed };
    for (inks) |ink| {
        for (grounds) |ground| {
            try testing.expect(ratio(ink, ground) >= theme_module.wcag_aa_body_text);
        }
    }
}

// ------------------------------------------------------- the switcher window

test "the switcher draws a bounded window that always holds the cursor" {
    // Unbounded, the panel grew a row per match: at the tab ceiling it stood
    // 624pt tall inside a window whose declared minimum height is 420, and the
    // tail was painted off the bottom edge.
    try testing.expectEqual(@as(usize, 0), app.paletteWindowFor(0, 0).count);

    // Under the cap, everything shows and nothing scrolls.
    const few = app.paletteWindowFor(3, 1);
    try testing.expectEqual(@as(usize, 0), few.first);
    try testing.expectEqual(@as(usize, 3), few.count);

    // Over it, the count is pinned and the cursor is always inside — which is
    // the whole invariant, because the row the cursor is on is the row Enter
    // commits and a cursor the panel never drew is a commit nobody can see.
    const many = app.max_tabs;
    for (0..many) |cursor| {
        const window = app.paletteWindowFor(many, cursor);
        try testing.expectEqual(app.palette_max_visible_rows, window.count);
        try testing.expect(window.contains(cursor));
        try testing.expect(window.first + window.count <= many);
    }

    // Anchored at the top until the cursor walks past the last drawn row, then
    // the cursor is the last one. Recentring on every step would make the rows
    // jump under the pointer.
    try testing.expectEqual(@as(usize, 0), app.paletteWindowFor(many, 0).first);
    try testing.expectEqual(
        many - app.palette_max_visible_rows,
        app.paletteWindowFor(many, many - 1).first,
    );
}

// ---------------------------------------------------------- the layout audit

/// One sweep point: build the app's real widget tree for `size`, lay it out
/// against `size`, and hand the solved tree to the toolkit's audit.
///
/// The tree is rebuilt per size rather than laid out once and re-solved,
/// because the strip's visible-tab window is DERIVED from `surface_size` — a
/// tree built for a wide window and audited at a narrow one would report an
/// overflow the app would never produce.
fn auditAt(
    state: *support.TerminalApp,
    size: geometry.SizeF,
    density: canvas.Density,
    label: []const u8,
) !void {
    // Heap, not a stack array: the build arena has to hold a full strip of tab
    // titles and every panel row, and a megabyte of test-thread stack is how
    // you get a crash that looks like a layout bug.
    const arena_bytes = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(arena_bytes);
    var fixed = std.heap.FixedBufferAllocator.init(arena_bytes);
    var ui = support.TerminalApp.Ui.init(fixed.allocator());

    state.model.ws().surface_size = size;
    var tokens = app.cockpitTokens(&state.model);
    tokens.density = density;

    const node = app.viewWindow(&ui, &state.model, 0);
    const tree = try ui.finalizeWithTokens(node, tokens);

    const nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, canvas.max_layout_audit_nodes);
    defer testing.allocator.free(nodes);
    const bounds = geometry.RectF.init(0, 0, size.width, size.height);
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, nodes);

    var storage: [canvas.max_layout_audit_findings]canvas.LayoutAuditFinding = undefined;
    const issues = canvas.auditWidgetLayout(layout, bounds, tokens, &storage);
    if (issues.total == 0) return;

    std.debug.print(
        "\nlayout audit: {d} finding(s) in \"{s}\" at {d:.0}x{d:.0}, {s} density\n",
        .{ issues.total, label, size.width, size.height, @tagName(density) },
    );
    for (issues.findings) |finding| {
        var message: [1400]u8 = undefined;
        var writer = std.Io.Writer.fixed(&message);
        canvas.formatLayoutAuditFinding(layout, finding, &writer) catch {};
        std.debug.print("  - {s}\n", .{writer.buffered()});
    }
    return error.LayoutAuditFindings;
}

/// The declared window floor, the declared default, and a generous desktop.
/// The floor is the one that matters: a min-size the chrome does not actually
/// fit inside is a min-size that is not honest, and both panel overflows this
/// audit found were invisible at every larger size.
const sweep_sizes = [_]geometry.SizeF{
    geometry.SizeF.init(app.window_min_width, app.window_min_height),
    geometry.SizeF.init(app.window_width, app.window_height),
    geometry.SizeF.init(1680, 1000),
};

fn sweep(state: *support.TerminalApp, label: []const u8) !void {
    for (sweep_sizes) |size| {
        for ([_]canvas.Density{ .compact, .regular, .spacious }) |density| {
            try auditAt(state, size, density, label);
        }
    }
}

// GUARD: canvas-cmd-t-complete-edge
test "repeated canvas Cmd+T presses complete their key edges" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try support.startCockpit(harness);
    defer support.stopCockpit(state);
    const iface = state.app();

    try support.requireLiveShells(app.max_tabs);
    for (1..app.max_tabs) |_| {
        try support.pressCanvasKey(harness, iface, "t", .{ .primary = true });
        try support.releaseCanvasKey(harness, iface, "t", .{ .primary = true });
    }
    try testing.expectEqual(app.max_tabs, state.model.ws().tab_count);
    try testing.expectEqual(@as(u64, 0), state.model.consumed_shortcut_keys_held);
}

// GUARD: full-tab-strip-chrome-arrangements
test "a full tab strip passes the layout audit in titlebar and fullscreen" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try support.startCockpit(harness);
    defer support.stopCockpit(state);

    try support.requireLiveShells(app.max_tabs);
    for (1..app.max_tabs) |_| app.update(&state.model, .new_terminal, &state.effects);
    try testing.expectEqual(app.max_tabs, state.model.ws().tab_count);

    state.model.ws().chrome_top = 66;
    try testing.expect(app.tabsRideTitlebarIn(&state.model, state.model.wsConst()));
    try sweep(state, "full tab strip in the titlebar");

    state.model.ws().chrome_top = 0;
    try testing.expect(!app.tabsRideTitlebarIn(&state.model, state.model.wsConst()));
    try sweep(state, "full tab strip in fullscreen");
}

test "the chrome survives the layout audit in every state it has" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(1100, 640) });
    defer harness.destroy(gpa);
    const state = try support.startSplitCockpit(gpa, harness);
    defer gpa.destroy(state);
    defer app.deinitModel(&state.model);
    defer state.deinit();
    const iface = state.app();

    try sweep(state, "split panes");

    for (0..3) |_| try state.dispatch(&harness.runtime, 1, .new_terminal);
    try sweep(state, "four-tab strip");

    try support.pressCanvasKey(harness, iface, "f", .{ .primary = true });
    try support.typeCanvasText(harness, iface, "a needle long enough to crowd the band");
    try sweep(state, "the search band");
    try support.pressCanvasKey(harness, iface, "escape", .{});

    // The switcher at its worst: every tab matching, so the row window is the
    // only thing between the panel and the bottom of the window.
    try support.pressCanvasKey(harness, iface, "p", .{ .primary = true, .shift = true });
    try sweep(state, "the switcher, everything matching");
    // And with the cursor at the far end, which is the other anchor.
    for (0..app.max_tabs) |_| try support.pressCanvasKey(harness, iface, "arrowdown", .{});
    try sweep(state, "the switcher, cursor at the end");
    try support.pressCanvasKey(harness, iface, "escape", .{});

    try support.pressCanvasKey(harness, iface, ",", .{ .primary = true });
    try sweep(state, "the settings panel");
    try support.pressCanvasKey(harness, iface, "escape", .{});

    state.model.state.write_failed = true;
    try sweep(state, "the exhausted layout-save notice");
    state.model.state.write_failed = false;

    state.model.tab_placement = .side;
    try sweep(state, "the side rail");
}

// ------------------------------------------- the band's trailing arithmetic

/// The solved widget tree for one size and density, as the audit above builds
/// it. Returned as a slice the caller frees, because the findings we want here
/// are geometric relationships between named nodes rather than audit findings.
/// Everything the chrome band can occupy, and nothing the terminal below it
/// can. The titlebar band measures 62pt inside an 8pt inset on this machine and
/// the fallback header band is 50; 80 clears both and is well above the first
/// terminal row.
const band_floor: f32 = 80;

const SolvedTree = struct {
    nodes: []canvas.WidgetLayoutNode,
    solved: canvas.WidgetLayoutTree,

    fn free(self: SolvedTree) void {
        testing.allocator.free(self.nodes);
    }

    /// The frame of the first node IN THE CHROME BAND whose accessibility
    /// label starts with `prefix`.
    ///
    /// Prefix rather than equality because the statuses name themselves with a
    /// whole diagnostic sentence — and band-scoped because a pane's SURFACE
    /// carries that same sentence (`terminalSurfaceLabel`), so an unscoped
    /// search for the failed pane's badge finds the 1584pt terminal instead and
    /// measures the window.
    fn find(self: SolvedTree, prefix: []const u8) ?geometry.RectF {
        for (self.solved.nodes) |node| {
            if (node.frame.y + node.frame.height > band_floor) continue;
            if (std.mem.startsWith(u8, node.widget.semantics.label, prefix)) return node.frame;
        }
        return null;
    }

    /// Everything the band carries to the RIGHT of the tab strip row, as one
    /// box. That is the status slot by construction rather than by name, which
    /// matters because the pane status is two widgets (a badge and a Restart
    /// button) and the badge's label is the pane's own diagnostic sentence.
    fn statusSlot(self: SolvedTree) ?geometry.RectF {
        const strip = self.find("Terminal tabs") orelse return null;
        const right_of = strip.x + strip.width;
        var min_x: f32 = std.math.floatMax(f32);
        var max_x: f32 = 0;
        for (self.solved.nodes) |node| {
            if (node.frame.y + node.frame.height > band_floor) continue;
            if (node.frame.width <= 0) continue;
            if (node.frame.x < right_of) continue;
            min_x = @min(min_x, node.frame.x);
            max_x = @max(max_x, node.frame.x + node.frame.width);
        }
        if (min_x > max_x) return null;
        return geometry.RectF.init(min_x, 0, max_x - min_x, 0);
    }

    fn expect(self: SolvedTree, prefix: []const u8) !geometry.RectF {
        return self.find(prefix) orelse {
            std.debug.print("\nno widget labelled \"{s}...\" in the chrome band\n", .{prefix});
            return error.WidgetMissing;
        };
    }
};

fn solveAt(
    state: *support.TerminalApp,
    arena_bytes: []u8,
    size: geometry.SizeF,
    density: canvas.Density,
) !SolvedTree {
    var fixed = std.heap.FixedBufferAllocator.init(arena_bytes);
    var ui = support.TerminalApp.Ui.init(fixed.allocator());

    state.model.ws().surface_size = size;
    var tokens = app.cockpitTokens(&state.model);
    tokens.density = density;

    const node = app.viewWindow(&ui, &state.model, 0);
    const tree = try ui.finalizeWithTokens(node, tokens);
    const nodes = try testing.allocator.alloc(canvas.WidgetLayoutNode, canvas.max_layout_audit_nodes);
    const bounds = geometry.RectF.init(0, 0, size.width, size.height);
    return .{
        .nodes = nodes,
        .solved = try canvas.layoutWidgetTreeWithTokens(tree.root, bounds, tokens, nodes),
    };
}

// What this pins, in one sentence: the `+` button is a child of the tab strip
// row, so it has to be INSIDE that row, and the status is the row's sibling,
// so the two can never share a column.
//
// It shipped doing neither. `tab_strip_trailing_reserve` (220) was subtracted
// from the band width, but the 78pt traffic-light reserve and the two 8pt gaps
// around the row were not — so the strip laid out believing it had 94pt more
// room than it had, and the `+` walked out of its own row and under the badge.
// Driven live at the app's declared minimum width after filling the shell
// table and refusing one more split:
//
//   ### width=900  tabs_drawn=4
//     strip row:    94.0 ..   784.0     (role=group name="Terminal tabs")
//     + button :   774.0 ..   806.0     (role=button name="New terminal…")
//     status   :   792.0 ..   892.0     (role=text name="Shell limit reached…")
//
// 22pt outside the row and 14pt under the badge, over the whole narrow range
// (900, 800: +22/+14; 700, 660, 600: +18/+10), and it only came clear at 1100.
// The 32pt button centres a 16pt glyph, so about 6pt of the `+` itself was
// covered.
test "the new-tab button stays inside the tab strip and clear of the status" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(1100, 640) });
    defer harness.destroy(gpa);
    const state = try support.startCockpit(harness);
    defer support.stopCockpit(state);

    // Fill the process-wide table across bounded tabs and panes, then ask for
    // one more shell through a split (a new tab would stop at max_tabs first).
    try testing.expect(!state.model.terminal_limit_refused);
    try support.fillLiveShells(state);
    try state.dispatch(&harness.runtime, 1, .split_right);
    // Assert-absent, act, assert-present: without this the geometry below would
    // be checked in a state that has no status node at all, and it would pass
    // for the wrong reason forever.
    try testing.expect(state.model.terminal_limit_refused);

    // THE STRIP HAS TO BE RIDING THE TITLEBAR, which is where the traffic-light
    // reserve is spent and where the overflow lives. 66 is this machine's
    // measured `chrome_top` (see "the titlebar band this app is given can host
    // the strip it puts there"), and a default `Workspace` leaves it at zero --
    // which is the fullscreen fallback band, and the reason the audit sweep
    // above has never once laid out the arrangement that ships.
    state.model.ws().chrome_top = 66;
    try testing.expect(app.tabsRideTitlebarIn(&state.model, state.model.wsConst()));

    const arena_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(arena_bytes);

    for (sweep_sizes) |size| {
        for ([_]canvas.Density{ .compact, .regular, .spacious }) |density| {
            const tree = try solveAt(state, arena_bytes, size, density);
            defer tree.free();

            const strip = try tree.expect("Terminal tabs");
            const plus = try tree.expect("New terminal, shortcut");
            const status = try tree.expect("Shell limit reached");

            const past_row = (plus.x + plus.width) - (strip.x + strip.width);
            const over_status = (plus.x + plus.width) - status.x;
            if (past_row > 0.5 or over_status > 0.5) {
                std.debug.print(
                    "\nat {d:.0}x{d:.0}, {s} density:\n" ++
                        "  strip row: {d:.1} ..{d:.1}\n" ++
                        "  + button : {d:.1} ..{d:.1}\n" ++
                        "  status   : {d:.1} ..{d:.1}\n" ++
                        "  + past the row's right edge by {d:.1}pt, over the status by {d:.1}pt\n",
                    .{
                        size.width,              size.height,
                        @tagName(density),       strip.x,
                        strip.x + strip.width,   plus.x,
                        plus.x + plus.width,     status.x,
                        status.x + status.width, past_row,
                        over_status,
                    },
                );
                return error.TabStripTrailingOverlap;
            }
        }
    }
}

// The reserve is a MEASUREMENT, and this is the measuring.
//
// `tabStripStatusReserveIn` holds back a fixed slot for a status whose width
// nothing in the projection can compute — the badge's text is laid out by the
// same estimator the audit predicts paint with, and only the solved tree knows
// what it came to. Holding back a number nobody re-derives is how the 220 that
// caused the overlap survived: this fails with the number if a status ever
// outgrows its slot, rather than letting the `+` slide back under it.
test "the trailing status fits the room the strip holds back" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(1600, 900) });
    defer harness.destroy(gpa);
    const state = try support.startCockpit(harness);
    defer support.stopCockpit(state);

    const arena_bytes = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(arena_bytes);
    // Wide enough that nothing in the band is being clamped by the window, so
    // what is measured is the status's own intrinsic width.
    const size = geometry.SizeF.init(1600, 900);

    const Case = struct { label: []const u8, prefix: []const u8, reserve: f32 };
    const notices = [_]Case{
        .{ .label = "shell limit", .prefix = "Shell limit reached", .reserve = app.tab_strip_notice_reserve },
        .{ .label = "window limit", .prefix = "Window limit reached", .reserve = app.tab_strip_notice_reserve },
        .{ .label = "tab limit", .prefix = "Tab limit reached", .reserve = app.tab_strip_notice_reserve },
        .{ .label = "theme save failure", .prefix = "Theme could not be saved", .reserve = app.tab_strip_save_notice_reserve },
        .{ .label = "layout save failure", .prefix = "Workspace layout could not be saved", .reserve = app.tab_strip_save_notice_reserve },
    };

    for (notices, 0..) |case, index| {
        state.model.terminal_limit_refused = index == 0;
        state.model.window_limit_refused = index == 1;
        state.model.ws().tab_limit_refused = index == 2;
        state.model.config_write_refused = index == 3;
        state.model.state.write_failed = index == 4;
        defer {
            state.model.terminal_limit_refused = false;
            state.model.window_limit_refused = false;
            state.model.ws().tab_limit_refused = false;
            state.model.config_write_refused = false;
            state.model.state.write_failed = false;
        }
        for ([_]canvas.Density{ .compact, .regular, .spacious }) |density| {
            const tree = try solveAt(state, arena_bytes, size, density);
            defer tree.free();
            _ = try tree.expect(case.prefix);
            const slot = tree.statusSlot() orelse return error.WidgetMissing;
            try expectStatusFits(case.label, density, slot.width, case.reserve);
            try testing.expectEqual(
                case.reserve,
                app.tabStripStatusReserveIn(&state.model, state.model.wsConst()),
            );
        }
    }

    // The pane status is the wide one: a lifecycle badge AND a Restart button.
    const slots = support.activeSlots(&state.model);
    inline for (.{ "rejected", "spawn_failed", "exited" }) |reason| {
        slots[0].phase = .failed;
        slots[0].exit_reason = @field(native_sdk.EffectExitReason, reason);
        for ([_]canvas.Density{ .compact, .regular, .spacious }) |density| {
            const tree = try solveAt(state, arena_bytes, size, density);
            defer tree.free();
            // Named to be sure the state under test is the one being measured,
            // then measured as a whole slot: the pane status is a badge AND a
            // Restart button, and both have to fit.
            _ = try tree.expect("Restart Terminal 1");
            const slot = tree.statusSlot() orelse return error.WidgetMissing;
            try expectStatusFits(
                "failed/" ++ reason,
                density,
                slot.width,
                app.tab_strip_pane_status_reserve,
            );
            try testing.expectEqual(
                app.tab_strip_pane_status_reserve,
                app.tabStripStatusReserveIn(&state.model, state.model.wsConst()),
            );
        }
    }
}

fn expectStatusFits(label: []const u8, density: canvas.Density, measured: f32, reserve: f32) !void {
    if (measured <= reserve) return;
    std.debug.print(
        "\nthe \"{s}\" status is {d:.1}pt at {s} density, and the strip only holds back {d:.1}\n",
        .{ label, measured, @tagName(density), reserve },
    );
    return error.StatusWiderThanItsReserve;
}

// The same constant, wrong in the other direction.
//
// With no status at all the old 220 held that room back for a node that lays
// out 0x0, and it cost whole tabs. Measured in a fullscreen-shaped band (1920
// wide, no titlebar to ride, so no leading reserve and no status):
//
//   usable = 1904 - 220 = 1684 -> floor(1684/120) = 14 tabs
//   but 15 tabs need 15*120 + 14*4 + 4 + 32 = 1892, and the band is 1904
//
// so one visible tab was traded for 132pt of dead gutter. What this pins is
// not the number 15 — it is that the run is MAXIMAL: one more tab, at the
// narrowest a tab is allowed to be, would not have fit.
test "the tab run takes every tab the band actually has room for" {
    var model: app.Model = .{ .provider = undefined };
    model.ws().tab_count = app.max_tabs;

    // Fullscreen: `chrome_top` is zero, so the strip falls back to its own band
    // and there are no traffic lights to clear.
    const band = 1920 - app.grid_inset * 2;
    const window = app.visibleTabWindow(&model, band);
    try testing.expect(window.count > 0);
    try testing.expect(window.extent >= app.tab_min_extent);

    // Include the fixed two-ended overflow-cue reserve while windowed.
    const gap = app.chrome_band_inset;
    const drawn = @as(f32, @floatFromInt(window.count));
    const cues: f32 = if (window.windowed()) 2 * (app.chrome_hit_target + gap) else 0;
    const spent = drawn * window.extent + drawn * gap + app.chrome_control_extent + cues;
    try testing.expect(spent <= band + 0.5);

    // ...and one more, at the floor, would not have.
    if (window.count < model.ws().tab_count) {
        const one_more = (drawn + 1) * (app.tab_min_extent + gap) + app.chrome_control_extent + cues;
        if (one_more <= band) {
            std.debug.print(
                "\nthe strip drew {d} tabs in a {d:.0}pt band, but {d} at the {d:.0}pt floor " ++
                    "would have cost {d:.0} and fit\n",
                .{ window.count, band, window.count + 1, app.tab_min_extent, one_more },
            );
            return error.TabRunLeavesRoomUnused;
        }
    }
}
