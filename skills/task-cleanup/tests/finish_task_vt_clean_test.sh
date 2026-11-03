#!/usr/bin/env bash
# Tests for the `vt clean` step of scripts/finish-task.sh (KAN-437): before it removes a task
# worktree, the finisher frees that worktree's copy on vtserv. Nothing real is touched: HOME is a
# temp dir, the repo and worktree are temp git repos, `vt`, `agtermctl` and the Jira script are
# stubs, and the finisher runs as a COPY next to a stub task-processes.sh (so it kills nothing).
#
# Usage:
#   finish_task_vt_clean_test.sh
#
# 1. clean worktree, vt clean succeeds → vt ran INSIDE the worktree, before it was removed; noted
# 2. vt clean exits 69 (vtserv down) → noted with the code; the worktree is still removed
# 3. vt clean exits 75 (a run still holds the copy) → noted; the worktree is still removed
# 4. no vt command → "NOT CLEANED" noted; the worktree is still removed
# 5. real uncommitted work → vt is NOT called and the worktree is kept
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
real_script="${FINISH_TASK:-$here/../scripts/finish-task.sh}"   # FINISH_TASK: a copy to mutation-check

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stubs. vt logs where it ran and whether that directory still existed, then exits $VT_STUB_RC.
mkdir -p "$tmp/bin" "$tmp/bin-novt" "$tmp/scripts"
cat >"$tmp/bin/vt" <<'EOF'
#!/usr/bin/env bash
echo "cwd=$(pwd -P) args=$*" >>"$VT_LOG"
exit "${VT_STUB_RC:-0}"
EOF
cat >"$tmp/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cp "$tmp/bin/agtermctl" "$tmp/bin-novt/agtermctl"
chmod +x "$tmp/bin/vt" "$tmp/bin/agtermctl" "$tmp/bin-novt/agtermctl"
cat >"$tmp/jira.py" <<'EOF'
import os, sys
with open(os.environ["JIRA_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
EOF
cp "$real_script" "$tmp/scripts/finish-task.sh"
# The finisher's PATH is an allowlist: only the tools it uses, linked one by one, so no real `vt`
# (in ~/bin, /opt/homebrew/bin or anywhere else) can be found and reach the real vtserv.
mkdir -p "$tmp/tools"
for t in bash git python3 pgrep ps basename dirname sleep seq sed grep cut mkdir mv date cat tr env rm; do
  ln -s "$(command -v "$t")" "$tmp/tools/$t"
done
cat >"$tmp/scripts/task-processes.sh" <<'EOF'
#!/usr/bin/env bash
echo "--- after stop ---"
echo "processes: none"
EOF

# One case: a fresh repo + worktree + registry, then the finisher, inline (no --detach).
run_case() { # <n> <PATH bin dir> <vt rc> <dirty: 0|1>
  local n="$1" bindir="$2" rc="$3" dirty="$4" home="$tmp/home$1" repo="$tmp/repo$1"
  mkdir -p "$home/.claude/task-briefs"
  git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'a\n' >"$repo/file"
  git -C "$repo" add file
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m file
  WT="$repo/.claude/worktrees/K-$n"
  git -C "$repo" worktree add -q "$WT" -b "K-$n-branch"
  WT="$(cd "$WT" && pwd -P)"
  [ "$dirty" = 1 ] && printf 'changed\n' >"$WT/file"
  cat >"$home/.claude/task-briefs/K-$n.env" <<EOF
REPO=$repo
WORKTREE=$WT
BRANCH=K-$n-branch
AGTERM_SESSION_ID=fake-agterm-$n
CLAUDE_SESSION_ID=$(uuidgen | tr 'A-Z' 'a-z')
SESSION_NAME=fake-$n
MERGE_PROVEN=0
EOF
  VT_LOG="$tmp/vt$n.log" JIRA_LOG="$tmp/jira$n.log" VT_STUB_RC="$rc" HOME="$home" DELAY=0 \
    JIRA_PY="$tmp/jira.py" PATH="$bindir:$tmp/tools" \
    bash "$tmp/scripts/finish-task.sh" "K-$n" >"$tmp/out$n.log" 2>&1
  touch "$tmp/vt$n.log" "$tmp/jira$n.log"
}

run_case 1 "$tmp/bin" 0 0
check "1: vt clean ran inside the worktree" grep -qx "cwd=$WT args=clean" "$tmp/vt1.log"
check "1: the worktree was removed after it" test ! -e "$WT"
check "1: the Jira note says the vtserv copy was removed" grep -q 'vtserv copy of the worktree removed (vt clean)' "$tmp/jira1.log"
check "1: and that the worktree was removed" grep -q "worktree $WT removed" "$tmp/jira1.log"

run_case 2 "$tmp/bin" 69 0
check "2: vt clean was tried" grep -q 'args=clean' "$tmp/vt2.log"
check "2: exit 69 is noted" grep -q 'vtserv copy NOT removed (vt clean exit 69' "$tmp/jira2.log"
check "2: the worktree is still removed" test ! -e "$WT"

run_case 3 "$tmp/bin" 75 0
check "3: exit 75 is noted" grep -q 'vtserv copy NOT removed (vt clean exit 75' "$tmp/jira3.log"
check "3: the worktree is still removed" test ! -e "$WT"

check "4: setup: the finisher's PATH for this case finds no vt" test -z "$(PATH="$tmp/bin-novt:$tmp/tools" command -v vt)"
run_case 4 "$tmp/bin-novt" 0 0
check "4: no vt: NOT CLEANED is noted" grep -q 'vtserv copy NOT CLEANED: no vt command found' "$tmp/jira4.log"
check "4: the worktree is still removed" test ! -e "$WT"

run_case 5 "$tmp/bin" 0 1
check "5: real uncommitted work: vt is not called" test ! -s "$tmp/vt5.log"
check "5: the worktree is kept" test -e "$WT/file"
check "5: and the note says so" grep -q 'WORKTREE KEPT: it has uncommitted work' "$tmp/jira5.log"

if ((fails)); then
  printf '\n%d failed — finisher output of each case: %s/out<n>.log\n' "$fails" "$tmp"
  trap - EXIT
  exit 1
fi
printf '\nall passed\n'
