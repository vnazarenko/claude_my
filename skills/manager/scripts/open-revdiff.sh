#!/usr/bin/env bash
# Open a revdiff overlay in a task session so the USER can review its branch before push / PR.
# Annotations go to $MANAGER_BRIEFS/revdiff-<KEY>.md; the task session reads that file after the
# user closes the overlay and addresses each annotation.
#
# Usage: open-revdiff.sh <KEY> <worktree>      e.g. open-revdiff.sh ABC-76 ~/code/myrepo/.claude/worktrees/ABC-76
set -uo pipefail

briefs="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
key="${1:?usage: open-revdiff.sh <KEY> <worktree>}"
wt="${2:?usage: open-revdiff.sh <KEY> <worktree>}"
env="$briefs/$key.env"
[ -f "$env" ] || { echo "no registry entry $env"; exit 1; }
[ -d "$wt" ] || { echo "no worktree $wt"; exit 1; }
sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$env")"
out="$briefs/revdiff-$key.md"

git -C "$wt" fetch -q origin main 2>/dev/null
base="$(git -C "$wt" merge-base origin/main HEAD)" || { echo "no merge-base with origin/main"; exit 1; }

# Find the window that holds the session (--target resolves only in the given window).
for w in $(agtermctl window list --json 2>/dev/null | jq -r '.result.windows[]? | select(.open) | .id'); do
  if agtermctl tree --json --window "$w" 2>/dev/null | jq -e --arg s "$sid" '[.. | objects | select(.id? == $s)] | length > 0' >/dev/null; then
    agtermctl session overlay open --target "$sid" --window "$w" --pane primary --cwd "$wt" \
      "revdiff --output $out $base HEAD" >/dev/null && {
      echo "revdiff open in $key ($sid), base ${base:0:9}, annotations -> $out"
      echo "$(date '+%Y-%m-%d %H:%M') | $key | revdiff overlay opened for the user, annotations -> $out" >> "$briefs/manager-log.md"
      exit 0; }
  fi
done
echo "session $sid not found in any open window"; exit 1
