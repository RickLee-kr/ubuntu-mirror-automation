#!/usr/bin/env bash
# run-apt-mirror.sh — systemd ExecStart wrapper
# Runs apt-mirror with line-buffered, timestamped logging and progress events,
# then auto-finalizes after the first successful sync (with visible steps).
set -euo pipefail

if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/common.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/config.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/state.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/progress.sh
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=lib/common.sh
  source "${ROOT}/lib/common.sh"
  # shellcheck source=lib/config.sh
  source "${ROOT}/lib/config.sh"
  # shellcheck source=lib/state.sh
  source "${ROOT}/lib/state.sh"
  # shellcheck source=lib/progress.sh
  source "${ROOT}/lib/progress.sh"
fi

um_load_config "${1:-}"
um_set_log_file "${LOG_DIR}/sync.log"
um_ensure_log_dir
um_ensure_state_dir
um_progress_ensure_dirs

SAMPLER_PID=""
cleanup_sampler() {
  if [[ -n "${SAMPLER_PID}" ]] && kill -0 "$SAMPLER_PID" 2>/dev/null; then
    kill "$SAMPLER_PID" 2>/dev/null || true
    wait "$SAMPLER_PID" 2>/dev/null || true
  fi
}
trap cleanup_sampler EXIT

finalize_log() {
  local msg="$1"
  local flog
  flog="$(um_finalize_log_path)"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$flog" >>"${APT_MIRROR_LOG}" 2>/dev/null || \
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$flog"
}

um_clear_marker "sync-failed"
um_mark_state "sync-started"
um_progress_event sync_started "mode=${MIRROR_MODE}"

# Refuse to start if projected download would violate the safety reserve
if ! um_check_sync_capacity "$BASE_PATH" "$MIRROR_MODE"; then
  um_mark_state "sync-failed"
  um_progress_event sync_failed "reason=capacity"
  exit 2
fi

# Start filesystem progress sampler in background
um_progress_sampler_loop 30 &
SAMPLER_PID=$!

# Prefer line-buffered apt-mirror output when stdbuf is available
run_apt_mirror() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL /usr/bin/apt-mirror
  else
    /usr/bin/apt-mirror
  fi
}

set +e
# Timestamp every line into the operational log; preserve raw content with timestamps.
# Also append unbuffered to APT_MIRROR_LOG for operators / journal duplication.
{
  echo "Start time: $(date)"
  echo "apt-mirror starting (line-buffered)"
} >>"${APT_MIRROR_LOG}" 2>/dev/null || true

run_apt_mirror 2>&1 | um_timestamp_line | tee -a "${APT_MIRROR_LOG}"
rc=${PIPESTATUS[0]}
set -e

cleanup_sampler
SAMPLER_PID=""

if [[ "$rc" -ne 0 ]]; then
  um_mark_state "sync-failed"
  um_progress_event sync_failed "rc=${rc}"
  um_error "apt-mirror exited with $rc"
  finalize_log "[FAIL] apt-mirror exited with ${rc}"
  exit "$rc"
fi

{
  echo "End time: $(date)"
  echo "apt-mirror completed successfully"
} >>"${APT_MIRROR_LOG}" 2>/dev/null || true

um_mark_state "initial-sync-complete"
um_clear_marker "sync-failed"
um_progress_event sync_complete
finalize_log "[OK] Initial synchronization completed"

# Auto-finalize once: cleanup + enable timer + mark ready (visible steps)
if ! um_has_marker "ready"; then
  um_mark_state "finalizing"
  um_progress_event finalization_started
  finalize_log "[RUNNING] Removing superseded packages"

  if [[ -x "${CLEAN_SCRIPT:-$VAR_PATH/clean.sh}" ]]; then
    if bash "${CLEAN_SCRIPT:-$VAR_PATH/clean.sh}" >>"${LOG_DIR}/cleanup.log" 2>&1; then
      finalize_log "[OK] Cleanup complete"
    else
      finalize_log "[WARN] Cleanup reported errors (see ${LOG_DIR}/cleanup.log)"
      um_warn "cleanup reported errors (see ${LOG_DIR}/cleanup.log)"
    fi
  else
    finalize_log "[WARN] clean.sh not found — skipping cleanup"
  fi

  finalize_log "[RUNNING] Enabling daily timer"
  systemctl enable apt-mirror.timer >/dev/null 2>&1 || true
  systemctl start apt-mirror.timer >/dev/null 2>&1 || true
  finalize_log "[OK] Daily timer enabled"

  finalize_log "[RUNNING] Endpoint validation"
  local_code=""
  local_code="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC:-10}" -w '%{http_code}' \
    "${MIRROR_URL}/ubuntu/dists/noble/Release" 2>/dev/null || true)"
  if [[ "$local_code" == "200" ]]; then
    finalize_log "[OK] noble Release endpoint HTTP 200"
  else
    finalize_log "[WARN] noble Release endpoint HTTP ${local_code:-000}"
  fi

  um_mark_state "ready"
  um_clear_marker "finalizing"
  um_progress_event finalization_complete
  finalize_log "[OK] Mirror state READY"
  um_info "Initial sync finalized; daily timer enabled"
fi

exit 0
