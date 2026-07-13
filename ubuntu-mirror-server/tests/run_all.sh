#!/usr/bin/env bash
# tests/run_all.sh — Run all project tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL=0
for t in test_install.sh test_validate.sh test_validate_fixture.sh test_nginx.sh test_systemd.sh; do
  echo "======== Running $t ========"
  if bash "$t"; then
    echo "OK $t"
  else
    echo "FAIL $t"
    FAIL=1
  fi
  echo
done

# ShellCheck + bash -n on all scripts
echo "======== Syntax & ShellCheck ========"
mapfile -t SCRIPTS < <(find "$ROOT" -type f \( -name '*.sh' -o -name 'mirrorctl' -o -name 'install.sh' -o -name 'uninstall.sh' -o -name 'validate.sh' \) ! -path '*/tests/fixtures/*')
for s in "${SCRIPTS[@]}"; do
  bash -n "$s" || FAIL=1
done

if command -v shellcheck >/dev/null 2>&1; then
  # SC1091: dynamic source paths resolved at runtime; -x follows shellcheck source= hints
  if ! (cd "$ROOT" && shellcheck -x -e SC1091 "${SCRIPTS[@]}"); then
    FAIL=1
  fi
else
  echo "WARNING: shellcheck not installed"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL TESTS PASSED"
  exit 0
fi
echo "SOME TESTS FAILED"
exit 1
