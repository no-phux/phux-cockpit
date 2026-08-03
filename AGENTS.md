# Phux Cockpit Product Contract

## Immediate Product

Build the most elegant, immediate, reliable native Phux terminal for macOS.
Terminal and TUI-agent workflows are the proving ground, not a disposable
prototype. Input, rendering, focus, process lifecycle, accessibility, and
failure recovery must feel native and exceptionally polished.

`libghostty-vt` is the terminal engine. Phux Cockpit owns the product model,
native interaction, orchestration, and presentation.

## North Star

Phux Cockpit is becoming a native control environment for directed machine
work. One person should eventually direct hundreds or thousands of agents,
runs, processes, and services while attending only to meaningful decisions.
Building and using agents belong to one work model; they are not separate
products.

Read [docs/PRODUCT_DIRECTION.md](docs/PRODUCT_DIRECTION.md) before changing
product structure, identity, navigation, or orchestration boundaries.

## Decision Rules

- Make today's terminal simpler and better; do not expose future architecture
  as premature fleet-management UI.
- Treat terminals, agents, and processes as provider-backed resources attached
  to stable product identities. Never make tab, pane, window, PID, or
  effect-key position the durable identity.
- Prefer native, direct, spatial interaction over dashboards, chat walls,
  generic cards, or configuration-heavy workflows.
- Design for progressive disclosure and exception-driven attention. More work
  must not create proportionally more things for the operator to watch.
- Preserve evidence and lineage from objective to run, session, and artifact.
- Keep local operation first-class; distributed execution must extend the same
  model rather than replace it.
- Do not fake detach, restoration, durability, or visibility when an underlying
  runtime seam is missing. Establish the seam and test its invariants first.

## Quality Bar

Every change should reduce cognitive load, preserve input and lifecycle
correctness, remain keyboard-fast and pointer-natural, and keep the interface
calm under concurrency. If a feature adds another surface to monitor without
compressing operational complexity, it is pointed in the wrong direction.
