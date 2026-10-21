---
name: task-cleanup
description: Finish a Jira task that was started with new-task, and leave a clean machine. Checks the PR is merged (and deployed), stops every process the task started (servers, specs, watchers, background jobs, containers, recorded remote screens and test databases), posts the final Jira comment and moves the ticket to Done, removes the worktree and branch, and at the very end closes the agterm session and the Claude session. Use whenever the user says "task cleanup", "/task-cleanup", "clean up this task", "close the task", "finish KAN-123", "we are done with this ticket", "close this session", or after a task's PR is merged and deployed — even if they do not say "Jira".
---

# task-cleanup — close a task completely

The end of the `new-task` flow. When this skill finishes, nothing of the task is left running:
no session, no worktree, no process, and Jira says what happened.

Everything about the task is in its registry: `~/.claude/task-briefs/<KEY>.env` (key, repo,
worktree, branch, Claude session id, agterm session id). Read it first.

```bash
JIRA="python3 /Users/vnazarenko/code/Orthhank/.claude/skills/jira-tickets/scripts/jira.py"
S=~/.claude/skills/task-cleanup/scripts
```

## 0. Find the task

- Inside the task session: the key is in the agterm session name and the branch name.
- From another session: the user names the key.
- No registry (the task was not started with `new-task`)? Build one by hand with the same fields
  (`KEY`, `REPO`, `WORKTREE`, `BRANCH`, `CLAUDE_SESSION_ID`, `AGTERM_SESSION_ID`,
  `SESSION_NAME`, `PROCS`) from `agtermctl tree --json`, `git worktree list` and the
  scratchpad path. Show it to the user before you go on.

## 1. Gates — stop and ask when one fails

Cleanup removes things, so check first. Report each failing gate in one line and ask what to do.

| gate | check | when it fails |
|---|---|---|
| work is committed | `git -C $WORKTREE status --porcelain` shows only bootstrap files (`.env*`, `Gemfile.lock`, `config/database.yml`, linked skills) | commit it (a `wip:` commit is fine) and push, or ask |
| branch is pushed | `git -C $WORKTREE log origin/$BRANCH..HEAD` is empty | push, or ask |
| every PR is merged | `gh pr list --head $BRANCH --state all --json number,state,mergeCommit,url` | an OPEN PR → stop: the worktree is still in use |
| merge is proven | for each merged PR: `git -C $REPO fetch -q origin && git -C $REPO merge-base --is-ancestor <mergeCommit.oid> origin/main` | do not delete the branch |
| it is deployed | the PR's "After deploy" checks pass (run the read-only ones: `curl`, a status page) or the user says it is deployed | ask: Done, or `ready for deploy` and keep going |
| session log | `git -C $REPO show origin/main:.claude/SESSIONS.md` has this session's line | say so in the report (it needs a new PR now) |

A CLOSED (not merged) PR is fine when the user confirms the work is dropped: then the Jira status
is `closed`, not `Done`.

When the merge is proven, add `MERGE_PROVEN=1` to the registry, so the finisher may delete the
local branch:

```bash
echo "MERGE_PROVEN=1" >> ~/.claude/task-briefs/$KEY.env
```

## 2. Stop the processes

```bash
bash $S/task-processes.sh $KEY            # list
bash $S/task-processes.sh $KEY --kill     # stop, then list again — must say "processes: none"
```

The script finds processes with their cwd in the worktree (daemonized `rails s`, spring, sidekiq,
vite) and children of the task's Claude (background Bash jobs, watchers). It also stops containers
that mount the worktree. It never touches the Claude process itself or the agterm shell.

Then go through the `recorded in …procs` lines one by one. Those are things the script cannot see:
a remote `screen`, a test database, a tunnel. Check each with its find command and stop it with
its stop command. **On a production host, show the user what you will stop and ask first** — a
`screen` on `investviews` may be a long import that must finish.

Also stop what this session itself runs in the background: `TaskStop` every background task and
Monitor you started, and `CronDelete` any cron you created.

## 3. Jira

1. Post the final comment (`$JIRA comment $KEY --body-file …`), in plain English:
   - what was done, in 1–3 lines;
   - the PR links with their merge commits;
   - the deploy state and the check that proves it;
   - anything left open, as a follow-up ticket key (create it with `jira-tickets`) or "nothing".
2. Move the status: `$JIRA transition $KEY --to "Done"` (deployed), `"ready for deploy"`
   (merged, not deployed), or `"closed"` (dropped).

## 4. Report to the user — before the session closes

The user reads this message in the session just before it closes, so it is the last thing they see
here. Keep it to the result table:

| | |
|---|---|
| PR | #N merged (`sha`) |
| Jira | KAN-297 → Done |
| processes | 3 stopped, 0 left |
| worktree + branch | removed after the session closes |

## 5. Close everything — the last step

```bash
bash $S/finish-task.sh $KEY --detach
```

This starts a detached finisher (its own process session, cwd `/`) and returns at once. After a
few seconds it:
1. closes the agterm session `AGTERM_SESSION_ID` — that ends this Claude session;
2. waits for the task Claude to exit (kills it after 30 s);
3. runs `task-processes.sh --kill` again, for anything that outlived the session;
4. removes the worktree from the main checkout — but keeps it when it holds real uncommitted work;
5. deletes the local branch, only with `MERGE_PROVEN=1`;
6. posts a "Cleanup finished" comment on Jira with what it did;
7. moves the registry, brief and `.procs` file to `~/.claude/task-briefs/done/`.

Its log is `~/.claude/task-briefs/<KEY>.cleanup.log`. Run it last: after it starts, nothing else in
this session will run. When you run cleanup from another session, the finisher closes the task's
session, not yours.

## Why the finisher runs detached

The Claude process and the agterm shell both have the worktree as their cwd. Removing the worktree
while they run would break every later command. And closing the agterm session kills the process
that runs the command. So the last steps run outside this session, after it is gone, and report to
Jira, because the session is no longer there to report.
