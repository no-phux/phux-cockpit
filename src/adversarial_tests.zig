//! ADVERSARIAL PROBES, written by a validator who did not build this.
//!
//! These do not trust the build agents' tests. Each one is designed to
//! FAIL if the two panes are secretly sharing emulator state, sharing a
//! display-list id namespace, running with an unbounded (0) command
//! budget, or routing input to the wrong pty.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("main.zig");
const grid = @import("grid.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const TerminalApp = native_sdk.UiApp(app.Model, app.Msg);

fn createSessions(cols: u16, rows: u16) ![app.pane_count]*grid.Session {
    var sessions: [app.pane_count]*grid.Session = undefined;
    for (&sessions) |*slot| slot.* = try grid.Session.create(std.heap.page_allocator, testing.io, cols, rows);
    return sessions;
}

fn destroyModelSessions(model: *app.Model) void {
    app.deinitModel(model);
}

fn startCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &app.web_origins;
    harness.runtime.options.shortcuts = &app.cockpit_shortcuts;
    const sessions = try createSessions(80, 24);
    const app_state = try gpa.create(TerminalApp);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = app.canvas_label,
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = 200,
        .y = 200,
    } });
    try app_state.effects.feedPtyOutput(app.ptyKey(0), "PANEALPHA\r\n");
    try app_state.effects.feedPtyOutput(app.ptyKey(1), "PANEBRAVO\r\n");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    return app_state;
}

// ------------------------------------------------------- A1: state sharing

test "ADVERSARIAL: a torrent into pane 0 leaves pane 1's emulator bit-identical" {
    // If the two panes shared one `vt.Terminal` (or one `*Session`), a
    // hundred lines fed to pane 0 would move pane 1's cursor, its
    // scrollback offset, and its viewport text. Nothing here reads a
    // pane index out of the painter: it compares pane 1 to itself.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const model = &app_state.model;

    // Distinct heap objects, distinct emulators, distinct pty keys.
    try testing.expect(model.panes[0].session != model.panes[1].session);
    try testing.expect(&model.panes[0].session.term != &model.panes[1].session.term);
    try testing.expect(&model.panes[0].session.render != &model.panes[1].session.render);
    try testing.expect(model.panes[0].pty_key != model.panes[1].pty_key);
    try testing.expect(model.panes[0].session.response_buffer.ptr != model.panes[1].session.response_buffer.ptr);

    const before_text = try model.panes[1].session.plainText(gpa);
    defer gpa.free(before_text);
    const before_offset = model.panes[1].session.scrollbar().offset;
    const before_bytes = model.panes[1].output_bytes;
    const before_cols = model.panes[1].session.cols();
    const before_rows = model.panes[1].session.rows();

    var line: [64]u8 = undefined;
    for (0..300) |i| {
        const bytes = std.fmt.bufPrint(&line, "\x1b[3{d}mtorrent {d}\x1b[0m\r\n", .{ i % 8, i }) catch unreachable;
        try app_state.effects.feedPtyOutput(app.ptyKey(0), bytes);
        try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    }
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // Pane 0 really did move.
    const alpha = try model.panes[0].session.plainText(gpa);
    defer gpa.free(alpha);
    try testing.expect(std.mem.indexOf(u8, alpha, "torrent 299") != null);
    try testing.expect(model.panes[0].session.scrollbar().offset > 0);

    // Pane 1 did not, in ANY observable dimension.
    const after_text = try model.panes[1].session.plainText(gpa);
    defer gpa.free(after_text);
    try testing.expectEqualStrings(before_text, after_text);
    try testing.expectEqual(before_offset, model.panes[1].session.scrollbar().offset);
    try testing.expectEqual(before_bytes, model.panes[1].output_bytes);
    try testing.expectEqual(before_cols, model.panes[1].session.cols());
    try testing.expectEqual(before_rows, model.panes[1].session.rows());
    try testing.expect(std.mem.indexOf(u8, after_text, "torrent") == null);
    try testing.expect(std.mem.indexOf(u8, after_text, "PANEBRAVO") != null);
    // ...and pane 0 never learned pane 1's content either.
    try testing.expect(std.mem.indexOf(u8, alpha, "PANEBRAVO") == null);
}

test "ADVERSARIAL: a hard reset of pane 0 does not reset pane 1" {
    // `spawnPane` calls `session.reset()`. Shared emulator state would
    // blank the neighbour.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const model = &app_state.model;

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, model.panes[0].phase);
    try testing.expectEqual(app.Phase.live, model.panes[1].phase);

    // cmd+R restarts the FOCUSED (ended) pane; `spawnPane` hard-resets
    // its emulator. A shared emulator would blank the neighbour too.
    try pressKey(harness, app_iface, "r", .{ .primary = true });
    const alpha = try model.panes[0].session.plainText(gpa);
    defer gpa.free(alpha);
    const bravo = try model.panes[1].session.plainText(gpa);
    defer gpa.free(bravo);
    try testing.expect(std.mem.indexOf(u8, alpha, "PANEALPHA") == null); // reset
    try testing.expect(std.mem.indexOf(u8, bravo, "PANEBRAVO") != null); // untouched
}

// ---------------------------------------------- A2: id namespace collisions

/// Every object id in the list, checked for repeats. The retained diff
/// rejects a repeated id, so a collision is a whole failed frame.
fn expectNoDuplicateIds(gpa: std.mem.Allocator, commands: []const canvas.CanvasCommand) !void {
    var seen = std.AutoHashMap(canvas.ObjectId, usize).init(gpa);
    defer seen.deinit();
    for (commands, 0..) |command, index| {
        const id = command.objectId() orelse continue;
        const gop = try seen.getOrPut(id);
        if (gop.found_existing) {
            std.debug.print(
                "DUPLICATE ID 0x{x} at command {d} (first seen at {d})\n",
                .{ id, index, gop.value_ptr.* },
            );
            return error.DuplicateObjectId;
        }
        gop.value_ptr.* = index;
    }
}

test "ADVERSARIAL: hostile terminal tab switches retain collision-free ids" {
    // Each selected terminal drives every id-emitting path, then the
    // retained diff switches between their disjoint id namespaces.
    const gpa = testing.allocator;
    const sessions = try createSessions(120, 40);
    defer for (sessions) |each| each.destroy();

    var line: [4096]u8 = undefined;
    for (sessions, 0..) |session, pane| {
        for (0..200) |row| {
            var w: usize = 0;
            for (0..40) |col| {
                // Underline + strike + a distinct SGR per cell, then box
                // glyphs, so the run merger cannot collapse anything.
                const seq = std.fmt.bufPrint(line[w..], "\x1b[4;9;3{d}m\u{256C}\x1b[0m\u{2500}A", .{(col + row + pane) % 8}) catch break;
                w += seq.len;
            }
            session.feed(line[0..w]);
            session.feed("\r\n");
        }
        // Scrolled back, so the scrollbar thumb paints too.
        session.scrollLines(-5);
        session.beginSelection(false);
        session.moveSelection(20, 3, true);
    }

    var storage: [app.pane_count][]canvas.CanvasCommand = undefined;
    var allocated: usize = 0;
    defer for (storage[0..allocated]) |commands| gpa.free(commands);
    var lists: [app.pane_count]canvas.DisplayList = undefined;
    for (sessions, 0..) |session, index| {
        storage[index] = try gpa.alloc(canvas.CanvasCommand, 32 * 1024);
        allocated += 1;
        var builder = canvas.Builder.init(storage[index]);
        try grid.paint(session, &builder, .{
            .frame = geometry.RectF.init(226, 60, 746, 572),
            .background_frame = geometry.RectF.init(0, 0, 980, 640),
            .tokens = .{},
            .running = true,
            .focused = true,
            .selecting = true,
            .id_base = grid.paneIdBase(index),
        });
        lists[index] = builder.displayList();
        try testing.expect(lists[index].commands.len > 2000);
        try expectNoDuplicateIds(gpa, lists[index].commands);
    }
    const changes = try gpa.alloc(canvas.DiffChange, 64 * 1024);
    defer gpa.free(changes);
    _ = try canvas.DisplayList.diff(lists[0], lists[1], changes);
}

test "ADVERSARIAL: each selected terminal frame has unique ids and no hidden grid band" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    var line: [64]u8 = undefined;
    for (0..60) |i| {
        const bytes = std.fmt.bufPrint(&line, "\x1b[4;3{d}mrow {d} \u{2500}\u{256C}\x1b[0m\r\n", .{ i % 8, i }) catch unreachable;
        // Drain each batch: the fake pty's queue is short.
        try app_state.effects.feedPtyOutput(app.ptyKey(0), bytes);
        try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
        try app_state.effects.feedPtyOutput(app.ptyKey(1), bytes);
        try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    }
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    const stride: u64 = 1 << 24;
    const base0 = canvas.terminal_grid.paintIdBase(grid.paneIdBase(0));
    const base1 = canvas.terminal_grid.paintIdBase(grid.paneIdBase(1));
    for ([_]struct { key: []const u8, selected_base: u64, hidden_base: u64 }{
        .{ .key = "1", .selected_base = base0, .hidden_base = base1 },
        .{ .key = "2", .selected_base = base1, .hidden_base = base0 },
    }) |case| {
        try pressKey(harness, app_iface, case.key, .{ .primary = true });
        try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
        const list = harness.runtime.views[0].canvasDisplayList();
        try testing.expect(list.commands.len > 100);
        try expectNoDuplicateIds(gpa, list.commands);
        var selected_commands: usize = 0;
        var hidden_commands: usize = 0;
        for (list.commands) |command| {
            const id = command.objectId() orelse continue;
            if (id >= case.selected_base and id < case.selected_base + stride) selected_commands += 1;
            if (id >= case.hidden_base and id < case.hidden_base + stride) hidden_commands += 1;
        }
        try testing.expect(selected_commands > 20);
        try testing.expectEqual(@as(usize, 0), hidden_commands);
    }
}

test "ADVERSARIAL: split paints both hostile terminals inside one collision-free envelope" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(1100, 640) });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    feedHostileRows(app_state.model.panes[0].session, 58, 40);
    for (0..40) |_| {
        app_state.model.panes[1].session.feed("\u{256C}" ** 58);
        app_state.model.panes[1].session.feed("\r\n");
    }
    try pressKey(harness, app_iface, "d", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    const list = harness.runtime.views[0].canvasDisplayList();
    try expectNoDuplicateIds(gpa, list.commands);
    try testing.expect(list.commands.len <= native_sdk.runtime.max_canvas_commands_per_view);

    const stride: u64 = 1 << 24;
    var per_pane: [app.pane_count]usize = @splat(0);
    for (list.commands) |command| {
        const id = command.objectId() orelse continue;
        for (&per_pane, 0..) |*count, index| {
            const base = canvas.terminal_grid.paintIdBase(grid.paneIdBase(index));
            if (id >= base and id < base + stride) count.* += 1;
        }
    }
    try testing.expect(per_pane[0] > 20);
    try testing.expect(per_pane[1] > 20);
}

// --------------------------------------------------- A3/A4: budget reality

/// Rows the pane actually put on screen this paint.
fn paintedRows(commands: []const canvas.CanvasCommand) usize {
    var rows: [256]f32 = undefined;
    var count: usize = 0;
    outer: for (commands) |command| {
        switch (command) {
            .draw_text => |text| {
                for (rows[0..count]) |seen| if (seen == text.origin.y) continue :outer;
                if (count < rows.len) {
                    rows[count] = text.origin.y;
                    count += 1;
                }
            },
            else => {},
        }
    }
    return count;
}

fn feedHostileRows(session: *grid.Session, cols: usize, rows: usize) void {
    var line: [8192]u8 = undefined;
    for (0..rows) |_| {
        var w: usize = 0;
        for (0..cols) |col| {
            const seq = std.fmt.bufPrint(line[w..], "\x1b[{d}mX", .{if (col % 2 == 0) @as(u8, 31) else 32}) catch break;
            w += seq.len;
        }
        session.feed(line[0..w]);
        session.feed("\r\n");
    }
}

test "ADVERSARIAL: the selected terminal command envelope genuinely binds" {
    // A budget that was secretly 0 (unbounded) would still pass a test
    // that only asserts `len <= budget` on a quiet screen. This compares
    // the SAME hostile screen painted bounded vs unbounded: if the bound
    // did nothing, the two lists would be the same length.
    const gpa = testing.allocator;
    const session = try grid.Session.create(std.heap.page_allocator, testing.io, 60, 40);
    defer session.destroy();
    feedHostileRows(session, 60, 40);

    const big = try gpa.alloc(canvas.CanvasCommand, 32 * 1024);
    defer gpa.free(big);

    var unbounded = canvas.Builder.init(big);
    try grid.paint(session, &unbounded, .{
        .frame = geometry.RectF.init(0, 0, 480, 600),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .id_base = grid.paneIdBase(0),
    });
    const unbounded_len = unbounded.displayList().commands.len;

    const small = try gpa.alloc(canvas.CanvasCommand, 32 * 1024);
    defer gpa.free(small);
    var bounded = canvas.Builder.init(small);
    try grid.paint(session, &bounded, .{
        .frame = geometry.RectF.init(0, 0, 480, 600),
        .tokens = .{},
        .running = true,
        .selecting = false,
        .command_budget = app.chrome_command_envelope,
        .text_reserve = canvas.terminal_grid.widget_text_reserve,
        .glyph_budget = canvas.terminal_grid.widget_glyph_budget,
        .id_base = grid.paneIdBase(0),
    });
    const bounded_len = bounded.displayList().commands.len;

    std.debug.print(
        "\nMEASURED budget bind: unbounded={d} bounded={d} budget={d}\n",
        .{ unbounded_len, bounded_len, app.chrome_command_envelope },
    );
    try testing.expect(app.chrome_command_envelope > 0);
    try testing.expect(unbounded_len > app.chrome_command_envelope); // the screen CAN overflow
    try testing.expect(bounded_len < unbounded_len); // the bound truncated it
    try testing.expect(bounded_len <= app.chrome_command_envelope);
}

test "ADVERSARIAL: either selected terminal gets the same full hostile-content budget" {
    const gpa = testing.allocator;
    const sessions = try createSessions(58, 40);
    for (sessions) |session| feedHostileRows(session, 58, 40);

    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);
    var painted: [app.pane_count]usize = @splat(0);
    var used: [app.pane_count]usize = @splat(0);
    for (sessions, 0..) |session, index| {
        model.selected_tab = if (index == 0) .terminal_1 else .terminal_2;
        const frames = app.paneFrames(&model, geometry.SizeF.init(980, 640));
        try testing.expect(frames[index].width > 0);
        try testing.expectEqual(@as(f32, 0), frames[1 - index].width);

        const storage = try gpa.alloc(canvas.CanvasCommand, 32 * 1024);
        defer gpa.free(storage);
        var builder = canvas.Builder.init(storage);
        try grid.paint(session, &builder, .{
            .frame = frames[index],
            .background_frame = geometry.RectF.init(0, 0, 980, 640),
            .tokens = .{},
            .running = true,
            .focused = true,
            .selecting = false,
            .command_budget = app.chrome_command_envelope,
            .text_reserve = canvas.terminal_grid.widget_text_reserve,
            .glyph_budget = canvas.terminal_grid.widget_glyph_budget,
            .id_base = grid.paneIdBase(index),
        });
        used[index] = builder.displayList().commands.len;
        painted[index] = paintedRows(builder.displayList().commands);
        try testing.expect(used[index] <= app.chrome_command_envelope);
    }
    std.debug.print(
        "\nMEASURED selected symmetry: rows={{ {d}, {d} }} commands={{ {d}, {d} }} envelope={d}\n",
        .{ painted[0], painted[1], used[0], used[1], app.chrome_command_envelope },
    );
    try testing.expect(painted[0] >= 5);
    try testing.expectEqual(painted[0], painted[1]);
    try testing.expectEqual(used[0], used[1]);
}

// ------------------------------------------------------- A5/A6: input paths

fn pressKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = key,
        .modifiers = modifiers,
    } });
}

test "ADVERSARIAL: encoded KEYS (not just text) reach one pty only" {
    // The build agents' acceptance gate uses `.text_input`, which takes
    // the `sendCommittedText` path. Specials and chords take a different
    // path (`encodeKeyEvent`) through the emulator's own encoder, from
    // the SESSION of whichever pane is focused. A shared session would
    // put the bytes on the wrong stream.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressKey(harness, app_iface, "arrowup", .{});
    try pressKey(harness, app_iface, "tab", .{});
    const alpha_after_keys = app_state.effects.ptyWrittenBytes(app.ptyKey(0));
    try testing.expect(alpha_after_keys.len > 0);
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));

    // Move focus and repeat: the bytes must switch streams entirely.
    try pressKey(harness, app_iface, "2", .{ .primary = true });
    try testing.expectEqual(app.Placement.secondary, app_state.model.focus_placement);
    try pressKey(harness, app_iface, "arrowup", .{});
    try testing.expect(app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len > 0);
    // Pane 0's stream did not grow.
    try testing.expectEqualStrings(alpha_after_keys, app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
}

test "ADVERSARIAL: the focus chord itself never leaks a byte to either child" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Press AND release under kitty release reporting. The release omits
    // Command to model the modifier coming up first; the model-level
    // physical-key latch must still recognize and swallow it.
    for (app_state.model.panes) |*pane| pane.session.feed("\x1b[>11u");
    try pressKey(harness, app_iface, "2", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = "2",
        .modifiers = .{},
    } });
    std.debug.print(
        "\nMEASURED chord leak: pane0={d} bytes pane1={d} bytes\n",
        .{ app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len, app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len },
    );
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "ADVERSARIAL: a wheel over native tab chrome reaches neither terminal" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const model = &app_state.model;

    var line: [32]u8 = undefined;
    for (0..200) |i| {
        const bytes = std.fmt.bufPrint(&line, "history {d}\r\n", .{i}) catch unreachable;
        model.panes[0].session.feed(bytes);
        model.panes[1].session.feed(bytes);
    }
    for (2..8) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = size,
            .scale_factor = 2,
            .frame_index = @intCast(frame_index),
            .timestamp_ns = @as(u64, frame_index) * 1_000_000,
        } });
    }
    try testing.expect(model.surface_size.width > 0);

    const bottom0 = model.panes[0].session.scrollbar().offset;
    const bottom1 = model.panes[1].session.scrollbar().offset;
    try testing.expect(bottom0 > 0 and bottom1 > 0);
    try testing.expectEqual(app.TabId.terminal_1, model.selected_tab);
    const cell_h = model.panes[0].session.cell_height;
    for (0..6) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .scroll,
            .x = 100,
            .y = 30,
            .delta_y = cell_h,
        } });
    }
    std.debug.print(
        "\nMEASURED rail wheel isolation: pane0 {d}->{d}  pane1 {d}->{d}\n",
        .{ bottom0, model.panes[0].session.scrollbar().offset, bottom1, model.panes[1].session.scrollbar().offset },
    );
    try testing.expectEqual(bottom0, model.panes[0].session.scrollbar().offset);
    try testing.expectEqual(bottom1, model.panes[1].session.scrollbar().offset);
}

test "ADVERSARIAL: split wheel routing scrolls only the pane under the pointer" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const model = &app_state.model;

    for (model.panes) |*pane| {
        var line: [32]u8 = undefined;
        for (0..200) |i| pane.session.feed(std.fmt.bufPrint(&line, "history {d}\r\n", .{i}) catch unreachable);
    }
    try pressKey(harness, app_iface, "d", .{ .primary = true });
    for (2..8) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = size,
            .scale_factor = 2,
            .frame_index = @intCast(frame_index),
            .timestamp_ns = @as(u64, frame_index) * 1_000_000,
        } });
    }
    const frames = app.paneFrames(model, size);
    const bottom0 = model.panes[0].session.scrollbar().offset;
    const bottom1 = model.panes[1].session.scrollbar().offset;
    try testing.expect(bottom0 > 0 and bottom1 > 0);

    for (0..4) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .scroll,
            .x = frames[1].x + frames[1].width / 2,
            .y = frames[1].y + frames[1].height / 2,
            .delta_y = model.panes[1].session.cell_height,
        } });
    }
    try testing.expectEqual(bottom0, model.panes[0].session.scrollbar().offset);
    try testing.expect(model.panes[1].session.scrollbar().offset < bottom1);
}

test "REGRESSION: the selected Terminal 2 frame receives wheel input before the first frame" {
    const gpa = testing.allocator;
    const size = geometry.SizeF.init(1100, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();
    const model = &app_state.model;

    // The mirror is live before any frame, and the rects it yields are real.
    try testing.expectEqual(size.width, model.surface_size.width);
    try testing.expectEqual(size.height, model.surface_size.height);
    try pressKey(harness, app_iface, "2", .{ .primary = true });
    try testing.expectEqual(app.TabId.terminal_2, model.selected_tab);
    try testing.expectEqual(@as(f32, 0), app.paneFrames(model, model.surface_size)[0].width);
    try testing.expect(app.paneFrames(model, model.surface_size)[1].width > 0);

    var line: [32]u8 = undefined;
    for (0..200) |i| {
        const bytes = std.fmt.bufPrint(&line, "history {d}\r\n", .{i}) catch unreachable;
        model.panes[0].session.feed(bytes);
        model.panes[1].session.feed(bytes);
    }
    const bottom0 = model.panes[0].session.scrollbar().offset;
    const bottom1 = model.panes[1].session.scrollbar().offset;

    // Aim squarely at the selected Terminal 2 surface.
    try testing.expectEqual(app.Placement.secondary, model.focus_placement);
    const target = app.paneFrames(model, model.surface_size)[1];
    const cell_h = model.panes[1].session.cell_height;
    for (0..6) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .scroll,
            .x = target.x + target.width / 2,
            .y = target.y + target.height / 2,
            .delta_y = cell_h,
        } });
    }
    // Terminal 2 scrolled; hidden Terminal 1 did not.
    try testing.expect(model.panes[1].session.scrollbar().offset < bottom1);
    try testing.expectEqual(bottom0, model.panes[0].session.scrollbar().offset);
}

// -------------------------------------------------- A7: the validator's eyes

const validator_shot_path = "zig-out/validator-native-split.png";

test "ADVERSARIAL: native-split proof shot preserves both independent terminals (env-gated)" {
    if (comptime !@import("builtin").link_libc) return error.SkipZigTest;
    if (std.c.getenv("COCKPIT_SHOTS") == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    const size = geometry.SizeF.init(980, 640);
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = size });
    defer harness.destroy(gpa);
    const app_state = try startCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Let the frame pump measure the surface so the panes take their
    // real grids.
    for (2..8) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = size,
            .scale_factor = 2,
            .frame_index = @intCast(frame_index),
            .timestamp_ns = @as(u64, frame_index) * 1_000_000,
        } });
    }

    var line: [128]u8 = undefined;
    for (0..14) |i| {
        try app_state.effects.feedPtyOutput(app.ptyKey(0), std.fmt.bufPrint(
            &line,
            "\x1b[32mLEFT\x1b[0m  build step {d}/14 \u{2500}\u{2500}\u{2500} ok\r\n",
            .{i + 1},
        ) catch unreachable);
        try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
        try app_state.effects.feedPtyOutput(app.ptyKey(1), std.fmt.bufPrint(
            &line,
            "\x1b[1;35mRIGHT\x1b[0m Tue Jul 27 04:0{d}:00 PDT 2026\r\n",
            .{i % 10},
        ) catch unreachable);
        try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    }
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // Both streams landed on their own emulator while only one surface
    // was visible, and neither saw the other's marker.
    const left = app_state.model.panes[0].session.screenText();
    const right = app_state.model.panes[1].session.screenText();
    try testing.expect(std.mem.indexOf(u8, left, "build step 14/14") != null);
    try testing.expect(std.mem.indexOf(u8, left, "RIGHT") == null);
    try testing.expect(std.mem.indexOf(u8, right, "Tue Jul 27") != null);
    try testing.expect(std.mem.indexOf(u8, right, "LEFT") == null);

    // Capture both sessions through the real split substrate.
    try pressKey(harness, app_iface, "d", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, app.canvas_label, null);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const shot = try harness.runtime.renderCanvasScreenshot(1, app.canvas_label, null, pixels, scratch);
    const encoded = try gpa.alloc(u8, try canvas.png.encodedRgba8ByteLen(shot.width, shot.height));
    defer gpa.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, shot.width, shot.height, shot.rgba8);
    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = validator_shot_path, .data = writer.buffered() });
}
