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

## Rendering Evidence

`native automate screenshot` renders through the SDK's CPU reference renderer,
not through the real macOS rasterizer. It cannot see anything CoreText does,
which is why a 35% text-weight defect once survived three diagnoses. Never
conclude "the text renders correctly" from a screenshot. Read
[docs/RENDER_FIDELITY.md](docs/RENDER_FIDELITY.md) before writing any test that
claims to check what the terminal looks like.

## Running the App

```sh
./scripts/dev-run.sh
```

Builds this checkout and runs it as a real app that cannot be confused with
`/Applications/Phux Cockpit.app`: its own bundle id, its own process name
(`phux-cockpit-dev`, so `pgrep -x` and System Events target it and not the
installed copy), and its own config, layout and automation dropbox under
`.dev-run/`. Never hand someone a change to look at by telling them to open the
installed app — three days of bug reports once went to a build a week older
than `main` exactly that way. `./scripts/dev-isolation-check.sh` is the proof
and README explains the mechanisms.

## Quality Bar

Every change should reduce cognitive load, preserve input and lifecycle
correctness, remain keyboard-fast and pointer-natural, and keep the interface
calm under concurrency. If a feature adds another surface to monitor without
compressing operational complexity, it is pointed in the wrong direction.

## The Gate

```sh
zig build test > /tmp/t.log 2>&1; echo "exit=$?"
```

**Judge the run by the exit code.** Never by a log line. Nothing printed to
stdout or stderr is authoritative, and a green run has previously ended with a
line reading `failed command: .../test --listen=-`.

**Then read the verdict.** The run ends with a block naming what it compiled:

```
------------------------------------------------------------------
zig build test: PASS
  phux provider: COMPILED AND TESTED (transport, host, provider, pointer)
  ...
------------------------------------------------------------------
```

The verdict step depends on every test step, so it prints only when all of
them succeeded. **No verdict block means the run was not green**, whatever
else the output says.

A verdict that says `PASS, INCOMPLETE` means `src/providers/phux/` was not
compiled, because the phux client FFI was not found on this machine. The rest
of the run is real; a change under `src/providers/phux/` is not verified by it.
The verdict prints the four locations it searched and how to fix it. Do not
report such a run as verifying a phux change.

The full phux-inclusive invocation, when the FFI lives outside the four
searched locations:

```sh
zig build test \
  -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir="$PWD/../phux/crates/phux-client-ffi/include" \
  -Dphux-client-ffi-lib-dir="$PWD/../phux/target/ffi-release"
```

`-Dphux-enabled=true` additionally swaps the *app* graph onto the phux
provider. It is not needed just to compile and test `src/providers/phux/` —
discovering the FFI is enough for that.

See README.md, "Reading the result of `zig build test`", for the search order
and the reasoning.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
