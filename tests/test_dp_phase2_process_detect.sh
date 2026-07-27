#!/usr/bin/env bash
# Process detection: real matches yes, self-match / harness no. Bounded fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/stage-dp-phase2.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    kill "$p" 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
  # Kill any leftover fixtures by exact path marker
  pkill -f "${WORKDIR}/fixture-" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck disable=SC1090
source "$HELPER"

echo "[test] self-match: helper detection does not fire on idle system for stage helper"
set +e
out="$(require_no_active_os_upgrade 2>&1)"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "no false positive on idle" || fail "false positive: $out"

echo "[test] real fixture process is detected"
FIX="${WORKDIR}/fixture-dp-offline-upgrade-jammy-to-noble.sh"
cat >"$FIX" <<'EOF'
#!/bin/bash
sleep 8
EOF
chmod +x "$FIX"
timeout 10 "$FIX" &
PIDS+=($!)
sleep 0.2
set +e
out="$(require_no_active_os_upgrade 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "detects real dp-offline-upgrade fixture" || fail "missed real fixture"
kill "${PIDS[-1]}" 2>/dev/null || true
wait "${PIDS[-1]}" 2>/dev/null || true
unset 'PIDS[-1]' 2>/dev/null || PIDS=()

echo "[test] apt-get executable name detection"
# Run under argv0 apt-get using bash -c exec trick (bounded)
timeout 10 bash -c 'exec -a apt-get sleep 8' &
PIDS+=($!)
sleep 0.2
set +e
out="$(require_no_active_os_upgrade 2>&1)"
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "detects apt-get argv0" || fail "missed apt-get: $out"
kill "${PIDS[-1]}" 2>/dev/null || true
wait "${PIDS[-1]}" 2>/dev/null || true
PIDS=()

echo "[test] orphan cleanup verification"
sleep 0.2
left="$(ps -eo args= | grep -F "${WORKDIR}/fixture-" | grep -v grep || true)"
[[ -z "${left// }" ]] && pass "no orphan fixtures" || fail "orphans remain: $left"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL DP PHASE2 PROCESS DETECT TESTS PASSED"
  exit 0
fi
echo "SOME DP PHASE2 PROCESS DETECT TESTS FAILED"
exit 1
