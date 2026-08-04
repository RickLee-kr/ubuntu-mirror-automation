#!/usr/bin/env bash
# Legacy name: now covers three-line command blocks (delegates).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "${ROOT}/tests/test_dp_client_command_single_lines.sh"
