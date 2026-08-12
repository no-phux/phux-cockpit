# Phux Cockpit

Phux Cockpit is a native macOS spatial runtime for terminal, web, and future
control-plane surfaces. Native Phux terminals use the same bounded tabs and
split-pane substrate as local terminal processes.

The immediate goal is an exceptional native Phux terminal for terminal and
TUI-agent work. Its stable execution and interaction primitives grow into a
native control environment for large-scale directed machine work. See
[Product Direction](docs/PRODUCT_DIRECTION.md).

## Spatial runtime

- Cockpit launches with **one terminal** and one shell process, up to 32. Each
  has a durable terminal ID and owns its own PTY, emulator, scrollback,
  selection, input queue, and retained-rendering namespace. Tab order and
  visible placement do not own execution.
- **A tab owns a pane tree**, not a terminal. A leaf is a terminal; a branch
  divides its rect between two children along an orientation at a fraction.
  `cmd+D` splits right and `cmd+shift+D` splits down, each creating a NEW
  shell beside the focused pane, nested arbitrarily up to 16 panes per tab.
  Closing a pane promotes its sibling into the parent's rect, so a split never
  collapses into a hole and never pulls in an unrelated tab. Splitting,
  focusing, resizing, and collapsing never restart a process.
- **One geometry.** `resolve()` over that tree is the single source of truth
  for pane rects: the painter, the hit-test widget tree, and the PTY sizing
  pump all consume the same call. They used to be three independent
  derivations, and they had already drifted.
- **Tabs** are native canvas controls with tab accessibility semantics,
  rendered from a real slice with a close affordance and a `+`. A tab is
  titled by its focused pane's shell title (OSC 0/2), then the last component
  of its working directory (OSC 7), then its mint number. Tabs can sit above
  the workspace or in a side rail without changing terminal identity, focus,
  or process state.
- **Web** is a native WebKit surface for the explicitly allowed GitHub,
  Superlogical, and Mitchell Hashimoto top-level origins, reachable by
  `cmd+shift+B` and the View menu. It is deliberately NOT a tab in the
  terminal strip: the strip shows terminals. It keeps its page process alive
  while a terminal is selected. Native bridge commands are disabled; WebKit
  subframes and page resources remain ordinary web content.
- **The workspace persists.** Tab list, pane trees, divider fractions,
  selection, focus, and each terminal's working directory are written to the
  platform state directory on a debounce and restored before the first
  terminal is created. Restoring recreates shells in the saved shape;
  `process_restoration_supported` is `false` and nothing pretends otherwise.
- **Phux terminals** published by a coordinator enter the same bounded tab
  topology as local ones. One that appears becomes a tab; it takes a visible
  pane when you select it, never by displacing a live local terminal. `cmd+W`
  closes local terminals only — a phux terminal's lifetime is not Cockpit's to
  end. Cockpit still does not run the phux TUI.

## Chrome that costs nothing

At rest Cockpit is a terminal, not an application frame around one. A single
healthy terminal gets the whole content area: no tab strip, no toolbar, no
status banner.

**Tabs live in the titlebar.** A `hidden_inset_tall` window is already carrying
~66pt of band that holds three traffic lights and nothing else, and its height
does not depend on how many tabs exist — so the strip drawn inside it takes no
content height in any state. This is the difference between chrome that is
cheap to reveal and chrome there is nothing to reveal: `content.y` does not
move, so no terminal is resized and no TUI redraws. The old separate 50pt band
cost every terminal in the tab three rows and a `SIGWINCH` on the way in, and
another on the way out. It survives only for a window the platform gave no
titlebar — fullscreen — where the room genuinely has to come from somewhere.

The strip appears when the workspace has structure to show: a second tab, the
Web surface, or a terminal that needs attention. A split alone does not raise
it — two panes in one tab are still one tab, and the divider says so. Attention
is *unacknowledged* state, not cumulative: looking at a terminal clears it, the
way a bell already worked. The loss counters themselves stay cumulative, because
they are the evidence in each surface's accessibility label, and a diagnostic
that resets is a diagnostic that lies.

**`cmd+shift+P` summons a switcher** that floats over the grid instead of taking
room from it — type to filter by shell title, working directory, or position,
`enter` to go. It is the path that still works at thirty terminals, where a
strip has to start windowing and shrinking pills, and it is the seam this app
grows through toward directing many machines at once.

Tabs can sit in a side rail instead (`tab-placement = side`, or View > Toggle
Tab Placement) without changing terminal identity, focus, or process state. The
rail moves the cost onto the columns axis, which reflows far more cheaply than
rows.

The band is presentation, never the only path: every shortcut in the table below
reaches the model whether or not it is showing, and the menu bar carries the
same commands. The window stays draggable by its titlebar inset in every state.

All terminal executions stay live while hidden or reordered. libghostty-vt owns
terminal state, and native-sdk paints each visible pane as one packed
`cell_grid` command per row — a lattice of 20-byte cells the renderer expands,
rather than per-run rectangles and text. That is what lets a dense screen paint
in full: a distinct foreground and background on every cell merges nothing, and
the old per-run emission wanted roughly 24,000 commands for a 200x60 screen
against a 2,048 ceiling, truncating from the bottom without saying so. Where a
budget does genuinely bind, the painter reports the loss instead of quietly
dropping rows.

Terminal tabs show an attention dot when a hidden process rings the bell or
develops an operational issue, and an exception is itself enough to bring the
strip back when a lone terminal is in trouble. Splits carry no pane header at
all: the focused pane wears a hairline accent edge, the others are dimmed by a
scrim, and that is the whole indication. The scrim dims toward **black**, not
toward the window's own ground — painting the ground over panes that already
carry it composited a colour over itself, which changes nothing at any alpha,
so the dim used to draw literally nothing and a four-way split was told apart
only by a solid-versus-hollow cursor. The accent edge is what survives the case
the scrim still cannot serve: a terminal configured black, or put there by an
application's OSC 11, has no luminance left to take away.

Byte counts, I/O-loss badges and lifecycle strings are not product chrome — they
live in each surface's accessibility label, so a screen reader keeps every
detail the eye is spared.

**A shell that ends closes its pane, at any exit status**, and its sibling
reclaims the rect. Exit code is the child's answer about the last command it
ran, not a claim about whether the pane is still wanted — and `exit` inherits
that status, so gating the close on it left an ordinary session ended by an
ordinary failed command sitting behind a permanent `EXIT 1` husk that never gave
the space back. The one end that still leaves a pane standing is a spawn that
never produced a process: there is nothing to close to, and a split that
vanished on its own would read as a broken `cmd+D`. That pane says so where it
is, with its **Restart**.

The local provider is a bounded dynamic registry independent from layout. Close
frees the emulator immediately rather than holding a registry slot against a pty
exit that may never arrive, discards post-close output and generated terminal
replies, and never reuses PTY keys in-process, so stale traffic cannot cross
into a replacement terminal. Closing the last pane closes its tab, and closing
the last tab closes the window *and quits* — AppKit keeps a process alive after
its last window unless asked not to, and a running cockpit with no window is not
a closed one.

`Model.topologySnapshot()` exposes the versioned persistence boundary for the
tab list, each tab's pane tree, selection, focus, divider fractions, and
per-terminal working directories. `restoreModel()` validates or migrates that
snapshot and creates new emulator sessions and shell processes. The snapshot
intentionally contains no PID, PTY key, screen memory, or process-survival
claim. It is stored as a flat line-oriented file with an explicit terminator,
chosen over a nested format because it is read at startup from a user-editable
path a crash may have half-written, and a grammar with no nesting cannot
overflow a stack however the bytes fall. See
[Topology Snapshots](docs/TOPOLOGY_SNAPSHOTS.md).

## Configuration

Cockpit reads `~/.config/phux-cockpit/config` (or `$XDG_CONFIG_HOME/…`), falling
back to the macOS platform config directory. The dotfile path is searched first
on purpose: the people most likely to write one are arriving from Ghostty and
will not go looking in `~/Library/Preferences`. `PHUX_COCKPIT_CONFIG` overrides
both.

The syntax is Ghostty's — one `key = value` per line, `#` starts a whole-line
comment, and there are deliberately no trailing comments because `#` is also how
every colour begins. An unknown key or a malformed value is a diagnostic, not a
failure: one bad line costs that line, never the rest of the file. A config that
produced any diagnostic raises **one line of chrome above the terminal naming
the line numbers**, dismissed by clicking it; the startup log carries the same
diagnostics in full, with the offending key or value quoted. The band takes no
keyboard and holds no chord — a setting that did nothing is not a reason to
stand between you and a prompt.

```
theme = nord
font-size = 14
cursor-style = bar
cursor-style-blink = false
background = #090b0f
foreground = #f4f7fb
palette = 1 = #f38ba8
scrollback-limit = 50000000
shell = /opt/homebrew/bin/fish
inherit-working-directory = true
tab-placement = top
```

### Themes and the settings surface

`theme = <name>` names one of the built-in sets — `phux-dark`, `phux-light`,
`high-contrast`, `nord`, `gruvbox-dark`, `solarized-dark`. A theme sets
`background`, `foreground` and `selection-background`; an explicit key for any
of those **outranks** it, wherever the two lines happen to sit in the file. It
deliberately leaves the ANSI-16 palette alone, so a terminal red stays a
terminal red — see [Decisions](docs/DECISIONS.md).

**`cmd+,`** (or **View > Settings…**) opens the settings surface. Up and down
preview a theme LIVE against whatever is on screen, `return` saves the choice
into your config file, and `esc` puts back the one you had. The panel writes
only the `theme` line: your comments, your spacing, and any key this build has
never heard of are copied through untouched.

The panel also shows the **contrast ratio** between the foreground and
background actually being painted, and flags it when it drops below the WCAG AA
minimum for body text (4.5:1). That readout is there so "I can't read my
terminal" is something you can see the answer to rather than something that
needs investigating. Every built-in theme clears the threshold; a test keeps it
that way.

The panel's own colours are fixed and never follow the theme. A settings page
you cannot read when the theme is broken is worse than none.

`shell` (or `command`) is a command LINE, not just a path, so `command = tmux
attach` keeps its argument. It runs via the login shell with `exec`, so the
program you name is the pty's own process. A value that is empty, over-long, or
carries a NUL is refused and the built-in shell stands.

`font-family` and `selection-foreground` are parsed but **cannot** be applied in
this build: the SDK selects faces from a fixed registered set rather than by
family name, and a terminal grid carries one selection colour rather than a
foreground override. Setting either raises the notice above, and logs a line,
saying so.

## Install

Install with Homebrew:

```sh
brew install --cask phall1/tap/phux-cockpit
```

The cask places **Phux Cockpit** in Applications. Releases without configured
Developer ID credentials are ad-hoc signed; the cask clears the quarantine
attribute and reports that fact in its caveat.

## Keybindings

| Key | Action |
|---|---|
| `cmd+1` ... `cmd+5` | Select the tab at that position |
| `cmd+T` | Create and select a tab, up to 32 terminals |
| `cmd+W` | Close the focused pane, then its tab, then the window |
| `cmd+shift+left` / `cmd+shift+right` | Move the selected tab |
| `cmd+shift+[` / `cmd+shift+]` | Select previous or next tab |
| `cmd+D` | Split right, creating a new shell beside the focused pane |
| `cmd+shift+D` | Split down, creating a new shell below the focused pane |
| `cmd+[` / `cmd+]` | Focus previous or next pane |
| `cmd+option+arrows` | Move keyboard focus to the pane in that direction |
| `cmd+=` / `cmd+-` / `cmd+0` | Increase, decrease, or reset the terminal font size |
| `cmd+A` | Select the whole scrollback |
| `cmd+click` | Open the URL under the pointer |
| `cmd+K` | Clear the screen and scrollback |
| `cmd+shift+P` | Go to terminal — the summoned switcher (type to filter, arrows or `ctrl+N`/`ctrl+P` to move, `enter` to go, `esc` to dismiss) |
| `cmd+,` | Settings — themes with a live preview and a WCAG contrast readout (arrows or `ctrl+N`/`ctrl+P` to preview, `return` to save, `esc` to cancel) |
| `cmd+shift+B` | Show the Web surface |
| `cmd+shift+space` | Enter or leave keyboard selection mode |
| Arrow keys | Move the selection caret |
| `shift` + arrow keys | Extend the selection |
| `B` | Toggle block selection while selecting |
| `enter` | Copy and leave selection mode |
| `esc` | Cancel selection mode |
| `cmd+C` | Copy the active selection |
| `cmd+V` | Safely paste the system clipboard into the selected terminal |
| `cmd+arrow-up` / `cmd+arrow-down` | Scroll one history line (`shift` scrolls a page) |
| `cmd+home` / `cmd+end` | Jump to the top or bottom of history |
| `cmd+R` | Restart the focused terminal after its process exits |

Clicking a tab switches surfaces without stopping hidden execution. Clicking a
split pane moves input ownership to it. The divider supports pointer dragging,
arrow-key adjustment, Home, and End. Trackpad and wheel input route only to the
terminal under the pointer. Dragging a selection beyond the top or bottom edge
autoscrolls through history. Right-click or control-click opens native Copy and
Paste actions while Cockpit owns pointer selection or the process has ended.
While a live TUI enables mouse reporting, it exclusively owns secondary click,
so the native menu is intentionally unavailable; Shift-drag selection remains
copyable with `cmd+C`. `cmd+click` opens a URL under the pointer, and works
even while a TUI owns mouse reporting — a program that prints links should not
have to give up mouse input for them to be clickable. It is deliberately a
heuristic that fails toward "not a link": only `http`, `https` and `mailto` are
recognised, so a printed `file:` or `javascript:` path is never something the
OS can be asked to open. A `cmd+click` on ordinary text is an ordinary click. A copied range remains highlighted until typing or
another selection clears it. Terminal tab reorder remains available through the
menu command and keyboard shortcut; direct tab dragging is not claimed.

## Requirements

- Apple silicon Mac running macOS 11 or later
- Zig 0.16.0 and Xcode Command Line Tools for source builds
- Internet access on the first source build to fetch pinned dependencies

native-sdk is pinned to
[`phall1/native@f3678832`](https://github.com/phall1/native/commit/f3678832fd282b81241993d0c08105cd5170f39f),
the head of that fork's `cockpit/v0.8.4` branch: upstream v0.8.4 plus Cockpit's
terminal interaction, viewport, and font seams, the packed `cell_grid` canvas
command with its AppKit decoder and wire format v6, macOS glyph smoothing, the
per-window `ChromeContext` on `build_window` and `web_panes`, and `fx.openUrl`.
The pin is a tarball SHA rather than a branch, so a push to the fork can never
break a checkout of Cockpit — see [docs/SDK_PIN.md](docs/SDK_PIN.md) for how the
fork and this repo stay in contract, and what to run before moving the pin.
libghostty-vt is pinned
to Ghostty commit `7aa9591746ffa4d2eee458960c76554352832595`, the existing
Zig 0.16-compatible checkpoint.

## Build and test

```sh
zig build
zig build run
zig build test -Dplatform=null --summary all
```

### Reading the result of `zig build test`

Two things have to be true for a test run to mean anything: it has to have
passed, and it has to have compiled the code you changed. `zig build test`
now answers both, in that order.

**Did it pass?** The exit code, and only the exit code.

```sh
zig build test > /tmp/t.log 2>&1; echo "exit=$?"
```

Do not judge from a log line. A green run used to end with

```
failed command: ./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache ... --listen=-
```

which read as a failure and was not one. That line came from tests calling
`std.debug.print` on the happy path: Zig 0.16's build runner prints a
step-failure report — including `failed command:` — for any step whose captured
stderr is non-empty, whether or not the step failed. Those prints are now behind
`-Dmeasure=true` (see `src/tests/measured.zig`), so a passing run is quiet.

**What did it compile?** The last thing the run prints is a verdict:

```
------------------------------------------------------------------
zig build test: PASS
  phux provider: COMPILED AND TESTED (transport, host, provider, pointer)
    ffi include: /Users/you/workspace/phux/crates/phux-client-ffi/include
    ffi lib:     /Users/you/workspace/phux/target/ffi-release
    found via:   ../phux sibling checkout
  app graph:     local terminal provider (-Dphux-enabled defaults to false)
------------------------------------------------------------------
```

The verdict is a build step that depends on every test step, so it prints only
when all of them succeeded. **No verdict means the run was not green.**

The named modules are the ones rooted as test artifacts. `extension.zig` is
compiled but not rooted: its tests have never run anywhere, and rooting them
hangs the build. See phux-cockpit-iwf and the comment on
`phux_test_module_names` in `build.zig`.

`src/providers/phux/` needs the phux client FFI, so `zig build test` looks for
`phux/client.h` and `libphux_client_ffi.a` in four places, in order:

1. `-Dphux-client-ffi-include-dir` / `-Dphux-client-ffi-lib-dir`
2. `$PHUX_CLIENT_FFI_INCLUDE_DIR` / `$PHUX_CLIENT_FFI_LIB_DIR`
3. `./.phux/crates/phux-client-ffi/include` and `./.phux/target/ffi-release`
4. `../phux/crates/phux-client-ffi/include` and `../phux/target/ffi-release`

If it finds them, the provider is compiled and its tests run — regardless of
`-Dphux-enabled`. If it does not, everything else still runs and passes, and the
verdict says `PASS, INCOMPLETE` and names what was left out. Without that line, a
signature change to `PhuxProvider.search` or `Host.search` passes a local run
without ever being compiled.

Being in the build graph is not the same as being compiled: Zig analyzes only
what is referenced, and nothing in Cockpit calls `PhuxProvider.search`. Each
rooted module therefore ends with

```zig
test "every declaration in this module is compiled, not merely reachable" {
    @import("phux_ref").refAllDeclsRecursive(@This());
}
```

which is what makes the verdict's "COMPILED" claim true.

To build the FFI for a sibling checkout:

```sh
cargo build --locked --profile ffi-release -p phux-client-ffi \
  --manifest-path ../phux/Cargo.toml
```

`-Dphux-enabled=true` is a separate question: it swaps the **app** graph from the
local terminal provider to the phux provider. It requires the FFI and now fails
loudly rather than building a local-terminal app under a phux flag:

```sh
zig build test -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir="$PWD/../phux/crates/phux-client-ffi/include" \
  -Dphux-client-ffi-lib-dir="$PWD/../phux/target/ffi-release"
```

Tabs start at the top by default. Set `PHUX_COCKPIT_TABS=side` (or `sidebar`)
to start with the side rail; the in-app placement control switches the current
workspace without restarting or resizing through intermediate states.

The application is macOS-only. The null platform is used only for deterministic
tests; it does not exercise Metal presentation.

### Running a local build beside the installed app

Both can coexist: Homebrew installs an `.app` bundle, `zig build` produces a
bare binary in `zig-out/bin`. They are different files in different places, so
nothing needs uninstalling to test a change.

What they *would* have shared is your saved layout. A debug build writes
`workspace-dev.state` and a packaged build writes `workspace.state`, keyed off
the optimize mode so it is right without anyone remembering — plain `zig build`
is Debug, and `scripts/package-macos.sh` is ReleaseSafe. Without that split, a
dev build running a newer schema would replace the layout the installed app was
about to restore; the version guard means the loser opens a fresh window rather
than crashing, but a window arrangement lost to a test build still reads as the
app having forgotten it.

Config is deliberately NOT split: font size and colors are yours, and you want
them in both.

To separate two builds of the same optimize mode, or to keep a scratch layout
entirely apart, override the paths:

```sh
PHUX_COCKPIT_STATE=/tmp/cockpit-scratch.state \
PHUX_COCKPIT_CONFIG=~/.config/phux-cockpit/scratch \
  ./zig-out/bin/phux-cockpit
```

Add `-Dautomation=true` to drive the running app: commands are written as
`command-<n>.txt` files into `.zig-cache/native-sdk-automation/`, and
screenshots and a full widget snapshot appear beside them.

## Package

Create an arm64 app, ZIP, DMG, and `SHA256SUMS` under `zig-out/release`:

```sh
cargo build --locked --profile ffi-release -p phux-client-ffi \
  --manifest-path ../phux/Cargo.toml
PHUX_CLIENT_FFI_INCLUDE_DIR="$PWD/../phux/crates/phux-client-ffi/include" \
PHUX_CLIENT_FFI_LIB_DIR="$PWD/../phux/target/ffi-release" \
  ./scripts/package-macos.sh
```

Release and CI builds pin that static FFI to Phux `v0.12.0`. Set
`PHUX_ENABLED=false` only for an explicit local-terminal-only package; production
packaging requires and verifies the FFI inputs instead of silently omitting the
coordinator-backed provider.

Verify a packaged or installed bundle and run a process-lifecycle soak with:

```sh
VERSION="$(tr -d '\n' < version.txt)"
./scripts/verify-macos-app.sh \
  --app "zig-out/release/Phux Cockpit.app" \
  --version "$VERSION" \
  --signature-mode adhoc \
  --quarantine absent
./scripts/soak-macos-app.sh \
  --app "zig-out/release/Phux Cockpit.app" \
  --cycles 10 \
  --artifacts zig-out/soak
```

Local packaging ad-hoc signs the app. The hosted release accepts either no
Apple credentials or a Developer ID identity with notarization credentials;
partial credentials fail closed:

```sh
MACOS_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
APPLE_NOTARY_KEY_PATH="$HOME/private/AuthKey_KEYID.p8" \
APPLE_NOTARY_KEY_ID="KEYID" \
APPLE_NOTARY_ISSUER_ID="ISSUER-UUID" \
./scripts/package-macos.sh
```

`MACOS_ENTITLEMENTS` may point to an entitlements plist when one is required.
The packaging script validates the bundle identifier, display name, version,
executable, arm64 architecture, and code signature before producing archives.
Release Please maintains a draft version PR from conventional commits. Merging
that PR creates the tag and a draft GitHub release; the release workflow builds,
verifies, and attaches the macOS artifacts before publishing the release and
regenerating `Casks/phux-cockpit.rb` in
[`phall1/homebrew-tap`](https://github.com/phall1/homebrew-tap). The tap's
scheduled updater independently repairs a missed release update.
A failed artifact pass can be resumed by manually dispatching the **Release**
workflow against the existing draft tag.

## Limitations

- Native Phux terminal identity and lifetime remain coordinator-owned; Cockpit
  projects published terminals but does not fake remote close or restoration.
- Layout persistence restores the SHAPE of a workspace, never its processes.
  Tabs, pane trees, divider fractions, selection, focus, and working
  directories come back; scrollback and running programs do not.
  `process_restoration_supported` is explicitly `false` and the snapshot
  carries no PID.
- Working-directory inheritance and shell-titled tabs depend on the shell
  emitting OSC 7 and OSC 0/2. A shell without integration falls back to `$HOME`
  and to numbered tabs — correct, but less useful, and not something Cockpit
  can fix from its side.
- Scrollback search matches case-insensitively for local terminals, because the
  pinned engine's search API exposes no case option. The remote phux provider
  takes a case-sensitivity flag, so the two do not agree.
- `bold` and `italic` are carried into every cell and every renderer but cannot
  change a glyph until companion mono faces are registered; the bundled face is
  the explicit no-ligature JetBrains Mono NL, so ligatures are structurally
  unavailable regardless of renderer support.
- Single window. There is no new-window, fullscreen, or multi-window restore.
- Detachable terminal windows are intentionally not faked. Cockpit does not yet
  project a stable terminal identity into native-sdk's model-declared secondary
  window trees with the same chrome and lifecycle guarantees as the main window.
- Web allowlists top-level navigation; it is not a content firewall for
  subframes or page resources. native-sdk v0.8.1 does not expose page title,
  committed-navigation, load-state, or native back/forward events to Zig, so
  Cockpit does not pretend to own general browser history.
- Headless tests prove terminal and UI behavior but cannot prove live Metal
  presentation.
- Releases without configured Developer ID credentials are ad-hoc signed rather
  than Apple-notarized. Homebrew performs the same explicit quarantine removal
  used by other apps in the tap.

## Project background

This repository began as a spike on 2026-07-27 asking whether phux could have
several independent terminal panes beside ordinary native widgets in one GPU
surface without making the native layer understand terminals.

**Verdict: GO, with caveats.** [`FINDINGS.md`](FINDINGS.md) records what was
built, what broke, what it cost, and how each claim was established. The spike
forked native-sdk's `examples/terminal` at `a7509a7`, grew it into a two-pane
cockpit, and was then ported to the framework's first-party
`canvas.terminal_grid` painter. The old forked painter remains in history at
`git show d4ccb84^:src/box.zig`.

The rendering seam remains deliberately small (`src/terminal/grid.zig`):

```zig
pub fn feed(session: *Session, bytes: []const u8) void {
    session.stream.nextSlice(bytes);
}
```

The rendering spike is complete and closed out. All four steps of `FINDINGS.md`
section 8 were finished, migrated here as PR #7, and developed further since;
this repository is the shipping product, not a validation fixture. The spike
branch was removed on 2026-08-09 and its history preserved at the annotated tag
`spike/first-party-terminal-grid` — `git show spike/first-party-terminal-grid`
for the audit that established nothing was left behind.

The section 7 `phux-client-ffi` sketch is historical, not the next API to
implement. The current phux direction is a versioned libghostty checkpoint
bootstrap and a shared `SessionKernel<NativeEngine>`; the eventual native host
bridge should expose that kernel's effects, borrowed render views, and damage.
Resume that integration here only after those protocol and kernel layers exist.

## License

Apache-2.0. See [`LICENSE`](LICENSE). Bundled dependency licenses and notices
are recorded in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and shipped
inside every application bundle.
