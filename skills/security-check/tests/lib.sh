#!/usr/bin/env bash
# Shared helpers of the security-check tests. Each *_test.sh sources it:
#   . "$here/lib.sh"
#
#   ok <label>                               a check passed
#   bad <label>                              a check failed (counted)
#   die <message> [exit code]                the test cannot run (a missing tool); default 1
#   expect_eq <label> <expected> <actual>
#   expect_has <label> <needle> <text>
#   expect_not_has <label> <needle> <text>
#   finish <test name>                       the result line; exit 0 when nothing failed, else 1

fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }

expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1"; printf '     expected: %s\n     actual:   %s\n' "$2" "$3"
  fi
}

expect_has() {
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1"; printf '     missing: %s\n     in: %s\n' "$2" "$3" ;; esac
}

expect_not_has() {
  case "$3" in *"$2"*) bad "$1"; printf '     found: %s\n' "$2" ;; *) ok "$1" ;; esac
}

finish() {
  echo
  if [ "$fails" -eq 0 ]; then
    echo "$1: all passed"
    exit 0
  fi
  echo "$1: $fails failed"
  exit 1
}
