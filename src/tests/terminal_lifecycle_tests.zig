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
    try testing.expectEqual(app.Phase.starting, app_state.model.provider.slots[0].phase);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingPtyCount());
    try harness.runtime.dispatchPlatformEvent(app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "r",
        .modifiers = .{ .primary = true },
    } });
    try testing.expectEqual(app.Phase.starting, app_state.model.provider.slots[0].phase);
    try testing.expectEqual(@as(usize, 1), app_state.effects.pendingPtyCount());
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
    //
    // A SPAWN failure, because that is the only end that leaves a pane
    // standing for a Restart to target — a shell that ran and ended closes its
    // pane at any status, and a closed pane has no counters left to reset.
    try app_state.effects.feedPtyOutput(1, "demo$ ");
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try app_state.effects.feedPtyExit(1, 0, 0, .spawn_failed, 3);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try testing.expectEqual(app.Phase.failed, app_state.model.provider.slots[0].phase);
    try testing.expectEqual(@as(u32, 3), app_state.model.provider.slots[0].native_delivery_failures);
    const pane = &app_state.model.provider.slots[0];
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
    try testing.expectEqual(@as(i32, 0), pane.exit_signal);

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

test "a split pane carries its lifecycle in accessibility, not in a pane header" {
    // Rewritten: the 24pt `TERMINAL 2 / PHUX / RUNNING` per-pane header is
    // gone (Ghostty has none, and it cost every split pane a row of grid).
    // The detail it carried moved into the surface's accessibility label.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try support.startSplitCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    // A spawn failure: the end that leaves a pane standing to carry a label.
    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .spawn_failed, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("split-status"), &writer);
    const snapshot = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, snapshot, "Terminal 1, native terminal, RUNNING") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "Terminal 2, native terminal, SPAWN FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "Restart Terminal 2") != null);
    // No pane header text of any kind is painted.
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |node| {
        try testing.expect(std.mem.indexOf(u8, node.widget.text, "TERMINAL 1 /") == null);
        try testing.expect(std.mem.indexOf(u8, node.widget.text, "TERMINAL 2 /") == null);
    }
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

    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    // Attention rides as a MARKER beside the tab, not as a `" !"` suffix
    // welded onto the terminal's own name.
    var saw_hidden_marker = false;
    var saw_hidden_reason = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "Terminal 2 !"));
        if (std.mem.eql(u8, layout.widget.icon, "circle-dot")) saw_hidden_marker = true;
        if (std.mem.indexOf(u8, layout.widget.semantics.label, "SPAWN FAILED") != null) saw_hidden_reason = true;
    }
    try testing.expect(saw_hidden_marker);
    try testing.expect(saw_hidden_reason);

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .rejected, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    // The focused pane's own abnormal end is the ONE piece of lifecycle
    // that stays as chrome, because Restart has to be reachable.
    var saw_rejected = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "SPAWN REJECTED")) saw_rejected = true;
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

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .spawn_failed, 4);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    const pane = &app_state.model.provider.slots[0];
    pane.outbound_dropped = 7;
    pane.session.response_bytes_dropped = 2;
    pane.copy_failed = true;
    try harness.runtime.dispatchPlatformEvent(app_iface, .app_deactivated);

    const buffer = try gpa.alloc(u8, 128 * 1024);
    defer gpa.free(buffer);
    var writer = std.Io.Writer.fixed(buffer);
    try automation.snapshot.writeA11yText(harness.runtime.automationSnapshot("terminal-diagnostics"), &writer);
    const snapshot = writer.buffered();
    // Every number a screen reader needs is still there, in the one place
    // that keeps it: the accessibility label.
    try testing.expect(std.mem.indexOf(u8, snapshot, "Terminal 1, native terminal, SPAWN FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "outbound loss 7 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "reply loss 2 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "native delivery failures 4") != null);
    try testing.expect(std.mem.indexOf(u8, snapshot, "copy failed") != null);
}

test "restart targets the focused pane, and only a failed spawn offers it" {
    // Rewritten for the tree model: a pane is not a placement slot, so
    // Restart names a TERMINAL. And an EXIT of any status no longer leaves
    // anything to restart — it closes its pane — so only a pane that never
    // got a process reaches here.
    const gpa = testing.allocator;
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(980, 640) });
    defer harness.destroy(gpa);
    const app_state = try support.startSplitCockpit(gpa, harness);
    defer gpa.destroy(app_state);
    defer destroyModelSessions(&app_state.model);
    defer app_state.deinit();
    const app_iface = app_state.app();

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .spawn_failed, 0);
    try app_state.effects.feedPtyExit(app.ptyKey(1), 0, 0, .spawn_failed, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    // Both panes survive a spawn that never produced a process.
    try testing.expectEqual(@as(usize, 2), app_state.model.ws().tabs[0].paneCount());
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);

    // The split focused the pane it created — terminal 2 — so the band
    // offers exactly that pane's Restart.
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(1)));
    const second_restart = widgetFrameBySemantics(harness, "Restart Terminal 2") orelse return error.TestExpectedRestart;
    const second_generation = app_state.model.provider.slots[1].session_generation;
    const second_target = rectCenter(second_restart);
    try clickCanvas(harness, app_iface, second_target.x, second_target.y);
    try testing.expectEqual(app.Phase.failed, app_state.model.provider.slots[0].phase);
    try testing.expectEqual(app.Phase.starting, app_state.model.provider.slots[1].phase);
    try testing.expect(app_state.model.provider.slots[1].session_generation != second_generation);

    // Cycling focus to the other pane brings ITS Restart into the band, and
    // Cmd+R hits the same pane.
    app.update(&app_state.model, .{ .cycle_pane = -1 }, &app_state.effects);
    try testing.expect(app_state.model.selectedTerminalRef().?.eql(app.initialTerminalRef(0)));
    const cmd_generation = app_state.model.provider.slots[0].session_generation;
    try pressCanvasKey(harness, app_iface, "r", .{ .primary = true });
    try testing.expectEqual(app.Phase.starting, app_state.model.provider.slots[0].phase);
    try testing.expect(app_state.model.provider.slots[0].session_generation != cmd_generation);
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

    try app_state.effects.feedPtyExit(app.ptyKey(0), 0, 0, .spawn_failed, 0);
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    var saw_missing = false;
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        if (std.mem.eql(u8, layout.widget.text, "SPAWN FAILED")) {
            saw_missing = true;
            try testing.expectEqual(canvas.WidgetVariant.destructive, layout.widget.variant);
        }
    }
    try testing.expect(saw_missing);

    // The second terminal remains usable, and arming a selection is NOT an
    // occasion to paint a badge: the state rides in accessibility.
    try pressCanvasKey(harness, app_iface, "2", .{ .primary = true });
    try pressCanvasKey(harness, app_iface, "space", .{ .primary = true, .shift = true });
    try testing.expect(app_state.model.provider.slots[1].selecting);
    try harness.runtime.dispatchPlatformEvent(app_iface, .frame_requested);
    for (harness.runtime.views[0].widgetLayoutTree().nodes) |layout| {
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "SELECTING"));
        try testing.expect(!std.mem.eql(u8, layout.widget.text, "Arrows move | Shift extends | Enter copies | Esc cancels"));
    }
}

// ------------------------------------------------------- the shell ceiling

// phux-cockpit-pg1: "Pane renders empty".
//
// The fifth cmd+T used to open a tab whose grid stayed blank forever. The
// effects layer keeps ONE fixed pty table for the whole process
// (`native_sdk.max_effect_ptys`), so its `ptySpawn` answered `.rejected` and
// that pane never received a byte — while the tab strip, the pane rect and
// the accessibility tree all reported an ordinary terminal, and
// `dispatch_errors` stayed 0 because a refused spawn is a normal exit event
// rather than an error. Reproduced against the shipped bundle on 2026-08-12:
// four cmd+T from a fresh workspace leave Terminal 5 at SPAWN REJECTED,
// filling the content area with no `text=` attribute at all.
//
// The invariant pinned here is NOT the number four. It is that cockpit never
// mints a pane it cannot back with a shell; both bounds are read from the
// SDK, so a pin that grows the pty table grows this test with it.
test "cmd+T refuses at the shell ceiling instead of opening a pane no shell can back" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try support.startCockpit(harness);
    defer support.stopCockpit(state);
    const app_iface = state.app();

    // One terminal arrives with the workspace, so this asks for the rest of
    // the table and then two more than it can hold.
    try testing.expectEqual(@as(usize, 1), state.effects.pendingPtyCount());
    for (0..native_sdk.max_effect_ptys + 1) |_| app.update(&state.model, .new_terminal, &state.effects);

    // The registry holds exactly the terminals that got a pty. Before the fix
    // it held every chord that was pressed, two of them backed by nothing.
    try testing.expectEqual(native_sdk.max_effect_ptys, state.model.provider.activeCount());
    try testing.expectEqual(native_sdk.max_effect_ptys, state.effects.pendingPtyCount());
    try testing.expectEqual(native_sdk.max_effect_ptys, state.model.provider.liveShellCount());

    // Drain what the effects layer staged: this is where the refused spawns
    // deliver their `.rejected` exits and strand the dead panes.
    try harness.runtime.dispatchPlatformEvent(app_iface, .wake);
    for (support.activeSlots(&state.model)) |pane| {
        try testing.expect(pane.phase != .failed);
        try testing.expect(pane.exit_reason != .rejected);
    }

    // Refused, and VISIBLY: the latch is what `view.terminalLimitNotice` reads,
    // and the band reveals itself to carry it. Asserted on the model rather
    // than on the rendered tree because `app.update` is called directly here,
    // which never tells the runtime the model is dirty — the same reason the
    // window-limit test next door checks its latch and not its badge.
    try testing.expect(state.model.terminal_limit_refused);
    try testing.expect(app.chromeRevealed(&state.model));

    // Closing a terminal gives the slot back, so the refusal stops being true.
    app.update(&state.model, .close_terminal, &state.effects);
    try testing.expect(!state.model.terminal_limit_refused);
}

// The same ceiling reached through cmd+D, which has further to fall: a split
// divides the focused pane's rect FIRST, so a rejected spawn used to hand
// half of a working terminal's screen area to a grid that never painted
// anything at all.
test "cmd+D refuses at the shell ceiling instead of dividing a pane for a shell that cannot start" {
    const harness = try native_sdk.TestHarness().create(testing.allocator, .{});
    defer harness.destroy(testing.allocator);
    const state = try support.startCockpit(harness);
    defer support.stopCockpit(state);

    for (0..native_sdk.max_effect_ptys - 1) |_| app.update(&state.model, .split_right, &state.effects);
    try testing.expectEqual(native_sdk.max_effect_ptys, state.model.provider.activeCount());
    try testing.expect(!state.model.terminal_limit_refused);

    var refs: [app.max_panes_per_tab]app.TerminalRef = undefined;
    const before = state.model.selectedTree().?.terminals(&refs);
    app.update(&state.model, .split_right, &state.effects);
    // The tree is untouched: no new leaf, and the sibling keeps its whole rect.
    try testing.expectEqual(before, state.model.selectedTree().?.terminals(&refs));
    try testing.expectEqual(native_sdk.max_effect_ptys, state.model.provider.activeCount());
    try testing.expect(state.model.terminal_limit_refused);
}
