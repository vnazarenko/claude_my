#!/usr/bin/env bash
# Tests for scripts/inventory.sh and scripts/remote-inventory.sh.
#
# Usage:
#   inventory_test.sh
#
# 1. guard: every command in remote-inventory.sh is on ALLOWED, and the guard catches
#    forbidden ones (pm2, nvm, npm, docker inspect, apt update, systemctl, rm, writes,
#    /proc/<pid>/environ, cmdline, .env, ...)
# 2. inventory.sh with a stub ssh: argument checks and the ssh options (no network)
# 3. remote-inventory.sh in docker (default image ubuntu:24.04): bare, then with fake
#    nvm / pm2 / reboot / apt / docker data. Skipped with a warning when docker is not running.
#
# All data is synthetic. Nothing here connects to a real server.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
scripts="$here/../scripts"
remote="$scripts/remote-inventory.sh"
inventory="$scripts/inventory.sh"
IMAGE="${INVENTORY_TEST_IMAGE:-ubuntu:24.04}"

# The only external commands remote-inventory.sh may run. Shell builtins are in the guard.
ALLOWED="apt-get date docker dpkg-query find readlink sort timeout uname"

fails=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
die() { echo "ERROR: $*" >&2; exit 1; }
# check <name> <jq expression> <json>
check() { if jq -e "$2" >/dev/null 2>&1 <<< "$3"; then ok "$1"; else bad "$1"; fi; }

command -v jq >/dev/null 2>&1 || die "jq not on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ---- 1. allowlist guard -----------------------------------------------------------------------

# guard <file> [--list]: prints one line per problem; exit 1 when there is any.
# --list also prints "uses: <allowed commands found>".
guard() {
  python3 - "$1" "$ALLOWED" "${2:-}" <<'PY'
import re, shlex, sys

path, allowed = sys.argv[1], set(sys.argv[2].split())
BUILTINS = {"echo", "printf", "read", "local", "declare", "set", "shift", "return", "exit",
            "test", "[", "true", "false", "mapfile", "readarray", "unset", "export",
            "break", "continue", "command"}
FORBIDDEN = {"pm2", "nvm", "npm", "npx", "systemctl", "service", "rm", "apt", "sudo",
             "eval", "source", ".", "exec", "bash", "sh", "xargs", "env", "tee", "curl", "wget"}
PREFIX_KW = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "time"}
END_KW = {"fi", "done", "}"}
OUT_REDIR = {">", ">>", "&>", "&>>", ">|"}
DUP_REDIR = {">&", "<&"}
IN_REDIR = {"<", "<<<"}
PUNCT = set(";&|()<>")
VAR = "__VAR__"
errors = []
FOUND = set()

def err(lineno, msg):
    errors.append(f"line {lineno}: {msg}")

def find_close(s, k, lineno):
    """Index of the ")" that closes the "(" just before s[k]."""
    depth, i, n, dq = 1, k, len(s), False
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if dq:
            if c == '"':
                dq = False
            elif c == "$" and s[i + 1:i + 2] == "(":
                i = find_close(s, i + 2, lineno) + 1
                continue
            i += 1
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = (j if j >= 0 else n) + 1
            continue
        if c == '"':
            dq = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    err(lineno, "unbalanced '(' in: " + s.strip())
    return n

def scan(s, lineno):
    """Cut the comment; replace each $( ), <( ) with VAR. Returns (outer text, inner texts)."""
    out, inners, i, n, quote = [], [], 0, len(s), None
    while i < n:
        c = s[i]
        if quote == "'":
            out.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\":
            out.append(s[i:i + 2])
            i += 2
            continue
        if c == "`":
            err(lineno, "backticks are not allowed")
            i += 1
            continue
        if c == "'" and quote is None:
            quote = "'"
        elif c == '"':
            quote = None if quote == '"' else '"'
        elif c == "#" and quote is None and (i == 0 or s[i - 1] in " \t;&|("):
            break
        elif s[i + 1:i + 2] == "(" and (c == "$" or (quote is None and c in "<>")):
            if c == ">":
                err(lineno, "process substitution >( ) is not allowed")
            j = find_close(s, i + 2, lineno)
            if c == "$" and s[i + 2:i + 3] == "(":
                # $(( arithmetic )): not a command, but a $( ) inside it is
                inners.extend(scan(s[i + 3:j - 1], lineno)[1])
            else:
                inners.append(s[i + 2:j])
            out.append(VAR)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), inners

def strip_redirections(toks, lineno):
    res, i = [], 0
    while i < len(toks):
        t = toks[i]
        nxt = toks[i + 1] if i + 1 < len(toks) else ""
        if t in OUT_REDIR:
            if nxt != "/dev/null":
                err(lineno, f"writes to a file: {t} {nxt}")
            i += 2
        elif t in DUP_REDIR:
            if not re.fullmatch(r"[0-9]+|-", nxt):
                err(lineno, f"redirection to a file: {t} {nxt}")
            i += 2
        elif t in IN_REDIR:
            i += 2
        elif t == "<<" or t == "<<-":
            err(lineno, "heredocs are not allowed")
            i += 1
        else:
            res.append(t)
            i += 1
    return res

def is_sep(t):
    return t != "" and all(ch in PUNCT for ch in t)

def check_command(cmd, args, lineno):
    if VAR in cmd:
        err(lineno, f"command from a variable: {cmd}")
        return
    if cmd in FORBIDDEN:
        err(lineno, f"forbidden command: {cmd}")
        return
    if cmd in FUNCS:
        return
    if cmd == "command":
        if args and args[0] in ("-v", "-V"):
            return
        if args:
            check_command(args[0], args[1:], lineno)
        return
    if cmd in BUILTINS:
        return
    if cmd not in allowed:
        err(lineno, f"command not on the allowlist: {cmd}")
        return
    FOUND.add(cmd)
    words = [a for a in args if not a.startswith("-")]
    if cmd == "timeout":
        rest, k = list(args), 0
        while k < len(rest) and rest[k].startswith("-"):
            k += 2 if rest[k] in ("-s", "-k") else 1
        rest = rest[k + 1:]  # drop the duration
        if rest:
            check_command(rest[0], rest[1:], lineno)
    elif cmd == "docker":
        if not words or words[0] not in ("ps", "images"):
            err(lineno, f"docker only runs 'ps' and 'images', got: {' '.join(args)}")
    elif cmd == "apt-get":
        if "--simulate" not in args:
            err(lineno, "apt-get runs only with --simulate")
    elif cmd == "find":
        bad = {"-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"}
        if bad & set(args):
            err(lineno, f"find may not use {sorted(bad & set(args))}")
    elif cmd == "sort":
        if any(re.match(r"-[A-Za-z]*o|--output", a) for a in args):
            err(lineno, "sort may not write a file (-o)")
    elif cmd == "date":
        if any(re.match(r"-[A-Za-z]*s|--set", a) for a in args):
            err(lineno, "date may not set the clock (-s)")

def check_line(text, lineno):
    outer, inners = scan(text, lineno)
    for inner in inners:
        check_line(inner, lineno)
    try:
        lex = shlex.shlex(outer, posix=True, punctuation_chars=";&|()<>")
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError as e:
        err(lineno, f"cannot parse ({e}): {text.strip()}")
        return
    toks = strip_redirections(toks, lineno)
    i, n, expect = 0, len(toks), True
    while i < n:
        t = toks[i]
        if t == "((" and expect:
            while i < n and toks[i] != "))":
                i += 1
            i += 1
            expect = False
            continue
        if is_sep(t):
            expect = True
            i += 1
            continue
        if not expect:
            i += 1
            continue
        if t == "[[":
            while i < n and toks[i] != "]]":
                i += 1
            i += 1
            expect = False
            continue
        if t in PREFIX_KW:
            i += 1
            continue
        if t in END_KW:
            expect = False
            i += 1
            continue
        if t in ("for", "select"):
            while i < n and not is_sep(toks[i]):
                i += 1
            continue
        if t == "case":
            err(lineno, "'case' is not supported by this guard; use if/elif")
            return
        if re.match(r"[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=", t):
            i += 1
            if t.endswith("=") and i < n and toks[i] == "(":
                # array value: name=( ... ) or name+=( ... )
                while i < n and toks[i] != ")":
                    i += 1
                i += 1
            continue
        if i + 1 < n and toks[i + 1] == "()":
            i += 2
            continue
        j, args = i + 1, []
        while j < n and not is_sep(toks[j]):
            args.append(toks[j])
            j += 1
        check_command(t, args, lineno)
        i, expect = j, False

src = open(path, encoding="utf-8").read()
FUNCS = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)", src, re.M))
for f in sorted(FUNCS & (allowed | FORBIDDEN | BUILTINS)):
    errors.append(f"function '{f}' hides a command of the same name")

lines = src.replace("\\\n", " ").split("\n")
for no, line in enumerate(lines, 1):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    low = line.lower()
    for word in ("environ", "cmdline", ".env"):
        if word in low:
            err(no, f"reads '{word}'")
    for p in re.findall(r"/proc/[^\s\"')]*", line):
        if not re.fullmatch(r"/proc/(\[0-9\]\*|\$[A-Za-z_]+)(/exe)?", p):
            err(no, f"reads {p} (only /proc/<pid>/exe is allowed)")
    norm = line
    while True:
        new = re.sub(r"\$\{[^{}]*\}", VAR, norm)
        if new == norm:
            break
        norm = new
    norm = re.sub(r"\$([A-Za-z_][A-Za-z0-9_]*|[0-9#?@*!$-])", VAR, norm)
    check_line(norm, no)

for e in errors:
    print(e)
if len(sys.argv) > 3 and sys.argv[3] == "--list":
    print("uses: " + " ".join(sorted(FOUND)))
sys.exit(1 if errors else 0)
PY
}

if out="$(guard "$remote" --list)"; then
  ok "guard: remote-inventory.sh uses only allowed commands"
else
  bad "guard: remote-inventory.sh"
  printf '%s\n' "$out" | sed 's/^/     /'
fi
# The guard must really see the commands; a parser that finds nothing would pass anything.
if [ "$(sed -n 's/^uses: //p' <<< "$out")" = "$ALLOWED" ]; then
  ok "guard: finds every allowed command in the script"
else
  bad "guard: finds every allowed command in the script (got: $(sed -n 's/^uses: //p' <<< "$out"))"
fi

# Each line below appended to a copy of the script must make the guard fail.
# shellcheck disable=SC2016 # the lines are shell code, kept as literal text
bad_lines=(
  'pm2 jlist'
  'x="$(pm2 list)"'
  'nvm ls'
  'npm ls -g'
  'docker inspect example'
  'timeout 5 docker inspect example'
  'apt update'
  'apt install -y example'
  'apt upgrade'
  'apt-get update'
  'apt-get install -y example'
  'apt-get upgrade'
  'systemctl status nginx'
  'rm -f /srv/app/x'
  'if true; then rm -rf /srv/app; fi'
  'command rm -f /srv/x'
  'read -r x < /proc/1/environ'
  'x=$(sort -u < /proc/1/cmdline)'
  'read -r x < /srv/app/.env'
  'printf x > /srv/out'
  'sort -o /srv/out /etc/hostname'
  'find /srv -delete'
  'find /srv -exec id {} +'
  'date -s 2020-01-01'
  '$cmd --version'
  'x=`uname`'
  'curl -s https://example.com'
  'eval "uname"'
  'readlink /proc/1/cwd'
  'uname -r | tee /srv/out'
  'docker exec example id'
  'x=( "$(rm -f /srv/x)" )'
  'n=$(( $(npm ls | sort) + 1 ))'
  'x="$(printf %s "$(pm2 jlist)")"'
  'while read -r l; do systemctl restart x; done < <(uname)'
  'rm() { true; }'
  'apt-get dist-upgrade'
)
for line in "${bad_lines[@]}"; do
  { cat "$remote"; printf '%s\n' "$line"; } > "$tmp/mutant.sh"
  if guard "$tmp/mutant.sh" >/dev/null; then
    bad "guard catches: $line"
  else
    ok "guard catches: $line"
  fi
done

# ---- 2. inventory.sh with a stub ssh (no network) ---------------------------------------------

mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: records its arguments and stdin, prints $STUB_OUT, exits $STUB_RC.
printf '%s\n' "$@" > "$STUB_DIR/ssh.args"
cat > "$STUB_DIR/ssh.stdin"
printf '%s' "${STUB_OUT:-}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$tmp/bin/ssh"
export STUB_DIR="$tmp"

run_inv() { PATH="$tmp/bin:$PATH" bash "$inventory" "$@"; }

rm -f "$tmp/ssh.args"
out="$(STUB_OUT='{"host":null,"os":{"id":"ubuntu"}}' run_inv example-host \
  --pm2-home /srv/app/.pm2 --revision-file /srv/app/current/REVISION 2>/dev/null)"
check "inventory.sh: sets host" '.host == "example-host" and .os.id == "ubuntu"' "$out"
args="$(cat "$tmp/ssh.args" 2>/dev/null)"
for want in -a -x -T ForwardAgent=no ClearAllForwardings=yes BatchMode=yes ControlMaster=no ControlPath=none; do
  if grep -qxF -- "$want" <<< "$args"; then ok "inventory.sh: ssh option $want"; else bad "inventory.sh: ssh option $want"; fi
done
tail_args="$(sed -n '/^example-host$/,$p' <<< "$args" | tr '\n' ' ')"
if [ "$tail_args" = "example-host bash -s -- --pm2-home /srv/app/.pm2 --revision-file /srv/app/current/REVISION " ]; then
  ok "inventory.sh: remote command and arguments"
else
  bad "inventory.sh: remote command and arguments (got: $tail_args)"
fi
if cmp -s "$tmp/ssh.stdin" "$remote"; then ok "inventory.sh: sends remote-inventory.sh on stdin"; else bad "inventory.sh: sends remote-inventory.sh on stdin"; fi

# Bad arguments: refused before ssh runs.
refused() {
  local name=$1
  shift
  rm -f "$tmp/ssh.args"
  if STUB_OUT='{}' run_inv "$@" >/dev/null 2>&1; then
    bad "inventory.sh refuses $name"
  elif [ -e "$tmp/ssh.args" ]; then
    bad "inventory.sh refuses $name (but ssh ran)"
  else
    ok "inventory.sh refuses $name"
  fi
}
refused "no host"
refused "host that starts with -" -oProxyCommand=example
refused "host with a space" "example host"
refused "path with .." example-host --pm2-home /srv/app/../etc
refused "relative path" example-host --pm2-home srv/app
refused "path with ;" example-host --revision-file '/srv/app;id'
refused "path with a space" example-host --revision-file '/srv/my app'
# shellcheck disable=SC2016 # a literal $ in the path
refused "path with \$" example-host --revision-file '/srv/$HOME'
refused "unknown option" example-host --command /bin/id
refused "option without a path" example-host --pm2-home

if STUB_OUT='{}' STUB_RC=255 run_inv example-host >/dev/null 2>&1; then
  bad "inventory.sh fails when ssh fails"
else
  ok "inventory.sh fails when ssh fails"
fi
if STUB_OUT='not json' run_inv example-host >/dev/null 2>&1; then
  bad "inventory.sh fails on invalid JSON"
else
  ok "inventory.sh fails on invalid JSON"
fi

# ---- 3. remote-inventory.sh in docker ---------------------------------------------------------

if ! docker info >/dev/null 2>&1; then
  echo "WARN: docker is not running - skipped the container tests"
  echo
  [ "$fails" -eq 0 ] && { echo "inventory_test: all passed (container tests skipped)"; exit 0; }
  echo "inventory_test: $fails failed"
  exit 1
fi

# 3a. Bare container, through inventory.sh. The stub ssh runs the remote command in docker.
cat > "$tmp/bin/ssh-docker" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: drop the options and the host, run the remote command in a fresh container.
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift 2
exec docker run --rm -i "$STUB_IMAGE" "$@"
EOF
chmod +x "$tmp/bin/ssh-docker"
mkdir -p "$tmp/dbin"
cp "$tmp/bin/ssh-docker" "$tmp/dbin/ssh"
out="$(STUB_IMAGE="$IMAGE" PATH="$tmp/dbin:$PATH" bash "$inventory" example-host \
  --pm2-home /srv/app/.pm2 --revision-file /srv/app/current/REVISION 2>"$tmp/err")"
check "bare: valid JSON with host" '.host == "example-host"' "$out"
check "bare: os from /etc/os-release" '.os.id == "ubuntu" and .os.version_id == "24.04" and .os.codename == "noble"' "$out"
check "bare: no kernel in /boot -> null" '.os.kernel_newest_installed == null and .os.reboot_required == false and .os.reboot_required_pkgs == []' "$out"
check "bare: no apt lists -> age null, nothing upgradable" '.apt.lists_age_hours == null and .apt.upgradable == []' "$out"
check "bare: no node, no nvm" '.node == [] and .nvm == []' "$out"
check "bare: pm2 home without pid file" '.pm2 == [{"pm2_home":"/srv/app/.pm2","pid_file":false,"daemon_running":false,"daemon_node_path":null,"daemon_node":null,"pm2_version":null}]' "$out"
check "bare: services missing -> null" '[.services[]] | all(. == null)' "$out"
check "bare: python3 and docker missing -> null" '.python3 == null and .docker_images == null' "$out"
check "bare: no ruby" '.ruby == []' "$out"
check "bare: missing revision file -> null" '.revisions == {"/srv/app/current/REVISION": null}' "$out"

# 3b. Container with fake data. Synthetic users, paths and versions only.
cat > "$tmp/setup.sh" <<'EOF'
set -e
u=/home/tester
for v in v22.1.0 v22.2.0 v24.21.0; do
  mkdir -p "$u/.nvm/versions/node/$v/bin"
  cp /usr/bin/sleep "$u/.nvm/versions/node/$v/bin/node"
done
mkdir -p "$u/.nvm/alias" /root/.nvm/versions/node/v20.0.0/bin /root/.nvm/alias
echo 22 > "$u/.nvm/alias/default"
cp /usr/bin/sleep /root/.nvm/versions/node/v20.0.0/bin/node
echo 'lts/*' > /root/.nvm/alias/default
mkdir -p "$u/.nvm/versions/node/v24.21.0/lib/node_modules/pm2"
printf '{\n  "name": "pm2",\n  "version": "6.0.5",\n  "engines": {\n    "version": "9.9.9"\n  }\n}\n' \
  > "$u/.nvm/versions/node/v24.21.0/lib/node_modules/pm2/package.json"
"$u/.nvm/versions/node/v24.21.0/bin/node" 300 &
daemon=$!
"$u/.nvm/versions/node/v24.21.0/bin/node" 300 &
mkdir -p "$u/.pm2-app" "$u/.pm2-old"
echo "$daemon" > "$u/.pm2-app/pm2.pid"
echo 999999 > "$u/.pm2-old/pm2.pid"
cp /usr/bin/sleep /usr/local/bin/node
/usr/local/bin/node 300 &
cp /usr/bin/sleep /usr/local/bin/oldsvc
/usr/local/bin/oldsvc 300 &
sleep 0.3
rm /usr/local/bin/oldsvc
touch /var/run/reboot-required
printf 'linux-image-6.8.0-48-generic\nlinux-base\nlinux-base\n' > /var/run/reboot-required.pkgs
mkdir -p /boot
touch /boot/vmlinuz-6.8.0-9-generic /boot/vmlinuz-6.8.0-45-generic /boot/vmlinuz-6.8.0-48-generic
mkdir -p /usr/local/rvm/rubies/ruby-3.4.7 /usr/local/rvm/rubies/ruby-3.3.6 "$u/.rvm/rubies/ruby-3.4.7"
mkdir -p /srv/app/current /srv/bad/current
echo 0123456789abcdef0123456789abcdef01234567 > /srv/app/current/REVISION
echo 'not a sha; DB_PASSWORD=secret' > /srv/bad/current/REVISION
mkdir -p /var/lib/apt/lists /var/lib/apt/periodic
touch -d '30 hours ago' /var/lib/apt/lists/example.invalid_dists_noble-security_InRelease
touch -d '3 hours ago' /var/lib/apt/periodic/update-success-stamp
for p in nginx:1.24.0-2ubuntu7.1 postgresql-14:14.13-1 postgresql-16:16.4-1 python3.12:3.12.3-1ubuntu0.8; do
  printf 'Package: %s\nStatus: install ok installed\nArchitecture: all\nVersion: %s\nMaintainer: Test <test@example.invalid>\nDescription: fake\n\n' \
    "${p%%:*}" "${p#*:}" >> /var/lib/dpkg/status
done
printf 'Package: redis-server\nStatus: deinstall ok config-files\nArchitecture: all\nVersion: 7.0.15-1\nMaintainer: Test <test@example.invalid>\nDescription: fake\n\n' \
  >> /var/lib/dpkg/status
cat > /usr/local/bin/apt-get <<'APT'
#!/bin/sh
case " $* " in *" --simulate "*) ;; *) exit 1 ;; esac
cat <<'OUT'
NOTE: This is only a simulation!
Inst libssl3t64 [3.0.13-0ubuntu3.4] (3.0.13-0ubuntu3.6 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])
Inst docker-ce:amd64 [5:27.3.1-1~ubuntu.24.04~noble] (5:27.4.0-1~ubuntu.24.04~noble Docker CE:24.04/noble [amd64])
Inst clickhouse-server [24.8.4] (24.9.1 stable [amd64])
Inst example-tool [1.0] (1.1 ExampleRepo:main [all]) []
Inst linux-image-6.8.0-50-generic (6.8.0-50.51 Ubuntu:24.04/noble-updates [amd64])
Conf libssl3t64 (3.0.13-0ubuntu3.6 Ubuntu:24.04/noble-updates [amd64])
OUT
APT
chmod +x /usr/local/bin/apt-get
cat > /usr/local/bin/docker <<'DOCKER'
#!/bin/sh
case "$1" in
  ps) printf 'example/geo:4.5\nredis\n0123456789ab\n' ;;
  images) printf 'example/geo:4.5\tsha256:aaaa\t2026-01-01 10:00:00 +0000 UTC\nredis:latest\tsha256:bbbb\t2026-01-02 10:00:00 +0000 UTC\nexample/old:1.0\tsha256:0123456789abcdef\t2025-01-01 10:00:00 +0000 UTC\nexample/unused:2\tsha256:cccc\t2025-01-01 10:00:00 +0000 UTC\n' ;;
  *) echo "unexpected docker call: $*" >&2; exit 9 ;;
esac
DOCKER
chmod +x /usr/local/bin/docker
EOF

out="$(docker run --rm -i -v "$scripts:/t:ro" -v "$tmp/setup.sh:/setup.sh:ro" "$IMAGE" bash -c \
  'bash /setup.sh && bash /t/remote-inventory.sh --pm2-home /home/tester/.pm2-app --pm2-home /home/tester/.pm2-old --revision-file /srv/app/current/REVISION --revision-file /srv/bad/current/REVISION' 2>"$tmp/err")"
check "fake: valid JSON" 'type == "object"' "$out"
check "fake: newest kernel by version order" '.os.kernel_newest_installed == "6.8.0-48-generic"' "$out"
check "fake: reboot required + packages once each" '.os.reboot_required == true and .os.reboot_required_pkgs == ["linux-base","linux-image-6.8.0-48-generic"]' "$out"
check "fake: apt lists age from the success stamp" '.apt.lists_age_hours == 3' "$out"
check "fake: apt upgrades, new packages skipped" '.apt.upgradable | length == 4' "$out"
check "fake: Ubuntu upgrade with source package" '.apt.upgradable[0] == {"package":"libssl3t64","source":"openssl","installed":"3.0.13-0ubuntu3.4","candidate":"3.0.13-0ubuntu3.6","origin":"Ubuntu","archives":["noble-updates","noble-security"]}' "$out"
check "fake: vendor repo with label" '.apt.upgradable[1] | .package == "docker-ce" and .origin == "Docker CE" and .archives == ["noble"] and .candidate == "5:27.4.0-1~ubuntu.24.04~noble"' "$out"
check "fake: vendor repo without label" '.apt.upgradable[2] | .package == "clickhouse-server" and .origin == null and .archives == ["stable"]' "$out"
check "fake: label without release version" '.apt.upgradable[3] | .origin == "ExampleRepo" and .archives == ["main"]' "$out"
check "fake: nvm installs and running counts" '[.node[] | {version, running}] == [{"version":"v22.1.0","running":0},{"version":"v22.2.0","running":0},{"version":"v24.21.0","running":2},{"version":"v20.0.0","running":0},{"version":null,"running":1}]' "$out"
check "fake: default alias 22 -> newest v22" '[.node[] | select(.default_alias) | .version] == ["v22.2.0"]' "$out"
check "fake: nvm aliases reported as written" '.nvm == [{"nvm_dir":"/root/.nvm","default_alias":"lts/*"},{"nvm_dir":"/home/tester/.nvm","default_alias":"22"}]' "$out"
check "fake: running node outside nvm" '.node[-1].path == "/usr/local/bin/node"' "$out"
check "fake: pm2 daemon Node and version from files" '.pm2[0] | .pid_file and .daemon_running and .daemon_node == "v24.21.0" and .pm2_version == "6.0.5"' "$out"
check "fake: stale pm2 pid -> not running, nulls" '.pm2[1] | .pid_file and (.daemon_running | not) and .daemon_node == null and .pm2_version == null' "$out"
check "fake: services from dpkg, removed package -> null" '.services.nginx == "1.24.0-2ubuntu7.1" and .services.postgresql == "16.4-1" and .services.redis == null' "$out"
check "fake: python3 from dpkg" '.python3 == "3.12.3-1ubuntu0.8"' "$out"
check "fake: rvm rubies, sorted, once each" '.ruby == ["3.3.6","3.4.7"]' "$out"
check "fake: running docker images only" '.docker_images | map(.image) | sort == ["example/geo:4.5","example/old:1.0","redis:latest"]' "$out"
check "fake: deleted binary still running" '.running_deleted_exe == ["/usr/local/bin/oldsvc"]' "$out"
check "fake: revision is a sha or null" '.revisions == {"/srv/app/current/REVISION":"0123456789abcdef0123456789abcdef01234567","/srv/bad/current/REVISION":null}' "$out"
if grep -q secret <<< "$out"; then bad "fake: no file content in the output"; else ok "fake: no file content in the output"; fi

# 3c. The remote script refuses bad arguments on its own too.
out="$(docker run --rm -i -v "$scripts:/t:ro" "$IMAGE" bash -c '
  for a in "--pm2-home /srv/../etc" "--pm2-home srv" "--revision-file /srv/a;b" "--bogus /srv"; do
    # shellcheck disable=SC2086
    bash /t/remote-inventory.sh $a >/dev/null 2>&1; echo "$?"
  done' 2>/dev/null | tr '\n' ' ')"
if [ "$out" = "2 2 2 2 " ]; then ok "remote: refuses bad arguments"; else bad "remote: refuses bad arguments (exit codes: $out)"; fi

echo
if [ "$fails" -eq 0 ]; then echo "inventory_test: all passed"; exit 0; fi
echo "inventory_test: $fails failed"
exit 1
