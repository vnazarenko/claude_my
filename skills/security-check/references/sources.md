# Sources — where fixes are announced, and how to judge them

Read this in Step 2 and Step 3 of `SKILL.md`. Per component: where to look, how to decide
"affects us", what to propose, and what must restart.

All lookups here are reads of public pages and APIs from the local machine. None of them touch
the server.

## How to judge any fix

**Severity** — use the source's own rating, in this order:

1. the vendor's rating (Node release post, Ubuntu priority, GitHub advisory severity);
2. CVSS v3 base score when there is no rating: 9.0+ Critical, 7.0+ High, 4.0+ Medium;
3. in the CISA KEV list → **exploited**: keep it whatever the rating says.

**Affects us** — answer `yes`, `no` or `unclear`, with the reason in a few words:

| question | points to `yes` | points to `no` |
|---|---|---|
| Is the affected version on the server? | our version is in the range | fixed already, or another line |
| Does it run? | `running` > 0, a pm2 daemon, a service, a running container | installed, never started |
| Is the vulnerable part used? | the feature, flag or module is in use | Windows-only, an unused flag (e.g. Node's `--permission`), a dev-only gem |
| Can an attacker reach it? | network-facing: nginx, the web app, SSH, a public port | local only, behind auth we control |

`unclear` counts as `yes` in the summary. Write what is unclear.

A binary that is installed but does not run is still listed when it is used by a deploy
(for example the nvm `default` alias that builds apps). Say "used at build time".

**Risk** of the update — `low`, `medium`, `high`, plus a few words:

- `low`: a patch release in the same line, a reload, no outage.
- `medium`: a restart with a short outage, or a minor version jump.
- `high`: a major version jump, a reboot, a database restart, or no easy rollback.

## Node.js (nvm installs, pm2 daemons)

| | |
|---|---|
| Where | `advisories.py node` (nodejs.org release index + release schedule) |
| CVEs and severity | the release post: `https://nodejs.org/en/blog/vulnerability/` (one post per security release, for example `<month>-<year>-security-releases`), or the version's entry in `https://github.com/nodejs/node/blob/main/doc/changelogs/CHANGELOG_V<major>.md` |
| End of life | `support: end_of_life` in the `node` output → no more fixes. Propose a move to a supported line. |

- Affects us: a running Node (`running` > 0) or a pm2 daemon's Node → `yes` for most CVEs. Read
  each CVE: some are only for Windows, the permission model, or a module we do not use.
- Update proposal (as the app's user, never as root):
  1. `nvm install <fixed_in>` — this does **not** move the `default` alias. Do not move it when
     other apps use it.
  2. change the project's Node pins (`ours[].node_pin`, for example `.nvmrc` and the deploy
     config), then deploy.
  3. pm2 in cluster mode runs workers on the **daemon's** Node. `pm2 reload` cannot change it.
     The daemon must restart: `pm2 kill`, start the app again, `pm2 save` — a few seconds of
     outage. Then regenerate `pm2 startup` from the new Node, because the boot unit names the
     old Node's path.
  4. check: the pm2 daemon's Node in the next inventory (`pm2[].daemon_node`).
- Rollback: keep the old version installed. Revert the pin, deploy, `pm2 kill` and start on the
  old Node, regenerate `pm2 startup`.

## pm2

- Version: `pm2[].pm2_version` (read from its `package.json`).
- Advisories: `https://github.com/Unitech/pm2/security/advisories` and
  `https://github.com/advisories?query=pm2`. `pnpm audit` does not see a global pm2.
- Update: `npm i -g pm2@<version>` under the same Node, then `pm2 update` — this restarts the
  daemon. Propose it together with a Node update when there is one.

## Ubuntu packages (OpenSSL, OpenSSH, nginx, PostgreSQL, Redis, Python, libraries)

| | |
|---|---|
| Where | `advisories.py usn` (Ubuntu CVE tracker, by source package and release) |
| Notices | `https://ubuntu.com/security/notices` (USN pages) |
| Severity | Ubuntu priority: `critical`, `high`, `medium`, `low`, `negligible` |

- `in_candidate: false` → the fix is newer than what apt offers now: the package lists are old
  (`apt.lists_age_hours`), or the fix is only in ESM (Ubuntu Pro). Say which.
- `pocket` tells where the fix is: `security`, `updates`, `esm-infra`, `esm-apps`.
- A library (libssl, libc, zlib, …) affects every process linked to it. After the update, those
  processes run old code until they restart; `running_deleted_exe` in the next inventory shows
  what was missed.
- Update proposal: `apt-get install --only-upgrade <binary packages>` (the `binaries` of the
  source package), or `unattended-upgrade` for all security updates.

| component | restart after the update |
|---|---|
| a library | every process that uses it; `needrestart -r l` lists them |
| nginx | `nginx -t && systemctl reload nginx` (no outage) |
| OpenSSH | `systemctl restart ssh`; keep a second session open while you do it |
| PostgreSQL | `systemctl restart postgresql` (short outage; plan it) |
| Redis | `systemctl restart redis-server` (short outage; data comes back from disk) |
| Python | the services that run on it |

A package from a vendor repo (nginx.org, PGDG, redis.io) has `origin` other than `Ubuntu` and is
in `usn.vendor[]`. Check the vendor page instead:

| vendor | advisories |
|---|---|
| nginx.org | `https://nginx.org/en/security_advisories.html` |
| PostgreSQL (PGDG) | `https://www.postgresql.org/support/security/` |
| Redis | `https://github.com/redis/redis/security/advisories` |
| OpenSSH (upstream) | `https://www.openssh.com/security.html` |

## Kernel

- Not looked up by `usn` (one kernel USN lists hundreds of CVEs). Use the inventory:
  `kernel_running`, `kernel_newest_installed`, `reboot_required`, `reboot_required_pkgs`, and the
  `usn.kernel[]` list (kernel packages with an upgrade).
- Newer kernel installed but not running, or `reboot_required: true` → "Reboot needed".
- Notices: `https://ubuntu.com/security/notices?package=linux`.
- Update proposal: `apt-get install --only-upgrade <kernel packages>`, then a reboot in a planned
  window. Risk `high` (full outage). Livepatch, when enabled, covers some fixes without a reboot.

## ClickHouse (vendor apt repo)

- `origin` is not Ubuntu → in `usn.vendor[]`.
- Advisories: `https://github.com/ClickHouse/ClickHouse/security/advisories` and the security
  changelog `https://clickhouse.com/docs/whats-new/security-changelog`.
- Supported versions: the LTS lines (`YY.3`, `YY.8`) get fixes for a year; other releases for about
  three months. Unsupported → say so.
- Update proposal: `apt-get install --only-upgrade clickhouse-server clickhouse-client
  clickhouse-common-static`, then `systemctl restart clickhouse-server`.
- Risk: `medium` for a patch in the same line; `high` for a new line (format changes, no easy
  downgrade). A config that installs "latest" can jump lines on its own; say so.

## Docker engine and containerd (vendor apt repo)

- `origin` `Docker CE` → in `usn.vendor[]`.
- Release notes: `https://docs.docker.com/engine/release-notes/`. Advisories:
  `https://github.com/moby/moby/security/advisories`,
  `https://github.com/containerd/containerd/security/advisories`,
  `https://github.com/opencontainers/runc/security/advisories`.
- Update proposal: `apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io`.
- Restart: the daemon restarts, and containers stop with it unless `live-restore` is on. Risk
  `medium` or `high`: every container has an outage.

## Docker images

- `docker_images[]`: the image tag and its build date. There is no API here.
- Check the image's own releases (its GitHub page or registry page) for a newer tag with security
  fixes, and the upstream app's advisories.
- A scanner (`trivy`, `grype`), if installed locally, can scan a public image by tag on the local
  machine. It does not touch the server. Without one, the base OS of the image is "Not checked".
- Update proposal: a new tag in the project's config, then recreate the container. Risk: the
  app's own upgrade notes.

## Ruby (rvm) and gems

- Ruby: `https://www.ruby-lang.org/en/security/`; supported lines:
  `https://www.ruby-lang.org/en/downloads/branches/`. An end-of-life line → propose a move.
- Gems: `bundle-audit check --update --format json` on the deployed `Gemfile.lock` (ruby-advisory-db).
  `criticality` can be empty: use the CVE's CVSS then.
- Affects us: the gem is in the production bundle and its vulnerable part is used.
- Update proposal: `bundle update --conservative <gem>` in the app repo, tests, deploy. Restart:
  the app servers (a normal deploy does it).

## npm packages (pnpm)

- `pnpm audit --prod --json` on the deployed lockfile (GitHub advisory database).
  `--prod` leaves out dev dependencies: they do not run on the server.
- Framework advisories, for example Next.js: `https://github.com/vercel/next.js/security/advisories`.
- Affects us: server-side code paths first (SSR, API routes, middleware); a client-only package
  is lower.
- Update proposal: bump the package in the app repo (`pnpm update <pkg>` or an override), tests,
  deploy. Restart: the app (a normal deploy does it).

## Go and other single binaries

- The inventory does not version them. The version is in the project's deploy config.
- With the source at the deployed revision: `govulncheck ./...` locally. Without it: "Not checked".

## CISA KEV

- `advisories.py kev` against `https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json`.
- A hit means attackers use it now. Keep it in the main table, mark it **exploited**, and put it
  first in the proposed order.
