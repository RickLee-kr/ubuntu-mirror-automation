#!/usr/bin/env bash
# uninstall.sh — Safely remove Ubuntu Mirror Server automation components.
# NEVER deletes mirror package data unless --purge-data --force is given.
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"

UM_DRY_RUN=0
UM_FORCE=0
UM_PURGE_DATA=0
UM_PURGE_PACKAGES=0
UM_NON_INTERACTIVE=0
UM_CONFIG_ARG=""

usage() {
  cat <<'EOF'
Usage: sudo ./uninstall.sh [OPTIONS]

Removes automation units, nginx site, and installed helper scripts.
Does NOT delete mirrored packages unless --purge-data --force.

Options:
  --config PATH      Config path
  --dry-run          Show actions only
  --force            Required for destructive options
  --purge-data       Delete BASE_PATH mirror data (DANGEROUS)
  --purge-packages   apt-get remove apt-mirror (nginx left installed)
  -h, --help         Show help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) UM_CONFIG_ARG="${2:-}"; shift 2 ;;
      --dry-run) UM_DRY_RUN=1; shift ;;
      --force) UM_FORCE=1; shift ;;
      --non-interactive) UM_NON_INTERACTIVE=1; shift ;;
      --purge-data) UM_PURGE_DATA=1; shift ;;
      --purge-packages) UM_PURGE_PACKAGES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

stop_units() {
  um_info "Stopping apt-mirror timer/service"
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "DRY-RUN: systemctl disable --now apt-mirror.timer"
    return 0
  fi
  systemctl disable --now apt-mirror.timer 2>/dev/null || true
  systemctl stop apt-mirror.service 2>/dev/null || true
  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    um_warn "apt-mirror process still running — not killing automatically"
    um_warn "Stop manually if needed: pkill -f /usr/bin/apt-mirror"
  fi
}

remove_systemd() {
  local files=(
    /etc/systemd/system/apt-mirror.service
    /etc/systemd/system/apt-mirror.timer
  )
  local f
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      um_backup_file "$f" >/dev/null || true
      um_run rm -f "$f"
    fi
  done
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    systemctl daemon-reload || true
  fi
}

remove_nginx_site() {
  local name="${NGINX_SITE_NAME:-apt-mirror}"
  local avail="/etc/nginx/sites-available/${name}"
  local enabled="/etc/nginx/sites-enabled/${name}"
  if [[ -e "$enabled" ]]; then
    um_run rm -f "$enabled"
  fi
  if [[ -e "$avail" ]]; then
    um_backup_file "$avail" >/dev/null || true
    um_run rm -f "$avail"
  fi
  if um_command_exists nginx && [[ "$UM_DRY_RUN" != "1" ]]; then
    if nginx -t 2>/dev/null; then
      systemctl reload nginx || true
    fi
  fi
}

remove_bins() {
  local bins=(
    mirrorctl mirror-status.sh mirror-recovery.sh validate.sh
    client-setup.sh client-validate.sh
  )
  local b
  for b in "${bins[@]}"; do
    um_run rm -f "${INSTALL_BIN_DIR}/${b}"
  done
  um_run rm -f /usr/local/sbin/mirrorctl
  um_run rm -rf "${INSTALL_LIB_DIR}"
  # Keep INSTALL_CONF_DIR unless force — operator may want mirror.conf
  if [[ "$UM_FORCE" == "1" ]]; then
    um_run rm -rf "${INSTALL_CONF_DIR}"
  else
    um_info "Keeping ${INSTALL_CONF_DIR} (use --force to remove)"
  fi
}

restore_mirror_list_note() {
  if [[ -f /etc/apt/mirror.list ]]; then
    um_backup_file /etc/apt/mirror.list >/dev/null || true
    um_warn "Left /etc/apt/mirror.list in place (backed up). Remove manually if desired."
  fi
}

purge_data() {
  if [[ "$UM_PURGE_DATA" != "1" ]]; then
    return 0
  fi
  if [[ "$UM_FORCE" != "1" ]]; then
    um_die "--purge-data requires --force"
  fi
  um_warn "DELETING mirror data under $BASE_PATH"
  if [[ "$UM_NON_INTERACTIVE" != "1" ]]; then
    um_confirm "Confirm deletion of $BASE_PATH ?" || um_die "Aborted"
  fi
  um_run rm -rf "${MIRROR_PATH}" "${SKEL_PATH}" "${VAR_PATH}"
  um_ok "Mirror data removed"
}

purge_packages() {
  if [[ "$UM_PURGE_PACKAGES" != "1" ]]; then
    return 0
  fi
  if [[ "$UM_FORCE" != "1" ]]; then
    um_die "--purge-packages requires --force"
  fi
  um_run apt-get remove -y apt-mirror || true
  um_warn "nginx left installed (shared service)"
}

main() {
  parse_args "$@"
  um_setup_trap
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    um_require_root
  fi
  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/uninstall.log"
  um_ensure_log_dir
  um_info "=== Uninstall begin ==="

  stop_units
  remove_systemd
  remove_nginx_site
  remove_bins
  restore_mirror_list_note
  purge_data
  purge_packages

  um_ok "=== Uninstall finished ==="
  um_info "Backups under ${BACKUP_DIR}; logs under ${LOG_DIR}"
}

main "$@"
