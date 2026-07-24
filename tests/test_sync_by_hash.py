#!/usr/bin/env python3
"""Fixture tests for supplemental by-hash sync / validate / cleanup."""
from __future__ import print_function

import gzip
import hashlib
import io
import lzma
import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))

import sync_by_hash as sbh  # noqa: E402


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def make_release(entries, acquire=True, extra_headers=None):
    """Build a minimal InRelease-like Release body with SHA256 section."""
    lines = [
        "Origin: Ubuntu",
        "Label: Ubuntu",
        "Suite: jammy",
        "Codename: jammy",
        "Architectures: amd64",
        "Components: main",
    ]
    if extra_headers:
        lines.extend(extra_headers)
    if acquire:
        lines.append("Acquire-By-Hash: yes")
    lines.append("SHA256:")
    for relpath, data in entries:
        digest = sha256_bytes(data)
        lines.append(" {} {} {}".format(digest, len(data), relpath))
    return "\n".join(lines) + "\n", {
        relpath: (sha256_bytes(data), data) for relpath, data in entries
    }


def build_repo(tmpdir, host="archive.ubuntu.com", suite="jammy", entries=None, acquire=True):
    ubuntu = os.path.join(tmpdir, "mirror", host, "ubuntu")
    suite_dir = os.path.join(ubuntu, "dists", suite)
    os.makedirs(suite_dir, exist_ok=True)
    if entries is None:
        pkg = b"Package: foo\nVersion: 1\n"
        pkg_xz = lzma.compress(pkg)
        pkg_gz = gzip.compress(pkg)
        i18n = b"Fake translation\n"
        cnf = lzma.compress(b"name: foo\n")
        entries = [
            ("main/binary-amd64/Packages", pkg),
            ("main/binary-amd64/Packages.gz", pkg_gz),
            ("main/binary-amd64/Packages.xz", pkg_xz),
            ("main/i18n/Translation-en", i18n),
            ("main/cnf/Commands-amd64.xz", cnf),
        ]
    body, meta = make_release(entries, acquire=acquire)
    write(os.path.join(suite_dir, "InRelease"), body)
    for relpath, data in entries:
        write(os.path.join(suite_dir, relpath), data)
    return {
        "mirror_root": tmpdir,
        "ubuntu_root": ubuntu,
        "suite_dir": suite_dir,
        "suite": suite,
        "meta": meta,
        "entries": entries,
    }


class FakeDownloader(object):
    def __init__(self):
        self.calls = []
        self.bodies = {}  # url -> bytes or ('status', code)
        self.fail_once = {}

    def __call__(self, url, dest_tmp, timeouts, log, conditional=False):
        self.calls.append((url, conditional))
        if url in self.fail_once:
            action = self.fail_once.pop(url)
            if action == "304":
                return False, "304", "not_modified_no_body"
            if action == "fail":
                return False, "500", "http_500"
        body = self.bodies.get(url)
        if body is None:
            return False, "404", "http_404"
        if isinstance(body, tuple) and body[0] == "status":
            return False, str(body[1]), "http_{}".format(body[1])
        with open(dest_tmp, "wb") as fh:
            fh.write(body)
        return True, "200", "ok"


class TestByHash(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="byhash-test-")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _validate(self, repo, incomplete=False):
        argv = [
            "validate",
            "--mirror-root",
            repo["mirror_root"],
            "--ubuntu-root",
            repo["ubuntu_root"],
            "--quiet",
        ]
        if incomplete:
            argv.append("--incomplete")
        return sbh.main(argv)

    def _sync_validate(self, repo, downloader=None, incomplete=False):
        # Monkeypatch curl_download when downloader provided via ensure path
        old = sbh.curl_download
        if downloader is not None:
            sbh.curl_download = downloader
        try:
            argv = [
                "sync-validate",
                "--mirror-root",
                repo["mirror_root"],
                "--ubuntu-root",
                repo["ubuntu_root"],
                "--upstream-base-url",
                "http://archive.ubuntu.com/ubuntu",
                "--quiet",
            ]
            if incomplete:
                argv.append("--incomplete")
            return sbh.main(argv)
        finally:
            sbh.curl_download = old

    def test_01_acquire_yes_present_pass(self):
        repo = build_repo(self.tmpdir)
        rc = self._sync_validate(repo)
        self.assertEqual(rc, 0)
        # by-hash for Packages.xz exists
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        path = os.path.join(
            repo["suite_dir"],
            "main/binary-amd64/by-hash/SHA256",
            digest,
        )
        self.assertTrue(os.path.isfile(path))
        self.assertEqual(self._validate(repo), 0)

    def test_02_missing_by_hash_fail(self):
        repo = build_repo(self.tmpdir)
        # sync would create — validate without sync should fail
        rc = self._validate(repo)
        self.assertEqual(rc, 1)

    def test_03_digest_mismatch_fail(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        path = os.path.join(
            repo["suite_dir"], "main/binary-amd64/by-hash/SHA256", digest
        )
        write(path, b"tampered-content-not-matching-digest")
        self.assertEqual(self._validate(repo), 1)

    def test_04_named_vs_byhash_mismatch_fail(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        named = os.path.join(repo["suite_dir"], "main/binary-amd64/Packages.xz")
        write(named, b"different-named-index-content!!!!")
        self.assertEqual(self._validate(repo), 1)

    def test_05_304_then_unconditional_retry(self):
        repo = build_repo(self.tmpdir)
        named = os.path.join(repo["suite_dir"], "main/binary-amd64/Packages.xz")
        data = open(named, "rb").read()
        digest = sha256_bytes(data)
        # Stale named forces download path (by-hash required only when named exists)
        write(named, b"stale-named-not-matching-release-hash!!!!!")
        url = (
            "http://archive.ubuntu.com/ubuntu/dists/jammy/"
            "main/binary-amd64/by-hash/SHA256/{}".format(digest)
        )
        fd = FakeDownloader()
        fd.fail_once[url] = "304"
        fd.bodies[url] = data
        rc = self._sync_validate(repo, downloader=fd)
        self.assertEqual(rc, 0)
        urls = [c[0] for c in fd.calls]
        self.assertIn(url, urls)
        self.assertGreaterEqual(urls.count(url), 2)
        path = os.path.join(
            repo["suite_dir"], "main/binary-amd64/by-hash/SHA256", digest
        )
        self.assertTrue(os.path.isfile(path))
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), data)
        with open(named, "rb") as fh:
            self.assertEqual(fh.read(), data)

    def test_06_download_fail_keeps_existing(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        path = os.path.join(
            repo["suite_dir"], "main/binary-amd64/by-hash/SHA256", digest
        )
        original = open(path, "rb").read()
        url = (
            "http://archive.ubuntu.com/ubuntu/dists/jammy/"
            "main/binary-amd64/by-hash/SHA256/{}".format(digest)
        )
        fd = FakeDownloader()
        fd.bodies[url] = ("status", 500)
        item = {
            "algo": "SHA256",
            "hash": digest,
            "size": len(original),
            "path": "main/binary-amd64/Packages.xz",
            "by_hash_path": path,
            "named_path": os.path.join(
                repo["suite_dir"], "main/binary-amd64/Packages.xz"
            ),
            "acquire_by_hash": True,
        }
        # Explicit download failure must not destroy the existing good object
        ok, reason = sbh.download_by_hash(
            item,
            "http://archive.ubuntu.com/ubuntu",
            "jammy",
            (5, 30, 1),
            lambda m: None,
            downloader=fd,
        )
        self.assertTrue(ok)
        self.assertIn("kept_existing", reason)
        with open(path, "rb") as fh:
            self.assertEqual(fh.read(), original)

    def test_07_partial_sync_skips_cleanup(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        stale = os.path.join(
            repo["suite_dir"],
            "main/binary-amd64/by-hash/SHA256",
            "0" * 64,
        )
        write(stale, b"stale-old-byhash")
        rc = sbh.main(
            [
                "cleanup",
                "--mirror-root",
                repo["mirror_root"],
                "--ubuntu-root",
                repo["ubuntu_root"],
                "--incomplete",
                "--quiet",
            ]
        )
        self.assertEqual(rc, 1)  # incomplete => FAIL
        self.assertTrue(os.path.isfile(stale))

    def test_08_referenced_preserved(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        path = os.path.join(
            repo["suite_dir"], "main/binary-amd64/by-hash/SHA256", digest
        )
        self.assertTrue(os.path.isfile(path))
        # Run cleanup via sync-validate again
        self.assertEqual(self._sync_validate(repo), 0)
        self.assertTrue(os.path.isfile(path))

    def test_09_stale_only_removed(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        good = os.path.join(
            repo["suite_dir"], "main/binary-amd64/by-hash/SHA256", digest
        )
        stale = os.path.join(
            repo["suite_dir"],
            "main/binary-amd64/by-hash/SHA256",
            "a" * 64,
        )
        write(stale, b"old")
        self.assertEqual(self._sync_validate(repo), 0)
        self.assertTrue(os.path.isfile(good))
        self.assertFalse(os.path.isfile(stale))

    def test_10_idempotent_no_redownload(self):
        repo = build_repo(self.tmpdir)
        fd = FakeDownloader()
        self.assertEqual(self._sync_validate(repo, downloader=fd), 0)
        calls1 = len(fd.calls)
        self.assertEqual(self._sync_validate(repo, downloader=fd), 0)
        # No additional downloads when hardlink path used
        self.assertEqual(len(fd.calls), calls1)

    def test_11_archive_and_security_layouts(self):
        # archive tree
        repo_a = build_repo(self.tmpdir, host="archive.ubuntu.com", suite="jammy")
        # security host tree (same layout under different host dir)
        pkg = b"Package: sec\n"
        pkg_xz = lzma.compress(pkg)
        entries = [("main/binary-amd64/Packages.xz", pkg_xz)]
        ubuntu_s = os.path.join(
            self.tmpdir, "mirror", "security.ubuntu.com", "ubuntu"
        )
        suite_dir = os.path.join(ubuntu_s, "dists", "jammy-security")
        body, meta = make_release(entries, acquire=True)
        write(os.path.join(suite_dir, "InRelease"), body)
        write(os.path.join(suite_dir, "main/binary-amd64/Packages.xz"), pkg_xz)
        rc = sbh.main(
            [
                "sync-validate",
                "--mirror-root",
                self.tmpdir,
                "--quiet",
            ]
        )
        self.assertEqual(rc, 0)
        d1 = repo_a["meta"]["main/binary-amd64/Packages.xz"][0]
        d2 = meta["main/binary-amd64/Packages.xz"][0]
        self.assertTrue(
            os.path.isfile(
                os.path.join(
                    repo_a["suite_dir"],
                    "main/binary-amd64/by-hash/SHA256",
                    d1,
                )
            )
        )
        self.assertTrue(
            os.path.isfile(
                os.path.join(
                    suite_dir, "main/binary-amd64/by-hash/SHA256", d2
                )
            )
        )

    def test_12_gzip_xz_plain(self):
        pkg = b"Package: multi\n"
        entries = [
            ("main/binary-amd64/Packages", pkg),
            ("main/binary-amd64/Packages.gz", gzip.compress(pkg)),
            ("main/binary-amd64/Packages.xz", lzma.compress(pkg)),
        ]
        repo = build_repo(self.tmpdir, entries=entries)
        self.assertEqual(self._sync_validate(repo), 0)
        for relpath, data in entries:
            digest = sha256_bytes(data)
            path = os.path.join(
                repo["suite_dir"],
                "main/binary-amd64/by-hash/SHA256",
                digest,
            )
            self.assertTrue(os.path.isfile(path), path)

    def test_13_html_body_detected(self):
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        path = os.path.join(
            repo["suite_dir"], "main/binary-amd64/by-hash/SHA256", digest
        )
        write(path, b"<!DOCTYPE html><html><body>404</body></html>")
        # Also break named so validate catches html on by-hash
        # digest won't match — checksum_mismatch
        self.assertEqual(self._validate(repo), 1)

    def test_14_nginx_path_mapping(self):
        """URL /ubuntu/dists/.../by-hash/... maps to archive tree without rewrite."""
        repo = build_repo(self.tmpdir)
        self.assertEqual(self._sync_validate(repo), 0)
        digest = repo["meta"]["main/binary-amd64/Packages.xz"][0]
        url_path = (
            "/ubuntu/dists/jammy/main/binary-amd64/by-hash/SHA256/{}".format(digest)
        )
        # nginx alias /ubuntu/ -> .../archive.ubuntu.com/ubuntu/
        fs_path = os.path.join(
            repo["mirror_root"],
            "mirror",
            "archive.ubuntu.com",
            "ubuntu",
            url_path[len("/ubuntu/") :],
        )
        self.assertTrue(os.path.isfile(fs_path), fs_path)
        # Template must alias /ubuntu/ without blocking by-hash
        nginx = open(os.path.join(ROOT, "templates", "nginx.conf"), encoding="utf-8").read()
        self.assertIn("location /ubuntu/", nginx)
        self.assertIn("alias /var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu/", nginx)
        self.assertNotIn("by-hash", nginx)  # no special rewrite needed

    def test_15_discovery_byhash_url_shapes_supported(self):
        """Every discovery by-hash URL shape is generatable from Release entries."""
        discovery = os.path.join(ROOT, "artifacts", "upgrade-discovery")
        if not os.path.isdir(discovery):
            self.skipTest("discovery artifacts absent")
        import re
        from urllib.parse import urlparse

        pat = re.compile(
            r"/dists/([^/]+)/(.+)/by-hash/(SHA256|SHA512|SHA1|MD5)/([0-9a-fA-F]+)$"
        )
        shapes = set()
        unsupported = []
        for hop in sorted(os.listdir(discovery)):
            tsv = os.path.join(discovery, hop, "required-urls.tsv")
            if not os.path.isfile(tsv):
                continue
            with open(tsv, encoding="utf-8") as fh:
                hdr = fh.readline().rstrip("\n").split("\t")
                for line in fh:
                    row = dict(zip(hdr, line.rstrip("\n").split("\t")))
                    url = row.get("url") or row.get("original_url") or ""
                    if "/by-hash/" not in url:
                        continue
                    path = urlparse(url).path
                    m = pat.search(path)
                    if not m:
                        unsupported.append(url)
                        continue
                    suite, mid, algo, digest = m.groups()
                    # mid like main/binary-amd64 — by-hash parent is mid
                    shapes.add((algo, mid.split("/")[-1]))
                    # Ensure our path builder matches
                    suite_dir = "/tmp/dists/" + suite
                    # Reconstruct a plausible index path under mid
                    # Discovery doesn't include basename; builder uses dirname(relpath)
                    relpath = mid + "/Packages.xz"
                    built = sbh.by_hash_path(suite_dir, relpath, algo, digest.lower())
                    expected = os.path.join(
                        suite_dir, mid, "by-hash", algo, digest.lower()
                    )
                    self.assertEqual(built, expected)
        self.assertEqual(unsupported, [])
        # Observed kinds from discovery
        kinds = {k for _a, k in shapes}
        for expected in ("binary-amd64", "i18n", "cnf"):
            self.assertIn(expected, kinds)

    def test_parse_acquire_and_checksums(self):
        body, meta = make_release(
            [("main/binary-amd64/Packages.xz", b"abc")], acquire=True
        )
        headers, checksums = sbh.parse_release_text(body)
        self.assertTrue(sbh.acquire_by_hash_enabled(headers))
        self.assertEqual(len(checksums["SHA256"]), 1)
        self.assertEqual(checksums["SHA256"][0]["hash"], meta["main/binary-amd64/Packages.xz"][0])


if __name__ == "__main__":
    # Prefer unittest verbosity
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestByHash)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
