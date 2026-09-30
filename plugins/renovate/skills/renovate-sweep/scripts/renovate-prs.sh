#!/usr/bin/env bash
# Inventory of the open Renovate PRs, or of the given PR numbers, as one block of lines per PR.
#
# Usage: renovate-prs.sh [--config <path>] [pr-number ...]
#
# Run it from a checkout of the repo. The bot login and the dependency rules come from the config (config.sh).
#
#   pr=<n> draft=yes|no base=<branch> branch=<branch> head=<sha>
#     title=<title>
#     url=<url>
#     update=<type> zeroVer=yes|no consumerFacing=yes|no ecosystems=<list>
#     ci=pass|fail|pending|none stability=pass|pending|absent failed=<checks>
#     mergeState=<state> review=<decision> autoMerge=yes|no rebasing=<setting> modifiedByOthers=yes|no
#     dep=<name> from=<version> to=<version> update=<type> consumerFacing=yes|no      one line per dependency
#
# update: major, minor, patch, digest, pin, lockfile or unknown; the PR's is the highest of its dependencies'.
# zeroVer: a major, minor or patch update within 0.x, which semver allows to break.
# consumerFacing: something the repo ships at origin/<base> pulls the dependency in (consumer_facing in lib.sh),
#   unless a dependency rule of the config says otherwise; the PR's is yes when any dependency's is.
# ecosystems: nuget, npm, github-actions or other, from the changed files.
# ci, stability, failed: see ci_summary in lib.sh. mergeState, review: GitHub's mergeStateStatus and reviewDecision.
# rebasing: Renovate's rebase setting from the PR body: behind-base-branch, conflicted, never or unknown.
# modifiedByOthers: the PR has a commit by anyone but the bot.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

cfg="" prs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      cfg="$2"
      shift 2
      ;;
    *)
      prs+=("$1")
      shift
      ;;
  esac
done

load_config "$cfg"
slug="$(repo_slug)"
if [ "${#prs[@]}" -eq 0 ]; then
  list="$(gh pr list --state open --author "$(author_filter "$cfg_bot")" --limit 100 --json number --jq '.[].number')"
  while IFS= read -r n; do
    if [ -n "$n" ]; then prs+=("$n"); fi
  done <<<"$list"
fi
if [ "${#prs[@]}" -eq 0 ]; then
  echo "no open PRs by $cfg_bot"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The values of one field of the current PR ($fields), one per line.
values() {
  awk -v k="$1" 'index($0, k "\t") == 1 { print substr($0, length(k) + 2) }' <<<"$fields"
}

# Renovate's "| Package | ... |" table in the PR body (on stdin) → one "dep=<name> from=<v> to=<v> update=<type>"
# line per row, then "summary <update> <zeroVer>" for the whole PR, whose title is the argument.
parse_table() {
  awk -F'|' -v title="$1" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function num(s) { return match(s, /^[0-9]+/) ? substr(s, 1, RLENGTH) + 0 : 0 }
    function major(v) { sub(/^v/, "", v); return num(v) }
    function minor(v, parts) { sub(/^v/, "", v); split(v, parts, "."); return num(parts[2]) }
    function sha(s) { return s ~ /^[0-9a-f]+$/ && length(s) >= 7 && length(s) <= 40 }
    function utype(update, from, to) {
      update = tolower(update)
      if (update == "pindigest") return "pin"
      if (update != "") return update
      if (sha(from) && sha(to)) return "digest"
      if (major(from) != major(to)) return "major"
      if (minor(from) != minor(to)) return "minor"
      return "patch"
    }
    BEGIN { rank["major"] = 4; rank["minor"] = 3; rank["patch"] = 2; rank["digest"] = 1; rank["pin"] = 1; rank["lockfile"] = 1 }
    finished { next }
    /^\| *Package *\|/ {
      for (i = 1; i <= NF; i++) {
        h = trim($i)
        if (h == "Update") uc = i
        if (h == "Change") cc = i
      }
      intable = 1
      next
    }
    intable && /^\|[-| ]+\|$/ { next }
    intable && /^\|/ {
      name = trim($2)
      if (match(name, /\[[^]]+\]/)) name = substr(name, RSTART + 1, RLENGTH - 2)
      change = $cc; from = ""; to = ""
      if (match(change, /`[^`]+`/)) { from = substr(change, RSTART + 1, RLENGTH - 2); change = substr(change, RSTART + RLENGTH) }
      if (match(change, /`[^`]+`/)) to = substr(change, RSTART + 1, RLENGTH - 2)
      u = utype(uc > 0 ? trim($uc) : "", from, to)
      print "dep=" name " from=" from " to=" to " update=" u
      r = (u in rank) ? rank[u] : 0
      if (deps++ == 0 || r > best_rank) { best = u; best_rank = r }
      if ((u == "major" || u == "minor" || u == "patch") && major(from) == 0 && major(to) == 0) zero = 1
      next
    }
    intable { finished = 1 }
    END {
      t = tolower(title)
      if (t ~ /lock file maintenance/) u = "lockfile"
      else if (t ~ /^[^:]+: pin /) u = "pin"
      else if (deps == 0) u = (t ~ /digest/) ? "digest" : "unknown"
      else u = best
      print "summary " u " " (zero ? "yes" : "no")
    }'
}

fetched=" "
for pr in "${prs[@]}"; do
  # One "<field>\t<value>" line per value; the body comes last, one "body" line per line of it.
  fields="$(gh pr view "$pr" --json number,isDraft,baseRefName,headRefName,headRefOid,title,url,mergeStateStatus,reviewDecision,autoMergeRequest,commits,files,body --jq '
    "number\t\(.number)", "draft\t\(if .isDraft then "yes" else "no" end)", "base\t\(.baseRefName)",
    "branch\t\(.headRefName)", "head\t\(.headRefOid)", "title\t\(.title)", "url\t\(.url)",
    "mergeState\t\(.mergeStateStatus)", "review\t\(.reviewDecision // "")",
    "autoMerge\t\(if .autoMergeRequest then "yes" else "no" end)",
    (.commits[].authors[].login | "author\t\(.)"), (.files[].path | "file\t\(.)"),
    (.body // "" | gsub("\r"; "") | split("\n")[] | "body\t\(.)")')"
  base="$(values base)"
  case "$fetched" in
    *" $base "*) ;;
    *)
      git fetch origin "$base" --quiet
      fetched="$fetched$base "
      ;;
  esac
  # What the package.json files ship, once per base commit.
  sha="$(git rev-parse "origin/$base")"
  [ -f "$tmp/npm-$sha" ] || npm_shipped "origin/$base" "$slug" >"$tmp/npm-$sha"
  npm="$(cat "$tmp/npm-$sha")"

  deps="" consumer=no summary="unknown no"
  while IFS= read -r line; do
    case "$line" in
      dep=*)
        name="${line#dep=}"
        name="${name%% *}"
        cf="$(config_consumer_facing "$name")"
        if [ -z "$cf" ]; then
          cf=no
          if consumer_facing "$name" "origin/$base" "$npm"; then cf=yes; fi
        fi
        if [ "$cf" = yes ]; then consumer=yes; fi
        deps+="  $line consumerFacing=$cf"$'\n'
        ;;
      summary\ *) summary="${line#summary }" ;;
    esac
  done <<<"$(values body | parse_table "$(values title)")"

  others="$(awk -v bot="$cfg_bot" 'index($0, "author\t") == 1 && substr($0, 8) != bot { o = 1 }
    END { print (o ? "yes" : "no") }' <<<"$fields")"
  rebasing="$(awk 'index($0, "body\t") == 1 && w == "" && match($0, /\*\*Rebasing\*\*: [^,]*/) {
      w = substr($0, RSTART + 14, RLENGTH - 14)
    }
    END {
      if (w ~ /^Whenever PR is behind/) print "behind-base-branch"
      else if (w ~ /^Whenever PR becomes conflicted/) print "conflicted"
      else if (w ~ /^Never/) print "never"
      else print "unknown"
    }' <<<"$fields")"

  printf 'pr=%s draft=%s base=%s branch=%s head=%s\n' "$(values number)" "$(values draft)" "$base" "$(values branch)" "$(values head)"
  printf '  title=%s\n  url=%s\n' "$(values title)" "$(values url)"
  printf '  update=%s zeroVer=%s consumerFacing=%s ecosystems=%s\n' "${summary% *}" "${summary#* }" "$consumer" \
    "$(values file | ecosystems | paste -sd, -)"
  printf '  %s\n' "$(ci_summary "$pr")"
  printf '  mergeState=%s review=%s autoMerge=%s rebasing=%s modifiedByOthers=%s\n' "$(values mergeState)" \
    "$(values review)" "$(values autoMerge)" "$rebasing" "$others"
  printf '%s\n' "$deps"
done
