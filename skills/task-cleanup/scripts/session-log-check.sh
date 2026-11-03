#!/usr/bin/env bash
# Says whether a session's log entry reached the default branch. READ-ONLY. Called by task-evidence.sh
# for its SESSIONLOG section.
#
#   session-log-check.sh <repo> <session-id> [started]
#
# The log is one file per session per PR: <default branch>:.claude/sessions/<YYYY-MM-DD>-<id8>[-N].md
# (KAN-345, "Per-project session log" in ~/.claude/CLAUDE.md). A repo not moved yet still has the
# old .claude/SESSIONS.md; a line there counts too. The default branch is read from origin/HEAD
# (command_hq's is `command-hq`); origin/main when that is not set.
#
# The 8-char prefix alone is not proof: 2026-10-23 it matched a 2026-07-18 line, and this said
# "yes" for a session that had no line. Only a file (or line) dated on or after STARTED counts.
# STARTED may be empty (a HAND-BUILT registry has none): then say the date was not checked,
# never a false NO — a false NO sends the next session to open a PR it does not need.
set -uo pipefail

repo="${1:?repo required}"
sid="${2:-}"
started="${3:-}"
id8="${sid:0:8}"
ref="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"

found() {
  if [ -n "$started" ]; then
    echo "on $ref: yes ($id8, $1)"
  else
    echo "on $ref: yes ($id8, $1) — registry has no STARTED, so the date was not checked"
  fi
  exit 0
}

files="$(git -C "$repo" ls-tree --name-only "$ref" .claude/sessions/ 2>/dev/null)"
legacy=no
if git -C "$repo" cat-file -e "$ref:.claude/SESSIONS.md" 2>/dev/null; then legacy=yes; fi

if [ -z "$files" ] && [ "$legacy" = no ]; then
  echo "(neither .claude/sessions/ nor .claude/SESSIONS.md is on $ref)"
  exit 0
fi

if [ -n "$sid" ]; then
  hit="$(printf '%s\n' "$files" | sed 's#.*/##' \
    | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}-${id8}(-[0-9]+)?\.md$" \
    | awk -v s="${started:0:10}" 'substr($0, 1, 10) >= s' | tail -1)"
  if [ -n "$hit" ]; then found ".claude/sessions/$hit"; fi

  # The old line may carry the full UUID (the old rule allowed it), not only the 8-char prefix.
  # Its date may be a range (`2026-10-24..27`, `..11-02`, `/27`): compare the END of it, as the
  # split script names the file.
  if [ "$legacy" = yes ] && git -C "$repo" show "$ref:.claude/SESSIONS.md" \
       | grep -E "· ${id8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})? ·" \
       | awk -v s="${started:0:10}" '{
           d = substr($2, 1, 10); rest = substr($2, 13)
           if (substr($2, 11, 1) == "/") rest = substr($2, 12)
           if (rest ~ /^[0-9][0-9]$/) d = substr(d, 1, 8) rest
           else if (rest ~ /^[0-9][0-9]-[0-9][0-9]$/) d = substr(d, 1, 5) rest
           if (d >= s) f = 1
         } END { exit !f }'; then
    found "line in the old .claude/SESSIONS.md"
  fi
fi

echo "on $ref: NO — this session has no file in .claude/sessions/ yet"
