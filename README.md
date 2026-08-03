# Phux Cockpit

Phux Cockpit is a native macOS spatial runtime for terminal, web, and future
control-plane surfaces. Version 0.3.0 replaces the embedded phux TUI and Work
rail with native tabs and a real split-pane terminal substrate.

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
- **Web** is a native WebKit surface for the explicitly allowed GitHub,
  Superlogical, and Mitchell Hashimoto top-level origins. It keeps its page
  process alive while another tab is selected. Native bridge commands are
  disabled; WebKit subframes and page resources remain ordinary web content.
- Cockpit does not run the phux TUI. A future control-plane client will attach
  native surfaces to phux sessions through a headless protocol.

All terminal executions stay live while hidden or reordered. libghostty-vt owns
terminal state and native-sdk paints the visible attachments into one Metal
surface under strict combined command, text, glyph, and path budgets.

Terminal tabs show an attention marker when a hidden process exits or develops
an operational issue. Healthy single-terminal mode has no permanent RUNNING
banner. Split mode identifies each pane quietly; lifecycle text appears only for
transitions and exceptions. Full lifecycle and I/O detail remains accessible.
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

The cask places **Phux Cockpit** in Applications. Version 0.3.0 is ad-hoc
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
Paste actions, and a copied range remains highlighted until typing or another
selection clears it. Terminal tab reorder remains available through the menu
command and keyboard shortcut; direct tab dragging is not claimed.

## Requirements

- Apple silicon Mac running macOS 11 or later
- Zig 0.16.0 and Xcode Command Line Tools for source builds
- Internet access on the first source build to fetch pinned dependencies

native-sdk is pinned to v0.7.1. libghostty-vt is pinned to Ghostty commit
`7aa9591746ffa4d2eee458960c76554352832595`, the existing Zig 0.16-compatible
checkpoint.

## Build and test

```sh
zig build
zig build run
zig build test -Dplatform=null --summary all
```

The application is macOS-only. The null platform is used only for deterministic
tests; it does not exercise Metal presentation.

## Package

Create an arm64 app, ZIP, DMG, and `SHA256SUMS` under `zig-out/release`:

```sh
./scripts/package-macos.sh
```

Verify a packaged or installed bundle and run a process-lifecycle soak with:

```sh
./scripts/verify-macos-app.sh \
  --app "zig-out/release/Phux Cockpit.app" \
  --version 0.3.0 \
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

- Version 0.3.0 establishes the spatial terminal substrate; it is not yet a
  native phux control-plane client.
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
- The 0.3.0 release is ad-hoc signed rather than Apple-notarized. Homebrew
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

The rendering seam remains deliberately small (`src/grid.zig`):

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
