# dsr Release Fallback

## What this is

`dsr` ("doodlestein self-releaser", forked to
[phall1/doodlestein_self_releaser](https://github.com/phall1/doodlestein_self_releaser))
is an operator-invoked CLI tool for working around GitHub Actions billing and
queue throttling. When hosted Actions is backed up or over budget, `dsr`
replays a repo's existing `.github/workflows/release.yml` locally on the
operator's machine, then uploads the resulting artifacts to the GitHub
Release via `gh release upload`.

It is **not** a persistent listener, runner, or CI replacement. It does
nothing until a human runs a `dsr` subcommand. Its job is narrow: get a
release's build artifacts published when hosted Actions can't do it in a
reasonable time.

## Registration lives outside this repo

`dsr` is installed and configured on the operator's Mac already; nothing in
this repo needs to change for it to work. The registration lives at
`~/.config/dsr/repos.d/phux-cockpit.yaml` (machine-local, not part of this
git repo), pointing at this repo's local checkout, `release.yml`, and the
`darwin/arm64` target built natively on that same Mac. This app is
macOS-only per `app.zon`'s `platforms = ["macos"]`, and `act` cannot run
macOS jobs at all, so there is no Linux/`act` leg to configure here — the
native-build path is the only one that exists.

This doc is purely informational and operational. It exists so anyone
reading this repo understands what the fallback path is and what it does and
doesn't cover, without needing to go spelunking in a machine-local config
directory.

## Usage

All commands are manual, run by an operator when `dsr check` (or direct
observation of a stuck Actions run) indicates throttling:

```sh
dsr check no-phux/phux-cockpit
dsr build phux-cockpit --targets darwin/arm64
dsr release phux-cockpit --version vX.Y.Z
dsr fallback phux-cockpit --version vX.Y.Z
```

`dsr check` reports whether GitHub Actions currently looks throttled for
this repo. `dsr build` runs the local replay without publishing. `dsr
release`/`dsr fallback` carry a local build through to uploading assets
against an existing GitHub Release for the given tag.

## The signing caveat — read this before using the fallback for a real release

`release.yml`'s single `macos` job conditionally imports Developer ID
signing secrets (`MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`,
`MACOS_SIGNING_IDENTITY`) and notarization secrets (`APPLE_NOTARY_KEY`,
`APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`). Both groups are declared
`required: false` at the `workflow_call` level, and both are all-or-nothing:
supply zero secrets and the job proceeds with an ad-hoc signed build; supply
a partial set and it hard-fails.

`dsr`'s local config for this repo **deliberately does not configure those
secrets**. This is an explicit decision, not an oversight: `dsr` is
build-only, and replaying `release.yml` locally without those secrets
naturally falls through to the workflow's own existing ad-hoc-signed path —
exactly the behavior the workflow already has for a normal hosted run with
no signing secrets configured.

The practical consequence: **a local `dsr` fallback release produces an
unsigned/ad-hoc build, not the normal Developer-ID-signed-and-notarized
one.** A genuinely signed, notarized release still requires hosted GitHub
Actions, because that's where those secrets live, in GitHub's managed
secret store. `dsr` must never be handed Apple signing or notarization
secrets locally — keeping that material off this Mac's disk and keychain,
outside GitHub's managed secret store, is the point. (This mirrors the
reasoning behind ADR-0084 in the operator's home-ops repo, made for a
different, now-retired self-hosted-runner approach, for the same reason.)

If a real release needs to go out during an outage and Developer ID
signing matters for that release, the fallback is not a substitute for
waiting on or escalating hosted Actions — it's a way to get *an* artifact
published, ad-hoc signed, when that's an acceptable tradeoff.

## The Homebrew tap caveat

`HOMEBREW_TAP_DEPLOY_KEY` is `required: true` at the `workflow_call` level
and gates a later step in `release.yml` that hard-fails if the secret is
unset. `dsr`'s local config does not configure this secret either.

This means a full local replay of `release.yml` via `dsr` will get through
build, asset upload, and ad-hoc-signature verification, but will fail at the
Homebrew-tap-update gate. That failure is expected, not a sign that the
fallback release is broken — the assets are already uploaded by the time it
happens.

If you actually use the fallback to ship a real release, the Homebrew tap
does not get updated automatically. Either:

- run `bash scripts/gen-formula.sh` and push the result to the tap manually
  afterward, or
- accept that the tap stays stale until a real hosted-Actions release runs
  and updates it normally.

State this plainly to whoever consumes the release: a `dsr fallback` run
that stops at the Homebrew gate is a partial success (artifacts are up),
not a failure that needs debugging.
