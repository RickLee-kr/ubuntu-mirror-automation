#!/usr/bin/env bash
# Regression: long Bionic->Focal LXD operations must not look hung.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /tmp/lxd-heartbeat-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
LOG="${TMP}/heartbeat.log"

TEST_ROOT=""
SYSTEMCTL_BIN="systemctl"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
CRITICAL_HOLD_PACKAGES="apt dpkg libc6"
LXD_REMOVAL_ALLOWLIST="lxd lxd-client lxd-tools"
LXD_REMOVAL_TARGETS="lxd lxd-client"
EC_LXD=36
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED=false
PIN_SOURCE_VERSION=18.04
hostpath() { printf '%s' "$1"; }
log() { local level="$1"; shift; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" >>"$LOG"; }
utc_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
read_os_field() { printf '%s\n' "$PIN_SOURCE_VERSION"; }
die() { return "${1:-1}"; }
cross_release_candidate_from_policy() { printf '%s\n' ''; }

# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-offline-lxd-inventory.sh"

bash -n "${ROOT}/client/lib/dp-offline-lxd-inventory.sh"

# 1) A genuinely long operation emits BEGIN, heartbeat progress, and END while
# keeping raw child output in the evidence files.
LXD_PROGRESS_HEARTBEAT_SECS=1
: >"$LOG"
out="${TMP}/long.out"
err="${TMP}/long.err"
lxd_run_with_heartbeat LXD_TEST_LONG "$out" "$err" -- bash -c \
  'printf "child-out\n"; printf "child-err\n" >&2; sleep 2'

grep -q 'LXD_TEST_LONG_BEGIN' "$LOG"
grep -q 'LXD_TEST_LONG_PROGRESS=RUNNING elapsed_secs=' "$LOG"
grep -q 'LXD_TEST_LONG_END rc=0 elapsed_secs=' "$LOG"
grep -q '^child-out$' "$out"
grep -q '^child-err$' "$err"

# 2) Preserve the child exit status exactly.
: >"$LOG"
set +e
lxd_run_with_heartbeat LXD_TEST_FAIL "${TMP}/fail.out" "${TMP}/fail.err" -- bash -c 'exit 23'
rc=$?
set -e
[[ "$rc" -eq 23 ]]
grep -q 'LXD_TEST_FAIL_END rc=23 elapsed_secs=' "$LOG"

# 3) A short command must not be delayed by a long heartbeat interval. The
# wrapper polls completion independently from its 30-second log cadence.
LXD_PROGRESS_HEARTBEAT_SECS=30
start="$(date +%s)"
lxd_run_with_heartbeat LXD_TEST_SHORT "${TMP}/short.out" "${TMP}/short.err" -- bash -c 'sleep 0.1'
end="$(date +%s)"
[[ $((end - start)) -lt 3 ]]

# 4) Both field-observed silent apt operations use the heartbeat wrapper.
grep -q 'lxd_run_with_heartbeat LXD_REMOVAL_EXEC' "${ROOT}/client/lib/dp-offline-lxd-inventory.sh"
grep -q 'lxd_run_with_heartbeat LXD_TARGET_PLAN_SIMULATION' "${ROOT}/client/lib/dp-offline-lxd-inventory.sh"

# 5) LXD helper changes are build-provenance inputs, so Menu 2 cannot silently
# reuse a client built from an older helper implementation.
python3 "${ROOT}/scripts/lib/client_build_provenance.py" list-files \
  | grep -qx 'client/lib/dp-offline-lxd-inventory.sh'

echo "LXD_LONG_OPERATION_HEARTBEAT=PASS"
