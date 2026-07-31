#!/usr/bin/env bash
# scripts/lib/mirror_manager_common.sh — shared helpers for DP Upgrade Mirror Manager
# shellcheck shell=bash
set +x

if [[ -n "${MIRROR_MANAGER_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_MANAGER_COMMON_LOADED=1

MM_PROJECT_ROOT="${MM_PROJECT_ROOT:-}"
MM_MIRROR_ROOT="${MM_MIRROR_ROOT:-/var/spool/apt-mirror}"
MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-${MM_MIRROR_ROOT}/selective}"
MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT}/dp-phase2}"
MM_CLIENT_ROOT="${MM_CLIENT_ROOT:-${MM_MIRROR_ROOT}/client}"
MM_LOG_DIR="${MM_LOG_DIR:-/var/log/ubuntu-mirror-automation}"
MM_STATE_ROOT="${MM_STATE_ROOT:-/var/lib/ubuntu-mirror-automation/runs}"
MM_CONFIG_DIR="${MM_CONFIG_DIR:-/etc/ubuntu-mirror}"
MM_CONFIG_FILE="${MM_CONFIG_FILE:-${MM_CONFIG_DIR}/dp-upgrade-mirror.conf}"
MM_STATUS_FILE="${MM_STATUS_FILE:-${MM_CONFIG_DIR}/dp-upgrade-mirror.status}"
MM_LOCK_FILE="${MM_LOCK_FILE:-/run/ubuntu-mirror-manager.lock}"
MM_CACHE_ROOT="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}"
MM_VERIFY_HTTP_BASE="${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}"
MM_SKIP_ROOT_CHECK="${MM_SKIP_ROOT_CHECK:-0}"

# Fixed ACPS endpoint (not user-editable). Credentials come from GUI config only.
ACPS_BASE_URL_FIXED="${ACPS_BASE_URL_FIXED:-https://acps.stellarcyber.ai/provision/aelladeb_py3}"

# Cloudflare R2 OS Core package URL — single code constant (custom domain).
# Checksum sidecar is derived as "${OS_CORE_R2_URL}.sha256" (no separate constant).
# Tests may override via environment: OS_CORE_R2_URL=http://127.0.0.1:<port>/pkg.tar
# shellcheck disable=SC2034
OS_CORE_R2_URL_CONSTANT="https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar"
: "${OS_CORE_R2_URL:=${OS_CORE_R2_URL_CONSTANT}}"

MM_LOCK_FD=""
MM_LOCK_HELD=0
MM_RUN_ID="${MM_RUN_ID:-}"
MM_LOG_FILE="${MM_LOG_FILE:-}"
MM_STATE_DIR="${MM_STATE_DIR:-}"
MM_DRY_RUN="${MM_DRY_RUN:-0}"
MM_FILES_CHANGED="${MM_FILES_CHANGED:-NO}"
TARGET_DP_VERSION="${TARGET_DP_VERSION:-6.5.0}"
ACPS_USERNAME="${ACPS_USERNAME:-}"
ACPS_PASSWORD="${ACPS_PASSWORD:-}"

mm_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mm_run_id() { date -u +%Y%m%dT%H%M%SZ; }

mm_redact() {
  sed -E \
    -e 's/(ACPS_PASSWORD|ACPS_PASS|ACPS_TOKEN|PASSWORD|TOKEN|PASSWD)=[^[:space:]]+/\1=***/Ig' \
    -e 's/(-u[[:space:]]+)[^[:space:]]+/\1***/g' \
    -e 's#(://[^:/@]+:)[^@/]+@#\1***@#g' \
    -e 's/Authorization:[[:space:]]*Basic[[:space:]]+[^[:space:]]+/Authorization: Basic ***/Ig' \
    -e 's/Authorization:[[:space:]]*Bearer[[:space:]]+[^[:space:]]+/Authorization: Bearer ***/Ig'
}

mm_format_bytes() {
  local b="${1:-0}"
  if ! [[ "$b" =~ ^[0-9]+$ ]]; then
    printf '%s' "$b"
    return 0
  fi
  if [[ "$b" -ge $((1024 * 1024 * 1024)) ]]; then
    awk -v n="$b" 'BEGIN { printf "%.2f GiB", n / (1024*1024*1024) }'
  elif [[ "$b" -ge $((1024 * 1024)) ]]; then
    awk -v n="$b" 'BEGIN { printf "%.1f MiB", n / (1024*1024) }'
  elif [[ "$b" -ge 1024 ]]; then
    awk -v n="$b" 'BEGIN { printf "%.1f KiB", n / 1024 }'
  else
    printf '%s B' "$b"
  fi
}

mm_format_rate() {
  local bps="${1:-0}"
  if ! [[ "$bps" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bps"
    return 0
  fi
  printf '%s/s' "$(mm_format_bytes "$bps")"
}

mm_log() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(mm_ts) [${level}] ${msg}"
  line="$(printf '%s\n' "$line" | mm_redact)"
  case "$level" in
    ERROR|WARN) printf '%s\n' "$line" >&2 ;;
    *) printf '%s\n' "$line" ;;
  esac
  # Always mirror progress to the controlling terminal so GUI capture cannot hide it.
  if [[ "${MM_LIVE_PROGRESS:-0}" == "1" ]]; then
    if { printf '%s\n' "$line" >/dev/tty; } 2>/dev/null; then
      :
    fi
  fi
  if [[ -n "${MM_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$MM_LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$MM_LOG_FILE" 2>/dev/null || true
  fi
}
mm_info() { mm_log INFO "$*"; }
mm_warn() { mm_log WARN "$*"; }
mm_error() { mm_log ERROR "$*"; }
mm_ok() { mm_log OK "$*"; }
mm_die() { mm_error "$*"; exit 1; }

mm_progress_line() {
  # Human-readable download progress for operators watching the terminal.
  local label="$1" downloaded="$2" expected="$3" elapsed="$4" rate="$5"
  local pct="--" down_h exp_h rate_h
  down_h="$(mm_format_bytes "$downloaded")"
  if [[ "$expected" =~ ^[0-9]+$ && "$expected" -gt 0 ]]; then
    pct=$((downloaded * 100 / expected))
    exp_h="$(mm_format_bytes "$expected")"
  else
    exp_h="unknown"
  fi
  if [[ "$rate" =~ ^[0-9]+$ ]]; then
    rate_h="$(mm_format_rate "$rate")"
  else
    rate_h="--"
  fi
  mm_info "PROGRESS ${label}: ${down_h} / ${exp_h} (${pct}%) elapsed=${elapsed}s rate=${rate_h}"
}

mm_require_root() {
  if [[ "${MM_SKIP_ROOT_CHECK}" == "1" ]]; then
    return 0
  fi
  [[ "${EUID}" -eq 0 ]] || mm_die "ROOT_REQUIRED=FAIL"
  mm_ok "ROOT_REQUIRED=PASS"
}

mm_require_cmds() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    mm_die "COMMANDS_MISSING=FAIL missing=${missing[*]}"
  fi
}

mm_validate_dp_version() {
  local ver="$1"
  [[ -n "$ver" ]] || mm_die "TARGET_DP_VERSION=FAIL empty"
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    mm_die "TARGET_DP_VERSION=FAIL invalid=${ver}"
  fi
}

mm_assert_regular_file() {
  local path="$1"
  local label="${2:-$path}"
  [[ -e "$path" ]] || mm_die "FILE_MISSING=FAIL file=${label}"
  if [[ -L "$path" ]]; then
    mm_die "SYMLINK_FORBIDDEN=FAIL file=${label}"
  fi
  [[ -f "$path" ]] || mm_die "NOT_REGULAR_FILE=FAIL file=${label}"
}

mm_load_gui_config() {
  TARGET_DP_VERSION="${TARGET_DP_VERSION:-6.5.0}"
  ACPS_USERNAME="${ACPS_USERNAME:-}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-}"
  if [[ -f "${MM_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "${MM_CONFIG_FILE}"
    set +a
  fi
  TARGET_DP_VERSION="${TARGET_DP_VERSION:-6.5.0}"
  ACPS_USERNAME="${ACPS_USERNAME:-${ACPS_USER:-}}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-${ACPS_PASS:-}}"
  ACPS_BASE_URL="${ACPS_BASE_URL_FIXED}"
}

mm_save_gui_config() {
  mkdir -p "$(dirname "$MM_CONFIG_FILE")"
  local tmp old_umask
  tmp="$(mktemp)"
  old_umask="$(umask)"
  umask 077
  cat >"$tmp" <<EOF
# DP Upgrade Mirror Manager configuration (managed by GUI)
# Do not store secrets in world-readable locations.
TARGET_DP_VERSION=${TARGET_DP_VERSION}
ACPS_USERNAME=${ACPS_USERNAME}
ACPS_PASSWORD=${ACPS_PASSWORD}
EOF
  umask "$old_umask"
  chmod 600 "$tmp"
  mv -f "$tmp" "$MM_CONFIG_FILE"
  chmod 600 "$MM_CONFIG_FILE"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$MM_CONFIG_FILE" 2>/dev/null || true
  fi
  mm_ok "CONFIGURATION_SAVED=PASS path=${MM_CONFIG_FILE}"
}

mm_config_ready() {
  mm_load_gui_config
  [[ -n "${TARGET_DP_VERSION}" ]] || return 1
  mm_validate_dp_version "$TARGET_DP_VERSION" 2>/dev/null || return 1
  [[ -n "${ACPS_USERNAME}" ]] || return 1
  [[ -n "${ACPS_PASSWORD}" ]] || return 1
  return 0
}

mm_r2_url_configured() {
  [[ -n "${OS_CORE_R2_URL:-}" ]]
}

mm_status_set() {
  local key="$1"
  local val="$2"
  local f="${MM_STATUS_FILE}"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  if grep -q "^${key}=" "$f" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -F= -v k="$key" -v v="$val" 'BEGIN{done=0} $1==k && !done {print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$f" >"$tmp"
    mv -f "$tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >>"$f"
  fi
}

mm_status_get() {
  local key="$1"
  local f="${MM_STATUS_FILE}"
  [[ -f "$f" ]] || { printf ''; return 0; }
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' "$f"
}

mm_state_init() {
  MM_RUN_ID="${MM_RUN_ID:-$(mm_run_id)}"
  MM_STATE_DIR="${MM_STATE_ROOT}/${MM_RUN_ID}"
  MM_LOG_FILE="${MM_LOG_DIR}/mirror-manager-${MM_RUN_ID}.log"
  mkdir -p "$MM_STATE_DIR" "$(dirname "$MM_LOG_FILE")"
  {
    printf 'INSTALLATION_MODE_COUNT=1\n'
    printf 'OS_CORE_SOURCE=R2\n'
    printf 'DP_PHASE2_SOURCE=ACPS\n'
    printf 'CLIENT_DOWNLOAD_SOURCE=MIRROR_SERVER_ONLY\n'
    printf 'PROJECT_ROLLBACK_SUPPORTED=NO\n'
    printf 'RUN_ID=%s\n' "$MM_RUN_ID"
    printf 'STARTED_AT=%s\n' "$(mm_ts)"
  } >"${MM_STATE_DIR}/state.env"
  cp -f "${MM_STATE_DIR}/state.env" "${MM_STATE_DIR}/report.env"
}

mm_state_set() {
  local key="$1"
  local val="$2"
  mm_status_set "$key" "$val"
  local f="${MM_STATE_DIR:-}/state.env"
  [[ -n "${MM_STATE_DIR:-}" ]] || return 0
  mkdir -p "$MM_STATE_DIR"
  if [[ -f "$f" ]] && grep -q "^${key}=" "$f" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -F= -v k="$key" -v v="$val" 'BEGIN{done=0} $1==k && !done {print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$f" >"$tmp"
    mv -f "$tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >>"$f"
  fi
  cp -f "$f" "${MM_STATE_DIR}/report.env" 2>/dev/null || true
}

mm_acquire_install_lock() {
  local new_fd
  mkdir -p "$(dirname "$MM_LOCK_FILE")"
  exec {new_fd}>"$MM_LOCK_FILE"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    mm_die "INSTALL_LOCK=BUSY path=${MM_LOCK_FILE}"
  fi
  MM_LOCK_FD="$new_fd"
  MM_LOCK_HELD=1
  printf 'pid=%s\nstarted_at=%s\n' "$$" "$(mm_ts)" >"${MM_LOCK_FILE}.meta"
  mm_ok "INSTALL_LOCK=PASS"
}

mm_release_install_lock() {
  if [[ "${MM_LOCK_HELD:-0}" == "1" && -n "${MM_LOCK_FD:-}" ]]; then
    flock -u "$MM_LOCK_FD" 2>/dev/null || true
    eval "exec ${MM_LOCK_FD}>&-" 2>/dev/null || true
    MM_LOCK_FD=""
    MM_LOCK_HELD=0
  fi
  rm -f "${MM_LOCK_FILE}.meta" 2>/dev/null || true
}

mm_free_bytes() {
  local path="$1"
  if [[ -n "${MM_MOCK_AVAILABLE_BYTES:-}" ]]; then
    printf '%s\n' "$MM_MOCK_AVAILABLE_BYTES"
    return 0
  fi
  mkdir -p "$path" 2>/dev/null || true
  local kib
  kib="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ "$kib" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((kib * 1024))"
    return 0
  fi
  df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

mm_file_bytes() {
  local f="$1"
  if [[ -f "$f" ]]; then
    stat -c%s "$f"
  else
    printf '0'
  fi
}

mm_fs_size_bytes() {
  local path="$1"
  if [[ -n "${MM_MOCK_FS_SIZE_BYTES:-}" ]]; then
    printf '%s\n' "$MM_MOCK_FS_SIZE_BYTES"
    return 0
  fi
  mkdir -p "$path" 2>/dev/null || true
  local kib
  kib="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $2}')"
  if [[ "$kib" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$((kib * 1024))"
    return 0
  fi
  df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $2}'
}

mm_calc_disk_requirements() {
  # Preflight runs after the R2 package is already on disk, so package bytes are
  # reflected in AVAILABLE_BYTES and must not be double-counted.
  #
  # Same-filesystem optimized peak (concurrent physical data):
  #   OS payload materialize temp + ACPS source (one tree) + bundle .new output
  #   + brief existing-final replacement overhead + metadata + safety reserve.
  # Full cache→work→dp-build→bundle re-copies are not part of this model.
  local os_pkg_bytes payload_bytes acps_bytes ver existing_bundle
  local reserve_floor_bytes reserve_pct_bytes fs_size_bytes
  os_pkg_bytes="${OS_CORE_PACKAGE_BYTES:-0}"
  payload_bytes="${OS_CORE_PAYLOAD_BYTES:-0}"
  acps_bytes="${ACPS_EXPECTED_BYTES:-0}"
  [[ "$os_pkg_bytes" =~ ^[0-9]+$ ]] || os_pkg_bytes=0
  [[ "$payload_bytes" =~ ^[0-9]+$ ]] || payload_bytes=0
  [[ "$acps_bytes" =~ ^[0-9]+$ ]] || acps_bytes=0

  DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  DISK_PREFLIGHT_ACPS_SOURCE_BYTES=$acps_bytes
  # Bundle output is approximately the ACPS source tree size (9-file tar).
  DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=$acps_bytes
  DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=$((payload_bytes + (512 * 1024 * 1024)))

  DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=0
  ver="${TARGET_DP_VERSION:-${DP_PHASE2_VERSION:-6.5.0}}"
  existing_bundle="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT:-/var/spool/apt-mirror}/dp-phase2}/${ver}/dp_bundle_${ver}-current.tar"
  if [[ -f "$existing_bundle" ]]; then
    DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES="$(mm_file_bytes "$existing_bundle")"
    [[ "$DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES" =~ ^[0-9]+$ ]] \
      || DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=0
  fi

  reserve_floor_bytes=$((10 * 1024 * 1024 * 1024))
  if [[ -n "${MM_MOCK_SAFETY_RESERVE_BYTES:-}" ]]; then
    DISK_PREFLIGHT_SAFETY_RESERVE_BYTES="$MM_MOCK_SAFETY_RESERVE_BYTES"
  else
    fs_size_bytes="$(mm_fs_size_bytes "${MM_MIRROR_ROOT}")"
    [[ "$fs_size_bytes" =~ ^[0-9]+$ ]] || fs_size_bytes=0
    reserve_pct_bytes=$((fs_size_bytes / 10))
    if [[ "$reserve_pct_bytes" -gt "$reserve_floor_bytes" ]]; then
      DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_pct_bytes
    else
      DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_floor_bytes
    fi
  fi
  [[ "$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES" =~ ^[0-9]+$ ]] \
    || DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=$reserve_floor_bytes

  # Compat aliases used by older logs/tests.
  OS_MATERIALIZE_TEMP_BYTES=$payload_bytes
  DP_BUILD_TEMP_BYTES=$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
  SAFETY_MARGIN_BYTES=$DISK_PREFLIGHT_SAFETY_RESERVE_BYTES

  DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=$((
    DISK_PREFLIGHT_R2_REQUIRED_BYTES
    + DISK_PREFLIGHT_ACPS_SOURCE_BYTES
    + DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
    + DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES
    + DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES
    + DISK_PREFLIGHT_SAFETY_RESERVE_BYTES
  ))
  TOTAL_REQUIRED_BYTES=$DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES

  DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES="$(mm_free_bytes "${MM_MIRROR_ROOT}")"
  AVAILABLE_BYTES="$DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES"
  [[ -n "$AVAILABLE_BYTES" && "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] \
    || mm_die "DISK_PREFLIGHT=FAIL cannot_read_df"

  if [[ "$AVAILABLE_BYTES" -lt "$TOTAL_REQUIRED_BYTES" ]]; then
    DISK_PREFLIGHT_RESULT=FAIL
    DISK_PREFLIGHT=FAIL
  else
    DISK_PREFLIGHT_RESULT=PASS
    DISK_PREFLIGHT=PASS
  fi

  mm_info "OS_CORE_PACKAGE_BYTES=${os_pkg_bytes}"
  mm_info "OS_CORE_PAYLOAD_BYTES=${payload_bytes}"
  mm_info "ACPS_EXPECTED_BYTES=${acps_bytes}"
  mm_info "OS_MATERIALIZE_TEMP_BYTES=${OS_MATERIALIZE_TEMP_BYTES}"
  mm_info "DP_BUILD_TEMP_BYTES=${DP_BUILD_TEMP_BYTES}"
  mm_info "DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES=${DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_R2_REQUIRED_BYTES=${DISK_PREFLIGHT_R2_REQUIRED_BYTES}"
  mm_info "DISK_PREFLIGHT_ACPS_SOURCE_BYTES=${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
  mm_info "DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=${DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES}"
  mm_info "DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=${DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=${DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=${DISK_PREFLIGHT_SAFETY_RESERVE_BYTES}"
  mm_info "DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=${DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES}"
  mm_info "TOTAL_REQUIRED_BYTES=${TOTAL_REQUIRED_BYTES}"
  mm_info "AVAILABLE_BYTES=${AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_RESULT=${DISK_PREFLIGHT_RESULT}"
  mm_info "DISK_PREFLIGHT=${DISK_PREFLIGHT}"
  [[ "$DISK_PREFLIGHT" == "PASS" ]] || mm_die "DISK_PREFLIGHT=FAIL"
}

mm_mark_changed() {
  MM_FILES_CHANGED=YES
  mm_state_set FILES_CHANGED YES
}

mm_configured_label() {
  local val="$1"
  if [[ -n "$val" ]]; then
    printf 'configured'
  else
    printf 'not configured'
  fi
}

# Required HTTP client artifacts (must be real files; empty directory is FAIL)
MM_CLIENT_REQUIRED_FILES=(
  dp-offline-upgrade-xenial-to-bionic.sh
  dp-offline-upgrade-xenial-to-bionic.sh.sha256
  dp-offline-upgrade-bionic-to-focal.sh
  dp-offline-upgrade-bionic-to-focal.sh.sha256
  dp-offline-upgrade-focal-to-jammy.sh
  dp-offline-upgrade-focal-to-jammy.sh.sha256
  dp-offline-upgrade-jammy-to-noble.sh
  dp-offline-upgrade-jammy-to-noble.sh.sha256
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
)

mm_client_files_ready() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local f
  [[ -d "$root" ]] || return 1
  for f in "${MM_CLIENT_REQUIRED_FILES[@]}"; do
    [[ -f "${root}/${f}" ]] || return 1
  done
  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    stage-dp-phase2.sh
  do
    (cd "$root" && sha256sum -c "${f}.sha256" >/dev/null 2>&1) || return 1
  done
  return 0
}

mm_check_client_files_ready() {
  if mm_client_files_ready "${MM_CLIENT_ROOT}"; then
    mm_state_set CLIENT_FILES_READY PASS
    mm_ok "CLIENT_FILES_READY=PASS"
    return 0
  fi
  mm_state_set CLIENT_FILES_READY FAIL
  mm_error "CLIENT_FILES_READY=FAIL (required scripts/checksums missing under ${MM_CLIENT_ROOT})"
  return 1
}
