#!/usr/bin/env bash
# Drive the real app up to N concurrent shells and report where it actually
# stops. This is the repeatable form of phux-cockpit-ipg's evidence: the pty
# ceiling is an SDK constant, so the only honest way to say it moved is to
# open shells in the shipped bundle until one is refused.
#
#   ./scripts/drive-shell-ceiling.sh --want 8      # open 8 terminals, or fail
#   ./scripts/drive-shell-ceiling.sh --want 8 --keep
# measures: concurrent shell ceiling and per-shell process cost
#
# Exit 0 means every one of the N terminals exists AND is running. Exit 1
# names the terminal that did not appear (the ceiling) or the one that
# appeared with a rejected spawn.
#
# WHY EVERY STEP HAS A NEGATIVE CONTROL
# --------------------------------------
# `expect_change` asserts the pattern is ABSENT, performs the action, then
# asserts it is PRESENT. The absent half is not ceremony: an assertion never
# seen to distinguish the two states is not evidence, and this repo has
# already shipped one confident finding built on an assertion that could not
# fail for the right reason (see scripts/automate-smoke.sh and
# phux-cockpit-2ml.5). Here the trap is specific: `role=tab name="Terminal 5`
# is a SUFFIX-open pattern, so it also matches "Terminal 5" inside a longer
# name -- and every tab that already exists would satisfy a sloppier pattern.
#
# WHICH SDK DID THIS BINARY ACTUALLY LINK
# ----------------------------------------
# The shell-limit badge renders `local.max_live_shells`, which is
# `native_sdk.max_effect_ptys` with no literal in between. So the app's own
# published snapshot names the constant that was COMPILED IN, which is the
# only way to tell a patched SDK from an unpatched one without trusting the
# build graph. This script prints it before driving anything.
#
# SERIAL ONLY (phux-cockpit-2ml.10). The automation dropbox is per-user, not
# per-process: a second bundle steals the channel. scripts/lib/app-instance.sh
# refuses to start if one is already running, binds every later read to the pid
# this script launched, and refuses an empty widget tree rather than reporting
# a dead instance as a vanished UI.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib/measure.sh"
WORK="${TMPDIR:-/tmp}/phux-cockpit-ceiling.$$"
WANT=8
KEEP=0
MEASURE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --want) WANT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --measure) MEASURE=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

mkdir -p "$WORK"
APP_PID=""
cleanup() {
    if [[ -n "$APP_PID" && "$KEEP" == "0" ]]; then
        app_instance_stop "$APP_PID"
    fi
    [[ "$KEEP" == "1" ]] || rm -rf "$WORK"
}
trap cleanup EXIT

# An already-built CLI can be handed in, and has to be for the one workflow
# this script exists to serve: `build-automation-cli.sh` reads the SDK pin out
# of `build.zig.zon`, so while that dependency is temporarily a local `.path`
# (which is how an SDK patch is validated — see docs/sdk-patches/) there is no
# url for it to read and it walks off onto the NEXT dependency's url instead.
# The CLI does not need to come from the patched SDK anyway: the automation
# fingerprint hashes the protocol surface and `semantic_epoch`, and a pty
# table size is in neither.
NATIVE="${NATIVE:-$("${ROOT}/scripts/build-automation-cli.sh")}"
printf 'root: %s\n' "$ROOT"
printf 'cli:  %s\n' "$NATIVE"
printf 'cli fingerprint: %s\n' "$("$NATIVE" version)"

# A shell that speaks exactly once and then holds its pty open. The one line
# is load-bearing: a local pane only leaves `.starting` for `.live` when its
# pty delivers OUTPUT (src/cockpit/update.zig, the `.output` arm), so a
# perfectly healthy `/bin/cat` reads as STARTING forever and "RUNNING" could
# never be counted. `exec cat` after it keeps the pty quiet and alive, so N
# of these produce a stable snapshot instead of N racing prompts.
cat >"${WORK}/hold.sh" <<'HOLD'
#!/bin/sh
printf 'shell up\n'
exec cat
HOLD
chmod +x "${WORK}/hold.sh"
printf 'command = /bin/sh %s\nfont-size = 13\n' "${WORK}/hold.sh" >"${WORK}/config"

measure_launch_isolated "$WORK" "${WORK}/config" "${WORK}/app.log"
APP_PID="$MEASURE_APP_PID"

"$NATIVE" automate wait >/dev/null

# The instance under test must be the instance we launched. A sibling agent's
# bundle answering these assertions would produce a perfectly clean transcript
# about someone else's binary. app_instance_bind also refuses an empty widget
# tree, which the old publisher_pid check here could not tell from a healthy
# app that simply had no UI.
app_instance_bind "$NATIVE" "$APP_PID"

# The compiled-in ceiling, read back out of the running binary.
report_ceiling() {
    local limit
    limit="$(app_instance_snapshot \
        | grep -o 'Shell limit reached: [0-9]* running terminals' \
        | head -1 | cut -d' ' -f4 || true)"
    printf 'compiled-in shell ceiling (read out of the running binary): %s\n' \
        "${limit:-<the badge renders only once a spawn is refused>}"
}
report_ceiling

expect_change() {
    local what="$1" pattern="$2"; shift 2
    if ! "$NATIVE" automate assert --absent "$pattern" >/dev/null 2>&1; then
        printf 'NEGATIVE CONTROL FAILED: %s already matches before the action.\n' "$pattern" >&2
        printf 'This assertion cannot prove %s did anything. Fix the assertion.\n' "$what" >&2
        return 1
    fi
    "$@" >/dev/null
    if ! "$NATIVE" automate assert --timeout-ms 5000 "$pattern" >/dev/null; then
        printf 'FAILED: %s did not produce %s\n' "$what" "$pattern" >&2
        return 1
    fi
    printf '  ok: %s\n' "$what"
}

# `role=tab` widgets exist only once there is more than one tab, so the
# single-tab starting state is asserted through the rendered pane instead.
"$NATIVE" automate assert --timeout-ms 10000 \
    'ready=true' 'role=textbox name="Terminal 1, native terminal, RUNNING' 'dispatch_errors=0' >/dev/null
printf 'structure: ok (Terminal 1 RUNNING)\n'

# What one live shell actually costs the process. This is the derivation
# behind the pty ceiling: a table size is only defensible against a measured
# per-shell cost, never against a preference. `ps` reports rss in KiB and
# `lsof` counts open descriptors; both are read from the pid we launched.
measure() {
    [[ "$MEASURE" == "1" ]] || return 0
    local shells="$1" rss threads fds
    if [[ -z "${MEASURE_BASIS_PRINTED:-}" ]]; then
        MEASURE_BASIS_PRINTED=1
        measure_basis shell_cost \
            "quiet /bin/sh + cat per tab; rss, threads, and fds read from pid ${APP_PID}" \
            "./scripts/drive-shell-ceiling.sh --want ${WANT} --measure"
    fi
    rss="$(ps -o rss= -p "$APP_PID" | tr -d ' ')"
    threads="$(ps -M -p "$APP_PID" | tail -n +2 | wc -l | tr -d ' ')"
    fds="$(lsof -p "$APP_PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    printf 'MEASURED shells=%s rss_kib=%s threads=%s fds=%s\n' "$shells" "$rss" "$threads" "$fds"
}
measure 1

printf 'opening %s terminals with cmd+t...\n' "$WANT"
reached=1
for (( n = 2; n <= WANT; n++ )); do
    if expect_change "cmd+t opens Terminal ${n}" "role=tab name=\"Terminal ${n}," \
        "$NATIVE" automate widget-key phux-cockpit-canvas cmd+t; then
        reached="$n"
        measure "$n"
    else
        printf '\nCEILING: stopped at %s live terminals (wanted %s).\n' "$reached" "$WANT" >&2
        # Now that a spawn HAS been refused the badge exists, so the binary can
        # be asked what ceiling it was compiled against rather than inferred.
        report_ceiling >&2
        "$NATIVE" automate snapshot | grep -o 'Terminal [0-9]*, native terminal, [A-Z ]*' >&2 || true
        exit 1
    fi
done

# A tab that exists proves nothing on its own -- phux-cockpit-pg1 was exactly
# a tab that existed with a dead shell behind it. Every one must be RUNNING,
# and no spawn anywhere may have been rejected.
if ! "$NATIVE" automate assert --absent 'SPAWN REJECTED' >/dev/null; then
    printf 'FAILED: a spawn was rejected even though every tab appeared.\n' >&2
    "$NATIVE" automate snapshot | grep -o 'Terminal [0-9]*, native terminal, [A-Z ]*' >&2 || true
    exit 1
fi
# Count the TAB widgets, not the rendered panes: `role=textbox name="Terminal
# N` exists only for the SELECTED tab, so counting panes reports 1 no matter
# how many shells run. Each tab's accessibility name embeds its pane's status
# ("... 1 pane(s); Terminal N, native terminal, RUNNING; ..."), which is the
# only per-shell liveness readout the snapshot publishes for unselected tabs.
#
# READ THIS BEFORE TRUSTING THE NUMBER. The tab strip SCROLLS: it publishes
# only the tabs that fit the window, so this count is bounded by strip width,
# not by live shells. Measured at 16 tabs in a 1100px window: 9 published
# (Terminals 8..16), the first 7 off-strip and invisible to the snapshot
# despite their shells being perfectly alive. Reporting `running` as the shell
# count would be exactly the class of mistake this repo keeps filing bugs
# about — an assertion that answers a question it was never measuring.
#
# So the count is reported against what is PUBLISHED, and the per-tab proof
# is the `expect_change` chain above: each tab was asserted absent, opened,
# and asserted present, one at a time.
published="$(app_instance_snapshot | grep -c 'role=tab ' || true)"
running="$(app_instance_snapshot | grep -c 'role=tab .*native terminal, RUNNING' || true)"
printf '\ntabs opened and individually proven present: %s\n' "$WANT"
printf 'tabs the strip publishes: %s (it scrolls; the rest are off-strip)\n' "$published"
printf 'of those, RUNNING: %s   SPAWN REJECTED: 0\n' "$running"
if [[ "$running" -lt "$published" ]]; then
    printf 'FAILED: the strip publishes %s tabs but only %s are RUNNING.\n' "$published" "$running" >&2
    "$NATIVE" automate snapshot | grep -o 'role=tab name="Terminal [0-9]*, native terminal, [^;]*' >&2 || true
    exit 1
fi
printf 'ceiling drive: ok (%s concurrent shells, %s of them observably RUNNING)\n' "$WANT" "$running"
