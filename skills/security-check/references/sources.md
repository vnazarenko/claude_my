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

- `low`: a patch release in the same line, no outage (for example a config reload; a new
  binary or library needs a restart).
- `medium`: a restart with a short outage, or a minor version jump.
- `high`: a major version jump, a reboot, a database restart, or no easy rollback.

## Node.js (nvm installs, pm2 daemons)

| | |
|---|---|
| Where | `advisories.py node` (nodejs.org release index + release schedule) |
| CVEs and severity | the release post: `https://nodejs.org/en/blog/vulnerability/` (one post per security release, for example `<month>-<year>-security-releases`), or the version's entry in `https://github.com/nodejs/node/blob/main/doc/changelogs/CHANGELOG_V<major>.md` |
| End of life | `support: end_of_life` in the `node` output → no more fixes. Propose a move to a supported line. |
| Distro build | `status: not_checked` (for example `/usr/bin/node` from the Ubuntu `nodejs` package). See below. |

- Affects us: a running Node (`running` > 0) or a pm2 daemon's Node → `yes` for most CVEs. Read
  each CVE: some are only for Windows, the permission model, or a module we do not use.
- **A project deploy doc wins.** When the app has `ours[].deploy_doc`, take the update and
  rollback steps from it: it knows how this server boots the app. The steps below are the
  generic case, for apps without one.
- Update proposal (as the app's user, never as root):
  1. `nvm install <fixed_in>`. It does not change the `default` alias text, but it can change
     what the alias **resolves to**. An alias that is not a full version (`22`, `lts/*`, `node`;
     see `nvm[].default_alias`) means the newest install that matches it. So a new `22.x`
     install moves a `22` default to it, and every login shell, cron job and deploy without its
     own pin switches at its next start. The safeguard, in the proposal:
     - before the install: `nvm version default`, and note the version it prints;
     - the new version matches the alias and other apps use the default → pin it first:
       `nvm alias default <the noted version>`;
     - after the install: `nvm version default` must print the noted version;
     - moving the alias back (`nvm alias default 22`) is a later step, for the owners of those apps.
  2. before the deploy, install what the deploy and the app run, under the new Node. A new nvm
     install has no global packages: pm2 and the package manager stay with the old Node. A
     deploy that runs them from the new pin fails, often after the release link has moved.
     Run `npm` and `corepack` by their full path in the new Node's `bin` folder:
     - pm2: `npm i -g pm2@<version>`, the same version as the running daemon
       (`pm2[].pm2_version`), so the new pm2 can talk to the old daemon until it restarts;
     - the package manager the project pins (`packageManager` in `package.json`), for example
       pnpm: `corepack enable pnpm`, then
       `COREPACK_DEFAULT_TO_LATEST=0 corepack install -g --cache-only pnpm@<version>`.
       Leave out `--cache-only` or the variable, and that version can become the user's default
       for every Node install (`lastKnownGood.json` in the corepack home), so apps without a pin
       switch. `--cache-only` alone still moves a default of the same major to a newer download
       (11.24.0 → 11.25.0); the variable stops that;
     - check: under the new Node, `lib/node_modules/pm2/package.json` names the daemon's pm2
       version (read the file: any `pm2` command can start a daemon), `pnpm -v` run in a folder
       whose `package.json` pins the version prints it, `lastKnownGood.json` is the same as
       before the install, and `nvm version default` still prints the noted version.
  3. change the project's Node pins (`ours[].node_pin`, for example `.nvmrc` and the deploy
     config), then deploy.
  4. pm2 in cluster mode runs workers on the **daemon's** Node. `pm2 reload` cannot change it.
     The daemon must restart: `pm2 kill`, start the app again, `pm2 save` — a few seconds of
     outage. Then the boot unit must name the new Node's path: regenerate it with
     `pm2 startup`, or edit its Node paths when the unit was written by hand.
  5. a custom `PM2_HOME`: `pm2 startup` can write a unit with two `Environment=PM2_HOME=`
     lines, and systemd uses the last one (often the shared `~/.pm2`). Check that the unit has
     exactly one, and that it is yours.
  6. check: the pm2 daemon's Node in the next inventory (`pm2[].daemon_node`).
- Rollback: keep the old version installed, with its pm2 and package manager. Revert the pin,
  deploy, restart the daemon on the old Node, and point the boot unit back at it.

A distro Node (`/usr/bin/node`, a dpkg version such as `18.19.1+dfsg-…`):

- `usn` does not see it unless apt offers an upgrade. Look it up by hand in the Ubuntu CVE
  tracker: `https://ubuntu.com/security/cves.json?package=nodejs&version=<codename>&status=needed`
  (and `status=released`), or the page `https://ubuntu.com/security/cves?package=nodejs`.
- On Ubuntu the `nodejs` package is in `universe`: Canonical covers it only through Ubuntu Pro
  (`esm-apps`), see `https://ubuntu.com/security/esm`. Say how many CVEs are `needed` (no fix yet)
  and whether any fix exists at all.
- Compare with upstream: when its major line is end of life, every Node security release since
  then says "End-of-Life versions are always affected".
- `running` counts `/proc/<pid>/exe` links. For a process inside a container, the link is the path
  **inside** the container. The inventory compares the link's target with the host file at that
  path: a container's process is listed apart, with `container: true` and `version: null`. Its
  Node is the image's: check the image (`docker_images[]`), not the host package.
- A binary replaced on disk (`<path> (deleted)`) cannot be compared: its file is gone. It counts
  as the host's (with the dpkg version) only when its process is in the host's mount namespace.
  Else it is listed with `container: true` and `version: null` too: a container's, or a service
  with its own mounts. Its version is not known; do not take the host package's.
- A Node binary in a folder a user may name (`/tmp`, a home folder outside nvm, a folder others
  can write) or a container's Node outside `/usr/bin` and `/usr/local/bin` is not listed: only
  counted in `filtered.other_paths.node`. Report the count under "Not checked".

## pm2

- Version: `pm2[].pm2_version` (read from its `package.json`).
- Advisories: `https://github.com/Unitech/pm2/security/advisories` and
  `https://github.com/advisories?query=pm2`. `pnpm audit` does not see a global pm2.
- Update: `npm i -g pm2@<version>` under the same Node, then `pm2 update` — this restarts the
  daemon. Propose it together with a Node update when there is one. When systemd owns the daemon
  (a boot unit), restart it through the unit instead, and follow `ours[].deploy_doc` when set.

## Ubuntu packages (OpenSSL, OpenSSH, nginx, PostgreSQL, Redis, Python, libraries)

| | |
|---|---|
| Where | `advisories.py usn` (Ubuntu CVE tracker, by source package and release) |
| Notices | `https://ubuntu.com/security/notices` (USN pages) |
| Severity | Ubuntu priority: `critical`, `high`, `medium`, `low`, `negligible` |

- `in_candidate: false` → the fix is newer than what apt offers now: the package lists are old
  (`apt.lists_age_hours`), or the fix is only in ESM (Ubuntu Pro). Say which.
- `pocket` tells where the fix is: `security`, `updates`, `esm-infra`, `esm-apps`.
- `usn` only looks at packages apt offers an upgrade for. A fix that is only in ESM never shows
  up on a host without Ubuntu Pro. To check the `services` too, run `usn` on a copy of the
  inventory (in `$OUT`) whose `apt.upgradable` lists their packages with `candidate` =
  `installed` and `origin` `Ubuntu`: any CVE it prints is a fix apt does not offer.
- A library (libssl, libc, zlib, …) affects every process linked to it. After the update, those
  processes run old code until they restart. `running_deleted_exe` does **not** show them: it
  sees only replaced executables (`/proc/<pid>/exe`), not libraries. So the proposal names the
  services to restart, and its check (a step for the user, after the update) is
  `needrestart -b -r l` on the server: it lists the processes that still use an old library and
  changes nothing. Without needrestart: restart every service that uses the library.
- Update proposal: `apt-get install --only-upgrade <binary packages>` (the `binaries` of the
  source package), or `unattended-upgrade` for all security updates.

| component | restart after the update |
|---|---|
| a library | every process that uses it. Check after the update: `needrestart -b -r l` lists the ones still on the old library (`running_deleted_exe` does not see libraries) |
| nginx | `nginx -t && systemctl restart nginx` (open connections drop; a second or two). A reload is **not** enough: it only re-reads the config, and the new workers still run the old binary and libraries. With no outage allowed: nginx's binary upgrade (`USR2`, then `QUIT` to the old master), see `https://nginx.org/en/docs/control.html#upgrade`. Check: `running_deleted_exe` in the next inventory no longer lists nginx, and `needrestart -b -r l` lists no nginx process |
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

- `origin` `Docker_CE` → in `usn.vendor[]`.
- Release notes: `https://docs.docker.com/engine/release-notes/`. Advisories:
  `https://github.com/moby/moby/security/advisories`,
  `https://github.com/containerd/containerd/security/advisories`,
  `https://github.com/opencontainers/runc/security/advisories`.
- Update proposal: `apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io`.
- Restart: the daemon restarts, and containers stop with it unless `live-restore` is on. Risk
  `medium` or `high`: every container has an outage.

## Docker images

- `docker_status` not `ok` → `docker_images` is `null`: images not checked. `not_running`: no
  dockerd of the host runs as root, so the script did not call docker. With socket activation
  (`docker.socket`, in Docker CE and Ubuntu's `docker.io`) any docker call starts a stopped
  daemon, and every container set to restart with it. Report "not checked: Docker daemon not
  running"; never start it to check. `podman`: `docker` is the podman shim (not called).
  `error`: `docker ps` failed.
- `docker_images[]`: per running image, its name, its repo `digest`, the id the container runs
  and that image's build date. There is no API here.
- `tag_moved: true`: the container runs an older image than its tag names now (a newer image was
  pulled or built under that name, or the name was removed). `image` is then the image's
  repo@digest name (`image` + `digest`) or its id. The container runs the old code until it is
  recreated. Check the old image (its `created`), and put "recreate the container" in the update
  proposal.
- `tag_moved: null` and `id: null`: not known. The tag moved while the script read docker (a pull
  or build at that moment), or docker did not list it. Report the image as not checked, and run
  the check again later.
- Check the image's own releases (its GitHub page or registry page) for a newer tag with security
  fixes, and the upstream app's advisories.
- Scan only the image the server runs, by its fixed name: `<repository>@<digest>`.
  `<repository>` is `image` without its `:tag`, the `:` after the last `/` (`redis:7` +
  `sha256:…` → `redis@sha256:…`; `localhost:5000/tool:1` → `localhost:5000/tool@sha256:…`).
  Never scan a tag (`:latest`, `:4.5`): the registry may name a newer image with it now, and the
  scan would be of an image the server does not run. Never report a scan of a tag as the running
  image.
- Take `digest` only from the inventory's `docker_images` row: it belongs to the `id` the
  container runs. Never look a digest up by a tag (a tag row of `docker images --digests`, a
  registry page): after a pull, the tag names a newer image. An older inventory without `digest`
  → rerun the inventory first.
- With a scanner on the local machine (it does not touch the server):
  `trivy image --platform linux/amd64 <repository>@<digest>` (`grype` has `--platform` too). The
  platform is the server's: `os.machine` `x86_64` → `linux/amd64`, `aarch64` → `linux/arm64`. One
  digest can name an image per platform, and without `--platform` the scanner takes the Mac's.
- `digest` is `null` (a local build, or `image` is an id): the image cannot be pulled by name
  safely. Do not scan its tag. Put it under "Not checked": "not checked: no pullable digest".
- No scanner installed: the image is "Not checked" ("no scanner"). Write what was checked
  instead (the build date, the releases page), and the `<repository>@<digest>` to scan.
- Update proposal: a new tag in the project's config, then recreate the container. Risk: the
  app's own upgrade notes.

## Ruby (rvm) and gems

- Ruby: `https://www.ruby-lang.org/en/security/`; supported lines:
  `https://www.ruby-lang.org/en/downloads/branches/`. An end-of-life line → propose a move.
- Gems: `bundle-audit update --quiet`, then `bundle-audit check --format json` on the deployed
  `Gemfile.lock` (ruby-advisory-db). `criticality` is often empty: use the GitHub advisory's
  `severity` (`gh api /advisories/GHSA-<id>`), else the CVSS score.
- Which gems run in production: the gems of the Gemfile's default and `production` groups, plus
  everything they depend on in the `Gemfile.lock`. A gem reached only from `development` or `test`
  (for example `selenium-webdriver`, `puma` when production runs Passenger) is `no — test group`.
  With Ruby installed locally: `Bundler::LockfileParser` for the lockfile and `Bundler::Dsl#eval_gemfile`
  for the groups, in a script in `$OUT`.
- The app server (Passenger, Puma) is a gem or a vendor package: say which, and check it too.
- Affects us: the gem is in the production bundle and its vulnerable part is used.
- Update proposal: `bundle update --conservative <gem>` in the app repo, tests, deploy. Restart:
  the app servers (a normal deploy does it).

## npm packages (pnpm)

- `pnpm audit --prod --json` on the deployed lockfile (GitHub advisory database). `cves` is often
  empty: `gh api /advisories/<github_advisory_id>` gives `cve_id`.
- Read each Critical and High advisory: most name the feature that must be in use (for Next.js:
  `next/og`, `use cache`, Server Actions, `images.remotePatterns`, SVG in image optimization).
  `git grep` the deployed sha for it, and write what you found in "affects us".
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
