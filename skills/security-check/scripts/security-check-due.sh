#!/usr/bin/env bash
# Start a scheduled security check of ONE server when it is due. launchd runs this every day
# (see install-launchd.sh). It starts a run only every 14 days.
#
# Usage:
#   security-check-due.sh <repo> <server> <jira_project>
#
# - <repo>          the project's MAIN checkout, not a worktree (worktrees get deleted)
# - <server>        the profile name: letters, digits, "-" and "_"
# - <jira_project>  the Jira project of the run's ticket, e.g. PROJ
#
# One call (the code sections below have the same numbers):
#   1. take the lock (a folder). Another call holds it → exit 0. A lock left by a crashed call
#      → notification, exit 1: remove the folder by hand
#   2. due? The last run is the newer of LAST_RUN in the state file and the newest report
#      <YYYY-MM-DD>-<server>.md on origin's default branch (after a fetch of origin). Less than
#      14 days ago → exit 0
#   3. what the run needs, checked before a ticket exists: start-task.sh, the run brief, jira.py,
#      and the profile security-check/<server>.yml on origin's default branch (the run's
#      worktree starts from it)
#   4. agterm is not running → desktop notification, exit 0, state unchanged
#      (the next daily call tries again)
#   5. a ticket from a failed try (PENDING_KEY) → reuse it. Else create one and save it as
#      PENDING_KEY before anything else:
#      jira.py create --project <p> --type Task --label security --summary "Security check: <server> <date>"
#   6. start-task.sh <repo> <KEY> (the new-task skill), with TASK_SEED, TASK_BRIEF_EXTRA and
#      TASK_NEXT set: a worktree, an agterm session and a Claude that runs
#      /security-check <server> --ticket <KEY>
#   7. success → LAST_RUN=<today>, LAST_KEY=<KEY>, PENDING_KEY cleared.
#      failure → notification, exit 1, PENDING_KEY kept for the next call.
#
# State: ~/.local/state/security-check/<server>.state, lines KEY=value: LAST_RUN (YYYY-MM-DD),
# LAST_KEY, PENDING_KEY. It is parsed, never sourced. The lock is the folder <server>.lock there.
#
# Environment (all optional):
#   DRY_RUN=1                     print what would happen: no lock, no fetch, no ticket, no
#                                 session, no state. Any value but "" and "0" means a dry run
#   SECURITY_CHECK_INTERVAL_DAYS  days between runs. Default 14; 0 = due on every call
#   JIRA_PY                       default: jira-tickets/scripts/jira.py in <repo>/.claude/skills,
#                                 in a parent folder's .claude/skills, then in ~/.claude/skills
#   AGTERM_SOCKET                 default ~/Library/Application Support/agterm/agterm.sock
#
# Exit: 0 started or nothing to do, 1 failed (a notification says why), 2 bad usage.
set -uo pipefail

repo_in="${1:-}"
server="${2:-}"
project="${3:-}"

skills="$HOME/.claude/skills"
start_task="$skills/new-task/scripts/start-task.sh"
brief="$skills/security-check/references/run-brief.md"
AGTERM_SOCKET="${AGTERM_SOCKET:-$HOME/Library/Application Support/agterm/agterm.sock}"
state_dir="$HOME/.local/state/security-check"
interval="${SECURITY_CHECK_INTERVAL_DAYS:-14}"
case "${DRY_RUN:-}" in "" | 0) dry=0 ;; *) dry=1 ;; esac

# Exact ASCII sets. No ranges: in some locales a range like A-Z also matches other letters.
UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
LOWER=abcdefghijklmnopqrstuvwxyz
DIGITS=0123456789

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
  osascript -e "display notification \"$text\" with title \"security-check\"" >/dev/null 2>&1 \
    || log "WARN: could not show the notification"
}

# die <message> [exit code]: log it on stderr, show it as a notification, exit (default 1).
die() {
  log "ERROR: $1" >&2
  notify "security-check ${server:-?}: $1"
  exit "${2:-1}"
}

valid_server() { case "$1" in "" | [!$UPPER$LOWER$DIGITS]* | *[!$UPPER$LOWER${DIGITS}_-]*) return 1 ;; esac; }
valid_project() { case "$1" in "" | [!$UPPER]* | *[!$UPPER${DIGITS}_]*) return 1 ;; esac; }
valid_key() {
  local p="${1%-*}" n="${1##*-}"
  [ "$p" != "$1" ] || return 1
  valid_project "$p" || return 1
  case "$n" in "" | *[!$DIGITS]*) return 1 ;; esac
}
valid_date() {
  case "$1" in
    [$DIGITS][$DIGITS][$DIGITS][$DIGITS]-[$DIGITS][$DIGITS]-[$DIGITS][$DIGITS]) return 0 ;;
  esac
  return 1
}

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

# newest_report: the date of the newest <YYYY-MM-DD>-<server>.md on $ref, or nothing.
newest_report() {
  local p d best=""
  while IFS= read -r p; do
    p="${p##*/}"
    d="${p:0:10}"
    { [ "$p" = "$d-$server.md" ] && valid_date "$d"; } || continue
    [ -z "$best" ] || [[ $d > $best ]] || continue
    days_between "$d" "$today" >/dev/null && best="$d"
  done < <(git -C "$repo" ls-tree -r --name-only "$ref" 2>/dev/null | grep -e "-$server\.md\$")
  printf '%s' "$best"
}

# ---- arguments --------------------------------------------------------------------------------

[ -n "$repo_in" ] && [ -n "$server" ] && [ -n "$project" ] \
  || die "usage: security-check-due.sh <repo> <server> <jira_project>" 2
valid_server "$server" || die "bad server name (letters, digits, - and _ only)" 2
valid_project "$project" || die "bad Jira project '$project' (capital letters and digits, e.g. PROJ)" 2
case "$interval" in "" | *[!$DIGITS]*) die "SECURITY_CHECK_INTERVAL_DAYS must be a whole number of days" 2 ;; esac
interval=$((10#$interval))
repo="$(cd "$repo_in" 2>/dev/null && pwd -P)" || die "repo '$repo_in' does not exist" 2
# A worktree gets deleted after its PR.
[ -d "$repo/.git" ] || die "'$repo' is not the main checkout of a git repo" 2
for c in agtermctl jq python3 git; do
  command -v "$c" >/dev/null 2>&1 || die "$c not on PATH"
done
today="$(date +%F)"
export AGTERM_SOCKET

state="$state_dir/$server.state"
lock="$state_dir/$server.lock"

# ---- 1. lock: two calls at once must not create two tickets -----------------------------------

# A live call: the lock is younger than an hour (a call takes seconds), and its pid is alive
# or not written yet. Anything else was left by a crash. It is never removed here: two calls
# that both judge it stale could both take it.
lock_is_live() {
  local pid
  [ -n "$(find "$lock" -maxdepth 0 -mmin -60 2>/dev/null)" ] || return 1
  pid="$(cat "$lock/pid" 2>/dev/null)"
  [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null
}

if [ "$dry" = 0 ]; then
  mkdir -p "$state_dir" || die "cannot create $state_dir"
  if ! mkdir "$lock" 2>/dev/null; then
    if lock_is_live; then
      log "another call holds the lock $lock: nothing to do"
      exit 0
    fi
    die "a crashed call left the lock $lock: remove that folder, then the next call runs"
  fi
  trap 'rm -rf "$lock"' EXIT
  echo "$$" > "$lock/pid"
fi

# ---- 2. due? The state is read under the lock, so a second call sees the first one's result ---

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
  || die "broken state file $state: LAST_RUN is not YYYY-MM-DD"
[ -z "$PENDING_KEY" ] || valid_key "$PENDING_KEY" || die "broken state file $state: PENDING_KEY is not a Jira key"
[ -z "$PENDING_KEY" ] || [ "${PENDING_KEY%-*}" = "$project" ] \
  || die "pending ticket $PENDING_KEY is not in project $project: fix or remove $state"

# write_state <LAST_RUN> <LAST_KEY> <PENDING_KEY>: replace the state file in one step.
write_state() {
  local tmp="$state.tmp.$$"
  printf '# written by security-check-due.sh\nLAST_RUN=%s\nLAST_KEY=%s\nPENDING_KEY=%s\n' "$1" "$2" "$3" > "$tmp" \
    && mv -f "$tmp" "$state"
}

# not_due <last run> [<where it comes from>]: exit 0 when the last run is too recent.
not_due() {
  local age
  age="$(days_between "$1" "$today")"
  if [ "$age" -lt "$interval" ]; then
    log "not due: last run $1, $age days ago (every $interval days)${2:-}"
    exit 0
  fi
  log "due: last run $1, $age days ago (every $interval days)${2:-}"
}

[ -z "$LAST_RUN" ] || not_due "$LAST_RUN"

# The run's worktree starts from origin's default branch: read the profile and the newest
# report there, not in the main checkout (other sessions keep it as it is).
if [ "$dry" = 1 ]; then
  log "DRY_RUN: would fetch origin"
else
  GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet origin </dev/null \
    || log "WARN: git fetch origin failed; using the origin branch as it is"
fi
ref="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || ref="origin/main"
git -C "$repo" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 \
  || die "$repo has no branch $ref: set its remote 'origin'"

report_date="$(newest_report)"
if [ -n "$report_date" ] && { [ -z "$LAST_RUN" ] || [[ $report_date > $LAST_RUN ]]; }; then
  not_due "$report_date" " (the newest report on $ref)"
elif [ -z "$LAST_RUN" ]; then
  log "due: no run recorded yet, no report on $ref"
fi

# ---- 3. what the run needs, checked before a ticket exists -------------------------------------

[ -f "$start_task" ] || die "start-task.sh of the new-task skill not found at $start_task"
[ -f "$brief" ] || die "run brief not found at $brief"
git -C "$repo" ls-tree -r --name-only "$ref" 2>/dev/null | grep -e "security-check/$server\.yml\$" >/dev/null \
  || die "no profile security-check/$server.yml on $ref of $repo"
if [ -z "${JIRA_PY:-}" ]; then
  JIRA_PY="$(find_jira)" || die "jira.py of the jira-tickets skill not found (set JIRA_PY)"
fi
[ -f "$JIRA_PY" ] || die "jira.py not found at $JIRA_PY (JIRA_PY)"
export JIRA_PY

# ---- 4. agterm --------------------------------------------------------------------------------

if ! tree="$(agtermctl tree --json --socket "$AGTERM_SOCKET" 2>/dev/null)" || [ -z "$tree" ]; then
  log "agterm is not running: no run started; the next daily call tries again"
  notify "Security check of $server is due, but agterm is not running. The next daily call tries again."
  exit 0
fi

# ---- 5. the ticket ----------------------------------------------------------------------------

if [ -n "$PENDING_KEY" ]; then
  key="$PENDING_KEY"
  log "reusing $key from a failed try"
else
  summary="Security check: $server $today"
  desc="Scheduled read-only security check of $server. The Claude session of this ticket writes the report and posts its summary here."
  if [ "$dry" = 1 ]; then
    log "DRY_RUN: would create a ticket: python3 $JIRA_PY create --project $project --type Task --label security --summary '$summary'"
    key="$project-NEW"
  else
    out="$(python3 "$JIRA_PY" create --project "$project" --type Task --label security \
      --summary "$summary" --description "$desc" </dev/null)" || die "Jira: could not create the ticket"
    key="$(jq -r '.key // empty' <<<"$out" 2>/dev/null)"
    valid_key "$key" || die "Jira: no ticket key in the answer of jira.py create"
    write_state "$LAST_RUN" "$LAST_KEY" "$key" || die "created $key, but $state could not be saved"
    log "created $key"
  fi
fi

# ---- 6. the session ---------------------------------------------------------------------------

# A space after the key, so the key is never read as "PROJ-123." or "PROJ-123,".
seed="/security-check $server --ticket $key (first read the task brief {{BRIEF}} and follow it for the whole run)"
next="a security report (/security-check). The report summary will be posted here."

if [ "$dry" = 1 ]; then
  log "DRY_RUN: would run: AGTERM_ENABLED=1 TASK_SEED='$seed' TASK_BRIEF_EXTRA=$brief TASK_NEXT='$next' JIRA_PY=$JIRA_PY bash $start_task $repo $key"
  log "DRY_RUN: would save $state: LAST_RUN=$today LAST_KEY=$key PENDING_KEY="
  exit 0
fi

out="$(AGTERM_ENABLED=1 TASK_SEED="$seed" TASK_BRIEF_EXTRA="$brief" TASK_NEXT="$next" \
  bash "$start_task" "$repo" "$key" 2>&1)"
rc=$?
printf '%s\n' "$out"

# ---- 7. the result ----------------------------------------------------------------------------

if [ "$rc" -ne 0 ] || ! grep -q "^TASK_STARTED $key " <<<"$out"; then
  die "the session for $key did not start (start-task.sh exit $rc). The next call reuses $key."
fi
write_state "$today" "$key" "" || die "$key started, but $state could not be saved"
log "started $key"
notify "Security check of $server started: $key"
