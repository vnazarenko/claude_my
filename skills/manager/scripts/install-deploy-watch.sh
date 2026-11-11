#!/usr/bin/env bash
# Install the launchd job that starts a manager tick the moment a deploy log changes.
# Watches the Capistrano logs of every REPOS repo (DEPLOY_LIST not off) and ~/.claude/manager-deploys.log.
# Run it again after adding a repo. The user runs this (it adds a LaunchAgent).
set -euo pipefail
u="$(id -un)"; out="$HOME/Library/LaunchAgents/com.$u.manager-deploy-watch.plist"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
echo "    <string>$HOME/.claude/manager-deploys.log</string>" >"$tmp"
for te in "$HOME"/.claude/task-briefs*/tick.env; do
  grep -q '^DEPLOY_LIST=off' "$te" && continue
  for r in $(sed -n 's/^REPOS=//p' "$te"); do
    for c in "$r"/log/capistrano.log "$r"/*/log/capistrano.log; do
      [ -f "$c" ] && echo "    <string>$c</string>" >>"$tmp"
    done
  done
done
sed -e "s|@USER@|$u|" -e "s|@HOME@|$HOME|g" "$(dirname "$0")/deploy-watch.plist.in" \
  | awk -v f="$tmp" '$0 == "@PATHS@" { while ((getline l < f) > 0) print l; next } { print }' >"$out"
plutil -lint "$out"
launchctl bootout "gui/$(id -u)/com.$u.manager-deploy-watch" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$out"
echo "installed: $out"
