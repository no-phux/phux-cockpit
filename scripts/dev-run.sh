#!/usr/bin/env bash
# Build this checkout and run it, as a real app, in a way that cannot be
# confused with the Phux Cockpit in /Applications.
#
#   ./scripts/dev-run.sh
#
# That is the whole command. Everything below is optional.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-12 it surfaced that three days of rendering bug reports had been
# filed against /Applications/Phux Cockpit.app -- version 0.7.1, built
# 2026-08-09 -- while `main` was 0.8.0. Nothing merged in those three days had
# ever been in front of the person reporting the bugs. Both apps are called
# "Phux Cockpit", both put the same icon in the same Dock, and until now the
# only local run was a bare binary out of `zig-out/bin` that shared the
# installed app's bundle identity, its process name, and its state file. There
# was no cheap way to be SURE which one you were looking at, so the expensive
# way -- three days -- happened instead.
#
# This command makes the answer obvious: the dev build's Dock tile and
# application menu read "Phux Cockpit (dev)", its process is `phux-cockpit-dev`
# rather than `phux-cockpit`, and its config, workspace layout and automation
# dropbox live under `.dev-run/` in this repo. Run both at once if you like;
# nothing they own is shared. scripts/lib/dev-app.sh explains the four separate
# mechanisms that takes, and `./scripts/dev-isolation-check.sh` drives both apps
# at once and proves it.
#
# OPTIONS
#   --debug              Debug build instead of ReleaseSafe. Faster to compile,
#                        but it is NOT what ships: scripts/package-macos.sh
#                        builds ReleaseSafe, so timing-shaped questions (frame
#                        pacing, input latency) need the default.
#   --automation         Build with -Dautomation=true and print how to drive it.
#   --config PATH        Use this config file instead of .dev-run/config. The
#                        app WRITES to whatever file it is given (a theme choice
#                        from the settings surface), so naming your real config
#                        here means a dev build can edit it.
#   --fresh              Delete the dev home first: config, workspace layout,
#                        dropbox. A clean first-launch.
#   --detach             Print the pid and exit instead of staying attached.
#   --no-build           Run what is already staged. Skips zig entirely.
#   --phux               -Dphux-enabled=true, with the FFI directories the build
#                        already knows how to find.
#
# The foreground run is the default because it makes quitting unambiguous:
# ctrl-c here ends the app, and closing the app ends this script. A dev build
# you forgot was running is a dev build that will confuse the next launch.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "${ROOT}/scripts/lib/dev-app.sh"

DEV_HOME="${PHUX_COCKPIT_DEV_HOME:-${ROOT}/.dev-run}"
STAGED_APP="${ROOT}/zig-out/dev/Phux Cockpit (dev).app"
OPTIMIZE="ReleaseSafe"
AUTOMATION=0
CONFIG=""
FRESH=0
DETACH=0
BUILD=1
PHUX=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) OPTIMIZE="Debug" ;;
        --automation) AUTOMATION=1 ;;
        --config) CONFIG="${2:?--config needs a path}"; shift ;;
        --fresh) FRESH=1 ;;
        --detach) DETACH=1 ;;
        --no-build) BUILD=0 ;;
        --phux) PHUX=1 ;;
        -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ "$(uname -s)" == "Darwin" ]] || { printf 'error: macOS only\n' >&2; exit 1; }

if [[ "$FRESH" == "1" ]]; then
    rm -rf -- "$DEV_HOME"
    printf 'fresh: removed %s\n' "$DEV_HOME"
fi
dev_app_home_init "$DEV_HOME"
CONFIG="${CONFIG:-${DEV_HOME}/config}"

if [[ "$BUILD" == "1" ]]; then
    build_args=(build package "-Doptimize=${OPTIMIZE}")
    [[ "$AUTOMATION" == "1" ]] && build_args+=(-Dautomation=true)
    [[ "$PHUX" == "1" ]] && build_args+=(-Dphux-enabled=true)
    printf 'building: zig %s\n' "${build_args[*]}"
    # A cold ReleaseSafe package build measured 1m41s on this machine, and an
    # unchanged rebuild 1.9s (`time zig build package -Doptimize=ReleaseSafe`,
    # 2026-08-12, M-series). The build is not the friction this command exists
    # to remove, so it is not worth defaulting to a Debug binary to avoid it.
    ( cd "$ROOT" && zig "${build_args[@]}" )
fi

EXECUTABLE="$(dev_app_stage "${ROOT}/zig-out/package/phux-cockpit.app" "$STAGED_APP")"

read -r staged_id staged_executable staged_name <<<"$(dev_app_identity "$STAGED_APP")"
printf '\n'
printf 'running:  %s\n' "$STAGED_APP"
printf '  build:      %s%s\n' "$OPTIMIZE" "$([[ "$AUTOMATION" == "1" ]] && printf ', automation' || true)"
printf '  bundle id:  %s\n' "$staged_id"
printf '  process:    %s      (pgrep -x %s)\n' "$staged_executable" "$staged_executable"
printf '  menu name:  %s\n' "$staged_name"
printf '  config:     %s\n' "$CONFIG"
printf '  state:      %s/workspace.state\n' "$DEV_HOME"
if [[ -d "$DEV_APP_INSTALLED_BUNDLE" ]]; then
    read -r installed_id installed_executable _ <<<"$(dev_app_identity "$DEV_APP_INSTALLED_BUNDLE")"
    printf '  not:        %s (%s, %s, v%s)\n' \
        "$DEV_APP_INSTALLED_BUNDLE" "$installed_id" "$installed_executable" \
        "$(dev_app_plist_value "$DEV_APP_INSTALLED_BUNDLE" CFBundleShortVersionString)"
fi
printf '\n'

LOG="${DEV_HOME}/app.log"
dev_app_launch "$EXECUTABLE" "$DEV_HOME" "$CONFIG" "$LOG"
printf 'pid %s, log %s\n' "$DEV_APP_PID" "$LOG"

cleanup() {
    [[ "$DETACH" == "1" ]] && return 0
    kill "$DEV_APP_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Fail here rather than leaving a half-started app: if the name does not resolve
# to exactly this pid, every later `pgrep -x` and every System Events activation
# in this session is already ambiguous.
dev_app_wait_named "$staged_executable" "$DEV_APP_PID"

# Front it by name. This is the activation phux-cockpit-2ml.10 records as
# unreliable-by-name with two instances up -- which is exactly what the renamed
# executable fixes: "phux-cockpit-dev" cannot resolve to the installed app.
#
# Retried, because the process exists (pgrep sees it) several seconds before
# System Events does, and a single attempt right after launch fails on a
# perfectly healthy app -- it reported "needs Accessibility permission" on a
# machine that had the grant. Failure after the deadline is still not fatal: a
# machine without the grant cannot be activated this way at all, and the app is
# already running.
front_deadline=$((SECONDS + 15))
until osascript -e "tell application \"System Events\" to set frontmost of process \"${staged_executable}\" to true" >/dev/null 2>&1; do
    if [[ "$SECONDS" -ge "$front_deadline" ]]; then
        printf 'note: could not front the window in 15s (System Events may need an Accessibility grant)\n'
        break
    fi
    sleep 0.5
done

if [[ "$AUTOMATION" == "1" ]]; then
    printf '\nautomation is on. The dropbox is resolved against the app CWD, which\n'
    printf 'is the dev home, so drive it from there:\n\n'
    printf '  eval "$(%s/scripts/build-automation-cli.sh --export)"\n' "$ROOT"
    printf '  (cd %s && "$NATIVE" automate wait && "$NATIVE" automate assert '"'"'ready=true'"'"')\n\n' "$DEV_HOME"
fi

if [[ "$DETACH" == "1" ]]; then
    printf 'detached. kill %s to stop it.\n' "$DEV_APP_PID"
    exit 0
fi

printf 'attached. ctrl-c to quit.\n'
status=0
wait "$DEV_APP_PID" || status=$?
printf 'app exited (status %s). log: %s\n' "$status" "$LOG"
exit "$status"
