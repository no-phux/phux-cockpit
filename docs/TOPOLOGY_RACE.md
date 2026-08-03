# Topology Race

## Decision

Army C keeps Army A's dynamic provider registry as the execution model. Stable
terminal IDs, monotonic PTY transport keys, closing tombstones, independent tab
order, and versioned identity-based snapshots are a stronger base than Army B's
fixed slot identity and reusable transport keys.

Army B supplied the sharper close fence and useful full-capacity visual lesson.
C salvages post-close output suppression, compact growing-tab labels, and the
four-terminal visual/accessibility proof while retaining A's non-reuse and exact
exit acknowledgement.

## C Challenge

- Replaced positional `TabId` model state with one stable `SurfaceSelection`
  contract. Cmd+1 through Cmd+5 resolve dynamically at the edge; Web is always
  the final position and cannot be reordered or closed.
- Closing resources retain only their exact PTY key until exit. Output after
  close, including VT queries and their potential replies, is discarded.
- Version 1 snapshots are canonical: accepted and captured values restore
  exactly without topology normalization. Process restoration remains false.
- ID and transport allocation reject duplicates, reserved keys, exhaustion,
  and the `maxInt - 1` edge before arithmetic can wrap.
- Full-capacity tabs compact to `T1` through `T4`. Permanent move arrows and
  normal-title `DETACHED` text are gone; menu/keyboard reorder remains. New,
  context-sensitive Close, Split, and accessible keyboard parity remain.
- Healthy single mode hides RUNNING. Split mode shows pane identity quietly;
  lifecycle appears for starting, exit, failure, or I/O exceptions, with full
  detail retained in accessibility semantics.

## Evidence

The default null-platform suite passes 124 runnable tests with three expected
screenshot skips. It covers existing product/lifecycle behavior plus stable
selection, exact snapshots, exhaustion/collision rejection, stale post-close
output/query replies, and four-terminal accessibility/layout. With
`COCKPIT_SHOTS=1`, all 127 tests pass and emit deterministic native-canvas PNGs
for standard tabs, split terminals, and the four-terminal compact state.
`zig build` separately passes the native macOS executable path.

## Constraints

- native-sdk currently caps live PTYs at four; Cockpit displays at most two at
  once in the split substrate.
- Direct tab drag reorder is unavailable and is not simulated.
- WebKit remains parked at a one-point anchor when terminals are visible.
- Snapshots persist presentation identity only. Filesystem policy and live
  process restoration remain outside this slice.
- Deterministic screenshots validate retained native-canvas structure; they do
  not capture WebKit pixels or replace a live Metal presentation check.
