#!/usr/bin/env bash
# shellcheck shell=bash
# Interactive installer menu — dialog/whiptail style TUI (SSH-friendly).
#
# Keyboard model (no Tab required):
#   ↑ / ↓     move in the list
#   Enter     select / confirm  (Ok)
#   Esc       leave dialog      (same as Cancel)
# Tab-to-button focus is unreliable over many SSH clients, so Cancel buttons
# are omitted (--nocancel) and Esc / Exit items are used instead.

# shellcheck disable=SC2317
if [[ -n "${UM_INSTALL_MENU_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_INSTALL_MENU_LOADED=1

# Classic dialog look (magenta root, gray window, red selection).
um_menu_set_newt_colors() {
  export NEWT_COLORS='
root=white,magenta
border=black,lightgray
window=black,lightgray
shadow=black,blue
title=red,lightgray
button=black,lightgray
actbutton=white,green
compactbutton=black,lightgray
checkbox=black,lightgray
actcheckbox=white,blue
entry=black,lightgray
label=black,lightgray
listbox=black,lightgray
actlistbox=white,red
sellistbox=black,lightgray
actsellistbox=white,red
textbox=black,lightgray
acttextbox=black,lightgray
roottext=black,magenta
emptyscale=,gray
fullscale=,blue
disentry=gray,lightgray
helpline=black,lightgray
'
}

um_menu_is_tty() {
  [[ -t 0 ]] && [[ -t 1 ]]
}

um_menu_has_whiptail() {
  command -v whiptail >/dev/null 2>&1
}

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

um_menu_status_blurb() {
  local host data_gib sync_label disk_free avail_kib
  host="$(hostname 2>/dev/null || echo unknown)"
  data_gib="$(um_menu_existing_data_gib)"
  sync_label="$(um_menu_sync_label)"
  avail_kib="$(um_df_avail_kib "${BASE_PATH:-/}" 2>/dev/null || echo 0)"
  disk_free="$(( avail_kib / 1024 / 1024 )) GiB free"
  printf '%s | %s | data %s GiB | %s' "$host" "$sync_label" "$data_gib" "$disk_free"
}

um_menu_keys_hint() {
  printf '↑↓ move   Enter = select   Esc = back'
}

# ---------------------------------------------------------------------------
# whiptail helpers — always --nocancel so Enter confirms without Tab
# ---------------------------------------------------------------------------
um_whiptail_menu() {
  # um_whiptail_menu <title> <text> <tag1> <item1> ...
  local title="$1" text="$2"
  shift 2
  um_menu_set_newt_colors
  # --nocancel: only Ok; focus stays on the list; Enter selects the highlighted item.
  # Esc still aborts (exit 1) for "back/quit".
  whiptail --title "$title" --nocancel --ok-button "OK" \
    --menu "$text" 22 74 10 "$@" 3>&1 1>&2 2>&3
}

um_whiptail_yesno() {
  # Implemented as a 2-item menu so Tab is never required.
  local title="$1" text="$2" default_no="${3:-0}"
  local choice default_item="yes"
  if [[ "$default_no" == "1" ]]; then
    default_item="no"
  fi

  if ! um_menu_has_whiptail; then
    printf '%s\n%s\n' "$title" "$(printf '%b' "$text")"
    if [[ "$default_no" == "1" ]]; then
      printf '[y/N] '
      local ans
      read -r ans || true
      [[ "$ans" =~ ^[Yy]$ ]]
    else
      printf '[Y/n] '
      local ans
      read -r ans || true
      [[ ! "$ans" =~ ^[Nn]$ ]]
    fi
    return $?
  fi

  um_menu_set_newt_colors
  choice="$(whiptail --title "$title" --nocancel --ok-button "OK" \
    --default-item "$default_item" \
    --menu "${text}

$(um_menu_keys_hint)" 16 70 2 \
    "yes" "Yes — continue" \
    "no"  "No — cancel" \
    3>&1 1>&2 2>&3)" || return 1
  [[ "$choice" == "yes" ]]
}

um_whiptail_msg() {
  local title="$1" text="$2" height="${3:-16}" width="${4:-72}"
  if ! um_menu_has_whiptail; then
    printf '\n== %s ==\n%b\n' "$title" "$text"
    printf 'Press Enter... '
    read -r _ || true
    return 0
  fi
  um_menu_set_newt_colors
  # Single OK button — Enter dismisses. No Cancel / no Tab.
  whiptail --title "$title" --nocancel --ok-button "OK" \
    --msgbox "${text}

(Press Enter)" "$height" "$width"
}

um_whiptail_file_msg() {
  local title="$1" file="$2" height="${3:-20}" width="${4:-72}"
  local body
  body="$(sed 's/\x1b\[[0-9;]*m//g' "$file" 2>/dev/null || cat "$file")"
  um_whiptail_msg "$title" "$body" "$height" "$width"
}

um_whiptail_input() {
  local title="$1" text="$2" default="${3:-}"
  if ! um_menu_has_whiptail; then
    printf '%s\n%b\n> ' "$title" "$text"
    local val
    read -r val || true
    printf '%s\n' "${val:-$default}"
    return 0
  fi
  um_menu_set_newt_colors
  # --nocancel: type text, press Enter to submit (no Tab to Ok).
  whiptail --title "$title" --nocancel --ok-button "OK" \
    --inputbox "${text}

$(um_menu_keys_hint)" 14 70 "$default" 3>&1 1>&2 2>&3
}

um_menu_pause() {
  um_whiptail_msg "Ubuntu Mirror" "Press Enter to return to the menu."
}

um_menu_run_dashboard() {
  local dash repo
  dash=""
  if [[ -f "${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/source-repo" ]]; then
    repo="$(tr -d '\r\n' <"${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/source-repo" 2>/dev/null || true)"
    [[ -x "${repo}/scripts/mirror-dashboard.sh" ]] && dash="${repo}/scripts/mirror-dashboard.sh"
  fi
  [[ -n "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  [[ -x "$dash" ]] || dash="${INSTALL_BIN_DIR:-/usr/local/bin}/mirror-dashboard"
  [[ -x "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  if [[ ! -x "$dash" ]]; then
    um_whiptail_msg "Monitor" "Dashboard not installed yet.\n\nInstall first (Minimal or Full)."
    return 0
  fi
  clear 2>/dev/null || true
  "$dash" --config "${UM_CONFIG_PATH:-${INSTALL_CONF_DIR}/mirror.conf}" || true
}

um_menu_show_status() {
  local bin tmp
  bin="${INSTALL_BIN_DIR:-/usr/local/bin}/mirrorctl"
  [[ -x "$bin" ]] || bin="${UM_PROJECT_ROOT}/scripts/mirrorctl"
  tmp="$(mktemp)"
  if [[ -x "$bin" ]]; then
    "$bin" --config "${UM_CONFIG_PATH}" status >"$tmp" 2>&1 || true
  else
    printf 'State: %s\nPath: %s\n' "$(um_menu_sync_label)" "$BASE_PATH" >"$tmp"
  fi
  um_whiptail_file_msg "Status" "$tmp" 22 72
  rm -f "$tmp"
}

um_menu_follow_logs() {
  clear 2>/dev/null || true
  printf 'Following %s (Ctrl+C returns to menu)\n' "${APT_MIRROR_LOG}"
  if [[ -f "${APT_MIRROR_LOG}" ]]; then
    tail -n 50 -f "${APT_MIRROR_LOG}" || true
  else
    um_whiptail_msg "Logs" "Log not found yet:\n${APT_MIRROR_LOG}"
  fi
}

um_menu_stop_sync() {
  um_require_root
  if ! um_is_sync_running && ! pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    um_whiptail_msg "Stop sync" "No sync process is running."
    return 0
  fi
  if ! um_whiptail_yesno "Stop sync" "Stop apt-mirror.service now?\n\nSync will halt until started again." 1; then
    return 0
  fi
  systemctl kill -s SIGCONT apt-mirror.service 2>/dev/null || true
  systemctl stop apt-mirror.service 2>/dev/null || true
  pkill -f '/usr/bin/apt-mirror' 2>/dev/null || true
  um_whiptail_msg "Stop sync" "Stop requested."
}

um_menu_delete_data() {
  um_require_root
  local data_gib confirm
  data_gib="$(um_menu_existing_data_gib)"

  if um_is_sync_running; then
    um_whiptail_msg "Delete data" \
      "A sync is currently RUNNING.\n\nStop it first (menu: Stop running sync),\nthen delete data."
    return 0
  fi

  if ! um_whiptail_yesno "Delete data" \
    "DANGER: Delete existing mirror data?\n\nPath: ${BASE_PATH}\nSize: ~${data_gib} GiB\n\nRemoves mirror/, skel/, var/.\nConfig and nginx are kept." 1; then
    return 0
  fi

  confirm="$(um_whiptail_input "Confirm delete" \
    "Type DELETE to permanently remove:\n${BASE_PATH}" "")" || return 0
  if [[ "$confirm" != "DELETE" ]]; then
    um_whiptail_msg "Delete data" "Cancelled — data not deleted."
    return 0
  fi

  mkdir -p "$BASE_PATH"
  rm -rf "${MIRROR_PATH}" "${SKEL_PATH}" "${VAR_PATH}"
  um_clear_marker "sync-started" 2>/dev/null || true
  um_clear_marker "sync-failed" 2>/dev/null || true
  um_clear_marker "initial-sync-complete" 2>/dev/null || true
  um_clear_marker "ready" 2>/dev/null || true
  um_clear_marker "finalizing" 2>/dev/null || true
  : >"${APT_MIRROR_LOG}" 2>/dev/null || true
  if declare -F um_progress_jsonl_path >/dev/null 2>&1; then
    : >"$(um_progress_jsonl_path)" 2>/dev/null || true
  fi
  um_whiptail_msg "Delete data" "Mirror data deleted under:\n${BASE_PATH}"
}

um_menu_prepare_install_minimal() {
  UM_FULL=0
  UM_MINIMAL=1
  UM_FORCE=1
  UM_NO_SYNC=0
  UM_SYNC_MODE="foreground"
  um_resolve_mirror_mode 0

  local cap_out
  cap_out="$(mktemp)"
  if ! um_check_sync_capacity "$BASE_PATH" "minimal" >"$cap_out" 2>&1; then
    um_whiptail_file_msg "Capacity check failed" "$cap_out" 18 72
    rm -f "$cap_out"
    return 1
  fi
  rm -f "$cap_out"

  um_whiptail_yesno "Minimal install" \
    "Install / start sync in MINIMAL mode?\n\nComponents: main + restricted\nProjected size: ~320 GiB\n\nRecommended default." 0
}

um_menu_prepare_install_full() {
  UM_FULL=1
  UM_MINIMAL=0
  UM_FORCE=1
  UM_NO_SYNC=0
  UM_SYNC_MODE="foreground"
  um_resolve_mirror_mode 1

  local cap_out
  cap_out="$(mktemp)"
  if ! um_check_sync_capacity "$BASE_PATH" "full" >"$cap_out" 2>&1; then
    um_whiptail_file_msg "Full mode blocked" "$cap_out" 18 72
    rm -f "$cap_out"
    um_resolve_mirror_mode 0
    return 1
  fi
  rm -f "$cap_out"

  if ! um_whiptail_yesno "Full install" \
    "Install / start sync in FULL mode?\n\nComponents: main restricted universe multiverse\nProjected size: ~700 GiB\n\nRequires enough disk after 20% reserve." 1; then
    um_resolve_mirror_mode 0
    return 1
  fi
  return 0
}

um_menu_fallback_draw() {
  cat <<EOF
┌──────────────── Ubuntu Mirror Server ─────────────────┐
│ $(um_menu_status_blurb)
├───────────────────────────────────────────────────────┤
│  1) Install / start sync — Minimal (~320 GiB)         │
│  2) Install / start sync — Full (~700 GiB)            │
│  3) Monitor live dashboard                            │
│  4) Show status                                       │
│  5) Follow raw logs                                   │
│  6) Stop running synchronization                      │
│  7) Delete existing mirror data  (DANGEROUS)          │
│  8) Exit                                              │
└───────────────────────────────────────────────────────┘
EOF
}

um_install_menu_fallback() {
  local choice
  while true; do
    clear 2>/dev/null || true
    um_menu_fallback_draw
    printf 'Select [1-8]: '
    read -r choice || choice="8"
    case "$choice" in
      1)
        if um_menu_prepare_install_minimal; then
          UM_MENU_ACTION="install"
          return 0
        fi
        ;;
      2)
        if um_menu_prepare_install_full; then
          UM_MENU_ACTION="install"
          return 0
        fi
        ;;
      3) um_menu_run_dashboard ;;
      4) um_menu_show_status ;;
      5) um_menu_follow_logs ;;
      6) um_menu_stop_sync ;;
      7) um_menu_delete_data ;;
      8|q|Q)
        UM_MENU_ACTION="quit"
        return 0
        ;;
    esac
  done
}

um_install_menu() {
  UM_MENU_ACTION=""

  if [[ -f "${UM_PROJECT_ROOT}/lib/progress.sh" ]]; then
    # shellcheck source=lib/progress.sh
    source "${UM_PROJECT_ROOT}/lib/progress.sh" 2>/dev/null || true
  elif [[ -f /usr/local/lib/ubuntu-mirror/progress.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/progress.sh 2>/dev/null || true
  fi

  if ! um_menu_has_whiptail; then
    um_warn "whiptail not found — using plain text menu"
    um_warn "Install with: apt-get install -y whiptail"
    um_install_menu_fallback
    return $?
  fi

  local choice blurb
  while true; do
    blurb="$(um_menu_status_blurb)"
    choice="$(um_whiptail_menu "Ubuntu Mirror Menu" \
      "Ubuntu Mirror Server

${blurb}

$(um_menu_keys_hint)
(Cancel button removed — Esc or choose Exit)" \
      "1" "Install / start sync — Minimal (~320 GiB)" \
      "2" "Install / start sync — Full (~700 GiB)" \
      "3" "Monitor live dashboard" \
      "4" "Show status" \
      "5" "Follow raw logs" \
      "6" "Stop running synchronization" \
      "7" "Delete existing mirror data (DANGEROUS)" \
      "8" "Exit" \
    )" || {
      UM_MENU_ACTION="quit"
      return 0
    }

    case "$choice" in
      1)
        if um_menu_prepare_install_minimal; then
          UM_MENU_ACTION="install"
          return 0
        fi
        ;;
      2)
        if um_menu_prepare_install_full; then
          UM_MENU_ACTION="install"
          return 0
        fi
        ;;
      3) um_menu_run_dashboard ;;
      4) um_menu_show_status ;;
      5) um_menu_follow_logs ;;
      6) um_menu_stop_sync ;;
      7) um_menu_delete_data ;;
      8)
        UM_MENU_ACTION="quit"
        return 0
        ;;
    esac
  done
}
