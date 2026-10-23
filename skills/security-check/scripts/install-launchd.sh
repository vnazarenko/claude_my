#!/usr/bin/env bash
# Install the daily launchd job that starts scheduled security checks of ONE server (macOS).
#
# Usage:
#   install-launchd.sh <repo> <server> <jira_project>
#
# - <repo>          the project's MAIN checkout, not a worktree (worktrees get deleted)
# - <server>        the profile name: letters, digits, "-" and "_"
# - <jira_project>  the Jira project of the run tickets, e.g. PROJ
#
# Writes ~/Library/LaunchAgents/local.security-check.<server>.plist:
#   - every day at 10:00 (a missed time runs at wake), not at load
#   - runs /bin/bash ~/.claude/skills/security-check/scripts/security-check-due.sh <repo> <server> <jira_project>
#     (the installed copy; that script decides whether a run is due)
#   - env: PATH with /usr/local/bin and /opt/homebrew/bin, AGTERM_ENABLED=1 (agterm is reached
#     on its default socket)
#   - log: ~/Library/Logs/security-check-<server>.log
# Checks it with plutil -lint, then reloads it: launchctl bootout (an error is fine: not loaded)
# and launchctl bootstrap gui/<uid>. Running it again replaces the job.
# The first run starts 14 days after the newest report of <server> on origin's default branch
# (or at once when there is none): the due script decides.
#
# Exit: 0 installed, 1 failed, 2 bad usage.
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: keep '&' literal in ${v//p/r}

repo_in="${1:-}"
server="${2:-}"
project="${3:-}"

plist_dir="$HOME/Library/LaunchAgents"
due="$HOME/.claude/skills/security-check/scripts/security-check-due.sh"
logs="$HOME/Library/Logs"
path="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Exact ASCII sets. No ranges: in some locales a range like A-Z also matches other letters.
UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
LOWER=abcdefghijklmnopqrstuvwxyz
DIGITS=0123456789

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }   # die <message> [exit code]
usage() { die "$1. Usage: install-launchd.sh <repo> <server> <jira_project>" 2; }

[ -n "$repo_in" ] && [ -n "$server" ] && [ -n "$project" ] || usage "three arguments needed"
# The name goes into a file name, a launchd label and the plist.
case "$server" in "" | [!$UPPER$LOWER$DIGITS]* | *[!$UPPER$LOWER${DIGITS}_-]*) usage "bad server name '$server' (letters, digits, - and _ only)" ;; esac
case "$project" in "" | [!$UPPER]* | *[!$UPPER${DIGITS}_]*) usage "bad Jira project '$project' (capital letters and digits, e.g. PROJ)" ;; esac
repo="$(cd "$repo_in" 2>/dev/null && pwd -P)" || usage "repo '$repo_in' does not exist"
[ -d "$repo/.git" ] || usage "'$repo' is not the main checkout of a git repo (a worktree gets deleted)"
[ -f "$due" ] || die "$due is not installed: merge and pull the skill first"
command -v plutil >/dev/null 2>&1 || die "plutil not found: this needs macOS"

label="local.security-check.$server"
plist="$plist_dir/$label.plist"
log_file="$logs/security-check-$server.log"
uid="$(id -u)"

# xml <text>: escape for a plist string.
xml() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

mkdir -p "$plist_dir" "$logs" || die "cannot create $plist_dir or $logs"
tmp="$plist.tmp.$$"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF || die "cannot write $tmp"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$due")</string>
    <string>$(xml "$repo")</string>
    <string>$server</string>
    <string>$project</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>10</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$path</string>
    <key>AGTERM_ENABLED</key>
    <string>1</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml "$log_file")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$log_file")</string>
</dict>
</plist>
EOF
plutil -lint "$tmp" >/dev/null || die "the plist does not pass plutil -lint: $tmp"
chmod 644 "$tmp" || die "cannot chmod $tmp"
mv -f "$tmp" "$plist" || die "cannot write $plist"
echo "wrote $plist"

# Reload: bootout fails when the job is not loaded, which is fine. Right after a bootout,
# bootstrap can fail for a moment ("Input/output error"), so it gets three tries.
launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
ok=0
for try in 1 2 3; do
  if launchctl bootstrap "gui/$uid" "$plist"; then ok=1; break; fi
  [ "$try" = 3 ] || sleep 1
done
[ "$ok" = 1 ] || die "launchctl bootstrap gui/$uid $plist failed"

cat <<EOF
loaded $label: every day at 10:00, a run every 14 days
first: 14 days after the newest $server report on origin (at once when there is none)
check: launchctl print gui/$uid/$label
log:   $log_file
state: ~/.local/state/security-check/$server.state
stop:  launchctl bootout gui/$uid/$label
EOF
