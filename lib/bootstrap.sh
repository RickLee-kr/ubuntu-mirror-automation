#!/usr/bin/env bash
# lib/bootstrap.sh — Fresh Ubuntu 24.04 Mirror Manager bootstrap helpers
# shellcheck shell=bash

if [[ -n "${UM_BOOTSTRAP_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UM_BOOTSTRAP_LOADED=1

# Test-only override (never documented in README / --help).
# UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS=1 skips the Ubuntu 24.04 gate.

UM_BOOTSTRAP_REQUIRED_PKGS=(
  nginx
  curl
  ca-certificates
  whiptail
  python3
  tar
  coreutils
  util-linux
  gnupg
  gpgv
  openssl
  findutils
  grep
  sed
  gawk
)

UM_BOOTSTRAP_REQUIRED_CMDS=(
  nginx
  curl
  whiptail
  python3
  tar
  sha256sum
  sha1sum
  flock
  stat
  df
  awk
  sed
  grep
  find
  mkdir
  chmod
  mktemp
  openssl
  gpgv
)

# Client HTTP artifacts required for CLIENT_FILES_READY=PASS
UM_CLIENT_REQUIRED_FILES=(
  dp-offline-upgrade-xenial-to-bionic.sh
  dp-offline-upgrade-xenial-to-bionic.sh.sha256
  dp-offline-upgrade-bionic-to-focal.sh
  dp-offline-upgrade-bionic-to-focal.sh.sha256
  dp-offline-upgrade-focal-to-jammy.sh
  dp-offline-upgrade-focal-to-jammy.sh.sha256
  dp-offline-upgrade-jammy-to-noble.sh
  dp-offline-upgrade-jammy-to-noble.sh.sha256
  stage-dp-phase2.sh
  stage-dp-phase2.sh.sha256
)

um_bootstrap_required_packages() {
  printf '%s\n' "${UM_BOOTSTRAP_REQUIRED_PKGS[@]}"
}

um_bootstrap_os_gate() {
  local id="" version_id="" arch
  arch="$(uname -m 2>/dev/null || true)"
  if [[ ! -f /etc/os-release ]]; then
    um_die "OS_GATE=FAIL /etc/os-release missing"
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  id="${ID:-}"
  version_id="${VERSION_ID:-}"
  if [[ "${UM_BOOTSTRAP_ALLOW_UNSUPPORTED_OS:-0}" == "1" ]]; then
    um_warn "OS_GATE=SKIPPED_TEST_ONLY id=${id} version=${version_id} arch=${arch}"
    return 0
  fi
  if [[ "$id" != "ubuntu" || "$version_id" != "24.04" ]]; then
    um_die "OS_GATE=FAIL supported=Ubuntu_24.04_LTS_amd64 got=${id:-unknown} ${version_id:-unknown}"
  fi
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    um_die "OS_GATE=FAIL supported_arch=amd64 got=${arch}"
  fi
  um_ok "OS_GATE=PASS Ubuntu 24.04 LTS amd64"
}

um_bootstrap_host_preflight() {
  um_bootstrap_os_gate

  if [[ "${UM_DRY_RUN:-0}" != "1" ]]; then
    um_require_root
  else
    um_dry "Would require root privileges"
  fi

  um_command_exists apt-get || um_die "PREFLIGHT=FAIL apt-get missing"
  um_command_exists systemctl || um_die "PREFLIGHT=FAIL systemd/systemctl missing"
  um_ok "PREFLIGHT=PASS apt-get systemd"

  # DNS / HTTPS (best-effort; do not fail dry-run)
  if curl -sS --max-time 8 -I https://xdrsolutions.uk/ >/dev/null 2>&1; then
    um_ok "OUTBOUND_HTTPS=PASS xdrsolutions.uk"
  else
    if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
      um_dry "SKIPPED: outbound HTTPS check (runtime)"
    else
      um_warn "OUTBOUND_HTTPS=WARN cannot reach https://xdrsolutions.uk (R2 download will need this)"
    fi
  fi

  # System clock sanity (year >= 2024)
  local year
  year="$(date -u +%Y 2>/dev/null || echo 0)"
  if [[ "$year" =~ ^[0-9]+$ ]] && [[ "$year" -ge 2024 ]]; then
    um_ok "SYSTEM_CLOCK=PASS year=${year}"
  else
    um_warn "SYSTEM_CLOCK=WARN year=${year}"
  fi

  # Port 80 conflict (informational)
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn '( sport = :80 )' 2>/dev/null | grep -q LISTEN; then
      if systemctl is-active --quiet nginx 2>/dev/null; then
        um_ok "PORT_80=PASS (nginx already listening)"
      else
        um_warn "PORT_80=WARN port 80 in use by non-nginx process"
      fi
    else
      um_ok "PORT_80=PASS available"
    fi
  fi
}

um_bootstrap_storage_preflight() {
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  if [[ ! -d "$base" ]]; then
    if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
      um_dry "Would create BASE_PATH ${base}"
    else
      mkdir -p "$base"
    fi
  fi

  if [[ -d "$base" ]] && um_path_mounted "$base" 2>/dev/null; then
    local src
    src="$(findmnt -n -o SOURCE -T "$base" 2>/dev/null || echo unknown)"
    um_ok "STORAGE_MOUNT=PASS ${base} <- ${src}"
  else
    um_warn "STORAGE_MOUNT=WARN ${base} is not a separate mount — ensure enough free space"
  fi

  if [[ -d "$base" ]]; then
    local avail_kib avail_gib
    avail_kib="$(um_df_avail_kib "$base" 2>/dev/null || echo 0)"
    avail_gib=$(( ${avail_kib:-0} / 1024 / 1024 ))
    um_ok "STORAGE_FREE=${avail_gib} GiB at ${base}"
    um_info "Disk requirements for R2/ACPS downloads are calculated at Download and Prepare time"
    um_info "(package size + extract + Phase 2 + safety margin). Bootstrap does not download OS Core."
  fi

  if [[ -d "$base" ]] && [[ "${UM_DRY_RUN:-0}" != "1" ]] && [[ ! -w "$base" ]]; then
    um_die "STORAGE=FAIL no write permission on ${base}"
  fi
}

um_bootstrap_install_packages() {
  local pkgs=("${UM_BOOTSTRAP_REQUIRED_PKGS[@]}")
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install packages: ${pkgs[*]}"
    return 0
  fi

  local need=0 c
  for c in "${UM_BOOTSTRAP_REQUIRED_CMDS[@]}"; do
    um_command_exists "$c" || need=1
  done

  if [[ "$need" -eq 0 ]]; then
    um_ok "PACKAGE_INSTALL=PASS already present"
  else
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
  fi

  for c in "${UM_BOOTSTRAP_REQUIRED_CMDS[@]}"; do
    um_command_exists "$c" || um_die "PACKAGE_INSTALL=FAIL missing command after install: ${c}"
  done
  um_ok "PACKAGE_INSTALL=PASS commands verified (whiptail nginx python3 present)"
}

um_bootstrap_prepare_dirs() {
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  local mm_log_dir="${UM_MM_LOG_DIR:-/var/log/ubuntu-mirror-automation}"
  local mm_state_dir="${UM_MM_STATE_ROOT:-/var/lib/ubuntu-mirror-automation/runs}"
  local dirs=(
    "$base"
    "${base}/selective"
    "${base}/dp-phase2"
    "${base}/client"
    "${base}/.install-cache"
    "${base}/offline"
    "${LOG_DIR:-/var/log/ubuntu-mirror}"
    "$mm_log_dir"
    "$mm_state_dir"
    "${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
    "${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
    "${BACKUP_DIR:-/var/backups/ubuntu-mirror}"
  )
  local d
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would create directories under ${base} and runtime paths"
    return 0
  fi
  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done
  chmod 755 "$base" "${base}/selective" "${base}/dp-phase2" "${base}/client" 2>/dev/null || true
  # Do not create selective/current, published.previous, or releases/
  rm -f "${base}/selective/current" 2>/dev/null || true
  um_ok "DIRECTORIES=PASS"
}

um_bootstrap_install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || um_die "RUNTIME_INSTALL=FAIL missing source ${src}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest" 2>/dev/null; then
    chmod "$mode" "$dest" 2>/dev/null || true
    return 0
  fi
  install -m "$mode" "$src" "$dest"
}

um_bootstrap_install_runtime() {
  local src_root="${UM_PROJECT_ROOT}"
  local runtime="${INSTALL_LIB_DIR:-/usr/local/lib/ubuntu-mirror}"
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install Mirror Manager runtime under ${runtime}"
    um_dry "Would link ${bindir}/ubuntu-offline-mirror"
    return 0
  fi

  mkdir -p \
    "${runtime}/lib" \
    "${runtime}/scripts/lib" \
    "${runtime}/vendor/dp-phase2" \
    "${runtime}/templates" \
    "${runtime}/config/client-signing" \
    "${runtime}/client" \
    "${confdir}" \
    "${bindir}" \
    /usr/local/sbin

  local f
  for f in common.sh config.sh state.sh progress.sh offline.sh upgrade-profile.sh bootstrap.sh; do
    if [[ -f "${src_root}/lib/${f}" ]]; then
      um_bootstrap_install_file "${src_root}/lib/${f}" "${runtime}/lib/${f}" 0644
      # Flat copies for legacy drift/path helpers
      um_bootstrap_install_file "${src_root}/lib/${f}" "${runtime}/${f}" 0644
    fi
  done

  um_bootstrap_install_file \
    "${src_root}/scripts/ubuntu-offline-mirror.sh" \
    "${runtime}/scripts/ubuntu-offline-mirror.sh" 0755
  um_bootstrap_install_file \
    "${src_root}/scripts/install-dp-upgrade-mirror.sh" \
    "${runtime}/scripts/install-dp-upgrade-mirror.sh" 0755

  for f in mirror_manager_common.sh mirror_install_engine.sh r2_acquire.sh acps_acquire.sh \
           dp-phase2-common.sh os_core_package.py; do
    um_bootstrap_install_file \
      "${src_root}/scripts/lib/${f}" \
      "${runtime}/scripts/lib/${f}" 0644
  done
  chmod 0755 "${runtime}/scripts/lib/os_core_package.py" 2>/dev/null || true

  um_bootstrap_install_file \
    "${src_root}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" \
    "${runtime}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" 0755
  um_bootstrap_install_file \
    "${src_root}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1" \
    "${runtime}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1" 0644

  if [[ -f "${src_root}/templates/nginx.conf" ]]; then
    um_bootstrap_install_file \
      "${src_root}/templates/nginx.conf" \
      "${runtime}/templates/nginx.conf" 0644
  fi

  # Public signing key only — never install private key material
  if [[ -f "${src_root}/config/client-signing/offline-client-manifest.gpg" ]]; then
    um_bootstrap_install_file \
      "${src_root}/config/client-signing/offline-client-manifest.gpg" \
      "${runtime}/config/client-signing/offline-client-manifest.gpg" 0644
  fi

  # Reference client scripts under runtime tree
  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    stage-dp-phase2.sh \
    stage-dp-phase2-6.5.0.sh
  do
    if [[ -f "${src_root}/client/${f}" ]]; then
      um_bootstrap_install_file "${src_root}/client/${f}" "${runtime}/client/${f}" 0755
    fi
  done
  if [[ -d "${src_root}/client/lib" ]]; then
    mkdir -p "${runtime}/client/lib"
    cp -a "${src_root}/client/lib/." "${runtime}/client/lib/"
  fi

  # Deploy HTTP client artifacts + checksum sidecars
  um_bootstrap_deploy_client_http_artifacts

  # Entry points (sbin path overridable for temp-root tests)
  local sbin_link="${UM_UOM_INSTALL_PATH:-/usr/local/sbin/ubuntu-offline-mirror.sh}"
  mkdir -p "$(dirname "$sbin_link")" "${bindir}"
  ln -sfn "${runtime}/scripts/ubuntu-offline-mirror.sh" "$sbin_link"
  ln -sfn "${runtime}/scripts/ubuntu-offline-mirror.sh" "${bindir}/ubuntu-offline-mirror"

  # Minimal mirror.conf for path defaults (no secrets)
  if [[ ! -f "${confdir}/mirror.conf" ]] || [[ "${UM_FORCE:-0}" == "1" ]]; then
    if [[ -f "${src_root}/mirror.conf" ]]; then
      um_bootstrap_install_file "${src_root}/mirror.conf" "${confdir}/mirror.conf" 0644
    fi
  fi

  # Record source repo for operators (path only)
  printf '%s\n' "${src_root}" >"${confdir}/source-repo"

  # Verify dependency closure
  local missing=()
  for f in \
    "${runtime}/scripts/install-dp-upgrade-mirror.sh" \
    "${runtime}/scripts/ubuntu-offline-mirror.sh" \
    "${runtime}/scripts/lib/mirror_manager_common.sh" \
    "${runtime}/scripts/lib/mirror_install_engine.sh" \
    "${runtime}/scripts/lib/r2_acquire.sh" \
    "${runtime}/scripts/lib/acps_acquire.sh" \
    "${runtime}/scripts/lib/dp-phase2-common.sh" \
    "${runtime}/scripts/lib/os_core_package.py" \
    "${runtime}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" \
    "${runtime}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1" \
    "${runtime}/templates/nginx.conf" \
    "${bindir}/ubuntu-offline-mirror"
  do
    [[ -e "$f" ]] || missing+=("$f")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    um_die "RUNTIME_DEPENDENCY_CLOSURE=FAIL missing=${missing[*]}"
  fi
  um_ok "RUNTIME_INSTALL=PASS"
  um_ok "RUNTIME_DEPENDENCY_CLOSURE=PASS"
}

um_bootstrap_write_sha256_sidecar() {
  local file="$1"
  local dir base
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  (
    cd "$dir" || exit 1
    sha256sum "$base" >"${base}.sha256"
  )
}

um_bootstrap_deploy_client_http_artifacts() {
  local src_root="${UM_PROJECT_ROOT}"
  local dest="${BASE_PATH:-/var/spool/apt-mirror}/client"
  mkdir -p "$dest"

  local f
  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    stage-dp-phase2.sh
  do
    [[ -f "${src_root}/client/${f}" ]] || um_die "CLIENT_ARTIFACT=FAIL missing ${src_root}/client/${f}"
    um_bootstrap_install_file "${src_root}/client/${f}" "${dest}/${f}" 0755
    um_bootstrap_write_sha256_sidecar "${dest}/${f}"
  done

  # Optional versioned helper (not required for CLIENT_FILES_READY)
  if [[ -f "${src_root}/client/stage-dp-phase2-6.5.0.sh" ]]; then
    um_bootstrap_install_file \
      "${src_root}/client/stage-dp-phase2-6.5.0.sh" \
      "${dest}/stage-dp-phase2-6.5.0.sh" 0755
    um_bootstrap_write_sha256_sidecar "${dest}/stage-dp-phase2-6.5.0.sh"
  fi

  if [[ -d "${src_root}/client/lib" ]]; then
    mkdir -p "${dest}/lib"
    cp -a "${src_root}/client/lib/." "${dest}/lib/"
  fi

  um_bootstrap_verify_client_files "$dest" || um_die "CLIENT_FILES_READY=FAIL after deploy"
  um_ok "CLIENT_HTTP_ARTIFACTS=PASS path=${dest}"
}

um_bootstrap_verify_client_files() {
  local root="${1:-${BASE_PATH:-/var/spool/apt-mirror}/client}"
  local f
  local missing_flag=0
  [[ -d "$root" ]] || return 1
  for f in "${UM_CLIENT_REQUIRED_FILES[@]}"; do
    if [[ ! -f "${root}/${f}" ]]; then
      um_error "CLIENT_FILE_MISSING=${f}"
      missing_flag=1
    fi
  done
  [[ "$missing_flag" -eq 0 ]] || return 1

  # Verify sha256 sidecars for the four hop scripts + stage helper
  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh \
    dp-offline-upgrade-bionic-to-focal.sh \
    dp-offline-upgrade-focal-to-jammy.sh \
    dp-offline-upgrade-jammy-to-noble.sh \
    stage-dp-phase2.sh
  do
    if ! (cd "$root" && sha256sum -c "${f}.sha256" >/dev/null 2>&1); then
      um_error "CLIENT_CHECKSUM=FAIL file=${f}"
      return 1
    fi
  done
  return 0
}

um_bootstrap_install_nginx_base() {
  local base="${BASE_PATH:-/var/spool/apt-mirror}"
  local site_name="${NGINX_SITE_NAME:-apt-mirror}"
  local site_avail="/etc/nginx/sites-available/${site_name}"
  local site_en="/etc/nginx/sites-enabled/${site_name}"
  local tpl="${UM_PROJECT_ROOT}/templates/nginx.conf"
  local ngx_tmp backup=""

  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would install nginx site ${site_avail} (direct selective root, no current/previous)"
    return 0
  fi

  [[ -f "$tpl" ]] || um_die "NGINX_TEMPLATE=FAIL missing ${tpl}"
  um_command_exists nginx || um_die "NGINX_INSTALL=FAIL nginx binary missing"

  ngx_tmp="$(mktemp)"
  sed \
    -e "s|/var/spool/apt-mirror/selective|${base}/selective|g" \
    -e "s|/var/spool/apt-mirror/client|${base}/client|g" \
    -e "s|/var/spool/apt-mirror/dp-phase2|${base}/dp-phase2|g" \
    "$tpl" >"$ngx_tmp"

  # Refuse generation paths in generated config
  if grep -qE 'selective/current|published\.previous|/releases/' "$ngx_tmp"; then
    rm -f "$ngx_tmp"
    um_die "NGINX_CONFIG=FAIL generation path reference present"
  fi

  if [[ -f "$site_avail" ]] && cmp -s "$ngx_tmp" "$site_avail"; then
    um_ok "NGINX_CONFIG=PASS unchanged"
  else
    if [[ -f "$site_avail" ]]; then
      backup="${site_avail}.bak.$(date -u +%Y%m%d%H%M%S)"
      cp -a "$site_avail" "$backup"
    fi
    install -m 0644 "$ngx_tmp" "$site_avail"
    um_ok "NGINX_CONFIG=PASS installed ${site_avail}"
  fi
  rm -f "$ngx_tmp"

  ln -sfn "$site_avail" "$site_en"
  if [[ "${NGINX_DISABLE_DEFAULT:-true}" == "true" ]] && [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
    um_ok "NGINX_DEFAULT_SITE=DISABLED"
  fi

  if ! nginx -t; then
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -a "$backup" "$site_avail"
      um_warn "Restored previous nginx site from ${backup}"
    fi
    um_die "NGINX_TEST=FAIL nginx -t failed"
  fi
  um_ok "NGINX_TEST=PASS"

  systemctl enable nginx >/dev/null 2>&1 || true
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx || systemctl restart nginx
  else
    systemctl start nginx
  fi
  if systemctl is-active --quiet nginx; then
    um_ok "NGINX_ENABLE=PASS"
  else
    um_warn "NGINX_ENABLE=WARN nginx not active yet (Enable HTTP Distribution will retry)"
  fi
}

um_bootstrap_summary() {
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  cat <<EOF

DP Ubuntu Upgrade Mirror bootstrap completed.

Runtime:
  ${bindir}/ubuntu-offline-mirror mirror-manager

Mirror root:
  ${BASE_PATH:-/var/spool/apt-mirror}

Config (GUI credentials, mode 600 after save):
  ${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}/dp-upgrade-mirror.conf

Logs:
  /var/log/ubuntu-mirror-automation/

Next steps (Mirror Manager GUI):
  1. Configuration — Preparation Mode, ACPS username/password
  2. Download and Prepare Upgrade Files — R2 OS Core (FULL) + ACPS Phase 2
  3. Enable HTTP Distribution
  4. Verify Upgrade Readiness
  7. Show DP Client Upgrade Commands

Phase 2 Target is fixed at 6.5.0.
Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
If the DP is already on Ubuntu 24.04, choose Phase 2 Only.

Large downloads are NOT started by bootstrap. Start them from the GUI.

Recovery: take a full hypervisor snapshot of the DP VM before upgrade.
This project does not provide rollback commands.

EOF
}

um_bootstrap_maybe_start_gui() {
  local bindir="${INSTALL_BIN_DIR:-/usr/local/bin}"
  local cmd="${bindir}/ubuntu-offline-mirror"
  if [[ "${UM_NO_GUI:-0}" == "1" ]]; then
    if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
      um_dry "GUI auto-start skipped (--no-gui / --non-interactive)"
    else
      um_info "GUI auto-start skipped (--no-gui)"
    fi
    printf 'Re-open GUI: sudo %s mirror-manager\n' "$cmd"
    return 0
  fi
  if [[ "${UM_DRY_RUN:-0}" == "1" ]]; then
    um_dry "Would start Mirror Manager GUI on interactive TTY"
    return 0
  fi
  if [[ -t 0 && -t 1 ]]; then
    um_ok "Starting Mirror Manager GUI"
    exec "$cmd" mirror-manager
  fi
  cat <<EOF
NONINTERACTIVE_TTY=YES
Mirror Manager GUI was not started (no interactive TTY).

Re-open GUI:
  sudo ${cmd} mirror-manager
EOF
}

um_bootstrap_run() {
  phase() { printf '\n==> %s\n' "$*"; }

  phase "Host preflight (Ubuntu 24.04)"
  um_bootstrap_host_preflight

  phase "Storage preflight"
  um_bootstrap_storage_preflight

  phase "Install required packages"
  um_bootstrap_install_packages

  phase "Prepare directories"
  um_bootstrap_prepare_dirs

  phase "Install Mirror Manager runtime"
  um_bootstrap_install_runtime

  phase "Install nginx base configuration"
  um_bootstrap_install_nginx_base

  phase "Bootstrap summary"
  um_bootstrap_summary

  um_bootstrap_maybe_start_gui
}
