#!/usr/bin/env bash
# Drive the LIVE app's Retina (2x) render path on a 1x panel, and measure the
# real pixels it uploads to the Metal texture.
#
#   ./scripts/drive-backing-scale.sh              # unforced control, then 2
#   ./scripts/drive-backing-scale.sh 1.5 2 3      # ...then a scale sweep
#   ./scripts/drive-backing-scale.sh --keep 2     # leave the dumps in place
#
# The unforced control run always happens first and is not optional: see the
# negative-control note on `run_scale`.
#
# WHY THIS EXISTS
# ---------------
# phux-cockpit-aht spent five rounds on "I can't see the text" and every
# measurement in all five ran at gpu_scale=1, because this machine has no
# Retina panel and `native automate resize`'s scale argument does not touch
# the backing scale. The owner is on Retina. So the entire 2x path - a 2x
# drawable, a 2x raster cache, CoreText at scale 2, a 4x-larger upload - had
# never been executed even once, and "we could not reproduce it" meant "we
# could not reproduce it on the wrong path".
#
# THIS MACHINE CANNOT BE MADE RETINA. Measured, not assumed: the only display
# is a 1920x1080 PM1561P reporting backingScaleFactor 1.00, and all 31 of its
# CoreGraphics modes - enumerated WITH kCGDisplayShowDuplicateLowResolutionModes,
# which is the option that reveals hidden HiDPI modes - have pixel dimensions
# equal to their point dimensions. There is no 2x mode to switch to. Enabling
# one would need `defaults write /Library/Preferences/com.apple.windowserver
# DisplayResolutionEnabled -bool true` (root, plus a logout), and even that
# only ever exposes HiDPI modes the panel can drive.
#
# WHAT IT DOES INSTEAD, AND WHERE THE SEAM IS
# -------------------------------------------
# `NativeSdkMetalSurfaceView.updateDrawableSize` is the ONE place the host
# learns the device scale. Everything downstream reads the value that lands in
# that local: `metalLayer.contentsScale`, `metalLayer.drawableSize`, the
# GPU_SURFACE_RESIZE event the runtime stores as `gpu_scale_factor` (and
# publishes as `gpu_scale`), and therefore the `scale` argument every packet
# present is drawn at. docs/sdk-patches/scale-probe.patch overrides that one
# local from an environment variable, so the app runs the whole 2x path.
#
# BE HONEST ABOUT WHAT IS SIMULATED. Forcing the scale reproduces every line
# of code a Retina window would run, at the same pixel dimensions, with the
# same CoreText rasterization. It does NOT reproduce the display server's 2x
# scanout - the 2x layer is downsampled on its way to a 1x panel. That does
# not affect these numbers, because they are read from the bytes handed to
# the texture upload, upstream of scanout. It does mean a defect that lives
# only in scanout (subpixel layout, panel gamma) is still out of reach here.
#
# THE PATCH IS A DIAGNOSTIC BUILD, NOT A SHIPPING ONE. It is applied to a
# scratch worktree of the pinned SDK; build.zig.zon is repointed at that
# worktree for the build and restored on exit, always, including on failure.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PIN_CACHE="${PHUX_COCKPIT_SDK_CACHE:-${ROOT}/.zig-cache/pinned-sdk}"
PROBE="${ROOT}/.zig-cache/sdk-scale-probe"
WORK="${TMPDIR:-/tmp}/phux-cockpit-scale.$$"
KEEP=0

SCALES=()
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=1 ;;
        -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
        -*) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
        *) SCALES+=("$arg") ;;
    esac
done
[[ ${#SCALES[@]} -gt 0 ]] || SCALES=(2)

# Rule 7 of this bead's hard-won rules: live-app automation is serial-only,
# because activation is global and name-based. Refuse rather than interleave.
if pgrep -x phux-cockpit >/dev/null 2>&1; then
    printf 'REFUSING: a phux-cockpit is already running. Automation is serial-only.\n' >&2
    exit 1
fi

if [[ ! -d "${PIN_CACHE}/.git" ]]; then
    printf 'error: no pinned SDK checkout at %s\n' "$PIN_CACHE" >&2
    printf '       run ./scripts/build-automation-cli.sh first\n' >&2
    exit 1
fi

# The automation CLI must come from the PIN, not from the probe: a CLI and an
# app that disagree on the protocol fingerprint refuse each other. The probe
# touches only appkit_host.m, so the fingerprint is unchanged and the pinned
# CLI drives the probe build - which is itself a check that the patch stayed
# out of the protocol surface.
NATIVE="$("${ROOT}/scripts/build-automation-cli.sh")"

pinned_sha="$(git -C "$PIN_CACHE" rev-parse HEAD)"

restore_zon() { git -C "$ROOT" checkout -- build.zig.zon 2>/dev/null || true; }
# APP_PID is set by run_scale and cleared when it reaps its own app. The trap
# reads it because a failing assertion aborts run_scale before its own kill,
# and a leaked instance poisons every later run: automation is serial-only,
# so the next launch would either refuse or - worse - attach to the corpse.
APP_PID=""
cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
    restore_zon
    [[ "$KEEP" == "1" ]] || rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

mkdir -p "$WORK"

printf 'preparing the probe SDK at %s\n' "${pinned_sha:0:9}"
if [[ ! -d "${PROBE}/.git" && ! -f "${PROBE}/.git" ]]; then
    git -C "$PIN_CACHE" worktree add --quiet --detach "$PROBE" "$pinned_sha"
fi
git -C "$PROBE" checkout --quiet --detach "$pinned_sha"
git -C "$PROBE" reset --hard --quiet "$pinned_sha"
git -C "$PROBE" apply "${ROOT}/docs/sdk-patches/scale-probe.patch"

# Repoint at the probe for the build only. `.path` deps must be relative to
# the build root, which is why the probe lives under .zig-cache.
python3 - "$ROOT" <<'PY'
import re, sys, pathlib
zon = pathlib.Path(sys.argv[1], "build.zig.zon")
text = zon.read_text()
patched = re.sub(
    r'\.native_sdk = \.\{\n\s*\.url = "[^"]*",\n\s*\.hash = "[^"]*",\n\s*\},',
    '.native_sdk = .{\n            .path = ".zig-cache/sdk-scale-probe",\n        },',
    text, count=1)
if patched == text:
    sys.exit("could not repoint .native_sdk in build.zig.zon")
zon.write_text(patched)
PY

printf 'building the probe app\n'
( cd "$ROOT" && zig build package -Dautomation=true >"${WORK}/build.log" 2>&1 ) || {
    printf 'the probe build failed; see %s\n' "${WORK}/build.log" >&2
    exit 1
}
restore_zon

INK="${WORK}/measure-png-ink"
clang -w -o "$INK" "${ROOT}/scripts/measure-png-ink.m" \
    -framework Foundation -framework CoreGraphics -framework ImageIO

# A pane that repaints one fixed row set forever, so every dumped frame at
# every scale carries the same glyphs and the ink numbers compare.
cat >"${WORK}/repaint.sh" <<'REPAINT'
#!/bin/sh
i=0
while :; do
    printf '\033[H\033[2J'
    n=0
    while [ "$n" -lt 40 ]; do
        printf 'row %03d  frame %06d  the quick brown fox jumps over the lazy dog\n' "$n" "$i"
        n=$((n + 1))
    done
    i=$((i + 1))
    sleep 0.2
done
REPAINT
chmod +x "${WORK}/repaint.sh"
printf 'command = /bin/sh %s\nfont-size = 13\n' "${WORK}/repaint.sh" >"${WORK}/config"

# The measured window, in POINTS. Multiplied by the scale to reach device
# pixels, so both sides of any comparison read the SAME glyphs. Derived, not
# guessed: run with --keep, then read the ink of candidate rectangles out of a
# kept dump until one lands wholly inside the first pane's text and clear of
# the tab strip -
#   clang -w -o /tmp/ink scripts/measure-png-ink.m -framework Foundation \
#       -framework CoreGraphics -framework ImageIO
#   /tmp/ink <work>/dump-control-1/packet-*-1100x640.png 20 80 380 60
# A rectangle that clips the tab strip or the pane edge would put chrome ink
# in one column of the table and not the other.
RECT_X=20
RECT_Y=80
RECT_W=380
RECT_H=60

printf '\nforced gpu_scale  gpu_size    px          mean_luma  solid    solid_frac  lit_frac\n'

run_scale() {
    local scale="$1" expect_control="$2"
    local dump="${WORK}/dump-${expect_control}-${scale}"
    local row_label="$scale"
    [[ "$expect_control" == "control" ]] && row_label="none"
    mkdir -p "$dump"
    rm -f "${WORK}/workspace.state"

    local -a env_args=(
        "PHUX_COCKPIT_CONFIG=${WORK}/config"
        "PHUX_COCKPIT_STATE=${WORK}/workspace.state"
        "NATIVE_SDK_PACKET_DUMP_DIR=${dump}"
        "NATIVE_SDK_PACKET_DUMP_LIMIT=8"
    )
    # The control run passes NO override, so the app reports the panel's real
    # scale. That is the absent half of the assertion below: it proves
    # `gpu_scale=2` can be false here, so seeing it later means the override
    # moved the path rather than the pattern having always matched.
    [[ "$expect_control" == "control" ]] || env_args+=("NATIVE_SDK_FORCE_BACKING_SCALE=${scale}")

    env "${env_args[@]}" \
        "${ROOT}/zig-out/package/phux-cockpit.app/Contents/MacOS/phux-cockpit" \
        >"${WORK}/app-${scale}.log" 2>&1 &
    APP_PID=$!
    local app_pid="$APP_PID"

    "$NATIVE" automate wait >/dev/null

    local snap publisher
    snap="$("$NATIVE" automate snapshot)"
    publisher="$(printf '%s' "$snap" | grep -o 'publisher_pid=[0-9]*' | head -1 | cut -d= -f2)"
    if [[ "$publisher" != "$app_pid" ]]; then
        kill "$app_pid" 2>/dev/null || true
        printf 'REFUSING: publisher_pid=%s is not the pid this script launched (%s).\n' \
            "$publisher" "$app_pid" >&2
        return 1
    fi

    local reported size
    reported="$(printf '%s' "$snap" | grep -o 'gpu_scale=[0-9.]*' | head -1 | cut -d= -f2)"
    size="$(printf '%s' "$snap" | grep -o 'gpu_size=[0-9]*x[0-9]*' | head -1 | cut -d= -f2)"

    if [[ "$expect_control" == "control" ]]; then
        # The negative control: without the override the app must NOT report
        # the scale the forced runs will report.
        if [[ "$reported" != "1" ]]; then
            kill "$app_pid" 2>/dev/null || true
            printf 'NEGATIVE CONTROL FAILED: the panel already reports gpu_scale=%s.\n' "$reported" >&2
            printf 'Then this machine is not the 1x machine this script assumes, and the\n' >&2
            printf 'forced runs prove nothing. Re-derive the control.\n' >&2
            return 1
        fi
    elif [[ "$reported" != "$scale" ]]; then
        kill "$app_pid" 2>/dev/null || true
        printf 'FAILED: forced scale %s but the app reports gpu_scale=%s.\n' "$scale" "$reported" >&2
        return 1
    fi

    # Frames must actually be reaching the packet path, or the dump below is
    # measuring the CPU fallback instead of the real rasterizer.
    "$NATIVE" automate assert 'gpu_present_path=packet' 'gpu_status=ready' 'dispatch_errors=0' >/dev/null
    sleep 3
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    APP_PID=""

    local png
    png="$(ls -1 "$dump"/*.png 2>/dev/null | tail -1 || true)"
    if [[ -z "$png" ]]; then
        printf 'FAILED: no packet dump at scale %s; the probe patch did not take.\n' "$scale" >&2
        return 1
    fi

    local rx ry rw rh
    rx="$(python3 -c "print(round($RECT_X * $reported))")"
    ry="$(python3 -c "print(round($RECT_Y * $reported))")"
    rw="$(python3 -c "print(round($RECT_W * $reported))")"
    rh="$(python3 -c "print(round($RECT_H * $reported))")"

    local ink mean solid pixels
    ink="$("$INK" "$png" "$rx" "$ry" "$rw" "$rh")"
    mean="$(printf '%s' "$ink" | grep -o 'mean_luma=[0-9.]*' | cut -d= -f2)"
    solid="$(printf '%s' "$ink" | grep -o 'solid=[0-9]*' | cut -d= -f2)"
    local lit
    lit="$(printf '%s' "$ink" | grep -o 'lit=[0-9]*' | cut -d= -f2)"
    pixels="$(printf '%s' "$ink" | grep -o 'pixels=[0-9]*' | cut -d= -f2)"

    printf '%-6s %-10s %-11s %-11s %-10s %-8s %-11s %s\n' \
        "$row_label" "$reported" "$size" "$(basename "$png" | sed -E 's/.*-([0-9]+x[0-9]+)\.png/\1/')" \
        "$mean" "$solid" \
        "$(python3 -c "print(f'{100*$solid/$pixels:.2f}%')")" \
        "$(python3 -c "print(f'{100*$lit/$pixels:.2f}%')")"
}

run_scale 1 control
for scale in "${SCALES[@]}"; do
    run_scale "$scale" forced
done

printf '\nsolid_frac and lit_frac are per-pixel FRACTIONS of the same point-space\n'
printf 'rectangle, so they compare across scales; raw solid counts do not.\n'
[[ "$KEEP" == "1" ]] && printf 'dumps kept in %s\n' "$WORK"
exit 0
