#!/usr/bin/env bash
# Tests for scripts/start-task.sh. Only stubs run: no agterm session, no Jira call, no real
# worktree. HOME is a temp folder, so ~/.claude/task-briefs is never the real one.
#
# Usage:
#   start_task_test.sh
#
# Stubs: agtermctl and sleep on PATH; JIRA_PY = a stub python script; NEW_WT = a stub that
# prints "WORKTREE_READY <dir>". jq, uuidgen and python3 are the real ones.
#
# 1. no override set → the /planning:make seed, the default brief, the default Jira "Next:" line
# 2. TASK_SEED, TASK_BRIEF_EXTRA and TASK_NEXT set → all three used, placeholders filled; the
#    extra file comes after the default brief and before the ticket text
# 3. overrides set but empty → the defaults
# 4. TASK_BRIEF_EXTRA names a missing file → clear error; no worktree, no session, no Jira
# 5. TASK_SEED with a character the typed shell would expand, a control byte or a non-ASCII
#    byte → clear error; nothing started
# 6. an open agterm session of the same ticket blocks the start; one of PROJ-1234 does not
# 7. macOS /bin/bash (3.2), no caller session (AGTERM_SESSION_ID unset): the way launchd starts it
# 8. Claude never shows up in the session → exit 1, no TASK_STARTED, no Jira update, session
#    marked blocked; Claude shows up late → one more Enter, then started
# 9. control bytes in the Jira summary (Ctrl-A + `printf PWNED; #`, ESC sequences, DEL, a tab,
#    C1) and non-ASCII letters: only allowlisted bytes are typed; the brief keeps the summary
# 10. a key that is not PROJ-123 → clear error; nothing started
# 11. more than one agterm window: Claude in a window that is not in front still counts; a
#     session of the same ticket in another window blocks the start; the caller is found in
#     another window; a closed window is never asked; no window list → the frontmost tree
#
# The Jira summary holds " $ ! and a {{BRIEF}}: they must be dropped, or stay literal.
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: keep '&' literal in ${v//p/r}

here="$(cd "$(dirname "$0")" && pwd -P)"
script="$here/../scripts/start-task.sh"
default_tpl="$here/../references/brief-template.md"

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"   # the script resolves paths with pwd -P

key="PROJ-123"
# shellcheck disable=SC2016  # a literal $ on purpose: start-task.sh must drop it
summary='R&D rankings! no "way" to clear $filters {{BRIEF}}'
clean='R&D rankings no way to clear filters {{BRIEF}}'   # start-task.sh drops ! " $ ` \ and '
name="$key $clean"
status="To Do"
url="https://jira.example.com/browse/$key"
description="The filters stay on after a reload."

# ---- stubs ------------------------------------------------------------------------------------

mkdir -p "$tmp/bin"

cat > "$tmp/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
# Logs every call; "session type" also logs the typed text (the last argument).
# Windows: $STUB_WINDOWS (default "W1"; the first is in front), plus WC, which is closed.
# "window list --json": those windows; STUB_NO_WINDOW_LIST=1: an error (an older agterm).
# "tree --json [--window W]" (default: the front window): W1 = $STUB_TREE, W2 = $STUB_TREE_W2
# (default: empty). Once the claude command is typed, the tree of $STUB_CLAUDE_WINDOW (default
# W1) shows session SID-1 with claude in front, from its $STUB_CLAUDE_AFTER-th call on
# (default 1); STUB_NO_CLAUDE=1: never (Claude does not start).
printf '%s\n' "$*" >> "$STUB_LOG/agtermctl.calls"
win="" prev=""
for a in "$@"; do [ "$prev" != --window ] || win="$a"; prev="$a"; done
windows="${STUB_WINDOWS:-W1}"
[ -n "$win" ] || win="${windows%% *}"
case "$1 ${2:-}" in
  "window list")  [ "${STUB_NO_WINDOW_LIST:-}" != 1 ] || { echo '{"ok":false,"error":"unknown command"}'; exit 1; }
                  list='{"id":"WC","open":false}'
                  for w in $windows; do list="$list,{\"id\":\"$w\",\"open\":true}"; done
                  printf '{"ok":true,"result":{"windows":[%s]}}\n' "$list" ;;
  "tree --json")  case " $windows " in *" $win "*) : ;; *) echo '{"ok":false,"error":"window not open"}'; exit 1 ;; esac
                  empty='{"result":{"tree":{"workspaces":[]}}}'
                  if [ "$win" = "${STUB_CLAUDE_WINDOW:-W1}" ] && [ -e "$STUB_LOG/claude.typed" ] \
                     && [ "${STUB_NO_CLAUDE:-}" != 1 ]; then
                    echo x >> "$STUB_LOG/claude.typed"
                    if [ "$(wc -l < "$STUB_LOG/claude.typed")" -ge "${STUB_CLAUDE_AFTER:-1}" ]; then
                      echo '{"result":{"tree":{"workspaces":[{"sessions":[{"id":"SID-1","cwd":"/w","foreground":["claude","--session-id","x"]}]}]}}}'
                      exit 0
                    fi
                  fi
                  case "$win" in
                    W1) printf '%s\n' "${STUB_TREE:-$empty}" ;;
                    W2) printf '%s\n' "${STUB_TREE_W2:-$empty}" ;;
                    *)  printf '%s\n' "$empty" ;;
                  esac ;;
  "session new")  echo '{"result":{"id":"SID-1"}}' ;;
  "session type") printf '%s\n' "${!#}" >> "$STUB_LOG/typed"
                  case "${!#}" in "claude "*) : > "$STUB_LOG/claude.typed" ;; esac ;;
esac
exit 0
EOF

printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sleep"

cat > "$tmp/jira_stub.py" <<'EOF'
import json, os, sys
log = os.environ["STUB_LOG"]
args = sys.argv[1:]
with open(os.path.join(log, "jira.calls"), "a") as f:
    f.write(" ".join(args[:2]) + "\n")
if args[0] == "get":
    print(json.dumps({"summary": os.environ["STUB_SUMMARY"], "status": os.environ["STUB_STATUS"],
                      "url": os.environ["STUB_URL"], "description": os.environ["STUB_DESCRIPTION"]}))
elif args[0] == "comment":
    with open(os.path.join(log, "comment.txt"), "w") as f:
        f.write(args[args.index("--body") + 1])
EOF

cat > "$tmp/new-worktree.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG/new_wt.calls"
dir="$PARALLEL_ISSUES_ROOT/$1/.claude/worktrees/$2"
mkdir -p "$dir"
echo "WORKTREE_READY $dir"
EOF

chmod +x "$tmp/bin/agtermctl" "$tmp/bin/sleep" "$tmp/new-worktree.sh"

# The real agtermctl would open a real session. Stop here if the stub does not come first.
[ "$(PATH="$tmp/bin:$PATH" command -v agtermctl)" = "$tmp/bin/agtermctl" ] \
  || { echo "ERROR: the agtermctl stub is not first on PATH" >&2; exit 1; }

repo="$tmp/code/demo"
mkdir -p "$repo/.git"
wt="$repo/.claude/worktrees/$key"

cat > "$tmp/custom-extra.md" <<'EOF'
## 7. Custom part for {{KEY}}

{{URL}} | {{REPO}} | {{WORKTREE}} | {{BRANCH}}
{{SESSION_ID}} | {{JIRA_PY}} | {{REGISTRY}} | {{PROCS}}
EOF

# ---- helpers ----------------------------------------------------------------------------------

out="" rc=0 home="" log="" brief="" uuid="" branch=""
shell_bin=bash   # the bash that runs start-task.sh; case 7 uses /bin/bash
run_key=""       # the key start-task.sh gets, when not $key (case 10)

# run_case <name> [VAR=value ...]: start-task.sh in a fresh HOME, log dir and repo.
run_case() {
  local case_name="$1"; shift
  home="$tmp/$case_name/home"
  log="$tmp/$case_name/log"
  mkdir -p "$home" "$log"
  rm -rf "$repo/.claude"
  out="$(env -u TASK_SEED -u TASK_BRIEF_EXTRA -u TASK_NEXT -u AGTERM_SESSION_ID -u AGTERM_SOCKET -u STUB_TREE \
    -u STUB_NO_CLAUDE -u STUB_CLAUDE_AFTER -u STUB_WINDOWS -u STUB_TREE_W2 -u STUB_CLAUDE_WINDOW \
    -u STUB_NO_WINDOW_LIST \
    HOME="$home" PATH="$tmp/bin:$PATH" STUB_LOG="$log" AGTERM_ENABLED=1 \
    JIRA_PY="$tmp/jira_stub.py" NEW_WT="$tmp/new-worktree.sh" \
    STUB_SUMMARY="$summary" STUB_STATUS="$status" STUB_URL="$url" STUB_DESCRIPTION="$description" \
    "$@" "$shell_bin" "$script" "$repo" "${run_key:-$key}" 2>&1)"
  rc=$?
  brief="$home/.claude/task-briefs/$key.md"
  uuid="$(sed -n 's/^TASK_STARTED .* claude=\([^ ]*\) .*/\1/p' <<<"$out")"
  branch="$(sed -n 's/^TASK_STARTED .* branch=\([^ ]*\).*/\1/p' <<<"$out")"
}

# expect_eq <label> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"; printf '     expected: %s\n     actual:   %s\n' "$2" "$3"
  fi
}

# expect_has <label> <needle> <text>
expect_has() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1"; printf '     missing: %s\n' "$2" ;; esac
}

# expect_not_has <label> <needle> <text>
expect_not_has() {
  case "$3" in *"$2"*) bad "$1"; printf '     found: %s\n' "$2" ;; *) ok "$1" ;; esac
}

# The first typed text is the claude command; the next ones are Enter keys.
typed_command() { head -n 1 "$log/typed" 2>/dev/null; }

# expect_safe_typed <label>: the claude command holds only printable ASCII (bytes 040-176),
# exactly the 4 quotes around the name and the seed, and none of $ ` \ ' !.
expect_safe_typed() {
  local c rest quotes
  c="$(typed_command)"
  rest="$(printf '%s' "$c" | LC_ALL=C tr -d '\040-\176' | wc -c | tr -d ' ')"
  quotes="$(printf '%s' "$c" | LC_ALL=C tr -cd '"' | wc -c | tr -d ' ')"
  case "$c" in
    "" | *[\$\`\\\'!]*) bad "$1"; printf '     typed: %q\n' "$c" ;;
    *) if [ "$rest" = 0 ] && [ "$quotes" = 4 ]; then ok "$1"; else
         bad "$1"; printf '     typed: %q\n' "$c"
       fi ;;
  esac
}
typed_count() { wc -l < "$log/typed" 2>/dev/null | tr -d ' '; }
next_line() { grep '^- Next: ' "$log/comment.txt" 2>/dev/null; }

# expected_brief [extra]: the default template, then the extra file after a blank line, each
# with every placeholder filled, plus the ticket part.
expected_brief() {
  local f text k v kv sep=""
  for f in "$default_tpl" "$@"; do
    printf '%s' "$sep"
    sep=$'\n'
    text="$(cat "$f")"
    for kv in "KEY=$key" "URL=$url" "REPO=$repo" "WORKTREE=$wt" "BRANCH=$branch" \
              "SESSION_ID=$uuid" "JIRA_PY=$tmp/jira_stub.py" \
              "REGISTRY=$home/.claude/task-briefs/$key.env" "PROCS=$home/.claude/task-briefs/$key.procs"; do
      k="${kv%%=*}"; v="${kv#*=}"
      text="${text//"{{$k}}"/$v}"
    done
    printf '%s\n' "$text"
  done
  printf '\n## The ticket (from Jira, %s)\n\n**%s** — status %s\n\n%s\n' \
    "$(date +%F)" "$summary" "$status" "$description"
}

# expect_brief <label> [extra]
expect_brief() {
  if diff <(expected_brief "${@:2}") "$brief" >"$tmp/brief.diff" 2>&1; then ok "$1"; else
    bad "$1"; sed 's/^/     /' "$tmp/brief.diff" | head -20
  fi
}

# expect_nothing_started <label>: no worktree, no session, no Jira call, no brief.
expect_nothing_started() {
  if [ ! -e "$log/new_wt.calls" ] && [ ! -e "$log/jira.calls" ] && [ ! -e "$brief" ] \
     && ! grep -q '^session new' "$log/agtermctl.calls" 2>/dev/null; then
    ok "$1"
  else
    bad "$1"; ls "$log"
  fi
}

default_next="- Next: an implementation plan (planning:make). The plan summary will be posted here."

# ---- 1. no override: today's behaviour --------------------------------------------------------

run_case defaults
expect_eq "defaults: exit 0" 0 "$rc"
if [ -n "$uuid" ]; then ok "defaults: TASK_STARTED line"; else bad "defaults: TASK_STARTED line"; echo "$out"; fi
expect_eq "defaults: typed /planning:make seed" \
  "claude --session-id $uuid -n \"$name\" \"/planning:make $key: $clean. First read the task brief $brief and follow it for the whole task.\"" \
  "$(typed_command)"
expect_brief "defaults: brief from references/brief-template.md"
expect_eq "defaults: Jira Next line" "$default_next" "$(next_line)"
expect_eq "defaults: Jira calls get, transition, comment" \
  "$(printf 'get %s\ntransition %s\ncomment %s' "$key" "$key" "$key")" "$(cat "$log/jira.calls")"
expect_has "defaults: session opened in the worktree" \
  "session new --cwd $wt --name $name --json" "$(cat "$log/agtermctl.calls")"
expect_eq "defaults: Claude runs at once, so no extra Enter" 2 "$(typed_count)"
expect_has "defaults: session marked active" "session status active --target SID-1" "$(cat "$log/agtermctl.calls")"

# ---- 2. all three overrides -------------------------------------------------------------------

run_case overrides \
  TASK_SEED='/security-check example-host --ticket {{KEY}}. First read the task brief {{BRIEF}} and follow it ({{SUMMARY}}).' \
  TASK_BRIEF_EXTRA="$tmp/custom-extra.md" \
  TASK_NEXT='a security report (/security-check). The report summary will be posted here.'
expect_eq "overrides: exit 0" 0 "$rc"
expect_eq "overrides: typed custom seed, placeholders filled" \
  "claude --session-id $uuid -n \"$name\" \"/security-check example-host --ticket $key. First read the task brief $brief and follow it ($clean).\"" \
  "$(typed_command)"
expect_brief "overrides: default brief, then the extra file, then the ticket" "$tmp/custom-extra.md"
expect_eq "overrides: Jira Next line" \
  "- Next: a security report (/security-check). The report summary will be posted here." "$(next_line)"

# ---- 3. empty overrides = defaults ------------------------------------------------------------

run_case empty TASK_SEED= TASK_BRIEF_EXTRA= TASK_NEXT=
expect_eq "empty: exit 0" 0 "$rc"
expect_has "empty: typed /planning:make seed" "\"/planning:make $key: $clean. First read" "$(typed_command)"
expect_brief "empty: default brief"
expect_eq "empty: Jira Next line" "$default_next" "$(next_line)"

# ---- 4. missing extra brief -------------------------------------------------------------------

run_case missing TASK_BRIEF_EXTRA="$tmp/no-such-extra.md"
expect_eq "missing extra brief: exit 1" 1 "$rc"
expect_has "missing extra brief: error names the file" \
  "ERROR: extra brief not found at $tmp/no-such-extra.md (TASK_BRIEF_EXTRA)" "$out"
expect_nothing_started "missing extra brief: nothing started"

# ---- 5. seed the typed shell would expand -----------------------------------------------------

# Also every control byte: Ctrl-A (start of line) + a command, ESC, DEL, a tab, C1 (as UTF-8 and
# as a raw byte), and non-ASCII text.
# shellcheck disable=SC2016  # literal $( ) and backticks on purpose
for seed in '/security-check x --ticket {{KEY}} "$(id)"' '/x $(id)' '/x `id`' '/x a\b' '/x hi!' \
            "$(printf '/x a\nb')" "$(printf '/x a\rb')" "/x it's" \
            "$(printf '/x a\001printf PWNED; #')" "$(printf '/x \033[2K\033]0;t\007b')" \
            "$(printf '/x a\177b')" "$(printf '/x a\tb')" "$(printf '/x \302\233b')" \
            "$(printf '/x \233b')" '/x Привет'; do
  run_case badseed TASK_SEED="$seed"
  expect_eq "bad seed $(printf '%q' "$seed"): exit 1" 1 "$rc"
  expect_has "bad seed: error says why" "ERROR: TASK_SEED may hold only printable ASCII" "$out"
  expect_nothing_started "bad seed: nothing started"
  rm -rf "$tmp/badseed"
done

# ---- 6. one session per ticket ----------------------------------------------------------------

# The shape of "agtermctl tree --json": result.tree.workspaces[].sessions[].
tree_with() { printf '{"result":{"tree":{"workspaces":[{"sessions":[{"id":"SID-9","name":"%s","cwd":"/w"}]}]}}}' "$1"; }

run_case other STUB_TREE="$(tree_with "PROJ-1234 Another ticket")"
expect_eq "open session of PROJ-1234: PROJ-123 still starts" 0 "$rc"

run_case same STUB_TREE="$(tree_with "$key Earlier try")"
expect_eq "open session of the same ticket: exit 1" 1 "$rc"
expect_has "open session of the same ticket: says so" "an agterm session for $key already exists (sid=SID-9)" "$out"
expect_nothing_started "open session of the same ticket: nothing started"

# ---- 7. macOS /bin/bash, no caller session ---------------------------------------------------

# launchd runs the due script with /bin/bash (3.2 on macOS) and no AGTERM_SESSION_ID. bash 3.2
# calls an empty array "unbound" under set -u, so an unguarded "${arr[@]}" stops the script.
if [ -x /bin/bash ]; then
  shell_bin=/bin/bash
  run_case sysbash
  shell_bin=bash
  expect_eq "/bin/bash: exit 0" 0 "$rc"
  if [ -n "$uuid" ]; then ok "/bin/bash: TASK_STARTED line"; else bad "/bin/bash: TASK_STARTED line"; echo "$out"; fi
  expect_has "/bin/bash: session opened without --after" \
    "session new --cwd $wt --name $name --json" "$(cat "$log/agtermctl.calls")"
  expect_eq "/bin/bash: typed /planning:make seed" \
    "claude --session-id $uuid -n \"$name\" \"/planning:make $key: $clean. First read the task brief $brief and follow it for the whole task.\"" \
    "$(typed_command)"
else
  echo "WARN: no /bin/bash - skipped the system bash case"
fi

# ---- 8. Claude must run in the session before the task counts as started ----------------------

run_case noclaude STUB_NO_CLAUDE=1
expect_eq "Claude does not start: exit 1" 1 "$rc"
expect_has "Claude does not start: says so" "ERROR: Claude did not start in the agterm session '$name' (sid=SID-1)" "$out"
expect_not_has "Claude does not start: no TASK_STARTED line" "TASK_STARTED" "$out"
expect_eq "Claude does not start: Jira only read, no transition, no comment" "get $key" "$(cat "$log/jira.calls")"
expect_has "Claude does not start: session marked blocked" "session status blocked --target SID-1" "$(cat "$log/agtermctl.calls")"
expect_eq "Claude does not start: one extra Enter, not more" 3 "$(typed_count)"

run_case lateclaude STUB_CLAUDE_AFTER=3
expect_eq "Claude starts late: exit 0" 0 "$rc"
if [ -n "$uuid" ]; then ok "Claude starts late: TASK_STARTED line"; else bad "Claude starts late: TASK_STARTED line"; echo "$out"; fi
expect_eq "Claude starts late: one extra Enter" 3 "$(typed_count)"
expect_eq "Claude starts late: Jira get, transition, comment" \
  "$(printf 'get %s\ntransition %s\ncomment %s' "$key" "$key" "$key")" "$(cat "$log/jira.calls")"

# ---- 9. control bytes and non-ASCII in the Jira summary ---------------------------------------

# summary_case <name> <summary> <clean>: started, the typed command holds only safe bytes, the
# name and seed use <clean>, the brief keeps the summary as Jira has it.
summary_case() {
  local cname="$1" raw="$2" want="$3"
  run_case "$cname" STUB_SUMMARY="$raw"
  expect_eq "$cname: exit 0" 0 "$rc"
  expect_safe_typed "$cname: only safe bytes typed"
  expect_eq "$cname: typed command" \
    "claude --session-id $uuid -n \"$key${want:+ $want}\" \"/planning:make $key: $want. First read the task brief $brief and follow it for the whole task.\"" \
    "$(typed_command)"
  expect_has "$cname: brief keeps the Jira summary" "**$raw** — status" "$(cat "$brief" 2>/dev/null)"
}

# Ctrl-A moves the cursor to the start of the line: the rest would run as a command.
summary_case ctrl_a "$(printf 'Fix filters\001printf PWNED; #')" 'Fix filters printf PWNED; #'
summary_case esc "$(printf 'Fix \033[2K\033]0;title\007filters')" 'Fix 2K 0;title filters'
summary_case del "$(printf 'Fix\177\177\177filters')" 'Fix filters'
summary_case tab "$(printf 'Fix\tfilters\r')" 'Fix filters'
summary_case c1 "$(printf 'Fix \302\23331mfilters \302\205x')" 'Fix 31mfilters x'
summary_case utf8 'Фильтры: fix café filters' ': fix caf filters'
expect_eq "utf8: branch from the kept ASCII" "$key-fix-caf-filters" "$branch"

# Nothing kept: the name and the branch are the key alone.
summary_case cyrillic 'Фильтры не сбрасываются' ''
expect_eq "cyrillic: branch is the key" "$key" "$branch"
expect_has "cyrillic: session named by the key" "session new --cwd $wt --name $key --json" "$(cat "$log/agtermctl.calls")"
run_case cyrillic_again STUB_SUMMARY='Фильтры' STUB_TREE="$(tree_with "$key")"
expect_eq "session named only by the key: a second start is blocked" 1 "$rc"
expect_nothing_started "session named only by the key: nothing started"

# ---- 10. a key that is not PROJ-123 -----------------------------------------------------------

# shellcheck disable=SC2016  # a literal $( ) on purpose
for run_key in 'PROJ-1"; id; "' "$(printf 'PROJ-1\001x')" 'proj-1' 'PROJ-' '-1' 'PROJ-1x' 'PR$(id)-1' 'ПРОЕКТ-1'; do
  run_case badkey
  expect_eq "bad key $(printf '%q' "$run_key"): exit 1" 1 "$rc"
  expect_has "bad key: error says why" "is not a Jira key" "$out"
  expect_nothing_started "bad key: nothing started"
  rm -rf "$tmp/badkey"
done
run_key=""

# ---- 11. more than one agterm window ----------------------------------------------------------

# The user brought window W1 to the front; the new session is in W2.
run_case otherwindow STUB_WINDOWS="W1 W2" STUB_CLAUDE_WINDOW=W2
expect_eq "Claude in a window not in front: exit 0" 0 "$rc"
if [ -n "$uuid" ]; then ok "Claude in a window not in front: TASK_STARTED line"; else
  bad "Claude in a window not in front: TASK_STARTED line"; echo "$out"
fi
expect_has "Claude in a window not in front: W2 asked" "tree --json --window W2" "$(cat "$log/agtermctl.calls")"
expect_not_has "Claude in a window not in front: no closed window asked" "--window WC" "$(cat "$log/agtermctl.calls")"
expect_eq "Claude in a window not in front: Jira get, transition, comment" \
  "$(printf 'get %s\ntransition %s\ncomment %s' "$key" "$key" "$key")" "$(cat "$log/jira.calls")"

run_case samewindow2 STUB_WINDOWS="W1 W2" STUB_TREE_W2="$(tree_with "$key Earlier try")"
expect_eq "same ticket open in another window: exit 1" 1 "$rc"
expect_has "same ticket open in another window: says so" "an agterm session for $key already exists (sid=SID-9)" "$out"
expect_nothing_started "same ticket open in another window: nothing started"

run_case caller2 STUB_WINDOWS="W1 W2" STUB_TREE_W2="$(tree_with "PROJ-9 The caller")" AGTERM_SESSION_ID=SID-9
expect_eq "caller in another window: exit 0" 0 "$rc"
expect_has "caller in another window: new session right after it" \
  "session new --cwd $wt --after SID-9 --name $name --json" "$(cat "$log/agtermctl.calls")"

# An agterm without "window list": the frontmost tree, as before.
run_case nowindowlist STUB_NO_WINDOW_LIST=1
expect_eq "no window list: exit 0" 0 "$rc"
expect_has "no window list: the frontmost tree" "$(printf 'window list --json\ntree --json\n')" "$(cat "$log/agtermctl.calls")"

echo
if [ "$fails" -eq 0 ]; then
  echo "start_task_test: all passed"
  exit 0
fi
echo "start_task_test: $fails failed"
exit 1
