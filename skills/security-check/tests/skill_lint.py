#!/usr/bin/env python3
"""Lint the security-check skill. Run it through skill_lint.sh (that file checks the arguments).

Usage:
  skill_lint.py <SKILL_DIR> <PRIVATE_WORDS_FILE>

The skill lives in a PUBLIC repo, so this also checks that no private detail is in it.

Checks:
1. SKILL.md frontmatter: starts with "---", has "name" (= the folder name) and a
   "description" that says when to use the skill.
2. Every skill file that SKILL.md or references/*.md names (scripts/..., references/...,
   tests/...) exists, and every file in scripts/ is named in SKILL.md.
3. references/run-brief.md uses only the placeholders that new-task's start-task.sh fills.
4. Public-repo rules, in every file of the skill:
   - no IPv4 address. Allowed: 127.0.0.1, 0.0.0.0 and the documentation ranges
     (192.0.2, 198.51.100, 203.0.113). tests/fixtures/ is skipped for this check only,
     because package versions there look like IPs.
   - no links to claude dot ai, no Claude-Session trailer, no Jira (atlassian) links
   - no macOS home paths (a slash, "Users", a slash and a name)
   - no word from the private list (one word per line, "#" comments, matched without case).
     The list is local and never committed. Missing file: a warning, and that check is skipped.

Prints one line per problem. Exit 0 clean, 1 a check failed.
"""
import os, re, sys

skill, words_file = sys.argv[1], sys.argv[2]
skill = os.path.realpath(skill)
name = os.path.basename(skill)
problems = []


def fail(check, where, what):
    problems.append(f"FAIL {check}: {where}: {what}")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def rel(path):
    return os.path.relpath(path, skill)


# Every file of the skill, except Python caches.
files = []
for root, dirs, names in os.walk(skill):
    dirs[:] = sorted(d for d in dirs if d not in ("__pycache__", ".git"))
    for n in sorted(names):
        if n.endswith(".pyc") or n == ".DS_Store":
            continue
        files.append(os.path.join(root, n))

skill_md = read(os.path.join(skill, "SKILL.md"))

# ---- 1. frontmatter ---------------------------------------------------------------------------

lines = skill_md.split("\n")
if not lines or lines[0].strip() != "---":
    fail("frontmatter", "SKILL.md", "does not start with ---")
else:
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        end = None
        fail("frontmatter", "SKILL.md", "no closing ---")
    if end is not None:
        fm, key = {}, None
        for line in lines[1:end]:
            m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
            if m:
                key = m.group(1)
                fm[key] = m.group(2).strip()
            elif key and line.startswith((" ", "\t")):
                fm[key] = (fm[key] + " " + line.strip()).strip()
        if fm.get("name") != name:
            fail("frontmatter", "SKILL.md", f"name must be '{name}', is '{fm.get('name', '')}'")
        desc = fm.get("description", "")
        if desc in ("", ">", "|", ">-", "|-"):
            fail("frontmatter", "SKILL.md", "description is missing or empty")
        elif not re.search(r"\buse (it )?(when|whenever)\b|\btrigger", desc, re.IGNORECASE):
            fail("frontmatter", "SKILL.md", "description does not say when to use the skill")

# ---- 2. referenced files ----------------------------------------------------------------------

# A path of this skill: bare (not inside another path), or after $SKILL/ or the installed path.
REF_RE = re.compile(
    r"(?:(?<=\$SKILL/)|(?<=skills/" + re.escape(name) + r"/)|(?<![\w./$~-]))"
    r"((?:scripts|references|tests)/[\w.-]+(?:/[\w.-]+)*)")
docs = [os.path.join(skill, "SKILL.md")]
ref_dir = os.path.join(skill, "references")
if os.path.isdir(ref_dir):
    docs += [os.path.join(ref_dir, n) for n in sorted(os.listdir(ref_dir)) if n.endswith(".md")]
for doc in docs:
    for no, line in enumerate(read(doc).split("\n"), 1):
        for m in REF_RE.finditer(line):
            ref = m.group(1).rstrip(".")
            if not os.path.exists(os.path.join(skill, ref)):
                fail("reference", f"{rel(doc)}:{no}", f"names {ref}, which does not exist")

scripts_dir = os.path.join(skill, "scripts")
if os.path.isdir(scripts_dir):
    for n in sorted(os.listdir(scripts_dir)):
        if n == "__pycache__":
            continue
        if f"scripts/{n}" not in skill_md:
            fail("reference", "SKILL.md", f"does not describe scripts/{n}")

# ---- 3. run-brief placeholders ----------------------------------------------------------------

FILLED = {"KEY", "URL", "REPO", "WORKTREE", "BRANCH", "SESSION_ID", "JIRA_PY", "REGISTRY", "PROCS"}
brief = os.path.join(skill, "references", "run-brief.md")
if os.path.exists(brief):
    for no, line in enumerate(read(brief).split("\n"), 1):
        for ph in re.findall(r"\{\{([^}]*)\}\}", line):
            if ph not in FILLED:
                fail("placeholder", f"references/run-brief.md:{no}",
                     f"{{{{{ph}}}}} is not filled by start-task.sh")

# ---- 4. public-repo rules ---------------------------------------------------------------------

IP_RE = re.compile(r"(?<![\w.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\w-])(?!\.\d)")
IP_OK = ("127.0.0.1", "0.0.0.0")
IP_OK_PREFIX = ("192.0.2.", "198.51.100.", "203.0.113.")
PATTERNS = [
    ("session link", re.compile(r"claude\.ai/|//claude\.ai\b", re.IGNORECASE)),
    ("session trailer", re.compile(r"Claude-Session\s*:", re.IGNORECASE)),
    ("jira link", re.compile(r"atlassian\.net/", re.IGNORECASE)),
    ("home path", re.compile(r"/Users/[\w.-]")),
]

private = []
if os.path.isfile(words_file):
    for w in read(words_file).split("\n"):
        w = w.strip()
        if w and not w.startswith("#"):
            private.append(w.lower())
else:
    print(f"WARN: private word list not found ({words_file}); that check is skipped")

for path in files:
    r = rel(path)
    in_fixtures = r.startswith("tests/fixtures/")
    for no, line in enumerate(read(path).split("\n"), 1):
        where = f"{r}:{no}"
        if not in_fixtures:
            for m in IP_RE.finditer(line):
                ip = m.group(0)
                if all(int(o) <= 255 for o in m.groups()) and ip not in IP_OK \
                        and not ip.startswith(IP_OK_PREFIX):
                    fail("ip address", where, ip)
        for check, rx in PATTERNS:
            if rx.search(line):
                fail(check, where, "not allowed in a public repo")
        low = line.lower()
        for w in private:
            if w in low:
                fail("private word", where, "a word from the private list")

for p in problems:
    print(p)
if problems:
    print(f"skill_lint: {len(problems)} problem(s) in {skill}")
    sys.exit(1)
print(f"skill_lint: ok ({len(files)} files)")
