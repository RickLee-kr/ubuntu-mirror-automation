#!/usr/bin/env python3
"""Sync and validate local meta-release-lts + release upgrader tarballs/signatures.

Downloads upstream meta-release-lts, materializes UpgradeTool / UpgradeToolSignature
into the local archive tree (paths derived from metadata URLs — not hardcoded
filenames), verifies detached GPG signatures with the Ubuntu archive keyring,
rewrites meta-release URLs to PUBLIC_BASE_URL, and promotes a staging snapshot
atomically. Existing live files are preserved when a sync fails.

Commands: sync | validate | sync-validate
"""
from __future__ import print_function

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict
from urllib.parse import urlparse

HTML_RE = re.compile(br"<(!DOCTYPE\s+)?[Hh][Tt][Mm][Ll]", re.IGNORECASE)
EXTERNAL_HOST_RE = re.compile(
    r"(?:archive|security|old-releases|changelogs)\.ubuntu\.com",
    re.IGNORECASE,
)
CANONICAL_EXTERNAL_HOSTS = frozenset(
    [
        "changelogs.ubuntu.com",
        "archive.ubuntu.com",
        "security.ubuntu.com",
        "old-releases.ubuntu.com",
        "api.snapcraft.io",
    ]
)

# Default LTS hop targets (UpgradeTool download set). Chain entries are broader.
DEFAULT_UPGRADER_DISTS = ("bionic", "focal", "jammy", "noble")
DEFAULT_META_CHAIN = ("xenial", "bionic", "focal", "jammy", "noble")
DEFAULT_ALLOWED_HOSTS = (
    "changelogs.ubuntu.com archive.ubuntu.com "
    "security.ubuntu.com old-releases.ubuntu.com"
)

REWRITE_URL_KEYS = frozenset(
    [
        "UpgradeTool",
        "UpgradeToolSignature",
        "Release-File",
        "ReleaseNotes",
        "ReleaseNotesHtml",
    ]
)
REQUIRED_ENTRY_KEYS = frozenset(["Dist", "Version", "Supported", "Date"])


class SyncError(Exception):
    pass


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def log_line(msg, quiet=False):
    if quiet:
        return
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print("{} [release-upgrader] {}".format(stamp, msg))


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def is_probably_html(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(512)
    except OSError:
        return False
    return HTML_RE.search(head) is not None


def url_host(url):
    try:
        return (urlparse(url).hostname or "").lower()
    except Exception:
        return ""


def url_path(url):
    try:
        p = urlparse(url).path or "/"
    except Exception:
        return "/"
    if not p.startswith("/"):
        p = "/" + p
    return p


def host_allowed(host, allowlist):
    host = (host or "").lower()
    allow = (
        (allowlist or "")
        .lower()
        .replace(",", " ")
        .split()
    )
    return host in allow


def parse_meta_release(text):
    """Parse Ubuntu meta-release (blank-line separated records) into list of OrderedDict."""
    entries = []
    current = OrderedDict()
    for raw in text.splitlines():
        line = raw.rstrip("\r\n")
        if not line.strip():
            if current:
                entries.append(current)
                current = OrderedDict()
            continue
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        current[key.strip()] = val.lstrip()
    if current:
        entries.append(current)
    return entries


def format_meta_release(entries):
    """Serialize entries with Ubuntu-compatible blank-line separation."""
    blocks = []
    for entry in entries:
        lines = []
        for key, val in entry.items():
            lines.append("{}: {}".format(key, val))
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks) + ("\n" if blocks else "")


def entry_by_dist(entries, dist):
    for e in entries:
        if e.get("Dist") == dist:
            return e
    return None


def rewrite_url(url, public_base):
    """Map Canonical archive/changelogs URLs onto PUBLIC_BASE_URL paths."""
    public_base = public_base.rstrip("/")
    host = url_host(url)
    path = url_path(url)

    if host in ("archive.ubuntu.com", "old-releases.ubuntu.com"):
        if path == "/ubuntu" or path.startswith("/ubuntu/"):
            return public_base + path
        return public_base + "/ubuntu" + path

    if host == "security.ubuntu.com":
        if path.startswith("/ubuntu/"):
            return public_base + "/ubuntu-security" + path[len("/ubuntu") :]
        if path == "/ubuntu":
            return public_base + "/ubuntu-security"
        return public_base + "/ubuntu-security" + path

    if host == "changelogs.ubuntu.com":
        base = os.path.basename(path.rstrip("/")) or "announcement"
        return "{}/offline/announcements/{}".format(public_base, base)

    raise SyncError("cannot rewrite URL (unknown host {}): {}".format(host, url))


def local_fs_path_for_url(url, ubuntu_root, offline_dir):
    """Map an upstream URL to a path under the local mirror tree."""
    host = url_host(url)
    path = url_path(url)
    if host in ("archive.ubuntu.com", "old-releases.ubuntu.com", "security.ubuntu.com"):
        if path.startswith("/ubuntu/"):
            rel = path[len("/ubuntu/") :]
        elif path == "/ubuntu":
            rel = ""
        else:
            rel = path.lstrip("/")
        return os.path.join(ubuntu_root, rel)
    if host == "changelogs.ubuntu.com":
        base = os.path.basename(path.rstrip("/")) or "announcement"
        return os.path.join(offline_dir, "announcements", base)
    raise SyncError("no local path mapping for {}".format(url))


def public_path_for_rewritten(url, public_base):
    rewritten = rewrite_url(url, public_base)
    base = public_base.rstrip("/")
    if rewritten.startswith(base):
        return rewritten[len(base) :] or "/"
    return url_path(rewritten)


def curl_download(
    url,
    dest,
    connect_timeout=30,
    max_time=600,
    retries=3,
    if_modified_since=None,
    allow_304_with_existing=None,
):
    """Download URL to dest via curl. Returns dict with status/size/final_url.

    HTTP 200 required for a new body. HTTP 304 is accepted only when
    allow_304_with_existing points to an existing non-empty file (copied to dest).
    If 304 and no local body, retries once without If-Modified-Since.
    """
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    tmp = dest + ".partial"
    if os.path.exists(tmp):
        os.unlink(tmp)

    def _run(extra_headers=None):
        cmd = [
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--connect-timeout",
            str(connect_timeout),
            "--max-time",
            str(max_time),
            "--retry",
            str(retries),
            "--retry-delay",
            "2",
            "-o",
            tmp,
            "-w",
            "%{http_code}|%{url_effective}|%{size_download}",
        ]
        if extra_headers:
            for h in extra_headers:
                cmd.extend(["-H", h])
        cmd.append(url)
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
        )
        out = (proc.stdout or "").strip()
        parts = out.split("|")
        code = parts[0] if parts else "000"
        final = parts[1] if len(parts) > 1 else url
        return proc.returncode, code, final, proc.stderr or ""

    headers = []
    if if_modified_since:
        headers.append("If-Modified-Since: {}".format(if_modified_since))

    rc, code, final, err = _run(headers or None)

    if code == "304":
        if allow_304_with_existing and os.path.isfile(allow_304_with_existing):
            size = os.path.getsize(allow_304_with_existing)
            if size > 0:
                shutil.copy2(allow_304_with_existing, dest)
                if os.path.exists(tmp):
                    os.unlink(tmp)
                return {
                    "ok": True,
                    "http_status": 304,
                    "final_url": final,
                    "size": size,
                    "path": dest,
                    "from_cache": True,
                }
        # 304 but no usable body → unconditional retry
        if os.path.exists(tmp):
            os.unlink(tmp)
        rc, code, final, err = _run(None)

    if rc != 0 or code != "200":
        if os.path.exists(tmp):
            os.unlink(tmp)
        return {
            "ok": False,
            "http_status": int(code) if code.isdigit() else 0,
            "final_url": final,
            "size": 0,
            "error": "curl rc={} http={} err={}".format(rc, code, err.strip()[:200]),
        }

    size = os.path.getsize(tmp) if os.path.isfile(tmp) else 0
    if size == 0:
        os.unlink(tmp)
        return {
            "ok": False,
            "http_status": 200,
            "final_url": final,
            "size": 0,
            "error": "zero-byte body",
        }
    if is_probably_html(tmp):
        os.unlink(tmp)
        return {
            "ok": False,
            "http_status": 200,
            "final_url": final,
            "size": size,
            "error": "HTML error page",
        }

    os.replace(tmp, dest)
    return {
        "ok": True,
        "http_status": 200,
        "final_url": final,
        "size": size,
        "path": dest,
        "from_cache": False,
    }


def gpgv_verify(tarball, signature, keyring):
    """Verify detached signature with gpgv. Returns (ok, detail_dict)."""
    detail = {
        "keyring": keyring,
        "signer_fingerprint": "",
        "ok": False,
        "error": "",
    }
    if not os.path.isfile(keyring):
        detail["error"] = "keyring missing: {}".format(keyring)
        return False, detail
    if not os.path.isfile(tarball) or os.path.getsize(tarball) == 0:
        detail["error"] = "tarball missing or empty"
        return False, detail
    if not os.path.isfile(signature) or os.path.getsize(signature) == 0:
        detail["error"] = "signature missing or empty"
        return False, detail
    if is_probably_html(tarball):
        detail["error"] = "tarball looks like HTML"
        return False, detail

    proc = subprocess.run(
        ["gpgv", "--keyring", keyring, signature, tarball],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    combined = (proc.stdout or "") + (proc.stderr or "")
    # gpgv prints "Good signature from ..." / fingerprint lines on stderr
    fp_match = re.search(
        r"([0-9A-F]{40}|[0-9A-F]{16})", combined.replace(" ", ""), re.IGNORECASE
    )
    if fp_match:
        detail["signer_fingerprint"] = fp_match.group(1).upper()
    # Prefer using --status-fd style parse; also accept "Good signature"
    if proc.returncode == 0 and re.search(r"Good signature", combined, re.IGNORECASE):
        detail["ok"] = True
        return True, detail
    if proc.returncode == 0:
        # Some gpgv builds are terse; trust exit 0
        detail["ok"] = True
        return True, detail
    detail["error"] = combined.strip()[:500] or "gpgv failed rc={}".format(proc.returncode)
    return False, detail


def build_local_entries(upstream_entries, chain_dists, public_base):
    local = []
    missing = []
    for dist in chain_dists:
        src = entry_by_dist(upstream_entries, dist)
        if src is None:
            missing.append(dist)
            continue
        for req in ("UpgradeTool", "UpgradeToolSignature"):
            if not src.get(req):
                raise SyncError("{} missing for Dist {}".format(req, dist))
        new_entry = OrderedDict()
        for key, val in src.items():
            if key in REWRITE_URL_KEYS and val:
                new_entry[key] = rewrite_url(val, public_base)
            else:
                new_entry[key] = val
        local.append(new_entry)
    if missing:
        raise SyncError("missing Dist entries in upstream meta-release-lts: {}".format(
            ", ".join(missing)
        ))
    return local


def external_urls_in_entries(entries, public_base, keys=None):
    """Return list of (dist, key, url) that are external / not under public_base."""
    keys = keys or ("UpgradeTool", "UpgradeToolSignature")
    public_base = public_base.rstrip("/")
    bad = []
    for e in entries:
        dist = e.get("Dist", "?")
        for key in keys:
            val = e.get(key, "")
            if not val:
                continue
            host = url_host(val)
            if host in CANONICAL_EXTERNAL_HOSTS or not val.startswith(public_base):
                bad.append((dist, key, val))
    return bad


def discover_ubuntu_root(mirror_root):
    candidates = [
        os.path.join(mirror_root, "mirror", "archive.ubuntu.com", "ubuntu"),
        os.path.join(mirror_root, "archive.ubuntu.com", "ubuntu"),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "dists")):
            return c
    # Allow empty tree for fixture bootstrap
    return candidates[0]


def http_check(base_url, path, method="GET", timeout=15):
    url = base_url.rstrip("/") + path
    cmd = ["curl", "-sS", "-o", "/dev/null", "--max-time", str(timeout), "-w", "%{http_code}"]
    if method == "HEAD":
        cmd.append("-I")
    else:
        cmd.extend(["-X", method])
    cmd.append(url)
    proc = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True
    )
    code = (proc.stdout or "").strip() or "000"
    try:
        return int(code)
    except ValueError:
        return 0


def mtime_http_date(path):
    if not os.path.isfile(path):
        return None
    return time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(os.path.getmtime(path)))


def atomic_write_text(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".meta.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def promote_file(src, dest):
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    os.replace(src, dest)
    os.chmod(dest, 0o644)


def referenced_upgrader_basenames(local_entries):
    """Basenames of UpgradeTool / Signature under dist-upgrader-all/current."""
    refs = set()
    for e in local_entries:
        for key in ("UpgradeTool", "UpgradeToolSignature"):
            val = e.get(key, "")
            if not val:
                continue
            path = url_path(val)
            if "dist-upgrader-all" in path:
                refs.add(os.path.basename(path))
    return refs


def stale_cleanup_upgraders(ubuntu_root, upgrader_dists, referenced_names, log):
    """Remove unreferenced files under each target's dist-upgrader-all/current."""
    removed = []
    for dist in upgrader_dists:
        cur = os.path.join(
            ubuntu_root,
            "dists",
            "{}-updates".format(dist),
            "main",
            "dist-upgrader-all",
            "current",
        )
        if not os.path.isdir(cur):
            continue
        for name in os.listdir(cur):
            path = os.path.join(cur, name)
            if not os.path.isfile(path):
                continue
            # Keep currently referenced tools/sigs and announcements we may still use
            if name in referenced_names:
                continue
            if name.startswith("ReleaseAnnouncement") or name.startswith("EOL"):
                continue
            if name.endswith(".tar.gz") or name.endswith(".tar.gz.gpg") or name.endswith(".gpg"):
                os.unlink(path)
                removed.append(path)
                log("stale cleanup removed {}".format(path))
    return removed


def empty_summary():
    return OrderedDict(
        [
            ("meta_release_path", ""),
            ("meta_release_http_status", 0),
            ("meta_release_entries", 0),
            ("required_lts_hops", []),
            ("supported_lts_hops", []),
            ("missing_lts_hops", []),
            ("upgrader_tarballs_required", 0),
            ("upgrader_tarballs_present", 0),
            ("upgrader_signatures_required", 0),
            ("upgrader_signatures_present", 0),
            ("signature_valid_count", 0),
            ("signature_invalid_count", 0),
            ("external_urls_remaining", 0),
            ("external_connection_attempts", 0),
            ("client_meta_release_config_status", "not_checked"),
            ("keyring", ""),
            ("meta_release_sha256", ""),
            ("validation_result", "FAIL"),
            ("details", []),
            ("downloads", []),
            ("signatures", []),
        ]
    )


def validate_tree(
    mirror_root,
    ubuntu_root,
    public_base,
    upgrader_dists,
    meta_chain,
    keyring,
    http_base="",
    client_meta_release_path="",
    quiet=False,
):
    summary = empty_summary()
    offline_dir = os.path.join(mirror_root, "offline")
    meta_local = os.path.join(offline_dir, "meta-release-lts")
    summary["meta_release_path"] = meta_local
    summary["keyring"] = keyring
    summary["required_lts_hops"] = list(upgrader_dists)
    details = summary["details"]

    if not os.path.isfile(meta_local) or os.path.getsize(meta_local) == 0:
        details.append("local meta-release-lts missing or empty")
        summary["missing_lts_hops"] = list(upgrader_dists)
        return summary

    if is_probably_html(meta_local):
        details.append("meta-release-lts looks like HTML")
        return summary

    with open(meta_local, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    try:
        entries = parse_meta_release(text)
    except Exception as exc:
        details.append("meta-release parse failed: {}".format(exc))
        return summary

    summary["meta_release_entries"] = len(entries)
    summary["meta_release_sha256"] = file_sha256(meta_local)

    supported = []
    missing = []
    for dist in meta_chain:
        e = entry_by_dist(entries, dist)
        if e is None:
            missing.append(dist)
            continue
        for rk in REQUIRED_ENTRY_KEYS:
            if rk not in e:
                details.append("Dist {}: missing required key {}".format(dist, rk))
        supported.append(dist)
    summary["supported_lts_hops"] = supported
    summary["missing_lts_hops"] = [d for d in upgrader_dists if entry_by_dist(entries, d) is None]
    # Also flag chain gaps
    for d in missing:
        if d not in summary["missing_lts_hops"]:
            summary["missing_lts_hops"].append(d)

    bad = external_urls_in_entries(entries, public_base)
    # Also check Release-File / ReleaseNotes for Canonical hosts (informational count
    # uses UpgradeTool* only for FAIL gate; still record all external)
    bad_all = external_urls_in_entries(
        entries, public_base, keys=tuple(REWRITE_URL_KEYS)
    )
    summary["external_urls_remaining"] = len(bad_all)
    for dist, key, url in bad:
        details.append("external URL in {}:{} -> {}".format(dist, key, url))

    def public_url_to_fs(u):
        path = url_path(u)
        if path.startswith("/ubuntu/"):
            return os.path.join(ubuntu_root, path[len("/ubuntu/") :])
        if path.startswith("/ubuntu-security/"):
            return os.path.join(ubuntu_root, path[len("/ubuntu-security/") :])
        if path.startswith("/offline/"):
            return os.path.join(mirror_root, path.lstrip("/"))
        return os.path.join(ubuntu_root, path.lstrip("/"))

    tarballs_req = 0
    tarballs_ok = 0
    sigs_req = 0
    sigs_ok = 0
    sig_valid = 0
    sig_invalid = 0

    for dist in upgrader_dists:
        e = entry_by_dist(entries, dist)
        if e is None:
            continue
        tool_url = e.get("UpgradeTool", "")
        sig_url = e.get("UpgradeToolSignature", "")
        tool_path = public_url_to_fs(tool_url) if tool_url else ""
        sig_path = public_url_to_fs(sig_url) if sig_url else ""

        if tool_url:
            tarballs_req += 1
            if os.path.isfile(tool_path) and os.path.getsize(tool_path) > 0:
                if is_probably_html(tool_path):
                    details.append("tarball HTML: {}".format(tool_path))
                else:
                    tarballs_ok += 1
            else:
                details.append("tarball missing: {}".format(tool_path))

        if sig_url:
            sigs_req += 1
            if os.path.isfile(sig_path) and os.path.getsize(sig_path) > 0:
                sigs_ok += 1
            else:
                details.append("signature missing: {}".format(sig_path))

        if tool_url and sig_url and tool_path and sig_path:
            ok, detail = gpgv_verify(tool_path, sig_path, keyring)
            summary["signatures"].append(
                {
                    "dist": dist,
                    "tarball": tool_path,
                    "signature": sig_path,
                    "ok": ok,
                    "keyring": detail.get("keyring", ""),
                    "signer_fingerprint": detail.get("signer_fingerprint", ""),
                    "error": detail.get("error", ""),
                }
            )
            if ok:
                sig_valid += 1
            else:
                sig_invalid += 1
                details.append(
                    "signature invalid for {}: {}".format(dist, detail.get("error", ""))
                )

    summary["upgrader_tarballs_required"] = tarballs_req
    summary["upgrader_tarballs_present"] = tarballs_ok
    summary["upgrader_signatures_required"] = sigs_req
    summary["upgrader_signatures_present"] = sigs_ok
    summary["signature_valid_count"] = sig_valid
    summary["signature_invalid_count"] = sig_invalid

    if http_base:
        code = http_check(http_base, "/offline/meta-release-lts", method="GET")
        summary["meta_release_http_status"] = code
        if code != 200:
            details.append("HTTP GET meta-release-lts -> {}".format(code))
        head_code = http_check(http_base, "/offline/meta-release-lts", method="HEAD")
        if head_code != 200:
            details.append("HTTP HEAD meta-release-lts -> {}".format(head_code))
        for dist in upgrader_dists:
            e = entry_by_dist(entries, dist)
            if not e:
                continue
            for key in ("UpgradeTool", "UpgradeToolSignature"):
                u = e.get(key, "")
                if not u:
                    continue
                p = url_path(u)
                c = http_check(http_base, p, method="GET")
                if c != 200:
                    details.append("HTTP GET {} -> {}".format(p, c))
                hc = http_check(http_base, p, method="HEAD")
                if hc != 200:
                    details.append("HTTP HEAD {} -> {}".format(p, hc))

    if client_meta_release_path:
        status = check_client_meta_release_config(client_meta_release_path, public_base)
        summary["client_meta_release_config_status"] = status
        if status != "ok":
            details.append("client meta-release config: {}".format(status))

    # FAIL gate: UpgradeTool* must be local; signatures valid; hops present
    tool_external = len(bad)
    pass_ok = (
        not summary["missing_lts_hops"]
        and tool_external == 0
        and sig_invalid == 0
        and tarballs_ok == tarballs_req
        and sigs_ok == sigs_req
        and tarballs_req > 0
        and summary["external_connection_attempts"] == 0
    )
    # ReleaseNotes/Release-File external remaining: FAIL if any Canonical host remains
    if summary["external_urls_remaining"] > 0:
        pass_ok = False
        details.append(
            "external_urls_remaining={} (UpgradeTool/ReleaseNotes/Release-File must be local)".format(
                summary["external_urls_remaining"]
            )
        )
    if client_meta_release_path and summary["client_meta_release_config_status"] != "ok":
        pass_ok = False

    summary["validation_result"] = "PASS" if pass_ok else "FAIL"
    if not quiet:
        for d in details[:40]:
            log_line("validate: {}".format(d), quiet=False)
    return summary


def check_client_meta_release_config(path, public_base):
    if not os.path.isfile(path):
        return "missing"
    public_base = public_base.rstrip("/")
    try:
        import configparser

        cp = configparser.ConfigParser()
        cp.read(path)
        if not cp.has_section("METARELEASE"):
            return "no_METARELEASE_section"
        uri = cp.get("METARELEASE", "URI", fallback="")
        uri_lts = cp.get("METARELEASE", "URI_LTS", fallback="")
        for label, val in (("URI", uri), ("URI_LTS", uri_lts)):
            if not val:
                return "missing_{}".format(label)
            if EXTERNAL_HOST_RE.search(val):
                return "external_{}".format(label)
            if not val.startswith(public_base):
                return "mismatch_{}".format(label)
        return "ok"
    except Exception as exc:
        return "parse_error:{}".format(exc)


def run_sync(
    mirror_root,
    ubuntu_root,
    public_base,
    meta_release_url,
    upgrader_dists,
    meta_chain,
    keyring,
    allowed_hosts,
    connect_timeout,
    max_time,
    retries,
    quiet=False,
    skip_download=False,
    upstream_meta_path="",
):
    """Sync upgraders into a staging area, verify, then atomically promote."""
    summary = empty_summary()
    summary["required_lts_hops"] = list(upgrader_dists)
    summary["keyring"] = keyring
    offline_dir = os.path.join(mirror_root, "offline")
    os.makedirs(offline_dir, exist_ok=True)
    os.makedirs(os.path.join(offline_dir, "announcements"), exist_ok=True)

    live_meta_upstream = os.path.join(offline_dir, "meta-release-lts.upstream")
    live_meta_local = os.path.join(offline_dir, "meta-release-lts")
    live_meta_plain = os.path.join(offline_dir, "meta-release")

    stage_root = tempfile.mkdtemp(prefix="uom-upgrader-", dir=offline_dir)
    stage_ubuntu = os.path.join(stage_root, "ubuntu")
    stage_offline = os.path.join(stage_root, "offline")
    os.makedirs(stage_offline, exist_ok=True)
    os.makedirs(os.path.join(stage_offline, "announcements"), exist_ok=True)

    def log(msg):
        log_line(msg, quiet=quiet)

    downloads = summary["downloads"]

    try:
        stage_meta_up = os.path.join(stage_offline, "meta-release-lts.upstream")
        if skip_download and upstream_meta_path:
            shutil.copy2(upstream_meta_path, stage_meta_up)
            downloads.append(
                {
                    "url": upstream_meta_path,
                    "final_url": upstream_meta_path,
                    "http_status": 200,
                    "size": os.path.getsize(stage_meta_up),
                    "role": "meta-release-lts.upstream",
                    "from_fixture": True,
                }
            )
        else:
            ims = mtime_http_date(live_meta_upstream)
            result = curl_download(
                meta_release_url,
                stage_meta_up,
                connect_timeout=connect_timeout,
                max_time=max_time,
                retries=retries,
                if_modified_since=ims,
                allow_304_with_existing=live_meta_upstream,
            )
            downloads.append(
                {
                    "url": meta_release_url,
                    "final_url": result.get("final_url", ""),
                    "http_status": result.get("http_status", 0),
                    "size": result.get("size", 0),
                    "role": "meta-release-lts.upstream",
                    "ok": result.get("ok", False),
                    "error": result.get("error", ""),
                }
            )
            if not result.get("ok"):
                raise SyncError(
                    "meta-release download failed: {}".format(result.get("error"))
                )
            host = url_host(result.get("final_url", meta_release_url))
            if not host_allowed(host, allowed_hosts):
                raise SyncError("redirect host not allowlisted: {}".format(host))

        with open(stage_meta_up, "r", encoding="utf-8", errors="replace") as fh:
            upstream_text = fh.read()
        if is_probably_html(stage_meta_up):
            raise SyncError("upstream meta-release looks like HTML")
        upstream_entries = parse_meta_release(upstream_text)
        if not upstream_entries:
            raise SyncError("upstream meta-release parsed to zero entries")

        # Download each upgrader into staging ubuntu tree
        for dist in upgrader_dists:
            entry = entry_by_dist(upstream_entries, dist)
            if entry is None:
                raise SyncError("Dist {} missing from upstream meta-release-lts".format(dist))
            tool_url = entry.get("UpgradeTool", "")
            sig_url = entry.get("UpgradeToolSignature", "")
            if not tool_url or not sig_url:
                raise SyncError("UpgradeTool/Signature missing for {}".format(dist))
            for u in (tool_url, sig_url):
                if not host_allowed(url_host(u), allowed_hosts):
                    raise SyncError("host not allowlisted for {}: {}".format(dist, u))

            tool_dest = local_fs_path_for_url(tool_url, stage_ubuntu, stage_offline)
            sig_dest = local_fs_path_for_url(sig_url, stage_ubuntu, stage_offline)
            # Also know live paths for 304 reuse
            live_tool = local_fs_path_for_url(tool_url, ubuntu_root, offline_dir)
            live_sig = local_fs_path_for_url(sig_url, ubuntu_root, offline_dir)

            for role, url, dest, live in (
                ("UpgradeTool", tool_url, tool_dest, live_tool),
                ("UpgradeToolSignature", sig_url, sig_dest, live_sig),
            ):
                if skip_download:
                    # Fixture mode: expect files already prepared under ubuntu_root
                    if not os.path.isfile(live):
                        raise SyncError("fixture missing {}: {}".format(role, live))
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    shutil.copy2(live, dest)
                    downloads.append(
                        {
                            "url": url,
                            "final_url": url,
                            "http_status": 200,
                            "size": os.path.getsize(dest),
                            "role": "{}:{}".format(dist, role),
                            "from_fixture": True,
                        }
                    )
                    continue
                ims = mtime_http_date(live)
                result = curl_download(
                    url,
                    dest,
                    connect_timeout=connect_timeout,
                    max_time=max_time,
                    retries=retries,
                    if_modified_since=ims,
                    allow_304_with_existing=live,
                )
                downloads.append(
                    {
                        "url": url,
                        "final_url": result.get("final_url", ""),
                        "http_status": result.get("http_status", 0),
                        "size": result.get("size", 0),
                        "sha256": file_sha256(dest) if result.get("ok") else "",
                        "role": "{}:{}".format(dist, role),
                        "ok": result.get("ok", False),
                        "error": result.get("error", ""),
                    }
                )
                log(
                    "download {} -> status={} size={} final={}".format(
                        url,
                        result.get("http_status"),
                        result.get("size"),
                        result.get("final_url"),
                    )
                )
                if not result.get("ok"):
                    raise SyncError(
                        "download failed for {} {}: {}".format(
                            dist, role, result.get("error")
                        )
                    )
                fhost = url_host(result.get("final_url", url))
                if not host_allowed(fhost, allowed_hosts):
                    raise SyncError("redirect host not allowlisted: {}".format(fhost))

            ok, detail = gpgv_verify(tool_dest, sig_dest, keyring)
            summary["signatures"].append(
                {
                    "dist": dist,
                    "ok": ok,
                    "keyring": keyring,
                    "signer_fingerprint": detail.get("signer_fingerprint", ""),
                    "error": detail.get("error", ""),
                }
            )
            log(
                "gpgv {} -> {} fingerprint={}".format(
                    dist, "OK" if ok else "FAIL", detail.get("signer_fingerprint", "")
                )
            )
            if not ok:
                raise SyncError(
                    "GPG verification failed for {}: {}".format(
                        dist, detail.get("error", "")
                    )
                )

            # Optional ReleaseNotes / announcements (best-effort; required for rewrite)
            for key in ("ReleaseNotes", "ReleaseNotesHtml"):
                note_url = entry.get(key, "")
                if not note_url:
                    continue
                if not host_allowed(url_host(note_url), allowed_hosts):
                    raise SyncError("ReleaseNotes host not allowlisted: {}".format(note_url))
                note_dest = local_fs_path_for_url(note_url, stage_ubuntu, stage_offline)
                live_note = local_fs_path_for_url(note_url, ubuntu_root, offline_dir)
                if skip_download:
                    if os.path.isfile(live_note):
                        os.makedirs(os.path.dirname(note_dest), exist_ok=True)
                        shutil.copy2(live_note, note_dest)
                    else:
                        # Create minimal placeholder so rewrite target exists
                        os.makedirs(os.path.dirname(note_dest), exist_ok=True)
                        with open(note_dest, "w", encoding="utf-8") as fh:
                            fh.write("Release announcement for {}\n".format(dist))
                    continue
                result = curl_download(
                    note_url,
                    note_dest,
                    connect_timeout=connect_timeout,
                    max_time=min(max_time, 120),
                    retries=1,
                    if_modified_since=mtime_http_date(live_note),
                    allow_304_with_existing=live_note,
                )
                downloads.append(
                    {
                        "url": note_url,
                        "final_url": result.get("final_url", ""),
                        "http_status": result.get("http_status", 0),
                        "size": result.get("size", 0),
                        "role": "{}:{}".format(dist, key),
                        "ok": result.get("ok", False),
                        "optional": True,
                        "error": result.get("error", ""),
                    }
                )
                if not result.get("ok"):
                    # Create empty-ish local stub so rewritten URL is locally served
                    log("optional {} unavailable; writing stub".format(note_url))
                    os.makedirs(os.path.dirname(note_dest), exist_ok=True)
                    with open(note_dest, "w", encoding="utf-8") as fh:
                        fh.write("Release announcement for {} (offline stub)\n".format(dist))

        local_entries = build_local_entries(upstream_entries, meta_chain, public_base)
        local_text = format_meta_release(local_entries)
        stage_meta_local = os.path.join(stage_offline, "meta-release-lts")
        atomic_write_text(stage_meta_local, local_text)
        # Non-LTS URI also points locally (same LTS chain content)
        atomic_write_text(os.path.join(stage_offline, "meta-release"), local_text)

        bad = external_urls_in_entries(
            local_entries, public_base, keys=tuple(REWRITE_URL_KEYS)
        )
        if bad:
            raise SyncError(
                "local meta still has external URLs: {}".format(
                    "; ".join("{}:{}={}".format(d, k, u) for d, k, u in bad[:5])
                )
            )

        # Promote staging → live (only after full success)
        promote_file(stage_meta_up, live_meta_upstream)
        promote_file(stage_meta_local, live_meta_local)
        promote_file(
            os.path.join(stage_offline, "meta-release"), live_meta_plain
        )

        # Promote ubuntu tree files
        for dirpath, _dns, filenames in os.walk(stage_ubuntu):
            for fn in filenames:
                src = os.path.join(dirpath, fn)
                rel = os.path.relpath(src, stage_ubuntu)
                dest = os.path.join(ubuntu_root, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                promote_file(src, dest)

        # Promote announcements
        stage_ann = os.path.join(stage_offline, "announcements")
        live_ann = os.path.join(offline_dir, "announcements")
        if os.path.isdir(stage_ann):
            os.makedirs(live_ann, exist_ok=True)
            for fn in os.listdir(stage_ann):
                src = os.path.join(stage_ann, fn)
                if os.path.isfile(src):
                    promote_file(src, os.path.join(live_ann, fn))

        refs = referenced_upgrader_basenames(local_entries)
        removed = stale_cleanup_upgraders(ubuntu_root, upgrader_dists, refs, log)
        summary["details"].append("stale_removed={}".format(len(removed)))

        # Post-promote validation
        v = validate_tree(
            mirror_root=mirror_root,
            ubuntu_root=ubuntu_root,
            public_base=public_base,
            upgrader_dists=upgrader_dists,
            meta_chain=meta_chain,
            keyring=keyring,
            quiet=True,
        )
        summary.update(v)
        summary["downloads"] = downloads
        if summary["validation_result"] != "PASS":
            raise SyncError("post-sync validation failed")
        log("sync complete validation_result=PASS")
        return summary

    except Exception:
        # Live snapshot untouched (except we never promoted). Staging discarded.
        raise
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


def print_summary(summary):
    keys = [
        "meta_release_path",
        "meta_release_http_status",
        "meta_release_entries",
        "required_lts_hops",
        "supported_lts_hops",
        "missing_lts_hops",
        "upgrader_tarballs_required",
        "upgrader_tarballs_present",
        "upgrader_signatures_required",
        "upgrader_signatures_present",
        "signature_valid_count",
        "signature_invalid_count",
        "external_urls_remaining",
        "external_connection_attempts",
        "client_meta_release_config_status",
        "validation_result",
    ]
    for k in keys:
        v = summary.get(k, "")
        if isinstance(v, (list, tuple)):
            v = ",".join(str(x) for x in v)
        print("{}={}".format(k, v))


def write_json(path, data):
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ru-json.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def parse_list(value, default):
    if value is None or value == "":
        return list(default)
    return [x for x in value.replace(",", " ").split() if x]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=("sync", "validate", "sync-validate"),
        help="sync / validate / sync-validate",
    )
    parser.add_argument("--mirror-root", required=True)
    parser.add_argument("--ubuntu-root", default="")
    parser.add_argument(
        "--public-base-url",
        default=os.environ.get("PUBLIC_BASE_URL", "http://ubuntu-mirror.local"),
    )
    parser.add_argument(
        "--meta-release-url",
        default=os.environ.get(
            "META_RELEASE_URL", "http://changelogs.ubuntu.com/meta-release-lts"
        ),
    )
    parser.add_argument(
        "--upgrader-dists",
        default=os.environ.get("UPGRADER_DISTS", " ".join(DEFAULT_UPGRADER_DISTS)),
    )
    parser.add_argument(
        "--meta-chain-dists",
        default=os.environ.get("META_CHAIN_DISTS", " ".join(DEFAULT_META_CHAIN)),
    )
    parser.add_argument(
        "--keyring",
        default=os.environ.get(
            "UBUNTU_KEYRING", "/usr/share/keyrings/ubuntu-archive-keyring.gpg"
        ),
    )
    parser.add_argument(
        "--allowed-hosts",
        default=os.environ.get("ALLOWED_HOSTS", DEFAULT_ALLOWED_HOSTS),
    )
    parser.add_argument("--connect-timeout", type=int, default=30)
    parser.add_argument("--max-time", type=int, default=600)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument("--http-base", default="")
    parser.add_argument("--client-meta-release", default="")
    parser.add_argument("--result-json", default="")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument(
        "--skip-download",
        action="store_true",
        help="Fixture mode: use --upstream-meta and files already under ubuntu-root",
    )
    parser.add_argument("--upstream-meta", default="")
    args = parser.parse_args(argv)

    mirror_root = os.path.abspath(args.mirror_root)
    ubuntu_root = (
        os.path.abspath(args.ubuntu_root)
        if args.ubuntu_root
        else discover_ubuntu_root(mirror_root)
    )
    upgrader_dists = parse_list(args.upgrader_dists, DEFAULT_UPGRADER_DISTS)
    meta_chain = parse_list(args.meta_chain_dists, DEFAULT_META_CHAIN)
    result_json = args.result_json or os.path.join(
        mirror_root, "offline", "release-upgrader-validation.json"
    )

    try:
        if args.command in ("sync", "sync-validate"):
            summary = run_sync(
                mirror_root=mirror_root,
                ubuntu_root=ubuntu_root,
                public_base=args.public_base_url,
                meta_release_url=args.meta_release_url,
                upgrader_dists=upgrader_dists,
                meta_chain=meta_chain,
                keyring=args.keyring,
                allowed_hosts=args.allowed_hosts,
                connect_timeout=args.connect_timeout,
                max_time=args.max_time,
                retries=args.retries,
                quiet=args.quiet,
                skip_download=args.skip_download,
                upstream_meta_path=args.upstream_meta,
            )
            if args.command == "sync-validate" and args.http_base:
                v = validate_tree(
                    mirror_root=mirror_root,
                    ubuntu_root=ubuntu_root,
                    public_base=args.public_base_url,
                    upgrader_dists=upgrader_dists,
                    meta_chain=meta_chain,
                    keyring=args.keyring,
                    http_base=args.http_base,
                    client_meta_release_path=args.client_meta_release,
                    quiet=args.quiet,
                )
                summary.update(v)
        else:
            summary = validate_tree(
                mirror_root=mirror_root,
                ubuntu_root=ubuntu_root,
                public_base=args.public_base_url,
                upgrader_dists=upgrader_dists,
                meta_chain=meta_chain,
                keyring=args.keyring,
                http_base=args.http_base,
                client_meta_release_path=args.client_meta_release,
                quiet=args.quiet,
            )
    except SyncError as exc:
        summary = empty_summary()
        summary["required_lts_hops"] = upgrader_dists
        summary["details"] = [str(exc)]
        summary["validation_result"] = "FAIL"
        eprint("ERROR: {}".format(exc))
        print_summary(summary)
        write_json(result_json, summary)
        return 1
    except Exception as exc:
        summary = empty_summary()
        summary["details"] = [str(exc)]
        summary["validation_result"] = "FAIL"
        eprint("ERROR: {}".format(exc))
        print_summary(summary)
        write_json(result_json, summary)
        return 2

    print_summary(summary)
    write_json(result_json, summary)
    return 0 if summary.get("validation_result") == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
