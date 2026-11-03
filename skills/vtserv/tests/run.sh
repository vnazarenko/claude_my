#!/usr/bin/env bash
# Unit tests for the Mac side of `vt` (KAN-387). No network: ssh and rsync are fakes on PATH that
# log what they were asked to do. Run: ~/.claude/skills/vtserv/tests/run.sh
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VT="${SKILL_DIR}/scripts/vt"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vt-tests.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
check() { # <name> <condition command…>
  local name="$1"
  shift
  if "$@"; then ok "${name}"; else bad "${name}" "$*"; fi
}

# ── fakes ──────────────────────────────────────────────────────────────────────────────────────
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
cmd="${*: -1}"
for a in "$@"; do [[ "$a" == -fN ]] && { [[ -n "${FAKE_UNREACHABLE:-}" ]] && exit 255; echo "connect" >>"$FAKE_LOG"; exit 0; }; done
case "$cmd" in
  *"vt-remote lease"*) echo "lease: $cmd" >>"$FAKE_LOG"; echo LEASED; cat >/dev/null; echo "lease-end" >>"$FAKE_LOG" ;;
  *"vt-remote run"*) echo "run: $cmd" >>"$FAKE_LOG"; echo $$ >"$FAKE_LOG.runpid"; sleep "${FAKE_RUN_SLEEP:-0}"; exit "${FAKE_RUN_RC:-0}" ;;
  *) echo "ssh: $cmd" >>"$FAKE_LOG" ;;
esac
FAKE
cat >"${WORK}/bin/rsync" <<'FAKE'
#!/usr/bin/env bash
rp=""; for a in "$@"; do [[ "$a" == --rsync-path=* ]] && rp=" [$a]"; done
echo "rsync: ${*: -2}${rp}" >>"$FAKE_LOG"
FAKE
# Records what it was asked to keep awake, and which process that is.
cat >"${WORK}/bin/caffeinate" <<'FAKE'
#!/usr/bin/env bash
echo "caffeinate: $* [$(ps -o command= -p "${@: -1}")]" >>"$FAKE_LOG"
FAKE
chmod +x "${WORK}/bin/ssh" "${WORK}/bin/rsync" "${WORK}/bin/caffeinate"
export PATH="${WORK}/bin:${PATH}"
export FAKE_LOG="${WORK}/log"

# A parsalytics-like repo with a worktree, and an investviews-like repo.
mk_repo() {
  git init -q "$1"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}
mk_repo "${WORK}/code/parsalytics"
mkdir -p "${WORK}/code/parsalytics/bin" "${WORK}/code/parsalytics/config"
printf '#!/bin/sh\n' >"${WORK}/code/parsalytics/bin/rspec-full"
chmod +x "${WORK}/code/parsalytics/bin/rspec-full"
touch "${WORK}/code/parsalytics/config/database.yml"
git -C "${WORK}/code/parsalytics" worktree add -q "${WORK}/code/parsalytics/.claude/worktrees/KAN-1" -b kan-1 2>/dev/null
mkdir -p "${WORK}/code/parsalytics/.claude/worktrees/KAN-1/bin"
cp "${WORK}/code/parsalytics/bin/rspec-full" "${WORK}/code/parsalytics/.claude/worktrees/KAN-1/bin/"
mk_repo "${WORK}/code/investviews"
mkdir -p "${WORK}/code/investviews/web"
echo '{}' >"${WORK}/code/investviews/web/package.json"

vt_in() { # <dir> <args…> → runs vt there, returns its code
  local dir="$1"
  shift
  : >"${FAKE_LOG}"
  (cd "${dir}" && "${VT_SHELL:-bash}" "${VT}" "$@") >"${WORK}/out" 2>&1
}

# ── slug ───────────────────────────────────────────────────────────────────────────────────────
vt_in "${WORK}/code/parsalytics/.claude/worktrees/KAN-1" rspec-full
check "slug of a worktree is <repo>--<worktree>-<hash>" grep -Eq 'lease: .*vt-remote lease parsalytics--kan-1-[0-9a-f]{6}-' "${FAKE_LOG}"
vt_in "${WORK}/code/parsalytics" rspec-full
check "slug of the main checkout says main" grep -Eq 'lease: .*parsalytics--main-[0-9a-f]{6}' "${FAKE_LOG}"
mk_repo "${WORK}/other/parsalytics"
cp -R "${WORK}/code/parsalytics/bin" "${WORK}/other/parsalytics/"
vt_in "${WORK}/other/parsalytics" rspec-full
a="$(grep -o 'parsalytics--main-[0-9a-f]*' "${FAKE_LOG}" | head -1)"
vt_in "${WORK}/code/parsalytics" rspec-full
b="$(grep -o 'parsalytics--main-[0-9a-f]*' "${FAKE_LOG}" | head -1)"
check "two clones with the same names get different slugs" test "${a}" != "${b}"

# ── order: the lease comes before the sync ─────────────────────────────────────────────────────
vt_in "${WORK}/code/parsalytics" rspec-full
lease_line="$(grep -n '^lease:' "${FAKE_LOG}" | head -1 | cut -d: -f1)"
sync_line="$(grep -n "^rsync: .*vt/src/" "${FAKE_LOG}" | head -1 | cut -d: -f1)"
check "the lease is taken before the checkout is synced" test "${lease_line:-99}" -lt "${sync_line:-0}"
check "the checkout sync goes through sync-guard" grep -Eq "rsync: .*vt\/src\/.*\[--rsync-path=vt\/bin\/[0-9a-f]{12}\/vt-remote sync-guard " "${FAKE_LOG}"
check "the lease ends after the run" bash -c "tail -1 '${FAKE_LOG}' | grep -q lease-end"
check "the Mac is kept from idle sleep for as long as vt runs" \
  grep -Eq "^caffeinate: -i -s -w [0-9]+ \[.*${VT}" "${FAKE_LOG}"

# ── vt rspec: a list longer than the full-run guard's 80 files goes through bin/rspec-full ──────
long=()
for i in $(seq 1 81); do long+=("spec/f${i}_spec.rb"); done
vt_in "${WORK}/code/parsalytics" rspec "${long[@]}"
check "81 spec files run through bin/rspec-full" \
  grep -Eq '^run: .*--mode rspec-full .* -- bin/rspec-full spec/f1_spec.rb .*spec/f81_spec.rb' "${FAKE_LOG}"
vt_in "${WORK}/code/parsalytics" rspec "${long[@]}" --fail-fast
check "81 files with an rspec option stay plain rspec" \
  grep -Eq '^run: .*--mode rspec .* -- bundle exec rspec spec/f1_spec.rb' "${FAKE_LOG}"
sel=()
for i in $(seq 1 81); do sel+=("spec/one_spec.rb:${i}"); done
vt_in "${WORK}/code/parsalytics" rspec "${sel[@]}"
check "81 line selectors of one file stay plain rspec" \
  grep -Eq '^run: .*--mode rspec .* -- bundle exec rspec spec/one_spec.rb:1 ' "${FAKE_LOG}"
vt_in "${WORK}/code/parsalytics" rspec spec/a_spec.rb
check "a short list stays plain rspec" grep -Eq '^run: .*--mode rspec .* -- bundle exec rspec spec/a_spec.rb' "${FAKE_LOG}"

# ── exit codes ─────────────────────────────────────────────────────────────────────────────────
FAKE_RUN_RC=3 vt_in "${WORK}/code/parsalytics" rspec-full
check "the command's exit code is vt's exit code" test $? -eq 3
vt_in "${WORK}/code/investviews" rspec-full
check "rspec-full outside parsalytics: exit 64" test $? -eq 64
vt_in "${WORK}/code/parsalytics" run ls
check "vt run without -- : exit 64" test $? -eq 64
vt_in "${WORK}/code/parsalytics" run -e FOO -- true
check "vt run -e without KEY=VALUE: exit 64" test $? -eq 64
vt_in "${WORK}/code/parsalytics" bogus
check "unknown command: exit 64" test $? -eq 64
t0="$(date +%s)"
FAKE_UNREACHABLE=1 vt_in "${WORK}/code/parsalytics" rspec-full
code=$?
check "vtserv unreachable: exit 69" test "${code}" -eq 69
check "vtserv unreachable: says to ask the user" grep -q 'ask' "${WORK}/out"
check "vtserv unreachable: nothing synced or run" bash -c "! grep -qE '^(rsync|run|lease)' '${FAKE_LOG}'"
check "vtserv unreachable: fails fast" test $(($(date +%s) - t0)) -lt 10

# ── kill -9 of only the client ends the lease (the heartbeat writer watches the client pid) ────
sleep 30 &
bystander=$!
: >"${FAKE_LOG}"
(cd "${WORK}/code/parsalytics" && FAKE_RUN_SLEEP=30 exec "${VT}" run -- true) >"${WORK}/out" 2>&1 &
vpid=$!
for _ in $(seq 1 50); do grep -q '^run:' "${FAKE_LOG}" && break; sleep 0.1; done
kill -9 "${vpid}" 2>/dev/null
ended=0
for _ in $(seq 1 100); do grep -q '^lease-end' "${FAKE_LOG}" && { ended=1; break; }; sleep 0.1; done
check "kill -9 of only the vt process ends the lease within 10 s" test "${ended}" -eq 1
# Clean up only what this test started: the fake run (and its sleep), by its recorded pid.
fake_run="$(cat "${FAKE_LOG}.runpid" 2>/dev/null)"
[[ -n "${fake_run}" ]] && { pkill -P "${fake_run}" 2>/dev/null; kill "${fake_run}" 2>/dev/null; }
check "an unrelated sleeper survives the test's cleanup" kill -0 "${bystander}"
kill "${bystander}" 2>/dev/null

# ── forwarding ─────────────────────────────────────────────────────────────────────────────────
RSPEC_FULL_WORKERS=8 E2E_API_URL=http://elsewhere vt_in "${WORK}/code/parsalytics" rspec-full
check "RSPEC_FULL_* is forwarded" grep -q -- '-e RSPEC_FULL_WORKERS=8' "${FAKE_LOG}"
check "E2E_API_URL is not forwarded" bash -c "! grep -q E2E_API_URL '${FAKE_LOG}'"
vt_in "${WORK}/code/parsalytics" run -e FOO=1 -- echo hi
check "vt run -e KEY=VAL reaches the run" grep -q -- '-e FOO=1' "${FAKE_LOG}"
mkdir -p "${WORK}/code/parsalytics/spec/models"
vt_in "${WORK}/code/parsalytics/spec/models" run -- ls
check "vt run keeps the subdirectory" grep -q -- '--rel spec/models' "${FAKE_LOG}"
vt_in "${WORK}/code/investviews" e2e
check "vt e2e caps Playwright workers by default" grep -q -- '--workers=4' "${FAKE_LOG}"
check "vt e2e starts no databases" grep -q -- '--no-db' "${FAKE_LOG}"
vt_in "${WORK}/code/investviews" e2e --workers=2
check "an explicit --workers wins" bash -c "! grep -q -- '--workers=4' '${FAKE_LOG}'"

for key in DATABASE_HOST PRIMARY_DATABASE_URL CH_DATABASE_HOST REDIS_URL PUBLIC_API_REDIS_DB E2E_PG_HOST E2E_SKIP_SETUP SENTRY_DSN RAILS_ENV; do
  vt_in "${WORK}/code/parsalytics" run -e "${key}=x" -- true
  check "-e ${key} is refused (pinned): exit 64" test $? -eq 64
done
E2E_PG_HOST=10.0.0.1 E2E_SKIP_SETUP=1 E2E_BOOT_TIMEOUT=99 vt_in "${WORK}/code/investviews" e2e-live
check "e2e-live forwards E2E_BOOT_TIMEOUT" grep -q -- '-e E2E_BOOT_TIMEOUT=99' "${FAKE_LOG}"
check "e2e-live never forwards E2E_PG_HOST or E2E_SKIP_SETUP" bash -c "! grep -qE 'E2E_PG_HOST|E2E_SKIP_SETUP' '${FAKE_LOG}'"
RSPEC_FULL_WORKERS=8 vt_in "${WORK}/code/parsalytics" run -- true
check "RSPEC_FULL_WORKERS travels with rspec-full only" bash -c "! grep -q RSPEC_FULL_WORKERS '${FAKE_LOG}'"

# ── e2e-live backend ───────────────────────────────────────────────────────────────────────────
PARSALYTICS_DIR="${WORK}/code/parsalytics" vt_in "${WORK}/code/investviews" e2e-live
check "e2e-live syncs the backend to <slug>.parsalytics" grep -Eq 'rsync: .*/code/parsalytics/ vt@build-host.local:vt/src/investviews--main-[0-9a-f]{6}\.parsalytics/' "${FAKE_LOG}"
check "e2e-live passes --psrc" grep -q -- '--psrc' "${FAKE_LOG}"
check "e2e-live never passes the Mac's PARSALYTICS_DIR" bash -c "! grep -q 'PARSALYTICS_DIR' '${FAKE_LOG}'"
vt_in "${WORK}/code/investviews" e2e-live
check "e2e-live finds the sibling parsalytics by default" grep -Eq 'rsync: .*/code/parsalytics/ .*\.parsalytics/' "${FAKE_LOG}"

# ── check-dotenv.sh: a *DATABASE_URL in a loaded dotenv file is refused ────────────────────────
CD="${SKILL_DIR}/server/check-dotenv.sh"
dotenv_case() { # <name> <expected exit> <file name> <content>
  local d="${WORK}/dotenv-$RANDOM"
  mkdir -p "${d}"
  printf '%b' "$4" >"${d}/$3"
  env -u DATABASE_URL "${CD}" "${d}" >/dev/null 2>&1
  check "dotenv: $1" test $? -eq "$2"
}
dotenv_case "DATABASE_URL=… refused" 70 .env 'DATABASE_URL=postgres://elsewhere/x\n'
dotenv_case "PRIMARY_DATABASE_URL: … (colon form) refused" 70 .env 'PRIMARY_DATABASE_URL: postgres://elsewhere/x\n'
dotenv_case "export CLICKHOUSE_DATABASE_URL = … refused" 70 .env.e2e.local '  export CLICKHOUSE_DATABASE_URL = clickhouse://x\n'
dotenv_case "CRLF file refused" 70 .env.test 'A=1\r\nDATABASE_URL=postgres://x\r\n'
dotenv_case ".env.example is not loaded, not refused" 0 .env.example 'DATABASE_URL=postgres://x\n'
dotenv_case "a commented line is fine" 0 .env '# DATABASE_URL=postgres://x\n'
dotenv_case "DATABASE_HOST is fine" 0 .env 'DATABASE_HOST=localhost\nDATABASE_URLX=1\n'
DATABASE_URL=postgres://x "${CD}" "${WORK}" >/dev/null 2>&1
check "dotenv: DATABASE_URL in the environment refused" test $? -eq 70
for line in 'PRIMARY_DATABASE_URL:\tpostgresql://u:SECRET-MARKER@h/db' 'DATABASE_URL: postgresql://u:SECRET-MARKER@h/db' \
  'DATABASE_URL=postgresql://u:SECRET-MARKER@h/db' 'export CLICKHOUSE_DATABASE_URL=SECRET-MARKER\r'; do
  d="${WORK}/dotenv-secret-$RANDOM"
  mkdir -p "${d}"
  printf '%b\n' "${line}" >"${d}/.env"
  out="$(env -u DATABASE_URL "${CD}" "${d}" 2>&1)"
  check "dotenv refusal names the variable, never the value ($(printf '%s' "${line}" | cut -c1-24)…)" \
    bash -c '[[ "$0" == *DATABASE_URL* && "$0" != *SECRET-MARKER* ]]' "${out}"
done

# ── excludes (real rsync, local dry run) ───────────────────────────────────────────────────────
src="${WORK}/tree"
mkdir -p "${src}/config" "${src}/infra/ansible" "${src}/web/node_modules/x" "${src}/tmp" "${src}/.claude/worktrees/x" "${src}/spec/tmp"
touch "${src}/.env" "${src}/web/.env.local" "${src}/config/master.key" "${src}/infra/ansible/.vault" \
  "${src}/key.pem" "${src}/web/node_modules/x/a" "${src}/tmp/cache" "${src}/.claude/worktrees/x/f" \
  "${src}/spec/tmp/fixture" "${src}/app.rb"
echo "gitdir: x" >"${src}/.git"
PATH=/usr/bin:/bin /usr/bin/rsync -a --exclude-from="${SKILL_DIR}/scripts/rsync-excludes" "${src}/" "${WORK}/dst/"
for f in .env web/.env.local config/master.key app.rb spec/tmp/fixture; do
  check "synced: ${f}" test -e "${WORK}/dst/${f}"
done
for f in infra/ansible/.vault key.pem web/node_modules/x/a tmp/cache .claude/worktrees/x/f .git; do
  check "not synced: ${f}" test ! -e "${WORK}/dst/${f}"
done

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
((FAIL == 0))
