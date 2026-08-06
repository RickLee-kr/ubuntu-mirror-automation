#!/usr/bin/env bash
# Reusable long-operation progress / heartbeat for Phase 2 staging.
# shellcheck shell=bash
# Default interval 30s; override with DP_PHASE2_HEARTBEAT_SECONDS (tests use 1).
# Preserves exact child exit status; no orphan heartbeats; SIGINT/SIGTERM safe.

DP_PHASE2_HEARTBEAT_SECONDS="${DP_PHASE2_HEARTBEAT_SECONDS:-30}"

dp2_progress_sanitize_target() {
  local t="${1-}"
  # Strip credentials and query parameters from URLs.
  t="$(printf '%s' "$t" | sed -E 's#://[^/@]+@#://#; s/\?.*$//')"
  # Bound length
  printf '%s' "${t:0:200}"
}

dp2_progress_now() {
  date -u +%s
}

# Run command with periodic OPERATION_PROGRESS heartbeats.
# Usage: dp2_run_with_heartbeat <name> <target> <command...>
# Or:    dp2_run_with_heartbeat <name> <target> -- <command...>
dp2_run_with_heartbeat() {
  local name="$1"
  local target="$2"
  shift 2
  if [[ "${1-}" == "--" ]]; then
    shift
  fi
  local sanitized child_pid hb_pid start now elapsed rc=0
  local stop_file
  sanitized="$(dp2_progress_sanitize_target "$target")"
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-hb-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  printf 'OPERATION_START name=%s target=%s\n' "$name" "$sanitized"

  "$@" &
  child_pid=$!

  (
    trap 'exit 0' TERM INT
    while true; do
      if [[ -f "$stop_file" ]]; then
        exit 0
      fi
      if ! kill -0 "$child_pid" 2>/dev/null; then
        exit 0
      fi
      sleep "${DP_PHASE2_HEARTBEAT_SECONDS}"
      if [[ -f "$stop_file" ]]; then
        exit 0
      fi
      if ! kill -0 "$child_pid" 2>/dev/null; then
        exit 0
      fi
      now="$(dp2_progress_now)"
      elapsed=$((now - start))
      printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s\n' "$name" "$elapsed"
    done
  ) &
  hb_pid=$!

  _dp2_hb_cleanup() {
    : >"$stop_file" 2>/dev/null || true
    kill "$hb_pid" 2>/dev/null || true
    wait "$hb_pid" 2>/dev/null || true
    rm -f "$stop_file"
  }

  if wait "$child_pid"; then
    rc=0
  else
    rc=$?
  fi
  _dp2_hb_cleanup
  now="$(dp2_progress_now)"
  elapsed=$((now - start))
  printf 'OPERATION_END name=%s rc=%s elapsed_seconds=%s\n' "$name" "$rc" "$elapsed"
  return "$rc"
}

# File-size aware download progress. Does not fabricate Content-Length.
# Usage: dp2_run_download_with_progress <name> <mode> <dest_path> <bytes_total_or_UNKNOWN> <curl-args...>
# mode=FULL|RESUME
dp2_run_download_with_progress() {
  local name="$1"
  local mode="$2"
  local dest="$3"
  local bytes_total="$4"
  shift 4
  local child_pid hb_pid start now elapsed rc=0
  local stop_file last_bytes=0 unchanged=0 bytes_now avg eta percent
  local sanitized="download"
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-dl-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  if [[ -f "$dest" ]]; then
    last_bytes="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  else
    last_bytes=0
  fi
  printf 'OPERATION_START name=%s target=%s mode=%s bytes_total=%s\n' \
    "$name" "$sanitized" "$mode" "${bytes_total:-UNKNOWN}"

  "$@" &
  child_pid=$!

  (
    trap 'exit 0' TERM INT
    while true; do
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      sleep "${DP_PHASE2_HEARTBEAT_SECONDS}"
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      now="$(dp2_progress_now)"
      elapsed=$((now - start))
      [[ "$elapsed" -lt 1 ]] && elapsed=1
      bytes_now=0
      if [[ -f "$dest" ]]; then
        bytes_now="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
      fi
      if [[ "$bytes_now" -eq "$last_bytes" ]]; then
        unchanged=$((unchanged + DP_PHASE2_HEARTBEAT_SECONDS))
      else
        unchanged=0
        last_bytes="$bytes_now"
      fi
      avg=$((bytes_now / elapsed))
      if [[ "$bytes_total" =~ ^[0-9]+$ && "$bytes_total" -gt 0 && "$avg" -gt 0 ]]; then
        percent=$((bytes_now * 100 / bytes_total))
        eta=$(( (bytes_total - bytes_now) / avg ))
      else
        percent="UNKNOWN"
        eta="UNKNOWN"
        bytes_total="${bytes_total:-UNKNOWN}"
      fi
      printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s bytes_downloaded=%s bytes_total=%s percent=%s average_bytes_per_second=%s eta_seconds=%s mode=%s unchanged_seconds=%s\n' \
        "$name" "$elapsed" "$bytes_now" "$bytes_total" "$percent" "$avg" "$eta" "$mode" "$unchanged"
      if [[ "$unchanged" -ge $((DP_PHASE2_HEARTBEAT_SECONDS * 3)) ]]; then
        printf 'DOWNLOAD_NO_PROGRESS_WARNING=YES\n'
      fi
    done
  ) &
  hb_pid=$!

  if wait "$child_pid"; then
    rc=0
  else
    rc=$?
  fi
  : >"$stop_file" 2>/dev/null || true
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true
  rm -f "$stop_file"

  now="$(dp2_progress_now)"
  elapsed=$((now - start))
  [[ "$elapsed" -lt 1 ]] && elapsed=1
  bytes_now=0
  if [[ -f "$dest" ]]; then
    bytes_now="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  fi
  avg=$((bytes_now / elapsed))
  printf 'OPERATION_END name=%s rc=%s elapsed_seconds=%s\n' "$name" "$rc" "$elapsed"
  if [[ "$rc" -eq 0 ]]; then
    printf 'DOWNLOAD_RESULT=PASS\n'
  else
    printf 'DOWNLOAD_RESULT=FAIL\n'
  fi
  printf 'DOWNLOAD_MODE=%s\n' "$mode"
  printf 'DOWNLOAD_BYTES=%s\n' "$bytes_now"
  printf 'DOWNLOAD_ELAPSED_SECONDS=%s\n' "$elapsed"
  printf 'DOWNLOAD_AVERAGE_BYTES_PER_SECOND=%s\n' "$avg"
  return "$rc"
}

# Extraction progress: report extracted bytes + file count under a directory.
# Usage: dp2_run_extract_with_progress <name> <dest_dir> <command...>
# Or:    dp2_run_extract_with_progress <name> <dest_dir> -- <command...>
dp2_run_extract_with_progress() {
  local name="$1"
  local dest_dir="$2"
  shift 2
  # Keep the same optional command separator contract as
  # dp2_run_with_heartbeat(). Without this, the literal `--` becomes argv[0]
  # and Bash exits immediately with `--: command not found` before extraction.
  if [[ "${1-}" == "--" ]]; then
    shift
  fi
  if [[ "$#" -eq 0 ]]; then
    printf 'OPERATION_START name=%s target=%s\n' "$name" "$(dp2_progress_sanitize_target "$dest_dir")"
    printf 'OPERATION_END name=%s rc=2 elapsed_seconds=0\n' "$name"
    return 2
  fi
  local child_pid hb_pid start now elapsed rc=0 stop_file
  local extracted_bytes extracted_files
  stop_file="$(mktemp "${TMPDIR:-/tmp}/dp2-ex-stop.XXXXXX")"
  rm -f "$stop_file"
  start="$(dp2_progress_now)"
  printf 'OPERATION_START name=%s target=%s\n' "$name" "$(dp2_progress_sanitize_target "$dest_dir")"

  "$@" &
  child_pid=$!
  (
    trap 'exit 0' TERM INT
    while true; do
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      sleep "${DP_PHASE2_HEARTBEAT_SECONDS}"
      if [[ -f "$stop_file" ]]; then exit 0; fi
      if ! kill -0 "$child_pid" 2>/dev/null; then exit 0; fi
      now="$(dp2_progress_now)"
      elapsed=$((now - start))
      extracted_bytes=0
      extracted_files=0
      if [[ -d "$dest_dir" ]]; then
        extracted_bytes="$(du -sb "$dest_dir" 2>/dev/null | awk '{print $1}')"
        extracted_files="$(find "$dest_dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
      fi
      printf 'OPERATION_PROGRESS name=%s elapsed_seconds=%s extracted_bytes=%s extracted_file_count=%s\n' \
        "$name" "$elapsed" "${extracted_bytes:-0}" "${extracted_files:-0}"
    done
  ) &
  hb_pid=$!

  if wait "$child_pid"; then
    rc=0
  else
    rc=$?
  fi
  : >"$stop_file" 2>/dev/null || true
  kill "$hb_pid" 2>/dev/null || true
  wait "$hb_pid" 2>/dev/null || true
  rm -f "$stop_file"
  now="$(dp2_progress_now)"
  elapsed=$((now - start))
  printf 'OPERATION_END name=%s rc=%s elapsed_seconds=%s\n' "$name" "$rc" "$elapsed"
  return "$rc"
}
