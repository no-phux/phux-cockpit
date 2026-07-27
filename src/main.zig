//! terminal: a recordable terminal embed at the example tier. The pty
//! effect vocabulary owns the transport (`fx.ptySpawn` and friends),
//! libghostty-vt owns cell state, damage, scrollback, and selection, and
//! the canvas paints the viewport as real text — theme-mapped ANSI-16,
//! exact 256-color and truecolor. Record a session and it replays
//! byte-identical offline: no shell runs, the journaled output batches
//! (bytes in the session blob store) and exit ARE the session.
//!
//! Keyboard-first by design: typing goes to the pty (committed text via
//! the IME-correct text channel; chords and specials through the
//! emulator's key encoder, so application cursor-key modes hold).
//! cmd/ctrl+shift+space arms cell selection (arrows move, shift+arrows
//! extend, B toggles block/line, cmd/ctrl+C copies, escape clears);
//! cmd/ctrl+arrows page the scrollback.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const vt = @import("ghostty-vt");
const grid = @import("grid.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "terminal-canvas";
const window_width: f32 = 980;
const window_height: f32 = 640;
pub const window_min_width: f32 = 640;
pub const window_min_height: f32 = 420;

/// The grid's padding inside the window.
const grid_inset: f32 = 8;

/// The band the ORDINARY WIDGETS occupy above the grids: the cockpit's
/// label, one status badge per pane, and a real focusable button. The
/// pane rects start below it (`paneFrames`), so the chrome prefix never
/// paints under the widget row.
pub const header_height: f32 = 28;

/// The cockpit paints SEVERAL terminal panes into one gpu_surface.
pub const pane_count: usize = 2;

/// The horizontal gap between two panes, in canvas points.
pub const pane_gutter: f32 = 8;

/// One keyed-effect space spans pty, clipboard, spawn, and fetch
/// (`effects.keyOccupiedUntilDelivery`), so the pane keys and the
/// clipboard key must not collide. Pane i owns key 1+i; the clipboard
/// sits far clear of them — at key 2 (the single-pane original) every
/// copy would be silently rejected the moment pane 1 spawned, surfacing
/// only as `copy_failed`.
pub fn ptyKey(index: usize) u64 {
    return 1 + index;
}
pub const clipboard_key: u64 = 100;

/// THE BUDGET POLICY. The three per-view canvas budgets are accounted
/// DIFFERENTLY by the painter, so each is partitioned differently.
///
/// COMMANDS are CUMULATIVE: the painter compares the BUILDER TOTAL
/// against its ceiling, so `command_budget` is an absolute high-water
/// mark, not a per-paint allowance. Partitioned floor-and-slack: pane 0
/// may reach 896 and no further, pane 1 may reach the whole 1792 — so
/// pane 1 inherits every command pane 0 left unspent while still being
/// guaranteed its own 896. Neither pane can starve its neighbour.
/// The widgets' share now comes from the first-party painter's own
/// constants rather than a local copy: the port's whole point is to stop
/// hand-maintaining numbers the framework publishes and will keep in
/// step with its own emission.
const widget_command_reserve: usize = canvas.terminal_grid.widget_command_reserve;
pub const chrome_command_envelope: usize = native_sdk.runtime.max_canvas_commands_per_view - widget_command_reserve;
pub fn paneCommandBudget(index: usize) usize {
    return chrome_command_envelope - (pane_count - 1 - index) * (chrome_command_envelope / pane_count);
}

/// TEXT is PER-PAINT LOCAL: the painter's emitted-bytes counter resets
/// every call while the 32 KiB text store is shared. Partitioned by a
/// MIRRORED reserve — both panes get the same one, each capping its own
/// local counter, so the pair can never exceed the store less the
/// widgets' share.
pub const pane_text_reserve: usize = canvas.max_display_list_text_bytes -
    (canvas.max_display_list_text_bytes - canvas.terminal_grid.widget_text_reserve) / pane_count;

/// GLYPHS are PER-PAINT LOCAL and a SET, not a running count. Halved
/// per pane. The four-atlas-variants-per-code-point charge that the fork
/// had to add by hand is now the painter's own
/// (`atlas_variants_per_glyph`), so this is a plain division again.
pub const pane_glyph_budget: usize = canvas.terminal_grid.widget_glyph_budget / pane_count;

/// PATHS are PER-PAINT LOCAL, and new to the first-party painter: box
/// drawing renders as GEOMETRY at exact cell bounds rather than font
/// glyphs, so box-heavy content competes for path elements. The fork had
/// no path tier at all — it widened its per-column command reserve
/// instead, which is exactly the hand-maintained accounting this port
/// deletes.
pub const pane_path_reserve: usize = native_sdk.runtime.max_canvas_path_elements_per_view -
    (native_sdk.runtime.max_canvas_path_elements_per_view - canvas.terminal_grid.widget_path_reserve) / pane_count;

/// Each pane's share of the module-wide cell ceiling, so two panes
/// together can never outgrow one view's budgets.
pub const pane_cell_ceiling: usize = grid.max_cells / pane_count;

/// The per-pane pending-outbound ring. 64 KiB matches the pty's stdin
/// FIFO exactly; at two panes that is 128 KiB of model, HALF the single
/// pane's former 256 KiB. Only a paste or reply burst larger than the
/// whole ring, into a child that never reads, reaches the drop path —
/// and even then the drop is counted and shown, never silent.
const outbound_buffer_bytes: usize = 64 * 1024;

/// The default interactive shell per platform — a deterministic pick so
/// a replayed update issues the identical spawn (reading $SHELL here
/// would be nondeterminism outside the effect boundary). macOS's login
/// shell has been zsh since Catalina; Linux uses `/bin/sh`, the only
/// interpreter POSIX guarantees present (a bare `/bin/bash` is absent on
/// Alpine and other minimal installs); Windows uses cmd.exe, present on
/// every install (PowerShell's location and edition vary).
const default_shell: []const u8 = if (builtin.os.tag == .macos)
    "/bin/zsh"
else if (builtin.os.tag == .windows)
    "cmd.exe"
else
    "/bin/sh";

/// The spawn argv around that shell: the POSIX shells take `-i`
/// (interactive even though stdin is a pty the shell might not
/// recognize as a login session); cmd.exe is interactive by default
/// and has no such flag.
const default_shell_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{default_shell}
else
    &.{ default_shell, "-i" };

/// The second pane's content. Two panes only prove the cockpit thesis if
/// they show DIFFERENT things, so pane 1 runs a self-driving clock: it
/// produces output on its own, which also exercises two concurrent live
/// ptys feeding one surface without any typing.
const ticker_argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ default_shell, "/c", "for /l %i in (1,0,2) do @(echo %date% %time%& timeout /t 1 >nul)" }
else
    &.{ default_shell, "-c", "while :; do date; sleep 1; done" };

fn paneArgv(index: usize) []const []const u8 {
    return if (index == 0) default_shell_argv else ticker_argv;
}

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Terminal canvas", .accessibility_label = "Terminal", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Terminal",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Phase = enum { starting, live, ended, failed };

/// ONE terminal pane: its emulator session, its pty, and every piece of
/// state that belongs to that pty rather than to the window. Everything
/// here was a field of `Model` in the single-terminal original and keeps
/// its name, so the behaviour is the same code operating on a pane
/// pointer instead of the model.
pub const Pane = struct {
    /// The emulator session, heap-owned (created in main/tests before
    /// the app starts); everything inside derives from journaled inputs.
    session: *grid.Session,
    /// This pane's key in the app's one keyed-effect space.
    pty_key: u64 = 1,
    /// The spawn argv for this pane's child (and its restart).
    argv: []const []const u8 = default_shell_argv,
    phase: Phase = .starting,
    exit_code: i32 = 0,
    exit_signal: i32 = 0,
    exit_reason: native_sdk.EffectExitReason = .exited,
    cols: u16 = 80,
    rows: u16 = 24,
    /// Keyboard selection mode (the caret the grid outlines).
    selecting: bool = false,
    /// Copy feedback for the status line, cleared by the next copy.
    copied_bytes: u64 = 0,
    /// Physical macOS natural-editing keys whose press was sent as a
    /// legacy shell binding. Matching releases are swallowed by key
    /// identity even if Command/Option came up first.
    macos_natural_keys_held: u8 = 0,
    /// The last copy FAILED (selection serialization or the clipboard
    /// write) with a selection active: the status line says so and the
    /// selection stays live for a retry. Cleared by the next copy
    /// attempt and by a restart.
    copy_failed: bool = false,
    /// Fractional wheel-scroll remainder in view points: deltas
    /// accumulate here and convert to whole scrollback rows.
    wheel_accum: f32 = 0,
    /// Delivered output accounting for the status line (and the
    /// replay fingerprint: byte totals pin the fed stream).
    output_batches: u64 = 0,
    output_bytes: u64 = 0,
    /// Writes the pty refused over the session (reported on exit).
    dropped_writes: u32 = 0,
    /// The window's traffic-light inset so the header clears it.
    /// Pending outbound bytes toward the child's stdin — typed keys,
    /// pastes, AND emulator query replies, in one stream-ordered ring
    /// drained as the pty's 64 KiB stdin FIFO accepts them. A single
    /// queue is why nothing is lost: `ptyWrite` reports acceptance (it
    /// alone knows the byte- and record-ring limits), so a refused write
    /// is retried from here rather than dropped, and a reply cannot be
    /// discarded before it lands. Ordering is the child's own stdin
    /// order — a keystroke after a paste, a reply after the output that
    /// provoked it — exactly what a real terminal delivers.
    outbound_buffer: [outbound_buffer_bytes]u8 = undefined,
    outbound_head: usize = 0,
    outbound_len: usize = 0,
    /// Bytes dropped because the pending ring was full (a paste far
    /// larger than the ring, or a reply burst, into a child that never
    /// reads). Surfaced on the status line — never a silent loss.
    outbound_dropped: u64 = 0,

    /// Input flows to the pty from the moment it is spawned — not only
    /// after the first output batch flips the phase to `.live`. A shell
    /// with an empty prompt and no startup banner never produces that
    /// first batch, and gating input on `.live` would strand it waiting
    /// for keystrokes it discards. Only an ended or failed session
    /// refuses input.
    pub fn acceptsInput(pane: *const Pane) bool {
        return pane.phase == .starting or pane.phase == .live;
    }
};

pub const Model = struct {
    panes: [pane_count]Pane,
    /// Which pane keyboard input reaches. Window activation is global,
    /// pane focus is not: exactly one pane is the keyboard target and
    /// only that one paints a filled cursor.
    focus: u8 = 0,
    /// This single-window app owns terminal keyboard input exactly while
    /// the application is active. Lifecycle messages rebuild the custom
    /// chrome so the cursor fills on focus and hollows on blur.
    focused: bool = true,
    /// A clipboard write is IN FLIGHT: further copies are no-ops until
    /// its result lands, or the fixed-key re-request would be rejected
    /// as a duplicate and overwrite the first copy's outcome. There is
    /// ONE system clipboard, so this is a window-level fact, not a pane
    /// one — `copy_owner` records which pane's selection is riding it,
    /// so the result clears the right pane's highlight.
    copy_inflight: bool = false,
    copy_owner: u8 = 0,
    /// The OS titlebar band height (hidden-inset chrome): the grid's
    /// text starts below it while the terminal background runs under
    /// it, so the window reads as one seamless surface with only the
    /// traffic lights floating over it.
    chrome_top: f32 = 0,
    /// The last surface size the frame pump reported, carried on the
    /// `.viewport` message. `update` has no view size of its own, and
    /// the wheel hit test needs one to resolve which pane the pointer
    /// stands over — `on_wheel` cannot do it (no model access) and
    /// `on_frame` cannot mutate. A size change too small to move any
    /// pane's grid never lands here, so the resolved midpoint can lag
    /// by up to one cell: correct for a which-half question, and the
    /// hit test falls back to the focused pane when the point lands in
    /// no rect at all.
    surface_size: geometry.SizeF = .{},

    pub fn focusedPane(model: *Model) *Pane {
        return &model.panes[@min(model.focus, pane_count - 1)];
    }
};

/// The initial cockpit model over `pane_count` heap-owned sessions: pane
/// i takes pty key i+1 and its own spawn argv.
pub fn initialModel(sessions: [pane_count]*grid.Session) Model {
    var model: Model = .{ .panes = undefined };
    for (&model.panes, sessions, 0..) |*pane, session, index| {
        pane.* = .{
            .session = session,
            .pty_key = ptyKey(index),
            .argv = paneArgv(index),
        };
    }
    return model;
}

pub const Msg = union(enum) {
    shell: native_sdk.EffectPtyEvent,
    key: canvas.WidgetKeyboardEvent,
    text: canvas.WidgetKeyboardEvent,
    viewport: struct { pane: u8, cols: u16, rows: u16, size: geometry.SizeF },
    clipboard: native_sdk.EffectClipboardResult,
    copy_selection,
    restart,
    /// Move keyboard focus to a pane (cmd+digit, or a press on the
    /// pane's own stack). Out-of-range indices clamp rather than trap:
    /// the chord generalizes to nine panes and the app has two.
    focus_pane: u8,
    /// The header button's action: restart the FOCUSED pane's shell.
    /// A distinct variant from `.restart` so the journal records which
    /// surface asked — the chord or the widget.
    restart_pane,
    /// The frame pump asks the update loop (which holds `fx`) to push
    /// more pending outbound bytes now that a frame elapsed — the child
    /// may have read and freed FIFO space without producing output to
    /// trigger a flush.
    flush_outbound,
    /// A wheel/trackpad scroll over the grid: the pointer's position in
    /// view points plus the vertical delta, accumulated into whole rows
    /// of scrollback. The POSITION rides along because `on_wheel` has no
    /// model access — the pane hit test has to happen in `update`.
    wheel: struct { x: f32, y: f32, delta: f32 },
    chrome_changed: native_sdk.platform.WindowChrome,
    focus_changed: bool,
};

const TerminalApp = native_sdk.UiApp(Model, Msg);
const Fx = TerminalApp.Effects;

fn initFx(model: *Model, fx: *Fx) void {
    for (&model.panes) |*pane| spawnPane(pane, fx);
}

fn spawnPane(pane: *Pane, fx: *Fx) void {
    const model = pane;
    model.phase = .starting;
    // Leave selection mode: reset() clears the emulator's selection, so
    // a lingering `selecting` flag would show a caret over no selection
    // AND make the new shell reject all typed text until Escape.
    model.selecting = false;
    // The copy feedback belonged to the session that ended — the new
    // shell's status line must not claim its predecessor's clipboard.
    model.copied_bytes = 0;
    model.copy_failed = false;
    model.macos_natural_keys_held = 0;
    // Drop any bytes still queued for the session that just ended — a
    // restarted shell must not receive the dead one's unsent keystrokes.
    model.outbound_head = 0;
    model.outbound_len = 0;
    model.outbound_dropped = 0;
    // The refused-write tally is per session: the exit that ended the
    // last shell recorded ITS transport drops here, and the status line
    // renders the tally in every phase — a restarted shell must start
    // the count at zero, not inherit its predecessor's.
    model.dropped_writes = 0;
    // Hard-reset the emulator so a restarted shell starts from a clean
    // terminal — no leftover mode (application-cursor, reverse video),
    // scrollback, palette override, or partial escape sequence from the
    // session that just ended. (A no-op on the first spawn.)
    model.session.reset();
    model.session.refreshScreenText();
    fx.ptySpawn(.{
        .key = model.pty_key,
        .argv = model.argv,
        .cols = model.cols,
        .rows = model.rows,
        .on_event = Fx.ptyMsg(.shell),
    });
}

/// The pane owning a keyed pty event. An event for a key no pane holds
/// (a stale exit after a restart raced) is ignored rather than applied
/// to the wrong terminal.
fn paneForKey(model: *Model, key: u64) ?*Pane {
    for (&model.panes) |*pane| {
        if (pane.pty_key == key) return pane;
    }
    return null;
}

pub fn update(model: *Model, msg: Msg, fx: *Fx) void {
    switch (msg) {
        .shell => |event| {
            // Every pty event carries its own key: route it to the pane
            // that owns that key, never to "the" terminal.
            const pane = paneForKey(model, event.key) orelse return;
            switch (event.kind) {
                .output => {
                    pane.phase = .live;
                    pane.output_batches += 1;
                    pane.output_bytes += event.bytes.len;
                    feedOutput(pane, fx, event.bytes);
                    // Cells changed: refresh the grid's accessibility text
                    // (which also carries real cell state into the session
                    // fingerprint — byte counters alone would verify a
                    // wrong screen).
                    pane.session.refreshScreenText();
                    // An armed selection follows the TEXT the emulator's
                    // absolute pins track — output that scrolled the screen
                    // moves the caret with the selected cells, and a range
                    // that left the viewport clears selection mode rather
                    // than desynchronizing the caret from the copyable text.
                    if (pane.selecting and !pane.session.rebaseSelection()) {
                        pane.selecting = false;
                    }
                    // The child produced output, so it is reading: its stdin
                    // FIFO likely has room now — push any pending outbound,
                    // then let a reply the full ring retained take the room
                    // the flush just freed (stdin order: it is older than
                    // anything a later dispatch could enqueue).
                    flushOutbound(pane, fx);
                    moveResponsesToOutbound(pane, fx);
                },
                .exit => {
                    pane.phase = if (event.reason == .rejected or event.reason == .spawn_failed) .failed else .ended;
                    pane.exit_code = event.code;
                    pane.exit_signal = event.signal;
                    pane.exit_reason = event.reason;
                    pane.dropped_writes = event.dropped_writes;
                    // The child is gone: bytes still queued can never land —
                    // drop them COUNTED (they are outbound loss like any
                    // other), and drop retained emulator replies too — ALSO
                    // counted (a DSR reply the full ring retained is outbound
                    // loss the same way) — or the frame pump would retry
                    // flushing them against the dead key until restart.
                    pane.outbound_dropped += pane.outbound_len;
                    pane.outbound_dropped += pane.session.pendingResponses().len;
                    pane.outbound_head = 0;
                    pane.outbound_len = 0;
                    pane.session.clearResponses();
                },
                // Write-admission verdicts are journal-only (replay
                // machinery); the engine never delivers one as an event.
                .write => unreachable,
            }
        },
        .key => |event| handleKey(model, fx, event),
        .text => |event| {
            const pane = model.focusedPane();
            if (pane.selecting or !pane.acceptsInput()) return;
            if (event.text.len == 0) return;
            pane.session.scrollToBottom();
            sendCommittedText(pane, fx, event.text);
        },
        .viewport => |size| {
            const pane = &model.panes[@min(size.pane, pane_count - 1)];
            // Remember the surface the frame pump measured against, so
            // the wheel hit test has rectangles to resolve into.
            model.surface_size = size.size;
            // Commit the new size only once the emulator actually took
            // it: on an allocation failure the model keeps its old
            // dimensions and the frame pump retries next frame, so the
            // emulator and the pty never disagree about the grid.
            if (!pane.session.resize(size.cols, size.rows)) return;
            pane.cols = size.cols;
            pane.rows = size.rows;
            pane.session.refreshScreenText();
            fx.ptyResize(pane.pty_key, size.cols, size.rows);
            flushOutbound(pane, fx);
        },
        .flush_outbound => {
            for (&model.panes) |*pane| {
                flushOutbound(pane, fx);
                // The drain may have freed room for query replies a full
                // ring left retained in the emulator's buffer.
                moveResponsesToOutbound(pane, fx);
            }
        },
        .chrome_changed => |chrome| {
            model.chrome_top = chrome.insets.top;
        },
        .focus_changed => |focused| {
            model.focused = focused;
            // Window blur strands every pane's held-key latches, not
            // only the focused one's.
            if (!focused) {
                for (&model.panes) |*pane| pane.macos_natural_keys_held = 0;
            }
        },
        .wheel => |wheel| {
            // Natural direction, like every terminal: swiping the
            // content down (positive delta on hosts with natural
            // scrolling) reveals history. Inert while a selection is
            // armed - the caret and the emulator's absolute range must
            // not desynchronize (the scroll-chord rule).
            //
            // A wheel scrolls the pane it is OVER, not the focused one:
            // that is what every tiling terminal does and it is why the
            // pointer position rides on the message.
            const pane = paneAtPoint(model, wheel.x, wheel.y) orelse model.focusedPane();
            if (pane.selecting) return;
            pane.wheel_accum += wheel.delta;
            const cell_h = @max(1, pane.session.cell_height);
            const rows = @trunc(pane.wheel_accum / cell_h);
            if (rows != 0) {
                pane.wheel_accum -= rows * cell_h;
                pane.session.scrollLines(-@as(isize, @intFromFloat(rows)));
            }
        },
        .copy_selection => copySelection(model, fx),
        .clipboard => |result| {
            model.copy_inflight = false;
            // The result belongs to the pane whose selection was copied,
            // which may no longer be the focused one.
            const pane = &model.panes[@min(model.copy_owner, pane_count - 1)];
            if (result.outcome == .ok) {
                // Confirmed on the clipboard: the selection's job is
                // done, and only NOW does it clear — a failed write
                // needs it still standing to retry.
                pane.selecting = false;
                pane.session.clearSelection();
            } else {
                // The write failed after a successful read: same user
                // story as a serialization failure — loud, the
                // selection kept, never a silent no-op the user pastes
                // stale content after.
                pane.copied_bytes = 0;
                pane.copy_failed = true;
            }
        },
        .restart => {
            // Restart ONLY a genuinely finished session. During
            // `.starting` (spawned, no output yet) or `.live` the pty
            // still holds the key, so respawning would collide on the
            // same key — a rejected exit that strands the running
            // original with no input.
            const pane = model.focusedPane();
            if (pane.phase != .ended and pane.phase != .failed) return;
            // The restarting pane's copy can never confirm now.
            if (model.copy_inflight and model.copy_owner == model.focus) model.copy_inflight = false;
            spawnPane(pane, fx);
        },
        .restart_pane => update(model, .restart, fx),
        .focus_pane => |requested| {
            const next: u8 = @intCast(@min(requested, pane_count - 1));
            if (next == model.focus) return;
            // The pane losing focus may never see the releases of keys
            // still physically down, so its natural-editing latches
            // would strand and swallow a later matching release.
            model.panes[@min(model.focus, pane_count - 1)].macos_natural_keys_held = 0;
            model.focus = next;
        },
    }
}

/// The pane whose rect contains a view point, or null when the point
/// stands over the header band, a gutter, or outside the panes.
fn paneAtPoint(model: *Model, x: f32, y: f32) ?*Pane {
    const frames = paneFrames(model, model.surface_size);
    for (&model.panes, frames) |*pane, frame| {
        if (x >= frame.x and x < frame.x + frame.width and
            y >= frame.y and y < frame.y + frame.height) return pane;
    }
    return null;
}

/// Append outbound bytes (typed keys, pastes, or query replies) to the
/// pending ring in stream order, then flush what the pty's stdin FIFO
/// will take. A large payload is not submitted all at once: `flushOutbound`
/// paces it as the child reads, so the tail is never dropped. Admission
/// is ALL-OR-NOTHING — a query reply or encoded key cut mid-sequence
/// would feed the child a malformed control sequence, which is worse
/// than a whole loss — and the RESULT says which disposal the caller
/// must apply: `true` means the payload is DISPOSED (queued whole, or
/// impossible — larger than the ring itself — and counted as dropped);
/// `false` means it merely does not fit RIGHT NOW, is untouched and
/// uncounted, and the caller retains it to retry as the ring drains.
fn enqueueOutbound(model: *Pane, fx: *Fx, bytes: []const u8) bool {
    const cap = model.outbound_buffer.len;
    if (bytes.len > cap) {
        model.outbound_dropped += bytes.len;
        return true;
    }
    if (bytes.len > cap - model.outbound_len) {
        // The occupancy may be STALE — the child may have resumed
        // reading since the ring filled — so drain what the FIFO will
        // take before refusing: a keystroke arriving between periodic
        // flushes must not drop when flushing would make room now.
        flushOutbound(model, fx);
        if (bytes.len > cap - model.outbound_len) return false;
    }
    for (bytes, 0..) |byte, i| {
        model.outbound_buffer[(model.outbound_head + model.outbound_len + i) % cap] = byte;
    }
    model.outbound_len += bytes.len;
    flushOutbound(model, fx);
    return true;
}

/// Enqueue a TRANSIENT payload (typed text, an encoded key): the event's
/// bytes do not outlive this dispatch, so a right-now refusal cannot be
/// retried later — it is counted as dropped instead, never silent.
/// Hitting this at all means the child ignored the whole 64 KiB ring.
///
/// STDIN ORDER comes first: a query reply retained behind a full ring is
/// OLDER than this keystroke and must reach the child before it. The
/// retained reply gets its retry now; if it still cannot enter the ring,
/// the keystroke must not jump the queue — it drops counted rather than
/// arrive before an answer the child may be parsing toward.
fn enqueueTransient(model: *Pane, fx: *Fx, bytes: []const u8) void {
    moveResponsesToOutbound(model, fx);
    if (model.session.response_len > 0) {
        model.outbound_dropped += bytes.len;
        return;
    }
    if (!enqueueOutbound(model, fx, bytes)) {
        model.outbound_dropped += bytes.len;
    }
}

/// Push as much pending outbound as the pty's stdin FIFO will accept, in
/// per-write-bound chunks. `ptyWrite` reports acceptance — it alone knows
/// the byte- and record-ring limits — so a refused chunk stays in the
/// ring and is retried on the next output, resize, or frame: a
/// non-reading child pauses the stream instead of losing its tail, and a
/// reply is never removed before it actually lands.
fn flushOutbound(model: *Pane, fx: *Fx) void {
    const cap = model.outbound_buffer.len;
    while (model.outbound_len > 0) {
        const run_to_end = cap - model.outbound_head;
        const n = @min(
            native_sdk.max_effect_pty_write_bytes,
            @min(model.outbound_len, run_to_end),
        );
        if (!fx.ptyWrite(model.pty_key, model.outbound_buffer[model.outbound_head .. model.outbound_head + n])) break;
        model.outbound_head = (model.outbound_head + n) % cap;
        model.outbound_len -= n;
    }
}

/// Feed one pty output batch and return the emulator's query answers to
/// the child. A batch can be many times the response buffer, and a
/// pathological all-query batch (thousands of pipelined DSR/DA1 requests)
/// could produce more replies than the buffer holds in one pass — so the
/// batch is fed in sub-slices no larger than the response buffer, with
/// the answers drained after each. The VT stream keeps parser state
/// across slices, so splitting mid-escape-sequence is invisible; each
/// query's reply is well under a slice's worth of input, so the buffer
/// never overflows and no reply is dropped. This keeps the write-back
/// lossless: a child that blocks on a DSR answer never hangs.
fn feedOutput(model: *Pane, fx: *Fx, bytes: []const u8) void {
    const slice_bytes = grid.Session.feed_slice_bytes;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + slice_bytes, bytes.len);
        model.session.feed(bytes[offset..end]);
        moveResponsesToOutbound(model, fx);
        offset = end;
    }
    // A zero-length batch never reaches here (the engine coalesces only
    // non-empty reads), but a batch that produced no output still drains
    // any answer a prior partial sequence completed.
    if (bytes.len == 0) moveResponsesToOutbound(model, fx);
}

/// Move the emulator's query answers (DSR, DA1, ...) into the pending
/// outbound ring, in stream order after whatever input preceded them,
/// then flush. Routing them through the SAME ring as typed input is what
/// makes them lossless: a reply refused by a full FIFO stays queued and
/// retries, never cleared before it lands (which would hang a child
/// blocking on it). Replies are DURABLE (the emulator's buffer holds
/// them), so a ring too full right now leaves them IN PLACE — uncleared,
/// retried on the next output, resize, or frame — instead of discarding
/// an answer the child may be blocked on. Only a queued (or impossible,
/// counted) batch clears; never a torn escape sequence either way.
pub fn moveResponsesToOutbound(model: *Pane, fx: *Fx) void {
    const pending = model.session.pendingResponses();
    if (pending.len > 0) {
        if (!enqueueOutbound(model, fx, pending)) return;
    }
    model.session.clearResponses();
}

fn copySelection(model: *Model, fx: *Fx) void {
    // ONE copy in flight: the clipboard write reuses a fixed key, so a
    // second request before the first result drains would be rejected
    // as a duplicate — and that rejection would overwrite the first
    // copy's success with `copy_failed`. There is one system clipboard,
    // so this holds ACROSS panes, not per pane.
    if (model.copy_inflight) return;
    const pane = model.focusedPane();
    pane.copy_failed = false;
    const text = (pane.session.selectionText(pane.session.gpa) catch {
        // Serialization failed with a selection ACTIVE: keep the
        // selection for a retry and say so in the status — a copy that
        // silently does nothing would leave the user pasting stale
        // clipboard content.
        pane.copy_failed = true;
        pane.copied_bytes = 0;
        return;
    }) orelse {
        // No emulator range while the MODEL still holds an anchor: a
        // prior selection re-pin failed and cleared the highlight (see
        // `applySelection`), so this copy has nothing to serialize —
        // that is a failed copy, not a quiet no-op.
        if (pane.session.selectionActive()) {
            pane.copy_failed = true;
            pane.copied_bytes = 0;
        }
        return;
    };
    defer pane.session.gpa.free(text);
    pane.copied_bytes = text.len;
    model.copy_inflight = true;
    // Remember whose selection is riding the clipboard: the result may
    // land after focus moved to the other pane.
    model.copy_owner = model.focus;
    fx.writeClipboard(.{
        .key = clipboard_key,
        .text = text,
        .on_result = Fx.clipboardMsg(.clipboard),
    });
    // The selection stays armed until the clipboard CONFIRMS: clearing
    // it now would leave a failed write nothing to retry — the promised
    // keep-on-failure needs the selection still standing when the
    // result lands (the `.clipboard` arm clears it on success).
}

// ------------------------------------------------------------- keyboard

fn onKey(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .key = event };
}

fn onText(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .text = event };
}

fn onWheel(wheel: native_sdk.platform.WheelEvent) ?Msg {
    if (wheel.delta_y == 0) return null;
    return .{ .wheel = .{ .x = wheel.x, .y = wheel.y, .delta = wheel.delta_y } };
}

fn onChrome(chrome: native_sdk.platform.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
    return switch (event) {
        .activate => .{ .focus_changed = true },
        .deactivate => .{ .focus_changed = false },
        else => null,
    };
}

fn handleKey(model: *Model, fx: *Fx, event: canvas.WidgetKeyboardEvent) void {
    const mods = event.modifiers;
    const primary = mods.hasCommandModifier();
    // Keyboard input belongs to the FOCUSED pane; the window-level
    // clipboard and restart chords still route through the model.
    const pane = model.focusedPane();
    const session = pane.session;

    // Releases are terminal input only — app chords and selection act
    // on presses. The encoder decides whether the child hears them
    // (kitty event reporting; silent under legacy modes).
    if (event.phase == .key_up) {
        if (pane.selecting or !pane.acceptsInput()) return;
        encodeKeyEvent(pane, fx, event, .release);
        return;
    }

    // App chords first: pane focus, selection mode, copy, scrollback,
    // restart.
    //
    // cmd/ctrl+digit is the conventional tab chord and nothing else
    // binds it, so it generalizes to N panes without stealing terminal
    // input a shell would otherwise see. It runs BEFORE the selection
    // and terminal paths because a focus move is a window action, not
    // something the focused child should hear.
    if (primary and !mods.shift and event.key.len == 1 and event.key[0] >= '1' and event.key[0] <= '9') {
        update(model, .{ .focus_pane = event.key[0] - '1' }, fx);
        return;
    }
    if (primary and mods.shift and keyIs(event.key, "space")) {
        if (pane.selecting) {
            pane.selecting = false;
            session.clearSelection();
        } else {
            pane.selecting = true;
            session.beginSelection(false);
        }
        return;
    }
    if (primary and keyIs(event.key, "c") and (pane.selecting or session.selectionActive())) {
        copySelection(model, fx);
        return;
    }
    if (primary and keyIs(event.key, "r") and (pane.phase == .ended or pane.phase == .failed)) {
        update(model, .restart, fx);
        return;
    }
    // Scrollback chords pause while a keyboard selection is armed: the
    // selection's anchor and head are VIEWPORT coordinates and the
    // emulator range is pinned to absolute cells, so scrolling under an
    // armed selection would leave the painted caret naming different
    // text than a copy returns. (The chords fall through to the
    // selection block below, where primary+arrows are simply inert.)
    if (!pane.selecting) {
        if (primary and keyIs(event.key, "arrowup")) {
            session.scrollLines(-if (mods.shift) @as(isize, pane.rows) else 1);
            return;
        }
        if (primary and keyIs(event.key, "arrowdown")) {
            session.scrollLines(if (mods.shift) @as(isize, pane.rows) else 1);
            return;
        }
        if (primary and keyIs(event.key, "home")) {
            session.scrollToTop();
            return;
        }
        if (primary and keyIs(event.key, "end")) {
            session.scrollToBottom();
            return;
        }
    }

    if (pane.selecting) {
        if (keyIs(event.key, "escape")) {
            pane.selecting = false;
            session.clearSelection();
            return;
        }
        if (keyIs(event.key, "b")) {
            session.toggleSelectionBlock();
            return;
        }
        if (keyIs(event.key, "enter")) {
            copySelection(model, fx);
            return;
        }
        const step: i32 = 1;
        if (keyIs(event.key, "arrowleft")) return session.moveSelection(-step, 0, mods.shift);
        if (keyIs(event.key, "arrowright")) return session.moveSelection(step, 0, mods.shift);
        if (keyIs(event.key, "arrowup")) return session.moveSelection(0, -step, mods.shift);
        if (keyIs(event.key, "arrowdown")) return session.moveSelection(0, step, mods.shift);
        return;
    }

    if (!pane.acceptsInput()) return;

    // Everything else is terminal input: specials and chords encode
    // through the emulator (application cursor-key mode, kitty
    // protocol, and modifier encodings all honored); plain printable
    // presses arrive through `.text` instead and are ignored here.
    encodeKeyEvent(pane, fx, event, .press);
}

/// Encode one key transition and push the bytes toward the child. macOS
/// natural-text arrow gestures use conventional shell bindings;
/// everything else goes through the emulator's encoder. Releases ride
/// the same path with `.release`: the encoder emits them only under the
/// kitty protocol's negotiated event reporting and stays silent in
/// legacy modes. (Key REPEAT is the one event type the hosts do not
/// distinguish from a fresh press, so a TUI that enabled event reporting
/// sees repeats as presses.)
fn encodeKeyEvent(model: *Pane, fx: *Fx, event: canvas.WidgetKeyboardEvent, action: vt.input.KeyAction) void {
    const session = model.session;
    const natural_key_mask = macosNaturalTextKeyMask(event.key);
    if (action == .release and natural_key_mask != 0 and
        (model.macos_natural_keys_held & natural_key_mask) != 0)
    {
        model.macos_natural_keys_held &= ~natural_key_mask;
        return;
    }
    // A fresh press supersedes a stale latch, then re-arms it below when
    // this is another natural-editing gesture (auto-repeat included).
    if (action == .press and natural_key_mask != 0) {
        model.macos_natural_keys_held &= ~natural_key_mask;
    }
    if (macosNaturalTextSequence(event)) |sequence| {
        // Natural-text bindings consume the whole gesture. In
        // particular, a child using kitty event reporting must not
        // receive a release for a modified arrow whose press arrived as
        // legacy editing bytes.
        if (action == .release) return;
        model.macos_natural_keys_held |= natural_key_mask;
        session.scrollToBottom();
        enqueueTransient(model, fx, sequence);
        return;
    }
    const mods = event.modifiers;
    const key = mapKey(event) orelse blk: {
        // A release of a plain printable never maps (its PRESS came
        // through the text channel): synthesize the codepoint-keyed
        // event so kitty event reporting hears the release too.
        if (action != .release) return;
        break :blk mapPrintable(event.key) orelse return;
    };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const encode_options: vt.input.KeyEncodeOptions = .fromTerminal(&session.term);
    // The runtime folds the platform's PRIMARY modifier into `super`.
    // On macOS primary IS the GUI key, so the fold is harmless there —
    // but on hosts whose primary is Ctrl, a bare Ctrl chord arrives as
    // ctrl+super and the encoder would skip its C0 byte (Ctrl+C must
    // deliver ETX and interrupt the child, never a CSI-u chord). Undo
    // the alias for the encoder: super counts only when Ctrl is not the
    // key raising it. (The one loss is the GUI+Ctrl double chord, which
    // encodes as plain Ctrl — the convention terminals follow anyway.)
    const encoder_super = mods.super and !mods.control;
    _ = vt.input.encodeKey(&writer, .{
        .key = key.key,
        .action = action,
        .mods = .{
            .shift = mods.shift,
            .ctrl = mods.control,
            .alt = mods.alt,
            .super = encoder_super,
        },
        .utf8 = key.utf8,
        .unshifted_codepoint = key.unshifted,
    }, encode_options) catch return;
    if (writer.end == 0) return;
    session.scrollToBottom();
    // Through the pending ring like committed text, so an encoded key
    // typed while a paste is still draining lands after it in the stream.
    enqueueTransient(model, fx, buffer[0..writer.end]);
}

fn macosNaturalTextKeyMask(key: []const u8) u8 {
    if (comptime builtin.os.tag != .macos) return 0;
    if (keyIs(key, "arrowleft")) return 1 << 0;
    if (keyIs(key, "arrowright")) return 1 << 1;
    if (keyIs(key, "backspace")) return 1 << 2;
    return 0;
}

/// Match macOS terminals' "natural text editing" bindings. These are
/// exact bare-modifier gestures: shifted or combined chords continue
/// through the key encoder so terminal applications can distinguish
/// them. The raw bindings intentionally bypass negotiated kitty
/// reporting, just as Ghostty's own default keybinds do.
fn macosNaturalTextSequence(event: canvas.WidgetKeyboardEvent) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const mods = event.modifiers;
    if (mods.shift or mods.control) return null;
    if (mods.alt and !mods.super) {
        if (keyIs(event.key, "arrowleft")) return "\x1bb";
        if (keyIs(event.key, "arrowright")) return "\x1bf";
    }
    if (mods.super and !mods.alt) {
        if (keyIs(event.key, "arrowleft")) return "\x01";
        if (keyIs(event.key, "arrowright")) return "\x05";
        // The physical macOS Delete key is normalized as Backspace.
        if (keyIs(event.key, "backspace")) return "\x15";
    }
    return null;
}

/// Committed text reaches the child through the emulator's key encoder
/// when it is a single scalar: byte-identical to the raw text under
/// legacy modes (the encoder writes unmodified text through untouched)
/// and the negotiated CSI-u form when a TUI enabled the kitty
/// protocol's report-all mode — raw bytes there would desynchronize the
/// application's key decoding. Multi-scalar commits (IME words, paste)
/// stay raw text, the protocol's rule for composed input.
fn sendCommittedText(model: *Pane, fx: *Fx, text: []const u8) void {
    single: {
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch break :single;
        if (text.len != len) break :single;
        const cp = std.unicode.utf8Decode(text[0..len]) catch break :single;
        var buffer: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        _ = vt.input.encodeKey(&writer, .{
            .key = .unidentified,
            .action = .press,
            .utf8 = text,
            .unshifted_codepoint = cp,
        }, .fromTerminal(&model.session.term)) catch break :single;
        if (writer.end == 0) break :single;
        enqueueTransient(model, fx, buffer[0..writer.end]);
        return;
    }
    enqueueTransient(model, fx, text);
}

fn keyIs(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

const MappedKey = struct {
    key: vt.input.Key,
    utf8: []const u8 = "",
    unshifted: u21 = 0,
};

/// Host key names -> emulator key codes, for keys that do not commit
/// A plain printable's codepoint-keyed event, for RELEASE encoding
/// only: its press travels the committed-text channel, but kitty event
/// reporting still owes the child the release of the same key. No text
/// rides a release.
fn mapPrintable(key: []const u8) ?MappedKey {
    if (key.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(key[0]) catch return null;
    if (key.len != len) return null;
    const cp = std.unicode.utf8Decode(key[0..len]) catch return null;
    return .{ .key = .unidentified, .unshifted = cp };
}

/// text (specials always; letters/digits only under a chord modifier,
/// where the text channel stays silent and the encoder must speak).
fn mapKey(event: canvas.WidgetKeyboardEvent) ?MappedKey {
    const key = event.key;
    const specials = [_]struct { name: []const u8, key: vt.input.Key }{
        .{ .name = "enter", .key = .enter },
        .{ .name = "tab", .key = .tab },
        .{ .name = "escape", .key = .escape },
        .{ .name = "backspace", .key = .backspace },
        .{ .name = "delete", .key = .delete },
        .{ .name = "arrowup", .key = .arrow_up },
        .{ .name = "arrowdown", .key = .arrow_down },
        .{ .name = "arrowleft", .key = .arrow_left },
        .{ .name = "arrowright", .key = .arrow_right },
        .{ .name = "home", .key = .home },
        .{ .name = "end", .key = .end },
        .{ .name = "pageup", .key = .page_up },
        .{ .name = "pagedown", .key = .page_down },
        .{ .name = "insert", .key = .insert },
        // Function keys produce no committed text, so the encoder must
        // build their escape sequences or the child never sees them.
        .{ .name = "f1", .key = .f1 },
        .{ .name = "f2", .key = .f2 },
        .{ .name = "f3", .key = .f3 },
        .{ .name = "f4", .key = .f4 },
        .{ .name = "f5", .key = .f5 },
        .{ .name = "f6", .key = .f6 },
        .{ .name = "f7", .key = .f7 },
        .{ .name = "f8", .key = .f8 },
        .{ .name = "f9", .key = .f9 },
        .{ .name = "f10", .key = .f10 },
        .{ .name = "f11", .key = .f11 },
        .{ .name = "f12", .key = .f12 },
    };
    for (specials) |entry| {
        if (keyIs(key, entry.name)) return .{ .key = entry.key };
    }
    // Chorded character keys (ctrl+c, alt+f, ...): the text channel is
    // silent for these, so the encoder builds the control sequence.
    // Alt is a chord EXCEPT on macOS, where Option is a compose key —
    // Option+F commits the composed `ƒ` through the text channel, so
    // encoding an Alt-F escape here too would double the input (the
    // child would see both). On macOS, Option composes; everywhere else
    // Alt is Meta (ESC prefix, no composed text) — EXCEPT Ctrl+Alt
    // together ON WINDOWS, which is how that host represents AltGr:
    // the combination composes text there (AltGr+Q commits `@` through
    // the text channel), so encoding it as a chord would send wrong
    // bytes AND shadow the composed character. Linux keeps Ctrl+Alt as
    // a genuine chord — its AltGr is a distinct modifier that never
    // reports as ctrl+alt, so Ctrl+Alt+C must still encode.
    const altgr = event.modifiers.control and event.modifiers.alt and builtin.os.tag == .windows;
    const alt_is_chord = event.modifiers.alt and builtin.os.tag != .macos;
    const chorded = (event.modifiers.control or event.modifiers.super or alt_is_chord) and !altgr;
    if (!chorded) return null;
    if (key.len == 1) {
        // The emulator's encoder expects the pressed CHARACTER as UTF-8
        // alongside the logical key — the shape its host normally
        // supplies — and derives the chord bytes from it: legacy C0
        // sequences (Ctrl+C -> 0x03, Ctrl+\ -> 0x1C) where they exist,
        // and the fixterms CSI-u encoding for the exceptions (Ctrl+[,
        // Ctrl+I, Ctrl+M keep their unchorded bytes unambiguous).
        const ch = key[0];
        const utf8 = key[0..1];
        if (ch >= 'a' and ch <= 'z') {
            const base = @intFromEnum(vt.input.Key.key_a);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - 'a')),
                .utf8 = utf8,
                .unshifted = ch,
            };
        }
        if (ch >= '0' and ch <= '9') {
            const base = @intFromEnum(vt.input.Key.digit_0);
            return .{
                .key = @enumFromInt(base + @as(c_int, ch - '0')),
                .utf8 = utf8,
                .unshifted = ch,
            };
        }
        // Chorded punctuation carries real control meaning a terminal
        // user expects — Ctrl+[ is the ESC chord, Ctrl+\ is SIGQUIT,
        // Ctrl+] exits telnet — and has no text-channel fallback, so an
        // unmapped key here is silently lost input.
        const punctuation = [_]struct { ch: u8, key: vt.input.Key }{
            .{ .ch = '[', .key = .bracket_left },
            .{ .ch = ']', .key = .bracket_right },
            .{ .ch = '\\', .key = .backslash },
            .{ .ch = ';', .key = .semicolon },
            .{ .ch = '\'', .key = .quote },
            .{ .ch = ',', .key = .comma },
            .{ .ch = '.', .key = .period },
            .{ .ch = '/', .key = .slash },
            .{ .ch = '-', .key = .minus },
            .{ .ch = '=', .key = .equal },
            .{ .ch = '`', .key = .backquote },
        };
        for (punctuation) |entry| {
            if (ch == entry.ch) return .{ .key = entry.key, .utf8 = utf8, .unshifted = entry.ch };
        }
    }
    if (keyIs(key, "space")) return .{ .key = .space, .utf8 = " ", .unshifted = ' ' };
    return null;
}

// ------------------------------------------------------------------ view

const TerminalUi = TerminalApp.Ui;

/// A pane's fallback accessibility label before its shell has produced
/// a screen. Stable per index so the layout test can find the stack.
fn paneFallbackLabel(index: usize) []const u8 {
    return switch (index) {
        0 => "Terminal grid 1",
        else => "Terminal grid 2",
    };
}

pub fn view(ui: *TerminalUi, model: *const Model) TerminalUi.Node {
    // The cockpit is panes PLUS ordinary widgets: a header row of real
    // native chrome above a row of pane stacks.
    //
    // The stacks paint NOTHING (a panel would draw its surface over the
    // grid) — they exist to put both panes' viewport text in the
    // accessibility tree, and now to be press targets that move focus.
    // Because `.stack` is not focusable (`defaultFocusable`), a press on
    // one RELEASES keyboard focus back to the app's `on_key`, which is
    // exactly the recovery path that makes the focusable button below
    // safe to ship: click the button and Enter goes to the button;
    // click a pane and the terminal has the keyboard again.
    var badges: [pane_count]TerminalUi.Node = undefined;
    for (&badges, &model.panes, 0..) |*node, *pane, index| {
        node.* = ui.el(.badge, .{
            .key = .{ .index = index },
            .size = .sm,
            .text = ui.fmt("{d}{s} {s} {d}B", .{
                index + 1,
                if (index == model.focus) "*" else "",
                @tagName(pane.phase),
                pane.output_bytes,
            }),
        }, .{});
    }

    const header = [_]TerminalUi.Node{
        ui.text(.{ .cross = .center }, "COCKPIT"),
        badges[0],
        badges[1],
        ui.spacer(1),
        // A REAL focusable control, not decoration: it is the honest
        // demonstration that panes and native widgets share one surface,
        // and it is the one interaction hazard worth pinning — while it
        // holds focus, Enter and Space activate the button instead of
        // reaching the shell.
        ui.button(.{ .size = .sm, .on_press = .restart_pane }, "Restart"),
    };

    var panes: [pane_count]TerminalUi.Node = undefined;
    for (&panes, &model.panes, 0..) |*node, *pane, index| {
        const screen = pane.session.screenText();
        node.* = ui.el(.stack, .{
            .key = .{ .index = index },
            .grow = 1,
            .on_press = .{ .focus_pane = @intCast(index) },
            .semantics = .{ .label = if (screen.len > 0) screen else paneFallbackLabel(index) },
        }, .{});
    }

    const header_nodes: []const TerminalUi.Node = &header;
    const pane_nodes: []const TerminalUi.Node = &panes;
    // The column's uniform padding IS `grid_inset`, and the leading
    // spacer is the hidden-inset titlebar band: together they reproduce
    // `paneFrames`' top edge exactly, which the layout-agreement test
    // pins to a quarter of a point.
    const titlebar_band = @max(0, @max(grid_inset, model.chrome_top + 4) - grid_inset);
    return ui.column(.{ .padding = grid_inset }, .{
        ui.el(.stack, .{ .height = titlebar_band }, .{}),
        ui.row(.{ .height = header_height, .gap = pane_gutter, .cross = .center }, header_nodes),
        ui.row(.{ .grow = 1, .gap = pane_gutter }, pane_nodes),
    });
}

/// The grids, painted as a variable-length chrome prefix beneath the
/// widget tree: real text through the canvas primitives, damage kept
/// row-shaped by stable command ids, one id namespace per pane.
///
/// The budgets are partitioned per the policy at the top of this file:
/// commands floor-and-slack (cumulative), text mirrored (per-paint
/// local), glyphs halved (per-paint local).
fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    const frames = paneFrames(model, size);
    for (&model.panes, frames, 0..) |*pane, frame, index| {
        try grid.paint(pane.session, builder, .{
            .frame = frame,
            // Pane 0 lays the full-bleed terminal background over the
            // WHOLE window (under the hidden-inset titlebar band too, so
            // the window reads as one surface); the others fill only
            // their own rect over it.
            .background_frame = if (index == 0) geometry.RectF.init(0, 0, size.width, size.height) else null,
            .tokens = tokens,
            .running = pane.phase == .live or pane.phase == .starting,
            // Window activation is global, pane focus is not: only the
            // focused pane of an active window paints a filled cursor.
            .focused = model.focused and index == model.focus,
            .selecting = pane.selecting,
            .command_budget = paneCommandBudget(index),
            .text_reserve = pane_text_reserve,
            .glyph_budget = pane_glyph_budget,
            .path_reserve = pane_path_reserve,
            .id_base = grid.paneIdBase(index),
        });
    }
}

/// Where each pane's grid lives, in canvas points: below the
/// hidden-inset titlebar band AND below the widget header row, width
/// split evenly with `pane_gutter` between.
///
/// This is the SECOND derivation of these rectangles — `view()` is the
/// first, and the layout engine owns that one. `ChromeOptions.build`
/// never receives the laid-out tree, so the two cannot share a result;
/// the layout-agreement test is what keeps them honest.
pub fn paneFrames(model: *const Model, size: geometry.SizeF) [pane_count]geometry.RectF {
    const top = @max(grid_inset, model.chrome_top + 4) + header_height;
    const usable = @max(0, size.width - grid_inset * 2);
    const gutters = pane_gutter * @as(f32, @floatFromInt(pane_count - 1));
    const width = @max(0, (usable - gutters) / @as(f32, @floatFromInt(pane_count)));
    const height = @max(0, size.height - top - grid_inset);
    var frames: [pane_count]geometry.RectF = undefined;
    for (&frames, 0..) |*frame, index| {
        frame.* = geometry.RectF.init(
            grid_inset + @as(f32, @floatFromInt(index)) * (width + pane_gutter),
            top,
            width,
            height,
        );
    }
    return frames;
}

/// Frame pump: derive the grid each pane's rect fits and dispatch a
/// resize Msg exactly when one changes (journaled, so replay resizes
/// identically). At most ONE Msg per frame, so a window resize that
/// moves both panes sequences across consecutive frames — safe, because
/// the painter clips every pane to its (possibly stale) frame.
fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const frames = paneFrames(model, frame.size);
    var pending = false;
    for (&model.panes, frames, 0..) |*pane, inner, index| {
        const session = pane.session;
        if (session.cell_width <= 0 or session.cell_height <= 0) continue;
        const proposed = grid.Session.clampGrid(
            @intFromFloat(@max(2, inner.width / session.cell_width)),
            @intFromFloat(@max(2, inner.height / session.cell_height)),
            pane_cell_ceiling,
        );
        if (proposed.x != pane.cols or proposed.y != pane.rows) {
            return .{ .viewport = .{
                .pane = @intCast(index),
                .cols = proposed.x,
                .rows = proposed.y,
                .size = frame.size,
            } };
        }
        // No resize for this pane: if bytes are still queued (a large
        // paste draining, or a child that read without echoing), or a
        // query reply sits retained in the emulator's buffer behind a
        // full ring, nudge the update loop to push more now that the
        // FIFO may have freed.
        if (pane.outbound_len > 0 or session.response_len > 0) pending = true;
    }
    if (pending) return .flush_outbound;
    return null;
}

// ------------------------------------------------------------------ main

pub fn appOptions() TerminalApp.Options {
    return .{
        .name = "terminal",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = initFx,
        .update_fx = update,
        .view = view,
        .on_key = onKey,
        // Key releases feed the encoder for the kitty protocol's event
        // reporting; `handleKey` branches on the phase.
        .key_release_events = true,
        .on_text = onText,
        .on_wheel = onWheel,
        .on_chrome = onChrome,
        .on_lifecycle = onLifecycle,
        .on_frame = onFrame,
        .chrome = .{
            .prefix_commands = chrome_command_envelope,
            .variable_prefix = true,
            .build = buildChrome,
        },
    };
}

pub fn main(init: std.process.Init) !void {
    var sessions: [pane_count]*grid.Session = undefined;
    var created: usize = 0;
    // The deferred expression runs at scope exit and reads `created`
    // THEN, so a partial run (one session made, the next failing) frees
    // exactly what exists — no double free, no leak.
    defer for (sessions[0..created]) |session| session.destroy();
    while (created < pane_count) : (created += 1) {
        sessions[created] = try grid.Session.create(std.heap.page_allocator, init.io, 80, 24);
    }
    const app_state = try std.heap.page_allocator.create(TerminalApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = TerminalApp.init(std.heap.page_allocator, initialModel(sessions), appOptions());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "terminal",
        .window_title = "Terminal",
        .bundle_id = "dev.native_sdk.terminal",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
    _ = @import("adversarial_tests.zig");
}
