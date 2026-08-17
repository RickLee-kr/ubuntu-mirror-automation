#!/usr/bin/env bash
# Tiny fixtures so Download-and-Prepare tests can exercise fail-closed
# prerequisite prepare without dummy text files being treated as ACPS.
# Zero extra packages: inner py3-apt has no .deb files.
# shellcheck shell=bash

phase2_prereq_write_zero_extra_common() {
  local dest="$1"
  local marker="${2:-}"
  local work inner
  work="$(mktemp -d "${TMPDIR:-/tmp}/phase2-prereq-common.XXXXXX")"
  inner="${work}/inner"
  mkdir -p "$inner"
  if [[ -n "$marker" ]]; then
    printf '%s\n' "$marker" >"${inner}/README.fixture"
  fi
  tar -czf "${work}/py3-apt-packages.tar.gz" -C "$inner" .
  mkdir -p "$(dirname "$dest")"
  tar -czf "$dest" -C "$work" py3-apt-packages.tar.gz
  rm -rf "$work"
}

phase2_prereq_write_empty_noble_index() {
  local root="$1"
  local suite comp
  for suite in noble noble-updates noble-security noble-backports; do
    for comp in main restricted universe multiverse; do
      mkdir -p "${root}/dists/${suite}/${comp}/binary-amd64"
      : >"${root}/dists/${suite}/${comp}/binary-amd64/Packages"
    done
  done
}

phase2_prereq_write_not_required_state() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
PHASE2_PREREQ_REQUIRED=NO
PHASE2_PREREQ_PACKAGE_COUNT=0
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
EOF
}
