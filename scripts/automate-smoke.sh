#!/usr/bin/env bash
# Drive the real app through the SDK's automation harness and assert on what
# actually changes. This is the repeatable version of a session that was
# otherwise twenty manual steps.
#
#   ./scripts/automate-smoke.sh                 # structure + driven interaction
#   ./scripts/automate-smoke.sh --profile       # ...and a 4-pane frame profile
#   ./scripts/automate-smoke.sh --keep          # leave the app running to poke at
#
# It builds the CLI from the PINNED SDK (see build-automation-cli.sh — the
# automation dropbox is fingerprint-guarded, and a CLI from anywhere else will
# refuse this app), packages a bundle with -Dautomation=true, launches it with
# an ISOLATED config and state file so it cannot touch the user's own, waits
# for readiness, and drives it.
#
# WHY EVERY ASSERTION HERE HAS A NEGATIVE CONTROL
# ------------------------------------------------
# `expect_change` asserts the pattern is ABSENT, performs the action, then
# asserts it is PRESENT. The absent half is not ceremony — it is the only
# thing standing between this script and the failure that produced it.
#
# On 2026-08-12 an earlier version of this file carried a confident warning
# that automation input was silently broken. It was not. The assertion used to
# "prove" it counted `role=textbox name="Terminal`, which only ever matches the
# SELECTED tab's rendered pane — so `cmd+t` creating a second TAB could not
# move it, no matter how perfectly the key was delivered. The harness was
# telling the truth; the assertion could not fail for the right reason, and so
# it manufactured a finding. See phux-cockpit-2ml.5.
#
# An assertion never seen to distinguish the two states is not evidence.
# If you add one here, give it its before-half too.
#
# Verified observables for this app (2026-08-12, against the real bundle):
#   new tab            role=tab name="Terminal N
#   rendered pane      role=textbox name="Terminal        (SELECTED tab only)
#   scrollback search  role=group name="Scrollback search
# measures: structure and driven interaction of the real bundle; with --profile, host frame stages
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib/measure.sh"

WORK="${TMPDIR:-/tmp}/phux-cockpit-smoke.$$"
PROFILE=0
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --profile) PROFILE=1 ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

# The automation dropbox is per-user, not per-process, so a second bundle takes
# over the channel and every assertion below would be about someone else's
# binary. drive-shell-ceiling.sh has refused this since phux-cockpit-2ml.10;
# this script had the same exposure and no check, which is precisely the kind of
# gap a per-script copy of the harness produces.
measure_require_serial_automation

mkdir -p "$WORK"
APP_PID=""
cleanup() {
    if [[ -n "$APP_PID" && "$KEEP" == "0" ]]; then
        kill "$APP_PID" 2>/dev/null || true
    fi
    [[ "$KEEP" == "1" ]] || rm -rf "$WORK"
}
trap cleanup EXIT

NATIVE="$("${ROOT}/scripts/build-automation-cli.sh")"
printf 'cli: %s\n' "$NATIVE"

# A pane that repaints continuously, so the profile describes something closer
# to a live TUI than an idle prompt. Uses the `command` config key, which is
# why that key existing is load-bearing here and not just a nicety.
cat >"${WORK}/repaint.sh" <<'REPAINT'
#!/bin/sh
i=0
while :; do
    printf '\033[H\033[2J'
    n=0
    while [ "$n" -lt 45 ]; do
        printf 'row %03d  frame %06d  %s\n' "$n" "$i" 'the quick brown fox jumps over the lazy dog'
        n=$((n + 1))
    done
    i=$((i + 1))
done
REPAINT
chmod +x "${WORK}/repaint.sh"
printf 'command = /bin/sh %s\nfont-size = 13\n' "${WORK}/repaint.sh" >"${WORK}/config"

measure_launch_isolated "${WORK}/config" "${WORK}/workspace.state" "${WORK}/app.log"
APP_PID="${MEASURE_APP_PID}"

"$NATIVE" automate wait >/dev/null

# The instance under test must be the instance we launched. Without this a
# sibling agent's bundle answers everything below and the transcript is
# spotless and about the wrong binary.
measure_require_publisher "$APP_PID"

# `expect_change` comes from scripts/lib/measure.sh: assert ABSENT, act, assert
# PRESENT. Its negative control is why this script's findings are believable;
# the reasoning is in the library beside the code.

# Structural assertions. These read published runtime state.
"$NATIVE" automate assert \
    'ready=true' \
    'window @w1' \
    'kind=gpu_surface' \
    'role=textbox name="Terminal 1' \
    'dispatch_errors=0'
# The terminal must reach glass through the PACKET path, where the AppKit host
# rasterizes with CoreText. A fallback to `pixels` silently moves every glyph
# onto the CPU reference renderer - the app then looks like its own
# screenshots, which is exactly the failure no screenshot can report. See
# docs/RENDER_FIDELITY.md.
"$NATIVE" automate assert 'gpu_present_path=packet'
"$NATIVE" automate assert --absent 'error event='
printf 'structure: ok\n'

printf 'driving interaction...\n'
expect_change 'cmd+t opens a second tab' 'role=tab name="Terminal 2' \
    "$NATIVE" automate widget-key phux-cockpit-canvas cmd+t
expect_change 'cmd+f opens scrollback search' 'role=group name="Scrollback search' \
    "$NATIVE" automate widget-key phux-cockpit-canvas cmd+f
"$NATIVE" automate widget-key phux-cockpit-canvas escape >/dev/null
"$NATIVE" automate assert --timeout-ms 5000 --absent 'role=group name="Scrollback search' >/dev/null
printf '  ok: escape closes scrollback search\n'

if [[ "$PROFILE" == "1" ]]; then
    # jw4's recorded condition is FOUR panes under interaction, not an idle
    # prompt. Split to four before reading anything, or the percentiles
    # describe a near-idle app and mean nothing.
    printf 'building the 4-pane condition...\n'
    "$NATIVE" automate widget-key phux-cockpit-canvas cmd+d >/dev/null
    "$NATIVE" automate widget-key phux-cockpit-canvas cmd+shift+d >/dev/null
    "$NATIVE" automate widget-key phux-cockpit-canvas cmd+d >/dev/null
    panes="$("$NATIVE" automate snapshot | grep -c 'role=textbox name="Terminal' || true)"
    printf '  panes in the selected tab: %s\n' "$panes"
    if [[ "$panes" -lt 4 ]]; then
        printf 'REFUSING TO PROFILE: wanted 4 panes, got %s. Numbers from the\n' "$panes" >&2
        printf 'wrong condition are worse than no numbers. See phux-cockpit-jw4.\n' >&2
        exit 1
    fi

    "$NATIVE" automate profile on >/dev/null

    # Wait for ENOUGH samples, not for the counter to exist. `assert
    # 'present_n=[0-9]'` matches `present_n=0` on the first poll and returns
    # instantly — an always-true wait, the same defect this script's negative
    # controls exist to prevent, and it is how the first profiling run
    # reported every host-side stage as 0.
    #
    # 200 presents is ~3.3s of a 60Hz surface (200 / 60). Below ~100 samples a
    # p90 is one or two frames wide and moves with any scheduling hiccup.
    min_samples=200
    deadline=$((SECONDS + 60))
    while :; do
        drawn="$("$NATIVE" automate snapshot | grep -o 'host_draw_n=[0-9]*' | head -1 | cut -d= -f2)"
        drawn="${drawn:-0}"
        [[ "$drawn" -ge "$min_samples" ]] && break
        if [[ "$SECONDS" -ge "$deadline" ]]; then
            # The refusal itself lives in the library so every measurement in
            # scripts/ refuses on the same rule rather than on whichever floor
            # its author happened to think of.
            measure_require_sample_floor 'host_draw' "$drawn" "$min_samples" \
                'It had 60s of four continuously repainting panes to produce them.' || exit 1
            break
        fi
        sleep 1
    done
    printf '  host_draw samples: %s\n' "$drawn"

    printf '\n--- frame profile (4 panes, continuous repaint) ---\n'
    measure_basis frame_profile \
        "4 panes, 45-row full-screen repaint loop, font-size 13, ${drawn} host_draw samples" \
        './scripts/automate-smoke.sh --profile'
    "$NATIVE" automate snapshot | grep -o 'frame_profile.*' | tr ' ' '\n' | grep -E '_p50_us=|_p90_us=|_n=' || true
    printf '\nNOTE: check the _n= counts before believing any percentile. A stage\n'
    printf 'with a handful of samples describes a near-idle app, not load.\n'
fi

printf '\nsmoke: ok\n'
