#!/usr/bin/env bash
# Tests for scripts/lib/measure.sh. Offline, hermetic, sub-second.
#
#   ./scripts/lib/measure_test.sh
#
# Everything here was watched RED before it was watched green. The pin-scan
# cases in particular reproduce phux-cockpit-yo5 against a synthetic
# build.zig.zon, so the defect can be re-created on demand instead of being
# re-created accidentally by the next person who puts a local .path override on
# the SDK dependency.
#
# A synthetic .zon is the right fixture here and does not violate the
# never-compare-against-a-counterfactual-you-authored rule: this is not a
# comparison of two builds, it is a parser being fed an input that occurs in
# real use (docs/sdk-patches/ tells you to create exactly this state).
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
. "${ROOT}/scripts/lib/measure.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { printf '  ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

check_eq() {
    local what="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then ok "$what"; else
        bad "$what"
        printf '        want: %s\n' "$want" >&2
        printf '        got:  %s\n' "$got" >&2
    fi
}

# --------------------------------------------------------------- fixtures

# The shape build.zig.zon actually has: native_sdk pinned by url, ghostty next.
cat >"${WORK}/pinned.zon" <<'ZON'
.{
    .name = .phux_cockpit,
    .dependencies = .{
        // Prose about the pin. It mentions .url = "https://example.invalid/decoy.tar.gz"
        // because the real .zon carries long comment blocks and one of them
        // talks about urls.
        .native_sdk = .{
            .url = "https://github.com/phall1/native/archive/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tar.gz",
            .hash = "native_sdk-0.1.0-fake",
        },
        .ghostty = .{
            .url = "https://github.com/ghostty-org/ghostty/archive/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar.gz",
            .hash = "ghostty-fake",
        },
    },
}
ZON

# The state phux-cockpit-yo5 is about: native_sdk swapped for a local path
# while an SDK patch is validated. There is no url in the block, and the next
# url in the file belongs to a completely different dependency.
cat >"${WORK}/path-override.zon" <<'ZON'
.{
    .name = .phux_cockpit,
    .dependencies = .{
        .native_sdk = .{
            .path = "../native",
        },
        .ghostty = .{
            .url = "https://github.com/ghostty-org/ghostty/archive/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar.gz",
            .hash = "ghostty-fake",
        },
    },
}
ZON

# A pin by short sha: resolvable as a url, but not a thing any measurement may
# be attributed to.
cat >"${WORK}/short-sha.zon" <<'ZON'
.{
    .dependencies = .{
        .native_sdk = .{
            .url = "https://github.com/phall1/native/archive/aaaaaaa.tar.gz",
        },
    },
}
ZON

# ------------------------------------------------------- the pin resolution

printf 'measure_zon_dependency_url\n'

got="$(measure_zon_dependency_url native_sdk "${WORK}/pinned.zon")"
check_eq 'reads the native_sdk url' \
    'https://github.com/phall1/native/archive/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tar.gz' "$got"

got="$(measure_zon_dependency_url ghostty "${WORK}/pinned.zon")"
check_eq 'reads the ghostty url' \
    'https://github.com/ghostty-org/ghostty/archive/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.tar.gz' "$got"

# phux-cockpit-yo5. The failure mode is silent and specific: not an error, but
# ghostty's tarball returned as though it were the SDK's.
got="$(measure_zon_dependency_url native_sdk "${WORK}/path-override.zon" 2>"${WORK}/err" || true)"
if [[ "$got" == *ghostty* ]]; then
    bad 'a .path override must not fall through to the next dependency (phux-cockpit-yo5)'
    printf '        returned another dependency url: %s\n' "$got" >&2
elif [[ -n "$got" ]]; then
    bad 'a .path override must not resolve to any url'
    printf '        returned: %s\n' "$got" >&2
else
    ok 'a .path override does not fall through to the next dependency (phux-cockpit-yo5)'
fi

if measure_zon_dependency_url native_sdk "${WORK}/path-override.zon" >/dev/null 2>&1; then
    bad 'a .path override must exit non-zero'
else
    ok 'a .path override exits non-zero'
fi

if grep -q 'local .path override' "${WORK}/err"; then
    ok 'the refusal names the .path override'
else
    bad 'the refusal must name the .path override, not fail anonymously'
    printf '        stderr was: %s\n' "$(cat "${WORK}/err")" >&2
fi

# The comment in pinned.zon sits ABOVE the block, so a scan that ignored block
# boundaries but skipped comments would still pass the first case. This one
# puts the decoy INSIDE the block.
cat >"${WORK}/commented.zon" <<'ZON'
.{
    .dependencies = .{
        .native_sdk = .{
            // was .url = "https://example.invalid/old.tar.gz" before the bump
            .url = "https://github.com/phall1/native/archive/cccccccccccccccccccccccccccccccccccccccc.tar.gz",
        },
    },
}
ZON
got="$(measure_zon_dependency_url native_sdk "${WORK}/commented.zon")"
check_eq 'a commented-out url inside the block is not the pin' \
    'https://github.com/phall1/native/archive/cccccccccccccccccccccccccccccccccccccccc.tar.gz' "$got"

if measure_zon_dependency_url absent_dep "${WORK}/pinned.zon" >/dev/null 2>&1; then
    bad 'a missing dependency must exit non-zero'
else
    ok 'a missing dependency exits non-zero'
fi

printf 'measure_zon_dependency_sha\n'

got="$(measure_zon_dependency_sha native_sdk "${WORK}/pinned.zon")"
check_eq 'reads the pinned sha' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$got"

if measure_zon_dependency_sha native_sdk "${WORK}/short-sha.zon" >/dev/null 2>&1; then
    bad 'a short sha must be refused'
else
    ok 'a short sha is refused'
fi

# The real repository file must resolve, or every caller of this library is
# broken in a way the synthetic fixtures cannot see.
got="$(measure_zon_dependency_sha native_sdk)"
if [[ "$got" =~ ^[0-9a-f]{40}$ ]]; then
    ok "the repo's own build.zig.zon resolves (${got:0:9})"
else
    bad "the repo's own build.zig.zon does not resolve a native_sdk sha"
fi

got="$(measure_zon_dependency_repo native_sdk "${WORK}/pinned.zon")"
check_eq 'derives the git remote' 'https://github.com/phall1/native.git' "$got"

# ---------------------------------------------------------- sample floor

printf 'measure_require_sample_floor\n'

if measure_require_sample_floor 'host_draw' 200 200 2>/dev/null; then
    ok 'a count at the floor is reported'
else
    bad 'a count at the floor must be reported'
fi

if measure_require_sample_floor 'host_draw' 7 200 2>"${WORK}/floor-err"; then
    bad 'a count below the floor must refuse'
else
    ok 'a count below the floor refuses'
fi
if grep -q 'below the floor of 200' "${WORK}/floor-err"; then
    ok 'the floor refusal names both numbers'
else
    bad 'the floor refusal must name both numbers'
fi

# An empty counter is what a snapshot returns when the field does not exist
# yet, which is the state phux-cockpit-jw4 reported percentiles from.
if measure_require_sample_floor 'host_draw' '' 200 2>/dev/null; then
    bad 'an absent count must refuse'
else
    ok 'an absent count refuses'
fi

# ------------------------------------------------- assertions with controls

printf 'expect_change\n'

# A stub automation CLI. `assert --absent <pattern>` succeeds only for patterns
# not in PRESENT; plain `assert` succeeds only for patterns that are.
cat >"${WORK}/native" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
present="${STUB_PRESENT:-}"
[[ "${1:-}" == "automate" ]] || exit 2
shift
case "${1:-}" in
    assert)
        shift
        absent=0
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --absent) absent=1; shift ;;
                --timeout-ms) shift 2 ;;
                *) break ;;
            esac
        done
        for pattern in "$@"; do
            if [[ "$present" == *"$pattern"* ]]; then
                [[ "$absent" == "1" ]] && exit 1
            else
                [[ "$absent" == "1" ]] || exit 1
            fi
        done
        exit 0
        ;;
    snapshot) printf '%s\n' "$present"; exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "${WORK}/native"
NATIVE="${WORK}/native"

# An action that changes nothing: the pattern is absent before and after, so
# the control passes and the assertion has to fail.
STUB_PRESENT='role=textbox'
export STUB_PRESENT
if expect_change 'a no-op opens a tab' 'role=tab' true >/dev/null 2>&1; then
    bad 'an action that does not produce the pattern must fail'
else
    ok 'an action that does not produce the pattern fails'
fi

# The negative control itself. This is the case that matters: the pattern is
# ALREADY present, so the assertion cannot prove the action did anything, and
# the run must stop rather than report a pass.
STUB_PRESENT='role=tab name="Terminal 2'
export STUB_PRESENT
if expect_change 'already true' 'role=tab' true >"${WORK}/ec-out" 2>"${WORK}/ec-err"; then
    bad 'expect_change must fail when the pattern is present before the action'
else
    ok 'expect_change fails when the pattern is present before the action'
fi
if grep -q 'NEGATIVE CONTROL FAILED' "${WORK}/ec-err"; then
    ok 'the negative-control failure says so by name'
else
    bad 'the negative-control failure must say so by name'
fi

# The passing path: absent, then the action makes it present.
STUB_PRESENT='role=textbox'
export STUB_PRESENT
flip() { STUB_PRESENT='role=textbox role=tab'; export STUB_PRESENT; }
if expect_change 'the action adds a tab' 'role=tab' flip >/dev/null 2>&1; then
    ok 'absent, then present, passes'
else
    bad 'absent, then present, must pass'
fi

printf 'measure_require_publisher\n'

STUB_PRESENT='ready=true publisher_pid=4242'
export STUB_PRESENT
if measure_require_publisher 4242 >/dev/null 2>&1; then
    ok 'our own publisher_pid is accepted'
else
    bad 'our own publisher_pid must be accepted'
fi
if measure_require_publisher 99 >/dev/null 2>"${WORK}/pub-err"; then
    bad "a sibling's publisher_pid must be refused"
else
    ok "a sibling's publisher_pid is refused"
fi
if grep -q 'REFUSING TO ASSERT' "${WORK}/pub-err"; then
    ok 'the publisher refusal says so by name'
else
    bad 'the publisher refusal must say so by name'
fi

STUB_PRESENT='ready=true'
export STUB_PRESENT
if measure_require_publisher 4242 >/dev/null 2>&1; then
    bad 'a snapshot with no publisher_pid must be refused'
else
    ok 'a snapshot with no publisher_pid is refused'
fi

# ------------------------------------------------------------------ record

printf 'measure_basis\n'

got="$(measure_basis cell_grid 'JetBrains Mono NL 13pt, scale 2, 48 cols' './scripts/host-raster-check.sh')"
if [[ "$got" == MEASURED-BASIS\ cell_grid\ * && "$got" == *'derive="./scripts/host-raster-check.sh"'* ]]; then
    ok 'the basis line carries the deriving command'
else
    bad 'the basis line must carry the deriving command'
    printf '        got: %s\n' "$got" >&2
fi
if [[ "$got" == *'basis="JetBrains Mono NL 13pt, scale 2, 48 cols"'* ]]; then
    ok 'the basis line carries the basis'
else
    bad 'the basis line must carry the basis'
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" == "0" ]]
