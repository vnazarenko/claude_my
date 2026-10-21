#!/usr/bin/env bash
# List (default) or stop (--kill) the local processes a task left running.
#
# Usage:
#   task-processes.sh <KEY>           # list
#   task-processes.sh <KEY> --kill    # TERM, wait, KILL what is left, list again
#
# A process belongs to the task when:
#   A) its cwd is inside the task worktree (catches daemonized servers: rails s -d, spring,
#      sidekiq, vite, node dev servers — they reparent to launchd but keep their cwd), or
#   B) it is a descendant of the task's Claude process (background Bash tasks, watchers).
# Never listed: the task's Claude process and its ancestors (the agterm shell), this
# script's own ancestors, and the Claude process's direct non-shell children (its MCP
# servers — they go away with the session).
# Also prints Docker containers that mount the worktree, and the task's .procs file, which
# holds what this script cannot see (remote screens, databases).
set -uo pipefail

key="${1:?Jira key required}"
mode="${2:-}"
reg="$HOME/.claude/task-briefs/$key.env"
[ -f "$reg" ] || { echo "ERROR: no task registry $reg"; exit 1; }
# shellcheck disable=SC1090
. "$reg"
wt="$WORKTREE"
# Only a task worktree. Pointed at a main checkout, the cwd match would take in every session
# that works there.
case "$wt" in */.claude/worktrees/?*) : ;; *) echo "ERROR: '$wt' is not under .claude/worktrees/ — refusing"; exit 1 ;; esac

ppid_of() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
comm_of() { basename "$(ps -o comm= -p "$1" 2>/dev/null)" 2>/dev/null; }

# Never touched: this script's chain and its own pipeline (process group), the task Claude's
# chain (its agterm shell), and EVERY other claude / codex process with its ancestors and its
# descendants — a second session that cd'ed into the worktree is not ours to stop.
protect=" "
add_chain() { local p="$1"; while [ -n "$p" ] && [ "$p" -gt 1 ]; do protect="$protect$p "; p="$(ppid_of "$p")"; done; }
add_desc() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do protect="$protect$c "; add_desc "$c"; done; }
add_chain $$
mypgid="$(ps -o pgid= -p $$ | tr -d ' ')"

task_claude=""
for p in $(pgrep -f -- "$CLAUDE_SESSION_ID" 2>/dev/null); do
  [ "$(comm_of "$p")" = "claude" ] && { task_claude="$p"; break; }
done
[ -n "$task_claude" ] && add_chain "$task_claude"

for p in $(pgrep -x claude 2>/dev/null) $(pgrep -x codex 2>/dev/null); do
  [ "$p" = "$task_claude" ] && continue
  protect="$protect$p "; add_chain "$p"; add_desc "$p"
done

cands=" "
# A) cwd inside the worktree.
while read -r pid path; do
  case "$path" in "$wt"|"$wt"/*) cands="$cands$pid " ;; esac
done < <(lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p, substr($0,2)}')

# B) descendants of the task Claude, except its direct non-shell children (MCP servers).
if [ -n "$task_claude" ]; then
  walk() {
    local parent="$1" depth="$2" c
    for c in $(pgrep -P "$parent" 2>/dev/null); do
      if [ "$depth" = 0 ]; then
        case "$(comm_of "$c")" in zsh|bash|sh|-zsh|-bash) : ;; *) continue ;; esac
      fi
      cands="$cands$c "
      walk "$c" 1
    done
  }
  walk "$task_claude" 0
fi

list=()
for pid in $cands; do
  case "$protect" in *" $pid "*) continue ;; esac
  kill -0 "$pid" 2>/dev/null || continue
  [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$mypgid" ] && continue
  case " ${list[*]-} " in *" $pid "*) continue ;; esac
  list+=("$pid")
done

show() {
  local pid ports alive=()
  for pid in ${list[@]+"${list[@]}"}; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
  if [ "${#alive[@]}" -eq 0 ]; then echo "processes: none"; return; fi
  echo "processes (${#alive[@]}):"
  printf '  %-7s %-7s %-10s %-14s %s\n' PID PPID ELAPSED PORTS COMMAND
  for pid in "${alive[@]}"; do
    ports="$(lsof -Pan -p "$pid" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9]*\)$/\1/p' | sort -u | paste -sd, -)"
    printf '  %-7s %-7s %-10s %-14s %s\n' "$pid" "$(ppid_of "$pid")" \
      "$(ps -o etime= -p "$pid" | tr -d ' ')" "${ports:--}" "$(ps -o command= -p "$pid" | cut -c1-110)"
  done
}

containers=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ids="$(docker ps -q)"
  [ -n "$ids" ] && containers="$(docker inspect --format '{{.Id}} {{.Name}} {{range .Mounts}}{{.Source}} {{end}}' $ids 2>/dev/null \
    | grep -F "$wt" | awk '{print substr($1,1,12), $2}')"
fi

if [ "$mode" = "--kill" ]; then
  [ -x "$wt/bin/spring" ] && ( cd "$wt" && bin/spring stop >/dev/null 2>&1 ) && echo "spring stopped"
  if [ "${#list[@]}" -gt 0 ]; then
    kill -TERM "${list[@]}" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      alive=0; for pid in "${list[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
      [ "$alive" = 0 ] && break; sleep 0.5
    done
    for pid in "${list[@]}"; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null && echo "KILL $pid"; done
  fi
  [ -n "$containers" ] && echo "$containers" | while read -r id name; do docker stop "$id" >/dev/null && echo "container stopped: $name"; done
  echo "--- after stop ---"
  containers=""
fi

show
[ -n "$containers" ] && { echo "containers mounting the worktree:"; echo "$containers" | sed 's/^/  /'; } || echo "containers: none"
if [ -s "$PROCS" ]; then
  echo "recorded in $PROCS (check and stop these by hand):"
  sed 's/^/  /' "$PROCS"
else
  echo "recorded: none"
fi
echo "task claude pid: ${task_claude:-not running}"
