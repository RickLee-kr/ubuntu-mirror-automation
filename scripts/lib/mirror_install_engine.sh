#!/usr/bin/env bash
# Compatibility wrapper around the original mirror install engine.
# Overrides remove redundant full-size copies and make publication fail closed.
# shellcheck shell=bash
set +x

_ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mirror_install_engine_base.sh
source "${_ENGINE_DIR}/mirror_install_engine_base.sh"
unset _ENGINE_DIR

engine_materialize_os_mirror() {
  local package="$1"
  local staging_extract="${MM_CACHE_ROOT}/os-core-extract/$(mm_run_id)"
  local final_tmp="${MM_SELECTIVE_ROOT}.new.$$"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip materialize_os_mirror"
    return 0
  fi

  rm -rf "$staging_extract" "$final_tmp"
  python3 "${MM_PROJECT_ROOT}/scripts/lib/os_core_package.py" extract-staging \
    --package "$package" \
    --staging-dir "$staging_extract" \
    ${OS_CORE_PUBLIC_KEY:+--public-key "$OS_CORE_PUBLIC_KEY"} \
    || mm_die "OS_CORE_EXTRACT=FAIL"

  local payload="${staging_extract}/ubuntu-os-core/payload"
  [[ -d "$payload" ]] || mm_die "OS_CORE_PAYLOAD_MISSING"
  local hop
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    [[ -d "${payload}/hops/${hop}" ]] || mm_die "OS_MIRROR_READY=FAIL hop=${hop}"
  done

  mkdir -p "$(dirname "$final_tmp")"
  local src_dev dst_dev
  src_dev="$(stat -c %d "$payload")"
  dst_dev="$(stat -c %d "$(dirname "$final_tmp")")"
  if [[ "$src_dev" == "$dst_dev" ]]; then
    mv -f "$payload" "$final_tmp" || mm_die "OS_MIRROR_STAGE_MOVE=FAIL"
  else
    mkdir -p "$final_tmp"
    cp -a "$payload"/. "$final_tmp"/ || mm_die "OS_MIRROR_STAGE_COPY=FAIL"
  fi

  if [[ ! -e "${final_tmp}/ubuntu" ]]; then
    ln -sfn hops/jammy-to-noble/ubuntu "${final_tmp}/ubuntu"
  fi

  local keys_backup=""
  if [[ -d "${MM_SELECTIVE_ROOT}/keys" ]]; then
    keys_backup="${MM_CACHE_ROOT}/keys-backup.$$"
    rm -rf "$keys_backup"
    cp -a "${MM_SELECTIVE_ROOT}/keys" "$keys_backup" || mm_die "OS_KEYS_BACKUP=FAIL"
  fi

  local old="${MM_SELECTIVE_ROOT}.old.$$"
  rm -rf "$old"
  if [[ -d "$MM_SELECTIVE_ROOT" ]]; then
    mv -f "$MM_SELECTIVE_ROOT" "$old" || mm_die "OS_MIRROR_OLD_MOVE=FAIL"
  fi
  if ! mv -f "$final_tmp" "$MM_SELECTIVE_ROOT"; then
    [[ -e "$old" && ! -e "$MM_SELECTIVE_ROOT" ]] && mv -f "$old" "$MM_SELECTIVE_ROOT" 2>/dev/null || true
    mm_die "OS_MIRROR_PUBLISH_MOVE=FAIL"
  fi
  if [[ -n "$keys_backup" && -d "$keys_backup" ]]; then
    rm -rf "${MM_SELECTIVE_ROOT}/keys"
    mv -f "$keys_backup" "${MM_SELECTIVE_ROOT}/keys" || mm_die "OS_KEYS_RESTORE=FAIL"
  fi
  rm -rf "$old" "$staging_extract"

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

engine_apply_local_bringup_patch() {
  local files_dir="$1"
  local patched="${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
  [[ -f "$patched" ]] || mm_die "LOCAL_PATCHED_BRINGUP_MISSING"
  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip apply_local_bringup_patch"
    return 0
  fi
  cp -f "$patched" "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" \
    || mm_die "PATCHED_BRINGUP_COPY=FAIL"
  sha1sum "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${files_dir}/bringup_py3_dp_after_os_upgrade.sh.sha1" \
    || mm_die "PATCHED_BRINGUP_SHA1_WRITE=FAIL"
  BRINGUP_PATCHED_SHA1="$(sha1sum "${files_dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  local want
  want="$(sha1sum "$patched" | awk '{print $1}')"
  [[ "${BRINGUP_PATCHED_SHA1,,}" == "${want,,}" ]] || mm_die "PATCHED_BRINGUP_SHA1=FAIL"
  mm_state_set PATCHED_BRINGUP_APPLIED YES
  mm_ok "PATCHED_BRINGUP_APPLIED=YES sha1=${BRINGUP_PATCHED_SHA1}"
}

engine_place_dp_phase2_final() {
  local files_src="$1"
  local ver="$2"
  dp2_set_version "$ver"
  DP_PHASE2_ROOT="$MM_DP_PHASE2_ROOT"

  if [[ "${MM_DRY_RUN}" == "1" ]]; then
    mm_info "DRY_RUN skip place_dp_phase2_final"
    return 0
  fi

  local dest="${MM_DP_PHASE2_ROOT}/${ver}"
  local dest_tmp="${dest}.new.$$"
  local dest_old="${dest}.old.$$"
  local list_count stable actual want
  rm -rf "$dest_tmp" "$dest_old"
  mkdir -p "$dest_tmp" || mm_die "DP_PHASE2_STAGE_CREATE=FAIL"

  dp2_assert_exact_files_dir "$files_src"
  dp2_verify_payload_checksums "$files_src"
  list_count="$(dp2_check_image_list "${files_src}/images-${ver}.list" | tail -n1)"
  stable="$(dp2_stable_bundle_name)"

  (
    cd "$files_src" || exit 1
    tar -cf "${dest_tmp}/${stable}" "${DP_PHASE2_REQUIRED_FILES[@]}"
  ) || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_BUNDLE_BUILD=FAIL"; }
  dp2_assert_safe_tar_list "${dest_tmp}/${stable}" \
    || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_BUNDLE_TAR=FAIL"; }
  sha256sum "${dest_tmp}/${stable}" | awk '{print $1"  '"${stable}"'"}' \
    >"${dest_tmp}/${stable}.sha256" \
    || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_BUNDLE_SHA256_WRITE=FAIL"; }
  dp2_verify_sha256_pair "${dest_tmp}/${stable}" "${dest_tmp}/${stable}.sha256" \
    || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_BUNDLE_SHA256=FAIL"; }

  local created_at commit
  created_at="$(mm_ts)"
  commit="$(git -C "${MM_PROJECT_ROOT}" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
  cat >"${dest_tmp}/release.env" <<EOF
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
  if dp2_release_has_secret "${dest_tmp}/release.env"; then
    rm -rf "$dest_tmp"
    mm_die "RELEASE_ENV_SECRET=FAIL"
  fi

  actual="$(sha1sum "${files_src}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  want="$(sha1sum "${MM_PROJECT_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
  if [[ "${actual,,}" != "${want,,}" ]]; then
    rm -rf "$dest_tmp"
    mm_die "VALIDATE_DP=FAIL patched_bringup_sha1"
  fi

  mkdir -p "$(dirname "$dest")" || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_DEST_PARENT=FAIL"; }
  if [[ -e "$dest" ]]; then
    mv -f "$dest" "$dest_old" || { rm -rf "$dest_tmp"; mm_die "DP_PHASE2_OLD_MOVE=FAIL"; }
  fi
  if ! mv -f "$dest_tmp" "$dest"; then
    [[ -e "$dest_old" && ! -e "$dest" ]] && mv -f "$dest_old" "$dest" 2>/dev/null || true
    mm_die "DP_PHASE2_PUBLISH_MOVE=FAIL"
  fi

  if ! dp2_verify_sha256_pair "${dest}/${stable}" "${dest}/${stable}.sha256"; then
    rm -rf "$dest"
    [[ -e "$dest_old" ]] && mv -f "$dest_old" "$dest" 2>/dev/null || true
    mm_die "DP_PHASE2_PUBLISHED_SHA256=FAIL"
  fi
  if ! dp2_assert_safe_tar_list "${dest}/${stable}"; then
    rm -rf "$dest"
    [[ -e "$dest_old" ]] && mv -f "$dest_old" "$dest" 2>/dev/null || true
    mm_die "DP_PHASE2_PUBLISHED_TAR=FAIL"
  fi
  rm -rf "$dest_old"

  rm -rf "${dest}/releases" "${dest}/current" "${dest}/previous" \
    "${dest}/.staging" "${dest}/files" 2>/dev/null || true

  PHASE2_BUNDLE_ENTRY_COUNT="${DP_PHASE2_FILE_COUNT}"
  mm_state_set PHASE2_BUNDLE_ENTRY_COUNT "$PHASE2_BUNDLE_ENTRY_COUNT"
  mm_state_set PHASE2_BUNDLE_CHECKSUM PASS
  mm_mark_changed
  mm_ok "DP_PHASE2_FINAL=PASS path=${dest} bundle=${stable}"
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
  mkdir -p "$MM_CLIENT_ROOT"
  mm_check_client_files_ready || mm_die "CLIENT_FILES_READY=FAIL"

  r2_download_package
  engine_verify_os_core_package "$OS_CORE_PACKAGE"

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

  local cache work f
  acps_acquire_all "$TARGET_DP_VERSION"
  cache="$(acps_cache_dir "$TARGET_DP_VERSION")"
  [[ -d "$cache" ]] || mm_die "ACPS_CACHE_MISSING"
  engine_verify_acps_upstream_bringup "$cache"

  work="${MM_CACHE_ROOT}/acps-work/${TARGET_DP_VERSION}/$(mm_run_id)"
  rm -rf "$work"
  mkdir -p "$work"
  for f in "${DP_PHASE2_REQUIRED_FILES[@]}"; do
    case "$f" in
      bringup_py3_dp_after_os_upgrade.sh|bringup_py3_dp_after_os_upgrade.sh.sha1)
        continue
        ;;
    esac
    if ! ln "${cache}/${f}" "${work}/${f}" 2>/dev/null; then
      cp -f "${cache}/${f}" "${work}/${f}" \
        || mm_die "ACPS_WORK_STAGE=FAIL file=${f}"
    fi
  done
  engine_apply_local_bringup_patch "$work"
  dp2_assert_exact_files_dir "$work"
  dp2_verify_payload_checksums "$work"
  engine_place_dp_phase2_final "$work" "$TARGET_DP_VERSION"

  engine_cleanup_temps
  mm_state_set HTTP_DISTRIBUTION_READY NO
  mm_status_set HTTP_DISTRIBUTION DISABLED
  engine_write_install_report PASS
  mm_ok "DOWNLOAD_AND_PREPARE=PASS"
}
