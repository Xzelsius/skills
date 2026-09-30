#!/usr/bin/env bash
# The repo's settings for the Renovate skills: .github/renovate-sweep.conf in git config syntax, with the default
# for every key the file doesn't set. references/config.md describes the keys.
#
# Usage: config.sh [--config <path>]
#
# Without --config, it reads the file from origin/<default branch> after a fetch, so the committed file counts, not
# a local edit. --config reads a local file instead, e.g. a draft, without any gh or network call.
#
# Output:
#   source=<where the file was read from>    empty when there's no file, so every key has its default
#   bot=<login>
#   mergeMethod=squash|rebase|merge           empty when not set: the sweep discovers it
#   verify=<command>                          empty when not set: the skills discover it
#   dependency=<glob> consumerFacing=yes|no   one line per rule, in file order; the last matching rule wins
# Exit 2: the file isn't valid, with one line per problem on stderr; or bad usage.

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

file=""
if [ "$#" -eq 2 ] && [ "$1" = --config ]; then
  file="$2"
elif [ "$#" -ne 0 ]; then
  sed -n '2,16p' "$0"
  exit 2
fi

load_config "$file"
printf 'source=%s\nbot=%s\nmergeMethod=%s\nverify=%s\n' "$cfg_source" "$cfg_bot" "$cfg_merge_method" "$cfg_verify"
while read -r glob value; do
  if [ -n "$glob" ]; then echo "dependency=$glob consumerFacing=$value"; fi
done <<<"$cfg_rules"
