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
# - accepts only absolute paths made of plain characters, without "..", at most 128 characters,
#   because the remote shell reads the arguments again
# - stops a connection that hangs (ServerAlive: about 1 minute without an answer)
# - treats the answer as untrusted data: other users on the server can name folders and run
#   their own binaries, and the server itself can lie. So no free text from the server gets out:
#   - the answer must be one JSON object, at most MAX_BYTES; else it fails
#   - only the known fields are kept, each in its expected shape (a version, a package name, a git
#     sha, a number, a date, a plain path without spaces, ...); a value of another shape is left
#     out and counted; a pm2 home or a revision file must be one this call asked for
#   - the path of a binary is kept only in a form root chose: a system folder (/usr, /bin, /sbin,
#     /lib*, /opt, /snap; not an nvm tree there), or an nvm Node path .../versions/node/vX.Y.Z/bin/node;
#     a container's Node only at /usr/bin or /usr/local/bin. Any other path is left out and only
#     counted in "filtered.other_paths": any user can run a binary from a folder they name
#   - each list has a cap; entries over it are left out and counted, and filtered.truncated is true
#   - "filtered.dropped" and "filtered.other_paths" give the counts per field, added to the
#     counts the server sent
# - sets "host" to <ssh_host>
set -uo pipefail
export LC_ALL=C   # the [A-Za-z...] ranges below mean ASCII only

here="$(cd "$(dirname "$0")" && pwd -P)"
remote="$here/remote-inventory.sh"
filter="$here/inventory-clean.jq"   # the jq filter for the answer
MAX_BYTES=2000000   # the raw answer. A real one is far smaller; the caps keep it under ~1.5 MB.

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }   # die <message> [exit code]
usage() { die "usage: inventory.sh <ssh_host> [--pm2-home DIR ...] [--revision-file FILE ...]"; }

[ $# -ge 1 ] || usage
host=$1
shift
[[ $host =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ ]] || die "bad ssh host: '$host'"
command -v ssh >/dev/null 2>&1 || die "ssh not on PATH"
command -v jq >/dev/null 2>&1 || die "jq not on PATH"
[ -f "$remote" ] || die "remote-inventory.sh not found next to $0"
[ -f "$filter" ] || die "inventory-clean.jq not found next to $0"

args=()
homes=""
rev_files=""
while [ $# -gt 0 ]; do
  [ "$1" = "--pm2-home" ] || [ "$1" = "--revision-file" ] || die "unknown argument: $1"
  [ $# -ge 2 ] || die "$1 needs a path"
  p=$2
  [[ $p == /* ]] || die "$1 must be an absolute path: '$p'"
  [[ $p != *..* ]] || die "$1 must not contain '..': '$p'"
  [[ $p =~ ^[A-Za-z0-9_./@+-]+$ ]] || die "$1 has characters that are not allowed: '$p'"
  [ ${#p} -le 128 ] || die "$1 is longer than 128 characters: '$p'"
  if [ "$1" = "--pm2-home" ]; then homes+="$p"$'\n'; else rev_files+="$p"$'\n'; fi
  args+=("$1" "$p")
  shift 2
done

# head -c: never hold more than MAX_BYTES + 1 of the answer. ssh's own exit code is kept.
out=$(ssh -a -x -T \
  -o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes \
  -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
  -o ControlMaster=no -o ControlPath=none -o PermitLocalCommand=no \
  -- "$host" bash -s -- ${args[@]+"${args[@]}"} < "$remote" | head -c $((MAX_BYTES + 1)); exit "${PIPESTATUS[0]}")
rc=$?
[ ${#out} -le $MAX_BYTES ] || die "$host returned more than $MAX_BYTES bytes: refused"
[ "$rc" -eq 0 ] || die "inventory on $host failed (ssh exit $rc)"

jq -e -s --arg host "$host" --arg homes "$homes" --arg rev_files "$rev_files" -f "$filter" <<< "$out" 2>/dev/null \
  || die "$host did not return a valid inventory (one JSON object)"
