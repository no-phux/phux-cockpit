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
#   ./scripts/build-automation-cli.sh --checkout-only     # just the SDK source
#
# Then, from the app's working directory, with the app running under
# `zig build -Dautomation=true`:
#
#   "$NATIVE" automate wait
#   "$NATIVE" automate assert 'gpu_nonblank=true' 'role=tab'
#   "$NATIVE" automate screenshot phux-cockpit-canvas
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${PHUX_COCKPIT_SDK_CACHE:-${ROOT}/.zig-cache/pinned-sdk}"
EXPORT_ONLY=0
# Resolving the pin and building the CLI are separable, and CI wants only the
# first half: scripts/host-raster-check.sh #includes the host's appkit_host.m
# and compiles that translation unit itself, so a full SDK build would be
# minutes spent producing a binary the rasterizer check never runs. Keeping
# both halves in this script is what keeps the pin read in one place.
CHECKOUT_ONLY=0
case "${1:-}" in
    --export) EXPORT_ONLY=1 ;;
    --checkout-only) CHECKOUT_ONLY=1 ;;
esac

log() { [[ "${EXPORT_ONLY}" == "1" ]] || printf '%s\n' "$*" >&2; }

# The pin is read from build.zig.zon rather than restated here, so this script
# cannot drift from what the app actually links against.
# shellcheck source=scripts/lib/zon.sh
source "${ROOT}/scripts/lib/zon.sh"
# This read once had no block scoping at all: under a local `.path` override it
# returned GHOSTTY's url, and this script then cloned ghostty (578 MB) into the
# SDK cache and failed later with "no step named 'cli'". See phux-cockpit-yo5.
read_status=0
url="$(zon_dependency_url "${ROOT}/build.zig.zon" native_sdk)" || read_status=$?
if [[ "${read_status}" -eq 3 ]]; then
    printf 'error: .native_sdk is a local override (.path), so there is no tarball to fetch.\n' >&2
    printf 'Build the CLI from your override directly, or restore a published pin.\n' >&2
    exit 1
fi
if [[ "${read_status}" -ne 0 || -z "${url}" ]]; then
    printf 'error: could not read the .native_sdk url from build.zig.zon\n' >&2
    exit 1
fi

# https://github.com/<owner>/<repo>/archive/<sha>.tar.gz
repo="$(printf '%s' "${url}" | sed -E 's#^(https://github.com/[^/]+/[^/]+)/archive/.*#\1#').git"
sha="$(printf '%s' "${url}" | sed -E 's#.*/archive/([0-9a-f]+)\.tar\.gz$#\1#')"
if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    printf 'error: the .native_sdk url does not pin a full commit sha: %s\n' "${url}" >&2
    exit 1
fi

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

if [[ "${CHECKOUT_ONLY}" == "1" ]]; then
    printf '%s\n' "${CACHE}"
    exit 0
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
