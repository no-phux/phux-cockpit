#!/usr/bin/env bash
# Repoint build.zig.zon's native_sdk dependency at a ref of the SDK fork.
#
# Two callers, one resolution rule:
#   - .github/workflows/sdk-head.yml, so a scheduled build sees the fork's
#     branch head before anyone bumps the pin;
#   - a human bumping the pin, so the sha in build.zig.zon is the one that was
#     actually built rather than one copied out of a browser tab.
#
# `zig fetch --save` rewrites only the .url and .hash lines, so the dependency's
# comment block survives. Verified: the two-line diff is the whole diff.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ZON="${ROOT}/build.zig.zon"
# shellcheck source=scripts/lib/zon.sh
source "${ROOT}/scripts/lib/zon.sh"

# The fork tracks upstream by rebasing onto each release, and names the result
# after the upstream version it sits on: cockpit/v0.8.3, cockpit/v0.8.4, ...
# So the branch to follow is not a constant, and hardcoding one would leave a
# scheduled job passing forever against a frozen branch. `auto` resolves the
# highest such branch every run instead.
BRANCH_GLOB='refs/heads/cockpit/v*'
REF=auto
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: scripts/repoint-sdk.sh [--ref <branch|sha|auto>] [--dry-run]

  --ref auto   Newest cockpit/v* branch on the pinned SDK remote (default)
  --ref <ref>  A branch name or full commit sha on that remote
  --dry-run    Resolve and report, but leave build.zig.zon alone
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref)
            # An empty value means auto: on a schedule event GitHub's `inputs`
            # context is empty, so the workflow can pass it through unguarded.
            REF="${2:-auto}"
            [[ -n "${REF}" ]] || REF=auto
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown argument %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# This read used to have NO block-close rule at all, so `inside` latched on the
# first `.native_sdk = .{` and never cleared: under a local `.path` override it
# answered with GHOSTTY's url. `slug` below is derived from this url and feeds
# `zig fetch --save=native_sdk` at the end — so the script would have pinned
# ghostty AS the SDK, in build.zig.zon, and reported success. This is the most
# dangerous of the five copies of that defect. See scripts/lib/zon.sh and
# phux-cockpit-yo5.
#
# `|| read_status=$?` rather than a bare assignment: `set -e` would otherwise
# kill the script here before the refusal below could say why.
read_status=0
pinned_url="$(zon_dependency_url "${ZON}" native_sdk)" || read_status=$?
if [[ "${read_status}" -eq 3 ]]; then
    printf 'error: .native_sdk is a local override (.path); there is no pin to repoint.\n' >&2
    printf 'Restore a published pin first, or edit build.zig.zon by hand.\n' >&2
    exit 1
fi

if [[ ! "${pinned_url}" =~ ^https://github\.com/([^/]+/[^/]+)/archive/([0-9a-f]{40})\.tar\.gz$ ]]; then
    printf 'error: build.zig.zon native_sdk url is not a sha-pinned github archive: %s\n' \
        "${pinned_url:-<missing>}" >&2
    exit 1
fi
slug="${BASH_REMATCH[1]}"
pinned_sha="${BASH_REMATCH[2]}"
remote="https://github.com/${slug}"

resolved_ref="${REF}"
if [[ "${REF}" == "auto" ]]; then
    # sort -V so cockpit/v0.8.10 sorts above cockpit/v0.8.9 rather than below.
    resolved_ref="$(git ls-remote --heads "${remote}" "${BRANCH_GLOB}" \
        | sed 's|.*refs/heads/||' \
        | sort -V \
        | tail -1)"
    if [[ -z "${resolved_ref}" ]]; then
        printf 'error: no branch on %s matches %s -- the fork renamed its cockpit branches, so this check is blind until the glob is updated\n' \
            "${remote}" "${BRANCH_GLOB}" >&2
        exit 1
    fi
fi

if [[ "${resolved_ref}" =~ ^[0-9a-f]{40}$ ]]; then
    head_sha="${resolved_ref}"
else
    head_sha="$(git ls-remote "${remote}" "refs/heads/${resolved_ref}" | cut -f1)"
    if [[ -z "${head_sha}" ]]; then
        printf 'error: %s has no branch %s\n' "${remote}" "${resolved_ref}" >&2
        exit 1
    fi
fi

moved=false
if [[ "${head_sha}" != "${pinned_sha}" ]]; then
    moved=true
fi

printf 'SDK remote  %s\n' "${remote}"
printf 'SDK ref     %s\n' "${resolved_ref}"
printf 'Pinned sha  %s\n' "${pinned_sha}"
printf 'Ref head    %s\n' "${head_sha}"
printf 'Moved ahead %s\n' "${moved}"

# Everything a reader of a failed run needs is known here, before the build, so
# write the run summary now rather than from a trailing `if: always()` step that
# would have to survive the failure it is reporting on.
# shellcheck disable=SC2016 # the backticks are markdown code spans, not commands
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '## SDK head check\n\n'
        printf '| | |\n|---|---|\n'
        printf '| Remote | `%s` |\n' "${slug}"
        printf '| Ref | `%s` |\n' "${resolved_ref}"
        printf '| Pinned in build.zig.zon | [`%s`](%s/commit/%s) |\n' \
            "${pinned_sha}" "${remote}" "${pinned_sha}"
        printf '| Building against | [`%s`](%s/commit/%s) |\n' \
            "${head_sha}" "${remote}" "${head_sha}"
        printf '\n'
        if [[ "${moved}" == "true" ]]; then
            printf 'The fork is ahead of the pin. If this run is green, bump with:\n\n'
            printf '```sh\n./scripts/repoint-sdk.sh --ref %s\n```\n' "${resolved_ref}"
        else
            printf 'The pin is already the branch head; this run duplicates CI by design.\n'
        fi
    } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ "${DRY_RUN}" == "true" ]]; then
    printf 'Dry run: build.zig.zon left unchanged.\n'
    exit 0
fi

if [[ "${moved}" == "false" ]]; then
    printf 'build.zig.zon already pins %s; nothing to rewrite.\n' "${head_sha}"
    exit 0
fi

(
    cd "${ROOT}"
    zig fetch --save=native_sdk "${remote}/archive/${head_sha}.tar.gz"
)
printf 'build.zig.zon now pins %s@%s.\n' "${slug}" "${head_sha}"
