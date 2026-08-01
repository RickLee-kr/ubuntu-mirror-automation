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
PREPARATION_MODE=FULL
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
pass "worker IP validation"

# --- Configuration: Preparation Mode only; no DP version fields ---
grep -q '"1" "Preparation Mode"' "$INSTALLER" || fail "Preparation Mode menu missing"
grep -qE 'Current DP Version|Starting DP Version"|Target DP Version|"DP Version"' "$INSTALLER" \
  && fail "DP version config fields still present" || true
footer="$(mm_config_footer_text)"
grep -Fxq 'Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0' <<<"$footer" \
  || fail "exact footer starting line missing"
grep -Fxq 'Phase 2 Target:      6.5.0 고정' <<<"$footer" \
  || fail "exact footer phase2 target line missing"
grep -Fxq 'DP OS version: 16.04' <<<"$footer" \
  || fail "exact footer DP OS line missing"
grep -Fq 'If the DP is already running Ubuntu 24.04, select Phase 2 Only.' <<<"$footer" \
  || fail "Phase 2 Only notice missing"
pass "Configuration uses Preparation Mode + exact footer"

# Fixed target constant
mm_force_phase2_target
[[ "$TARGET_DP_VERSION" == "6.5.0" ]] || fail "forced target not 6.5.0"
[[ "$PHASE2_TARGET_VERSION" == "6.5.0" ]] || fail "PHASE2_TARGET_VERSION not 6.5.0"
TARGET_DP_VERSION=9.9.9
mm_force_phase2_target
[[ "$TARGET_DP_VERSION" == "6.5.0" ]] || fail "production override not forced back to 6.5.0"
pass "Phase 2 target fixed at 6.5.0"

# --- FULL mode command generation ---
PREPARATION_MODE=FULL
OUT="$TMP/cmds-full.txt"
gui_build_client_commands "http://221.139.249.111" "single" "" >"$OUT"

grep -q 'Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0' "$OUT" \
  || fail "missing supported starting versions"
grep -q 'Phase 2 Target: 6.5.0' "$OUT" || fail "missing phase2 target header"
grep -q 'OS Upgrade: Ubuntu 16.04 → Ubuntu 24.04' "$OUT" || fail "missing OS upgrade header"
grep -q 'Step 0 — Create snapshot or backup' "$OUT" || fail "missing step 0"
grep -q 'Step 1 — Verify bash login shells' "$OUT" || fail "missing shell verify"
grep -q 'Step 2 — Pause DP services' "$OUT" || fail "missing pause"
grep -q 'Step 3 — Ubuntu 16.04 to 18.04' "$OUT" || fail "missing hop 16→18"
grep -q 'Step 4 — Ubuntu 18.04 to 20.04' "$OUT" || fail "missing hop 18→20"
grep -q 'Step 5 — Ubuntu 20.04 to 22.04' "$OUT" || fail "missing hop 20→22"
grep -q 'Step 6 — Ubuntu 22.04 to 24.04' "$OUT" || fail "missing hop 22→24"
grep -q 'Step 7 — Stage DP 6.5.0 files' "$OUT" || fail "missing stage"
grep -q 'Step 8 — Run DP 6.5.0 bringup' "$OUT" || fail "missing bringup"
grep -q 'Step 9 — Resume DP services' "$OUT" || fail "missing resume"
grep -q 'Step 10 — Verify DP health' "$OUT" || fail "missing health"
grep -Fq -- '--source-dp-version' "$OUT" && fail "FULL command has --source-dp-version" || true
grep -Fq -- '--target-version 6.5.0' "$OUT" || fail "target version missing"
grep -Fq -- '--same-version-recovery' "$OUT" || fail "same-version-recovery missing"
grep -q 'License is valid' "$OUT" || fail "license check missing"
pass "FULL mode client commands"

# --- PHASE2_ONLY mode: no OS hops ---
PREPARATION_MODE=PHASE2_ONLY
P2_OUT="$TMP/cmds-p2.txt"
gui_build_client_commands "http://221.139.249.111" "single" "" >"$P2_OUT"
grep -q 'DP Phase 2 Upgrade Commands' "$P2_OUT" || fail "phase2 title missing"
grep -q 'Required OS: Ubuntu 24.04' "$P2_OUT" || fail "required OS missing"
grep -q 'Ubuntu 16.04 to 18.04' "$P2_OUT" && fail "PHASE2_ONLY still has OS hops" || true
grep -q 'dp-offline-upgrade-xenial-to-bionic' "$P2_OUT" && fail "PHASE2_ONLY hop script present" || true
grep -q 'Step 2 — Stage DP 6.5.0 files' "$P2_OUT" || fail "phase2 stage step missing"
grep -q 'Step 3 — Run DP 6.5.0 bringup' "$P2_OUT" || fail "phase2 bringup missing"
grep -Fq -- '--same-version-recovery' "$P2_OUT" || fail "phase2 same-version-recovery missing"
pass "PHASE2_ONLY omits OS hop commands"

# Forbidden strings
for bad in \
  CLIENT_DOWNLOAD_SOURCE CLIENT_R2_ACCESS CLIENT_ACPS_ACCESS \
  PROJECT_ROLLBACK_SUPPORTED 'Repeat similarly' '<mirror-ip>' \
  'Worker management IPs' '--source-dp-version' \
  'Current DP Version' 'Target DP Version'
do
  if grep -Fq -- "$bad" "$OUT"; then
    fail "forbidden string present in FULL: $bad"
  fi
  if grep -Fq -- "$bad" "$P2_OUT"; then
    fail "forbidden string present in PHASE2_ONLY: $bad"
  fi
done
pass "forbidden strings absent"

# No backslash continuations
if grep -E '\\[[:space:]]*$' "$OUT" "$P2_OUT"; then
  fail "backslash continuation present"
fi
pass "no backslash continuations"

# Cluster bringup
CLUSTER_OUT="$TMP/cluster.txt"
PREPARATION_MODE=FULL
gui_build_client_commands "http://221.139.249.111" "cluster" "192.168.124.23,192.168.124.24" \
  >"$CLUSTER_OUT"
grep -q -- '--worker-ips "192.168.124.23,192.168.124.24"' "$CLUSTER_OUT" || fail "worker ips missing"
grep -q 'Cluster IP addresses are recommended' "$CLUSTER_OUT" || fail "cluster IP recommendation missing"
grep -q 'Management IP addresses or cluster IP addresses can be used' "$CLUSTER_OUT" || fail "mgmt/cluster IP support missing"
pass "cluster bringup command"

bringup_line="$(grep -E 'bringup_py3_dp_after_os_upgrade\.sh' "$CLUSTER_OUT" | head -1)"
STUB="$TMP/bringup_stub.sh"
STUB_ARGV_FILE="$TMP/bringup.argv"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_ARGV_FILE}"
EOF
chmod +x "$STUB"
stub_args="$(printf '%s\n' "$bringup_line" | sed -E 's|^sudo bash [^ ]+bringup_py3_dp_after_os_upgrade\.sh[[:space:]]*||')"
# shellcheck disable=SC2086
STUB_ARGV_FILE="$STUB_ARGV_FILE" eval "\"$STUB\" $stub_args"
mapfile -t ARGV <"$STUB_ARGV_FILE"
[[ "${ARGV[0]}" == "--version" && "${ARGV[1]}" == "6.5.0" ]] || fail "bringup version wrong"
[[ "${ARGV[3]}" == "--worker-ips" ]] || fail "argv --worker-ips missing"
[[ "${ARGV[4]}" == "192.168.124.23,192.168.124.24" ]] || fail "argv worker csv not one arg"
pass "worker-ips argv verified as single CSV argument"

# Config save: PREPARATION_MODE, no TARGET_DP_VERSION / CURRENT
PREPARATION_MODE=FULL
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL="http://221.139.249.111"
mm_save_gui_config >/dev/null
grep -q '^PREPARATION_MODE=FULL$' "$MM_CONFIG_FILE" || fail "PREPARATION_MODE not saved"
grep -q 'TARGET_DP_VERSION' "$MM_CONFIG_FILE" && fail "TARGET_DP_VERSION still written" || true
grep -q 'CURRENT_DP_VERSION' "$MM_CONFIG_FILE" && fail "CURRENT_DP_VERSION still written" || true
# Legacy ignored
cat >"$MM_CONFIG_FILE" <<EOF
CURRENT_DP_VERSION=6.3.0
SOURCE_DP_VERSION=6.3.0
TARGET_DP_VERSION=9.9.9
PREPARATION_MODE=PHASE2_ONLY
ACPS_USERNAME=u
ACPS_PASSWORD=p
MIRROR_HTTP_URL=http://221.139.249.111
EOF
chmod 600 "$MM_CONFIG_FILE"
mm_load_gui_config
[[ "$PREPARATION_MODE" == "PHASE2_ONLY" ]] || fail "PHASE2_ONLY not loaded"
[[ "$TARGET_DP_VERSION" == "6.5.0" ]] || fail "legacy TARGET not forced to 6.5.0"
[[ -z "${CURRENT_DP_VERSION:-}" ]] || fail "CURRENT not unset"
mm_config_ready || fail "config_ready should pass without source version"
pass "config save/load ignores legacy versions; mode required"

# Mode change stale commands
PREPARATION_MODE=FULL
mm_save_gui_config >/dev/null
mkdir -p "$(dirname "$(mm_client_commands_file)")"
echo stale >"$(mm_client_commands_file)"
chmod 644 "$(mm_client_commands_file)"
PREPARATION_MODE=PHASE2_ONLY
mm_save_gui_config >/dev/null
[[ ! -f "$(mm_client_commands_file)" ]] || fail "stale command file not removed on mode change"
pass "mode change invalidates client commands file"

# Menu 7: topology first; version input count=0
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://221.139.249.111"
MENU7_TRACE="$TMP/menu7.trace"
: >"$MENU7_TRACE"
INPUTBOX_COUNT=0
mm_whiptail_input() {
  INPUTBOX_COUNT=$((INPUTBOX_COUNT + 1))
  printf 'INPUT\t%s\n' "$*" >>"$MENU7_TRACE"
  fail "unexpected input prompt on single path: $*"
}
mm_whiptail_menu() {
  printf 'MENU\t%s\n' "$1" >>"$MENU7_TRACE"
  printf '1\n'
}
mm_whiptail_textbox() { printf 'TEXTBOX\n' >>"$MENU7_TRACE"; return 0; }
mm_whiptail_msg() { printf 'MSG\t%s\n' "$*" >>"$MENU7_TRACE"; return 0; }
load_mirror_defaults() { :; }
engine_resolve_paths() { :; }
mm_save_gui_config() { return 0; }
rm -f "$(mm_client_commands_file)"
gui_client_instructions
[[ "$INPUTBOX_COUNT" -eq 0 ]] || fail "menu7 version inputbox count=${INPUTBOX_COUNT}"
grep -q $'MENU\tDP deployment type' "$MENU7_TRACE" || fail "first menu7 prompt not topology"
[[ -f "$(mm_client_commands_file)" ]] || fail "menu7 did not create command file"
[[ "$(stat -c '%a' "$(mm_client_commands_file)")" == "644" ]] || fail "menu7 file mode not 644"
grep -Fq -- '--source-dp-version' "$(mm_client_commands_file)" && fail "menu7 has source" || true
grep -Fq -- '--target-version 6.5.0' "$(mm_client_commands_file)" || fail "menu7 missing target"
grep -Fq -- '--same-version-recovery' "$(mm_client_commands_file)" || fail "menu7 missing recovery"
pass "menu7 topology-only; no version prompts"

# Artifact: only 6.5.0 versioned names in ACPS/phase2 helpers
grep -E 'images-6\.[234]\.0|aella-uvp-2404_6\.[234]\.0' \
  "$ROOT/scripts/lib/dp-phase2-common.sh" "$ENGINE" 2>/dev/null \
  && fail "non-6.5.0 versioned ACPS artifacts referenced" || true
grep -Eq 'images-\$\{|images-6\.5\.0|images-.*VERSION' "$ROOT/scripts/lib/dp-phase2-common.sh" \
  || fail "versioned images template missing from dp2 common"
grep -q 'PHASE2_TARGET_VERSION="6.5.0"' "$COMMON" || fail "fixed PHASE2_TARGET_VERSION missing"
pass "Phase 2 artifacts are 6.5.0-only"

# Engine: PHASE2_ONLY skips R2
grep -q 'PHASE2_ONLY_R2_DOWNLOAD_COUNT=0' "$ENGINE" || fail "PHASE2_ONLY R2 skip marker missing"
grep -q 'mm_is_phase2_only' "$ENGINE" || fail "engine missing phase2_only branch"
pass "engine PHASE2_ONLY R2 skip present"

# Non-root official entry
NONROOT_OUT="$TMP/nonroot.out"
set +e
MM_SKIP_ROOT_CHECK=0 bash "$INSTALLER" mirror-manager >"$NONROOT_OUT" 2>&1
NONROOT_RC=$?
set -e
[[ "$NONROOT_RC" -ne 0 ]] || fail "non-root mirror-manager should fail"
grep -q 'This command requires sudo.' "$NONROOT_OUT" || fail "non-root missing sudo guidance"
pass "non-root prints clear sudo guidance"

echo "ALL test_gui_client_commands checks passed"
