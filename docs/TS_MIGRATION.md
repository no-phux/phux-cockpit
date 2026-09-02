# Migrating Cockpit's authoring to TypeScript + `.native` markup

Status: **phase 3 first cut running under `-Dtypescript-spike=true`.**
`typescript-spike/` is a real cockpit: markup chrome from `app.native` over a
`core.ts` model, and beneath it the shipping Zig painter drawing real shells.
The seam (`ts_protocol.zig`, `ts_snapshot.zig`, `ts_engine.zig`, the fork's
`native_extension` hook in `typescript-spike/src/native_extension.zig`) carries
intents, snapshots and invalidations; the engine now also owns the PTY spawn,
output, key encoding, committed text and the resize pump, through the same
`terminal_runtime.zig` the shipping app uses (made generic over the effects
type). No terminal byte enters the compiled core: shell events are consumed in
the pty event constructor and the core receives a void `engine_wake`. Guards
under the extension prove boot, resync, the revision fence, key routing and
shell ownership red-then-green (`zig build test -Dtypescript-spike=true
-Dplatform=null`). Not yet moved: scrollback search, selection, mouse
protocols, bells, secondary windows, settings/palette contents (the spike's
overlays are placeholders), and the parity harness of phase 2. The shipping
graph remains the Zig core.

Building the spike needs the SDK package's TypeScript toolchain, which the
tarball pin does not carry. Once per pin, on the package `zig build` resolved:

```sh
cd zig-pkg/native_sdk-*/packages/core && npm ci --include=dev
zig build test -Dtypescript-spike=true -Dplatform=null
```

Without it the build stops at "the @native-sdk/core frontend cannot resolve
its TypeScript toolchain" and names the exact directory. The default and Phux
graphs never touch it.

## Target

The Native SDK's primary authoring path is a TypeScript app core (`src/core.ts`:
`Model`, `Msg`, `update`, `subscriptions`) plus declarative markup
(`src/app.native`). It compiles ahead-of-time to native code — no JS runtime in
the binary. Cockpit currently uses the explicit Zig-core alternative end to end:
`src/cockpit/` owns the model/update loop, `src/cockpit/native/view.zig` builds
the widget tree, and the terminal engine paints through app-owned canvas
commands.

The goal is to move what the SDK's TS tier is good at (declarative chrome,
bindings, derived values, the automation-checked markup contract) onto that
path, and keep everything that must sit next to libghostty-vt native. The SDK
tier split is binary: an app graph is EITHER a Zig core OR a TS core. There is
no second app loop, so this is a swap of the core staged behind proven seams —
not a file-by-file port. Rendering CAN compose: a custom Zig view may call
`canvas.CompiledMarkupView(...).build` and place the native terminal subtree
beside/under that node. That is the intended final shape: one TS model/update
loop, `.native` chrome, and one app-owned Zig terminal module.

## What moves, what stays

Grounded in a survey of `src/cockpit/native/` (2026-08-24):

**Movable to `.native` markup + TS core** (direct widget equivalents exist):
tab strip / side rail triggers (`view.zig:458`, `:598`), new-tab button and
overflow cues (`:663`, `:708`), status badges and limit notices (`:363`,
`:1619`–`:1685`), config notice band (`:1133`), palette overlay rows
(`:1189`), settings surface (`:1508`), horizontal splits (already SDK `.split`
widgets, `:977`), tooltips, context menus, menus/shortcuts/status-item tables
(already declarative data in `scene.zig`).

**Stays native regardless** (no markup equivalent, or correctness lives beside
emulator state):
- Terminal cell grids and all custom-painted chrome in `paintWindow`
  (`view.zig:1992`): dim scrims, focus edges, OSC 8 preview band, hand-managed
  command-id namespaces and per-pane budgets.
- `grid.Session` + libghostty-vt, key encoding (`terminal_runtime.zig:198` —
  kitty-protocol encoding depends on live emulator modes), the lossless
  outbound ring and its back-pressure invariants (`:80`–`:146`), the resize
  pump (needs the measured cell box only the native painter writes,
  `workspace_projection.zig:1439`), providers, and `CockpitHost` event routing.
- The deliberately-drawn search/palette needles (`view.zig:1003`): a keystroke
  aimed at a hosted text-entry child can never be intercepted the way the
  modal search needs.
- The single-geometry law: `resolvePanesIn` / `workspaceChromeIn` remain THE
  source for painter rects, hit-test rects, and PTY sizing. Markup layout must
  consume these derivations, not re-derive them, or `chrome_register_tests.zig`
  has nothing left to audit.

## The seams (must exist and be tested BEFORE any swap)

1. **Engine → core:** `Cmd.channelOpen` channels fed by a native poster
   (pattern already in-tree: `openPhuxChannel`, `openPointerMonitor`,
   `update.zig:108`–`:146`) deliver chrome-state snapshots and terminal frame
   notifications. Known bound: channel posts are capped at 4096 bytes
   (`FINDINGS.md:258`), so payloads are chunked or summarized, never raw
   scrollback.
2. **Core → engine:** how a TS core issues commands (pty spawn/write/resize/
   kill, tab ops) to a native extension is now settled: `Cmd.host` /
   `Cmd.request` ride `TsUiApp.CoreOptions.host_calls`, whose public
   `HostCallBinding` is synchronous-or-async and answers requests through the
   ordinary effect result path. Cockpit exposes one versioned intent command
   and one snapshot request rather than mirroring every native operation into
   the interface. The SDK-generated runner does not expose that option to an
   app, so the fork needs one narrow native-extension hook to configure
   `CoreOptions`, configure the composed view/chrome options, and decorate the
   resulting `native_sdk.App` with Cockpit's event/focus host.
3. **Terminal pixels:** two candidates, decide by measurement not taste:
   - Keep native painting of grids into the chrome display list (today's path)
     and let markup own only the interactive chrome around it.
   - `media-surface` leaves (`gpu_surfaces` capability) composited into the
     tree, fed by a native RGBA producer. Costs: loses the wire-v6 incremental
     patch path for those cells, and accessibility must come from a parallel
     surface. Only wins if it removes more native paint code than it costs.

## Phases

0. **Toolchain proof (spike).** Install `@native-sdk/cli`; build and drive one
   fork example (`examples/gpu-components`) through `native dev` /
   `native test -Dplatform=null` on this machine. Add the TS compile step to a
   scratch app target. Exit criterion: a TS-core binary runs and snapshots via
   the automation harness.
1. **Seam contracts.** Land (2) above behind tests, in the Zig app, using the
   channel pattern that already exists. No product change. Guards prove the
   4096-byte chunking and ordering invariants.
2. **Parity harness.** Before any UI moves, define what
   `chrome_register_tests.zig` becomes for markup trees (the toolkit audits
   solved trees — verify `native check`'s markup audit covers the register
   ladder at every declared window size, or keep a Zig-side audit consuming
   the compiled view).
3. **Swap, window by window.** Main-window chrome to `app.native` + TS core;
   secondary windows follow (`#351` exposes model-declared windows to TS).
   Each swap keeps the automation smoke green and ships behind no flag — the
   binary either is the cockpit or is not merged.
4. **Delete the old path.** `view.zig` chrome builders and their tests retire
   only when the last window is swapped. Engine files stay.

## Non-goals

- Rewriting the terminal engine in TS (impossible: subset has no FFI, no raw
  bidirectional streams, no PTY ioctl).
- A web/WebView frontend. The TS path compiles to native; nothing here adopts
  a browser runtime.
- Faking parity: until phase 3's swaps ship, the Zig-core app remains the
  product. No dual-maintenance limbo longer than one swap.
