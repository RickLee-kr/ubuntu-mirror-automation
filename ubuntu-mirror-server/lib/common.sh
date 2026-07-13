#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for Ubuntu Mirror Server automation.
# Sourced by install/validate/mirrorctl/client scripts.

# Prevent double-source
# shellcheck disable=SC2317
if [[ -n "${UM_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_COMMON_LOADED=1

set -o errexit
set -o nounset
set -o pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
um_script_dir() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "$src")" && pwd
}

UM_PROJECT_ROOT="${UM_PROJECT_ROOT:-}"
if [[ -z "$UM_PROJECT_ROOT" ]]; then
  # Prefer caller location: .../ubuntu-mirror-server/<script>
  _um_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  UM_PROJECT_ROOT="$_um_here"
  unset _um_here
fi

UM_LIB_DIR="${UM_LIB_DIR:-$UM_PROJECT_ROOT/lib}"
UM_TEMPLATE_DIR="${UM_TEMPLATE_DIR:-$UM_PROJECT_ROOT/templates}"

# ---------------------------------------------------------------------------
# Colors / output
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
  UM_C_RED=$'\033[0;31m'
  UM_C_GREEN=$'\033[0;32m'
  UM_C_YELLOW=$'\033[0;33m'
  UM_C_BLUE=$'\033[0;34m'
  UM_C_BOLD=$'\033[1m'
  UM_C_RESET=$'\033[0m'
else
  UM_C_RED="" UM_C_GREEN="" UM_C_YELLOW="" UM_C_BLUE="" UM_C_BOLD="" UM_C_RESET=""
fi

um_ts() { date '+%Y-%m-%d %H:%M:%S'; }
um_date_tag() { date '+%Y%m%d'; }
um_datetime_tag() { date '+%Y%m%d-%H%M%S'; }

um_log_file="${UM_LOG_FILE:-}"

um_set_log_file() {
  um_log_file="$1"
  export um_log_file
}

um_ensure_log_dir() {
  local dir
  dir="$(dirname "${um_log_file:-/var/log/ubuntu-mirror/install.log}")"
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || true
  fi
  # Fall back to /tmp if system log dir is not writable
  if [[ -n "${um_log_file:-}" ]] && [[ ! -w "$dir" ]]; then
    local base
    base="$(basename "$um_log_file")"
    um_log_file="/tmp/ubuntu-mirror-logs/${base}"
    mkdir -p /tmp/ubuntu-mirror-logs 2>/dev/null || true
  fi
}

um_log() {
  local level="$1"
  shift
  local msg="$*"
  local line
  line="$(um_ts) [$level] $msg"
  case "$level" in
    ERROR) printf '%s%s%s\n' "$UM_C_RED" "$line" "$UM_C_RESET" >&2 ;;
    WARN)  printf '%s%s%s\n' "$UM_C_YELLOW" "$line" "$UM_C_RESET" >&2 ;;
    INFO)  printf '%s%s%s\n' "$UM_C_BLUE" "$line" "$UM_C_RESET" ;;
    OK)    printf '%s%s%s\n' "$UM_C_GREEN" "$line" "$UM_C_RESET" ;;
    *)     printf '%s\n' "$line" ;;
  esac
  if [[ -n "${um_log_file:-}" ]] && [[ "${UM_DRY_RUN:-0}" != "1" ]]; then
    um_ensure_log_dir
    if [[ -d "$(dirname "$um_log_file")" ]]; then
      printf '%s\n' "$line" >>"$um_log_file" 2>/dev/null || true
    fi
  fi
}

um_info()  { um_log INFO "$*"; }
um_ok()    { um_log OK "$*"; }
um_warn()  { um_log WARN "$*"; }
um_error() { um_log ERROR "$*"; }

um_die() {
  um_error "$*"
  exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Privileges / dry-run
# ---------------------------------------------------------------------------
um_is_root() { [[ "$(id -u)" -eq 0 ]]; }

um_require_root() {
  if ! um_is_root; then
    um_die "This operation requires root. Re-run with sudo." 2
  fi
}

um_run() {
  # Execute a command, or print it in dry-run mode.
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: $*"
    return 0
  fi
  "$@"
}

um_run_shell() {
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: $*"
    return 0
  fi
  bash -c "$*"
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
um_backup_file() {
  # Usage: um_backup_file <path> [backup_dir]
  local path="$1"
  local bdir="${2:-${BACKUP_DIR:-/var/backups/ubuntu-mirror}}"
  local base dest

  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: backup $path"
    return 0
  fi

  mkdir -p "$bdir"
  base="$(basename "$path")"
  dest="$bdir/${base}.$(um_date_tag).bak"
  # Avoid clobbering same-day backups
  if [[ -e "$dest" ]]; then
    dest="$bdir/${base}.$(um_datetime_tag).bak"
  fi
  cp -a "$path" "$dest"
  um_ok "Backup created: $dest"
  printf '%s\n' "$dest"
}

# ---------------------------------------------------------------------------
# Atomic install of files
# ---------------------------------------------------------------------------
um_install_file() {
  # um_install_file <src> <dest> [mode]
  local src="$1"
  local dest="$2"
  local mode="${3:-0644}"
  local tmp dir

  if [[ ! -f "$src" ]]; then
    um_die "Template/source missing: $src"
  fi

  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    um_info "Unchanged: $dest"
    return 0
  fi

  if [[ -e "$dest" ]]; then
    um_backup_file "$dest" >/dev/null || true
  fi

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: install $src -> $dest (mode $mode)"
    return 0
  fi

  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$"
  cp "$src" "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
  um_ok "Installed: $dest"
}

um_write_file() {
  # um_write_file <dest> <mode> <<EOF ... EOF  (via stdin)
  local dest="$1"
  local mode="${2:-0644}"
  local tmp dir content

  content="$(cat)"
  if [[ -f "$dest" ]]; then
    if printf '%s' "$content" | cmp -s - "$dest"; then
      um_info "Unchanged: $dest"
      return 0
    fi
    um_backup_file "$dest" >/dev/null || true
  fi

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_info "DRY-RUN: write $dest (mode $mode)"
    return 0
  fi

  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  tmp="${dest}.tmp.$$"
  printf '%s' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$dest"
  um_ok "Wrote: $dest"
}

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------
um_detect_primary_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  printf '%s\n' "${ip:-127.0.0.1}"
}

um_command_exists() { command -v "$1" >/dev/null 2>&1; }

um_path_mounted() {
  local path="$1"
  findmnt -n -T "$path" >/dev/null 2>&1
}

um_disk_usage_percent() {
  local path="$1"
  df -P "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

um_confirm() {
  # um_confirm "message" — returns 0 if yes. Skipped in non-interactive.
  local msg="$1"
  if [[ "${UM_NON_INTERACTIVE:-0}" == "1" ]]; then
    return 0
  fi
  local ans
  read -r -p "$msg [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Trap / cleanup
# ---------------------------------------------------------------------------
UM_CLEANUP_FUNCS=()

um_register_cleanup() {
  UM_CLEANUP_FUNCS+=("$1")
}

um_cleanup() {
  local fn
  local code=$?
  for fn in "${UM_CLEANUP_FUNCS[@]:-}"; do
    [[ -n "$fn" ]] || continue
    "$fn" || true
  done
  return "$code"
}

um_setup_trap() {
  trap 'um_cleanup' EXIT
  trap 'um_error "Interrupted"; exit 130' INT TERM
}

# ---------------------------------------------------------------------------
# Validation result helpers (PASS/WARNING/FAIL)
# ---------------------------------------------------------------------------
UM_PASS_COUNT=0
UM_WARN_COUNT=0
UM_FAIL_COUNT=0

um_result_reset() {
  UM_PASS_COUNT=0
  UM_WARN_COUNT=0
  UM_FAIL_COUNT=0
}

um_result() {
  local status="$1"
  local name="$2"
  local detail="${3:-}"
  case "$status" in
    PASS)
      ((UM_PASS_COUNT++)) || true
      printf '%s[PASS]%s    %s%s%s\n' "$UM_C_GREEN" "$UM_C_RESET" "$name" \
        "${detail:+ — }" "${detail}"
      ;;
    WARNING)
      ((UM_WARN_COUNT++)) || true
      printf '%s[WARNING]%s %s%s%s\n' "$UM_C_YELLOW" "$UM_C_RESET" "$name" \
        "${detail:+ — }" "${detail}"
      ;;
    FAIL)
      ((UM_FAIL_COUNT++)) || true
      printf '%s[FAIL]%s    %s%s%s\n' "$UM_C_RED" "$UM_C_RESET" "$name" \
        "${detail:+ — }" "${detail}"
      ;;
    *)
      um_error "Unknown result status: $status"
      ;;
  esac
}

um_result_summary() {
  printf '\n%sValidation summary:%s PASS=%s WARNING=%s FAIL=%s\n' \
    "$UM_C_BOLD" "$UM_C_RESET" "$UM_PASS_COUNT" "$UM_WARN_COUNT" "$UM_FAIL_COUNT"
  if [[ "$UM_FAIL_COUNT" -gt 0 ]]; then
    return 2
  fi
  if [[ "$UM_WARN_COUNT" -gt 0 ]]; then
    return 1
  fi
  return 0
}
