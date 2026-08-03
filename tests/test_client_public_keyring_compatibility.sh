#!/usr/bin/env bash
# tests/test_client_public_keyring_compatibility.sh
# Reproduce armored-keyring gpgv failure and prove binary public-keyring.gpg works.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_client_public_keyring_compatibility ==="

GPG_HOME="${WORKDIR}/gnupg"
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"
cat >"${GPG_HOME}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Keyring Compat Fixture
Name-Email: keyring-compat@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "${GPG_HOME}/batch" >/dev/null 2>&1

PRIV="${WORKDIR}/private.gpg"
PUB="${WORKDIR}/public.gpg"
gpg --homedir "$GPG_HOME" --batch --export-secret-keys --armor >"$PRIV"
gpg --homedir "$GPG_HOME" --batch --export --armor >"$PUB"
chmod 600 "$PRIV"
chmod 644 "$PUB"
FPR="$(local_signing_fingerprint_of "$PUB")"
[[ -n "$FPR" && ${#FPR} -eq 40 ]] || fail "fixture fingerprint"
LOCAL_KEY_FINGERPRINT="$FPR"

# Confirm armored format
head -n1 "$PUB" | grep -qx -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
  && pass "ARMORED_KEY_FORMAT=ASCII_ARMOR" \
  || fail "public.gpg is not ASCII armor"

# Payload + detached signature
PAYLOAD="${WORKDIR}/client-manifest.json"
printf '{"hop":"xenial-to-bionic","ok":true}\n' >"$PAYLOAD"
ASC="${WORKDIR}/client-manifest.json.asc"
gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
  -o "$ASC" "$PAYLOAD" >/dev/null 2>&1

# 1) Armored public.gpg directly as gpgv --keyring → FAIL (regression reproduce)
set +e
gpgv --keyring "$PUB" "$ASC" "$PAYLOAD" >/dev/null 2>"${WORKDIR}/armored-gpgv.err"
armored_rc=$?
set -e
if [[ "$armored_rc" -ne 0 ]]; then
  pass "ARMORED_KEYRING_FAILURE_REPRO=YES (gpgv rc=${armored_rc})"
  if grep -qiE 'invalid packet|No public key|keydb_search' "${WORKDIR}/armored-gpgv.err"; then
    pass "armored gpgv error matches xenial-class failure"
  else
    echo "  NOTE: gpgv stderr: $(tr '\n' ' ' <"${WORKDIR}/armored-gpgv.err")"
  fi
else
  fail "ARMORED_KEYRING_FAILURE_REPRO=NO (gpgv unexpectedly passed)"
fi

# 2) Build binary keyring
KR="${WORKDIR}/public-keyring.gpg"
if local_signing_build_binary_keyring "$PUB" "$KR"; then
  pass "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=PASS"
else
  fail "CLIENT_PUBLIC_BINARY_KEYRING_BUILD=FAIL"
fi

# 3) Binary format checks
if local_signing_is_ascii_armored_public "$KR"; then
  fail "binary keyring still looks armored"
else
  pass "BINARY_KEYRING_FORMAT=OPENPGP_BINARY"
fi
if local_signing_verify_binary_keyring "$KR" "$FPR"; then
  pass "BINARY_KEYRING_FINGERPRINT_VERIFY=PASS"
else
  fail "BINARY_KEYRING_FINGERPRINT_VERIFY=FAIL"
fi

# 4) gpgv with binary keyring → PASS
if gpgv --keyring "$KR" "$ASC" "$PAYLOAD" >/dev/null 2>&1; then
  pass "binary keyring gpgv PASS"
else
  fail "binary keyring gpgv FAIL"
fi

# 5) Stage artifacts + private key absence
STAGE="${WORKDIR}/stage"
mkdir -p "$STAGE/xenial-to-bionic" "$STAGE/bionic-to-focal" \
  "$STAGE/focal-to-jammy" "$STAGE/jammy-to-noble"
LOCAL_SIGNING_PUBLIC_KEY="$PUB"
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  printf '{"hop":"%s"}\n' "$hop" >"${STAGE}/${hop}/client-manifest.json"
  gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
    -o "${STAGE}/${hop}/client-manifest.json.asc" \
    "${STAGE}/${hop}/client-manifest.json" >/dev/null 2>&1
done
if local_signing_stage_http_public_artifacts "$STAGE" "$PUB" "$FPR"; then
  pass "stage public artifacts"
else
  fail "stage public artifacts"
fi
[[ -f "${STAGE}/public.gpg" && -f "${STAGE}/public.asc" && -f "${STAGE}/public-keyring.gpg" ]] \
  && pass "BINARY_KEYRING_ARTIFACT=public-keyring.gpg (+ public.gpg/public.asc)" \
  || fail "missing staged key artifacts"
if local_signing_verify_staged_manifest_gpgv "$STAGE"; then
  pass "ALL_FOUR_MANIFEST_GPGV_VERIFY=PASS"
else
  fail "ALL_FOUR_MANIFEST_GPGV_VERIFY=FAIL"
fi
if local_signing_assert_private_not_published "$STAGE"; then
  pass "PRIVATE_KEY_HTTP_PUBLISHED=NO"
else
  fail "PRIVATE_KEY_HTTP_PUBLISHED=YES"
fi
cp "$PRIV" "${STAGE}/private.gpg"
if local_signing_assert_private_not_published "$STAGE" 2>/dev/null; then
  fail "private key should be detected in stage"
else
  pass "private key publication blocked"
fi
rm -f "${STAGE}/private.gpg"

# 6) Corrupt binary keyring → FAIL
printf 'not-a-keyring\n' >"${STAGE}/public-keyring.gpg"
if local_signing_verify_binary_keyring "${STAGE}/public-keyring.gpg" "$FPR" 2>/dev/null; then
  fail "corrupt binary keyring accepted"
else
  pass "corrupt binary keyring → FAIL"
fi

# 7) Missing binary keyring → fail closed
rm -f "${STAGE}/public-keyring.gpg"
if local_signing_verify_staged_manifest_gpgv "$STAGE" 2>/dev/null; then
  fail "missing binary keyring should fail closed"
else
  pass "missing binary keyring → fail closed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_client_public_keyring_compatibility PASS ==="
  exit 0
fi
echo "=== test_client_public_keyring_compatibility FAIL ==="
exit 1
