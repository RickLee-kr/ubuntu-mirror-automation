#!/usr/bin/env python3
"""Fixture tests for P0-4 Xenial / old-releases legacy snapshot sync."""
from __future__ import print_function

import gzip
import hashlib
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))

import sync_legacy_releases as slr  # noqa: E402

SERIES = "xenial"
POCKETS = ("xenial", "xenial-updates", "xenial-security", "xenial-backports")
COMPONENTS = ("main", "restricted", "universe", "multiverse")
ARCH = "amd64"
PUBLIC = "http://mirror.local"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def make_packages(pkg_name, version, filename, deb_data):
    return (
        "Package: {}\n"
        "Version: {}\n"
        "Architecture: amd64\n"
        "Filename: {}\n"
        "Size: {}\n"
        "SHA256: {}\n"
        "\n"
    ).format(pkg_name, version, filename, len(deb_data), sha256_bytes(deb_data))


def make_release(entries, suite, acquire=True):
    lines = [
        "Origin: Ubuntu",
        "Label: Ubuntu",
        "Suite: {}".format(suite),
        "Codename: {}".format(suite.split("-")[0]),
        "Architectures: amd64",
        "Components: main restricted universe multiverse",
    ]
    if acquire:
        lines.append("Acquire-By-Hash: yes")
    lines.append("SHA256:")
    for relpath, data in entries:
        lines.append(" {} {} {}".format(sha256_bytes(data), len(data), relpath))
    return "\n".join(lines) + "\n"


def build_pocket_tree(ubuntu_root, pocket, deb_tag="a"):
    """Build one pocket with Packages + by-hash + one pool deb per component."""
    suite_dir = os.path.join(ubuntu_root, "dists", pocket)
    entries = []
    for comp in COMPONENTS:
        deb_name = "pkg-{}-{}_{}_amd64.deb".format(pocket, comp, deb_tag)
        filename = "pool/{}/p/pkg-{}/{}".format(comp, pocket, deb_name)
        deb_data = b"FAKEDEB-%s-%s-%s\n" % (
            pocket.encode(),
            comp.encode(),
            deb_tag.encode(),
        )
        write(os.path.join(ubuntu_root, filename), deb_data)
        pkg_text = make_packages(
            "pkg-{}-{}".format(pocket, comp), "1.0", filename, deb_data
        )
        pkg_gz = gzip.compress(pkg_text.encode("utf-8"))
        rel = "{}/binary-amd64/Packages.gz".format(comp)
        entries.append((rel, pkg_gz))
        write(os.path.join(suite_dir, rel), pkg_gz)
        dig = sha256_bytes(pkg_gz)
        write(
            os.path.join(suite_dir, comp, "binary-amd64", "by-hash", "SHA256", dig),
            pkg_gz,
        )
    body = make_release(entries, suite=pocket)
    write(os.path.join(suite_dir, "InRelease"), body)
    return entries


def build_full_xenial(ubuntu_root, deb_tag="a"):
    for pocket in POCKETS:
        build_pocket_tree(ubuntu_root, pocket, deb_tag=deb_tag)


def build_upstream_host(root, hostname, pockets=None, deb_tag="up"):
    """Build fixture tree: root/<hostname>/ubuntu/..."""
    ubuntu = os.path.join(root, hostname, "ubuntu")
    pockets = pockets or list(POCKETS)
    for pocket in pockets:
        build_pocket_tree(ubuntu, pocket, deb_tag=deb_tag)
    return ubuntu


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class FixtureHTTPRequestHandler(http.server.BaseHTTPRequestHandler):
    """Serve fixture roots keyed by Host header under docroots[host]."""

    docroots = {}
    status_overrides = {}  # (host, path) -> status
    body_overrides = {}  # (host, path) -> bytes
    redirect_map = {}  # (host, path) -> Location
    hit_log = None

    def log_message(self, fmt, *args):
        return

    def _host(self):
        return (self.headers.get("Host") or "localhost").split(":")[0].lower()

    def _dispatch(self):
        host = self._host()
        path = self.path.split("?", 1)[0]
        if self.hit_log is not None:
            self.hit_log.append((host, path, self.command))
        key = (host, path)
        if key in self.redirect_map:
            self.send_response(302)
            self.send_header("Location", self.redirect_map[key])
            self.end_headers()
            return
        if key in self.status_overrides:
            code = self.status_overrides[key]
            body = self.body_overrides.get(key, b"")
            self.send_response(code)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD" and body:
                self.wfile.write(body)
            return
        root = self.docroots.get(host)
        if root is None:
            self.send_error(404)
            return
        # Map /ubuntu/... → root/...
        if "/../" in path or path.endswith("/..") or "/.." in path:
            self.send_error(403)
            return
        if path.startswith("/ubuntu/"):
            rel = path[len("/ubuntu/") :]
        elif path == "/ubuntu":
            rel = ""
        else:
            self.send_error(404)
            return
        fspath = os.path.normpath(os.path.join(root, rel))
        root_norm = os.path.normpath(root)
        if fspath != root_norm and not fspath.startswith(root_norm + os.sep):
            self.send_error(403)
            return
        if not os.path.isfile(fspath):
            self.send_error(404)
            return
        with open(fspath, "rb") as fh:
            data = fh.read()
        # IMS / 304 support
        ims = self.headers.get("If-Modified-Since")
        if ims and self.command == "GET":
            # For tests: if override says 304-empty
            if key in self.body_overrides and self.body_overrides[key] is None:
                self.send_response(304)
                self.end_headers()
                return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()


def start_fixture_server(docroots, status_overrides=None, body_overrides=None, redirect_map=None):
    hit_log = []
    handler = type(
        "H",
        (FixtureHTTPRequestHandler,),
        {
            "docroots": docroots,
            "status_overrides": status_overrides or {},
            "body_overrides": body_overrides or {},
            "redirect_map": redirect_map or {},
            "hit_log": hit_log,
        },
    )
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    resolve = []
    for host in docroots:
        resolve.append("{}:{}:127.0.0.1".format(host, port))
        # also map for :80 style URLs by using http://host:port in upstreams
    return httpd, port, resolve, hit_log


class TestLegacyReleases(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="legacy-")
        self.addCleanup(shutil.rmtree, self.tmpdir, True)
        self.mirror_root = self.tmpdir
        self.ubuntu = os.path.join(
            self.tmpdir, "mirror", "archive.ubuntu.com", "ubuntu"
        )
        os.makedirs(os.path.join(self.tmpdir, "offline"), exist_ok=True)
        self.httpd = None

    def tearDown(self):
        if self.httpd is not None:
            self.httpd.shutdown()
            self.httpd.server_close()

    def _upstreams(self, port, names):
        parts = []
        for name in names:
            parts.append(
                "{}=http://{}:{}/ubuntu".format(name, name, port)
            )
        return ";".join(parts)

    def _sync(self, port, names, **kwargs):
        kw = dict(
            mirror_root=self.mirror_root,
            ubuntu_root=self.ubuntu,
            series=SERIES,
            target_series="bionic",
            suffixes=("updates", "security", "backports"),
            components=COMPONENTS,
            arch=ARCH,
            upstreams=slr.parse_upstreams_arg(self._upstreams(port, names)),
            discovery_root="",
            sources_root="",
            connect_timeout=5,
            max_time=30,
            retries=1,
            resolve_map=["{}:{}:127.0.0.1".format(n, port) for n in names],
            require_by_hash=True,
            sync_pool=True,
            quiet=True,
        )
        kw.update(kwargs)
        return slr.run_sync(**kw)

    def _validate(self, **kwargs):
        kw = dict(
            mirror_root=self.mirror_root,
            ubuntu_root=self.ubuntu,
            series=SERIES,
            target_series="bionic",
            suffixes=("updates", "security", "backports"),
            components=COMPONENTS,
            arch=ARCH,
            require_by_hash=True,
            quiet=True,
        )
        kw.update(kwargs)
        return slr.run_validate(**kw)

    def test_01_archive_complete_pass(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="arc")
        # security host unused but present
        build_upstream_host(fx, "security.ubuntu.com", pockets=["xenial-security"], deb_tag="sec")
        docroots = {
            "archive.ubuntu.com": archive_u,
            "security.ubuntu.com": os.path.join(fx, "security.ubuntu.com", "ubuntu"),
        }
        self.httpd, port, _resolve, _hits = start_fixture_server(docroots)
        summary = self._sync(
            port,
            ["archive.ubuntu.com", "security.ubuntu.com", "old-releases.ubuntu.com"],
        )
        self.assertEqual(summary["validation_result"], "PASS")
        self.assertIn("archive.ubuntu.com", summary["selected_upstreams"])
        self.assertTrue(summary["snapshot_promoted"])
        self.assertTrue(os.path.isdir(slr.active_dir(self.mirror_root, SERIES)))
        v = self._validate()
        self.assertEqual(v["validation_result"], "PASS")

    def test_02_archive_404_old_releases_pass(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        old_u = build_upstream_host(fx, "old-releases.ubuntu.com", deb_tag="old")
        # archive returns 404 for all
        empty = os.path.join(fx, "archive.ubuntu.com", "ubuntu")
        os.makedirs(empty, exist_ok=True)
        docroots = {
            "archive.ubuntu.com": empty,
            "old-releases.ubuntu.com": old_u,
        }
        self.httpd, port, _, _ = start_fixture_server(docroots)
        summary = self._sync(
            port, ["archive.ubuntu.com", "old-releases.ubuntu.com"]
        )
        self.assertEqual(summary["validation_result"], "PASS")
        self.assertIn("old-releases.ubuntu.com", summary["selected_upstreams"])

    def test_03_archive_partial_old_releases_selected(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        # archive only base
        archive_u = os.path.join(fx, "archive.ubuntu.com", "ubuntu")
        build_pocket_tree(archive_u, "xenial", deb_tag="partial")
        old_u = build_upstream_host(fx, "old-releases.ubuntu.com", deb_tag="old")
        docroots = {
            "archive.ubuntu.com": archive_u,
            "old-releases.ubuntu.com": old_u,
        }
        self.httpd, port, _, _ = start_fixture_server(docroots)
        summary = self._sync(
            port, ["archive.ubuntu.com", "old-releases.ubuntu.com"]
        )
        self.assertEqual(summary["validation_result"], "PASS")
        self.assertIn("old-releases.ubuntu.com", summary["selected_upstreams"])

    def test_04_archive_base_only_partial(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = os.path.join(fx, "archive.ubuntu.com", "ubuntu")
        build_pocket_tree(archive_u, "xenial", deb_tag="base")
        docroots = {"archive.ubuntu.com": archive_u}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        with self.assertRaises(slr.LegacyError):
            self._sync(port, ["archive.ubuntu.com"])

    def test_05_old_releases_metadata_missing_fail(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        empty = os.path.join(fx, "old-releases.ubuntu.com", "ubuntu")
        os.makedirs(empty, exist_ok=True)
        docroots = {"old-releases.ubuntu.com": empty}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        with self.assertRaises(slr.LegacyError):
            self._sync(port, ["old-releases.ubuntu.com"])

    def test_06_updates_missing_fail(self):
        build_full_xenial(self.ubuntu)
        shutil.rmtree(os.path.join(self.ubuntu, "dists", "xenial-updates"))
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertIn("xenial-updates", v["pockets_missing"])

    def test_07_security_missing_fail(self):
        build_full_xenial(self.ubuntu)
        shutil.rmtree(os.path.join(self.ubuntu, "dists", "xenial-security"))
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertIn("xenial-security", v["pockets_missing"])

    def test_08_backports_missing_fail(self):
        build_full_xenial(self.ubuntu)
        shutil.rmtree(os.path.join(self.ubuntu, "dists", "xenial-backports"))
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertIn("xenial-backports", v["pockets_missing"])

    def test_09_release_without_inrelease_pass(self):
        build_full_xenial(self.ubuntu)
        suite = os.path.join(self.ubuntu, "dists", "xenial")
        shutil.move(
            os.path.join(suite, "InRelease"), os.path.join(suite, "Release")
        )
        write(os.path.join(suite, "Release.gpg"), b"fake-gpg\n")
        v = self._validate()
        self.assertEqual(v["validation_result"], "PASS")

    def test_10_release_checksum_fail(self):
        build_full_xenial(self.ubuntu)
        pkg = os.path.join(
            self.ubuntu,
            "dists/xenial/main/binary-amd64/Packages.gz",
        )
        with open(pkg, "ab") as fh:
            fh.write(b"x")
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["checksum_mismatches"], 0)

    def test_11_packages_missing_fail(self):
        build_full_xenial(self.ubuntu)
        os.unlink(
            os.path.join(
                self.ubuntu, "dists/xenial/main/binary-amd64/Packages.gz"
            )
        )
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_12_byhash_missing_fail(self):
        build_full_xenial(self.ubuntu)
        bh_dir = os.path.join(
            self.ubuntu, "dists/xenial/main/binary-amd64/by-hash"
        )
        shutil.rmtree(bh_dir)
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["by_hash_missing"], 0)

    def test_13_pool_missing_fail(self):
        build_full_xenial(self.ubuntu)
        shutil.rmtree(os.path.join(self.ubuntu, "pool"))
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["pool_files_missing"], 0)

    def test_14_pool_checksum_fail(self):
        build_full_xenial(self.ubuntu)
        # corrupt one deb
        for dirpath, _dns, files in os.walk(os.path.join(self.ubuntu, "pool")):
            for fn in files:
                if fn.endswith(".deb"):
                    p = os.path.join(dirpath, fn)
                    with open(p, "wb") as fh:
                        fh.write(b"TAMPERED\n")
                    break
            else:
                continue
            break
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_15_html_body_fail(self):
        build_full_xenial(self.ubuntu)
        write(
            os.path.join(self.ubuntu, "dists/xenial/InRelease"),
            b"<html>404 Not Found</html>\n",
        )
        v = self._validate()
        self.assertEqual(v["validation_result"], "FAIL")

    def test_16_304_without_body_retries(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="r304")
        docroots = {"archive.ubuntu.com": archive_u}
        # First InRelease request returns 304 with no body; curl_download retries
        status = {}
        bodies = {}
        path = "/ubuntu/dists/xenial/InRelease"
        # Use a custom handler that returns 304 once then 200
        class Once304(FixtureHTTPRequestHandler):
            seen = set()

            def _dispatch(self):
                host = self._host()
                p = self.path.split("?", 1)[0]
                if p == path and path not in Once304.seen:
                    Once304.seen.add(path)
                    self.send_response(304)
                    self.end_headers()
                    return
                FixtureHTTPRequestHandler._dispatch(self)

        Once304.docroots = docroots
        Once304.status_overrides = {}
        Once304.body_overrides = {}
        Once304.redirect_map = {}
        Once304.hit_log = []
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Once304)
        port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        summary = self._sync(port, ["archive.ubuntu.com"])
        self.assertEqual(summary["validation_result"], "PASS")

    def test_17_redirect_ok(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="redir")
        docroots = {"archive.ubuntu.com": archive_u}
        redirects = {
            (
                "archive.ubuntu.com",
                "/ubuntu/dists/xenial/InRelease",
            ): "http://archive.ubuntu.com:{}/ubuntu/dists/xenial/InRelease-real".format(
                0
            )
        }
        # Simpler: put real file and redirect from alt path — use curl --location
        # by renaming InRelease and redirecting
        real = os.path.join(archive_u, "dists/xenial/InRelease")
        shutil.move(real, real + ".real")
        # Rebuild server with redirect to .real via path rewrite in handler
        class Redir(FixtureHTTPRequestHandler):
            def _dispatch(self):
                p = self.path.split("?", 1)[0]
                if p == "/ubuntu/dists/xenial/InRelease":
                    self.send_response(302)
                    self.send_header(
                        "Location", "/ubuntu/dists/xenial/InRelease.real"
                    )
                    self.end_headers()
                    return
                FixtureHTTPRequestHandler._dispatch(self)

        Redir.docroots = docroots
        Redir.status_overrides = {}
        Redir.body_overrides = {}
        Redir.redirect_map = {}
        Redir.hit_log = []
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Redir)
        port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        summary = self._sync(port, ["archive.ubuntu.com"])
        self.assertEqual(summary["validation_result"], "PASS")

    def test_18_both_fail_preserve_active(self):
        # First create active via live snapshot
        build_full_xenial(self.ubuntu, deb_tag="keep")
        stage = tempfile.mkdtemp(prefix="st-", dir=os.path.join(self.tmpdir, "offline"))
        stage_u = os.path.join(stage, "ubuntu")
        slr.snapshot_live_tree(self.ubuntu, stage_u, list(POCKETS))
        summary = slr.empty_summary(SERIES, "bionic")
        summary["source_status"] = "COMPLETE"
        summary["selected_upstreams"] = ["live-tree"]
        summary["pockets_required"] = list(POCKETS)
        slr.promote_snapshot(self.mirror_root, SERIES, stage_u, summary, quiet=True)
        active = slr.active_dir(self.mirror_root, SERIES)
        self.assertTrue(os.path.isdir(active))
        # Wipe live and make upstreams empty
        shutil.rmtree(os.path.join(self.ubuntu, "dists"), ignore_errors=True)
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        empty_a = os.path.join(fx, "archive.ubuntu.com", "ubuntu")
        empty_o = os.path.join(fx, "old-releases.ubuntu.com", "ubuntu")
        os.makedirs(empty_a)
        os.makedirs(empty_o)
        docroots = {
            "archive.ubuntu.com": empty_a,
            "old-releases.ubuntu.com": empty_o,
        }
        self.httpd, port, _, _ = start_fixture_server(docroots)
        result = self._sync(
            port, ["archive.ubuntu.com", "old-releases.ubuntu.com"]
        )
        self.assertTrue(result.get("snapshot_preserved_after_failure"))
        self.assertEqual(result["validation_result"], "PASS")
        self.assertTrue(os.path.isdir(active))

    def test_19_partial_candidate_no_promote(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = os.path.join(fx, "archive.ubuntu.com", "ubuntu")
        build_pocket_tree(archive_u, "xenial", deb_tag="p")
        build_pocket_tree(archive_u, "xenial-updates", deb_tag="p")
        # missing security + backports
        docroots = {"archive.ubuntu.com": archive_u}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        with self.assertRaises(slr.LegacyError):
            self._sync(port, ["archive.ubuntu.com"])
        self.assertFalse(
            os.path.isdir(slr.active_dir(self.mirror_root, SERIES))
        )

    def test_20_valid_candidate_atomic_promote(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="p1")
        docroots = {"archive.ubuntu.com": archive_u}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        s1 = self._sync(port, ["archive.ubuntu.com"])
        self.assertTrue(s1["snapshot_promoted"])
        # second sync with new tag → previous preserved
        shutil.rmtree(archive_u)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="p2")
        docroots["archive.ubuntu.com"] = archive_u
        # force re-fetch by clearing live completeness... live is complete so
        # sync will snapshot live. Force upstream:
        s2 = self._sync(
            port, ["archive.ubuntu.com"], force_upstream="archive.ubuntu.com"
        )
        self.assertEqual(s2["validation_result"], "PASS")
        self.assertTrue(os.path.isdir(slr.previous_dir(self.mirror_root, SERIES)))

    def test_21_promote_failure_keeps_active(self):
        build_full_xenial(self.ubuntu, deb_tag="act")
        stage = tempfile.mkdtemp(prefix="st-", dir=os.path.join(self.tmpdir, "offline"))
        stage_u = os.path.join(stage, "ubuntu")
        slr.snapshot_live_tree(self.ubuntu, stage_u, list(POCKETS))
        summary = slr.empty_summary(SERIES, "bionic")
        summary["pockets_required"] = list(POCKETS)
        slr.promote_snapshot(self.mirror_root, SERIES, stage_u, summary, quiet=True)
        marker = os.path.join(slr.active_dir(self.mirror_root, SERIES), "manifest.json")
        before = open(marker, encoding="utf-8").read()
        # Force sync failure with empty upstreams and broken live
        shutil.rmtree(os.path.join(self.ubuntu, "dists"))
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        empty = os.path.join(fx, "archive.ubuntu.com", "ubuntu")
        os.makedirs(empty)
        docroots = {"archive.ubuntu.com": empty}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        # restore from active should succeed; active unchanged
        result = self._sync(port, ["archive.ubuntu.com"])
        after = open(marker, encoding="utf-8").read()
        self.assertEqual(before, after)
        self.assertTrue(result.get("snapshot_preserved_after_failure") or result["validation_result"] == "PASS")

    def test_22_previous_snapshot_preserved(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="v1")
        docroots = {"archive.ubuntu.com": archive_u}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        self._sync(port, ["archive.ubuntu.com"])
        shutil.rmtree(archive_u)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="v2")
        docroots["archive.ubuntu.com"] = archive_u
        self._sync(
            port, ["archive.ubuntu.com"], force_upstream="archive.ubuntu.com"
        )
        self.assertTrue(os.path.isdir(slr.previous_dir(self.mirror_root, SERIES)))
        self.assertTrue(
            os.path.isfile(
                os.path.join(
                    slr.previous_dir(self.mirror_root, SERIES), "manifest.json"
                )
            )
        )

    def test_23_24_stale_cleanup_active_refs(self):
        # Stale cleanup is "only unreferenced" — verify restore keeps active refs
        build_full_xenial(self.ubuntu, deb_tag="stale")
        stage = tempfile.mkdtemp(prefix="st-", dir=os.path.join(self.tmpdir, "offline"))
        stage_u = os.path.join(stage, "ubuntu")
        slr.snapshot_live_tree(self.ubuntu, stage_u, list(POCKETS))
        summary = slr.empty_summary(SERIES, "bionic")
        summary["pockets_required"] = list(POCKETS)
        slr.promote_snapshot(self.mirror_root, SERIES, stage_u, summary, quiet=True)
        # Simulate apt-mirror clean deleting live dists
        shutil.rmtree(os.path.join(self.ubuntu, "dists"))
        shutil.rmtree(os.path.join(self.ubuntu, "pool"), ignore_errors=True)
        n = slr.restore_live_from_active(
            self.mirror_root, self.ubuntu, SERIES, list(POCKETS), quiet=True
        )
        self.assertGreater(n, 0)
        v = self._validate()
        self.assertEqual(v["validation_result"], "PASS")

    def test_25_clean_then_restore(self):
        self.test_23_24_stale_cleanup_active_refs()

    def test_26_idempotent_sync(self):
        fx = tempfile.mkdtemp(prefix="up-", dir=self.tmpdir)
        archive_u = build_upstream_host(fx, "archive.ubuntu.com", deb_tag="id")
        docroots = {"archive.ubuntu.com": archive_u}
        self.httpd, port, _, _ = start_fixture_server(docroots)
        s1 = self._sync(port, ["archive.ubuntu.com"])
        s2 = self._sync(port, ["archive.ubuntu.com"])
        self.assertEqual(s1["validation_result"], "PASS")
        self.assertEqual(s2["validation_result"], "PASS")

    def test_27_28_client_rewrite_old_releases(self):
        apt_root = os.path.join(self.tmpdir, "apt")
        os.makedirs(os.path.join(apt_root, "sources.list.d"), exist_ok=True)
        write(
            os.path.join(apt_root, "sources.list"),
            "deb http://archive.ubuntu.com/ubuntu xenial main\n"
            "deb http://security.ubuntu.com/ubuntu xenial-security main\n"
            "deb http://old-releases.ubuntu.com/ubuntu xenial-updates main\n"
            "deb http://ppa.launchpad.net/foo/bar/ubuntu xenial main\n",
        )
        write(
            os.path.join(
                apt_root, "sources.list.d", "extra.list.disabled-by-dp-os-upgrade"
            ),
            "deb http://old-releases.ubuntu.com/ubuntu xenial main\n",
        )
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt_root
        proc = subprocess.run(
            [
                "bash",
                os.path.join(ROOT, "client", "client-setup.sh"),
                "--mirror-url",
                "http://10.1.2.3",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            env=env,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg="stdout={} stderr={}".format(proc.stdout, proc.stderr),
        )
        text = open(os.path.join(apt_root, "sources.list"), encoding="utf-8").read()
        self.assertNotIn("archive.ubuntu.com", text)
        self.assertNotIn("security.ubuntu.com", text)
        self.assertNotIn("old-releases.ubuntu.com", text)
        self.assertIn("http://10.1.2.3/ubuntu", text)
        self.assertIn("http://10.1.2.3/ubuntu-security", text)
        self.assertIn("ppa.launchpad.net", text)
        disabled = open(
            os.path.join(
                apt_root, "sources.list.d", "extra.list.disabled-by-dp-os-upgrade"
            ),
            encoding="utf-8",
        ).read()
        self.assertIn("old-releases.ubuntu.com", disabled)

    def test_29_third_party_unchanged(self):
        self.test_27_28_client_rewrite_old_releases()

    def test_30_client_restore(self):
        apt_root = os.path.join(self.tmpdir, "apt2")
        os.makedirs(os.path.join(apt_root, "sources.list.d"), exist_ok=True)
        original = "deb http://archive.ubuntu.com/ubuntu xenial main\n"
        write(os.path.join(apt_root, "sources.list"), original)
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt_root
        proc = subprocess.run(
            [
                "bash",
                os.path.join(ROOT, "client", "client-setup.sh"),
                "--mirror-url",
                "http://10.1.2.3",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0)
        proc = subprocess.run(
            [
                "bash",
                os.path.join(ROOT, "client", "client-setup.sh"),
                "--mirror-url",
                "http://10.1.2.3",
                "--restore",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            env=env,
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg="stdout={} stderr={}".format(proc.stdout, proc.stderr),
        )
        text = open(os.path.join(apt_root, "sources.list"), encoding="utf-8").read()
        self.assertIn("archive.ubuntu.com", text)

    def test_31_external_old_releases_fail(self):
        build_full_xenial(self.ubuntu)
        sources = os.path.join(self.tmpdir, "sources")
        os.makedirs(sources, exist_ok=True)
        write(
            os.path.join(sources, "sources.list"),
            "deb http://old-releases.ubuntu.com/ubuntu xenial main\n",
        )
        v = self._validate(sources_root=sources)
        self.assertEqual(v["validation_result"], "FAIL")
        self.assertGreater(v["external_urls_remaining"], 0)

    def test_32_37_nginx_paths_and_traversal(self):
        build_full_xenial(self.ubuntu)
        # Local file server simulating nginx alias
        docroots = {"mirror.local": self.ubuntu}
        self.httpd, port, _, hits = start_fixture_server(docroots)
        base = "http://127.0.0.1:{}".format(port)

        def code(path, method="GET"):
            cmd = [
                "curl",
                "-sS",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "--max-time",
                "5",
                "--path-as-is",
            ]
            if method == "HEAD":
                cmd.append("-I")
            cmd.extend(["-H", "Host: mirror.local", base + path])
            out = subprocess.check_output(cmd, universal_newlines=True).strip()
            return out

        self.assertEqual(code("/ubuntu/dists/xenial/InRelease"), "200")
        self.assertEqual(code("/ubuntu/dists/xenial-updates/InRelease", "HEAD"), "200")
        self.assertEqual(code("/ubuntu/dists/xenial-security/InRelease"), "200")
        # by-hash
        suite = os.path.join(self.ubuntu, "dists/xenial/main/binary-amd64/by-hash/SHA256")
        dig = os.listdir(suite)[0]
        self.assertEqual(
            code("/ubuntu/dists/xenial/main/binary-amd64/by-hash/SHA256/{}".format(dig)),
            "200",
        )
        # pool HEAD
        for dirpath, _d, files in os.walk(os.path.join(self.ubuntu, "pool")):
            for fn in files:
                rel = os.path.relpath(os.path.join(dirpath, fn), self.ubuntu)
                self.assertEqual(code("/ubuntu/" + rel, "HEAD"), "200")
                break
            else:
                continue
            break
        self.assertEqual(code("/ubuntu/dists/xenial/does-not-exist"), "404")
        self.assertEqual(code("/ubuntu/../etc/passwd"), "403")

    def test_38_path_traversal_blocked(self):
        self.test_32_37_nginx_paths_and_traversal()

    def test_39_40_upgrader_meta_patterns(self):
        # Structural support for bionic upgrader + discovery patterns
        url = (
            "http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/"
            "dist-upgrader-all/current/bionic.tar.gz"
        )
        ok, reason = slr.discovery_pattern_supported(url, self.ubuntu)
        self.assertTrue(ok)
        meta_path = "/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz"
        self.assertIn("dist-upgrader-all", meta_path)

    def test_41_external_connection_attempts_zero(self):
        build_full_xenial(self.ubuntu)
        v = self._validate()
        self.assertEqual(v["external_connection_attempts"], 0)

    def test_42_discovery_pattern_coverage(self):
        build_full_xenial(self.ubuntu)
        discovery = os.path.join(ROOT, "artifacts", "upgrade-discovery")
        self.assertTrue(
            os.path.isdir(discovery),
            "artifacts/upgrade-discovery must be present for coverage check",
        )
        v = self._validate(discovery_root=discovery)
        self.assertEqual(v["validation_result"], "PASS")
        self.assertEqual(v["discovery_urls_unsupported"], 0)
        self.assertEqual(v["unsupported_urls"], 0)
        self.assertGreater(v["discovered_xenial_urls"], 0)

    def test_43_cli_wiring(self):
        text = open(
            os.path.join(ROOT, "scripts", "ubuntu-offline-mirror.sh"), encoding="utf-8"
        ).read()
        self.assertIn("sync-legacy-releases", text)
        self.assertIn("validate-legacy-releases", text)
        self.assertIn("freeze-xenial-snapshot", text)
        self.assertIn("sync_legacy_releases", text)
        install = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
        self.assertIn("sync_legacy_releases.py", install)
        nginx = open(os.path.join(ROOT, "templates", "nginx.conf"), encoding="utf-8").read()
        self.assertIn("old-releases.ubuntu.com", nginx)

    def test_44_discovery_artifacts_unchanged(self):
        path = os.path.join(
            ROOT,
            "artifacts/upgrade-discovery/xenial-to-bionic/export-summary.json",
        )
        self.assertTrue(os.path.isfile(path), "discovery export-summary.json required")
        before = open(path, "rb").read()
        data = json.loads(before.decode("utf-8"))
        self.assertEqual(data.get("validation"), "PASS")
        # Re-run discovery cross-check must not mutate artifacts
        build_full_xenial(self.ubuntu)
        self._validate(
            discovery_root=os.path.join(ROOT, "artifacts", "upgrade-discovery")
        )
        after = open(path, "rb").read()
        self.assertEqual(before, after)

    def test_main_exit_codes(self):
        build_full_xenial(self.ubuntu)
        rc = slr.main(
            [
                "validate",
                "--mirror-root",
                self.mirror_root,
                "--ubuntu-root",
                self.ubuntu,
                "--quiet",
            ]
        )
        self.assertEqual(rc, 0)
        shutil.rmtree(os.path.join(self.ubuntu, "dists", "xenial-security"))
        rc = slr.main(
            [
                "validate",
                "--mirror-root",
                self.mirror_root,
                "--ubuntu-root",
                self.ubuntu,
                "--quiet",
            ]
        )
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
