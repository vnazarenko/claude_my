#!/usr/bin/env bash
# The LAST step of task-cleanup. Runs DETACHED (its own process session, cwd /), because it
# closes the agterm session — and with it the Claude process that started it.
#
#   python3 - <<'PY' ... (see SKILL.md)   or:   finish-task.sh <KEY> --detach
#
# Order: wait a moment so the caller's last message is shown → close the agterm session →
# wait for the task Claude to exit → stop processes still inside the worktree → remove the
# worktree (only when it holds no real uncommitted work) → delete the local branch (only when
# MERGE_PROVEN=1 is set in the registry) → post the result to Jira → archive the registry.
# Log: ~/.claude/task-briefs/<KEY>.cleanup.log
set -uo pipefail

key="${1:?Jira key required}"
briefs="$HOME/.claude/task-briefs"
reg="$briefs/$key.env"
log="$briefs/$key.cleanup.log"
[ -f "$reg" ] || { echo "ERROR: no task registry $reg"; exit 1; }

if [ "${2:-}" = "--detach" ]; then
  python3 - "$0" "$key" "$log" <<'PY'
import subprocess, sys
script, key, log = sys.argv[1:4]
subprocess.Popen(["bash", script, key], cwd="/", start_new_session=True,
                 stdin=subprocess.DEVNULL, stdout=open(log, "a"), stderr=subprocess.STDOUT)
PY
  echo "FINISHER_STARTED $key (log $log) — the agterm session closes in ${DELAY:-6}s"
  exit 0
fi

trap '' HUP
cd /
# shellcheck disable=SC1090
. "$reg"
JIRA_PY="${JIRA_PY:-/Users/vnazarenko/code/Orthhank/.claude/skills/jira-tickets/scripts/jira.py}"
here="$(cd "$(dirname "$0")" && pwd -P)"
echo "=== $(date '+%F %T') finish $key"
notes=()

sleep "${DELAY:-6}"
if agtermctl session close --target "$AGTERM_SESSION_ID" >/dev/null 2>&1; then
  notes+=("agterm session \"$SESSION_NAME\" closed"); echo "agterm session closed"
else
  notes+=("agterm session was already closed"); echo "agterm close: not found (already closed?)"
fi

for _ in $(seq 1 30); do
  alive=""
  for p in $(pgrep -f -- "$CLAUDE_SESSION_ID" 2>/dev/null); do
    [ "$(basename "$(ps -o comm= -p "$p" 2>/dev/null)")" = "claude" ] && alive="$p"
  done
  [ -z "$alive" ] && break
  sleep 1
done
if [ -n "$alive" ]; then
  kill -TERM "$alive" 2>/dev/null; sleep 2; kill -KILL "$alive" 2>/dev/null
  echo "claude $alive did not exit — killed"
fi
notes+=("Claude session $CLAUDE_SESSION_ID ended (resume: claude --resume $CLAUDE_SESSION_ID)")

left="$(bash "$here/task-processes.sh" "$key" --kill 2>&1)"
echo "$left"
if grep -q '^processes: none' <<<"$(sed -n '/--- after stop ---/,$p' <<<"$left")"; then
  notes+=("no task processes left running")
else
  notes+=("WARNING: some task processes are still running — see $log")
fi

if [ -d "$WORKTREE" ]; then
  real="$(git -C "$WORKTREE" status --porcelain 2>/dev/null | cut -c4- \
    | grep -vxE '(.*/)?(Gemfile\.lock|config/database\.ya?ml)' | grep -vxE '(.*/)?\.env[^/]*' \
    | grep -vxE '\.claude/skills/[^/]+/?' || true)"
  if [ -n "$real" ]; then
    notes+=("WORKTREE KEPT: it has uncommitted work ($WORKTREE)")
    echo "REFUSING to remove worktree, real changes:"; echo "$real"
  elif git -C "$REPO" worktree remove --force "$WORKTREE"; then
    notes+=("worktree $WORKTREE removed"); echo "worktree removed"
  else
    notes+=("WARNING: could not remove worktree $WORKTREE")
  fi
fi
git -C "$REPO" worktree prune

if [ "${MERGE_PROVEN:-0}" = "1" ] && git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$REPO" branch -D "$BRANCH" && notes+=("local branch $BRANCH deleted (merge proven)")
elif git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  notes+=("local branch $BRANCH kept (merge not proven)")
fi

body="Cleanup finished $(date '+%F %H:%M')."$'\n'
for n in "${notes[@]}"; do body+=$'\n'"- $n"; done
python3 "$JIRA_PY" comment "$key" --body "$body" >/dev/null && echo "jira comment posted" || echo "WARN: jira comment failed"

mkdir -p "$briefs/done"
mv "$reg" "$briefs/done/" 2>/dev/null
for ext in procs md; do [ -f "$briefs/$key.$ext" ] && mv "$briefs/$key.$ext" "$briefs/done/"; done
echo "=== done"
