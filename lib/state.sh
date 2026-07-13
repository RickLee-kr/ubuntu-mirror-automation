#!/usr/bin/env bash
# shellcheck shell=bash
# Lifecycle / state helpers for Ubuntu Mirror Server.

# shellcheck disable=SC2317
if [[ -n "${UM_STATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_STATE_LOADED=1

# States: NOT_INSTALLED | INSTALLED | SYNC_RUNNING | SYNC_FAILED | SYNC_COMPLETE | READY

um_state_root() {
  if [[ -n "${UM_STATE_DIR:-}" ]]; then
    printf '%s\n' "$UM_STATE_DIR"
    return
  fi
  if [[ -d /var/lib/ubuntu-mirror ]] || [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' "/var/lib/ubuntu-mirror"
  else
    printf '%s\n' "${INSTALL_CONF_DIR:-/tmp/ubuntu-mirror-state}"
  fi
}

um_ensure_state_dir() {
  mkdir -p "$(um_state_root)" 2>/dev/null || true
}

um_state_marker() {
  printf '%s/%s\n' "$(um_state_root)" "$1"
}

um_mark_state() {
  local name="$1"
  um_ensure_state_dir
  date -Is >"$(um_state_marker "$name")" 2>/dev/null || true
}

um_has_marker() {
  [[ -f "$(um_state_marker "$1")" ]]
}

um_clear_marker() {
  rm -f "$(um_state_marker "$1")" 2>/dev/null || true
}

um_is_sync_running() {
  if systemctl is-active --quiet apt-mirror.service 2>/dev/null; then
    return 0
  fi
  pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1
}

um_is_installed() {
  [[ -f /etc/apt/mirror.list ]] \
    && [[ -f /etc/systemd/system/apt-mirror.service ]] \
    && [[ -x "${INSTALL_BIN_DIR:-/usr/local/bin}/mirrorctl" ]]
}

um_initial_sync_complete() {
  if um_has_marker "initial-sync-complete"; then
    return 0
  fi
  local noble_release
  noble_release="${DIST_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/mirror/archive.ubuntu.com/ubuntu/dists}/noble/Release"
  if [[ -f "$noble_release" ]]; then
    if [[ -f "${APT_MIRROR_LOG:-/var/log/apt-mirror.log}" ]] && grep -q 'End time:' "${APT_MIRROR_LOG}" 2>/dev/null; then
      return 0
    fi
    if [[ -f "${APT_MIRROR_INITIAL_LOG:-/var/log/apt-mirror-initial.log}" ]] && grep -q 'End time:' "${APT_MIRROR_INITIAL_LOG}" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

um_detect_lifecycle_state() {
  if ! um_is_installed; then
    printf 'NOT_INSTALLED\n'
    return
  fi
  if um_has_marker "ready"; then
    printf 'READY\n'
    return
  fi
  if um_initial_sync_complete && systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
    printf 'READY\n'
    return
  fi
  if um_is_sync_running; then
    printf 'SYNC_RUNNING\n'
    return
  fi
  if um_has_marker "sync-failed"; then
    printf 'SYNC_FAILED\n'
    return
  fi
  if um_initial_sync_complete; then
    printf 'SYNC_COMPLETE\n'
    return
  fi
  printf 'INSTALLED\n'
}
