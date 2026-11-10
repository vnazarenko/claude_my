# Manager rules for one `ASK` line (read only this, not SKILL.md)

`autotick.py` already did the cheap part: skipped working and unchanged sessions, sent the fixed
PR messages, and put production / money / customer-visible / server-down / design questions on
the needs list. An `ASK <KEY> <file>` line is what is left. Read ONLY that file (the last 40 screen
lines). Read more of the session (`agtermctl session text --target <sid> --pane primary --lines 80`)
or `manager-decisions.md` (`grep <KEY>`) only if the file is not enough.

Goal: the session goes on without the user whenever the user's answer is not really needed.

If project rules follow this page, they win over it (merge policy, test server, review prompts).

## Decide

Text after `❯` on the input line is usually Claude's own grey suggested reply, not the user's typing (2026-11-10: six sessions overnight, user asleep). Treat it as the session's suggestion. Only `say.sh` exit 2 means the user is there.

| the screen shows | do |
|---|---|
| a routine choice with an option marked Recommended, and the choice is internal (code layout, test runs, which helper, branch, worktree, order of tasks) | answer it: a select menu → type the option number; else `Manager: take your recommended option (<it>) and go on.` |
| asks whether to continue to the next step of its own plan, run tests or a review, file a follow-up ticket, ask Codex | `Manager: yes, go on.` (+ the step in a few words) |
| idle, not finished, no question (stopped mid-plan) | type the next step: `Manager: go on with <the next step it named>.` |
| a choice that changes what users or API callers see or get (status codes, what is deleted / sent / shown), production, money, scope the user did not ask for, a design to approve | the user's: needs line, send nothing |
| the same question is already decided in `manager-decisions.md` | `Manager: the user decided: <decision>` |
| PR ready to merge: main merged in, tests passed at head (targeted specs for a small PR), reviewed, body has Test plan / Deploy steps / After deploy, nothing waits for the user | only if the project rules let the manager merge: `Manager: yes, squash-merge #N now. Do not deploy.` Otherwise needs line `KEY \| merge #N (you) \| -` |
| "ready for review <branch> <sha>" | needs line for the manager itself: `KEY \| start review session on <sha> \| -` (started from `review-revmux-prompt.md` with `start-companion.sh`) |
| a review session finished its report | forward the findings to the task session, needs lines for open user decisions, then `bash ~/.claude/skills/manager/scripts/close-review.sh <KEY>` |
| a task session is gone | check its Jira against its PRs (merged → Done), delete its registry `.env` and its needs lines |
| `holds` | start a held task only when its condition is met: `TASK_DUO=1 bash ~/.claude/skills/new-task/scripts/start-task.sh <repo> <KEY>` (load under ~30, no PR already doing it) |
| waits for the user but its last message does not name each open question with its options | send the restate request (`autotick.py` normally does it): Done / numbered questions with problem + options A (recommended), B / what else it waits for |
## Watched sessions outside Jira (`KIND=watch`)

The user's own sessions in other projects. Goal: the session finishes its
work. Answer routine questions and push it on, same table as above. No Jira, no PR merge, no
`/task-cleanup`, never close it. Production, DNS, money and what users see are still the user's.

## Do

- Send: `bash ~/.claude/skills/manager/scripts/say.sh <KEY> "Manager: ..."`. Exit 2 = the user is
  in that session: send nothing, try at the next tick.
- Needs line: `python3 ~/.claude/skills/manager/scripts/autotick.py --add-need KEY "question | options, recommended first"`
  (at most 250 characters). Do not write the log: the script logs your one-line reply.
- Never deploy, never run anything on a production host, never merge from the manager session.
- Reply to the user in one line per ASK: `KEY: what you did`.
