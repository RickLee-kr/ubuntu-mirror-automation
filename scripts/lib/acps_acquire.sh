#!/usr/bin/env bash
# scripts/lib/acps_acquire.sh — ACPS Phase 2 download (GUI credentials, no hardcoded secrets)
# shellcheck shell=bash
set +x

if [[ -n "${ACPS_ACQUIRE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
ACPS_ACQUIRE_LOADED=1

# Expects mirror_manager_common.sh and dp-phase2-common.sh already sourced.

ACPS_CURL_CONNECT_TIMEOUT="${ACPS_CURL_CONNECT_TIMEOUT:-30}"
ACPS_CURL_RETRIES="${ACPS_CURL_RETRIES:-5}"
ACPS_CURL_RETRY_DELAY="${ACPS_CURL_RETRY_DELAY:-5}"
ACPS_PROGRESS_INTERVAL_SEC="${ACPS_PROGRESS_INTERVAL_SEC:-3}"

acps_cache_dir() {
  local ver="${1:-$DP_PHASE2_VERSION}"
  printf '%s/acps/%s\n' "${MM_CACHE_ROOT}" "$ver"
}

acps_is_verified_cache() {
  local dir="$1"
  [[ -f "${dir}/.VERIFIED" ]] || return 1
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    [[ -f "${dir}/${f}" ]] || return 1
  done
  if ! (
    set +e
    dp2_verify_payload_checksums "$dir" >/dev/null 2>&1
  ); then
    return 1
  fi
  if ! (
    set +e
    for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
      dp2_reject_bad_payload "${dir}/${f}" "$f" >/dev/null 2>&1 || exit 1
    done
    exit 0
  ); then
    return 1
  fi
  return 0
}

acps_expected_bytes_hint() {
  local base="$1"
  local total=0
  local name url cl err
  err="$(mktemp)"
  for name in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    url="${base%/}/${name}"
    cl="$(
      curl -sS -I -L --connect-timeout "$ACPS_CURL_CONNECT_TIMEOUT" \
        ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
        ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
        "$url" 2>"$err" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2; exit}'
    )" || true
    if [[ "$cl" =~ ^[0-9]+$ ]]; then
      total=$((total + cl))
    fi
  done
  rm -f "$err"
  printf '%s\n' "$total"
}

acps_setup_curl_auth() {
  ACPS_CURL_AUTH_ARGS=()
  ACPS_CURL_TLS_ARGS=()
  if [[ -n "${DP_PHASE2_SOURCE_BASE:-}" ]]; then
    ACPS_EFFECTIVE_BASE="${DP_PHASE2_SOURCE_BASE}"
    return 0
  fi
  ACPS_EFFECTIVE_BASE="${ACPS_BASE_URL:-$ACPS_BASE_URL_FIXED}"
  [[ -n "${ACPS_USERNAME:-}" ]] || mm_die "ACPS_USERNAME=FAIL missing"
  [[ -n "${ACPS_PASSWORD:-}" ]] || mm_die "ACPS_PASSWORD=FAIL missing"
  ACPS_CURL_AUTH_ARGS=(-u "${ACPS_USERNAME}:${ACPS_PASSWORD}")
  if [[ "${ACPS_INSECURE_TLS:-1}" == "1" ]]; then
    ACPS_CURL_TLS_ARGS+=(-k)
  fi
}

acps_test_connection() {
  acps_setup_curl_auth
  # Probe an authenticated artifact, not the directory index.
  # ACPS nginx returns 403 for "/" even with valid Basic auth (no autoindex),
  # which previously caused false ACPS_CONNECTION=FAIL.
  local probe="${ACPS_CONNECTION_PROBE_FILE:-aelladeb_py3_common.tar.gz.sha1}"
  local url="${ACPS_EFFECTIVE_BASE%/}/${probe}"
  local code
  code="$(
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 30 \
      ${ACPS_CURL_TLS_ARGS[@]+"${ACPS_CURL_TLS_ARGS[@]}"} \
      ${ACPS_CURL_AUTH_ARGS[@]+"${ACPS_CURL_AUTH_ARGS[@]}"} \
      -I -L "$url" 2>/dev/null || true
  )"
  code="${code:-000}"
  # curl may print "000" on failure; ignore non-numeric garbage
  [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
  if [[ "$code" == "000" ]]; then
    mm_error "ACPS_CONNECTION=FAIL code=${code} url=${probe}"
    return 1
  fi
  if [[ "$code" == "401" ]]; then
    mm_error "ACPS_CONNECTION=FAIL auth code=${code}"
    return 1
  fi
  if [[ "$code" == "403" ]]; then
    mm_error "ACPS_CONNECTION=FAIL forbidden code=${code} url=${probe}"
    return 1
  fi
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    mm_ok "ACPS_CONNECTION=PASS code=${code} probe=${probe}"
    return 0
  fi
  # 404 after auth usually means wrong version/path, not bad password.
  mm_error "ACPS_CONNECTION=FAIL unexpected code=${code} probe=${probe}"
  return 1
}

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
  if ! curl "${curl_args[@]}" "$url" 2>"$err"; then
    rc=$?
  fi
  if [[ -n "$progress_pid" ]]; then
    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true
  fi

  if [[ "$rc" -ne 0 ]]; then
    mm_redact <"$err" >&2 || true
    rm -f "$err"
    mm_error "ACPS_DOWNLOAD_FAILED file=${name}"
    return 1
  fi
  rm -f "$err"

  if ! dp2_reject_bad_payload "$part" "$name"; then
    rm -f "$part"
    mm_error "ACPS_DOWNLOAD_FAILED file=${name} reason=bad_payload"
    return 1
  fi
  mv -f "$part" "$final"
  now="$(date +%s)"
  elapsed=$((now - start_ts))
  mm_ok "ACPS_DOWNLOAD_COMPLETE file=${name} size=$(stat -c%s "$final") elapsed=${elapsed}s"
  return 0
}

acps_acquire_all() {
  local ver="$1"
  local cache
  cache="$(acps_cache_dir "$ver")"
  mkdir -p "$cache"
  acps_setup_curl_auth

  if acps_is_verified_cache "$cache"; then
    mm_ok "ACPS_DOWNLOAD=REUSED cache=${cache}"
    mm_state_set ACPS_PHASE2_DOWNLOADED REUSED
    mm_state_set ACPS_CHECKSUM PASS
    return 0
  fi

  rm -f "${cache}/.VERIFIED"

  local name
  for name in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    acps_download_one "$name" "$cache" || {
      mm_state_set ACPS_PHASE2_DOWNLOADED FAIL
      mm_die "ACPS_DOWNLOAD=FAIL file=${name}"
    }
  done

  dp2_assert_exact_files_dir "$cache"
  if ! dp2_verify_payload_checksums "$cache"; then
    mm_state_set ACPS_CHECKSUM FAIL
    rm -f "${cache}/.VERIFIED"
    mm_die "ACPS_CHECKSUM=FAIL"
  fi
  mm_state_set ACPS_CHECKSUM PASS
  date -u +%Y-%m-%dT%H:%M:%SZ >"${cache}/.VERIFIED"
  mm_ok "ACPS_DOWNLOAD=PASS"
  mm_state_set ACPS_PHASE2_DOWNLOADED PASS
}

acps_cleanup_cache() {
  local ver="$1"
  local cache
  cache="$(acps_cache_dir "$ver")"
  rm -rf "$cache"
  mm_info "ACPS_CACHE_CLEANUP=DONE"
}
