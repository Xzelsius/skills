#!/usr/bin/env bash
# Shared helpers for the renovate-sweep and renovate-fix scripts. Source it, don't execute it.

set -euo pipefail

for tool in git gh jq; do
  command -v "$tool" >/dev/null || {
    echo "missing tool: $tool" >&2
    exit 2
  }
done

# The account Renovate commits and opens PRs as. Self-hosted Renovate uses its own account; pass --bot <login>.
# shellcheck disable=SC2034 # used by the scripts that source this file
DEFAULT_BOT='renovate[bot]'

# jq on Windows ends lines with CRLF. $(...) strips the \r, but read and mapfile keep it.
jq() {
  command jq "$@" | tr -d '\r'
}

repo_slug() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

# `gh pr list --author` takes app/<name> for a GitHub App and the plain login otherwise.
author_filter() {
  case "$1" in
    *'[bot]') echo "app/${1%'[bot]'}" ;;
    *) echo "$1" ;;
  esac
}

# Runs gh pr checks, treating "no checks reported" as an empty list.
# Prints the JSON array, or nothing when the given error text matched. Exit 1 on any other error.
_checks() {
  local pr="$1" empty="$2" out err status=0
  err="$(mktemp)"
  shift 2
  out="$(gh pr checks "$pr" "$@" --json name,bucket,link 2>"$err")" || status=$?
  if [ "$status" -ne 0 ]; then
    if grep -q -F "$empty" "$err"; then
      rm -f "$err"
      return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

# CI state of a PR as JSON: {ci, scope, failed, pending, stability}.
#   ci:        pass | fail | pending | none (no checks at all)
#   scope:     required (the checks branch protection or rulesets require) | all (none are required, so all count)
#   stability: Renovate's minimum release age status (renovate/stability-days): pass | pending | absent
# `gh pr checks --required` lists only checks that have already reported. mergeStateStatus stays the merge gate.
ci_summary() {
  local pr="$1" all req scope=required
  all="$(_checks "$pr" 'no checks reported')"
  req="$(_checks "$pr" 'no required checks reported' --required)"
  [ -n "$all" ] || all='[]'
  [ -n "$req" ] || req='[]'
  jq -n --argjson all "$all" --argjson req "$req" --arg scope "$scope" '
    def ci: map(select(.name != "renovate/stability-days"));
    ($req | ci) as $r
    | (if ($r | length) > 0 then {c: $r, scope: $scope} else {c: ($all | ci), scope: "all"} end) as $x
    | ($all | map(select(.name == "renovate/stability-days")) | first) as $s
    | def failed: .bucket == "fail" or .bucket == "cancel";
    {
      ci: (if ($x.c | length) == 0 then "none"
           elif any($x.c[]; failed) then "fail"
           elif any($x.c[]; .bucket == "pending") then "pending"
           else "pass" end),
      scope: (if ($x.c | length) == 0 then "none" else $x.scope end),
      failed: [ $x.c[] | select(failed) | .name ],
      pending: [ $x.c[] | select(.bucket == "pending") | .name ],
      stability: (if $s == null then "absent" elif $s.bucket == "pending" then "pending" else "pass" end)
    }'
}
