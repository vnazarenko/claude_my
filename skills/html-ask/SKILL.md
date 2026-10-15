---
name: html-ask
description: >
  Ask the user a decision question as a good-looking HTML page in an agterm overlay instead of plain
  terminal text, with option cards, pros/cons and wireframe mockups, and get the answer back as JSON.
  Use INSTEAD of AskUserQuestion whenever running inside agterm (AGTERM_ENABLED=1) and you need the user
  to choose: brainstorm questions, approach choices, design reviews ("is this part right?"), UI layout
  options. Always use it when the question is about how something will LOOK — draw the mockup.
when_to_use: >
  Trigger on: any multiple-choice question to the user, brainstorm / design / plan questions, "which
  approach", "is this right", UI or page layout decisions, the user asking to see options or mockups
  visually, "show it in html", "overlay". Falls back to AskUserQuestion outside agterm.
allowed-tools: Bash(bash ~/.claude/skills/html-ask/scripts/ask.sh *), Bash(agtermctl *)
---

# html-ask — questions as an HTML overlay

## When

Use this for every question where the user picks between options, **when `AGTERM_ENABLED=1`**.
Outside agterm, use `AskUserQuestion` as usual.

Still ask **one question per page**. Do not stack several questions into one page.

## How

1. Write only the `<body …>` block (copy it from `template.html`: header, options, and the `.foot`
   block with notes / Cancel / Submit) to the scratchpad as `q-<topic>.body.html`, then build:

   ```bash
   python3 ~/.claude/skills/html-ask/scripts/build.py q-topic.body.html q-topic.html "Short title"
   ```

   It adds the template's head, CSS and script, and refuses to write a broken page.
2. Per option, write a `<section class="opt" data-id="…">` with:
   - a short title, and a `Recommended` badge on the first one when you recommend it;
   - one line on what it does;
   - **a mockup** (`<div class="mock">`) whenever the option changes something visible. Build it from
     the `.w-*` wireframe kit in the template (`w-bar`, `w-side`, `w-card`, `w-btn`, `w-chip`,
     `w-input`, `w-steps`, `w-grid`, `w-img`, `w-line`) or inline SVG. Show real labels and real
     example values, not lorem ipsum. Use `.mock.big` for a full-width page mock;
   - pros / cons, 1–3 short bullets each.
3. For a **design review** ("is this part right?"), use one big mock of the whole page as the first
   block (inside `.context`, or a full-width `.opt` with `grid-column: 1 / -1`), then options like
   `ok` = "Looks right", `change` = "Change something" (the notes box carries what).
4. Open it and wait, **in the background** so the user can take their time:

   ```bash
   bash ~/.claude/skills/html-ask/scripts/ask.sh /path/to/q-topic.html   # Bash run_in_background: true
   ```

   **The overlay does not switch the user to this session.** It opens in place and waits. The user
   may be working in another session; they come to this one when they want and see the page then.
   While the question is open, the session is marked `blocked` in the sidebar (blinking glyph, one
   sound) and a desktop notification is posted once, so the session is easy to find.

   Then end your turn with one short line: "Question is open in the overlay of this session." The
   harness wakes you when the user answers. Read the background command's output then.
5. Parse the output:

   | exit | output | meaning |
   |---|---|---|
   | 0 | `{"outcome":"submitted","value":"{\"choice\":[\"a\"],\"notes\":\"…\"}"}` | chose `a` (+ notes) |
   | 0 | `…"value":"{\"other\":\"…\"}"` | free-text answer, no option |
   | 2 | `{"outcome":"dismissed"}` | closed without answering — ask in the terminal, briefly |
   | 3 | `{"outcome":"unavailable"}` | not in agterm — use `AskUserQuestion` |

   `value` is a JSON string inside JSON: decode it twice.

## Rules

- Plain, simple English on the page: short sentences, common words (the user is not a native speaker).
- The page takes the terminal theme through `--agterm-*` CSS variables. Never declare `--agterm-*`.
- Self-contained page: inline CSS, inline SVG. No CDN, no file access.
- Edit the copy with the Edit tool. If you splice it with a script, match the real tags on their own
  line (`\n<body`, `\n<script>`), and check the result still has `<style>`, `<body` and `<script>`.
  A broken splice leaves an open `<!--` and the overlay shows a blank page with no controls.
- Escape any outside text (issue bodies, logs, user data) you put on the page — the page can run
  agterm commands.
- Do not repeat the whole page as text in the terminal. One line saying it is open is enough.
- To change a page after the user comments, write a new file and run `ask.sh` again (it closes the
  stale overlay first).
- **Never pull the user's focus to the question.** Do not call `agtermctl session select`,
  `session go` or `overlay open --follow` yourself, and do not set `HTML_ASK_FOLLOW=1` unless the
  user asks to be taken to the question. `HTML_ASK_SOUND=off` mutes the attention sound.
