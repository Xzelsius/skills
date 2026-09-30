#!/usr/bin/env bash
# What discovery finds in a repo, for renovate-sweep-setup: the facts it turns into questions and a config file. It
# reads the default branch after a fetch, as the sweep does, and writes nothing.
#
# Usage: detect.sh
#
# Output, one line each; lists are comma-separated, and empty when there's nothing:
#   defaultBranch=<branch>
#   mergeMethods=<methods>      the methods the repo allows, of squash, rebase and merge in that order; unknown when
#                               the gh token can't read the repo's merge settings
#   bots=<login>:<prs> ...      the authors of PRs from renovate/ branches, most PRs first
#   agentInstructions=<files>   where a verification command can come from: the agent instructions, build scripts,
#   buildScripts=<files>        the package manager of the root package.json, and the workflows that run on pull
#   packageManager=<manager>    requests
#   prWorkflows=<files>
#   committedConfig=yes|no      whether .github/renovate-sweep.conf exists on the default branch
#   localConfig=yes|no          whether it exists in the checkout
#   hint=<kind> files=<files> names=<names>
#                               a case that consumer-facing discovery misses, one line each: shared-package-reference,
#                               dotnet-sdk, published-action or bundled-npm (references/config.md explains them)
# Run it from the main checkout.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ "$#" -eq 0 ] || {
  sed -n '2,21p' "$0"
  exit 2
}

slug="$(repo_slug)"
# The merge settings are null for a token that can't read them, e.g. with read access only. Never guess then.
info="$(gh api "repos/$slug" --jq '.default_branch,
  if .allow_squash_merge == null or .allow_rebase_merge == null or .allow_merge_commit == null then "unknown"
  else [ (if .allow_squash_merge then "squash" else empty end), (if .allow_rebase_merge then "rebase" else empty end),
    (if .allow_merge_commit then "merge" else empty end) ] | join(",") end')"
{
  read -r base
  read -r merge
} <<<"$info"
git fetch origin "$base" --quiet
ref="origin/$base"
sha="$(git rev-parse "$ref")"
tree="$(git ls-tree -r --full-tree --name-only "$ref")"

# gh lists a GitHub App as app/<name>; its commits come from <name>[bot], the login the config uses.
bots="$(gh pr list --state all --limit 200 --json author,headRefName --jq '
  [ .[] | select(.headRefName | startswith("renovate/")) | .author.login
    | if startswith("app/") then "\(ltrimstr("app/"))[bot]" else . end ]
  | group_by(.) | map({login: .[0], prs: length}) | sort_by(-.prs) | map("\(.login):\(.prs)") | join(" ")')"

# The ref's files that match an extended regex, comma-separated.
files() {
  { grep -E "$1" <<<"$tree" || true; } | paste -sd, -
}

manager=""
if grep -q -x 'package.json' <<<"$tree"; then
  manager=npm
  if grep -q -x 'pnpm-lock.yaml' <<<"$tree"; then manager=pnpm; fi
  if grep -q -x 'yarn.lock' <<<"$tree"; then manager=yarn; fi
  if grep -q -x -E 'bun\.lockb?' <<<"$tree"; then manager=bun; fi
fi
workflows="$({ git grep -l -E 'pull_request' "$ref" -- '.github/workflows/*.yml' '.github/workflows/*.yaml' || true; } \
  | sed "s#^$ref:##" | paste -sd, -)"
committed=no checkout=no
if blob_at "$ref" "$CONFIG_FILE" >/dev/null; then committed=yes; fi
if [ -f "$(git rev-parse --show-toplevel)/$CONFIG_FILE" ]; then checkout=yes; fi

printf '%s\n' "defaultBranch=$base" "mergeMethods=$merge" "bots=$bots" \
  "agentInstructions=$(files '^(AGENTS\.md|CLAUDE\.md|\.claude/CLAUDE\.md|\.github/copilot-instructions\.md)$')" \
  "buildScripts=$(files '^(build\.(sh|ps1|cmd|cake)|Makefile|justfile|Taskfile\.ya?ml|\.nuke/parameters\.json)$')" \
  "packageManager=$manager" "prWorkflows=$workflows" "committedConfig=$committed" "localConfig=$checkout"

# Package references in shared .props and .targets files that can ship, as "<file>\t<name>" lines. A reference
# doesn't ship with PrivateAssets="all", as an attribute or a child element, or in an ItemGroup, or with a condition,
# for test projects only. Neither does a GlobalPackageReference, which this doesn't match: NuGet always adds those
# with PrivateAssets="All".
shared="$({ git grep -l -i -F '<PackageReference' "$ref" -- '*.props' '*.targets' || true; } | while IFS= read -r file; do
  file="${file#"$ref":}"
  show_file "$ref" "$file" | tr -d '\r' | awk -v file="$file" '
    function test_only(s) { return s ~ /condition="[^"]*istestproject[^"]*==[^"]*true/ }
    {
      low = tolower($0)
      if (!inref) {
        if (low ~ /<itemgroup([ \t>]|$)/) group_test = test_only(low)
        if (low ~ /<\/itemgroup>/) group_test = 0
        if (low !~ /<packagereference([ \t>]|$)/) next
        inref = 1; raw = ""
      }
      # The whole element, which can span lines, up to its end.
      raw = raw " " $0
      if (low !~ /\/>[ \t]*$/ && low !~ /<\/packagereference>/) next
      inref = 0
      text = tolower(raw)
      if (group_test || test_only(text)) next
      if (text ~ /privateassets[ \t]*=[ \t]*"all"/ || text ~ /<privateassets>[ \t]*all[ \t]*<\/privateassets>/) next
      if (!match(raw, /[Ii]nclude[ \t]*=[ \t]*"[^"$@]+"/)) next
      name = substr(raw, RSTART, RLENGTH); sub(/^[^"]*"/, "", name); sub(/"$/, "", name)
      print file "\t" name
    }'
done)"
if [ -n "$shared" ]; then
  echo "hint=shared-package-reference files=$(cut -f1 <<<"$shared" | sort -u | paste -sd, -)" \
    "names=$(cut -f2 <<<"$shared" | sort -u | paste -sd, -)"
fi

# A new SDK major matters to consumers when the repo ships NuGet packages, i.e. has a packable project (lib.sh).
ships=no
while IFS= read -r file; do
  if [ -n "$file" ] && packable "$ref" "$file"; then
    ships=yes
    break
  fi
done <<<"$(grep -E '\.(cs|fs|vb)proj$' <<<"$tree" || true)"
globals="$(files '(^|/)global\.json$')"
if [ -n "$globals" ] && [ "$ships" = yes ]; then echo "hint=dotnet-sdk files=$globals names=dotnet-sdk"; fi

# The uses: references of an action the repo publishes, except its own local actions.
for action in action.yml action.yaml; do
  if ! grep -q -x "$action" <<<"$tree"; then continue; fi
  uses="$(show_file "$ref" "$action" | { grep -o -E 'uses:[[:space:]]*[^[:space:]#]+' || true; } \
    | sed -E 's/^uses:[[:space:]]*//; s/@.*$//' | { grep -v '^\./' || true; } | sort -u | paste -sd, -)"
  if [ -n "$uses" ]; then echo "hint=published-action files=$action names=$uses"; fi
done

# Published npm packages that build with a bundler: the packages they bundle ship inside their output.
bundlers='^(tsup|tsdown|rollup|esbuild|webpack|vite|parcel|microbundle|unbuild|@rollup/.+)$'
while IFS= read -r file; do
  [ -n "$file" ] || continue
  # On an HTTP error, gh prints the error body to stdout, so the output counts only on exit 0.
  if found="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$slug/contents/${file// /%20}?ref=$sha" --jq "
    select(.private != true) | .devDependencies // {} | keys | map(select(test(\"$bundlers\"))) | join(\",\")" \
    2>/dev/null)" && [ -n "$found" ]; then
    echo "hint=bundled-npm files=$file names=$found"
  fi
done <<<"$(grep -E '(^|/)package\.json$' <<<"$tree" || true)"
