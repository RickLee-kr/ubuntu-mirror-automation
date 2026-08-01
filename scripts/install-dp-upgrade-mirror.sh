#!/usr/bin/env bash
# scripts/install-dp-upgrade-mirror.sh — DP Ubuntu Upgrade Mirror Manager (whiptail TUI)
# Single workflow: R2 OS Core + ACPS Phase 2 → one HTTP artifact set.
# Sensor-Installer style: dynamic sizing, --fb, inputbox/passwordbox/msgbox/textbox.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MM_PROJECT_ROOT="${MM_PROJECT_ROOT:-$PROJECT_ROOT}"
PROJECT_ROOT="$MM_PROJECT_ROOT"

# shellcheck source=lib/mirror_manager_common.sh
source "${SCRIPT_DIR}/lib/mirror_manager_common.sh"
# shellcheck source=lib/dp-phase2-common.sh
source "${SCRIPT_DIR}/lib/dp-phase2-common.sh"
# shellcheck source=lib/acps_acquire.sh
source "${SCRIPT_DIR}/lib/acps_acquire.sh"
# shellcheck source=lib/r2_acquire.sh
source "${SCRIPT_DIR}/lib/r2_acquire.sh"
# shellcheck source=lib/mirror_install_engine.sh
source "${SCRIPT_DIR}/lib/mirror_install_engine.sh"

cleanup() {
  local rc=$?
  mm_release_install_lock
  if [[ "$rc" -ne 0 && -n "${MM_STATE_DIR:-}" ]]; then
    mm_state_set INSTALL_RESULT FAIL 2>/dev/null || true
  fi
}
trap cleanup EXIT

load_mirror_defaults() {
  if [[ -f "${PROJECT_ROOT}/mirror.conf" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${PROJECT_ROOT}/mirror.conf"
    set +a
  fi
  if [[ -f /etc/ubuntu-mirror/mirror.conf ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/ubuntu-mirror/mirror.conf
    set +a
  fi
  MM_MIRROR_ROOT="${MM_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}}"
  MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-${SELECTIVE_MIRROR_ROOT:-${MM_MIRROR_ROOT}/selective}}"
  MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT:-${DP_PHASE2_ROOT:-${MM_MIRROR_ROOT}/dp-phase2}}"
  MM_CLIENT_ROOT="${MM_CLIENT_ROOT:-${MM_MIRROR_ROOT}/client}"
  if [[ -n "${CLIENT_SIGNING_PUBLIC_KEY:-}" ]]; then
    OS_CORE_PUBLIC_KEY="$CLIENT_SIGNING_PUBLIC_KEY"
  elif [[ -f "${PROJECT_ROOT}/config/client-signing/offline-client-manifest.gpg" ]]; then
    OS_CORE_PUBLIC_KEY="${PROJECT_ROOT}/config/client-signing/offline-client-manifest.gpg"
  fi
}

# ---------------------------------------------------------------------------
# Whiptail helpers (Sensor Installer style)
# ---------------------------------------------------------------------------
mm_term_size() {
  if command -v tput >/dev/null 2>&1; then
    HEIGHT="$(tput lines 2>/dev/null || true)"
    WIDTH="$(tput cols 2>/dev/null || true)"
  fi
  [[ -z "${HEIGHT:-}" ]] && HEIGHT=25
  [[ -z "${WIDTH:-}" ]] && WIDTH=100
}

mm_calc_menu_size() {
  local item_count="$1"
  local min_width="${2:-74}"
  local min_list="${3:-8}"
  mm_term_size
  local menu_list_height=$((item_count + 1))
  [[ "${menu_list_height}" -lt "${min_list}" ]] && menu_list_height="${min_list}"
  # +12 leaves room for a multi-line instruction block (workflow + progress).
  local dialog_height=$((menu_list_height + 12))
  local max_list=$((HEIGHT - 14))
  [[ "${max_list}" -lt 6 ]] && max_list=6
  if [[ "${menu_list_height}" -gt "${max_list}" ]]; then
    menu_list_height="${max_list}"
    dialog_height=$((HEIGHT - 2))
  fi
  [[ "${dialog_height}" -gt $((HEIGHT - 2)) ]] && dialog_height=$((HEIGHT - 2))
  [[ "${dialog_height}" -lt 16 ]] && dialog_height=16
  local dialog_width=$((WIDTH - 6))
  [[ "${dialog_width}" -lt "${min_width}" ]] && dialog_width="${min_width}"
  [[ "${dialog_width}" -gt 100 ]] && dialog_width=100
  [[ "${dialog_width}" -gt $((WIDTH - 2)) ]] && dialog_width=$((WIDTH - 2))
  echo "${dialog_height} ${dialog_width} ${menu_list_height}"
}

mm_calc_dialog_size() {
  local line_count="${1:-4}"
  local min_width="${2:-70}"
  local extra="${3:-6}"
  mm_term_size
  [[ "${line_count}" -lt 1 ]] && line_count=1
  local dialog_height=$((line_count + extra))
  [[ "${dialog_height}" -lt 10 ]] && dialog_height=10
  [[ "${dialog_height}" -gt $((HEIGHT - 2)) ]] && dialog_height=$((HEIGHT - 2))
  [[ "${dialog_height}" -gt 28 ]] && dialog_height=28
  local dialog_width=$((WIDTH - 6))
  [[ "${dialog_width}" -lt "${min_width}" ]] && dialog_width="${min_width}"
  [[ "${dialog_width}" -gt 96 ]] && dialog_width=96
  [[ "${dialog_width}" -gt $((WIDTH - 2)) ]] && dialog_width=$((WIDTH - 2))
  echo "${dialog_height} ${dialog_width}"
}

mm_has_whiptail() { command -v whiptail >/dev/null 2>&1; }

mm_whiptail_menu() {
  local title="$1" text="$2"
  shift 2
  local item_count=$(( $# / 2 ))
  local menu_dims menu_height menu_width menu_list_height
  menu_dims="$(mm_calc_menu_size "${item_count}" 74 8)"
  read -r menu_height menu_width menu_list_height <<< "${menu_dims}"
  if ! mm_has_whiptail; then
    printf '%s\n%s\n' "$title" "$text"
    local i=1 tag
    while [[ $# -gt 0 ]]; do
      printf '  %s) %s\n' "$1" "$2"
      shift 2
    done
    read -r -p "Select: " tag || true
    printf '%s\n' "$tag"
    return 0
  fi
  whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --menu "${text}" \
    "${menu_height}" "${menu_width}" "${menu_list_height}" \
    "$@" \
    3>&1 1>&2 2>&3
}

mm_whiptail_msg() {
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    printf '\n== %s ==\n%b\n' "$title" "$text"
    printf 'Press Enter... '; read -r _ || true
    return 0
  fi
  local body line_count dims h w
  body="$(printf '%b\n\n(Enter = OK)' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 72 6)"
  read -r h w <<< "$dims"
  whiptail --title "${title}" --fb --ok-button "OK" \
    --msgbox "${body}" "${h}" "${w}" || true
}

mm_whiptail_input() {
  local title="$1" text="$2" default="${3:-}"
  if ! mm_has_whiptail; then
    printf '%s\n%b\n[%s]> ' "$title" "$text" "$default"
    local val; read -r val || true
    printf '%s\n' "${val:-$default}"
    return 0
  fi
  local body line_count dims h w result rc
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 70 8)"
  read -r h w <<< "$dims"
  result="$(whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --inputbox "${body}" "${h}" "${w}" "${default}" \
    3>&1 1>&2 2>&3)" || rc=$?
  rc="${rc:-0}"
  if [[ "$rc" -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

mm_whiptail_password() {
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    printf '%s\n%b\n> ' "$title" "$text"
    local val; read -r -s val || true
    printf '\n'
    printf '%s\n' "$val"
    return 0
  fi
  local body line_count dims h w result rc
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 70 8)"
  read -r h w <<< "$dims"
  result="$(whiptail --title "${title}" --fb \
    --ok-button "OK" --cancel-button "Cancel" \
    --passwordbox "${body}" "${h}" "${w}" \
    3>&1 1>&2 2>&3)" || rc=$?
  rc="${rc:-0}"
  if [[ "$rc" -ne 0 ]]; then
    echo ""
    return 1
  fi
  echo "${result}"
  return 0
}

mm_whiptail_textbox() {
  local title="$1" file="$2"
  mm_term_size
  local h=$((HEIGHT - 4)) w=$((WIDTH - 6))
  [[ "$h" -lt 12 ]] && h=12
  [[ "$w" -lt 60 ]] && w=60
  if ! mm_has_whiptail; then
    printf '\n== %s ==\n' "$title"
    cat "$file"
    printf 'Press Enter... '; read -r _ || true
    return 0
  fi
  whiptail --title "${title}" --fb --textbox "$file" "$h" "$w" || true
  return 0
}

mm_whiptail_infobox() {
  # Non-blocking notice that remains visible until the next whiptail dialog.
  # Always returns 0 so callers never inherit dialog exit status.
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    if [[ -w /dev/tty ]]; then
      {
        printf '\n== %s ==\n' "$title"
        printf '%b\n\n' "$text"
      } >/dev/tty 2>/dev/null || true
    else
      printf '\n== %s ==\n' "$title"
      printf '%b\n\n' "$text"
    fi
    return 0
  fi
  local body line_count dims h w
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 72 6)"
  read -r h w <<< "$dims"
  whiptail --title "${title}" --fb --infobox "${body}" "${h}" "${w}" || true
  return 0
}

# Operator notice before long Phase 2 bundle SHA256 (legacy helper; prefer live progress).
gui_show_sha256_wait_notice() {
  local operation="$1"
  local file="$2"
  local lead="${3:-Verifying the SHA256 checksum of the Phase 2 bundle.}"
  local body
  body="${lead}

The bundle is large, so this step may take several minutes depending on disk performance.

The program is still running normally.
Please wait and do not interrupt the process or close this terminal.

HTTP configuration will continue automatically after verification completes."
  mm_info "SHA256_VERIFICATION_START operation=${operation} file=${file} message=\"large file; this may take several minutes\""
  mm_whiptail_infobox "SHA256 Verification in Progress" "$body"
  return 0
}

# Isolate GUI actions from set -e: backend FAIL must show a dialog, not exit the menu.
gui_run_action() {
  local action_name="$1"
  shift
  local action_rc=0
  if [[ "${MM_DEBUG_GUI:-0}" == "1" ]]; then
    mm_info "GUI_ACTION_START action=${action_name}"
  fi
  "$@" || action_rc=$?
  if [[ "${MM_DEBUG_GUI:-0}" == "1" ]]; then
    mm_info "GUI_ACTION_END action=${action_name} rc=${action_rc}"
  fi
  if [[ "$action_rc" -ne 0 ]]; then
    mm_whiptail_msg \
      "${action_name} — Error" \
      "The operation failed with exit code ${action_rc}.

See View Logs for details.

Press OK, Cancel, or ESC to return to the main menu." || true
  fi
  if [[ "${MM_DEBUG_GUI:-0}" == "1" ]]; then
    mm_info "GUI_MENU_RETURN action=${action_name}"
  fi
  return 0
}

mm_whiptail_yesno() {
  # OK/Yes → 0; Cancel/No → 1
  local title="$1" text="$2"
  if ! mm_has_whiptail; then
    printf '%s\n%b\n[Y/n]> ' "$title" "$text"
    local ans; read -r ans || true
    case "${ans:-Y}" in
      Y|y|yes|YES|"") return 0 ;;
      *) return 1 ;;
    esac
  fi
  local body line_count dims h w
  body="$(printf '%b' "$text")"
  line_count="$(printf '%b' "$body" | wc -l)"
  dims="$(mm_calc_dialog_size "${line_count}" 70 6)"
  read -r h w <<< "$dims"
  whiptail --title "${title}" --fb \
    --yes-button "OK" --no-button "Cancel" \
    --yesno "${body}" "${h}" "${w}"
}

# ---------------------------------------------------------------------------
# GUI screens
# ---------------------------------------------------------------------------
gui_configuration() {
  mm_load_gui_config
  while true; do
    local choice
    choice="$(mm_whiptail_menu "Configuration" \
      "Current DP Version: ${CURRENT_DP_VERSION:-"(not set)"}
Target DP Version: ${TARGET_DP_VERSION}
ACPS Username: $(mm_configured_label "$ACPS_USERNAME")
ACPS Password: $(mm_configured_label "$ACPS_PASSWORD")
ACPS Server: fixed
OS Core Source: Cloudflare R2 — fixed" \
      "1" "Current DP Version" \
      "2" "Target DP Version" \
      "3" "ACPS Username" \
      "4" "ACPS Password" \
      "5" "Test ACPS Connection" \
      "6" "Save Configuration" \
      "0" "Back")" || return 0
    case "$choice" in
      1)
        local cv
        cv="$(mm_whiptail_input "Current DP Version" \
          "Enter the DP software version currently installed on the DP (X.Y.Z).

This is the source version used by Stage (--source-dp-version).
It must differ from the Target DP Version." \
          "${CURRENT_DP_VERSION:-}")" || continue
        if [[ -n "$cv" ]]; then
          if mm_validate_source_dp_version "$cv"; then
            if [[ "$cv" == "${TARGET_DP_VERSION}" ]]; then
              mm_whiptail_msg "Invalid" \
                "The current DP version and target DP version are the same.

Verify the Current DP Version in Configuration."
            else
              CURRENT_DP_VERSION="$cv"
            fi
          else
            mm_whiptail_msg "Invalid" "Version must be X.Y.Z at or above 6.2.0 (got: ${cv})"
          fi
        fi
        ;;
      2)
        local v
        v="$(mm_whiptail_input "Target DP Version" "Enter target DP version (X.Y.Z)" "${TARGET_DP_VERSION}")" || continue
        if [[ -n "$v" ]]; then
          if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            TARGET_DP_VERSION="$v"
          else
            mm_whiptail_msg "Invalid" "Version must be X.Y.Z (got: ${v})"
          fi
        fi
        ;;
      3)
        local u
        u="$(mm_whiptail_input "ACPS Username" "Enter ACPS username" "${ACPS_USERNAME}")" || continue
        ACPS_USERNAME="$u"
        ;;
      4)
        local p
        p="$(mm_whiptail_password "ACPS Password" "Enter ACPS password (not displayed later)")" || continue
        ACPS_PASSWORD="$p"
        ;;
      5)
        load_mirror_defaults
        engine_resolve_paths
        mm_load_gui_config
        if [[ -z "$ACPS_USERNAME" || -z "$ACPS_PASSWORD" ]]; then
          mm_whiptail_msg "ACPS" "Save username and password first."
          continue
        fi
        ACPS_BASE_URL="$ACPS_BASE_URL_FIXED"
        if acps_test_connection; then
          mm_status_set ACPS_CONNECTION PASS
          mm_whiptail_msg "ACPS" "ACPS_CONNECTION=PASS"
        else
          mm_status_set ACPS_CONNECTION FAIL
          mm_whiptail_msg "ACPS" "ACPS_CONNECTION=FAIL"
        fi
        ;;
      6)
        mm_save_gui_config
        mm_record_config_validated
        mm_whiptail_msg "Configuration" \
          "Configuration saved.

Next step:
  Back → main menu → 2) Download and Prepare Upgrade Files

Then:
  3) Enable HTTP Distribution
  4) Verify Upgrade Readiness

Saving configuration does NOT start the download."
        ;;
      0|"") return 0 ;;
    esac
  done
}

gui_download_and_prepare() {
  load_mirror_defaults
  mm_load_gui_config
  if ! mm_config_ready; then
    mm_whiptail_msg "Configuration required" "Set Target DP Version, ACPS Username, and ACPS Password first."
    return 0
  fi
  if ! mm_r2_url_configured; then
    mm_whiptail_msg "CONFIGURATION_REQUIRED" \
      "OS Core R2 URL is not configured.

Set OS_CORE_R2_URL_CONSTANT in:
scripts/lib/mirror_manager_common.sh

Then re-run Download and Prepare."
    return 0
  fi
  if ! mm_whiptail_yesno "Confirm" \
      "Download and prepare upgrade files for DP ${TARGET_DP_VERSION}?

OK / Enter starts the download.
Live progress prints in the terminal (no empty waits).
Long steps emit a heartbeat every 30 seconds."; then
    return 0
  fi

  # Leave the whiptail UI so operators can see live download/prepare progress.
  # Do not use a blocking msgbox that requires OK before work starts.
  clear 2>/dev/null || true
  cat <<EOF
============================================================
Download and Prepare — live progress
Target DP Version: ${TARGET_DP_VERSION}

Phases (names appear as each step starts):
  1. Downloading ACPS Artifacts
  2. Verifying ACPS Checksums
  3. Preparing Patched Bringup Script
  4. Creating Phase 2 Bundle
  5. Calculating Bundle SHA256
  6. Verifying Published Bundle
  7. Cleaning Temporary Files
  8. Publishing Phase 2 Artifacts

Long checksum / bundle steps print a heartbeat every 30 seconds.
Do not interrupt or close this terminal.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  local tmp backend_rc=0
  tmp="$(mktemp)"
  set +e
  # Capture transcript for the result textbox. Live progress is mirrored to
  # /dev/tty by mm_log under MM_LIVE_PROGRESS — do not also tee to the
  # terminal (that created exact adjacent duplicate progress lines).
  engine_download_and_prepare >"$tmp" 2>&1
  backend_rc=$?
  set -e
  unset MM_LIVE_PROGRESS

  printf '\n------------------------------------------------------------\n'
  if [[ "$backend_rc" -eq 0 ]]; then
    printf 'Download and Prepare finished: PASS\n'
  else
    printf 'Download and Prepare finished: FAIL (see log above)\n'
  fi
  printf 'Press Enter to return to the menu...\n'
  read -r _ || true

  if [[ "$backend_rc" -eq 0 ]]; then
    mm_whiptail_textbox "Download and Prepare — PASS" "$tmp" || true
  else
    mm_whiptail_textbox "Download and Prepare — FAIL" "$tmp" || true
  fi
  rm -f "$tmp"
  return 0
}

gui_enable_http() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  if ! mm_artifacts_ready_for_http; then
    mm_whiptail_msg "Enable HTTP Distribution" \
      "Upgrade files are not ready.

Run:
2 Download and Prepare Upgrade Files

before enabling HTTP distribution."
    return 0
  fi
  dp2_set_version "${TARGET_DP_VERSION}"
  local backend_rc=0 tmp stable bytes
  stable="$(dp2_stable_bundle_name)"
  bytes="$(stat -c%s "${MM_DP_PHASE2_ROOT}/${TARGET_DP_VERSION}/${stable}" 2>/dev/null || echo 0)"

  # Leave whiptail so SHA256 heartbeats are visible (same pattern as Download).
  clear 2>/dev/null || true
  cat <<EOF
============================================================
Enable HTTP Distribution — live progress
Target DP Version: ${TARGET_DP_VERSION}
Phase 2 bundle: ${stable}
Size: $(mm_format_bytes "$bytes")

Verifying the Phase 2 bundle SHA256 before enabling HTTP distribution.
Long checksum steps print a heartbeat every 30 seconds.
Do not interrupt or close this terminal.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  export MM_SHA256_OPERATION=enable-http
  tmp="$(mktemp)"
  set +e
  # Capture transcript for the result textbox. Live progress is mirrored to
  # /dev/tty by mm_log under MM_LIVE_PROGRESS — do not also tee.
  engine_enable_http_distribution >"$tmp" 2>&1
  backend_rc=$?
  set -e
  unset MM_LIVE_PROGRESS
  unset MM_SHA256_OPERATION

  printf '\n------------------------------------------------------------\n'
  if [[ "$backend_rc" -eq 0 ]]; then
    printf 'Enable HTTP Distribution finished: PASS\n'
  else
    printf 'Enable HTTP Distribution finished: FAIL (see log above)\n'
  fi
  printf 'Press Enter to return to the menu...\n'
  read -r _ || true

  if [[ "$backend_rc" -eq 0 ]]; then
    mm_whiptail_textbox "HTTP Distribution — ENABLED" "$tmp" || true
  else
    mm_whiptail_textbox "HTTP Distribution — FAIL" "$tmp" || true
  fi
  rm -f "$tmp"
  # Backend failure is already shown; keep the main menu alive.
  return 0
}

gui_verify_readiness() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  local tmp http_rc=0 ready_line="" backend_rc=0
  tmp="$(mktemp)"
  if ! mm_http_distribution_enabled; then
    cat >"$tmp" <<EOF
UPGRADE_READINESS=FAIL

HTTP distribution is not enabled.

Run:
3 Enable HTTP Distribution

before verifying upgrade readiness.
EOF
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT FAIL
    mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  dp2_set_version "${TARGET_DP_VERSION}"
  {
    printf 'Target DP Version: %s\n' "${TARGET_DP_VERSION}"
    printf 'HTTP Distribution: %s\n' "$(mm_status_get HTTP_DISTRIBUTION)"
  } >"$tmp"

  clear 2>/dev/null || true
  cat <<EOF
============================================================
Verify Upgrade Readiness — live progress
Target DP Version: ${TARGET_DP_VERSION}

HTTP URL checks and status validation run next.
If a Phase 2 SHA256 check is required, a heartbeat prints every 30 seconds.
Do not interrupt or close this terminal.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  export MM_SHA256_OPERATION=verify-readiness
  set +e
  # Prefer fingerprint skip when artifacts match last Download verify.
  if mm_download_completed; then
    export MM_SKIP_BUNDLE_SHA256=1
  fi
  ( engine_validate_http_layout ) >>"$tmp" 2>&1
  http_rc=$?
  unset MM_SKIP_BUNDLE_SHA256
  set -e
  if [[ "$http_rc" -eq 0 ]]; then
    printf 'HTTP URL checks: PASS\n' >>"$tmp"
  else
    printf 'HTTP URL checks: FAIL\n' >>"$tmp"
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT FAIL
    printf 'UPGRADE_READINESS=FAIL\n' >>"$tmp"
    unset MM_LIVE_PROGRESS
    unset MM_SHA256_OPERATION
    printf '\nPress Enter to return to the menu...\n'
    read -r _ || true
    mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  set +e
  ready_line="$(engine_compute_readiness 2>>"$tmp")"
  backend_rc=$?
  set -e
  printf '%s\n' "$ready_line" >>"$tmp"
  unset MM_LIVE_PROGRESS
  unset MM_SHA256_OPERATION
  printf '\n------------------------------------------------------------\n'
  if [[ "$backend_rc" -eq 0 ]]; then
    printf 'Verify Upgrade Readiness finished: PASS\n'
  else
    printf 'Verify Upgrade Readiness finished: FAIL\n'
  fi
  printf 'Press Enter to return to the menu...\n'
  read -r _ || true
  mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
  rm -f "$tmp"
  return 0
}

gui_show_status() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  local tmp ver config_state os_state bundle_state http_state ready_state
  ver="${TARGET_DP_VERSION:-6.5.0}"
  mm_collect_workflow_status
  if [[ "${MM_WF_CONFIG_COMPLETED}" == "1" ]]; then
    config_state="PASS"
  else
    config_state="FAIL"
  fi
  if [[ "${MM_WF_DOWNLOAD_COMPLETED}" == "1" ]]; then
    os_state="READY"
    bundle_state="READY (9 files)"
  else
    os_state="NOT READY"
    bundle_state="NOT READY"
  fi
  if [[ "${MM_WF_HTTP_COMPLETED}" == "1" ]]; then
    http_state="ENABLED"
  else
    http_state="$(mm_status_get HTTP_DISTRIBUTION)"
    [[ -n "$http_state" ]] || http_state="DISABLED"
    [[ "$http_state" == "ENABLED" ]] || http_state="DISABLED"
  fi
  ready_state="$(mm_upgrade_readiness_display)"
  [[ -n "$ready_state" ]] || ready_state="NOT VERIFIED"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
DP Upgrade Mirror Status
========================

Current DP Version: ${CURRENT_DP_VERSION:-"(not set)"}
Target DP Version: ${ver}
Configuration: ${config_state}
OS Upgrade Files: ${os_state}
DP ${ver} Bundle: ${bundle_state}
HTTP Distribution: ${http_state}
Upgrade Readiness: ${ready_state}
Last Operation: $(mm_status_get LAST_EXECUTION_RESULT)
Log File: $(mm_status_get LOG_PATH)

$(mm_workflow_progress_text)
EOF
  mm_whiptail_textbox "Current Status" "$tmp" || true
  rm -f "$tmp"
  return 0
}

gui_view_logs() {
  local log
  log="$(mm_status_get LOG_PATH)"
  if [[ -z "$log" || ! -f "$log" ]]; then
    # newest log
    log="$(ls -1t "${MM_LOG_DIR}"/mirror-manager-*.log 2>/dev/null | head -1 || true)"
  fi
  if [[ -z "$log" || ! -f "$log" ]]; then
    mm_whiptail_msg "Logs" "No mirror-manager log found yet."
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  # redact before display
  mm_redact <"$log" >"$tmp" || true
  mm_whiptail_textbox "Logs — ${log}" "$tmp" || true
  rm -f "$tmp"
  return 0
}

# One physical line: rm → curl script → curl sha → sha256sum -c → sudo bash.
gui_client_hop_command() {
  local mirror="$1" script="$2"
  printf 'cd /home/aella && rm -f %s %s.sha256 && curl -fsSLO %s/client/%s && curl -fsSLO %s/client/%s.sha256 && sha256sum -c %s.sha256 && sudo bash ./%s' \
    "$script" "$script" "$mirror" "$script" "$mirror" "$script" "$script" "$script"
}

gui_build_client_commands() {
  # Writes command text to stdout. Args: mirror source_ver topology worker_ips
  local mirror="$1" source_ver="$2" topology="$3" worker_ips="${4:-}"
  local ver="${TARGET_DP_VERSION:-6.5.0}"
  local snap_line step6 step7
  if [[ "$topology" == "cluster" ]]; then
    snap_line="Create a full hypervisor snapshot of every DP VM."
  else
    snap_line="Create a full hypervisor snapshot of the DP VM."
  fi
  step6="cd /home/aella && rm -f stage-dp-phase2.sh stage-dp-phase2.sh.sha256 && curl -fsSLO ${mirror}/client/stage-dp-phase2.sh && curl -fsSLO ${mirror}/client/stage-dp-phase2.sh.sha256 && sha256sum -c stage-dp-phase2.sh.sha256 && sudo bash ./stage-dp-phase2.sh --source-dp-version ${source_ver} --target-version ${ver} --mirror-url ${mirror}"
  if [[ "$topology" == "cluster" ]]; then
    step7="sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version ${ver} --skip-download --worker-ips \"${worker_ips}\""
  else
    step7="sudo bash /home/aella/bringup_py3_dp_after_os_upgrade.sh --version ${ver} --skip-download"
  fi
  cat <<EOF
DP Client Upgrade Commands
==========================

Mirror Server: ${mirror}
Current DP Version: ${source_ver}
Target DP Version: ${ver}

Run these steps on the DP, not on the Mirror Server.

Step 0 — Create a snapshot

${snap_line}

Step 1 — Pause DP services

Run \`aella_cli\` on the Ubuntu 16.04 DP.
Select or enter \`pause\`.
Wait until the pause completes.

Do not run \`pause\` directly in the Linux bash shell.
Do not resume the DP during the intermediate Ubuntu upgrades.

Step 2 — Ubuntu 16.04 to 18.04

$(gui_client_hop_command "$mirror" "dp-offline-upgrade-xenial-to-bionic.sh")

Step 3 — Ubuntu 18.04 to 20.04

$(gui_client_hop_command "$mirror" "dp-offline-upgrade-bionic-to-focal.sh")

Step 4 — Ubuntu 20.04 to 22.04

$(gui_client_hop_command "$mirror" "dp-offline-upgrade-focal-to-jammy.sh")

Step 5 — Ubuntu 22.04 to 24.04

$(gui_client_hop_command "$mirror" "dp-offline-upgrade-jammy-to-noble.sh")

Do not resume the DP during Steps 2–5.

Step 6 — Download and stage DP ${ver} files

${step6}

EOF
  if [[ "$topology" == "cluster" ]]; then
    cat <<EOF
Step 7 — Start DP ${ver} bringup

Run this command on the cluster master only.

Complete the DL cluster first, then run the corresponding command on the DA master using the DA worker IPs.

Do not include the master IP.
Do not mix DL and DA worker IPs in one command.

Management IPs or cluster IPs can be used for \`--worker-ips\`.
Cluster IPs are recommended when the master can reach them.

${step7}

EOF
  else
    cat <<EOF
Step 7 — Start DP ${ver} bringup

${step7}

EOF
  fi
  cat <<EOF
Step 8 — Resume DP services

After the bringup script completes, run \`aella_cli\`.
Select or enter \`resume\`.
Wait for resume to complete and allow several minutes for pods and host services to start.

Resume is an aella_cli menu command.
Do not run \`resume\` directly in the Linux bash shell.

The DP health checks must be performed after resume.
Pods and host services may not become ready until the DP services are resumed.

Step 9 — Verify DP health

After resume, wait for the DP services to start.
Then run \`aella_cli\` and select or enter \`show status\`.

Confirm that:
- All pods are running
- All cluster nodes are ready
- All host services are ready
- System Ready (or the normal ready state for this role)
- License status is normal
- Provision status is normal when required for this role

The status may take several minutes to become ready after resume.
Do not treat the DP as healthy immediately after running resume.

EOF
  if [[ "$topology" == "cluster" ]]; then
    cat <<EOF
Run the status check on the cluster master.
Confirm that all worker nodes are ready.
Confirm the DL cluster first, then confirm the DA cluster.

EOF
  fi
  cat <<EOF
A copy of these commands was saved to:
$(mm_client_commands_file)
EOF
}

gui_client_instructions() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  local ver="${TARGET_DP_VERSION:-6.5.0}"
  local mirror source_ver topology worker_ips="" topo_choice out_file tmp source_default=""
  mirror="$(mm_client_mirror_url)" || {
    mm_whiptail_msg "DP Client Upgrade Commands" \
      "Could not determine the Mirror Server HTTP address.

Set MIRROR_HTTP_URL in ${MM_CONFIG_FILE} (example: http://221.139.249.111)
or ensure this host has a reachable IPv4 address."
    return 0
  }
  # Persist resolved URL for next runs (no secrets).
  if [[ -z "${MIRROR_HTTP_URL:-}" ]]; then
    MIRROR_HTTP_URL="$mirror"
    mm_save_gui_config >/dev/null 2>&1 || true
  fi

  if mm_validate_source_dp_version "${CURRENT_DP_VERSION:-}" 2>/dev/null \
    && [[ "${CURRENT_DP_VERSION}" != "$ver" ]]; then
    source_default="${CURRENT_DP_VERSION}"
  else
    source_default=""
  fi

  source_ver="$(mm_whiptail_input \
    "Current DP software version" \
    "Enter the current DP software version on the DP (X.Y.Z).

This value is used in Step 6 --source-dp-version.
It must match Configuration Current DP Version and must differ from Target DP Version (${ver})." \
    "${source_default}")" || return 0
  if ! mm_validate_source_dp_version "$source_ver"; then
    mm_whiptail_msg "Invalid version" \
      "Version must be X.Y.Z at or above 6.2.0 (got: ${source_ver})"
    return 0
  fi
  if [[ "$source_ver" == "$ver" ]]; then
    mm_whiptail_msg "Invalid versions" \
      "The current DP version and target DP version are the same.

Verify the Current DP Version in Configuration."
    return 0
  fi

  topo_choice="$(mm_whiptail_menu \
    "DP topology" \
    "Select the DP deployment type for Step 7 bringup." \
    "1" "Single DP / AIO / master without workers" \
    "2" "Cluster master with workers")" || return 0
  case "$topo_choice" in
    1) topology="single" ;;
    2)
      topology="cluster"
      worker_ips="$(mm_whiptail_input \
        "Worker IP addresses" \
        "Enter the worker IP addresses for this cluster master.

Recommended: use the worker cluster IP addresses.
Use management IP addresses only when the cluster network is not reachable from the master.

- Management IPs or cluster IPs can be used.
- Cluster IPs are recommended when they are reachable because the cluster network usually provides more reliable node-to-node communication.
- Enter worker IPs only. Do not enter the master IP.
- Separate multiple IPs with commas.
- Do not mix management and cluster IPs in the same cluster unless required by the network design.
- Example: 192.168.124.23,192.168.124.24" \
        "")" || return 0
      worker_ips="$(mm_validate_worker_ips "$worker_ips")" || {
        mm_whiptail_msg "Invalid worker IPs" \
          "Provide a non-empty comma-separated list of valid IPv4 addresses.
Do not include trailing commas, duplicates, 0.0.0.0, or 255.255.255.255.
Shell metacharacters are not allowed."
        return 0
      }
      ;;
    *) return 0 ;;
  esac

  tmp="$(mktemp)"
  gui_build_client_commands "$mirror" "$source_ver" "$topology" "$worker_ips" >"$tmp"
  out_file="$(mm_client_commands_file)"
  if ! mkdir -p "$(dirname "$out_file")" || ! cp -f "$tmp" "$out_file" || ! chmod 0644 "$out_file"; then
    mm_whiptail_msg "DP Client Upgrade Commands" \
      "Could not write command file:
${out_file}

Mirror Manager must run as root:
  sudo ubuntu-offline-mirror mirror-manager"
    rm -f "$tmp"
    return 0
  fi
  mm_whiptail_textbox "DP Client Upgrade Commands" "$tmp" || true
  # Optional tty reprint for mouse-copy after textbox (interactive sessions only).
  if [[ -t 0 ]]; then
    {
      printf '\n------------------------------------------------------------\n'
      cat "$tmp"
      printf '------------------------------------------------------------\n'
    } >/dev/tty 2>/dev/null || true
  fi
  rm -f "$tmp"
  return 0
}

cmd_mirror_manager() {
  export MM_GUI_MODE=1
  # Official entry: sudo ubuntu-offline-mirror mirror-manager (root only).
  # Check before loading root-owned config/logs to avoid raw Permission denied.
  mm_require_root
  load_mirror_defaults
  engine_resolve_paths
  mm_load_gui_config
  if [[ "${MM_FORCE_MENU:-0}" != "1" ]] && { [[ ! -t 0 ]] || [[ ! -t 1 ]]; }; then
    cat <<EOF
NON_INTERACTIVE_TTY=FAIL
Use: sudo $0 mirror-manager   (interactive TTY)
Or:  sudo ./scripts/ubuntu-offline-mirror.sh mirror-manager
EOF
    exit 1
  fi
  while true; do
    local choice="" menu_rc=0
    local configuration_label download_label http_label readiness_label progress_line
    mm_collect_workflow_status
    configuration_label="$(mm_menu_label "Configuration" "${MM_WF_CONFIG_COMPLETED}")"
    download_label="$(mm_menu_label "Download and Prepare Upgrade Files" "${MM_WF_DOWNLOAD_COMPLETED}")"
    http_label="$(mm_menu_label "Enable HTTP Distribution" "${MM_WF_HTTP_COMPLETED}")"
    readiness_label="$(mm_menu_label "Verify Upgrade Readiness" "${MM_WF_READINESS_COMPLETED}")"
    progress_line="$(mm_workflow_progress_text)"
    choice="$(mm_whiptail_menu \
      "DP Ubuntu Upgrade Mirror Manager" \
      "Workflow: Configuration → Download → Enable HTTP → Verify Readiness
${progress_line}
Cancel/ESC returns here; choose 0 to Exit." \
      "1" "${configuration_label}" \
      "2" "${download_label}" \
      "3" "${http_label}" \
      "4" "${readiness_label}" \
      "5" "Show Current Status" \
      "6" "View Logs" \
      "7" "Show DP Client Upgrade Commands" \
      "0" "Exit")" || menu_rc=$?
    # Cancel/ESC on the main menu must NOT drop to the shell; only "0 Exit" leaves.
    if [[ "$menu_rc" -ne 0 ]]; then
      continue
    fi
    case "$choice" in
      1) gui_run_action "Configuration" gui_configuration ;;
      2) gui_run_action "Download and Prepare" gui_download_and_prepare ;;
      3) gui_run_action "Enable HTTP Distribution" gui_enable_http ;;
      4) gui_run_action "Verify Upgrade Readiness" gui_verify_readiness ;;
      5) gui_run_action "Show Current Status" gui_show_status ;;
      6) gui_run_action "View Logs" gui_view_logs ;;
      7) gui_run_action "DP Client Upgrade Commands" gui_client_instructions ;;
      0)
        # GUI_EXITS_ONLY_ON_EXPLICIT_ZERO
        return 0
        ;;
      "")
        continue
        ;;
      *)
        mm_whiptail_msg "Invalid selection" "Unknown menu selection: ${choice}" || true
        ;;
    esac
  done
}

# Non-interactive helpers for tests
cmd_download_and_prepare() {
  mm_require_root
  load_mirror_defaults
  engine_download_and_prepare
}

cmd_verify_readiness() {
  mm_require_root
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  engine_compute_readiness
}

cmd_enable_http() {
  mm_require_root
  load_mirror_defaults
  engine_enable_http_distribution
}

usage() {
  cat <<EOF
Usage: $0 <command>

DP Ubuntu Upgrade Mirror Manager (single workflow: R2 OS Core + ACPS Phase 2).

Fresh hosts should bootstrap with: sudo ./install.sh
Re-open GUI after install:         sudo ubuntu-offline-mirror mirror-manager

Commands:
  mirror-manager          Interactive whiptail Mirror Manager (default)
  download-and-prepare    Non-interactive prepare (saved config + fixed R2 URL)
  verify-readiness        Print UPGRADE_READINESS
  enable-http             Install/enable nginx site and smoke-test HTTP
EOF
}

main() {
  local cmd="${1:-mirror-manager}"
  if [[ "$cmd" == "-h" || "$cmd" == "--help" || "$cmd" == "help" ]]; then
    usage
    exit 0
  fi
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-root)
        MM_MIRROR_ROOT="${2:-}"
        MM_SELECTIVE_ROOT="${MM_MIRROR_ROOT}/selective"
        MM_DP_PHASE2_ROOT="${MM_MIRROR_ROOT}/dp-phase2"
        MM_CLIENT_ROOT="${MM_MIRROR_ROOT}/client"
        shift 2
        ;;
      --dry-run) MM_DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) mm_die "Unknown argument: $1" ;;
    esac
  done
  case "$cmd" in
    mirror-manager|install-menu) cmd_mirror_manager ;;
    download-and-prepare) cmd_download_and_prepare ;;
    verify-readiness) cmd_verify_readiness ;;
    enable-http) cmd_enable_http ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
