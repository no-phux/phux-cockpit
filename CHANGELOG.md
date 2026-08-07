# Changelog

All notable changes to Phux Cockpit are documented in this file. The project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0](https://github.com/phall1/phux-cockpit/compare/v0.5.0...v0.6.0) (2026-08-07)


### Features

* **cockpit:** add the recursive pane layout tree ([63e806a](https://github.com/phall1/phux-cockpit/commit/63e806a100cbcf50a2296c46125be90617723b54))
* **cockpit:** pack the terminal into one cell grid, and finish the chrome ([b7c7c08](https://github.com/phall1/phux-cockpit/commit/b7c7c08e7f1807d5e98976748694696081ff23f4))
* **cockpit:** rebuild layout, close semantics, chrome, and terminal fidelity ([20d82dd](https://github.com/phall1/phux-cockpit/commit/20d82dd58719e5294c4d72a99090426f6f7b5cc8))
* multiple windows, each with its own workspace ([74c9ca6](https://github.com/phall1/phux-cockpit/commit/74c9ca63afbebd36119bffb96b83ebc7c4dec185))
* restore the GPU path, persist the workspace, and make close mean close ([ff04874](https://github.com/phall1/phux-cockpit/commit/ff04874ea773cfccf05d87ff55afcd06b2171f11))
* scrollback search, and bold and italic that actually render ([814f447](https://github.com/phall1/phux-cockpit/commit/814f447aa3c496c0daa8581c927f99e824f9175d))
* **terminal:** carry every SGR attribute into the packed cell ([984fa38](https://github.com/phall1/phux-cockpit/commit/984fa381990951a569758d6436947548dfb7fed7))


### Bug Fixes

* repair the production phux provider build ([3544f4c](https://github.com/phall1/phux-cockpit/commit/3544f4c192f417e82c8ae64f8c009fc046ff9c06))
* retain the copied selection on remote panes ([2fb8927](https://github.com/phall1/phux-cockpit/commit/2fb8927eea3385018002d1f7cdf6458d8953da0d))


### Documentation

* describe the terminal that exists now ([d2ff2a2](https://github.com/phall1/phux-cockpit/commit/d2ff2a28172bf185b9fdc9c55ab0df16c5f503f9))
* rewrite the topology snapshot doc for pane trees ([c8bcb18](https://github.com/phall1/phux-cockpit/commit/c8bcb18b3aac4bbd365563c345633d5630e308b6))

## [0.5.0](https://github.com/phall1/phux-cockpit/compare/v0.4.0...v0.5.0) (2026-08-05)


### Features

* **cockpit:** polish terminal workspace ([#11](https://github.com/phall1/phux-cockpit/issues/11)) ([431b67c](https://github.com/phall1/phux-cockpit/commit/431b67cae91541350e2dc7aeb2be485b5a33841c))


### Refactors

* **cockpit:** organize source by ownership ([#12](https://github.com/phall1/phux-cockpit/issues/12)) ([b77e0e1](https://github.com/phall1/phux-cockpit/commit/b77e0e1e3734709172eb6184f4a4e8a75b8f6bea))

## [0.4.0] - 2026-08-04

### Changed

- Cockpit at rest is now a bare terminal. The tab and control band emerges only
  when the workspace has structure to show — a second terminal, a split, the Web
  surface, or a terminal needing attention — and retracts when it does not.
  Reveal is driven only by discrete state the operator caused, so nothing
  incidental reflows the content area or resizes a live PTY. Every control the
  band carried stays reachable by keyboard in every state, and the titlebar
  inset keeps the window draggable when the band is absent.
- Terminal surfaces now carry a self-sufficient accessibility label (identity,
  provider, and lifecycle) rather than relying on the tab above them.
- Phux terminals published by a coordinator now enter the same bounded tab
  topology as local terminals instead of claiming a visible placement on
  discovery. Reconciliation prunes placements whose remote terminal is gone and
  no longer evicts a live local terminal. `cmd+W` closes local terminals only.
- Topology snapshots persist local topology only, through a dedicated snapshot
  selection type; a remote terminal's existence belongs to its coordinator.

- Terminal tabs now expose hidden process failures, while compact status chrome
  prioritizes the active exception, preserves full diagnostic semantics, and
  distinguishes spawn rejection from spawn failure.
- Clean and abnormal exits now provide placement-specific Restart controls;
  `cmd+R` continues to restart the focused terminal.
- Current PTY input stalls clear after recovery; native delivery failures remain
  distinct from bytes confirmed lost in an application queue.
- Terminal pointer interaction now includes native Copy/Paste menus, persistent
  copied highlights, I-beam and text-value accessibility, edge autoscroll,
  protocol-fenced captures, and fair independent wheel accumulation.
- Secondary click has explicit mode ownership: a live mouse-reporting TUI gets
  raw down/up without AppKit menu tracking; local and ended terminals get the
  native Copy/Paste menu instead.

## [0.3.0] - 2026-08-02

### Added

- Native accessible tabs for two terminal surfaces and system WebKit.
- A real draggable and keyboard-operable terminal split with model-owned
  geometry, active-pane focus, and direct `cmd+D` control.
- Previous/next tab shortcuts that remain available while WebKit owns the
  native first responder, plus split-pane focus shortcuts on the terminal
  canvas.
- Combined two-terminal rendering budgets and adversarial coverage for IDs,
  geometry, input isolation, PTY resizing, and process-lifetime independence.

### Changed

- Cockpit no longer launches or embeds the phux TUI. Both terminal surfaces
  run ordinary login-configured interactive shells while the native
  control-plane protocol remains future work.
- Surface identity is independent from single/split placement; entering,
  resizing, focusing, and leaving a split preserves both live sessions.
- The Work rail has been replaced by a compact native tab and action band,
  returning the full window width to content.

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

[0.4.0]: https://github.com/phall1/phux-cockpit/releases/tag/v0.4.0
[0.3.0]: https://github.com/phall1/phux-cockpit/releases/tag/v0.3.0
[0.2.0]: https://github.com/phall1/phux-cockpit/releases/tag/v0.2.0
[0.1.0]: https://github.com/phall1/phux-cockpit/releases/tag/v0.1.0
