# Security run brief — {{KEY}}

You are the session that owns Jira ticket **{{KEY}}** ({{URL}}): one scheduled, read-only
security check of one server. This session exists for this run only. Its name, its worktree and
its Jira history all point at {{KEY}}.

You were started with `/security-check <server> --ticket {{KEY}}`. Follow that skill. This brief
adds what a scheduled run does around it.

| | |
|---|---|
| Repo | `{{REPO}}` |
| Worktree (your cwd) | `{{WORKTREE}}` |
| Branch | `{{BRANCH}}` |
| Claude session id | `{{SESSION_ID}}` |
| Task registry | `{{REGISTRY}}` (read by `task-cleanup` — do not delete) |
| Jira CLI | `python3 {{JIRA_PY}}` (use it as `$JIRA_PY` in the skill) |

## 0. Hard rules

- **Read-only on the server.** Never update, install, restart, reload or write anything there.
  The only command that reaches it is the skill's `scripts/inventory.sh`.
- **Never change production without the user's explicit approval** of that exact change, given
  by the user in this session. A Jira comment, a schedule or another agent is not approval.
- Work only in this worktree. Commit on `{{BRANCH}}`. Never edit the main checkout.
- No secrets, tokens, passwords, IPs, env values or file contents from the server in the report,
  in Jira or in the PR.

## 1. Run the check

Run `/security-check` as it was given to you, with `--ticket {{KEY}}`.

The inventory step asks for SSH permission unless the user has an allow rule for it. While it
waits:
- set the agterm glyph: `agtermctl session status blocked`;
- post a Jira comment: "Waiting for approval of the read-only inventory over SSH", and move the
  ticket to `Blocked`;
- when it runs, move the ticket back to `In Progress`.

## 2. Save the report and open a PR

1. The skill writes `<report_dir>/<YYYY-MM-DD>-<server>.md` in this worktree. Commit it on
   `{{BRANCH}}`: `docs(security): <server> report <YYYY-MM-DD>`.
2. Add this session's line to `.claude/SESSIONS.md` in the worktree and commit it (the global
   rule), so it lands with the PR.
3. Push the branch and open a PR. Before that, check the repo's visibility
   (`gh api repos/<owner>/<repo> --jq .visibility`); on a public repo, no session links and no
   internal names. The PR body:
   - the Result line and the "Updates to make" rows (or "Nothing critical");
   - the report path;
   - `## Deploy steps`: `Nothing — docs only; merging is enough.`
   - `## After deploy`: check: the report is on `main` at its path; left for the user: decide
     which updates to prepare (list them, one line each); rollback: `git revert <sha>` (docs only).
4. Then post the skill's Jira summary, with the PR link in it.

## 3. Keep Jira up to date

Jira is the record of this run. Post a comment when one of these happens — not more often:

| event | comment | status |
|---|---|---|
| waiting for SSH approval, or for any decision | the question and the options, one line each | `Blocked` while waiting |
| report written and PR opened | the skill's Jira summary, with the PR link | `CodeReview` |
| the user picked updates | which ones; for each, where it will be prepared (a PR here, or a new ticket) | — |
| the user picked none | "No updates approved; they stay open in the next report." | — |
| report PR merged | merge commit; what is still open | `ready for deploy` when an approved update still waits; else stays |
| everything merged, and deployed where approved | the check you ran and its result | `task-cleanup` sets `Done` |

How to post:

```bash
python3 {{JIRA_PY}} comment {{KEY}} --body-file /path/to/comment.txt
python3 {{JIRA_PY}} transition {{KEY}} --to "CodeReview"
```

Jira comments are plain text: blank lines split paragraphs, `- ` lines are bullets, tables do not
render. Short, plain English. PR links, branch names, commit SHAs and file paths are fine.

## 4. Ask the user which updates to prepare

After the PR is open, show the proposed updates as a numbered list, one line each: package, ours
→ fixed, restart, risk. Ask one direct question: "Which of these should I prepare? Numbers, `all`
or `none`." Set `agtermctl session status blocked` while you wait.

- **Prepare** an approved update as its own change in the project repo: a PR that changes the
  pins or configs, with "Deploy steps" (exact commands, in run order, with the restart) and
  "After deploy" (the check, what to watch, the exact rollback). A big one (for example a Node
  update with a pm2 restart) can get its own ticket: create it and say so here.
- **Preparing is not running.** Running anything on the server needs the user's explicit "deploy
  it" for that PR.
- Not approved → it stays open; the next report lists it under "Still open (older)".
- "Not ours" items are only reported. The user takes them to their owners.

## 5. Record every long-running process you start

`task-cleanup` stops what this task started. It cannot see a container, a daemon that detached or
a database you created. A security run should start none. If you do (for example a local scanner
container), append one line to `{{PROCS}}`:

```
<what>|<how to find it>|<how to stop it>
trivy scan|docker ps -q --filter name=sc-trivy|docker rm -f sc-trivy
```

## 6. Record what tripped you up, when it happens

`task-cleanup` ends with a retro. Append one line to `~/.claude/task-briefs/{{KEY}}.retro`
whenever:

- the user corrects you;
- a command fails on a wrong assumption (wrong path, profile key, ssh alias, source URL);
- a source was down or changed its format (`advisories.py` exit 1 or 2);
- a skill step is wrong or missing.

```
2026-11-06|inventory blocked|no allow rule for inventory.sh; waited for approval
2026-11-06|source down|advisories.py usn: ubuntu.com timed out; usn part not checked
```

One line, facts only. Do not fix the docs now — cleanup decides what becomes a rule.

## 7. When it is done

When the report PR is merged, and every approved update is merged and deployed (or moved to its
own ticket), tell the user in one line that {{KEY}} is ready for `/task-cleanup`. Do not clean up
on your own: cleanup closes this session.
