#!/usr/bin/env bash
#
# The CHEAP half of the guard ritual, wired into `zig build test`.
#
# A guard is a regression test that has been WATCHED FAILING with its fix
# removed. `scripts/guard-red-run.sh` is what watches; this script is what
# keeps the resulting bookkeeping from rotting, and it is deliberately the
# only half that runs on every gate, because it costs milliseconds and the
# other half costs minutes.
#
# It answers three questions, all of them statically:
#
#   1. Does every `// GUARD: <name>` marker in src/ have a guard file, and
#      does every guard file name a test that still exists with that marker?
#      A marker whose file was deleted is a claim with nothing behind it.
#
#   2. Has every guard actually been demonstrated red? A guard file with no
#      `red:` line is a test-shaped comment — exactly the thing phux-cockpit-2ml.2
#      exists to stop. guard-red-run.sh is the only writer of that line, and it
#      writes it only after watching the named test fail.
#
#   3. Does each guard's break still APPLY to the tree? This is the staleness
#      test. `red:` records a run against a particular shape of the fix; if the
#      fix has since moved, the recorded proof is about code that is gone. A
#      patch that no longer applies is not a failure of the fix — it is a
#      demand to re-derive the guard and watch it go red again.
#
# What it deliberately does NOT check is whether the test would still go red.
# Nothing static can know that. That is what guard-red-run.sh is for, and the
# gap between "the break still applies" and "the test still fails without the
# fix" is real. See docs/GUARDS.md.
#
# Silent on success: this runs as a build step with inherited stdio, and Zig's
# build runner reports any step that wrote to stderr as a failure.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_DIR="$ROOT/scripts/guards"

status=0
complain() {
    printf 'guard-check: %s\n' "$1" >&2
    status=1
}

# ------------------------------------------------- guard file -> source tree

shopt -s nullglob
guard_files=("$GUARD_DIR"/*.guard)
shopt -u nullglob

declare -A known_guard=()

for guard in "${guard_files[@]}"; do
    name="$(basename "$guard" .guard)"
    known_guard["$name"]=1

    test_name="$(sed -n 's/^test: //p' "$guard" | head -1)"
    if [[ -z "$test_name" ]]; then
        complain "$name: no 'test:' line. A guard must name the test it proves."
        continue
    fi

    # -F: Zig test names are prose and contain regex metacharacters.
    hit="$(grep -rFn "test \"$test_name\" {" "$ROOT/src" || true)"
    if [[ -z "$hit" ]]; then
        complain "$name: names test \"$test_name\", which no longer exists in src/."
        continue
    fi
    if [[ "$(printf '%s\n' "$hit" | wc -l)" -ne 1 ]]; then
        complain "$name: test \"$test_name\" is declared more than once; the guard is ambiguous."
        continue
    fi

    src_file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"

    # The marker sits on the line directly above the test, so a reader who
    # opens the test sees the claim without going looking for it.
    marker="$(sed -n "$((line - 1))p" "$src_file")"
    if [[ "$marker" != *"// GUARD: $name"* ]]; then
        complain "$name: expected '// GUARD: $name' directly above test \"$test_name\" in $src_file:$line."
    fi

    if ! grep -q '^red: ' "$guard"; then
        complain "$name: never demonstrated red. Run: scripts/guard-red-run.sh $name"
    fi

    # Staleness. The break is stored as a patch against the FIXED tree, so it
    # must still apply forward. When it does not, the fix it removes has moved
    # and the recorded proof is about code that no longer exists.
    if ! sed -n '/^diff --git /,$p' "$guard" | git -C "$ROOT" apply --check - 2>/dev/null; then
        complain "$name: its break no longer applies to the tree. The fix moved; re-derive with scripts/guard-red-run.sh --record."
    fi
done

# ------------------------------------------------- source tree -> guard file

while IFS= read -r marker_line; do
    [[ -z "$marker_line" ]] && continue
    name="$(printf '%s' "$marker_line" | sed -n 's/.*\/\/ GUARD: \([A-Za-z0-9_-]*\).*/\1/p')"
    if [[ -z "$name" ]]; then
        complain "malformed GUARD marker (expected '// GUARD: <name>'): $marker_line"
        continue
    fi
    if [[ -z "${known_guard[$name]:-}" ]]; then
        complain "$name: marked in ${marker_line%%:*} but scripts/guards/$name.guard does not exist."
    fi
done < <(grep -rn '// GUARD: ' "$ROOT/src" || true)

exit "$status"
