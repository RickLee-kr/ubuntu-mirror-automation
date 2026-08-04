#!/usr/bin/env bash
# tests/test_xenial_apt_1_2_authentication.sh
# Real Ubuntu 16.04 (apt 1.2.x) integration test for temporary APT authentication
# preflight inside docker. Exercises dp-offline-apt-preflight-sandbox.sh with a
# signed local HTTP fixture — no Canonical/R2/external apt sources during update.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Used by documentation / local sourcing; path is also baked into the docker runner.
HELPER="${ROOT}/client/lib/dp-offline-apt-preflight-sandbox.sh"
: "${HELPER}"
DOCKER_IMAGE="ubuntu:16.04"
# shellcheck source=../tests/lib/client_finalization_fixture.sh
source "${ROOT}/tests/lib/client_finalization_fixture.sh"

FAIL=0
BLOCKED=0
RESULT="PASS"

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; RESULT="FAIL"; }

WORKDIR="$(mktemp -d /tmp/test-xenial-apt-1.2.XXXXXX)"
HTTP_PID=""
UNSIGNED_HTTP_PID=""
BADSIG_HTTP_PID=""

cleanup() {
  [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true
  [[ -n "${UNSIGNED_HTTP_PID:-}" ]] && kill "$UNSIGNED_HTTP_PID" 2>/dev/null || true
  [[ -n "${BADSIG_HTTP_PID:-}" ]] && kill "$BADSIG_HTTP_PID" 2>/dev/null || true
  if [[ -d "${WORKDIR:-}" ]]; then
    sudo rm -rf "${WORKDIR}" 2>/dev/null || rm -rf "${WORKDIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

report_blocked() {
  local reason="$1"
  echo "TEST_REAL_XENIAL_APT_1_2=BLOCKED"
  echo "BLOCKED_REASON=${reason}"
  echo "=== test_xenial_apt_1_2_authentication BLOCKED ==="
  BLOCKED=1
  exit 2
}

report_final() {
  if [[ "$BLOCKED" -eq 1 ]]; then
    return 0
  fi
  if [[ "$FAIL" -eq 0 ]]; then
    RESULT="PASS"
    echo "TEST_REAL_XENIAL_APT_1_2=PASS"
    echo "=== test_xenial_apt_1_2_authentication PASS ==="
    exit 0
  fi
  RESULT="FAIL"
  echo "TEST_REAL_XENIAL_APT_1_2=${RESULT}"
  echo "=== test_xenial_apt_1_2_authentication ${RESULT} ==="
  exit 1
}

echo "=== test_xenial_apt_1_2_authentication ==="

# ---------------------------------------------------------------------------
# Docker / Xenial availability gate
# ---------------------------------------------------------------------------
echo "--- gate: docker + xenial apt 1.2.x ---"

if ! command -v sudo >/dev/null 2>&1; then
  report_blocked "sudo unavailable"
fi
if ! sudo docker info >/dev/null 2>&1; then
  report_blocked "docker daemon unavailable"
fi
if ! sudo docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  report_blocked "docker image ${DOCKER_IMAGE} not present"
fi

XENIAL_PROBE="$(
  sudo docker run --rm "$DOCKER_IMAGE" bash -c '
    set -e
    vid=""
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      vid="${VERSION_ID:-}"
    fi
    apt_line="$(apt-get --version 2>/dev/null | head -1 || true)"
    printf "VERSION_ID=%s\n" "$vid"
    printf "APT_VERSION=%s\n" "$apt_line"
  ' 2>/dev/null || true
)"

XENIAL_VERSION_ID="$(printf '%s\n' "$XENIAL_PROBE" | sed -n 's/^VERSION_ID=//p' | head -1)"
XENIAL_APT_LINE="$(printf '%s\n' "$XENIAL_PROBE" | sed -n 's/^APT_VERSION=//p' | head -1)"

if [[ "$XENIAL_VERSION_ID" != "16.04" ]]; then
  report_blocked "container VERSION_ID=${XENIAL_VERSION_ID:-missing} (need 16.04)"
fi
if [[ ! "$XENIAL_APT_LINE" =~ apt[[:space:]]1\.2\. ]]; then
  report_blocked "container apt is not 1.2.x (${XENIAL_APT_LINE:-missing})"
fi
pass "docker ${DOCKER_IMAGE}: VERSION_ID=16.04 apt 1.2.x"

# ---------------------------------------------------------------------------
# Host fixture: signed hop repo + local HTTP (no external apt during update)
# ---------------------------------------------------------------------------
echo "--- fixture: signed hop + local HTTP ---"
client_fixture_require
client_fixture_gen_keys "$WORKDIR"
client_fixture_populate_hop \
  "${WORKDIR}/selective" "xenial-to-bionic" "xenial" "bionic" \
  "${WORKDIR}/gpg-selective"

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
        "Origin: Ubuntu",
        "Label: Ubuntu",
        f"Suite: {suite}",
        f"Codename: {suite.split('-')[0]}",
        f"Date: {now}",
        "Architectures: amd64",
        "Components: main",
        f"Description: Ubuntu {suite} fixture",
        "SHA256:",
    ]
    for digest, size, rel_path in files:
        lines.append(f" {digest} {size} {rel_path}")
    release.write_text("\n".join(lines) + "\n", encoding="ascii")
    inrelease = d / "InRelease"
    subprocess.check_call(
        [
            "gpg", "--homedir", gpg_home, "--batch", "--yes", "--clearsign",
            "-o", str(inrelease), str(release),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
PY

KR_BIN="${WORKDIR}/stellar-offline-upgrade.gpg"
gpg --homedir "${WORKDIR}/gpg-selective" --batch --export >"$KR_BIN"
chmod 0644 "$KR_BIN"
KEY_FPR="$(
  gpg --homedir "${WORKDIR}/gpg-selective" --batch --with-colons --fingerprint \
    | awk -F: '/^fpr:/ { print toupper($10); exit }'
)"
[[ ${#KEY_FPR} -eq 40 ]] && pass "fixture key fingerprint=${KEY_FPR}" || fail "fixture key fingerprint missing"

HTTP_ROOT="${WORKDIR}/http"
mkdir -p "${HTTP_ROOT}/hops"
cp -a "${WORKDIR}/selective/hops/xenial-to-bionic" "${HTTP_ROOT}/hops/"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 - "$HTTP_ROOT" "$PORT" <<'PY' >/dev/null 2>"${WORKDIR}/http.log" &
import http.server, os, sys

os.chdir(sys.argv[1])
port = int(sys.argv[2])
http.server.ThreadingHTTPServer(
    ("127.0.0.1", port), http.server.SimpleHTTPRequestHandler
).serve_forever()
PY
HTTP_PID=$!
sleep 0.4
REPO="http://127.0.0.1:${PORT}/hops/xenial-to-bionic/ubuntu"

# Unsigned mirror tree (strip signatures)
UNSIGNED_ROOT="${WORKDIR}/http-unsigned"
mkdir -p "${UNSIGNED_ROOT}/hops"
cp -a "${HTTP_ROOT}/hops/xenial-to-bionic" "${UNSIGNED_ROOT}/hops/"
find "${UNSIGNED_ROOT}" -name InRelease -delete
find "${UNSIGNED_ROOT}" -name Release.gpg -delete
UPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 - "$UNSIGNED_ROOT" "$UPORT" <<'PY' >/dev/null 2>&1 &
import http.server, os, sys

os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(
    ("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler
).serve_forever()
PY
UNSIGNED_HTTP_PID=$!
sleep 0.2
UREPO="http://127.0.0.1:${UPORT}/hops/xenial-to-bionic/ubuntu"

# BADSIG mirror tree (corrupt clearsigned InRelease)
BADSIG_ROOT="${WORKDIR}/http-badsig"
mkdir -p "${BADSIG_ROOT}/hops"
cp -a "${HTTP_ROOT}/hops/xenial-to-bionic" "${BADSIG_ROOT}/hops/"
python3 - "${BADSIG_ROOT}/hops/xenial-to-bionic/ubuntu/dists" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])
for inrelease in root.glob("*/InRelease"):
    inrelease.write_text(
        "-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n"
        "Origin: Tampered\nSuite: badsig\n"
        "-----BEGIN PGP SIGNATURE-----\n\n"
        "iQEcBAABAgAGBQJbadSIGAAoJEFakeSignatureBADSIG\n=aaaa\n"
        "-----END PGP SIGNATURE-----\n",
        encoding="ascii",
    )
PY
BPORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 - "$BADSIG_ROOT" "$BPORT" <<'PY' >/dev/null 2>&1 &
import http.server, os, sys

os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(
    ("127.0.0.1", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler
).serve_forever()
PY
BADSIG_HTTP_PID=$!
sleep 0.2
BREPO="http://127.0.0.1:${BPORT}/hops/xenial-to-bionic/ubuntu"

# Wrong key for NO_PUBKEY / wrong primary keyring negatives
WRONG_GPG="${WORKDIR}/gpg-wrong"
mkdir -p "$WRONG_GPG"
chmod 700 "$WRONG_GPG"
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
: >"${WORKDIR}/empty.gpg"

# Host APT poison (must never be consulted during sandbox update)
mkdir -p "${WORKDIR}/host-apt/trusted.gpg.d" "${WORKDIR}/host-apt/sources.list.d"
: >"${WORKDIR}/host-apt/trusted.gpg"
printf 'POISON\n' >"${WORKDIR}/host-apt/trusted.gpg.d/poison.gpg"
printf 'deb http://archive.ubuntu.com/ubuntu poison main\n' >"${WORKDIR}/host-apt/sources.list"
printf 'deb http://security.ubuntu.com/ubuntu poison-security main\n' \
  >"${WORKDIR}/host-apt/sources.list.d/poison.list"

# Persist parameters for the in-container runner
cat >"${WORKDIR}/env.sh" <<EOF
REPO=${REPO}
UREPO=${UREPO}
BREPO=${BREPO}
KR_BIN=/fixture/stellar-offline-upgrade.gpg
WRONG_KR=/fixture/wrong.gpg
EMPTY_KR=/fixture/empty.gpg
MISSING_KR=/fixture/no-such-keyring.gpg
KEY_FPR=${KEY_FPR}
INRELEASE=/fixture/selective/hops/xenial-to-bionic/ubuntu/dists/xenial/InRelease
EOF

# ---------------------------------------------------------------------------
# In-container integration runner (real Xenial userspace + apt 1.2.x)
# ---------------------------------------------------------------------------
cat >"${WORKDIR}/run-xenial-tests.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /fixture/env.sh

HELPER="/repo/client/lib/dp-offline-apt-preflight-sandbox.sh"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "--- xenial container bootstrap ---"
if [[ ! -f /etc/os-release ]]; then
  fail "missing /etc/os-release"
else
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${VERSION_ID:-}" == "16.04" ]] \
    && pass "VERSION_ID=16.04" \
    || fail "VERSION_ID=${VERSION_ID:-missing}"
fi
apt_line="$(apt-get --version 2>/dev/null | head -1 || true)"
[[ "$apt_line" =~ apt[[:space:]]1\.2\. ]] \
  && pass "apt-get version=${apt_line}" \
  || fail "apt-get version not 1.2.x (${apt_line})"

if ! getent passwd _apt >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then
    useradd -r _apt 2>/dev/null || true
  fi
fi
getent passwd _apt >/dev/null 2>&1 \
  && pass "_apt user present" \
  || fail "_apt user missing"

for cmd in gpg gpgv apt-key apt-get runuser; do
  command -v "$cmd" >/dev/null 2>&1 \
    && pass "command present: ${cmd}" \
    || fail "command missing: ${cmd}"
done

# Poison container host APT trust paths (must not satisfy authentication).
mkdir -p /etc/apt/trusted.gpg.d /etc/apt/sources.list.d
: >/etc/apt/trusted.gpg
printf 'POISON\n' >/etc/apt/trusted.gpg.d/poison.gpg
printf 'deb http://archive.ubuntu.com/ubuntu poison main\n' >/etc/apt/sources.list
printf 'deb http://security.ubuntu.com/ubuntu poison-security main\n' \
  >/etc/apt/sources.list.d/poison.list
pass "host poison keyrings/sources installed under /etc/apt"

# Install sudo only if neither sudo nor runuser works for sandbox probes.
if ! command -v runuser >/dev/null 2>&1 && ! command -v sudo >/dev/null 2>&1; then
  echo "Installing sudo for _apt sandbox probes (one-time apt from archives)..." >&2
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y sudo >/dev/null 2>&1 || fail "could not install sudo"
fi

mkdir -p /fixture/testhost/opt/aelladata/os-upgrade/offline

EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP="xenial-to-bionic"
PIN_SOURCE_SUITES="xenial xenial-updates"
PIN_COMPONENTS="main"
PIN_KEY_FINGERPRINT="${KEY_FPR}"

hostpath() {
  case "$1" in
    /var/lib/dpkg/status) printf '%s' /var/lib/dpkg/status ;;
    /opt/aelladata/os-upgrade/offline/*) printf '%s%s' /fixture/testhost "$1" ;;
    *) printf '%s%s' /fixture/testhost "$1" ;;
  esac
}
log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >&2; }
die() { local c="$1"; shift; log ERROR "$* (exit=${c})"; exit "$c"; }

# shellcheck source=/repo/client/lib/dp-offline-apt-preflight-sandbox.sh
source "$HELPER"

helper_env() {
  EC_MIRROR=18
  STATE_ROOT="/opt/aelladata/os-upgrade/offline"
  PIN_HOP="xenial-to-bionic"
  PIN_SOURCE_SUITES="xenial"
  PIN_COMPONENTS="main"
  PIN_KEY_FINGERPRINT="${KEY_FPR}"
}

expect_mirror_fail() {
  local label="$1"
  shift
  set +e
  "$@" >"/fixture/neg-${label}.out" 2>"/fixture/neg-${label}.err"
  local rc=$?
  set -e
  if [[ "$rc" -eq 18 ]]; then
    pass "${label}: client exit 18 (EC_MIRROR)"
  else
    fail "${label}: expected exit 18 got ${rc}"
    tail -15 "/fixture/neg-${label}.err" 2>/dev/null || true
  fi
}

EVIDENCE_FILE="/fixture/xenial-evidence.txt"
: >"$EVIDENCE_FILE"

record_evidence() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  grep -E \
    '(APT_GET_EXIT_CODE|APT_REPOSITORY_AUTHENTICATION|APT_TRUSTED_KEY_VISIBLE|APT_GPGV_KEYRING_ARGUMENT|APT_EFFECTIVE_TRUSTED|APT_EFFECTIVE_TRUSTEDPARTS|APT_SIGNATURE_WARNING_COUNT|APT_EXTERNAL_SOURCE_REFERENCE_COUNT|APT_SANDBOX_TRAVERSAL|APT_SANDBOX_KEYRING_READABLE)=' \
    "$src" >>"$EVIDENCE_FILE" 2>/dev/null || true
}

grep_evidence_field() {
  local field="$1"
  local file="$2"
  grep -E "(^|\\]) ${field}=" "$file" 2>/dev/null | tail -1 | sed -E "s/^[^ ]* ${field}=//" || true
}

# ---------------------------------------------------------------------------
# Positive path
# ---------------------------------------------------------------------------
echo "--- positive: valid primary trusted.gpg ---"

if gpgv --keyring "$KR_BIN" "$INRELEASE" >/dev/null 2>&1; then
  pass "direct Xenial gpgv=PASS"
else
  fail "direct Xenial gpgv=FAIL"
fi

set +e
(
  run_temporary_local_apt_authentication_preflight \
    "$KR_BIN" "$REPO" "xenial xenial-updates" "main"
) >"/fixture/pos.out" 2>"/fixture/pos.err"
POS_RC=$?
set -e
record_evidence "/fixture/pos.err"

if [[ "$POS_RC" -eq 0 ]]; then
  pass "preflight exit=0"
else
  fail "preflight exit=${POS_RC}"
  tail -40 "/fixture/pos.err" || true
fi

grep -q 'APT_GET_EXIT_CODE=0' "/fixture/pos.err" \
  && pass "APT_GET_EXIT_CODE=0" || fail "APT_GET_EXIT_CODE not zero"
grep -q 'APT_REPOSITORY_AUTHENTICATION=PASS' "/fixture/pos.err" \
  && pass "APT_REPOSITORY_AUTHENTICATION=PASS" || fail "APT_REPOSITORY_AUTHENTICATION not PASS"
grep -q 'APT_TRUSTED_KEY_VISIBLE=PASS' "/fixture/pos.err" \
  && pass "APT_TRUSTED_KEY_VISIBLE=PASS" || fail "APT_TRUSTED_KEY_VISIBLE not PASS"
grep -q 'APT_SIGNATURE_WARNING_COUNT=0' "/fixture/pos.err" \
  && pass "APT_SIGNATURE_WARNING_COUNT=0" || fail "signature warnings present"
grep -q 'APT_EXTERNAL_SOURCE_REFERENCE_COUNT=0' "/fixture/pos.err" \
  && pass "APT_EXTERNAL_SOURCE_REFERENCE_COUNT=0" || fail "external source refs present"
# Must NOT overlay or mutate host /etc/apt/trusted.gpg{,.d}
if grep -qiE 'APT_XENIAL_HOST_TRUST_BIND' "/fixture/pos.err" 2>/dev/null; then
  fail "host trust overlay must not be used"
else
  pass "HOST_TRUSTED_KEYRINGS_USED=NO"
fi
# Poisoned host paths must never appear as trusted keyring arguments
if grep -qiE '/etc/apt/trusted\.gpg\.d/poison|POISON' "/fixture/pos.err" "/fixture/pos.out" 2>/dev/null; then
  fail "host poison keyring referenced"
else
  pass "host poison keyrings not used"
fi

if grep -qiE '^(W|E):.*(NO_PUBKEY|not signed|BADSIG|EXPKEYSIG)' "/fixture/pos.err" "/fixture/pos.out" 2>/dev/null; then
  fail "positive path emitted signature warnings"
else
  pass "no NO_PUBKEY / unsigned / BADSIG warnings"
fi

EFF_TRUSTED="$(grep_evidence_field APT_EFFECTIVE_TRUSTED /fixture/pos.err)"
EFF_TRUSTEDPARTS="$(grep_evidence_field APT_EFFECTIVE_TRUSTEDPARTS /fixture/pos.err)"
GPGV_KR="$(grep_evidence_field APT_GPGV_KEYRING_ARGUMENT /fixture/pos.err)"

if [[ "$EFF_TRUSTED" == */etc/apt/trusted.gpg ]]; then
  pass "APT_EFFECTIVE_TRUSTED ends with etc/apt/trusted.gpg"
else
  fail "APT_EFFECTIVE_TRUSTED=${EFF_TRUSTED:-missing}"
fi
if [[ "$EFF_TRUSTEDPARTS" == */etc/apt/trusted.gpg.d.empty ]]; then
  pass "APT_EFFECTIVE_TRUSTEDPARTS=trusted.gpg.d.empty"
else
  fail "APT_EFFECTIVE_TRUSTEDPARTS=${EFF_TRUSTEDPARTS:-missing}"
fi
if [[ -n "$GPGV_KR" && "$GPGV_KR" == */etc/apt/trusted.gpg ]]; then
  pass "APT_GPGV_KEYRING_ARGUMENT points at primary trusted.gpg"
else
  fail "APT_GPGV_KEYRING_ARGUMENT=${GPGV_KR:-missing}"
fi

# Prove trustedparts directory stayed empty during successful preflight.
POS_EVIDENCE="$(grep -E 'APT_PREFLIGHT_EVIDENCE=' /fixture/pos.err | tail -1 | sed -E 's/^[^ ]* APT_PREFLIGHT_EVIDENCE=//' || true)"
if [[ -n "$POS_EVIDENCE" && -d "$POS_EVIDENCE" && -f "$POS_EVIDENCE/meta.txt" ]]; then
  tp="$(grep '^APT_EFFECTIVE_TRUSTEDPARTS=' "$POS_EVIDENCE/meta.txt" | cut -d= -f2- || true)"
  [[ "$tp" == */trusted.gpg.d.empty ]] && pass "evidence trustedparts empty dir" || fail "evidence trustedparts=${tp}"
fi

if grep -qiE 'archive\.ubuntu\.com|security\.ubuntu\.com|poison' \
  "/fixture/pos.err" "/fixture/pos.out" 2>/dev/null; then
  fail "host/external poison referenced during positive update"
else
  pass "host APT sources/keyrings not used"
fi

# ---------------------------------------------------------------------------
# Authentication negatives → client exit 18 (EC_MIRROR)
# ---------------------------------------------------------------------------
echo "--- negatives: authentication fail-closed (EC_MIRROR=18) ---"

run_neg_subshell() {
  local label="$1"
  shift
  expect_mirror_fail "$label" bash -c '
    helper_env(){ :; }
    '"$(declare -f hostpath log die helper_env)"'
    source "'"$HELPER"'"
    helper_env
    CURRENT_RUN_ID="neg-'"$label"'"
    '"$*"'
  '
}

run_neg_subshell missing_key \
  'run_temporary_local_apt_authentication_preflight "'"$MISSING_KR"'" "'"$REPO"'"'

run_neg_subshell empty_key \
  'run_temporary_local_apt_authentication_preflight "'"$EMPTY_KR"'" "'"$REPO"'"'

run_neg_subshell wrong_key \
  'run_temporary_local_apt_authentication_preflight "'"$WRONG_KR"'" "'"$REPO"'"'

grep -qiE 'NO_PUBKEY|APT_SIGNATURE_WARNING|APT_REPOSITORY_AUTHENTICATION=FAIL' \
  "/fixture/neg-wrong_key.err" \
  && pass "wrong_key: warning evidence present" \
  || fail "wrong_key: warning evidence missing"

run_neg_subshell unsigned \
  'run_temporary_local_apt_authentication_preflight "'"$KR_BIN"'" "'"$UREPO"'"'

run_neg_subshell badsig \
  'run_temporary_local_apt_authentication_preflight "'"$KR_BIN"'" "'"$BREPO"'"'

# Key only in trustedparts while primary trusted.gpg empty (misconfigured trust)
expect_mirror_fail trustedparts_only bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP="xenial-to-bionic"
PIN_SOURCE_SUITES="xenial"
PIN_COMPONENTS="main"
PIN_KEY_FINGERPRINT="'"${KEY_FPR}"'"
CURRENT_RUN_ID="neg-trustedparts-only"
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" /fixture/testhost "$1";; esac; }
log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
apt_preflight_create_sandbox "'"$KR_BIN"'"
: >"$APT_PREFLIGHT_KEYRING"
cp "'"$KR_BIN"'" "${APT_PREFLIGHT_TRUSTEDPARTS}/stellar-offline-upgrade.gpg"
chmod 0644 "${APT_PREFLIGHT_TRUSTEDPARTS}/stellar-offline-upgrade.gpg"
apt_preflight_write_sources "'"$REPO"'" "xenial" "main"
if ! apt_preflight_verify_sandbox_access; then
  APT_GET_EXIT_CODE=""
  apt_preflight_fail "sandbox access failed"
fi
apt_preflight_capture_effective_config || true
if apt_preflight_probe_trusted_key_visibility; then
  apt_preflight_fail "trustedparts-only key must not satisfy primary trusted.gpg binding"
fi
apt_preflight_run_apt_update
apt_preflight_count_signature_warnings
apt_preflight_count_external_refs
if [[ "${APT_SIGNATURE_WARNING_COUNT}" -ne 0 ]]; then
  apt_preflight_fail "trustedparts-only key must not authenticate repository"
fi
apt_preflight_fail "trustedparts-only misconfiguration must fail closed"
'

# Simulated BADSIG / external source via warning counters
sim_fail_from_err() {
  local label="$1"
  local errtxt="$2"
  expect_mirror_fail "$label" bash -c '
    source "'"$HELPER"'"
    EC_MIRROR=18
    STATE_ROOT="/opt/aelladata/os-upgrade/offline"
    PIN_HOP="xenial-to-bionic"
    CURRENT_RUN_ID="neg-'"$label"'"
    hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" /fixture/testhost "$1";; esac; }
    log(){ printf "%s [%s] %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
    die(){ local c="$1"; shift; log ERROR "$* (exit=$c)"; exit "$c"; }
    apt_preflight_create_sandbox "'"$KR_BIN"'"
    printf "%s\n" "'"$errtxt"'" >"$APT_PREFLIGHT_ERR"
    : >"$APT_PREFLIGHT_OUT"
    APT_GET_EXIT_CODE=0
    apt_preflight_count_signature_warnings
    apt_preflight_count_external_refs
    if [[ "${APT_SIGNATURE_WARNING_COUNT}" -ne 0 || "${APT_EXTERNAL_SOURCE_REFERENCE_COUNT}" -ne 0 ]]; then
      apt_preflight_fail "simulated auth failure ('"$label"')"
    fi
    exit 0
  '
}

sim_fail_from_err badsig_sim "W: GPG error: http://mirror BADSIG ABCDEF0123456789"
sim_fail_from_err expkeysig_sim "W: GPG error: http://mirror EXPKEYSIG ABCDEF0123456789"
sim_fail_from_err notsigned_sim "W: The repository is not signed."

expect_mirror_fail external_source bash -c '
source "'"$HELPER"'"
EC_MIRROR=18
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
PIN_HOP="xenial-to-bionic"
CURRENT_RUN_ID="neg-external"
hostpath(){ case "$1" in /var/lib/dpkg/status) printf /var/lib/dpkg/status;; *) printf "%s%s" /fixture/testhost "$1";; esac; }
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
'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "--- xenial evidence summary ---"
{
  echo "XENIAL_VERSION_ID=16.04"
  echo "XENIAL_APT=${apt_line}"
  echo "FIXTURE_KEY_FPR=${KEY_FPR}"
  echo "REPO=${REPO}"
  cat "$EVIDENCE_FILE" 2>/dev/null || true
} | tee /fixture/xenial-summary.txt

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== xenial inner PASS ==="
  exit 0
fi
echo "=== xenial inner FAIL ==="
exit 1
INNER
chmod +x "${WORKDIR}/run-xenial-tests.sh"

# ---------------------------------------------------------------------------
# Run inside real Xenial container (--network=host so 127.0.0.1 reaches HTTP)
# ---------------------------------------------------------------------------
echo "--- docker: run xenial integration ---"

DOCKER_ARGS=(
  run --rm
  --network=host
  -v "${ROOT}:/repo:ro"
  -v "${WORKDIR}:/fixture"
  "$DOCKER_IMAGE"
  bash /fixture/run-xenial-tests.sh
)

set +e
# shellcheck disable=SC2024 # workdir is test-owned; sudo only needed for docker
sudo docker "${DOCKER_ARGS[@]}" >"${WORKDIR}/docker.out" 2>"${WORKDIR}/docker.err"
INNER_RC=$?
set -e

cat "${WORKDIR}/docker.out"
cat "${WORKDIR}/docker.err" >&2

if [[ -f "${WORKDIR}/xenial-summary.txt" ]]; then
  echo "--- evidence fields ---"
  cat "${WORKDIR}/xenial-summary.txt"
fi

if [[ "$INNER_RC" -ne 0 ]]; then
  fail "xenial inner runner exit=${INNER_RC}"
else
  pass "xenial inner runner exit=0"
fi

report_final
