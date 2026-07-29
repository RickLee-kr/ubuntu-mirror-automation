#!/usr/bin/env bash
# Compatibility wrapper around the original ACPS acquisition implementation.
# The override preserves curl's real exit status and emits a final progress row.
# shellcheck shell=bash
set +x

_ACPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=acps_acquire_base.sh
source "${_ACPS_DIR}/acps_acquire_base.sh"
unset _ACPS_DIR

acps_download_one() {
  local name="$1"
  local dest_dir="$2"
  local part="${dest_dir}/${name}.part"
  local final="${dest_dir}/${name}"
  local url="${ACPS_EFFECTIVE_BASE%/}/${name}"
  local start_ts now elapsed downloaded expected pct rate
  local curl_args=(
    -f -L
    --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT"
    --retry "$ACPS_CURL_RETRIES"
    --retry-delay "$ACPS_CURL_RETRY_DELAY"
    --retry-all-errors
    --continue-at -
    -o "$part"
  )
  curl_args+=(${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"})
  curl_args+=(${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"})

  mkdir -p "$dest_dir"
  if [[ -f "$final" ]]; then
    mm_info "ACPS_DOWNLOAD_SKIP_EXISTING file=${name}"
    return 0
  fi

  mm_info "ACPS_DOWNLOAD_START file=${name}"
  start_ts="$(date +%s)"
  expected=""
  local cl err_head
  err_head="$(mktemp)"
  cl="$(
    curl -sS -I -L --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT" \
      ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
      ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
      "$url" 2>"$err_head" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2; exit}'
  )" || true
  rm -f "$err_head"
  if [[ "$cl" =~ ^[0-9]+$ ]]; then
    expected="$cl"
  fi

  local err progress_pid=""
  err="$(mktemp)"
  (
    while true; do
      sleep "$ACPS_PROGRESS_INTERVAL_SEC" || break
      now="$(date +%s)"
      elapsed=$((now - start_ts))
      downloaded=0
      [[ -f "$part" ]] && downloaded="$(stat -c%s "$part" 2>/dev/null || echo 0)"
      pct="UNKNOWN"
      rate="UNKNOWN"
      if [[ -n "$expected" && "$expected" -gt 0 ]]; then
        pct=$((downloaded * 100 / expected))
      fi
      if [[ "$elapsed" -gt 0 ]]; then
        rate=$((downloaded / elapsed))
      fi
      mm_info "ACPS_DOWNLOAD_PROGRESS file=${name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate}"
      mm_progress_line "ACPS ${name}" "$downloaded" "${expected:-}" "$elapsed" "$rate"
    done
  ) &
  progress_pid=$!

  local rc=0
  if curl "${curl_args[@]}" "$url" 2>"$err"; then
    rc=0
  else
    rc=$?
  fi
  if [[ -n "$progress_pid" ]]; then
    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true
  fi

  if [[ "$rc" -ne 0 ]]; then
    mm_redact <"$err" >&2 || true
    rm -f "$err"
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} curl_rc=${rc}"
    return "$rc"
  fi
  rm -f "$err"

  if ! dp2_reject_bad_payload "$part" "$name"; then
    rm -f "$part"
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} reason=bad_payload"
    return 1
  fi
  mv -f "$part" "$final" || {
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} reason=finalize"
    return 1
  }

  now="$(date +%s)"
  elapsed=$((now - start_ts))
  downloaded="$(stat -c%s "$final")"
  pct="UNKNOWN"
  rate="UNKNOWN"
  if [[ -n "$expected" && "$expected" -gt 0 ]]; then
    pct=$((downloaded * 100 / expected))
  fi
  if [[ "$elapsed" -gt 0 ]]; then
    rate=$((downloaded / elapsed))
  fi
  mm_info "ACPS_DOWNLOAD_PROGRESS file=${name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate} final=yes"
  mm_progress_line "ACPS ${name}" "$downloaded" "${expected:-}" "$elapsed" "$rate"
  mm_ok "ACPS_DOWNLOAD_COMPLETE file=${name} size=${downloaded} elapsed=${elapsed}s"
  return 0
}
