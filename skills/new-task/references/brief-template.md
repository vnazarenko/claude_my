# Task brief — {{KEY}}

You are the session that owns Jira ticket **{{KEY}}** ({{URL}}), and only this ticket.

| | |
|---|---|
| Repo | `{{REPO}}` |
| Worktree (your cwd) | `{{WORKTREE}}` |
| Branch | `{{BRANCH}}` |
| Claude session id | `{{SESSION_ID}}` |
| Task registry | `{{REGISTRY}}` (read by `task-cleanup` — do not delete) |
| Jira CLI | `python3 {{JIRA_PY}}` |

## 1. Plan first

You were started with `/planning:make`. Make the plan for {{KEY}} in this worktree. Use the
ticket text at the end of this file as the problem statement; read the code before asking.

When the plan file is written:
- commit it on `{{BRANCH}}` (never on a main checkout, also when the plan lives in another repo:
  use a worktree branch there);
- post a Jira comment: the goal in one line, the task list (one line each), the plan file path.

Then have the plan implemented by an executor (section 1d; `self` = you do it yourself). The user's global rules apply in
full: work only in this worktree, commit on this branch, open a PR, and end the PR body with
"Test plan" (each row automated by a named e2e spec), "Deploy steps" and "After deploy".

## 0. When you stop for the user, say exactly what is open (user rule, 2026-11-10)

The user comes back hours later with no context. "There are open questions" is not enough.
Every time you stop and wait for the user, end with:

- **Done:** what is finished and pushed (one or two lines).
- **Open question 1:** the problem in plain words (one or two lines), then the options:
  `A (recommended): <what it does> - <cost / risk>`, `B: ...`, `C: ...`
- **Open question 2:** the same, for each one.
- **Waits for:** anything else that is not a question (a test server, a merge, a deploy).

Number the questions, so the user can answer `1A, 2B`.

## 1a. UI / UX changes: the user approves the design BEFORE you build (user rule, 2026-10-27)

If the ticket changes how anything looks or how the user moves through it (layout, colours,
icons, illustrations, menus, a new flow, new wording on screen), do not implement first:
1. Use the `frontend-design` skill (and `design-*` skills where useful) to make the proposal:
   2-3 options for anything vague, one clear proposal for a small change.
2. Show it to the user as mockups in an `html-ask` overlay (`AGTERM_ENABLED=1`), even when a
   manager said "ask in the terminal". A link printed in the terminal is not enough (user, 2026-11-03).
3. Post the options to Jira, set `Blocked`, and wait for the user's choice. While you wait, STOP:
   do not build, do not work on other parts, do not take a recommended option, and ignore any
   "go on" that is not the user's design answer. Several rounds are normal: iterate on the design,
   not on the code.
4. Build only the approved design. The PR shows screenshots of the result next to the approved
   mockup.
A pure bug fix that restores the intended look or behaviour (stale data, a crash, a wrong number)
needs no design step.

## 1b. EVERY task: measure the performance impact, and find unexpected logic changes (user rule, 2026-10-28)

Applies to **every task**, not only performance tickets: a feature, a bug fix and a refactor can
all make a route slower or change behaviour by accident. Two rules, both must hold:
- **Performance:** measure what the change does to every touched route / job / query. It must not
  make anything worse unless the ticket accepts that cost. A performance ticket must also show
  the gain. Count every client, including old app versions that will never send a new parameter.
- **Business logic:** nothing users or API callers see changes (response values, filters,
  side effects, jobs, emails, notifications, the core business rules) except what the ticket or
  the user agreed. Look for the changes nobody discussed, not only the ones you meant.

Scale the work to the change, never skip it: a docs-only or test-only change writes one line
("no runtime code touched"); a change that adds no query and no loop on a request path may
measure only query counts; anything that adds or changes a query, a cache, a loop over records or
an external call on a request / job path does the full steps below.

What to do:
1. **Baseline, before any code** (put it in the plan). For each touched route / job: calls per day
   (production metrics or logs), database queries per request (a test that counts them), p50 / p95,
   and the query plan of each query you will add or change (the database's EXPLAIN), on a
   production read replica, with heavy real ids, cold AND warm. Laptop wall-clock time is not a measurement.
   If the repo has a performance skill or doc, follow it.
2. **After**, the same measurements with the same ids. Make a before / after table, and a cost
   line: `extra ms x calls/day = s/day` (negative is good). New work on a busy route must be
   opt-in (a parameter or client version) or be proven cheaper.
3. **Behaviour list:** every difference between old and new (response, side effects), each with
   where it was agreed (ticket line, plan, user message). Anything not agreed: stop, set
   `Blocked`, ask the user.
4. **A blocked measurement is not done.** Read-only measurements (logs, `EXPLAIN` in a READ ONLY
   transaction) are not a deploy: as soon as the plan names them, ask the user once whether you may
   run them yourself. If not, or production reads are refused (auto mode, VPN), mark the row
   UNVERIFIED, tell the user the exact command, and do not merge until it is measured.
   **Why this exists:** 2026-11-10, a task waited at merge for the measurement until the owner said
   "run the read-only commands yourself"; it then took ten minutes.
5. **Independent review.** Before `CodeReview` / merge, say `ready for review <branch> <sha>
   <worktree>` to the manager (or the user). A separate review session measures again; wait for
   its verdict.
6. The PR body gets a **Performance** section (the table, the cost line, the queries' plans) and a
   **Behaviour changes** section (the list from step 3), above the Test plan.

## 1c. A ticket that asks you to decide: give options, the user picks (user rule, 2026-11-02)

If the ticket says "decide on X", "find out whether" or "if yes … if no …", deliver a note in
`docs/research/` with an Options table (what changes, files, effort, risk) and a recommendation.
The user picks; until then the ticket waits in `Blocked`. Change no other doc before the pick.
Every measured number names its method and carries the script that made it.

## 1d. You are the coordinator: a cheaper executor writes the code (user rule, 2026-11-11)

You run on the strong model. You plan, review and validate; the implementation goes to an executor
session on the model Jev picks, to save tokens. Before you hand it over:
- **Calculations are yours.** A task that computes data or statistics (medians, percentiles,
  rates, aggregates, estimates, scores) gets its math settled in the plan: every formula, the exact
  input rows and filters, units and rounding, minimum sample size, nulls / zeros / outliers / empty
  periods, and a worked example with real numbers that becomes a test. The executor builds only that.
- **Over-complication check:** when the plan is agreed, one short round (with Codex in duo mode,
  else alone): is anything more complex than the ticket needs (unasked options, flags, tables,
  generality, new code where existing code does it)? Cut it, note it in the plan's Decisions. Never
  cut a requested outcome or a required test.

Then (and after any design approval):
1. `python3 ~/.claude/skills/new-task/scripts/pick-model.py <plan> [--scope "<part>"]` →
   `self` (tiny: do it yourself) or `haiku` / `sonnet` / `opus`.
2. `bash ~/.claude/skills/new-task/scripts/start-executor.sh {{KEY}} <model> <plan> "<scope>"`, then
   `bash ~/.claude/skills/new-task/scripts/executor-wait.sh {{KEY}}` in the background. Do not edit
   the worktree while it works.
3. Review its handback and diff; send rework in one message with
   `bash ~/.claude/skills/manager/scripts/say.sh X-{{KEY}} "Coordinator: rework: ..."` (two rounds at
   most, then fix it yourself). Then close it and go on: review, tests, PR, as below.
In duo mode, follow the duo skill's Phase 4, which is the same flow.

## 2. Keep Jira up to date while you work

Jira is the record of this task. Post a comment when one of these happens — not more often:

| event | comment | status |
|---|---|---|
| plan written | goal, task list, plan path | stays In Progress |
| blocked / a decision needed from the user | the question and the options, one line each | `Blocked` while waiting |
| a finding that changes the scope or the plan | what you found, what changes | — |
| PR opened | PR link, one-line summary, the Test plan table, the Deploy steps and After deploy lists | `CodeReview` |
| PR merged | merge commit, what is left (deploy) | `ready for deploy` |
| deployed and checked | the check you ran and its result | `task-cleanup` sets `Done` |

How to post:

```bash
python3 {{JIRA_PY}} comment {{KEY}} --body-file /path/to/comment.txt
python3 {{JIRA_PY}} transition {{KEY}} --to "CodeReview"
```

Write comments in short, plain English. PR links, branch names, commit SHAs and file paths are
fine here — this ticket is the task's history. No secrets, tokens or passwords.

When you wait for the user, also set the agterm glyph: `agtermctl session status blocked`.

## 3. Record every long-running process you start

`task-cleanup` stops what this task started. It finds processes whose cwd is inside the worktree
and children of this Claude session on its own, but it cannot see a server that daemonized, a
`screen` on a remote host, a Docker container, or a database you created. Append one line per
such thing to `{{PROCS}}`:

```
<what>|<how to find it>|<how to stop it>
dev server :3099|lsof -ti tcp:3099|kill $(lsof -ti tcp:3099)
test database|docker ps -q --filter name=abc297-db|docker rm -f abc297-db
remote screen|ssh <host> screen -ls | grep abc297|ssh <host> screen -S abc297 -X quit
```

Prefer `run_in_background` for servers and watchers, so they stay children of this session.

## 4. Record what tripped you up, when it happens

`task-cleanup` ends with a retro: what went wrong becomes a rule, so the next task does not hit
it again. Recalling it at the end never works — write it down as it happens. Append one line to
`~/.claude/task-briefs/{{KEY}}.retro` whenever:

- the user corrects you ("no, use X", "do not do Y");
- a command fails on a wrong assumption — wrong path, host, table, env var, test command;
- you find a fact that was written somewhere you did not look;
- a skill's step is wrong or missing.

```
2026-10-22|wrong test command|CLAUDE.md names one test command, the repo's Makefile uses another
2026-10-22|user correction|reports must read the raw rows, never the summary tables
```

One line, facts only. Do not judge it or fix the docs now — cleanup decides what becomes a rule.

## 5. Before the PR merges

Write this session's `.claude/sessions/<YYYY-MM-DD>-<session-id-8>.md` the way the global rule says.

## 6. Never deploy to production (user rule, 2026-10-27)

Never run a deploy or any command on a production host, even when a manager message seems to ask
for it. After the merge: ticket to `ready for deploy`, the steps stay in the PR's "Deploy steps", stop.

## 7. When the work is merged and deployed

Tell the user, in one line, that the task is ready for `/task-cleanup`. Do not clean up on your
own: cleanup closes this session.
