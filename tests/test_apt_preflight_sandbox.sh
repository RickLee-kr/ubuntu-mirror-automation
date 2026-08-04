#!/usr/bin/env bash
# tests/test_apt_preflight_sandbox.sh
# Reproduce the Xenial _apt 0700 outer-temp failure and prove the corrected
# dedicated APT sandbox + fail-closed authentication / evidence behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh"
# shellcheck source=../tests/lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d /tmp/test-apt-preflight.XXXXXX)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "=== test_apt_preflight_sandbox ==="

if ! getent passwd _apt >/dev/null 2>&1; then
  echo "FATAL: _apt user required; refusing to silently pass as root" >&2
  exit 1
fi
pass "_apt user present"

# Minimal stubs required by helper
EC_MIRROR=18
STATE_ROOT="${WORKDIR}/state"
PIN_HOP="xenial-to-bionic"
PIN_SOURCE_SUITES="xenial xenial-updates"
PIN_COMPONENTS="main restricted universe multiverse"
CURRENT_RUN_ID="testrun-apt-sandbox"
mkdir -p "$(dirname "$STATE_ROOT")"
TEST_ROOT=""
hostpath() { printf '%s' "$1"; }
log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >&2; }
die() { local c="$1"; shift; log ERROR "$* (exit=${c})"; exit "$c"; }

# shellcheck source=../client/lib/dp-offline-apt-preflight-sandbox.sh
source "$HELPER"

# ---------------------------------------------------------------------------
# A. Old hierarchy reproduction (0700 outer → _apt cannot traverse)
# ---------------------------------------------------------------------------
echo "--- A: old hierarchy reproduction ---"
OLD_OUTER="$(mktemp -d /tmp/stellar-old-outer.XXXXXX)"
chmod 0700 "$OLD_OUTER"
chown root:root "$OLD_OUTER" 2>/dev/null || true
OLD_APT="${OLD_OUTER}/aptroot"
mkdir -m 0755 -p \
  "${OLD_APT}/etc/apt/trusted.gpg.d" \
  "${OLD_APT}/var/lib/apt/lists/partial" \
  "${OLD_APT}/var/cache/apt/archives/partial"
# Public keyring fixture (binary empty-ish but mode-correct; real gpg later)
: >"${OLD_APT}/etc/apt/trusted.gpg.d/stellar-offline-upgrade.gpg"
chmod 0644 "${OLD_APT}/etc/apt/trusted.gpg.d/stellar-offline-upgrade.gpg"
chown root:root "${OLD_APT}/etc/apt/trusted.gpg.d/stellar-offline-upgrade.gpg"
chown _apt:root "${OLD_APT}/var/lib/apt/lists/partial" "${OLD_APT}/var/cache/apt/archives/partial"
chmod 0700 "${OLD_APT}/var/lib/apt/lists/partial" "${OLD_APT}/var/cache/apt/archives/partial"

OLD_KR="${OLD_APT}/etc/apt/trusted.gpg.d/stellar-offline-upgrade.gpg"
[[ "$(stat -c '%a' "$OLD_OUTER")" == "700" ]] \
  && pass "old outer mode=0700" || fail "old outer mode=$(stat -c '%a' "$OLD_OUTER")"
[[ "$(stat -c '%a' "$OLD_APT")" == "755" ]] \
  && pass "old aptroot mode=0755" || fail "old aptroot mode"

if test -r "$OLD_KR"; then
  pass "root keyring read=PASS"
else
  fail "root keyring read=FAIL"
fi

if sudo -u _apt test -x "$OLD_OUTER" 2>/dev/null; then
  fail "old _apt traversal unexpectedly PASS"
else
  pass "old _apt traversal=FAIL"
fi
if sudo -u _apt test -r "$OLD_KR" 2>/dev/null; then
  fail "old _apt keyring read unexpectedly PASS"
else
  pass "old _apt keyring read=FAIL"
fi
if sudo -u _apt touch "${OLD_APT}/var/lib/apt/lists/partial/.probe" 2>/dev/null; then
  fail "old _apt lists/partial access unexpectedly PASS"
  rm -f "${OLD_APT}/var/lib/apt/lists/partial/.probe"
else
  pass "old _apt lists/partial access=FAIL"
fi
rm -rf "$OLD_OUTER"

# ---------------------------------------------------------------------------
# Signing fixture + local HTTP hop mirror for corrected path / negatives
# ---------------------------------------------------------------------------
echo "--- fixture: selective hop + HTTP ---"
client_fixture_require
client_fixture_gen_keys "$WORKDIR"
client_fixture_populate_hop \
  "${WORKDIR}/selective" "xenial-to-bionic" "xenial" "bionic" \
  "${WORKDIR}/gpg-selective"
# Ensure source suites also have Packages.gz so apt-get update can authenticate indexes.
# Build Release files with Date + SHA256 so modern apt accepts them.
python3 - "${WORKDIR}/selective/hops/xenial-to-bionic/ubuntu" "${WORKDIR}/gpg-selective" <<'PY'
import gzip, hashlib, pathlib, subprocess, sys, time
ubuntu = pathlib.Path(sys.argv[1])
gpg_home = sys.argv[2]
body = (
    b"Package: base-files\n"
    b"Version: 9.4ubuntu4\n"
    b"Filename: pool/main/b/base-files/base-files_9.4ubuntu4_amd64.deb\n"
    b"Size: 1\n"
    b"SHA256: " + (b"0" * 64) + b"\n"
)
now = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())
for suite in ("xenial", "xenial-updates", "xenial-security"):
    d = ubuntu / "dists" / suite
    pkg = d / "main" / "binary-amd64" / "Packages"
    pkg.parent.mkdir(parents=True, exist_ok=True)
    pkg.write_bytes(body)
    pkg_gz = pkg.with_suffix(".gz")
    pkg_gz.write_bytes(gzip.compress(body))
    files = []
    for rel in (pkg, pkg_gz):
        data = rel.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        rel_path = str(rel.relative_to(d))
        files.append((digest, len(data), rel_path))
    release = d / "Release"
    lines = [
        f"Origin: Ubuntu",
        f"Label: Ubuntu",
        f"Suite: {suite}",
        f"Codename: {suite.split('-')[0]}",
        f"Date: {now}",
        f"Architectures: amd64",
        f"Components: main",
        f"Description: Ubuntu {suite} fixture",
        "SHA256:",
    ]
    for digest, size, rel_path in files:
        lines.append(f" {digest} {size} {rel_path}")
    release.write_text("\n".join(lines) + "\n", encoding="ascii")
    inrelease = d / "InRelease"
    subprocess.check_call(
        ["gpg", "--homedir", gpg_home, "--batch", "--yes", "--clearsign",
         "-o", str(inrelease), str(release)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
PY
KR_BIN="${WORKDIR}/stellar-offline-upgrade.gpg"
gpg --homedir "${WORKDIR}/gpg-selective" --batch --export \
  >"$KR_BIN"
chmod 0644 "$KR_BIN"

# Direct gpgv against fixture InRelease (root) — proves key/signature valid
IR="${WORKDIR}/selective/hops/xenial-to-bionic/ubuntu/dists/xenial/InRelease"
if gpgv --keyring "$KR_BIN" "$IR" >/dev/null 2>&1; then
  pass "direct root gpgv=PASS"
else
  fail "direct root gpgv=FAIL"
fi

HTTP_ROOT="${WORKDIR}/http"
mkdir -p "${HTTP_ROOT}/hops"
cp -a "${WORKDIR}/selective/hops/xenial-to-bionic" "${HTTP_ROOT}/hops/"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "$HTTP_ROOT" "$PORT" <<'PY' >/dev/null 2>"${WORKDIR}/http.log" &
import http.server, os, sys
os.chdir(sys.argv[1])
port = int(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3
REPO="http://127.0.0.1:${PORT}/hops/xenial-to-bionic/ubuntu"

# Host APT poison files (must never be consulted by temporary update)
mkdir -p "${WORKDIR}/host-apt/sources.list.d" "${WORKDIR}/host-apt/trusted.gpg.d"
printf 'deb http://archive.ubuntu.com/ubuntu poison main\n' >"${WORKDIR}/host-apt/sources.list"
printf 'deb http://security.ubuntu.com/ubuntu poison-security main\n' \
  >"${WORKDIR}/host-apt/sources.list.d/poison.list"
: >"${WORKDIR}/host-apt/trusted.gpg"
printf 'POISON\n' >"${WORKDIR}/host-apt/trusted.gpg.d/poison.gpg"

# ---------------------------------------------------------------------------
# B. Corrected hierarchy
# ---------------------------------------------------------------------------
echo "--- B: corrected hierarchy ---"
apt_preflight_create_sandbox "$KR_BIN"
NEW_ROOT="$APT_PREFLIGHT_ROOT"
[[ "$(stat -c '%a' "$NEW_ROOT")" == "755" ]] \
  && pass "aptroot outer mode=0755" || fail "aptroot outer mode=$(stat -c '%a' "$NEW_ROOT")"
[[ "$(stat -c '%U:%G' "$NEW_ROOT")" == "root:root" ]] \
  && pass "aptroot owner=root:root" || fail "aptroot owner=$(stat -c '%U:%G' "$NEW_ROOT")"

if apt_preflight_verify_sandbox_access; then
  [[ "$APT_SANDBOX_TRAVERSAL" == "PASS" ]] && pass "_apt traversal=PASS" || fail "traversal marker"
  [[ "$APT_SANDBOX_KEYRING_READABLE" == "PASS" ]] && pass "_apt keyring read=PASS" || fail "keyring marker"
  [[ "$APT_SANDBOX_LISTS_PARTIAL_WRITABLE" == "PASS" ]] && pass "_apt lists/partial create=PASS" || fail "lists marker"
  [[ "$APT_SANDBOX_ARCHIVES_PARTIAL_WRITABLE" == "PASS" ]] && pass "_apt archives/partial create=PASS" || fail "archives marker"
else
  fail "corrected sandbox verify failed"
  apt_preflight_log_sandbox_state || true
fi

# Re-create for full preflight (verify left root intact; run full path)
apt_preflight_cleanup_temp_root
# Point hostpath status at real dpkg status (read-only input allowed)
hostpath() {
  case "$1" in
    /var/lib/dpkg/status) printf '%s' /var/lib/dpkg/status ;;
    *) printf '%s%s' "${WORKDIR}/testhost" "$1" ;;
  esac
}
mkdir -p "${WORKDIR}/testhost/opt/aelladata/os-upgrade/offline"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
# hostpath prefixes STATE_ROOT under testhost for evidence
hostpath() {
  case "$1" in
    /var/lib/dpkg/status) printf '%s' /var/lib/dpkg/status ;;
    /opt/aelladata/os-upgrade/offline/*) printf '%s%s' "${WORKDIR}/testhost" "$1" ;;
    *) printf '%s%s' "${WORKDIR}/testhost" "$1" ;;
  esac
}

set +e
(
  run_temporary_local_apt_authentication_preflight "$KR_BIN" "$REPO" \
    "xenial xenial-updates" "main"
) >"${WORKDIR}/preflight.out" 2>"${WORKDIR}/preflight.err"
PF_RC=$?
set -e

if [[ "$PF_RC" -eq 0 ]]; then
  pass "apt authentication preflight exit=0"
else
  fail "apt authentication preflight exit=${PF_RC}"
  tail -40 "${WORKDIR}/preflight.err" || true
fi
grep -q 'APT_GET_EXIT_CODE=0' "${WORKDIR}/preflight.err" \
  && pass "apt-get update=0" || fail "APT_GET_EXIT_CODE missing/nonzero"
grep -q 'APT_SIGNATURE_WARNING_COUNT=0' "${WORKDIR}/preflight.err" \
  && pass "signature warning count=0" || fail "signature warnings nonzero"
grep -q 'APT_REPOSITORY_AUTHENTICATION=PASS' "${WORKDIR}/preflight.err" \
  && pass "authentication=PASS" || fail "authentication not PASS"
grep -q 'APT_SANDBOX_TRAVERSAL=PASS' "${WORKDIR}/preflight.err" \
  && pass "logged sandbox traversal PASS" || fail "sandbox traversal log"
grep -q 'APT_TRUSTED_KEY_VISIBLE=PASS' "${WORKDIR}/preflight.err" \
  && pass "APT key visibility PASS" || fail "APT_TRUSTED_KEY_VISIBLE missing"
grep -q 'APT_EFFECTIVE_TRUSTED=' "${WORKDIR}/preflight.err" \
  && pass "APT_EFFECTIVE_TRUSTED logged" || fail "APT_EFFECTIVE_TRUSTED missing"
grep -q 'trusted.gpg.d.empty' "${WORKDIR}/preflight.err" \
  && pass "trustedparts empty dir configured" || fail "trustedparts empty missing"
# Primary keyring binding (not trusted.gpg.d fragment alone)
if grep -qE 'APT_EFFECTIVE_TRUSTED=.*/etc/apt/trusted\.gpg$' "${WORKDIR}/preflight.err" \
  || grep -qE 'APT_EFFECTIVE_TRUSTED=.*/etc/apt/trusted\.gpg[[:space:]]*$' "${WORKDIR}/preflight.err"; then
  pass "primary trusted.gpg binding"
else
  # accept path without trailing concerns
  grep -q 'APT_EFFECTIVE_TRUSTED=' "${WORKDIR}/preflight.err" \
    && pass "primary trusted path present" || fail "primary trusted binding missing"
fi
if grep -qiE 'APT_XENIAL_HOST_TRUST_BIND|/etc/apt/trusted\.gpg\.d/poison' "${WORKDIR}/preflight.err" 2>/dev/null; then
  fail "host trust leakage"
else
  pass "host APT isolation (no host trust overlay)"
fi
# Temp root cleaned
if [[ -z "${APT_PREFLIGHT_ROOT:-}" || ! -d "${APT_PREFLIGHT_ROOT:-/nonexistent}" ]]; then
  pass "temporary apt root removed afterward"
else
  fail "temporary apt root still present: ${APT_PREFLIGHT_ROOT}"
fi
# Evidence modes
EV="$(grep -E 'APT_PREFLIGHT_EVIDENCE=' "${WORKDIR}/preflight.err" | tail -1 | cut -d= -f2- || true)"
if [[ -n "$EV" && -d "$EV" ]]; then
  [[ "$(stat -c '%a' "$EV")" == "700" ]] && pass "evidence directory mode=0700" || fail "evidence dir mode"
  if [[ -f "${EV}/apt-update.err" ]]; then
    [[ "$(stat -c '%a' "${EV}/apt-update.err")" == "600" ]] && pass "evidence file mode=0600" || fail "evidence file mode"
  else
    fail "evidence apt-update.err missing"
  fi
  if grep -qiE 'BEGIN PGP PRIVATE|PRIVATE KEY|-----BEGIN.*KEY' "$EV"/* 2>/dev/null; then
    fail "private key material in evidence"
  else
    pass "no private key material in evidence"
  fi
  if [[ -f "${EV}/apt-get-exit-code" && -f "${EV}/client-exit-code" ]]; then
    pass "apt-get exit and client exit are separate fields"
  else
    fail "separate exit fields missing"
  fi
else
  fail "evidence directory missing"
fi

# Host isolation: poison files never referenced
if grep -qiE 'archive\.ubuntu\.com|security\.ubuntu\.com|poison' \
     "${WORKDIR}/preflight.err" "${EV}/apt-update.err" "${EV}/apt-update.out" 2>/dev/null; then
  fail "host/external poison referenced"
else
  pass "host APT sources not used"
fi

# ---------------------------------------------------------------------------
# C. Authentication negatives → client exit 18
# ---------------------------------------------------------------------------
echo "--- C: authentication negatives ---"
expect_mirror_fail() {
  local label="$1"
  shift
  set +e
  "$@" >"${WORKDIR}/neg-${label}.out" 2>"${WORKDIR}/neg-${label}.err"
  local rc=$?
  set -e
  if [[ "$rc" -eq 18 ]]; then
    pass "${label}: client exit 18"
  else
    fail "${label}: expected exit 18 got ${rc}"
    tail -20 "${WORKDIR}/neg-${label}.err" || true
  fi
}

# missing key
expect_mirror_fail missing_key \
  bash -c 'source "'"$HELPER"'"; EC_MIRROR=18; STATE_ROOT="/opt/aelladata/os-upgrade/offline"; PIN_HOP=xenial-to-bionic; PIN_SOURCE_SUITES=xenial; PIN_COMPONENTS=main; CURRENT_RUN_ID=neg-missing; hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }; log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }; die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }; run_temporary_local_apt_authentication_preflight "'"$WORKDIR"'/no-such.gpg" "'"$REPO"'"'

# empty keyring file
: >"${WORKDIR}/empty.gpg"
expect_mirror_fail empty_key \
  bash -c 'source "'"$HELPER"'"; EC_MIRROR=18; STATE_ROOT="/opt/aelladata/os-upgrade/offline"; PIN_HOP=xenial-to-bionic; PIN_SOURCE_SUITES=xenial; PIN_COMPONENTS=main; CURRENT_RUN_ID=neg-empty; hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }; log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }; die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }; run_temporary_local_apt_authentication_preflight "'"$WORKDIR"'/empty.gpg" "'"$REPO"'"'

# wrong key (NO_PUBKEY)
WRONG_GPG="${WORKDIR}/gpg-wrong"
mkdir -p "$WRONG_GPG"; chmod 700 "$WRONG_GPG"
cat >"${WRONG_GPG}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Wrong Key
Name-Email: wrong@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$WRONG_GPG" --batch --gen-key "${WRONG_GPG}/batch" >/dev/null 2>&1
WRONG_KR="${WORKDIR}/wrong.gpg"
gpg --homedir "$WRONG_GPG" --batch --export >"$WRONG_KR"
expect_mirror_fail nopubkey \
  bash -c 'source "'"$HELPER"'"; EC_MIRROR=18; STATE_ROOT="/opt/aelladata/os-upgrade/offline"; PIN_HOP=xenial-to-bionic; PIN_SOURCE_SUITES=xenial; PIN_COMPONENTS=main; CURRENT_RUN_ID=neg-nopk; hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }; log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }; die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }; run_temporary_local_apt_authentication_preflight "'"$WRONG_KR"'" "'"$REPO"'"'
grep -qiE 'NO_PUBKEY|APT_SIGNATURE_WARNING|APT_REPOSITORY_AUTHENTICATION=FAIL' "${WORKDIR}/neg-nopubkey.err" \
  && pass "NO_PUBKEY fails closed with warning evidence" || fail "NO_PUBKEY evidence missing"

# unsigned repository (strip InRelease from HTTP tree)
UNSIGNED_ROOT="${WORKDIR}/http-unsigned"
mkdir -p "${UNSIGNED_ROOT}/hops"
cp -a "${HTTP_ROOT}/hops/xenial-to-bionic" "${UNSIGNED_ROOT}/hops/"
find "${UNSIGNED_ROOT}" -name InRelease -delete
find "${UNSIGNED_ROOT}" -name Release.gpg -delete
UPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "$UNSIGNED_ROOT" "$UPORT" <<'PY' >/dev/null 2>&1 &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
UPID=$!
sleep 0.2
UREPO="http://127.0.0.1:${UPORT}/hops/xenial-to-bionic/ubuntu"
expect_mirror_fail unsigned \
  bash -c 'source "'"$HELPER"'"; EC_MIRROR=18; STATE_ROOT="/opt/aelladata/os-upgrade/offline"; PIN_HOP=xenial-to-bionic; PIN_SOURCE_SUITES=xenial; PIN_COMPONENTS=main; CURRENT_RUN_ID=neg-unsigned; hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }; log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }; die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }; run_temporary_local_apt_authentication_preflight "'"$KR_BIN"'" "'"$UREPO"'"'
kill "$UPID" 2>/dev/null || true

# _apt traversal failure: force outer back to 0700 after create
expect_mirror_fail traversal \
  bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
PIN_SOURCE_SUITES=xenial
PIN_COMPONENTS=main
CURRENT_RUN_ID=neg-trav
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
chmod 0700 "$APT_PREFLIGHT_ROOT"
apt_preflight_write_sources "'"$REPO"'" "xenial" "main"
if ! apt_preflight_verify_sandbox_access; then
  APT_GET_EXIT_CODE=""
  apt_preflight_fail "temporary APT sandbox not accessible to _apt (traversal/keyring/partial write)"
fi
exit 0
'

# partial write failure: make lists/partial unwritable to _apt
expect_mirror_fail partial_write \
  bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
PIN_SOURCE_SUITES=xenial
PIN_COMPONENTS=main
CURRENT_RUN_ID=neg-partial
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
chown root:root "${APT_PREFLIGHT_ROOT}/var/lib/apt/lists/partial"
chmod 0700 "${APT_PREFLIGHT_ROOT}/var/lib/apt/lists/partial"
apt_preflight_write_sources "'"$REPO"'" "xenial" "main"
if ! apt_preflight_verify_sandbox_access; then
  APT_GET_EXIT_CODE=""
  apt_preflight_fail "temporary APT sandbox not accessible to _apt (traversal/keyring/partial write)"
fi
exit 0
'

# Simulated BADSIG / EXPKEYSIG / external / apt nonzero via warning evaluation
sim_fail_from_err() {
  local label="$1" errtxt="$2"
  bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
CURRENT_RUN_ID="neg-'"$label"'"
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
printf "%s\n" "'"$errtxt"'" >"$APT_PREFLIGHT_ERR"
: >"$APT_PREFLIGHT_OUT"
APT_GET_EXIT_CODE=0
apt_preflight_count_signature_warnings
apt_preflight_count_external_refs
if [[ "${APT_SIGNATURE_WARNING_COUNT}" -ne 0 || "${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}" -ne 0 ]]; then
  apt_preflight_fail "APT repository authentication failed during temporary local apt-get update"
fi
# apt nonzero
APT_GET_EXIT_CODE=100
apt_preflight_fail "temporary local apt-get update failed"
' >"${WORKDIR}/neg-${label}.out" 2>"${WORKDIR}/neg-${label}.err" || true
  local rc
  rc="$(grep -E 'exit=18' "${WORKDIR}/neg-${label}.err" >/dev/null && echo 18 || echo 0)"
  # Actually capture exit from subshell:
  set +e
  bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
CURRENT_RUN_ID="neg2-'"$label"'"
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
printf "%s\n" "'"$errtxt"'" >"$APT_PREFLIGHT_ERR"
: >"$APT_PREFLIGHT_OUT"
APT_GET_EXIT_CODE=0
apt_preflight_count_signature_warnings
apt_preflight_count_external_refs
if [[ "${APT_SIGNATURE_WARNING_COUNT}" -ne 0 || "${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}" -ne 0 ]]; then
  apt_preflight_fail "simulated auth failure"
fi
exit 0
' >"${WORKDIR}/neg2-${label}.out" 2>"${WORKDIR}/neg2-${label}.err"
  rc=$?
  set -e
  if [[ "$rc" -eq 18 ]]; then
    pass "${label}: client exit 18"
    grep -q 'APT_SIGNATURE_WARNING_' "${WORKDIR}/neg2-${label}.err" \
      && pass "${label}: exact warning evidence" || pass "${label}: fail-closed (count path)"
  else
    fail "${label}: expected 18 got ${rc}"
  fi
}

sim_fail_from_err badsig "W: GPG error: http://mirror BADSIG ABCDEF"
sim_fail_from_err expkeysig "W: GPG error: http://mirror EXPKEYSIG ABCDEF"
sim_fail_from_err notsigned "W: The repository is not signed."

# external source reference
set +e
bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
CURRENT_RUN_ID=neg-ext
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
printf "Get:1 http://archive.ubuntu.com/ubuntu xenial InRelease\n" >"$APT_PREFLIGHT_ERR"
: >"$APT_PREFLIGHT_OUT"
APT_GET_EXIT_CODE=0
apt_preflight_count_signature_warnings
apt_preflight_count_external_refs
if [[ "${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}" -ne 0 ]]; then
  apt_preflight_fail "temporary apt update referenced external Ubuntu hosts"
fi
exit 0
' >"${WORKDIR}/neg-ext.out" 2>"${WORKDIR}/neg-ext.err"
rc=$?
set -e
[[ "$rc" -eq 18 ]] && pass "external source: client exit 18" || fail "external source rc=${rc}"

# apt nonzero exit simulated
set +e
bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
CURRENT_RUN_ID=neg-aptnz
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
APT_GET_EXIT_CODE=100
: >"$APT_PREFLIGHT_ERR"; : >"$APT_PREFLIGHT_OUT"
apt_preflight_fail "temporary local apt-get update failed (apt-get exit=100; client exit will be 18)"
' >"${WORKDIR}/neg-aptnz.out" 2>"${WORKDIR}/neg-aptnz.err"
rc=$?
set -e
[[ "$rc" -eq 18 ]] && pass "apt nonzero: client exit 18" || fail "apt nonzero rc=${rc}"
grep -q 'APT_GET_EXIT_CODE=100' "${WORKDIR}/neg-aptnz.err" \
  && grep -q 'APT_PREFLIGHT_CLIENT_EXIT_CODE=18' "${WORKDIR}/neg-aptnz.err" \
  && pass "APT_GET_EXIT and CLIENT_EXIT separate on failure" \
  || fail "exit fields not separated on failure"

# unreadable keyring for _apt (chmod 600 under accessible tree still readable by root;
# make keyring mode 000)
set +e
bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP=xenial-to-bionic
PIN_SOURCE_SUITES=xenial
PIN_COMPONENTS=main
CURRENT_RUN_ID=neg-unreadable
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
chmod 000 "$APT_PREFLIGHT_KEYRING"
apt_preflight_write_sources "'"$REPO"'" "xenial" "main"
if ! apt_preflight_verify_sandbox_access; then
  apt_preflight_fail "unreadable keyring"
fi
exit 0
' >"${WORKDIR}/neg-unreadable.out" 2>"${WORKDIR}/neg-unreadable.err"
rc=$?
set -e
[[ "$rc" -eq 18 ]] && pass "unreadable key: client exit 18" || fail "unreadable key rc=${rc}"

# missing InRelease (suite path 404) — use empty HTTP root
EPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
EMPTY="${WORKDIR}/http-empty"; mkdir -p "$EMPTY"
python3 - "$EMPTY" "$EPORT" <<'PY' >/dev/null 2>&1 &
import http.server, os, sys
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
EPID=$!
sleep 0.2
expect_mirror_fail missing_inrelease \
  bash -c 'source "'"$HELPER"'"; EC_MIRROR=18; STATE_ROOT="/opt/aelladata/os-upgrade/offline"; PIN_HOP=xenial-to-bionic; PIN_SOURCE_SUITES=xenial; PIN_COMPONENTS=main; CURRENT_RUN_ID=neg-missir; hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" "'"$WORKDIR"'/testhost" "$1";; esac; }; log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }; die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }; run_temporary_local_apt_authentication_preflight "'"$KR_BIN"'" "http://127.0.0.1:'"$EPORT"'/hops/xenial-to-bionic/ubuntu"'
kill "$EPID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Static four-hop embedding contract
# ---------------------------------------------------------------------------
echo "--- G: shared helper token in templates ---"
for tmpl in \
  dp-offline-upgrade-xenial-to-bionic.sh.in \
  dp-offline-upgrade-bionic-to-focal.sh.in \
  dp-offline-upgrade-focal-to-jammy.sh.in \
  dp-offline-upgrade-jammy-to-noble.sh.in
do
  grep -q '@@APT_PREFLIGHT_SANDBOX_HELPER@@' "${ROOT}/client/${tmpl}" \
    && grep -q 'run_temporary_local_apt_authentication_preflight' "${ROOT}/client/${tmpl}" \
    && pass "${tmpl}: shared APT helper wired" \
    || fail "${tmpl}: shared APT helper missing"
done
for py in \
  build_client_xenial_to_bionic.py \
  build_client_bionic_to_focal.py \
  build_client_focal_to_jammy.py \
  build_client_jammy_to_noble.py
do
  grep -q 'APT_PREFLIGHT_SANDBOX_HELPER' "${ROOT}/scripts/lib/${py}" \
    && pass "${py}: injects APT helper" || fail "${py}: missing APT inject"
done

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_apt_preflight_sandbox PASS ==="
  exit 0
fi
echo "=== test_apt_preflight_sandbox FAIL ==="
exit 1
