# When the pane chat with Codex is impossible

Read from duo/SKILL.md only when peer-chat cannot reach Codex.

If peer-chat cannot reach Codex after the Phase 0 fixes (no split, script refusing, the user cannot be
reached to fix it), run the same rounds through the `codex:codex-rescue` agent in **read-only** mode,
as a FRESH task per round (`--fresh`, the round's context restated in the prompt, never `--resume-last`), and tell the user in one line that the conversation is not
visible in the pane. Switch back to the pane as soon as it works, and brief the pane Codex with what
was decided. A fallback task can hang: check it with `codex-companion.mjs status <task-id>`; when its
log is silent for 5 minutes, `cancel` it and start a fresh task instead of resuming the thread again.
The `codex-rescue` agent's own call stops at 10 minutes, and it then goes idle without reporting. Run a
round yourself instead: `codex-companion.mjs task --background --fresh "<prompt>"` (read-only
without `--write`), wait with `scripts/codex-wait.sh <job>` in the background (exit 3 = silent 5 min:
cancel, start fresh), then read `result <job>`. Never a hand-written wait loop: it forgets the silence check.
Never a bare `codex exec` either: in a background shell it waits on stdin and logs nothing.
