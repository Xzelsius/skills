#!/usr/bin/env bash
# Pushes a worktree's HEAD to its PR branch, but only as a guarded fast-forward.
#
# Usage: push-guarded.sh <pr> <worktree> <branch> <base> <verified-tree-sha>
#
# Refuses (exit 1) unless, right after a fresh fetch:
#   - origin/<base> is an ancestor of HEAD (the fix sits on the current base branch),
#   - the remote branch head is an ancestor of HEAD (fast-forward, never a force push),
#   - HEAD's tree is exactly the tree the full build ran on (<verified-tree-sha> = `git rev-parse HEAD^{tree}`).
# Then it turns off the PR's auto-merge before it pushes. Renovate turns auto-merge on for the PRs it automerges,
# and GitHub keeps it on after a push by someone with write access, so the fix would merge before anyone reviewed it.

set -euo pipefail

[ "$#" -eq 5 ] || {
  sed -n '2,11p' "$0"
  exit 2
}
pr="$1" worktree="$2" branch="$3" base="$4" verified="$5"
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

if [ "$(gh pr view "$pr" --json autoMergeRequest --jq '.autoMergeRequest != null')" = true ]; then
  gh pr merge "$pr" --disable-auto
  echo "turned off auto-merge on #$pr, so the fix waits for a review"
fi
git push origin "HEAD:refs/heads/$branch"
echo "pushed ${remote:0:7}..$(git rev-parse --short HEAD) to $branch"
