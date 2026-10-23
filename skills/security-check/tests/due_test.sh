#!/usr/bin/env bash
# Tests for scripts/security-check-due.sh and scripts/install-launchd.sh. Only stubs run: no Jira
# ticket, no agterm session, no notification, no launchd job. HOME is a temp folder, so the real
# ~/.local/state/security-check, ~/.claude/task-briefs and ~/Library/LaunchAgents are never used.
#
# Usage:
#   due_test.sh
#
# Stubs: agtermctl, osascript, launchctl and sleep first on PATH; JIRA_PY = a stub python script;
# start-task.sh = a stub installed in the temp HOME, where the scripts look for it. The project
# repo is a clone of a local bare "origin", so git fetch works without a network.
# The scripts run under /bin/bash, as launchd runs them.
#
# security-check-due.sh:
#   1. not due → nothing; 14 days → due; no state, no report → due; interval override
#   2. the newest report on origin counts as the last run (also one pushed after the clone)
#   3. due → one ticket, start-task.sh with the right env, state saved
#   4. start-task.sh fails, or prints no TASK_STARTED line → PENDING_KEY kept; the next call
#      reuses it, no second ticket
#   5. agterm down → one notification, state unchanged
#   6. lock held or being taken → exit 0; a lock left by a crash → notification, kept; two calls
#      at once → one ticket
#   7. DRY_RUN (1, true) → prints the actions, changes nothing; DRY_RUN=0 → a real run
#   8. errors before the ticket (no start-task.sh, no brief, no profile on origin, no jira.py, bad
#      arguments, broken state) and Jira errors → no ticket or no session
#   9. the whole chain with the real new-task start-task.sh: the typed /security-check command;
#      Claude never starts → no LAST_RUN, PENDING_KEY kept; a launchd-like environment (env -i)
# install-launchd.sh:
#  10. writes a plist that passes plutil -lint, with the right values (no AGTERM_SOCKET: the
#      default socket); launchctl bootout + bootstrap
#  11. a bootstrap that fails once is retried; bad names, a worktree, no installed script → refused
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: keep '&' literal in ${v//p/r}

here="$(cd "$(dirname "$0")" && pwd -P)"
skill="$(dirname "$here")"
due="$skill/scripts/security-check-due.sh"
install="$skill/scripts/install-launchd.sh"
real_brief="$skill/references/run-brief.md"
real_start_task="$skill/../new-task/scripts/start-task.sh"
real_task_brief="$skill/../new-task/references/brief-template.md"
BASH_BIN=/bin/bash
[ -x "$BASH_BIN" ] || BASH_BIN="$(command -v bash)"

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"   # the scripts resolve paths with pwd -P

# ago <days>: the local date that many days before today (negative = in the future).
ago() { python3 -c 'import sys, datetime as d; print(d.date.today() - d.timedelta(days=int(sys.argv[1])))' "$1"; }

server="example-host"
project="PROJ"
key="PROJ-123"
today="$(ago 0)"
next_text="a security report (/security-check). The report summary will be posted here."
seed_for() { printf '/security-check %s --ticket %s (first read the task brief {{BRIEF}} and follow it for the whole run)' "$server" "$1"; }
seed="$(seed_for "$key")"

# ---- stubs ------------------------------------------------------------------------------------

mkdir -p "$tmp/bin"

cat > "$tmp/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
# tree: STUB_AGTERM_DOWN=1 → fail; else an empty tree, and once the claude command is typed, a
# tree with session SID-1 and claude in front (not with STUB_NO_CLAUDE=1). The session calls
# are for start-task.sh.
printf '%s\n' "$*" >> "$STUB_LOG/agtermctl.calls"
case "$1 ${2:-}" in
  "tree --json")  [ "${STUB_AGTERM_DOWN:-}" = 1 ] && exit 1
                  if [ -e "$STUB_LOG/claude.typed" ] && [ "${STUB_NO_CLAUDE:-}" != 1 ]; then
                    echo '{"result":{"tree":{"workspaces":[{"sessions":[{"id":"SID-1","cwd":"/w","foreground":["claude"]}]}]}}}'
                  else
                    echo '{"result":{"tree":{"workspaces":[]}}}'
                  fi ;;
  "session new")  echo '{"result":{"id":"SID-1"}}' ;;
  "session type") printf '%s\n' "${!#}" >> "$STUB_LOG/typed"
                  case "${!#}" in "claude "*) : > "$STUB_LOG/claude.typed" ;; esac ;;
esac
exit 0
EOF

cat > "$tmp/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/notify.calls"
exit "${STUB_OSA_RC:-0}"
EOF

cat > "$tmp/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
# bootout fails (the job is not loaded); bootstrap fails the first STUB_BOOTSTRAP_FAILS times.
printf '%s\n' "$*" >> "$STUB_LOG/launchctl.calls"
case "$1" in
  bootout) exit 1 ;;
  bootstrap)
    n="$(cat "$STUB_LOG/bootstrap.count" 2>/dev/null || echo 0)"
    echo $((n + 1)) > "$STUB_LOG/bootstrap.count"
    [ "$n" -lt "${STUB_BOOTSTRAP_FAILS:-0}" ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    exit 0 ;;
esac
exit 0
EOF

printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"

cat > "$tmp/jira_stub.py" <<'EOF'
import json, os, sys
log = os.environ["STUB_LOG"]
args = sys.argv[1:]
with open(os.path.join(log, "jira.calls"), "a") as f:
    f.write("|".join(args).replace("\n", "\\n") + "\n")
if args[0] == "create":
    if os.environ.get("STUB_JIRA_FAIL") == "1":
        sys.stderr.write("HTTP 401\n")
        sys.exit(1)
    k = "" if os.environ.get("STUB_JIRA_NOKEY") == "1" else os.environ.get("STUB_KEY", "PROJ-123")
    print(json.dumps({"key": k or None, "id": "1", "url": "https://jira.example.com/browse/" + k}, indent=2))
elif args[0] == "get":
    print(json.dumps({"summary": "Security check: example-host " + os.environ["STUB_TODAY"], "status": "To Do",
                      "url": "https://jira.example.com/browse/" + args[1], "description": "Scheduled."}))
elif args[0] == "comment":
    with open(os.path.join(log, "comment.txt"), "w") as f:
        f.write(args[args.index("--body") + 1])
EOF

# start-task.sh stub: logs its arguments and the env it got.
cat > "$tmp/start-task.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "ARGS=$*"
  echo "TASK_SEED=${TASK_SEED:-}"
  echo "TASK_BRIEF_EXTRA=${TASK_BRIEF_EXTRA:-}"
  echo "TASK_NEXT=${TASK_NEXT:-}"
  echo "AGTERM_ENABLED=${AGTERM_ENABLED:-}"
  echo "AGTERM_SOCKET=${AGTERM_SOCKET:-}"
  echo "JIRA_PY=${JIRA_PY:-}"
} >> "$STUB_LOG/start.calls"
[ -z "${STUB_START_DELAY:-}" ] || /bin/sleep "$STUB_START_DELAY"   # the real sleep: a slow start
rc="${STUB_START_RC:-0}"
if [ "$rc" = 0 ] && [ "${STUB_START_NOLINE:-}" != 1 ]; then
  echo "TASK_STARTED $2 agterm=SID-1 claude=u-1 worktree=/w branch=b"
fi
[ "$rc" = 0 ] || echo "ERROR: could not read $2 from Jira"
exit "$rc"
EOF

cat > "$tmp/new-worktree.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/new_wt.calls"
dir="$PARALLEL_ISSUES_ROOT/$1/.claude/worktrees/$2"
mkdir -p "$dir"
echo "WORKTREE_READY $dir"
EOF

chmod +x "$tmp/bin/"* "$tmp/start-task.sh" "$tmp/new-worktree.sh"

# The real commands would post a notification, open a session or load a job. Stop if a stub
# does not come first on PATH.
for c in agtermctl osascript launchctl sleep; do
  [ "$(PATH="$tmp/bin:$PATH" command -v "$c")" = "$tmp/bin/$c" ] \
    || { echo "ERROR: the $c stub is not first on PATH" >&2; exit 1; }
done

# ---- git: a bare origin, a seed clone that pushes to it, the main checkout ---------------------

g() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
        -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }

# make_repo <dir>: <dir>/origin.git, <dir>/seed (pushes), <dir>/code/demo (the main checkout).
# The profile is on origin/main. Prints nothing; fails the test run on a git error.
make_repo() {
  local d="$1"
  mkdir -p "$d/code"
  { g init -q --bare "$d/origin.git" \
    && g clone -q "$d/origin.git" "$d/seed" 2>/dev/null \
    && mkdir -p "$d/seed/infra/security-check" "$d/seed/docs/security" \
    && echo "server: $server" > "$d/seed/infra/security-check/$server.yml" \
    && g -C "$d/seed" add -A && g -C "$d/seed" commit -q --no-verify -m profile \
    && g -C "$d/seed" push -q origin HEAD:main 2>/dev/null \
    && g clone -q "$d/origin.git" "$d/code/demo" 2>/dev/null; } \
    || { echo "ERROR: could not make the test repo in $d" >&2; exit 1; }
}
# push_file <repo dir> <path> [content]: commit a file in the seed clone and push it to origin.
push_file() {
  mkdir -p "$(dirname "$1/seed/$2")"
  echo "${3:-x}" > "$1/seed/$2"
  g -C "$1/seed" add -A && g -C "$1/seed" commit -q --no-verify -m "$2" && g -C "$1/seed" push -q origin HEAD:main 2>/dev/null
}

make_repo "$tmp/base"
repo="$tmp/base/code/demo"

# jira.py must not be found by the default search (the "no jira.py" case relies on it).
jira_in_parents=""
d="$repo"
while :; do
  [ -f "$d/.claude/skills/jira-tickets/scripts/jira.py" ] && jira_in_parents="$d"
  [ "$d" = / ] && break
  d="$(dirname "$d")"
done

# ---- helpers ----------------------------------------------------------------------------------

out="" rc=0 home="" log="" state_file="" lock=""
arg_repo="" arg_server="" arg_project=""

# new_case <name>: a fresh HOME (with the stub start-task.sh and the run brief installed where
# the due script looks), log folder and arguments.
new_case() {
  home="$tmp/$1/home"
  log="$tmp/$1/log"
  mkdir -p "$home/.claude/skills/new-task/scripts" "$home/.claude/skills/security-check/references" "$log"
  cp "$tmp/start-task.sh" "$home/.claude/skills/new-task/scripts/start-task.sh"
  cp "$real_brief" "$home/.claude/skills/security-check/references/run-brief.md"
  state_file="$home/.local/state/security-check/$server.state"
  lock="$home/.local/state/security-check/$server.lock"
  arg_repo="$repo" arg_server="$server" arg_project="$project"
}

# set_state <line> ...: write the state file.
set_state() {
  mkdir -p "$(dirname "$state_file")"
  printf '%s\n' "$@" > "$state_file"
}
state_val() { sed -n "s/^$1=//p" "$state_file" 2>/dev/null; }
calls() { cat "$log/$1.calls" 2>/dev/null; }
count() { calls "$1" | grep -c "${2:-.}"; }
start_env() { sed -n "s/^$1=//p" "$log/start.calls" 2>/dev/null | tail -n 1; }

# run_due [VAR=value ...]: the due script in the current case.
run_due() {
  out="$(due_cmd "$@" 2>&1)"
  rc=$?
}
# due_cmd [VAR=value ...]: the same, output not captured.
due_cmd() {
  env -u DRY_RUN -u SECURITY_CHECK_INTERVAL_DAYS -u AGTERM_ENABLED -u AGTERM_SOCKET -u AGTERM_SESSION_ID \
    -u TASK_SEED -u TASK_BRIEF_EXTRA -u TASK_NEXT -u NEW_WT -u STUB_NO_CLAUDE \
    HOME="$home" PATH="$tmp/bin:$PATH" STUB_LOG="$log" STUB_TODAY="$today" JIRA_PY="$tmp/jira_stub.py" \
    "$@" "$BASH_BIN" "$due" "$arg_repo" "$arg_server" "$arg_project"
}

# expect_nothing_done <label>: no ticket, no session, no notification.
expect_nothing_done() {
  if [ ! -e "$log/jira.calls" ] && [ ! -e "$log/start.calls" ] && [ ! -e "$log/notify.calls" ]; then
    ok "$1"
  else
    bad "$1"; ls "$log"
  fi
}

# expect_started <label> [key]: state after a good run.
expect_started() {
  expect_eq "$1: LAST_RUN" "$today" "$(state_val LAST_RUN)"
  expect_eq "$1: LAST_KEY" "${2:-$key}" "$(state_val LAST_KEY)"
  expect_eq "$1: PENDING_KEY cleared" "" "$(state_val PENDING_KEY)"
  if [ -e "$lock" ]; then bad "$1: lock released"; else ok "$1: lock released"; fi
}

# ---- 1. not due / due -------------------------------------------------------------------------

new_case notdue
set_state "LAST_RUN=$(ago 13)" "LAST_KEY=PROJ-100" "PENDING_KEY="
cp "$state_file" "$tmp/notdue/before"
run_due
expect_eq "not due: exit 0" 0 "$rc"
expect_has "not due: says so" "not due: last run $(ago 13), 13 days ago (every 14 days)" "$out"
expect_nothing_done "not due: nothing done"
expect_eq "not due: agterm not asked" "" "$(calls agtermctl)"
if cmp -s "$tmp/notdue/before" "$state_file"; then ok "not due: state unchanged"; else bad "not due: state unchanged"; fi
if [ -e "$lock" ]; then bad "not due: lock released"; else ok "not due: lock released"; fi

new_case future
set_state "LAST_RUN=$(ago -3)"
run_due
expect_eq "LAST_RUN in the future: exit 0" 0 "$rc"
expect_has "LAST_RUN in the future: not due" "not due: last run $(ago -3), -3 days ago" "$out"
expect_nothing_done "LAST_RUN in the future: nothing done"

new_case interval
set_state "LAST_RUN=$today" "LAST_KEY=PROJ-100"
run_due SECURITY_CHECK_INTERVAL_DAYS=0
expect_eq "interval 0: exit 0" 0 "$rc"
expect_eq "interval 0: due again the same day" 1 "$(count start '^ARGS=')"

# ---- 2. the newest report on origin counts as the last run ------------------------------------

make_repo "$tmp/rep"
push_file "$tmp/rep" "docs/security/$(ago 3)-$server.md"
push_file "$tmp/rep" "docs/security/$(ago 1)-web-update-deploy.md"   # not a report of this server
push_file "$tmp/rep" "docs/security/$(ago 1)-other-host.md"          # another server's report
new_case report
arg_repo="$tmp/rep/code/demo"
run_due
expect_eq "report, no state: exit 0" 0 "$rc"
expect_has "report, no state: not due from the report" \
  "not due: last run $(ago 3), 3 days ago (every 14 days) (the newest report on origin/main)" "$out"
expect_nothing_done "report, no state: nothing done"

new_case reportnewer
arg_repo="$tmp/rep/code/demo"
set_state "LAST_RUN=$(ago 30)" "LAST_KEY=PROJ-100"
run_due
expect_has "report newer than LAST_RUN: due by the state" "due: last run $(ago 30), 30 days ago" "$out"
expect_has "report newer than LAST_RUN: not due by the report" "not due: last run $(ago 3), 3 days ago" "$out"
expect_nothing_done "report newer than LAST_RUN: nothing done"

# A report merged after the main checkout was cloned: the due script fetches it.
make_repo "$tmp/late"
push_file "$tmp/late" "docs/security/$(ago 20)-$server.md"
push_file "$tmp/late" "docs/security/$(ago 2)-$server.md"
new_case late
arg_repo="$tmp/late/code/demo"
run_due
expect_has "report pushed after the clone: fetched, not due" "not due: last run $(ago 2), 2 days ago" "$out"
expect_nothing_done "report pushed after the clone: nothing done"

make_repo "$tmp/old"
push_file "$tmp/old" "docs/security/$(ago 15)-$server.md"
new_case oldreport
arg_repo="$tmp/old/code/demo"
run_due
expect_eq "report 15 days old: exit 0" 0 "$rc"
expect_has "report 15 days old: due" "due: last run $(ago 15), 15 days ago (every 14 days) (the newest report on origin/main)" "$out"
expect_eq "report 15 days old: one ticket" 1 "$(count jira '^create|')"
expect_started "report 15 days old"

# ---- 3. due: one ticket, start-task.sh with the right env -------------------------------------

new_case due
set_state "LAST_RUN=$(ago 14)" "LAST_KEY=PROJ-100" "PENDING_KEY="
run_due
expect_eq "due: exit 0" 0 "$rc"
expect_has "due: 14 days is due" "due: last run $(ago 14), 14 days ago" "$out"
expect_eq "due: one Jira create, exact arguments" \
  "create|--project|PROJ|--type|Task|--label|security|--summary|Security check: $server $today|--description|Scheduled read-only security check of $server. The Claude session of this ticket writes the report and posts its summary here." \
  "$(calls jira)"
expect_eq "due: start-task.sh arguments" "ARGS=$repo $key" "$(grep '^ARGS=' "$log/start.calls")"
expect_eq "due: TASK_SEED" "$seed" "$(start_env TASK_SEED)"
expect_has "due: TASK_SEED has the key and a space after it" "--ticket $key (first" "$(start_env TASK_SEED)"
expect_eq "due: TASK_BRIEF_EXTRA = installed run brief" \
  "$home/.claude/skills/security-check/references/run-brief.md" "$(start_env TASK_BRIEF_EXTRA)"
expect_eq "due: TASK_NEXT" "$next_text" "$(start_env TASK_NEXT)"
expect_eq "due: AGTERM_ENABLED=1 for start-task.sh" "1" "$(start_env AGTERM_ENABLED)"
expect_eq "due: no AGTERM_SOCKET set (start-task.sh uses the default socket too)" "" "$(start_env AGTERM_SOCKET)"
expect_eq "due: JIRA_PY passed on" "$tmp/jira_stub.py" "$(start_env JIRA_PY)"
expect_eq "due: agterm alive check on the default socket" "tree --json" "$(calls agtermctl)"
expect_started "due"
expect_has "due: notification names the ticket" "started: $key" "$(calls notify)"

new_case first
run_due
expect_eq "first run (no state, no report): exit 0" 0 "$rc"
expect_has "first run: says so" "due: no run recorded yet, no report on origin/main" "$out"
expect_eq "first run: one ticket" 1 "$(count jira '^create|')"
expect_started "first run"

# ---- 4. start-task.sh fails → the next call reuses the ticket ---------------------------------

new_case retry
set_state "LAST_RUN=$(ago 50)" "LAST_KEY=PROJ-100"
run_due STUB_START_RC=1
expect_eq "start fails: exit 1" 1 "$rc"
expect_eq "start fails: PENDING_KEY saved" "$key" "$(state_val PENDING_KEY)"
expect_eq "start fails: LAST_RUN unchanged" "$(ago 50)" "$(state_val LAST_RUN)"
expect_has "start fails: notification" "did not start" "$(calls notify)"
expect_has "start fails: start-task.sh output in the log" "ERROR: could not read $key from Jira" "$out"
if [ -e "$lock" ]; then bad "start fails: lock released"; else ok "start fails: lock released"; fi
run_due STUB_KEY=PROJ-999
expect_eq "next call: exit 0" 0 "$rc"
expect_has "next call: says it reuses" "reusing $key from a failed try" "$out"
expect_eq "next call: no second ticket" 1 "$(count jira '^create|')"
expect_eq "next call: start-task.sh with the same ticket" "ARGS=$repo $key" "$(grep '^ARGS=' "$log/start.calls" | tail -n 1)"
expect_eq "next call: TASK_SEED names the same ticket" "$seed" "$(start_env TASK_SEED)"
expect_started "next call"

new_case noline
set_state "LAST_RUN=$(ago 50)" "LAST_KEY=PROJ-100"
run_due STUB_START_NOLINE=1
expect_eq "start-task.sh exit 0 without TASK_STARTED: exit 1" 1 "$rc"
expect_eq "start-task.sh exit 0 without TASK_STARTED: PENDING_KEY kept" "$key" "$(state_val PENDING_KEY)"
expect_eq "start-task.sh exit 0 without TASK_STARTED: LAST_RUN unchanged" "$(ago 50)" "$(state_val LAST_RUN)"

# ---- 5. agterm down ---------------------------------------------------------------------------

new_case down
set_state "LAST_RUN=$(ago 50)" "LAST_KEY=PROJ-100" "PENDING_KEY="
cp "$state_file" "$tmp/down/before"
run_due STUB_AGTERM_DOWN=1
expect_eq "agterm down: exit 0" 0 "$rc"
expect_eq "agterm down: one notification" 1 "$(count notify)"
expect_has "agterm down: notification says why" "agterm is not running" "$(calls notify)"
expect_eq "agterm down: no ticket" 0 "$(count jira)"
expect_eq "agterm down: no start-task.sh" 0 "$(count start '^ARGS=')"
if cmp -s "$tmp/down/before" "$state_file"; then ok "agterm down: state unchanged"; else bad "agterm down: state unchanged"; fi

new_case osafail
set_state "LAST_RUN=$(ago 50)"
run_due STUB_OSA_RC=1
expect_eq "notification fails: the run still starts" 1 "$(count start '^ARGS=')"
expect_has "notification fails: logged" "WARN: could not show the notification" "$out"
expect_started "notification fails"

# ---- 6. lock ----------------------------------------------------------------------------------

new_case locked
set_state "LAST_RUN=$(ago 50)"
mkdir -p "$lock"
echo "$$" > "$lock/pid"   # this test's shell: alive
run_due
expect_eq "lock held: exit 0" 0 "$rc"
expect_has "lock held: says so" "another call holds the lock" "$out"
expect_nothing_done "lock held: nothing done"
expect_eq "lock held: the other call's lock is kept" "$$" "$(cat "$lock/pid" 2>/dev/null)"

new_case taking
set_state "LAST_RUN=$(ago 50)"
mkdir -p "$lock"          # no pid yet, just made: being taken right now
run_due
expect_eq "lock being taken: exit 0" 0 "$rc"
expect_nothing_done "lock being taken: nothing done"

# A lock left by a crash is never removed by a call: two calls could both take it.
bash -c 'exit 0' &
dead=$!
wait "$dead"
for kind in "dead pid" "old, no pid" "old, live pid"; do
  new_case crashlock
  set_state "LAST_RUN=$(ago 50)"
  mkdir -p "$lock"
  case "$kind" in
    "dead pid") echo "$dead" > "$lock/pid" ;;
    "old, no pid") touch -t 202601010000 "$lock" ;;
    "old, live pid") echo "$$" > "$lock/pid"; touch -t 202601010000 "$lock" ;;
  esac
  run_due
  expect_eq "crashed lock ($kind): exit 1" 1 "$rc"
  expect_has "crashed lock ($kind): notification says what to remove" "remove that folder" "$(calls notify)"
  expect_eq "crashed lock ($kind): no ticket" 0 "$(count jira)"
  expect_eq "crashed lock ($kind): no start-task.sh" 0 "$(count start '^ARGS=')"
  if [ -d "$lock" ]; then ok "crashed lock ($kind): kept"; else bad "crashed lock ($kind): kept"; fi
  rm -rf "$tmp/crashlock"
done

# Two calls at once (launchd at wake, plus a hand run): one ticket, one session.
new_case race
set_state "LAST_RUN=$(ago 50)"
due_cmd STUB_START_DELAY=1 > "$log/race1.out" 2>&1 &
p1=$!
due_cmd STUB_START_DELAY=1 > "$log/race2.out" 2>&1 &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
expect_eq "two calls at once: both exit 0" "0 0" "$r1 $r2"
expect_eq "two calls at once: one ticket" 1 "$(count jira '^create|')"
expect_eq "two calls at once: one session" 1 "$(count start '^ARGS=')"
expect_has "two calls at once: the other one stops" "nothing to do" "$(cat "$log/race1.out" "$log/race2.out")"
expect_started "two calls at once"

# ---- 7. DRY_RUN -------------------------------------------------------------------------------

for v in 1 true; do
  new_case "dry$v"
  run_due DRY_RUN=$v
  expect_eq "DRY_RUN=$v: exit 0" 0 "$rc"
  expect_has "DRY_RUN=$v: no fetch" "DRY_RUN: would fetch origin" "$out"
  expect_has "DRY_RUN=$v: ticket action" \
    "DRY_RUN: would create a ticket: python3 $tmp/jira_stub.py create --project PROJ --type Task --label security --summary 'Security check: $server $today'" "$out"
  expect_has "DRY_RUN=$v: session action" "DRY_RUN: would run: AGTERM_ENABLED=1 TASK_SEED='$(seed_for PROJ-NEW)'" "$out"
  expect_has "DRY_RUN=$v: state action" "DRY_RUN: would save $state_file: LAST_RUN=$today LAST_KEY=PROJ-NEW PENDING_KEY=" "$out"
  expect_nothing_done "DRY_RUN=$v: nothing done"
  if [ -e "$home/.local/state" ]; then bad "DRY_RUN=$v: no state folder, no lock"; else ok "DRY_RUN=$v: no state folder, no lock"; fi
done

new_case dry0
run_due DRY_RUN=0
expect_eq "DRY_RUN=0 is a real run: one ticket" 1 "$(count jira '^create|')"
expect_started "DRY_RUN=0"

new_case drypending
set_state "LAST_RUN=$(ago 50)" "PENDING_KEY=$key"
cp "$state_file" "$tmp/drypending/before"
run_due DRY_RUN=1
expect_has "dry run, pending: reuses" "reusing $key" "$out"
expect_has "dry run, pending: session action" "TASK_SEED='$seed'" "$out"
expect_nothing_done "dry run, pending: nothing done"
if cmp -s "$tmp/drypending/before" "$state_file"; then ok "dry run, pending: state unchanged"; else bad "dry run, pending: state unchanged"; fi

new_case drydown
run_due DRY_RUN=1 STUB_AGTERM_DOWN=1
expect_eq "dry run, agterm down: exit 0" 0 "$rc"
expect_has "dry run, agterm down: prints the notification" "DRY_RUN: would notify: Security check of $server is due" "$out"
expect_nothing_done "dry run, agterm down: no notification"

# ---- 8. errors --------------------------------------------------------------------------------

# expect_refused <label> <exit code> <message>: failed before a ticket.
expect_refused() {
  expect_eq "$1: exit $2" "$2" "$rc"
  expect_has "$1: says why" "$3" "$out"
  expect_eq "$1: no ticket" 0 "$(count jira)"
  expect_eq "$1: no start-task.sh" 0 "$(count start '^ARGS=')"
}

new_case nostart
rm "$home/.claude/skills/new-task/scripts/start-task.sh"
run_due
expect_refused "no start-task.sh" 1 "start-task.sh of the new-task skill not found"
expect_has "no start-task.sh: notification" "start-task.sh of the new-task skill not found" "$(calls notify)"

new_case nobrief
rm "$home/.claude/skills/security-check/references/run-brief.md"
run_due
expect_refused "missing run brief" 1 "run brief not found at $home/.claude/skills/security-check/references/run-brief.md"

new_case noprofile
arg_server="other-host"
run_due
expect_refused "no profile on origin" 1 "no profile security-check/other-host.yml on origin/main"

# The profile only in the main checkout's files, not on origin: refused.
make_repo "$tmp/local"
mkdir -p "$tmp/local/code/demo/infra/security-check"
echo "server: local-host" > "$tmp/local/code/demo/infra/security-check/local-host.yml"
g -C "$tmp/local/code/demo" add -A
new_case localprofile
arg_repo="$tmp/local/code/demo"
arg_server="local-host"
run_due
expect_refused "profile only in the main checkout's index" 1 "no profile security-check/local-host.yml on origin/main"

mkdir -p "$tmp/noorigin/demo"
g -C "$tmp/noorigin/demo" init -q
new_case noorigin
arg_repo="$tmp/noorigin/demo"
run_due
expect_refused "no origin remote" 1 "has no branch origin/main"

if [ -z "$jira_in_parents" ]; then
  new_case nojira
  run_due JIRA_PY=
  expect_refused "no jira.py" 1 "jira.py of the jira-tickets skill not found"
else
  echo "WARN: a jira.py exists in a parent of the temp folder ($jira_in_parents); 'no jira.py' skipped"
fi

new_case parentjira
mkdir -p "$tmp/base/code/.claude/skills/jira-tickets/scripts"
cp "$tmp/jira_stub.py" "$tmp/base/code/.claude/skills/jira-tickets/scripts/jira.py"
run_due JIRA_PY=
expect_eq "jira.py in a parent folder: exit 0" 0 "$rc"
expect_eq "jira.py in a parent folder: used" "$tmp/base/code/.claude/skills/jira-tickets/scripts/jira.py" "$(start_env JIRA_PY)"

new_case repojira
mkdir -p "$repo/.claude/skills/jira-tickets/scripts"
cp "$tmp/jira_stub.py" "$repo/.claude/skills/jira-tickets/scripts/jira.py"
run_due JIRA_PY=
expect_eq "jira.py in the repo and a parent: the repo's wins" "$repo/.claude/skills/jira-tickets/scripts/jira.py" "$(start_env JIRA_PY)"
rm -rf "$tmp/base/code/.claude" "$repo/.claude"

new_case jirafail
set_state "LAST_RUN=$(ago 50)" "LAST_KEY=PROJ-100"
cp "$state_file" "$tmp/jirafail/before"
run_due STUB_JIRA_FAIL=1
expect_eq "Jira create fails: exit 1" 1 "$rc"
expect_has "Jira create fails: says so" "Jira: could not create the ticket" "$out"
expect_eq "Jira create fails: no start-task.sh" 0 "$(count start '^ARGS=')"
if cmp -s "$tmp/jirafail/before" "$state_file"; then ok "Jira create fails: state unchanged"; else bad "Jira create fails: state unchanged"; fi

new_case jiranokey
run_due STUB_JIRA_NOKEY=1
expect_eq "Jira answer without a key: exit 1" 1 "$rc"
expect_eq "Jira answer without a key: no start-task.sh" 0 "$(count start '^ARGS=')"
expect_eq "Jira answer without a key: no pending ticket" "" "$(state_val PENDING_KEY)"

new_case nostatedir
mkdir -p "$home/.local"
echo "not a folder" > "$home/.local/state"
run_due
expect_refused "state folder cannot be created" 1 "cannot create $home/.local/state/security-check"

for st in "LAST_RUN=yesterday" "LAST_RUN=2026-13-45" "PENDING_KEY=not-a-key" "PENDING_KEY=OTHER-5"; do
  new_case broken
  set_state "$st"
  cp "$state_file" "$tmp/broken/before"
  run_due
  expect_eq "broken state $st: exit 1" 1 "$rc"
  expect_eq "broken state $st: no ticket" 0 "$(count jira)"
  if cmp -s "$tmp/broken/before" "$state_file"; then ok "broken state $st: state unchanged"; else bad "broken state $st: state unchanged"; fi
  rm -rf "$tmp/broken"
done

# A worktree: .git is a file. Refused by a real run and by a dry run.
mkdir -p "$tmp/code/wt"
echo "gitdir: $repo/.git/worktrees/wt" > "$tmp/code/wt/.git"

for bad_args in "server=bad/name" "server=x y" "server=../x" "server=-x" "server=" \
                "project=proj" "project=P-1" "project=" "repo=$tmp/no-such-repo" "repo=$tmp/code/wt" \
                "dry repo=$tmp/code/wt"; do
  new_case badargs
  dry_env=""
  case "$bad_args" in
    server=*) arg_server="${bad_args#server=}" ;;
    project=*) arg_project="${bad_args#project=}" ;;
    repo=*) arg_repo="${bad_args#repo=}" ;;
    "dry repo="*) arg_repo="${bad_args#dry repo=}"; dry_env="DRY_RUN=1" ;;
  esac
  run_due ${dry_env:+"$dry_env"}
  expect_eq "bad argument $bad_args: exit 2" 2 "$rc"
  expect_eq "bad argument $bad_args: no ticket" 0 "$(count jira)"
  expect_eq "bad argument $bad_args: no start-task.sh" 0 "$(count start '^ARGS=')"
  if [ -e "$home/.local/state" ]; then bad "bad argument $bad_args: no state"; else ok "bad argument $bad_args: no state"; fi
  rm -rf "$tmp/badargs"
done

new_case badenv
run_due SECURITY_CHECK_INTERVAL_DAYS=two
expect_eq "bad SECURITY_CHECK_INTERVAL_DAYS: exit 2" 2 "$rc"
expect_eq "bad SECURITY_CHECK_INTERVAL_DAYS: no ticket" 0 "$(count jira)"

# ---- 9. the whole chain with the real start-task.sh -------------------------------------------

if [ -f "$real_start_task" ] && grep -q TASK_BRIEF_EXTRA "$real_start_task"; then
  new_case chain
  cp "$real_start_task" "$home/.claude/skills/new-task/scripts/start-task.sh"
  mkdir -p "$home/.claude/skills/new-task/references"
  cp "$real_task_brief" "$home/.claude/skills/new-task/references/brief-template.md"
  run_due NEW_WT="$tmp/new-worktree.sh"
  brief="$home/.claude/task-briefs/$key.md"
  uuid="$(sed -n 's/^TASK_STARTED .* claude=\([^ ]*\) .*/\1/p' <<<"$out")"
  expect_eq "chain: exit 0" 0 "$rc"
  expect_eq "chain: Jira create, get, transition, comment" \
    "$(printf 'create\nget\ntransition\ncomment')" "$(calls jira | cut -d'|' -f1)"
  expect_eq "chain: the typed command runs /security-check on the ticket" \
    "claude --session-id $uuid -n \"$key Security check: $server $today\" \"/security-check $server --ticket $key (first read the task brief $brief and follow it for the whole run)\"" \
    "$(head -n 1 "$log/typed" 2>/dev/null)"
  expect_eq "chain: brief starts with new-task's brief" "# Task brief — $key" "$(head -n 1 "$brief" 2>/dev/null)"
  expect_eq "chain: new-task's last part, the run brief, the ticket, in this order" \
    "## 6. When the work is merged and deployed|## 7. This task is a scheduled security check|## The ticket (from Jira, $today)|" \
    "$(grep -e '^## 6\. ' -e '^## 7\. ' -e '^## The ticket' "$brief" 2>/dev/null | tr '\n' '|')"
  expect_not_has "chain: every brief placeholder filled" "{{" "$(cat "$brief" 2>/dev/null)"
  expect_eq "chain: Jira Next line" "- Next: $next_text" "$(grep '^- Next: ' "$log/comment.txt" 2>/dev/null)"
  expect_started "chain"

  # Typing worked, but Claude never runs in the session: not started, the ticket kept.
  new_case chainnoclaude
  cp "$real_start_task" "$home/.claude/skills/new-task/scripts/start-task.sh"
  mkdir -p "$home/.claude/skills/new-task/references"
  cp "$real_task_brief" "$home/.claude/skills/new-task/references/brief-template.md"
  set_state "LAST_RUN=$(ago 50)" "LAST_KEY=PROJ-100"
  run_due NEW_WT="$tmp/new-worktree.sh" STUB_NO_CLAUDE=1
  expect_eq "chain, Claude does not start: exit 1" 1 "$rc"
  expect_has "chain, Claude does not start: start-task.sh says why" "ERROR: Claude did not start" "$out"
  expect_eq "chain, Claude does not start: PENDING_KEY kept" "$key" "$(state_val PENDING_KEY)"
  expect_eq "chain, Claude does not start: LAST_RUN unchanged" "$(ago 50)" "$(state_val LAST_RUN)"
  expect_has "chain, Claude does not start: notification" "did not start" "$(calls notify)"
  expect_eq "chain, Claude does not start: Jira create and get only" \
    "$(printf 'create\nget')" "$(calls jira | cut -d'|' -f1)"
else
  echo "WARN: no start-task.sh with TASK_BRIEF_EXTRA at $real_start_task; chain test skipped"
fi

# launchd gives a bare environment: only what the plist sets (PATH, AGTERM_*), plus HOME.
new_case launchd
plist_path="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
out="$(env -i HOME="$home" PATH="$tmp/bin:$plist_path" AGTERM_ENABLED=1 STUB_LOG="$log" STUB_TODAY="$today" \
  JIRA_PY="$tmp/jira_stub.py" "$BASH_BIN" "$due" "$repo" "$server" "$project" 2>&1)"
rc=$?
expect_eq "launchd-like environment: exit 0" 0 "$rc"
expect_eq "launchd-like environment: one ticket" 1 "$(count jira '^create|')"
expect_started "launchd-like environment"

# ---- 10. install-launchd.sh -------------------------------------------------------------------

# run_install <repo> <server> <project> [VAR=value ...]
run_install() {
  local r="$1" s="$2" p="$3"
  shift 3
  out="$(env -u AGTERM_SOCKET HOME="$home" PATH="$tmp/bin:$PATH" STUB_LOG="$log" \
    "$@" "$BASH_BIN" "$install" "$r" "$s" "$p" 2>&1)"
  rc=$?
}
# pl <key path>: one value of the plist
pl() { plutil -extract "$1" raw -o - "$plist" 2>/dev/null; }

# new_install_case <name>: a case with the due script installed where the plist points.
new_install_case() {
  new_case "$1"
  mkdir -p "$home/.claude/skills/security-check/scripts"
  cp "$due" "$home/.claude/skills/security-check/scripts/security-check-due.sh"
  plist="$home/Library/LaunchAgents/local.security-check.$server.plist"
}

plist=""
uid="$(id -u)"
if command -v plutil >/dev/null 2>&1; then
  new_install_case install
  run_install "$repo" "$server" "$project" AGTERM_SOCKET="$tmp/other.sock"
  expect_eq "install: exit 0" 0 "$rc"
  if plutil -lint "$plist" >/dev/null 2>&1; then ok "install: plist passes plutil -lint"; else bad "install: plist passes plutil -lint"; fi
  expect_eq "install: Label" "local.security-check.$server" "$(pl Label)"
  expect_eq "install: ProgramArguments" \
    "/bin/bash|$home/.claude/skills/security-check/scripts/security-check-due.sh|$repo|$server|$project" \
    "$(pl ProgramArguments.0)|$(pl ProgramArguments.1)|$(pl ProgramArguments.2)|$(pl ProgramArguments.3)|$(pl ProgramArguments.4)"
  expect_eq "install: no sixth argument" "" "$(pl ProgramArguments.5)"
  expect_eq "install: daily at 10:00" "10:0" "$(pl StartCalendarInterval.Hour):$(pl StartCalendarInterval.Minute)"
  expect_eq "install: not at load" "false" "$(pl RunAtLoad)"
  expect_eq "install: PATH" "$plist_path" "$(pl EnvironmentVariables.PATH)"
  expect_eq "install: AGTERM_ENABLED" "1" "$(pl EnvironmentVariables.AGTERM_ENABLED)"
  expect_eq "install: no AGTERM_SOCKET, even when set (agterm's default socket)" "" "$(pl EnvironmentVariables.AGTERM_SOCKET)"
  expect_eq "install: log path" "$home/Library/Logs/security-check-$server.log|$home/Library/Logs/security-check-$server.log" \
    "$(pl StandardOutPath)|$(pl StandardErrorPath)"
  expect_eq "install: launchctl bootout, then bootstrap" \
    "$(printf 'bootout gui/%s/local.security-check.%s\nbootstrap gui/%s %s' "$uid" "$server" "$uid" "$plist")" \
    "$(calls launchctl)"
  expect_has "install: prints how to check" "launchctl print gui/$uid/local.security-check.$server" "$out"
  expect_has "install: prints how to stop" "launchctl bootout gui/$uid/local.security-check.$server" "$out"

  # Characters that need escaping in XML, in the repo path.
  new_install_case xmlpath
  odd="$tmp/code/R&D <odd>"
  mkdir -p "$odd/.git"
  run_install "$odd" "$server" "$project"
  expect_eq "repo path with & < >: exit 0" 0 "$rc"
  if plutil -lint "$plist" >/dev/null 2>&1; then ok "repo path with & < >: plutil -lint"; else bad "repo path with & < >: plutil -lint"; fi
  expect_eq "repo path with & < >: kept as is" "$odd" "$(pl ProgramArguments.2)"

  # ---- 11. retries and refusals ---------------------------------------------------------------

  new_install_case retry1
  run_install "$repo" "$server" "$project" STUB_BOOTSTRAP_FAILS=1
  expect_eq "bootstrap fails once: exit 0" 0 "$rc"
  expect_eq "bootstrap fails once: tried twice" 2 "$(count launchctl '^bootstrap')"

  new_install_case retry5
  run_install "$repo" "$server" "$project" STUB_BOOTSTRAP_FAILS=5
  expect_eq "bootstrap always fails: exit 1" 1 "$rc"
  expect_eq "bootstrap always fails: three tries" 3 "$(count launchctl '^bootstrap')"
  expect_has "bootstrap always fails: says so" "launchctl bootstrap gui/$uid" "$out"

  for name in "bad/name" "x y" "../x" "-x" "a.b" 'x"y' "x<y>" "x&y" ""; do
    new_install_case badname
    run_install "$repo" "$name" "$project"
    expect_eq "install, bad server name '$name': exit 2" 2 "$rc"
    expect_eq "install, bad server name '$name': no plist" "" "$(ls "$home/Library/LaunchAgents" 2>/dev/null)"
    expect_eq "install, bad server name '$name': no launchctl" 0 "$(count launchctl)"
    rm -rf "$tmp/badname"
  done

  new_install_case badproject
  run_install "$repo" "$server" "proj"
  expect_eq "install, bad Jira project: exit 2" 2 "$rc"
  expect_eq "install, bad Jira project: no launchctl" 0 "$(count launchctl)"

  new_install_case worktree
  run_install "$tmp/code/wt" "$server" "$project"
  expect_eq "install, a worktree: exit 2" 2 "$rc"
  expect_has "install, a worktree: says why" "not the main checkout" "$out"

  new_case notinstalled
  plist="$home/Library/LaunchAgents/local.security-check.$server.plist"
  run_install "$repo" "$server" "$project"
  expect_eq "install, due script not installed: exit 1" 1 "$rc"
  expect_has "install, due script not installed: says why" "is not installed" "$out"
  if [ -e "$plist" ]; then bad "install, due script not installed: no plist"; else ok "install, due script not installed: no plist"; fi
  expect_eq "install, due script not installed: no launchctl" 0 "$(count launchctl)"
else
  echo "WARN: plutil not found (not macOS); install-launchd.sh tests skipped"
fi

finish due_test
