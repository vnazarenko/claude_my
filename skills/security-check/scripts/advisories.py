#!/usr/bin/env python3
"""Find the security fixes for the versions in a server inventory (made by inventory.sh).

Usage:
  advisories.py node <inventory.json|-> [--since-days N] [--today YYYY-MM-DD] [--cache-dir DIR]
  advisories.py usn  <inventory.json|-> [--since-days N] [--today YYYY-MM-DD] [--cache-dir DIR]
  advisories.py kev  <CVE-ID ...|->                                       [--cache-dir DIR]

Each command prints one JSON object on stdout.

node  For each Node.js version on the server: the security releases of the same major line
      that are newer than ours, the version that fixes them all, the newest release of the
      line, and whether the line is still supported.
      Data: the nodejs.org release index and the Node.js release schedule.
usn   For each upgradable package from an Ubuntu repo: the CVEs that are fixed after the
      installed version, with Ubuntu's priority, the fixed version and the USN ids.
      Data: the Ubuntu CVE tracker, one paged query per source package.
      Kernel packages and vendor repos (Docker, ClickHouse, ...) are listed, not looked up.
kev   Which CVE ids are in the CISA Known Exploited Vulnerabilities catalog.
      "-" reads the ids from stdin: any text, for example the output of "usn".

The script collects facts. It does not judge what affects us; see references/sources.md.

Every pending fix is listed, of any age. "in_window" marks the ones published in the last
--since-days days (default 14) before --today (default: today, UTC).

Network: only HTTPS GET requests to the sources above, all through Fetcher, which keeps a
disk cache (default ~/.cache/security-check, or $SECURITY_CHECK_CACHE).
Exit codes: 0 ok, 1 a source could not be fetched, 2 bad input.
"""

import argparse
import datetime as dt
import hashlib
import http.client
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

NODE_INDEX_URL = "https://nodejs.org/dist/index.json"
NODE_SCHEDULE_URL = "https://raw.githubusercontent.com/nodejs/Release/main/schedule.json"
UBUNTU_CVES_URL = "https://ubuntu.com/security/cves.json"
KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"

HOUR = 3600
MAX_AGE = {
    NODE_INDEX_URL: 6 * HOUR,
    NODE_SCHEDULE_URL: 7 * 24 * HOUR,
    KEV_URL: 12 * HOUR,
}
UBUNTU_MAX_AGE = 12 * HOUR
PAGE_SIZE = 20   # the most the Ubuntu API gives per page
MAX_PAGES = 15   # per source package, so at most 300 CVEs
TIMEOUT = 60
USER_AGENT = "security-check-advisories/1"

PRIORITIES = ["critical", "high", "medium", "low", "negligible"]
CVE_RE = re.compile(r"\bCVE-\d{4}-\d{4,}\b", re.IGNORECASE)
NODE_VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
# A NodeSource apt package is an upstream build: "22.11.0-1nodesource1".
NODESOURCE_RE = re.compile(r"^(\d+\.\d+\.\d+)-\d*nodesource")
# Kernel sources. Their USNs list hundreds of CVEs each; the report handles the kernel
# through the running kernel and the reboot flag instead.
KERNEL_SOURCE_RE = re.compile(
    r"^linux(-(meta|signed|hwe|aws|azure|gcp|gke|gkeop|ibm|kvm|lowlatency|oracle|realtime"
    r"|fips|raspi|nvidia|intel|riscv)(-.*)?)?$")


class FetchError(Exception):
    """A source could not be fetched, or its answer was not what we expect."""


class InputError(Exception):
    """Bad input from the user: a missing file, bad JSON, a bad CVE id."""


# ---- network and cache ---------------------------------------------------------------------

def http_get(url):
    """One HTTPS GET. The only place that opens a network connection."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT,
                                               "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def default_cache_dir():
    if os.environ.get("SECURITY_CHECK_CACHE"):
        return os.environ["SECURITY_CHECK_CACHE"]
    base = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.join(base, "security-check")


class Fetcher:
    """Get a JSON document by URL, with a disk cache.

    A cached copy younger than max_age seconds is used without a request.
    Only a valid JSON answer is written to the cache.
    """

    def __init__(self, cache_dir, opener=None, now=time.time):
        self.cache_dir = cache_dir
        self.opener = opener or http_get
        self.now = now

    def cache_path(self, url):
        name = hashlib.sha256(url.encode("utf-8")).hexdigest()[:32]
        return os.path.join(self.cache_dir, name + ".json")

    def get_json(self, url, max_age):
        path = self.cache_path(url)
        try:
            if self.now() - os.stat(path).st_mtime < max_age:
                with open(path, "rb") as f:
                    return json.loads(f.read())
        except (OSError, ValueError):
            pass
        try:
            body = self.opener(url)
        except urllib.error.HTTPError as e:
            raise FetchError(f"could not fetch {url}: HTTP {e.code}") from None
        except (OSError, http.client.HTTPException) as e:
            reason = getattr(e, "reason", None) or e
            raise FetchError(f"could not fetch {url}: {reason}") from None
        try:
            data = json.loads(body)
        except ValueError:
            raise FetchError(f"could not fetch {url}: the answer is not JSON") from None
        self._save(path, body)
        return data

    def _save(self, path, body):
        try:
            os.makedirs(self.cache_dir, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=self.cache_dir, suffix=".tmp")
            with os.fdopen(fd, "wb") as f:
                f.write(body)
            os.replace(tmp, path)
        except OSError as e:
            print(f"advisories.py: warning: cache not written: {e}", file=sys.stderr)


# ---- versions --------------------------------------------------------------------------------

def node_version(s):
    """(24, 21, 0) from "v24.21.0" or "24.21.0", else None."""
    m = NODE_VERSION_RE.match(s or "")
    return tuple(int(x) for x in m.groups()) if m else None


def _order(c):
    if c == "" or c in "0123456789":
        return 0
    if c.isascii() and c.isalpha():
        return ord(c)
    if c == "~":
        return -1
    return ord(c) + 256


def _verrevcmp(a, b):
    """dpkg's comparison of one upstream or revision part."""
    i = j = 0
    while i < len(a) or j < len(b):
        while (i < len(a) and a[i] not in "0123456789") or (j < len(b) and b[j] not in "0123456789"):
            ac = _order(a[i] if i < len(a) else "")
            bc = _order(b[j] if j < len(b) else "")
            if ac != bc:
                return ac - bc
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        first_diff = 0
        while i < len(a) and a[i] in "0123456789" and j < len(b) and b[j] in "0123456789":
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and a[i] in "0123456789":
            return 1
        if j < len(b) and b[j] in "0123456789":
            return -1
        if first_diff:
            return first_diff
    return 0


def _split_dpkg(v):
    epoch = 0
    if ":" in v:
        e, v = v.split(":", 1)
        epoch = int(e) if e.isdigit() else 0
    up, rev = v.rsplit("-", 1) if "-" in v else (v, "")
    return epoch, up, rev


def dpkg_cmp(a, b):
    """Compare two Debian package versions the way dpkg does: -1, 0 or 1."""
    ea, ua, ra = _split_dpkg(a)
    eb, ub, rb = _split_dpkg(b)
    if ea != eb:
        return -1 if ea < eb else 1
    r = _verrevcmp(ua, ub) or _verrevcmp(ra, rb)
    return (r > 0) - (r < 0)


def priority_rank(p):
    """0 for critical ... 4 for negligible, 5 for anything else (untriaged, missing)."""
    return PRIORITIES.index(p) if p in PRIORITIES else len(PRIORITIES)


# ---- input -----------------------------------------------------------------------------------

def load_inventory(path, stdin):
    try:
        if path == "-":
            data = json.load(stdin)
        else:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
    except OSError as e:
        raise InputError(f"cannot read the inventory {path}: {e.strerror}") from None
    except ValueError:
        raise InputError(f"the inventory {path} is not valid JSON") from None
    if not isinstance(data, dict):
        raise InputError(f"the inventory {path} is not a JSON object")
    return data


def window(today, since_days):
    return today - dt.timedelta(days=since_days)


def header(command, today, since_days, sources):
    return {"command": command, "checked_on": today.isoformat(), "since_days": since_days,
            "window_start": window(today, since_days).isoformat(), "sources": sources}


# ---- node ------------------------------------------------------------------------------------

def node_installs(inv):
    """Every Node binary in the inventory, with the pm2 homes whose daemon runs it."""
    installs = {}
    for n in inv.get("node") or []:
        path = n.get("path")
        if not path:
            continue
        installs[path] = {"path": path, "version": n.get("version"),
                          "running": n.get("running") or 0,
                          "default_alias": bool(n.get("default_alias")), "pm2_homes": []}
    for p in inv.get("pm2") or []:
        path = p.get("daemon_node_path")
        if not path:
            continue
        if path not in installs:
            installs[path] = {"path": path, "version": p.get("daemon_node"), "running": 0,
                              "default_alias": False, "pm2_homes": []}
        installs[path]["pm2_homes"].append(p.get("pm2_home"))
    return [installs[k] for k in sorted(installs)]


def upstream_node_version(v):
    """The upstream version string, or None when v is not an upstream Node build."""
    if node_version(v):
        return v if v.startswith("v") else "v" + v
    m = NODESOURCE_RE.match(v or "")
    return "v" + m.group(1) if m else None


def line_support(major, schedule, today):
    """The release schedule of one major line, and its support state on `today`."""
    s = schedule.get(f"v{major}") if isinstance(schedule, dict) else None
    if not isinstance(s, dict):
        return {"support": None, "end": None}

    def day(key):
        try:
            return dt.date.fromisoformat(s.get(key) or "")
        except ValueError:
            return None

    start, lts, maint, end = day("start"), day("lts"), day("maintenance"), day("end")
    if end and today > end:
        support = "end_of_life"
    elif maint and today >= maint:
        support = "maintenance_lts" if lts else "maintenance"
    elif lts and today >= lts:
        support = "active_lts"
    elif start and today >= start:
        support = "current"
    else:
        support = "not_released"
    return {"support": support, "end": end.isoformat() if end else None}


def node_report(inv, fetcher, today, since_days):
    out = header("node", today, since_days, [NODE_INDEX_URL, NODE_SCHEDULE_URL])
    installs = node_installs(inv)
    out.update(installs=installs, versions=[], notes=[])
    if not installs:
        out["notes"].append("no Node.js found in the inventory")
        return out

    index = fetcher.get_json(NODE_INDEX_URL, MAX_AGE[NODE_INDEX_URL])
    if not isinstance(index, list):
        raise FetchError(f"unexpected answer from {NODE_INDEX_URL}: not a list")
    releases = []
    for r in index:
        if not isinstance(r, dict):
            continue
        v = node_version(r.get("version"))
        try:
            date = dt.date.fromisoformat(r.get("date") or "")
        except ValueError:
            continue
        if v:
            releases.append({"v": v, "version": r["version"], "date": date,
                             "lts": r.get("lts") or None, "security": r.get("security") is True})

    try:
        schedule = fetcher.get_json(NODE_SCHEDULE_URL, MAX_AGE[NODE_SCHEDULE_URL])
    except FetchError as e:
        schedule = None
        out["notes"].append(f"release schedule not checked ({e}); line support is unknown")

    start = window(today, since_days)
    by_version = {}
    for inst in installs:
        by_version.setdefault(inst["version"], []).append(inst)

    def sort_key(item):
        v = node_version(upstream_node_version(item[0]) or "")
        return (v is None, v or (), item[0] or "")

    for version, group in sorted(by_version.items(), key=sort_key):
        entry = {"version": version, "installs": len(group),
                 "running": sum(i["running"] for i in group)}
        out["versions"].append(entry)
        upstream = upstream_node_version(version)
        if not upstream:
            entry["status"] = "not_checked"
            entry["reason"] = ("not an upstream Node.js version (a distro package? see the usn command)"
                               if version else "version unknown")
            continue
        if upstream != version:
            entry["upstream_version"] = upstream
        v = node_version(upstream)
        line = [r for r in releases if r["v"][0] == v[0]]
        entry["major"] = v[0]
        if not line:
            entry["status"] = "unknown_major"
            entry["reason"] = f"no v{v[0]}.x release in the Node.js index"
            continue
        newest = max(line, key=lambda r: r["v"])
        missed = sorted((r for r in line if r["v"] > v and r["security"]), key=lambda r: r["v"])
        entry.update(
            status="behind" if missed else "up_to_date",
            lts_codename=newest["lts"],
            **line_support(v[0], schedule, today),
            latest_release=newest["version"],
            latest_release_date=newest["date"].isoformat(),
            fixed_in=missed[-1]["version"] if missed else None,
            missed_security_releases=[
                {"version": r["version"], "date": r["date"].isoformat(), "in_window": r["date"] >= start}
                for r in missed],
            new_in_window=any(r["date"] >= start for r in missed),
        )
    return out


# ---- usn -------------------------------------------------------------------------------------

def is_ubuntu_origin(origin):
    """Ubuntu's own repos: "Ubuntu", and the ESM ones ("UbuntuESM", "UbuntuESMApps")."""
    return bool(origin) and origin.startswith("Ubuntu")


def ubuntu_cves(fetcher, source, codename):
    """All CVEs with a released fix for `source` in `codename`. Returns (cves, truncated)."""
    found, offset = [], 0
    for _ in range(MAX_PAGES):
        query = urllib.parse.urlencode([("package", source), ("version", codename),
                                        ("status", "released"), ("limit", PAGE_SIZE),
                                        ("offset", offset)])
        url = f"{UBUNTU_CVES_URL}?{query}"
        data = fetcher.get_json(url, UBUNTU_MAX_AGE)
        if not isinstance(data, dict) or not isinstance(data.get("cves"), list):
            raise FetchError(f"unexpected answer from {url}: no 'cves' list")
        page = data["cves"]
        found.extend(c for c in page if isinstance(c, dict))
        offset += len(page)
        total = data.get("total_results")
        if not page or not isinstance(total, int) or offset >= total:
            return found, False
    return found, True


def release_status(cve, source, codename):
    """The status entry of `source` in `codename` from one CVE record, or None."""
    for pkg in cve.get("packages") or []:
        if isinstance(pkg, dict) and pkg.get("name") == source:
            for st in pkg.get("statuses") or []:
                if isinstance(st, dict) and st.get("release_codename") == codename:
                    return st
    return None


def cve_notices(cve, codename):
    """The USNs of one CVE that cover `codename`: [{id, title, published}]."""
    notices = cve.get("notices")
    if isinstance(notices, list) and notices:
        out = []
        for n in notices:
            if not isinstance(n, dict) or not n.get("id"):
                continue
            rel = n.get("release_packages")
            if isinstance(rel, dict) and codename not in rel:
                continue
            out.append({"id": n["id"], "title": n.get("title"),
                        "published": (n.get("published") or "")[:10] or None})
        return out
    return [{"id": i, "title": None, "published": None} for i in cve.get("notices_ids") or []]


def group_upgrades(upgradable):
    """Ubuntu-origin upgrades grouped by source package, plus kernel and vendor lists."""
    groups, kernel, vendor = {}, {}, []
    for p in upgradable:
        if not isinstance(p, dict) or not p.get("package"):
            continue
        name, source = p["package"], p.get("source") or p["package"]
        if not is_ubuntu_origin(p.get("origin")):
            vendor.append({k: p.get(k) for k in ("package", "source", "origin", "installed",
                                                 "candidate", "archives")})
            continue
        target = kernel if KERNEL_SOURCE_RE.match(source) else groups
        g = target.setdefault(source, {"source": source, "binaries": [], "installed": None,
                                       "candidate": None, "origin": p.get("origin"), "archives": []})
        g["binaries"].append(name)
        inst, cand = p.get("installed") or "", p.get("candidate") or ""
        # The lowest installed and the highest candidate of the binaries: the safe side.
        if inst and (g["installed"] is None or dpkg_cmp(inst, g["installed"]) < 0):
            g["installed"] = inst
        if cand and (g["candidate"] is None or dpkg_cmp(cand, g["candidate"]) > 0):
            g["candidate"] = cand
        for a in p.get("archives") or []:
            if a not in g["archives"]:
                g["archives"].append(a)
    for g in list(groups.values()) + list(kernel.values()):
        g["binaries"].sort()
    return groups, kernel, vendor


def usn_report(inv, fetcher, today, since_days):
    out = header("usn", today, since_days, [UBUNTU_CVES_URL])
    os_info = inv.get("os") or {}
    apt = inv.get("apt") or {}
    codename = os_info.get("codename")
    out.update(codename=codename, apt_lists_age_hours=apt.get("lists_age_hours"), packages=[],
               no_security_fix=[], kernel=[], vendor=[], notes=[],
               counts={"packages_with_fixes": 0, "cves": {}})
    if os_info.get("id") != "ubuntu" or not codename:
        out["notes"].append("not an Ubuntu server: USN data covers Ubuntu only")
        return out
    upgradable = apt.get("upgradable")
    if upgradable is None:
        out["notes"].append("no apt upgrade list in the inventory (apt-get missing on the server)")
        return out

    groups, kernel, vendor = group_upgrades(upgradable)
    out["kernel"] = [kernel[k] for k in sorted(kernel)]
    out["vendor"] = sorted(vendor, key=lambda p: p["package"])
    start = window(today, since_days).isoformat()
    cve_counts = {}

    for source in sorted(groups):
        g = groups[source]
        if not g["installed"] or not g["candidate"]:
            out["notes"].append(f"{source}: installed or candidate version missing; not checked")
            continue
        records, truncated = ubuntu_cves(fetcher, source, codename)
        cves, usns = [], {}
        for rec in records:
            st = release_status(rec, source, codename)
            fixed = (st or {}).get("description") or ""
            if not st or st.get("status") != "released" or not fixed:
                continue
            if dpkg_cmp(fixed, g["installed"]) <= 0:
                continue  # already installed
            notices = cve_notices(rec, codename)
            for n in notices:
                n["in_window"] = bool(n["published"]) and n["published"] >= start
                usns.setdefault(n["id"], n)
            priority = rec.get("priority")
            cves.append({"id": rec.get("id"), "priority": priority, "cvss3": rec.get("cvss3"),
                         "fixed": fixed, "pocket": st.get("pocket"),
                         "in_candidate": dpkg_cmp(fixed, g["candidate"]) <= 0,
                         "usns": sorted(n["id"] for n in notices)})
        if not cves:
            out["no_security_fix"].append({k: g[k] for k in ("source", "binaries", "installed",
                                                             "candidate", "archives")})
            if truncated:
                out["notes"].append(f"{source}: more than {MAX_PAGES * PAGE_SIZE} CVEs; list cut")
            continue
        cves.sort(key=lambda c: (priority_rank(c["priority"]), c["id"] or ""))
        for c in cves:
            key = c["priority"] if c["priority"] in PRIORITIES else "unknown"
            cve_counts[key] = cve_counts.get(key, 0) + 1
        usn_list = sorted(usns.values(), key=lambda n: (n["published"] or "", n["id"]), reverse=True)
        g.update(max_priority=cves[0]["priority"],
                 new_in_window=any(n["in_window"] for n in usn_list),
                 truncated=truncated, cves=cves, usns=usn_list)
        out["packages"].append(g)

    out["packages"].sort(key=lambda g: (priority_rank(g["max_priority"]), g["source"]))
    out["counts"] = {"packages_with_fixes": len(out["packages"]),
                     "cves": {k: cve_counts[k] for k in PRIORITIES + ["unknown"] if k in cve_counts}}
    if kernel:
        out["notes"].append("kernel packages are not looked up: see os.kernel_running, "
                            "kernel_newest_installed and reboot_required in the inventory")
    return out


# ---- kev -------------------------------------------------------------------------------------

def parse_cve_args(args, stdin):
    ids = []
    for a in args:
        if a == "-":
            ids.extend(m.upper() for m in CVE_RE.findall(stdin.read()))
        elif CVE_RE.fullmatch(a):
            ids.append(a.upper())
        else:
            raise InputError(f"not a CVE id: {a!r} (expected CVE-YYYY-NNNN, or - for stdin)")
    return sorted(set(ids))


def kev_report(ids, fetcher):
    out = {"command": "kev", "sources": [KEV_URL], "catalog_version": None,
           "date_released": None, "checked": len(ids), "hits": [], "not_listed": []}
    if not ids:
        return out
    data = fetcher.get_json(KEV_URL, MAX_AGE[KEV_URL])
    vulns = data.get("vulnerabilities") if isinstance(data, dict) else None
    if not isinstance(vulns, list):
        raise FetchError(f"unexpected answer from {KEV_URL}: no 'vulnerabilities' list")
    known = {}
    for v in vulns:
        if isinstance(v, dict) and isinstance(v.get("cveID"), str):
            known[v["cveID"].upper()] = v
    out["catalog_version"] = data.get("catalogVersion")
    out["date_released"] = data.get("dateReleased")
    for cve in ids:
        v = known.get(cve)
        if v is None:
            out["not_listed"].append(cve)
            continue
        out["hits"].append({"cve": cve, "vendor": v.get("vendorProject"), "product": v.get("product"),
                            "name": v.get("vulnerabilityName"), "date_added": v.get("dateAdded"),
                            "due_date": v.get("dueDate"),
                            "ransomware": v.get("knownRansomwareCampaignUse")})
    return out


# ---- command line ----------------------------------------------------------------------------

def _date(s):
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not a date (YYYY-MM-DD): {s!r}") from None


def _days(s):
    if not s.isdigit() or int(s) < 1:
        raise argparse.ArgumentTypeError(f"not a whole number of days: {s!r}")
    return int(s)


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--cache-dir", default=default_cache_dir(),
                        help="disk cache (default: %(default)s)")
    dated = argparse.ArgumentParser(add_help=False)
    dated.add_argument("--since-days", type=_days, default=14,
                       help="fixes published in this many days are marked in_window (default 14)")
    dated.add_argument("--today", type=_date, default=dt.datetime.now(dt.timezone.utc).date(),
                       help="the date to count from (default: today, UTC)")

    p = argparse.ArgumentParser(
        prog="advisories.py", description="Find security fixes for a server inventory.",
        epilog="Each command prints one JSON object. Exit 1: a source could not be fetched; "
               "2: bad input.")
    sub = p.add_subparsers(dest="command", required=True, metavar="{node,usn,kev}")
    for name, text in (("node", "Node.js security releases newer than ours"),
                       ("usn", "Ubuntu CVE fixes for the upgradable packages")):
        s = sub.add_parser(name, parents=[common, dated], help=text, description=text)
        s.add_argument("inventory", help="inventory JSON from inventory.sh, or - for stdin")
    s = sub.add_parser("kev", parents=[common], help="CVE ids in the CISA KEV catalog",
                       description="CVE ids in the CISA KEV catalog")
    s.add_argument("cves", nargs="*", metavar="CVE", help="CVE ids, or - to read them from stdin")
    return p


def main(argv=None, opener=None, stdin=None, stdout=None, now=time.time):
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    args = build_parser().parse_args(argv)
    fetcher = Fetcher(args.cache_dir, opener=opener, now=now)
    try:
        if args.command == "kev":
            result = kev_report(parse_cve_args(args.cves, stdin), fetcher)
        else:
            inv = load_inventory(args.inventory, stdin)
            report = node_report if args.command == "node" else usn_report
            result = report(inv, fetcher, args.today, args.since_days)
    except InputError as e:
        print(f"advisories.py: {e}", file=sys.stderr)
        return 2
    except FetchError as e:
        print(f"advisories.py: {e}\nCheck the network and run again.", file=sys.stderr)
        return 1
    json.dump(result, stdout, indent=2, ensure_ascii=False)
    stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
