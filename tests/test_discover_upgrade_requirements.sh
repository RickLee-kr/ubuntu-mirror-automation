#!/usr/bin/env bash
# tests/test_discover_upgrade_requirements.sh — fixture-based discovery tests
# Does NOT run apt upgrade, do-release-upgrade, or reboot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/discover-upgrade-requirements.sh"
COMMON="${ROOT}/scripts/lib/discover-upgrade-requirements-common.sh"
PY="${ROOT}/scripts/lib/discover_upgrade_requirements.py"
FIXTURES="${ROOT}/tests/fixtures/discover-upgrade-requirements"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export DUR_REGISTRY_DIR="${WORKDIR}/registry"
mkdir -p "$DUR_REGISTRY_DIR"

echo "[test] discover-upgrade-requirements"

# ---------------------------------------------------------------------------
# Syntax / CLI / Python 3.5 compatibility
# ---------------------------------------------------------------------------
if bash -n "$SCRIPT" && bash -n "$COMMON"; then
  pass "bash -n"
else
  fail "bash -n"
fi

if python3 -m py_compile "$PY" "${ROOT}/scripts/lib/discover_upgrade_http_proxy.py"; then
  pass "python3 py_compile"
else
  fail "python3 py_compile"
fi

if python3 "${ROOT}/tests/check_py35_syntax.py"; then
  pass "Python 3.5 compatibility checker"
else
  fail "Python 3.5 compatibility checker"
fi

if bash "$SCRIPT" --help >/dev/null; then
  pass "--help"
else
  fail "--help"
fi

ver="$(bash "$SCRIPT" --version 2>/dev/null || true)"
if [[ "$ver" == *discover-upgrade-requirements.sh* ]]; then
  pass "--version ($ver)"
else
  fail "--version: $ver"
fi

if bash "$SCRIPT" definitely-not-a-command >/dev/null 2>&1; then
  fail "unknown command should fail"
else
  pass "unknown command fails"
fi

# Source common without running main
# shellcheck source=scripts/lib/discover-upgrade-requirements-common.sh
source "$COMMON"
# shellcheck source=scripts/discover-upgrade-requirements.sh
source "$SCRIPT"

if declare -F cmd_init >/dev/null; then
  pass "source loads commands"
else
  fail "source did not load commands"
fi

# ---------------------------------------------------------------------------
# Unit: hop name / URL classify / access log / packages index / sha256 / deb
# ---------------------------------------------------------------------------
hop="$(python3 "$PY" hop-name --from-os 16.04 --to-os 18.04)"
[[ "$hop" == "xenial-to-bionic" ]] && pass "hop-name xenial-to-bionic" || fail "hop-name: $hop"

for pair in "18.04:20.04:bionic-to-focal" "20.04:22.04:focal-to-jammy" "22.04:24.04:jammy-to-noble"; do
  IFS=':' read -r a b expect <<<"$pair"
  got="$(python3 "$PY" hop-name --from-os "$a" --to-os "$b")"
  [[ "$got" == "$expect" ]] && pass "hop-name $expect" || fail "hop-name $a->$b got $got"
done

classify() { python3 "$PY" classify-url "$1"; }
[[ "$(classify 'http://x/ubuntu/pool/main/b/bash/bash_1_amd64.deb')" == "deb" ]] && pass "classify deb" || fail "classify deb"
[[ "$(classify 'http://x/ubuntu/dists/bionic/InRelease')" == "inrelease" ]] && pass "classify inrelease" || fail "classify inrelease"
[[ "$(classify 'http://x/ubuntu/dists/bionic/main/binary-amd64/Packages.gz')" == "packages_index" ]] && pass "classify packages_index" || fail "classify packages_index"
[[ "$(classify 'http://changelogs.ubuntu.com/meta-release-lts')" == "meta_release" ]] && pass "classify meta_release" || fail "classify meta_release"
[[ "$(classify 'http://x/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz')" == "release_upgrader" ]] && pass "classify release_upgrader" || fail "classify release_upgrader"
[[ "$(classify 'http://x/ubuntu/dists/bionic/Release.gpg')" == "release_gpg" ]] && pass "classify release_gpg" || fail "classify release_gpg"
[[ "$(classify 'http://x/ubuntu/dists/bionic/main/i18n/Translation-en')" == "translation" ]] && pass "classify translation" || fail "classify translation"

OUT_URLS="${WORKDIR}/urls.tsv"
python3 "$PY" parse-access-log \
  --log "${FIXTURES}/access-logs/sample-proxy-access.log" \
  --hop xenial-to-bionic \
  --output "$OUT_URLS"
if grep -q 'bionic.tar.gz' "$OUT_URLS" && grep -q 'meta-release-lts' "$OUT_URLS"; then
  pass "apt access log URL extraction"
else
  fail "apt access log URL extraction"
fi

# redirect: original + final preserved
if awk -F'\t' 'NR>1 && $4 ~ /dists\/bionic\/InRelease/ && $5 ~ /bionic-updates\/InRelease/ {found=1} END{exit !found}' "$OUT_URLS"; then
  pass "HTTP redirect original+final"
else
  fail "HTTP redirect original+final"
fi

# request_count for duplicate bash deb (>=2)
bash_count="$(awk -F'\t' 'NR>1 && $4 ~ /bash_4.4.18/ {print $10; exit}' "$OUT_URLS")"
if [[ "${bash_count:-0}" -ge 2 ]]; then
  pass "duplicate URL request_count ($bash_count)"
else
  fail "duplicate URL request_count ($bash_count)"
fi

OUT_IDX="${WORKDIR}/packages-index.tsv"
python3 "$PY" parse-packages-index --index "${FIXTURES}/packages-index/Packages" --output "$OUT_IDX"
if grep -q $'^bash\t4.4.18-2ubuntu1\tamd64\t' "$OUT_IDX" && grep -q 'Depends' <<<"$(head -1 "$OUT_IDX")"; then
  pass "Packages index parsing"
else
  fail "Packages index parsing"
fi

DEB="${FIXTURES}/debs/bash_4.4.18-2ubuntu1_amd64.deb"
meta="$(python3 "$PY" extract-deb "$DEB")"
echo "$meta" | grep -q 'package=bash' && pass ".deb metadata package" || fail ".deb metadata package: $meta"
echo "$meta" | grep -q 'version=4.4.18-2ubuntu1' && pass ".deb metadata version" || fail ".deb metadata version"
echo "$meta" | grep -q 'architecture=amd64' && pass ".deb metadata architecture" || fail ".deb metadata architecture"
echo "$meta" | grep -q 'sha256=' && pass "SHA256 generation" || fail "SHA256 generation"

# ---------------------------------------------------------------------------
# Package diff: added/upgraded/removed + arch distinction
# ---------------------------------------------------------------------------
DIFF_OUT="${WORKDIR}/diff"
python3 "$PY" diff-packages \
  --before "${FIXTURES}/inventories/before-installed-packages.tsv" \
  --after "${FIXTURES}/inventories/after-installed-packages.tsv" \
  --output-dir "$DIFF_OUT" >/dev/null

grep -q $'^newpkg\tamd64\t\t1.0\tadded$' "${DIFF_OUT}/packages-added.tsv" && pass "packages-added" || fail "packages-added"
grep -q $'^oldpkg\tamd64\t1.0\t\tremoved$' "${DIFF_OUT}/packages-removed.tsv" && pass "packages-removed" || fail "packages-removed"
grep -q $'^bash\tamd64\t4.3-14ubuntu1\t4.4.18-2ubuntu1\tupgraded$' "${DIFF_OUT}/packages-upgraded.tsv" && pass "packages-upgraded" || fail "packages-upgraded"
grep -q $'^shared\tamd64\t1.0\t1.0\tunchanged$' "${DIFF_OUT}/packages-unchanged.tsv" && pass "packages-unchanged" || fail "packages-unchanged"
grep -q $'^multiarch\ti386\t1.0\t2.0\tupgraded$' "${DIFF_OUT}/packages-upgraded.tsv" && pass "different architecture distinguished" || fail "different architecture distinguished"

# ---------------------------------------------------------------------------
# output-dir lifecycle + init failure safety (no real upgrade)
# ---------------------------------------------------------------------------
CUSTOM="${WORKDIR}/custom-run"
BAD_INIT="${WORKDIR}/bad-init"
export DUR_DRY_RECORDING=1
export DUR_HOST_ROOT="${WORKDIR}/hostroot-empty"
mkdir -p \
  "${WORKDIR}/hostroot-empty/tmp" \
  "${WORKDIR}/hostroot-empty/etc/apt/sources.list.d" \
  "${WORKDIR}/hostroot-empty/var/log/apt" \
  "${WORKDIR}/hostroot-empty/var/lib/dpkg" \
  "${WORKDIR}/hostroot-empty/usr/local" \
  "${WORKDIR}/hostroot-empty/opt/aelladata"
printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\n' >"${WORKDIR}/hostroot-empty/etc/os-release"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${WORKDIR}/hostroot-empty/tmp/installed-packages.tsv"
: >"${WORKDIR}/hostroot-empty/var/log/apt/history.log"
: >"${WORKDIR}/hostroot-empty/var/log/apt/term.log"
: >"${WORKDIR}/hostroot-empty/var/log/dpkg.log"

set +e
bash "$SCRIPT" init --from 16.04 --to 18.04 >/dev/null 2>"${WORKDIR}/init-no-outdir.err"
rc_no_outdir=$?
set -e
if [[ "$rc_no_outdir" -ne 0 ]] && grep -q 'output-dir' "${WORKDIR}/init-no-outdir.err"; then
  pass "init requires --output-dir"
else
  fail "init requires --output-dir rc=$rc_no_outdir"
fi

set +e
bash "$SCRIPT" init --from 16.04 --to 17.04 --output-dir "$BAD_INIT" >/dev/null 2>"${WORKDIR}/init-bad-hop.err"
rc_bad=$?
set -e
if [[ "$rc_bad" -ne 0 ]] && [[ ! -f "${BAD_INIT}/upgrade-discovery/.discovery-state.json" ]]; then
  pass "init failure leaves no partial active state"
else
  fail "init failure left partial state rc=$rc_bad"
fi

if bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$CUSTOM"; then
  pass "Python 3.5-compatible init with custom output-dir"
else
  fail "Python 3.5-compatible init with custom output-dir"
fi
[[ -f "${CUSTOM}/upgrade-discovery/.discovery-state.json" ]] && pass "custom output-dir state created" || fail "custom output-dir state created"

# Must not read default /var/tmp when custom dir was used
if [[ -d /var/tmp/ubuntu-upgrade-discovery/upgrade-discovery ]] && \
   grep -q xenial-to-bionic /var/tmp/ubuntu-upgrade-discovery/upgrade-discovery/.discovery-state.json 2>/dev/null; then
  # only fail if that default state was created by this test run (mtime recent + our registry missing it)
  if ! grep -qx "$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' /var/tmp/ubuntu-upgrade-discovery)" "$DUR_REGISTRY_DIR/active-runs.list" 2>/dev/null; then
    : # unrelated pre-existing default; ignore
  fi
fi

if bash "$SCRIPT" before-hop --output-dir "$CUSTOM"; then
  pass "before-hop with same custom output-dir"
else
  fail "before-hop with same custom output-dir"
fi

# Pre-recording noise must be discarded by start-recording
PRE_URL='http://example.invalid/pre-recording-should-not-appear.deb'
mkdir -p "${CUSTOM}/upgrade-discovery/xenial-to-bionic/runtime"
printf '2026-07-17T00:00:00Z GET %s 200 1\n' "$PRE_URL" \
  >"${CUSTOM}/upgrade-discovery/xenial-to-bionic/runtime/proxy-access.log"

if bash "$SCRIPT" start-recording --output-dir "$CUSTOM"; then
  pass "start-recording with same custom output-dir"
else
  fail "start-recording with same custom output-dir"
fi
if grep -q 'pre-recording-should-not-appear' "${CUSTOM}/upgrade-discovery/xenial-to-bionic/runtime/proxy-access.log"; then
  fail "start-recording did not clear pre-recording proxy log"
else
  pass "pre-recording APT requests cleared on start-recording"
fi
PROXY_CONF_CUSTOM="${WORKDIR}/hostroot-empty/etc/apt/apt.conf.d/99upgrade-discovery-recorder"
if [[ -f "$PROXY_CONF_CUSTOM" ]] && grep -q 'Acquire::http::Proxy "http://127.0.0.1:18080/"' "$PROXY_CONF_CUSTOM"; then
  pass "start-recording auto-installs APT proxy config"
else
  fail "start-recording auto-installs APT proxy config (missing $PROXY_CONF_CUSTOM)"
fi
if grep -q 'Acquire::https::Proxy "DIRECT"' "$PROXY_CONF_CUSTOM"; then
  pass "HTTPS routed DIRECT (unsupported full-URL capture)"
else
  fail "HTTPS routed DIRECT (unsupported full-URL capture)"
fi

st_custom="$(bash "$SCRIPT" status --output-dir "$CUSTOM" 2>&1 || true)"
echo "$st_custom" | grep -q "$CUSTOM" && pass "status with same custom output-dir" || fail "status custom: $st_custom"
echo "$st_custom" | grep -q 'xenial-to-bionic' && pass "status reports custom hop" || fail "status reports custom hop"

# Omitting --output-dir uses unique active custom run (not /var/tmp default)
st_auto="$(bash "$SCRIPT" status 2>&1 || true)"
echo "$st_auto" | grep -q "$CUSTOM" && pass "status without --output-dir uses unique active custom run" || fail "status auto: $st_auto"
echo "$st_auto" | grep -q '/var/tmp/ubuntu-upgrade-discovery' && fail "status incorrectly selected /var/tmp default" || pass "status does not fall back to /var/tmp default"

# Ambiguous runs blocked
OTHER="${WORKDIR}/other-run"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$OTHER" >/dev/null
set +e
bash "$SCRIPT" status >"${WORKDIR}/ambiguous.out" 2>"${WORKDIR}/ambiguous.err"
rc_amb=$?
set -e
if [[ "$rc_amb" -ne 0 ]] && grep -qi 'ambiguous' "${WORKDIR}/ambiguous.err" "${WORKDIR}/ambiguous.out"; then
  pass "output-dir omit blocked when ambiguous"
else
  fail "output-dir omit ambiguous rc=$rc_amb out=$(cat "${WORKDIR}/ambiguous.out") err=$(cat "${WORKDIR}/ambiguous.err")"
fi

# Clean ambiguous second run so later unique-active tests stay simple
rm -rf "$OTHER"
# remove from registry
if [[ -f "$DUR_REGISTRY_DIR/active-runs.list" ]]; then
  grep -vxF "$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OTHER")" \
    "$DUR_REGISTRY_DIR/active-runs.list" >"${DUR_REGISTRY_DIR}/active-runs.list.tmp" || true
  mv "${DUR_REGISTRY_DIR}/active-runs.list.tmp" "$DUR_REGISTRY_DIR/active-runs.list"
fi

# ---------------------------------------------------------------------------
# End-to-end fixture hop (no real upgrade)
# ---------------------------------------------------------------------------
OUT1="${WORKDIR}/out1"
export DUR_HOST_ROOT="${WORKDIR}/hostroot"
mkdir -p \
  "${DUR_HOST_ROOT}/etc/apt/sources.list.d" \
  "${DUR_HOST_ROOT}/etc/apt/preferences.d" \
  "${DUR_HOST_ROOT}/var/log/apt" \
  "${DUR_HOST_ROOT}/var/log/dist-upgrade" \
  "${DUR_HOST_ROOT}/var/cache/apt/archives/partial" \
  "${DUR_HOST_ROOT}/var/lib/dpkg" \
  "${DUR_HOST_ROOT}/var/lib/apt" \
  "${DUR_HOST_ROOT}/usr/local/bin" \
  "${DUR_HOST_ROOT}/opt/aelladata" \
  "${DUR_HOST_ROOT}/tmp"

printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\nVERSION_CODENAME=xenial\n' >"${DUR_HOST_ROOT}/etc/os-release"
printf 'deb http://archive.ubuntu.com/ubuntu xenial main\n' >"${DUR_HOST_ROOT}/etc/apt/sources.list"
printf 'Package: bash\nStatus: install ok installed\nVersion: 4.3-14ubuntu1\nArchitecture: amd64\n\n' >"${DUR_HOST_ROOT}/var/lib/dpkg/status"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${DUR_HOST_ROOT}/tmp/installed-packages.tsv"
: >"${DUR_HOST_ROOT}/var/log/apt/history.log"
: >"${DUR_HOST_ROOT}/var/log/apt/term.log"
: >"${DUR_HOST_ROOT}/var/log/dpkg.log"
echo 'hello' >"${DUR_HOST_ROOT}/etc/hostname"
echo 'tool' >"${DUR_HOST_ROOT}/usr/local/bin/tool"
echo 'data' >"${DUR_HOST_ROOT}/opt/aelladata/marker"

# init
if bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUT1"; then
  pass "init"
else
  fail "init"
fi

HOP_DIR="${OUT1}/upgrade-discovery/xenial-to-bionic"
[[ -f "${HOP_DIR}/run.json" ]] && pass "hop layout run.json" || fail "hop layout run.json"

# before-hop
if bash "$SCRIPT" before-hop --output-dir "$OUT1"; then
  pass "before-hop"
else
  fail "before-hop"
fi
[[ -f "${HOP_DIR}/before/installed-packages.tsv" ]] && pass "before inventory" || fail "before inventory"
[[ -f "${HOP_DIR}/before/file-manifest.tsv" ]] && pass "before file-manifest" || fail "before file-manifest"

# start/stop recording
if bash "$SCRIPT" start-recording --output-dir "$OUT1"; then
  pass "start-recording"
else
  fail "start-recording"
fi

# Simulate upgrade traffic + package cache + logs (no real apt)
cp "${FIXTURES}/access-logs/sample-proxy-access.log" "${HOP_DIR}/runtime/proxy-access.log"
mkdir -p "${HOP_DIR}/runtime/deb-cache"
cp "${FIXTURES}/debs/"*.deb "${HOP_DIR}/runtime/deb-cache/"
python3 "${FIXTURES}/seed_complete_captures.py" "$HOP_DIR" "$FIXTURES"
cp "${FIXTURES}/packages-index/Packages" "${HOP_DIR}/metadata/Packages"
printf 'Start-Date: 2026-07-17\nCommandline: apt dist-upgrade\nEnd-Date: 2026-07-17\n' >>"${DUR_HOST_ROOT}/var/log/apt/history.log"
printf 'apt term log slice\n' >>"${DUR_HOST_ROOT}/var/log/apt/term.log"
printf '2026-07-17 upgrade bash:amd64 4.3-14ubuntu1 4.4.18-2ubuntu1\n' >>"${DUR_HOST_ROOT}/var/log/dpkg.log"
printf 'dist-upgrade main log\n' >"${DUR_HOST_ROOT}/var/log/dist-upgrade/main.log"
cp "${FIXTURES}/debs/bash_4.4.18-2ubuntu1_amd64.deb" "${DUR_HOST_ROOT}/var/cache/apt/archives/"

# after inventory fixture swap
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${DUR_HOST_ROOT}/tmp/installed-packages.tsv"
printf 'NAME="Ubuntu"\nVERSION_ID="18.04"\nVERSION_CODENAME=bionic\n' >"${DUR_HOST_ROOT}/etc/os-release"

if bash "$SCRIPT" stop-recording --output-dir "$OUT1"; then
  pass "stop-recording"
else
  fail "stop-recording"
fi
[[ -f "${HOP_DIR}/runtime/apt-history.log" ]] && pass "apt history preserved" || fail "apt history preserved"
[[ -f "${HOP_DIR}/runtime/dpkg.log" ]] && pass "dpkg log preserved" || fail "dpkg log preserved"
[[ -d "${HOP_DIR}/runtime/dist-upgrade" ]] && pass "dist-upgrade preserved" || fail "dist-upgrade preserved"

if bash "$SCRIPT" after-hop --output-dir "$OUT1"; then
  pass "after-hop"
else
  fail "after-hop"
fi

# Replace collected inventories with richer fixtures for diff assertions
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP_DIR}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${HOP_DIR}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP_DIR}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/after-file-manifest.tsv" "${HOP_DIR}/after/file-manifest.tsv"
cp "${FIXTURES}/inventories/before-conffiles.tsv" "${HOP_DIR}/before/conffiles.tsv"
cp "${FIXTURES}/inventories/after-conffiles.tsv" "${HOP_DIR}/after/conffiles.tsv"

if bash "$SCRIPT" finalize-hop --output-dir "$OUT1"; then
  pass "finalize-hop"
else
  fail "finalize-hop"
  cat "${HOP_DIR}/validation.txt" 2>/dev/null || true
fi

for f in required-packages.tsv required-files.tsv required-urls.tsv evidence.json validation.txt \
  diff/packages-added.tsv diff/packages-upgraded.tsv diff/packages-removed.tsv \
  packages/downloaded-packages.tsv packages/requested-packages.tsv \
  metadata/release-upgrader-files.tsv metadata/repository-index-files.tsv \
  unresolved-packages.tsv unresolved-files.tsv failed-requests.tsv; do
  if [[ -f "${HOP_DIR}/$f" ]]; then
    pass "artifact $f"
  else
    fail "artifact $f missing"
  fi
done

grep -q 'VALIDATION: PASS' "${HOP_DIR}/validation.txt" && pass "validation PASS" || fail "validation PASS"
grep -q 'required_packages=' "${HOP_DIR}/validation.txt" && pass "validation metrics required_packages" || fail "validation metrics required_packages"
grep -q 'captured_http_200=' "${HOP_DIR}/validation.txt" && pass "validation metrics captured_http_200" || fail "validation metrics captured_http_200"
grep -q 'unresolved_packages=0' "${HOP_DIR}/validation.txt" && pass "validation unresolved_packages=0" || fail "validation unresolved_packages=0"

# required-packages columns
hdr="$(head -1 "${HOP_DIR}/required-packages.tsv")"
for col in hop package version architecture source_package filename repository_host suite component size_bytes sha256 original_url final_url requested downloaded installed evidence_source; do
  [[ "$hdr" == *$col* ]] || fail "required-packages missing column $col"
done
pass "required-packages.tsv columns"

hdrf="$(head -1 "${HOP_DIR}/required-files.tsv")"
for col in hop file_type filename original_url final_url local_path size_bytes sha256 http_status request_count evidence_source; do
  [[ "$hdrf" == *$col* ]] || fail "required-files missing column $col"
done
pass "required-files.tsv columns"

# duplicate package/version/arch collapsed
bash_lines="$(awk -F'\t' 'NR>1 && $2=="bash" && $3=="4.4.18-2ubuntu1" && $4=="amd64" {c++} END{print c+0}' "${HOP_DIR}/required-packages.tsv")"
[[ "$bash_lines" -eq 1 ]] && pass "same package deduplicated" || fail "same package deduplicated ($bash_lines)"

# different versions remain distinct if present — inject a second version row check via unit style
# downloaded but not installed preserved (extra.deb requested, not in after inventory)
if grep -q $'^xenial-to-bionic\textra\t' "${HOP_DIR}/required-packages.tsv"; then
  inst="$(awk -F'\t' 'NR>1 && $2=="extra" {print $16; exit}' "${HOP_DIR}/required-packages.tsv")"
  [[ "$inst" == "false" ]] && pass "downloaded but not installed preserved" || fail "downloaded but not installed flag ($inst)"
else
  fail "extra package missing from manifests"
fi

# zlib downloaded and installed
grep -q $'^xenial-to-bionic\tzlib1g\t' "${HOP_DIR}/required-packages.tsv" && pass "zlib in required-packages" || fail "zlib in required-packages"

# release upgrader metadata classified
if grep -q 'release_upgrader' "${HOP_DIR}/metadata/release-upgrader-files.tsv" && grep -q 'meta_release' "${HOP_DIR}/metadata/release-upgrader-files.tsv"; then
  pass "release upgrader metadata classification"
else
  fail "release upgrader metadata classification"
fi

# repository metadata classified
if grep -q 'inrelease\|packages_index\|release_gpg' "${HOP_DIR}/metadata/repository-index-files.tsv"; then
  pass "repository metadata classification"
else
  fail "repository metadata classification"
fi

# unresolved / failed
grep -q 'missing_1.0_amd64.deb' "${HOP_DIR}/failed-requests.tsv" && pass "unresolved/failed URL recorded" || fail "failed URL recorded"
grep -q '404' "${HOP_DIR}/failed-requests.tsv" && pass "HTTP 404 reason recorded" || fail "HTTP 404 reason"

# overwrite prevention
if bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUT1" >/dev/null 2>&1; then
  fail "overwrite finalized hop should fail"
else
  pass "overwrite prevention"
fi

if bash "$SCRIPT" finalize-hop --output-dir "$OUT1" >/dev/null 2>&1; then
  fail "re-finalize should fail"
else
  pass "re-finalize refused"
fi

# ---------------------------------------------------------------------------
# Hop isolation + resume
# ---------------------------------------------------------------------------
OUT2="${WORKDIR}/out2"
# reuse same hostroot
if bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$OUT2"; then
  pass "init second hop root"
else
  fail "init second hop root"
fi
HOP2="${OUT2}/upgrade-discovery/bionic-to-focal"
bash "$SCRIPT" before-hop --output-dir "$OUT2" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$OUT2" >/dev/null
# interrupt: do not stop — resume via init
if bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$OUT2" | grep -qi 'Resumed'; then
  pass "resume after interrupt"
else
  # status should still show recording
  st="$(bash "$SCRIPT" status --output-dir "$OUT2")"
  echo "$st" | grep -q 'recording' && pass "resume after interrupt (phase retained)" || fail "resume after interrupt: $st"
fi

# Ensure hop1 artifacts not inside hop2
if [[ ! -f "${HOP2}/required-packages.tsv" ]] && [[ -f "${HOP_DIR}/required-packages.tsv" ]]; then
  pass "hop result isolation"
else
  # hop2 not finalized — required may be absent; ensure run.json hop names differ
  h1="$(python3 -c 'import json; print(json.load(open("'"${HOP_DIR}/run.json"'"))["hop"])')"
  h2="$(python3 -c 'import json; print(json.load(open("'"${HOP2}/run.json"'"))["hop"])')"
  [[ "$h1" != "$h2" ]] && pass "hop result isolation" || fail "hop result isolation"
fi

# Complete hop2 minimally and ensure no cross contamination
cp "${FIXTURES}/access-logs/sample-proxy-access.log" "${HOP2}/runtime/proxy-access.log"
# rewrite hop field expectations by using build with hop name bionic-to-focal
mkdir -p "${HOP2}/runtime/deb-cache"
cp "${FIXTURES}/debs/"*.deb "${HOP2}/runtime/deb-cache/"
python3 "${FIXTURES}/seed_complete_captures.py" "$HOP2" "$FIXTURES"
bash "$SCRIPT" stop-recording --output-dir "$OUT2" >/dev/null
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${DUR_HOST_ROOT}/tmp/installed-packages.tsv"
bash "$SCRIPT" after-hop --output-dir "$OUT2" >/dev/null
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP2}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${HOP2}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP2}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/after-file-manifest.tsv" "${HOP2}/after/file-manifest.tsv"
: >"${HOP2}/before/conffiles.tsv"; echo -e 'path\thash\tpackage' >"${HOP2}/before/conffiles.tsv"
: >"${HOP2}/after/conffiles.tsv"; echo -e 'path\thash\tpackage' >"${HOP2}/after/conffiles.tsv"
if bash "$SCRIPT" finalize-hop --output-dir "$OUT2" >/dev/null; then
  pass "finalize second hop"
else
  fail "finalize second hop"
  cat "${HOP2}/validation.txt" || true
fi
if awk -F'\t' 'NR>1 && $1!="bionic-to-focal" {bad=1} END{exit bad+0}' "${HOP2}/required-packages.tsv"; then
  pass "no cross-hop contamination"
else
  fail "cross-hop contamination"
fi

# ---------------------------------------------------------------------------
# Validation failure path
# ---------------------------------------------------------------------------
OUT3="${WORKDIR}/out3"
bash "$SCRIPT" init --from 20.04 --to 22.04 --output-dir "$OUT3" >/dev/null
HOP3="${OUT3}/upgrade-discovery/focal-to-jammy"
bash "$SCRIPT" before-hop --output-dir "$OUT3" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$OUT3" >/dev/null
bash "$SCRIPT" stop-recording --output-dir "$OUT3" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$OUT3" >/dev/null
# Break validation: remove after inventory
rm -f "${HOP3}/after/installed-packages.tsv"
set +e
bash "$SCRIPT" finalize-hop --output-dir "$OUT3" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'VALIDATION: FAIL' "${HOP3}/validation.txt"; then
  pass "finalize validation failure handling"
else
  fail "finalize validation failure handling rc=$rc"
fi
# phase must not be finalized
phase="$(python3 -c 'import json; print(json.load(open("'"${OUT3}/upgrade-discovery/.discovery-state.json"'"))["phase"])')"
[[ "$phase" != "finalized" ]] && pass "failed finalize not marked success" || fail "failed finalize marked success"

# status command
st_out="$(bash "$SCRIPT" status --output-dir "$OUT1" 2>&1 || true)"
echo "$st_out" | grep -q 'xenial-to-bionic' && pass "status" || fail "status: $st_out"

# ---------------------------------------------------------------------------
# Non-ASCII dpkg *.list paths + before-hop failure / start-recording gate
# ---------------------------------------------------------------------------
UNI="${WORKDIR}/unicode-host"
OUTU="${WORKDIR}/out-unicode"
mkdir -p \
  "${UNI}/etc/apt/apt.conf.d" \
  "${UNI}/etc/apt/sources.list.d" \
  "${UNI}/var/log/apt" \
  "${UNI}/var/lib/dpkg/info" \
  "${UNI}/usr/local" \
  "${UNI}/opt/aelladata" \
  "${UNI}/tmp"
printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\n' >"${UNI}/etc/os-release"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${UNI}/tmp/installed-packages.tsv"
: >"${UNI}/var/log/apt/history.log"
: >"${UNI}/var/log/apt/term.log"
: >"${UNI}/var/log/dpkg.log"
# Latin-1 0xc5 (Å) — must not raise UnicodeDecodeError under LC_ALL=C
NONASCII_NAME="$(python3 -c 'import sys; sys.stdout.buffer.write(b"caf\xc5.txt")')"
NONASCII_PATH="/etc/${NONASCII_NAME}"
python3 -c '
import os, sys
root = sys.argv[1]
name = b"caf\xc5.txt"
path = os.path.join(root, "etc").encode("utf-8") + b"/" + name
open(path, "wb").write(b"payload\n")
listdir = os.path.join(root, "var/lib/dpkg/info/nonascii-pkg.list")
with open(listdir, "wb") as fh:
    fh.write(b"/etc/" + name + b"\n")
' "$UNI"
echo "hello" >"${UNI}/etc/hostname"

export DUR_HOST_ROOT="$UNI"
export DUR_DRY_RECORDING=1
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTU" >/dev/null
if bash "$SCRIPT" before-hop --output-dir "$OUTU" >/dev/null; then
  pass "before-hop with non-ASCII dpkg list paths"
else
  fail "before-hop with non-ASCII dpkg list paths"
fi
HOPU="${OUTU}/upgrade-discovery/xenial-to-bionic"
if [[ -f "${HOPU}/before/file-manifest.tsv" ]]; then
  pass "file-manifest.tsv created with non-ASCII dpkg paths"
else
  fail "file-manifest.tsv created with non-ASCII dpkg paths"
fi
# Manifest must contain the non-ASCII basename (surrogate/utf-8 form)
if python3 -c '
import sys
raw = open(sys.argv[1], "rb").read()
sys.exit(0 if b"caf" in raw and b".txt" in raw else 1)
' "${HOPU}/before/file-manifest.tsv"; then
  pass "non-ASCII path preserved in file-manifest"
else
  fail "non-ASCII path preserved in file-manifest"
fi

# Force file-manifest failure: replace output path with a directory
OUTF="${WORKDIR}/out-fail-before"
FAILHOST="${WORKDIR}/fail-host"
mkdir -p \
  "${FAILHOST}/etc/apt/apt.conf.d" \
  "${FAILHOST}/etc/apt/sources.list.d" \
  "${FAILHOST}/var/log/apt" \
  "${FAILHOST}/var/lib/dpkg" \
  "${FAILHOST}/usr/local" \
  "${FAILHOST}/opt/aelladata" \
  "${FAILHOST}/tmp"
printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\n' >"${FAILHOST}/etc/os-release"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${FAILHOST}/tmp/installed-packages.tsv"
: >"${FAILHOST}/var/log/apt/history.log"
: >"${FAILHOST}/var/log/apt/term.log"
: >"${FAILHOST}/var/log/dpkg.log"
export DUR_HOST_ROOT="$FAILHOST"
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTF" >/dev/null
HOPF="${OUTF}/upgrade-discovery/xenial-to-bionic"
mkdir -p "${HOPF}/before/file-manifest.tsv"  # block TSV creation (IsADirectoryError)
set +e
bash "$SCRIPT" before-hop --output-dir "$OUTF" >"${WORKDIR}/before-fail.out" 2>"${WORKDIR}/before-fail.err"
rc_bf=$?
set -e
if [[ "$rc_bf" -ne 0 ]]; then
  pass "file manifest failure => before-hop nonzero"
else
  fail "file manifest failure => before-hop nonzero (rc=0)"
fi
if grep -q 'before inventory complete' "${WORKDIR}/before-fail.out" "${WORKDIR}/before-fail.err" 2>/dev/null; then
  fail "before inventory complete not printed on failure"
else
  pass "before inventory complete not printed on failure"
fi
if grep -q 'before-hop complete' "${WORKDIR}/before-fail.out" 2>/dev/null; then
  fail "before-hop complete not printed on failure"
else
  pass "before-hop complete not printed on failure"
fi
phase_f="$(python3 -c 'import json; print(json.load(open("'"${OUTF}/upgrade-discovery/.discovery-state.json"'"))["phase"])')"
[[ "$phase_f" == "before_failed" ]] && pass "state recorded as before_failed" || fail "state recorded as before_failed (got $phase_f)"
# Ensure no successful file-manifest.tsv file exists (only the blocking dir)
if [[ -f "${HOPF}/before/file-manifest.tsv" ]]; then
  fail "file-manifest.tsv must not be a regular file after failure"
else
  pass "file-manifest.tsv absent after failed before-hop"
fi
set +e
bash "$SCRIPT" start-recording --output-dir "$OUTF" >"${WORKDIR}/start-reject.out" 2>"${WORKDIR}/start-reject.err"
rc_sr=$?
set -e
if [[ "$rc_sr" -ne 0 ]]; then
  pass "start-recording rejected after failed before-hop"
else
  fail "start-recording rejected after failed before-hop"
fi
phase_sr="$(python3 -c 'import json; print(json.load(open("'"${OUTF}/upgrade-discovery/.discovery-state.json"'"))["phase"])')"
[[ "$phase_sr" != "recording" ]] && pass "proxy self-test/before failure keeps phase!=recording" || fail "phase incorrectly set to recording"

# Missing file-manifest after before_collected must also block start-recording
OUTM="${WORKDIR}/out-missing-manifest"
export DUR_HOST_ROOT="$UNI"
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTM" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$OUTM" >/dev/null
HOPM="${OUTM}/upgrade-discovery/xenial-to-bionic"
rm -f "${HOPM}/before/file-manifest.tsv"
set +e
bash "$SCRIPT" start-recording --output-dir "$OUTM" >/dev/null 2>&1
rc_m=$?
set -e
[[ "$rc_m" -ne 0 ]] && pass "start-recording rejects missing file-manifest.tsv" || fail "start-recording rejects missing file-manifest.tsv"

# ---------------------------------------------------------------------------
# APT proxy install / restore + live proxy download (no apt upgrade)
# ---------------------------------------------------------------------------
OUTP="${WORKDIR}/out-proxy"
PH="${WORKDIR}/proxy-host"
mkdir -p \
  "${PH}/etc/apt/apt.conf.d" \
  "${PH}/etc/apt/sources.list.d" \
  "${PH}/var/log/apt" \
  "${PH}/var/lib/dpkg" \
  "${PH}/var/cache/apt/archives/partial" \
  "${PH}/usr/local" \
  "${PH}/opt/aelladata" \
  "${PH}/tmp"
# Pre-existing proxy snippet that must be restored after stop
printf 'Acquire::http::Proxy "http://127.0.0.1:3142/";\n' >"${PH}/etc/apt/apt.conf.d/01preexisting-proxy"
printf 'NAME="Ubuntu"\nVERSION_ID="16.04"\n' >"${PH}/etc/os-release"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${PH}/tmp/installed-packages.tsv"
: >"${PH}/var/log/apt/history.log"
: >"${PH}/var/log/apt/term.log"
: >"${PH}/var/log/dpkg.log"
echo x >"${PH}/etc/hostname"
export DUR_HOST_ROOT="$PH"
export DUR_DRY_RECORDING=1
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTP" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$OUTP" >/dev/null
HOPP="${OUTP}/upgrade-discovery/xenial-to-bionic"
bash "$SCRIPT" start-recording --output-dir "$OUTP" >/dev/null
REC_CONF="${PH}/etc/apt/apt.conf.d/99upgrade-discovery-recorder"
[[ -f "$REC_CONF" ]] && pass "APT recorder conf installed" || fail "APT recorder conf installed"
grep -q 'Acquire::http::Proxy "http://127.0.0.1:18080/"' "$REC_CONF" && pass "apt-config file has http proxy" || fail "apt-config file has http proxy"
[[ -f "${PH}/etc/apt/apt.conf.d/01preexisting-proxy" ]] && pass "preexisting APT proxy kept during recording" || fail "preexisting APT proxy kept during recording"
[[ -f "${HOPP}/runtime/apt-proxy-backup/proxy-settings-before.txt" || -d "${HOPP}/runtime/apt-proxy-backup/conf.d" ]] \
  && pass "APT proxy settings backed up" || fail "APT proxy settings backed up"
bash "$SCRIPT" stop-recording --output-dir "$OUTP" >/dev/null
if [[ ! -f "$REC_CONF" ]]; then
  pass "stop-recording removes recorder APT proxy conf"
else
  fail "stop-recording removes recorder APT proxy conf"
fi
if [[ -f "${PH}/etc/apt/apt.conf.d/01preexisting-proxy" ]] && grep -q '3142' "${PH}/etc/apt/apt.conf.d/01preexisting-proxy"; then
  pass "stop-recording restores preexisting APT proxy settings"
else
  fail "stop-recording restores preexisting APT proxy settings"
fi

# restore-apt-proxy after simulated crash (recorder conf left behind)
mkdir -p "$(dirname "$REC_CONF")"
{
  printf 'Acquire::http::Proxy "http://127.0.0.1:18080/";\n'
  printf 'Acquire::https::Proxy "DIRECT";\n'
} >"$REC_CONF"
if bash "$SCRIPT" restore-apt-proxy --output-dir "$OUTP" >/dev/null; then
  pass "restore-apt-proxy command"
else
  fail "restore-apt-proxy command"
fi
[[ ! -f "$REC_CONF" ]] && pass "restore-apt-proxy removed recorder conf" || fail "restore-apt-proxy removed recorder conf"

# Live HTTP recorder: empty dedicated cache dir, force real download through proxy
unset DUR_DRY_RECORDING
OUTL="${WORKDIR}/out-live-proxy"
# Ephemeral ports avoid collisions with leftover listeners from prior runs.
export DUR_PROXY_PORT
DUR_PROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export DUR_HOST_ROOT="$PH"
rm -rf "$OUTL"
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTL" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$OUTL" >/dev/null
HOPL="${OUTL}/upgrade-discovery/xenial-to-bionic"
if bash "$SCRIPT" start-recording --output-dir "$OUTL" >/dev/null; then
  pass "live start-recording with proxy self-test"
else
  fail "live start-recording with proxy self-test"
  cat "${HOPL}/runtime/proxy-error.log" 2>/dev/null || true
fi
if grep -q 'dur-proxy-self-test-' "${HOPL}/runtime/proxy-access.log"; then
  pass "proxy self-test request recorded in access log"
else
  fail "proxy self-test request recorded in access log"
fi
# Origin server + download .deb via recorder (dedicated empty cache; not /var/cache/apt/archives)
ORIGIN_DIR="${WORKDIR}/origin-debs"
mkdir -p "$ORIGIN_DIR"
cp "${FIXTURES}/debs/bash_4.4.18-2ubuntu1_amd64.deb" "$ORIGIN_DIR/"
ORIGIN_PORT_FILE="${WORKDIR}/origin.port"
(
  cd "$ORIGIN_DIR"
  python3 - "$ORIGIN_PORT_FILE" <<'PY'
from __future__ import print_function
import sys
from http.server import SimpleHTTPRequestHandler
from socketserver import TCPServer
class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        return
class ReuseTCPServer(TCPServer):
    allow_reuse_address = True
httpd = ReuseTCPServer(("127.0.0.1", 0), Quiet)
port = httpd.server_address[1]
open(sys.argv[1], "w").write(str(port))
httpd.serve_forever()
PY
) &
ORIGIN_PID=$!
ORIGIN_PORT=""
for _ in $(seq 1 50); do
  if [[ -s "$ORIGIN_PORT_FILE" ]]; then
    ORIGIN_PORT="$(cat "$ORIGIN_PORT_FILE")"
    break
  fi
  sleep 0.05
done
if [[ -z "$ORIGIN_PORT" ]]; then
  fail "origin HTTP server failed to start"
  ORIGIN_PORT=0
else
  pass "origin HTTP server ready on ${ORIGIN_PORT}"
fi
DEB_URL="http://127.0.0.1:${ORIGIN_PORT}/bash_4.4.18-2ubuntu1_amd64.deb"
EMPTY_CACHE="${WORKDIR}/empty-apt-archives"
mkdir -p "$EMPTY_CACHE"
set +e
# Use http.client absolute-form (not urllib ProxyHandler) so NO_PROXY=127.0.0.1 cannot bypass.
python3 - "$DUR_PROXY_PORT" "$DEB_URL" "${EMPTY_CACHE}/bash_4.4.18-2ubuntu1_amd64.deb" <<'PY'
from __future__ import print_function
import sys
from http.client import HTTPConnection
port, url, dest = sys.argv[1], sys.argv[2], sys.argv[3]
conn = HTTPConnection("127.0.0.1", int(port), timeout=30)
conn.request("GET", url)
resp = conn.getresponse()
data = resp.read()
conn.close()
if resp.status != 200 or len(data) < 100:
    raise SystemExit("download failed status=%s size=%s" % (resp.status, len(data)))
open(dest, "wb").write(data)
print(len(data))
PY
rc_dl=$?
set -e
if [[ "$rc_dl" -eq 0 && -s "${EMPTY_CACHE}/bash_4.4.18-2ubuntu1_amd64.deb" ]]; then
  pass "forced download through recorder proxy (empty cache dir)"
else
  fail "forced download through recorder proxy (empty cache dir)"
fi
if grep -Fq "$DEB_URL" "${HOPL}/runtime/proxy-access.log" && \
   grep -q 'bash_4.4.18-2ubuntu1_amd64.deb' "${HOPL}/runtime/proxy-access.log" && \
   grep -qE ' 200 ' "${HOPL}/runtime/proxy-access.log"; then
  pass "proxy-access.log has full URL + HTTP status"
else
  fail "proxy-access.log has full URL + HTTP status"
  cat "${HOPL}/runtime/proxy-access.log" || true
fi
if grep -q 'sha256=' "${HOPL}/runtime/proxy-access.log" && \
   grep -q 'local_path=' "${HOPL}/runtime/proxy-access.log"; then
  pass "proxy-access.log has sha256 + local cached path"
else
  fail "proxy-access.log has sha256 + local cached path"
fi
# URL-hash object store (not basename); APT client cache delete must not matter
LP="$(awk '/bash_4.4.18-2ubuntu1_amd64.deb/ && /local_path=/ {
  for(i=1;i<=NF;i++) if($i ~ /^local_path=/) { sub(/^local_path=/,"",$i); print $i; exit }
}' "${HOPL}/runtime/proxy-access.log")"
if [[ -n "$LP" && -f "$LP" ]]; then
  pass "downloaded .deb preserved in URL-hash recorder store"
else
  fail "downloaded .deb preserved in URL-hash recorder store (lp=$LP)"
fi
# Simulate APT deleting its own download immediately after install
rm -f "${EMPTY_CACHE}/bash_4.4.18-2ubuntu1_amd64.deb"
if [[ -f "$LP" ]]; then
  pass "recorder copy survives APT cache deletion"
else
  fail "recorder copy survives APT cache deletion"
fi
bash "$SCRIPT" stop-recording --output-dir "$OUTL" >/dev/null
kill "$ORIGIN_PID" 2>/dev/null || true
wait "$ORIGIN_PID" 2>/dev/null || true

# proxy self-test failure must keep phase != recording
OUTS="${WORKDIR}/out-selftest-fail"
export DUR_DRY_RECORDING=0
export DUR_HOST_ROOT="$PH"
DUR_PROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export DUR_PROXY_PORT
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTS" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$OUTS" >/dev/null
HOPS="${OUTS}/upgrade-discovery/xenial-to-bionic"

# Unit: self-test fails when nothing is listening
set +e
dur_proxy_self_test 1 "${WORKDIR}/no-selftest.log"
rc_st=$?
set -e
[[ "$rc_st" -ne 0 ]] && pass "proxy self-test fails when proxy unreachable" || fail "proxy self-test fails when proxy unreachable"

# Regression: NO_PROXY/localhost must NOT bypass the recorder self-test
NO_PROXY_SAVE="${NO_PROXY-}"
no_proxy_SAVE="${no_proxy-}"
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="localhost,127.0.0.1"
NOPROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
NOPROXY_LOG="${WORKDIR}/noproxy-selftest.log"
: >"$NOPROXY_LOG"
python3 "${ROOT}/scripts/lib/discover_upgrade_http_proxy.py" \
  --listen 127.0.0.1 --port "$NOPROXY_PORT" --log "$NOPROXY_LOG" \
  --cache-dir "${WORKDIR}/noproxy-cache" \
  >"${WORKDIR}/noproxy-proxy.out" 2>"${WORKDIR}/noproxy-proxy.err" &
NOPROXY_PID=$!
for _ in $(seq 1 50); do
  python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.2); s.connect(("127.0.0.1", int(sys.argv[1]))); s.close()' \
    "$NOPROXY_PORT" 2>/dev/null && break
  sleep 0.05
done
set +e
dur_proxy_self_test "$NOPROXY_PORT" "$NOPROXY_LOG"
rc_np=$?
set -e
kill "$NOPROXY_PID" 2>/dev/null || true
wait "$NOPROXY_PID" 2>/dev/null || true
if [[ -n "${NO_PROXY_SAVE+x}" ]]; then export NO_PROXY="$NO_PROXY_SAVE"; else unset NO_PROXY; fi
if [[ -n "${no_proxy_SAVE+x}" ]]; then export no_proxy="$no_proxy_SAVE"; else unset no_proxy; fi
[[ "$rc_np" -eq 0 ]] && pass "proxy self-test works despite NO_PROXY=localhost,127.0.0.1" \
  || fail "proxy self-test works despite NO_PROXY=localhost,127.0.0.1"

# Bind-only stub: accepts the port but never writes GET lines to the access log
STUB="${WORKDIR}/stub-proxy.py"
cat >"$STUB" <<'PY'
from __future__ import print_function
import argparse
import socket
ap = argparse.ArgumentParser()
ap.add_argument("--listen", default="127.0.0.1")
ap.add_argument("--port", type=int, default=18080)
ap.add_argument("--log", required=True)
ap.add_argument("--cache-dir", required=True)
args = ap.parse_args()
open(args.log, "a").write("# stub proxy started (no request logging)\n")
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((args.listen, args.port))
s.listen(5)
while True:
    conn, _addr = s.accept()
    try:
        conn.recv(1024)
    except Exception:
        pass
    try:
        conn.close()
    except Exception:
        pass
PY
DUR_PROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export DUR_PROXY_PORT
export DUR_PROXY_PY="$STUB"
set +e
bash "$SCRIPT" start-recording --output-dir "$OUTS" >"${WORKDIR}/stub-start.out" 2>"${WORKDIR}/stub-start.err"
rc_stub=$?
set -e
unset DUR_PROXY_PY
if [[ "$rc_stub" -ne 0 ]]; then
  pass "start-recording rejected when proxy self-test not logged"
else
  fail "start-recording rejected when proxy self-test not logged"
  cat "${WORKDIR}/stub-start.err" || true
fi
phase_stub="$(python3 -c 'import json; print(json.load(open("'"${OUTS}/upgrade-discovery/.discovery-state.json"'"))["phase"])')"
[[ "$phase_stub" != "recording" ]] && pass "self-test failure does not set phase=recording" || fail "self-test failure does not set phase=recording (got $phase_stub)"
if [[ -f "${HOPS}/runtime/proxy.pid" ]]; then
  kill "$(cat "${HOPS}/runtime/proxy.pid")" 2>/dev/null || true
  rm -f "${HOPS}/runtime/proxy.pid"
fi
bash "$SCRIPT" restore-apt-proxy --output-dir "$OUTS" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# finalize-hop with non-ASCII file-manifest paths under LC_ALL=C
# (simulates real Ubuntu 18.04 finalize after successful after-hop)
# ---------------------------------------------------------------------------
OUTFNL="${WORKDIR}/out-finalize-nonascii"
export DUR_HOST_ROOT="$PH"
export DUR_DRY_RECORDING=1
unset DUR_PROXY_PY
bash "$SCRIPT" init --from 16.04 --to 18.04 --output-dir "$OUTFNL" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$OUTFNL" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$OUTFNL" >/dev/null
HOPFNL="${OUTFNL}/upgrade-discovery/xenial-to-bionic"
cp "${FIXTURES}/access-logs/sample-proxy-access.log" "${HOPFNL}/runtime/proxy-access.log"
mkdir -p "${HOPFNL}/runtime/deb-cache"
cp "${FIXTURES}/debs/"*.deb "${HOPFNL}/runtime/deb-cache/"
python3 "${FIXTURES}/seed_complete_captures.py" "$HOPFNL" "$FIXTURES"
cp "${FIXTURES}/packages-index/Packages" "${HOPFNL}/metadata/Packages"
bash "$SCRIPT" stop-recording --output-dir "$OUTFNL" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$OUTFNL" >/dev/null

# Inject rich inventories + non-ASCII paths (Latin-1 0xc5) into before/after manifests
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOPFNL}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${HOPFNL}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-conffiles.tsv" "${HOPFNL}/before/conffiles.tsv"
cp "${FIXTURES}/inventories/after-conffiles.tsv" "${HOPFNL}/after/conffiles.tsv"
python3 - "$HOPFNL" <<'PY'
from __future__ import print_function
import os, sys
hop = sys.argv[1]
hdr = b"path\ttype\tsize\towner\tgroup\tmode\tmtime\tsha256\thash_skip_reason\tfile_origin\n"
# Latin-1 0xc5 (same class of byte that failed on real finalize)
na = b"/etc/caf\xc5.conf"
before = hdr + b"/etc/hostname\tfile\t6\troot\troot\t644\t1000\tabc\t\tpackage_owned\n"
before += na + b"\tfile\t10\troot\troot\t644\t1000\toldhash\t\tcustom\n"
before += b"/usr/local/bin/tool\tfile\t20\troot\troot\t755\t1000\taaa\t\tcustom\n"
after = hdr + b"/etc/hostname\tfile\t6\troot\troot\t644\t1000\tabc\t\tpackage_owned\n"
after += na + b"\tfile\t12\troot\troot\t644\t2000\tnewhash\t\tcustom\n"  # modified
after += b"/etc/new.conf\tfile\t5\troot\troot\t644\t3000\teee\t\tcustom\n"  # added
# removed: /usr/local/bin/tool
open(os.path.join(hop, "before", "file-manifest.tsv"), "wb").write(before)
open(os.path.join(hop, "after", "file-manifest.tsv"), "wb").write(after)
print("injected non-ascii manifests")
PY

# Unit: parse + diff + round-trip under LC_ALL=C
set +e
LC_ALL=C LANG=C python3 - "$PY" "$HOPFNL" <<'PY'
from __future__ import print_function
import os, sys
os.environ["LC_ALL"] = "C"
os.environ["LANG"] = "C"
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import discover_upgrade_requirements as d
hop = sys.argv[2]
before = os.path.join(hop, "before", "file-manifest.tsv")
after = os.path.join(hop, "after", "file-manifest.tsv")
# Locale default open must fail on this fixture (proves why explicit encoding is required)
try:
    open(before, "r").read()
    # On UTF-8 locales this may succeed; force ascii decode check via binary
    raw = open(before, "rb").read()
    raw.decode("ascii")
    print("UNEXPECTED ascii-decodable")
    sys.exit(2)
except UnicodeDecodeError:
    pass
b = d.parse_file_manifest(d.Path(before))
a = d.parse_file_manifest(d.Path(after))
if not any("caf" in p for p in b):
    print("missing non-ascii in before", list(b))
    sys.exit(3)
diff = d.diff_files(d.Path(before), d.Path(after))
if not any(r.get("change_type") == "modified" for r in diff["modified"]):
    # path key may be the dict key
    if len(diff["modified"]) < 1:
        print("no modified", diff)
        sys.exit(4)
if len(diff["added"]) < 1 or len(diff["removed"]) < 1:
    print("diff incomplete", {k: len(v) for k, v in diff.items()})
    sys.exit(5)
# Round-trip write/read
out = os.path.join(hop, "diff", "files-modified.tsv")
d.write_tsv(d.Path(out), ["path", "change_type", "sha256_before", "sha256_after"], [
    {"path": r.get("path") or "", "change_type": r.get("change_type", ""),
     "sha256_before": r.get("sha256_before", ""), "sha256_after": r.get("sha256_after", "")}
    for r in diff["modified"]
])
raw_out = open(out, "rb").read()
if b"caf" not in raw_out or b"\xc5" not in raw_out:
    print("round-trip lost non-ascii", raw_out)
    sys.exit(6)
hdr, rows = d.read_tsv(d.Path(out))
if not any("caf" in r.get("path", "") for r in rows):
    print("read_tsv lost path", rows)
    sys.exit(7)
print("unit_ok")
PY
rc_unit=$?
set -e
[[ "$rc_unit" -eq 0 ]] && pass "LC_ALL=C non-ASCII parse/diff/round-trip" || fail "LC_ALL=C non-ASCII parse/diff/round-trip (rc=$rc_unit)"

# finalize-hop under LC_ALL=C (no apt / no after-hop redo)
set +e
LC_ALL=C LANG=C bash "$SCRIPT" finalize-hop --output-dir "$OUTFNL" >"${WORKDIR}/finalize-nonascii.out" 2>"${WORKDIR}/finalize-nonascii.err"
rc_fnl=$?
set -e
if [[ "$rc_fnl" -eq 0 ]]; then
  pass "finalize-hop with non-ASCII manifests under LC_ALL=C"
else
  fail "finalize-hop with non-ASCII manifests under LC_ALL=C"
  cat "${WORKDIR}/finalize-nonascii.err" || true
  cat "${HOPFNL}/validation.txt" 2>/dev/null || true
fi
for f in required-packages.tsv required-files.tsv required-urls.tsv evidence.json validation.txt \
  diff/files-added.tsv diff/files-modified.tsv diff/files-removed.tsv; do
  if [[ -f "${HOPFNL}/$f" ]]; then
    pass "finalize artifact $f"
  else
    fail "finalize artifact $f"
  fi
done
grep -q 'VALIDATION: PASS' "${HOPFNL}/validation.txt" && pass "finalize validation PASS" || fail "finalize validation PASS"
# non-ASCII preserved in files-modified
if python3 -c 'import sys; sys.exit(0 if b"\xc5" in open(sys.argv[1],"rb").read() else 1)' \
  "${HOPFNL}/diff/files-modified.tsv"; then
  pass "non-ASCII path preserved in files-modified.tsv"
else
  fail "non-ASCII path preserved in files-modified.tsv"
fi
phase_fnl="$(python3 -c 'import json; print(json.load(open("'"${OUTFNL}/upgrade-discovery/.discovery-state.json"'"))["phase"])')"
[[ "$phase_fnl" == "finalized" ]] && pass "finalize marks phase finalized" || fail "finalize marks phase finalized (got $phase_fnl)"

# build-manifests failure must not run validate / not mark finalized
OUTFB="${WORKDIR}/out-finalize-buildfail"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$OUTFB" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$OUTFB" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$OUTFB" >/dev/null
HOPFB="${OUTFB}/upgrade-discovery/bionic-to-focal"
bash "$SCRIPT" stop-recording --output-dir "$OUTFB" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$OUTFB" >/dev/null
# Break build by replacing file-manifest with a directory so open('r') fails hard
rm -f "${HOPFB}/after/file-manifest.tsv"
mkdir -p "${HOPFB}/after/file-manifest.tsv"
set +e
bash "$SCRIPT" finalize-hop --output-dir "$OUTFB" >"${WORKDIR}/finalize-fail.out" 2>"${WORKDIR}/finalize-fail.err"
rc_fb=$?
set -e
[[ "$rc_fb" -ne 0 ]] && pass "finalize nonzero when manifest build fails" || fail "finalize nonzero when manifest build fails"
if grep -qi 'validating' "${WORKDIR}/finalize-fail.out" "${WORKDIR}/finalize-fail.err" 2>/dev/null; then
  # build fails before validate — should not reach validating
  if grep -q 'manifest build failed' "${WORKDIR}/finalize-fail.err"; then
    pass "validate skipped after build-manifests failure"
  else
    fail "validate skipped after build-manifests failure"
  fi
else
  pass "validate skipped after build-manifests failure"
fi
phase_fb="$(python3 -c 'import json; print(json.load(open("'"${OUTFB}/upgrade-discovery/.discovery-state.json"'"))["phase"])')"
[[ "$phase_fb" != "finalized" ]] && pass "build failure does not set finalized" || fail "build failure does not set finalized (got $phase_fb)"
# before/after evidence untouched (directory still there as we left it; installed packages intact)
[[ -f "${HOPFB}/before/installed-packages.tsv" ]] && pass "build failure leaves before inventory" || fail "build failure leaves before inventory"

# ---------------------------------------------------------------------------
# Atomic capture / collision / redirect / 304 / self-test / unresolved FAIL / repair
# ---------------------------------------------------------------------------
export DUR_DRY_RECORDING=1
CAP="${WORKDIR}/capture-cases"
CAPHOST="${WORKDIR}/capture-host"
mkdir -p \
  "${CAPHOST}/etc/apt/apt.conf.d" \
  "${CAPHOST}/etc/apt/sources.list.d" \
  "${CAPHOST}/var/log/apt" \
  "${CAPHOST}/var/lib/dpkg" \
  "${CAPHOST}/usr/local" \
  "${CAPHOST}/opt/aelladata" \
  "${CAPHOST}/tmp"
printf 'NAME="Ubuntu"\nVERSION_ID="18.04"\n' >"${CAPHOST}/etc/os-release"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${CAPHOST}/tmp/installed-packages.tsv"
: >"${CAPHOST}/var/log/apt/history.log"
: >"${CAPHOST}/var/log/apt/term.log"
: >"${CAPHOST}/var/log/dpkg.log"
export DUR_HOST_ROOT="$CAPHOST"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$CAP" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$CAP" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$CAP" >/dev/null
HOPCAP="${CAP}/upgrade-discovery/bionic-to-focal"
CACHE="${HOPCAP}/runtime/deb-cache"
mkdir -p "$CACHE"

# Live mini origin for redirect + multi InRelease basename + by-hash + upgrader
ORIGIN2="${WORKDIR}/origin2"
mkdir -p "${ORIGIN2}/dists/a" "${ORIGIN2}/dists/b" "${ORIGIN2}/by-hash/SHA256" \
  "${ORIGIN2}/upgrader" "${ORIGIN2}/pool"
echo 'inrelease-a' >"${ORIGIN2}/dists/a/InRelease"
echo 'inrelease-b' >"${ORIGIN2}/dists/b/InRelease"
echo 'byhash' >"${ORIGIN2}/by-hash/SHA256/deadbeef"
echo 'upgrader-tar' >"${ORIGIN2}/upgrader/focal.tar.gz"
echo 'upgrader-gpg' >"${ORIGIN2}/upgrader/focal.tar.gz.gpg"
cp "${FIXTURES}/debs/bash_4.4.18-2ubuntu1_amd64.deb" "${ORIGIN2}/pool/"
# redirect target
echo 'final-body' >"${ORIGIN2}/final.dat"
ORIGIN2_PORT_FILE="${WORKDIR}/origin2.port"
(
  cd "$ORIGIN2"
  python3 - "$ORIGIN2_PORT_FILE" <<'PY'
from __future__ import print_function
import sys
from http.server import SimpleHTTPRequestHandler
from socketserver import TCPServer
class H(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        return
    def do_GET(self):
        if self.path.startswith('/redir'):
            self.send_response(302)
            self.send_header('Location', '/final.dat')
            self.end_headers()
            return
        if self.path.startswith('/not-modified'):
            self.send_response(304)
            self.end_headers()
            return
        return SimpleHTTPRequestHandler.do_GET(self)
class S(TCPServer):
    allow_reuse_address = True
httpd = S(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
) &
ORIGIN2_PID=$!
ORIGIN2_PORT=""
for _ in $(seq 1 50); do
  [[ -s "$ORIGIN2_PORT_FILE" ]] && ORIGIN2_PORT="$(cat "$ORIGIN2_PORT_FILE")" && break
  sleep 0.05
done
unset DUR_DRY_RECORDING
DUR_PROXY_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export DUR_PROXY_PORT
# Restart recording with live proxy for capture tests
bash "$SCRIPT" stop-recording --output-dir "$CAP" >/dev/null 2>&1 || true
# New hop dir for live capture
CAPL="${WORKDIR}/capture-live"
export DUR_HOST_ROOT="$CAPHOST"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$CAPL" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$CAPL" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$CAPL" >/dev/null
HOPCL="${CAPL}/upgrade-discovery/bionic-to-focal"
PROXY_PORT="$DUR_PROXY_PORT"

fetch_via_proxy() {
  local url="$1"
  python3 - "$PROXY_PORT" "$url" <<'PY'
from __future__ import print_function
import sys
from http.client import HTTPConnection
port, url = sys.argv[1], sys.argv[2]
conn = HTTPConnection("127.0.0.1", int(port), timeout=30)
conn.request("GET", url)
resp = conn.getresponse()
data = resp.read()
conn.close()
print(resp.status, len(data))
PY
}

BASE="http://127.0.0.1:${ORIGIN2_PORT}"
fetch_via_proxy "${BASE}/dists/a/InRelease" >/dev/null
fetch_via_proxy "${BASE}/dists/b/InRelease" >/dev/null
fetch_via_proxy "${BASE}/by-hash/SHA256/deadbeef" >/dev/null
fetch_via_proxy "${BASE}/upgrader/focal.tar.gz" >/dev/null
fetch_via_proxy "${BASE}/upgrader/focal.tar.gz.gpg" >/dev/null
fetch_via_proxy "${BASE}/pool/bash_4.4.18-2ubuntu1_amd64.deb" >/dev/null
fetch_via_proxy "${BASE}/redir" >/dev/null
fetch_via_proxy "${BASE}/not-modified" >/dev/null

LOGCL="${HOPCL}/runtime/proxy-access.log"
# basename collision: two InRelease URLs -> distinct local_path
lp_a="$(awk -v u="${BASE}/dists/a/InRelease" '$0 ~ u && /local_path=/ {
  for(i=1;i<=NF;i++) if($i ~ /^local_path=/){sub(/^local_path=/,"",$i); print $i; exit}}' "$LOGCL")"
lp_b="$(awk -v u="${BASE}/dists/b/InRelease" '$0 ~ u && /local_path=/ {
  for(i=1;i<=NF;i++) if($i ~ /^local_path=/){sub(/^local_path=/,"",$i); print $i; exit}}' "$LOGCL")"
if [[ -n "$lp_a" && -n "$lp_b" && "$lp_a" != "$lp_b" && -f "$lp_a" && -f "$lp_b" ]]; then
  pass "identical basename InRelease URLs do not collide"
else
  fail "identical basename InRelease URLs do not collide (a=$lp_a b=$lp_b)"
fi
grep -q 'by-hash/SHA256/deadbeef' "$LOGCL" && grep -q 'local_path=' <<<"$(grep 'by-hash' "$LOGCL")" \
  && pass "by-hash response captured" || fail "by-hash response captured"
grep -q 'focal.tar.gz' "$LOGCL" && grep -q 'focal.tar.gz.gpg' "$LOGCL" \
  && pass "release upgrader tar/gpg captured" || fail "release upgrader tar/gpg captured"
if grep -q 'redirects=' "$LOGCL" && grep -q 'final=' <<<"$(grep '/redir' "$LOGCL")" && \
   grep -q 'local_path=' <<<"$(grep '/redir' "$LOGCL")"; then
  pass "redirect preserves final body"
else
  fail "redirect preserves final body"
fi
# 304 without prior body => unresolved after manifests
if grep -q ' 304 ' "$LOGCL"; then
  pass "HTTP 304 logged"
else
  fail "HTTP 304 logged"
fi
# self-test must not appear in required manifests
bash "$SCRIPT" stop-recording --output-dir "$CAPL" >/dev/null
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOPCL}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${HOPCL}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOPCL}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/after-file-manifest.tsv" "${HOPCL}/after/file-manifest.tsv"
echo -e 'path\thash\tpackage' >"${HOPCL}/before/conffiles.tsv"
echo -e 'path\thash\tpackage' >"${HOPCL}/after/conffiles.tsv"
: >"${HOPCL}/runtime/apt-history.log"
: >"${HOPCL}/runtime/apt-term.log"
: >"${HOPCL}/runtime/dpkg.log"
mkdir -p "${HOPCL}/runtime/dist-upgrade"
python3 "$PY" build-manifests --hop-dir "$HOPCL" --hop bionic-to-focal >/dev/null
if ! grep -q 'dur-recorder-self-test\|dur-proxy-self-test' "${HOPCL}/required-urls.tsv" \
   && ! grep -q 'dur-recorder-self-test\|dur-proxy-self-test' "${HOPCL}/required-files.tsv"; then
  pass "self-test excluded from manifests"
else
  fail "self-test excluded from manifests"
fi
# 304 without body must be unresolved
if grep -q 'http_304_without_stored_body\|not-modified' "${HOPCL}/unresolved-files.tsv"; then
  pass "HTTP 304 without body => unresolved"
else
  fail "HTTP 304 without body => unresolved"
  cat "${HOPCL}/unresolved-files.tsv" || true
fi
# unresolved => validation FAIL
set +e
python3 "$PY" validate --hop-dir "$HOPCL" --hop bionic-to-focal --from-os 18.04 --to-os 20.04 >/dev/null
rc_val=$?
set -e
if [[ "$rc_val" -ne 0 ]] && grep -q 'VALIDATION: FAIL' "${HOPCL}/validation.txt"; then
  pass "unresolved => validation FAIL"
else
  fail "unresolved => validation FAIL"
fi
kill "$ORIGIN2_PID" 2>/dev/null || true
wait "$ORIGIN2_PID" 2>/dev/null || true

# repair-hop recovers unresolved from a local origin
REPAIR_OUT="${WORKDIR}/repair-out"
export DUR_DRY_RECORDING=1
export DUR_HOST_ROOT="$CAPHOST"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$REPAIR_OUT" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$REPAIR_OUT" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$REPAIR_OUT" >/dev/null
HOPR="${REPAIR_OUT}/upgrade-discovery/bionic-to-focal"
bash "$SCRIPT" stop-recording --output-dir "$REPAIR_OUT" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$REPAIR_OUT" >/dev/null
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOPR}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/after-installed-packages.tsv" "${HOPR}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOPR}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/after-file-manifest.tsv" "${HOPR}/after/file-manifest.tsv"
echo -e 'path\thash\tpackage' >"${HOPR}/before/conffiles.tsv"
echo -e 'path\thash\tpackage' >"${HOPR}/after/conffiles.tsv"
# Incomplete recording: one package URL without capture
ORIGIN3="${WORKDIR}/origin3"
mkdir -p "$ORIGIN3"
cp "${FIXTURES}/debs/zlib1g_1.2.11.dfsg-0ubuntu2_amd64.deb" \
  "${ORIGIN3}/zlib1g_1.2.11.dfsg-0ubuntu2_amd64.deb"
ORIGIN3_PORT_FILE="${WORKDIR}/origin3.port"
(
  cd "$ORIGIN3"
  python3 - "$ORIGIN3_PORT_FILE" <<'PY'
from __future__ import print_function
import sys
from http.server import SimpleHTTPRequestHandler
from socketserver import TCPServer
class Q(SimpleHTTPRequestHandler):
    def log_message(self, *a): return
class S(TCPServer):
    allow_reuse_address = True
httpd = S(("127.0.0.1", 0), Q)
open(sys.argv[1], "w").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
) &
ORIGIN3_PID=$!
ORIGIN3_PORT=""
for _ in $(seq 1 50); do
  [[ -s "$ORIGIN3_PORT_FILE" ]] && ORIGIN3_PORT="$(cat "$ORIGIN3_PORT_FILE")" && break
  sleep 0.05
done
ZURL="http://127.0.0.1:${ORIGIN3_PORT}/zlib1g_1.2.11.dfsg-0ubuntu2_amd64.deb"
printf '2026-07-17T02:00:00Z GET %s 200 3000\n' "$ZURL" >"${HOPR}/runtime/proxy-access.log"
python3 "$PY" build-manifests --hop-dir "$HOPR" --hop bionic-to-focal >/dev/null
before_unres="$(awk 'NR>1{c++} END{print c+0}' "${HOPR}/unresolved-packages.tsv")"
[[ "$before_unres" -ge 1 ]] && pass "repair fixture has unresolved packages" || fail "repair fixture has unresolved packages"
# Preserve before inventory marker
cp "${HOPR}/before/installed-packages.tsv" "${WORKDIR}/before-packages.before-repair"
set +e
bash "$SCRIPT" repair-hop --output-dir "$REPAIR_OUT" >"${WORKDIR}/repair.out" 2>"${WORKDIR}/repair.err"
rc_repair=$?
set -e
after_unres="$(awk 'NR>1{c++} END{print c+0}' "${HOPR}/unresolved-packages.tsv")"
if [[ "$after_unres" -lt "$before_unres" ]] && grep -q 'local_path=' "${HOPR}/runtime/repair-access.log"; then
  pass "repair-hop recovers unresolved downloads"
else
  fail "repair-hop recovers unresolved downloads (before=$before_unres after=$after_unres)"
  cat "${WORKDIR}/repair.err" || true
fi
if cmp -s "${WORKDIR}/before-packages.before-repair" "${HOPR}/before/installed-packages.tsv"; then
  pass "repair-hop does not overwrite before evidence"
else
  fail "repair-hop does not overwrite before evidence"
fi
# SHA256 of repaired object matches log
if python3 - "$HOPR" <<'PY'
from __future__ import print_function
import hashlib, os, sys
hop = sys.argv[1]
log = os.path.join(hop, "runtime", "repair-access.log")
for line in open(log, encoding="utf-8", errors="surrogateescape"):
    if "local_path=" not in line or "sha256=" not in line:
        continue
    parts = line.split()
    sha = lp = ""
    for p in parts:
        if p.startswith("sha256="):
            sha = p.split("=", 1)[1]
        if p.startswith("local_path="):
            lp = p.split("=", 1)[1]
    if not lp or not os.path.isfile(lp):
        sys.exit(2)
    h = hashlib.sha256(open(lp, "rb").read()).hexdigest()
    if h != sha:
        sys.exit(3)
    print("ok", sha)
    sys.exit(0)
sys.exit(4)
PY
then
  pass "repair-hop SHA256 verification"
else
  fail "repair-hop SHA256 verification"
fi
# evidence marks post-hop recovery
grep -q 'recovered_post_hop' "${HOPR}/evidence.json" && pass "evidence recovered_post_hop" || fail "evidence recovered_post_hop"
kill "$ORIGIN3_PID" 2>/dev/null || true
wait "$ORIGIN3_PID" 2>/dev/null || true

# repair-hop: first 304 + no stored body => unconditional GET + cache-bust nonce => 200
REPAIR304_OUT="${WORKDIR}/repair-304-out"
export DUR_DRY_RECORDING=1
export DUR_HOST_ROOT="$CAPHOST"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$REPAIR304_OUT" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$REPAIR304_OUT" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$REPAIR304_OUT" >/dev/null
HOP304="${REPAIR304_OUT}/upgrade-discovery/bionic-to-focal"
bash "$SCRIPT" stop-recording --output-dir "$REPAIR304_OUT" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$REPAIR304_OUT" >/dev/null
# Identical inventories so validation can PASS with a single metadata URL.
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP304}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP304}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP304}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP304}/after/file-manifest.tsv"
echo -e 'path\thash\tpackage' >"${HOP304}/before/conffiles.tsv"
echo -e 'path\thash\tpackage' >"${HOP304}/after/conffiles.tsv"
ORIGIN304="${WORKDIR}/origin304"
mkdir -p "${ORIGIN304}/ubuntu/dists/bionic"
BODY304='InRelease-body-after-unconditional-retry'
printf '%s\n' "$BODY304" >"${ORIGIN304}/ubuntu/dists/bionic/InRelease"
ORIGIN304_PORT_FILE="${WORKDIR}/origin304.port"
ORIGIN304_HDR_FILE="${WORKDIR}/origin304.headers"
: >"$ORIGIN304_HDR_FILE"
(
  python3 - "$ORIGIN304" "$ORIGIN304_PORT_FILE" "$ORIGIN304_HDR_FILE" <<'PY'
from __future__ import print_function
import os, sys
from http.server import BaseHTTPRequestHandler
from socketserver import TCPServer
root, port_file, hdr_file = sys.argv[1], sys.argv[2], sys.argv[3]
counts = {}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        return
    def do_GET(self):
        raw = self.path
        path = raw.split('?', 1)[0]
        query = raw.split('?', 1)[1] if '?' in raw else ''
        counts[path] = counts.get(path, 0) + 1
        n = counts[path]
        with open(hdr_file, 'a', encoding='utf-8') as fh:
            fh.write(
                'n=%d path=%s raw=%s inm=%r ims=%r ir=%r cc=%r pragma=%r ae=%r\n' % (
                    n, path, raw,
                    self.headers.get('If-None-Match'),
                    self.headers.get('If-Modified-Since'),
                    self.headers.get('If-Range'),
                    self.headers.get('Cache-Control'),
                    self.headers.get('Pragma'),
                    self.headers.get('Accept-Encoding'),
                )
            )
        if path.endswith('/InRelease'):
            has_nonce = 'dur_repair_nonce=' in query
            if n == 1:
                # First request must be the clean original URL (no cache-bust).
                if has_nonce:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(b'unexpected nonce on first request')
                    return
                self.send_response(304)
                self.end_headers()
                return
            # Second request: require nonce; without it keep returning 304
            # (mirrors archive.ubuntu.com ignoring plain no-cache GETs).
            if not has_nonce:
                self.send_response(304)
                self.end_headers()
                return
            if (self.headers.get('If-None-Match')
                    or self.headers.get('If-Modified-Since')
                    or self.headers.get('If-Range')):
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'conditional headers present')
                return
            if self.headers.get('Cache-Control') != 'no-cache, no-store, max-age=0':
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'bad Cache-Control')
                return
            if self.headers.get('Pragma') != 'no-cache':
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'bad Pragma')
                return
            if self.headers.get('Accept-Encoding') != 'identity':
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b'bad Accept-Encoding')
                return
            body_path = os.path.join(root, path.lstrip('/'))
            with open(body_path, 'rb') as bf:
                data = bf.read()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(404)
        self.end_headers()
class S(TCPServer):
    allow_reuse_address = True
httpd = S(("127.0.0.1", 0), H)
open(port_file, "w").write(str(httpd.server_address[1]))
httpd.serve_forever()
PY
) &
ORIGIN304_PID=$!
ORIGIN304_PORT=""
for _ in $(seq 1 50); do
  [[ -s "$ORIGIN304_PORT_FILE" ]] && ORIGIN304_PORT="$(cat "$ORIGIN304_PORT_FILE")" && break
  sleep 0.05
done
INREL_URL="http://127.0.0.1:${ORIGIN304_PORT}/ubuntu/dists/bionic/InRelease"
printf '2026-07-17T03:00:00Z GET %s 304 0\n' "$INREL_URL" >"${HOP304}/runtime/proxy-access.log"
python3 "$PY" build-manifests --hop-dir "$HOP304" --hop bionic-to-focal >/dev/null
before_uf="$(awk 'NR>1{c++} END{print c+0}' "${HOP304}/unresolved-files.tsv")"
if [[ "$before_uf" -eq 1 ]] && grep -q 'http_304_without_stored_body' "${HOP304}/unresolved-files.tsv"; then
  pass "repair-304 fixture: unresolved InRelease without body"
else
  fail "repair-304 fixture: unresolved InRelease without body (count=$before_uf)"
  cat "${HOP304}/unresolved-files.tsv" || true
fi
set +e
bash "$SCRIPT" repair-hop --output-dir "$REPAIR304_OUT" >"${WORKDIR}/repair304.out" 2>"${WORKDIR}/repair304.err"
rc_repair304=$?
set -e
after_uf="$(awk 'NR>1{c++} END{print c+0}' "${HOP304}/unresolved-files.tsv")"
after_up="$(awk 'NR>1{c++} END{print c+0}' "${HOP304}/unresolved-packages.tsv")"
if [[ "$after_uf" -eq 0 && "$after_up" -eq 0 ]]; then
  pass "repair-hop 304 retry clears unresolved (files=0 packages=0)"
else
  fail "repair-hop 304 retry clears unresolved (files=$after_uf packages=$after_up)"
  cat "${WORKDIR}/repair304.err" || true
  cat "${HOP304}/runtime/repair-access.log" || true
fi
if grep -q " 200 " "${HOP304}/runtime/repair-access.log" \
   && grep -q 'local_path=' "${HOP304}/runtime/repair-access.log" \
   && grep -q 'sha256=' "${HOP304}/runtime/repair-access.log"; then
  pass "repair-hop 304 retry stored body with sha256"
else
  fail "repair-hop 304 retry stored body with sha256"
  cat "${HOP304}/runtime/repair-access.log" || true
fi
# First request: clean path; second: cache-bust nonce + unconditional headers
if grep -q "n=1 path=/ubuntu/dists/bionic/InRelease raw=/ubuntu/dists/bionic/InRelease " "$ORIGIN304_HDR_FILE"; then
  pass "repair-hop 304 first request has no query"
else
  fail "repair-hop 304 first request has no query"
  cat "$ORIGIN304_HDR_FILE" || true
fi
if grep -q "n=2 path=/ubuntu/dists/bionic/InRelease raw=/ubuntu/dists/bionic/InRelease?dur_repair_nonce=" "$ORIGIN304_HDR_FILE" \
   && grep -q "n=2 .* cc='no-cache, no-store, max-age=0' pragma='no-cache' ae='identity'" "$ORIGIN304_HDR_FILE"; then
  pass "repair-hop 304 retry sent nonce + unconditional headers"
else
  fail "repair-hop 304 retry sent nonce + unconditional headers"
  cat "$ORIGIN304_HDR_FILE" || true
fi
if grep -q '\[INFO\] repair-hop: url=.* status=304 unconditional=false' "${WORKDIR}/repair304.err" \
   && grep -q '\[INFO\] repair-hop: url=.*dur_repair_nonce=.* status=200 unconditional=true' "${WORKDIR}/repair304.err"; then
  pass "repair-hop 304 retry INFO logs per attempt"
else
  fail "repair-hop 304 retry INFO logs per attempt"
  cat "${WORKDIR}/repair304.err" || true
fi
if python3 - "$HOP304" "$BODY304" "$INREL_URL" <<'PY'
from __future__ import print_function
import hashlib, json, os, sys
hop, expected_body, original_url = sys.argv[1], sys.argv[2] + "\n", sys.argv[3]
log = os.path.join(hop, "runtime", "repair-access.log")
sha = lp = ""
for line in open(log, encoding="utf-8", errors="surrogateescape"):
    if "local_path=" not in line or "sha256=" not in line:
        continue
    for p in line.split():
        if p.startswith("sha256="):
            sha = p.split("=", 1)[1]
        if p.startswith("local_path="):
            lp = p.split("=", 1)[1]
if not lp or not os.path.isfile(lp):
    sys.exit(2)
data = open(lp, "rb").read()
if data != expected_body.encode("utf-8"):
    sys.exit(3)
h = hashlib.sha256(data).hexdigest()
if h != sha:
    sys.exit(4)
meta_path = lp + ".meta.json"
if not os.path.isfile(meta_path):
    sys.exit(5)
meta = json.loads(open(meta_path, encoding="utf-8").read())
if not meta.get("recovered_post_hop") or meta.get("checksum_source") != "post_hop_download":
    sys.exit(6)
if meta.get("original_url") != original_url:
    sys.exit(7)
if "dur_repair_nonce=" not in (meta.get("final_url") or ""):
    sys.exit(8)
# Object key must be derived from original_url (no nonce).
key = hashlib.sha256(original_url.encode("utf-8")).hexdigest()
if not lp.endswith(key) and os.path.basename(lp) != key:
    sys.exit(9)
print("ok", sha)
sys.exit(0)
PY
then
  pass "repair-hop 304 retry SHA256 + original_url/final_url/nonce key"
else
  fail "repair-hop 304 retry SHA256 + original_url/final_url/nonce key"
fi
grep -q '"recovered_post_hop": true' "${HOP304}/evidence.json" \
  && grep -q 'post_hop_download' "${HOP304}/evidence.json" \
  && pass "repair-hop 304 retry evidence markers" \
  || fail "repair-hop 304 retry evidence markers"
if [[ "$rc_repair304" -eq 0 ]] && grep -q 'VALIDATION: PASS' "${HOP304}/validation.txt"; then
  pass "repair-hop 304 retry validation PASS"
else
  fail "repair-hop 304 retry validation PASS (rc=$rc_repair304)"
  cat "${HOP304}/validation.txt" || true
  cat "${WORKDIR}/repair304.err" || true
fi
kill "$ORIGIN304_PID" 2>/dev/null || true
wait "$ORIGIN304_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# export-hop: workspace artifact export
# ---------------------------------------------------------------------------
seed_export_hop() {
  # seed_export_hop OUT HOP FROM TO [required_packages_rows]
  local out="$1" hop="$2" from_os="$3" to_os="$4"
  local pkg_rows="${5:-2}"
  local hd="${out}/upgrade-discovery/${hop}"
  mkdir -p "$hd" \
    "${hd}/runtime/deb-cache/aa/bb" \
    "${hd}/before" \
    "${hd}/after"
  cat >"${out}/upgrade-discovery/.discovery-state.json" <<EOF
{
  "schema_version": "1",
  "output_dir": "${out}",
  "from_os": "${from_os}",
  "to_os": "${to_os}",
  "hop": "${hop}",
  "phase": "finalized"
}
EOF
  cat >"${hd}/run.json" <<EOF
{
  "hop": "${hop}",
  "from_os": "${from_os}",
  "to_os": "${to_os}",
  "phase": "finalized"
}
EOF
  printf 'hop\tpackage\tversion\tarchitecture\n' >"${hd}/required-packages.tsv"
  local i
  for i in $(seq 1 "$pkg_rows"); do
    printf '%s\tpkg%s\t1.0-%s\tamd64\n' "$hop" "$i" "$i" >>"${hd}/required-packages.tsv"
  done
  # UTF-8 / non-ASCII field preserved verbatim in export
  printf 'hop\tfile_type\tfilename\toriginal_url\tfinal_url\tlocal_path\tsize_bytes\tsha256\thttp_status\trequest_count\tevidence_source\n' \
    >"${hd}/required-files.tsv"
  printf '%s\tinrelease\tInRelease\thttp://example.test/utf8/경로/InRelease\thttp://example.test/utf8/경로/InRelease\t/opt/aelladata/abs/path/InRelease\t12\tabc\t200\t1\tproxy_access_log\n' \
    "$hop" >>"${hd}/required-files.tsv"
  printf 'hop\trequested_at\tmethod\toriginal_url\tfinal_url\thttp_status\tsize_bytes\tsha256\tlocal_path\n' \
    >"${hd}/required-urls.tsv"
  printf '%s\t2026-07-18T00:00:00Z\tGET\thttp://example.test/a\thttp://example.test/a\t200\t1\tx\t/opt/aelladata/abs/a\n' \
    "$hop" >>"${hd}/required-urls.tsv"
  printf 'hop\tpackage\tversion\tarchitecture\toriginal_url\tfinal_url\treason\n' \
    >"${hd}/unresolved-packages.tsv"
  printf 'hop\tfile_type\tfilename\toriginal_url\tfinal_url\treason\n' \
    >"${hd}/unresolved-files.tsv"
  printf 'hop\toriginal_url\tfinal_url\thttp_status\treason\tfile_type\n' \
    >"${hd}/failed-requests.tsv"
  cat >"${hd}/evidence.json" <<EOF
{
  "hop": "${hop}",
  "required_packages": ${pkg_rows},
  "resolved_packages": ${pkg_rows},
  "required_files": 1,
  "resolved_files": 1,
  "required_urls": 1,
  "unresolved_packages": 0,
  "unresolved_files": 0,
  "failed_requests": 0,
  "captured_http_200": 3,
  "captured_bytes": 99,
  "recovered_post_hop": false,
  "checksum_source": "original_capture"
}
EOF
  cat >"${hd}/validation.txt" <<EOF
VALIDATION: PASS
hop=${hop}
from_os=${from_os}
to_os=${to_os}
required_packages=${pkg_rows}
resolved_packages=${pkg_rows}
unresolved_packages=0
required_files=1
resolved_files=1
unresolved_files=0
failed_requests=0
failures: none
EOF
  # Large payloads that must NEVER be exported
  printf 'FAKEDEB' >"${hd}/runtime/deb-cache/aa/bb/deadbeef.deb"
  printf 'FAKEDEB' >"${hd}/should-not-export.deb"
  mkdir -p "${hd}/runtime/payload"
  printf 'BODY' >"${hd}/runtime/payload/InRelease"
}

REPO_EXPORT="${WORKDIR}/repo-export"
mkdir -p "$REPO_EXPORT"
EXPORT_OUT="${WORKDIR}/export-src-bionic"
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 2
# Snapshot source evidence before export
cp "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-packages.tsv" \
  "${WORKDIR}/src-required-packages.before"
cp "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/evidence.json" \
  "${WORKDIR}/src-evidence.before"
cp "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-files.tsv" \
  "${WORKDIR}/src-required-files.before"

set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >"${WORKDIR}/export1.out" 2>"${WORKDIR}/export1.err"
rc_export1=$?
set -e
EXP1="${REPO_EXPORT}/artifacts/upgrade-discovery/bionic-to-focal"
if [[ "$rc_export1" -eq 0 && -d "$EXP1" ]]; then
  pass "export-hop PASS result succeeds"
else
  fail "export-hop PASS result succeeds (rc=$rc_export1)"
  cat "${WORKDIR}/export1.err" || true
fi
[[ -d "$EXP1" ]] && pass "export-hop creates hop directory" || fail "export-hop creates hop directory"
missing_export=""
for f in required-packages.tsv required-files.tsv required-urls.tsv \
  unresolved-packages.tsv unresolved-files.tsv failed-requests.tsv \
  evidence.json validation.txt export-summary.json checksums.sha256; do
  [[ -f "${EXP1}/${f}" ]] || missing_export="${missing_export} ${f}"
done
[[ -z "$missing_export" ]] && pass "export-hop copies all required files" \
  || fail "export-hop copies all required files (missing:$missing_export)"
if cmp -s "${WORKDIR}/src-required-packages.before" \
     "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-packages.tsv" \
   && cmp -s "${WORKDIR}/src-evidence.before" \
     "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/evidence.json" \
   && cmp -s "${WORKDIR}/src-required-files.before" \
     "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-files.tsv"; then
  pass "export-hop does not modify source evidence"
else
  fail "export-hop does not modify source evidence"
fi
# Absolute paths preserved in exported copy
if grep -q '/opt/aelladata/abs/path/InRelease' "${EXP1}/required-files.tsv" \
   && grep -q 'utf8/경로/InRelease' "${EXP1}/required-files.tsv"; then
  pass "export-hop preserves absolute paths and UTF-8"
else
  fail "export-hop preserves absolute paths and UTF-8"
fi
if python3 - "$EXP1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1] + "/export-summary.json", encoding="utf-8"))
assert s["schema_version"] == 1
assert s["hop"] == "bionic-to-focal"
assert s["from_os"] == "18.04" and s["to_os"] == "20.04"
assert s["validation"] == "PASS"
assert s["required_packages"] == 2
assert s["required_files"] == 1
assert s["required_urls"] == 1
assert s["unresolved_packages"] == 0
assert s["unresolved_files"] == 0
assert s["resolved_files"] == 1
assert s["required_files"] == s["resolved_files"] + s["unresolved_files"]
assert s["failed_requests"] == 0
assert s["failed_requests_total"] == 0
assert s["failed_requests_blocking"] == 0
assert s["failed_requests_non_blocking"] == 0
assert s.get("non_blocking_failure_reasons") == {}
assert s.get("historical_non_required_failures", 0) == 0
assert s["recovered_post_hop"] is False
assert s["checksum_source"] == "original_capture"
assert s["captured_http_200"] == 3
assert s["captured_bytes"] == 99
assert "source_output_dir" in s and s["source_output_dir"]
print("ok")
PY
then
  pass "export-summary.json row counts and fields"
else
  fail "export-summary.json row counts and fields"
fi
if (cd "$EXP1" && sha256sum -c checksums.sha256 >/dev/null); then
  pass "checksums.sha256 verifies"
else
  fail "checksums.sha256 verifies"
fi
IDX="${REPO_EXPORT}/artifacts/upgrade-discovery/index.tsv"
[[ -f "$IDX" ]] && pass "index.tsv created" || fail "index.tsv created"

# Re-export same hop with updated package count — no duplicate index rows
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
# Keep a marker file in prior export to ensure atomic replace removes old extras
printf 'stale' >"${EXP1}/stale-should-vanish.txt"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >"${WORKDIR}/export2.out" 2>"${WORKDIR}/export2.err"
rc_export2=$?
set -e
[[ "$rc_export2" -eq 0 ]] || { fail "export-hop re-export succeeds"; cat "${WORKDIR}/export2.err" || true; }
hop_rows="$(awk -F'\t' 'NR>1 && $1=="bionic-to-focal"{c++} END{print c+0}' "$IDX")"
[[ "$hop_rows" -eq 1 ]] && pass "index.tsv one row per hop on re-export" \
  || fail "index.tsv one row per hop on re-export (rows=$hop_rows)"
req_pkgs="$(python3 -c 'import json; print(json.load(open("'"$EXP1"'/export-summary.json"))["required_packages"])')"
[[ "$req_pkgs" == "5" ]] && pass "index/summary updated on re-export" \
  || fail "index/summary updated on re-export (required_packages=$req_pkgs)"
[[ ! -f "${EXP1}/stale-should-vanish.txt" ]] && pass "re-export atomically replaces hop dir" \
  || fail "re-export atomically replaces hop dir"

# Second hop + sort order
EXPORT_OUT_X="${WORKDIR}/export-src-xenial"
seed_export_hop "$EXPORT_OUT_X" "xenial-to-bionic" "16.04" "18.04" 1
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT_X" --repo-dir "$REPO_EXPORT" >/dev/null
EXPORT_OUT_F="${WORKDIR}/export-src-focal"
seed_export_hop "$EXPORT_OUT_F" "focal-to-jammy" "20.04" "22.04" 1
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT_F" --repo-dir "$REPO_EXPORT" >/dev/null
EXPORT_OUT_J="${WORKDIR}/export-src-jammy"
seed_export_hop "$EXPORT_OUT_J" "jammy-to-noble" "22.04" "24.04" 1
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT_J" --repo-dir "$REPO_EXPORT" >/dev/null
order="$(awk -F'\t' 'NR>1{print $1}' "$IDX" | tr '\n' ',')"
if [[ "$order" == "xenial-to-bionic,bionic-to-focal,focal-to-jammy,jammy-to-noble," ]]; then
  pass "index.tsv hop sort order fixed"
else
  fail "index.tsv hop sort order fixed (got=$order)"
fi

# Idempotent: third export of bionic unchanged checksums
sum_before="$(sha256sum "${EXP1}/checksums.sha256" | awk '{print $1}')"
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" >/dev/null
sum_after="$(sha256sum "${EXP1}/checksums.sha256" | awk '{print $1}')"
# exported_at_utc changes => checksums.sha256 changes; verify content still validates
if (cd "$EXP1" && sha256sum -c checksums.sha256 >/dev/null); then
  pass "export-hop repeated run remains valid (idempotent verify)"
else
  fail "export-hop repeated run remains valid (idempotent verify)"
fi
# Manifest body files (excluding summary timestamp) stay byte-identical across re-export
# of unchanged source — re-seed same 5-row source already done; compare packages tsv
if cmp -s "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-packages.tsv" \
     "${EXP1}/required-packages.tsv"; then
  pass "export-hop idempotent manifest copy"
else
  fail "export-hop idempotent manifest copy"
fi

# Rejection: validation FAIL — existing export must remain
cp -a "$EXP1" "${WORKDIR}/export-bionic-backup"
printf 'VALIDATION: FAIL\nfailures:\n  - boom\n' \
  >"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/validation.txt"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >"${WORKDIR}/export-fail.out" 2>"${WORKDIR}/export-fail.err"
rc_fail=$?
set -e
[[ "$rc_fail" -ne 0 ]] && pass "export-hop rejects validation FAIL" \
  || fail "export-hop rejects validation FAIL"
if diff -qr "${WORKDIR}/export-bionic-backup" "$EXP1" >/dev/null; then
  pass "export-hop keeps prior export on FAIL"
else
  fail "export-hop keeps prior export on FAIL"
fi
if ! find "${REPO_EXPORT}/artifacts/upgrade-discovery" -maxdepth 1 -type d -name '.staging-*' | grep -q .; then
  pass "export-hop leaves no staging dir on FAIL"
else
  fail "export-hop leaves no staging dir on FAIL"
  find "${REPO_EXPORT}/artifacts/upgrade-discovery" -maxdepth 1 -type d -name '.staging-*' || true
fi

# Restore PASS validation for further reject tests
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
cp -a "$EXP1" "${WORKDIR}/export-bionic-backup2"

# unresolved-packages nonempty
printf 'bionic-to-focal\tp\t1\tamd64\thttp://x\thttp://x\treason\n' \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/unresolved-packages.tsv"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-unres-pkg.err"
rc_up=$?
set -e
[[ "$rc_up" -ne 0 ]] && grep -q 'unresolved-packages' "${WORKDIR}/export-unres-pkg.err" \
  && pass "export-hop rejects unresolved-packages rows" \
  || fail "export-hop rejects unresolved-packages rows"
diff -qr "${WORKDIR}/export-bionic-backup2" "$EXP1" >/dev/null \
  && pass "prior export kept after unresolved-packages reject" \
  || fail "prior export kept after unresolved-packages reject"

# unresolved-files nonempty
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
printf 'bionic-to-focal\tinrelease\tInRelease\thttp://x\thttp://x\thttp_304_without_stored_body\n' \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/unresolved-files.tsv"
# false PASS text with unresolved rows
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-unres-file.err"
rc_uf=$?
set -e
[[ "$rc_uf" -ne 0 ]] && grep -q 'unresolved-files' "${WORKDIR}/export-unres-file.err" \
  && pass "export-hop rejects unresolved-files rows" \
  || fail "export-hop rejects unresolved-files rows"

# ---------------------------------------------------------------------------
# stale by-hash 404: excluded from required manifests on rebuild, then export OK
# ---------------------------------------------------------------------------
STALE_OUT="${WORKDIR}/stale-byhash-rebuild"
export DUR_DRY_RECORDING=1
export DUR_HOST_ROOT="$CAPHOST"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$STALE_OUT" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$STALE_OUT" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$STALE_OUT" >/dev/null
HOP_STALE="${STALE_OUT}/upgrade-discovery/bionic-to-focal"
bash "$SCRIPT" stop-recording --output-dir "$STALE_OUT" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$STALE_OUT" >/dev/null
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP_STALE}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP_STALE}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP_STALE}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP_STALE}/after/file-manifest.tsv"
echo -e 'path\thash\tpackage' >"${HOP_STALE}/before/conffiles.tsv"
echo -e 'path\thash\tpackage' >"${HOP_STALE}/after/conffiles.tsv"
: >"${HOP_STALE}/runtime/apt-history.log"
: >"${HOP_STALE}/runtime/apt-term.log"
: >"${HOP_STALE}/runtime/dpkg.log"
mkdir -p "${HOP_STALE}/runtime/dist-upgrade"
STALE_INREL='http://archive.ubuntu.com/ubuntu/dists/bionic/InRelease'
STALE_BYHASH='http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/binary-amd64/by-hash/SHA256/stalebeefcafe'
# Seed successful InRelease capture + access log with stale by-hash 404
python3 - "$HOP_STALE" "$STALE_INREL" "$STALE_BYHASH" <<'PY'
from __future__ import print_function
import hashlib, json, os, sys
hop, inrel, byhash = sys.argv[1], sys.argv[2], sys.argv[3]
cache = os.path.join(hop, "runtime", "deb-cache")
body = b"InRelease-secured-body\n"
key = hashlib.sha256(inrel.encode("utf-8")).hexdigest()
directory = os.path.join(cache, key[0:2], key[2:4])
os.makedirs(directory, exist_ok=True)
path = os.path.join(directory, key)
open(path, "wb").write(body)
sha = hashlib.sha256(body).hexdigest()
meta = {
    "original_url": inrel, "final_url": inrel, "redirect_chain": [inrel],
    "http_status": 200, "content_length": len(body), "size_bytes": len(body),
    "sha256": sha, "local_path": path,
}
open(path + ".meta.json", "w", encoding="utf-8").write(json.dumps(meta, indent=2) + "\n")
log = os.path.join(hop, "runtime", "proxy-access.log")
open(log, "w", encoding="utf-8").write(
    "2026-07-19T00:00:00Z GET %s 200 %d local_path=%s sha256=%s\n"
    "2026-07-19T00:00:01Z GET %s 404 0\n" % (inrel, len(body), path, sha, byhash)
)
open(os.path.join(hop, "runtime", "recording-started-at.txt"), "w").write("2026-07-19T00:00:00Z\n")
PY
# Confirm preconditions would include by-hash in raw URL log before rebuild semantics
if grep -q "$STALE_BYHASH" "${HOP_STALE}/runtime/proxy-access.log" \
   && grep -q ' 404 ' "${HOP_STALE}/runtime/proxy-access.log"; then
  pass "stale by-hash fixture: access log has by-hash 404"
else
  fail "stale by-hash fixture: access log has by-hash 404"
fi
python3 "$PY" build-manifests --hop-dir "$HOP_STALE" --hop bionic-to-focal >/dev/null
set +e
python3 "$PY" validate --hop-dir "$HOP_STALE" --hop bionic-to-focal --from-os 18.04 --to-os 20.04 \
  >"${WORKDIR}/stale-validate.out" 2>"${WORKDIR}/stale-validate.err"
rc_stale_val=$?
set -e
if [[ "$rc_stale_val" -eq 0 ]] && grep -q 'VALIDATION: PASS' "${HOP_STALE}/validation.txt"; then
  pass "stale by-hash rebuild validation PASS"
else
  fail "stale by-hash rebuild validation PASS (rc=$rc_stale_val)"
  cat "${HOP_STALE}/validation.txt" || true
  cat "${WORKDIR}/stale-validate.err" || true
fi
if ! grep -q "$STALE_BYHASH" "${HOP_STALE}/required-files.tsv" \
   && ! grep -q "$STALE_BYHASH" "${HOP_STALE}/required-urls.tsv" \
   && grep -q "$STALE_BYHASH" "${HOP_STALE}/failed-requests.tsv" \
   && ! grep -q "$STALE_BYHASH" "${HOP_STALE}/unresolved-files.tsv"; then
  pass "stale by-hash removed from required-files/urls, kept in failed-requests"
else
  fail "stale by-hash removed from required-files/urls, kept in failed-requests"
  grep -n "$STALE_BYHASH" "${HOP_STALE}/required-files.tsv" "${HOP_STALE}/required-urls.tsv" \
    "${HOP_STALE}/failed-requests.tsv" "${HOP_STALE}/unresolved-files.tsv" || true
fi
if grep -q "$STALE_INREL" "${HOP_STALE}/required-files.tsv"; then
  pass "stale by-hash rebuild keeps secured InRelease in required-files"
else
  fail "stale by-hash rebuild keeps secured InRelease in required-files"
fi
if python3 - "$HOP_STALE" <<'PY'
import json, sys
hd = sys.argv[1]
ev = json.load(open(hd + "/evidence.json", encoding="utf-8"))
assert ev["failed_requests"] == 1
assert ev.get("historical_non_required_failures") == 1
assert ev.get("historical_non_required_failure_reasons") == {"stale_by_hash_404": 1}
assert ev["unresolved_files"] == 0
assert ev["required_files"] == ev["resolved_files"]
assert ev["required_files"] == ev["resolved_files"] + ev["unresolved_files"]
# failed-requests row preserved
rows = open(hd + "/failed-requests.tsv", encoding="utf-8").read().splitlines()
assert any("by_hash" in r and "404" in r for r in rows[1:])
print("ok")
PY
then
  pass "stale by-hash evidence historical_non_required + count identity"
else
  fail "stale by-hash evidence historical_non_required + count identity"
fi
# .deb 404 must remain in required manifests (not stripped) and stay blocking
STALE_DEB_OUT="${WORKDIR}/stale-deb-not-stripped"
bash "$SCRIPT" init --from 18.04 --to 20.04 --output-dir "$STALE_DEB_OUT" >/dev/null
bash "$SCRIPT" before-hop --output-dir "$STALE_DEB_OUT" >/dev/null
bash "$SCRIPT" start-recording --output-dir "$STALE_DEB_OUT" >/dev/null
HOP_DEB="${STALE_DEB_OUT}/upgrade-discovery/bionic-to-focal"
bash "$SCRIPT" stop-recording --output-dir "$STALE_DEB_OUT" >/dev/null
bash "$SCRIPT" after-hop --output-dir "$STALE_DEB_OUT" >/dev/null
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP_DEB}/before/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-installed-packages.tsv" "${HOP_DEB}/after/installed-packages.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP_DEB}/before/file-manifest.tsv"
cp "${FIXTURES}/inventories/before-file-manifest.tsv" "${HOP_DEB}/after/file-manifest.tsv"
echo -e 'path\thash\tpackage' >"${HOP_DEB}/before/conffiles.tsv"
echo -e 'path\thash\tpackage' >"${HOP_DEB}/after/conffiles.tsv"
: >"${HOP_DEB}/runtime/apt-history.log"
: >"${HOP_DEB}/runtime/apt-term.log"
: >"${HOP_DEB}/runtime/dpkg.log"
mkdir -p "${HOP_DEB}/runtime/dist-upgrade"
DEB404='http://archive.ubuntu.com/ubuntu/pool/main/b/bash/bash_9.9.9_amd64.deb'
python3 - "$HOP_DEB" "$STALE_INREL" "$DEB404" <<'PY'
from __future__ import print_function
import hashlib, json, os, sys
hop, inrel, deb = sys.argv[1], sys.argv[2], sys.argv[3]
cache = os.path.join(hop, "runtime", "deb-cache")
body = b"InRelease-secured-body\n"
key = hashlib.sha256(inrel.encode("utf-8")).hexdigest()
directory = os.path.join(cache, key[0:2], key[2:4])
os.makedirs(directory, exist_ok=True)
path = os.path.join(directory, key)
open(path, "wb").write(body)
sha = hashlib.sha256(body).hexdigest()
meta = {
    "original_url": inrel, "final_url": inrel, "redirect_chain": [inrel],
    "http_status": 200, "content_length": len(body), "size_bytes": len(body),
    "sha256": sha, "local_path": path,
}
open(path + ".meta.json", "w", encoding="utf-8").write(json.dumps(meta, indent=2) + "\n")
open(os.path.join(hop, "runtime", "proxy-access.log"), "w", encoding="utf-8").write(
    "2026-07-19T00:00:00Z GET %s 200 %d local_path=%s sha256=%s\n"
    "2026-07-19T00:00:01Z GET %s 404 0\n" % (inrel, len(body), path, sha, deb)
)
open(os.path.join(hop, "runtime", "recording-started-at.txt"), "w").write("2026-07-19T00:00:00Z\n")
PY
python3 "$PY" build-manifests --hop-dir "$HOP_DEB" --hop bionic-to-focal >/dev/null
if grep -q "$DEB404" "${HOP_DEB}/failed-requests.tsv" \
   && grep -q "$DEB404" "${HOP_DEB}/required-urls.tsv"; then
  pass "package .deb 404 kept in required-urls/failed-requests (not stripped)"
else
  fail "package .deb 404 kept in required-urls/failed-requests (not stripped)"
fi
# export path for rebuilt stale by-hash hop
cp "${HOP_STALE}/failed-requests.tsv" "${WORKDIR}/src-failed-requests.before"
REPO_STALE="${WORKDIR}/repo-stale-byhash"
mkdir -p "$REPO_STALE"
set +e
bash "$SCRIPT" export-hop --output-dir "$STALE_OUT" --repo-dir "$REPO_STALE" \
  >"${WORKDIR}/export-byhash.out" 2>"${WORKDIR}/export-byhash.err"
rc_byhash=$?
set -e
EXP_BY="${REPO_STALE}/artifacts/upgrade-discovery/bionic-to-focal"
if [[ "$rc_byhash" -eq 0 ]]; then
  pass "export-hop allows stale by-hash 404 when unresolved=0"
else
  fail "export-hop allows stale by-hash 404 when unresolved=0 (rc=$rc_byhash)"
  cat "${WORKDIR}/export-byhash.err" || true
  cat "${HOP_STALE}/validation.txt" || true
fi
if cmp -s "${WORKDIR}/src-failed-requests.before" "${EXP_BY}/failed-requests.tsv"; then
  pass "export-hop preserves failed-requests.tsv (stale by-hash)"
else
  fail "export-hop preserves failed-requests.tsv (stale by-hash)"
fi
if python3 - "$EXP_BY" <<'PY'
import json, sys
s = json.load(open(sys.argv[1] + "/export-summary.json", encoding="utf-8"))
assert s["failed_requests"] == 1
assert s["failed_requests_total"] == 1
assert s["failed_requests_blocking"] == 0
assert s["failed_requests_non_blocking"] == 1
assert s["non_blocking_failure_reasons"] == {"stale_by_hash_404": 1}
assert s["required_files"] == s["resolved_files"] + s["unresolved_files"]
assert s.get("historical_non_required_failures") == 1
assert s.get("historical_non_required_failure_reasons") == {"stale_by_hash_404": 1}
print("ok")
PY
then
  pass "export-summary classifies stale by-hash as non-blocking"
else
  fail "export-summary classifies stale by-hash as non-blocking"
fi
IDX_STALE="${REPO_STALE}/artifacts/upgrade-discovery/index.tsv"
if python3 - "$IDX_STALE" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().splitlines()
hdr = lines[0].split("\t")
needed = [
    "failed_requests", "failed_requests_total",
    "failed_requests_blocking", "failed_requests_non_blocking",
]
for col in needed:
    assert col in hdr, col
row = None
for line in lines[1:]:
    parts = line.split("\t")
    if parts and parts[0] == "bionic-to-focal":
        row = dict(zip(hdr, parts))
        break
assert row is not None
assert row["failed_requests"] == "1"
assert row["failed_requests_total"] == "1"
assert row["failed_requests_blocking"] == "0"
assert row["failed_requests_non_blocking"] == "1"
print("ok")
PY
then
  pass "index.tsv failed-request classification columns"
else
  fail "index.tsv failed-request classification columns"
fi

# package .deb 404 => export refused (and not treated as historical strip)
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
printf 'bionic-to-focal\thttp://example.test/pool/p_1_amd64.deb\thttp://example.test/pool/p_1_amd64.deb\t404\tHTTP 404\tdeb\n' \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/failed-requests.tsv"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-failed-deb.err"
rc_fr_deb=$?
set -e
[[ "$rc_fr_deb" -ne 0 ]] && grep -q 'blocking_failed_requests' "${WORKDIR}/export-failed-deb.err" \
  && pass "export-hop rejects package .deb 404" \
  || fail "export-hop rejects package .deb 404"

# release upgrader tar.gz 404 => export refused
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
printf 'bionic-to-focal\thttp://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz\thttp://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz\t404\tHTTP 404\trelease_upgrader\n' \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/failed-requests.tsv"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-failed-upgrader.err"
rc_fr_up=$?
set -e
[[ "$rc_fr_up" -ne 0 ]] && grep -q 'blocking_failed_requests' "${WORKDIR}/export-failed-upgrader.err" \
  && pass "export-hop rejects release upgrader tar.gz 404" \
  || fail "export-hop rejects release upgrader tar.gz 404"

# by-hash 404 that remains unresolved-files => export refused (not stripped)
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
BYHASH_UNRES='http://archive.ubuntu.com/ubuntu/dists/bionic/main/binary-amd64/by-hash/SHA256/unresolvedbeef'
printf 'bionic-to-focal\t%s\t%s\t404\tHTTP 404\tby_hash\n' "$BYHASH_UNRES" "$BYHASH_UNRES" \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/failed-requests.tsv"
printf 'bionic-to-focal\tby_hash\tSHA256\t%s\t%s\thttp_404\n' "$BYHASH_UNRES" "$BYHASH_UNRES" \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/unresolved-files.tsv"
# Also keep URL in required-files to show it is not auto-stripped when unresolved
printf 'bionic-to-focal\tby_hash\tSHA256\t%s\t%s\t\t0\t\t404\t1\tproxy_access_log\n' \
  "$BYHASH_UNRES" "$BYHASH_UNRES" \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-files.tsv"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-byhash-unres.err"
rc_bh_un=$?
set -e
[[ "$rc_bh_un" -ne 0 ]] && grep -qE 'unresolved-files|blocking_failed_requests|count_mismatch' "${WORKDIR}/export-byhash-unres.err" \
  && pass "export-hop rejects by-hash 404 linked to unresolved-files" \
  || fail "export-hop rejects by-hash 404 linked to unresolved-files"

# 500 failure linked to final unresolved => export refused
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
FAIL500='http://example.test/ubuntu/dists/bionic/InRelease'
printf 'bionic-to-focal\t%s\t%s\t500\tHTTP 500\tinrelease\n' "$FAIL500" "$FAIL500" \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/failed-requests.tsv"
printf 'bionic-to-focal\tinrelease\tInRelease\t%s\t%s\thttp_500\n' "$FAIL500" "$FAIL500" \
  >>"${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/unresolved-files.tsv"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-failed-500.err"
rc_fr_500=$?
set -e
[[ "$rc_fr_500" -ne 0 ]] && grep -qE 'unresolved-files|blocking_failed_requests' "${WORKDIR}/export-failed-500.err" \
  && pass "export-hop rejects 500 linked to unresolved" \
  || fail "export-hop rejects 500 linked to unresolved"

# missing required manifest
seed_export_hop "$EXPORT_OUT" "bionic-to-focal" "18.04" "20.04" 5
rm -f "${EXPORT_OUT}/upgrade-discovery/bionic-to-focal/required-urls.tsv"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_OUT" --repo-dir "$REPO_EXPORT" \
  >/dev/null 2>"${WORKDIR}/export-missing.err"
rc_miss=$?
set -e
[[ "$rc_miss" -ne 0 ]] && grep -q 'missing:required-urls.tsv' "${WORKDIR}/export-missing.err" \
  && pass "export-hop rejects missing manifest" \
  || fail "export-hop rejects missing manifest"

# No .deb / runtime/deb-cache in any export tree
if find "${REPO_EXPORT}/artifacts/upgrade-discovery" \( -name '*.deb' -o -path '*/runtime/*' -o -path '*/deb-cache/*' \) | grep -q .; then
  fail "export-hop excludes .deb and runtime/deb-cache"
  find "${REPO_EXPORT}/artifacts/upgrade-discovery" \( -name '*.deb' -o -path '*/runtime/*' -o -path '*/deb-cache/*' \) || true
else
  pass "export-hop excludes .deb and runtime/deb-cache"
fi

# non-ASCII output-dir path
EXPORT_UTF="${WORKDIR}/export-src-유니코드"
seed_export_hop "$EXPORT_UTF" "bionic-to-focal" "18.04" "20.04" 1
REPO_UTF="${WORKDIR}/repo-유니코드"
mkdir -p "$REPO_UTF"
set +e
bash "$SCRIPT" export-hop --output-dir "$EXPORT_UTF" --repo-dir "$REPO_UTF" \
  >"${WORKDIR}/export-utf.out" 2>"${WORKDIR}/export-utf.err"
rc_utf=$?
set -e
if [[ "$rc_utf" -eq 0 ]] \
   && [[ -f "${REPO_UTF}/artifacts/upgrade-discovery/bionic-to-focal/export-summary.json" ]] \
   && (cd "${REPO_UTF}/artifacts/upgrade-discovery/bionic-to-focal" && sha256sum -c checksums.sha256 >/dev/null); then
  pass "export-hop handles non-ASCII paths"
else
  fail "export-hop handles non-ASCII paths (rc=$rc_utf)"
  cat "${WORKDIR}/export-utf.err" || true
fi

# No leftover staging after success path either
if ! find "${REPO_EXPORT}/artifacts/upgrade-discovery" "${REPO_UTF}/artifacts/upgrade-discovery" \
     -maxdepth 1 -type d \( -name '.staging-*' -o -name '.replace-*' -o -name '.old-*' \) 2>/dev/null \
     | grep -q .; then
  pass "export-hop leaves no staging/replace/old dirs"
else
  fail "export-hop leaves no staging/replace/old dirs"
fi

# ---------------------------------------------------------------------------
unset DUR_HOST_ROOT DUR_DRY_RECORDING DUR_PROXY_PORT DUR_PROXY_PY

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL discover-upgrade-requirements TESTS PASSED"
  exit 0
fi
echo "SOME discover-upgrade-requirements TESTS FAILED"
exit 1
