#!/usr/bin/env bash
# Show every new-task task whose agterm session is alive: key, Jira status, end of its screen.
# Then the manager's holds file.
#
# Usage: status.sh [lines]   (screen lines per task, default 22)
set -uo pipefail

n="${1:-22}"
briefs="$HOME/.claude/task-briefs"
# Same jira.py as new-task, without repeating its path here.
JIRA_PY="${JIRA_PY:-$(sed -n 's/^JIRA_PY="\${JIRA_PY:-\(.*\)}"$/\1/p' "$HOME/.claude/skills/new-task/scripts/start-task.sh")}"

live="$(agtermctl tree --json 2>/dev/null | jq -r '.. | objects | select(.cwd?) | .id')"
gone=()
for f in "$briefs"/*.env; do
  [ -f "$f" ] || continue
  key="$(sed -n 's/^KEY=//p' "$f")"
  sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$f")"
  if [ -z "$sid" ] || ! grep -qx "$sid" <<<"$live"; then gone+=("$key"); continue; fi
  st="?"
  [ -f "$JIRA_PY" ] && st="$(python3 "$JIRA_PY" get "$key" 2>/dev/null | jq -r '.status // "?"')"
  echo "##### $key sid=$sid jira=$st"
  # Drop blank lines and the prompt box frame; keep the conversation tail.
  agtermctl session text --target "$sid" --lines 60 2>&1 \
    | grep -v '^[[:space:]]*$' | grep -vE '^[[:space:]]*(─|⏵⏵)|Update installed' | tail -n "$n"
done
[ ${#gone[@]} -eq 0 ] || echo "##### no session: ${gone[*]}"
if [ -s "$briefs/manager-holds.md" ]; then
  echo "##### holds"
  cat "$briefs/manager-holds.md"
fi
