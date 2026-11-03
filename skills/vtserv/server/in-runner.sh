#!/usr/bin/env bash
# in-runner.sh — runs INSIDE the runner container of a `vt` run (KAN-387). Mounted read-only at
# /vt/bin, so an edit here needs no image rebuild.
#
#   in-runner.sh <mode> <workdir> -- <command…>
#
# Prepares what the mode needs (gems, node_modules, Chromium, the test databases), then replaces
# itself with the command, so the command's exit code is the run's exit code.
set -Eeuo pipefail
# `docker exec` under rootless Docker starts with umask 0000. Bundler then leaves world-writable
# gem directories in the shared cache, and later refuses to replace them ("unsafe to remove").
umask 022

mode="$1"
workdir="$2"
shift 2
[[ "${1:-}" == "--" ]] && shift

say() { printf 'vt: %s\n' "$*" >&2; }

# Quiet on success; the whole log on failure.
quietly() {
  local log
  log="$(mktemp)"
  if ! "$@" >"${log}" 2>&1; then
    cat "${log}" >&2
    say "failed: $*"
    exit 70
  fi
  rm -f "${log}"
}

bundle_ready() {
  cd "$1"
  if ! bundle check >/dev/null 2>&1; then
    say "bundle install in ${1} (shared gem cache, first time per Gemfile.lock)"
    quietly flock /cache/bundle/.vt-lock bundle install --jobs 8 --retry 2
  fi
}

pnpm_ready() {
  cd "$1"
  say "pnpm install in ${1}"
  quietly pnpm install --frozen-lockfile --prefer-offline --store-dir /cache/pnpm-store
}

chromium_ready() {
  cd "$1"
  quietly pnpm exec playwright install chromium
}

test_db_ready() {
  cd "$1"
  say "creating the test databases (RAILS_ENV=test db:create db:test:prepare)"
  quietly env RAILS_ENV=test bin/rails db:create db:test:prepare
}

/vt/bin/check-dotenv.sh /work/src /work/parsalytics || exit 70

case "${mode}" in
  rspec-full)
    export RAILS_ENV=test
    bundle_ready /work/src
    ;;
  rspec)
    export RAILS_ENV=test
    bundle_ready /work/src
    test_db_ready /work/src
    ;;
  e2e)
    pnpm_ready /work/src/web
    chromium_ready /work/src/web
    ;;
  e2e-live)
    bundle_ready /work/parsalytics
    pnpm_ready /work/src/web
    chromium_ready /work/src/web
    ;;
  run)
    if [[ "${VT_PREPARE:-1}" == "1" ]]; then
      [[ -f /work/src/Gemfile ]] && bundle_ready /work/src
      [[ -f /work/src/web/pnpm-lock.yaml ]] && pnpm_ready /work/src/web
    fi
    ;;
  *)
    say "unknown mode: ${mode}"
    exit 64
    ;;
esac

cd "${workdir}"
exec "$@"
