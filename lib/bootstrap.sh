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

# OS-hop clients (built and signed per Mirror install against local MIRROR_HTTP_URL)
UM_CLIENT_HOP_SCRIPTS=(
  dp-offline-upgrade-xenial-to-bionic.sh
  dp-offline-upgrade-bionic-to-focal.sh
  dp-offline-upgrade-focal-to-jammy.sh
  dp-offline-upgrade-jammy-to-noble.sh
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

  um_bootstrap_install_file \
    "${src_root}/scripts/rebuild-publish-clients.sh" \
    "${runtime}/scripts/rebuild-publish-clients.sh" 0755

  for f in mirror_manager_common.sh mirror_install_engine.sh r2_acquire.sh acps_acquire.sh \
           dp-phase2-common.sh mirror_host_ip.sh client_mirror_gates.sh local_client_signing.sh \
           os_core_package.py \
           build_client_xenial_to_bionic.py build_client_bionic_to_focal.py \
           build_client_focal_to_jammy.py build_client_jammy_to_noble.py; do
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

  # Templates + phase2 helpers (hop clients are rebuilt per host; do not publish
  # stale prebuilt client/*.sh from the git checkout).
  for f in \
    dp-offline-upgrade-xenial-to-bionic.sh.in \
    dp-offline-upgrade-bionic-to-focal.sh.in \
    dp-offline-upgrade-focal-to-jammy.sh.in \
    dp-offline-upgrade-jammy-to-noble.sh.in \
    dp-postboot-readiness-policy.sh.inc \
    stage-dp-phase2.sh \
    stage-dp-phase2-6.5.0.sh
  do
    if [[ -f "${src_root}/client/${f}" ]]; then
      mode=0644
      [[ "$f" == *.sh ]] && mode=0755
      um_bootstrap_install_file "${src_root}/client/${f}" "${runtime}/client/${f}" "$mode"
    fi
  done
  if [[ -d "${src_root}/client/lib" ]]; then
    mkdir -p "${runtime}/client/lib"
    cp -a "${src_root}/client/lib/." "${runtime}/client/lib/"
  fi

  # Resolve IP, local keypair, rebuild/sign/atomic-publish host-pinned clients
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
    "${runtime}/scripts/lib/mirror_host_ip.sh" \
    "${runtime}/scripts/lib/client_mirror_gates.sh" \
    "${runtime}/scripts/lib/local_client_signing.sh" \
    "${runtime}/scripts/rebuild-publish-clients.sh" \
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

um_bootstrap_source_mirror_host_libs() {
  local root="${UM_PROJECT_ROOT}"
  [[ -f "${root}/scripts/lib/mirror_host_ip.sh" ]] || return 1
  [[ -f "${root}/scripts/lib/client_mirror_gates.sh" ]] || return 1
  [[ -f "${root}/scripts/lib/local_client_signing.sh" ]] || return 1
  # shellcheck source=/dev/null
  source "${root}/scripts/lib/mirror_host_ip.sh"
  # shellcheck source=/dev/null
  source "${root}/scripts/lib/client_mirror_gates.sh"
  # shellcheck source=/dev/null
  source "${root}/scripts/lib/local_client_signing.sh"
}

# Persist resolved local Mirror URL for Mirror Manager command generation.
um_bootstrap_persist_local_mirror_url() {
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  local conf="${confdir}/dp-upgrade-mirror.conf"
  local mirror_base="$1"
  local tmp prep user pass
  mkdir -p "$confdir"
  prep="FULL"
  user=""
  pass=""
  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "$conf"
    set +a
    prep="${PREPARATION_MODE:-FULL}"
    user="${ACPS_USERNAME:-}"
    pass="${ACPS_PASSWORD:-}"
  fi
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# DP Upgrade Mirror Manager configuration (managed by install/bootstrap)
# Phase 2 target is fixed at 6.5.0 (not user-editable).
PREPARATION_MODE=$(printf '%q' "${prep}")
ACPS_USERNAME=$(printf '%q' "${user}")
ACPS_PASSWORD=$(printf '%q' "${pass}")
MIRROR_HTTP_URL=$(printf '%q' "${mirror_base}")
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$conf"
  chmod 600 "$conf"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$conf" 2>/dev/null || true
  fi
  um_ok "INSTALL_PERSISTS_LOCAL_MIRROR_URL=YES path=${conf} url=${mirror_base}"
}

um_bootstrap_selective_ready() {
  local selective="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}"
  [[ -f "${selective}/state/READY" ]] || return 1
  [[ -f "${selective}/keys/ubuntu-mirror-selective.gpg" ]] || return 1
  return 0
}

# Publish Phase 2 helpers + local public key without hop clients (pre-OS-Core).
um_bootstrap_publish_phase2_helpers_only() {
  local dest="${1:-${BASE_PATH:-/var/spool/apt-mirror}/client}"
  local src_root="${UM_PROJECT_ROOT}"
  local stage f
  mkdir -p "$dest"
  stage="$(mktemp -d "${dest}.helpers.XXXXXX")"
  for f in stage-dp-phase2.sh stage-dp-phase2-6.5.0.sh; do
    if [[ -f "${src_root}/client/${f}" ]]; then
      install -m 0755 "${src_root}/client/${f}" "${stage}/${f}"
      um_bootstrap_write_sha256_sidecar "${stage}/${f}"
    fi
  done
  if [[ -d "${src_root}/client/lib" ]]; then
    mkdir -p "${stage}/lib"
    cp -a "${src_root}/client/lib/." "${stage}/lib/"
  fi
  if [[ -n "${LOCAL_SIGNING_PUBLIC_KEY:-}" && -f "${LOCAL_SIGNING_PUBLIC_KEY}" ]]; then
    install -m 0644 "$LOCAL_SIGNING_PUBLIC_KEY" "${stage}/public.gpg"
    install -m 0644 "$LOCAL_SIGNING_PUBLIC_KEY" "${stage}/offline-client-manifest.gpg"
    if [[ -n "${LOCAL_KEY_FINGERPRINT:-}" ]]; then
      printf '%s\n' "$LOCAL_KEY_FINGERPRINT" >"${stage}/fingerprint"
      chmod 0644 "${stage}/fingerprint"
    fi
  fi
  # Merge helpers into dest without removing an existing hop set.
  cp -a "${stage}/." "$dest/"
  rm -rf "$stage"
  local_signing_assert_private_not_published "$dest" || return 1
  return 0
}

# Resolve host IP, ensure local signing keypair, rebuild/sign/atomic-publish the
# four host-pinned clients. Never copies stale prebuilt client/*.sh from git.
um_bootstrap_deploy_client_http_artifacts() {
  local src_root="${UM_PROJECT_ROOT}"
  local dest="${BASE_PATH:-/var/spool/apt-mirror}/client"
  local mirror_base rebuild="${src_root}/scripts/rebuild-publish-clients.sh"
  local confdir="${INSTALL_CONF_DIR:-/etc/ubuntu-mirror}"
  mkdir -p "$dest"

  um_bootstrap_source_mirror_host_libs \
    || um_die "CLIENT_ARTIFACT=FAIL mirror host resolution / signing libraries missing"
  mirror_host_resolve_and_log \
    || um_die "MIRROR_IP_RESOLUTION_RESULT=FAIL refusing to install without an authoritative mirror host IPv4"
  mirror_base="${RESOLVED_MIRROR_BASE_URL%/}"
  um_bootstrap_persist_local_mirror_url "$mirror_base"
  um_info "INSTALL_RESOLVES_LOCAL_HOST_IP=YES url=${mirror_base}"
  um_info "CENTRAL_PRODUCTION_PRIVATE_KEY_REQUIRED=NO"
  um_info "OUT_OF_BAND_FINGERPRINT_REQUIRED=NO"
  um_info "EXPECTED_FINGERPRINT_COMMAND_ARGUMENT_REQUIRED=NO"

  # Install-time key directory is always under INSTALL_CONF_DIR. Ambient
  # LOCAL_CLIENT_SIGNING_DIR from a developer shell must not leak into bootstrap.
  if [[ "${UM_BOOTSTRAP_ALLOW_SIGNING_DIR_OVERRIDE:-0}" == "1" && -n "${LOCAL_CLIENT_SIGNING_DIR:-}" ]]; then
    :
  else
    LOCAL_CLIENT_SIGNING_DIR="${confdir}/client-signing"
  fi
  export LOCAL_CLIENT_SIGNING_DIR
  local_signing_ensure_keypair \
    || um_die "LOCAL_SIGNING_KEY_ACTION=FAIL INSTALL_RESULT=FAIL"
  um_ok "INSTALL_GENERATES_OR_REUSES_LOCAL_KEYPAIR=YES action=${LOCAL_SIGNING_KEY_ACTION}"
  um_info "LOCAL_SIGNING_KEY_PATH=${LOCAL_SIGNING_PRIVATE_KEY}"
  um_info "LOCAL_PUBLIC_KEY_PATH=${LOCAL_SIGNING_PUBLIC_KEY}"
  um_info "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"

  um_info "TARGET_INSTALL_GENERATES_OR_REUSES_LOCAL_PRIVATE_KEY=YES"
  um_info "TARGET_INSTALL_REBUILDS_CLIENTS=YES"
  um_info "TARGET_INSTALL_SIGNS_CLIENTS=YES"
  um_info "TARGET_INSTALL_REQUIRES_PREEXISTING_PRIVATE_KEY=NO"

  if ! um_bootstrap_selective_ready; then
    um_warn "SELECTIVE_READY=NO — deferring hop-client rebuild until OS Core is prepared"
    um_warn "CLIENT_SET_DEFERRED_UNTIL_OS_CORE=YES"
    um_info "Stale prebuilt git client/*.sh will NOT be published"
    # Still publish Phase 2 helpers + local public key metadata (no hop clients).
    um_bootstrap_publish_phase2_helpers_only "$dest" || true
    if um_bootstrap_verify_client_files "$dest" 2>/dev/null; then
      um_ok "CLIENT_HTTP_ARTIFACTS=PASS (helpers present; hops rebuild after OS Core)"
    else
      um_warn "CLIENT_FILES_READY=NO (hop clients deferred until Download and Prepare)"
    fi
    return 0
  fi

  [[ -x "$rebuild" || -f "$rebuild" ]] \
    || um_die "CLIENT_ARTIFACT=FAIL missing ${rebuild}"

  local artifact_dir="${src_root}/artifacts/client"
  mkdir -p "$artifact_dir"
  if ! env \
    MIRROR_HTTP_URL="$mirror_base" \
    RESOLVED_MIRROR_HOST_IPV4="${RESOLVED_MIRROR_HOST_IPV4}" \
    RESOLVED_MIRROR_BASE_URL="$mirror_base" \
    LOCAL_CLIENT_SIGNING_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
    CLIENT_HTTP_ROOT="$dest" \
    ARTIFACT_DIR="$artifact_dir" \
    SELECTIVE_ROOT="${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}" \
    BASE_PATH="${BASE_PATH:-/var/spool/apt-mirror}" \
    SKIP_HTTP_VERIFY="${UM_BOOTSTRAP_SKIP_HTTP_VERIFY:-0}" \
    bash "$rebuild"
  then
    um_die "CLIENT_SET_BUILD_OR_PUBLISH=FAIL existing HTTP set left unchanged"
  fi

  um_bootstrap_verify_client_files "$dest" || um_die "CLIENT_FILES_READY=FAIL after deploy"
  local_signing_assert_private_not_published "$dest" \
    || um_die "PRIVATE_KEY_HTTP_PUBLISHED=YES"
  um_ok "CLIENT_HTTP_ARTIFACTS=PASS path=${dest}"
  um_ok "INSTALL_BUILDS_LOCAL_CLIENT_SET=YES"
  um_ok "INSTALL_SIGNS_LOCAL_CLIENT_SET=YES"
  um_ok "INSTALL_PUBLISHES_LOCAL_PUBLIC_KEY=YES"
  um_ok "INSTALL_ATOMICALLY_PUBLISHES_FULL_SET=YES"
  um_ok "CLIENT_SET_DEPLOY_ATOMIC=YES"
  um_ok "PARTIAL_CLIENT_DEPLOY_ALLOWED=NO"
  um_ok "PRIVATE_KEY_HTTP_PUBLISHED=NO"
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
  # Public key must be published; private key must not.
  if [[ ! -f "${root}/public.gpg" && ! -f "${root}/offline-client-manifest.gpg" ]]; then
    um_error "CLIENT_PUBLIC_KEY=MISSING"
    return 1
  fi
  if [[ -f "${root}/private.gpg" ]]; then
    um_error "PRIVATE_KEY_HTTP_PUBLISHED=YES"
    return 1
  fi
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
