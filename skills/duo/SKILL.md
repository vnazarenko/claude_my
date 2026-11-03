---
name: duo
description: 'Take a task from a one-line request to a reviewed, tested, ready-to-merge pull request with TWO agents side by side in an agterm split — Claude (the only writer) and Codex (reviewer and critic) — who plan together and review each other, then hand the PR to one independent revmux review, while the user is away. Use whenever the user says "duo", "/duo", "do this with codex", "work on this with codex", "claude and codex together", "pair with codex on X", "plan it with codex and implement", "build this with codex, I will be away", "make a ready PR with codex", or hands over a task and says they are leaving and want a finished PR. Not for one question to Codex (peer-chat), and not for a review of existing code only (revmux).'
---

# Duo — Claude and Codex finish a task together

The incidents behind these rules are in `references/history.md`. Read it only when a rule is
unclear; add new "Why" stories there, not here.

The user describes what should be done and leaves. When they come back they expect **one or more
pull requests that are ready to merge**: planned together, implemented, reviewed by Codex and by
one independent revmux review, covered by unit, API and UI end-to-end tests, with a test plan they can follow after deploy.
They should not find a half-done branch, a question that waited for hours, or Codex frozen at a
prompt.

| | Claude (this pane) | Codex (the other pane) |
|---|---|---|
| writes code, plans, tests, PR bodies | **only Claude** | never |
| runs suites, servers, migrations, git writes | **only Claude** | never |
| reads code, criticises, reviews, checks claims | yes | **its main job** |
| asks the user | only for the cases in "When to ask the user" | never directly — tells Claude |

Transport is the `peer-chat` skill (`peer-chat.py`). Load it at the start and follow its sending and
receiving rules; this skill adds the workflow on top.

## Phase 0 — Preflight

```bash
~/.claude/skills/duo/scripts/preflight.py
```

It checks agterm, the split with Codex in the other pane, that `peer-chat.py` and both peer-chat
skills match upstream master (an old script cannot read a newer Codex prompt and refuses to type), the
Codex rule that lets Codex reply without an approval prompt, and revmux and gh.

- Every `FIX` line prints its fix. Do the ones you may do yourself.
- A fix that changes the user's own config (the Codex rule, `~/bin/peer-chat.py`) or needs a pane
  opened is the user's. Ask **once, at the very start, all together**, while they are still there.
  This is the one question worth making before work begins, because without it every Codex reply
  stops at a prompt.
- If peer-chat cannot work at all, use the fallback in "When the pane chat is impossible" and say so
  in one line.

## Phase 1 — Intake (Claude alone, short)

1. Say the task back in one line, in the user's terms.
2. Search for someone already doing it: `gh pr list --state all --limit 30 --search "<2-3 keywords>"`
   in every repo the task touches. An open PR by another session or person is **not yours to edit** —
   record it in the Outcome ledger as an outstanding dependency. Check whether a separate fix
   can safely deliver the promised behavior; do not silently remove the outcome from the request.
   Also list open PRs that rewrite the pages or files you will change (`gh pr list --state open`,
   then `gh pr diff <N> --name-only`). If one replaces them, build on its version or ask the user.
3. For every repo you will touch: read its `CLAUDE.md` and `AGENTS.md` (and nested ones for the
   package), check `gh api repos/<o>/<r> --jq .visibility`, and create a worktree at
   `<repo>/.claude/worktrees/<name>` from `origin/<main>`. Never edit the main checkout.
   Create every worktree — the second repo's too — with `(cd <repo> && ~/.claude/skills/parallel-issues/scripts/new-worktree.sh . <KEY> <branch>)`,
   never a bare `git worktree add`: it copies the gitignored `.env*`, `config/master.key` and gems.
4. Give the worktree its own test databases when the repo supports it (for example `TEST_DB_NAME`,
   `CH_TEST_DATABASE_NAME`), so your runs cannot collide with another session's.
5. Do a quick audit of the current state: the code paths involved, what already exists and what is
   missing. Facts with `file:line`, not guesses.
6. A number the design depends on (a median, a top, a count) is measured on the exact input the
   code reads at run time (the request the app really sends, its buffer and resolution), never on a
   hand-made box or a whole city.

## Coverage follows the user's request

At intake, copy the user's requested outcomes verbatim into an **Outcome ledger** in the plan,
with stable IDs (`O1`, `O2`, ...). Keep the original wording through every revision. Add newly
discovered requirements as separate rows; never replace the original request with the proposed scope.
Each row records: outcome, PR or owner, required test rows, status, and any decision still needed.
When one outcome names several items ("compare A, B, C / D + custom"), each named item gets its own
row or matrix column; never merge two of them into one.
Link the source message when available; otherwise quote it. If intake only has a peer's summary,
mark it as unconfirmed and obtain the original request before claiming the whole request fulfilled.

Before **every plan round, code round and handoff**, Claude and Codex each reconcile the work with
this ledger first. A plan can be implemented correctly while the user's request is still incomplete.
Another owner's PR is an outstanding dependency until its required behavior and tests are verified.

For each outcome, record a matrix of the applicable account states and access paths:

- For paid access: **signed-in free denial and current paid allowance** are separate required cases.
  Add anonymous, lapsed paid and staff where the policy gives them distinct behavior. Anonymous
  denial never proves signed-in free denial.
- Cover the real UI where relevant and direct API access, including applicable alternate routes,
  generation, cache reuse and stored reads. Check each path against its recorded product policy.
  A UI lock does not prove an API is gated. An API may be free on purpose: record its expectation
  as `open by design — <decision and source>` and test its intended limits. That is an expected
  behavior, not an exemption from coverage; do not add a gate that breaks an intended free feature.
- Each applicable cell names its exact automated spec/test, account state, expected assertion,
  actual result and tested commit(s). Use `n/a — <reason>` only for inapplicable cases. A missing,
  blocked or unrun test stays **UNVERIFIED**, with the reason; it is never `n/a` or passed.
- Label unit, request, mocked browser and live e2e evidence accurately. Where a live suite exists,
  every changed-behavior row needs live e2e for its relevant UI or direct API path. A regression row
  for unchanged behavior may use a request spec, labeled as such. Passing totals alone do not
  establish coverage; request or mocked tests do not replace required live e2e evidence.

A scope reduction needs explicit user agreement. If the user is away, notify once with
`agtermctl notify` when available and permitted, continue independent work, and keep the unresolved outcome
**NOT DONE** at the top of the handoff, with the decision needed. Silence is not agreement.
A scope EXPANSION needs it too: a review finding (Codex's or revmux's) that adds behaviour users
see beyond the request (URL state, a persisted preference, a change to a shared component, a new
error or check, hardening against the caller's environment) is not a
"decision" to accept; keep today's behaviour and put the finding to the user as a follow-up.
The same holds for your OWN design: every side effect the ticket does not name keeps main's exact
behaviour (stored values, key meanings, focus text, which rows are imported or dropped), and choosing
against the ticket's own words ("non-linear" → linear) is a question for the user, never a Decision
you write down yourself. A row main drops or skips (even by an exception your fix removes) stays dropped.
When the ticket says "the same way as X", copy X's exclusions too: what X kept, you keep.
A conflicting PR is not itself a reason to exclude an outcome: where a safe fix follows the
product's existing promise, prepare a small separate PR from main with its own tests and flag the
conflict. Do not modify another owner's branch or make an unresolved product choice for the user.

Keep three conclusions separate: **code approved** (the reviewed implementation), **PR readiness**
(the named PR's checks and dependencies), and **request fulfilled** (every original outcome verified
or explicitly removed by the user). If the user agrees to defer an outcome, name it as deferred.
Do not call it tested. Lead the handoff with the ledger, unresolved outcomes first,
then the PR links. State `code approved: yes/no` and `request fulfilled: yes/no` explicitly, and name
any user-approved exclusions.

## Phase 2 — Kick off Codex

Send one message (one paragraph; the script joins lines):

> Hi Codex, Claude here (left pane). Task from the user: <one line>. Please read
> `~/.claude/skills/duo/references/codex-role.md` first — it is how we work: I am the only writer,
> you review and criticise, read-only, no test suites. Reply with
> `peer-chat.py --to claude --session <$AGTERM_SESSION_ID>`. My audit so far: <findings with
> file:line>. Original requested outcomes: <verbatim ledger rows and source>. My proposal: <short>.
> Repos and worktrees: <paths, branches>. First reconcile the proposal with the Outcome ledger; then
> check every claim yourself and attack these risks: <specific risks>.

Always put the explicit `--session <id>` in the message. Codex's environment can name a session that no
longer exists, and then none of its replies reach you.

## Phase 3 — The plan, negotiated

Write the plan at `<repo>/docs/plans/<YYYYMMDD>-<slug>.md` in your worktree and commit it. It holds:

- **Problem** — what is wrong or missing, with evidence.
- **Outcome ledger and coverage matrix** — the original outcomes, account states, access paths and
  evidence defined above. Keep unresolved dependencies and coverage gaps visible.
- **Scope** — what this implementation delivers; exclusions from the original request require
  explicit user agreement. Another owner's PR remains an outstanding ledger row.
- **Design** — per change: the rule, where it runs, edge cases (anonymous, free, lapsed, staff, empty,
  nil, concurrent), error codes and messages.
- **Tests** — unit, API (request/integration) and **UI end-to-end** specs, named, each with what it
  proves. If the change has a UI, there is a UI e2e spec. If it has an endpoint, there is an API e2e
  check against a real backend where the repo has a live suite. Say which existing specs change.
- **Test plan after deploy** — the rows that will go into the PR's Test plan (see Phase 7).
- **Rollout** — order of deploys, migrations, rollback.
- **Decisions** — every choice made without the user, with the reason.

Then the review rounds:

1. Send Codex the plan path, original request and ledger. Ask it to check outcome coverage first,
   then review in its shape (numbered findings, severity, evidence, the concrete change, and
   `approve` / `changes needed`). Code or plan approval does not certify request fulfillment.
2. **Verify each finding yourself** before accepting it — read the code it cites. Accept, or reply
   with the evidence for why not. A real disagreement is useful; settle it with a checked fact.
3. Revise the plan, commit, tell Codex what changed per finding, ask for the next round.
4. Repeat until Codex says `approve`, or the only open points are written in **Decisions** with
   reasons both sides have seen. Written decisions cannot waive a requested outcome or missing
   coverage without the user's explicit agreement. **At most two plan rounds** (user rule,
   2026-11-03): round 2 checks only what changed since round 1. Open points after round 2 go in
   **Decisions**; a disagreement that changes what users see goes to the user.
5. A product decision with no safe default goes to the user; continue independent work while the
   decision is pending. A conflicting PR alone does not require waiting: prepare the safe separate
   PR described above, then ask the user which direction to keep. Record the decision needed.
   Decide routine details, write them down, and move on.
   While the answer is pending, the main PR keeps today's behaviour; build the option that changes it
   as its own PR stacked on the main one, never as a commit inside it.

You may start uncontested parts of the implementation while a plan round is out, and tell Codex you
did. Never start the parts the round is about.

Before building a requirement found mid-task (not in the ticket), run the intake PR search again for it.

## Phase 3b — Design approval for UI / UX changes (user rule, 2026-10-27)

If the task changes how anything looks or how the user moves through it, the negotiated plan ends
with a DESIGN, not with code: Claude makes mockups with the `frontend-design` skill (2-3 options when
the ticket is vague), Codex reviews them, and the user picks one (html-ask overlay, or an HTML file /
Artifact link printed in the terminal; Jira comment + `Blocked` while waiting). While waiting, stop
completely: no building, no other parts, no recommended option. Iterate on the design
until the user approves; only then go to Phase 4. Never build an unapproved design. A pure bug fix
that restores the intended look skips this phase.

## Phase 4 — Implement (Claude)

- Test first where it is practical. Run targeted specs after each change, never a full suite while
  working.
- **Mutation-check every guard you add**: break it on purpose (remove the lock, the check, the filter),
  run its spec, confirm the spec fails, restore with `git checkout -- <file>`. A test that passes
  without the guard proves nothing. Do this from a committed state, and never while a suite, an e2e
  build or a reviewer reads the worktree: they see the mutated file.
- Lint the way CI does (the whole project, not one file) — on vtserv: `vt run --no-db -- bundle exec
  rubocop`, or from `web/` `vt run --no-db -- pnpm lint`.
- Commit in small steps on the worktree branch. A `wip:` commit is fine.

## Phase 5 — Code review: Codex here, revmux once, outside (user rule, 2026-11-03)

Before any review, merge the latest `origin/<main>` into the branch and diff with three dots
(`git diff origin/<main>...HEAD`), so the review sees only this branch's changes.

1. **Codex reviews the code.** Send it the branch, the head SHA and the diff command, and ask for a
   code review in its shape. Name what you most want attacked.
2. For every finding: verify it in the code yourself and classify it (real and fixing, real but
   pre-existing, not real with evidence, or a decision). Fix with three checks: sweep for the same
   shape elsewhere, list what you touched, re-read the finding against the fix. Re-run the targeted
   specs, commit, tell Codex what changed.
3. **At most two Codex code rounds.** Round 2 reads only `git diff <round-1 sha>..HEAD` and the open
   findings, not the whole branch again. Open points after round 2 go in **Decisions**; a
   disagreement that changes what users see goes to the user.
4. **Do not run revmux in this session.** revmux runs once, in the independent review after the PR
   is open (Phase 7, step 6).

**Code approved when** Codex says `approve` on the current head after reconciling the ledger, and
the independent review's findings are fixed or decided. Assess request fulfillment separately
against every original outcome and its coverage matrix.

## Phase 6 — Tests: unit, API and UI end-to-end

- Reconcile executed tests with every Outcome ledger row and coverage-matrix cell. Read the actual
  test setup and assertions; file names and green totals do not establish the required coverage.
- Every behaviour change has a unit or request spec, an **API e2e** check where the repo has a live
  suite against a real backend, and a **UI e2e** spec when users see it. Use fresh accounts in e2e;
  never change shared seeded fixtures.
- Run the stubbed and the live e2e suites that cover the change, on vtserv: `vt e2e …`,
  `vt e2e-live …`. Background long runs and wait for the notification.
- **A failure is yours until it is proven otherwise.** To call it pre-existing, run the same spec on a
  clean `origin/<main>` worktree and get the same failure, then remove that worktree. "The file is
  untouched" is not proof. Write the baseline comparison into the PR.
- A red test in a Playwright `serial` file skips every test after it, so a new test there is proven
  only by a whole-file run, never by `-g`. Fix the earlier test, or give the new test its own file.
- Run the full suite once, right before opening the PR, on vtserv: `vt rspec-full` (parsalytics).
  Report its result exactly, failures included.
- **Every heavy run goes to vtserv through `vt`, never the Mac** — load the `vtserv` skill: full
  suites, both e2e suites, whole-project builds, typecheck and lint, Docker. Each run gets its own
  databases there, and `vt` queues by itself (one run per checkout, three slots), so there is no
  load check and no "is another live run going" check. Exit 69 means vtserv is down: ask the user;
  never fall back to the Mac. A few e2e tests fail only on vtserv (BL-0010 in investviews'
  backlog): compare against `main` on vtserv, not against a green Mac run.

## Phase 7 — Pull requests

1. Merge the latest `origin/<main>` again, re-run the targeted specs, push, and open the PR.
2. Write the body to the PR rules in `~/.claude/CLAUDE.md` ("PR descriptions"). It ends with
   `## Test plan`, `## Deploy steps` and `## After deploy`, in that order. Every Test plan row names
   its Outcome ledger ID and the exact spec/test that automates it, accurately labeled by layer.
   Disclose all requested outcomes still unimplemented or unverified and link any dependency PR.
   Also include: what changed and why, the review record (Codex
   rounds, the independent review, what each found), the exact test results, the pre-existing failures with
   their proof, and release dependencies on other PRs.
3. Link PRs that belong together in both directions, and say which deploys first. A PR whose
   tests fail without another PR opens as a **draft** (`gh pr create --draft`); mark it ready only
   after that PR merges.
4. Read the checks: `gh pr view <N> --json statusCheckRollup`. A job that ended in seconds with no
   steps and no runner **did not run** — say so, and do not call it verified.
5. Ask Codex for one last read of the PR bodies, mainly that the Deploy steps and After deploy
   commands are right and safe. Fix what it finds. Save each body and diff to a file first
   (`gh pr view <N> --json body --jq .body > …`, `gh pr diff <N> > …`) and send Codex the paths:
   `gh` needs network, and in Codex's sandbox it stops at an approval prompt only the user can answer.
6. **Independent review.** Say `ready for review <branch> <sha> <worktree>` to the manager. It starts
   ONE independent revmux review in a companion session (of the PR; in a repo where the PR opens
   only after review, of the pushed branch). Verify each finding it forwards,
   fix it (Phase 5 checks), re-run the targeted specs, push, then send Codex the findings, your
   classification and `git diff <reviewed sha>..HEAD` for ONE re-read. No new revmux round unless the
   user asks. No manager (the user started duo by hand): run that one revmux round yourself (`revmux`
   skill, headless, `--profile comprehensive`) on the PR.
7. **Do not merge.** Ready to merge means the user can merge it without doing anything else first.

## Phase 8 — Wrap up

- Write the session file `.claude/sessions/<date>-<id8>.md` in each worktree branch and push it with the PR.
- Remove temporary worktrees you created (baselines). Keep the PR worktrees until the PR is merged.
- Check `git status` in every worktree: nothing uncommitted.
- Send Codex a closing note (`--queue`) and stop the exchange.
- Reconcile the original Outcome ledger once more. Lead with its table (outcome, PR, test rows,
  status), unresolved outcomes first; then report the PR links, the two separate verdicts
  (`code approved` and `request fulfilled`), Deploy steps and After deploy lists, and any decision
  still needed. Do not report the whole request complete while an original outcome is outstanding.

## Working with Codex in the other pane

**Never poll for a reply.** A Codex reply arrives in your pane as a prompt starting with
`Chat from Codex:` and wakes you. While you wait, keep working on what does not depend on the answer.

**Check on Codex at checkpoints, not in a loop.** A checkpoint is: you finished the work you could do,
and a reply you asked for has not come; or a background job finished; or you are about to report to
the user. Then run once:

```bash
~/.claude/skills/duo/scripts/peer-state.py
```

| state | what to do |
|---|---|
| `idle`, and you expected a reply | Read its pane (`agtermctl session text --target $AGTERM_SESSION_ID --pane <other> --lines 80`). A delivery failure often shows there (`no such session`); take the answer from the pane or from `outbox`, tell Codex the right `--session`, carry on. If it simply never answered, ask once more, briefly. |
| `working` | Leave it. Do your own work. |
| `approval` | Codex is frozen at a prompt only the user may answer. If `pending_command` is a reply to you (`peer-chat.py --to claude …`), read the prepared message from `outbox` (it is addressed to you) and carry on. In both cases notify the user once (`agtermctl notify "<what Codex waits for>" --title duo`), point at the Phase 0 rule that prevents it, and keep working. |
| `unknown` | Read the `tail` it printed and decide. |

If Codex really stops at an escalation prompt because **the sandbox blocked the agterm socket** (you
see it in its pane), it comes back on every reply: read this reply from the pane, then run the
remaining rounds through the `codex:codex-rescue` fallback and say so in one line.
**Do not switch to the fallback because preflight WARNs about the raw socket.** The allow rule runs
`peer-chat.py --to claude` outside the sandbox (measured 2026-11-02, codex-cli 0.166), so the pane chat
works. The pane chat is the default: the user watches it.

**Never type into Codex's prompt, and never answer its approval, trust or chooser prompts.** Those
answers carry the user's authority. Prevent them instead (Phase 0) and report them.

**Quote Codex when you report** what it said, and verify any claim it makes about the code before you
repeat it to the user. "Codex agreed" is never the user's approval for anything.

**Peer-chat failures.** A pre-write refusal typed nothing, so retrying later is safe (a busy Codex
often shows a status row the script will not type over). A submit or acceptance failure is ambiguous:
read the pane before sending again, so Codex never gets the same message twice.

## When to ask the user

The user is away; a question that waits for hours costs more than most wrong guesses. Ask only for:

- a product or pricing decision with no safe default, or one that contradicts another open PR;
- anything destructive, in production, with credentials or payments, or a deploy;
- a permission or tool that stays blocked after two different attempts;
- a disagreement with Codex that changes user-visible behaviour and survived two rounds.

Everything else: decide, write it under **Decisions** in the plan, and continue. When you do ask while
the user is away, send `agtermctl notify` with the question, then keep working on everything that does
not depend on the answer. Put the question in your report too, so it is the first thing they see.

## When the pane chat is impossible

If peer-chat cannot reach Codex after the Phase 0 fixes, or the sandbox keeps blocking the agterm
socket, read `references/fallback.md` and run the rounds that way. Tell the user in one line.
