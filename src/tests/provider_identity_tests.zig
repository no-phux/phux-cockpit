const std = @import("std");
const app = @import("../main.zig");
const support = @import("support.zig");

const testing = std.testing;

const createSession = support.createSession;
const remoteTerminalRef = support.remoteTerminalRef;

// Attach/detach no longer exist: a terminal does not occupy a "placement",
// it is a LEAF of a tab's tree. These pin the equivalent invariants on the
// tree model — one terminal never occupies two panes, and provider churn
// never disturbs a pane that is still live.

test "a terminal occupies exactly one pane, and admitting it twice is a no-op" {
    const session = try createSession(80, 24);
    var model = app.initialModel(session);
    defer app.deinitModel(&model);

    const id = app.initialTerminalRef(0);
    const terminal = model.provider.terminal(id) orelse return error.TestExpectedTerminal;
    terminal.session.feed("durable state");

    try testing.expectEqual(@as(usize, 1), model.ws().tab_count);
    try testing.expect(model.admitTab(id));
    try testing.expectEqual(@as(usize, 1), model.ws().tab_count);
    try testing.expectEqual(@as(usize, 0), model.tabOfTerminal(id).?);

    // Selecting is not creating: the emulator behind the pane is the same one.
    try testing.expect(model.selectTerminal(id));
    try testing.expect(model.provider.terminal(id) == terminal);
    const text = try terminal.session.plainText(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "durable state") != null);
}

test "discovering a remote terminal gives it a tab and never disturbs a live pane" {
    // Discovery is not intent. A Phux terminal that appears becomes its own
    // TAB; it never displaces a pane the operator is using.
    const session = try createSession(80, 24);
    var model = app.initialModel(session);
    defer app.deinitModel(&model);

    const local = app.initialTerminalRef(0);
    const first = try remoteTerminalRef(11);
    const second = try remoteTerminalRef(12);
    try testing.expect(model.admitTab(first));
    try testing.expect(model.admitTab(second));
    try testing.expectEqual(@as(usize, 3), model.ws().tab_count);
    try testing.expectEqual(@as(usize, 0), model.tabOfTerminal(local).?);
    try testing.expectEqual(@as(usize, 1), model.tabOfTerminal(first).?);
    try testing.expectEqual(@as(usize, 2), model.tabOfTerminal(second).?);

    // Re-admitting in a different order does not reshuffle anything.
    try testing.expect(model.admitTab(second));
    try testing.expect(model.admitTab(first));
    try testing.expectEqual(@as(usize, 1), model.tabOfTerminal(first).?);
    try testing.expectEqual(@as(usize, 2), model.tabOfTerminal(second).?);
}

test "a terminal that disappears loses its pane and the local ones stay put" {
    const session = try createSession(80, 24);
    var model = app.initialModel(session);
    defer app.deinitModel(&model);

    const local = app.initialTerminalRef(0);
    const remote = try remoteTerminalRef(31);
    try testing.expect(model.admitTab(remote));
    try testing.expectEqual(@as(usize, 2), model.ws().tab_count);

    // No provider vouches for the remote terminal, so normalization takes
    // its pane, and with it the tab that held nothing else.
    model.normalizeTopology();
    try testing.expectEqual(@as(usize, 1), model.ws().tab_count);
    try testing.expectEqual(@as(?usize, null), model.tabOfTerminal(remote));
    try testing.expectEqual(@as(usize, 0), model.tabOfTerminal(local).?);
    try testing.expect(model.selectedTerminalRef().?.eql(local));
}

test "provider dispatch refuses a provider-qualified remote identity at the local backend" {
    const session = try createSession(80, 24);
    var model = app.initialModel(session);
    defer app.deinitModel(&model);

    const local = app.initialTerminalRef(0);
    const remote = try remoteTerminalRef(1);
    try testing.expect(model.containsTerminal(local));
    try testing.expect(!model.containsTerminal(remote));
    try testing.expect(model.terminalOwner(local) != null);
    try testing.expect(model.terminalOwner(remote) == null);
    // A terminal nobody has cannot be selected into a pane.
    try testing.expect(!model.selectTerminal(remote));
}
