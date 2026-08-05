# Phux Cockpit

Phux Cockpit is a native macOS spatial runtime for terminal, web, and future
control-plane surfaces. Version 0.4.0 brings native Phux terminals into the
same bounded tabs and split-pane substrate as local terminal processes.

The immediate goal is an exceptional native Phux terminal for terminal and
TUI-agent work. Its stable execution and interaction primitives grow into a
native control environment for large-scale directed machine work. See
[Product Direction](docs/PRODUCT_DIRECTION.md).

## Spatial runtime

- Cockpit launches with **one terminal** and one shell process. New creates
  subsequent terminals, up to four. Each has a durable terminal ID and owns its
  own PTY, emulator, scrollback, selection, input queue, and retained-rendering
  namespace. Tab order and visible placement do not own execution.
- **Split** projects at most two live terminal sessions simultaneously through
  a real draggable and keyboard-operable divider. Splitting, focusing,
  resizing, and collapsing never restart either process.
- **Tabs** are native canvas controls with tab accessibility semantics. They
  compact to `T1` through `T4` at full capacity; Web remains stable and pinned
  last. Direct selection and next/previous shortcuts preserve hidden state.
  Tabs can sit above the workspace or in a scroll-safe side rail without
  changing terminal identity, focus, or process state.
- **Web** is a native WebKit surface for the explicitly allowed GitHub,
  Superlogical, and Mitchell Hashimoto top-level origins. It keeps its page
  process alive while another tab is selected. Native bridge commands are
  disabled; WebKit subframes and page resources remain ordinary web content.
- **Phux terminals** published by a coordinator enter the same bounded tab
  topology as local ones. One that appears becomes a tab; it takes a visible
  pane when you select it, never by displacing a live local terminal. `cmd+W`
  closes local terminals only — a phux terminal's lifetime is not Cockpit's to
  end. Cockpit still does not run the phux TUI.

## Chrome that emerges

At rest Cockpit is a terminal, not an application frame around one. A single
healthy terminal gets the whole content area: no tab strip, no toolbar, no
status banner.

The band appears when the workspace actually has structure to show — a second
terminal, a split, the Web surface, or a terminal that needs attention — and
retracts when that structure goes away. Reveal is driven only by discrete state
you caused; nothing incidental moves it, because every change to the band
reflows the content area and resizes a live PTY.

The band is presentation, never the only path: `cmd+T`, `cmd+W`, `cmd+D`, and
`cmd+1`..`cmd+5` reach the model whether or not it is showing. The window stays
draggable by its titlebar inset in every state.

All terminal executions stay live while hidden or reordered. libghostty-vt owns
terminal state and native-sdk paints the visible attachments into one Metal
surface under strict combined command, text, glyph, and path budgets.

Terminal tabs show an attention marker when a hidden process exits or develops
an operational issue, and an exception is itself enough to bring the band back
when a lone terminal is in trouble. Healthy single-terminal mode has no
permanent RUNNING banner. Split mode identifies each pane quietly; lifecycle
text appears only for transitions and exceptions. Full lifecycle and I/O detail remains accessible.
Recovered stalls disappear. Finished terminals expose a placement-specific
**Restart** control for clean and abnormal exits.

The local provider is a bounded dynamic registry independent from layout. New
and Close are native actions; close tombstones one PTY until its exact exit is
delivered, discards post-close output and generated terminal replies, and never
reuses PTY keys in-process. This prevents stale traffic from crossing into a
replacement terminal.

`Model.topologySnapshot()` exposes the versioned persistence boundary for
terminal count, tab order, selection, split attachments, focus, and divider
position. `restoreModel()` validates or migrates that snapshot and creates new
emulator sessions and shell processes. The snapshot intentionally contains no
PID, PTY key, screen memory, or process-survival claim. See
[Topology Snapshots](docs/TOPOLOGY_SNAPSHOTS.md).

## Install

Install with Homebrew:

```sh
brew install --cask phall1/tap/phux-cockpit
```

The cask places **Phux Cockpit** in Applications. Version 0.4.0 is ad-hoc
signed; the cask clears its quarantine attribute and reports that fact in its
caveat.

## Keybindings

| Key | Action |
|---|---|
| `cmd+1` ... `cmd+5` | Select the surface at that current position; Web is always last |
| `cmd+T` | Create and select a terminal, up to four |
| `cmd+W` | Close the selected terminal; Web is never closed |
| `cmd+shift+left` / `cmd+shift+right` | Move the selected terminal tab |
| `cmd+shift+[` / `cmd+shift+]` | Select previous or next tab |
| `cmd+D` | Split terminals or collapse to the active terminal; unclaimed until two terminals exist |
| `cmd+option+left` / `cmd+option+right` | Move keyboard focus across split panes |
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
copyable with `cmd+C`. A copied range remains highlighted until typing or
another selection clears it. Terminal tab reorder remains available through the
menu command and keyboard shortcut; direct tab dragging is not claimed.

## Requirements

- Apple silicon Mac running macOS 11 or later
- Zig 0.16.0 and Xcode Command Line Tools for source builds
- Internet access on the first source build to fetch pinned dependencies

native-sdk is temporarily pinned to
[`phall1/native@49bedbb`](https://github.com/phall1/native/commit/49bedbb794f2d86e74e004f0c00cca5f91b24ff0),
an upstream-ready terminal interaction, viewport, paint-budget, and font seam
over v0.7.1. libghostty-vt is pinned
to Ghostty commit `7aa9591746ffa4d2eee458960c76554352832595`, the existing
Zig 0.16-compatible checkpoint.

## Build and test

```sh
zig build
zig build run
zig build test -Dplatform=null --summary all
```

Tabs start at the top by default. Set `PHUX_COCKPIT_TABS=side` (or `sidebar`)
to start with the side rail; the in-app placement control switches the current
workspace without restarting or resizing through intermediate states.

The application is macOS-only. The null platform is used only for deterministic
tests; it does not exercise Metal presentation.

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
./scripts/verify-macos-app.sh \
  --app "zig-out/release/Phux Cockpit.app" \
  --version 0.4.0 \
  --signature-mode adhoc \
  --quarantine absent
./scripts/soak-macos-app.sh \
  --app "zig-out/release/Phux Cockpit.app" \
  --cycles 10 \
  --artifacts zig-out/soak
```

Local packaging ad-hoc signs the app. A release machine can provide a Developer
ID identity and optional notarization credentials:

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
Tagged releases also regenerate `Casks/phux-cockpit.rb` in
[`phall1/homebrew-tap`](https://github.com/phall1/homebrew-tap); the tap's
scheduled updater independently repairs a missed release update.

## Limitations

- Native Phux terminal identity and lifetime remain coordinator-owned; Cockpit
  projects published terminals but does not fake remote close or restoration.
- Terminal topology has a versioned snapshot/restore API. The executable does
  not yet choose a filesystem persistence policy; restoring always starts fresh
  processes. `process_restoration_supported` is explicitly `false`; filesystem
  persistence remains outside this slice.
- Detachable terminal windows are intentionally not faked. native-sdk v0.7.1
  needs per-secondary-window custom chrome and focus hooks before the same
  terminal surface can attach to another native window correctly.
- Web allowlists top-level navigation; it is not a content firewall for
  subframes or page resources. native-sdk v0.7.1 does not expose page title,
  committed-navigation, load-state, or native back/forward events to Zig, so
  Cockpit does not pretend to own general browser history.
- Headless tests prove terminal and UI behavior but cannot prove live Metal
  presentation.
- The 0.4.0 release is ad-hoc signed rather than Apple-notarized. Homebrew
  performs the same explicit quarantine removal used by other apps in the tap.

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

The rendering spike is complete. Steps 1-3 of `FINDINGS.md` section 8 landed on
`port/first-party-terminal-grid`, and this repository remains the native host
validation fixture.

The section 7 `phux-client-ffi` sketch is historical, not the next API to
implement. The current phux direction is a versioned libghostty checkpoint
bootstrap and a shared `SessionKernel<NativeEngine>`; the eventual native host
bridge should expose that kernel's effects, borrowed render views, and damage.
Resume that integration here only after those protocol and kernel layers exist.

## License

Apache-2.0. See [`LICENSE`](LICENSE). Bundled dependency licenses and notices
are recorded in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and shipped
inside every application bundle.
