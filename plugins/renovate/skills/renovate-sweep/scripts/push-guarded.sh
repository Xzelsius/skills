#!/usr/bin/env bash
# Pushes a worktree's HEAD to its PR branch, but only as a guarded fast-forward.
#
# Usage: push-guarded.sh <worktree> <branch> <base> <verified-tree-sha> [--dry-run]
#
# Refuses (exit 1) unless, right after a fresh fetch:
#   - origin/<base> is an ancestor of HEAD (the fix sits on the current base branch),
#   - the remote branch head is an ancestor of HEAD (fast-forward, never a force push),
#   - HEAD's tree is exactly the tree the full build ran on (<verified-tree-sha> = `git rev-parse HEAD^{tree}`).

set -euo pipefail

[ "$#" -ge 4 ] || {
  sed -n '2,9p' "$0"
  exit 2
}
worktree="$1" branch="$2" base="$3" verified="$4" dry="${5:-}"
cd "$worktree"

git fetch origin "$base" "$branch" --quiet
tree="$(git rev-parse 'HEAD^{tree}')"
remote="$(git rev-parse "origin/$branch")"

[ "$tree" = "$verified" ] || {
  echo "refused: HEAD tree ${tree:0:7} is not the verified tree ${verified:0:7}" >&2
  exit 1
}
git merge-base --is-ancestor "origin/$base" HEAD || {
  echo "refused: origin/$base moved; wait for Renovate's rebase, then re-apply and re-verify" >&2
  exit 1
}
git merge-base --is-ancestor "$remote" HEAD || {
  echo "refused: origin/$branch (${remote:0:7}) is not an ancestor of HEAD; not a fast-forward" >&2
  exit 1
}

if [ "$dry" = "--dry-run" ]; then
  echo "dry run: would push ${remote:0:7}..$(git rev-parse --short HEAD) to $branch"
  exit 0
fi

git push origin "HEAD:refs/heads/$branch"
echo "pushed ${remote:0:7}..$(git rev-parse --short HEAD) to $branch"
