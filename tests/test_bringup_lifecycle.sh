#!/usr/bin/env bash
# Targeted lifecycle state tests: current-run completion, safe monitoring, read-only status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
TMP="$(mktemp -d)"
trap '[[ -n "${WORKER_PID:-}" ]] && kill "$WORKER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
write_file() { printf '%s\n' "$2" >"$1"; }
run_id="current-run"

export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${TMP}/bringup.log"
export PHASE2_BRINGUP_MONITOR_SECONDS=1
# shellcheck source=/dev/null
source "$LIB"

echo "=== test_bringup_lifecycle ==="

cat >"$PHASE2_BRINGUP_LOG_DEFAULT" <<'EOF'
Bringup complete: run this command when installation completes
Note: run this only after the Bringup complete: line is printed
EOF
if p2b_log_has_anchored_completion "$PHASE2_BRINGUP_LOG_DEFAULT"; then
  fail "instructional completion text was accepted"
fi
pass "instructional text is not completion"

# A production-like active worker and IMAGE_IMPORT records remain RUNNING; CLI
# discovery is deliberately deferred during an active run.
p2b_ensure_dir
bash -c 'exec -a bringup-worker sleep 30' &
WORKER_PID=$!
write_file "$(p2b_dir)/state" RUNNING
write_file "$(p2b_dir)/run-id" "$run_id"
write_file "$(p2b_dir)/worker.pid" "$WORKER_PID"
write_file "$(p2b_dir)/worker-start-ticks" "$(awk '{print $22}' "/proc/${WORKER_PID}/stat")"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
cat >"$PHASE2_BRINGUP_LOG_DEFAULT" <<'EOF'
IMAGE_IMPORT_START namespace=k8s.io
IMAGE_IMPORT_PROGRESS namespace=k8s.io progress=5%
IMAGE_IMPORT_PROGRESS namespace=k8s.io progress=53%
EOF
rm -f "$(p2b_dir)/result.env"
p2b_status_snapshot
p2b_print_status >"${TMP}/status.running"
[[ "$BRINGUP_STATE" == RUNNING ]] || fail "running fixture state=${BRINGUP_STATE}"
[[ "$BRINGUP_COMPLETION_SENTINEL" == NOT_PRESENT ]] || fail "unexpected completion sentinel"
[[ "$AELLA_CLI_AVAILABLE" == NOT_CHECKED ]] || fail "CLI was checked while running"
[[ "$IMAGE_IMPORT_PROGRESS" == 53% ]] || fail "image progress=${IMAGE_IMPORT_PROGRESS}"
grep -q '^BRINGUP_RESULT=IN_PROGRESS$' "${TMP}/status.running" || fail "missing IN_PROGRESS"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/status.running" || fail "missing DO_NOT_RUN"
pass "running import status is non-terminal and read-only"

# An exact sentinel and rc=0 for this run represents completion.
cat >"$(p2b_dir)/result.env" <<EOF
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=${run_id}
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
write_file "$(p2b_dir)/state" COMPLETED
p2b_status_snapshot
[[ "$BRINGUP_STATE" == COMPLETED && "$BRINGUP_COMPLETION_SENTINEL" == PASS && "$BRINGUP_EXIT_CODE" == 0 ]] \
  || fail "current exact completion sentinel rejected"
pass "current exact completion sentinel succeeds"

# A prior run's result cannot complete this run.
write_file "$(p2b_dir)/state" RUNNING
write_file "$(p2b_dir)/run-id" new-run
sed -i 's/^BRINGUP_RUN_ID=.*/BRINGUP_RUN_ID=old-run/' "$(p2b_dir)/result.env"
p2b_status_snapshot
[[ "$BRINGUP_COMPLETION_SENTINEL" == NOT_PRESENT ]] || fail "old run sentinel passed current run"
pass "old terminal result is isolated by run id"

# Dead or mismatched workers cannot masquerade as RUNNING.
write_file "$(p2b_dir)/worker.pid" 999999
p2b_status_snapshot
[[ "$BRINGUP_STATE" == STALE_OR_UNKNOWN ]] || fail "stale PID state=${BRINGUP_STATE}"
if p2b_pid_alive_and_matches "$$" pgrep; then
  fail "diagnostic pgrep self-match accepted as worker"
fi
pass "stale and self-matching worker identities are rejected"

# CLI absence is not failure while running, but is a terminal postcondition after
# a genuine completed result.  Override discovery to avoid host package state.
write_file "$(p2b_dir)/state" COMPLETED
write_file "$(p2b_dir)/run-id" completed-run
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=completed-run
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=NO; AELLA_CLI_PATH=""; return 1; }
set +e
p2b_monitor_loop completed-run >"${TMP}/monitor.out" 2>&1
MONITOR_RC=$?
set -e
[[ "$MONITOR_RC" -ne 0 ]] || fail "missing post-completion CLI passed"
grep -q '^BRINGUP_RESULT=FAIL_POSTCONDITION$' "${TMP}/monitor.out" || fail "postcondition failure missing"
grep -q '^BRINGUP_STATE=FAILED$' "${TMP}/monitor.out" || fail "postcondition state missing"
pass "missing CLI is only terminal failure after completion"

# Status/diagnose snapshot has no lifecycle mutation.
before="$(tar -cf - -C "$(p2b_dir)" . | sha256sum | awk '{print $1}')"
p2b_print_status >/dev/null
after="$(tar -cf - -C "$(p2b_dir)" . | sha256sum | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail "status snapshot mutated lifecycle files"
pass "status snapshot is read-only"

echo "TEST_BRINGUP_LIFECYCLE=PASS"
