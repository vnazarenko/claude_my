#!/usr/bin/env bash
# Start an extra session for a ticket (a review, a fix-up, a check) as an agterm COMPANION of the
# ticket's task session: it sits under that session in the sidebar, so the user sees which ticket
# it belongs to. User rule 2026-11-02: no free-floating review sessions.
#
# Usage: start-companion.sh <TASK_KEY> <KEY> <label> <prompt-file | --resume=<claude-session-id>> [cwd]
#   TASK_KEY  registry key of the ticket's task session (ABC-387); its AGTERM_SESSION_ID is the parent
#   KEY       registry key for the new session (R-ABC-387-web); the registry file is written here
#   label     what the session is FOR, short: "Review #170 web"
#   4th arg   the claude prompt file, or --resume=<id> to continue an existing Claude conversation
#   cwd       defaults to the task's REPO
# COMPANION_CLAUDE_ARGS: extra claude flags (start-executor.sh: --model, --effort). KEY X-<TASK> is an
# executor (KIND=executor): its coordinator supervises it, the manager tick only counts it as busy.
# Prints the new agterm session id. If the task session is gone, falls back to a plain session in
# the manager's workspace and says so on stderr.
set -euo pipefail
B="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
[ $# -ge 4 ] || { echo "usage: $0 TASK_KEY KEY label prompt-file|--resume=ID [cwd]" >&2; exit 2; }
task="$1"; key="$2"; label="$3"; what="$4"; cwd="${5:-}"
env="$B/$task.env"
[ -f "$env" ] || { echo "no registry file $env" >&2; exit 1; }
val() { sed -n "s/^$1=//p" "$env" | head -1 | tr -d '"'; }
parent="$(val AGTERM_SESSION_ID)"
repo="$(val REPO)"
cwd="${cwd:-$repo}"
win="${AGTERM_WINDOW_ID:?run from the manager session}"
name="$task · $label"

new_id() { python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["id"])'; }
if [ -n "$parent" ] && agtermctl tree --json --window "$win" | grep -qi "\"$parent\""; then
  sid="$(agtermctl session new --parent "$parent" --cwd "$cwd" --name "$name" --no-select \
         --window "$win" --json | new_id)"
else
  echo "WARN: the task session of $task is gone; starting a plain session in the manager's workspace" >&2
  sid="$(agtermctl session new --cwd "$cwd" --name "$name" --no-select --window "$win" \
         --workspace "${AGTERM_WORKSPACE_ID:?}" --json | new_id)"
fi
agtermctl session context "$label ($task)" --target "$sid" --window "$win" >/dev/null || true

sleep 1
case "$what" in
  --resume=*) cmd="command claude --resume ${what#--resume=}" ;;
  *) [ -f "$what" ] || { echo "no prompt file $what" >&2; exit 1; }
     cmd="command claude ${COMPANION_CLAUDE_ARGS:-} \"\$(cat '$what')\"" ;;
esac
# A project can run claude with its own config dir (CLAUDE_CONFIG_DIR). A relative dir only
# resolves from the folder that holds it: start claude there, not in a repo cwd (a repo can hold a
# stale copy of that dir with no login -> first-run theme screen).
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  case "$CLAUDE_CONFIG_DIR" in
    /*) cmd="CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR $cmd" ;;
    *)  cmd="cd '$PWD' && CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR $cmd" ;;
  esac
fi
agtermctl session type --target "$sid" --window "$win" "$cmd" >/dev/null
agtermctl session type --target "$sid" --window "$win" $'\r' >/dev/null

kind=task; wt="$repo/.claude/worktrees/review-${key#R-}"
case "$key" in R-*) kind=review ;; X-*) kind=executor; wt="$cwd" ;; esac
if [ -f "$B/$key.env" ]; then
  # Re-homing an existing session: keep its fields, point it at the new agterm session.
  sed -i '' -e "s/^AGTERM_SESSION_ID=.*/AGTERM_SESSION_ID=$sid/" -e '/^PARENT_KEY=/d' "$B/$key.env"
  echo "PARENT_KEY=$task" >> "$B/$key.env"
else
  cat > "$B/$key.env" <<ENV
KEY=$key
JIRA_KEY=$task
KIND=$kind
PARENT_KEY=$task
REPO=$repo
WORKTREE=$wt
AGTERM_SESSION_ID=$sid
SESSION_NAME="$name"
STARTED="$(date '+%Y-%m-%d %H:%M:%S')"
ENV
fi
echo "$(date '+%Y-%m-%d %H:%M') | $key | companion of $task started: $label (agterm $sid)" >> "$B/manager-log.md"
echo "$sid"
