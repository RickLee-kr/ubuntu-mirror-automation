#!/usr/bin/env bash
# tests/test_dp_upgrade_mirror_manager.sh — unified R2+ACPS Mirror Manager synthetic tests
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
OS_CORE_PY="${ROOT}/scripts/lib/os_core_package.py"
UPSTREAM_BASELINE="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
PATCHED_BRINGUP="${ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
HTTP_PID=""
R2_PID=""
HTTP_PORT=""
R2_PORT=""
ORIG_PWD="$(pwd)"
USE_WORKDIR_VENDOR=0
SHADOW_ROOT="$ROOT"

cleanup() {
  if [[ -n "${HTTP_PID:-}" ]]; then kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; fi
  if [[ -n "${R2_PID:-}" ]]; then kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; fi
  pkill -f "${WORKDIR}" 2>/dev/null || true
  rm -rf "$WORKDIR"
  cd "$ORIG_PWD" 2>/dev/null || true
}
trap cleanup EXIT

make_selective_fixture() {
  local root="$1" hop
  for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
    mkdir -p "${root}/published/hops/${hop}/ubuntu/pool" "${root}/published/hops/${hop}/ubuntu/dists"
    printf 'pkg-%s\n' "$hop" >"${root}/published/hops/${hop}/ubuntu/pool/hello.deb"
    printf 'Release-%s\n' "$hop" >"${root}/published/hops/${hop}/ubuntu/dists/Release"
  done
  mkdir -p "${root}/published/shared/offline"
  printf 'meta\n' >"${root}/published/shared/offline/meta-release-lts"
  ln -sfn hops/jammy-to-noble/ubuntu "${root}/published/ubuntu"
}

make_upstream_bringup() {
  local dest="$1"
  local prod="/var/spool/apt-mirror/dp-phase2/6.5.0/releases/20260726T155911Z/files/bringup_py3_dp_after_os_upgrade.sh"
  if [[ -r "$prod" ]]; then cp -f "$prod" "$dest"; return 0; fi
  local build_up
  build_up="$(find "${ROOT}/.build-"* -name 'bringup_py3_dp_after_os_upgrade.sh' 2>/dev/null | head -1 || true)"
  if [[ -n "$build_up" && -r "$build_up" ]]; then
    local h want
    h="$(sha1sum "$build_up" | awk '{print $1}')"
    want="$(awk '{print $1; exit}' "$UPSTREAM_BASELINE")"
    if [[ "${h,,}" == "${want,,}" ]]; then cp -f "$build_up" "$dest"; return 0; fi
  fi
  return 1
}

ensure_upstream_bytes() {
  local dest="$1"
  if make_upstream_bringup "$dest"; then return 0; fi
  mkdir -p "${WORKDIR}/vendor/dp-phase2"
  printf 'SYNTHETIC_UPSTREAM_BRINGUP_FOR_MIRROR_MANAGER_TEST\n' \
    >"${WORKDIR}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.body"
  cp -f "${WORKDIR}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.body" "$dest"
  sha1sum "$dest" | awk '{print $1"  bringup_py3_dp_after_os_upgrade.sh"}' \
    >"${WORKDIR}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1"
  cp -f "$PATCHED_BRINGUP" "${WORKDIR}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh"
  USE_WORKDIR_VENDOR=1
}

make_acps_payload() {
  local dir="$1" ver="${2:-6.5.0}"
  mkdir -p "$dir"
  printf 'common-payload\n' >"${dir}/aelladeb_py3_common.tar.gz"
  sha1sum "${dir}/aelladeb_py3_common.tar.gz" | awk '{print $1}' >"${dir}/aelladeb_py3_common.tar.gz.sha1"
  printf 'uvp-deb\n' >"${dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb"
  sha1sum "${dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb" | awk '{print $1}' >"${dir}/aella-uvp-2404_${ver}ubuntu1_amd64.deb.sha1"
  ensure_upstream_bytes "${dir}/bringup_py3_dp_after_os_upgrade.sh"
  sha1sum "${dir}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
    >"${dir}/bringup_py3_dp_after_os_upgrade.sh.sha1"
  seq 1 156 >"${dir}/images-${ver}.list"
  printf 'images-tar-body\n' >"${dir}/images-${ver}.tar"
  sha256sum "${dir}/images-${ver}.tar" | awk '{print $1}' >"${dir}/images-${ver}.tar.sha256"
}

start_http() {
  local root="$1" auth_mode="${2:-none}"
  HTTP_PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
  python3 - "$root" "$HTTP_PORT" "$auth_mode" "${WORKDIR}/http-counts" <<'PY' &
import base64, http.server, os, sys, pathlib
root, port, auth_mode, count_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3], pathlib.Path(sys.argv[4])
count_dir.mkdir(parents=True, exist_ok=True)
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def _auth_ok(self):
        if auth_mode == 'none': return True
        if auth_mode == 'fail': return False
        hdr = self.headers.get('Authorization', '')
        if not hdr.startswith('Basic '): return False
        try:
            userpass = base64.b64decode(hdr.split(' ',1)[1]).decode()
        except Exception:
            return False
        return userpass == 'testuser:testpass'
    def do_HEAD(self):
        if not self._auth_ok():
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm=t'); self.end_headers(); return
        return super().do_HEAD()
    def do_GET(self):
        if not self._auth_ok():
            self.send_response(401); self.send_header('WWW-Authenticate','Basic realm=t'); self.end_headers(); return
        p = count_dir / 'gets'
        p.write_text(str(int(p.read_text())+1 if p.exists() else 1))
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404); return
        fs = os.stat(path); size = fs.st_size
        range_hdr = self.headers.get('Range')
        if range_hdr and range_hdr.startswith('bytes='):
            _, _, rng = range_hdr.partition('=')
            start_s, _, end_s = rng.partition('-')
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size-1
            end = min(end, size-1); length = end-start+1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length', str(length))
            self.send_header('Content-Type','application/octet-stream')
            self.end_headers()
            with open(path,'rb') as fh:
                fh.seek(start); self.wfile.write(fh.read(length))
            return
        return super().do_GET()
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  HTTP_PID=$!
  sleep 0.3
}

start_r2() {
  local root="$1"
  R2_PORT="$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)"
  python3 - "$root" "$R2_PORT" "${WORKDIR}/http-counts-r2" <<'PY' &
import http.server, os, sys, pathlib
root, port, count_dir = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3])
count_dir.mkdir(parents=True, exist_ok=True)
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=root, **k)
    def do_GET(self):
        p = count_dir / 'gets'
        p.write_text(str(int(p.read_text())+1 if p.exists() else 1))
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404); return
        fs = os.stat(path); size = fs.st_size
        range_hdr = self.headers.get('Range')
        if range_hdr and range_hdr.startswith('bytes='):
            _, _, rng = range_hdr.partition('=')
            start_s, _, end_s = rng.partition('-')
            start = int(start_s) if start_s else 0
            end = int(end_s) if end_s else size-1
            end = min(end, size-1); length = end-start+1
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Accept-Ranges','bytes')
            self.send_header('Content-Length', str(length))
            self.send_header('Content-Type','application/octet-stream')
            self.end_headers()
            with open(path,'rb') as fh:
                fh.seek(start); self.wfile.write(fh.read(length))
            return
        return super().do_GET()
    def log_message(self, *args): pass
http.server.ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
PY
  R2_PID=$!
  sleep 0.3
}

write_gui_config() {
  local path="$1"
  umask 077
  cat >"$path" <<EOF
TARGET_DP_VERSION=6.5.0
ACPS_USERNAME=testuser
ACPS_PASSWORD=testpass
EOF
  chmod 600 "$path"
}

setup_project_shadow_if_needed() {
  if [[ "${USE_WORKDIR_VENDOR:-0}" != "1" ]]; then
    SHADOW_ROOT="$ROOT"
    return 0
  fi
  SHADOW_ROOT="${WORKDIR}/shadow-project"
  mkdir -p "$SHADOW_ROOT/vendor"
  ln -sfn "${ROOT}/scripts" "${SHADOW_ROOT}/scripts"
  ln -sfn "${ROOT}/config" "${SHADOW_ROOT}/config"
  ln -sfn "${ROOT}/mirror.conf" "${SHADOW_ROOT}/mirror.conf" 2>/dev/null || true
  cp -a "${WORKDIR}/vendor/dp-phase2" "${SHADOW_ROOT}/vendor/dp-phase2"
}

common_env() {
  export MM_SKIP_ROOT_CHECK=1
  export MM_SKIP_HTTP_VALIDATE=1
  export MM_LOG_DIR="${WORKDIR}/logs"
  export MM_STATE_ROOT="${WORKDIR}/runs"
  export MM_LOCK_FILE="${WORKDIR}/install.lock"
  export MM_CACHE_ROOT="${WORKDIR}/mirror/.install-cache"
  export MM_MIRROR_ROOT="${WORKDIR}/mirror"
  export MM_SELECTIVE_ROOT="${WORKDIR}/mirror/selective"
  export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror/dp-phase2"
  export MM_CLIENT_ROOT="${WORKDIR}/mirror/client"
  export MM_CONFIG_FILE="${WORKDIR}/gui.conf"
  export MM_STATUS_FILE="${WORKDIR}/status.env"
  export DP_PHASE2_ROOT="${WORKDIR}/mirror/dp-phase2"
  export DP_PHASE2_SKIP_ROOT_CHECK=1
  export DP_PHASE2_MIN_FREE_GIB=0
  export ACPS_PROGRESS_INTERVAL_SEC=30
  export R2_PROGRESS_INTERVAL_SEC=30
  export ACPS_INSECURE_TLS=0
  mkdir -p "$MM_LOG_DIR" "$MM_STATE_ROOT" "$MM_CLIENT_ROOT"
}

run_prepare() {
  setup_project_shadow_if_needed
  MM_PROJECT_ROOT="$SHADOW_ROOT" bash "${SHADOW_ROOT}/scripts/install-dp-upgrade-mirror.sh" \
    download-and-prepare --mirror-root "${MM_MIRROR_ROOT}" "$@"
}

# ===========================================================================
echo "======== A/B/P. GUI + obsolete absence ========"
grep -q 'Configuration' "$INSTALLER" && grep -q 'Download and Prepare Upgrade Files' "$INSTALLER" \
  && grep -q 'Verify Upgrade Readiness' "$INSTALLER" && grep -q 'Enable HTTP Distribution' "$INSTALLER" \
  && grep -q 'Show Current Status' "$INSTALLER" && grep -q 'View Logs' "$INSTALLER" \
  && grep -q 'Show DP Client Upgrade Instructions' "$INSTALLER" && grep -q 'Exit' "$INSTALLER" \
  && pass "A main menu items" || fail "A main menu"
grep -qE 'Mode 1|Mode 2|Mode 3|Fully Offline|Online Bootstrap|install-standard|Roll Back' "$INSTALLER" \
  && fail "A obsolete menu text" || pass "A no obsolete menus"
grep -q 'passwordbox' "$INSTALLER" && grep -q 'Target DP Version' "$INSTALLER" \
  && pass "B configuration fields" || fail "B config"
grep -qE 'Enter R2 URL|Enter ACPS URL|R2 URL input|ACPS URL input|Set R2 URL|Set ACPS URL' "$INSTALLER" \
  && fail "B URL menus present" || pass "B no URL menus"
grep -q 'HYPERVISOR_SNAPSHOT' "$INSTALLER" && grep -q 'PROJECT_ROLLBACK_SUPPORTED=NO' "$INSTALLER" \
  && pass "O snapshot instructions" || fail "O instructions"

echo "======== C. R2 constant / CONFIGURATION_REQUIRED ========"
common_env
write_gui_config "$MM_CONFIG_FILE"
grep -q 'OS_CORE_R2_URL_CONSTANT=""' "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  && pass "C R2 constant empty placeholder" || fail "C constant"
set +e
out_c="$(env -u OS_CORE_R2_URL MM_PROJECT_ROOT="$ROOT" bash "$INSTALLER" download-and-prepare --mirror-root "${WORKDIR}/mirror-c" 2>&1)"
rc_c=$?
set -e
[[ "$rc_c" -ne 0 ]] && echo "$out_c" | grep -q 'CONFIGURATION_REQUIRED' \
  && pass "C CONFIGURATION_REQUIRED" || fail "C should require R2 URL"

echo "======== E. OS Core package verify ========"
SEL="${WORKDIR}/sel-e"; make_selective_fixture "$SEL"
OUT_E="${WORKDIR}/out-e"; mkdir -p "$OUT_E"
python3 "$OS_CORE_PY" build --selective-root "$SEL" --output-dir "$OUT_E" --project-root "$ROOT" --release-id testE001
PKG_E="$(ls "$OUT_E"/ubuntu-os-core-xenial-to-noble-testE001.tar)"
python3 "$OS_CORE_PY" verify --package "$PKG_E" && pass "E verify" || fail "E verify"
PKG_BAD="${WORKDIR}/corrupt.tar"; cp -f "$PKG_E" "$PKG_BAD"; cp -f "${PKG_E}.sha256" "${PKG_BAD}.sha256"; printf x >>"$PKG_BAD"
python3 "$OS_CORE_PY" verify --package "$PKG_BAD" 2>/dev/null && fail "E outer should fail" || pass "E outer reject"

echo "======== Prepare fixtures for install flow ========"
common_env
USE_WORKDIR_VENDOR=0
ACPS_ROOT="${WORKDIR}/acps-http"
make_acps_payload "$ACPS_ROOT" 6.5.0
setup_project_shadow_if_needed
write_gui_config "$MM_CONFIG_FILE"

R2_ROOT="${WORKDIR}/r2-http"; mkdir -p "$R2_ROOT"
cp -f "$PKG_E" "${PKG_E}.sha256" "$R2_ROOT/"
start_r2 "$R2_ROOT"
start_http "$ACPS_ROOT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"

echo "======== H/J/K/L/M. happy path prepare ========"
if run_prepare; then pass "H download-and-prepare"; else fail "H prepare"; fi

DP_DIR="${WORKDIR}/mirror/dp-phase2/6.5.0"
[[ -f "${DP_DIR}/release.env" ]] && [[ -f "${DP_DIR}/dp_bundle_6.5.0-current.tar" ]] \
  && [[ -f "${DP_DIR}/dp_bundle_6.5.0-current.tar.sha256" ]] && pass "J final bundle files" || fail "J files"
[[ ! -e "${DP_DIR}/releases" ]] && [[ ! -L "${DP_DIR}/current" ]] && [[ ! -L "${DP_DIR}/previous" ]] \
  && pass "K no generation paths" || fail "K generation present"
[[ -d "${WORKDIR}/mirror/selective/hops/xenial-to-bionic" ]] && pass "M OS selective hops" || fail "M hops"
[[ ! -L "${WORKDIR}/mirror/selective/current" ]] && [[ ! -e "${WORKDIR}/mirror/selective/published.previous" ]] \
  && pass "K selective no current/previous" || fail "K selective generation"
# shellcheck source=../scripts/lib/dp-phase2-common.sh
source "${ROOT}/scripts/lib/dp-phase2-common.sh"
dp2_set_version 6.5.0
dp2_assert_safe_tar_list "${DP_DIR}/dp_bundle_6.5.0-current.tar" && pass "J bundle contract" || fail "J tar"
WANT_PATCH="$(sha1sum "$PATCHED_BRINGUP" | awk '{print $1}')"
if [[ "${USE_WORKDIR_VENDOR}" == "1" ]]; then
  WANT_PATCH="$(sha1sum "${SHADOW_ROOT}/vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
fi
# extract bringup from bundle and check
TMPB="${WORKDIR}/bundle-check"; mkdir -p "$TMPB"
tar -C "$TMPB" -xf "${DP_DIR}/dp_bundle_6.5.0-current.tar" bringup_py3_dp_after_os_upgrade.sh
GOT="$(sha1sum "${TMPB}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}')"
[[ "${GOT,,}" == "${WANT_PATCH,,}" ]] && pass "H patched bringup" || fail "H patched got=${GOT}"

# L cleanup
compgen -G "${WORKDIR}/mirror/.install-cache/acps/6.5.0/*" >/dev/null 2>&1 \
  && fail "L acps cache remains" || pass "L acps cache cleaned"
compgen -G "${WORKDIR}/mirror/.install-cache/r2/*.tar" >/dev/null 2>&1 \
  && fail "L r2 archive remains" || pass "L r2 archive cleaned"
find "${WORKDIR}/mirror" -name '*.part' | grep -q . && fail "L .part remains" || pass "L no .part"

echo "======== N. readiness ========"
MM_PROJECT_ROOT="$SHADOW_ROOT" bash "${SHADOW_ROOT}/scripts/install-dp-upgrade-mirror.sh" enable-http >/dev/null
MM_PROJECT_ROOT="$SHADOW_ROOT" bash "${SHADOW_ROOT}/scripts/install-dp-upgrade-mirror.sh" verify-readiness \
  | grep -q 'UPGRADE_READINESS=PASS' && pass "N readiness PASS" || fail "N readiness"

echo "======== D/G R2 HTML + ACPS failures ========"
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""

# HTML R2 body
R2_HTML="${WORKDIR}/r2-html"; mkdir -p "$R2_HTML"
printf '<!DOCTYPE html><html>err</html>' >"${R2_HTML}/bad.tar"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  bad.tar\n' >"${R2_HTML}/bad.tar.sha256"
start_r2 "$R2_HTML"
start_http "$ACPS_ROOT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/bad.tar"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_LOCK_FILE="${WORKDIR}/lock-html"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-html"
export MM_CACHE_ROOT="${WORKDIR}/mirror-html/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-html/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-html/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-html/client"
mkdir -p "$MM_CLIENT_ROOT"
set +e
out_html="$(run_prepare 2>&1)"; rc_html=$?
set -e
[[ "$rc_html" -ne 0 ]] && pass "D R2 HTML fail" || fail "D HTML should fail"

# checksum mismatch ACPS
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
ACPS_BAD="${WORKDIR}/acps-bad"; cp -a "$ACPS_ROOT" "$ACPS_BAD"
echo '0000000000000000000000000000000000000000' >"${ACPS_BAD}/aelladeb_py3_common.tar.gz.sha1"
R2_ROOT2="${WORKDIR}/r2-ok"; mkdir -p "$R2_ROOT2"; cp -f "$PKG_E" "${PKG_E}.sha256" "$R2_ROOT2/"
start_r2 "$R2_ROOT2"
start_http "$ACPS_BAD" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_LOCK_FILE="${WORKDIR}/lock-acps-bad"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-acps-bad"
export MM_CACHE_ROOT="${WORKDIR}/mirror-acps-bad/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-acps-bad/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-acps-bad/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-acps-bad/client"
mkdir -p "$MM_CLIENT_ROOT"
set +e
out_bad="$(run_prepare 2>&1)"; rc_bad=$?
set -e
[[ "$rc_bad" -ne 0 ]] && pass "G ACPS checksum fail" || fail "G checksum"

# auth failure (no DP_PHASE2_SOURCE_BASE; use real auth against fail server)
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
start_http "$ACPS_ROOT" fail
unset DP_PHASE2_SOURCE_BASE
export MM_LOCK_FILE="${WORKDIR}/lock-auth"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-auth"
export MM_CACHE_ROOT="${WORKDIR}/mirror-auth/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-auth/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-auth/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-auth/client"
mkdir -p "$MM_CLIENT_ROOT"
set +e
out_auth="$(run_prepare 2>&1)"; rc_auth=$?
set -e
[[ "$rc_auth" -ne 0 ]] && pass "G ACPS auth fail" || fail "G auth"
echo "$out_auth" | grep -qi 'testpass' && fail "F secret leaked" || pass "F no secret in output"

echo "======== I. upstream drift ========"
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
ACPS_DRIFT="${WORKDIR}/acps-drift"; cp -a "$ACPS_ROOT" "$ACPS_DRIFT"
printf 'DRIFTED_UPSTREAM_CONTENT\n' >"${ACPS_DRIFT}/bringup_py3_dp_after_os_upgrade.sh"
sha1sum "${ACPS_DRIFT}/bringup_py3_dp_after_os_upgrade.sh" | awk '{print $1}' \
  >"${ACPS_DRIFT}/bringup_py3_dp_after_os_upgrade.sh.sha1"
start_r2 "$R2_ROOT2"
start_http "$ACPS_DRIFT" none
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export MM_LOCK_FILE="${WORKDIR}/lock-drift"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-drift"
export MM_CACHE_ROOT="${WORKDIR}/mirror-drift/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-drift/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-drift/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-drift/client"
mkdir -p "$MM_CLIENT_ROOT"
set +e
out_drift="$(run_prepare 2>&1)"; rc_drift=$?
set -e
[[ "$rc_drift" -ne 0 ]] && echo "$out_drift" | grep -q 'UPSTREAM_BRINGUP_DRIFT=YES' \
  && pass "I upstream drift" || fail "I drift"
[[ ! -f "${WORKDIR}/mirror-drift/dp-phase2/6.5.0/dp_bundle_6.5.0-current.tar" ]] \
  && pass "I no final bundle" || fail "I bundle published on drift"

echo "======== G resume ========"
kill "$HTTP_PID" 2>/dev/null || true; wait "$HTTP_PID" 2>/dev/null || true; HTTP_PID=""
kill "$R2_PID" 2>/dev/null || true; wait "$R2_PID" 2>/dev/null || true; R2_PID=""
ACPS_G="${WORKDIR}/acps-g"; cp -a "$ACPS_ROOT" "$ACPS_G"
dd if=/dev/urandom of="${ACPS_G}/images-6.5.0.tar" bs=1024 count=64 status=none
sha256sum "${ACPS_G}/images-6.5.0.tar" | awk '{print $1}' >"${ACPS_G}/images-6.5.0.tar.sha256"
start_r2 "$R2_ROOT2"
start_http "$ACPS_G" none
export DP_PHASE2_SOURCE_BASE="http://127.0.0.1:${HTTP_PORT}"
export OS_CORE_R2_URL="http://127.0.0.1:${R2_PORT}/$(basename "$PKG_E")"
export MM_LOCK_FILE="${WORKDIR}/lock-g"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-g"
export MM_CACHE_ROOT="${WORKDIR}/mirror-g/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-g/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-g/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-g/client"
mkdir -p "${WORKDIR}/mirror-g/.install-cache/acps/6.5.0" "$MM_CLIENT_ROOT"
for f in aelladeb_py3_common.tar.gz aelladeb_py3_common.tar.gz.sha1 \
  aella-uvp-2404_6.5.0ubuntu1_amd64.deb aella-uvp-2404_6.5.0ubuntu1_amd64.deb.sha1 \
  bringup_py3_dp_after_os_upgrade.sh bringup_py3_dp_after_os_upgrade.sh.sha1 \
  images-6.5.0.list images-6.5.0.tar.sha256; do
  cp -f "${ACPS_G}/$f" "${WORKDIR}/mirror-g/.install-cache/acps/6.5.0/$f"
done
dd if="${ACPS_G}/images-6.5.0.tar" of="${WORKDIR}/mirror-g/.install-cache/acps/6.5.0/images-6.5.0.tar.part" bs=1024 count=10 status=none
if run_prepare; then pass "G resume"; else fail "G resume"; fi

echo "======== P disk + lock + entrypoint ========"
export MM_MOCK_AVAILABLE_BYTES=1000
export MM_LOCK_FILE="${WORKDIR}/lock-disk"
export MM_MIRROR_ROOT="${WORKDIR}/mirror-disk"
export MM_CACHE_ROOT="${WORKDIR}/mirror-disk/.install-cache"
export MM_SELECTIVE_ROOT="${WORKDIR}/mirror-disk/selective"
export MM_DP_PHASE2_ROOT="${WORKDIR}/mirror-disk/dp-phase2"
export MM_CLIENT_ROOT="${WORKDIR}/mirror-disk/client"
mkdir -p "$MM_CLIENT_ROOT"
set +e
out_disk="$(run_prepare 2>&1)"; rc_disk=$?
set -e
[[ "$rc_disk" -ne 0 ]] && echo "$out_disk" | grep -q 'DISK_PREFLIGHT=FAIL' && pass "P disk" || fail "P disk"
unset MM_MOCK_AVAILABLE_BYTES

export MM_LOCK_FILE="${WORKDIR}/lock-v"
exec {lockfd}>"$MM_LOCK_FILE"; flock -n "$lockfd"
set +e
out_v="$(MM_DRY_RUN=1 run_prepare --dry-run 2>&1)"; rc_v=$?
set -e
flock -u "$lockfd"; eval "exec ${lockfd}>&-"
[[ "$rc_v" -ne 0 ]] && echo "$out_v" | grep -q 'INSTALL_LOCK=BUSY' && pass "P lock" || fail "P lock"

bash "${ROOT}/scripts/ubuntu-offline-mirror.sh" --help 2>&1 | grep -q 'mirror-manager' \
  && pass "entrypoint mirror-manager" || fail "entrypoint missing"
bash "${ROOT}/scripts/ubuntu-offline-mirror.sh" --help 2>&1 | grep -qE 'install-standard|install-menu|Mode 2' \
  && fail "entrypoint obsolete cmds" || pass "entrypoint no obsolete cmds"

# Hardcoded credential absence in new manager scripts
grep -RInE 'AellaMeta|WroTQfm' "${ROOT}/scripts/lib/mirror_manager_common.sh" \
  "${ROOT}/scripts/lib/mirror_install_engine.sh" "${ROOT}/scripts/lib/acps_acquire.sh" \
  "${ROOT}/scripts/install-dp-upgrade-mirror.sh" 2>/dev/null \
  && fail "F hardcoded creds in manager" || pass "F no hardcoded manager creds"
grep -nE "ACPS_PASS='|ACPS_USER=\"Aella" "${ROOT}/scripts/download-dp-phase2.sh" \
  && fail "F hardcoded in download-dp-phase2" || pass "F download-dp-phase2 creds removed"

echo "======== Q. production safety ========"
PROD_CUR="$(readlink /var/spool/apt-mirror/dp-phase2/6.5.0/current 2>/dev/null || true)"
PROD_PREV="$(readlink /var/spool/apt-mirror/dp-phase2/6.5.0/previous 2>/dev/null || true)"
[[ "$PROD_CUR" == "releases/20260728T110548Z" ]] && pass "Q production current" || fail "Q current=$PROD_CUR"
[[ "$PROD_PREV" == "releases/20260726T155911Z" ]] && pass "Q production previous" || fail "Q previous=$PROD_PREV"

echo "======== DONE fail=${FAIL} ========"
exit "$FAIL"
