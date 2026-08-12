//! Theming, the settings surface, and the legibility readout.
//!
//! `config_tests.zig` proves the parser and `config_wiring_tests.zig` proves
//! each knob reaches something. This file proves the three properties that
//! make `phux-cockpit-q4z` worth having:
//!
//!   1. the owner can name a theme and an explicit key still wins over it;
//!   2. the settings surface is MODAL and stays readable when the theme it is
//!      there to fix is broken;
//!   3. the contrast readout reports the WCAG number for the colours actually
//!      being painted, not for the ones the config meant to ask for.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const grid = @import("../terminal/grid.zig");
const support = @import("support.zig");
// The two pure modules directly, the way `config_tests.zig` does: `Rgb` and
// `Diagnostic` are module-level declarations, not members of `Config`.
const config = @import("../config/config.zig");
const theme = @import("../config/theme.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const startCockpit = support.startCockpit;
const stopCockpit = support.stopCockpit;
const startFocusedTerminal = support.startFocusedTerminal;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;
const typeCanvasText = support.typeCanvasText;
const destroyModelSessions = app.deinitModel;

// -------------------------------------------------------------- the formula

test "the contrast ratio is the WCAG one, checked against published values" {
    // Black on white is the ceiling the WCAG definition produces by
    // construction: (1.0 + 0.05) / (0.0 + 0.05) = 21.
    try expectClose(21.0, app.contrastRatio(black, white), 0.001);
    // A colour against itself is the floor.
    try expectClose(1.0, app.contrastRatio(white, white), 0.0001);
    try expectClose(1.0, app.contrastRatio(black, black), 0.0001);
    // SYMMETRIC. "Is this readable" is not a question about which one is ink.
    try expectClose(app.contrastRatio(black, white), app.contrastRatio(white, black), 0.0001);

    // #767676 on white is the canonical AA boundary grey — the darkest grey
    // that still clears 4.5:1, and the reason it is quoted everywhere is that
    // one 8-bit step lighter (#777777) does not. Getting BOTH right is what
    // pins the gamma curve: a linear (un-gamma'd) luminance puts these two at
    // roughly 2.4 and 2.37, on the wrong side of the threshold, and a curve
    // with the wrong exponent moves them across it.
    try expectClose(4.542, app.contrastRatio(rgb(0x76, 0x76, 0x76), white), 0.01);
    try expectClose(4.478, app.contrastRatio(rgb(0x77, 0x77, 0x77), white), 0.01);
    try testing.expect(app.contrastRatio(rgb(0x76, 0x76, 0x76), white) >= app.wcag_aa_body_text);
    try testing.expect(app.contrastRatio(rgb(0x77, 0x77, 0x77), white) < app.wcag_aa_body_text);

    // Two more with published values, so the 0.2126/0.7152/0.0722 weighting is
    // pinned and not only the curve: pure blue on white is 8.59:1 and mid-grey
    // on black is 5.32:1.
    try expectClose(8.592, app.contrastRatio(rgb(0x00, 0x00, 0xff), white), 0.01);
    try expectClose(5.317, app.contrastRatio(rgb(0x80, 0x80, 0x80), black), 0.01);
}

test "the grade bands sit exactly on the WCAG thresholds" {
    try testing.expectEqual(app.Legibility.fails_aa, app.Legibility.of(4.49));
    try testing.expectEqual(app.Legibility.passes_aa, app.Legibility.of(4.5));
    try testing.expectEqual(app.Legibility.passes_aa, app.Legibility.of(6.99));
    try testing.expectEqual(app.Legibility.passes_aaa, app.Legibility.of(7.0));
    try testing.expect(!app.Legibility.of(1.0).readable());
    try testing.expect(app.Legibility.of(21.0).readable());
}

test "every built-in theme clears the readout's own AA threshold" {
    // A theme the app's own legibility readout would flag is advice nobody can
    // act on. This is the test that keeps the shipped set honest.
    for (app.builtin_themes) |entry| {
        const ratio = app.contrastRatio(entry.foreground, entry.background);
        testing.expect(ratio >= app.wcag_aa_body_text) catch |err| {
            std.debug.print(
                "theme '{s}' contrast {d:.2}:1 is below the AA minimum {d}\n",
                .{ entry.name, ratio, app.wcag_aa_body_text },
            );
            return err;
        };
    }
    // And the names are unique, or `themeByName` would silently shadow one.
    for (app.builtin_themes, 0..) |a, i| {
        for (app.builtin_themes, 0..) |b, j| {
            if (i == j) continue;
            try testing.expect(!std.ascii.eqlIgnoreCase(a.name, b.name));
        }
    }
}

// ----------------------------------------------------------- theme in config

test "an unknown theme name is a diagnostic and is not stored" {
    const parsed = app.parseConfig("theme = no-such-theme");
    try testing.expectEqual(@as(usize, 0), parsed.theme.slice().len);
    try testing.expectEqual(@as(usize, 1), parsed.diagnosticSlice().len);
    try testing.expectEqual(config.Diagnostic.Kind.bad_value, parsed.diagnosticSlice()[0].kind);
    // ...and a known one is stored with no complaint.
    const good = app.parseConfig("theme = nord");
    try testing.expectEqualStrings("nord", good.theme.slice());
    try testing.expectEqual(@as(usize, 0), good.diagnosticSlice().len);
}

test "an explicit colour outranks the theme, whichever line comes first" {
    const nord = app.themeByName("nord") orelse return error.TestExpectedTheme;

    // A theme alone fills all three in.
    const themed = app.parseConfig("theme = nord");
    try testing.expectEqual(nord.foreground.r, (themed.resolvedForeground() orelse return error.TestExpectedColor).r);
    try testing.expectEqual(nord.background.b, (themed.resolvedBackground() orelse return error.TestExpectedColor).b);
    try testing.expectEqual(nord.selection_background.g, (themed.resolvedSelectionBackground() orelse return error.TestExpectedColor).g);

    // THE precedence: an explicit key wins. Both orderings, because resolving
    // at parse time would make this order-sensitive and only one of the two
    // would pass.
    const key_first = app.parseConfig("foreground = #ff0000\ntheme = nord");
    const key_last = app.parseConfig("theme = nord\nforeground = #ff0000");
    for ([_]config.Config{ key_first, key_last }) |cfg| {
        const fg = cfg.resolvedForeground() orelse return error.TestExpectedColor;
        try testing.expectEqual(@as(u8, 0xff), fg.r);
        try testing.expectEqual(@as(u8, 0x00), fg.g);
        try testing.expectEqual(@as(u8, 0x00), fg.b);
        // The keys NOT written still come from the theme — an explicit
        // foreground must not throw the rest of the theme away.
        try testing.expectEqual(nord.background.r, (cfg.resolvedBackground() orelse return error.TestExpectedColor).r);
    }

    // No theme and no key resolves to null, which means "the app's own
    // register" and is not the same as black.
    const bare = app.parseConfig("font-size = 14");
    try testing.expectEqual(@as(?config.Rgb, null), bare.resolvedForeground());
    try testing.expectEqual(@as(?config.Rgb, null), bare.resolvedBackground());
}

test "a theme reaches the terminal tokens, and only when it is named" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    const nord = app.themeByName("nord") orelse return error.TestExpectedTheme;
    const nord_text = canvas.Color.rgb8(nord.foreground.r, nord.foreground.g, nord.foreground.b);

    // ABSENT first. Without this the assertion below could pass on a build
    // where the tokens were nord's all along.
    state.model.config = app.parseConfig("");
    try testing.expect(!std.meta.eql(nord_text, app.terminalTokens(&state.model).colors.text));

    // ...then present.
    state.model.config = app.parseConfig("theme = nord");
    const themed = app.terminalTokens(&state.model);
    try testing.expectEqual(nord_text, themed.colors.text);
    try testing.expectEqual(
        canvas.Color.rgb8(nord.background.r, nord.background.g, nord.background.b),
        themed.colors.background,
    );

    // The CHROME register does not move with it. The tab strip is not the
    // terminal, and a theme that repainted the chrome is exactly what would
    // take the settings surface down with it.
    const chrome_before = app.cockpitTokens(&state.model);
    state.model.config = app.parseConfig("theme = high-contrast");
    try testing.expectEqual(chrome_before.colors.text, app.cockpitTokens(&state.model).colors.text);
    try testing.expectEqual(chrome_before.colors.surface, app.cockpitTokens(&state.model).colors.surface);
}

test "the readout measures the painted tokens, config or theme or neither" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);

    // The app's own default register is comfortably readable.
    state.model.config = app.parseConfig("");
    try testing.expect(app.legibility(&state.model).readable());

    // A theme's number matches the theme table's own arithmetic, which is what
    // says the readout is measuring the thing that gets painted.
    const solarized = app.themeByName("solarized-dark") orelse return error.TestExpectedTheme;
    state.model.config = app.parseConfig("theme = solarized-dark");
    try expectClose(
        app.contrastRatio(solarized.foreground, solarized.background),
        app.legibility(&state.model).ratio,
        0.01,
    );

    // THE case the whole feature exists for: text you cannot see. An explicit
    // foreground equal to the background is 1.0:1 and the readout says so.
    state.model.config = app.parseConfig("foreground = #101010\nbackground = #101010");
    const invisible = app.legibility(&state.model);
    try expectClose(1.0, invisible.ratio, 0.0001);
    try testing.expect(!invisible.readable());
    try testing.expectEqual(app.Legibility.fails_aa, invisible.grade);

    // And an explicit key over a theme is measured as the EXPLICIT key, so the
    // readout cannot report a theme the user has already overridden. The pair
    // here is #101010 (the key) on #000000 (high-contrast's ground) — 1.10:1,
    // not high-contrast's own 21:1, and not 1.00:1 either.
    const high_contrast = app.themeByName("high-contrast") orelse return error.TestExpectedTheme;
    state.model.config = app.parseConfig("theme = high-contrast\nforeground = #101010");
    try expectClose(
        app.contrastRatio(.{ .r = 0x10, .g = 0x10, .b = 0x10 }, high_contrast.background),
        app.legibility(&state.model).ratio,
        0.001,
    );
    try testing.expect(!app.legibility(&state.model).readable());
}

// ------------------------------------------------------- the settings surface

test "cmd+, opens settings and nothing typed into it reaches the pty" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(state);
    defer destroyModelSessions(&state.model);
    defer state.deinit();
    const iface = state.app();
    const pane = &state.model.provider.slots[0];

    try harness.runtime.dispatchPlatformEvent(iface, .wake);

    // ABSENT: the panel is not open, and ordinary typing DOES reach the child.
    // Without this half, "the child heard nothing" below would also pass on a
    // build where nothing ever reaches the child.
    try testing.expect(!state.model.ws().settings.open);
    const idle_before = state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try typeCanvasText(harness, iface, "z");
    try testing.expect(state.effects.ptyWrittenBytes(app.ptyKey(0)).len > idle_before);

    try pressCanvasKey(harness, iface, ",", .{ .primary = true });
    try releaseCanvasKey(harness, iface, ",", .{ .primary = true });
    try testing.expect(state.model.ws().settings.open);

    // Every one of these would otherwise be shell input or an app chord.
    const written_before = state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try typeCanvasText(harness, iface, "q");
    try typeCanvasText(harness, iface, "u");
    try typeCanvasText(harness, iface, "i");
    try typeCanvasText(harness, iface, "t");
    try pressCanvasKey(harness, iface, "tab", .{});
    try pressCanvasKey(harness, iface, "home", .{ .primary = true });
    try pressCanvasKey(harness, iface, "c", .{ .control = true });
    try pressCanvasKey(harness, iface, "t", .{ .primary = true });

    // THE contract: the child heard none of it, and cmd+T did not open a tab
    // behind the panel either.
    try testing.expectEqual(written_before, state.effects.ptyWrittenBytes(app.ptyKey(0)).len);
    try testing.expectEqual(@as(u64, 0), pane.outbound_dropped);
    try testing.expectEqual(@as(usize, 1), state.model.ws().tab_count);

    // Escape gives the keyboard back.
    try pressCanvasKey(harness, iface, "escape", .{});
    try testing.expect(!state.model.ws().settings.open);
    const reopened = state.effects.ptyWrittenBytes(app.ptyKey(0)).len;
    try typeCanvasText(harness, iface, "z");
    try testing.expect(state.effects.ptyWrittenBytes(app.ptyKey(0)).len > reopened);
}

test "arrow keys preview a theme live and escape puts back the one in effect" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    state.model.config = app.parseConfig("theme = nord");
    const nord_text = app.terminalTokens(&state.model).colors.text;

    try pressCanvasKey(harness, iface, ",", .{ .primary = true });
    try releaseCanvasKey(harness, iface, ",", .{ .primary = true });
    // The cursor opens ON the theme in effect rather than at row zero.
    try testing.expectEqual(
        app.themeIndexOf("nord") orelse return error.TestExpectedTheme,
        state.model.ws().settings.cursor,
    );

    // One step LIVE-APPLIES the next theme: the painted tokens move with no
    // commit and no frame in between.
    try pressCanvasKey(harness, iface, "arrowdown", .{});
    const previewed = app.terminalTokens(&state.model).colors.text;
    try testing.expect(!std.meta.eql(nord_text, previewed));
    try testing.expect(!std.mem.eql(u8, "nord", state.model.config.theme.slice()));

    // Escape CANCELS the preview, not merely the panel.
    try pressCanvasKey(harness, iface, "escape", .{});
    try testing.expect(!state.model.ws().settings.open);
    try testing.expectEqualStrings("nord", state.model.config.theme.slice());
    try testing.expectEqual(nord_text, app.terminalTokens(&state.model).colors.text);
}

test "return keeps the previewed theme and writes it to the config file" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tempConfigPath(&path_buf, "commit");
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    // A file with a comment, an unknown key, and a real setting in it — the
    // three kinds of byte the writer has to leave alone.
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = path,
        .data = "# my terminal\nfont-size = 15\nsome-future-key = 3\n",
    });
    state.model.config_file.setPath(path);
    state.model.config = app.parseConfig("theme = nord");

    try pressCanvasKey(harness, iface, ",", .{ .primary = true });
    try releaseCanvasKey(harness, iface, ",", .{ .primary = true });
    try pressCanvasKey(harness, iface, "arrowdown", .{});
    const chosen = state.model.config.theme;
    try pressCanvasKey(harness, iface, "enter", .{});

    try testing.expect(!state.model.ws().settings.open);
    try testing.expectEqualStrings(chosen.slice(), state.model.config.theme.slice());

    var read_buf: [4096]u8 = undefined;
    const written = try readWholeFile(path, &read_buf);
    // The choice is there...
    try testing.expect(std.mem.indexOf(u8, written, chosen.slice()) != null);
    // ...and so is every byte that was already in the file.
    try testing.expect(std.mem.indexOf(u8, written, "# my terminal") != null);
    try testing.expect(std.mem.indexOf(u8, written, "font-size = 15") != null);
    try testing.expect(std.mem.indexOf(u8, written, "some-future-key = 3") != null);
    // And it survives a re-read, which is the property that makes it persist.
    const reloaded = app.parseConfig(written);
    try testing.expectEqualStrings(chosen.slice(), reloaded.theme.slice());
    try testing.expectEqual(@as(f32, 15), reloaded.font_size);
}

// -------------------------------------------------- the panel stays readable

test "the settings surface stays readable when the theme is broken" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const state = try startCockpit(harness);
    defer stopCockpit(state);
    const iface = state.app();

    // Invisible text: foreground identical to background, which is the exact
    // shape of the complaint behind `phux-cockpit-aht`.
    state.model.config = app.parseConfig("foreground = #101010\nbackground = #101010");
    try testing.expect(!app.legibility(&state.model).readable());

    try pressCanvasKey(harness, iface, ",", .{ .primary = true });
    try releaseCanvasKey(harness, iface, ",", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);

    const ground = panelGround(harness) orelse return error.TestExpectedSettingsPanel;
    var broken: [64]Ink = undefined;
    const broken_count = collectPanelInk(harness, &broken);
    // The panel is really on screen and really has labels to check.
    try testing.expect(broken_count >= 6);

    // EVERY label the panel paints clears WCAG AA against the panel's own
    // ground — measured, not asserted equal to a constant, so a future change
    // that swaps the palette for a different fixed one still has to keep it
    // readable.
    //
    // The PANEL ground is the one measured, not the raised ground a
    // highlighted row and the readout sit on. Every ink in the `settings_*`
    // block scores higher against #101010 than against #262626, so this is the
    // more lenient of the two by a known margin; the raised ground's own
    // numbers are measured and recorded in the constants block, all of them
    // above 4.5:1.
    for (broken[0..broken_count]) |ink| {
        const ratio = app.contrastRatioLuminance(
            app.relativeLuminance(ink.color.r, ink.color.g, ink.color.b),
            app.relativeLuminance(ground.r, ground.g, ground.b),
        );
        testing.expect(ratio >= app.wcag_aa_body_text) catch |err| {
            std.debug.print(
                "settings label '{s}' is {d:.2}:1 against the panel ground, below AA\n",
                .{ ink.text, ratio },
            );
            return err;
        };
    }

    // ...and the colours are IDENTICAL to the ones a healthy theme produces.
    // Readable-by-luck is not the property; independence from the theme is.
    state.model.config = app.parseConfig("theme = phux-light");
    try harness.runtime.dispatchPlatformEvent(iface, .frame_requested);
    var healthy: [64]Ink = undefined;
    const healthy_count = collectPanelInk(harness, &healthy);
    try testing.expectEqual(broken_count, healthy_count);
    for (broken[0..broken_count], healthy[0..healthy_count]) |a, b| {
        try testing.expectEqualStrings(a.text, b.text);
        try testing.expectEqual(a.color, b.color);
    }
    try testing.expectEqual(ground, panelGround(harness) orelse return error.TestExpectedSettingsPanel);
}

// ------------------------------------------------------------- the file write

test "writing a key preserves comments, unknown keys, and everything else" {
    var out: [1024]u8 = undefined;

    // Replaced IN PLACE, keeping its position and every neighbouring byte.
    const source =
        \\# a comment nobody may delete
        \\font-size = 15
        \\theme = nord
        \\some-future-key = 3
        \\
    ;
    const replaced = try app.setConfigKey(source, "theme", "gruvbox-dark", &out);
    try testing.expectEqualStrings(
        \\# a comment nobody may delete
        \\font-size = 15
        \\theme = gruvbox-dark
        \\some-future-key = 3
        \\
    , replaced);

    // Appended when the key is absent, and nothing else is touched.
    var out2: [1024]u8 = undefined;
    const appended = try app.setConfigKey("font-size = 15\n", "theme", "nord", &out2);
    try testing.expectEqualStrings("font-size = 15\ntheme = nord\n", appended);

    // An empty file becomes a one-line file rather than a file starting with
    // a stray newline.
    var out3: [1024]u8 = undefined;
    try testing.expectEqualStrings("theme = nord\n", try app.setConfigKey("", "theme", "nord", &out3));

    // A final line with no newline still gets one before the append.
    var out4: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "font-size = 15\ntheme = nord\n",
        try app.setConfigKey("font-size = 15", "theme", "nord", &out4),
    );

    // A COMMENTED-OUT key is somebody's note, not an assignment: it stays put
    // and the live key is added separately.
    var out5: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "# theme = nord\ntheme = phux-light\n",
        try app.setConfigKey("# theme = nord\n", "theme", "phux-light", &out5),
    );

    // Duplicates COLLAPSE. The parser is last-wins, so leaving the second line
    // would mean this function returned success and the setting still did not
    // take effect.
    var out6: [1024]u8 = undefined;
    const collapsed = try app.setConfigKey(
        "theme = nord\nfont-size = 15\ntheme = solarized-dark\n",
        "theme",
        "high-contrast",
        &out6,
    );
    try testing.expectEqualStrings("theme = high-contrast\nfont-size = 15\n", collapsed);
    try testing.expectEqualStrings("high-contrast", app.parseConfig(collapsed).theme.slice());

    // CRLF stays CRLF: a file edited on one platform must not change shape
    // because the app touched one line of it.
    var out7: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "font-size = 15\r\ntheme = nord\r\n",
        try app.setConfigKey("font-size = 15\r\ntheme = phux-dark\r\n", "theme", "nord", &out7),
    );

    // A buffer that cannot hold the result REFUSES rather than truncating a
    // person's config into a shorter, differently-meaning file.
    var tiny: [8]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, app.setConfigKey(source, "theme", "nord", &tiny));
}

// ------------------------------------------------------------------ helpers

const black = theme.Rgb{ .r = 0, .g = 0, .b = 0 };
const white = theme.Rgb{ .r = 255, .g = 255, .b = 255 };

fn rgb(r: u8, g: u8, b: u8) theme.Rgb {
    return .{ .r = r, .g = g, .b = b };
}

fn expectClose(expected: f32, actual: f32, tolerance: f32) !void {
    if (@abs(expected - actual) <= tolerance) return;
    std.debug.print("expected {d:.4} +/- {d}, got {d:.4}\n", .{ expected, tolerance, actual });
    return error.TestUnexpectedResult;
}

const Ink = struct {
    text: []const u8,
    color: canvas.Color,
};

/// The settings panel's own ground, read off the tree rather than copied from
/// the view's constants — the invariant is about the colour actually painted.
fn panelGround(harness: anytype) ?canvas.Color {
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (!std.mem.eql(u8, node.widget.semantics.label, app.settings_panel_label)) continue;
        if (node.widget.style.background) |background| return background;
    }
    return null;
}

/// Every piece of TEXT the settings panel paints, with the colour it paints
/// in. The two live swatches are excluded by name: they deliberately show the
/// user's own pair, which is the one thing in the panel allowed to be
/// unreadable.
fn collectPanelInk(harness: anytype, out: []Ink) usize {
    const panel = panelFrame(harness) orelse return 0;
    var count: usize = 0;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (count >= out.len) break;
        if (node.widget.text.len == 0) continue;
        if (std.mem.eql(u8, node.widget.semantics.label, app.settings_sample_label)) continue;
        if (!contains(panel, node.frame)) continue;
        const color = node.widget.style.foreground orelse continue;
        out[count] = .{ .text = node.widget.text, .color = color };
        count += 1;
    }
    return count;
}

fn panelFrame(harness: anytype) ?geometry.RectF {
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, app.settings_panel_label)) return node.frame;
    }
    return null;
}

fn contains(outer: geometry.RectF, inner: geometry.RectF) bool {
    return inner.x >= outer.x and inner.y >= outer.y and
        inner.x + inner.width <= outer.x + outer.width + 0.5 and
        inner.y + inner.height <= outer.y + outer.height + 0.5;
}

/// A throwaway path under `/tmp`. Hardcoded rather than read from `$TMPDIR`
/// (this build's std exposes neither `posix.getenv` nor `time.nanoTimestamp`),
/// and the test WRITES the file before reading it, so a leftover from an
/// earlier run is overwritten rather than believed.
fn tempConfigPath(storage: []u8, tag: []const u8) ![]const u8 {
    return std.fmt.bufPrint(storage, "/tmp/phux-cockpit-test-{s}.config", .{tag});
}

fn readWholeFile(path: []const u8, storage: []u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(testing.io, path, .{});
    defer file.close(testing.io);
    const read = try file.readPositionalAll(testing.io, storage, 0);
    return storage[0..read];
}

