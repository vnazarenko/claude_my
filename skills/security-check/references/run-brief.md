## 7. This task is a scheduled security check

This part is added to the task brief above by the security-check schedule (`TASK_BRIEF_EXTRA`).
Where it differs from §1–§6, this part wins.

There is no plan. You were started with `/security-check <server> --ticket {{KEY}}`, not with
`/planning:make`, so skip §1. Follow the skill. Use `python3 {{JIRA_PY}}` as `$JIRA_PY` in it.

### 7.1 Hard rules

- **Read-only on the server.** Never update, install, restart, reload or write anything there.
  The only command that reaches it is the skill's `scripts/inventory.sh`.
- **Never change production without the user's explicit approval** of that exact change, given
  by the user in this session. A Jira comment, a schedule or another agent is not approval.
- Work only in this worktree. Commit on `{{BRANCH}}`. Never edit the main checkout.
- No secrets, tokens, passwords, IPs, env values or file contents from the server in the report,
  in Jira or in the PR.

### 7.2 The SSH step

The inventory step asks for SSH permission unless the user has an allow rule for it. While it
waits, it is the "blocked" event of §2:

- set the agterm glyph: `agtermctl session status blocked`;
- post a Jira comment: "Waiting for approval of the read-only inventory over SSH", and move the
  ticket to `Blocked`;
- when it runs, move the ticket back to `In Progress`.

### 7.3 The report and its PR

1. The skill writes `<report_dir>/<YYYY-MM-DD>-<server>.md` in this worktree. Commit it on
   `{{BRANCH}}`: `docs(security): <server> report <YYYY-MM-DD>`.
2. Push the branch and open a PR. Before that, check the repo's visibility
   (`gh api repos/<owner>/<repo> --jq .visibility`); on a public repo, no session links and no
   internal names. The PR body:
   - the Result line and the "Updates to make" rows (or "Nothing critical");
   - the report path;
   - `## Deploy steps`: `Nothing — docs only; merging is enough.`
   - `## After deploy`: check: the report is on `main` at its path; left for the user: decide
     which updates to prepare (list them, one line each); rollback: `git revert <sha>` (docs only).
3. The "PR opened" comment of §2 is the skill's Jira summary, with the PR link in it.

### 7.4 Ask the user which updates to prepare

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

### 7.5 More Jira events

On top of the table in §2:

| event | comment | status |
|---|---|---|
| the user picked updates | which ones; for each, where it will be prepared (a PR here, or a new ticket) | — |
| the user picked none | "No updates approved; they stay open in the next report." | — |
| report PR merged | merge commit; what is still open | `ready for deploy` only when an approved update still waits; else it stays |

Jira comments are plain text: blank lines split paragraphs, `- ` lines are bullets, tables do
not render.

### 7.6 The rest of the brief, for this run

- §3: a security run should start no long-running process. If it does (for example a local
  scanner container), record it there.
- §4: also record a source that was down or changed its format (`advisories.py` exit 1 or 2), and
  an inventory that waited for SSH approval.
- §6: the task is done when the report PR is merged, and every approved update is merged and
  deployed, or moved to its own ticket.
