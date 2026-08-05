//! The pane layout tree: structure, geometry, focus, and collapse.
//!
//! These pin the behavior the old two-rect model could not express — nested
//! splits in both orientations, sibling promotion on close, and geometric
//! directional focus — so the single-source-of-truth claim stays honest.

const std = @import("std");
const native_sdk = @import("native_sdk");
const layout = @import("../cockpit/layout.zig");
const provider_contract = @import("provider_contract");

const RectF = native_sdk.geometry.RectF;
const Tree = layout.Tree;

fn ref(index: u64) layout.TerminalRef {
    return provider_contract.localTerminalRef(@enumFromInt(index));
}

const bounds = RectF.init(0, 0, 1000, 600);
const divider: f32 = 8;
const min_w: f32 = 80;
const min_h: f32 = 40;

fn resolveAll(tree: *const Tree, out: []layout.Pane) usize {
    return tree.resolve(bounds, divider, min_w, min_h, out);
}

test "a fresh tree is one leaf filling its bounds" {
    const tree = Tree.initLeaf(ref(1));
    try std.testing.expect(!tree.isEmpty());
    try std.testing.expect(!tree.isSplit());
    try std.testing.expectEqual(@as(usize, 1), tree.paneCount());

    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolveAll(&tree, &panes);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(bounds.x, panes[0].rect.x);
    try std.testing.expectEqual(bounds.width, panes[0].rect.width);
    try std.testing.expectEqual(bounds.height, panes[0].rect.height);
}

test "splitting right puts the new terminal in the second pane and focuses it" {
    var tree = Tree.initLeaf(ref(1));
    const created = try tree.split(tree.focus, .horizontal, ref(2));

    try std.testing.expectEqual(@as(usize, 2), tree.paneCount());
    try std.testing.expect(tree.isSplit());
    try std.testing.expectEqual(created, tree.focus);
    // Ghostty moves focus into the pane it just made.
    try std.testing.expect(tree.focusedTerminal().?.eql(ref(2)));

    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolveAll(&tree, &panes);
    try std.testing.expectEqual(@as(usize, 2), count);
    // The ORIGINAL terminal keeps the left pane; the new one takes the right.
    try std.testing.expect(panes[0].terminal.eql(ref(1)));
    try std.testing.expect(panes[1].terminal.eql(ref(2)));
    try std.testing.expect(panes[0].rect.x < panes[1].rect.x);
    // Same height, and the divider is carved out of the middle.
    try std.testing.expectEqual(panes[0].rect.height, panes[1].rect.height);
    const gap = panes[1].rect.x - (panes[0].rect.x + panes[0].rect.width);
    try std.testing.expectApproxEqAbs(divider, gap, 0.001);
}

test "splitting down divides vertically and preserves width" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .vertical, ref(2));

    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolveAll(&tree, &panes);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(panes[0].rect.y < panes[1].rect.y);
    try std.testing.expectEqual(bounds.width, panes[0].rect.width);
    try std.testing.expectEqual(bounds.width, panes[1].rect.width);
    const gap = panes[1].rect.y - (panes[0].rect.y + panes[0].rect.height);
    try std.testing.expectApproxEqAbs(divider, gap, 0.001);
}

test "nested splits produce the Ghostty L-shape and never overlap" {
    // one | two          one | two
    //           becomes      -----
    //                    one | three
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));

    try std.testing.expectEqual(@as(usize, 3), tree.paneCount());
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolveAll(&tree, &panes);
    try std.testing.expectEqual(@as(usize, 3), count);

    // Left pane spans the full height; the right column is stacked.
    var left: layout.Pane = undefined;
    var top_right: layout.Pane = undefined;
    var bottom_right: layout.Pane = undefined;
    for (panes[0..count]) |pane| {
        if (pane.terminal.eql(ref(1))) left = pane;
        if (pane.terminal.eql(ref(2))) top_right = pane;
        if (pane.terminal.eql(ref(3))) bottom_right = pane;
    }
    try std.testing.expectEqual(bounds.height, left.rect.height);
    try std.testing.expect(top_right.rect.y < bottom_right.rect.y);
    try std.testing.expectApproxEqAbs(top_right.rect.x, bottom_right.rect.x, 0.001);
    try std.testing.expectApproxEqAbs(top_right.rect.width, bottom_right.rect.width, 0.001);

    // No pane overlaps another.
    for (panes[0..count], 0..) |a, i| {
        for (panes[0..count], 0..) |b, j| {
            if (i >= j) continue;
            const disjoint = a.rect.x + a.rect.width <= b.rect.x + 0.001 or
                b.rect.x + b.rect.width <= a.rect.x + 0.001 or
                a.rect.y + a.rect.height <= b.rect.y + 0.001 or
                b.rect.y + b.rect.height <= a.rect.y + 0.001;
            try std.testing.expect(disjoint);
        }
    }
}

test "closing a pane promotes its sibling into the parent's rect" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    const closed_node = tree.find(ref(2)).?;
    const removed = try tree.closePane(closed_node);

    try std.testing.expect(removed.eql(ref(2)));
    try std.testing.expectEqual(@as(usize, 1), tree.paneCount());
    try std.testing.expect(!tree.isSplit());
    // Focus fell back onto the survivor, not into nothing.
    try std.testing.expect(tree.focusedTerminal().?.eql(ref(1)));

    // The survivor reclaims the WHOLE area — this is the collapse that the
    // old attachment model got wrong by pulling in an unrelated tab.
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolveAll(&tree, &panes);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(bounds.width, panes[0].rect.width);
    try std.testing.expectEqual(bounds.height, panes[0].rect.height);
}

test "closing a nested pane keeps the rest of the tree intact" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));
    _ = try tree.closePane(tree.find(ref(3)).?);

    try std.testing.expectEqual(@as(usize, 2), tree.paneCount());
    var panes: [layout.max_panes]layout.Pane = undefined;
    const count = resolveAll(&tree, &panes);
    try std.testing.expectEqual(@as(usize, 2), count);
    // Two survives and reclaims the full right column height.
    for (panes[0..count]) |pane| {
        try std.testing.expectEqual(bounds.height, pane.rect.height);
    }
}

test "closing the last pane empties the tree" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.closePane(tree.focus);
    try std.testing.expect(tree.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), tree.paneCount());
    try std.testing.expectEqual(@as(?layout.TerminalRef, null), tree.focusedTerminal());
}

test "closing every pane one at a time never strands a node" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));
    _ = try tree.split(tree.find(ref(1)).?, .vertical, ref(4));

    try std.testing.expectEqual(@as(usize, 4), tree.paneCount());
    for ([_]u64{ 3, 1, 4, 2 }) |raw| {
        _ = tree.closeTerminal(ref(raw)) orelse return error.TestUnexpectedResult;
    }
    try std.testing.expect(tree.isEmpty());
    // Every node returned to the free list, so the tree can be reused.
    for (tree.nodes) |node| try std.testing.expectEqual(layout.Kind.free, node.kind);
}

test "directional focus moves geometrically across nested splits" {
    // one | two
    // one | three
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));

    // Focus is on three (bottom right) after the nested split.
    try std.testing.expect(tree.focusedTerminal().?.eql(ref(3)));

    const up = tree.focusDirection(bounds, divider, min_w, min_h, .up).?;
    try std.testing.expect(tree.node(up).terminal.?.eql(ref(2)));

    const left = tree.focusDirection(bounds, divider, min_w, min_h, .left).?;
    try std.testing.expect(tree.node(left).terminal.?.eql(ref(1)));

    // Nothing lies to the right of the right column.
    try std.testing.expectEqual(
        @as(?layout.NodeId, null),
        tree.focusDirection(bounds, divider, min_w, min_h, .right),
    );
}

test "cycle focus visits every pane and wraps" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));

    var seen: [3]bool = .{ false, false, false };
    for (0..3) |_| {
        const next = tree.cycleFocus(1).?;
        tree.focus = next;
        const held = tree.node(next).terminal.?;
        for (1..4) |raw| {
            if (held.eql(ref(@intCast(raw)))) seen[raw - 1] = true;
        }
    }
    for (seen) |visited| try std.testing.expect(visited);
}

test "a fraction that would starve a pane is clamped to the minimum, not honored" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    const branch = tree.nodes[tree.root];
    try std.testing.expectEqual(layout.Kind.branch, branch.kind);

    tree.setFraction(tree.root, 0.99);
    var panes: [layout.max_panes]layout.Pane = undefined;
    _ = resolveAll(&tree, &panes);
    // The clamp is to max_fraction and then to the pixel minimum.
    try std.testing.expect(panes[1].rect.width >= min_w - 0.001);

    tree.setFraction(tree.root, 0.001);
    _ = resolveAll(&tree, &panes);
    try std.testing.expect(panes[0].rect.width >= min_w - 0.001);
}

test "a non-finite fraction is refused rather than poisoning the layout" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    tree.setFraction(tree.root, 0.4);
    tree.setFraction(tree.root, std.math.nan(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), tree.nodes[tree.root].fraction, 0.0001);
}

test "a window too small for two minimums divides evenly instead of starving one side" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    tree.setFraction(tree.root, 0.9);

    var panes: [layout.max_panes]layout.Pane = undefined;
    const tight = RectF.init(0, 0, 100, 200); // 92 usable, under min_w * 2
    const count = tree.resolve(tight, divider, min_w, min_h, &panes);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectApproxEqAbs(panes[0].rect.width, panes[1].rect.width, 0.001);
}

test "the tree refuses to grow past its pane ceiling and stays consistent" {
    var tree = Tree.initLeaf(ref(1));
    var created: usize = 1;
    while (created < layout.max_panes) : (created += 1) {
        _ = try tree.split(tree.focus, .horizontal, ref(@intCast(created + 1)));
    }
    try std.testing.expectEqual(layout.max_panes, tree.paneCount());
    try std.testing.expectError(error.Full, tree.split(tree.focus, .horizontal, ref(999)));
    // The refused split left nothing half-built.
    try std.testing.expectEqual(layout.max_panes, tree.paneCount());
}

test "dividers resolve to grabbable strips between siblings" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));

    var strips: [layout.max_panes]layout.Divider = undefined;
    const count = tree.dividers(bounds, divider, min_w, min_h, &strips);
    try std.testing.expectEqual(@as(usize, 2), count);
    for (strips[0..count]) |strip| {
        switch (strip.orientation) {
            .horizontal => {
                try std.testing.expectApproxEqAbs(divider, strip.rect.width, 0.001);
                try std.testing.expectEqual(bounds.height, strip.rect.height);
            },
            .vertical => try std.testing.expectApproxEqAbs(divider, strip.rect.height, 0.001),
        }
    }
}

test "paneAt hits panes and misses dividers" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));

    var panes: [layout.max_panes]layout.Pane = undefined;
    _ = resolveAll(&tree, &panes);

    const inside_left = tree.paneAt(bounds, divider, min_w, min_h, panes[0].rect.x + 5, 300).?;
    try std.testing.expect(inside_left.terminal.eql(ref(1)));

    const inside_right = tree.paneAt(bounds, divider, min_w, min_h, panes[1].rect.x + 5, 300).?;
    try std.testing.expect(inside_right.terminal.eql(ref(2)));

    // Dead centre of the divider strip belongs to neither pane.
    const seam = panes[0].rect.x + panes[0].rect.width + divider / 2;
    try std.testing.expectEqual(
        @as(?layout.Pane, null),
        tree.paneAt(bounds, divider, min_w, min_h, seam, 300),
    );
}

test "terminals are reported in layout order" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    _ = try tree.split(tree.focus, .vertical, ref(3));

    var out: [layout.max_panes]layout.TerminalRef = undefined;
    const count = tree.terminals(&out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(out[0].eql(ref(1)));
    try std.testing.expect(out[1].eql(ref(2)));
    try std.testing.expect(out[2].eql(ref(3)));
}

test "splitting a branch node is refused" {
    var tree = Tree.initLeaf(ref(1));
    _ = try tree.split(tree.focus, .horizontal, ref(2));
    try std.testing.expectError(error.NotALeaf, tree.split(tree.root, .horizontal, ref(3)));
}
