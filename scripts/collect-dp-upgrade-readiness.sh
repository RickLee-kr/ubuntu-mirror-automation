#!/usr/bin/env bash
# collect-dp-upgrade-readiness.sh — Read-only DP Ubuntu upgrade readiness collector
#
# Collects evidence for subsequent dp-upgrade-preflight.sh / upgrade automation.
# Does NOT modify the system, install packages, or judge READY/BLOCKED.
#
# Compatible with Bash 4.3+ / Ubuntu 16.04 base utilities.
# shellcheck disable=SC2034
# SC2034: summary_* globals are written during collection and read by generate_summary_*.

# Do not use set -e: individual collection failures must not abort the run.
set -uo pipefail

umask 077
export LC_ALL=C
export LANG=C

SCRIPT_VERSION="1.0.2"
SCHEMA_VERSION="1.0"
SCRIPT_NAME="collect-dp-upgrade-readiness.sh"

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------
OUTPUT_DIR="."
SKIP_NETWORK=0
DEEP_MANIFEST=0
KEEP_DIRECTORY=0
NETWORK_TIMEOUT=10
MAX_LOG_LINES=2000

COLLECTION_ID=""
RESULT_DIR=""
RESULT_NAME=""
TMP_DIR=""
STARTED_AT_UTC=""
COMPLETED_AT_UTC=""
DURATION_SECONDS=0

SUCCESSFUL_CHECKS=0
FAILED_CHECKS=0
SKIPPED_CHECKS=0
COLLECTION_STATUS="complete"

# Summary fields (unknown/null when not detected)
SUMMARY_HOSTNAME=""
SUMMARY_FQDN=""
SUMMARY_OS_ID=""
SUMMARY_OS_VERSION_ID=""
SUMMARY_OS_CODENAME=""
SUMMARY_KERNEL=""
SUMMARY_ARCH=""
SUMMARY_DP_VERSION="null"
SUMMARY_DP_VERSION_STATUS="unknown"
SUMMARY_DP_ROLE="null"
SUMMARY_CLUSTER_DETECTED="false"
SUMMARY_WORKER_IPS_JSON="[]"
SUMMARY_SHELL_ROOT="null"
SUMMARY_SHELL_AELLA="null"
SUMMARY_ROOT_AVAIL="null"
SUMMARY_BOOT_AVAIL="null"
SUMMARY_AELLADATA_AVAIL="null"
SUMMARY_AELLADATA_MOUNTED="false"
SUMMARY_UTC_NOW=""
SUMMARY_NTP_SYNC="null"
SUMMARY_NTP_SOURCE="unknown"
SUMMARY_DPKG_AUDIT_CLEAN="null"
SUMMARY_HELD_COUNT=0
SUMMARY_SOURCE_URI_COUNT=0
SUMMARY_UPGRADE_STATE_DETECTED="false"
SUMMARY_UPGRADE_STATE="null"
SUMMARY_HOP_HISTORY="false"
SUMMARY_AELLADEB_EXISTS="false"
SUMMARY_AELLADEB_FILE_COUNT=0
SUMMARY_AELLADEB_LEGACY_EXISTS="false"
SUMMARY_AELLADEB_LEGACY_FILE_COUNT=0
SUMMARY_WARNINGS_JSON="[]"

FINDINGS_FILE=""
COMMANDS_TSV=""
COLLECTION_LOG=""
REDACTION_REPORT=""

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u
}

utc_stamp() {
  date -u +"%Y%m%dT%H%M%SZ" 2>/dev/null || date -u +"%Y%m%dT%H%M%SZ"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]]
}

sanitize_filename() {
  local s="${1:-}"
  # Replace unsafe characters; collapse runs of underscores; trim edges.
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_' )"
  s="$(printf '%s' "$s" | sed 's/__*/_/g; s/^_//; s/_$//')"
  if [[ -z "$s" ]]; then
    s="unknown"
  fi
  printf '%s' "$s"
}

json_escape() {
  # Escape a string for JSON (no surrounding quotes).
  local s="${1-}"
  local out="" i c hex
  local -i len=${#s}
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      $'\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        # shellcheck disable=SC2053
        if [[ "$c" < $'\x20' || "$c" > $'\x7e' ]]; then
          printf -v hex '%02X' "'$c"
          out+="\\u00${hex}"
        else
          out+="$c"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

json_str_or_null() {
  local v="${1-}"
  if [[ -z "$v" || "$v" == "null" || "$v" == "unknown" && "${2:-}" == "null_unknown" ]]; then
    if [[ -z "$v" || "$v" == "null" ]]; then
      printf 'null'
      return
    fi
  fi
  if [[ "$v" == "null" ]]; then
    printf 'null'
  else
    printf '"%s"' "$(json_escape "$v")"
  fi
}

json_bool() {
  case "${1:-}" in
    true|1|yes) printf 'true' ;;
    false|0|no) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

json_num_or_null() {
  local v="${1-}"
  if [[ -z "$v" || "$v" == "null" ]]; then
    printf 'null'
  elif [[ "$v" =~ ^-?[0-9]+$ ]]; then
    printf '%s' "$v"
  else
    printf 'null'
  fi
}

ensure_dir() {
  mkdir -p "$1" 2>/dev/null || true
}

log() {
  local level="${1:-INFO}"
  shift || true
  local msg="$*"
  local ts
  ts="$(utc_now)"
  local line="${ts} ${level} ${msg}"
  printf '%s\n' "$line" >&2
  if [[ -n "${COLLECTION_LOG:-}" ]]; then
    printf '%s\n' "$line" >>"$COLLECTION_LOG" 2>/dev/null || true
  fi
}

log_info() { log INFO "$*"; }
log_warn() { log WARN "$*"; }
log_error() { log ERROR "$*"; }

WARNINGS_FILE=""

append_warning() {
  local w="$1"
  if [[ -n "${WARNINGS_FILE:-}" ]]; then
    printf '%s\n' "$w" >>"$WARNINGS_FILE"
  fi
  log_warn "$w"
}

append_finding() {
  local f="$1"
  if [[ -n "${FINDINGS_FILE:-}" ]]; then
    printf '%s\n' "$f" >>"$FINDINGS_FILE"
  fi
  log_info "Finding: $f"
}

note_redaction() {
  local file="$1"
  local pattern_kind="$2"
  if [[ -n "${REDACTION_REPORT:-}" ]]; then
    printf 'file=%s pattern=%s\n' "$file" "$pattern_kind" >>"$REDACTION_REPORT"
  fi
}

# ---------------------------------------------------------------------------
# Redaction
# ---------------------------------------------------------------------------

redact_stream() {
  # Read stdin, write redacted stdout. Records pattern kinds via side channel file if set.
  # Patterns: URL user:pass@, password=/token=/secret=, sensitive env-like KEY=value
  sed -E \
    -e 's#(https?://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g' \
    -e 's#(ftp://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g' \
    -e 's#((^|[[:space:]])(PASSWORD|PASS|TOKEN|SECRET|KEY|CREDENTIAL|COOKIE|AUTH)[[:space:]]*=[[:space:]]*)[^[:space:]]+#\1***REDACTED***#gI' \
    -e 's#((password|passwd|token|secret|api[_-]?key|authorization)[[:space:]]*[:=][[:space:]]*)[^[:space:]]+#\1***REDACTED***#gI' \
    -e 's#(Authorization:[[:space:]]*)[^[:space:]]+#\1***REDACTED***#gI' \
    -e 's#(proxy[_-]?password[[:space:]]*[:=][[:space:]]*)[^[:space:]]+#\1***REDACTED***#gI' \
    -e 's#(Acquire::http::Proxy[[:space:]]+"[^"]*://)[^/@"]+:[^/@"]+@#\1***:***@#gI' \
    -e 's#(machine[[:space:]]+[^[:space:]]+[[:space:]]+login[[:space:]]+[^[:space:]]+[[:space:]]+password[[:space:]]+)[^[:space:]]+#\1***REDACTED***#gI'
}

redact_file_to() {
  local src="$1"
  local dst="$2"
  local label="${3:-$dst}"
  if [[ ! -r "$src" ]]; then
    printf 'UNAVAILABLE: cannot read %s\n' "$src" >"$dst"
    return 1
  fi
  local tmp
  tmp="$(mktemp "${TMP_DIR}/redact.XXXXXX")"
  if ! redact_stream <"$src" >"$tmp" 2>/dev/null; then
    printf 'UNAVAILABLE: redact failed for %s\n' "$src" >"$dst"
    rm -f "$tmp"
    return 1
  fi
  # Detect if redaction changed content
  if ! cmp -s "$src" "$tmp" 2>/dev/null; then
    note_redaction "$label" "credentials_or_secrets"
    log_info "Redaction applied for $label"
  fi
  mv -f "$tmp" "$dst"
  return 0
}

copy_text_limited() {
  # Copy last N lines of a text file; skip binaries; record metadata.
  local src="$1"
  local dst="$2"
  local max_lines="${3:-$MAX_LOG_LINES}"
  local meta_dst="${4:-}"

  if [[ ! -e "$src" ]]; then
    printf 'MISSING: %s\n' "$src" >"$dst"
    [[ -n "$meta_dst" ]] && printf 'path=%s exists=false\n' "$src" >"$meta_dst"
    return 1
  fi
  if [[ -L "$src" ]]; then
    local target
    target="$(readlink "$src" 2>/dev/null || true)"
    printf 'SYMLINK: %s -> %s\n' "$src" "$target" >"$dst"
    # Do not follow symlinks unbounded; only copy if target is a regular file and readable
    if [[ -f "$target" && -r "$target" ]]; then
      src="$target"
    else
      [[ -n "$meta_dst" ]] && printf 'path=%s symlink=true target=%s followed=false\n' "$1" "$target" >"$meta_dst"
      return 0
    fi
  fi
  if [[ ! -f "$src" || ! -r "$src" ]]; then
    printf 'UNREADABLE: %s\n' "$src" >"$dst"
    [[ -n "$meta_dst" ]] && printf 'path=%s readable=false\n' "$src" >"$meta_dst"
    return 1
  fi
  # Skip binary
  if command_exists file; then
    if file -b --mime-encoding "$src" 2>/dev/null | grep -qi 'binary'; then
      printf 'SKIPPED_BINARY: %s\n' "$src" >"$dst"
      [[ -n "$meta_dst" ]] && printf 'path=%s binary=true skipped=true\n' "$src" >"$meta_dst"
      return 0
    fi
  else
    if grep -qI '' "$src" 2>/dev/null; then
      :
    else
      # grep -I treats binary as non-match with exit 1 on some systems; try LC_ALL
      if ! grep -a -q '' "$src" 2>/dev/null; then
        printf 'SKIPPED_BINARY: %s\n' "$src" >"$dst"
        return 0
      fi
      # Heuristic: NUL bytes
      if grep -a -q $'\0' "$src" 2>/dev/null; then
        printf 'SKIPPED_BINARY: %s\n' "$src" >"$dst"
        return 0
      fi
    fi
  fi

  local size lines_copied=0
  size="$(wc -c <"$src" 2>/dev/null | tr -d ' ' || echo 0)"
  {
    printf '# source: %s\n' "$src"
    printf '# original_bytes: %s\n' "$size"
    printf '# max_lines: %s\n' "$max_lines"
    printf '# collected_at_utc: %s\n' "$(utc_now)"
    printf '# --- tail begin ---\n'
    if command_exists tail; then
      tail -n "$max_lines" "$src" 2>/dev/null || true
    else
      # Fallback: sed
      sed -n "$(( $(wc -l <"$src" 2>/dev/null || echo 0) - max_lines + 1 )),\$p" "$src" 2>/dev/null || cat "$src"
    fi
  } >"$dst"
  lines_copied="$(wc -l <"$dst" 2>/dev/null | tr -d ' ' || echo 0)"
  [[ -n "$meta_dst" ]] && printf 'path=%s bytes=%s lines_in_output=%s\n' "$src" "$size" "$lines_copied" >"$meta_dst"
  return 0
}

# ---------------------------------------------------------------------------
# Command runner
# ---------------------------------------------------------------------------

_ms_now() {
  # Milliseconds since epoch if possible; else seconds*1000
  if date +%s%3N 2>/dev/null | grep -qE '^[0-9]+$'; then
    date +%s%3N
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

_tsv_escape() {
  # Replace tabs/newlines in a field
  printf '%s' "${1-}" | tr '\t\n\r' '   '
}

# Consume at most N lines from stdin, then drain the rest so upstream
# writers (grep, find, etc.) do not hit SIGPIPE / "Broken pipe".
take_lines() {
  local n="${1:-50}"
  local i=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    i=$((i + 1))
    if [[ "$i" -ge "$n" ]]; then
      cat >/dev/null 2>&1 || true
      break
    fi
  done
}

run_check() {
  # run_check check_id category description command output_relpath [timeout_sec] [privileged]
  local check_id="$1"
  local category="$2"
  local description="$3"
  local cmd="$4"
  local output_rel="${5:-}"
  local timeout_sec="${6:-0}"
  local privileged="${7:-0}"

  local started duration_ms rc status out_abs err_summary
  started="$(utc_now)"
  local t0 t1
  t0="$(_ms_now)"
  rc=0
  status="SUCCESS"
  err_summary=""
  out_abs=""

  if [[ -n "$output_rel" ]]; then
    out_abs="${RESULT_DIR}/${output_rel}"
    ensure_dir "$(dirname "$out_abs")"
  else
    out_abs="${TMP_DIR}/${check_id}.out"
  fi

  # Privileged path: try sudo -n if not root
  local run_cmd="$cmd"
  if [[ "$privileged" -eq 1 ]] && ! is_root; then
    if command_exists sudo; then
      run_cmd="sudo -n -- $cmd"
    else
      status="PERMISSION_DENIED"
      err_summary="privileged check without root and sudo unavailable"
      printf '%s\n' "$err_summary" >"$out_abs"
      SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
      _record_command "$check_id" "$category" "$description" "$cmd" "$started" 0 126 "$status" "$output_rel" "$err_summary"
      return 0
    fi
  fi

  local full_cmd="$run_cmd"
  if [[ "$timeout_sec" -gt 0 ]] && command_exists timeout; then
    full_cmd="timeout ${timeout_sec}s $run_cmd"
  fi

  set +e
  # shellcheck disable=SC2086
  bash -c "$full_cmd" >"$out_abs" 2>"${out_abs}.err"
  rc=$?
  set -uo pipefail

  t1="$(_ms_now)"
  duration_ms=$((t1 - t0))
  if [[ "$duration_ms" -lt 0 ]]; then duration_ms=0; fi

  if [[ -s "${out_abs}.err" ]]; then
    # Append stderr marker
    {
      printf '\n# --- stderr ---\n'
      cat "${out_abs}.err"
    } >>"$out_abs"
  fi
  rm -f "${out_abs}.err"

  if [[ "$rc" -eq 0 ]]; then
    status="SUCCESS"
    SUCCESSFUL_CHECKS=$((SUCCESSFUL_CHECKS + 1))
  elif [[ "$rc" -eq 124 ]]; then
    status="TIMEOUT"
    err_summary="command timed out after ${timeout_sec}s"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    COLLECTION_STATUS="partial"
    log_warn "Timeout: $check_id ($description)"
  elif [[ "$rc" -eq 126 || "$rc" -eq 127 ]]; then
    if grep -qiE 'permission denied|must be root|sudo:' "$out_abs" 2>/dev/null; then
      status="PERMISSION_DENIED"
    else
      status="NOT_AVAILABLE"
    fi
    err_summary="exit $rc"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    COLLECTION_STATUS="partial"
  else
    if grep -qiE 'permission denied|Operation not permitted|must be root' "$out_abs" 2>/dev/null; then
      status="PERMISSION_DENIED"
      err_summary="permission denied (rc=$rc)"
    else
      status="FAILED"
      err_summary="exit $rc"
    fi
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    COLLECTION_STATUS="partial"
  fi

  _record_command "$check_id" "$category" "$description" "$cmd" "$started" "$duration_ms" "$rc" "$status" "$output_rel" "$err_summary"
  return 0
}

run_cmd_capture() {
  # Capture stdout of a simple command into a variable-friendly file; never abort.
  local outfile="$1"
  shift
  set +e
  "$@" >"$outfile" 2>/dev/null
  local rc=$?
  set -uo pipefail
  return "$rc"
}

run_available_check() {
  # Skip with NOT_AVAILABLE if binary missing
  local check_id="$1"
  local category="$2"
  local description="$3"
  local binary="$4"
  local cmd="$5"
  local output_rel="$6"
  local timeout_sec="${7:-0}"
  local privileged="${8:-0}"

  if ! command_exists "$binary"; then
    local out_abs="${RESULT_DIR}/${output_rel}"
    ensure_dir "$(dirname "$out_abs")"
    printf 'NOT_AVAILABLE: command %s not found\n' "$binary" >"$out_abs"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
    log_warn "Command $binary not available"
    _record_command "$check_id" "$category" "$description" "$cmd" "$(utc_now)" 0 127 "NOT_AVAILABLE" "$output_rel" "command not found: $binary"
    return 0
  fi
  run_check "$check_id" "$category" "$description" "$cmd" "$output_rel" "$timeout_sec" "$privileged"
}

_record_command() {
  local check_id="$1" category="$2" description="$3" cmd="$4"
  local started="$5" duration_ms="$6" rc="$7" status="$8" output_file="$9" error_summary="${10:-}"
  # Never record credentials in command column — use description if cmd looks sensitive
  local safe_cmd
  safe_cmd="$cmd"
  if printf '%s' "$cmd" | grep -qiE 'password|token|secret|credential|authorization'; then
    safe_cmd="[REDACTED_COMMAND]"
    note_redaction "commands.tsv:${check_id}" "command_credentials"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(_tsv_escape "$check_id")" \
    "$(_tsv_escape "$category")" \
    "$(_tsv_escape "$description")" \
    "$(_tsv_escape "$safe_cmd")" \
    "$(_tsv_escape "$started")" \
    "$(_tsv_escape "$duration_ms")" \
    "$(_tsv_escape "$rc")" \
    "$(_tsv_escape "$status")" \
    "$(_tsv_escape "$output_file")" \
    "$(_tsv_escape "$error_summary")" \
    >>"$COMMANDS_TSV"
}

run_privileged_check() {
  run_check "$1" "$2" "$3" "$4" "$5" "${6:-0}" 1
}

write_note() {
  local path="$1"
  shift
  ensure_dir "$(dirname "$path")"
  printf '%s\n' "$*" >"$path"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Read-only collector of DP Ubuntu upgrade readiness evidence.
Does not modify the system or perform upgrade/preflight judgments.

Options:
  --output-dir DIR         Parent directory for results (default: current directory)
  --skip-network           Skip external DNS/HTTP checks
  --deep-manifest          Detailed metadata manifest for /opt/aelladata
  --keep-directory         Keep result directory after creating tar.gz
  --network-timeout SECS   Per-check network timeout (default: 10)
  --max-log-lines NUMBER   Max lines collected per log file (default: 2000)
  --help                   Show this help
  --version                Show script version

Examples:
  sudo ./scripts/$SCRIPT_NAME --output-dir /var/tmp --keep-directory
  sudo ./scripts/$SCRIPT_NAME --output-dir /var/tmp --skip-network
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
          printf 'ERROR: --output-dir requires a directory argument\n' >&2
          exit 2
        fi
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --skip-network)
        SKIP_NETWORK=1
        shift
        ;;
      --deep-manifest)
        DEEP_MANIFEST=1
        shift
        ;;
      --keep-directory)
        KEEP_DIRECTORY=1
        shift
        ;;
      --network-timeout)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          printf 'ERROR: --network-timeout requires a numeric argument\n' >&2
          exit 2
        fi
        if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -eq 0 ]]; then
          printf 'ERROR: --network-timeout must be a positive integer\n' >&2
          exit 2
        fi
        NETWORK_TIMEOUT="$2"
        shift 2
        ;;
      --max-log-lines)
        if [[ $# -lt 2 || -z "${2:-}" ]]; then
          printf 'ERROR: --max-log-lines requires a numeric argument\n' >&2
          exit 2
        fi
        if ! [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" -eq 0 ]]; then
          printf 'ERROR: --max-log-lines must be a positive integer\n' >&2
          exit 2
        fi
        MAX_LOG_LINES="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --version)
        printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
        exit 0
        ;;
      *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        printf 'Use --help for usage.\n' >&2
        exit 2
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Setup / cleanup
# ---------------------------------------------------------------------------

cleanup() {
  local ec=$?
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR" 2>/dev/null || true
  fi
  return "$ec"
}

setup_result_dirs() {
  if [[ ! -d "$OUTPUT_DIR" ]]; then
    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
      printf 'ERROR: cannot create output directory: %s\n' "$OUTPUT_DIR" >&2
      exit 2
    fi
  fi
  if [[ ! -w "$OUTPUT_DIR" ]]; then
    printf 'ERROR: output directory not writable: %s\n' "$OUTPUT_DIR" >&2
    exit 2
  fi

  SUMMARY_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
  local safe_host
  safe_host="$(sanitize_filename "$SUMMARY_HOSTNAME")"
  local stamp
  stamp="$(utc_stamp)"
  RESULT_NAME="dp-upgrade-readiness-${safe_host}-${stamp}"
  COLLECTION_ID="$RESULT_NAME"
  RESULT_DIR="${OUTPUT_DIR%/}/${RESULT_NAME}"

  if ! mkdir -p "$RESULT_DIR"; then
    printf 'ERROR: cannot create result directory: %s\n' "$RESULT_DIR" >&2
    exit 2
  fi

  TMP_DIR="$(mktemp -d "${RESULT_DIR}/.tmp.XXXXXX")"
  trap cleanup EXIT

  for d in system storage apt network services dp upgrade data-preservation security \
           apt/sources.list.d upgrade/state-files upgrade/dist-upgrade-logs \
           upgrade/apt-logs upgrade/aella-upgrade-logs; do
    ensure_dir "${RESULT_DIR}/${d}"
  done

  COLLECTION_LOG="${RESULT_DIR}/collection.log"
  COMMANDS_TSV="${RESULT_DIR}/commands.tsv"
  FINDINGS_FILE="${RESULT_DIR}/findings.txt"
  REDACTION_REPORT="${RESULT_DIR}/security/redaction-report.txt"
  WARNINGS_FILE="${TMP_DIR}/warnings.txt"

  : >"$COLLECTION_LOG"
  : >"$FINDINGS_FILE"
  : >"$REDACTION_REPORT"
  : >"$WARNINGS_FILE"

  printf 'check_id\tcategory\tcommand_description\tcommand\tstarted_at_utc\tduration_ms\treturn_code\tstatus\toutput_file\terror_summary\n' \
    >"$COMMANDS_TSV"
}

# ---------------------------------------------------------------------------
# Collectors: system
# ---------------------------------------------------------------------------

collect_system() {
  log_info "Starting system collection"
  local out="${RESULT_DIR}/system"

  if [[ -r /etc/os-release ]]; then
    # Dereference symlink so archive contains real content
    cat /etc/os-release >"${out}/os-release.txt" 2>/dev/null || true
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    SUMMARY_OS_ID="${ID:-unknown}"
    SUMMARY_OS_VERSION_ID="${VERSION_ID:-unknown}"
    SUMMARY_OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
  else
    write_note "${out}/os-release.txt" "MISSING: /etc/os-release"
    append_warning "os-release missing"
  fi
  if [[ -r /etc/lsb-release ]]; then
    cat /etc/lsb-release >"${out}/lsb-release.txt" 2>/dev/null || true
  fi

  run_available_check sys_uname system "uname -a" uname "uname -a" "system/uname.txt"
  SUMMARY_KERNEL="$(uname -r 2>/dev/null || echo unknown)"
  SUMMARY_ARCH="$(uname -m 2>/dev/null || echo unknown)"
  {
    printf 'hostname: %s\n' "$(hostname 2>/dev/null || true)"
    printf 'hostname -f: %s\n' "$(hostname -f 2>/dev/null || true)"
    printf 'hostname -I: %s\n' "$(hostname -I 2>/dev/null || true)"
  } >"${out}/hostname.txt"
  SUMMARY_FQDN="$(hostname -f 2>/dev/null || echo "$SUMMARY_HOSTNAME")"

  run_available_check sys_uptime system "uptime" uptime "uptime" "system/uptime.txt"
  {
    printf 'local: %s\n' "$(date 2>/dev/null || true)"
    printf 'utc: %s\n' "$(date -u 2>/dev/null || true)"
  } >"${out}/date.txt"
  SUMMARY_UTC_NOW="$(utc_now)"

  run_available_check sys_locale system "locale" locale "locale" "system/locale.txt"

  if command_exists lscpu; then
    run_check sys_cpu system "lscpu" "lscpu" "system/cpu.txt"
  else
    run_check sys_cpu system "cpuinfo head" "head -n 80 /proc/cpuinfo" "system/cpu.txt"
  fi

  {
    if command_exists free; then
      free -m 2>/dev/null || true
      printf '\n'
    fi
    if [[ -r /proc/meminfo ]]; then
      cat /proc/meminfo
    fi
  } >"${out}/memory.txt"
  _record_command sys_memory system "memory summary" "free -m; cat /proc/meminfo" "$(utc_now)" 0 0 SUCCESS "system/memory.txt" ""
  SUCCESSFUL_CHECKS=$((SUCCESSFUL_CHECKS + 1))

  {
    printf '=== who ===\n'
    who 2>/dev/null || true
    printf '\n=== last reboot ===\n'
    if command_exists last; then
      last -x reboot 2>/dev/null | take_lines 20 || true
    fi
  } >"${out}/sessions.txt"

  if [[ -e /var/run/reboot-required ]]; then
    {
      printf 'reboot_required=true\n'
      if [[ -r /var/run/reboot-required ]]; then
        cat /var/run/reboot-required
      fi
      if [[ -r /var/run/reboot-required.pkgs ]]; then
        printf '\n--- reboot-required.pkgs ---\n'
        cat /var/run/reboot-required.pkgs
      fi
    } >"${out}/reboot-required.txt"
  else
    printf 'reboot_required=false\n' >"${out}/reboot-required.txt"
  fi

  {
    printf 'execution_user=%s\n' "$(id -un 2>/dev/null || echo unknown)"
    printf 'effective_uid=%s\n' "$(id -u 2>/dev/null || echo unknown)"
    printf 'effective_gid=%s\n' "$(id -g 2>/dev/null || echo unknown)"
    printf 'groups=%s\n' "$(id -Gn 2>/dev/null || true)"
    printf 'sudo_user=%s\n' "${SUDO_USER:-}"
    printf 'is_root=%s\n' "$(is_root && echo true || echo false)"
    printf '\n=== target accounts ===\n'
    for acct in root aella stellar stellarcyber; do
      if command_exists getent; then
        getent passwd "$acct" 2>/dev/null || true
      else
        grep -E "^${acct}:" /etc/passwd 2>/dev/null || true
      fi
    done
    # Service-ish aella accounts
    if [[ -r /etc/passwd ]]; then
      printf '\n=== aella/stellar related passwd entries ===\n'
      grep -Ei 'aella|stellar' /etc/passwd 2>/dev/null || true
    fi
    printf '\n=== shells ===\n'
    local root_shell aella_shell
    root_shell="$(getent passwd root 2>/dev/null | awk -F: '{print $NF}' || true)"
    aella_shell="$(getent passwd aella 2>/dev/null | awk -F: '{print $NF}' || true)"
    printf 'root_shell=%s\n' "${root_shell:-unknown}"
    printf 'aella_shell=%s\n' "${aella_shell:-unknown}"
    if [[ -n "$root_shell" ]]; then
      SUMMARY_SHELL_ROOT="$root_shell"
      if [[ "$root_shell" != "/bin/bash" ]]; then
        append_finding "root shell is not /bin/bash"
      fi
    fi
    if [[ -n "$aella_shell" ]]; then
      SUMMARY_SHELL_AELLA="$aella_shell"
      if [[ "$aella_shell" != "/bin/bash" ]]; then
        append_finding "aella shell is not /bin/bash"
      fi
    fi
    printf '\n=== id root ===\n'
    id root 2>/dev/null || true
    printf '\n=== id aella ===\n'
    id aella 2>/dev/null || true
  } >"${out}/users-and-shells.txt"

  log_info "Finished system collection"
}

# ---------------------------------------------------------------------------
# Collectors: storage
# ---------------------------------------------------------------------------

_df_avail_bytes() {
  local path="$1"
  df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $4}' || true
}

_path_is_separate_mount() {
  local path="$1"
  local parent
  parent="$(dirname "$path")"
  local d1 d2
  d1="$(df -P "$path" 2>/dev/null | awk 'NR==2 {print $1}')"
  d2="$(df -P "$parent" 2>/dev/null | awk 'NR==2 {print $1}')"
  [[ -n "$d1" && -n "$d2" && "$d1" != "$d2" ]]
}

collect_storage() {
  log_info "Starting storage collection"
  local out="${RESULT_DIR}/storage"

  run_available_check stor_dfh storage "df -hT" df "df -hT" "storage/df-h.txt"
  run_available_check stor_dfi storage "df -i" df "df -i" "storage/df-inodes.txt"

  if command_exists lsblk; then
    run_check stor_lsblk_f storage "lsblk -f" "lsblk -f" "storage/lsblk.txt"
    run_check stor_lsblk_o storage "lsblk detailed" "lsblk -o NAME,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINT" "storage/lsblk-detailed.txt"
  else
    write_note "${out}/lsblk.txt" "NOT_AVAILABLE: lsblk"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
  fi

  run_available_check stor_mount storage "mount" mount "mount" "storage/mounts.txt"
  if command_exists findmnt; then
    run_check stor_findmnt storage "findmnt" "findmnt" "storage/findmnt.txt"
  else
    write_note "${out}/findmnt.txt" "NOT_AVAILABLE: findmnt"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
  fi

  if [[ -r /etc/fstab ]]; then
    redact_file_to /etc/fstab "${out}/fstab.redacted" "storage/fstab.redacted" || true
  else
    write_note "${out}/fstab.redacted" "MISSING or unreadable: /etc/fstab"
  fi

  {
    printf 'path\tfilesystem\tmountpoint\tfstype\ttotal_bytes\tused_bytes\tavail_bytes\tinodes_used\tinodes_free\tread_only\n'
    for p in / /boot /opt /opt/aelladata; do
      local fs mp fstype tot used avail iused ifree ro
      fs=""; mp=""; fstype=""; tot=""; used=""; avail=""; iused=""; ifree=""; ro="unknown"
      if [[ -e "$p" ]]; then
        local line
        line="$(df -PB1 "$p" 2>/dev/null | awk 'NR==2')"
        fs="$(printf '%s' "$line" | awk '{print $1}')"
        tot="$(printf '%s' "$line" | awk '{print $2}')"
        used="$(printf '%s' "$line" | awk '{print $3}')"
        avail="$(printf '%s' "$line" | awk '{print $4}')"
        mp="$(printf '%s' "$line" | awk '{print $6}')"
        local iline
        iline="$(df -Pi "$p" 2>/dev/null | awk 'NR==2')"
        iused="$(printf '%s' "$iline" | awk '{print $3}')"
        ifree="$(printf '%s' "$iline" | awk '{print $4}')"
        if command_exists findmnt; then
          fstype="$(findmnt -n -o FSTYPE --target "$p" 2>/dev/null || true)"
          local opts
          opts="$(findmnt -n -o OPTIONS --target "$p" 2>/dev/null || true)"
          if printf '%s' "$opts" | grep -qw ro; then ro="true"; else ro="false"; fi
        else
          fstype="$(df -PT "$p" 2>/dev/null | awk 'NR==2 {print $2}')"
          if mount 2>/dev/null | grep -F " on ${mp} " | grep -q '(ro\|,ro,\|,ro)'; then
            ro="true"
          else
            ro="false"
          fi
        fi
      else
        fs="MISSING"; mp="MISSING"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$p" "$fs" "$mp" "$fstype" "$tot" "$used" "$avail" "$iused" "$ifree" "$ro"
    done
  } >"${out}/target-filesystems.txt"

  SUMMARY_ROOT_AVAIL="$(_df_avail_bytes /)"
  SUMMARY_BOOT_AVAIL="$(_df_avail_bytes /boot)"
  if [[ -e /opt/aelladata ]]; then
    SUMMARY_AELLADATA_AVAIL="$(_df_avail_bytes /opt/aelladata)"
    if _path_is_separate_mount /opt/aelladata; then
      SUMMARY_AELLADATA_MOUNTED="true"
    else
      SUMMARY_AELLADATA_MOUNTED="false"
      append_finding "/opt/aelladata is not a separate mount"
    fi
    if [[ -L /opt/aelladata ]]; then
      printf 'aelladata_is_symlink=true\ntarget=%s\n' "$(readlink /opt/aelladata 2>/dev/null || true)" \
        >>"${out}/target-filesystems.txt"
    fi
  else
    SUMMARY_AELLADATA_MOUNTED="false"
    append_warning "/opt/aelladata does not exist"
  fi

  {
    printf '# directory size summary (timeout-protected du)\n'
    for d in /var/log /opt /opt/aelladata /boot /var/cache/apt; do
      if [[ -d "$d" ]]; then
        printf '=== %s ===\n' "$d"
        if command_exists timeout && command_exists du; then
          timeout 60s du -sh "$d" 2>/dev/null || printf 'TIMEOUT or error for %s\n' "$d"
        elif command_exists du; then
          du -sh "$d" 2>/dev/null || true
        else
          printf 'du not available\n'
        fi
      fi
    done
  } >"${out}/directory-sizes.txt"

  log_info "Finished storage collection"
}

# ---------------------------------------------------------------------------
# Collectors: apt
# ---------------------------------------------------------------------------

_is_ubuntu_official_uri() {
  local uri="$1"
  printf '%s' "$uri" | grep -qiE 'ubuntu\.com|canonical\.com|archive\.ubuntu|security\.ubuntu|ports\.ubuntu|old-releases\.ubuntu|changelogs\.ubuntu'
}

# Extract repository URIs from classic one-line deb sources (handles [options]).
_extract_deb_line_uri() {
  local line="$1"
  line="$(printf '%s' "$line" | sed -E 's/#.*//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "$line" ]] && return 0
  case "$line" in
    deb|deb-src|deb[[:space:]]*|deb-src[[:space:]]*) ;;
    *) return 0 ;;
  esac
  # Strip bracketed apt options: [arch=amd64 trusted=yes]
  line="$(printf '%s' "$line" | sed -E 's/\[[^]]*\]//g; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  # shellcheck disable=SC2086
  set -- $line
  # $1 = deb|deb-src, $2 = URI
  if [[ $# -ge 2 && "$2" == *://* ]]; then
    printf '%s\n' "$2"
  fi
}

_collect_source_uris_from_file() {
  local src="$1"
  local line
  [[ -r "$src" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    _extract_deb_line_uri "$line"
  done <"$src"
}

collect_apt() {
  log_info "Starting apt collection"
  local out="${RESULT_DIR}/apt"
  local uri_tmp="${TMP_DIR}/uris.txt"
  : >"$uri_tmp"

  if [[ -r /etc/apt/sources.list ]]; then
    redact_file_to /etc/apt/sources.list "${out}/sources.list.redacted" "apt/sources.list.redacted" || true
    _collect_source_uris_from_file /etc/apt/sources.list >>"$uri_tmp" || true
  else
    write_note "${out}/sources.list.redacted" "MISSING: /etc/apt/sources.list"
  fi

  ensure_dir "${out}/sources.list.d"
  if [[ -d /etc/apt/sources.list.d ]]; then
    local f base
    # shellcheck disable=SC2044
    for f in /etc/apt/sources.list.d/*; do
      [[ -e "$f" ]] || continue
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      case "$base" in
        *.list|*.sources)
          redact_file_to "$f" "${out}/sources.list.d/${base}.redacted" "apt/sources.list.d/${base}" || true
          if [[ "$base" == *.list ]]; then
            _collect_source_uris_from_file "$f" >>"$uri_tmp" || true
          else
            # deb822 URIs
            grep -Ei '^\s*URIs:' "$f" 2>/dev/null | sed -E 's/^\s*URIs:\s*//I' | tr ' ' '\n' | \
              grep -E '^[a-zA-Z][a-zA-Z0-9+.-]*://' >>"$uri_tmp" || true
          fi
          ;;
        *)
          printf 'SKIPPED_NON_SOURCE: %s\n' "$f" >"${out}/sources.list.d/${base}.note"
          ;;
      esac
    done
  fi

  {
    printf '# deduplicated source URIs\n'
    sort -u "$uri_tmp" 2>/dev/null | grep -E '^[a-zA-Z][a-zA-Z0-9+.-]*://' | sed '/^$/d' | while IFS= read -r u; do
      printf '%s\n' "$u"
    done
  } >"${out}/source-uris.txt"
  SUMMARY_SOURCE_URI_COUNT="$(grep -cve '^#' -e '^[[:space:]]*$' "${out}/source-uris.txt" 2>/dev/null || true)"
  SUMMARY_SOURCE_URI_COUNT="$(printf '%s' "${SUMMARY_SOURCE_URI_COUNT:-0}" | tr -cd '0-9')"
  SUMMARY_SOURCE_URI_COUNT=$(( ${SUMMARY_SOURCE_URI_COUNT:-0} + 0 ))

  {
    printf '# third-party vs official classification\n'
    grep -E '^[a-zA-Z][a-zA-Z0-9+.-]*://' "$uri_tmp" 2>/dev/null | sort -u | sed '/^$/d' | while IFS= read -r u; do
      if _is_ubuntu_official_uri "$u"; then
        printf 'official\t%s\n' "$u"
      else
        printf 'third-party\t%s\n' "$u"
      fi
    done
  } >"${out}/third-party-repositories.txt"

  # Codename mismatch note — suite field after URI (skip bracket options)
  {
    printf 'os_codename=%s\n' "${SUMMARY_OS_CODENAME:-unknown}"
    printf 'source_codenames_seen=\n'
    {
      [[ -r /etc/apt/sources.list ]] && cat /etc/apt/sources.list
      [[ -d /etc/apt/sources.list.d ]] && cat /etc/apt/sources.list.d/*.list 2>/dev/null
    } 2>/dev/null | sed -E 's/#.*//; s/\[[^]]*\]//g' | \
      awk '/^[[:space:]]*deb(-src)?[[:space:]]/ {
        for (i=1;i<=NF;i++) if ($i ~ /:\/\//) { print $(i+1); break }
      }' | sort -u || true
  } >"${out}/codename-check.txt"

  run_available_check apt_policy apt "apt-cache policy" apt-cache "apt-cache policy" "apt/apt-cache-policy.txt" 60
  run_available_check apt_hold apt "apt-mark showhold" apt-mark "apt-mark showhold" "apt/held-packages.txt"
  if [[ -f "${out}/held-packages.txt" ]]; then
    if grep -q 'NOT_AVAILABLE' "${out}/held-packages.txt" 2>/dev/null; then
      SUMMARY_HELD_COUNT=0
    else
      SUMMARY_HELD_COUNT="$(grep -cve '^[[:space:]]*$' "${out}/held-packages.txt" 2>/dev/null || true)"
      SUMMARY_HELD_COUNT="$(printf '%s' "${SUMMARY_HELD_COUNT:-0}" | tr -cd '0-9')"
      SUMMARY_HELD_COUNT=$(( ${SUMMARY_HELD_COUNT:-0} + 0 ))
    fi
  fi

  if command_exists dpkg-query; then
    run_check apt_pkgs apt "dpkg-query package list" \
      "dpkg-query -W -f='\${Package}\t\${Version}\t\${Architecture}\t\${Status}\n'" \
      "apt/package-list.tsv" 120
  else
    write_note "${out}/package-list.tsv" "NOT_AVAILABLE: dpkg-query"
  fi

  run_available_check apt_audit apt "dpkg --audit" dpkg "dpkg --audit" "apt/dpkg-audit.txt"
  if [[ -f "${out}/dpkg-audit.txt" ]]; then
    if grep -qiE 'NOT_AVAILABLE|The following packages' "${out}/dpkg-audit.txt" 2>/dev/null; then
      if grep -qiE 'The following packages are only half|unfinished|missing' "${out}/dpkg-audit.txt"; then
        SUMMARY_DPKG_AUDIT_CLEAN="false"
        append_finding "dpkg reports unfinished configuration"
      elif grep -q 'NOT_AVAILABLE' "${out}/dpkg-audit.txt"; then
        SUMMARY_DPKG_AUDIT_CLEAN="null"
      else
        # empty or only stderr noise => treat as clean if rc was 0 — check commands.tsv later; heuristic:
        if [[ ! -s "${out}/dpkg-audit.txt" ]] || ! grep -qiE 'half|broken|missing|unfinished' "${out}/dpkg-audit.txt"; then
          SUMMARY_DPKG_AUDIT_CLEAN="true"
        else
          SUMMARY_DPKG_AUDIT_CLEAN="false"
          append_finding "dpkg reports unfinished configuration"
        fi
      fi
    else
      if grep -qiE 'half|broken|missing|unfinished|The following packages' "${out}/dpkg-audit.txt"; then
        SUMMARY_DPKG_AUDIT_CLEAN="false"
        append_finding "dpkg reports unfinished configuration"
      else
        SUMMARY_DPKG_AUDIT_CLEAN="true"
      fi
    fi
  fi

  run_available_check apt_dpkg_c apt "dpkg -C" dpkg "dpkg -C" "apt/dpkg-status-check.txt"

  {
    printf '=== /var/lib/dpkg/updates ===\n'
    if [[ -d /var/lib/dpkg/updates ]]; then
      ls -la /var/lib/dpkg/updates 2>/dev/null || true
      local count
      count="$(find /var/lib/dpkg/updates -type f 2>/dev/null | wc -l | tr -d ' ')"
      printf 'update_files=%s\n' "$count"
    else
      printf 'MISSING\n'
    fi
    printf '\n=== lock files ===\n'
    for lock in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
      if [[ -e "$lock" ]]; then
        printf 'exists %s\n' "$lock"
        if command_exists fuser; then
          fuser "$lock" 2>/dev/null && printf '  in_use=true\n' || printf '  in_use=false_or_unknown\n'
        elif command_exists lsof; then
          lsof "$lock" 2>/dev/null | take_lines 5 || printf '  in_use=unknown\n'
        fi
      else
        printf 'missing %s\n' "$lock"
      fi
    done
  } >"${out}/apt-locks.txt"

  {
    printf '=== apt/dpkg related processes ===\n'
    ps auxww 2>/dev/null | grep -iE 'apt-get|aptitude|unattended-upgrade|dpkg' | grep -v grep || true
  } >"${out}/pending-actions.txt"

  # Proxy settings (redacted)
  {
    printf '=== environment proxy vars (redacted) ===\n'
    env 2>/dev/null | grep -iE 'proxy|no_proxy' | redact_stream || true
    printf '\n=== /etc/apt/apt.conf ===\n'
    if [[ -r /etc/apt/apt.conf ]]; then
      redact_stream </etc/apt/apt.conf || true
      note_redaction "apt/proxy-settings" "apt_conf"
    fi
    printf '\n=== /etc/apt/apt.conf.d ===\n'
    if [[ -d /etc/apt/apt.conf.d ]]; then
      local cf
      for cf in /etc/apt/apt.conf.d/*; do
        [[ -f "$cf" && -r "$cf" ]] || continue
        printf '--- %s ---\n' "$cf"
        redact_stream <"$cf" || true
      done
    fi
  } >"${out}/../network/proxy-settings.redacted" 2>/dev/null || {
    ensure_dir "${RESULT_DIR}/network"
    {
      env 2>/dev/null | grep -iE 'proxy|no_proxy' | redact_stream || true
    } >"${RESULT_DIR}/network/proxy-settings.redacted"
  }

  # Also keep apt-specific proxy note
  if [[ -r /etc/apt/auth.conf ]]; then
    printf 'PRESENT but contents redacted/not collected (credentials)\n' >"${out}/auth.conf.note"
    note_redaction "apt/auth.conf" "skipped_credentials_file"
  fi

  log_info "Finished apt collection"
}

# ---------------------------------------------------------------------------
# Collectors: network + time
# ---------------------------------------------------------------------------

_dns_lookup() {
  local host="$1"
  if command_exists getent; then
    getent ahosts "$host" 2>/dev/null | take_lines 5 || getent hosts "$host" 2>/dev/null || true
  elif command_exists host; then
    host "$host" 2>/dev/null || true
  elif command_exists dig; then
    dig +short "$host" 2>/dev/null || true
  elif command_exists nslookup; then
    nslookup "$host" 2>/dev/null || true
  else
    printf 'NO_DNS_TOOL\n'
    return 127
  fi
}

_http_head() {
  local url="$1"
  local timeout="$2"
  if command_exists curl; then
    # HEAD only — do not use --max-filesize (Release files exceed small limits and
    # caused false FAILED with HTTP 200 / curl exit 63).
    local out rc=0 code
    set +e
    out="$(curl -sS -o /dev/null -w '%{http_code}\t%{time_total}\t%{url_effective}' \
      --connect-timeout "$timeout" --max-time "$timeout" \
      -L --head "$url" 2>/dev/null)"
    rc=$?
    set -uo pipefail
    code="$(printf '%s' "$out" | cut -d$'\t' -f1)"
    printf '%s\n' "$out"
    # Treat HTTP 2xx/3xx as success even if curl returned a soft error.
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
      return 0
    fi
    return "$rc"
  elif command_exists wget; then
    # wget spider
    local t0 t1 code
    t0="$(_ms_now)"
    set +e
    wget --spider -T "$timeout" -q "$url" 2>"${TMP_DIR}/wget.err"
    local rc=$?
    set -uo pipefail
    t1="$(_ms_now)"
    if [[ $rc -eq 0 ]]; then code=200; else code="ERR:${rc}"; fi
    printf '%s\t%s\t%s\n' "$code" "$(( (t1 - t0) / 1000 )).$(( (t1 - t0) % 1000 ))" "$url"
    return "$rc"
  else
    printf 'NO_HTTP_TOOL\t0\t%s\n' "$url"
    return 127
  fi
}

collect_network() {
  log_info "Starting network collection"
  local out="${RESULT_DIR}/network"
  ensure_dir "$out"

  if command_exists ip; then
    run_check net_addr network "ip addr" "ip addr" "network/ip-address.txt"
    run_check net_route network "ip route" "ip route" "network/ip-route.txt"
    run_check net_link network "ip link" "ip link" "network/ip-link.txt"
  else
    run_available_check net_ifconfig network "ifconfig -a" ifconfig "ifconfig -a" "network/ip-address.txt"
    write_note "${out}/ip-route.txt" "NOT_AVAILABLE: ip"
    write_note "${out}/ip-link.txt" "NOT_AVAILABLE: ip"
  fi

  if [[ -r /etc/resolv.conf ]]; then
    redact_file_to /etc/resolv.conf "${out}/resolv.conf.redacted" "network/resolv.conf.redacted" || true
  else
    write_note "${out}/resolv.conf.redacted" "MISSING: /etc/resolv.conf"
  fi
  if [[ -r /etc/hosts ]]; then
    redact_file_to /etc/hosts "${out}/hosts.redacted" "network/hosts.redacted" || true
  else
    write_note "${out}/hosts.redacted" "MISSING: /etc/hosts"
  fi

  # Ensure proxy-settings exists
  if [[ ! -f "${out}/proxy-settings.redacted" ]]; then
    {
      printf '=== environment proxy vars (redacted) ===\n'
      env 2>/dev/null | grep -iE 'proxy|no_proxy' | redact_stream || true
    } >"${out}/proxy-settings.redacted"
  fi

  # DNS / HTTP tests
  printf 'hostname\tstatus\tdetail\n' >"${out}/dns-tests.tsv"
  printf 'url\thttp_status\tresult\n' >"${out}/http-tests.tsv"

  if [[ "$SKIP_NETWORK" -eq 1 ]]; then
    log_info "Skipping network DNS/HTTP checks (--skip-network)"
    for h in archive.ubuntu.com security.ubuntu.com changelogs.ubuntu.com old-releases.ubuntu.com api.snapcraft.io; do
      printf '%s\tSKIPPED\tskip-network\n' "$h" >>"${out}/dns-tests.tsv"
      SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
      _record_command "dns_${h}" network "DNS $h" "dns_lookup $h" "$(utc_now)" 0 0 SKIPPED "network/dns-tests.tsv" "skip-network"
    done
    for url in \
      "http://archive.ubuntu.com/ubuntu/dists/xenial/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release" \
      "http://security.ubuntu.com/ubuntu/dists/xenial-security/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/bionic/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/focal/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/jammy/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/noble/Release" \
      "http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release" \
      "http://changelogs.ubuntu.com/meta-release-lts"; do
      printf '%s\tSKIPPED\t0\tskip-network\n' "$url" >>"${out}/http-tests.tsv"
      SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
    done
  else
    for h in archive.ubuntu.com security.ubuntu.com changelogs.ubuntu.com old-releases.ubuntu.com api.snapcraft.io; do
      local detail rc=0
      detail="$(_dns_lookup "$h" 2>&1)" || rc=$?
      if [[ $rc -eq 0 && -n "$detail" && "$detail" != "NO_DNS_TOOL" ]]; then
        printf '%s\tSUCCESS\t%s\n' "$h" "$(_tsv_escape "$detail")" >>"${out}/dns-tests.tsv"
        SUCCESSFUL_CHECKS=$((SUCCESSFUL_CHECKS + 1))
        _record_command "dns_${h}" network "DNS $h" "dns_lookup $h" "$(utc_now)" 0 0 SUCCESS "network/dns-tests.tsv" ""
      elif [[ "$detail" == "NO_DNS_TOOL" ]]; then
        printf '%s\tNOT_AVAILABLE\tno dns tool\n' "$h" >>"${out}/dns-tests.tsv"
        SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
      else
        printf '%s\tFAILED\t%s\n' "$h" "$(_tsv_escape "$detail")" >>"${out}/dns-tests.tsv"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        COLLECTION_STATUS="partial"
        log_warn "DNS lookup failed: $h"
      fi
    done

    local url
    # Direct Xenial uses archive/security (not old-releases as primary).
    # old-releases xenial is collected only as a fallback candidate.
    for url in \
      "http://archive.ubuntu.com/ubuntu/dists/xenial/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release" \
      "http://security.ubuntu.com/ubuntu/dists/xenial-security/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/bionic/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/focal/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/jammy/Release" \
      "http://archive.ubuntu.com/ubuntu/dists/noble/Release" \
      "http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release" \
      "http://changelogs.ubuntu.com/meta-release-lts"; do
      local result rc=0 http_code
      result="$(_http_head "$url" "$NETWORK_TIMEOUT")" || rc=$?
      http_code="$(printf '%s' "$result" | cut -d$'\t' -f1)"
      printf '%s\t%s\t%s\n' "$url" "$http_code" "$(_tsv_escape "$result")" >>"${out}/http-tests.tsv"
      if [[ $rc -eq 0 ]]; then
        SUCCESSFUL_CHECKS=$((SUCCESSFUL_CHECKS + 1))
        _record_command "http_check" network "HTTP check $url" "http_head [url]" "$(utc_now)" 0 0 SUCCESS "network/http-tests.tsv" ""
      else
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        COLLECTION_STATUS="partial"
        log_warn "HTTP check failed: $url (rc=$rc code=$http_code)"
        _record_command "http_check" network "HTTP check $url" "http_head [url]" "$(utc_now)" 0 "$rc" FAILED "network/http-tests.tsv" "code=$http_code"
      fi
    done

    # APT source hosts (limited) — only real hostnames from URI list
    if [[ -f "${RESULT_DIR}/apt/source-uris.txt" ]]; then
      local host
      while IFS= read -r host; do
        [[ -z "$host" ]] && continue
        # Basic hostname sanity
        if ! printf '%s' "$host" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$|^[A-Za-z0-9]+$'; then
          continue
        fi
        local detail rc=0
        detail="$(_dns_lookup "$host" 2>&1)" || rc=$?
        if [[ $rc -eq 0 && -n "$detail" && "$detail" != "NO_DNS_TOOL" ]]; then
          printf '%s\tSUCCESS\t%s\n' "$host" "$(_tsv_escape "$detail")" >>"${out}/dns-tests.tsv"
        else
          printf '%s\tFAILED\t%s\n' "$host" "$(_tsv_escape "$detail")" >>"${out}/dns-tests.tsv"
        fi
      done < <(sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' "${RESULT_DIR}/apt/source-uris.txt" 2>/dev/null | \
        cut -d/ -f1 | cut -d: -f1 | grep -E '^[A-Za-z0-9]' | sort -u | take_lines 20)
    fi
  fi

  collect_time
  log_info "Finished network collection"
}

collect_time() {
  log_info "Starting time/NTP collection"
  local out="${RESULT_DIR}/network/ntp-status.txt"
  {
    printf 'utc_now=%s\n' "$(utc_now)"
    printf '\n=== timedatectl ===\n'
  } >"$out"

  SUMMARY_UTC_NOW="$(utc_now)"
  SUMMARY_NTP_SYNC="null"
  SUMMARY_NTP_SOURCE="unknown"

  if command_exists timedatectl; then
    timedatectl status >>"$out" 2>&1 || true
    if timedatectl show 2>/dev/null >>"$out"; then
      :
    fi
    if timedatectl status 2>/dev/null | grep -qiE 'System clock synchronized:\s*yes|NTP synchronized:\s*yes'; then
      SUMMARY_NTP_SYNC="true"
      SUMMARY_NTP_SOURCE="timedatectl"
    elif timedatectl status 2>/dev/null | grep -qiE 'System clock synchronized:\s*no|NTP synchronized:\s*no'; then
      SUMMARY_NTP_SYNC="false"
      SUMMARY_NTP_SOURCE="timedatectl"
    fi
    _record_command time_timedatectl network "timedatectl status" "timedatectl status" "$(utc_now)" 0 0 SUCCESS "network/ntp-status.txt" ""
    SUCCESSFUL_CHECKS=$((SUCCESSFUL_CHECKS + 1))
  else
    printf 'timedatectl: NOT_AVAILABLE\n' >>"$out"
  fi

  if command_exists chronyc; then
    printf '\n=== chronyc tracking ===\n' >>"$out"
    chronyc tracking >>"$out" 2>&1 || true
    printf '\n=== chronyc sources ===\n' >>"$out"
    chronyc sources >>"$out" 2>&1 || true
    if [[ "$SUMMARY_NTP_SOURCE" == "unknown" ]]; then
      if chronyc tracking 2>/dev/null | grep -qi 'Leap status.*Normal'; then
        SUMMARY_NTP_SYNC="true"
        SUMMARY_NTP_SOURCE="chronyc"
      fi
    fi
  fi

  if command_exists ntpq; then
    printf '\n=== ntpq -pn ===\n' >>"$out"
    ntpq -pn >>"$out" 2>&1 || true
    if [[ "$SUMMARY_NTP_SOURCE" == "unknown" ]]; then
      if ntpq -pn 2>/dev/null | grep -qE '^\*'; then
        SUMMARY_NTP_SYNC="true"
        SUMMARY_NTP_SOURCE="ntpq"
      fi
    fi
  fi

  if command_exists systemctl; then
    printf '\n=== systemd-timesyncd ===\n' >>"$out"
    systemctl status systemd-timesyncd.service --no-pager >>"$out" 2>&1 || true
  fi

  if [[ "$SUMMARY_NTP_SYNC" == "null" ]]; then
    append_finding "NTP synchronization could not be confirmed"
  fi
}

# ---------------------------------------------------------------------------
# Collectors: services
# ---------------------------------------------------------------------------

collect_services() {
  log_info "Starting services collection"
  local out="${RESULT_DIR}/services"

  if command_exists systemctl; then
    run_check svc_failed services "systemctl --failed" "systemctl --failed --no-pager" "services/systemctl-failed.txt"
    run_check svc_running services "systemctl list-units services" \
      "systemctl list-units --type=service --no-pager --all" "services/systemctl-running.txt" 60
    run_check svc_unit_files services "systemctl list-unit-files" \
      "systemctl list-unit-files --type=service --no-pager" "services/systemctl-unit-files.txt" 60
  else
    write_note "${out}/systemctl-failed.txt" "NOT_AVAILABLE: systemctl"
    write_note "${out}/systemctl-running.txt" "NOT_AVAILABLE: systemctl"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 2))
  fi

  {
    printf '# services matching aella|stellar|data|sensor|dl|da|worker\n'
    if command_exists systemctl; then
      systemctl list-units --type=service --no-pager --all 2>/dev/null | \
        grep -iE 'aella|stellar|data|sensor|\bdl\b|\bda\b|worker' || true
      printf '\n=== unit-files match ===\n'
      systemctl list-unit-files --type=service --no-pager 2>/dev/null | \
        grep -iE 'aella|stellar|data|sensor|\bdl\b|\bda\b|worker' || true
    else
      printf 'systemctl not available; process grep fallback\n'
      ps auxww 2>/dev/null | grep -iE 'aella|stellar|sensor|worker' | grep -v grep || true
    fi
  } >"${out}/aella-services.txt"

  run_available_check svc_ps services "ps auxww" ps "ps auxww" "services/processes.txt" 30

  {
    printf '# listening ports\n'
    if command_exists ss; then
      ss -lntup 2>/dev/null || ss -lntu 2>/dev/null || true
    elif command_exists netstat; then
      netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null || true
    else
      printf 'NOT_AVAILABLE: ss/netstat\n'
    fi
  } >"${out}/listening-ports.txt"

  if command_exists docker; then
    run_check docker_ver services "docker version" "docker version" "services/docker-version.txt" 30
    run_check docker_info services "docker info" "docker info" "services/docker-info.txt" 60
    run_check docker_ps services "docker ps -a" "docker ps -a --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}'" "services/docker-ps.txt" 60
    run_check docker_images services "docker images" "docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'" "services/docker-images.txt" 60
    {
      printf '# compose projects (names/status only; no env/secrets)\n'
      if docker compose version >/dev/null 2>&1; then
        docker compose ls 2>/dev/null || true
      elif command_exists docker-compose; then
        printf 'docker-compose binary present; listing via ps may be incomplete without project dir\n'
        docker-compose version 2>/dev/null || true
      else
        printf 'compose not available\n'
      fi
    } >"${out}/docker-compose-projects.txt"
  else
    write_note "${out}/docker-info.txt" "NOT_AVAILABLE: docker"
    write_note "${out}/docker-ps.txt" "NOT_AVAILABLE: docker"
    write_note "${out}/docker-compose-projects.txt" "NOT_AVAILABLE: docker"
    SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
  fi

  log_info "Finished services collection"
}

# ---------------------------------------------------------------------------
# Collectors: DP version / role / cluster
# ---------------------------------------------------------------------------

collect_dp() {
  log_info "Starting DP evidence collection"
  local out="${RESULT_DIR}/dp"
  local versions_tmp="${TMP_DIR}/dp_versions.txt"
  : >"$versions_tmp"

  {
    printf '# DP version evidence (multi-source)\n'
    printf 'collected_at_utc=%s\n\n' "$(utc_now)"

    printf '=== dpkg packages matching aella/stellar ===\n'
    if command_exists dpkg-query; then
      dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2>/dev/null | grep -iE 'aella|stellar' || true
      dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | grep -iE 'aella|stellar' | while IFS=$'\t' read -r pkg ver; do
        printf '%s\n' "$ver" >>"$versions_tmp"
      done
    fi

    printf '\n=== version files under /opt/aelladata ===\n'
    local vf
    for vf in \
      /opt/aelladata/version \
      /opt/aelladata/VERSION \
      /opt/aelladata/dp_version \
      /opt/aelladata/metarepo/version \
      /opt/aelladata/provision/version \
      /opt/aelladata/aella/version \
      /opt/aelladata/conf/version \
      /etc/aella/version \
      /opt/aella/version; do
      if [[ -f "$vf" && -r "$vf" ]]; then
        printf 'FILE %s: ' "$vf"
        # Only read small files
        local sz
        sz="$(wc -c <"$vf" 2>/dev/null | tr -d ' ')"
        if [[ "${sz:-0}" -lt 4096 ]]; then
          tr -d '\0' <"$vf" | head -c 512
          printf '\n'
          tr -d '\0\n' <"$vf" | head -c 128 >>"$versions_tmp"
          printf '\n' >>"$versions_tmp"
        else
          printf '(skipped large file size=%s)\n' "$sz"
        fi
      fi
    done

    printf '\n=== docker image tags (aella/stellar) ===\n'
    if command_exists docker; then
      docker ps -a --format '{{.Image}}' 2>/dev/null | grep -iE 'aella|stellar' || true
      docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE 'aella|stellar' || true
    fi

    printf '\n=== read-only CLI version probes ===\n'
    for cli in aella-cli stellar-cli aellactl; do
      if command_exists "$cli"; then
        printf 'trying %s version\n' "$cli"
        # Only safe read-only subcommands
        timeout 10s "$cli" version 2>&1 | take_lines 20 || true
        timeout 10s "$cli" --version 2>&1 | take_lines 20 || true
      fi
    done
  } >"${out}/version-evidence.txt" 2>&1

  # Resolve version status
  local uniq_versions
  uniq_versions="$(sort -u "$versions_tmp" 2>/dev/null | sed '/^$/d' | head -n 20)"
  local vcount
  vcount="$(printf '%s\n' "$uniq_versions" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$vcount" -eq 0 ]]; then
    SUMMARY_DP_VERSION="null"
    SUMMARY_DP_VERSION_STATUS="unknown"
    append_finding "DP version could not be detected"
  elif [[ "$vcount" -eq 1 ]]; then
    SUMMARY_DP_VERSION="$(printf '%s' "$uniq_versions" | head -n 1)"
    SUMMARY_DP_VERSION_STATUS="detected"
  else
    SUMMARY_DP_VERSION="$(printf '%s' "$uniq_versions" | head -n 1)"
    SUMMARY_DP_VERSION_STATUS="conflicting"
    append_warning "Conflicting DP version evidence found"
  fi

  {
    printf '# Role evidence\n'
    printf 'collected_at_utc=%s\n\n' "$(utc_now)"
    local role_hints="${TMP_DIR}/roles.txt"
    : >"$role_hints"

    for p in \
      /opt/aelladata/conf/role \
      /opt/aelladata/role \
      /opt/aelladata/cluster/role \
      /opt/aelladata/provision/role \
      /etc/aella/role \
      /opt/aelladata/cluster-name \
      /opt/aelladata/release-metadata.yml \
      /opt/aelladata/release-image.yml; do
      if [[ -f "$p" && -r "$p" ]]; then
        local sz
        sz="$(wc -c <"$p" 2>/dev/null | tr -d ' ')"
        if [[ "${sz:-0}" -lt 65536 ]]; then
          printf 'FILE %s: %s\n' "$p" "$(tr -d '\0' <"$p" | head -c 256)"
          tr -d '\0\n' <"$p" | head -c 256 >>"$role_hints"
          printf '\n' >>"$role_hints"
        fi
      fi
    done

    printf '\n=== package name hints ===\n'
    if command_exists dpkg-query; then
      dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -iE 'aella|stellar' | take_lines 50 || true
      dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -iE 'aella|stellar' >>"$role_hints" || true
    fi

    printf '\n=== service name hints ===\n'
    if command_exists systemctl; then
      systemctl list-units --type=service --no-pager --all 2>/dev/null | \
        grep -iE 'aella|stellar|data-lake|data_analyzer|dl-|da-|worker|aio|cluster' || true
      systemctl list-units --type=service --no-pager --all 2>/dev/null | \
        grep -iE 'aella|stellar|cluster|worker' >>"$role_hints" || true
    fi
    printf '\n=== process hints ===\n'
    ps auxww 2>/dev/null | grep -iE 'aella|stellar|data.lake|analyzer|/aella_cm/' | grep -v grep | take_lines 40 || true

    printf '\n=== aelladata layout hints ===\n'
    for d in kubernetes cluster-manager cluster-controller cms aelladeb aelladeb_py3 da-upgrade esdata mongodb work; do
      if [[ -e "/opt/aelladata/$d" ]]; then
        printf 'PRESENT /opt/aelladata/%s\n' "$d"
        printf 'layout:%s\n' "$d" >>"$role_hints"
      fi
    done

    # Heuristic role (multi-signal; prefer AIO when DA+cluster+k8s co-located)
    local role="UNKNOWN"
    local has_da=0 has_dl=0 has_cluster=0 has_k8s=0 has_worker_only=0 has_aio_word=0
    grep -qiE 'aella-da|aella_da|da-services|da-cli' "$role_hints" "${out}/version-evidence.txt" 2>/dev/null && has_da=1
    grep -qiE 'aella-dl|aella_dl|data.?lake|aella_conf_dl|aella_ctrl_dl' "$role_hints" 2>/dev/null && has_dl=1
    grep -qiE 'aella_cluster|cluster-manager|cluster-controller|aellacm|layout:cluster' "$role_hints" 2>/dev/null && has_cluster=1
    grep -qiE 'layout:kubernetes|\.kube|kube-' "$role_hints" 2>/dev/null && has_k8s=1
    grep -qiE '\bAIO\b|all.in.one' "$role_hints" 2>/dev/null && has_aio_word=1
    if grep -qiE 'cm_worker|aella-cm-worker|/worker_' "$role_hints" 2>/dev/null && \
       ! grep -qiE 'aella_cluster_controller|aella_cluster_manager|kube-scheduler' "$role_hints" 2>/dev/null; then
      has_worker_only=1
    fi

    if [[ "$has_aio_word" -eq 1 ]] || { [[ "$has_da" -eq 1 || "$has_dl" -eq 1 ]] && [[ "$has_cluster" -eq 1 || "$has_k8s" -eq 1 ]]; }; then
      role="AIO"
    elif [[ "$has_dl" -eq 1 && "$has_da" -eq 0 ]]; then
      role="DL"
    elif [[ "$has_da" -eq 1 ]]; then
      role="DA"
    elif [[ "$has_worker_only" -eq 1 ]]; then
      role="worker"
    elif grep -qiE 'master' "$role_hints" 2>/dev/null; then
      role="master"
    elif grep -qiE 'worker' "$role_hints" 2>/dev/null; then
      role="worker"
    fi
    printf '\nhas_da=%s has_dl=%s has_cluster=%s has_k8s=%s\n' "$has_da" "$has_dl" "$has_cluster" "$has_k8s"
    printf 'resolved_role_hint=%s\n' "$role"
    if [[ "$role" != "UNKNOWN" ]]; then
      SUMMARY_DP_ROLE="$role"
    else
      SUMMARY_DP_ROLE="null"
    fi
  } >"${out}/role-evidence.txt" 2>&1

  {
    printf '# Cluster evidence\n'
    local workers_tmp="${TMP_DIR}/workers.txt"
    : >"$workers_tmp"
    SUMMARY_CLUSTER_DETECTED="false"

    for p in \
      /opt/aelladata/conf/cluster.conf \
      /opt/aelladata/conf/workers \
      /opt/aelladata/cluster/workers \
      /opt/aelladata/cluster/nodes \
      /opt/aelladata/provision/workers \
      /opt/aelladata/conf/worker_ips \
      /opt/aelladata/worker_ips \
      /opt/aelladata/cluster-name \
      /opt/aelladata/release-metadata.yml; do
      if [[ -f "$p" && -r "$p" ]]; then
        local sz
        sz="$(wc -c <"$p" 2>/dev/null | tr -d ' ')"
        printf 'FILE %s size=%s\n' "$p" "$sz"
        if [[ "${sz:-0}" -lt 65536 ]]; then
          redact_stream <"$p" | take_lines 200
          grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$p" 2>/dev/null >>"$workers_tmp" || true
          SUMMARY_CLUSTER_DETECTED="true"
        else
          printf '(skipped large file)\n'
        fi
        printf '\n'
      fi
    done

    printf '\n=== directory presence ===\n'
    for d in /opt/aelladata/cluster /opt/aelladata/conf /opt/aelladata/provision /opt/aelladata/metarepo \
             /opt/aelladata/cluster-manager /opt/aelladata/cluster-controller /opt/aelladata/kubernetes \
             /opt/aelladata/cms /opt/aelladata/.kube; do
      if [[ -d "$d" ]]; then
        printf 'DIR %s exists\n' "$d"
        SUMMARY_CLUSTER_DETECTED="true"
      fi
    done

    printf '\n=== systemd cluster units ===\n'
    if command_exists systemctl; then
      if systemctl list-units --type=service --no-pager --all 2>/dev/null | grep -qiE 'aella_cluster'; then
        systemctl list-units --type=service --no-pager --all 2>/dev/null | grep -iE 'aella_cluster' || true
        SUMMARY_CLUSTER_DETECTED="true"
      fi
    fi
  } >"${out}/cluster-evidence.txt"

  {
    if [[ -f "${TMP_DIR}/workers.txt" ]]; then
      sort -u "${TMP_DIR}/workers.txt" | sed '/^$/d'
    fi
  } >"${out}/worker-ips.txt"

  # Build worker JSON array
  SUMMARY_WORKER_IPS_JSON="[]"
  if [[ -s "${out}/worker-ips.txt" ]]; then
    local first=1
    SUMMARY_WORKER_IPS_JSON="["
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      if [[ $first -eq 1 ]]; then
        SUMMARY_WORKER_IPS_JSON="${SUMMARY_WORKER_IPS_JSON}\"$(json_escape "$ip")\""
        first=0
      else
        SUMMARY_WORKER_IPS_JSON="${SUMMARY_WORKER_IPS_JSON},\"$(json_escape "$ip")\""
      fi
    done <"${out}/worker-ips.txt"
    SUMMARY_WORKER_IPS_JSON="${SUMMARY_WORKER_IPS_JSON}]"
  fi

  {
    printf '=== /opt/aelladata mount details ===\n'
    if [[ -e /opt/aelladata ]]; then
      ls -ld /opt/aelladata 2>/dev/null || true
      if command_exists findmnt; then
        findmnt -T /opt/aelladata 2>/dev/null || true
      fi
      df -hT /opt/aelladata 2>/dev/null || true
      if [[ -L /opt/aelladata ]]; then
        printf 'symlink_target=%s\n' "$(readlink /opt/aelladata)"
      fi
    else
      printf 'MISSING\n'
    fi
  } >"${out}/aelladata-mount.txt"

  {
    printf '# Important paths existence\n'
    for p in \
      /opt/aelladata \
      /opt/aelladata/os-upgrade \
      /opt/aelladata/aelladeb_py3 \
      /opt/aelladata/aelladeb \
      /opt/aelladata/conf \
      /opt/aelladata/cluster \
      /opt/aelladata/cluster-manager \
      /opt/aelladata/cluster-controller \
      /opt/aelladata/kubernetes \
      /opt/aelladata/metarepo \
      /opt/aelladata/provision \
      /var/log/aella \
      /var/log/dist-upgrade; do
      if [[ -e "$p" ]]; then
        local t="path"
        [[ -d "$p" ]] && t="dir"
        [[ -f "$p" ]] && t="file"
        [[ -L "$p" ]] && t="symlink"
        printf 'PRESENT\t%s\t%s\n' "$t" "$p"
      else
        printf 'ABSENT\t-\t%s\n' "$p"
      fi
    done
  } >"${out}/important-paths.txt"

  log_info "Finished DP evidence collection"
}

# ---------------------------------------------------------------------------
# Collectors: upgrade state / logs
# ---------------------------------------------------------------------------

_safe_copy_state_file() {
  local src="$1"
  local dst_dir="$2"
  local base
  base="$(basename "$src")"
  base="$(sanitize_filename "$base")"
  if [[ -f "$src" && -r "$src" ]]; then
    if command_exists file && file -b --mime-encoding "$src" 2>/dev/null | grep -qi binary; then
      printf 'SKIPPED_BINARY %s\n' "$src" >"${dst_dir}/${base}.note"
      return 0
    fi
    local sz
    sz="$(wc -c <"$src" 2>/dev/null | tr -d ' ')"
    if [[ "${sz:-0}" -gt 1048576 ]]; then
      # Large state: copy limited
      copy_text_limited "$src" "${dst_dir}/${base}" "$MAX_LOG_LINES"
    else
      redact_file_to "$src" "${dst_dir}/${base}" "upgrade/state-files/${base}" || \
        cp -a "$src" "${dst_dir}/${base}" 2>/dev/null || true
    fi
  elif [[ -e "$src" ]]; then
    printf 'UNREADABLE %s\n' "$src" >"${dst_dir}/${base}.note"
  fi
}

collect_upgrade_state() {
  log_info "Starting upgrade state collection"
  local out="${RESULT_DIR}/upgrade"
  SUMMARY_UPGRADE_STATE_DETECTED="false"
  SUMMARY_UPGRADE_STATE="null"
  SUMMARY_HOP_HISTORY="false"

  local state_paths=(
    /opt/aelladata/os-upgrade/state
    /opt/aelladata/os-upgrade/hop_history
  )

  if [[ -d /opt/aelladata/os-upgrade ]]; then
    SUMMARY_UPGRADE_STATE_DETECTED="true"
    {
      printf 'os-upgrade directory present\n'
      ls -la /opt/aelladata/os-upgrade 2>/dev/null || true
    } >"${out}/os-upgrade-state.txt"
    append_finding "Existing OS upgrade state was found"
    # Copy files (not recurse deeply into huge trees)
    local f
    # shellcheck disable=SC2044
    for f in /opt/aelladata/os-upgrade/*; do
      [[ -e "$f" ]] || continue
      if [[ -f "$f" ]]; then
        _safe_copy_state_file "$f" "${out}/state-files"
      elif [[ -d "$f" ]]; then
        printf 'DIR %s\n' "$f" >>"${out}/os-upgrade-state.txt"
      fi
    done
    if [[ -f /opt/aelladata/os-upgrade/state && -r /opt/aelladata/os-upgrade/state ]]; then
      SUMMARY_UPGRADE_STATE="$(tr -d '\0\n' </opt/aelladata/os-upgrade/state | head -c 256)"
      # Avoid secrets in summary
      SUMMARY_UPGRADE_STATE="$(printf '%s' "$SUMMARY_UPGRADE_STATE" | redact_stream | head -c 256)"
    fi
  else
    write_note "${out}/os-upgrade-state.txt" "ABSENT: /opt/aelladata/os-upgrade"
  fi

  if [[ -e /opt/aelladata/os-upgrade/hop_history ]]; then
    SUMMARY_HOP_HISTORY="true"
    copy_text_limited /opt/aelladata/os-upgrade/hop_history "${out}/hop-history.txt" "$MAX_LOG_LINES"
  else
    write_note "${out}/hop-history.txt" "ABSENT: hop_history"
  fi

  # Logs
  if [[ -f /var/log/aella/auto_os_upgrade.log ]]; then
    copy_text_limited /var/log/aella/auto_os_upgrade.log \
      "${out}/aella-upgrade-logs/auto_os_upgrade.log" "$MAX_LOG_LINES"
  else
    write_note "${out}/aella-upgrade-logs/auto_os_upgrade.log" "ABSENT"
  fi

  if [[ -d /var/log/dist-upgrade ]]; then
    local lf count=0
    # shellcheck disable=SC2044
    for lf in /var/log/dist-upgrade/*; do
      [[ -f "$lf" ]] || continue
      count=$((count + 1))
      copy_text_limited "$lf" "${out}/dist-upgrade-logs/$(sanitize_filename "$(basename "$lf")")" "$MAX_LOG_LINES"
    done
    if [[ "$count" -eq 0 ]]; then
      write_note "${out}/dist-upgrade-logs/README.txt" "PRESENT but empty: /var/log/dist-upgrade"
    fi
  else
    write_note "${out}/dist-upgrade-logs/README.txt" "ABSENT: /var/log/dist-upgrade"
  fi

  for lf in /var/log/apt/history.log /var/log/apt/term.log; do
    if [[ -f "$lf" ]]; then
      copy_text_limited "$lf" "${out}/apt-logs/$(basename "$lf")" "$MAX_LOG_LINES"
    fi
  done

  # Extra aella logs if present
  if [[ -d /var/log/aella ]]; then
    local af
    # shellcheck disable=SC2044
    for af in /var/log/aella/*upgrade* /var/log/aella/*os*; do
      [[ -f "$af" ]] || continue
      copy_text_limited "$af" "${out}/aella-upgrade-logs/$(sanitize_filename "$(basename "$af")")" "$MAX_LOG_LINES"
    done
  fi

  log_info "Finished upgrade state collection"
}

# ---------------------------------------------------------------------------
# Collectors: bringup bundle
# ---------------------------------------------------------------------------

_summarize_bundle_dir() {
  # _summarize_bundle_dir <path> <label>
  # Prints summary to stdout; sets BUNDLE_FILE_COUNT for caller.
  local bundle="$1"
  local label="$2"
  BUNDLE_FILE_COUNT=0
  printf 'path=%s\n' "$bundle"
  printf '\n=== top-level listing ===\n'
  ls -la "$bundle" 2>/dev/null || true
  printf '\n=== size ===\n'
  if command_exists timeout && command_exists du; then
    timeout 120s du -sh "$bundle" 2>/dev/null || echo "du timeout/error"
  fi
  local fcount dcount
  fcount="$(timeout 120s find "$bundle" -xdev -type f 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  BUNDLE_FILE_COUNT="${fcount:-0}"
  printf 'file_count=%s\n' "$BUNDLE_FILE_COUNT"
  dcount="$(timeout 120s find "$bundle" -xdev -type d 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  printf 'dir_count=%s\n' "$dcount"
  if [[ "${fcount:-0}" -eq 0 ]]; then
    printf 'empty_or_no_files=true\n'
  else
    printf 'empty_or_no_files=false\n'
  fi
  printf '\n=== broken symlinks (sample) ===\n'
  timeout 60s find "$bundle" -xdev -type l ! -exec test -e {} \; -print 2>/dev/null | take_lines 50 || true
  printf '\n=== deb / version-like filenames (sample) ===\n'
  timeout 60s find "$bundle" -xdev -maxdepth 2 -type f 2>/dev/null | \
    grep -iE '\.deb$|[0-9]+\.[0-9]+' | take_lines 40 || true
  if [[ "$label" == "py3" ]]; then
    printf '\n=== bringup script ===\n'
    local bs
    bs="$(find "$bundle" -xdev -maxdepth 3 -name 'bringup_py3_dp_after_os_upgrade.sh' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$bs" ]]; then
      printf 'found=%s\n' "$bs"
      ls -l "$bs" 2>/dev/null || true
      [[ -x "$bs" ]] && printf 'executable=true\n' || printf 'executable=false\n'
      local sz
      sz="$(wc -c <"$bs" 2>/dev/null | tr -d ' ')"
      if [[ "${sz:-0}" -lt 1048576 ]] && command_exists sha256sum; then
        sha256sum "$bs" 2>/dev/null || true
      fi
    else
      printf 'found=false\n'
    fi
    printf '\n=== small metadata checksums (size < 1MiB) ===\n'
    local mf
    while IFS= read -r mf; do
      [[ -z "$mf" ]] && continue
      local sz
      sz="$(wc -c <"$mf" 2>/dev/null | tr -d ' ')"
      if [[ "${sz:-0}" -lt 1048576 ]] && command_exists sha256sum; then
        sha256sum "$mf" 2>/dev/null || true
      else
        printf 'SKIP_LARGE %s size=%s\n' "$mf" "$sz"
      fi
    done < <(timeout 60s find "$bundle" -xdev -maxdepth 3 -type f \( \
      -iname '*manifest*' -o -iname '*checksum*' -o -name '*.sha256' -o -name 'SHA256SUMS' -o -name '*.md5' \
      -o -name '*.sh' -o -name '*.json' -o -name '*.txt' -o -name '*.yml' -o -name '*.yaml' \
    \) 2>/dev/null | take_lines 30)
  fi
}

collect_bringup_bundle() {
  log_info "Starting bringup bundle collection"
  local out_py3="${RESULT_DIR}/dp/aelladeb-py3-summary.txt"
  local out_legacy="${RESULT_DIR}/dp/aelladeb-summary.txt"
  local bundle_py3="" bundle_legacy=""
  local cand

  for cand in /opt/aelladata/aelladeb_py3 /opt/aelladata/aelladeb-py3 /opt/aelladeb_py3; do
    if [[ -d "$cand" ]]; then
      bundle_py3="$cand"
      break
    fi
  done
  for cand in /opt/aelladata/aelladeb /opt/aelladeb; do
    if [[ -d "$cand" ]]; then
      bundle_legacy="$cand"
      break
    fi
  done

  SUMMARY_AELLADEB_EXISTS="false"
  SUMMARY_AELLADEB_FILE_COUNT=0
  SUMMARY_AELLADEB_LEGACY_EXISTS="false"
  SUMMARY_AELLADEB_LEGACY_FILE_COUNT=0

  {
    printf 'collected_at_utc=%s\n' "$(utc_now)"
    if [[ -z "$bundle_py3" ]]; then
      printf 'aelladeb_py3_exists=false\n'
      append_finding "aelladeb_py3 was not found"
    else
      SUMMARY_AELLADEB_EXISTS="true"
      printf 'aelladeb_py3_exists=true\n'
      BUNDLE_FILE_COUNT=0
      _summarize_bundle_dir "$bundle_py3" py3
      SUMMARY_AELLADEB_FILE_COUNT="${BUNDLE_FILE_COUNT:-0}"
    fi
  } >"$out_py3"

  {
    printf 'collected_at_utc=%s\n' "$(utc_now)"
    if [[ -z "$bundle_legacy" ]]; then
      printf 'aelladeb_exists=false\n'
    else
      SUMMARY_AELLADEB_LEGACY_EXISTS="true"
      printf 'aelladeb_exists=true\n'
      BUNDLE_FILE_COUNT=0
      _summarize_bundle_dir "$bundle_legacy" legacy
      SUMMARY_AELLADEB_LEGACY_FILE_COUNT="${BUNDLE_FILE_COUNT:-0}"
    fi
  } >"$out_legacy"

  log_info "Finished bringup bundle collection"
}

# ---------------------------------------------------------------------------
# Collectors: data preservation manifest
# ---------------------------------------------------------------------------

_is_sensitive_path() {
  local p="$1"
  printf '%s' "$p" | grep -qiE '(^|/)(\.ssh|private|secret|credential|password|passwd|token|cookie|id_rsa|id_dsa|\.pem|\.key|shadow|gshadow)(/|$)|(\.pcap|\.pcapng|\.sql|\.dump|\.db)$'
}

collect_data_manifest() {
  log_info "Starting data preservation collection"
  local out="${RESULT_DIR}/data-preservation"
  ensure_dir "$out"

  {
    printf 'notes generated_at_utc=%s\n' "$(utc_now)"
    printf 'deep_manifest=%s\n' "$DEEP_MANIFEST"
    printf 'Sensitive content (keys, passwords, DB dumps, pcaps) is not collected.\n'
    printf 'Only metadata and small non-sensitive config checksums are recorded.\n'
  } >"${out}/manifest-notes.txt"

  if [[ ! -d /opt/aelladata ]]; then
    write_note "${out}/aelladata-top-level.txt" "ABSENT: /opt/aelladata"
    write_note "${out}/aelladata-size-summary.txt" "ABSENT"
    write_note "${out}/aelladata-metadata-manifest.tsv" "ABSENT"
    write_note "${out}/critical-config-checksums.tsv" "ABSENT"
    return 0
  fi

  {
    printf '=== top-level entries ===\n'
    ls -la /opt/aelladata 2>/dev/null || true
    printf '\n=== mount / filesystem ===\n'
    df -hT /opt/aelladata 2>/dev/null || true
    if command_exists findmnt; then
      findmnt -T /opt/aelladata -o TARGET,SOURCE,FSTYPE,UUID,OPTIONS 2>/dev/null || true
    fi
    printf '\n=== ownership ===\n'
    ls -ld /opt/aelladata 2>/dev/null || true
  } >"${out}/aelladata-top-level.txt"

  {
    printf 'path\tsize\n'
    if command_exists timeout && command_exists du; then
      timeout 180s du -sk /opt/aelladata/* /opt/aelladata/.[!.]* 2>/dev/null | sort -n || true
      printf '\n=== total ===\n'
      timeout 180s du -sh /opt/aelladata 2>/dev/null || echo "du timeout"
    else
      echo "du/timeout unavailable"
    fi
    printf '\n=== counts (timeout protected) ===\n'
    if command_exists timeout; then
      printf 'files=%s\n' "$(timeout 180s find /opt/aelladata -xdev -type f 2>/dev/null | wc -l | tr -d ' ')"
      printf 'dirs=%s\n' "$(timeout 180s find /opt/aelladata -xdev -type d 2>/dev/null | wc -l | tr -d ' ')"
    fi
  } >"${out}/aelladata-size-summary.txt"

  # Critical small configs checksums
  {
    printf 'path\tsize_bytes\tsha256\n'
    local cf
    for cf in \
      /opt/aelladata/conf/role \
      /opt/aelladata/version \
      /opt/aelladata/VERSION \
      /opt/aelladata/os-upgrade/state \
      /opt/aelladata/os-upgrade/hop_history \
      /opt/aelladata/cluster-name \
      /opt/aelladata/release-metadata.yml \
      /opt/aelladata/release-image.yml; do
      if [[ -f "$cf" && -r "$cf" ]]; then
        if _is_sensitive_path "$cf"; then
          printf '%s\tSKIPPED_SENSITIVE\t-\n' "$cf"
          continue
        fi
        local sz
        sz="$(wc -c <"$cf" 2>/dev/null | tr -d ' ')"
        if [[ "${sz:-0}" -lt 1048576 ]] && command_exists sha256sum; then
          printf '%s\t%s\t%s\n' "$cf" "$sz" "$(sha256sum "$cf" 2>/dev/null | awk '{print $1}')"
        else
          printf '%s\t%s\tSKIPPED_LARGE_OR_NO_SHA\n' "$cf" "$sz"
        fi
      fi
    done
  } >"${out}/critical-config-checksums.tsv"

  # Manifest
  printf 'relative_path\tfile_type\tsize_bytes\tmtime_epoch\tmode\tuid\tgid\tsymlink_target\n' \
    >"${out}/aelladata-metadata-manifest.tsv"

  if [[ "$DEEP_MANIFEST" -eq 1 ]]; then
    log_info "Generating deep metadata manifest for /opt/aelladata"
    local manifest_timeout=600
    if command_exists timeout && command_exists find; then
      # Use find -printf if available (GNU find)
      if find --version >/dev/null 2>&1; then
        timeout "${manifest_timeout}s" find /opt/aelladata -xdev \
          \( -path '/opt/aelladata/proc' -o -path '/opt/aelladata/sys' -o -path '/opt/aelladata/dev' \) -prune -o \
          -printf '%P\t%y\t%s\t%T@\t%m\t%U\t%G\t%l\n' 2>"${TMP_DIR}/manifest.err" | \
          sort >>"${out}/aelladata-metadata-manifest.tsv" || true
      else
        # Avoid pipeline subshell + local; use process substitution.
        while IFS= read -r -d '' p; do
          rel="${p#/opt/aelladata/}"
          [[ "$p" == /opt/aelladata ]] && rel="."
          if _is_sensitive_path "$p"; then
            continue
          fi
          ftype="f"; sz=0; mtime=0; mode=""; uid=""; gid=""; target=""
          if [[ -L "$p" ]]; then ftype="l"; target="$(readlink "$p" 2>/dev/null || true)"
          elif [[ -d "$p" ]]; then ftype="d"
          elif [[ -f "$p" ]]; then ftype="f"
          else ftype="o"
          fi
          if command_exists stat; then
            sz="$(stat -c '%s' "$p" 2>/dev/null || echo 0)"
            mtime="$(stat -c '%Y' "$p" 2>/dev/null || echo 0)"
            mode="$(stat -c '%a' "$p" 2>/dev/null || true)"
            uid="$(stat -c '%u' "$p" 2>/dev/null || true)"
            gid="$(stat -c '%g' "$p" 2>/dev/null || true)"
          fi
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$ftype" "$sz" "$mtime" "$mode" "$uid" "$gid" "$target"
        done < <(timeout "${manifest_timeout}s" find /opt/aelladata -xdev -print0 2>"${TMP_DIR}/manifest.err") | \
          sort >>"${out}/aelladata-metadata-manifest.tsv" || true
      fi
      if [[ -s "${TMP_DIR}/manifest.err" ]]; then
        printf '\nmanifest errors:\n' >>"${out}/manifest-notes.txt"
        head -n 100 "${TMP_DIR}/manifest.err" >>"${out}/manifest-notes.txt"
      fi
    else
      printf 'deep manifest skipped: find/timeout unavailable\n' >>"${out}/manifest-notes.txt"
    fi
  else
    # Shallow: top-level metadata only
    local e
    for e in /opt/aelladata/* /opt/aelladata/.[!.]*; do
      [[ -e "$e" ]] || continue
      local rel="${e#/opt/aelladata/}"
      local ftype="f" sz=0 mtime=0 mode="" uid="" gid="" target=""
      if [[ -L "$e" ]]; then ftype="l"; target="$(readlink "$e" 2>/dev/null || true)"
      elif [[ -d "$e" ]]; then ftype="d"
      elif [[ -f "$e" ]]; then ftype="f"
      else ftype="o"
      fi
      if command_exists stat; then
        sz="$(stat -c '%s' "$e" 2>/dev/null || echo 0)"
        mtime="$(stat -c '%Y' "$e" 2>/dev/null || echo 0)"
        mode="$(stat -c '%a' "$e" 2>/dev/null || true)"
        uid="$(stat -c '%u' "$e" 2>/dev/null || true)"
        gid="$(stat -c '%g' "$e" 2>/dev/null || true)"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$ftype" "$sz" "$mtime" "$mode" "$uid" "$gid" "$target" \
        >>"${out}/aelladata-metadata-manifest.tsv"
    done
    printf 'default shallow manifest (top-level only); use --deep-manifest for full metadata\n' \
      >>"${out}/manifest-notes.txt"
  fi

  log_info "Finished data preservation collection"
}

# ---------------------------------------------------------------------------
# Findings / summary / archive
# ---------------------------------------------------------------------------

generate_findings() {
  log_info "Generating findings"
  # Additional fact-based findings already appended during collection.
  # Ensure file exists even if empty.
  if [[ ! -s "$FINDINGS_FILE" ]]; then
    printf '(no automatic findings)\n' >"$FINDINGS_FILE"
  fi
}

_warnings_json() {
  if [[ ! -s "${WARNINGS_FILE:-}" ]]; then
    printf '[]'
    return
  fi
  local first=1
  printf '['
  while IFS= read -r w; do
    [[ -z "$w" ]] && continue
    if [[ $first -eq 1 ]]; then
      printf '"%s"' "$(json_escape "$w")"
      first=0
    else
      printf ',"%s"' "$(json_escape "$w")"
    fi
  done <"$WARNINGS_FILE"
  printf ']'
}

generate_summary_json() {
  log_info "Generating summary.json"
  local sudo_user_json
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo_user_json="\"$(json_escape "$SUDO_USER")\""
  else
    sudo_user_json="null"
  fi

  local dp_version_json
  if [[ "$SUMMARY_DP_VERSION" == "null" || -z "$SUMMARY_DP_VERSION" ]]; then
    dp_version_json="null"
  else
    dp_version_json="\"$(json_escape "$SUMMARY_DP_VERSION")\""
  fi

  local dp_role_json
  if [[ "$SUMMARY_DP_ROLE" == "null" || -z "$SUMMARY_DP_ROLE" ]]; then
    dp_role_json="null"
  else
    dp_role_json="\"$(json_escape "$SUMMARY_DP_ROLE")\""
  fi

  local shell_root_json shell_aella_json
  if [[ "$SUMMARY_SHELL_ROOT" == "null" || -z "$SUMMARY_SHELL_ROOT" ]]; then
    shell_root_json="null"
  else
    shell_root_json="\"$(json_escape "$SUMMARY_SHELL_ROOT")\""
  fi
  if [[ "$SUMMARY_SHELL_AELLA" == "null" || -z "$SUMMARY_SHELL_AELLA" ]]; then
    shell_aella_json="null"
  else
    shell_aella_json="\"$(json_escape "$SUMMARY_SHELL_AELLA")\""
  fi

  local upgrade_state_json
  if [[ "$SUMMARY_UPGRADE_STATE" == "null" || -z "$SUMMARY_UPGRADE_STATE" ]]; then
    upgrade_state_json="null"
  else
    upgrade_state_json="\"$(json_escape "$SUMMARY_UPGRADE_STATE")\""
  fi

  local ntp_json
  case "$SUMMARY_NTP_SYNC" in
    true) ntp_json="true" ;;
    false) ntp_json="false" ;;
    *) ntp_json="null" ;;
  esac

  local dpkg_json
  case "$SUMMARY_DPKG_AUDIT_CLEAN" in
    true) dpkg_json="true" ;;
    false) dpkg_json="false" ;;
    *) dpkg_json="null" ;;
  esac

  cat >"${RESULT_DIR}/summary.json" <<EOF
{
  "schema_version": "$(json_escape "$SCHEMA_VERSION")",
  "script_version": "$(json_escape "$SCRIPT_VERSION")",
  "collection_id": "$(json_escape "$COLLECTION_ID")",
  "started_at_utc": "$(json_escape "$STARTED_AT_UTC")",
  "completed_at_utc": "$(json_escape "$COMPLETED_AT_UTC")",
  "duration_seconds": $(json_num_or_null "$DURATION_SECONDS"),
  "hostname": "$(json_escape "$SUMMARY_HOSTNAME")",
  "fqdn": "$(json_escape "$SUMMARY_FQDN")",
  "execution_user": "$(json_escape "$(id -un 2>/dev/null || echo unknown)")",
  "effective_user_id": $(json_num_or_null "$(id -u 2>/dev/null || echo null)"),
  "is_root": $(is_root && echo true || echo false),
  "sudo_user": ${sudo_user_json},
  "os": {
    "id": "$(json_escape "${SUMMARY_OS_ID:-unknown}")",
    "version_id": "$(json_escape "${SUMMARY_OS_VERSION_ID:-unknown}")",
    "codename": "$(json_escape "${SUMMARY_OS_CODENAME:-unknown}")",
    "kernel": "$(json_escape "${SUMMARY_KERNEL:-unknown}")",
    "architecture": "$(json_escape "${SUMMARY_ARCH:-unknown}")"
  },
  "dp": {
    "version": ${dp_version_json},
    "version_status": "$(json_escape "$SUMMARY_DP_VERSION_STATUS")",
    "role": ${dp_role_json},
    "cluster_detected": $(json_bool "$SUMMARY_CLUSTER_DETECTED"),
    "worker_ips": ${SUMMARY_WORKER_IPS_JSON}
  },
  "shells": {
    "root": ${shell_root_json},
    "aella": ${shell_aella_json}
  },
  "storage": {
    "root_available_bytes": $(json_num_or_null "$SUMMARY_ROOT_AVAIL"),
    "boot_available_bytes": $(json_num_or_null "$SUMMARY_BOOT_AVAIL"),
    "aelladata_available_bytes": $(json_num_or_null "$SUMMARY_AELLADATA_AVAIL"),
    "aelladata_mounted": $(json_bool "$SUMMARY_AELLADATA_MOUNTED")
  },
  "time": {
    "utc_now": "$(json_escape "${SUMMARY_UTC_NOW}")",
    "ntp_synchronized": ${ntp_json},
    "source": "$(json_escape "$SUMMARY_NTP_SOURCE")"
  },
  "apt": {
    "dpkg_audit_clean": ${dpkg_json},
    "held_package_count": $(json_num_or_null "$SUMMARY_HELD_COUNT"),
    "source_uri_count": $(json_num_or_null "$SUMMARY_SOURCE_URI_COUNT")
  },
  "upgrade": {
    "existing_state_detected": $(json_bool "$SUMMARY_UPGRADE_STATE_DETECTED"),
    "state": ${upgrade_state_json},
    "hop_history_detected": $(json_bool "$SUMMARY_HOP_HISTORY")
  },
  "bringup": {
    "aelladeb_py3_exists": $(json_bool "$SUMMARY_AELLADEB_EXISTS"),
    "aelladeb_py3_file_count": $(json_num_or_null "$SUMMARY_AELLADEB_FILE_COUNT"),
    "aelladeb_exists": $(json_bool "$SUMMARY_AELLADEB_LEGACY_EXISTS"),
    "aelladeb_file_count": $(json_num_or_null "$SUMMARY_AELLADEB_LEGACY_FILE_COUNT")
  },
  "collection": {
    "status": "$(json_escape "$COLLECTION_STATUS")",
    "successful_checks": $(json_num_or_null "$SUCCESSFUL_CHECKS"),
    "failed_checks": $(json_num_or_null "$FAILED_CHECKS"),
    "skipped_checks": $(json_num_or_null "$SKIPPED_CHECKS"),
    "warnings": $(_warnings_json)
  }
}
EOF
}

generate_summary_text() {
  log_info "Generating summary.txt"
  cat >"${RESULT_DIR}/summary.txt" <<EOF
DP Upgrade Readiness Collection Summary
=======================================
Collection ID : ${COLLECTION_ID}
Script version: ${SCRIPT_VERSION}
Started (UTC) : ${STARTED_AT_UTC}
Completed     : ${COMPLETED_AT_UTC}
Duration (s)  : ${DURATION_SECONDS}
Status        : ${COLLECTION_STATUS}
Checks        : success=${SUCCESSFUL_CHECKS} failed=${FAILED_CHECKS} skipped=${SKIPPED_CHECKS}

Host
----
Hostname : ${SUMMARY_HOSTNAME}
FQDN     : ${SUMMARY_FQDN}
User     : $(id -un 2>/dev/null) (uid=$(id -u 2>/dev/null)) root=$(is_root && echo yes || echo no)
SUDO_USER: ${SUDO_USER:-(none)}

OS
--
ID/Version: ${SUMMARY_OS_ID} ${SUMMARY_OS_VERSION_ID} (${SUMMARY_OS_CODENAME})
Kernel    : ${SUMMARY_KERNEL}
Arch      : ${SUMMARY_ARCH}

DP
--
Version   : ${SUMMARY_DP_VERSION} [${SUMMARY_DP_VERSION_STATUS}]
Role      : ${SUMMARY_DP_ROLE}
Cluster   : ${SUMMARY_CLUSTER_DETECTED}
Workers   : see dp/worker-ips.txt

Shells
------
root : ${SUMMARY_SHELL_ROOT}
aella: ${SUMMARY_SHELL_AELLA}

Storage (available bytes)
-------------------------
/              : ${SUMMARY_ROOT_AVAIL}
/boot          : ${SUMMARY_BOOT_AVAIL}
/opt/aelladata : ${SUMMARY_AELLADATA_AVAIL} (separate_mount=${SUMMARY_AELLADATA_MOUNTED})

Time / NTP
----------
UTC now : ${SUMMARY_UTC_NOW}
NTP sync: ${SUMMARY_NTP_SYNC} (source=${SUMMARY_NTP_SOURCE})

APT
---
dpkg audit clean : ${SUMMARY_DPKG_AUDIT_CLEAN}
held packages    : ${SUMMARY_HELD_COUNT}
source URI count : ${SUMMARY_SOURCE_URI_COUNT}

Upgrade state
-------------
Detected : ${SUMMARY_UPGRADE_STATE_DETECTED}
State    : ${SUMMARY_UPGRADE_STATE}
Hop hist : ${SUMMARY_HOP_HISTORY}

Bringup
-------
aelladeb_py3 : exists=${SUMMARY_AELLADEB_EXISTS} files=${SUMMARY_AELLADEB_FILE_COUNT}
aelladeb     : exists=${SUMMARY_AELLADEB_LEGACY_EXISTS} files=${SUMMARY_AELLADEB_LEGACY_FILE_COUNT}

Findings
--------
$(cat "$FINDINGS_FILE" 2>/dev/null || true)

This archive is evidence only. Next step: dp-upgrade-preflight.sh
EOF
}

scan_for_secrets() {
  log_info "Scanning archive contents for obvious secret patterns"
  local hits="${TMP_DIR}/secret_hits.txt"
  : >"$hits"
  # High-confidence patterns only (avoid apt package-name false positives).
  if command_exists grep; then
    grep -R -I -n -E \
      'https?://[^/@[:space:]]+:[^/@[:space:]]+@|BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|[[:space:]](PASSWORD|TOKEN|SECRET|API[_-]?KEY|CREDENTIAL)=[^[:space:]]{4,}|Authorization:[[:space:]]*[^[:space:]]+' \
      "$RESULT_DIR" 2>/dev/null | \
      grep -v 'redaction-report' | \
      grep -v '\*\*\*REDACTED\*\*\*' | \
      grep -v '\*\*\*:\*\*\*' | \
      grep -v 'pattern=post_scan' | \
      head -n 50 >"$hits" || true
  fi
  if [[ -s "$hits" ]]; then
    log_warn "Potential unretracted secrets detected; scrubbing matching lines"
    printf 'post_scan_hits=%s\n' "$(wc -l <"$hits" | tr -d ' ')" >>"$REDACTION_REPORT"
    local line file
    while IFS= read -r line; do
      file="${line%%:*}"
      [[ -f "$file" ]] || continue
      local tmp
      tmp="$(mktemp "${TMP_DIR}/scrub.XXXXXX")"
      redact_stream <"$file" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file" || rm -f "$tmp"
      note_redaction "${file#"$RESULT_DIR"/}" "post_scan_scrub"
    done <"$hits"
    COLLECTION_STATUS="partial"
    append_warning "Secret patterns were found and scrubbed during post-scan"
  else
    printf 'post_scan_hits=0\n' >>"$REDACTION_REPORT"
    log_info "No obvious unretracted secrets found in post-scan"
  fi
}

create_archive() {
  log_info "Creating tar.gz archive"
  local archive="${OUTPUT_DIR%/}/${RESULT_NAME}.tar.gz"
  # Remove temp dir before archiving
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
    rm -rf "$TMP_DIR" 2>/dev/null || true
    TMP_DIR=""
  fi

  local parent base
  parent="$(dirname "$RESULT_DIR")"
  base="$(basename "$RESULT_DIR")"
  if command_exists tar; then
    local tar_err
    tar_err="$(mktemp "${OUTPUT_DIR%/}/.collect-tar.XXXXXX")"
    if tar -C "$parent" -czf "$archive" "$base" 2>"$tar_err"; then
      log_info "Archive created: $archive"
      rm -f "$tar_err"
    else
      log_error "Failed to create archive"
      if [[ -s "$tar_err" ]]; then
        log_error "$(head -n 5 "$tar_err")"
      fi
      rm -f "$tar_err"
      COLLECTION_STATUS="partial"
      append_warning "Archive creation failed"
      return 1
    fi
  else
    log_error "tar not available"
    return 1
  fi

  # Ownership restore for SUDO_USER
  if [[ -n "${SUDO_USER:-}" ]]; then
    if command_exists chown; then
      chown "${SUDO_USER}:" "$archive" 2>/dev/null || \
        chown "$SUDO_USER" "$archive" 2>/dev/null || \
        log_warn "Could not chown archive to $SUDO_USER"
      if [[ "$KEEP_DIRECTORY" -eq 1 ]]; then
        chown -R "${SUDO_USER}:" "$RESULT_DIR" 2>/dev/null || \
          chown -R "$SUDO_USER" "$RESULT_DIR" 2>/dev/null || true
      fi
    fi
  fi

  if [[ "$KEEP_DIRECTORY" -eq 0 ]]; then
    log_info "Removing result directory (use --keep-directory to retain)"
    rm -rf "$RESULT_DIR" 2>/dev/null || log_warn "Could not remove $RESULT_DIR"
    RESULT_DIR=""
  else
    log_info "Keeping result directory: $RESULT_DIR"
  fi

  printf '%s\n' "$archive"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  STARTED_AT_UTC="$(utc_now)"
  local start_epoch end_epoch
  start_epoch="$(date +%s 2>/dev/null || echo 0)"

  setup_result_dirs

  log_info "Starting $SCRIPT_NAME version $SCRIPT_VERSION"
  log_info "Options: output_dir=$OUTPUT_DIR skip_network=$SKIP_NETWORK deep_manifest=$DEEP_MANIFEST keep_directory=$KEEP_DIRECTORY network_timeout=$NETWORK_TIMEOUT max_log_lines=$MAX_LOG_LINES"
  log_info "Result directory: $RESULT_DIR"
  log_info "Execution user=$(id -un) uid=$(id -u) sudo_user=${SUDO_USER:-}"

  collect_system
  collect_storage
  collect_apt
  collect_network
  collect_services
  collect_dp
  collect_upgrade_state
  collect_bringup_bundle
  collect_data_manifest
  generate_findings

  COMPLETED_AT_UTC="$(utc_now)"
  end_epoch="$(date +%s 2>/dev/null || echo 0)"
  DURATION_SECONDS=$((end_epoch - start_epoch))
  if [[ "$DURATION_SECONDS" -lt 0 ]]; then DURATION_SECONDS=0; fi

  generate_summary_json
  generate_summary_text
  scan_for_secrets

  # Regenerate summary after secret scan may have changed warnings/status
  COMPLETED_AT_UTC="$(utc_now)"
  generate_summary_json
  generate_summary_text

  local archive_path
  archive_path="$(create_archive)" || true

  log_info "Collection finished status=$COLLECTION_STATUS"
  if [[ -n "${archive_path:-}" ]]; then
    log_info "Archive path: $archive_path"
    printf 'Archive: %s\n' "$archive_path"
  fi
  if [[ -n "${RESULT_DIR:-}" && -d "${RESULT_DIR:-}" ]]; then
    printf 'Directory: %s\n' "$RESULT_DIR"
  fi

  # Always exit 0 on successful collection run (partial is still success)
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
