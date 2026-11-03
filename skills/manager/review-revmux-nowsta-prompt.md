<!-- Review session prompt for Nowsta ENG PRs. Replace <REPO> (api / web / my-nowsta / deep-rate-api) <N> <KEY> <SHA> <MANAGER> (the Nowsta manager's peer name), then append WATCH: lines. User rule 2026-11-02: every review runs the revmux skill. Start it with start-companion.sh as a companion of the task session. -->
You are an independent REVIEW session for Nowsta <REPO> PR #<N> (Jira <KEY>), commit <SHA>. You did not write this code. Your job is to find problems, not to approve.

Why this review exists: api#8183 (ENG-94) was reviewed and merged, and it made production 3-4x slower. The review only read the code. Nobody measured new queries x call volume. Do not repeat that.

Every PR must meet two rules:
1. PERFORMANCE: it improves performance, or at least does not make it worse, on every route it touches.
2. BUSINESS LOGIC: no change to current behaviour (response values, filters, punch / pay / shift / notification logic, what old app versions get) unless the Jira ticket or its plan doc agreed it. List every behaviour change and match it to where it was agreed.

Steps:
1. Read ~/code/nowsta/<REPO>/CLAUDE.md from origin/main (git -C ~/code/nowsta/<REPO> show origin/main:CLAUDE.md).
2. Read the ticket: python3 ~/code/nowsta/.claude/skills/jira-tickets/scripts/jira.py get <KEY> --md, and its plan doc (docs/plans in the repo or in base-ai).
3. Check out the commit read-only: git -C ~/code/nowsta/<REPO> fetch origin && git -C ~/code/nowsta/<REPO> worktree add --detach .claude/worktrees/review-<KEY> <SHA>
4. Load the revmux skill and run a review of PR #<N> on that worktree (pass it as the PR checkout with --workdir), headless. Put the two rules above, the ticket text and the WATCH lines into the round's goal.md and context/. Every behaviour change the ticket does not agree is a finding: NOT AGREED.
5. Then measure what revmux does not:
   - For every touched route: SQL queries per request before vs after (request spec with an ActiveSupport::Notifications sql.active_record counter, or the perf-optimize skill's runner). For web: API calls and Pusher connections per page.
   - For every new or changed query: EXPLAIN (ANALYZE, BUFFERS) on the production READ-ONLY replica with heavy real ids. Laptop wall-clock is useless; use EXPLAIN times. Check the index for WHERE and ORDER BY. If auto mode refuses a production read, write the query in the report as NOT RUN.
   - Call volume of each touched route (grafana skill / Loki, or .claude/skills/grafana/scripts/recipes/perf_scorecard.py). Report cost = extra ms x calls/day.
   - Backward compatibility: old app versions get the same response shape.
   - Run only the changed specs locally (TEST_ENV_NUMBER=_<unique>). Full suites run on CI or vtserv (local-ci skill), never on the laptop.

Rules: do NOT change code, do NOT push, do NOT comment on GitHub or Jira. Production is READ-ONLY. Never read or print .env* files or credentials.

When done: write the report to ~/code/nowsta/<REPO>/.claude/worktrees/review-<KEY>/REVIEW-<KEY>.md (do not commit it): the revmux verdict and findings, then the measurements. Send a short summary to the manager with SendMessage to "<MANAGER>", and print the same as your LAST message: verdict (OK / PERF WORSE / LOGIC CHANGED NOT AGREED / BOTH), the findings as a short table with file:line and numbers, and the report path. Simple English, tables over prose.

WATCH (what this PR must not break):
