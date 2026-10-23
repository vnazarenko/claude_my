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
# 2. TASK_SEED, TASK_BRIEF_TEMPLATE and TASK_NEXT set → all three used, placeholders filled
# 3. overrides set but empty → the defaults
# 4. TASK_BRIEF_TEMPLATE names a missing file → clear error; no worktree, no session, no Jira
# 5. TASK_SEED with a character the typed shell would expand → clear error; nothing started
# 6. an open agterm session of the same ticket blocks the start; one of PROJ-1234 does not
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
printf '%s\n' "$*" >> "$STUB_LOG/agtermctl.calls"
case "$1 ${2:-}" in
  "tree --json")  empty='{"result":{"tree":{"workspaces":[]}}}'
                  printf '%s\n' "${STUB_TREE:-$empty}" ;;
  "session new")  echo '{"result":{"id":"SID-1"}}' ;;
  "session type") printf '%s\n' "${!#}" >> "$STUB_LOG/typed" ;;
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

cat > "$tmp/custom-brief.md" <<'EOF'
# Custom brief {{KEY}}

{{URL}} | {{REPO}} | {{WORKTREE}} | {{BRANCH}}
{{SESSION_ID}} | {{JIRA_PY}} | {{REGISTRY}} | {{PROCS}}
EOF

# ---- helpers ----------------------------------------------------------------------------------

out="" rc=0 home="" log="" brief="" uuid="" branch=""

# run_case <name> [VAR=value ...]: start-task.sh in a fresh HOME, log dir and repo.
run_case() {
  local case_name="$1"; shift
  home="$tmp/$case_name/home"
  log="$tmp/$case_name/log"
  mkdir -p "$home" "$log"
  rm -rf "$repo/.claude"
  out="$(env -u TASK_SEED -u TASK_BRIEF_TEMPLATE -u TASK_NEXT -u AGTERM_SESSION_ID -u AGTERM_SOCKET -u STUB_TREE \
    HOME="$home" PATH="$tmp/bin:$PATH" STUB_LOG="$log" AGTERM_ENABLED=1 \
    JIRA_PY="$tmp/jira_stub.py" NEW_WT="$tmp/new-worktree.sh" \
    STUB_SUMMARY="$summary" STUB_STATUS="$status" STUB_URL="$url" STUB_DESCRIPTION="$description" \
    "$@" bash "$script" "$repo" "$key" 2>&1)"
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

# The first typed text is the claude command; the next ones are Enter keys.
typed_command() { head -n 1 "$log/typed" 2>/dev/null; }
next_line() { grep '^- Next: ' "$log/comment.txt" 2>/dev/null; }

# expected_brief <template>: the template with every placeholder filled, plus the ticket part.
expected_brief() {
  local text k v kv
  text="$(cat "$1")"
  for kv in "KEY=$key" "URL=$url" "REPO=$repo" "WORKTREE=$wt" "BRANCH=$branch" \
            "SESSION_ID=$uuid" "JIRA_PY=$tmp/jira_stub.py" \
            "REGISTRY=$home/.claude/task-briefs/$key.env" "PROCS=$home/.claude/task-briefs/$key.procs"; do
    k="${kv%%=*}"; v="${kv#*=}"
    text="${text//"{{$k}}"/$v}"
  done
  printf '%s\n' "$text"
  printf '\n## The ticket (from Jira, %s)\n\n**%s** — status %s\n\n%s\n' \
    "$(date +%F)" "$summary" "$status" "$description"
}

# expect_brief <label> <template>
expect_brief() {
  if diff <(expected_brief "$2") "$brief" >"$tmp/brief.diff" 2>&1; then ok "$1"; else
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
expect_brief "defaults: brief from references/brief-template.md" "$default_tpl"
expect_eq "defaults: Jira Next line" "$default_next" "$(next_line)"
expect_eq "defaults: Jira calls get, transition, comment" \
  "$(printf 'get %s\ntransition %s\ncomment %s' "$key" "$key" "$key")" "$(cat "$log/jira.calls")"
expect_has "defaults: session opened in the worktree" \
  "session new --cwd $wt --name $name --json" "$(cat "$log/agtermctl.calls")"

# ---- 2. all three overrides -------------------------------------------------------------------

run_case overrides \
  TASK_SEED='/security-check example-host --ticket {{KEY}}. First read the task brief {{BRIEF}} and follow it ({{SUMMARY}}).' \
  TASK_BRIEF_TEMPLATE="$tmp/custom-brief.md" \
  TASK_NEXT='a security report (/security-check). The report summary will be posted here.'
expect_eq "overrides: exit 0" 0 "$rc"
expect_eq "overrides: typed custom seed, placeholders filled" \
  "claude --session-id $uuid -n \"$name\" \"/security-check example-host --ticket $key. First read the task brief $brief and follow it ($clean).\"" \
  "$(typed_command)"
expect_brief "overrides: brief from the custom template" "$tmp/custom-brief.md"
expect_eq "overrides: Jira Next line" \
  "- Next: a security report (/security-check). The report summary will be posted here." "$(next_line)"

# ---- 3. empty overrides = defaults ------------------------------------------------------------

run_case empty TASK_SEED= TASK_BRIEF_TEMPLATE= TASK_NEXT=
expect_eq "empty: exit 0" 0 "$rc"
expect_has "empty: typed /planning:make seed" "\"/planning:make $key: $clean. First read" "$(typed_command)"
expect_brief "empty: default brief" "$default_tpl"
expect_eq "empty: Jira Next line" "$default_next" "$(next_line)"

# ---- 4. missing custom template ---------------------------------------------------------------

run_case missing TASK_BRIEF_TEMPLATE="$tmp/no-such-brief.md"
expect_eq "missing template: exit 1" 1 "$rc"
expect_has "missing template: error names the file" \
  "ERROR: brief template not found at $tmp/no-such-brief.md (TASK_BRIEF_TEMPLATE)" "$out"
expect_nothing_started "missing template: nothing started"

# ---- 5. seed the typed shell would expand -----------------------------------------------------

# shellcheck disable=SC2016  # literal $( ) and backticks on purpose
for seed in '/security-check x --ticket {{KEY}} "$(id)"' '/x $(id)' '/x `id`' '/x a\b' '/x hi!' \
            "$(printf '/x a\nb')" "$(printf '/x a\rb')"; do
  run_case badseed TASK_SEED="$seed"
  expect_eq "bad seed $(printf '%q' "$seed"): exit 1" 1 "$rc"
  expect_has "bad seed: error says why" "ERROR: TASK_SEED must not contain" "$out"
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

echo
if [ "$fails" -eq 0 ]; then
  echo "start_task_test: all passed"
  exit 0
fi
echo "start_task_test: $fails failed"
exit 1
