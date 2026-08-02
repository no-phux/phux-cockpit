# Changelog

All notable changes to Phux Cockpit are documented in this file. The project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-08-02

### Added

- A stable Work rail over Workspace, Scratch, and Web surfaces.
- A native system-WebKit research surface with allowlisted top-level origins,
  disabled native commands, and explicit app-owned root navigation.
- Product-level Work selection independent from terminal focus, including
  `cmd+1`, `cmd+2`, and `cmd+3` navigation.

### Changed

- The selected terminal now uses the full content area while hidden terminal
  executions continue ingesting output without reset or respawn.
- Pointer, keyboard, paste, restart, and wheel routing are surface-aware so a
  webview or rail interaction cannot leak into a hidden terminal.
- Test coverage now verifies Work transitions, hidden execution preservation,
  WebKit bindings, rail isolation, accessibility, and selected-surface budgets.

## [0.1.0] - 2026-08-02

### Added

- Interim macOS Companion with Workspace and Local Shell terminal panes in one
  native Metal window.
- Keyboard focus, selection, safe terminal-aware copy/paste, scrollback, and
  pane restart controls.
- A fixed dark graphite and lime Phux visual register with concise, accessible
  process and I/O-loss status.
- Native app identity, icon, ad-hoc local packaging, optional Developer ID
  signing and notarization, ZIP and DMG artifacts, and SHA-256 checksums.
- macOS CI and tag-driven GitHub release automation for Zig 0.16.0.

### Known limitations

- Workspace delegates to the installed phux TUI; this is not the future native
  `SessionKernel` client.
- Local Shell is ephemeral and is not a durable phux session.
- The release supports Apple silicon macOS only.

[Unreleased]: https://github.com/phall1/phux-cockpit/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/phall1/phux-cockpit/releases/tag/v0.2.0
[0.1.0]: https://github.com/phall1/phux-cockpit/releases/tag/v0.1.0
