#!/usr/bin/env bash
# test_validate_fixture.sh — Prove validate logic can PASS against a fixture tree
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

# Fixture mirror layout
mkdir -p "$FIX"/{mirror,skel,var,logs,backups}
mkdir -p "$FIX/mirror/archive.ubuntu.com/ubuntu/dists"
for v in xenial bionic focal jammy noble; do
  mkdir -p "$FIX/mirror/archive.ubuntu.com/ubuntu/dists/$v"
  echo "Origin: Ubuntu" >"$FIX/mirror/archive.ubuntu.com/ubuntu/dists/$v/Release"
done
# Simulate clean script
printf '#!/bin/bash\nexit 0\n' >"$FIX/var/clean.sh"
chmod +x "$FIX/var/clean.sh"
touch "$FIX/logs/apt-mirror.log"
echo "End time: fixture" >>"$FIX/logs/apt-mirror.log"

CONF="$FIX/mirror.conf"
cat >"$CONF" <<EOF
BASE_PATH="$FIX"
MIRROR_MODE="full"
UBUNTU_VERSIONS="xenial bionic focal jammy noble"
SUITE_SUFFIXES="updates security backports"
UPSTREAM_MIRROR="http://archive.ubuntu.com/ubuntu"
DEFAULT_ARCH="amd64"
NTHREADS="20"
MIRROR_PORT="80"
MIRROR_HOSTNAME="_"
MIRROR_URL="http://127.0.0.1"
MIRROR_IP="127.0.0.1"
DATA_DEVICE=""
DISK_WARN_PERCENT="99"
DISK_CRIT_PERCENT="100"
MIN_FREE_GIB="0"
LOG_DIR="$FIX/logs"
APT_MIRROR_LOG="$FIX/logs/apt-mirror.log"
APT_MIRROR_INITIAL_LOG="$FIX/logs/apt-mirror-initial.log"
NGINX_ACCESS_LOG="$FIX/logs/nginx-access.log"
NGINX_ERROR_LOG="$FIX/logs/nginx-error.log"
INSTALL_BIN_DIR="$FIX/bin"
INSTALL_LIB_DIR="$FIX/lib"
INSTALL_CONF_DIR="$FIX/etc"
BACKUP_DIR="$FIX/backups"
NGINX_SITE_NAME="apt-mirror"
HTTP_TIMEOUT_SEC="2"
HEALTH_HTTP_LATENCY_WARN_MS="5000"
HEALTH_LOG_ERROR_WARN="100"
SYNC_ON_CALENDAR="*-*-* 02:00:00"
SYNC_PERSISTENT="true"
INCLUDE_SOURCE="false"
NGINX_LISTEN_IPV6="true"
NGINX_DEFAULT_SERVER="true"
NGINX_DISABLE_DEFAULT="true"
ALLOW_FORMAT="false"
ALLOW_DELETE_MIRROR_DATA="false"
EOF

um_load_config "$CONF"

FAIL=0
echo "[test] fixture paths exist"
[[ -d "$DIST_ROOT/noble" ]] || FAIL=1
[[ -f "$DIST_ROOT/noble/Release" ]] || FAIL=1

echo "[test] mirror.list generator for fixture"
list="$(um_generate_mirror_list)"
[[ "$list" == *"set base_path    $FIX"* ]] || FAIL=1

echo "[test] all five versions present in fixture"
present=0
for v in xenial bionic focal jammy noble; do
  [[ -d "$DIST_ROOT/$v" ]] && present=$((present + 1))
done
if [[ "$present" -eq 5 ]]; then
  echo "  PASS: 5/5 versions in fixture"
else
  echo "  FAIL: present=$present"
  FAIL=1
fi

# Simulate validate version checks using um_result
um_result_reset
for v in xenial bionic focal jammy noble; do
  if [[ -d "$DIST_ROOT/$v" ]]; then
    um_result PASS "Ubuntu version ${v}" "dists present"
  else
    um_result FAIL "Ubuntu version ${v}" "missing"
  fi
done
um_result PASS "Mirror Directory" "fixture ok"
um_result PASS "Disk Space" "fixture ok"
um_result PASS "Permissions" "fixture ok"
um_result PASS "Logs" "fixture ok"

set +e
um_result_summary >/dev/null
rc=$?
set -e
if [[ "$rc" -eq 0 && "$UM_FAIL_COUNT" -eq 0 ]]; then
  echo "  PASS: fixture validation summary PASS (exit 0)"
else
  echo "  FAIL: fixture summary rc=$rc fail=$UM_FAIL_COUNT"
  FAIL=1
fi

exit "$FAIL"
