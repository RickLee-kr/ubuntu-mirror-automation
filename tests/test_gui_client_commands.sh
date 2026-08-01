#!/usr/bin/env bash
# GUI client-command generation, menu helpers, worker IP validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"
COMMON="${ROOT}/scripts/lib/mirror_manager_common.sh"
ENGINE="${ROOT}/scripts/lib/mirror_install_engine.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MM_PROJECT_ROOT="$ROOT"
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CLIENT_ROOT="$TMP/client"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"
CURRENT_DP_VERSION=6.3.0
TARGET_DP_VERSION=6.5.0
MIRROR_HTTP_URL="http://221.139.249.111"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"

# shellcheck disable=SC1090
source "$LIB"

# --- worker IP validation ---
ok="$(mm_validate_worker_ips '192.168.124.23, 192.168.124.24')" \
  || fail "valid cluster worker ips rejected"
[[ "$ok" == "192.168.124.23,192.168.124.24" ]] || fail "worker ips not normalized: $ok"
ok_mgmt="$(mm_validate_worker_ips '10.10.10.23,10.10.10.24')" \
  || fail "valid management worker ips rejected"
[[ "$ok_mgmt" == "10.10.10.23,10.10.10.24" ]] || fail "mgmt ips not normalized"
mm_validate_worker_ips '' >/dev/null 2>&1 && fail "empty worker ips accepted" || true
mm_validate_worker_ips '192.168.1.1;rm -rf /' >/dev/null 2>&1 && fail "metachar accepted" || true
mm_validate_worker_ips 'not-an-ip' >/dev/null 2>&1 && fail "bad ip accepted" || true
mm_validate_worker_ips '192.168.124.23,' >/dev/null 2>&1 && fail "trailing comma accepted" || true
mm_validate_worker_ips '192.168.124.999' >/dev/null 2>&1 && fail "octet 999 accepted" || true
mm_validate_worker_ips $'192.168.1.1\n192.168.1.2' >/dev/null 2>&1 && fail "newline accepted" || true
mm_validate_worker_ips '192.168.1.1,,192.168.1.2' >/dev/null 2>&1 && fail "empty item accepted" || true
mm_validate_worker_ips '192.168.1.1,192.168.1.1' >/dev/null 2>&1 && fail "duplicate accepted" || true
mm_validate_worker_ips '0.0.0.0' >/dev/null 2>&1 && fail "0.0.0.0 accepted" || true
mm_validate_worker_ips '255.255.255.255' >/dev/null 2>&1 && fail "broadcast accepted" || true
pass "worker IP validation"

mm_validate_source_dp_version "6.3.0" || fail "6.3.0 rejected"
mm_validate_source_dp_version "6.4.0" || fail "6.4.0 rejected"
mm_validate_source_dp_version "6.1.0" >/dev/null 2>&1 && fail "6.1.0 below floor accepted" || true
mm_validate_source_dp_version "bad" >/dev/null 2>&1 && fail "bad version accepted" || true
mm_validate_source_dp_version "6.3" >/dev/null 2>&1 && fail "partial version accepted" || true
mm_validate_source_dp_version "v6.3.0" >/dev/null 2>&1 && fail "v-prefix accepted" || true
pass "source DP version validation"

# --- command text generation ---
OUT="$TMP/cmds.txt"
gui_build_client_commands "http://221.139.249.111" "6.3.0" "single" "" >"$OUT"

grep -q 'Current DP Version: 6.3.0' "$OUT" || fail "missing current version header"
grep -q 'Target DP Version: 6.5.0' "$OUT" || fail "missing target version header"
grep -q 'Step 0 — Create a snapshot' "$OUT" || fail "missing step 0"
grep -q 'Step 1 — Pause DP services' "$OUT" || fail "missing pause step"
grep -q 'Step 2 — Ubuntu 16.04 to 18.04' "$OUT" || fail "missing step 2"
grep -q 'Step 3 — Ubuntu 18.04 to 20.04' "$OUT" || fail "missing step 3"
grep -q 'Step 4 — Ubuntu 20.04 to 22.04' "$OUT" || fail "missing step 4"
grep -q 'Step 5 — Ubuntu 22.04 to 24.04' "$OUT" || fail "missing step 5"
grep -q 'Step 6 — Download and stage DP 6.5.0 files' "$OUT" || fail "missing stage step"
grep -q 'Step 7 — Start DP 6.5.0 bringup' "$OUT" || fail "missing bringup step"
grep -q 'Step 8 — Resume DP services' "$OUT" || fail "missing resume step"
grep -q 'Step 9 — Verify DP health' "$OUT" || fail "missing health step"
grep -q 'http://221.139.249.111' "$OUT" || fail "mirror URL missing"
grep -q 'sha256sum -c' "$OUT" || fail "checksum verify missing"
grep -q 'stage-dp-phase2.sh' "$OUT" || fail "stage script missing"
grep -Fq -- '--source-dp-version 6.3.0' "$OUT" || fail "source version not resolved"
grep -Fq -- '--target-version 6.5.0' "$OUT" || fail "target version missing"
grep -q 'bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --skip-download' "$OUT" \
  || fail "bringup command missing"
grep -q 'Do not resume the DP during Steps 2–5' "$OUT" || fail "no-resume-during-hops missing"
grep -q 'The DP health checks must be performed after resume' "$OUT" \
  || fail "health-after-resume note missing"
grep -q 'dp-client-upgrade-commands.txt' "$OUT" || fail "commands file path missing"
grep -q 'show status' "$OUT" || fail "show status missing"

# Order: pause before OS hops; resume after bringup; health after resume
awk '
  /Step 1 — Pause/ { p=NR }
  /Step 2 — Ubuntu 16.04/ { o=NR }
  /Step 7 — Start DP/ { b=NR }
  /Step 8 — Resume/ { r=NR }
  /Step 9 — Verify DP health/ { h=NR }
  END {
    if (!(p && o && b && r && h)) exit 1
    if (!(p < o && o < b && b < r && r < h)) exit 2
  }
' "$OUT" || fail "pause/bringup/resume/health order wrong"

# Forbidden: health before resume sequence
if awk '
  /Step 9 — Verify DP health/ { h=NR }
  /Step 8 — Resume/ { r=NR }
  END { exit((h && r && h < r) ? 0 : 1) }
' "$OUT"; then
  fail "wrong health-before-resume sequence present"
fi
pass "client command order pause→OS→stage→bringup→resume→health"

# Forbidden strings
for bad in \
  CLIENT_DOWNLOAD_SOURCE CLIENT_R2_ACCESS CLIENT_ACPS_ACCESS \
  PROJECT_ROLLBACK_SUPPORTED OS_ROLLBACK_SUPPORTED DP_RUNTIME_ROLLBACK_SUPPORTED \
  RECOVERY_TARGET INTERMEDIATE_OS_RECOVERY_SUPPORTED \
  'Repeat similarly' 'Also used by clients' 'Phase 2 HTTP paths' \
  'example mirror' 'Bringup drift' 'Cloudflare R2' 'ACPS Server' \
  '<current-dp>' '<mirror-ip>' '<worker1' '<worker2' \
  'Worker management IPs' \
  "echo 'pause'" "echo 'resume'" 'SKIPPED_NETWORK'
do
  if grep -Fq "$bad" "$OUT"; then
    fail "forbidden string present: $bad"
  fi
done
pass "forbidden strings absent"

# No backslash line continuations
if grep -E '\\[[:space:]]*$' "$OUT"; then
  fail "backslash continuation present"
fi
pass "no backslash continuations"

# OS hop command lines (Steps 2-5) and stage (Step 6) are single && chains
for n in 2 3 4 5 6; do
  cmd_line="$(awk -v n="$n" '
    $0 ~ ("^Step " n " —") { want=1; next }
    want && NF { print; exit }
  ' "$OUT")"
  [[ -n "$cmd_line" ]] || fail "step $n command missing"
  grep -Fq '&&' <<<"$cmd_line" || fail "step $n not a && chain"
  grep -Fq 'curl -fsSLO' <<<"$cmd_line" || fail "step $n missing curl"
  grep -Fq 'sha256sum -c' <<<"$cmd_line" || fail "step $n missing sha256sum"
  grep -Fq 'sudo bash' <<<"$cmd_line" || fail "step $n missing sudo bash"
done
pass "one-line && commands for steps 2-6"

# Single topology: no --worker-ips
grep -q -- '--worker-ips' "$OUT" && fail "single topology has worker-ips" || true
pass "single topology omits --worker-ips"

# Cluster bringup includes worker-ips + cluster IP guidance
CLUSTER_OUT="$TMP/cluster.txt"
gui_build_client_commands "http://221.139.249.111" "6.4.0" "cluster" "192.168.124.23,192.168.124.24" \
  >"$CLUSTER_OUT"
grep -q 'Start DP 6.5.0 bringup' "$CLUSTER_OUT" || fail "cluster step7 title"
grep -q -- '--worker-ips "192.168.124.23,192.168.124.24"' "$CLUSTER_OUT" || fail "worker ips missing"
grep -q 'Run this command on the cluster master only.' "$CLUSTER_OUT" || fail "cluster master note"
grep -q 'Cluster IPs are recommended' "$CLUSTER_OUT" || fail "cluster IP recommendation missing"
grep -q 'Management IPs or cluster IPs can be used' "$CLUSTER_OUT" || fail "mgmt/cluster IP support missing"
grep -Fq -- '--source-dp-version 6.4.0' "$CLUSTER_OUT" || fail "cluster source 6.4.0 missing"
pass "cluster bringup command"

# Management worker IPs also accepted in generated argv text
MGMT_OUT="$TMP/mgmt.txt"
gui_build_client_commands "http://221.139.249.111" "6.3.0" "cluster" "10.10.10.23,10.10.10.24" \
  >"$MGMT_OUT"
grep -q -- '--worker-ips "10.10.10.23,10.10.10.24"' "$MGMT_OUT" || fail "mgmt worker ips missing"
pass "management worker IPs in command"

# Stub argv capture: parse generated bringup line with shell quoting rules
bringup_line="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh' "$CLUSTER_OUT" | head -1)"
[[ -n "$bringup_line" ]] || fail "no bringup line to exec"
STUB="$TMP/bringup_stub.sh"
STUB_ARGV_FILE="$TMP/bringup.argv"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_ARGV_FILE}"
EOF
chmod +x "$STUB"
# Drop "sudo bash <script>" and invoke stub with the remaining quoted args.
stub_args="$(printf '%s\n' "$bringup_line" | sed -E 's|^sudo bash [^ ]+bringup_py3_dp_after_os_upgrade\.sh[[:space:]]*||')"
# shellcheck disable=SC2086
STUB_ARGV_FILE="$STUB_ARGV_FILE" eval "\"$STUB\" $stub_args"
[[ -f "$STUB_ARGV_FILE" ]] || fail "stub did not record argv"
mapfile -t ARGV <"$STUB_ARGV_FILE"
# Expect: --version 6.5.0 --skip-download --worker-ips 192.168.124.23,192.168.124.24
[[ "${ARGV[0]}" == "--version" ]] || fail "argv[0] want --version got ${ARGV[0]:-}"
[[ "${ARGV[1]}" == "6.5.0" ]] || fail "argv version wrong"
[[ "${ARGV[2]}" == "--skip-download" ]] || fail "argv skip-download missing"
[[ "${ARGV[3]}" == "--worker-ips" ]] || fail "argv --worker-ips missing"
[[ "${ARGV[4]}" == "192.168.124.23,192.168.124.24" ]] || fail "argv worker csv not one arg: ${ARGV[4]:-}"
[[ "${#ARGV[@]}" -eq 5 ]] || fail "unexpected argv count=${#ARGV[@]}"
pass "worker-ips argv verified as single CSV argument"

# Commands file path + mode when written like gui_client_instructions
OUT_FILE="$(mm_client_commands_file)"
mkdir -p "$(dirname "$OUT_FILE")"
cp -f "$OUT" "$OUT_FILE"
chmod 0644 "$OUT_FILE"
[[ "$(stat -c '%a' "$OUT_FILE")" == "644" ]] || fail "commands file mode not 644"
pass "commands file mode 644"

# HTTP probe list includes stage script; no production SKIPPED_NETWORK WARN
grep -q 'stage-dp-phase2.sh.sha256' "$ENGINE" || fail "stage sha HTTP probe missing"
grep -q 'dp-offline-upgrade-xenial-to-bionic.sh' "$ENGINE" || fail "client hop HTTP probe missing"
grep -q 'HTTP_VALIDATION_START' "$ENGINE" || fail "HTTP_VALIDATION_START missing"
grep -q 'HTTP_VALIDATION=DEFERRED' "$ENGINE" || fail "DEFERRED marker missing"
if grep -n 'mm_warn "HTTP_VALIDATION=SKIPPED_NETWORK"' "$ENGINE"; then
  fail "production SKIPPED_NETWORK WARN still present"
fi
pass "HTTP readiness probes + no SKIPPED_NETWORK WARN"

# Dependency helpers
mm_status_set HTTP_DISTRIBUTION DISABLED
mm_http_distribution_enabled && fail "http enabled when DISABLED" || true
mm_status_set HTTP_DISTRIBUTION ENABLED
mm_http_distribution_enabled || fail "http enabled check failed"
pass "HTTP distribution enabled helper"

# Menu title
grep -q 'Show DP Client Upgrade Commands' "$INSTALLER" || fail "menu 7 title"
if grep -q 'Show DP Client Upgrade Instructions' "$INSTALLER"; then
  fail "old menu 7 title still present"
fi
grep -q 'Worker IP addresses' "$INSTALLER" || fail "Worker IP addresses title missing"
if grep -q 'Worker management IPs' "$INSTALLER"; then
  fail "old Worker management IPs title still present"
fi
grep -q 'Current DP Version' "$INSTALLER" || fail "Current DP Version config field missing"
pass "menu titles updated"

# Dependency message strings in product code
grep -q 'Upgrade files are not ready' "$INSTALLER" || fail "menu3 gate message missing"
grep -q 'HTTP distribution is not enabled' "$INSTALLER" || fail "menu4 gate message missing"
grep -q '2 Download and Prepare Upgrade Files' "$INSTALLER" || fail "menu3 points to menu 2"
grep -q '3 Enable HTTP Distribution' "$INSTALLER" || fail "menu4 points to menu 3"
pass "dependency gate messages"

# Status screen omits internal fields; readiness never blank
if awk '
  /^gui_show_status\(\)/ { in_fn=1 }
  in_fn && /^}/ { in_fn=0 }
  in_fn && /PROJECT_ROLLBACK_SUPPORTED|Bringup drift|CLIENT_R2_ACCESS|Cloudflare R2|ACPS Server/ { bad=1 }
  in_fn && /mm_upgrade_readiness_display/ { ok=1 }
  END { exit((bad || !ok) ? 1 : 0) }
' "$INSTALLER"; then
  pass "status omits internal fields and uses readiness display helper"
else
  fail "status still shows internal fields or missing readiness helper"
fi

# Upgrade readiness display mapping
: >"$MM_STATUS_FILE"
ready="$(mm_upgrade_readiness_display)"
[[ "$ready" == "NOT READY" ]] || fail "expected NOT READY got '$ready'"
# Pretend config+download+http complete without readiness attempt
mm_configuration_completed() { return 0; }
mm_download_completed() { return 0; }
mm_http_completed() { return 0; }
mm_readiness_completed() { return 1; }
ready="$(mm_upgrade_readiness_display)"
[[ "$ready" == "NOT VERIFIED" ]] || fail "expected NOT VERIFIED got '$ready'"
mm_status_set READINESS_RESULT FAIL
mm_status_set UPGRADE_READINESS FAIL
ready="$(mm_upgrade_readiness_display)"
[[ "$ready" == "FAIL" ]] || fail "expected FAIL got '$ready'"
mm_readiness_completed() { return 0; }
ready="$(mm_upgrade_readiness_display)"
[[ "$ready" == "PASS" ]] || fail "expected PASS got '$ready'"
[[ -n "$ready" ]] || fail "blank readiness"
pass "Upgrade Readiness mapping"

# Root-only official entry message
grep -q 'This command requires sudo.' "$COMMON" || fail "sudo guidance missing"
grep -q 'sudo ubuntu-offline-mirror mirror-manager' "$COMMON" || fail "official sudo command missing"
grep -q 'mm_require_root' "$INSTALLER" || fail "installer must call mm_require_root"
pass "root-only guidance present"

# Config CURRENT_DP_VERSION save/load
CURRENT_DP_VERSION=6.3.0
TARGET_DP_VERSION=6.5.0
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL="http://221.139.249.111"
mm_save_gui_config >/dev/null
grep -q '^CURRENT_DP_VERSION=6.3.0$' "$MM_CONFIG_FILE" || fail "CURRENT_DP_VERSION not saved"
CURRENT_DP_VERSION=""
mm_load_gui_config
[[ "$CURRENT_DP_VERSION" == "6.3.0" ]] || fail "CURRENT_DP_VERSION not loaded"
pass "CURRENT_DP_VERSION config round-trip"

# Menu 7 uses config current as default; blocks source==target
MM_LOG_DIR="$TMP/logs"
mkdir -p "$MM_LOG_DIR"
MENU7_TRACE="$TMP/menu7.trace"
: >"$MENU7_TRACE"
CURRENT_DP_VERSION=6.3.0
TARGET_DP_VERSION=6.5.0
MIRROR_HTTP_URL="http://221.139.249.111"
mm_whiptail_input() {
  printf 'INPUT_DEFAULT\t%s\n' "${3:-}" >>"$MENU7_TRACE"
  printf '%s\n' "${3:-}"
}
mm_whiptail_menu() { printf '1\n'; }  # single topology
mm_whiptail_textbox() { printf 'TEXTBOX\n' >>"$MENU7_TRACE"; return 0; }
mm_whiptail_msg() { printf 'MSG\t%s\n' "$*" >>"$MENU7_TRACE"; return 0; }
load_mirror_defaults() { :; }
engine_resolve_paths() { :; }
mm_save_gui_config() { return 0; }
rm -f "$(mm_client_commands_file)"
gui_client_instructions
grep -q $'INPUT_DEFAULT\t6.3.0' "$MENU7_TRACE" || fail "menu7 default not CURRENT_DP_VERSION"
[[ -f "$(mm_client_commands_file)" ]] || fail "menu7 did not auto-create command file"
[[ "$(stat -c '%a' "$(mm_client_commands_file)")" == "644" ]] || fail "menu7 file mode not 644"
grep -Fq -- '--source-dp-version 6.3.0' "$(mm_client_commands_file)" || fail "menu7 file wrong source"
grep -Fq -- '--target-version 6.5.0' "$(mm_client_commands_file)" || fail "menu7 file wrong target"
gui_build_client_commands "http://221.139.249.111" "6.3.0" "single" "" >"$TMP/expected-cmds.txt"
cmp -s "$(mm_client_commands_file)" "$TMP/expected-cmds.txt" \
  || fail "GUI file content mismatch"
pass "menu7 GUI path uses CURRENT_DP_VERSION default"

# source == target blocked
: >"$MENU7_TRACE"
mm_whiptail_input() { printf '6.5.0\n'; }
gui_client_instructions
grep -q 'current DP version and target DP version are the same' "$MENU7_TRACE" \
  || fail "source==target not blocked"
pass "source equals target blocked"

# Non-root official entry must print clear sudo guidance (not raw Permission denied first).
NONROOT_OUT="$TMP/nonroot.out"
set +e
MM_SKIP_ROOT_CHECK=0 bash "$INSTALLER" mirror-manager >"$NONROOT_OUT" 2>&1
NONROOT_RC=$?
set -e
[[ "$NONROOT_RC" -ne 0 ]] || fail "non-root mirror-manager should fail"
grep -q 'This command requires sudo.' "$NONROOT_OUT" || fail "non-root missing sudo guidance"
grep -q 'sudo ubuntu-offline-mirror mirror-manager' "$NONROOT_OUT" || fail "non-root missing official command"
if grep -q 'Permission denied' "$NONROOT_OUT"; then
  awk '
    /This command requires sudo\./ { guide=NR }
    /Permission denied/ { perm=NR }
    END { exit((guide && (!perm || guide < perm)) ? 0 : 1) }
  ' "$NONROOT_OUT" || fail "Permission denied before sudo guidance"
fi
pass "non-root prints clear sudo guidance"

echo "ALL test_gui_client_commands checks passed"
