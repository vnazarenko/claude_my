#!/usr/bin/env bash
# Report a finished deploy to the manager, then start a tick at once.
#   deployed.sh <repo path> <sha> [source]
# Any deploy tool can call it at its end (run it on this Mac, never on the server). The tick then
# types /task-cleanup into every waiting session whose merged PRs are all inside <sha>.
# Capistrano needs no call: the tick reads <repo>/log/capistrano.log ("Branch X (at SHA) deployed").
set -euo pipefail
repo="${1:?repo path}"; sha="${2:?sha}"; src="${3:-manual}"
common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"  # main checkout, also from a worktree
top="$(dirname "$common")"
full="$(git -C "$top" rev-parse --verify -q "$sha^{commit}" || { git -C "$top" fetch -q origin && git -C "$top" rev-parse --verify "$sha^{commit}"; })"
printf '%s | %s | %s | %s\n' "$(date '+%F %T')" "$top" "$full" "$src" >> "$HOME/.claude/manager-deploys.log"
echo "recorded: $top $full ($src)"
launchctl kickstart "gui/$(id -u)/com.$(id -un).manager-tick" 2>/dev/null || true
