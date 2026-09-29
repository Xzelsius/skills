#!/usr/bin/env bash
# Waits until a Renovate PR's branch is up to date with its base branch.
#
# Usage: wait-rebase.sh [--bot <login>] [--request] [--timeout <s>=540] [--interval <s>=15] <pr>
#
# --request ticks Renovate's rebase checkbox first, which is a GitHub write. Renovate then rebases the branch, or
# recreates it without any commits that aren't its own.
#
# Exit 0: up to date (prints head and base). Exit 1: timeout; call again to keep waiting.
# Exit 3: the head isn't Renovate's own commit, so Renovate won't rebase it (someone pushed on top).
# Exit 4: the PR was closed or its branch is gone.
# Never rebase Renovate's commit yourself instead: a Renovate job already in flight can force-push over it.
# The default timeout stays below the 10-minute cap that agent shells put on a single command.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

bot="$DEFAULT_BOT" request=0 timeout=540 interval=15 pr=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bot)
      bot="$2"
      shift 2
      ;;
    --request)
      request=1
      shift
      ;;
    --timeout)
      timeout="$2"
      shift 2
      ;;
    --interval)
      interval="$2"
      shift 2
      ;;
    *)
      pr="$1"
      shift
      ;;
  esac
done
[ -n "$pr" ] || {
  sed -n '2,14p' "$0"
  exit 2
}

slug="$(repo_slug)"
json="$(gh pr view "$pr" --json state,headRefName,baseRefName,body)"
branch="$(jq -r .headRefName <<<"$json")"
base="$(jq -r .baseRefName <<<"$json")"
[ "$(jq -r .state <<<"$json")" = "OPEN" ] || {
  echo "PR #$pr is $(jq -r .state <<<"$json")" >&2
  exit 4
}

if [ "$request" -eq 1 ]; then
  body="$(mktemp)"
  jq -r .body <<<"$json" >"$body"
  if grep -q -F -- '- [ ] <!-- rebase-check -->' "$body"; then
    sed -i.bak 's/- \[ \] <!-- rebase-check -->/- [x] <!-- rebase-check -->/' "$body"
    gh pr edit "$pr" --body-file "$body" >/dev/null
    echo "ticked the rebase checkbox of #$pr"
  else
    echo "no unticked rebase checkbox in #$pr; waiting without it" >&2
  fi
  rm -f "$body" "$body.bak"
fi

deadline=$(($(date +%s) + timeout))
while :; do
  base_sha="$(git ls-remote origin "refs/heads/$base" | cut -f1)"
  head="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
  [ -n "$head" ] || {
    echo "branch $branch no longer exists" >&2
    exit 4
  }
  behind="$(gh api "repos/$slug/compare/$base_sha...$head" --jq .behind_by)"

  if [ "$behind" = "0" ]; then
    echo "up to date: head=${head:0:7} base=$base@${base_sha:0:7}"
    exit 0
  fi
  # After --request, Renovate discards other commits itself, so only check the author without it.
  if [ "$request" -eq 0 ]; then
    author="$(gh api "repos/$slug/commits/$head" --jq '.author.login // .commit.author.name')"
    if [ "$author" != "$bot" ]; then
      echo "head ${head:0:7} is by $author, not $bot; Renovate won't rebase it" >&2
      exit 3
    fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timeout: head=${head:0:7} is $behind behind $base@${base_sha:0:7}" >&2
    exit 1
  fi
  sleep "$interval"
done
