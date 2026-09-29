#!/usr/bin/env bash
# Inventory of open Renovate PRs (or the given PR numbers) with their classification, as a JSON array.
#
# Usage: renovate-prs.sh [--bot <login>] [pr-number ...]
# Run it from a checkout of the repo: it reads origin/<base> to decide whether a dependency is consumer-facing.
#
# Per PR: number, title, url, draft, base, branch, head, deps [{name, type, from, to, update, consumerFacing}],
# updateType (highest of the deps: major > minor > patch > digest/pin/lockfile), zeroVer, ecosystems (from the
# changed files), consumerFacing, ci {ci, scope, failed, pending, stability}, behindBy, mergeState,
# reviewDecision, autoMerge, rebasing (behind-base-branch | conflicted | never | unknown, from the PR body),
# rebaseCheckbox (unchecked | checked | absent), modifiedByOthers (a commit by anyone but the bot).

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

bot="$DEFAULT_BOT"
prs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bot)
      bot="$2"
      shift 2
      ;;
    *)
      prs+=("$1")
      shift
      ;;
  esac
done

slug="$(repo_slug)"
if [ "${#prs[@]}" -eq 0 ]; then
  while IFS= read -r n; do prs+=("$n"); done < <(gh pr list --state open --author "$(author_filter "$bot")" --limit 100 --json number --jq '.[].number')
fi
if [ "${#prs[@]}" -eq 0 ]; then
  echo "[]"
  exit 0
fi

# A NuGet project ships to consumers unless it's a test project or marked as not packable, in the project file
# or in a Directory.Build.props above it.
packable() {
  local ref="$1" file="$2" dir props
  case "/$file" in */test/* | */tests/*) return 1 ;; esac
  local not='<IsPackable>[[:space:]]*false|<IsTestProject>[[:space:]]*true'
  git show "$ref:$file" | grep -q -i -E "$not|\"Microsoft\.NET\.Test\.Sdk\"" && return 1
  dir="$(dirname "$file")"
  while :; do
    props="$dir/Directory.Build.props"
    [ "$dir" = . ] && props=Directory.Build.props
    git show "$ref:$props" 2>/dev/null | grep -q -i -E "$not" && return 1
    [ "$dir" = . ] && break
    dir="$(dirname "$dir")"
  done
  return 0
}

# True when the project file references the package without PrivateAssets="all", so its consumers get it too.
ships_reference() {
  local ref="$1" file="$2" dep="$3"
  git show "$ref:$file" | tr -d '\r' | awk -v dep="$(printf '%s' "$dep" | tr '[:upper:]' '[:lower:]')" '
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

# A dependency is consumer-facing when something this repo ships pulls it in: a packable NuGet project, or a
# package.json that isn't private (dependencies, peerDependencies, optionalDependencies). A repo's agent
# instructions can widen or narrow this.
consumer_facing() {
  local dep="$1" ref="$2" file
  while IFS= read -r file; do
    file="${file#"$ref":}"
    packable "$ref" "$file" && ships_reference "$ref" "$file" "$dep" && return 0
  done < <(git grep -l -i -F "\"$dep\"" "$ref" -- '*.csproj' '*.fsproj' '*.vbproj' || true)
  while IFS= read -r file; do
    git show "$ref:$file" | jq -e --arg d "$dep" '
      (.private != true)
      and ([.dependencies, .peerDependencies, .optionalDependencies] | map(. // {} | has($d)) | any)' \
      >/dev/null 2>&1 && return 0
  done < <(git ls-tree -r --name-only "$ref" | grep -E '(^|/)package\.json$' || true)
  return 1
}

# PR body → TSV rows (name, type, from, to, update) from Renovate's "| Package | ... |" table.
parse_table() {
  awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\| *Package *\|/ {
      for (i = 1; i <= NF; i++) {
        h = trim($i)
        if (h == "Update") uc = i
        if (h == "Change") cc = i
        if (h == "Type") tc = i
      }
      intable = 1; next
    }
    intable && /^\|[-| ]+\|$/ { next }
    intable && /^\|/ {
      name = $2
      if (match(name, /\[[^]]+\]/)) name = substr(name, RSTART + 1, RLENGTH - 2)
      change = $cc; from = ""; to = ""
      if (match(change, /`[^`]+`/)) { from = substr(change, RSTART + 1, RLENGTH - 2); change = substr(change, RSTART + RLENGTH) }
      if (match(change, /`[^`]+`/)) { to = substr(change, RSTART + 1, RLENGTH - 2) }
      update = (uc > 0) ? trim($uc) : ""
      type = (tc > 0) ? trim($tc) : ""
      printf "%s\t%s\t%s\t%s\t%s\n", trim(name), type, from, to, update
      next
    }
    intable { exit }
  '
}

# Ecosystems of the changed files, one per line.
ecosystems() {
  local file
  while IFS= read -r file; do
    case "$file" in
      *.csproj | *.fsproj | *.vbproj | *.props | *.targets | *.nuspec | */packages.lock.json | packages.lock.json | \
        global.json | */global.json | *dotnet-tools.json | *packages.config) echo nuget ;;
      package.json | */package.json | *package-lock.json | *npm-shrinkwrap.json | *pnpm-lock.yaml | \
        *pnpm-workspace.yaml | *yarn.lock | .nvmrc | */.nvmrc | .node-version | */.node-version) echo npm ;;
      .github/workflows/* | action.yml | action.yaml | */action.yml | */action.yaml) echo github-actions ;;
      *Dockerfile* | *.dockerfile | *docker-compose*.yml | *docker-compose*.yaml | compose*.yml | compose*.yaml) echo docker ;;
      *.tf | *.terraform.lock.hcl) echo terraform ;;
      renovate.json | renovate.json5 | .renovaterc* | .github/renovate.json*) echo renovate-config ;;
      *) echo other ;;
    esac
  done | sort -u
}

# shellcheck disable=SC2016
jq_classify='
def ver: ltrimstr("v") | split(".") | map((capture("^(?<n>[0-9]+)").n | tonumber)? // 0);
def utype:
  if .update != "" then (.update | ascii_downcase | if . == "pindigest" then "pin" else . end)
  elif (.from | test("^[0-9a-f]{7,40}$")) and (.to | test("^[0-9a-f]{7,40}$")) then "digest"
  else (.from | ver) as $f | (.to | ver) as $t
    | if ($f[0] // 0) != ($t[0] // 0) then "major"
      elif ($f[1] // 0) != ($t[1] // 0) then "minor"
      else "patch" end
  end;
def rank: {"major": 4, "minor": 3, "patch": 2, "digest": 1, "pin": 1, "lockfile": 1}[.] // 0;
'

fetched=""
out="[]"
for pr in "${prs[@]}"; do
  json="$(gh pr view "$pr" --json number,title,url,isDraft,baseRefName,headRefName,headRefOid,body,files,mergeStateStatus,reviewDecision,autoMergeRequest,commits)"
  base="$(jq -r .baseRefName <<<"$json")"
  case " $fetched " in
    *" $base "*) ;;
    *)
      git fetch origin "$base" --quiet
      fetched="$fetched $base"
      ;;
  esac
  base_sha="$(git rev-parse "origin/$base")"

  deps="[]"
  while IFS=$'\t' read -r name type from to update; do
    [ -z "$name" ] && continue
    cf=false
    consumer_facing "$name" "origin/$base" && cf=true
    deps="$(jq --arg n "$name" --arg ty "$type" --arg f "$from" --arg t "$to" --arg u "$update" --argjson cf "$cf" \
      "$jq_classify"' . + [ {name: $n, type: $ty, from: $f, to: $t, update: $u, consumerFacing: $cf} | .update = utype ]' <<<"$deps")"
  done < <(jq -r .body <<<"$json" | parse_table)

  ecos="$(jq -r '.files[].path' <<<"$json" | ecosystems | jq -R . | jq -s -c .)"
  head="$(jq -r .headRefOid <<<"$json")"
  behind="$(gh api "repos/$slug/compare/$base_sha...$head" --jq .behind_by 2>/dev/null || echo null)"
  ci="$(ci_summary "$pr")"

  entry="$(jq --argjson deps "$deps" --argjson ecos "$ecos" --argjson ci "$ci" --argjson behind "$behind" --arg bot "$bot" \
    "$jq_classify"'
    (.title | ascii_downcase) as $t
    | {
        number, title, url,
        draft: .isDraft,
        base: .baseRefName,
        branch: .headRefName,
        head: .headRefOid,
        deps: $deps,
        updateType: (
          if ($t | test("lock file maintenance")) then "lockfile"
          elif ($t | test("^[^:]+: pin ")) then "pin"
          elif ($deps | length) == 0 then (if ($t | test("digest")) then "digest" else "unknown" end)
          else ($deps | max_by(.update | rank) | .update) end),
        zeroVer: ($deps | any(.[]; (.update == "major" or .update == "minor" or .update == "patch")
          and (.from | ver | .[0]) == 0 and (.to | ver | .[0]) == 0)),
        ecosystems: $ecos,
        consumerFacing: ($deps | any(.[]; .consumerFacing)),
        ci: $ci,
        behindBy: $behind,
        mergeState: .mergeStateStatus,
        reviewDecision,
        autoMerge: (.autoMergeRequest != null),
        rebasing: (
          (.body | capture("\\*\\*Rebasing\\*\\*: (?<w>[^,\n]+)").w // "") as $w
          | if ($w | startswith("Whenever PR is behind")) then "behind-base-branch"
            elif ($w | startswith("Whenever PR becomes conflicted")) then "conflicted"
            elif ($w | startswith("Never")) then "never"
            else "unknown" end),
        rebaseCheckbox: (
          if (.body | test("- \\[ \\] <!-- rebase-check -->")) then "unchecked"
          elif (.body | test("- \\[[xX]\\] <!-- rebase-check -->")) then "checked"
          else "absent" end),
        modifiedByOthers: ([ .commits[].authors[].login ] | any(.[]; . != $bot))
      }' <<<"$json")"
  out="$(jq --argjson e "$entry" '. + [$e]' <<<"$out")"
done

jq . <<<"$out"
