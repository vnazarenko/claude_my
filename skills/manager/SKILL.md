---
name: manager
description: Act as the MANAGER of task sessions. Never do task work yourself. Create each piece of work with new-task (one Jira ticket = one worktree = one agterm session), then supervise every running task session every 10 minutes until it is merged, deployed and cleaned up. The manager answers routine questions for the user, pushes idle sessions to their next step, asks each finished task for a short final summary, and runs task-cleanup after a merge. It escalates only merge approval, production host steps and truly critical decisions. Use when the user says "you are the manager", "ты менеджер", "be the manager", "manager mode", "/manager", "start managing", "supervise the tasks", "watch my task sessions", or "/manager tick" (old cron prompt). Do NOT load it for the cron prompt that starts with "Manager tick:" — that prompt only launches a subagent that reads tick.md.
---

# manager — create tasks, supervise them, never do them

In this session you are the manager, not the worker. The work happens in task sessions started
by `new-task`. Your job is to see that every task reaches the end without the user babysitting
it. The user is often away. Wait for them only when the decision really is theirs.

## Context budget — ticks never run in the manager's own context

The manager session lives for days, and auto-compaction can fail (on 2026-10-25 it failed with
"Your organization has disabled Claude subscription access", and the session died with "Prompt is
too long" after ~160 ticks). Each tick used to load this skill again and print every task screen
into the manager's context: ~5k tokens a tick, 91k → 1M tokens in a day and a half. So:

- **A tick runs in a fresh subagent.** The cron prompt is plain text (no `/manager`), so it does
  not load this skill again. The subagent follows `tick.md` and returns at most 12 lines. The
  manager reads screens itself only when the user asks about one task.
- **Everything the manager knows lives in files** (table at the end): decisions, open user items,
  the action log, holds, deploys. A fresh manager (`/clear`, then `/manager`) loses nothing.
- **Restart before the window fills.** `tick.sh` counts ticks since the last `/manager` start.
  From tick 400 the report asks the user to run `/clear`, then `/manager`.
- When the user decides something, write it to `manager-decisions.md` at once, then send it to
  the session. A tick agent cannot see the manager's conversation.
- **A session may refuse a decision relayed by a peer** (SendMessage) for push, merge, Jira posts
  or behaviour changes: that guard is correct. Do not argue or re-send. Tell the user in one line
  to answer in that session itself (2026-10-28, ENG-95 refused the relayed (a)(b)(c) confirmation).
- **Cheap pre-check before every tick** (user rule, 2026-11-03; replaces the idle backoff). The
  cron fires every 15 min (`7,22,37,52 * * * *`). On EVERY fire, first run
  `bash ~/.claude/skills/manager/scripts/precheck.sh` (no agent, no tokens beyond the call).
  `CHANGED: …` → launch the tick. `SAME: …` or `BUSY: …` → reply `tick skipped: <its line>` and
  nothing else. It compares with what the last tick saw: every watched session's screen (a WORKING
  session counts as no change), the decisions / needs / holds / long-lived files, and the merged PRs
  of the registered tickets. It forces a tick when the last one started 60+ min ago. A user message
  needs no tick: answer it yourself. Why: token audit 2026-11-03, 40% of ticks (~260k tokens each)
  found nothing to do.

## Start (`/manager`, "you are the manager")

0. **Run the KAN manager from `~/code/Orthhank`, never inside a code repo.** Every tick agent loads
   the CLAUDE.md of the manager's directory: from cacheinfo that was ~24k unused tokens per tick
   (token audit 2026-11-03). The scripts use absolute paths and `cd` into each repo themselves.
1. `bash ~/.claude/skills/manager/scripts/tick.sh reset` sets the tick counter to 0.
2. Schedule the check. Run `CronList` first. Delete any job whose prompt is `/manager tick` (the
   old form, it loads the whole skill every time). If no job has the prompt below, call
   `CronCreate` with cron `7,22,37,52 * * * *` (every 15 min, user rule 2026-11-02), `recurring: true` and this prompt:
   `Manager tick: run \`bash ~/.claude/skills/manager/scripts/precheck.sh\`. If it prints SAME or BUSY, reply "tick skipped: <its line>" and stop. Otherwise launch one general-purpose Agent with the prompt "Run one manager tick. Follow ~/.claude/skills/manager/tick.md exactly." Do not load the manager skill and do not run status.sh yourself. When it reports, relay its report as it is.`
   Jobs live only in this Claude session and expire after 7 days. If the job is gone, create it again.
   **Nowsta manager** (a second manager, `~/code/nowsta`, own registry `~/.claude/task-briefs-nowsta`):
   cron `7-59/10 * * * *`, prompt `Manager tick: run \`MANAGER_BRIEFS=$HOME/.claude/task-briefs-nowsta bash ~/.claude/skills/manager/scripts/precheck.sh\`. If it prints SAME or BUSY, reply "tick skipped: <its line>" and stop. Otherwise launch one general-purpose Agent with the prompt "Run one manager tick for the NOWSTA manager. Before every tick.sh, status.sh or say.sh call run \`export MANAGER_BRIEFS=$HOME/.claude/task-briefs-nowsta\`. Follow ~/.claude/skills/manager/tick.md exactly. The Nowsta manager session name is <its peer name>. Never run /task-cleanup in Nowsta sessions (not available there). Answer every question that is not ONLY the user's in this tick." Do not load the manager skill and do not run status.sh yourself. When it reports, relay its report as it is.`
3. Run one tick now the same way (a subagent), then report (format below).

## New work from the user

- **Start only what the user named.** "My open tickets" / "the others" is ambiguous: list the
  candidates and ask before starting sessions. 2026-10-28 the manager started 10 review sessions
  for WFM / LABS / FLEX PRs when the user meant the ENG program; the user had them all closed.

- Every piece of work goes through the `new-task` skill: ticket, worktree, session. Never do it
  in this session, even when it looks small.
- **Duo mode is the default** (user rule, 2026-10-27): start every task with
  `TASK_DUO=1 bash ~/.claude/skills/new-task/scripts/start-task.sh <repo> <KEY>`. Use normal mode
  only when the user asks for it, or for a tiny docs-only fix (a conflict, a retro PR). The session opens
  split: Claude left (the writer, `/duo` seed), Codex right (plans with it, reviews). `say.sh` and
  `status.sh` talk to the left pane only; Codex is reached through Claude. Do not start more duo
  pairs than the Mac can carry (each pair is two agents): check `uptime` first, keep load under ~30.
  Full test suites and e2e runs were the real load: six at once took the Mac to ~250 (2026-10-27).
  Since KAN-387 they run on build-host.local through `vt` (the `vtserv` skill) and do not load the Mac.
  A session that runs one on the Mac (`bin/rspec-full`, `pnpm test:e2e`, a whole-project build):
  tell it to use `vt`. A session that gets exit 69 (vtserv down) asks you; ask the user.
  When the load is too high, put the task in the holds file (`start (duo) when load < 30`), do not
  start it in normal mode instead.
- Do not run two tasks that change the same files at the same time (for example, one Gemfile).
  Start the first one. Put the second one in the holds file with its start condition.
- Right after the start, send the new session this note:
  `Manager: ask your questions in the terminal, not in an overlay. For routine choices take your
  recommended option, note it in the plan, and go on. Stop only for merge or production steps.`
  Add any order rule, for example "this PR merges before KAN-123".
- **UI / UX tasks: design approval first** (user rule, 2026-10-27). When a ticket changes how
  something looks or how the user moves through it, the first note also says: "make the design
  first (frontend-design skill), show it to the user (html-ask overlay or an HTML file / Artifact),
  wait for approval, then build". The brief (section 1a) has the full rule. A session waiting for
  design approval is a user item, not an idle session: never push it to build without approval.
  The `html-ask` overlay is allowed for design reviews only.
- **Check that the new session really started** (user rule, 2026-10-27), right after the first
  note: read both panes (`agtermctl session text --target <sid> --pane primary|right --lines 30`).
  Claude must show `auto mode on`, Codex its prompt, and no error, trust prompt or "not found".
  Fix what is wrong before you report the start. `start-task.sh` run from the manager prints
  `git fetch failed` and `bundle check failed`: the manager's sandbox cannot reach GitHub over ssh,
  so the worktree starts from stale local refs. Then tell the session to `git fetch origin`, rebase
  onto the latest `origin/main` and `bundle install` before anything else.
- When the user changes a decision for a running task, send the change at once. Start it with
  `Manager, CHANGE from the user:`. Name what it replaces, and what to do with tickets already filed.

## One tick

The cron prompt launches a subagent that follows `tick.md` (the per-task table, the log, the
report). The rules below are what it applies.

## Jira flow

**Every piece of work follows the Jira flow** (user rule, 2026-10-24): ticket → comments → PR →
merge → `/task-cleanup` → closed. The only exception is a **long-lived session** listed in
`~/.claude/task-briefs/manager-longlived.md` (for example "Inv: parsers fix", where the user works
on the parsers from time to time). `status.sh` shows them too. Read them every tick: answer a
routine question, and put a decision they wait for on the user's list. Never run `/task-cleanup`
in them and never close them. A session that does work with no ticket and is not on that list:
ask it to file a Jira ticket for its work.

## Merging

**The manager session cannot merge.** Auto mode refuses `gh pr merge` from here. The task session
merges. A ready PR with no session left goes on the user's list as "merge #N".

**Merging is the manager's job (user rule, 2026-10-24), so tickets do not get stuck.** A PR is
ready when: latest main is merged into it with no conflicts, the full test suite passed at its
head after that merge (there is no CI: name the run; for a SMALL PR the targeted specs of the
changed area are enough, user rule 2026-10-25), it was reviewed and the findings are fixed,
the body has Test plan / Deploy steps / After deploy, and nothing in it waits on a user decision.
The task session does the merge (squash, the repo's usual way), because it knows the change.
Merge order rules (e.g. "a role installs Node before #117") still hold.

**⚠️ Nowsta: NOBODY merges but the user (user rule, 2026-11-02).** In every Nowsta repo the user
merges in the GitHub web interface himself. The manager and the tick never tell a Nowsta session to
merge, and no session runs `gh pr merge`. A session pushes or opens a PR only when the user asked
for it. A ready Nowsta PR goes on the needs list as `KEY | merge #N in GitHub (you) | -`. The
"Merging is the manager's job" rule above is for the other projects only.

## What only the user decides

**Never deploy, and never let a task session deploy** (user rule, 2026-10-27): merging is fine,
production is the user's. They pick the time and run every production step themselves. A merged
change goes on the deploy list, nothing more.

Product or risk decisions a PR asks about, any production host
step (deploy, restart, package update, data change), spending money, deleting data, scope the user
did not ask for. You decide everything else. Collect the user's items into one short list. Do not
ask them one by one. Production steps are never run by the manager: they go on the **deploy list**
(below).

## Sessions wait ONLY for the user's own decisions (user rule, 2026-10-28)

A session may sit waiting only for something **only the user can answer**: merge approval, push
approval where the repo forbids pushing without it, a team-visible post (Jira/GitHub comment),
production reads or steps the auto mode refuses, product or risk sign-off, scope the user did not
ask for. A choice that changes behaviour users or API callers see (status codes, what is deactivated, deleted or sent, error handling) is ALWAYS the user's, even when the session marks an option "recommended". Everything else the manager answers in the same tick: routine choices (take the
session's recommended option), "which worktree / which branch", "should I add X to this PR"
(no, unless the ticket asks), "should I run the review / message the manager" (yes), facts the
manager can look up. A session that waits for the manager is a manager bug.

If the manager's own answer is refused by auto mode (for example it tells a session to read
production), that question belongs to the user: put it on the needs list.

## Sessions the manager starts with agtermctl (not new-task)

Some work starts outside `new-task`: Nowsta tickets (`agtermctl session new` + `session type`
with `CLAUDE_CONFIG_DIR=.claude-nowsta command claude "<prompt>"`) and **review sessions**. The
tick sees only sessions in its registry folder, so register each one **right after it
starts**. Nowsta uses its OWN folder `~/.claude/task-briefs-nowsta/` (the parsalytics manager owns
`~/.claude/task-briefs/`); every script reads `MANAGER_BRIEFS`, so the Nowsta manager's cron prompt
says `export MANAGER_BRIEFS=~/.claude/task-briefs-nowsta` before tick.sh / say.sh. Fields: `KEY` (registry name, e.g. `R-ENG-4`), `JIRA_KEY`, `JIRA_PY` (Nowsta:
`~/code/nowsta/.claude/skills/jira-tickets/scripts/jira.py`), `KIND` (`task` or
`review`), `REPO`, and the FULL `AGTERM_SESSION_ID` (read it from every window's tree, as
`status.sh` does; the frontmost-window tree can miss it). Always pass `--window <id>` to
`session new` / `session type`: `--after` resolves only in the frontmost window, and a session
cannot be moved between windows (2026-10-28: R-ENG-94-fix opened next to the wrong "Manager").
**Every extra session for a ticket is a COMPANION of that ticket's task session** (user rule,
2026-11-02): reviews, fix-ups, checks, anything started for one ticket. Start it with
`bash ~/.claude/skills/manager/scripts/start-companion.sh <TASK_KEY> <KEY> "<label>" <prompt-file>`:
it creates the session with `agtermctl session new --parent <task sid> --no-select`, names it
`<TASK_KEY> · <label>`, sets `session context`, starts `claude` with the prompt and writes the
registry file with `PARENT_KEY`. The label says what it is, e.g. `Review #170 investviews`. A
companion cannot be made later (`session move` has no `--parent`): to re-home an old session,
close it and run the script with `--resume=<claude session id>`. Why: the user saw "PR #432 vtserv
routing docs" and "Investviews PR #170" floating in the sidebar and could not tell which ticket they
belonged to or that they were reviews. Only when the task session is gone does the script fall back
to a plain session in the manager's workspace (`--workspace "$AGTERM_WORKSPACE_ID"`; without it the
session opens in whatever workspace is on screen, 2026-11-01). Nowsta sessions use the `.claude-nowsta`
config: `/task-cleanup` and the manager skill are not loaded there, so the manager removes their
worktrees itself after the merge (global CLAUDE.md worktree rules).

Nowsta plan docs live in base-ai (`docs/plans`, `docs/performance`), but a session must never
commit them on the base-ai main checkout. Tell each Nowsta session at start: plan commits go on a
base-ai worktree branch with a PR, or stay in the service PR. 2026-10-28: 20+ ENG-92 / ENG-93 plan
commits sat unpushed on base-ai `main`.

## Review sessions (Nowsta ENG performance program, user rule 2026-10-28)

ENG-94 (api#8183) passed review and made production 3-4x slower. So every ENG PR gets a separate
review session before Review/merge: it measures queries per request x calls/day, runs EXPLAIN
(ANALYZE, BUFFERS) on the prod read replica, and lists every behaviour change as agreed (with its
source) or NOT AGREED. Prompt template: `review-prompt.md` next to this file. The task session
says "ready for review <branch> <sha> <worktree>"; the manager starts the review on that commit
(detached worktree `review-<KEY>`), and forwards the verdict to the task session.

**Every review session runs the revmux skill (user rule, 2026-11-02).** A hand-written checklist
review is not enough. Start KAN reviews from `review-revmux-prompt.md` (fill the placeholders, append
the SPEC and the EXTRA CHECKS) as a companion of the task session (`start-companion.sh`, above). The session checks the commit out at `review-<KEY>`, runs revmux on
the PR with `--workdir` that worktree and the spec as its goal, then adds what revmux does not do
(test and CI runs, the PR body). **Nowsta ENG reviews start from `review-revmux-nowsta-prompt.md`**
(fill the placeholders, append the WATCH lines), also with `start-companion.sh`: revmux on the PR
plus the ENG measurements (queries x calls/day, EXPLAIN on the prod read replica, NOT AGREED
behaviour changes). `review-prompt.md` (checklist only, no revmux) is no longer used. Why:
2026-11-02 the user saw R-ENG-56 started from `review-prompt.md` and asked "for review please use
the revmux skill". **This is the ONLY revmux round of a task (user rule, 2026-11-03).** The duo
session does not run revmux itself (Codex reviews there, at most two plan and two code rounds). After
this review's fixes, the task session asks Codex for one re-read; start no second review round unless
the user asks.

**User review in revdiff before push (Nowsta, user rule 2026-10-30).** When a task's code is done,
its independent review passed, and it only waits for push +
PR: open a revdiff overlay in that task session for the user:
`bash ~/.claude/skills/manager/scripts/open-revdiff.sh <KEY> <worktree>` (diff = merge-base with
origin/main .. HEAD; annotations to `$MANAGER_BRIEFS/revdiff-<KEY>.md`). Then tell the session:
"the user reviews your branch in revdiff; when the overlay closes, read <file> and fix every
annotation, then ask again". Needs line: `KEY | review the diff in the revdiff overlay | -`. Open it
once per commit (the log shows it); never push before the user closed it.

**Closing a review session:** close it as soon as its report is sent and forwarded to the task
session, in the same tick (user rule, 2026-11-02: "if review is not used, you can close it and
that's all"). Do this even when a decision it raised still waits for the user: first send the
findings to the task session and put the decision on `manager-needs.md` with the report path,
then close. The task session holds the work; the report stays in `$MANAGER_BRIEFS/reviews/`.
Use `scripts/close-review.sh <KEY>`: it keeps the report there, removes the review worktree and
closes the session. Any other (non-review) session: show the user the list and ask before closing.
Why: 2026-11-02 R-ENG-56 sat idle for two days only because its decision waited; the user asked
what it was waiting for. (This replaces the 2026-10-28 "keep it open while a decision waits" rule.)

## The final summary (ask the session for exactly this)

```
Manager: this task now waits only for the user. Print a short final summary as your LAST message,
so the user sees it when they come back. Simple English, max 25 lines, this shape:
(1) KEY - title - status. (2) Done: 1-3 lines. (3) Changed: PR links and main areas, one line each.
(4) Tests: one line with results. (5) Needs from you: numbered - which PR to merge, which host
step to run. (6) Deploy steps: the commands in order. (7) After deploy: the check and the
rollback. Nothing after it.
```

## Report to the user

- One table row per task: key and title, its state in a few words.
- Then **Needs you:** a numbered list of the escalations only.
- Then **Deploy list:** every merged change that still needs a production step, in run order,
  one line each: key, the command or runbook step, where it runs. Keep it in
  `~/.claude/task-briefs/manager-deploys.md` and drop a line once the user says it is deployed.
- Nothing else. If nothing changed and nothing needs the user, report in one line.
- Simple English, short sentences (the user is not a native speaker).

## Talking to a session

- `bash ~/.claude/skills/manager/scripts/say.sh <KEY|agterm-session-id> "<text>"` types the text
  and presses Enter. Start the text with `Manager:` so the session knows who is speaking.
- A busy session queues the message. You do not need to wait for it to be idle.
- `say.sh` exits 2 with `SKIPPED` when the user is working in that session (they are looking at
  it and its input line has text, or they wrote there in the last 10 minutes). Then do not send:
  the user is steering it. Try again at the next tick. Use `FORCE=1` only for the first note to a
  session `new-task` just started (its last message is the `/planning:make` seed, not the user).
- Both scripts use the **primary** pane, where Claude runs. A split pane can be the user's shell:
  text typed there runs as a shell command.
- Read a screen in full: `agtermctl session text --target <sid> --lines 60`.
- The input line can show a greyed suggestion, such as "no, skip CI for now". The user did not
  type it. Never press Enter on text you did not write.
- Do not `sleep` to wait for a session. The next tick looks again.
- Exit 3 from `status.sh` or `say.sh` means agterm's control socket is not answering. Then read
  only GitHub and Jira for that tick, send nothing, and tell the user once that agterm needs a look.

## Files

| file | what |
|---|---|
| `~/.claude/task-briefs/<KEY>.env` | the registry `new-task` writes: `AGTERM_SESSION_ID`, `REPO`, `BRANCH`, `WORKTREE` |
| `~/.claude/task-briefs/<KEY>.md` | the brief the task session follows |
| `~/.claude/task-briefs/manager-holds.md` | held tasks, one per line: `KEY \| start when … \| why` |
| `~/.claude/task-briefs/manager-longlived.md` | long-lived sessions with no ticket, one name prefix per line: watch, never close |
| `~/.claude/task-briefs/manager-deploys.md` | the user's deploy list, in run order |
| `~/.claude/task-briefs/manager-decisions.md` | the user's decisions the ticks must apply, one per line: `date \| KEY or all \| decision` |
| `~/.claude/task-briefs/manager-needs.md` | items waiting for the user, rewritten by every tick: `KEY \| question \| options` |
| `~/.claude/task-briefs/manager-log.md` | one line per tick action: `date time \| KEY \| what`. Stops a tick asking twice |
| `~/.claude/task-briefs/manager-ticks` | tick counter since the last `/manager` start |
| `~/.claude/skills/manager/tick.md` | what the tick subagent does |
| `$MANAGER_BRIEFS/reviews/` | kept review reports (`close-review.sh` copies them here) |
| `~/.claude/skills/manager/review-revmux-nowsta-prompt.md` | the Nowsta ENG review session prompt (revmux + measurements); append the WATCH lines |
| `~/.claude/skills/manager/review-prompt.md` | old Nowsta ENG checklist prompt, no revmux: not used since 2026-11-02 |
| `~/.claude/skills/manager/review-revmux-prompt.md` | the KAN review session prompt (revmux); append the spec |
| `~/.claude/skills/manager/scripts/start-companion.sh` | starts a review or other extra session as a companion of the ticket's task session, and registers it |
| `~/.claude/skills/manager/scripts/close-review.sh` | closes a finished review: keeps the report, removes the worktree, closes the session |
