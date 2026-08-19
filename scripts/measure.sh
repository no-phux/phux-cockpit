#!/usr/bin/env bash
# Catalog and dispatcher for first-class Cockpit measurements.
#
#   ./scripts/measure.sh
#   ./scripts/measure.sh automate-smoke --churn
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

measurements() {
    local path name description
    for path in "$ROOT"/scripts/*.sh; do
        description="$(sed -n 's/^# measures: //p' "$path" | head -1)"
        [[ -n "$description" ]] || continue
        name="$(basename -- "$path" .sh)"
        printf '%s\t%s\n' "$name" "$description"
    done | sort
}

list() {
    local name description
    printf 'MEASUREMENTS\n\n'
    while IFS=$'\t' read -r name description; do
        printf '  %-24s %s\n' "$name" "$description"
    done < <(measurements)
    printf '\nEvery statistic records MEASURED-BASIS and refuses below its sample floor.\n'
    printf 'See docs/MEASUREMENT.md.\n'
}

case "${1:-}" in
    ''|list|-l|--list) list; exit 0 ;;
    -h|--help) sed -n '2,5p' "$0"; printf '\n'; list; exit 0 ;;
esac

name="$1"
shift
if ! measurements | cut -f1 | grep -qx -- "$name"; then
    printf 'error: no measurement named %s\n\n' "$name" >&2
    list >&2
    exit 2
fi
exec "${ROOT}/scripts/${name}.sh" "$@"
