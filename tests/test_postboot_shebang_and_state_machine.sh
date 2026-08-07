#!/usr/bin/env bash
# tests/test_postboot_shebang_and_state_machine.sh
# Regression: postboot executable shebang-first invariant + state classification
# + failed-postboot fail-closed across Xenial→…→Noble hops.
set -euo pipefail
unset STELLAR_OFFLINE_TEST_ROOT DETACH_AFTER_HANDOFF DP_OFFLINE_TEST_HANDOFF || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

OUT_DIR="$(mktemp -d /tmp/postboot-state-reg.XXXXXX)"
trap 'rm -rf "$OUT_DIR"' EXIT

ACES="${ROOT}/scripts/lib/assert_client_executable_shebang.py"
RENDER="${ROOT}/tests/lib/render_offline_upgrade_stub.py"
[[ -f "$ACES" ]] || { echo "missing $ACES"; exit 1; }
[[ -f "$RENDER" ]] || { echo "missing $RENDER"; exit 1; }

declare -A HOP_TEMPLATE=(
  [xenial-to-bionic]="client/dp-offline-upgrade-xenial-to-bionic.sh.in"
  [bionic-to-focal]="client/dp-offline-upgrade-bionic-to-focal.sh.in"
  [focal-to-jammy]="client/dp-offline-upgrade-focal-to-jammy.sh.in"
  [jammy-to-noble]="client/dp-offline-upgrade-jammy-to-noble.sh.in"
)
declare -A HOP_COMPLETED=(
  [xenial-to-bionic]="COMPLETED_BIONIC"
  [bionic-to-focal]="COMPLETED_FOCAL"
  [focal-to-jammy]="COMPLETED_JAMMY"
  [jammy-to-noble]="COMPLETED_NOBLE"
)
declare -A HOP_PREPARING=(
  [xenial-to-bionic]="PREPARING_XENIAL"
  [bionic-to-focal]="PREPARING_BIONIC"
  [focal-to-jammy]="PREPARING_FOCAL"
  [jammy-to-noble]="PREPARING_JAMMY"
)
declare -A HOP_UPGRADING=(
  [xenial-to-bionic]="UPGRADING_XENIAL_TO_BIONIC"
  [bionic-to-focal]="UPGRADING_BIONIC_TO_FOCAL"
  [focal-to-jammy]="UPGRADING_FOCAL_TO_JAMMY"
  [jammy-to-noble]="UPGRADING_JAMMY_TO_NOBLE"
)

HOPS=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)

# --- helpers -----------------------------------------------------------------
expand_hop() {
  local hop="$1"
  local out="$2"
  python3 "$RENDER" --helpers-only \
    "${ROOT}/${HOP_TEMPLATE[$hop]}" "$out"
}

materialize_postboot() {
  # Extract postboot body from helper-expanded template into an executable file.
  local expanded="$1"
  local dest="$2"
  python3 - "$expanded" "$dest" <<'PY'
import re, sys
from pathlib import Path
src, dest = sys.argv[1], sys.argv[2]
text = Path(src).read_text(encoding="utf-8")

def body(marker):
    m = re.search(r"<<['\"]?%s['\"]?\s*\n" % re.escape(marker), text)
    if not m:
        return None
    start = m.end()
    c = re.search(r"(?m)^%s\s*$" % re.escape(marker), text[start:])
    if not c:
        raise SystemExit("unclosed " + marker)
    return text[start:start + c.start()]

hdr = body("POSTBOOT_HDR")
main = body("POSTBOOT_MAIN")
simple = body("POSTBOOT")
if hdr is not None:
    # jammy: HDR (shebang+helpers+policy) + MAIN (main())
    content = hdr + (main or "")
elif simple is not None:
    content = simple
else:
    raise SystemExit("no POSTBOOT heredoc in " + src)
Path(dest).write_text(content, encoding="utf-8")
PY
  chmod 0755 "$dest"
}

build_state_harness() {
  local hop="$1"
  local expanded="$2"
  local harness="$3"
  local completed="${HOP_COMPLETED[$hop]}"
  local preparing="${HOP_PREPARING[$hop]}"
  local upgrading="${HOP_UPGRADING[$hop]}"
  {
    cat <<EOS
#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="\${DP_OFFLINE_TEST_ROOT:-}"
LOG_FILE="/var/log/aella/offline_os_upgrade.log"
STATE_ROOT="/opt/aelladata/os-upgrade/offline"
STATE_FILE="\${STATE_ROOT}/state"
UNIT_NAME="stellar-offline-os-upgrade.service"
POSTBOOT_UNIT_NAME="stellar-offline-os-upgrade-postboot.service"
BACKUP_ROOT="\${STATE_ROOT}/backups"
HOLDS_DIR="\${STATE_ROOT}/critical-holds"
ENV_DEFAULT_FILE="/etc/default/stellar-offline-os-upgrade"
PIN_ENV_FILE="\${STATE_ROOT}/pins.env"
RUNNER_PID_FILE="\${STATE_ROOT}/runner.pid"
SYSTEMCTL_BIN="\${SYSTEMCTL_BIN:-systemctl}"
HANDOFF_WAIT_SECS=3
HANDOFF_POLL_SECS=1
HANDOFF_CONFIRMED=0
UPGRADE_RUNNER_PID=0
DBUS_DISCONNECT_SEEN=0
LAST_SYSTEMCTL_OUTPUT=""
LAST_SYSTEMCTL_RC=0
DETACH_AFTER_HANDOFF="\${DETACH_AFTER_HANDOFF:-0}"
MONITOR_POLL_SECS="\${DP_OFFLINE_MONITOR_POLL_SECS:-1}"
MONITOR_HEARTBEAT_SECS="\${DP_OFFLINE_MONITOR_HEARTBEAT_SECS:-2}"
MONITOR_RECENT_LINES=15
MONITOR_INTERRUPTED=0
MONITOR_EXIT_REASON=""
MONITOR_LOG_OFFSET=0
LIVE_SERVICE_ACTIVE="NO"
LIVE_RUNNER_PRESENT="NO"
LIVE_DRO_PRESENT="NO"
LIVE_MAIN_PID="0"
EC_OK=0
EC_BUSY=22
EC_HANDOFF=30
EC_STATE=23
EC_INTERNAL=99
EC_PARTIAL_TRANSITION=27
PIN_SOURCE_VERSION="16.04"
PREVIOUS_FAILURE_CLASS=""
PREVIOUS_FAILURE_DETECTED="NO"
PARTIAL_RELEASE_TRANSITION="NO"
RESUME_FROM=""
RELEASE_UPGRADE_STARTED="false"
RELEASE_UPGRADE_INVOCATION_STARTED="false"
RELEASE_UPGRADE_PROCESS_SPAWNED="false"
RELEASE_UPGRADE_PACKAGE_TRANSITION_STARTED="false"
RELEASE_UPGRADE_COMPLETED="false"
LEGACY_STATE_RECONCILED="false"
RECONCILIATION_REASON=""
DOWNLOAD_ATTEMPTED=0
http_fetch() { DOWNLOAD_ATTEMPTED=1; return 1; }
http_code() { DOWNLOAD_ATTEMPTED=1; printf '000'; }
hostpath() {
  local p="\$1"
  if [[ -n "\$TEST_ROOT" ]]; then printf '%s%s' "\$TEST_ROOT" "\$p"; else printf '%s' "\$p"; fi
}
log() {
  local level="\$1"; shift
  local msg="\$*"
  printf '%s [%s] %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "\$level" "\$msg"
  mkdir -p "\$(dirname "\$(hostpath "\$LOG_FILE")")" 2>/dev/null || true
  printf '%s [%s] %s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)" "\$level" "\$msg" >>"\$(hostpath "\$LOG_FILE")" 2>/dev/null || true
}
die() { local code="\$1"; shift; log ERROR "\$* (exit=\${code})"; exit "\$code"; }
write_state() { mkdir -p "\$(dirname "\$(hostpath "\$STATE_FILE")")"; printf '%s\n' "\$1" >"\$(hostpath "\$STATE_FILE")"; }
read_state() {
  local f; f="\$(hostpath "\$STATE_FILE")"
  if [[ -f "\$f" ]]; then tr -d '\r' <"\$f" | head -1; else printf ''; fi
}
EOS
    # Include durable helpers referenced by handoff block after expansion.
    # Extract from systemd handoff through commit_and_start (exclusive).
    awk '
      /^# --- systemd handoff/ {p=1}
      /^commit_and_start\(\)/ {exit}
      p
    ' "$expanded"
  } >"$harness"
  # Soften bash -n: harness may reference hop-specific symbols later; syntax only.
  bash -n "$harness" || {
    fail "$hop harness bash -n"
    return 1
  }
  return 0
}

install_unit_aware_systemctl() {
  local root="$1"
  local upgrade_active="${2:-inactive}"
  local postboot_active="${3:-failed}"
  cat >"$root/bin/systemctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
ROOT='$root'
UP_ACTIVE='$upgrade_active'
PB_ACTIVE='$postboot_active'
CALLS="\$ROOT/run/systemctl-calls.txt"
mkdir -p "\$ROOT/run"
printf '%s\n' "\$*" >>"\$CALLS"
cmd="\${1:-}"; shift || true
case "\$cmd" in
  daemon-reload|reset-failed|enable|status|start|stop|disable) exit 0 ;;
  show)
    prop=""; unit=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        -p) prop="\$2"; shift 2 ;;
        *) unit="\$1"; shift ;;
      esac
    done
    active="\$UP_ACTIVE"
    case "\$unit" in
      *postboot*) active="\$PB_ACTIVE" ;;
    esac
    case "\$prop" in
      MainPID) echo "MainPID=0" ;;
      ActiveState) echo "ActiveState=\${active}" ;;
      SubState)
        if [[ "\$active" == "failed" ]]; then echo "SubState=failed"
        elif [[ "\$active" == "active" || "\$active" == "activating" ]]; then echo "SubState=running"
        else echo "SubState=dead"; fi
        ;;
      LoadState) echo "LoadState=loaded" ;;
      *) echo "\${prop}=" ;;
    esac
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$root/bin/systemctl"
}

# =============================================================================
# TEST 1–3: build-time helper injection → postboot shebang + bash -n (4 hops)
# =============================================================================
echo "== TEST 1–3: generated postboot shebang + syntax (4 hops) =="
for hop in "${HOPS[@]}"; do
  exp="${OUT_DIR}/${hop}.expanded.sh.in"
  expand_hop "$hop" "$exp" || { fail "$hop helper expand"; continue; }
  # Assert via production assert helper (same as build_client_*.py).
  if python3 "$ACES" "$exp" "$hop" >"${OUT_DIR}/${hop}.shebang.out" 2>"${OUT_DIR}/${hop}.shebang.err"; then
    pass "$hop build-time shebang assert"
  else
    fail "$hop build-time shebang assert"
    cat "${OUT_DIR}/${hop}.shebang.err" || true
  fi

  pb="${OUT_DIR}/${hop}.postboot"
  if materialize_postboot "$exp" "$pb"; then
    first="$(head -c 2 "$pb" | od -An -tx1 | tr -d ' \n')"
    # 23 21 == '#!'
    if [[ "$first" == "2321" ]]; then
      pass "$hop postboot first bytes are #!"
    else
      fail "$hop postboot first bytes=${first} (want 2321)"
    fi
    line1="$(head -1 "$pb")"
    if [[ "$line1" == "#!/usr/bin/env bash" || "$line1" == "#!/bin/bash" ]]; then
      pass "$hop postboot head -1 interpreter ($line1)"
    else
      fail "$hop postboot head -1='$line1'"
    fi
    if bash -n "$pb" 2>"${OUT_DIR}/${hop}.postboot.bashn.err"; then
      pass "$hop postboot bash -n"
    else
      fail "$hop postboot bash -n"
      cat "${OUT_DIR}/${hop}.postboot.bashn.err" || true
    fi
    # Durable helper must NOT precede shebang in materialized body.
    if awk 'NR==1{exit} /^# Shared durable/{found=1} END{exit found?0:1}' "$pb"; then
      fail "$hop durable helper appears before shebang scan anomaly"
    else
      # Confirm shebang is line 1 and durable comment (if any) is after.
      if head -1 "$pb" | grep -q '^#!' \
         && ! awk 'NR==1 && /^# Shared durable/ {exit 0} NR==1 {exit 1}' "$pb"; then
        pass "$hop shebang precedes durable helper body"
      else
        fail "$hop shebang/helper ordering"
      fi
    fi
  else
    fail "$hop materialize postboot"
  fi
done

# Optional: full production render path when selective mirror is present.
SEL_ROOT="${TEST_SELECTIVE_ROOT:-/var/spool/apt-mirror/selective}"
MIRROR_BASE="${TEST_MIRROR_BASE:-http://192.0.2.10}"
if [[ -f "${SEL_ROOT}/keys/ubuntu-mirror-selective.gpg" && -f "${SEL_ROOT}/state/READY" ]]; then
  echo "== optional live build shebang checks =="
  for hop in "${HOPS[@]}"; do
    py="${ROOT}/scripts/lib/build_client_${hop//-/_}.py"
    hop_out="${OUT_DIR}/live-${hop}"
    mkdir -p "$hop_out"
    set +e
    python3 "$py" \
      --project-root "$ROOT" \
      --mirror-base "$MIRROR_BASE" \
      --selective-root "$SEL_ROOT" \
      --content-source local-fs \
      --output-dir "$hop_out" \
      --deploy-nginx-root "${hop_out}/nginx" \
      --skip-sign \
      >"${hop_out}/build.log" 2>&1
    rc=$?
    set -e
    built="${hop_out}/dp-offline-upgrade-${hop}.sh"
    if [[ "$rc" -eq 0 && -f "$built" ]]; then
      if python3 "$ACES" "$built" "$hop-live" >/dev/null; then
        pass "$hop live-build shebang assert"
      else
        fail "$hop live-build shebang assert"
      fi
      bash -n "$built" && pass "$hop live-build bash -n" || fail "$hop live-build bash -n"
    else
      echo "  SKIP: live build unavailable for $hop (rc=${rc})"
    fi
  done
else
  echo "  SKIP: selective root not available for live build path"
fi

# =============================================================================
# TEST 4 + 7: transitional ≠ terminal success; disjoint classification
# =============================================================================
echo "== TEST 4+7: state classification invariants =="
for hop in "${HOPS[@]}"; do
  exp="${OUT_DIR}/${hop}.expanded.sh.in"
  [[ -f "$exp" ]] || expand_hop "$hop" "$exp"
  harness="${OUT_DIR}/${hop}.state-harness.sh"
  if ! build_state_harness "$hop" "$exp" "$harness"; then
    continue
  fi
  # shellcheck disable=SC1090
  (
    # shellcheck source=/dev/null
    source "$harness"
    completed="${HOP_COMPLETED[$hop]}"
    fail_local=0
    for st in REBOOT_PENDING REBOOTING POST_BOOT_VERIFY; do
      if state_is_terminal_success "$st"; then
        echo "FAIL: $hop $st classified terminal_success"
        fail_local=1
      fi
      if ! state_is_reboot_handoff "$st" && [[ "$st" != "POST_BOOT_VERIFY" ]]; then
        echo "FAIL: $hop $st not reboot_handoff"
        fail_local=1
      fi
      if [[ "$st" == "POST_BOOT_VERIFY" ]] && ! state_is_postboot_pending "$st"; then
        echo "FAIL: $hop POST_BOOT_VERIFY not postboot_pending"
        fail_local=1
      fi
      if state_is_upgrade_running "$st" && state_is_terminal_success "$st"; then
        echo "FAIL: $hop $st both running and terminal_success"
        fail_local=1
      fi
    done
    if ! state_is_terminal_success "$completed"; then
      echo "FAIL: $hop $completed not terminal_success"
      fail_local=1
    fi
    if state_is_upgrade_running "$completed"; then
      echo "FAIL: $hop $completed upgrade_running"
      fail_local=1
    fi
    if ! assert_state_classification_disjoint; then
      echo "FAIL: $hop assert_state_classification_disjoint"
      fail_local=1
    fi
    exit "$fail_local"
  ) >"${OUT_DIR}/${hop}.state.out" 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    pass "$hop transitional≠terminal + disjoint invariant"
  else
    fail "$hop state classification"
    cat "${OUT_DIR}/${hop}.state.out" || true
  fi
done

# =============================================================================
# TEST 5: failed postboot fail-closed (next hop must not download / claim running)
# =============================================================================
echo "== TEST 5: failed postboot fail-closed =="
# Next-hop clients that inherit previous transitional state.
for hop in bionic-to-focal focal-to-jammy jammy-to-noble; do
  exp="${OUT_DIR}/${hop}.expanded.sh.in"
  [[ -f "$exp" ]] || expand_hop "$hop" "$exp"
  harness="${OUT_DIR}/${hop}.state-harness.sh"
  [[ -f "$harness" ]] || build_state_harness "$hop" "$exp" "$harness" || continue

  for st in REBOOTING REBOOT_PENDING POST_BOOT_VERIFY; do
    fx="${OUT_DIR}/fx-${hop}-${st}"
    rm -rf "$fx"
    mkdir -p "$fx/opt/aelladata/os-upgrade/offline" "$fx/var/log/aella" \
      "$fx/bin" "$fx/run" "$fx/usr/local/sbin" "$fx/etc/systemd/system"
    : >"$fx/var/log/aella/offline_os_upgrade.log"
    printf '%s\n' "$st" >"$fx/opt/aelladata/os-upgrade/offline/state"
    printf '0\n' >"$fx/opt/aelladata/os-upgrade/offline/runner.pid"
    install_unit_aware_systemctl "$fx" inactive failed
    export DP_OFFLINE_TEST_ROOT="$fx" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$fx"
    export STELLAR_OFFLINE_TEST_ROOT="$fx" SYSTEMCTL_BIN="$fx/bin/systemctl"
    export DETACH_AFTER_HANDOFF=1 DP_OFFLINE_FORCE_NONINTERACTIVE=1
    set +e
    # shellcheck disable=SC1090
    (
      source "$harness"
      DOWNLOAD_ATTEMPTED=0
      refuse_duplicate_upgrade
    ) >"$fx/out.txt" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]] \
       && grep -q 'POSTBOOT_VALIDATION_COMPLETED=NO' "$fx/out.txt" \
       && grep -q 'PREVIOUS_OS_HOP_POSTBOOT_INCOMPLETE=YES' "$fx/out.txt" \
       && grep -q 'NEXT_HOP_BLOCKED=YES' "$fx/out.txt" \
       && grep -q 'BACKGROUND_UPGRADE_RUNNING=NO' "$fx/out.txt" \
       && ! grep -q 'BACKGROUND_UPGRADE_RUNNING=YES' "$fx/out.txt"; then
      pass "$hop fail-closed on state=$st postboot=failed (rc=$rc)"
    else
      fail "$hop fail-closed state=$st (rc=$rc)"
      cat "$fx/out.txt" || true
    fi
    # No network/download side effects from refuse path.
    if grep -qE 'http_fetch|apt-get update|wget |curl ' "$fx/out.txt" 2>/dev/null; then
      fail "$hop unexpected download action logged for $st"
    else
      pass "$hop no download action for state=$st"
    fi
    unset DP_OFFLINE_TEST_ROOT DP_OFFLINE_TEST_HANDOFF TEST_ROOT STELLAR_OFFLINE_TEST_ROOT
    unset SYSTEMCTL_BIN DETACH_AFTER_HANDOFF DP_OFFLINE_FORCE_NONINTERACTIVE
  done
done

# Same-hop (xenial) also fail-closed — re-entry must not claim success.
hop=xenial-to-bionic
exp="${OUT_DIR}/${hop}.expanded.sh.in"
harness="${OUT_DIR}/${hop}.state-harness.sh"
[[ -f "$harness" ]] || build_state_harness "$hop" "$exp" "$harness"
fx="${OUT_DIR}/fx-x2b-REBOOTING"
rm -rf "$fx"
mkdir -p "$fx/opt/aelladata/os-upgrade/offline" "$fx/var/log/aella" "$fx/bin" "$fx/run"
: >"$fx/var/log/aella/offline_os_upgrade.log"
printf 'REBOOTING\n' >"$fx/opt/aelladata/os-upgrade/offline/state"
printf '0\n' >"$fx/opt/aelladata/os-upgrade/offline/runner.pid"
install_unit_aware_systemctl "$fx" inactive failed
export DP_OFFLINE_TEST_ROOT="$fx" DP_OFFLINE_TEST_HANDOFF=1 TEST_ROOT="$fx"
export STELLAR_OFFLINE_TEST_ROOT="$fx" SYSTEMCTL_BIN="$fx/bin/systemctl"
export DETACH_AFTER_HANDOFF=1 DP_OFFLINE_FORCE_NONINTERACTIVE=1
set +e
(
  source "$harness"
  refuse_duplicate_upgrade
) >"$fx/out.txt" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -q 'POSTBOOT_VALIDATION_COMPLETED=NO' "$fx/out.txt" \
   && ! grep -q 'BACKGROUND_UPGRADE_RUNNING=YES' "$fx/out.txt"; then
  pass "xenial-to-bionic fail-closed REBOOTING+postboot failed"
else
  fail "xenial-to-bionic fail-closed REBOOTING (rc=$rc)"
  cat "$fx/out.txt" || true
fi
unset DP_OFFLINE_TEST_ROOT DP_OFFLINE_TEST_HANDOFF TEST_ROOT STELLAR_OFFLINE_TEST_ROOT
unset SYSTEMCTL_BIN DETACH_AFTER_HANDOFF DP_OFFLINE_FORCE_NONINTERACTIVE

# =============================================================================
# TEST 6: COMPLETED_* remains terminal success (classification only)
# =============================================================================
echo "== TEST 6: COMPLETED_* terminal success =="
for hop in "${HOPS[@]}"; do
  harness="${OUT_DIR}/${hop}.state-harness.sh"
  completed="${HOP_COMPLETED[$hop]}"
  (
    source "$harness"
    state_is_terminal_success "$completed"
  ) && pass "$hop $completed is terminal_success" || fail "$hop $completed terminal_success"
done

# =============================================================================
# Similar-pattern audit (A/B/C executable heredocs in upgrade templates)
# =============================================================================
echo "== similar-pattern audit (upgrade templates) =="
AUDIT_FAIL=0
# A/B: any POSTBOOT heredoc must start with shebang in SOURCE templates after our fix
# (helper token may follow shebang; must not precede it)
for hop in "${HOPS[@]}"; do
  tmpl="${ROOT}/${HOP_TEMPLATE[$hop]}"
  if grep -n "<<'POSTBOOT'" "$tmpl" >/dev/null 2>&1; then
    # Lines after <<'POSTBOOT' until first non-empty: must be shebang
    block="$(awk "/<<'POSTBOOT'/{p=1;next} p&&NF{print; exit}" "$tmpl")"
    if [[ "$block" == "#!"* ]]; then
      pass "$hop template POSTBOOT opens with shebang"
    else
      fail "$hop template POSTBOOT opens with: $block"
      AUDIT_FAIL=1
    fi
  elif grep -n "<<'POSTBOOT_HDR'" "$tmpl" >/dev/null 2>&1; then
    block="$(awk "/<<'POSTBOOT_HDR'/{p=1;next} p&&NF{print; exit}" "$tmpl")"
    if [[ "$block" == "#!"* ]]; then
      pass "$hop template POSTBOOT_HDR opens with shebang"
    else
      fail "$hop template POSTBOOT_HDR opens with: $block"
      AUDIT_FAIL=1
    fi
  else
    fail "$hop missing POSTBOOT heredoc marker"
    AUDIT_FAIL=1
  fi
  # RUNNER must keep shebang-first (helper after shebang)
  block="$(awk "/<<'RUNNER'/{p=1;next} p&&NF{print; exit}" "$tmpl")"
  if [[ "$block" == "#!"* ]]; then
    pass "$hop template RUNNER opens with shebang"
  else
    fail "$hop template RUNNER opens with: $block"
    AUDIT_FAIL=1
  fi
done
# Helper itself must remain shebang-less so mid-script injection stays safe.
if head -1 "${ROOT}/client/lib/dp-offline-durable-write.sh" | grep -q '^#!'; then
  fail "durable-write helper unexpectedly has shebang (unsafe for mid-script inject)"
  AUDIT_FAIL=1
else
  pass "durable-write helper has no shebang (safe mid-script inject)"
fi

echo
if [[ "$FAIL" -ne 0 || "$AUDIT_FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
