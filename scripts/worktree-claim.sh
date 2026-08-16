#!/usr/bin/env bash
# Claim this worktree for the branch you are working on, so a commit cannot land
# here from somewhere else.
#
#   ./scripts/worktree-claim.sh                # show the current claim
#   ./scripts/worktree-claim.sh claim          # claim for the current branch
#   ./scripts/worktree-claim.sh claim <branch> # claim for a named branch
#   ./scripts/worktree-claim.sh release        # drop the claim
#   ./scripts/worktree-claim.sh install        # point core.hooksPath at the hooks
#
# WHY. Parallel agents share one repository. Three times on 2026-08-15 a worktree
# was flipped onto another session's branch mid-flight; the resulting damage was
# a commit that swept up ~1200 lines of a neighbour's uncommitted work, and a
# "clean the tree" that destroyed an agent's work outright.
#
# The claim is stored at `git rev-parse --git-path worktree-claim`, which is
# per-worktree and never tracked -- claiming one worktree cannot affect another,
# and nothing about the claim reaches a commit.
#
# `install` is required once per clone: hooks live outside the tree, so a
# tracked hook does nothing until core.hooksPath points at it.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
claim_file="$(git rev-parse --git-path worktree-claim)"

case "${1:-show}" in
    show)
        if [[ -f "$claim_file" ]]; then
            printf 'worktree:    %s\n' "$(git rev-parse --show-toplevel)"
            printf 'claimed for: %s\n' "$(head -1 "$claim_file")"
            printf 'HEAD on:     %s\n' "$(git branch --show-current || echo '<detached>')"
        else
            printf 'worktree:    %s\n' "$(git rev-parse --show-toplevel)"
            printf 'claimed for: <unclaimed>\n'
            printf '\nRun "%s claim" to protect it.\n' "$0"
        fi
        ;;
    claim)
        branch="${2:-$(git branch --show-current)}"
        if [[ -z "$branch" ]]; then
            printf 'error: detached HEAD and no branch given; pass one explicitly\n' >&2
            exit 1
        fi
        printf '%s\n' "$branch" >"$claim_file"
        printf 'claimed %s for %s\n' "$(git rev-parse --show-toplevel)" "$branch"
        ;;
    release)
        rm -f "$claim_file"
        printf 'released %s\n' "$(git rev-parse --show-toplevel)"
        ;;
    install)
        # Repo-relative, so it resolves in every worktree of this clone.
        git config core.hooksPath scripts/git-hooks
        chmod +x "${ROOT}/scripts/git-hooks/"* 2>/dev/null || true
        printf 'core.hooksPath = %s\n' "$(git config core.hooksPath)"
        printf 'hooks active: pre-commit (refuses), post-checkout (warns)\n'
        ;;
    -h|--help)
        sed -n '2,26p' "$0"
        ;;
    *)
        printf 'unknown command: %s\n' "$1" >&2
        sed -n '2,26p' "$0" >&2
        exit 2
        ;;
esac
