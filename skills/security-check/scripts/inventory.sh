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

here="$(cd "$(dirname "$0")" && pwd -P)"
remote="$here/remote-inventory.sh"
MAX_BYTES=2000000   # the raw answer. A real one is far smaller; the caps keep it under ~1.5 MB.

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

# The same shapes as in remote-inventory.sh.
# shellcheck disable=SC2016 # $host, $homes and $rev_files are jq variables
clean='
  def VER: "^v?([0-9]{1,5}:)?[0-9][A-Za-z0-9.+~-]{0,63}$";
  def SEMVER: "^[0-9]{1,3}\\.[0-9]{1,4}\\.[0-9]{1,4}$";
  def RUBY: "^[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{1,3}(-[a-z]{1,8}[0-9]{0,4})?$";
  def PKG: "^[a-z0-9][a-z0-9.+-]{1,63}$";
  def WORD: "^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$";
  def ALIAS: "^(v?[0-9]{1,3}(\\.[0-9]{1,4}){0,2}|lts/(\\*|-?[0-9]{1,2}|[a-z]{2,12})|node|stable|unstable|system|iojs)$";
  def IMAGE: "^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,127}$";
  def IMAGE_ID: "^(sha256:)?[0-9a-f]{12,64}$";
  def NVM: "^(/root/\\.nvm|/home/[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}/\\.nvm|/usr/local/nvm|/opt/nvm)$";
  def NVM_NODE: "^(/root/\\.nvm|/home/[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}/\\.nvm|/usr/local/nvm|/opt/nvm)/versions/node/v[0-9]{1,3}\\.[0-9]{1,4}\\.[0-9]{1,4}/bin/node$";
  def SHA: "^[0-9a-f]{7,40}$";
  def DATE: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{4})$";
  def SYS: "^/(usr|bin|sbin|lib|lib32|lib64|libx32|opt|snap)/";
  def NVM_TREE: "/versions/node/|^/(usr/local|opt)/nvm/";
  def CT_NODE: "^/usr/(local/)?bin/node(js)?$";

  def o: if type == "object" then . else {} end;
  def arr: if type == "array" then . else [] end;
  # good($t): the value has the shape $t: a regex above, or "num", "bool", "path",
  # "named" (a binary path root chose), "ct_node" (a Node path in a container).
  def good($t):
    if $t == "num" then type == "number" and . >= 0 and . <= 1000000000
    elif $t == "bool" then type == "boolean"
    elif $t == "path" then type == "string" and length <= 128 and test("^/[A-Za-z0-9_./@+-]+$") and (contains("..") | not)
    elif $t == "named" then good("path") and (test(NVM_NODE) or (test(SYS) and (test(NVM_TREE) | not)))
    elif $t == "ct_node" then good("path") and test(CT_NODE)
    else type == "string" and test($t) end;
  # unnamed($t): a string that is not a good $t: a path a user may have named. Only counted.
  def unnamed($t): type == "string" and (good($t) | not);
  def node_t: if type == "object" and .container == true then "ct_node" else "named" end;
  def node_unnamed: type == "object" and (node_t as $t | .path | unnamed($t));
  def pm2_unnamed: type == "object" and (.daemon_node_path | unnamed("named"));
  # counts($here; $there): {<field>: <count here + count the server sent>}, only counts over 0.
  def counts($here; $there):
    reduce ($here | keys[]) as $k ({};
      ($here[$k] + ($there[$k] | if good("num") then floor else 0 end)) as $n
      | if $n > 0 then .[$k] = $n else . end);
  # chk($t): {v: the value, or null; b: 1 when a value of the wrong shape was left out}.
  def chk($t): if . == null then {v: null, b: 0} elif good($t) then {v: ., b: 0} else {v: null, b: 1} end;
  # obj($spec): exactly the keys of $spec, each value checked. Other keys are left out.
  def obj($spec):
    o as $o
    | reduce ($spec | to_entries[]) as $f ({v: {}, b: 0};
        ($o[$f.key] | chk($f.value)) as $c | .v[$f.key] = $c.v | .b += $c.b);
  # entry($spec; $key): obj($spec); the whole entry is left out when $key is not good.
  def entry($spec; $key):
    if type != "object" then {v: null, b: 0}
    else obj($spec) | if .v[$key] == null then {v: null, b: 0} else . end end;
  # list($max; f): an array; f gives {v, b} per entry (v null: left out); at most $max kept.
  # {v: the kept entries, b: entries and values left out, t: true when over $max}
  def list($max; f):
    (if type == "array" then . else [] end) as $in
    | [$in[] | f | select(.v != null)] as $ok
    | $ok[:$max] as $kept
    | {v: [$kept[].v], b: (($in | length) - ($kept | length) + ([$kept[].b] | add // 0)),
       t: (($ok | length) > $max)};

  def apt_e:
    if type != "object" then {v: null, b: 0}
    else entry({package: PKG, source: PKG, installed: VER, candidate: VER, origin: WORD}; "package") as $e
      | (.archives | list(8; chk(WORD))) as $a
      | if $e.v == null then $e else {v: ($e.v + {archives: $a.v}), b: ($e.b + $a.b)} end
    end;
  def revs($files):
    if type != "object" then {v: {}, b: 0}
    else [to_entries[] | select(.key | IN($files[])) | {key, c: (.value | chk(SHA))}] as $ok
      | {v: ($ok | map({key, value: .c.v}) | from_entries),
         b: (length - ($ok | length) + ([$ok[].c.b] | add // 0))}
    end;

  if length != 1 or (.[0] | type) != "object" then error("not one JSON object") else .[0] end
  | . as $r
  | ($homes | split("\n") | map(select(length > 0))) as $H
  | ($rev_files | split("\n") | map(select(length > 0))) as $R
  | ($r.collected_at | chk(DATE)) as $ca
  | ($r.os | obj({id: WORD, version_id: WORD, codename: WORD, kernel_running: VER,
                  kernel_newest_installed: VER, reboot_required: "bool"})) as $os
  | ($r.os | o | .reboot_required_pkgs | list(50; chk(PKG))) as $rpk
  | ($r.apt | o | .lists_age_hours | chk("num")) as $age
  | ($r.apt | o | .upgradable | if . == null then {v: null, b: 0, t: false} else list(2000; apt_e) end) as $upg
  | ($r.node | arr | map(select(node_unnamed | not))
     | list(50; node_t as $t | entry({path: $t, version: VER, running: "num", container: "bool"}; "path"))) as $node
  | ($r.nvm | list(50; entry({nvm_dir: NVM, default_alias: ALIAS}; "nvm_dir"))) as $nvm
  | ($r.pm2 | arr | map(if pm2_unnamed then .daemon_node_path = null else . end)
     | list(20; entry({pm2_home: "path", pid_file: "bool", daemon_running: "bool",
                       daemon_node_path: "named", daemon_node: VER, pm2_version: SEMVER}; "pm2_home")
                | if .v != null and (.v.pm2_home | IN($H[]) | not) then {v: null, b: 0} else . end)) as $pm2
  | ($r.services | obj({nginx: VER, postgresql: VER, redis: VER, clickhouse: VER, docker: VER,
                        containerd: VER, openssh: VER, openssl: VER})) as $svc
  | ($r.ruby | list(50; chk(RUBY))) as $ruby
  | ($r.python3 | chk(VER)) as $py
  | ($r.docker_images | if . == null then {v: null, b: 0, t: false}
                        else list(50; entry({image: IMAGE, id: IMAGE_ID, created: DATE}; "image")) end) as $img
  | ($r.running_deleted_exe | arr | map(select(unnamed("named") | not)) | list(50; chk("named"))) as $del
  | ($r.revisions | revs($R)) as $rev
  | ({collected_at: $ca.b, os: $os.b, reboot_required_pkgs: $rpk.b, apt: ($age.b + $upg.b),
      node: $node.b, nvm: $nvm.b, pm2: $pm2.b, services: $svc.b, ruby: $ruby.b, python3: $py.b,
      docker_images: $img.b, running_deleted_exe: $del.b, revisions: $rev.b, dpkg: 0}) as $here
  | ({node: ($r.node | arr | map(select(node_unnamed)) | length),
      pm2: ($r.pm2 | arr | map(select(pm2_unnamed)) | length),
      running_deleted_exe: ($r.running_deleted_exe | arr | map(select(unnamed("named"))) | length)}) as $here_paths
  | ($r.filtered | o) as $rf
  | {collected_at: $ca.v, host: $host,
     os: ($os.v + {reboot_required_pkgs: $rpk.v}),
     apt: {lists_age_hours: $age.v, upgradable: $upg.v},
     node: $node.v, nvm: $nvm.v, pm2: $pm2.v, services: $svc.v, ruby: $ruby.v, python3: $py.v,
     docker_images: $img.v, running_deleted_exe: $del.v, revisions: $rev.v,
     filtered: {
       truncated: ($rf.truncated == true or ([$rpk, $upg, $node, $nvm, $pm2, $ruby, $img, $del] | any(.t))),
       dropped: counts($here; $rf.dropped | o),
       other_paths: counts($here_paths; $rf.other_paths | o)}}'
jq -e -s --arg host "$host" --arg homes "$homes" --arg rev_files "$rev_files" "$clean" <<< "$out" 2>/dev/null \
  || die "$host did not return a valid inventory (one JSON object)"
