#!/usr/bin/env bash
# shellcheck shell=bash
# Interactive installer menu (SSH-friendly TUI) for Ubuntu Mirror Server.

# shellcheck disable=SC2317
if [[ -n "${UM_INSTALL_MENU_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_INSTALL_MENU_LOADED=1

um_menu_is_tty() {
  [[ -t 0 ]] && [[ -t 1 ]]
}

# Returns 0 when the interactive menu should be shown.
um_should_show_install_menu() {
  if [[ "${UM_FORCE_MENU:-0}" == "1" ]]; then
    um_menu_is_tty || return 1
    return 0
  fi
  if [[ "${UM_NO_MENU:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    return 1
  fi
  # Explicit CLI install intent → skip menu
  if [[ "${UM_FULL:-0}" == "1" ]] || [[ "${UM_MINIMAL:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_NO_SYNC:-0}" == "1" ]]; then
    return 1
  fi
  if [[ "${UM_SYNC_MODE:-auto}" != "auto" ]]; then
    return 1
  fi
  um_menu_is_tty
}

um_menu_clear() {
  if um_menu_is_tty; then
    clear 2>/dev/null || printf '\033[2J\033[H'
  fi
}

um_menu_existing_data_gib() {
  local root="${BASE_PATH:-/var/spool/apt-mirror}"
  if [[ -d "$root" ]]; then
    du -sb "$root" 2>/dev/null | awk '{printf "%.1f", $1/1024/1024/1024}'
  else
    printf '0'
  fi
}

um_menu_sync_label() {
  if um_is_sync_running 2>/dev/null; then
    printf 'RUNNING'
  elif um_has_marker "ready" 2>/dev/null; then
    printf 'READY'
  elif um_initial_sync_complete 2>/dev/null; then
    printf 'SYNC_COMPLETE'
  elif um_is_installed 2>/dev/null; then
    printf 'INSTALLED'
  else
    printf 'NOT_INSTALLED'
  fi
}

um_menu_draw() {
  local host disk_free data_gib sync_label mode_hint avail_kib
  host="$(hostname 2>/dev/null || echo unknown)"
  avail_kib="$(um_df_avail_kib "${BASE_PATH:-/}" 2>/dev/null || echo 0)"
  if declare -F um_format_bytes >/dev/null 2>&1; then
    disk_free="$(um_format_bytes $(( avail_kib * 1024 )))"
  else
    disk_free="$(( avail_kib / 1024 / 1024 )) GiB"
  fi
  data_gib="$(um_menu_existing_data_gib)"
  sync_label="$(um_menu_sync_label)"
  mode_hint="${MIRROR_MODE:-minimal}"

  cat <<EOF
┌──────────────── Ubuntu Mirror Server ─────────────────┐
│ Interactive setup menu (SSH-friendly)                 │
├───────────────────────────────────────────────────────┤
│ Host:        ${host}
│ Mirror URL:  ${MIRROR_URL:-?}/ubuntu
│ Disk free:   ${disk_free}
│ Existing:    ${data_gib} GiB under ${BASE_PATH}
│ Sync state:  ${sync_label}
│ Config mode: ${mode_hint}
├───────────────────────────────────────────────────────┤
│  1) Install / start sync — Minimal (~320 GiB)         │
│     main + restricted only  [recommended default]     │
│                                                       │
│  2) Install / start sync — Full (~700 GiB)            │
│     + universe + multiverse  [explicit; capacity OK?] │
│                                                       │
│  3) Monitor live dashboard                            │
│  4) Show status                                       │
│  5) Follow raw logs                                   │
│  6) Stop running synchronization                      │
│  7) Delete existing mirror data  (DANGEROUS)          │
│  8) Quit                                              │
└───────────────────────────────────────────────────────┘
EOF
}

um_menu_pause() {
  printf '\nPress Enter to return to the menu... '
  read -r _ || true
}

um_menu_run_dashboard() {
  local dash
  dash="${INSTALL_BIN_DIR:-/usr/local/bin}/mirror-dashboard"
  [[ -x "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  if [[ ! -x "$dash" ]]; then
    um_warn "Dashboard not installed yet. Install first (option 1 or 2)."
    um_menu_pause
    return 0
  fi
  "$dash" --config "${UM_CONFIG_PATH:-${INSTALL_CONF_DIR}/mirror.conf}" || true
}

um_menu_show_status() {
  local bin
  bin="${INSTALL_BIN_DIR:-/usr/local/bin}/mirrorctl"
  [[ -x "$bin" ]] || bin="${UM_PROJECT_ROOT}/scripts/mirrorctl"
  if [[ -x "$bin" ]]; then
    "$bin" --config "${UM_CONFIG_PATH}" status || true
  else
    printf 'State: %s\nPath: %s\n' "$(um_menu_sync_label)" "$BASE_PATH"
  fi
  um_menu_pause
}

um_menu_follow_logs() {
  printf 'Following %s (Ctrl+C returns to menu)\n' "${APT_MIRROR_LOG}"
  if [[ -f "${APT_MIRROR_LOG}" ]]; then
    tail -n 50 -f "${APT_MIRROR_LOG}" || true
  else
    um_warn "Log not found yet: ${APT_MIRROR_LOG}"
    um_menu_pause
  fi
}

um_menu_stop_sync() {
  um_require_root
  if ! um_is_sync_running && ! pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    um_info "No sync process is running."
    um_menu_pause
    return 0
  fi
  printf 'Stop apt-mirror.service? [y/N] '
  local ans
  read -r ans || true
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    um_info "Cancelled."
    um_menu_pause
    return 0
  fi
  systemctl kill -s SIGCONT apt-mirror.service 2>/dev/null || true
  systemctl stop apt-mirror.service 2>/dev/null || true
  pkill -f '/usr/bin/apt-mirror' 2>/dev/null || true
  um_ok "Stop requested."
  um_menu_pause
}

um_menu_delete_data() {
  um_require_root
  local data_gib
  data_gib="$(um_menu_existing_data_gib)"
  cat <<EOF

⚠  DANGER: Delete existing mirror data
   Path: ${BASE_PATH}
   Size: ~${data_gib} GiB
   This removes mirror/, skel/, and var/ under BASE_PATH.
   Configuration and nginx are kept.

EOF
  if um_is_sync_running; then
    um_warn "A sync is currently RUNNING. Stop it before deleting (menu option 6)."
    um_menu_pause
    return 0
  fi

  printf 'Type DELETE to confirm removal of %s: ' "$BASE_PATH"
  local confirm
  read -r confirm || true
  if [[ "$confirm" != "DELETE" ]]; then
    um_info "Cancelled — data not deleted."
    um_menu_pause
    return 0
  fi

  printf 'Final confirm — delete ~%s GiB? [y/N] ' "$data_gib"
  local ans
  read -r ans || true
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    um_info "Cancelled."
    um_menu_pause
    return 0
  fi

  mkdir -p "$BASE_PATH"
  rm -rf "${MIRROR_PATH}" "${SKEL_PATH}" "${VAR_PATH}"
  # Clear sync lifecycle markers so a fresh install can start cleanly
  um_clear_marker "sync-started" 2>/dev/null || true
  um_clear_marker "sync-failed" 2>/dev/null || true
  um_clear_marker "initial-sync-complete" 2>/dev/null || true
  um_clear_marker "ready" 2>/dev/null || true
  um_clear_marker "finalizing" 2>/dev/null || true
  # Truncate operational logs for a clean dashboard
  : >"${APT_MIRROR_LOG}" 2>/dev/null || true
  : >"$(um_progress_jsonl_path 2>/dev/null || echo /dev/null)" 2>/dev/null || true
  um_ok "Mirror data deleted under ${BASE_PATH}"
  um_menu_pause
}

# Sets globals for the chosen install action.
# Prints: install | quit  on stdout (last line via return path uses UM_MENU_ACTION)
um_install_menu() {
  local choice
  UM_MENU_ACTION=""

  # Menu needs progress helpers when available
  if [[ -f "${UM_PROJECT_ROOT}/lib/progress.sh" ]]; then
    # shellcheck source=lib/progress.sh
    source "${UM_PROJECT_ROOT}/lib/progress.sh" 2>/dev/null || true
  elif [[ -f /usr/local/lib/ubuntu-mirror/progress.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/progress.sh 2>/dev/null || true
  fi

  while true; do
    um_menu_clear
    um_menu_draw
    printf 'Select [1-8]: '
    read -r choice || choice="8"
    case "$choice" in
      1)
        UM_FULL=0
        UM_MINIMAL=1
        UM_FORCE=1
        UM_NO_SYNC=0
        UM_SYNC_MODE="foreground"
        um_resolve_mirror_mode 0
        printf '\nSelected: MINIMAL (main + restricted)\n'
        if ! um_check_sync_capacity "$BASE_PATH" "minimal"; then
          um_menu_pause
          continue
        fi
        printf 'Proceed with minimal install + sync? [Y/n] '
        read -r choice || true
        if [[ "$choice" =~ ^[Nn]$ ]]; then
          continue
        fi
        UM_MENU_ACTION="install"
        return 0
        ;;
      2)
        UM_FULL=1
        UM_MINIMAL=0
        UM_FORCE=1
        UM_NO_SYNC=0
        UM_SYNC_MODE="foreground"
        um_resolve_mirror_mode 1
        printf '\nSelected: FULL (main restricted universe multiverse)\n'
        if ! um_check_sync_capacity "$BASE_PATH" "full"; then
          um_warn "Full mode blocked by capacity / safety reserve."
          um_menu_pause
          continue
        fi
        printf 'Proceed with FULL install + sync? [y/N] '
        read -r choice || true
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
          um_resolve_mirror_mode 0
          continue
        fi
        UM_MENU_ACTION="install"
        return 0
        ;;
      3) um_menu_run_dashboard ;;
      4) um_menu_show_status ;;
      5) um_menu_follow_logs ;;
      6) um_menu_stop_sync ;;
      7) um_menu_delete_data ;;
      8|q|Q)
        UM_MENU_ACTION="quit"
        printf 'Goodbye.\n'
        return 0
        ;;
      *)
        printf 'Invalid choice.\n'
        sleep 1
        ;;
    esac
  done
}
