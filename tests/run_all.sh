#!/usr/bin/env bash
# tests/run_all.sh — Run all project tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")"

FAIL=0
for t in test_install.sh test_validate.sh test_validate_fixture.sh test_nginx.sh test_systemd.sh test_simplified_install.sh test_dashboard.sh test_offline_mirror.sh test_upgrade_profile.py test_selective_mirror.py test_selective_orchestration_lock.sh test_selective_runtime_migration.py test_sync_by_hash.py test_security_compat.py test_release_upgraders.py test_legacy_releases.py test_analyze_upgrade_discovery.py test_collect_dp_upgrade_readiness.sh test_dp_upgrade_preflight.sh test_dp_os_upgrade.sh test_discover_upgrade_requirements.sh test_dp_offline_upgrade_xenial_to_bionic.sh test_dp_offline_upgrade_bionic_to_focal.sh test_dp_offline_upgrade_focal_to_jammy.sh test_dp_offline_upgrade_jammy_to_noble.sh test_client_manifest_signing.sh test_distupgrade_config_ascii.sh test_distupgrade_source_compat.py test_prepare_backup_staging.sh; do
  echo "======== Running $t ========"
  if [[ "$t" == *.py ]]; then
    if python3 "$t"; then
      echo "OK $t"
    else
      echo "FAIL $t"
      FAIL=1
    fi
  elif bash "$t"; then
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
  if ! (cd "$ROOT" && shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "${SCRIPTS[@]}"); then
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
