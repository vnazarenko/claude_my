#!/usr/bin/env bash
# Tests for scripts/session-log-check.sh. Each case is a temp git repo whose origin/main is a
# local ref set with `git update-ref`: no network, no real repo touched.
#
# Usage:
#   session_log_check_test.sh
#
# 1. a file dated on/after STARTED → yes, names the file
# 2. only an older file of the same id (another session that shared the prefix) → NO
# 3. a `-2` file → yes
# 4. no file, but a line in the old .claude/SESSIONS.md dated on/after STARTED → yes via the old file
# 5. old line with the full UUID → yes; old line dated before STARTED → NO
# 6. no STARTED → yes, and says the date was not checked
# 7. neither the folder nor the old file on origin/main → says so
# 8. no session id → NO
# 9. a file only on the branch, not on origin/main → NO
# 10. old line with a date range that ENDS on/after STARTED (`2026-10-24..27`, STARTED 10-26) → yes;
#     `..11-02` and `/27` forms too
# 11. the default branch is not main (origin/HEAD → origin/command-hq) → reads that branch
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
script="$here/../scripts/session-log-check.sh"

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2], got [$3]"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sid="5bdcecff-ae41-442b-8209-9279fdedbf9e"
started="2026-10-27T14:00:00"

# new_repo <name> <file>=<content>... — commits the files and points origin/main at that commit
new_repo() {
  local repo="$tmp/$1"; shift
  git init -q "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  mkdir -p "$repo/.claude/sessions"
  local pair
  for pair in "$@"; do printf '%s\n' "${pair#*=}" > "$repo/${pair%%=*}"; done
  echo x > "$repo/README"
  git -C "$repo" add -A
  git -C "$repo" commit -qm init
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  echo "$repo"
}

line='- 2026-10-27 · 5bdcecff · [KAN-345] x'

r="$(new_repo new ".claude/sessions/2026-10-27-5bdcecff.md=$line")"
expect_eq "file on/after STARTED: yes" "on origin/main: yes (5bdcecff, .claude/sessions/2026-10-27-5bdcecff.md)" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo older ".claude/sessions/2026-07-18-5bdcecff.md=- 2026-07-18 · 5bdcecff · [old] y")"
expect_eq "only an older file: NO" "on origin/main: NO — this session has no file in .claude/sessions/ yet" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo second ".claude/sessions/2026-10-27-5bdcecff-2.md=$line")"
expect_eq "-2 file: yes" "on origin/main: yes (5bdcecff, .claude/sessions/2026-10-27-5bdcecff-2.md)" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo legacy ".claude/SESSIONS.md=$line")"
expect_eq "old file line: yes" "on origin/main: yes (5bdcecff, line in the old .claude/SESSIONS.md)" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo legacyuuid ".claude/SESSIONS.md=- 2026-10-28 · $sid · [KAN-345] x")"
expect_eq "old file, full UUID: yes" "on origin/main: yes (5bdcecff, line in the old .claude/SESSIONS.md)" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo legacyold ".claude/SESSIONS.md=- 2026-07-18 · 5bdcecff · [old] y")"
expect_eq "old file, older line: NO" "on origin/main: NO — this session has no file in .claude/sessions/ yet" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo nostart ".claude/sessions/2026-07-18-5bdcecff.md=- 2026-07-18 · 5bdcecff · [old] y")"
expect_eq "no STARTED: yes, date not checked" \
  "on origin/main: yes (5bdcecff, .claude/sessions/2026-07-18-5bdcecff.md) — registry has no STARTED, so the date was not checked" \
  "$("$script" "$r" "$sid" "")"

r="$(new_repo none)"
expect_eq "no log at all: says so" "(neither .claude/sessions/ nor .claude/SESSIONS.md is on origin/main)" \
  "$("$script" "$r" "$sid" "$started")"

r="$(new_repo nosid ".claude/sessions/2026-10-27-5bdcecff.md=$line")"
expect_eq "no session id: NO" "on origin/main: NO — this session has no file in .claude/sessions/ yet" \
  "$("$script" "$r" "" "$started")"

r="$(new_repo branchonly ".claude/sessions/2026-10-20-0a1b2c3d.md=- 2026-10-20 · 0a1b2c3d · [other] z")"
printf '%s\n' "$line" > "$r/.claude/sessions/2026-10-27-5bdcecff.md"
git -C "$r" add -A && git -C "$r" commit -qm "branch only"
expect_eq "file only on the branch: NO" "on origin/main: NO — this session has no file in .claude/sessions/ yet" \
  "$("$script" "$r" "$sid" "$started")"

for range in '2026-10-24..27' '2026-10-20..11-02' '2026-10-24/27'; do
  r="$(new_repo "range-${range//[\/.]/_}" ".claude/SESSIONS.md=- $range · 5bdcecff · [KAN-345] x")"
  expect_eq "old range $range, STARTED inside it: yes" \
    "on origin/main: yes (5bdcecff, line in the old .claude/SESSIONS.md)" "$("$script" "$r" "$sid" 2026-10-26)"
done
r="$(new_repo rangeold ".claude/SESSIONS.md=- 2026-10-20..25 · 5bdcecff · [old] y")"
expect_eq "old range that ends before STARTED: NO" "on origin/main: NO — this session has no file in .claude/sessions/ yet" \
  "$("$script" "$r" "$sid" 2026-10-26)"

r="$(new_repo otherdefault ".claude/sessions/2026-10-27-5bdcecff.md=$line")"
git -C "$r" update-ref refs/remotes/origin/command-hq HEAD
git -C "$r" update-ref -d refs/remotes/origin/main
git -C "$r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/command-hq
expect_eq "default branch command-hq: read" "on origin/command-hq: yes (5bdcecff, .claude/sessions/2026-10-27-5bdcecff.md)" \
  "$("$script" "$r" "$sid" "$started")"

echo
if [ "$fails" -eq 0 ]; then
  echo "session_log_check_test: all passed"
  exit 0
fi
echo "session_log_check_test: $fails failed"
exit 1
