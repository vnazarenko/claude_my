#!/usr/bin/env bash
# Type a message into a task session's Claude pane and press Enter.
#
# Usage: say.sh <KEY|agterm-session-id> "<text>"
#   KEY (e.g. KAN-123) is looked up in ~/.claude/task-briefs/<KEY>.env.
#
# It refuses (exit 2) while the user works in that session: the user can only type into the
# session they are looking at, and typing there too would mix both texts into one message
# (it happened once). FORCE=1 skips the check.
set -euo pipefail

# agterm's control socket can stop answering; never let one call hang the tick.
at() { if command -v timeout >/dev/null 2>&1; then timeout 10 agtermctl "$@"; else agtermctl "$@"; fi; }

target="${1:?KEY or agterm session id required}"
text="${2:?message text required}"
# MANAGER_BRIEFS lets a second manager (e.g. Nowsta) keep its own registry and memory files.
briefs="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"

if [[ "$target" =~ ^[A-Z]+-[0-9]+$ ]]; then
  reg="$briefs/$target.env"
  [ -f "$reg" ] || { echo "ERROR: no registry $reg"; exit 1; }
  target="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$reg")"
  [ -n "$target" ] || { echo "ERROR: no AGTERM_SESSION_ID in $reg"; exit 1; }
else
  reg="$(grep -l "^AGTERM_SESSION_ID=$target\$" "$briefs"/*.env 2>/dev/null | head -1 || true)"
fi

if [ "${FORCE:-}" != "1" ]; then
  viewing="$(at tree --json 2>/dev/null | jq -r --arg id "$target" \
    '[.result.tree.workspaces[]? | select(.active) | .sessions[]? | select(.id == $id and .active)] | length')"
  [ -n "$viewing" ] || { echo "ERROR: agterm is not answering; nothing sent. Try at the next tick."; exit 3; }
  if [ "$viewing" != "0" ]; then
    # Text on the input line of a session the user is looking at may be their half-typed message.
    input="$(at session text --target "$target" --pane primary --lines 15 2>/dev/null \
      | grep '^❯' | tail -1 | sed 's/^❯[[:space:]]*//')" || true
    if [ -n "$input" ]; then
      echo "SKIPPED: the user is in this session and its input line has text. Try at the next tick."
      exit 2
    fi
    # A message from the user in the last 10 minutes means they are working there right now.
    sess=""; log=""
    [ -n "${reg:-}" ] && sess="$(sed -n 's/^CLAUDE_SESSION_ID=//p' "$reg")"
    [ -n "$sess" ] && log="$(ls "$HOME"/.claude/projects/*/"$sess".jsonl 2>/dev/null | head -1 || true)"
    if [ -n "$log" ]; then
      last="$(jq -r 'select(.type=="user" and (.message.content|type)=="string")
        | select(.message.content | startswith("Manager") | not) | .timestamp' "$log" 2>/dev/null | tail -1)"
      if [ -n "$last" ]; then
        then_s="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${last%%.*}" +%s 2>/dev/null || echo 0)"
        age=$(( $(date -u +%s) - then_s ))
        if [ "$age" -lt 600 ]; then
          echo "SKIPPED: the user wrote in this session $((age / 60)) min ago. Try at the next tick."
          exit 2
        fi
      fi
    fi
  fi
fi

at session type --target "$target" --pane primary "$text" >/dev/null
# Without the pause the Enter can arrive before the text is in the input line.
sleep 1
at session type --target "$target" --pane primary $'\r' >/dev/null
echo "sent to $target"
