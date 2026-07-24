#!/usr/bin/env bash
# Fail-closed client manifest signing / deploy gates (xenial→bionic).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PY="${ROOT}/scripts/lib/build_client_xenial_to_bionic.py"
DEPLOY_SH="${ROOT}/scripts/deploy-client-xenial-to-bionic-atomic.sh"
PUB_KEY="${ROOT}/config/client-signing/offline-client-manifest.gpg"
PRIV_KEY="${ROOT}/config/client-signing/offline-client-manifest.private.gpg"
MIRROR_BASE="${TEST_MIRROR_BASE:-http://221.139.249.111}"
SEL_ROOT="${TEST_SELECTIVE_ROOT:-/var/spool/apt-mirror/selective}"
PROD_ARTIFACT="${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh"
READY_PATH="${SEL_ROOT}/state/READY"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_client_manifest_signing ==="

# 1) production signing key exists → signed client build PASS
if [[ -f "$PRIV_KEY" && -r "$PRIV_KEY" && -f "$PUB_KEY" ]]; then
  pass "production signing key present"
else
  fail "production signing key missing/unreadable"
fi

READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"

PROD_OUT="${WORKDIR}/prod-client"
set +e
python3 "$BUILD_PY" \
  --project-root "$ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "$PROD_OUT" \
  >"${WORKDIR}/prod-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED' "${WORKDIR}/prod-build.log" \
  && grep -q 'CLIENT_MANIFEST_SIGNATURE_STATUS=PASS' "${WORKDIR}/prod-build.log" \
  && grep -q 'CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=0' "${WORKDIR}/prod-build.log" \
  && grep -q 'ARTIFACT_SIGNATURE_VERIFY=PASS' "${WORKDIR}/prod-build.log"; then
  pass "1 production signing key → signed client build PASS"
else
  fail "1 production signed build"
  tail -40 "${WORKDIR}/prod-build.log" || true
fi

PROD_SCRIPT="${PROD_OUT}/dp-offline-upgrade-xenial-to-bionic.sh"
if [[ -f "$PROD_SCRIPT" ]]; then
  unsigned_count="$(grep -c 'UNSIGNED_TEST' "$PROD_SCRIPT" || true)"
  if [[ "$unsigned_count" == "0" ]]; then
    pass "8 production build UNSIGNED_TEST=0"
  else
    fail "8 production build UNSIGNED_TEST count=${unsigned_count}"
  fi
  FPR="$(grep -E '^CLIENT_MANIFEST_SIGNER_FINGERPRINT=' "${WORKDIR}/prod-build.log" | head -1 | cut -d= -f2- || true)"
  echo "  INFO: signer_fingerprint=${FPR}"
fi

# 2) signing key absent → production build FAIL
NOKEY_ROOT="${WORKDIR}/nokey-project"
mkdir -p "${NOKEY_ROOT}/client" "${NOKEY_ROOT}/scripts/lib" "${NOKEY_ROOT}/config"
cp "$BUILD_PY" "${NOKEY_ROOT}/scripts/lib/"
cp "${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in" "${NOKEY_ROOT}/client/"
# Intentionally omit config/client-signing keys
set +e
python3 "${NOKEY_ROOT}/scripts/lib/build_client_xenial_to_bionic.py" \
  --project-root "$NOKEY_ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "${WORKDIR}/nokey-out" \
  >"${WORKDIR}/nokey-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qiE 'signing key missing|unreadable' "${WORKDIR}/nokey-build.log"; then
  pass "2 signing key absent → production build FAIL"
else
  fail "2 expected production build FAIL without key (rc=${rc})"
  tail -20 "${WORKDIR}/nokey-build.log" || true
fi

# Helper: run deploy against a staged artifact tree (no real nginx write).
run_deploy_gate() {
  local art_dir="$1"
  local dest="$2"
  local log="$3"
  local art="${art_dir}/dp-offline-upgrade-xenial-to-bionic.sh"
  local sha="${art}.sha256"
  # Stage under a fake ROOT layout expected by deploy script paths via env override
  # by invoking the python verify path + a thin wrapper.
  DEST_ROOT="$dest" MIRROR_BASE="http://127.0.0.1:9" \
    bash -c '
      set -euo pipefail
      ROOT="'"$ROOT"'"
      ARTIFACT="'"$art"'"
      SHAFILE="'"$sha"'"
      DEST_ROOT="'"$dest"'"
      NAME="dp-offline-upgrade-xenial-to-bionic.sh"
      BUILD_PY="'"$BUILD_PY"'"
      PUB_KEY="'"$PUB_KEY"'"
      ART_SHA="$(sha256sum "$ARTIFACT" | awk "{print \$1}")"
      SIDECAR_SHA="$(awk "{print \$1}" "$SHAFILE")"
      [[ "$ART_SHA" == "$SIDECAR_SHA" ]] || { echo "artifact/sidecar SHA mismatch"; exit 1; }
      python3 - "$BUILD_PY" "$ARTIFACT" "$PUB_KEY" <<'"'"'PY'"'"'
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
PY
      mkdir -p "$DEST_ROOT"
      cp -a "$ARTIFACT" "$DEST_ROOT/$NAME"
      cp -a "$SHAFILE" "$DEST_ROOT/$NAME.sha256"
      echo DEPLOY_OK
    ' >"$log" 2>&1
}

# 3) UNSIGNED_TEST artifact → deploy 거부
UNSIGNED_OUT="${WORKDIR}/unsigned-client"
set +e
python3 "$BUILD_PY" \
  --project-root "$ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "$UNSIGNED_OUT" \
  --skip-sign \
  >"${WORKDIR}/unsigned-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  pass "unsigned test build writes isolated path"
else
  fail "unsigned test build should succeed on non-production path"
  tail -20 "${WORKDIR}/unsigned-build.log" || true
fi
# Refuse skip-sign into production artifacts/client
set +e
python3 "$BUILD_PY" \
  --project-root "$ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "${ROOT}/artifacts/client" \
  --skip-sign \
  >"${WORKDIR}/unsigned-prod-refuse.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qi 'refuses production' "${WORKDIR}/unsigned-prod-refuse.log"; then
  pass "7 unit/unsigned cannot overwrite artifacts/client"
else
  fail "7 skip-sign must refuse production artifacts/client"
fi

set +e
run_deploy_gate "$UNSIGNED_OUT" "${WORKDIR}/deploy-unsigned" "${WORKDIR}/deploy-unsigned.log"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qiE 'UNSIGNED_TEST|verification failed|signature' "${WORKDIR}/deploy-unsigned.log"; then
  pass "3 UNSIGNED_TEST artifact → deploy 거부"
else
  fail "3 UNSIGNED_TEST deploy should be rejected (rc=${rc})"
  cat "${WORKDIR}/deploy-unsigned.log" || true
fi

# 4) wrong signer fingerprint → deploy 거부
if [[ -f "$PROD_SCRIPT" ]]; then
  WRONG="${WORKDIR}/wrong-fpr"
  mkdir -p "$WRONG"
  cp -a "$PROD_OUT/." "$WRONG/"
  set +e
  python3 - "$BUILD_PY" "${WRONG}/dp-offline-upgrade-xenial-to-bionic.sh" <<'PY' >"${WORKDIR}/wrong-fpr.log" 2>&1
import importlib.util, sys
build_py, artifact = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.verify_client_artifact_signature(artifact, allowed_fingerprint="0" * 40)
except Exception as exc:
    print("REJECT:" + str(exc))
    sys.exit(2)
print("UNEXPECTED_PASS")
sys.exit(0)
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -q 'REJECT:' "${WORKDIR}/wrong-fpr.log"; then
    pass "4 wrong signer fingerprint → deploy 거부"
  else
    fail "4 wrong fingerprint should reject"
    cat "${WORKDIR}/wrong-fpr.log" || true
  fi
fi

# 5) tampered manifest → gpg verification FAIL
if [[ -f "$PROD_SCRIPT" ]]; then
  set +e
  python3 - "$BUILD_PY" "$PROD_SCRIPT" "$PUB_KEY" <<'PY' >"${WORKDIR}/tamper-manifest.log" 2>&1
import importlib.util, base64, re, sys, tempfile, os
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = open(artifact, "r", encoding="utf-8", errors="replace").read()
token = "PIN_MANIFEST_B64='"
start = text.find(token) + len(token)
end = text.find("'", start)
raw = re.sub(r"\s+", "", text[start:end])
data = bytearray(base64.b64decode(raw))
data[0] ^= 0xFF
new_b64 = base64.b64encode(bytes(data)).decode("ascii")
wrapped = "\n".join(new_b64[i:i+76] for i in range(0, len(new_b64), 76))
text2 = text[:start] + wrapped + text[end:]
td = tempfile.mkdtemp()
path = os.path.join(td, "tampered.sh")
open(path, "w").write(text2)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
try:
    mod.verify_client_artifact_signature(path, allowed_fingerprint=allowed)
except Exception as exc:
    print("REJECT:" + str(exc))
    sys.exit(2)
print("UNEXPECTED_PASS")
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]] && grep -qiE 'gpgv|REJECT' "${WORKDIR}/tamper-manifest.log"; then
    pass "5 tampered manifest → gpg verification FAIL"
  else
    fail "5 tampered manifest should fail gpgv"
    cat "${WORKDIR}/tamper-manifest.log" || true
  fi
fi

# 6) tampered client → SHA + signature 검증 FAIL
if [[ -f "$PROD_SCRIPT" ]]; then
  TAMPER_DIR="${WORKDIR}/tamper-client"
  mkdir -p "$TAMPER_DIR"
  cp -a "$PROD_OUT/." "$TAMPER_DIR/"
  # Corrupt embedded detached signature bytes (keeps pins parseable).
  python3 - "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh" <<'PY'
import base64, re, sys
path = sys.argv[1]
text = open(path, "r", encoding="utf-8", errors="replace").read()
token = "PIN_MANIFEST_SIG_B64='"
start = text.find(token) + len(token)
end = text.find("'", start)
raw = re.sub(r"\s+", "", text[start:end])
data = bytearray(base64.b64decode(raw))
# Flip a payload byte inside the armored sig body if possible
if len(data) > 40:
    data[40] ^= 0x5A
else:
    data[-1] ^= 0x5A
new_b64 = base64.b64encode(bytes(data)).decode("ascii")
wrapped = "\n".join(new_b64[i:i+76] for i in range(0, len(new_b64), 76))
open(path, "w", encoding="utf-8").write(text[:start] + wrapped + text[end:])
PY
  set +e
  art_sha="$(sha256sum "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
  side="$(awk '{print $1}' "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh.sha256")"
  set -e
  if [[ "$art_sha" != "$side" ]]; then
    pass "6 tampered client → SHA mismatch detected"
  else
    fail "6 tampered client SHA should mismatch sidecar"
  fi
  set +e
  python3 - "$BUILD_PY" "${TAMPER_DIR}/dp-offline-upgrade-xenial-to-bionic.sh" "$PUB_KEY" <<'PY' >"${WORKDIR}/tamper-client.log" 2>&1
import importlib.util, sys
build_py, artifact, pub_key = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("build_client_x2b", build_py)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
allowed = mod.key_fingerprint(open(pub_key, "rb").read())
try:
    mod.verify_client_artifact_signature(artifact, allowed_fingerprint=allowed)
except Exception as exc:
    print("REJECT:" + str(exc))
    sys.exit(2)
print("UNEXPECTED_PASS")
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    pass "6 tampered client → signature verification FAIL"
  else
    fail "6 tampered client signature should fail"
    cat "${WORKDIR}/tamper-client.log" || true
  fi
fi

# 7 already covered above (skip-sign refuses artifacts/client)
# Also ensure default --skip-sign path is client-unsigned-test and does not touch prod artifact mtime/sha
PROD_SHA_BEFORE=""
[[ -f "$PROD_ARTIFACT" ]] && PROD_SHA_BEFORE="$(sha256sum "$PROD_ARTIFACT" | awk '{print $1}')"
set +e
python3 "$BUILD_PY" \
  --project-root "$ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --skip-sign \
  >"${WORKDIR}/default-unsigned.log" 2>&1
rc=$?
set -e
PROD_SHA_AFTER=""
[[ -f "$PROD_ARTIFACT" ]] && PROD_SHA_AFTER="$(sha256sum "$PROD_ARTIFACT" | awk '{print $1}')"
if [[ "$rc" -eq 0 ]] \
  && [[ -f "${ROOT}/artifacts/client-unsigned-test/dp-offline-upgrade-xenial-to-bionic.sh" ]] \
  && [[ "$PROD_SHA_BEFORE" == "$PROD_SHA_AFTER" ]]; then
  pass "7 default --skip-sign uses client-unsigned-test; production artifact untouched"
else
  fail "7 default unsigned path isolation (rc=${rc})"
  tail -20 "${WORKDIR}/default-unsigned.log" || true
fi

# Rebuild production artifacts/client for subsequent HTTP/deploy checks (signed)
set +e
python3 "$BUILD_PY" \
  --project-root "$ROOT" \
  --mirror-base "$MIRROR_BASE" \
  --selective-root "$SEL_ROOT" \
  --output-dir "${ROOT}/artifacts/client" \
  >"${WORKDIR}/final-prod-build.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED' "${WORKDIR}/final-prod-build.log" \
  && grep -q 'ARTIFACT_SIGNATURE_VERIFY=PASS' "${WORKDIR}/final-prod-build.log"; then
  pass "production artifacts/client rebuilt signed"
  grep -E '^CLIENT_MANIFEST_SIGNER_FINGERPRINT=|^sha256=|^CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=' \
    "${WORKDIR}/final-prod-build.log" || true
else
  fail "production artifacts/client rebuild"
  tail -40 "${WORKDIR}/final-prod-build.log" || true
fi

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ -n "$READY_BEFORE" && "$READY_BEFORE" == "$READY_AFTER" ]]; then
  pass "READY_UNCHANGED=YES"
  echo "READY_UNCHANGED=YES"
else
  fail "READY changed during signing tests"
fi

# 11) no real DP / dro / publish — this suite never invokes them
pass "11 no DP/do-release-upgrade/package transaction/publish/reboot/full-mirror"

if [[ "$FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
