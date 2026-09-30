#!/usr/bin/env bash
# Shared helpers for the scripts of renovate-sweep and renovate-fix. Source it, don't execute it.
#
# The scripts need only bash, git and gh. They read GitHub's JSON with gh's built-in --jq and print plain text for
# the model, so they don't need jq.

set -euo pipefail

for tool in git gh; do
  command -v "$tool" >/dev/null || {
    echo "missing tool: $tool" >&2
    exit 2
  }
done

# The repo's settings for the Renovate skills, in git config syntax (config.sh describes them).
CONFIG_FILE='.github/renovate-sweep.conf'

repo_slug() {
  gh repo view --json nameWithOwner --jq .nameWithOwner
}

# `gh pr list --author` takes app/<name> for a GitHub App and the plain login otherwise.
author_filter() {
  case "$1" in
    *'[bot]') echo "app/${1%'[bot]'}" ;;
    *) echo "$1" ;;
  esac
}

strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

# The blob of a file at a ref; exit 1 if it doesn't exist there.
blob_at() {
  local blob
  blob="$(git ls-tree --full-tree "$1" -- "$2" | awk '$2 == "blob" { print $3; exit }')"
  [ -n "$blob" ] || return 1
  echo "$blob"
}

# Prints a file as it is at a ref; exit 1 if it doesn't exist there. Use it instead of `git show <ref>:<path>`:
# Git Bash converts such an argument like a path list when both sides contain a slash and the path starts with a
# dot folder, so origin/main:.github/x reaches git as origin\main;.github\x.
show_file() {
  local blob
  blob="$(blob_at "$1" "$2")" || return 1
  git cat-file blob "$blob"
}

# Stops the calling script with exit 2: the config file named first isn't valid, for the problems given second,
# one per line.
config_invalid() {
  {
    echo "invalid config: $1"
    printf '%s\n' "${2%$'\n'}" | sed 's/^fatal: //'
    echo "references/config.md of the renovate-sweep skill describes every key."
  } >&2
  exit 2
}

# Loads the repo's settings into cfg_source, cfg_bot, cfg_merge_method, cfg_verify and cfg_rules: from the given
# file if there is one, as --config passes it, otherwise from the default branch after a fetch. cfg_source is empty
# when there's no file. cfg_rules has one "<glob> <yes|no>" line per dependency rule, in file order. An invalid file
# stops the calling script (config_invalid). git parses the file and checks the booleans.
# shellcheck disable=SC2034 # the cfg_ variables are read by the scripts that source this file
load_config() {
  local file="${1:-}" base blob names name glob value rules status=0 problems=""
  local -a src
  cfg_source="" cfg_bot='renovate[bot]' cfg_merge_method="" cfg_verify="" cfg_rules=""
  if [ -n "$file" ]; then
    [ -f "$file" ] || config_invalid "$file" "no such file"
    src=(--file "$file")
    cfg_source="$file"
  else
    base="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
    git fetch origin "$base" --quiet
    blob="$(blob_at "origin/$base" "$CONFIG_FILE")" || return 0
    src=(--blob "$blob")
    cfg_source="$CONFIG_FILE at origin/$base"
  fi

  # git prints section and key names in lowercase, and subsection names, the globs, as written.
  names="$(git config "${src[@]}" --name-only --list 2>&1)" || config_invalid "$cfg_source" "$names"
  while IFS= read -r name; do
    case "$name" in
      '' | sweep.bot | sweep.mergemethod | sweep.verify) ;;
      dependency.consumerfacing) problems+="$name: a rule needs a glob, as in [dependency \"<glob>\"]"$'\n' ;;
      dependency.*.consumerfacing)
        glob="${name#dependency.}"
        case "${glob%.consumerfacing}" in
          *[[:space:]]*) problems+="$name: a glob can't contain spaces"$'\n' ;;
        esac
        ;;
      *) problems+="$name: unknown key"$'\n' ;;
    esac
  done <<<"$names"

  if value="$(git config "${src[@]}" --get sweep.bot)"; then
    if [ -n "$value" ]; then cfg_bot="$value"; else problems+="sweep.bot: must not be empty"$'\n'; fi
  fi
  if value="$(git config "${src[@]}" --get sweep.mergemethod)"; then
    case "$value" in
      squash | rebase | merge) cfg_merge_method="$value" ;;
      *) problems+="sweep.mergemethod: expected squash, rebase or merge, got \"$value\""$'\n' ;;
    esac
  fi
  if value="$(git config "${src[@]}" --get sweep.verify)"; then
    if [ -n "$value" ]; then cfg_verify="$value"; else problems+="sweep.verify: must not be empty"$'\n'; fi
  fi
  # Exit 1: no rules. Anything else: a value that isn't a boolean, which git names.
  rules="$(git config "${src[@]}" --type=bool --get-regexp '^dependency\..*\.consumerfacing$' 2>&1)" || status=$?
  case "$status" in
    0) ;;
    1) rules="" ;;
    *)
      problems+="$rules"$'\n'
      rules=""
      ;;
  esac
  [ -z "$problems" ] || config_invalid "$cfg_source" "$problems"

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    glob="${value%% *}"
    glob="${glob#dependency.}"
    glob="${glob%.consumerfacing}"
    if [ "${value##* }" = true ]; then cfg_rules+="$glob yes"$'\n'; else cfg_rules+="$glob no"$'\n'; fi
  done <<<"$rules"
}

# What the config's dependency rules say about a dependency: yes or no from the last rule whose glob matches its
# name, or nothing when no rule matches. Globs are shell patterns and match case-insensitively.
config_consumer_facing() {
  local name="$1" glob value result=""
  shopt -s nocasematch
  while read -r glob value; do
    # shellcheck disable=SC2053 # the glob is a pattern on purpose
    if [ -n "$glob" ] && [[ $name == $glob ]]; then result="$value"; fi
  done <<<"$cfg_rules"
  shopt -u nocasematch
  echo "$result"
}

# The checks of a PR as "<bucket>\t<name>" lines, treating "no checks reported" as none. Further arguments go to
# gh pr checks, e.g. --required. Exit 1 on any other error.
_checks() {
  local pr="$1" out err status=0
  shift
  err="$(mktemp)"
  out="$(gh pr checks "$pr" "$@" --json bucket,name --jq '.[] | "\(.bucket)\t\(.name)"' 2>"$err")" || status=$?
  if [ "$status" -ne 0 ] && ! grep -q -E 'no (required )?checks reported' "$err"; then
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s' "$out"
}

# CI state of a PR as one line, "ci=<state> stability=<state> failed=<checks>":
#   ci         pass | fail | pending | none (no checks at all), from the checks that branch protection or rulesets
#              require, or from all checks when none is required
#   stability  Renovate's minimum release age check (renovate/stability-days): pass | pending | absent
#   failed     the failed or cancelled checks, separated by "; "
# `gh pr checks --required` lists only checks that have already reported, so mergeStateStatus stays the merge gate.
ci_summary() {
  local all req checks stability failed ci=pass
  all="$(_checks "$1")" || return 1
  req="$(_checks "$1" --required)" || return 1
  stability="$(awk -F'\t' '$2 == "renovate/stability-days" { s = ($1 == "pending") ? "pending" : "pass" }
    END { print (s == "" ? "absent" : s) }' <<<"$all")"
  # Renovate's own status check isn't CI.
  checks="$(awk -F'\t' 'NF == 2 && $2 != "renovate/stability-days"' <<<"$req")"
  [ -n "$checks" ] || checks="$(awk -F'\t' 'NF == 2 && $2 != "renovate/stability-days"' <<<"$all")"
  failed="$(awk -F'\t' '$1 == "fail" || $1 == "cancel" { printf "%s%s", sep, $2; sep = "; " }' <<<"$checks")"
  if [ -z "$checks" ]; then
    ci=none
  elif [ -n "$failed" ]; then
    ci=fail
  elif awk -F'\t' '$1 == "pending" { found = 1 } END { exit !found }' <<<"$checks"; then
    ci=pending
  fi
  echo "ci=$ci stability=$stability failed=$failed"
}

# The ecosystems of the given changed files (one per line on stdin), one per line: nuget, npm, github-actions or
# other. The skills have a reference for each named one.
ecosystems() {
  local file
  while IFS= read -r file; do
    case "$file" in
      *.csproj | *.fsproj | *.vbproj | *.props | *.targets | *.nuspec | */packages.lock.json | packages.lock.json | \
        global.json | */global.json | *dotnet-tools.json | *packages.config) echo nuget ;;
      package.json | */package.json | *package-lock.json | *npm-shrinkwrap.json | *pnpm-lock.yaml | \
        *pnpm-workspace.yaml | *yarn.lock | .nvmrc | */.nvmrc | .node-version | */.node-version) echo npm ;;
      .github/workflows/* | action.yml | action.yaml | */action.yml | */action.yaml) echo github-actions ;;
      *) echo other ;;
    esac
  done | sort -u
}

# A NuGet project ships to consumers unless it's a test project or marked as not packable, in the project file
# or in a Directory.Build.props above it. A project on the Web SDK (ASP.NET Core) isn't packable either, unless it
# opts in with IsPackable: the SDK defaults IsPackable to false (Microsoft.NET.Sdk.Web.ProjectSystem.props in
# dotnet/sdk). An IsPackable of true in the project file itself wins, as in MSBuild.
packable() {
  local ref="$1" file="$2" dir props content web=no opted=no
  case "/$file" in */test/* | */tests/*) return 1 ;; esac
  local yes='<IsPackable>[[:space:]]*true' not='<IsPackable>[[:space:]]*false|<IsTestProject>[[:space:]]*true'
  content="$(show_file "$ref" "$file" 2>/dev/null || true)"
  grep -q -i -E "$yes" <<<"$content" && return 0
  grep -q -i -E "$not|\"Microsoft\.NET\.Test\.Sdk\"" <<<"$content" && return 1
  grep -q -i -E '(Sdk|Name)[[:space:]]*=[[:space:]]*"Microsoft\.NET\.Sdk\.Web(/[^"]*)?"' <<<"$content" && web=yes
  dir="$(dirname "$file")"
  while :; do
    props="$dir/Directory.Build.props"
    [ "$dir" = . ] && props=Directory.Build.props
    content="$(show_file "$ref" "$props" 2>/dev/null || true)"
    grep -q -i -E "$not" <<<"$content" && return 1
    grep -q -i -E "$yes" <<<"$content" && opted=yes
    [ "$dir" = . ] && break
    dir="$(dirname "$dir")"
  done
  [ "$web" = no ] || [ "$opted" = yes ]
}

# True when the project file references the package without PrivateAssets="all", so its consumers get it too.
ships_reference() {
  local ref="$1" file="$2" dep="$3"
  show_file "$ref" "$file" | tr -d '\r' | awk -v dep="$(printf '%s' "$dep" | tr '[:upper:]' '[:lower:]')" '
    BEGIN { RS = "<[Pp]ackage[Rr]eference" }
    NR > 1 {
      s = tolower($0)
      tag = substr(s, 1, index(s, ">"))
      if (index(tag, "include=\"" dep "\"") == 0) next
      body = (tag ~ /\/>$/) ? tag : substr(s, 1, index(s, "</packagereference>"))
      if (body !~ /privateassets[ \t]*=[ \t]*"all"|<privateassets>[ \t\n]*all/) { found = 1; exit }
    }
    END { exit !found }'
}

# The packages that the package.json files at a ref ship to consumers, one per line: those under dependencies,
# peerDependencies or optionalDependencies of a package.json that isn't private. gh reads the files through
# GitHub's contents API and parses them, so the ref must exist on GitHub, as origin/<base> does.
npm_shipped() {
  local ref="$1" slug="$2" sha file out
  sha="$(git rev-parse "$ref")"
  git ls-tree -r --full-tree --name-only "$ref" | { grep -E '(^|/)package\.json$' || true; } | while IFS= read -r file; do
    # On an HTTP error, gh prints the error body to stdout, so the output counts only on exit 0.
    if out="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$slug/contents/${file// /%20}?ref=$sha" --jq '
      select(.private != true) | [.dependencies, .peerDependencies, .optionalDependencies] | map(. // {} | keys[]) | .[]' \
      2>/dev/null)"; then
      [ -z "$out" ] || printf '%s\n' "$out"
    fi
  done | sort -u
}

# Whether something the repo ships at a ref pulls in a dependency: a packable NuGet project that references it
# without PrivateAssets="all", or a package on the npm_shipped list, which the caller passes third. The config's
# dependency rules come on top of this (renovate-prs.sh).
consumer_facing() {
  local dep="$1" ref="$2" npm="$3" file
  if grep -q -i -x -F -- "$dep" <<<"$npm"; then return 0; fi
  while IFS= read -r file; do
    file="${file#"$ref":}"
    if packable "$ref" "$file" && ships_reference "$ref" "$file" "$dep"; then return 0; fi
  done < <(git grep -l -i -F "\"$dep\"" "$ref" -- '*.csproj' '*.fsproj' '*.vbproj' || true)
  return 1
}
