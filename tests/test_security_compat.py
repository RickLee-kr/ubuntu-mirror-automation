#!/usr/bin/env python3
"""Fixture tests for P0-2 security.ubuntu.com compatibility."""
from __future__ import print_function

import gzip
import hashlib
import lzma
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))

import validate_security_compat as vsc  # noqa: E402


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def make_release(entries, suite="jammy-security", acquire=True):
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
        lines.append(
            " {} {} {}".format(sha256_bytes(data), len(data), relpath)
        )
    return "\n".join(lines) + "\n"


def build_mirror(tmpdir, with_security=True, with_byhash=True, with_packages=True, with_pool=True):
    archive = os.path.join(tmpdir, "mirror", "archive.ubuntu.com", "ubuntu")
    # archive noble for archive_repository_status
    write(os.path.join(archive, "dists", "noble", "InRelease"), "Suite: noble\n")
    write(os.path.join(archive, "dists", "noble", "main", "binary-amd64", "Packages"), b"Package: a\n")

    suites = []
    if with_security:
        for suite in (
            "xenial-security",
            "bionic-security",
            "focal-security",
            "jammy-security",
            "noble-security",
        ):
            suites.append(suite)
            pkg = b"Package: sec-%s\n" % suite.encode()
            pkg_xz = lzma.compress(pkg)
            entries = []
            if with_packages:
                entries.append(("main/binary-amd64/Packages.xz", pkg_xz))
                for comp in ("restricted", "universe", "multiverse"):
                    entries.append(("{}/binary-amd64/Packages.xz".format(comp), pkg_xz))
            body = make_release(entries, suite=suite)
            write(os.path.join(archive, "dists", suite, "InRelease"), body)
            for relpath, data in entries:
                dest = os.path.join(archive, "dists", suite, relpath)
                write(dest, data)
                if with_byhash:
                    dig = sha256_bytes(data)
                    bh = os.path.join(
                        os.path.dirname(dest), "by-hash", "SHA256", dig
                    )
                    write(bh, data)
    if with_pool:
        write(
            os.path.join(archive, "pool", "main", "s", "secpkg", "secpkg_1_amd64.deb"),
            b"fake-deb\n",
        )
    return {
        "mirror_root": tmpdir,
        "ubuntu_root": archive,
        "suites": suites,
    }


class TestSecurityCompat(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix="sec-compat-")

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _validate(self, repo, **kwargs):
        argv = [
            "--mirror-root",
            repo["mirror_root"],
            "--ubuntu-root",
            repo["ubuntu_root"],
            "--quiet",
        ]
        discovery = kwargs.pop("discovery_root", os.path.join(ROOT, "artifacts", "upgrade-discovery"))
        if discovery and os.path.isdir(discovery):
            argv.extend(["--discovery-root", discovery])
        sources = kwargs.pop("sources_root", "")
        if sources:
            argv.extend(["--sources-root", sources])
        if kwargs.pop("require_by_hash", False):
            argv.append("--require-by-hash")
        http_base = kwargs.pop("http_base", "")
        if http_base:
            argv.extend(["--http-base", http_base])
        return vsc.main(argv)

    def test_01_archive_and_security_present_pass(self):
        repo = build_mirror(self.tmpdir)
        self.assertEqual(self._validate(repo), 0)

    def test_02_security_inrelease_missing_fail(self):
        repo = build_mirror(self.tmpdir)
        os.unlink(
            os.path.join(repo["ubuntu_root"], "dists", "jammy-security", "InRelease")
        )
        self.assertEqual(self._validate(repo), 1)

    def test_03_security_packages_missing_fail(self):
        repo = build_mirror(self.tmpdir, with_packages=False)
        # still has InRelease with empty checksums — no Packages files
        self.assertEqual(self._validate(repo), 1)

    def test_04_security_byhash_missing_fail(self):
        repo = build_mirror(self.tmpdir, with_byhash=False)
        self.assertEqual(self._validate(repo, require_by_hash=True), 1)

    def test_05_security_pool_missing_fail(self):
        repo = build_mirror(self.tmpdir, with_pool=False)
        self.assertEqual(self._validate(repo), 1)

    def test_06_discovery_coverage_55(self):
        repo = build_mirror(self.tmpdir)
        # Capture summary via run_validation
        class A(object):
            pass

        args = A()
        args.mirror_root = repo["mirror_root"]
        args.ubuntu_root = repo["ubuntu_root"]
        args.http_base = ""
        args.timeout = 5
        args.discovery_root = os.path.join(ROOT, "artifacts", "upgrade-discovery")
        args.sources_root = ""
        args.check_host_header = False
        args.require_by_hash = False
        summary = vsc.run_validation(args)
        self.assertEqual(summary["discovered_security_urls"], 55)
        self.assertEqual(summary["unsupported_security_urls"], 0)
        self.assertEqual(summary["supported_security_urls"], 55)

    def test_07_path_mapping_aliases(self):
        ok, _ = vsc.path_supported_by_aliases(
            "/ubuntu/dists/jammy-security/main/binary-amd64/by-hash/SHA256/" + ("a" * 64)
        )
        self.assertTrue(ok)
        ok, _ = vsc.path_supported_by_aliases("/ubuntu/pool/main/a/a.deb")
        self.assertTrue(ok)
        ok, reason = vsc.path_supported_by_aliases("/other/path")
        self.assertFalse(ok)

    def test_08_client_sources_rewrite_classic(self):
        apt = os.path.join(self.tmpdir, "apt")
        os.makedirs(os.path.join(apt, "sources.list.d"))
        write(
            os.path.join(apt, "sources.list"),
            "\n".join(
                [
                    "deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse",
                    "deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse",
                    "deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse",
                    "deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse",
                    "deb http://ports.ubuntu.com/ubuntu-ports jammy main",
                    "deb http://ppa.launchpad.net/foo/bar/ubuntu jammy main",
                    "",
                ]
            ),
        )
        write(
            os.path.join(apt, "sources.list.d", "disabled-by-dp-os-upgrade.list"),
            "deb http://security.ubuntu.com/ubuntu jammy-security main\n",
        )
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt
        proc = subprocess.run(
            [
                "bash",
                os.path.join(ROOT, "client", "client-setup.sh"),
                "--mirror-url",
                "http://10.1.2.3",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        text = open(os.path.join(apt, "sources.list"), encoding="utf-8").read()
        self.assertIn("http://10.1.2.3/ubuntu jammy ", text)
        self.assertIn("http://10.1.2.3/ubuntu-security jammy-security ", text)
        self.assertNotIn("security.ubuntu.com", text)
        self.assertIn("ports.ubuntu.com", text)
        self.assertIn("ppa.launchpad.net", text)
        # disabled file untouched
        disabled = open(
            os.path.join(apt, "sources.list.d", "disabled-by-dp-os-upgrade.list"),
            encoding="utf-8",
        ).read()
        self.assertIn("security.ubuntu.com", disabled)

    def test_09_client_idempotent_and_ip_change(self):
        apt = os.path.join(self.tmpdir, "apt2")
        os.makedirs(os.path.join(apt, "sources.list.d"))
        write(
            os.path.join(apt, "sources.list"),
            "deb http://archive.ubuntu.com/ubuntu jammy main\n"
            "deb http://security.ubuntu.com/ubuntu jammy-security main\n",
        )
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt
        for url in ("http://10.1.2.3", "http://10.1.2.3", "http://10.9.9.9"):
            proc = subprocess.run(
                [
                    "bash",
                    os.path.join(ROOT, "client", "client-setup.sh"),
                    "--mirror-url",
                    url,
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        text = open(os.path.join(apt, "sources.list"), encoding="utf-8").read()
        self.assertEqual(text.count("ubuntu-security"), 1)
        self.assertIn("http://10.9.9.9/ubuntu-security", text)
        self.assertNotIn("10.1.2.3", text)

    def test_10_deb822_sources(self):
        apt = os.path.join(self.tmpdir, "apt3")
        os.makedirs(os.path.join(apt, "sources.list.d"))
        write(
            os.path.join(apt, "sources.list.d", "ubuntu.sources"),
            "\n".join(
                [
                    "Types: deb",
                    "URIs: http://archive.ubuntu.com/ubuntu",
                    "Suites: noble noble-updates noble-backports",
                    "Components: main restricted universe multiverse",
                    "",
                    "Types: deb",
                    "URIs: http://security.ubuntu.com/ubuntu",
                    "Suites: noble-security",
                    "Components: main restricted universe multiverse",
                    "",
                ]
            ),
        )
        env = os.environ.copy()
        env["CLIENT_SETUP_APT_ROOT"] = apt
        proc = subprocess.run(
            [
                "bash",
                os.path.join(ROOT, "client", "client-setup.sh"),
                "--mirror-url",
                "http://10.0.0.5",
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        text = open(
            os.path.join(apt, "sources.list.d", "ubuntu.sources"), encoding="utf-8"
        ).read()
        self.assertIn("URIs: http://10.0.0.5/ubuntu\n", text)
        self.assertIn("URIs: http://10.0.0.5/ubuntu-security\n", text)
        self.assertNotIn("security.ubuntu.com", text)

    def test_11_external_security_sources_fail_validation(self):
        repo = build_mirror(self.tmpdir)
        apt = os.path.join(self.tmpdir, "apt4")
        os.makedirs(apt)
        write(
            os.path.join(apt, "sources.list"),
            "deb http://security.ubuntu.com/ubuntu jammy-security main\n",
        )
        self.assertEqual(self._validate(repo, sources_root=apt), 1)

    def test_12_nginx_template_has_security_alias(self):
        conf = open(os.path.join(ROOT, "templates", "nginx.conf"), encoding="utf-8").read()
        self.assertIn("location /ubuntu-security/", conf)
        self.assertIn("server_name security.ubuntu.com", conf)
        self.assertIn("server_name archive.ubuntu.com", conf)
        self.assertIn(
            "alias /var/spool/apt-mirror/selective/active/ubuntu/", conf
        )

    def test_13_components_and_suites_in_fixture(self):
        repo = build_mirror(self.tmpdir)
        for suite in repo["suites"]:
            for comp in ("main", "restricted", "universe", "multiverse"):
                p = os.path.join(
                    repo["ubuntu_root"],
                    "dists",
                    suite,
                    comp,
                    "binary-amd64",
                    "Packages.xz",
                )
                self.assertTrue(os.path.isfile(p), p)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestSecurityCompat)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
