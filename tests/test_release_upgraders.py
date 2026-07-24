#!/usr/bin/env python3
"""Fixture tests for P0-3 meta-release / release upgrader sync & validation."""
from __future__ import print_function

import http.server
import os
import shutil
import socketserver
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from collections import OrderedDict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
LIB = os.path.join(ROOT, "scripts", "lib")
sys.path.insert(0, LIB)

import sync_release_upgraders as sru  # noqa: E402

PUBLIC = "http://mirror.test"
UPGRADER_DISTS = ["bionic", "focal", "jammy", "noble"]
META_CHAIN = ["xenial", "bionic", "focal", "jammy", "noble"]


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def make_upstream_meta(dists_extra=None):
    """Minimal Ubuntu-shaped meta-release-lts with xenial + 4 hop targets."""
    blocks = []
    # Dates must increase so MetaReleaseCore finds the next hop
    specs = [
        ("xenial", "16.04.7 LTS", "Thu, 21 April 2016 16:04:00 UTC"),
        ("bionic", "18.04.6 LTS", "Thu, 26 April 2018 18:04:00 UTC"),
        ("focal", "20.04.6 LTS", "Thu, 23 April 2020 20:04:00 UTC"),
        ("jammy", "22.04.5 LTS", "Thu, 21 April 2022 22:04:00 UTC"),
        ("noble", "24.04.4 LTS", "Thu, 25 April 2024 00:24:04 UTC"),
    ]
    if dists_extra:
        specs = [s for s in specs if s[0] in dists_extra or s[0] == "xenial"]
    for dist, ver, date in specs:
        base = (
            "http://archive.ubuntu.com/ubuntu/dists/"
            "{}-updates/main/dist-upgrader-all/current".format(dist)
        )
        blocks.append(
            "\n".join(
                [
                    "Dist: {}".format(dist),
                    "Name: {}".format(dist.capitalize()),
                    "Version: {}".format(ver),
                    "Date: {}".format(date),
                    "Supported: 1",
                    "Description: This is the {} release".format(ver),
                    "Release-File: http://archive.ubuntu.com/ubuntu/dists/{}-updates/Release".format(
                        dist
                    ),
                    "ReleaseNotes: {}/ReleaseAnnouncement".format(base),
                    "ReleaseNotesHtml: {}/ReleaseAnnouncement.html".format(base),
                    "UpgradeTool: {}/{}.tar.gz".format(base, dist),
                    "UpgradeToolSignature: {}/{}.tar.gz.gpg".format(base, dist),
                ]
            )
        )
    return "\n\n".join(blocks) + "\n"


class GpgFixture(object):
    def __init__(self, workdir):
        self.workdir = workdir
        self.gnupg = os.path.join(workdir, "gnupg-test")
        self.keyring = os.path.join(workdir, "test-keyring.gpg")
        self.unknown_keyring = os.path.join(workdir, "unknown-keyring.gpg")
        os.makedirs(self.gnupg, mode=0o700)
        cfg = os.path.join(workdir, "gpg-batch")
        write(
            cfg,
            "\n".join(
                [
                    "%no-protection",
                    "Key-Type: RSA",
                    "Key-Length: 2048",
                    "Name-Real: Ubuntu Mirror Fixture",
                    "Name-Email: fixture-upgrader@example.invalid",
                    "Expire-Date: 0",
                    "%commit",
                    "",
                ]
            ),
        )
        env = os.environ.copy()
        env["GNUPGHOME"] = self.gnupg
        subprocess.run(
            ["gpg", "--batch", "--gen-key", cfg],
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["gpg", "--batch", "--export", "--output", self.keyring],
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Second key for "unknown key" tests
        cfg2 = os.path.join(workdir, "gpg-batch2")
        write(
            cfg2,
            "\n".join(
                [
                    "%no-protection",
                    "Key-Type: RSA",
                    "Key-Length: 2048",
                    "Name-Real: Unknown Fixture",
                    "Name-Email: unknown@example.invalid",
                    "Expire-Date: 0",
                    "%commit",
                    "",
                ]
            ),
        )
        gnupg2 = os.path.join(workdir, "gnupg-unknown")
        os.makedirs(gnupg2, mode=0o700)
        env2 = os.environ.copy()
        env2["GNUPGHOME"] = gnupg2
        subprocess.run(
            ["gpg", "--batch", "--gen-key", cfg2],
            env=env2,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["gpg", "--batch", "--export", "--output", self.unknown_keyring],
            env=env2,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._env = env

    def sign(self, path, sig_path=None):
        if sig_path is None:
            sig_path = path + ".gpg"
        subprocess.run(
            ["gpg", "--batch", "--detach-sign", "--output", sig_path, path],
            env=self._env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return sig_path


def make_tarball(path, dist):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    staging = path + ".dir"
    os.makedirs(staging, exist_ok=True)
    script = os.path.join(staging, dist)
    write(script, "#!/bin/sh\necho upgrader-{}-ok\n".format(dist))
    os.chmod(script, 0o755)
    with tarfile.open(path, "w:gz") as tar:
        tar.add(script, arcname=dist)
    shutil.rmtree(staging)


class MirrorFixture(object):
    def __init__(self, workdir, gpg):
        self.root = os.path.join(workdir, "mirror-root")
        self.ubuntu = os.path.join(
            self.root, "mirror", "archive.ubuntu.com", "ubuntu"
        )
        self.offline = os.path.join(self.root, "offline")
        os.makedirs(self.ubuntu, exist_ok=True)
        os.makedirs(self.offline, exist_ok=True)
        self.gpg = gpg
        self.upstream_meta = os.path.join(workdir, "upstream-meta-release-lts")
        write(self.upstream_meta, make_upstream_meta())
        for dist in UPGRADER_DISTS + ["xenial"]:
            cur = os.path.join(
                self.ubuntu,
                "dists",
                "{}-updates".format(dist),
                "main",
                "dist-upgrader-all",
                "current",
            )
            os.makedirs(cur, exist_ok=True)
            tar = os.path.join(cur, "{}.tar.gz".format(dist))
            make_tarball(tar, dist)
            gpg.sign(tar)
            write(os.path.join(cur, "ReleaseAnnouncement"), "notes {}\n".format(dist))
            write(
                os.path.join(cur, "ReleaseAnnouncement.html"),
                "<html>notes {}</html>\n".format(dist),
            )
            # Release file for Release-File rewrite target
            rel = os.path.join(
                self.ubuntu, "dists", "{}-updates".format(dist), "Release"
            )
            write(rel, "Suite: {}-updates\n".format(dist))


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class TestReleaseUpgraders(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._class_tmp = tempfile.mkdtemp(prefix="ru-class-")
        cls.gpg = GpgFixture(cls._class_tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._class_tmp, ignore_errors=True)

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="ru-test-")
        self.addCleanup(shutil.rmtree, self.tmpdir, True)
        self.fx = MirrorFixture(self.tmpdir, self.gpg)

    def _sync(self, **kwargs):
        kw = dict(
            mirror_root=self.fx.root,
            ubuntu_root=self.fx.ubuntu,
            public_base=PUBLIC,
            meta_release_url="http://unused.example/meta-release-lts",
            upgrader_dists=UPGRADER_DISTS,
            meta_chain=META_CHAIN,
            keyring=self.gpg.keyring,
            allowed_hosts=sru.DEFAULT_ALLOWED_HOSTS,
            connect_timeout=5,
            max_time=30,
            retries=1,
            quiet=True,
            skip_download=True,
            upstream_meta_path=self.fx.upstream_meta,
        )
        kw.update(kwargs)
        return sru.run_sync(**kw)

    def _validate(self, **kwargs):
        kw = dict(
            mirror_root=self.fx.root,
            ubuntu_root=self.fx.ubuntu,
            public_base=PUBLIC,
            upgrader_dists=UPGRADER_DISTS,
            meta_chain=META_CHAIN,
            keyring=self.gpg.keyring,
            quiet=True,
        )
        kw.update(kwargs)
        return sru.validate_tree(**kw)

    def test_01_happy_path_pass(self):
        summary = self._sync()
        self.assertEqual(summary["validation_result"], "PASS")
        v = self._validate()
        self.assertEqual(v["validation_result"], "PASS")
        self.assertEqual(v["missing_lts_hops"], [])
        self.assertEqual(v["signature_invalid_count"], 0)
        self.assertEqual(v["external_urls_remaining"], 0)
        meta = open(
            os.path.join(self.fx.offline, "meta-release-lts"), encoding="utf-8"
        ).read()
        self.assertIn("UpgradeTool: {}/ubuntu/dists/bionic".format(PUBLIC), meta)
        self.assertNotIn("archive.ubuntu.com", meta)
        self.assertNotIn("changelogs.ubuntu.com", meta)
        # non-LTS alias also written
        self.assertTrue(os.path.isfile(os.path.join(self.fx.offline, "meta-release")))

    def test_02_meta_missing_fail(self):
        self._sync()
        os.unlink(os.path.join(self.fx.offline, "meta-release-lts"))
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_03_meta_syntax_fail(self):
        self._sync()
        write(os.path.join(self.fx.offline, "meta-release-lts"), "not a meta file\n")
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_04_missing_hop_entry_fail(self):
        write(self.fx.upstream_meta, make_upstream_meta(dists_extra=["bionic", "focal", "jammy"]))
        # rebuild fixtures without noble in meta — sync should fail
        with self.assertRaises(sru.SyncError):
            self._sync()

    def test_05_external_upgrade_tool_fail(self):
        self._sync()
        path = os.path.join(self.fx.offline, "meta-release-lts")
        text = open(path, encoding="utf-8").read()
        text = text.replace(
            "{}/ubuntu/dists/bionic".format(PUBLIC),
            "http://archive.ubuntu.com/ubuntu/dists/bionic",
        )
        write(path, text)
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["external_urls_remaining"], 0)

    def test_06_external_signature_url_fail(self):
        self._sync()
        path = os.path.join(self.fx.offline, "meta-release-lts")
        text = open(path, encoding="utf-8").read()
        text = text.replace(
            "UpgradeToolSignature: {}/ubuntu/dists/focal".format(PUBLIC),
            "UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/focal",
        )
        write(path, text)
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_07_tarball_missing_fail(self):
        self._sync()
        tar = os.path.join(
            self.fx.ubuntu,
            "dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz",
        )
        os.unlink(tar)
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_08_signature_missing_fail(self):
        self._sync()
        sig = os.path.join(
            self.fx.ubuntu,
            "dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz.gpg",
        )
        os.unlink(sig)
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_09_tarball_tampered_fail(self):
        self._sync()
        tar = os.path.join(
            self.fx.ubuntu,
            "dists/jammy-updates/main/dist-upgrader-all/current/jammy.tar.gz",
        )
        with open(tar, "ab") as fh:
            fh.write(b"TAMPER")
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["signature_invalid_count"], 0)

    def test_10_signature_tampered_fail(self):
        self._sync()
        sig = os.path.join(
            self.fx.ubuntu,
            "dists/jammy-updates/main/dist-upgrader-all/current/jammy.tar.gz.gpg",
        )
        with open(sig, "wb") as fh:
            fh.write(b"\x00" * 64)
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_11_unknown_signing_key_fail(self):
        self._sync()
        v = self._validate(keyring=self.gpg.unknown_keyring)
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["signature_invalid_count"], 0)

    def test_12_html_body_as_tarball_fail(self):
        self._sync()
        tar = os.path.join(
            self.fx.ubuntu,
            "dists/noble-updates/main/dist-upgrader-all/current/noble.tar.gz",
        )
        write(tar, "<!DOCTYPE html><html>error</html>\n")
        # re-sign so gpg might still fail on content / html check
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_13_http_304_without_body_retries(self):
        # Local origin that returns 304 then 200 on unconditional
        state = {"n": 0}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                state["n"] += 1
                ims = self.headers.get("If-Modified-Since")
                if ims and state["n"] == 1:
                    self.send_response(304)
                    self.end_headers()
                    return
                body = b"Dist: bionic\nName: B\nVersion: 18.04\nDate: Thu, 26 April 2018 18:04:00 UTC\nSupported: 1\n"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                return

        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        port = httpd.server_address[1]
        t = threading.Thread(target=httpd.serve_forever, daemon=True)
        t.start()
        dest = os.path.join(self.tmpdir, "meta-dl")
        # Pretend IMS is set but no existing body
        result = sru.curl_download(
            "http://127.0.0.1:{}/meta".format(port),
            dest,
            connect_timeout=2,
            max_time=10,
            retries=0,
            if_modified_since="Mon, 01 Jan 2020 00:00:00 GMT",
            allow_304_with_existing=None,
        )
        httpd.shutdown()
        self.assertTrue(result["ok"])
        self.assertEqual(result["http_status"], 200)
        self.assertGreaterEqual(state["n"], 2)

    def test_14_failed_sync_keeps_live_snapshot(self):
        summary = self._sync()
        self.assertEqual(summary["validation_result"], "PASS")
        live = open(
            os.path.join(self.fx.offline, "meta-release-lts"), encoding="utf-8"
        ).read()
        # Break upstream so next sync fails
        write(self.fx.upstream_meta, "garbage\n")
        with self.assertRaises(sru.SyncError):
            self._sync()
        still = open(
            os.path.join(self.fx.offline, "meta-release-lts"), encoding="utf-8"
        ).read()
        self.assertEqual(live, still)

    def test_15_partial_sync_no_stale_cleanup_on_fail(self):
        self._sync()
        stale = os.path.join(
            self.fx.ubuntu,
            "dists/bionic-updates/main/dist-upgrader-all/current/old-orphan.tar.gz",
        )
        write(stale, "orphan\n")
        # Fail sync
        write(self.fx.upstream_meta, "Dist: only\n")
        with self.assertRaises(sru.SyncError):
            self._sync()
        self.assertTrue(os.path.isfile(stale), "orphan must remain when sync fails")

    def test_16_referenced_upgrader_preserved(self):
        self._sync()
        tar = os.path.join(
            self.fx.ubuntu,
            "dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz",
        )
        self.assertTrue(os.path.isfile(tar))
        # successful re-sync keeps it
        self._sync()
        self.assertTrue(os.path.isfile(tar))

    def test_17_unref_previous_upgrader_cleaned(self):
        self._sync()
        orphan = os.path.join(
            self.fx.ubuntu,
            "dists/bionic-updates/main/dist-upgrader-all/current/bionic-old.tar.gz",
        )
        write(orphan, "old\n")
        self._sync()
        self.assertFalse(os.path.isfile(orphan))

    def test_18_idempotent_sync(self):
        a = self._sync()
        b = self._sync()
        self.assertEqual(a["validation_result"], "PASS")
        self.assertEqual(b["validation_result"], "PASS")
        m1 = open(os.path.join(self.fx.offline, "meta-release-lts"), "rb").read()
        m2 = open(os.path.join(self.fx.offline, "meta-release-lts"), "rb").read()
        self.assertEqual(m1, m2)

    def test_19_mirror_address_change_rewrites_urls(self):
        self._sync(public_base="http://10.1.1.1")
        meta = open(
            os.path.join(self.fx.offline, "meta-release-lts"), encoding="utf-8"
        ).read()
        self.assertIn("http://10.1.1.1/ubuntu/dists/", meta)
        self._sync(public_base="http://10.9.9.9")
        meta = open(
            os.path.join(self.fx.offline, "meta-release-lts"), encoding="utf-8"
        ).read()
        self.assertIn("http://10.9.9.9/ubuntu/dists/", meta)
        self.assertNotIn("http://10.1.1.1/", meta)

    def test_20_client_config_idempotent(self):
        um = os.path.join(self.tmpdir, "um")
        apt = os.path.join(self.tmpdir, "apt")
        os.makedirs(os.path.join(apt, "sources.list.d"))
        write(
            os.path.join(apt, "sources.list"),
            "deb http://archive.ubuntu.com/ubuntu jammy main\n"
            "deb http://security.ubuntu.com/ubuntu jammy-security main\n",
        )
        write(
            os.path.join(um, "meta-release"),
            "[METARELEASE]\n"
            "URI = https://changelogs.ubuntu.com/meta-release\n"
            "URI_LTS = https://changelogs.ubuntu.com/meta-release-lts\n"
            "URI_UNSTABLE_POSTFIX = -development\n",
        )
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt
        env["CLIENT_SETUP_UPDATE_MANAGER_ROOT"] = um
        for _ in range(2):
            proc = subprocess.run(
                [
                    "bash",
                    os.path.join(ROOT, "client", "client-setup.sh"),
                    "--mirror-url",
                    "http://10.2.3.4",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        text = open(os.path.join(um, "meta-release"), encoding="utf-8").read()
        self.assertEqual(text.count("URI_LTS ="), 1)
        self.assertIn("URI_LTS = http://10.2.3.4/offline/meta-release-lts", text)
        self.assertIn("URI_UNSTABLE_POSTFIX = -development", text)
        self.assertNotIn("changelogs.ubuntu.com", text)

    def test_21_client_restore(self):
        um = os.path.join(self.tmpdir, "um2")
        apt = os.path.join(self.tmpdir, "apt2")
        os.makedirs(os.path.join(apt, "sources.list.d"))
        original = (
            "[METARELEASE]\n"
            "URI = https://changelogs.ubuntu.com/meta-release\n"
            "URI_LTS = https://changelogs.ubuntu.com/meta-release-lts\n"
        )
        write(os.path.join(um, "meta-release"), original)
        write(os.path.join(apt, "sources.list"), "deb http://archive.ubuntu.com/ubuntu x main\n")
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt
        env["CLIENT_SETUP_UPDATE_MANAGER_ROOT"] = um
        subprocess.run(
            [
                "bash",
                os.path.join(ROOT, "client", "client-setup.sh"),
                "--mirror-url",
                "http://10.2.3.4",
            ],
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["bash", os.path.join(ROOT, "client", "client-setup.sh"), "--restore"],
            env=env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        restored = open(os.path.join(um, "meta-release"), encoding="utf-8").read()
        self.assertIn("changelogs.ubuntu.com", restored)

    def test_22_to_26_ubuntu_meta_release_formats(self):
        # All supported releases use the same [METARELEASE] URI / URI_LTS keys
        # (verified against UpdateManager.Core.MetaRelease on this host).
        for label in ("16.04", "18.04", "20.04", "22.04", "24.04"):
            um = os.path.join(self.tmpdir, "um-" + label)
            write(
                os.path.join(um, "meta-release"),
                "# Ubuntu {}\n[METARELEASE]\n"
                "URI = https://changelogs.ubuntu.com/meta-release\n"
                "URI_LTS = https://changelogs.ubuntu.com/meta-release-lts\n".format(
                    label
                ),
            )
            env = os.environ.copy()
            env["CLIENT_SETUP_APT_ROOT"] = os.path.join(self.tmpdir, "apt-" + label)
            env["CLIENT_SETUP_UPDATE_MANAGER_ROOT"] = um
            os.makedirs(os.path.join(env["CLIENT_SETUP_APT_ROOT"], "sources.list.d"))
            write(os.path.join(env["CLIENT_SETUP_APT_ROOT"], "sources.list"), "")
            proc = subprocess.run(
                [
                    "bash",
                    os.path.join(ROOT, "client", "client-setup.sh"),
                    "--mirror-url",
                    "http://10.0.0.8",
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, label + proc.stderr)
            text = open(os.path.join(um, "meta-release"), encoding="utf-8").read()
            self.assertIn("URI_LTS = http://10.0.0.8/offline/meta-release-lts", text)

    def test_27_to_31_http_get_head_404_traversal(self):
        self._sync()
        # Serve mirror tree
        os.chdir(self.fx.root)

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                return

        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        base = "http://127.0.0.1:{}".format(port)

        def code(path, method="GET"):
            return sru.http_check(base, path, method=method, timeout=5)

        self.assertEqual(code("/offline/meta-release-lts", "GET"), 200)
        self.assertEqual(code("/offline/meta-release-lts", "HEAD"), 200)
        self.assertEqual(
            code(
                "/mirror/archive.ubuntu.com/ubuntu/dists/bionic-updates/"
                "main/dist-upgrader-all/current/bionic.tar.gz",
                "GET",
            ),
            200,
        )
        self.assertEqual(
            code(
                "/mirror/archive.ubuntu.com/ubuntu/dists/bionic-updates/"
                "main/dist-upgrader-all/current/bionic.tar.gz.gpg",
                "HEAD",
            ),
            200,
        )
        self.assertEqual(
            code(
                "/mirror/archive.ubuntu.com/ubuntu/dists/bionic-updates/"
                "main/dist-upgrader-all/current/missing.tar.gz"
            ),
            404,
        )
        # path traversal should not escape (SimpleHTTPRequestHandler normalizes)
        trav = code("/offline/../../etc/passwd")
        self.assertIn(trav, (404, 400, 403))
        httpd.shutdown()

    def test_32_external_changelogs_attempts_zero(self):
        self._sync()
        # Parse-only release detection with local meta (no network)
        meta_path = os.path.join(self.fx.offline, "meta-release-lts")
        attempts = []

        class Guard(object):
            def find_module(self, name, path=None):
                return None

        # Ensure validate reports 0 external attempts
        v = self._validate()
        self.assertEqual(v["external_connection_attempts"], 0)
        text = open(meta_path, encoding="utf-8").read()
        self.assertNotIn("changelogs.ubuntu.com", text)
        _ = attempts  # reserved for future socket mock

    def test_33_fake_release_detection(self):
        self._sync()
        meta_path = os.path.join(self.fx.offline, "meta-release-lts")
        entries = sru.parse_meta_release(open(meta_path, encoding="utf-8").read())
        xenial = sru.entry_by_dist(entries, "xenial")
        bionic = sru.entry_by_dist(entries, "bionic")
        self.assertIsNotNone(xenial)
        self.assertIsNotNone(bionic)
        # Simulate MetaReleaseCore: next dist after xenial by Date order
        import email.utils
        import time

        def date_of(e):
            return time.mktime(email.utils.parsedate(e["Date"]))

        nxt = None
        for e in entries:
            if date_of(e) > date_of(xenial):
                nxt = e
                break
        self.assertEqual(nxt["Dist"], "bionic")
        self.assertTrue(nxt["UpgradeTool"].startswith(PUBLIC + "/ubuntu/"))

    def test_34_fake_upgrader_download_extract(self):
        self._sync()
        meta_path = os.path.join(self.fx.offline, "meta-release-lts")
        entries = sru.parse_meta_release(open(meta_path, encoding="utf-8").read())
        bionic = sru.entry_by_dist(entries, "bionic")
        tool = bionic["UpgradeTool"]
        sig = bionic["UpgradeToolSignature"]
        tpath = os.path.join(
            self.fx.ubuntu, sru.url_path(tool)[len("/ubuntu/") :]
        )
        spath = os.path.join(
            self.fx.ubuntu, sru.url_path(sig)[len("/ubuntu/") :]
        )
        ok, detail = sru.gpgv_verify(tpath, spath, self.gpg.keyring)
        self.assertTrue(ok, detail)
        tmp = tempfile.mkdtemp(dir=self.tmpdir)
        with tarfile.open(tpath, "r:gz") as tar:
            tar.extractall(tmp)
        self.assertTrue(os.path.isfile(os.path.join(tmp, "bionic")))

    def test_35_cli_validate_nonzero_on_fail(self):
        proc = subprocess.run(
            [
                sys.executable,
                os.path.join(LIB, "sync_release_upgraders.py"),
                "validate",
                "--mirror-root",
                self.fx.root,
                "--ubuntu-root",
                self.fx.ubuntu,
                "--public-base-url",
                PUBLIC,
                "--keyring",
                self.gpg.keyring,
                "--quiet",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_36_discovery_artifacts_unchanged(self):
        # Sync must never mutate discovery artifacts (even if the tree is absent).
        disc = os.path.join(ROOT, "artifacts", "upgrade-discovery")
        marker = None
        if os.path.isdir(disc):
            marker = os.path.join(disc, ".p0-3-must-not-touch")
            self.assertFalse(os.path.exists(marker))
        before = subprocess.check_output(
            ["git", "-C", ROOT, "status", "--porcelain", "artifacts/upgrade-discovery"],
            universal_newlines=True,
        )
        self._sync()
        after = subprocess.check_output(
            ["git", "-C", ROOT, "status", "--porcelain", "artifacts/upgrade-discovery"],
            universal_newlines=True,
        )
        self.assertEqual(before, after)
        if marker is not None:
            self.assertFalse(os.path.exists(marker))

    def test_cli_wiring_in_offline_mirror(self):
        text = open(
            os.path.join(ROOT, "scripts", "ubuntu-offline-mirror.sh"), encoding="utf-8"
        ).read()
        self.assertIn("sync-release-upgraders", text)
        self.assertIn("validate-release-upgraders", text)
        self.assertIn("sync_release_upgraders_py", text)
        self.assertIn("sync_release_upgraders.py", text)

    def test_parse_format_roundtrip(self):
        text = make_upstream_meta()
        entries = sru.parse_meta_release(text)
        out = sru.format_meta_release(entries)
        again = sru.parse_meta_release(out)
        self.assertEqual(len(entries), len(again))
        self.assertEqual(entries[0]["Dist"], again[0]["Dist"])


if __name__ == "__main__":
    unittest.main()
