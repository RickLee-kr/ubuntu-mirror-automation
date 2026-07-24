#!/usr/bin/env python3
"""Build the single-file Bionic→Focal offline DP upgrade client artifact.

Does not materialize/publish the selective repository or mutate READY.
Writes client artifacts under a separate directory (default: artifacts/client/).
"""
from __future__ import print_function

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from collections import OrderedDict
from urllib.request import Request, urlopen


HOP = "bionic-to-focal"
SOURCE_CODENAME = "bionic"
TARGET_CODENAME = "focal"
SOURCE_VERSION = "18.04"
TARGET_VERSION = "20.04"
PROFILE_NAME = "offline-upgrade-selective"
KEYRING_INSTALL_PATH = "/etc/apt/trusted.gpg.d/stellar-offline-bionic-to-focal.gpg"
CONFIRM_PHRASE = "UPGRADE-BIONIC-TO-FOCAL"
EXTERNAL_HOST_RE = re.compile(
    r"(archive|security|old-releases|changelogs)\.ubuntu\.com|api\.snapcraft\.io",
    re.I,
)
UNSIGNED_TEST_MARKER = "UNSIGNED" + "_TEST"
PRODUCTION_CLIENT_REL = os.path.join("artifacts", "client")
UNSIGNED_TEST_CLIENT_REL = os.path.join("artifacts", "client-unsigned-test")
CLIENT_SIGNING_PRIV_REL = os.path.join(
    "config", "client-signing", "offline-client-manifest.private.gpg"
)
CLIENT_SIGNING_PUB_REL = os.path.join(
    "config", "client-signing", "offline-client-manifest.gpg"
)


class BuildError(Exception):
    pass


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def http_get(url, timeout=30):
    req = Request(url, headers={"User-Agent": "ubuntu-mirror-build-client/1.0"})
    with urlopen(req, timeout=timeout) as resp:
        code = getattr(resp, "status", None) or resp.getcode()
        if int(code) != 200:
            raise BuildError("HTTP {} for {}".format(code, url))
        return resp.read()


def http_get_text(url, timeout=30):
    return http_get(url, timeout=timeout).decode("utf-8", "replace")


def parse_release_components(release_text):
    for line in release_text.splitlines():
        if line.startswith("Components:"):
            comps = line.split(":", 1)[1].strip().split()
            if not comps:
                raise BuildError("empty Components in Release")
            return comps
    raise BuildError("Components field missing from Release")


def list_suites_from_mirror(mirror_base, hop):
    """Discover suites that have a Release file under the hop ubuntu tree."""
    base = "{}/hops/{}/ubuntu/dists".format(mirror_base.rstrip("/"), hop)
    # Prefer local FS when available; otherwise probe known pocket names.
    candidates = [
        SOURCE_CODENAME,
        SOURCE_CODENAME + "-updates",
        SOURCE_CODENAME + "-security",
        SOURCE_CODENAME + "-backports",
        TARGET_CODENAME,
        TARGET_CODENAME + "-updates",
        TARGET_CODENAME + "-security",
        TARGET_CODENAME + "-backports",
    ]
    found = []
    for suite in candidates:
        url = "{}/{}/Release".format(base, suite)
        try:
            http_get(url, timeout=15)
            found.append(suite)
        except Exception:
            continue
    if SOURCE_CODENAME not in found or TARGET_CODENAME not in found:
        raise BuildError(
            "required suites missing under hop (have: {})".format(",".join(found))
        )
    return found


def dearmor_key(key_bytes):
    """Return binary OpenPGP key material suitable for apt signed-by / gpgv."""
    if key_bytes.startswith(b"-----BEGIN"):
        proc = subprocess.run(
            ["gpg", "--dearmor"],
            input=key_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0 or not proc.stdout:
            raise BuildError("gpg --dearmor failed: {}".format(proc.stderr.decode()))
        return proc.stdout
    return key_bytes


def key_fingerprint(key_bytes):
    """Return 40-char uppercase fingerprint from public key bytes."""
    dearmed = dearmor_key(key_bytes)
    with tempfile.NamedTemporaryFile(prefix="selkey-", suffix=".gpg") as tmp:
        tmp.write(dearmed)
        tmp.flush()
        proc = subprocess.run(
            [
                "gpg",
                "--no-default-keyring",
                "--keyring",
                tmp.name,
                "--with-colons",
                "--fingerprint",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if proc.returncode != 0:
        raise BuildError("fingerprint failed: {}".format(proc.stderr.decode()))
    for line in proc.stdout.decode().splitlines():
        if line.startswith("fpr:"):
            fpr = line.split(":")[9]
            if len(fpr) >= 40:
                return fpr[-40:].upper()
    raise BuildError("no fingerprint in key")


def read_ready_fields(ready_path):
    fields = {}
    if not ready_path or not os.path.isfile(ready_path):
        return fields
    with open(ready_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if "=" in line:
                k, v = line.split("=", 1)
                fields[k.strip()] = v.strip()
    return fields


def build_meta_release_lts(mirror_base, hop, announcement_name="ReleaseAnnouncement"):
    """Build local-only meta-release-lts for Bionic to Focal (no Canonical hosts).

    Client-generated /etc/update-manager/meta-release INI must stay ASCII-only for
    Bionic Python 3.6 configparser under POSIX locale. Dist-format bodies here may
    still carry upstream UTF-8 Description text.
    """
    mb = mirror_base.rstrip("/")
    hop_ubuntu = "{}/hops/{}/ubuntu".format(mb, hop)
    # Include current + target so update-manager can resolve LTS prompt.
    bionic = OrderedDict(
        [
            ("Dist", "bionic"),
            ("Name", "Bionic Beaver"),
            ("Version", "18.04.6 LTS"),
            ("Date", "Thu, 26 April 2018 18:04:00 UTC"),
            ("Supported", "1"),
            ("Description", "This is the 18.04.6 LTS release"),
            ("Release-File", "{}/dists/bionic/Release".format(hop_ubuntu)),
            (
                "ReleaseNotes",
                "{}/client/{}/{}".format(mb, hop, announcement_name),
            ),
            (
                "UpgradeTool",
                "{}/offline/release-upgraders/focal/focal.tar.gz".format(mb),
            ),
            (
                "UpgradeToolSignature",
                "{}/offline/release-upgraders/focal/focal.tar.gz.gpg".format(mb),
            ),
        ]
    )
    focal = OrderedDict(
        [
            ("Dist", "focal"),
            ("Name", "Focal Fossa"),
            ("Version", "20.04.6 LTS"),
            ("Date", "Thu, 23 April 2020 20:04:00 UTC"),
            ("Supported", "1"),
            ("Description", "This is the 20.04.6 LTS release"),
            ("Release-File", "{}/dists/focal/Release".format(hop_ubuntu)),
            (
                "ReleaseNotes",
                "{}/client/{}/{}".format(mb, hop, announcement_name),
            ),
            (
                "ReleaseNotesHtml",
                "{}/client/{}/ReleaseAnnouncement.html".format(mb, hop),
            ),
            (
                "UpgradeTool",
                "{}/offline/release-upgraders/focal/focal.tar.gz".format(mb),
            ),
            (
                "UpgradeToolSignature",
                "{}/offline/release-upgraders/focal/focal.tar.gz.gpg".format(mb),
            ),
        ]
    )
    blocks = []
    for entry in (bionic, focal):
        lines = ["{}: {}".format(k, v) for k, v in entry.items()]
        blocks.append("\n".join(lines))
    text = "\n\n".join(blocks) + "\n"
    if EXTERNAL_HOST_RE.search(text):
        raise BuildError("generated meta-release still contains external hosts")
    return text




def extract_announcements(upgrader_tar_path, dest_dir):
    os.makedirs(dest_dir, exist_ok=True)
    names = ("ReleaseAnnouncement", "ReleaseAnnouncement.html")
    extracted = {}
    with tarfile.open(upgrader_tar_path, "r:gz") as tf:
        for name in names:
            try:
                member = tf.getmember("./" + name)
            except KeyError:
                try:
                    member = tf.getmember(name)
                except KeyError:
                    continue
            fh = tf.extractfile(member)
            if fh is None:
                continue
            data = fh.read()
            out = os.path.join(dest_dir, name)
            with open(out, "wb") as out_fh:
                out_fh.write(data)
            extracted[name] = sha256_bytes(data)
    if "ReleaseAnnouncement" not in extracted:
        raise BuildError("ReleaseAnnouncement missing from upgrader tar")
    return extracted


def gpg_detach_sign(private_key_path, payload_path, sig_path):
    homedir = tempfile.mkdtemp(prefix="client-sign-")
    try:
        proc = subprocess.run(
            ["gpg", "--homedir", homedir, "--batch", "--import", private_key_path],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise BuildError(
                "gpg import failed: {}".format(proc.stderr.decode("utf-8", "replace"))
            )
        if os.path.exists(sig_path):
            os.remove(sig_path)
        proc = subprocess.run(
            [
                "gpg",
                "--homedir",
                homedir,
                "--batch",
                "--yes",
                "--armor",
                "--detach-sign",
                "-o",
                sig_path,
                payload_path,
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if proc.returncode != 0:
            raise BuildError(
                "gpg detach-sign failed: {}".format(proc.stderr.decode("utf-8", "replace"))
            )
    finally:
        shutil.rmtree(homedir, ignore_errors=True)


def production_client_dir(project_root):
    return os.path.abspath(os.path.join(project_root, PRODUCTION_CLIENT_REL))


def unsigned_test_client_dir(project_root):
    return os.path.abspath(os.path.join(project_root, UNSIGNED_TEST_CLIENT_REL))


def is_production_output_dir(project_root, output_dir):
    """True when output_dir is the production artifacts/client tree."""
    prod = production_client_dir(project_root)
    out = os.path.abspath(output_dir)
    return out == prod or out.startswith(prod + os.sep)


def client_signing_paths(project_root):
    return (
        os.path.join(project_root, CLIENT_SIGNING_PRIV_REL),
        os.path.join(project_root, CLIENT_SIGNING_PUB_REL),
    )


def resolve_production_manifest_signing_key(project_root):
    """Return (private_path, public_bytes, fingerprint) for production signing.

    Uses only config/client-signing/offline-client-manifest.* — never auto-generates
    and never falls back to the selective repository private key.
    """
    priv, pub = client_signing_paths(project_root)
    if not os.path.isfile(priv) or not os.access(priv, os.R_OK):
        raise BuildError(
            "production client manifest signing key missing or unreadable: {}".format(
                priv
            )
        )
    if not os.path.isfile(pub) or not os.access(pub, os.R_OK):
        raise BuildError(
            "production client manifest public key missing or unreadable: {}".format(pub)
        )
    pub_raw = open(pub, "rb").read()
    return priv, pub_raw, key_fingerprint(pub_raw)


def ensure_manifest_signing_key(project_root, allow_generate=False):
    """Return (private_path, public_bytes) for client-manifest signing.

    Production builds must call resolve_production_manifest_signing_key() instead.
    When allow_generate is True (test helpers only), missing keys may be created
    under config/client-signing/ — never used for production artifacts/client.
    """
    signing_dir = os.path.join(project_root, "config", "client-signing")
    os.makedirs(signing_dir, exist_ok=True)
    priv, pub = client_signing_paths(project_root)
    if os.path.isfile(priv) and os.path.isfile(pub):
        return priv, open(pub, "rb").read()
    if not allow_generate:
        raise BuildError(
            "client manifest signing key missing (generation disabled): {}".format(priv)
        )

    homedir = tempfile.mkdtemp(prefix="client-keygen-")
    try:
        batch = os.path.join(homedir, "batch")
        with open(batch, "w", encoding="utf-8") as fh:
            fh.write(
                "Key-Type: RSA\nKey-Length: 2048\nName-Real: Stellar Offline Client Manifest\n"
                "Name-Email: offline-client-manifest@local\nExpire-Date: 0\n%no-protection\n%commit\n"
            )
        subprocess.run(
            ["gpg", "--homedir", homedir, "--batch", "--gen-key", batch],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            [
                "gpg",
                "--homedir",
                homedir,
                "--batch",
                "--export-secret-keys",
                "--armor",
                "-o",
                priv,
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["gpg", "--homedir", homedir, "--batch", "--export", "-o", pub],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        os.chmod(priv, 0o600)
        os.chmod(pub, 0o644)
    finally:
        shutil.rmtree(homedir, ignore_errors=True)
    return priv, open(pub, "rb").read()


def extract_pinned_b64(script_text, pin_name):
    """Extract a PIN_<name>='...' single-quoted value (may be multiline)."""
    token = "PIN_{}='".format(pin_name)
    start = script_text.find(token)
    if start < 0:
        raise BuildError("pin {} missing from client artifact".format(pin_name))
    start += len(token)
    end = script_text.find("'", start)
    if end < 0:
        raise BuildError("pin {} is not terminated".format(pin_name))
    return script_text[start:end]


def decode_pinned_b64(script_text, pin_name):
    raw = extract_pinned_b64(script_text, pin_name)
    compact = re.sub(r"\s+", "", raw)
    try:
        return base64.b64decode(compact)
    except Exception as exc:
        raise BuildError("pin {} base64 decode failed: {}".format(pin_name, exc))


def count_unsigned_test(data):
    if isinstance(data, bytes):
        return data.count(UNSIGNED_TEST_MARKER.encode("ascii"))
    return data.count(UNSIGNED_TEST_MARKER)


def gpgv_verify(key_bin, sig_bytes, payload_bytes):
    """Verify detached armored/binary signature; raise BuildError on failure."""
    with tempfile.TemporaryDirectory(prefix="client-gpgv-") as td:
        key_path = os.path.join(td, "key.gpg")
        sig_path = os.path.join(td, "payload.asc")
        payload_path = os.path.join(td, "payload")
        with open(key_path, "wb") as fh:
            if key_bin.startswith(b"-----BEGIN"):
                fh.write(dearmor_key(key_bin))
            else:
                fh.write(key_bin)
        with open(sig_path, "wb") as fh:
            fh.write(sig_bytes)
        with open(payload_path, "wb") as fh:
            fh.write(payload_bytes)
        proc = subprocess.run(
            ["gpgv", "--keyring", key_path, sig_path, payload_path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise BuildError(
                "gpgv verification failed: {}".format(
                    proc.stderr.decode("utf-8", "replace")
                )
            )


def verify_client_artifact_signature(script_path, allowed_fingerprint=None):
    """Extract embedded manifest/sig/key and verify production signature.

    Returns dict with fingerprint and unsigned_test_count.
    """
    script_text = open(script_path, "r", encoding="utf-8", errors="replace").read()
    unsigned_count = count_unsigned_test(script_text)
    manifest = decode_pinned_b64(script_text, "MANIFEST_B64")
    sig = decode_pinned_b64(script_text, "MANIFEST_SIG_B64")
    key = decode_pinned_b64(script_text, "MANIFEST_KEY_B64")
    pin_fpr = extract_pinned_b64(script_text, "MANIFEST_KEY_FINGERPRINT").strip().upper()
    unsigned_count += count_unsigned_test(sig)
    if unsigned_count:
        raise BuildError(
            "UNSIGNED_TEST present in client artifact (count={})".format(unsigned_count)
        )
    if not sig or not manifest or not key:
        raise BuildError("embedded manifest signature material missing")
    if UNSIGNED_TEST_MARKER.encode("ascii") in sig:
        raise BuildError("embedded manifest signature is UNSIGNED_TEST")
    key_fpr = key_fingerprint(key)
    if pin_fpr != key_fpr:
        raise BuildError(
            "embedded manifest key fingerprint mismatch pin={} key={}".format(
                pin_fpr, key_fpr
            )
        )
    if allowed_fingerprint and key_fpr != allowed_fingerprint.upper():
        raise BuildError(
            "manifest signer fingerprint not allowed: got {} want {}".format(
                key_fpr, allowed_fingerprint.upper()
            )
        )
    gpgv_verify(key, sig, manifest)
    return {
        "fingerprint": key_fpr,
        "unsigned_test_count": 0,
        "manifest_sha256": sha256_bytes(manifest),
    }


def first_pool_filename_from_packages_gz(packages_gz_bytes):
    import gzip

    text = gzip.decompress(packages_gz_bytes).decode("utf-8", "replace")
    for line in text.splitlines():
        if line.startswith("Filename:"):
            return line.split(":", 1)[1].strip()
    raise BuildError("no Filename in Packages.gz")


def render_script(template_path, replacements):
    with open(template_path, "r", encoding="utf-8") as fh:
        body = fh.read()
    for key, value in replacements.items():
        token = "@@{}@@".format(key)
        if token not in body:
            raise BuildError("template missing token {}".format(token))
        body = body.replace(token, value)
    leftover = re.findall(r"@@[A-Z0-9_]+@@", body)
    if leftover:
        raise BuildError("unreplaced template tokens: {}".format(", ".join(leftover)))
    return body


def bash_single_quote(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project-root", required=True)
    ap.add_argument("--mirror-base", required=True, help="e.g. http://221.139.249.111")
    ap.add_argument(
        "--selective-root",
        default="/var/spool/apt-mirror/selective",
        help="local selective root for keys/READY/upgraders",
    )
    ap.add_argument(
        "--output-dir",
        default="",
        help="default: <project-root>/artifacts/client",
    )
    ap.add_argument(
        "--template",
        default="",
        help="default: client/dp-offline-upgrade-bionic-to-focal.sh.in",
    )
    ap.add_argument(
        "--deploy-nginx-root",
        default="",
        help="optional directory nginx /client/ will alias (copy artifacts here)",
    )
    ap.add_argument(
        "--skip-sign",
        action="store_true",
        help="emit UNSIGNED_TEST placeholder (test paths only; never artifacts/client)",
    )
    args = ap.parse_args(argv)

    project_root = os.path.abspath(args.project_root)
    mirror_base = args.mirror_base.rstrip("/")
    selective_root = args.selective_root
    if args.skip_sign:
        default_out = unsigned_test_client_dir(project_root)
    else:
        default_out = production_client_dir(project_root)
    out_dir = os.path.abspath(args.output_dir or default_out)
    if args.skip_sign:
        if is_production_output_dir(project_root, out_dir):
            raise BuildError(
                "--skip-sign refuses production output dir {}".format(out_dir)
            )
        if args.deploy_nginx_root:
            raise BuildError("--skip-sign refuses --deploy-nginx-root")
        nginx_probe = os.path.abspath(args.deploy_nginx_root) if args.deploy_nginx_root else ""
        if nginx_probe and (
            nginx_probe == "/var/spool/apt-mirror/client"
            or nginx_probe.startswith("/var/spool/apt-mirror/client" + os.sep)
        ):
            raise BuildError("--skip-sign refuses nginx client path")
    elif args.output_dir and not is_production_output_dir(project_root, out_dir):
        # Signed builds may still target temp dirs (unit tests); production path
        # is the default. Non-production signed builds are allowed.
        pass
    hop_out = os.path.join(out_dir, HOP)
    template = args.template or os.path.join(
        project_root, "client", "dp-offline-upgrade-bionic-to-focal.sh.in"
    )
    if not os.path.isfile(template):
        raise BuildError("template not found: {}".format(template))

    key_path = os.path.join(selective_root, "keys", "ubuntu-mirror-selective.gpg")
    ready_path = os.path.join(selective_root, "state", "READY")
    upgrader_tar = os.path.join(
        selective_root,
        "current",
        "shared",
        "offline",
        "release-upgraders",
        "focal",
        "focal.tar.gz",
    )
    upgrader_gpg = upgrader_tar + ".gpg"

    for path in (key_path, upgrader_tar, upgrader_gpg):
        if not os.path.isfile(path):
            raise BuildError("required file missing: {}".format(path))

    os.makedirs(hop_out, exist_ok=True)

    key_raw = open(key_path, "rb").read()
    key_bin = dearmor_key(key_raw)
    key_sha = sha256_bytes(key_bin)
    fingerprint = key_fingerprint(key_raw)

    source_release = http_get_text(
        "{}/hops/{}/ubuntu/dists/{}/Release".format(mirror_base, HOP, SOURCE_CODENAME)
    )
    target_release = http_get_text(
        "{}/hops/{}/ubuntu/dists/{}/Release".format(mirror_base, HOP, TARGET_CODENAME)
    )
    components = parse_release_components(source_release)
    target_components = parse_release_components(target_release)
    if components != target_components:
        # Prefer intersection to avoid 404s; fail if empty.
        components = [c for c in components if c in target_components]
        if not components:
            raise BuildError("no shared Components between bionic and focal Release")

    suites = list_suites_from_mirror(mirror_base, HOP)
    source_suites = [s for s in suites if s == SOURCE_CODENAME or s.startswith(SOURCE_CODENAME + "-")]
    target_suites = [s for s in suites if s == TARGET_CODENAME or s.startswith(TARGET_CODENAME + "-")]

    announcements = extract_announcements(upgrader_tar, hop_out)
    meta_text = build_meta_release_lts(mirror_base, HOP)
    meta_path = os.path.join(hop_out, "meta-release-lts")
    with open(meta_path, "w", encoding="utf-8") as fh:
        fh.write(meta_text)
    meta_sha = sha256_file(meta_path)

    up_tar_sha = sha256_file(upgrader_tar)
    up_gpg_sha = sha256_file(upgrader_gpg)

    # Sample connectivity probe from *target* suite Packages (source suites are
    # intentionally empty of discovery payloads after suite-semantics fix).
    sample_suite = TARGET_CODENAME
    packages_gz = http_get(
        "{}/hops/{}/ubuntu/dists/{}/main/binary-amd64/Packages.gz".format(
            mirror_base, HOP, sample_suite
        )
    )
    sample_deb_rel = first_pool_filename_from_packages_gz(packages_gz)
    if not sample_deb_rel:
        raise BuildError(
            "no pool Filename in {} Packages.gz (target suite empty?)".format(sample_suite)
        )
    sample_deb_url = "{}/hops/{}/ubuntu/{}".format(mirror_base, HOP, sample_deb_rel)

    ready = read_ready_fields(ready_path)
    plan_checksum = (
        ready.get("selective_plan_checksum")
        or ready.get("plan_checksum")
        or ""
    )
    discovery_checksum = ready.get("discovery_artifact_checksum") or ""
    if not plan_checksum or not discovery_checksum:
        raise BuildError(
            "READY missing plan/discovery checksums (refusing to invent values)"
        )

    # Verify InRelease with dearmored key
    inrelease = http_get(
        "{}/hops/{}/ubuntu/dists/{}/InRelease".format(mirror_base, HOP, SOURCE_CODENAME)
    )
    with tempfile.TemporaryDirectory(prefix="inrel-") as td:
        key_f = os.path.join(td, "key.gpg")
        ir_f = os.path.join(td, "InRelease")
        with open(key_f, "wb") as fh:
            fh.write(key_bin)
        with open(ir_f, "wb") as fh:
            fh.write(inrelease)
        proc = subprocess.run(
            ["gpgv", "--keyring", key_f, ir_f],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise BuildError(
                "InRelease signature verification failed: {}".format(
                    proc.stderr.decode()
                )
            )

    generated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    repo_base = "{}/hops/{}/ubuntu".format(mirror_base, HOP)

    # Resolve manifest signing key before writing manifest JSON.
    # Production always uses config/client-signing (never selective private,
    # never auto-generated keys).
    manifest_key_bin = key_bin
    manifest_key_fpr = fingerprint
    manifest_key_sha = key_sha
    sign_priv = None
    allowed_production_fpr = None
    if not args.skip_sign:
        sign_priv, manifest_pub_raw, manifest_key_fpr = (
            resolve_production_manifest_signing_key(project_root)
        )
        manifest_key_bin = dearmor_key(manifest_pub_raw)
        manifest_key_sha = sha256_bytes(manifest_key_bin)
        allowed_production_fpr = manifest_key_fpr
        print(
            "manifest_signing_key=production-client-signing ({})".format(
                os.path.join("config", "client-signing")
            )
        )

    manifest = OrderedDict(
        [
            ("schema_version", 1),
            ("profile", PROFILE_NAME),
            ("hop", HOP),
            ("source_codename", SOURCE_CODENAME),
            ("target_codename", TARGET_CODENAME),
            ("source_version", SOURCE_VERSION),
            ("target_version", TARGET_VERSION),
            ("mirror_base", mirror_base),
            ("repository_base", repo_base),
            ("suites", suites),
            ("source_suites", source_suites),
            ("target_suites", target_suites),
            ("components", components),
            ("repository_key_fingerprint", fingerprint),
            ("key_sha256", key_sha),
            ("manifest_key_fingerprint", manifest_key_fpr),
            ("manifest_key_sha256", manifest_key_sha),
            ("keyring_install_path", KEYRING_INSTALL_PATH),
            (
                "meta_release_url",
                "{}/client/{}/meta-release-lts".format(mirror_base, HOP),
            ),
            ("meta_release_sha256", meta_sha),
            (
                "upgrader_tar_url",
                "{}/offline/release-upgraders/focal/focal.tar.gz".format(mirror_base),
            ),
            ("upgrader_tar_sha256", up_tar_sha),
            (
                "upgrader_gpg_url",
                "{}/offline/release-upgraders/focal/focal.tar.gz.gpg".format(
                    mirror_base
                ),
            ),
            ("upgrader_gpg_sha256", up_gpg_sha),
            ("sample_deb_url", sample_deb_url),
            ("plan_checksum", plan_checksum),
            ("discovery_checksum", discovery_checksum),
            ("confirm_phrase", CONFIRM_PHRASE),
            ("generated_at", generated_at),
            ("announcements", announcements),
        ]
    )
    manifest_path = os.path.join(hop_out, "client-manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=False)
        fh.write("\n")
    manifest_sha = sha256_file(manifest_path)

    sig_path = os.path.join(hop_out, "client-manifest.json.asc")
    signed = False
    if args.skip_sign:
        with open(sig_path, "w", encoding="utf-8") as fh:
            fh.write(
                "-----BEGIN PGP SIGNATURE-----\n{}\n-----END PGP SIGNATURE-----\n".format(
                    UNSIGNED_TEST_MARKER
                )
            )
        manifest_sig_b64 = base64.b64encode(open(sig_path, "rb").read()).decode("ascii")
        print("CLIENT_MANIFEST_SIGNATURE_MODE=UNSIGNED_TEST")
    else:
        gpg_detach_sign(sign_priv, manifest_path, sig_path)
        manifest_sig_b64 = base64.b64encode(open(sig_path, "rb").read()).decode("ascii")
        signed = True
        # Fail-closed: refuse any UNSIGNED_TEST placeholder in the detached sig.
        sig_raw = open(sig_path, "rb").read()
        if count_unsigned_test(sig_raw):
            raise BuildError("production signature unexpectedly contains UNSIGNED_TEST")
        gpgv_verify(manifest_key_bin, sig_raw, open(manifest_path, "rb").read())

    # Persist repository + manifest public keys (dearmored) beside artifacts
    key_out = os.path.join(hop_out, "stellar-offline-upgrade.gpg")
    with open(key_out, "wb") as fh:
        fh.write(key_bin)
    manifest_key_out = os.path.join(hop_out, "stellar-offline-manifest.gpg")
    with open(manifest_key_out, "wb") as fh:
        fh.write(manifest_key_bin)

    key_b64 = base64.b64encode(key_bin).decode("ascii")
    # wrap base64 for readability
    key_b64_wrapped = "\n".join(
        key_b64[i : i + 76] for i in range(0, len(key_b64), 76)
    )
    manifest_key_b64 = base64.b64encode(manifest_key_bin).decode("ascii")
    manifest_key_b64_wrapped = "\n".join(
        manifest_key_b64[i : i + 76] for i in range(0, len(manifest_key_b64), 76)
    )
    meta_b64 = base64.b64encode(meta_text.encode("utf-8")).decode("ascii")
    meta_b64_wrapped = "\n".join(meta_b64[i : i + 76] for i in range(0, len(meta_b64), 76))
    # Embed exact file bytes so PIN_MANIFEST_SHA256 matches decoded content
    manifest_raw = open(manifest_path, "rb").read()
    if sha256_bytes(manifest_raw) != manifest_sha:
        raise BuildError("internal error: manifest sha mismatch before embed")
    manifest_b64 = base64.b64encode(manifest_raw).decode("ascii")
    manifest_b64_wrapped = "\n".join(
        manifest_b64[i : i + 76] for i in range(0, len(manifest_b64), 76)
    )
    sig_b64_wrapped = "\n".join(
        manifest_sig_b64[i : i + 76] for i in range(0, len(manifest_sig_b64), 76)
    )

    ann_text = open(
        os.path.join(hop_out, "ReleaseAnnouncement"), "r", encoding="utf-8", errors="replace"
    ).read()
    ann_b64 = base64.b64encode(ann_text.encode("utf-8")).decode("ascii")
    ann_b64_wrapped = "\n".join(ann_b64[i : i + 76] for i in range(0, len(ann_b64), 76))

    replacements = {
        "MIRROR_BASE": mirror_base,
        "HOP": HOP,
        "SOURCE_CODENAME": SOURCE_CODENAME,
        "TARGET_CODENAME": TARGET_CODENAME,
        "SOURCE_VERSION": SOURCE_VERSION,
        "TARGET_VERSION": TARGET_VERSION,
        "COMPONENTS": " ".join(components),
        "SOURCE_SUITES": " ".join(source_suites),
        "TARGET_SUITES": " ".join(target_suites),
        "KEY_FINGERPRINT": fingerprint,
        "KEY_SHA256": key_sha,
        "KEY_B64": key_b64_wrapped,
        "MANIFEST_KEY_FINGERPRINT": manifest_key_fpr,
        "MANIFEST_KEY_SHA256": manifest_key_sha,
        "MANIFEST_KEY_B64": manifest_key_b64_wrapped,
        "META_SHA256": meta_sha,
        "META_B64": meta_b64_wrapped,
        "UPGRADER_TAR_SHA256": up_tar_sha,
        "UPGRADER_GPG_SHA256": up_gpg_sha,
        "PLAN_CHECKSUM": plan_checksum,
        "DISCOVERY_CHECKSUM": discovery_checksum,
        "MANIFEST_SHA256": manifest_sha,
        "MANIFEST_B64": manifest_b64_wrapped,
        "MANIFEST_SIG_B64": sig_b64_wrapped,
        "SAMPLE_DEB_URL": sample_deb_url,
        "CONFIRM_PHRASE": CONFIRM_PHRASE,
        "ANNOUNCEMENT_B64": ann_b64_wrapped,
        "GENERATED_AT": generated_at,
        "PROFILE_NAME": PROFILE_NAME,
    }

    script_body = render_script(template, replacements)
    script_name = "dp-offline-upgrade-bionic-to-focal.sh"
    script_path = os.path.join(out_dir, script_name)
    # also place under hop dir; production signed builds also refresh client/
    with open(script_path, "w", encoding="utf-8") as fh:
        fh.write(script_body)
        if not script_body.endswith("\n"):
            fh.write("\n")
    os.chmod(script_path, 0o755)
    hop_script = os.path.join(hop_out, script_name)
    shutil.copy2(script_path, hop_script)
    client_script = os.path.join(project_root, "client", script_name)
    if not args.skip_sign:
        # Never let unsigned test builds overwrite the repo client/ copy.
        shutil.copy2(script_path, client_script)
        os.chmod(client_script, 0o755)
    else:
        client_script = ""

    script_sha = sha256_file(script_path)
    sha_path = os.path.join(out_dir, script_name + ".sha256")
    with open(sha_path, "w", encoding="utf-8") as fh:
        fh.write("{}  {}\n".format(script_sha, script_name))

    if not args.skip_sign:
        # Fail-closed production gates on the final artifact.
        verify_info = verify_client_artifact_signature(
            script_path, allowed_fingerprint=allowed_production_fpr
        )
        print("CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED")
        print("CLIENT_MANIFEST_SIGNATURE_STATUS=PASS")
        print(
            "CLIENT_MANIFEST_SIGNER_FINGERPRINT={}".format(verify_info["fingerprint"])
        )
        print(
            "CLIENT_MANIFEST_UNSIGNED_TEST_COUNT={}".format(
                verify_info["unsigned_test_count"]
            )
        )
        print("ARTIFACT_SIGNATURE_VERIFY=PASS")

    # Optional nginx client root deploy:
    # Only top-level client script + .sha256 (never selective READY / DP publish).
    # Backup existing files, then atomic temp+fsync+rename replace.
    # Unsigned test builds already refused --deploy-nginx-root above.
    if args.deploy_nginx_root:
        deploy_root = args.deploy_nginx_root
        os.makedirs(deploy_root, exist_ok=True)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        for src, name in ((script_path, script_name), (sha_path, script_name + ".sha256")):
            dest = os.path.join(deploy_root, name)
            if os.path.isfile(dest):
                bak = "{}.bak-{}".format(dest, stamp)
                shutil.copy2(dest, bak)
                print("client_deploy_backup={}".format(bak))
            tmp = "{}.tmp.{}".format(dest, os.getpid())
            shutil.copy2(src, tmp)
            os.chmod(tmp, 0o755 if name.endswith(".sh") else 0o644)
            # fsync file + directory for durable atomic replace
            with open(tmp, "rb") as fh:
                os.fsync(fh.fileno())
            os.replace(tmp, dest)
            dirfd = os.open(deploy_root, os.O_RDONLY)
            try:
                os.fsync(dirfd)
            finally:
                os.close(dirfd)
            print("client_deploy_atomic={}".format(dest))
        # Intentionally do NOT modify hop bundle / selective / READY here.

    summary = OrderedDict(
        [
            ("status", "PASS"),
            ("script_path", script_path),
            ("client_script_path", client_script),
            ("script_sha256", script_sha),
            ("manifest_path", manifest_path),
            ("manifest_sha256", manifest_sha),
            ("manifest_signed", signed),
            ("mirror_base", mirror_base),
            ("components", components),
            ("source_suites", source_suites),
            ("key_fingerprint", fingerprint),
            ("key_sha256", key_sha),
            ("meta_release_sha256", meta_sha),
            ("upgrader_tar_sha256", up_tar_sha),
            ("plan_checksum", plan_checksum),
            ("discovery_checksum", discovery_checksum),
            ("generated_at", generated_at),
        ]
    )
    summary_path = os.path.join(out_dir, "build-summary.json")
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")

    print("BUILD_CLIENT_BIONIC_TO_FOCAL PASS")
    print("script={}".format(script_path))
    print("sha256={}".format(script_sha))
    print("fingerprint={}".format(fingerprint))
    print("components={}".format(" ".join(components)))
    print("manifest_signed={}".format(signed))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildError as exc:
        print("BUILD_CLIENT_BIONIC_TO_FOCAL FAIL: {}".format(exc), file=sys.stderr)
        sys.exit(1)
