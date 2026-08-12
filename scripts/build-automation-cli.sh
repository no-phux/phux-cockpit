#!/usr/bin/env bash
# Build the `native` automation CLI from the SDK this app is PINNED to.
#
# The npm-installed `@native-sdk/cli` cannot drive Cockpit, and no version of
# it ever will. The automation dropbox is guarded by a protocol fingerprint
# hashed over the protocol surface plus a `semantic_epoch`, and this app's SDK
# pin — a fork carrying Cockpit's terminal seams — bumps that epoch. A CLI and
# an app that do not share one fingerprint refuse each other loudly rather than
# reading each other's state, which is the correct behaviour and is why this
# script exists instead of a version bump.
#
# Usage:
#   ./scripts/build-automation-cli.sh            # build, print the binary path
#   eval "$(./scripts/build-automation-cli.sh --export)"   # ...and set NATIVE
#
# Then, from the app's working directory, with the app running under
# `zig build -Dautomation=true`:
#
#   "$NATIVE" automate wait
#   "$NATIVE" automate assert 'gpu_nonblank=true' 'role=tab'
#   "$NATIVE" automate screenshot phux-cockpit-canvas
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib/measure.sh"

CACHE="$(measure_sdk_cache)"
EXPORT_ONLY=0
[[ "${1:-}" == "--export" ]] && EXPORT_ONLY=1

log() { [[ "${EXPORT_ONLY}" == "1" ]] || printf '%s\n' "$*" >&2; }

# The pin is read from build.zig.zon rather than restated here, so this script
# cannot drift from what the app actually links against. The reader lives in
# scripts/lib/measure.sh because this script's own copy of it was
# phux-cockpit-yo5: under a local `.path` override it fell through to the NEXT
# dependency and fetched ghostty's sha into the SDK clone, silently.
repo="$(measure_zon_dependency_repo native_sdk)"
sha="$(measure_zon_dependency_sha native_sdk)"

if [[ ! -d "${CACHE}/.git" ]]; then
    log "cloning ${repo}"
    mkdir -p "$(dirname -- "${CACHE}")"
    git clone --quiet --filter=blob:none "${repo}" "${CACHE}"
fi

if ! git -C "${CACHE}" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    log "fetching ${sha:0:9}"
    git -C "${CACHE}" fetch --quiet origin "${sha}"
fi

current="$(git -C "${CACHE}" rev-parse HEAD 2>/dev/null || true)"
if [[ "${current}" != "${sha}" ]]; then
    log "checking out ${sha:0:9}"
    git -C "${CACHE}" checkout --quiet --detach "${sha}"
fi

log "building the CLI (this is a full SDK build the first time)"
( cd "${CACHE}" && zig build cli )

binary="${CACHE}/zig-out/bin/native"
if [[ ! -x "${binary}" ]]; then
    printf 'error: the CLI build produced no binary at %s\n' "${binary}" >&2
    exit 1
fi

if [[ "${EXPORT_ONLY}" == "1" ]]; then
    printf 'export NATIVE=%q\n' "${binary}"
else
    log ""
    log "$("${binary}" version)"
    log "the app's fingerprint must match the one above; a mismatch names both."
    printf '%s\n' "${binary}"
fi
