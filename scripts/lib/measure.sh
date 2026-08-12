# shellcheck shell=bash
#
# The shared parts of the measurement scripts. Source it, do not run it:
#
#   ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
#   . "${ROOT}/scripts/lib/measure.sh"
#
# WHY THIS FILE EXISTS
# --------------------
# scripts/ grew a measurement harness one script at a time, and each new script
# copied the parts it needed out of the last one. By 2026-08-12 the same four
# things existed in four places: resolving the SDK pin out of build.zig.zon,
# launching an isolated bundle, proving the bundle answering us is the one we
# launched, and the absent-then-present assertion.
#
# That is not a tidiness complaint. phux-cockpit-yo5 is a real bug in the pin
# resolution, and three scripts each carried their own copy of the defect, so
# fixing it in the one that was noticed would have left the other two wrong.
# A shared implementation is the only shape in which "fixed" means fixed
# everywhere.
#
# WHAT BELONGS HERE
# -----------------
# Only the parts where two scripts disagreeing would be a correctness problem:
# the pin resolution, the assertion shapes with negative controls, the
# refusals. Formatting, prose and each script's own measurement stay in the
# script, where a reader looking for them will be.

# Sourcing this twice (a script that sources it and calls another that does)
# must be harmless.
[[ -n "${MEASURE_LIB_SOURCED:-}" ]] && return 0
MEASURE_LIB_SOURCED=1

# Resolved from this file's own location rather than from the caller's, so a
# script invoked through a symlink or from any working directory still finds
# the repo. Callers keep their own ROOT; this is the library's.
MEASURE_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MEASURE_ROOT="$(CDPATH='' cd -- "${MEASURE_LIB_DIR}/../.." && pwd)"

# ------------------------------------------------------------------ the pin

# Where the pinned SDK is cloned. One default, so a script that resolves the
# pin and a script that reads the checkout cannot disagree about which
# directory they mean.
measure_sdk_cache() {
    printf '%s\n' "${PHUX_COCKPIT_SDK_CACHE:-${MEASURE_ROOT}/.zig-cache/pinned-sdk}"
}

# Print one dependency's archive URL from build.zig.zon, or refuse by name.
#
# THE BUG THIS REPLACES (phux-cockpit-yo5). Three scripts scanned with
#
#   awk '/\.native_sdk = \.\{/ { found = 1 } found && /\.url = / { print; exit }'
#
# which sets a latch and then takes the first `.url` ANYWHERE after it. While
# the dependency is a local `.path` override — which is exactly what anyone
# validating an SDK patch uses, see docs/sdk-patches/ — the native_sdk block
# has no `.url`, so the scan walked on into the NEXT dependency and returned
# ghostty's tarball. Nothing failed: build-automation-cli.sh went on to fetch
# ghostty's sha into the SDK clone and build a CLI from it.
#
# So the scan is block-scoped (the latch clears at the block's closing `},`),
# comment lines are skipped so prose containing `.url = ` cannot be read as a
# pin, and a block with no URL is a named refusal rather than a fall-through.
measure_zon_dependency_url() {
    local name="$1" zon="${2:-${MEASURE_ROOT}/build.zig.zon}"
    local block url

    block="$(awk -v name="${name}" '
        # Skip comments before anything else: the dependency blocks in this
        # .zon carry long prose comments, and one of them mentions a url.
        /^[[:space:]]*\/\// { next }
        $0 ~ "\\." name " = \\.\\{" { inside = 1; next }
        inside && /^[[:space:]]*\},[[:space:]]*$/ { inside = 0; exit }
        inside { print }
    ' "${zon}")"

    if [[ -z "${block}" ]]; then
        printf 'error: %s has no .%s dependency block\n' "${zon}" "${name}" >&2
        return 1
    fi

    url="$(printf '%s\n' "${block}" | awk '
        /\.url = "/ { match($0, /"[^"]+"/); print substr($0, RSTART + 1, RLENGTH - 2); exit }
    ')"

    if [[ -z "${url}" ]]; then
        if printf '%s\n' "${block}" | grep -q '\.path = "'; then
            local path
            path="$(printf '%s\n' "${block}" | sed -nE 's/.*\.path = "([^"]*)".*/\1/p' | head -1)"
            printf 'error: .%s is a local .path override (%s), so it has no pinned url.\n' \
                "${name}" "${path}" >&2
            printf '       Refusing to guess. Nothing here can resolve a pin that does not exist;\n' >&2
            printf '       point the caller at an already-built artifact instead (for the automation\n' >&2
            printf '       CLI that is NATIVE=<path to native>, see docs/sdk-patches/).\n' >&2
        else
            printf 'error: .%s in %s has neither a .url nor a .path\n' "${name}" "${zon}" >&2
        fi
        return 1
    fi

    printf '%s\n' "${url}"
}

# The full commit sha the given dependency is pinned to, validated. A short or
# absent sha is refused here rather than being passed to git, which would
# resolve it to something plausible and wrong.
measure_zon_dependency_sha() {
    local name="$1" zon="${2:-${MEASURE_ROOT}/build.zig.zon}" url sha
    url="$(measure_zon_dependency_url "${name}" "${zon}")" || return 1
    # https://github.com/<owner>/<repo>/archive/<sha>.tar.gz
    sha="$(printf '%s' "${url}" | sed -E 's#.*/archive/([0-9a-f]+)\.tar\.gz$#\1#')"
    if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
        printf 'error: the .%s url does not pin a full commit sha: %s\n' "${name}" "${url}" >&2
        return 1
    fi
    printf '%s\n' "${sha}"
}

# The git remote behind that archive URL.
measure_zon_dependency_repo() {
    local name="$1" zon="${2:-${MEASURE_ROOT}/build.zig.zon}" url
    url="$(measure_zon_dependency_url "${name}" "${zon}")" || return 1
    printf '%s.git\n' "$(printf '%s' "${url}" | sed -E 's#^(https://github.com/[^/]+/[^/]+)/archive/.*#\1#')"
}

# Resolve the SDK source to measure into MEASURE_SDK_SRC, refusing any checkout
# that is not at the pinned commit, and report which it chose.
#
# A rasterizer measured from a checkout at some other commit describes a
# rasterizer the app does not ship, and it does so in numbers that look exactly
# like the real ones. PHUX_COCKPIT_SDK_SRC overrides deliberately (that is how
# host-raster-compare.sh points this at a worktree of an older commit), and the
# report says so, so an override cannot pass unnoticed into a transcript.
#
# The path lands in a variable rather than on stdout because the report line is
# already on stdout and callers pipe it.
measure_require_pinned_sdk() {
    local cache sha have
    if [[ -n "${PHUX_COCKPIT_SDK_SRC:-}" ]]; then
        MEASURE_SDK_SRC="${PHUX_COCKPIT_SDK_SRC}"
        printf 'sdk: %s (PHUX_COCKPIT_SDK_SRC override - NOT the pin)\n' "${MEASURE_SDK_SRC}"
        return 0
    fi
    cache="$(measure_sdk_cache)"
    if [[ ! -d "${cache}/.git" ]]; then
        printf 'error: no pinned SDK checkout at %s\n' "${cache}" >&2
        printf '       run ./scripts/build-automation-cli.sh first, or set PHUX_COCKPIT_SDK_SRC\n' >&2
        return 1
    fi
    sha="$(measure_zon_dependency_sha native_sdk)" || return 1
    have="$(git -C "${cache}" rev-parse HEAD)"
    if [[ "${have}" != "${sha}" ]]; then
        printf 'error: %s is at %s, but build.zig.zon pins %s\n' \
            "${cache}" "${have:0:9}" "${sha:0:9}" >&2
        printf '       run ./scripts/build-automation-cli.sh to re-checkout the pin\n' >&2
        return 1
    fi
    MEASURE_SDK_SRC="${cache}"
    printf 'sdk: %s at %s (pinned)\n' "${cache}" "${have:0:9}"
}

# ------------------------------------------------- assertions with controls

# Assert a pattern is ABSENT, run the action, then assert it is PRESENT.
#
# The absent half is the negative control, and it is the whole point. It proves
# this assertion can tell the two states apart, so a later PRESENT result means
# the action worked rather than meaning the pattern was already there.
#
# On 2026-08-12 this repo published a confident finding that automation input
# was broken. It was not. The assertion "proving" it counted `role=textbox
# name="Terminal`, which only ever matches the SELECTED tab's rendered pane, so
# `cmd+t` creating a second TAB could not move it however perfectly the key was
# delivered. An assertion never seen to distinguish the two states is not
# evidence; it manufactures findings. See phux-cockpit-2ml.5.
#
# Requires NATIVE to name the automation CLI.
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

# Refuse to start while another bundle is running.
#
# The automation dropbox is per-USER, not per-process: a second bundle takes
# over the channel, and every assertion afterwards is about someone else's
# binary while reading like a clean transcript. phux-cockpit-2ml.10.
#
# `pgrep -f` would match the command line of the shell running this check and
# report a hit every single time. `-x` matches the executable name, which
# cannot self-match.
measure_require_serial_automation() {
    if pgrep -x phux-cockpit >/dev/null 2>&1; then
        printf 'REFUSING TO RUN: a phux-cockpit is already running.\n' >&2
        printf 'Automation is serial-only; a second bundle steals the dropbox.\n' >&2
        return 1
    fi
}

# Assert that the process publishing the dropbox is the pid we launched.
#
# The serial check above is a start-time check; this is the one that holds
# during the run. Without it a sibling agent's bundle can answer every
# assertion in the script and produce a spotless transcript about a binary
# nobody in this run built.
measure_require_publisher() {
    local pid="$1" publisher
    publisher="$("$NATIVE" automate snapshot | grep -o 'publisher_pid=[0-9]*' | head -1 | cut -d= -f2)"
    if [[ "${publisher}" != "${pid}" ]]; then
        printf 'REFUSING TO ASSERT: the dropbox publisher is %s, not the pid we launched (%s).\n' \
            "${publisher:-<none>}" "${pid}" >&2
        return 1
    fi
    printf 'publisher_pid: %s (ours)\n' "${pid}"
}

# ------------------------------------------------------------- sample floor

# Refuse to report a statistic computed over too few samples.
#
# Generalised out of automate-smoke.sh, where it was written for host_draw
# samples after phux-cockpit-jw4: the first profiling run waited on `assert
# 'present_n=[0-9]'`, which matches `present_n=0` on the first poll and returns
# instantly. An always-true wait. Every host-side stage was then reported as 0,
# and the numbers were about an app that had not drawn anything yet.
#
# Below roughly a hundred samples a p90 is one or two events wide and moves
# with any scheduling hiccup, so this refuses rather than annotating: a number
# printed with a caveat gets copied into an issue without the caveat.
measure_require_sample_floor() {
    local label="$1" count="$2" floor="$3" why="${4:-}"
    count="${count:-0}"
    if [[ ! "${count}" =~ ^[0-9]+$ ]]; then
        printf 'REFUSING TO REPORT: %s sample count is %s, not a number.\n' "${label}" "${count:-<none>}" >&2
        return 1
    fi
    if (( count < floor )); then
        printf 'REFUSING TO REPORT: %s has %s samples, below the floor of %s.\n' \
            "${label}" "${count}" "${floor}" >&2
        [[ -n "${why}" ]] && printf '%s\n' "${why}" >&2
        printf 'A percentile over that few samples is not a percentile. See phux-cockpit-jw4.\n' >&2
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------- record

# Print the basis of the numbers a script is about to emit, in one line a
# reader can act on a month later.
#
#   MEASURED-BASIS <name> host=<machine> when=<utc> basis="<what was held fixed>" derive="<command>"
#
# WHY. phux-cockpit-aht's recorded conclusion carried an invalid comparison for
# days: an ALPHA measurement set against a LUMINANCE measurement, yielding a
# +61% that justified a change actually worth -0.3%. Both numbers were real.
# Neither recorded what it was a number OF, so nothing about the pair looked
# wrong until the harness was re-run. A number without its basis and its
# deriving command is not a measurement, it is a memory.
#
# This is deliberately a printed line and not a stored file. See
# docs/MEASUREMENT.md for why a checked-in baseline was rejected.
measure_basis() {
    local name="$1" basis="$2" derive="$3"
    printf 'MEASURED-BASIS %s host=%s when=%s basis="%s" derive="%s"\n' \
        "${name}" "$(uname -m)-$(sw_vers -productVersion 2>/dev/null || printf 'unknown')" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${basis}" "${derive}"
}

# ------------------------------------------------------------ isolated runs

# Package the app with automation and launch it against an ISOLATED config and
# state file, so a measurement can never write the user's own workspace state
# or read their font size. Sets MEASURE_APP_PID.
#
# The caller owns the config file (each script needs a different pane command)
# and owns the cleanup trap, because what to do with the process on exit is a
# per-script decision (--keep).
measure_launch_isolated() {
    local config="$1" state="$2" logfile="$3"
    printf 'packaging with automation...\n'
    ( cd "${MEASURE_ROOT}" && zig build package -Dautomation=true >/dev/null )
    PHUX_COCKPIT_CONFIG="${config}" \
    PHUX_COCKPIT_STATE="${state}" \
        "${MEASURE_ROOT}/zig-out/package/phux-cockpit.app/Contents/MacOS/phux-cockpit" \
        >"${logfile}" 2>&1 &
    MEASURE_APP_PID=$!
}
