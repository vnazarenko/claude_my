---
name: vtserv
description: 'Run heavy work on the home server build-host.local instead of this Mac, with the `vt` command: the parsalytics full suite (`vt rspec-full`), targeted specs (`vt rspec`), the investviews web e2e (`vt e2e`) and live e2e (`vt e2e-live`), whole-project builds, typecheck and lint, and anything that starts Docker (`vt run [--host] -- …`). Each run gets its own fresh Postgres, ClickHouse and Redis in Docker on vtserv, so parallel sessions never share a test database and the Mac stays usable. Use whenever you are about to run a full test suite, an e2e suite, `pnpm build`, `rubocop` on a whole project, `bin/rspec-full`, `pnpm test:e2e`, `pnpm test:e2e:live`, `docker build/run`, or an infra `*_e2e.sh` script — and whenever the user says "vt", "vtserv", "run it on the server", "run the suite", "heavy tests". Also for `vt status`, `vt doctor`, a stuck or cancelled run, and what to do when vtserv is down.'
allowed-tools: Bash, Read
---

# vtserv — heavy work runs on build-host.local, not on the Mac

Many agent sessions share the developer Mac. When several of them run full suites, e2e or Docker at
once, the Mac load reaches 250–480 and everything freezes (KAN-387). The home server build-host.local
(24 threads, 47 GB) runs that work instead, through one command: **`vt`** (`~/bin/vt`).

## The rule

**Every heavy run goes through `vt`.** Heavy means:

| work | command (from your worktree) |
|---|---|
| parsalytics full suite | `vt rspec-full` (args after `--` go to rspec: `vt rspec-full -- --seed 1`) |
| parsalytics targeted specs | `vt rspec $(bin/rspec-changed --list)` · `vt rspec spec/models/user_spec.rb:12` (more than 80 plain file paths run through `bin/rspec-full` by themselves; with rspec options use `vt rspec-full <files> -- <options>`) |
| investviews stubbed web e2e | `vt e2e` · `vt e2e city-search.spec.ts` |
| investviews live e2e | `vt e2e-live` · `vt e2e-live login.spec.ts` (backend: as `e2e-live.sh` finds it, or `PARSALYTICS_DIR=…`) |
| whole-project build / typecheck / lint | from `web/`: `vt run --no-db -- bash -c 'pnpm build && pnpm typecheck'` · parsalytics: `vt run --no-db -- bundle exec rubocop` (vt keeps your subdirectory) |
| infra Docker tests | from `infra/ansible`: `vt run --host -- bash tools/security_updates_e2e.sh` |
| any other heavy command | `vt run -- <command>` (runs in the same subdirectory as here) |

What stays on the Mac: one rspec or Vitest file or a few examples while you code, `pnpm test`
(Vitest), lint of one file, dev servers, and **anything that needs git** — `.git` is not copied, so
compute git-based lists on the Mac and pass the result (`vt rspec $(bin/rspec-changed --list)`).
An e2e spec, stubbed or live, is never Mac work: not even one, at any load.

Run long ones in the background (`run_in_background`) and wait for the notification. The output
streams to your terminal unchanged; **vt's exit code is the command's exit code.**

Before a long batch (several `--seed` runs, a full suite) that includes a NEW spec file, run that
file alone first (`vt rspec <file>`, ~1 min): a bug in it otherwise shows in every run of the batch.
**Why:** 2026-11-03 (KAN-444), a new guard spec's wrong assertion failed in all 9 runs of a 49-min batch.

vtserv is an old CPU (one thread is ~4× slower than the Mac's): the parsalytics full suite takes
20–30 min there (3.5 min on the Mac), each web e2e suite about 5 min. Start the full suite once,
early, in the background, and keep working on targeted specs meanwhile.

## What a run does

1. Takes this checkout's **lease** on vtserv. A second run from the same checkout waits here (it
   prints who holds it) — before anything is copied.
2. rsyncs the checkout — uncommitted and untracked files, `.env*` and `config/master.key` included;
   never `.git`, `node_modules`, `.next`, `tmp/`, `log/`, `.vault`, keys or tfstate.
3. Waits for one of 3 slots on vtserv if all are busy (prints who holds them).
4. Starts a fresh set of containers: a runner (Ruby, Node, Chromium) and Postgres 16, ClickHouse
   25.11, Redis 7.2 that share the runner's network. Inside, the databases are at the Mac's
   addresses (127.0.0.1:5432 / 8123 / 6379) and belong to this run only.
5. Installs gems / node_modules / Chromium if needed (shared caches), runs the command.
6. Copies `web/test-results/` and `web/playwright-report/` back after e2e (also after a failure).
   ⚠️ Each copy-back REPLACES the last: in `vt e2e …; vt e2e-live …` the first run's failure files
   are gone. Read or copy them aside before the next run. **Why:** 2026-11-02 (KAN-349), lost a stubbed failure; re-ran it 3×.
7. Removes the containers; once docker confirms they are gone, it deletes the Rails test logs
   (`log/test*.log*`) and `coverage/` in the run's vtserv copy (best effort; never through a
   symlink). The e2e results and the caches (node_modules, .next, tmp/, gems) stay. **Why:**
   2026-11-02 (KAN-437), each parsalytics copy kept ~200 MB of test logs.
   Ctrl-C or a killed background task also stops the run on vtserv within 30 s; a connection that answers nothing for 60 s, too. While a run is going, `vt` keeps the Mac
   from idle sleep (`caffeinate`): a sleeping Mac sends no heartbeat, and vtserv stops the run.

Pinned on vtserv, so a run can only reach its own databases: `DATABASE_*`, `TEST_DB_*`, `CH_*`,
`REDIS_URL`, `PUBLIC_API_REDIS_URL`, the `E2E_PG/CH/REDIS_*` probes, `E2E_SKIP_SETUP`,
`SENTRY_DSN` (off), `RAILS_ENV=test` for rspec. `-e` cannot set them. A `.env*` that sets any
`*DATABASE_URL` is refused (exit 70): remove that line for the run.

## Options and other commands

```
vt run [--no-db] [--no-prepare] [--host] [-e KEY=VAL]… -- <command…>
  --no-db       no database containers (faster for builds and lint)
  --no-prepare  skip bundle / pnpm install
  --host        run on the vtserv host as user vt (rootless Docker available), not in a container
VT_CLICKHOUSE=<tag> vt rspec …   any run with databases: clickhouse/clickhouse-server:<tag>, not 25.11
vt status        slots, runs, containers on vtserv
vt doctor        ssh, rootless Docker, images, disk, reaper — one line each (disk: LOW below 15 GB,
                 fails below the 10 GB floor)
vt stop <run-id> stop one run (the id is in vt's last line and in vt status)
vt clean         delete this checkout's copy on vtserv
vt setup         pull the images and build the runner image ahead of time
```

In `--host` mode, containers a script starts with `docker run` / `docker create` get the run's
label and are removed with the run, even when the script's own cleanup never runs. Containers from
`docker compose` do not: a host-mode script that uses compose must remove them itself.

From the Mac's environment only these travel: `RSPEC_FULL_WORKERS` (rspec-full) and
`E2E_BOOT_TIMEOUT`, `E2E_TEARDOWN_WAIT` (e2e-live). Playwright gets `--workers=4` unless you pass
`--workers`.

`VT_CLICKHOUSE` tests another ClickHouse (e.g. `25.10`, the version production may run). **ClickHouse
26.x does not start on vtserv**: its Xeon X5675 has no AVX, the server dies with SIGILL
(`clickhouse-1 exited (132)`, vt exit 70). Test 26.x / `:latest` on GitHub CI instead. **Why:**
2026-11-02 (KAN-406), `VT_CLICKHOUSE=latest` (26.10.3.7) crashed on start.

ClickHouse in a run keeps its data on a **2 GB tmpfs**, its only disk: the host's free space does
not help it. Its eight big system log tables (`text_log`, `query_log`, `processors_profile_log`,
`trace_log`, `metric_log`, `query_metric_log`, `part_log`, `asynchronous_metric_log`) are off in
`server/clickhouse-vt.xml`. The parsalytics #441 and #443 full suites failed with `Cannot reserve
1.00 MiB, not enough space (NOT_ENOUGH_SPACE)`; a clean full suite then had the tmpfs at 1959 of
2048 MB, nearly all of it these tables, and passed by 89 MB. A spec cannot read those tables on
vtserv. **Why:** 2026-11-02 (KAN-437).

Exit codes: the command's own · **64** usage · **69 vtserv unreachable** · **70** vtserv-side
setup failed (image build, containers, a refused `.env`, the disk below the 10 GB floor) · **255** ssh lost the connection mid-run
(no answer for 60 s — keepalive 5 s × 12): no test result. `vt doctor`, re-run once; a second 255 →
report it, never the Mac. **Why this exists:** 2026-11-01 (KAN-400), `vt rspec-full` ended 255 twice
(16, 20 min), no worker output. The cause was the Mac going to idle sleep; `vt` now keeps it awake.

## When vtserv is down (exit 69) — ask, do not fall back

`vt` prints `vtserv is unreachable` and runs nothing. **Do not run the heavy command on the Mac
instead.** Several sessions each deciding "the load looks fine" at the same moment is exactly how
the Mac froze. Tell the user vtserv is down, give the command you wanted to run, and ask. Keep
doing work that does not need the run.

## When something looks wrong

- `vt doctor` first. `vt status` shows every run, its state and phase, and whether its lease is
  alive.
- A run "waiting: another vt run from this checkout holds it" — another session of yours, or a run
  you started in the background. `vt status`, then wait or `vt stop <id>`.
- First run after a Ruby or Node version change builds a new runner image (a few minutes; the log
  path is printed).
- **Exit 255**: the ssh connection was lost (the Mac slept with the lid closed, the network
  dropped for over a minute). vtserv has already stopped the run. Run it again.
- **Exit 70, "below the 10 GB floor: this run was NOT started"**: vtserv's disk is nearly full.
  The command and its containers did not start. A refusal while taking the lease comes before the
  sync; one after a wait for a slot comes after it, so the copy may already be on vtserv. Tell the
  user, and never run it on the Mac instead. `vt clean` removes this checkout's copy. Once the user
  has run the KAN-437 play (`vtserv.yml`), `vt-reaper` removes checkouts with no run for 24 h and,
  while less than 30 GB is free, the least recently run ones (never one in use); until then vtserv
  runs the old reaper, which keeps a checkout for 14 days. **Why:** 2026-11-02 (KAN-437),
  48 checkout copies (33 GB) filled the disk in one day.
- **Known vtserv-only e2e failures** (headless Linux Chromium, no GPU): `discover-tooltip.spec.ts`
  :154 and :166, `ai-connect.spec.ts:308`, live `map.spec.ts:426` — investviews backlog BL-0010.
  To call a failure pre-existing, run the same spec on `main` on vtserv, not on the Mac.
- **Known Linux-only spec failure** (vtserv and CI, not the Mac): parsalytics
  `cell_listings_spec.rb:158` (KAN-409). Name it in the report; it is not the branch's.
- **parsalytics Selenium specs (`type: :system, :js`) never run on vtserv**: the runner has only
  Playwright's Chromium for investviews, no Chrome on PATH, so they skip. Only GitHub CI runs them;
  report them UNVERIFIED otherwise. **Why:** 2026-11-03 (KAN-434), all 6 browser examples skipped on vtserv; follow-up KAN-440.
- **vtserv hides AWS-metadata failures** (`compose.yml` sets `AWS_EC2_METADATA_DISABLED`): a spec red on
  CI with `169.254.169.254` is green here, on `main` too. To reproduce: `vt run -e AWS_EC2_METADATA_DISABLED=false
  -- bash -c 'bin/rails db:test:prepare && bundle exec rspec <file>'` (`vt run` does not prepare the test DB).
  **Why:** 2026-11-02 (KAN-407), a PR cited a default vtserv run as proof; the independent review found `main` green there.
- The vtserv side lives in `~/.claude/skills/vtserv/server/` and is copied to
  `vt@build-host.local:vt/bin/<hash>/` on first use. The host itself is set up by the Ansible play
  `investviews/infra/ansible/vtserv.yml` (`roles/vt_runner_host/README.md`).
- Tests for `vt` itself: `~/.claude/skills/vtserv/tests/run.sh`.

## Leave nothing behind on vtserv

vtserv's disk is shared by every session (110 GB, about 30 GB of it Plex). It filled up on
2026-11-02 (KAN-437): 48 checkout copies, 33 GB, in one day.

- **Every checkout you run `vt` from is one copy on vtserv** (investviews ~1.2 GB, its backend copy
  ~0.4 GB, parsalytics ~0.5 GB). Baseline, review and mutation worktrees count too.
- **Before you remove a worktree that ran `vt`, run `vt clean` in it** — it finds the copy from the
  checkout path, so it cannot be done after the worktree is gone. `task-cleanup` does this for the
  task worktree; for every other worktree you create (a `main` baseline, a review checkout), it is
  yours. `vt clean` refuses (exit 75) while a run holds the copy.
- Reuse one baseline worktree per repo for a task instead of making a new one per check.
- A run removes its containers and, after them, its test logs and coverage (step 7 above).
  `vt-reaper` removes copies with no run for 24 h and, under 30 GB free, the least recently run ones
  (once the KAN-437 play is applied). `vt` refuses a run below 10 GB free.
- ClickHouse in a run logs warnings and errors only (`server/clickhouse-vt.xml`): at the image's
  default trace level its log grew 800 MB in 7 minutes, on vtserv's disk.

## Rules for vtserv

- vtserv is a **development** server. It is never a production host and holds no production access.
- `vt` logs in as the unprivileged user `vt` (no sudo, rootless Docker). Do not use the `ubuntu`
  admin account for runs, and never give `vt` sudo or the `docker` group.
- Containers a run starts are removed by the run; `vt-reaper` on vtserv removes what a dead lease
  left. Nothing needs to go into a task's `.procs` file for a `vt` run.
