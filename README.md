# Phux Cockpit

Phux Cockpit is the macOS companion for
[phux](https://github.com/phall1/phux). Version 0.1.0 is an intentionally
interim, terminal-backed release: it puts the installed phux TUI and an
ephemeral local shell side by side in one native Metal window.

## Companion scope

- **Workspace** runs the `phux` executable already installed on your Mac. It is
  the same TUI and workspace state you get by running `phux` in a terminal.
- **Local Shell** is owned by this app process. It is ephemeral:
  closing or restarting the app ends that shell, and it is not a durable phux
  session.
- This release is **not** the future native `SessionKernel` client. It does not
  embed `SessionKernel<NativeEngine>`, attach through a native protocol, or
  replace phux's TUI. That integration waits for phux's versioned libghostty
  checkpoint bootstrap and shared kernel layers.

Both panes are real PTYs backed by libghostty-vt and painted into one native-sdk
Metal surface. The native layer owns terminal state and pixels; it does not
parse phux application state.

## Install

Phux must be installed and available on `PATH`. Install the companion with
Homebrew:

```sh
brew install --cask phall1/tap/phux-cockpit
```

The cask installs the `phux` formula from the same tap, then places **Phux
Cockpit** in Applications. Version 0.1.0 is ad-hoc signed; the cask clears its
quarantine attribute and reports that fact in its caveat.

## Keybindings

| Key | Action |
|---|---|
| `cmd+1` | Focus Workspace |
| `cmd+2` | Focus Local Shell |
| `cmd+shift+space` | Enter or leave keyboard selection mode |
| Arrow keys | Move the selection caret |
| `shift` + arrow keys | Extend the selection |
| `B` | Toggle block selection while selecting |
| `enter` | Copy and leave selection mode |
| `esc` | Cancel selection mode |
| `cmd+C` | Copy the active selection |
| `cmd+V` | Safely paste the system clipboard into the focused pane |
| `cmd+arrow-up` / `cmd+arrow-down` | Scroll one history line (`shift` scrolls a page) |
| `cmd+home` / `cmd+end` | Jump to the top or bottom of history |
| `cmd+R` | Restart the focused pane after its process exits |

Clicking a pane focuses it. Trackpad and mouse-wheel input scrolls the pane
under the pointer.

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

## Limitations

- Version 0.1.0 is an interim Companion, not a native phux session client.
- Workspace depends on an independently installed `phux`; the app does not
  bundle or update phux.
- Local Shell is disposable and has no phux session semantics.
- Window and shell state are not restored between launches.
- Headless tests prove terminal and UI behavior but cannot prove live Metal
  presentation.
- The 0.1.0 release is ad-hoc signed rather than Apple-notarized. Homebrew
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
