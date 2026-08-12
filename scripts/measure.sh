#!/usr/bin/env bash
# One entry point to everything in this repo that measures something.
#
#   ./scripts/measure.sh                       # what can be measured
#   ./scripts/measure.sh host-raster-check     # run one, passing its own flags
#   ./scripts/measure.sh automate-smoke --profile
#
# WHY AN ENTRY POINT AT ALL
# -------------------------
# Because the alternative is what happened on 2026-08-11 and 2026-08-12: two
# constants were guessed and both guesses were wrong, in a repo that already
# owned a harness capable of deriving them. phux-cockpit-wah's search slice
# sizes were set on intuition at 64 and 256; measurement put one engine tick at
# ~285 rows, which makes 64 finish a 4000-row search inline - the exact stall
# the change existed to remove. Nobody was hiding the harness. It was one of
# nine scripts with no index, and the cheapest thing to do was guess.
#
# A measurement nobody can find is not available, whatever its file permissions
# say.
#
# HOW THE LIST STAYS TRUE
# -----------------------
# There is no table here. Each measurement script carries a `# measures:` line
# in its own header, and this script greps for it. A hand-maintained index is
# the failure scripts/check-sdk-pin.sh exists to catch - README claimed one SDK
# pin while build.zig.zon shipped another for days - and an index of
# measurements would rot the same way, faster, because it changes more often.
#
# What this deliberately does NOT do is wrap the scripts. Every one keeps its
# own flags, its own output and its own exit code, and running it directly is
# still correct. This is a directory, not a driver: a driver would become a
# second place for behaviour to live, and the whole reason this bead exists is
# that behaviour lived in nine places at once.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Every runnable measurement, as `name<TAB>description`. Sorted by name so the
# listing order does not depend on the filesystem.
runnable() {
    local path name tag
    for path in "${ROOT}"/scripts/*.sh; do
        tag="$(sed -n 's/^# measures: //p' "${path}" | head -1)"
        [[ -n "${tag}" ]] || continue
        name="$(basename -- "${path}" .sh)"
        printf '%s\t%s\n' "${name}" "${tag}"
    done | sort
}

list() {
    local name tag path
    printf 'MEASUREMENTS\n\n'
    while IFS=$'\t' read -r name tag; do
        path="${ROOT}/scripts/${name}.sh"
        # A listed measurement that cannot be run is worse than an unlisted
        # one: it is an invitation to a dead end. Say so here rather than at
        # the exec.
        printf '  %-22s %s\n' "${name}" "${tag}"
        [[ -x "${path}" ]] || printf '  %-22s NOT EXECUTABLE: %s\n' '' "${path}"
    done < <(runnable)

    # The Objective-C instruments are compiled by the wrappers above, except
    # where they are not. Listing them separately is honest about which
    # measurements still have no runner, instead of leaving that discoverable
    # only by reading nine file headers - which is the state this entry point
    # exists to end.
    local m base
    printf '\nINSTRUMENTS (compiled by a wrapper above, or by hand from their header)\n\n'
    for m in "${ROOT}"/scripts/*.m; do
        base="$(basename -- "${m}")"
        if grep -qF "${base}" "${ROOT}"/scripts/*.sh 2>/dev/null; then
            printf '  %-30s compiled by a wrapper\n' "${base}"
        else
            printf '  %-30s NO WRAPPER: build it from the comment at the top\n' "${base}"
        fi
    done

    printf '\nRun one with:  ./scripts/measure.sh <name> [its own flags]\n'
    printf 'Each script keeps its own flags; --help on any of them is authoritative.\n'
    printf 'What makes a number here trustworthy: docs/MEASUREMENT.md\n'
}

case "${1:-}" in
    ''|list|-l|--list) list; exit 0 ;;
    -h|--help) sed -n '2,8p' "$0"; printf '\n'; list; exit 0 ;;
esac

name="$1"; shift
target="${ROOT}/scripts/${name}.sh"
if ! runnable | cut -f1 | grep -qx -- "${name}"; then
    printf 'error: no measurement named %s\n\n' "${name}" >&2
    list >&2
    exit 2
fi
exec "${target}" "$@"
