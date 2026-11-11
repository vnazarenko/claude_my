#!/usr/bin/env bash
# A deploy happened? -> one manager tick at once, also while ticks are off (user rule, 2026-11-10).
#
#   deploy-watch.sh            (launchd WatchPaths job) on a new deploy: flag it, kickstart the tick job
#   deploy-watch.sh --no-kick  (run-tick.sh) only flag it
#
# A deploy = a new "deployed as release" line in a Capistrano log of a REPOS repo (the repo's own
# log/ or one folder down, e.g. web/log/), or a new line in ~/.claude/manager-deploys.log (deployed.sh).
# Registries with DEPLOY_LIST=off are not watched. The flag ~/.claude/manager-deploy-pending makes
# run-tick.sh run autotick.py --force for the watched registries.
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
seen="$HOME/.claude/manager-deploy-seen"
flag="$HOME/.claude/manager-deploy-pending"

sig() {
  for te in "$HOME"/.claude/task-briefs*/tick.env; do
    [ -f "$te" ] || continue
    grep -q '^DEPLOY_LIST=off' "$te" && continue
    for r in $(sed -n 's/^REPOS=//p' "$te"); do
      for c in "$r"/log/capistrano.log "$r"/*/log/capistrano.log; do
        [ -f "$c" ] && printf '%s %s\n' "$c" "$(grep -o 'deployed as release [0-9]*' "$c" | tail -1)"
      done
    done
  done
  tail -1 "$HOME/.claude/manager-deploys.log" 2>/dev/null
}

now="$(sig | shasum | cut -c1-16)"
[ "$now" = "$(cat "$seen" 2>/dev/null)" ] && exit 0
echo "$now" >"$seen"
touch "$flag"
echo "$(date '+%F %T') deploy seen -> manager tick"
[ "${1:-}" = "--no-kick" ] || launchctl kickstart "gui/$(id -u)/com.$(id -un).manager-tick" >/dev/null 2>&1
exit 0
