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
        app.chrome_band_height,  app.chrome_band_inset,   app.chrome_control_extent,
        app.chrome_icon_extent,  app.chrome_gap,          app.chrome_hit_target,
        app.tab_height,          app.tab_extent,          app.tab_min_extent,
        app.side_tab_height,     app.side_rail_width,     app.side_rail_gap,
        app.split_divider_width, app.search_bar_height,   app.config_notice_height,
        app.palette_width,       app.palette_row_height,  app.palette_padding,
        app.palette_top_inset,   app.settings_width,      app.settings_row_height,
        app.settings_padding,    app.settings_margin,     app.field_caret_width,
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

    // As FULL a strip as this machine will give. The window derivation is what
    // keeps it honest at the narrow end, and it is exactly where a tab that
    // outgrew its own furniture would show up.
    //
    // The loop is bounded by the chord count rather than by the tab count, and
    // that is not defensive style — an unbounded `while (tab_count < max_tabs)`
    // spun this test at 100% CPU for twenty-five minutes, because cmd+T stops
    // producing tabs at the SHELL ceiling and a refusal that does not latch
    // leaves the condition permanently false.
    for (0..app.max_tabs) |_| {
        try support.pressCanvasKey(harness, iface, "t", .{ .primary = true });
    }
    try testing.expect(state.model.ws().tab_count > 1);
    try sweep(state, "as full a tab strip as we can open");

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

    state.model.tab_placement = .side;
    try sweep(state, "the side rail");
}
