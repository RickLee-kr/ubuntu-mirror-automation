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
#   PIN_COMPONENTS, CURRENT_RUN_ID (optional), PIN_KEY_FINGERPRINT (optional)
#
# Critical design:
#   Temporary APT root is a dedicated mktemp directory mode 0755 so the APT
#   sandbox user (_apt) can traverse it. It MUST NOT be nested under a
#   root-private 0700 work directory (that caused Xenial NO_PUBKEY / permission
#   denied despite valid InRelease gpgv verification).
#
# Trust model (Xenial apt 1.2):
#   Bind Dir::Etc::trusted to the exact binary public keyring file and keep
#   Dir::Etc::trustedparts as an empty dedicated directory. Do not depend on
#   trusted-parts directory discovery or host keyrings.

APT_PREFLIGHT_ROOT=""
APT_PREFLIGHT_KEYRING=""
APT_PREFLIGHT_TRUSTEDPARTS=""
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

# Effective path resolution (from apt-config dump with the same -o options).
APT_EFFECTIVE_DIR=""
APT_EFFECTIVE_ETC=""
APT_EFFECTIVE_SOURCELIST=""
APT_EFFECTIVE_SOURCEPARTS=""
APT_EFFECTIVE_TRUSTED=""
APT_EFFECTIVE_TRUSTEDPARTS=""
APT_EFFECTIVE_LISTS=""
APT_EFFECTIVE_ARCHIVES=""

# APT-level key visibility probe.
APT_EXPECTED_REPOSITORY_KEY_FPR=""
APT_EXPECTED_REPOSITORY_KEY_LONG_ID=""
APT_TRUSTED_KEY_VISIBLE="UNKNOWN"
APT_TRUSTED_KEY_VISIBLE_FPR=""
APT_TRUSTED_KEY_VISIBLE_LONG_ID=""
APT_GPGV_KEYRING_ARGUMENT=""

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
    printf 'APT_EFFECTIVE_DIR=%s\n' "${APT_EFFECTIVE_DIR}"
    printf 'APT_EFFECTIVE_ETC=%s\n' "${APT_EFFECTIVE_ETC}"
    printf 'APT_EFFECTIVE_SOURCELIST=%s\n' "${APT_EFFECTIVE_SOURCELIST}"
    printf 'APT_EFFECTIVE_SOURCEPARTS=%s\n' "${APT_EFFECTIVE_SOURCEPARTS}"
    printf 'APT_EFFECTIVE_TRUSTED=%s\n' "${APT_EFFECTIVE_TRUSTED}"
    printf 'APT_EFFECTIVE_TRUSTEDPARTS=%s\n' "${APT_EFFECTIVE_TRUSTEDPARTS}"
    printf 'APT_EFFECTIVE_LISTS=%s\n' "${APT_EFFECTIVE_LISTS}"
    printf 'APT_EFFECTIVE_ARCHIVES=%s\n' "${APT_EFFECTIVE_ARCHIVES}"
    printf 'APT_EXPECTED_REPOSITORY_KEY_FPR=%s\n' "${APT_EXPECTED_REPOSITORY_KEY_FPR}"
    printf 'APT_EXPECTED_REPOSITORY_KEY_LONG_ID=%s\n' "${APT_EXPECTED_REPOSITORY_KEY_LONG_ID}"
    printf 'APT_TRUSTED_KEY_VISIBLE=%s\n' "${APT_TRUSTED_KEY_VISIBLE}"
    printf 'APT_TRUSTED_KEY_VISIBLE_FPR=%s\n' "${APT_TRUSTED_KEY_VISIBLE_FPR}"
    printf 'APT_TRUSTED_KEY_VISIBLE_LONG_ID=%s\n' "${APT_TRUSTED_KEY_VISIBLE_LONG_ID}"
    printf 'APT_GPGV_KEYRING_ARGUMENT=%s\n' "${APT_GPGV_KEYRING_ARGUMENT}"
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

apt_preflight_log_trust_diagnostics() {
  log INFO "APT_EFFECTIVE_DIR=${APT_EFFECTIVE_DIR}"
  log INFO "APT_EFFECTIVE_ETC=${APT_EFFECTIVE_ETC}"
  log INFO "APT_EFFECTIVE_SOURCELIST=${APT_EFFECTIVE_SOURCELIST}"
  log INFO "APT_EFFECTIVE_SOURCEPARTS=${APT_EFFECTIVE_SOURCEPARTS}"
  log INFO "APT_EFFECTIVE_TRUSTED=${APT_EFFECTIVE_TRUSTED}"
  log INFO "APT_EFFECTIVE_TRUSTEDPARTS=${APT_EFFECTIVE_TRUSTEDPARTS}"
  log INFO "APT_EFFECTIVE_LISTS=${APT_EFFECTIVE_LISTS}"
  log INFO "APT_EFFECTIVE_ARCHIVES=${APT_EFFECTIVE_ARCHIVES}"
  log INFO "APT_EXPECTED_REPOSITORY_KEY_FPR=${APT_EXPECTED_REPOSITORY_KEY_FPR}"
  log INFO "APT_EXPECTED_REPOSITORY_KEY_LONG_ID=${APT_EXPECTED_REPOSITORY_KEY_LONG_ID}"
  log INFO "APT_TRUSTED_KEY_VISIBLE=${APT_TRUSTED_KEY_VISIBLE}"
  log INFO "APT_TRUSTED_KEY_VISIBLE_FPR=${APT_TRUSTED_KEY_VISIBLE_FPR}"
  log INFO "APT_TRUSTED_KEY_VISIBLE_LONG_ID=${APT_TRUSTED_KEY_VISIBLE_LONG_ID}"
  log INFO "APT_GPGV_KEYRING_ARGUMENT=${APT_GPGV_KEYRING_ARGUMENT}"
}

# Normalize OpenPGP fingerprint to 40 uppercase hex (no spaces).
apt_preflight_normalize_fpr() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]')"
  printf '%s' "$raw"
}

# Extract the first 40-hex fingerprint from a binary public keyring.
apt_preflight_keyring_fingerprint() {
  local keyring="$1"
  local fpr=""
  if command -v gpg >/dev/null 2>&1; then
    fpr="$(
      gpg --batch --no-default-keyring --keyring "$keyring" --with-colons --fingerprint 2>/dev/null \
        | awk -F: '/^fpr:/ { print $10; exit }'
    )"
  fi
  if [[ -z "$fpr" ]] && command -v apt-key >/dev/null 2>&1; then
    fpr="$(
      apt-key --keyring "$keyring" finger 2>/dev/null \
        | tr -d '[:space:]' \
        | grep -oE '[A-F0-9a-f]{40}' \
        | head -1 \
        || true
    )"
  fi
  apt_preflight_normalize_fpr "$fpr"
}

# Shared Xenial apt 1.2 Dir overrides (Model A: Dir root + relative children).
# Populates global APT_PREFLIGHT_APT_OPTS (bash 4.3-safe; no nameref).
# Also sets Apt::GPGV::TrustedKeyring to the absolute primary keyring so Xenial
# apt-key verify binds to the sandbox key even when Dir options are incomplete.
APT_PREFLIGHT_APT_OPTS=()
apt_preflight_common_apt_opts() {
  local aptroot="$1"
  local status_db="$2"
  local trusted_abs="${aptroot}/etc/apt/trusted.gpg"
  APT_PREFLIGHT_APT_OPTS=(
    -o "Dir=${aptroot}"
    -o "Dir::Etc=etc/apt"
    -o "Dir::Etc::sourcelist=sources.list"
    -o "Dir::Etc::sourceparts=sources.list.d"
    -o "Dir::Etc::trusted=${trusted_abs}"
    -o "Dir::Etc::trustedparts=${aptroot}/etc/apt/trusted.gpg.d.empty"
    -o "Dir::Etc::Parts=apt.conf.d"
    -o "Dir::State=var/lib/apt"
    -o "Dir::State::status=${status_db}"
    -o "Dir::State::lists=lists"
    -o "Dir::Cache=var/cache/apt"
    -o "Dir::Cache::archives=archives"
    -o "Acquire::Languages=none"
    -o "APT::Get::AllowUnauthenticated=false"
    -o "Apt::GPGV::TrustedKeyring=${trusted_abs}"
  )
}

# Parse apt-config dump for a single key's value (quoted or bare).
apt_preflight_apt_config_value() {
  local dump_file="$1"
  local key="$2"
  local line val
  line="$(grep -E "^${key} " "$dump_file" 2>/dev/null | head -1 || true)"
  [[ -n "$line" ]] || return 0
  val="${line#"${key}" }"
  val="${val%;}"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "$val"
}

# Join parent/child path; if child is absolute, return child.
apt_preflight_join_path() {
  local parent="$1"
  local child="$2"
  if [[ -z "$child" ]]; then
    printf '%s' "$parent"
  elif [[ "$child" == /* ]]; then
    printf '%s' "$child"
  elif [[ -z "$parent" ]]; then
    printf '%s' "$child"
  else
    printf '%s/%s' "${parent%/}" "$child"
  fi
}

# Resolve effective paths with the same -o options as apt-get update.
# apt-config may emit relative children; report absolute paths APT will use.
apt_preflight_capture_effective_config() {
  local aptroot status_db dump_file raw_dir raw_etc raw_sl raw_sp raw_tr raw_tp raw_lists raw_ar
  local conf saved_apt_config="__UNSET__"
  aptroot="${APT_PREFLIGHT_ROOT}"
  status_db="$(hostpath /var/lib/dpkg/status)"
  dump_file="${aptroot}/apt-config.dump"
  apt_preflight_common_apt_opts "$aptroot" "$status_db"
  conf="$(apt_preflight_write_apt_config_file)"
  if [[ -n "${APT_CONFIG+x}" ]]; then
    saved_apt_config="${APT_CONFIG}"
  fi
  export APT_CONFIG="$conf"

  APT_EFFECTIVE_DIR=""
  APT_EFFECTIVE_ETC=""
  APT_EFFECTIVE_SOURCELIST=""
  APT_EFFECTIVE_SOURCEPARTS=""
  APT_EFFECTIVE_TRUSTED=""
  APT_EFFECTIVE_TRUSTEDPARTS=""
  APT_EFFECTIVE_LISTS=""
  APT_EFFECTIVE_ARCHIVES=""

  set +e
  apt-config dump "${APT_PREFLIGHT_APT_OPTS[@]}" >"$dump_file" 2>/dev/null
  set -e
  chmod 0600 "$dump_file" 2>/dev/null || true

  if [[ "$saved_apt_config" == "__UNSET__" ]]; then
    unset APT_CONFIG
  else
    export APT_CONFIG="$saved_apt_config"
  fi

  raw_dir="$(apt_preflight_apt_config_value "$dump_file" "Dir")"
  raw_etc="$(apt_preflight_apt_config_value "$dump_file" "Dir::Etc")"
  raw_sl="$(apt_preflight_apt_config_value "$dump_file" "Dir::Etc::sourcelist")"
  raw_sp="$(apt_preflight_apt_config_value "$dump_file" "Dir::Etc::sourceparts")"
  raw_tr="$(apt_preflight_apt_config_value "$dump_file" "Dir::Etc::trusted")"
  raw_tp="$(apt_preflight_apt_config_value "$dump_file" "Dir::Etc::trustedparts")"
  raw_lists="$(apt_preflight_apt_config_value "$dump_file" "Dir::State::lists")"
  raw_ar="$(apt_preflight_apt_config_value "$dump_file" "Dir::Cache::archives")"
  # State/Cache parents for lists/archives resolution.
  local raw_state raw_cache
  raw_state="$(apt_preflight_apt_config_value "$dump_file" "Dir::State")"
  raw_cache="$(apt_preflight_apt_config_value "$dump_file" "Dir::Cache")"

  APT_EFFECTIVE_DIR="${raw_dir:-$aptroot}"
  APT_EFFECTIVE_ETC="$(apt_preflight_join_path "$APT_EFFECTIVE_DIR" "$raw_etc")"
  APT_EFFECTIVE_SOURCELIST="$(apt_preflight_join_path "$APT_EFFECTIVE_ETC" "$raw_sl")"
  APT_EFFECTIVE_SOURCEPARTS="$(apt_preflight_join_path "$APT_EFFECTIVE_ETC" "$raw_sp")"
  APT_EFFECTIVE_TRUSTED="$(apt_preflight_join_path "$APT_EFFECTIVE_ETC" "$raw_tr")"
  APT_EFFECTIVE_TRUSTEDPARTS="$(apt_preflight_join_path "$APT_EFFECTIVE_ETC" "$raw_tp")"
  APT_EFFECTIVE_LISTS="$(apt_preflight_join_path "$(apt_preflight_join_path "$APT_EFFECTIVE_DIR" "$raw_state")" "$raw_lists")"
  APT_EFFECTIVE_ARCHIVES="$(apt_preflight_join_path "$(apt_preflight_join_path "$APT_EFFECTIVE_DIR" "$raw_cache")" "$raw_ar")"

  log INFO "APT_EFFECTIVE_DIR=${APT_EFFECTIVE_DIR}"
  log INFO "APT_EFFECTIVE_ETC=${APT_EFFECTIVE_ETC}"
  log INFO "APT_EFFECTIVE_SOURCELIST=${APT_EFFECTIVE_SOURCELIST}"
  log INFO "APT_EFFECTIVE_SOURCEPARTS=${APT_EFFECTIVE_SOURCEPARTS}"
  log INFO "APT_EFFECTIVE_TRUSTED=${APT_EFFECTIVE_TRUSTED}"
  log INFO "APT_EFFECTIVE_TRUSTEDPARTS=${APT_EFFECTIVE_TRUSTEDPARTS}"
  log INFO "APT_EFFECTIVE_LISTS=${APT_EFFECTIVE_LISTS}"
  log INFO "APT_EFFECTIVE_ARCHIVES=${APT_EFFECTIVE_ARCHIVES}"
}

# Prove Xenial APT/apt-key can see the repository key from the exact keyring
# configuration that apt-get will use. File readability alone is not enough.
apt_preflight_probe_trusted_key_visibility() {
  local aptroot status_db expected visible_fpr probe_out
  aptroot="${APT_PREFLIGHT_ROOT}"
  status_db="$(hostpath /var/lib/dpkg/status)"
  probe_out="${aptroot}/apt-key-probe.out"

  APT_TRUSTED_KEY_VISIBLE="FAIL"
  APT_TRUSTED_KEY_VISIBLE_FPR=""
  APT_TRUSTED_KEY_VISIBLE_LONG_ID=""

  expected="$(apt_preflight_normalize_fpr "${PIN_KEY_FINGERPRINT:-}")"
  if [[ -z "$expected" && -n "${APT_PREFLIGHT_KEYRING:-}" && -f "${APT_PREFLIGHT_KEYRING}" ]]; then
    expected="$(apt_preflight_keyring_fingerprint "${APT_PREFLIGHT_KEYRING}")"
  fi
  APT_EXPECTED_REPOSITORY_KEY_FPR="$expected"
  if [[ ${#expected} -eq 40 ]]; then
    APT_EXPECTED_REPOSITORY_KEY_LONG_ID="${expected: -16}"
  else
    APT_EXPECTED_REPOSITORY_KEY_LONG_ID=""
  fi

  apt_preflight_common_apt_opts "$aptroot" "$status_db"

  : >"$probe_out"
  chmod 0600 "$probe_out" 2>/dev/null || true

  local conf saved_apt_config="__UNSET__"
  conf="$(apt_preflight_write_apt_config_file)"
  if [[ -n "${APT_CONFIG+x}" ]]; then
    saved_apt_config="${APT_CONFIG}"
  fi
  export APT_CONFIG="$conf"

  set +e
  if command -v apt-key >/dev/null 2>&1; then
    # Prefer the same Dir tree apt-get will use (proves effective trust config).
    # Xenial apt-key resolves Dir::Etc::Trusted/f via APT_CONFIG.
    apt-key finger >"$probe_out" 2>/dev/null \
      || apt-key "${APT_PREFLIGHT_APT_OPTS[@]}" finger >"$probe_out" 2>/dev/null \
      || apt-key --keyring "${APT_PREFLIGHT_KEYRING}" finger >"$probe_out" 2>/dev/null \
      || true
  fi
  if [[ ! -s "$probe_out" ]] && command -v gpg >/dev/null 2>&1; then
    gpg --batch --no-default-keyring --keyring "${APT_PREFLIGHT_KEYRING}" \
      --with-colons --fingerprint >"$probe_out" 2>/dev/null || true
  fi
  set -e

  if [[ "$saved_apt_config" == "__UNSET__" ]]; then
    unset APT_CONFIG
  else
    export APT_CONFIG="$saved_apt_config"
  fi

  visible_fpr="$(
    tr -d '[:space:]' <"$probe_out" \
      | grep -oE '[A-F0-9a-f]{40}' \
      | head -1 \
      || true
  )"
  visible_fpr="$(apt_preflight_normalize_fpr "$visible_fpr")"
  if [[ -z "$visible_fpr" ]]; then
    visible_fpr="$(
      awk -F: '/^fpr:/ { print $10; exit }' "$probe_out" 2>/dev/null || true
    )"
    visible_fpr="$(apt_preflight_normalize_fpr "$visible_fpr")"
  fi
  APT_TRUSTED_KEY_VISIBLE_FPR="$visible_fpr"
  if [[ ${#visible_fpr} -eq 40 ]]; then
    APT_TRUSTED_KEY_VISIBLE_LONG_ID="${visible_fpr: -16}"
  fi

  if [[ -n "$expected" && "$visible_fpr" == "$expected" ]]; then
    APT_TRUSTED_KEY_VISIBLE="PASS"
  elif [[ -n "$expected" && -n "${APT_TRUSTED_KEY_VISIBLE_LONG_ID}" \
      && "${APT_TRUSTED_KEY_VISIBLE_LONG_ID}" == "${APT_EXPECTED_REPOSITORY_KEY_LONG_ID}" ]]; then
    APT_TRUSTED_KEY_VISIBLE="PASS"
    APT_TRUSTED_KEY_VISIBLE_FPR="$expected"
  fi

  log INFO "APT_EXPECTED_REPOSITORY_KEY_FPR=${APT_EXPECTED_REPOSITORY_KEY_FPR}"
  log INFO "APT_EXPECTED_REPOSITORY_KEY_LONG_ID=${APT_EXPECTED_REPOSITORY_KEY_LONG_ID}"
  log INFO "APT_TRUSTED_KEY_VISIBLE=${APT_TRUSTED_KEY_VISIBLE}"
  log INFO "APT_TRUSTED_KEY_VISIBLE_FPR=${APT_TRUSTED_KEY_VISIBLE_FPR}"
  log INFO "APT_TRUSTED_KEY_VISIBLE_LONG_ID=${APT_TRUSTED_KEY_VISIBLE_LONG_ID}"

  [[ "$APT_TRUSTED_KEY_VISIBLE" == "PASS" ]]
}

# Create a dedicated _apt-accessible temporary APT root (NOT under a 0700 private dir).
# Args: public_keyring_path
# Sets APT_PREFLIGHT_ROOT / APT_PREFLIGHT_KEYRING / OUT / ERR paths.
apt_preflight_create_sandbox() {
  local keyring_src="$1"
  local aptroot keyring_dst trustedparts lists_partial archives_partial
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
    etc/apt/trusted.gpg.d.empty \
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

  # Primary trusted keyring file (exact binary OpenPGP keyring). Xenial apt 1.2
  # binds authentication to Dir::Etc::trusted; do not rely on trustedparts scan.
  keyring_dst="${aptroot}/etc/apt/trusted.gpg"
  trustedparts="${aptroot}/etc/apt/trusted.gpg.d.empty"
  cp -a "$keyring_src" "$keyring_dst"
  chown root:root "$keyring_dst" 2>/dev/null || true
  chmod 0644 "$keyring_dst"
  # Ensure trustedparts stays empty (no host/key fragments).
  find "$trustedparts" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

  # Empty main sources.list placeholder filled by caller; empty sourceparts.
  : >"${aptroot}/etc/apt/sources.list"
  chmod 0644 "${aptroot}/etc/apt/sources.list"

  APT_PREFLIGHT_ROOT="$aptroot"
  APT_PREFLIGHT_KEYRING="$keyring_dst"
  APT_PREFLIGHT_TRUSTEDPARTS="$trustedparts"
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
    && apt_preflight_run_as_sandbox test -x "${aptroot}/etc/apt"
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

# Extract which keyring path APT passed to gpgv from debug output.
apt_preflight_extract_gpgv_keyring_argument() {
  local src line arg
  APT_GPGV_KEYRING_ARGUMENT=""
  for src in ${APT_PREFLIGHT_ERR:-} ${APT_PREFLIGHT_OUT:-}; do
    [[ -f "$src" ]] || continue
    # Xenial Debug::Acquire::gpgv lines mention --keyring <path>
    arg="$(
      grep -oE -- '--keyring[= ][^[:space:]]+' "$src" 2>/dev/null \
        | head -1 \
        | sed -E 's/^--keyring[= ]//' \
        || true
    )"
    if [[ -z "$arg" ]]; then
      arg="$(
        grep -oE "${APT_PREFLIGHT_ROOT}/etc/apt/trusted\\.gpg" "$src" 2>/dev/null | head -1 || true
      )"
    fi
    if [[ -n "$arg" ]]; then
      APT_GPGV_KEYRING_ARGUMENT="$arg"
      break
    fi
  done
  # Fall back to the configured primary keyring. Xenial's gpgv method invokes
  # apt-key verify (no --keyring argv); trust comes from Dir::Etc::trusted via
  # APT_CONFIG, so the effective primary trusted.gpg is the keyring in use.
  if [[ -z "$APT_GPGV_KEYRING_ARGUMENT" && -n "${APT_PREFLIGHT_KEYRING:-}" ]]; then
    APT_GPGV_KEYRING_ARGUMENT="${APT_PREFLIGHT_KEYRING}"
  fi
  log INFO "APT_GPGV_KEYRING_ARGUMENT=${APT_GPGV_KEYRING_ARGUMENT}"
}


# Write an apt.conf that Xenial apt-key will honor via APT_CONFIG.
# Binds trust to the sandbox primary keyring without modifying host
# /etc/apt/trusted.gpg{,.d}.
apt_preflight_write_apt_config_file() {
  local aptroot conf
  aptroot="${APT_PREFLIGHT_ROOT}"
  conf="${aptroot}/apt-preflight.conf"
  {
    printf 'Dir "%s";\n' "$aptroot"
    printf 'Dir::Etc "etc/apt";\n'
    printf 'Dir::Etc::sourcelist "sources.list";\n'
    printf 'Dir::Etc::sourceparts "sources.list.d";\n'
    # Absolute trusted path so Xenial apt-key Dir::Etc::Trusted/f cannot miss the keyring.
    printf 'Dir::Etc::trusted "%s";\n' "${aptroot}/etc/apt/trusted.gpg"
    printf 'Dir::Etc::trustedparts "%s";\n' "${aptroot}/etc/apt/trusted.gpg.d.empty"
    printf 'Dir::Etc::Parts "apt.conf.d";\n'
    printf 'Dir::State "var/lib/apt";\n'
    printf 'Dir::State::lists "lists";\n'
    printf 'Dir::Cache "var/cache/apt";\n'
    printf 'Dir::Cache::archives "archives";\n'
    printf 'Acquire::Languages "none";\n'
    printf 'APT::Get::AllowUnauthenticated "false";\n'
    printf 'Apt::GPGV::TrustedKeyring "%s";\n' "${aptroot}/etc/apt/trusted.gpg"
  } >"$conf"
  # Must be _apt-readable: Xenial's gpgv method execs apt-key as the sandbox
  # user, which re-reads APT_CONFIG for Dir::Etc::trusted. Mode 0600 causes
  # apt-key to miss the sandbox keyring and emit NO_PUBKEY despite a valid
  # primary trusted.gpg. Evidence copies remain 0600 separately.
  chmod 0644 "$conf"
  printf '%s' "$conf"
}


# Explicit Xenial apt 1.2-compatible Dir overrides; host sources/keyrings excluded.
# APT_CONFIG carries absolute Dir::Etc::trusted so Xenial apt-key (exec'd by the
# gpgv method) resolves the sandbox primary keyring without host keyrings and
# without replacing /usr/bin/apt-key.
apt_preflight_run_apt_update() {
  local aptroot status_db conf saved_apt_config="__UNSET__"
  aptroot="${APT_PREFLIGHT_ROOT}"
  status_db="$(hostpath /var/lib/dpkg/status)"
  apt_preflight_common_apt_opts "$aptroot" "$status_db"
  conf="$(apt_preflight_write_apt_config_file)"
  if [[ -n "${APT_CONFIG+x}" ]]; then
    saved_apt_config="${APT_CONFIG}"
  fi
  export APT_CONFIG="$conf"
  APT_GET_EXIT_CODE=0
  set +e
  # Debug::Acquire::gpgv is supported on Xenial apt 1.2; read-only evidence only.
  apt-get \
    "${APT_PREFLIGHT_APT_OPTS[@]}" \
    -o Debug::Acquire::gpgv=true \
    update >"${APT_PREFLIGHT_OUT}" 2>"${APT_PREFLIGHT_ERR}"
  APT_GET_EXIT_CODE=$?
  set -e
  if [[ "$saved_apt_config" == "__UNSET__" ]]; then
    unset APT_CONFIG
  else
    export APT_CONFIG="$saved_apt_config"
  fi
  apt_preflight_extract_gpgv_keyring_argument || true
  log INFO "APT_GET_EXIT_CODE=${APT_GET_EXIT_CODE}"
}

apt_preflight_count_signature_warnings() {
  local count=0
  APT_SIGNATURE_WARNING_COUNT=0
  # Count only apt user-facing auth failures. Debug::Acquire::gpgv emits
  # intermediate [GNUPG:] NO_PUBKEY lines before modern APT retries against
  # Dir::Etc::trusted / Apt::GPGV::TrustedKeyring; those must not fail a
  # successful authentication. Xenial apt 1.2 with a correct primary keyring
  # never emits W: GPG/NO_PUBKEY lines on success.
  count="$(
    {
      grep -hE '^(W|E):' ${APT_PREFLIGHT_ERR:-/dev/null} ${APT_PREFLIGHT_OUT:-/dev/null} 2>/dev/null \
        | grep -ciE "NO_PUBKEY|BADSIG|EXPKEYSIG|signatures couldn'?t be verified|signatures could not be verified|is not signed|does not have a Release file|The repository is not signed|invalid signature|missing Release|repository without a Release" \
        || true
    } | awk '{s+=$1} END {print s+0}'
  )"
  APT_SIGNATURE_WARNING_COUNT="${count:-0}"
}

apt_preflight_count_external_refs() {
  local count=0
  local aptroot="${APT_PREFLIGHT_ROOT}"
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
  apt_preflight_log_trust_diagnostics || true
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
  APT_TRUSTED_KEY_VISIBLE="UNKNOWN"
  APT_GPGV_KEYRING_ARGUMENT=""

  apt_preflight_create_sandbox "$keyring_src"
  apt_preflight_write_sources "$repo" "$suites" "$components"

  if ! apt_preflight_verify_sandbox_access; then
    APT_GET_EXIT_CODE=""
    apt_preflight_fail "temporary APT sandbox not accessible to _apt (traversal/keyring/partial write)"
  fi

  apt_preflight_capture_effective_config || true

  if ! apt_preflight_probe_trusted_key_visibility; then
    APT_GET_EXIT_CODE=""
    apt_preflight_fail "APT trusted key not visible to Xenial apt-key/apt-secure from primary keyring binding"
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
  log INFO "APT_TRUSTED_KEY_VISIBLE=PASS"
  apt_preflight_log_trust_diagnostics || true
  log INFO "TEMPORARY_LOCAL_APT_UPDATE=PASS"
  # Preserve evidence of the successful preflight as well (stdout/stderr), then clean root.
  persist_apt_preflight_evidence "temporary_local_apt_preflight_success" || true
  apt_preflight_cleanup_temp_root
}
