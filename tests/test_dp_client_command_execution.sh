#!/usr/bin/env bash
# tests/test_dp_client_command_execution.sh
# Execute a generated hop command block against a local HTTP fixture with stubs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
# shellcheck source=../scripts/lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"; [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null || true' EXIT

echo "=== test_dp_client_command_execution ==="

# --- signing fixture ---
GPG_HOME="${WORKDIR}/gnupg"
mkdir -p "$GPG_HOME"
chmod 700 "$GPG_HOME"
cat >"${GPG_HOME}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Command Exec Fixture
Name-Email: cmd-exec@local
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "${GPG_HOME}/batch" >/dev/null 2>&1
PUB="${WORKDIR}/public.gpg"
PRIV="${WORKDIR}/private.gpg"
gpg --homedir "$GPG_HOME" --batch --export --armor >"$PUB"
gpg --homedir "$GPG_HOME" --batch --export-secret-keys --armor >"$PRIV"
FPR="$(local_signing_fingerprint_of "$PUB")"
KR="${WORKDIR}/public-keyring.gpg"
local_signing_build_binary_keyring "$PUB" "$KR"

# --- HTTP fixture tree ---
HTTP_ROOT="${WORKDIR}/http"
HOP="xenial-to-bionic"
SCRIPT="dp-offline-upgrade-${HOP}.sh"
mkdir -p "${HTTP_ROOT}/client/${HOP}"
# Client script content does not matter — sudo/bash are stubbed.
printf '#!/bin/bash\necho REAL_UPGRADE_SHOULD_NOT_RUN\nexit 99\n' \
  >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )
cp "$KR" "${HTTP_ROOT}/client/public-keyring.gpg"
cp "$PUB" "${HTTP_ROOT}/client/public.gpg"
printf '{"hop":"%s","fixture":true}\n' "$HOP" \
  >"${HTTP_ROOT}/client/${HOP}/client-manifest.json"
gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
  -o "${HTTP_ROOT}/client/${HOP}/client-manifest.json.asc" \
  "${HTTP_ROOT}/client/${HOP}/client-manifest.json" >/dev/null 2>&1

# Local HTTP server
PORT=18766
python3 - "$HTTP_ROOT" "$PORT" <<'PY' &
import http.server, os, sys
os.chdir(sys.argv[1])
port = int(sys.argv[2])
http.server.ThreadingHTTPServer(("127.0.0.1", port), http.server.SimpleHTTPRequestHandler).serve_forever()
PY
HTTP_PID=$!
sleep 0.3
MIRROR="http://127.0.0.1:${PORT}"

# Source command generator
LIB="${WORKDIR}/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"

block="$(gui_client_hop_command_block "$MIRROR" "$SCRIPT")"
printf '%s\n' "$block" >"${WORKDIR}/block.sh"

# Workdir for DP-side execution (replaces /home/aella)
DP_HOME="${WORKDIR}/dp-home"
mkdir -p "$DP_HOME"

# Stubs: sudo and gpgv stay real; sudo bash runs stub client counter
STUB_RUNS="${WORKDIR}/stub.runs"
: >"$STUB_RUNS"
STUB_BIN="${WORKDIR}/bin"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/sudo" <<EOF
#!/usr/bin/env bash
# Count upgrade-client invocations only.
if [[ "\${1:-}" == "bash" && "\${2:-}" == "./${SCRIPT}" ]]; then
  echo "\$@" >>"${STUB_RUNS}"
  exit 0
fi
# Allow other sudo uses if any
exec /usr/bin/sudo "\$@"
EOF
chmod +x "${STUB_BIN}/sudo"

# Rewrite cd target in the block for the test home
sed "s|cd /home/aella|cd '${DP_HOME}'|" "${WORKDIR}/block.sh" >"${WORKDIR}/block.run.sh"

run_block() {
  env PATH="${STUB_BIN}:/usr/bin:/bin" bash "${WORKDIR}/block.run.sh"
}

# --- 1) Happy path ---
: >"$STUB_RUNS"
set +e
run_block >"${WORKDIR}/happy.out" 2>"${WORKDIR}/happy.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "full block execution rc=0" || {
  fail "full block execution rc=${rc}"
  cat "${WORKDIR}/happy.err" || true
}
[[ -f "${DP_HOME}/${SCRIPT}" ]] && pass "downloads PASS (script)" || fail "script missing"
[[ -f "${DP_HOME}/public-keyring.gpg" ]] && pass "downloads PASS (keyring)" || fail "keyring missing"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "1" ]] \
  && pass "stub upgrade client executed once" \
  || fail "stub runs=$(wc -l <"$STUB_RUNS")"

# --- 2) Bad signature → 0 stub runs ---
find "$DP_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
printf '{"tampered":true}\n' >"${HTTP_ROOT}/client/${HOP}/client-manifest.json"
# leave old .asc → mismatch
: >"$STUB_RUNS"
set +e
run_block >"${WORKDIR}/badsig.out" 2>"${WORKDIR}/badsig.err"
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] && pass "bad signature fails block" || fail "bad signature should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "SIGNATURE_FAILURE_PREVENTS_UPGRADE_EXECUTION=YES" \
  || fail "stub ran after signature failure"

# restore valid manifest+sig
printf '{"hop":"%s","fixture":true}\n' "$HOP" \
  >"${HTTP_ROOT}/client/${HOP}/client-manifest.json"
gpg --homedir "$GPG_HOME" --batch --yes --detach-sign --armor \
  -o "${HTTP_ROOT}/client/${HOP}/client-manifest.json.asc" \
  "${HTTP_ROOT}/client/${HOP}/client-manifest.json" >/dev/null 2>&1

# --- 3) Corrupt public-keyring → 0 runs ---
find "$DP_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
printf 'CORRUPT\n' >"${HTTP_ROOT}/client/public-keyring.gpg"
: >"$STUB_RUNS"
set +e
run_block >/dev/null 2>&1
kr_rc=$?
set -e
[[ "$kr_rc" -ne 0 ]] && pass "corrupt keyring fails" || fail "corrupt keyring should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "corrupt keyring prevents upgrade" \
  || fail "stub ran with corrupt keyring"
cp "$KR" "${HTTP_ROOT}/client/public-keyring.gpg"

# --- 4) HTTP 404 → 0 runs ---
find "$DP_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -f "${HTTP_ROOT}/client/${SCRIPT}"
: >"$STUB_RUNS"
set +e
run_block >/dev/null 2>&1
miss_rc=$?
set -e
[[ "$miss_rc" -ne 0 ]] && pass "HTTP 404 fails block" || fail "404 should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "HTTP_404_PREVENTS_UPGRADE_EXECUTION=YES" \
  || fail "stub ran after 404"

# --- 5) Missing public-keyring artifact → fail closed ---
# restore script for next checks
printf '#!/bin/bash\necho REAL\n' >"${HTTP_ROOT}/client/${SCRIPT}"
chmod 0755 "${HTTP_ROOT}/client/${SCRIPT}"
( cd "${HTTP_ROOT}/client" && sha256sum "$SCRIPT" >"${SCRIPT}.sha256" )
rm -f "${HTTP_ROOT}/client/public-keyring.gpg"
find "$DP_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
: >"$STUB_RUNS"
set +e
run_block >/dev/null 2>&1
miss_kr_rc=$?
set -e
[[ "$miss_kr_rc" -ne 0 ]] && pass "missing public-keyring fail closed" \
  || fail "missing keyring should fail"
[[ "$(wc -l <"$STUB_RUNS" | tr -d ' ')" == "0" ]] \
  && pass "missing keyring prevents upgrade" \
  || fail "stub ran without keyring"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_dp_client_command_execution PASS ==="
  echo "GENERATED_BLOCK_EXECUTION_TEST=PASS"
  exit 0
fi
echo "=== test_dp_client_command_execution FAIL ==="
exit 1
