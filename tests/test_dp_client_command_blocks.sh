#!/usr/bin/env bash
# Legacy name: multi-line blocks were replaced by single-line commands.
# Delegate to the single-line contract test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "${ROOT}/tests/test_dp_client_command_single_lines.sh"
