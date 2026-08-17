#!/usr/bin/env bash
# Build the separate Phase 2 Ubuntu prerequisite artifact from ACPS py3-apt
# package metadata + the selective Noble package index.
# Never modifies original ACPS files. Never rewrites ACPS SHA sidecars.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/dp-phase2-common.sh
source "${SCRIPT_DIR}/lib/dp-phase2-common.sh"

PHASE2_PREREQ_PY="${SCRIPT_DIR}/lib/phase2_ubuntu_prerequisites.py"
DP_PHASE2_VERSION="${DP_PHASE2_VERSION:-${DP_PHASE2_VERSION_DEFAULT}}"
DP_PHASE2_ROOT="${DP_PHASE2_ROOT:-/var/spool/apt-mirror/dp-phase2}"
MM_SELECTIVE_ROOT="${MM_SELECTIVE_ROOT:-/var/spool/apt-mirror/selective}"

dp2_phase2_prereq_artifact_name() {
  printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz"
}

dp2_phase2_prereq_published_dir() {
  # Always version-root/extras so DP stage URL /dp-phase2/<ver>/extras/ matches
  # the production nginx alias (flat final dir, no current/ generation layout).
  printf '%s/extras\n' "$(dp2_version_root)"
}

dp2_find_acps_common() {
  local explicit="${PHASE2_PREREQ_ACPS_COMMON:-}"
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  local ver_root current
  ver_root="$(dp2_version_root)"
  for current in \
    "${ver_root}/current/files/aelladeb_py3_common.tar.gz" \
    "${ver_root}/files/aelladeb_py3_common.tar.gz" \
    "${ver_root}/aelladeb_py3_common.tar.gz" \
    "${ver_root}/current/aelladeb_py3_common.tar.gz"
  do
    if [[ -f "$current" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
  done
  if [[ -n "${PHASE2_PREREQ_WORK_DIR:-}" && -f "${PHASE2_PREREQ_WORK_DIR}/aelladeb_py3_common.tar.gz" ]]; then
    printf '%s\n' "${PHASE2_PREREQ_WORK_DIR}/aelladeb_py3_common.tar.gz"
    return 0
  fi
  return 1
}

dp2_find_noble_ubuntu_root() {
  if [[ -n "${PHASE2_PREREQ_INDEX_ROOT:-}" && -d "${PHASE2_PREREQ_INDEX_ROOT}" ]]; then
    printf '%s\n' "${PHASE2_PREREQ_INDEX_ROOT}"
    return 0
  fi
  local hop
  for hop in \
    "${MM_SELECTIVE_ROOT}/hops/jammy-to-noble/ubuntu" \
    "${MM_SELECTIVE_ROOT}/published/hops/jammy-to-noble/ubuntu" \
    "${MM_SELECTIVE_ROOT}/current/hops/jammy-to-noble/ubuntu"
  do
    if [[ -d "${hop}/dists" ]]; then
      printf '%s\n' "$hop"
      return 0
    fi
  done
  local discovery
  discovery="${PROJECT_ROOT}/artifacts/upgrade-discovery/analysis/pocket-indexes/ubuntu"
  if [[ -d "${discovery}/dists" ]]; then
    printf '%s\n' "$discovery"
    return 0
  fi
  return 1
}

dp2_find_extra_acps_debs() {
  # Read-only extra roots: published Aella/UVP debs beside ACPS common.
  # Never modify or repack these files.
  local common="${1:-}"
  local ver_root
  ver_root="$(dp2_version_root)"
  local dirs=()
  if [[ -n "$common" ]]; then
    dirs+=("$(dirname "$common")")
  fi
  dirs+=(
    "${ver_root}/current/files"
    "${ver_root}/files"
    "${ver_root}"
  )
  local d f
  local seen=""
  for d in "${dirs[@]}"; do
    [[ -n "$d" && -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] || continue
      case " $seen " in
        *" $f "*) continue ;;
      esac
      seen="${seen} ${f}"
      printf '%s\n' "$f"
    done < <(find "$d" -maxdepth 1 -type f \( \
      -name 'aella-uvp-*.deb' -o -name 'aella-da-*.deb' \
    \) 2>/dev/null | sort)
  done
}

dp2_extract_py3_apt_from_common() {
  local common="$1"
  local dest="$2"
  mkdir -p "$dest"
  # Extract only the inner py3-apt tarball; never rewrite the common archive.
  if tar -tzf "$common" 2>/dev/null | grep -q 'py3-apt-packages.tar.gz$'; then
    local member
    member="$(tar -tzf "$common" | grep 'py3-apt-packages.tar.gz$' | head -1)"
    tar -xzf "$common" -C "$dest" "$member"
    # Flatten if nested.
    if [[ ! -f "${dest}/py3-apt-packages.tar.gz" ]]; then
      local found
      found="$(find "$dest" -name 'py3-apt-packages.tar.gz' -type f | head -1 || true)"
      if [[ -n "$found" ]]; then
        cp -a "$found" "${dest}/py3-apt-packages.tar.gz"
      fi
    fi
  fi
  [[ -f "${dest}/py3-apt-packages.tar.gz" ]]
}

prepare_phase2_ubuntu_prerequisites() {
  local common ubuntu_root extras work rc=0

  extras="${PHASE2_PREREQ_OUT_DIR:-$(dp2_phase2_prereq_published_dir)}"
  mkdir -p "$extras"
  work="$(mktemp -d "${TMPDIR:-/tmp}/phase2-prereq.XXXXXX")"

  if ! common="$(dp2_find_acps_common)"; then
    local bundle
    bundle="$(dp2_version_root)/$(dp2_stable_bundle_name 2>/dev/null || true)"
    if [[ -f "$bundle" ]] \
      && tar -xf "$bundle" -C "$work" aelladeb_py3_common.tar.gz 2>/dev/null \
      && [[ -s "${work}/aelladeb_py3_common.tar.gz" ]]; then
      tar -xf "$bundle" -C "$work" \
        "aella-uvp-2404_${DP_PHASE2_VERSION}ubuntu1_amd64.deb" 2>/dev/null || true
      common="${work}/aelladeb_py3_common.tar.gz"
      dp2_info "PHASE2_PREREQ_ACPS_COMMON_FROM_BUNDLE=${bundle}"
    else
      rm -rf "$work"
      dp2_error "PHASE2_PREREQ=FAIL reason=acps_common_missing"
      return 1
    fi
  fi
  dp2_info "PHASE2_PREREQ_ACPS_COMMON=${common}"
  dp2_info "PHASE2_PREREQ_ACPS_SHA1=$(sha1sum "$common" | awk '{print $1}')"

  if ! ubuntu_root="$(dp2_find_noble_ubuntu_root)"; then
    rm -rf "$work"
    dp2_error "PHASE2_PREREQ=FAIL reason=noble_index_missing"
    return 1
  fi
  dp2_info "PHASE2_PREREQ_UBUNTU_ROOT=${ubuntu_root}"

  if ! dp2_extract_py3_apt_from_common "$common" "$work"; then
    rm -rf "$work"
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_missing"
    return 1
  fi

  local extra_deb extra_args=()
  while IFS= read -r extra_deb; do
    [[ -n "$extra_deb" ]] || continue
    extra_args+=(--extra-deb "$extra_deb")
    dp2_info "PHASE2_PREREQ_EXTRA_ROOT_DEB=${extra_deb}"
  done < <(dp2_find_extra_acps_debs "$common")

  local archive_base security_base
  archive_base="${PHASE2_PREREQ_ARCHIVE_BASE:-http://archive.ubuntu.com/ubuntu}"
  security_base="${PHASE2_PREREQ_SECURITY_BASE:-http://security.ubuntu.com/ubuntu}"
  extra_args+=(--target-version "${DP_PHASE2_VERSION}")
  extra_args+=(--archive-base "$archive_base")
  extra_args+=(--security-base "$security_base")
  if [[ -n "${PHASE2_PREREQ_AUTHORITATIVE_ROOT:-}" ]]; then
    extra_args+=(--authoritative-root "${PHASE2_PREREQ_AUTHORITATIVE_ROOT}")
  fi
  if [[ -n "${PHASE2_PREREQ_AUTHORITATIVE_CACHE:-}" ]]; then
    extra_args+=(--authoritative-cache "${PHASE2_PREREQ_AUTHORITATIVE_CACHE}")
  fi

  set +e
  python3 "$PHASE2_PREREQ_PY" build \
    --source "${work}/py3-apt-packages.tar.gz" \
    --ubuntu-root "$ubuntu_root" \
    --dest "$extras" \
    --ensure-selective \
    "${extra_args[@]}"
  rc=$?
  set -e
  rm -rf "$work"

  local state="${extras}/phase2-ubuntu-prerequisites.state"
  if [[ "$rc" -ne 0 ]]; then
    python3 "$PHASE2_PREREQ_PY" validate-state --dest "$extras" >/dev/null 2>&1 || true
    dp2_error "PHASE2_PREREQ_BUILD=FAIL rc=${rc}"
    dp2_error "PHASE2_PREREQ=FAIL rc=${rc}"
    return "$rc"
  fi
  if [[ ! -f "$state" ]]; then
    dp2_error "PHASE2_PREREQ=FAIL state_missing"
    return 1
  fi
  local fields_rc=0
  set +e
  python3 "$PHASE2_PREREQ_PY" validate-state --dest "$extras"
  fields_rc=$?
  set -e
  if [[ "$fields_rc" -ne 0 ]]; then
    dp2_error "PHASE2_PREREQ=FAIL reason=state_contract"
    return 1
  fi
  local art sha required count
  art="${extras}/$(dp2_phase2_prereq_artifact_name)"
  required="$(awk -F= '$1=="PHASE2_PREREQ_REQUIRED"{print $2; exit}' "$state")"
  count="$(awk -F= '$1=="PHASE2_PREREQ_PACKAGE_COUNT"{print $2; exit}' "$state")"
  sha=""
  if [[ -f "${art}.sha256" ]]; then
    sha="$(awk '{print $1; exit}' "${art}.sha256")"
  fi
  dp2_ok "PHASE2_PREREQ=PASS artifact=${art} sha256=${sha} required=${required} count=${count}"
  dp2_info "PHASE2_PREREQ_PUBLICATION=PASS extras=${extras}"
  # Confirm the original ACPS common file is unchanged.
  dp2_info "PHASE2_PREREQ_ACPS_UNMODIFIED=YES"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dp2_set_version "${1:-$DP_PHASE2_VERSION}"
  prepare_phase2_ubuntu_prerequisites
fi
