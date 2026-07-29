#!/usr/bin/env bash
# Compatibility wrapper around the original Ubuntu 24.04 bootstrap helpers.
# It ensures runtime wrapper dependencies are installed beside their entry files.
# shellcheck shell=bash

_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap_base.sh
source "${_BOOTSTRAP_DIR}/bootstrap_base.sh"
unset _BOOTSTRAP_DIR

# Preserve the original helper and extend it without duplicating the full
# bootstrap implementation.
eval "$(declare -f um_bootstrap_install_file | sed '1s/um_bootstrap_install_file/um_bootstrap_install_file_base/')"

um_bootstrap_install_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  um_bootstrap_install_file_base "$src" "$dest" "$mode"

  local companion_src="" companion_dest=""
  case "$src" in
    */lib/bootstrap.sh)
      companion_src="${src%/*}/bootstrap_base.sh"
      companion_dest="${dest%/*}/bootstrap_base.sh"
      ;;
    */scripts/lib/mirror_manager_common.sh)
      companion_src="${src%/*}/mirror_manager_common_base.sh"
      companion_dest="${dest%/*}/mirror_manager_common_base.sh"
      ;;
    */scripts/lib/r2_acquire.sh)
      companion_src="${src%/*}/r2_acquire_base.sh"
      companion_dest="${dest%/*}/r2_acquire_base.sh"
      ;;
    */scripts/lib/acps_acquire.sh)
      companion_src="${src%/*}/acps_acquire_base.sh"
      companion_dest="${dest%/*}/acps_acquire_base.sh"
      ;;
    */scripts/lib/mirror_install_engine.sh)
      companion_src="${src%/*}/mirror_install_engine_base.sh"
      companion_dest="${dest%/*}/mirror_install_engine_base.sh"
      ;;
  esac

  if [[ -n "$companion_src" ]]; then
    [[ -f "$companion_src" ]] || um_die "RUNTIME_INSTALL=FAIL missing companion ${companion_src}"
    um_bootstrap_install_file_base "$companion_src" "$companion_dest" 0644
  fi
}
