#!/usr/bin/env bash
# Show the post-deploy checklist in the agterm session "Post-deploy steps".
#
#   open.sh            create the session if missing, start the server, open the overlay
#   open.sh --ensure   (from the tick) only repair an existing session: restart a dead
#                      server, reopen a closed overlay. Never creates the session.
#
# Layout: the page on the left pane, a shell on the right for doing the steps.
# The page polls the server every 15 s, so a rebuild (build.py) shows without reopening.
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
NAME="Post-deploy steps"
PORT="${POST_DEPLOY_PORT:-47312}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${POST_DEPLOY_DIR:-$HOME/.claude/post-deploy}"
URL="http://127.0.0.1:$PORT/"
ensure=0; [ "${1:-}" = "--ensure" ] && ensure=1
command -v agtermctl >/dev/null || { echo "post-deploy: agtermctl not found"; exit 0; }
mkdir -p "$DIR"

find_session() {  # prints "<window> <session id> <page shown> <split shown>" for the first match
  agtermctl window list --json 2>/dev/null | python3 -c '
import json, subprocess, sys
name = sys.argv[1]
for w in json.load(sys.stdin).get("result", {}).get("windows", []):
    t = subprocess.run(["agtermctl", "tree", "--json", "--window", w["id"]], capture_output=True, text=True).stdout
    try:
        tree = json.loads(t)["result"]["tree"]
    except Exception:
        continue
    for ws in tree.get("workspaces", []):
        for s in ws.get("sessions", []):
            if s.get("name") == name:
                po = s.get("paneOverlays") or []
                print(w["id"], s["id"], str("left" in po or "primary" in po).lower(),
                      str(bool(s.get("hasSplit") or s.get("split"))).lower()); sys.exit()
' "$NAME"
}

up() { curl -s -o /dev/null -m 2 "$URL"; }

read -r win sid ov sp <<<"$(find_session)"
[ -z "${sid:-}" ] && [ "$ensure" = 1 ] && exit 0
if [ -n "${sid:-}" ] && ! up; then  # the server died: replace the session
  agtermctl session close --target "$sid" --window "$win" >/dev/null 2>&1 || true
  sid=""
fi
if [ -z "${sid:-}" ]; then
  # the workspace of the manager that first opened it (launchd has no AGTERM_WORKSPACE_ID)
  [ -n "${AGTERM_WORKSPACE_ID:-}" ] && echo "$AGTERM_WORKSPACE_ID" >"$DIR/.workspace"
  ws=$(cat "$DIR/.workspace" 2>/dev/null)
  ws_args=(); [ -n "$ws" ] && ws_args=(--workspace "$ws")
  agtermctl session new --name "$NAME" --cwd "$DIR" --no-select ${ws_args[@]+"${ws_args[@]}"} --wait \
    --command "python3 '$HERE/serve.py' $PORT" >/dev/null || exit 1
  for _ in $(seq 1 20); do up && break; sleep 0.5; done
  up || { echo "post-deploy: server did not start"; exit 1; }
  read -r win sid ov sp <<<"$(find_session)"
  [ -n "${sid:-}" ] || { echo "post-deploy: session not found after start"; exit 1; }
fi
wargs=(--window "$win")

# Layout: the page on the left (an overlay on the server's pane), a shell on the right
# for doing the steps, started in WORK_DIR (config.env).
if [ "${sp:-false}" != "true" ]; then
  agtermctl session split visibility on --target "$sid" "${wargs[@]}" >/dev/null
  sleep 1
  wd=$(sed -n 's/^WORK_DIR=//p' "$DIR/config.env" 2>/dev/null | tail -1)
  [ -n "$wd" ] && agtermctl session type --pane split --target "$sid" "${wargs[@]}" \
    "cd '$wd' && clear"$'\r' >/dev/null
fi
if [ "${ov:-false}" != "true" ]; then
  agtermctl session overlay open --url "$URL" --js --navigation --pane primary \
    --target "$sid" "${wargs[@]}" >/dev/null && echo "post-deploy: page open in \"$NAME\" (left pane)"
fi
exit 0
