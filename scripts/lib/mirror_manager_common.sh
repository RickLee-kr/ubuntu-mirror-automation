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
mm_verify_sha256_pair_logged() {
  local data_file="$1"
  local checksum_file="$2"
  local event_prefix="$3"
  local human_still="${4:-Still verifying SHA256...}"
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
  fi
  mm_info "${event_prefix}_START ${fields}"
  mm_bg_with_heartbeat "$event_prefix" "$fields" "$human_still" -- sha256sum "$data_file" && rc=0 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL rc=${rc}"
    return "$rc"
  fi
  actual="$(printf '%s\n' "$MM_LONG_STEP_LAST_STDOUT" | awk '{print $1; exit}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "SHA256_VERIFY=FAIL file=$(basename "$data_file") expected=${expected} actual=${actual}"
    mm_error "${event_prefix}_FAIL ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=FAIL"
    return 1
  fi
  mm_ok "${event_prefix}_COMPLETE ${fields} elapsed=${MM_LONG_STEP_LAST_ELAPSED}s result=PASS"
  mm_ok "SHA256_VERIFY=PASS file=$(basename "$data_file")"
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
