#!/usr/bin/env python3
"""Build a question page: the template's <head> + CSS + script around YOUR <body> block.

    build.py BODY.html OUT.html "Page title"

BODY.html holds `<body data-mode="single|multi"> … </div>` — everything from the <body> tag up to
(not including) the template's <script>. Keep the template's `.foot` block (notes, Cancel, Submit)
in it, or the answer controls are lost. Fails loudly when the result is missing a part.
"""
import html
import os
import sys

TEMPLATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "template.html")

body_path, out_path, title = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(TEMPLATE, encoding="utf-8").read()
body = open(body_path, encoding="utf-8").read().strip()

i = t.index("\n<body") + 1
j = t.index("\n<script>") + 1
page = t[:i] + body + "\n" + t[j:]
page = page.replace("<title>Question</title>", f"<title>{html.escape(title)}</title>", 1)

missing = [p for p in ("<style>", "<body", "<script>", 'id="notes"', 'id="submit"', 'id="other"') if p not in page]
if missing or page.count("<!--") != page.count("-->"):
    sys.exit(f"build.py: broken page, missing {missing or 'a comment close'}")

open(out_path, "w", encoding="utf-8").write(page)
print(out_path)
