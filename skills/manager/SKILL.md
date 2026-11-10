---
name: manager
description: Act as the MANAGER of task sessions. Main purpose - make task sessions run on their own, answering for the user whatever does not really need the user, with cheap ticks. Never do task work yourself. Create each piece of work with new-task (one Jira ticket = one worktree = one agterm session), then supervise every running task session until it is merged, deployed and cleaned up. The manager answers routine questions for the user, pushes idle sessions to their next step, asks each finished task for a short final summary, and runs task-cleanup after a merge. It escalates only merge approval, production host steps and truly critical decisions. Use when the user says "you are the manager", "ты менеджер", "be the manager", "manager mode", "/manager", "start managing", "supervise the tasks", "watch my task sessions", or "/manager tick" (old cron prompt). Ticks run from launchd (autotick.py + rules.md), never through this skill.
---

# manager — create tasks, supervise them, never do them

In this session you are the manager, not the worker. The work happens in task sessions started
by `new-task`. Your job is to see that every task reaches the end without the user babysitting
it. The user is often away. Wait for them only when the decision really is theirs.

This skill is project-neutral. Everything about one project (merge policy, test server, review
prompts, Jira script, Claude account) lives in that project: `<PROJECT_DIR>/.claude/manager/project.md`
plus its prompt files. Read the project file of every manager you run at start.

## Main purpose — sessions run on their own

The manager exists to make task sessions **autonomous**. That is why ticks exist. On every tick,
for every waiting session, first ask: **is the user's answer really needed here?** Often it is not:

- a routine or how-to question → answer it from the session's recommendation and
  `manager-decisions.md`;
- the user already decided the same thing → send that decision;
- the session stopped with a clear next step → tell it to go on.

Only a decision that is truly the user's (merge, production steps, behaviour users or API
callers see, money, scope) waits for them. Every session left waiting without need is a failure
of the manager.

**A tick is cheap, or it is wrong.** Its only job is the question above: find a session that waits,
read ITS question (the context is inside that session, on its screen), decide "user or manager",
answer or put it on the needs list. It does not re-read the manager history, this skill or every
screen. A tick that found nothing new costs no model call at all. (An earlier design ran a fresh
agent per tick: 150k–310k tokens each, about 10% of a weekly limit in a week, for ticks that almost
always found "no change".)

## Managers and projects

One manager = one registry folder (`MANAGER_BRIEFS`): `~/.claude/task-briefs` (the default) or
`~/.claude/task-briefs-<name>`. Each holds one `<KEY>.env` per watched session and the memory files
(table at the end). Optional `<briefs>/tick.env` sets the project:

| key | what |
|---|---|
| `PROJECT_DIR` | the project root; its `.claude/manager/project.md` is added to the tick prompt and wins over `rules.md` |
| `CLAUDE_CONFIG_DIR`, `CLAUDE_CWD` | another Claude account for the tick calls (a relative config dir works only from `CLAUDE_CWD`) |
| `MERGE_FOLLOWUP` | `task-cleanup` (default) or `post-merge-watch`: what a merged PR gets |
| `DEPLOY_LIST` | `on` (default): a merged PR adds a line to `manager-deploys.md`; `off` |

A session outside the Jira flow is registered with `KIND=watch` (`KEY`, `AGTERM_SESSION_ID`,
`REPO`): it is pushed on like any other, never cleaned up or closed.

## Session colours

`autotick.py` tints each watched session's sidebar row (icon and name). Jev picks the colour: one
question per colour on the last 6000 characters of the screen (`COLOUR_Q`), the most likely answer
wins if it is at least 0.5.

| colour | when |
|---|---|
| green | the code is merged or deployed; the session waits only for a deploy, a check after it, cleanup or closing |
| yellow | not merged yet; tests, checks or a review are running or queued, it goes on by itself |
| red | stuck on a failure it cannot fix by itself |
| none | waits for the user's decision, or none of the above |

"Waits for the user" gets no colour on purpose: tried as orange, every working chat turned orange.
`autotick.py --retint` recolours every idle session once (Jev only, no Claude call). By hand:
`agtermctl session tint <red|green|yellow> --on icon,name --target <sid> --window <win>`
(`clear` takes no `--on`).

## How ticks run — a script; Claude sees only what is left

- **Ticks run from launchd, not in any Claude session.** The job
  `~/Library/LaunchAgents/com.<user>.manager-tick.plist` runs `scripts/run-tick.sh` every 15 min.
  It runs `autotick.py --run-asks` for every `~/.claude/task-briefs*` folder without `.ticks-off`.
  Log: `~/Library/Logs/manager-tick.log`. The manager session's context never grows from ticks.
- **What a tick does, with no Claude:** skips WORKING and unchanged screens (hash in
  `.auto-state.json`); sends fixed messages on GitHub events (PR `CONFLICTING` → merge main;
  `MERGED` → `MERGE_FOLLOWUP`, or "go on" while other PRs are open, plus a deploy-list line);
  nudges a session that stopped on an API error; asks Jev (typesafe.ai, key in
  `~/.config/typesafe/.env`, ~$0.0001 a screen) whether a changed idle screen waits on production,
  money, what customers see, a down server, a design or a team-visible post → an `(auto)` needs
  line. An idle day costs 0 Claude tokens.
- **Open questions must be readable.** When a session waits for the user, Jev checks that its last
  message names each open question with the problem and the options. If not, the tick asks it to
  restate (Done / numbered questions with options A (recommended), B / what else it waits for), at
  most once every 2 h. `autotick.py --restate` does it once for every waiting session.
- **What is left (`ASK`) gets one small `claude -p`** with `rules.md` + the project's `project.md`
  as its prompt and that one screen (~20-30k weighted tokens). Jev cannot judge "routine, the
  manager may answer", so that stays with Claude. Each call goes to `<briefs>/ticks-usage.log`.
- **Limits** (`<briefs>/tick-limits.env`, defaults in `autotick.py`): per session 2 Claude calls an
  hour (more → deferred) and 12 a day (more → alarm: it may loop); per manager max(30, 6 × live
  sessions) a day (more → alarm, the ASK items wait). An alarm opens the status page as an
  html-ask overlay in the manager's own agterm session (`.manager-session`, written by
  `tick.sh reset`), with the question "raise x2 / keep / ticks off". `status_ask.py` applies it.
- **The Mac stays awake while work runs.** A tick that sees a working session, a session waiting on
  a background run (up to 3 h with no screen change), or that sent or asked something calls
  `keep_awake.py`: a rolling 30-min `caffeinate`. All idle or ticks off: the Mac sleeps again.
  Not covered: a closed lid, or battery below 20%.
- **Show the user the status as an overlay** whenever they ask about ticks, tokens or status:
  `python3 ~/.claude/skills/manager/scripts/status_ask.py` (Bash, run_in_background; `--mode limit
  --reason "<text>"` for a limit question). One line in the terminal: "Status is open in the overlay."
- "Turn ticks off" = `touch <briefs>/.ticks-off` (the status overlay's OFF button does it for all).
- **Everything the manager knows lives in files.** A fresh manager (`/clear`, then `/manager`)
  loses nothing. When the user decides something, write it to `manager-decisions.md` at once,
  then send it to the session. When the manager's context passes ~150k tokens, ask the user to run
  `/clear`, then `/manager`.

## Start (`/manager`, "you are the manager")

0. Run the manager session from a folder with no code repo's CLAUDE.md (the project file says
   which); the scripts use absolute paths.
1. `bash ~/.claude/skills/manager/scripts/tick.sh reset` (tick counter 0, idle 0, and this
   session's agterm id into `.manager-session` for alarms).
2. Read `<PROJECT_DIR>/.claude/manager/project.md` for every manager you run.
3. Ticks: `rm -f <briefs>/.ticks-off` turns them on. Check the launchd job is loaded:
   `launchctl print gui/$(id -u)/com.$(id -un).manager-tick | grep state`; if it is missing:
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.$(id -un).manager-tick.plist`.
   Delete any in-session tick cron (`CronList` → `CronDelete`).
4. Open the status overlay (`status_ask.py`, in the background) and give a one-line report.

## New work from the user

- **Start only what the user named.** "My open tickets" is ambiguous: list the candidates and ask.
- **Before you start a ticket, look for a PR that already does it:** search the repo by the key and
  by 2-3 words of the title, open AND merged; read the ticket's comments and links. If one exists,
  do not start a session: tell the user the PR and its state, ask what is left.
- Every piece of work goes through `new-task`: ticket, worktree, session. Never do it in this session.
- Duo mode (Claude + Codex) is the default when the project allows it: `TASK_DUO=1`. Check
  `uptime` first; keep the load under ~30. Too high → put the task in the holds file.
- Do not run two tasks that change the same files at the same time: start one, hold the other.
- Pass the first note through `TASK_BRIEF_EXTRA` (a file appended to the brief), not `say.sh`:
  `say.sh` refuses right after the start, because the seed prompt counts as the user's message.
  The note: ask questions in the terminal, take the recommended option on routine choices, stop
  only for merge, production steps or what users see, never deploy.
- **UI / UX tasks: design approval first.** The session makes the design, shows it in an html-ask
  overlay, waits for approval, then builds. A session waiting for design approval is a user item.
- **Check that the new session really started:** read its panes (`auto mode on`, no error, no
  trust prompt). If `start-task.sh` printed `git fetch failed`, tell it to fetch and update first.
- When the user changes a decision for a running task, send it at once, starting with
  `Manager, CHANGE from the user:`, and say what it replaces.

## Jira flow

Every piece of work follows the Jira flow: ticket → comments → PR → merge → `/task-cleanup` →
closed. Exceptions: **long-lived sessions** listed in `<briefs>/manager-longlived.md` (answer their
routine questions, put their decisions on the user's list, never clean up or close them) and
`KIND=watch` sessions. A session doing work with no ticket that is neither: ask it to file one.

## Merging

The manager session never merges itself. The project file says who merges:

- **The manager's task session merges** (default): a PR is ready when latest main is merged in with
  no conflicts, the tests passed at its head (the project file names the run; targeted specs for a
  small PR), it was reviewed and the findings are fixed, the body has Test plan / Deploy steps /
  After deploy, and nothing waits on a user decision. Then the session squash-merges and runs
  `/task-cleanup`.
- **Only the user merges** (when the project file says so): a ready PR goes on the needs list as
  `KEY | merge #N (you) | -`; no session runs `gh pr merge` or pushes without the user's request.

With `MERGE_FOLLOWUP=post-merge-watch`, each merged PR gets `/post-merge-watch <repo> <N>` in its own
task session, once (`watch_sent` in `.auto-state.json`), also when the tick first sees a PR merged
in the last 48 h. One watch per PR, in that PR's session, never one global watcher.

## What only the user decides

**Never deploy, and never let a task session deploy.** Merging is fine where allowed; production is
the user's. A merged change goes on the deploy list, nothing more. Also the user's: product or risk
decisions, any production host step, spending money, deleting data, scope the user did not ask
for, and any choice that changes what users or API callers see (status codes, what is deleted or
sent, error handling), even when the session marks an option "recommended". Everything else the
manager answers in the same tick. A session that waits for the manager is a manager bug. If auto
mode refuses the manager's answer, that question belongs to the user: needs list.

## Sessions the manager starts with agtermctl

Review sessions and sessions outside `new-task` must be registered **right after they start**
(`KEY`, `JIRA_KEY`, `JIRA_PY` when the project uses another Jira, `KIND` = task / review / watch,
`REPO`, the FULL `AGTERM_SESSION_ID`). Always pass `--window <id>` to `session new` / `session type`.

**Every extra session for a ticket is a COMPANION of that ticket's task session** (reviews, fix-ups,
checks): `bash ~/.claude/skills/manager/scripts/start-companion.sh <TASK_KEY> <KEY> "<label>" <prompt-file>`.
It nests the session under the task session, names it `<TASK_KEY> · <label>` (the label says what
it is FOR, e.g. `Review #170 web`), starts `claude` with the prompt and writes the registry file.
A companion cannot be made later: to re-home an old session, close it and run the script with
`--resume=<claude session id>`.

## Review sessions

Every PR gets one independent review session before merge, started from the project's review
prompt (`<PROJECT_DIR>/.claude/manager/review-*.md`; fill the placeholders) with
`start-companion.sh` and key `R-<KEY>`. The task session says "ready for review <branch> <sha>";
the review checks that commit out at `review-<KEY>`, runs the **revmux** skill on the PR, then adds
what revmux does not do (test runs, the PR body). It is the only revmux round of a task. A review of
our own PR returns its findings to the task session and stops; it never asks the user what to post.

**Closing a review session:** as soon as its report is forwarded to the task session, in the same
tick, also when a decision it raised still waits (that decision goes on `manager-needs.md` with the
report path): `scripts/close-review.sh <KEY>` keeps the report in `$MANAGER_BRIEFS/reviews/`,
removes the worktree and closes the session. Any other session: ask the user before closing it.

**User review in revdiff before push** (when the project file asks for it):
`scripts/open-revdiff.sh <KEY> <worktree>`, then tell the session to read the annotations file when
the overlay closes. Needs line `KEY | review the diff in revdiff | -`. Never push before it closed.

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
- Then **Deploy list:** every merged change that still needs a production step, in run order, from
  `<briefs>/manager-deploys.md` (drop a line once the user says it is deployed).
- Nothing else. If nothing changed and nothing needs the user, report in one line.
- Simple English, short sentences.

## Talking to a session

- `bash ~/.claude/skills/manager/scripts/say.sh <KEY|agterm-session-id> "<text>"` types the text
  and presses Enter. Start the text with `Manager:`.
- A busy session queues the message. You do not need to wait for it to be idle.
- `say.sh` exits 2 with `SKIPPED` when the user is in that session (looking at it with text on its
  input line, or wrote there in the last 10 minutes). Do not send; try at the next tick.
- Text after `❯` on an input line is usually Claude's grey suggested reply, not the user's typing.
  Never press Enter on text you did not write.
- A session may refuse a decision relayed by a peer (push, merge, team-visible posts): that guard is
  correct. Tell the user in one line to answer in that session itself.
- Both scripts use the **primary** pane, where Claude runs. Read a screen in full:
  `agtermctl session text --target <sid> --lines 60`. Do not `sleep` to wait for a session.
- Exit 3 from `status.sh` or `say.sh`: agterm's control socket is not answering. Send nothing, tell
  the user once.

## Files

| file | what |
|---|---|
| `<briefs>/<KEY>.env` | the registry: `AGTERM_SESSION_ID`, `REPO`, `BRANCH`, `WORKTREE`, `KIND` |
| `<briefs>/<KEY>.md` | the brief the task session follows |
| `<briefs>/tick.env` | the project settings (table above) |
| `<briefs>/manager-holds.md` | held tasks: `KEY \| start when … \| why` |
| `<briefs>/manager-longlived.md` | long-lived sessions with no ticket, one name prefix per line |
| `<briefs>/manager-deploys.md` | the user's deploy list, in run order |
| `<briefs>/manager-decisions.md` | the user's decisions the ticks must apply: `date \| KEY or all \| decision` |
| `<briefs>/manager-needs.md` | items waiting for the user: `KEY \| question \| options` |
| `<briefs>/manager-log.md` | one line per tick action: `date time \| KEY \| what` |
| `<briefs>/.auto-state.json` | per session: last screen hash, PR states, colour; the idle count |
| `<briefs>/.ask/<KEY>.txt` | the screen tail of one `ASK` item |
| `<briefs>/reviews/` | kept review reports |
| `<PROJECT_DIR>/.claude/manager/project.md` | the project's rules, added to every tick prompt |
| `<PROJECT_DIR>/.claude/manager/review-*.md` | the project's review session prompts |
| `scripts/autotick.py` | the tick: screens, GitHub events, Jev, colours; `--dry`, `--retint`, `--restate`, `--add-need KEY "text"` |
| `scripts/run-tick.sh` | what launchd runs every 15 min, for every registry folder |
| `scripts/keep_awake.py` | the rolling `caffeinate` while work runs |
| `scripts/status_ask.py` | the status / limit overlay |
| `scripts/start-companion.sh`, `scripts/close-review.sh` | start a companion session; close a finished review |
| `rules.md` | the one page Claude reads for an `ASK` line |
| `~/.config/typesafe/.env` | `TYPESAFE_API_KEY` for Jev (chmod 600, outside every repo) |
