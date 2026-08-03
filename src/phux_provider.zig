//! Identity-first provider around the owning-thread Phux host.

const std = @import("std");
const native_sdk = @import("native_sdk");
const provider = @import("provider_contract");
const host_mod = @import("phux_host");
const transport = @import("phux_transport");
const extension = @import("phux_extension");

pub const enabled = true;
pub const Endpoint = extension.Endpoint;
pub const State = host_mod.State;
pub const SyncDelta = host_mod.SyncDelta;
pub const DocumentSpace = host_mod.DocumentSpace;
pub const DocumentPoint = host_mod.DocumentPoint;
pub const Anchor = host_mod.Anchor;
pub const SearchResult = host_mod.SearchResult;
pub const Notice = host_mod.Notice;
pub const Error = host_mod.Error;

const OwnedEndpoint = union(enum) {
    tcp: struct { host: []u8, port: u16 },
    unix: []u8,

    fn init(gpa: std.mem.Allocator, endpoint: Endpoint) !OwnedEndpoint {
        return switch (endpoint) {
            .tcp => |tcp| .{ .tcp = .{ .host = try gpa.dupe(u8, tcp.host), .port = tcp.port } },
            .unix => |path| .{ .unix = try gpa.dupe(u8, path) },
        };
    }
    fn deinit(endpoint: *OwnedEndpoint, gpa: std.mem.Allocator) void {
        switch (endpoint.*) {
            .tcp => |tcp| gpa.free(tcp.host),
            .unix => |path| gpa.free(path),
        }
    }
    fn borrowed(endpoint: *const OwnedEndpoint) Endpoint {
        return switch (endpoint.*) {
            .tcp => |tcp| .{ .tcp = .{ .host = tcp.host, .port = tcp.port } },
            .unix => |path| .{ .unix = path },
        };
    }
};

pub const PhuxProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    bridge: *transport.Bridge,
    host: *host_mod.Host,
    worker: ?*extension.Worker = null,
    endpoint: OwnedEndpoint,
    session: []u8,
    client_name: []u8,
    attach_viewport: provider.Viewport = .{ .cols = 80, .rows = 24 },
    attach_queued: bool = false,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, endpoint: Endpoint, session: []const u8, client_name: []const u8) !*PhuxProvider {
        const self = try gpa.create(PhuxProvider);
        errdefer gpa.destroy(self);
        const bridge = try gpa.create(transport.Bridge);
        errdefer gpa.destroy(bridge);
        bridge.* = transport.Bridge.init(gpa);
        errdefer bridge.deinit();
        const host = try host_mod.Host.create(gpa, bridge);
        errdefer host.destroy();
        var owned_endpoint = try OwnedEndpoint.init(gpa, endpoint);
        errdefer owned_endpoint.deinit(gpa);
        const owned_session = try gpa.dupe(u8, session);
        errdefer gpa.free(owned_session);
        const owned_client_name = try gpa.dupe(u8, client_name);
        errdefer gpa.free(owned_client_name);
        self.* = .{ .gpa = gpa, .io = io, .bridge = bridge, .host = host, .endpoint = owned_endpoint, .session = owned_session, .client_name = owned_client_name };
        return self;
    }

    pub fn destroy(self: *PhuxProvider) void {
        self.stop();
        self.host.destroy();
        self.bridge.deinit();
        self.gpa.destroy(self.bridge);
        self.endpoint.deinit(self.gpa);
        self.gpa.free(self.session);
        self.gpa.free(self.client_name);
        self.gpa.destroy(self);
    }

    pub fn open(self: *PhuxProvider, handle: native_sdk.ChannelHandle) !void {
        if (self.worker != null) return error.InvalidState;
        if (self.host.state() == .new) try self.host.start(self.client_name);
        self.worker = try extension.Worker.start(self.io, self.gpa, self.bridge, handle, self.endpoint.borrowed());
    }

    pub fn stop(self: *PhuxProvider) void {
        if (self.worker) |worker| worker.stop();
        self.worker = null;
        self.host.freezePublished();
    }

    /// Preserve provider identity, terminal order, and the last complete canvas
    /// while replacing only the generation-bound client and socket worker.
    pub fn reconnect(self: *PhuxProvider, handle: native_sdk.ChannelHandle) !void {
        self.host.freezePublished();
        errdefer self.host.freezePublished();
        if (self.worker) |worker| worker.stop();
        self.worker = null;
        self.bridge.incoming.reset();
        self.bridge.outgoing.reset();
        try self.host.reconnect(self.client_name);
        self.attach_queued = false;
        self.worker = try extension.Worker.start(self.io, self.gpa, self.bridge, handle, self.endpoint.borrowed());
    }

    /// ATTACH is queued once after negotiation. The host still withholds every
    /// first presentation until the ATTACHED/READY barrier completes.
    pub fn drainReadiness(self: *PhuxProvider) !SyncDelta {
        const delta = try self.host.drainReadiness();
        if (self.host.state() == .detached) {
            self.attach_queued = false;
            return delta;
        }
        if (!self.attach_queued and self.host.state() == .negotiated) {
            try self.host.attach(self.session, self.attach_viewport);
            self.attach_queued = true;
        }
        return delta;
    }

    pub fn state(self: *const PhuxProvider) State {
        return self.host.state();
    }

    pub fn terminalRefs(self: *const PhuxProvider, out: []provider.TerminalRef) usize {
        return self.host.terminalRefs(out);
    }
    pub fn contains(self: *const PhuxProvider, terminal_ref: provider.TerminalRef) bool {
        return self.host.contains(terminal_ref);
    }
    pub fn owner(self: *const PhuxProvider, terminal_ref: provider.TerminalRef) ?provider.ReplicaOwner {
        return self.host.owner(terminal_ref);
    }
    pub fn ownerIsCurrent(self: *const PhuxProvider, value: provider.ReplicaOwner) bool {
        return self.host.ownerIsCurrent(value);
    }
    pub fn presentation(self: *const PhuxProvider, terminal_ref: provider.TerminalRef) ?provider.Presentation {
        return self.host.presentation(terminal_ref);
    }

    pub fn viewportResize(self: *PhuxProvider, terminal_ref: provider.TerminalRef, viewport: provider.Viewport) !void {
        try self.host.viewportResize(terminal_ref, viewport);
        self.attach_viewport = viewport;
    }
    pub fn sendKey(self: *PhuxProvider, owner_value: provider.ReplicaOwner, input: *const provider.KeyInput) !void {
        return self.host.sendKey(owner_value, input);
    }
    pub fn sendMouse(self: *PhuxProvider, owner_value: provider.ReplicaOwner, input: *const provider.MouseInput) !void {
        return self.host.sendMouse(owner_value, input);
    }
    pub fn mouseTracking(self: *const PhuxProvider, owner_value: provider.ReplicaOwner) !bool {
        return self.host.mouseTracking(owner_value);
    }
    pub fn sendFocus(self: *PhuxProvider, owner_value: provider.ReplicaOwner, focused: bool) !void {
        return self.host.sendFocus(owner_value, focused);
    }
    pub fn sendPaste(self: *PhuxProvider, owner_value: provider.ReplicaOwner, payload: []const u8, trusted: bool) !void {
        return self.host.sendPaste(owner_value, payload, trusted);
    }
    pub fn scrollViewport(self: *PhuxProvider, owner_value: provider.ReplicaOwner, scroll: provider.Scroll) !void {
        return self.host.scrollViewport(owner_value, scroll);
    }
    pub fn createAnchor(self: *PhuxProvider, owner_value: provider.ReplicaOwner, point: DocumentPoint) !Anchor {
        return self.host.createAnchor(owner_value, point);
    }
    pub fn releaseAnchor(self: *PhuxProvider, owner_value: provider.ReplicaOwner, anchor: Anchor) void {
        self.host.releaseAnchor(owner_value, anchor);
    }
    pub fn setSelection(self: *PhuxProvider, owner_value: provider.ReplicaOwner, start_anchor: Anchor, end_anchor: Anchor, rectangle: bool) !void {
        return self.host.setSelection(owner_value, start_anchor, end_anchor, rectangle);
    }
    pub fn clearSelection(self: *PhuxProvider, owner_value: provider.ReplicaOwner) !void {
        return self.host.clearSelection(owner_value);
    }
    pub fn search(self: *PhuxProvider, owner_value: provider.ReplicaOwner, query: []const u8, case_sensitive: bool) ![]const SearchResult {
        return self.host.search(owner_value, query, case_sensitive);
    }
    pub fn clearSearchResults(self: *PhuxProvider, expected_owner: ?provider.ReplicaOwner) void {
        self.host.clearSearchResults(expected_owner);
    }
    pub fn selectionText(self: *PhuxProvider, owner_value: provider.ReplicaOwner, gpa: std.mem.Allocator) ![]u8 {
        return self.host.selectionText(owner_value, gpa);
    }
    pub fn takeNotice(self: *PhuxProvider) ?Notice {
        return self.host.takeNotice();
    }
    pub fn releaseNotice(self: *PhuxProvider, notice: Notice) void {
        self.host.releaseNotice(notice);
    }
};

test "reconnect allocation failure after queue reset leaves old generation frozen" {
    const self = try PhuxProvider.create(
        std.testing.allocator,
        std.testing.io,
        .{ .unix = "/unused" },
        "session",
        "cockpit",
    );
    defer self.destroy();

    const id = try provider.RemoteTerminalId.fromPhux(0, 11, "");
    try self.host.terminals.append(self.gpa, .{
        .id = id,
        .phase = .live,
        .published = true,
    });
    const terminal_ref: provider.TerminalRef = .{
        .provider_id = .phux,
        .terminal_id = .{ .phux = id },
    };

    const original_allocator = self.bridge.outgoing.gpa;
    self.bridge.outgoing.gpa = std.testing.failing_allocator;
    defer self.bridge.outgoing.gpa = original_allocator;

    try std.testing.expectError(error.OutOfMemory, self.reconnect(undefined));
    const presentation_value = self.presentation(terminal_ref);
    try std.testing.expect(presentation_value != null);
    try std.testing.expectEqual(provider.Phase.frozen, presentation_value.?.phase);
}

test "provider lookups keep remote identity across reordered enumeration" {
    const self = try PhuxProvider.create(
        std.testing.allocator,
        std.testing.io,
        .{ .unix = "/unused" },
        "session",
        "cockpit",
    );
    defer self.destroy();

    const first_id = try provider.RemoteTerminalId.fromPhux(0, 51, "");
    const second_id = try provider.RemoteTerminalId.fromPhux(1, 51, "satellite");
    try self.host.terminals.append(self.gpa, .{
        .id = first_id,
        .generation = .{ .stream_id = 10, .bootstrap_id = 11 },
        .phase = .live,
        .published = true,
    });
    try self.host.terminals.append(self.gpa, .{
        .id = second_id,
        .generation = .{ .stream_id = 12, .bootstrap_id = 13 },
        .phase = .live,
        .published = true,
    });

    var first_order: [2]provider.TerminalRef = undefined;
    try std.testing.expectEqual(@as(usize, 2), self.terminalRefs(&first_order));
    const first_owner = self.owner(first_order[0]).?;
    const second_owner = self.owner(first_order[1]).?;

    std.mem.swap(
        @TypeOf(self.host.terminals.items[0]),
        &self.host.terminals.items[0],
        &self.host.terminals.items[1],
    );
    var second_order: [2]provider.TerminalRef = undefined;
    try std.testing.expectEqual(@as(usize, 2), self.terminalRefs(&second_order));
    try std.testing.expect(first_order[0].eql(second_order[1]));
    try std.testing.expect(first_order[1].eql(second_order[0]));

    try std.testing.expect(self.contains(first_owner.terminal_ref));
    try std.testing.expect(self.contains(second_owner.terminal_ref));
    try std.testing.expect(self.presentation(first_owner.terminal_ref).?.owner.eql(first_owner));
    try std.testing.expect(self.presentation(second_owner.terminal_ref).?.owner.eql(second_owner));
}

test "provider rejects a stale generation before forwarding host input" {
    const self = try PhuxProvider.create(
        std.testing.allocator,
        std.testing.io,
        .{ .unix = "/unused" },
        "session",
        "cockpit",
    );
    defer self.destroy();

    const id = try provider.RemoteTerminalId.fromPhux(0, 52, "");
    try self.host.terminals.append(self.gpa, .{
        .id = id,
        .generation = .{ .stream_id = 20, .bootstrap_id = 21, .last_seq = 1 },
        .phase = .live,
        .published = true,
    });
    const terminal_ref: provider.TerminalRef = .{
        .provider_id = .phux,
        .terminal_id = .{ .phux = id },
    };
    const stale = self.owner(terminal_ref).?;

    self.host.terminals.items[0].generation.last_seq = 99;
    try std.testing.expect(self.ownerIsCurrent(stale));
    self.host.terminals.items[0].generation.bootstrap_id += 1;
    try std.testing.expect(!self.ownerIsCurrent(stale));
    try std.testing.expectError(error.InvalidState, self.sendFocus(stale, true));
}

test "provider stop freezes every published canvas without dropping refs" {
    const self = try PhuxProvider.create(
        std.testing.allocator,
        std.testing.io,
        .{ .unix = "/unused" },
        "session",
        "cockpit",
    );
    defer self.destroy();

    const first_id = try provider.RemoteTerminalId.fromPhux(0, 53, "");
    const second_id = try provider.RemoteTerminalId.fromPhux(0, 54, "");
    try self.host.terminals.append(self.gpa, .{ .id = first_id, .phase = .live, .published = true });
    try self.host.terminals.append(self.gpa, .{ .id = second_id, .phase = .live, .published = true });
    var before: [2]provider.TerminalRef = undefined;
    try std.testing.expectEqual(@as(usize, 2), self.terminalRefs(&before));

    self.stop();

    var after: [2]provider.TerminalRef = undefined;
    try std.testing.expectEqual(@as(usize, 2), self.terminalRefs(&after));
    for (before, after) |old_ref, new_ref| {
        try std.testing.expect(old_ref.eql(new_ref));
        const presentation_value = self.presentation(old_ref).?;
        try std.testing.expectEqual(provider.Phase.frozen, presentation_value.phase);
        try std.testing.expect(!presentation_value.grid.running);
    }
}
