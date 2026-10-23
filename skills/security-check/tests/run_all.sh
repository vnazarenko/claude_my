#!/usr/bin/env bash
# Run every test of the security-check skill: the shell linter on all scripts,
# the skill lint (skill_lint.sh), every tests/*_test.sh, and every tests/test_*.py (unittest).
#
# Usage:
#   run_all.sh
#
# Exit 0 only when everything passed. A missing shellcheck is a warning, not a failure.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
skill="$(dirname "$here")"
failed=()

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$skill"/scripts/*.sh "$here"/*.sh; then
    echo "ok   shellcheck"
  else
    failed+=("shellcheck")
  fi
else
  echo "WARN: shellcheck not found - skipped"
fi

echo "== skill_lint.sh"
bash "$here/skill_lint.sh" "$skill" || failed+=("skill_lint.sh")

for t in "$here"/*_test.sh; do
  [ -e "$t" ] || continue
  echo "== ${t##*/}"
  bash "$t" || failed+=("${t##*/}")
done

if compgen -G "$here/test_*.py" >/dev/null; then
  echo "== python unittest"
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$here" -p 'test_*.py' || failed+=("python unittest")
fi

echo
if [ ${#failed[@]} -eq 0 ]; then
  echo "run_all: all passed"
  exit 0
fi
echo "run_all: FAILED: ${failed[*]}"
exit 1
