---
name: task-cleanup
description: Wrap up a Jira task that was started with new-task, and leave a clean machine plus a better set of rules. Checks every PR (merged, CI, review, Deploy steps), updates the ticket and every related ticket, runs a short retro that turns what went wrong into one concrete change in CLAUDE.md, a skill or the docs, stops every process the task started (servers, specs, watchers, background jobs, containers, recorded remote screens and test databases), removes the worktree and branch, and at the very end closes the agterm session and the Claude session. Use whenever the user says "task cleanup", "/task-cleanup", "wrap up", "wrap up the task", "clean up this task", "close the task", "finish KAN-123", "retro this task", "we are done with this ticket", "close this session", or after a task's PR is merged and deployed — even if they do not say "Jira".
---

# task-cleanup — wrap up a task completely

The end of the `new-task` flow. When this skill finishes, nothing of the task is left running —
no session, no worktree, no process — Jira says what happened, and anything that went wrong has
become a rule, so the next task does not hit it again.

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

Red CI on an already-merged PR and a PR body with no `Deploy steps` are **not** gates — they are
retro findings. Step 3 handles them.

When the merge is proven, add `MERGE_PROVEN=1` to the registry, so the finisher may delete the
local branch:

```bash
echo "MERGE_PROVEN=1" >> ~/.claude/task-briefs/$KEY.env
```

## 2. Evidence — one run, read it before anything else

```bash
bash $S/task-evidence.sh $KEY | tee "$SCRATCHPAD/$KEY-evidence.txt"
```

Read-only. It prints facts and judges nothing:

| section | what it tells you |
|---|---|
| `PRS` | every PR for the branch, its state and merge commit |
| `CI` | checks that were not green when it merged |
| `REVIEW` | what a reviewer had to catch — each line is a candidate finding |
| `PRBODY` | whether each PR body really carries `## Deploy steps` and `## After deploy` |
| `COMMITS` | the branch's commits, and how many of them were rework ("fix the fix") |
| `PLAN` | lines the plan marked ➕ (discovered) or ⚠️ (blocked), and boxes never ticked |
| `JIRA` | status, and comments mentioning blocked / scope / wrong / again |
| `RELATED` | linked tickets, plus every key named in the commits or PR bodies |
| `RETRO NOTES` | what the task session wrote down as it worked — the best evidence there is |
| `SESSIONLOG` | whether this session's `SESSIONS.md` line reached `origin/main` |

## 3. Retro — turn what went wrong into one rule change

Run it here, while the worktree, the branch and the logs still exist. This is the step that makes
cleanup worth running: the machine gets clean either way, but only this step stops the same
mistake happening in the next task.

Start from the `RETRO NOTES` section — the task session wrote those lines as the problems
happened. Then add what neither the notes nor the script caught, from this session:

- every time the user corrected you ("no, use X", "do not do Y", "switch to English");
- every command that failed on a wrong assumption about the project — wrong path, wrong host,
  wrong table, wrong env var, wrong test command;
- a fact you had to discover that was already written somewhere you did not look;
- a step a skill told you to do that was wrong, or a step the skill was missing;
- a permission prompt the user denied.

### Where a fix goes

| what happened | fix it here |
|---|---|
| a project fact was wrong or missing (path, host, command, table, env var) | that repo's `CLAUDE.md`, or `docs/services/<name>.md` when it is service detail |
| the fact was written already, but not where you looked | move it, or add one pointer line — never write it twice |
| the same process mistake has now happened in more than one task (uncommitted work in the main checkout, missing PR sections, worktree in the wrong place) | `~/.claude/CLAUDE.md` |
| a skill's steps were wrong, incomplete, or sent you to the wrong place | that skill's `SKILL.md` or its `references/` file |
| a preference about how to work, not about the code | a memory file, type `feedback` |
| the tool or the harness itself failed | `SendFeedback`, not a doc edit |
| one-off, and no rule would have prevented it | nothing — say "nothing to change" |

### Rules for the rule change

- **At most two changes per task.** "Nothing to change" is the normal answer for a task that
  went well. A retro that always finds something stops being read.
- A change earns its place only when it **would have changed what happened this task** and
  **will change the next one**. "Good to know" is not enough.
- **Edit an existing rule before adding a new one.** Deleting a rule that proved wrong counts as
  a change, and is often the best one.
- **Three lines maximum**, written as an instruction ("Edit only `investviews/infra/`"), not as a
  story.
- Give it one line of evidence in the file's own style: `**Why this exists:** 2026-10-22, …` and
  what actually happened.
- Project facts never go in the global file. Process rules never go in a project file.
- Never add a rule that already exists elsewhere. If it existed and was still missed, that is a
  placement problem — fix the placement instead.

### Make the change

- `~/.claude/CLAUDE.md`, a skill under `~/.claude/skills/`, or a memory file: edit in place —
  they only work from that path — then commit it:
  ```bash
  git -C ~/.claude add -A <paths> && git -C ~/.claude commit -m "retro($KEY): <what changed>"
  ```
- A file inside a project repo: it needs its own worktree and PR, because the task's branch is
  merged and the main checkout is read-only.
  ```bash
  git -C $REPO worktree add .claude/worktrees/$KEY-retro -b $KEY-retro origin/main
  # edit → commit → push → gh pr create   (Deploy steps: "Nothing — docs only, merging is enough")
  ```
  That PR is the one thing cleanup leaves open. Name it in the report, and delete its worktree
  when it merges.

Write the finding and the change into the Jira comment in step 5, in one line each. If there is
nothing to change, say that too — it is a result.

## 4. Stop the processes

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

## 5. Jira — this ticket and every related one

1. Post the final comment (`$JIRA comment $KEY --body-file …`), in plain English:
   - what was done, in 1–3 lines;
   - the PR links with their merge commits;
   - the deploy state and the check that proves it;
   - the retro: the finding and the rule that changed, one line each, or "nothing to change";
   - anything left open, as a follow-up ticket key (create it with `jira-tickets`) or "nothing".
2. Move the status: `$JIRA transition $KEY --to "Done"` (deployed), `"ready for deploy"`
   (merged, not deployed), or `"closed"` (dropped).
3. Then every ticket from the evidence's `RELATED` section:

   | the related ticket | do this |
   |---|---|
   | was fixed by this work too | comment what landed with the PR link, then move its status |
   | was only touched | one comment naming this ticket and the PR. No status change |
   | is the same bug as this one | close it as a duplicate and link it |
   | is work this task found and left | it must exist as a follow-up ticket — create it now if it does not |

   Never move a related ticket to Done without naming the PR that did it.

## 6. Report to the user — before the session closes

The user reads this message in the session just before it closes, so it is the last thing they see
here. Keep it to the result table:

| | |
|---|---|
| PR | #N merged (`sha`) |
| Jira | KAN-297 → Done; KAN-310 commented |
| retro | `~/.claude/CLAUDE.md`: test command for parsalytics specs — or "nothing to change" |
| left open | retro PR #N (doc change), or "nothing" |
| processes | 3 stopped, 0 left |
| worktree + branch | removed after the session closes |

## 7. Close everything — the last step

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
session, not yours. It never touches a `<KEY>-retro` worktree.

## Why the finisher runs detached

The Claude process and the agterm shell both have the worktree as their cwd. Removing the worktree
while they run would break every later command. And closing the agterm session kills the process
that runs the command. So the last steps run outside this session, after it is gone, and report to
Jira, because the session is no longer there to report.
