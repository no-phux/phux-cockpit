# The SDK pin, and the contract across the fork boundary

Cockpit builds against [`phall1/native`](https://github.com/phall1/native), a
fork of `vercel-labs/native`. The fork carries Cockpit-specific commits rebased
over each upstream release, and names the result after the upstream version it
sits on: `cockpit/v0.8.3`, `cockpit/v0.8.4`, and so on. `build.zig.zon` pins one
commit from that lineage by tarball sha.

Cockpit is the fork's only real consumer, and the fork has no test that its
consumer still compiles. `sdk-head.yml` in this repo is that test, run from the
consumer side.

## What the pin being a sha buys, and what it costs

A sha pin means a push to the fork can never break a checkout of Cockpit. Every
existing branch, tag, and CI run keeps resolving the same tarball.

It also means nothing notices when the fork makes a breaking change. The
breakage is deferred, in full, to whoever next bumps the pin — and it arrives as
a compile error in code they did not write, mixed in with whatever they were
actually trying to land.

Observed 2026-08-11: the fork's `web_panes` gained a `ChromeContext` parameter.
The SDK's own suite passed on a full gate. Cockpit did not compile. That was
discovered by hand-building Cockpit against the fork, because nothing else
would have.

## The four checks

| Check | Where | Answers |
|---|---|---|
| Build against the pin | `.github/workflows/ci.yml`, every push and PR | Does Cockpit compile and pass against the SDK it claims to use? |
| Build against the branch head | `.github/workflows/sdk-head.yml`, daily at 07:17 UTC and on dispatch | Has the fork moved somewhere Cockpit cannot follow? |
| Pin documentation agrees | `scripts/check-sdk-pin.sh`, run first in CI | Does README describe the sha that is actually built? |
| Glyph weight holds | `scripts/host-raster-check.sh --min-solid 4000`, every push and PR | Does the pinned host still ink text as thickly as it did? |

The last one is aimed squarely at a pin bump. Compiling proves the SDK's API did
not move; it says nothing about what CoreText draws, and no screenshot this repo
can take is able to see the difference — see docs/RENDER_FIDELITY.md. A bump
that thins every glyph in the terminal passes the other three checks.

CI covers **both** build graphs — the default local-terminal graph and the
production Phux provider under `-Dphux-enabled=true`. That matters, because
`-Dphux-enabled` defaults to false, so a plain `zig build test` never compiles
`src/providers/phux` at all and a signature change there goes unverified. The
SDK-head workflow covers both graphs too, and additionally builds the real macOS
executable on each, since `zig build test` compiles the test root rather than
the AppKit binary.

`sdk-head.yml` failing does **not** mean Cockpit is broken. Cockpit's own PRs
stay green, because they still build against the pin. It means the next pin bump
has work attached to it, and names the sha to start bisecting from.

Notification is GitHub's default for scheduled workflows and nothing more: the
account that created the workflow is emailed when a scheduled run fails, and
that moves to whoever last changed the `cron` expression. There is no
issue-filing automation and no chat integration. If that email is not being
read, the check is not doing its job.

## Pre-pin checklist

Run this before pushing a pin bump. It is the same sequence `sdk-head.yml` runs,
so anything it catches, CI would have caught a day later.

**1. See what would move.** `scripts/repoint-sdk.sh` resolves the ref, rewrites
`build.zig.zon` through `zig fetch --save` (which touches only the `.url` and
`.hash` lines, so the dependency's comment block survives), and reports whether
the fork is ahead of the pin.

```sh
./scripts/repoint-sdk.sh --dry-run
```

**2. Move the pin.** `auto` takes the newest `cockpit/v*` branch on the fork; a
branch name or full sha is also accepted.

```sh
./scripts/repoint-sdk.sh --ref auto
./scripts/repoint-sdk.sh --ref cockpit/v0.8.4
./scripts/repoint-sdk.sh --ref f3678832fd282b81241993d0c08105cd5170f39f
```

**3. Test BOTH graphs.** Running only the first proves nothing about the
provider, because `-Dphux-enabled` defaults to false.

```sh
zig build test -Dplatform=null --summary all

zig build test -Dplatform=null -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir="$PWD/../phux/crates/phux-client-ffi/include" \
  -Dphux-client-ffi-lib-dir="$PWD/../phux/target/ffi-release" \
  --summary all
```

`zig build test` prints a line reading `failed command: .../test --listen=-` on
a completely green run. It is not a failure. Judge the exit code and nothing
else:

```sh
zig build test -Dplatform=null > /tmp/t.log 2>&1; echo "exit=$?"
```

**4. Build the executable on both graphs.** The tests compile the test root, not
the AppKit binary, and the platform layer is where an SDK signature change
lands.

```sh
zig build --summary all

zig build -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir="$PWD/../phux/crates/phux-client-ffi/include" \
  -Dphux-client-ffi-lib-dir="$PWD/../phux/target/ffi-release" \
  --summary all
```

**5. Update the documentation, and prove it.** Rewrite the pin paragraph under
[Requirements](../README.md#requirements) to the new sha, then:

```sh
./scripts/check-sdk-pin.sh
```

**6. Describe the change, not the sha.** The `.zon` comment above `.native_sdk`
is this fork's changelog — it is where a future reader learns why the pin is
where it is. Say what the new commits change for Cockpit.

## The direction this repo cannot check

The break originates in the fork, so the fork is where it should be caught: a
job on `phall1/native`'s cockpit branches that checks out Cockpit and builds it.
That job does not exist and cannot be added from here.

Half of it is already in place. `sdk-head.yml` accepts a `workflow_dispatch`
input naming any ref, so the fork's CI can ask Cockpit to build against the
exact sha it is pushing, with a token holding `actions: write` on this repo:

```sh
gh workflow run sdk-head.yml \
  --repo phall1/phux-cockpit \
  --field ref="$GITHUB_SHA"
```

Until that exists, the daily run is the backstop, and it is a day late.
