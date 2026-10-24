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
# Prints `TASK_STARTED <KEY> agterm=<sid> claude=<uuid> worktree=<path>` only when Claude runs in
# the new session (agterm shows it in front, within about 20 s). Else: ERROR, exit 1, the session
# is marked blocked and Jira is not touched.
#
# Optional overrides (for skills that reuse this flow, e.g. security-check). Unset or empty =
# the default (default_seed, no extra, default_next below), so a plain new-task run does not change:
#   TASK_SEED         first prompt of the new Claude; may use {{KEY}}, {{SUMMARY}}, {{BRIEF}}
#   TASK_BRIEF_EXTRA  a file added to the end of the brief, after ../references/brief-template.md
#                     and before the ticket text; same {{...}} placeholders as the template
#   TASK_NEXT         text after "- Next: " in the "work started" Jira comment
#
# The claude command is TYPED into a shell. A control byte (Ctrl-A, ESC, ...) would edit that
# line, so only allowlisted bytes are typed: TASK_SEED and the key are refused when they hold
# anything else, and the Jira summary keeps only SUMMARY_OK (other bytes become spaces, so a
# non-ASCII letter is lost there too; the brief keeps the full summary).
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # bash 5.2+: keep '&' literal in ${v//p/r}

# Exact ASCII sets. No ranges: in some locales a range like A-Z also matches other letters.
UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
LOWER=abcdefghijklmnopqrstuvwxyz
DIGITS=0123456789
# Bytes a typed seed may hold: printable ASCII without " $ ` \ ' !, so all of it stays literal
# inside "..." in bash and zsh. \133 \135 are [ ], in octal so tr does not read a class.
SEED_OK="$UPPER$LOWER$DIGITS #%&()*+,./:;<=>?@^_{|}~\\133\\135-"
# Bytes the summary keeps in the typed command, the session name and the branch.
SUMMARY_OK="$UPPER$LOWER$DIGITS .,:;()/_+#@&?={}-"

repo_in="${1:?repo path required}"
key="${2:?Jira key required (e.g. KAN-297)}"
branch="${3:-}"
ws="${4:-}"

here="$(cd "$(dirname "$0")" && pwd -P)"
JIRA_PY="${JIRA_PY:-/Users/vnazarenko/code/Orthhank/.claude/skills/jira-tickets/scripts/jira.py}"
NEW_WT="${NEW_WT:-$HOME/.claude/skills/parallel-issues/scripts/new-worktree.sh}"
briefs="$HOME/.claude/task-briefs"
brief_tpl="$here/../references/brief-template.md"
brief_extra="${TASK_BRIEF_EXTRA:-}"
default_seed='/planning:make {{KEY}}: {{SUMMARY}}. First read the task brief {{BRIEF}} and follow it for the whole task.'
seed_tpl="${TASK_SEED:-$default_seed}"
default_next='an implementation plan (planning:make). The plan summary will be posted here.'
next="${TASK_NEXT:-$default_next}"

die() { echo "ERROR: $*"; exit 1; }
# outside <tr set> <text>: how many bytes of <text> are not in the set (byte by byte, C locale).
outside() { printf '%s' "$2" | LC_ALL=C tr -d "$1" | wc -c | tr -d ' '; }
# valid_key <key>: PROJ-123 form, ASCII only.
valid_key() {
  local p="${1%-*}" n="${1##*-}"
  [ "$p" != "$1" ] || return 1
  case "$p" in "" | [!$UPPER]* | *[!$UPPER${DIGITS}_]*) return 1 ;; esac
  case "$n" in "" | *[!$DIGITS]*) return 1 ;; esac
}
# trees: the tree of every open agterm window, one JSON document each. `agtermctl tree` alone
# shows only the frontmost window, and the user may switch windows while this script runs.
# Without a window list (an older agterm), the frontmost tree.
trees() {
  local w found=0
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    found=1
    agtermctl tree --json --window "$w" 2>/dev/null
  done < <(agtermctl window list --json 2>/dev/null \
             | jq -r '.result.windows[]? | select(.open == true) | .id // empty' 2>/dev/null)
  [ "$found" = 1 ] || agtermctl tree --json 2>/dev/null
}
[ "${AGTERM_ENABLED:-}" = "1" ] || die "not inside agterm (AGTERM_ENABLED != 1)"
for c in agtermctl jq uuidgen python3; do command -v "$c" >/dev/null 2>&1 || die "$c not on PATH"; done
[ -f "$JIRA_PY" ] || die "jira.py not found at $JIRA_PY (set JIRA_PY)"
[ -x "$NEW_WT" ] || [ -f "$NEW_WT" ] || die "new-worktree.sh not found at $NEW_WT"
[ -f "$brief_tpl" ] || die "brief template not found at $brief_tpl"
[ -z "$brief_extra" ] || [ -f "$brief_extra" ] || die "extra brief not found at $brief_extra (TASK_BRIEF_EXTRA)"
# The seed is typed into a shell inside double quotes: refuse what that shell would expand and
# every control byte (a tab, a line break, Ctrl-A, ESC, DEL, C1) or non-ASCII byte.
[ "$(outside "$SEED_OK" "$seed_tpl")" = 0 ] \
  || die "TASK_SEED may hold only printable ASCII without \" \$ \` \\ ' ! (no control character, no line break)"
valid_key "$key" || die "$(printf '%q' "$key") is not a Jira key"   # %q: no raw control byte in the output
repo="$(cd "$repo_in" 2>/dev/null && pwd -P)" || die "repo '$repo_in' does not exist"
[ -e "$repo/.git" ] || die "'$repo' is not a git repo"

# One session per ticket, in any window. A second one would split the history in two places.
# The name is "<KEY> <summary>", or only "<KEY>" when nothing of the summary is kept.
existing="$(trees | jq -rs --arg k "$key" \
  '[.. | objects | select(.cwd? and ((.name? // "") as $n | $n == $k or ($n | startswith($k + " ")))) | .id]
   | first // empty' 2>/dev/null)"
[ -z "$existing" ] || die "an agterm session for $key already exists (sid=$existing) — switch to it instead"

ticket="$(python3 "$JIRA_PY" get "$key")" || die "could not read $key from Jira"
summary="$(jq -r '.summary' <<<"$ticket")"
status="$(jq -r '.status' <<<"$ticket")"
url="$(jq -r '.url' <<<"$ticket")"
description="$(jq -r '.description // ""' <<<"$ticket")"

# Text that goes into a typed shell command. Quotes, $, backticks, backslashes and "!" are
# dropped, as before (so "user's" stays "users"); every other byte outside SUMMARY_OK (control
# bytes, other punctuation, non-ASCII) becomes a space. Then spaces are collapsed and trimmed.
# ('…\\' ends the set with a backslash, then "'" adds the single quote; SC1003 is a false alarm.)
# shellcheck disable=SC1003
clean="$(printf '%s' "$summary" | LC_ALL=C tr -d '!"`$\\'"'" | LC_ALL=C tr -c "$SUMMARY_OK" ' ' \
  | tr -s ' ' | sed 's/^ //; s/ $//')"
name="$(printf '%s %s' "$key" "$clean" | cut -c1-60 | sed 's/ *$//')"

if [ -z "$branch" ]; then
  slug="$(printf '%s' "$clean" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-' \
    | cut -d- -f1-6 | sed 's/^-//; s/-$//')"
  branch="${key}${slug:+-$slug}"
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

# fill <file>: the file with every {{...}} placeholder of the brief filled in.
fill() {
  sed -e "s|{{KEY}}|$key|g" -e "s|{{URL}}|$url|g" -e "s|{{REPO}}|$repo|g" \
      -e "s|{{WORKTREE}}|$wt|g" -e "s|{{BRANCH}}|$branch|g" -e "s|{{SESSION_ID}}|$uuid|g" \
      -e "s|{{JIRA_PY}}|$JIRA_PY|g" -e "s|{{REGISTRY}}|$reg|g" -e "s|{{PROCS}}|$briefs/$key.procs|g" "$1"
}
{
  fill "$brief_tpl"
  if [ -n "$brief_extra" ]; then printf '\n'; fill "$brief_extra"; fi
  printf '\n## The ticket (from Jira, %s)\n\n**%s** — status %s\n\n%s\n' "$(date +%F)" "$summary" "$status" "$description"
} > "$brief"

# SUMMARY goes last, so text from Jira is never searched for placeholders.
seed="${seed_tpl//'{{KEY}}'/$key}"
seed="${seed//'{{BRIEF}}'/$brief}"
seed="${seed//'{{SUMMARY}}'/$clean}"
# Last check of everything typed, before a session exists (the brief path comes from $HOME).
[ "$(outside "$SEED_OK" "$seed$name$uuid")" = 0 ] \
  || die "the claude command would hold a byte that is not safe to type: check the brief path (\$HOME)"

ws_args=()
case "$ws" in
  # Default: right after the caller's session. The shell's AGTERM_WORKSPACE_ID can be stale
  # (the session was moved), so look the caller up in the live tree of every window; if it is
  # not there, the active workspace is used.
  "")    if [ -n "${AGTERM_SESSION_ID:-}" ] && trees \
            | jq -se --arg id "$AGTERM_SESSION_ID" '[.. | objects | select(.id? == $id)] | length > 0' >/dev/null 2>&1; then
           ws_args=(--after "$AGTERM_SESSION_ID")
         fi ;;
  new:*) ws_args=(--workspace-name "${ws#new:}" --create-workspace) ;;
  *)     ws_args=(--workspace "$ws") ;;
esac

# A login shell, then type the claude command: `--command` gets a minimal PATH and often
# cannot find claude (same reason as parallel-issues/launch-agterm-session.sh).
# ${ws_args[@]+...}: bash 3.2 (macOS /bin/bash) calls an empty array unbound under set -u.
sid="$(agtermctl session new --cwd "$wt" ${ws_args[@]+"${ws_args[@]}"} --name "$name" --json | jq -r '.result.id // empty')"
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

sleep 1
agtermctl session type --target "$sid" "claude --session-id ${uuid} -n \"${name}\" \"${seed}\"" >/dev/null 2>&1
agtermctl session type --target "$sid" $'\r' >/dev/null 2>&1

# claude_runs: agterm's tree shows claude as the new session's foreground process. All windows:
# the new session stays in its window when the user brings another one to the front.
claude_runs() {
  trees | jq -se --arg id "$sid" '[.. | objects | select(.id? == $id) | .foreground[0]?] | any(. == "claude")' >/dev/null 2>&1
}
# Wait for Claude, about 20 s. One more Enter after the first miss: a shell that was still
# starting can lose the first one. Typing can fail without an error, so only this check says
# that the task started.
started=0
for try in 1 2 3 4 5 6 7 8 9 10; do
  sleep 2
  if claude_runs; then started=1; break; fi
  [ "$try" != 1 ] || agtermctl session type --target "$sid" $'\r' >/dev/null 2>&1
done
if [ "$started" != 1 ]; then
  agtermctl session status blocked --target "$sid" >/dev/null 2>&1 || true
  die "Claude did not start in the agterm session '$name' (sid=$sid). Nothing was posted to Jira. Look at that session, close it, then start again."
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
