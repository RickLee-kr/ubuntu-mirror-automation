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
grep -q '\[DRY-RUN\] Would install apt-mirror nginx curl whiptail' /tmp/um-dry.out || fail "missing package dry-run line"
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
if echo "$svc" | grep -q 'ubuntu-offline-mirror.sh sync'; then
  pass "service uses offline sync wrapper"
else
  fail "offline sync ExecStart missing"
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
echo "[test_default_is_full_offline]"
OUT="$(bash "${ROOT}/install.sh" --dry-run --no-menu 2>&1 || true)"
echo "$OUT" | grep -q 'Mirror mode: full' || fail "default dry-run should report full mode for offline mirror"
echo "$OUT" | grep -qE 'universe' || fail "default full should mention universe"
pass "default is full (offline upgrade)"
OUT_MIN="$(bash "${ROOT}/install.sh" --dry-run --no-menu --minimal 2>&1 || true)"
echo "$OUT_MIN" | grep -q 'Mirror mode: minimal' || fail "--minimal should select minimal mode"
pass "--minimal selects minimal mode"
OUT_FULL="$(bash "${ROOT}/install.sh" --dry-run --no-menu --full 2>&1 || true)"
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
if grep -q 'How to confirm sync is complete' "${ROOT}/README.md" \
  && grep -q 'How to delete existing mirror data' "${ROOT}/README.md" \
  && grep -q 'State: READY' "${ROOT}/README.md"; then
  pass "README documents run / complete / delete usage"
else
  fail "README usage section incomplete"
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
grep -q 'whiptail' "${ROOT}/lib/install-menu.sh" && pass "whiptail dialog UI" || fail "whiptail missing"
grep -q 'NEWT_COLORS' "${ROOT}/lib/install-menu.sh" && pass "dialog color theme" || fail "NEWT_COLORS missing"
grep -q 'whiptail' "${ROOT}/install.sh" && pass "install ensures whiptail package" || fail "whiptail not in packages"
grep -q 'um_whiptail_file_msg\|--msgbox' "${ROOT}/lib/install-menu.sh" && pass "status uses msgbox (Enter closes)" || fail "msgbox helper missing"
if grep -qE -- '--textbox' "${ROOT}/lib/install-menu.sh"; then
  fail "textbox still used (Tab-to-Ok broken over SSH)"
else
  pass "no textbox (avoids focus trap)"
fi
grep -q 'um_calc_menu_size' "${ROOT}/lib/install-menu.sh" && pass "dynamic menu sizing (XDR-style)" || fail "missing um_calc_menu_size"
grep -q 'um_calc_dialog_size' "${ROOT}/lib/install-menu.sh" && pass "content-fitted dialog sizing" || fail "missing um_calc_dialog_size"
grep -q 'um_whiptail_fit_body' "${ROOT}/lib/install-menu.sh" && pass "body truncate avoids scroll focus trap" || fail "missing um_whiptail_fit_body"
if grep -qE 'um_center_menu_message|um_center_message' "${ROOT}/lib/install-menu.sh"; then
  fail "centering padding still present (steals Tab focus)"
else
  pass "no vertical centering padding"
fi
grep -q -- '--yes-button' "${ROOT}/lib/install-menu.sh" && pass "yesno uses OK/Cancel buttons" || fail "missing yesno OK/Cancel"
# um_whiptail_menu must keep Cancel enabled for Tab/Esc
menu_fn="$(awk '/^um_whiptail_menu\(/,/^um_whiptail_yesno\(/' "${ROOT}/lib/install-menu.sh")"
if echo "$menu_fn" | grep -q -- '--nocancel'; then
  fail "menu still uses --nocancel (blocks Tab/Cancel)"
else
  pass "menu allows Cancel (Tab/Esc)"
fi
if grep -qE -- '--nocancel' "${ROOT}/lib/install-menu.sh"; then
  fail "--nocancel still used somewhere"
else
  pass "no --nocancel anywhere"
fi
# Every direct whiptail invocation must use --fb (Tab focus on OK/Cancel)
wt_lines="$(grep -E '^\s*(result="\$\()?whiptail |^\s*whiptail ' "${ROOT}/lib/install-menu.sh" || true)"
wt_count="$(printf '%s\n' "$wt_lines" | grep -c 'whiptail' || true)"
fb_count="$(printf '%s\n' "$wt_lines" | grep -c -- '--fb' || true)"
if [[ "${wt_count}" -ge 4 ]] && [[ "${wt_count}" -eq "${fb_count}" ]]; then
  pass "all ${wt_count} whiptail calls use --fb"
else
  fail "whiptail/--fb mismatch (whiptail=${wt_count} fb=${fb_count})"
fi
# All dialogs go through helpers (only count real `whiptail --...` invocations)
raw_outside="$(awk '
  /^[[:space:]]*#/ { next }
  /^um_whiptail_(menu|yesno|msg|input)\(/ { in_helper=1 }
  in_helper && /^}/ { in_helper=0; next }
  !in_helper && /whiptail[[:space:]]+--/ { print }
' "${ROOT}/lib/install-menu.sh" || true)"
if [[ -n "${raw_outside}" ]]; then
  fail "raw whiptail outside helpers: ${raw_outside}"
else
  pass "all dialogs use whiptail helpers"
fi
grep -q 'um_menu_keys_hint' "${ROOT}/lib/install-menu.sh" && pass "keyboard hints shown" || fail "keys hint missing"
grep -q 'Tab = OK/Cancel' "${ROOT}/lib/install-menu.sh" && pass "Tab hint in keys help" || fail "Tab hint missing"
grep -q 'actcompactbutton' "${ROOT}/lib/install-menu.sh" && pass "actcompactbutton in NEWT theme" || fail "missing actcompactbutton"
grep -q -- '--fb' "${ROOT}/lib/install-menu.sh" && pass "fullbuttons (--fb) for Tab focus" || fail "missing --fb"
grep -q 'um_menu_run_detachable' "${ROOT}/lib/install-menu.sh" && pass "detachable runner for Ctrl+C" || fail "missing um_menu_run_detachable"
if grep -A6 '^um_menu_follow_logs' "${ROOT}/lib/install-menu.sh" | grep -q 'um_menu_run_detachable'; then
  pass "Follow logs Ctrl+C returns to menu"
else
  fail "Follow logs still uses bare tail (Ctrl+C aborts installer)"
fi
if grep -A20 '^um_menu_run_dashboard' "${ROOT}/lib/install-menu.sh" | grep -q 'um_menu_run_detachable'; then
  pass "Dashboard Ctrl+C returns to menu"
else
  fail "Dashboard launch missing detachable wrapper"
fi

exit "$FAIL"
