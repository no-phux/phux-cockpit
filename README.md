# Phux Cockpit

Phux Cockpit is a native macOS workbench around
[phux](https://github.com/phall1/phux). Version 0.2.0 introduces a stable Work
rail over three real execution surfaces: the installed phux TUI, an ephemeral
local scratch shell, and a focused system-WebKit research surface.

## Companion scope

- **Workspace** runs the installed `phux` executable. It is the same durable
  TUI and workspace state you get by running `phux` in a terminal.
- **Scratch** is owned by this app process. It is ephemeral:
  closing or restarting the app ends that shell, and it is not a durable phux
  session.
- **Web** is a native WebKit surface for the explicitly allowed GitHub,
  Superlogical, and Mitchell Hashimoto top-level origins. It keeps its page
  process alive while another Work is selected. Native bridge commands are
  disabled; WebKit subframes and page resources remain ordinary web content.
- This release is **not** the future native `SessionKernel` client. It does not
  embed `SessionKernel<NativeEngine>`, attach through a native protocol, or
  replace phux's TUI. That integration waits for phux's versioned libghostty
  checkpoint bootstrap and shared kernel layers.

Both terminal executions stay live while hidden. The selected terminal is
backed by libghostty-vt and painted into a native-sdk Metal surface; Web is a
real platform webview layered into the same window. The native layer does not
parse or fabricate phux application state.

## Install

Phux must be installed and available on `PATH`. Install the companion with
Homebrew:

```sh
brew install --cask phall1/tap/phux-cockpit
```

The cask installs the `phux` formula from the same tap, then places **Phux
Cockpit** in Applications. Version 0.2.0 is ad-hoc signed; the cask clears its
quarantine attribute and reports that fact in its caveat.

## Keybindings

| Key | Action |
|---|---|
| `cmd+1` | Select Workspace |
| `cmd+2` | Select Scratch |
| `cmd+3` | Select Web |
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
| `cmd+R` | Restart the selected terminal after its process exits |

Clicking a Work row switches surfaces without stopping hidden work. Trackpad
and mouse-wheel input scrolls only inside the selected terminal; wheel input
over the rail never leaks into a hidden execution.

## Requirements

- Apple silicon Mac running macOS 11 or later
- `phux` installed and discoverable on `PATH` (the cask installs it)
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

- Version 0.2.0 is an early product slice, not a native phux session client.
- Workspace depends on an independently installed `phux`; the app does not
  bundle or update phux.
- Scratch is disposable and has no phux session semantics.
- Web allowlists top-level navigation; it is not a content firewall for
  subframes or page resources. native-sdk v0.7.1 does not expose page title,
  committed-navigation, load-state, or native back/forward events to Zig, so
  Cockpit does not pretend to own general browser history.
- The initial Work records are fixed; user-created durable Work and promotion
  in place require the next persistence/session integration slice.
- Window and shell state are not restored between launches.
- Headless tests prove terminal and UI behavior but cannot prove live Metal
  presentation.
- The 0.2.0 release is ad-hoc signed rather than Apple-notarized. Homebrew
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
