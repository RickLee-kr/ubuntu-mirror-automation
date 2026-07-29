#!/usr/bin/env bash
# Synthetic durable republish helper for unit tests (not for production use).
set -euo pipefail
H7_HOP="${H7_HOP:-xenial-to-bionic}"
materialize-selective "$H7_HOP"
verify-selective "$H7_HOP"
if [[ "${PROVENANCE_MISMATCH:-0}" == "1" ]]; then
  echo "PROVENANCE_MISMATCH"
  exit 10
fi
