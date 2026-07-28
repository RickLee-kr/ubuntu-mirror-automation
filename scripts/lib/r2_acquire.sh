#!/usr/bin/env bash
# scripts/lib/r2_acquire.sh — download Ubuntu OS Core package from fixed R2 URL
# shellcheck shell=bash
set +x

if [[ -n "${R2_ACQUIRE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
R2_ACQUIRE_LOADED=1

R2_CURL_CONNECT_TIMEOUT="${R2_CURL_CONNECT_TIMEOUT:-30}"
R2_CURL_RETRIES="${R2_CURL_RETRIES:-5}"
R2_CURL_RETRY_DELAY="${R2_CURL_RETRY_DELAY:-5}"
R2_PROGRESS_INTERVAL_SEC="${R2_PROGRESS_INTERVAL_SEC:-5}"

r2_cache_dir() {
  printf '%s/r2\n' "${MM_CACHE_ROOT}"
}

r2_require_url() {
  if ! mm_r2_url_configured; then
    mm_error "CONFIGURATION_REQUIRED=YES"
    mm_error "R2_URL_REQUIRED_LOCATION=scripts/lib/mirror_manager_common.sh:OS_CORE_R2_URL_CONSTANT"
    mm_die "OS_CORE_R2_URL=CONFIGURATION_REQUIRED"
  fi
  mm_ok "OS_CORE_R2_URL=CONFIGURED"
}

r2_reject_html_body() {
  local path="$1"
  local label="${2:-$path}"
  [[ -f "$path" ]] || return 1
  local head
  # Binary packages may contain NUL; strip before grep.
  head="$(head -c 256 "$path" 2>/dev/null | tr -d '\0' || true)"
  if printf '%s' "$head" | grep -qiE '<!DOCTYPE[[:space:]]*html|<html[[:space:]]'; then
    mm_error "R2_HTML_BODY=FAIL file=${label}"
    return 1
  fi
  return 0
}

r2_download_package() {
  # Downloads OS Core .tar (+ attempts .sha256 sidecar) into cache; sets OS_CORE_PACKAGE.
  r2_require_url
  local dest_dir part final url start_ts now elapsed downloaded expected pct rate
  dest_dir="$(r2_cache_dir)"
  mkdir -p "$dest_dir"
  url="${OS_CORE_R2_URL}"
  local base_name
  base_name="$(basename "${url%%\?*}")"
  [[ -n "$base_name" ]] || base_name="ubuntu-os-core.tar"
  final="${dest_dir}/${base_name}"
  part="${final}.part"

  # Sidecar checksum URL: same path + .sha256
  local sha_url="${url}.sha256"
  local sha_final="${final}.sha256"
  local sha_part="${sha_final}.part"

  mm_info "R2_DOWNLOAD_START url_redacted=yes file=${base_name}"
  start_ts="$(date +%s)"
  expected=""
  local cl err_head
  err_head="$(mktemp)"
  cl="$(
    curl -sS -I -L --connect-timeout "$R2_CURL_CONNECT_TIMEOUT" "$url" 2>"$err_head" \
      | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2; exit}'
  )" || true
  rm -f "$err_head"
  if [[ "$cl" =~ ^[0-9]+$ ]]; then
    expected="$cl"
  fi

  local err progress_pid=""
  err="$(mktemp)"
  (
    while true; do
      sleep "$R2_PROGRESS_INTERVAL_SEC" || break
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
      mm_info "R2_DOWNLOAD_PROGRESS file=${base_name} downloaded_bytes=${downloaded} expected_bytes=${expected:-UNKNOWN} percentage=${pct} elapsed=${elapsed}s rate_bps=${rate}"
    done
  ) &
  progress_pid=$!

  local rc=0
  if ! curl -f -L \
    --connect-timeout "$R2_CURL_CONNECT_TIMEOUT" \
    --retry "$R2_CURL_RETRIES" \
    --retry-delay "$R2_CURL_RETRY_DELAY" \
    --retry-all-errors \
    --continue-at - \
    -o "$part" \
    "$url" 2>"$err"; then
    rc=$?
  fi
  if [[ -n "$progress_pid" ]]; then
    kill "$progress_pid" 2>/dev/null || true
    wait "$progress_pid" 2>/dev/null || true
  fi
  if [[ "$rc" -ne 0 ]]; then
    mm_redact <"$err" >&2 || true
    rm -f "$err"
    mm_state_set R2_OS_CORE_DOWNLOADED FAIL
    mm_die "R2_DOWNLOAD=FAIL file=${base_name}"
  fi
  rm -f "$err"

  if ! r2_reject_html_body "$part" "$base_name"; then
    rm -f "$part"
    mm_state_set R2_OS_CORE_DOWNLOADED FAIL
    mm_die "R2_DOWNLOAD=FAIL reason=html_body"
  fi
  if [[ -n "$expected" && "$expected" =~ ^[0-9]+$ ]]; then
    local got
    got="$(stat -c%s "$part")"
    if [[ "$got" -ne "$expected" ]]; then
      mm_warn "R2_CONTENT_LENGTH_MISMATCH expected=${expected} got=${got}"
    fi
  fi
  mv -f "$part" "$final"

  # Download outer checksum (required)
  err="$(mktemp)"
  if ! curl -f -L \
    --connect-timeout "$R2_CURL_CONNECT_TIMEOUT" \
    --retry "$R2_CURL_RETRIES" \
    --retry-delay "$R2_CURL_RETRY_DELAY" \
    --retry-all-errors \
    --continue-at - \
    -o "$sha_part" \
    "$sha_url" 2>"$err"; then
    mm_redact <"$err" >&2 || true
    rm -f "$err" "$sha_part"
    mm_state_set R2_OS_CORE_CHECKSUM FAIL
    mm_die "R2_SHA256_DOWNLOAD=FAIL"
  fi
  rm -f "$err"
  if ! r2_reject_html_body "$sha_part" "${base_name}.sha256"; then
    rm -f "$sha_part"
    mm_die "R2_SHA256_DOWNLOAD=FAIL reason=html_body"
  fi
  mv -f "$sha_part" "$sha_final"

  # Optional signature sidecar (best-effort)
  local asc_url="${sha_url}.asc"
  local asc_final="${sha_final}.asc"
  if curl -fsSL --connect-timeout 10 -o "${asc_final}.part" "$asc_url" 2>/dev/null; then
    if r2_reject_html_body "${asc_final}.part" 2>/dev/null; then
      mv -f "${asc_final}.part" "$asc_final"
    else
      rm -f "${asc_final}.part"
    fi
  else
    rm -f "${asc_final}.part"
  fi

  OS_CORE_PACKAGE="$final"
  OS_CORE_PACKAGE_BYTES="$(mm_file_bytes "$final")"
  mm_state_set R2_OS_CORE_DOWNLOADED PASS
  mm_ok "R2_DOWNLOAD=PASS file=${base_name} size=${OS_CORE_PACKAGE_BYTES}"
}

r2_cleanup_package() {
  local pkg="${OS_CORE_PACKAGE:-}"
  [[ -n "$pkg" ]] || return 0
  rm -f "$pkg" "${pkg}.sha256" "${pkg}.sha256.asc" "${pkg}.part" "${pkg}.sha256.part" 2>/dev/null || true
  mm_info "R2_PACKAGE_CLEANUP=DONE"
}
