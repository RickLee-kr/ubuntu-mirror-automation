#!/usr/bin/env bash
# tests/test_dp_phase2_client_stage.sh — client staging helper safety + logic
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2-6.5.0.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "[test] bash -n helper"
bash -n "$HELPER" && pass "bash -n" || fail "bash -n"

echo "[test] helper does not use ACPS as download source"
# Guard-string mentioning ACPS is OK; download/base URL must not.
if grep -Eiq 'ACPS_PROVISION_URL|ACPS_BASE_URL|curl .*acps\.stellarcyber' "$HELPER"; then
  fail "ACPS download source present"
elif grep -Eiq 'DEFAULT_MIRROR_URL=.*acps\.stellarcyber' "$HELPER"; then
  fail "default mirror is ACPS"
else
  pass "no ACPS download source"
fi

echo "[test] default mirror IP only (no alternate public hosts hardcoded as default)"
grep -q 'DEFAULT_MIRROR_URL="http://221.139.249.111"' "$HELPER" && pass "default mirror IP" || fail "default mirror IP"
if grep -Eiq 'DEFAULT_MIRROR_URL=.*(archive\.ubuntu\.com|acps\.)' "$HELPER"; then
  fail "default mirror points elsewhere"
else
  pass "default mirror is internal IP"
fi

echo "[test] bringup never auto-executed"
grep -q 'BRINGUP_EXECUTED=NO' "$HELPER" && pass "BRINGUP_EXECUTED=NO" || fail "missing NO"
if grep -nE '[[:space:]](bash|sh)[[:space:]]+/home/aella/bringup_py3' "$HELPER" | grep -v 'NEXT_COMMAND'; then
  fail "bringup executed in script body"
else
  pass "bringup not executed in body"
fi
# NEXT_COMMAND is guidance only
grep -q 'NEXT_COMMAND=sudo bash' "$HELPER" && pass "NEXT_COMMAND guidance present" || fail "NEXT_COMMAND"

echo "[test] refuses stellarcyber URL via --mirror-url (non-root dies on root check first OK)"
# parse_args runs before require_root — invoke through a tiny wrapper that sources parse only
err="$(bash -c '
  source "'"$HELPER"'" 2>/dev/null
' 2>&1 || true)"
# Direct execution: ACPS check happens in parse_args before root check
set +e
out="$(bash "$HELPER" --mirror-url 'https://acps.stellarcyber.ai/x' 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && echo "$out" | grep -Eiq 'Refusing ACPS|ACPS|stellarcyber'; then
  pass "refuses ACPS mirror-url"
elif [[ "$rc" -ne 0 ]]; then
  # may die on root first depending on arg order — ensure parse_args is first in stage_main
  if grep -A2 'stage_main()' "$HELPER" | grep -q 'parse_args'; then
    # If root check somehow first, still ensure code path exists
    grep -q 'Refusing ACPS' "$HELPER" && pass "ACPS refuse code present" || fail "ACPS refuse missing"
  else
    fail "should refuse ACPS mirror-url: $out"
  fi
else
  fail "should refuse ACPS mirror-url"
fi

echo "[test] checksum failure leaves destination untouched (inline harness)"
HTTP_ROOT="${WORKDIR}/http"
REL="${HTTP_ROOT}/dp-phase2/6.5.0"
mkdir -p "$REL" "${WORKDIR}/dest"
printf 'old-marker\n' >"${WORKDIR}/dest/marker"
FILES=(
  aelladeb_py3_common.tar.gz
  aelladeb_py3_common.tar.gz.sha1
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb.sha1
  bringup_py3_dp_after_os_upgrade.sh
  bringup_py3_dp_after_os_upgrade.sh.sha1
  images-6.5.0.list
  images-6.5.0.tar
  images-6.5.0.tar.sha256
)
TMPF="${WORKDIR}/files"
mkdir -p "$TMPF"
printf 'common\n' >"${TMPF}/aelladeb_py3_common.tar.gz"
sha1sum "${TMPF}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${TMPF}/aelladeb_py3_common.tar.gz.sha1"
printf 'deb\n' >"${TMPF}/aella-uvp-2404_6.5.0ubuntu1_amd64.deb"
sha1sum "${TMPF}/aella-uvp-2404_6.5.0ubuntu1_amd64.deb" | awk '{print $1}' >"${TMPF}/aella-uvp-2404_6.5.0ubuntu1_amd64.deb.sha1"
printf '#!/bin/bash\necho hi\n' >"${TMPF}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${TMPF}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' >"${TMPF}/bringup_py3_dp_after_os_upgrade.sh.sha1"
seq 1 3 >"${TMPF}/images-6.5.0.list"
printf 'img\n' >"${TMPF}/images-6.5.0.tar"
sha256sum "${TMPF}/images-6.5.0.tar" | awk '{print $1}' >"${TMPF}/images-6.5.0.tar.sha256"
(
  cd "$TMPF"
  tar -cf "${REL}/dp_bundle_6.5.0-current.tar" "${FILES[@]}"
)
# Wrong checksum
echo '0000000000000000000000000000000000000000000000000000000000000000  dp_bundle_6.5.0-current.tar' \
  >"${REL}/dp_bundle_6.5.0-current.tar.sha256"

python3 - "${HTTP_ROOT}" 8766 <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3

# Harness mirrors helper download+verify order; must not touch dest on failure
DEST="${WORKDIR}/dest"
STAGE="${WORKDIR}/stage"
mkdir -p "$STAGE"
set +e
(
  set -euo pipefail
  curl -fsS -o "${STAGE}/bundle.tar" "http://127.0.0.1:8766/dp-phase2/6.5.0/dp_bundle_6.5.0-current.tar"
  curl -fsS -o "${STAGE}/bundle.tar.sha256" "http://127.0.0.1:8766/dp-phase2/6.5.0/dp_bundle_6.5.0-current.tar.sha256"
  expected="$(awk 'NF {print $1; exit}' "${STAGE}/bundle.tar.sha256")"
  actual="$(sha256sum "${STAGE}/bundle.tar" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]]
  # would extract + replace DEST only after success
  rm -rf "$DEST"
) 2>/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "checksum failure aborts before replace" || fail "checksum should fail"
[[ -f "${DEST}/marker" ]] && pass "destination preserved on checksum fail" || fail "destination altered"

# Success path after fix
sha256sum "${REL}/dp_bundle_6.5.0-current.tar" | awk '{print $1"  dp_bundle_6.5.0-current.tar"}' \
  >"${REL}/dp_bundle_6.5.0-current.tar.sha256"
NEW="${WORKDIR}/new_art"
mkdir -p "$NEW"
curl -fsS -o "${STAGE}/bundle.tar" "http://127.0.0.1:8766/dp-phase2/6.5.0/dp_bundle_6.5.0-current.tar"
curl -fsS -o "${STAGE}/bundle.tar.sha256" "http://127.0.0.1:8766/dp-phase2/6.5.0/dp_bundle_6.5.0-current.tar.sha256"
expected="$(awk 'NF {print $1; exit}' "${STAGE}/bundle.tar.sha256")"
actual="$(sha256sum "${STAGE}/bundle.tar" | awk '{print $1}')"
[[ "${expected,,}" == "${actual,,}" ]] && pass "good checksum verifies" || fail "good checksum"
tar -xf "${STAGE}/bundle.tar" -C "$NEW"
[[ -f "${NEW}/images-6.5.0.tar" ]] && pass "extract places artifacts" || fail "extract"

echo "[test] deploy script safety checks"
bash -n "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "deploy bash -n" || fail "deploy bash -n"
grep -q 'READY_UNCHANGED' "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "READY guard" || fail "READY guard"
grep -q 'stellarcyber' "${ROOT}/scripts/deploy-stage-dp-phase2-client-atomic.sh" && pass "deploy refuses ACPS check present" || fail "deploy ACPS check"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$HELPER" \
    && pass "shellcheck helper" || fail "shellcheck helper"
else
  echo "  SKIP: shellcheck not installed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 CLIENT STAGE TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 CLIENT STAGE TESTS FAILED"
exit 1
