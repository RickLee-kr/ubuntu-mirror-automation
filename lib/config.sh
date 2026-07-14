#!/usr/bin/env bash
# shellcheck shell=bash
# Config loading and derived paths for Ubuntu Mirror Server.

# shellcheck disable=SC2317
if [[ -n "${UM_CONFIG_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_CONFIG_LOADED=1

# Defaults (overridden by mirror.conf). Exported for consumers after um_load_config.
# shellcheck disable=SC2034
{
MIRROR_HOSTNAME="_"
MIRROR_PORT="80"
MIRROR_URL=""
MIRROR_IP=""
BASE_PATH="/var/spool/apt-mirror"
DATA_DEVICE=""
DATA_FSTYPE="ext4"
DATA_MOUNT_OPTS="defaults,noatime"
DISK_WARN_PERCENT="80"
DISK_CRIT_PERCENT="90"
# Minimum free GiB warning for default (minimal) sync
MIN_FREE_GIB="350"
# Keep at least this percent of the filesystem free after sync
DISK_RESERVE_PERCENT="20"
# Projected apt-mirror footprint (GiB) used for pre-sync capacity checks
PROJECTED_SIZE_GIB_MINIMAL="320"
PROJECTED_SIZE_GIB_FULL="700"
UPSTREAM_MIRROR="http://archive.ubuntu.com/ubuntu"
DEFAULT_ARCH="amd64"
NTHREADS="20"
# Offline upgrade mirror defaults to full (main restricted universe multiverse).
# Installer still accepts --minimal for smaller footprints.
MIRROR_MODE="full"
UBUNTU_VERSIONS="xenial bionic focal jammy noble"
SUITE_SUFFIXES="updates security backports"
INCLUDE_SOURCE="false"
# Dedicated data-disk enforcement for offline mirror (override via defaults file)
ALLOW_ROOT_FS_MIRROR="false"
MIN_FREE_GB="50"
PUBLIC_BASE_URL=""
SYNC_RANDOMIZED_DELAY_SEC="900"
RUN_CLEAN="true"
NGINX_SITE_NAME="apt-mirror"
NGINX_LISTEN_IPV6="true"
NGINX_DEFAULT_SERVER="true"
NGINX_DISABLE_DEFAULT="true"
SYNC_ON_CALENDAR="*-*-* 02:00:00"
SYNC_PERSISTENT="true"
LOG_DIR="/var/log/ubuntu-mirror"
APT_MIRROR_LOG="/var/log/apt-mirror.log"
APT_MIRROR_INITIAL_LOG="/var/log/apt-mirror-initial.log"
NGINX_ACCESS_LOG="/var/log/nginx/apt-mirror-access.log"
NGINX_ERROR_LOG="/var/log/nginx/apt-mirror-error.log"
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_LIB_DIR="/usr/local/lib/ubuntu-mirror"
INSTALL_CONF_DIR="/etc/ubuntu-mirror"
BACKUP_DIR="/var/backups/ubuntu-mirror"
HTTP_TIMEOUT_SEC="10"
HEALTH_HTTP_LATENCY_WARN_MS="500"
HEALTH_LOG_ERROR_WARN="20"
STALL_THRESHOLD_SEC="600"
WAITING_THRESHOLD_SEC="30"
ALLOW_FORMAT="false"
ALLOW_DELETE_MIRROR_DATA="false"
}

um_resolve_config_path() {
  local given="${1:-}"
  if [[ -n "$given" ]]; then
    if [[ -f "$given" ]]; then
      printf '%s\n' "$(cd "$(dirname "$given")" && pwd)/$(basename "$given")"
      return 0
    fi
    um_die "Config not found: $given"
  fi
  # Prefer installed config, then project root
  if [[ -f "${INSTALL_CONF_DIR}/mirror.conf" ]]; then
    printf '%s\n' "${INSTALL_CONF_DIR}/mirror.conf"
    return 0
  fi
  if [[ -f "${UM_PROJECT_ROOT}/mirror.conf" ]]; then
    printf '%s\n' "${UM_PROJECT_ROOT}/mirror.conf"
    return 0
  fi
  um_die "No mirror.conf found. Pass --config PATH"
}

um_load_config() {
  local path
  path="$(um_resolve_config_path "${1:-}")"
  # shellcheck disable=SC1090
  source "$path"
  UM_CONFIG_PATH="$path"

  # Derived paths
  MIRROR_PATH="${MIRROR_PATH:-$BASE_PATH/mirror}"
  SKEL_PATH="${SKEL_PATH:-$BASE_PATH/skel}"
  VAR_PATH="${VAR_PATH:-$BASE_PATH/var}"
  CLEAN_SCRIPT="${CLEAN_SCRIPT:-$VAR_PATH/clean.sh}"
  UBUNTU_MIRROR_ROOT="${UBUNTU_MIRROR_ROOT:-$MIRROR_PATH/archive.ubuntu.com/ubuntu}"
  DIST_ROOT="${DIST_ROOT:-$UBUNTU_MIRROR_ROOT/dists}"

  # Disk capacity defaults
  DISK_RESERVE_PERCENT="${DISK_RESERVE_PERCENT:-20}"
  PROJECTED_SIZE_GIB_MINIMAL="${PROJECTED_SIZE_GIB_MINIMAL:-320}"
  PROJECTED_SIZE_GIB_FULL="${PROJECTED_SIZE_GIB_FULL:-700}"
  MIN_FREE_GIB="${MIN_FREE_GIB:-350}"

  um_apply_mirror_mode_components

  if [[ -z "${MIRROR_IP}" ]]; then
    MIRROR_IP="$(um_detect_primary_ip)"
  fi
  if [[ -z "${MIRROR_URL}" ]]; then
    if [[ "${MIRROR_PORT}" == "80" ]]; then
      MIRROR_URL="http://${MIRROR_IP}"
    else
      MIRROR_URL="http://${MIRROR_IP}:${MIRROR_PORT}"
    fi
  fi

  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  # Stall detection defaults (seconds)
  STALL_THRESHOLD_SEC="${STALL_THRESHOLD_SEC:-600}"
  WAITING_THRESHOLD_SEC="${WAITING_THRESHOLD_SEC:-30}"
  if [[ "${UM_QUIET_LOAD:-0}" != "1" ]]; then
    um_info "Loaded config: $UM_CONFIG_PATH"
  fi
}

um_apply_mirror_mode_components() {
  case "${MIRROR_MODE}" in
    full|FULL)
      MIRROR_MODE="full"
      MIRROR_COMPONENTS="main restricted universe multiverse"
      ;;
    minimal|MINIMAL|"")
      MIRROR_MODE="minimal"
      MIRROR_COMPONENTS="main restricted"
      ;;
    *)
      um_die "Invalid MIRROR_MODE='$MIRROR_MODE' (use full|minimal)"
      ;;
  esac
}

# Resolve install/runtime mode.
# Offline upgrade mirror defaults to full. --minimal forces reduced footprint.
# --full explicitly selects full. Config MIRROR_MODE=full is honored without --full.
um_resolve_mirror_mode() {
  local want_full="${1:-0}"
  local want_minimal="${2:-0}"
  if [[ "$want_minimal" == "1" ]]; then
    MIRROR_MODE="minimal"
  elif [[ "$want_full" == "1" ]]; then
    MIRROR_MODE="full"
  else
    case "${MIRROR_MODE}" in
      full|FULL) MIRROR_MODE="full" ;;
      minimal|MINIMAL) MIRROR_MODE="minimal" ;;
      *) MIRROR_MODE="full" ;;
    esac
  fi
  um_apply_mirror_mode_components
  # Offline upgrade mirror always mirrors backports (even if a stale /etc config omitted them)
  if [[ "$MIRROR_MODE" == "full" ]]; then
    SUITE_SUFFIXES="updates security backports"
  else
    case " ${SUITE_SUFFIXES} " in
      *" backports "*) ;;
      *) SUITE_SUFFIXES="${SUITE_SUFFIXES:+${SUITE_SUFFIXES} }backports" ;;
    esac
  fi
}

um_persist_mirror_mode_to_conf() {
  # Ensure installed mirror.conf matches the resolved mode / suites.
  local conf="${1:-${INSTALL_CONF_DIR}/mirror.conf}"
  [[ -f "$conf" ]] || return 0
  if grep -qE '^MIRROR_MODE=' "$conf" 2>/dev/null; then
    sed -i "s/^MIRROR_MODE=.*/MIRROR_MODE=\"${MIRROR_MODE}\"/" "$conf"
  else
    printf '\nMIRROR_MODE="%s"\n' "$MIRROR_MODE" >>"$conf"
  fi
  if grep -qE '^SUITE_SUFFIXES=' "$conf" 2>/dev/null; then
    sed -i "s/^SUITE_SUFFIXES=.*/SUITE_SUFFIXES=\"${SUITE_SUFFIXES}\"/" "$conf"
  else
    printf 'SUITE_SUFFIXES="%s"\n' "$SUITE_SUFFIXES" >>"$conf"
  fi
}

um_upstream_host_path() {
  # From http://archive.ubuntu.com/ubuntu -> archive.ubuntu.com/ubuntu
  local url="${UPSTREAM_MIRROR}"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%/}"
  printf '%s\n' "$url"
}

um_components_for_mode() {
  printf '%s\n' "$MIRROR_COMPONENTS"
}

um_generate_mirror_list() {
  # Print apt-mirror mirror.list content to stdout
  local components host_path suite ver suffix
  components="$(um_components_for_mode)"
  host_path="$(um_upstream_host_path)"

  cat <<EOF
############# config ##################
set base_path    ${BASE_PATH}
set mirror_path  \$base_path/mirror
set skel_path    \$base_path/skel
set var_path     \$base_path/var
set cleanscript  \$var_path/clean.sh
set defaultarch  ${DEFAULT_ARCH}
set nthreads     ${NTHREADS}
set _tilde 0
############# end config ##############

# Offline LTS upgrade chain (amd64 only)
# INCLUDED: official Ubuntu amd64 packages (main/restricted/universe/multiverse),
#           kernels, headers, and dependencies for release upgrades.
# EXCLUDED: i386, deb-src, Ubuntu Pro/ESM, PPAs, Docker CE, NVIDIA/CUDA,
#           Snap packages, vendor/private APT repositories.

EOF

  for ver in ${UBUNTU_VERSIONS}; do
    cat <<EOF
# Ubuntu ${ver}
deb ${UPSTREAM_MIRROR} ${ver} ${components}
EOF
    for suffix in ${SUITE_SUFFIXES}; do
      [[ -n "$suffix" ]] || continue
      suite="${ver}-${suffix}"
      cat <<EOF
deb ${UPSTREAM_MIRROR} ${suite} ${components}
EOF
    done
    if [[ "${INCLUDE_SOURCE}" == "true" ]]; then
      cat <<EOF
deb-src ${UPSTREAM_MIRROR} ${ver} ${components}
EOF
      for suffix in ${SUITE_SUFFIXES}; do
        [[ -n "$suffix" ]] || continue
        suite="${ver}-${suffix}"
        cat <<EOF
deb-src ${UPSTREAM_MIRROR} ${suite} ${components}
EOF
      done
    fi
    printf '\n'
  done

  # clean directive uses the host/path form expected by apt-mirror
  printf 'clean http://%s\n' "$host_path"
}

um_generate_nginx_conf() {
  local listen_extra=""
  local default_flag=""
  local offline_root="${BASE_PATH}/offline"
  if [[ "${NGINX_DEFAULT_SERVER}" == "true" ]]; then
    default_flag=" default_server"
  fi
  if [[ "${NGINX_LISTEN_IPV6}" == "true" ]]; then
    listen_extra="    listen [::]:${MIRROR_PORT}${default_flag};"
  fi

  cat <<EOF
# Managed by ubuntu-mirror-server — offline upgrade mirror
server {
    listen ${MIRROR_PORT}${default_flag};
${listen_extra}

    server_name ${MIRROR_HOSTNAME};

    root ${MIRROR_PATH};
    autoindex on;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location = /ubuntu {
        return 301 /ubuntu/;
    }
    location /ubuntu/ {
        alias ${UBUNTU_MIRROR_ROOT}/;
        autoindex on;
    }

    location = /offline {
        return 301 /offline/;
    }
    location /offline/ {
        alias ${offline_root}/;
        autoindex on;
        default_type text/plain;
    }

    location ~ /\\.\\. {
        return 403;
    }

    access_log ${NGINX_ACCESS_LOG};
    error_log ${NGINX_ERROR_LOG};
}
EOF
}

um_generate_systemd_service() {
  cat <<EOF
[Unit]
Description=Ubuntu Offline Mirror Sync Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ubuntu-offline-mirror.sh sync
StandardOutput=journal
StandardError=journal
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=infinity
KillMode=control-group
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF
}

um_generate_systemd_timer() {
  local persistent_line=""
  local delay="${SYNC_RANDOMIZED_DELAY_SEC:-900}"
  if [[ "${SYNC_PERSISTENT}" == "true" ]]; then
    persistent_line="Persistent=true"
  else
    persistent_line="Persistent=false"
  fi
  cat <<EOF
[Unit]
Description=Daily Ubuntu Offline Mirror Sync

[Timer]
OnCalendar=${SYNC_ON_CALENDAR}
${persistent_line}
RandomizedDelaySec=${delay}
Unit=apt-mirror.service

[Install]
WantedBy=timers.target
EOF
}
