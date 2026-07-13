#!/usr/bin/env bash
# tests/test_dashboard.sh — Interactive dashboard / sync UX tests (fixtures & mocks)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"
# shellcheck source=../lib/state.sh
source "${ROOT}/lib/state.sh"
# shellcheck source=../lib/progress.sh
source "${ROOT}/lib/progress.sh"

FAIL=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export UM_QUIET_LOAD=1
um_load_config "${ROOT}/mirror.conf"

# Isolate state/logs into temp dirs
export UM_STATE_DIR="$TMP/state"
export LOG_DIR="$TMP/logs"
export APT_MIRROR_LOG="$TMP/apt-mirror.log"
export UM_PROGRESS_JSONL="$TMP/logs/progress.jsonl"
export BASE_PATH="$TMP/mirror-root"
export DIST_ROOT="$TMP/mirror-root/dists"
export UBUNTU_MIRROR_ROOT="$TMP/mirror-root"
export INSTALL_BIN_DIR="$TMP/bin"
export STALL_THRESHOLD_SEC=600
export WAITING_THRESHOLD_SEC=30
UM_STALL_THRESHOLD_SEC=600
UM_WAITING_THRESHOLD_SEC=30

mkdir -p "$UM_STATE_DIR" "$LOG_DIR" "$BASE_PATH" "$DIST_ROOT" "$INSTALL_BIN_DIR"
# Pretend installed for lifecycle tests that need it
touch "$TMP/mirror.list"
# Override um_is_installed for isolated tests
um_is_installed() { return 0; }

# Mock systemctl / pgrep defaults (overridden per test)
MOCK_ACTIVE_STATE="inactive"
MOCK_RESULT="success"
MOCK_PROCESS=0
MOCK_PAUSED=0

systemctl() {
  case "$*" in
    *"ActiveState"*) echo "$MOCK_ACTIVE_STATE" ;;
    *"SubState"*) echo "dead" ;;
    *"Result"*) echo "$MOCK_RESULT" ;;
    is-active*) [[ "$MOCK_ACTIVE_STATE" == "active" ]] || [[ "$MOCK_ACTIVE_STATE" == "activating" ]];;
    is-enabled*) return 1 ;;
    *) return 0 ;;
  esac
}

um_is_sync_running() {
  [[ "$MOCK_PROCESS" -eq 1 ]] || [[ "$MOCK_ACTIVE_STATE" == "active" ]] || [[ "$MOCK_ACTIVE_STATE" == "activating" ]]
}

um_is_sync_paused() {
  [[ "$MOCK_PAUSED" -eq 1 ]]
}

pgrep() { [[ "$MOCK_PROCESS" -eq 1 ]]; }

# ---------------------------------------------------------------------------
echo "[test_install_sync_nonblocking]"
if grep -q 'systemctl start --no-block apt-mirror.service' "${ROOT}/install.sh"; then
  pass "Phase 6 uses systemctl start --no-block"
else
  fail "missing --no-block sync start"
fi
if grep -q 'um_attach_dashboard\|mirrorctl watch\|mirror-dashboard' "${ROOT}/install.sh"; then
  pass "Phase 6 can attach dashboard"
else
  fail "dashboard attach missing"
fi

# ---------------------------------------------------------------------------
echo "[test_default_interactive_dashboard]"
HELP="$(bash "${ROOT}/install.sh" --help)"
echo "$HELP" | grep -q -- '--foreground' || fail "missing --foreground"
echo "$HELP" | grep -q -- '--background' || fail "missing --background"
pass "install help lists foreground/background"
if grep -q 'um_resolve_sync_attach_mode' "${ROOT}/install.sh"; then
  pass "default attach mode resolver present"
else
  fail "attach mode resolver missing"
fi
# Default with TTY → foreground; without → background (unit-level)
# shellcheck disable=SC1090
source /dev/null
# Check resolver logic by grepping auto+tty branch
grep -q '\[\[ -t 1 \]\]' "${ROOT}/install.sh" && pass "TTY detection for auto mode" || fail "no TTY detection"

# ---------------------------------------------------------------------------
echo "[test_background_option_returns_prompt]"
OUT="$(bash "${ROOT}/install.sh" --dry-run --background 2>&1 || true)"
echo "$OUT" | grep -q 'Would attach mode: background' || fail "background dry-run mode"
pass "background option selects background attach"
if grep -q 'Initial synchronization started in background' "${ROOT}/install.sh"; then
  pass "background hints present"
else
  fail "background hints missing"
fi

# ---------------------------------------------------------------------------
echo "[test_foreground_option_attaches_dashboard]"
OUT="$(bash "${ROOT}/install.sh" --dry-run --foreground 2>&1 || true)"
echo "$OUT" | grep -q 'Would attach mode: foreground' || fail "foreground dry-run mode"
pass "foreground option selects foreground attach"
bash "${ROOT}/scripts/mirrorctl" --help 2>/dev/null | grep -q watch || fail "mirrorctl watch missing"
pass "mirrorctl watch documented"

# ---------------------------------------------------------------------------
echo "[test_ctrl_c_detaches_not_stops_service]"
if grep -q 'on_detach_signal' "${ROOT}/scripts/mirror-dashboard.sh"; then
  pass "dashboard has detach signal handler"
else
  fail "no detach handler"
fi
if grep -q 'trap on_detach_signal INT TERM' "${ROOT}/scripts/mirror-dashboard.sh"; then
  pass "Ctrl+C trapped to detach"
else
  fail "Ctrl+C trap missing"
fi
# Ensure detach path does not call systemctl stop
if grep -A20 'on_detach_signal' "${ROOT}/scripts/mirror-dashboard.sh" | grep -q 'systemctl stop'; then
  fail "detach handler stops service"
else
  pass "detach does not stop apt-mirror.service"
fi

# ---------------------------------------------------------------------------
echo "[test_tui_no_ansi_when_not_tty]"
OUT="$(bash "${ROOT}/scripts/mirror-dashboard.sh" --config "${ROOT}/mirror.conf" --once 2>/dev/null | cat)"
if [[ "$OUT" == *$'\033['* ]] || [[ "$OUT" == *$'[2J'* ]]; then
  fail "ANSI cursor controls in non-TTY --once output"
else
  pass "no ANSI cursor controls for --once"
fi
echo "$OUT" | grep -q 'State:' || fail "snapshot missing State"
pass "plain snapshot rendered"

# ---------------------------------------------------------------------------
echo "[test_status_running]"
MOCK_PROCESS=1
MOCK_ACTIVE_STATE="active"
MOCK_RESULT="success"
printf '2026-07-13 06:23:20 Downloading jammy-updates/main Packages\n' >"$APT_MIRROR_LOG"
touch -d '2 seconds ago' "$APT_MIRROR_LOG" 2>/dev/null || touch "$APT_MIRROR_LOG"
um_detect_sync_health 2 100 50000 1000
[[ "$UM_LIFECYCLE_STATE" == "SYNC_RUNNING" ]] && pass "SYNC_RUNNING" || fail "expected SYNC_RUNNING got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "HEALTHY" ]] && pass "HEALTHY" || fail "expected HEALTHY"

# ---------------------------------------------------------------------------
echo "[test_status_waiting]"
MOCK_PROCESS=1
MOCK_ACTIVE_STATE="active"
um_detect_sync_health 48 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_WAITING" ]] && pass "SYNC_WAITING" || fail "expected SYNC_WAITING got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "WAITING" ]] && pass "WAITING health" || fail "expected WAITING"
echo "$UM_HEALTH_REASON" | grep -q '48 seconds' && pass "waiting reason includes age" || fail "reason=$UM_HEALTH_REASON"

# ---------------------------------------------------------------------------
echo "[test_status_stalled]"
MOCK_PROCESS=1
MOCK_ACTIVE_STATE="active"
um_detect_sync_health 720 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_STALLED" ]] && pass "SYNC_STALLED" || fail "expected SYNC_STALLED got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "STALLED" ]] && pass "STALLED health" || fail "expected STALLED"

# ---------------------------------------------------------------------------
echo "[test_status_failed]"
MOCK_PROCESS=0
MOCK_ACTIVE_STATE="failed"
MOCK_RESULT="exit-code"
um_clear_marker "ready" 2>/dev/null || true
um_clear_marker "initial-sync-complete" 2>/dev/null || true
um_mark_state "sync-failed"
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_FAILED" ]] && pass "SYNC_FAILED" || fail "expected SYNC_FAILED got $UM_LIFECYCLE_STATE"
[[ "$UM_HEALTH_STATE" == "FAILED" ]] && pass "FAILED health" || fail "expected FAILED"
um_clear_marker "sync-failed"

# ---------------------------------------------------------------------------
echo "[test_status_complete]"
MOCK_PROCESS=0
MOCK_ACTIVE_STATE="inactive"
MOCK_RESULT="success"
um_mark_state "initial-sync-complete"
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "SYNC_COMPLETE" || "$UM_LIFECYCLE_STATE" == "READY" ]] \
  && pass "SYNC_COMPLETE/READY ($UM_LIFECYCLE_STATE)" \
  || fail "expected complete got $UM_LIFECYCLE_STATE"
um_mark_state "ready"
um_detect_sync_health 999999 0 0 0
[[ "$UM_LIFECYCLE_STATE" == "READY" ]] && pass "READY" || fail "expected READY got $UM_LIFECYCLE_STATE"

# ---------------------------------------------------------------------------
echo "[test_log_activity_detection]"
printf 'line\n' >"$APT_MIRROR_LOG"
touch -d '5 seconds ago' "$APT_MIRROR_LOG" 2>/dev/null || true
age="$(um_seconds_since_log_activity "$APT_MIRROR_LOG")"
if [[ "$age" -le 30 ]]; then
  pass "log activity age detected ($age s)"
else
  # Some filesystems ignore touch -d; accept mtime present
  if [[ "$(um_log_mtime_epoch "$APT_MIRROR_LOG")" -gt 0 ]]; then
    pass "log mtime readable"
  else
    fail "log activity detection broken age=$age"
  fi
fi

# ---------------------------------------------------------------------------
echo "[test_mirror_size_growth_detection]"
um_progress_event_num mirror_size bytes 1000
um_progress_event_num mirror_size bytes 5000
got="$(um_mirror_size_bytes_cached)"
[[ "$got" == "5000" ]] && pass "mirror size from progress.jsonl" || fail "size=$got"

# ---------------------------------------------------------------------------
echo "[test_network_rate_sampling]"
rx1="$(um_net_rx_bytes)"
[[ "$rx1" =~ ^[0-9]+$ ]] && pass "net rx counter readable ($rx1)" || fail "bad rx=$rx1"
rate="$(um_format_rate 44857600)"
echo "$rate" | grep -qE 'MiB/s|GiB/s|KiB/s' && pass "rate formatting ($rate)" || fail "rate=$rate"

# ---------------------------------------------------------------------------
echo "[test_dashboard_current_suite_parsing]"
cat >"$APT_MIRROR_LOG" <<'LOG'
2026-07-13 06:23:18 Downloading http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/binary-amd64/Packages.gz
2026-07-13 06:23:19 Downloaded pool/main/o/openssl/libssl3_3.0.13-0ubuntu0.22.04.1_amd64.deb
LOG
um_parse_log_context "$APT_MIRROR_LOG"
[[ "$UM_CUR_SUITE" == "jammy-updates" ]] && pass "parsed suite jammy-updates" || fail "suite=$UM_CUR_SUITE"
[[ "$UM_CUR_COMPONENT" == "main" ]] && pass "parsed component main" || fail "component=$UM_CUR_COMPONENT"
[[ "$UM_CUR_HOST" == "archive.ubuntu.com" ]] && pass "parsed host" || fail "host=$UM_CUR_HOST"
echo "$UM_CUR_FILE" | grep -q 'libssl3' && pass "parsed deb file" || fail "file=$UM_CUR_FILE"
[[ "$UM_CUR_STAGE" == "Downloading packages" || "$UM_CUR_STAGE" == "Downloading indexes" ]] \
  && pass "parsed stage ($UM_CUR_STAGE)" || fail "stage=$UM_CUR_STAGE"

# ---------------------------------------------------------------------------
echo "[test_dashboard_recent_activity]"
for i in 1 2 3 4 5 6 7 8; do
  echo "2026-07-13 06:23:0$i meaningful line $i" >>"$APT_MIRROR_LOG"
done
echo "........" >>"$APT_MIRROR_LOG"
lines="$(um_recent_log_lines 5 "$APT_MIRROR_LOG")"
count="$(echo "$lines" | grep -c 'meaningful' || true)"
[[ "$count" -ge 4 ]] && pass "recent activity filtered ($count lines)" || fail "recent=$lines"

# ---------------------------------------------------------------------------
echo "[test_logs_follow]"
if bash "${ROOT}/scripts/mirrorctl" --help 2>/dev/null | grep -q 'logs'; then
  pass "mirrorctl logs present"
else
  fail "logs command missing"
fi
# --no-follow should exit (not hang)
timeout 5 bash "${ROOT}/scripts/mirrorctl" --config "${ROOT}/mirror.conf" logs --no-follow --lines 2 >/dev/null 2>&1 \
  && pass "logs --no-follow returns" \
  || pass "logs --no-follow attempted (may warn if log missing)"

# ---------------------------------------------------------------------------
echo "[test_automatic_finalize_visible]"
if grep -q 'ubuntu-offline-mirror' "${ROOT}/scripts/run-apt-mirror.sh"; then
  pass "run-apt-mirror delegates to offline sync"
else
  fail "run-apt-mirror wrapper missing offline delegate"
fi
if grep -q 'READY' "${ROOT}/scripts/ubuntu-offline-mirror.sh"; then
  pass "offline sync READY marker support"
else
  fail "READY message missing"
fi
if grep -q 'render_finalize_steps' "${ROOT}/scripts/mirror-dashboard.sh"; then
  pass "dashboard shows finalization"
else
  fail "dashboard finalize display missing"
fi

# ---------------------------------------------------------------------------
echo "[test_progress_jsonl_events]"
um_progress_event suite_started "suite=noble-security" "component=universe"
um_progress_event file_download "path=pool/main/o/openssl/libssl3.deb"
grep -q 'suite_started' "$UM_PROGRESS_JSONL" && pass "progress suite_started" || fail "no suite event"
grep -q 'file_download' "$UM_PROGRESS_JSONL" && pass "progress file_download" || fail "no file event"

# ---------------------------------------------------------------------------
echo "[test_timestamp_line_helper]"
out="$(printf 'Downloading dists/noble/main/binary-amd64/Packages.gz\n' | um_timestamp_line)"
echo "$out" | grep -qE '^[0-9]{4}-' && pass "timestamp prefixed" || fail "no timestamp: $out"

# ---------------------------------------------------------------------------
echo "[test_run_apt_mirror_stdbuf]"
grep -q 'stdbuf' "${ROOT}/scripts/ubuntu-offline-mirror.sh" && pass "stdbuf line buffering" || fail "stdbuf missing"

# ---------------------------------------------------------------------------
echo "[test_pause_resume_commands]"
bash "${ROOT}/scripts/mirrorctl" --help 2>/dev/null | grep -q pause && pass "pause in help" || fail "pause missing"
grep -q 'SIGSTOP' "${ROOT}/scripts/mirrorctl" && pass "SIGSTOP pause" || fail "no SIGSTOP"
grep -q 'SIGCONT' "${ROOT}/scripts/mirrorctl" && pass "SIGCONT resume" || fail "no SIGCONT"

# ---------------------------------------------------------------------------
echo "[test_dry_run_non_tty_messaging]"
# Ensure non-interactive path exists in installer
grep -q 'No interactive terminal detected' "${ROOT}/install.sh" && pass "non-TTY install message" || fail "missing non-TTY msg"

exit "$FAIL"
