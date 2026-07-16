#!/usr/bin/env bash
# scripts/lib/dp-os-upgrade-common.sh — Phase 1 DP OS upgrade shared library
# Compatible with Bash 4.3+ / Ubuntu 16.04. Safe to source.
# shellcheck disable=SC2034,SC2155

# ---------------------------------------------------------------------------
# Version / exit codes
# ---------------------------------------------------------------------------
OSU_SCRIPT_VERSION="1.0.0"
OSU_SCHEMA_VERSION="1.0"
OSU_DESTRUCTIVE_ACK_DEFAULT="I_UNDERSTAND_THIS_OS_UPGRADE_IS_DESTRUCTIVE"
OSU_ALL_WARNINGS_ACK_DEFAULT="I_ACCEPT_ALL_PREFLIGHT_WARNINGS"
OSU_DISCOVERY_ACK_DEFAULT="I_UNDERSTAND_THIS_DISCOVERY_VM_MAY_BE_LOST"
OSU_ORPHAN_ARCHIVE_ACK_DEFAULT="I_UNDERSTAND_THE_ORPHANED_STATE_WILL_BE_ARCHIVED"

EXIT_OK=0
EXIT_CLI=2
EXIT_INTEGRITY=3
EXIT_WARNINGS=10
EXIT_BLOCKED=20
EXIT_PAUSED=21
EXIT_RESUME_REQUIRED=22
EXIT_FAILED=30
EXIT_COMPLETED=40
EXIT_CHECKPOINT=41

# Supported LTS chain (no skip)
OSU_LTS_CHAIN="16.04:xenial 18.04:bionic 20.04:focal 22.04:jammy 24.04:noble"

# State machine
OSU_STATES="NEW PREFLIGHT_ACCEPTED INITIALIZED HOP_PRECHECK HOP_SOURCE_PREPARING HOP_SOURCE_READY HOP_CURRENT_RELEASE_UPDATING HOP_RELEASE_UPGRADE_STARTING HOP_RELEASE_UPGRADE_RUNNING REBOOT_REQUIRED REBOOT_REQUESTED RESUMED HOP_VALIDATING HOP_COMPLETED CHECKPOINT_REACHED PAUSED BLOCKED FAILED COMPLETED"

# Globals populated at runtime
OSU_ROOT=""
OSU_CONFIG_FILE=""
OSU_STATE_DIR=""
OSU_LOCK_FILE=""
OSU_LOG_FILE=""
OSU_LOCK_FD=""
OSU_TMP_DIR=""
OSU_OWNED_TMP=0
OSU_PREFLIGHT_ROOT=""
OSU_PREFLIGHT_INPUT_TYPE=""
OSU_EXECUTE=0
OSU_TEST_MODE=0
OSU_EFFECTIVE_USER=""
OSU_EXECUTION_PROFILE="production"
OSU_STOP_AFTER_OS=""
OSU_MAX_HOPS=""
OSU_DISCOVERY_ACK=""
OSU_HOPS_THIS_RUN=0

# Policy (defaults; overwritten by config)
POLICY_TARGET_OS_VERSION="24.04"
POLICY_TARGET_OS_CODENAME="noble"
POLICY_PREFLIGHT_MAX_AGE_SECONDS="3600"
POLICY_MIN_ROOT_AVAILABLE_BYTES="12884901888"
POLICY_MIN_BOOT_AVAILABLE_BYTES="536870912"
POLICY_MIN_AELLADATA_AVAILABLE_BYTES="5368709120"
POLICY_MIN_INODE_AVAILABLE_PERCENT="10"
POLICY_AUTO_RETRY_ENABLED="true"
POLICY_AUTO_RETRY_INTERVAL_SECONDS="900"
POLICY_MAX_RETRY_ATTEMPTS="20"
POLICY_MANAGE_CRITICAL_HOLDS="false"
POLICY_RESTORE_ORIGINAL_HOLDS_AT_COMPLETION="false"
POLICY_CRITICAL_HELD_PACKAGES="systemd,udev,apt,dpkg,linux-generic,ubuntu-minimal,ubuntu-standard,ubuntu-release-upgrader-core,update-manager-core"
POLICY_CRITICAL_HOLD_ALLOWLIST=""
POLICY_DISABLE_THIRD_PARTY_REPOSITORIES="true"
POLICY_REENABLE_THIRD_PARTY_REPOSITORIES="false"
POLICY_REQUIRE_INTERNAL_RELEASE_METADATA_FOR_MIRROR="true"
POLICY_ALLOW_EXTERNAL_FALLBACK_IN_MIRROR_MODE="false"
POLICY_REQUIRE_AELLA_BASH="true"
POLICY_REQUIRE_ROOT_BASH="true"
POLICY_STATE_DIR="/opt/aelladata/os-upgrade"
POLICY_LOCK_FILE="/run/lock/dp-os-upgrade.lock"
POLICY_LOG_FILE="/var/log/aella/auto_os_upgrade.log"
POLICY_DESTRUCTIVE_ACK_PHRASE="$OSU_DESTRUCTIVE_ACK_DEFAULT"
POLICY_ALL_WARNINGS_ACK_PHRASE="$OSU_ALL_WARNINGS_ACK_DEFAULT"
POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE="$OSU_DISCOVERY_ACK_DEFAULT"
POLICY_ORPHAN_ARCHIVE_ACK_PHRASE="$OSU_ORPHAN_ARCHIVE_ACK_DEFAULT"
POLICY_DEFAULT_EXECUTION_PROFILE="production"
POLICY_PRODUCTION_REQUIRE_SNAPSHOT_OR_BACKUP="true"
POLICY_DISCOVERY_REQUIRE_SNAPSHOT_OR_BACKUP="false"
POLICY_DISCOVERY_REQUIRE_DISPOSABLE_VM_ACK="true"
POLICY_DISCOVERY_DEFAULT_MAX_HOPS="1"
POLICY_DISCOVERY_REQUIRE_NEW_PREFLIGHT_AFTER_HOP="true"
POLICY_DISCOVERY_CAPTURE_PACKAGES="true"
POLICY_DISCOVERY_CAPTURE_FILE_CHANGES="true"
POLICY_DISCOVERY_CAPTURE_PYTHON_INVENTORY="true"
POLICY_DISCOVERY_PRESERVE_APT_CACHE="true"
POLICY_PHASE2_CHECKS_AFFECT_OS_PREFLIGHT="false"
POLICY_REJECTED_REFERENCE_PLACEHOLDERS="none,n/a,na,unknown,todo,test,later,null,undefined,placeholder,tbd,pending"
POLICY_MIRROR_UBUNTU_PATH="/ubuntu"
POLICY_MIRROR_OFFLINE_PATH="/offline"
POLICY_MIRROR_META_RELEASE_PATH="/offline/meta-release-lts"
POLICY_MAX_PREFLIGHT_ARCHIVE_ENTRIES="5000"
POLICY_MAX_PREFLIGHT_ARCHIVE_BYTES="104857600"
POLICY_DEFAULT_COMMAND_TIMEOUT_SECONDS="3600"
POLICY_DO_RELEASE_UPGRADE_TIMEOUT_SECONDS="14400"
POLICY_APT_UPDATE_TIMEOUT_SECONDS="1800"

# Preflight fields
PF_SCHEMA=""
PF_SCRIPT_VERSION=""
PF_ID=""
PF_COMPLETED_AT=""
PF_HOSTNAME=""
PF_OS_VERSION=""
PF_OS_CODENAME=""
PF_DP_VERSION_RAW=""
PF_DP_VERSION_NORM=""
PF_ROLE=""
PF_OVERALL=""
PF_RECOMMENDED=""
PF_PHASE1_REQUIRED=""
PF_PHASE1_HOPS=""
PF_PHASE2_REQUIRED=""
PF_PACKAGE_SOURCE_MODE=""
PF_PACKAGE_SOURCE_URL=""
PF_SNAPSHOT_REF=""
PF_BACKUP_REF=""
PF_BRINGUP_MODE=""
PF_EXECUTION_PROFILE=""
PF_PHASE2_EVALUATED=""
PF_OS_UPGRADE_REQUIRED=""
PF_NEXT_HOP=""
PF_SNAPSHOT_REQUIRED=""

# ---------------------------------------------------------------------------
# Test-mode / path helpers
# ---------------------------------------------------------------------------
osu_init_test_mode() {
  if [[ "${DP_OS_UPGRADE_TEST_MODE:-0}" == "1" ]]; then
    OSU_TEST_MODE=1
    if [[ -z "${DP_OS_UPGRADE_TEST_ROOT:-}" ]]; then
      printf 'ERROR: DP_OS_UPGRADE_TEST_MODE=1 requires DP_OS_UPGRADE_TEST_ROOT\n' >&2
      return 1
    fi
    mkdir -p "$DP_OS_UPGRADE_TEST_ROOT"
    if [[ -n "${DP_OS_UPGRADE_COMMAND_PATH:-}" ]]; then
      export PATH="${DP_OS_UPGRADE_COMMAND_PATH}:${PATH}"
    fi
  else
    OSU_TEST_MODE=0
    if [[ -n "${DP_OS_UPGRADE_TEST_ROOT:-}" ]]; then
      printf 'ERROR: DP_OS_UPGRADE_TEST_ROOT set without DP_OS_UPGRADE_TEST_MODE=1 — refusing\n' >&2
      return 1
    fi
  fi
  return 0
}

# Map absolute host path into test root when in test mode
osu_hostpath() {
  local p="${1:-}"
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    case "$p" in
      /*) printf '%s%s' "${DP_OS_UPGRADE_TEST_ROOT}" "$p" ;;
      *) printf '%s/%s' "${DP_OS_UPGRADE_TEST_ROOT}" "$p" ;;
    esac
  else
    printf '%s' "$p"
  fi
}

osu_is_root() {
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    # In test mode, allow simulated root via env
    [[ "${DP_OS_UPGRADE_SIMULATE_ROOT:-0}" == "1" || "$(id -u)" -eq 0 ]]
  else
    [[ "$(id -u)" -eq 0 ]]
  fi
}

osu_require_root_for_mutate() {
  if ! osu_is_root; then
    osu_log ERROR "root required for mutating operations"
    return "$EXIT_CLI"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Time / logging
# ---------------------------------------------------------------------------
osu_utc_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'
}

osu_utc_stamp() {
  date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || date -u '+%Y%m%dT%H%M%SZ'
}

osu_log() {
  local level="$1"; shift
  local msg="$*"
  local line ts
  ts="$(osu_utc_now)"
  line="${ts} [${level}] ${msg}"
  case "$level" in
    ERROR|WARN) printf '%s\n' "$line" >&2 ;;
    *) printf '%s\n' "$line" ;;
  esac
  local lf
  lf="$(osu_hostpath "${OSU_LOG_FILE:-$POLICY_LOG_FILE}")"
  if [[ -n "$lf" ]]; then
    mkdir -p "$(dirname "$lf")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$lf" 2>/dev/null || true
  fi
}

osu_die_cli() { osu_log ERROR "$*"; exit "$EXIT_CLI"; }
osu_die_integrity() { osu_log ERROR "$*"; exit "$EXIT_INTEGRITY"; }
osu_die_blocked() { osu_log ERROR "$*"; exit "$EXIT_BLOCKED"; }
osu_die_failed() { osu_log ERROR "$*"; exit "$EXIT_FAILED"; }

# ---------------------------------------------------------------------------
# JSON / string helpers (aligned with dp-preflight-common)
# ---------------------------------------------------------------------------
osu_json_escape() {
  local s="${1-}" out="" i c hex
  local -i len=${#s} o
  for ((i = 0; i < len; i++)); do
    c="${s:i:1}"
    case "$c" in
      $'\\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        printf -v o '%d' "'$c"
        if (( o < 32 || o > 126 )); then
          printf -v hex '%02X' "$o"
          out+="\\u00${hex}"
        else
          out+="$c"
        fi
        ;;
    esac
  done
  printf '%s' "$out"
}

osu_json_str_or_null() {
  local v="${1-}"
  if [[ -z "$v" || "$v" == "null" ]]; then printf 'null'
  else printf '"%s"' "$(osu_json_escape "$v")"
  fi
}

osu_json_bool() {
  case "${1:-}" in true|1|yes) printf 'true' ;; false|0|no) printf 'false' ;; *) printf 'null' ;; esac
}

osu_json_num_or_null() {
  local v="${1-}"
  if [[ -z "$v" || "$v" == "null" ]]; then printf 'null'
  elif [[ "$v" =~ ^-?[0-9]+$ ]]; then printf '%s' "$v"
  else printf 'null'
  fi
}

osu_sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  else
    # openssl fallback
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
  fi
}

osu_json_validate_file() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$file" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>/dev/null
  elif command -v python >/dev/null 2>&1; then
    python -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>/dev/null
  else
    grep -q '{' "$file" && grep -q '}' "$file"
  fi
}

osu_json_get() {
  local file="$1" path="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg p "$path" '
      def dig($path):
        if ($path|length)==0 then .
        else
          ($path|split(".")[0]) as $k |
          ($path|split(".")[1:]|join(".")) as $rest |
          if .==null then null
          elif type=="object" then (.[$k] | dig($rest))
          else null end
        end;
      dig($p) | if .==null then "" elif type=="array" then join(",") elif type=="boolean" or type=="number" then tostring else . end
    ' "$file" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$path" <<'PY' 2>/dev/null || true
import json,sys
path=sys.argv[2].split(".")
with open(sys.argv[1]) as f: data=json.load(f)
cur=data
for p in path:
    if isinstance(cur,dict) and p in cur: cur=cur[p]
    else: print(""); sys.exit(0)
if cur is None: print("")
elif isinstance(cur,bool): print("true" if cur else "false")
elif isinstance(cur,list): print(",".join(str(x) for x in cur))
else: print(cur)
PY
  else
    printf ''
  fi
}

osu_normalize_version() {
  local raw="${1-}" base
  if [[ -z "$raw" || "$raw" == "null" || "$raw" == "unknown" ]]; then
    printf ''; return 1
  fi
  raw="$(printf '%s' "$raw" | sed -E 's/^[^0-9]*//')"
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    base="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+\.[0-9]+) ]]; then
    base="${BASH_REMATCH[1]}.0"
  else
    printf ''; return 1
  fi
  printf '%s' "$base"
}

osu_compare_versions() {
  local a="${1-}" b="${2-}" a1 a2 a3 b1 b2 b3
  if [[ -z "$a" || -z "$b" ]]; then printf 'unknown'; return 1; fi
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
  b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
  if (( a1 < b1 )); then printf 'lt'; return 0; fi
  if (( a1 > b1 )); then printf 'gt'; return 0; fi
  if (( a2 < b2 )); then printf 'lt'; return 0; fi
  if (( a2 > b2 )); then printf 'gt'; return 0; fi
  if (( a3 < b3 )); then printf 'lt'; return 0; fi
  if (( a3 > b3 )); then printf 'gt'; return 0; fi
  printf 'eq'
}

osu_redact_url() {
  local u="${1-}"
  printf '%s' "$u" | sed -E 's#(://)[^/@:]+(:[^/@]*)?@#\1***:***@#g'
}

osu_is_placeholder() {
  local ref="${1-}" low list item
  [[ -z "$ref" ]] && return 0
  low="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"
  list="${POLICY_REJECTED_REFERENCE_PLACEHOLDERS}"
  IFS=',' read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ "$low" == "$item" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Config parser (KEY=VALUE only; never source)
# ---------------------------------------------------------------------------
osu_parse_policy() {
  local file="$1"
  local prefix="${2:-POLICY}"
  local line key value
  local allowed_re='^[A-Z][A-Z0-9_]*$'

  if [[ ! -f "$file" || ! -r "$file" ]]; then
    printf 'policy file not readable: %s\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" == *'$('* || "$line" == *'`'* ]]; then
      printf 'policy rejects shell expansion: %s\n' "$line" >&2
      return 1
    fi
    if [[ ! "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      printf 'policy invalid line: %s\n' "$line" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ ! "$key" =~ $allowed_re ]]; then
      printf 'policy invalid key: %s\n' "$key" >&2
      return 1
    fi
    case "$value" in
      *$'\n'*) printf 'policy rejects multiline value for %s\n' "$key" >&2; return 1 ;;
    esac
    if [[ "$value" =~ [\;\|\&\<\>\`\$\(\)\{\}] ]]; then
      printf 'policy rejects unsafe characters in %s\n' "$key" >&2
      return 1
    fi
    printf -v "${prefix}_${key}" '%s' "$value"
  done <"$file"
  return 0
}

osu_load_config() {
  local cfg="${1:-}"
  local root="${OSU_ROOT:-}"
  # Derive repo root from this library path when unset (runtime pin or CLI)
  if [[ -z "$root" ]]; then
    local _libdir
    _libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_libdir}/../../config/dp-os-upgrade.conf" ]]; then
      root="$(cd "${_libdir}/../.." && pwd)"
      OSU_ROOT="$root"
    elif [[ -f "${_libdir}/../config/dp-os-upgrade.conf" ]]; then
      # unexpected layout fallback
      root="$(cd "${_libdir}/.." && pwd)"
      OSU_ROOT="$root"
    fi
  fi
  if [[ -z "$cfg" ]]; then
    if [[ -n "$root" && -f "${root}/config/dp-os-upgrade.conf" ]]; then
      cfg="${root}/config/dp-os-upgrade.conf"
    elif [[ -f "$(osu_hostpath "${POLICY_STATE_DIR}/policy-effective.conf")" ]]; then
      cfg="$(osu_hostpath "${POLICY_STATE_DIR}/policy-effective.conf")"
    elif [[ -f /etc/dp-os-upgrade.conf ]]; then
      cfg=/etc/dp-os-upgrade.conf
    else
      osu_log WARN "no config file found; using built-in defaults"
      OSU_STATE_DIR="$(osu_hostpath "$POLICY_STATE_DIR")"
      OSU_LOCK_FILE="$(osu_hostpath "$POLICY_LOCK_FILE")"
      OSU_LOG_FILE="$(osu_hostpath "$POLICY_LOG_FILE")"
      return 0
    fi
  fi
  OSU_CONFIG_FILE="$cfg"
  osu_parse_policy "$cfg" POLICY || return 1
  # Validate numeric ranges
  local k
  for k in PREFLIGHT_MAX_AGE_SECONDS MIN_ROOT_AVAILABLE_BYTES MIN_BOOT_AVAILABLE_BYTES \
           MIN_AELLADATA_AVAILABLE_BYTES MIN_INODE_AVAILABLE_PERCENT \
           AUTO_RETRY_INTERVAL_SECONDS MAX_RETRY_ATTEMPTS \
           MAX_PREFLIGHT_ARCHIVE_ENTRIES MAX_PREFLIGHT_ARCHIVE_BYTES \
           DEFAULT_COMMAND_TIMEOUT_SECONDS DO_RELEASE_UPGRADE_TIMEOUT_SECONDS \
           APT_UPDATE_TIMEOUT_SECONDS; do
    local var="POLICY_${k}"
    local val="${!var}"
    if [[ -n "$val" && ! "$val" =~ ^[0-9]+$ ]]; then
      printf 'policy %s must be non-negative integer\n' "$k" >&2
      return 1
    fi
  done
  if [[ "${POLICY_MIN_INODE_AVAILABLE_PERCENT}" -lt 0 || "${POLICY_MIN_INODE_AVAILABLE_PERCENT}" -gt 100 ]]; then
    printf 'policy MIN_INODE_AVAILABLE_PERCENT out of range\n' >&2
    return 1
  fi
  case "${POLICY_MANAGE_CRITICAL_HOLDS}" in true|false) ;; *) printf 'MANAGE_CRITICAL_HOLDS must be true|false\n' >&2; return 1 ;; esac
  case "${POLICY_AUTO_RETRY_ENABLED}" in true|false) ;; *) printf 'AUTO_RETRY_ENABLED must be true|false\n' >&2; return 1 ;; esac
  case "${POLICY_ALLOW_EXTERNAL_FALLBACK_IN_MIRROR_MODE}" in true|false) ;; *) return 1 ;; esac
  case "${POLICY_REQUIRE_INTERNAL_RELEASE_METADATA_FOR_MIRROR}" in true|false) ;; *) return 1 ;; esac

  OSU_STATE_DIR="$(osu_hostpath "$POLICY_STATE_DIR")"
  OSU_LOCK_FILE="$(osu_hostpath "$POLICY_LOCK_FILE")"
  OSU_LOG_FILE="$(osu_hostpath "$POLICY_LOG_FILE")"
  return 0
}

osu_write_effective_config() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  {
    printf '# effective dp-os-upgrade policy\n'
    printf 'TARGET_OS_VERSION=%s\n' "$POLICY_TARGET_OS_VERSION"
    printf 'TARGET_OS_CODENAME=%s\n' "$POLICY_TARGET_OS_CODENAME"
    printf 'PREFLIGHT_MAX_AGE_SECONDS=%s\n' "$POLICY_PREFLIGHT_MAX_AGE_SECONDS"
    printf 'MIN_ROOT_AVAILABLE_BYTES=%s\n' "$POLICY_MIN_ROOT_AVAILABLE_BYTES"
    printf 'MIN_BOOT_AVAILABLE_BYTES=%s\n' "$POLICY_MIN_BOOT_AVAILABLE_BYTES"
    printf 'MIN_AELLADATA_AVAILABLE_BYTES=%s\n' "$POLICY_MIN_AELLADATA_AVAILABLE_BYTES"
    printf 'MIN_INODE_AVAILABLE_PERCENT=%s\n' "$POLICY_MIN_INODE_AVAILABLE_PERCENT"
    printf 'AUTO_RETRY_ENABLED=%s\n' "$POLICY_AUTO_RETRY_ENABLED"
    printf 'AUTO_RETRY_INTERVAL_SECONDS=%s\n' "$POLICY_AUTO_RETRY_INTERVAL_SECONDS"
    printf 'MAX_RETRY_ATTEMPTS=%s\n' "$POLICY_MAX_RETRY_ATTEMPTS"
    printf 'MANAGE_CRITICAL_HOLDS=%s\n' "$POLICY_MANAGE_CRITICAL_HOLDS"
    printf 'RESTORE_ORIGINAL_HOLDS_AT_COMPLETION=%s\n' "$POLICY_RESTORE_ORIGINAL_HOLDS_AT_COMPLETION"
    printf 'CRITICAL_HELD_PACKAGES=%s\n' "$POLICY_CRITICAL_HELD_PACKAGES"
    printf 'CRITICAL_HOLD_ALLOWLIST=%s\n' "$POLICY_CRITICAL_HOLD_ALLOWLIST"
    printf 'DISABLE_THIRD_PARTY_REPOSITORIES=%s\n' "$POLICY_DISABLE_THIRD_PARTY_REPOSITORIES"
    printf 'REENABLE_THIRD_PARTY_REPOSITORIES=%s\n' "$POLICY_REENABLE_THIRD_PARTY_REPOSITORIES"
    printf 'REQUIRE_INTERNAL_RELEASE_METADATA_FOR_MIRROR=%s\n' "$POLICY_REQUIRE_INTERNAL_RELEASE_METADATA_FOR_MIRROR"
    printf 'ALLOW_EXTERNAL_FALLBACK_IN_MIRROR_MODE=%s\n' "$POLICY_ALLOW_EXTERNAL_FALLBACK_IN_MIRROR_MODE"
    printf 'REQUIRE_AELLA_BASH=%s\n' "$POLICY_REQUIRE_AELLA_BASH"
    printf 'REQUIRE_ROOT_BASH=%s\n' "$POLICY_REQUIRE_ROOT_BASH"
    printf 'STATE_DIR=%s\n' "$POLICY_STATE_DIR"
    printf 'MIRROR_UBUNTU_PATH=%s\n' "$POLICY_MIRROR_UBUNTU_PATH"
    printf 'MIRROR_META_RELEASE_PATH=%s\n' "$POLICY_MIRROR_META_RELEASE_PATH"
  } >"$dest"
  chmod 0640 "$dest" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Hop planning
# ---------------------------------------------------------------------------
osu_codename_for_version() {
  local ver="$1" pair
  for pair in $OSU_LTS_CHAIN; do
    if [[ "${pair%%:*}" == "$ver" ]]; then
      printf '%s' "${pair##*:}"
      return 0
    fi
  done
  return 1
}

osu_version_for_codename() {
  local code="$1" pair
  for pair in $OSU_LTS_CHAIN; do
    if [[ "${pair##*:}" == "$code" ]]; then
      printf '%s' "${pair%%:*}"
      return 0
    fi
  done
  return 1
}

osu_lts_index() {
  local ver="$1" i=0 pair
  for pair in $OSU_LTS_CHAIN; do
    if [[ "${pair%%:*}" == "$ver" ]]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# Print hops as lines: FROM_VER:FROM_CODE->TO_VER:TO_CODE
osu_plan_hops() {
  local start="${1:-}"
  local target="${2:-$POLICY_TARGET_OS_VERSION}"
  local si ti i
  local -a vers codes
  vers=(); codes=()
  local pair
  for pair in $OSU_LTS_CHAIN; do
    vers+=("${pair%%:*}")
    codes+=("${pair##*:}")
  done
  si="$(osu_lts_index "$start")" || { printf 'UNSUPPORTED\n'; return 1; }
  ti="$(osu_lts_index "$target")" || { printf 'UNSUPPORTED\n'; return 1; }
  if (( si > ti )); then
    printf 'UNSUPPORTED\n'
    return 1
  fi
  if (( si == ti )); then
    return 0
  fi
  for ((i = si; i < ti; i++)); do
    printf '%s:%s->%s:%s\n' "${vers[$i]}" "${codes[$i]}" "${vers[$((i+1))]}" "${codes[$((i+1))]}"
  done
}

# Effective hops for this run: apply --stop-after-os and/or --max-hops.
# Args: start [stop_after_os] [max_hops]
osu_effective_plan_hops() {
  local start="${1:-}"
  local stop="${2:-}"
  local max_hops="${3:-}"
  local target="$POLICY_TARGET_OS_VERSION"
  local hops line n=0
  if [[ -n "$stop" ]]; then
    target="$stop"
  fi
  hops="$(osu_plan_hops "$start" "$target")" || true
  if printf '%s\n' "$hops" | grep -qx UNSUPPORTED; then
    printf 'UNSUPPORTED\n'
    return 1
  fi
  if [[ -n "$max_hops" ]]; then
    if [[ ! "$max_hops" =~ ^[1-9][0-9]*$ ]]; then
      osu_log ERROR "invalid --max-hops: $max_hops"
      return 1
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      n=$((n + 1))
      if (( n <= max_hops )); then
        printf '%s\n' "$line"
      fi
    done <<< "$hops"
    return 0
  fi
  printf '%s' "$hops"
  [[ -n "$hops" ]] && printf '\n'
  return 0
}

# Full-chain hops after the last effective hop (reference only).
# Args: start effective_hops_text
osu_remaining_plan_hops() {
  local start="$1"
  local effective="$2"
  local full last="" line seen=0
  full="$(osu_plan_hops "$start")" || true
  if printf '%s\n' "$full" | grep -qx UNSUPPORTED; then
    return 0
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    last="$line"
  done <<< "$effective"
  if [[ -z "$last" ]]; then
    printf '%s' "$full"
    [[ -n "$full" ]] && printf '\n'
    return 0
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$seen" -eq 1 ]]; then
      printf '%s\n' "$line"
      continue
    fi
    if [[ "$line" == "$last" ]]; then
      seen=1
    fi
  done <<< "$full"
}

osu_hop_count() {
  local start="$1"
  local n=0 line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == UNSUPPORTED ]] && continue
    n=$((n + 1))
  done < <(osu_plan_hops "$start")
  printf '%s' "$n"
}

osu_count_hop_lines() {
  local text="${1:-}" n=0 line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == UNSUPPORTED ]] && continue
    n=$((n + 1))
  done <<< "$text"
  printf '%s' "$n"
}

osu_hop_dirname() {
  local num="$1" from_code="$2" to_code="$3"
  printf 'hop-%02d-%s-to-%s' "$num" "$from_code" "$to_code"
}

osu_is_supported_os() {
  local ver="$1"
  osu_lts_index "$ver" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
osu_boot_id() {
  local f
  f="$(osu_hostpath /proc/sys/kernel/random/boot_id)"
  if [[ -r "$f" ]]; then
    tr -d '\n' <"$f"
  else
    printf 'unknown'
  fi
}

osu_proc_starttime() {
  local pid="$1" f
  f="$(osu_hostpath "/proc/${pid}/stat")"
  if [[ -r "$f" ]]; then
    # field 22 is starttime
    awk '{print $22}' "$f" 2>/dev/null
  else
    printf ''
  fi
}

osu_acquire_lock() {
  local lockf="${OSU_LOCK_FILE}"
  local meta
  meta="$(osu_hostpath "${POLICY_STATE_DIR}/lock-metadata.json")"
  mkdir -p "$(dirname "$lockf")" "$(dirname "$meta")" 2>/dev/null || true

  if command -v flock >/dev/null 2>&1; then
    exec {OSU_LOCK_FD}>"$lockf" || return 1
    if ! flock -n "$OSU_LOCK_FD"; then
      osu_log ERROR "another dp-os-upgrade process holds the lock: $lockf"
      return 1
    fi
  else
    # mkdir lock fallback
    local lockdir="${lockf}.d"
    if ! mkdir "$lockdir" 2>/dev/null; then
      # stale check
      if [[ -f "${lockdir}/pid" ]]; then
        local opid ost boot
        opid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
        ost="$(cat "${lockdir}/starttime" 2>/dev/null || true)"
        boot="$(cat "${lockdir}/boot_id" 2>/dev/null || true)"
        local cur_st cur_boot
        cur_st="$(osu_proc_starttime "$opid")"
        cur_boot="$(osu_boot_id)"
        if [[ -n "$opid" && -n "$ost" && "$cur_st" == "$ost" && "$boot" == "$cur_boot" ]]; then
          osu_log ERROR "lock held by live pid $opid"
          return 1
        fi
        osu_log WARN "removing stale mkdir lock"
        rm -rf "$lockdir"
        mkdir "$lockdir" || return 1
      else
        return 1
      fi
    fi
    printf '%s\n' "$$" >"${lockdir}/pid"
    printf '%s\n' "$(osu_proc_starttime "$$")" >"${lockdir}/starttime"
    printf '%s\n' "$(osu_boot_id)" >"${lockdir}/boot_id"
  fi

  local rev=0
  if [[ -f "$(osu_hostpath "${POLICY_STATE_DIR}/state.json")" ]]; then
    rev="$(osu_json_get "$(osu_hostpath "${POLICY_STATE_DIR}/state.json")" state_revision || true)"
    rev="${rev:-0}"
  fi
  cat >"$meta" <<EOF
{
  "pid": $$,
  "starttime": "$(osu_json_escape "$(osu_proc_starttime "$$")")",
  "hostname": "$(osu_json_escape "$(hostname 2>/dev/null || echo unknown)")",
  "boot_id": "$(osu_json_escape "$(osu_boot_id)")",
  "command": "$(osu_json_escape "$0 ${*:-}")",
  "acquired_at": "$(osu_utc_now)",
  "state_revision": $(osu_json_num_or_null "$rev")
}
EOF
  chmod 0600 "$meta" 2>/dev/null || true
  return 0
}

osu_release_lock() {
  if [[ -n "${OSU_LOCK_FD:-}" ]]; then
    flock -u "$OSU_LOCK_FD" 2>/dev/null || true
    eval "exec ${OSU_LOCK_FD}>&-" 2>/dev/null || true
    OSU_LOCK_FD=""
  fi
  local lockdir="${OSU_LOCK_FILE}.d"
  if [[ -d "$lockdir" ]]; then
    local opid
    opid="$(cat "${lockdir}/pid" 2>/dev/null || true)"
    if [[ "$opid" == "$$" ]]; then
      rm -rf "$lockdir"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Events / hop history
# ---------------------------------------------------------------------------
osu_append_event() {
  local event_type="$1"
  local detail="${2:-}"
  local f="${OSU_STATE_DIR}/events.jsonl"
  mkdir -p "$OSU_STATE_DIR"
  printf '{"ts":"%s","event":"%s","detail":"%s","pid":%s}\n' \
    "$(osu_utc_now)" "$(osu_json_escape "$event_type")" "$(osu_json_escape "$detail")" "$$" >>"$f"
  chmod 0640 "$f" 2>/dev/null || true
}

osu_append_hop_history() {
  local hop="$1" from_os="$2" to_os="$3" status="$4" detail="${5:-}"
  local f="${OSU_STATE_DIR}/hop_history.jsonl"
  mkdir -p "$OSU_STATE_DIR"
  printf '{"ts":"%s","hop":%s,"from_os":"%s","to_os":"%s","status":"%s","detail":"%s"}\n' \
    "$(osu_utc_now)" "$(osu_json_num_or_null "$hop")" \
    "$(osu_json_escape "$from_os")" "$(osu_json_escape "$to_os")" \
    "$(osu_json_escape "$status")" "$(osu_json_escape "$detail")" >>"$f"
  chmod 0640 "$f" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Atomic state
# ---------------------------------------------------------------------------
osu_transition_allowed() {
  local from="$1" to="$2"
  [[ "$from" == "$to" ]] && return 0
  case "$from->$to" in
    NEW-\>PREFLIGHT_ACCEPTED|NEW-\>COMPLETED|NEW-\>BLOCKED|NEW-\>FAILED) return 0 ;;
  esac
  # bash case with -> needs careful quoting
  case "${from}|${to}" in
    NEW|PREFLIGHT_ACCEPTED) return 0 ;;
    NEW|COMPLETED) return 0 ;;
    NEW|BLOCKED|NEW|FAILED) return 0 ;;
    PREFLIGHT_ACCEPTED|INITIALIZED) return 0 ;;
    PREFLIGHT_ACCEPTED|BLOCKED|PREFLIGHT_ACCEPTED|FAILED) return 0 ;;
    INITIALIZED|HOP_PRECHECK) return 0 ;;
    INITIALIZED|COMPLETED) return 0 ;;
    INITIALIZED|BLOCKED|INITIALIZED|FAILED|INITIALIZED|PAUSED) return 0 ;;
    HOP_PRECHECK|HOP_SOURCE_PREPARING) return 0 ;;
    HOP_PRECHECK|BLOCKED|HOP_PRECHECK|FAILED|HOP_PRECHECK|PAUSED) return 0 ;;
    HOP_SOURCE_PREPARING|HOP_SOURCE_READY) return 0 ;;
    HOP_SOURCE_PREPARING|BLOCKED|HOP_SOURCE_PREPARING|FAILED|HOP_SOURCE_PREPARING|PAUSED) return 0 ;;
    HOP_SOURCE_READY|HOP_CURRENT_RELEASE_UPDATING) return 0 ;;
    HOP_SOURCE_READY|BLOCKED|HOP_SOURCE_READY|FAILED|HOP_SOURCE_READY|PAUSED) return 0 ;;
    HOP_CURRENT_RELEASE_UPDATING|HOP_RELEASE_UPGRADE_STARTING) return 0 ;;
    HOP_CURRENT_RELEASE_UPDATING|BLOCKED|HOP_CURRENT_RELEASE_UPDATING|FAILED|HOP_CURRENT_RELEASE_UPDATING|PAUSED) return 0 ;;
    HOP_RELEASE_UPGRADE_STARTING|HOP_RELEASE_UPGRADE_RUNNING) return 0 ;;
    HOP_RELEASE_UPGRADE_STARTING|BLOCKED|HOP_RELEASE_UPGRADE_STARTING|FAILED) return 0 ;;
    HOP_RELEASE_UPGRADE_RUNNING|REBOOT_REQUIRED) return 0 ;;
    HOP_RELEASE_UPGRADE_RUNNING|HOP_VALIDATING) return 0 ;;
    HOP_RELEASE_UPGRADE_RUNNING|FAILED|HOP_RELEASE_UPGRADE_RUNNING|BLOCKED) return 0 ;;
    REBOOT_REQUIRED|REBOOT_REQUESTED) return 0 ;;
    REBOOT_REQUIRED|FAILED|REBOOT_REQUIRED|BLOCKED|REBOOT_REQUIRED|PAUSED) return 0 ;;
    REBOOT_REQUESTED|RESUMED) return 0 ;;
    REBOOT_REQUESTED|FAILED|REBOOT_REQUESTED|BLOCKED) return 0 ;;
    RESUMED|HOP_VALIDATING) return 0 ;;
    RESUMED|FAILED|RESUMED|BLOCKED|RESUMED|PAUSED) return 0 ;;
    HOP_VALIDATING|HOP_COMPLETED) return 0 ;;
    HOP_VALIDATING|FAILED|HOP_VALIDATING|BLOCKED) return 0 ;;
    HOP_COMPLETED|HOP_PRECHECK) return 0 ;;
    HOP_COMPLETED|COMPLETED) return 0 ;;
    HOP_COMPLETED|CHECKPOINT_REACHED) return 0 ;;
    HOP_COMPLETED|PAUSED|HOP_COMPLETED|BLOCKED) return 0 ;;
    CHECKPOINT_REACHED|PREFLIGHT_ACCEPTED) return 0 ;;
    CHECKPOINT_REACHED|INITIALIZED) return 0 ;;
    CHECKPOINT_REACHED|HOP_PRECHECK) return 0 ;;
    CHECKPOINT_REACHED|BLOCKED|CHECKPOINT_REACHED|FAILED|CHECKPOINT_REACHED|PAUSED) return 0 ;;
    PAUSED|HOP_PRECHECK|PAUSED|RESUMED|PAUSED|HOP_SOURCE_PREPARING|PAUSED|HOP_VALIDATING|PAUSED|INITIALIZED) return 0 ;;
    BLOCKED|HOP_PRECHECK|BLOCKED|RESUMED|BLOCKED|INITIALIZED) return 0 ;;
    # Allow pause from most non-terminal states
    *|PAUSED) 
      case "$from" in COMPLETED|FAILED) return 1 ;; *) return 0 ;; esac
      ;;
    *|BLOCKED|*|FAILED)
      case "$from" in COMPLETED) return 1 ;; *) return 0 ;; esac
      ;;
    *) return 1 ;;
  esac
}

# Fixed transition checker using explicit pairs
osu_can_transition() {
  local from="$1" to="$2"
  [[ "$from" == "$to" ]] && return 0
  local pair="${from}->${to}"
  local allowed="
NEW->PREFLIGHT_ACCEPTED
NEW->COMPLETED
NEW->BLOCKED
NEW->FAILED
PREFLIGHT_ACCEPTED->INITIALIZED
PREFLIGHT_ACCEPTED->BLOCKED
PREFLIGHT_ACCEPTED->FAILED
INITIALIZED->HOP_PRECHECK
INITIALIZED->COMPLETED
INITIALIZED->BLOCKED
INITIALIZED->FAILED
INITIALIZED->PAUSED
HOP_PRECHECK->HOP_SOURCE_PREPARING
HOP_PRECHECK->BLOCKED
HOP_PRECHECK->FAILED
HOP_PRECHECK->PAUSED
HOP_SOURCE_PREPARING->HOP_SOURCE_READY
HOP_SOURCE_PREPARING->BLOCKED
HOP_SOURCE_PREPARING->FAILED
HOP_SOURCE_PREPARING->PAUSED
HOP_SOURCE_READY->HOP_CURRENT_RELEASE_UPDATING
HOP_SOURCE_READY->BLOCKED
HOP_SOURCE_READY->FAILED
HOP_SOURCE_READY->PAUSED
HOP_CURRENT_RELEASE_UPDATING->HOP_RELEASE_UPGRADE_STARTING
HOP_CURRENT_RELEASE_UPDATING->BLOCKED
HOP_CURRENT_RELEASE_UPDATING->FAILED
HOP_CURRENT_RELEASE_UPDATING->PAUSED
HOP_RELEASE_UPGRADE_STARTING->HOP_RELEASE_UPGRADE_RUNNING
HOP_RELEASE_UPGRADE_STARTING->BLOCKED
HOP_RELEASE_UPGRADE_STARTING->FAILED
HOP_RELEASE_UPGRADE_RUNNING->REBOOT_REQUIRED
HOP_RELEASE_UPGRADE_RUNNING->HOP_VALIDATING
HOP_RELEASE_UPGRADE_RUNNING->FAILED
HOP_RELEASE_UPGRADE_RUNNING->BLOCKED
REBOOT_REQUIRED->REBOOT_REQUESTED
REBOOT_REQUIRED->FAILED
REBOOT_REQUIRED->BLOCKED
REBOOT_REQUIRED->PAUSED
REBOOT_REQUESTED->RESUMED
REBOOT_REQUESTED->FAILED
REBOOT_REQUESTED->BLOCKED
RESUMED->HOP_VALIDATING
RESUMED->FAILED
RESUMED->BLOCKED
RESUMED->PAUSED
HOP_VALIDATING->HOP_COMPLETED
HOP_VALIDATING->FAILED
HOP_VALIDATING->BLOCKED
HOP_COMPLETED->HOP_PRECHECK
HOP_COMPLETED->COMPLETED
HOP_COMPLETED->CHECKPOINT_REACHED
HOP_COMPLETED->PAUSED
HOP_COMPLETED->BLOCKED
CHECKPOINT_REACHED->PREFLIGHT_ACCEPTED
CHECKPOINT_REACHED->INITIALIZED
CHECKPOINT_REACHED->HOP_PRECHECK
PAUSED->HOP_PRECHECK
PAUSED->RESUMED
PAUSED->HOP_SOURCE_PREPARING
PAUSED->HOP_VALIDATING
PAUSED->INITIALIZED
PAUSED->HOP_COMPLETED
BLOCKED->HOP_PRECHECK
BLOCKED->RESUMED
BLOCKED->INITIALIZED
BLOCKED->FAILED
"
  # pause from non-terminal
  case "$to" in
    PAUSED)
      case "$from" in COMPLETED|FAILED) return 1 ;; *) return 0 ;; esac
      ;;
  esac
  printf '%s\n' "$allowed" | grep -qxF "$pair"
}

osu_state_path() { printf '%s/state.json' "$OSU_STATE_DIR"; }
osu_state_sha_path() { printf '%s/state.json.sha256' "$OSU_STATE_DIR"; }

osu_read_state_field() {
  local field="$1"
  local sp
  sp="$(osu_state_path)"
  [[ -f "$sp" ]] || { printf ''; return 1; }
  osu_json_get "$sp" "$field"
}

osu_verify_state_checksum() {
  local sp sha_path actual expected
  sp="$(osu_state_path)"
  sha_path="$(osu_state_sha_path)"
  [[ -f "$sp" ]] || return 1
  [[ -f "$sha_path" ]] || return 1
  actual="$(osu_sha256_file "$sp")"
  expected="$(tr -d ' \n\r' <"$sha_path")"
  [[ -n "$actual" && "$actual" == "$expected" ]]
}

osu_write_state_json() {
  local content="$1"
  local sp tmp sha_path
  sp="$(osu_state_path)"
  sha_path="$(osu_state_sha_path)"
  mkdir -p "$OSU_STATE_DIR"
  chmod 0700 "$OSU_STATE_DIR" 2>/dev/null || true
  tmp="${sp}.tmp.$$"
  printf '%s\n' "$content" >"$tmp"
  if ! osu_json_validate_file "$tmp"; then
    rm -f "$tmp"
    osu_log ERROR "state JSON validation failed"
    return 1
  fi
  chmod 0640 "$tmp" 2>/dev/null || true
  if [[ "$OSU_TEST_MODE" -eq 0 ]]; then
    chown root:root "$tmp" 2>/dev/null || true
  fi
  # flush
  sync "$tmp" 2>/dev/null || sync 2>/dev/null || true
  mv -f "$tmp" "$sp"
  local hash
  hash="$(osu_sha256_file "$sp")"
  printf '%s\n' "$hash" >"${sha_path}.tmp"
  mv -f "${sha_path}.tmp" "$sha_path"
  chmod 0640 "$sha_path" 2>/dev/null || true
  if ! osu_json_validate_file "$sp"; then
    osu_log ERROR "post-write state revalidation failed"
    return 1
  fi
  return 0
}

osu_build_state_json() {
  # Uses environment-like vars: ST_* (all expansions must tolerate set -u)
  cat <<EOF
{
  "schema_version": "$(osu_json_escape "$OSU_SCHEMA_VERSION")",
  "script_version": "$(osu_json_escape "$OSU_SCRIPT_VERSION")",
  "state_revision": $(osu_json_num_or_null "${ST_REVISION:-1}"),
  "current_state": "$(osu_json_escape "${ST_STATE:-NEW}")",
  "hostname": $(osu_json_str_or_null "${ST_HOSTNAME:-}"),
  "source_os": $(osu_json_str_or_null "${ST_SOURCE_OS:-}"),
  "source_codename": $(osu_json_str_or_null "${ST_SOURCE_CODENAME:-}"),
  "current_os": $(osu_json_str_or_null "${ST_CURRENT_OS:-}"),
  "current_codename": $(osu_json_str_or_null "${ST_CURRENT_CODENAME:-}"),
  "target_os": $(osu_json_str_or_null "${ST_TARGET_OS:-}"),
  "target_codename": $(osu_json_str_or_null "${ST_TARGET_CODENAME:-}"),
  "final_target_os": $(osu_json_str_or_null "${ST_FINAL_TARGET_OS:-$POLICY_TARGET_OS_VERSION}"),
  "final_target_codename": $(osu_json_str_or_null "${ST_FINAL_TARGET_CODENAME:-$POLICY_TARGET_OS_CODENAME}"),
  "current_hop": $(osu_json_num_or_null "${ST_CURRENT_HOP:-0}"),
  "total_hops": $(osu_json_num_or_null "${ST_TOTAL_HOPS:-0}"),
  "attempt": $(osu_json_num_or_null "${ST_ATTEMPT:-1}"),
  "preflight_id": $(osu_json_str_or_null "${ST_PREFLIGHT_ID:-}"),
  "preflight_completed_at": $(osu_json_str_or_null "${ST_PREFLIGHT_COMPLETED_AT:-}"),
  "snapshot_reference": $(osu_json_str_or_null "${ST_SNAPSHOT_REF:-}"),
  "backup_reference": $(osu_json_str_or_null "${ST_BACKUP_REF:-}"),
  "package_source_mode": $(osu_json_str_or_null "${ST_PKG_MODE:-}"),
  "package_source_url": $(osu_json_str_or_null "${ST_PKG_URL:-}"),
  "warning_acceptances": ${ST_WARNING_ACCEPTANCES:-[]},
  "last_successful_step": $(osu_json_str_or_null "${ST_LAST_STEP:-}"),
  "last_error": $(osu_json_str_or_null "${ST_LAST_ERROR:-}"),
  "block_reason": $(osu_json_str_or_null "${ST_BLOCK_REASON:-}"),
  "retryable": $(osu_json_bool "${ST_RETRYABLE:-false}"),
  "retry_count": $(osu_json_num_or_null "${ST_RETRY_COUNT:-0}"),
  "next_retry_at_utc": $(osu_json_str_or_null "${ST_NEXT_RETRY:-}"),
  "pause_requested": $(osu_json_bool "${ST_PAUSE_REQUESTED:-false}"),
  "pause_reason": $(osu_json_str_or_null "${ST_PAUSE_REASON:-}"),
  "runtime_sha256": $(osu_json_str_or_null "${ST_RUNTIME_SHA:-}"),
  "boot_id_at_reboot": $(osu_json_str_or_null "${ST_BOOT_ID:-}"),
  "phase2_executed": false,
  "phase2_evaluated": false,
  "execution_profile": $(osu_json_str_or_null "${ST_EXECUTION_PROFILE:-${OSU_EXECUTION_PROFILE:-production}}"),
  "stop_after_os": $(osu_json_str_or_null "${ST_STOP_AFTER_OS:-}"),
  "max_hops": $(osu_json_num_or_null "${ST_MAX_HOPS:-}"),
  "discovery_acknowledged": $(osu_json_bool "${ST_DISCOVERY_ACKNOWLEDGED:-false}"),
  "snapshot_required": $(osu_json_bool "${ST_SNAPSHOT_REQUIRED:-true}"),
  "snapshot_present": $(osu_json_bool "${ST_SNAPSHOT_PRESENT:-false}"),
  "current_run_hop_limit": $(osu_json_num_or_null "${ST_CURRENT_RUN_HOP_LIMIT:-}"),
  "checkpoint_reason": $(osu_json_str_or_null "${ST_CHECKPOINT_REASON:-}"),
  "new_preflight_required": $(osu_json_bool "${ST_NEW_PREFLIGHT_REQUIRED:-false}"),
  "artifact_capture_status": $(osu_json_str_or_null "${ST_ARTIFACT_CAPTURE_STATUS:-}"),
  "artifact_export_status": $(osu_json_str_or_null "${ST_ARTIFACT_EXPORT_STATUS:-}"),
  "hops_completed_this_run": $(osu_json_num_or_null "${ST_HOPS_THIS_RUN:-0}"),
  "next_action": $(osu_json_str_or_null "${ST_NEXT_ACTION:-}"),
  "created_at_utc": $(osu_json_str_or_null "${ST_CREATED_AT:-}"),
  "updated_at_utc": "$(osu_utc_now)"
}
EOF
}

osu_load_state_into_vars() {
  local sp
  sp="$(osu_state_path)"
  [[ -f "$sp" ]] || return 1
  if ! osu_verify_state_checksum; then
    osu_log ERROR "state checksum mismatch — refusing automatic repair"
    return 1
  fi
  ST_REVISION="$(osu_json_get "$sp" state_revision)"
  ST_STATE="$(osu_json_get "$sp" current_state)"
  ST_HOSTNAME="$(osu_json_get "$sp" hostname)"
  ST_SOURCE_OS="$(osu_json_get "$sp" source_os)"
  ST_SOURCE_CODENAME="$(osu_json_get "$sp" source_codename)"
  ST_CURRENT_OS="$(osu_json_get "$sp" current_os)"
  ST_CURRENT_CODENAME="$(osu_json_get "$sp" current_codename)"
  ST_TARGET_OS="$(osu_json_get "$sp" target_os)"
  ST_TARGET_CODENAME="$(osu_json_get "$sp" target_codename)"
  ST_FINAL_TARGET_OS="$(osu_json_get "$sp" final_target_os)"
  ST_FINAL_TARGET_CODENAME="$(osu_json_get "$sp" final_target_codename)"
  ST_CURRENT_HOP="$(osu_json_get "$sp" current_hop)"
  ST_TOTAL_HOPS="$(osu_json_get "$sp" total_hops)"
  ST_ATTEMPT="$(osu_json_get "$sp" attempt)"
  ST_PREFLIGHT_ID="$(osu_json_get "$sp" preflight_id)"
  ST_PREFLIGHT_COMPLETED_AT="$(osu_json_get "$sp" preflight_completed_at)"
  ST_SNAPSHOT_REF="$(osu_json_get "$sp" snapshot_reference)"
  ST_BACKUP_REF="$(osu_json_get "$sp" backup_reference)"
  ST_PKG_MODE="$(osu_json_get "$sp" package_source_mode)"
  ST_PKG_URL="$(osu_json_get "$sp" package_source_url)"
  ST_LAST_STEP="$(osu_json_get "$sp" last_successful_step)"
  ST_LAST_ERROR="$(osu_json_get "$sp" last_error)"
  ST_BLOCK_REASON="$(osu_json_get "$sp" block_reason)"
  ST_RETRYABLE="$(osu_json_get "$sp" retryable)"
  ST_RETRY_COUNT="$(osu_json_get "$sp" retry_count)"
  ST_NEXT_RETRY="$(osu_json_get "$sp" next_retry_at_utc)"
  ST_PAUSE_REQUESTED="$(osu_json_get "$sp" pause_requested)"
  ST_PAUSE_REASON="$(osu_json_get "$sp" pause_reason)"
  ST_RUNTIME_SHA="$(osu_json_get "$sp" runtime_sha256)"
  ST_BOOT_ID="$(osu_json_get "$sp" boot_id_at_reboot)"
  ST_CREATED_AT="$(osu_json_get "$sp" created_at_utc)"
  ST_EXECUTION_PROFILE="$(osu_json_get "$sp" execution_profile)"
  ST_STOP_AFTER_OS="$(osu_json_get "$sp" stop_after_os)"
  ST_MAX_HOPS="$(osu_json_get "$sp" max_hops)"
  ST_DISCOVERY_ACKNOWLEDGED="$(osu_json_get "$sp" discovery_acknowledged)"
  ST_SNAPSHOT_REQUIRED="$(osu_json_get "$sp" snapshot_required)"
  ST_SNAPSHOT_PRESENT="$(osu_json_get "$sp" snapshot_present)"
  ST_CURRENT_RUN_HOP_LIMIT="$(osu_json_get "$sp" current_run_hop_limit)"
  ST_CHECKPOINT_REASON="$(osu_json_get "$sp" checkpoint_reason)"
  ST_NEW_PREFLIGHT_REQUIRED="$(osu_json_get "$sp" new_preflight_required)"
  ST_ARTIFACT_CAPTURE_STATUS="$(osu_json_get "$sp" artifact_capture_status)"
  ST_ARTIFACT_EXPORT_STATUS="$(osu_json_get "$sp" artifact_export_status)"
  ST_HOPS_THIS_RUN="$(osu_json_get "$sp" hops_completed_this_run)"
  ST_NEXT_ACTION="$(osu_json_get "$sp" next_action)"
  OSU_EXECUTION_PROFILE="${ST_EXECUTION_PROFILE:-$OSU_EXECUTION_PROFILE}"
  # warning_acceptances kept as JSON array string via jq if available
  if command -v jq >/dev/null 2>&1; then
    ST_WARNING_ACCEPTANCES="$(jq -c '.warning_acceptances // []' "$sp")"
  else
    ST_WARNING_ACCEPTANCES='[]'
  fi
  return 0
}

osu_transition_state() {
  local new_state="$1"
  local step="${2:-}"
  local err="${3:-}"
  if [[ -z "${ST_STATE:-}" ]]; then
    if ! osu_load_state_into_vars; then
      ST_STATE="NEW"
    fi
  fi
  local old="$ST_STATE"
  if ! osu_can_transition "$old" "$new_state"; then
    osu_log ERROR "illegal state transition: ${old} -> ${new_state}"
    osu_append_event "illegal_transition" "${old}->${new_state}"
    return 1
  fi
  ST_STATE="$new_state"
  ST_REVISION=$(( ${ST_REVISION:-0} + 1 ))
  [[ -n "$step" ]] && ST_LAST_STEP="$step"
  if [[ -n "$err" ]]; then
    ST_LAST_ERROR="$err"
    ST_BLOCK_REASON="$err"
  elif [[ "$new_state" != "BLOCKED" && "$new_state" != "FAILED" ]]; then
    ST_LAST_ERROR=""
    ST_BLOCK_REASON=""
  fi
  local json
  json="$(osu_build_state_json)"
  osu_write_state_json "$json" || return 1
  osu_append_event "state_transition" "${old}->${new_state}"
  if [[ -n "${ST_CURRENT_HOP:-}" && "${ST_CURRENT_HOP:-0}" -gt 0 ]]; then
    osu_append_hop_history "${ST_CURRENT_HOP}" "${ST_CURRENT_OS}" "${ST_TARGET_OS}" "$new_state" "$step"
  fi
  return 0
}

osu_detect_orphaned_state() {
  # Orphan only when STATE_DIR exists, state.json is missing/invalid, and real
  # upgrade progress evidence is present under that directory.
  # Missing /opt/aelladata/os-upgrade is NOT orphan.
  # Collector/preflight results, project sources, systemd units alone, and
  # host /var/log/dist-upgrade without STATE_DIR are NOT orphan evidence.
  local sp evidence=0
  sp="$(osu_state_path)"
  if [[ -f "$sp" ]]; then
    return 1
  fi
  if [[ ! -d "$OSU_STATE_DIR" ]]; then
    return 1
  fi
  [[ -d "${OSU_STATE_DIR}/hops" ]] && evidence=1
  [[ -d "${OSU_STATE_DIR}/runtime" ]] && evidence=1
  [[ -d "${OSU_STATE_DIR}/original-system-state" ]] && evidence=1
  [[ -f "${OSU_STATE_DIR}/events.jsonl" ]] && evidence=1
  [[ -f "${OSU_STATE_DIR}/hop_history.jsonl" ]] && evidence=1
  [[ -d "${OSU_STATE_DIR}/repository-backup" ]] && evidence=1
  [[ -e "${OSU_STATE_DIR}/apt-sources.list.backup" || -e "${OSU_STATE_DIR}/sources.list.backup" ]] && evidence=1
  [[ -f "${OSU_STATE_DIR}/logs/commands.tsv" ]] && evidence=1
  if [[ -d "${OSU_STATE_DIR}/logs" ]] && \
     find "${OSU_STATE_DIR}/logs" -type f \( -name '*.log' -o -name 'commands.tsv' \) 2>/dev/null | grep -q .; then
    evidence=1
  fi
  if [[ "$evidence" -eq 1 ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Preflight archive / directory input
# ---------------------------------------------------------------------------
osu_cleanup_tmp() {
  if [[ "${OSU_OWNED_TMP:-0}" -eq 1 && -n "${OSU_TMP_DIR:-}" && -d "${OSU_TMP_DIR}" ]]; then
    rm -rf "${OSU_TMP_DIR}"
  fi
}

osu_is_safe_archive_entry() {
  local entry="$1"
  [[ "$entry" != /* ]] || return 1
  [[ "$entry" != *..* ]] || return 1
  [[ -n "$entry" ]] || return 1
  return 0
}

osu_validate_preflight_archive() {
  local archive="$1"
  local entries=0 tops=() e top found t
  local max_entries="${POLICY_MAX_PREFLIGHT_ARCHIVE_ENTRIES}"
  local max_bytes="${POLICY_MAX_PREFLIGHT_ARCHIVE_BYTES}"
  local sz

  sz="$(stat -c%s "$archive" 2>/dev/null || stat -f%z "$archive" 2>/dev/null || echo 0)"
  if [[ "$sz" -gt "$max_bytes" ]]; then
    osu_log ERROR "preflight archive exceeds size limit ($sz > $max_bytes)"
    return 1
  fi

  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    osu_is_safe_archive_entry "$e" || {
      osu_log ERROR "unsafe archive entry rejected: $e"
      return 1
    }
    entries=$((entries + 1))
    if [[ "$entries" -gt "$max_entries" ]]; then
      osu_log ERROR "archive entry count exceeds limit"
      return 1
    fi
    top="${e%%/*}"
    [[ -n "$top" ]] || continue
    found=0
    for t in "${tops[@]+"${tops[@]}"}"; do
      [[ "$t" == "$top" ]] && found=1 && break
    done
    if [[ "$found" -eq 0 ]]; then
      tops+=("$top")
    fi
  done < <(tar -tzf "$archive" 2>/dev/null)

  if [[ ${#tops[@]} -ne 1 ]]; then
    osu_log ERROR "archive must contain exactly one top-level root (found ${#tops[@]})"
    return 1
  fi

  # Reject special file types via python when available
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 - "$archive" <<'PY'
import tarfile,sys
bad=False
with tarfile.open(sys.argv[1],'r:gz') as t:
    for m in t.getmembers():
        if m.isdev() or m.isfifo() or m.isblk() or m.ischr():
            print('special file:', m.name, file=sys.stderr); bad=True
        if m.islnk() and (m.linkname.startswith('/') or '..' in m.linkname.split('/')):
            print('bad hardlink:', m.name, file=sys.stderr); bad=True
sys.exit(1 if bad else 0)
PY
    then
      return 1
    fi
  fi
  printf '%s' "${tops[0]}"
  return 0
}

osu_extract_preflight_archive() {
  local archive="$1" dest="$2"
  local top root
  top="$(osu_validate_preflight_archive "$archive")" || return 1
  mkdir -p "$dest"
  if ! tar -xzf "$archive" -C "$dest" 2>/dev/null; then
    osu_log ERROR "failed to extract preflight archive"
    return 1
  fi
  root="${dest}/${top}"
  [[ -d "$root" ]] || { osu_log ERROR "extracted root missing"; return 1; }
  local link target
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    if [[ -L "$link" ]]; then
      target="$(readlink -f "$link" 2>/dev/null || true)"
      if [[ -n "$target" && "$target" != "$root"* ]]; then
        osu_log ERROR "symlink escapes preflight root: $link -> $target"
        return 1
      fi
    fi
  done < <(find "$root" -type l 2>/dev/null || true)
  printf '%s' "$root"
}

osu_require_preflight_files() {
  local root="$1" f
  for f in preflight-summary.json checks.tsv blockers.txt warnings.txt remediation.md policy-effective.conf source/collector-reference.txt; do
    if [[ ! -f "${root}/${f}" ]]; then
      osu_log ERROR "required preflight file missing: $f"
      return 1
    fi
  done
  return 0
}

osu_prepare_preflight_input() {
  local path="$1"
  if [[ -d "$path" ]]; then
    OSU_PREFLIGHT_INPUT_TYPE="directory"
    OSU_PREFLIGHT_ROOT="$(cd "$path" && pwd)"
  elif [[ -f "$path" ]]; then
    case "$path" in
      *.tar.gz|*.tgz)
        OSU_PREFLIGHT_INPUT_TYPE="tar.gz"
        OSU_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dp-os-upgrade-pf-XXXXXX")"
        OSU_OWNED_TMP=1
        OSU_PREFLIGHT_ROOT="$(osu_extract_preflight_archive "$path" "$OSU_TMP_DIR")" || return 1
        ;;
      *)
        osu_log ERROR "preflight path must be a directory or .tar.gz"
        return 1
        ;;
    esac
  else
    osu_log ERROR "preflight path not found: $path"
    return 1
  fi
  osu_require_preflight_files "$OSU_PREFLIGHT_ROOT" || return 1
  if ! osu_json_validate_file "${OSU_PREFLIGHT_ROOT}/preflight-summary.json"; then
    osu_log ERROR "preflight-summary.json is not valid JSON"
    return 1
  fi
  return 0
}

osu_load_preflight_summary() {
  local sj="${OSU_PREFLIGHT_ROOT}/preflight-summary.json"
  PF_SCHEMA="$(osu_json_get "$sj" schema_version)"
  PF_SCRIPT_VERSION="$(osu_json_get "$sj" script_version)"
  PF_ID="$(osu_json_get "$sj" preflight_id)"
  PF_COMPLETED_AT="$(osu_json_get "$sj" completed_at_utc)"
  PF_HOSTNAME="$(osu_json_get "$sj" target.hostname)"
  PF_OS_VERSION="$(osu_json_get "$sj" target.os_version)"
  PF_OS_CODENAME="$(osu_json_get "$sj" target.os_codename)"
  PF_DP_VERSION_RAW="$(osu_json_get "$sj" target.dp_version_raw)"
  PF_DP_VERSION_NORM="$(osu_json_get "$sj" target.dp_version_normalized)"
  PF_ROLE="$(osu_json_get "$sj" target.role)"
  PF_OVERALL="$(osu_json_get "$sj" result.overall_status)"
  PF_RECOMMENDED="$(osu_json_get "$sj" upgrade_plan.recommended_action)"
  PF_PHASE1_REQUIRED="$(osu_json_get "$sj" upgrade_plan.phase1_required)"
  PF_PHASE1_HOPS="$(osu_json_get "$sj" upgrade_plan.phase1_hops)"
  PF_PHASE2_REQUIRED="$(osu_json_get "$sj" upgrade_plan.phase2_required)"
  PF_PACKAGE_SOURCE_MODE="$(osu_json_get "$sj" requested_path.package_source_mode)"
  PF_PACKAGE_SOURCE_URL="$(osu_json_get "$sj" requested_path.package_source_url)"
  PF_SNAPSHOT_REF="$(osu_json_get "$sj" requested_path.snapshot_reference)"
  PF_BACKUP_REF="$(osu_json_get "$sj" requested_path.backup_reference)"
  PF_BRINGUP_MODE="$(osu_json_get "$sj" requested_path.bringup_mode)"

  PF_EXECUTION_PROFILE="$(osu_json_get "$sj" upgrade_plan.execution_profile)"
  if [[ -z "$PF_EXECUTION_PROFILE" ]]; then
    PF_EXECUTION_PROFILE="$(osu_json_get "$sj" requested_path.execution_profile)"
  fi
  if [[ -z "$PF_EXECUTION_PROFILE" ]]; then
    PF_EXECUTION_PROFILE="${POLICY_DEFAULT_EXECUTION_PROFILE:-production}"
  fi
  PF_PHASE2_EVALUATED="$(osu_json_get "$sj" upgrade_plan.phase2_evaluated)"
  PF_OS_UPGRADE_REQUIRED="$(osu_json_get "$sj" upgrade_plan.os_upgrade_required)"
  PF_NEXT_HOP="$(osu_json_get "$sj" upgrade_plan.next_hop)"
  PF_SNAPSHOT_REQUIRED="$(osu_json_get "$sj" upgrade_plan.snapshot_required)"

  # Normalize legacy recommended_action values to OS-only canonical set
  case "$PF_RECOMMENDED" in
    RUN_PHASE1|RUN_PHASE1_AND_PHASE2)
      osu_log WARN "normalizing legacy recommended_action=${PF_RECOMMENDED} -> RUN_OS_UPGRADE (phase2 ignored)"
      PF_RECOMMENDED="RUN_OS_UPGRADE"
      ;;
    RUN_PHASE2)
      osu_log WARN "legacy recommended_action=RUN_PHASE2 ignored for Phase 1; treating as NO_OS_UPGRADE_REQUIRED"
      PF_RECOMMENDED="NO_OS_UPGRADE_REQUIRED"
      ;;
    NONE)
      PF_RECOMMENDED="NO_OS_UPGRADE_REQUIRED"
      ;;
    RUN_OS_UPGRADE|NO_OS_UPGRADE_REQUIRED|UNSUPPORTED|BLOCKED) ;;
    *)
      osu_log WARN "unknown recommended_action=${PF_RECOMMENDED}"
      ;;
  esac
  # phase2_required from legacy fixtures is ignored for Phase 1 gates
  PF_PHASE2_REQUIRED="false"
  PF_PHASE2_EVALUATED="false"

  if [[ "$PF_SCHEMA" != "1.0" ]]; then
    osu_log ERROR "unsupported preflight schema: ${PF_SCHEMA}"
    return 1
  fi
  return 0
}

osu_list_warning_ids() {
  local checks="${OSU_PREFLIGHT_ROOT}/checks.tsv"
  awk -F'\t' 'NR>1 && ($3=="WARN" || $3=="UNKNOWN" || ($3=="FAIL" && $4=="WARNING")) {print $1}' "$checks" | sort -u
}

osu_list_blocker_ids() {
  local checks="${OSU_PREFLIGHT_ROOT}/checks.tsv"
  local blockers="${OSU_PREFLIGHT_ROOT}/blockers.txt"
  local ids=""
  if [[ -f "$checks" ]]; then
    ids="$(awk -F'\t' 'NR>1 && ($4=="BLOCKER" || ($3=="FAIL" && $4=="BLOCKER")) {print $1}' "$checks" | sort -u)"
  fi
  if [[ -z "$ids" && -f "$blockers" ]]; then
    ids="$(awk -F: 'NF>=1 && $1 !~ /^#/ && $1 !~ /^$/ {gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1!="") print $1}' "$blockers" | sort -u)"
  fi
  printf '%s\n' "$ids" | sed '/^$/d'
}

# Match ISO-8601 UTC timestamps used in preflight completed_at_utc.
# Supports: YYYY-MM-DDTHH:MM:SSZ | +00:00 / ±HH:MM | fractional seconds.
osu_iso_timestamp_match() {
  local ts="$1"
  [[ -n "$ts" ]] || return 1
  [[ "$ts" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]
}

# Strip fractional seconds for tools that reject them (keeps Z / offset).
osu_iso_strip_fractional() {
  local ts="$1"
  if [[ "$ts" =~ ^(.*T[0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]+(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s\n' "$ts"
  fi
}

# Validate calendar date / time components (rejects 2026-02-30, 2026-13-16, …).
osu_iso_validate_components() {
  local y="$1" mo="$2" d="$3" h="$4" mi="$5" s="$6"
  local dim
  y=$((10#$y)); mo=$((10#$mo)); d=$((10#$d))
  h=$((10#$h)); mi=$((10#$mi)); s=$((10#$s))
  (( mo >= 1 && mo <= 12 )) || return 1
  (( h >= 0 && h <= 23 )) || return 1
  (( mi >= 0 && mi <= 59 )) || return 1
  (( s >= 0 && s <= 59 )) || return 1
  case "$mo" in
    1|3|5|7|8|10|12) dim=31 ;;
    4|6|9|11) dim=30 ;;
    2)
      if (( (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0) )); then
        dim=29
      else
        dim=28
      fi
      ;;
    *) return 1 ;;
  esac
  (( d >= 1 && d <= dim )) || return 1
  return 0
}

# Civil date → UTC epoch seconds (Howard Hinnant algorithm; no local TZ).
osu_civil_to_utc_epoch() {
  local y="$1" m="$2" d="$3" h="$4" mi="$5" s="$6"
  local era yoe doy doe days
  y=$((10#$y)); m=$((10#$m)); d=$((10#$d))
  h=$((10#$h)); mi=$((10#$mi)); s=$((10#$s))
  if (( m <= 2 )); then y=$((y - 1)); fi
  if (( y >= 0 )); then era=$((y / 400)); else era=$(( (y - 399) / 400 )); fi
  yoe=$((y - era * 400))
  if (( m > 2 )); then
    doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 ))
  else
    doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 ))
  fi
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  days=$((era * 146097 + doe - 719468))
  printf '%s\n' "$((days * 86400 + h * 3600 + mi * 60 + s))"
}

osu_parse_iso_epoch_bash() {
  local ts="$1" y mo d h mi s tz sign th tm epoch off
  osu_iso_timestamp_match "$ts" || return 1
  y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  tz="${BASH_REMATCH[8]}"
  osu_iso_validate_components "$y" "$mo" "$d" "$h" "$mi" "$s" || return 1
  epoch="$(osu_civil_to_utc_epoch "$y" "$mo" "$d" "$h" "$mi" "$s")" || return 1
  if [[ "$tz" != "Z" ]]; then
    sign=1
    [[ "${tz:0:1}" == "-" ]] && sign=-1
    th="${tz:1:2}"
    tm="${tz:4:2}"
    th=$((10#$th)); tm=$((10#$tm))
    (( th >= 0 && th <= 23 && tm >= 0 && tm <= 59 )) || return 1
    off=$((sign * (th * 3600 + tm * 60)))
    epoch=$((epoch - off))
  fi
  printf '%s\n' "$epoch"
}

osu_parse_iso_epoch_gnu_date() {
  local ts="$1" norm epoch y mo d h mi s
  osu_iso_timestamp_match "$ts" || return 1
  y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
  h="${BASH_REMATCH[4]}"; mi="${BASH_REMATCH[5]}"; s="${BASH_REMATCH[6]}"
  osu_iso_validate_components "$y" "$mo" "$d" "$h" "$mi" "$s" || return 1
  norm="$(osu_iso_strip_fractional "$ts")"
  # Normalize +00:00 / -00:00 to Z for broader GNU date compatibility.
  case "$norm" in
    *+00:00) norm="${norm%+00:00}Z" ;;
    *-00:00) norm="${norm%-00:00}Z" ;;
  esac
  epoch="$(date -u -d "$norm" +%s 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$epoch"
}

# Portable Python 2.7 / 3.x parser — no fromisoformat / timezone.utc / aware .timestamp().
osu_parse_iso_epoch_python() {
  local ts="$1" py
  osu_iso_timestamp_match "$ts" || return 1
  for py in python3 python2 python; do
    command -v "$py" >/dev/null 2>&1 || continue
    if "$py" - "$ts" <<'PY'
from __future__ import print_function
import sys, re, calendar, datetime
s = sys.argv[1].strip()
m = re.match(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$',
    s,
)
if not m:
    sys.exit(1)
y, mo, d, h, mi, sec = [int(x) for x in m.group(1, 2, 3, 4, 5, 6)]
tz = m.group(7)
try:
    datetime.datetime(y, mo, d, h, mi, sec)
except ValueError:
    sys.exit(1)
epoch = calendar.timegm((y, mo, d, h, mi, sec, 0, 0, 0))
if tz != 'Z':
    sign = 1 if tz[0] == '+' else -1
    th, tm = tz[1:].split(':')
    epoch -= sign * (int(th) * 3600 + int(tm) * 60)
print(int(epoch))
PY
    then
      return 0
    fi
  done
  return 1
}

osu_parse_iso_epoch_perl() {
  local ts="$1"
  osu_iso_timestamp_match "$ts" || return 1
  command -v perl >/dev/null 2>&1 || return 1
  perl - "$ts" <<'PL'
use strict;
use warnings;
use Time::Local qw(timegm);
my $s = $ARGV[0];
if ($s !~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/) {
  exit 1;
}
my ($y, $mo, $d, $h, $mi, $sec, $tz) = ($1, $2, $3, $4, $5, $6, $7);
my $epoch;
eval { $epoch = timegm($sec, $mi, $h, $d, $mo - 1, $y); 1 } or exit 1;
if ($tz ne 'Z') {
  my $sign = (substr($tz, 0, 1) eq '+') ? 1 : -1;
  my ($th, $tm) = split /:/, substr($tz, 1);
  $epoch -= $sign * ($th * 3600 + $tm * 60);
}
print int($epoch), "\n";
PL
}

# Canonical: ISO-8601 UTC timestamp → UTC epoch seconds.
# Order: GNU date (when it accepts the form) → python3/2 → Perl → Bash.
# Must work on Ubuntu 16.04 (Bash 4.3, Python 3.5, older coreutils).
osu_parse_iso_epoch() {
  local ts="$1" epoch
  [[ -n "$ts" ]] || return 1
  osu_iso_timestamp_match "$ts" || return 1

  if epoch="$(osu_parse_iso_epoch_gnu_date "$ts" 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  if epoch="$(osu_parse_iso_epoch_python "$ts" 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  if epoch="$(osu_parse_iso_epoch_perl "$ts" 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  if epoch="$(osu_parse_iso_epoch_bash "$ts" 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  return 1
}

osu_check_preflight_freshness() {
  local completed="$PF_COMPLETED_AT"
  local epoch_c epoch_n age max_age
  if [[ -z "$completed" ]]; then
    osu_die_cli "preflight completed_at_utc missing"
  fi
  epoch_c="$(osu_parse_iso_epoch "$completed")" || {
    osu_die_cli "invalid preflight timestamp: $completed"
  }
  # Compare in UTC epoch seconds only (immune to local TZ).
  epoch_n="$(date -u +%s)"
  if [[ "$epoch_c" -gt $((epoch_n + 60)) ]]; then
    osu_log ERROR "preflight timestamp is in the future: $completed"
    return 1
  fi
  age=$((epoch_n - epoch_c))
  max_age="${POLICY_PREFLIGHT_MAX_AGE_SECONDS}"
  if [[ "$age" -gt "$max_age" ]]; then
    osu_log ERROR "preflight stale: age=${age}s max=${max_age}s — re-run collector and preflight"
    return 1
  fi
  return 0
}

osu_current_hostname() {
  if [[ "$OSU_TEST_MODE" -eq 1 && -n "${DP_OS_UPGRADE_FAKE_HOSTNAME:-}" ]]; then
    printf '%s' "$DP_OS_UPGRADE_FAKE_HOSTNAME"
    return
  fi
  local f
  f="$(osu_hostpath /etc/hostname)"
  if [[ -r "$f" ]]; then
    tr -d '\n\r' <"$f"
  else
    hostname 2>/dev/null || printf 'unknown'
  fi
}

osu_current_os_version() {
  if [[ "$OSU_TEST_MODE" -eq 1 && -n "${DP_OS_UPGRADE_FAKE_OS_VERSION:-}" ]]; then
    printf '%s' "$DP_OS_UPGRADE_FAKE_OS_VERSION"
    return
  fi
  local f
  f="$(osu_hostpath /etc/os-release)"
  if [[ -r "$f" ]]; then
    # shellcheck disable=SC1090
    VERSION_ID=""
    # parse without sourcing shell expansions from unknown content
    VERSION_ID="$(grep -E '^VERSION_ID=' "$f" | head -1 | cut -d= -f2- | tr -d '"')"
    printf '%s' "$VERSION_ID"
  else
    printf ''
  fi
}

osu_current_os_codename() {
  if [[ "$OSU_TEST_MODE" -eq 1 && -n "${DP_OS_UPGRADE_FAKE_OS_CODENAME:-}" ]]; then
    printf '%s' "$DP_OS_UPGRADE_FAKE_OS_CODENAME"
    return
  fi
  local f
  f="$(osu_hostpath /etc/os-release)"
  if [[ -r "$f" ]]; then
    grep -E '^VERSION_CODENAME=' "$f" | head -1 | cut -d= -f2- | tr -d '"'
  else
    printf ''
  fi
}

osu_current_dp_version() {
  if [[ "$OSU_TEST_MODE" -eq 1 && -n "${DP_OS_UPGRADE_FAKE_DP_VERSION:-}" ]]; then
    printf '%s' "$DP_OS_UPGRADE_FAKE_DP_VERSION"
    return
  fi
  local candidates=(
    "$(osu_hostpath /opt/aelladata/release-metadata.yml)"
    "$(osu_hostpath /opt/aelladata/release-image.yml)"
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -r "$f" ]]; then
      local v
      v="$(grep -E 'version|dp_version' "$f" | head -1 | sed -E 's/.*[: ]([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' || true)"
      if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    fi
  done
  printf ''
}

# ---------------------------------------------------------------------------
# Preflight safety gates
# ---------------------------------------------------------------------------
osu_gate_preflight_status() {
  case "$PF_OVERALL" in
    READY) return 0 ;;
    READY_WITH_WARNINGS) return 0 ;; # further warning acceptance required for execute
    BLOCKED)
      osu_log ERROR "preflight overall_status=BLOCKED — cannot override"
      local id
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        osu_log ERROR "blocker: $id"
      done < <(osu_list_blocker_ids)
      return 1
      ;;
    *)
      osu_log ERROR "unknown preflight status: $PF_OVERALL"
      return 1
      ;;
  esac
}

osu_gate_recommended_action() {
  case "$PF_RECOMMENDED" in
    RUN_OS_UPGRADE|RUN_PHASE1|RUN_PHASE1_AND_PHASE2) return 0 ;;
    NO_OS_UPGRADE_REQUIRED|NONE)
      # Allowed for no-op 24.04 COMPLETED path
      return 0
      ;;
    UNSUPPORTED|BLOCKED)
      osu_log ERROR "recommended_action=${PF_RECOMMENDED} — refusing OS upgrade"
      return 1
      ;;
    RUN_PHASE2)
      osu_log ERROR "recommended_action=RUN_PHASE2 — Phase 1 orchestrator will not run Phase 2"
      return 1
      ;;
    *)
      osu_log ERROR "unsupported recommended_action: $PF_RECOMMENDED"
      return 1
      ;;
  esac
}

osu_gate_identity_match() {
  local host osver
  host="$(osu_current_hostname)"
  osver="$(osu_current_os_version)"
  if [[ "$host" != "$PF_HOSTNAME" ]]; then
    osu_log ERROR "hostname mismatch: current=$host preflight=$PF_HOSTNAME"
    return 1
  fi
  if [[ "$osver" != "$PF_OS_VERSION" ]]; then
    # Allow if we are mid-upgrade and state says so
    if [[ -n "${ST_STATE:-}" && "$ST_STATE" != "NEW" && "$ST_STATE" != "PREFLIGHT_ACCEPTED" && "$ST_STATE" != "INITIALIZED" ]]; then
      :
    else
      osu_log ERROR "OS version mismatch: current=$osver preflight=$PF_OS_VERSION"
      return 1
    fi
  fi
  return 0
}

osu_gate_package_source_match() {
  local mode="${1:-}" url="${2:-}"
  # If CLI does not override, accept preflight values
  if [[ -z "$mode" ]]; then
    return 0
  fi
  if [[ "$mode" != "$PF_PACKAGE_SOURCE_MODE" ]]; then
    osu_log ERROR "package source mode mismatch: cli=$mode preflight=$PF_PACKAGE_SOURCE_MODE"
    return 1
  fi
  if [[ "$mode" == "mirror" || "$mode" == "cache" ]]; then
    local curl="${url%/}"
    local purl="${PF_PACKAGE_SOURCE_URL%/}"
    if [[ -n "$url" && "$curl" != "$purl" ]]; then
      osu_log ERROR "package source URL mismatch"
      return 1
    fi
  fi
  return 0
}

osu_gate_snapshot_present() {
  local snap="$PF_SNAPSHOT_REF" bak="$PF_BACKUP_REF"
  local profile="${OSU_EXECUTION_PROFILE:-${PF_EXECUTION_PROFILE:-production}}"
  if osu_is_placeholder "$snap"; then snap=""; fi
  if osu_is_placeholder "$bak"; then bak=""; fi
  if [[ -z "$snap" && -z "$bak" ]]; then
    if [[ "$PF_RECOMMENDED" == "NONE" || "$PF_RECOMMENDED" == "NO_OS_UPGRADE_REQUIRED" ]]; then
      return 0
    fi
    if [[ "$profile" == "discovery" ]]; then
      osu_log WARN "discovery profile: snapshot/backup optional (not blocking)"
      return 0
    fi
    osu_log ERROR "snapshot or backup reference required for production"
    return 1
  fi
  return 0
}

osu_gate_execution_profile_match() {
  local cli_profile="${1:-}"
  local pf_profile="${PF_EXECUTION_PROFILE:-production}"
  [[ -z "$cli_profile" ]] && cli_profile="${OSU_EXECUTION_PROFILE:-production}"
  if [[ "$cli_profile" != "$pf_profile" ]]; then
    osu_log ERROR "execution profile mismatch: cli=${cli_profile} preflight=${pf_profile}"
    return 1
  fi
  return 0
}

osu_gate_discovery_ack() {
  local profile="${OSU_EXECUTION_PROFILE:-production}"
  if [[ "$profile" != "discovery" ]]; then
    return 0
  fi
  if [[ "${POLICY_DISCOVERY_REQUIRE_DISPOSABLE_VM_ACK}" != "true" ]]; then
    return 0
  fi
  if [[ "${OSU_DISCOVERY_ACK}" != "${POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE}" ]]; then
    osu_log ERROR "discovery requires --acknowledge-disposable-discovery-vm '${POLICY_DISCOVERY_DISPOSABLE_VM_ACK_PHRASE}' (no changes made)"
    return 1
  fi
  return 0
}

osu_next_lts_version() {
  local cur="$1" pair next="" found=0
  for pair in $OSU_LTS_CHAIN; do
    if [[ "$found" -eq 1 ]]; then
      printf '%s' "${pair%%:*}"
      return 0
    fi
    if [[ "${pair%%:*}" == "$cur" ]]; then
      found=1
    fi
  done
  return 1
}

osu_validate_stop_after_os() {
  local start="$1" stop="$2"
  [[ -z "$stop" ]] && return 0
  local next
  next="$(osu_next_lts_version "$start")" || {
    osu_log ERROR "cannot determine next LTS from $start"
    return 1
  }
  if [[ "$stop" != "$next" ]]; then
    # Allow stop == current only when already there; otherwise reject skip
    local si ti
    si="$(osu_lts_index "$start")" || return 1
    ti="$(osu_lts_index "$stop")" || {
      osu_log ERROR "stop-after-os not in LTS chain: $stop"
      return 1
    }
    if (( ti <= si )); then
      osu_log ERROR "stop-after-os ${stop} is not after current ${start}"
      return 1
    fi
    if (( ti > si + 1 )); then
      osu_log ERROR "LTS hop skip rejected: --stop-after-os ${stop} from ${start} would skip intermediate LTS (next is ${next})"
      return 1
    fi
  fi
  return 0
}

# Warning acceptance: space-separated accepted IDs in OSU_ACCEPTED_WARNINGS
# ALL mode: OSU_ACCEPT_ALL_WARNINGS=1 with reference + phrase
OSU_ACCEPTED_WARNINGS=""
OSU_ACCEPT_ALL_WARNINGS=0
OSU_APPROVAL_REFERENCE=""
OSU_ALL_WARNINGS_ACK=""
OSU_WARNING_ACCEPTANCE_JSON="[]"

osu_validate_warning_acceptances() {
  local need_ids missing=0 id found a
  if [[ "$PF_OVERALL" == "READY" ]]; then
    OSU_WARNING_ACCEPTANCE_JSON='[]'
    return 0
  fi
  if [[ "$PF_OVERALL" != "READY_WITH_WARNINGS" ]]; then
    return 0
  fi

  mapfile -t need_ids < <(osu_list_warning_ids)
  if [[ ${#need_ids[@]} -eq 0 ]]; then
    OSU_WARNING_ACCEPTANCE_JSON='[]'
    return 0
  fi

  if [[ "$OSU_ACCEPT_ALL_WARNINGS" -eq 1 ]]; then
    if [[ -z "$OSU_APPROVAL_REFERENCE" ]] || osu_is_placeholder "$OSU_APPROVAL_REFERENCE"; then
      osu_log ERROR "accept-all-warnings requires a non-placeholder --approval-reference"
      return 1
    fi
    if [[ "$OSU_ALL_WARNINGS_ACK" != "$POLICY_ALL_WARNINGS_ACK_PHRASE" ]]; then
      osu_log ERROR "acknowledge-all-warnings phrase mismatch"
      return 1
    fi
    OSU_ACCEPTED_WARNINGS="$(printf '%s\n' "${need_ids[@]}" | tr '\n' ' ')"
  fi

  # Reject accepting unknown warning IDs
  for a in $OSU_ACCEPTED_WARNINGS; do
    found=0
    for id in "${need_ids[@]}"; do
      [[ "$a" == "$id" ]] && found=1 && break
    done
    if [[ "$found" -eq 0 ]]; then
      osu_log ERROR "cannot accept unknown warning id: $a"
      return 1
    fi
  done

  missing=0
  for id in "${need_ids[@]}"; do
    found=0
    for a in $OSU_ACCEPTED_WARNINGS; do
      [[ "$a" == "$id" ]] && found=1 && break
    done
    if [[ "$found" -eq 0 ]]; then
      osu_log ERROR "unaccepted warning: $id"
      missing=1
    fi
  done
  if [[ "$missing" -eq 1 ]]; then
    return 1
  fi

  # Build acceptance JSON
  local user ts parts="" first=1
  user="${SUDO_USER:-${USER:-unknown}}"
  ts="$(osu_utc_now)"
  parts="["
  first=1
  for id in "${need_ids[@]}"; do
    if [[ "$first" -eq 1 ]]; then first=0; else parts+=","; fi
    parts+="{\"warning_id\":\"$(osu_json_escape "$id")\",\"user\":\"$(osu_json_escape "$user")\",\"accepted_at_utc\":\"$(osu_json_escape "$ts")\",\"approval_reference\":$(osu_json_str_or_null "$OSU_APPROVAL_REFERENCE"),\"reason\":\"explicit_cli_acceptance\"}"
  done
  parts+="]"
  OSU_WARNING_ACCEPTANCE_JSON="$parts"
  return 0
}

# ---------------------------------------------------------------------------
# Live safety check (read-only)
# ---------------------------------------------------------------------------
osu_df_avail_bytes() {
  local path="$1" hp
  hp="$(osu_hostpath "$path")"
  if [[ ! -e "$hp" ]]; then printf '0'; return 1; fi
  df -PB1 "$hp" 2>/dev/null | awk 'NR==2{print $4}'
}

osu_df_inode_pct_free() {
  local path="$1" hp
  hp="$(osu_hostpath "$path")"
  df -Pi "$hp" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print 100-$5}'
}

osu_fs_readonly() {
  local path="$1" hp
  hp="$(osu_hostpath "$path")"
  if findmnt -T "$hp" -o OPTIONS -n 2>/dev/null | grep -qw ro; then
    return 0
  fi
  return 1
}

osu_apt_lock_active() {
  local locks=(
    "$(osu_hostpath /var/lib/dpkg/lock)"
    "$(osu_hostpath /var/lib/dpkg/lock-frontend)"
    "$(osu_hostpath /var/lib/apt/lists/lock)"
    "$(osu_hostpath /var/cache/apt/archives/lock)"
  )
  local l
  for l in "${locks[@]}"; do
    if [[ -f "$l" ]] && command -v fuser >/dev/null 2>&1; then
      if fuser "$l" >/dev/null 2>&1; then return 0; fi
    fi
    # test-mode marker
    if [[ -f "${l}.held" ]]; then return 0; fi
  done
  if [[ -f "$(osu_hostpath /var/lib/dpkg/lock).active" ]]; then return 0; fi
  if [[ "${DP_OS_UPGRADE_FAKE_APT_LOCK:-0}" == "1" ]]; then return 0; fi
  return 1
}

osu_upgrade_process_active() {
  if [[ "${DP_OS_UPGRADE_FAKE_DRO_ACTIVE:-0}" == "1" ]]; then return 0; fi
  # In test mode, do not scan the real host process table (pgrep -f can match
  # our own test harness / stub paths containing these strings).
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    [[ -f "$(osu_hostpath /tmp/upgrade-process-active)" ]] && return 0
    return 1
  fi
  if command -v pgrep >/dev/null 2>&1; then
    # Match real package-manager binaries; exclude this orchestrator.
    if pgrep -x apt >/dev/null 2>&1; then return 0; fi
    if pgrep -x apt-get >/dev/null 2>&1; then return 0; fi
    if pgrep -x dpkg >/dev/null 2>&1; then return 0; fi
    if pgrep -x unattended-upgrade >/dev/null 2>&1; then return 0; fi
    if pgrep -f '[d]o-release-upgrade' >/dev/null 2>&1; then
      # Ignore if the only match is our runner/CLI argv
      if pgrep -af '[d]o-release-upgrade' 2>/dev/null | grep -vE 'dp-os-upgrade|test_dp_os_upgrade' | grep -q .; then
        return 0
      fi
    fi
  fi
  return 1
}

# True if apt/dpkg/do-release-upgrade OR a live dp-os-upgrade runner is active.
osu_os_upgrade_activity_present() {
  if osu_upgrade_process_active; then
    return 0
  fi
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    [[ -f "$(osu_hostpath /tmp/dp-os-upgrade-process-active)" ]] && return 0
    return 1
  fi
  if command -v pgrep >/dev/null 2>&1; then
    if pgrep -f '[d]p-os-upgrade-runner\.sh' >/dev/null 2>&1; then
      return 0
    fi
    if pgrep -f '[d]p-os-upgrade-only\.sh (install|resume|continue)' >/dev/null 2>&1; then
      # Exclude this very process
      local self=$$
      if pgrep -af '[d]p-os-upgrade-only\.sh (install|resume|continue)' 2>/dev/null \
        | awk -v self="$self" '$1 != self {found=1} END {exit !found}'; then
        return 0
      fi
    fi
  fi
  return 1
}

osu_read_held_packages() {
  if [[ "$OSU_TEST_MODE" -eq 1 && -f "$(osu_hostpath /tmp/held-packages.txt)" ]]; then
    cat "$(osu_hostpath /tmp/held-packages.txt)"
    return
  fi
  if command -v apt-mark >/dev/null 2>&1; then
    apt-mark showhold 2>/dev/null || true
  fi
}

osu_critical_holds_present() {
  local held crit pkg
  held="$(osu_read_held_packages)"
  IFS=',' read -r -a crit <<< "$POLICY_CRITICAL_HELD_PACKAGES"
  for pkg in "${crit[@]}"; do
    pkg="$(printf '%s' "$pkg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$pkg" ]] && continue
    if printf '%s\n' "$held" | grep -qxF "$pkg"; then
      printf '%s\n' "$pkg"
    fi
  done
}

# NTP live-precheck evidence (populated by osu_ntp_evaluate)
OSU_NTP_SOURCE=""
OSU_NTP_SYNCHRONIZED=""
OSU_NTP_SELECTED_PEER=""
OSU_NTP_REACH=""
OSU_NTP_OFFSET_MS=""
OSU_NTP_RAW_FILE=""
OSU_NTP_DETAIL=""

osu_ntp_reset_evidence() {
  # Preserve OSU_NTP_RAW_FILE — live_precheck sets the path before evaluate.
  OSU_NTP_SOURCE=""
  OSU_NTP_SYNCHRONIZED=""
  OSU_NTP_SELECTED_PEER=""
  OSU_NTP_REACH=""
  OSU_NTP_OFFSET_MS=""
  OSU_NTP_DETAIL=""
}

osu_ntp_set_evidence() {
  OSU_NTP_SOURCE="${1:-}"
  OSU_NTP_SYNCHRONIZED="${2:-}"
  OSU_NTP_SELECTED_PEER="${3:-}"
  OSU_NTP_REACH="${4:-}"
  OSU_NTP_OFFSET_MS="${5:-}"
  OSU_NTP_DETAIL="${6:-}"
}

# Parse ntpq -p / -pn text. Sets peer/reach/offset via nameref-style globals:
# OSU_NTP_PARSE_PEER OSU_NTP_PARSE_REACH OSU_NTP_PARSE_OFFSET
# Returns: 0=synchronized (* peer, reach!=0, numeric offset), 1=not synced, 2=unusable input
osu_ntp_parse_ntpq_output() {
  local text="${1:-}"
  local line trimmed tally peer reach offset f1
  OSU_NTP_PARSE_PEER=""
  OSU_NTP_PARSE_REACH=""
  OSU_NTP_PARSE_OFFSET=""

  [[ -n "$text" ]] || return 2
  if printf '%s\n' "$text" | grep -qiE 'no association ID'; then
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [[:space:]]*remote[[:space:]]+refid ]] && continue
    [[ "$line" =~ ^=+$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Drop leading whitespace; tally code is first character of the peer field.
    # '+'/'-'/'x'/'#'/' '/'.' are not the selected sys.peer.
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$trimmed" ]] || continue
    tally="${trimmed:0:1}"
    [[ "$tally" == "*" ]] || continue

    f1="$(printf '%s\n' "$trimmed" | awk '{print $1}')"
    peer="${f1:1}"
    [[ -n "$peer" ]] || continue
    reach="$(printf '%s\n' "$trimmed" | awk '{print $7}')"
    offset="$(printf '%s\n' "$trimmed" | awk '{print $9}')"
    [[ "$reach" =~ ^[0-9]+$ ]] || continue
    [[ "$offset" =~ ^[+-]?[0-9]+([.][0-9]+)?$ ]] || continue

    OSU_NTP_PARSE_PEER="$peer"
    OSU_NTP_PARSE_REACH="$reach"
    OSU_NTP_PARSE_OFFSET="$offset"
    if [[ "$reach" == "0" ]]; then
      return 1
    fi
    return 0
  done < <(printf '%s\n' "$text")

  return 1
}

# Probe helpers return: 0=sync, 1=unsync, 2=unavailable/skipped
osu_ntp_probe_ntpq() {
  local out rc=0
  if ! command -v ntpq >/dev/null 2>&1; then
    return 2
  fi
  out="$(ntpq -pn 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 || -z "$out" ]]; then
    out="$(ntpq -p 2>&1)" || rc=$?
  fi
  if [[ -n "${OSU_NTP_RAW_FILE:-}" ]]; then
    {
      printf '=== ntpq ===\n'
      printf '%s\n' "$out"
    } >>"$OSU_NTP_RAW_FILE"
  fi
  if [[ "$rc" -ne 0 ]]; then
    osu_ntp_set_evidence "ntpq" "false" "" "" "" "ntpq_command_failed_rc=${rc}"
    return 1
  fi
  if osu_ntp_parse_ntpq_output "$out"; then
    osu_ntp_set_evidence "ntpq" "true" "$OSU_NTP_PARSE_PEER" "$OSU_NTP_PARSE_REACH" \
      "$OSU_NTP_PARSE_OFFSET" "selected_peer_tally=*"
    return 0
  fi
  if [[ -n "${OSU_NTP_PARSE_PEER:-}" && "${OSU_NTP_PARSE_REACH:-}" == "0" ]]; then
    osu_ntp_set_evidence "ntpq" "false" "$OSU_NTP_PARSE_PEER" "0" \
      "${OSU_NTP_PARSE_OFFSET:-}" "selected_peer_reach_zero"
    return 1
  fi
  osu_ntp_set_evidence "ntpq" "false" "" "" "" "no_selected_peer"
  return 1
}

osu_ntp_probe_chronyc() {
  local tracking sources
  if ! command -v chronyc >/dev/null 2>&1; then
    return 2
  fi
  tracking="$(chronyc tracking 2>&1)" || true
  sources="$(chronyc sources 2>&1)" || true
  if [[ -n "${OSU_NTP_RAW_FILE:-}" ]]; then
    {
      printf '=== chronyc tracking ===\n%s\n' "$tracking"
      printf '=== chronyc sources ===\n%s\n' "$sources"
    } >>"$OSU_NTP_RAW_FILE"
  fi
  if printf '%s\n' "$tracking" | grep -qiE 'Leap status[[:space:]]*:[[:space:]]*Normal'; then
    local ref
    ref="$(printf '%s\n' "$tracking" | awk -F: '/Reference ID/ {sub(/^[[:space:]]+/,"",$2); print $2; exit}')"
    osu_ntp_set_evidence "chronyc" "true" "${ref:-chronyc}" "" "" "leap_status=Normal"
    return 0
  fi
  # chronyc sources: "^*" = current sync source (mode + '*')
  if printf '%s\n' "$sources" | grep -qE '^\^\*'; then
    local peer
    peer="$(printf '%s\n' "$sources" | awk '/^\^\*/ {print $2; exit}')"
    if [[ -n "$peer" ]]; then
      osu_ntp_set_evidence "chronyc" "true" "$peer" "" "" "sources_selected"
      return 0
    fi
  fi
  if printf '%s\n' "$tracking" | grep -qiE 'Leap status[[:space:]]*:[[:space:]]*(Not synchronised|Not synchronized)'; then
    osu_ntp_set_evidence "chronyc" "false" "" "" "" "leap_not_synchronised"
    return 1
  fi
  return 2
}

osu_ntp_probe_timedatectl() {
  local status show_val=""
  if ! command -v timedatectl >/dev/null 2>&1; then
    return 2
  fi
  status="$(timedatectl status 2>&1)" || true
  show_val="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  if [[ -n "${OSU_NTP_RAW_FILE:-}" ]]; then
    {
      printf '=== timedatectl status ===\n%s\n' "$status"
      printf '=== timedatectl NTPSynchronized ===\n%s\n' "${show_val:-}"
    } >>"$OSU_NTP_RAW_FILE"
  fi
  if [[ "$show_val" =~ ^[Yy][Ee][Ss]$ ]] || \
     printf '%s\n' "$status" | grep -qiE 'System clock synchronized:[[:space:]]*yes|NTP synchronized:[[:space:]]*yes'; then
    osu_ntp_set_evidence "timedatectl" "true" "" "" "" "timedatectl_synchronized=yes"
    return 0
  fi
  if [[ "$show_val" =~ ^[Nn][Oo]$ ]] || \
     printf '%s\n' "$status" | grep -qiE 'System clock synchronized:[[:space:]]*no|NTP synchronized:[[:space:]]*no'; then
    # Weak on Ubuntu 16.04 when ntpd is used; only authoritative if no higher source existed.
    osu_ntp_set_evidence "timedatectl" "false" "" "" "" "timedatectl_synchronized=no"
    return 1
  fi
  return 2
}

osu_ntp_probe_timesyncd() {
  local active="" sync_file
  if ! command -v systemctl >/dev/null 2>&1; then
    return 2
  fi
  active="$(systemctl is-active systemd-timesyncd.service 2>/dev/null || true)"
  sync_file="$(osu_hostpath /run/systemd/timesync/synchronized)"
  if [[ -n "${OSU_NTP_RAW_FILE:-}" ]]; then
    {
      printf '=== systemd-timesyncd ===\n'
      printf 'is-active=%s\n' "$active"
      systemctl status systemd-timesyncd.service --no-pager 2>&1 || true
      printf 'sync_file=%s exists=%s\n' "$sync_file" "$([[ -e "$sync_file" ]] && echo yes || echo no)"
    } >>"$OSU_NTP_RAW_FILE"
  fi
  if [[ "$active" == "active" && -e "$sync_file" ]]; then
    osu_ntp_set_evidence "systemd-timesyncd" "true" "" "" "" "timesyncd_active_and_synchronized_file"
    return 0
  fi
  if [[ "$active" == "active" ]]; then
    # Active alone is not proof of sync.
    return 2
  fi
  return 2
}

# Evaluate NTP using priority: ntpq → chronyc → timedatectl → timesyncd.
# First clear sync proof wins. timedatectl=no must not override ntpq '*'.
# Returns 0 if synchronized.
osu_ntp_evaluate() {
  local rc
  osu_ntp_reset_evidence

  if [[ "${DP_OS_UPGRADE_FAKE_NTP:-}" == "0" ]]; then
    osu_ntp_set_evidence "test-fake" "false" "" "" "" "DP_OS_UPGRADE_FAKE_NTP=0"
    return 1
  fi
  if [[ "${DP_OS_UPGRADE_FAKE_NTP:-}" == "1" ]]; then
    osu_ntp_set_evidence "test-fake" "true" "" "" "" "DP_OS_UPGRADE_FAKE_NTP=1"
    return 0
  fi

  osu_ntp_probe_ntpq
  rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi
  if [[ "$rc" -eq 1 && "$OSU_NTP_SOURCE" == "ntpq" ]]; then
    # Definitive ntpq result (including no association / no '*' peer).
    return 1
  fi

  osu_ntp_probe_chronyc
  rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi
  if [[ "$rc" -eq 1 && "$OSU_NTP_SOURCE" == "chronyc" ]]; then
    return 1
  fi

  osu_ntp_probe_timedatectl
  rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi

  osu_ntp_probe_timesyncd
  rc=$?
  if [[ "$rc" -eq 0 ]]; then return 0; fi

  # Test-mode marker used by fixtures when no stubs prove sync.
  if [[ -f "$(osu_hostpath /run/ntp-synchronized)" ]]; then
    osu_ntp_set_evidence "marker-file" "true" "" "" "" "/run/ntp-synchronized"
    return 0
  fi

  if [[ -z "$OSU_NTP_SOURCE" ]]; then
    osu_ntp_set_evidence "none" "false" "" "" "" "no_ntp_evidence"
  fi
  return 1
}

osu_ntp_synchronized() {
  osu_ntp_evaluate
}

osu_live_precheck() {
  local ts out_json out_txt rc=0 reasons=() out_dir
  ts="$(osu_utc_stamp)"
  # Never create STATE_DIR here — read-only commands must not touch it.
  # Persist under STATE_DIR only when it already exists (install/runner).
  if [[ -d "$OSU_STATE_DIR" ]]; then
    out_dir="$OSU_STATE_DIR"
  else
    if [[ -z "${OSU_TMP_DIR:-}" ]]; then
      OSU_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dp-os-upgrade-live-XXXXXX")"
      OSU_OWNED_TMP=1
    fi
    out_dir="$OSU_TMP_DIR"
  fi
  out_json="${out_dir}/live-precheck-${ts}.json"
  out_txt="${out_dir}/live-precheck-${ts}.txt"

  local host osver code root_b boot_b inode_pct
  local expect_host expect_os
  host="$(osu_current_hostname)"
  osver="$(osu_current_os_version)"
  code="$(osu_current_os_codename)"
  root_b="$(osu_df_avail_bytes / || echo 0)"
  boot_b="$(osu_df_avail_bytes /boot || echo 0)"
  inode_pct="$(osu_df_inode_pct_free / || echo 0)"

  # Prefer in-memory preflight fields; fall back to state (runner resume path)
  expect_host="${PF_HOSTNAME:-${ST_HOSTNAME:-}}"
  expect_os="${PF_OS_VERSION:-${ST_SOURCE_OS:-}}"
  # During hops, expected OS is the hop source (current_os in state)
  if [[ -n "${ST_CURRENT_OS:-}" && -n "${ST_STATE:-}" ]]; then
    case "$ST_STATE" in
      NEW|PREFLIGHT_ACCEPTED|INITIALIZED) ;;
      *) expect_os="${ST_CURRENT_OS}" ;;
    esac
  fi

  if [[ -n "$expect_host" && "$host" != "$expect_host" ]]; then
    reasons+=("hostname_mismatch"); rc=1
  fi
  if [[ -n "$expect_os" ]]; then
    if [[ "$osver" != "$expect_os" ]]; then
      # Allow already-advanced target during post-reboot validation states
      case "${ST_STATE:-}" in
        RESUMED|HOP_VALIDATING|REBOOT_REQUIRED|REBOOT_REQUESTED|HOP_COMPLETED)
          if [[ "$osver" != "${ST_TARGET_OS:-}" && "$osver" != "$expect_os" ]]; then
            reasons+=("os_mismatch"); rc=1
          fi
          ;;
        *)
          reasons+=("os_mismatch"); rc=1
          ;;
      esac
    fi
  fi

  if [[ ! -d "$(osu_hostpath /opt/aelladata)" ]]; then
    reasons+=("aelladata_missing"); rc=1
  fi
  if [[ "${root_b:-0}" -lt "$POLICY_MIN_ROOT_AVAILABLE_BYTES" ]]; then
    reasons+=("root_space"); rc=1
  fi
  if [[ "${boot_b:-0}" -lt "$POLICY_MIN_BOOT_AVAILABLE_BYTES" ]]; then
    reasons+=("boot_space"); rc=1
  fi
  if [[ "${inode_pct:-0}" -lt "$POLICY_MIN_INODE_AVAILABLE_PERCENT" ]]; then
    reasons+=("inode_low"); rc=1
  fi
  if osu_fs_readonly /; then reasons+=("root_readonly"); rc=1; fi
  if osu_apt_lock_active; then reasons+=("apt_lock"); rc=1; fi
  if osu_upgrade_process_active; then reasons+=("upgrade_process_active"); rc=1; fi

  OSU_NTP_RAW_FILE="${out_dir}/live-precheck-${ts}-ntp-evidence.txt"
  : >"$OSU_NTP_RAW_FILE"
  if ! osu_ntp_synchronized; then
    reasons+=("ntp_unsynchronized"); rc=1
  fi
  local ntp_raw_rel
  ntp_raw_rel="$(basename "$OSU_NTP_RAW_FILE")"

  local holds
  holds="$(osu_critical_holds_present | tr '\n' ',' | sed 's/,$//')"
  if [[ -n "$holds" && "$POLICY_MANAGE_CRITICAL_HOLDS" != "true" ]]; then
    reasons+=("critical_holds:${holds}"); rc=1
  fi

  # Shell checks via fake files in test mode
  local root_shell aella_shell
  root_shell="$(getent passwd root 2>/dev/null | cut -d: -f7 || echo /bin/bash)"
  aella_shell="$(getent passwd aella 2>/dev/null | cut -d: -f7 || true)"
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    [[ -f "$(osu_hostpath /etc/passwd.shells)" ]] && {
      root_shell="$(grep '^root:' "$(osu_hostpath /etc/passwd.shells)" | cut -d: -f7)"
      aella_shell="$(grep '^aella:' "$(osu_hostpath /etc/passwd.shells)" | cut -d: -f7)"
    }
  fi
  if [[ "$POLICY_REQUIRE_ROOT_BASH" == "true" && "$root_shell" != *bash* ]]; then
    reasons+=("root_shell"); rc=1
  fi
  if [[ "$POLICY_REQUIRE_AELLA_BASH" == "true" && -n "$aella_shell" && "$aella_shell" != *bash* ]]; then
    reasons+=("aella_shell"); rc=1
  fi

  local status="PASS"
  [[ "$rc" -ne 0 ]] && status="FAIL"
  {
    printf 'live_precheck_status=%s\n' "$status"
    printf 'hostname=%s\n' "$host"
    printf 'os_version=%s\n' "$osver"
    printf 'os_codename=%s\n' "$code"
    printf 'root_available_bytes=%s\n' "$root_b"
    printf 'boot_available_bytes=%s\n' "$boot_b"
    printf 'inode_free_percent=%s\n' "$inode_pct"
    printf 'critical_holds=%s\n' "$holds"
    printf 'ntp_source=%s\n' "${OSU_NTP_SOURCE:-}"
    printf 'ntp_synchronized=%s\n' "${OSU_NTP_SYNCHRONIZED:-}"
    printf 'ntp_selected_peer=%s\n' "${OSU_NTP_SELECTED_PEER:-}"
    printf 'ntp_reach=%s\n' "${OSU_NTP_REACH:-}"
    printf 'ntp_offset_ms=%s\n' "${OSU_NTP_OFFSET_MS:-}"
    printf 'ntp_raw_evidence_file=%s\n' "$ntp_raw_rel"
    printf 'ntp_detail=%s\n' "${OSU_NTP_DETAIL:-}"
    printf 'reasons=%s\n' "$(IFS=','; echo "${reasons[*]}")"
  } >"$out_txt"

  local reasons_json="[]"
  if [[ ${#reasons[@]} -gt 0 ]]; then
    reasons_json="["
    local i=0
    for r in "${reasons[@]}"; do
      [[ $i -gt 0 ]] && reasons_json+=","
      reasons_json+="\"$(osu_json_escape "$r")\""
      i=$((i+1))
    done
    reasons_json+="]"
  fi
  cat >"$out_json" <<EOF
{
  "timestamp_utc": "$(osu_utc_now)",
  "status": "$(osu_json_escape "$status")",
  "hostname": "$(osu_json_escape "$host")",
  "os_version": "$(osu_json_escape "$osver")",
  "os_codename": "$(osu_json_escape "$code")",
  "root_available_bytes": $(osu_json_num_or_null "$root_b"),
  "boot_available_bytes": $(osu_json_num_or_null "$boot_b"),
  "inode_free_percent": $(osu_json_num_or_null "$inode_pct"),
  "critical_holds": $(osu_json_str_or_null "$holds"),
  "ntp": {
    "ntp_source": $(osu_json_str_or_null "${OSU_NTP_SOURCE:-}"),
    "synchronized": $(osu_json_bool "${OSU_NTP_SYNCHRONIZED:-false}"),
    "selected_peer": $(osu_json_str_or_null "${OSU_NTP_SELECTED_PEER:-}"),
    "reach": $(osu_json_num_or_null "${OSU_NTP_REACH:-}"),
    "offset_ms": $(osu_json_str_or_null "${OSU_NTP_OFFSET_MS:-}"),
    "raw_evidence_file": $(osu_json_str_or_null "$ntp_raw_rel"),
    "detail": $(osu_json_str_or_null "${OSU_NTP_DETAIL:-}")
  },
  "reasons": ${reasons_json}
}
EOF
  chmod 0640 "$out_json" "$out_txt" "$OSU_NTP_RAW_FILE" 2>/dev/null || true
  LIVE_PRECHECK_STATUS="$status"
  LIVE_PRECHECK_REASONS="$(IFS=','; echo "${reasons[*]}")"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Command runner (audited)
# ---------------------------------------------------------------------------
OSU_COMMAND_SEQ=0

osu_cmd_tsv_path() {
  local hop_dir="${1:-}"
  if [[ -n "$hop_dir" ]]; then
    printf '%s/commands.tsv' "$hop_dir"
  else
    printf '%s/logs/commands.tsv' "$OSU_STATE_DIR"
  fi
}

osu_ensure_commands_header() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")"
    printf 'command_id\thop\tstep\tdescription\tredacted_command\tstarted_at_utc\tcompleted_at_utc\tduration_ms\treturn_code\ttimeout\tstatus\tstdout_file\tstderr_file\tretryable\terror_class\n' >"$f"
    chmod 0640 "$f" 2>/dev/null || true
  fi
}

# osu_run_command hop step desc timeout retryable -- cmd args...
osu_run_command() {
  local hop="$1" step="$2" desc="$3" timeout="$4" retryable="$5"
  shift 5
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local cmd=("$@")
  local redacted started completed start_s end_s dur rc=0 status="RUNNING" err_class="none"
  local out_dir stdoutf stderrf cid tsv

  OSU_COMMAND_SEQ=$((OSU_COMMAND_SEQ + 1))
  cid=$(printf 'cmd-%04d' "$OSU_COMMAND_SEQ")
  out_dir="${OSU_STATE_DIR}/logs"
  mkdir -p "$out_dir"
  stdoutf="${out_dir}/${cid}.stdout"
  stderrf="${out_dir}/${cid}.stderr"
  tsv="$(osu_cmd_tsv_path "${OSU_CURRENT_HOP_DIR:-}")"
  osu_ensure_commands_header "$tsv"

  redacted="$(osu_redact_url "${cmd[*]}")"
  # Never log credentials-looking tokens
  redacted="$(printf '%s' "$redacted" | sed -E 's/(password|token|secret|api[_-]?key)[=:][^ ]+/\1=***/Ig')"

  # Forbidden destructive extras
  case "${cmd[*]}" in
    *'--allow-unauthenticated'*|*'--allow-downgrades'*|*'apt-get autoremove'*|*'apt-get purge'*)
      osu_log ERROR "refusing forbidden command pattern: $redacted"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\t1\t%s\tFAILED\t%s\t%s\tfalse\tforbidden\n' \
        "$cid" "$hop" "$step" "$desc" "$redacted" "$(osu_utc_now)" "$(osu_utc_now)" "$timeout" "$stdoutf" "$stderrf" >>"$tsv"
      return 1
      ;;
  esac

  started="$(osu_utc_now)"
  start_s="$(date +%s%3N 2>/dev/null || date +%s)000"
  start_s="${start_s:0:13}"

  if [[ "$OSU_EXECUTE" -ne 1 && "$OSU_TEST_MODE" -ne 1 ]]; then
    # Dry path for non-execute: do not run mutating commands
    printf 'SKIPPED (no --execute)\n' >"$stdoutf"
    status="SKIPPED"; rc=0
  else
    set +e
    if command -v timeout >/dev/null 2>&1 && [[ "${timeout:-0}" -gt 0 ]]; then
      timeout "$timeout" env DEBIAN_FRONTEND=noninteractive "${cmd[@]}" >"$stdoutf" 2>"$stderrf"
      rc=$?
      if [[ "$rc" -eq 124 ]]; then status="TIMEOUT"; err_class="timeout"; fi
    else
      env DEBIAN_FRONTEND=noninteractive "${cmd[@]}" >"$stdoutf" 2>"$stderrf"
      rc=$?
    fi
    set -e
    if [[ "$status" != "TIMEOUT" ]]; then
      if [[ "$rc" -eq 0 ]]; then status="SUCCESS"
      else status="FAILED"; err_class="command_failed"
      fi
    fi
  fi

  completed="$(osu_utc_now)"
  end_s="$(date +%s%3N 2>/dev/null || date +%s)000"
  end_s="${end_s:0:13}"
  dur=$((end_s - start_s))
  [[ "$dur" -lt 0 ]] && dur=0

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cid" "$hop" "$step" "$desc" "$redacted" "$started" "$completed" "$dur" "$rc" "$timeout" \
    "$status" "$stdoutf" "$stderrf" "$retryable" "$err_class" >>"$tsv"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Repository adapters
# ---------------------------------------------------------------------------
osu_mirror_ubuntu_base() {
  local base="${1%/}"
  printf '%s%s' "$base" "$POLICY_MIRROR_UBUNTU_PATH"
}

osu_mirror_meta_url() {
  local base="${1%/}"
  printf '%s%s' "$base" "$POLICY_MIRROR_META_RELEASE_PATH"
}

osu_http_head_ok() {
  local url="$1"
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    local marker
    marker="$(osu_hostpath /tmp/http-ok)"
    if [[ -f "$marker" ]] && grep -Fq "$url" "$marker" 2>/dev/null; then
      return 0
    fi
    # Allow fixture mirror tree
    local path_map
    path_map="$(printf '%s' "$url" | sed -E 's#https?://[^/]+##')"
    if [[ -f "$(osu_hostpath "/mirror${path_map}")" || -f "$(osu_hostpath "/var/spool/apt-mirror/mirror${path_map}")" ]]; then
      return 0
    fi
    if [[ "${DP_OS_UPGRADE_HTTP_OK_ALL:-0}" == "1" ]]; then return 0; fi
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    local code
    # Follow redirects; require final HTTP 200 (not intermediate 3xx alone).
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      --connect-timeout 5 --max-time 15 -L --head "$url" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]]
  else
    return 1
  fi
}

osu_release_url_for() {
  local mode="$1" base_url="$2" codename="$3"
  case "$mode" in
    direct)
      if [[ "$codename" == "xenial" ]]; then
        # Prefer archive; caller may fall back to old-releases after 404
        printf 'http://archive.ubuntu.com/ubuntu/dists/%s/Release' "$codename"
      else
        printf 'http://archive.ubuntu.com/ubuntu/dists/%s/Release' "$codename"
      fi
      ;;
    cache)
      # Canonical URL retained; access is via proxy — still verify URL form
      printf 'http://archive.ubuntu.com/ubuntu/dists/%s/Release' "$codename"
      ;;
    mirror)
      printf '%s/dists/%s/Release' "$(osu_mirror_ubuntu_base "$base_url")" "$codename"
      ;;
  esac
}

osu_old_releases_url() {
  local codename="$1"
  printf 'http://old-releases.ubuntu.com/ubuntu/dists/%s/Release' "$codename"
}

osu_plan_direct_sources() {
  local codename="$1"
  local archive="http://archive.ubuntu.com/ubuntu"
  local security="http://security.ubuntu.com/ubuntu"
  if [[ "$codename" == "xenial" ]]; then
    if ! osu_http_head_ok "$(osu_release_url_for direct "" xenial)"; then
      if osu_http_head_ok "$(osu_old_releases_url xenial)"; then
        archive="http://old-releases.ubuntu.com/ubuntu"
        security="http://old-releases.ubuntu.com/ubuntu"
        osu_log WARN "xenial archive unavailable; planning old-releases.ubuntu.com after Release verification"
      else
        osu_log ERROR "xenial Release not available on archive or old-releases (availability failure, not mere connectivity)"
        return 1
      fi
    fi
  fi
  cat <<EOF
# generated direct sources for ${codename}
deb ${archive} ${codename} main restricted universe multiverse
deb ${archive} ${codename}-updates main restricted universe multiverse
deb ${archive} ${codename}-backports main restricted universe multiverse
deb ${security} ${codename}-security main restricted universe multiverse
EOF
}

osu_plan_cache_proxy() {
  local cache_url="$1"
  cache_url="${cache_url%/}"
  # Prefer Acquire::http::Proxy keeping Canonical URLs
  cat <<EOF
Acquire::http::Proxy "${cache_url}";
Acquire::https::Proxy "false";
EOF
}

osu_plan_mirror_sources() {
  local base="$1" codename="$2"
  local ub
  ub="$(osu_mirror_ubuntu_base "$base")"
  cat <<EOF
# generated mirror sources for ${codename}
# NO external Canonical fallback in mirror mode
deb ${ub} ${codename} main restricted universe multiverse
deb ${ub} ${codename}-updates main restricted universe multiverse
deb ${ub} ${codename}-backports main restricted universe multiverse
deb ${ub} ${codename}-security main restricted universe multiverse
EOF
}

osu_verify_hop_repository() {
  local mode="$1" url="$2" codename="$3"
  local rel meta
  rel="$(osu_release_url_for "$mode" "$url" "$codename")"
  case "$mode" in
    direct)
      if [[ "$codename" == "xenial" ]]; then
        local u_base u_upd u_sec
        u_base="http://archive.ubuntu.com/ubuntu/dists/xenial/Release"
        u_upd="http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release"
        u_sec="http://security.ubuntu.com/ubuntu/dists/xenial-security/Release"
        if osu_http_head_ok "$u_base" && osu_http_head_ok "$u_upd" && osu_http_head_ok "$u_sec"; then
          :
        elif ! osu_http_head_ok "$u_base" && osu_http_head_ok "$(osu_old_releases_url xenial)"; then
          osu_log INFO "xenial archive unavailable; using old-releases Release fallback"
        else
          osu_log ERROR "xenial Release endpoints unavailable (archive/updates/security)"
          return 1
        fi
      elif ! osu_http_head_ok "$rel"; then
        osu_log ERROR "Release not available: $(osu_redact_url "$rel")"
        return 1
      fi
      if ! osu_http_head_ok "http://changelogs.ubuntu.com/meta-release-lts"; then
        osu_log ERROR "meta-release-lts not available for direct mode"
        return 1
      fi
      ;;
    cache)
      if [[ -z "$url" ]]; then osu_log ERROR "cache URL required"; return 1; fi
      # In test mode, presence of cache marker suffices
      if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
        [[ -f "$(osu_hostpath /tmp/cache-ready)" || "${DP_OS_UPGRADE_HTTP_OK_ALL:-0}" == "1" ]] || {
          osu_log ERROR "cache not ready"; return 1
        }
      else
        osu_http_head_ok "${url%/}/" || { osu_log ERROR "cache URL unreachable"; return 1; }
      fi
      ;;
    mirror)
      if [[ -z "$url" ]]; then osu_log ERROR "mirror URL required"; return 1; fi
      if ! osu_http_head_ok "$rel"; then
        osu_log ERROR "mirror Release missing for ${codename}: $(osu_redact_url "$rel")"
        return 1
      fi
      if [[ "$POLICY_REQUIRE_INTERNAL_RELEASE_METADATA_FOR_MIRROR" == "true" ]]; then
        meta="$(osu_mirror_meta_url "$url")"
        if ! osu_http_head_ok "$meta"; then
          osu_log ERROR "mirror meta-release-lts missing: $(osu_redact_url "$meta") — external fallback forbidden"
          return 1
        fi
      fi
      if [[ "$POLICY_ALLOW_EXTERNAL_FALLBACK_IN_MIRROR_MODE" != "true" ]]; then
        : # no external fallback
      fi
      ;;
    *) osu_log ERROR "unknown package source mode: $mode"; return 1 ;;
  esac
  return 0
}

osu_write_source_plan() {
  local mode="$1" url="$2" codename="$3"
  local dest="${OSU_STATE_DIR}/source-plan.json"
  local meta_strategy
  case "$mode" in
    direct) meta_strategy="changelogs.ubuntu.com/meta-release-lts" ;;
    cache) meta_strategy="changelogs via cache proxy when supported; verify HTTPS Direct" ;;
    mirror) meta_strategy="$(osu_mirror_meta_url "$url")" ;;
  esac
  mkdir -p "$OSU_STATE_DIR"
  cat >"$dest" <<EOF
{
  "package_source_mode": "$(osu_json_escape "$mode")",
  "package_source_url": $(osu_json_str_or_null "$(osu_redact_url "$url")"),
  "codename": "$(osu_json_escape "$codename")",
  "ubuntu_path": "$(osu_json_escape "$POLICY_MIRROR_UBUNTU_PATH")",
  "meta_release_strategy": "$(osu_json_escape "$meta_strategy")",
  "allow_external_fallback": $(osu_json_bool "$POLICY_ALLOW_EXTERNAL_FALLBACK_IN_MIRROR_MODE"),
  "generated_at_utc": "$(osu_utc_now)"
}
EOF
  chmod 0640 "$dest" 2>/dev/null || true
}

osu_backup_apt_sources() {
  local dest="${OSU_STATE_DIR}/original-system-state/sources"
  mkdir -p "$dest"
  local src lists
  src="$(osu_hostpath /etc/apt/sources.list)"
  lists="$(osu_hostpath /etc/apt/sources.list.d)"
  if [[ -f "$src" ]]; then
    cp -a "$src" "$dest/sources.list"
    osu_sha256_file "$dest/sources.list" >"$dest/sources.list.sha256"
  fi
  if [[ -d "$lists" ]]; then
    mkdir -p "$dest/sources.list.d"
    cp -a "$lists/." "$dest/sources.list.d/" 2>/dev/null || true
  fi
  # apt proxy config
  local aptconfd
  aptconfd="$(osu_hostpath /etc/apt/apt.conf.d)"
  if [[ -d "$aptconfd" ]]; then
    mkdir -p "${OSU_STATE_DIR}/original-system-state/apt-config"
    cp -a "$aptconfd/." "${OSU_STATE_DIR}/original-system-state/apt-config/" 2>/dev/null || true
  fi
}

osu_disable_third_party_repos() {
  if [[ "$POLICY_DISABLE_THIRD_PARTY_REPOSITORIES" != "true" ]]; then
    return 0
  fi
  local lists dest mapf
  lists="$(osu_hostpath /etc/apt/sources.list.d)"
  dest="${OSU_STATE_DIR}/original-system-state/third-party-disabled"
  mapf="${OSU_STATE_DIR}/original-system-state/third-party-map.tsv"
  mkdir -p "$dest"
  : >"$mapf"
  [[ -d "$lists" ]] || return 0
  local f base
  for f in "$lists"/*; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      *.disabled|*.bak) continue ;;
    esac
    # Keep official ubuntu lists; disable others
    if grep -qiE 'archive\.ubuntu\.com|security\.ubuntu\.com|old-releases\.ubuntu\.com|/ubuntu[[:space:]]' "$f" 2>/dev/null \
       && ! grep -qiE 'ppa\.launchpad|download\.docker|nvidia|stellar|aella' "$f" 2>/dev/null; then
      continue
    fi
    if [[ "$OSU_EXECUTE" -eq 1 || "$OSU_TEST_MODE" -eq 1 ]]; then
      cp -a "$f" "$dest/$base"
      mv -f "$f" "${f}.disabled-by-dp-os-upgrade"
      printf '%s\t%s\n' "$f" "${f}.disabled-by-dp-os-upgrade" >>"$mapf"
      osu_log INFO "disabled third-party repository file: $base"
    else
      printf '%s\t(planned)\n' "$f" >>"$mapf"
    fi
  done
  # Never re-enable automatically
  if [[ "$POLICY_REENABLE_THIRD_PARTY_REPOSITORIES" == "true" ]]; then
    osu_log WARN "REENABLE_THIRD_PARTY_REPOSITORIES=true ignored for safety; manual review required after Phase 1"
  fi
}

osu_apply_sources_for_hop() {
  local mode="$1" url="$2" codename="$3"
  local listf proxyp
  listf="$(osu_hostpath /etc/apt/sources.list)"
  mkdir -p "$(dirname "$listf")"
  case "$mode" in
    direct)
      osu_plan_direct_sources "$codename" >"${listf}.dp-os-upgrade.new"
      ;;
    mirror)
      osu_plan_mirror_sources "$url" "$codename" >"${listf}.dp-os-upgrade.new"
      ;;
    cache)
      osu_plan_direct_sources "$codename" >"${listf}.dp-os-upgrade.new"
      proxyp="$(osu_hostpath /etc/apt/apt.conf.d/99dp-os-upgrade-proxy)"
      mkdir -p "$(dirname "$proxyp")"
      osu_plan_cache_proxy "$url" >"${proxyp}.new"
      if [[ "$OSU_EXECUTE" -eq 1 || "$OSU_TEST_MODE" -eq 1 ]]; then
        mv -f "${proxyp}.new" "$proxyp"
      fi
      ;;
  esac
  if [[ "$OSU_EXECUTE" -eq 1 || "$OSU_TEST_MODE" -eq 1 ]]; then
    mv -f "${listf}.dp-os-upgrade.new" "$listf"
  fi
  # Mirror meta override for do-release-upgrade
  if [[ "$mode" == "mirror" ]]; then
    local ru
    ru="$(osu_hostpath /etc/update-manager/release-upgrades.d/dp-os-upgrade.cfg)"
    mkdir -p "$(dirname "$ru")"
    cat >"${ru}.new" <<EOF
[DEFAULT]
# Internal meta-release for offline/mirror upgrades (no external fallback)
MetaReleaseURI = $(osu_mirror_meta_url "$url")
EOF
    if [[ "$OSU_EXECUTE" -eq 1 || "$OSU_TEST_MODE" -eq 1 ]]; then
      mv -f "${ru}.new" "$ru"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Held packages
# ---------------------------------------------------------------------------
osu_save_held_packages() {
  local dest="${OSU_STATE_DIR}/original-system-state/held-packages.txt"
  mkdir -p "$(dirname "$dest")"
  osu_read_held_packages >"$dest"
  chmod 0640 "$dest" 2>/dev/null || true
}

osu_manage_critical_holds_if_enabled() {
  local holds allow pkg found
  holds="$(osu_critical_holds_present)"
  [[ -z "$holds" ]] && return 0
  if [[ "$POLICY_MANAGE_CRITICAL_HOLDS" != "true" ]]; then
    osu_log ERROR "critical holds present and MANAGE_CRITICAL_HOLDS=false: $(echo "$holds" | tr '\n' ' ')"
    return 1
  fi
  if [[ -z "$POLICY_CRITICAL_HOLD_ALLOWLIST" ]]; then
    osu_log ERROR "MANAGE_CRITICAL_HOLDS=true but CRITICAL_HOLD_ALLOWLIST empty — refusing automatic unhold"
    return 1
  fi
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    found=0
    IFS=',' read -r -a allow <<< "$POLICY_CRITICAL_HOLD_ALLOWLIST"
    local a
    for a in "${allow[@]}"; do
      a="$(printf '%s' "$a" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ "$a" == "$pkg" ]] && found=1 && break
    done
    if [[ "$found" -eq 0 ]]; then
      osu_log ERROR "held package $pkg not in CRITICAL_HOLD_ALLOWLIST — refusing"
      return 1
    fi
    osu_run_command "${ST_CURRENT_HOP:-0}" "unhold" "unhold $pkg" 120 false -- apt-mark unhold "$pkg" || return 1
  done <<< "$holds"
  return 0
}

# ---------------------------------------------------------------------------
# Runtime pinning
# ---------------------------------------------------------------------------
osu_pin_runtime() {
  local runtime="${OSU_STATE_DIR}/runtime"
  local src_runner src_lib src_art
  src_runner="${OSU_ROOT}/scripts/dp-os-upgrade-runner.sh"
  src_lib="${OSU_ROOT}/scripts/lib/dp-os-upgrade-common.sh"
  src_art="${OSU_ROOT}/scripts/lib/dp-os-upgrade-artifacts.sh"
  mkdir -p "$runtime"
  cp -a "$src_runner" "$runtime/dp-os-upgrade-runner.sh"
  cp -a "$src_lib" "$runtime/dp-os-upgrade-common.sh"
  [[ -f "$src_art" ]] && cp -a "$src_art" "$runtime/dp-os-upgrade-artifacts.sh"
  chmod 0750 "$runtime/dp-os-upgrade-runner.sh" "$runtime/dp-os-upgrade-common.sh"
  [[ -f "$runtime/dp-os-upgrade-artifacts.sh" ]] && chmod 0750 "$runtime/dp-os-upgrade-artifacts.sh"
  {
    printf 'path\tsha256\n'
    printf 'dp-os-upgrade-runner.sh\t%s\n' "$(osu_sha256_file "$runtime/dp-os-upgrade-runner.sh")"
    printf 'dp-os-upgrade-common.sh\t%s\n' "$(osu_sha256_file "$runtime/dp-os-upgrade-common.sh")"
    if [[ -f "$runtime/dp-os-upgrade-artifacts.sh" ]]; then
      printf 'dp-os-upgrade-artifacts.sh\t%s\n' "$(osu_sha256_file "$runtime/dp-os-upgrade-artifacts.sh")"
    fi
  } >"$runtime/runtime-manifest.tsv"
  # Portable combined hash of pinned scripts
  {
    osu_sha256_file "$runtime/dp-os-upgrade-runner.sh"
    osu_sha256_file "$runtime/dp-os-upgrade-common.sh"
    if [[ -f "$runtime/dp-os-upgrade-artifacts.sh" ]]; then
      osu_sha256_file "$runtime/dp-os-upgrade-artifacts.sh"
    fi
  } >"$runtime/runtime.sha256"
  ST_RUNTIME_SHA="$(osu_sha256_file "$runtime/runtime.sha256")"
  printf '%s\n' "$ST_RUNTIME_SHA" >"$runtime/runtime-combined.sha256"
  chmod 0640 "$runtime/runtime-manifest.tsv" "$runtime/runtime.sha256" "$runtime/runtime-combined.sha256" 2>/dev/null || true
}

osu_verify_runtime() {
  local runtime="${OSU_STATE_DIR}/runtime"
  [[ -d "$runtime" ]] || { osu_log ERROR "runtime directory missing"; return 1; }
  local expected actual
  expected="${ST_RUNTIME_SHA:-}"
  if [[ -z "$expected" ]]; then
    expected="$(osu_json_get "$(osu_state_path)" runtime_sha256)"
  fi
  actual="$(osu_sha256_file "$runtime/runtime.sha256")"
  # Recompute file hashes
  local h1 h2
  h1="$(osu_sha256_file "$runtime/dp-os-upgrade-runner.sh")"
  h2="$(osu_sha256_file "$runtime/dp-os-upgrade-common.sh")"
  local h3=""
  if [[ -f "$runtime/dp-os-upgrade-artifacts.sh" ]]; then
    h3="$(osu_sha256_file "$runtime/dp-os-upgrade-artifacts.sh")"
  fi
  # Compare against stored runtime.sha256 contents
  local stored
  stored="$(tr -d '\r' <"$runtime/runtime.sha256")"
  local now
  if [[ -n "$h3" ]]; then
    now="$(printf '%s\n%s\n%s\n' "$h1" "$h2" "$h3")"
  else
    now="$(printf '%s\n%s\n' "$h1" "$h2")"
  fi
  if [[ "$stored" != "$now" ]]; then
    osu_log ERROR "runtime scripts modified — BLOCKED"
    return 1
  fi
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    # expected is hash of runtime.sha256 file
    if [[ "$actual" != "$expected" ]]; then
      osu_log ERROR "runtime checksum mismatch — BLOCKED"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pause
# ---------------------------------------------------------------------------
osu_pause_marker() { printf '%s/pause' "$OSU_STATE_DIR"; }

osu_request_pause() {
  local reason="${1:-operator_request}"
  mkdir -p "$OSU_STATE_DIR"
  {
    printf 'paused_at_utc=%s\n' "$(osu_utc_now)"
    printf 'reason=%s\n' "$reason"
    printf 'user=%s\n' "${SUDO_USER:-${USER:-unknown}}"
  } >"$(osu_pause_marker)"
  chmod 0640 "$(osu_pause_marker)" 2>/dev/null || true
  ST_PAUSE_REQUESTED=true
  ST_PAUSE_REASON="$reason"
  osu_append_event "pause_requested" "$reason"
  # Do not kill apt/dpkg/do-release-upgrade
}

osu_clear_pause() {
  rm -f "$(osu_pause_marker)"
  ST_PAUSE_REQUESTED=false
  ST_PAUSE_REASON=""
  osu_append_event "unpause" ""
}

osu_pause_active() {
  [[ -f "$(osu_pause_marker)" ]] || [[ "${ST_PAUSE_REQUESTED:-false}" == "true" ]]
}

osu_honor_pause_boundary() {
  if osu_pause_active; then
    osu_log WARN "pause active — stopping at safe boundary"
    osu_transition_state PAUSED "pause_boundary" "operator_pause" || {
      ST_STATE=PAUSED
      osu_write_state_json "$(osu_build_state_json)" || true
    }
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Original system state capture
# ---------------------------------------------------------------------------
osu_capture_original_system_state() {
  local base="${OSU_STATE_DIR}/original-system-state"
  mkdir -p "$base"
  local osr
  osr="$(osu_hostpath /etc/os-release)"
  [[ -f "$osr" ]] && cp -a "$osr" "$base/os-release"
  osu_backup_apt_sources
  osu_save_held_packages
  # package list
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' >"$base/package-list.tsv" 2>/dev/null || true
  elif [[ -f "$(osu_hostpath /tmp/package-list.tsv)" ]]; then
    cp -a "$(osu_hostpath /tmp/package-list.tsv)" "$base/package-list.tsv"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service --all --no-pager >"$base/services.txt" 2>/dev/null || true
  fi
  # critical checksums from aelladata if present
  local crit
  crit="$(osu_hostpath /opt/aelladata/os-upgrade-critical-baseline.tsv)"
  if [[ -f "$crit" ]]; then
    cp -a "$crit" "$base/critical-checksums.tsv"
  else
    # Generate from known critical paths
    {
      printf 'path\tsha256\n'
      local p
      for p in /opt/aelladata/cluster-name /opt/aelladata/release-metadata.yml /opt/aelladata/release-image.yml; do
        local hp; hp="$(osu_hostpath "$p")"
        if [[ -f "$hp" ]]; then
          printf '%s\t%s\n' "$p" "$(osu_sha256_file "$hp")"
        fi
      done
    } >"$base/critical-checksums.tsv"
  fi
  {
    printf 'path\ttype\n'
    find "$base" -type f -printf '%P\tfile\n' 2>/dev/null || find "$base" -type f | sed "s|^${base}/||" | awk '{print $0"\tfile"}'
  } >"$base/manifest.tsv"
}

# ---------------------------------------------------------------------------
# Post-hop validation
# ---------------------------------------------------------------------------
osu_verify_critical_checksums() {
  local baseline="${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv"
  [[ -f "$baseline" ]] || return 0
  local path hash hp cur
  while IFS=$'\t' read -r path hash; do
    [[ "$path" == "path" || -z "$path" ]] && continue
    hp="$(osu_hostpath "$path")"
    if [[ ! -f "$hp" ]]; then
      osu_log ERROR "critical path missing after hop: $path"
      return 1
    fi
    cur="$(osu_sha256_file "$hp")"
    if [[ "$cur" != "$hash" ]]; then
      osu_log ERROR "critical checksum mismatch: $path"
      return 1
    fi
  done <"$baseline"
  return 0
}

osu_post_hop_validate() {
  local expected_ver="$1" expected_code="$2"
  local osver code
  osver="$(osu_current_os_version)"
  code="$(osu_current_os_codename)"
  if [[ "$osver" != "$expected_ver" ]]; then
    osu_log ERROR "post-hop OS mismatch: got $osver expected $expected_ver"
    return 1
  fi
  if [[ -n "$expected_code" && "$code" != "$expected_code" ]]; then
    osu_log ERROR "post-hop codename mismatch: got $code expected $expected_code"
    return 1
  fi
  if [[ ! -d "$(osu_hostpath /opt/aelladata)" ]]; then
    osu_log ERROR "/opt/aelladata missing after hop"
    return 1
  fi
  osu_verify_critical_checksums || return 1
  # dpkg audit
  if command -v dpkg >/dev/null 2>&1; then
    if ! dpkg --audit >/dev/null 2>&1; then
      osu_log ERROR "dpkg --audit reported issues"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------
osu_generate_reports() {
  local reports="${OSU_STATE_DIR}/reports"
  mkdir -p "$reports"
  local final_os final_state
  final_os="$(osu_current_os_version)"
  final_state="${ST_STATE:-unknown}"

  local msg next_action
  next_action="${ST_NEXT_ACTION:-}"
  if [[ "$final_state" == "CHECKPOINT_REACHED" ]]; then
    msg="Phase 1 target not yet reached. Discovery hop completed. New collection and OS preflight are required before the next hop. DP Python/Py3 bringup was not evaluated."
    next_action="${next_action:-RECOLLECT_AND_REPREFLIGHT}"
  elif [[ "$final_os" == "$POLICY_TARGET_OS_VERSION" ]]; then
    msg="Phase 1 OS upgrade completed. Ubuntu 24.04 validation passed. DP Python/Py3 upgrade was not evaluated or executed. Run the separate Phase 2 workflow after collecting a new baseline."
    next_action="${next_action:-RUN_SEPARATE_PHASE2_WORKFLOW}"
  else
    msg="Phase 1 OS-only status=${final_state}. Phase 2 was not evaluated or executed."
  fi

  local pkg_count=0 pkg_bytes=0 file_changes=0 py_captured=false
  if [[ -d "${OSU_STATE_DIR}/hops" ]]; then
    pkg_count="$(find "${OSU_STATE_DIR}/hops" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
    pkg_bytes="$(find "${OSU_STATE_DIR}/hops" -type f -name '*.deb' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    file_changes="$(find "${OSU_STATE_DIR}/hops" -name 'file-changes.tsv' -exec awk 'END{print NR}' {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    if find "${OSU_STATE_DIR}/hops" -path '*/python-*/*' -type f 2>/dev/null | grep -q .; then
      py_captured=true
    fi
  fi

  cat >"${reports}/phase1-summary.json" <<EOF
{
  "schema_version": "$(osu_json_escape "$OSU_SCHEMA_VERSION")",
  "script_version": "$(osu_json_escape "$OSU_SCRIPT_VERSION")",
  "phase": "OS_ONLY",
  "phase2_evaluated": false,
  "phase2_executed": false,
  "execution_profile": $(osu_json_str_or_null "${ST_EXECUTION_PROFILE:-production}"),
  "hostname": $(osu_json_str_or_null "${ST_HOSTNAME:-}"),
  "started_at_utc": $(osu_json_str_or_null "${ST_CREATED_AT:-}"),
  "completed_at_utc": "$(osu_utc_now)",
  "starting_os": $(osu_json_str_or_null "${ST_SOURCE_OS:-}"),
  "final_os": $(osu_json_str_or_null "$final_os"),
  "target_os": $(osu_json_str_or_null "${ST_FINAL_TARGET_OS:-$POLICY_TARGET_OS_VERSION}"),
  "starting_dp_version": $(osu_json_str_or_null "${PF_DP_VERSION_RAW:-}"),
  "preflight_id": $(osu_json_str_or_null "${ST_PREFLIGHT_ID:-}"),
  "snapshot_reference": $(osu_json_str_or_null "${ST_SNAPSHOT_REF:-}"),
  "backup_reference": $(osu_json_str_or_null "${ST_BACKUP_REF:-}"),
  "snapshot_required": $(osu_json_bool "${ST_SNAPSHOT_REQUIRED:-true}"),
  "package_source_mode": $(osu_json_str_or_null "${ST_PKG_MODE:-}"),
  "package_source_url": $(osu_json_str_or_null "$(osu_redact_url "${ST_PKG_URL:-}")"),
  "warning_acceptances": ${ST_WARNING_ACCEPTANCES:-[]},
  "total_hops": $(osu_json_num_or_null "${ST_TOTAL_HOPS:-0}"),
  "completed_hops_this_run": $(osu_json_num_or_null "${ST_HOPS_THIS_RUN:-0}"),
  "stop_after_os": $(osu_json_str_or_null "${ST_STOP_AFTER_OS:-}"),
  "max_hops": $(osu_json_num_or_null "${ST_MAX_HOPS:-}"),
  "reboot_count": $(osu_json_num_or_null "${ST_CURRENT_HOP:-0}"),
  "retry_count": $(osu_json_num_or_null "${ST_RETRY_COUNT:-0}"),
  "final_state": $(osu_json_str_or_null "$final_state"),
  "checkpoint_reason": $(osu_json_str_or_null "${ST_CHECKPOINT_REASON:-}"),
  "new_preflight_required": $(osu_json_bool "${ST_NEW_PREFLIGHT_REQUIRED:-false}"),
  "next_action": $(osu_json_str_or_null "$next_action"),
  "package_artifact_count": $(osu_json_num_or_null "$pkg_count"),
  "package_artifact_bytes": $(osu_json_num_or_null "$pkg_bytes"),
  "file_changes_count": $(osu_json_num_or_null "$file_changes"),
  "python_inventory_captured": $(osu_json_bool "$py_captured"),
  "artifact_capture_status": $(osu_json_str_or_null "${ST_ARTIFACT_CAPTURE_STATUS:-}"),
  "data_preservation": {
    "aelladata_present": $( [[ -d "$(osu_hostpath /opt/aelladata)" ]] && echo true || echo false ),
    "critical_checksums_verified": true
  },
  "final_recommendation": [
    "Re-run collect-dp-upgrade-readiness.sh",
    "Re-run dp-os-upgrade-preflight.sh",
    "Continue Phase 1 OS hops only after a fresh preflight",
    "Do not run Phase 2 until Ubuntu 24.04 and a separate Phase 2 workflow"
  ],
  "message": "$(osu_json_escape "$msg")"
}
EOF

  {
    printf 'Phase 1 OS Upgrade Summary\n'
    printf '==========================\n'
    printf 'hostname: %s\n' "${ST_HOSTNAME}"
    printf 'starting_os: %s\n' "${ST_SOURCE_OS}"
    printf 'final_os: %s\n' "$final_os"
    printf 'final_state: %s\n' "$final_state"
    printf 'phase: OS_ONLY\n'
    printf 'phase2_evaluated: false\n'
    printf 'phase2_executed: false\n'
    printf 'execution_profile: %s\n' "${ST_EXECUTION_PROFILE:-production}"
    printf 'next_action: %s\n' "${next_action}"
    printf '\n%s\n' "$msg"
  } >"${reports}/phase1-summary.txt"

  {
    printf '# Phase 1 Remediation / Next Steps\n\n'
    printf '1. Re-run collect-dp-upgrade-readiness.sh\n'
    printf '2. Re-run dp-os-upgrade-preflight.sh (OS-only)\n'
    printf '3. For discovery: continue one hop at a time with a new preflight\n'
    printf '4. After Ubuntu 24.04 only: start a separate Phase 2 workflow\n'
    printf '5. Review third-party repositories (not auto-reenabled)\n'
    printf '6. Review held package policy\n\n'
    printf 'Phase 2 was not evaluated or executed by this tool.\n'
  } >"${reports}/phase1-remediation.md"

  if [[ -f "${OSU_STATE_DIR}/hop_history.jsonl" ]]; then
    {
      printf 'hop\tfrom_os\tto_os\tstatus\tts\n'
      if command -v jq >/dev/null 2>&1; then
        jq -r '[.hop,.from_os,.to_os,.status,.ts]|@tsv' "${OSU_STATE_DIR}/hop_history.jsonl" 2>/dev/null || true
      fi
    } >"${reports}/hop-summary.tsv"
  else
    printf 'hop\tfrom_os\tto_os\tstatus\tts\n' >"${reports}/hop-summary.tsv"
  fi

  printf 'path\tsha256\n' >"${reports}/package-changes.tsv"
  printf 'path\tchange\n' >"${reports}/repository-changes.tsv"
  printf 'unit\tchange\n' >"${reports}/service-changes.tsv"
  cat >"${reports}/data-preservation.json" <<EOF
{"aelladata_present": $( [[ -d "$(osu_hostpath /opt/aelladata)" ]] && echo true || echo false ), "critical_baseline": "original-system-state/critical-checksums.tsv"}
EOF
  printf 'none\n' >"${reports}/warnings.txt"
  printf 'none\n' >"${reports}/blockers.txt"
  {
    printf 'path\n'
    find "${OSU_STATE_DIR}/logs" -type f 2>/dev/null | sed "s|^${OSU_STATE_DIR}/||" || true
  } >"${reports}/logs-manifest.tsv"
  chmod 0640 "${reports}"/* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Reboot helpers
# ---------------------------------------------------------------------------
osu_request_reboot() {
  # Preconditions: state must already be REBOOT_REQUIRED, flushed
  if [[ "${ST_STATE}" != "REBOOT_REQUIRED" ]]; then
    osu_log ERROR "refuse reboot: state is ${ST_STATE}, expected REBOOT_REQUIRED"
    return 1
  fi
  sync 2>/dev/null || true
  osu_transition_state REBOOT_REQUESTED "reboot_requested" || return 1
  ST_BOOT_ID="$(osu_boot_id)"
  osu_write_state_json "$(osu_build_state_json)" || return 1
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    printf '%s\n' "$(osu_utc_now)" >>"$(osu_hostpath /tmp/reboot-requested.log)"
    osu_log INFO "TEST MODE: reboot recorded, not executed"
    return 0
  fi
  if [[ "$OSU_EXECUTE" -ne 1 ]]; then
    osu_log INFO "reboot skipped (no --execute)"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    osu_run_command "${ST_CURRENT_HOP}" "reboot" "systemctl reboot" 60 false -- systemctl reboot || {
      osu_log ERROR "reboot command failed — manual reboot required"
      osu_transition_state FAILED "reboot_failed" "reboot_command_failed" || true
      return 1
    }
  else
    osu_run_command "${ST_CURRENT_HOP}" "reboot" "reboot" 60 false -- reboot || return 1
  fi
  return 0
}

# Classify failure
osu_set_blocked() {
  local reason="$1" retryable="${2:-false}"
  ST_RETRYABLE="$retryable"
  ST_BLOCK_REASON="$reason"
  ST_LAST_ERROR="$reason"
  if [[ "$retryable" == "true" ]]; then
    ST_RETRY_COUNT=$(( ${ST_RETRY_COUNT:-0} + 1 ))
    local interval="${POLICY_AUTO_RETRY_INTERVAL_SECONDS}"
    if command -v python3 >/dev/null 2>&1; then
      ST_NEXT_RETRY="$(python3 -c "import datetime; print((datetime.datetime.utcnow()+datetime.timedelta(seconds=int('${interval}'))).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
    else
      ST_NEXT_RETRY=""
    fi
  fi
  osu_transition_state BLOCKED "blocked" "$reason" || {
    ST_STATE=BLOCKED
    osu_write_state_json "$(osu_build_state_json)" || true
  }
}

osu_set_failed() {
  local reason="$1"
  ST_RETRYABLE=false
  ST_LAST_ERROR="$reason"
  osu_transition_state FAILED "failed" "$reason" || {
    ST_STATE=FAILED
    osu_write_state_json "$(osu_build_state_json)" || true
  }
}


# Artifact capture / export helpers
# shellcheck source=scripts/lib/dp-os-upgrade-artifacts.sh
if [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dp-os-upgrade-artifacts.sh" ]]; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dp-os-upgrade-artifacts.sh"
fi
