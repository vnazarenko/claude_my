---
name: security-check
description: Check ONE server for missing security updates, read-only, and write a report of what to patch. It lists what runs on the server with exact versions (one read-only SSH script), finds the security fixes for those versions (Node.js releases, Ubuntu CVE fixes, the CISA KEV list, the apps' lockfiles, vendor pages), keeps the Critical / High / exploited ones that affect us, saves a report in the project repo and posts a summary to Jira. It never updates, restarts or writes anything on the server; it proposes and the user approves. Use whenever the user says "security check", "/security-check <server>", "check security updates for <server>", "what must we patch on <server>", "is <server> behind on security releases", "which CVEs affect <server>", "is our Node / OpenSSL / nginx on <server> vulnerable", or when a scheduled security run starts with this skill.
---

# security-check — what must we patch on a server

`/security-check <server> [--since 14d] [--ticket KEY]`

| argument | meaning |
|---|---|
| `<server>` | the profile name: `infra/security-check/<server>.yml` in the current repo |
| `--since Nd` | the window for "new". Default: the profile's `since_days`, else 14. Older pending fixes are still reported. |
| `--ticket KEY` | the Jira ticket for the summary. Without it, a new ticket is created. |

In this file, `$SKILL` means `~/.claude/skills/security-check`.

## ⚠️ Hard rule: read-only on the server

- **Never update, install, upgrade, restart, reload or write anything on the server.** Not even
  `apt update`. Not even "just one restart".
- **The only command that reaches the server is `scripts/inventory.sh`.** No other `ssh`, `scp`
  or `rsync` to it, no remote command typed by hand, no other script.
- No file contents leave the server. The inventory brings back versions, paths of binaries and
  git shas. Nothing else.
- If a step seems to need more access, stop and ask the user. Do not find another way in.
- Fixes are **proposals**. Nothing is applied until the user picks it. An approved fix goes
  through the project's normal change: a PR with "Deploy steps" and "After deploy", run by the
  user or on the user's explicit request — never from this skill.

## Files

| file | what it does |
|---|---|
| `scripts/inventory.sh` | runs `remote-inventory.sh` on the server over SSH. No agent forwarding, no port forwards, no shared connection. Prints one JSON. |
| `scripts/remote-inventory.sh` | the read-only script that runs on the server. A test allows only 9 commands in it. |
| `scripts/advisories.py` | `node`, `usn`, `kev`: finds the fixes for the inventory. Stdlib Python, disk cache. |
| `references/sources.md` | per component: where fixes are announced, how to judge "affects us", update and restart. |
| `references/report-template.md` | the report and the Jira summary. |
| `references/profile-example.yml` | a profile to copy into a project. |
| `references/run-brief.md` | the brief of a scheduled run (one Jira ticket, one worktree, one session). |
| `tests/run_all.sh` | every test of this skill. Run it after any change here. |

## Step 0 — read the profile

1. Find `infra/security-check/<server>.yml` under `git rev-parse --show-toplevel`. Not there →
   `git ls-files '*security-check/<server>.yml'`. Still none → stop and tell the user; point to
   `references/profile-example.yml`.
2. Read these keys:

| key | required | used for |
|---|---|---|
| `server` | yes | report file name, Jira summary |
| `ssh_host` | yes | the first argument of `inventory.sh` (an alias from `~/.ssh/config`) |
| `jira_project` | yes | the new ticket, when there is no `--ticket` |
| `report_dir` | yes | where the report goes, relative to the repo root |
| `since_days` | no (14) | the default `--since` |
| `ours[]` | no | apps we own: we may propose updates for them |
| `ours[].name` | yes | the row name in the report |
| `ours[].pm2_home` | no | `--pm2-home` for `inventory.sh` |
| `ours[].revision_file` | no | `--revision-file` for `inventory.sh`; the deployed git sha |
| `ours[].repo` | no | the local git repo of the app: `.` = this repo, or a path from the root of its **main checkout** (in a worktree: the parent of `git rev-parse --path-format=absolute --git-common-dir`) |
| `ours[].lockfile` | no | the lockfile path inside `repo` (`pnpm-lock.yaml`, `Gemfile.lock`) |
| `ours[].runtime` | no | `node`, `ruby`, … |
| `ours[].node_pin` | no | files that pin the Node version (for the update proposal) |
| `ours[].image` | no | a Docker image we run |
| `not_ours[]` | no | things on the server that belong to others: reported, never proposed |

3. Make an output folder outside every repo: the session's scratchpad, else `mktemp -d`. Call it
   `$OUT`. The inventory and the raw results stay there. They never go into a repo.

## Step 1 — inventory (the only step that touches the server)

```bash
bash $SKILL/scripts/inventory.sh <ssh_host> \
  --pm2-home <ours[].pm2_home> ... \
  --revision-file <ours[].revision_file> ... > "$OUT/inventory.json"
```

- Claude Code asks before this runs, unless the user has an allow rule for it. Do not work around
  the prompt. In a scheduled run, set the ticket to `Blocked` and wait
  (see `references/run-brief.md`).
- It fails (`ERROR: …`, exit 1) → stop. Report the error. Do not try another way in.
- Paths must be absolute and plain (`[A-Za-z0-9_./@+-]`, no `..`). The script refuses others.

What you get (one JSON object):

| field | what |
|---|---|
| `os` | `id`, `version_id`, `codename`, `kernel_running`, `kernel_newest_installed`, `reboot_required`, `reboot_required_pkgs` |
| `apt.lists_age_hours` | how old the server's package lists are. No `apt update` is run. Over 48 → say so in the report. |
| `apt.upgradable[]` | `package`, `source`, `installed`, `candidate`, `origin` (repo label: `Ubuntu`, `Docker CE`, or `null`), `archives` |
| `node[]` | every Node binary: nvm installs and running ones; `version`, `running` (process count), `default_alias` |
| `nvm[]` | each nvm tree and its `default` alias as written |
| `pm2[]` | per `--pm2-home`: `daemon_running`, `daemon_node`, `daemon_node_path`, `pm2_version` |
| `services` | dpkg versions of nginx, postgresql, redis, clickhouse, docker, containerd, openssh, openssl |
| `ruby`, `python3` | rvm rubies; the newest `python3.x` dpkg version |
| `docker_images[]` | images of running containers: `image`, `id`, `created` |
| `running_deleted_exe` | binaries replaced on disk but still running: old code until a restart |
| `revisions` | `{<revision_file>: <git sha or null>}` |

A missing tool gives `null` or `[]`, not an error.

## Step 2 — find the fixes

Use `N` from `--since` (`14d` → `14`).

```bash
python3 $SKILL/scripts/advisories.py node "$OUT/inventory.json" --since-days N > "$OUT/node.json"
python3 $SKILL/scripts/advisories.py usn  "$OUT/inventory.json" --since-days N > "$OUT/usn.json"
```

- `node`: per Node version found (installs and pm2 daemons): `status` (`behind`, `up_to_date`,
  `not_checked`, `unknown_major`), `fixed_in`, `missed_security_releases[]` with `in_window`,
  `latest_release`, `support` of the line (`end_of_life` matters). It gives versions, not CVEs:
  read the CVEs and their severity from the Node release posts (`references/sources.md`).
- `usn`: per Ubuntu source package with a pending fix: `cves[]` (`priority`, `fixed`, `usns`,
  `in_candidate`), `max_priority`, `new_in_window`. Also `kernel[]` and `vendor[]` (not looked up)
  and `no_security_fix[]`.
- Exit 1 = a source could not be fetched (the message names the URL). `CERTIFICATE_VERIFY_FAILED`
  means this Python has no CA certificates: set `SSL_CERT_FILE` to a CA bundle and run again.
  Any other fetch error: put that part under
  "Not checked" and go on. Exit 2 = bad input: fix the call.
- The cache is `~/.cache/security-check` (or `$SECURITY_CHECK_CACHE`). Repeat runs are cheap.

Apps we own — audit the **deployed** revision, not `main`. For each `ours[]` with `lockfile`:

```bash
sha=<inventory .revisions[<revision_file>]>        # null → "Not checked: revision unknown"
git -C <repo> cat-file -e "${sha}^{commit}" || git -C <repo> fetch origin
mkdir -p "$OUT/<name>"
# Node (pnpm): the lockfile's folder needs package.json, pnpm-lock.yaml, pnpm-workspace.yaml (if any)
git -C <repo> show "${sha}:<dir>/package.json"   > "$OUT/<name>/package.json"
git -C <repo> show "${sha}:<dir>/pnpm-lock.yaml" > "$OUT/<name>/pnpm-lock.yaml"
(cd "$OUT/<name>" && pnpm audit --prod --json > ../audit-<name>.json)
# Ruby: the Gemfile.lock for the audit; the Gemfile tells which gems are dev/test only
git -C <repo> show "${sha}:Gemfile.lock" > "$OUT/<name>/Gemfile.lock"
git -C <repo> show "${sha}:Gemfile"      > "$OUT/<name>/Gemfile"
bundle-audit update --quiet     # not "check --update": it prints the update lines into the JSON
bundle-audit check --format json "$OUT/<name>" > "$OUT/audit-<name>.json"
```

- Write `${sha}:…` with braces: in zsh `$sha:w…` is a modifier, not a path.
- Both audits exit 1 when they find something. That is a result, not an error.
- Never `pnpm audit --fix`, `pnpm install` or `bundle update` here.
- Both audits often give a GHSA id with no CVE id or no rating (`cves: []`, `criticality: null`).
  `gh api /advisories/<GHSA-id>` gives `cve_id` and `severity`. Use them for the table and `kev`.
- `bundle-audit` checks every gem group. A gem only in `development` or `test` does not run on
  the server: `affects us: no — test group`. `references/sources.md` says how to tell.

Then the exploited ones: feed every CVE id you have to `kev` (it reads ids from any text).

```bash
cat "$OUT"/usn.json "$OUT"/audit-*.json "$OUT"/node-cves.txt 2>/dev/null \
  | python3 $SKILL/scripts/advisories.py kev - > "$OUT/kev.json"
```

`node-cves.txt` = the CVE ids you took from the Node release posts.

Not covered by the scripts: vendor repos (`usn.vendor[]`: ClickHouse, Docker CE, …), Docker
images, rubies, pm2, Go or other binaries. `references/sources.md` says where to look. What you
cannot check goes under "Not checked", with the reason.

## Step 3 — judge: keep what matters

Use `references/sources.md`. For every pending fix:

- **Keep** it in the main table when it is Critical or High (the source's own rating), or in KEV
  (any rating), **and** it may affect us.
- **affects us**: `yes`, `no` or `unclear`, plus a few words why (runs? reachable? feature used?).
  `unclear` counts as `yes` in the summary.
- **update command**: the exact command to propose. Never run it.
- **restart**: what must restart for the fix to take effect (`none` when nothing).
- **risk**: `low`, `medium` or `high`, plus a few words (outage length, major version jump).
- Medium and Low: one count line, not rows.
- Critical or High with `affects us: no`: not in the table, but one line in "Lower severity"
  with the reason, so the reader sees it was looked at.
- One fix for many advisories (one version bump) → one row, even when only some of them may
  affect us.
- `not_ours[]` → "Not ours (needs owner)". Never propose a change to someone else's app.
- **New or older**: new = published inside the window (`in_window` / `new_in_window`) or not in the
  previous report. Older = in the previous report and still pending. The previous report is the
  newest `<report_dir>/*-<server>.md` before today. No previous report (first run) → every row is
  new; mark the ones published inside the window with ★.

## Step 4 — write the report

- File: `<report_dir>/<YYYY-MM-DD>-<server>.md` (today, local date), from
  `references/report-template.md`. A second run on the same day overwrites it.
- Nothing Critical, High or exploited → the short form: "Nothing critical." plus the sections
  that still have rows ("Not ours", "Not checked", "Reboot needed") and the versions appendix.
- Before saving, read it once more. **No** IPs, tokens, passwords, env values, file contents or
  `claude.ai` links. Versions, package names, CVE ids, binary paths and git shas are fine.
- Save it in the current worktree and commit it on its branch: `docs(security): <server> report
  <YYYY-MM-DD>`. On a main checkout, do not commit: tell the user the file is there.

## Step 5 — Jira and the user

Jira CLI: `$JIRA_PY` when set, else `jira-tickets/scripts/jira.py` from the `jira-tickets` skill
(look in `<repo>/.claude/skills/`, the parent folders' `.claude/skills/`, then `~/.claude/skills/`).
None found → skip Jira and say so.

1. No `--ticket`:
   `python3 "$JIRA_PY" create --project <jira_project> --type Task --label security --summary "Security check: <server> <YYYY-MM-DD>" --description "<one line: read-only check, report path>"`
   (the default type is Bug, so `--type Task` is required).
2. Write the summary with the "Jira summary" part of `references/report-template.md` to
   `$OUT/jira-summary.txt`. Put the PR link in it when a PR for the report is open. Check it:
   under 30,000 characters (the Jira limit is 32,767) and no secrets or IPs. Then:
   `python3 "$JIRA_PY" comment <KEY> --body-file "$OUT/jira-summary.txt"`
3. Tell the user, short: the result line, the table of proposed updates, the report path, the
   ticket. Then **one** question: which updates to prepare (numbers, `all` or `none`).

## Step 6 — stop

The run ends here. Do not apply anything. When the user picks updates, each one is a normal change
in the project: a PR that changes the pins or configs, with "Deploy steps" (the exact commands,
the restart) and "After deploy" (the check, the rollback). Running it on the server needs the
user's explicit go for that PR.

## Scheduled runs

A scheduled run gets its own Jira ticket, worktree and session, and starts with
`/security-check <server> --ticket <KEY>`. Its brief is `references/run-brief.md`: it adds the PR
for the report, the Jira events and the question to the user. The read-only rule is the same.
