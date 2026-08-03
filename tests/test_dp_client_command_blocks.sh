#!/usr/bin/env bash
# tests/test_dp_client_command_blocks.sh
# Validate multi-line DP hop command blocks (copy-safe, binary keyring, short lines).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CLIENT_ROOT="$TMP/client"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://192.0.2.55"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

echo "=== test_dp_client_command_blocks ==="

MIRROR="http://192.0.2.55"
MAX_LINE=90
HOPS=(
  "dp-offline-upgrade-xenial-to-bionic.sh"
  "dp-offline-upgrade-bionic-to-focal.sh"
  "dp-offline-upgrade-focal-to-jammy.sh"
  "dp-offline-upgrade-jammy-to-noble.sh"
)

OUT="$TMP/full.txt"
gui_build_client_commands "$MIRROR" "single" "" >"$OUT"

for script in "${HOPS[@]}"; do
  hop="${script#dp-offline-upgrade-}"
  hop="${hop%.sh}"
  block="$(gui_client_hop_command_block "$MIRROR" "$script")"
  printf '%s\n' "$block" >"${TMP}/block-${hop}.sh"

  grep -q 'BEGIN STEP' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: BEGIN marker" || fail "${hop}: BEGIN marker"
  grep -q 'END STEP' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: END marker" || fail "${hop}: END marker"
  grep -q "MIRROR='${MIRROR}'" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: configured mirror" || fail "${hop}: mirror"
  grep -q "HOP='${hop}'" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: HOP var" || fail "${hop}: HOP var"

  # bash -n on the block (strip BEGIN/END comment wrappers are fine)
  if bash -n "${TMP}/block-${hop}.sh"; then
    pass "${hop}: bash -n PASS"
  else
    fail "${hop}: bash -n FAIL"
  fi

  if grep -Eq 'curl -fsSLO([[:space:]]|$)' "${TMP}/block-${hop}.sh"; then
    fail "${hop}: naked curl -fsSLO"
  else
    pass "${hop}: no naked curl -fsSLO"
  fi
  grep -q 'curl -fsSLo' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: curl -o destinations" || fail "${hop}: curl -o"
  grep -q 'public-keyring.gpg' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: downloads public-keyring.gpg" || fail "${hop}: keyring download"
  grep -q -- '--keyring ./public-keyring.gpg' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: gpgv uses public-keyring.gpg" || fail "${hop}: gpgv keyring"
  if grep -q -- '--keyring ./public.gpg' "${TMP}/block-${hop}.sh"; then
    fail "${hop}: still uses public.gpg as keyring"
  else
    pass "${hop}: no public.gpg keyring"
  fi
  if grep -qE '221\.139\.249\.(111|112)' "${TMP}/block-${hop}.sh"; then
    fail "${hop}: hardcoded test server IP"
  else
    pass "${hop}: no hardcoded 221.139.249.111/112"
  fi

  # Physical line length
  while IFS= read -r line; do
    # Ignore empty lines
    [[ -n "$line" ]] || continue
    len="${#line}"
    if [[ "$len" -gt "$MAX_LINE" ]]; then
      fail "${hop}: line length ${len} > ${MAX_LINE}: ${line:0:60}..."
    fi
  done <"${TMP}/block-${hop}.sh"
  pass "${hop}: physical lines <= ${MAX_LINE}"

  # Failure before sudo: if gpgv line is removed, sudo must not run alone without prior checks
  grep -q 'sha256sum -c' "${TMP}/block-${hop}.sh" \
    && grep -q 'gpgv' "${TMP}/block-${hop}.sh" \
    && grep -q 'sudo bash' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: verify-then-sudo order present" \
    || fail "${hop}: missing verify/sudo sequence"

  # Ensure set -euo pipefail so failure skips sudo
  grep -q 'set -euo pipefail' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: set -euo pipefail" || fail "${hop}: missing set -euo"
done

# Full document consistency
grep -q 'COMMAND FORMAT' "$OUT" || fail "COMMAND FORMAT missing from full doc"
[[ "$(grep -c 'BEGIN STEP' "$OUT" || true)" -eq 4 ]] \
  || fail "expected 4 BEGIN STEP markers in full doc"
[[ "$(grep -c 'public-keyring.gpg' "$OUT" || true)" -ge 8 ]] \
  || fail "public-keyring.gpg under-referenced in full doc"
grep -Eq 'curl -fsSLO([[:space:]]|$)' "$OUT" && fail "naked curl in full doc" || true
pass "full document command-block contract"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_command_blocks PASS ==="
  echo "ALL_FOUR_COMMAND_BASH_N=PASS"
  echo "MAX_GENERATED_PHYSICAL_LINE_LENGTH=${MAX_LINE}"
  exit 0
fi
echo "=== test_dp_client_command_blocks FAIL ==="
exit 1
