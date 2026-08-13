# shellcheck shell=bash
# One reader for build.zig.zon dependency pins. Source this; do not reimplement.
#
# WHY THIS FILE EXISTS, and it is not tidiness.
#
# Five scripts each carried their own copy of the same awk one-liner, and every
# copy had the same defect. The opener matched `.<name> = .{` and then `next`ed,
# discarding the rest of that line, while the only close rule was a STANDALONE
# `},`. So a single-line block -- exactly what a local SDK patch uses:
#
#     .native_sdk = .{ .path = "../native" },
#
# opened and never closed, and the reader walked on into the NEXT dependency.
# Asking for `native_sdk` returned GHOSTTY's tarball url. That url passes the
# sha-pinned-github-archive check, so `check-sdk-pin.sh` reported
#
#     Pinned native_sdk is ghostty-org/ghostty@7aa9591746... and README.md agrees.
#
# and exited 0. The gate whose entire purpose is catching pin drift certified
# the wrong repository, green. `repoint-sdk.sh` was worse: it would have run
# `zig fetch --save=native_sdk` on a ghostty tarball and written that into
# build.zig.zon as the SDK pin.
#
# Verified by execution against the real scripts, not by reading them.
# See phux-cockpit-yo5.
#
# zon_dependency_url <zon-path> <name>
#   stdout: the url          exit 0
#   (silent)                 exit 3  the dependency exists but has no .url
#                                    (a .path override) -- a NAMED refusal, never
#                                    a fall-through to another dependency
#   (silent)                 exit 4  no such dependency
zon_dependency_url() {
    local zon="$1" name="$2"
    awk -v name="${name}" '
        # Blank the BODY of every double-quoted string, preserving length, so a
        # url inside prose or inside another key value can never be read as this
        # pin for this dependency, and so a brace inside a string cannot move the depth.
        function blanked(s,   out, pad, i, body) {
            out = ""
            while (match(s, /"[^"]*"/)) {
                body = RLENGTH - 2
                pad = ""
                for (i = 0; i < body; i++) pad = pad "x"
                out = out substr(s, 1, RSTART) pad "\""
                s = substr(s, RSTART + RLENGTH)
            }
            return out s
        }
        BEGIN { inside = 0; depth = 0; found = 0; seen = 0 }
        {
            line = $0
            scan = blanked(line)
            if (!inside) {
                needle = "." name " = .{"
                at = index(scan, needle)
                if (at == 0) next
                inside = 1
                seen = 1
                depth = 0
                # Only the text from the opening brace of THIS block onward: a url
                # earlier on the same line belongs to somebody else.
                cut = at + length(needle) - 1
                scan = substr(scan, cut)
                line = substr(line, cut)
            }
            opens = gsub(/\{/, "{", scan)
            closes = gsub(/\}/, "}", scan)
            if (match(line, /\.url = "[^"]*"/)) {
                u = substr(line, RSTART, RLENGTH)
                match(u, /"[^"]*"/)
                print substr(u, RSTART + 1, RLENGTH - 2)
                found = 1
                exit
            }
            depth += opens - closes
            if (depth <= 0) exit
        }
        END {
            if (found) exit 0
            if (seen) exit 3
            exit 4
        }
    ' "${zon}"
}

# The same read, with the refusals turned into messages naming what to do.
# Callers that just want a url and a clean failure should use this.
zon_dependency_url_or_die() {
    local zon="$1" name="$2" url status
    url="$(zon_dependency_url "${zon}" "${name}")"
    status=$?
    case "${status}" in
        0) printf '%s\n' "${url}"; return 0 ;;
        3)
            printf 'error: .%s in %s has no .url -- it is a local override (.path).\n' \
                "${name}" "${zon}" >&2
            printf 'Refusing to guess. Point at a published pin, or pass the dependency explicitly.\n' >&2
            return 3
            ;;
        4)
            printf 'error: %s has no .%s dependency.\n' "${zon}" "${name}" >&2
            return 4
            ;;
        *)
            printf 'error: reading .%s from %s failed (%s).\n' "${name}" "${zon}" "${status}" >&2
            return 1
            ;;
    esac
}
