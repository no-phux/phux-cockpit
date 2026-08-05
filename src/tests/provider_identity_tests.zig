const std = @import("std");
const app = @import("../main.zig");
const support = @import("support.zig");

const testing = std.testing;

const createSessions = support.createSessions;
const remoteTerminalRef = support.remoteTerminalRef;

test "typed terminal attachments reject duplicates and preserve provider-owned state" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);

    const id = app.initialTerminalRef(0);
    const terminal = model.provider.terminal(id) orelse return error.TestExpectedTerminal;
    terminal.session.feed("durable state");
    try testing.expectError(error.TerminalAlreadyAttached, model.attach(.secondary, id));

    try testing.expectEqual(id, model.detach(.primary).?);
    try testing.expect(model.provider.terminal(id) == terminal);
    const detached_text = try terminal.session.plainText(testing.allocator);
    defer testing.allocator.free(detached_text);
    try testing.expect(std.mem.indexOf(u8, detached_text, "durable state") != null);

    try testing.expectError(error.PlacementOccupied, model.attach(.secondary, id));
    _ = model.detach(.secondary);
    try model.attach(.secondary, id);
    try testing.expectEqual(id, model.attachments[app.Placement.secondary.index()].?);
    try testing.expect(model.terminalAt(.secondary) == terminal);
}

test "local and remote terminal identities never collide" {
    const local = app.initialTerminalRef(0);
    const remote = try remoteTerminalRef(@truncate(@intFromEnum(app.initialTerminalId(0))));
    try testing.expect(!local.eql(remote));
    try testing.expectEqual(app.ProviderKind.local, app.providerKind(local));
    try testing.expectEqual(app.ProviderKind.phux, app.providerKind(remote));
}

test "discovering a remote terminal never evicts a live local placement" {
    // Discovery is not intent. A Phux terminal that appears becomes a tab; it
    // takes a pane only when the operator selects it. Reconciliation must
    // leave both live local placements exactly where they were.
    const first = try remoteTerminalRef(11);
    const second = try remoteTerminalRef(12);
    var attachments: [app.pane_count]?app.TerminalRef = .{
        app.initialTerminalRef(0),
        app.initialTerminalRef(1),
    };
    app.reconcileRemoteRefs(&attachments, &.{ first, second });
    try testing.expect(attachments[0].?.eql(app.initialTerminalRef(0)));
    try testing.expect(attachments[1].?.eql(app.initialTerminalRef(1)));
}

test "remote enumeration reorder retains stable placement identity" {
    const first = try remoteTerminalRef(21);
    const second = try remoteTerminalRef(22);
    // A remote terminal that WAS selected into a placement keeps it, and the
    // order the provider enumerates in never reshuffles the panes.
    var attachments: [app.pane_count]?app.TerminalRef = .{ first, second };
    const before = attachments;
    app.reconcileRemoteRefs(&attachments, &.{ second, first });
    try testing.expect(attachments[0].?.eql(before[0].?));
    try testing.expect(attachments[1].?.eql(before[1].?));
}

test "a remote terminal that disappears leaves the placement it held" {
    const first = try remoteTerminalRef(31);
    const second = try remoteTerminalRef(32);
    var attachments: [app.pane_count]?app.TerminalRef = .{ first, second };
    app.reconcileRemoteRefs(&attachments, &.{first});
    try testing.expect(attachments[0].?.eql(first));
    try testing.expectEqual(@as(?app.TerminalRef, null), attachments[1]);
}

test "pruning a remote placement never disturbs a local one" {
    const remote = try remoteTerminalRef(41);
    var attachments: [app.pane_count]?app.TerminalRef = .{
        app.initialTerminalRef(0),
        remote,
    };
    app.reconcileRemoteRefs(&attachments, &.{});
    try testing.expect(attachments[0].?.eql(app.initialTerminalRef(0)));
    try testing.expectEqual(@as(?app.TerminalRef, null), attachments[1]);
}

test "provider dispatch refuses a provider-qualified remote identity at the local backend" {
    const sessions = try createSessions(80, 24);
    var model = app.initialModel(sessions);
    defer app.deinitModel(&model);

    const local = app.initialTerminalRef(0);
    const remote = try remoteTerminalRef(1);
    try testing.expect(model.containsTerminal(local));
    try testing.expect(!model.containsTerminal(remote));
    try testing.expect(model.terminalOwner(local) != null);
    try testing.expect(model.terminalOwner(remote) == null);
    _ = model.detach(.primary);
    try testing.expectError(error.UnknownTerminal, model.attach(.primary, remote));
}
