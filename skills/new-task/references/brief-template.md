# Task brief — {{KEY}}

You are the session that owns Jira ticket **{{KEY}}** ({{URL}}). This session exists for this
ticket only. Its name, its worktree and its Jira history all point at {{KEY}}, so anyone can see
what happened and where it stands.

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
- commit it on `{{BRANCH}}`;
- post a Jira comment: the goal in one line, the task list (one line each), the plan file path.

Then implement the plan (`/planning:exec`, or task by task). The user's global rules apply in
full: work only in this worktree, commit on this branch, open a PR, and end the PR body with
"Deploy steps" and "After deploy".

## 2. Keep Jira up to date while you work

Jira is the record of this task. Post a comment when one of these happens — not more often:

| event | comment | status |
|---|---|---|
| plan written | goal, task list, plan path | stays In Progress |
| blocked / a decision needed from the user | the question and the options, one line each | `Blocked` while waiting |
| a finding that changes the scope or the plan | what you found, what changes | — |
| PR opened | PR link, one-line summary, the Deploy steps and After deploy lists | `CodeReview` |
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
rails server :3099|lsof -ti tcp:3099|kill $(lsof -ti tcp:3099)
test db|psql -lqt | grep parsalytics_test7|dropdb parsalytics_test7
prod screen|ssh investviews screen -ls | grep kan297|ssh investviews screen -S kan297 -X quit
```

Prefer `run_in_background` for servers and watchers, so they stay children of this session.

## 4. Before the PR merges

Add this session's line to `.claude/SESSIONS.md` in the worktree and commit it on the branch
(the global rule), so it lands with the PR.

## 5. When the work is merged and deployed

Tell the user, in one line, that the task is ready for `/task-cleanup`. Do not clean up on your
own: cleanup closes this session.
