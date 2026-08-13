#!/usr/bin/env bash
# Every fixture here is a shape that BROKE the old reader, plus the shapes that
# must keep working. The single-line override is the one that mattered: the old
# reader answered it with ghostty's url and exited 0.
set -uo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/zon.sh
source "${ROOT}/scripts/lib/zon.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
pass=0
fail=0

check() {
    local what="$1" want_out="$2" want_code="$3" got_out got_code
    got_out="$(zon_dependency_url "${WORK}/z.zon" "${4}")"
    got_code=$?
    if [[ "${got_out}" == "${want_out}" && "${got_code}" == "${want_code}" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n  want out=%q code=%s\n  got  out=%q code=%s\n' \
            "${what}" "${want_out}" "${want_code}" "${got_out}" "${got_code}" >&2
    fi
}

SDK_URL="https://github.com/phall1/native/archive/f3678832fd282b81241993d0c08105cd5170f39f.tar.gz"
GHOSTTY_URL="https://github.com/ghostty-org/ghostty/archive/7aa9591746ffa4d2eee458960c76554352832595.tar.gz"

# THE REGRESSION. A one-line .path override followed by another dependency.
# The old reader returned GHOSTTY_URL here, exit 0.
cat >"${WORK}/z.zon" <<EOF
.{
    .dependencies = .{
        .native_sdk = .{ .path = "../native" },
        .ghostty = .{ .url = "${GHOSTTY_URL}" },
    },
}
EOF
check 'single-line .path override refuses, does not leak the next dependency' '' 3 native_sdk
check 'ghostty still readable past a single-line override' "${GHOSTTY_URL}" 0 ghostty

# The multi-line override the old reader did handle. Keep it handled.
cat >"${WORK}/z.zon" <<EOF
.{
    .dependencies = .{
        .native_sdk = .{
            .path = "../native",
        },
        .ghostty = .{ .url = "${GHOSTTY_URL}" },
    },
}
EOF
check 'multi-line .path override refuses' '' 3 native_sdk

# The ordinary shape, both forms.
cat >"${WORK}/z.zon" <<EOF
.{
    .dependencies = .{
        .native_sdk = .{
            .url = "${SDK_URL}",
            .hash = "native_sdk-0.1.0-xxx",
        },
        .ghostty = .{ .url = "${GHOSTTY_URL}" },
    },
}
EOF
check 'multi-line pin reads its own url' "${SDK_URL}" 0 native_sdk
check 'single-line pin reads its own url' "${GHOSTTY_URL}" 0 ghostty
check 'absent dependency is distinguishable from a .path override' '' 4 nonesuch

# A url mentioned in PROSE above the block must not be mistaken for the pin.
# This is why the reader blanks string bodies before counting braces.
cat >"${WORK}/z.zon" <<EOF
.{
    .dependencies = .{
        // see "https://github.com/example/not-the-pin/archive/deadbeef.tar.gz"
        .native_sdk = .{
            .url = "${SDK_URL}",
        },
    },
}
EOF
check 'a url in a comment above the block is not the pin' "${SDK_URL}" 0 native_sdk

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
