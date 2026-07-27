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
    for (&model.panes) |*pane| pane.session.destroy();
}

fn startCockpit(gpa: std.mem.Allocator, harness: anytype) !*TerminalApp {
    harness.null_platform.gpu_surfaces = true;
    const sessions = try createSessions(80, 24);
    const app_state = try gpa.create(TerminalApp);
    app_state.* = TerminalApp.init(std.heap.page_allocator, app.initialModel(sessions), app.appOptions());
    app_state.effects.executor = .fake;
    const app_iface = app_state.app();
    try harness.start(app_iface);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
        .label = "terminal-canvas",
        .size = geometry.SizeF.init(980, 640),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
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

test "ADVERSARIAL: no two commands in a hostile two-pane frame share an id" {
    // The recon flagged `grid_id_base` / `cursor_command_id` as a real
    // collision risk. This drives BOTH panes into every id-emitting path
    // at once — background, clip, row backgrounds, text runs, underlines,
    // strikethroughs, box geometry, selection wash, the cursor, and the
    // scrollbar thumb — at the widest grid the clamp allows, and scans
    // the WHOLE list rather than probing two known ids.
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

    const commands = try gpa.alloc(canvas.CanvasCommand, 64 * 1024);
    defer gpa.free(commands);
    var builder = canvas.Builder.init(commands);
    for (sessions, 0..) |session, index| {
        try grid.paint(session, &builder, .{
            .frame = geometry.RectF.init(@as(f32, @floatFromInt(index)) * 490, 36, 480, 600),
            .background_frame = if (index == 0) geometry.RectF.init(0, 0, 980, 640) else null,
            .tokens = .{},
            .running = true,
            .focused = index == 0,
            .selecting = true,
            // NOTE: unbounded on purpose. A budget would truncate the
            // rows before the high row ids could ever collide, which
            // would make this probe vacuous.
            .id_base = grid.paneIdBase(index),
        });
    }
    const list = builder.displayList();
    try testing.expect(list.commands.len > 2000); // the probe is not empty
    try expectNoDuplicateIds(gpa, list.commands);
}

test "ADVERSARIAL: the live frame's ids are unique across grids AND widgets" {
    // The unit probe above paints grids only. This one takes the REAL
    // retained display list the runtime holds — chrome prefix plus the
    // widget header, the badges, and the button — and scans all of it.
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

    const list = harness.runtime.views[0].canvasDisplayList();
    try testing.expect(list.commands.len > 100);
    try expectNoDuplicateIds(gpa, list.commands);

    // And the grids' bands really are disjoint from each other.
    var pane0: usize = 0;
    var pane1: usize = 0;
    for (list.commands) |command| {
        const id = command.objectId() orelse continue;
        if (id >= grid.paneIdBase(0) and id < grid.paneIdBase(1)) pane0 += 1;
        if (id >= grid.paneIdBase(1) and id < grid.paneIdBase(2)) pane1 += 1;
    }
    try testing.expect(pane0 > 20);
    try testing.expect(pane1 > 20);
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

test "ADVERSARIAL: the command budget genuinely binds - it is not 0" {
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
        .command_budget = app.paneCommandBudget(0),
        .text_reserve = app.pane_text_reserve,
        .glyph_budget = app.pane_glyph_budget,
        .id_base = grid.paneIdBase(0),
    });
    const bounded_len = bounded.displayList().commands.len;

    std.debug.print(
        "\nMEASURED budget bind: unbounded={d} bounded={d} budget={d}\n",
        .{ unbounded_len, bounded_len, app.paneCommandBudget(0) },
    );
    try testing.expect(app.paneCommandBudget(0) > 0);
    try testing.expect(unbounded_len > app.paneCommandBudget(0)); // the screen CAN overflow
    try testing.expect(bounded_len < unbounded_len); // the bound truncated it
    try testing.expect(bounded_len <= app.paneCommandBudget(0));
}

test "ADVERSARIAL: identical hostile content, and the two panes are NOT equal" {
    // MEASUREMENT, not a repair. The policy calls itself "floor and
    // slack" and claims neither pane can starve the other. It is a
    // CUMULATIVE high-water mark, so pane 0 stops at 896 total while
    // pane 1 stops at 1792 total, and each pane also gives back its own
    // `cols*8+8` row reserve. Feed BOTH panes byte-identical content at
    // the app's real pane geometry and the two do not paint the same
    // number of rows: position in the paint order decides how much of
    // your terminal you can see.
    const gpa = testing.allocator;
    const sessions = try createSessions(58, 40);
    defer for (sessions) |each| each.destroy();
    for (sessions) |session| feedHostileRows(session, 58, 40);

    // The real rects the app would use at its default window size.
    var model = app.initialModel(sessions);
    const frames = app.paneFrames(&model, geometry.SizeF.init(980, 640));

    const storage = try gpa.alloc(canvas.CanvasCommand, 32 * 1024);
    defer gpa.free(storage);
    var builder = canvas.Builder.init(storage);
    var painted: [app.pane_count]usize = @splat(0);
    var used: [app.pane_count]usize = @splat(0);
    for (sessions, frames, 0..) |session, frame, index| {
        const before = builder.displayList().commands.len;
        try grid.paint(session, &builder, .{
            .frame = frame,
            .background_frame = if (index == 0) geometry.RectF.init(0, 0, 980, 640) else null,
            .tokens = .{},
            .running = true,
            .focused = index == 0,
            .selecting = false,
            .command_budget = app.paneCommandBudget(index),
            .text_reserve = app.pane_text_reserve,
            .glyph_budget = app.pane_glyph_budget,
            .id_base = grid.paneIdBase(index),
        });
        const after = builder.displayList().commands.len;
        used[index] = after - before;
        painted[index] = paintedRows(builder.displayList().commands[before..after]);
    }
    std.debug.print(
        "\nMEASURED symmetry: rows={{ {d}, {d} }} commands={{ {d}, {d} }} budgets={{ {d}, {d} }} envelope={d}\n",
        .{ painted[0], painted[1], used[0], used[1], app.paneCommandBudget(0), app.paneCommandBudget(1), app.chrome_command_envelope },
    );

    // The envelope holds — that part of the claim is true.
    try testing.expect(builder.displayList().commands.len <= app.chrome_command_envelope);
    // Both panes show something — no total starvation.
    try testing.expect(painted[0] > 0);
    try testing.expect(painted[1] > 0);
    // But the split is NOT even. Pinned as the honest description of
    // the policy: pane 1 gets strictly more of the frame than pane 0
    // for byte-identical content. If a later change makes them equal,
    // this test fails and the comment above should be deleted.
    try testing.expect(painted[1] > painted[0]);
}

// ------------------------------------------------------- A5/A6: input paths

fn pressKey(harness: anytype, app_iface: anytype, key: []const u8, modifiers: native_sdk.platform.ShortcutModifiers) !void {
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
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
    try testing.expectEqual(@as(u8, 1), app_state.model.focus);
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

    // Press AND release, which is where the build agent flagged an
    // asymmetry: the chord is swallowed on press, but the release path
    // sits above the chord block.
    try pressKey(harness, app_iface, "2", .{ .primary = true });
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "terminal-canvas",
        .kind = .key_up,
        .key = "2",
        .modifiers = .{ .primary = true },
    } });
    std.debug.print(
        "\nMEASURED chord leak: pane0={d} bytes pane1={d} bytes\n",
        .{ app_state.effects.ptyWrittenBytes(app.ptyKey(0)).len, app_state.effects.ptyWrittenBytes(app.ptyKey(1)).len },
    );
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(0)));
    try testing.expectEqualStrings("", app_state.effects.ptyWrittenBytes(app.ptyKey(1)));
}

test "ADVERSARIAL: a wheel over the UNFOCUSED pane scrolls that one, not the focused one" {
    // Named by the build agent as implemented-but-unpinned. It is also
    // the sharpest shared-state probe available: one scrollback offset
    // behind two panes would move both.
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
    // `Model.surface_size` is only written by the `.viewport` Msg, and
    // `onFrame` emits at most ONE of those per surface frame. Until the
    // surface has been measured, `paneFrames` returns zero-width rects
    // and the hit test cannot resolve anything — so pump real frames
    // first, exactly as a live window does at ~60 Hz.
    for (2..8) |frame_index| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_frame = .{
            .label = "terminal-canvas",
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
    try testing.expectEqual(@as(u8, 0), model.focus);

    // Point at the CENTRE of pane 1 while pane 0 holds keyboard focus.
    const frames = app.paneFrames(model, size);
    const target = frames[1];
    const cell_h = model.panes[1].session.cell_height;
    for (0..6) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .scroll,
            .x = target.x + target.width / 2,
            .y = target.y + target.height / 2,
            .delta_y = cell_h,
        } });
    }
    std.debug.print(
        "\nMEASURED wheel routing (surface measured): pane0 {d}->{d}  pane1 {d}->{d}\n",
        .{ bottom0, model.panes[0].session.scrollbar().offset, bottom1, model.panes[1].session.scrollbar().offset },
    );
    // Pane 1 scrolled into history...
    try testing.expect(model.panes[1].session.scrollbar().offset < bottom1);
    // ...and the FOCUSED pane 0 did not move at all. Two scrollback
    // offsets, independently addressable by pointer position.
    try testing.expectEqual(bottom0, model.panes[0].session.scrollbar().offset);
}

test "ADVERSARIAL: DEFECT - before the surface is measured the wheel hit test is dead" {
    // THE DEFECT THIS PROBE FOUND, pinned rather than repaired.
    // `Model.surface_size` starts at {0,0} and is only written by the
    // `.viewport` Msg. Until `onFrame` has emitted one, `paneFrames`
    // returns zero-width rects, `paneAtPoint` can never contain a point,
    // and EVERY wheel — including one plainly over pane 1 — silently
    // falls back to the focused pane. The build agents' own suite never
    // reached the measured state, so their "a wheel scrolls the pane it
    // is OVER" claim was never exercised by any test.
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

    // The state the whole pre-existing suite runs in.
    try testing.expectEqual(@as(f32, 0), model.surface_size.width);
    try testing.expectEqual(@as(f32, 0), model.surface_size.height);
    try testing.expectEqual(@as(f32, 0), app.paneFrames(model, model.surface_size)[1].width);

    var line: [32]u8 = undefined;
    for (0..200) |i| {
        const bytes = std.fmt.bufPrint(&line, "history {d}\r\n", .{i}) catch unreachable;
        model.panes[0].session.feed(bytes);
        model.panes[1].session.feed(bytes);
    }
    const bottom0 = model.panes[0].session.scrollbar().offset;
    const bottom1 = model.panes[1].session.scrollbar().offset;

    // Aim squarely at pane 1, as `paneFrames` WOULD place it.
    const target = app.paneFrames(model, size)[1];
    const cell_h = model.panes[1].session.cell_height;
    for (0..6) |_| {
        try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = "terminal-canvas",
            .kind = .scroll,
            .x = target.x + target.width / 2,
            .y = target.y + target.height / 2,
            .delta_y = cell_h,
        } });
    }
    std.debug.print(
        "\nMEASURED wheel routing (surface UNMEASURED): pane0 {d}->{d}  pane1 {d}->{d}  <- went to the WRONG pane\n",
        .{ bottom0, model.panes[0].session.scrollbar().offset, bottom1, model.panes[1].session.scrollbar().offset },
    );
    // The wrong pane scrolled.
    try testing.expect(model.panes[0].session.scrollbar().offset < bottom0);
    try testing.expectEqual(bottom1, model.panes[1].session.scrollbar().offset);
}
