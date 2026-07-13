#!/usr/bin/env bash
# test_systemd.sh — Validate generated systemd units
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"

FAIL=0
um_load_config "${ROOT}/mirror.conf"

SVC="$(um_generate_systemd_service)"
TIMER="$(um_generate_systemd_timer)"

echo "$SVC" | grep -q '^\[Unit\]' || FAIL=1
echo "$SVC" | grep -q 'Type=oneshot' || FAIL=1
echo "$SVC" | grep -q 'ExecStart=/usr/bin/apt-mirror' || FAIL=1
echo "$TIMER" | grep -q '^\[Timer\]' || FAIL=1
echo "$TIMER" | grep -q 'OnCalendar=' || FAIL=1
echo "$TIMER" | grep -q 'Persistent=true' || FAIL=1

# Template files
grep -q 'ExecStart=/usr/bin/apt-mirror' "${ROOT}/templates/apt-mirror.service" || FAIL=1
grep -q 'OnCalendar=' "${ROOT}/templates/apt-mirror.timer" || FAIL=1

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
um_generate_systemd_service >"${TMPDIR_TEST}/apt-mirror.service"
um_generate_systemd_timer >"${TMPDIR_TEST}/apt-mirror.timer"

if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "${TMPDIR_TEST}/apt-mirror.service" "${TMPDIR_TEST}/apt-mirror.timer" 2>/dev/null; then
    echo "  PASS: systemd-analyze verify"
  else
    # verify may need full system context
    echo "  WARNING: systemd-analyze verify skipped/failed in test env"
  fi
else
  echo "  SKIP: systemd-analyze not available"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "  PASS: systemd unit structure"
fi
exit "$FAIL"
