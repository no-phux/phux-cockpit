#!/usr/bin/env bash
# Evidence for scripts/lib/app-instance.sh: drive every refusal the guard can
# issue, and prove each one can also PASS.
#
#   ./scripts/instance-guard-check.sh              # decisions + live app
#   ./scripts/instance-guard-check.sh --unit-only  # decisions only, no app
#
# WHY BOTH DIRECTIONS FOR EVERY CASE
# ----------------------------------
# A guard is trivially "correct" if it refuses everything, and that failure
# mode is invisible in a suite that only feeds it bad input - the run is green,
# every refusal fired, and the guard is useless. So every case here is a PAIR:
# the input that must be refused, and the neighbouring input that must be
# accepted. If the accepting half ever stops accepting, the refusing half stops
# being evidence of anything. This is the same rule automate-smoke.sh applies
# with `expect_change` and for the same reason (phux-cockpit-2ml.5).
#
# The decision half runs anywhere and needs no app: app_instance_check_* take
# their inputs as arguments precisely so the corpse transcript from
# phux-cockpit-2ml.10 can be replayed without reproducing the race that
# produced it. The live half launches real bundles and is macOS-only.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib/app-instance.sh"

UNIT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --unit-only) UNIT_ONLY=1 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

FAILURES=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# The guard must ACCEPT this input.
expect_accept() {
    local what="$1"; shift
    if "$@" 2>/dev/null; then pass "accepts: $what"; else fail "accepts: $what (it refused)"; fi
}

# The guard must REFUSE this input, and say something about it on stderr. A
# silent non-zero is not a refusal anyone can act on - the whole complaint in
# phux-cockpit-2ml.10 is that the failures were silent.
expect_refuse() {
    local what="$1"; shift
    local err rc
    err="$("$@" 2>&1 >/dev/null)"; rc=$?
    if [[ $rc -eq 0 ]]; then
        fail "refuses: $what (it accepted)"
    elif [[ -z "$err" ]]; then
        fail "refuses: $what (non-zero but silent)"
    else
        pass "refuses: $what"
    fi
}

# ---------------------------------------------------------------------------
# Fixtures, copied from a real `native automate snapshot` against this app on
# 2026-08-12 and trimmed to the fields the guard reads. The gpu_surface line is
# ~4KB in reality; what matters here is that it carries `kind=... role=...`.
# ---------------------------------------------------------------------------
HEADER='ready=true protocol=0x59d66f39803fd602 frame=2 commands=0 runtime_uptime_ns=178799000 dispatch_errors=0 dropped_trace_records=0 publisher_pid=%s markup_watch=off'
WINDOW='window @w1 "Phux Cockpit" bounds=(410,307 1100x640) focused=false frame=2 commands=0'
VIEW='  view @w1/phux-cockpit-canvas kind=gpu_surface role="Phux Cockpit canvas" accessibility_label="Phux Cockpit" text="Phux Cockpit canvas" bounds=(0,0 1100x640) visible=true gpu_present_path=packet'

healthy_snapshot() { printf "${HEADER}\n%s\n%s\n" "$1" "$WINDOW" "$VIEW"; }
# THE CORPSE (phux-cockpit-2ml.10): a `ready=true` header and nothing under it.
# The app had logged event=stop and window_closed; the dropbox still answered.
# shellcheck disable=SC2059 # HEADER is intentionally the fixture's format
corpse_snapshot()  { printf "${HEADER}\n" "$1"; }

printf 'decisions (no app required)\n'

# 1. Pre-launch exclusivity.
expect_accept 'no instance live before launch'      app_instance_check_free
expect_refuse 'one instance already live'           app_instance_check_free 4242
expect_refuse 'several instances already live'      app_instance_check_free 4242 4243

# 2. Sole-instance binding. This is the check that catches the name-based
#    activation hazard: two live pids means System Events would front an
#    arbitrary one.
expect_accept 'exactly our pid is live'             app_instance_check_only 4242 4242
expect_refuse 'our pid plus a stranger'             app_instance_check_only 4242 4242 4243
expect_refuse 'a stranger instead of our pid'       app_instance_check_only 4242 4243
expect_refuse 'nothing live at all'                 app_instance_check_only 4242

# 3. Snapshot binding and the empty-tree corpse.
expect_accept 'snapshot published by our pid'       app_instance_check_snapshot 4242 "$(healthy_snapshot 4242)"
expect_refuse 'snapshot published by another pid'   app_instance_check_snapshot 4242 "$(healthy_snapshot 4243)"
expect_refuse 'empty output, no publisher_pid'      app_instance_check_snapshot 4242 ''
expect_refuse 'ready header, zero widgets (corpse)' app_instance_check_snapshot 4242 "$(corpse_snapshot 4242)"

# 4. Activation actually took. osascript exits 0 either way, so the only
#    evidence is the frontmost pid read back afterwards.
expect_accept 'our pid is frontmost'                app_instance_check_frontmost 4242 4242
expect_refuse 'another app is frontmost'            app_instance_check_frontmost 4242 4243
expect_refuse 'System Events named no frontmost'    app_instance_check_frontmost 4242 ''

# 5. Forced stop. A child that ignores SIGTERM deterministically takes the
# timeout/SIGKILL branch; app_instance_stop must still wait it out and reap it.
# Watched red with the final wait removed: kill -0 still saw the zombie.
STOP_WORK="$(mktemp -d)"
bash -c 'trap "" TERM; printf ready >"$1"; while :; do :; done' \
    bash "${STOP_WORK}/ready" &
STOP_PID=$!
for _ in $(seq 1 100); do [[ -f "${STOP_WORK}/ready" ]] && break; sleep 0.01; done
if [[ ! -f "${STOP_WORK}/ready" ]]; then
    fail 'TERM-resistant stop fixture became ready'
    kill -9 "$STOP_PID" 2>/dev/null || true
    wait "$STOP_PID" 2>/dev/null || true
elif app_instance_stop "$STOP_PID" 0 2>"${STOP_WORK}/stop.err"; then
    if kill -0 "$STOP_PID" 2>/dev/null; then
        fail 'forced SIGKILL stop returned with child still present'
    elif grep -q 'sending SIGKILL' "${STOP_WORK}/stop.err"; then
        pass 'forced SIGKILL stop waits and reaps before return'
    else
        fail 'forced stop did not exercise the SIGKILL timeout branch'
    fi
else
    fail 'forced SIGKILL stop returned non-zero'
fi
rm -rf "$STOP_WORK"

if [[ "$UNIT_ONLY" == "1" ]]; then
    printf '\n%s\n' "$([[ $FAILURES -eq 0 ]] && echo 'guard decisions: ok' || echo "guard decisions: ${FAILURES} FAILED")"
    exit $(( FAILURES > 0 ))
fi

# ---------------------------------------------------------------------------
# Live app. Launches real bundles, so it is serial-only itself.
# ---------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || { printf '\nlive: skipped (macOS only)\n'; exit $(( FAILURES > 0 )); }

APP="${ROOT}/zig-out/package/phux-cockpit.app/Contents/MacOS/phux-cockpit"
if [[ ! -x "$APP" ]]; then
    printf '\nerror: no automation bundle at %s\n' "$APP" >&2
    printf '       run: zig build package -Dautomation=true\n' >&2
    exit 1
fi
NATIVE="$("${ROOT}/scripts/build-automation-cli.sh")"
WORK="${TMPDIR:-/tmp}/phux-cockpit-guardcheck.$$"
mkdir -p "$WORK"
printf 'font-size = 13\n' >"${WORK}/config"

PIDS=()
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    local p
    for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Sets LAUNCHED rather than printing the pid: `pid="$(launch a)"` would run the
# whole function in a SUBSHELL, so `PIDS+=` would update a copy and the cleanup
# trap would kill nothing. An earlier version of this script did exactly that
# and leaked a live bundle into the next run - manufacturing the two-instance
# condition it exists to detect.
LAUNCHED=""
launch() {
    PHUX_COCKPIT_CONFIG="${WORK}/config" \
    PHUX_COCKPIT_STATE="${WORK}/workspace-$1.state" \
        "$APP" >"${WORK}/app-$1.log" 2>&1 &
    LAUNCHED=$!
    PIDS+=("$LAUNCHED")
}

printf '\nlive: one instance\n'
app_instance_require_free || { printf 'cannot run the live half: something is already running\n' >&2; exit 1; }
launch a; one="$LAUNCHED"
"$NATIVE" automate wait >/dev/null

# The binding must hold with exactly one instance up. This is the ACCEPTING
# half of the live pair - without it, the refusal below proves nothing.
if app_instance_bind "$NATIVE" "$one"; then pass "binds to the sole instance (pid $one)"; else fail 'binds to the sole instance'; fi
if app_instance_snapshot >/dev/null; then pass 'guarded snapshot returns a tree'; else fail 'guarded snapshot returns a tree'; fi

# Activation must never SILENTLY fail. It is allowed to succeed, and it is
# allowed to refuse - what it may not do is report success while some other app
# stays in front, which is what a bare `osascript ... set frontmost` does (see
# the measurements in app-instance.sh above app_instance_check_frontmost).
#
# Both outcomes are correct here, so the assertion is on the AGREEMENT between
# the return code and the machine, not on the return code alone. That keeps
# this test meaningful on a machine that can activate and on one that cannot.
if app_instance_activate 10; then
    if [[ "$(app_instance_frontmost_pid)" == "$one" ]]; then
        pass "activation by unix id fronted pid $one, and said so"
    else
        fail 'activation returned success while another app is frontmost'
    fi
else
    if [[ "$(app_instance_frontmost_pid)" != "$one" ]]; then
        pass 'activation refused loudly rather than reporting a no-op as success'
    else
        fail 'activation refused although our pid IS frontmost'
    fi
fi

printf '\nlive: two instances\n'
launch b; two="$LAUNCHED"
# Wait for the second process to actually exist before asserting on the count,
# or this races the fork and tests nothing.
for _ in $(seq 1 30); do [[ "$(app_instance_pids | wc -l | tr -d ' ')" -ge 2 ]] && break; sleep 0.5; done
printf '  live pids: %s\n' "$(app_instance_pids | tr '\n' ' ')"

expect_refuse 'a second run may not start while one is live' app_instance_require_free
expect_refuse 'the bound run refuses once a sibling appears'  app_instance_assert

kill "$two" 2>/dev/null || true
for _ in $(seq 1 30); do [[ "$(app_instance_pids | wc -l | tr -d ' ')" -le 1 ]] && break; sleep 0.5; done

printf '\nlive: back to one instance\n'
expect_accept 'the bound run resumes once the sibling is gone' app_instance_assert

printf '\n'
if [[ $FAILURES -eq 0 ]]; then
    printf 'instance guard: ok\n'
else
    printf 'instance guard: %d FAILED\n' "$FAILURES"
fi
exit $(( FAILURES > 0 ))
