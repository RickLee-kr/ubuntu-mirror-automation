#!/usr/bin/env bash
# Atomic deploy of xenial→bionic approved client artifacts:
#   - top-level script + sha256 sidecar
#   - per-hop script + manifest + detached signature + hop support files
# Does NOT rebuild/sign artifacts, touch selective READY, or restart nginx.
#
# Fail-closed: refuses SHA mismatch / wrong signer / gpg failure both locally
# and (unless SKIP_HTTP_VERIFY=1) on the HTTP-fetched post-deploy copies.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT="${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh"
SHAFILE="${ARTIFACT}.sha256"
HOP_DIR="${ROOT}/artifacts/client/xenial-to-bionic"
HOP_NAME="xenial-to-bionic"
DEST_ROOT="${DEST_ROOT:-/var/spool/apt-mirror/client}"
NAME="dp-offline-upgrade-xenial-to-bionic.sh"
BUILD_PY="${ROOT}/scripts/lib/build_client_xenial_to_bionic.py"
DEPLOY_PY="${ROOT}/scripts/lib/deploy_client_artifacts_atomic.py"
PUB_KEY="${CLIENT_SIGNING_PUBLIC_KEY:-${LOCAL_CLIENT_SIGNING_DIR:-/etc/ubuntu-mirror/client-signing}/public.gpg}"
if [[ ! -f "$PUB_KEY" ]]; then
  PUB_KEY="${ROOT}/config/client-signing/offline-client-manifest.gpg"
fi
EXPECTED_ARTIFACT_SHA="${EXPECTED_ARTIFACT_SHA:-}"
ALLOWED_FINGERPRINT="${ALLOWED_FINGERPRINT:-}"

[[ -f "$ARTIFACT" && -f "$SHAFILE" ]] || { echo "missing artifact/sha256" >&2; exit 1; }
[[ -d "$HOP_DIR" ]] || { echo "missing hop dir: $HOP_DIR" >&2; exit 1; }
[[ -f "$BUILD_PY" ]] || { echo "missing builder helper: $BUILD_PY" >&2; exit 1; }
[[ -f "$DEPLOY_PY" ]] || { echo "missing deploy helper: $DEPLOY_PY" >&2; exit 1; }
[[ -f "$PUB_KEY" ]] || { echo "missing production public key: $PUB_KEY" >&2; exit 1; }

if [[ -z "$ALLOWED_FINGERPRINT" && -f "$PUB_KEY" ]]; then
  ALLOWED_FINGERPRINT="$(gpg --batch --with-colons --import-options show-only --import "$PUB_KEY" 2>/dev/null | awk -F: '/^fpr:/{print toupper($10); exit}')"
fi
[[ -n "$ALLOWED_FINGERPRINT" ]] || { echo "ALLOWED_FINGERPRINT missing and could not derive from $PUB_KEY" >&2; exit 1; }

ART_SHA="$(sha256sum "$ARTIFACT" | awk '{print $1}')"
SIDECAR_SHA="$(awk '{print $1}' "$SHAFILE")"
[[ "$ART_SHA" == "$SIDECAR_SHA" ]] || { echo "artifact/sidecar SHA mismatch" >&2; exit 1; }
if [[ -n "$EXPECTED_ARTIFACT_SHA" ]]; then
  [[ "$ART_SHA" == "$EXPECTED_ARTIFACT_SHA" ]] || {
    echo "artifact SHA ${ART_SHA} != approved ${EXPECTED_ARTIFACT_SHA}" >&2
    exit 1
  }
fi

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

python3 "$DEPLOY_PY" \
  --artifact "$ARTIFACT" \
  --sidecar "$SHAFILE" \
  --hop-dir "$HOP_DIR" \
  --hop-name "$HOP_NAME" \
  --script-name "$NAME" \
  --dest-root "$DEST_ROOT" \
  --pub-key "$PUB_KEY" \
  --expected-sha "$EXPECTED_ARTIFACT_SHA" \
  --allowed-fingerprint "$ALLOWED_FINGERPRINT"

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ -n "$READY_BEFORE" && "$READY_BEFORE" != "$READY_AFTER" ]]; then
  echo "READY changed unexpectedly" >&2
  exit 1
fi
echo "READY_UNCHANGED=YES"
echo "ARTIFACT_SHA256=${ART_SHA}"

if [[ "${SKIP_HTTP_VERIFY:-0}" == "1" ]]; then
  echo "HTTP_VERIFY=SKIPPED"
  exit 0
fi

MIRROR_BASE="${MIRROR_BASE:-${RESOLVED_MIRROR_BASE_URL:-${MIRROR_HTTP_URL:-}}}"
TMP="$(mktemp)"
trap 'rm -f "$TMP" "${TMP}.sha256" "${TMP}.hop" "${TMP}.manifest" "${TMP}.asc"' EXIT
curl -fsS -o "$TMP" "${MIRROR_BASE}/client/${NAME}"
HTTP_SHA="$(sha256sum "$TMP" | awk '{print $1}')"
echo "HTTP_SHA256=${HTTP_SHA}"
[[ "$HTTP_SHA" == "$ART_SHA" ]] || { echo "HTTP download SHA mismatch" >&2; exit 1; }
curl -fsS -o "${TMP}.sha256" "${MIRROR_BASE}/client/${NAME}.sha256"
HTTP_SIDE="$(awk '{print $1}' "${TMP}.sha256")"
echo "HTTP_SIDECAR_SHA256=${HTTP_SIDE}"
[[ "$HTTP_SIDE" == "$ART_SHA" ]] || { echo "HTTP sidecar SHA mismatch" >&2; exit 1; }

curl -fsS -o "${TMP}.hop" "${MIRROR_BASE}/client/${HOP_NAME}/${NAME}"
HTTP_HOP_SHA="$(sha256sum "${TMP}.hop" | awk '{print $1}')"
echo "HTTP_HOP_SHA256=${HTTP_HOP_SHA}"
[[ "$HTTP_HOP_SHA" == "$ART_SHA" ]] || { echo "HTTP per-hop script SHA mismatch" >&2; exit 1; }

curl -fsS -o "${TMP}.manifest" "${MIRROR_BASE}/client/${HOP_NAME}/client-manifest.json"
curl -fsS -o "${TMP}.asc" "${MIRROR_BASE}/client/${HOP_NAME}/client-manifest.json.asc"
MAN_SHA="$(sha256sum "${TMP}.manifest" | awk '{print $1}')"
REPO_MAN_SHA="$(sha256sum "${HOP_DIR}/client-manifest.json" | awk '{print $1}')"
[[ "$MAN_SHA" == "$REPO_MAN_SHA" ]] || { echo "HTTP manifest SHA mismatch" >&2; exit 1; }

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

# Detached HTTP per-hop manifest verification (temporary GNUPGHOME, public key only).
python3 - "$PUB_KEY" "${TMP}.manifest" "${TMP}.asc" "$ALLOWED_FINGERPRINT" <<'PY'
import os, subprocess, sys, tempfile, shutil
pub, manifest, asc, allowed = sys.argv[1:5]
td = tempfile.mkdtemp(prefix="http-manifest-gpg-")
try:
    env = os.environ.copy(); env["GNUPGHOME"] = td
    subprocess.run(["gpg", "--batch", "--import", pub], check=True, env=env,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p = subprocess.run(
        ["gpg", "--batch", "--status-fd", "1", "--verify", asc, manifest],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
    )
    status = (p.stdout or "") + "\n" + (p.stderr or "")
    validsig = None
    for line in status.splitlines():
        if line.startswith("[GNUPG:] VALIDSIG "):
            validsig = line.split()[2].upper()
            break
    if p.returncode != 0 or validsig != allowed.upper():
        raise SystemExit("HTTP manifest signature verify failed")
    print("HTTP_HOP_MANIFEST_SIGNATURE_VERIFY=PASS")
    print("HTTP_HOP_MANIFEST_SIGNER_FINGERPRINT=" + validsig)
finally:
    shutil.rmtree(td, ignore_errors=True)
PY

echo "HTTP_VERIFY=PASS"
echo "DOWNLOAD=curl -fsSO ${MIRROR_BASE}/client/${NAME}"
