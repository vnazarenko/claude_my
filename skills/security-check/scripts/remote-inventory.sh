#!/usr/bin/env bash
# Read-only inventory of one Linux server (Ubuntu or Debian). Prints one JSON object on stdout.
#
# It runs ON the server. inventory.sh sends it over ssh:
#   ssh <host> bash -s -- [--pm2-home DIR ...] [--revision-file FILE ...] < remote-inventory.sh
#
#   --pm2-home DIR        a PM2_HOME; its pm2.pid shows which Node the pm2 daemon runs
#   --revision-file FILE  a deploy REVISION file; only a git sha is passed on
#
# Read-only by construction. tests/inventory_test.sh checks these rules on every run:
# - external commands come only from the allowlist in the test
# - apt-get runs only with --simulate, docker only "ps" and "images" with a --format of named
#   safe fields (no env, labels, mounts or command), dd only reads (with
#   iflag=nofollow,nonblock, no of=); nothing writes a file
# - pm2, nvm, npm and systemctl are never run: they can start daemons or write files
# - process facts come only from the /proc/<pid>/exe link and the /proc/<pid>/ns/mnt link (which
#   mount namespace: the host's, or a container's): no process arguments, no process
#   environment, no app config files. /proc/self/cwd is read too: the script's own folder
#   (read_plain)
# - a file under a folder other users can write (nvm, pm2, deploys) is read only through
#   read_plain: it goes into the folder and checks with the kernel that it is the folder named
#   (no link on the way), then dd opens the file there once, with O_NOFOLLOW and O_NONBLOCK,
#   under timeout. So root never follows a link put there (in the folders or the file, also not
#   one swapped in after a check) and never waits on a FIFO. Only a value of the expected shape
#   is passed on (a version, a pid, a git sha)
# - a missing tool or file gives null or [], never an error. A tool that fails gives null or
#   "error", never an empty list: "apt.status" says whether the upgrade list is complete
# - a value leaves the server only in the shape it should have (a version, a package name, a
#   plain path without spaces, ...): other users can name folders and run their own binaries, so
#   no free text gets out. A value of the wrong shape is dropped and counted; each list has a cap,
#   and entries over it are dropped and counted too ("filtered" in the output). inventory.sh
#   checks all of this again on the user's side.
# - a list that other users can fill (nvm folders, rubies, their binaries) is cut to MAX_SORT
#   short entries before "sort": a long input would make sort write temp files
# - the path of a binary leaves the server only when root chose every part of it: a file in a
#   system folder (/usr, /bin, /sbin, /lib*, /opt, /snap) whose folders only root can write, or an
#   nvm Node path of the strict form (.../versions/node/vX.Y.Z/bin/node). Any other path is only
#   counted ("filtered.other_paths"): any user can run a binary from a folder they name.
# The test also runs this script in a container and checks that no file changed.
#
# Keep the style simple, the test reads this file line by line: one command per line,
# no heredocs, no backticks, no "case", no multi-line $( ... ). No here-strings ("<<<"): bash
# before 5.1 writes them to a temp file. No "< $file": read such a file with read_plain.
set -uo pipefail
export LC_ALL=C

die() { printf 'ERROR: remote-inventory: %s\n' "$1" >&2; exit "${2:-1}"; }   # die <message> [exit code]

# ---- what may leave the server -----------------------------------------------------------------

MAX_LIST=50     # entries per list
MAX_APT=2000    # pending upgrades
MAX_ARCH=8      # archives per upgrade
MAX_PATH=128    # characters in a path
MAX_PS=500      # lines of "docker ps" (one per running container)
MAX_IMG=5000    # lines of "docker images" (one per image name), read to find the running images
MAX_SORT=1000   # entries of a list other users can fill, before "sort" (see bounded)
# The shapes. inventory.sh has the same ones.
VER_RE='^v?([0-9]{1,5}:)?[0-9][A-Za-z0-9.+~-]{0,63}$'
RUBY_RE='^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,3}(-[a-z]{1,8}[0-9]{0,4})?$'
PKG_RE='^[a-z0-9][a-z0-9.+-]{1,63}$'
WORD_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'
ALIAS_RE='^(v?[0-9]{1,3}(\.[0-9]{1,4}){0,2}|lts/(\*|-?[0-9]{1,2}|[a-z]{2,12})|node|stable|unstable|system|iojs)$'
IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,127}$'
IMAGE_ID_RE='^sha256:[0-9a-f]{64}$'     # an image id, as "docker ps/images --no-trunc" print it
DIGEST_RE='^sha256:[0-9a-f]{64}$'       # a repo digest (name@sha256:...)
RAW_IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$'   # a "docker ps" image, before it is shortened
HEX_RE='^[0-9a-f]{4,64}$'               # an image id prefix, as a container can be started with
NVM_RE='^(/root/\.nvm|/home/[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}/\.nvm|/usr/local/nvm|/opt/nvm)$'
NVM_NODE_RE='^(/root/\.nvm|/home/[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}/\.nvm|/usr/local/nvm|/opt/nvm)/versions/node/v[0-9]{1,3}\.[0-9]{1,4}\.[0-9]{1,4}/bin/node$'
DOCKER_DATE_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) ([+-][0-9]{4})'
SHA_RE='^[0-9a-f]{7,40}$'      # a git sha in a REVISION file
PID_RE='^[0-9]+$'              # a process id (a /proc folder, a pm2.pid file)
# System folders: only root writes them. An nvm tree is not one, even inside them: its group
# may write it, so a path there must have the strict nvm form.
SYS_RE='^/(usr|bin|sbin|lib|lib32|lib64|libx32|opt|snap)/'
NVM_TREE_RE='/versions/node/|^/(usr/local|opt)/nvm/'
# A Node in a container: the path inside the image. Only the usual places are passed on.
CT_NODE_RE='^/usr/(local/)?bin/node(js)?$'
# The last line of a stream when its command worked ("cmd && printf ..."). No line of apt-get or
# "docker ps" is this text, so a stream without it means the command failed.
END_MARK='== end of the list =='

declare -A dropped=() others=()
truncated=false

# drop <list>: count one value left out of <list>.
drop() { dropped[$1]=$(( ${dropped[$1]:-0} + 1 )); }
# unnamed <list>: count one path left out of <list> because a user may have named it.
unnamed() { others[$1]=$(( ${others[$1]:-0} + 1 )); }

# shaped <list> <regex> <value>: true when the value is empty or has the shape; else counts it.
shaped() {
  [ -z "$3" ] && return 0
  [[ $3 =~ $2 ]] && return 0
  drop "$1"
  return 1
}

# room <list> <entries now> <cap>: true when one more entry fits; else counts it as dropped.
room() {
  [ "$2" -lt "$3" ] && return 0
  drop "$1"
  truncated=true
  return 1
}

# A path: absolute, plain characters, no spaces, no "..", at most MAX_PATH characters.
safe_path() { [[ ${#1} -le $MAX_PATH && $1 == /* && $1 != *..* && $1 =~ ^[A-Za-z0-9_./@+-]+$ ]]; }

# root_tree <path>: every folder from / down to the path's folder is a real folder (not a link),
# owned by root and not writable by group or others. Then only root could have named the path.
root_tree() {
  local d=${1%/*} dirs ok
  dirs=(/)
  while [ -n "$d" ]; do
    dirs+=("$d")
    d=${d%/*}
  done
  ok=$(find "${dirs[@]}" -maxdepth 0 -type d -user root ! -perm /022 -printf x 2>/dev/null)
  [ "${#ok}" -eq "${#dirs[@]}" ]
}

# named <path>: a file is at this path on this host, and root chose every part of its name: an
# nvm Node path of the strict form, or a path in a system folder (not in an nvm tree) under
# folders that only root can write. Every other path is only counted.
named() {
  safe_path "$1" || return 1
  [ -e "$1" ] || return 1
  [[ $1 =~ $NVM_NODE_RE ]] && return 0
  [[ $1 =~ $SYS_RE && ! $1 =~ $NVM_TREE_RE ]] || return 1
  root_tree "$1"
}

# bounded <list> <value ...>: sets "batch" to the values that are plain paths (safe_path), at most
# MAX_SORT of them; the rest is counted. A list that other users can fill goes through it before
# "sort": then sort gets at most MAX_SORT short lines and sorts them in memory, with no temp file.
bounded() {
  local list=$1 v
  shift
  batch=()
  for v in "$@"; do
    if ! safe_path "$v"; then unnamed "$list"; continue; fi
    room "$list" ${#batch[@]} $MAX_SORT || continue
    batch+=("$v")
  done
}

# read_plain <file>: the first 64 KiB of a file in a folder other users can write, on stdout.
# Nothing when the folder is not the one named, or the file is not a regular file.
# - The folder: a subshell goes into it, then asks the kernel where it is (/proc/self/cwd: a path
#   with no link in it). Another place (a link on the way) gives nothing. A link swapped in later
#   changes nothing: the subshell stays in the folder it checked. One link is allowed: Capistrano's
#   "<deploy>/current" to "<deploy>/releases/<name>".
# - The file: dd opens it once, in that folder, with O_NOFOLLOW (a symlink is not followed, also
#   not one swapped in) and O_NONBLOCK (a FIFO gives nothing at once instead of waiting); timeout
#   bounds the rest.
# Use it as "read ... < <(read_plain FILE)": a pipe, no temp file.
read_plain() {
  local dir=${1%/*} leaf=${1##*/}
  (
    cd -P -- "$dir" 2>/dev/null || exit 0
    real=$(readlink /proc/self/cwd)
    if [ "$real" != "$dir" ] && [[ $dir != */current || ${real%/*} != "${dir%/current}/releases" ]]; then exit 0; fi
    timeout 5 dd if="./$leaf" iflag=nofollow,nonblock bs=65536 count=1 status=none 2>/dev/null
  )
}

pm2_homes=()
rev_files=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--pm2-home" ] && [ $# -ge 2 ]; then
    safe_path "$2" || die "bad path: $2" 2
    pm2_homes+=("$2")
    shift 2
  elif [ "$1" = "--revision-file" ] && [ $# -ge 2 ]; then
    safe_path "$2" || die "bad path: $2" 2
    rev_files+=("$2")
    shift 2
  else
    die "unknown argument: $1" 2
  fi
done

# ---- JSON helpers ----------------------------------------------------------------------------

# One JSON string. An empty value becomes null.
js() {
  local s=$1
  if [ -z "$s" ]; then printf 'null'; return 0; fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//[$'\001'-$'\037']/}
  printf '"%s"' "$s"
}

# A JSON array from items that are already JSON.
jarr() { local IFS=,; printf '[%s]' "$*"; }

# ---- installed packages (dpkg) -----------------------------------------------------------------

declare -A dpkg_ver=() dpkg_src=()
if command -v dpkg-query >/dev/null 2>&1; then
  while IFS=$'\t' read -r p src ver st; do
    [ "${st:1:1}" = "i" ] || continue
    if [[ ! $p =~ $PKG_RE || ! $ver =~ $VER_RE ]]; then drop dpkg; continue; fi
    [[ $src =~ $PKG_RE ]] || src=$p
    dpkg_ver[$p]=$ver
    dpkg_src[$p]=$src
  done < <(dpkg-query -W -f='${Package}\t${source:Package}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null)
fi

# Version of the first installed package from the list.
pkg() {
  local p
  for p in "$@"; do
    if [ -n "${dpkg_ver[$p]:-}" ]; then printf '%s' "${dpkg_ver[$p]}"; return 0; fi
  done
}

# Version of the highest-numbered installed package whose name matches a regex.
newest_pkg() {
  local p best="" names=()
  for p in "${!dpkg_ver[@]}"; do
    [[ $p =~ $1 ]] && names+=("$p")
  done
  [ ${#names[@]} -gt 0 ] || return 0
  read -r best < <(printf '%s\n' "${names[@]}" | sort -rV)
  printf '%s' "${dpkg_ver[$best]}"
}

# ---- OS, kernel, reboot ------------------------------------------------------------------------

os_id="" os_ver="" os_code=""
if [ -r /etc/os-release ]; then
  while IFS='=' read -r k v; do
    v=${v#\"}
    v=${v%\"}
    if [ "$k" = "ID" ]; then os_id=$v
    elif [ "$k" = "VERSION_ID" ]; then os_ver=$v
    elif [ "$k" = "VERSION_CODENAME" ]; then os_code=$v
    fi
  done < /etc/os-release
fi
shaped os "$WORD_RE" "$os_id" || os_id=""
shaped os "$WORD_RE" "$os_ver" || os_ver=""
shaped os "$WORD_RE" "$os_code" || os_code=""

kernel_running=$(uname -r 2>/dev/null)
shaped os "$VER_RE" "$kernel_running" || kernel_running=""
# The machine (x86_64, aarch64): an image is scanned for the server's platform, not the Mac's.
machine=$(uname -m 2>/dev/null)
shaped os "$WORD_RE" "$machine" || machine=""
kernels=()
for f in /boot/vmlinuz-*; do
  [ -e "$f" ] && kernels+=("${f#/boot/vmlinuz-}")
done
kernel_newest=""
if [ ${#kernels[@]} -gt 0 ]; then
  read -r kernel_newest < <(printf '%s\n' "${kernels[@]}" | sort -rV)
fi
shaped os "$VER_RE" "$kernel_newest" || kernel_newest=""

reboot_required=false
[ -e /var/run/reboot-required ] && reboot_required=true
reboot_pkgs=()
if [ -r /var/run/reboot-required.pkgs ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    shaped reboot_required_pkgs "$PKG_RE" "$p" || continue
    room reboot_required_pkgs ${#reboot_pkgs[@]} $MAX_LIST || continue
    reboot_pkgs+=("$(js "$p")")
  done < <(sort -u /var/run/reboot-required.pkgs)
fi

# ---- apt: every pending upgrade, with the repo it comes from -----------------------------------

# No "apt update": the age of the package lists says how fresh this view is.
# A Release file keeps the archive's date, so it can look a few hours older than the last
# update; the stamp that apt's daily job writes on success is exact, when it exists.
lists_age=""
newest=""
stamp=""
read -r newest < <(find /var/lib/apt/lists -maxdepth 1 -type f -name '*Release' -printf '%T@\n' 2>/dev/null | sort -rn)
read -r stamp < <(find /var/lib/apt/periodic/update-success-stamp -maxdepth 0 -printf '%T@\n' 2>/dev/null)
if [ -n "$stamp" ] && { [ -z "$newest" ] || [ "${stamp%.*}" -gt "${newest%.*}" ]; }; then
  newest=$stamp
fi
if [ -n "$newest" ]; then
  now=$(date +%s)
  age=$(( now - ${newest%.*} ))
  lists_age=$(( age / 3600 ))
fi

# A dry run lists each upgrade as
#   Inst <pkg> [<installed>] (<candidate> <Label>:<release>/<archive>, ... [<arch>])
# The label is the repo's name (Ubuntu, Docker CE, ...). It can be missing for vendor repos.
# A space in the label becomes "_" (Docker_CE): no value in the output has a space.
# The cache options stop apt from writing its binary cache; the empty Planner log stops it from
# rewriting /var/log/apt/eipp.log.xz; NoLocking leaves the dpkg lock alone.
# apt-get fails (broken lists, ...) → status "error" and upgradable null: not checked. Never an
# empty list, which would read as "nothing pending". No apt-get → status and upgradable null.
upg_json=null
apt_state=""
if command -v apt-get >/dev/null 2>&1; then
  upg=()
  apt_ok=false
  re='^Inst ([^ ]+) \[([^]]*)\] \(([^ ]+) (.*)\)'
  while IFS= read -r line; do
    if [ "$line" = "$END_MARK" ]; then apt_ok=true; continue; fi
    [[ $line =~ $re ]] || continue
    name=${BASH_REMATCH[1]%%:*}
    installed=${BASH_REMATCH[2]}
    candidate=${BASH_REMATCH[3]}
    rel=${BASH_REMATCH[4]% \[*\]}
    shaped apt "$PKG_RE" "$name" || continue
    room apt ${#upg[@]} $MAX_APT || continue
    shaped apt "$VER_RE" "$installed" || installed=""
    shaped apt "$VER_RE" "$candidate" || candidate=""
    origin=""
    archives=()
    # The parts of "<label>:<release>/<archive>, ...", split here (a here-string could write a
    # temp file).
    rest="$rel,"
    while [ -n "$rest" ]; do
      part=${rest%%,*}
      rest=${rest#*,}
      part=${part# }
      [ -n "$part" ] || continue
      label=""
      if [[ $part == */* ]]; then
        archive=${part##*/}
        head=${part%/*}
        [[ $head == *:* ]] && label=${head%:*}
      elif [[ $part == *:* ]]; then
        archive=${part##*:}
        label=${part%:*}
      else
        archive=$part
      fi
      [ -z "$origin" ] && origin=${label// /_}
      shaped apt "$WORD_RE" "$archive" || continue
      room apt ${#archives[@]} $MAX_ARCH || continue
      archives+=("$(js "$archive")")
    done
    shaped apt "$WORD_RE" "$origin" || origin=""
    src=${dpkg_src[$name]:-$name}
    upg+=("{\"package\":$(js "$name"),\"source\":$(js "$src"),\"installed\":$(js "$installed"),\"candidate\":$(js "$candidate"),\"origin\":$(js "$origin"),\"archives\":$(jarr ${archives[@]+"${archives[@]}"})}")
  done < <(apt-get --simulate -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Dir::Log::Planner= -o Debug::NoLocking=1 dist-upgrade 2>/dev/null && printf '%s\n' "$END_MARK")
  if [ "$apt_ok" = true ]; then
    apt_state=ok
    upg_json=$(jarr ${upg[@]+"${upg[@]}"})
  else
    apt_state=error
  fi
fi

# ---- running binaries, from /proc/<pid>/exe links only -----------------------------------------

# The link of a process in a container names the path INSIDE the container. When the link's
# target is not the host file at that path ("-ef" compares device and inode), the process is
# counted as a container process, not as the host binary.
# A binary replaced on disk ("<path> (deleted)") cannot be compared: its file is gone. It is the
# host's only when the process is in the host's mount namespace (host_ns); else it is counted as
# a container's too (a container, or a service with its own mounts: its version is not known).
host_mnt=$(readlink /proc/1/ns/mnt 2>/dev/null)
# host_ns <pid>: the process is in the mount namespace of PID 1, so a path in its exe link is the
# host's path. A link that cannot be read (the process is gone, or no access) gives false.
host_ns() {
  local p=$1 ns
  ns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null)
  [ -n "$host_mnt" ] && [ "$ns" = "$host_mnt" ]
}
declare -A running=() deleted=() in_container=()
while IFS=$'\t' read -r dir exe; do
  [ -n "$exe" ] || continue
  pid=${dir##*/}
  [[ $pid =~ $PID_RE ]] || continue
  if [[ $exe == *' (deleted)' ]]; then
    exe=${exe% (deleted)}
    if ! host_ns "$pid"; then
      [ -d "/proc/$pid" ] && in_container[$exe]=$(( ${in_container[$exe]:-0} + 1 ))
      continue
    fi
    deleted[$exe]=1
  elif [ ! "/proc/$pid/exe" -ef "$exe" ]; then
    [ -d "/proc/$pid" ] && in_container[$exe]=$(( ${in_container[$exe]:-0} + 1 ))
    continue
  fi
  running[$exe]=$(( ${running[$exe]:-0} + 1 ))
done < <(find /proc/[0-9]*/exe -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null)

# A binary replaced on disk but still running, in the host's mount namespace: the old code runs
# until a restart. "named" wants a file at that path now (the update put a new one there).
deleted_json=()
bounded running_deleted_exe "${!deleted[@]}"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! named "$p"; then unnamed running_deleted_exe; continue; fi
  room running_deleted_exe ${#deleted_json[@]} $MAX_LIST || continue
  deleted_json+=("$(js "$p")")
done < <(printf '%s\n' ${batch[@]+"${batch[@]}"} | sort)

# ---- Node.js: nvm trees and every running "node" binary ----------------------------------------

# "v24.21.0" from an nvm path; the nodejs package version for the system binary; else empty.
node_version() {
  if [[ $1 =~ /versions/node/(v[0-9]+\.[0-9]+\.[0-9]+)/bin/node$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [ "$1" = /usr/bin/node ] || [ "$1" = /usr/bin/nodejs ]; then
    printf '%s' "${dpkg_ver[nodejs]:-}"
  fi
}

declare -A node_paths=() node_in_container=()
nvm_json=()
for nvm in /root/.nvm /home/*/.nvm /usr/local/nvm /opt/nvm; do
  [ -d "$nvm/versions/node" ] || continue
  shaped nvm "$NVM_RE" "$nvm" || continue
  room nvm ${#nvm_json[@]} $MAX_LIST || continue
  # The "default" alias as written ("22", "lts/*", ...). nvm resolves it; Claude does too.
  dflt=""
  read -r dflt < <(read_plain "$nvm/alias/default")
  shaped nvm "$ALIAS_RE" "$dflt" || dflt=""
  nvm_json+=("{\"nvm_dir\":$(js "$nvm"),\"default_alias\":$(js "$dflt")}")
  for bin in "$nvm"/versions/node/*/bin/node; do
    [ -e "$bin" ] && node_paths[$bin]=1
  done
done
for exe in "${!running[@]}"; do
  [[ ${exe##*/} == node || ${exe##*/} == nodejs ]] && node_paths[$exe]=1
done
for exe in "${!in_container[@]}"; do
  [[ ${exe##*/} == node || ${exe##*/} == nodejs ]] && node_in_container[$exe]=1
done

node_json=()
bounded node "${!node_paths[@]}"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! named "$p"; then unnamed node; continue; fi
  room node ${#node_json[@]} $MAX_LIST || continue
  node_json+=("{\"path\":$(js "$p"),\"version\":$(js "$(node_version "$p")"),\"running\":${running[$p]:-0},\"container\":false}")
done < <(printf '%s\n' ${batch[@]+"${batch[@]}"} | sort)
# A container's Node: its version is the image's, not the host package's.
bounded node "${!node_in_container[@]}"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! [[ $p =~ $CT_NODE_RE ]]; then unnamed node; continue; fi
  room node ${#node_json[@]} $MAX_LIST || continue
  node_json+=("{\"path\":$(js "$p"),\"version\":null,\"running\":${in_container[$p]},\"container\":true}")
done < <(printf '%s\n' ${batch[@]+"${batch[@]}"} | sort)

# ---- pm2: the daemon's Node and the pm2 version, read from files -------------------------------

# The top "version" of a package.json, when it is a plain X.Y.Z.
json_version() {
  local line re='^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.[0-9]{1,4}\.[0-9]{1,4})"'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  done < <(read_plain "$1")
}

pm2_json=()
for home in ${pm2_homes[@]+"${pm2_homes[@]}"}; do
  pid="" exe="" nver="" pver="" pidfile=false up=false
  read -r pid < <(read_plain "$home/pm2.pid")
  [ -n "$pid" ] && pidfile=true
  [[ $pid =~ $PID_RE ]] || pid=""
  # The pid file is the user's: it can name any process. Its binary is passed on only when it is
  # the host file at that path (or, when replaced, the process is in the host's mount namespace
  # and a file is there now) and root named it.
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    up=true
    host=true
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if [[ $exe == *' (deleted)' ]]; then
      exe=${exe% (deleted)}
      host_ns "$pid" || host=false
    elif [ -n "$exe" ] && [ ! "/proc/$pid/exe" -ef "$exe" ]; then
      host=false
    fi
    if [ -n "$exe" ] && { [ "$host" = false ] || ! named "$exe"; }; then
      unnamed pm2
      exe=""
    fi
  fi
  if [ -n "$exe" ]; then
    nver=$(node_version "$exe")
    pver=$(json_version "${exe%/bin/node}/lib/node_modules/pm2/package.json")
  fi
  pm2_json+=("{\"pm2_home\":$(js "$home"),\"pid_file\":$pidfile,\"daemon_running\":$up,\"daemon_node_path\":$(js "$exe"),\"daemon_node\":$(js "$nver"),\"pm2_version\":$(js "$pver")}")
done

# ---- services (package versions) ---------------------------------------------------------------

services_json="{\"nginx\":$(js "$(pkg nginx nginx-core nginx-full nginx-extras nginx-light)"),"
services_json+="\"postgresql\":$(js "$(newest_pkg '^postgresql-[0-9]+$')"),"
services_json+="\"redis\":$(js "$(pkg redis-server)"),"
services_json+="\"clickhouse\":$(js "$(pkg clickhouse-server)"),"
services_json+="\"docker\":$(js "$(pkg docker-ce docker.io)"),"
services_json+="\"containerd\":$(js "$(pkg containerd.io containerd)"),"
services_json+="\"openssh\":$(js "$(pkg openssh-server)"),"
services_json+="\"openssl\":$(js "$(pkg openssl)")}"
python_ver=$(newest_pkg '^python3\.[0-9]+$')

# ---- Ruby (rvm) ---------------------------------------------------------------------------------

rubies=()
# /usr/share/rvm: the Ubuntu rvm package and the common Ansible rvm role; /usr/local/rvm: the
# rvm installer run as root; ~/.rvm: a per-user install. Users can make these folders: only
# versions of the right shape, and at most MAX_SORT of them, go to "sort".
for d in /usr/share/rvm/rubies/ruby-* /usr/local/rvm/rubies/ruby-* /root/.rvm/rubies/ruby-* /home/*/.rvm/rubies/ruby-*; do
  [ -d "$d" ] || continue
  v=${d##*/ruby-}
  shaped ruby "$RUBY_RE" "$v" || continue
  room ruby ${#rubies[@]} $MAX_SORT || continue
  rubies+=("$v")
done
ruby_json=()
while IFS= read -r v; do
  [ -n "$v" ] || continue
  room ruby ${#ruby_json[@]} $MAX_LIST || continue
  ruby_json+=("$(js "$v")")
done < <(printf '%s\n' ${rubies[@]+"${rubies[@]}"} | sort -uV)

# ---- Docker: running images only (no "inspect": it prints container env) -----------------------

# "docker ps --no-trunc" prints each running container's image the way it was started ("app",
# "docker.io/library/redis:7", "app@sha256:<digest>"), as long as that name still points to the
# image the container runs. When the name points to another image now (a newer pull or build) or
# to none, it prints the id of the image the container runs ("sha256:<64 hex>"). Without
# --no-trunc docker drops the digest ("app@sha256:..." -> "app"), and "app" would then match
# the newest "app:latest", not the image the container runs.
# "docker images -a" gives each image's names (repo:tag, repo@digest), its id and build date. -a
# also lists images without a name (docker 29 hides them without it).
# "docker ps" has no field with the image id, so a name it prints is matched to an id with
# "docker images". A pull or build between the two calls moves the tag: the name would then match
# the new image, not the one the container runs. So "docker images" is read before AND after
# "docker ps": a tag the two reads do not agree on gives id, created and tag_moved null (not
# known). Only a tag that moves away and back within those seconds would still pass.
# All are read as a stream (no copy in memory, no temp file): at most MAX_PS and MAX_IMG lines.
# "docker ps" failed (no daemon, no access) → null, not an empty list.

# familiar <image>: sets "fam" to the short name "docker images" prints: no "docker.io/", and no
# "library/" for an official image ("docker.io/library/redis:7" -> "redis:7").
familiar() {
  local name=${1%%@*} rest="" first
  [ "$name" = "$1" ] || rest="@${1#*@}"
  first=${name%%/*}
  if [ "$first" != "$name" ] && [[ $first == docker.io || $first == index.docker.io ]]; then
    name=${name#*/}
  elif [ "$first" != "$name" ] && [[ $first == *[.:]* || $first == localhost ]]; then
    fam=$name$rest
    return 0
  fi
  if [[ $name == library/* && ${name#library/} != */* ]]; then name=${name#library/}; fi
  fam=$name$rest
}

# by_prefix <hex>: sets "id" to the one image id that starts with it, else empty.
by_prefix() {
  local i n=0
  id=""
  for i in "${!made[@]}"; do
    [[ $i == "sha256:$1"* ]] || continue
    id=$i
    n=$((n + 1))
  done
  [ "$n" -eq 1 ] || id=""
}

# read_images: reads "docker images -a" (at most MAX_IMG lines) into tag_id (repo:tag -> id),
# tag_digest (repo:tag -> the repo digest of that image: "repo@digest" pulls exactly it),
# digest_id (repo@digest -> id), made (id -> build date) and id_repo / id_digest (id -> one
# repo@digest name, for an image whose tag moved on).
read_images() {
  local repo tag digest id created n=0
  tag_id=()
  tag_digest=()
  digest_id=()
  made=()
  id_repo=()
  id_digest=()
  while IFS=$'\t' read -r repo tag digest id created; do
    if [ "$n" -ge "$MAX_IMG" ]; then truncated=true; continue; fi
    n=$((n + 1))
    [[ $id =~ $IMAGE_ID_RE ]] || continue
    made[$id]=$created
    [[ $repo =~ $IMAGE_RE ]] || continue
    if [ "$tag" != "<none>" ] && [ -n "$tag" ]; then tag_id[$repo:$tag]=$id; fi
    [[ $digest =~ $DIGEST_RE ]] || continue
    if [ "$tag" != "<none>" ] && [ -n "$tag" ]; then tag_digest[$repo:$tag]=$digest; fi
    digest_id[$repo@$digest]=$id
    if [ -z "${id_repo[$id]:-}" ]; then id_repo[$id]=$repo; id_digest[$id]=$digest; fi
  done < <(timeout 20 docker images -a --no-trunc --digests --format '{{.Repository}}{{"\t"}}{{.Tag}}{{"\t"}}{{.Digest}}{{"\t"}}{{.ID}}{{"\t"}}{{.CreatedAt}}' 2>/dev/null)
}

docker_json=null
if command -v docker >/dev/null 2>&1; then
  declare -A tag_id=() tag_digest=() digest_id=() made=() id_repo=() id_digest=() tag_before=()
  # 1. The tags before "docker ps".
  read_images
  for k in "${!tag_id[@]}"; do
    tag_before[$k]=${tag_id[$k]}
  done
  # 2. The running containers.
  declare -A ps_seen=()
  ps_refs=()
  ps_ok=false
  n_ps=0
  while IFS= read -r ref; do
    if [ "$ref" = "$END_MARK" ]; then ps_ok=true; continue; fi
    [ -n "$ref" ] || continue
    room docker_images $n_ps $MAX_PS || continue
    n_ps=$((n_ps + 1))
    shaped docker_images "$RAW_IMAGE_RE" "$ref" || continue
    [ -z "${ps_seen[$ref]:-}" ] || continue
    ps_seen[$ref]=1
    ps_refs+=("$ref")
  done < <(timeout 20 docker ps --no-trunc --format '{{.Image}}' 2>/dev/null && printf '%s\n' "$END_MARK")
  if [ "$ps_ok" = true ]; then
    # 3. The images after "docker ps".
    read_images
    # Per running image: "image" (the short name; the image id when it has no repo@digest name),
    # "digest" (the image's repo digest: the one the container was started by, else the one
    # "docker images" lists for its tag or id; "<repo>@<digest>" pulls exactly this image; empty
    # when it has none, as a local build), "id" (the image the container runs),
    # "created" (its build date) and "tag_moved": true when the name the container was started
    # with points to another image now, or to none. null: not known (then id is null too, unless
    # a digest names the image).
    declare -A img_seen=()
    imgs=()
    for ref in ${ps_refs[@]+"${ps_refs[@]}"}; do
      id="" digest="" moved=false
      if [[ $ref =~ $IMAGE_ID_RE ]]; then
        # docker prints the id: the container's name points to another image now, or to none.
        id=$ref
        name=${id_repo[$id]:-$id}
        digest=${id_digest[$id]:-}
        moved=true
      else
        familiar "$ref"
        name=${fam%%@*}
        [ "$name" = "$fam" ] || digest=${fam#*@}
        if [ -n "$digest" ]; then
          # started by digest: the digest names the image; a tag next to it may have moved on.
          bare=$name
          if [[ ${name##*/} == *:* ]]; then bare=${name%:*}; fi
          id=${digest_id[$bare@$digest]:-}
          if [ -z "$id" ]; then
            moved=null
          elif [ "$bare" != "$name" ] && [ "${tag_id[$name]:-}" != "$id" ]; then
            moved=true
          fi
        else
          # "docker ps" found this name: then it pointed to the image the container runs. Both
          # reads of "docker images" must give the same id for it, else it moved: not known.
          if [[ ${name##*/} != *:* ]]; then name=$name:latest; fi
          id=${tag_id[$name]:-}
          if [ "${tag_before[$name]:-}" != "$id" ]; then
            id=""
          elif [ -z "$id" ] && [[ $ref =~ $HEX_RE ]]; then
            by_prefix "$ref"
            if [ -n "$id" ]; then
              name=${id_repo[$id]:-$id}
              digest=${id_digest[$id]:-}
            fi
          else
            digest=${tag_digest[$name]:-}
          fi
          [ -n "$id" ] || moved=null
        fi
      fi
      shaped docker_images "$IMAGE_RE" "$name" || continue
      shaped docker_images "$DIGEST_RE" "$digest" || continue
      [ -z "${img_seen[$name@$digest]:-}" ] || continue
      img_seen[$name@$digest]=1
      room docker_images ${#imgs[@]} $MAX_LIST || continue
      created=""
      [ -z "$id" ] || created=${made[$id]:-}
      # "created" as 2026-01-02T10:00:00+0000 (docker prints "2026-01-02 10:00:00 +0000 UTC").
      if [[ $created =~ $DOCKER_DATE_RE ]]; then
        created="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
      else
        created=""
      fi
      imgs+=("{\"image\":$(js "$name"),\"digest\":$(js "$digest"),\"id\":$(js "$id"),\"created\":$(js "$created"),\"tag_moved\":$moved}")
    done
    docker_json=$(jarr ${imgs[@]+"${imgs[@]}"})
  fi
fi

# ---- deployed revisions: a git sha or null, never other file content ---------------------------

revs=()
for f in ${rev_files[@]+"${rev_files[@]}"}; do
  sha=""
  read -r sha < <(read_plain "$f")
  [[ $sha =~ $SHA_RE ]] || sha=""
  revs+=("$(js "$f"):$(js "$sha")")
done

# ---- output -------------------------------------------------------------------------------------

out="{\"collected_at\":$(js "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),\"host\":null,"
out+="\"os\":{\"id\":$(js "$os_id"),\"version_id\":$(js "$os_ver"),\"codename\":$(js "$os_code"),"
out+="\"machine\":$(js "$machine"),\"kernel_running\":$(js "$kernel_running"),\"kernel_newest_installed\":$(js "$kernel_newest"),"
out+="\"reboot_required\":$reboot_required,\"reboot_required_pkgs\":$(jarr ${reboot_pkgs[@]+"${reboot_pkgs[@]}"})},"
out+="\"apt\":{\"status\":$(js "$apt_state"),\"lists_age_hours\":${lists_age:-null},\"upgradable\":$upg_json},"
out+="\"node\":$(jarr ${node_json[@]+"${node_json[@]}"}),"
out+="\"nvm\":$(jarr ${nvm_json[@]+"${nvm_json[@]}"}),"
out+="\"pm2\":$(jarr ${pm2_json[@]+"${pm2_json[@]}"}),"
out+="\"services\":$services_json,"
out+="\"ruby\":$(jarr ${ruby_json[@]+"${ruby_json[@]}"}),"
out+="\"python3\":$(js "$python_ver"),"
out+="\"docker_images\":$docker_json,"
out+="\"running_deleted_exe\":$(jarr ${deleted_json[@]+"${deleted_json[@]}"}),"
out+="\"revisions\":{$(IFS=,; printf '%s' "${revs[*]:-}")},"
counts=()
for k in "${!dropped[@]}"; do
  counts+=("$(js "$k"):${dropped[$k]}")
done
other_counts=()
for k in "${!others[@]}"; do
  other_counts+=("$(js "$k"):${others[$k]}")
done
out+="\"filtered\":{\"truncated\":$truncated,\"dropped\":{$(IFS=,; printf '%s' "${counts[*]:-}")},"
out+="\"other_paths\":{$(IFS=,; printf '%s' "${other_counts[*]:-}")}}}"
printf '%s\n' "$out"
