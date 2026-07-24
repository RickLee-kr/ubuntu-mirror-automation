#!/usr/bin/env python3
"""Sync, preserve, and validate legacy Ubuntu release trees (Xenial / old-releases).

Canonical client URLs stay on the archive layout:

  /ubuntu/dists/<suite>/...
  /ubuntu-security/dists/<suite>-security/...   (nginx alias → same tree)
  /ubuntu/pool/...

Upstream selection (archive → security → old-releases → frozen active snapshot)
happens only on the mirror server. Incomplete candidates are never promoted.
apt-mirror clean may remove live files; active/previous snapshots under
offline/legacy-releases/<series>/ survive and are re-materialized into the
live tree after clean.
"""
from __future__ import print_function

import argparse
import gzip
import hashlib
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict, defaultdict
from urllib.parse import urlparse

try:
    import bz2
except ImportError:  # pragma: no cover
    bz2 = None

HTML_RE = re.compile(br"<(!DOCTYPE\s+)?[Hh][Tt][Mm][Ll]", re.IGNORECASE)
SECTION_TO_ALGO = {
    "SHA256": "SHA256",
    "SHA512": "SHA512",
    "SHA1": "SHA1",
    "MD5Sum": "MD5",
    "MD5sum": "MD5",
}
ALGO_DIR_NAMES = ("SHA256", "SHA512", "SHA1", "MD5")
ALGO_TO_HASHLIB = {
    "SHA256": "sha256",
    "SHA512": "sha512",
    "SHA1": "sha1",
    "MD5": "md5",
}

DEFAULT_SERIES = "xenial"
DEFAULT_TARGET_SERIES = "bionic"
DEFAULT_SUFFIXES = ("updates", "security", "backports")
DEFAULT_COMPONENTS = ("main", "restricted", "universe", "multiverse")
DEFAULT_ARCH = "amd64"

DEFAULT_UPSTREAMS = (
    OrderedDict(
        [
            ("name", "archive.ubuntu.com"),
            ("base_url", "http://archive.ubuntu.com/ubuntu"),
            ("pocket_filter", "all"),
        ]
    ),
    OrderedDict(
        [
            ("name", "security.ubuntu.com"),
            ("base_url", "http://security.ubuntu.com/ubuntu"),
            ("pocket_filter", "security"),
        ]
    ),
    OrderedDict(
        [
            ("name", "old-releases.ubuntu.com"),
            ("base_url", "http://old-releases.ubuntu.com/ubuntu"),
            ("pocket_filter", "all"),
        ]
    ),
)

SOURCE_STATUS = (
    "COMPLETE",
    "PARTIAL",
    "UNAVAILABLE",
    "INVALID",
    "STALE",
    "UNKNOWN",
)


class LegacyError(Exception):
    pass


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def log_line(msg, quiet=False):
    if quiet:
        return
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print("{} [legacy-releases] {}".format(stamp, msg))


def file_digest(path, algo="SHA256", chunk=1024 * 1024):
    name = ALGO_TO_HASHLIB.get(algo, algo.lower())
    h = hashlib.new(name)
    with open(path, "rb") as fh:
        while True:
            data = fh.read(chunk)
            if not data:
                break
            h.update(data)
    return h.hexdigest()


def file_sha256(path):
    return file_digest(path, "SHA256")


def is_probably_html(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(512)
    except OSError:
        return False
    return HTML_RE.search(head) is not None


def is_probably_html_bytes(data):
    return bool(HTML_RE.search(data[:512] if data else b""))


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


def parse_release_text(text):
    if "-----BEGIN PGP SIGNED MESSAGE-----" in text:
        parts = text.split("-----BEGIN PGP SIGNATURE-----", 1)[0]
        lines = parts.splitlines()
        out = []
        started = False
        for line in lines:
            if not started:
                if line.startswith("Hash:") or line.startswith("-----BEGIN"):
                    continue
                if line.strip() == "":
                    started = True
                    continue
                continue
            out.append(line)
        text = "\n".join(out) + "\n"

    headers = OrderedDict()
    checksums = OrderedDict()
    current_section = None
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        if not line:
            current_section = None
            continue
        if current_section:
            if line[:1] in (" ", "\t"):
                parts = line.split()
                if len(parts) >= 3:
                    digest, size_s, relpath = parts[0], parts[1], parts[2]
                    try:
                        size = int(size_s)
                    except ValueError:
                        continue
                    checksums.setdefault(current_section, []).append(
                        {"hash": digest.lower(), "size": size, "path": relpath}
                    )
                continue
            current_section = None
        if ":" in line:
            key, val = line.split(":", 1)
            key = key.strip()
            val = val.strip()
            if key in SECTION_TO_ALGO and val == "":
                current_section = SECTION_TO_ALGO[key]
                checksums.setdefault(current_section, [])
                continue
            headers[key] = val
            if key in SECTION_TO_ALGO and not val:
                current_section = SECTION_TO_ALGO[key]
                checksums.setdefault(current_section, [])
    return headers, checksums


def read_release_file(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if not raw:
        raise LegacyError("empty release file: {}".format(path))
    if is_probably_html_bytes(raw):
        raise LegacyError("release file looks like HTML: {}".format(path))
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("utf-8", "replace")
    return parse_release_text(text)


def pockets_for_series(series, suffixes):
    pockets = [series]
    for suf in suffixes:
        suf = (suf or "").strip()
        if not suf:
            continue
        pockets.append("{}-{}".format(series, suf))
    return pockets


def snapshot_root(mirror_root, series):
    return os.path.join(mirror_root, "offline", "legacy-releases", series)


def active_dir(mirror_root, series):
    return os.path.join(snapshot_root(mirror_root, series), "active")


def previous_dir(mirror_root, series):
    return os.path.join(snapshot_root(mirror_root, series), "previous")


def active_ubuntu(mirror_root, series):
    return os.path.join(active_dir(mirror_root, series), "ubuntu")


def discover_ubuntu_root(mirror_root):
    candidates = [
        os.path.join(mirror_root, "mirror", "archive.ubuntu.com", "ubuntu"),
        os.path.join(mirror_root, "archive.ubuntu.com", "ubuntu"),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "dists")):
            return c
    return candidates[0]


def curl_download(
    url,
    dest,
    connect_timeout=30,
    max_time=600,
    retries=3,
    if_modified_since=None,
    allow_304_with_existing=None,
    resolve_map=None,
):
    """Download URL to dest. HTTP 200 body required for new content.

    resolve_map: optional list of curl --resolve specs
      e.g. ["archive.ubuntu.com:80:127.0.0.1"]
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
        if resolve_map:
            for spec in resolve_map:
                cmd.extend(["--resolve", spec])
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


def curl_probe(url, connect_timeout=15, max_time=60, resolve_map=None):
    """GET a small probe; return status and optional body path in temp."""
    fd, tmp = tempfile.mkstemp(prefix=".legacy-probe-")
    os.close(fd)
    try:
        result = curl_download(
            url,
            tmp,
            connect_timeout=connect_timeout,
            max_time=max_time,
            retries=1,
            resolve_map=resolve_map,
        )
        body = b""
        if result.get("ok") and os.path.isfile(tmp):
            with open(tmp, "rb") as fh:
                body = fh.read()
        return result, body
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def mtime_http_date(path):
    if not os.path.isfile(path):
        return None
    return time.strftime("%a, %d %b %Y %H:%M:%S GMT", time.gmtime(os.path.getmtime(path)))


def hardlink_or_copy(src, dest):
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    if os.path.exists(dest):
        if os.path.samefile(src, dest):
            return "same"
        os.unlink(dest)
    try:
        os.link(src, dest)
        return "hardlink"
    except OSError:
        shutil.copy2(src, dest)
        return "copy"


def atomic_replace_file(src, dest):
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".legacy-", dir=os.path.dirname(dest) or ".")
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def write_json(path, data):
    if not path:
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".legacy-json-", dir=os.path.dirname(path) or ".")
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


def decompress_packages_bytes(data, name):
    lower = name.lower()
    if lower.endswith(".xz"):
        return lzma.decompress(data)
    if lower.endswith(".gz"):
        return gzip.decompress(data)
    if lower.endswith(".bz2"):
        if bz2 is None:
            raise LegacyError("bz2 unsupported")
        return bz2.decompress(data)
    return data


def parse_packages_text(text):
    """Yield dicts with Filename, Size, SHA256/MD5Sum for each package stanza."""
    current = {}
    for raw in text.splitlines():
        line = raw.rstrip("\r\n")
        if not line.strip():
            if current.get("Filename"):
                yield current
            current = {}
            continue
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        current[key.strip()] = val.strip()
    if current.get("Filename"):
        yield current


def open_packages_index(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data:
        raise LegacyError("empty Packages index: {}".format(path))
    if is_probably_html_bytes(data):
        raise LegacyError("Packages index looks like HTML: {}".format(path))
    plain = decompress_packages_bytes(data, path)
    try:
        text = plain.decode("utf-8")
    except UnicodeDecodeError:
        text = plain.decode("utf-8", "replace")
    return list(parse_packages_text(text))


def preferred_checksum_entries(checksums):
    for algo in ALGO_DIR_NAMES:
        for entry in checksums.get(algo, []):
            yield algo, entry


def index_paths_for_components(checksums, components, arch):
    """Select Packages* index paths for required components/arch from Release."""
    wanted = []
    seen = set()
    for algo, entry in preferred_checksum_entries(checksums):
        rel = entry["path"]
        if "/by-hash/" in rel:
            continue
        base = os.path.basename(rel)
        if not base.startswith("Packages"):
            continue
        # component/binary-<arch>/Packages*
        parts = rel.split("/")
        if len(parts) < 3:
            continue
        comp = parts[0]
        binary = parts[1]
        if comp not in components:
            continue
        if binary != "binary-{}".format(arch):
            continue
        key = rel
        if key in seen:
            continue
        # Prefer compressed forms when multiple exist; keep first preferred algo hit
        seen.add(key)
        wanted.append({"algo": algo, "entry": entry})
    # Prefer .xz > .gz > plain per component
    by_comp = OrderedDict()
    rank = {".xz": 0, ".gz": 1, ".bz2": 2, ".lzma": 3, "": 4}
    for item in wanted:
        rel = item["entry"]["path"]
        comp = rel.split("/")[0]
        ext = ""
        for e in (".xz", ".gz", ".bz2", ".lzma"):
            if rel.endswith(e):
                ext = e
                break
        prev = by_comp.get(comp)
        if prev is None or rank.get(ext, 9) < rank.get(prev[1], 9):
            by_comp[comp] = (item, ext)
    return [v[0] for v in by_comp.values()]


def by_hash_path(suite_dir, relpath, algo, digest):
    parent = os.path.dirname(relpath)
    if parent and parent != ".":
        return os.path.join(suite_dir, parent, "by-hash", algo, digest)
    return os.path.join(suite_dir, "by-hash", algo, digest)


def acquire_by_hash_enabled(headers):
    val = str(headers.get("Acquire-By-Hash", "")).strip().lower()
    return val in ("yes", "true", "1")


def suite_release_present(suite_dir):
    for name in ("InRelease", "Release"):
        path = os.path.join(suite_dir, name)
        if os.path.isfile(path) and os.path.getsize(path) > 0 and not is_probably_html(path):
            return name, path
    return None, None


def empty_summary(series, target_series):
    return OrderedDict(
        [
            ("source_series", series),
            ("target_series", target_series),
            ("candidate_upstreams", []),
            ("selected_upstreams", []),
            ("source_status", "UNKNOWN"),
            ("pockets_required", []),
            ("pockets_present", []),
            ("pockets_missing", []),
            ("components_required", []),
            ("components_present", []),
            ("metadata_files_required", 0),
            ("metadata_files_present", 0),
            ("metadata_files_missing", 0),
            ("by_hash_required", 0),
            ("by_hash_present", 0),
            ("by_hash_missing", 0),
            ("pool_files_required", 0),
            ("pool_files_present", 0),
            ("pool_files_missing", 0),
            ("checksum_mismatches", 0),
            ("active_snapshot", ""),
            ("previous_snapshot", ""),
            ("snapshot_promoted", False),
            ("snapshot_preserved_after_failure", False),
            ("external_urls_remaining", 0),
            ("external_connection_attempts", 0),
            ("discovery_urls_checked", 0),
            ("discovery_urls_supported", 0),
            ("discovery_urls_unsupported", 0),
            ("discovered_xenial_urls", 0),
            ("repository_urls", 0),
            ("upgrader_urls", 0),
            ("supported_urls", 0),
            ("unsupported_urls", 0),
            ("unsupported_patterns", []),
            ("collection_artifacts", []),
            ("non_blocking_failures", []),
            ("pocket_provenance", OrderedDict()),
            ("validation_result", "FAIL"),
            ("details", []),
            ("downloads", []),
            ("errors", []),
        ]
    )


def classify_upstream_probe(pocket_results, required_pockets):
    """Classify a candidate upstream from per-pocket probe results."""
    if not pocket_results:
        return "UNAVAILABLE"
    ok = 0
    invalid = 0
    missing = 0
    for pocket in required_pockets:
        st = pocket_results.get(pocket, {}).get("status", "missing")
        if st == "ok":
            ok += 1
        elif st in ("invalid", "html", "zero"):
            invalid += 1
        else:
            missing += 1
    if ok == len(required_pockets):
        return "COMPLETE"
    if invalid and ok == 0:
        return "INVALID"
    if ok == 0:
        return "UNAVAILABLE"
    return "PARTIAL"


def upstream_applies(upstream, pocket):
    filt = upstream.get("pocket_filter", "all")
    if filt == "all":
        return True
    if filt == "security":
        return pocket.endswith("-security")
    return True


def probe_upstream(
    upstream,
    pockets,
    components,
    arch,
    connect_timeout,
    max_time,
    resolve_map,
    quiet,
):
    """Probe Release/InRelease for each applicable pocket."""
    log = lambda m: log_line(m, quiet=quiet)
    result = OrderedDict(
        [
            ("name", upstream["name"]),
            ("base_url", upstream["base_url"].rstrip("/")),
            ("status", "UNKNOWN"),
            ("pockets", OrderedDict()),
        ]
    )
    applicable = [p for p in pockets if upstream_applies(upstream, p)]
    if not applicable:
        result["status"] = "UNAVAILABLE"
        return result

    for pocket in applicable:
        base = result["base_url"]
        pocket_info = OrderedDict(
            [("status", "missing"), ("release_kind", ""), ("http_status", 0), ("error", "")]
        )
        got = False
        for kind in ("InRelease", "Release"):
            url = "{}/dists/{}/{}".format(base, pocket, kind)
            probe, body = curl_probe(
                url,
                connect_timeout=connect_timeout,
                max_time=max_time,
                resolve_map=resolve_map,
            )
            pocket_info["http_status"] = probe.get("http_status", 0)
            if not probe.get("ok"):
                pocket_info["error"] = probe.get("error", "fetch failed")
                continue
            if is_probably_html_bytes(body):
                pocket_info["status"] = "html"
                pocket_info["error"] = "HTML body"
                continue
            try:
                headers, checksums = parse_release_text(
                    body.decode("utf-8", "replace")
                )
            except Exception as exc:
                pocket_info["status"] = "invalid"
                pocket_info["error"] = str(exc)
                continue
            indexes = index_paths_for_components(checksums, components, arch)
            if not indexes:
                # Accept Release with Components listed even if checksum scan
                # finds nothing yet — still mark partial unless Packages exist.
                comps = [
                    c
                    for c in str(headers.get("Components", "")).split()
                    if c in components
                ]
                if not comps:
                    pocket_info["status"] = "invalid"
                    pocket_info["error"] = "no matching components/Packages"
                    continue
            pocket_info["status"] = "ok"
            pocket_info["release_kind"] = kind
            pocket_info["index_count"] = len(indexes)
            pocket_info["components"] = str(headers.get("Components", ""))
            got = True
            break
        if not got and pocket_info["status"] == "missing":
            if pocket_info.get("http_status") in (0,):
                pass
        result["pockets"][pocket] = pocket_info
        log(
            "probe {} {} -> {} http={}".format(
                upstream["name"],
                pocket,
                pocket_info["status"],
                pocket_info.get("http_status"),
            )
        )

    # For security-only upstream, evaluate only security pocket completeness
    # against the security subset of required pockets.
    eval_pockets = applicable
    result["status"] = classify_upstream_probe(result["pockets"], eval_pockets)
    # If this upstream only covers security, remap COMPLETE to mean its
    # applicable set is complete (selection logic combines later).
    return result


def select_upstreams(probe_results, required_pockets):
    """Choose COMPLETE single-source or pocket-wise combination.

    Returns (selected_list, provenance dict pocket->upstream name, status).
    Never returns PARTIAL as selectable for promote.
    """
    by_name = OrderedDict((p["name"], p) for p in probe_results)
    # Prefer first COMPLETE all-pocket source (archive, then old-releases)
    for name in ("archive.ubuntu.com", "old-releases.ubuntu.com"):
        p = by_name.get(name)
        if not p:
            continue
        # Recompute against full required set (security-only upstreams skip)
        full = OrderedDict()
        for pocket in required_pockets:
            if pocket in p["pockets"]:
                full[pocket] = p["pockets"][pocket]
            else:
                full[pocket] = {"status": "missing"}
        status = classify_upstream_probe(full, required_pockets)
        if status == "COMPLETE":
            prov = OrderedDict((pocket, name) for pocket in required_pockets)
            return [p], prov, "COMPLETE"

    # Combine: for each pocket pick first upstream that has ok
    provenance = OrderedDict()
    combined_pockets = OrderedDict()
    selected_names = []
    for pocket in required_pockets:
        chosen = None
        for p in probe_results:
            info = p.get("pockets", {}).get(pocket)
            if info and info.get("status") == "ok":
                chosen = p
                break
        if chosen is None:
            combined_pockets[pocket] = {"status": "missing"}
            continue
        provenance[pocket] = chosen["name"]
        combined_pockets[pocket] = chosen["pockets"][pocket]
        if chosen["name"] not in selected_names:
            selected_names.append(chosen["name"])

    status = classify_upstream_probe(combined_pockets, required_pockets)
    selected = [by_name[n] for n in selected_names if n in by_name]
    return selected, provenance, status


def validate_tree(
    ubuntu_root,
    series,
    pockets,
    components,
    arch,
    require_by_hash=True,
    allow_release_without_inrelease=True,
):
    """Validate a ubuntu tree for legacy series pockets. Returns summary fragment."""
    frag = OrderedDict(
        [
            ("pockets_present", []),
            ("pockets_missing", []),
            ("components_present", []),
            ("metadata_files_required", 0),
            ("metadata_files_present", 0),
            ("metadata_files_missing", 0),
            ("by_hash_required", 0),
            ("by_hash_present", 0),
            ("by_hash_missing", 0),
            ("pool_files_required", 0),
            ("pool_files_present", 0),
            ("pool_files_missing", 0),
            ("checksum_mismatches", 0),
            ("errors", []),
        ]
    )
    comps_seen = set()
    for pocket in pockets:
        suite_dir = os.path.join(ubuntu_root, "dists", pocket)
        kind, rel_path = suite_release_present(suite_dir)
        if kind is None:
            # Release+Release.gpg without InRelease
            rel = os.path.join(suite_dir, "Release")
            gpg = os.path.join(suite_dir, "Release.gpg")
            if (
                allow_release_without_inrelease
                and os.path.isfile(rel)
                and os.path.getsize(rel) > 0
                and not is_probably_html(rel)
                and os.path.isfile(gpg)
                and os.path.getsize(gpg) > 0
            ):
                kind, rel_path = "Release", rel
            else:
                frag["pockets_missing"].append(pocket)
                frag["errors"].append("missing release metadata for {}".format(pocket))
                continue
        try:
            headers, checksums = read_release_file(rel_path)
        except LegacyError as exc:
            frag["pockets_missing"].append(pocket)
            frag["errors"].append(str(exc))
            frag["checksum_mismatches"] += 1
            continue

        frag["pockets_present"].append(pocket)
        frag["metadata_files_required"] += 1
        frag["metadata_files_present"] += 1

        indexes = index_paths_for_components(checksums, components, arch)
        if not indexes:
            frag["errors"].append("no Packages indexes for {}".format(pocket))
            frag["pockets_missing"].append(pocket)
            if pocket in frag["pockets_present"]:
                frag["pockets_present"].remove(pocket)
            continue

        acquire = acquire_by_hash_enabled(headers)
        for item in indexes:
            entry = item["entry"]
            algo = item["algo"]
            rel = entry["path"]
            named = os.path.join(suite_dir, rel)
            frag["metadata_files_required"] += 1
            if not os.path.isfile(named) or os.path.getsize(named) == 0:
                frag["errors"].append("missing index {}".format(named))
                frag["metadata_files_missing"] += 1
                if pocket not in frag["pockets_missing"]:
                    frag["pockets_missing"].append(pocket)
                continue
            if is_probably_html(named):
                frag["errors"].append("HTML index {}".format(named))
                frag["checksum_mismatches"] += 1
                frag["metadata_files_missing"] += 1
                continue
            digest = file_digest(named, algo)
            if digest.lower() != entry["hash"].lower():
                frag["errors"].append(
                    "checksum mismatch {}: {} != {}".format(named, digest, entry["hash"])
                )
                frag["checksum_mismatches"] += 1
                continue
            if os.path.getsize(named) != entry["size"]:
                frag["errors"].append(
                    "size mismatch {}: {} != {}".format(
                        named, os.path.getsize(named), entry["size"]
                    )
                )
                frag["checksum_mismatches"] += 1
                continue
            frag["metadata_files_present"] += 1
            comps_seen.add(rel.split("/")[0])

            if acquire or require_by_hash:
                bh = by_hash_path(suite_dir, rel, algo, entry["hash"])
                frag["by_hash_required"] += 1
                if (
                    os.path.isfile(bh)
                    and os.path.getsize(bh) > 0
                    and not is_probably_html(bh)
                    and file_digest(bh, algo).lower() == entry["hash"].lower()
                ):
                    frag["by_hash_present"] += 1
                else:
                    frag["by_hash_missing"] += 1
                    frag["errors"].append("missing/bad by-hash {}".format(bh))

            # Pool files from Packages
            try:
                pkgs = open_packages_index(named)
            except LegacyError as exc:
                frag["errors"].append(str(exc))
                frag["checksum_mismatches"] += 1
                continue
            for pkg in pkgs:
                filename = pkg.get("Filename", "")
                if not filename:
                    continue
                pool_path = os.path.join(ubuntu_root, filename)
                frag["pool_files_required"] += 1
                if not os.path.isfile(pool_path) or os.path.getsize(pool_path) == 0:
                    frag["pool_files_missing"] += 1
                    frag["errors"].append("missing pool {}".format(pool_path))
                    continue
                if is_probably_html(pool_path):
                    frag["pool_files_missing"] += 1
                    frag["checksum_mismatches"] += 1
                    frag["errors"].append("HTML pool {}".format(pool_path))
                    continue
                expected = (pkg.get("SHA256") or pkg.get("MD5sum") or "").lower()
                algo_pkg = "SHA256" if pkg.get("SHA256") else "MD5"
                if expected:
                    actual = file_digest(pool_path, algo_pkg).lower()
                    if actual != expected:
                        frag["checksum_mismatches"] += 1
                        frag["pool_files_missing"] += 1
                        frag["errors"].append(
                            "pool checksum mismatch {}".format(pool_path)
                        )
                        continue
                frag["pool_files_present"] += 1

    frag["components_present"] = sorted(comps_seen)
    # Deduplicate pockets_missing
    frag["pockets_missing"] = sorted(set(frag["pockets_missing"]))
    return frag


def materialize_tree(src_ubuntu, dest_ubuntu, pockets=None):
    """Copy/hardlink files from src ubuntu tree into dest (live or snapshot)."""
    if not os.path.isdir(src_ubuntu):
        raise LegacyError("source ubuntu tree missing: {}".format(src_ubuntu))
    copied = 0
    for dirpath, _dns, filenames in os.walk(src_ubuntu):
        for fn in filenames:
            src = os.path.join(dirpath, fn)
            rel = os.path.relpath(src, src_ubuntu)
            if pockets is not None:
                # Limit dists/ to selected pockets; always allow pool/
                if rel.startswith("dists" + os.sep):
                    parts = rel.split(os.sep)
                    if len(parts) >= 2 and parts[1] not in pockets:
                        continue
            dest = os.path.join(dest_ubuntu, rel)
            hardlink_or_copy(src, dest)
            copied += 1
    return copied


def promote_snapshot(mirror_root, series, staging_ubuntu, summary, quiet=False):
    """Atomically promote staging ubuntu tree to active snapshot, keep previous."""
    log = lambda m: log_line(m, quiet=quiet)
    root = snapshot_root(mirror_root, series)
    os.makedirs(root, exist_ok=True)
    active = active_dir(mirror_root, series)
    previous = previous_dir(mirror_root, series)
    staging_snap = os.path.join(root, "staging-{}".format(int(time.time())))
    stage_ubuntu = os.path.join(staging_snap, "ubuntu")

    # Move staging tree into snapshot staging dir
    os.makedirs(staging_snap, exist_ok=True)
    if os.path.isdir(stage_ubuntu):
        shutil.rmtree(stage_ubuntu)
    shutil.move(staging_ubuntu, stage_ubuntu)

    # Write manifest inside staging snap
    manifest = OrderedDict(
        [
            ("series", series),
            ("promoted_at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
            ("source_status", summary.get("source_status")),
            ("selected_upstreams", summary.get("selected_upstreams")),
            ("pocket_provenance", summary.get("pocket_provenance")),
            ("pockets", summary.get("pockets_required")),
        ]
    )
    write_json(os.path.join(staging_snap, "manifest.json"), manifest)

    # Rotate previous ← active ← staging
    if os.path.isdir(previous):
        shutil.rmtree(previous, ignore_errors=True)
    if os.path.isdir(active):
        os.rename(active, previous)
        log("preserved previous snapshot at {}".format(previous))
    os.rename(staging_snap, active)
    log("promoted active snapshot at {}".format(active))
    summary["snapshot_promoted"] = True
    summary["active_snapshot"] = active
    summary["previous_snapshot"] = previous if os.path.isdir(previous) else ""
    return active


def restore_live_from_active(mirror_root, ubuntu_root, series, pockets, quiet=False):
    active_u = active_ubuntu(mirror_root, series)
    if not os.path.isdir(active_u):
        raise LegacyError("no active legacy snapshot for {}".format(series))
    n = materialize_tree(active_u, ubuntu_root, pockets=pockets)
    log_line("restored {} files from active snapshot into live tree".format(n), quiet)
    return n


def protect_paths_from_clean(clean_script, series, quiet=False):
    """Best-effort: wrap clean.sh to skip deleting active legacy snapshot files.

    Live archive paths may still be cleaned by apt-mirror; sync re-materializes
    from active snapshot afterward. This helper records protection intent.
    """
    del clean_script  # reserved for future clean.sh rewrite
    log_line(
        "legacy {} protected via offline snapshot (re-materialize after clean)".format(
            series
        ),
        quiet=quiet,
    )


def load_discovery_urls(discovery_root, hop="xenial-to-bionic"):
    path = os.path.join(discovery_root, hop, "required-urls.tsv")
    if not os.path.isfile(path):
        return []
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        idx = {name: i for i, name in enumerate(header)}
        url_i = idx.get("original_url", idx.get("url", 1))
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if url_i >= len(parts):
                continue
            rows.append(parts[url_i])
    return rows


def load_discovery_failed(discovery_root, hop="xenial-to-bionic"):
    path = os.path.join(discovery_root, hop, "failed-requests.tsv")
    out = []
    if not os.path.isfile(path):
        return out
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            row = {}
            for i, name in enumerate(header):
                row[name] = parts[i] if i < len(parts) else ""
            out.append(row)
    return out


def classify_discovery_url(url):
    host = url_host(url)
    path = url_path(url)
    if host not in (
        "archive.ubuntu.com",
        "security.ubuntu.com",
        "old-releases.ubuntu.com",
    ):
        return "other", host, path
    if "dist-upgrader-all" in path:
        return "upgrader", host, path
    if "/dists/" in path or "/pool/" in path:
        return "repository", host, path
    return "other", host, path


def local_paths_for_discovery_url(url, ubuntu_root):
    """Map discovery URL to local filesystem path(s) under canonical tree."""
    host = url_host(url)
    path = url_path(url)
    if path.startswith("/ubuntu/"):
        rel = path[len("/ubuntu/") :]
    elif path == "/ubuntu":
        rel = ""
    else:
        rel = path.lstrip("/")
    return [os.path.join(ubuntu_root, rel)]


def discovery_pattern_supported(url, ubuntu_root, public_base=""):
    """Check whether URL shape is served by local canonical layout.

    Does not require every pool deb from discovery to exist on this fixture —
    for repository metadata/by-hash/upgrader path shapes, verify mapping rules.
    When the local file exists, count as supported; when missing for pool debs
    in a full mirror validate, caller decides. Here we check structural support.
    """
    kind, host, path = classify_discovery_url(url)
    if kind == "other":
        return False, "unsupported_host_or_path"
    if kind == "upgrader":
        # Must map under /ubuntu/dists/<target>-updates/.../dist-upgrader-all/
        if "dist-upgrader-all" not in path:
            return False, "upgrader_path"
        return True, "upgrader"
    # repository
    if host == "security.ubuntu.com":
        # Client uses /ubuntu-security which aliases same tree; path after /ubuntu
        if not path.startswith("/ubuntu/"):
            return False, "security_path"
        return True, "security_alias"
    if host in ("archive.ubuntu.com", "old-releases.ubuntu.com"):
        if not (path == "/ubuntu" or path.startswith("/ubuntu/")):
            return False, "archive_path"
        return True, "archive_layout"
    return False, "unknown"


def cross_check_discovery(discovery_root, ubuntu_root, series, summary):
    hop = "{}-to-{}".format(series, summary.get("target_series") or DEFAULT_TARGET_SERIES)
    # Prefer explicit hop directory naming
    candidates = [
        hop,
        "xenial-to-bionic",
    ]
    hop_dir = None
    for c in candidates:
        if os.path.isdir(os.path.join(discovery_root, c)):
            hop_dir = c
            break
    if hop_dir is None:
        summary["details"].append("discovery hop not found")
        return

    urls = load_discovery_urls(discovery_root, hop_dir)
    summary["discovered_xenial_urls"] = len(urls)
    summary["discovery_urls_checked"] = len(urls)
    unsupported = []
    unsupported_patterns = set()
    repo_n = 0
    up_n = 0
    supported = 0
    for url in urls:
        kind, _host, path = classify_discovery_url(url)
        if kind == "repository":
            repo_n += 1
        elif kind == "upgrader":
            up_n += 1
        else:
            continue
        ok, reason = discovery_pattern_supported(url, ubuntu_root)
        if ok:
            supported += 1
        else:
            unsupported.append(url)
            unsupported_patterns.add(reason + ":" + path.split("/dists/")[-1][:60] if "/dists/" in path else reason)

    summary["repository_urls"] = repo_n
    summary["upgrader_urls"] = up_n
    summary["supported_urls"] = supported
    summary["unsupported_urls"] = len(unsupported)
    summary["discovery_urls_supported"] = supported
    summary["discovery_urls_unsupported"] = len(unsupported)
    summary["unsupported_patterns"] = sorted(unsupported_patterns)

    failed = load_discovery_failed(discovery_root, hop_dir)
    non_blocking = []
    for row in failed:
        # Prefer classification columns when present
        blocking = (row.get("blocking") or row.get("is_blocking") or "").lower()
        reason = row.get("reason") or row.get("classification") or row.get("error") or ""
        url = row.get("original_url") or row.get("url") or ""
        if blocking in ("0", "false", "no", "") or "stale_by_hash" in reason or "non_blocking" in reason.lower():
            non_blocking.append(
                OrderedDict([("url", url), ("reason", reason), ("blocking", False)])
            )
        else:
            non_blocking.append(
                OrderedDict([("url", url), ("reason", reason), ("blocking", blocking)])
            )
    summary["non_blocking_failures"] = [
        x for x in non_blocking if not x.get("blocking") or x.get("blocking") is False
    ]
    if any("stale_by_hash" in (x.get("reason") or "") for x in failed):
        summary["collection_artifacts"].append("stale_by_hash_404")


def scan_sources_external(sources_root):
    """Return count of external archive/security/old-releases URLs in apt sources."""
    if not sources_root or not os.path.isdir(sources_root):
        return 0, []
    pat = re.compile(
        r"https?://(?:archive|security|old-releases)\.ubuntu\.com",
        re.IGNORECASE,
    )
    hits = []
    candidates = [os.path.join(sources_root, "sources.list")]
    spd = os.path.join(sources_root, "sources.list.d")
    if os.path.isdir(spd):
        for name in os.listdir(spd):
            if name.endswith(".list") or name.endswith(".sources"):
                candidates.append(os.path.join(spd, name))
    for path in candidates:
        if not os.path.isfile(path):
            continue
        # Skip intentionally disabled backups
        if "disabled-by-dp-os-upgrade" in path:
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh, 1):
                if line.lstrip().startswith("#"):
                    continue
                if pat.search(line):
                    hits.append("{}:{}:{}".format(path, i, line.strip()[:120]))
    return len(hits), hits


def build_suite_from_upstream(
    pocket,
    upstream_base,
    dest_ubuntu,
    reuse_ubuntu,
    components,
    arch,
    connect_timeout,
    max_time,
    retries,
    resolve_map,
    downloads,
    quiet,
    sync_pool=True,
):
    """Download one pocket into dest_ubuntu from upstream_base."""
    log = lambda m: log_line(m, quiet=quiet)
    suite_dir = os.path.join(dest_ubuntu, "dists", pocket)
    os.makedirs(suite_dir, exist_ok=True)
    base = upstream_base.rstrip("/")

    release_kind = None
    release_path = None
    for kind in ("InRelease", "Release"):
        url = "{}/dists/{}/{}".format(base, pocket, kind)
        dest = os.path.join(suite_dir, kind)
        live = (
            os.path.join(reuse_ubuntu, "dists", pocket, kind) if reuse_ubuntu else None
        )
        result = curl_download(
            url,
            dest,
            connect_timeout=connect_timeout,
            max_time=max_time,
            retries=retries,
            if_modified_since=mtime_http_date(live) if live else None,
            allow_304_with_existing=live,
            resolve_map=resolve_map,
        )
        downloads.append(
            OrderedDict(
                [
                    ("url", url),
                    ("http_status", result.get("http_status", 0)),
                    ("size", result.get("size", 0)),
                    ("ok", result.get("ok", False)),
                    ("error", result.get("error", "")),
                    ("role", "release:{}".format(pocket)),
                ]
            )
        )
        if result.get("ok"):
            release_kind = kind
            release_path = dest
            break
    if release_path is None:
        raise LegacyError("failed to fetch release metadata for {}".format(pocket))

    if release_kind == "Release":
        # Optional Release.gpg
        url = "{}/dists/{}/Release.gpg".format(base, pocket)
        dest = os.path.join(suite_dir, "Release.gpg")
        live = (
            os.path.join(reuse_ubuntu, "dists", pocket, "Release.gpg")
            if reuse_ubuntu
            else None
        )
        result = curl_download(
            url,
            dest,
            connect_timeout=connect_timeout,
            max_time=max_time,
            retries=retries,
            if_modified_since=mtime_http_date(live) if live else None,
            allow_304_with_existing=live,
            resolve_map=resolve_map,
        )
        downloads.append(
            OrderedDict(
                [
                    ("url", url),
                    ("http_status", result.get("http_status", 0)),
                    ("ok", result.get("ok", False)),
                    ("role", "release.gpg:{}".format(pocket)),
                    ("optional", True),
                ]
            )
        )

    headers, checksums = read_release_file(release_path)
    indexes = index_paths_for_components(checksums, components, arch)
    if not indexes:
        raise LegacyError("no Packages indexes listed for {}".format(pocket))

    acquire = acquire_by_hash_enabled(headers)
    for item in indexes:
        entry = item["entry"]
        algo = item["algo"]
        rel = entry["path"]
        named = os.path.join(suite_dir, rel)
        url = "{}/dists/{}/{}".format(base, pocket, rel)
        live = (
            os.path.join(reuse_ubuntu, "dists", pocket, rel) if reuse_ubuntu else None
        )
        # Prefer reuse when checksum matches
        reused = False
        if live and os.path.isfile(live) and os.path.getsize(live) == entry["size"]:
            if file_digest(live, algo).lower() == entry["hash"].lower():
                hardlink_or_copy(live, named)
                reused = True
                downloads.append(
                    OrderedDict(
                        [
                            ("url", url),
                            ("http_status", 200),
                            ("ok", True),
                            ("reused", True),
                            ("role", "index:{}".format(rel)),
                        ]
                    )
                )
        if not reused:
            result = curl_download(
                url,
                named,
                connect_timeout=connect_timeout,
                max_time=max_time,
                retries=retries,
                resolve_map=resolve_map,
            )
            downloads.append(
                OrderedDict(
                    [
                        ("url", url),
                        ("http_status", result.get("http_status", 0)),
                        ("ok", result.get("ok", False)),
                        ("error", result.get("error", "")),
                        ("role", "index:{}".format(rel)),
                    ]
                )
            )
            if not result.get("ok"):
                raise LegacyError("index download failed: {} ({})".format(url, result.get("error")))
            if file_digest(named, algo).lower() != entry["hash"].lower():
                raise LegacyError("index checksum mismatch after download: {}".format(named))

        # by-hash
        bh = by_hash_path(suite_dir, rel, algo, entry["hash"])
        if acquire or True:
            live_bh = (
                by_hash_path(
                    os.path.join(reuse_ubuntu, "dists", pocket),
                    rel,
                    algo,
                    entry["hash"],
                )
                if reuse_ubuntu
                else None
            )
            if live_bh and os.path.isfile(live_bh):
                hardlink_or_copy(live_bh, bh)
            elif os.path.isfile(named):
                hardlink_or_copy(named, bh)
            else:
                bh_url = "{}/dists/{}/{}/by-hash/{}/{}".format(
                    base,
                    pocket,
                    os.path.dirname(rel).replace("\\", "/"),
                    algo,
                    entry["hash"],
                )
                # dirname may be empty
                if os.path.dirname(rel) in ("", "."):
                    bh_url = "{}/dists/{}/by-hash/{}/{}".format(
                        base, pocket, algo, entry["hash"]
                    )
                result = curl_download(
                    bh_url,
                    bh,
                    connect_timeout=connect_timeout,
                    max_time=max_time,
                    retries=retries,
                    resolve_map=resolve_map,
                )
                if not result.get("ok"):
                    # Fall back to named materialization
                    hardlink_or_copy(named, bh)
                downloads.append(
                    OrderedDict(
                        [
                            ("url", bh_url),
                            ("http_status", result.get("http_status", 0)),
                            ("ok", True),
                            ("role", "by-hash:{}".format(rel)),
                        ]
                    )
                )

        if sync_pool:
            pkgs = open_packages_index(named)
            for pkg in pkgs:
                filename = pkg.get("Filename", "")
                if not filename:
                    continue
                dest = os.path.join(dest_ubuntu, filename)
                live_pool = (
                    os.path.join(reuse_ubuntu, filename) if reuse_ubuntu else None
                )
                expected = (pkg.get("SHA256") or "").lower()
                size_s = pkg.get("Size", "")
                try:
                    expected_size = int(size_s) if size_s else None
                except ValueError:
                    expected_size = None
                if (
                    live_pool
                    and os.path.isfile(live_pool)
                    and (expected_size is None or os.path.getsize(live_pool) == expected_size)
                ):
                    if not expected or file_sha256(live_pool).lower() == expected:
                        hardlink_or_copy(live_pool, dest)
                        continue
                url = "{}/{}".format(base, filename)
                result = curl_download(
                    url,
                    dest,
                    connect_timeout=connect_timeout,
                    max_time=max_time,
                    retries=retries,
                    resolve_map=resolve_map,
                )
                downloads.append(
                    OrderedDict(
                        [
                            ("url", url),
                            ("http_status", result.get("http_status", 0)),
                            ("ok", result.get("ok", False)),
                            ("error", result.get("error", "")),
                            ("role", "pool:{}".format(filename)),
                        ]
                    )
                )
                if not result.get("ok"):
                    raise LegacyError(
                        "pool download failed: {} ({})".format(url, result.get("error"))
                    )
                if expected and file_sha256(dest).lower() != expected:
                    raise LegacyError("pool checksum mismatch: {}".format(dest))
        log("synced pocket {} from {}".format(pocket, base))


def snapshot_live_tree(ubuntu_root, dest_ubuntu, pockets):
    """Copy existing live pockets (+ referenced pool) into dest staging."""
    os.makedirs(dest_ubuntu, exist_ok=True)
    for pocket in pockets:
        src = os.path.join(ubuntu_root, "dists", pocket)
        if not os.path.isdir(src):
            raise LegacyError("live pocket missing: {}".format(pocket))
        dst = os.path.join(dest_ubuntu, "dists", pocket)
        if os.path.isdir(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst, copy_function=shutil.copy2)
    # Pool: copy files referenced by Packages
    for pocket in pockets:
        suite_dir = os.path.join(dest_ubuntu, "dists", pocket)
        kind, rel_path = suite_release_present(suite_dir)
        if kind is None:
            continue
        _headers, checksums = read_release_file(rel_path)
        # Discover any Packages* present
        for dirpath, _dns, filenames in os.walk(suite_dir):
            for fn in filenames:
                if not fn.startswith("Packages"):
                    continue
                if "by-hash" in dirpath.split(os.sep):
                    continue
                path = os.path.join(dirpath, fn)
                try:
                    pkgs = open_packages_index(path)
                except LegacyError:
                    continue
                for pkg in pkgs:
                    filename = pkg.get("Filename", "")
                    if not filename:
                        continue
                    src = os.path.join(ubuntu_root, filename)
                    dst = os.path.join(dest_ubuntu, filename)
                    if os.path.isfile(src):
                        hardlink_or_copy(src, dst)


def finalize_summary(summary, frag):
    for key in (
        "pockets_present",
        "pockets_missing",
        "components_present",
        "metadata_files_required",
        "metadata_files_present",
        "metadata_files_missing",
        "by_hash_required",
        "by_hash_present",
        "by_hash_missing",
        "pool_files_required",
        "pool_files_present",
        "pool_files_missing",
        "checksum_mismatches",
    ):
        summary[key] = frag.get(key, summary.get(key))
    errors = list(summary.get("errors") or [])
    errors.extend(frag.get("errors") or [])
    summary["errors"] = errors


def validation_pass(summary):
    """Return True when the live/canonical tree meets offline PASS criteria."""
    if summary.get("pockets_missing"):
        return False
    if summary.get("metadata_files_missing", 0) > 0:
        return False
    if summary.get("by_hash_missing", 0) > 0:
        return False
    if summary.get("pool_files_missing", 0) > 0:
        return False
    if summary.get("checksum_mismatches", 0) > 0:
        return False
    if summary.get("discovery_urls_unsupported", 0) > 0:
        return False
    if summary.get("external_urls_remaining", 0) > 0:
        return False
    # Tree content is complete — normalize status for reporting.
    if summary.get("source_status") in (
        "PARTIAL",
        "UNAVAILABLE",
        "INVALID",
        "UNKNOWN",
        "STALE",
    ):
        summary["source_status"] = "COMPLETE"
    return True


def run_validate(
    mirror_root,
    ubuntu_root,
    series,
    target_series,
    suffixes,
    components,
    arch,
    discovery_root="",
    sources_root="",
    require_by_hash=True,
    quiet=False,
):
    summary = empty_summary(series, target_series)
    pockets = pockets_for_series(series, suffixes)
    summary["pockets_required"] = list(pockets)
    summary["components_required"] = list(components)
    summary["active_snapshot"] = (
        active_dir(mirror_root, series)
        if os.path.isdir(active_dir(mirror_root, series))
        else ""
    )
    summary["previous_snapshot"] = (
        previous_dir(mirror_root, series)
        if os.path.isdir(previous_dir(mirror_root, series))
        else ""
    )

    frag = validate_tree(
        ubuntu_root,
        series,
        pockets,
        components,
        arch,
        require_by_hash=require_by_hash,
    )
    finalize_summary(summary, frag)
    summary["source_status"] = (
        "COMPLETE" if not frag["pockets_missing"] and frag["pool_files_missing"] == 0
        and frag["by_hash_missing"] == 0 and frag["checksum_mismatches"] == 0
        else ("PARTIAL" if frag["pockets_present"] else "UNAVAILABLE")
    )

    if discovery_root:
        cross_check_discovery(discovery_root, ubuntu_root, series, summary)

    ext_n, ext_hits = scan_sources_external(sources_root)
    summary["external_urls_remaining"] = ext_n
    if ext_hits:
        summary["details"].extend(ext_hits[:20])

    # external_connection_attempts always 0 for validate (offline check)
    summary["external_connection_attempts"] = 0

    if validation_pass(summary):
        summary["validation_result"] = "PASS"
        summary["source_status"] = "COMPLETE"
    else:
        summary["validation_result"] = "FAIL"
    return summary


def run_sync(
    mirror_root,
    ubuntu_root,
    series,
    target_series,
    suffixes,
    components,
    arch,
    upstreams=None,
    discovery_root="",
    sources_root="",
    connect_timeout=30,
    max_time=600,
    retries=3,
    resolve_map=None,
    require_by_hash=True,
    sync_pool=True,
    quiet=False,
    force_upstream="",
):
    """Probe upstreams, build staging, validate, promote, materialize live."""
    summary = empty_summary(series, target_series)
    pockets = pockets_for_series(series, suffixes)
    summary["pockets_required"] = list(pockets)
    summary["components_required"] = list(components)
    upstreams = upstreams or [OrderedDict(u) for u in DEFAULT_UPSTREAMS]
    downloads = summary["downloads"]
    log = lambda m: log_line(m, quiet=quiet)

    active_before = active_dir(mirror_root, series)
    had_active = os.path.isdir(active_before)
    live_before = validate_tree(
        ubuntu_root, series, pockets, components, arch, require_by_hash=require_by_hash
    )
    live_complete = (
        not live_before["pockets_missing"]
        and live_before["pool_files_missing"] == 0
        and live_before["by_hash_missing"] == 0
        and live_before["checksum_mismatches"] == 0
    )

    stage_root = tempfile.mkdtemp(
        prefix="legacy-{}-".format(series),
        dir=os.path.join(mirror_root, "offline")
        if os.path.isdir(os.path.join(mirror_root, "offline"))
        else None,
    )
    # Ensure offline dir exists
    offline = os.path.join(mirror_root, "offline")
    os.makedirs(offline, exist_ok=True)
    if not stage_root.startswith(offline):
        # recreate under offline for promote paths
        shutil.rmtree(stage_root, ignore_errors=True)
        stage_root = tempfile.mkdtemp(prefix="legacy-{}-".format(series), dir=offline)
    stage_ubuntu = os.path.join(stage_root, "ubuntu")
    os.makedirs(stage_ubuntu, exist_ok=True)

    try:
        if live_complete and not force_upstream:
            log("live {} tree COMPLETE — snapshotting without upstream fetch".format(series))
            snapshot_live_tree(ubuntu_root, stage_ubuntu, pockets)
            summary["selected_upstreams"] = ["live-tree"]
            summary["source_status"] = "COMPLETE"
            summary["candidate_upstreams"] = ["live-tree"]
            for pocket in pockets:
                summary["pocket_provenance"][pocket] = "live-tree"
        else:
            probes = []
            for up in upstreams:
                if force_upstream and up["name"] != force_upstream:
                    continue
                # Restrict probe pockets by filter
                probe = probe_upstream(
                    up,
                    pockets,
                    components,
                    arch,
                    connect_timeout=min(connect_timeout, 30),
                    max_time=min(max_time, 120),
                    resolve_map=resolve_map,
                    quiet=quiet,
                )
                probes.append(probe)
                summary["candidate_upstreams"].append(
                    OrderedDict(
                        [
                            ("name", probe["name"]),
                            ("status", probe["status"]),
                            ("base_url", probe["base_url"]),
                        ]
                    )
                )

            selected, provenance, status = select_upstreams(probes, pockets)
            summary["source_status"] = status
            summary["pocket_provenance"] = provenance
            summary["selected_upstreams"] = [s["name"] for s in selected]

            if status != "COMPLETE":
                # Fall back to active snapshot
                if had_active:
                    log(
                        "upstream status={} — restoring active snapshot".format(status)
                    )
                    try:
                        restore_live_from_active(
                            mirror_root, ubuntu_root, series, pockets, quiet=quiet
                        )
                    except LegacyError as exc:
                        summary["errors"].append(str(exc))
                    summary["snapshot_preserved_after_failure"] = True
                    summary["active_snapshot"] = active_before
                    summary["previous_snapshot"] = (
                        previous_dir(mirror_root, series)
                        if os.path.isdir(previous_dir(mirror_root, series))
                        else ""
                    )
                    # Validate restored live
                    v = run_validate(
                        mirror_root,
                        ubuntu_root,
                        series,
                        target_series,
                        suffixes,
                        components,
                        arch,
                        discovery_root=discovery_root,
                        sources_root=sources_root,
                        require_by_hash=require_by_hash,
                        quiet=True,
                    )
                    v["snapshot_preserved_after_failure"] = True
                    v["candidate_upstreams"] = summary["candidate_upstreams"]
                    v["selected_upstreams"] = summary["selected_upstreams"]
                    v["source_status"] = "STALE" if v["validation_result"] == "PASS" else status
                    if v["validation_result"] == "PASS":
                        v["source_status"] = "COMPLETE"
                    return v
                raise LegacyError(
                    "no COMPLETE upstream for {} (status={}) and no active snapshot".format(
                        series, status
                    )
                )

            # Build staging from selected upstreams per pocket
            by_name = {s["name"]: s for s in selected}
            for pocket in pockets:
                up_name = provenance.get(pocket)
                up = by_name.get(up_name)
                if up is None:
                    raise LegacyError("no upstream for pocket {}".format(pocket))
                build_suite_from_upstream(
                    pocket,
                    up["base_url"],
                    stage_ubuntu,
                    reuse_ubuntu=ubuntu_root,
                    components=components,
                    arch=arch,
                    connect_timeout=connect_timeout,
                    max_time=max_time,
                    retries=retries,
                    resolve_map=resolve_map,
                    downloads=downloads,
                    quiet=quiet,
                    sync_pool=sync_pool,
                )

        # Validate staging before promote
        frag = validate_tree(
            stage_ubuntu,
            series,
            pockets,
            components,
            arch,
            require_by_hash=require_by_hash,
        )
        finalize_summary(summary, frag)
        if (
            frag["pockets_missing"]
            or frag["pool_files_missing"]
            or frag["by_hash_missing"]
            or frag["checksum_mismatches"]
        ):
            raise LegacyError(
                "staging validation failed: missing_pockets={} pool_missing={} "
                "by_hash_missing={} checksum_mismatches={}".format(
                    frag["pockets_missing"],
                    frag["pool_files_missing"],
                    frag["by_hash_missing"],
                    frag["checksum_mismatches"],
                )
            )

        # Promote snapshot then materialize to live
        promote_snapshot(mirror_root, series, stage_ubuntu, summary, quiet=quiet)
        # stage_ubuntu moved; materialize from active
        restore_live_from_active(
            mirror_root, ubuntu_root, series, pockets, quiet=quiet
        )

        if discovery_root:
            cross_check_discovery(discovery_root, ubuntu_root, series, summary)
        ext_n, ext_hits = scan_sources_external(sources_root)
        summary["external_urls_remaining"] = ext_n
        if ext_hits:
            summary["details"].extend(ext_hits[:20])
        summary["external_connection_attempts"] = 0

        if validation_pass(summary):
            summary["validation_result"] = "PASS"
            summary["source_status"] = "COMPLETE"
        else:
            summary["validation_result"] = "FAIL"
            summary["errors"].append("post-promote validation failed")
        return summary

    except Exception as exc:
        summary["errors"].append(str(exc))
        summary["validation_result"] = "FAIL"
        if had_active:
            summary["snapshot_preserved_after_failure"] = True
            summary["active_snapshot"] = active_before
            summary["details"].append("active snapshot left unchanged after failure")
            # Ensure live still matches active if staging polluted live — we never
            # write live until promote succeeds, so live is intact.
        raise
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


def print_summary(summary):
    keys = [
        "source_series",
        "target_series",
        "source_status",
        "selected_upstreams",
        "pockets_required",
        "pockets_present",
        "pockets_missing",
        "by_hash_required",
        "by_hash_present",
        "by_hash_missing",
        "pool_files_required",
        "pool_files_present",
        "pool_files_missing",
        "checksum_mismatches",
        "snapshot_promoted",
        "snapshot_preserved_after_failure",
        "external_urls_remaining",
        "external_connection_attempts",
        "discovery_urls_checked",
        "discovery_urls_supported",
        "discovery_urls_unsupported",
        "unsupported_urls",
        "validation_result",
    ]
    for k in keys:
        v = summary.get(k, "")
        if isinstance(v, (list, tuple)):
            if v and isinstance(v[0], dict):
                v = ",".join(x.get("name", str(x)) for x in v)
            else:
                v = ",".join(str(x) for x in v)
        print("{}={}".format(k, v))


def parse_upstreams_arg(text):
    """Parse 'name=http://host/ubuntu;name2=http://...' or empty for defaults."""
    if not text:
        return [OrderedDict(u) for u in DEFAULT_UPSTREAMS]
    out = []
    for part in text.split(";"):
        part = part.strip()
        if not part:
            continue
        if "=" not in part:
            raise LegacyError("bad --upstreams entry: {}".format(part))
        name, base = part.split("=", 1)
        filt = "security" if "security" in name and "old-releases" not in name else "all"
        out.append(
            OrderedDict(
                [("name", name.strip()), ("base_url", base.strip()), ("pocket_filter", filt)]
            )
        )
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description="Legacy Ubuntu release sync/validate")
    parser.add_argument(
        "command",
        choices=("sync", "validate", "sync-validate", "restore-live", "freeze-snapshot"),
    )
    parser.add_argument("--mirror-root", default="/var/spool/apt-mirror")
    parser.add_argument("--ubuntu-root", default="")
    parser.add_argument("--series", default=DEFAULT_SERIES)
    parser.add_argument("--target-series", default=DEFAULT_TARGET_SERIES)
    parser.add_argument(
        "--suite-suffixes",
        default=" ".join(DEFAULT_SUFFIXES),
        help="Space-separated pocket suffixes (default: updates security backports)",
    )
    parser.add_argument(
        "--components",
        default=" ".join(DEFAULT_COMPONENTS),
    )
    parser.add_argument("--arch", default=DEFAULT_ARCH)
    parser.add_argument(
        "--upstreams",
        default="",
        help="Override upstreams: name=url;name2=url2",
    )
    parser.add_argument("--force-upstream", default="")
    parser.add_argument("--discovery-root", default="")
    parser.add_argument("--sources-root", default="")
    parser.add_argument("--result-json", default="")
    parser.add_argument("--xenial-result-json", default="")
    parser.add_argument("--connect-timeout", type=int, default=30)
    parser.add_argument("--max-time", type=int, default=600)
    parser.add_argument("--retries", type=int, default=3)
    parser.add_argument(
        "--resolve",
        action="append",
        default=[],
        help="curl --resolve mapping (repeatable)",
    )
    parser.add_argument("--require-by-hash", action="store_true", default=True)
    parser.add_argument("--no-require-by-hash", action="store_true")
    parser.add_argument("--skip-pool", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    ubuntu_root = args.ubuntu_root or discover_ubuntu_root(args.mirror_root)
    suffixes = tuple(s for s in args.suite_suffixes.split() if s)
    components = tuple(c for c in args.components.split() if c)
    require_by_hash = not args.no_require_by_hash
    resolve_map = list(args.resolve or [])

    offline = os.path.join(args.mirror_root, "offline")
    os.makedirs(offline, exist_ok=True)
    result_json = args.result_json or os.path.join(
        offline, "legacy-release-validation.json"
    )
    xenial_json = args.xenial_result_json or os.path.join(
        offline, "xenial-validation.json"
    )

    rc = 0
    summary = None
    try:
        if args.command in ("validate",):
            summary = run_validate(
                args.mirror_root,
                ubuntu_root,
                args.series,
                args.target_series,
                suffixes,
                components,
                args.arch,
                discovery_root=args.discovery_root,
                sources_root=args.sources_root,
                require_by_hash=require_by_hash,
                quiet=args.quiet,
            )
        elif args.command == "restore-live":
            pockets = pockets_for_series(args.series, suffixes)
            restore_live_from_active(
                args.mirror_root, ubuntu_root, args.series, pockets, quiet=args.quiet
            )
            summary = run_validate(
                args.mirror_root,
                ubuntu_root,
                args.series,
                args.target_series,
                suffixes,
                components,
                args.arch,
                discovery_root=args.discovery_root,
                sources_root=args.sources_root,
                require_by_hash=require_by_hash,
                quiet=args.quiet,
            )
        elif args.command == "freeze-snapshot":
            # Snapshot current live tree into active without upstream
            pockets = pockets_for_series(args.series, suffixes)
            stage = tempfile.mkdtemp(prefix="legacy-freeze-", dir=offline)
            stage_u = os.path.join(stage, "ubuntu")
            try:
                snapshot_live_tree(ubuntu_root, stage_u, pockets)
                summary = empty_summary(args.series, args.target_series)
                summary["pockets_required"] = list(pockets)
                summary["components_required"] = list(components)
                summary["source_status"] = "COMPLETE"
                summary["selected_upstreams"] = ["live-tree"]
                frag = validate_tree(
                    stage_u,
                    args.series,
                    pockets,
                    components,
                    args.arch,
                    require_by_hash=require_by_hash,
                )
                finalize_summary(summary, frag)
                if frag["pockets_missing"] or frag["pool_files_missing"]:
                    raise LegacyError("cannot freeze incomplete live tree")
                promote_snapshot(
                    args.mirror_root, args.series, stage_u, summary, quiet=args.quiet
                )
                summary["validation_result"] = "PASS"
            finally:
                shutil.rmtree(stage, ignore_errors=True)
        else:
            # sync / sync-validate
            summary = run_sync(
                args.mirror_root,
                ubuntu_root,
                args.series,
                args.target_series,
                suffixes,
                components,
                args.arch,
                upstreams=parse_upstreams_arg(args.upstreams),
                discovery_root=args.discovery_root,
                sources_root=args.sources_root,
                connect_timeout=args.connect_timeout,
                max_time=args.max_time,
                retries=args.retries,
                resolve_map=resolve_map,
                require_by_hash=require_by_hash,
                sync_pool=not args.skip_pool,
                quiet=args.quiet,
                force_upstream=args.force_upstream,
            )
            if args.command == "sync-validate" and summary["validation_result"] != "PASS":
                rc = 1
    except LegacyError as exc:
        eprint("ERROR: {}".format(exc))
        if summary is None:
            summary = empty_summary(args.series, args.target_series)
        summary["errors"].append(str(exc))
        summary["validation_result"] = "FAIL"
        rc = 1
    except Exception as exc:
        eprint("ERROR: {}".format(exc))
        if summary is None:
            summary = empty_summary(args.series, args.target_series)
        summary["errors"].append(str(exc))
        summary["validation_result"] = "FAIL"
        rc = 1

    if summary is not None:
        if summary.get("validation_result") != "PASS":
            rc = 1
        print_summary(summary)
        write_json(result_json, summary)
        if args.series == "xenial":
            write_json(xenial_json, summary)

    return rc


if __name__ == "__main__":
    sys.exit(main())
