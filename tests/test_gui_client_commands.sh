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
  || fail "valid worker ips rejected"
[[ "$ok" == "192.168.124.23,192.168.124.24" ]] || fail "worker ips not normalized: $ok"
mm_validate_worker_ips '' >/dev/null 2>&1 && fail "empty worker ips accepted" || true
mm_validate_worker_ips '192.168.1.1;rm -rf /' >/dev/null 2>&1 && fail "metachar accepted" || true
mm_validate_worker_ips 'not-an-ip' >/dev/null 2>&1 && fail "bad ip accepted" || true
pass "worker IP validation"

mm_validate_source_dp_version "6.3.0" || fail "6.3.0 rejected"
mm_validate_source_dp_version "bad" >/dev/null 2>&1 && fail "bad version accepted" || true
pass "source DP version validation"

# --- command text generation ---
OUT="$TMP/cmds.txt"
gui_build_client_commands "http://221.139.249.111" "6.3.0" "single" "" >"$OUT"

grep -q 'Step 1 — Ubuntu 16.04 to 18.04' "$OUT" || fail "missing step 1"
grep -q 'Step 2 — Ubuntu 18.04 to 20.04' "$OUT" || fail "missing step 2"
grep -q 'Step 3 — Ubuntu 20.04 to 22.04' "$OUT" || fail "missing step 3"
grep -q 'Step 4 — Ubuntu 22.04 to 24.04' "$OUT" || fail "missing step 4"
grep -q 'Step 5 — Download and stage DP 6.5.0 files' "$OUT" || fail "missing step 5"
grep -q 'Step 6 — Start DP 6.5.0 bringup' "$OUT" || fail "missing step 6"
grep -q 'http://221.139.249.111' "$OUT" || fail "mirror URL missing"
grep -q 'sha256sum -c' "$OUT" || fail "checksum verify missing"
grep -q 'stage-dp-phase2.sh' "$OUT" || fail "stage script missing"
grep -Fq -- '--source-dp-version 6.3.0' "$OUT" || fail "source version not resolved"
grep -q 'bringup_py3_dp_after_os_upgrade.sh --version 6.5.0 --skip-download' "$OUT" \
  || fail "bringup command missing"
grep -q 'sudo tail -F /var/log/aella/aella_py3_bringup.log' "$OUT" || fail "log watch missing"
grep -q 'dp-client-upgrade-commands.txt' "$OUT" || fail "commands file path missing"

# Forbidden strings
for bad in \
  CLIENT_DOWNLOAD_SOURCE CLIENT_R2_ACCESS CLIENT_ACPS_ACCESS \
  PROJECT_ROLLBACK_SUPPORTED OS_ROLLBACK_SUPPORTED DP_RUNTIME_ROLLBACK_SUPPORTED \
  RECOVERY_TARGET INTERMEDIATE_OS_RECOVERY_SUPPORTED \
  'Repeat similarly' 'Also used by clients' 'Phase 2 HTTP paths' \
  'example mirror' 'Bringup drift' 'Cloudflare R2' 'ACPS Server' \
  '<current-dp>' '<mirror-ip>' '<worker1' '<worker2'
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

# Each Step N command line is a single && chain
for n in 1 2 3 4 5; do
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
pass "one-line && commands for steps 1-5"

# Cluster bringup includes worker-ips
CLUSTER_OUT="$TMP/cluster.txt"
gui_build_client_commands "http://221.139.249.111" "6.4.0" "cluster" "192.168.124.23,192.168.124.24" \
  >"$CLUSTER_OUT"
grep -q 'Start DP 6.5.0 cluster bringup' "$CLUSTER_OUT" || fail "cluster step6 title"
grep -q -- '--worker-ips "192.168.124.23,192.168.124.24"' "$CLUSTER_OUT" || fail "worker ips missing"
grep -q 'Run this command on the cluster master.' "$CLUSTER_OUT" || fail "cluster master note"
pass "cluster bringup command"

# Commands file path + mode when written like gui_client_instructions
OUT_FILE="$(mm_client_commands_file)"
mkdir -p "$(dirname "$OUT_FILE")"
cp -f "$OUT" "$OUT_FILE"
chmod 0644 "$OUT_FILE"
[[ "$(stat -c '%a' "$OUT_FILE")" == "644" ]] || fail "commands file mode not 644"
pass "commands file mode 644"

# HTTP probe list includes stage script
grep -q 'stage-dp-phase2.sh.sha256' "$ENGINE" || fail "stage sha HTTP probe missing"
grep -q 'dp-offline-upgrade-xenial-to-bionic.sh' "$ENGINE" || fail "client hop HTTP probe missing"
pass "HTTP readiness probes include stage + hop scripts"

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
pass "menu 7 title updated"

# Dependency message strings in product code
grep -q 'Upgrade files are not ready' "$INSTALLER" || fail "menu3 gate message missing"
grep -q 'HTTP distribution is not enabled' "$INSTALLER" || fail "menu4 gate message missing"
grep -q '2 Download and Prepare Upgrade Files' "$INSTALLER" || fail "menu3 points to menu 2"
grep -q '3 Enable HTTP Distribution' "$INSTALLER" || fail "menu4 points to menu 3"
pass "dependency gate messages"

# Status screen omits internal fields
if awk '
  /^gui_show_status\(\)/ { in_fn=1 }
  in_fn && /^}/ { in_fn=0 }
  in_fn && /PROJECT_ROLLBACK_SUPPORTED|Bringup drift|CLIENT_R2_ACCESS|Cloudflare R2|ACPS Server/ { bad=1 }
  END { exit(bad ? 1 : 0) }
' "$INSTALLER"; then
  pass "status omits internal fields"
else
  fail "status still shows internal fields"
fi

# Root-only official entry message
grep -q 'This command requires sudo.' "$COMMON" || fail "sudo guidance missing"
grep -q 'sudo ubuntu-offline-mirror mirror-manager' "$COMMON" || fail "official sudo command missing"
grep -q 'mm_require_root' "$INSTALLER" || fail "installer must call mm_require_root"
pass "root-only guidance present"

# Menu 7 auto-writes command file mode 644 (as root would, using writable test log dir)
MM_LOG_DIR="$TMP/logs"
mkdir -p "$MM_LOG_DIR"
OUT_AUTO="$(mm_client_commands_file)"
gui_build_client_commands "http://221.139.249.111" "6.3.0" "single" "" >"$OUT_AUTO"
chmod 0644 "$OUT_AUTO"
[[ -f "$OUT_AUTO" ]] || fail "command file not created"
[[ "$(stat -c '%a' "$OUT_AUTO")" == "644" ]] || fail "command file mode not 644"
pass "command file auto path + mode 644"

# Simulate Menu 7 GUI path: gui_client_instructions must write the file itself.
MENU7_TRACE="$TMP/menu7.trace"
: >"$MENU7_TRACE"
mm_whiptail_input() { printf '6.3.0\n'; }
mm_whiptail_menu() { printf '1\n'; }  # single topology
mm_whiptail_textbox() { printf 'TEXTBOX\n' >>"$MENU7_TRACE"; return 0; }
mm_whiptail_msg() { printf 'MSG\t%s\n' "$1" >>"$MENU7_TRACE"; return 0; }
load_mirror_defaults() { :; }
engine_resolve_paths() { :; }
mm_save_gui_config() { return 0; }
MIRROR_HTTP_URL="http://221.139.249.111"
rm -f "$(mm_client_commands_file)"
gui_client_instructions
[[ -f "$(mm_client_commands_file)" ]] || fail "menu7 did not auto-create command file"
[[ "$(stat -c '%a' "$(mm_client_commands_file)")" == "644" ]] || fail "menu7 file mode not 644"
grep -q 'http://221.139.249.111' "$(mm_client_commands_file)" || fail "menu7 file missing mirror URL"
grep -q 'TEXTBOX' "$MENU7_TRACE" || fail "menu7 textbox not shown"
pass "menu7 GUI path auto-creates command file"

# Non-root official entry must print clear sudo guidance (not raw Permission denied first).
NONROOT_OUT="$TMP/nonroot.out"
set +e
MM_SKIP_ROOT_CHECK=0 bash "$INSTALLER" mirror-manager >"$NONROOT_OUT" 2>&1
NONROOT_RC=$?
set -e
[[ "$NONROOT_RC" -ne 0 ]] || fail "non-root mirror-manager should fail"
grep -q 'This command requires sudo.' "$NONROOT_OUT" || fail "non-root missing sudo guidance"
grep -q 'sudo ubuntu-offline-mirror mirror-manager' "$NONROOT_OUT" || fail "non-root missing official command"
# Must not surface raw config Permission denied before the guidance.
if grep -q 'Permission denied' "$NONROOT_OUT"; then
  # Guidance must appear before any Permission denied line.
  awk '
    /This command requires sudo\./ { guide=NR }
    /Permission denied/ { perm=NR }
    END { exit((guide && (!perm || guide < perm)) ? 0 : 1) }
  ' "$NONROOT_OUT" || fail "Permission denied before sudo guidance"
fi
pass "non-root prints clear sudo guidance"

echo "ALL test_gui_client_commands checks passed"
