#!/usr/bin/env bash
# install.sh — Single-command Ubuntu Mirror Server installer
# Default: sudo ./install.sh  → validate, install, configure, start nginx, start sync
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"
# shellcheck source=lib/state.sh
source "${UM_PROJECT_ROOT}/lib/state.sh"

UM_DRY_RUN=0
UM_FORCE=0
UM_NO_SYNC=0
UM_MINIMAL=0
UM_VERBOSE=0
UM_FORMAT_DEVICE=0
UM_CONFIG_ARG=""
UM_CHANGES=0
# Sync attach mode: auto | foreground | background
# auto = attach dashboard when TTY, else background
UM_SYNC_MODE="auto"

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Install and start an Ubuntu Mirror Server in one command.

Options:
  --help              Show this help
  --config PATH       Use a custom mirror.conf
  --dry-run           Show planned actions without changing the system
  --no-sync           Install and validate but do not start initial sync
  --foreground        Start sync and keep the live dashboard attached
  --background        Start sync and return to the shell immediately
  --minimal           Use minimal mirror components (main restricted)
  --verbose           Show detailed validation and command output
  --force             Replace changed managed configuration after backup

Examples:
  sudo ./install.sh
  sudo ./install.sh --background
  sudo ./install.sh --foreground
  sudo ./install.sh --dry-run
  sudo ./install.sh --no-sync
  sudo ./install.sh --minimal
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
      --no-sync) UM_NO_SYNC=1; shift ;;
      --foreground) UM_SYNC_MODE="foreground"; shift ;;
      --background) UM_SYNC_MODE="background"; shift ;;
      --minimal) UM_MINIMAL=1; shift ;;
      --verbose) UM_VERBOSE=1; shift ;;
      --force) UM_FORCE=1; shift ;;
      # Hidden expert option — not advertised in Quick Start
      --format-device) UM_FORMAT_DEVICE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      # Compatibility aliases (deprecated, still accepted quietly)
      --non-interactive) UM_SYNC_MODE="background"; shift ;;
      --start-sync) UM_NO_SYNC=0; shift ;;
      --validate) UM_VERBOSE=1; shift ;;
      --skip-packages) shift ;; # ignored; dry-run handles missing packages
      *) um_die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

vlog() {
  if [[ "$UM_VERBOSE" == "1" ]] || [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "$*"
  fi
}

phase() {
  printf '\n==> %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Phase 1: Root and environment validation
# ---------------------------------------------------------------------------
phase1_preflight() {
  phase "Phase 1: Environment validation"

  if [[ "$UM_DRY_RUN" != "1" ]]; then
    um_require_root
  else
    um_dry "Would require root privileges"
  fi

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      um_ok "OS: ${PRETTY_NAME}"
    else
      um_warn "Non-Ubuntu host: ${PRETTY_NAME:-unknown} (continuing)"
    fi
  else
    um_die "Cannot detect OS (/etc/os-release missing)"
  fi

  if ! um_command_exists apt-get; then
    um_die "apt-get not available"
  fi
  um_ok "apt-get available"

  if ! um_command_exists systemctl; then
    um_die "systemd/systemctl not available"
  fi
  um_ok "systemd available"

  # Internet (best-effort)
  if curl -sS --max-time 5 -I http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1 \
    || curl -sS --max-time 5 -I https://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
    um_ok "Internet connectivity"
  else
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "SKIPPED: internet check (runtime)"
    else
      um_warn "Could not reach archive.ubuntu.com — sync may fail"
    fi
  fi

  # Base path / mount — do NOT require DATA_DEVICE when already mounted
  if [[ ! -d "$BASE_PATH" ]]; then
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would create BASE_PATH $BASE_PATH"
    else
      mkdir -p "$BASE_PATH"
    fi
  fi

  if [[ -d "$BASE_PATH" ]] && um_path_mounted "$BASE_PATH"; then
    local src
    src="$(findmnt -n -o SOURCE -T "$BASE_PATH" 2>/dev/null || echo unknown)"
    um_ok "Mirror path mounted: $BASE_PATH <- $src"
  elif [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "SKIPPED: mount check for $BASE_PATH (not present in dry-run host)"
  else
    um_warn "BASE_PATH exists but is not a separate mount — ensure enough disk space"
  fi

  if [[ -d "$BASE_PATH" ]]; then
    local avail_kib avail_gib pct
    avail_kib="$(df -Pk "$BASE_PATH" 2>/dev/null | awk 'NR==2 {print $4}')"
    avail_gib=$(( ${avail_kib:-0} / 1024 / 1024 ))
    pct="$(um_disk_usage_percent "$BASE_PATH" || echo 0)"
    if [[ "$avail_gib" -lt "${MIN_FREE_GIB}" ]] && ! um_initial_sync_complete; then
      um_warn "Free space ${avail_gib} GiB < recommended ${MIN_FREE_GIB} GiB for full sync"
    else
      um_ok "Disk space: ${avail_gib} GiB free (${pct}% used)"
    fi
    if [[ ! -w "$BASE_PATH" ]] && [[ "$UM_DRY_RUN" != "1" ]]; then
      um_die "No write permission on $BASE_PATH"
    fi
  fi

  # Port conflict (informational)
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn "( sport = :${MIRROR_PORT} )" 2>/dev/null | grep -q LISTEN; then
      if systemctl is-active --quiet nginx 2>/dev/null; then
        vlog "Port ${MIRROR_PORT} already used by nginx (ok)"
      else
        um_warn "Port ${MIRROR_PORT} is in use — nginx may fail to bind"
      fi
    fi
  fi

  um_ok "Configuration loaded: $UM_CONFIG_PATH (mode=${MIRROR_MODE})"
}

# Optional mount only when DATA_DEVICE set and not already mounted — never format by default
maybe_mount_data_device() {
  if [[ -z "${DATA_DEVICE}" ]]; then
    return 0
  fi
  if findmnt -n -S "$DATA_DEVICE" >/dev/null 2>&1; then
    return 0
  fi
  if um_path_mounted "$BASE_PATH"; then
    vlog "BASE_PATH already mounted; ignoring DATA_DEVICE=$DATA_DEVICE"
    return 0
  fi
  if [[ "$UM_FORMAT_DEVICE" == "1" ]]; then
    [[ "$UM_FORCE" == "1" ]] || um_die "--format-device requires --force"
    um_warn "FORMATTING $DATA_DEVICE — destructive"
    um_confirm "Confirm mkfs on $DATA_DEVICE?" || um_die "Aborted"
    um_run "mkfs.${DATA_FSTYPE}" -F "$DATA_DEVICE"
  fi
  um_run mkdir -p "$BASE_PATH"
  um_run mount "$DATA_DEVICE" "$BASE_PATH"
  local uuid
  uuid="$(blkid -s UUID -o value "$DATA_DEVICE" 2>/dev/null || true)"
  if [[ -n "$uuid" ]] && ! grep -q "UUID=$uuid" /etc/fstab 2>/dev/null; then
    if [[ -f /etc/fstab ]]; then
      um_backup_file /etc/fstab >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would append fstab for UUID=$uuid"
    else
      printf 'UUID=%s %s %s %s 0 2\n' "$uuid" "$BASE_PATH" "$DATA_FSTYPE" "$DATA_MOUNT_OPTS" >>/etc/fstab
    fi
  fi
}

# ---------------------------------------------------------------------------
# Phase 2: Packages
# ---------------------------------------------------------------------------
phase2_packages() {
  phase "Phase 2: Install required packages"
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would install apt-mirror nginx curl"
    um_dry "SKIPPED: requires installed package (apt-mirror, nginx)"
    return 0
  fi

  local need=0
  um_command_exists apt-mirror || need=1
  um_command_exists nginx || need=1
  um_command_exists curl || need=1

  if [[ "$need" -eq 0 ]]; then
    um_ok "Packages already installed (apt-mirror, nginx, curl)"
    return 0
  fi

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-mirror nginx curl
  um_command_exists apt-mirror || um_die "apt-mirror not found after install"
  um_command_exists nginx || um_die "nginx not found after install"
  um_ok "Packages installed"
  UM_CHANGES=1
}

# ---------------------------------------------------------------------------
# Phase 3: Configuration
# ---------------------------------------------------------------------------
phase3_config() {
  phase "Phase 3: Generate and install configuration"

  um_run mkdir -p "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH"
  um_run mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$INSTALL_CONF_DIR" "$INSTALL_LIB_DIR" "$(um_state_root)"
  um_run mkdir -p "$(dirname "$NGINX_ACCESS_LOG")"
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    chown -R root:root "$BASE_PATH" 2>/dev/null || true
    chmod -R 755 "$BASE_PATH" 2>/dev/null || true
  fi

  local tmp
  tmp="$(mktemp)"
  um_generate_mirror_list >"$tmp"
  if [[ -f /etc/apt/mirror.list ]] && cmp -s "$tmp" /etc/apt/mirror.list; then
    vlog "Unchanged: /etc/apt/mirror.list"
    rm -f "$tmp"
  else
    if [[ -f /etc/apt/mirror.list ]]; then
      um_backup_file /etc/apt/mirror.list >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would write /etc/apt/mirror.list"
      rm -f "$tmp"
    else
      install -m 0644 "$tmp" /etc/apt/mirror.list
      rm -f "$tmp"
      um_ok "Installed /etc/apt/mirror.list"
      UM_CHANGES=1
    fi
  fi

  # nginx site
  local site_avail="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  local site_en="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  local ngx_tmp
  ngx_tmp="$(mktemp)"
  um_generate_nginx_conf >"$ngx_tmp"
  UM_NGINX_TMP="$ngx_tmp"

  if [[ -f "$site_avail" ]] && cmp -s "$ngx_tmp" "$site_avail"; then
    vlog "Unchanged: $site_avail"
  else
    if [[ -f "$site_avail" ]]; then
      um_backup_file "$site_avail" >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would configure nginx ($site_avail)"
    else
      install -m 0644 "$ngx_tmp" "$site_avail"
      um_ok "Installed $site_avail"
      UM_CHANGES=1
    fi
  fi

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would enable nginx site symlink"
  else
    ln -sfn "$site_avail" "$site_en"
    if [[ "${NGINX_DISABLE_DEFAULT}" == "true" ]] && [[ -e /etc/nginx/sites-enabled/default ]]; then
      rm -f /etc/nginx/sites-enabled/default
      um_ok "Disabled nginx default site"
      UM_CHANGES=1
    fi
  fi

  # systemd units (timer installed but NOT enabled until finalize)
  local svc_tmp timer_tmp
  svc_tmp="$(mktemp)"
  timer_tmp="$(mktemp)"
  um_generate_systemd_service >"$svc_tmp"
  um_generate_systemd_timer >"$timer_tmp"
  UM_SVC_TMP="$svc_tmp"
  UM_TIMER_TMP="$timer_tmp"

  if [[ -f /etc/systemd/system/apt-mirror.service ]] && cmp -s "$svc_tmp" /etc/systemd/system/apt-mirror.service; then
    vlog "Unchanged: apt-mirror.service"
  else
    if [[ -f /etc/systemd/system/apt-mirror.service ]]; then
      um_backup_file /etc/systemd/system/apt-mirror.service >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would install systemd units"
    else
      install -m 0644 "$svc_tmp" /etc/systemd/system/apt-mirror.service
      UM_CHANGES=1
    fi
  fi
  if [[ -f /etc/systemd/system/apt-mirror.timer ]] && cmp -s "$timer_tmp" /etc/systemd/system/apt-mirror.timer; then
    vlog "Unchanged: apt-mirror.timer"
  else
    if [[ -f /etc/systemd/system/apt-mirror.timer ]]; then
      um_backup_file /etc/systemd/system/apt-mirror.timer >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" != "1" ]]; then
      install -m 0644 "$timer_tmp" /etc/systemd/system/apt-mirror.timer
      UM_CHANGES=1
    fi
  fi

  # Management tools (without .sh suffixes for status/recovery)
  install_mgmt_tools
}

install_mgmt_tools() {
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would install mirrorctl, mirror-dashboard, mirror-status, mirror-recovery"
    return 0
  fi

  um_install_file "${UM_PROJECT_ROOT}/scripts/mirrorctl" "${INSTALL_BIN_DIR}/mirrorctl" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh" "${INSTALL_BIN_DIR}/mirror-dashboard" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/mirror-status.sh" "${INSTALL_BIN_DIR}/mirror-status" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/mirror-recovery.sh" "${INSTALL_BIN_DIR}/mirror-recovery" 0755
  ln -sfn "${INSTALL_BIN_DIR}/mirror-status" "${INSTALL_BIN_DIR}/mirror-status.sh"
  ln -sfn "${INSTALL_BIN_DIR}/mirror-recovery" "${INSTALL_BIN_DIR}/mirror-recovery.sh"
  ln -sfn "${INSTALL_BIN_DIR}/mirror-dashboard" "${INSTALL_BIN_DIR}/mirror-dashboard.sh"

  um_install_file "${UM_PROJECT_ROOT}/scripts/run-apt-mirror.sh" "${INSTALL_LIB_DIR}/run-apt-mirror.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/validate.sh" "${INSTALL_BIN_DIR}/validate.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/client/client-setup.sh" "${INSTALL_BIN_DIR}/client-setup.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/client/client-validate.sh" "${INSTALL_BIN_DIR}/client-validate.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/lib/common.sh" "${INSTALL_LIB_DIR}/common.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/config.sh" "${INSTALL_LIB_DIR}/config.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/state.sh" "${INSTALL_LIB_DIR}/state.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/progress.sh" "${INSTALL_LIB_DIR}/progress.sh" 0644

  if [[ -f "${INSTALL_CONF_DIR}/mirror.conf" ]] && [[ "$UM_FORCE" != "1" ]]; then
    vlog "Keeping existing ${INSTALL_CONF_DIR}/mirror.conf"
  else
    um_install_file "${UM_CONFIG_PATH}" "${INSTALL_CONF_DIR}/mirror.conf" 0644
  fi
  ln -sfn "${INSTALL_BIN_DIR}/mirrorctl" /usr/local/sbin/mirrorctl 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Phase 4: Validate generated configuration
# ---------------------------------------------------------------------------
phase4_validate() {
  phase "Phase 4: Validate configuration"

  # bash -n on installed/generated scripts
  local s
  for s in "${UM_PROJECT_ROOT}/install.sh" \
           "${UM_PROJECT_ROOT}/scripts/mirrorctl" \
           "${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh" \
           "${UM_PROJECT_ROOT}/scripts/run-apt-mirror.sh"; do
    bash -n "$s"
  done
  um_ok "bash -n syntax ok"

  # nginx -t
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    if um_command_exists nginx && [[ -n "${UM_NGINX_TMP:-}" ]]; then
      local wrap
      wrap="$(mktemp -d)"
      cat >"$wrap/nginx.conf" <<EOF
events {}
http {
  include ${UM_NGINX_TMP};
}
EOF
      if nginx -t -c "$wrap/nginx.conf" >/dev/null 2>&1; then
        um_ok "nginx syntax (temp) valid"
      else
        um_dry "SKIPPED: full nginx -t (minimal wrapper limits)"
      fi
      rm -rf "$wrap"
    else
      um_dry "SKIPPED: requires installed package (nginx -t)"
    fi
  else
    if ! nginx -t; then
      um_error "nginx -t failed — aborting before sync"
      return 1
    fi
    um_ok "nginx -t passed"
  fi

  # systemd-analyze verify
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    if command -v systemd-analyze >/dev/null 2>&1 && [[ -n "${UM_SVC_TMP:-}" ]]; then
      if systemd-analyze verify "${UM_SVC_TMP}" "${UM_TIMER_TMP}" 2>/dev/null; then
        um_ok "systemd units verify ok"
      else
        um_dry "SKIPPED: systemd-analyze verify (environment limits)"
      fi
    else
      um_dry "SKIPPED: requires installed package (systemd-analyze)"
    fi
  else
    if command -v systemd-analyze >/dev/null 2>&1; then
      if ! systemd-analyze verify /etc/systemd/system/apt-mirror.service /etc/systemd/system/apt-mirror.timer 2>/dev/null; then
        um_warn "systemd-analyze verify reported issues (continuing if units load)"
      else
        um_ok "systemd units verify ok"
      fi
    fi
    if ! systemctl cat apt-mirror.service >/dev/null 2>&1; then
      um_error "apt-mirror.service failed to load"
      return 1
    fi
  fi

  # Internal install-mode validation (sync pending is OK)
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "SKIPPED: runtime install validation against live services"
    return 0
  fi

  if [[ -x "${UM_PROJECT_ROOT}/validate.sh" ]]; then
    set +e
    "${UM_PROJECT_ROOT}/validate.sh" --config "${INSTALL_CONF_DIR}/mirror.conf" --mode install --quiet
    local vrc=$?
    set -e
    if [[ "$vrc" -ge 2 ]]; then
      um_error "Installation validation failed (critical)"
      if [[ "$UM_VERBOSE" == "1" ]]; then
        "${UM_PROJECT_ROOT}/validate.sh" --config "${INSTALL_CONF_DIR}/mirror.conf" --mode install || true
      fi
      return 1
    fi
    um_ok "Installation validation passed (sync pending is OK)"
  fi
}

# ---------------------------------------------------------------------------
# Phase 5: Start services (timer stays disabled)
# ---------------------------------------------------------------------------
phase5_services() {
  phase "Phase 5: Start services"

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would reload systemd"
    um_dry "Would enable and restart nginx"
    um_dry "Would leave apt-mirror.timer disabled until initial sync completes"
    return 0
  fi

  systemctl daemon-reload
  systemctl enable nginx >/dev/null
  systemctl restart nginx
  if ! systemctl is-active --quiet nginx; then
    um_die "nginx failed to start"
  fi
  um_ok "nginx running on port ${MIRROR_PORT}"

  # Explicitly keep timer disabled until finalize
  systemctl disable apt-mirror.timer >/dev/null 2>&1 || true
  systemctl stop apt-mirror.timer >/dev/null 2>&1 || true
  um_ok "apt-mirror.timer installed but disabled until initial sync completes"
  um_mark_state "installed"
}

# ---------------------------------------------------------------------------
# Phase 6: Start initial sync (non-blocking) + optional live dashboard
# ---------------------------------------------------------------------------
um_resolve_sync_attach_mode() {
  # Prints: foreground | background
  case "$UM_SYNC_MODE" in
    foreground) printf 'foreground\n' ;;
    background) printf 'background\n' ;;
    *)
      if [[ -t 1 ]]; then
        printf 'foreground\n'
      else
        printf 'background\n'
      fi
      ;;
  esac
}

um_print_background_sync_hints() {
  cat <<EOF

Initial synchronization started in background.

Attach dashboard:
  sudo mirrorctl watch

Check status:
  sudo mirrorctl status

Follow raw logs:
  sudo mirrorctl logs
EOF
}

um_attach_dashboard() {
  local dash
  dash="${INSTALL_BIN_DIR}/mirror-dashboard"
  [[ -x "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  if [[ ! -x "$dash" ]]; then
    um_warn "mirror-dashboard not found — use: sudo mirrorctl status"
    return 0
  fi
  printf '\nAttaching live dashboard...\n'
  printf 'Press B or Ctrl+C to detach. Sync will continue.\n\n'
  # Dashboard owns Ctrl+C (detach only); do not stop apt-mirror.service
  set +e
  "$dash" --config "${INSTALL_CONF_DIR}/mirror.conf"
  set -e
}

phase6_sync() {
  phase "Phase 6: Initial synchronization"

  if [[ "$UM_NO_SYNC" == "1" ]]; then
    um_info "Skipping initial sync (--no-sync)"
    return 0
  fi

  if um_initial_sync_complete || um_has_marker "ready"; then
    um_ok "Initial sync already completed — not restarting"
    return 0
  fi

  local attach_mode already_running=0
  attach_mode="$(um_resolve_sync_attach_mode)"

  if um_is_sync_running; then
    um_ok "Initial synchronization is already running"
    already_running=1
  fi

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would start initial synchronization (systemctl start --no-block)"
    um_dry "Would attach mode: ${attach_mode}"
    return 0
  fi

  if [[ "$already_running" -eq 0 ]]; then
    um_clear_marker "sync-failed"
    # Non-blocking: never freeze the installer on a multi-hour sync
    systemctl start --no-block apt-mirror.service

    local _i ok=0
    for _i in 1 2 3 4 5; do
      sleep 1
      if um_is_sync_running \
        || systemctl is-active --quiet apt-mirror.service 2>/dev/null \
        || systemctl show -p ActiveState --value apt-mirror.service 2>/dev/null | grep -qE 'active|activating' \
        || [[ -f "$APT_MIRROR_LOG" ]]; then
        ok=1
        break
      fi
    done

    if [[ "$ok" -eq 1 ]]; then
      um_mark_state "sync-started"
      um_ok "apt-mirror.service starting"
      um_ok "Raw log: ${APT_MIRROR_LOG}"
      um_ok "Dashboard: sudo mirrorctl watch"
    else
      local st
      st="$(systemctl show -p Result --value apt-mirror.service 2>/dev/null || true)"
      if [[ "$st" == "success" ]]; then
        um_ok "apt-mirror.service completed quickly (check logs)"
      else
        um_warn "Could not confirm sync process — check: journalctl -u apt-mirror.service"
        um_warn "Then: sudo mirrorctl status"
        return 0
      fi
    fi
  fi

  # Non-interactive / CI: never emit TUI controls into redirected logs
  if [[ "$attach_mode" == "background" ]] || [[ ! -t 1 ]]; then
    if [[ ! -t 1 ]] && [[ "$UM_SYNC_MODE" == "auto" ]]; then
      printf '\nNo interactive terminal detected.\n'
      printf 'Initial synchronization started in background.\n'
      printf 'Use: sudo mirrorctl watch\n'
    else
      um_print_background_sync_hints
    fi
    return 0
  fi

  um_attach_dashboard
}

# ---------------------------------------------------------------------------
# Phase 7: Summary / idempotent short path
# ---------------------------------------------------------------------------
phase7_summary() {
  local state
  state="$(um_detect_lifecycle_state 2>/dev/null || echo INSTALLED)"

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    printf '\nDry-run completed successfully.\n'
    return 0
  fi

  if [[ "$UM_CHANGES" -eq 0 ]] && um_is_installed; then
    printf '\nUbuntu Mirror Server is already installed.\n'
    printf 'Configuration is current.\n'
    case "$state" in
      SYNC_RUNNING) printf 'Initial synchronization is running.\n' ;;
      READY) printf 'Mirror is ready.\n' ;;
      SYNC_COMPLETE) printf 'Initial sync complete — run: sudo mirrorctl finalize\n' ;;
      *) printf 'State: %s\n' "$state" ;;
    esac
    printf 'No changes required.\n'
  fi

  cat <<EOF

Ubuntu Mirror Server installation completed.

Mirror path:
  ${BASE_PATH}

Mirror URL:
  ${MIRROR_URL}/ubuntu

Initial synchronization:
  $( [[ "$UM_NO_SYNC" == "1" ]] && echo "Not started (--no-sync)" || echo "Started via systemd (continues if dashboard detached)" )

Live dashboard:
  sudo mirrorctl watch

Check status:
  sudo mirrorctl status

Follow raw logs:
  sudo mirrorctl logs

Check disk:
  df -h ${BASE_PATH}

Finalization runs automatically when the first sync finishes.
Manual fallback: sudo mirrorctl finalize

EOF
}

cleanup_temps() {
  rm -f "${UM_NGINX_TMP:-}" "${UM_SVC_TMP:-}" "${UM_TIMER_TMP:-}" 2>/dev/null || true
}

main() {
  parse_args "$@"
  um_setup_trap
  um_register_cleanup cleanup_temps

  um_load_config "$UM_CONFIG_ARG"
  if [[ "$UM_MINIMAL" == "1" ]]; then
    MIRROR_MODE="minimal"
    MIRROR_COMPONENTS="main restricted"
  fi

  um_set_log_file "${LOG_DIR}/install.log"
  um_ensure_log_dir
  UM_BACKUP_SESSION=""
  um_backup_session_dir >/dev/null

  # Idempotent fast path (real run only): already installed, config current, sync running
  if [[ "$UM_DRY_RUN" != "1" ]] && [[ "$UM_FORCE" != "1" ]] && um_is_installed; then
    local gen
    gen="$(mktemp)"; um_generate_mirror_list >"$gen"
    if cmp -s "$gen" /etc/apt/mirror.list 2>/dev/null; then
      if um_is_sync_running || um_has_marker "ready" || um_initial_sync_complete; then
        rm -f "$gen"
        phase7_summary
        exit 0
      fi
    fi
    rm -f "$gen"
  fi

  phase1_preflight
  maybe_mount_data_device
  phase2_packages
  phase3_config
  if ! phase4_validate; then
    um_die "Installation stopped due to critical validation failure" 2
  fi
  phase5_services
  phase6_sync
  phase7_summary
}

main "$@"
