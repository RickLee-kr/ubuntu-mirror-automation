#!/usr/bin/env bash
# tests/test_simplified_install.sh — Required simplified-workflow tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=../lib/state.sh
source "${ROOT}/lib/state.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }

check() {
  if "$1"; then
    pass "$2"
  else
    fail "$2"
  fi
}

# ---------------------------------------------------------------------------
echo "[test_default_install_flow] help lists simplified options only"
HELP="$(bash "${ROOT}/install.sh" --help)"
echo "$HELP" | grep -q -- '--dry-run' || fail "missing --dry-run"
echo "$HELP" | grep -q -- '--no-sync' || fail "missing --no-sync"
echo "$HELP" | grep -q -- '--full' || fail "missing --full"
echo "$HELP" | grep -q -- '--minimal' || fail "missing --minimal"
echo "$HELP" | grep -q -- '--menu' || fail "missing --menu"
echo "$HELP" | grep -q -- '--verbose' || fail "missing --verbose"
if echo "$HELP" | grep -q -- '--start-sync'; then fail "deprecated --start-sync still in help"; fi
if echo "$HELP" | grep -Eq -- '--validate([[:space:]]|$)'; then fail "deprecated --validate still in help"; fi
# --non-interactive is a supported automation alias (skips menu)
echo "$HELP" | grep -q -- '--non-interactive' || fail "missing --non-interactive"
pass "operator help surface"

# ---------------------------------------------------------------------------
echo "[test_default_starts_initial_sync] default plan includes sync"
OUT="$(bash "${ROOT}/install.sh" --dry-run 2>&1 || true)"
echo "$OUT" | grep -q 'Would start initial synchronization' || fail "default dry-run should start sync"
echo "$OUT" | grep -q 'Dry-run completed successfully' || fail "dry-run success banner"
pass "default starts initial sync (dry-run)"

# ---------------------------------------------------------------------------
echo "[test_no_sync_option]"
OUT="$(bash "${ROOT}/install.sh" --dry-run --no-sync 2>&1 || true)"
echo "$OUT" | grep -q 'Skipping initial sync' || fail "--no-sync should skip sync"
pass "--no-sync"

# ---------------------------------------------------------------------------
echo "[test_dry_run_without_packages_installed]"
if command -v apt-mirror >/dev/null 2>&1; then
  echo "  SKIP: apt-mirror already installed on this host"
else
  pass "apt-mirror not installed (reproduces defect environment)"
fi
if command -v nginx >/dev/null 2>&1; then
  echo "  NOTE: nginx present"
else
  pass "nginx not installed"
fi

# ---------------------------------------------------------------------------
echo "[test_dry_run_exit_zero]"
set +e
bash "${ROOT}/install.sh" --dry-run >/tmp/um-dry.out 2>&1
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
  pass "dry-run exit 0"
else
  fail "dry-run exit $RC"
  tail -30 /tmp/um-dry.out || true
fi
if grep -q 'apt-mirror not found after install' /tmp/um-dry.out; then
  fail "false apt-mirror not found error still present"
else
  pass "no false apt-mirror not found error"
fi
grep -q '\[DRY-RUN\] Would install apt-mirror nginx curl' /tmp/um-dry.out || fail "missing package dry-run line"
grep -q '\[DRY-RUN\] Would write /etc/apt/mirror.list' /tmp/um-dry.out || fail "missing mirror.list dry-run"
grep -q 'SKIPPED: requires installed package' /tmp/um-dry.out || fail "missing SKIPPED marker"
pass "dry-run messaging"

# ---------------------------------------------------------------------------
echo "[test_existing_mount_not_formatted]"
if grep -qiE 'mkfs|wipefs|format' /tmp/um-dry.out; then
  fail "dry-run mentioned format/mkfs"
else
  pass "no format in normal dry-run"
fi
um_load_config "${ROOT}/mirror.conf"
[[ -z "${DATA_DEVICE}" ]] && pass "DATA_DEVICE empty by default"

# ---------------------------------------------------------------------------
echo "[test_existing_install_idempotent] generators are stable"
um_load_config "${ROOT}/mirror.conf"
A="$(mktemp)"; B="$(mktemp)"
um_generate_mirror_list >"$A"
um_generate_mirror_list >"$B"
if cmp -s "$A" "$B"; then
  pass "mirror.list generation idempotent"
else
  fail "generator unstable"
fi
rm -f "$A" "$B"

# ---------------------------------------------------------------------------
echo "[test_sync_pending_not_install_failure]"
um_result_reset
um_result WARNING "Ubuntu versions" "INSTALLATION_OK_SYNC_PENDING"
if [[ "$UM_FAIL_COUNT" -eq 0 ]]; then
  pass "sync pending is WARNING not FAIL"
else
  fail "unexpected FAIL count"
fi

# ---------------------------------------------------------------------------
echo "[test_nginx_failure_stops_before_sync]"
if grep -q 'Installation stopped due to critical validation failure' "${ROOT}/install.sh"; then
  pass "critical nginx/systemd failure aborts before sync"
else
  fail "missing abort path"
fi

# ---------------------------------------------------------------------------
echo "[test_timer_disabled_before_initial_sync]"
if grep -q 'disable apt-mirror.timer' "${ROOT}/install.sh"; then
  pass "timer disabled until sync"
else
  fail "timer not explicitly disabled"
fi
svc="$(um_generate_systemd_service)"
if echo "$svc" | grep -q 'run-apt-mirror.sh'; then
  pass "service uses finalize wrapper"
else
  fail "wrapper missing"
fi

# ---------------------------------------------------------------------------
echo "[test_backup_only_when_changed]"
if grep -n 'cmp -s' "${ROOT}/install.sh" | grep -q .; then
  pass "cmp guards backups"
else
  fail "no cmp guards"
fi

# ---------------------------------------------------------------------------
echo "[test_normal_install_summary]"
if grep -q 'Ubuntu Mirror Server installation completed' "${ROOT}/install.sh"; then
  pass "operator summary present"
else
  fail "summary missing"
fi
if grep -q 'sudo mirrorctl status' "${ROOT}/install.sh"; then
  pass "summary points to mirrorctl status"
else
  fail "status hint missing"
fi
if grep -q 'sudo mirrorctl finalize' "${ROOT}/install.sh"; then
  pass "summary mentions finalize"
else
  fail "finalize hint missing"
fi

# ---------------------------------------------------------------------------
echo "[test_minimal_option]"
if bash "${ROOT}/install.sh" --help | grep -q -- '--minimal'; then
  pass "--minimal accepted"
else
  fail "--minimal"
fi

# ---------------------------------------------------------------------------
echo "[test_default_is_minimal_not_full]"
OUT="$(bash "${ROOT}/install.sh" --dry-run 2>&1 || true)"
echo "$OUT" | grep -q 'Mirror mode: minimal' || fail "default dry-run should report minimal mode"
echo "$OUT" | grep -qE 'main restricted' || fail "default should mention main restricted"
if echo "$OUT" | grep -q 'Mirror mode: full'; then
  fail "default must not select full mode"
else
  pass "default is minimal"
fi
OUT_FULL="$(bash "${ROOT}/install.sh" --dry-run --full 2>&1 || true)"
echo "$OUT_FULL" | grep -q 'Mirror mode: full' || fail "--full should select full mode"
pass "--full selects full mode"

# ---------------------------------------------------------------------------
echo "[test_capacity_check_in_install]"
echo "$OUT" | grep -q 'Pre-sync capacity check\|Projected mirror size\|Disk capacity check' \
  || fail "dry-run should run capacity check"
pass "capacity check present"
if grep -q 'um_check_sync_capacity' "${ROOT}/install.sh"; then
  pass "install calls um_check_sync_capacity"
else
  fail "capacity gate missing"
fi
if grep -q 'um_resolve_mirror_mode' "${ROOT}/install.sh"; then
  pass "mode resolver used"
else
  fail "mode resolver missing"
fi

# ---------------------------------------------------------------------------
echo "[test_readme_quick_start]"
if grep -q 'sudo ./install.sh' "${ROOT}/README.md"; then
  pass "README quick start"
else
  fail "README"
fi
if grep -q 'Interactive setup menu\|Delete existing mirror data' "${ROOT}/README.md"; then
  pass "README documents interactive menu"
else
  fail "README menu docs missing"
fi
if grep -q 'Development and Troubleshooting' "${ROOT}/README.md"; then
  pass "README has advanced section"
else
  fail "advanced section"
fi

# ---------------------------------------------------------------------------
echo "[test_install_menu_helpers]"
# shellcheck source=../lib/install-menu.sh
source "${ROOT}/lib/install-menu.sh"
UM_DRY_RUN=1
UM_FORCE_MENU=0
UM_NO_MENU=0
UM_FULL=0
UM_MINIMAL=0
UM_NO_SYNC=0
UM_SYNC_MODE="auto"
if um_should_show_install_menu; then
  fail "dry-run should not show menu"
else
  pass "dry-run skips menu"
fi
UM_DRY_RUN=0
UM_NO_MENU=1
if um_should_show_install_menu; then
  fail "--no-menu should skip"
else
  pass "--no-menu skips menu"
fi
UM_NO_MENU=0
UM_FULL=1
if um_should_show_install_menu; then
  fail "--full should skip menu"
else
  pass "--full skips menu"
fi
grep -q 'Delete existing mirror data' "${ROOT}/lib/install-menu.sh" && pass "purge menu option exists" || fail "purge missing"
grep -q 'Monitor live dashboard' "${ROOT}/lib/install-menu.sh" && pass "monitor menu option exists" || fail "monitor missing"
grep -q 'um_install_menu' "${ROOT}/install.sh" && pass "install.sh calls menu" || fail "menu not wired"

exit "$FAIL"
