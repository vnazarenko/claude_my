#!/usr/bin/env bash
# Collect a read-only inventory of one server over ssh. Prints one JSON object on stdout.
#
# Usage:
#   inventory.sh <ssh_host> [--pm2-home DIR ...] [--revision-file FILE ...]
#
# - <ssh_host>         an alias from ~/.ssh/config, or user@host
# - --pm2-home DIR     a PM2_HOME on the server (repeat for more)
# - --revision-file F  a deploy REVISION file on the server (repeat for more)
#
# The server runs remote-inventory.sh (read-only; see its header). This side:
# - turns off agent forwarding, X11 and every port forward, and does not reuse a shared
#   connection, so the server gets no way back to the user's keys
# - accepts only absolute paths made of plain characters, without "..", because the
#   remote shell reads the arguments again
# - checks that the answer is valid JSON and sets "host" to <ssh_host>
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
remote="$here/remote-inventory.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { die "usage: inventory.sh <ssh_host> [--pm2-home DIR ...] [--revision-file FILE ...]"; }

[ $# -ge 1 ] || usage
host=$1
shift
[[ $host =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ ]] || die "bad ssh host: '$host'"
command -v ssh >/dev/null 2>&1 || die "ssh not on PATH"
command -v jq >/dev/null 2>&1 || die "jq not on PATH"
[ -f "$remote" ] || die "remote-inventory.sh not found next to $0"

args=()
while [ $# -gt 0 ]; do
  [ "$1" = "--pm2-home" ] || [ "$1" = "--revision-file" ] || die "unknown argument: $1"
  [ $# -ge 2 ] || die "$1 needs a path"
  p=$2
  [[ $p == /* ]] || die "$1 must be an absolute path: '$p'"
  [[ $p != *..* ]] || die "$1 must not contain '..': '$p'"
  [[ $p =~ ^[A-Za-z0-9_./@+-]+$ ]] || die "$1 has characters that are not allowed: '$p'"
  args+=("$1" "$p")
  shift 2
done

out=$(ssh -a -x -T \
  -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
  -o BatchMode=yes -o ConnectTimeout=20 \
  -o ControlMaster=no -o ControlPath=none -o PermitLocalCommand=no \
  -- "$host" bash -s -- ${args[@]+"${args[@]}"} < "$remote")
rc=$?
[ "$rc" -eq 0 ] || die "inventory on $host failed (ssh exit $rc)"

jq -e --arg host "$host" '.host = $host' <<< "$out" 2>/dev/null \
  || die "$host did not return valid JSON"
