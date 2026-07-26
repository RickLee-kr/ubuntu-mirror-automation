#!/usr/bin/env bash
# Atomic publish of client/stage-dp-phase2-6.5.0.sh (+ sha256) to /var/spool/apt-mirror/client/
# Does NOT touch selective READY, OS upgrade client manifests, or nginx reload.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/client/stage-dp-phase2-6.5.0.sh"
NAME="stage-dp-phase2-6.5.0.sh"
DEST_ROOT="${DEST_ROOT:-/var/spool/apt-mirror/client}"
READY_PATH="${READY_PATH:-/var/spool/apt-mirror/selective/state/READY}"
MIRROR_BASE="${MIRROR_BASE:-http://221.139.249.111}"
SKIP_HTTP_VERIFY="${SKIP_HTTP_VERIFY:-0}"

[[ -f "$SRC" ]] || { echo "missing ${SRC}" >&2; exit 1; }
[[ "$(id -u)" -eq 0 || "${DP_PHASE2_SKIP_ROOT_CHECK:-0}" == "1" ]] || {
  echo "must run as root" >&2
  exit 1
}

bash -n "$SRC" || { echo "bash -n failed" >&2; exit 1; }

# Refuse ACPS host and ensure bringup is never auto-executed
# Reject an actual external Stellar Cyber URL, but allow guard code that
# contains the hostname only to refuse such URLs at runtime.
if grep -Ev '^[[:space:]]*#' "$SRC" |    grep -Eiq 'https?://[^[:space:]]*stellarcyber\.ai([/:]|$)'; then
  echo "REFUSE: helper contains an external Stellar Cyber URL" >&2
  exit 1
fi
grep -q 'BRINGUP_EXECUTED=NO' "$SRC" || { echo "missing BRINGUP_EXECUTED=NO" >&2; exit 1; }
grep -Eq 'BRINGUP_EXECUTED=YES' "$SRC" && { echo "REFUSE: BRINGUP_EXECUTED=YES present" >&2; exit 1; }
grep -q '221.139.249.111' "$SRC" || { echo "missing default mirror IP" >&2; exit 1; }

mkdir -p "$DEST_ROOT"
SHA="$(sha256sum "$SRC" | awk '{print $1}')"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${DEST_ROOT}/${NAME}"
SIDE="${DEST}.sha256"
TMP="${DEST}.tmp.$$"
SIDETMP="${SIDE}.tmp.$$"

READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"

if [[ -f "$DEST" ]]; then
  cp -a "$DEST" "${DEST}.bak-${STAMP}"
fi
if [[ -f "$SIDE" ]]; then
  cp -a "$SIDE" "${SIDE}.bak-${STAMP}"
fi

cp -a "$SRC" "$TMP"
chmod 0755 "$TMP"
printf '%s  %s\n' "$SHA" "$NAME" >"$SIDETMP"
chmod 0644 "$SIDETMP"

# fsync + atomic replace
python3 - "$TMP" "$DEST" "$SIDETMP" "$SIDE" <<'PY'
import os, sys
tmp, dest, sidetmp, side = sys.argv[1:5]
for path in (tmp, sidetmp):
    with open(path, "rb") as fh:
        os.fsync(fh.fileno())
os.replace(tmp, dest)
os.replace(sidetmp, side)
parent = os.path.dirname(dest) or "."
dirfd = os.open(parent, os.O_RDONLY)
try:
    os.fsync(dirfd)
finally:
    os.close(dirfd)
print("ATOMIC_DEPLOY=PASS")
print("DEST=" + dest)
print("SIDECAR=" + side)
PY

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ -n "$READY_BEFORE" && "$READY_BEFORE" != "$READY_AFTER" ]]; then
  echo "READY changed unexpectedly" >&2
  exit 1
fi
echo "READY_UNCHANGED=YES"
echo "ARTIFACT_SHA256=${SHA}"

if [[ "$SKIP_HTTP_VERIFY" == "1" ]]; then
  echo "HTTP_VERIFY=SKIPPED"
  exit 0
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
curl -fsS -o "${TMPD}/${NAME}" "${MIRROR_BASE}/client/${NAME}"
HTTP_SHA="$(sha256sum "${TMPD}/${NAME}" | awk '{print $1}')"
[[ "$HTTP_SHA" == "$SHA" ]] || { echo "HTTP SHA mismatch" >&2; exit 1; }
curl -fsS -o "${TMPD}/${NAME}.sha256" "${MIRROR_BASE}/client/${NAME}.sha256"
HTTP_SIDE="$(awk '{print $1}' "${TMPD}/${NAME}.sha256")"
[[ "$HTTP_SIDE" == "$SHA" ]] || { echo "HTTP sidecar mismatch" >&2; exit 1; }
echo "HTTP_VERIFY=PASS"
echo "HTTP_SHA256=${HTTP_SHA}"
