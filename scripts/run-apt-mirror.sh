#!/usr/bin/env bash
# run-apt-mirror.sh — systemd ExecStart wrapper
# Runs apt-mirror, then auto-finalizes after the first successful sync.
set -euo pipefail

if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/common.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/config.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/state.sh
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=lib/common.sh
  source "${ROOT}/lib/common.sh"
  # shellcheck source=lib/config.sh
  source "${ROOT}/lib/config.sh"
  # shellcheck source=lib/state.sh
  source "${ROOT}/lib/state.sh"
fi

um_load_config "${1:-}"
um_set_log_file "${LOG_DIR}/sync.log"
um_ensure_log_dir
um_ensure_state_dir

um_clear_marker "sync-failed"
um_mark_state "sync-started"

set +e
/usr/bin/apt-mirror
rc=$?
set -e

if [[ "$rc" -ne 0 ]]; then
  um_mark_state "sync-failed"
  um_error "apt-mirror exited with $rc"
  exit "$rc"
fi

# Record completion in initial log for operators
{
  echo "End time: $(date)"
  echo "apt-mirror completed successfully"
} >>"${APT_MIRROR_LOG}" 2>/dev/null || true

um_mark_state "initial-sync-complete"
um_clear_marker "sync-failed"

# Auto-finalize once: cleanup + enable timer + mark ready
if ! um_has_marker "ready"; then
  um_info "Auto-finalizing after successful sync"
  if [[ -x "${CLEAN_SCRIPT:-$VAR_PATH/clean.sh}" ]]; then
    # clean.sh may be large; run safely
    bash "${CLEAN_SCRIPT:-$VAR_PATH/clean.sh}" >>"${LOG_DIR}/cleanup.log" 2>&1 || \
      um_warn "cleanup reported errors (see ${LOG_DIR}/cleanup.log)"
  fi
  systemctl enable apt-mirror.timer >/dev/null 2>&1 || true
  systemctl start apt-mirror.timer >/dev/null 2>&1 || true
  um_mark_state "ready"
  um_info "Initial sync finalized; daily timer enabled"
fi

exit 0
