#!/usr/bin/env bash
# Ephemeral worktrees for Renovate PRs, kept outside the repository so the main checkout stays untouched.
#
# Usage: worktree.sh add <pr> <branch>     create <root>/pr-<pr> on local branch renovate-sweep/pr-<pr>
#        worktree.sh reset <pr> <branch>   discard everything in it and move it to the latest origin/<branch>
#        worktree.sh remove <pr>           remove the worktree, its local branch and its saved files
#        worktree.sh prune                 remove all worktrees whose PR is no longer open
#        worktree.sh root                  print the root
#
# Root: ${TMPDIR:-/tmp}/renovate-sweep/<owner>-<repo>. Run it from the main checkout.
# Per-PR files live next to the worktree, so a reset doesn't lose them: pr-<pr>.patch (verified fix),
# pr-<pr>.json (worker verdict) and pr-<pr>.pushed (head SHA of a fix the sweep pushed).

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

slug="$(repo_slug)"
root="${TMPDIR:-/tmp}/renovate-sweep/${slug//\//-}"
# On Windows, print C:/... paths, which both Git Bash and native tools understand.
if command -v cygpath >/dev/null; then root="$(cygpath -m "$root")"; fi

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

remove_one() {
  local pr="$1" path="$root/pr-$1"
  git worktree remove --force "$path" 2>/dev/null || rm -rf "$path"
  git branch -D "renovate-sweep/pr-$pr" >/dev/null 2>&1 || true
  rm -f "$root/pr-$pr.patch" "$root/pr-$pr.json" "$root/pr-$pr.pushed"
  git worktree prune
  echo "removed pr-$pr"
}

case "$cmd" in
  add)
    pr="$1" branch="$2" path="$root/pr-$1"
    mkdir -p "$root"
    [ -e "$path" ] && {
      echo "worktree exists: $path (use reset)" >&2
      exit 1
    }
    git fetch origin "$branch" --quiet
    git worktree add --quiet -B "renovate-sweep/pr-$pr" "$path" "origin/$branch"
    echo "$path"
    ;;
  reset)
    pr="$1" branch="$2" path="$root/pr-$1"
    git fetch origin "$branch" --quiet
    git -C "$path" reset --quiet --hard "origin/$branch"
    git -C "$path" clean --quiet -fdx -e node_modules
    echo "$path at $(git -C "$path" rev-parse --short HEAD)"
    ;;
  remove)
    remove_one "$1"
    ;;
  prune)
    for path in "$root"/pr-*/; do
      [ -d "$path" ] || continue
      pr="$(basename "$path")"
      pr="${pr#pr-}"
      state="$(gh pr view "$pr" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
      [ "$state" = "OPEN" ] || remove_one "$pr"
    done
    git worktree prune
    ;;
  root)
    echo "$root"
    ;;
  *)
    sed -n '2,12p' "$0"
    exit 2
    ;;
esac
