#!/usr/bin/env bash
# Type a message into a task session and press Enter.
#
# Usage: say.sh <KEY|agterm-session-id> "<text>"
#   KEY (e.g. KAN-123) is looked up in ~/.claude/task-briefs/<KEY>.env.
set -euo pipefail

target="${1:?KEY or agterm session id required}"
text="${2:?message text required}"

if [[ "$target" =~ ^[A-Z]+-[0-9]+$ ]]; then
  reg="$HOME/.claude/task-briefs/$target.env"
  [ -f "$reg" ] || { echo "ERROR: no registry $reg"; exit 1; }
  target="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$reg")"
  [ -n "$target" ] || { echo "ERROR: no AGTERM_SESSION_ID in $reg"; exit 1; }
fi

agtermctl session type --target "$target" "$text" >/dev/null
# Without the pause the Enter can arrive before the text is in the input line.
sleep 1
agtermctl session type --target "$target" $'\r' >/dev/null
echo "sent to $target"
