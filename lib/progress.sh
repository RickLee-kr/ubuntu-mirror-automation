#!/usr/bin/env bash
# shellcheck shell=bash
# Progress sampling, log parsing, and sync health helpers for the mirror dashboard.

# shellcheck disable=SC2317
if [[ -n "${UM_PROGRESS_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_PROGRESS_LOADED=1

# Stall threshold (seconds). Override via STALL_THRESHOLD_SEC in mirror.conf.
UM_STALL_THRESHOLD_SEC="${STALL_THRESHOLD_SEC:-600}"
UM_WAITING_THRESHOLD_SEC="${WAITING_THRESHOLD_SEC:-30}"
UM_PROGRESS_JSONL="${UM_PROGRESS_JSONL:-}"

um_progress_jsonl_path() {
  if [[ -n "${UM_PROGRESS_JSONL}" ]]; then
    printf '%s\n' "$UM_PROGRESS_JSONL"
    return
  fi
  printf '%s/progress.jsonl\n' "${LOG_DIR:-/var/log/ubuntu-mirror}"
}

um_finalize_log_path() {
  printf '%s/finalize.log\n' "${LOG_DIR:-/var/log/ubuntu-mirror}"
}

um_progress_ensure_dirs() {
  mkdir -p "${LOG_DIR:-/var/log/ubuntu-mirror}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Structured progress events
# ---------------------------------------------------------------------------
um_progress_event() {
  # um_progress_event <event> [key=value ...]
  local event="$1"
  shift || true
  local ts pair key val json
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  json="{\"timestamp\":\"${ts}\",\"event\":\"${event}\""
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    json+=",\"${key}\":\"${val}\""
  done
  json+="}"
  um_progress_ensure_dirs
  printf '%s\n' "$json" >>"$(um_progress_jsonl_path)" 2>/dev/null || true
}

um_progress_event_num() {
  # um_progress_event_num <event> <key> <number> [key=value ...]
  local event="$1" key="$2" num="$3"
  shift 3 || true
  local ts pair k val json
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  json="{\"timestamp\":\"${ts}\",\"event\":\"${event}\",\"${key}\":${num}"
  for pair in "$@"; do
    k="${pair%%=*}"
    val="${pair#*=}"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    json+=",\"${k}\":\"${val}\""
  done
  json+="}"
  um_progress_ensure_dirs
  printf '%s\n' "$json" >>"$(um_progress_jsonl_path)" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Timestamped log line helper (for run-apt-mirror)
# ---------------------------------------------------------------------------
um_timestamp_line() {
  # Prefix stdin lines with ISO-ish local timestamps; also emit progress events.
  local line ts suite component path stage
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s %s\n' "$ts" "$line"

    # Best-effort structured events from apt-mirror / wget-ish output
    if [[ "$line" =~ dists/([a-z0-9.-]+)/([a-z]+)/ ]]; then
      suite="${BASH_REMATCH[1]}"
      component="${BASH_REMATCH[2]}"
      um_progress_event suite_activity "suite=${suite}" "component=${component}"
    fi
    if [[ "$line" =~ (pool/[^[:space:]]+\.deb) ]]; then
      path="${BASH_REMATCH[1]}"
      um_progress_event file_download "path=${path}"
    elif [[ "$line" =~ (/[^[:space:]]+\.deb) ]]; then
      path="${BASH_REMATCH[1]}"
      path="${path#*/mirror/}"
      um_progress_event file_download "path=${path}"
    fi
    stage="$(um_infer_stage_from_line "$line")"
    if [[ -n "$stage" ]]; then
      um_progress_event stage "stage=${stage}"
    fi
  done
}

um_infer_stage_from_line() {
  local line="$1"
  case "$line" in
    *[Dd]ownloading*index*|*Packages.gz*|*Packages.xz*|*InRelease*|*Release.gpg*)
      printf 'Downloading indexes\n'
      ;;
    *[Pp]rocessing*|*Parsing*|*Reading\ package*)
      printf 'Processing metadata\n'
      ;;
    *\.deb*|*[Dd]ownloading*pool*|*pool/main*|*pool/universe*)
      printf 'Downloading packages\n'
      ;;
    *[Pp]ostmirror*|*postmirror.sh*)
      printf 'Running postmirror\n'
      ;;
    *[Cc]lean*|*clean.sh*)
      printf 'Cleanup\n'
      ;;
    *[Vv]alidat*)
      printf 'Validation\n'
      ;;
    *[Ff]inaliz*)
      printf 'Finalization\n'
      ;;
    *completed\ successfully*|*End\ time:*)
      printf 'Completed\n'
      ;;
    *)
      printf ''
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Log / filesystem metrics
# ---------------------------------------------------------------------------
um_log_mtime_epoch() {
  local f="${1:-${APT_MIRROR_LOG:-/var/log/apt-mirror.log}}"
  if [[ -f "$f" ]]; then
    stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

um_log_size_bytes() {
  local f="${1:-${APT_MIRROR_LOG:-/var/log/apt-mirror.log}}"
  if [[ -f "$f" ]]; then
    stat -c '%s' "$f" 2>/dev/null || stat -f '%z' "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

um_seconds_since_log_activity() {
  local mtime now
  mtime="$(um_log_mtime_epoch "${1:-}")"
  now="$(date +%s)"
  if [[ "${mtime:-0}" -eq 0 ]]; then
    printf '%s\n' "999999"
    return
  fi
  printf '%s\n' "$((now - mtime))"
}

um_format_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    if (b < 1024) printf "%d B", b
    else if (b < 1048576) printf "%.1f KiB", b/1024
    else if (b < 1073741824) printf "%.1f MiB", b/1048576
    else if (b < 1099511627776) printf "%.1f GiB", b/1073741824
    else printf "%.2f TiB", b/1099511627776
  }'
}

um_format_duration() {
  local sec="${1:-0}"
  local h m s
  h=$((sec / 3600))
  m=$(((sec % 3600) / 60))
  s=$((sec % 60))
  printf '%02d:%02d:%02d\n' "$h" "$m" "$s"
}

um_format_rate() {
  local bps="${1:-0}"
  if [[ "$bps" -lt 0 ]]; then bps=0; fi
  printf '%s/s\n' "$(um_format_bytes "$bps")"
}

um_df_used_kib() {
  local path="${1:-${BASE_PATH:-/}}" out
  out="$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $3+0}')" || true
  printf '%s\n' "${out:-0}"
}

um_inode_usage_percent() {
  local path="${1:-${BASE_PATH:-/}}" out
  out="$(df -Pi "$path" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}')" || true
  printf '%s\n' "${out:-0}"
}

um_net_rx_bytes() {
  # Sum receive bytes across non-lo interfaces
  awk '
    NR>2 {
      iface=$1; gsub(/:/,"",iface);
      if (iface != "lo") rx+=$2
    }
    END { print rx+0 }
  ' /proc/net/dev 2>/dev/null || echo 0
}

um_disk_write_sectors() {
  # Sum write sectors from /proc/diskstats (field 10)
  awk '{ w+=$10 } END { print w+0 }' /proc/diskstats 2>/dev/null || echo 0
}

um_mirror_size_bytes_cached() {
  local f bytes=0 ready_size
  # Selective READY total_size is authoritative (avoid legacy progress.jsonl / full-mirror du).
  if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
    ready_size="$(um_ready_field total_size 2>/dev/null || true)"
    if [[ "${ready_size:-}" =~ ^[0-9]+$ ]] && [[ "$ready_size" -gt 0 ]]; then
      printf '%s\n' "$ready_size"
      return
    fi
    um_sample_mirror_size_bytes
    return
  fi
  # Prefer last progress.jsonl mirror_size event; fall back to live sample.
  f="$(um_progress_jsonl_path)"
  if [[ -f "$f" ]] && [[ -s "$f" ]]; then
    bytes="$(awk -F'"bytes":' '
      /"event":"mirror_size"/ {
        split($2, a, /[,}]/);
        last=a[1]+0
      }
      END { print last+0 }
    ' "$f" 2>/dev/null || echo 0)"
  fi
  if [[ "${bytes:-0}" -gt 0 ]]; then
    printf '%s\n' "$bytes"
    return
  fi
  um_sample_mirror_size_bytes
}

um_selective_published_root() {
  local sel cur
  sel="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  cur="${sel}/current"
  if [[ -L "$cur" ]] || [[ -d "$cur" ]]; then
    readlink -f "$cur" 2>/dev/null || printf '%s\n' "${sel}/published"
    return
  fi
  printf '%s\n' "${sel}/published"
}

um_sample_mirror_size_bytes() {
  local root base
  if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
    root="${1:-$(um_selective_published_root)}"
  else
    root="${1:-${MIRROR_PATH:-${BASE_PATH:-/var/spool/apt-mirror}/mirror}}"
  fi
  base="${BASE_PATH:-/var/spool/apt-mirror}"
  if [[ -d "$root" ]]; then
    # Selective: always du the published/current tree (never whole BASE_PATH mount).
    if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
      du -sb "$root" 2>/dev/null | awk '{print $1}'
      return
    fi
    # Prefer df used-bytes when BASE_PATH is a dedicated mount (avoids multi-minute du).
    if findmnt -n "$base" >/dev/null 2>&1; then
      df -PB1 "$base" 2>/dev/null | awk 'NR==2 {print $3+0; exit}'
      return
    fi
    du -sb "$root" 2>/dev/null | awk '{print $1}'
  else
    echo 0
  fi
}

um_package_count_cached() {
  local f count=0 ready_count
  # Prefer READY package_count — avoids multi-minute find on large mirrors.
  ready_count="$(um_ready_field package_count 2>/dev/null || true)"
  if [[ "${ready_count:-}" =~ ^[0-9]+$ ]] && [[ "${ready_count}" -gt 0 ]]; then
    printf '%s\n' "$ready_count"
    return
  fi
  if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
    um_sample_package_count
    return
  fi
  f="$(um_progress_jsonl_path)"
  if [[ -f "$f" ]] && [[ -s "$f" ]]; then
    count="$(awk -F'"count":' '
      /"event":"package_count"/ {
        split($2, a, /[,}]/);
        last=a[1]+0
      }
      END { print last+0 }
    ' "$f" 2>/dev/null || echo 0)"
  fi
  if [[ "${count:-0}" -gt 0 ]]; then
    printf '%s\n' "$count"
    return
  fi
  um_sample_package_count
}

um_sample_package_count() {
  local root
  if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
    root="${1:-$(um_selective_published_root)}"
    if [[ -d "$root" ]]; then
      find "$root" -type f -name '*.deb' 2>/dev/null | wc -l
      return
    fi
    echo 0
    return
  fi
  root="${1:-${UBUNTU_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/mirror/archive.ubuntu.com/ubuntu}}"
  if [[ -d "$root/pool" ]]; then
    find "$root/pool" -type f -name '*.deb' 2>/dev/null | wc -l
  else
    echo 0
  fi
}

um_suites_with_release() {
  local dist="${1:-${DIST_ROOT:-}}"
  local count=0
  if [[ -z "$dist" ]] || [[ ! -d "$dist" ]]; then
    echo 0
    return
  fi
  local d
  for d in "$dist"/*/Release; do
    [[ -f "$d" ]] || continue
    count=$((count + 1))
  done
  echo "$count"
}

um_expected_suite_count() {
  local vers suffixes n=0 _ver s
  vers="${UBUNTU_VERSIONS:-xenial bionic focal jammy noble}"
  suffixes="${SUITE_SUFFIXES:-updates security}"
  for _ver in $vers; do
    n=$((n + 1))
    for s in $suffixes; do
      [[ -n "$s" ]] || continue
      n=$((n + 1))
    done
  done
  echo "$n"
}

um_sync_start_epoch() {
  local marker
  marker="$(um_state_marker sync-started 2>/dev/null || true)"
  if [[ -n "$marker" ]] && [[ -f "$marker" ]]; then
    stat -c '%Y' "$marker" 2>/dev/null || stat -f '%m' "$marker" 2>/dev/null || date +%s
  else
    # Fall back to service ActiveEnterTimestamp
    local ts
    ts="$(systemctl show -p ActiveEnterTimestamp --value apt-mirror.service 2>/dev/null || true)"
    if [[ -n "$ts" ]] && [[ "$ts" != "n/a" ]]; then
      date -d "$ts" +%s 2>/dev/null || date +%s
    else
      date +%s
    fi
  fi
}

um_sync_elapsed_sec() {
  local start now
  start="$(um_sync_start_epoch)"
  now="$(date +%s)"
  echo $((now - start))
}

# ---------------------------------------------------------------------------
# Parse current processing target from apt-mirror log
# ---------------------------------------------------------------------------
um_parse_log_context() {
  # Sets globals: UM_CUR_HOST UM_CUR_VERSION UM_CUR_SUITE UM_CUR_COMPONENT
  #               UM_CUR_ARCH UM_CUR_FILE UM_CUR_STAGE
  local logf="${1:-${APT_MIRROR_LOG:-/var/log/apt-mirror.log}}"
  UM_CUR_HOST=""
  UM_CUR_VERSION=""
  UM_CUR_SUITE=""
  UM_CUR_COMPONENT=""
  UM_CUR_ARCH=""
  UM_CUR_FILE=""
  UM_CUR_STAGE=""

  if [[ ! -f "$logf" ]]; then
    UM_CUR_STAGE="waiting for apt-mirror output"
    return
  fi

  local line
  # Scan last ~200 lines for the most recent useful context
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ https?://([a-zA-Z0-9.-]+) ]]; then
      UM_CUR_HOST="${BASH_REMATCH[1]}"
    fi

    if [[ "$line" =~ dists/([a-z0-9.-]+)/([a-z]+)/(binary-([a-z0-9]+)|source|i18n) ]]; then
      UM_CUR_SUITE="${BASH_REMATCH[1]}"
      UM_CUR_COMPONENT="${BASH_REMATCH[2]}"
      if [[ -n "${BASH_REMATCH[4]:-}" ]]; then
        UM_CUR_ARCH="${BASH_REMATCH[4]}"
      fi
      UM_CUR_VERSION="${UM_CUR_SUITE%%-*}"
    elif [[ "$line" =~ dists/([a-z0-9.-]+)/([a-z]+)/ ]]; then
      UM_CUR_SUITE="${BASH_REMATCH[1]}"
      UM_CUR_COMPONENT="${BASH_REMATCH[2]}"
      UM_CUR_VERSION="${UM_CUR_SUITE%%-*}"
    fi

    if [[ "$line" =~ (pool/[^[:space:]]+\.deb) ]]; then
      UM_CUR_FILE="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ([^[:space:]]+\.deb) ]]; then
      UM_CUR_FILE="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ (Packages(\.gz|\.xz)?|InRelease|Release\.gpg|Contents-[^[:space:]]+) ]]; then
      UM_CUR_FILE="${BASH_REMATCH[1]}"
    fi

    local st
    st="$(um_infer_stage_from_line "$line")"
    if [[ -n "$st" ]]; then
      UM_CUR_STAGE="$st"
    fi
  done < <(tail -n 200 "$logf" 2>/dev/null || true)

  if [[ -z "$UM_CUR_STAGE" ]] && [[ -z "$UM_CUR_FILE" ]] && [[ -z "$UM_CUR_SUITE" ]]; then
    UM_CUR_STAGE="waiting for apt-mirror output"
  fi
}

um_recent_log_lines() {
  # Print last N meaningful (filtered) log lines
  local n="${1:-8}"
  local logf="${2:-${APT_MIRROR_LOG:-/var/log/apt-mirror.log}}"
  if [[ ! -f "$logf" ]]; then
    return 0
  fi
  # Filter empty / pure percentage spam / wget dots
  tail -n 80 "$logf" 2>/dev/null \
    | grep -vE '^[[:space:]]*$' \
    | grep -vE '^[[:space:]]*\.+[[:space:]]*$' \
    | grep -vE '^[[:space:]]*[0-9]+%[[:space:]]*$' \
    | tail -n "$n" || true
}

# ---------------------------------------------------------------------------
# Process / pause detection
# ---------------------------------------------------------------------------
um_apt_mirror_pids() {
  pgrep -f '/usr/bin/apt-mirror' 2>/dev/null || true
}

um_is_sync_paused() {
  local pid state
  for pid in $(um_apt_mirror_pids); do
    state="$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null || true)"
    # T = stopped (job control)
    if [[ "$state" == "T" ]]; then
      return 0
    fi
  done
  return 1
}

um_service_active_state() {
  systemctl show -p ActiveState --value apt-mirror.service 2>/dev/null || echo "unknown"
}

um_service_result() {
  systemctl show -p Result --value apt-mirror.service 2>/dev/null || echo "unknown"
}

um_service_sub_state() {
  systemctl show -p SubState --value apt-mirror.service 2>/dev/null || echo "unknown"
}

# ---------------------------------------------------------------------------
# Health / lifecycle with reason
# ---------------------------------------------------------------------------
# Activity snapshot for stall detection (caller provides previous sample vars)
# Returns via globals: UM_HEALTH_STATE UM_HEALTH_REASON UM_LIFECYCLE_STATE

um_detect_sync_health() {
  # Optional args (for tests): log_age_sec mirror_size_delta net_delta disk_delta
  local log_age="${1:-}"
  local size_delta="${2:-0}"
  local net_delta="${3:-0}"
  local disk_delta="${4:-0}"

  local active_state result process_alive=0 paused=0
  active_state="$(um_service_active_state)"
  result="$(um_service_result)"

  if um_is_sync_paused; then
    paused=1
  fi
  if um_is_sync_running || [[ "$active_state" == "activating" ]] || [[ "$active_state" == "active" ]]; then
    process_alive=1
  fi
  # Keep in sync with um_is_sync_running() — do not use loose '/usr/bin/apt-mirror' match.
  if pgrep -f '/usr/bin/perl /usr/bin/apt-mirror' >/dev/null 2>&1 \
    || pgrep -f 'ubuntu-offline-mirror\.sh[[:space:]]+sync' >/dev/null 2>&1 \
    || pgrep -f 'run-apt-mirror\.sh' >/dev/null 2>&1; then
    process_alive=1
  fi

  if [[ -z "$log_age" ]]; then
    log_age="$(um_seconds_since_log_activity)"
  fi

  local stall_thr="${UM_STALL_THRESHOLD_SEC:-600}"
  local wait_thr="${UM_WAITING_THRESHOLD_SEC:-30}"
  local has_activity=0

  if [[ "$log_age" -lt "$wait_thr" ]]; then has_activity=1; fi
  if [[ "${size_delta:-0}" -gt 0 ]]; then has_activity=1; fi
  if [[ "${net_delta:-0}" -gt 1024 ]]; then has_activity=1; fi
  if [[ "${disk_delta:-0}" -gt 0 ]]; then has_activity=1; fi

  # Ready / complete take priority when not actively syncing.
  # Treat inactive/dead service as not syncing even if pgrep false-positives.
  if um_is_mirror_ready 2>/dev/null; then
    if [[ "$process_alive" -eq 0 ]] \
      || [[ "$active_state" != "active" && "$active_state" != "activating" ]]; then
      UM_LIFECYCLE_STATE="READY"
      if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
        UM_HEALTH_STATE="HEALTHY"
        UM_HEALTH_REASON="${UM_SELECTIVE_READY_REASON:-Selective mirror verified and published}"
      else
        UM_HEALTH_STATE="COMPLETE"
        UM_HEALTH_REASON="Mirror state READY"
      fi
      return
    fi
  fi
  # Selective profile with incomplete gates: surface precise reason (never legacy INSTALLED).
  if declare -F um_is_selective_profile >/dev/null 2>&1 && um_is_selective_profile 2>/dev/null; then
    if [[ "$process_alive" -eq 0 ]]; then
      um_evaluate_selective_ready 2>/dev/null || true
      if [[ -f "$(um_selective_ready_path 2>/dev/null || true)" ]]; then
        UM_LIFECYCLE_STATE="SYNC_COMPLETE"
        UM_HEALTH_STATE="WARNING"
        UM_HEALTH_REASON="${UM_SELECTIVE_READY_REASON:-selective READY gates incomplete}"
        return
      fi
    fi
  fi

  if um_has_marker "finalizing" 2>/dev/null || um_has_marker "finalizing-cleanup" 2>/dev/null; then
    UM_LIFECYCLE_STATE="FINALIZING"
    UM_HEALTH_STATE="HEALTHY"
    UM_HEALTH_REASON="Running post-sync finalization"
    return
  fi

  if [[ "$paused" -eq 1 ]]; then
    UM_LIFECYCLE_STATE="PAUSED"
    UM_HEALTH_STATE="WAITING"
    UM_HEALTH_REASON="Sync processes stopped (SIGSTOP)"
    return
  fi

  if [[ "$process_alive" -eq 1 ]]; then
    local elapsed=0
    if declare -F um_sync_elapsed_sec >/dev/null 2>&1; then
      elapsed="$(um_sync_elapsed_sec 2>/dev/null || echo 0)"
    fi

    if [[ "$active_state" == "activating" ]] && [[ "$log_age" -gt 99990 ]]; then
      UM_LIFECYCLE_STATE="STARTING"
      UM_HEALTH_STATE="WAITING"
      UM_HEALTH_REASON="apt-mirror.service activating"
      return
    fi

    # Fresh start: log not created yet — do not mark stalled
    if [[ "$log_age" -gt 99990 ]] && [[ "$elapsed" -lt "$stall_thr" ]]; then
      UM_LIFECYCLE_STATE="STARTING"
      UM_HEALTH_STATE="WAITING"
      UM_HEALTH_REASON="waiting for apt-mirror output"
      return
    fi

    if [[ "$has_activity" -eq 1 ]]; then
      UM_LIFECYCLE_STATE="SYNC_RUNNING"
      UM_HEALTH_STATE="HEALTHY"
      UM_HEALTH_REASON="log updated ${log_age} seconds ago"
      return
    fi

    # No meaningful activity — waiting vs stalled
    # Require ALL of: no log, no size, no net/disk for stall threshold
    local idle_for="$log_age"
    if [[ "$idle_for" -ge "$stall_thr" ]] \
      && [[ "${size_delta:-0}" -le 0 ]] \
      && [[ "${net_delta:-0}" -le 1024 ]] \
      && [[ "${disk_delta:-0}" -le 0 ]]; then
      UM_LIFECYCLE_STATE="SYNC_STALLED"
      UM_HEALTH_STATE="STALLED"
      local mins=$((idle_for / 60))
      UM_HEALTH_REASON="no log, disk, or network activity for ${mins} minutes"
      return
    fi

    UM_LIFECYCLE_STATE="SYNC_WAITING"
    UM_HEALTH_STATE="WAITING"
    UM_HEALTH_REASON="no log output for ${log_age} seconds, process still active"
    return
  fi

  # Not running
  if um_has_marker "sync-failed" 2>/dev/null || [[ "$result" == "exit-code" ]] || [[ "$result" == "signal" ]] || [[ "$active_state" == "failed" ]]; then
    UM_LIFECYCLE_STATE="SYNC_FAILED"
    UM_HEALTH_STATE="FAILED"
    UM_HEALTH_REASON="apt-mirror.service result=${result}"
    return
  fi

  if um_initial_sync_complete 2>/dev/null; then
    if systemctl is-enabled --quiet apt-mirror.timer 2>/dev/null; then
      UM_LIFECYCLE_STATE="READY"
      UM_HEALTH_STATE="COMPLETE"
      UM_HEALTH_REASON="Initial sync complete; timer enabled"
    else
      UM_LIFECYCLE_STATE="SYNC_COMPLETE"
      UM_HEALTH_STATE="COMPLETE"
      UM_HEALTH_REASON="Initial synchronization completed"
    fi
    return
  fi

  if um_is_installed 2>/dev/null; then
    UM_LIFECYCLE_STATE="INSTALLED"
    UM_HEALTH_STATE="WAITING"
    UM_HEALTH_REASON="Installed; sync not started"
    return
  fi

  UM_LIFECYCLE_STATE="NOT_INSTALLED"
  UM_HEALTH_STATE="WAITING"
  UM_HEALTH_REASON="Not installed"
}

um_last_error_from_log() {
  local logf="${1:-${APT_MIRROR_LOG:-/var/log/apt-mirror.log}}"
  if [[ ! -f "$logf" ]]; then
    echo ""
    return
  fi
  grep -iE 'error|fail|fatal|no space|permission denied|cannot|unable' "$logf" 2>/dev/null \
    | tail -n 1 || true
}

# ---------------------------------------------------------------------------
# Background sampler used by run-apt-mirror.sh
# ---------------------------------------------------------------------------
um_progress_sampler_loop() {
  local interval="${1:-30}"
  local root="${BASE_PATH:-/var/spool/apt-mirror}"
  local pkg_root="${UBUNTU_MIRROR_ROOT:-$root/mirror/archive.ubuntu.com/ubuntu}"
  local bytes count
  while true; do
    bytes="$(um_sample_mirror_size_bytes "$root" 2>/dev/null || echo 0)"
    um_progress_event_num mirror_size bytes "${bytes:-0}"
    count="$(um_sample_package_count "$pkg_root" 2>/dev/null || echo 0)"
    um_progress_event_num package_count count "${count:-0}"
    sleep "$interval"
  done
}
