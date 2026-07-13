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
MIN_FREE_GIB="700"
UPSTREAM_MIRROR="http://archive.ubuntu.com/ubuntu"
DEFAULT_ARCH="amd64"
NTHREADS="20"
MIRROR_MODE="full"
UBUNTU_VERSIONS="xenial bionic focal jammy noble"
SUITE_SUFFIXES="updates security"
INCLUDE_SOURCE="false"
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

  # Components based on mode
  case "${MIRROR_MODE}" in
    full|FULL)
      MIRROR_COMPONENTS="main restricted universe multiverse"
      ;;
    minimal|MINIMAL)
      MIRROR_COMPONENTS="main restricted"
      ;;
    *)
      um_die "Invalid MIRROR_MODE='$MIRROR_MODE' (use full|minimal)"
      ;;
  esac

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
  um_info "Loaded config: $UM_CONFIG_PATH"
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
  if [[ "${NGINX_DEFAULT_SERVER}" == "true" ]]; then
    default_flag=" default_server"
  fi
  if [[ "${NGINX_LISTEN_IPV6}" == "true" ]]; then
    listen_extra="    listen [::]:${MIRROR_PORT}${default_flag};"
  fi

  cat <<EOF
# Managed by ubuntu-mirror-server — do not edit by hand unless necessary.
server {
    listen ${MIRROR_PORT}${default_flag};
${listen_extra}

    server_name ${MIRROR_HOSTNAME};

    root ${MIRROR_PATH};
    autoindex on;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /ubuntu {
        alias ${UBUNTU_MIRROR_ROOT};
        autoindex on;
    }

    access_log ${NGINX_ACCESS_LOG};
    error_log ${NGINX_ERROR_LOG};
}
EOF
}

um_generate_systemd_service() {
  cat <<EOF
[Unit]
Description=APT Mirror Sync Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/apt-mirror
StandardOutput=append:${APT_MIRROR_LOG}
StandardError=append:${APT_MIRROR_LOG}
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF
}

um_generate_systemd_timer() {
  local persistent_line=""
  if [[ "${SYNC_PERSISTENT}" == "true" ]]; then
    persistent_line="Persistent=true"
  else
    persistent_line="Persistent=false"
  fi
  cat <<EOF
[Unit]
Description=Daily APT Mirror Sync

[Timer]
OnCalendar=${SYNC_ON_CALENDAR}
${persistent_line}
Unit=apt-mirror.service

[Install]
WantedBy=timers.target
EOF
}
