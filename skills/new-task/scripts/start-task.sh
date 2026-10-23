#!/usr/bin/env bash
# Start work on ONE Jira ticket:
#   worktree <repo>/.claude/worktrees/<KEY>  +  agterm session named "<KEY> <summary>"
#   + an interactive Claude (fixed session id, same name) that opens with /planning:make,
#   + Jira moved to "In Progress" with a "work started" comment.
#
# Usage:
#   start-task.sh <repo_path> <KEY> [branch] [workspace]
#
# - <repo_path>  the git repo the work belongs in (e.g. ~/code/Orthhank/parsalytics)
# - <KEY>        Jira key, e.g. KAN-297 (the ticket must exist — create it first)
# - [branch]     default: <KEY>-<slug of the summary>
# - [workspace]  agterm workspace: default = the caller's current one; <id|prefix>; new:NAME
#
# Writes the task registry ~/.claude/task-briefs/<KEY>.env (read by task-cleanup) and the
# brief ~/.claude/task-briefs/<KEY>.md (the new session's instructions).
# Prints `TASK_STARTED <KEY> agterm=<sid> claude=<uuid> worktree=<path>`.
#
# Optional overrides (for skills that reuse this flow, e.g. security-check). Unset or empty =
# the default, so a plain new-task run does not change:
#   TASK_SEED            first prompt of the new Claude; may use {{KEY}}, {{SUMMARY}}, {{BRIEF}}.
#                        Default: "/planning:make {{KEY}}: {{SUMMARY}}. First read the task brief
#                        {{BRIEF}} and follow it for the whole task."
#   TASK_BRIEF_TEMPLATE  brief template file. Default: ../references/brief-template.md
#   TASK_NEXT            text after "- Next: " in the "work started" Jira comment. Default:
#                        "an implementation plan (planning:make). The plan summary will be posted here."
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: keep '&' literal in ${v//p/r}

repo_in="${1:?repo path required}"
key="${2:?Jira key required (e.g. KAN-297)}"
branch="${3:-}"
ws="${4:-}"

here="$(cd "$(dirname "$0")" && pwd -P)"
JIRA_PY="${JIRA_PY:-/Users/vnazarenko/code/Orthhank/.claude/skills/jira-tickets/scripts/jira.py}"
NEW_WT="${NEW_WT:-$HOME/.claude/skills/parallel-issues/scripts/new-worktree.sh}"
briefs="$HOME/.claude/task-briefs"
brief_tpl="${TASK_BRIEF_TEMPLATE:-$here/../references/brief-template.md}"
default_seed='/planning:make {{KEY}}: {{SUMMARY}}. First read the task brief {{BRIEF}} and follow it for the whole task.'
seed_tpl="${TASK_SEED:-$default_seed}"
next="${TASK_NEXT:-an implementation plan (planning:make). The plan summary will be posted here.}"

die() { echo "ERROR: $*"; exit 1; }
[ "${AGTERM_ENABLED:-}" = "1" ] || die "not inside agterm (AGTERM_ENABLED != 1)"
for c in agtermctl jq uuidgen python3; do command -v "$c" >/dev/null 2>&1 || die "$c not on PATH"; done
[ -f "$JIRA_PY" ] || die "jira.py not found at $JIRA_PY (set JIRA_PY)"
[ -x "$NEW_WT" ] || [ -f "$NEW_WT" ] || die "new-worktree.sh not found at $NEW_WT"
[ -f "$brief_tpl" ] || die "brief template not found at $brief_tpl (TASK_BRIEF_TEMPLATE)"
# The seed is typed into a shell inside double quotes: refuse what that shell would expand.
case "$seed_tpl" in
  *[\"\$\`\\!]* | *$'\n'* | *$'\r'*) die 'TASK_SEED must not contain " $ ` \ ! or a line break' ;;
esac
case "$key" in [A-Z]*-[0-9]*) : ;; *) die "'$key' is not a Jira key" ;; esac
repo="$(cd "$repo_in" 2>/dev/null && pwd -P)" || die "repo '$repo_in' does not exist"
[ -e "$repo/.git" ] || die "'$repo' is not a git repo"

# One session per ticket. A second one would split the history in two places.
existing="$(agtermctl tree --json 2>/dev/null | jq -r --arg k "$key " \
  '[.. | objects | select(.cwd? and (.name? // "" | startswith($k))) | .id] | first // empty')"
[ -z "$existing" ] || die "an agterm session for $key already exists (sid=$existing) — switch to it instead"

ticket="$(python3 "$JIRA_PY" get "$key")" || die "could not read $key from Jira"
summary="$(jq -r '.summary' <<<"$ticket")"
status="$(jq -r '.status' <<<"$ticket")"
url="$(jq -r '.url' <<<"$ticket")"
description="$(jq -r '.description // ""' <<<"$ticket")"

# Text that goes into a typed shell command: drop quotes, $, backticks, backslashes.
# ('…\\' ends the set with a backslash, then "'" adds the single quote; SC1003 is a false alarm.)
# shellcheck disable=SC1003
clean="$(printf '%s' "$summary" | tr -d '"`$\\'"'" | tr -s ' ')"
name="$(printf '%s %s' "$key" "$clean" | cut -c1-60 | sed 's/ *$//')"

if [ -z "$branch" ]; then
  slug="$(printf '%s' "$clean" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' \
    | cut -d- -f1-6 | sed 's/^-//; s/-$//')"
  branch="${key}-${slug}"
fi

# Root = the repo's parent, service = the repo dir. Two reasons: service "." makes paths like
# <repo>/./.claude/… that break new-worktree.sh's "already exists" check, and this shape links
# the parent's shared skills (e.g. ~/code/Orthhank/.claude/skills: jira-tickets, aparser) into
# the worktree of a nested repo such as parsalytics.
wt_out="$(PARALLEL_ISSUES_ROOT="$(dirname "$repo")" bash "$NEW_WT" "$(basename "$repo")" "$key" "$branch")"
echo "$wt_out"
wt="$(sed -n 's/^WORKTREE_READY \([^ ]*\).*/\1/p' <<<"$wt_out")"
[ -n "$wt" ] && [ -d "$wt" ] || die "worktree was not created"
wt="$(cd "$wt" && pwd -P)"   # new-worktree.sh with service "." gives <repo>/./.claude/…

uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
mkdir -p "$briefs"
brief="$briefs/$key.md"
reg="$briefs/$key.env"

{
  sed -e "s|{{KEY}}|$key|g" -e "s|{{URL}}|$url|g" -e "s|{{REPO}}|$repo|g" \
      -e "s|{{WORKTREE}}|$wt|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{SESSION_ID}}|$uuid|g" \
      -e "s|{{JIRA_PY}}|$JIRA_PY|g" -e "s|{{REGISTRY}}|$reg|g" -e "s|{{PROCS}}|$briefs/$key.procs|g" "$brief_tpl"
  printf '\n## The ticket (from Jira, %s)\n\n**%s** — status %s\n\n%s\n' "$(date +%F)" "$summary" "$status" "$description"
} > "$brief"

ws_args=()
case "$ws" in
  # Default: right after the caller's session. The shell's AGTERM_WORKSPACE_ID can be stale
  # (the session was moved), so look the caller up in the live tree; if it is not there, the
  # active workspace is used.
  "")    if [ -n "${AGTERM_SESSION_ID:-}" ] && agtermctl tree --json 2>/dev/null \
            | jq -e --arg id "$AGTERM_SESSION_ID" '[.. | objects | select(.id? == $id)] | length > 0' >/dev/null; then
           ws_args=(--after "$AGTERM_SESSION_ID")
         fi ;;
  new:*) ws_args=(--workspace-name "${ws#new:}" --create-workspace) ;;
  *)     ws_args=(--workspace "$ws") ;;
esac

# A login shell, then type the claude command: `--command` gets a minimal PATH and often
# cannot find claude (same reason as parallel-issues/launch-agterm-session.sh).
sid="$(agtermctl session new --cwd "$wt" "${ws_args[@]}" --name "$name" --json | jq -r '.result.id // empty')"
[ -n "$sid" ] || die "'agtermctl session new' returned no id"

cat > "$reg" <<EOF
KEY=$key
SUMMARY="$clean"
URL=$url
REPO=$repo
WORKTREE=$wt
BRANCH=$branch
CLAUDE_SESSION_ID=$uuid
AGTERM_SESSION_ID=$sid
SESSION_NAME="$name"
BRIEF=$brief
PROCS=$briefs/$key.procs
RETRO=$briefs/$key.retro
STARTED="$(date '+%F %T')"
EOF
: > "$briefs/$key.procs"

# SUMMARY goes last, so text from Jira is never searched for placeholders.
seed="${seed_tpl//'{{KEY}}'/$key}"
seed="${seed//'{{BRIEF}}'/$brief}"
seed="${seed//'{{SUMMARY}}'/$clean}"
sleep 1
agtermctl session type --target "$sid" "claude --session-id ${uuid} -n \"${name}\" \"${seed}\"" >/dev/null 2>&1
agtermctl session type --target "$sid" $'\r' >/dev/null 2>&1
sleep 2
if ! agtermctl tree --json 2>/dev/null | jq -e --arg id "$sid" '.. | objects | select(.id? == $id) | .foreground[0]? == "claude"' >/dev/null 2>&1; then
  agtermctl session type --target "$sid" $'\r' >/dev/null 2>&1
fi
agtermctl session status active --target "$sid" >/dev/null 2>&1 || true

# A folder Claude has not seen before opens with the "trust this folder" question. That is the
# user's decision, so it is only reported, never answered here.
sleep 2
if agtermctl session text --target "$sid" --lines 30 2>/dev/null | grep -q "trust this folder"; then
  echo "WARN: Claude in the new session asks to trust $wt — answer it there"
  agtermctl session status blocked --target "$sid" >/dev/null 2>&1 || true
fi

# Jira: In Progress (skip when it already is) + where the work lives.
[ "$status" = "In Progress" ] || python3 "$JIRA_PY" transition "$key" --to "In Progress" >/dev/null \
  || echo "WARN: could not move $key to In Progress"
python3 "$JIRA_PY" comment "$key" --body "Work started $(date '+%F %H:%M').

- agterm session: $name
- Claude session: $uuid (resume: claude --resume $uuid)
- Repo: $(basename "$repo"), branch $branch
- Worktree: $wt
- Next: $next" >/dev/null \
  || echo "WARN: could not comment on $key"

echo "TASK_STARTED $key agterm=$sid claude=$uuid worktree=$wt branch=$branch"
