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
# - a missing tool or file gives null or [], never an error
#
# Keep the style simple, the test reads this file line by line: one command per line,
# no heredocs, no backticks, no "case", no multi-line $( ... ).
set -uo pipefail
export LC_ALL=C

die() { printf 'remote-inventory: %s\n' "$*" >&2; exit 2; }

# A path from the command line: absolute, plain characters, no "..".
safe_path() { [[ $1 == /* && $1 != *..* && $1 =~ ^[A-Za-z0-9_./@+-]+$ ]]; }

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
    dpkg_ver[$p]=$ver
    dpkg_src[$p]=${src:-$p}
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

kernel_running=$(uname -r 2>/dev/null)
kernels=()
for f in /boot/vmlinuz-*; do
  [ -e "$f" ] && kernels+=("${f#/boot/vmlinuz-}")
done
kernel_newest=""
if [ ${#kernels[@]} -gt 0 ]; then
  read -r kernel_newest < <(printf '%s\n' "${kernels[@]}" | sort -rV)
fi

reboot_required=false
[ -e /var/run/reboot-required ] && reboot_required=true
reboot_pkgs=()
if [ -r /var/run/reboot-required.pkgs ]; then
  while IFS= read -r p; do
    [ -n "$p" ] && reboot_pkgs+=("$(js "$p")")
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
# The cache options stop apt from writing its binary cache; NoLocking leaves the dpkg lock alone.
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
      [ -z "$origin" ] && origin=$label
      archives+=("$(js "$archive")")
    done
    src=${dpkg_src[$name]:-$name}
    upg+=("{\"package\":$(js "$name"),\"source\":$(js "$src"),\"installed\":$(js "$installed"),\"candidate\":$(js "$candidate"),\"origin\":$(js "$origin"),\"archives\":$(jarr ${archives[@]+"${archives[@]}"})}")
  done < <(apt-get --simulate -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)
  upg_json=$(jarr ${upg[@]+"${upg[@]}"})
fi

# ---- running binaries, from /proc/<pid>/exe links only -----------------------------------------

declare -A running=() deleted=()
while IFS= read -r exe; do
  [ -n "$exe" ] || continue
  if [[ $exe == *' (deleted)' ]]; then
    exe=${exe% (deleted)}
    deleted[$exe]=1
  fi
  running[$exe]=$(( ${running[$exe]:-0} + 1 ))
done < <(find /proc/[0-9]*/exe -maxdepth 0 -printf '%l\n' 2>/dev/null)

# A binary replaced on disk but still running: the old code runs until a restart.
deleted_json=()
while IFS= read -r p; do
  [ -n "$p" ] && deleted_json+=("$(js "$p")")
done < <(printf '%s\n' "${!deleted[@]}" | sort)

# ---- Node.js: nvm trees and every running "node" binary ----------------------------------------

# "v24.21.0" from an nvm path; the nodejs package version for the system binary; else empty.
node_version() {
  if [[ $1 =~ /versions/node/(v[0-9][^/]*)/bin/node$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [ "$1" = /usr/bin/node ] || [ "$1" = /usr/bin/nodejs ]; then
    printf '%s' "${dpkg_ver[nodejs]:-}"
  fi
}

declare -A node_paths=() node_default=()
nvm_json=()
for nvm in /root/.nvm /home/*/.nvm /usr/local/nvm /opt/nvm; do
  [ -d "$nvm/versions/node" ] || continue
  dflt=""
  if [ -r "$nvm/alias/default" ]; then read -r dflt < "$nvm/alias/default"; fi
  nvm_json+=("{\"nvm_dir\":$(js "$nvm"),\"default_alias\":$(js "$dflt")}")
  vers=()
  for bin in "$nvm"/versions/node/*/bin/node; do
    [ -e "$bin" ] || continue
    node_paths[$bin]=1
    v=${bin%/bin/node}
    vers+=("${v##*/}")
  done
  # nvm reads "22", "v22.2" or "v22.2.0" as the newest install that matches.
  # Other aliases (lts/*, node) are only reported in nvm_json.
  want=${dflt#v}
  if [ ${#vers[@]} -gt 0 ] && [[ $want =~ ^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
    while IFS= read -r v; do
      if [ "${v#v}" = "$want" ] || [[ ${v#v} == "$want".* ]]; then
        node_default["$nvm/versions/node/$v/bin/node"]=1
        break
      fi
    done < <(printf '%s\n' "${vers[@]}" | sort -rV)
  fi
done
for exe in "${!running[@]}"; do
  [[ ${exe##*/} == node || ${exe##*/} == nodejs ]] && node_paths[$exe]=1
done

node_json=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  d=false
  [ -n "${node_default[$p]:-}" ] && d=true
  node_json+=("{\"path\":$(js "$p"),\"version\":$(js "$(node_version "$p")"),\"running\":${running[$p]:-0},\"default_alias\":$d}")
done < <(printf '%s\n' "${!node_paths[@]}" | sort)

# ---- pm2: the daemon's Node and the pm2 version, read from files -------------------------------

# The top "version" of a package.json.
json_version() {
  local line re='^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)"'
  [ -r "$1" ] || return 0
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then printf '%s' "${BASH_REMATCH[1]}"; return 0; fi
  done < "$1"
}

pm2_json=()
for home in ${pm2_homes[@]+"${pm2_homes[@]}"}; do
  pid="" exe="" nver="" pver="" pidfile=false up=false
  if [ -r "$home/pm2.pid" ]; then
    pidfile=true
    read -r pid < "$home/pm2.pid"
  fi
  [[ $pid =~ ^[0-9]+$ ]] || pid=""
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    up=true
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    exe=${exe% (deleted)}
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
  [ -n "$v" ] && ruby_json+=("$(js "$v")")
done < <(printf '%s\n' ${rubies[@]+"${rubies[@]}"} | sort -uV)

# ---- Docker: running images only (no "inspect": it prints container env) -----------------------

docker_json=null
if command -v docker >/dev/null 2>&1; then
  if ps_out=$(timeout 20 docker ps --format '{{.Image}}' 2>/dev/null); then
    declare -A in_use=()
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      [[ ${ref##*/} == *:* || $ref == *@* || $ref =~ ^[0-9a-f]{12}$ ]] || ref="$ref:latest"
      in_use[$ref]=1
    done <<< "$ps_out"
    imgs=()
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
      imgs+=("{\"image\":$(js "$ref"),\"id\":$(js "$id"),\"created\":$(js "$created")}")
    done < <(timeout 20 docker images --no-trunc --format '{{.Repository}}:{{.Tag}}{{"\t"}}{{.ID}}{{"\t"}}{{.CreatedAt}}' 2>/dev/null)
    for ref in "${!in_use[@]}"; do
      imgs+=("{\"image\":$(js "$ref"),\"id\":null,\"created\":null}")
    done
    docker_json=$(jarr ${imgs[@]+"${imgs[@]}"})
  fi
fi

# ---- deployed revisions: a git sha or null, never other file content ---------------------------

revs=()
for f in ${rev_files[@]+"${rev_files[@]}"}; do
  sha=""
  if [ -r "$f" ]; then read -r sha < "$f"; fi
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
out+="\"revisions\":{$(IFS=,; printf '%s' "${revs[*]:-}")}}"
printf '%s\n' "$out"
