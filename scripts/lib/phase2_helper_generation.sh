#!/usr/bin/env bash
# scripts/lib/phase2_helper_generation.sh — generation-bound Phase 2 helper unit
# shellcheck shell=bash

if [[ -n "${PHASE2_HELPER_GENERATION_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
PHASE2_HELPER_GENERATION_LOADED=1

PHASE2_HELPER_GENERATION_MANIFEST_NAME="phase2-helper-generation.manifest"

phase2_helper_generation_files() {
  printf '%s\n' \
    stage-dp-phase2.sh \
    bringup_py3_dp_lifecycle.sh \
    lib/dp-offline-source-product-version.sh \
    lib/dp-phase2-operation-progress.sh \
    lib/dp-phase2-bringup-lifecycle.sh \
    lib/dp-phase2-ubuntu-prerequisites.sh
}

phase2_helper_generation_write() {
  local root="${1:?client root required}"
  local dest="${2:-${root}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}}"
  local tmp f
  [[ -d "$root" ]] || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  (
    cd "$root" || exit 1
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      [[ -f "$f" ]] || {
        printf 'PHASE2_HELPER_GENERATION=FAIL missing=%s\n' "$f" >&2
        exit 1
      }
      sha256sum "$f"
    done < <(phase2_helper_generation_files)
  ) >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
  printf '%s\n' "$dest"
}

phase2_helper_generation_sha256() {
  local man="${1:?manifest path required}"
  [[ -f "$man" ]] || return 1
  sha256sum "$man" | awk '{print $1}'
}

phase2_helper_generation_verify() {
  local root="${1:?client root required}"
  local man="${root}/${PHASE2_HELPER_GENERATION_MANIFEST_NAME}"
  local f listed
  [[ -f "$man" ]] || {
    printf 'PHASE2_HELPER_GENERATION=FAIL reason=manifest_missing\n' >&2
    return 1
  }
  [[ -s "$man" ]] || {
    printf 'PHASE2_HELPER_GENERATION=FAIL reason=manifest_empty\n' >&2
    return 1
  }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    listed="$(awk -v p="$f" '$2 == p {print $1; exit}' "$man")"
    [[ -n "$listed" && "$listed" =~ ^[0-9a-fA-F]{64}$ ]] || {
      printf 'PHASE2_HELPER_GENERATION=FAIL reason=required_file_unlisted path=%s\n' "$f" >&2
      return 1
    }
  done < <(phase2_helper_generation_files)
  if ! (cd "$root" && sha256sum -c "$PHASE2_HELPER_GENERATION_MANIFEST_NAME" >/dev/null); then
    printf 'PHASE2_HELPER_GENERATION=FAIL reason=hash_mismatch\n' >&2
    return 1
  fi
  return 0
}
