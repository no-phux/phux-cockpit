# phux-cockpit

A spike, run 2026-07-27, answering one question: **can phux have a native GUI
cockpit — several live terminal panes beside ordinary native widgets, in one GPU
surface — without the native layer having to understand terminals?**

**Verdict: GO, with caveats.** Read [`FINDINGS.md`](FINDINGS.md) before the code.
It records what was built, what broke, and what it cost, and it marks every claim
by how it was established — two adversarial validators and the report agent died
on transient API errors partway through, so the coverage is thinner than planned
and the document says so where it matters.

## What this is

The default build remains a fork of `native-sdk`'s `examples/terminal`
(`a7509a7`) for deterministic painter tests. The production
`-Dphux-enabled=true` build replaces that fixture with the real
`phux-client-ffi`: protocol 0.7 frames cross a bounded TCP/Unix socket bridge,
the owning UI thread drains the synchronous client, and two client-owned grid
views render beside ordinary native widgets in one GPU surface.

It has since been ported onto the framework's first-party `canvas.terminal_grid`
painter, deleting the forked renderer entirely (`grid.zig` 1156 → 916 lines,
`box.zig` gone). The old painter is still in history —
`git show d4ccb84^:src/box.zig`.

```sh
zig build run
zig build test -Dplatform=null

# Production host against the panic-contained Rust static library:
zig build -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir=../../phux-codec-bindings/crates/phux-client-ffi/include \
  -Dphux-client-ffi-lib-dir=../../phux-codec-bindings/target/ffi-release
zig build test -Dplatform=null -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir=../../phux-codec-bindings/crates/phux-client-ffi/include \
  -Dphux-client-ffi-lib-dir=../../phux-codec-bindings/target/ffi-release
```

## The finding that mattered


The integrated seam is `src/phux_host.zig`: it owns one `PhuxClient`, copies
borrowed published grids into reusable Zig projection buffers, drains typed
status/damage/job effects, and stages exact outbound protocol frames. Socket
I/O remains in `src/phux_extension.zig`; `PhuxClient` never leaves the UI
thread. Keyboard, IME text, paste, focus, pointer, viewport, selection,
clipboard, and search paths all call the C ABI rather than interpreting
terminal bytes in Zig.

## Where it stands

Steps 1–4 of `FINDINGS.md` section 8 are integrated on
`port/first-party-terminal-grid`. With Zig 0.16, the production build and the
`platform=null` suite both exit 0 against
`target/ffi-release/libphux_client_ffi.a`.

Branches:

- `main` — the spike as originally built, on the forked painter
- `port/first-party-terminal-grid` — the port, and where the work continues

Two sibling working copies sat beside this repo during the spike (`baseline/`,
`cockpit-validator/`). Neither holds anything this history does not, and neither
was published.

---

## Upstream example README

The text below is from `native-sdk`'s `examples/terminal`, which this forked.
Some of it still describes how the terminal stack works; the keybindings are the
example's and not necessarily this spike's.

A recordable terminal: a real shell on a pty, rendered as real text on the canvas, and — the headline — sessions that replay byte-identical offline, with no shell present.

- The pty effect vocabulary (`fx.ptySpawn` / `ptyWrite` / `ptyResize` / `ptyKill`) owns the transport.
- [libghostty-vt](https://github.com/ghostty-org/ghostty) owns terminal state and damage (the `ghostty-vt` Zig module, pinned in `build.zig.zon`).
- The canvas owns the pixels: damaged rows re-render as styled text runs, the ANSI-16 palette derives from the active theme tokens, and 256-color/truecolor pass through exactly.

### Keyboard

- `cmd+shift+space` — toggle keyboard selection mode (arrows move the caret, `shift`+arrows extend, `B` toggles block selection, `enter` copies, `esc` cancels)
- `cmd+C` — copy the active selection
- `cmd+arrow-up` / `cmd+arrow-down` — scroll history one line (`shift` for a page)
- `cmd+home` / `cmd+end` — jump to the top / bottom of history
- `cmd+R` — restart the shell after it exits

Trackpad and mouse-wheel scrolling over the grid scrolls history directly.
