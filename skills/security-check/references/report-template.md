# Report template

Copy the part between the `---` lines into `<report_dir>/<YYYY-MM-DD>-<server>.md` and fill it in.
Text in `<angle brackets>` is a placeholder. Drop a section when it has no rows, except "Result"
and the appendix. Write short, plain lines.

Rules for the content:

- Versions, package names, CVE ids, binary paths and git shas are fine.
- No IPs, tokens, passwords, env values or file contents from the server.
- One row per package and fix. Many CVEs fixed by the same version → one row, CVE ids in the cell
  (the first three, then `+N more`).
- `affects us`: `yes` / `no` / `unclear` plus a few words. `update command`: the exact command,
  or "see Node.js below" when it is longer than one line. `restart`: what restarts, or `none`.
  `risk`: `low` / `medium` / `high` plus a few words.

---

# Security check: <server>, <YYYY-MM-DD>

| | |
|---|---|
| Server | `<server>` (profile `<profile path>`) |
| Inventory | collected `<collected_at>` UTC; apt lists `<lists_age_hours>` h old |
| Window | new = published since `<window_start>` (`<N>` days) |
| Previous report | `<path>`, or none |
| Jira | `<KEY>` |
| Checked by | `/security-check`, read-only. Nothing was changed on the server. |

## Result

<One of these two lines:>

Nothing critical. No Critical, High or exploited fix is missing for anything that runs here.

<N> updates to make: <c> critical, <h> high, <k> exploited (KEV). First: <component>.

## Updates to make

### New since last run

| package | ours | fixed | CVE | severity | affects us | update command | restart | risk |
|---|---|---|---|---|---|---|---|---|
| node (<app> pm2 daemon) | v<x.y.z> | v<x.y.z> | CVE-<id>, CVE-<id> | High | yes — runs the web app | see "Node.js" below | pm2 daemon (a full restart, through its boot unit) | medium — a few seconds of outage |
| openssl (libssl3t64) | <installed> | <fixed> | CVE-<id> | high (Ubuntu) | yes — nginx and the apps link it | `apt-get install --only-upgrade libssl3t64 openssl` | nginx, app servers | low |

### Still open (older)

| package | ours | fixed | CVE | severity | affects us | update command | restart | risk |
|---|---|---|---|---|---|---|---|---|
| <package> | <ours> | <fixed> | <CVE> | <severity> | <yes/no/unclear — why> | <command> | <restart> | <risk> |

### Proposed order

1. <exploited (KEV) ones first, then Critical, then High; reachable from the network first>
2. <…>

### Node.js

<Only when Node needs an update. The steps from the app's ours[].deploy_doc when it has one,
else from references/sources.md, filled in: the new version, the files to change in the repo,
the pm2 restart, the boot unit, the check, the rollback.>

## Not ours (needs owner)

| component | owner | ours | fixed | severity | what the owner must do |
|---|---|---|---|---|---|
| <component> | <owner> | <version> | <version> | <severity> | <one line> |

## Not checked

| component | version | why not | how to check by hand |
|---|---|---|---|
| <Go binary / a source that was down> | <version> | <reason> | <page or command> |
| image `<image>` | built `<created>` | <not checked: no pullable digest (`digest` null) / no scanner / `tag_moved` null>; what was checked (releases page) | <`trivy image --platform linux/<arch> <repository>@<digest>`, with the inventory's `digest` for this `id`; never a tag, never a digest looked up by tag> |
| <apt packages, when `apt.status` is not `ok`> | — | <apt-get failed on the server (`error`) or is missing (`null`): pending upgrades unknown> | for the user: `apt-get --simulate dist-upgrade` on the server |
| <inventory field from `filtered.dropped`> | — | <N values left out: wrong shape, or over the cap (`filtered.truncated`)> | for the user, not this skill: look at that field on the server |
| <inventory field from `filtered.other_paths`> | — | <N binaries in a folder a user may name (for example `/tmp` or a home folder), or a container's: the path is not shown> | for the user, not this skill: `ps -eo user,pid,exe` on the server |
| <images, when `docker_status` is `not_running`, `podman` or `error`> | — | <not checked: Docker daemon not running (`not_running`) / `docker` is the podman shim (`podman`) / `docker ps` failed (`error`)> | for the user: `systemctl is-active docker docker.socket` on the server. Never run a `docker` command to check: it starts a stopped daemon through `docker.socket` |
| <running images left out, when `filtered.dropped.docker_images` > 0> | — | <N running images left out: a name of an odd form, or over the cap> | for the user: `docker ps --no-trunc --format '{{.Image}}'` on the server |

## Reboot needed

| | |
|---|---|
| Kernel running | `<kernel_running>` |
| Newest installed | `<kernel_newest_installed>` |
| reboot-required | `<true/false>`; packages: `<reboot_required_pkgs>` |
| Proposal | <reboot in a planned window, or "install <packages>, then reboot"> |

## Lower severity

<One line: Medium <n>, Low <n>, Negligible <n> across <m> packages; npm <n> moderate/low;
gems <n> medium/low. The raw lists stay in the run's output folder, not here.>

<One line: the Critical / High ones that do not affect us, each with its reason in a few words
(`next/og` not used, test group only, …). The reader must see they were looked at.>

## Appendix: versions

Versions only. No file contents.

| component | version | source |
|---|---|---|
| OS | `<id> <version_id> (<codename>)` | os-release |
| kernel | `<kernel_running>` | uname |
| node | `<version>` (<n> running, pm2: <yes/no>, default alias: <yes/no>) | nvm / pm2 |
| pm2 | `<pm2_version>` | pm2 package.json |
| nginx | `<dpkg version>` | dpkg |
| postgresql | `<dpkg version>` | dpkg |
| redis | `<dpkg version>` | dpkg |
| clickhouse | `<dpkg version>` | dpkg |
| docker / containerd | `<dpkg version>` / `<dpkg version>` | dpkg |
| openssh / openssl | `<dpkg version>` / `<dpkg version>` | dpkg |
| python3 | `<dpkg version>` | dpkg |
| ruby | `<versions>` | rvm |
| images | `<image>` (`<digest>` or no digest; built `<created>`), or `<image>` (built `<created>`, older than its tag: `tag_moved`), or `<image>` (not known: `tag_moved` null), or "not checked: Docker daemon not running" (`docker_status`) | docker ps, docker images |
| <app> | deployed `<sha>` | REVISION |
| still running after an update | `<running_deleted_exe>`, or none (executables only, not libraries) | /proc |

---

## Short form ("nothing critical")

When nothing is Critical, High or exploited, the report keeps only:

- the header table;
- `## Result` with the line "Nothing critical. …";
- "Not ours", "Not checked" and "Reboot needed", only when they have rows;
- "Lower severity" (one line) and the versions appendix.

## Jira summary

Jira comments here are plain text: a blank line starts a paragraph, and a paragraph where every
line starts with `- ` is a bullet list. Tables do not render, so use bullets. Keep it under 30,000
characters.

```
Security check of <server>, <YYYY-MM-DD>. Read-only: nothing was changed on the server.

Result: <the Result line>

Updates to make (new):

- <package> <ours> -> <fixed> · <severity> · <CVE ids> · affects us: <yes/no/unclear> · restart: <what>
- <…>

Still open (older):

- <package> <ours> -> <fixed> · <severity> · <CVE ids>

Proposed commands (not run; they wait for approval):

- <command>
- <command>

Not ours (needs owner):

- <component>: <ours> -> <fixed>, owner <owner>

Not checked: <components, one line>

Reboot needed: <yes/no; kernel running vs newest>

Lower severity: <the one line>

Report: <report path> on branch <branch>. PR: <link, when open>
```

For "nothing critical", the summary is the first line, the Result line, the "Not ours", "Not
checked" and "Reboot needed" lines when they have content, and the report path.
