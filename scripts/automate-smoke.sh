#!/usr/bin/env bash
# Drive the real app through the SDK's automation harness and report what it
# says. This is the repeatable version of a session that was otherwise twenty
# manual steps.
#
#   ./scripts/automate-smoke.sh                 # snapshot + assertions
#   ./scripts/automate-smoke.sh --profile       # ...and a frame profile under load
#   ./scripts/automate-smoke.sh --keep          # leave the app running to poke at
#
# It builds the CLI from the PINNED SDK (see build-automation-cli.sh — the
# automation dropbox is fingerprint-guarded, and a CLI from anywhere else will
# refuse this app), packages a bundle with -Dautomation=true, launches it with
# an ISOLATED config and state file so it cannot touch the user's own, waits
# for readiness, and asserts.
#
# READ THIS BEFORE TRUSTING AN INPUT RESULT
# -----------------------------------------
# `widget-key`, `widget-click` and `widget-action` all currently report
# "delivered" against this app and DO NOTHING — verified 2026-08-12 across
# cmd+d, cmd+shift+d, cmd+t, a click and an explicit focus action, with
# dispatch_errors=0 and zero focused widgets throughout. Cockpit routes
# keyboard input through its own `handleKey` on the canvas rather than through
# the SDK's widget-focus mechanism, so there is nothing for those verbs to
# route to. Any smoke test that "drives" this app and passes is measuring
# delivery to the dropbox, not behaviour. See phux-cockpit-2ml.5.
#
# Snapshot, assert, screenshot and profile are all trustworthy. Input is not.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/phux-cockpit-smoke.$$"
PROFILE=0
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --profile) PROFILE=1 ;;
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

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

printf 'packaging with automation...\n'
( cd "$ROOT" && zig build package -Dautomation=true >/dev/null )

PHUX_COCKPIT_CONFIG="${WORK}/config" \
PHUX_COCKPIT_STATE="${WORK}/workspace.state" \
    "${ROOT}/zig-out/package/phux-cockpit.app/Contents/MacOS/phux-cockpit" >"${WORK}/app.log" 2>&1 &
APP_PID=$!

"$NATIVE" automate wait >/dev/null
osascript -e 'tell application "Phux Cockpit" to activate' >/dev/null 2>&1 || true

# Structural assertions. These are real: they read published runtime state.
"$NATIVE" automate assert \
    'ready=true' \
    'window @w1' \
    'kind=gpu_surface' \
    'role=textbox name="Terminal 1' \
    'dispatch_errors=0'
"$NATIVE" automate assert --absent 'error event='
printf 'assertions: ok\n'

if [[ "$PROFILE" == "1" ]]; then
    "$NATIVE" automate profile on >/dev/null
    # Let samples accumulate under the repaint load before reading.
    "$NATIVE" automate assert --timeout-ms 20000 'present_n=[0-9]' >/dev/null || true
    printf '\n--- frame profile ---\n'
    "$NATIVE" automate snapshot | grep -o 'frame_profile.*' | tr ' ' '\n' | grep -E '_p50_us=|_p90_us=|_n=' || true
    printf '\nNOTE: check the _n= counts before believing any percentile. A stage\n'
    printf 'with a handful of samples describes a near-idle app, not load.\n'
fi

printf '\nsmoke: ok\n'
