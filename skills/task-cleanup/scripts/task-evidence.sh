#!/usr/bin/env bash
# Collects everything the task-cleanup retro needs, in one run. READ-ONLY: it never changes a
# branch, a PR, a ticket or a file.
#
#   task-evidence.sh <KEY>
#
# Sections: REGISTRY, PRS, CI, REVIEW, PRBODY, COMMITS, PLAN, JIRA, RELATED, SESSIONLOG.
# Every section is facts only. Reading them is the model's job, not the script's.
set -uo pipefail

key="${1:?Jira key required}"
briefs="$HOME/.claude/task-briefs"
reg="$briefs/$key.env"
JIRA_PY="${JIRA_PY:-/Users/vnazarenko/code/Orthhank/.claude/skills/jira-tickets/scripts/jira.py}"

if [ -f "$reg" ]; then . "$reg"; fi
REPO="${REPO:-$(pwd)}"
WORKTREE="${WORKTREE:-$REPO}"
BRANCH="${BRANCH:-$(git -C "$WORKTREE" branch --show-current 2>/dev/null)}"

# gh reads the repo from the cwd, so every call below must run inside the repo
cd "$REPO" 2>/dev/null || { echo "ERROR: cannot cd to REPO=$REPO"; exit 1; }

echo "== REGISTRY =="
if [ -f "$reg" ]; then cat "$reg"; else echo "(no registry — values guessed: REPO=$REPO BRANCH=$BRANCH)"; fi

mentions=""

echo
echo "== PRS =="
prs=""
if command -v gh >/dev/null 2>&1 && [ -n "$BRANCH" ]; then
  gh pr list --head "$BRANCH" --state all \
     --json number,state,title,url,mergeCommit \
     --template '{{range .}}#{{.number}} {{.state}} {{.title}}  {{.url}}  merge={{if .mergeCommit}}{{.mergeCommit.oid}}{{else}}-{{end}}
{{end}}' 2>&1
  prs=$(gh pr list --head "$BRANCH" --state all --json number --jq '.[].number' 2>/dev/null)
else
  echo "(gh missing or no branch)"
fi

echo
echo "== CI =="
for n in $prs; do
  echo "--- #$n"
  gh pr view "$n" --json statusCheckRollup \
     --jq '[.statusCheckRollup[]? | select((.conclusion // .state) as $c | $c != "SUCCESS" and $c != "NEUTRAL" and $c != "SKIPPED")
            | "\(.name // .context): \(.conclusion // .state)"] | if length == 0 then "all green" else .[] end' 2>&1
done
[ -z "$prs" ] && echo "(no PR)"

echo
echo "== REVIEW =="
echo "# what a reviewer had to catch — each line is a candidate retro finding"
for n in $prs; do
  echo "--- #$n"
  gh pr view "$n" --json reviews,comments \
     --jq '[(.reviews[]? | select(.body != "") | "review(\(.state)): \(.body | split("\n")[0])"),
            (.comments[]? | "comment: \(.body | split("\n")[0])")] | if length == 0 then "none" else .[] end' 2>&1
done
[ -z "$prs" ] && echo "(no PR)"

echo
echo "== PRBODY =="
echo "# every PR body must end with '## Deploy steps' and '## After deploy'"
for n in $prs; do
  body=$(gh pr view "$n" --json body --jq .body 2>/dev/null)
  d=MISSING; a=MISSING
  printf '%s' "$body" | grep -qi '^## *Deploy steps'  && d=ok
  printf '%s' "$body" | grep -qi '^## *After deploy'  && a=ok
  echo "#$n Deploy steps=$d  After deploy=$a"
  mentions="$mentions $(printf '%s' "$body" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sort -u | tr '\n' ' ')"
done
[ -z "$prs" ] && echo "(no PR)"

echo
echo "== COMMITS =="
base=$(git -C "$REPO" merge-base origin/main "$BRANCH" 2>/dev/null)
if [ -n "$base" ]; then
  log=$(git -C "$REPO" log --no-merges --format='%h %s' "$base..$BRANCH" 2>/dev/null)
  echo "$log"
  echo "--- rework signals (a fix on top of a fix is a retro finding)"
  printf '%s\n' "$log" | grep -icE '(^|\s)(revert|fixup|squash|wip)' | sed 's/^/rework-prefixed commits: /'
  printf '%s\n' "$log" | grep -icE 'fix.*(fix|again|properly|actually)' | sed 's/^/"fix the fix" commits: /'
  mentions="$mentions $(printf '%s\n' "$log" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | sort -u | tr '\n' ' ')"
else
  echo "(no merge-base for $BRANCH — fetch origin first)"
fi

echo
echo "== PLAN =="
if [ -n "$base" ]; then
  plans=$(git -C "$REPO" diff --name-only "$base..$BRANCH" 2>/dev/null | grep -E 'docs/plans/.*\.md$')
  if [ -n "$plans" ]; then
    for p in $plans; do
      echo "--- $p"
      git -C "$REPO" show "$BRANCH:$p" 2>/dev/null | grep -nE '^\s*(➕|⚠️|- \[ \])' | head -40
    done
  else
    echo "(no plan file on the branch)"
  fi
fi

echo
echo "== JIRA =="
if [ -f "$JIRA_PY" ]; then
  python3 "$JIRA_PY" get "$key" 2>&1 | python3 -c '
import json,sys,re
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print(raw[:400]); sys.exit()
print("status:", d.get("status"), "| type:", d.get("type"), "| labels:", d.get("labels"))
cs=d.get("comments") or []
print("comments:", len(cs))
pat=re.compile(r"block|scope|revert|wrong|broke|retry|again|misunderstood|clarif", re.I)
for c in cs:
    b=(c.get("body") or "").strip().replace("\n"," ")
    if pat.search(b): print("  flag:", b[:160])
'
else
  echo "(jira.py not found at $JIRA_PY)"
fi

echo
echo "== RELATED =="
if [ -f "$JIRA_PY" ]; then
  python3 "$JIRA_PY" jql "issue in linkedIssues(\"$key\")" --limit 20 --md 2>&1 | head -25
fi
echo "--- keys named in commits or PR bodies"
echo "$mentions" | tr ' ' '\n' | grep -E '^[A-Z]' | grep -v "^$key$" | sort -u | tr '\n' ' '; echo

echo
echo "== RETRO NOTES =="
echo "# written by the task session as it worked (brief step 4)"
if [ -s "$briefs/$key.retro" ]; then cat "$briefs/$key.retro"; else echo "(none recorded)"; fi

echo
echo "== SESSIONLOG =="
sid="${CLAUDE_SESSION_ID:-}"
if git -C "$REPO" show origin/main:.claude/SESSIONS.md >/dev/null 2>&1; then
  if [ -n "$sid" ] && git -C "$REPO" show origin/main:.claude/SESSIONS.md | grep -q "${sid:0:8}"; then
    echo "on origin/main: yes (${sid:0:8})"
  else
    echo "on origin/main: NO — this session has no line yet"
  fi
else
  echo "(.claude/SESSIONS.md is not on origin/main)"
fi
