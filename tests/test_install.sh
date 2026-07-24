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
assert_contains "$list" "main restricted universe multiverse" "selective components"
assert_contains "$list" "xenial-backports" "includes backports"
if printf '%s\n' "$list" | grep -Eiq '^[[:space:]]*deb-src|[[:space:]]i386[[:space:]]'; then
  echo "  FAIL: default mode must not include i386/deb-src directives"
  FAIL=1
else
  echo "  PASS: default excludes i386/deb-src directives"
fi
[[ "$MIRROR_MODE" == "selective" ]] && echo "  PASS: MIRROR_MODE=selective" || { echo "  FAIL: mode=$MIRROR_MODE"; FAIL=1; }

echo "[test] minimal mode via resolve is rejected"
set +e
( um_resolve_mirror_mode 0 1 ) >/tmp/um-min-resolve.out 2>&1
min_rc=$?
set -e
if [[ "$min_rc" -ne 0 ]]; then
  echo "  PASS: --minimal resolve rejected (rc=$min_rc)"
else
  echo "  FAIL: --minimal resolve should die"
  FAIL=1
fi
grep -q 'UNSUPPORTED_MINIMAL_PROFILE' /tmp/um-min-resolve.out \
  && echo "  PASS: UNSUPPORTED_MINIMAL_PROFILE message" \
  || { echo "  FAIL: missing UNSUPPORTED_MINIMAL_PROFILE"; FAIL=1; }
um_load_config "${ROOT}/mirror.conf"

echo "[test] full mode via config"
FULL_CONF="$(mktemp)"
sed 's/^MIRROR_MODE=.*/MIRROR_MODE="full"/' "${ROOT}/mirror.conf" >"$FULL_CONF"
um_load_config "$FULL_CONF"
list_full="$(um_generate_mirror_list)"
rm -f "$FULL_CONF"
assert_contains "$list_full" "universe multiverse" "full mode components"
# restore default config for subsequent tests
um_load_config "${ROOT}/mirror.conf"

echo "[test] projected sizes and capacity helpers"
proj_min="$(um_projected_mirror_gib minimal)"
proj_full="$(um_projected_mirror_gib full)"
[[ "$proj_min" -lt "$proj_full" ]] && echo "  PASS: minimal projected < full ($proj_min < $proj_full)" || { echo "  FAIL: projections"; FAIL=1; }
[[ "${DISK_RESERVE_PERCENT}" -ge 10 ]] && echo "  PASS: reserve >= 10% (${DISK_RESERVE_PERCENT})" || { echo "  FAIL: reserve"; FAIL=1; }

echo "[test] capacity check blocks when projection exceeds usable space"
CAP_DIR="$(mktemp -d)"
# Force an impossible projection against this filesystem
old_proj="$PROJECTED_SIZE_GIB_MINIMAL"
PROJECTED_SIZE_GIB_MINIMAL=999999
BASE_PATH="$CAP_DIR"
set +e
um_check_sync_capacity "$CAP_DIR" minimal >/tmp/um-cap.out 2>&1
cap_rc=$?
set -e
PROJECTED_SIZE_GIB_MINIMAL="$old_proj"
if [[ "$cap_rc" -ne 0 ]]; then
  echo "  PASS: capacity check blocks oversized projection"
else
  echo "  FAIL: capacity check should have blocked"
  FAIL=1
  cat /tmp/um-cap.out || true
fi
rm -rf "$CAP_DIR"

echo "[test] resolve mode defaults to selective; full/minimal rejected"
um_load_config "${ROOT}/mirror.conf"
um_resolve_mirror_mode 0 0
[[ "$MIRROR_MODE" == "selective" ]] && echo "  PASS: config selective kept" || { echo "  FAIL: $MIRROR_MODE"; FAIL=1; }
set +e
( MIRROR_MODE=full; um_resolve_mirror_mode 0 0 ) >/tmp/um-full-resolve.out 2>&1
full_rc=$?
( um_resolve_mirror_mode 1 0 ) >/tmp/um-full-flag.out 2>&1
full_flag_rc=$?
( um_resolve_mirror_mode 0 1 ) >/tmp/um-min2.out 2>&1
min2_rc=$?
set -e
[[ "$full_rc" -ne 0 ]] && echo "  PASS: MIRROR_MODE=full rejected" || { echo "  FAIL: full still accepted"; FAIL=1; }
[[ "$full_flag_rc" -ne 0 ]] && echo "  PASS: --full → rejected" || { echo "  FAIL: --full accepted"; FAIL=1; }
[[ "$min2_rc" -ne 0 ]] && echo "  PASS: --minimal → rejected" || { echo "  FAIL: minimal still accepted"; FAIL=1; }
um_load_config "${ROOT}/mirror.conf"

echo "[test] nginx + systemd generators"
# reload defaults
um_load_config "${ROOT}/mirror.conf"
ngx="$(um_generate_nginx_conf)"
assert_contains "$ngx" "location /ubuntu/" "nginx /ubuntu/ location"
assert_contains "$ngx" "location /offline/" "nginx /offline/ location"
assert_contains "$ngx" "selective/current" "nginx selective canonical root"
assert_contains "$ngx" "location /hops/" "nginx /hops/ location"
svc="$(um_generate_systemd_service)"
assert_contains "$svc" "materialize-selective" "service ExecStart materialize-selective"
tim="$(um_generate_systemd_timer)"
assert_contains "$tim" "OnCalendar=" "timer OnCalendar"
assert_contains "$tim" "RandomizedDelaySec=" "timer RandomizedDelaySec"

ml="$(um_generate_mirror_list)"
assert_contains "$ml" "set defaultarch  amd64" "mirror.list defaultarch"
assert_contains "$ml" "noble-backports" "mirror.list backports"
if printf '%s\n' "$ml" | grep -Eiq '^[[:space:]]*deb-src|[[:space:]]i386[[:space:]]'; then
  echo "  FAIL: mirror.list has i386/deb-src"; FAIL=1
else
  echo "  PASS: mirror.list no i386/deb-src directives"
fi

echo "[test] install.sh --help / dry-run parse"
bash -n "${ROOT}/install.sh"
bash "${ROOT}/install.sh" --help >/dev/null
# dry-run without root should work
OUT="$(bash "${ROOT}/install.sh" --dry-run 2>&1 || true)"
assert_contains "$OUT" "[DRY-RUN]" "dry-run emits DRY-RUN markers"

echo "[test] uninstall.sh --help"
bash "${ROOT}/uninstall.sh" --help >/dev/null

exit "$FAIL"
