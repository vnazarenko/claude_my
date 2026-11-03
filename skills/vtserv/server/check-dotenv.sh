#!/usr/bin/env bash
# check-dotenv.sh <dir>… — exit 70 if a dotenv file Rails would load sets a *DATABASE_URL (KAN-387).
#
# ActiveRecord takes DATABASE_URL, PRIMARY_DATABASE_URL and CLICKHOUSE_DATABASE_URL over
# config/database.yml, so one would point a vt run at another server. It cannot be blanked from
# outside either: an empty one raises "Database URL cannot be empty". So the run stops here.
#
# The pattern follows dotenv 2.8's own LINE grammar (lib/dotenv/parser.rb): optional `export`, a key
# of [\w.]+, then `=` (spaces allowed around it) or `:` followed by whitespace. Values are never
# read or evaluated. `.env.example` is not loaded by dotenv and is skipped.
set -uo pipefail

pattern='^[[:space:]]*(export[[:space:]]+)?[A-Za-z0-9_.]*DATABASE_URL([[:space:]]*=|:[[:space:]])'
found=0
for dir in "$@"; do
  [[ -d "${dir}" ]] || continue
  for file in "${dir}"/.env*; do
    [[ -f "${file}" ]] || continue
    case "${file}" in *.example | *.sample | *.template) continue ;; esac
    if hits="$(grep -nE "${pattern}" "${file}")"; then
      found=1
      printf 'vt: refusing: %s sets a database URL, which would point this run at another server:\n' "${file#/work/}" >&2
      # Line number and variable name only — never the value (it holds credentials).
      printf '%s\n' "${hits}" |
        sed -E 's/^([0-9]+):[[:space:]]*(export[[:space:]]+)?([A-Za-z0-9_.]+).*/vt:   line \1: \3/' >&2
    fi
  done
done
if env | grep -qE '^[A-Za-z0-9_.]*DATABASE_URL='; then
  found=1
  printf 'vt: refusing: a *DATABASE_URL variable is set for this run\n' >&2
fi
((found)) && exit 70
exit 0
