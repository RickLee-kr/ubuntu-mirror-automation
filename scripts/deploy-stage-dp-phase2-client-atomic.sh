#!/usr/bin/env bash
# Atomic publish of Phase 2 client helpers (+ sha256) to /var/spool/apt-mirror/client/
# Deploys both:
#   stage-dp-phase2.sh              (canonical)
#   stage-dp-phase2-6.5.0.sh        (compatibility wrapper)
# Does NOT touch selective READY, OS upgrade client manifests, or nginx reload
# unless HTTP verify requires an already-published /client/ location.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/mirror_host_ip.sh
source "${ROOT}/scripts/lib/mirror_host_ip.sh"
DEST_ROOT="${DEST_ROOT:-/var/spool/apt-mirror/client}"
READY_PATH="${READY_PATH:-/var/spool/apt-mirror/selective/state/READY}"
SKIP_HTTP_VERIFY="${SKIP_HTTP_VERIFY:-0}"
MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL:-${MIRROR_BASE:-}}"
MIRROR_BASE="${MIRROR_BASE%/}"
if [[ -z "$MIRROR_BASE" && "$SKIP_HTTP_VERIFY" != "1" ]]; then
  mirror_host_resolve_and_log || exit 1
  MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL%/}"
fi

HELPERS=(
  stage-dp-phase2.sh
  stage-dp-phase2-6.5.0.sh
)

[[ "$(id -u)" -eq 0 || "${DP_PHASE2_SKIP_ROOT_CHECK:-0}" == "1" ]] || {
  echo "must run as root" >&2
  exit 1
}

deploy_one() {
  local name="$1"
  local src="${ROOT}/client/${name}"
  [[ -f "$src" ]] || { echo "missing ${src}" >&2; exit 1; }
  bash -n "$src" || { echo "bash -n failed: ${name}" >&2; exit 1; }

  # Reject an actual external Stellar Cyber URL, but allow guard code that
  # contains the hostname only to refuse such URLs at runtime.
  if grep -Ev '^[[:space:]]*#' "$src" | grep -Eiq 'https?://[^[:space:]]*stellarcyber\.ai([/:]|$)'; then
    echo "REFUSE: helper contains an external Stellar Cyber URL: ${name}" >&2
    exit 1
  fi
  # Wrapper may only exec; canonical must declare BRINGUP_EXECUTED=NO
  if [[ "$name" == "stage-dp-phase2.sh" ]]; then
    grep -Eq '^[[:space:]]*BRINGUP_EXECUTED[[:space:]]*=[[:space:]]*"?NO"?[[:space:]]*$' "$src" || {
      echo "missing valid BRINGUP_EXECUTED=NO assignment" >&2
      exit 1
    }
    if grep -Eq '^[[:space:]]*BRINGUP_EXECUTED[[:space:]]*=[[:space:]]*"?YES"?[[:space:]]*$' "$src"; then
      echo "REFUSE: BRINGUP_EXECUTED=YES assignment present" >&2
      exit 1
    fi
    grep -Eq '^DEFAULT_MIRROR_URL=""$' "$src" || {
      echo "REFUSE: stage helper must not carry a built-in mirror address" >&2
      exit 1
    }
    if grep -Eq -- 'chown[[:space:]]+aella:aella|install[[:space:]]+-o[[:space:]]+aella|[[:space:]]-g[[:space:]]+aella[[:space:]]+-m' "$src"; then
      echo "REFUSE: literal aella group ownership present" >&2
      exit 1
    fi
    if grep -Eq '^VERSION=|^[[:space:]]*VERSION=' "$src"; then
      echo "REFUSE: ambiguous VERSION= assignment present" >&2
      exit 1
    fi
  fi

  mkdir -p "$DEST_ROOT"
  local sha stamp dest side tmp sidetmp
  sha="$(sha256sum "$src" | awk '{print $1}')"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="${DEST_ROOT}/${name}"
  side="${dest}.sha256"
  tmp="${dest}.tmp.$$"
  sidetmp="${side}.tmp.$$"

  if [[ -f "$dest" ]]; then
    cp -a "$dest" "${dest}.bak-${stamp}"
  fi
  if [[ -f "$side" ]]; then
    cp -a "$side" "${side}.bak-${stamp}"
  fi

  cp -a "$src" "$tmp"
  chmod 0755 "$tmp"
  printf '%s  %s\n' "$sha" "$name" >"$sidetmp"
  chmod 0644 "$sidetmp"

  python3 - "$tmp" "$dest" "$sidetmp" "$side" <<'PY'
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
  echo "ARTIFACT_SHA256=${sha} name=${name}"
}

READY_BEFORE=""
[[ -f "$READY_PATH" ]] && READY_BEFORE="$(sha256sum "$READY_PATH" | awk '{print $1}')"

for h in "${HELPERS[@]}"; do
  deploy_one "$h"
done

READY_AFTER=""
[[ -f "$READY_PATH" ]] && READY_AFTER="$(sha256sum "$READY_PATH" | awk '{print $1}')"
if [[ -n "$READY_BEFORE" && "$READY_BEFORE" != "$READY_AFTER" ]]; then
  echo "READY changed unexpectedly" >&2
  exit 1
fi
echo "READY_UNCHANGED=YES"

if [[ "$SKIP_HTTP_VERIFY" == "1" ]]; then
  echo "HTTP_VERIFY=SKIPPED"
  exit 0
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
for h in "${HELPERS[@]}"; do
  local_sha="$(sha256sum "${DEST_ROOT}/${h}" | awk '{print $1}')"
  curl -fsS -o "${TMPD}/${h}" "${MIRROR_BASE}/client/${h}"
  http_sha="$(sha256sum "${TMPD}/${h}" | awk '{print $1}')"
  [[ "$http_sha" == "$local_sha" ]] || { echo "HTTP SHA mismatch for ${h}" >&2; exit 1; }
  curl -fsS -o "${TMPD}/${h}.sha256" "${MIRROR_BASE}/client/${h}.sha256"
  http_side="$(awk '{print $1}' "${TMPD}/${h}.sha256")"
  [[ "$http_side" == "$local_sha" ]] || { echo "HTTP sidecar mismatch for ${h}" >&2; exit 1; }
  echo "HTTP_VERIFY=PASS name=${h} sha256=${http_sha}"
done
