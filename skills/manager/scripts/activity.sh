#!/usr/bin/env bash
# Cheap activity probe for the idle backoff (no tick agent, a few tokens).
# Prints "ACTIVE <n>" when any registered or long-lived session changed its agent status
# (agterm statusChangedAt) or is running ('active') within the last N minutes (default 15),
# else "QUIET". Why: 2026-11-03 the backoff skipped checks for hours while the user was
# working inside the sessions; "no change" in the last tick is not proof nobody is working.
set -uo pipefail
B="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
MIN="${1:-15}"
ids=$(grep -h '^AGTERM_SESSION_ID=' "$B"/*.env 2>/dev/null | cut -d= -f2 | tr -d '"' | tr 'a-z' 'A-Z' | sort -u)
names=$(grep -v '^#' "$B/manager-longlived.md" 2>/dev/null | sed '/^\s*$/d')
for w in $(agtermctl window list --json 2>/dev/null | python3 -c 'import sys,json;[print(w["id"]) for w in json.load(sys.stdin)["result"]["windows"]]' 2>/dev/null); do
  agtermctl tree --json --window "$w" 2>/dev/null
done | python3 -c '
import sys, json, time
ids=set(sys.argv[1].split()); names=[n for n in sys.argv[2].splitlines() if n.strip()]; win=int(sys.argv[3])*60
now=time.time(); hits=[]
dec=json.JSONDecoder(); buf=sys.stdin.read(); i=0
while i < len(buf):
    while i < len(buf) and buf[i].isspace(): i+=1
    if i>=len(buf): break
    obj,i=dec.raw_decode(buf,i)
    for w in obj.get("result",{}).get("tree",{}).get("workspaces",[]):
        for s in w.get("sessions",[]):
            mine = s["id"].upper() in ids or any(s.get("name","").startswith(n) for n in names)
            if not mine: continue
            if s.get("status")=="active" or now - (s.get("statusChangedAt") or 0) < win:
                hits.append(s.get("name","?")[:40])
print(("ACTIVE %d: " % len(hits)) + "; ".join(hits) if hits else "QUIET")
' "$ids" "$names" "$MIN"
