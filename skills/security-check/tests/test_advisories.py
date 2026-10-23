"""Unit tests for scripts/advisories.py.

Run:
  python3 -m unittest discover -s skills/security-check/tests -p 'test_*.py'

No test touches the network: every request goes to FakeWeb, which serves the files in
fixtures/. The real http_get is replaced by a function that fails the test.
All fixture data is synthetic.
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
FIXTURES = os.path.join(HERE, "fixtures")
sys.path.insert(0, SCRIPTS)
sys.dont_write_bytecode = True  # no __pycache__ in scripts/

import advisories as adv  # noqa: E402

TODAY = "2026-10-23"


def fixture(name):
    with open(os.path.join(FIXTURES, name), "rb") as f:
        return f.read()


def inventory():
    return json.loads(fixture("inventory.json"))


class FakeWeb:
    """Answers a URL with a fixture file and records every URL it was asked for."""

    ROUTES = {
        adv.NODE_INDEX_URL: "node-index.json",
        adv.NODE_SCHEDULE_URL: "node-schedule.json",
        adv.KEV_URL: "kev.json",
        ("openssl", "0"): "ubuntu-cves-openssl-p1.json",
        ("openssl", "2"): "ubuntu-cves-openssl-p2.json",
        ("curl", "0"): "ubuntu-cves-curl.json",
        ("nginx", "0"): "ubuntu-cves-nginx.json",
    }

    def __init__(self, fail=None, override=None):
        self.calls = []
        self.fail = fail or {}          # key -> exception to raise
        self.override = override or {}  # key -> bytes to answer

    @staticmethod
    def key(url):
        parts = urllib.parse.urlsplit(url)
        if parts.path == "/security/cves.json":
            q = dict(urllib.parse.parse_qsl(parts.query))
            assert q["version"] == "noble" and q["status"] == "released", url
            assert q["limit"] == str(adv.PAGE_SIZE), url
            return (q["package"], q["offset"])
        return url

    def __call__(self, url):
        self.calls.append(url)
        key = self.key(url)
        if key in self.fail:
            raise self.fail[key]
        if key in self.override:
            return self.override[key]
        if key not in self.ROUTES:
            raise urllib.error.HTTPError(url, 404, "Not Found", None, None)
        return fixture(self.ROUTES[key])

    def packages_asked(self):
        return [self.key(u)[0] for u in self.calls if "/security/cves.json" in u]


def no_network(url):
    raise AssertionError(f"a test tried to reach the network: {url}")


class Base(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(adv, "http_get", no_network)
        patcher.start()
        self.addCleanup(patcher.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name
        self.cache = os.path.join(self.tmp, "cache")

    def write_inventory(self, data):
        path = os.path.join(self.tmp, "inventory.json")
        with open(path, "w") as f:
            json.dump(data, f)
        return path

    def run_main(self, argv, web=None, stdin=""):
        """Run main(); return (exit code, parsed stdout or None, stderr text)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = adv.main(argv + ["--cache-dir", self.cache], opener=web or FakeWeb(),
                          stdin=io.StringIO(stdin), stdout=out)
        text = out.getvalue()
        return rc, (json.loads(text) if text else None), err.getvalue()

    def run_report(self, cmd, inv=None, web=None, extra=()):
        path = self.write_inventory(inventory() if inv is None else inv)
        rc, data, err = self.run_main([cmd, path, "--today", TODAY, *extra], web)
        self.assertEqual(rc, 0, err)
        return data


# ---- versions --------------------------------------------------------------------------------

class TestVersions(unittest.TestCase):
    def test_dpkg_cmp(self):
        cases = [
            ("3.0.13-0ubuntu3.10", "3.0.13-0ubuntu3.9", 1),
            ("3.0.13-0ubuntu3.4", "3.0.13-0ubuntu3.4", 0),
            ("1.0~rc1", "1.0", -1),
            ("1.0", "1.0-0", 0),
            ("1.0a", "1.0", 1),
            ("1.0+b1", "1.0", 1),
            ("2:1.0", "1:9.9", 1),
            ("5:27.3.1-1~ubuntu.24.04~noble", "5:27.3.2-1~ubuntu.24.04~noble", -1),
            ("8.5.0-2ubuntu10.8+esm1", "8.5.0-2ubuntu10.7", 1),
            ("1.24.0-2ubuntu7.1", "1.24.0-2ubuntu7.10", -1),
            ("0.9", "0.10", -1),
            ("1.001", "1.1", 0),
        ]
        for a, b, want in cases:
            with self.subTest(a=a, b=b):
                self.assertEqual(adv.dpkg_cmp(a, b), want)
                self.assertEqual(adv.dpkg_cmp(b, a), -want)

    def test_node_version(self):
        self.assertEqual(adv.node_version("v24.21.0"), (24, 21, 0))
        self.assertEqual(adv.node_version("22.2.0"), (22, 2, 0))
        self.assertIsNone(adv.node_version("18.19.1+dfsg-6ubuntu5"))
        self.assertIsNone(adv.node_version(None))
        self.assertEqual(adv.upstream_node_version("22.11.0-1nodesource1"), "v22.11.0")
        self.assertEqual(adv.upstream_node_version("24.21.0"), "v24.21.0")
        self.assertIsNone(adv.upstream_node_version("18.19.1+dfsg-6ubuntu5"))


# ---- node ------------------------------------------------------------------------------------

class TestNode(Base):
    def versions(self, data):
        return {v["version"]: v for v in data["versions"]}

    def test_v24_21_0_behind_by_one(self):
        v = self.versions(self.run_report("node"))["v24.21.0"]
        self.assertEqual(v["status"], "behind")
        self.assertEqual(v["fixed_in"], "v24.22.1")
        self.assertEqual(v["latest_release"], "v24.22.1")
        self.assertEqual(v["missed_security_releases"],
                         [{"version": "v24.22.1", "date": "2026-10-20", "in_window": True}])
        self.assertTrue(v["new_in_window"])
        self.assertEqual(v["lts_codename"], "Krypton")
        self.assertEqual(v["support"], "maintenance_lts")

    def test_v22_2_0_many_missed(self):
        v = self.versions(self.run_report("node"))["v22.2.0"]
        missed = [r["version"] for r in v["missed_security_releases"]]
        self.assertEqual(missed, ["v22.4.1", "v22.13.1", "v22.15.1", "v22.17.1", "v22.22.0",
                                  "v22.22.2", "v22.23.0", "v22.23.2", "v22.23.4"])
        self.assertEqual(v["fixed_in"], "v22.23.4")
        # only the newest one is inside the 14-day window
        self.assertEqual([r["in_window"] for r in v["missed_security_releases"]], [False] * 8 + [True])
        self.assertEqual(v["installs"], 2)  # two nvm trees with the same version
        self.assertEqual(v["running"], 1)

    def test_window_size_changes_in_window_only(self):
        data = self.run_report("node", extra=("--since-days", "2"))
        v = self.versions(data)["v24.21.0"]
        self.assertEqual(data["window_start"], "2026-10-21")
        self.assertEqual(len(v["missed_security_releases"]), 1)  # still reported
        self.assertFalse(v["new_in_window"])

    def test_up_to_date_is_empty(self):
        inv = {"node": [{"path": "/home/app/.nvm/versions/node/v24.22.1/bin/node",
                         "version": "v24.22.1", "running": 1, "default_alias": True}]}
        v = self.versions(self.run_report("node", inv))["v24.22.1"]
        self.assertEqual(v["status"], "up_to_date")
        self.assertEqual(v["missed_security_releases"], [])
        self.assertIsNone(v["fixed_in"])
        self.assertFalse(v["new_in_window"])

    def test_pm2_daemon_linked_to_install(self):
        installs = {i["path"]: i for i in self.run_report("node")["installs"]}
        self.assertEqual(installs["/home/app/.nvm/versions/node/v24.21.0/bin/node"]["pm2_homes"],
                         ["/srv/app/.pm2"])
        # a pm2 home whose daemon is down adds nothing
        self.assertNotIn(None, installs)

    def test_pm2_daemon_node_not_in_node_list(self):
        inv = {"node": [], "pm2": [{"pm2_home": "/srv/app/.pm2",
                                    "daemon_node_path": "/opt/node/v24.21.0/bin/node",
                                    "daemon_node": "v24.21.0"}]}
        data = self.run_report("node", inv)
        self.assertEqual(data["installs"][0]["pm2_homes"], ["/srv/app/.pm2"])
        self.assertEqual(self.versions(data)["v24.21.0"]["status"], "behind")

    def test_distro_and_unknown_versions_not_checked(self):
        v = self.versions(self.run_report("node"))
        self.assertEqual(v["18.19.1+dfsg-6ubuntu5"]["status"], "not_checked")
        self.assertIn("distro package", v["18.19.1+dfsg-6ubuntu5"]["reason"])
        self.assertEqual(v[None]["status"], "not_checked")
        self.assertEqual(v[None]["reason"], "version unknown")

    def test_nodesource_package_is_checked(self):
        inv = {"node": [{"path": "/usr/bin/node", "version": "22.11.0-1nodesource1", "running": 1}]}
        v = self.versions(self.run_report("node", inv))["22.11.0-1nodesource1"]
        self.assertEqual(v["upstream_version"], "v22.11.0")
        self.assertEqual(v["status"], "behind")
        self.assertEqual(v["fixed_in"], "v22.23.4")

    def test_unknown_major(self):
        inv = {"node": [{"path": "/opt/x/bin/node", "version": "v99.1.0", "running": 0}]}
        v = self.versions(self.run_report("node", inv))["v99.1.0"]
        self.assertEqual(v["status"], "unknown_major")
        self.assertIn("v99", v["reason"])

    def test_non_lts_line_past_end_of_life(self):
        inv = {"node": [{"path": "/opt/x/bin/node", "version": "v25.8.0", "running": 1}]}
        v = self.versions(self.run_report("node", inv))["v25.8.0"]
        self.assertEqual(v["status"], "behind")
        self.assertIsNone(v["lts_codename"])
        self.assertEqual(v["support"], "end_of_life")
        self.assertEqual(v["end"], "2026-06-01")
        self.assertEqual(v["fixed_in"], "v25.8.2")
        self.assertEqual(v["latest_release"], "v25.9.0")

    def test_index_entries_that_are_not_versions_are_ignored(self):
        data = self.run_report("node")
        self.assertNotIn("nightly-build", json.dumps(data))

    def test_empty_inventory_no_requests(self):
        web = FakeWeb()
        data = self.run_report("node", {"node": None, "pm2": []}, web)
        self.assertEqual(data["installs"], [])
        self.assertEqual(data["versions"], [])
        self.assertIn("no Node.js found in the inventory", data["notes"])
        self.assertEqual(web.calls, [])

    def test_schedule_error_is_a_note(self):
        web = FakeWeb(fail={adv.NODE_SCHEDULE_URL: urllib.error.URLError("timed out")})
        data = self.run_report("node", web=web)
        v = self.versions(data)["v24.21.0"]
        self.assertIsNone(v["support"])
        self.assertEqual(v["fixed_in"], "v24.22.1")
        self.assertTrue(any("release schedule not checked" in n for n in data["notes"]))


# ---- network and cache -----------------------------------------------------------------------

class TestFetch(Base):
    def test_network_error_clear_message(self):
        web = FakeWeb(fail={adv.NODE_INDEX_URL: urllib.error.URLError("Name or service not known")})
        path = self.write_inventory(inventory())
        rc, data, err = self.run_main(["node", path, "--today", TODAY], web)
        self.assertEqual(rc, 1)
        self.assertIsNone(data)
        self.assertIn("could not fetch https://nodejs.org/dist/index.json: Name or service not known", err)
        self.assertIn("Check the network", err)

    def test_http_error_clear_message(self):
        web = FakeWeb(fail={("curl", "0"): urllib.error.HTTPError("u", 503, "busy", None, None)})
        path = self.write_inventory(inventory())
        rc, _, err = self.run_main(["usn", path, "--today", TODAY], web)
        self.assertEqual(rc, 1)
        self.assertIn("HTTP 503", err)
        self.assertIn("package=curl", err)

    def test_timeout_clear_message(self):
        web = FakeWeb(fail={adv.KEV_URL: TimeoutError("timed out")})
        rc, _, err = self.run_main(["kev", "CVE-2026-0101"], web)
        self.assertEqual(rc, 1)
        self.assertIn("could not fetch " + adv.KEV_URL + ": timed out", err)

    def test_not_json_is_an_error_and_not_cached(self):
        web = FakeWeb(override={adv.KEV_URL: b"<html>maintenance</html>"})
        rc, _, err = self.run_main(["kev", "CVE-2026-0101"], web)
        self.assertEqual(rc, 1)
        self.assertIn("the answer is not JSON", err)
        fetcher = adv.Fetcher(self.cache)
        self.assertFalse(os.path.exists(fetcher.cache_path(adv.KEV_URL)))

    def test_cache_hit_skips_fetch(self):
        first = FakeWeb()
        data1 = self.run_report("usn", web=first)
        self.assertTrue(first.calls)
        second = FakeWeb(fail={k: AssertionError("fetched again") for k in FakeWeb.ROUTES})
        data2 = self.run_report("usn", web=second)
        self.assertEqual(second.calls, [])
        self.assertEqual(data1, data2)

    def test_old_cache_is_fetched_again(self):
        web = FakeWeb()
        fetcher = adv.Fetcher(self.cache, opener=web)
        fetcher.get_json(adv.KEV_URL, 3600)
        two_hours_ago = time.time() - 7200
        os.utime(fetcher.cache_path(adv.KEV_URL), (two_hours_ago, two_hours_ago))
        fetcher.get_json(adv.KEV_URL, 3600)
        self.assertEqual(len(web.calls), 2)
        fetcher.get_json(adv.KEV_URL, 3600)
        self.assertEqual(len(web.calls), 2)  # fresh again

    def test_cache_dir_from_env(self):
        with mock.patch.dict(os.environ, {"SECURITY_CHECK_CACHE": "/srv/cache-x"}):
            self.assertEqual(adv.default_cache_dir(), "/srv/cache-x")

    def test_certificate_error_names_the_fix(self):
        err_obj = urllib.error.URLError(
            "[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer")
        web = FakeWeb(fail={adv.KEV_URL: err_obj})
        rc, _, err = self.run_main(["kev", "CVE-2026-0101"], web)
        self.assertEqual(rc, 1)
        self.assertIn("CERTIFICATE_VERIFY_FAILED", err)
        self.assertIn("SSL_CERT_FILE", err)

    def test_other_errors_have_no_certificate_hint(self):
        web = FakeWeb(fail={adv.KEV_URL: TimeoutError("timed out")})
        _, _, err = self.run_main(["kev", "CVE-2026-0101"], web)
        self.assertNotIn("SSL_CERT_FILE", err)

    def test_unexpected_shape(self):
        web = FakeWeb(override={("curl", "0"): b'{"errors": "bad query"}'})
        path = self.write_inventory(inventory())
        rc, _, err = self.run_main(["usn", path, "--today", TODAY], web)
        self.assertEqual(rc, 1)
        self.assertIn("no 'cves' list", err)


class FakeContext:
    """Stands in for ssl.SSLContext: a CA count and a record of the bundles loaded."""

    def __init__(self, ca=0, bad=()):
        self.ca = ca
        self.bad = set(bad)
        self.loaded = []

    def cert_store_stats(self):
        return {"x509": self.ca, "crl": 0, "x509_ca": self.ca}

    def load_verify_locations(self, cafile=None):
        if cafile in self.bad:
            raise adv.ssl.SSLError("bad bundle")
        self.loaded.append(cafile)
        self.ca += 1


class TestSslContext(unittest.TestCase):
    """http_get must work on a Python whose OpenSSL has no CA store, without turning off checks."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = tmp.name
        env = mock.patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("SSL_CERT_FILE", None)
        os.environ.pop("SSL_CERT_DIR", None)

    def bundle(self, name):
        path = os.path.join(self.dir, name)
        with open(path, "w") as f:
            f.write("synthetic\n")
        return path

    def context(self, fake, bundles):
        with mock.patch.object(adv.ssl, "create_default_context", return_value=fake):
            return adv.ssl_context(bundles)

    def test_store_with_ca_is_kept(self):
        fake = FakeContext(ca=5)
        self.assertIs(self.context(fake, [self.bundle("a.pem")]), fake)
        self.assertEqual(fake.loaded, [])

    def test_empty_store_loads_first_existing_bundle(self):
        missing = os.path.join(self.dir, "missing.pem")
        first, second = self.bundle("first.pem"), self.bundle("second.pem")
        fake = FakeContext()
        self.context(fake, [missing, first, second])
        self.assertEqual(fake.loaded, [first])

    def test_bad_bundle_is_skipped(self):
        bad, good = self.bundle("bad.pem"), self.bundle("good.pem")
        fake = FakeContext(bad=[bad])
        self.context(fake, [bad, good])
        self.assertEqual(fake.loaded, [good])

    def test_no_bundle_leaves_context_as_is(self):
        fake = FakeContext()
        self.assertIs(self.context(fake, [os.path.join(self.dir, "none.pem")]), fake)
        self.assertEqual(fake.loaded, [])

    def test_user_choice_in_env_wins(self):
        for var in ("SSL_CERT_FILE", "SSL_CERT_DIR"):
            with mock.patch.dict(os.environ, {var: self.dir}):
                fake = FakeContext()
                self.context(fake, [self.bundle("a.pem")])
                self.assertEqual(fake.loaded, [], var)

    def test_real_context_keeps_verification_on(self):
        ctx = adv.ssl_context([os.path.join(self.dir, "none.pem")])
        self.assertEqual(ctx.verify_mode, adv.ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)

    def test_http_get_passes_the_context(self):
        seen = {}

        class Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b"{}"

        def fake_urlopen(req, timeout=None, context=None):
            seen["context"] = context
            return Resp()

        fake = FakeContext(ca=1)
        with mock.patch.object(adv, "_SSL_CONTEXT", None), \
                mock.patch.object(adv.ssl, "create_default_context", return_value=fake), \
                mock.patch.object(adv.urllib.request, "urlopen", fake_urlopen):
            self.assertEqual(adv.http_get("https://example.invalid/x.json"), b"{}")
        self.assertIs(seen["context"], fake)


# ---- usn -------------------------------------------------------------------------------------

class TestUsn(Base):
    def packages(self, data):
        return {g["source"]: g for g in data["packages"]}

    def test_two_pages_and_pending_fixes(self):
        web = FakeWeb()
        data = self.run_report("usn", web=web)
        openssl = [u for u in web.calls if "package=openssl" in u]
        self.assertEqual(len(openssl), 2)
        self.assertIn("offset=0", openssl[0])
        self.assertIn("offset=2", openssl[1])
        g = self.packages(data)["openssl"]
        # sorted by priority; the fix already installed (0104) and not-affected (0105) are out
        self.assertEqual([(c["id"], c["priority"]) for c in g["cves"]],
                         [("CVE-2026-0101", "high"), ("CVE-2025-0103", "medium"), ("CVE-2026-0102", "low")])
        self.assertEqual(g["binaries"], ["libssl3t64", "openssl"])
        self.assertEqual(g["max_priority"], "high")
        self.assertTrue(g["new_in_window"])
        self.assertFalse(g["truncated"])

    def test_usn_list_only_for_our_release(self):
        g = self.packages(self.run_report("usn"))["openssl"]
        self.assertEqual([(u["id"], u["published"], u["in_window"]) for u in g["usns"]],
                         [("USN-9001-1", "2026-10-15", True), ("USN-8001-1", "2025-06-01", False)])
        self.assertNotIn("USN-9001-2", json.dumps(g))  # that notice covers another release

    def test_fix_newer_than_candidate(self):
        g = self.packages(self.run_report("usn"))["curl"]
        c = {c["id"]: c for c in g["cves"]}
        self.assertFalse(c["CVE-2026-0202"]["in_candidate"])
        self.assertEqual(c["CVE-2026-0202"]["pocket"], "esm-infra")
        self.assertTrue(c["CVE-2026-0201"]["in_candidate"])
        self.assertEqual(c["CVE-2026-0201"]["usns"], ["USN-9002-1"])  # from notices_ids

    def test_no_security_fix(self):
        data = self.run_report("usn")
        self.assertNotIn("nginx", self.packages(data))
        self.assertEqual([p["source"] for p in data["no_security_fix"]], ["nginx"])

    def test_vendor_and_kernel_not_looked_up(self):
        web = FakeWeb()
        data = self.run_report("usn", web=web)
        self.assertEqual(sorted(web.packages_asked()), ["curl", "nginx", "openssl", "openssl"])
        self.assertEqual([(p["package"], p["origin"]) for p in data["vendor"]],
                         [("clickhouse-server", None), ("docker-ce", "Docker CE")])
        self.assertEqual([k["source"] for k in data["kernel"]], ["linux-meta"])
        self.assertTrue(any("kernel" in n for n in data["notes"]))

    def test_counts(self):
        data = self.run_report("usn")
        self.assertEqual(data["counts"], {"packages_with_fixes": 2,
                                          "cves": {"critical": 1, "high": 1, "medium": 2, "low": 1}})

    def test_esm_origin_is_ubuntu(self):
        inv = inventory()
        for p in inv["apt"]["upgradable"]:
            if p["source"] == "curl":
                p["origin"] = "UbuntuESM"
        data = self.run_report("usn", inv)
        self.assertIn("curl", self.packages(data))

    def test_truncated_when_too_many_pages(self):
        with mock.patch.object(adv, "MAX_PAGES", 1):
            g = self.packages(self.run_report("usn"))["openssl"]
        self.assertTrue(g["truncated"])
        self.assertEqual([c["id"] for c in g["cves"]], ["CVE-2026-0101", "CVE-2026-0102"])

    def test_empty_upgrade_list(self):
        inv = inventory()
        inv["apt"]["upgradable"] = []
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertEqual((data["packages"], data["vendor"], data["kernel"]), ([], [], []))
        self.assertEqual(web.calls, [])

    def test_no_apt(self):
        inv = inventory()
        inv["apt"] = {"lists_age_hours": None, "upgradable": None}
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertTrue(any("apt-get missing" in n for n in data["notes"]))
        self.assertEqual(web.calls, [])

    def test_not_ubuntu(self):
        inv = inventory()
        inv["os"] = {"id": "debian", "codename": "bookworm"}
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertTrue(any("not an Ubuntu server" in n for n in data["notes"]))
        self.assertEqual(web.calls, [])

    def test_empty_inventory(self):
        web = FakeWeb()
        data = self.run_report("usn", {}, web)
        self.assertEqual(data["packages"], [])
        self.assertEqual(web.calls, [])


# ---- kev -------------------------------------------------------------------------------------

class TestKev(Base):
    def test_hits(self):
        rc, data, _ = self.run_main(["kev", "CVE-2026-0101", "cve-2026-0202"])
        self.assertEqual(rc, 0)
        self.assertEqual([h["cve"] for h in data["hits"]], ["CVE-2026-0101"])
        self.assertEqual(data["hits"][0]["due_date"], "2026-11-10")
        self.assertEqual(data["not_listed"], ["CVE-2026-0202"])
        self.assertEqual(data["catalog_version"], "2026.10.23")
        self.assertEqual(data["checked"], 2)

    def test_ids_from_stdin(self):
        usn = self.run_report("usn")
        rc, data, _ = self.run_main(["kev", "-"], stdin=json.dumps(usn))
        self.assertEqual(rc, 0)
        self.assertEqual(data["checked"], 5)
        self.assertEqual([h["cve"] for h in data["hits"]], ["CVE-2026-0101"])

    def test_bad_id_no_fetch(self):
        web = FakeWeb()
        rc, data, err = self.run_main(["kev", "CVE-2026-0101", "openssl"], web)
        self.assertEqual(rc, 2)
        self.assertIn("not a CVE id: 'openssl'", err)
        self.assertEqual(web.calls, [])

    def test_no_ids_no_fetch(self):
        web = FakeWeb()
        rc, data, _ = self.run_main(["kev", "-"], web, stdin="nothing here")
        self.assertEqual(rc, 0)
        self.assertEqual((data["checked"], data["hits"]), (0, []))
        self.assertEqual(web.calls, [])


# ---- input and command line ------------------------------------------------------------------

class TestInput(Base):
    def test_missing_inventory(self):
        rc, _, err = self.run_main(["node", os.path.join(self.tmp, "nope.json")])
        self.assertEqual(rc, 2)
        self.assertIn("cannot read the inventory", err)

    def test_inventory_not_json(self):
        path = os.path.join(self.tmp, "bad.json")
        with open(path, "w") as f:
            f.write("not json")
        rc, _, err = self.run_main(["usn", path])
        self.assertEqual(rc, 2)
        self.assertIn("not valid JSON", err)

    def test_inventory_from_stdin(self):
        rc, data, _ = self.run_main(["node", "-", "--today", TODAY], stdin=fixture("inventory.json").decode())
        self.assertEqual(rc, 0)
        self.assertEqual(len(data["installs"]), 5)

    def test_bad_today(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            adv.main(["node", "x.json", "--today", "yesterday"], opener=FakeWeb())
        self.assertEqual(cm.exception.code, 2)

    def test_cli_runs_without_network(self):
        script = os.path.join(SCRIPTS, "advisories.py")
        env = dict(os.environ, SECURITY_CHECK_CACHE=self.cache)
        r = subprocess.run([sys.executable, "-I", script, "--help"], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0)
        self.assertIn("node", r.stdout)
        r = subprocess.run([sys.executable, "-I", script, "kev", "not-a-cve"],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 2)
        self.assertIn("not a CVE id", r.stderr)


if __name__ == "__main__":
    unittest.main()
