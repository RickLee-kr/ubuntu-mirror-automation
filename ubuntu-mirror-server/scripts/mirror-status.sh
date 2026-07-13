#!/usr/bin/env bash
# mirror-status.sh — Enhanced health check for Ubuntu Mirror Server
# Improves on Setup Guide script with CPU/memory/inode/latency/errors.
set -euo pipefail

resolve_libs() {
  if [[ -f /usr/local/lib/ubuntu-mirror/common.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/common.sh
    # shellcheck source=/dev/null
    source /usr/local/lib/ubuntu-mirror/config.sh
  else
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=lib/common.sh
    source "${root}/lib/common.sh"
    # shellcheck source=lib/config.sh
    source "${root}/lib/config.sh"
  fi
}

resolve_libs

UM_QUIET=0
UM_CONFIG_ARG=""
UM_JSON=0

usage() {
  cat <<'EOF'
Usage: mirror-status.sh [--config PATH] [--quiet] [--json]
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) UM_CONFIG_ARG="${2:-}"; shift 2 ;;
      --quiet) UM_QUIET=1; shift ;;
      --json) UM_JSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) um_die "Unknown option: $1" ;;
    esac
  done
}

section() {
  [[ "$UM_QUIET" == "1" ]] && return 0
  printf '\n%s%s%s\n' "$UM_C_BOLD" "$1" "$UM_C_RESET"
}

line() {
  [[ "$UM_QUIET" == "1" ]] && return 0
  printf '  %s\n' "$*"
}

STATE_WARN=0
STATE_FAIL=0
mark_warn() { STATE_WARN=1; }
mark_fail() { STATE_FAIL=1; }

cpu_usage() {
  # 1-second sample via /proc/stat
  local a b idle_a idle_b total_a total_b
  read -r _ a < <(grep '^cpu ' /proc/stat)
  # shellcheck disable=SC2086
  set -- $a
  idle_a=$4
  total_a=0
  local v
  for v in "$@"; do total_a=$((total_a + v)); done
  sleep 0.5
  read -r _ b < <(grep '^cpu ' /proc/stat)
  # shellcheck disable=SC2086
  set -- $b
  idle_b=$4
  total_b=0
  for v in "$@"; do total_b=$((total_b + v)); done
  local idle total usage
  idle=$((idle_b - idle_a))
  total=$((total_b - total_a))
  if [[ "$total" -le 0 ]]; then
    printf '0\n'
    return
  fi
  usage=$((100 * (total - idle) / total))
  printf '%s\n' "$usage"
}

mem_info() {
  awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%d %d\n", t/1024, a/1024}' /proc/meminfo
}

inode_usage() {
  local path="$1"
  df -Pi "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

http_latency_ms() {
  local url="$1"
  curl -sS -o /dev/null --max-time "${HTTP_TIMEOUT_SEC}" \
    -w '%{time_total}' "$url" 2>/dev/null \
    | awk '{printf "%d\n", $1*1000}' || echo 0
}

count_debs() {
  find "$MIRROR_PATH" -name '*.deb' 2>/dev/null | wc -l | tr -d ' '
}

last_success_time() {
  if [[ -f "$APT_MIRROR_LOG" ]] && grep -q 'End time:' "$APT_MIRROR_LOG" 2>/dev/null; then
    grep 'End time:' "$APT_MIRROR_LOG" | tail -1
    return
  fi
  if [[ -f "$APT_MIRROR_INITIAL_LOG" ]] && grep -q 'End time:' "$APT_MIRROR_INITIAL_LOG" 2>/dev/null; then
    grep 'End time:' "$APT_MIRROR_INITIAL_LOG" | tail -1
    return
  fi
  printf 'unknown\n'
}

sync_duration_hint() {
  local logf=""
  if [[ -f "$APT_MIRROR_LOG" ]]; then
    logf="$APT_MIRROR_LOG"
  elif [[ -f "$APT_MIRROR_INITIAL_LOG" ]]; then
    logf="$APT_MIRROR_INITIAL_LOG"
  else
    printf 'n/a\n'
    return
  fi
  local begin end
  begin="$(grep 'Begin time:' "$logf" 2>/dev/null | tail -1 || true)"
  end="$(grep 'End time:' "$logf" 2>/dev/null | tail -1 || true)"
  if [[ -n "$begin" && -n "$end" ]]; then
    printf '%s | %s\n' "$begin" "$end"
  elif [[ -n "$begin" ]]; then
    printf '%s (in progress or incomplete)\n' "$begin"
  else
    printf 'n/a\n'
  fi
}

failed_packages() {
  local logf=""
  for logf in "$APT_MIRROR_LOG" "$APT_MIRROR_INITIAL_LOG"; do
    [[ -f "$logf" ]] || continue
    grep -ciE 'failed|error|404|unable to' "$logf" 2>/dev/null || true
    return
  done
  printf '0\n'
}

log_errors() {
  local n=0
  if [[ -f "$NGINX_ERROR_LOG" ]]; then
    n="$(tail -n 200 "$NGINX_ERROR_LOG" 2>/dev/null | grep -ciE 'error|crit|alert|emerg' || true)"
  fi
  printf '%s\n' "${n:-0}"
}

main() {
  parse_args "$@"
  um_load_config "$UM_CONFIG_ARG"
  um_set_log_file "${LOG_DIR}/health.log"
  um_ensure_log_dir

  if [[ "$UM_QUIET" != "1" ]]; then
    printf '%s╔════════════════════════════════════════════════╗%s\n' "$UM_C_BOLD" "$UM_C_RESET"
    printf '%s║    Ubuntu Mirror Server - Health Check         ║%s\n' "$UM_C_BOLD" "$UM_C_RESET"
    printf '%s╚════════════════════════════════════════════════╝%s\n' "$UM_C_BOLD" "$UM_C_RESET"
  fi

  local cpu mem_total mem_avail disk_pct inode_pct mirror_size packages
  local nginx_state timer_state sync_running latency failed errcount
  local last_ok duration

  cpu="$(cpu_usage)"
  read -r mem_total mem_avail <<<"$(mem_info)"
  disk_pct="$(um_disk_usage_percent "$BASE_PATH" 2>/dev/null || echo 0)"
  inode_pct="$(inode_usage "$BASE_PATH" || echo 0)"
  mirror_size="$(du -sh "$MIRROR_PATH" 2>/dev/null | awk '{print $1}')"
  packages="$(count_debs)"
  latency="$(http_latency_ms "${MIRROR_URL}/ubuntu/" )"
  failed="$(failed_packages)"
  errcount="$(log_errors)"
  last_ok="$(last_success_time)"
  duration="$(sync_duration_hint)"

  if systemctl is-active --quiet nginx 2>/dev/null; then
    nginx_state="running"
  else
    nginx_state="down"
    mark_fail
  fi

  if systemctl is-active --quiet apt-mirror.timer 2>/dev/null; then
    timer_state="active"
  elif systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
    timer_state="enabled-inactive"
    mark_warn
  else
    timer_state="disabled"
    mark_warn
  fi

  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    sync_running="yes"
  else
    sync_running="no"
  fi

  if [[ "$disk_pct" -ge "${DISK_CRIT_PERCENT}" ]]; then mark_fail; elif [[ "$disk_pct" -ge "${DISK_WARN_PERCENT}" ]]; then mark_warn; fi
  if [[ "${inode_pct:-0}" -ge 90 ]]; then mark_fail; elif [[ "${inode_pct:-0}" -ge 80 ]]; then mark_warn; fi
  if [[ "${latency:-0}" -gt "${HEALTH_HTTP_LATENCY_WARN_MS}" ]]; then mark_warn; fi
  if [[ "${errcount:-0}" -gt "${HEALTH_LOG_ERROR_WARN}" ]]; then mark_warn; fi

  section "System"
  line "CPU usage:          ${cpu}%"
  line "Memory:             ${mem_avail} MiB avail / ${mem_total} MiB total"
  line "Disk used:          ${disk_pct}% on ${BASE_PATH}"
  line "Inode used:         ${inode_pct}%"

  section "Mirror"
  line "Mirror size:        ${mirror_size:-unknown}"
  line "Downloaded .deb:    ${packages}"
  line "Sync running:       ${sync_running}"
  line "Last success:       ${last_ok}"
  line "Sync duration:      ${duration}"
  line "Failed/error hits:  ${failed}"

  section "Services"
  line "nginx:              ${nginx_state}"
  line "apt-mirror.timer:   ${timer_state}"
  line "HTTP latency:       ${latency} ms (${MIRROR_URL}/ubuntu/)"
  line "nginx log errors:   ${errcount} (last 200 lines)"

  section "Ubuntu Versions"
  local ver
  for ver in ${UBUNTU_VERSIONS}; do
    if [[ -d "${DIST_ROOT}/${ver}" ]]; then
      local sz
      sz="$(du -sh "${DIST_ROOT}/${ver}" 2>/dev/null | awk '{print $1}')"
      line "OK   ${ver} (${sz})"
    else
      line "WAIT ${ver} (not yet synced)"
      mark_warn
    fi
  done

  section "HTTP"
  if curl -sS -f --max-time "${HTTP_TIMEOUT_SEC}" \
      "${MIRROR_URL}/ubuntu/dists/noble/Release" >/dev/null 2>&1; then
    line "Local HTTP access working (noble/Release)"
  else
    line "Local HTTP not ready (sync may be incomplete)"
    mark_warn
  fi

  if [[ "$UM_JSON" == "1" ]]; then
    printf '{"cpu":%s,"mem_avail_mib":%s,"disk_pct":%s,"inode_pct":%s,"packages":%s,"latency_ms":%s,"nginx":"%s","sync_running":"%s","warn":%s,"fail":%s}\n' \
      "$cpu" "$mem_avail" "$disk_pct" "${inode_pct:-0}" "$packages" "${latency:-0}" \
      "$nginx_state" "$sync_running" "$STATE_WARN" "$STATE_FAIL"
  fi

  um_info "health warn=$STATE_WARN fail=$STATE_FAIL" >/dev/null 2>&1 || true
  printf '%s\n' "$(um_ts) [HEALTH] cpu=${cpu}% disk=${disk_pct}% nginx=${nginx_state} sync=${sync_running}" \
    >>"${LOG_DIR}/health.log" 2>/dev/null || true

  if [[ "$STATE_FAIL" -eq 1 ]]; then
    exit 2
  fi
  if [[ "$STATE_WARN" -eq 1 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
