//! Production phux cockpit. The fixture terminal remains in `main.zig` only
//! for the default demo/tests; `-Dphux-enabled` selects this entrypoint.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const grid_painter = @import("grid.zig");
const host_mod = @import("phux_host");
const transport = @import("phux_transport");
const extension = @import("phux_extension.zig");
const pointer_monitor = @import("phux_pointer.zig");
const c = host_mod.abi;

const pane_count: usize = 2;
const channel_key: u64 = 0x7068_7578;
const search_capacity: usize = 256;
const clipboard_key: u64 = 0x7068_7579;
const paste_clipboard_key: u64 = 0x7068_757a;
const display_command_budget: usize = 16 * 1024;
const canvas_label = "terminal-canvas";
const window_width: f32 = 980;
const window_height: f32 = 640;
const grid_inset: f32 = 8;
const header_height: f32 = 28;
const pane_gutter: f32 = 8;
const AttachConfig = struct {
    session: []const u8,
    cols: u16,
    rows: u16,
};

const shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "Remote terminal session",
    .accessibility_label = "phux terminal",
    .gpu_backend = .metal,
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .@"opaque",
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "phux",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const Selection = struct {
    active: bool = false,
    anchor: c.PhuxDocumentAnchor = std.mem.zeroes(c.PhuxDocumentAnchor),
    head: c.PhuxDocumentAnchor = std.mem.zeroes(c.PhuxDocumentAnchor),
    head_point: c.PhuxDocumentPoint = std.mem.zeroes(c.PhuxDocumentPoint),
};

const Projection = struct {
    gpa: std.mem.Allocator,
    cells: std.ArrayListUnmanaged(canvas.TerminalCell) = .empty,
    utf8: std.ArrayListUnmanaged(u8) = .empty,
    rows: std.ArrayListUnmanaged(canvas.TerminalRow) = .empty,
    screen_text: std.ArrayListUnmanaged(u8) = .empty,
    generation: host_mod.Generation = .{},
    cursor: ?canvas.TerminalCursor = null,
    scrollbar: canvas.TerminalScrollbar = .{},
    running: bool = false,
    style_limited: bool = false,

    fn init(gpa: std.mem.Allocator) Projection {
        return .{ .gpa = gpa };
    }

    fn deinit(projection: *Projection) void {
        projection.cells.deinit(projection.gpa);
        projection.rows.deinit(projection.gpa);
        projection.utf8.deinit(projection.gpa);
        projection.screen_text.deinit(projection.gpa);
    }

    fn refresh(projection: *Projection, source: *const host_mod.Grid) !void {
        const cell_count = source.cells.items.len;
        const projected_rows = @min(
            @as(usize, source.rows),
            if (source.cols == 0) 0 else cell_count / source.cols,
        );
        try projection.screen_text.ensureTotalCapacity(
            projection.gpa,
            source.utf8.items.len + projected_rows,
        );
        try projection.utf8.ensureTotalCapacity(projection.gpa, source.utf8.items.len);
        try projection.rows.ensureTotalCapacity(projection.gpa, projected_rows);
        try projection.cells.ensureTotalCapacity(projection.gpa, cell_count);
        projection.utf8.items.len = source.utf8.items.len;
        @memcpy(projection.utf8.items, source.utf8.items);
        projection.cells.items.len = cell_count;
        projection.rows.items.len = projected_rows;
        projection.screen_text.clearRetainingCapacity();
        projection.style_limited = false;
        for (source.cells.items[0..cell_count], projection.cells.items) |raw, *cell| {
            const start: usize = raw.utf8_offset;
            const end = @min(projection.utf8.items.len, start + raw.utf8_len);
            const cluster = if (start <= end) projection.utf8.items[start..end] else "";
            const cp: u21 = if (cluster.len == 0) 0 else std.unicode.utf8Decode(cluster) catch 0;
            var fg = canvas.Color.rgb8(raw.foreground_r, raw.foreground_g, raw.foreground_b);
            var bg = canvas.Color.rgb8(raw.background_r, raw.background_g, raw.background_b);
            if (raw.flags & c.PHUX_CLIENT_CELL_INVERSE != 0) std.mem.swap(canvas.Color, &fg, &bg);
            cell.* = .{
                .cp = if (raw.flags & c.PHUX_CLIENT_CELL_INVISIBLE != 0) 0 else cp,
                .cluster = if (cp == 0) "" else cluster,
                .fg = fg,
                .bg = bg,
                .underline = raw.underline != c.PHUX_UNDERLINE_NONE,
                .wide = switch (raw.wide) {
                    c.PHUX_CELL_WIDE => .wide,
                    c.PHUX_CELL_SPACER_TAIL, c.PHUX_CELL_SPACER_HEAD => .spacer,
                    else => .narrow,
                },
            };
            const unsupported = c.PHUX_CLIENT_CELL_BOLD | c.PHUX_CLIENT_CELL_ITALIC |
                c.PHUX_CLIENT_CELL_FAINT | c.PHUX_CLIENT_CELL_BLINK |
                c.PHUX_CLIENT_CELL_STRIKETHROUGH | c.PHUX_CLIENT_CELL_OVERLINE |
                c.PHUX_CLIENT_CELL_PROTECTED | c.PHUX_CLIENT_CELL_HYPERLINK;
            projection.style_limited = projection.style_limited or raw.flags & unsupported != 0 or
                (raw.underline != c.PHUX_UNDERLINE_NONE and raw.underline != c.PHUX_UNDERLINE_SINGLE);
        }

        const cols: usize = source.cols;
        for (projection.rows.items, 0..) |*row, row_index| {
            const first = row_index * cols;
            const last = @min(first + cols, projection.cells.items.len);
            row.* = .{ .cells = projection.cells.items[first..last] };
            var selected_first: ?u16 = null;
            var selected_last: u16 = 0;
            for (source.cells.items[first..last], 0..) |raw, col| {
                if (raw.flags & c.PHUX_CLIENT_CELL_SELECTED != 0) {
                    if (selected_first == null) selected_first = @intCast(col);
                    selected_last = @intCast(col);
                }
                const start: usize = raw.utf8_offset;
                const end = @min(projection.utf8.items.len, start + raw.utf8_len);
                if (start <= end) projection.screen_text.appendSliceAssumeCapacity(projection.utf8.items[start..end]);
            }
            if (selected_first) |first_selected| row.selection = .{ first_selected, selected_last };
            if (row_index + 1 < projection.rows.items.len) projection.screen_text.appendAssumeCapacity('\n');
        }

        projection.generation = source.generation;
        projection.running = true;
        projection.cursor = if (source.cursor_visible) .{
            .x = source.cursor_col,
            .y = source.cursor_row,
            .shape = switch (source.cursor_style) {
                c.PHUX_CURSOR_BAR => .bar,
                c.PHUX_CURSOR_UNDERLINE => .underline,
                else => .block,
            },
        } else null;
        projection.scrollbar = .{
            .offset = @intCast(@min(source.history_viewport_offset, @as(u64, std.math.maxInt(u32)))),
            .len = @intCast(@min(source.history_visible_rows, @as(u64, std.math.maxInt(u32)))),
            .total = @intCast(@min(source.history_total_rows, @as(u64, std.math.maxInt(u32)))),
        };
    }
    fn clear(projection: *Projection) void {
        projection.utf8.items.len = 0;
        projection.cells.items.len = 0;
        projection.rows.items.len = 0;
        projection.screen_text.clearRetainingCapacity();
        projection.cursor = null;
        projection.scrollbar = .{};
        projection.running = false;
    }

    fn snapshot(projection: *const Projection, tokens: canvas.DesignTokens) canvas.TerminalGrid {
        return .{
            .rows = projection.rows.items,
            .background = tokens.colors.background,
            .foreground = tokens.colors.text,
            .cursor_color = tokens.colors.accent,
            .selection_color = tokens.colors.accent,
            .cursor = projection.cursor,
            .running = projection.running,
            .scrollbar = projection.scrollbar,
            .screen_text = projection.screen_text.items,
        };
    }
};

pub const Model = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    bridge: *transport.Bridge,
    host: *host_mod.Host,
    worker: ?*extension.Worker = null,
    pointer: pointer_monitor.Monitor = .{},
    pointer_capture: ?usize = null,
    endpoint: extension.Endpoint,
    config: AttachConfig,
    client_name: []const u8,
    projections: [pane_count]Projection,
    search_buffer: canvas.TextBuffer(search_capacity) = .{},
    selections: [pane_count]Selection = [_]Selection{.{}} ** pane_count,
    focus: usize = 0,
    attached_requested: bool = false,
    reconnect_requested: bool = false,
    channel_live: bool = false,
    copy_inflight: bool = false,
    failed: bool = false,
    surface_size: geometry.SizeF = geometry.SizeF.init(window_width, window_height),
    status: [256]u8 = undefined,
    status_len: usize = 0,

    fn setStatus(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.status.len);
        @memcpy(model.status[0..len], text[0..len]);
        model.status_len = len;
    }

    fn statusText(model: *const Model) []const u8 {
        return model.status[0..model.status_len];
    }

    fn refreshProjections(model: *Model) void {
        for (0..@min(model.host.panes.items.len, pane_count)) |index| {
            const pane = &model.host.panes.items[index];
            switch (pane.phase) {
                .live => model.projections[index].refresh(&pane.grid) catch {
                    model.projections[index].clear();
                    model.failed = true;
                    model.setStatus("grid projection failed");
                },
                .tombstoned, .closed, .failed => model.projections[index].clear(),
                .attaching, .reconnecting, .frozen => {},
            }
        }
    }

    fn consumeNotices(model: *Model) void {
        while (model.host.takeNotice()) |notice| {
            defer model.host.releaseNotice(notice);
            if (notice.bytes.len > 0) model.setStatus(notice.bytes);
        }
    }

    fn shutdown(model: *Model) void {
        model.pointer.stop();
        if (model.worker) |worker| worker.stop();
        model.worker = null;
        model.host.destroy();
        model.bridge.deinit();
        model.gpa.destroy(model.bridge);
        for (&model.projections) |*projection| projection.deinit();
    }
};

pub const Msg = union(enum) {
    channel: native_sdk.EffectChannelEvent,
    key: canvas.WidgetKeyboardEvent,
    text: canvas.WidgetKeyboardEvent,
    search_edit: canvas.TextInputEvent,
    wheel: native_sdk.platform.WheelEvent,
    resize: struct { cols: u16, rows: u16, size: geometry.SizeF },
    paste_clipboard: native_sdk.EffectClipboardResult,
    focus_pane: u8,
    focus_changed: bool,
    reconnect,
    copy,
    clipboard: native_sdk.EffectClipboardResult,
};

const PhuxApp = native_sdk.UiApp(Model, Msg);
const Effects = PhuxApp.Effects;
const PhuxUi = canvas.Ui(Msg);

fn openTransport(model: *Model, fx: *Effects) void {
    const handle = fx.openChannel(.{ .key = channel_key, .on_event = Effects.channelMsg(.channel) });
    if (!handle.live()) {
        model.failed = true;
        model.setStatus("transport channel unavailable");
        return;
    }
    model.worker = extension.Worker.start(model.io, model.gpa, model.bridge, handle, model.endpoint) catch {
        fx.closeChannel(channel_key);
        model.failed = true;
        model.setStatus("socket worker failed to start");
        return;
    };
    model.channel_live = true;
    model.setStatus("negotiating protocol 0.7");
}

fn initFx(model: *Model, fx: *Effects) void {
    model.host.start(model.client_name) catch {
        model.failed = true;
        model.setStatus("HELLO queue failed");
        return;
    };
    openTransport(model, fx);
}
fn restartTransport(model: *Model, fx: *Effects) void {
    model.reconnect_requested = false;
    model.bridge.incoming.reset();
    model.bridge.outgoing.reset();
    const replacement = host_mod.Host.create(model.gpa, model.bridge) catch {
        model.failed = true;
        model.setStatus("client restart failed");
        return;
    };
    model.host.destroy();
    model.host = replacement;
    model.attached_requested = false;
    model.failed = false;
    model.host.start(model.client_name) catch {
        model.failed = true;
        model.setStatus("HELLO retry failed");
        return;
    };
    openTransport(model, fx);
}

fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .channel => |event| switch (event.kind) {
            .data => {
                model.host.drainReadiness() catch {
                    model.failed = true;
                    model.setStatus("connection lost; published panes frozen");
                    model.refreshProjections();
                    return;
                };
                if (!model.attached_requested and model.host.state() == c.PHUX_CLIENT_STATE_NEGOTIATED) {
                    model.host.attach(model.config.session, model.config.cols, model.config.rows) catch {
                        model.failed = true;
                        model.setStatus("ATTACH queue failed");
                        return;
                    };
                    model.attached_requested = true;
                    model.setStatus("attaching panes");
                }
                model.refreshProjections();
                model.consumeNotices();
                if (model.host.state() == c.PHUX_CLIENT_STATE_ATTACHED) model.setStatus("attached");
            },
            .closed, .rejected => {
                model.channel_live = false;
                if (model.worker) |worker| worker.stop();
                model.worker = null;
                if (model.reconnect_requested) {
                    restartTransport(model, fx);
                } else {
                    model.failed = true;
                    model.setStatus("transport closed; published panes frozen");
                }
            },
        },
        .reconnect => {
            if (model.reconnect_requested) return;
            model.reconnect_requested = true;
            if (model.worker) |worker| worker.stop();
            model.worker = null;
            if (model.channel_live) fx.closeChannel(channel_key) else restartTransport(model, fx);
        },
        .focus_pane => |pane| {
            const next = @min(@as(usize, pane), pane_count - 1);
            if (next == model.focus) return;
            model.host.sendFocus(model.focus, false) catch {};
            model.focus = next;
            model.host.sendFocus(model.focus, true) catch {};
        },
        .focus_changed => |focused| model.host.sendFocus(model.focus, focused) catch {},
        .resize => |resize| {
            model.surface_size = resize.size;
            model.config.cols = resize.cols;
            model.config.rows = resize.rows;
            model.host.viewportResize(resize.cols, resize.rows, null) catch {
                model.failed = true;
                model.setStatus("viewport resize rejected");
            };
        },
        .wheel => |wheel| {
            const pane = paneAtPoint(model, wheel.x, wheel.y) orelse model.focus;
            const rows: i64 = @intFromFloat(@round(wheel.delta_y / 16));
            if (rows != 0) model.host.scrollViewport(pane, c.PHUX_VIEWPORT_SCROLL_DELTA, -rows) catch {};
            model.refreshProjections();
        },
        .key => |event| handleKey(model, event, fx),
        .text => |event| {
            if (event.text.len == 0) return;
            sendKey(model, event, c.PHUX_KEY_PRESS, c.PHUX_KEY_UNIDENTIFIED, event.text);
        },
        .search_edit => |edit| {
            model.search_buffer.apply(edit);
            const query = model.search_buffer.text();
            if (query.len == 0) {
                model.host.clearSearchResults();
                model.setStatus("search cleared");
                return;
            }
            const matches = model.host.search(model.focus, query, false) catch {
                model.failed = true;
                model.setStatus("terminal search failed");
                return;
            };
            const status = std.fmt.bufPrint(&model.status, "{d} search matches", .{matches.len}) catch {
                model.setStatus("search complete");
                return;
            };
            model.status_len = status.len;
        },
        .copy => {
            if (model.copy_inflight) return;
            const text = model.host.selectionText(model.focus, model.gpa) catch {
                model.setStatus("selection copy failed");
                return;
            };
            defer model.gpa.free(text);
            model.copy_inflight = true;
            fx.writeClipboard(.{ .key = clipboard_key, .text = text, .on_result = Effects.clipboardMsg(.clipboard) });
        },
        .clipboard => |result| {
            model.copy_inflight = false;
            if (result.outcome == .ok) {
                clearSelection(model, model.focus);
                model.refreshProjections();
                model.setStatus("selection copied");
            } else model.setStatus("clipboard write failed; selection retained");
        },
        .paste_clipboard => |result| {
            if (result.outcome != .ok) {
                model.setStatus("clipboard read failed");
                return;
            }
            if (result.text.len == 0) return;
            model.host.sendPaste(model.focus, result.text, false) catch {
                model.failed = true;
                model.setStatus("terminal paste rejected");
            };
        },
    }
}

fn handleKey(model: *Model, event: canvas.WidgetKeyboardEvent, fx: *Effects) void {
    const primary = event.modifiers.control or event.modifiers.super;
    if (event.phase == .key_down and primary and keyIs(event.key, "r")) {
        update(model, .reconnect, fx);
        return;
    }
    if (event.phase == .key_down and primary and event.key.len == 1 and event.key[0] >= '1' and event.key[0] <= '2') {
        model.focus = @intCast(event.key[0] - '1');
        return;
    }
    if (event.phase == .key_down and primary and keyIs(event.key, "c") and model.selections[model.focus].active) {
        update(model, .copy, fx);
        return;
    }
    if (event.phase == .key_down and primary and keyIs(event.key, "v")) {
        fx.readClipboard(.{ .key = paste_clipboard_key, .on_result = Effects.clipboardMsg(.paste_clipboard) });
        return;
    }
    if (event.phase == .key_down and primary and event.modifiers.shift and keyIs(event.key, "space")) {
        beginSelection(model);
        return;
    }
    if (model.selections[model.focus].active and event.phase == .key_down) {
        if (keyIs(event.key, "escape")) {
            clearSelection(model, model.focus);
            model.refreshProjections();
            return;
        }
        if (keyIs(event.key, "enter")) {
            update(model, .copy, fx);
            return;
        }
        if (moveSelection(model, event)) return;
    }
    const physical = physicalKey(event.key);
    const action: u32 = if (event.phase == .key_up) c.PHUX_KEY_RELEASE else c.PHUX_KEY_PRESS;
    const printable_unmodified = event.phase == .key_down and event.key.len == 1 and
        !(event.modifiers.shift or event.modifiers.control or event.modifiers.alt or event.modifiers.super);
    if (!printable_unmodified) sendKey(model, event, action, physical, "");
}

fn sendKey(model: *Model, event: canvas.WidgetKeyboardEvent, action: u32, physical: u32, text: []const u8) void {
    const mods = modifierMask(event.modifiers);
    const key: c.PhuxKeyEvent = .{
        .size = @sizeOf(c.PhuxKeyEvent),
        .version = c.PHUX_CLIENT_ABI_VERSION,
        .action = action,
        .key = physical,
        .modifiers = mods,
        .consumed_modifiers = 0,
        .composing = false,
        .has_text = text.len > 0,
        .text = .{ .data = if (text.len == 0) null else text.ptr, .len = text.len },
        .has_unshifted_codepoint = false,
        .unshifted_codepoint = 0,
    };
    model.host.sendKey(model.focus, &key) catch {
        model.setStatus("terminal input is not eligible");
    };
}

fn beginSelection(model: *Model) void {
    if (model.focus >= model.host.panes.items.len) return;
    const grid = &model.host.panes.items[model.focus].grid;
    const point: c.PhuxDocumentPoint = .{
        .space = c.PHUX_DOCUMENT_VIEWPORT,
        .row = grid.cursor_row,
        .column = grid.cursor_col,
        .reserved = 0,
    };
    const anchor = model.host.createAnchor(model.focus, point) catch {
        model.setStatus("selection anchor unavailable");
        return;
    };
    model.selections[model.focus] = .{ .active = true, .anchor = anchor, .head = anchor, .head_point = point };
    model.host.setSelection(model.focus, anchor, anchor, false) catch {
        model.host.releaseAnchor(model.focus, anchor);
        model.selections[model.focus] = .{};
    };
    model.refreshProjections();
}

fn clearSelection(model: *Model, pane_index: usize) void {
    if (pane_index >= model.selections.len) return;
    const selection = &model.selections[pane_index];
    model.host.clearSelection(pane_index) catch {};
    if (selection.active) {
        if (selection.head.opaque_id != selection.anchor.opaque_id)
            model.host.releaseAnchor(pane_index, selection.head);
        model.host.releaseAnchor(pane_index, selection.anchor);
    }
    selection.* = .{};
}

fn moveSelection(model: *Model, event: canvas.WidgetKeyboardEvent) bool {
    var selection = &model.selections[model.focus];
    var next = selection.head_point;
    var moved = true;
    if (keyIs(event.key, "arrowleft")) {
        if (next.column > 0) next.column -= 1;
    } else if (keyIs(event.key, "arrowright")) next.column +|= 1 else if (keyIs(event.key, "arrowup")) {
        if (next.row > 0) next.row -= 1;
    } else if (keyIs(event.key, "arrowdown")) next.row +|= 1 else moved = false;
    if (!moved) return false;
    const next_head = model.host.createAnchor(model.focus, next) catch {
        selection.active = false;
        model.setStatus("selection became stale");
        return true;
    };
    model.host.setSelection(model.focus, selection.anchor, next_head, false) catch {
        model.host.releaseAnchor(model.focus, next_head);
        selection.active = false;
        model.setStatus("selection became stale");
        return true;
    };
    if (selection.head.opaque_id != selection.anchor.opaque_id)
        model.host.releaseAnchor(model.focus, selection.head);
    selection.head = next_head;
    selection.head_point = next;
    model.refreshProjections();
    return true;
}

fn modifierMask(mods: canvas.WidgetKeyboardModifiers) u16 {
    var result: u16 = 0;
    if (mods.shift) result |= c.PHUX_MOD_SHIFT;
    if (mods.control) result |= c.PHUX_MOD_CONTROL;
    if (mods.alt) result |= c.PHUX_MOD_ALT;
    if (mods.super) result |= c.PHUX_MOD_SUPER;
    return result;
}

fn physicalKey(key: []const u8) u32 {
    const names = [_]struct { name: []const u8, value: u32 }{
        .{ .name = "enter", .value = c.PHUX_KEY_ENTER },            .{ .name = "tab", .value = c.PHUX_KEY_TAB },
        .{ .name = "escape", .value = c.PHUX_KEY_ESCAPE },          .{ .name = "backspace", .value = c.PHUX_KEY_BACKSPACE },
        .{ .name = "delete", .value = c.PHUX_KEY_DELETE },          .{ .name = "arrowup", .value = c.PHUX_KEY_ARROW_UP },
        .{ .name = "arrowdown", .value = c.PHUX_KEY_ARROW_DOWN },   .{ .name = "arrowleft", .value = c.PHUX_KEY_ARROW_LEFT },
        .{ .name = "arrowright", .value = c.PHUX_KEY_ARROW_RIGHT }, .{ .name = "home", .value = c.PHUX_KEY_HOME },
        .{ .name = "end", .value = c.PHUX_KEY_END },                .{ .name = "pageup", .value = c.PHUX_KEY_PAGE_UP },
        .{ .name = "pagedown", .value = c.PHUX_KEY_PAGE_DOWN },     .{ .name = "insert", .value = c.PHUX_KEY_INSERT },
        .{ .name = "space", .value = c.PHUX_KEY_SPACE },
    };
    for (names) |entry| if (keyIs(key, entry.name)) return entry.value;
    if (key.len == 1) {
        const ch = std.ascii.toLower(key[0]);
        if (ch >= 'a' and ch <= 'z') return @as(u32, @intCast(c.PHUX_KEY_A)) + ch - 'a';
        if (ch >= '0' and ch <= '9') return @as(u32, @intCast(c.PHUX_KEY_DIGIT0)) + ch - '0';
    }
    if (key.len >= 2 and (key[0] == 'f' or key[0] == 'F')) {
        const number = std.fmt.parseInt(u8, key[1..], 10) catch 0;
        if (number >= 1 and number <= 24) return @as(u32, @intCast(c.PHUX_KEY_F1)) + number - 1;
    }
    return c.PHUX_KEY_UNIDENTIFIED;
}

fn keyIs(key: []const u8, name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, name);
}

fn view(ui: *PhuxUi, model: *const Model) PhuxUi.Node {
    const style_note = for (&model.projections) |*projection| {
        if (projection.style_limited) break " · painter subset: advanced styles retained but simplified";
    } else "";
    const status = ui.fmt("{s}{s}", .{ model.statusText(), style_note });
    var pane_nodes: [pane_count]PhuxUi.Node = undefined;
    for (&pane_nodes, 0..) |*node, index| {
        const label = if (index < model.host.panes.items.len and model.host.panes.items[index].title.items.len > 0)
            model.host.panes.items[index].title.items
        else if (index == 0) "Remote pane 1" else "Remote pane 2";
        node.* = ui.el(.stack, .{
            .grow = 1,
            .on_press = .{ .focus_pane = @intCast(index) },
            .semantics = .{ .label = label },
        }, .{});
    }
    return ui.column(.{ .padding = grid_inset }, .{
        ui.row(.{ .height = header_height, .gap = pane_gutter, .cross = .center }, .{
            ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, status),
            ui.el(.text_field, .{
                .width = 220,
                .text = model.search_buffer.text(),
                .placeholder = "Search terminal",
                .on_input = PhuxUi.inputMsg(.search_edit),
                .semantics = .{ .label = "Search terminal output" },
            }, .{}),
            ui.spacer(1),
            ui.button(.{ .size = .sm, .on_press = .reconnect }, "Reconnect"),
        }),
        ui.row(.{ .grow = 1, .gap = pane_gutter }, @as([]PhuxUi.Node, &pane_nodes)),
    });
}

fn paneFrames(model: *const Model, size: geometry.SizeF) [pane_count]geometry.RectF {
    _ = model;
    const top = grid_inset + header_height;
    const usable = @max(0, size.width - grid_inset * 2);
    const width = @max(0, (usable - pane_gutter) / 2);
    const height = @max(0, size.height - top - grid_inset);
    return .{
        geometry.RectF.init(grid_inset, top, width, height),
        geometry.RectF.init(grid_inset + width + pane_gutter, top, width, height),
    };
}

fn buildChrome(model: *const Model, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    const frames = paneFrames(model, size);
    for (&model.projections, frames, 0..) |*projection, frame, index| {
        try grid_painter.paintTerminalGrid(projection.snapshot(tokens), builder, .{
            .frame = frame,
            .background_frame = if (index == 0) geometry.RectF.init(0, 0, size.width, size.height) else null,
            .tokens = tokens,
            .running = projection.running,
            .focused = index == model.focus,
            .selecting = model.selections[index].active,
            .command_budget = display_command_budget / pane_count - 32,
            .text_reserve = 512,
            .glyph_budget = 3500,
            .path_reserve = 128,
            .id_base = grid_painter.paneIdBase(index),
        });
    }
}

fn onKey(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .key = event };
}
fn onText(event: canvas.WidgetKeyboardEvent) ?Msg {
    return .{ .text = event };
}
fn onWheel(event: native_sdk.platform.WheelEvent) ?Msg {
    return .{ .wheel = event };
}
fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
    return switch (event) {
        .activate => .{ .focus_changed = true },
        .deactivate => .{ .focus_changed = false },
        else => null,
    };
}

fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    if (frame.size.width <= 0 or frame.size.height <= 0) return null;
    const metrics = canvas.terminalCellMetrics(canvas.DesignTokens{});
    const pane = paneFrames(model, frame.size)[model.focus];
    const cols: u16 = @intFromFloat(std.math.clamp(@floor(pane.width / @max(metrics.width, 1)), 2, 1000));
    const rows: u16 = @intFromFloat(std.math.clamp(@floor(pane.height / @max(metrics.height, 1)), 2, 1000));
    if (cols == model.config.cols and rows == model.config.rows and
        frame.size.width == model.surface_size.width and frame.size.height == model.surface_size.height) return null;
    return .{ .resize = .{ .cols = cols, .rows = rows, .size = frame.size } };
}

fn paneAtPoint(model: *const Model, x: f32, y: f32) ?usize {
    const frames = paneFrames(model, model.surface_size);
    for (frames, 0..) |frame, index| if (frame.normalized().containsPoint(geometry.PointF.init(x, y))) return index;
    return null;
}

fn onRawPointer(context: ?*anyopaque, sample: *const pointer_monitor.Event) callconv(.c) void {
    const model: *Model = @ptrCast(@alignCast(context orelse return));
    const pointed = paneAtPoint(model, @floatCast(sample.x), @floatCast(sample.y));
    const index = if (sample.kind == c.PHUX_MOUSE_PRESS)
        pointed orelse return
    else
        model.pointer_capture orelse pointed orelse return;
    if (sample.kind == c.PHUX_MOUSE_PRESS) model.pointer_capture = index;
    if (sample.kind == c.PHUX_MOUSE_RELEASE) model.pointer_capture = null;
    const frame = paneFrames(model, model.surface_size)[index];
    const button: u32 = if (sample.button == std.math.maxInt(u32))
        c.PHUX_MOUSE_BUTTON_UNKNOWN
    else
        @min(sample.button + 1, c.PHUX_MOUSE_BUTTON_ELEVEN);
    const event: c.PhuxMouseEvent = .{
        .size = @sizeOf(c.PhuxMouseEvent),
        .version = c.PHUX_CLIENT_ABI_VERSION,
        .action = sample.kind,
        .button = button,
        .modifiers = sample.modifiers,
        .x = sample.x - @as(f64, frame.x),
        .y = sample.y - @as(f64, frame.y),
    };
    model.host.sendMouse(index, &event) catch {
        model.failed = true;
        model.setStatus("terminal mouse input failed");
    };
}
fn appOptions() PhuxApp.Options {
    return .{
        .name = "phux-terminal",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .init_fx = initFx,

        .update_fx = update,
        .view = view,
        .on_key = onKey,
        .key_release_events = true,
        .on_text = onText,
        .on_wheel = onWheel,
        .on_lifecycle = onLifecycle,
        .on_frame = onFrame,
        .chrome = .{
            .prefix_commands = display_command_budget - 256,
            .variable_prefix = true,
            .build = buildChrome,
        },
    };
}
fn initialModel(
    gpa: std.mem.Allocator,
    io: std.Io,
    endpoint: extension.Endpoint,
    session: []const u8,
    user: []const u8,
) !Model {
    const bridge = try gpa.create(transport.Bridge);
    errdefer gpa.destroy(bridge);
    bridge.* = .init(gpa);
    errdefer bridge.deinit();
    const client = try host_mod.Host.create(gpa, bridge);
    errdefer client.destroy();
    return .{
        .gpa = gpa,
        .io = io,
        .bridge = bridge,
        .host = client,
        .endpoint = endpoint,
        .config = .{ .session = session, .cols = 80, .rows = 24 },
        .client_name = user,
        .projections = .{ .init(gpa), .init(gpa) },
    };
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const endpoint_arg = args.next() orelse return error.MissingPhuxEndpoint;
    const session = args.next() orelse "default";
    const user = args.next() orelse "native";
    const endpoint: extension.Endpoint = if (std.mem.startsWith(u8, endpoint_arg, "unix://"))
        .{ .unix = endpoint_arg[7..] }
    else tcp: {
        const address = if (std.mem.startsWith(u8, endpoint_arg, "tcp://")) endpoint_arg[6..] else endpoint_arg;
        const split = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidPhuxEndpoint;
        const port = try std.fmt.parseInt(u16, address[split + 1 ..], 10);
        break :tcp .{ .tcp = .{ .host = address[0..split], .port = port } };
    };

    var model = try initialModel(std.heap.page_allocator, init.io, endpoint, session, user);
    const app_state = std.heap.page_allocator.create(PhuxApp) catch |err| {
        model.shutdown();
        return err;
    };
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = PhuxApp.init(std.heap.page_allocator, model, appOptions());
    defer app_state.model.shutdown();
    defer app_state.deinit();
    app_state.model.pointer = try pointer_monitor.Monitor.start(&app_state.model, onRawPointer);
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "phux",
        .window_title = "phux",
        .bundle_id = "dev.phux.native",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .security = .{ .permissions = &.{}, .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } } },
    }, init);
}
