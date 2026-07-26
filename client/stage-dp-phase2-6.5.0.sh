#!/usr/bin/env bash
# Stage DP Phase 2 6.5.0 artifacts from the internal Ubuntu mirror onto a DP host.
# Downloads + places files only. NEVER runs bringup or mutates cluster services.
set -euo pipefail
set +x

SCRIPT_NAME="$(basename "$0")"
VERSION="6.5.0"
DEFAULT_MIRROR_URL="http://221.139.249.111"
MIRROR_URL="$DEFAULT_MIRROR_URL"
ARTIFACT_DIR="/opt/aelladata/aelladeb_py3"
BRINGUP_DIR="/home/aella"
BRINGUP_SCRIPT="${BRINGUP_DIR}/bringup_py3_dp_after_os_upgrade.sh"
MIN_AELLADATA_GIB=70
MIN_ROOT_GIB=20
RUN_ID=""
STAGE_ROOT=""
WORKDIR=""

REQUIRED_BUNDLE_FILES=(
  aelladeb_py3_common.tar.gz
  aelladeb_py3_common.tar.gz.sha1
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb.sha1
  bringup_py3_dp_after_os_upgrade.sh
  bringup_py3_dp_after_os_upgrade.sh.sha1
  images-6.5.0.list
  images-6.5.0.tar
  images-6.5.0.tar.sha256
)

ARTIFACT_FILES=(
  aelladeb_py3_common.tar.gz
  aelladeb_py3_common.tar.gz.sha1
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb.sha1
  images-6.5.0.list
  images-6.5.0.tar
  images-6.5.0.tar.sha256
)

usage() {
  cat <<EOF
Usage: sudo bash ${SCRIPT_NAME} [--mirror-url URL]

Stages DP 6.5.0 Phase 2 files from the internal mirror.
Does NOT execute bringup_py3_dp_after_os_upgrade.sh.

Default mirror: ${DEFAULT_MIRROR_URL}
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    rm -rf "$WORKDIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-url)
        MIRROR_URL="${2:-}"
        [[ -n "$MIRROR_URL" ]] || die "--mirror-url requires a value"
        shift 2
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
  # Safety: never point at ACPS from this helper
  if [[ "$MIRROR_URL" == *acps.stellarcyber.ai* ]] || [[ "$MIRROR_URL" == *stellarcyber.ai* ]]; then
    die "Refusing ACPS/external stellarcyber URL; use internal mirror only"
  fi
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "must run as root"
}

require_noble() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu required"
  [[ "${VERSION_ID:-}" == "24.04" ]] || die "Ubuntu 24.04 required (got ${VERSION_ID:-unknown})"
  [[ "${VERSION_CODENAME:-}" == "noble" ]] || die "VERSION_CODENAME=noble required (got ${VERSION_CODENAME:-unknown})"
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

require_aella_user() {
  id -u aella >/dev/null 2>&1 || die "aella account missing"
  local shell
  shell="$(getent passwd aella | awk -F: '{print $7}')"
  [[ "$shell" == "/bin/bash" ]] || die "aella shell must be /bin/bash (got ${shell})"
}

require_os_upgrade_state() {
  local state=""
  local candidates=(
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
  if [[ -n "$state" && "$state" != "COMPLETED_NOBLE" ]]; then
    die "OS upgrade state is '${state}', require COMPLETED_NOBLE or absent"
  fi
}

require_dpkg_apt_clean() {
  local audit
  audit="$(dpkg --audit 2>&1 || true)"
  [[ -z "${audit// }" ]] || die "dpkg --audit reports issues"
  apt-get check >/dev/null || die "apt-get check failed"
}

# Avoid matching this script's own process / the pgrep cmdline itself.
require_no_active_os_upgrade() {
  local hits
  hits="$(ps -eo pid=,args= | awk '
    $1 == '"$$"' { next }
    /dp-offline-upgrade-/ { print }
    /dp-os-upgrade-runner/ { print }
    /ubuntu-release-upgrader/ { print }
    /do-release-upgrade/ { print }
  ' || true)"
  if [[ -n "${hits// }" ]]; then
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
  [[ "$lines" -eq 9 ]] || die "bundle entry count ${lines} != 9"
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

stage_main() {
  parse_args "$@"
  require_root
  require_noble
  require_space
  require_aella_user
  require_os_upgrade_state
  require_dpkg_apt_clean
  require_no_active_os_upgrade

  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  STAGE_ROOT="/opt/aelladata/.aelladeb_py3.stage.${RUN_ID}"
  WORKDIR="$(mktemp -d /tmp/dp-phase2-stage.XXXXXX)"
  mkdir -p "$STAGE_ROOT"

  local bundle_url sha_url
  bundle_url="${MIRROR_URL}/dp-phase2/${VERSION}/dp_bundle_${VERSION}-current.tar"
  sha_url="${bundle_url}.sha256"

  log "DOWNLOAD_BUNDLE url=${bundle_url}"
  curl -fL --connect-timeout 30 --retry 5 -o "${WORKDIR}/bundle.tar" "$bundle_url"
  curl -fL --connect-timeout 30 --retry 5 -o "${WORKDIR}/bundle.tar.sha256" "$sha_url"
  [[ ! -s "${WORKDIR}/bundle.tar" ]] && die "empty bundle"
  is_probably_html "${WORKDIR}/bundle.tar" && die "bundle looks like HTML"
  verify_sha256_pair "${WORKDIR}/bundle.tar" "${WORKDIR}/bundle.tar.sha256"
  assert_safe_tar_list "${WORKDIR}/bundle.tar"

  tar -xf "${WORKDIR}/bundle.tar" -C "$STAGE_ROOT"
  local f
  for f in "${REQUIRED_BUNDLE_FILES[@]}"; do
    [[ -f "${STAGE_ROOT}/${f}" ]] || die "missing extracted file ${f}"
    [[ -s "${STAGE_ROOT}/${f}" ]] || die "zero-byte extracted file ${f}"
  done
  verify_sha1_pair "${STAGE_ROOT}/aelladeb_py3_common.tar.gz" "${STAGE_ROOT}/aelladeb_py3_common.tar.gz.sha1"
  verify_sha1_pair "${STAGE_ROOT}/aella-uvp-2404_6.5.0ubuntu1_amd64.deb" "${STAGE_ROOT}/aella-uvp-2404_6.5.0ubuntu1_amd64.deb.sha1"
  verify_sha1_pair "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh" "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  verify_sha256_pair "${STAGE_ROOT}/images-6.5.0.tar" "${STAGE_ROOT}/images-6.5.0.tar.sha256"

  # Place bringup script for aella (never execute)
  install -o aella -g aella -m 0755 \
    "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh" \
    "${BRINGUP_SCRIPT}"
  install -o aella -g aella -m 0644 \
    "${STAGE_ROOT}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
    "${BRINGUP_SCRIPT}.sha1"
  verify_sha1_pair "$BRINGUP_SCRIPT" "${BRINGUP_SCRIPT}.sha1"

  # Build final artifact tree in a sibling temp dir then atomic rename
  local new_art
  new_art="${ARTIFACT_DIR}.new.${RUN_ID}"
  rm -rf "$new_art"
  mkdir -p "$new_art"
  for f in "${ARTIFACT_FILES[@]}"; do
    cp -a "${STAGE_ROOT}/${f}" "${new_art}/${f}"
  done

  if [[ ! -e "$ARTIFACT_DIR" ]]; then
    mv -f "$new_art" "$ARTIFACT_DIR"
  else
    if [[ -d "$ARTIFACT_DIR" ]]; then
      local old_h new_h
      if old_h="$(artifact_manifest_hash "$ARTIFACT_DIR" 2>/dev/null)" && \
         new_h="$(artifact_manifest_hash "$new_art" 2>/dev/null)" && \
         [[ "$old_h" == "$new_h" ]]; then
        log "ARTIFACT_REUSE=PASS identical manifest"
        rm -rf "$new_art"
      else
        local bak="${ARTIFACT_DIR}.bak.${RUN_ID}"
        if [[ -e "$bak" ]]; then
          die "backup path already exists: ${bak}"
        fi
        mv -f "$ARTIFACT_DIR" "$bak"
        mv -f "$new_art" "$ARTIFACT_DIR"
        log "ARTIFACT_BACKUP=${bak}"
      fi
    else
      die "${ARTIFACT_DIR} exists and is not a directory"
    fi
  fi

  # Remove staging extract after successful place
  rm -rf "$STAGE_ROOT"
  STAGE_ROOT=""

  cat <<EOF
PHASE2_STAGE_RESULT=PASS
VERSION=${VERSION}
ARTIFACT_DIR=${ARTIFACT_DIR}
BRINGUP_SCRIPT=${BRINGUP_SCRIPT}
BRINGUP_EXECUTED=NO
NEXT_COMMAND=sudo bash ${BRINGUP_SCRIPT} --version ${VERSION} --skip-download
EOF
}

stage_main "$@"
