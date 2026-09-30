#!/usr/bin/env bash
# Runs one of the read-only scripts of the sibling skill renovate-sweep.
#
# Usage: sweep.sh detect|config [args ...]
#
# renovate-sweep-setup has no scripts of its own. Going through this file keeps its commands free of "..", so
# that the commands its allowed-tools pre-approve match, and it refuses every other script.
# Exit 2 with the install command when renovate-sweep isn't installed next to this skill.

set -euo pipefail

dir="$(cd "$(dirname "$0")/../../renovate-sweep/scripts" 2>/dev/null && pwd)" || {
  echo "renovate-sweep-setup needs the renovate-sweep skill next to it. Install both, e.g.:" >&2
  echo "  npx skills add xzelsius/skills -s renovate-sweep -s renovate-sweep-setup" >&2
  echo "or install the renovate plugin from the xzelsius-skills marketplace." >&2
  exit 2
}

case "${1:-}" in
  detect | config) ;;
  *)
    sed -n '2,8p' "$0"
    exit 2
    ;;
esac
name="$1"
shift
exec bash "$dir/$name.sh" "$@"
