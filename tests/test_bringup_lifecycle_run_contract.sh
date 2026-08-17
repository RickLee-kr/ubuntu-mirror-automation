#!/usr/bin/env bash
# Current-run log scoping (P0-B) and coherent completion sentinel (P0-C).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/client/lib/dp-phase2-bringup-lifecycle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
write_file() { printf '%s\n' "$2" >"$1"; }

export PHASE2_BRINGUP_DIR="${TMP}/lifecycle"
export PHASE2_BRINGUP_LOG_DEFAULT="${TMP}/bringup.log"
export PHASE2_BRINGUP_MONITOR_SECONDS=1
# shellcheck source=/dev/null
source "$LIB"

echo "=== test_bringup_lifecycle_run_contract ==="

p2b_ensure_dir
mkdir -p "$(p2b_dir)/lib"
cat >"$(p2b_dir)/lib/dp-phase2-ubuntu-prerequisites.sh" <<'EOF'
dp2_install_phase2_ubuntu_prerequisites() { return 0; }
EOF

# ---------------------------------------------------------------------------
# B1. Historical APT FAIL must not fail a current-run APT PASS
# ---------------------------------------------------------------------------
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
printf 'HIST APT_DEPENDENCY_CHECK=FAIL\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-b1"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VENDOR_B1="${TMP}/vendor-b1.sh"
cat >"$VENDOR_B1" <<'EOF'
#!/usr/bin/env bash
echo "APT_DEPENDENCY_CHECK=PASS stage=current"
exit 0
EOF
chmod +x "$VENDOR_B1"
set +e
( p2b_worker_main "$VENDOR_B1" >/dev/null 2>&1 )
B1_RC=$?
set -e
[[ "$B1_RC" -eq 0 ]] || fail "B1 worker rc=${B1_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "B1 state=$(p2b_read_state)"
grep -q '^BRINGUP_RESULT=PASS$' "$(p2b_dir)/result.env" || fail "B1 result.env not PASS"
pass "B1 historical APT_DEPENDENCY_CHECK=FAIL is ignored"

# ---------------------------------------------------------------------------
# B2. Historical 3/3 must not PASS a current incomplete topology
# ---------------------------------------------------------------------------
p2b_ensure_dir
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\n' >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-b2"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$(p2b_dir)/result.env" "$(p2b_dir)/completion.sentinel" "$(p2b_dir)/state"
VENDOR_B2="${TMP}/vendor-b2.sh"
cat >"$VENDOR_B2" <<'EOF'
#!/usr/bin/env bash
echo "CLUSTER_JOIN_STATE ready=1 expected=3"
exit 0
EOF
chmod +x "$VENDOR_B2"
set +e
( p2b_worker_main "$VENDOR_B2" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
B2_RC=$?
set -e
[[ "$B2_RC" -ne 0 ]] || fail "B2 unexpectedly PASS"
[[ "$(p2b_read_state)" == "FAILED" ]] || fail "B2 state=$(p2b_read_state)"
grep -q 'FAILURE_REASON=CLUSTER_JOIN_INCOMPLETE' "$(p2b_dir)/completion.sentinel" \
  || fail "B2 missing CLUSTER_JOIN_INCOMPLETE"
pass "B2 historical CLUSTER_JOIN_STATE 3/3 does not make current run PASS"

# ---------------------------------------------------------------------------
# B3. Historical Bringup complete is not current-run completion evidence
# ---------------------------------------------------------------------------
printf 'Bringup complete: all nodes ready\nPHASE2_BRINGUP=COMPLETE\n' \
  >"$PHASE2_BRINGUP_LOG_DEFAULT"
offset="$(wc -c <"$PHASE2_BRINGUP_LOG_DEFAULT" | tr -d ' ')"
write_file "$(p2b_dir)/log-start-offset" "$offset"
printf 'still running\n' >>"$PHASE2_BRINGUP_LOG_DEFAULT"
if p2b_log_has_anchored_completion "$PHASE2_BRINGUP_LOG_DEFAULT"; then
  fail "B3 historical Bringup complete was accepted as current-run evidence"
fi
pass "B3 historical Bringup complete marker is not current-run completion"

# ---------------------------------------------------------------------------
# B4. Current-run 3/3 evidence => topology gate PASS
# ---------------------------------------------------------------------------
p2b_ensure_dir
: >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/run-id" "run-b4"
write_file "$(p2b_dir)/target-version" "6.5.0"
write_file "$(p2b_dir)/log-path" "$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/started-at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -f "$(p2b_dir)/result.env" "$(p2b_dir)/completion.sentinel" "$(p2b_dir)/state"
VENDOR_B4="${TMP}/vendor-b4.sh"
cat >"$VENDOR_B4" <<'EOF'
#!/usr/bin/env bash
echo "CLUSTER_JOIN_STATE ready=3 expected=3"
echo "WORKER_ORCHESTRATION=PASS"
exit 0
EOF
chmod +x "$VENDOR_B4"
set +e
( p2b_worker_main "$VENDOR_B4" --worker-ips 192.0.2.10,192.0.2.11 >/dev/null 2>&1 )
B4_RC=$?
set -e
[[ "$B4_RC" -eq 0 ]] || fail "B4 worker rc=${B4_RC}"
[[ "$(p2b_read_state)" == "COMPLETED" ]] || fail "B4 state=$(p2b_read_state)"
grep -q '^BRINGUP_COMPLETION_SENTINEL=PASS$' "$(p2b_dir)/result.env" \
  || fail "B4 sentinel missing"
pass "B4 current-run 3/3 topology gate PASS"

# ---------------------------------------------------------------------------
# B5. Offset past truncated log: no historical reuse, fail-closed
# ---------------------------------------------------------------------------
printf 'CLUSTER_JOIN_STATE ready=3 expected=3\nAPT_DEPENDENCY_CHECK=FAIL\nBringup complete: done\n' \
  >"$PHASE2_BRINGUP_LOG_DEFAULT"
write_file "$(p2b_dir)/log-start-offset" "999999"
set +e
p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null
B5_STREAM=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'CLUSTER_JOIN_STATE ready=3 expected=3'
B5_JOIN=$?
p2b_current_run_log_contains "$PHASE2_BRINGUP_LOG_DEFAULT" 'APT_DEPENDENCY_CHECK=FAIL'
B5_APT=$?
set -e
[[ "$B5_STREAM" -eq 2 ]] || fail "B5 stream rc=${B5_STREAM} expected 2"
[[ "$B5_JOIN" -eq 2 ]] || fail "B5 join contains rc=${B5_JOIN} expected 2"
[[ "$B5_APT" -eq 2 ]] || fail "B5 apt contains rc=${B5_APT} expected 2"
if p2b_log_has_anchored_completion "$PHASE2_BRINGUP_LOG_DEFAULT"; then
  fail "B5 truncated log reused historical completion"
fi
# Cluster evidence cannot be proven current-run => not PASS.
join_ok=0
if p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" >/dev/null \
  && p2b_current_run_log_stream "$PHASE2_BRINGUP_LOG_DEFAULT" \
  | grep -E 'CLUSTER_JOIN_STATE ready=([0-9]+) expected=([0-9]+)' \
  | awk '{
      ready=""; expected="";
      for(i=1;i<=NF;i++){
        if($i ~ /^ready=/){ split($i,a,"="); ready=a[2] }
        if($i ~ /^expected=/){ split($i,b,"="); expected=b[2] }
      }
      if(ready!="" && expected!="" && ready==expected && expected+0>1) ok=1
    }
    END { exit ok?0:1 }'
then
  join_ok=1
fi
[[ "$join_ok" -eq 0 ]] || fail "B5 truncated log reused historical 3/3"
pass "B5 truncated offset fail-closes and does not reuse historical evidence"

# ---------------------------------------------------------------------------
# C1. state=COMPLETED, no result.env => NOT PASS
# ---------------------------------------------------------------------------
p2b_ensure_dir
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c1"
rm -f "$(p2b_dir)/result.env"
p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=YES; AELLA_CLI_PATH=/usr/bin/aella_cli; return 0; }
p2b_print_status >"${TMP}/c1.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c1.status" \
  || fail "C1 result=$(grep ^BRINGUP_RESULT= "${TMP}/c1.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/c1.status" \
  || fail "C1 DO_NOT_RUN missing"
pass "C1 COMPLETED without result.env is NOT PASS"

# ---------------------------------------------------------------------------
# C2. state=COMPLETED, previous run-id result.env sentinel PASS => NOT PASS
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c2-current"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c2-old
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_print_status >"${TMP}/c2.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c2.status" \
  || fail "C2 result=$(grep ^BRINGUP_RESULT= "${TMP}/c2.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/c2.status" \
  || fail "C2 DO_NOT_RUN missing"
pass "C2 previous-run result.env cannot make current run PASS"

# ---------------------------------------------------------------------------
# C3. current run-id, terminal COMPLETED, result PASS, exit 0, sentinel missing
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c3"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c3
BRINGUP_EXIT_CODE=0
EOF
p2b_print_status >"${TMP}/c3.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c3.status" \
  || fail "C3 result=$(grep ^BRINGUP_RESULT= "${TMP}/c3.status")"
pass "C3 COMPLETED without sentinel PASS is NOT PASS"

# ---------------------------------------------------------------------------
# C4. sentinel PASS but exit code != 0 => NOT PASS
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c4"
write_file "$(p2b_dir)/exit-code" "7"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c4
BRINGUP_EXIT_CODE=7
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_print_status >"${TMP}/c4.status"
grep -q '^BRINGUP_RESULT=FAIL_INCONSISTENT_STATE$' "${TMP}/c4.status" \
  || fail "C4 result=$(grep ^BRINGUP_RESULT= "${TMP}/c4.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=YES$' "${TMP}/c4.status" \
  || fail "C4 DO_NOT_RUN missing"
pass "C4 sentinel PASS with nonzero exit is NOT PASS"

# ---------------------------------------------------------------------------
# C5. Fully coherent current-run completion => PASS (CLI present)
# ---------------------------------------------------------------------------
write_file "$(p2b_dir)/state" "COMPLETED"
write_file "$(p2b_dir)/run-id" "run-c5"
write_file "$(p2b_dir)/exit-code" "0"
cat >"$(p2b_dir)/result.env" <<'EOF'
BRINGUP_TERMINAL_STATE=COMPLETED
BRINGUP_RESULT=PASS
BRINGUP_RUN_ID=run-c5
BRINGUP_EXIT_CODE=0
BRINGUP_COMPLETION_SENTINEL=PASS
EOF
p2b_print_status >"${TMP}/c5.status"
grep -q '^BRINGUP_RESULT=PASS$' "${TMP}/c5.status" \
  || fail "C5 result=$(grep ^BRINGUP_RESULT= "${TMP}/c5.status")"
grep -q '^DO_NOT_RUN_AELLA_CLI_YET=NO$' "${TMP}/c5.status" \
  || fail "C5 DO_NOT_RUN unexpected"
pass "C5 coherent current-run completion is PASS"

# Preserve FAIL_POSTCONDITION when CLI is missing after a coherent completion.
p2b_discover_aella_cli() { AELLA_CLI_AVAILABLE=NO; AELLA_CLI_PATH=""; return 1; }
p2b_print_status >"${TMP}/c5.post.status"
grep -q '^BRINGUP_RESULT=FAIL_POSTCONDITION$' "${TMP}/c5.post.status" \
  || fail "C5 postcondition=$(grep ^BRINGUP_RESULT= "${TMP}/c5.post.status")"
pass "C5 CLI postcondition remains FAIL_POSTCONDITION"

echo "TEST_BRINGUP_LIFECYCLE_RUN_CONTRACT=PASS"
