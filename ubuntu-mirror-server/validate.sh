#!/usr/bin/env bash
# validate.sh — Comprehensive Ubuntu Mirror Server validation
# Exit codes: 0=all PASS, 1=WARNING(s), 2=FAIL(s)
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer installed libs if present
if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/common.sh
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/config.sh
  UM_PROJECT_ROOT="${UM_PROJECT_ROOT:-/usr/local/lib/ubuntu-mirror}"
else
  # shellcheck source=lib/common.sh
  source "${UM_PROJECT_ROOT}/lib/common.sh"
  # shellcheck source=lib/config.sh
  source "${UM_PROJECT_ROOT}/lib/config.sh"
fi

UM_CONFIG_ARG=""
UM_QUIET=0

usage() {
  cat <<'EOF'
Usage: ./validate.sh [--config PATH] [--quiet]

Checks disk, packages, nginx, systemd, HTTP, Ubuntu dists, permissions, logs, health.
Prints PASS / WARNING / FAIL for each check.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) UM_CONFIG_ARG="${2:-}"; shift 2 ;;
      --quiet) UM_QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

check_ubuntu_version() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      if [[ "${VERSION_ID:-}" == "24.04" ]]; then
        um_result PASS "Ubuntu Version" "${PRETTY_NAME}"
      else
        um_result WARNING "Ubuntu Version" "Guide targets 24.04; found ${PRETTY_NAME}"
      fi
    else
      um_result WARNING "Ubuntu Version" "Non-Ubuntu host: ${PRETTY_NAME:-unknown}"
    fi
  else
    um_result FAIL "Ubuntu Version" "/etc/os-release missing"
  fi
}

check_disk_mounted() {
  if [[ ! -d "$BASE_PATH" ]]; then
    um_result FAIL "Disk Mounted" "BASE_PATH missing: $BASE_PATH"
    return
  fi
  if um_path_mounted "$BASE_PATH"; then
    local src
    src="$(findmnt -n -o SOURCE -T "$BASE_PATH" 2>/dev/null || echo unknown)"
    # Warn if same filesystem as root and DATA_DEVICE expected
    local root_src base_src
    root_src="$(findmnt -n -o SOURCE -T / 2>/dev/null || true)"
    base_src="$src"
    if [[ -n "$DATA_DEVICE" ]] && [[ "$root_src" == "$base_src" ]]; then
      um_result WARNING "Disk Mounted" "$BASE_PATH on root FS; DATA_DEVICE=$DATA_DEVICE not separate"
    else
      um_result PASS "Disk Mounted" "$BASE_PATH <- $src"
    fi
  else
    um_result FAIL "Disk Mounted" "$BASE_PATH not a mount point"
  fi
}

check_disk_space() {
  if [[ ! -d "$BASE_PATH" ]]; then
    um_result FAIL "Disk Space" "path missing"
    return
  fi
  local pct avail_kib avail_gib
  pct="$(um_disk_usage_percent "$BASE_PATH" || echo 0)"
  avail_kib="$(df -Pk "$BASE_PATH" | awk 'NR==2 {print $4}')"
  avail_gib=$((avail_kib / 1024 / 1024))
  if [[ "$pct" -ge "${DISK_CRIT_PERCENT}" ]]; then
    um_result FAIL "Disk Space" "${pct}% used, ${avail_gib} GiB free (crit>=${DISK_CRIT_PERCENT}%)"
  elif [[ "$pct" -ge "${DISK_WARN_PERCENT}" ]]; then
    um_result WARNING "Disk Space" "${pct}% used, ${avail_gib} GiB free"
  elif [[ "$avail_gib" -lt "${MIN_FREE_GIB}" ]] && [[ ! -d "$DIST_ROOT/noble" ]]; then
    um_result WARNING "Disk Space" "${avail_gib} GiB free < recommended ${MIN_FREE_GIB} GiB for initial full sync"
  else
    um_result PASS "Disk Space" "${pct}% used, ${avail_gib} GiB free"
  fi
}

check_mirror_directory() {
  local ok=1
  for d in "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH"; do
    if [[ ! -d "$d" ]]; then
      ok=0
      um_result FAIL "Mirror Directory" "missing $d"
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    um_result PASS "Mirror Directory" "$BASE_PATH/{mirror,skel,var}"
  fi
}

check_apt_mirror_installed() {
  if um_command_exists apt-mirror; then
    um_result PASS "apt-mirror installed" "$(command -v apt-mirror)"
  else
    um_result FAIL "apt-mirror installed" "not found in PATH"
  fi
  if [[ -f /etc/apt/mirror.list ]]; then
    if grep -qE '^set[[:space:]]+base_path' /etc/apt/mirror.list; then
      um_result PASS "apt-mirror config" "base_path set in /etc/apt/mirror.list"
    else
      um_result FAIL "apt-mirror config" "base_path missing/commented (invalid config)"
    fi
  else
    um_result FAIL "apt-mirror config" "/etc/apt/mirror.list missing"
  fi
}

check_nginx_installed() {
  if um_command_exists nginx; then
    um_result PASS "nginx installed" "$(command -v nginx)"
  else
    um_result FAIL "nginx installed" "not found"
    return
  fi
  if systemctl is-active --quiet nginx 2>/dev/null; then
    um_result PASS "nginx running" "active"
  else
    um_result FAIL "nginx running" "not active"
  fi
}

check_nginx_config() {
  if ! um_command_exists nginx; then
    um_result FAIL "nginx config valid" "nginx missing"
    return
  fi
  if nginx -t >/dev/null 2>&1; then
    um_result PASS "nginx config valid" "nginx -t ok"
  else
    um_result FAIL "nginx config valid" "nginx -t failed"
  fi
  local site="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"
  if [[ -e "$site" ]]; then
    um_result PASS "nginx site enabled" "$site"
  else
    um_result FAIL "nginx site enabled" "$site missing"
  fi
}

check_systemd_service() {
  if [[ -f /etc/systemd/system/apt-mirror.service ]]; then
    if systemctl cat apt-mirror.service >/dev/null 2>&1; then
      um_result PASS "systemd service" "apt-mirror.service present"
    else
      um_result FAIL "systemd service" "cannot load apt-mirror.service"
    fi
  else
    um_result FAIL "systemd service" "unit file missing"
  fi
}

check_systemd_timer() {
  if [[ -f /etc/systemd/system/apt-mirror.timer ]]; then
    if systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
      um_result PASS "systemd timer" "enabled"
    else
      um_result WARNING "systemd timer" "present but not enabled"
    fi
    if systemctl is-active --quiet apt-mirror.timer 2>/dev/null; then
      um_result PASS "systemd timer active" "waiting for calendar event"
    else
      um_result WARNING "systemd timer active" "not started (enable after initial sync)"
    fi
  else
    um_result FAIL "systemd timer" "unit file missing"
  fi
}

check_mirror_url_reachable() {
  local url="${MIRROR_URL}"
  local code
  code="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC}" -w '%{http_code}' "$url" 2>/dev/null || true)"
  if [[ -z "$code" ]]; then
    code="000"
  fi
  # Accept any HTTP response as "reachable" (including 404 before sync)
  if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
    um_result PASS "Mirror URL reachable" "$url (HTTP $code)"
  else
    um_result FAIL "Mirror URL reachable" "$url unreachable (HTTP $code)"
  fi
}

check_ubuntu_versions() {
  local ver missing=0 present=0
  for ver in ${UBUNTU_VERSIONS}; do
    if [[ -d "${DIST_ROOT}/${ver}" ]]; then
      ((present++)) || true
      um_result PASS "Ubuntu version ${ver}" "dists present"
    else
      ((missing++)) || true
      um_result WARNING "Ubuntu version ${ver}" "not yet synced"
    fi
  done
  if [[ "$present" -eq 0 ]]; then
    um_result WARNING "Ubuntu versions" "none synced yet (initial sync pending)"
  fi
}

check_http_status() {
  local ver code url
  local any_ok=0
  for ver in ${UBUNTU_VERSIONS}; do
    url="${MIRROR_URL}/ubuntu/dists/${ver}/Release"
    code="$(curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC}" -w '%{http_code}' "$url" 2>/dev/null || true)"
    [[ -z "$code" ]] && code="000"
    if [[ "$code" == "200" ]]; then
      ((any_ok++)) || true
      um_result PASS "HTTP Status ${ver}" "200 OK"
    else
      um_result WARNING "HTTP Status ${ver}" "HTTP $code"
    fi
  done
  if [[ "$any_ok" -eq 0 ]]; then
    um_result WARNING "HTTP Status" "no Release files reachable yet"
  fi
}

check_permissions() {
  if [[ ! -d "$BASE_PATH" ]]; then
    um_result WARNING "Permissions" "BASE_PATH missing — skip"
    return
  fi
  local issues=0
  if [[ ! -r "$BASE_PATH" ]] || [[ ! -x "$BASE_PATH" ]]; then
    um_result FAIL "Permissions" "$BASE_PATH not readable/executable"
    issues=1
  fi
  if [[ -f /etc/apt/mirror.list ]] && [[ ! -r /etc/apt/mirror.list ]]; then
    um_result FAIL "Permissions" "/etc/apt/mirror.list not readable"
    issues=1
  fi
  if [[ "$issues" -eq 0 ]]; then
    um_result PASS "Permissions" "base paths readable"
  fi
}

check_logs() {
  local ok=0
  for f in "$APT_MIRROR_LOG" "$APT_MIRROR_INITIAL_LOG" "$LOG_DIR"; do
    if [[ -e "$f" ]]; then
      ((ok++)) || true
    fi
  done
  if [[ -d "$LOG_DIR" ]]; then
    um_result PASS "Logs" "log dir $LOG_DIR present"
  else
    um_result WARNING "Logs" "$LOG_DIR missing"
  fi
  if [[ -f "$APT_MIRROR_LOG" ]] || [[ -f "$APT_MIRROR_INITIAL_LOG" ]]; then
    um_result PASS "Logs sync" "apt-mirror log present"
  else
    um_result WARNING "Logs sync" "no apt-mirror log yet (sync not started)"
  fi
}

check_health() {
  local status_bin=""
  if [[ -x "${INSTALL_BIN_DIR}/mirror-status.sh" ]]; then
    status_bin="${INSTALL_BIN_DIR}/mirror-status.sh"
  elif [[ -x "${UM_PROJECT_ROOT}/scripts/mirror-status.sh" ]]; then
    status_bin="${UM_PROJECT_ROOT}/scripts/mirror-status.sh"
  fi
  if [[ -z "$status_bin" ]]; then
    um_result WARNING "Health" "mirror-status.sh not installed"
    return
  fi
  if "$status_bin" --quiet >/dev/null 2>&1; then
    um_result PASS "Health" "mirror-status.sh exit 0"
  else
    local rc=$?
    if [[ "$rc" -eq 1 ]]; then
      um_result WARNING "Health" "mirror-status reported warnings"
    else
      um_result FAIL "Health" "mirror-status exit $rc"
    fi
  fi
}

main() {
  parse_args "$@"
  um_setup_trap
  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/validate.log"
  um_ensure_log_dir
  um_result_reset

  if [[ "$UM_QUIET" != "1" ]]; then
    printf '%s╔════════════════════════════════════════════════╗%s\n' "$UM_C_BOLD" "$UM_C_RESET"
    printf '%s║     Ubuntu Mirror Server - Validation          ║%s\n' "$UM_C_BOLD" "$UM_C_RESET"
    printf '%s╚════════════════════════════════════════════════╝%s\n\n' "$UM_C_BOLD" "$UM_C_RESET"
  fi

  um_info "Writing results to ${um_log_file}"

  check_ubuntu_version
  check_disk_mounted
  check_disk_space
  check_mirror_directory
  check_apt_mirror_installed
  check_nginx_installed
  check_nginx_config
  check_systemd_service
  check_systemd_timer
  check_mirror_url_reachable
  check_ubuntu_versions
  check_http_status
  check_permissions
  check_logs
  check_health

  um_result_summary
  local rc=$?
  um_info "validate exit=$rc"
  exit "$rc"
}

main "$@"
