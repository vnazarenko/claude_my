#!/usr/bin/env bash
# Show every new-task task whose agterm session is alive: key, Jira status, end of its screen.
# Then the manager's holds file.
#
# Usage: status.sh [lines]   (screen lines per task, default 22)
#
# With TICK_SNAPSHOT=<file> (tick.sh sets it) the output is only what a tick needs, and each
# session's token goes to that file for precheck.sh: a WORKING session shows 2 lines, a screen that
# did not change since the last tick shows 4 lines, any other screen its full tail.
# Why: token audit 2026-11-03 — the full output (~17k chars, plus the memory files) was too long to
# show at once, so every tick saved it to a file and read it again in parts.
set -uo pipefail

n="${1:-22}"
# MANAGER_BRIEFS lets a second manager (another project) keep its own registry and memory files.
briefs="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
. "$HOME/.claude/skills/manager/scripts/lib-screens.sh"
# Same jira.py as new-task, without repeating its path here.
JIRA_PY="${JIRA_PY:-$(sed -n 's/^JIRA_PY="\${JIRA_PY:-\(.*\)}"$/\1/p' "$HOME/.claude/skills/new-task/scripts/start-task.sh")}"
snap="${TICK_SNAPSHOT:-}"

tree="$(agterm_tree)"
[ -n "$tree" ] || { echo "##### agterm is not answering: its control socket refuses connections. Sessions cannot be read now."; exit 3; }
live="$(jq -r '.. | objects | select(.cwd?) | .id' <<<"$tree")"
[ -z "$snap" ] || : >"$snap"

# show <name> <sid> <header line>
show() {
  local full t22 tok
  full="$(screen_text "$2")"
  if [ -z "$snap" ]; then echo "$3"; tail -n "$n" <<<"$full"; return; fi
  t22="$(tail -n 22 <<<"$full")"
  tok="$(token_of "$(session_status "$tree" "$2")" "$t22")"
  printf '%s\t%s\n' "$1" "$tok" >>"$snap"
  if [ "$tok" = working ]; then
    echo "$3 · WORKING"; tail -n 2 <<<"$full"
  elif [ "$tok" = "$(prev_token "$1")" ]; then
    echo "$3 · SAME SCREEN as the last tick"; tail -n 4 <<<"$full"
  else
    echo "$3"; tail -n "$n" <<<"$full"
  fi
}

gone=()
for f in "$briefs"/*.env; do
  [ -f "$f" ] || continue
  key="$(sed -n 's/^KEY=//p' "$f")"
  sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$f")"
  if [ -z "$sid" ] || ! grep -qx "$sid" <<<"$live"; then
    gone+=("$key"); [ -z "$snap" ] || printf '%s\tgone\n' "$key" >>"$snap"; continue
  fi
  # Hand-built entries (sessions the manager spawned with agtermctl) can name another Jira
  # (JIRA_PY), a ticket that differs from the registry name (JIRA_KEY, e.g. R-ABC-4 -> ABC-4)
  # and a KIND (task | review). A review session is never cleaned up with /task-cleanup.
  jpy="$(sed -n 's/^JIRA_PY=//p' "$f")"; jpy="${jpy:-$JIRA_PY}"
  jkey="$(sed -n 's/^JIRA_KEY=//p' "$f")"; jkey="${jkey:-$key}"
  kind="$(sed -n 's/^KIND=//p' "$f")"
  st="?"
  [ -f "$jpy" ] && st="$(timeout 20 python3 "$jpy" get "$jkey" 2>/dev/null | jq -r '.status // "?"')"
  show "$key" "$sid" "##### $key sid=$sid jira=$jkey:$st${kind:+ kind=$kind}"
done
[ ${#gone[@]} -eq 0 ] || echo "##### no session: ${gone[*]}"
# Long-lived sessions (no Jira ticket): watched, never cleaned up.
if [ -s "$briefs/manager-longlived.md" ]; then
  while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    sid="$(jq -rs --arg p "$prefix" \
      '[.[] | .. | objects | select(.cwd? and (.name? // "" | startswith($p))) | .id] | first // empty' <<<"$tree")"
    if [ -z "$sid" ]; then
      echo "##### long-lived '$prefix': no session"
      [ -z "$snap" ] || printf 'long-lived %s\tgone\n' "$prefix" >>"$snap"
      continue
    fi
    show "long-lived $prefix" "$sid" "##### long-lived '$prefix' sid=$sid"
  done < <(grep -v '^#' "$briefs/manager-longlived.md")
fi
if [ -s "$briefs/manager-holds.md" ]; then
  echo "##### holds"
  cat "$briefs/manager-holds.md"
fi
