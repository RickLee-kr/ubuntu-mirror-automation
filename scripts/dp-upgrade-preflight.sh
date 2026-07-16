#!/usr/bin/env bash
# dp-upgrade-preflight.sh — DEPRECATED compatibility wrapper
#
# Canonical entrypoint: scripts/dp-os-upgrade-preflight.sh
# This wrapper preserves exit codes and major options while emitting a
# deprecation warning on stderr.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL="${SCRIPT_DIR}/dp-os-upgrade-preflight.sh"

if [[ ! -x "$CANONICAL" && ! -f "$CANONICAL" ]]; then
  printf 'ERROR: canonical preflight missing: %s\n' "$CANONICAL" >&2
  exit 3
fi

printf 'WARNING: dp-upgrade-preflight.sh is deprecated; use dp-os-upgrade-preflight.sh (Phase 1 OS-only). --bringup-mode is ignored for readiness.\n' >&2

exec bash "$CANONICAL" "$@"
