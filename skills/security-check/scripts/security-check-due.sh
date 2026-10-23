#!/usr/bin/env bash
# Start a scheduled security check of ONE server when it is due. launchd runs this every day
# (see install-launchd.sh). It starts a run only every 14 days.
#
# Usage:
#   security-check-due.sh <repo> <server> <jira_project>
#
# - <repo>          the project's MAIN checkout, not a worktree (worktrees get deleted). Its git
#                   index must hold the profile: a path ending in security-check/<server>.yml
# - <server>        the profile name: letters, digits, "-" and "_"
# - <jira_project>  the Jira project of the run's ticket, e.g. PROJ
#
# One call:
#   1. take the lock; another call holds it → exit 0
#   2. the last run is less than 14 days ago → exit 0
#   3. agterm is not running → desktop notification, exit 0, state unchanged
#      (the next daily call tries again)
#   4. a ticket from a failed try (PENDING_KEY) → reuse it. Else create one and save it as
#      PENDING_KEY before anything else:
#      jira.py create --project <p> --type Task --label security --summary "Security check: <server> <date>"
#   5. start-task.sh <repo> <KEY> (the new-task skill), with TASK_SEED, TASK_BRIEF_TEMPLATE and
#      TASK_NEXT set: a worktree, an agterm session and a Claude that runs
#      /security-check <server> --ticket <KEY>
#   6. success → LAST_RUN=<today>, LAST_KEY=<KEY>, PENDING_KEY cleared.
#      failure → notification, exit 1, PENDING_KEY kept for the next call.
#
# State: <state dir>/<server>.state, lines KEY=value: LAST_RUN (YYYY-MM-DD), LAST_KEY,
# PENDING_KEY. It is parsed, never sourced. The lock is the folder <state dir>/<server>.lock.
#
# Environment (all optional):
#   DRY_RUN=1                     print what would happen: no lock, no ticket, no session, no state
#   SECURITY_CHECK_INTERVAL_DAYS  days between runs. Default 14; 0 = due on every call
#   SECURITY_CHECK_STATE_DIR      default ~/.local/state/security-check
#   SECURITY_CHECK_TODAY          today as YYYY-MM-DD (for tests). Default: the local date
#   SECURITY_CHECK_BRIEF          the run brief. Default: the installed
#                                 ~/.claude/skills/security-check/references/run-brief.md
#   START_TASK                    default ~/.claude/skills/new-task/scripts/start-task.sh
#   JIRA_PY                       default: jira-tickets/scripts/jira.py in <repo>/.claude/skills,
#                                 in a parent folder's .claude/skills, then in ~/.claude/skills
#   AGTERMCTL, OSASCRIPT          the commands. Default: agtermctl and osascript from PATH
#   AGTERM_SOCKET                 default ~/Library/Application Support/agterm/agterm.sock
#
# Exit: 0 started or nothing to do, 1 failed (a notification says why), 2 bad usage.
set -uo pipefail

repo_in="${1:-}"
server="${2:-}"
project="${3:-}"

skills="$HOME/.claude/skills"
START_TASK="${START_TASK:-$skills/new-task/scripts/start-task.sh}"
BRIEF="${SECURITY_CHECK_BRIEF:-$skills/security-check/references/run-brief.md}"
AGTERMCTL="${AGTERMCTL:-agtermctl}"
OSASCRIPT="${OSASCRIPT:-osascript}"
AGTERM_SOCKET="${AGTERM_SOCKET:-$HOME/Library/Application Support/agterm/agterm.sock}"
state_dir="${SECURITY_CHECK_STATE_DIR:-$HOME/.local/state/security-check}"
interval="${SECURITY_CHECK_INTERVAL_DAYS:-14}"
case "${DRY_RUN:-}" in "" | 0) dry=0 ;; *) dry=1 ;; esac

# Exact ASCII sets. No ranges: in some locales a range like A-Z also matches other letters.
AZ=ABCDEFGHIJKLMNOPQRSTUVWXYZ
az=abcdefghijklmnopqrstuvwxyz
D=0123456789

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# notify <text>: a macOS notification. Quotes, backslashes and line breaks are dropped, because
# the text goes into an AppleScript string.
notify() {
  local text
  text="$(printf '%s' "$1" | tr -d '"\\\r\n')"
  if [ "$dry" = 1 ]; then
    log "DRY_RUN: would notify: $text"
    return 0
  fi
  "$OSASCRIPT" -e "display notification \"$text\" with title \"security-check\"" >/dev/null 2>&1 \
    || log "WARN: could not show the notification"
}

# fail <exit code> <message>: log it, show it as a notification, exit.
fail() {
  local code="$1"
  shift
  log "ERROR: $*"
  notify "security-check ${server:-?}: $*"
  exit "$code"
}

valid_server() { case "$1" in "" | [!$AZ$az$D]* | *[!$AZ$az${D}_-]*) return 1 ;; esac; }
valid_project() { case "$1" in "" | [!$AZ]* | *[!$AZ${D}_]*) return 1 ;; esac; }
valid_key() {
  local p="${1%-*}" n="${1##*-}"
  [ "$p" != "$1" ] || return 1
  valid_project "$p" || return 1
  case "$n" in "" | *[!$D]*) return 1 ;; esac
}
valid_date() { case "$1" in [$D][$D][$D][$D]-[$D][$D]-[$D][$D]) return 0 ;; esac; return 1; }

# days_between <from> <to>: whole days from one YYYY-MM-DD to the other. Fails on a bad date.
days_between() {
  python3 -c 'import sys, datetime as d
print((d.date.fromisoformat(sys.argv[2]) - d.date.fromisoformat(sys.argv[1])).days)' "$1" "$2" 2>/dev/null
}

# find_jira: jira-tickets/scripts/jira.py in <repo>/.claude/skills, a parent's, then ~/.claude/skills.
find_jira() {
  local d="$repo" rel=".claude/skills/jira-tickets/scripts/jira.py"
  while :; do
    [ -f "$d/$rel" ] && { echo "$d/$rel"; return 0; }
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
  [ -f "$HOME/$rel" ] && { echo "$HOME/$rel"; return 0; }
  return 1
}

# ---- arguments --------------------------------------------------------------------------------

[ -n "$repo_in" ] && [ -n "$server" ] && [ -n "$project" ] \
  || fail 2 "usage: security-check-due.sh <repo> <server> <jira_project>"
valid_server "$server" || fail 2 "bad server name (letters, digits, - and _ only)"
valid_project "$project" || fail 2 "bad Jira project '$project' (capital letters and digits, e.g. PROJ)"
case "$interval" in "" | *[!$D]*) fail 2 "SECURITY_CHECK_INTERVAL_DAYS must be a whole number of days" ;; esac
interval=$((10#$interval))
today="${SECURITY_CHECK_TODAY:-$(date +%F)}"
{ valid_date "$today" && days_between "$today" "$today" >/dev/null; } || fail 2 "SECURITY_CHECK_TODAY must be YYYY-MM-DD"
repo="$(cd "$repo_in" 2>/dev/null && pwd -P)" || fail 2 "repo '$repo_in' does not exist"
[ -d "$repo/.git" ] || fail 2 "'$repo' is not the main checkout of a git repo"
for c in "$AGTERMCTL" jq python3 git; do
  command -v "$c" >/dev/null 2>&1 || fail 1 "$c not on PATH"
done
export AGTERM_SOCKET

state="$state_dir/$server.state"
lock="$state_dir/$server.lock"

# ---- lock: two calls at once must not create two tickets --------------------------------------

# A lock is stale when its process is gone. A lock with no pid file yet is being taken right
# now, unless it is older than a minute.
lock_is_stale() {
  local pid
  pid="$(cat "$lock/pid" 2>/dev/null)"
  if [ -n "$pid" ]; then
    ! kill -0 "$pid" 2>/dev/null
  else
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]
  fi
}

if [ "$dry" = 0 ]; then
  mkdir -p "$state_dir" || fail 1 "cannot create $state_dir"
  if ! mkdir "$lock" 2>/dev/null; then
    if ! lock_is_stale; then
      log "another call holds the lock $lock: nothing to do"
      exit 0
    fi
    log "removing a stale lock $lock"
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { log "another call took the lock: nothing to do"; exit 0; }
  fi
  trap 'rm -rf "$lock"' EXIT
  echo "$$" > "$lock/pid"
fi

# ---- state (read under the lock, so a second call sees the first one's result) ----------------

LAST_RUN="" LAST_KEY="" PENDING_KEY=""
if [ -f "$state" ]; then
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in
      LAST_RUN) LAST_RUN="$v" ;;
      LAST_KEY) LAST_KEY="$v" ;;
      PENDING_KEY) PENDING_KEY="$v" ;;
    esac
  done < "$state"
fi
[ -z "$LAST_RUN" ] || { valid_date "$LAST_RUN" && days_between "$LAST_RUN" "$today" >/dev/null; } \
  || fail 1 "broken state file $state: LAST_RUN is not YYYY-MM-DD"
[ -z "$PENDING_KEY" ] || valid_key "$PENDING_KEY" || fail 1 "broken state file $state: PENDING_KEY is not a Jira key"
[ -z "$PENDING_KEY" ] || [ "${PENDING_KEY%-*}" = "$project" ] \
  || fail 1 "pending ticket $PENDING_KEY is not in project $project: fix or remove $state"

# write_state <LAST_RUN> <LAST_KEY> <PENDING_KEY>: replace the state file in one step.
write_state() {
  local tmp="$state.tmp.$$"
  printf '# written by security-check-due.sh\nLAST_RUN=%s\nLAST_KEY=%s\nPENDING_KEY=%s\n' "$1" "$2" "$3" > "$tmp" \
    && mv -f "$tmp" "$state"
}

# ---- 1. due? ----------------------------------------------------------------------------------

if [ -n "$LAST_RUN" ]; then
  age="$(days_between "$LAST_RUN" "$today")"
  if [ "$age" -lt "$interval" ]; then
    log "not due: last run $LAST_RUN, $age days ago (every $interval days)"
    exit 0
  fi
  log "due: last run $LAST_RUN, $age days ago (every $interval days)"
else
  log "due: no run recorded yet"
fi

# ---- 2. what the run needs, checked before a ticket exists -------------------------------------

[ -f "$START_TASK" ] || fail 1 "start-task.sh not found at $START_TASK (START_TASK)"
grep -q 'TASK_SEED' "$START_TASK" \
  || fail 1 "$START_TASK has no TASK_SEED override: update the new-task skill first"
[ -f "$BRIEF" ] || fail 1 "run brief not found at $BRIEF (SECURITY_CHECK_BRIEF)"
[ -n "$(git -C "$repo" ls-files -- "*security-check/$server.yml" 2>/dev/null)" ] \
  || fail 1 "no profile security-check/$server.yml in $repo"
if [ -z "${JIRA_PY:-}" ]; then
  JIRA_PY="$(find_jira)" || fail 1 "jira.py of the jira-tickets skill not found (set JIRA_PY)"
fi
[ -f "$JIRA_PY" ] || fail 1 "jira.py not found at $JIRA_PY (JIRA_PY)"
export JIRA_PY

# ---- 3. agterm --------------------------------------------------------------------------------

if ! tree="$("$AGTERMCTL" tree --json --socket "$AGTERM_SOCKET" 2>/dev/null)" || [ -z "$tree" ]; then
  log "agterm is not running: no run started; the next daily call tries again"
  notify "Security check of $server is due, but agterm is not running. The next daily call tries again."
  exit 0
fi

# ---- 4. the ticket ----------------------------------------------------------------------------

started() {   # started <KEY>: record the run
  if [ "$dry" = 1 ]; then
    log "DRY_RUN: would save $state: LAST_RUN=$today LAST_KEY=$1 PENDING_KEY="
    return 0
  fi
  write_state "$today" "$1" "" || fail 1 "$1 started, but $state could not be saved"
  log "started $1"
  notify "Security check of $server started: $1"
}

if [ -n "$PENDING_KEY" ]; then
  key="$PENDING_KEY"
  log "reusing $key from a failed try"
  # The try may have failed after its session opened. start-task.sh refuses a second session.
  sid="$(jq -r --arg k "$key " '[.. | objects | select(.cwd? and (.name? // "" | startswith($k))) | .id] | first // empty' \
    <<<"$tree" 2>/dev/null)"
  if [ -n "$sid" ]; then
    log "an agterm session for $key is already open ($sid): the run started before"
    started "$key"
    exit 0
  fi
else
  summary="Security check: $server $today"
  desc="Scheduled read-only security check of $server. The Claude session of this ticket writes the report and posts its summary here."
  if [ "$dry" = 1 ]; then
    log "DRY_RUN: would create a ticket: python3 $JIRA_PY create --project $project --type Task --label security --summary '$summary'"
    key="$project-NEW"
  else
    out="$(python3 "$JIRA_PY" create --project "$project" --type Task --label security \
      --summary "$summary" --description "$desc" </dev/null)" || fail 1 "Jira: could not create the ticket"
    key="$(jq -r '.key // empty' <<<"$out" 2>/dev/null)"
    valid_key "$key" || fail 1 "Jira: no ticket key in the answer of jira.py create"
    write_state "$LAST_RUN" "$LAST_KEY" "$key" || fail 1 "created $key, but $state could not be saved"
    log "created $key"
  fi
fi

# ---- 5. the session ---------------------------------------------------------------------------

seed="/security-check $server --ticket $key. First read the task brief {{BRIEF}} and follow it for the whole run."
next="a security report (/security-check). The report summary will be posted here."

if [ "$dry" = 1 ]; then
  log "DRY_RUN: would run: AGTERM_ENABLED=1 TASK_SEED='$seed' TASK_BRIEF_TEMPLATE=$BRIEF TASK_NEXT='$next' JIRA_PY=$JIRA_PY bash $START_TASK $repo $key"
  started "$key"
  exit 0
fi

out="$(AGTERM_ENABLED=1 TASK_SEED="$seed" TASK_BRIEF_TEMPLATE="$BRIEF" TASK_NEXT="$next" \
  bash "$START_TASK" "$repo" "$key" 2>&1)"
rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ] || ! grep -q "^TASK_STARTED $key " <<<"$out"; then
  fail 1 "the session for $key did not start (start-task.sh exit $rc). The next call reuses $key."
fi
started "$key"
