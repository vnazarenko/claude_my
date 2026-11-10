#!/usr/bin/env bash
# Start or end one manager tick. Run by the tick subagent, never by the manager itself.
#
#   tick.sh        take the lock, count the tick, print the manager's memory files, then status.sh
#   tick.sh done   release the lock (and save the manager files' hash for precheck.sh)
#   tick.sh reset  set the tick counter to 0 (the manager runs this at /manager start)
#
# Exit 4: a previous tick still holds the lock (younger than 20 min). Stop and report "busy".
# Exit 3: agterm is not answering (from status.sh).
#
# Output is kept short so it shows at once instead of going to a file the agent reads in parts
# (token audit 2026-11-03): decisions only for "all" and live tickets, the last 25 log lines, and
# status.sh in its tick form (short lines for WORKING and SAME SCREEN sessions).
set -uo pipefail

# MANAGER_BRIEFS lets a second manager (another project) keep its own registry and memory files.
briefs="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
lock="$briefs/.manager-tick.lock"
counter="$briefs/manager-ticks"
. "$HOME/.claude/skills/manager/scripts/lib-screens.sh"

case "${1:-}" in
  done)  files_hash >"$briefs/.tick-files"; rmdir "$lock" 2>/dev/null; exit 0 ;;
  reset) echo 0 >"$counter"; rm -f "$briefs/.tick-screens"; rmdir "$lock" 2>/dev/null
         # The manager's own agterm session: autotick.py sends LIMIT alarms there.
         [ -n "${AGTERM_SESSION_ID:-}" ] && echo "$AGTERM_SESSION_ID" >"$briefs/.manager-session"
         python3 "$HOME/.claude/skills/manager/scripts/autotick.py" --reset-idle; exit 0 ;;
  "")    ;;
  # Any other argument (even --help) would take the lock and count a tick (2026-11-03).
  *)     echo "usage: tick.sh [done|reset] — no other arguments" >&2; exit 2 ;;
esac

if ! mkdir "$lock" 2>/dev/null; then
  # A crashed tick leaves its lock behind; it expires after 20 minutes.
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then
    rmdir "$lock" && mkdir "$lock" || { echo "BUSY: cannot take $lock"; exit 4; }
  else
    echo "BUSY: a previous tick is still running ($lock)"; exit 4
  fi
fi

n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$counter"
echo "##### tick $n  $(date '+%Y-%m-%d %H:%M')  load: $(uptime | sed 's/.*load averages*: //')"

if [ -s "$briefs/manager-decisions.md" ]; then
  echo "##### manager-decisions.md (lines for 'all' and live tickets)"
  python3 - "$briefs" <<'PY'
import sys, glob, re
b = sys.argv[1]
keys = set()
for f in glob.glob(b + '/*.env'):
    for l in open(f):
        if l.startswith(('KEY=', 'PARENT_KEY=', 'JIRA_KEY=')):
            keys.add(l.split('=', 1)[1].strip().strip('"'))
for name in ('manager-needs.md', 'manager-holds.md', 'manager-longlived.md'):
    try:
        txt = open(f'{b}/{name}').read()
    except OSError:
        continue
    keys |= set(re.findall(r'[A-Z][A-Z0-9]+-\d+', txt))
    if name == 'manager-longlived.md':
        keys |= {l.strip() for l in txt.splitlines() if l.strip() and not l.startswith('#')}
hidden = 0
for l in open(b + '/manager-decisions.md').read().splitlines():
    parts = [p.strip() for p in l.split('|')]
    who = parts[1] if len(parts) >= 3 else ''
    if (l.startswith('#') or not who or who.lower() == 'all'
            or any(k and (k in who or who in k) for k in keys)):
        print(l)
    else:
        hidden += 1
if hidden:
    print(f'({hidden} lines about tickets that are not live are hidden; grep the file for one)')
PY
fi
[ -s "$briefs/manager-needs.md" ] && { echo "##### manager-needs.md"; cat "$briefs/manager-needs.md"; }
if [ -s "$briefs/manager-log.md" ]; then
  echo "##### manager-log.md (last 25 lines)"
  tail -n 25 "$briefs/manager-log.md"
fi

TICK_SNAPSHOT="$briefs/.tick-screens.new" bash "$HOME/.claude/skills/manager/scripts/status.sh" "${TICK_LINES:-22}"
rc=$?
if [ "$rc" -eq 0 ] && [ -f "$briefs/.tick-screens.new" ]; then
  mv -f "$briefs/.tick-screens.new" "$briefs/.tick-screens"
  merged_prs >"$briefs/.tick-prs"
fi
exit "$rc"
