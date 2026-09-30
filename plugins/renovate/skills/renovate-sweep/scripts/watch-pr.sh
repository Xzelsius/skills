#!/usr/bin/env bash
# Watches a PR until its checks have finished or it is merged, or its head changes.
#
# Usage: watch-pr.sh [--until checks|merged] [--timeout <s>=540] <pr> <expected-head-sha>
#
# --until checks (default) returns once the checks have finished; --until merged waits for the merge, and also
# returns when a check fails, because the PR then won't merge.
# Exit 0: merged (prints MERGED), or done waiting (prints ci, stability, failed, review, merge and autoMerge).
# Exit 1: timeout; call again to keep waiting. Exit 2: the head changed (someone pushed, e.g. Renovate raced a
# push) or the PR was closed.
# The default timeout stays below the 10-minute cap that agent shells put on a single command.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

mode=checks timeout=540 args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --until)
      mode="$2"
      shift 2
      ;;
    --timeout)
      timeout="$2"
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
[ "${#args[@]}" -eq 2 ] || {
  sed -n '2,11p' "$0"
  exit 2
}
pr="${args[0]}" expected="${args[1]}"
deadline=$(($(date +%s) + timeout))

while :; do
  info="$(gh pr view "$pr" --json state,headRefOid,reviewDecision,mergeStateStatus,autoMergeRequest \
    --jq '.state, .headRefOid, (.reviewDecision // ""), .mergeStateStatus, (if .autoMergeRequest then "yes" else "no" end)')"
  {
    read -r state
    read -r head
    read -r review
    read -r merge
    read -r auto
  } <<<"$info"

  if [ "$state" = "MERGED" ]; then
    echo "MERGED"
    exit 0
  fi
  if [ "$state" = "CLOSED" ]; then
    echo "CLOSED" >&2
    exit 2
  fi
  case "$head" in
    "$expected"*) ;;
    *)
      echo "head changed: ${head:0:7} (expected ${expected:0:7})" >&2
      exit 2
      ;;
  esac

  summary="$(ci_summary "$pr")"
  ci="${summary#ci=}"
  ci="${ci%% *}"
  if [ "$ci" = "fail" ] || { [ "$ci" != "pending" ] && [ "$mode" = "checks" ]; }; then
    echo "$summary review=$review merge=$merge autoMerge=$auto"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timeout: ci=$ci merge=$merge" >&2
    exit 1
  fi
  sleep 15
done
