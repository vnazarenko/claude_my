#!/usr/bin/env bash
# Lint the security-check skill: frontmatter, file references, run-brief placeholders, and the
# public-repo rules (no IPs, session links, Jira links, home paths or private words). The checks
# are in skill_lint.py, next to this file; its docstring lists them.
#
# Usage:
#   skill_lint.sh [SKILL_DIR]     (default: the skill this file belongs to)
#
# The private words come from $SECURITY_CHECK_PRIVATE_WORDS, else
# ~/.config/security-check/private-words.txt. The list is local and never committed.
#
# Prints one line per problem. Exit 0 clean, 1 a check failed, 2 bad usage.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
skill="${1:-$(dirname "$here")}"
words="${SECURITY_CHECK_PRIVATE_WORDS:-$HOME/.config/security-check/private-words.txt}"

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }   # die <message> [exit code]

[ -d "$skill" ] || die "no such folder: $skill" 2
[ -f "$skill/SKILL.md" ] || die "no SKILL.md in $skill" 2
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH" 2

exec python3 "$here/skill_lint.py" "$skill" "$words"
