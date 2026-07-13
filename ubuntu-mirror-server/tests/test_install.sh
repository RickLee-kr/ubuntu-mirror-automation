#!/usr/bin/env bash
# test_install.sh — Dry-run / unit tests for installer pieces
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/config.sh
source "${ROOT}/lib/config.sh"

FAIL=0

assert_contains() {
  local hay="$1" needle="$2" msg="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo "  PASS: $msg"
  else
    echo "  FAIL: $msg (missing '$needle')"
    FAIL=1
  fi
}

echo "[test] load config + generate mirror.list"
um_load_config "${ROOT}/mirror.conf"
list="$(um_generate_mirror_list)"
assert_contains "$list" "set base_path    /var/spool/apt-mirror" "base_path set"
assert_contains "$list" "xenial" "includes xenial"
assert_contains "$list" "bionic" "includes bionic"
assert_contains "$list" "focal" "includes focal"
assert_contains "$list" "jammy" "includes jammy"
assert_contains "$list" "noble" "includes noble"
assert_contains "$list" "set nthreads     20" "nthreads 20"
assert_contains "$list" "universe multiverse" "full mode components"

echo "[test] minimal mode"
MIN_CONF="$(mktemp)"
sed 's/^MIRROR_MODE=.*/MIRROR_MODE="minimal"/' "${ROOT}/mirror.conf" >"$MIN_CONF"
um_load_config "$MIN_CONF"
list_min="$(um_generate_mirror_list)"
rm -f "$MIN_CONF"
if [[ "$list_min" == *"universe"* ]]; then
  echo "  FAIL: minimal should not include universe"
  FAIL=1
else
  echo "  PASS: minimal excludes universe"
fi
# restore default config for subsequent tests
um_load_config "${ROOT}/mirror.conf"

echo "[test] nginx + systemd generators"
# reload defaults
um_load_config "${ROOT}/mirror.conf"
ngx="$(um_generate_nginx_conf)"
assert_contains "$ngx" "location /ubuntu" "nginx /ubuntu location"
assert_contains "$ngx" "alias ${UBUNTU_MIRROR_ROOT}" "nginx alias path"
svc="$(um_generate_systemd_service)"
assert_contains "$svc" "run-apt-mirror.sh" "service ExecStart wrapper"
tim="$(um_generate_systemd_timer)"
assert_contains "$tim" "OnCalendar=" "timer OnCalendar"

echo "[test] install.sh --help / dry-run parse"
bash -n "${ROOT}/install.sh"
bash "${ROOT}/install.sh" --help >/dev/null
# dry-run without root should work
OUT="$(bash "${ROOT}/install.sh" --dry-run 2>&1 || true)"
assert_contains "$OUT" "[DRY-RUN]" "dry-run emits DRY-RUN markers"

echo "[test] uninstall.sh --help"
bash "${ROOT}/uninstall.sh" --help >/dev/null

exit "$FAIL"
