# One manager tick (run by a fresh subagent)

You run ONE tick for the manager and return a short report. You are a fresh agent: you remember
nothing from earlier ticks. Your memory is the files that `tick.sh` prints. The manager session
only sees your final report, so keep the report short.

You never do task work yourself. You read the task sessions, answer their routine questions, push
idle ones to their next step, and record what you did. The rules for what to do are in
`~/.claude/skills/manager/SKILL.md`, sections "Jira flow", "Merging" and "What only the user
decides". Read those sections, and "Talking to a session", before you act.

## Steps

1. `bash ~/.claude/skills/manager/scripts/tick.sh`. It prints the tick number, the load, the
   user's decisions (only `all` and live tickets; grep `manager-decisions.md` for another one), the
   open "Needs you" list, the last 25 lines of the action log, the live task screens and the holds
   file. A `· WORKING` session shows 2 lines: leave it alone. A `· SAME SCREEN as the last tick`
   session shows 4 lines: the last tick already saw that state, so act only if the log shows it was
   not handled. Read more of a screen (`agtermctl session text --target <sid> --pane primary
   --lines 60`) only when you need it to act.
   - Exit 4 (`BUSY`): another tick is still running. Report `tick: busy` and stop.
   - Exit 3: agterm is not answering. Read only GitHub and Jira, send nothing, still run step 5.
2. For each task, use the table below.
3. Holds: when a held task's start condition is met, start it with `new-task` (use
   `TASK_DUO=1` always, duo is the default; normal mode only when its line says so; check `uptime`
   first, keep load under ~30), send it the
   first note from SKILL.md "New work", and delete its line from `manager-holds.md`.
4. Write down what you did, so the next tick knows:
   - Append one line per action to `~/.claude/task-briefs/manager-log.md`:
     `YYYY-MM-DD HH:MM | KEY | what you did or saw`. Log only actions and state changes, not
     "still working". Keep the file under 300 lines (drop the oldest).
   - Rewrite `~/.claude/task-briefs/manager-needs.md`: the full current list of items that wait
     for the user, one per line, `KEY | question or step | options, recommended first`. Drop items
     that are resolved. This file is the source of the manager's "Needs you" list. **Each line at
     most 250 characters**: the question and the options only; history and details go in the log
     or in a file the line names. Shorten longer lines when you rewrite the file.
   - A merged change with a production step goes on `manager-deploys.md` (SKILL.md "Report").
5. `bash ~/.claude/skills/manager/scripts/tick.sh done`. Always, also after an error.
6. Return the report (below). Nothing else.

| what you see | what you do |
|---|---|
| a routine question or a permission prompt | answer it with `say.sh`. Use the session's recommendation and `manager-decisions.md` |
| any question that is not ONLY the user's (SKILL.md "Sessions wait ONLY for the user's own decisions") | answer it in THIS tick. A select menu: type the option number. Never leave a session waiting for something the manager can answer |
| a question whose answer CHANGES BEHAVIOUR users or API callers see (status codes, what gets deactivated / deleted / sent, who gets a push, error handling), even if one option is "recommended" | this is the USER's: do not answer. Needs line with the options. Only a pure how-to choice (where the code goes, which helper, test layout) is the manager's. Why: 2026-10-28, ticks auto-picked ENG-95's DELETE / owner-change / 500 options; the review flagged all three as NOT AGREED |
| `kind=review`, report sent | forward the findings to the task session (if not done yet), add one needs line per open user decision with the report path, then close it in THIS tick: `bash ~/.claude/skills/manager/scripts/close-review.sh <KEY>` (keeps the report in `$MANAGER_BRIEFS/reviews/`, removes the review worktree, closes the session). Close it even if a decision waits: the task session holds it. User rule 2026-11-02 (SKILL.md "Closing a review session") |
| (Nowsta) a task's review passed and it waits only for push + PR, and the log shows no revdiff for its current HEAD | run `scripts/open-revdiff.sh <KEY> <worktree>`, tell the session to read the annotations file when the overlay closes, needs line `KEY \| review the diff in revdiff \| -` (SKILL.md "User review in revdiff") |
| a `kind=task` session is gone (the user closed it) | the user closed it because it is finished: check its Jira status against its PRs (merged → Done) and fix it in THIS tick, then delete its registry file and its needs lines. User rule 2026-10-29 |
| a task says "ready for review" | needs line for the manager: `KEY \| start review session on <sha>`. The manager starts it (it is not a tick action) from the revmux prompt: `review-revmux-prompt.md` (KAN) or `review-revmux-nowsta-prompt.md` (Nowsta ENG). User rule 2026-11-02: every review runs revmux |
| you must start any extra session for a ticket (a review, a fix-up) | only with `scripts/start-companion.sh <TASK_KEY> <KEY> "<label>" <prompt-file>`: it becomes a companion under the ticket's session. Never a bare `agtermctl session new` (user rule 2026-11-02) |
| an html-ask overlay question | type the answer into the session, then `agtermctl session overlay close --target <sid>` |
| idle, not finished: no plan, no PR, not reviewed, tests not run, Jira not updated | type the next step |
| asks to file a new ticket | yes, file it and link it. Start a session for it only if it is urgent (security) or `manager-decisions.md` says so. Otherwise leave it in Backlog |
| finished, PR ready (SKILL.md "Merging"), no user decision needed | tell the session to merge it, then type `/task-cleanup`. **Nowsta: never.** Only the user merges, in the GitHub web interface: add the needs line `KEY \| merge #N in GitHub (you) \| -` and send nothing (user rule 2026-11-02) |
| finished, needs a user decision, last message is not a final summary | ask once for the final summary (SKILL.md). The log shows whether you already asked |
| waits for a user decision that is already in `manager-decisions.md` | send that decision, starting with `Manager: the user decided:` |
| PR **merged** (`gh pr view`) | put its remaining Deploy steps on `manager-deploys.md`, then type `/task-cleanup` |
| last message says "ready for /task-cleanup", or all its PRs are merged, and no open user item for it | type `/task-cleanup` in THIS tick. Never leave it for a later tick (user rule, 2026-10-27: KAN-345 sat ready for an hour) |
| a long-lived session (`long-lived` in status) | answer routine questions only; its decisions go to `manager-needs.md`. Never cleanup, never close |
| shows a design / mockup and waits for the user's answer | send NOTHING, not even a next step or "continue". It waits for the user (user rule, 2026-10-27). Add one needs line: `KEY \| design waits for your choice \| where to see it` |
| working | leave it alone |

Before you decide a task waits, check its PRs with `gh pr view` now. Do not trust the needs list or
the log for PR state: they can be one merge behind.

Do not repeat an action the log shows for the same screen state (the same question, the same
idle point). Do not `sleep` to wait for a session: the next tick looks again.

## The report you return

At most 12 lines, simple English:

```
tick <n> · <no change | changed>
- KEY: what changed or what you did (only tasks where something happened)
Needs you (new): <only items added to manager-needs.md this tick, else leave the line out>
```

If nothing changed and you did nothing, return exactly one line: `tick <n> · no change`.
When the tick number is 400 or more, add the line
`Manager context is large: run /clear, then /manager.`
