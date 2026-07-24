#!/usr/bin/env python3
"""Supplemental Ubuntu repository by-hash sync, validation, and stale cleanup.

Discovers required by-hash objects from local Release/InRelease metadata
(Acquire-By-Hash + checksum sections), materializes them (hardlink/copy from
named indexes or upstream download), validates checksums, and optionally
removes only unreferenced by-hash files after a successful sync.
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

ALGO_DIR_NAMES = ("SHA256", "SHA512", "SHA1", "MD5")
ALGO_TO_HASHLIB = {
    "SHA256": "sha256",
    "SHA512": "sha512",
    "SHA1": "sha1",
    "MD5": "md5",
}
SECTION_TO_ALGO = {
    "SHA256": "SHA256",
    "SHA512": "SHA512",
    "SHA1": "SHA1",
    "MD5Sum": "MD5",
    "MD5sum": "MD5",
}

# Index basenames apt fetches via by-hash when Acquire-By-Hash is enabled.
# Contents-/Icons- are only required when the named file already exists locally.
INDEX_BASENAME_RE = re.compile(
    r"^(?:"
    r"Packages(?:\.(?:gz|xz|bz2|lzma))?|"
    r"Sources(?:\.(?:gz|xz|bz2|lzma))?|"
    r"Release|"
    r"Translation-[A-Za-z0-9_@.-]+(?:\.(?:gz|xz|bz2))?|"
    r"Commands-[A-Za-z0-9.-]+(?:\.(?:gz|xz|bz2))?|"
    r"Components-[A-Za-z0-9.-]+\.yml(?:\.(?:gz|xz|bz2))?|"
    r"cnf|"  # rare
    r".+\.diff/Index"
    r")$"
)

HTML_RE = re.compile(br"<(!DOCTYPE\s+)?[Hh][Tt][Mm][Ll]", re.IGNORECASE)


class ByHashError(Exception):
    pass


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def file_digest(path, algo_dir="SHA256", chunk=1024 * 1024):
    name = ALGO_TO_HASHLIB.get(algo_dir)
    if not name:
        raise ByHashError("Unsupported hash algorithm: {}".format(algo_dir))
    h = hashlib.new(name)
    with open(path, "rb") as fh:
        while True:
            chunk_data = fh.read(chunk)
            if not chunk_data:
                break
            h.update(chunk_data)
    return h.hexdigest()


def is_probably_html(path):
    try:
        with open(path, "rb") as fh:
            head = fh.read(512)
    except OSError:
        return False
    return HTML_RE.search(head) is not None


def looks_like_index_basename(name):
    return bool(INDEX_BASENAME_RE.match(name))


def parse_release_text(text):
    """Parse Release/InRelease body (clears PGP wrapper if present)."""
    if "-----BEGIN PGP SIGNED MESSAGE-----" in text:
        # Drop armor header until blank line after Hash:, keep signed payload
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
    checksums = OrderedDict()  # algo_dir -> list of {hash, size, path}
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
            if key in SECTION_TO_ALGO and not val:
                current_section = SECTION_TO_ALGO[key]
                checksums.setdefault(current_section, [])
                continue
            headers[key] = val
            if key in SECTION_TO_ALGO:
                # "SHA256:" with entries on following indented lines
                if val == "":
                    current_section = SECTION_TO_ALGO[key]
                    checksums.setdefault(current_section, [])
    return headers, checksums


def read_suite_release(suite_dir):
    for name in ("InRelease", "Release"):
        path = os.path.join(suite_dir, name)
        if os.path.isfile(path) and os.path.getsize(path) > 0:
            with open(path, "rb") as fh:
                raw = fh.read()
            if is_probably_html(path):
                raise ByHashError("Release metadata looks like HTML: {}".format(path))
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                text = raw.decode("utf-8", "replace")
            headers, checksums = parse_release_text(text)
            return name, path, headers, checksums
    return None, None, {}, {}


def acquire_by_hash_enabled(headers):
    val = str(headers.get("Acquire-By-Hash", "")).strip().lower()
    return val in ("yes", "true", "1")


def discover_repos(mirror_root):
    """Find ubuntu repository roots under mirror_root/mirror or mirror_root."""
    candidates = []
    for base in (
        os.path.join(mirror_root, "mirror"),
        mirror_root,
    ):
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, _files in os.walk(base):
            if os.path.basename(dirpath) != "dists":
                continue
            # Expect .../<host>/ubuntu/dists
            ubuntu_root = os.path.dirname(dirpath)
            if os.path.basename(ubuntu_root) != "ubuntu":
                continue
            rel = os.path.relpath(ubuntu_root, base)
            host = rel.split(os.sep)[0] if rel != "." else "local"
            candidates.append(
                {
                    "ubuntu_root": ubuntu_root,
                    "dists_root": dirpath,
                    "host_label": host,
                    "mirror_base": base,
                }
            )
            dirnames[:] = []  # do not walk into dists
    # Deduplicate by ubuntu_root
    seen = set()
    out = []
    for c in sorted(candidates, key=lambda x: x["ubuntu_root"]):
        if c["ubuntu_root"] in seen:
            continue
        seen.add(c["ubuntu_root"])
        out.append(c)
    return out


def discover_suites(dists_root):
    suites = []
    if not os.path.isdir(dists_root):
        return suites
    for name in sorted(os.listdir(dists_root)):
        path = os.path.join(dists_root, name)
        if not os.path.isdir(path):
            continue
        if name.startswith("."):
            continue
        suites.append(name)
    return suites


def by_hash_path(suite_dir, relpath, algo, digest):
    parent = os.path.dirname(relpath)
    if parent and parent != ".":
        return os.path.join(suite_dir, parent, "by-hash", algo, digest)
    return os.path.join(suite_dir, "by-hash", algo, digest)


def named_path(suite_dir, relpath):
    return os.path.join(suite_dir, relpath)


def should_require_entry(suite_dir, entry, acquire_enabled, default_arch="amd64"):
    """Decide if a Release checksum entry needs a by-hash object.

    Require by-hash only when the named index exists on the mirror. Ubuntu
    Release files list many checksums (all arches, uncompressed forms) whose
    by-hash objects are not published upstream; chasing those yields false
    404 failures. Materializing by-hash for every local named index is the
    correct guarantee for apt-mirror trees (hardlink/copy + checksum check).

    When Acquire-By-Hash is disabled, still materialize for present named
    indexes (harmless, keeps layout complete) but validation treats missing
    by-hash as non-fatal only when acquire is off (see validate_item).
    """
    del default_arch  # reserved for future optional fetch-without-named mode
    relpath = entry["path"]
    if "/by-hash/" in relpath:
        return False
    named = named_path(suite_dir, relpath)
    if os.path.islink(named) and not os.path.exists(named):
        return True  # detect dangling via validate
    if not os.path.isfile(named) and not (os.path.islink(named) and os.path.exists(named)):
        return False
    base = os.path.basename(relpath)
    # Skip huge optional trees even if somehow present under unexpected names
    if base.startswith("Contents") or base.startswith("Icons"):
        # Still include when present — operators may want by-hash for Contents
        pass
    if acquire_enabled:
        return True
    # Acquire-By-Hash off: only care about classic index basenames
    return looks_like_index_basename(base)


def preferred_algo_entries(checksums):
    """Yield (algo, entry) preferring SHA256 then SHA512/SHA1/MD5."""
    for algo in ALGO_DIR_NAMES:
        for entry in checksums.get(algo, []):
            yield algo, entry


def collect_required(suite_dir, headers, checksums, default_arch="amd64"):
    acquire = acquire_by_hash_enabled(headers)
    required = OrderedDict()  # key: (algo, digest, relpath) -> entry dict
    # Prefer SHA256; if same path appears in multiple algos, keep SHA256
    path_best = {}
    for algo, entry in preferred_algo_entries(checksums):
        if not should_require_entry(suite_dir, entry, acquire, default_arch=default_arch):
            continue
        relpath = entry["path"]
        prev = path_best.get(relpath)
        if prev is None:
            path_best[relpath] = (algo, entry)
        else:
            prev_algo = prev[0]
            if ALGO_DIR_NAMES.index(algo) < ALGO_DIR_NAMES.index(prev_algo):
                path_best[relpath] = (algo, entry)

    for relpath, (algo, entry) in sorted(path_best.items()):
        key = (algo, entry["hash"], relpath)
        required[key] = {
            "algo": algo,
            "hash": entry["hash"],
            "size": entry["size"],
            "path": relpath,
            "by_hash_path": by_hash_path(suite_dir, relpath, algo, entry["hash"]),
            "named_path": named_path(suite_dir, relpath),
            "acquire_by_hash": acquire,
        }
    return acquire, required


def atomic_install(tmp_path, dest_path):
    dest_dir = os.path.dirname(dest_path)
    os.makedirs(dest_dir, exist_ok=True)
    # Install via temp in same directory for atomic rename
    fd, stage = tempfile.mkstemp(prefix=".byhash-", dir=dest_dir)
    os.close(fd)
    try:
        shutil.copyfile(tmp_path, stage)
        os.chmod(stage, 0o644)
        os.replace(stage, dest_path)
    finally:
        if os.path.exists(stage):
            try:
                os.unlink(stage)
            except OSError:
                pass


def materialize_from_named(item, log):
    named = item["named_path"]
    dest = item["by_hash_path"]
    algo = item["algo"]
    expected = item["hash"]

    if not os.path.isfile(named):
        return False, "named_missing"

    if os.path.islink(named) and not os.path.exists(named):
        return False, "named_dangling_symlink"

    try:
        digest = file_digest(named, algo)
    except OSError as exc:
        return False, "named_read_error:{}".format(exc)

    if digest.lower() != expected.lower():
        return False, "named_checksum_mismatch:{}!={}".format(digest, expected)

    if os.path.isfile(dest) and not os.path.islink(dest):
        try:
            existing = file_digest(dest, algo)
            if existing.lower() == expected.lower() and os.path.getsize(dest) > 0:
                return True, "already_present"
        except OSError:
            pass

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    # Prefer hardlink
    if os.path.exists(dest) or os.path.islink(dest):
        # Replace only after verifying we can create good content
        fd, stage = tempfile.mkstemp(prefix=".byhash-", dir=os.path.dirname(dest))
        os.close(fd)
        try:
            os.unlink(stage)
            try:
                os.link(named, stage)
            except OSError:
                shutil.copy2(named, stage)
            os.chmod(stage, 0o644)
            os.replace(stage, dest)
        finally:
            if os.path.exists(stage):
                try:
                    os.unlink(stage)
                except OSError:
                    pass
    else:
        try:
            os.link(named, dest)
            os.chmod(dest, 0o644)
        except OSError:
            shutil.copy2(named, dest)
            os.chmod(dest, 0o644)
    log("materialized hardlink/copy {} -> {}".format(named, dest))
    return True, "hardlink_or_copy"


def curl_download(url, dest_tmp, timeouts, log, conditional=False):
    """Download URL to dest_tmp. Returns (ok, http_code, message).

    Never treats 304 as success. On 304, caller should retry unconditional.
    """
    connect_t, max_t, retries = timeouts
    cmd = [
        "curl",
        "--location",
        "--silent",
        "--show-error",
        "--connect-timeout",
        str(connect_t),
        "--max-time",
        str(max_t),
        "--retry",
        str(retries),
        "--retry-delay",
        "2",
        "-o",
        dest_tmp,
        "-w",
        "%{http_code}",
    ]
    if not conditional:
        # Force unconditional GET (no 304): disable conditional headers curl may add via env
        cmd.extend(["-H", "Cache-Control: no-cache", "-H", "Pragma: no-cache"])
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
        return False, "000", "curl_exec_failed:{}".format(exc)

    code = (proc.stdout or "").strip() or "000"
    if proc.returncode != 0 and code not in ("200", "304"):
        return False, code, "curl_rc={}:{}".format(proc.returncode, (proc.stderr or "").strip())

    if code == "304":
        return False, "304", "not_modified_no_body"

    if code != "200":
        return False, code, "http_{}".format(code)

    if not os.path.isfile(dest_tmp) or os.path.getsize(dest_tmp) == 0:
        return False, code, "empty_body"

    if is_probably_html(dest_tmp):
        return False, code, "html_error_page"

    return True, code, "ok"


def download_by_hash(item, upstream_base, suite, timeouts, log, downloader=None):
    """Download by-hash object from upstream with checksum verification."""
    algo = item["algo"]
    digest = item["hash"]
    relpath = item["path"]
    dest = item["by_hash_path"]
    parent = os.path.dirname(relpath)
    if parent and parent != ".":
        url_path = "{}/by-hash/{}/{}".format(parent, algo, digest)
    else:
        url_path = "by-hash/{}/{}".format(algo, digest)
    url = "{}/dists/{}/{}".format(upstream_base.rstrip("/"), suite, url_path)

    # Preserve existing good file
    existing_good = False
    if os.path.isfile(dest) and not os.path.islink(dest) and os.path.getsize(dest) > 0:
        try:
            if file_digest(dest, algo).lower() == digest.lower():
                existing_good = True
        except OSError:
            existing_good = False

    dest_dir = os.path.dirname(dest)
    os.makedirs(dest_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".byhash-dl-", dir=dest_dir)
    os.close(fd)
    try:
        download_fn = downloader or curl_download
        ok, code, msg = download_fn(url, tmp, timeouts, log, conditional=False)
        if not ok and code == "304":
            log("got HTTP 304 for {}; retrying unconditional".format(url))
            try:
                os.unlink(tmp)
            except OSError:
                pass
            fd2, tmp = tempfile.mkstemp(prefix=".byhash-dl-", dir=dest_dir)
            os.close(fd2)
            ok, code, msg = download_fn(url, tmp, timeouts, log, conditional=False)

        if not ok:
            if existing_good:
                log("download failed ({}); keeping existing good file: {}".format(msg, dest))
                return True, "kept_existing_after_fail:{}".format(msg)
            log("download failed for {}: {}".format(url, msg))
            return False, "download_failed:{}:{}".format(code, msg)

        got = file_digest(tmp, algo).lower()
        if got != digest.lower():
            if existing_good:
                log("checksum mismatch on download; keeping existing: {}".format(dest))
                return True, "kept_existing_after_mismatch"
            log("checksum mismatch for {}: got {} expected {}".format(url, got, digest))
            return False, "checksum_mismatch"

        if item["size"] and os.path.getsize(tmp) != item["size"]:
            # Size from Release is authoritative when present; warn but hash wins
            log("size differs from Release for {} (got {}, expected {})".format(
                url, os.path.getsize(tmp), item["size"]))

        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
        tmp = None
        log("downloaded {}".format(url))
        # Keep named index consistent with verified by-hash when stale/missing
        named = item.get("named_path")
        if named:
            need_named = True
            if os.path.isfile(named):
                try:
                    need_named = file_digest(named, algo).lower() != digest.lower()
                except OSError:
                    need_named = True
            if need_named:
                try:
                    atomic_install(dest, named)
                    log("repaired named index from by-hash: {}".format(named))
                except OSError as exc:
                    log("could not repair named index {}: {}".format(named, exc))
        return True, "downloaded"
    finally:
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def ensure_item(item, suite, upstream_base, timeouts, log, downloader=None):
    dest = item["by_hash_path"]

    # Dangling symlink?
    if os.path.islink(dest) and not os.path.exists(dest):
        try:
            os.unlink(dest)
        except OSError:
            return False, "dangling_symlink"

    if os.path.isfile(dest) and os.path.getsize(dest) > 0:
        try:
            digest = file_digest(dest, item["algo"])
            if digest.lower() == item["hash"].lower():
                if is_probably_html(dest):
                    return False, "html_body"
                # If named matches Release but differs from by-hash, rebuild from named.
                # If named is stale vs Release while by-hash is correct, keep by-hash;
                # validate_item still reports named_byhash_mismatch.
                named = item["named_path"]
                if os.path.isfile(named):
                    named_digest = file_digest(named, item["algo"])
                    if named_digest.lower() != digest.lower():
                        if named_digest.lower() == item["hash"].lower():
                            ok, reason = materialize_from_named(item, log)
                            return ok, reason
                        log("named index stale vs Release/by-hash: {}".format(named))
                return True, "already_present"
        except OSError as exc:
            log("error reading {}: {}".format(dest, exc))

    ok, reason = materialize_from_named(item, log)
    if ok:
        return True, reason

    if reason.startswith("named_checksum_mismatch") or reason == "named_missing":
        return download_by_hash(
            item, upstream_base, suite, timeouts, log, downloader=downloader
        )

    return False, reason


def validate_item(item):
    """Return (ok, code) for a required by-hash item."""
    dest = item["by_hash_path"]
    named = item["named_path"]
    algo = item["algo"]
    expected = item["hash"]

    if os.path.islink(dest) and not os.path.exists(dest):
        return False, "dangling_symlink"
    if not os.path.isfile(dest) and not (os.path.islink(dest) and os.path.exists(dest)):
        if item.get("acquire_by_hash"):
            return False, "missing"
        return True, "skipped_no_acquire"
    if os.path.getsize(dest) == 0:
        return False, "empty"
    if is_probably_html(dest):
        return False, "html_body"
    try:
        digest = file_digest(dest, algo).lower()
    except OSError:
        return False, "unreadable"
    if digest != expected.lower():
        return False, "digest_mismatch"
    if os.path.isfile(named):
        try:
            named_digest = file_digest(named, algo).lower()
        except OSError:
            return False, "named_unreadable"
        if named_digest != digest:
            return False, "named_byhash_mismatch"
        if named_digest != expected.lower():
            return False, "named_release_mismatch"
    return True, "ok"


def list_on_disk_by_hash(suite_dir):
    """Return list of {path, algo, digest} for by-hash files under suite."""
    found = []
    for dirpath, _dirnames, filenames in os.walk(suite_dir):
        parts = dirpath.split(os.sep)
        if "by-hash" not in parts:
            continue
        idx = parts.index("by-hash")
        if idx + 1 >= len(parts):
            continue
        algo = parts[idx + 1]
        if algo not in ALGO_TO_HASHLIB:
            continue
        # Only files directly under by-hash/<ALGO>/
        if idx + 1 != len(parts) - 1:
            continue
        for name in filenames:
            found.append(
                {
                    "path": os.path.join(dirpath, name),
                    "algo": algo,
                    "digest": name.lower(),
                }
            )
    return found


def run_for_suite(
    suite,
    suite_dir,
    upstream_base,
    timeouts,
    do_sync,
    do_validate,
    do_cleanup,
    allow_cleanup,
    log,
    downloader=None,
    default_arch="amd64",
):
    result = {
        "suite": suite,
        "suite_dir": suite_dir,
        "acquire_by_hash": False,
        "release_file": None,
        "required": 0,
        "present": 0,
        "missing": 0,
        "checksum_mismatch": 0,
        "stale": 0,
        "synced": 0,
        "downloaded": 0,
        "errors": [],
        "validation_result": "PASS",
    }

    try:
        rel_name, rel_path, headers, checksums = read_suite_release(suite_dir)
    except ByHashError as exc:
        result["errors"].append(str(exc))
        result["validation_result"] = "FAIL"
        return result

    if not rel_path:
        result["errors"].append("no InRelease/Release")
        result["validation_result"] = "FAIL"
        return result

    result["release_file"] = rel_name
    acquire, required = collect_required(
        suite_dir, headers, checksums, default_arch=default_arch
    )
    result["acquire_by_hash"] = acquire
    result["required"] = len(required)
    referenced = set()

    for _key, item in required.items():
        referenced.add(os.path.normpath(item["by_hash_path"]))
        if do_sync:
            ok, reason = ensure_item(
                item, suite, upstream_base, timeouts, log, downloader=downloader
            )
            if ok:
                result["synced"] += 1
                if reason == "downloaded":
                    result["downloaded"] += 1
            else:
                result["errors"].append("{}: {}".format(item["path"], reason))

    if do_validate or do_sync:
        present = 0
        missing = 0
        mismatch = 0
        for _key, item in required.items():
            vok, vcode = validate_item(item)
            if vok:
                present += 1
            elif vcode == "missing":
                missing += 1
                result["errors"].append("missing {}".format(item["by_hash_path"]))
            else:
                mismatch += 1
                result["errors"].append("{}: {}".format(item["by_hash_path"], vcode))
        result["present"] = present
        result["missing"] = missing
        result["checksum_mismatch"] = mismatch

    on_disk = list_on_disk_by_hash(suite_dir)
    stale_paths = []
    for entry in on_disk:
        norm = os.path.normpath(entry["path"])
        if norm not in referenced:
            stale_paths.append(entry["path"])
    result["stale"] = len(stale_paths)

    if do_cleanup:
        if not allow_cleanup:
            log("skipping stale cleanup for {} (sync incomplete / not allowed)".format(suite))
        else:
            for path in stale_paths:
                try:
                    os.unlink(path)
                    log("removed stale by-hash {}".format(path))
                except OSError as exc:
                    result["errors"].append("cleanup {}: {}".format(path, exc))

    if result["missing"] or result["checksum_mismatch"]:
        result["validation_result"] = "FAIL"
    elif acquire and result["required"] and result["present"] < result["required"]:
        result["validation_result"] = "FAIL"
    return result


def summarize(suite_results, incomplete=False):
    summary = OrderedDict([
        ("repositories_checked", 0),
        ("suites_checked", 0),
        ("metadata_files_checked", 0),
        ("required_by_hash_files", 0),
        ("present_by_hash_files", 0),
        ("missing_by_hash_files", 0),
        ("checksum_mismatch_files", 0),
        ("stale_by_hash_files", 0),
        ("validation_result", "PASS"),
        ("incomplete_sync", bool(incomplete)),
        ("suites", []),
    ])
    repos = set()
    for sr in suite_results:
        repos.add(os.path.dirname(os.path.dirname(sr["suite_dir"])))
        summary["suites_checked"] += 1
        if sr.get("release_file"):
            summary["metadata_files_checked"] += 1
        summary["required_by_hash_files"] += sr.get("required", 0)
        summary["present_by_hash_files"] += sr.get("present", 0)
        summary["missing_by_hash_files"] += sr.get("missing", 0)
        summary["checksum_mismatch_files"] += sr.get("checksum_mismatch", 0)
        summary["stale_by_hash_files"] += sr.get("stale", 0)
        summary["suites"].append(sr)
        if sr.get("validation_result") != "PASS":
            summary["validation_result"] = "FAIL"
    summary["repositories_checked"] = len(repos)
    if incomplete:
        summary["validation_result"] = "FAIL"
    if summary["missing_by_hash_files"] or summary["checksum_mismatch_files"]:
        summary["validation_result"] = "FAIL"
    return summary


def print_summary(summary):
    keys = [
        "repositories_checked",
        "suites_checked",
        "metadata_files_checked",
        "required_by_hash_files",
        "present_by_hash_files",
        "missing_by_hash_files",
        "checksum_mismatch_files",
        "stale_by_hash_files",
        "validation_result",
    ]
    for k in keys:
        print("{}={}".format(k, summary.get(k)))


def write_json(path, obj):
    if not path:
        return
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".byhash-summary-", dir=parent or None)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, sort_keys=False)
            fh.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def default_upstream_for_repo(repo, fallback):
    host = repo.get("host_label") or ""
    if host in ("archive.ubuntu.com", "security.ubuntu.com", "old-releases.ubuntu.com"):
        return "http://{}/ubuntu".format(host)
    return fallback


def main(argv=None):
    parser = argparse.ArgumentParser(description="Ubuntu mirror by-hash sync/validate")
    parser.add_argument(
        "command",
        choices=("sync", "validate", "cleanup", "sync-validate"),
        help="Action to perform",
    )
    parser.add_argument(
        "--mirror-root",
        default=os.environ.get("MIRROR_ROOT", "/var/spool/apt-mirror"),
        help="apt-mirror base path (contains mirror/)",
    )
    parser.add_argument(
        "--ubuntu-root",
        default="",
        help="Optional single ubuntu root (…/ubuntu). Overrides discovery.",
    )
    parser.add_argument(
        "--upstream-base-url",
        default=os.environ.get("UPSTREAM_BASE_URL", "http://archive.ubuntu.com/ubuntu"),
        help="Upstream Ubuntu repo base for downloads",
    )
    parser.add_argument(
        "--connect-timeout",
        type=int,
        default=int(os.environ.get("CURL_CONNECT_TIMEOUT", "30")),
    )
    parser.add_argument(
        "--max-time",
        type=int,
        default=int(os.environ.get("CURL_MAX_TIME", "600")),
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=int(os.environ.get("CURL_RETRIES", "3")),
    )
    parser.add_argument(
        "--result-json",
        default="",
        help="Write machine-readable summary JSON",
    )
    parser.add_argument(
        "--incomplete",
        action="store_true",
        help="Mark sync incomplete: fail validation and skip destructive cleanup",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
    )
    parser.add_argument(
        "--default-arch",
        default=os.environ.get("DEFAULT_ARCH", "amd64"),
        help="Architecture to materialize when named index is absent (default: amd64)",
    )
    args = parser.parse_args(argv)

    def log(msg):
        if not args.quiet:
            stamp = time.strftime("%Y-%m-%d %H:%M:%S")
            print("{} [by-hash] {}".format(stamp, msg))

    timeouts = (args.connect_timeout, args.max_time, args.retries)
    do_sync = args.command in ("sync", "sync-validate")
    do_validate = args.command in ("validate", "sync-validate")
    do_cleanup = args.command in ("cleanup", "sync-validate")
    # cleanup alone requires explicit allow via success path; sync-validate cleans
    # only when not incomplete and validation will pass.
    allow_cleanup = do_cleanup and not args.incomplete

    repos = []
    if args.ubuntu_root:
        ubuntu_root = os.path.abspath(args.ubuntu_root)
        repos.append(
            {
                "ubuntu_root": ubuntu_root,
                "dists_root": os.path.join(ubuntu_root, "dists"),
                "host_label": "configured",
                "mirror_base": os.path.dirname(ubuntu_root),
            }
        )
    else:
        repos = discover_repos(os.path.abspath(args.mirror_root))

    if not repos:
        eprint("ERROR: no ubuntu repository trees found under {}".format(args.mirror_root))
        summary = summarize([], incomplete=True)
        print_summary(summary)
        write_json(args.result_json, summary)
        return 2

    suite_results = []
    for repo in repos:
        upstream = default_upstream_for_repo(repo, args.upstream_base_url)
        suites = discover_suites(repo["dists_root"])
        if not suites:
            log("no suites under {}".format(repo["dists_root"]))
            continue
        for suite in suites:
            suite_dir = os.path.join(repo["dists_root"], suite)
            # First pass: sync + validate without cleanup
            sr = run_for_suite(
                suite=suite,
                suite_dir=suite_dir,
                upstream_base=upstream,
                timeouts=timeouts,
                do_sync=do_sync,
                do_validate=do_validate or do_cleanup,
                do_cleanup=False,
                allow_cleanup=False,
                log=log,
                default_arch=args.default_arch,
            )
            suite_results.append(sr)

    summary = summarize(suite_results, incomplete=args.incomplete)

    # Safe stale cleanup only after successful sync/validate
    if do_cleanup and allow_cleanup and summary["validation_result"] == "PASS":
        for sr in suite_results:
            suite_dir = sr["suite_dir"]
            suite = sr["suite"]
            repo = next(
                (r for r in repos if suite_dir.startswith(r["dists_root"])),
                None,
            )
            upstream = default_upstream_for_repo(repo, args.upstream_base_url) if repo else args.upstream_base_url
            cleaned = run_for_suite(
                suite=suite,
                suite_dir=suite_dir,
                upstream_base=upstream,
                timeouts=timeouts,
                do_sync=False,
                do_validate=True,
                do_cleanup=True,
                allow_cleanup=True,
                log=log,
                default_arch=args.default_arch,
            )
            sr["stale"] = cleaned.get("stale", 0)
            # Recompute stale count after deletion (should be 0 remaining intent)
        # Refresh stale counts from disk after cleanup
        stale_total = 0
        for sr in suite_results:
            try:
                _n, _p, headers, checksums = read_suite_release(sr["suite_dir"])
            except ByHashError:
                continue
            _acq, required = collect_required(
                sr["suite_dir"], headers, checksums, default_arch=args.default_arch
            )
            referenced = set(
                os.path.normpath(i["by_hash_path"]) for i in required.values()
            )
            on_disk = list_on_disk_by_hash(sr["suite_dir"])
            left = [
                e for e in on_disk if os.path.normpath(e["path"]) not in referenced
            ]
            sr["stale"] = len(left)
            stale_total += len(left)
        summary["stale_by_hash_files"] = stale_total
    elif do_cleanup and not allow_cleanup:
        log("destructive by-hash cleanup skipped (incomplete sync)")

    # Final validation gate
    if do_validate or do_sync:
        if summary["missing_by_hash_files"] != 0 or summary["checksum_mismatch_files"] != 0:
            summary["validation_result"] = "FAIL"
        if args.incomplete:
            summary["validation_result"] = "FAIL"

    print_summary(summary)
    write_json(args.result_json, summary)

    if summary["validation_result"] != "PASS":
        for sr in suite_results:
            for err in sr.get("errors", [])[:20]:
                eprint("  {}: {}".format(sr["suite"], err))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
