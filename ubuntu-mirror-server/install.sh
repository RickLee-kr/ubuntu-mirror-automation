#!/usr/bin/env bash
# install.sh — Idempotent Ubuntu Mirror Server installer
# Based on: Ubuntu Mirror Server - Complete Setup Guide
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"

UM_DRY_RUN=0
UM_FORCE=0
UM_NON_INTERACTIVE=0
UM_START_SYNC=0
UM_VALIDATE=0
UM_FORMAT_DEVICE=0
UM_CONFIG_ARG=""
UM_SKIP_PACKAGES=0

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Options:
  --config PATH         Path to mirror.conf (default: ./mirror.conf)
  --dry-run             Print actions without changing the system
  --force               Allow overwriting managed configs / enable timer early
  --non-interactive     Do not prompt; assume yes for safe actions
  --start-sync          Start initial apt-mirror sync in background after install
  --validate            Run validate.sh after successful install
  --format-device       DANGEROUS: mkfs DATA_DEVICE before mount (requires DATA_DEVICE)
  --skip-packages       Skip apt-get install (templates/config only)
  -h, --help            Show this help

Examples:
  sudo ./install.sh
  sudo ./install.sh --dry-run
  sudo ./install.sh --config mirror.conf --non-interactive --validate
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        UM_CONFIG_ARG="${2:-}"
        [[ -n "$UM_CONFIG_ARG" ]] || um_die "--config requires a path"
        shift 2
        ;;
      --dry-run) UM_DRY_RUN=1; shift ;;
      --force) UM_FORCE=1; shift ;;
      --non-interactive) UM_NON_INTERACTIVE=1; shift ;;
      --start-sync) UM_START_SYNC=1; shift ;;
      --validate) UM_VALIDATE=1; shift ;;
      --format-device) UM_FORMAT_DEVICE=1; shift ;;
      --skip-packages) UM_SKIP_PACKAGES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

install_packages() {
  if [[ "$UM_SKIP_PACKAGES" == "1" ]]; then
    um_info "Skipping package installation (--skip-packages)"
    return 0
  fi
  um_info "Updating package lists"
  um_run apt-get update -y
  um_info "Installing apt-mirror and nginx"
  um_run apt-get install -y apt-mirror nginx curl
  if um_command_exists apt-mirror; then
    um_ok "apt-mirror present: $(command -v apt-mirror)"
  else
    um_die "apt-mirror not found after install"
  fi
  if um_command_exists nginx; then
    um_ok "nginx present: $(command -v nginx)"
  else
    um_die "nginx not found after install"
  fi
}

maybe_format_and_mount() {
  if [[ -z "${DATA_DEVICE}" ]]; then
    um_info "DATA_DEVICE empty — skipping mount/format (using existing BASE_PATH)"
    return 0
  fi

  if [[ ! -b "$DATA_DEVICE" ]]; then
    um_die "DATA_DEVICE is not a block device: $DATA_DEVICE"
  fi

  if findmnt -n -S "$DATA_DEVICE" >/dev/null 2>&1; then
    local current
    current="$(findmnt -n -o TARGET -S "$DATA_DEVICE" | head -1)"
    um_info "Device $DATA_DEVICE already mounted at $current"
    if [[ "$current" != "$BASE_PATH" ]]; then
      um_warn "Mounted path differs from BASE_PATH ($BASE_PATH)"
    fi
    return 0
  fi

  if [[ "$UM_FORMAT_DEVICE" == "1" ]]; then
    if [[ "$UM_FORCE" != "1" ]]; then
      um_die "--format-device also requires --force"
    fi
    um_warn "FORMATTING $DATA_DEVICE as ${DATA_FSTYPE} — ALL DATA WILL BE LOST"
    if [[ "$UM_NON_INTERACTIVE" != "1" ]]; then
      um_confirm "Type y to proceed with mkfs on $DATA_DEVICE" || um_die "Aborted"
    fi
    um_run "mkfs.${DATA_FSTYPE}" -F "$DATA_DEVICE"
  fi

  um_run mkdir -p "$BASE_PATH"
  um_run mount "$DATA_DEVICE" "$BASE_PATH"
  um_ok "Mounted $DATA_DEVICE -> $BASE_PATH"

  # Persist in fstab if not already present
  local uuid
  uuid="$(blkid -s UUID -o value "$DATA_DEVICE" 2>/dev/null || true)"
  if [[ -n "$uuid" ]]; then
    if ! grep -q "UUID=$uuid" /etc/fstab 2>/dev/null; then
      um_backup_file /etc/fstab >/dev/null || true
      local line="UUID=$uuid $BASE_PATH $DATA_FSTYPE $DATA_MOUNT_OPTS 0 2"
      if [[ "$UM_DRY_RUN" == "1" ]]; then
        um_info "DRY-RUN: append fstab: $line"
      else
        printf '%s\n' "$line" >>/etc/fstab
        um_ok "Added fstab entry for $BASE_PATH"
      fi
    fi
  fi
}

ensure_directories() {
  um_info "Ensuring mirror directories under $BASE_PATH"
  um_run mkdir -p "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH"
  um_run mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$INSTALL_CONF_DIR" "$INSTALL_LIB_DIR"
  um_run mkdir -p "$(dirname "$NGINX_ACCESS_LOG")"
  um_run chown -R root:root "$BASE_PATH"
  um_run chmod -R 755 "$BASE_PATH"
}

install_mirror_list() {
  local tmp
  tmp="$(mktemp)"
  um_generate_mirror_list >"$tmp"
  if [[ -f /etc/apt/mirror.list ]]; then
    if cmp -s "$tmp" /etc/apt/mirror.list; then
      um_info "Unchanged: /etc/apt/mirror.list"
      rm -f "$tmp"
      return 0
    fi
    um_backup_file /etc/apt/mirror.list >/dev/null || true
  fi
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "DRY-RUN: write /etc/apt/mirror.list"
    rm -f "$tmp"
    return 0
  fi
  install -m 0644 "$tmp" /etc/apt/mirror.list
  rm -f "$tmp"
  um_ok "Installed /etc/apt/mirror.list"
}

install_nginx_site() {
  local site_avail="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  local site_en="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  local tmp
  tmp="$(mktemp)"
  um_generate_nginx_conf >"$tmp"

  if [[ -f "$site_avail" ]]; then
    if cmp -s "$tmp" "$site_avail"; then
      um_info "Unchanged: $site_avail"
    else
      um_backup_file "$site_avail" >/dev/null || true
      if [[ "$UM_DRY_RUN" == "1" ]]; then
        um_info "DRY-RUN: write $site_avail"
      else
        install -m 0644 "$tmp" "$site_avail"
        um_ok "Updated $site_avail"
      fi
    fi
  else
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_info "DRY-RUN: write $site_avail"
    else
      install -m 0644 "$tmp" "$site_avail"
      um_ok "Created $site_avail"
    fi
  fi
  rm -f "$tmp"

  if [[ "$UM_DRY_RUN" != "1" ]]; then
    ln -sfn "$site_avail" "$site_en"
  else
    um_info "DRY-RUN: ln -sfn $site_avail $site_en"
  fi

  if [[ "${NGINX_DISABLE_DEFAULT}" == "true" ]]; then
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
      if [[ "$UM_FORCE" == "1" ]] || [[ "$UM_NON_INTERACTIVE" == "1" ]]; then
        um_run rm -f /etc/nginx/sites-enabled/default
        um_ok "Disabled nginx default site"
      else
        if um_confirm "Disable nginx default site?"; then
          um_run rm -f /etc/nginx/sites-enabled/default
        else
          um_warn "Leaving default site enabled (may conflict on port 80)"
        fi
      fi
    fi
  fi

  if um_command_exists nginx; then
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_info "DRY-RUN: nginx -t && systemctl reload/restart nginx"
    else
      nginx -t
      systemctl enable nginx
      systemctl restart nginx
      um_ok "nginx configuration applied"
    fi
  fi
}

install_systemd_units() {
  local svc_tmp timer_tmp
  svc_tmp="$(mktemp)"
  timer_tmp="$(mktemp)"
  um_generate_systemd_service >"$svc_tmp"
  um_generate_systemd_timer >"$timer_tmp"

  if [[ -f /etc/systemd/system/apt-mirror.service ]]; then
    if ! cmp -s "$svc_tmp" /etc/systemd/system/apt-mirror.service; then
      um_backup_file /etc/systemd/system/apt-mirror.service >/dev/null || true
    fi
  fi
  if [[ -f /etc/systemd/system/apt-mirror.timer ]]; then
    if ! cmp -s "$timer_tmp" /etc/systemd/system/apt-mirror.timer; then
      um_backup_file /etc/systemd/system/apt-mirror.timer >/dev/null || true
    fi
  fi

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "DRY-RUN: install systemd units"
  else
    install -m 0644 "$svc_tmp" /etc/systemd/system/apt-mirror.service
    install -m 0644 "$timer_tmp" /etc/systemd/system/apt-mirror.timer
    systemctl daemon-reload
    systemctl enable apt-mirror.timer
    um_ok "systemd apt-mirror.service/timer installed and enabled"
  fi
  rm -f "$svc_tmp" "$timer_tmp"
}

install_project_files() {
  um_info "Installing management tools"
  local files=(
    "scripts/mirrorctl"
    "scripts/mirror-status.sh"
    "scripts/mirror-recovery.sh"
    "validate.sh"
  )
  local f
  for f in "${files[@]}"; do
    um_install_file "${UM_PROJECT_ROOT}/${f}" "${INSTALL_BIN_DIR}/$(basename "$f")" 0755
  done

  # Also install client helpers for packaging onto clients
  um_install_file "${UM_PROJECT_ROOT}/client/client-setup.sh" \
    "${INSTALL_BIN_DIR}/client-setup.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/client/client-validate.sh" \
    "${INSTALL_BIN_DIR}/client-validate.sh" 0755

  # Libraries + config
  um_install_file "${UM_PROJECT_ROOT}/lib/common.sh" "${INSTALL_LIB_DIR}/common.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/config.sh" "${INSTALL_LIB_DIR}/config.sh" 0644

  # Preserve operator edits to installed mirror.conf unless --force
  if [[ -f "${INSTALL_CONF_DIR}/mirror.conf" ]] && [[ "$UM_FORCE" != "1" ]]; then
    um_info "Keeping existing ${INSTALL_CONF_DIR}/mirror.conf (use --force to overwrite)"
  else
    um_install_file "${UM_CONFIG_PATH}" "${INSTALL_CONF_DIR}/mirror.conf" 0644
  fi

  # Symlink convenience: mirrorctl without path
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    ln -sfn "${INSTALL_BIN_DIR}/mirrorctl" /usr/local/sbin/mirrorctl 2>/dev/null || true
  fi
}

start_initial_sync() {
  if pgrep -f '/usr/bin/apt-mirror|apt-mirror$' >/dev/null 2>&1; then
    um_warn "apt-mirror already running — not starting another sync"
    return 0
  fi
  um_info "Starting initial apt-mirror sync in background"
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "DRY-RUN: nohup apt-mirror > $APT_MIRROR_INITIAL_LOG"
    return 0
  fi
  touch "$APT_MIRROR_INITIAL_LOG"
  nohup apt-mirror >>"$APT_MIRROR_INITIAL_LOG" 2>&1 &
  um_ok "Initial sync started (PID $!). Log: $APT_MIRROR_INITIAL_LOG"
  um_info "Monitor with: mirrorctl status  OR  tail -f $APT_MIRROR_INITIAL_LOG"
}

post_install_notes() {
  cat <<EOF

${UM_C_BOLD}Ubuntu Mirror Server install complete${UM_C_RESET}

  Config:     ${UM_CONFIG_PATH}
  Base path:  ${BASE_PATH}
  Mode:       ${MIRROR_MODE} (${MIRROR_COMPONENTS})
  Versions:   ${UBUNTU_VERSIONS}
  Mirror URL: ${MIRROR_URL}/ubuntu
  Mirror IP:  ${MIRROR_IP}

Next steps (from Setup Guide):
  1. Start sync:   sudo mirrorctl sync start
     (or re-run:   sudo ./install.sh --start-sync)
  2. Monitor:      sudo mirrorctl status
  3. After sync:   sudo mirrorctl cleanup && sudo mirrorctl timer start
  4. Validate:     sudo ./validate.sh
  5. Clients:      sudo ./client/client-setup.sh --mirror-url ${MIRROR_URL}

EOF
}

main() {
  parse_args "$@"
  um_setup_trap

  if [[ "$UM_DRY_RUN" != "1" ]]; then
    um_require_root
  fi

  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/install.log"
  um_ensure_log_dir
  um_info "=== Ubuntu Mirror Server install begin (dry_run=$UM_DRY_RUN) ==="

  if [[ "$UM_FORMAT_DEVICE" == "1" ]] && [[ -z "$DATA_DEVICE" ]]; then
    um_die "--format-device requires DATA_DEVICE in mirror.conf"
  fi

  maybe_format_and_mount
  install_packages
  ensure_directories
  install_mirror_list
  install_nginx_site
  install_systemd_units
  install_project_files

  if [[ "$UM_START_SYNC" == "1" ]]; then
    start_initial_sync
  fi

  if [[ "$UM_VALIDATE" == "1" ]]; then
    um_info "Running post-install validation"
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_info "DRY-RUN: validate.sh skipped"
    else
      "${UM_PROJECT_ROOT}/validate.sh" --config "${INSTALL_CONF_DIR}/mirror.conf" || true
    fi
  fi

  post_install_notes
  um_ok "=== Install finished ==="
}

main "$@"
