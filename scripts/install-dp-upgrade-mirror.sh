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
  local dialog_height=$((menu_list_height + 10))
  local max_list=$((HEIGHT - 12))
  [[ "${max_list}" -lt 6 ]] && max_list=6
  if [[ "${menu_list_height}" -gt "${max_list}" ]]; then
    menu_list_height="${max_list}"
    dialog_height=$((HEIGHT - 2))
  fi
  [[ "${dialog_height}" -gt $((HEIGHT - 2)) ]] && dialog_height=$((HEIGHT - 2))
  [[ "${dialog_height}" -lt 14 ]] && dialog_height=14
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

# Operator notice before long Phase 2 bundle SHA256 (GUI capture hides engine stdout).
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
      "Target DP Version: ${TARGET_DP_VERSION}
ACPS Username: $(mm_configured_label "$ACPS_USERNAME")
ACPS Password: $(mm_configured_label "$ACPS_PASSWORD")
ACPS Server: fixed
OS Core Source: Cloudflare R2 — fixed" \
      "1" "Target DP Version" \
      "2" "ACPS Username" \
      "3" "ACPS Password" \
      "4" "Test ACPS Connection" \
      "5" "Save Configuration" \
      "0" "Back")" || return 0
    case "$choice" in
      1)
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
      2)
        local u
        u="$(mm_whiptail_input "ACPS Username" "Enter ACPS username" "${ACPS_USERNAME}")" || continue
        ACPS_USERNAME="$u"
        ;;
      3)
        local p
        p="$(mm_whiptail_password "ACPS Password" "Enter ACPS password (not displayed later)")" || continue
        ACPS_PASSWORD="$p"
        ;;
      4)
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
      5)
        mm_save_gui_config
        mm_status_set CONFIGURATION_READY PASS
        mm_whiptail_msg "Configuration" \
          "Configuration saved.

Next step:
  Back → main menu → 2) Download and Prepare Upgrade Files

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
Progress will print live in the terminal (R2 ~3.5GB may take a while)."; then
    return 0
  fi

  # Leave the whiptail UI so operators can see live download progress.
  clear 2>/dev/null || true
  cat <<EOF
============================================================
Download and Prepare — live progress
Target DP Version: ${TARGET_DP_VERSION}
R2 OS Core + ACPS Phase 2 will download now.
Progress lines print every few seconds. Do not interrupt.
============================================================

EOF
  export MM_LIVE_PROGRESS=1
  local tmp backend_rc=0
  tmp="$(mktemp)"
  set +e
  set -o pipefail
  # tee keeps a full transcript for the final summary textbox.
  # MM_LIVE_PROGRESS also mirrors lines to /dev/tty so progress stays visible.
  engine_download_and_prepare 2>&1 | tee "$tmp"
  backend_rc=$?
  set +o pipefail
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

gui_verify_readiness() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  local tmp
  tmp="$(mktemp)"
  {
    printf 'CONFIGURATION_READY=%s\n' "$(mm_status_get CONFIGURATION_READY)"
    printf 'R2_OS_CORE_DOWNLOADED=%s\n' "$(mm_status_get R2_OS_CORE_DOWNLOADED)"
    printf 'R2_OS_CORE_CHECKSUM=%s\n' "$(mm_status_get R2_OS_CORE_CHECKSUM)"
    printf 'OS_MIRROR_READY=%s\n' "$(mm_status_get OS_MIRROR_READY)"
    printf 'ACPS_CONNECTION=%s\n' "$(mm_status_get ACPS_CONNECTION)"
    printf 'ACPS_PHASE2_DOWNLOADED=%s\n' "$(mm_status_get ACPS_PHASE2_DOWNLOADED)"
    printf 'ACPS_CHECKSUM=%s\n' "$(mm_status_get ACPS_CHECKSUM)"
    printf 'UPSTREAM_BRINGUP_DRIFT=%s\n' "$(mm_status_get UPSTREAM_BRINGUP_DRIFT)"
    printf 'PATCHED_BRINGUP_APPLIED=%s\n' "$(mm_status_get PATCHED_BRINGUP_APPLIED)"
    printf 'PHASE2_BUNDLE_ENTRY_COUNT=%s\n' "$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT)"
    printf 'PHASE2_BUNDLE_CHECKSUM=%s\n' "$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
    printf 'CLIENT_FILES_READY=%s\n' "$(mm_status_get CLIENT_FILES_READY)"
    printf 'HTTP_CONFIGURATION_READY=%s\n' "$(mm_status_get HTTP_CONFIGURATION_READY)"
    printf 'TARGET_DP_VERSION=%s\n' "${TARGET_DP_VERSION}"
    # No live SHA256 of the Phase 2 bundle here — status keys + compute only.
    engine_compute_readiness || true
  } >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mm_whiptail_textbox "Verify Upgrade Readiness" "$tmp" || true
  rm -f "$tmp"
  return 0
}

gui_enable_http() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  dp2_set_version "${TARGET_DP_VERSION}"
  local out backend_rc=0 tmp stable
  stable="$(dp2_stable_bundle_name)"
  # Engine stdout is captured below; show wait notice before long SHA256 starts.
  gui_show_sha256_wait_notice "enable-http" "$stable" \
    "Verifying the SHA256 checksum of the Phase 2 bundle before enabling HTTP distribution."
  tmp="$(mktemp)"
  set +e
  out="$(engine_enable_http_distribution 2>&1)"
  backend_rc=$?
  set -e
  printf '%s\n' "$out" >"$tmp"
  if [[ "$backend_rc" -eq 0 ]]; then
    mm_whiptail_textbox "HTTP Distribution — ENABLED" "$tmp" || true
  else
    mm_whiptail_textbox "HTTP Distribution — FAIL" "$tmp" || true
  fi
  rm -f "$tmp"
  # Backend failure is already shown; keep the main menu alive.
  return 0
}

gui_show_status() {
  load_mirror_defaults
  mm_load_gui_config
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
Target DP Version: ${TARGET_DP_VERSION}
Configuration: $(mm_status_get CONFIGURATION_READY)
R2 OS Core download: $(mm_status_get R2_OS_CORE_DOWNLOADED)
R2 OS Core checksum: $(mm_status_get R2_OS_CORE_CHECKSUM)
OS mirror readiness: $(mm_status_get OS_MIRROR_READY)
ACPS Phase 2 download: $(mm_status_get ACPS_PHASE2_DOWNLOADED)
ACPS checksum: $(mm_status_get ACPS_CHECKSUM)
Bringup drift: $(mm_status_get UPSTREAM_BRINGUP_DRIFT)
Patched bringup: $(mm_status_get PATCHED_BRINGUP_APPLIED)
Phase 2 bundle: $(mm_status_get PHASE2_BUNDLE_CHECKSUM) (entries=$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT))
HTTP distribution: $(mm_status_get HTTP_DISTRIBUTION)
Last execution result: $(mm_status_get LAST_EXECUTION_RESULT)
Log path: $(mm_status_get LOG_PATH)
OS Core Source: Cloudflare R2 — configured by installer
ACPS Server: fixed
PROJECT_ROLLBACK_SUPPORTED=NO
RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
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

gui_client_instructions() {
  load_mirror_defaults
  mm_load_gui_config
  local ver="${TARGET_DP_VERSION:-6.5.0}"
  local mirror_hint="http://<MIRROR_IP>"
  # Prefer documented default mirror if present in client scripts
  if [[ -f "${PROJECT_ROOT}/client/stage-dp-phase2.sh" ]]; then
    local def
    def="$(awk -F= '/^DEFAULT_MIRROR_URL=/{gsub(/"/,"",$2); print $2; exit}' "${PROJECT_ROOT}/client/stage-dp-phase2.sh" || true)"
    [[ -n "$def" ]] && mirror_hint="$def"
  fi
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
DP Client Upgrade Instructions
==============================

CLIENT_DOWNLOAD_SOURCE=MIRROR_SERVER_ONLY
CLIENT_R2_ACCESS=NO
CLIENT_ACPS_ACCESS=NO

Use the mirror server HTTP address only. Do not connect to Cloudflare R2 or ACPS from the DP client.

Target DP Version: ${ver}

Before upgrade — REQUIRED:
  Create a full hypervisor snapshot of the entire DP VM.
  PROJECT_ROLLBACK_SUPPORTED=NO
  OS_ROLLBACK_SUPPORTED=NO
  DP_RUNTIME_ROLLBACK_SUPPORTED=NO
  RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
  RECOVERY_TARGET=PRE_UPGRADE_UBUNTU_16_04_STATE
  INTERMEDIATE_OS_RECOVERY_SUPPORTED=NO

  Intermediate Ubuntu versions (18.04/20.04/22.04) are NOT recovery points.
  This project does not provide OS or DP rollback. Restore the hypervisor snapshot on failure.

Phase 1 — OS hop client scripts (example mirror ${mirror_hint}):
  curl -fsSO ${mirror_hint}/client/dp-offline-upgrade-xenial-to-bionic.sh
  curl -fsSO ${mirror_hint}/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256
  sha256sum -c dp-offline-upgrade-xenial-to-bionic.sh.sha256
  sudo bash ./dp-offline-upgrade-xenial-to-bionic.sh

  Repeat similarly for:
    dp-offline-upgrade-bionic-to-focal.sh
    dp-offline-upgrade-focal-to-jammy.sh
    dp-offline-upgrade-jammy-to-noble.sh

Phase 2 — stage artifacts from mirror only:
  sudo bash stage-dp-phase2.sh \\
    --source-dp-version <current-dp> \\
    --target-version ${ver} \\
    --mirror-url ${mirror_hint}

Phase 2 HTTP paths:
  ${mirror_hint}/dp-phase2/${ver}/release.env
  ${mirror_hint}/dp-phase2/${ver}/dp_bundle_${ver}-current.tar
  ${mirror_hint}/dp-phase2/${ver}/dp_bundle_${ver}-current.tar.sha256

Also used by clients:
  ${mirror_hint}/ubuntu/
  ${mirror_hint}/ubuntu-security/
  ${mirror_hint}/offline/
  ${mirror_hint}/client/
EOF
  mm_whiptail_textbox "DP Client Upgrade Instructions" "$tmp" || true
  rm -f "$tmp"
  return 0
}

cmd_mirror_manager() {
  export MM_GUI_MODE=1
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
    choice="$(mm_whiptail_menu \
      "DP Ubuntu Upgrade Mirror Manager" \
      "Single workflow: Cloudflare R2 OS Core + ACPS Phase 2

After Configuration, choose 2 to start the download.
Cancel/ESC returns here; choose 0 to Exit." \
      "1" "Configuration" \
      "2" "Download and Prepare Upgrade Files" \
      "3" "Verify Upgrade Readiness" \
      "4" "Enable HTTP Distribution" \
      "5" "Show Current Status" \
      "6" "View Logs" \
      "7" "Show DP Client Upgrade Instructions" \
      "0" "Exit")" || menu_rc=$?
    # Cancel/ESC on the main menu must NOT drop to the shell; only "0 Exit" leaves.
    if [[ "$menu_rc" -ne 0 ]]; then
      continue
    fi
    case "$choice" in
      1) gui_run_action "Configuration" gui_configuration ;;
      2) gui_run_action "Download and Prepare" gui_download_and_prepare ;;
      3) gui_run_action "Verify Upgrade Readiness" gui_verify_readiness ;;
      4) gui_run_action "Enable HTTP Distribution" gui_enable_http ;;
      5) gui_run_action "Show Current Status" gui_show_status ;;
      6) gui_run_action "View Logs" gui_view_logs ;;
      7) gui_run_action "DP Client Upgrade Instructions" gui_client_instructions ;;
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
  load_mirror_defaults
  engine_download_and_prepare
}

cmd_verify_readiness() {
  load_mirror_defaults
  mm_load_gui_config
  engine_resolve_paths
  engine_compute_readiness
}

cmd_enable_http() {
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
