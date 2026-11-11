#!/usr/bin/env bash
# Start the EXECUTOR for a ticket: a companion session (under the task session in the sidebar) that
# implements the plan in the SAME worktree and branch, on a cheaper model picked by Jev.
# Run it from the coordinator (the ticket's task session), after the plan is approved.
#
#   start-executor.sh <KEY> <haiku|sonnet|opus> <plan-file> "<scope, e.g. Tasks 2-5 of the plan>"
#
# Then wait without tokens: executor-wait.sh <KEY> (Bash run_in_background). The executor writes
# ~/.claude/task-briefs/<KEY>.handback.md and runs handback.sh. Talk to it:
#   bash ~/.claude/skills/manager/scripts/say.sh X-<KEY> "Coordinator: <rework request>"
# While it works, the coordinator does not edit the worktree.
set -euo pipefail
B="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -ge 4 ] || { echo "usage: $0 KEY haiku|sonnet|opus plan-file scope" >&2; exit 2; }
key="$1"; model="$2"; plan="$3"; scope="$4"
case "$model" in
  haiku) args="--model haiku" ;;
  sonnet) args="--model sonnet --effort medium" ;;
  opus) args="--model opus --effort high" ;;
  *) echo "model must be haiku, sonnet or opus (self = do it yourself, no executor)" >&2; exit 2 ;;
esac
reg="$B/$key.env"; [ -f "$reg" ] || { echo "no registry $reg" >&2; exit 1; }
val() { sed -n "s/^$1=//p" "$reg" | head -1 | tr -d '"'; }
wt="$(val WORKTREE)"; branch="$(val BRANCH)"; brief="$(val BRIEF)"
[ -d "$wt" ] || { echo "no worktree $wt" >&2; exit 1; }
case "$plan" in /*) ;; *) plan="$wt/$plan" ;; esac
[ -f "$plan" ] || { echo "no plan file $plan" >&2; exit 1; }
xkey="X-$key"
if [ -f "$B/$xkey.env" ]; then
  sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$B/$xkey.env")"
  if agtermctl tree --json --window "${AGTERM_WINDOW_ID:?run inside agterm}" | grep -qi "\"$sid\""; then
    echo "an executor for $key already runs (agterm $sid): send it the next scope with say.sh $xkey" >&2; exit 3
  fi
  rm -f "$B/$xkey.env"
fi

xbrief="$B/$key.exec.md"
K="$key" W="$wt" BR="$branch" P="$plan" S="$scope" BF="$brief" \
python3 - "$HERE/references/executor-brief.md" "$xbrief" <<'PY'
import os, sys
t = open(sys.argv[1]).read()
e = os.environ
for k, v in {'KEY': e['K'], 'WORKTREE': e['W'], 'BRANCH': e['BR'], 'PLAN': e['P'],
             'SCOPE': e['S'], 'BRIEF': e['BF']}.items():
    t = t.replace('{{' + k + '}}', v)
open(sys.argv[2], 'w').write(t)
PY
rm -f "$B/$key.handback.md"
prompt="$B/$key.exec-prompt.txt"
echo "You are the executor for $key. Read $xbrief and do exactly what it says. Your scope: $scope" >"$prompt"

sid="$(COMPANION_CLAUDE_ARGS="--permission-mode auto $args" \
  bash "$HOME/.claude/skills/manager/scripts/start-companion.sh" "$key" "$xkey" "Executor ($model)" "$prompt" "$wt")"
echo "MODEL=$model" >>"$B/$xkey.env"
date +%s >"$B/$key.exec-started"
echo "$(date '+%Y-%m-%d %H:%M') | $key | executor started: $model, scope: $scope" >>"$B/manager-log.md"
echo "EXECUTOR_STARTED $xkey agterm=$sid model=$model"
