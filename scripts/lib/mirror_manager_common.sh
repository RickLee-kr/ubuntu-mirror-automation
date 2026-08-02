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

# Fixed Phase 2 target — not user-editable in production.
# Tests may set MM_ALLOW_TARGET_OVERRIDE=1 to exercise non-6.5.0 paths.
PHASE2_TARGET_VERSION="6.5.0"
TARGET_DP_VERSION="${PHASE2_TARGET_VERSION}"

# FULL = Ubuntu 16.04→24.04 OS hops + Phase 2
# PHASE2_ONLY = DP already on Ubuntu 24.04; Phase 2 artifacts only
PREPARATION_MODE="${PREPARATION_MODE:-FULL}"

ACPS_USERNAME="${ACPS_USERNAME:-}"
ACPS_PASSWORD="${ACPS_PASSWORD:-}"

mm_force_phase2_target() {
  if [[ "${MM_ALLOW_TARGET_OVERRIDE:-0}" == "1" ]]; then
    TARGET_DP_VERSION="${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}"
  else
    TARGET_DP_VERSION="${PHASE2_TARGET_VERSION}"
  fi
  DP_PHASE2_VERSION="${TARGET_DP_VERSION}"
}

mm_normalize_preparation_mode() {
  case "${PREPARATION_MODE:-}" in
    FULL|PHASE2_ONLY) ;;
    full) PREPARATION_MODE=FULL ;;
    phase2_only|PHASE2|phase2) PREPARATION_MODE=PHASE2_ONLY ;;
    *) PREPARATION_MODE=FULL ;;
  esac
}

mm_preparation_mode_label() {
  mm_normalize_preparation_mode
  case "${PREPARATION_MODE}" in
    PHASE2_ONLY) printf 'Phase 2 Only' ;;
    *) printf 'Full OS Upgrade + Phase 2' ;;
  esac
}

mm_is_phase2_only() {
  mm_normalize_preparation_mode
  [[ "${PREPARATION_MODE}" == "PHASE2_ONLY" ]]
}

mm_config_footer_text() {
  cat <<'EOF'
Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target:      6.5.0 고정
DP OS version: 16.04

If the DP is already running Ubuntu 24.04, select Phase 2 Only.
EOF
}

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
    [[ "$pct" -gt 100 ]] && pct=100
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

# Long-running Download/Prepare steps: heartbeat every N seconds (tests may set 1).
MM_LONG_STEP_HEARTBEAT_SEC="${MM_LONG_STEP_HEARTBEAT_SEC:-30}"

mm_long_step_heartbeat_seconds() {
  local hb="${MM_LONG_STEP_HEARTBEAT_SEC:-30}"
  if ! [[ "$hb" =~ ^[1-9][0-9]*$ ]]; then
    hb=30
  fi
  printf '%s\n' "$hb"
}

mm_set_phase() {
  local phase="$1"
  mm_info "DP_PHASE=${phase}"
  mm_info "Phase: ${phase}"
}

mm_human_lines() {
  # Emit one human-readable INFO line per argument (no adjacent duplicates).
  local line prev=""
  for line in "$@"; do
    [[ -n "$line" ]] || continue
    [[ "$line" == "$prev" ]] && continue
    mm_info "$line"
    prev="$line"
  done
}

# Last successful command stdout from mm_bg_with_heartbeat (not mixed into logs).
MM_LONG_STEP_LAST_STDOUT=""
MM_LONG_STEP_LAST_ELAPSED=0

# Background a command with heartbeat only. Caller emits START/COMPLETE.
# Sets MM_LONG_STEP_LAST_STDOUT and MM_LONG_STEP_LAST_ELAPSED. Preserves child rc.
# Usage: mm_bg_with_heartbeat EVENT_PREFIX "k=v ..." "human still..." -- cmd args...
mm_bg_with_heartbeat() {
  local event_prefix="$1"
  local fields="$2"
  local human_still="${3:-Still working...}"
  shift 3
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_bg_with_heartbeat: expected -- before command"
  fi
  shift

  local start_ts hb_secs hb_pid="" cmd_pid="" rc=0 elapsed
  local out err last_hb_line="" hb_line
  MM_LONG_STEP_LAST_STDOUT=""
  MM_LONG_STEP_LAST_ELAPSED=0
  start_ts="$(date +%s)"
  hb_secs="$(mm_long_step_heartbeat_seconds)"
  out="$(mktemp)"
  err="$(mktemp)"

  "$@" >"$out" 2>"$err" &
  cmd_pid=$!

  _mm_hb_cleanup() {
    kill "$cmd_pid" 2>/dev/null || true
    kill "$hb_pid" 2>/dev/null || true
  }
  trap '_mm_hb_cleanup' INT TERM

  (
    while kill -0 "$cmd_pid" 2>/dev/null; do
      sleep "$hb_secs" || break
      kill -0 "$cmd_pid" 2>/dev/null || break
      elapsed=$(( $(date +%s) - start_ts ))
      hb_line="${event_prefix}_HEARTBEAT ${fields} elapsed=${elapsed}s status=running"
      if [[ "$hb_line" != "$last_hb_line" ]]; then
        mm_info "$hb_line"
        mm_human_lines \
          "$human_still" \
          "Elapsed: ${elapsed} seconds" \
          "The program is running normally."
        last_hb_line="$hb_line"
      fi
    done
  ) &
  hb_pid=$!

  if wait "$cmd_pid"; then
    rc=0
  else
    rc=$?
  fi

  if [[ -n "$hb_pid" ]]; then
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
  fi
  trap - INT TERM

  elapsed=$(( $(date +%s) - start_ts ))
  MM_LONG_STEP_LAST_ELAPSED="$elapsed"
  if [[ "$rc" -eq 0 ]]; then
    MM_LONG_STEP_LAST_STDOUT="$(cat "$out")"
    rm -f "$out" "$err"
    return 0
  fi
  mm_redact <"$err" >&2 || true
  rm -f "$out" "$err"
  return "$rc"
}

# Run a command with START / HEARTBEAT / COMPLETE|FAIL. Preserves child rc.
# Usage: mm_run_with_heartbeat EVENT_PREFIX "k=v ..." "human still..." -- cmd args...
mm_run_with_heartbeat() {
  local event_prefix="$1"
  local fields="$2"
  local human_still="${3:-Still working...}"
  shift 3
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_run_with_heartbeat: expected -- before command"
  fi
  shift
  local rc=0
  mm_info "${event_prefix}_START ${fields}"
  # Do not toggle set -e here — it would leak into the caller.
  mm_bg_with_heartbeat "$event_prefix" "$fields" "$human_still" -- "$@" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
    return 0
  fi
  mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
  return "$rc"
}

# Like mm_run_with_heartbeat but also reports growing output-file size as progress.
# Usage: mm_run_with_file_progress EVENT_PREFIX "k=v" OUT_FILE EXPECTED_BYTES "human still" -- cmd...
mm_run_with_file_progress() {
  local event_prefix="$1"
  local fields="$2"
  local out_file="$3"
  local expected_bytes="$4"
  local human_still="${5:-Still working...}"
  shift 5
  if [[ "${1:-}" != "--" ]]; then
    mm_die "mm_run_with_file_progress: expected -- before command"
  fi
  shift

  local start_ts hb_secs hb_pid="" cmd_pid="" rc=0 elapsed
  local err last_prog="" written pct written_h expected_h prog_line
  start_ts="$(date +%s)"
  hb_secs="$(mm_long_step_heartbeat_seconds)"
  err="$(mktemp)"

  mm_info "${event_prefix}_START ${fields}"

  "$@" 2>"$err" &
  cmd_pid=$!

  _mm_prog_cleanup() {
    kill "$cmd_pid" 2>/dev/null || true
    kill "$hb_pid" 2>/dev/null || true
  }
  trap '_mm_prog_cleanup' INT TERM

  (
    while kill -0 "$cmd_pid" 2>/dev/null; do
      sleep "$hb_secs" || break
      kill -0 "$cmd_pid" 2>/dev/null || break
      elapsed=$(( $(date +%s) - start_ts ))
      written=0
      [[ -f "$out_file" ]] && written="$(stat -c%s "$out_file" 2>/dev/null || echo 0)"
      pct="UNKNOWN"
      if [[ "$expected_bytes" =~ ^[0-9]+$ && "$expected_bytes" -gt 0 ]]; then
        pct=$((written * 100 / expected_bytes))
        [[ "$pct" -gt 100 ]] && pct=100
      fi
      prog_line="${event_prefix}_PROGRESS written_bytes=${written} expected_bytes=${expected_bytes:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s"
      [[ "$prog_line" == "$last_prog" ]] && continue
      last_prog="$prog_line"
      mm_info "$prog_line"
      written_h="$(mm_format_bytes "$written")"
      if [[ "$expected_bytes" =~ ^[0-9]+$ && "$expected_bytes" -gt 0 ]]; then
        expected_h="$(mm_format_bytes "$expected_bytes")"
        mm_info "PROGRESS PHASE2 BUNDLE: ${written_h} / approximately ${expected_h} (${pct}%) elapsed=${elapsed}s"
      else
        mm_info "PROGRESS PHASE2 BUNDLE: ${written_h} / approximately unknown (--) elapsed=${elapsed}s"
      fi
      mm_human_lines "$human_still" "Elapsed: ${elapsed} seconds" "The program is running normally."
    done
  ) &
  hb_pid=$!

  if wait "$cmd_pid"; then
    rc=0
  else
    rc=$?
  fi

  if [[ -n "$hb_pid" ]]; then
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
  fi
  trap - INT TERM

  elapsed=$(( $(date +%s) - start_ts ))
  if [[ "$rc" -eq 0 ]]; then
    written=0
    [[ -f "$out_file" ]] && written="$(stat -c%s "$out_file" 2>/dev/null || echo 0)"
    mm_ok "${event_prefix}_COMPLETE ${fields} actual_bytes=${written} elapsed=${elapsed}s result=PASS"
    rm -f "$err"
    return 0
  fi
  mm_redact <"$err" >&2 || true
  mm_error "${event_prefix}_FAIL ${fields} elapsed=${elapsed}s result=FAIL rc=${rc}"
  rm -f "$err"
  return "$rc"
}

# Write "HEX  basename" sidecar with heartbeat around the full-file read.
mm_sha256_write_sidecar_logged() {
  local file="$1"
  local sidecar="$2"
  local event_prefix="$3"
  local fields="$4"
  local human_still="$5"
  local base hex rc=0
  base="$(basename "$file")"
  mm_info "${event_prefix}_START ${fields}"
  mm_human_lines \
    "Calculating the SHA256 checksum of the newly created Phase 2 bundle." \
    "The bundle is large, so this step may take 5–10 minutes." \
    "The program is still running normally." \
    "Please wait and do not interrupt the process."
  mm_bg_with_heartbeat "$event_prefix" "$fields" \
    "Still calculating Phase 2 bundle SHA256..." -- sha256sum "$file" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
    return "$rc"
  fi
  hex="$(printf '%s\n' "$MM_LONG_STEP_LAST_STDOUT" | awk '{print $1; exit}')"
  [[ -n "$hex" ]] || {
    mm_error "${event_prefix}_FAIL ${fields} reason=empty_hash"
    return 1
  }
  printf '%s  %s\n' "$hex" "$base" >"$sidecar" || {
    mm_error "${event_prefix}_FAIL ${fields} reason=sidecar_write"
    return 1
  }
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
  return 0
}

# Verify data+sidecar SHA256 with labeled START/HEARTBEAT/COMPLETE.
# Optional 5th arg: extra fields (e.g. operation=enable-http).
mm_verify_sha256_pair_logged() {
  local data_file="$1"
  local checksum_file="$2"
  local event_prefix="$3"
  local human_still="${4:-Still verifying SHA256...}"
  local extra_fields="${5:-}"
  local expected actual bytes fields rc=0
  expected="$(dp2_read_hash_field "$checksum_file")"
  dp2_validate_sha256_hex "$expected" || {
    mm_error "${event_prefix}_FAIL file=$(basename "$data_file") reason=bad_hash_format"
    return 1
  }
  bytes="$(stat -c%s "$data_file" 2>/dev/null || echo 0)"
  fields="bundle=${data_file} file=$(basename "$data_file") algorithm=SHA256 bytes=${bytes}"
  # Prefer shorter fields when path is long — keep basename form for ACPS.
  if [[ "$event_prefix" == ACPS_CHECKSUM_VERIFY ]]; then
    fields="file=$(basename "$data_file") algorithm=SHA256 bytes=${bytes}"
  elif [[ "$event_prefix" == PHASE2_FINAL_SHA256_VERIFY ]]; then
    fields="bundle=${data_file} bytes=${bytes}"
  elif [[ "$event_prefix" == SHA256_VERIFICATION ]]; then
    fields="file=$(basename "$data_file") bytes=${bytes} algorithm=SHA256"
  fi
  if [[ -n "$extra_fields" ]]; then
    fields="${extra_fields} ${fields}"
  fi
  mm_info "${event_prefix}_START ${fields}"
  mm_bg_with_heartbeat "$event_prefix" "$fields" "$human_still" -- sha256sum "$data_file" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    mm_error "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
    return "$rc"
  fi
  actual="$(printf '%s\n' "$MM_LONG_STEP_LAST_STDOUT" | awk '{print $1; exit}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "SHA256_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
    mm_error "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL"
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL"
    return 1
  fi
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
  if [[ -n "$extra_fields" ]]; then
    mm_ok "SHA256_VERIFY=PASS ${extra_fields} file=$(basename "$data_file")"
  else
    mm_ok "SHA256_VERIFY=PASS file=$(basename "$data_file")"
  fi
  return 0
}

# Verify SHA1 pair with explicit algorithm label (no SHA256 confusion).
mm_verify_sha1_pair_logged() {
  local data_file="$1"
  local checksum_file="$2"
  local event_prefix="${3:-ACPS_CHECKSUM_VERIFY}"
  local expected actual bytes fields start_ts elapsed
  expected="$(dp2_read_hash_field "$checksum_file")"
  dp2_validate_sha1_hex "$expected" || {
    mm_error "${event_prefix}_FAIL file=$(basename "$data_file") algorithm=SHA1 reason=bad_hash_format"
    return 1
  }
  bytes="$(stat -c%s "$data_file" 2>/dev/null || echo 0)"
  fields="file=$(basename "$data_file") algorithm=SHA1 bytes=${bytes}"
  start_ts="$(date +%s)"
  mm_info "${event_prefix}_START ${fields}"
  mm_human_lines "Verifying SHA1 checksum of $(basename "$data_file")."
  actual="$(sha1sum "$data_file" | awk '{print $1}')"
  elapsed=$(( $(date +%s) - start_ts ))
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "SHA1_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${elapsed}s result=FAIL"
    return 1
  fi
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${elapsed}s result=PASS"
  mm_ok "SHA1_VERIFY=PASS file=$(basename "$data_file")"
  return 0
}

# ACPS payload checksums with correct SHA1/SHA256 labels and heartbeat on images tar.
mm_acps_verify_payload_checksums() {
  local files_dir="$1"
  local ver="${DP_PHASE2_VERSION}"
  local img bytes img_h
  mm_set_phase "Verifying ACPS Checksums"
  mm_verify_sha1_pair_logged \
    "${files_dir}/aelladeb_py3_common.tar.gz" \
    "${files_dir}/aelladeb_py3_common.tar.gz.sha1" \
    || return 1
  mm_verify_sha1_pair_logged \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb" \
    "${files_dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1" \
    || return 1
  mm_verify_sha1_pair_logged \
    "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" \
    "${files_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
    || return 1
  img="${files_dir}/images-${ver}.tar"
  bytes="$(stat -c%s "$img" 2>/dev/null || echo 0)"
  img_h="$(mm_format_bytes "$bytes")"
  mm_human_lines \
    "Verifying SHA256 checksum of images-${ver}.tar." \
    "This file is approximately ${img_h}." \
    "Verification may take 5–10 minutes depending on disk performance." \
    "The program is still running normally." \
    "Please wait and do not interrupt the process."
  mm_verify_sha256_pair_logged \
    "$img" \
    "${img}.sha256" \
    "ACPS_CHECKSUM_VERIFY" \
    "Still verifying images-${ver}.tar SHA256..." \
    || return 1
  return 0
}

mm_require_root() {
  if [[ "${MM_SKIP_ROOT_CHECK}" == "1" ]]; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    # Operator-facing guidance (official entry is always sudo).
    cat >&2 <<'EOF'
This command requires sudo.
Run: sudo ubuntu-offline-mirror mirror-manager
EOF
    mm_die "ROOT_REQUIRED=FAIL"
  fi
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
  PREPARATION_MODE="${PREPARATION_MODE:-FULL}"
  ACPS_USERNAME="${ACPS_USERNAME:-}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-}"
  MIRROR_HTTP_URL="${MIRROR_HTTP_URL:-}"
  if [[ -f "${MM_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "${MM_CONFIG_FILE}"
    set +a
  fi
  # Legacy version fields from older configs are ignored (never required).
  unset CURRENT_DP_VERSION SOURCE_DP_VERSION 2>/dev/null || true
  mm_normalize_preparation_mode
  mm_force_phase2_target
  ACPS_USERNAME="${ACPS_USERNAME:-${ACPS_USER:-}}"
  ACPS_PASSWORD="${ACPS_PASSWORD:-${ACPS_PASS:-}}"
  MIRROR_HTTP_URL="${MIRROR_HTTP_URL:-}"
  ACPS_BASE_URL="${ACPS_BASE_URL_FIXED}"
}

mm_save_gui_config() {
  local prev_mode="" cmd_file
  if [[ -f "${MM_CONFIG_FILE}" ]]; then
    prev_mode="$(awk -F= '/^PREPARATION_MODE=/{print $2; exit}' "${MM_CONFIG_FILE}" 2>/dev/null || true)"
  fi
  mm_normalize_preparation_mode
  mm_force_phase2_target
  mkdir -p "$(dirname "$MM_CONFIG_FILE")"
  local tmp old_umask
  tmp="$(mktemp)"
  old_umask="$(umask)"
  umask 077
  cat >"$tmp" <<EOF
# DP Upgrade Mirror Manager configuration (managed by GUI)
# Do not store secrets in world-readable locations.
# Phase 2 target is fixed at ${PHASE2_TARGET_VERSION} (not user-editable).
PREPARATION_MODE=${PREPARATION_MODE}
ACPS_USERNAME=${ACPS_USERNAME}
ACPS_PASSWORD=${ACPS_PASSWORD}
MIRROR_HTTP_URL=${MIRROR_HTTP_URL:-}
EOF
  umask "$old_umask"
  chmod 600 "$tmp"
  mv -f "$tmp" "$MM_CONFIG_FILE"
  chmod 600 "$MM_CONFIG_FILE"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$MM_CONFIG_FILE" 2>/dev/null || true
  fi
  # Mode change invalidates previously generated client commands.
  if [[ -n "$prev_mode" && "$prev_mode" != "${PREPARATION_MODE}" ]]; then
    cmd_file="$(mm_client_commands_file)"
    if [[ -f "$cmd_file" ]]; then
      rm -f "$cmd_file" 2>/dev/null || true
      mm_info "CLIENT_COMMANDS_STALE=YES reason=preparation_mode_changed old=${prev_mode} new=${PREPARATION_MODE}"
    fi
    mm_status_set CLIENT_COMMANDS_MODE ""
  fi
  mm_ok "CONFIGURATION_SAVED=PASS path=${MM_CONFIG_FILE} mode=${PREPARATION_MODE}"
}

# Public HTTP base clients use (no trailing slash). Never logs credentials.
mm_client_mirror_url() {
  local url ip def stage
  mm_load_gui_config
  url="${MIRROR_HTTP_URL:-}"
  if [[ -z "$url" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      url="http://${ip}"
    fi
  fi
  if [[ -z "$url" ]]; then
    stage="${MM_PROJECT_ROOT:-}/client/stage-dp-phase2.sh"
    if [[ -f "$stage" ]]; then
      def="$(awk -F= '/^DEFAULT_MIRROR_URL=/{gsub(/"/,"",$2); print $2; exit}' "$stage" || true)"
      [[ -n "$def" ]] && url="$def"
    fi
  fi
  url="${url%/}"
  if [[ -z "$url" ]]; then
    return 1
  fi
  if ! [[ "$url" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]]; then
    return 1
  fi
  printf '%s\n' "$url"
}

mm_validate_source_dp_version() {
  local ver="$1"
  local cmp
  # Strict X.Y.Z only — reject empty, v-prefix, partial, metacharacters, newlines.
  [[ -n "$ver" ]] || return 1
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  # Policy floor matches stage-dp-phase2.sh MIN_SUPPORTED_SOURCE_DP_VERSION=6.2.0
  case "$ver" in
    6.2.0|6.3.0|6.4.0|6.5.0) return 0 ;;
  esac
  [[ "$ver" =~ ^6\.[0-9]+\.[0-9]+$ ]] || return 1
  # Reject below 6.2.0 via version sort.
  cmp="$(printf '%s\n' "6.2.0" "$ver" | sort -V | head -1)"
  [[ "$cmp" == "6.2.0" ]] || return 1
  return 0
}

# Comma-separated IPv4 list for --worker-ips. Rejects shell metacharacters,
# invalid octets, duplicates, and broadcast/unspecified addresses.
mm_validate_worker_ips() {
  local raw="$1"
  local cleaned item octet parts seen
  # Reject newlines / CR explicitly before stripping other whitespace.
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 1
  cleaned="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [[ -n "$cleaned" ]] || return 1
  # Trailing / leading comma or empty items.
  [[ "$cleaned" != *, && "$cleaned" != ,* && "$cleaned" != *,,* ]] || return 1
  # Allow only digits, dots, and commas.
  [[ "$cleaned" =~ ^[0-9.,]+$ ]] || return 1
  IFS=',' read -r -a _mm_ips <<<"$cleaned"
  [[ "${#_mm_ips[@]}" -ge 1 ]] || return 1
  seen="|"
  for item in "${_mm_ips[@]}"; do
    [[ -n "$item" ]] || return 1
    [[ "$item" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    parts=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}")
    for octet in "${parts[@]}"; do
      if (( 10#$octet > 255 )); then
        return 1
      fi
    done
    [[ "$item" != "0.0.0.0" && "$item" != "255.255.255.255" ]] || return 1
    if [[ "$seen" == *"|${item}|"* ]]; then
      return 1
    fi
    seen="${seen}${item}|"
  done
  printf '%s\n' "$cleaned"
}

# Operator-facing Upgrade Readiness label for status screens.
# Exactly one of: PASS | NOT VERIFIED | NOT READY | FAIL (never blank).
mm_upgrade_readiness_display() {
  local readiness_result
  # Suppress path-resolution INFO lines from nested completed-check helpers.
  if mm_readiness_completed >/dev/null 2>&1; then
    printf 'PASS\n'
    return 0
  fi
  if ! mm_configuration_completed >/dev/null 2>&1 \
    || ! mm_download_completed >/dev/null 2>&1 \
    || ! mm_http_completed >/dev/null 2>&1; then
    printf 'NOT READY\n'
    return 0
  fi
  readiness_result="$(mm_status_get READINESS_RESULT)"
  if [[ "$readiness_result" == "FAIL" ]]; then
    printf 'FAIL\n'
    return 0
  fi
  printf 'NOT VERIFIED\n'
}

mm_artifacts_ready_for_http() {
  local bundle_ck os_ready
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  [[ "$bundle_ck" == "PASS" ]] || return 1
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
    return 0
  fi
  os_ready="$(mm_status_get OS_MIRROR_READY)"
  [[ "$os_ready" == "PASS" ]] || return 1
  mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
  return 0
}

mm_http_distribution_enabled() {
  local v
  v="$(mm_status_get HTTP_DISTRIBUTION)"
  [[ "$v" == "ENABLED" ]]
}

mm_client_commands_file() {
  printf '%s/dp-client-upgrade-commands.txt\n' "${MM_LOG_DIR:-/var/log/ubuntu-mirror-automation}"
}

mm_client_commands_stale() {
  local f mode_saved
  f="$(mm_client_commands_file)"
  [[ -f "$f" ]] || return 0
  mm_normalize_preparation_mode
  mode_saved="$(mm_status_get CLIENT_COMMANDS_MODE)"
  [[ "$mode_saved" == "${PREPARATION_MODE}" ]] || return 0
  return 1
}

mm_mark_client_commands_fresh() {
  mm_normalize_preparation_mode
  mm_status_set CLIENT_COMMANDS_MODE "${PREPARATION_MODE}"
  mm_status_set CLIENT_COMMANDS_GENERATED_AT "$(mm_ts)"
}

mm_config_ready() {
  mm_load_gui_config
  mm_normalize_preparation_mode
  case "${PREPARATION_MODE}" in
    FULL|PHASE2_ONLY) ;;
    *) return 1 ;;
  esac
  mm_force_phase2_target
  [[ "${TARGET_DP_VERSION}" == "${PHASE2_TARGET_VERSION}" ]] || return 1
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
  local tmp dir old_umask
  dir="$(dirname "$f")"
  mkdir -p "$dir"
  if [[ ! -f "$f" ]]; then
    old_umask="$(umask)"
    umask 077
    : >"$f"
    umask "$old_umask"
    chmod 600 "$f" 2>/dev/null || true
  fi
  tmp="$(mktemp "${dir}/.status.XXXXXX")"
  old_umask="$(umask)"
  umask 077
  if [[ -f "$f" ]] && grep -q "^${key}=" "$f" 2>/dev/null; then
    awk -F= -v k="$key" -v v="$val" 'BEGIN{done=0} $1==k && !done {print k"="v; done=1; next} {print} END{if(!done) print k"="v}' "$f" >"$tmp"
  elif [[ -f "$f" ]]; then
    cat "$f" >"$tmp"
    printf '%s=%s\n' "$key" "$val" >>"$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >"$tmp"
  fi
  umask "$old_umask"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
  chmod 600 "$f" 2>/dev/null || true
}

mm_status_get() {
  local key="$1"
  local f="${MM_STATUS_FILE}"
  [[ -f "$f" ]] || { printf ''; return 0; }
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' "$f"
}

# Cheap file identity for menu completion (no full-file hash).
# Format: path|dev:inode:size:mtime_ns_or_sec
mm_file_fingerprint() {
  local path="$1"
  local st
  [[ -e "$path" ]] || { printf ''; return 1; }
  st="$(stat -c '%d:%i:%s:%Y' "$path" 2>/dev/null || true)"
  [[ -n "$st" ]] || { printf ''; return 1; }
  printf '%s|%s\n' "$path" "$st"
}

mm_config_fingerprint() {
  local path="${MM_CONFIG_FILE}"
  mm_file_fingerprint "$path" 2>/dev/null || printf ''
}

mm_phase2_paths() {
  mm_force_phase2_target
  local ver="${TARGET_DP_VERSION}"
  local dp="${MM_DP_PHASE2_ROOT}/${ver}"
  local stable
  if command -v dp2_stable_bundle_name >/dev/null 2>&1; then
    stable="$(dp2_stable_bundle_name 2>/dev/null || printf 'dp_bundle_%s-current.tar' "$ver")"
  else
    stable="dp_bundle_${ver}-current.tar"
  fi
  MM_WF_PHASE2_DIR="$dp"
  MM_WF_PHASE2_BUNDLE="${dp}/${stable}"
  MM_WF_PHASE2_SIDECAR="${dp}/${stable}.sha256"
  MM_WF_PHASE2_RELEASE="${dp}/release.env"
  MM_WF_PHASE2_STABLE="$stable"
}

mm_artifact_fingerprint() {
  # Phase 2 identity always; OS-mirror identity only for FULL mode.
  local os_fp bundle_fp side_fp rel_fp
  mm_phase2_paths
  os_fp=""
  if ! mm_is_phase2_only && [[ -e "${MM_SELECTIVE_ROOT}/ubuntu" ]]; then
    os_fp="$(mm_file_fingerprint "${MM_SELECTIVE_ROOT}/ubuntu" 2>/dev/null || true)"
  fi
  bundle_fp="$(mm_file_fingerprint "${MM_WF_PHASE2_BUNDLE}" 2>/dev/null || true)"
  side_fp="$(mm_file_fingerprint "${MM_WF_PHASE2_SIDECAR}" 2>/dev/null || true)"
  rel_fp="$(mm_file_fingerprint "${MM_WF_PHASE2_RELEASE}" 2>/dev/null || true)"
  printf 'mode=%s;os=%s;bundle=%s;sidecar=%s;release=%s\n' \
    "${PREPARATION_MODE:-FULL}" "${os_fp}" "${bundle_fp}" "${side_fp}" "${rel_fp}"
}

mm_temps_present() {
  # Incomplete publish leftovers invalidate Download completion.
  if [[ -d "${MM_DP_PHASE2_ROOT}" ]] \
    && find "${MM_DP_PHASE2_ROOT}" -maxdepth 1 \( -name '*.new.*' -o -name '*.old.*' \) \
      -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  if [[ -d "${MM_CACHE_ROOT}" ]] \
    && find "${MM_CACHE_ROOT}" \( -name '*.part' -o -name '*.download' -o -name '*.new.*' \) \
      -type f -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  return 1
}

mm_configuration_completed() {
  local mode
  [[ -f "${MM_CONFIG_FILE}" ]] || return 1
  mode="$(stat -c '%a' "${MM_CONFIG_FILE}" 2>/dev/null || true)"
  [[ "$mode" == "600" ]] || return 1
  [[ -r "${MM_CONFIG_FILE}" ]] || return 1
  mm_load_gui_config
  mm_config_ready || return 1
  # FULL mode requires the R2 URL constant; PHASE2_ONLY does not use R2.
  if ! mm_is_phase2_only; then
    mm_r2_url_configured || return 1
  fi
  if [[ -n "${MIRROR_HTTP_URL:-}" ]]; then
    [[ "${MIRROR_HTTP_URL}" =~ ^https?://[A-Za-z0-9._:-]+(/.*)?$ ]] || return 1
  fi
  [[ "$(mm_status_get CONFIGURATION_READY)" == "PASS" ]] || return 1
  return 0
}

mm_download_completed() {
  local stored_fp current_fp entries bundle_ck os_ready
  mm_configuration_completed || return 1
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  [[ -f "${MM_WF_PHASE2_RELEASE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_BUNDLE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_SIDECAR}" ]] || return 1
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  entries="$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT)"
  [[ "$bundle_ck" == "PASS" ]] || return 1
  [[ "$entries" == "9" ]] || return 1
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
  else
    [[ -d "${MM_SELECTIVE_ROOT}/ubuntu" || -L "${MM_SELECTIVE_ROOT}/ubuntu" ]] || return 1
    os_ready="$(mm_status_get OS_MIRROR_READY)"
    [[ "$os_ready" == "PASS" ]] || return 1
    [[ "$(mm_status_get R2_OS_CORE_CHECKSUM)" == "PASS" ]] || return 1
    mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
  fi
  [[ "$(mm_status_get DOWNLOAD_PREPARE_RESULT)" == "PASS" \
    || "$(mm_status_get LAST_EXECUTION_RESULT)" == "PASS" \
    || "$(mm_status_get INSTALL_RESULT)" == "PASS" ]] || return 1
  if mm_temps_present; then
    return 1
  fi
  current_fp="$(mm_artifact_fingerprint)"
  stored_fp="$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)"
  if [[ -z "$stored_fp" ]]; then
    mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "$current_fp"
    mm_status_set DOWNLOAD_PREPARE_RESULT PASS
    mm_status_set DOWNLOAD_VALIDATED_AT "$(mm_ts)"
    mm_status_set PHASE2_BUNDLE_SIZE "$(mm_file_bytes "${MM_WF_PHASE2_BUNDLE}")"
    mm_status_set PHASE2_BUNDLE_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_BUNDLE}" 2>/dev/null || echo 0)"
    mm_status_set PHASE2_SIDECAR_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_SIDECAR}" 2>/dev/null || echo 0)"
    return 0
  fi
  [[ "$stored_fp" == "$current_fp" ]] || return 1
  return 0
}

mm_http_probe_ok() {
  # Fast localhost probes for menu rendering (200-only).
  local url="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout "${MM_MENU_HTTP_CONNECT_TIMEOUT:-2}" \
    --max-time "${MM_MENU_HTTP_MAX_TIME:-3}" \
    "$url" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]]
}

mm_http_required_urls_ok() {
  local ver="${TARGET_DP_VERSION:-${PHASE2_TARGET_VERSION}}"
  local base="${MM_VERIFY_HTTP_BASE:-http://127.0.0.1}"
  local stable
  mm_phase2_paths
  stable="${MM_WF_PHASE2_STABLE}"
  mm_http_probe_ok "${base}/dp-phase2/${ver}/release.env" || return 1
  mm_http_probe_ok "${base}/dp-phase2/${ver}/${stable}.sha256" || return 1
  mm_http_probe_ok "${base}/client/stage-dp-phase2.sh" || return 1
  mm_http_probe_ok "${base}/client/stage-dp-phase2.sh.sha256" || return 1
  if ! mm_is_phase2_only; then
    mm_http_probe_ok "${base}/client/dp-offline-upgrade-xenial-to-bionic.sh" || return 1
    mm_http_probe_ok "${base}/offline/meta-release-lts" || return 1
  fi
  return 0
}

mm_nginx_distribution_live() {
  local nginx_bin systemctl_bin site_en
  nginx_bin="${MM_NGINX_BIN:-nginx}"
  systemctl_bin="${MM_SYSTEMCTL_BIN:-systemctl}"
  site_en="${MM_NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/${MM_NGINX_SITE_NAME:-apt-mirror}}"
  command -v "$systemctl_bin" >/dev/null 2>&1 || return 1
  "$systemctl_bin" is-active --quiet nginx 2>/dev/null || return 1
  command -v "$nginx_bin" >/dev/null 2>&1 || return 1
  "$nginx_bin" -t >/dev/null 2>&1 || return 1
  [[ -e "$site_en" ]] || return 1
  return 0
}

mm_http_completed() {
  mm_download_completed || return 1
  [[ "$(mm_status_get HTTP_DISTRIBUTION)" == "ENABLED" ]] || return 1
  [[ "$(mm_status_get HTTP_CONFIGURATION_READY)" == "PASS" ]] || return 1
  mm_nginx_distribution_live || return 1
  mm_http_required_urls_ok || return 1
  return 0
}

mm_readiness_completed() {
  local stored_art cur_art stored_cfg cur_cfg
  mm_configuration_completed || return 1
  mm_download_completed || return 1
  mm_http_completed || return 1
  [[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] || return 1
  [[ "$(mm_status_get READINESS_RESULT)" == "PASS" \
    || "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] || return 1
  cur_art="$(mm_artifact_fingerprint)"
  stored_art="$(mm_status_get READINESS_ARTIFACT_FINGERPRINT)"
  if [[ -z "$stored_art" ]]; then
    mm_status_set READINESS_ARTIFACT_FINGERPRINT "$cur_art"
    mm_status_set READINESS_RESULT PASS
    mm_status_set READINESS_VALIDATED_AT "$(mm_ts)"
    mm_status_set READINESS_CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
    return 0
  fi
  [[ "$stored_art" == "$cur_art" ]] || return 1
  cur_cfg="$(mm_config_fingerprint)"
  stored_cfg="$(mm_status_get READINESS_CONFIG_FINGERPRINT)"
  if [[ -n "$stored_cfg" && "$stored_cfg" != "$cur_cfg" ]]; then
    return 1
  fi
  return 0
}

# Populate MM_WF_* for menu + status screens (cheap; no full SHA256).
mm_collect_workflow_status() {
  MM_WF_CONFIG_COMPLETED=0
  MM_WF_DOWNLOAD_COMPLETED=0
  MM_WF_HTTP_COMPLETED=0
  MM_WF_READINESS_COMPLETED=0
  MM_WF_PROGRESS_COUNT=0
  mm_load_gui_config
  engine_resolve_paths 2>/dev/null || true
  if mm_configuration_completed; then
    MM_WF_CONFIG_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
  if mm_download_completed; then
    MM_WF_DOWNLOAD_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
  if mm_http_completed; then
    MM_WF_HTTP_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
  if mm_readiness_completed; then
    MM_WF_READINESS_COMPLETED=1
    MM_WF_PROGRESS_COUNT=$((MM_WF_PROGRESS_COUNT + 1))
  fi
}

mm_menu_label() {
  local base="$1"
  local completed="${2:-0}"
  if [[ "$completed" == "1" ]]; then
    printf '%s [COMPLETED]\n' "$base"
  else
    printf '%s\n' "$base"
  fi
}

mm_workflow_progress_text() {
  printf 'Progress: %s of 4 workflow steps completed\n' "${MM_WF_PROGRESS_COUNT:-0}"
}

mm_record_config_validated() {
  mm_status_set CONFIGURATION_READY PASS
  mm_status_set CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
  mm_status_set CONFIG_VALIDATED_AT "$(mm_ts)"
}

mm_record_download_validated() {
  local fp
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  fp="$(mm_artifact_fingerprint)"
  mm_status_set DOWNLOAD_PREPARE_RESULT PASS
  mm_status_set DOWNLOAD_VALIDATED_AT "$(mm_ts)"
  mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "$fp"
  mm_status_set PHASE2_BUNDLE_SIZE "$(mm_file_bytes "${MM_WF_PHASE2_BUNDLE}")"
  mm_status_set PHASE2_BUNDLE_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_BUNDLE}" 2>/dev/null || echo 0)"
  mm_status_set PHASE2_SIDECAR_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_SIDECAR}" 2>/dev/null || echo 0)"
  # Changing artifacts invalidates readiness until Menu 4 re-runs.
  mm_status_set READINESS_RESULT ""
  mm_status_set READINESS_ARTIFACT_FINGERPRINT ""
  mm_status_set UPGRADE_READINESS FAIL
}

mm_record_http_validated() {
  mm_status_set HTTP_ENABLE_RESULT PASS
  mm_status_set HTTP_VALIDATED_AT "$(mm_ts)"
  mm_status_set HTTP_DISTRIBUTION ENABLED
  mm_status_set HTTP_CONFIGURATION_READY PASS
}

mm_record_readiness_validated() {
  local fp
  fp="$(mm_artifact_fingerprint)"
  mm_status_set READINESS_RESULT PASS
  mm_status_set READINESS_VALIDATED_AT "$(mm_ts)"
  mm_status_set READINESS_ARTIFACT_FINGERPRINT "$fp"
  mm_status_set READINESS_CONFIG_FINGERPRINT "$(mm_config_fingerprint)"
  mm_status_set UPGRADE_READINESS PASS
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
  # reflected in CURRENT_AVAILABLE and must not be double-counted.
  #
  # OS materialization and Phase 2 build run sequentially. Future free-space
  # need is therefore max(OS_STAGE_EXTRA, PHASE2_STAGE_EXTRA) + SAFETY_RESERVE.
  #
  # Valid existing finals are REUSED (no ACPS/bundle bytes). Invalid finals are
  # deleted before rebuild, so their size is not part of future required.
  # Peak Phase 2 large data is at most ACPS source + new bundle (2 copies).
  #
  # TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES reports peak used capacity
  # (current used + sequential stage peak) for operator sizing guidance.
  local os_pkg_bytes payload_bytes acps_bytes ver existing_bundle
  local reserve_floor_bytes reserve_pct_bytes fs_size_bytes metadata_oh
  local stage_peak_bytes current_used_bytes existing_final_bytes
  local reuse_phase2=0
  os_pkg_bytes="${OS_CORE_PACKAGE_BYTES:-0}"
  payload_bytes="${OS_CORE_PAYLOAD_BYTES:-0}"
  acps_bytes="${ACPS_EXPECTED_BYTES:-0}"
  [[ "$os_pkg_bytes" =~ ^[0-9]+$ ]] || os_pkg_bytes=0
  [[ "$payload_bytes" =~ ^[0-9]+$ ]] || payload_bytes=0
  [[ "$acps_bytes" =~ ^[0-9]+$ ]] || acps_bytes=0
  metadata_oh=$((512 * 1024 * 1024))

  if [[ "${PHASE2_BUNDLE_ACTION:-}" == "REUSE" || "${PHASE2_REBUILD_REQUIRED:-}" == "NO" ]]; then
    reuse_phase2=1
    acps_bytes=0
  fi

  DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  DISK_PREFLIGHT_ACPS_SOURCE_BYTES=$acps_bytes
  # Bundle output is approximately the ACPS source tree size (9-file tar).
  DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=$acps_bytes
  PHASE2_ACPS_SOURCE_REQUIRED_BYTES=$DISK_PREFLIGHT_ACPS_SOURCE_BYTES
  PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=$DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
  VALID_FINAL_REBUILD_REQUIRED_BYTES=0
  if [[ "$reuse_phase2" -eq 1 ]]; then
    PHASE2_REBUILD_REQUIRED=NO
  else
    PHASE2_REBUILD_REQUIRED="${PHASE2_REBUILD_REQUIRED:-YES}"
  fi

  # Existing final (if still present) already reduces df available.
  DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=0
  existing_final_bytes=0
  ver="${TARGET_DP_VERSION:-${DP_PHASE2_VERSION:-6.5.0}}"
  existing_bundle="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT:-/var/spool/apt-mirror}/dp-phase2}/${ver}/dp_bundle_${ver}-current.tar"
  if [[ -f "$existing_bundle" ]]; then
    existing_final_bytes="$(mm_file_bytes "$existing_bundle")"
    [[ "$existing_final_bytes" =~ ^[0-9]+$ ]] || existing_final_bytes=0
  fi
  DISK_PREFLIGHT_EXISTING_FINAL_BYTES=$existing_final_bytes

  DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=$((payload_bytes + metadata_oh))
  if [[ "$reuse_phase2" -eq 1 ]]; then
    # Valid final reuse: Phase 2 adds only metadata-level free-space need.
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$metadata_oh
  else
    DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=$((
      DISK_PREFLIGHT_ACPS_SOURCE_BYTES
      + DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES
      + metadata_oh
    ))
  fi
  PHASE2_STAGE_REQUIRED_BYTES=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
  mm_normalize_preparation_mode
  if mm_is_phase2_only; then
    # PHASE2_ONLY never materializes OS; OS stage peak is not required.
    DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=0
    stage_peak_bytes=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
    DISK_PREFLIGHT_R2_REQUIRED_BYTES=0
  elif [[ "$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES" -gt "$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES" ]]; then
    stage_peak_bytes=$DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES
  else
    stage_peak_bytes=$DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES
  fi
  DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES=$stage_peak_bytes
  DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=$metadata_oh
  DISK_PREFLIGHT_PREPARATION_MODE="${PREPARATION_MODE}"

  reserve_floor_bytes=$((10 * 1024 * 1024 * 1024))
  fs_size_bytes="$(mm_fs_size_bytes "${MM_MIRROR_ROOT}")"
  [[ "$fs_size_bytes" =~ ^[0-9]+$ ]] || fs_size_bytes=0
  if [[ -n "${MM_MOCK_SAFETY_RESERVE_BYTES:-}" ]]; then
    DISK_PREFLIGHT_SAFETY_RESERVE_BYTES="$MM_MOCK_SAFETY_RESERVE_BYTES"
  else
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

  CURRENT_AVAILABLE_BASED_REQUIRED_BYTES=$((
    stage_peak_bytes + DISK_PREFLIGHT_SAFETY_RESERVE_BYTES
  ))
  DISK_PREFLIGHT_TOTAL_REQUIRED_BYTES=$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES
  TOTAL_REQUIRED_BYTES=$CURRENT_AVAILABLE_BASED_REQUIRED_BYTES

  DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES="$(mm_free_bytes "${MM_MIRROR_ROOT}")"
  AVAILABLE_BYTES="$DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES"
  [[ -n "$AVAILABLE_BYTES" && "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] \
    || mm_die "DISK_PREFLIGHT=FAIL cannot_read_df"

  if [[ "$fs_size_bytes" -ge "$AVAILABLE_BYTES" ]]; then
    current_used_bytes=$((fs_size_bytes - AVAILABLE_BYTES))
  else
    current_used_bytes=0
  fi
  TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES=$((current_used_bytes + stage_peak_bytes))
  DISK_PREFLIGHT_PROJECTED_PEAK_BYTES=$TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES

  if [[ "$AVAILABLE_BYTES" -lt "$TOTAL_REQUIRED_BYTES" ]]; then
    DISK_PREFLIGHT_RESULT=FAIL
    DISK_PREFLIGHT=FAIL
  else
    DISK_PREFLIGHT_RESULT=PASS
    DISK_PREFLIGHT=PASS
  fi

  mm_info "MIRROR_SERVER_DISK=100GB"
  mm_info "OS_CORE_PACKAGE_BYTES=${os_pkg_bytes}"
  mm_info "OS_CORE_PAYLOAD_BYTES=${payload_bytes}"
  mm_info "ACPS_EXPECTED_BYTES=${acps_bytes}"
  mm_info "PHASE2_BUNDLE_ACTION=${PHASE2_BUNDLE_ACTION:-}"
  mm_info "PHASE2_REBUILD_REQUIRED=${PHASE2_REBUILD_REQUIRED}"
  mm_info "PHASE2_ACPS_SOURCE_REQUIRED_BYTES=${PHASE2_ACPS_SOURCE_REQUIRED_BYTES}"
  mm_info "PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES=${PHASE2_BUNDLE_OUTPUT_REQUIRED_BYTES}"
  mm_info "PHASE2_STAGE_REQUIRED_BYTES=${PHASE2_STAGE_REQUIRED_BYTES}"
  mm_info "VALID_FINAL_REBUILD_REQUIRED_BYTES=${VALID_FINAL_REBUILD_REQUIRED_BYTES}"
  mm_info "OS_MATERIALIZE_TEMP_BYTES=${OS_MATERIALIZE_TEMP_BYTES}"
  mm_info "DP_BUILD_TEMP_BYTES=${DP_BUILD_TEMP_BYTES}"
  mm_info "DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES=${DISK_PREFLIGHT_CURRENT_AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT_R2_REQUIRED_BYTES=${DISK_PREFLIGHT_R2_REQUIRED_BYTES}"
  mm_info "DISK_PREFLIGHT_ACPS_SOURCE_BYTES=${DISK_PREFLIGHT_ACPS_SOURCE_BYTES}"
  mm_info "DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES=${DISK_PREFLIGHT_BUNDLE_OUTPUT_BYTES}"
  mm_info "DISK_PREFLIGHT_EXISTING_FINAL_BYTES=${DISK_PREFLIGHT_EXISTING_FINAL_BYTES}"
  mm_info "DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES=${DISK_PREFLIGHT_REPLACEMENT_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES=${DISK_PREFLIGHT_OS_STAGE_EXTRA_BYTES}"
  mm_info "DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES=${DISK_PREFLIGHT_PHASE2_STAGE_EXTRA_BYTES}"
  mm_info "DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES=${DISK_PREFLIGHT_SEQUENTIAL_STAGE_PEAK_BYTES}"
  mm_info "DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES=${DISK_PREFLIGHT_TEMP_OVERHEAD_BYTES}"
  mm_info "DISK_PREFLIGHT_SAFETY_RESERVE_BYTES=${DISK_PREFLIGHT_SAFETY_RESERVE_BYTES}"
  mm_info "CURRENT_AVAILABLE_BASED_REQUIRED_BYTES=${CURRENT_AVAILABLE_BASED_REQUIRED_BYTES}"
  mm_info "TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES=${TOTAL_CAPACITY_BASED_PROJECTED_PEAK_BYTES}"
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

MM_CLIENT_PHASE2_REQUIRED_FILES=(
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
)

mm_client_files_ready_phase2() {
  local root="${1:-${MM_CLIENT_ROOT}}"
  local f
  [[ -d "$root" ]] || return 1
  for f in "${MM_CLIENT_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -f "${root}/${f}" ]] || return 1
  done
  (cd "$root" && sha256sum -c stage-dp-phase2.sh.sha256 >/dev/null 2>&1) || return 1
  return 0
}

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
  local ok=0
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" && ok=1
  else
    mm_client_files_ready "${MM_CLIENT_ROOT}" && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    mm_state_set CLIENT_FILES_READY PASS
    mm_ok "CLIENT_FILES_READY=PASS"
    return 0
  fi
  mm_state_set CLIENT_FILES_READY FAIL
  mm_error "CLIENT_FILES_READY=FAIL (required scripts/checksums missing under ${MM_CLIENT_ROOT})"
  return 1
}
