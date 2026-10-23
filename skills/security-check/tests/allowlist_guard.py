#!/usr/bin/env python3
"""The allowlist guard of tests/inventory_test.sh: reads remote-inventory.sh line by line and
checks that it runs only allowed external commands, and nothing that can write or start things.
It also refuses here-strings ("<<<": bash before 5.1 writes them to a temp file) and "< $file"
(a file named by a variable is read only through read_plain: no symlink, no FIFO wait).
From /proc it allows only /proc/<pid>/exe and /proc/self/cwd (the script's own folder).

Usage:
  allowlist_guard.py <script> "<allowed commands, space separated>" [--list]

Prints one line per problem; exit 1 when there is any. --list also prints
"uses: <allowed commands found>", so the test can check that the guard sees every command.
"""
import re, shlex, sys

path, allowed = sys.argv[1], set(sys.argv[2].split())
BUILTINS = {"echo", "printf", "read", "local", "declare", "set", "shift", "return", "exit",
            "test", "[", "true", "false", "mapfile", "readarray", "unset", "export",
            "break", "continue", "command", "cd"}
FORBIDDEN = {"pm2", "nvm", "npm", "npx", "systemctl", "service", "rm", "apt", "sudo",
             "eval", "source", ".", "exec", "bash", "sh", "xargs", "env", "tee", "curl", "wget"}
PREFIX_KW = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "time"}
END_KW = {"fi", "done", "}"}
OUT_REDIR = {">", ">>", "&>", "&>>", ">|"}
DUP_REDIR = {">&", "<&"}
PUNCT = set(";&|()<>")
VAR = "__VAR__"
PSUB = "__PSUB__"   # a process substitution <( ): a pipe, fine after "<"
errors = []
FOUND = set()

def err(lineno, msg):
    errors.append(f"line {lineno}: {msg}")

def find_close(s, k, lineno):
    """Index of the ")" that closes the "(" just before s[k]."""
    depth, i, n, dq = 1, k, len(s), False
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if dq:
            if c == '"':
                dq = False
            elif c == "$" and s[i + 1:i + 2] == "(":
                i = find_close(s, i + 2, lineno) + 1
                continue
            i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = (j if j >= 0 else n) + 1
            continue
        if c == '"':
            dq = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    err(lineno, "unbalanced '(' in: " + s.strip())
    return n

def scan(s, lineno):
    """Cut the comment; replace each $( ) with VAR and each <( ) with PSUB.
    Returns (outer text, inner texts)."""
    out, inners, i, n, quote = [], [], 0, len(s), None
    while i < n:
        c = s[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\":
            out.append(s[i:i + 2])
            i += 2
            continue
        if c == "`":
            err(lineno, "backticks are not allowed")
            i += 1
            continue
        if c == "'" and quote is None:
            quote = "'"
        elif c == '"':
            quote = None if quote == '"' else '"'
        elif c == "#" and quote is None and (i == 0 or s[i - 1] in " \t;&|("):
            break
        elif s[i + 1:i + 2] == "(" and (c == "$" or (quote is None and c in "<>")):
            if c == ">":
                err(lineno, "process substitution >( ) is not allowed")
            j = find_close(s, i + 2, lineno)
            if c == "$" and s[i + 2:i + 3] == "(":
                # $(( arithmetic )): not a command, but a $( ) inside it is
                inners.extend(scan(s[i + 3:j - 1], lineno)[1])
            else:
                inners.append(s[i + 2:j])
            out.append(VAR if c == "$" else PSUB)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), inners

def strip_redirections(toks, lineno):
    res, i = [], 0
    while i < len(toks):
        t = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) else ""
        if t in OUT_REDIR:
            if nxt != "/dev/null":
                err(lineno, f"writes to a file: {t} {nxt}")
            i += 2
        elif t in DUP_REDIR:
            if not re.fullmatch(r"[0-9]+|-", nxt):
                err(lineno, f"redirection to a file: {t} {nxt}")
            i += 2
        elif t == "<":
            if VAR in nxt:
                err(lineno, f"reads a file named by a variable: < {nxt} (use read_plain)")
            i += 2
        elif t == "<<<":
            err(lineno, "here-strings are not allowed (bash before 5.1 writes them to a temp file)")
            i += 2
        elif t == "<<" or t == "<<-":
            err(lineno, "heredocs are not allowed")
            i += 1
        else:
            res.append(t)
            i += 1
    return res

def is_sep(t):
    return t != "" and all(ch in PUNCT for ch in t)

def check_command(cmd, args, lineno):
    if VAR in cmd:
        err(lineno, f"command from a variable: {cmd}")
        return
    if cmd in FORBIDDEN:
        err(lineno, f"forbidden command: {cmd}")
        return
    if cmd in FUNCS:
        return
    if cmd == "command":
        if args and args[0] in ("-v", "-V"):
            return
        if args:
            check_command(args[0], args[1:], lineno)
        return
    if cmd in BUILTINS:
        return
    if cmd not in allowed:
        err(lineno, f"command not on the allowlist: {cmd}")
        return
    FOUND.add(cmd)
    words = [a for a in args if not a.startswith("-")]
    if cmd == "timeout":
        rest, k = list(args), 0
        while k < len(rest) and rest[k].startswith("-"):
            k += 2 if rest[k] in ("-s", "-k") else 1
        rest = rest[k + 1:]  # drop the duration
        if rest:
            check_command(rest[0], rest[1:], lineno)
    elif cmd == "docker":
        if not words or words[0] not in ("ps", "images"):
            err(lineno, f"docker only runs 'ps' and 'images', got: {' '.join(args)}")
    elif cmd == "apt-get":
        if "--simulate" not in args:
            err(lineno, "apt-get runs only with --simulate")
    elif cmd == "find":
        bad = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"}
        if bad & set(args):
            err(lineno, f"find may not use {sorted(bad & set(args))}")
    elif cmd == "sort":
        if any(re.match(r"-[A-Za-z]*o|--output", a) for a in args):
            err(lineno, "sort may not write a file (-o)")
    elif cmd == "date":
        if any(re.match(r"-[A-Za-z]*s|--set", a) for a in args):
            err(lineno, "date may not set the clock (-s)")
    elif cmd == "dd":
        flags = [set(a[len("iflag="):].split(",")) for a in args if a.startswith("iflag=")]
        if any(a.startswith(("of=", "oflag=", "seek=", "conv=")) for a in args):
            err(lineno, "dd may only read: no of=, oflag=, seek= or conv=")
        elif not any({"nofollow", "nonblock"} <= f for f in flags):
            err(lineno, "dd reads only with iflag=nofollow,nonblock")

def check_line(text, lineno):
    outer, inners = scan(text, lineno)
    for inner in inners:
        check_line(inner, lineno)
    try:
        lex = shlex.shlex(outer, posix=True, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError as e:
        err(lineno, f"cannot parse ({e}): {text.strip()}")
        return
    toks = strip_redirections(toks, lineno)
    i, n, expect = 0, len(toks), True
    while i < n:
        t = toks[i]
        if t == "((" and expect:
            while i < n and toks[i] != "))":
                i += 1
            i += 1
            expect = False
            continue
        if is_sep(t):
            expect = True
            i += 1
            continue
        if not expect:
            i += 1
            continue
        if t == "[[":
            while i < n and toks[i] != "]]":
                i += 1
            i += 1
            expect = False
            continue
        if t in PREFIX_KW:
            i += 1
            continue
        if t in END_KW:
            expect = False
            i += 1
            continue
        if t in ("for", "select"):
            while i < n and not is_sep(toks[i]):
                i += 1
            continue
        if t == "case":
            err(lineno, "'case' is not supported by this guard; use if/elif")
            return
        if re.match(r"[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=", t):
            i += 1
            if t.endswith("=") and i < n and toks[i] == "(":
                # array value: name=( ... ) or name+=( ... )
                while i < n and toks[i] != ")":
                    i += 1
                i += 1
            continue
        if i + 1 < n and toks[i + 1] == "()":
            i += 2
            continue
        j, args = i + 1, []
        while j < n and not is_sep(toks[j]):
            args.append(toks[j])
            j += 1
        check_command(t, args, lineno)
        i, expect = j, False

src = open(path, encoding="utf-8").read()
FUNCS = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)", src, re.M))
for f in sorted(FUNCS & (allowed | FORBIDDEN | BUILTINS)):
    errors.append(f"function '{f}' hides a command of the same name")

lines = src.replace("\\\n", " ").split("\n")
for no, line in enumerate(lines, 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    low = line.lower()
    for word in ("environ", "cmdline", ".env"):
        if word in low:
            err(no, f"reads '{word}'")
    for p in re.findall(r"/proc/[^\s\"')]*", line):
        if not re.fullmatch(r"/proc/(\[0-9\]\*|\$[A-Za-z_]+)(/exe)?|/proc/self/cwd", p):
            err(no, f"reads {p} (only /proc/<pid>/exe and /proc/self/cwd are allowed)")
    norm = line
    while True:
        new = re.sub(r"\$\{[^{}]*\}", VAR, norm)
        if new == norm:
            break
        norm = new
    norm = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*|[0-9#?@*!$-])", VAR, norm)
    check_line(norm, no)

for e in errors:
    print(e)
if len(sys.argv) > 3 and sys.argv[3] == "--list":
    print("uses: " + " ".join(sorted(FOUND)))
sys.exit(1 if errors else 0)
