#!/usr/bin/env python3
"""Deterministic generator for hop-specific Menu 7 OS-hop launchers.

Produces four public launcher scripts from one template:

  dp-launch-xenial-to-bionic.sh
  dp-launch-bionic-to-focal.sh
  dp-launch-focal-to-jammy.sh
  dp-launch-jammy-to-noble.sh

Deterministic for the same template bytes, Mirror URL, signing fingerprint,
hop mapping, and launcher schema version. Never embeds timestamps, random
values, temp paths, hostnames, inodes, or private-key material.
"""
from __future__ import print_function

import argparse
import hashlib
import os
import re
import sys

LAUNCHER_SCHEMA_VERSION = "1"

HOPS = (
    ("xenial-to-bionic", "dp-offline-upgrade-xenial-to-bionic.sh"),
    ("bionic-to-focal", "dp-offline-upgrade-bionic-to-focal.sh"),
    ("focal-to-jammy", "dp-offline-upgrade-focal-to-jammy.sh"),
    ("jammy-to-noble", "dp-offline-upgrade-jammy-to-noble.sh"),
)

TEMPLATE_REL = "client/dp-client-hop-launcher.sh.in"


def _sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _normalize_mirror(mirror_base_url):
    mirror = (mirror_base_url or "").rstrip("/")
    if not mirror:
        raise RuntimeError("LAUNCHER_MIRROR_BASE_MISSING")
    if "@@" in mirror:
        raise RuntimeError("LAUNCHER_MIRROR_BASE_INVALID")
    return mirror


def _normalize_fpr(signing_fingerprint):
    fpr = (signing_fingerprint or "").upper().replace(" ", "")
    if not re.match(r"^[0-9A-F]{40}$", fpr):
        raise RuntimeError("LAUNCHER_EXPECTED_FPR_INVALID")
    return fpr


def render_launcher(template_text, mirror_base, expected_fpr, hop, script):
    text = template_text
    replacements = {
        "@@LAUNCHER_SCHEMA_VERSION@@": LAUNCHER_SCHEMA_VERSION,
        "@@MIRROR_BASE@@": mirror_base,
        "@@EXPECTED_FPR@@": expected_fpr,
        "@@HOP@@": hop,
        "@@SCRIPT@@": script,
    }
    for key, value in replacements.items():
        if key not in text:
            raise RuntimeError("LAUNCHER_TEMPLATE_PLACEHOLDER_MISSING=" + key)
        text = text.replace(key, value)
    if re.search(r"@@[A-Z0-9_]+@@", text):
        raise RuntimeError("LAUNCHER_TEMPLATE_UNREPLACED_PLACEHOLDER")
    if not text.startswith("#!/"):
        raise RuntimeError("LAUNCHER_TEMPLATE_SHEBANG_MISSING")
    # Normalize to LF-only for cross-platform determinism.
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if not text.endswith("\n"):
        text += "\n"
    return text


def build_launchers(project_root, output_dir, mirror_base_url, signing_fingerprint):
    root = os.path.abspath(project_root)
    out = os.path.abspath(output_dir)
    template_path = os.path.join(root, TEMPLATE_REL)
    if not os.path.isfile(template_path):
        raise RuntimeError("LAUNCHER_TEMPLATE_MISSING=" + TEMPLATE_REL)
    with open(template_path, "r", encoding="utf-8", errors="strict") as fh:
        template_text = fh.read()
    mirror = _normalize_mirror(mirror_base_url)
    fpr = _normalize_fpr(signing_fingerprint)
    os.makedirs(out, exist_ok=True)
    results = []
    for hop, script in HOPS:
        body = render_launcher(template_text, mirror, fpr, hop, script)
        name = "dp-launch-%s.sh" % hop
        path = os.path.join(out, name)
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        os.chmod(path, 0o644)
        digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
        sidecar = path + ".sha256"
        with open(sidecar, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("%s  %s\n" % (digest, name))
        os.chmod(sidecar, 0o644)
        results.append(
            {
                "hop": hop,
                "script": script,
                "name": name,
                "path": path,
                "sha256": digest,
                "sidecar": sidecar,
            }
        )
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--mirror-base-url", required=True)
    parser.add_argument("--signing-fingerprint", required=True)
    parser.add_argument(
        "--print-env",
        action="store_true",
        help="Emit LAUNCHER_* evidence lines after generation",
    )
    args = parser.parse_args(argv)
    try:
        results = build_launchers(
            args.project_root,
            args.output_dir,
            args.mirror_base_url,
            args.signing_fingerprint,
        )
        if args.print_env:
            print("LAUNCHER_SCHEMA_VERSION=%s" % LAUNCHER_SCHEMA_VERSION)
            print("LAUNCHER_COUNT=%s" % len(results))
            for item in results:
                print(
                    "LAUNCHER_BUILT hop=%s name=%s sha256=%s"
                    % (item["hop"], item["name"], item["sha256"])
                )
            print("LAUNCHER_BUILD=PASS")
        return 0
    except Exception as exc:
        print("LAUNCHER_BUILD=FAIL", file=sys.stderr)
        print("LAUNCHER_BUILD_REASON=%s" % str(exc).replace("\n", " "), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
