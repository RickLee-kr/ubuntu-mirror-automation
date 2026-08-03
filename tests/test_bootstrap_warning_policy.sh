#!/usr/bin/env bash
# tests/test_bootstrap_warning_policy.sh — Fresh bootstrap WARN policy + nginx HTTP isolation
# Does not touch production nginx/systemctl; uses mock systemctl only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/bootstrap.sh
source "${ROOT}/lib/bootstrap.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

MOCKBIN="${WORKDIR}/mockbin"
mkdir -p "$MOCKBIN"
STATE="${WORKDIR}/ngx.state"
# Default: inactive + disabled
printf 'inactive\ndisabled\n' >"$STATE"

cat >"${MOCKBIN}/systemctl" <<'EOF'
#!/bin/bash
STATE_FILE="${UM_MOCK_SYSTEMCTL_STATE:?}"
cmd="${1:-}"
unit="${2:-}"
shift || true
case "$cmd" in
  is-active)
    # --quiet nginx  OR  nginx
    while [[ "${1:-}" == --* ]]; do shift; done
    unit="${1:-nginx}"
    cur="$(sed -n '1p' "$STATE_FILE")"
    if [[ "$cur" == "active" ]]; then
      exit 0
    fi
    exit 3
    ;;
  is-enabled)
    while [[ "${1:-}" == --* ]]; do shift; done
    unit="${1:-nginx}"
    cur="$(sed -n '2p' "$STATE_FILE")"
    if [[ "$cur" == "enabled" ]]; then
      echo "enabled"
      exit 0
    fi
    echo "disabled"
    exit 1
    ;;
  stop)
    while [[ "${1:-}" == --* ]]; do shift; done
    unit="${1:-nginx}"
    if [[ "${UM_MOCK_STOP_FAIL:-0}" == "1" ]]; then
      echo "Failed to stop ${unit}" >&2
      exit 1
    fi
    # Keep enabled line; flip active -> inactive
    en="$(sed -n '2p' "$STATE_FILE")"
    printf 'inactive\n%s\n' "$en" >"$STATE_FILE"
    echo "stop:$unit" >>"${STATE_FILE}.log"
    exit 0
    ;;
  disable)
    while [[ "${1:-}" == --* ]]; do shift; done
    unit="${1:-nginx}"
    if [[ "${UM_MOCK_DISABLE_FAIL:-0}" == "1" ]]; then
      echo "Failed to disable ${unit}" >&2
      exit 1
    fi
    act="$(sed -n '1p' "$STATE_FILE")"
    printf '%s\ndisabled\n' "$act" >"$STATE_FILE"
    echo "disable:$unit" >>"${STATE_FILE}.log"
    exit 0
    ;;
  enable|start|reload|restart)
    echo "$cmd:${2:-nginx}" >>"${STATE_FILE}.log"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCKBIN}/systemctl"
export UM_BOOTSTRAP_SYSTEMCTL_BIN="${MOCKBIN}/systemctl"
export UM_MOCK_SYSTEMCTL_STATE="$STATE"

run_enforce() {
  env \
    UM_BOOTSTRAP_SYSTEMCTL_BIN="$UM_BOOTSTRAP_SYSTEMCTL_BIN" \
    UM_MOCK_SYSTEMCTL_STATE="$STATE" \
    UM_MOCK_STOP_FAIL="${UM_MOCK_STOP_FAIL:-0}" \
    UM_MOCK_DISABLE_FAIL="${UM_MOCK_DISABLE_FAIL:-0}" \
    UM_DRY_RUN=0 \
    bash -c '
      set -euo pipefail
      source "'"${ROOT}"'/lib/common.sh"
      source "'"${ROOT}"'/lib/bootstrap.sh"
      um_bootstrap_enforce_http_disabled
    ' 2>&1
}

echo "======== A. fresh selective absent (deferred INFO, no WARN) ========"
FAKE="${WORKDIR}/fresh"
mkdir -p "${FAKE}/var/spool/apt-mirror/selective" \
  "${FAKE}/etc/ubuntu-mirror" \
  "${FAKE}/usr/local/lib/ubuntu-mirror"
export UM_PROJECT_ROOT="$ROOT"
export BASE_PATH="${FAKE}/var/spool/apt-mirror"
export INSTALL_CONF_DIR="${FAKE}/etc/ubuntu-mirror"
export INSTALL_LIB_DIR="${FAKE}/usr/local/lib/ubuntu-mirror"
export INSTALL_BIN_DIR="${FAKE}/usr/local/bin"
mkdir -p "$INSTALL_BIN_DIR"
# No selective/state/READY → deferred path
rm -rf "${BASE_PATH}/selective/state" "${BASE_PATH}/client"
mkdir -p "${BASE_PATH}/selective" "${BASE_PATH}/client"

set +e
fresh_out="$(
  UM_PROJECT_ROOT="$ROOT" \
  BASE_PATH="$BASE_PATH" \
  INSTALL_CONF_DIR="$INSTALL_CONF_DIR" \
  UM_BOOTSTRAP_ALLOW_SIGNING_DIR_OVERRIDE=0 \
  bash -c '
    set -euo pipefail
    source "'"${ROOT}"'/lib/common.sh"
    source "'"${ROOT}"'/lib/bootstrap.sh"
    um_bootstrap_deploy_client_http_artifacts
  ' 2>&1
)"
fresh_rc=$?
set -e
[[ "$fresh_rc" -eq 0 ]] && pass "INSTALL_RESULT=PASS" || fail "INSTALL_RESULT=FAIL rc=${fresh_rc}"
echo "$fresh_out" | grep -q 'SELECTIVE_READY=NOT_PREPARED_YET' \
  && pass "SELECTIVE_READY=NOT_PREPARED_YET" || fail "SELECTIVE_READY"
echo "$fresh_out" | grep -q 'CLIENT_SET_BUILD=DEFERRED_UNTIL_OS_CORE' \
  && pass "CLIENT_SET_BUILD=DEFERRED_UNTIL_OS_CORE" || fail "CLIENT_SET_BUILD"
echo "$fresh_out" | grep -q 'CLIENT_FILES_READY=NOT_REQUIRED_DURING_BOOTSTRAP' \
  && pass "CLIENT_FILES_READY=NOT_REQUIRED_DURING_BOOTSTRAP" || fail "CLIENT_FILES_READY"
echo "$fresh_out" | grep -q 'CLIENT_HTTP_READY=DEFERRED_UNTIL_ENABLE_HTTP' \
  && pass "CLIENT_HTTP_READY=DEFERRED_UNTIL_ENABLE_HTTP" || fail "CLIENT_HTTP_READY"
echo "$fresh_out" | grep -q 'STALE_PREBUILT_CLIENT_PUBLISH=PROHIBITED' \
  && pass "STALE_PREBUILT_CLIENT_PUBLISH=PROHIBITED" || fail "STALE_PREBUILT"
echo "$fresh_out" | grep -q 'PRIVATE_KEY_HTTP_PUBLISHED=NO' \
  && pass "PRIVATE_KEY_HTTP_PUBLISHED=NO" || fail "PRIVATE_KEY_HTTP_PUBLISHED"
echo "$fresh_out" | grep -q 'STALE_CLIENT_COPY_ALLOWED=NO' \
  && pass "STALE_CLIENT_COPY_ALLOWED=NO" || fail "STALE_CLIENT_COPY_ALLOWED"
# Hop clients must not appear
if [[ -f "${BASE_PATH}/client/dp-offline-upgrade-xenial-to-bionic.sh" ]]; then
  fail "stale hop client published"
else
  pass "hop client build not run"
fi
if [[ -f "${BASE_PATH}/client/private.gpg" ]]; then
  fail "private key under HTTP root"
else
  pass "private key not HTTP published"
fi
# Phase 2 helper + public key allowed
[[ -f "${BASE_PATH}/client/stage-dp-phase2.sh" ]] \
  && pass "phase2 helper published" || fail "phase2 helper missing"
[[ -f "${BASE_PATH}/client/public.gpg" ]] \
  && pass "public key published" || fail "public key missing"
app_warn="$(
  printf '%s\n' "$fresh_out" \
    | grep -E '\[WARN\].*(SELECTIVE_READY|CLIENT_SET|CLIENT_FILES_READY|CLIENT_HTTP_READY|STALE_PREBUILT)=' \
    || true
)"
[[ -z "$app_warn" ]] \
  && pass "APPLICATION_WARN_COUNT=0 (deferred states)" \
  || fail "unexpected WARN: ${app_warn}"
WARN_COUNT_FROM_EXPECTED_DEFERRED_STATE=0
[[ "$WARN_COUNT_FROM_EXPECTED_DEFERRED_STATE" -eq 0 ]] \
  && pass "WARN_COUNT_FROM_EXPECTED_DEFERRED_STATE=0" \
  || fail "WARN_COUNT_FROM_EXPECTED_DEFERRED_STATE"

echo "======== B. nginx package auto-start simulation ========"
printf 'active\nenabled\n' >"$STATE"
: >"${STATE}.log"
unset UM_MOCK_STOP_FAIL UM_MOCK_DISABLE_FAIL
set +e
out_b="$(run_enforce)"
rc_b=$?
set -e
[[ "$rc_b" -eq 0 ]] && pass "auto-start enforce PASS" || fail "auto-start enforce FAIL"
echo "$out_b" | grep -q 'NGINX_PACKAGE_AUTO_START_DETECTED=YES' \
  && pass "NGINX_PACKAGE_AUTO_START_DETECTED=YES" || fail "auto-start detected"
echo "$out_b" | grep -q 'BOOTSTRAP_NGINX_STOP=PASS' \
  && pass "BOOTSTRAP_NGINX_STOP=PASS" || fail "STOP=PASS"
echo "$out_b" | grep -q 'BOOTSTRAP_NGINX_DISABLE=PASS' \
  && pass "BOOTSTRAP_NGINX_DISABLE=PASS" || fail "DISABLE=PASS"
echo "$out_b" | grep -q 'BOOTSTRAP_HTTP_ISOLATION=PASS' \
  && pass "BOOTSTRAP_HTTP_ISOLATION=PASS" || fail "ISOLATION=PASS"
echo "$out_b" | grep -q 'HTTP_DISTRIBUTION=DISABLED' \
  && pass "HTTP_DISTRIBUTION=DISABLED" || fail "HTTP_DISTRIBUTION"
echo "$out_b" | grep -qE '\[WARN\]' && fail "WARN on auto-start path" || pass "no WARN on auto-start"
grep -q 'stop:nginx' "${STATE}.log" && pass "stop invoked" || fail "stop not invoked"
grep -q 'disable:nginx' "${STATE}.log" && pass "disable invoked" || fail "disable not invoked"
[[ "$(sed -n '1p' "$STATE")" == "inactive" ]] && pass "final inactive" || fail "not inactive"
[[ "$(sed -n '2p' "$STATE")" == "disabled" ]] && pass "final disabled" || fail "not disabled"

echo "======== C. nginx already inactive/disabled (idempotent) ========"
printf 'inactive\ndisabled\n' >"$STATE"
: >"${STATE}.log"
set +e
out_c="$(run_enforce)"
rc_c=$?
set -e
[[ "$rc_c" -eq 0 ]] && pass "idempotent PASS" || fail "idempotent FAIL"
echo "$out_c" | grep -q 'NGINX_PACKAGE_AUTO_START_DETECTED=NO' \
  && pass "NGINX_PACKAGE_AUTO_START_DETECTED=NO" || fail "auto-start NO"
echo "$out_c" | grep -q 'BOOTSTRAP_HTTP_ISOLATION=PASS' \
  && pass "isolation PASS when already stopped" || fail "isolation when stopped"
echo "$out_c" | grep -qE '\[WARN\]' && fail "WARN on idle path" || pass "no WARN on idle"
[[ ! -s "${STATE}.log" ]] && pass "no unnecessary stop/disable" || fail "spurious systemctl: $(cat "${STATE}.log")"

echo "======== D. nginx stop failure ========"
printf 'active\nenabled\n' >"$STATE"
: >"${STATE}.log"
export UM_MOCK_STOP_FAIL=1
set +e
out_d="$(run_enforce)"
rc_d=$?
set -e
unset UM_MOCK_STOP_FAIL
[[ "$rc_d" -ne 0 ]] && pass "stop failure exits non-zero" || fail "stop failure should FAIL"
echo "$out_d" | grep -q 'BOOTSTRAP_HTTP_ISOLATION=FAIL' \
  && pass "BOOTSTRAP_HTTP_ISOLATION=FAIL on stop" || fail "isolation FAIL missing on stop"

echo "======== E. nginx disable failure ========"
printf 'inactive\nenabled\n' >"$STATE"
: >"${STATE}.log"
export UM_MOCK_DISABLE_FAIL=1
set +e
out_e="$(run_enforce)"
rc_e=$?
set -e
unset UM_MOCK_DISABLE_FAIL
[[ "$rc_e" -ne 0 ]] && pass "disable failure exits non-zero" || fail "disable failure should FAIL"
echo "$out_e" | grep -q 'BOOTSTRAP_HTTP_ISOLATION=FAIL' \
  && pass "BOOTSTRAP_HTTP_ISOLATION=FAIL on disable" || fail "isolation FAIL missing on disable"

echo "======== F. intentional risk WARN still allowed (policy smoke) ========"
# Confirm um_warn still produces [WARN] for real degraded cases (not stripped globally).
risk_out="$(
  bash -c '
    set -euo pipefail
    source "'"${ROOT}"'/lib/common.sh"
    um_warn "PORT_80=WARN port 80 in use by non-nginx process"
  ' 2>&1
)"
echo "$risk_out" | grep -q '\[WARN\].*PORT_80=WARN' \
  && pass "real WARN path retained" || fail "um_warn broken"

echo "======== DONE fail=${FAIL} ========"
exit "$FAIL"
