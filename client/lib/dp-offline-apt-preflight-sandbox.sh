# shellcheck shell=bash
# Shared authoritative temporary APT authentication preflight sandbox for all
# OS-hop clients.
#
# Injected into single-file clients at build time via the
# APT_PREFLIGHT_SANDBOX_HELPER template token (see build_client_*.py).
# Directly sourceable by fixture tests.
#
# Depends on caller-provided:
#   hostpath, log, die, STATE_ROOT, EC_MIRROR, PIN_HOP, PIN_SOURCE_SUITES,
#   PIN_COMPONENTS, CURRENT_RUN_ID (optional)
#
# Critical design:
#   Temporary APT root is a dedicated mktemp directory mode 0755 so the APT
#   sandbox user (_apt) can traverse it. It MUST NOT be nested under a
#   root-private 0700 work directory (that caused Xenial NO_PUBKEY / permission
#   denied despite valid InRelease gpgv verification).

APT_PREFLIGHT_ROOT=""
APT_PREFLIGHT_KEYRING=""
APT_PREFLIGHT_OUT=""
APT_PREFLIGHT_ERR=""
APT_PREFLIGHT_EVIDENCE_DIR=""
APT_SANDBOX_USER="_apt"
APT_SANDBOX_TRAVERSAL="UNKNOWN"
APT_SANDBOX_KEYRING_READABLE="UNKNOWN"
APT_SANDBOX_LISTS_PARTIAL_WRITABLE="UNKNOWN"
APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE="UNKNOWN"
APT_GET_EXIT_CODE=""
APT_PREFLIGHT_CLIENT_EXIT_CODE=""
APT_SIGNATURE_WARNING_COUNT=0
APT_EXTERNAL_SOURCE_REFERENCE_COUNT=0
APT_REPOSITORY_AUTHENTICATION="UNKNOWN"
APT_PERMISSION_WARNING_COUNT=0

apt_preflight_sandbox_user_exists() {
  getent passwd _apt >/dev/null 2>&1
}

apt_preflight_run_as_sandbox() {
  # Run a simple command as _apt. Prefer sudo (clients already run as root).
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$APT_SANDBOX_USER" "$@"
  elif command -v runuser >/dev/null 2>&1; then
    runuser -u "$APT_SANDBOX_USER" -- "$@"
  else
    return 127
  fi
}

apt_preflight_cleanup_temp_root() {
  if [[ -n "${APT_PREFLIGHT_ROOT:-}" && -d "${APT_PREFLIGHT_ROOT}" ]]; then
    rm -rf "${APT_PREFLIGHT_ROOT}"
  fi
  APT_PREFLIGHT_ROOT=""
}

# Persist apt-update stdout/stderr and metadata under a root-owned evidence path.
# Path: ${STATE_ROOT}/evidence/apt-preflight/<run-id>/
# Directory mode 0700, files mode 0600, atomic publication via temp+rename.
persist_apt_preflight_evidence() {
  local label="${1:-apt-preflight}"
  local run_id stamp dest staging f
  run_id="${CURRENT_RUN_ID:-}"
  if [[ -z "$run_id" ]]; then
    run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  fi
  stamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  dest="$(hostpath "${STATE_ROOT}/evidence/apt-preflight/${run_id}")"
  staging="${dest}.tmp.$$.$RANDOM"
  mkdir -p "$(dirname "$dest")"
  rm -rf "$staging"
  mkdir -p "$staging"
  chmod 0700 "$staging"

  if [[ -n "${APT_PREFLIGHT_ERR:-}" && -f "${APT_PREFLIGHT_ERR}" ]]; then
    cp -a "${APT_PREFLIGHT_ERR}" "${staging}/apt-update.err" 2>/dev/null || true
  fi
  if [[ -n "${APT_PREFLIGHT_OUT:-}" && -f "${APT_PREFLIGHT_OUT}" ]]; then
    cp -a "${APT_PREFLIGHT_OUT}" "${staging}/apt-update.out" 2>/dev/null || true
  fi
  if [[ -n "${APT_PREFLIGHT_ROOT:-}" && -f "${APT_PREFLIGHT_ROOT}/etc/apt/sources.list" ]]; then
    cp -a "${APT_PREFLIGHT_ROOT}/etc/apt/sources.list" "${staging}/sources.list" 2>/dev/null || true
  fi

  {
    printf 'label=%s\n' "$label"
    printf 'hop=%s\n' "${PIN_HOP:-}"
    printf 'timestamp=%s\n' "$stamp"
    printf 'APT_SANDBOX_USER=%s\n' "${APT_SANDBOX_USER}"
    printf 'APT_TEMP_ROOT=%s\n' "${APT_PREFLIGHT_ROOT:-}"
    printf 'APT_GET_EXIT_CODE=%s\n' "${APT_GET_EXIT_CODE:-}"
    printf 'APT_PREFLIGHT_CLIENT_EXIT_CODE=%s\n' "${APT_PREFLIGHT_CLIENT_EXIT_CODE:-}"
    printf 'APT_SANDBOX_TRAVERSAL=%s\n' "${APT_SANDBOX_TRAVERSAL}"
    printf 'APT_SANDBOX_KEYRING_READABLE=%s\n' "${APT_SANDBOX_KEYRING_READABLE}"
    printf 'APT_SANDBOX_LISTS_PARTIAL_WRITABLE=%s\n' "${APT_SANDBOX_LISTS_PARTIAL_WRITABLE}"
    printf 'APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE=%s\n' "${APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE}"
    printf 'APT_SIGNATURE_WARNING_COUNT=%s\n' "${APT_SIGNATURE_WARNING_COUNT}"
    printf 'APT_EXTERNAL_SOURCE_REFERENCE_COUNT=%s\n' "${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}"
    printf 'APT_REPOSITORY_AUTHENTICATION=%s\n' "${APT_REPOSITORY_AUTHENTICATION}"
  } >"${staging}/meta.txt"

  printf '%s\n' "${APT_GET_EXIT_CODE:-}" >"${staging}/apt-get-exit-code"
  printf '%s\n' "${APT_PREFLIGHT_CLIENT_EXIT_CODE:-}" >"${staging}/client-exit-code"

  # Mode 0600 for all regular files; keep directory 0700.
  find "$staging" -type f -exec chmod 0600 {} + 2>/dev/null || true
  chmod 0700 "$staging"

  rm -rf "$dest"
  mv -f "$staging" "$dest"
  APT_PREFLIGHT_EVIDENCE_DIR="$dest"
  log INFO "APT_PREFLIGHT_EVIDENCE=${dest}"
  printf '%s\n' "$dest"
}

# Backward-compatible name used by cross-release temp APT failure paths.
# Accepts either a private work dir containing apt-update.* or an aptroot parent.
persist_temp_apt_failure_evidence() {
  local tmp="$1"
  local exit_code="$2"
  local label="${3:-apt-update}"
  APT_GET_EXIT_CODE="${exit_code}"
  APT_PREFLIGHT_CLIENT_EXIT_CODE="${EC_MIRROR:-18}"
  APT_REPOSITORY_AUTHENTICATION="FAIL"
  if [[ -f "${tmp}/apt-update.err" ]]; then
    APT_PREFLIGHT_ERR="${tmp}/apt-update.err"
  elif [[ -f "${tmp}/update.err" ]]; then
    APT_PREFLIGHT_ERR="${tmp}/update.err"
  fi
  if [[ -f "${tmp}/apt-update.out" ]]; then
    APT_PREFLIGHT_OUT="${tmp}/apt-update.out"
  fi
  if [[ -d "${tmp}/aptroot" ]]; then
    APT_PREFLIGHT_ROOT="${tmp}/aptroot"
  elif [[ -f "${tmp}/etc/apt/sources.list" ]]; then
    APT_PREFLIGHT_ROOT="$tmp"
  fi
  persist_apt_preflight_evidence "$label" || true
}

apt_preflight_log_sandbox_state() {
  local mode owner key_mode
  mode="missing"
  owner="missing"
  key_mode="missing"
  if [[ -n "${APT_PREFLIGHT_ROOT:-}" && -d "${APT_PREFLIGHT_ROOT}" ]]; then
    mode="$(stat -c '%a' "${APT_PREFLIGHT_ROOT}" 2>/dev/null || printf 'unknown')"
    owner="$(stat -c '%U:%G' "${APT_PREFLIGHT_ROOT}" 2>/dev/null || printf 'unknown')"
  fi
  if [[ -n "${APT_PREFLIGHT_KEYRING:-}" && -f "${APT_PREFLIGHT_KEYRING}" ]]; then
    key_mode="$(stat -c '%a' "${APT_PREFLIGHT_KEYRING}" 2>/dev/null || printf 'unknown')"
  fi
  log INFO "APT_SANDBOX_USER=${APT_SANDBOX_USER}"
  log INFO "APT_TEMP_ROOT=${APT_PREFLIGHT_ROOT:-}"
  log INFO "APT_TEMP_ROOT_MODE=${mode}"
  log INFO "APT_TEMP_ROOT_OWNER=${owner}"
  log INFO "APT_TEMP_KEYRING_MODE=${key_mode}"
  log INFO "APT_SANDBOX_TRAVERSAL=${APT_SANDBOX_TRAVERSAL}"
  log INFO "APT_SANDBOX_KEYRING_READABLE=${APT_SANDBOX_KEYRING_READABLE}"
  log INFO "APT_SANDBOX_LISTS_PARTIAL_WRITABLE=${APT_SANDBOX_LISTS_PARTIAL_WRITABLE}"
  log INFO "APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE=${APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE}"
}

apt_preflight_emit_warning_evidence() {
  local src n line
  n=0
  for src in ${APT_PREFLIGHT_ERR:-} ${APT_PREFLIGHT_OUT:-}; do
    [[ -f "$src" ]] || continue
    while IFS= read -r line; do
      if printf '%s' "$line" | grep -qiE "NO_PUBKEY|BADSIG|EXPKEYSIG|is not signed|not signed|Release file|signatures couldn'?t be verified|signatures could not be verified"; then
        n=$((n + 1))
        # Sanitize: never emit key material (none present in apt warnings).
        log ERROR "APT_SIGNATURE_WARNING_${n}=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-240)"
      fi
    done <"$src"
  done
  n=0
  for src in ${APT_PREFLIGHT_ERR:-} ${APT_PREFLIGHT_OUT:-}; do
    [[ -f "$src" ]] || continue
    while IFS= read -r line; do
      if printf '%s' "$line" | grep -qiE "Can'?t drop privileges|Permission denied|pkgAcquire::Run"; then
        n=$((n + 1))
        log ERROR "APT_PERMISSION_WARNING_${n}=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-240)"
      fi
    done <"$src"
  done
  APT_PERMISSION_WARNING_COUNT="$n"
}

# Create a dedicated _apt-accessible temporary APT root (NOT under a 0700 private dir).
# Args: public_keyring_path
# Sets APT_PREFLIGHT_ROOT / APT_PREFLIGHT_KEYRING / OUT / ERR paths.
apt_preflight_create_sandbox() {
  local keyring_src="$1"
  local aptroot keyring_dst lists_partial archives_partial
  local d

  [[ -f "$keyring_src" && -s "$keyring_src" ]] \
    || die "${EC_MIRROR:-18}" "APT preflight keyring missing or empty: ${keyring_src}"

  aptroot="$(mktemp -d /tmp/stellar-apt-preflight.XXXXXX)"
  # mktemp defaults to 0700 — open the outer root so _apt can traverse.
  chmod 0755 "$aptroot"
  chown root:root "$aptroot" 2>/dev/null || true

  for d in \
    etc \
    etc/apt \
    etc/apt/sources.list.d \
    etc/apt/apt.conf.d \
    etc/apt/trusted.gpg.d \
    var \
    var/lib \
    var/lib/apt \
    var/lib/apt/lists \
    var/cache \
    var/cache/apt \
    var/cache/apt/archives
  do
    mkdir -p "${aptroot}/${d}"
    chown root:root "${aptroot}/${d}" 2>/dev/null || true
    chmod 0755 "${aptroot}/${d}"
  done

  lists_partial="${aptroot}/var/lib/apt/lists/partial"
  archives_partial="${aptroot}/var/cache/apt/archives/partial"
  mkdir -p "$lists_partial" "$archives_partial"

  if apt_preflight_sandbox_user_exists; then
    APT_SANDBOX_USER="_apt"
    # Match Ubuntu host layout: _apt:root mode 0700 on partial dirs.
    chown _apt:root "$lists_partial" "$archives_partial" 2>/dev/null \
      || chown _apt "$lists_partial" "$archives_partial"
    chmod 0700 "$lists_partial" "$archives_partial"
  else
    APT_SANDBOX_USER="missing"
    chmod 0755 "$lists_partial" "$archives_partial"
  fi

  keyring_dst="${aptroot}/etc/apt/trusted.gpg.d/stellar-offline-upgrade.gpg"
  # Public keyring only — never copy private key material.
  cp -a "$keyring_src" "$keyring_dst"
  chown root:root "$keyring_dst" 2>/dev/null || true
  chmod 0644 "$keyring_dst"

  # Empty main sources.list placeholder filled by caller; empty sourceparts.
  : >"${aptroot}/etc/apt/sources.list"
  chmod 0644 "${aptroot}/etc/apt/sources.list"

  APT_PREFLIGHT_ROOT="$aptroot"
  APT_PREFLIGHT_KEYRING="$keyring_dst"
  APT_PREFLIGHT_OUT="${aptroot}/apt-update.out"
  APT_PREFLIGHT_ERR="${aptroot}/apt-update.err"
  : >"${APT_PREFLIGHT_OUT}"
  : >"${APT_PREFLIGHT_ERR}"
  chmod 0600 "${APT_PREFLIGHT_OUT}" "${APT_PREFLIGHT_ERR}"
}

# Fail-closed probes before apt-get update.
apt_preflight_verify_sandbox_access() {
  local aptroot keyring lists_partial archives_partial probe
  aptroot="${APT_PREFLIGHT_ROOT}"
  keyring="${APT_PREFLIGHT_KEYRING}"
  lists_partial="${aptroot}/var/lib/apt/lists/partial"
  archives_partial="${aptroot}/var/cache/apt/archives/partial"

  APT_SANDBOX_TRAVERSAL="FAIL"
  APT_SANDBOX_KEYRING_READABLE="FAIL"
  APT_SANDBOX_LISTS_PARTIAL_WRITABLE="FAIL"
  APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE="FAIL"

  if ! apt_preflight_sandbox_user_exists; then
    apt_preflight_log_sandbox_state
    log ERROR "APT_SANDBOX_USER_MISSING=YES"
    return 1
  fi

  if apt_preflight_run_as_sandbox test -x "$aptroot" \
    && apt_preflight_run_as_sandbox test -x "${aptroot}/etc" \
    && apt_preflight_run_as_sandbox test -x "${aptroot}/etc/apt" \
    && apt_preflight_run_as_sandbox test -x "${aptroot}/etc/apt/trusted.gpg.d"
  then
    APT_SANDBOX_TRAVERSAL="PASS"
  fi

  if apt_preflight_run_as_sandbox test -r "$keyring"; then
    APT_SANDBOX_KEYRING_READABLE="PASS"
  fi

  probe="${lists_partial}/.stellar-apt-write-test.$$"
  if apt_preflight_run_as_sandbox touch "$probe" 2>/dev/null; then
    APT_SANDBOX_LISTS_PARTIAL_WRITABLE="PASS"
    rm -f "$probe" 2>/dev/null || apt_preflight_run_as_sandbox rm -f "$probe" 2>/dev/null || true
  fi

  probe="${archives_partial}/.stellar-apt-write-test.$$"
  if apt_preflight_run_as_sandbox touch "$probe" 2>/dev/null; then
    APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE="PASS"
    rm -f "$probe" 2>/dev/null || apt_preflight_run_as_sandbox rm -f "$probe" 2>/dev/null || true
  fi

  apt_preflight_log_sandbox_state

  if [[ "$APT_SANDBOX_TRAVERSAL" != "PASS" \
     || "$APT_SANDBOX_KEYRING_READABLE" != "PASS" \
     || "$APT_SANDBOX_LISTS_PARTIAL_WRITABLE" != "PASS" \
     || "$APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE" != "PASS" ]]; then
    return 1
  fi
  return 0
}

apt_preflight_write_sources() {
  local repo="$1"
  local suites="$2"
  local components="$3"
  local aptroot s
  aptroot="${APT_PREFLIGHT_ROOT}"
  {
    for s in $suites; do
      printf 'deb [arch=amd64] %s %s %s\n' "$repo" "$s" "$components"
    done
  } >"${aptroot}/etc/apt/sources.list"
  chmod 0644 "${aptroot}/etc/apt/sources.list"
}

# Explicit Xenial apt 1.2-compatible Dir overrides; host sources/keyrings excluded.
apt_preflight_run_apt_update() {
  local aptroot status_db
  aptroot="${APT_PREFLIGHT_ROOT}"
  status_db="$(hostpath /var/lib/dpkg/status)"
  APT_GET_EXIT_CODE=0
  set +e
  apt-get \
    -o Dir="${aptroot}" \
    -o Dir::Etc="${aptroot}/etc/apt" \
    -o Dir::Etc::sourcelist="${aptroot}/etc/apt/sources.list" \
    -o Dir::Etc::sourceparts="${aptroot}/etc/apt/sources.list.d" \
    -o Dir::Etc::trusted="${aptroot}/etc/apt/trusted.gpg" \
    -o Dir::Etc::trustedparts="${aptroot}/etc/apt/trusted.gpg.d" \
    -o Dir::Etc::Parts="${aptroot}/etc/apt/apt.conf.d" \
    -o Dir::State="${aptroot}/var/lib/apt" \
    -o Dir::State::status="${status_db}" \
    -o Dir::State::lists="${aptroot}/var/lib/apt/lists" \
    -o Dir::Cache="${aptroot}/var/cache/apt" \
    -o Dir::Cache::archives="${aptroot}/var/cache/apt/archives" \
    -o Acquire::Languages=none \
    -o APT::Get::AllowUnauthenticated=false \
    update >"${APT_PREFLIGHT_OUT}" 2>"${APT_PREFLIGHT_ERR}"
  APT_GET_EXIT_CODE=$?
  set -e
  log INFO "APT_GET_EXIT_CODE=${APT_GET_EXIT_CODE}"
}

apt_preflight_count_signature_warnings() {
  local count=0
  APT_SIGNATURE_WARNING_COUNT=0
  count="$(
    { grep -hciE "NO_PUBKEY|BADSIG|EXPKEYSIG|signatures couldn'?t be verified|signatures could not be verified|is not signed|does not have a Release file|The repository is not signed|invalid signature|missing Release|repository without a Release" \
      ${APT_PREFLIGHT_ERR:-/dev/null} ${APT_PREFLIGHT_OUT:-/dev/null} 2>/dev/null || true; } \
      | awk '{s+=$1} END {print s+0}'
  )"
  APT_SIGNATURE_WARNING_COUNT="${count:-0}"
}

apt_preflight_count_external_refs() {
  local count=0
  local aptroot="${APT_PREFLIGHT_ROOT}"
  local lists_glob
  APT_EXTERNAL_SOURCE_REFERENCE_COUNT=0
  count="$(
    { grep -hciE '(archive|security|old-releases|changelogs)\.ubuntu\.com' \
      ${APT_PREFLIGHT_ERR:-/dev/null} ${APT_PREFLIGHT_OUT:-/dev/null} 2>/dev/null || true; } \
      | awk '{s+=$1} END {print s+0}'
  )"
  # Also require acquired list filenames reference only the pinned hop mirror path.
  if [[ -d "${aptroot}/var/lib/apt/lists" ]]; then
    local f base
    shopt -s nullglob
    for f in "${aptroot}/var/lib/apt/lists/"*; do
      [[ -e "$f" ]] || continue
      base="$(basename "$f")"
      case "$base" in
        partial|lock) continue ;;
      esac
      # Hostnames for Ubuntu archives in list filenames are a hard failure.
      if printf '%s' "$base" | grep -qiE '(archive|security|old-releases|changelogs)[._-]ubuntu[._-]com'; then
        count=$((count + 1))
      fi
    done
    shopt -u nullglob
  fi
  APT_EXTERNAL_SOURCE_REFERENCE_COUNT="${count:-0}"
}

apt_preflight_fail() {
  local msg="$1"
  APT_REPOSITORY_AUTHENTICATION="FAIL"
  APT_PREFLIGHT_CLIENT_EXIT_CODE="${EC_MIRROR:-18}"
  log ERROR "APT_REPOSITORY_AUTHENTICATION=FAIL"
  log INFO "APT_GET_EXIT_CODE=${APT_GET_EXIT_CODE:-}"
  log INFO "APT_PREFLIGHT_CLIENT_EXIT_CODE=${APT_PREFLIGHT_CLIENT_EXIT_CODE}"
  log INFO "APT_SIGNATURE_WARNING_COUNT=${APT_SIGNATURE_WARNING_COUNT}"
  log INFO "APT_EXTERNAL_SOURCE_REFERENCE_COUNT=${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}"
  apt_preflight_emit_warning_evidence || true
  persist_apt_preflight_evidence "temporary_local_apt_preflight" || true
  apt_preflight_cleanup_temp_root
  die "${EC_MIRROR:-18}" "$msg"
}

# Main entry: temporary local APT authentication preflight.
# Args: keyring_path repo_url [suites] [components]
# suites/components default to PIN_SOURCE_SUITES / PIN_COMPONENTS.
run_temporary_local_apt_authentication_preflight() {
  local keyring_src="$1"
  local repo="$2"
  local suites="${3:-$PIN_SOURCE_SUITES}"
  local components="${4:-$PIN_COMPONENTS}"

  APT_PREFLIGHT_CLIENT_EXIT_CODE=0
  APT_REPOSITORY_AUTHENTICATION="UNKNOWN"
  APT_SIGNATURE_WARNING_COUNT=0
  APT_EXTERNAL_SOURCE_REFERENCE_COUNT=0

  apt_preflight_create_sandbox "$keyring_src"
  apt_preflight_write_sources "$repo" "$suites" "$components"

  if ! apt_preflight_verify_sandbox_access; then
    APT_GET_EXIT_CODE=""
    apt_preflight_fail "temporary APT sandbox not accessible to _apt (traversal/keyring/partial write)"
  fi

  apt_preflight_run_apt_update
  apt_preflight_count_signature_warnings
  apt_preflight_count_external_refs

  log INFO "APT_SIGNATURE_WARNING_COUNT=${APT_SIGNATURE_WARNING_COUNT}"
  log INFO "APT_EXTERNAL_SOURCE_REFERENCE_COUNT=${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}"

  if [[ "${APT_GET_EXIT_CODE}" -ne 0 ]]; then
    apt_preflight_fail "temporary local apt-get update failed (apt-get exit=${APT_GET_EXIT_CODE}; client exit will be ${EC_MIRROR:-18}; evidence under ${STATE_ROOT}/evidence/apt-preflight/)"
  fi
  if [[ "${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}" -ne 0 ]]; then
    apt_preflight_fail "temporary apt update referenced external Ubuntu hosts"
  fi
  if [[ "${APT_SIGNATURE_WARNING_COUNT}" -ne 0 ]]; then
    apt_preflight_fail "APT repository authentication failed during temporary local apt-get update"
  fi

  # Success: all gates required by contract.
  APT_REPOSITORY_AUTHENTICATION="PASS"
  APT_PREFLIGHT_CLIENT_EXIT_CODE=0
  log INFO "APT_GET_EXIT_CODE=${APT_GET_EXIT_CODE}"
  log INFO "APT_PREFLIGHT_CLIENT_EXIT_CODE=0"
  log INFO "APT_SANDBOX_TRAVERSAL=PASS"
  log INFO "APT_SANDBOX_KEYRING_READABLE=PASS"
  log INFO "APT_SANDBOX_LISTS_PARTIAL_WRITABLE=PASS"
  log INFO "APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE=PASS"
  log INFO "APT_REPOSITORY_AUTHENTICATION=PASS"
  log INFO "APT_SIGNATURE_WARNING_COUNT=0"
  log INFO "APT_EXTERNAL_SOURCE_REFERENCE_COUNT=0"
  log INFO "TEMPORARY_LOCAL_APT_UPDATE=PASS"
  # Preserve evidence of the successful preflight as well (stdout/stderr), then clean root.
  persist_apt_preflight_evidence "temporary_local_apt_preflight_success" || true
  apt_preflight_cleanup_temp_root
}
