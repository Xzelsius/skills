#!/usr/bin/env bash
# Deduplicated errors of a PR's failing CI run(s).
#
# Usage: ci-errors.sh <pr-number>
#        ci-errors.sh --run <run-id>
#
# The failing runs are found through the links of the PR's checks (`gh run list --branch` misses some Renovate
# branches). The last line is one of:
#   PATTERN: known     compiler, MSBuild, test, lint, npm or GitHub Actions errors were found
#   PATTERN: none      a GitHub Actions run failed without a known pattern; the only case where a rerun is allowed
#   PATTERN: external  only checks outside GitHub Actions failed; they can't be read or rerun from here

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

runs=()
external=""
if [ "${1:-}" = "--run" ]; then
  runs=("$2")
else
  checks="$(gh pr checks "$1" --json name,bucket,link)"
  while IFS= read -r run; do
    [ -n "$run" ] && runs+=("$run")
  done < <(jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | .link' <<<"$checks" \
    | sed -nE 's#.*/actions/runs/([0-9]+)(/.*)?$#\1#p' | sort -u)
  external="$(jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel")
    | select(.link | test("/actions/runs/[0-9]+") | not) | "\(.name) \(.link)"' <<<"$checks")"
fi

if [ -n "$external" ]; then
  echo "-- failing checks outside GitHub Actions (can't be read or rerun from here):"
  echo "$external"
fi
if [ "${#runs[@]}" -eq 0 ]; then
  echo "No failing GitHub Actions run found."
  if [ -n "$external" ]; then echo "PATTERN: external"; else echo "PATTERN: none"; fi
  exit 0
fi

tab=$'\t'
known=0
for run in "${runs[@]}"; do
  echo "== run $run: $(gh run view "$run" --json jobs --jq '
    [ .jobs[] | select(.conclusion == "failure")
      | "\(.name) -> \([ .steps[] | select(.conclusion == "failure") | .name ] | join(", "))" ] | join("; ")')"

  # Each log line is "<job>\t<step>\t<timestamp> <message>"; keep only the message.
  log="$(gh run view "$run" --log-failed 2>&1 | strip_ansi | sed -E "s/^[^${tab}]*${tab}[^${tab}]*${tab}[0-9T:.-]+Z ?//")"

  # MSBuild/compiler: "path/File.cs(16,17): error CS0400: message [project]" or "CSC : error CS1705: ...",
  # also code-less target errors like "X.targets(355,5): error : message".
  build="$(grep -oE '([A-Za-z0-9_.-]+\.[A-Za-z]+\([0-9]+(,[0-9]+)?\)|CSC|MSBUILD) ?: (error|warning)( [A-Z]+[0-9]+)? ?:[^[]*(\[[^]]*\])?' <<<"$log" \
    | grep -E ': error' | sed -E 's#\[([^]]*[/\\])?([^]/\\]+)\]$#(\2)#; s/[[:space:]]+$//' | sort | uniq -c | sort -rn || true)"
  # TypeScript: "src/a.ts(12,5): error TS2345: ..." or "src/a.ts:12:5 - error TS2345: ..."
  tsc="$(grep -oE '[A-Za-z0-9_./-]+\.[cm]?[jt]sx?(\([0-9]+,[0-9]+\): |:[0-9]+:[0-9]+ - )error TS[0-9]+: .*' <<<"$log" | sort | uniq -c | sort -rn || true)"
  # dotnet test: "  Failed Namespace.Class.Method [12 ms]"; Jest/Vitest: "FAIL src/a.test.ts"
  tests="$(grep -oE '^[[:space:]]*(Failed [A-Za-z0-9_.+<>,`]+ \[[^]]*\]|FAIL[[:space:]]+[^[:space:]]+\.(test|spec)\.[cm]?[jt]sx?.*)' <<<"$log" \
    | sed -E 's/^[[:space:]]+//' | sort -u || true)"
  # npm: "npm ERR! code ERESOLVE" (npm 6-9) or "npm error code ERESOLVE" (npm 10+), plus the lines that explain it
  npm="$(grep -E '^npm (ERR!|error) ' <<<"$log" | grep -vE '^npm (ERR!|error) (A complete log|[[:space:]]*$)' | head -20 || true)"
  # ESLint and VitePress: "  12:5  error  message  rule" and dead links
  lint="$(grep -E '^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+error[[:space:]]|[Dd]ead link' <<<"$log" | sort -u || true)"
  # GitHub Actions: an action that doesn't resolve, a required input that's missing, an input that no longer exists
  actions="$(grep -E "Unable to resolve action|Can't find 'action\.ya?ml'|Input required and not supplied|Unexpected input\(s\)" <<<"$log" \
    | sed -E 's/^.*##\[(error|warning)\]//' | sort -u || true)"

  [ -n "$build" ] && echo "-- build errors (occurrences in the log, location: code: message (project))" && echo "$build"
  [ -n "$tsc" ] && echo "-- TypeScript errors (occurrences in the log)" && echo "$tsc"
  [ -n "$tests" ] && echo "-- failed tests" && echo "$tests"
  [ -n "$npm" ] && echo "-- npm errors" && echo "$npm"
  [ -n "$lint" ] && echo "-- lint / docs errors" && echo "$lint"
  [ -n "$actions" ] && echo "-- GitHub Actions errors" && echo "$actions"
  if [ -n "$build$tsc$tests$npm$lint$actions" ]; then
    known=1
  else
    echo "-- no known error pattern; last error annotations:"
    grep -E '##\[error\]' <<<"$log" | grep -v 'Process completed with exit code' | sed -E 's/^.*##\[error\]//' | sort -u | tail -10 || true
  fi
done

if [ "$known" -eq 1 ]; then echo "PATTERN: known"; else echo "PATTERN: none"; fi
