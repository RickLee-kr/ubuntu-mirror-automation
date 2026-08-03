#!/usr/bin/env python3
"""Atomic publication of approved client artifacts (top-level + per-hop).

Copies already-built/signed repository artifacts into an nginx client root.
Does not rebuild scripts, regenerate manifests, or invoke signing keys.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time


HOP_FILES = (
    "client-manifest.json",
    "client-manifest.json.asc",
    "meta-release-lts",
    "ReleaseAnnouncement",
    "ReleaseAnnouncement.html",
    "stellar-offline-manifest.gpg",
    "stellar-offline-upgrade.gpg",
)


class DeployError(Exception):
    pass


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def atomic_install(src: str, dest: str, mode: int, stamp: str) -> list[str]:
    """Backup existing dest, then fsync+os.replace from a temp sibling."""
    events: list[str] = []
    parent = os.path.dirname(dest) or "."
    os.makedirs(parent, exist_ok=True)
    if os.path.isfile(dest):
        bak = "{}.bak-{}".format(dest, stamp)
        shutil.copy2(dest, bak)
        events.append("client_deploy_backup=" + bak)
    tmp = "{}.tmp.{}".format(dest, os.getpid())
    shutil.copy2(src, tmp)
    os.chmod(tmp, mode)
    with open(tmp, "rb") as fh:
        os.fsync(fh.fileno())
    os.replace(tmp, dest)
    dirfd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)
    events.append("client_deploy_atomic=" + dest)
    return events


def verify_detached_manifest(pub_key: str, manifest: str, signature: str, allowed_fpr: str) -> str:
    """Verify detached signature using a temporary GNUPGHOME (public key only)."""
    td = tempfile.mkdtemp(prefix="client-manifest-gpg-")
    try:
        env = os.environ.copy()
        env["GNUPGHOME"] = td
        # Quiet import of the production public key only.
        imp = subprocess.run(
            ["gpg", "--batch", "--import", pub_key],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if imp.returncode != 0:
            raise DeployError("failed to import production public key into temporary keyring")
        ver = subprocess.run(
            ["gpg", "--batch", "--status-fd", "1", "--verify", signature, manifest],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        status = (ver.stdout or "") + "\n" + (ver.stderr or "")
        validsig = None
        for line in status.splitlines():
            if line.startswith("[GNUPG:] VALIDSIG "):
                parts = line.split()
                if len(parts) >= 3:
                    validsig = parts[2].upper()
                    break
        if ver.returncode != 0 or not validsig:
            raise DeployError("manifest detached signature verification failed")
        if validsig != allowed_fpr.upper():
            raise DeployError(
                "manifest signer fingerprint mismatch: got {} expected {}".format(
                    validsig, allowed_fpr.upper()
                )
            )
        return validsig
    finally:
        shutil.rmtree(td, ignore_errors=True)


def extract_pin_manifest_sha(script_path: str) -> str:
    text = open(script_path, "r", encoding="utf-8", errors="replace").read()
    m = re.search(r"PIN_MANIFEST_SHA256='([0-9a-fA-F]{64})'", text)
    if not m:
        raise DeployError("PIN_MANIFEST_SHA256 not found in artifact script")
    return m.group(1).lower()


def deploy(args: argparse.Namespace) -> int:
    artifact = os.path.abspath(args.artifact)
    sidecar = os.path.abspath(args.sidecar)
    hop_dir = os.path.abspath(args.hop_dir)
    dest_root = os.path.abspath(args.dest_root)
    pub_key = os.path.abspath(args.pub_key)
    script_name = args.script_name
    hop_name = args.hop_name
    allowed_fpr = (args.allowed_fingerprint or os.environ.get("ALLOWED_FINGERPRINT", "")).upper()

    for path, label in (
        (artifact, "artifact"),
        (sidecar, "sidecar"),
        (hop_dir, "hop-dir"),
        (pub_key, "pub-key"),
    ):
        if label == "hop-dir":
            if not os.path.isdir(path):
                raise DeployError("missing {}: {}".format(label, path))
        elif not os.path.isfile(path):
            raise DeployError("missing {}: {}".format(label, path))

    # Confine publication target.
    dest_root_real = os.path.realpath(dest_root)
    if not dest_root_real.endswith(os.sep + "client") and os.path.basename(dest_root_real) != "client":
        # Allow test DEST_ROOT names ending with /client or exactly 'client'
        if os.path.basename(dest_root_real) != "client":
            raise DeployError(
                "refusing dest-root that is not a .../client directory: {}".format(dest_root_real)
            )

    hop_script = os.path.join(hop_dir, script_name)
    manifest = os.path.join(hop_dir, "client-manifest.json")
    manifest_asc = os.path.join(hop_dir, "client-manifest.json.asc")
    for required in (hop_script,) + tuple(os.path.join(hop_dir, name) for name in HOP_FILES):
        if not os.path.isfile(required):
            raise DeployError("missing required hop file: {}".format(required))

    art_sha = sha256_file(artifact)
    side_sha = open(sidecar, "r", encoding="utf-8").read().strip().split()[0]
    hop_sha = sha256_file(hop_script)
    if art_sha != side_sha:
        raise DeployError("artifact/sidecar SHA mismatch")
    if art_sha != hop_sha:
        raise DeployError("top-level/per-hop script SHA mismatch")
    if args.expected_sha and art_sha != args.expected_sha.lower():
        raise DeployError(
            "artifact SHA {} does not match expected {}".format(art_sha, args.expected_sha.lower())
        )

    pin_manifest_sha = extract_pin_manifest_sha(artifact)
    file_manifest_sha = sha256_file(manifest)
    if pin_manifest_sha != file_manifest_sha:
        raise DeployError("embedded PIN_MANIFEST_SHA256 does not match hop manifest file")

    signer = verify_detached_manifest(pub_key, manifest, manifest_asc, allowed_fpr)
    print("HOP_MANIFEST_SIGNATURE_VERIFY=PASS")
    print("HOP_MANIFEST_SIGNER_FINGERPRINT=" + signer)
    print("TOP_HOP_SCRIPT_SHA_MATCH=YES")
    print("ARTIFACT_SHA256=" + art_sha)

    # Ensure publication staging stays outside the HTTP alias when possible.
    # Per-file temp siblings under dest are used; never publish *.tmp.* finals.
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    hop_dest = os.path.join(dest_root, hop_name)
    os.makedirs(dest_root, exist_ok=True)
    os.makedirs(hop_dest, exist_ok=True)

    # Deploy hop tree first so top-level cutover sees a matching hop generation.
    for name in (script_name,) + HOP_FILES:
        src = os.path.join(hop_dir, name)
        dest = os.path.join(hop_dest, name)
        mode = 0o755 if name.endswith(".sh") else 0o644
        for event in atomic_install(src, dest, mode, stamp):
            print(event)

    # Top-level compatibility copies (script + sidecar only).
    for src, name, mode in (
        (artifact, script_name, 0o755),
        (sidecar, script_name + ".sha256", 0o644),
    ):
        dest = os.path.join(dest_root, name)
        for event in atomic_install(src, dest, mode, stamp):
            print(event)

    # Post-deploy consistency gates (filesystem).
    live_top = os.path.join(dest_root, script_name)
    live_side = os.path.join(dest_root, script_name + ".sha256")
    live_hop = os.path.join(hop_dest, script_name)
    live_manifest = os.path.join(hop_dest, "client-manifest.json")
    live_asc = os.path.join(hop_dest, "client-manifest.json.asc")
    if sha256_file(live_top) != art_sha:
        raise DeployError("post-deploy top-level script SHA mismatch")
    if sha256_file(live_hop) != art_sha:
        raise DeployError("post-deploy per-hop script SHA mismatch")
    if open(live_side, "r", encoding="utf-8").read().strip().split()[0] != art_sha:
        raise DeployError("post-deploy sidecar SHA mismatch")
    if sha256_file(live_manifest) != file_manifest_sha:
        raise DeployError("post-deploy manifest SHA mismatch")
    post_signer = verify_detached_manifest(pub_key, live_manifest, live_asc, allowed_fpr)
    if post_signer != signer:
        raise DeployError("post-deploy signer fingerprint changed unexpectedly")

    # Refuse leftover temp siblings in dest_root / hop_dest.
    for root in (dest_root, hop_dest):
        for entry in os.listdir(root):
            if ".tmp." in entry:
                raise DeployError("stale temp file left in publication tree: {}".format(entry))

    print("DEPLOY_OK")
    print("HOP_DIR_DEPLOYED=" + hop_dest)
    print("GENERATION_UNIFIED=YES")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--artifact", required=True)
    p.add_argument("--sidecar", required=True)
    p.add_argument("--hop-dir", required=True)
    p.add_argument("--hop-name", required=True)
    p.add_argument("--script-name", required=True)
    p.add_argument("--dest-root", required=True)
    p.add_argument("--pub-key", required=True)
    p.add_argument("--expected-sha", default="")
    p.add_argument("--allowed-fingerprint", default="")
    args = p.parse_args(argv)
    try:
        return deploy(args)
    except DeployError as exc:
        print("DEPLOY_ERROR={}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
