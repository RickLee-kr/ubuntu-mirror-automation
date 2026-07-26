#!/usr/bin/env bash
# Verify atomic client deploy publishes one unified generation
# (top-level + per-hop script/manifest/signature) without resigning.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_X2B="${ROOT}/scripts/deploy-client-xenial-to-bionic-atomic.sh"
DEPLOY_PY="${ROOT}/scripts/lib/deploy_client_artifacts_atomic.py"
PUB_KEY="${ROOT}/config/client-signing/offline-client-manifest.gpg"
APPROVED_X2B="a41038fb816c1b6cdec439188d851c50f54d7eb191e7e007752399ba73ae0213"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_deploy_client_atomic_consistency ==="
BEFORE_STATUS="$(git -C "$ROOT" status --short)"

[[ -f "$DEPLOY_X2B" && -f "$DEPLOY_PY" && -f "$PUB_KEY" ]] || {
  echo "missing deploy tooling" >&2
  exit 1
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
DEST="${WORKDIR}/client"
mkdir -p "$DEST/other-hop-should-remain"
printf 'keep\n' >"$DEST/other-hop-should-remain/marker"
# Seed stale mixed generation under xenial hop + top-level.
mkdir -p "$DEST/xenial-to-bionic"
printf 'stale-top\n' >"$DEST/dp-offline-upgrade-xenial-to-bionic.sh"
printf 'deadbeef  dp-offline-upgrade-xenial-to-bionic.sh\n' >"$DEST/dp-offline-upgrade-xenial-to-bionic.sh.sha256"
printf 'stale-hop\n' >"$DEST/xenial-to-bionic/dp-offline-upgrade-xenial-to-bionic.sh"
printf '{}\n' >"$DEST/xenial-to-bionic/client-manifest.json"
printf 'bad\n' >"$DEST/xenial-to-bionic/client-manifest.json.asc"

# 1) helper refuses non-.../client dest
set +e
python3 "$DEPLOY_PY" \
  --artifact "${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh" \
  --sidecar "${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256" \
  --hop-dir "${ROOT}/artifacts/client/xenial-to-bionic" \
  --hop-name xenial-to-bionic \
  --script-name dp-offline-upgrade-xenial-to-bionic.sh \
  --dest-root "${WORKDIR}/not-client-root" \
  --pub-key "$PUB_KEY" \
  --expected-sha "$APPROVED_X2B" >"${WORKDIR}/refuse-root.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qi 'refusing dest-root' "${WORKDIR}/refuse-root.log"; then
  pass "helper refuses non-client dest-root"
else
  fail "helper should refuse non-client dest-root (rc=${rc})"
fi

# 2) helper refuses top/hop SHA mismatch
BAD_HOP="${WORKDIR}/bad-hop"
mkdir -p "$BAD_HOP"
cp -a "${ROOT}/artifacts/client/xenial-to-bionic/." "$BAD_HOP/"
printf 'tampered\n' >"$BAD_HOP/dp-offline-upgrade-xenial-to-bionic.sh"
set +e
python3 "$DEPLOY_PY" \
  --artifact "${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh" \
  --sidecar "${ROOT}/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256" \
  --hop-dir "$BAD_HOP" \
  --hop-name xenial-to-bionic \
  --script-name dp-offline-upgrade-xenial-to-bionic.sh \
  --dest-root "$DEST" \
  --pub-key "$PUB_KEY" \
  --expected-sha "$APPROVED_X2B" >"${WORKDIR}/mismatch.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && grep -qi 'top-level/per-hop script SHA mismatch' "${WORKDIR}/mismatch.log"; then
  pass "helper refuses top/hop SHA mismatch"
else
  fail "helper should refuse top/hop mismatch (rc=${rc})"
fi

# 3) full atomic deploy into temp client root (no HTTP, no production write)
set +e
DEST_ROOT="$DEST" SKIP_HTTP_VERIFY=1 bash "$DEPLOY_X2B" >"${WORKDIR}/deploy.log" 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'DEPLOY_OK' "${WORKDIR}/deploy.log" \
  && grep -q 'GENERATION_UNIFIED=YES' "${WORKDIR}/deploy.log" \
  && grep -q 'HOP_MANIFEST_SIGNATURE_VERIFY=PASS' "${WORKDIR}/deploy.log"; then
  pass "xenial atomic deploy into temp DEST_ROOT"
else
  fail "xenial atomic deploy failed (rc=${rc})"
  tail -40 "${WORKDIR}/deploy.log" || true
fi

TOP_SHA="$(sha256sum "$DEST/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
HOP_SHA="$(sha256sum "$DEST/xenial-to-bionic/dp-offline-upgrade-xenial-to-bionic.sh" | awk '{print $1}')"
SIDE_SHA="$(awk '{print $1}' "$DEST/dp-offline-upgrade-xenial-to-bionic.sh.sha256")"
MAN_SHA="$(sha256sum "$DEST/xenial-to-bionic/client-manifest.json" | awk '{print $1}')"
REPO_MAN_SHA="$(sha256sum "${ROOT}/artifacts/client/xenial-to-bionic/client-manifest.json" | awk '{print $1}')"

[[ "$TOP_SHA" == "$APPROVED_X2B" ]] && pass "top-level SHA approved" || fail "top-level SHA $TOP_SHA"
[[ "$HOP_SHA" == "$APPROVED_X2B" ]] && pass "per-hop SHA approved" || fail "per-hop SHA $HOP_SHA"
[[ "$SIDE_SHA" == "$APPROVED_X2B" ]] && pass "sidecar declares approved SHA" || fail "sidecar $SIDE_SHA"
[[ "$TOP_SHA" == "$HOP_SHA" && "$TOP_SHA" == "$SIDE_SHA" ]] && pass "top/hop/sidecar unified" || fail "generation not unified"
[[ "$MAN_SHA" == "$REPO_MAN_SHA" ]] && pass "manifest copied from approved repo" || fail "manifest mismatch"
[[ -f "$DEST/xenial-to-bionic/client-manifest.json.asc" ]] && pass "detached signature published" || fail "signature missing"
[[ -f "$DEST/other-hop-should-remain/marker" ]] && pass "unrelated hop files preserved" || fail "unrelated hop deleted"

# modes
TOP_MODE="$(stat -c '%a' "$DEST/dp-offline-upgrade-xenial-to-bionic.sh")"
SIDE_MODE="$(stat -c '%a' "$DEST/dp-offline-upgrade-xenial-to-bionic.sh.sha256")"
[[ "$TOP_MODE" == "755" ]] && pass "script mode 0755" || fail "script mode $TOP_MODE"
[[ "$SIDE_MODE" == "644" ]] && pass "sidecar mode 0644" || fail "sidecar mode $SIDE_MODE"

# no temp leftovers
if find "$DEST" -name '*.tmp.*' | grep -q .; then
  fail "temp leftovers present"
else
  pass "no temp leftovers"
fi

# backups created for prior stale files
if compgen -G "$DEST/dp-offline-upgrade-xenial-to-bionic.sh.bak-*" >/dev/null; then
  pass "top-level backup created"
else
  fail "top-level backup missing"
fi

AFTER_STATUS="$(git -C "$ROOT" status --short)"
if [[ "$BEFORE_STATUS" == "$AFTER_STATUS" ]]; then
  pass "worktree unchanged by consistency test"
else
  fail "worktree changed unexpectedly"
  echo "BEFORE:$BEFORE_STATUS"
  echo "AFTER:$AFTER_STATUS"
fi

# syntax
bash -n "$DEPLOY_X2B" && pass "bash -n deploy xenial" || fail "bash -n deploy xenial"
python3 -m py_compile "$DEPLOY_PY" && pass "py_compile deploy helper" || fail "py_compile deploy helper"

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL test_deploy_client_atomic_consistency CHECKS PASSED"
  exit 0
fi
echo "SOME test_deploy_client_atomic_consistency CHECKS FAILED"
exit 1
