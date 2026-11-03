#!/usr/bin/env python3
"""The Jira ticket's own text, for task-cleanup step 5: is it true, testable and e2e-covered?

    ticket-doc.py check <KEY>                facts about the description (read-only)
    ticket-doc.py show  <KEY>                the description as markdown (read-only)
    ticket-doc.py set   <KEY> <file.md> [--summary TEXT] [--dry-run]
    ticket-doc.py restore <KEY> <backup.json>

`set` saves the CURRENT description first, to
~/.claude/task-briefs/description-backups/<KEY>-<time>.json, then writes the new one. `restore`
puts a backup back. jira.py (JIRA_PY, the same one new-task uses) gives the login and the HTTP
calls; this file only converts markdown <-> Atlassian Document Format (ADF).

jira.py's own `create` / `comment` turn every paragraph into one line of plain text, so a table or
a numbered test case comes out as one long line. Here headings, lists, tables, **bold**, `code`
and links stay what they are.

`check` prints facts, and judges nothing. It looks for these parts of the description:
  ## Expected result            what is true now
  ## Decided during the work    the decisions taken after the ticket was written
  ## How to test                cases written as `### <n>. <title>`, each with a `- e2e:` line
and for a link to a test-plan doc (docs/test-plans/...).
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

JIRA_PY = os.environ.get(
    "JIRA_PY", str(Path.home() / "code/Orthhank") + "/.claude/skills/jira-tickets/scripts/jira.py"
)
BRIEFS = Path(os.environ.get("TASK_BRIEFS", str(Path.home() / ".claude" / "task-briefs")))

# --------------------------------------------------------------------------- markdown -> ADF

INLINE = re.compile(r"(\*\*[^*]+\*\*|`[^`]+`|https?://[^\s|)]*[^\s|).,;:!?])")


def inline(text: str) -> list:
    out = []
    for part in INLINE.split(text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**") and len(part) > 4:
            out.append({"type": "text", "text": part[2:-2], "marks": [{"type": "strong"}]})
        elif part.startswith("`") and part.endswith("`") and len(part) > 2:
            out.append({"type": "text", "text": part[1:-1], "marks": [{"type": "code"}]})
        elif re.match(r"https?://", part):
            out.append({"type": "text", "text": part, "marks": [{"type": "link", "attrs": {"href": part}}]})
        else:
            out.append({"type": "text", "text": part})
    return out


def para(text: str) -> dict:
    return {"type": "paragraph", "content": inline(text)}


def cells(line: str) -> list:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def md_to_adf(md: str) -> dict:
    """Headings, `- ` lists, `1. ` lists, `|` tables and paragraphs. A line break inside a
    paragraph stays a line break. An indented line continues the list item above it."""
    blocks: list = []
    kind, buf = None, []

    def flush():
        nonlocal kind, buf
        if kind == "p":
            content = []
            for i, line in enumerate(buf):
                if i:
                    content.append({"type": "hardBreak"})
                content.extend(inline(line))
            blocks.append({"type": "paragraph", "content": content})
        elif kind in ("ul", "ol"):
            node = {"type": "bulletList" if kind == "ul" else "orderedList",
                    "content": [{"type": "listItem", "content": [para(item)]} for item in buf]}
            if kind == "ol":
                node["attrs"] = {"order": 1}
            blocks.append(node)
        elif kind == "table":
            rows = [r for r in buf if not re.fullmatch(r"\|?[\s:|-]+\|?", r.strip())]
            width = max(len(cells(r)) for r in rows)
            content = []
            for n, row in enumerate(rows):
                cs = cells(row) + [""] * (width - len(cells(row)))
                cell_type = "tableHeader" if n == 0 else "tableCell"
                content.append({"type": "tableRow", "content": [
                    {"type": cell_type, "attrs": {}, "content": [para(c)]} for c in cs]})
            blocks.append({"type": "table", "attrs": {"isNumberColumnEnabled": False, "layout": "default"},
                           "content": content})
        kind, buf = None, []

    for raw in md.splitlines():
        line = raw.rstrip()
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        bullet = re.match(r"^- (.*)$", line)
        number = re.match(r"^\d+\.\s+(.*)$", line)
        if not line.strip():
            flush()
        elif heading:
            flush()
            blocks.append({"type": "heading", "attrs": {"level": len(heading.group(1))},
                           "content": inline(heading.group(2))})
        elif line.lstrip().startswith("|"):
            if kind != "table":
                flush()
                kind = "table"
            buf.append(line)
        elif bullet or number:
            want = "ul" if bullet else "ol"
            if kind != want:
                flush()
                kind = want
            buf.append((bullet or number).group(1))
        elif kind in ("ul", "ol") and raw.startswith("  "):
            buf[-1] += " " + line.strip()
        else:
            if kind != "p":
                flush()
                kind = "p"
            buf.append(line)
    flush()
    return {"type": "doc", "version": 1, "content": blocks or [{"type": "paragraph", "content": []}]}

# --------------------------------------------------------------------------- ADF -> markdown


def text_of(nodes) -> str:
    out = []
    for n in nodes or []:
        t = n.get("type")
        if t == "text":
            s = n.get("text", "")
            for m in n.get("marks") or []:
                if m.get("type") == "strong":
                    s = f"**{s}**"
                elif m.get("type") == "code":
                    s = f"`{s}`"
                elif m.get("type") == "link":
                    href = (m.get("attrs") or {}).get("href", "")
                    if href and href != s:
                        s = f"{s} ({href})"
            out.append(s)
        elif t == "hardBreak":
            out.append("\n")
        elif t in ("inlineCard", "blockCard"):
            out.append((n.get("attrs") or {}).get("url", ""))
        elif t == "mention":
            out.append((n.get("attrs") or {}).get("text", "@someone"))
        elif t == "emoji":
            out.append((n.get("attrs") or {}).get("text", ""))
        else:
            out.append(text_of(n.get("content")))
    return "".join(out)


def item_text(item: dict) -> str:
    parts = []
    for child in item.get("content") or []:
        if child.get("type") in ("bulletList", "orderedList"):
            parts.append("\n" + "\n".join("  " + l for l in block_md(child).splitlines()))
        else:
            parts.append(text_of(child.get("content")))
    return " ".join(p for p in parts if p).replace(" \n", "\n")


def block_md(b: dict) -> str:
    t = b.get("type")
    if t == "heading":
        return "#" * (b.get("attrs") or {}).get("level", 2) + " " + text_of(b.get("content"))
    if t == "bulletList":
        return "\n".join("- " + item_text(i) for i in b.get("content") or [])
    if t == "orderedList":
        start = (b.get("attrs") or {}).get("order", 1)
        return "\n".join(f"{start + n}. " + item_text(i) for n, i in enumerate(b.get("content") or []))
    if t == "table":
        lines = []
        for n, row in enumerate(b.get("content") or []):
            cs = [" ".join(text_of(p.get("content")) for p in c.get("content") or []).replace("|", "\\|")
                  for c in row.get("content") or []]
            lines.append("| " + " | ".join(cs) + " |")
            if n == 0:
                lines.append("|" + "---|" * len(cs))
        return "\n".join(lines)
    if t == "codeBlock":
        return "```\n" + text_of(b.get("content")) + "\n```"
    if t == "rule":
        return "---"
    if t in ("mediaSingle", "mediaGroup"):
        return "[attachment]"
    if t in ("panel", "blockquote", "expand"):
        return "\n\n".join(block_md(c) for c in b.get("content") or [])
    return text_of(b.get("content"))


def adf_to_md(doc) -> str:
    if not doc:
        return ""
    return "\n\n".join(s for s in (block_md(b) for b in doc.get("content") or []) if s.strip()).strip() + "\n"

# --------------------------------------------------------------------------- check


def sections(md: str) -> dict:
    """`## Title` -> its text. A literal "## Title" paragraph (jira.py's create writes those)
    reads the same as a real heading."""
    out, name = {}, None
    for line in md.splitlines():
        m = re.match(r"^##\s+(.*?)\s*$", line)
        if m:
            name = m.group(1)
            out[name] = []
        elif name:
            out[name].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}


def find(secs: dict, *prefixes) -> tuple:
    for k, v in secs.items():
        if any(k.lower().startswith(p) for p in prefixes):
            return k, v
    return None, None


def check(md: str) -> list:
    secs = sections(md)
    lines = [f"description: {len(md.strip())} chars"]
    lines.append("sections: " + (", ".join(secs) or "(none — no `## ` heading)"))
    name, _ = find(secs, "expected result")
    lines.append("expected result: " + ("yes" if name else "MISSING"))
    name, body = find(secs, "decided during the work")
    lines.append("decided during the work: " + (f"yes ({name})" if name else "MISSING"))
    docs = sorted(set(re.findall(r"docs/test-plans/[\w./-]+\.md", md)))
    lines.append("test-plan doc: " + (", ".join(docs) if docs else "none linked"))
    name, body = find(secs, "how to test")
    if not name:
        lines.append("how to test: MISSING")
        return lines
    cases = re.split(r"^###\s+", body, flags=re.M)[1:]
    numbered = [c for c in cases if re.match(r"\d+\.", c)]
    lines.append(f"how to test: {len(numbered)} cases" + ("" if numbered else " — no `### <n>.` case"))
    for case in numbered:
        title = case.splitlines()[0].strip()
        fields = {m.group(1).lower(): m.group(2).strip()
                  for m in re.finditer(r"^- (\w[\w ]*?):\s*(.*)$", case, flags=re.M)}
        missing = [f for f in ("where", "steps", "expected") if f not in fields]
        e2e = fields.get("e2e")
        if e2e is None:
            state = "e2e line MISSING"
        elif re.search(r"web/e2e/|\.spec\.|e2e/", e2e) and not re.match(r"(none|manual)", e2e, re.I):
            state = "e2e: " + e2e
        else:
            state = "e2e GAP or manual: " + e2e
        lines.append(f"  case {title}")
        lines.append(f"    {state}" + (f" | missing: {', '.join(missing)}" if missing else ""))
    return lines

# --------------------------------------------------------------------------- Jira


def jira():
    spec = importlib.util.spec_from_file_location("jira_cli", JIRA_PY)
    if not spec or not Path(JIRA_PY).is_file():
        sys.exit(f"jira.py not found at {JIRA_PY} (set JIRA_PY)")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, mod.load_env()


def fetch(j, env, key: str) -> dict:
    issue = j.api_get(env, f"/rest/api/3/issue/{key}", {"fields": "summary,description"})
    return issue.get("fields") or {}


def backup(key: str, fields: dict) -> Path:
    d = BRIEFS / "description-backups"
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{key}-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}.json"
    p.write_text(json.dumps({"key": key, "summary": fields.get("summary"),
                             "description": fields.get("description")}, indent=1))
    return p


def cmd_set(args, j=None, env=None):
    md = Path(args.file).read_text()
    new = {"description": md_to_adf(md)}
    if args.summary:
        new["summary"] = args.summary
    if args.dry_run:
        print(json.dumps({"fields": new}, indent=1, ensure_ascii=False))
        return
    if j is None:
        j, env = jira()
    saved = backup(args.key, fetch(j, env, args.key))
    print(f"old description saved: {saved}")
    j.api_put(env, f"/rest/api/3/issue/{args.key}", {"fields": new})
    print(f"description of {args.key} updated ({len(md)} chars of markdown)")
    print(f"undo: {sys.argv[0]} restore {args.key} {saved}")


def cmd_restore(args, j=None, env=None):
    data = json.loads(Path(args.backup).read_text())
    if data.get("key") != args.key:
        sys.exit(f"backup is for {data.get('key')}, not {args.key}")
    if j is None:
        j, env = jira()
    fields = {"description": data.get("description")}
    if data.get("summary"):
        fields["summary"] = data["summary"]
    j.api_put(env, f"/rest/api/3/issue/{args.key}", {"fields": fields})
    print(f"{args.key}: description restored from {args.backup}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("check", "show"):
        s = sub.add_parser(name)
        s.add_argument("key")
    s = sub.add_parser("set")
    s.add_argument("key")
    s.add_argument("file")
    s.add_argument("--summary")
    s.add_argument("--dry-run", action="store_true")
    s = sub.add_parser("restore")
    s.add_argument("key")
    s.add_argument("backup")
    args = p.parse_args(argv)

    if args.cmd in ("check", "show"):
        j, env = jira()
        md = adf_to_md(fetch(j, env, args.key).get("description"))
        print(md if args.cmd == "show" else "\n".join(check(md)))
    elif args.cmd == "set":
        cmd_set(args)
    else:
        cmd_restore(args)


if __name__ == "__main__":
    main()
