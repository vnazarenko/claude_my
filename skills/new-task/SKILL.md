---
name: new-task
description: Start a new piece of work as ONE Jira ticket = ONE worktree = ONE agterm session = ONE Claude session. Creates (or reuses) the Jira ticket, a worktree at <repo>/.claude/worktrees/<KEY>, an agterm session named "<KEY> <summary>", and an interactive Claude in it that starts with /planning:make and keeps Jira updated with comments while it works. Use whenever the user says "new task", "start a task", "start KAN-123", "work on KAN-123 in a new session", "open a session for this ticket", "create a ticket and start on it", or describes new work that should get its own session — even if they do not say "Jira". The matching end-of-task skill is task-cleanup.
---

# new-task — one ticket, one session

Every piece of work gets a Jira ticket, and the ticket is the name of everything:

| thing | name |
|---|---|
| Jira ticket | `KAN-297` |
| git branch | `KAN-297-<slug>` |
| worktree | `<repo>/.claude/worktrees/KAN-297` |
| agterm session | `KAN-297 <summary>` |
| Claude session | same display name, fixed session id (posted to Jira) |

So the sidebar shows what is running, and Jira shows the history and the status.

**Not for a project with its own Claude config or Jira.** `start-task.sh` uses the default Jira and
the default Claude config. A project that needs `CLAUDE_CONFIG_DIR=<its dir>` and its own Jira is
started by the manager by hand (manager SKILL, "Sessions the manager starts with agtermctl"). The
brief's rules still apply there, section 1b above all: send them in the first prompt.

## Steps

### 1. Get the ticket

- The user gave a key (`KAN-297`) → read it:
  `python3 /Users/vnazarenko/code/Orthhank/.claude/skills/jira-tickets/scripts/jira.py get KAN-297 --md`
- The user described new work → create the ticket first, with the `jira-tickets` skill's rules
  (project `KAN` unless the user says another; type Bug / Task / Story; full body sections).
  Confirm the new key and URL to the user.
- The ticket is already Done or closed → ask before starting it again.

### 2. Pick the repo

The worktree goes in the repo the code lives in, not in the workspace root. Under
`~/code/Orthhank` that is usually `parsalytics/` (API, A-Parser), `investviews/` (web, infra,
docs) or the `Orthhank` root itself (plans, research docs). Read the ticket's labels and text; if
it is still not clear, ask one question with the repos as options.

### 3. Start it

```bash
bash ~/.claude/skills/new-task/scripts/start-task.sh <repo_path> <KEY> [branch] [workspace]
```

**Duo mode** (the user asks for "duo", "with codex", or a manager runs tasks as duo): prefix
`TASK_DUO=1`. The session opens split left/right: **Codex in the right pane, Claude in the left**,
and Claude's first prompt is `/duo <KEY>: …` instead of `/planning:make` (the `duo` skill: Claude
is the only writer, Codex plans, reviews and challenges). The brief's Jira, PR and cleanup rules
still apply. The script warns when Codex did not start or asks to trust the folder — that answer
is the user's.

```bash
TASK_DUO=1 bash ~/.claude/skills/new-task/scripts/start-task.sh <repo_path> <KEY>
```

The script:
1. refuses when an agterm session for this key already exists, in any agterm window (one
   session per ticket);
2. creates the worktree with `parallel-issues/scripts/new-worktree.sh` (env files, gems, skills);
3. writes the task brief `~/.claude/task-briefs/<KEY>.md` (from `references/brief-template.md`
   plus the ticket text) and the registry `~/.claude/task-briefs/<KEY>.env`;
4. opens an agterm session named `<KEY> <summary>` in the worktree and starts
   `claude --session-id <uuid> -n "<name>" "/planning:make <KEY> … read the brief …"`
   (another skill can change the prompt and add to the brief: see "Overrides");
5. waits until Claude runs in that session (about 20 s; it looks in every window, so bringing
   another window to the front does not matter). When it does not, the script stops with
   `ERROR: Claude did not start …`, exit 1: no `TASK_STARTED` line, no Jira change, the session
   is marked blocked. Look at the session, close it, then run the script again (it reuses the
   worktree);
6. moves the ticket to **In Progress** and posts a "work started" comment: session name, Claude
   session id with the resume command, repo, branch, worktree. Last line:
   `TASK_STARTED <KEY> agterm=<sid> claude=<uuid> worktree=<path> branch=<branch>`.

It must run inside agterm. Outside agterm, stop and tell the user. Do not fall back to a subagent,
because the point is a visible, named session.

### 4. Report

One line: the key, the session name, the worktree. Example:

> **KAN-297 started** in session "KAN-297 Rankings: no way to clear filters", worktree
> `investviews/.claude/worktrees/KAN-297`. It is writing the plan now.

## What the new session does (the brief)

The brief tells the task session to:
- make the plan, commit it, and post the plan summary to Jira;
- for EVERY task: measure the performance impact before and after (calls/day, queries per
  request, prod-replica EXPLAIN cold and warm; scaled to the change, never skipped), prove nothing
  got worse, find every behaviour change (also the unintended ones) with where it was agreed, and
  get an independent review before merge (brief section 1b);
- implement it in its worktree, open a PR with Test plan, Deploy steps and After deploy;
- comment on Jira at each event (plan, blocked, scope change, PR opened, merged, deployed) and move
  the status (`Blocked`, `CodeReview`, `ready for deploy`);
- record every daemon, remote `screen`, container or database it starts in
  `~/.claude/task-briefs/<KEY>.procs`, so `task-cleanup` can stop it;
- add its session file `.claude/sessions/<date>-<id8>.md` in the PR;
- say "ready for /task-cleanup" when merged and deployed, and not clean up on its own.

Edit `references/brief-template.md` to change these rules for every future task.

## Coordinator and executor (user rule, 2026-11-11)

The task session is the **coordinator**: it starts on Opus (`TASK_MODEL`, default `opus`), plans
(with Codex in duo mode), reviews and validates. The code is written by an **executor**: a companion
session (`X-<KEY>`, under the task session) on the model Jev picks for the plan, in the same
worktree and branch. Brief section 1d and duo Phase 4 have the steps.

| script | what |
|---|---|
| `scripts/pick-model.py <plan> [--scope ...]` | Jev: `self` (tiny, the coordinator does it) / `haiku` / `sonnet` / `opus` |
| `scripts/start-executor.sh <KEY> <model> <plan> "<scope>"` | starts the executor with `references/executor-brief.md` |
| `scripts/executor-wait.sh <KEY>` | the coordinator waits in the background: 0 handback, 3 idle, 4 gone |
| `scripts/handback.sh <KEY>` | the executor's last step: its report `<KEY>.handback.md` is ready |

The manager tick does not supervise executors (`KIND=executor`): their coordinator does.

## Overrides (for other skills)

Another skill can reuse this flow with its own first prompt and an extra part of the brief.
`start-task.sh` reads three optional env vars. Unset or empty means the default, so a normal
new-task run does not change. The defaults are at the top of `start-task.sh`.

| env | default | what it changes |
|---|---|---|
| `TASK_SEED` | the `/planning:make` prompt | the first prompt of the new Claude |
| `TASK_BRIEF_EXTRA` | none | a file added to the end of the brief, after `references/brief-template.md` and before the ticket text |
| `TASK_NEXT` | "an implementation plan …" | the text after `- Next: ` in the "work started" Jira comment |

- `TASK_SEED`: `{{KEY}}`, `{{SUMMARY}}` and `{{BRIEF}}` (the brief's path) are filled in;
  `{{SUMMARY}}` last, so text from Jira is never read as a placeholder. The seed is typed into a
  shell inside double quotes. It may hold only printable ASCII without `"`, `$`, a backtick,
  `\`, `'` and `!`; anything else (a control character such as Ctrl-A or ESC, a tab, a line
  break, a non-ASCII letter) is refused before anything starts. The key must be `PROJ-123`.
- The Jira summary in the typed command, the session name and the branch: `"`, `$`, a backtick,
  `\`, `'` and `!` are dropped, and every other byte that is not an ASCII letter, a digit, a space
  or one of `.,:;()/_+#@&?={}-` becomes a space. So control characters never reach the shell, and
  non-ASCII letters (Cyrillic, accents) are lost there. The brief keeps the full summary. When
  nothing is left, the session name and the branch are the key alone.
- `TASK_BRIEF_EXTRA` gets the same `{{…}}` placeholders as the template. The rules of the default
  brief stay; the extra part says where its task differs (for example: no plan). A missing file is
  refused before the worktree or the session is created.
- The `security-check` skill's scheduled run sets all three: its own command as the seed, its
  `references/run-brief.md` as the extra part, and a "security report" Next line. The exact
  values are in its `scripts/security-check-due.sh`.

Test (stubs only: no agterm session, no Jira call, a temp HOME):
`bash ~/.claude/skills/new-task/tests/start_task_test.sh`

## Several tickets at once

Run `start-task.sh` once per ticket. Each gets its own session. For a batch with a shared prompt
and no planning step, the `parallel-issues` skill is the better fit.
