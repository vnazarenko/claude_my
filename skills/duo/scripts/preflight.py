#!/usr/bin/env python3
"""Check that a Claude + Codex duo can start in this agterm session. Read-only.

Prints one line per check, `OK`, `FIX` (with the command that fixes it) or `WARN`, then exits
0 when nothing blocks the duo and 1 when something does.

Checks, in order:
  1. this shell runs inside agterm (AGTERM_ENABLED, AGTERM_SESSION_ID);
  2. the session is split and the OTHER pane runs codex;
  3. peer-chat.py and both peer-chat SKILL.md files match umputun/agterm master — an old script
     cannot read a newer Codex prompt (two footer rows, the top scroll arrow) and refuses to type;
  4. Codex may send its replies without an approval prompt (a prefix rule for
     `peer-chat.py --to claude`) — without it every reply stalls until a human presses a key —
     and Codex's sandbox can reach the agterm socket, or the rule does not help;
  5. revmux and gh are installed, gh is signed in, and `codex` on PATH is the real codex-cli.

Usage: preflight.py            (run from the Claude pane)
"""

import glob
import json
import os
import shutil
import subprocess
import sys

UPSTREAM = "umputun/agterm"
UPSTREAM_DIR = "cookbook/two-agent-chat"
LOCAL_COPIES = {
    "peer-chat.py": shutil.which("peer-chat.py"),
    "SKILL-claude.md": os.path.expanduser("~/.claude/skills/peer-chat/SKILL.md"),
    "SKILL-codex.md": os.path.expanduser("~/.codex/skills/peer-chat/SKILL.md"),
}
CODEX_RULE = 'prefix_rule(pattern=["peer-chat.py", "--to", "claude"], decision="allow")'

blockers = 0


def say(status, text):
    global blockers
    if status == "FIX":
        blockers += 1
    print(f"{status:4} {text}")


def run(args):
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as err:
        return 1, "", str(err)
    return done.returncode, done.stdout, done.stderr


def find_session(node, sid):
    if isinstance(node, dict):
        if str(node.get("id", "")).upper() == sid.upper():
            return node
        for value in node.values():
            found = find_session(value, sid)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_session(value, sid)
            if found:
                return found
    return None


def runs(foreground, name):
    return isinstance(foreground, list) and any(os.path.basename(str(part)) == name for part in foreground)


def check_agterm():
    sid = os.environ.get("AGTERM_SESSION_ID", "")
    if os.environ.get("AGTERM_ENABLED") != "1" or not sid:
        say("FIX", "not inside agterm — start Claude in an agterm session with Codex in a split pane")
        return None
    say("OK", f"agterm session {sid}, Claude pane {os.environ.get('AGTERM_PANE', '?')}")
    code, out, err = run(["agtermctl", "tree", "--json"])
    if code != 0:
        say("FIX", f"agtermctl tree failed: {err.strip() or out.strip()}")
        return sid
    node = find_session(json.loads(out or "{}"), sid)
    if not node or not node.get("hasSplit"):
        say("FIX", "the session has no split — open one and start `codex` in the other pane (the user does this)")
        return sid
    mine = "foreground" if os.environ.get("AGTERM_PANE", "left") in ("left", "primary", "top") else "splitForeground"
    other = "splitForeground" if mine == "foreground" else "foreground"
    if runs(node.get(other), "codex"):
        say("OK", "codex runs in the other pane")
    else:
        say("FIX", f"the other pane runs {node.get(other)!r}, not codex — start codex there (the user does this)")
    return sid


def check_peer_chat():
    code, out, err = run(["gh", "api", f"repos/{UPSTREAM}/git/trees/master?recursive=1"])
    if code != 0:
        say("WARN", f"cannot read {UPSTREAM} master to compare peer-chat ({err.strip()[:80]}); skipping")
        return
    upstream = {
        entry["path"].rsplit("/", 1)[-1]: entry["sha"]
        for entry in json.loads(out).get("tree", [])
        if entry.get("path", "").startswith(UPSTREAM_DIR + "/")
    }
    for name, path in LOCAL_COPIES.items():
        if not path or not os.path.exists(path):
            say("FIX", f"{name} is not installed (expected {path or 'peer-chat.py on PATH'})")
            continue
        code, local_sha, _ = run(["git", "hash-object", path])
        if upstream.get(name) == local_sha.strip():
            say("OK", f"{name} matches upstream master")
        else:
            raw = f"https://raw.githubusercontent.com/{UPSTREAM}/master/{UPSTREAM_DIR}/{name}"
            say("FIX", f"{name} is older than upstream master — review the diff, then: "
                       f"curl -sfL {raw} -o {path}" + (" && chmod +x " + path if name.endswith(".py") else ""))


def check_codex_rule():
    rules = glob.glob(os.path.expanduser("~/.codex/rules/*.rules"))
    text = "".join(open(path, encoding="utf-8").read() for path in rules)
    if CODEX_RULE in text:
        say("OK", "Codex may send replies to Claude without an approval prompt")
    else:
        say("FIX", "Codex will stop at an approval prompt on every reply. With the user's yes, append to "
                   f"~/.codex/rules/default.rules: {CODEX_RULE}  (then restart codex)")


def check_codex_sandbox():
    # 2026-10-27 (KAN-362): a raw command in Codex's sandbox cannot reach agterm's socket. That is
    # still true, but it is not the reply path: Codex replies with `peer-chat.py --to claude ...`,
    # which the allow rule (check_codex_rule) runs OUTSIDE the sandbox with no prompt. Measured
    # 2026-11-02 with codex-cli 0.166: a sandboxed Codex delivered `peer-chat.py --to claude
    # --message-file ...` into an agterm pane, exit 0, no approval. Until then this check said FIX and
    # every duo session skipped the pane chat for background Codex jobs, so the user saw an idle Codex
    # pane next to every task. So: the raw socket is only a WARN; the rule is what matters.
    code, out, err = run(["codex", "sandbox", "--", "agtermctl", "window", "list", "--json"])
    if code == 0:
        say("OK", "Codex's sandbox can reach the agterm socket")
    elif "Operation not permitted" in out + err:
        say("WARN", "Codex's sandbox blocks a raw agterm call; replies still work, because the allow rule "
                    "runs `peer-chat.py --to claude` outside it. If a reply ever stops at an escalation "
                    "prompt, follow \"When the pane chat is impossible\"")
    else:
        say("WARN", f"could not test Codex's sandbox: {(err or out).strip()[:120]}")


def check_tools():
    for tool in ("revmux", "gh"):
        if shutil.which(tool):
            say("OK", f"{tool} installed")
        else:
            say("FIX", f"{tool} is not installed")
    code, _, err = run(["gh", "auth", "status"])
    if code == 0:
        say("OK", "gh is signed in")
    else:
        say("FIX", f"gh is not signed in: {err.strip().splitlines()[0] if err.strip() else 'run gh auth login'}")
    # revmux runs `codex` from PATH. 2026-10-25 (KAN-262): an unrelated npm package `codex` 0.2.3 sat
    # first on PATH, and revmux's codex agent silently returned nothing.
    code, out, _ = run(["codex", "--version"])
    if code == 0 and "codex-cli" in out:
        say("OK", f"codex on PATH is {out.strip()}")
    else:
        say("FIX", f"`codex` on PATH is not codex-cli ({out.strip() or 'not found'}): "
                   "`npm rm -g codex && npm i -g @openai/codex` under the default Node (the user does this)")


def main():
    check_agterm()
    check_peer_chat()
    check_codex_rule()
    check_codex_sandbox()
    check_tools()
    print(f"\n{'READY' if blockers == 0 else f'{blockers} blocker(s)'}")
    return 0 if blockers == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
