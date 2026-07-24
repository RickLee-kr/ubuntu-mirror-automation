#!/usr/bin/env bash
# Unit / fixture tests for offline mirror helpers and failure modes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/offline.sh
source "${ROOT}/lib/offline.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[test] meta-release-lts parsing"

cat >"${WORKDIR}/meta" <<'EOF'
Dist: trusty
Name: Trusty
UpgradeTool: http://archive.ubuntu.com/ubuntu/dists/trusty-updates/main/dist-upgrader-all/current/trusty.tar.gz
UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/trusty-updates/main/dist-upgrader-all/current/trusty.tar.gz.gpg

Dist: bionic
Name: Bionic Beaver
Version: 18.04.6 LTS
Supported: 1
Release-File: http://archive.ubuntu.com/ubuntu/dists/bionic-updates/Release
ReleaseNotes: http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/ReleaseAnnouncement
ReleaseNotesHtml: http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/ReleaseAnnouncement.html
UpgradeTool: http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz
UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz.gpg

Dist: focal
Name: Focal Fossa
UpgradeTool: http://archive.ubuntu.com/ubuntu/dists/focal-updates/main/dist-upgrader-all/current/focal.tar.gz
UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/focal-updates/main/dist-upgrader-all/current/focal.tar.gz.gpg
Release-File: http://archive.ubuntu.com/ubuntu/dists/focal-updates/Release
ReleaseNotes: http://archive.ubuntu.com/ubuntu/dists/focal-updates/main/dist-upgrader-all/current/ReleaseAnnouncement
ReleaseNotesHtml: http://archive.ubuntu.com/ubuntu/dists/focal-updates/main/dist-upgrader-all/current/ReleaseAnnouncement.html

Dist: jammy
Name: Jammy
UpgradeTool: http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/dist-upgrader-all/current/jammy.tar.gz
UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/dist-upgrader-all/current/jammy.tar.gz.gpg
Release-File: http://archive.ubuntu.com/ubuntu/dists/jammy-updates/Release
ReleaseNotes: http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/dist-upgrader-all/current/ReleaseAnnouncement
ReleaseNotesHtml: http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/dist-upgrader-all/current/ReleaseAnnouncement.html

Dist: noble
Name: Noble
UpgradeTool: http://archive.ubuntu.com/ubuntu/dists/noble-updates/main/dist-upgrader-all/current/noble.tar.gz
UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/noble-updates/main/dist-upgrader-all/current/noble.tar.gz.gpg
Release-File: http://archive.ubuntu.com/ubuntu/dists/noble-updates/Release
ReleaseNotes: http://archive.ubuntu.com/ubuntu/dists/noble-updates/main/dist-upgrader-all/current/ReleaseAnnouncement
ReleaseNotesHtml: http://archive.ubuntu.com/ubuntu/dists/noble-updates/main/dist-upgrader-all/current/ReleaseAnnouncement.html

Dist: xenial
Name: Xenial
UpgradeTool: http://archive.ubuntu.com/ubuntu/dists/xenial-updates/main/dist-upgrader-all/current/xenial.tar.gz
UpgradeToolSignature: http://archive.ubuntu.com/ubuntu/dists/xenial-updates/main/dist-upgrader-all/current/xenial.tar.gz.gpg
Release-File: http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release
ReleaseNotes: http://archive.ubuntu.com/ubuntu/dists/xenial-updates/main/dist-upgrader-all/current/ReleaseAnnouncement
ReleaseNotesHtml: http://archive.ubuntu.com/ubuntu/dists/xenial-updates/main/dist-upgrader-all/current/ReleaseAnnouncement.html
EOF

stanza="$(uom_extract_dist_stanza "${WORKDIR}/meta" bionic)"
tool="$(uom_stanza_get "$stanza" UpgradeTool)"
[[ "$tool" == *bionic.tar.gz ]] && pass "extract UpgradeTool" || fail "extract UpgradeTool: $tool"

missing="$(uom_extract_dist_stanza "${WORKDIR}/meta" doesnotexist || true)"
[[ -z "$missing" ]] && pass "missing Dist returns empty" || fail "missing Dist"

# Required Dist missing in build
if uom_build_local_meta "${WORKDIR}/meta" "http://mirror.local" bionic missingdist >"${WORKDIR}/out" 2>"${WORKDIR}/err"; then
  fail "should fail on missing Dist"
else
  pass "missing Dist fails build"
fi

# UpgradeTool missing
cat >"${WORKDIR}/meta-bad" <<'EOF'
Dist: bionic
Name: Bionic
Release-File: http://archive.ubuntu.com/ubuntu/dists/bionic-updates/Release
EOF
if uom_build_local_meta "${WORKDIR}/meta-bad" "http://mirror.local" bionic >"${WORKDIR}/out" 2>"${WORKDIR}/err"; then
  fail "should fail on missing UpgradeTool"
else
  pass "missing UpgradeTool fails"
fi

echo "[test] allowlisted hosts / rewrite"
uom_host_allowed archive.ubuntu.com "archive.ubuntu.com security.ubuntu.com" && pass "allow archive" || fail "allow archive"
uom_host_allowed evil.example "archive.ubuntu.com" && fail "should reject evil" || pass "reject evil host"

rewritten="$(uom_rewrite_url "http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz" "http://mirror.local")"
[[ "$rewritten" == "http://mirror.local/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz" ]] \
  && pass "rewrite archive URL" || fail "rewrite: $rewritten"

sec_rewritten="$(uom_rewrite_url "http://security.ubuntu.com/ubuntu/dists/jammy-security/InRelease" "http://mirror.local")"
[[ "$sec_rewritten" == "http://mirror.local/ubuntu-security/dists/jammy-security/InRelease" ]] \
  && pass "rewrite security URL to /ubuntu-security" || fail "security rewrite: $sec_rewritten"

if uom_rewrite_url "http://evil.example/x" "http://mirror.local" >/dev/null 2>&1; then
  fail "rewrite should reject unknown host"
else
  pass "rewrite rejects unknown host"
fi

echo "[test] local meta rewrite + external URL detection"
uom_build_local_meta "${WORKDIR}/meta" "http://mirror.local" xenial bionic focal jammy noble >"${WORKDIR}/local"
grep -q 'UpgradeTool: http://mirror.local/ubuntu/dists/bionic' "${WORKDIR}/local" && pass "local UpgradeTool rewritten" || fail "local UpgradeTool"
if grep -E 'UpgradeTool:.*archive\.ubuntu\.com' "${WORKDIR}/local"; then
  fail "external UpgradeTool remained"
else
  pass "no external UpgradeTool in local meta"
fi
uom_local_meta_urls_ok "${WORKDIR}/local" "http://mirror.local" && pass "local meta URLs ok" || fail "local meta URLs"

# Inject external URL
sed 's|http://mirror.local/ubuntu/dists/bionic|http://archive.ubuntu.com/ubuntu/dists/bionic|' \
  "${WORKDIR}/local" >"${WORKDIR}/local-bad"
uom_local_meta_urls_ok "${WORKDIR}/local-bad" "http://mirror.local" && fail "should detect external URL" || pass "detects external URL"

echo "[test] suite list count (5 releases x 4 = 20)"
count="$(uom_all_suites "xenial bionic focal jammy noble" "updates security backports" | wc -l | tr -d ' ')"
[[ "$count" == "20" ]] && pass "20 suites" || fail "suite count=$count"

echo "[test] HTML detection / zero-byte"
printf '<!DOCTYPE html><html>err</html>' >"${WORKDIR}/html.gz"
uom_is_probably_html "${WORKDIR}/html.gz" && pass "detect HTML" || fail "detect HTML"
: >"${WORKDIR}/empty"
[[ "$(stat -c%s "${WORKDIR}/empty")" -eq 0 ]] && pass "zero-byte fixture" || fail "zero-byte"

echo "[test] bash -n scripts"
bash -n "${ROOT}/scripts/ubuntu-offline-mirror.sh"
bash -n "${ROOT}/lib/offline.sh"
bash -n "${ROOT}/scripts/run-apt-mirror.sh"
pass "bash -n"

echo "[test] by-hash CLI wiring"
grep -q 'sync-by-hash' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing sync-by-hash command"
grep -q 'validate-by-hash' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing validate-by-hash command"
grep -q 'sync_validate_cleanup_by_hash' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing by-hash in sync flow"
[[ -f "${ROOT}/scripts/lib/sync_by_hash.py" ]] || fail "missing sync_by_hash.py"
python3 -m py_compile "${ROOT}/scripts/lib/sync_by_hash.py"
pass "by-hash CLI + py_compile"

echo "[test] release-upgrader CLI wiring"
grep -q 'sync-release-upgraders' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing sync-release-upgraders"
grep -q 'sync-legacy-releases' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing sync-legacy-releases"
grep -q 'validate-legacy-releases' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing validate-legacy-releases"
grep -q 'freeze-xenial-snapshot' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing freeze-xenial-snapshot"
grep -q 'validate-release-upgraders' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing validate-release-upgraders"
grep -q 'sync_release_upgraders_py' "${ROOT}/scripts/ubuntu-offline-mirror.sh" || fail "missing py sync in flow"
[[ -f "${ROOT}/scripts/lib/sync_release_upgraders.py" ]] || fail "missing sync_release_upgraders.py"
[[ -f "${ROOT}/scripts/lib/validate_release_upgraders.py" ]] || fail "missing validate_release_upgraders.py"
python3 -m py_compile "${ROOT}/scripts/lib/sync_release_upgraders.py"
python3 -m py_compile "${ROOT}/scripts/lib/validate_release_upgraders.py"
pass "release-upgrader CLI + py_compile"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -x "${ROOT}/lib/offline.sh" && pass "shellcheck offline.sh" || fail "shellcheck offline.sh"
else
  echo "  SKIP: shellcheck not installed"
fi

echo "[test] mirror.list template policy"
if grep -Eiq '^[[:space:]]*deb-src|[[:space:]]i386[[:space:]]' "${ROOT}/templates/mirror.list"; then
  fail "template has i386/deb-src directives"
else
  pass "template has no i386/deb-src directives"
fi
if grep -qi 'EXCLUDED:.*i386' "${ROOT}/templates/mirror.list"; then
  pass "exclusion comment present"
fi
grep -q 'set defaultarch  amd64' "${ROOT}/templates/mirror.list" && pass "defaultarch amd64" || fail "defaultarch"
grep -q 'noble-backports' "${ROOT}/templates/mirror.list" && pass "noble-backports" || fail "backports"

echo "[test] systemd/nginx templates"
grep -q 'materialize-selective' "${ROOT}/templates/apt-mirror.service" && pass "service ExecStart" || fail "service ExecStart"
grep -q 'RandomizedDelaySec' "${ROOT}/templates/apt-mirror.timer" && pass "timer delay" || fail "timer delay"
grep -q 'location /offline/' "${ROOT}/templates/nginx.conf" && pass "nginx offline" || fail "nginx offline"
grep -q 'location /ubuntu/' "${ROOT}/templates/nginx.conf" && pass "nginx ubuntu/" || fail "nginx ubuntu/"
grep -q 'location /ubuntu-security/' "${ROOT}/templates/nginx.conf" && pass "nginx ubuntu-security/" || fail "nginx ubuntu-security/"
grep -q 'server_name security.ubuntu.com' "${ROOT}/templates/nginx.conf" && pass "nginx security Host vhost" || fail "nginx security Host"
grep -q 'server_name old-releases.ubuntu.com' "${ROOT}/templates/nginx.conf" && pass "nginx old-releases Host vhost" || fail "nginx old-releases Host"
grep -q 'sync_legacy_releases' "${ROOT}/scripts/ubuntu-offline-mirror.sh" && pass "legacy sync wired" || fail "legacy sync wiring"

# Simulate READY invalidation logic
READY="${WORKDIR}/READY"
echo ok >"$READY"
mv -f "$READY" "${READY}.invalid.1"
[[ ! -f "$READY" ]] && pass "READY invalidated" || fail "READY still present"

if [[ "$FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
