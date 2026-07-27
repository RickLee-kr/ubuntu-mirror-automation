#!/usr/bin/env bash
# Stage DP Phase 2 artifacts from the internal Ubuntu mirror onto a DP host.
# Downloads + places files only. NEVER runs bringup or mutates cluster services.
#
# Version model (do not conflate):
#   MIN_SUPPORTED_SOURCE_DP_VERSION  — policy floor (6.2.0)
#   SOURCE_DP_VERSION                — detected/supplied product version on the DP
#   TARGET_DP_VERSION                — selected Phase 2 artifact bundle version
set -euo pipefail
set +x

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly MIN_SUPPORTED_SOURCE_DP_VERSION="6.2.0"
DEFAULT_MIRROR_URL="http://221.139.249.111"
MIRROR_URL="$DEFAULT_MIRROR_URL"
ARTIFACT_DIR="/opt/aelladata/aelladeb_py3"
BRINGUP_DIR="/home/aella"
BRINGUP_SCRIPT="${BRINGUP_DIR}/bringup_py3_dp_after_os_upgrade.sh"
SOURCE_PRODUCT_ENV="/opt/aelladata/os-upgrade/offline/source-product.env"
MIN_AELLADATA_GIB=70
MIN_ROOT_GIB=20

TARGET_DP_VERSION=""
PHASE2_ARTIFACT_VERSION=""
SOURCE_DP_VERSION=""
SOURCE_DP_VERSION_RAW=""
SOURCE_DP_VERSION_ORIGIN=""
SOURCE_DP_VERSION_CHECK=""
TARGET_VERSION_COMPATIBILITY=""
OPERATOR_SOURCE_DP_VERSION=""
SAME_VERSION_RECOVERY=0
KEEP_CACHE=0

AELLA_UID=""
AELLA_PRIMARY_GID=""
AELLA_PRIMARY_GROUP=""
AELLA_OWNERSHIP_CHECK=""

ARTIFACT_CACHE_RESULT=""
ARTIFACT_CHECKSUM_RESULT=""
PHASE2_STAGE_RESULT=""
NTP_BRINGUP_READINESS="NOT_CHECKED"
BRINGUP_READY="NO"
BRINGUP_EXECUTED="NO"

RUN_ID=""
STAGE_ROOT=""
NEW_ART=""
CACHE_DIR=""
LOCK_FD=""
LOCK_HELD=0
REQUIRED_BUNDLE_FILES=()
ARTIFACT_FILES=()

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} --target-version X.Y.Z [options]

Stages DP Phase 2 artifact files from the internal mirror.
Does NOT execute bringup_py3_dp_after_os_upgrade.sh.

Required:
  --target-version VER     Phase 2 artifact / bundle target version

Options:
  --source-dp-version VER  Explicit source DP product version (operator override)
  --mirror-url URL         Internal mirror base (default: ${DEFAULT_MIRROR_URL})
  --same-version-recovery  Allow source==target when COMPLETED_NOBLE recovery applies
  --keep-cache             Keep verified bundle cache after successful staging
  -h, --help               Show this help

Source version resolution priority:
  1) ${SOURCE_PRODUCT_ENV}
  2) authoritative keys in /opt/aelladata/release-image.yml
  3) --source-dp-version (origin=operator-argument)
  4) UNKNOWN → STOP before download
EOF
}

log() { printf '%s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  PHASE2_STAGE_RESULT="${PHASE2_STAGE_RESULT:-FAIL}"
  exit 1
}

cleanup() {
  local rc=$?
  if [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_FD" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
    LOCK_HELD=0
  fi
  if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
    rm -rf "$STAGE_ROOT" 2>/dev/null || true
    STAGE_ROOT=""
  fi
  if [[ -n "$NEW_ART" && -d "$NEW_ART" ]]; then
    rm -rf "$NEW_ART" 2>/dev/null || true
    NEW_ART=""
  fi
  return "$rc"
}
trap cleanup EXIT

normalize_dp_version() {
  local raw="${1-}"
  local base
  if [[ -z "$raw" || "$raw" == "null" || "$raw" == "unknown" || "$raw" == "UNKNOWN" ]]; then
    return 1
  fi
  raw="$(printf '%s' "$raw" | sed -E 's/^[^0-9]*//')"
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    base="${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+\.[0-9]+)([.-]|$) ]]; then
    base="${BASH_REMATCH[1]}.0"
  else
    return 1
  fi
  printf '%s' "$base"
  return 0
}

compare_dp_versions() {
  # Prints: lt | eq | gt | unknown. Uses dpkg when available.
  local a="${1-}" b="${2-}"
  if [[ -z "$a" || -z "$b" ]]; then
    printf 'unknown'
    return 1
  fi
  if ! [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'unknown'
    return 1
  fi
  if command -v dpkg >/dev/null 2>&1; then
    if dpkg --compare-versions "$a" eq "$b"; then printf 'eq'; return 0; fi
    if dpkg --compare-versions "$a" lt "$b"; then printf 'lt'; return 0; fi
    if dpkg --compare-versions "$a" gt "$b"; then printf 'gt'; return 0; fi
    printf 'unknown'
    return 1
  fi
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  if (( a1 < b1 )); then printf 'lt'; return 0; fi
  if (( a1 > b1 )); then printf 'gt'; return 0; fi
  if (( a2 < b2 )); then printf 'lt'; return 0; fi
  if (( a2 > b2 )); then printf 'gt'; return 0; fi
  if (( a3 < b3 )); then printf 'lt'; return 0; fi
  if (( a3 > b3 )); then printf 'gt'; return 0; fi
  printf 'eq'
  return 0
}

set_target_bundle_files() {
  local ver="$1"
  REQUIRED_BUNDLE_FILES=(
    aelladeb_py3_common.tar.gz
    aelladeb_py3_common.tar.gz.sha1
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb"
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
    bringup_py3_dp_after_os_upgrade.sh
    bringup_py3_dp_after_os_upgrade.sh.sha1
    "images-${ver}.list"
    "images-${ver}.tar"
    "images-${ver}.tar.sha256"
  )
  ARTIFACT_FILES=(
    aelladeb_py3_common.tar.gz
    aelladeb_py3_common.tar.gz.sha1
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb"
    "aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
    "images-${ver}.list"
    "images-${ver}.tar"
    "images-${ver}.tar.sha256"
  )
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-version|--target-dp-version)
        TARGET_DP_VERSION="${2:-}"
        [[ -n "$TARGET_DP_VERSION" ]] || die "--target-version requires a value"
        shift 2
        ;;
      --source-dp-version)
        OPERATOR_SOURCE_DP_VERSION="${2:-}"
        [[ -n "$OPERATOR_SOURCE_DP_VERSION" ]] || die "--source-dp-version requires a value"
        shift 2
        ;;
      --mirror-url)
        MIRROR_URL="${2:-}"
        [[ -n "$MIRROR_URL" ]] || die "--mirror-url requires a value"
        shift 2
        ;;
      --same-version-recovery)
        SAME_VERSION_RECOVERY=1
        shift
        ;;
      --keep-cache)
        KEEP_CACHE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
  MIRROR_URL="${MIRROR_URL%/}"
  if [[ "$MIRROR_URL" == *acps.stellarcyber.ai* ]] || [[ "$MIRROR_URL" == *stellarcyber.ai* ]]; then
    die "Refusing ACPS/external stellarcyber URL; use internal mirror only"
  fi
  [[ -n "$TARGET_DP_VERSION" ]] || die "--target-version is required"
  local norm
  norm="$(normalize_dp_version "$TARGET_DP_VERSION")" || die "malformed --target-version: ${TARGET_DP_VERSION}"
  TARGET_DP_VERSION="$norm"
  readonly TARGET_DP_VERSION
  PHASE2_ARTIFACT_VERSION="$TARGET_DP_VERSION"
  readonly PHASE2_ARTIFACT_VERSION
  set_target_bundle_files "$TARGET_DP_VERSION"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "must run as root"
}

# Read OS identity without sourcing /etc/os-release (avoids VERSION shadowing).
os_release_field() {
  local key="$1"
  local f="/etc/os-release"
  [[ -r "$f" ]] || { printf ''; return 0; }
  grep -E "^${key}=" "$f" | head -1 | cut -d= -f2- | tr -d '"'
}

require_noble() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  local id vid codename
  id="$(os_release_field ID)"
  vid="$(os_release_field VERSION_ID)"
  codename="$(os_release_field VERSION_CODENAME)"
  [[ "$id" == "ubuntu" ]] || die "Ubuntu required"
  [[ "$vid" == "24.04" ]] || die "Ubuntu 24.04 required (got ${vid:-unknown})"
  [[ "$codename" == "noble" ]] || die "VERSION_CODENAME=noble required (got ${codename:-unknown})"
}

free_gib() {
  local path="$1"
  local kib
  kib="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  echo $((kib / 1024 / 1024))
}

require_space() {
  [[ -d /opt/aelladata ]] || die "/opt/aelladata missing"
  local aella_free root_free
  aella_free="$(free_gib /opt/aelladata)"
  root_free="$(free_gib /)"
  [[ "$aella_free" -ge "$MIN_AELLADATA_GIB" ]] || die "/opt/aelladata free ${aella_free}GiB < ${MIN_AELLADATA_GIB}GiB"
  [[ "$root_free" -ge "$MIN_ROOT_GIB" ]] || die "/ free ${root_free}GiB < ${MIN_ROOT_GIB}GiB"
}

resolve_aella_ownership() {
  id -u aella >/dev/null 2>&1 || die "aella account missing"
  local shell
  shell="$(getent passwd aella | awk -F: '{print $7}')"
  [[ "$shell" == "/bin/bash" ]] || die "aella shell must be /bin/bash (got ${shell})"

  AELLA_UID="$(id -u aella)"
  AELLA_PRIMARY_GID="$(id -g aella)"
  AELLA_PRIMARY_GROUP="$(id -gn aella)"
  [[ "$AELLA_UID" =~ ^[0-9]+$ ]] || die "AELLA_UID not numeric"
  [[ "$AELLA_PRIMARY_GID" =~ ^[0-9]+$ ]] || die "AELLA_PRIMARY_GID not numeric"
  [[ -n "$AELLA_PRIMARY_GROUP" ]] || die "AELLA_PRIMARY_GROUP empty"
  getent group "$AELLA_PRIMARY_GID" >/dev/null 2>&1 \
    || die "primary GID ${AELLA_PRIMARY_GID} not resolvable via getent group"
  AELLA_OWNERSHIP_CHECK="PASS"
  log "AELLA_UID=${AELLA_UID}"
  log "AELLA_PRIMARY_GID=${AELLA_PRIMARY_GID}"
  log "AELLA_PRIMARY_GROUP=${AELLA_PRIMARY_GROUP}"
  log "AELLA_OWNERSHIP_CHECK=${AELLA_OWNERSHIP_CHECK}"
}

read_os_upgrade_state() {
  local state=""
  local candidates=(
    /opt/aelladata/os-upgrade/offline/state
    /opt/aelladata/os-upgrade/state
    /var/lib/dp-os-upgrade/state
    /opt/aelladata/os-upgrade/CURRENT_STATE
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      state="$(tr -d '\r\n' <"$f" || true)"
      break
    fi
  done
  printf '%s' "$state"
}

require_os_upgrade_state() {
  local state
  state="$(read_os_upgrade_state)"
  if [[ -n "$state" && "$state" != "COMPLETED_NOBLE" ]]; then
    die "OS upgrade state is '${state}', require COMPLETED_NOBLE or absent"
  fi
}

phase1_product_validation_is_not_run() {
  local logf evidence
  for logf in /var/log/aella/offline_os_upgrade.log /opt/aelladata/os-upgrade/offline/*.log; do
    [[ -f "$logf" ]] || continue
    if grep -Eq 'product_validation_result=NOT_RUN_PHASE1|PRODUCT_VALIDATION=NOT_RUN_PHASE1|JAMMY_PRODUCT_VALIDATION=NOT_RUN_PHASE1' "$logf" 2>/dev/null; then
      return 0
    fi
  done
  # Marker files written by Phase 1 finalize path
  for evidence in \
    /opt/aelladata/os-upgrade/offline/product_validation_result \
    /opt/aelladata/os-upgrade/offline/PRODUCT_VALIDATION
  do
    if [[ -f "$evidence" ]] && grep -Eq 'NOT_RUN_PHASE1' "$evidence" 2>/dev/null; then
      return 0
    fi
  done
  # COMPLETED_NOBLE with no prior bringup is the common recovery posture
  local state
  state="$(read_os_upgrade_state)"
  [[ "$state" == "COMPLETED_NOBLE" ]] || return 1
  [[ ! -x "$BRINGUP_SCRIPT" ]] || return 1
  return 0
}

bringup_already_executed() {
  if [[ -f /opt/aelladata/os-upgrade/offline/BRINGUP_EXECUTED ]]; then
    return 0
  fi
  if grep -Eq 'BRINGUP_EXECUTED=YES|bringup_py3_dp_after_os_upgrade' /var/log/aella/offline_os_upgrade.log 2>/dev/null; then
    # log mention alone is weak; require explicit YES marker elsewhere
    :
  fi
  return 1
}

require_dpkg_apt_clean() {
  local audit
  audit="$(dpkg --audit 2>&1 || true)"
  [[ -z "${audit// }" ]] || die "dpkg --audit reports issues"
  apt-get check >/dev/null || die "apt-get check failed"
}

# Detect real upgrade/package-manager processes without matching ps/awk/grep or this helper.
require_no_active_os_upgrade() {
  local hits
  hits="$(ps -eo pid=,ppid=,comm=,args= | awk -v self_pid="$$" -v self_ppid="$PPID" '
    $1 == self_pid { next }
    $1 == self_ppid { next }
    $3 == "ps" || $3 == "awk" || $3 == "grep" || $3 == "sed" { next }
    # Skip this helper and its wrappers (comm is usually bash)
    $0 ~ /stage-dp-phase2/ { next }
    $0 ~ /test_dp_phase2/ { next }

    $0 ~ /[d]p-offline-upgrade-/ { print; next }
    $0 ~ /[d]p-os-upgrade-runner/ { print; next }
    $0 ~ /[u]buntu-release-upgrader/ { print; next }
    $0 ~ /[d]o-release-upgrade/ { print; next }

    $3 == "apt-get" || $4 ~ /(^|[[:space:]/])apt-get([:]|$)/ {
      # Ignore short-lived read-only checks that may still appear in the snapshot
      if ($0 ~ /apt-get[[:space:]]+check/) next
      print
      next
    }
    $3 == "dpkg" || $4 ~ /(^|[[:space:]/])dpkg([:]|$)/ {
      if ($0 ~ /dpkg[[:space:]]+--audit/) next
      print
      next
    }
  ' || true)"

  if [[ -n "${hits// }" ]]; then
    printf '%s\n' "$hits" >&2
    die "active OS upgrade process detected"
  fi
}

is_probably_html() {
  local f="$1"
  LC_ALL=C grep -a -m1 -E -q '<(!DOCTYPE[[:space:]]+)?[Hh][Tt][Mm][Ll]' \
    < <(head -c 256 "$f" 2>/dev/null | tr -d '\000')
}

read_hash() { awk 'NF {print $1; exit}' "$1"; }

verify_sha1_pair() {
  local data="$1" sum="$2"
  local expected actual
  expected="$(read_hash "$sum")"
  [[ "$expected" =~ ^[0-9a-fA-F]{40}$ ]] || die "bad sha1 format in $(basename "$sum")"
  actual="$(sha1sum "$data" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || die "sha1 mismatch for $(basename "$data")"
}

verify_sha256_pair() {
  local data="$1" sum="$2"
  local expected actual
  expected="$(read_hash "$sum")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "bad sha256 format in $(basename "$sum")"
  actual="$(sha256sum "$data" | awk '{print $1}')"
  [[ "${expected,,}" == "${actual,,}" ]] || die "sha256 mismatch for $(basename "$data")"
}

assert_safe_tar_list() {
  local bundle="$1"
  local tmp lines
  tmp="$(mktemp)"
  tar -tf "$bundle" >"$tmp"
  lines="$(wc -l <"$tmp" | tr -d ' ')"
  [[ "$lines" -eq 9 ]] || { rm -f "$tmp"; die "bundle entry count ${lines} != 9"; }
  if grep -E -q '(^/|^\.\./|/\.\./|/)' "$tmp"; then
    rm -f "$tmp"
    die "unsafe paths in bundle tar"
  fi
  local want got
  want="$(printf '%s\n' "${REQUIRED_BUNDLE_FILES[@]}" | sort)"
  got="$(sort "$tmp")"
  rm -f "$tmp"
  [[ "$want" == "$got" ]] || die "bundle file list mismatch"
}

artifact_manifest_hash() {
  local dir="$1"
  local f
  (
    cd "$dir"
    for f in "${ARTIFACT_FILES[@]}"; do
      [[ -f "$f" ]] || exit 1
      sha256sum "$f"
    done
  ) | sha256sum | awk '{print $1}'
}

is_authoritative_release_image_key() {
  case "${1:-}" in
    aella-cm-master|aella-cm-bg|aella-cm-user|aella-cm-worker|stellar-conf|stellar-controller)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_source_from_release_image() {
  local image="/opt/aelladata/release-image.yml"
  local line re key ver tmp uniq_n
  [[ -r "$image" ]] || return 1
  re='^[[:space:]]*([A-Za-z0-9_.-]+):[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)([.-][A-Za-z0-9.-]+)?[[:space:]]*$'
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ $re ]]; then
      key="${BASH_REMATCH[1]}"
      if is_authoritative_release_image_key "$key"; then
        printf '%s\n' "${BASH_REMATCH[2]}"
      fi
    fi
  done <"$image" >"$tmp" || true
  if [[ "$(wc -l <"$tmp" | tr -d ' ')" -lt 2 ]]; then
    rm -f "$tmp"
    return 1
  fi
  sort -u "$tmp" -o "$tmp"
  uniq_n="$(wc -l <"$tmp" | tr -d ' ')"
  if [[ "$uniq_n" -ne 1 ]]; then
    rm -f "$tmp"
    return 1
  fi
  ver="$(tr -d '[:space:]' <"$tmp")"
  rm -f "$tmp"
  SOURCE_DP_VERSION_RAW="$ver"
  SOURCE_DP_VERSION="$(normalize_dp_version "$ver")" || return 1
  SOURCE_DP_VERSION_ORIGIN="release-image.yml"
  return 0
}

detect_source_from_persisted_env() {
  local f="$SOURCE_PRODUCT_ENV"
  [[ -f "$f" ]] || return 1
  local raw="" norm="" origin="" check=""
  # shellcheck disable=SC1090
  raw="$(grep -E '^SOURCE_DP_VERSION_RAW=' "$f" | head -1 | cut -d= -f2- | tr -d '"')"
  norm="$(grep -E '^SOURCE_DP_VERSION=' "$f" | head -1 | cut -d= -f2- | tr -d '"')"
  origin="$(grep -E '^SOURCE_DP_VERSION_ORIGIN=' "$f" | head -1 | cut -d= -f2- | tr -d '"')"
  check="$(grep -E '^SOURCE_DP_VERSION_CHECK=' "$f" | head -1 | cut -d= -f2- | tr -d '"')"
  [[ -n "$norm" ]] || norm="$(normalize_dp_version "${raw:-}")" || return 1
  norm="$(normalize_dp_version "$norm")" || return 1
  if [[ "$check" == "FAIL_UNKNOWN" || "$norm" == "UNKNOWN" ]]; then
    return 1
  fi
  SOURCE_DP_VERSION_RAW="${raw:-$norm}"
  SOURCE_DP_VERSION="$norm"
  SOURCE_DP_VERSION_ORIGIN="${origin:-source-product.env}"
  return 0
}

resolve_source_dp_version() {
  SOURCE_DP_VERSION=""
  SOURCE_DP_VERSION_RAW=""
  SOURCE_DP_VERSION_ORIGIN=""
  SOURCE_DP_VERSION_CHECK=""

  if detect_source_from_persisted_env; then
    SOURCE_DP_VERSION_CHECK="PASS"
    log "SOURCE_DP_VERSION_ORIGIN=${SOURCE_DP_VERSION_ORIGIN}"
    return 0
  fi
  if detect_source_from_release_image; then
    SOURCE_DP_VERSION_CHECK="PASS"
    log "SOURCE_DP_VERSION_ORIGIN=${SOURCE_DP_VERSION_ORIGIN}"
    return 0
  fi
  if [[ -n "$OPERATOR_SOURCE_DP_VERSION" ]]; then
    SOURCE_DP_VERSION_RAW="$OPERATOR_SOURCE_DP_VERSION"
    SOURCE_DP_VERSION="$(normalize_dp_version "$OPERATOR_SOURCE_DP_VERSION")" \
      || die "malformed --source-dp-version: ${OPERATOR_SOURCE_DP_VERSION}"
    SOURCE_DP_VERSION_ORIGIN="operator-argument"
    SOURCE_DP_VERSION_CHECK="PASS"
    log "SOURCE_DP_VERSION_ORIGIN=${SOURCE_DP_VERSION_ORIGIN}"
    return 0
  fi
  SOURCE_DP_VERSION="UNKNOWN"
  SOURCE_DP_VERSION_RAW=""
  SOURCE_DP_VERSION_ORIGIN="none"
  SOURCE_DP_VERSION_CHECK="FAIL_UNKNOWN"
  die "SOURCE_DP_VERSION_CHECK=FAIL_UNKNOWN (provide --source-dp-version or persist ${SOURCE_PRODUCT_ENV})"
}

evaluate_version_compatibility() {
  local cmp_min cmp_tgt state
  if [[ "$SOURCE_DP_VERSION_CHECK" == "FAIL_UNKNOWN" || "$SOURCE_DP_VERSION" == "UNKNOWN" ]]; then
    SOURCE_DP_VERSION_CHECK="FAIL_UNKNOWN"
    die "SOURCE_DP_VERSION_CHECK=FAIL_UNKNOWN"
  fi
  cmp_min="$(compare_dp_versions "$SOURCE_DP_VERSION" "$MIN_SUPPORTED_SOURCE_DP_VERSION")"
  if [[ "$cmp_min" == "lt" ]]; then
    SOURCE_DP_VERSION_CHECK="FAIL_UNSUPPORTED"
    die "SOURCE_DP_VERSION_CHECK=FAIL_UNSUPPORTED source=${SOURCE_DP_VERSION} min=${MIN_SUPPORTED_SOURCE_DP_VERSION}"
  fi
  if [[ "$cmp_min" == "unknown" ]]; then
    SOURCE_DP_VERSION_CHECK="FAIL_UNKNOWN"
    die "SOURCE_DP_VERSION_CHECK=FAIL_UNKNOWN (compare failed)"
  fi
  SOURCE_DP_VERSION_CHECK="PASS"

  cmp_tgt="$(compare_dp_versions "$SOURCE_DP_VERSION" "$TARGET_DP_VERSION")"
  case "$cmp_tgt" in
    lt)
      TARGET_VERSION_COMPATIBILITY="PASS_UPGRADE"
      ;;
    gt)
      TARGET_VERSION_COMPATIBILITY="FAIL_DOWNGRADE"
      die "TARGET_VERSION_COMPATIBILITY=FAIL_DOWNGRADE source=${SOURCE_DP_VERSION} target=${TARGET_DP_VERSION}"
      ;;
    eq)
      state="$(read_os_upgrade_state)"
      if [[ "$state" == "COMPLETED_NOBLE" ]] && \
         phase1_product_validation_is_not_run && \
         ! bringup_already_executed && \
         [[ "$SAME_VERSION_RECOVERY" -eq 1 ]]; then
        TARGET_VERSION_COMPATIBILITY="SAME_VERSION_RECOVERY_REQUIRED"
        log "TARGET_VERSION_COMPATIBILITY=SAME_VERSION_RECOVERY_REQUIRED"
        log "PREREQUISITE: powered-off VM snapshot/backup confirmed by operator"
      elif [[ "$state" == "COMPLETED_NOBLE" ]] && \
            phase1_product_validation_is_not_run && \
            ! bringup_already_executed && \
            [[ "$SAME_VERSION_RECOVERY" -eq 0 ]]; then
        TARGET_VERSION_COMPATIBILITY="SAME_VERSION_RECOVERY_REQUIRED"
        die "TARGET_VERSION_COMPATIBILITY=SAME_VERSION_RECOVERY_REQUIRED (pass --same-version-recovery after snapshot)"
      else
        TARGET_VERSION_COMPATIBILITY="ALREADY_AT_TARGET"
        die "TARGET_VERSION_COMPATIBILITY=ALREADY_AT_TARGET (no staging)"
      fi
      ;;
    *)
      die "TARGET_VERSION_COMPATIBILITY=FAIL source/target compare unknown"
      ;;
  esac
  log "SOURCE_DP_VERSION_CHECK=${SOURCE_DP_VERSION_CHECK}"
  log "TARGET_VERSION_COMPATIBILITY=${TARGET_VERSION_COMPATIBILITY}"
}

load_release_env_from_mirror() {
  local url="${MIRROR_URL}/dp-phase2/${TARGET_DP_VERSION}/release.env"
  local tmp
  tmp="$(mktemp)"
  if ! curl -fsS --connect-timeout 15 --max-time 60 -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "failed to fetch release.env from ${url}"
  fi
  is_probably_html "$tmp" && { rm -f "$tmp"; die "release.env looks like HTML"; }
  local rel_target rel_art rel_ver stable
  rel_target="$(grep -E '^(TARGET_DP_VERSION|PHASE2_ARTIFACT_VERSION|DP_PHASE2_VERSION)=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  # Prefer explicit fields when present
  if grep -qE '^TARGET_DP_VERSION=' "$tmp"; then
    rel_target="$(grep -E '^TARGET_DP_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  elif grep -qE '^PHASE2_ARTIFACT_VERSION=' "$tmp"; then
    rel_target="$(grep -E '^PHASE2_ARTIFACT_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  elif grep -qE '^DP_PHASE2_VERSION=' "$tmp"; then
    rel_target="$(grep -E '^DP_PHASE2_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"')"
  fi
  rel_art="$(grep -E '^PHASE2_ARTIFACT_VERSION=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  rel_ver="$(normalize_dp_version "${rel_target:-}")" || {
    rm -f "$tmp"
    die "release.env target version malformed: ${rel_target}"
  }
  [[ "$rel_ver" == "$TARGET_DP_VERSION" ]] || {
    rm -f "$tmp"
    die "release.env target ${rel_ver} != requested ${TARGET_DP_VERSION}"
  }
  if [[ -n "$rel_art" ]]; then
    rel_art="$(normalize_dp_version "$rel_art")" || true
    [[ -z "$rel_art" || "$rel_art" == "$TARGET_DP_VERSION" ]] \
      || { rm -f "$tmp"; die "PHASE2_ARTIFACT_VERSION mismatch"; }
  fi
  stable="$(grep -E '^STABLE_BUNDLE_NAME=' "$tmp" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  if [[ -n "$stable" && "$stable" != "dp_bundle_${TARGET_DP_VERSION}-current.tar" ]]; then
    rm -f "$tmp"
    die "STABLE_BUNDLE_NAME mismatch: ${stable}"
  fi
  rm -f "$tmp"
  log "RELEASE_ENV_CROSSCHECK=PASS target=${TARGET_DP_VERSION}"
}

acquire_stage_lock() {
  local lockfile="${CACHE_DIR}/.stage.lock"
  mkdir -p "$CACHE_DIR"
  local new_fd
  exec {new_fd}>"$lockfile"
  if ! flock -n "$new_fd"; then
    eval "exec ${new_fd}>&-" 2>/dev/null || true
    die "concurrent Phase 2 staging lock busy: ${lockfile}"
  fi
  LOCK_FD="$new_fd"
  LOCK_HELD=1
  log "STAGE_LOCK=PASS path=${lockfile}"
}

ensure_verified_bundle() {
  local bundle_url sha_url
  local cache_tar="${CACHE_DIR}/bundle.tar"
  local cache_part="${CACHE_DIR}/bundle.tar.part"
  local cache_sha="${CACHE_DIR}/bundle.tar.sha256"
  local verified_marker="${CACHE_DIR}/VERIFIED"
  bundle_url="${MIRROR_URL}/dp-phase2/${TARGET_DP_VERSION}/dp_bundle_${TARGET_DP_VERSION}-current.tar"
  sha_url="${bundle_url}.sha256"

  log "DOWNLOAD_CHECKSUM url=${sha_url}"
  curl -fsSL --connect-timeout 30 --retry 5 -o "${cache_sha}.tmp" "$sha_url"
  mv -f "${cache_sha}.tmp" "$cache_sha"
  local expected
  expected="$(read_hash "$cache_sha")"
  [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "bad remote bundle sha256"

  if [[ -f "$verified_marker" && -f "$cache_tar" ]]; then
    local actual
    actual="$(sha256sum "$cache_tar" | awk '{print $1}')"
    if [[ "${expected,,}" == "${actual,,}" ]]; then
      ARTIFACT_CACHE_RESULT="REUSED"
      ARTIFACT_CHECKSUM_RESULT="PASS"
      log "ARTIFACT_CACHE_RESULT=REUSED"
      return 0
    fi
    log "ARTIFACT_CACHE_STALE=removing mismatched verified cache"
    rm -f "$verified_marker" "$cache_tar"
  fi

  if [[ -f "$cache_tar" ]]; then
    local actual
    actual="$(sha256sum "$cache_tar" | awk '{print $1}')"
    if [[ "${expected,,}" == "${actual,,}" ]]; then
      : >"$verified_marker"
      ARTIFACT_CACHE_RESULT="REUSED"
      ARTIFACT_CHECKSUM_RESULT="PASS"
      log "ARTIFACT_CACHE_RESULT=REUSED"
      return 0
    fi
    rm -f "$cache_tar"
  fi

  # Resume partial if present; fall back to full download if server rejects ranges.
  ARTIFACT_CACHE_RESULT="DOWNLOADED"
  log "DOWNLOAD_BUNDLE url=${bundle_url}"
  local err
  err="$(mktemp)"
  if [[ -f "$cache_part" && -s "$cache_part" ]]; then
    ARTIFACT_CACHE_RESULT="RESUMED"
    log "ARTIFACT_CACHE_RESULT=RESUMED"
    if ! curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
        --continue-at - -o "$cache_part" "$bundle_url" 2>"$err"; then
      log "RESUME_UNSUPPORTED=falling back to full download"
      rm -f "$cache_part"
      ARTIFACT_CACHE_RESULT="DOWNLOADED"
      if ! curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
          -o "$cache_part" "$bundle_url" 2>"$err"; then
        cat "$err" >&2 || true
        rm -f "$err"
        die "bundle download failed"
      fi
    fi
  else
    log "ARTIFACT_CACHE_RESULT=DOWNLOADED"
    if ! curl -fsSL --connect-timeout 30 --retry 5 --retry-delay 5 \
        -o "$cache_part" "$bundle_url" 2>"$err"; then
      cat "$err" >&2 || true
      rm -f "$err"
      die "bundle download failed"
    fi
  fi
  rm -f "$err"
  [[ -s "$cache_part" ]] || die "empty bundle download"
  is_probably_html "$cache_part" && die "bundle looks like HTML"
  local actual
  actual="$(sha256sum "$cache_part" | awk '{print $1}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    rm -f "$cache_part" "$verified_marker"
    die "bundle sha256 mismatch (cache discarded)"
  fi
  mv -f "$cache_part" "$cache_tar"
  : >"$verified_marker"
  ARTIFACT_CHECKSUM_RESULT="PASS"
  log "ARTIFACT_CHECKSUM_RESULT=PASS"
}

check_ntp_bringup_readiness() {
  # Read-only. Does not configure NTP. Staging may proceed; bringup guidance gated.
  NTP_BRINGUP_READINESS="FAIL"
  BRINGUP_READY="NO"
  if command -v ntpq >/dev/null 2>&1; then
    if ntpq -p 2>/dev/null | awk 'NR>2 && $1 ~ /^\*/ { found=1 } END { exit(found?0:1) }'; then
      NTP_BRINGUP_READINESS="PASS"
      BRINGUP_READY="YES"
      log "NTP_BRINGUP_READINESS=PASS (ntpsec selected peer)"
      return 0
    fi
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    local td
    td="$(timedatectl status 2>/dev/null || true)"
    if printf '%s\n' "$td" | grep -qiE 'System clock synchronized:[[:space:]]*yes' \
      && printf '%s\n' "$td" | grep -qiE 'NTP service:[[:space:]]*active'; then
      NTP_BRINGUP_READINESS="PASS"
      BRINGUP_READY="YES"
      log "NTP_BRINGUP_READINESS=PASS (systemd-timesyncd)"
      return 0
    fi
  fi
  log "NTP_BRINGUP_READINESS=FAIL (do not run bringup until internal NTP is healthy)"
}

emit_final_report() {
  cat <<EOF
MIN_SUPPORTED_SOURCE_DP_VERSION=${MIN_SUPPORTED_SOURCE_DP_VERSION}
SOURCE_DP_VERSION=${SOURCE_DP_VERSION}
SOURCE_DP_VERSION_RAW=${SOURCE_DP_VERSION_RAW}
SOURCE_DP_VERSION_ORIGIN=${SOURCE_DP_VERSION_ORIGIN}
SOURCE_DP_VERSION_CHECK=${SOURCE_DP_VERSION_CHECK}
TARGET_DP_VERSION=${TARGET_DP_VERSION}
PHASE2_ARTIFACT_VERSION=${PHASE2_ARTIFACT_VERSION}
TARGET_VERSION_COMPATIBILITY=${TARGET_VERSION_COMPATIBILITY}
AELLA_UID=${AELLA_UID}
AELLA_PRIMARY_GID=${AELLA_PRIMARY_GID}
AELLA_PRIMARY_GROUP=${AELLA_PRIMARY_GROUP}
AELLA_OWNERSHIP_CHECK=${AELLA_OWNERSHIP_CHECK}
ARTIFACT_CACHE_RESULT=${ARTIFACT_CACHE_RESULT}
ARTIFACT_CHECKSUM_RESULT=${ARTIFACT_CHECKSUM_RESULT}
PHASE2_STAGE_RESULT=${PHASE2_STAGE_RESULT}
NTP_BRINGUP_READINESS=${NTP_BRINGUP_READINESS}
BRINGUP_READY=${BRINGUP_READY}
BRINGUP_EXECUTED=${BRINGUP_EXECUTED}
ARTIFACT_DIR=${ARTIFACT_DIR}
BRINGUP_SCRIPT=${BRINGUP_SCRIPT}
EOF
  if [[ "$BRINGUP_READY" == "YES" ]]; then
    cat <<EOF
NEXT_COMMAND=sudo bash ${BRINGUP_SCRIPT} --version ${TARGET_DP_VERSION} --skip-download
NEXT_COMMAND_NOTE=Only run after NTP_BRINGUP_READINESS=PASS and operator snapshot confirmation
EOF
  else
    cat <<EOF
NEXT_COMMAND=NOT_READY
NEXT_COMMAND_NOTE=Fix internal NTP readiness before bringup; staging does not execute bringup
EOF
  fi
}

stage_main() {
  parse_args "$@"
  require_root
  require_noble
  # Prove TARGET is not shadowed by os-release VERSION
  local os_version_field
  os_version_field="$(os_release_field VERSION)"
  [[ "$TARGET_DP_VERSION" != "$os_version_field" ]] || true
  [[ "$TARGET_DP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "TARGET_DP_VERSION corrupted after OS checks: ${TARGET_DP_VERSION}"

  require_space
  resolve_aella_ownership
  require_os_upgrade_state
  require_dpkg_apt_clean
  require_no_active_os_upgrade

  resolve_source_dp_version
  evaluate_version_compatibility
  load_release_env_from_mirror

  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  CACHE_DIR="/opt/aelladata/.dp-phase2-cache/${TARGET_DP_VERSION}"
  STAGE_ROOT="/opt/aelladata/.aelladeb_py3.stage.${RUN_ID}"
  acquire_stage_lock
  ensure_verified_bundle

  mkdir -p "$STAGE_ROOT"
  local cache_tar="${CACHE_DIR}/bundle.tar"
  assert_safe_tar_list "$cache_tar"
  tar -xf "$cache_tar" -C "$STAGE_ROOT"

  local f
  for f in "${REQUIRED_BUNDLE_FILES[@]}"; do
    [[ -f "${STAGE_ROOT}/${f}" ]] || die "missing extracted file ${f}"
    [[ -s "${STAGE_ROOT}/${f}" ]] || die "zero-byte extracted file ${f}"
  done
  verify_sha1_pair "${STAGE_ROOT}/aelladeb_py3_common.tar.gz" "${STAGE_ROOT}/aelladeb_py3_common.tar.gz.sha1"
  verify_sha1_pair \
    "${STAGE_ROOT}/aella-uvp-2404_${TARGET_DP_VERSION}ubuntu1_amd64.deb" \
    "${STAGE_ROOT}/aella-uvp-2404_${TARGET_DP_VERSION}ubuntu1_amd64.deb.sha1"
  verify_sha1_pair "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh" "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  verify_sha256_pair \
    "${STAGE_ROOT}/images-${TARGET_DP_VERSION}.tar" \
    "${STAGE_ROOT}/images-${TARGET_DP_VERSION}.tar.sha256"

  # Place bringup script using numeric UID/GID from runtime account (never literal group aella)
  install -o "$AELLA_UID" -g "$AELLA_PRIMARY_GID" -m 0755 \
    "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh" \
    "${BRINGUP_SCRIPT}"
  install -o "$AELLA_UID" -g "$AELLA_PRIMARY_GID" -m 0644 \
    "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
    "${BRINGUP_SCRIPT}.sha1"
  verify_sha1_pair "$BRINGUP_SCRIPT" "${BRINGUP_SCRIPT}.sha1"
  local bu bg
  bu="$(stat -c '%u' "$BRINGUP_SCRIPT")"
  bg="$(stat -c '%g' "$BRINGUP_SCRIPT")"
  [[ "$bu" == "$AELLA_UID" && "$bg" == "$AELLA_PRIMARY_GID" ]] \
    || die "bringup ownership mismatch uid=${bu} gid=${bg}"

  NEW_ART="${ARTIFACT_DIR}.new.${RUN_ID}"
  rm -rf "$NEW_ART"
  mkdir -p "$NEW_ART"
  for f in "${ARTIFACT_FILES[@]}"; do
    cp -a "${STAGE_ROOT}/${f}" "${NEW_ART}/${f}"
  done
  # Apply ownership to entire artifact tree
  chown -R "${AELLA_UID}:${AELLA_PRIMARY_GID}" "$NEW_ART"

  if [[ ! -e "$ARTIFACT_DIR" ]]; then
    mv -f "$NEW_ART" "$ARTIFACT_DIR"
    NEW_ART=""
  else
    if [[ -d "$ARTIFACT_DIR" ]]; then
      local old_h new_h
      if old_h="$(artifact_manifest_hash "$ARTIFACT_DIR" 2>/dev/null)" && \
         new_h="$(artifact_manifest_hash "$NEW_ART" 2>/dev/null)" && \
         [[ "$old_h" == "$new_h" ]]; then
        log "ARTIFACT_REUSE=PASS identical manifest"
        rm -rf "$NEW_ART"
        NEW_ART=""
      else
        local bak="${ARTIFACT_DIR}.bak.${RUN_ID}"
        if [[ -e "$bak" ]]; then
          die "backup path already exists: ${bak}"
        fi
        mv -f "$ARTIFACT_DIR" "$bak"
        mv -f "$NEW_ART" "$ARTIFACT_DIR"
        NEW_ART=""
        log "ARTIFACT_BACKUP=${bak}"
      fi
    else
      die "${ARTIFACT_DIR} exists and is not a directory"
    fi
  fi

  # Re-verify final ownership on a sample artifact
  local sample="${ARTIFACT_DIR}/images-${TARGET_DP_VERSION}.tar"
  [[ -f "$sample" ]] || die "final artifact missing ${sample}"
  bu="$(stat -c '%u' "$sample")"
  bg="$(stat -c '%g' "$sample")"
  [[ "$bu" == "$AELLA_UID" && "$bg" == "$AELLA_PRIMARY_GID" ]] \
    || die "artifact ownership mismatch uid=${bu} gid=${bg}"

  rm -rf "$STAGE_ROOT"
  STAGE_ROOT=""

  if [[ "$KEEP_CACHE" -eq 0 ]]; then
    rm -f "${CACHE_DIR}/bundle.tar" "${CACHE_DIR}/bundle.tar.part" \
      "${CACHE_DIR}/bundle.tar.sha256" "${CACHE_DIR}/VERIFIED"
    log "ARTIFACT_CACHE_CLEANUP=PASS"
  else
    log "ARTIFACT_CACHE_CLEANUP=SKIPPED (--keep-cache)"
  fi

  check_ntp_bringup_readiness
  PHASE2_STAGE_RESULT="PASS"
  BRINGUP_EXECUTED="NO"
  emit_final_report
}

# Allow tests to source functions without executing main.
if [[ "${DP_PHASE2_STAGE_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

stage_main "$@"
