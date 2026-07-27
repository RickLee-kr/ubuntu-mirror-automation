#!/usr/bin/env bash
# tests/run_all.sh — Run all project tests with bounded timeouts and orphan cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
cd "$(dirname "${BASH_SOURCE[0]}")"

# shellcheck source=lib/worktree_fingerprint.sh
source "${ROOT}/tests/lib/worktree_fingerprint.sh"

DEFAULT_TIMEOUT_SECS="${TEST_TIMEOUT_SECS:-300}"
# test_dp_os_upgrade.sh alone is ~9 minutes on this host; keep headroom.
LONG_TIMEOUT_SECS="${TEST_LONG_TIMEOUT_SECS:-900}"
FAIL=0

TEST_LIST=(
  test_install.sh
  test_validate.sh
  test_validate_fixture.sh
  test_nginx.sh
  test_systemd.sh
  test_simplified_install.sh
  test_dashboard.sh
  test_offline_mirror.sh
  test_upgrade_profile.py
  test_selective_mirror.py
  test_selective_orchestration_lock.sh
  test_selective_runtime_migration.py
  test_sync_by_hash.py
  test_security_compat.py
  test_release_upgraders.py
  test_legacy_releases.py
  test_analyze_upgrade_discovery.py
  test_collect_dp_upgrade_readiness.sh
  test_dp_upgrade_preflight.sh
  test_dp_os_upgrade.sh
  test_discover_upgrade_requirements.sh
  test_destructive_confirmation.sh
  test_phase1_finalize.sh
  test_ntp_pre_transition_quiesce.sh
  test_dp_offline_upgrade_xenial_to_bionic.sh
  test_dp_offline_upgrade_bionic_to_focal.sh
  test_dp_offline_upgrade_focal_to_jammy.sh
  test_dp_offline_upgrade_jammy_to_noble.sh
  test_dp_phase2_bundle.sh
  test_dp_phase2_client_stage.sh
  test_dp_phase2_release_env_publish.sh
  test_dp_phase2_version_compat.sh
  test_dp_phase2_ownership.sh
  test_dp_phase2_cache_resume.sh
  test_dp_phase2_process_detect.sh
  test_client_manifest_signing.sh
  test_worktree_isolation.sh
  test_distupgrade_config_ascii.sh
  test_distupgrade_source_compat.py
  test_prepare_backup_staging.sh
  test_migrate_apt_mirror_to_root.sh
)

is_long_test() {
  case "$1" in
    test_dp_offline_upgrade_*.sh|test_dp_os_upgrade.sh|test_selective_mirror.py|test_offline_mirror.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

clear_test_fixture_orphans() {
  # Only clear known test fixture patterns — never touch production upgrade processes.
  local pid cmd
  while IFS= read -r pid; do
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    [[ -r "/proc/${pid}/cmdline" ]] || continue
    cmd="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)"
    case "$cmd" in
      *fixture-dp-offline-upgrade*|*/fake-*upgrade*|*worktree-isolation-child*)
        kill "$pid" 2>/dev/null || true
        ;;
    esac
  done < <(ps -eo pid= 2>/dev/null || true)
}

FP_BASE="$(mktemp -d)"
FP_CUR="$(mktemp -d)"
trap 'rm -rf "$FP_BASE" "$FP_CUR"' EXIT

echo "======== Capturing worktree baseline fingerprint ========"
# Existing intentional Phase 2 (or other) dirty files are part of the baseline.
# run_all must not introduce *additional* tracked/untracked drift beyond this.
worktree_save_fingerprint "$ROOT" "$FP_BASE"
echo "BASELINE_TRACKED_LINES=$(wc -l <"${FP_BASE}/tracked.sha256")"
echo "BASELINE_UNTRACKED_LINES=$(wc -l <"${FP_BASE}/untracked.list")"

check_contamination_after() {
  local label="$1"
  rm -rf "$FP_CUR"
  mkdir -p "$FP_CUR"
  worktree_save_fingerprint "$ROOT" "$FP_CUR"
  if ! worktree_diff_fingerprint "$FP_BASE" "$FP_CUR"; then
    echo "RUN_ALL_WORKTREE_CONTAMINATION=FAIL after=${label}"
    FAIL=1
    return 1
  fi
  echo "RUN_ALL_WORKTREE_CONTAMINATION=PASS after=${label}"
  return 0
}

run_one() {
  local t="$1"
  local timeout_secs="$DEFAULT_TIMEOUT_SECS"
  local rc=0
  if is_long_test "$t"; then
    timeout_secs="$LONG_TIMEOUT_SECS"
  fi
  echo "======== Running $t (timeout=${timeout_secs}s) ========"
  set +e
  # Default timeout places the command in its own process group so TERM/KILL
  # apply to the whole tree (children included).
  if [[ "$t" == *.py ]]; then
    timeout --signal=TERM --kill-after=30s "$timeout_secs" python3 "$t"
    rc=$?
  else
    timeout --signal=TERM --kill-after=30s "$timeout_secs" bash "$t"
    rc=$?
  fi
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "OK $t"
  elif [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo "FAIL $t (TIMEOUT)"
    FAIL=1
    echo "---- process tree snapshot ----"
    ps -efH || true
  else
    echo "FAIL $t (exit=${rc})"
    FAIL=1
  fi
  clear_test_fixture_orphans
  check_contamination_after "$t" || true
  echo
}

for t in "${TEST_LIST[@]}"; do
  run_one "$t"
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
  echo "WARNING: shellcheck not installed (SKIP)"
fi

clear_test_fixture_orphans
left="$(ps -eo args= | grep -E 'fixture-dp-offline-upgrade|worktree-isolation-child' | grep -v grep || true)"
if [[ -n "${left// }" ]]; then
  echo "WARNING: leftover matching processes after suite:"
  printf '%s\n' "$left"
  FAIL=1
fi

echo "======== Final worktree contamination check ========"
check_contamination_after "suite_end" || true

if [[ "$FAIL" -eq 0 ]]; then
  echo "RUN_ALL_ADDITIONAL_TRACKED_DIFF=0"
  echo "RUN_ALL_ADDITIONAL_UNTRACKED_FILES=0"
  echo "ALL TESTS PASSED"
  exit 0
fi
echo "SOME TESTS FAILED"
exit 1
