#!/usr/bin/env bash
# Compatibility wrapper around the original shared helpers.
# The base copy preserves the existing API; overrides below fix live logging
# duplication and calculate disk space for the bounded-copy pipeline.
# shellcheck shell=bash
set +x

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mirror_manager_common_base.sh
source "${_COMMON_DIR}/mirror_manager_common_base.sh"
unset _COMMON_DIR

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
  # stdout/stderr is already streamed by the GUI's tee pipeline. Writing the
  # same line to /dev/tty here produced an exact duplicate for every message.
  if [[ -n "${MM_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$MM_LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$MM_LOG_FILE" 2>/dev/null || true
  fi
}

mm_calc_disk_requirements() {
  # This preflight runs after the R2 package has been downloaded, so that file
  # is already reflected in AVAILABLE_BYTES. The optimized workflow needs one
  # extracted OS payload, one ACPS cache, and one final Phase 2 bundle.
  local os_pkg_bytes payload_bytes acps_bytes
  os_pkg_bytes="${OS_CORE_PACKAGE_BYTES:-0}"
  payload_bytes="${OS_CORE_PAYLOAD_BYTES:-0}"
  acps_bytes="${ACPS_EXPECTED_BYTES:-0}"

  OS_MATERIALIZE_TEMP_BYTES=$payload_bytes
  DP_BUILD_TEMP_BYTES=$((acps_bytes + (512 * 1024 * 1024)))
  SAFETY_MARGIN_BYTES=$((2 * 1024 * 1024 * 1024))
  TOTAL_REQUIRED_BYTES=$((OS_MATERIALIZE_TEMP_BYTES + acps_bytes + DP_BUILD_TEMP_BYTES + SAFETY_MARGIN_BYTES))
  AVAILABLE_BYTES="$(mm_free_bytes "${MM_MIRROR_ROOT}")"
  [[ -n "$AVAILABLE_BYTES" && "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] \
    || mm_die "DISK_PREFLIGHT=FAIL cannot_read_df"
  if [[ "$AVAILABLE_BYTES" -lt "$TOTAL_REQUIRED_BYTES" ]]; then
    DISK_PREFLIGHT=FAIL
  else
    DISK_PREFLIGHT=PASS
  fi
  mm_info "OS_CORE_PACKAGE_BYTES=${os_pkg_bytes}"
  mm_info "OS_CORE_PAYLOAD_BYTES=${payload_bytes}"
  mm_info "ACPS_EXPECTED_BYTES=${acps_bytes}"
  mm_info "OS_MATERIALIZE_TEMP_BYTES=${OS_MATERIALIZE_TEMP_BYTES}"
  mm_info "DP_BUILD_TEMP_BYTES=${DP_BUILD_TEMP_BYTES}"
  mm_info "TOTAL_REQUIRED_BYTES=${TOTAL_REQUIRED_BYTES}"
  mm_info "AVAILABLE_BYTES=${AVAILABLE_BYTES}"
  mm_info "DISK_PREFLIGHT=${DISK_PREFLIGHT}"
  [[ "$DISK_PREFLIGHT" == "PASS" ]] || mm_die "DISK_PREFLIGHT=FAIL"
}
