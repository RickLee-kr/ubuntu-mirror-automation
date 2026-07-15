#!/usr/bin/env bash
# ubuntu-offline-mirror.sh — Integrated offline Ubuntu upgrade mirror sync/verify/status/freeze
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_project_root() {
  if [[ -f "${SCRIPT_DIR}/../lib/offline.sh" ]]; then
    cd "${SCRIPT_DIR}/.." && pwd
    return
  fi
  if [[ -f /usr/local/lib/ubuntu-mirror/offline.sh ]]; then
    printf '%s\n' /usr/local/lib/ubuntu-mirror
    return
  fi
  if [[ -f "${SCRIPT_DIR}/offline.sh" ]]; then
    printf '%s\n' "$SCRIPT_DIR"
    return
  fi
  printf '%s\n' "$SCRIPT_DIR"
}

PROJECT_ROOT="$(resolve_project_root)"
if [[ -f "${PROJECT_ROOT}/lib/offline.sh" ]]; then
  # shellcheck source=lib/offline.sh
  source "${PROJECT_ROOT}/lib/offline.sh"
elif [[ -f /usr/local/lib/ubuntu-mirror/offline.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/ubuntu-mirror/offline.sh
elif [[ -f "${SCRIPT_DIR}/../lib/offline.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../lib/offline.sh"
else
  echo "ERROR: cannot find offline.sh library" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Defaults: environment wins, then /etc/default/ubuntu-offline-mirror, then built-ins
# ---------------------------------------------------------------------------
# Capture caller/environment overrides before assigning built-in defaults.
_UOM_ENV_KEYS=(
  PUBLIC_BASE_URL MIRROR_ROOT UPSTREAM_BASE_URL META_RELEASE_URL MIN_FREE_GB
  DEFAULT_ARCH ALLOWED_HOSTS EXTRA_ALLOWED_HOSTS RUN_CLEAN ALLOW_ROOT_FS_MIRROR
  SKIP_APT_MIRROR UBUNTU_KEYRING LOG_FILE LOCK_FILE CURL_CONNECT_TIMEOUT
  CURL_MAX_TIME CURL_RETRIES VERIFY_HTTP_BASE UBUNTU_RELEASES UPGRADER_DISTS
  SUITE_SUFFIXES COMPONENTS META_CHAIN_DISTS SYNC_RANDOMIZED_DELAY_SEC
)
declare -A _UOM_ENV_SET=()
declare -A _UOM_ENV_VAL=()
for _k in "${_UOM_ENV_KEYS[@]}"; do
  if [[ -n "${!_k+x}" ]]; then
    _UOM_ENV_SET["$_k"]=1
    _UOM_ENV_VAL["$_k"]="${!_k}"
  fi
done
unset _k

PUBLIC_BASE_URL="http://ubuntu-mirror.local"
MIRROR_ROOT="/var/spool/apt-mirror"
UPSTREAM_BASE_URL="http://archive.ubuntu.com/ubuntu"
META_RELEASE_URL="http://changelogs.ubuntu.com/meta-release-lts"
MIN_FREE_GB=50
DEFAULT_ARCH="amd64"
ALLOWED_HOSTS="changelogs.ubuntu.com archive.ubuntu.com security.ubuntu.com old-releases.ubuntu.com"
EXTRA_ALLOWED_HOSTS=""
RUN_CLEAN=true
ALLOW_ROOT_FS_MIRROR=false
SKIP_APT_MIRROR=false
UBUNTU_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
LOG_FILE="/var/log/ubuntu-offline-mirror.log"
LOCK_FILE="/run/ubuntu-offline-mirror.lock"
CURL_CONNECT_TIMEOUT=30
CURL_MAX_TIME=600
CURL_RETRIES=3
VERIFY_HTTP_BASE="http://127.0.0.1"
UBUNTU_RELEASES="xenial bionic focal jammy noble"
UPGRADER_DISTS="bionic focal jammy noble"
SUITE_SUFFIXES="updates security backports"
COMPONENTS="main restricted universe multiverse"
META_CHAIN_DISTS="xenial bionic focal jammy noble"

load_defaults_file() {
  local f="/etc/default/ubuntu-offline-mirror"
  [[ -f "$f" ]] || return 0
  # shellcheck disable=SC1090,SC1091
  set -a
  # shellcheck disable=SC1091
  source "$f"
  set +a
}

load_defaults_file

# Re-apply environment overrides (highest precedence)
if [[ ${#_UOM_ENV_SET[@]} -gt 0 ]]; then
  for _k in "${!_UOM_ENV_SET[@]}"; do
    printf -v "$_k" '%s' "${_UOM_ENV_VAL[$_k]}"
  done
fi
unset _k
unset _UOM_ENV_SET _UOM_ENV_VAL _UOM_ENV_KEYS

MIRROR_PATH="${MIRROR_ROOT}/mirror"
SKEL_PATH="${MIRROR_ROOT}/skel"
VAR_PATH="${MIRROR_ROOT}/var"
UBUNTU_ROOT="${MIRROR_PATH}/archive.ubuntu.com/ubuntu"
DIST_ROOT="${UBUNTU_ROOT}/dists"
OFFLINE_DIR="${MIRROR_ROOT}/offline"
READY_MARKER="${OFFLINE_DIR}/READY"
FROZEN_MARKER="${OFFLINE_DIR}/FROZEN"
META_UPSTREAM="${OFFLINE_DIR}/meta-release-lts.upstream"
META_LOCAL="${OFFLINE_DIR}/meta-release-lts"
MANIFEST_JSON="${OFFLINE_DIR}/manifest.json"
SHA256SUMS="${OFFLINE_DIR}/SHA256SUMS"
SYNC_STATE="${OFFLINE_DIR}/last-sync.json"
SNAPSHOT_INFO="${OFFLINE_DIR}/snapshot.json"
ANNOUNCE_DIR="${OFFLINE_DIR}/announcements"

SYNC_STARTED=""
SYNC_ENDED=""
SNAPSHOT_ID=""
TMP_DIR=""
LOCK_FD=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
iso_now() { date -Is; }

log() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(ts) [${level}] ${msg}"
  case "$level" in
    ERROR) printf '%s\n' "$line" >&2 ;;
    WARN)  printf '%s\n' "$line" >&2 ;;
    *)     printf '%s\n' "$line" ;;
  esac
  if [[ -n "${LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
  fi
}
info() { log INFO "$*"; }
warn() { log WARN "$*"; }
error() { log ERROR "$*"; }
die() { error "$*"; exit 1; }
ok() { log OK "$*"; }

cleanup_tmp() {
  if [[ -n "${TMP_DIR:-}" ]] && [[ -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup_tmp EXIT

invalidate_ready() {
  if [[ -f "$READY_MARKER" ]]; then
    mv -f "$READY_MARKER" "${READY_MARKER}.invalid.$(date +%s)" 2>/dev/null \
      || rm -f "$READY_MARKER"
    warn "READY marker invalidated"
  fi
  rm -f /var/lib/ubuntu-mirror/ready /var/lib/ubuntu-mirror/initial-sync-complete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
require_cmds() {
  local c missing=()
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
}

allowlist_hosts() {
  local all
  all="${ALLOWED_HOSTS} ${EXTRA_ALLOWED_HOSTS}"
  # Also allow host from UPSTREAM_BASE_URL and META_RELEASE_URL
  all="${all} $(uom_url_host "$UPSTREAM_BASE_URL") $(uom_url_host "$META_RELEASE_URL")"
  printf '%s\n' "$all"
}

assert_url_allowed() {
  local url="$1"
  local host
  host="$(uom_url_host "$url")"
  if ! uom_host_allowed "$host" "$(allowlist_hosts)"; then
    die "Refusing download from non-allowlisted host: ${host} (url=${url})"
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    die "Another ubuntu-offline-mirror process holds ${LOCK_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# Disk / mount checks
# ---------------------------------------------------------------------------
path_fs_source() {
  findmnt -n -o SOURCE -T "$1" 2>/dev/null || echo unknown
}

path_fs_target() {
  findmnt -n -o TARGET -T "$1" 2>/dev/null || echo unknown
}

check_mirror_mount() {
  local target src root_src
  mkdir -p "$MIRROR_ROOT"
  target="$(path_fs_target "$MIRROR_ROOT")"
  src="$(path_fs_source "$MIRROR_ROOT")"
  root_src="$(path_fs_source /)"

  if [[ "$target" == "/" ]] || [[ "$src" == "$root_src" ]]; then
    if [[ "${ALLOW_ROOT_FS_MIRROR}" == "true" ]]; then
      warn "MIRROR_ROOT ${MIRROR_ROOT} is on OS root filesystem (${src}) — ALLOW_ROOT_FS_MIRROR=true"
      return 0
    fi
    die "MIRROR_ROOT ${MIRROR_ROOT} is on OS root filesystem (${src}). Mount a dedicated data disk or set ALLOW_ROOT_FS_MIRROR=true"
  fi
  ok "MIRROR_ROOT on dedicated mount: ${target} <- ${src}"
}

check_disk_space() {
  local avail_kb avail_gb inodes_free
  if [[ ! -w "$MIRROR_ROOT" ]]; then
    die "MIRROR_ROOT not writable: $MIRROR_ROOT"
  fi
  avail_kb="$(df -Pk "$MIRROR_ROOT" | awk 'NR==2 {print $4}')"
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  inodes_free="$(df -Pi "$MIRROR_ROOT" | awk 'NR==2 {print $4}')"
  info "Disk free: ${avail_gb} GiB; inodes free: ${inodes_free}"
  if [[ "$avail_gb" -lt "$MIN_FREE_GB" ]]; then
    die "Insufficient free space: ${avail_gb} GiB < MIN_FREE_GB=${MIN_FREE_GB}"
  fi
  if [[ "${inodes_free}" -lt 100000 ]]; then
    die "Insufficient free inodes: ${inodes_free}"
  fi
  if [[ -d "$UBUNTU_ROOT" ]]; then
    info "Existing mirror size: $(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
  fi
}

# ---------------------------------------------------------------------------
# Safe download
# ---------------------------------------------------------------------------
# Download URL to dest. Returns 0 on success; non-zero on failure (does not exit).
try_download() {
  local url="$1"
  local dest="$2"
  local tmp host final_url http_code size rc

  assert_url_allowed "$url"
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${TMP_DIR:-/tmp}/dl.XXXXXX")"

  set +e
  http_code="$(curl --fail --location --silent --show-error \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    --retry "${CURL_RETRIES}" \
    --retry-delay 2 \
    -o "$tmp" \
    -w '%{http_code}|%{url_effective}' \
    "$url")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    error "Download failed (curl rc=${rc}): $url"
    return 1
  fi

  final_url="${http_code#*|}"
  http_code="${http_code%%|*}"
  if [[ "$http_code" != "200" ]]; then
    rm -f "$tmp"
    error "Download HTTP ${http_code}: $url"
    return 1
  fi

  host="$(uom_url_host "$final_url")"
  if ! uom_host_allowed "$host" "$(allowlist_hosts)"; then
    rm -f "$tmp"
    error "Redirect target host not allowlisted: ${host} (from ${url})"
    return 1
  fi

  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  if [[ "$size" -eq 0 ]]; then
    rm -f "$tmp"
    error "Refusing zero-byte download: $url"
    return 1
  fi
  if uom_is_probably_html "$tmp"; then
    rm -f "$tmp"
    error "Download looks like HTML error page: $url"
    return 1
  fi

  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  ok "Downloaded $(basename "$dest") (${size} bytes)"
  return 0
}

safe_download() {
  try_download "$1" "$2" || die "Required download failed: $1"
}

# Quiet download for optional assets (404 → return 1 without ERROR spam)
try_download_optional() {
  local url="$1"
  local dest="$2"
  local tmp host final_url http_code size rc host_check

  host_check="$(uom_url_host "$url")"
  if ! uom_host_allowed "$host_check" "$(allowlist_hosts)"; then
    error "Refusing download from non-allowlisted host: ${host_check}"
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "${TMP_DIR:-/tmp}/dl.XXXXXX")"

  set +e
  http_code="$(curl --fail --location --silent --show-error \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    --max-time "${CURL_MAX_TIME}" \
    --retry 1 \
    -o "$tmp" \
    -w '%{http_code}|%{url_effective}' \
    "$url" 2>/dev/null)"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  final_url="${http_code#*|}"
  http_code="${http_code%%|*}"
  [[ "$http_code" == "200" ]] || { rm -f "$tmp"; return 1; }
  host="$(uom_url_host "$final_url")"
  uom_host_allowed "$host" "$(allowlist_hosts)" || { rm -f "$tmp"; return 1; }
  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  [[ "$size" -gt 0 ]] || { rm -f "$tmp"; return 1; }
  uom_is_probably_html "$tmp" && { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  return 0
}

# ---------------------------------------------------------------------------
# Release upgrader sync
# ---------------------------------------------------------------------------
upgrader_dir_for() {
  local dist="$1"
  printf '%s/%s-updates/main/dist-upgrader-all/current\n' "$DIST_ROOT" "$dist"
}

sync_release_upgraders() {
  info "Syncing release upgraders from meta-release-lts"
  mkdir -p "$OFFLINE_DIR" "$ANNOUNCE_DIR" "$TMP_DIR"

  safe_download "$META_RELEASE_URL" "$META_UPSTREAM"

  local dist stanza tool sig release_notes release_notes_html release_file
  local dest_dir dest_tool dest_sig
  local allow
  allow="$(allowlist_hosts)"

  for dist in $UPGRADER_DISTS; do
    stanza="$(uom_extract_dist_stanza "$META_UPSTREAM" "$dist")"
    [[ -n "$stanza" ]] || die "Dist ${dist} missing from meta-release-lts"

    tool="$(uom_stanza_get "$stanza" UpgradeTool)"
    sig="$(uom_stanza_get "$stanza" UpgradeToolSignature)"
    [[ -n "$tool" ]] || die "UpgradeTool missing for Dist ${dist}"
    [[ -n "$sig" ]] || die "UpgradeToolSignature missing for Dist ${dist}"

    assert_url_allowed "$tool"
    assert_url_allowed "$sig"

    dest_dir="$(upgrader_dir_for "$dist")"
    mkdir -p "$dest_dir"
    dest_tool="${dest_dir}/${dist}.tar.gz"
    dest_sig="${dest_dir}/${dist}.tar.gz.gpg"

    safe_download "$tool" "$dest_tool"
    safe_download "$sig" "$dest_sig"

    # Optional announcement / notes files
    release_notes="$(uom_stanza_get "$stanza" ReleaseNotes)"
    release_notes_html="$(uom_stanza_get "$stanza" ReleaseNotesHtml)"
    release_file="$(uom_stanza_get "$stanza" Release-File)"

    local optional_url optional_name optional_dest
    for optional_url in "$release_notes" "$release_notes_html"; do
      [[ -n "$optional_url" ]] || continue
      if ! uom_host_allowed "$(uom_url_host "$optional_url")" "$allow"; then
        die "ReleaseNotes host not allowlisted for ${dist}: $optional_url"
      fi
      optional_name="$(basename "$(uom_url_path "$optional_url")")"
      optional_dest="${dest_dir}/${optional_name}"
      if try_download_optional "$optional_url" "$optional_dest"; then
        cp -f "$optional_dest" "${ANNOUNCE_DIR}/${optional_name}"
      else
        warn "Optional announcement unavailable for ${dist}: $optional_url"
      fi
    done

    # Probe common announcement names next to the upgrader when present upstream
    local name probe
    for name in ReleaseAnnouncement ReleaseAnnouncement.html \
                EOLReleaseAnnouncement EOLReleaseAnnouncement.html \
                DevelReleaseAnnouncement DevelReleaseAnnouncement.html; do
      if [[ -f "${dest_dir}/${name}" ]]; then
        cp -f "${dest_dir}/${name}" "${ANNOUNCE_DIR}/${name}"
        continue
      fi
      probe="${UPSTREAM_BASE_URL}/dists/${dist}-updates/main/dist-upgrader-all/current/${name}"
      if try_download_optional "$probe" "${dest_dir}/${name}"; then
        cp -f "${dest_dir}/${name}" "${ANNOUNCE_DIR}/${name}"
      fi
    done

    info "Release-File for ${dist}: ${release_file:-none}"
  done
}

verify_upgrader_gpg() {
  local dist="$1"
  local tool sig
  tool="$(upgrader_dir_for "$dist")/${dist}.tar.gz"
  sig="$(upgrader_dir_for "$dist")/${dist}.tar.gz.gpg"

  [[ -f "$tool" ]] || { error "Missing upgrader tarball: $tool"; return 1; }
  [[ -f "$sig" ]] || { error "Missing upgrader signature: $sig"; return 1; }
  [[ "$(stat -c%s "$tool")" -gt 0 ]] || { error "Zero-byte tarball: $tool"; return 1; }
  [[ "$(stat -c%s "$sig")" -gt 0 ]] || { error "Zero-byte signature: $sig"; return 1; }
  if uom_is_probably_html "$tool"; then
    error "Tarball looks like HTML: $tool"
    return 1
  fi
  [[ -f "$UBUNTU_KEYRING" ]] || { error "Keyring missing: $UBUNTU_KEYRING"; return 1; }

  if gpgv --keyring "$UBUNTU_KEYRING" "$sig" "$tool" >/dev/null 2>&1; then
    ok "GPG OK: ${dist}.tar.gz"
    return 0
  fi
  error "GPG verification failed: ${dist}.tar.gz"
  return 1
}

verify_all_upgraders() {
  local dist rc=0
  for dist in $UPGRADER_DISTS; do
    verify_upgrader_gpg "$dist" || rc=1
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Local meta-release-lts
# ---------------------------------------------------------------------------
build_local_meta() {
  info "Building local meta-release-lts -> $META_LOCAL"
  mkdir -p "$OFFLINE_DIR"
  [[ -f "$META_UPSTREAM" ]] || die "Missing upstream meta: $META_UPSTREAM"

  local tmp
  tmp="$(mktemp "${TMP_DIR}/meta.XXXXXX")"
  # shellcheck disable=SC2086
  if ! uom_build_local_meta "$META_UPSTREAM" "$PUBLIC_BASE_URL" $META_CHAIN_DISTS >"$tmp"; then
    rm -f "$tmp"
    die "Failed to build local meta-release-lts"
  fi
  if ! uom_local_meta_urls_ok "$tmp" "$PUBLIC_BASE_URL"; then
    rm -f "$tmp"
    die "Local meta-release-lts still contains external URLs"
  fi
  # Extra guard: UpgradeTool must not contain archive.ubuntu.com etc.
  if grep -E 'UpgradeTool(Signature)?:.*(archive|security|old-releases|changelogs)\.ubuntu\.com' "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "Local meta still references external Ubuntu hosts in UpgradeTool fields"
  fi
  mv -f "$tmp" "$META_LOCAL"
  chmod 0644 "$META_LOCAL"
  ok "Wrote $META_LOCAL"
}

# ---------------------------------------------------------------------------
# Suite / APT verification
# ---------------------------------------------------------------------------
suite_has_release_meta() {
  local suite="$1"
  local d="${DIST_ROOT}/${suite}"
  if [[ -f "${d}/InRelease" ]] && [[ "$(stat -c%s "${d}/InRelease")" -gt 0 ]]; then
    return 0
  fi
  if [[ -f "${d}/Release" ]] && [[ "$(stat -c%s "${d}/Release")" -gt 0 ]] \
    && [[ -f "${d}/Release.gpg" ]] && [[ "$(stat -c%s "${d}/Release.gpg")" -gt 0 ]]; then
    return 0
  fi
  return 1
}

suite_has_packages_index() {
  local suite="$1"
  local comp="$2"
  local base="${DIST_ROOT}/${suite}/${comp}/binary-amd64"
  local f
  for f in Packages.xz Packages.gz Packages; do
    if [[ -f "${base}/${f}" ]] && [[ "$(stat -c%s "${base}/${f}")" -gt 0 ]]; then
      return 0
    fi
  done
  return 1
}

valid_until_of_suite() {
  local suite="$1"
  local f=""
  if [[ -f "${DIST_ROOT}/${suite}/InRelease" ]]; then
    f="${DIST_ROOT}/${suite}/InRelease"
  elif [[ -f "${DIST_ROOT}/${suite}/Release" ]]; then
    f="${DIST_ROOT}/${suite}/Release"
  else
    printf 'n/a\n'
    return
  fi
  awk -F': ' '/^Valid-Until:/ {print $2; exit}' "$f" || printf 'none\n'
}

verify_all_suites_fs() {
  local suite comp rc=0
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    if ! suite_has_release_meta "$suite"; then
      error "Suite ${suite}: missing InRelease/Release(+gpg)"
      rc=1
      continue
    fi
    for comp in $COMPONENTS; do
      if ! suite_has_packages_index "$suite" "$comp"; then
        error "Suite ${suite}/${comp}: missing amd64 Packages index"
        rc=1
      fi
    done
    info "Suite ${suite}: OK (Valid-Until=$(valid_until_of_suite "$suite"))"
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
  return "$rc"
}

http_check() {
  local url="$1"
  local code size ctype body
  body="$(mktemp "${TMP_DIR:-/tmp}/http.XXXXXX")"
  code="$(curl -sS -o "$body" --max-time 30 -w '%{http_code}' "${VERIFY_HTTP_BASE}${url}" || echo 000)"
  size="$(stat -c%s "$body" 2>/dev/null || echo 0)"
  ctype="$(file -b --mime-type "$body" 2>/dev/null || echo unknown)"
  rm -f "$body"
  printf '%s %s %s\n' "$code" "$size" "$ctype"
}

verify_http_endpoints() {
  local rc=0
  local path code size ctype
  local paths=(
    /offline/meta-release-lts
    /offline/meta-release-lts.upstream
    /offline/manifest.json
    /offline/SHA256SUMS
  )
  # Suite metadata samples
  local suite
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    paths+=("/ubuntu/dists/${suite}/InRelease")
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")

  local dist
  for dist in $UPGRADER_DISTS; do
    paths+=("/ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz")
    paths+=("/ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz.gpg")
  done

  for path in "${paths[@]}"; do
    # InRelease may 404 if only Release+Release.gpg — try Release fallback
    read -r code size ctype <<<"$(http_check "$path")"
    if [[ "$path" == */InRelease ]] && [[ "$code" != "200" ]]; then
      local alt="${path%/InRelease}/Release"
      read -r code size ctype <<<"$(http_check "$alt")"
      path="$alt"
    fi
    if [[ "$code" != "200" ]]; then
      error "HTTP ${code} for ${path}"
      rc=1
      continue
    fi
    if [[ "$size" -eq 0 ]]; then
      error "HTTP 200 but zero length: ${path}"
      rc=1
      continue
    fi
    if [[ "$path" == *.tar.gz ]] && [[ "$ctype" == text/html ]]; then
      error "tar.gz endpoint returned HTML: ${path}"
      rc=1
      continue
    fi
    ok "HTTP 200 ${path} (${size} bytes)"
  done

  # READY may be absent during mid-sync verify failure path — optional here
  return "$rc"
}

apt_update_test_release() {
  local release="$1"
  local work
  work="$(mktemp -d "${TMP_DIR}/apt-${release}.XXXXXX")"
  mkdir -p "${work}/etc/apt/apt.conf.d" "${work}/etc/apt/preferences.d" \
           "${work}/var/lib/apt/lists/partial" "${work}/var/cache/apt/archives/partial" \
           "${work}/var/lib/dpkg" "${work}/etc/apt/trusted.gpg.d"
  chmod -R a+rwX "$work"

  if [[ -f "$UBUNTU_KEYRING" ]]; then
    cp -f "$UBUNTU_KEYRING" "${work}/etc/apt/trusted.gpg.d/ubuntu-archive-keyring.gpg"
  fi
  : >"${work}/var/lib/dpkg/status"
  : >"${work}/etc/apt/apt.conf"

  # Disable optional index targets not required for package lookup (dep11/cnf/icons).
  # Full apt-mirror sync still downloads them for client use; verify focuses on Packages.
  cat >"${work}/etc/apt/apt.conf.d/99-uom-verify" <<'EOF'
Acquire::Languages "none";
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "false";
Acquire::IndexTargets::deb::CNF::DefaultEnabled "false";
EOF

  cat >"${work}/etc/apt/sources.list" <<EOF
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release} ${COMPONENTS}
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release}-updates ${COMPONENTS}
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release}-security ${COMPONENTS}
deb [arch=amd64] ${VERIFY_HTTP_BASE}/ubuntu ${release}-backports ${COMPONENTS}
EOF

  local apt_opts=(
    -o "Dir=${work}"
    -o "Dir::State=${work}/var/lib/apt"
    -o "Dir::Cache=${work}/var/cache/apt"
    -o "Dir::Etc=${work}/etc/apt"
    -o "Dir::Etc::sourcelist=${work}/etc/apt/sources.list"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::Etc::parts=${work}/etc/apt/apt.conf.d"
    -o "Dir::Etc::main=${work}/etc/apt/apt.conf"
    -o "Dir::Etc::preferences=${work}/etc/apt/preferences"
    -o "Dir::Etc::preferencesparts=${work}/etc/apt/preferences.d"
    -o "Dir::State::status=${work}/var/lib/dpkg/status"
    -o "Acquire::Check-Valid-Until=false"
    -o "Acquire::Languages=none"
    -o "APT::Get::List-Cleanup=true"
    -o "APT::Sandbox::User=root"
  )

  local update_log="${work}/apt-update.log"
  set +e
  apt-get "${apt_opts[@]}" update -qq >"$update_log" 2>&1
  local urc=$?
  set -e

  # Prefer success; if apt still complains about optional indexes, continue when
  # InRelease/Packages were clearly acquired for the base suite.
  if [[ "$urc" -ne 0 ]]; then
    if ! ls "${work}/var/lib/apt/lists/"*"_dists_${release}_InRelease" >/dev/null 2>&1 \
      && ! ls "${work}/var/lib/apt/lists/"*"_dists_${release}_Release" >/dev/null 2>&1; then
      error "apt-get update failed for ${release}"
      cat "$update_log" >&2 || true
      return 1
    fi
    # Hard-fail only when Packages indexes are missing
    if ! ls "${work}/var/lib/apt/lists/"*"_dists_${release}_"*"_binary-amd64_Packages"* >/dev/null 2>&1; then
      error "apt-get update failed for ${release} (no Packages lists)"
      cat "$update_log" >&2 || true
      return 1
    fi
    warn "apt-get update for ${release} reported errors but core indexes are present; continuing package queries"
  fi

  local pkg
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if ! apt-cache "${apt_opts[@]}" show "$pkg" >/dev/null 2>&1; then
      if zgrep -h "^Package: ${pkg}$" "${DIST_ROOT}/${release}"/*/binary-amd64/Packages* 2>/dev/null \
        | head -1 | grep -q .; then
        error "Package ${pkg} present in Packages but not visible via apt-cache (${release})"
        return 1
      fi
      error "Required package missing for ${release}: ${pkg}"
      return 1
    fi
  done < <(uom_required_packages_for "$release")

  ok "Isolated apt-get update + package query OK: ${release}"
  return 0
}

verify_apt_all_releases() {
  local r rc=0
  require_cmds apt-get apt-cache
  for r in $UBUNTU_RELEASES; do
    apt_update_test_release "$r" || rc=1
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------
write_sha256sums() {
  info "Writing SHA256SUMS"
  local tmp
  tmp="$(mktemp "${TMP_DIR}/sha.XXXXXX")"
  {
    [[ -f "$META_LOCAL" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$META_LOCAL")" "offline/meta-release-lts"
    [[ -f "$META_UPSTREAM" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$META_UPSTREAM")" "offline/meta-release-lts.upstream"
    local dist
    for dist in $UPGRADER_DISTS; do
      local t s
      t="$(upgrader_dir_for "$dist")/${dist}.tar.gz"
      s="$(upgrader_dir_for "$dist")/${dist}.tar.gz.gpg"
      [[ -f "$t" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$t")" "ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz"
      [[ -f "$s" ]] && printf '%s  %s\n' "$(uom_file_sha256 "$s")" "ubuntu/dists/${dist}-updates/main/dist-upgrader-all/current/${dist}.tar.gz.gpg"
    done
    if [[ -f /etc/apt/mirror.list ]]; then
      printf '%s  %s\n' "$(uom_file_sha256 /etc/apt/mirror.list)" "etc/apt/mirror.list"
    fi
    if [[ -f /etc/default/ubuntu-offline-mirror ]]; then
      printf '%s  %s\n' "$(uom_file_sha256 /etc/default/ubuntu-offline-mirror)" "etc/default/ubuntu-offline-mirror"
    fi
  } >"$tmp"
  mv -f "$tmp" "$SHA256SUMS"
  ok "Wrote $SHA256SUMS"
}

write_manifest() {
  info "Writing manifest.json"
  local tmp pkg_count total_bytes
  tmp="$(mktemp "${TMP_DIR}/man.XXXXXX")"
  pkg_count=0
  total_bytes=0
  if [[ -d "$UBUNTU_ROOT" ]]; then
    pkg_count="$(find "$UBUNTU_ROOT" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
    total_bytes="$(du -sb "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
  fi

  # Build file inventory for offline + upgrader + key suite metadata (not all debs)
  local files_json="["
  local first=1
  local f rel size mtime ftype
  while IFS= read -r -d '' f; do
    rel="${f#"$MIRROR_ROOT"/}"
    size="$(stat -c%s "$f")"
    mtime="$(stat -c%Y "$f")"
    ftype="$(file -b --mime-type "$f" 2>/dev/null || echo unknown)"
    if [[ "$first" -eq 1 ]]; then first=0; else files_json+=","; fi
    files_json+=$(jq -nc --arg p "$rel" --argjson s "$size" --argjson m "$mtime" --arg t "$ftype" \
      '{path:$p,size:$s,mtime:$m,type:$t}')
  done < <(
    {
      find "$OFFLINE_DIR" -type f \( -name 'meta-release-lts*' -o -name 'READY*' -o -name 'FROZEN*' \
        -o -name 'manifest.json' -o -name 'SHA256SUMS' -o -name 'snapshot.json' -o -name 'last-sync.json' \) -print0 2>/dev/null
      local dist
      for dist in $UPGRADER_DISTS; do
        find "$(upgrader_dir_for "$dist")" -maxdepth 1 -type f -print0 2>/dev/null
      done
      # shellcheck disable=SC2086
      while IFS= read -r suite; do
        for f in InRelease Release Release.gpg; do
          [[ -f "${DIST_ROOT}/${suite}/${f}" ]] && printf '%s\0' "${DIST_ROOT}/${suite}/${f}"
        done
      done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
    }
  )

  files_json+="]"

  local suites_json="["
  first=1
  local suite vu
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    vu="$(valid_until_of_suite "$suite")"
    if [[ "$first" -eq 1 ]]; then first=0; else suites_json+=","; fi
    suites_json+=$(jq -nc --arg s "$suite" --arg v "$vu" '{suite:$s,"valid_until":$v}')
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
  suites_json+="]"

  jq -n \
    --arg generated "$(iso_now)" \
    --arg hostname "$(hostname -f 2>/dev/null || hostname)" \
    --arg public "$PUBLIC_BASE_URL" \
    --arg arch "$DEFAULT_ARCH" \
    --arg releases "$UBUNTU_RELEASES" \
    --arg snapshot "${SNAPSHOT_ID:-}" \
    --argjson packages "$pkg_count" \
    --argjson bytes "${total_bytes:-0}" \
    --argjson files "$files_json" \
    --argjson suites "$suites_json" \
    '{
      generated_at: $generated,
      hostname: $hostname,
      public_base_url: $public,
      architecture: $arch,
      releases: ($releases|split(" ")),
      snapshot_id: $snapshot,
      package_count: $packages,
      total_bytes: $bytes,
      suites: $suites,
      files: $files,
      excluded: [
        "i386 packages",
        "source packages (deb-src)",
        "Ubuntu Pro/ESM",
        "PPAs",
        "Docker CE external repos",
        "NVIDIA/CUDA external repos",
        "Snap packages",
        "Vendor-specific private APT repos"
      ]
    }' >"$tmp"
  mv -f "$tmp" "$MANIFEST_JSON"
  ok "Wrote $MANIFEST_JSON"
}

write_ready_marker() {
  local pkg_count total_h
  pkg_count="$(find "$UBUNTU_ROOT" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
  total_h="$(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
  mkdir -p "$OFFLINE_DIR"
  cat >"$READY_MARKER" <<EOF
generated_at=$(iso_now)
sync_started=${SYNC_STARTED}
sync_ended=${SYNC_ENDED:-$(iso_now)}
hostname=$(hostname -f 2>/dev/null || hostname)
public_base_url=${PUBLIC_BASE_URL}
architecture=${DEFAULT_ARCH}
releases=${UBUNTU_RELEASES}
upgrader_dists=${UPGRADER_DISTS}
total_size=${total_h}
package_count=${pkg_count}
upgrader_gpg=verified
manifest=${MANIFEST_JSON}
sha256sums=${SHA256SUMS}
snapshot_id=${SNAPSHOT_ID}
EOF
  # Keep mirrorctl/state markers in sync with offline READY
  mkdir -p /var/lib/ubuntu-mirror 2>/dev/null || true
  date -Is >/var/lib/ubuntu-mirror/ready 2>/dev/null || true
  date -Is >/var/lib/ubuntu-mirror/initial-sync-complete 2>/dev/null || true
  rm -f /var/lib/ubuntu-mirror/sync-failed /var/lib/ubuntu-mirror/sync-started 2>/dev/null || true
  ok "READY marker written: $READY_MARKER"
}

# ---------------------------------------------------------------------------
# apt-mirror
# ---------------------------------------------------------------------------
run_apt_mirror() {
  if [[ "${SKIP_APT_MIRROR}" == "true" ]]; then
    warn "SKIP_APT_MIRROR=true — skipping apt-mirror"
    return 0
  fi
  require_cmds apt-mirror
  info "Starting apt-mirror"
  local rc
  set +e
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL /usr/bin/apt-mirror 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  else
    /usr/bin/apt-mirror 2>&1 | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  fi
  set -e
  return "$rc"
}

maybe_run_clean() {
  if [[ "${RUN_CLEAN}" != "true" ]]; then
    info "RUN_CLEAN=false — skipping clean.sh"
    return 0
  fi
  local clean="${VAR_PATH}/clean.sh"
  if [[ ! -x "$clean" ]] && [[ ! -f "$clean" ]]; then
    warn "clean.sh not found at $clean — skipping"
    return 0
  fi
  info "Running clean.sh"
  local rc
  set +e
  bash "$clean" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_sync() {
  require_cmds curl flock gpgv jq sha256sum findmnt df stat file tee
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  SYNC_STARTED="$(iso_now)"
  SNAPSHOT_ID="snap-$(date +%Y%m%d-%H%M%S)-$(hostname -s 2>/dev/null || echo host)"
  invalidate_ready

  check_mirror_mount
  check_disk_space
  mkdir -p "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH" "$OFFLINE_DIR" "$ANNOUNCE_DIR"

  if ! run_apt_mirror; then
    die "apt-mirror failed"
  fi
  ok "apt-mirror completed"

  sync_release_upgraders
  build_local_meta
  verify_all_upgraders || die "Release upgrader GPG verification failed"

  if ! verify_all_suites_fs; then
    die "Suite filesystem verification failed"
  fi

  write_sha256sums
  write_manifest
  chmod 0644 "$SHA256SUMS" "$MANIFEST_JSON" 2>/dev/null || true
  # Ensure freshly downloaded upgraders/meta are world-readable for nginx
  find "$OFFLINE_DIR" -type f -exec chmod 0644 {} +
  for dist in $UPGRADER_DISTS; do
    find "$(upgrader_dir_for "$dist")" -type f -exec chmod 0644 {} + 2>/dev/null || true
  done

  if systemctl is-active --quiet nginx 2>/dev/null; then
    verify_http_endpoints || die "HTTP endpoint verification failed"
    verify_apt_all_releases || die "Isolated apt-get update verification failed"
  else
    warn "nginx not active — skipping HTTP/apt verification (filesystem checks passed)"
  fi

  if ! maybe_run_clean; then
    die "clean.sh failed"
  fi

  SYNC_ENDED="$(iso_now)"
  jq -n --arg s "$SYNC_STARTED" --arg e "$SYNC_ENDED" --arg id "$SNAPSHOT_ID" --arg r ok \
    '{started:$s,ended:$e,snapshot_id:$id,result:$r}' >"$SYNC_STATE"

  write_ready_marker
  ok "sync complete — READY"
}

cmd_verify() {
  require_cmds curl gpgv jq sha256sum file apt-get apt-cache
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"
  invalidate_ready

  local rc=0
  verify_all_upgraders || rc=1
  verify_all_suites_fs || rc=1
  [[ -f "$META_LOCAL" ]] || { error "missing $META_LOCAL"; rc=1; }
  [[ -f "$META_UPSTREAM" ]] || { error "missing $META_UPSTREAM"; rc=1; }
  if [[ -f "$META_LOCAL" ]]; then
    uom_local_meta_urls_ok "$META_LOCAL" "$PUBLIC_BASE_URL" || rc=1
  fi

  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    error "nginx is not active — verify requires local HTTP"
    rc=1
  else
    # Temporarily treat missing manifest as regenerable
    write_sha256sums
    write_manifest
    verify_http_endpoints || rc=1
    verify_apt_all_releases || rc=1
  fi

  if [[ "$rc" -ne 0 ]]; then
    die "verify failed"
  fi

  SYNC_STARTED="$(jq -r '.started // empty' "$SYNC_STATE" 2>/dev/null || true)"
  SYNC_ENDED="$(iso_now)"
  SNAPSHOT_ID="$(jq -r '.snapshot_id // empty' "$SYNC_STATE" 2>/dev/null || true)"
  [[ -n "$SNAPSHOT_ID" ]] || SNAPSHOT_ID="verify-$(date +%Y%m%d-%H%M%S)"
  write_ready_marker
  ok "verify passed — READY refreshed"
}

cmd_status() {
  echo "=== Ubuntu Offline Mirror Status ==="
  echo "Hostname:        $(hostname -f 2>/dev/null || hostname)"
  echo "PUBLIC_BASE_URL: $PUBLIC_BASE_URL"
  echo "MIRROR_ROOT:     $MIRROR_ROOT"
  echo "Mount:           $(path_fs_target "$MIRROR_ROOT") <- $(path_fs_source "$MIRROR_ROOT")"
  echo "Disk:            $(df -h "$MIRROR_ROOT" 2>/dev/null | awk 'NR==2 {printf "used=%s avail=%s (%s)", $3,$4,$5}')"
  if [[ -d "$MIRROR_ROOT" ]]; then
    echo "Mirror size:     $(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')"
    echo ".deb count:      $(find "$UBUNTU_ROOT" -type f -name '*.deb' 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ -f "$SYNC_STATE" ]]; then
    echo "Last sync:       $(cat "$SYNC_STATE")"
  else
    echo "Last sync:       (none)"
  fi
  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1 || systemctl is-active --quiet apt-mirror.service 2>/dev/null; then
    echo "Process:         apt-mirror RUNNING"
  else
    echo "Process:         idle"
  fi
  if [[ -f "$READY_MARKER" ]]; then
    echo "READY:           yes ($READY_MARKER)"
  else
    echo "READY:           no"
  fi
  if [[ -f "$FROZEN_MARKER" ]]; then
    echo "FROZEN:          yes ($FROZEN_MARKER)"
  else
    echo "FROZEN:          no"
  fi
  echo "nginx:           $(systemctl is-active nginx 2>/dev/null || echo unknown)"
  if systemctl list-timers apt-mirror.timer --no-pager 2>/dev/null | grep -q apt-mirror; then
    echo "Timer next:      $(systemctl list-timers apt-mirror.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1,$2,$3,$4}')"
    echo "Timer enabled:   $(systemctl is-enabled apt-mirror.timer 2>/dev/null || echo unknown)"
  else
    echo "Timer:           not registered / inactive"
  fi
  echo
  echo "--- Suites ---"
  local suite
  # shellcheck disable=SC2086
  while IFS= read -r suite; do
    if suite_has_release_meta "$suite"; then
      printf '  %-22s OK  Valid-Until=%s\n' "$suite" "$(valid_until_of_suite "$suite")"
    else
      printf '  %-22s MISSING\n' "$suite"
    fi
  done < <(uom_all_suites "$UBUNTU_RELEASES" "$SUITE_SUFFIXES")
  echo
  echo "--- Release upgraders ---"
  local dist
  for dist in $UPGRADER_DISTS; do
    if verify_upgrader_gpg "$dist" >/dev/null 2>&1; then
      printf '  %-10s GPG OK\n' "$dist"
    else
      printf '  %-10s MISSING/FAIL\n' "$dist"
    fi
  done
}

cmd_freeze() {
  require_cmds curl gpgv jq
  acquire_lock
  TMP_DIR="$(mktemp -d /tmp/uom-XXXXXX)"

  if pgrep -f '/usr/bin/apt-mirror' >/dev/null 2>&1; then
    die "Refuse freeze: apt-mirror process is running"
  fi
  if systemctl is-active --quiet apt-mirror.service 2>/dev/null; then
    die "Refuse freeze: apt-mirror.service is active"
  fi

  info "freeze: running verify first"
  # Release lock before nested verify? We hold lock — call verify internals directly
  invalidate_ready
  local rc=0
  verify_all_upgraders || rc=1
  verify_all_suites_fs || rc=1
  [[ -f "$META_LOCAL" ]] || rc=1
  if systemctl is-active --quiet nginx; then
    write_sha256sums
    write_manifest
    verify_http_endpoints || rc=1
    verify_apt_all_releases || rc=1
  else
    error "nginx inactive"
    rc=1
  fi
  [[ "$rc" -eq 0 ]] || die "freeze aborted: verify failed"

  info "Disabling apt-mirror.timer"
  systemctl stop apt-mirror.timer 2>/dev/null || true
  systemctl disable apt-mirror.timer 2>/dev/null || true

  SNAPSHOT_ID="freeze-$(date +%Y%m%d-%H%M%S)"
  SYNC_STARTED="$(jq -r '.started // empty' "$SYNC_STATE" 2>/dev/null || true)"
  SYNC_ENDED="$(iso_now)"
  write_sha256sums
  write_manifest
  write_ready_marker

  jq -n \
    --arg id "$SNAPSHOT_ID" \
    --arg at "$(iso_now)" \
    --arg host "$(hostname -f 2>/dev/null || hostname)" \
    --arg public "$PUBLIC_BASE_URL" \
    --arg size "$(du -sh "$MIRROR_ROOT" 2>/dev/null | awk '{print $1}')" \
    '{snapshot_id:$id,frozen_at:$at,hostname:$host,public_base_url:$public,mirror_size:$size,ready:true}' \
    >"$SNAPSHOT_INFO"

  cat >"$FROZEN_MARKER" <<EOF
frozen_at=$(iso_now)
snapshot_id=${SNAPSHOT_ID}
public_base_url=${PUBLIC_BASE_URL}
hostname=$(hostname -f 2>/dev/null || hostname)
timer=disabled
note=Mirror is frozen for closed-network transfer. Re-enable timer only after unfreeze on an internet-connected host.
EOF

  echo
  ok "FROZEN — mirror is ready to disconnect from the internet and move"
  echo "  READY:   $READY_MARKER"
  echo "  FROZEN:  $FROZEN_MARKER"
  echo "  Snapshot:$SNAPSHOT_INFO"
  echo "  Timer:   disabled"
}

cmd_sha256_all() {
  # Optional full-tree SHA256 (expensive) — not part of default sync
  require_cmds sha256sum find
  local out="${1:-${OFFLINE_DIR}/SHA256SUMS.all}"
  info "Computing full-tree SHA256 (this may take a long time) -> $out"
  mkdir -p "$(dirname "$out")"
  local tmp
  tmp="$(mktemp)"
  (
    cd "$MIRROR_ROOT"
    find . -type f -print0 | sort -z | xargs -0 sha256sum
  ) >"$tmp"
  mv -f "$tmp" "$out"
  ok "Wrote $out"
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} <command>

Commands:
  sync         Full sync: apt-mirror + upgraders + meta + verify + READY
  verify       Offline local verification (no external network required for checks)
  status       Show mirror / upgrader / READY / timer status
  freeze       Verify, disable timer, write FROZEN marker for air-gap move
  sha256-all   Expensive full-tree SHA256 (optional)

Config: /etc/default/ubuntu-offline-mirror
Log:    ${LOG_FILE}

Scope INCLUDED: Ubuntu amd64 binary packages (main/restricted/universe/multiverse),
                kernels/headers, release upgraders for bionic/focal/jammy/noble.
Scope EXCLUDED: i386, deb-src, Ubuntu Pro/ESM, PPAs, Docker/NVIDIA external repos,
                Snap, vendor private APT repos.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    sync) shift; cmd_sync "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    status) shift; cmd_status "$@" ;;
    freeze) shift; cmd_freeze "$@" ;;
    sha256-all) shift; cmd_sha256_all "$@" ;;
    -h|--help|help|"") usage; [[ -n "$cmd" ]] || exit 1; exit 0 ;;
    *) die "Unknown command: $cmd (see --help)" ;;
  esac
}

main "$@"
