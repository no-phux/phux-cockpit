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

A fork of `native-sdk`'s `examples/terminal` (`a7509a7`), grown into a two-pane
cockpit: two independent libghostty-vt panes rendering into one `gpu_surface`,
laid out by the canvas alongside native widgets, with focus routing and a budget
policy derived from the framework's own constants.

It has since been ported onto the framework's first-party `canvas.terminal_grid`
painter, deleting the forked renderer entirely (`grid.zig` 1156 → 916 lines,
`box.zig` gone). The old painter is still in history —
`git show d4ccb84^:src/box.zig`.

```sh
zig build run                    # run the cockpit
zig build test -Dplatform=null   # 70/72 pass, 2 env-gated skips
```

## The finding that mattered

The seam to phux is one line, and it knows nothing about PTYs (`src/grid.zig`):

```zig
pub fn feed(session: *Session, bytes: []const u8) void {
    session.stream.nextSlice(bytes);
}
```

Swapping the byte source for phux `PANE_OUTPUT` frames is a change of *caller*,
not of the terminal stack — ADR-0013's asymmetry landing on the FFI boundary as
intended. Zig owns everything from VT bytes rightward, Rust owns everything
leftward, and Rust never parses a byte.

## Where it stands

Steps 1–3 of `FINDINGS.md` section 8 are done, on
`port/first-party-terminal-grid`. The remaining work is **step 4:
`phux-client-ffi`**, the C ABI, whose minimum shape is specified in section 7.

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
