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
