#!/usr/bin/env bash
# mirror-recovery.sh — Automatic recovery for common mirror failures
# Covers: nginx down, sync interrupted, systemd unit drift, invalid mirror.list
set -euo pipefail

resolve_libs() {
  if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/common.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/config.sh
  else
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/common.sh
    source "${root}/lib/common.sh"
    # shellcheck source=lib/config.sh
    source "${root}/lib/config.sh"
  fi
}

resolve_libs

UM_CONFIG_ARG=""
UM_RESUME_SYNC=0
UM_FIX_CONFIG=0

usage() {
  cat <<'EOF'
Usage: sudo mirror-recovery.sh [--config PATH] [--resume-sync] [--fix-config]

Actions (idempotent):
  - Restart nginx if inactive / failed
  - nginx -t and reload if config valid
  - systemctl daemon-reload for apt-mirror units
  - Re-enable apt-mirror.timer if unit exists
  - Optionally rewrite /etc/apt/mirror.list from mirror.conf (--fix-config)
  - Optionally resume apt-mirror if not running (--resume-sync)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) UM_CONFIG_ARG="${2:-}"; shift 2 ;;
      --resume-sync) UM_RESUME_SYNC=1; shift ;;
      --fix-config) UM_FIX_CONFIG=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

recover_nginx() {
  um_info "Checking nginx"
  if ! um_command_exists nginx; then
    um_warn "nginx not installed — skip"
    return 0
  fi
  if ! nginx -t; then
    um_error "nginx -t failed — not restarting with broken config"
    return 1
  fi
  if ! systemctl is-active --quiet nginx; then
    um_warn "nginx inactive — restarting"
    systemctl restart nginx
  else
    systemctl reload nginx || systemctl restart nginx
  fi
  systemctl is-active --quiet nginx && um_ok "nginx recovered/healthy"
}

recover_systemd() {
  um_info "Reloading systemd units"
  systemctl daemon-reload
  if [[ -f /etc/systemd/system/apt-mirror.timer ]]; then
    systemctl enable apt-mirror.timer >/dev/null 2>&1 || true
    um_ok "apt-mirror.timer enabled"
  else
    um_warn "apt-mirror.timer missing — re-run install.sh"
  fi
}

recover_mirror_list() {
  if [[ ! -f /etc/apt/mirror.list ]]; then
    um_warn "/etc/apt/mirror.list missing"
    UM_FIX_CONFIG=1
  elif ! grep -qE '^set[[:space:]]+base_path' /etc/apt/mirror.list; then
    um_warn "base_path commented/missing (invalid config)"
    UM_FIX_CONFIG=1
  fi

  if [[ "$UM_FIX_CONFIG" == "1" ]]; then
    um_info "Rewriting /etc/apt/mirror.list from config"
    um_backup_file /etc/apt/mirror.list >/dev/null || true
    um_generate_mirror_list >/etc/apt/mirror.list
    um_ok "mirror.list restored"
  fi
}

recover_dirs() {
  mkdir -p "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH" "$LOG_DIR"
  chmod 755 "$BASE_PATH" || true
}

recover_sync() {
  if [[ "$UM_RESUME_SYNC" != "1" ]]; then
    um_info "Sync resume skipped (pass --resume-sync to start)"
    return 0
  fi
  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    um_ok "apt-mirror already running"
    return 0
  fi
  um_info "Resuming apt-mirror sync"
  touch "$APT_MIRROR_INITIAL_LOG"
  nohup apt-mirror >>"$APT_MIRROR_INITIAL_LOG" 2>&1 &
  um_ok "Resumed PID $!"
}

main() {
  parse_args "$@"
  um_require_root
  um_setup_trap
  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/recovery.log"
  um_ensure_log_dir
  um_info "=== Recovery begin ==="

  recover_dirs
  recover_mirror_list
  recover_systemd
  recover_nginx
  recover_sync

  um_ok "=== Recovery finished ==="
}

main "$@"
