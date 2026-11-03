#!/usr/bin/env bash
# Server-side tests for vt-remote (KAN-387): the run lifecycle, cleanup and races, with a FAKE
# docker. Linux only (flock, /proc). Needs no Docker and no root.
#
# From the Mac:  ~/.claude/skills/vtserv/tests/server.sh --remote [host]   (default build-host.local)
# On Linux:      SERVER_DIR=<copy of server/> bash server.sh
set -uo pipefail

if [[ "${1:-}" == --remote ]]; then
  host="${2:-build-host.local}"
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  dir="$(ssh "${host}" 'mktemp -d /tmp/vt-servertest.XXXXXX')" || exit 69
  rsync -a "${here}/server/" "${host}:${dir}/server/" && rsync -a "${here}/tests/server.sh" "${host}:${dir}/" || exit 69
  ssh "${host}" "SERVER_DIR=${dir}/server bash ${dir}/server.sh; rc=\$?; rm -rf ${dir}; exit \$rc"
  exit $?
fi

SERVER_DIR="${SERVER_DIR:?}"
WORK="$(mktemp -d /tmp/vt-st.XXXXXX)"
export VT_HOME="${WORK}/vt" FAKE="${WORK}/fake"
mkdir -p "${VT_HOME}" "${FAKE}/bin"
touch "${FAKE}/containers" "${FAKE}/log"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
check() { local n="$1"; shift; if "$@"; then ok "${n}"; else bad "${n}" "$*"; fi; }
cleanup_all() { pkill -f "${WORK}" 2>/dev/null; rm -rf "${WORK}"; }
trap cleanup_all EXIT

# Fake docker: containers live in $FAKE/containers as "<id> <vt.run>". FAKE_FAIL=ps makes `ps` fail.
cat >"${FAKE}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE/log"
label_of() { local a; for a in "$@"; do [[ "$a" == label=vt.run=* ]] && echo "${a#label=vt.run=}"; done; }
case "$1" in
  ps)
    [[ -e "$FAKE/fail-ps" ]] && exit 1
    want="$(label_of "$@")"
    if [[ -n "$want" ]]; then awk -v w="$want" '$2 == w {print $1}' "$FAKE/containers"; fi
    ;;
  rm)
    [[ -e "$FAKE/fail-rm" ]] && exit 1
    for a in "$@"; do grep -v "^$a " "$FAKE/containers" >"$FAKE/c.tmp"; mv "$FAKE/c.tmp" "$FAKE/containers"; done
    ;;
  compose)
    shift
    while [[ "$1" == -f || "$1" == --profile ]]; do shift 2; done
    case "$1" in
      up) echo "c-$RANDOM $VT_RUN" >>"$FAKE/containers"; echo "c-$RANDOM $VT_RUN" >>"$FAKE/containers" ;;
      down) [[ -e "$FAKE/slow-down" ]] && sleep 60; [[ -e "$FAKE/fail-rm" ]] || awk -v r="$VT_RUN" '$2 != r' "$FAKE/containers" >"$FAKE/c.tmp" && mv "$FAKE/c.tmp" "$FAKE/containers" ;;
      exec) while [[ "$1" != -- ]]; do shift; done; shift; exec "$@" ;;
    esac
    ;;
  info) [[ -e "$FAKE/docker-rootless" ]] && echo "[name=rootless name=seccomp]"; exit 0 ;;
  version) echo 29.9.2 ;;
  image | volume | network | pull | build) exit 0 ;;
esac
EOF
chmod +x "${FAKE}/bin/docker"
# systemctl passes through, except that $FAKE/fail-systemctl makes every call fail (a lost bus).
cat >"${FAKE}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ -e "$FAKE/fail-systemctl" ]] && { echo "Failed to connect to bus" >&2; exit 1; }
exec /usr/bin/systemctl "$@"
EOF
chmod +x "${FAKE}/bin/systemctl"
# Fake df (KAN-437): $FAKE/df-gb holds the free GB to report (default 500); "fail" = no number.
cat >"${FAKE}/bin/df" <<'EOF'
#!/usr/bin/env bash
gb="$(cat "$FAKE/df-gb" 2>/dev/null || echo 500)"
[[ "$gb" == fail ]] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1 $((gb * 1048576)) 1% /"
EOF
chmod +x "${FAKE}/bin/df"
export PATH="${FAKE}/bin:${PATH}"
R="${SERVER_DIR}/vt-remote"
SLUG=t--a-000000

# A lease fed from a FIFO we control.
start_lease() { # <id> → LEASE_PID, HB (fd 7 writes heartbeats)
  mkfifo "${WORK}/hb-$1"
  bash "${R}" lease "$1" "${SLUG}" <"${WORK}/hb-$1" >"${WORK}/out-$1" 2>"${WORK}/err-$1" &
  LEASE_PID=$!
  exec 7>"${WORK}/hb-$1"
  for _ in $(seq 1 50); do grep -qx LEASED "${WORK}/out-$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
end_lease() { exec 7>&-; for _ in $(seq 1 100); do kill -0 "${LEASE_PID}" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
lock_free() { flock -n "${VT_HOME}/locks/${SLUG}" true; }
mkdir -p "${VT_HOME}/src/${SLUG}"

# 1. A normal run: exit code kept, containers removed, lock freed.
start_lease r1
setsid -w bash "${R}" run --id r1 --slug "${SLUG}" --mode run --rel . -- bash -c 'exit 3' >/dev/null 2>&1
check "run returns the command's exit code" test $? -eq 3
check "run removed its containers" bash -c "! grep -q ' r1$' '${FAKE}/containers'"
end_lease
check "lease ended after EOF" test $? -eq 0
check "checkout lock free after the lease" lock_free
check "run state removed" test ! -e "${VT_HOME}/runs/r1"

# 2. Registration after close is refused; nothing starts.
start_lease r2
bash "${R}" stop r2 >/dev/null 2>&1
setsid -w bash "${R}" run --id r2 --slug "${SLUG}" --mode run --rel . -- true >/dev/null 2>&1
check "a run of a stopped lease refuses (exit 70)" test $? -eq 70
check "no containers after a refused run" bash -c "! grep -q ' r2$' '${FAKE}/containers'"
end_lease

# 3. Barrier: the run is stopped while paused after registering; it must not start containers.
start_lease r3
VT_TEST_PAUSE=after-register:3 setsid bash "${R}" run --id r3 --slug "${SLUG}" --mode run --rel . -- sleep 30 >/dev/null 2>&1 6>&- 7>&- &
rp=$!
sleep 1
end_lease   # EOF: the lease stops the run (TERM to its process group) and cleans up
wait "${rp}"
rc=$?
check "a run stopped during its pause ends (TERM, not the command)" test "${rc}" -ne 0
check "no compose up for the stopped run" bash -c "! grep -q 'runs/r3/compose.yml.* up ' '${FAKE}/log'"
check "no containers for the stopped run" bash -c "! grep -q ' r3$' '${FAKE}/containers'"
check "lock free after the barrier stop" lock_free

# 3b. Barrier before registering: the stop finds no process group to kill, so the run survives the
#     stop — and must then be refused by `register`, before it starts any container.
start_lease r3b
VT_TEST_PAUSE=before-register:3 setsid bash "${R}" run --id r3b --slug "${SLUG}" --mode run --rel . -- sleep 30 >/dev/null 2>&1 6>&- 7>&- &
rp=$!
sleep 1
touch "${FAKE}/fail-ps"   # keeps the lease in its cleanup: run dir present, state closed
exec 7>&-
wait "${rp}"
check "a run closed before it registered is refused (exit 70)" test $? -eq 70
check "no compose up for the run closed before registering" bash -c "! grep -q 'runs/r3b/compose.yml.* up ' '${FAKE}/log'"
rm -f "${FAKE}/fail-ps"
end_lease

# 4. Docker cannot confirm removal: the checkout stays locked until it can. The run's outputs
#    (KAN-437) are removed only after docker confirms, never while a container may still write.
start_lease r4
mkdir -p "${VT_HOME}/src/${SLUG}/log"
touch "${VT_HOME}/src/${SLUG}/log/test.log"
echo "c-stuck r4" >>"${FAKE}/containers"
touch "${FAKE}/fail-ps"
exec 7>&-   # EOF → stop; docker ps fails → pending
sleep 25
check "checkout stays locked while docker fails" bash -c "! flock -n '${VT_HOME}/locks/${SLUG}' true"
check "status shows cleanup pending" grep -q 'CLEANUP PENDING' "${VT_HOME}/locks/${SLUG}.owner"
check "the run's test log stays while docker cannot confirm" test -e "${VT_HOME}/src/${SLUG}/log/test.log"
rm -f "${FAKE}/fail-ps"
for _ in $(seq 1 200); do kill -0 "${LEASE_PID}" 2>/dev/null || break; sleep 0.1; done
check "lock freed once docker confirms removal" lock_free
check "the stuck container was removed" bash -c "! grep -q ' r4$' '${FAKE}/containers'"
check "and only then the run's test log was removed" test ! -e "${VT_HOME}/src/${SLUG}/log/test.log"

# 5. A stale sync registration never hits an unrelated process with that pid.
start_lease r5
sleep 300 6>&- 7>&- &
victim=$!
echo "${victim} 1" >>"${VT_HOME}/runs/r5/sync.pid"   # pid alive, start time wrong
end_lease
check "an unrelated process with a registered pid survives" kill -0 "${victim}"
kill "${victim}" 2>/dev/null

# 6. A lease waiting for the lock leaves no state when its client goes away.
start_lease r6
mkfifo "${WORK}/hb-r7"
bash "${R}" lease r7 "${SLUG}" <"${WORK}/hb-r7" >"${WORK}/out-r7" 2>"${WORK}/err-r7" 7>&- &
p7=$!
exec 6>"${WORK}/hb-r7"
sleep 1
check "second lease waits and says so" grep -q 'waiting' "${WORK}/err-r7"
exec 6>&-
for _ in $(seq 1 50); do kill -0 "${p7}" 2>/dev/null || break; sleep 0.1; done
check "a waiting lease exits on EOF" bash -c "! kill -0 ${p7} 2>/dev/null"
check "a waiting lease leaves no run state" test ! -e "${VT_HOME}/runs/r7"
end_lease

# 7. The run's own cleanup trap still removes containers when its watcher already exited (a kill
#    that fails must not abort the trap). Checked BEFORE the lease ends, so the lease's own
#    cleanup cannot hide a broken trap.
start_lease r8
VT_TEST_KILL_WATCHER=1 setsid -w bash "${R}" run --id r8 --slug "${SLUG}" --mode run --rel . -- bash -c 'exit 4' >/dev/null 2>&1 6>&- 7>&-
check "with an already-exited watcher the exit code is kept" test $? -eq 4
check "with an already-exited watcher the run removed its containers" bash -c "! grep -q ' r8$' '${FAKE}/containers'"
end_lease

# 8. A stale process-group registration never hits a group that reused the number — while its
#    new leader lives, and after that leader exited leaving a child.
start_lease r9
setsid sleep 300 6>&- 7>&- &
grp=$!
sleep 0.2
echo "${grp} 1" >>"${VT_HOME}/runs/r9/run.pgid"   # group alive, leader start time wrong
setsid bash -c 'sleep 300 & echo $! >"$0"; exit 0' "${WORK}/orphan-child" 6>&- 7>&- &
glead=$!
sleep 0.5
ochild="$(cat "${WORK}/orphan-child")"
echo "${glead} $(sed 's/.*) //' /proc/self/stat | awk '{print $20}')" >>"${VT_HOME}/runs/r9/run.pgid"   # leader gone, its child left
end_lease
check "an unrelated group with a live leader survives" kill -0 "${grp}"
check "an unrelated group whose leader exited (child left) survives" kill -0 "${ochild}"
kill "${grp}" "${ochild}" 2>/dev/null

# 8b. A run's own background processes do not outlive it (host mode, a script that daemonizes).
start_lease rc
setsid -w bash "${R}" run --id rc --slug "${SLUG}" --mode run --rel . --host -- \
  bash -c 'sleep 300 & echo $! >"$0"; exit 0' "${WORK}/daemon-pid" >/dev/null 2>&1 6>&- 7>&-
daemon="$(cat "${WORK}/daemon-pid" 2>/dev/null)"
sleep 0.5
check "a host-mode background process is stopped when its run ends" bash -c "! kill -0 ${daemon:-0} 2>/dev/null"
end_lease

# 8c. kill -9 of ONLY the run leader in host mode: its worker lives in the run's scope, so the stop
#     still finds it, and the checkout is not free before the worker is gone.
start_lease rk
setsid bash "${R}" run --id rk --slug "${SLUG}" --mode run --rel . --host -- \
  bash -c 'echo $$ >"$0"; exec sleep 300' "${WORK}/worker-rk" >/dev/null 2>&1 6>&- 7>&- &
leader=$!
for _ in $(seq 1 50); do [[ -s "${WORK}/worker-rk" ]] && break; sleep 0.1; done
hworker="$(cat "${WORK}/worker-rk" 2>/dev/null)"
check "the host worker runs in the run's scope" bash -c "grep -q 'vt-run-rk.scope' /proc/${hworker:-0}/cgroup"
kill -9 "${leader}"
sleep 0.5
check "the host worker outlived its killed leader" kill -0 "${hworker:-0}"
end_lease
check "after the lease's stop the host worker is gone" bash -c "! kill -0 ${hworker:-0} 2>/dev/null"
check "the checkout was freed only after that" lock_free

# 9. A killed lease does not hand the checkout over while its run still works: the next lease
#    finishes that run first, then says LEASED.
start_lease ra
check "lease A is up" grep -qx LEASED "${WORK}/out-ra"
setsid bash "${R}" run --id ra --slug "${SLUG}" --mode run --rel . -- \
  bash -c 'echo $$ >"$0"; exec sleep 60' "${WORK}/worker-ra" >/dev/null 2>&1 6>&- 7>&- &
for _ in $(seq 1 50); do [[ -s "${WORK}/worker-ra" ]] && break; sleep 0.1; done
worker="$(cat "${WORK}/worker-ra" 2>/dev/null)"
check "run A's worker published its pid" test -n "${worker}"
check "the worker belongs to run A's process group" bash -c \
  "[[ \"\$(ps -o pgid= -p ${worker:-0} | tr -d ' ')\" == \"\$(cut -d' ' -f1 '${VT_HOME}/runs/ra/run.pgid')\" ]]"
kill -9 "${LEASE_PID}"
exec 7>&-
sleep 0.5
check "the killed lease's worker is still running" kill -0 "${worker:-0}"
start_lease rb
check "lease B is up" grep -qx LEASED "${WORK}/out-rb"
check "lease B stopped run A's worker before LEASED" bash -c "! kill -0 ${worker:-0} 2>/dev/null"
check "lease B said it finished the earlier run" grep -q 'finishing an earlier run' "${WORK}/err-rb"
check "run A's containers are gone" bash -c "! grep -q ' ra$' '${FAKE}/containers'"
end_lease

# 10. Recovery while docker cannot confirm: heartbeats keep the new lease waiting; silence past the
#     deadline or EOF make it leave without LEASED. Each phase is confirmed before the next.
mk_dead_run() { # <id>: a run record of this checkout with a dead lease and a container
  mkdir -p "${VT_HOME}/runs/$1"
  echo open >"${VT_HOME}/runs/$1/state"
  echo 99999999 >"${VT_HOME}/runs/$1/lease.pid"
  echo "${SLUG}" >"${VT_HOME}/runs/$1/slug"
  echo "c-$1 $1" >>"${FAKE}/containers"
}
lease_bg() { # <id> → a lease fed by fd 6; LPID
  mkfifo "${WORK}/hb-$1"
  VT_HEARTBEAT_TIMEOUT=8 bash "${R}" lease "$1" "${SLUG}" <"${WORK}/hb-$1" >"${WORK}/out-$1" 2>"${WORK}/err-$1" 7>&- &
  LPID=$!
  exec 6>"${WORK}/hb-$1"
}
wait_for() { local i; for i in $(seq 1 "$1"); do shift_cmd="${*:2}"; eval "${shift_cmd}" && return 0; sleep 0.5; done; return 1; }
touch "${FAKE}/fail-ps"
mk_dead_run rd1
lease_bg re1
wait_for 20 "grep -q 'finishing an earlier run' '${WORK}/err-re1'"
check "10: the lease entered recovery" grep -q 'finishing an earlier run' "${WORK}/err-re1"
for _ in $(seq 1 6); do echo hb >&6; sleep 2; done
check "10: with heartbeats it keeps waiting, no LEASED" bash -c "kill -0 ${LPID} && ! grep -qx LEASED '${WORK}/out-re1'"
t0="$(date +%s)"
wait_for 40 "! kill -0 ${LPID} 2>/dev/null"
gone_after=$(($(date +%s) - t0))
check "10: silent past the deadline it left (after ${gone_after}s, deadline 8s + one poll)" test "${gone_after}" -le 14
check "10: and never said LEASED" bash -c "! grep -qx LEASED '${WORK}/out-re1'"
exec 6>&-
# A KILLed lease's in-flight `sleep` (2 s at most) still holds the lock fd; wait for it to go.
wait_for 10 lock_free
lease_bg re2
wait_for 20 "grep -q 'finishing an earlier run' '${WORK}/err-re2'"
check "10: the second lease entered recovery (not the lock wait)" bash -c "grep -q 'finishing an earlier run' '${WORK}/err-re2' && ! grep -q 'waiting: another' '${WORK}/err-re2'"
exec 6>&-
wait_for 10 "! kill -0 ${LPID} 2>/dev/null"
check "10: on EOF it left without LEASED" bash -c "! kill -0 ${LPID} 2>/dev/null && ! grep -qx LEASED '${WORK}/out-re2'"
rm -f "${FAKE}/fail-ps"
start_lease rf
check "10: once docker answers, the next lease finishes the dead run and starts" grep -qx LEASED "${WORK}/out-rf"
check "10: the dead run's container is gone" bash -c "! grep -q ' rd1$' '${FAKE}/containers'"
end_lease

# 10b. Recovery blocked in a stalled `compose down` (a saved compose config + slow docker): silence
#      and EOF must still end the recovering lease within the deadline.
mk_dead_run rd2
printf 'services: {}\n' >"${VT_HOME}/runs/rd2/compose.yml"
printf 'VT_PROJECT=vt-rd2\nVT_RUN=rd2\n' >"${VT_HOME}/runs/rd2/compose.env"
touch "${FAKE}/slow-down" "${FAKE}/fail-ps"
lease_bg re3
wait_for 20 "grep -q 'finishing an earlier run' '${WORK}/err-re3'"
check "10b: recovering lease is in recovery" grep -q 'finishing an earlier run' "${WORK}/err-re3"
t0="$(date +%s)"
wait_for 40 "! kill -0 ${LPID} 2>/dev/null"
gone_after=$(($(date +%s) - t0))
check "10b: silent while compose down stalls: left within the deadline (${gone_after}s, deadline 8s + 2s poll)" test "${gone_after}" -le 12
check "10b: its own record removed" test ! -e "${VT_HOME}/runs/re3"
check "10b: the old run's record kept for the next lease" test -d "${VT_HOME}/runs/rd2"
exec 6>&-
lease_bg re4
wait_for 20 "grep -q 'finishing an earlier run' '${WORK}/err-re4'"
exec 6>&-
t0="$(date +%s)"
wait_for 20 "! kill -0 ${LPID} 2>/dev/null"
check "10b: EOF while compose down stalls: left within a poll ($(($(date +%s) - t0))s)" test $(($(date +%s) - t0)) -le 4
rm -f "${FAKE}/slow-down" "${FAKE}/fail-ps"
start_lease rg
check "10b: with docker back the next lease finishes rd2 and starts" grep -qx LEASED "${WORK}/out-rg"
end_lease

# 11. systemd cannot be asked (lost bus) while a host worker survives and docker shows no
#     container: the checkout stays locked until systemd confirms the scope is gone.
start_lease rh
# The worker leaves the run's process group (its own session, like a daemonizing script), so only
# the run's scope can reach it.
setsid bash "${R}" run --id rh --slug "${SLUG}" --mode run --rel . --host -- \
  bash -c 'setsid bash -c "echo \$\$ >\"\$0\"; exec sleep 300" "$0" & sleep 300' "${WORK}/worker-rh" >/dev/null 2>&1 6>&- 7>&- &
for _ in $(seq 1 50); do [[ -s "${WORK}/worker-rh" ]] && break; sleep 0.1; done
hw="$(cat "${WORK}/worker-rh" 2>/dev/null)"
touch "${FAKE}/fail-systemctl"
exec 7>&-   # the lease stops the run; the group TERM cannot reach the worker, only the scope can
# The first stop gives the group up to 10 s and the unreachable scope up to 10 s before it reports
# pending.
wait_for 60 "grep -q 'CLEANUP PENDING' '${VT_HOME}/locks/${SLUG}.owner'"
check "11: worker alive and systemd unreachable → checkout still locked" bash -c "kill -0 ${hw:-0} && ! flock -n '${VT_HOME}/locks/${SLUG}' true"
check "11: status says cleanup pending" grep -q 'CLEANUP PENDING' "${VT_HOME}/locks/${SLUG}.owner"
rm -f "${FAKE}/fail-systemctl"
for _ in $(seq 1 100); do kill -0 "${LEASE_PID}" 2>/dev/null || break; sleep 0.3; done
check "11: once systemd answers, the worker is stopped" bash -c "! kill -0 ${hw:-0} 2>/dev/null"
check "11: and only then the checkout is free" lock_free

# 12. KAN-437: the disk floor (10 GB) and doctor's disk line.
# 12a. Below the floor at the start: the lease refuses before it creates anything.
echo 5 >"${FAKE}/df-gb"
bash "${R}" lease rfl "${SLUG}" </dev/null >"${WORK}/out-rfl" 2>"${WORK}/err-rfl"
check "12a: a lease below the floor exits 70" test $? -eq 70
check "12a: and says why" grep -q 'only 5 GB free on its disk, below the 10 GB floor: this run was NOT started' "${WORK}/err-rfl"
check "12a: and to not fall back to the Mac" grep -q 'Do NOT fall back to a heavy run on this Mac' "${WORK}/err-rfl"
check "12a: no LEASED" bash -c "! grep -qx LEASED '${WORK}/out-rfl'"
check "12a: no run record" test ! -e "${VT_HOME}/runs/rfl"
check "12a: the checkout lock is free" lock_free

# 12a2. Below the floor while another lease holds the checkout: refused at once, not queued.
echo 500 >"${FAKE}/df-gb"
start_lease rfh
echo 5 >"${FAKE}/df-gb"
t0="$(date +%s)"
timeout 20 bash "${R}" lease rfq "${SLUG}" </dev/null >"${WORK}/out-rfq" 2>"${WORK}/err-rfq"
rc=$?
check "12a2: refused (exit 70) while the checkout is held" test "${rc}" -eq 70
check "12a2: at once ($(($(date +%s) - t0))s), not queued behind the other run" bash -c "test $(($(date +%s) - t0)) -le 3 && ! grep -q 'waiting: another' '${WORK}/err-rfq'"
check "12a2: no run record" test ! -e "${VT_HOME}/runs/rfq"
echo 500 >"${FAKE}/df-gb"
end_lease

# 12b. Unknown free space never refuses.
echo fail >"${FAKE}/df-gb"
start_lease rfu
check "12b: with no df number the lease starts" grep -qx LEASED "${WORK}/out-rfu"
end_lease

# 12c. A lease queued behind another while the disk fills: once it has the checkout, it refuses
#      before the sync (no LEASED, no record, lock free).
echo 500 >"${FAKE}/df-gb"
start_lease rqa
lease_bg rqb
wait_for 20 "grep -q 'waiting: another' '${WORK}/err-rqb'"
check "12c: the second lease is queued" grep -q 'waiting: another' "${WORK}/err-rqb"
echo 5 >"${FAKE}/df-gb"
echo hb >&6
end_lease
wait_for 20 "! kill -0 ${LPID} 2>/dev/null"
check "12c: the queued lease ended" bash -c "! kill -0 ${LPID} 2>/dev/null"
check "12c: without LEASED" bash -c "! grep -qx LEASED '${WORK}/out-rqb'"
check "12c: saying why" grep -q 'below the 10 GB floor' "${WORK}/err-rqb"
check "12c: no run record left" test ! -e "${VT_HOME}/runs/rqb"
check "12c: the checkout lock is free" lock_free
exec 6>&-

# 12d. A run whose disk fell below the floor while it held the lease refuses after taking its
#      slot, before any container, and frees the slot.
echo 500 >"${FAKE}/df-gb"
start_lease rfr
echo 5 >"${FAKE}/df-gb"
setsid -w bash "${R}" run --id rfr --slug "${SLUG}" --mode run --rel . -- true >/dev/null 2>"${WORK}/err-rfr-run"
check "12d: the run exits 70" test $? -eq 70
check "12d: and says why" grep -q 'below the 10 GB floor' "${WORK}/err-rfr-run"
check "12d: no compose up for it" bash -c "! grep -q 'runs/rfr/compose.yml.* up ' '${FAKE}/log'"
check "12d: its slot is free again" bash -c "! grep -qs rfr '${VT_HOME}'/slots/*.owner"
end_lease

# 12e. doctor's disk line. The fake docker looks rootless here, so only the disk decides.
touch "${FAKE}/docker-rootless"
doc() { echo "$1" >"${FAKE}/df-gb"; bash "${R}" doctor >"${WORK}/doctor-$1" 2>&1; echo $? >"${WORK}/doctor-$1.rc"; }
doc 50
doc 12
doc 5
doc fail
check "12e: 50 GB: plain line" grep -qx 'disk      50 GB free' "${WORK}/doctor-50"
check "12e: 50 GB: doctor passes" test "$(cat "${WORK}/doctor-50.rc")" -eq 0
check "12e: 12 GB: LOW warning" grep -q '^disk      12 GB free — LOW (warning below 15 GB' "${WORK}/doctor-12"
check "12e: 12 GB: a warning does not fail doctor" test "$(cat "${WORK}/doctor-12.rc")" -eq 0
check "12e: 5 GB: below the floor" grep -q '^disk      5 GB free — BELOW THE 10 GB FLOOR' "${WORK}/doctor-5"
check "12e: 5 GB: doctor fails (exit 70)" test "$(cat "${WORK}/doctor-5.rc")" -eq 70
check "12e: no number: unknown, not a failure" bash -c "grep -q '^disk      unknown' '${WORK}/doctor-fail' && test \$(cat '${WORK}/doctor-fail.rc') -eq 0"
rm -f "${FAKE}/docker-rootless" "${FAKE}/df-gb"

# 13. KAN-437: when a lease ends (its containers gone), the run's outputs in the copy go — Rails
#     test logs and coverage — and the e2e results, the caches and other files stay.
C="${VT_HOME}/src/${SLUG}"
P="${VT_HOME}/src/${SLUG}.parsalytics"
mkdir -p "${C}/log" "${C}/coverage" "${C}/web/test-results" "${C}/web/playwright-report" \
  "${C}/web/node_modules/m" "${C}/web/.next/cache" "${C}/tmp/cache" "${P}/log" "${P}/tmp"
touch "${C}/log/test.log" "${C}/log/test.log.0" "${C}/log/newrelic_agent.log" "${C}/coverage/x" \
  "${C}/web/test-results/a" "${C}/web/playwright-report/b" "${C}/web/node_modules/m/i" \
  "${C}/web/.next/cache/c" "${C}/tmp/cache/t" "${C}/Gemfile" "${P}/log/test.log" \
  "${P}/log/e2e-live-server.log" "${P}/tmp/t"
start_lease r13
check "13: while the lease holds, the outputs are still there" bash -c "test -e '${C}/log/test.log' && test -e '${C}/web/test-results/a'"
end_lease
check "13: the lease ended" test $? -eq 0
check "13: Rails test logs removed (test.log, test.log.0)" bash -c "test ! -e '${C}/log/test.log' && test ! -e '${C}/log/test.log.0'"
check "13: the backend copy's test log removed" test ! -e "${P}/log/test.log"
check "13: coverage removed" test ! -e "${C}/coverage"
check "13: the e2e results stay (a failed or cancelled copy-back must not lose them)" bash -c "test -e '${C}/web/test-results/a' && test -e '${C}/web/playwright-report/b'"
check "13: other logs stay" bash -c "test -e '${C}/log/newrelic_agent.log' && test -e '${P}/log/e2e-live-server.log'"
check "13: caches and sources stay" bash -c "test -e '${C}/web/node_modules/m/i' && test -e '${C}/web/.next/cache/c' && test -e '${C}/tmp/cache/t' && test -e '${C}/Gemfile' && test -e '${P}/tmp/t'"
check "13: the checkout lock is free" lock_free
rm -rf "${P}"

# 13b. Never through a symlink: a log/ that points at another checkout, and a copy root that is a
#      symlink, are skipped; the files they point at survive.
O="${WORK}/outside"
mkdir -p "${O}/log" "${O}/root/log"
touch "${O}/log/test.log" "${O}/root/log/test.log"
rm -rf "${C}/log"
ln -s "${O}/log" "${C}/log"
ln -s "${O}/root" "${P}"
start_lease r13b
end_lease
check "13b: a symlinked log/ is not followed" test -e "${O}/log/test.log"
check "13b: a symlinked backend copy root is not followed" test -e "${O}/root/log/test.log"
check "13b: the symlinks themselves are left alone" bash -c "test -L '${C}/log' && test -L '${P}'"
check "13b: the checkout lock is free" lock_free
rm -f "${C}/log" "${P}"
mkdir -p "${C}/log"

# 14. KAN-437: `vt clean` (task-cleanup runs it on every task worktree) never removes a copy that a
#     run record still names, even when the checkout lock is free (a killed lease).
mkdir -p "${VT_HOME}/src/${SLUG}" "${VT_HOME}/src/${SLUG}.parsalytics"
touch "${VT_HOME}/src/${SLUG}/keep" "${VT_HOME}/src/${SLUG}.parsalytics/keep"
mkdir -p "${VT_HOME}/runs/rcl"
echo open >"${VT_HOME}/runs/rcl/state"
echo 99999999 >"${VT_HOME}/runs/rcl/lease.pid"
echo "${SLUG}" >"${VT_HOME}/runs/rcl/slug"
bash "${R}" clean "${SLUG}" >/dev/null 2>"${WORK}/err-clean1"
check "14: clean refuses (exit 75) while a run record names the checkout" test $? -eq 75
check "14: and says why" grep -q 'still being cleaned up' "${WORK}/err-clean1"
check "14: the copy and its backend copy stay" bash -c "test -e '${VT_HOME}/src/${SLUG}/keep' && test -e '${VT_HOME}/src/${SLUG}.parsalytics/keep'"
check "14: the lock is free again" lock_free
rm -rf "${VT_HOME}/runs/rcl"
bash "${R}" clean "${SLUG}" >/dev/null 2>&1
check "14: once the record is gone, clean succeeds" test $? -eq 0
check "14: and removes both copies" bash -c "test ! -e '${VT_HOME}/src/${SLUG}' && test ! -e '${VT_HOME}/src/${SLUG}.parsalytics'"
mkdir -p "${VT_HOME}/src/${SLUG}"

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
((FAIL == 0))
