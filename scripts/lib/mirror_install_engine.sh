#!/usr/bin/env bash
# scripts/lib/mirror_install_engine.sh — single R2 + ACPS install workflow
# No mode selection. No current/previous/release lifecycle. No rollback.
# shellcheck shell=bash
set +x

if [[ -n "${MIRROR_INSTALL_ENGINE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_INSTALL_ENGINE_LOADED=1

# Requires: mirror_manager_common.sh, dp-phase2-common.sh, acps_acquire.sh, r2_acquire.sh

engine_preflight_host() {
  mm_require_root
  mm_require_cmds bash curl tar sha1sum sha256sum awk flock stat df readlink mv ln find mkdir chmod python3 mktemp sed grep
  mm_ok "PREFLIGHT_HOST=PASS"
}

engine_resolve_paths() {
  MM_MIRROR_ROOT="${MM_MIRROR_ROOT:-/var/spool/apt-mirror}"
  MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-${MM_MIRROR_ROOT}/selective}"
  MM_DP_PHASE2_ROOT="${MM_DP_PHASE2_ROOT:-${MM_MIRROR_ROOT}/dp-phase2}"
  MM_CLIENT_ROOT="${MM_CLIENT_ROOT:-${MM_MIRROR_ROOT}/client}"
  DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT"
  MM_CACHE_ROOT="${MM_CACHE_ROOT:-${MM_MIRROR_ROOT}/.install-cache}"
  mm_info "MIRROR_ROOT=${MM_MIRROR_ROOT}"
  mm_info "SELECTIVE_ROOT=${MM_SELECTIVE_ROOT}"
  mm_info "DP_PHASE2_ROOT=${MM_DP_PHASE2_ROOT}"
}

engine_verify_disk_space() {
  mm_calc_disk_requirements
}

engine_verify_os_core_package() {
  local package="$1"
  mm_assert_regular_file "$package" "os-core-package"
  OS_CORE_PACKAGE_BYTES="$(mm_file_bytes "$package")"
  local py="${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py"
  local out
  out="$(python3 "$py" verify --package "$package" ${OS_CORE_PUBLIC_KEY:+--public-key "$OS_CORE_PUBLIC_KEY"} )"
  printf '%s\n' "$out"
  OS_CORE_PAYLOAD_BYTES="$(printf '%s\n' "$out" | awk -F= '/^PAYLOAD_BYTES=/{print $2; exit}')"
  OS_CORE_RELEASE_ID="$(printf '%s\n' "$out" | awk -F= '/^RELEASE_ID=/{print $2; exit}')"
  OS_CORE_PAYLOAD_BYTES="${OS_CORE_PAYLOAD_BYTES:-0}"
  mm_state_set R2_OS_CORE_CHECKSUM PASS
  mm_ok "VERIFY_OS_CORE=PASS release_id=${OS_CORE_RELEASE_ID}"
}

engine_materialize_os_mirror() {
  # Extract verified OS Core into selective root directly (no current/previous/releases).
  local package="$1"
  local staging_extract
  staging_extract="${MM_CACHE_ROOT}/os-core-extract/$(mm_run_id)"
  local final_tmp="${MM_SELECTIVE_ROOT}.new.$$"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip materialize_os_mirror"
    return 0
  fi

  rm -rf "$staging_extract"
  python3 "${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py" extract-staging \
    --package "$package" \
    --staging-dir "$staging_extract" \
    ${OS_CORE_PUBLIC_KEY:+--public-key "$OS_CORE_PUBLIC_KEY"}

  local payload="${staging_extract}/ubuntu-os-core/payload"
  [[ -d "$payload" ]] || mm_die "OS_CORE_PAYLOAD_MISSING"

  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    [[ -d "${payload}/hops/${hop}" ]] || mm_die "OS_MIRROR_READY=FAIL hop=${hop}"
  done

  rm -rf "$final_tmp"
  mkdir -p "$final_tmp"
  cp -a "$payload"/. "$final_tmp"/
  # Ensure ubuntu alias for nginx /ubuntu/
  if [[ ! -e "${final_tmp}/ubuntu" ]]; then
    ln -sfn hops/jammy-to-noble/ubuntu "${final_tmp}/ubuntu"
  fi

  mkdir -p "$(dirname "$MM_SELECTIVE_ROOT")"
  # Replace selective content in place without current/previous generations.
  # Preserve keys/ if present outside payload.
  local keys_backup=""
  if [[ -d "${MM_SELECTIVE_ROOT}/keys" ]]; then
    keys_backup="${MM_CACHE_ROOT}/keys-backup.$$"
    cp -a "${MM_SELECTIVE_ROOT}/keys" "$keys_backup"
  fi

  # Remove obsolete generation dirs if somehow present under selective (do not touch production outside MM_MIRROR_ROOT tests).
  rm -rf "${MM_SELECTIVE_ROOT}.old.$$"
  if [[ -d "$MM_SELECTIVE_ROOT" ]]; then
    mv -f "$MM_SELECTIVE_ROOT" "${MM_SELECTIVE_ROOT}.old.$$"
  fi
  mv -f "$final_tmp" "$MM_SELECTIVE_ROOT"
  if [[ -n "$keys_backup" && -d "$keys_backup" ]]; then
    rm -rf "${MM_SELECTIVE_ROOT}/keys"
    mv -f "$keys_backup" "${MM_SELECTIVE_ROOT}/keys"
  fi
  rm -rf "${MM_SELECTIVE_ROOT}.old.$$" "$staging_extract"

  # Explicitly do not create current/previous/published.previous/os-core-releases
  rm -rf \
    "${MM_SELECTIVE_ROOT}/current" \
    "${MM_SELECTIVE_ROOT}/previous" \
    "${MM_SELECTIVE_ROOT}/published" \
    "${MM_SELECTIVE_ROOT}/published.previous" \
    "${MM_SELECTIVE_ROOT}/os-core-releases" \
    "${MM_SELECTIVE_ROOT}/releases" 2>/dev/null || true

  mm_mark_changed
  mm_state_set OS_MIRROR_READY PASS
  mm_ok "OS_MIRROR_MATERIALIZE=PASS path=${MM_SELECTIVE_ROOT}"
}

engine_verify_acps_upstream_bringup() {
  local files_dir="$1"
  local baseline="${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
  local upstream_file="${files_dir}/bringup_py3_dp_after_os_upgrade.sh"
  [[ -f "$baseline" ]] || mm_die "UPSTREAM_BASELINE_MISSING path=${baseline}"
  [[ -f "$upstream_file" ]] || mm_die "UPSTREAM_BRINGUP_MISSING"
  local expected actual
  expected="$(awk '{print $1; exit}' "$baseline")"
  actual="$(sha1sum "$upstream_file" | awk '{print $1}')"
  if [[ "${expected,,}" != "${actual,,}" ]]; then
    mm_error "UPSTREAM_BRINGUP_DRIFT=YES"
    mm_error "EXPECTED_UPSTREAM_SHA1=${expected}"
    mm_error "ACTUAL_UPSTREAM_SHA1=${actual}"
    mm_error "HTTP_DISTRIBUTION_READY=NO"
    mm_error "INSTALL_RESULT=FAIL"
    mm_state_set UPSTREAM_BRINGUP_DRIFT YES
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "UPSTREAM_BRINGUP_DRIFT=YES"
  fi
  mm_state_set UPSTREAM_BRINGUP_DRIFT NO
  BRINGUP_UPSTREAM_SHA1="$actual"
  mm_ok "VERIFY_ACPS_UPSTREAM=PASS sha1=${actual}"
}

engine_apply_local_bringup_patch() {
  local files_dir="$1"
  local patched="${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
  [[ -f "$patched" ]] || mm_die "LOCAL_PATCHED_BRINGUP_MISSING"
  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip apply_local_bringup_patch"
    return 0
  fi
  cp -f "$patched" "${files_dir}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${files_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  BRINGUP_PATCHED_SHA1="$(sha1sum "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  local want
  want="$(sha1sum "$patched" | awk '{print $1}')"
  [[ "${BRINGUP_PATCHED_SHA1,,}" == "${want,,}" ]] || mm_die "PATCHED_BRINGUP_SHA1=FAIL"
  mm_state_set PATCHED_BRINGUP_APPLIED YES
  mm_ok "PATCHED_BRINGUP_APPLIED=YES sha1=${BRINGUP_PATCHED_SHA1}"
}

engine_place_dp_phase2_final() {
  # Build bundle in staging, then place ONLY final HTTP artifacts into version dir (direct, no symlink).
  local files_src="$1"
  local ver="$2"
  dp2_set_version "$ver"
  DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip place_dp_phase2_final"
    return 0
  fi

  local staging work_files
  staging="${MM_CACHE_ROOT}/dp-build/$(mm_run_id)"
  work_files="${staging}/files"
  rm -rf "$staging"
  mkdir -p "$work_files"

  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    cp -f "${files_src}/${f}" "${work_files}/${f}"
  done
  dp2_assert_exact_files_dir "$work_files"
  dp2_verify_payload_checksums "$work_files"

  local list_count stable
  list_count="$(dp2_check_image_list "${work_files}/images-${ver}.list" | tail -n1)"
  stable="$(dp2_stable_bundle_name)"

  (
    cd "$work_files" || exit 1
    tar -cf "${staging}/${stable}" "${DP_PHASE2_REQUIRED_FILES[@]}"
  )
  dp2_assert_safe_tar_list "${staging}/${stable}"
  sha256sum "${staging}/${stable}" | awk '{print $1"  '"${stable}"'"}' >"${staging}/${stable}.sha256"
  dp2_verify_sha256_pair "${staging}/${stable}" "${staging}/${stable}.sha256"

  local created_at commit
  created_at="$(mm_ts)"
  commit="$(git -C "${MM_PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
  cat >"${staging}/release.env" <<EOF
TARGET_DP_VERSION=${ver}
PHASE2_ARTIFACT_VERSION=${ver}
# Deprecated alias for older consumers; prefer TARGET_DP_VERSION.
DP_PHASE2_VERSION=${ver}
CREATED_AT=${created_at}
FILE_COUNT=${DP_PHASE2_FILE_COUNT}
STABLE_BUNDLE_NAME=${stable}
IMAGE_LIST_COUNT=${list_count}
SOURCE_HOST=acps
SOURCE_PATH=provision
VERIFICATION_RESULT=PASS
SOURCE_REPOSITORY_COMMIT=${commit}
BRINGUP_UPSTREAM_SHA1=${BRINGUP_UPSTREAM_SHA1:-}
BRINGUP_PATCHED_SHA1=${BRINGUP_PATCHED_SHA1:-}
ACPS_SOURCE_VERSION=${ver}
EOF
  if dp2_release_has_secret "${staging}/release.env"; then
    mm_die "RELEASE_ENV_SECRET=FAIL"
  fi

  # Validate patched bringup inside bundle entries
  local actual want
  actual="$(sha1sum "${work_files}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  want="$(sha1sum "${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  [[ "${actual,,}" == "${want,,}" ]] || mm_die "VALIDATE_DP=FAIL patched_bringup_sha1"

  local dest="${MM_DP_PHASE2_ROOT}/${ver}"
  local dest_tmp="${dest}.new.$$"
  rm -rf "$dest_tmp"
  mkdir -p "$dest_tmp"
  cp -f "${staging}/release.env" "${dest_tmp}/release.env"
  cp -f "${staging}/${stable}" "${dest_tmp}/${stable}"
  cp -f "${staging}/${stable}.sha256" "${dest_tmp}/${stable}.sha256"

  # Replace final version directory with the single artifact set (no releases/, no current/previous).
  mkdir -p "$(dirname "$dest")"
  rm -rf "${dest}.old.$$"
  if [[ -e "$dest" ]]; then
    mv -f "$dest" "${dest}.old.$$"
  fi
  mv -f "$dest_tmp" "$dest"
  rm -rf "${dest}.old.$$" "$staging"

  # Ensure obsolete generation paths are absent under this version root
  rm -rf "${dest}/releases" "${dest}/current" "${dest}/previous" "${dest}/.staging" "${dest}/files" 2>/dev/null || true
  # If current/previous were symlinks at version root level already replaced by dest dir — good.
  # Clean any sibling generation leftovers only inside dest.
  if [[ -L "${MM_DP_PHASE2_ROOT}/${ver}/current" || -d "${MM_DP_PHASE2_ROOT}/${ver}/releases" ]]; then
    :
  fi

  PHASE2_BUNDLE_ENTRY_COUNT="${DP_PHASE2_FILE_COUNT}"
  mm_state_set PHASE2_BUNDLE_ENTRY_COUNT "$PHASE2_BUNDLE_ENTRY_COUNT"
  mm_state_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_mark_changed
  mm_ok "DP_PHASE2_FINAL=PASS path=${dest} bundle=${stable}"
}

engine_validate_http_layout() {
  # Validate on-disk layout matching client HTTP URL contract (no production nginx reload).
  local ver="${TARGET_DP_VERSION:-$DP_PHASE2_VERSION}"
  local sel="$MM_SELECTIVE_ROOT"
  local dp="${MM_DP_PHASE2_ROOT}/${ver}"
  local stable
  stable="$(dp2_stable_bundle_name)"

  [[ -d "${sel}/ubuntu" || -L "${sel}/ubuntu" ]] || mm_die "HTTP_LAYOUT=FAIL missing /ubuntu tree"
  [[ -d "${sel}/shared/offline" ]] || mm_die "HTTP_LAYOUT=FAIL missing /offline tree"
  [[ -d "${MM_CLIENT_ROOT}" ]] || mkdir -p "${MM_CLIENT_ROOT}"
  [[ -f "${dp}/release.env" ]] || mm_die "HTTP_LAYOUT=FAIL missing release.env"
  [[ -f "${dp}/${stable}" ]] || mm_die "HTTP_LAYOUT=FAIL missing ${stable}"
  [[ -f "${dp}/${stable}.sha256" ]] || mm_die "HTTP_LAYOUT=FAIL missing ${stable}.sha256"
  dp2_verify_sha256_pair "${dp}/${stable}" "${dp}/${stable}.sha256"

  # Refuse generation structures
  if [[ -L "${dp}/current" || -L "${dp}/previous" || -d "${dp}/releases" ]]; then
    mm_die "HTTP_LAYOUT=FAIL generation_structure_present"
  fi
  if [[ -L "${sel}/current" || -e "${sel}/published.previous" ]]; then
    mm_die "HTTP_LAYOUT=FAIL selective_generation_structure_present"
  fi

  if [[ "${MM_SKIP_HTTP_VALIDATE:-0}" == "1" ]]; then
    mm_warn "HTTP_VALIDATION=SKIPPED_NETWORK"
    mm_state_set HTTP_CONFIGURATION_READY PASS
    return 0
  fi

  if [[ "${MM_HTTP_VALIDATE_MOCK_FAIL:-0}" == "1" ]]; then
    mm_error "HTTP_VALIDATION=FAIL mock"
    mm_state_set HTTP_CONFIGURATION_READY FAIL
    return 1
  fi

  local base="${MM_VERIFY_HTTP_BASE}"
  local urls=(
    "${base}/ubuntu/"
    "${base}/ubuntu-security/"
    "${base}/offline/"
    "${base}/client/"
    "${base}/dp-phase2/${ver}/release.env"
    "${base}/dp-phase2/${ver}/${stable}.sha256"
  )
  local u code
  for u in "${urls[@]}"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$u" 2>/dev/null || echo 000)"
    if [[ "$code" == "404" || "$code" == "000" || "$code" == "500" ]]; then
      mm_error "HTTP_VALIDATION=FAIL url=${u} code=${code}"
      mm_state_set HTTP_CONFIGURATION_READY FAIL
      return 1
    fi
    mm_info "HTTP_CHECK url=${u} code=${code}"
  done
  mm_state_set HTTP_CONFIGURATION_READY PASS
  mm_ok "HTTP_VALIDATION=PASS"
  return 0
}

engine_cleanup_temps() {
  local ver="${TARGET_DP_VERSION:-}"
  r2_cleanup_package || true
  if [[ -n "$ver" ]]; then
    acps_cleanup_cache "$ver" || true
  fi
  rm -rf "${MM_CACHE_ROOT}/os-core-extract" "${MM_CACHE_ROOT}/dp-build" "${MM_CACHE_ROOT}/acps-work" 2>/dev/null || true
  find "${MM_CACHE_ROOT}" -name '*.part' -type f -delete 2>/dev/null || true
  mm_ok "TEMP_CLEANUP=PASS"
}

engine_compute_readiness() {
  local f="${MM_STATUS_FILE}"
  local keys=(
    CONFIGURATION_READY
    R2_OS_CORE_DOWNLOADED
    R2_OS_CORE_CHECKSUM
    OS_MIRROR_READY
    ACPS_CONNECTION
    ACPS_PHASE2_DOWNLOADED
    ACPS_CHECKSUM
    UPSTREAM_BRINGUP_DRIFT
    PATCHED_BRINGUP_APPLIED
    PHASE2_BUNDLE_ENTRY_COUNT
    PHASE2_BUNDLE_CHECKSUM
    CLIENT_FILES_READY
    HTTP_CONFIGURATION_READY
  )
  local k v all=PASS
  for k in "${keys[@]}"; do
    v="$(mm_status_get "$k")"
    case "$k" in
      UPSTREAM_BRINGUP_DRIFT)
        [[ "$v" == "NO" ]] || all=FAIL
        ;;
      PHASE2_BUNDLE_ENTRY_COUNT)
        [[ "$v" == "9" ]] || all=FAIL
        ;;
      PATCHED_BRINGUP_APPLIED)
        [[ "$v" == "YES" || "$v" == "PASS" ]] || all=FAIL
        ;;
      *)
        [[ "$v" == "PASS" || "$v" == "YES" || "$v" == "REUSED" ]] || all=FAIL
        ;;
    esac
  done
  mm_status_set TARGET_DP_VERSION "${TARGET_DP_VERSION}"
  mm_status_set UPGRADE_READINESS "$all"
  printf 'UPGRADE_READINESS=%s\n' "$all"
  [[ "$all" == "PASS" ]]
}

engine_write_install_report() {
  local result="${1:-PASS}"
  mm_state_set INSTALL_RESULT "$result"
  mm_state_set FINISHED_AT "$(mm_ts)"
  mm_state_set FILES_CHANGED "${MM_FILES_CHANGED}"
  mm_status_set LAST_EXECUTION_RESULT "$result"
  mm_status_set LOG_PATH "${MM_LOG_FILE:-}"
  if [[ -n "${MM_STATE_DIR:-}" ]]; then
    cp -f "${MM_STATE_DIR}/state.env" "${MM_STATE_DIR}/report.env" 2>/dev/null || true
    mm_info "REPORT_PATH=${MM_STATE_DIR}/report.env"
  fi
  printf 'INSTALL_RESULT=%s\n' "$result"
  printf 'FILES_CHANGED=%s\n' "${MM_FILES_CHANGED}"
  printf 'RUN_ID=%s\n' "${MM_RUN_ID:-}"
}

engine_download_and_prepare() {
  mm_load_gui_config
  engine_resolve_paths
  mm_state_init
  mm_state_set OS_CORE_SOURCE R2
  mm_state_set DP_PHASE2_SOURCE ACPS

  if ! mm_config_ready; then
    mm_state_set CONFIGURATION_READY FAIL
    mm_die "CONFIGURATION_READY=FAIL"
  fi
  mm_state_set CONFIGURATION_READY PASS
  mm_validate_dp_version "$TARGET_DP_VERSION"
  dp2_set_version "$TARGET_DP_VERSION"

  r2_require_url
  engine_preflight_host
  mm_acquire_install_lock

  # Client HTTP artifacts must already be present (installed by bootstrap)
  mkdir -p "$MM_CLIENT_ROOT"
  if ! mm_check_client_files_ready; then
    mm_die "CLIENT_FILES_READY=FAIL"
  fi

  # R2 OS Core
  r2_download_package
  engine_verify_os_core_package "$OS_CORE_PACKAGE"

  # ACPS auth setup + disk estimate
  if [[ -z "${DP_PHASE2_SOURCE_BASE:-}" ]]; then
    ACPS_BASE_URL="$ACPS_BASE_URL_FIXED"
  fi
  acps_setup_curl_auth
  if acps_test_connection; then
    mm_state_set ACPS_CONNECTION PASS
  else
    mm_state_set ACPS_CONNECTION FAIL
    mm_die "ACPS_CONNECTION=FAIL"
  fi
  ACPS_EXPECTED_BYTES="$(acps_expected_bytes_hint "${ACPS_EFFECTIVE_BASE}")"
  ACPS_EXPECTED_BYTES="${ACPS_EXPECTED_BYTES:-0}"
  engine_verify_disk_space

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN=YES"
    engine_write_install_report PASS
    printf 'DRY_RUN=YES\nFILES_CHANGED=NO\n'
    return 0
  fi

  engine_materialize_os_mirror "$OS_CORE_PACKAGE"

  local cache work
  acps_acquire_all "$TARGET_DP_VERSION"
  cache="$(acps_cache_dir "$TARGET_DP_VERSION")"
  [[ -d "$cache" ]] || mm_die "ACPS_CACHE_MISSING"

  engine_verify_acps_upstream_bringup "$cache"

  work="${MM_CACHE_ROOT}/acps-work/${TARGET_DP_VERSION}/$(mm_run_id)"
  rm -rf "$work"
  mkdir -p "$work"
  local f
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    cp -f "${cache}/${f}" "${work}/${f}"
  done
  engine_apply_local_bringup_patch "$work"
  engine_place_dp_phase2_final "$work" "$TARGET_DP_VERSION"

  engine_cleanup_temps

  mm_state_set HTTP_DISTRIBUTION_READY NO
  mm_status_set HTTP_DISTRIBUTION DISABLED
  engine_write_install_report PASS
  mm_ok "DOWNLOAD_AND_PREPARE=PASS"
}

engine_render_nginx_site() {
  # Render nginx site for the single final selective + Phase 2 layout.
  local tpl=""
  local base="${MM_MIRROR_ROOT}"
  local ver="${TARGET_DP_VERSION:-6.5.0}"
  local candidates=(
    "${MM_PROJECT_ROOT}/templates/nginx.conf"
    "${MM_PROJECT_ROOT}/../templates/nginx.conf"
    /usr/local/lib/ubuntu-mirror/templates/nginx.conf
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      tpl="$c"
      break
    fi
  done
  [[ -n "$tpl" ]] || mm_die "NGINX_TEMPLATE=FAIL"
  sed \
    -e "s|/var/spool/apt-mirror/selective|${base}/selective|g" \
    -e "s|/var/spool/apt-mirror/client|${base}/client|g" \
    -e "s|/var/spool/apt-mirror/dp-phase2/6.5.0|${base}/dp-phase2/${ver}|g" \
    -e "s|/var/spool/apt-mirror/dp-phase2|${base}/dp-phase2|g" \
    -e "s|/dp-phase2/6.5.0/|/dp-phase2/${ver}/|g" \
    -e "s|location = /dp-phase2/6.5.0|location = /dp-phase2/${ver}|g" \
    "$tpl"
}

engine_nginx_bin() { printf '%s\n' "${MM_NGINX_BIN:-nginx}"; }
engine_systemctl_bin() { printf '%s\n' "${MM_SYSTEMCTL_BIN:-systemctl}"; }

engine_enable_http_distribution() {
  # Real nginx enable: layout check → site install → nginx -t → enable/reload → HTTP smoke.
  # On any failure: restore previous site config and do NOT set HTTP_DISTRIBUTION=ENABLED.
  mm_load_gui_config
  engine_resolve_paths
  dp2_set_version "$TARGET_DP_VERSION"

  if ! mm_check_client_files_ready; then
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "HTTP_DISTRIBUTION=FAIL CLIENT_FILES_READY"
  fi

  # Layout validation without requiring live HTTP yet
  local prev_skip="${MM_SKIP_HTTP_VALIDATE:-0}"
  MM_SKIP_HTTP_VALIDATE=1
  if ! engine_validate_http_layout; then
    MM_SKIP_HTTP_VALIDATE="$prev_skip"
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
    mm_die "HTTP_DISTRIBUTION=FAIL layout"
  fi
  MM_SKIP_HTTP_VALIDATE="$prev_skip"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip nginx enable"
    mm_status_set HTTP_DISTRIBUTION ENABLED
    mm_state_set HTTP_DISTRIBUTION_READY YES
    mm_ok "HTTP_DISTRIBUTION=ENABLED (dry-run)"
    return 0
  fi

  # Unit-test hook: layout already validated; skip writing /etc/nginx (see bootstrap tests for full path).
  if [[ "${MM_SKIP_NGINX_APPLY:-0}" == "1" ]]; then
    mm_warn "NGINX_APPLY=SKIPPED_TEST"
    mm_status_set HTTP_DISTRIBUTION ENABLED
    mm_state_set HTTP_DISTRIBUTION_READY YES
    mm_status_set HTTP_CONFIGURATION_READY PASS
    mm_ok "HTTP_DISTRIBUTION=ENABLED"
    return 0
  fi

  local site_name="${MM_NGINX_SITE_NAME:-apt-mirror}"
  local site_avail="${MM_NGINX_SITE_AVAIL:-/etc/nginx/sites-available/${site_name}}"
  local site_en="${MM_NGINX_SITE_ENABLED:-/etc/nginx/sites-enabled/${site_name}}"
  local nginx_bin systemctl_bin ngx_tmp backup=""
  nginx_bin="$(engine_nginx_bin)"
  systemctl_bin="$(engine_systemctl_bin)"

  command -v "$nginx_bin" >/dev/null 2>&1 || mm_die "NGINX_PACKAGE=FAIL binary missing"
  command -v "$systemctl_bin" >/dev/null 2>&1 || mm_die "SYSTEMCTL=FAIL missing"

  ngx_tmp="$(mktemp)"
  engine_render_nginx_site >"$ngx_tmp"
  if grep -qE 'selective/current|published\.previous' "$ngx_tmp"; then
    rm -f "$ngx_tmp"
    mm_die "NGINX_CONFIG=FAIL generation path reference"
  fi

  mkdir -p "$(dirname "$site_avail")" "$(dirname "$site_en")"
  if [[ -f "$site_avail" ]]; then
    backup="${site_avail}.bak.mm.$(date -u +%Y%m%d%H%M%S)"
    cp -a "$site_avail" "$backup"
  fi
  install -m 0644 "$ngx_tmp" "$site_avail"
  rm -f "$ngx_tmp"
  ln -sfn "$site_avail" "$site_en"
  local default_site
  default_site="$(dirname "$site_en")/default"
  if [[ -e "$default_site" ]]; then
    rm -f "$default_site"
  fi

  local restore_nginx
  restore_nginx() {
    if [[ -n "${backup:-}" && -f "$backup" ]]; then
      cp -a "$backup" "$site_avail"
      mm_warn "NGINX_ROLLBACK=YES restored ${backup}"
    fi
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_state_set HTTP_DISTRIBUTION_READY NO
  }

  if [[ "${MM_NGINX_TEST_FAIL:-0}" == "1" ]] || ! "$nginx_bin" -t; then
    restore_nginx
    mm_die "NGINX_TEST=FAIL"
  fi
  mm_ok "NGINX_TEST=PASS"

  "$systemctl_bin" enable nginx >/dev/null 2>&1 || true
  if "$systemctl_bin" is-active --quiet nginx 2>/dev/null; then
    if ! "$systemctl_bin" reload nginx; then
      "$systemctl_bin" restart nginx || {
        restore_nginx
        mm_die "NGINX_RELOAD=FAIL"
      }
    fi
  else
    "$systemctl_bin" start nginx || {
      restore_nginx
      mm_die "NGINX_START=FAIL"
    }
  fi
  mm_ok "NGINX_ENABLE=PASS"

  # Concrete artifact HTTP smoke (root URL / is not a failure criterion)
  if [[ "${MM_SKIP_HTTP_VALIDATE:-0}" != "1" ]]; then
    if [[ "${MM_HTTP_VALIDATE_MOCK_FAIL:-0}" == "1" ]] || ! engine_validate_http_layout; then
      restore_nginx
      if command -v "$systemctl_bin" >/dev/null 2>&1; then
        "$systemctl_bin" reload nginx 2>/dev/null \
          || "$systemctl_bin" restart nginx 2>/dev/null \
          || true
      fi
      mm_die "HTTP_SMOKE=FAIL"
    fi
  else
    mm_state_set HTTP_CONFIGURATION_READY PASS
    mm_warn "HTTP_VALIDATION=SKIPPED_NETWORK"
  fi

  mm_status_set HTTP_DISTRIBUTION ENABLED
  mm_state_set HTTP_DISTRIBUTION_READY YES
  mm_status_set HTTP_CONFIGURATION_READY PASS
  mm_ok "HTTP_DISTRIBUTION=ENABLED"
}
