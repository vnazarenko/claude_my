#!/usr/bin/env bash
# launchd runs this every 15 min (~/Library/LaunchAgents/com.<user>.manager-tick.plist).
# One cheap tick for each manager: autotick.py, and a small `claude -p` only for ASK items.
# A manager with <briefs>/.ticks-off is skipped. No Claude session is involved.
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
log="$HOME/Library/Logs/manager-tick.log"
awake=0
# Post-deploy checklist: rebuild from the PR bodies, repair its session. No Claude, no tokens,
# so it runs even when every manager has .ticks-off. Off switch: ~/.claude/post-deploy/.off
pd="$HOME/.claude/skills/post-deploy/scripts"
if [ -f "$pd/build.py" ] && [ ! -e "$HOME/.claude/post-deploy/.off" ]; then
  pdout="$(python3 "$pd/build.py" --quiet 2>&1; bash "$pd/open.sh" --ensure 2>&1)"
  [ -n "$pdout" ] && printf '%s post-deploy\n%s\n' "$(date '+%F %T')" "$pdout" >>"$log"
fi
# A new deploy -> one tick now, also for a manager with .ticks-off (user rule, 2026-11-10).
# deploy-watch.sh flags it (from here, or at once from the WatchPaths job if installed).
bash "$HOME/.claude/skills/manager/scripts/deploy-watch.sh" --no-kick >>"$log" 2>&1
deploy=0
[ -e "$HOME/.claude/manager-deploy-pending" ] && deploy=1 && rm -f "$HOME/.claude/manager-deploy-pending"
# Every manager folder: task-briefs (the default), task-briefs-<project>, ...
for b in "$HOME"/.claude/task-briefs "$HOME"/.claude/task-briefs-*; do
  [ -d "$b" ] || continue
  force=()
  if [ -e "$b/.ticks-off" ]; then
    # off: only a deploy tick, and only for a manager that follows deploys
    [ "$deploy" = 1 ] && grep -q '^REPOS=' "$b/tick.env" 2>/dev/null \
      && ! grep -q '^DEPLOY_LIST=off' "$b/tick.env" || continue
    force=(--force)
  fi
  out="$(MANAGER_BRIEFS="$b" python3 "$HOME/.claude/skills/manager/scripts/autotick.py" --run-asks ${force[@]+"${force[@]}"} 2>&1)"
  printf '%s %s\n%s\n' "$(date '+%F %T')" "$(basename "$b")" "$out" >>"$log"
  case "$out" in *"awake: "*) awake=1 ;; esac
done
# Live work seen: keep the Mac awake until the next tick decides again.
[ "$awake" = 1 ] && python3 "$HOME/.claude/skills/manager/scripts/keep_awake.py" >>"$log" 2>&1
# keep the log small
[ "$(wc -l <"$log" 2>/dev/null || echo 0)" -gt 3000 ] && tail -n 1500 "$log" >"$log.tmp" && mv "$log.tmp" "$log"
exit 0
