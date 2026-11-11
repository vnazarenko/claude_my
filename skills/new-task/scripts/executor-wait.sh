#!/usr/bin/env bash
# The coordinator waits for its executor without spending tokens (Bash run_in_background: true).
#   executor-wait.sh <KEY> [idle-minutes, default 25]
# Exits and prints when:
#   0  the executor handed back (prints the report)
#   3  the executor screen did not change for idle-minutes and no handback (stuck at a prompt?)
#   4  the executor session is gone
set -uo pipefail
B="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
key="${1:?KEY}"; idle_min="${2:-25}"
ready="$B/$key.handback.ready"
sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$B/X-$key.env" 2>/dev/null)"
[ -n "$sid" ] || { echo "no executor registry $B/X-$key.env"; exit 4; }
rm -f "$ready"
last=""; since=$(date +%s)
while :; do
  if [ -e "$ready" ]; then
    rm -f "$ready"
    echo "EXECUTOR HANDBACK ($key):"; cat "$B/$key.handback.md"; exit 0
  fi
  scr="$(agtermctl session text --target "$sid" --lines 40 2>/dev/null)" || { echo "EXECUTOR GONE: session $sid closed, no handback"; exit 4; }
  h="$(printf '%s' "$scr" | grep -v -E 'esc to interrupt|[0-9]+s · ' | shasum | cut -c1-12)"
  # a change, or a background shell still running (a vt run), resets the idle clock
  if [ "$h" != "$last" ] || printf '%s' "$scr" | grep -qE '[0-9]+ shells?\b'; then last="$h"; since=$(date +%s); fi
  if [ $(( $(date +%s) - since )) -ge $(( idle_min * 60 )) ]; then
    echo "EXECUTOR IDLE ${idle_min} min without a handback. Last screen:"; printf '%s\n' "$scr" | tail -25; exit 3
  fi
  sleep 30
done
