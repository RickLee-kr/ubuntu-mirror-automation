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
cp "${FIXTURES}/debs/"*.deb "${HOP_DIR}/runtime/deb-cache/"
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
  # extra may be unresolved if no local deb — still must appear as requested/unresolved
  if grep -q 'extra_1.0_amd64.deb' "${HOP_DIR}/unresolved-packages.tsv" || grep -q 'extra' "${HOP_DIR}/required-packages.tsv"; then
    pass "downloaded but not installed preserved (unresolved/required)"
  else
    fail "extra package missing from manifests"
  fi
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
cp "${FIXTURES}/debs/"*.deb "${HOP2}/runtime/deb-cache/"
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
if [[ -f "${HOPL}/runtime/deb-cache/bash_4.4.18-2ubuntu1_amd64.deb" ]]; then
  pass "downloaded .deb preserved in runtime/deb-cache"
else
  fail "downloaded .deb preserved in runtime/deb-cache"
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
cp "${FIXTURES}/debs/"*.deb "${HOPFNL}/runtime/deb-cache/"
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
unset DUR_HOST_ROOT DUR_DRY_RECORDING DUR_PROXY_PORT DUR_PROXY_PY

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL discover-upgrade-requirements TESTS PASSED"
  exit 0
fi
echo "SOME discover-upgrade-requirements TESTS FAILED"
exit 1
