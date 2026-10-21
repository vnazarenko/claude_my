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

The script:
1. refuses when an agterm session for this key already exists (one session per ticket);
2. creates the worktree with `parallel-issues/scripts/new-worktree.sh` (env files, gems, skills);
3. writes the task brief `~/.claude/task-briefs/<KEY>.md` (from `references/brief-template.md`
   plus the ticket text) and the registry `~/.claude/task-briefs/<KEY>.env`;
4. opens an agterm session named `<KEY> <summary>` in the worktree and starts
   `claude --session-id <uuid> -n "<name>" "/planning:make <KEY> … read the brief …"`;
5. moves the ticket to **In Progress** and posts a "work started" comment: session name, Claude
   session id with the resume command, repo, branch, worktree.

It must run inside agterm. Outside agterm, stop and tell the user. Do not fall back to a subagent,
because the point is a visible, named session.

### 4. Report

One line: the key, the session name, the worktree. Example:

> **KAN-297 started** in session "KAN-297 Rankings: no way to clear filters", worktree
> `investviews/.claude/worktrees/KAN-297`. It is writing the plan now.

## What the new session does (the brief)

The brief tells the task session to:
- make the plan, commit it, and post the plan summary to Jira;
- implement it in its worktree, open a PR with Deploy steps and After deploy;
- comment on Jira at each event (plan, blocked, scope change, PR opened, merged, deployed) and move
  the status (`Blocked`, `CodeReview`, `ready for deploy`);
- record every daemon, remote `screen`, container or database it starts in
  `~/.claude/task-briefs/<KEY>.procs`, so `task-cleanup` can stop it;
- add its `.claude/SESSIONS.md` line in the PR;
- say "ready for /task-cleanup" when merged and deployed, and not clean up on its own.

Edit `references/brief-template.md` to change these rules for every future task.

## Several tickets at once

Run `start-task.sh` once per ticket. Each gets its own session. For a batch with a shared prompt
and no planning step, the `parallel-issues` skill is the better fit.
