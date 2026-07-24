#!/usr/bin/env python3
"""Validate security.ubuntu.com compatibility for the offline Ubuntu mirror.

apt-mirror stores *-security suites under archive.ubuntu.com/ubuntu/.
This module checks filesystem presence, optional HTTP serving via
/ubuntu-security/ (and /ubuntu/), discovery URL shape coverage, and
summarizes metrics required by P0-2.
"""
from __future__ import print_function

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import OrderedDict, Counter
from urllib.parse import urlparse

BY_HASH_RE = re.compile(
    r"/dists/([^/]+)/(.+)/by-hash/(SHA256|SHA512|SHA1|MD5)/([0-9a-fA-F]+)$"
)
SECURITY_SUITE_RE = re.compile(r".+-security$")


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def discover_ubuntu_root(mirror_root):
    candidates = [
        os.path.join(mirror_root, "mirror", "archive.ubuntu.com", "ubuntu"),
        os.path.join(mirror_root, "archive.ubuntu.com", "ubuntu"),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "dists")):
            return c
    return ""


def list_security_suites(ubuntu_root):
    dists = os.path.join(ubuntu_root, "dists")
    if not os.path.isdir(dists):
        return []
    out = []
    for name in sorted(os.listdir(dists)):
        path = os.path.join(dists, name)
        if os.path.isdir(path) and SECURITY_SUITE_RE.match(name):
            out.append(name)
    return out


def suite_has_release(suite_dir):
    for name in ("InRelease", "Release"):
        p = os.path.join(suite_dir, name)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            return name
    return ""


def suite_has_packages(suite_dir):
    # Any component/binary-*/Packages*
    for dirpath, _dns, filenames in os.walk(suite_dir):
        base = os.path.basename(dirpath)
        if not base.startswith("binary-"):
            continue
        for fn in filenames:
            if fn == "Packages" or fn.startswith("Packages."):
                p = os.path.join(dirpath, fn)
                if os.path.isfile(p) and os.path.getsize(p) > 0:
                    return True
    return False


def count_by_hash(suite_dir):
    n = 0
    for dirpath, _dns, filenames in os.walk(suite_dir):
        parts = dirpath.split(os.sep)
        if "by-hash" in parts:
            n += len(filenames)
    return n


def count_pool_debs(ubuntu_root):
    pool = os.path.join(ubuntu_root, "pool")
    if not os.path.isdir(pool):
        return 0
    n = 0
    for dirpath, _dns, filenames in os.walk(pool):
        for fn in filenames:
            if fn.endswith(".deb"):
                n += 1
    return n


def http_check(base_url, path, method="GET", timeout=15, host_header=None):
    url = base_url.rstrip("/") + path
    cmd = [
        "curl",
        "-sS",
        "-o",
        "/dev/null",
        "-w",
        "%{http_code}",
        "--max-time",
        str(timeout),
        "-X",
        method,
    ]
    if host_header:
        cmd.extend(["-H", "Host: {}".format(host_header)])
    cmd.append(url)
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            check=False,
        )
    except OSError as exc:
        return "000", str(exc)
    code = (proc.stdout or "").strip() or "000"
    return code, ""


def classify_security_url(url):
    path = urlparse(url).path
    if "/by-hash/" in path:
        return "by-hash"
    if "/pool/" in path or path.endswith(".deb"):
        return "pool_deb"
    if path.endswith("InRelease") or path.endswith("/InRelease"):
        return "InRelease"
    if path.endswith("Release") or path.endswith("/Release"):
        return "Release"
    if "Packages" in os.path.basename(path):
        return "Packages"
    return "other"


def path_supported_by_aliases(path):
    """Return True if path under security.ubuntu.com /ubuntu/... maps to our aliases."""
    if not path.startswith("/ubuntu/"):
        return False, "path_not_under_/ubuntu/"
    # Equivalent local prefixes: /ubuntu/... and /ubuntu-security/...
    rest = path[len("/ubuntu/") :]
    # Must be dists/<suite>-security/... or pool/...
    if rest.startswith("dists/"):
        parts = rest.split("/")
        if len(parts) < 2:
            return False, "dists_too_short"
        suite = parts[1]
        if not suite.endswith("-security") and "/by-hash/" not in path and "/pool/" not in path:
            # security host sometimes serves only *-security suites in capture
            if not SECURITY_SUITE_RE.match(suite):
                return False, "suite_not_security_pocket:{}".format(suite)
        if "/by-hash/" in path and not BY_HASH_RE.search(path):
            return False, "by_hash_shape"
        return True, "ok"
    if rest.startswith("pool/"):
        return True, "ok"
    return False, "unsupported_path_class"


def load_discovery_security_urls(discovery_root):
    urls = []
    if not discovery_root or not os.path.isdir(discovery_root):
        return urls
    for hop in sorted(os.listdir(discovery_root)):
        tsv = os.path.join(discovery_root, hop, "required-urls.tsv")
        if not os.path.isfile(tsv):
            continue
        with open(tsv, encoding="utf-8") as fh:
            hdr = fh.readline().rstrip("\n").split("\t")
            for line in fh:
                row = dict(zip(hdr, line.rstrip("\n").split("\t")))
                url = row.get("url") or row.get("original_url") or ""
                if "security.ubuntu.com" not in url:
                    continue
                urls.append({"hop": hop, "url": url, "type": classify_security_url(url)})
    return urls


def scan_external_security_in_sources(sources_root):
    """Scan apt sources trees for remaining security.ubuntu.com references."""
    remaining = []
    if not sources_root or not os.path.isdir(sources_root):
        return remaining
    candidates = []
    sl = os.path.join(sources_root, "sources.list")
    if os.path.isfile(sl):
        candidates.append(sl)
    sld = os.path.join(sources_root, "sources.list.d")
    if os.path.isdir(sld):
        for name in os.listdir(sld):
            if name.endswith(".list") or name.endswith(".sources"):
                candidates.append(os.path.join(sld, name))
    for path in candidates:
        if "disabled-by-dp-os-upgrade" in os.path.basename(path):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        if "security.ubuntu.com" in text:
            remaining.append(path)
    return remaining


def run_validation(args):
    summary = OrderedDict(
        [
            ("archive_repository_status", "UNKNOWN"),
            ("security_repository_status", "UNKNOWN"),
            ("security_suites_found", 0),
            ("security_metadata_files_checked", 0),
            ("security_by_hash_required", 0),
            ("security_by_hash_missing", 0),
            ("security_pool_files_found", 0),
            ("security_http_checks", 0),
            ("external_security_urls_remaining", 0),
            ("discovered_security_urls", 0),
            ("supported_security_urls", 0),
            ("unsupported_security_urls", 0),
            ("unsupported_patterns", []),
            ("validation_result", "PASS"),
            ("details", []),
        ]
    )

    ubuntu_root = args.ubuntu_root or discover_ubuntu_root(args.mirror_root)
    if not ubuntu_root or not os.path.isdir(ubuntu_root):
        summary["archive_repository_status"] = "FAIL"
        summary["security_repository_status"] = "FAIL"
        summary["validation_result"] = "FAIL"
        summary["details"].append("ubuntu root missing")
        return summary

    dists = os.path.join(ubuntu_root, "dists")
    if os.path.isdir(dists):
        summary["archive_repository_status"] = "PASS"
    else:
        summary["archive_repository_status"] = "FAIL"
        summary["validation_result"] = "FAIL"
        summary["details"].append("dists missing")

    suites = list_security_suites(ubuntu_root)
    summary["security_suites_found"] = len(suites)
    if not suites:
        summary["security_repository_status"] = "FAIL"
        summary["validation_result"] = "FAIL"
        summary["details"].append("no *-security suites found")
    else:
        meta_ok = 0
        pkg_ok = 0
        meta_missing = 0
        pkg_missing = 0
        by_hash_files = 0
        for suite in suites:
            sdir = os.path.join(dists, suite)
            rel = suite_has_release(sdir)
            summary["security_metadata_files_checked"] += 1
            if rel:
                meta_ok += 1
            else:
                meta_missing += 1
                summary["details"].append("missing InRelease/Release: {}".format(suite))
            if suite_has_packages(sdir):
                pkg_ok += 1
            else:
                pkg_missing += 1
                summary["details"].append("missing Packages index: {}".format(suite))
            by_hash_files += count_by_hash(sdir)

        summary["security_by_hash_required"] = by_hash_files
        # Every discovered *-security suite must have Release metadata and Packages.
        if meta_missing or pkg_missing or meta_ok == 0 or pkg_ok == 0:
            summary["security_repository_status"] = "FAIL"
            summary["validation_result"] = "FAIL"
        else:
            summary["security_repository_status"] = "PASS"

    summary["security_pool_files_found"] = count_pool_debs(ubuntu_root)
    if summary["security_pool_files_found"] < 1 and suites:
        summary["details"].append("no pool .deb files under ubuntu root")
        summary["security_repository_status"] = "FAIL"
        summary["validation_result"] = "FAIL"

    # Discovery coverage (shape), no hardcoded URL list
    disc = load_discovery_security_urls(args.discovery_root)
    summary["discovered_security_urls"] = len(disc)
    unsupported = []
    patterns = Counter()
    for item in disc:
        path = urlparse(item["url"]).path
        ok, reason = path_supported_by_aliases(path)
        if ok:
            summary["supported_security_urls"] += 1
        else:
            summary["unsupported_security_urls"] += 1
            unsupported.append(item["url"])
            patterns[reason] += 1
    summary["unsupported_patterns"] = [
        "{}:{}".format(k, v) for k, v in sorted(patterns.items())
    ]
    if summary["discovered_security_urls"] and summary["unsupported_security_urls"]:
        summary["validation_result"] = "FAIL"
        summary["details"].append(
            "unsupported discovery security URLs: {}".format(
                summary["unsupported_security_urls"]
            )
        )

    # Optional HTTP checks
    http_fail = 0
    http_ok = 0
    if args.http_base:
        # Pick first security suite for probes
        probe_suite = suites[0] if suites else ""
        paths = []
        if probe_suite:
            paths.append("/ubuntu-security/dists/{}/InRelease".format(probe_suite))
            paths.append("/ubuntu/dists/{}/InRelease".format(probe_suite))
            # Packages
            pkg_base = os.path.join(
                dists, probe_suite, "main", "binary-amd64"
            )
            for name in ("Packages.xz", "Packages.gz", "Packages"):
                if os.path.isfile(os.path.join(pkg_base, name)):
                    paths.append(
                        "/ubuntu-security/dists/{}/main/binary-amd64/{}".format(
                            probe_suite, name
                        )
                    )
                    break
            # by-hash sample
            bh = os.path.join(pkg_base, "by-hash", "SHA256")
            if os.path.isdir(bh):
                for dig in sorted(os.listdir(bh)):
                    paths.append(
                        "/ubuntu-security/dists/{}/main/binary-amd64/by-hash/SHA256/{}".format(
                            probe_suite, dig
                        )
                    )
                    break
        # pool sample
        pool = os.path.join(ubuntu_root, "pool")
        if os.path.isdir(pool):
            for dirpath, _dns, filenames in os.walk(pool):
                for fn in filenames:
                    if fn.endswith(".deb"):
                        rel = os.path.relpath(os.path.join(dirpath, fn), ubuntu_root)
                        paths.append("/ubuntu-security/{}".format(rel.replace(os.sep, "/")))
                        break
                if any(p.endswith(".deb") for p in paths):
                    break

        for path in paths:
            for method in ("GET", "HEAD"):
                code, err = http_check(
                    args.http_base, path, method=method, timeout=args.timeout
                )
                summary["security_http_checks"] += 1
                if code == "200":
                    http_ok += 1
                else:
                    http_fail += 1
                    summary["details"].append(
                        "HTTP {} {} -> {} {}".format(method, path, code, err)
                    )

        # Host header compatibility (optional probe)
        if args.check_host_header and probe_suite:
            path = "/ubuntu/dists/{}/InRelease".format(probe_suite)
            code, _err = http_check(
                args.http_base,
                path,
                method="GET",
                timeout=args.timeout,
                host_header="security.ubuntu.com",
            )
            summary["security_http_checks"] += 1
            if code == "200":
                http_ok += 1
            else:
                # Not fatal if path alias works — Host vhost is optional
                summary["details"].append(
                    "Host security.ubuntu.com {} -> {} (optional)".format(path, code)
                )

        # 404 must not be HTML 200 — probe missing file
        code, _ = http_check(
            args.http_base,
            "/ubuntu-security/dists/__missing_suite__/InRelease",
            method="GET",
            timeout=args.timeout,
        )
        summary["security_http_checks"] += 1
        if code == "404":
            http_ok += 1
        elif code == "200":
            http_fail += 1
            summary["details"].append("missing path returned HTTP 200 (want 404)")
            summary["validation_result"] = "FAIL"
        else:
            # other codes acceptable as not-found-ish
            http_ok += 1

        if http_fail:
            summary["security_repository_status"] = "FAIL"
            summary["validation_result"] = "FAIL"

    # External security URLs in client sources
    remaining = scan_external_security_in_sources(args.sources_root)
    summary["external_security_urls_remaining"] = len(remaining)
    if remaining:
        summary["validation_result"] = "FAIL"
        summary["details"].append(
            "external security.ubuntu.com in: {}".format(", ".join(remaining))
        )

    if args.require_by_hash and suites:
        # Delegate detailed by-hash to sync_by_hash if available
        missing = 0
        try:
            from sync_by_hash import (  # type: ignore
                collect_required,
                read_suite_release,
                validate_item,
            )

            for suite in suites:
                sdir = os.path.join(dists, suite)
                try:
                    _n, _p, headers, checksums = read_suite_release(sdir)
                except Exception as exc:  # noqa: BLE001
                    summary["details"].append("by-hash read {}: {}".format(suite, exc))
                    missing += 1
                    continue
                _acq, required = collect_required(sdir, headers, checksums)
                summary["security_by_hash_required"] = summary.get(
                    "security_by_hash_required", 0
                ) + len(required)
                for item in required.values():
                    ok, code = validate_item(item)
                    if not ok:
                        missing += 1
                        summary["details"].append(
                            "by-hash {}:{}:{}".format(suite, item["path"], code)
                        )
        except ImportError:
            if by_hash_files == 0:
                missing = 1
                summary["details"].append("no by-hash files and sync_by_hash unavailable")
        summary["security_by_hash_missing"] = missing
        if missing:
            summary["security_repository_status"] = "FAIL"
            summary["validation_result"] = "FAIL"

    if summary["archive_repository_status"] != "PASS":
        summary["validation_result"] = "FAIL"
    if summary["security_repository_status"] != "PASS":
        summary["validation_result"] = "FAIL"

    return summary


def print_summary(summary):
    keys = [
        "archive_repository_status",
        "security_repository_status",
        "security_suites_found",
        "security_metadata_files_checked",
        "security_by_hash_required",
        "security_by_hash_missing",
        "security_pool_files_found",
        "security_http_checks",
        "external_security_urls_remaining",
        "discovered_security_urls",
        "supported_security_urls",
        "unsupported_security_urls",
        "validation_result",
    ]
    for k in keys:
        print("{}={}".format(k, summary.get(k)))
    if summary.get("unsupported_patterns"):
        print("unsupported_patterns={}".format(",".join(summary["unsupported_patterns"])))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate security repository compatibility")
    parser.add_argument(
        "--mirror-root",
        default=os.environ.get("MIRROR_ROOT", "/var/spool/apt-mirror"),
    )
    parser.add_argument("--ubuntu-root", default="")
    parser.add_argument("--http-base", default="", help="e.g. http://127.0.0.1")
    parser.add_argument("--timeout", type=int, default=15)
    parser.add_argument(
        "--discovery-root",
        default="",
        help="artifacts/upgrade-discovery for shape coverage",
    )
    parser.add_argument(
        "--sources-root",
        default="",
        help="Client /etc/apt directory to scan for external security URLs",
    )
    parser.add_argument("--check-host-header", action="store_true")
    parser.add_argument("--require-by-hash", action="store_true")
    parser.add_argument("--result-json", default="")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    # Make sync_by_hash importable
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)

    summary = run_validation(args)
    print_summary(summary)
    if args.result_json:
        parent = os.path.dirname(args.result_json)
        if parent:
            os.makedirs(parent, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".sec-val-", dir=parent or None)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(summary, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, args.result_json)
    if not args.quiet:
        for d in summary.get("details", [])[:30]:
            eprint("  {}".format(d))
    return 0 if summary.get("validation_result") == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
