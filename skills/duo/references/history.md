# History behind duo/SKILL.md

Moved out of SKILL.md on 2026-11-03 (token audit): the skill stays in the task session's context for
every call. Keep the rules in SKILL.md and add new "Why" stories here.

## Why one writer

Why one writer: two writers in one worktree lose each other's edits. Why only Claude runs suites: test
databases are shared on the machine, and two suites at once corrupt each other with failures that look
real.

## Phase 1 — open PRs

**Why this exists:** 2026-10-27, KAN-271: #135 replaced the Live charts page while #136 was open; the chart was rebuilt.

## Phase 1 — new-worktree.sh

**Why this exists:** 2026-10-27 (KAN-272), a hand-made investviews worktree had no `web/.env.local` and `pnpm build` failed; KAN-268 and KAN-271 hit the same.

## Phase 1 — measure on the real input

**Why this exists:** 2026-11-02 (KAN-427), KAN-354 sized its slider
   top on Kyiv's bounding box; the app reads the screen plus a cheaper ring, so the top was too low.

## Coverage — named items

**Why this exists:** 2026-11-01 (KAN-257),
"visx / Recharts + custom brush" became one candidate; visx was never compared, and the independent review sent it back.

## Coverage — scope expansion

**Why this exists:** 2026-11-01, KAN-373: four such Codex-agreed changes were cut by the user after the independent review, discarding three review rounds. KAN-354: F3–F8 and N1 (a linear track, a rounded bottom, new Home/End and focus behaviour) cost two independent review rounds. KAN-394: "clear the band the way KAN-391 clears the price ranges" — KAN-391 kept area ranges, but area bands were cleared too; the manager reverted it, one extra review round. KAN-401: the guard removed a TypeError, so no-area listings main had dropped were imported; that moved two legacy-report figures and was cut after the independent review. KAN-314: a new "must be a tracked symlink" error and a `GIT_*` unset, both from Codex findings, were judged NOT IN SPEC and cut.

## Phase 3 — stacked PR for a pending choice

**Why this exists:** 2026-10-27,
   KAN-258's board default (Q1 = A) rode inside #127, shipped and deployed via #135; the user chose B.

## Phase 3 — mid-task PR search

**Why this exists:** 2026-10-27, KAN-357 built the stale-selection fix that KAN-362 (#145, opened after
intake) merged first; the duplicate was dropped in the merge.

## Phase 4 — mutation check

**Why this exists:** 2026-11-01,
  KAN-391: a full unit run during a live mutation run reported 5 false failures and had to be redone.

## Phase 6 — Playwright serial

**Why:** 2026-11-02 (KAN-424), the new test passed alone but never ran in its file; the review sent it back.

## Phase 6 — vtserv

**Why this exists:**
  2026-10-27, KAN-372 started full stubbed + live suites at load ~200 on the Mac; 2026-11-01,
  KAN-394's seed ran over KAN-393's live run. KAN-387 moved the runs to vtserv.

## Phase 7 — draft PR

**Why this exists:** 2026-11-02 (KAN-412), tests-only investviews#173 was
   merged before backend #436, so its live specs failed on main until #436 was reopened and merged.

## Phase 7 — gh in Codex sandbox

**Why this exists:** 2026-11-02 (KAN-333), the pane Codex froze on `gh pr diff 440`.

## Codex pane — socket fallback

**Why this exists:**
2026-10-28, KAN-357: three replies froze there; one review waited ~1 h.

## Codex pane — pane chat is default

**Why:** 2026-11-02 every duo session read the
old FIX line, skipped the pane, ran Codex as background jobs, and the user saw an idle Codex pane in
every task ("claude do not talk with codex ... they should work together").

## Fallback — fresh tasks

**Why this exists:** 2026-10-27 (KAN-362), a resumed review logged nothing for 10 minutes; a fresh task answered in 3.
2026-11-02 (KAN-404), resumed rounds 3 and 4 both went silent for 10+ minutes; all seven fresh tasks answered in 2–5.

## Fallback — codex-wait.sh

**Why this exists:** 2026-11-01 (KAN-356), round 4 was cut at 10 minutes and the agent went idle twice; the direct `task --background` rounds answered in 2–3 minutes.
2026-11-01 (KAN-393), a hand-written wait loop had no silence check; a hung round 2 was noticed after 30 minutes.

## Fallback — codex exec

**Why:** 2026-11-02 (KAN-387), two `codex exec` checks hung 36 and 67 min until the manager found them.

## Review policy before 2026-11-03

Each round ran revmux and Codex in parallel inside the task session, at least two plan rounds, up to
four code rounds, then the manager's independent revmux review on top. Token audit 2026-11-03: 26
in-session revmux rounds on 2026-11-02 (~1.2M weighted tokens each); the independent review still
found new blockers after Codex "code approved" in 3 of 4 PRs (KAN-434, KAN-427, KAN-428 #446).

## Lessons this skill is built on (2026-10-23)

- An outdated `peer-chat.py` could not read Codex's prompt (two footer rows) and refused every send.
- Codex's replies failed with `no such session` until it was told the exact `--session`.
- Codex froze at an approval prompt for its own reply: its allow-rule matched `--to claude
  --message-file` but the reply put `--session` first.
- The first code review round found a real bypass (a stricter parser in the guard than in the code it
  guarded). Two independent reviews catch what one misses.
- Pre-existing e2e failures were only trusted after the same failures reproduced on clean `main`.
