#!/usr/bin/env bash
# run-apt-mirror.sh — compatibility wrapper
# Preferred entrypoint is /usr/local/sbin/ubuntu-offline-mirror.sh (systemd ExecStart).
set -euo pipefail

OFFLINE_BIN="/usr/local/sbin/ubuntu-offline-mirror.sh"
if [[ -x "$OFFLINE_BIN" ]]; then
  exec "$OFFLINE_BIN" sync
fi

# Fallback: locate from source checkout / lib install
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -x "${ROOT}/scripts/ubuntu-offline-mirror.sh" ]]; then
  exec "${ROOT}/scripts/ubuntu-offline-mirror.sh" sync
fi

echo "ERROR: ubuntu-offline-mirror.sh not found" >&2
exit 1
