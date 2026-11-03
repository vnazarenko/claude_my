#!/usr/bin/env python3
"""Say what the Codex pane is doing right now, from its last screen lines. Read-only: it reads
the pane text and never types into it.

Prints one JSON object:
  {"state": "approval" | "working" | "idle" | "unknown" | "error",
   "pending_command": "<the command Codex asks to run, for approval>",
   "outbox": "<path of a peer-chat message file Codex prepared for Claude, if one shows>",
   "tail": "<the last lines of the pane>"}

- approval  Codex is stopped at a "Would you like to run the following command?" prompt. Only the
            user may answer it. `pending_command` says what it wants to run.
- working   Codex is in the middle of a turn ("esc to interrupt" is showing).
- idle      Codex shows an empty prompt and waits for input.
- unknown   none of the above — read `tail` yourself.

Use it at a checkpoint (after your own work, when a reply you asked for has not come), never in a
loop: a reply from Codex wakes the Claude session by itself.

Usage: peer-state.py [--session ID] [--pane left|right] [--lines N]
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time


def other_pane():
    return "right" if os.environ.get("AGTERM_PANE", "left") in ("left", "primary", "top") else "left"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", default=os.environ.get("AGTERM_SESSION_ID", ""))
    parser.add_argument("--pane", default=other_pane())
    parser.add_argument("--lines", type=int, default=60)
    args = parser.parse_args()
    if not args.session:
        print(json.dumps({"state": "error", "detail": "no --session and no AGTERM_SESSION_ID"}))
        return 2

    done = subprocess.run(
        ["agtermctl", "session", "text", "--target", args.session, "--pane", args.pane, "--lines", str(args.lines)],
        capture_output=True, text=True, timeout=30,
    )
    if done.returncode != 0:
        print(json.dumps({"state": "error", "detail": (done.stderr or done.stdout).strip()}))
        return 2

    lines = [line.rstrip() for line in done.stdout.splitlines()]
    text = "\n".join(lines)
    bottom = "\n".join(line for line in lines[-12:] if line.strip())

    state = "unknown"
    pending = ""
    if "Would you like to run the following command?" in text and re.search(r"Press enter to confirm|Yes, proceed", bottom + text[-1500:]):
        state = "approval"
        commands = [line.strip()[2:] for line in lines if line.strip().startswith("$ ")]
        pending = commands[-1] if commands else ""
    elif re.search(r"esc to interrupt", bottom):
        state = "working"
    elif re.search(r"^\s*›", bottom, re.M) and re.search(r"for shortcuts", bottom):
        state = "idle"

    print(json.dumps({
        "state": state,
        "pending_command": pending,
        "outbox": newest_outbox(),
        "tail": "\n".join(lines[-15:]),
    }, ensure_ascii=False))
    return 0


def newest_outbox(max_age_s=7200):
    """The newest message Codex prepared with `peer-chat.py --prepare-message` and has not sent yet.

    The pane wraps long paths, so the spool directory is listed instead of parsed off the screen. A
    sent message is consumed (`.claimed-*` while in flight), so what is left is unsent.
    """
    dirs = glob.glob(os.path.join(tempfile.gettempdir(), "agterm-peer-chat-*"))
    dirs += glob.glob("/var/folders/*/*/T/agterm-peer-chat-*")
    files = [
        path for directory in set(dirs) for path in glob.glob(os.path.join(directory, "*.txt"))
        if ".claimed-" not in path and os.path.isfile(path)
    ]
    fresh = [path for path in files if time.time() - os.path.getmtime(path) < max_age_s]
    return max(fresh, key=os.path.getmtime) if fresh else ""


if __name__ == "__main__":
    sys.exit(main())
