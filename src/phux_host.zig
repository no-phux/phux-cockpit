//! Thin owning-thread host for the stable phux client C ABI.
//!
//! No callbacks, async traits, sockets, or renderer policy live here. The
//! native-sdk readiness extension stages frames in `phux_transport.Bridge`;
//! this UI-thread owner drains them, calls the synchronous FFI, copies only the
//! borrowed presentation grid into reusable buffers, and stages outgoing bytes.

const std = @import("std");
const transport = @import("phux_transport");
const c = @cImport({
    @cInclude("phux/client.h");
});
pub const abi = c;

pub const enabled = true;
pub const max_panes: usize = 16;
pub const max_satellite_host_bytes: usize = 255;

pub const PixelSize = struct { width: u16, height: u16 };
pub const Phase = enum { attaching, live, reconnecting, tombstoned, frozen, closed, failed };

pub const TerminalId = struct {
    kind: u32 = c.PHUX_TERMINAL_LOCAL,
    id: u32 = 0,
    host_storage: [max_satellite_host_bytes]u8 = undefined,
    host_len: usize = 0,

    fn fromC(raw: c.PhuxTerminalId) TerminalId {
        var out: TerminalId = .{ .kind = raw.kind, .id = raw.id };
        const len = @min(raw.host.len, out.host_storage.len);
        if (len > 0 and raw.host.data != null) {
            @memcpy(out.host_storage[0..len], raw.host.data[0..len]);
            out.host_len = len;
        }
        return out;
    }

    pub fn asC(id: *const TerminalId) c.PhuxTerminalId {
        return .{
            .kind = id.kind,
            .id = id.id,
            .host = .{
                .data = if (id.host_len == 0) null else id.host_storage[0..id.host_len].ptr,
                .len = id.host_len,
            },
        };
    }

    pub fn eql(a: TerminalId, b: TerminalId) bool {
        return a.kind == b.kind and a.id == b.id and
            std.mem.eql(u8, a.host_storage[0..a.host_len], b.host_storage[0..b.host_len]);
    }
};

pub const Generation = struct {
    stream_id: u64 = 0,
    bootstrap_id: u64 = 0,
    last_seq: u64 = 0,

    pub fn eql(a: Generation, b: Generation) bool {
        return a.stream_id == b.stream_id and a.bootstrap_id == b.bootstrap_id;
    }
};

pub const ReplicaOwner = struct {
    terminal_id: TerminalId,
    generation: Generation,

    pub fn eql(a: ReplicaOwner, b: ReplicaOwner) bool {
        return a.terminal_id.eql(b.terminal_id) and a.generation.eql(b.generation);
    }
};

pub const Grid = struct {
    gpa: std.mem.Allocator,
    terminal_id: TerminalId = .{},
    generation: Generation = .{},
    cols: u16 = 0,
    rows: u16 = 0,
    cells: std.ArrayListUnmanaged(c.PhuxTerminalCell) = .empty,
    utf8: std.ArrayListUnmanaged(u8) = .empty,
    cursor_visible: bool = false,
    cursor_col: u16 = 0,
    cursor_row: u16 = 0,
    cursor_style: u32 = 0,
    document_revision: u64 = 0,
    history_total_rows: u64 = 0,
    history_viewport_offset: u64 = 0,
    history_visible_rows: u64 = 0,
    history_loading: bool = false,
    history_pages_loaded: u64 = 0,
    history_bytes_loaded: u64 = 0,
    history_has_more: bool = false,
    // `top_anchor` is released immediately after every borrowed grid copy.

    pub fn init(gpa: std.mem.Allocator) Grid {
        return .{ .gpa = gpa };
    }

    pub fn deinit(grid: *Grid) void {
        grid.cells.deinit(grid.gpa);
        grid.utf8.deinit(grid.gpa);
    }

    pub fn copyBorrowed(grid: *Grid, view: *const c.PhuxTerminalGridView) !void {
        try grid.cells.ensureTotalCapacity(grid.gpa, view.cell_count);
        grid.cells.items.len = view.cell_count;
        if (view.cell_count > 0) @memcpy(grid.cells.items, view.cells[0..view.cell_count]);
        try grid.utf8.ensureTotalCapacity(grid.gpa, view.utf8.len);
        grid.utf8.items.len = view.utf8.len;
        if (view.utf8.len > 0) @memcpy(grid.utf8.items, view.utf8.data[0..view.utf8.len]);
        grid.terminal_id = .fromC(view.terminal_id);
        grid.generation = .{
            .stream_id = view.stream_id,
            .bootstrap_id = view.bootstrap_id,
            .last_seq = view.last_seq,
        };
        grid.cols = view.cols;
        grid.rows = view.rows;
        grid.cursor_visible = view.cursor_visible;
        grid.cursor_col = view.cursor_col;
        grid.cursor_row = view.cursor_row;
        grid.cursor_style = view.cursor_style;
        grid.document_revision = view.document_revision;
        grid.history_total_rows = view.history_total_rows;
        grid.history_viewport_offset = view.history_viewport_offset;
        grid.history_visible_rows = view.history_visible_rows;
        grid.history_loading = view.history_loading;
        grid.history_has_more = view.history_has_more;
        grid.history_pages_loaded = view.history_pages_loaded;
        grid.history_bytes_loaded = view.history_bytes_loaded;
        // The caller releases `view.top_anchor` after every complete copy.
    }
};

pub const Pane = struct {
    id: TerminalId = .{},
    phase: Phase = .attaching,
    dirty: bool = false,
    seen_in_attach: bool = false,
    remove_at_barrier: bool = false,
    grid: Grid,
    title: std.ArrayListUnmanaged(u8) = .empty,

    fn init(gpa: std.mem.Allocator, id: TerminalId) Pane {
        return .{ .id = id, .grid = .init(gpa) };
    }

    fn deinit(pane: *Pane, gpa: std.mem.Allocator) void {
        pane.grid.deinit();
        pane.title.deinit(gpa);
    }
};
pub const NoticeKind = enum { status, job };

pub const Notice = struct {
    kind: NoticeKind,
    detail: u32,
    terminal_id: TerminalId,
    generation: Generation,
    bytes: []u8,
};

pub const Error = error{ InvalidState, Protocol, Engine, OutOfMemory, Panic, NoValue };

fn resultError(result: c.PhuxClientResult) Error!void {
    return switch (result) {
        c.PHUX_CLIENT_OK => {},
        c.PHUX_CLIENT_NO_VALUE => error.NoValue,
        c.PHUX_CLIENT_INVALID_ARGUMENT, c.PHUX_CLIENT_INVALID_STATE => error.InvalidState,
        c.PHUX_CLIENT_PROTOCOL_ERROR => error.Protocol,
        c.PHUX_CLIENT_ENGINE_ERROR => error.Engine,
        c.PHUX_CLIENT_OUT_OF_MEMORY => error.OutOfMemory,
        else => error.Panic,
    };
}

pub const Host = struct {
    gpa: std.mem.Allocator,
    client: *c.PhuxClient,
    bridge: *transport.Bridge,
    panes: std.ArrayListUnmanaged(Pane) = .empty,
    search_results: std.ArrayListUnmanaged(c.PhuxSearchResult) = .empty,
    search_owner: ?ReplicaOwner = null,
    notices: std.ArrayListUnmanaged(Notice) = .empty,
    focused: ?usize = null,
    failed: bool = false,
    attach_barrier_seen: bool = false,

    pub fn create(gpa: std.mem.Allocator, bridge: *transport.Bridge) !*Host {
        const host = try gpa.create(Host);
        errdefer gpa.destroy(host);
        var raw: ?*c.PhuxClient = null;
        const options: c.PhuxClientOptions = .{
            .size = @sizeOf(c.PhuxClientOptions),
            .version = c.PHUX_CLIENT_ABI_VERSION,
            .max_bootstrap_chunk_bytes = 256 * 1024,
            .max_history_page_bytes = 1024 * 1024,
            .max_history_page_rows = 1024,
            .max_history_cache_bytes = 8 * 1024 * 1024,
            .max_history_materialized_rows = 8192,
            .history_prefetch_rows = 256,
        };
        try resultError(c.phux_client_new(&options, &raw));
        host.* = .{ .gpa = gpa, .client = raw orelse return error.InvalidState, .bridge = bridge };
        return host;
    }

    pub fn destroy(host: *Host) void {
        host.clearSearchResults();
        for (host.panes.items) |*pane| pane.deinit(host.gpa);
        host.panes.deinit(host.gpa);
        for (host.notices.items) |notice| host.gpa.free(notice.bytes);
        host.notices.deinit(host.gpa);
        host.search_results.deinit(host.gpa);
        c.phux_client_free(host.client);
        host.gpa.destroy(host);
    }

    pub fn state(host: *const Host) c.PhuxClientState {
        return c.phux_client_state(host.client);
    }

    pub fn start(host: *Host, client_name: []const u8) !void {
        try resultError(c.phux_client_queue_hello(host.client, bytes(client_name)));
        try host.stageOutgoing();
    }

    pub fn attach(
        host: *Host,
        session: []const u8,
        cols: u16,
        rows: u16,
        pixels: ?PixelSize,
    ) !void {
        const options: c.PhuxAttachOptions = .{
            .size = @sizeOf(c.PhuxAttachOptions),
            .version = c.PHUX_CLIENT_ABI_VERSION,
            .attach_id = 1,
            .target_kind = c.PHUX_ATTACH_CREATE_IF_MISSING,
            .session_id = 0,
            .name = bytes(session),
            .cols = cols,
            .rows = rows,
            .has_pixel_size = pixels != null,
            .pixel_width = if (pixels) |p| p.width else 0,
            .pixel_height = if (pixels) |p| p.height else 0,
            .request_scrollback = true,
            .scrollback_limit_lines = 5000,
        };
        try resultError(c.phux_client_queue_attach(host.client, &options));
        try host.stageOutgoing();
    }

    /// Owning-thread wake handler. Complete payloads came through `Bridge`,
    /// never through the native-sdk effect channel.
    pub fn drainReadiness(host: *Host) !void {
        while (host.bridge.incoming.take()) |frame| {
            defer host.bridge.incoming.release(frame);
            resultError(c.phux_client_feed_frame(host.client, frame.ptr, frame.len)) catch |err| {
                host.failed = true;
                for (host.panes.items) |*pane| pane.phase = .frozen;
                return err;
            };
        }
        host.captureEffects() catch |err| {
            host.failed = true;
            host.freezePublished();
            return err;
        };
        if (host.state() == c.PHUX_CLIENT_STATE_ATTACHED and !host.attach_barrier_seen) {
            host.finishAttachBarrier();
            host.attach_barrier_seen = true;
        }
        host.stageOutgoing() catch |err| {
            host.failed = true;
            host.freezePublished();
            return err;
        };
    }

    fn ensurePane(host: *Host, raw: c.PhuxTerminalId) !*Pane {
        const id = TerminalId.fromC(raw);
        for (host.panes.items) |*pane| if (pane.id.eql(id)) return pane;
        if (host.panes.items.len == max_panes) return error.OutOfMemory;
        try host.panes.append(host.gpa, .init(host.gpa, id));
        if (host.focused == null) host.focused = host.panes.items.len - 1;
        return &host.panes.items[host.panes.items.len - 1];
    }
    fn findPane(host: *Host, raw: c.PhuxTerminalId) ?*Pane {
        const id = TerminalId.fromC(raw);
        for (host.panes.items) |*pane| if (pane.id.eql(id)) return pane;
        return null;
    }

    fn finishAttachBarrier(host: *Host) void {
        host.clearSearchResults();
        var index = host.panes.items.len;
        while (index > 0) {
            index -= 1;
            const pane = &host.panes.items[index];
            if (!pane.seen_in_attach or pane.remove_at_barrier) {
                pane.deinit(host.gpa);
                _ = host.panes.orderedRemove(index);
            }
        }
        host.focused = if (host.panes.items.len == 0)
            null
        else
            @min(host.focused orelse 0, host.panes.items.len - 1);
    }

    pub fn replicaOwner(host: *const Host, pane_index: usize) ?ReplicaOwner {
        if (pane_index >= host.panes.items.len) return null;
        const pane = &host.panes.items[pane_index];
        return .{ .terminal_id = pane.id, .generation = pane.grid.generation };
    }

    pub fn ownerIsCurrent(host: *const Host, owner: ReplicaOwner) bool {
        for (host.panes.items) |pane| {
            const current: ReplicaOwner = .{ .terminal_id = pane.id, .generation = pane.grid.generation };
            if (current.eql(owner)) return true;
        }
        return false;
    }

    pub fn indexOfOwner(host: *const Host, owner: ReplicaOwner) ?usize {
        for (host.panes.items, 0..) |pane, index| {
            const current: ReplicaOwner = .{ .terminal_id = pane.id, .generation = pane.grid.generation };
            if (current.eql(owner)) return index;
        }
        return null;
    }

    fn captureEffects(host: *Host) !void {
        const count = c.phux_client_effect_count(host.client);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            var effect: c.PhuxClientEffect = undefined;
            try resultError(c.phux_client_effect_get(host.client, index, &effect));
            const terminal_id = TerminalId.fromC(effect.terminal_id);
            const effect_bytes: []const u8 = if (effect.bytes.len == 0) &.{} else effect.bytes.data[0..effect.bytes.len];
            switch (effect.kind) {
                c.PHUX_CLIENT_EFFECT_DAMAGE => {
                    const pane = try host.ensurePane(effect.terminal_id);
                    switch (effect.detail) {
                        c.PHUX_CLIENT_DAMAGE_REMOVED => {
                            pane.phase = .tombstoned;
                            pane.remove_at_barrier = true;
                        },
                        else => {
                            pane.dirty = true;
                            pane.phase = .live;
                            pane.seen_in_attach = true;
                            pane.remove_at_barrier = false;
                        },
                    }
                },
                c.PHUX_CLIENT_EFFECT_STATUS => {
                    switch (effect.detail) {
                        c.PHUX_CLIENT_STATUS_TITLE => {
                            const pane = try host.ensurePane(effect.terminal_id);
                            try pane.title.ensureTotalCapacity(host.gpa, effect_bytes.len);
                            pane.title.items.len = effect_bytes.len;
                            if (effect_bytes.len > 0) @memcpy(pane.title.items, effect_bytes);
                        },
                        c.PHUX_CLIENT_STATUS_RESYNC_REQUIRED => {
                            if (host.findPane(effect.terminal_id)) |pane| {
                                pane.phase = .frozen;
                            } else {
                                for (host.panes.items) |*pane| pane.phase = .frozen;
                            }
                        },
                        c.PHUX_CLIENT_STATUS_DETACHED => {
                            host.attach_barrier_seen = false;
                            for (host.panes.items) |*pane| {
                                pane.phase = .reconnecting;
                                pane.seen_in_attach = false;
                                pane.remove_at_barrier = false;
                            }
                        },
                        c.PHUX_CLIENT_STATUS_SERVER_ERROR => {
                            for (host.panes.items) |*pane| pane.phase = .failed;
                        },
                        else => {},
                    }
                    const payload = host.gpa.dupe(u8, effect_bytes) catch return error.OutOfMemory;
                    host.notices.append(host.gpa, .{
                        .kind = .status,
                        .detail = effect.detail,
                        .terminal_id = terminal_id,
                        .generation = .{
                            .stream_id = effect.stream_id,
                            .bootstrap_id = effect.bootstrap_id,
                            .last_seq = effect.seq,
                        },
                        .bytes = payload,
                    }) catch {
                        host.gpa.free(payload);
                        return error.OutOfMemory;
                    };
                },
                c.PHUX_CLIENT_EFFECT_JOB => {
                    const payload = host.gpa.dupe(u8, effect_bytes) catch return error.OutOfMemory;
                    host.notices.append(host.gpa, .{
                        .kind = .job,
                        .detail = effect.detail,
                        .terminal_id = terminal_id,
                        .generation = .{
                            .stream_id = effect.stream_id,
                            .bootstrap_id = effect.bootstrap_id,
                            .last_seq = effect.seq,
                        },
                        .bytes = payload,
                    }) catch {
                        host.gpa.free(payload);
                        return error.OutOfMemory;
                    };
                },
                else => return error.InvalidState,
            }
        }
        try resultError(c.phux_client_effect_clear(host.client));
        for (host.panes.items) |*pane| {
            if (!pane.dirty or pane.phase != .live) continue;
            const id = pane.id.asC();
            var view: c.PhuxTerminalGridView = undefined;
            const result = c.phux_client_terminal_grid(host.client, &id, &view);
            if (result == c.PHUX_CLIENT_NO_VALUE) {
                pane.phase = .frozen;
                continue;
            }
            try resultError(result);
            const top_anchor = view.top_anchor;
            pane.grid.copyBorrowed(&view) catch |err| {
                if (top_anchor.opaque_id != 0)
                    _ = c.phux_client_anchor_release(host.client, &id, top_anchor);
                return err;
            };
            if (top_anchor.opaque_id != 0)
                _ = c.phux_client_anchor_release(host.client, &id, top_anchor);
            pane.dirty = false;
        }
    }

    fn freezePublished(host: *Host) void {
        for (host.panes.items) |*pane| {
            if (pane.phase == .live or pane.phase == .attaching or pane.phase == .reconnecting) {
                pane.phase = .frozen;
            }
        }
    }

    fn stageOutgoing(host: *Host) !void {
        if (host.bridge.incoming.takeDisconnect() != null) {
            host.freezePublished();
            host.failed = true;
            return error.Protocol;
        }

        const count = c.phux_client_outgoing_count(host.client);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            var frame: c.PhuxBytes = undefined;
            try resultError(c.phux_client_outgoing_get(host.client, index, &frame));
            if (!host.bridge.outgoing.stage(frame.data[0..frame.len])) return error.OutOfMemory;
        }
        try resultError(c.phux_client_outgoing_clear(host.client));
    }

    /// Local viewport projection only; never resizes the canonical PTY.
    pub fn viewportResize(host: *Host, cols: u16, rows: u16, pixels: ?PixelSize) !void {
        try resultError(c.phux_client_viewport_resize(
            host.client,
            cols,
            rows,
            pixels != null,
            if (pixels) |p| p.width else 0,
            if (pixels) |p| p.height else 0,
        ));
        try host.stageOutgoing();
    }

    /// The only geometry path allowed to mutate the canonical PTY.
    pub fn explicitTerminalResize(host: *Host, pane_index: usize, cols: u16, rows: u16) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_terminal_resize(host.client, &id, cols, rows));
        try host.stageOutgoing();
    }

    pub fn sendKey(host: *Host, pane_index: usize, event: *const c.PhuxKeyEvent) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_send_key(host.client, &id, event));
        try host.stageOutgoing();
    }

    pub fn sendMouse(host: *Host, pane_index: usize, event: *const c.PhuxMouseEvent) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_send_mouse(host.client, &id, event));
        try host.stageOutgoing();
    }

    pub fn mouseTracking(host: *const Host, pane_index: usize) !bool {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        var tracking_enabled = false;
        try resultError(c.phux_client_terminal_mouse_tracking(host.client, &id, &tracking_enabled));
        return tracking_enabled;
    }

    /// Transfer one copied status/job notification to the UI owner.
    pub fn takeNotice(host: *Host) ?Notice {
        if (host.notices.items.len == 0) return null;
        return host.notices.orderedRemove(0);
    }

    pub fn releaseNotice(host: *Host, notice: Notice) void {
        host.gpa.free(notice.bytes);
    }

    pub fn sendFocus(host: *Host, pane_index: usize, focused: bool) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_send_focus(host.client, &id, focused));
        try host.stageOutgoing();
    }

    pub fn sendPaste(host: *Host, pane_index: usize, payload: []const u8, trusted: bool) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_send_paste(host.client, &id, payload.ptr, payload.len, trusted));
        try host.stageOutgoing();
    }

    pub fn sendPasteOwned(host: *Host, owner: ReplicaOwner, payload: []const u8, trusted: bool) !void {
        if (!host.ownerIsCurrent(owner)) return error.InvalidState;
        const id = owner.terminal_id.asC();
        try resultError(c.phux_client_send_paste(host.client, &id, payload.ptr, payload.len, trusted));
        try host.stageOutgoing();
    }

    pub fn scrollViewport(host: *Host, pane_index: usize, kind: u32, value: i64) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_scroll_viewport(host.client, &id, kind, value));
        try host.captureEffects();
        try host.stageOutgoing();
    }

    pub fn createAnchor(host: *Host, pane_index: usize, point: c.PhuxDocumentPoint) !c.PhuxDocumentAnchor {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        var anchor: c.PhuxDocumentAnchor = undefined;
        try resultError(c.phux_client_anchor_create(host.client, &id, point, &anchor));
        return anchor;
    }

    pub fn releaseAnchor(host: *Host, pane_index: usize, anchor: c.PhuxDocumentAnchor) void {
        const owner = host.replicaOwner(pane_index) orelse return;
        host.releaseAnchorOwned(owner, anchor);
    }

    pub fn releaseAnchorOwned(host: *Host, owner: ReplicaOwner, anchor: c.PhuxDocumentAnchor) void {
        const id = owner.terminal_id.asC();
        _ = c.phux_client_anchor_release(host.client, &id, anchor);
    }

    pub fn setSelection(
        host: *Host,
        pane_index: usize,
        selection_start: c.PhuxDocumentAnchor,
        selection_end: c.PhuxDocumentAnchor,
        rectangle: bool,
    ) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_selection_set(host.client, &id, selection_start, selection_end, rectangle));
        try host.captureEffects();
        try host.stageOutgoing();
    }

    pub fn clearSelection(host: *Host, pane_index: usize) !void {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        try resultError(c.phux_client_selection_clear(host.client, &id));
        try host.captureEffects();
        try host.stageOutgoing();
    }

    pub fn clearSelectionOwned(host: *Host, owner: ReplicaOwner) !void {
        if (!host.ownerIsCurrent(owner)) return error.InvalidState;
        const id = owner.terminal_id.asC();
        try resultError(c.phux_client_selection_clear(host.client, &id));
        try host.captureEffects();
        try host.stageOutgoing();
    }

    pub fn search(
        host: *Host,
        pane_index: usize,
        query: []const u8,
        case_sensitive: bool,
    ) ![]const c.PhuxSearchResult {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const owner: ReplicaOwner = .{ .terminal_id = pane.id, .generation = pane.grid.generation };
        const id = pane.id.asC();
        host.clearSearchResults();
        var borrowed: [*c]const c.PhuxSearchResult = null;
        var count: usize = 0;
        try resultError(c.phux_client_search(
            host.client,
            &id,
            bytes(query),
            case_sensitive,
            &borrowed,
            &count,
        ));
        host.search_results.ensureTotalCapacity(host.gpa, count) catch {
            releaseSearchAnchors(host.client, &id, if (count == 0) &.{} else borrowed[0..count]);
            return error.OutOfMemory;
        };
        host.search_results.items.len = count;
        if (count > 0) @memcpy(host.search_results.items, borrowed[0..count]);
        host.search_owner = owner;
        try host.captureEffects();
        try host.stageOutgoing();
        return host.search_results.items;
    }

    pub fn clearSearchResults(host: *Host) void {
        if (host.search_owner) |owner| {
            const id = owner.terminal_id.asC();
            releaseSearchAnchors(host.client, &id, host.search_results.items);
        }
        host.search_results.items.len = 0;
        host.search_owner = null;
    }

    pub fn selectionText(host: *Host, pane_index: usize, gpa: std.mem.Allocator) ![]u8 {
        const pane = if (pane_index < host.panes.items.len) &host.panes.items[pane_index] else return error.InvalidState;
        const id = pane.id.asC();
        var text: c.PhuxBytes = undefined;
        try resultError(c.phux_client_selection_text(host.client, &id, &text));
        const borrowed: []const u8 = if (text.len == 0) &.{} else text.data[0..text.len];
        return gpa.dupe(u8, borrowed);
    }
};

fn bytes(slice: []const u8) c.PhuxBytes {
    return .{ .data = if (slice.len == 0) null else slice.ptr, .len = slice.len };
}

fn releaseSearchAnchors(
    client: *c.PhuxClient,
    terminal_id: *const c.PhuxTerminalId,
    results: []const c.PhuxSearchResult,
) void {
    for (results) |result| {
        _ = c.phux_client_anchor_release(client, terminal_id, result.start);
        if (result.end.opaque_id != result.start.opaque_id)
            _ = c.phux_client_anchor_release(client, terminal_id, result.end);
    }
}

test "runtime host creation accepts materialized history limits" {
    var bridge = transport.Bridge.init(std.testing.allocator);
    defer bridge.deinit();
    const host = try Host.create(std.testing.allocator, &bridge);
    defer host.destroy();
    try std.testing.expectEqual(@as(c.PhuxClientState, @intCast(c.PHUX_CLIENT_STATE_NEW)), host.state());
}

test "repeated borrowed grid copies retain bounded capacity" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var cells = [_]c.PhuxTerminalCell{std.mem.zeroes(c.PhuxTerminalCell)} ** 8;
    const text = "damage";
    var grid_view = std.mem.zeroes(c.PhuxTerminalGridView);
    grid_view.cols = 4;
    grid_view.rows = 2;
    grid_view.cells = &cells;
    grid_view.cell_count = cells.len;
    grid_view.utf8 = bytes(text);
    try grid.copyBorrowed(&grid_view);
    const cell_capacity = grid.cells.capacity;
    const utf8_capacity = grid.utf8.capacity;
    try grid.copyBorrowed(&grid_view);
    try std.testing.expectEqual(cell_capacity, grid.cells.capacity);
    try std.testing.expectEqual(utf8_capacity, grid.utf8.capacity);
}

test "absent and removed panes survive until the attach barrier" {
    var host: Host = undefined;
    host.gpa = std.testing.allocator;
    host.panes = .empty;
    host.search_results = .empty;
    host.search_owner = null;
    host.focused = 1;
    try host.panes.append(std.testing.allocator, Pane.init(std.testing.allocator, .{ .id = 1 }));
    try host.panes.append(std.testing.allocator, Pane.init(std.testing.allocator, .{ .id = 2 }));
    host.panes.items[0].seen_in_attach = true;
    host.panes.items[1].remove_at_barrier = true;
    try std.testing.expectEqual(@as(usize, 2), host.panes.items.len);
    host.finishAttachBarrier();
    defer {
        for (host.panes.items) |*pane| pane.deinit(std.testing.allocator);
        host.panes.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), host.panes.items.len);
    try std.testing.expectEqual(@as(u32, 1), host.panes.items[0].id.id);
    try std.testing.expectEqual(@as(?usize, 0), host.focused);
}
