#!/usr/bin/env bash
# Hermetic tests for measurement policy and launcher composition.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/measure.sh
source "${ROOT}/scripts/lib/measure.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }

check measure_require_sample_floor host_draw 200 200
if measure_require_sample_floor rebuild 199 200 >/dev/null 2>&1; then
    bad 'sample below floor was accepted'
else
    ok
fi
if measure_require_sample_floor rebuild missing 200 >/dev/null 2>&1; then
    bad 'non-numeric sample count was accepted'
else
    ok
fi

good_profile='frame_profile host_draw_n=210 host_draw_p50_us=4 host_draw_p90_us=8 rebuild_n=200 rebuild_p50_us=2 rebuild_p90_us=3'
if output="$(measure_print_frame_profile test basis derive "$good_profile")"; then
    if [[ "$output" == *'MEASURED-BASIS test '* && "$output" == *'rebuild_p90_us=3'* ]]; then
        ok
    else
        bad 'valid profile did not use common output'
    fi
else
    bad 'valid profile was refused'
fi
low_profile='frame_profile host_draw_n=210 host_draw_p50_us=4 host_draw_p90_us=8 rebuild_n=12 rebuild_p50_us=2 rebuild_p90_us=3'
# Watched red with the per-stage output filter disabled: the test printed
# rebuild_p90_us=3 and failed "under-sampled stage percentile ... refused".
if low_output="$(measure_print_frame_profile test basis derive "$low_profile" 2>"${WORK}/low.err")"; then
    if [[ "$low_output" == *'host_draw_p90_us=8'* && "$low_output" != *'rebuild_p90_us=3'* ]] \
        && grep -q 'rebuild has 12 samples' "${WORK}/low.err"; then
        ok
    else
        bad 'under-sampled stage percentile was not independently refused'
    fi
else
    bad 'one low stage hid independently reportable stages'
fi

# Replace only external mechanics. The function under test must still compose
# package -> dev_app_stage -> same-name refusal -> dev_app_launch, and must pin
# the CLI to the launch cwd.
mkdir -p "${WORK}/bin" "${WORK}/home"
printf '#!/bin/sh\nexit 0\n' >"${WORK}/bin/zig"
chmod +x "${WORK}/bin/zig"
PATH="${WORK}/bin:${PATH}"
export PATH
dev_app_stage() {
    printf '%s\n' "$*" >"${WORK}/stage.args"
    printf '%s\n' "${WORK}/home/App.app/Contents/MacOS/phux-cockpit-dev"
}
app_instance_require_free() { printf '%s\n' "$APP_INSTANCE_NAME" >"${WORK}/guard.name"; }
dev_app_launch() {
    printf '%s\n' "$*" >"${WORK}/launch.args"
    DEV_APP_PID=4242
}
NATIVE=/bin/echo
measure_launch_isolated "${WORK}/home" "${WORK}/home/config" "${WORK}/home/app.log"
if [[ "$MEASURE_APP_PID" == 4242 ]]; then ok; else bad 'launcher did not return dev_app pid'; fi
if [[ "$(cat "${WORK}/guard.name")" == phux-cockpit-dev ]]; then ok; else bad 'guard did not use staged process identity'; fi
if grep -q 'Phux Cockpit (measure).app' "${WORK}/stage.args"; then ok; else bad 'launcher did not identity-stage bundle'; fi
if grep -q "${WORK}/home ${WORK}/home/config ${WORK}/home/app.log" "${WORK}/launch.args"; then
    ok
else
    bad 'launcher did not delegate home/config/log to dev_app_launch'
fi
if [[ "$NATIVE" == "${WORK}/home/native-in-measure-home" ]]; then ok; else bad 'automation CLI was not cwd-pinned'; fi
if grep -q 'exec env -C' "$NATIVE"; then ok; else bad 'CLI wrapper does not enter isolated dropbox cwd'; fi

catalog="$("${ROOT}/scripts/measure.sh")"
if [[ "$catalog" == *'automate-smoke'* && "$catalog" == *'host-raster-check'* ]]; then
    ok
else
    bad 'catalog did not discover tagged measurements'
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
