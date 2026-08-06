#!/usr/bin/env bash
# Regression: dp2_run_extract_with_progress accepts the same optional `--`
# separator contract as dp2_run_with_heartbeat and preserves child exit status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROGRESS="${ROOT}/client/lib/dp-phase2-operation-progress.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export DP_PHASE2_HEARTBEAT_SECONDS=1
# shellcheck source=/dev/null
source "$PROGRESS"

OUT="${TMP}/extract.out"
DEST="${TMP}/extract"
mkdir -p "$DEST"

dp2_run_extract_with_progress phase2-tar-extract "$DEST" -- \
  bash -c 'mkdir -p "$1/sub"; dd if=/dev/zero of="$1/sub/payload.bin" bs=1024 count=4 status=none; sleep 2' \
  _ "$DEST" >"$OUT" 2>&1

grep -q '^OPERATION_START name=phase2-tar-extract target=' "$OUT"
grep -q '^OPERATION_PROGRESS name=phase2-tar-extract ' "$OUT"
grep -q '^OPERATION_END name=phase2-tar-extract rc=0 ' "$OUT"
test -s "$DEST/sub/payload.bin"
! grep -q -- '^--: command not found$' "$OUT"

FAIL_OUT="${TMP}/extract-fail.out"
set +e
dp2_run_extract_with_progress phase2-tar-extract-fail "$DEST" -- \
  bash -c 'exit 23' >"$FAIL_OUT" 2>&1
RC=$?
set -e
[[ "$RC" -eq 23 ]]
grep -q '^OPERATION_END name=phase2-tar-extract-fail rc=23 ' "$FAIL_OUT"

# Backward compatibility: callers without the optional separator still work.
NOSEP_OUT="${TMP}/extract-nosep.out"
dp2_run_extract_with_progress phase2-tar-extract-nosep "$DEST" \
  bash -c 'printf ok >"$1/nosep.txt"' _ "$DEST" >"$NOSEP_OUT" 2>&1
grep -q '^OPERATION_END name=phase2-tar-extract-nosep rc=0 ' "$NOSEP_OUT"
grep -q '^ok$' "$DEST/nosep.txt"

# Empty command fails closed instead of attempting to execute an empty argv.
EMPTY_OUT="${TMP}/extract-empty.out"
set +e
dp2_run_extract_with_progress phase2-tar-extract-empty "$DEST" -- \
  >"$EMPTY_OUT" 2>&1
EMPTY_RC=$?
set -e
[[ "$EMPTY_RC" -eq 2 ]]
grep -q '^OPERATION_END name=phase2-tar-extract-empty rc=2 elapsed_seconds=0$' "$EMPTY_OUT"

echo 'PHASE2_EXTRACT_SEPARATOR=PASS'
echo 'PHASE2_EXTRACT_EXIT_STATUS=PASS'
echo 'PHASE2_EXTRACT_EMPTY_COMMAND=PASS'
