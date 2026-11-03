#!/usr/bin/env python3
"""Tests for scripts/ticket-doc.py. No network: Jira is a fake object.

    python3 -I tests/ticket_doc_test.py

1. markdown -> ADF: headings, a table (separator row dropped), both list kinds, line breaks, marks
2. a link does not swallow the full stop after it
3. markdown -> ADF -> markdown gives the same text back
4. check, complete ticket: sections found, cases counted, each case's e2e state
5. check, a case with no e2e line, or with missing fields, is named
6. check, the old flat ticket text: "How to test" and "Decided" MISSING, "Expected result" found
7. check, a linked docs/test-plans/ file is reported
8. set saves the old description BEFORE it writes the new one; --dry-run calls nothing
9. restore refuses a backup of another ticket
"""
import argparse
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ticket_doc", HERE.parent / "scripts" / "ticket-doc.py")
td = importlib.util.module_from_spec(spec)
spec.loader.exec_module(td)

GOOD = """## Summary
Live charts showed **Sep 2026** as the newest month.

## Expected result
- October appears after the build on the 5th.

## Decided during the work (2026-11-02)
- O1: keep the build on the 5th.

## How to test
Account: a Pro account.

### 1. Ireland says why
- Where: https://investviews.ai/live-charts?places=ie&period=1y
- Steps: open the chart, Table tab, hover Sep 2026
- Expected: "Not enough earlier data to check this period"
- e2e: web/e2e/live/live-charts-eur-gap.spec.ts › "a month with too little earlier history" (live)

### 2. Austria says why
- Where: https://investviews.ai/live-charts?places=at&period=1y
- Steps: as in case 1
- Expected: "Listing counts here changed too much to check this period"
- e2e: none — unit only. Follow-up: KAN-999

### 3. October after the 5th
- Where: https://investviews.ai/live-charts?places=at,es
- Steps: look at the newest month
- Expected: Oct 2026
- e2e: manual only — production schedule
"""

OLD_FLAT = """## Summary
Live charts: newest month is Sept 2026.
## Expected result
In November the latest closed month is **October 2026**, and it is shown.
## What to find
1. Did the monthly rebuild run?
"""


class FakeJira:
    def __init__(self):
        self.calls = []

    def api_get(self, env, path, params=None):
        self.calls.append(("GET", path))
        return {"fields": {"summary": "old title", "description": td.md_to_adf("## Expected result\nold text")}}

    def api_put(self, env, path, body):
        self.calls.append(("PUT", path, body))
        return {}


class MarkdownToAdf(unittest.TestCase):
    def test_blocks(self):
        doc = td.md_to_adf("## Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n- x\n- y\n\n1. one\n2. two\n\nline 1\nline 2")
        types = [b["type"] for b in doc["content"]]
        self.assertEqual(types, ["heading", "table", "bulletList", "orderedList", "paragraph"])
        self.assertEqual(doc["content"][0]["attrs"]["level"], 2)
        rows = doc["content"][1]["content"]
        self.assertEqual(len(rows), 2, "the |---| row is not a row")
        self.assertEqual([c["type"] for c in rows[0]["content"]], ["tableHeader", "tableHeader"])
        self.assertEqual([c["type"] for c in rows[1]["content"]], ["tableCell", "tableCell"])
        self.assertEqual(len(doc["content"][2]["content"]), 2)
        self.assertIn({"type": "hardBreak"}, doc["content"][4]["content"])

    def test_marks(self):
        nodes = td.inline("see **bold**, `code` and https://example.com/a?b=1.")
        marks = {n["text"]: [m["type"] for m in n.get("marks", [])] for n in nodes}
        self.assertEqual(marks["bold"], ["strong"])
        self.assertEqual(marks["code"], ["code"])
        self.assertEqual(marks["https://example.com/a?b=1"], ["link"], "the full stop is not part of the link")
        self.assertEqual(nodes[-1]["text"], ".")

    def test_round_trip(self):
        # adf_to_md puts a blank line between all blocks; the text itself must not change
        lines = lambda s: [l for l in s.splitlines() if l.strip()]
        self.assertEqual(lines(td.adf_to_md(td.md_to_adf(GOOD))), lines(GOOD))


class Check(unittest.TestCase):
    def test_complete(self):
        out = "\n".join(td.check(GOOD))
        self.assertIn("expected result: yes", out)
        self.assertIn("decided during the work: yes (Decided during the work (2026-11-02))", out)
        self.assertIn("how to test: 3 cases", out)
        self.assertIn("e2e: web/e2e/live/live-charts-eur-gap.spec.ts", out)
        self.assertIn("e2e GAP or manual: none — unit only. Follow-up: KAN-999", out)
        self.assertIn("e2e GAP or manual: manual only — production schedule", out)
        self.assertIn("test-plan doc: none linked", out)

    def test_case_without_e2e_or_fields(self):
        md = "## How to test\n\n### 1. Something\n- Where: /x\n- Expected: y\n"
        out = "\n".join(td.check(md))
        self.assertIn("e2e line MISSING | missing: steps", out)

    def test_old_flat_text(self):
        out = "\n".join(td.check(OLD_FLAT))
        self.assertIn("expected result: yes", out)
        self.assertIn("decided during the work: MISSING", out)
        self.assertIn("how to test: MISSING", out)

    def test_doc_link(self):
        md = "## How to test\nThe cases are in docs/test-plans/KAN-1.md (link).\n"
        out = "\n".join(td.check(md))
        self.assertIn("test-plan doc: docs/test-plans/KAN-1.md", out)
        self.assertIn("how to test: 0 cases", out)


class SetAndRestore(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        td.BRIEFS = Path(self.tmp.name)
        self.md = Path(self.tmp.name) / "new.md"
        self.md.write_text(GOOD)

    def tearDown(self):
        self.tmp.cleanup()

    def test_set_backs_up_first(self):
        fake = FakeJira()
        args = argparse.Namespace(key="KAN-1", file=str(self.md), summary=None, dry_run=False)
        with redirect_stdout(io.StringIO()):
            td.cmd_set(args, fake, {})
        self.assertEqual([c[0] for c in fake.calls], ["GET", "PUT"])
        backups = list((Path(self.tmp.name) / "description-backups").glob("KAN-1-*.json"))
        self.assertEqual(len(backups), 1)
        saved = json.loads(backups[0].read_text())
        self.assertEqual(saved["summary"], "old title")
        self.assertEqual(td.adf_to_md(saved["description"]).strip(), "## Expected result\n\nold text")
        body = fake.calls[1][2]
        self.assertEqual(set(body["fields"]), {"description"}, "no --summary: the title is not touched")
        self.assertEqual(body["fields"]["description"]["type"], "doc")

    def test_dry_run_calls_nothing(self):
        fake = FakeJira()
        args = argparse.Namespace(key="KAN-1", file=str(self.md), summary="new title", dry_run=True)
        out = io.StringIO()
        with redirect_stdout(out):
            td.cmd_set(args, fake, {})
        self.assertEqual(fake.calls, [])
        self.assertEqual(json.loads(out.getvalue())["fields"]["summary"], "new title")

    def test_restore_refuses_other_key(self):
        b = Path(self.tmp.name) / "b.json"
        b.write_text(json.dumps({"key": "KAN-2", "description": None}))
        with self.assertRaises(SystemExit):
            td.cmd_restore(argparse.Namespace(key="KAN-1", backup=str(b)), FakeJira(), {})


if __name__ == "__main__":
    unittest.main(verbosity=1)
