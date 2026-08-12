#!/usr/bin/env bash
# Did an SDK change actually move the glyph pixels? Two numbers, one basis.
#
#   ./scripts/host-raster-compare.sh <ref-before> [ref-after]
#
# `ref-before` and `ref-after` are commits of the pinned SDK fork. `ref-after`
# defaults to the commit build.zig.zon pins, so the common call is
#
#   ./scripts/host-raster-compare.sh e8bd84886      # shipped-then vs pinned-now
#
# WHY THIS EXISTS
# ---------------
# scripts/host-raster-check.sh measures ONE rasterizer. That is enough to catch
# a regression against a pinned floor, and not enough to answer the question
# that actually matters when a render fix is proposed: does the shipping build
# change?
#
# phux-cockpit-aht is the worked example, and it cost four rounds. The SDK was
# missing `CGContextSetShouldSmoothFonts`. Someone added it, measured the fixed
# SDK against a copy with the calls set explicitly to `false`, saw solid
# 4179 vs 3081 - a real 26.3% - and shipped it as the faint-text fix.
#
# But no build was ever in the `false` state. The state before the fix was the
# calls being ABSENT, and absent is not false: on this CGBitmapContext the
# default is smoothing ENABLED. Measured against the commit the shipping app
# was actually built from, the fix moves nothing:
#
#   e8bd84886 (no calls, shipped)   cell_grid solid=4179  mean_luma=45.7978
#   f3678832f (calls = true, pin)   cell_grid solid=4179  mean_luma=45.7978
#   f3678832f with calls = false    cell_grid solid=3081  mean_luma=37.1124
#
# The control was synthetic. A synthetic control can only tell you the knob is
# wired up; it cannot tell you the knob was ever in the other position. This
# script compares two REAL commits, so the before side is a state that shipped.
# measures: host rasterizer ink at two SDK commits that both shipped, on one basis
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib/measure.sh"

PIN_CACHE="$(measure_sdk_cache)"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    sed -n '2,10p' "$0"
    exit 2
fi

if [[ ! -d "${PIN_CACHE}/.git" ]]; then
    printf 'error: no pinned SDK checkout at %s\n' "$PIN_CACHE" >&2
    printf '       run ./scripts/build-automation-cli.sh first\n' >&2
    exit 1
fi

pinned_sha="$(measure_zon_dependency_sha native_sdk)"

BEFORE="$1"
AFTER="${2:-$pinned_sha}"

WORK="$(mktemp -d)"
cleanup() {
    for ref in "$BEFORE" "$AFTER"; do
        git -C "$PIN_CACHE" worktree remove --force "${WORK}/${ref}" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

measure() {
    local ref="$1" label="$2"
    # Fetch on demand: the checkout was cloned at the pin, so an older commit
    # is usually not present.
    git -C "$PIN_CACHE" cat-file -e "${ref}^{commit}" 2>/dev/null || \
        git -C "$PIN_CACHE" fetch --quiet origin "$ref"
    git -C "$PIN_CACHE" worktree add --quiet --detach "${WORK}/${ref}" "$ref"
    printf '\n--- %s (%s) ---\n' "$label" "${ref:0:9}"
    PHUX_COCKPIT_SDK_SRC="${WORK}/${ref}" "${ROOT}/scripts/host-raster-check.sh" | grep -v '^sdk'
}

measure "$BEFORE" before
measure "$AFTER" after

printf '\nRead the two cell_grid lines against each other. Equal numbers mean the\n'
printf 'change did not move a single glyph pixel, whatever its diff says.\n'
