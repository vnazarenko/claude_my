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
# - apt-get runs only with --simulate, docker only "ps" and "images"; nothing writes a file
# - pm2, nvm, npm and systemctl are never run: they can start daemons or write files
# - process facts come only from the /proc/<pid>/exe link: no process arguments,
#   no process environment, no app config files
# - a file under a folder other users can write (nvm, pm2, deploys) is read only when it is a
#   regular file and not a symlink, and only a value of the expected shape is passed on
#   (a version, a pid, a git sha): root never follows a link to another file, and never
#   waits on a FIFO
# - a missing tool or file gives null or [], never an error
# - a value leaves the server only in the shape it should have (a version, a package name, a
#   plain path without spaces, ...): other users can name folders and run their own binaries, so
#   no free text gets out. A value of the wrong shape is dropped and counted; each list has a cap,
#   and entries over it are dropped and counted too ("filtered" in the output). inventory.sh
#   checks all of this again on the user's side.
# The test also runs this script in a container and checks that no file changed.
#
# Keep the style simple, the test reads this file line by line: one command per line,
# no heredocs, no backticks, no "case", no multi-line $( ... ).
set -uo pipefail
export LC_ALL=C

die() { printf 'remote-inventory: %s\n' "$*" >&2; exit 2; }

# ---- what may leave the server -----------------------------------------------------------------

MAX_LIST=50     # entries per list
MAX_APT=2000    # pending upgrades
MAX_ARCH=8      # archives per upgrade
MAX_PATH=128    # characters in a path
# The shapes. inventory.sh has the same ones.
VER_RE='^v?([0-9]{1,5}:)?[0-9][A-Za-z0-9.+~-]{0,63}$'
RUBY_RE='^[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{1,3}(-[a-z]{1,8}[0-9]{0,4})?$'
PKG_RE='^[a-z0-9][a-z0-9.+-]{1,63}$'
WORD_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'
ALIAS_RE='^(v?[0-9]{1,3}(\.[0-9]{1,4}){0,2}|lts/(\*|-?[0-9]{1,2}|[a-z]{2,12})|node|stable|unstable|system|iojs)$'
IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,127}$'
IMAGE_ID_RE='^(sha256:)?[0-9a-f]{12,64}$'
NVM_RE='^(/root/\.nvm|/home/[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}/\.nvm|/usr/local/nvm|/opt/nvm)$'
NVM_NODE_RE='^(/root/\.nvm|/home/[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}/\.nvm|/usr/local/nvm|/opt/nvm)/versions/node/v[0-9]{1,3}\.[0-9]{1,4}\.[0-9]{1,4}/bin/node$'
DOCKER_DATE_RE='^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) ([+-][0-9]{4})'

declare -A dropped=()
truncated=false

# drop <list>: count one value left out of <list>.
drop() { dropped[$1]=$(( ${dropped[$1]:-0} + 1 )); }

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

# A Node path: a safe path; one in an nvm tree only with a plain version folder (vX.Y.Z).
node_path_ok() {
  if [[ $1 == */versions/node/* ]]; then
    [[ $1 =~ $NVM_NODE_RE ]]
    return
  fi
  safe_path "$1"
}

# A file root may read in a folder that other users can write: a regular file, not a symlink.
plain_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }

pm2_homes=()
rev_files=()
while [ $# -gt 0 ]; do
  if [ "$1" = "--pm2-home" ] && [ $# -ge 2 ]; then
    safe_path "$2" || die "bad path: $2"
    pm2_homes+=("$2")
    shift 2
  elif [ "$1" = "--revision-file" ] && [ $# -ge 2 ]; then
    safe_path "$2" || die "bad path: $2"
    rev_files+=("$2")
    shift 2
  else
    die "unknown argument: $1"
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
upg_json=null
if command -v apt-get >/dev/null 2>&1; then
  upg=()
  re='^Inst ([^ ]+) \[([^]]*)\] \(([^ ]+) (.*)\)'
  while IFS= read -r line; do
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
    IFS=',' read -ra parts <<< "$rel"
    for part in "${parts[@]}"; do
      part=${part# }
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
  done < <(apt-get --simulate -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Dir::Log::Planner= -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)
  upg_json=$(jarr ${upg[@]+"${upg[@]}"})
fi

# ---- running binaries, from /proc/<pid>/exe links only -----------------------------------------

# The link of a process in a container names the path INSIDE the container. When the link's
# target is not the host file at that path ("-ef" compares device and inode), the process is
# counted as a container process, not as the host binary.
declare -A running=() deleted=() in_container=()
while IFS=$'\t' read -r dir exe; do
  [ -n "$exe" ] || continue
  pid=${dir##*/}
  [[ $pid =~ ^[0-9]+$ ]] || continue
  if [[ $exe == *' (deleted)' ]]; then
    exe=${exe% (deleted)}
    deleted[$exe]=1
  elif [ ! "/proc/$pid/exe" -ef "$exe" ]; then
    [ -d "/proc/$pid" ] && in_container[$exe]=$(( ${in_container[$exe]:-0} + 1 ))
    continue
  fi
  running[$exe]=$(( ${running[$exe]:-0} + 1 ))
done < <(find /proc/[0-9]*/exe -maxdepth 0 -printf '%h\t%l\n' 2>/dev/null)

# A binary replaced on disk but still running: the old code runs until a restart.
deleted_json=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! safe_path "$p"; then drop running_deleted_exe; continue; fi
  room running_deleted_exe ${#deleted_json[@]} $MAX_LIST || continue
  deleted_json+=("$(js "$p")")
done < <(printf '%s\n' "${!deleted[@]}" | sort)

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
  if plain_file "$nvm/alias/default"; then read -r dflt < "$nvm/alias/default"; fi
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
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! node_path_ok "$p"; then drop node; continue; fi
  room node ${#node_json[@]} $MAX_LIST || continue
  node_json+=("{\"path\":$(js "$p"),\"version\":$(js "$(node_version "$p")"),\"running\":${running[$p]:-0},\"container\":false}")
done < <(printf '%s\n' "${!node_paths[@]}" | sort)
# A container's Node: its version is the image's, not the host package's.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! node_path_ok "$p"; then drop node; continue; fi
  room node ${#node_json[@]} $MAX_LIST || continue
  node_json+=("{\"path\":$(js "$p"),\"version\":null,\"running\":${in_container[$p]},\"container\":true}")
done < <(printf '%s\n' "${!node_in_container[@]}" | sort)

# ---- pm2: the daemon's Node and the pm2 version, read from files -------------------------------

# The top "version" of a package.json, when it is a plain X.Y.Z.
json_version() {
  local line re='^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.[0-9]{1,4}\.[0-9]{1,4})"'
  plain_file "$1" || return 0
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  done < "$1"
}

pm2_json=()
for home in ${pm2_homes[@]+"${pm2_homes[@]}"}; do
  pid="" exe="" nver="" pver="" pidfile=false up=false
  if plain_file "$home/pm2.pid"; then
    pidfile=true
    read -r pid < "$home/pm2.pid"
  fi
  [[ $pid =~ ^[0-9]+$ ]] || pid=""
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    up=true
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    exe=${exe% (deleted)}
    if [ -n "$exe" ] && ! node_path_ok "$exe"; then
      drop pm2
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
# rvm installer run as root; ~/.rvm: a per-user install.
for d in /usr/share/rvm/rubies/ruby-* /usr/local/rvm/rubies/ruby-* /root/.rvm/rubies/ruby-* /home/*/.rvm/rubies/ruby-*; do
  [ -d "$d" ] && rubies+=("${d##*/ruby-}")
done
ruby_json=()
while IFS= read -r v; do
  [ -n "$v" ] || continue
  shaped ruby "$RUBY_RE" "$v" || continue
  room ruby ${#ruby_json[@]} $MAX_LIST || continue
  ruby_json+=("$(js "$v")")
done < <(printf '%s\n' ${rubies[@]+"${rubies[@]}"} | sort -uV)

# ---- Docker: running images only (no "inspect": it prints container env) -----------------------

docker_json=null
if command -v docker >/dev/null 2>&1; then
  if ps_out=$(timeout 20 docker ps --format '{{.Image}}' 2>/dev/null); then
    declare -A in_use=()
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      [[ ${ref##*/} == *:* || $ref == *@* || $ref =~ ^[0-9a-f]{12}$ ]] || ref="$ref:latest"
      shaped docker_images "$IMAGE_RE" "$ref" || continue
      in_use[$ref]=1
    done <<< "$ps_out"
    imgs=()
    # "created" as 2026-01-02T10:00:00+0000 (docker prints "2026-01-02 10:00:00 +0000 UTC").
    while IFS=$'\t' read -r ref id created; do
      short=${id#sha256:}
      short=${short:0:12}
      if [ -n "${in_use[$ref]:-}" ]; then
        unset "in_use[$ref]"
      elif [ -n "$short" ] && [ -n "${in_use[$short]:-}" ]; then
        unset "in_use[$short]"
      else
        continue
      fi
      room docker_images ${#imgs[@]} $MAX_LIST || continue
      shaped docker_images "$IMAGE_RE" "$ref" || continue
      shaped docker_images "$IMAGE_ID_RE" "$id" || id=""
      if [[ $created =~ $DOCKER_DATE_RE ]]; then
        created="${BASH_REMATCH[1]}T${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
      else
        created=""
      fi
      imgs+=("{\"image\":$(js "$ref"),\"id\":$(js "$id"),\"created\":$(js "$created")}")
    done < <(timeout 20 docker images --no-trunc --format '{{.Repository}}:{{.Tag}}{{"\t"}}{{.ID}}{{"\t"}}{{.CreatedAt}}' 2>/dev/null)
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      room docker_images ${#imgs[@]} $MAX_LIST || continue
      imgs+=("{\"image\":$(js "$ref"),\"id\":null,\"created\":null}")
    done < <(printf '%s\n' "${!in_use[@]}" | sort)
    docker_json=$(jarr ${imgs[@]+"${imgs[@]}"})
  fi
fi

# ---- deployed revisions: a git sha or null, never other file content ---------------------------

revs=()
for f in ${rev_files[@]+"${rev_files[@]}"}; do
  sha=""
  if plain_file "$f"; then read -r sha < "$f"; fi
  [[ $sha =~ ^[0-9a-f]{7,40}$ ]] || sha=""
  revs+=("$(js "$f"):$(js "$sha")")
done

# ---- output -------------------------------------------------------------------------------------

out="{\"collected_at\":$(js "$(date -u +%Y-%m-%dT%H:%M:%SZ)"),\"host\":null,"
out+="\"os\":{\"id\":$(js "$os_id"),\"version_id\":$(js "$os_ver"),\"codename\":$(js "$os_code"),"
out+="\"kernel_running\":$(js "$kernel_running"),\"kernel_newest_installed\":$(js "$kernel_newest"),"
out+="\"reboot_required\":$reboot_required,\"reboot_required_pkgs\":$(jarr ${reboot_pkgs[@]+"${reboot_pkgs[@]}"})},"
out+="\"apt\":{\"lists_age_hours\":${lists_age:-null},\"upgradable\":$upg_json},"
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
out+="\"filtered\":{\"truncated\":$truncated,\"dropped\":{$(IFS=,; printf '%s' "${counts[*]:-}")}}}"
printf '%s\n' "$out"
