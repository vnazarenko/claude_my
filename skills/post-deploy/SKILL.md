---
name: post-deploy
description: One live checklist of everything to do after the next deploy - the "Deploy steps" and "After deploy" items of every merged and ready-to-merge PR, with checkboxes the user ticks off, shown in the agterm session "Post-deploy steps" (HTML overlay) and rebuilt every 15 minutes by the manager's launchd job. Use when the user asks "what is left after the deploy", "post-deploy steps", "deploy checklist", "what do I need to run after deploying", "show the post-deploy page", "open the checklist", or when a manager needs to add or refresh deploy steps for merged PRs.
---

# post-deploy — one checklist for all deploy and after-deploy steps

Many PRs merge on their own (the manager merges them). Each PR body ends with "Deploy steps" and
"After deploy". This skill collects them into ONE page, so after a deploy the user walks through it
and ticks what is done. Nothing here runs a step: production is always the user's.

## Files

| file | what |
|---|---|
| `scripts/build.py` | reads the PRs with `gh`, writes `~/.claude/post-deploy/data.json` (only when changed) |
| `scripts/serve.py` | serves the page on `127.0.0.1:47312`, saves ticks in `~/.claude/post-deploy/checks.json` |
| `scripts/open.sh` | makes the agterm session "Post-deploy steps": the page on the LEFT pane (a pane overlay over the server), a shell on the RIGHT pane to run the steps in, side by side. `--ensure` only repairs an existing session |
| `page.html` | the checklist. It polls the server every 15 s, so a rebuild shows without reopening |
| `~/.claude/post-deploy/config.env` | `SINCE=` the first merge date to include, `KEEP_DAYS=` (default 2), `WORK_DIR=` where the right-pane shell starts |
| `~/.claude/post-deploy/.off` | create it to stop the rebuilds |

## What goes on the page

- Repos: `REPOS` of every manager registry (`~/.claude/task-briefs*/tick.env`) whose
  `DEPLOY_LIST` is not `off` (a project where the user merges and watches deploys in another way).
- Merged PRs since `max(SINCE, today - KEEP_DAYS)`, plus every older PR that still has an unticked
  step. A PR whose steps are all ticked drops off after `KEEP_DAYS`.
- Open, non-draft PRs whose title or branch names a ticket registered in that folder ("ready to
  merge — steps to come").
- Deploy status from the Capistrano logs on this Mac (`<repo>/log/capistrano.log`,
  `<repo>/*/log/capistrano.log`) and `~/.claude/manager-deploys.log` (`deployed.sh`):
  `deployed` (the merge commit is in the last deploy), `waits for deploy`, or `deploy not
  recorded` (the page then shows an "I deployed it" box).
- Each list item becomes a checkbox. No checkbox for: `Rollback:`, "Too noisy / If …", "Nothing …",
  "Check: nothing", "Left for you: deploy steps 1–4". The `cap … deploy` step and "Merge this PR"
  are ticked automatically once true.
- A tick's id is a hash of the PR, the section and the item text: if a PR body changes an item's
  text, that item shows unticked again.

## Use

```bash
bash ~/.claude/skills/post-deploy/scripts/open.sh          # show it (creates the session)
python3 ~/.claude/skills/post-deploy/scripts/build.py      # rebuild now
python3 ~/.claude/skills/post-deploy/scripts/build.py --since 2026-11-01   # look further back once
```

The launchd job `run-tick.sh` runs `build.py --quiet` and `open.sh --ensure` every 15 minutes,
also while every manager has `.ticks-off` (no Claude, no tokens). If the user closes the session,
it stays closed until `open.sh` runs again. The page also opens in a browser at
`http://127.0.0.1:47312/` (same ticks).

## Rules for task sessions (so the page is useful)

- Write Deploy steps as a numbered list, one action per item, the command in backticks.
- "Left for you: …" items that only repeat the steps above add nothing; name new work only.
