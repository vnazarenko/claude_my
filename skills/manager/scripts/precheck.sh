#!/usr/bin/env bash
# Cheap check before a manager tick: no agent, no tokens beyond the call. Did anything the tick acts
# on change since the last tick started? Prints ONE line:
#   CHANGED: <what>   launch the tick
#   SAME: ...         skip this fire
#   BUSY: ...         a tick is still running; skip this fire
# It compares with the snapshot tick.sh saved: each watched session's screen (a WORKING session
# counts as no change — the tick leaves it alone), the decisions / needs / holds / long-lived files
# (saved at `tick.sh done`), and the merged PRs of the registered tickets. It forces a tick when the
# last one started PRECHECK_MAX_MIN (default 60) minutes ago or more.
# Why: token audit 2026-11-03 — 40% of ticks (~260k tokens each) found nothing to do.
set -uo pipefail
briefs="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
. "$HOME/.claude/skills/manager/scripts/lib-screens.sh"
max="${PRECHECK_MAX_MIN:-60}"

lock="$briefs/.manager-tick.lock"
if [ -d "$lock" ] && [ -z "$(find "$lock" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then
  echo "BUSY: a tick is still running"; exit 0
fi
snap="$briefs/.tick-screens"
[ -f "$snap" ] || { echo "CHANGED: no snapshot from an earlier tick"; exit 0; }
age=$(( ( $(date +%s) - $(stat -f %m "$snap") ) / 60 ))
[ "$age" -lt "$max" ] || { echo "CHANGED: the last tick started ${age} min ago"; exit 0; }

tree="$(agterm_tree)"
[ -n "$tree" ] || { echo "CHANGED: agterm is not answering"; exit 0; }

changed=()
while IFS=$'\t' read -r name sid; do
  [ -n "$name" ] || continue
  if [ "$sid" = - ]; then tok=gone
  else tok="$(token_of "$(session_status "$tree" "$sid")" "$(screen_text "$sid" | tail -n 22)")"; fi
  [ "$tok" = working ] && continue
  [ "$tok" = "$(prev_token "$name")" ] || changed+=("$name")
done < <(watched_sessions "$tree")

[ "$(files_hash)" = "$(cat "$briefs/.tick-files" 2>/dev/null)" ] || changed+=("manager files")
[ "$(merged_prs)" = "$(cat "$briefs/.tick-prs" 2>/dev/null)" ] || changed+=("a ticket's PR merged")

if [ ${#changed[@]} -gt 0 ]; then
  ( IFS=','; echo "CHANGED: ${changed[*]}" )
else
  echo "SAME: nothing to act on since the last tick (${age} min ago)"
fi
