#!/usr/bin/env bash
# Atomic deploy of xenial→bionic client script + sha256 sidecar only.
# Does NOT touch selective READY, hop package trees, or DP publish.
#
# Fail-closed: refuses UNSIGNED_TEST / wrong signer / gpgv failure / SHA mismatch
# both on the local artifact and on the HTTP-fetched post-deploy copy.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh"
SHAFILE="${ARTIFACT}.sha256"
DEST_ROOT="${DEST_ROOT:-/var/spool/apt-mirror/client}"
NAME="dp-offline-upgrade-xenial-to-bionic.sh"
BUILD_PY="${ROOT}/scripts/lib/build_client_xenial_to_bionic.py"
PUB_KEY="${ROOT}/config/client-signing/offline-client-manifest.gpg"

[[ -f "$ARTIFACT" && -f "$SHAFILE" ]] || { echo "missing artifact/sha256" >&2; exit 1; }
[[ -f "$BUILD_PY" ]] || { echo "missing builder helper: $BUILD_PY" >&2; exit 1; }
[[ -f "$PUB_KEY" ]] || { echo "missing production public key: $PUB_KEY" >&2; exit 1; }

ART_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
SIDECAR_SHA="$(awk '{print $1}' "$SHAFILE")"
[[ "$ART_SHA" == "$SIDECAR_SHA" ]] || { echo "artifact/sidecar SHA mismatch" >&2; exit 1; }

READY_PATH="${READY_PATH:-/var/spool/apt-mirror/selective/state/READY}"
READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"

# Pre-deploy: extract embedded manifest and verify production signature.
VERIFY_OUT="$(
  python3 - "$BUILD_PY" "$ARTIFACT" "$PUB_KEY" <<'PY'
import importlib.util, sys
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
info = mod.verify_client_artifact_signature(artifact, allowed_fingerprint=allowed)
print("CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED")
print("CLIENT_MANIFEST_SIGNATURE_STATUS=PASS")
print("CLIENT_MANIFEST_SIGNER_FINGERPRINT=" + info["fingerprint"])
print("CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=" + str(info["unsigned_test_count"]))
print("ARTIFACT_SIGNATURE_VERIFY=PASS")
print("ALLOWED_FINGERPRINT=" + allowed)
PY
)" || {
  echo "pre-deploy signature verification FAILED" >&2
  exit 1
}
printf '%s\n' "$VERIFY_OUT"

python3 - "$ARTIFACT" "$SHAFILE" "$DEST_ROOT" "$NAME" <<'PY'
import os, shutil, sys, time
script_path, sha_path, deploy_root, script_name = sys.argv[1:5]
stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
os.makedirs(deploy_root, exist_ok=True)
for src, name in ((script_path, script_name), (sha_path, script_name + ".sha256")):
    dest = os.path.join(deploy_root, name)
    if os.path.isfile(dest):
        bak = "{}.bak-{}".format(dest, stamp)
        shutil.copy2(dest, bak)
        print("client_deploy_backup=" + bak)
    tmp = "{}.tmp.{}".format(dest, os.getpid())
    shutil.copy2(src, tmp)
    os.chmod(tmp, 0o755 if name.endswith(".sh") else 0o644)
    with open(tmp, "rb") as fh:
        os.fsync(fh.fileno())
    os.replace(tmp, dest)
    dirfd = os.open(deploy_root, os.O_RDONLY)
    try:
        os.fsync(dirfd)
    finally:
        os.close(dirfd)
    print("client_deploy_atomic=" + dest)
print("DEPLOY_OK")
PY

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ -n "$READY_BEFORE" && "$READY_BEFORE" != "$READY_AFTER" ]]; then
  echo "READY changed unexpectedly" >&2
  exit 1
fi
echo "READY_UNCHANGED=YES"
echo "ARTIFACT_SHA256=${ART_SHA}"

MIRROR_BASE="${MIRROR_BASE:-http://221.139.249.111}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsS -o "$TMP" "${MIRROR_BASE}/client/${NAME}"
HTTP_SHA="$(sha256sum "$TMP" | awk '{print $1}')"
echo "HTTP_SHA256=${HTTP_SHA}"
[[ "$HTTP_SHA" == "$ART_SHA" ]] || { echo "HTTP download SHA mismatch" >&2; exit 1; }
curl -fsS -o "${TMP}.sha256" "${MIRROR_BASE}/client/${NAME}.sha256"
HTTP_SIDE="$(awk '{print $1}' "${TMP}.sha256")"
rm -f "${TMP}.sha256"
echo "HTTP_SIDECAR_SHA256=${HTTP_SIDE}"
[[ "$HTTP_SIDE" == "$ART_SHA" ]] || { echo "HTTP sidecar SHA mismatch" >&2; exit 1; }

HTTP_VERIFY_OUT="$(
  python3 - "$BUILD_PY" "$TMP" "$PUB_KEY" <<'PY'
import importlib.util, sys
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
info = mod.verify_client_artifact_signature(artifact, allowed_fingerprint=allowed)
print("HTTP_SIGNATURE_VERIFY=PASS")
print("CLIENT_MANIFEST_SIGNER_FINGERPRINT=" + info["fingerprint"])
print("CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=" + str(info["unsigned_test_count"]))
PY
)" || {
  echo "HTTP signature verification FAILED" >&2
  exit 1
}
printf '%s\n' "$HTTP_VERIFY_OUT"
echo "HTTP_VERIFY=PASS"
echo "DOWNLOAD=curl -fsSO ${MIRROR_BASE}/client/${NAME}"
