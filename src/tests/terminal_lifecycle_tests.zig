const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("../main.zig");
const support = @import("support.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;
const automation = native_sdk.automation;

const destroyModelSessions = app.deinitModel;
const startFocusedTerminal = support.startFocusedTerminal;
const startTwoPaneCockpit = support.startTwoPaneCockpit;
const clickCanvas = support.clickCanvas;
const pressCanvasKey = support.pressCanvasKey;
const releaseCanvasKey = support.releaseCanvasKey;
const widgetFrameBySemantics = support.widgetFrameBySemantics;
const rectCenter = support.rectCenter;

test "restart during starting is a no-op - the original session is not duplicated" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // Still .starting (no output yet), one live pty. Cmd+R must not
    // respawn onto the occupied key.
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(usize, app.pane_count), app_state.effects.pendingPtyCount());
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(usize, app.pane_count), app_state.effects.pendingPtyCount());
}

test "restart resets every per-session counter and exit field" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startFocusedTerminal(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // The first session ends with transport drops on record: the exit
    // carries them into the model, where the status tally renders them.
    try app_state.effects.feedPtyOutput(1, "demo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try app_state.effects.feedPtyExit(1, 0, 9, .signaled, 3);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(@as(u32, 3), app_state.model.panes[0].native_delivery_failures);
    const pane = &app_state.model.panes[0];
    const previous_generation = pane.session_generation;
    pane.selecting = true;
    pane.copied_bytes = 12;
    pane.copy_failed = true;
    pane.macos_natural_keys_held = 7;
    pane.scrollback_wheel_accum = 4.5;
    pane.mouse_wheel_y_accum = 3.5;
    pane.mouse_wheel_x_accum = 2.5;
    pane.outbound_head = 9;
    pane.outbound_len = 11;
    pane.outbound_dropped = 13;
    pane.session.response_bytes_dropped = 2;
    app_state.model.paste_owner = app_state.model.provider.owner(pane.id) orelse return error.TestExpectedTerminalOwner;
    app_state.model.paste_failed = true;
    try testing.expect(pane.output_batches > 0);
    try testing.expect(pane.output_bytes > 0);
    try testing.expectEqual(@as(i32, -1), pane.exit_code);
    try testing.expectEqual(@as(i32, 9), pane.exit_signal);

    // Cmd+R: the new shell's tally is its own — zero, not the dead
    // session's drops.
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, pane.phase);
    try testing.expectEqual(@as(i32, 0), pane.exit_code);
    try testing.expectEqual(@as(i32, 0), pane.exit_signal);
    try testing.expectEqual(native_sdk.EffectExitReason.exited, pane.exit_reason);
    try testing.expect(!pane.selecting);
    try testing.expectEqual(@as(u64, 0), pane.copied_bytes);
    try testing.expect(!pane.copy_failed);
    try testing.expectEqual(@as(u8, 0), pane.macos_natural_keys_held);
    try testing.expectEqual(@as(f32, 0), pane.scrollback_wheel_accum);
    try testing.expectEqual(@as(f32, 0), pane.mouse_wheel_y_accum);
    try testing.expectEqual(@as(f32, 0), pane.mouse_wheel_x_accum);
    try testing.expectEqual(@as(u64, 0), pane.output_batches);
    try testing.expectEqual(@as(u64, 0), pane.output_bytes);
    try testing.expectEqual(@as(u32, 0), pane.write_refusals);
    try testing.expectEqual(@as(u32, 0), pane.write_refusals_total);
    try testing.expectEqual(@as(u32, 0), pane.native_delivery_failures);
    try testing.expectEqual(@as(usize, 0), pane.outbound_head);
    try testing.expectEqual(@as(usize, 0), pane.outbound_len);
    try testing.expectEqual(@as(u64, 0), pane.outbound_dropped);
    try testing.expectEqual(@as(u64, 0), pane.session.response_bytes_dropped);
    try testing.expect(pane.session_generation != previous_generation);
    try testing.expect(!app_state.model.paste_failed);
}

test "healthy single-terminal mode omits lifecycle chrome" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();

    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "TERMINAL 1 / RUNNING"));
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "TERMINAL 2 / RUNNING"));
    }
}

test "split exposes lifecycle status for both visible terminals" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try releaseCanvasKey(harness, app_iface, "d", .{});
    try app_state.effects.feedPtyExit(app.ptyKey(1), 9, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("split-status"), &writer);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 1") != null);
    // Visual split chrome shows only pane identity, while accessibility keeps
    // the complete lifecycle detail available.
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 1 / RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "TERMINAL 2 / EXIT 9") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "Restart Terminal 2") != null);
}

test "hidden terminal spawn failures mark tabs and distinguish failure reasons" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .spawn_failed, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));

    var saw_hidden_marker = false;
    var saw_hidden_reason = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "Terminal 2 !")) saw_hidden_marker = true;
        if (std.mem.indexOf(u8, layout.widget.semantics.label, "SPAWN FAILED") != null) saw_hidden_reason = true;
    }
    try testing.expect(saw_hidden_marker);
    try testing.expect(saw_hidden_reason);

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .rejected, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    var saw_rejected = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "TERMINAL 1 / SPAWN REJECTED")) saw_rejected = true;
    }
    try testing.expect(saw_rejected);
}

test "lifecycle and loss diagnostics remain visible beside native delivery failures" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(0), 23, 0, .exited, 4);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    const pane = &app_state.model.panes[0];
    pane.outbound_dropped = 7;
    pane.session.response_bytes_dropped = 2;
    pane.copy_failed = true;
    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("terminal-diagnostics"), &writer);
    const snapshot = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, snapshot, "TERMINAL 1 / EXIT 23") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "OUTBOUND LOSS 7B") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "REPLY LOSS 2B") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "DELIVERY FAILURES 4") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "COPY FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "I/O LOSS") != null);
}

test "restart controls target their placement and Cmd+R targets focus" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try pressCanvasKey(harness, app_iface, "d", .{ .primary = true });
    try releaseCanvasKey(harness, app_iface, "d", .{});
    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .exited, 0);
    try app_state.effects.feedPtyExit(app.ptyKey(1), 9, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);

    const secondary_restart = widgetFrameBySemantics(harness, "Restart Terminal 2") orelse return error.TestExpectedRestart;
    const secondary_generation = app_state.model.panes[1].session_generation;
    const secondary_target = rectCenter(secondary_restart);
    try clickCanvas(harness, app_iface, secondary_target.x, secondary_target.y);
    try testing.expectEqual(app.Phase.ended, app_state.model.panes[0].phase);
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[1].phase);
    try testing.expect(app_state.model.panes[1].session_generation != secondary_generation);

    const primary_restart = widgetFrameBySemantics(harness, "Restart Terminal 1") orelse return error.TestExpectedRestart;
    const primary_target = rectCenter(primary_restart);
    try clickCanvas(harness, app_iface, primary_target.x, primary_target.y);
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[0].phase);

    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    app.update(&app_state.model, .{ .focus_pane = .secondary }, &app_state.effects);
    const cmd_generation = app_state.model.panes[1].session_generation;
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true });
    try testing.expectEqual(app.Phase.starting, app_state.model.panes[1].phase);
    try testing.expect(app_state.model.panes[1].session_generation != cmd_generation);
}

test "terminal exit and selection mode are actionable in native chrome" {
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try startTwoPaneCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(0), 127, 0, .exited, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    var saw_missing = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "TERMINAL 1 / EXIT 127")) {
            saw_missing = true;
            try testing.expectEqual(canvas.WidgetVariant.destructive, layout.widget.variant);
        }
    }
    try testing.expect(saw_missing);

    // The second terminal remains usable and exposes selection state without
    // turning the command band into a permanent shortcut legend.
    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try pressCanvasKey(harness, app_iface, "space", .{ .primary = true, .shift = true });
    var saw_selecting = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "SELECTING")) saw_selecting = true;
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "Arrows move | Shift extends | Enter copies | Esc cancels"));
    }
    try testing.expect(saw_selecting);
}
