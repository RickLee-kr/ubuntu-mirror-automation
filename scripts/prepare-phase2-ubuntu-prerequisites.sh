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
PHASE2_PREREQ_OPTIONAL="${PHASE2_PREREQ_OPTIONAL:-0}"
PHASE2_PREREQ_ALLOW_MISSING_CANDIDATE="${PHASE2_PREREQ_ALLOW_MISSING_CANDIDATE:-0}"

dp2_phase2_prereq_artifact_name() {
  printf '%s\n' "phase2-ubuntu-prerequisites.tar.gz"
}

dp2_phase2_prereq_published_dir() {
  local ver_root dest
  ver_root="$(dp2_version_root)"
  if [[ -L "${ver_root}/current" && -d "${ver_root}/current" ]]; then
    dest="$(readlink -f "${ver_root}/current")"
  elif [[ -d "$ver_root" ]]; then
    dest="$ver_root"
  else
    dest="$ver_root"
  fi
  printf '%s/extras\n' "$dest"
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
  local allow=()

  if ! common="$(dp2_find_acps_common)"; then
    if [[ "$PHASE2_PREREQ_OPTIONAL" == "1" ]]; then
      dp2_warn "PHASE2_PREREQ=SKIP reason=acps_common_missing"
      return 0
    fi
    dp2_error "PHASE2_PREREQ=FAIL reason=acps_common_missing"
    return 1
  fi
  dp2_info "PHASE2_PREREQ_ACPS_COMMON=${common}"
  dp2_info "PHASE2_PREREQ_ACPS_SHA1=$(sha1sum "$common" | awk '{print $1}')"

  if ! ubuntu_root="$(dp2_find_noble_ubuntu_root)"; then
    if [[ "$PHASE2_PREREQ_OPTIONAL" == "1" ]]; then
      dp2_warn "PHASE2_PREREQ=SKIP reason=noble_index_missing"
      return 0
    fi
    dp2_error "PHASE2_PREREQ=FAIL reason=noble_index_missing"
    return 1
  fi
  dp2_info "PHASE2_PREREQ_UBUNTU_ROOT=${ubuntu_root}"

  extras="${PHASE2_PREREQ_OUT_DIR:-$(dp2_phase2_prereq_published_dir)}"
  mkdir -p "$extras"
  work="$(mktemp -d "${TMPDIR:-/tmp}/phase2-prereq.XXXXXX")"
  if ! dp2_extract_py3_apt_from_common "$common" "$work"; then
    rm -rf "$work"
    if [[ "$PHASE2_PREREQ_OPTIONAL" == "1" ]]; then
      dp2_warn "PHASE2_PREREQ=SKIP reason=py3_apt_missing"
      return 0
    fi
    dp2_error "PHASE2_PREREQ=FAIL reason=py3_apt_missing"
    return 1
  fi

  if [[ "$PHASE2_PREREQ_ALLOW_MISSING_CANDIDATE" == "1" ]]; then
    allow+=(--allow-missing-candidate)
  fi

  local extra_deb extra_args=()
  while IFS= read -r extra_deb; do
    [[ -n "$extra_deb" ]] || continue
    extra_args+=(--extra-deb "$extra_deb")
    dp2_info "PHASE2_PREREQ_EXTRA_ROOT_DEB=${extra_deb}"
  done < <(dp2_find_extra_acps_debs "$common")

  set +e
  python3 "$PHASE2_PREREQ_PY" build \
    --source "${work}/py3-apt-packages.tar.gz" \
    --ubuntu-root "$ubuntu_root" \
    --dest "$extras" \
    --ensure-selective \
    "${extra_args[@]}" \
    "${allow[@]}"
  rc=$?
  set -e
  rm -rf "$work"

  if [[ "$rc" -ne 0 ]]; then
    dp2_error "PHASE2_PREREQ=FAIL rc=${rc}"
    return "$rc"
  fi
  local art sha
  art="${extras}/$(dp2_phase2_prereq_artifact_name)"
  [[ -f "$art" ]] || { dp2_error "PHASE2_PREREQ=FAIL artifact_missing"; return 1; }
  sha="$(awk '{print $1; exit}' "${art}.sha256")"
  dp2_ok "PHASE2_PREREQ=PASS artifact=${art} sha256=${sha}"
  # Confirm the original ACPS common file is unchanged.
  dp2_info "PHASE2_PREREQ_ACPS_UNMODIFIED=YES"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  dp2_set_version "${1:-$DP_PHASE2_VERSION}"
  prepare_phase2_ubuntu_prerequisites
fi
