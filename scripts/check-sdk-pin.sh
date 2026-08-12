#!/usr/bin/env bash
# Fail when the SDK/engine pins documented in README.md have drifted from the
# pins build.zig.zon actually resolves. Offline and fast, so it belongs beside
# check-release-version.sh at the top of CI rather than in a build job.
#
# This check exists because the drift already happened: README claimed
# phall1/native@f7347de long after build.zig.zon had moved to f3678832.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZON="${ROOT}/build.zig.zon"
README="${ROOT}/README.md"

# Read one dependency's archive URL out of the .zon. The .zon is not JSON and
# has no offline parser here, so scope the search to the block that opens with
# `.<name> = .{` and read the first `.url` inside it.
dependency_url() {
    local name="$1"
    awk -v name="${name}" '
        $0 ~ "\\." name " = \\.\\{" { inside = 1; next }
        inside && /\.url = "/ {
            match($0, /"[^"]+"/)
            print substr($0, RSTART + 1, RLENGTH - 2)
            exit
        }
        inside && /^[[:space:]]*\},[[:space:]]*$/ { inside = 0 }
    ' "${ZON}"
}

status=0

check_pin() {
    local name="$1" url slug sha
    url="$(dependency_url "${name}")"
    if [[ -z "${url}" ]]; then
        printf 'error: build.zig.zon has no .%s dependency with a .url\n' "${name}" >&2
        status=1
        return
    fi

    # https://github.com/<owner>/<repo>/archive/<sha>.tar.gz
    if [[ ! "${url}" =~ ^https://github\.com/([^/]+/[^/]+)/archive/([0-9a-f]{40})\.tar\.gz$ ]]; then
        printf 'error: .%s url is not a github archive pinned by full commit sha: %s\n' \
            "${name}" "${url}" >&2
        status=1
        return
    fi
    slug="${BASH_REMATCH[1]}"
    sha="${BASH_REMATCH[2]}"

    if ! grep -qF "${sha}" "${README}"; then
        printf 'error: README.md does not document the pinned .%s commit %s (%s)\n' \
            "${name}" "${sha}" "${slug}" >&2
        status=1
        return
    fi

    # A stale short sha next to a fresh long one reads as current to a human,
    # so require every short reference to prefix the pin it claims to describe.
    local short
    while read -r short; do
        [[ -n "${short}" ]] || continue
        if [[ "${sha}" != "${short}"* ]]; then
            printf 'error: README.md references %s@%s but the pin is %s\n' \
                "${slug}" "${short}" "${sha}" >&2
            status=1
        fi
    done < <(grep -Eo "${slug}@[0-9a-f]{7,40}" "${README}" | sed "s|${slug}@||")

    printf 'Pinned %s is %s@%s and README.md agrees.\n' "${name}" "${slug}" "${sha}"
}

check_pin native_sdk
check_pin ghostty

exit "${status}"
