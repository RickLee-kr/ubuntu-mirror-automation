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
# Fixture mirror addresses are RFC 5737 documentation IPs that are not
# configured on the test host; skip the interface-presence check only.
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export MM_CLIENT_ROOT="$TMP/client"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$MM_CLIENT_ROOT"
: >"$MM_STATUS_FILE"
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://192.0.2.10"

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

# Menu height must fit Configuration instruction+footer (not a fixed +12 chrome).
# Match production: trailing blank line avoids newt clipping the last footer line.
config_text="Preparation Mode: Full OS Upgrade + Phase 2
ACPS Username: configured
ACPS Password: configured
ACPS Server: Fixed
OS Core Source: Cloudflare R2

${footer}
"
config_text_lines="$(printf '%b' "$config_text" | wc -l)"
# mm_term_size normally overwrites HEIGHT/WIDTH via tput; pin sizes for this check.
mm_term_size() { :; }
HEIGHT=50 WIDTH=140
read -r cfg_h cfg_w cfg_list <<<"$(mm_calc_menu_size 6 74 8 "${config_text_lines}")"
# Whiptail text rows ≈ dialog_height - list_height - chrome(10).
cfg_text_rows=$((cfg_h - cfg_list - 10))
[[ "$cfg_text_rows" -ge "$config_text_lines" ]] \
  || fail "config menu text rows ${cfg_text_rows} < footer block ${config_text_lines} (h=${cfg_h} list=${cfg_list})"
HEIGHT=40 WIDTH=100
read -r cfg_h cfg_w cfg_list <<<"$(mm_calc_menu_size 6 74 8 "${config_text_lines}")"
cfg_text_rows=$((cfg_h - cfg_list - 10))
[[ "$cfg_text_rows" -ge "$config_text_lines" ]] \
  || fail "mid-term config menu clips footer (rows=${cfg_text_rows} need=${config_text_lines} h=${cfg_h} list=${cfg_list})"
grep -q 'text_lines' "$INSTALLER" || fail "mm_calc_menu_size missing text_lines sizing"
pass "Configuration menu height fits exact footer"

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
gui_build_client_commands "http://192.0.2.10" "single" "" >"$OUT"

grep -q 'Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0' "$OUT" \
  || fail "missing supported starting versions"
grep -q 'Phase 2 Target: 6.5.0' "$OUT" || fail "missing phase2 target header"
grep -q 'OS Upgrade: Ubuntu 16.04 → Ubuntu 24.04' "$OUT" || fail "missing OS upgrade header"
grep -q 'Commands saved to:' "$OUT" || fail "missing Commands saved to"
grep -q 'exactly one physical line' "$OUT" || fail "missing one-line copy guidance"
grep -qE 'STEP 0 — SNAPSHOT|Step 0 —' "$OUT" || fail "missing step 0"
grep -qE 'STEP 1 — PAUSE|Step 1 — Pause' "$OUT" || fail "missing pause"
grep -qE 'STEP 2 — UBUNTU 16.04 TO 18.04|Step 2 — Ubuntu 16.04 to 18.04' "$OUT" \
  || fail "missing hop 16→18"
grep -q 'The Xenial-to-Bionic client automatically sets the aella and root login' "$OUT" \
  || fail "missing automatic login shell guidance"
grep -qE 'STEP 3 — UBUNTU 18.04 TO 20.04|Step 3 — Ubuntu 18.04 to 20.04' "$OUT" \
  || fail "missing hop 18→20"
grep -qE 'STEP 4 — UBUNTU 20.04 TO 22.04|Step 4 — Ubuntu 20.04 to 22.04' "$OUT" \
  || fail "missing hop 20→22"
grep -qE 'STEP 5 — UBUNTU 22.04 TO 24.04|Step 5 — Ubuntu 22.04 to 24.04' "$OUT" \
  || fail "missing hop 22→24"
grep -qE 'STEP 6 — STAGE DP 6.5.0|Step 6 — Stage DP 6.5.0 files' "$OUT" \
  || fail "missing stage"
grep -qE 'STEP 7 — RUN DP 6.5.0 BRINGUP|Step 7 — Run DP 6.5.0 bringup' "$OUT" \
  || fail "missing bringup"
grep -qE 'STEP 8 — RESUME|Step 8 — Resume' "$OUT" || fail "missing resume"
grep -qE 'STEP 9 — VERIFY|Step 9 — Verify' "$OUT" || fail "missing health"
grep -q 'Verify bash login shells' "$OUT" && fail "manual shell verify step still present" || true
grep -q 'getent passwd aella root' "$OUT" && fail "manual getent shell command still present" || true
grep -q 'Show complete instructions' "$OUT" && fail "Show complete instructions still present" || true
grep -q 'Show Step 2 command block' "$OUT" && fail "Show Step submenu still present" || true
grep -q 'BEGIN STEP' "$OUT" && fail "BEGIN STEP markers must be removed" || true
grep -q 'END STEP' "$OUT" && fail "END STEP markers must be removed" || true
grep -qE '\\[[:space:]]*$' "$OUT" && fail "backslash continuations must be removed" || true
grep -q 'public-keyring.gpg' "$OUT" || fail "missing public-keyring.gpg in commands"
grep -q -- '--keyring ./public-keyring.gpg' "$OUT" || fail "gpgv must use public-keyring.gpg"
grep -q -- '--keyring ./public.gpg' "$OUT" && fail "gpgv must not use armored public.gpg" || true
grep -Eq 'curl -fsSLO([[:space:]]|$)' "$OUT" && fail "naked curl -fsSLO present" || true
# Full mode must still cover steps 0..9
for n in 0 1 2 3 4 5 6 7 8 9; do
  grep -qE "Step ${n} —|STEP ${n} —" "$OUT" || fail "missing step ${n}"
done
for script in \
  dp-offline-upgrade-xenial-to-bionic.sh \
  dp-offline-upgrade-bionic-to-focal.sh \
  dp-offline-upgrade-focal-to-jammy.sh \
  dp-offline-upgrade-jammy-to-noble.sh \
  stage-dp-phase2.sh \
  bringup_py3_dp_after_os_upgrade.sh
do
  grep -Fq "$script" "$OUT" || fail "missing script name: $script"
done
grep -Fq -- '--source-dp-version' "$OUT" && fail "FULL command has --source-dp-version" || true
grep -Fq -- '--target-version' "$OUT" || fail "target version missing"
grep -Fq -- '--same-version-recovery' "$OUT" || fail "same-version-recovery missing"
hop_count="$(grep -cE "HOP='(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)'" "$OUT" || true)"
[[ "$hop_count" -eq 4 ]] || fail "expected four hop HOP= assignments, got ${hop_count}"
mirror_count="$(grep -c "MIRROR='http://192.0.2.10'" "$OUT" || true)"
[[ "$mirror_count" -ge 4 ]] || fail "expected MIRROR pin in hop lines, got ${mirror_count}"
grep -q -- '--mirror-base "\$MIRROR"' "$OUT" || fail "hop command lacks --mirror-base"
second_cmd="$(gui_client_hop_command_line "http://192.0.2.20" "dp-offline-upgrade-xenial-to-bionic.sh")"
[[ "$(printf '%s\n' "$second_cmd" | wc -l | tr -d ' ')" == "1" ]] \
  || fail "hop command_line must be one physical line"
[[ "$second_cmd" == *"MIRROR='http://192.0.2.20'"* ]] \
  || fail "second fixture URL missing from hop command"
[[ "$second_cmd" == *"--mirror-base \"\$MIRROR\""* ]] \
  || fail "second fixture missing --mirror-base \$MIRROR"
grep -q 'License is valid' "$OUT" || fail "license check missing"
pass "FULL mode client commands"

# --- PHASE2_ONLY mode: no OS hops ---
PREPARATION_MODE=PHASE2_ONLY
P2_OUT="$TMP/cmds-p2.txt"
gui_build_client_commands "http://192.0.2.10" "single" "" >"$P2_OUT"
grep -q 'DP Phase 2 Upgrade Commands' "$P2_OUT" || fail "phase2 title missing"
grep -q 'Required OS: Ubuntu 24.04' "$P2_OUT" || fail "required OS missing"
grep -q 'Ubuntu 16.04 to 18.04\|UBUNTU 16.04 TO 18.04' "$P2_OUT" && fail "PHASE2_ONLY still has OS hops" || true
grep -q 'dp-offline-upgrade-xenial-to-bionic' "$P2_OUT" && fail "PHASE2_ONLY hop script present" || true
grep -qE 'STEP 2 — STAGE DP 6.5.0|Step 2 — Stage DP 6.5.0 files' "$P2_OUT" \
  || fail "phase2 stage step missing"
grep -qE 'STEP 3 — RUN DP 6.5.0 BRINGUP|Step 3 — Run DP 6.5.0 bringup' "$P2_OUT" \
  || fail "phase2 bringup missing"
grep -Fq -- '--same-version-recovery' "$P2_OUT" || fail "phase2 same-version-recovery missing"
grep -q 'BEGIN STEP\|BEGIN PHASE' "$P2_OUT" && fail "phase2 still has BEGIN markers" || true
pass "PHASE2_ONLY omits OS hop commands"

# Forbidden strings
for bad in \
  CLIENT_DOWNLOAD_SOURCE CLIENT_R2_ACCESS CLIENT_ACPS_ACCESS \
  PROJECT_ROLLBACK_SUPPORTED 'Repeat similarly' '<mirror-ip>' \
  'Worker management IPs' '--source-dp-version' \
  'Current DP Version' 'Target DP Version' \
  '221.139.249.111' '221.139.249.112'
do
  if grep -Fq -- "$bad" "$OUT"; then
    fail "forbidden string present in FULL: $bad"
  fi
  if grep -Fq -- "$bad" "$P2_OUT"; then
    fail "forbidden string present in PHASE2_ONLY: $bad"
  fi
done
pass "forbidden strings absent"

# Cluster bringup
CLUSTER_OUT="$TMP/cluster.txt"
PREPARATION_MODE=FULL
gui_build_client_commands "http://192.0.2.10" "cluster" "192.168.124.23,192.168.124.24" \
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
MIRROR_HTTP_URL="http://192.0.2.10"
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
MIRROR_HTTP_URL=http://192.0.2.10
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

# Menu 7: topology first; version input count=0; full instructions via secure pager
PREPARATION_MODE=FULL
MIRROR_HTTP_URL="http://192.0.2.10"
# Persist FULL before stubbing save — gui_client_instructions reloads config.
mm_save_gui_config >/dev/null
MENU7_TRACE="$TMP/menu7.trace"
: >"$MENU7_TRACE"
INPUTBOX_COUNT=0
TEXTBOX_COUNT=0
PAGER_COUNT=0
mm_whiptail_input() {
  INPUTBOX_COUNT=$((INPUTBOX_COUNT + 1))
  printf 'INPUT\t%s\n' "$*" >>"$MENU7_TRACE"
  fail "unexpected input prompt on single path: $*"
}
# NOTE: $(mm_whiptail_menu) runs in a subshell — do not rely on call counters.
mm_whiptail_menu() {
  printf 'MENU\t%s\n' "$1" >>"$MENU7_TRACE"
  case "$1" in
    "DP deployment type") printf '1\n' ;;  # single
    *" — view"*) fail "secondary viewer menu must not appear: $1" ;;
    *) fail "unexpected menu after topology: $1" ;;
  esac
}
mm_whiptail_textbox() {
  TEXTBOX_COUNT=$((TEXTBOX_COUNT + 1))
  printf 'TEXTBOX\t%s\t%s\n' "$1" "$2" >>"$MENU7_TRACE"
  return 0
}
mm_view_long_text_file() {
  PAGER_COUNT=$((PAGER_COUNT + 1))
  printf 'PAGER\t%s\t%s\n' "$1" "$2" >>"$MENU7_TRACE"
  return 0
}
mm_whiptail_msg() { printf 'MSG\t%s\n' "$*" >>"$MENU7_TRACE"; return 0; }
load_mirror_defaults() { :; }
engine_resolve_paths() { :; }
mm_save_gui_config() { return 0; }
rm -f "$(mm_client_commands_file)"
gui_client_instructions
[[ "$INPUTBOX_COUNT" -eq 0 ]] || fail "menu7 version inputbox count=${INPUTBOX_COUNT}"
[[ "$TEXTBOX_COUNT" -eq 0 ]] || fail "menu7 must not use textbox for long commands, got ${TEXTBOX_COUNT}"
[[ "$PAGER_COUNT" -eq 1 ]] || fail "menu7 expected exactly one pager view, got ${PAGER_COUNT}"
grep -q $'MENU\tDP deployment type' "$MENU7_TRACE" || fail "first menu7 prompt not topology"
grep -q ' — view' "$MENU7_TRACE" && fail "secondary viewer menu still present" || true
grep -q 'Show complete instructions' "$INSTALLER" && fail "Show complete instructions string still in installer" || true
grep -q 'Show Step 2 command block' "$INSTALLER" && fail "Show Step submenu still in installer" || true
grep -q 'gui_client_commands_viewer' "$INSTALLER" && fail "gui_client_commands_viewer still present" || true
[[ -f "$(mm_client_commands_file)" ]] || fail "menu7 did not create command file"
[[ "$(stat -c '%a' "$(mm_client_commands_file)")" == "644" ]] || fail "menu7 file mode not 644"
grep -Fq -- '--source-dp-version' "$(mm_client_commands_file)" && fail "menu7 has source" || true
grep -Fq -- '--target-version' "$(mm_client_commands_file)" || fail "menu7 missing target"
grep -Fq -- '--same-version-recovery' "$(mm_client_commands_file)" || fail "menu7 missing recovery"
for n in 0 1 2 3 4 5 6 7 8 9; do
  grep -qE "STEP ${n} —|Step ${n} —" "$(mm_client_commands_file)" \
    || fail "menu7 missing step ${n}"
done
grep -q 'BEGIN STEP' "$(mm_client_commands_file)" && fail "menu7 still has BEGIN STEP" || true
grep -q 'public-keyring.gpg' "$(mm_client_commands_file)" || fail "menu7 missing public-keyring.gpg"
grep -q 'gpgv --keyring ./public-keyring.gpg' "$(mm_client_commands_file)" \
  || fail "menu7 missing gpgv public-keyring"
# Saved file and generators must agree (same one-line hop/stage content).
gen_hop="$(gui_client_hop_command_line "http://192.0.2.10" "dp-offline-upgrade-xenial-to-bionic.sh")"
grep -Fxq "$gen_hop" "$(mm_client_commands_file)" \
  || fail "saved file hop line differs from gui_client_hop_command_line"
gen_stage="$(gui_phase2_stage_command_line "http://192.0.2.10" "6.5.0")"
grep -Fxq "$gen_stage" "$(mm_client_commands_file)" \
  || fail "saved file stage line differs from gui_phase2_stage_command_line"
grep -q 'mm_view_long_text_file\|mm_terminal_pager' "$INSTALLER" \
  || fail "menu7 missing secure pager call"
grep -q 'mm_whiptail_textbox "\$title" "\$out_file"' "$INSTALLER" \
  && fail "menu7 still uses whiptail textbox for command file" || true
pass "menu7 shows full instructions via secure pager; no secondary viewer"

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
