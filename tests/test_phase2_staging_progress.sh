#!/usr/bin/env bash
# Targeted contracts for Phase 2 staging progress and no-mutation diagnosis.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRESS="${ROOT}/client/lib/dp-phase2-operation-progress.sh"
STAGE="${ROOT}/client/stage-dp-phase2.sh"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
expect_fail() { "$@" && fail "unexpected success: $*" || true; }

export DP_PHASE2_HEARTBEAT_SECONDS=1
# shellcheck source=/dev/null
source "$PROGRESS"
# Verify the stage implementation remains loadable without starting its main path.
export DP_PHASE2_STAGE_LIB_ONLY=1
# shellcheck source=/dev/null
source "$STAGE"

echo "=== test_phase2_staging_progress ==="

HB_OUT="${TMP}/heartbeat.out"
set +e
dp2_run_with_heartbeat test-heartbeat 'https://user:secret@example.invalid/a?token=secret' -- \
  bash -c 'sleep 2; exit 17' >"$HB_OUT" 2>&1
RC=$?
set -e
[[ "$RC" -eq 17 ]] || fail "heartbeat did not preserve failure rc (got ${RC})"
grep -q '^OPERATION_START name=test-heartbeat target=https://example.invalid/a$' "$HB_OUT" \
  || { cat "$HB_OUT"; fail "sanitized START missing"; }
grep -q '^OPERATION_PROGRESS name=test-heartbeat ' "$HB_OUT" || fail "PROGRESS missing"
grep -q '^OPERATION_END name=test-heartbeat rc=17 ' "$HB_OUT" || fail "END with failure rc missing"
if pgrep -f "dp2-hb-stop\." >/dev/null 2>&1; then
  fail "orphan heartbeat process remains"
fi
pass "heartbeat emits lifecycle records and preserves rc"

[[ "$(dp2_progress_sanitize_target 'https://name:password@mirror.example/file?sig=private')" == \
   "https://mirror.example/file" ]] || fail "URL sanitization leaked query or credentials"
pass "sensitive URL fields are stripped"

# A throttled local HTTP curl transfer produces observable byte growth even
# when total is UNKNOWN.
SRC="${TMP}/payload.bin"
DST="${TMP}/download.bin"
PORT_FILE="${TMP}/port"
dd if=/dev/zero of="$SRC" bs=1M count=2 status=none
python3 - "$TMP" "$PORT_FILE" <<'PY' &
import http.server
import os
import socketserver
import sys
import time

root, port_file = sys.argv[1:]
os.chdir(root)

class SlowHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass
    def copyfile(self, source, outputfile):
        while True:
            chunk = source.read(65536)
            if not chunk:
                return
            outputfile.write(chunk)
            outputfile.flush()
            time.sleep(0.08)

with socketserver.TCPServer(("127.0.0.1", 0), SlowHandler) as server:
    with open(port_file, "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
PY
SERVER_PID=$!
for _ in $(seq 1 20); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
[[ -s "$PORT_FILE" ]] || fail "slow HTTP server did not start"
DL_OUT="${TMP}/download.out"
dp2_run_download_with_progress download-test FULL "$DST" UNKNOWN \
  curl --fail --silent --show-error --output "$DST" "http://127.0.0.1:$(<"$PORT_FILE")/payload.bin" >"$DL_OUT" 2>&1 \
  || { cat "$DL_OUT"; fail "local curl download"; }
grep -Eq '^OPERATION_PROGRESS name=download-test .*bytes_downloaded=[1-9][0-9]* .*bytes_total=UNKNOWN ' "$DL_OUT" \
  || { cat "$DL_OUT"; fail "download byte progress missing"; }
grep -q '^DOWNLOAD_RESULT=PASS$' "$DL_OUT" || fail "download PASS missing"
cmp -s "$SRC" "$DST" || fail "download content differs"
pass "download progress reports increasing bytes with UNKNOWN total"

# Source resolution happens before download/artifact mutations.  Calling the
# stage resolver directly exercises the same diagnose-source-version path.
SOURCE_PRODUCT_ENV="${TMP}/missing-source.env"
SOURCE_PRODUCT_PHASE1_LOG_DEFAULT="${TMP}/missing-phase1.log"
SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT="${TMP}/missing-release.yml"
SOURCE_PRODUCT_OS_STATE_FILE="${TMP}/missing-state"
export SOURCE_PRODUCT_ENV SOURCE_PRODUCT_PHASE1_LOG_DEFAULT SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT SOURCE_PRODUCT_OS_STATE_FILE
BUNDLE_DOWNLOAD_ATTEMPTED=NO
ARTIFACT_MUTATION_ATTEMPTED=NO
expect_fail spv_resolve_source_dp_version "$SOURCE_PRODUCT_ENV" "$SOURCE_PRODUCT_PHASE1_LOG_DEFAULT" \
  "$SOURCE_PRODUCT_RELEASE_IMAGE_DEFAULT" "" 0 diagnose 1
[[ "$BUNDLE_DOWNLOAD_ATTEMPTED" == NO ]] || fail "source resolution attempted bundle download"
[[ "$ARTIFACT_MUTATION_ATTEMPTED" == NO ]] || fail "source resolution mutated artifacts"
pass "source diagnosis fails before staging mutation"

echo "TEST_PHASE2_STAGING_PROGRESS=PASS"
