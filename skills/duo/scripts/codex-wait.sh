#!/usr/bin/env bash
# Wait for one codex-companion fallback job (duo skill, "When the pane chat is impossible").
# Run it with run_in_background and act on its exit code when it notifies you:
#   0  the job completed — read it with `codex-companion.mjs result <job>`
#   1  the job failed or was cancelled
#   3  its log was silent for SILENCE seconds (default 300) — it hangs: `cancel` it, start a FRESH task
# Usage: codex-wait.sh <job-id> [silence-seconds]   (run from the worktree the job was started in)
set -u
JOB=${1:?usage: codex-wait.sh <job-id> [silence-seconds]}
SILENCE=${2:-300}
CC=$(ls -d ~/.claude/plugins/cache/openai-codex/codex/*/scripts/codex-companion.mjs 2>/dev/null | sort -V | tail -1)
[ -n "$CC" ] || { echo "codex-companion.mjs not found"; exit 1; }

state() {
  node "$CC" status "$JOB" --json 2>/dev/null |
    python3 -c 'import sys, json; d = json.load(sys.stdin); j = d.get("job", d); print(j.get("status", ""), j.get("logFile") or j.get("log") or "")' 2>/dev/null
}

sleep 20
while true; do
  read -r status log <<<"$(state)"
  case "$status" in
    completed) echo "status=completed"; exit 0 ;;
    failed | cancelled) echo "status=$status"; exit 1 ;;
    "") echo "no job $JOB here (wrong id, or run from another worktree?)"; exit 1 ;;
  esac
  # The log path is in the status JSON; fall back to the newest log of this job under the plugin state.
  [ -n "${log:-}" ] && [ -f "$log" ] || log=$(ls -t ~/.claude/plugins/data/codex-openai-codex/state/*/jobs/"$JOB".log 2>/dev/null | head -1)
  if [ -n "$log" ] && [ -f "$log" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$log" 2>/dev/null || stat -c %Y "$log") ))
    if [ "$age" -gt "$SILENCE" ]; then
      echo "silent for ${age}s (> ${SILENCE}s): cancel $JOB and start a fresh task"
      exit 3
    fi
  fi
  sleep 15
done
