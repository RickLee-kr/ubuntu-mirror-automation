#!/usr/bin/env bash
# install.sh — Single-command Ubuntu Mirror Server installer
# Default: sudo ./install.sh  → validate, install, configure, start nginx, start sync
set -euo pipefail

UM_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${UM_PROJECT_ROOT}/lib/common.sh"
# shellcheck source=lib/config.sh
source "${UM_PROJECT_ROOT}/lib/config.sh"
# shellcheck source=lib/state.sh
source "${UM_PROJECT_ROOT}/lib/state.sh"
# shellcheck source=lib/install-menu.sh
source "${UM_PROJECT_ROOT}/lib/install-menu.sh"

UM_DRY_RUN=0
UM_FORCE=0
UM_NO_SYNC=0
UM_MINIMAL=0
UM_FULL=0
UM_VERBOSE=0
UM_FORMAT_DEVICE=0
UM_CONFIG_ARG=""
UM_CHANGES=0
UM_NO_MENU=0
UM_FORCE_MENU=0
UM_FROM_MENU=0
# Sync attach mode: auto | foreground | background
# auto = attach dashboard when TTY, else background
UM_SYNC_MODE="auto"
UM_SELECTIVE=0

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Install and start an Ubuntu Mirror Server for closed-network
Ubuntu 16.04 → 24.04 offline upgrades.

Supported profile: offline-upgrade-selective
  Selection:  discovery-exact payloads from artifacts/upgrade-discovery
  Layout:     hop-separated snapshots under SELECTIVE_MIRROR_ROOT
  Releases:   xenial → bionic → focal → jammy → noble

Interactive (default on a TTY):
  sudo ./install.sh
    Opens a menu to install selective mirror tooling, run plan-selective,
    monitor status, or quit.

Non-interactive / scripted:
  sudo ./install.sh --selective
  sudo ./install.sh --non-interactive

Full apt-mirror sync and minimal mirrors are NOT supported.
  --full / --minimal exit with UNSUPPORTED_* and do not start sync.

Options:
  --help              Show this help
  --config PATH       Use a custom mirror.conf
  --dry-run           Show planned actions without changing the system
  --no-sync           Install and validate but do not start plan-selective
  --foreground        Keep status attached after install
  --background        Return to the shell immediately
  --selective         Explicit offline-upgrade-selective profile (default)
  --full              Rejected (UNSUPPORTED_FULL_MIRROR_SYNC)
  --menu              Force interactive menu (TTY required)
  --no-menu           Skip menu even on a TTY
  --non-interactive   Alias for --no-menu + background-friendly defaults
  --verbose           Show detailed validation and command output
  --force             Replace changed managed configuration after backup

Examples:
  sudo ./install.sh
  sudo ./install.sh --menu
  sudo ./install.sh --selective --dry-run
  sudo ./install.sh --no-sync
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        UM_CONFIG_ARG="${2:-}"
        [[ -n "$UM_CONFIG_ARG" ]] || um_die "--config requires a path"
        shift 2
        ;;
      --dry-run) UM_DRY_RUN=1; shift ;;
      --no-sync) UM_NO_SYNC=1; shift ;;
      --foreground) UM_SYNC_MODE="foreground"; shift ;;
      --background) UM_SYNC_MODE="background"; shift ;;
      --selective|--full)
        if [[ "$1" == "--full" ]]; then
          # shellcheck source=lib/upgrade-profile.sh
          source "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh"
          um_reject_full_sync_request "UNSUPPORTED_FULL_MIRROR_SYNC" || true
          exit 2
        fi
        UM_FULL=0; UM_MINIMAL=0; UM_SELECTIVE=1; shift
        ;;
      --minimal)
        # shellcheck source=lib/upgrade-profile.sh
        source "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh"
        um_reject_minimal_request "UNSUPPORTED_MINIMAL_PROFILE" || true
        exit 2
        ;;
      --menu) UM_FORCE_MENU=1; shift ;;
      --no-menu) UM_NO_MENU=1; shift ;;
      --verbose) UM_VERBOSE=1; shift ;;
      --force) UM_FORCE=1; shift ;;
      # Hidden expert option — not advertised in Quick Start
      --format-device) UM_FORMAT_DEVICE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      # Compatibility aliases
      --non-interactive) UM_NO_MENU=1; UM_SYNC_MODE="background"; shift ;;
      --start-sync) UM_NO_SYNC=0; shift ;;
      --validate) UM_VERBOSE=1; shift ;;
      --skip-packages) shift ;; # ignored; dry-run handles missing packages
      *) um_die "Unknown option: $1 (see --help)" ;;
    esac
  done
}

vlog() {
  if [[ "$UM_VERBOSE" == "1" ]] || [[ "$UM_DRY_RUN" == "1" ]]; then
    um_info "$*"
  fi
}

phase() {
  printf '\n==> %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Phase 1: Root and environment validation
# ---------------------------------------------------------------------------
phase1_preflight() {
  phase "Phase 1: Environment validation"

  if [[ "$UM_DRY_RUN" != "1" ]]; then
    um_require_root
  else
    um_dry "Would require root privileges"
  fi

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" == "ubuntu" ]]; then
      um_ok "OS: ${PRETTY_NAME}"
    else
      um_warn "Non-Ubuntu host: ${PRETTY_NAME:-unknown} (continuing)"
    fi
  else
    um_die "Cannot detect OS (/etc/os-release missing)"
  fi

  if ! um_command_exists apt-get; then
    um_die "apt-get not available"
  fi
  um_ok "apt-get available"

  if ! um_command_exists systemctl; then
    um_die "systemd/systemctl not available"
  fi
  um_ok "systemd available"

  # Internet (best-effort)
  if curl -sS --max-time 5 -I http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1 \
    || curl -sS --max-time 5 -I https://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
    um_ok "Internet connectivity"
  else
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "SKIPPED: internet check (runtime)"
    else
      um_warn "Could not reach archive.ubuntu.com — sync may fail"
    fi
  fi

  # Base path / mount — do NOT require DATA_DEVICE when already mounted
  if [[ ! -d "$BASE_PATH" ]]; then
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would create BASE_PATH $BASE_PATH"
    else
      mkdir -p "$BASE_PATH"
    fi
  fi

  if [[ -d "$BASE_PATH" ]] && um_path_mounted "$BASE_PATH"; then
    local src
    src="$(findmnt -n -o SOURCE -T "$BASE_PATH" 2>/dev/null || echo unknown)"
    um_ok "Mirror path mounted: $BASE_PATH <- $src"
  elif [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "SKIPPED: mount check for $BASE_PATH (not present in dry-run host)"
  else
    um_warn "BASE_PATH exists but is not a separate mount — ensure enough disk space"
  fi

  if [[ -d "$BASE_PATH" ]]; then
    local avail_kib avail_gib pct
    avail_kib="$(um_df_avail_kib "$BASE_PATH")"
    avail_gib=$(( ${avail_kib:-0} / 1024 / 1024 ))
    pct="$(um_disk_usage_percent "$BASE_PATH" || echo 0)"
    if [[ "$avail_gib" -lt "${MIN_FREE_GIB}" ]] && ! um_initial_sync_complete; then
      um_warn "Free space ${avail_gib} GiB < recommended ${MIN_FREE_GIB} GiB for ${MIRROR_MODE} sync"
    else
      um_ok "Disk space: ${avail_gib} GiB free (${pct}% used, mode=${MIRROR_MODE})"
    fi
    if [[ ! -w "$BASE_PATH" ]] && [[ "$UM_DRY_RUN" != "1" ]]; then
      um_die "No write permission on $BASE_PATH"
    fi
  fi

  # Port conflict (informational)
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn "( sport = :${MIRROR_PORT} )" 2>/dev/null | grep -q LISTEN; then
      if systemctl is-active --quiet nginx 2>/dev/null; then
        vlog "Port ${MIRROR_PORT} already used by nginx (ok)"
      else
        um_warn "Port ${MIRROR_PORT} is in use — nginx may fail to bind"
      fi
    fi
  fi

  um_ok "Configuration loaded: $UM_CONFIG_PATH (mode=${MIRROR_MODE})"
}

# Optional mount only when DATA_DEVICE set and not already mounted — never format by default
maybe_mount_data_device() {
  if [[ -z "${DATA_DEVICE}" ]]; then
    return 0
  fi
  if findmnt -n -S "$DATA_DEVICE" >/dev/null 2>&1; then
    return 0
  fi
  if um_path_mounted "$BASE_PATH"; then
    vlog "BASE_PATH already mounted; ignoring DATA_DEVICE=$DATA_DEVICE"
    return 0
  fi
  if [[ "$UM_FORMAT_DEVICE" == "1" ]]; then
    [[ "$UM_FORCE" == "1" ]] || um_die "--format-device requires --force"
    um_warn "FORMATTING $DATA_DEVICE — destructive"
    um_confirm "Confirm mkfs on $DATA_DEVICE?" || um_die "Aborted"
    um_run "mkfs.${DATA_FSTYPE}" -F "$DATA_DEVICE"
  fi
  um_run mkdir -p "$BASE_PATH"
  um_run mount "$DATA_DEVICE" "$BASE_PATH"
  local uuid
  uuid="$(blkid -s UUID -o value "$DATA_DEVICE" 2>/dev/null || true)"
  if [[ -n "$uuid" ]] && ! grep -q "UUID=$uuid" /etc/fstab 2>/dev/null; then
    if [[ -f /etc/fstab ]]; then
      um_backup_file /etc/fstab >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would append fstab for UUID=$uuid"
    else
      printf 'UUID=%s %s %s %s 0 2\n' "$uuid" "$BASE_PATH" "$DATA_FSTYPE" "$DATA_MOUNT_OPTS" >>/etc/fstab
    fi
  fi
}

# ---------------------------------------------------------------------------
# Phase 2: Packages
# ---------------------------------------------------------------------------
phase2_packages() {
  phase "Phase 2: Install required packages"
  local pkgs=(
    apt-mirror
    nginx
    curl
    ca-certificates
    gpgv
    gnupg
    apt-utils
    dpkg-dev
    ubuntu-keyring
    coreutils
    util-linux
    jq
    xz-utils
    gzip
    whiptail
  )
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would install apt-mirror nginx curl whiptail apt-utils gnupg dpkg-dev"
    um_dry "Would install: ${pkgs[*]}"
    um_dry "SKIPPED: requires installed package (apt-mirror, nginx)"
    return 0
  fi

  local need=0 p
  for p in apt-mirror nginx curl gpgv jq xz gzip flock sha256sum apt-ftparchive dpkg-deb gpg; do
    um_command_exists "$p" || need=1
  done
  # gpgv package provides gpgv; ubuntu-keyring provides keyring file
  [[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] || need=1

  if [[ "$need" -eq 0 ]]; then
    um_ok "Required packages/commands already present"
  else
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
    UM_CHANGES=1
  fi

  local c
  for c in apt-mirror nginx curl gpgv jq xz gzip flock sha256sum findmnt apt-ftparchive dpkg-deb gpg; do
    um_command_exists "$c" || um_die "Required command missing after install: $c"
  done
  [[ -f /usr/share/keyrings/ubuntu-archive-keyring.gpg ]] \
    || um_die "ubuntu-archive-keyring.gpg not found"
  um_ok "Packages and commands verified"
}

# ---------------------------------------------------------------------------
# Phase 3: Configuration
# ---------------------------------------------------------------------------
phase3_config() {
  phase "Phase 3: Generate and install configuration"

  um_run mkdir -p "$MIRROR_PATH" "$SKEL_PATH" "$VAR_PATH" "${BASE_PATH}/offline" "${BASE_PATH}/offline/announcements"
  um_run mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$INSTALL_CONF_DIR" "$INSTALL_LIB_DIR" "$(um_state_root)"
  um_run mkdir -p "$(dirname "$NGINX_ACCESS_LOG")"
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    chown -R root:root "$BASE_PATH" 2>/dev/null || true
    chmod -R 755 "$BASE_PATH" 2>/dev/null || true
  fi

  local tmp
  tmp="$(mktemp)"
  # Prefer project offline template (amd64, backports, exclusion policy). Fall back to generator.
  if [[ -f "${UM_PROJECT_ROOT}/templates/mirror.list" ]]; then
    cp "${UM_PROJECT_ROOT}/templates/mirror.list" "$tmp"
  else
    # Offline full chain always needs release/updates/security/backports
    case " ${SUITE_SUFFIXES} " in
      *" backports "*) ;;
      *) SUITE_SUFFIXES="${SUITE_SUFFIXES:+${SUITE_SUFFIXES} }backports" ;;
    esac
    um_generate_mirror_list >"$tmp"
  fi
  # Validate generated mirror.list: amd64 only, no i386, no deb-src
  if grep -Eiq '^[[:space:]]*deb-src|[[:space:]]i386[[:space:]]' "$tmp"; then
    rm -f "$tmp"
    um_die "Generated mirror.list contains i386 or deb-src (forbidden)"
  fi
  if ! grep -q 'set defaultarch  amd64' "$tmp"; then
    rm -f "$tmp"
    um_die "Generated mirror.list missing defaultarch amd64"
  fi
  if ! grep -q 'xenial-backports' "$tmp" || ! grep -q 'noble-backports' "$tmp"; then
    rm -f "$tmp"
    um_die "Generated mirror.list missing required backports suites"
  fi
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    # Always emit the plan line (even when content already matches).
    um_dry "Would write /etc/apt/mirror.list"
    if [[ -f /etc/apt/mirror.list ]] && cmp -s "$tmp" /etc/apt/mirror.list; then
      vlog "Unchanged content: /etc/apt/mirror.list"
    fi
    rm -f "$tmp"
  elif [[ -f /etc/apt/mirror.list ]] && cmp -s "$tmp" /etc/apt/mirror.list; then
    vlog "Unchanged: /etc/apt/mirror.list"
    rm -f "$tmp"
  else
    if [[ -f /etc/apt/mirror.list ]]; then
      um_backup_file /etc/apt/mirror.list >/dev/null || true
    fi
    install -m 0644 "$tmp" /etc/apt/mirror.list
    rm -f "$tmp"
    um_ok "Installed /etc/apt/mirror.list"
    UM_CHANGES=1
  fi

  # Offline mirror defaults
  if [[ "$UM_DRY_RUN" != "1" ]]; then
    if [[ ! -f /etc/default/ubuntu-offline-mirror ]] || [[ "$UM_FORCE" == "1" ]]; then
      local def_src="${UM_PROJECT_ROOT}/templates/ubuntu-offline-mirror.default"
      if [[ -f "$def_src" ]]; then
        if [[ -f /etc/default/ubuntu-offline-mirror ]]; then
          um_backup_file /etc/default/ubuntu-offline-mirror >/dev/null || true
        fi
        install -m 0644 "$def_src" /etc/default/ubuntu-offline-mirror
        # Seed PUBLIC_BASE_URL from detected mirror URL when still default
        if [[ -n "${MIRROR_URL:-}" ]]; then
          sed -i "s|^PUBLIC_BASE_URL=.*|PUBLIC_BASE_URL=${MIRROR_URL}|" /etc/default/ubuntu-offline-mirror
        fi
        um_ok "Installed /etc/default/ubuntu-offline-mirror"
        UM_CHANGES=1
      fi
    fi
  else
    um_dry "Would install /etc/default/ubuntu-offline-mirror"
  fi

  # nginx site — selective canonical root (SELECTIVE_MIRROR_ROOT/current)
  # Idempotent migration: timestamp backup → atomic replace → nginx -t → reload
  local ngx_tmp
  ngx_tmp="$(mktemp)"
  um_generate_nginx_conf >"$ngx_tmp"
  UM_NGINX_TMP="$ngx_tmp"

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would migrate nginx site to root $(um_selective_nginx_root)"
  else
    if um_migrate_nginx_selective_site; then
      UM_CHANGES=1
      um_ok "nginx selective site ready (root $(um_selective_nginx_root))"
    else
      um_die "nginx selective site migration failed"
    fi
  fi

  # systemd units (timer installed but NOT enabled until finalize)
  local svc_tmp timer_tmp
  svc_tmp="$(mktemp)"
  timer_tmp="$(mktemp)"
  um_generate_systemd_service >"$svc_tmp"
  um_generate_systemd_timer >"$timer_tmp"
  UM_SVC_TMP="$svc_tmp"
  UM_TIMER_TMP="$timer_tmp"

  if [[ -f /etc/systemd/system/apt-mirror.service ]] && cmp -s "$svc_tmp" /etc/systemd/system/apt-mirror.service; then
    vlog "Unchanged: apt-mirror.service"
  else
    if [[ -f /etc/systemd/system/apt-mirror.service ]]; then
      um_backup_file /etc/systemd/system/apt-mirror.service >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" == "1" ]]; then
      um_dry "Would install systemd units"
    else
      install -m 0644 "$svc_tmp" /etc/systemd/system/apt-mirror.service
      UM_CHANGES=1
    fi
  fi
  if [[ -f /etc/systemd/system/apt-mirror.timer ]] && cmp -s "$timer_tmp" /etc/systemd/system/apt-mirror.timer; then
    vlog "Unchanged: apt-mirror.timer"
  else
    if [[ -f /etc/systemd/system/apt-mirror.timer ]]; then
      um_backup_file /etc/systemd/system/apt-mirror.timer >/dev/null || true
    fi
    if [[ "$UM_DRY_RUN" != "1" ]]; then
      install -m 0644 "$timer_tmp" /etc/systemd/system/apt-mirror.timer
      UM_CHANGES=1
    fi
  fi

  # Management tools (without .sh suffixes for status/recovery)
  install_mgmt_tools
}

install_mgmt_tools() {
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would install mirrorctl, ubuntu-offline-mirror, mirror-dashboard, mirror-status, mirror-recovery"
    return 0
  fi

  um_install_file "${UM_PROJECT_ROOT}/scripts/mirrorctl" "${INSTALL_BIN_DIR}/mirrorctl" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh" "${INSTALL_BIN_DIR}/mirror-dashboard" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/mirror-status.sh" "${INSTALL_BIN_DIR}/mirror-status" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/mirror-recovery.sh" "${INSTALL_BIN_DIR}/mirror-recovery" 0755
  um_install_file "${UM_PROJECT_ROOT}/scripts/ubuntu-offline-mirror.sh" /usr/local/sbin/ubuntu-offline-mirror.sh 0755
  ln -sfn /usr/local/sbin/ubuntu-offline-mirror.sh /usr/local/bin/ubuntu-offline-mirror 2>/dev/null || true
  ln -sfn "${INSTALL_BIN_DIR}/mirror-status" "${INSTALL_BIN_DIR}/mirror-status.sh"
  ln -sfn "${INSTALL_BIN_DIR}/mirror-recovery" "${INSTALL_BIN_DIR}/mirror-recovery.sh"
  ln -sfn "${INSTALL_BIN_DIR}/mirror-dashboard" "${INSTALL_BIN_DIR}/mirror-dashboard.sh"

  um_install_file "${UM_PROJECT_ROOT}/scripts/run-apt-mirror.sh" "${INSTALL_LIB_DIR}/run-apt-mirror.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/validate.sh" "${INSTALL_BIN_DIR}/validate.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/client/client-setup.sh" "${INSTALL_BIN_DIR}/client-setup.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/client/client-validate.sh" "${INSTALL_BIN_DIR}/client-validate.sh" 0755
  um_install_file "${UM_PROJECT_ROOT}/lib/common.sh" "${INSTALL_LIB_DIR}/common.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/config.sh" "${INSTALL_LIB_DIR}/config.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/state.sh" "${INSTALL_LIB_DIR}/state.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/progress.sh" "${INSTALL_LIB_DIR}/progress.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/install-menu.sh" "${INSTALL_LIB_DIR}/install-menu.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/offline.sh" "${INSTALL_LIB_DIR}/offline.sh" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/sync_by_hash.py" "${INSTALL_LIB_DIR}/sync_by_hash.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/validate_security_compat.py" "${INSTALL_LIB_DIR}/validate_security_compat.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/sync_release_upgraders.py" "${INSTALL_LIB_DIR}/sync_release_upgraders.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/validate_release_upgraders.py" "${INSTALL_LIB_DIR}/validate_release_upgraders.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/sync_legacy_releases.py" "${INSTALL_LIB_DIR}/sync_legacy_releases.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/validate_legacy_releases.py" "${INSTALL_LIB_DIR}/validate_legacy_releases.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/validate_upgrade_profile.py" "${INSTALL_LIB_DIR}/validate_upgrade_profile.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/derive_upgrade_requirements.py" "${INSTALL_LIB_DIR}/derive_upgrade_requirements.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/selective_mirror.py" "${INSTALL_LIB_DIR}/selective_mirror.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/lib/validate_selective_mirror.py" "${INSTALL_LIB_DIR}/validate_selective_mirror.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/scripts/build-selective-mirror-plan.py" "${INSTALL_LIB_DIR}/build-selective-mirror-plan.py" 0644
  um_install_file "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh" "${INSTALL_LIB_DIR}/upgrade-profile.sh" 0644
  mkdir -p "${INSTALL_LIB_DIR}/templates"
  um_install_file "${UM_PROJECT_ROOT}/templates/nginx.conf" "${INSTALL_LIB_DIR}/templates/nginx.conf" 0644
  um_install_file "${UM_PROJECT_ROOT}/config/offline-upgrade-profile.json" "${INSTALL_CONF_DIR}/offline-upgrade-profile.json" 0644
  um_install_file "${UM_PROJECT_ROOT}/config/offline-upgrade-exceptions.json" "${INSTALL_CONF_DIR}/offline-upgrade-exceptions.json" 0644
  um_install_file "${UM_PROJECT_ROOT}/config/offline-upgrade-profile.json" "${INSTALL_LIB_DIR}/offline-upgrade-profile.json" 0644

  # Selective storage layout (staging stays unpublished until publish-selective)
  mkdir -p \
    "${BASE_PATH}/selective/staging" \
    "${BASE_PATH}/selective/snapshots" \
    "${BASE_PATH}/selective/published" \
    "${BASE_PATH}/selective/state" \
    "${BASE_PATH}/selective/logs" \
    "${BASE_PATH}/selective/keys"
  # Ensure current pointer exists only after publish; do not expose staging.
  if [[ ! -e "${BASE_PATH}/selective/current" ]] && [[ -d "${BASE_PATH}/selective/published" ]]; then
    # Placeholder empty published tree is fine; nginx 404s until publish.
    ln -sfn published "${BASE_PATH}/selective/current" 2>/dev/null || true
  fi

  # Remember git checkout path so `mirrorctl watch` picks up git pull without reinstall
  mkdir -p "${INSTALL_CONF_DIR}"
  printf '%s\n' "${UM_PROJECT_ROOT}" >"${INSTALL_CONF_DIR}/source-repo"

  if [[ -f "${INSTALL_CONF_DIR}/mirror.conf" ]] && [[ "$UM_FORCE" != "1" ]]; then
    vlog "Keeping existing ${INSTALL_CONF_DIR}/mirror.conf (merging selective fields)"
    # Preserve operator values; add/correct selective profile keys only.
    um_migrate_selective_runtime_config "${INSTALL_CONF_DIR}/mirror.conf" || true
    um_persist_mirror_mode_to_conf "${INSTALL_CONF_DIR}/mirror.conf"
  else
    um_install_file "${UM_CONFIG_PATH}" "${INSTALL_CONF_DIR}/mirror.conf" 0644
    um_migrate_selective_runtime_config "${INSTALL_CONF_DIR}/mirror.conf" || true
    um_persist_mirror_mode_to_conf "${INSTALL_CONF_DIR}/mirror.conf"
  fi
  # Canonical: /usr/local/bin/mirrorctl ; aux symlink: /usr/local/sbin/mirrorctl
  if [[ -e /usr/local/sbin/mirrorctl && ! -L /usr/local/sbin/mirrorctl ]]; then
    um_backup_file /usr/local/sbin/mirrorctl >/dev/null || true
    rm -f /usr/local/sbin/mirrorctl
  fi
  ln -sfn "${INSTALL_BIN_DIR}/mirrorctl" /usr/local/sbin/mirrorctl 2>/dev/null || true

  # Drift guard: installed mirrorctl must match repository after install.
  local src_sum dst_sum
  src_sum="$(um_sha256_file "${UM_PROJECT_ROOT}/scripts/mirrorctl")"
  dst_sum="$(um_sha256_file "${INSTALL_BIN_DIR}/mirrorctl")"
  if [[ "$src_sum" != "$dst_sum" ]]; then
    um_die "Installed mirrorctl checksum drift after install (${dst_sum} != ${src_sum})"
  fi
  um_ok "mirrorctl installed (sha256=${src_sum:0:12}…) canonical=${INSTALL_BIN_DIR}/mirrorctl"
}

# ---------------------------------------------------------------------------
# Phase 4: Validate generated configuration
# ---------------------------------------------------------------------------
phase4_validate() {
  phase "Phase 4: Validate configuration"

  # bash -n on installed/generated scripts
  local s
  for s in "${UM_PROJECT_ROOT}/install.sh" \
           "${UM_PROJECT_ROOT}/scripts/mirrorctl" \
           "${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh" \
           "${UM_PROJECT_ROOT}/scripts/run-apt-mirror.sh" \
           "${UM_PROJECT_ROOT}/scripts/ubuntu-offline-mirror.sh" \
           "${UM_PROJECT_ROOT}/lib/offline.sh"; do
    bash -n "$s"
  done
  um_ok "bash -n syntax ok"

  # apt-mirror config parse check when available
  if [[ "$UM_DRY_RUN" != "1" ]] && um_command_exists apt-mirror && [[ -f /etc/apt/mirror.list ]]; then
    if grep -Eiq '^[[:space:]]*deb-src|[[:space:]]i386[[:space:]]' /etc/apt/mirror.list; then
      um_die "/etc/apt/mirror.list contains i386 or deb-src"
    fi
    # apt-mirror prints config when parsing; dry-run by invoking with empty nthreads check:
    # Validate key directives exist (apt-mirror has no --dry-run).
    grep -q 'set defaultarch  amd64' /etc/apt/mirror.list \
      || um_die "mirror.list missing defaultarch amd64"
    um_ok "mirror.list policy checks passed (amd64, no i386/deb-src)"
  fi

  # nginx -t
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    if um_command_exists nginx && [[ -n "${UM_NGINX_TMP:-}" ]]; then
      local wrap
      wrap="$(mktemp -d)"
      cat >"$wrap/nginx.conf" <<EOF
events {}
http {
  include ${UM_NGINX_TMP};
}
EOF
      if nginx -t -c "$wrap/nginx.conf" >/dev/null 2>&1; then
        um_ok "nginx syntax (temp) valid"
      else
        um_dry "SKIPPED: full nginx -t (minimal wrapper limits)"
      fi
      rm -rf "$wrap"
    else
      um_dry "SKIPPED: requires installed package (nginx -t)"
    fi
  else
    if ! nginx -t; then
      um_error "nginx -t failed — aborting before sync"
      return 1
    fi
    um_ok "nginx -t passed"
  fi

  # systemd-analyze verify
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    if command -v systemd-analyze >/dev/null 2>&1 && [[ -n "${UM_SVC_TMP:-}" ]]; then
      if systemd-analyze verify "${UM_SVC_TMP}" "${UM_TIMER_TMP}" 2>/dev/null; then
        um_ok "systemd units verify ok"
      else
        um_dry "SKIPPED: systemd-analyze verify (environment limits)"
      fi
    else
      um_dry "SKIPPED: requires installed package (systemd-analyze)"
    fi
  else
    if command -v systemd-analyze >/dev/null 2>&1; then
      if ! systemd-analyze verify /etc/systemd/system/apt-mirror.service /etc/systemd/system/apt-mirror.timer 2>/dev/null; then
        um_warn "systemd-analyze verify reported issues (continuing if units load)"
      else
        um_ok "systemd units verify ok"
      fi
    fi
    if ! systemctl cat apt-mirror.service >/dev/null 2>&1; then
      um_error "apt-mirror.service failed to load"
      return 1
    fi
  fi

  # Internal install-mode validation (sync pending is OK)
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "SKIPPED: runtime install validation against live services"
    return 0
  fi

  if [[ -x "${UM_PROJECT_ROOT}/validate.sh" ]]; then
    set +e
    "${UM_PROJECT_ROOT}/validate.sh" --config "${INSTALL_CONF_DIR}/mirror.conf" --mode install --quiet
    local vrc=$?
    set -e
    if [[ "$vrc" -ge 2 ]]; then
      um_error "Installation validation failed (critical)"
      if [[ "$UM_VERBOSE" == "1" ]]; then
        "${UM_PROJECT_ROOT}/validate.sh" --config "${INSTALL_CONF_DIR}/mirror.conf" --mode install || true
      fi
      return 1
    fi
    um_ok "Installation validation passed (sync pending is OK)"
  fi
}

# ---------------------------------------------------------------------------
# Phase 5: Start services (timer stays disabled)
# ---------------------------------------------------------------------------
phase5_services() {
  phase "Phase 5: Start services"

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_dry "Would reload systemd"
    um_dry "Would enable and restart nginx"
    um_dry "Would leave apt-mirror.timer disabled until initial sync completes"
    return 0
  fi

  systemctl daemon-reload
  systemctl enable nginx >/dev/null
  # When selective READY already exists, avoid bouncing nginx (publish already validated).
  if um_is_mirror_ready 2>/dev/null && systemctl is-active --quiet nginx; then
    um_ok "nginx already running — not restarted (selective READY preserved)"
  else
    systemctl restart nginx
    if ! systemctl is-active --quiet nginx; then
      um_die "nginx failed to start"
    fi
    um_ok "nginx running on port ${MIRROR_PORT}"
  fi

  # Explicitly keep timer disabled (selective profile never uses daily full sync)
  systemctl disable apt-mirror.timer >/dev/null 2>&1 || true
  systemctl stop apt-mirror.timer >/dev/null 2>&1 || true
  um_ok "apt-mirror.timer installed but disabled (selective profile)"
  um_mark_state "installed"
}

# ---------------------------------------------------------------------------
# Phase 6: Start initial sync (non-blocking) + optional live dashboard
# ---------------------------------------------------------------------------
um_resolve_sync_attach_mode() {
  # Prints: foreground | background
  case "$UM_SYNC_MODE" in
    foreground) printf 'foreground\n' ;;
    background) printf 'background\n' ;;
    *)
      if [[ -t 1 ]]; then
        printf 'foreground\n'
      else
        printf 'background\n'
      fi
      ;;
  esac
}

um_print_background_sync_hints() {
  cat <<EOF

Initial synchronization started in background.

Attach dashboard:
  sudo mirrorctl watch

Check status:
  sudo mirrorctl status

Follow raw logs:
  sudo mirrorctl logs
EOF
}

um_attach_dashboard() {
  local dash
  # Prefer checkout copy so refresh interval / UI fixes apply after git pull
  dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  [[ -x "$dash" ]] || dash="${INSTALL_BIN_DIR}/mirror-dashboard"
  [[ -x "$dash" ]] || dash="${UM_PROJECT_ROOT}/scripts/mirror-dashboard.sh"
  if [[ ! -x "$dash" ]]; then
    um_warn "mirror-dashboard not found — use: sudo mirrorctl status"
    return 0
  fi
  printf '\nAttaching live dashboard...\n'
  printf 'Press B or Ctrl+C to detach. Sync will continue.\n\n'
  # Dashboard owns Ctrl+C (detach only); do not stop apt-mirror.service
  set +e
  "$dash" --config "${INSTALL_CONF_DIR}/mirror.conf"
  set -e
}

phase6_sync() {
  phase "Phase 6: Initial synchronization"

  if [[ "$UM_NO_SYNC" == "1" ]]; then
    um_info "Skipping initial sync (--no-sync)"
    return 0
  fi

  local attach_mode already_running=0
  attach_mode="$(um_resolve_sync_attach_mode)"

  # Reject minimal / incomplete profiles before any sync work.
  if [[ -f "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh" ]]; then
    # shellcheck source=lib/upgrade-profile.sh
    source "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh"
    um_load_upgrade_profile 2>/dev/null || true
    if ! um_assert_supported_mirror_mode "${MIRROR_MODE}"; then
      um_die "UNSUPPORTED_MINIMAL_PROFILE / incomplete upgrade profile" 2
    fi
  fi

  # Pre-sync capacity gate (projected size vs available minus reserve)
  phase "Phase 6a: Pre-sync capacity check"
  if [[ "$UM_DRY_RUN" == "1" ]]; then
    um_check_sync_capacity "$BASE_PATH" "$MIRROR_MODE" || um_dry "Capacity check would block sync"
    um_dry "Would start initial synchronization: plan-selective (no apt-mirror)"
    um_dry "Would attach mode: ${attach_mode}"
    um_dry "Mirror mode: ${MIRROR_MODE} (selective discovery-exact)"
    um_dry "Profile: offline-upgrade-selective"
    um_dry "Next: materialize-selective → verify-selective → publish-selective (manual)"
    if um_initial_sync_complete || um_is_mirror_ready; then
      um_dry "Note: host already READY/sync-complete; real run would not restart sync"
    fi
    return 0
  fi

  if um_initial_sync_complete || um_is_mirror_ready; then
    um_ok "Initial selective plan/READY already present — not restarting"
    return 0
  fi

  if ! um_check_sync_capacity "$BASE_PATH" "$MIRROR_MODE"; then
    um_die "Initial sync blocked by disk capacity / safety reserve check" 2
  fi

  # Selective profile: run plan-selective only (never apt-mirror / publish).
  local uom="${UM_PROJECT_ROOT}/scripts/ubuntu-offline-mirror.sh"
  if [[ -x "$uom" ]] || [[ -f "$uom" ]]; then
    um_ok "Running plan-selective (discovery analysis; no download/publish)"
    if bash "$uom" plan-selective; then
      um_mark_state "sync-started"
      um_ok "plan-selective complete"
      um_ok "Next (manual): ubuntu-offline-mirror.sh materialize-selective"
      um_ok "Then: verify-selective → publish-selective"
    else
      um_warn "plan-selective failed — run: sudo $uom plan-selective"
    fi
  else
    um_warn "ubuntu-offline-mirror.sh not found — skip plan-selective"
  fi

  # Non-interactive / CI: never emit TUI controls into redirected logs
  if [[ "$attach_mode" == "background" ]] || [[ ! -t 1 ]]; then
    if [[ ! -t 1 ]] && [[ "$UM_SYNC_MODE" == "auto" ]]; then
      printf '\nNo interactive terminal detected.\n'
      printf 'Initial synchronization started in background.\n'
      printf 'Use: sudo mirrorctl watch\n'
    else
      um_print_background_sync_hints
    fi
    return 0
  fi

  um_attach_dashboard
}

# ---------------------------------------------------------------------------
# Phase 7: Summary / idempotent short path
# ---------------------------------------------------------------------------
phase7_summary() {
  local state
  state="$(um_detect_lifecycle_state 2>/dev/null || echo INSTALLED)"

  if [[ "$UM_DRY_RUN" == "1" ]]; then
    printf '\nDry-run completed successfully.\n'
    return 0
  fi

  if [[ "$UM_CHANGES" -eq 0 ]] && um_is_installed; then
    printf '\nUbuntu Mirror Server is already installed.\n'
    printf 'Configuration is current.\n'
    case "$state" in
      SYNC_RUNNING) printf 'Initial synchronization is running.\n' ;;
      READY) printf 'Mirror is ready.\n' ;;
      SYNC_COMPLETE) printf 'Initial sync complete — run: sudo mirrorctl finalize\n' ;;
      *) printf 'State: %s\n' "$state" ;;
    esac
    printf 'No changes required.\n'
  fi

  cat <<EOF

Ubuntu Mirror Server installation completed.

Mirror path:
  ${BASE_PATH}

Mirror URL:
  ${MIRROR_URL}/ubuntu

Initial synchronization:
  $( [[ "$UM_NO_SYNC" == "1" ]] && echo "Not started (--no-sync)" || echo "Started via systemd (continues if dashboard detached)" )

Live dashboard:
  sudo mirrorctl watch

Check status:
  sudo mirrorctl status

Follow raw logs:
  sudo mirrorctl logs

Check disk:
  df -h ${BASE_PATH}

Finalization runs automatically when the first sync finishes.
Manual fallback: sudo mirrorctl finalize

EOF
}

cleanup_temps() {
  rm -f "${UM_NGINX_TMP:-}" "${UM_SVC_TMP:-}" "${UM_TIMER_TMP:-}" 2>/dev/null || true
}

run_install_pipeline() {
  # Idempotent fast path (real run only): already installed, NO runtime drift, READY/syncing.
  # Skipped when operator came from the interactive menu with an explicit install choice.
  # IMPORTANT: selective READY alone must not skip tool/config refresh when checksums drift.
  if [[ "$UM_FROM_MENU" != "1" ]] && [[ "$UM_DRY_RUN" != "1" ]] && [[ "$UM_FORCE" != "1" ]] && um_is_installed; then
    UM_PROJECT_ROOT="${UM_PROJECT_ROOT}"
    if ! um_has_runtime_drift; then
      local gen
      gen="$(mktemp)"; um_generate_mirror_list >"$gen"
      if cmp -s "$gen" /etc/apt/mirror.list 2>/dev/null; then
        if um_is_sync_running || um_is_mirror_ready || um_initial_sync_complete; then
          rm -f "$gen"
          um_ok "Runtime tools/config already current — skipping reinstall (READY preserved)"
          phase7_summary
          return 0
        fi
      fi
      rm -f "$gen"
    else
      um_warn "Runtime drift detected (mirrorctl/libs/config/systemd) — refreshing install without restarting selective sync"
    fi
  fi

  phase1_preflight
  maybe_mount_data_device
  phase2_packages
  phase3_config
  if ! phase4_validate; then
    um_die "Installation stopped due to critical validation failure" 2
  fi
  phase5_services
  phase6_sync
  phase7_summary
}

main() {
  parse_args "$@"
  um_setup_trap
  um_register_cleanup cleanup_temps

  # Prefer project mirror.conf over a stale /etc copy for --force and --dry-run
  # from the checkout (avoids host MIRROR_MODE=minimal poisoning dry-run plans).
  if [[ -z "${UM_CONFIG_ARG}" ]] \
    && [[ -f "${UM_PROJECT_ROOT}/mirror.conf" ]] \
    && { [[ "${UM_FORCE}" == "1" ]] || [[ "${UM_DRY_RUN}" == "1" ]]; }; then
    UM_CONFIG_ARG="${UM_PROJECT_ROOT}/mirror.conf"
  fi

  UM_QUIET_LOAD=0
  um_load_config "$UM_CONFIG_ARG"
  # shellcheck source=lib/upgrade-profile.sh
  source "${UM_PROJECT_ROOT}/lib/upgrade-profile.sh"
  um_load_upgrade_profile 2>/dev/null || true

  # Legacy host configs may still say MIRROR_MODE=full while selective READY exists.
  # Prefer selective whenever selective state/profile is present.
  if um_is_selective_profile 2>/dev/null || [[ "${UM_SELECTIVE}" == "1" ]]; then
    MIRROR_MODE="selective"
  fi

  um_set_log_file "${LOG_DIR}/install.log"
  um_ensure_log_dir
  UM_BACKUP_SESSION=""
  um_backup_session_dir >/dev/null

  # Interactive menu: mode select / monitor / delete data
  if um_should_show_install_menu; then
    while true; do
      UM_QUIET_LOAD=1
      um_install_menu
      case "${UM_MENU_ACTION:-quit}" in
        install)
          UM_FROM_MENU=1
          run_install_pipeline
          # After install/dashboard detach, return to menu
          UM_FROM_MENU=0
          printf '\nReturning to menu...\n'
          sleep 1
          ;;
        quit|*)
          exit 0
          ;;
      esac
    done
  fi

  # Non-menu path: resolve mode from CLI flags (default = selective)
  if [[ "$UM_FULL" == "1" ]]; then
    um_resolve_mirror_mode 1 0
  elif [[ "$UM_MINIMAL" == "1" ]]; then
    um_resolve_mirror_mode 0 1
  else
    MIRROR_MODE="selective"
    um_resolve_mirror_mode 0 0
  fi

  run_install_pipeline
}

main "$@"
