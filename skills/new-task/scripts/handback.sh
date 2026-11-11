#!/usr/bin/env bash
# The executor's last step: mark its report ready for the coordinator.
#   handback.sh <KEY>      (the report is ~/.claude/task-briefs/<KEY>.handback.md)
# executor-wait.sh in the coordinator session sees the mark and wakes the coordinator.
set -euo pipefail
B="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
key="${1:?KEY}"
f="$B/$key.handback.md"
[ -s "$f" ] || { echo "write $f first (STATUS / Done / Commits / Tests / Decisions / Open)" >&2; exit 1; }
grep -qE '^STATUS: (done|blocked|question)' "$f" || { echo "$f needs a first line STATUS: done|blocked|question" >&2; exit 1; }
date +%s >"$B/$key.handback.ready"
echo "$(date '+%Y-%m-%d %H:%M') | $key | executor handback: $(head -1 "$f")" >>"$B/manager-log.md"
echo "handed back to the coordinator: $(head -1 "$f")"
