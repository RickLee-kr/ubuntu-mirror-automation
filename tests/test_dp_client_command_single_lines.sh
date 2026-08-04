#!/usr/bin/env bash
# tests/test_dp_client_command_single_lines.sh
# Validate DP hop/stage/bringup commands are copyable single physical lines.
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

echo "=== test_dp_client_command_single_lines ==="

MIRROR="http://192.0.2.55"
HOPS=(
  "dp-offline-upgrade-xenial-to-bionic.sh"
  "dp-offline-upgrade-bionic-to-focal.sh"
  "dp-offline-upgrade-focal-to-jammy.sh"
  "dp-offline-upgrade-jammy-to-noble.sh"
)

assert_one_physical_line() {
  local label="$1" text="$2"
  local lines
  lines="$(printf '%s\n' "$text" | wc -l | tr -d ' ')"
  if [[ "$lines" == "1" ]]; then
    pass "${label}: exactly one physical line"
  else
    fail "${label}: expected 1 physical line, got ${lines}"
  fi
  if printf '%s' "$text" | grep -qE '\\[[:space:]]*$'; then
    fail "${label}: backslash continuation present"
  else
    pass "${label}: no backslash continuation"
  fi
  if printf '%s\n' "$text" | grep -qE 'BEGIN STEP|END STEP|BEGIN PHASE|END PHASE'; then
    fail "${label}: BEGIN/END markers present"
  else
    pass "${label}: no BEGIN/END markers"
  fi
  if printf '%s\n' "$text" | grep -qE '^\('; then
    fail "${label}: parenthesized multi-line block"
  else
    pass "${label}: no parenthesized block"
  fi
}

for script in "${HOPS[@]}"; do
  hop="${script#dp-offline-upgrade-}"
  hop="${hop%.sh}"
  line="$(gui_client_hop_command_line "$MIRROR" "$script")"
  printf '%s\n' "$line" >"${TMP}/line-${hop}.sh"
  assert_one_physical_line "$hop" "$line"

  grep -q "MIRROR='${MIRROR}'" "${TMP}/line-${hop}.sh" \
    && pass "${hop}: configured mirror" || fail "${hop}: mirror"
  grep -q "HOP='${hop}'" "${TMP}/line-${hop}.sh" \
    && pass "${hop}: HOP var" || fail "${hop}: HOP var"
  grep -q '^cd /home/aella &&' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: starts with cd /home/aella" || fail "${hop}: cd prefix"

  if bash -n "${TMP}/line-${hop}.sh"; then
    pass "${hop}: bash -n PASS"
  else
    fail "${hop}: bash -n FAIL"
  fi

  if grep -Eq 'curl -fsSLO([[:space:]]|$)' "${TMP}/line-${hop}.sh"; then
    fail "${hop}: naked curl -fsSLO"
  else
    pass "${hop}: no naked curl -fsSLO"
  fi
  grep -q 'curl -fsSLo' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: curl -fsSLo" || fail "${hop}: curl -fsSLo"
  grep -q 'public-keyring.gpg' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: downloads public-keyring.gpg" || fail "${hop}: keyring download"
  grep -q -- '--keyring ./public-keyring.gpg' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: gpgv uses public-keyring.gpg" || fail "${hop}: gpgv keyring"
  if grep -q -- '--keyring ./public.gpg' "${TMP}/line-${hop}.sh"; then
    fail "${hop}: still uses public.gpg as keyring"
  else
    pass "${hop}: no public.gpg keyring"
  fi
  if grep -qE '221\.139\.249\.(111|112)' "${TMP}/line-${hop}.sh"; then
    fail "${hop}: hardcoded test server IP"
  else
    pass "${hop}: no hardcoded 221.139.249.111/112"
  fi

  # Order: fingerprint pin → gpgv → manifest/sidecar SHA → sudo bash
  fpr_pos="$(grep -ob 'EXPECTED_FPR=' "${TMP}/line-${hop}.sh" | head -1 | cut -d: -f1)"
  gpg_pos="$(grep -ob 'gpgv --keyring' "${TMP}/line-${hop}.sh" | head -1 | cut -d: -f1)"
  sudo_pos="$(grep -ob 'sudo bash' "${TMP}/line-${hop}.sh" | head -1 | cut -d: -f1)"
  calc_pos="$(grep -ob 'sha256sum' "${TMP}/line-${hop}.sh" | head -1 | cut -d: -f1)"
  if [[ -n "$fpr_pos" && -n "$gpg_pos" && -n "$sudo_pos" && -n "$calc_pos" \
        && "$fpr_pos" -lt "$gpg_pos" && "$gpg_pos" -lt "$sudo_pos" \
        && "$calc_pos" -lt "$sudo_pos" ]]; then
    pass "${hop}: fingerprint/gpgv/sha → sudo order"
  else
    fail "${hop}: verify/sudo order wrong (fpr=${fpr_pos} gpg=${gpg_pos} calc=${calc_pos} sudo=${sudo_pos})"
  fi
  grep -q 'EXPECTED_FPR=' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: EXPECTED_FPR pin" || fail "${hop}: missing EXPECTED_FPR"
  grep -q 'mktemp -d' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: isolated workdir" || fail "${hop}: missing workdir"
  grep -q 'rm -f "\$SCRIPT"' "${TMP}/line-${hop}.sh" \
    && fail "${hop}: pre-HTTP rm still present" || pass "${hop}: no pre-HTTP rm"
  grep -q ' && ' "${TMP}/line-${hop}.sh" \
    && pass "${hop}: && fail-closed chain" || fail "${hop}: missing && chain"
done

stage="$(gui_phase2_stage_command_line "$MIRROR" "6.5.0")"
assert_one_physical_line "phase2-stage" "$stage"
printf '%s\n' "$stage" >"${TMP}/stage.sh"
grep -q 'stage-dp-phase2.sh' "${TMP}/stage.sh" \
  && pass "stage: script name" || fail "stage: script name"
grep -q "MIRROR='${MIRROR}'" "${TMP}/stage.sh" \
  && pass "stage: configured mirror" || fail "stage: mirror"
grep -q '^cd /home/aella &&' "${TMP}/stage.sh" \
  && pass "stage: cd prefix" || fail "stage: cd prefix"
bash -n "${TMP}/stage.sh" && pass "stage: bash -n" || fail "stage: bash -n"

OUT="$TMP/full.txt"
gui_build_client_commands "$MIRROR" "single" "" >"$OUT"
bringup="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh' "$OUT" | head -1)"
assert_one_physical_line "bringup" "$bringup"
[[ "$(grep -cE 'curl -fsSLo .*public-keyring\.gpg' "$OUT" || true)" -ge 4 ]] \
  || fail "public-keyring.gpg under-downloaded in full doc"
grep -q 'BEGIN STEP\|END STEP' "$OUT" && fail "BEGIN/END in full doc" || true
grep -qE '\\[[:space:]]*$' "$OUT" && fail "backslash in full doc" || true
grep -Eq 'curl -fsSLO([[:space:]]|$)' "$OUT" && fail "naked curl in full doc" || true
pass "full document single-line contract"

# Source generators themselves must emit one printf line (no embedded newlines in string).
if declare -F gui_client_hop_command_line >/dev/null; then
  pass "gui_client_hop_command_line defined"
else
  fail "gui_client_hop_command_line missing"
fi
if declare -F gui_phase2_stage_command_line >/dev/null; then
  pass "gui_phase2_stage_command_line defined"
else
  fail "gui_phase2_stage_command_line missing"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_command_single_lines PASS ==="
  echo "EACH_EXECUTABLE_COMMAND_ONE_PHYSICAL_LINE=YES"
  exit 0
fi
echo "=== test_dp_client_command_single_lines FAIL ==="
exit 1
