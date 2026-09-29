#!/usr/bin/env bash
# Watches a PR until its checks have finished or it is merged, or its head changes.
#
# Usage: watch-pr.sh [--until checks|merged] [--timeout <s>=540] [--interval <s>=15] <pr> <expected-head-sha>
#
# --until checks (default) returns once the checks have finished; --until merged waits for the merge, and also
# returns when a check fails, because the PR then won't merge.
# Exit 0: merged, or done waiting (prints ci, the failed checks, review, merge state and auto-merge).
# Exit 1: timeout; call again to keep waiting. Exit 2: the head changed (someone pushed, e.g. Renovate raced a
# push) or the PR was closed.
# The default timeout stays below the 10-minute cap that agent shells put on a single command.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

mode=checks timeout=540 interval=15 args=()
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
    --interval)
      interval="$2"
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
  json="$(gh pr view "$pr" --json state,headRefOid,reviewDecision,mergeStateStatus,autoMergeRequest)"
  state="$(jq -r .state <<<"$json")"
  head="$(jq -r .headRefOid <<<"$json")"

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
  ci="$(jq -r .ci <<<"$summary")"
  if [ "$ci" = "fail" ] || { [ "$ci" != "pending" ] && [ "$mode" = "checks" ]; }; then
    jq -r --argjson s "$summary" '"ci=\($s.ci) failed=\($s.failed | join(",")) review=\(.reviewDecision)"
      + " merge=\(.mergeStateStatus) autoMerge=\(.autoMergeRequest != null)"' <<<"$json"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timeout: ci=$ci pending=$(jq -r '.pending | join(",")' <<<"$summary") merge=$(jq -r .mergeStateStatus <<<"$json")" >&2
    exit 1
  fi
  sleep "$interval"
done
