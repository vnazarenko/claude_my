#!/usr/bin/env bash
# Tests for tests/skill_lint.sh.
#
# Usage:
#   skill_lint_test.sh
#
# 1. the real skill passes, with a private word list and without one (then a warning)
# 2. a copy of the skill with one planted problem fails, and the output names the check
# 3. look-alikes that are allowed pass: documentation IPs, versions in fixtures,
#    5-part versions, other skills' paths, a folded description
#
# The bad strings are built at run time, so this file stays clean for the lint itself.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
lint="$here/skill_lint.sh"
skill="$(dirname "$here")"

# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$here/lib.sh"

command -v perl >/dev/null 2>&1 || die "perl not on PATH"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Built at run time: a private word, an IP, an IP-like version, a session link, a trailer,
# a Jira link, a home path.
word="$(printf 'zz%sword' '-test-')"
ip="$(printf '%s.%s.%s.%s' 10 20 30 40)"
ver="$(printf '%s.%s.%s.%s' 24 8 1 1)"
session_link="$(printf 'https://claude%sai/code/session_x' '.')"
trailer="$(printf 'Claude-%s: abc' Session)"
jira_link="$(printf 'https://example.atlassian%snet/browse/PROJ-1' '.')"
home_path="$(printf '/%s/someone/notes' Users)"

printf '%s\n' '# test list' '' "$word" > "$tmp/words.txt"
export SECURITY_CHECK_PRIVATE_WORDS="$tmp/words.txt"

out="" rc=0
c=""

# A fresh copy of the skill in a folder with the same name.
fresh() {
  rm -rf "$tmp/c"
  mkdir -p "$tmp/c"
  cp -R "$skill" "$tmp/c/security-check"
  c="$tmp/c/security-check"
  find "$c" -name __pycache__ -type d -prune -exec rm -rf {} +
}

run_lint() {
  out="$(bash "$lint" "$@" 2>&1)"
  rc=$?
}

# expect_fail <label> <check name in the output>
expect_fail() {
  run_lint "$c"
  if [ "$rc" -eq 1 ] && grep -q "^FAIL $2:" <<< "$out"; then
    ok "$1"
  else
    bad "$1 (exit $rc, wanted 1 and 'FAIL $2')"
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
}

expect_pass() {
  run_lint "$c"
  if [ "$rc" -eq 0 ]; then
    ok "$1"
  else
    bad "$1 (exit $rc, wanted 0)"
    printf '%s\n' "$out" | sed 's/^/     /'
  fi
}

# ---- 1. the real skill ------------------------------------------------------------------------

run_lint "$skill"
if [ "$rc" -eq 0 ] && grep -q '^skill_lint: ok' <<< "$out"; then ok "real skill passes"; else
  bad "real skill passes (exit $rc)"; printf '%s\n' "$out" | sed 's/^/     /'; fi

out="$(SECURITY_CHECK_PRIVATE_WORDS="$tmp/no-such-file" bash "$lint" "$skill" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^WARN: private word list not found' <<< "$out"; then
  ok "no word list: warning, still passes"
else
  bad "no word list: warning, still passes (exit $rc)"
fi

run_lint "$tmp/no-such-skill"
if [ "$rc" -eq 2 ]; then ok "missing skill folder: exit 2"; else bad "missing skill folder: exit 2 (got $rc)"; fi

# ---- 2. frontmatter ---------------------------------------------------------------------------

fresh; perl -0pi -e 's/\A---\n/# no frontmatter\n/' "$c/SKILL.md"
expect_fail "no frontmatter" frontmatter

fresh; perl -pi -e 's/^name: .*/name: other-skill/' "$c/SKILL.md"
expect_fail "name is not the folder name" frontmatter

fresh; perl -pi -e 's/^name: .*\n//' "$c/SKILL.md"
expect_fail "name missing" frontmatter

fresh; perl -pi -e 's/^description: .*/description:/' "$c/SKILL.md"
expect_fail "description empty" frontmatter

fresh; perl -pi -e 's/^description: .*/description: Checks servers for updates./' "$c/SKILL.md"
expect_fail "description does not say when to use it" frontmatter

fresh; perl -pi -e 's/^description: .*/description: >\n  Checks servers for updates.\n  Use when the user says "security check"./' "$c/SKILL.md"
expect_pass "folded multi-line description passes"

# ---- 3. referenced files ----------------------------------------------------------------------

fresh
# shellcheck disable=SC2016  # the backticks are text, not a command
printf '\nRun `scripts/missing.sh` first.\n' >> "$c/SKILL.md"
expect_fail "SKILL.md names a missing script" reference

fresh
# shellcheck disable=SC2016  # $SKILL is text, not a variable
printf '\nRead $SKILL/references/nope.md.\n' >> "$c/SKILL.md"
expect_fail "SKILL.md names a missing reference via \$SKILL/" reference

fresh; printf '\nSee ~/.claude/skills/security-check/tests/nope_test.sh.\n' >> "$c/references/sources.md"
expect_fail "a reference file names a missing test via the installed path" reference

fresh; printf '\nAlso ~/.claude/skills/other/scripts/x.sh and jira-tickets/scripts/jira.py.\n' >> "$c/SKILL.md"
expect_pass "other skills' paths are not checked"

fresh; printf '#!/usr/bin/env bash\n' > "$c/scripts/extra.sh"
expect_fail "a script that SKILL.md does not describe" reference

# ---- 4. run-brief placeholders ----------------------------------------------------------------

fresh; printf '\nServer: {{SERVER}}\n' >> "$c/references/run-brief.md"
expect_fail "run-brief placeholder start-task.sh does not fill" placeholder

# ---- 5. public-repo rules ---------------------------------------------------------------------

fresh; printf '\nThe host is %s.\n' "$ip" >> "$c/SKILL.md"
expect_fail "IP in SKILL.md (at the end of a sentence)" "ip address"

fresh; printf '\n# connects to %s\n' "$ip" >> "$c/scripts/inventory.sh"
expect_fail "IP in a script" "ip address"

fresh; printf '\n# version %s looks like an IP outside fixtures\n' "$ver" >> "$c/scripts/inventory.sh"
expect_fail "IP-like version outside tests/fixtures is still caught" "ip address"

fresh; printf '\n{"v": "%s", "w": "%s"}\n' "$ver" "$ip" >> "$c/tests/fixtures/inventory.json"
expect_pass "IP-like strings in tests/fixtures are skipped"

fresh; printf '\n# 192.0.2.10 198.51.100.7 203.0.113.5 127.0.0.1 0.0.0.0\n' >> "$c/scripts/inventory.sh"
expect_pass "documentation and loopback IPs pass"

fresh; printf '\n# 6.8.0.45.45 1.2.3.4-1ubuntu v1.2.3.4 300.1.2.3 1.2.3.4.5\n' >> "$c/scripts/inventory.sh"
expect_pass "version look-alikes pass"

fresh; mkdir -p "$c/scripts/__pycache__"; printf '%s\n' "$ip" > "$c/scripts/__pycache__/x.pyc"
expect_pass "python cache files are skipped"

fresh; printf '\n{"note": "%s"}\n' "$session_link" >> "$c/tests/fixtures/kev.json"
expect_fail "session link (fixtures are not skipped for it)" "session link"

fresh; printf '\n%s\n' "$trailer" >> "$c/references/run-brief.md"
expect_fail "session trailer" "session trailer"

fresh; printf '\nTicket: %s\n' "$jira_link" >> "$c/references/sources.md"
expect_fail "Jira link" "jira link"

fresh; printf '\n# cache in %s\n' "$home_path" >> "$c/scripts/advisories.py"
expect_fail "macOS home path" "home path"

fresh; printf '\n{"host": "%s"}\n' "$(tr '[:lower:]' '[:upper:]' <<< "$word")" >> "$c/tests/fixtures/inventory.json"
expect_fail "private word, other case, in a fixture" "private word"

finish skill_lint_test
