#!/usr/bin/env bash
# Shared helpers for repository worktree fingerprint / contamination checks.
# shellcheck shell=bash

worktree_fingerprint_tracked() {
  local root="${1:?}"
  (
    cd "$root" || exit 1
    git ls-files -z | sort -z | while IFS= read -r -d '' f; do
      if [[ -f "$f" ]]; then
        sha256sum -- "$f"
      elif [[ -L "$f" ]]; then
        printf 'SYMLINK:%s  %s\n' "$(readlink -- "$f")" "$f"
      else
        printf 'MISSING  %s\n' "$f"
      fi
    done
  )
}

worktree_fingerprint_untracked() {
  local root="${1:?}"
  (
    cd "$root" || exit 1
    git ls-files -o --exclude-standard | LC_ALL=C sort
  )
}

worktree_save_fingerprint() {
  local root="${1:?}"
  local out_dir="${2:?}"
  mkdir -p "$out_dir"
  worktree_fingerprint_tracked "$root" >"${out_dir}/tracked.sha256"
  worktree_fingerprint_untracked "$root" >"${out_dir}/untracked.list"
}

worktree_diff_fingerprint() {
  # Prints differing tracked paths / new untracked paths; returns 1 if any drift.
  local before_dir="${1:?}"
  local after_dir="${2:?}"
  local drift=0
  if ! diff -q "${before_dir}/tracked.sha256" "${after_dir}/tracked.sha256" >/dev/null 2>&1; then
    echo "TRACKED_CONTENT_DRIFT:"
    diff -u "${before_dir}/tracked.sha256" "${after_dir}/tracked.sha256" | grep -E '^[+-][^+-]' | head -200 || true
    drift=1
  fi
  if ! diff -q "${before_dir}/untracked.list" "${after_dir}/untracked.list" >/dev/null 2>&1; then
    echo "UNTRACKED_DRIFT:"
    diff -u "${before_dir}/untracked.list" "${after_dir}/untracked.list" | head -200 || true
    drift=1
  fi
  return "$drift"
}
