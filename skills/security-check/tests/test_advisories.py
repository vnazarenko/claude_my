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
import shutil
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

    def test_release_on_window_start_is_in_window(self):
        data = self.run_report("node", extra=("--since-days", "3"))
        self.assertEqual(data["window_start"], "2026-10-20")
        v = self.versions(data)["v24.21.0"]
        self.assertEqual(v["missed_security_releases"],
                         [{"version": "v24.22.1", "date": "2026-10-20", "in_window": True}])
        self.assertTrue(v["new_in_window"])

    def support(self, version, today):
        """The support state of one install of `version` on the day `today`."""
        inv = {"node": [{"path": "/opt/x/bin/node", "version": version, "running": 1,
                         "container": False}]}
        rc, data, err = self.run_main(["node", self.write_inventory(inv), "--today", today])
        self.assertEqual(rc, 0, err)
        return data["versions"][0]["support"]

    def check_support(self, cases):
        for version, today, want in cases:
            with self.subTest(version=version, today=today):
                self.assertEqual(self.support(version, today), want)

    def test_support_before_and_on_start(self):
        # v26: start 2026-05-05, lts 2026-10-28
        self.check_support([("v26.0.0", "2026-05-04", "not_released"),
                            ("v26.0.0", "2026-05-05", "current"),
                            ("v26.0.0", TODAY, "current")])

    def test_support_on_lts_and_maintenance_days(self):
        # v26: lts 2026-10-28. v24: maintenance 2026-10-20. v25 (no LTS): maintenance 2026-04-01
        self.check_support([("v26.0.0", "2026-10-27", "current"),
                            ("v26.0.0", "2026-10-28", "active_lts"),
                            ("v24.21.0", "2026-10-19", "active_lts"),
                            ("v24.21.0", "2026-10-20", "maintenance_lts"),
                            ("v25.8.0", "2026-03-31", "current"),
                            ("v25.8.0", "2026-04-01", "maintenance")])

    def test_end_day_is_not_end_of_life(self):
        # v25: end 2026-06-01; end of life starts the day after
        self.check_support([("v25.8.0", "2026-06-01", "maintenance"),
                            ("v25.8.0", "2026-06-02", "end_of_life")])

    def test_up_to_date_is_empty(self):
        inv = {"node": [{"path": "/home/app/.nvm/versions/node/v24.22.1/bin/node",
                         "version": "v24.22.1", "running": 1, "container": False}]}
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
        # a host binary with no version, and a process in a container
        self.assertEqual(v[None]["reason"], "version unknown")
        self.assertEqual(v[None]["installs"], 2)

    def test_same_path_on_host_and_in_container(self):
        inv = inventory()
        inv["pm2"].append({"pm2_home": "/srv/sys/.pm2", "daemon_running": True,
                           "daemon_node_path": "/usr/bin/node", "daemon_node": "18.19.1"})
        data = self.run_report("node", inv)
        for i in data["installs"]:
            self.assertNotIn("default_alias", i)
        usr = [i for i in data["installs"] if i["path"] == "/usr/bin/node"]
        self.assertEqual([(i["container"], i["version"], i["running"], i["pm2_homes"]) for i in usr],
                         [(False, "18.19.1+dfsg-6ubuntu5", 0, ["/srv/sys/.pm2"]),
                          (True, None, 1, [])])

    def test_container_processes_not_checked(self):
        inv = {"node": [{"path": "/usr/bin/node", "version": None, "running": 2, "container": True},
                        {"path": "/app/bin/node", "version": None, "running": 1, "container": True}]}
        v = self.versions(self.run_report("node", inv))[None]
        self.assertEqual(v["status"], "not_checked")
        self.assertEqual(v["reason"], "runs in a container: check the container's image")
        self.assertEqual((v["installs"], v["running"]), (2, 3))

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

    def test_wrong_shape_is_an_error_and_not_cached(self):
        bad = FakeWeb(override={adv.KEV_URL: b'{"vulnerabilities": "maintenance"}'})
        rc, _, err = self.run_main(["kev", "CVE-2026-0101"], bad)
        self.assertEqual(rc, 1)
        self.assertIn("no 'vulnerabilities' list", err)
        self.assertFalse(os.path.exists(adv.Fetcher(self.cache).cache_path(adv.KEV_URL)))
        good = FakeWeb()
        rc, data, err = self.run_main(["kev", "CVE-2026-0101"], good)
        self.assertEqual(rc, 0, err)
        self.assertEqual(good.calls, [adv.KEV_URL])

    def test_cached_wrong_shape_is_fetched_again(self):
        path = adv.Fetcher(self.cache).cache_path(adv.NODE_INDEX_URL)
        os.makedirs(self.cache)
        with open(path, "w") as f:
            f.write('{"error": "rate limited"}')  # valid JSON, wrong shape; the file is new
        web = FakeWeb()
        rc, data, err = self.run_main(["node", self.write_inventory(inventory()), "--today", TODAY], web)
        self.assertEqual(rc, 0, err)
        self.assertIn(adv.NODE_INDEX_URL, web.calls)

    def test_cache_hit_skips_fetch(self):
        first = FakeWeb()
        data1 = self.run_report("usn", web=first)
        self.assertTrue(first.calls)
        second = FakeWeb(fail={k: AssertionError("fetched again") for k in FakeWeb.ROUTES})
        data2 = self.run_report("usn", web=second)
        self.assertEqual(second.calls, [])
        self.assertEqual(data1, data2)

    def test_one_cache_age_for_every_url(self):
        self.assertEqual(adv.CACHE_MAX_AGE, 6 * 3600)
        for url in (adv.NODE_INDEX_URL, adv.NODE_SCHEDULE_URL, adv.KEV_URL):
            with self.subTest(url=url):
                web = FakeWeb()
                fetcher = adv.Fetcher(self.cache, opener=web)
                fetcher.get_json(url)
                path = fetcher.cache_path(url)
                young = time.time() - adv.CACHE_MAX_AGE + 60
                os.utime(path, (young, young))
                fetcher.get_json(url)
                self.assertEqual(len(web.calls), 1)  # still fresh
                old = time.time() - adv.CACHE_MAX_AGE - 60
                os.utime(path, (old, old))
                fetcher.get_json(url)
                self.assertEqual(len(web.calls), 2)  # too old: fetched again
                fetcher.get_json(url)
                self.assertEqual(len(web.calls), 2)  # fresh again

    def test_corrupt_cache_is_fetched_again(self):
        web = FakeWeb()
        path = adv.Fetcher(self.cache).cache_path(adv.KEV_URL)
        os.makedirs(self.cache)
        with open(path, "w") as f:
            f.write('{"vulnerabilities": [')  # cut short; the file is new
        rc, data, err = self.run_main(["kev", "CVE-2026-0101"], web)
        self.assertEqual(rc, 0, err)
        self.assertEqual(web.calls, [adv.KEV_URL])
        self.assertEqual([h["cve"] for h in data["hits"]], ["CVE-2026-0101"])
        with open(path, "rb") as f:
            self.assertEqual(json.loads(f.read()), json.loads(fixture("kev.json")))

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

    def test_node_index_not_a_list(self):
        web = FakeWeb(override={adv.NODE_INDEX_URL: b'{"error": "rate limited"}'})
        path = self.write_inventory(inventory())
        rc, data, err = self.run_main(["node", path, "--today", TODAY], web)
        self.assertEqual(rc, 1)
        self.assertIsNone(data)
        self.assertIn("unexpected answer from " + adv.NODE_INDEX_URL + ": not a list", err)

    def test_kev_unexpected_shape(self):
        for body in (b'{"vulnerabilities": {"CVE-2026-0101": {}}}',
                     b'[{"cveID": "CVE-2026-0101"}]'):
            with self.subTest(body=body):
                shutil.rmtree(self.cache, ignore_errors=True)
                web = FakeWeb(override={adv.KEV_URL: body})
                rc, data, err = self.run_main(["kev", "CVE-2026-0101"], web)
                self.assertEqual(web.calls, [adv.KEV_URL])
                self.assertEqual(rc, 1)
                self.assertIsNone(data)
                self.assertIn("no 'vulnerabilities' list", err)


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

    def test_real_context_from_bundle_keeps_verification_on(self):
        # A real context with no CA certificates, like the python.org build: the fallback
        # loads a real CA bundle (fixtures/test-ca.pem, a synthetic self-signed CA).
        bare = adv.ssl.SSLContext(adv.ssl.PROTOCOL_TLS_CLIENT)
        self.assertEqual(bare.cert_store_stats()["x509_ca"], 0)
        ctx = self.context(bare, [os.path.join(self.dir, "missing.pem"),
                                  os.path.join(FIXTURES, "test-ca.pem")])
        self.assertIs(ctx, bare)
        self.assertGreaterEqual(ctx.cert_store_stats()["x509_ca"], 1)
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

    def test_binaries_grouped_by_source(self):
        # libssl3t64: 3.4 -> 3.5, openssl: 3.5 -> 3.6. The group takes the lowest installed
        # and the highest candidate, in any order of the list.
        for order in ("as listed", "reversed"):
            with self.subTest(order=order):
                inv = inventory()
                if order == "reversed":
                    inv["apt"]["upgradable"].reverse()
                g = self.packages(self.run_report("usn", inv))["openssl"]
                self.assertEqual((g["installed"], g["candidate"]),
                                 ("3.0.13-0ubuntu3.4", "3.0.13-0ubuntu3.6"))
                c = {c["id"]: c for c in g["cves"]}
                # fixed in 3.5: in openssl already, not in libssl3t64
                self.assertIn("CVE-2025-0103", c)
                # fixed in 3.6: in openssl's candidate, newer than libssl3t64's
                self.assertTrue(c["CVE-2026-0101"]["in_candidate"])

    def test_notice_on_window_start_is_in_window(self):
        data = self.run_report("usn", extra=("--since-days", "8"))
        self.assertEqual(data["window_start"], "2026-10-15")
        g = self.packages(data)["openssl"]
        self.assertEqual([(u["id"], u["in_window"]) for u in g["usns"]],
                         [("USN-9001-1", True), ("USN-8001-1", False)])
        self.assertTrue(g["new_in_window"])

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
                         [("clickhouse-server", None), ("docker-ce", "Docker_CE")])
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

    @staticmethod
    def nginx_page(first, count):
        """A cves.json answer with `count` pending nginx fixes and no total_results."""
        cves = [{"id": f"CVE-2026-{n}", "priority": "low",
                 "packages": [{"name": "nginx", "statuses": [
                     {"release_codename": "noble", "status": "released",
                      "description": "1.24.0-2ubuntu7.2", "pocket": "security"}]}],
                 "notices_ids": [], "notices": []} for n in range(first, first + count)]
        return json.dumps({"cves": cves}).encode()

    def test_pages_without_total_results(self):
        size = adv.PAGE_SIZE
        web = FakeWeb(override={("nginx", "0"): self.nginx_page(1000, size),
                                ("nginx", str(size)): self.nginx_page(2000, 3)})
        data = self.run_report("usn", web=web)
        offsets = [FakeWeb.key(u)[1] for u in web.calls if "package=nginx" in u]
        self.assertEqual(offsets, ["0", str(size)])  # a full page, then a short one
        g = self.packages(data)["nginx"]
        self.assertEqual(len(g["cves"]), size + 3)
        self.assertFalse(g["truncated"])

    def test_pages_without_total_results_are_capped(self):
        size = adv.PAGE_SIZE
        full = {("nginx", str(i * size)): self.nginx_page(1000 + 100 * i, size) for i in range(3)}
        web = FakeWeb(override=full)
        with mock.patch.object(adv, "MAX_PAGES", 2):
            g = self.packages(self.run_report("usn", web=web))["nginx"]
        self.assertEqual(web.packages_asked().count("nginx"), 2)
        self.assertEqual(len(g["cves"]), 2 * size)
        self.assertTrue(g["truncated"])

    def test_truncated_when_too_many_pages(self):
        with mock.patch.object(adv, "MAX_PAGES", 1):
            g = self.packages(self.run_report("usn"))["openssl"]
        self.assertTrue(g["truncated"])
        self.assertEqual([c["id"] for c in g["cves"]], ["CVE-2026-0101", "CVE-2026-0102"])

    def test_truncated_without_pending_fix_is_a_note(self):
        page = json.loads(fixture("ubuntu-cves-nginx.json"))
        page["total_results"] = 50  # only the first page is read
        web = FakeWeb(override={("nginx", "0"): json.dumps(page).encode()})
        with mock.patch.object(adv, "MAX_PAGES", 1):
            data = self.run_report("usn", web=web)
        self.assertEqual([p["source"] for p in data["no_security_fix"]], ["nginx"])
        self.assertIn(f"nginx: more than {adv.PAGE_SIZE} CVEs; list cut", data["notes"])

    def test_missing_version_is_a_note(self):
        inv = inventory()
        for p in inv["apt"]["upgradable"]:
            if p["source"] == "nginx":
                p["candidate"] = None
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertIn("nginx: installed or candidate version missing; not checked", data["notes"])
        self.assertNotIn("nginx", web.packages_asked())
        self.assertEqual(data["no_security_fix"], [])

    def test_unknown_priority_is_counted(self):
        page = json.loads(fixture("ubuntu-cves-curl.json"))
        page["cves"][0]["priority"] = "untriaged"  # CVE-2026-0201
        web = FakeWeb(override={("curl", "0"): json.dumps(page).encode()})
        data = self.run_report("usn", web=web)
        cves = data["counts"]["cves"]
        self.assertEqual(list(cves.items()), [("critical", 1), ("high", 1), ("medium", 1),
                                              ("low", 1), ("unknown", 1)])
        g = self.packages(data)["curl"]
        self.assertEqual([c["id"] for c in g["cves"]], ["CVE-2026-0202", "CVE-2026-0201"])

    def test_empty_upgrade_list(self):
        inv = inventory()
        inv["apt"]["upgradable"] = []
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertEqual((data["packages"], data["vendor"], data["kernel"]), ([], [], []))
        self.assertEqual(web.calls, [])

    def test_no_apt(self):
        inv = inventory()
        inv["apt"] = {"status": None, "lists_age_hours": None, "upgradable": None}
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertTrue(any("apt-get missing" in n and "not checked" in n for n in data["notes"]))
        self.assertEqual(web.calls, [])

    def test_apt_failed(self):
        # apt-get failed on the server: "not checked", never an empty result.
        inv = inventory()
        inv["apt"] = {"status": "error", "lists_age_hours": 20, "upgradable": None}
        web = FakeWeb()
        data = self.run_report("usn", inv, web)
        self.assertEqual(data["apt_status"], "error")
        self.assertTrue(any("apt-get failed" in n and "not checked" in n for n in data["notes"]))
        self.assertEqual((data["packages"], data["kernel"], data["vendor"]), ([], [], []))
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
        self.assertEqual(len(data["installs"]), 6)

    def test_bad_today(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            adv.main(["node", "x.json", "--today", "yesterday"], opener=FakeWeb())
        self.assertEqual(cm.exception.code, 2)

    def test_since_days_must_be_positive(self):
        for bad in ("0", "two"):
            with self.subTest(bad=bad):
                err = io.StringIO()
                with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as cm:
                    adv.main(["usn", "x.json", "--since-days", bad], opener=FakeWeb())
                self.assertEqual(cm.exception.code, 2)
                self.assertIn("not a whole number of days", err.getvalue())

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
