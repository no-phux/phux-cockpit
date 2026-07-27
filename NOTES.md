# cockpit — spike notes

Forked verbatim from native-sdk `a7509a7` (v0.6.1) `examples/terminal`.

## Provenance

`src/main.zig`, `src/grid.zig`, `src/box.zig`, `src/tests.zig`, `build.zig`,
`app.zon`, `README.md` are byte-identical to the upstream example at that
commit. The only intentional divergence is `build.zig.zon`, whose
`.native_sdk` dependency path is retargeted from `"../.."` (its location
inside the SDK tree) to `"../ref/native-sdk"` (the read-only reference clone
beside this repo). Package name (`.terminal`), fingerprint
(`0x8f7b154131eea8ae`), binary name, and the `canvas_label = "terminal-canvas"`
are deliberately unchanged — the label is threaded through ~40 sites in
`src/tests.zig`, and renaming the package would also force a new fingerprint.

The reference clone at `/Users/phall/workspace/phux-native-spike/ref/native-sdk`
is READ-ONLY. Do not `git pull` it mid-spike: every line number the build plan
cites was read at `a7509a7`.

## Toolchain

Zig 0.16.0, invoked by absolute path. The `zig` on `PATH` is 0.15.2 and is the
WRONG version — it will not build this.

```
/nix/store/y6ihamhfl46ybmz49k7c5qs9navb6q1a-zig-0.16.0/bin/zig
```

`zig-pkg/` (561 MB, ghostty already materialized at commit
`7aa9591746ffa4d2eee458960c76554352832595`) is kept in the working tree and
gitignored, so no network fetch is needed.

## Validation commands

Tests:

```sh
cd /Users/phall/workspace/phux-native-spike/cockpit && \
  /nix/store/y6ihamhfl46ybmz49k7c5qs9navb6q1a-zig-0.16.0/bin/zig build test \
  -Dplatform=null --summary all
```

Binary:

```sh
cd /Users/phall/workspace/phux-native-spike/cockpit && \
  /nix/store/y6ihamhfl46ybmz49k7c5qs9navb6q1a-zig-0.16.0/bin/zig build && \
  file zig-out/bin/terminal
```

## Baseline measured at this commit

- `Build Summary: 18/18 steps succeeded; 48/48 tests passed`
- `run exe terminal-model-contract success`
- `zig-out/bin/terminal: Mach-O 64-bit arm64 executable`

48 is the baseline test count. Later slices add tests; any run that reports
fewer than 48 means something in the fork regressed rather than grew.

## Repo rules

Local commits only. There is no remote and one must never be added.

---

## Slice 2 — two panes (commit after `b2741ed`)

The fork is no longer verbatim. `src/main.zig`, `src/grid.zig`, `src/box.zig`,
and `src/tests.zig` all diverge; `git diff b2741ed -- src/` is the whole story.

### Budget policy (do not improvise; measure before tuning)

One `gpu_surface`, one chrome prefix, `pane_count = 2` grids painted into it.
The three per-view canvas budgets are accounted DIFFERENTLY by the painter, so
each is partitioned differently:

| Budget | Accounting | Partition | Value (N=2) |
|---|---|---|---|
| `command_budget` | CUMULATIVE — compared against the builder TOTAL, so it is an absolute high-water mark | floor-and-slack | pane 0: 896, pane 1: 1792 |
| `text_reserve` | PER-PAINT LOCAL — the emitted-bytes counter resets each call, the 32 KiB store does not | mirrored | 18432 for both |
| `glyph_budget` | PER-PAINT LOCAL and a SET, not a count | halved | 3840 for both |

`chrome_command_envelope` is 1792 (2048 less a 256-command widget reserve) and
is what `chrome.prefix_commands` now declares.

### Measured

- Combined chrome under the adversarial two-pane test (40x40, a distinct SGR
  per cell, real ceilings): **1488 of 1792 commands**, pane 0 painting 15 rows
  and pane 1 painting 22. Neither pane starved.
- A 40-column screen of `╬` costs 8 commands per cell; with the corrected
  `cols*8+8` row reserve one pane lands at 644 of its 896 budget. With the old
  `cols*4+8` reserve the same screen reached 964 — a whole-frame
  `error.InvalidChromeCommandCount` under `variable_prefix`. That regression is
  pinned by `a screen of double box drawing stays inside the pane command budget`,
  observed failing before the fix and passing after.

### Test count

54 (48 baseline + 6). The sixth is env-gated and skips unless `COCKPIT_SHOTS=1`:

```sh
cd /Users/phall/workspace/phux-native-spike/cockpit && \
  COCKPIT_SHOTS=1 /nix/store/y6ihamhfl46ybmz49k7c5qs9navb6q1a-zig-0.16.0/bin/zig \
  build test -Dplatform=null --summary all
```

It writes `zig-out/cockpit-two-panes.png` (980x640 RGBA) — a build artifact,
gitignored twice over (`zig-out/` and `*.png`), so read it in-session.

### Keyed-effect space

One key space spans pty, clipboard, spawn, and fetch. Pane i owns pty key
`1 + i`; the clipboard moved from key 2 to **key 100**. Leaving it at 2 would
make every copy silently reject the moment pane 1 spawned.
