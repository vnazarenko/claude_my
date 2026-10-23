#!/usr/bin/env bash
# Run every test of the security-check skill: the shell linter on all scripts,
# the skill lint (skill_lint.sh), every tests/*_test.sh, and every tests/test_*.py (unittest).
#
# Usage:
#   run_all.sh
#
# Exit 0 only when everything passed. A missing tool (shellcheck, docker, the network in docker,
# the private word list) is a warning, not a failure: every "WARN" line is listed again at the
# end, so a skipped part is never hidden behind "all passed".
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
skill="$(dirname "$here")"
failed=()
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# run <name> <command ...>: run it, show its output, keep its WARN lines.
run() {
  local name="$1"
  shift
  "$@" 2>&1 | tee -a "$log"
  [ "${PIPESTATUS[0]}" -eq 0 ] || failed+=("$name")
}

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$skill"/scripts/*.sh "$here"/*.sh; then
    echo "ok   shellcheck"
  else
    failed+=("shellcheck")
  fi
else
  echo "WARN: shellcheck not found - skipped" | tee -a "$log"
fi

echo "== skill_lint.sh"
run skill_lint.sh bash "$here/skill_lint.sh" "$skill"

for t in "$here"/*_test.sh; do
  [ -e "$t" ] || continue
  echo "== ${t##*/}"
  run "${t##*/}" bash "$t"
done

if compgen -G "$here/test_*.py" >/dev/null; then
  echo "== python unittest"
  run "python unittest" env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$here" -p 'test_*.py'
fi

echo
warns="$(grep '^WARN' "$log")"
if [ -n "$warns" ]; then
  echo "run_all: these parts were skipped or need a look:"
  printf '%s\n' "$warns" | sed 's/^/  /'
fi
if [ ${#failed[@]} -eq 0 ]; then
  if [ -n "$warns" ]; then echo "run_all: all passed, with $(printf '%s\n' "$warns" | wc -l | tr -d ' ') warnings"; else echo "run_all: all passed"; fi
  exit 0
fi
echo "run_all: FAILED: ${failed[*]}"
exit 1
