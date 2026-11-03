# Shared by status.sh, tick.sh and precheck.sh (source it; it needs $briefs).
# One definition of "what a tick acts on", so the cheap pre-check and the tick agree.

# agterm's control socket can stop answering; never let one call hang the tick.
at() { if command -v timeout >/dev/null 2>&1; then timeout 10 agtermctl "$@"; else agtermctl "$@"; fi; }

# Every open window's tree. `tree` alone shows only the frontmost window, and task sessions often
# sit in another one (2026-10-26: all tasks read as "no session").
agterm_tree() {
  local t="" w
  for w in $(at window list --json 2>/dev/null | jq -r '.result.windows[]? | select(.open) | .id'); do
    t+="$(at tree --json --window "$w" 2>/dev/null)"$'\n'
  done
  [ -n "${t//[[:space:]]/}" ] || t="$(at tree --json 2>/dev/null)" || t=""
  printf '%s' "$t"
}

# A session's primary pane, last 60 lines, without blank lines and the prompt-box frame.
screen_text() {
  at session text --target "$1" --pane primary --lines 60 2>&1 \
    | grep -v '^[[:space:]]*$' | grep -vE '^[[:space:]]*(─|⏵⏵)|Update installed'
}

# agterm agent status of a session id: active | completed | blocked | none
session_status() { # tree sid
  jq -rs --arg id "$2" '[.[] | .. | objects
    | select(.cwd? and ((.id // "") | ascii_upcase) == ($id | ascii_upcase)) | (.status // "none")]
    | first // "none"' <<<"$1"
}

# "working" while the agent runs, else a hash of the last 22 screen lines. agterm's status can be
# reset to none while Claude still runs, so the spinner line ("✻ Generating… (11s ·") counts too.
token_of() { # status screen-tail
  if [ "$1" = active ] || tail -n 6 <<<"$2" | grep -qE '…[[:space:]]+\([0-9]'; then
    echo working
  else
    shasum <<<"$2" | cut -c1-12
  fi
}

# Watched sessions, one per line: "<name><TAB><sid or ->". Registry tasks by KEY, then long-lived
# sessions as "long-lived <prefix>". The names match what status.sh records.
watched_sessions() { # tree
  local f key sid live prefix
  live="$(jq -r '.. | objects | select(.cwd?) | .id' <<<"$1")"
  for f in "$briefs"/*.env; do
    [ -f "$f" ] || continue
    key="$(sed -n 's/^KEY=//p' "$f")"
    sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$f")"
    if [ -n "$sid" ] && grep -qx "$sid" <<<"$live"; then printf '%s\t%s\n' "$key" "$sid"
    else printf '%s\t-\n' "$key"; fi
  done
  [ -s "$briefs/manager-longlived.md" ] || return 0
  grep -v '^#' "$briefs/manager-longlived.md" | while IFS= read -r prefix; do
    [ -n "$prefix" ] || continue
    sid="$(jq -rs --arg p "$prefix" \
      '[.[] | .. | objects | select(.cwd? and (.name? // "" | startswith($p))) | .id] | first // empty' <<<"$1")"
    printf 'long-lived %s\t%s\n' "$prefix" "${sid:--}"
  done
}

# Token a watched session had when the last tick started (empty if unknown).
prev_token() { # name
  [ -f "$briefs/.tick-screens" ] && awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$briefs/.tick-screens"
}

# Hash of the files the manager and the user change between ticks.
files_hash() {
  cat "$briefs"/manager-decisions.md "$briefs"/manager-needs.md "$briefs"/manager-holds.md \
      "$briefs"/manager-longlived.md 2>/dev/null | shasum | cut -c1-12
}

# Hash of the merged PRs whose branch names a registered ticket, in every registered repo.
merged_prs() {
  local keys r
  keys="$(sed -n 's/^KEY=R\{0,1\}-\{0,1\}//p' "$briefs"/*.env 2>/dev/null | sort -u | paste -sd'|' -)"
  [ -n "$keys" ] || { echo none; return 0; }
  for r in $(sed -n 's/^REPO=//p' "$briefs"/*.env 2>/dev/null | tr -d '"' | sort -u); do
    [ -d "$r" ] || continue
    (cd "$r" && timeout 20 gh pr list --state merged --limit 30 --json number,headRefName \
        --jq '.[] | "\(.number) \(.headRefName)"' 2>/dev/null) | grep -iE "$keys" | sort
  done | shasum | cut -c1-12
}
