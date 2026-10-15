#!/usr/bin/env bash
# Show a question page in an agterm overlay and wait for the answer.
#
#   ask.sh PAGE.html [SIZE_PERCENT]
#
# The overlay opens WITHOUT switching to the session. The user keeps working
# wherever they are and sees the page when they come to this session on their
# own. To make it findable, the session is marked `blocked` (blinking glyph) in
# the sidebar for as long as the question is open, and a desktop notification is
# posted once.
#
# Environment:
#   HTML_ASK_FOLLOW=1      switch to the session right away (the old behaviour)
#   HTML_ASK_SOUND=NAME    sound played once when the question opens
#                          ('default', a system sound name, or 'off'; default: default)
#
# Prints one JSON line and exits:
#   0  {"pageID":"…","outcome":"submitted","value":"<option id or free text>"}
#   2  {"pageID":"…","outcome":"dismissed"}      the user closed the page
#   1  error from agtermctl
#   3  {"outcome":"unavailable"}                 not inside agterm — ask in the terminal instead
set -u

page="${1:?usage: ask.sh PAGE.html [SIZE_PERCENT]}"
size="${2:-92}"

if [ "${AGTERM_ENABLED:-}" != "1" ] || [ -z "${AGTERM_SESSION_ID:-}" ] || ! command -v agtermctl >/dev/null 2>&1; then
  echo '{"outcome":"unavailable"}'
  exit 3
fi

case "$page" in /*) ;; *) page="$PWD/$page" ;; esac
[ -f "$page" ] || { echo "{\"outcome\":\"error\",\"error\":\"no such file: $page\"}"; exit 1; }

status() {
  state="$1"; shift
  agtermctl session status "$state" --target "$AGTERM_SESSION_ID" "$@" >/dev/null 2>&1 || true
}

# One overlay per session: close a stale page left from an earlier question.
agtermctl session overlay close --target "$AGTERM_SESSION_ID" >/dev/null 2>&1 || true

keeper=""
cleanup() {
  [ -n "$keeper" ] && kill "$keeper" 2>/dev/null
  status idle
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# Mark the session as waiting for the user. The agent-status hooks (PostToolUse,
# Stop) overwrite the glyph as soon as the turn ends, while the question stays
# open long after that — so a keeper re-asserts it every 5s until this script
# exits (the loop dies with it).
sound="${HTML_ASK_SOUND:-default}"
if [ "$sound" = "off" ]; then
  status blocked --blink
else
  status blocked --blink --sound "$sound"
fi
( while kill -0 "$$" 2>/dev/null; do sleep 5; status blocked --blink; done ) &
keeper=$!

agtermctl notify "A question is waiting in the overlay of this session." \
  --target "$AGTERM_SESSION_ID" >/dev/null 2>&1 || true

follow_flag=""
[ "${HTML_ASK_FOLLOW:-}" = "1" ] && follow_flag="--follow"

out=$(agtermctl session overlay open --html "$page" --block --js \
  --target "$AGTERM_SESSION_ID" --size-percent "$size" $follow_flag)
rc=$?
printf '%s\n' "$out"
exit $rc
