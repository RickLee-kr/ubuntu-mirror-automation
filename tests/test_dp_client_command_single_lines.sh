#!/usr/bin/env bash
# tests/test_dp_client_command_single_lines.sh
# Validate DP hop commands are controlled three-line blocks; stage is 2–3 lines.
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

echo "=== test_dp_client_command_three_line_blocks ==="

MIRROR="http://192.0.2.55"
MAX_LEN=360
HOPS=(
  "dp-offline-upgrade-xenial-to-bionic.sh"
  "dp-offline-upgrade-bionic-to-focal.sh"
  "dp-offline-upgrade-focal-to-jammy.sh"
  "dp-offline-upgrade-jammy-to-noble.sh"
)

assert_three_line_hop_block() {
  local label="$1" text="$2"
  local lines l1 l2 l3
  mapfile -t lines < <(printf '%s\n' "$text")
  if [[ "${#lines[@]}" -eq 3 ]]; then
    pass "${label}: exactly three physical lines"
  else
    fail "${label}: expected 3 physical lines, got ${#lines[@]}"
    return
  fi
  l1="${lines[0]}"
  l2="${lines[1]}"
  l3="${lines[2]}"
  [[ "$l1" == '('* ]] \
    && pass "${label}: line1 opens with (" || fail "${label}: line1 opens with ("
  printf '%s\n' "$l1" | grep -qE 'BASH_SUBSHELL' \
    && pass "${label}: subshell guard" || fail "${label}: subshell guard"
  printf '%s\n' "$l1" | grep -q 'DP_COMMAND_SUBSHELL_REQUIRED=YES' \
    && pass "${label}: DP_COMMAND_SUBSHELL_REQUIRED" || fail "${label}: missing required marker"
  printf '%s\n' "$l1" | grep -qE 'cd /home/aella &&' \
    && pass "${label}: line1 cd /home/aella" || fail "${label}: line1 cd prefix"
  [[ "$l1" =~ \\[[:space:]]*$ ]] \
    && pass "${label}: line1 trailing backslash" || fail "${label}: line1 backslash"
  [[ "$l2" =~ \\[[:space:]]*$ ]] \
    && pass "${label}: line2 trailing backslash" || fail "${label}: line2 backslash"
  if [[ "$l3" =~ \\[[:space:]]*$ ]]; then
    fail "${label}: line3 must not end with backslash"
  else
    pass "${label}: line3 no trailing backslash"
  fi
  for i in 0 1 2; do
    if [[ ${#lines[$i]} -gt "$MAX_LEN" ]]; then
      fail "${label}: line$((i + 1)) length ${#lines[$i]} > ${MAX_LEN}"
    else
      pass "${label}: line$((i + 1)) length ${#lines[$i]} <= ${MAX_LEN}"
    fi
  done
  if printf '%s\n' "$text" | grep -qE 'BEGIN STEP|END STEP|BEGIN PHASE|END PHASE'; then
    fail "${label}: BEGIN/END markers present"
  else
    pass "${label}: no BEGIN/END markers"
  fi
}

for script in "${HOPS[@]}"; do
  hop="${script#dp-offline-upgrade-}"
  hop="${hop%.sh}"
  block="$(gui_client_hop_command_line "$MIRROR" "$script")"
  printf '%s\n' "$block" >"${TMP}/block-${hop}.sh"
  assert_three_line_hop_block "$hop" "$block"

  grep -q "MIRROR='${MIRROR}'" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: configured mirror" || fail "${hop}: mirror"
  grep -q "HOP='${hop}'" "${TMP}/block-${hop}.sh" \
    && pass "${hop}: HOP var" || fail "${hop}: HOP var"
  grep -qE '^\( ' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: starts with (" || fail "${hop}: missing ("
  grep -qE 'BASH_SUBSHELL' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: BASH_SUBSHELL guard" || fail "${hop}: missing BASH_SUBSHELL"
  grep -qE 'cd /home/aella &&' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: contains cd /home/aella" || fail "${hop}: cd prefix"
  grep -q 'GNUPGHOME=' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: ephemeral GNUPGHOME" || fail "${hop}: missing GNUPGHOME"
  grep -qE '^\(' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: runs in subshell" || fail "${hop}: missing subshell"

  if bash -n "${TMP}/block-${hop}.sh"; then
    pass "${hop}: bash -n PASS"
  else
    fail "${hop}: bash -n FAIL"
  fi

  grep -q 'curl -fsSLo' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: curl -fsSLo" || fail "${hop}: curl -fsSLo"
  grep -q 'public-keyring.gpg' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: downloads public-keyring.gpg" || fail "${hop}: keyring download"
  grep -q 'dp-client-command-runner.sh' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: runner helper" || fail "${hop}: runner helper"
  grep -q 'gpgv --keyring' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: gpgv present" || fail "${hop}: gpgv"
  grep -q 'EXPECTED_FPR=' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: EXPECTED_FPR pin" || fail "${hop}: missing EXPECTED_FPR"
  grep -q 'mktemp -d' "${TMP}/block-${hop}.sh" \
    && pass "${hop}: isolated workdir" || fail "${hop}: missing workdir"
  grep -q 'rm -f "\$SCRIPT"' "${TMP}/block-${hop}.sh" \
    && fail "${hop}: pre-HTTP rm still present" || pass "${hop}: no pre-HTTP rm"
  if grep -qE '221\.139\.249\.(111|112)' "${TMP}/block-${hop}.sh"; then
    fail "${hop}: hardcoded test server IP"
  else
    pass "${hop}: no hardcoded 221.139.249.111/112"
  fi

  # Incomplete copy: line 1 alone / lines 1-2 alone must not be a complete command
  # (trailing backslash → Bash waits for continuation; never reaches runner).
  head -1 "${TMP}/block-${hop}.sh" >"${TMP}/partial1-${hop}.sh"
  head -2 "${TMP}/block-${hop}.sh" >"${TMP}/partial2-${hop}.sh"
  grep -qE '\\[[:space:]]*$' "${TMP}/partial1-${hop}.sh" \
    && pass "${hop}: line1 alone ends with continuation" \
    || fail "${hop}: line1 alone not continued"
  grep -qE '\\[[:space:]]*$' <(tail -1 "${TMP}/partial2-${hop}.sh") \
    && pass "${hop}: lines1-2 end with continuation" \
    || fail "${hop}: lines1-2 not continued"
  # Reconstructed full block must invoke runner once (no sudo bash of hop in block).
  recon="$(sed -E 's/\\[[:space:]]*$//;s/^[[:space:]]+//' "${TMP}/block-${hop}.sh" | tr -d '\n')"
  printf '%s\n' "$recon" | grep -q 'bash \$R ' \
    && pass "${hop}: reconstructed invokes runner" || fail "${hop}: runner invoke"
done

stage="$(gui_phase2_stage_command_line "$MIRROR" "6.5.0")"
mapfile -t stage_lines < <(printf '%s\n' "$stage")
[[ "${#stage_lines[@]}" -ge 2 && "${#stage_lines[@]}" -le 3 ]] \
  && pass "phase2-stage: ${#stage_lines[@]} physical lines" \
  || fail "phase2-stage: unexpected line count ${#stage_lines[@]}"
printf '%s\n' "$stage" >"${TMP}/stage.sh"
grep -q 'stage-dp-phase2.sh' "${TMP}/stage.sh" \
  && pass "stage: script name" || fail "stage: script name"
grep -q "MIRROR='${MIRROR}'" "${TMP}/stage.sh" \
  && pass "stage: configured mirror" || fail "stage: mirror"
bash -n "${TMP}/stage.sh" && pass "stage: bash -n" || fail "stage: bash -n"
grep -qE 'BASH_SUBSHELL' "${TMP}/stage.sh" \
  && pass "stage: BASH_SUBSHELL guard" || fail "stage: missing BASH_SUBSHELL"
grep -qE '^\( ' "${TMP}/stage.sh" \
  && pass "stage: opens with (" || fail "stage: missing ("
[[ "${stage_lines[0]}" =~ \\[[:space:]]*$ ]] \
  && pass "stage: non-final line has backslash" || fail "stage: missing continuation"

OUT="$TMP/full.txt"
gui_build_client_commands "$MIRROR" "single" "" >"$OUT"
bringup="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh' "$OUT" | head -1)"
[[ "$(printf '%s\n' "$bringup" | wc -l | tr -d ' ')" == "1" ]] \
  && pass "bringup: one physical line" || fail "bringup: not one line"
[[ "$(grep -cE 'curl -fsSLo .*public-keyring\.gpg|K=public-keyring\.gpg' "$OUT" || true)" -ge 4 ]] \
  || fail "public-keyring.gpg under-referenced in full doc"
grep -q 'BEGIN STEP\|END STEP' "$OUT" && fail "BEGIN/END in full doc" || true
grep -q 'exactly one physical line' "$OUT" && fail "obsolete one-line guidance" || true
grep -q 'Visual wrapping does not insert a newline' "$OUT" && fail "obsolete wrap guidance" || true
grep -qE 'Copy the complete three-line block|three physical lines|DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2' "$OUT" \
  && pass "three-line copy guidance" || fail "missing three-line guidance"
grep -qE 'opening parenthesis|begins with an opening parenthesis' "$OUT" \
  && pass "opening parenthesis instruction" || fail "missing opening parenthesis instruction"
grep -qE 'closing parenthesis|ends with a closing' "$OUT" \
  && pass "closing parenthesis instruction" || fail "missing closing parenthesis instruction"
grep -q 'first two lines must end with backslash' "$OUT" \
  && pass "backslash instruction" || fail "missing backslash instruction"
grep -q 'Do not copy only one or two lines' "$OUT" \
  && pass "partial-copy warning" || fail "missing partial-copy warning"
grep -q 'DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2' "$OUT" \
  && pass "DP_COMMAND_BLOCK_VERSION in doc" || fail "missing block version"
pass "full document three-line contract"

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
  echo "=== test_dp_client_command_three_line_blocks PASS ==="
  echo "OS_HOP_BLOCK_LINES=3"
  echo "EACH_EXECUTABLE_OS_HOP_THREE_PHYSICAL_LINES=YES"
  exit 0
fi
echo "=== test_dp_client_command_three_line_blocks FAIL ==="
exit 1
