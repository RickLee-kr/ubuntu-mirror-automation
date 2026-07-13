#!/usr/bin/env bash
# test_validate.sh — Syntax and offline validation helper tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "[test] validate.sh syntax and --help"
bash -n "${ROOT}/validate.sh"
bash "${ROOT}/validate.sh" --help >/dev/null

echo "[test] result helpers"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
um_result_reset
um_result PASS "example" "ok"
um_result WARNING "example2" "warn"
# summary should return 1 due to warning
set +e
um_result_summary >/dev/null
rc=$?
set -e
if [[ "$rc" -eq 1 ]]; then
  echo "  PASS: summary returns 1 on warnings"
else
  echo "  FAIL: summary rc=$rc expected 1"
  FAIL=1
fi

echo "[test] client-validate --help"
bash -n "${ROOT}/client/client-validate.sh"
bash "${ROOT}/client/client-validate.sh" --help >/dev/null

echo "[test] client-setup --help"
bash -n "${ROOT}/client/client-setup.sh"
bash "${ROOT}/client/client-setup.sh" --help >/dev/null

exit "$FAIL"
