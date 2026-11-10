#!/usr/bin/env bash
# Close a finished review session: keep its report, remove its worktree(s), close the agterm
# session, drop it from the registry. Run only when nothing the review raised waits for the user.
#
# Usage: close-review.sh <REGISTRY-KEY>      e.g. close-review.sh R-ABC-92
# Reports are kept in $MANAGER_BRIEFS/reviews/ (outlives the session scratchpads).
set -uo pipefail

briefs="${MANAGER_BRIEFS:-$HOME/.claude/task-briefs}"
key="${1:?usage: close-review.sh <REGISTRY-KEY>}"
env="$briefs/$key.env"
[ -f "$env" ] || { echo "no registry entry $env"; exit 1; }
grep -qx 'KIND=review' "$env" || { echo "$key is not KIND=review; refusing"; exit 1; }
sid="$(sed -n 's/^AGTERM_SESSION_ID=//p' "$env")"
name="${key#R-}"
mkdir -p "$briefs/reviews"

# Review worktrees are named review-<name>* inside the repos under the session's root.
root="$(sed -n 's/^REPO=//p' "$env")"; root="${root%/*}"
for repo in "$root"/*/; do
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
  # Match by directory name, or by the report inside it: a session can name its worktree
  # differently (R-ABC-30-43-42 made review-ABC-30-42-43).
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | grep '/\.claude/worktrees/review-' | while read -r wt; do
      [[ "$wt" =~ /review-${name}(-[^/]*)?$ ]] || [ -f "$wt/REVIEW-$name.md" ] || continue
      cp "$wt"/REVIEW-*.md "$briefs/reviews/" 2>/dev/null && echo "kept $(ls "$wt"/REVIEW-*.md)"
      # Detached review checkouts hold only local test setup; nothing to save but the report.
      git -C "$repo" worktree remove --force "$wt" && echo "removed $wt"
    done
  git -C "$repo" worktree prune 2>/dev/null
done

if [ -n "$sid" ]; then
  for w in $(agtermctl window list --json 2>/dev/null | jq -r '.result.windows[]? | select(.open) | .id'); do
    agtermctl session close --target "$sid" --window "$w" >/dev/null 2>&1 && { echo "closed session $sid"; break; }
  done
fi
rm -f "$env"
echo "$(date '+%Y-%m-%d %H:%M') | $key | review closed; report in $briefs/reviews/" >> "$briefs/manager-log.md"
