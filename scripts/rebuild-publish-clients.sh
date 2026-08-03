#!/usr/bin/env bash
# scripts/rebuild-publish-clients.sh — build/sign/publish host-pinned clients
# for THIS Mirror Server using its local signing keypair.
#
# Invoked by install/bootstrap (and Mirror Manager after OS Core is READY).
# Builds all four OS-hop clients against MIRROR_HTTP_URL, signs with the local
# private key, verifies, then atomically replaces /client/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/mirror_host_ip.sh
source "${ROOT}/scripts/lib/mirror_host_ip.sh"
# shellcheck source=lib/client_mirror_gates.sh
source "${ROOT}/scripts/lib/client_mirror_gates.sh"
# shellcheck source=lib/local_client_signing.sh
source "${ROOT}/scripts/lib/local_client_signing.sh"

ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT}/artifacts/client}"
CLIENT_HTTP_ROOT="${CLIENT_HTTP_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/client}"
SELECTIVE_ROOT="${SELECTIVE_ROOT:-${SELECTIVE_MIRROR_ROOT:-${BASE_PATH:-/var/spool/apt-mirror}/selective}}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
SKIP_HTTP_VERIFY="${SKIP_HTTP_VERIFY:-0}"
REQUIRE_SELECTIVE_READY="${REQUIRE_SELECTIVE_READY:-1}"

HOPS=(
  xenial-to-bionic
  bionic-to-focal
  focal-to-jammy
  jammy-to-noble
)

hop_builder_py() {
  printf '%s/scripts/lib/build_client_%s.py\n' "$ROOT" "${1//-/_}"
}

usage() {
  cat <<EOF
Usage: sudo bash ${0##*/} [--hop HOP]... [--skip-build] [--skip-deploy] [--skip-http-verify]

Rebuild and atomically publish host-pinned signed clients for this Mirror.

Hops: ${HOPS[*]}

Environment:
  RESOLVED_MIRROR_HOST_IPV4   override host IPv4
  MIRROR_HTTP_URL             persisted mirror base
  LOCAL_CLIENT_SIGNING_DIR    key directory (default /etc/ubuntu-mirror/client-signing)
  CLIENT_HTTP_ROOT            nginx /client/ destination
  ARTIFACT_DIR                staging build output
EOF
}

selected=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hop) selected+=("${2:?--hop requires a value}"); shift 2 ;;
    --hop=*) selected+=("${1#*=}"); shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-deploy) SKIP_DEPLOY=1; shift ;;
    --skip-http-verify) SKIP_HTTP_VERIFY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "${#selected[@]}" -gt 0 ]] && HOPS=("${selected[@]}")

echo "CENTRAL_PRODUCTION_PRIVATE_KEY_REQUIRED=NO"
echo "LOCAL_MIRROR_KEYPAIR_REQUIRED=YES"
echo "OUT_OF_BAND_FINGERPRINT_REQUIRED=NO"
echo "TARGET_INSTALL_GENERATES_OR_REUSES_LOCAL_PRIVATE_KEY=YES"
echo "TARGET_INSTALL_REBUILDS_CLIENTS=YES"
echo "TARGET_INSTALL_SIGNS_CLIENTS=YES"
echo "PARTIAL_CLIENT_DEPLOY_ALLOWED=NO"

mirror_host_resolve_and_log || {
  echo "REBUILD_PUBLISH_CLIENTS=FAIL mirror host IPv4 could not be resolved" >&2
  exit 1
}
MIRROR_BASE="${RESOLVED_MIRROR_BASE_URL%/}"
echo "RESOLVED_MIRROR_BASE_URL=${MIRROR_BASE}"

local_signing_ensure_keypair || {
  echo "REBUILD_PUBLISH_CLIENTS=FAIL local signing keypair unavailable" >&2
  exit 1
}
local_signing_export_build_env
echo "LOCAL_SIGNING_KEY_PATH=${LOCAL_SIGNING_PRIVATE_KEY}"
echo "LOCAL_PUBLIC_KEY_PATH=${LOCAL_SIGNING_PUBLIC_KEY}"
echo "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"

if [[ "$REQUIRE_SELECTIVE_READY" == "1" ]]; then
  if [[ ! -f "${SELECTIVE_ROOT}/state/READY" ]]; then
    echo "SELECTIVE_READY=MISSING path=${SELECTIVE_ROOT}/state/READY" >&2
    echo "REBUILD_PUBLISH_CLIENTS=FAIL OS Core/selective mirror not ready" >&2
    exit 1
  fi
  if [[ ! -f "${SELECTIVE_ROOT}/keys/ubuntu-mirror-selective.gpg" ]]; then
    echo "SELECTIVE_KEY=MISSING" >&2
    echo "REBUILD_PUBLISH_CLIENTS=FAIL" >&2
    exit 1
  fi
fi

hop_script_name() { printf 'dp-offline-upgrade-%s.sh\n' "$1"; }

# Preserve existing HTTP set until the full new set verifies.
LIVE_BACKUP=""
STAGE_DIR=""
cleanup() {
  [[ -n "${STAGE_DIR:-}" && -d "${STAGE_DIR:-}" ]] && rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [[ "$SKIP_BUILD" == "1" ]]; then
  echo "CLIENT_REBUILD=SKIPPED"
else
  mkdir -p "$ARTIFACT_DIR"
  for hop in "${HOPS[@]}"; do
    builder="$(hop_builder_py "$hop")"
    [[ -f "$builder" ]] || { echo "missing builder ${builder}" >&2; exit 1; }
    echo "CLIENT_REBUILD_START=${hop} mirror_base=${MIRROR_BASE}"
    env \
      CLIENT_SIGNING_PRIVATE_KEY="$LOCAL_SIGNING_PRIVATE_KEY" \
      CLIENT_SIGNING_PUBLIC_KEY="$LOCAL_SIGNING_PUBLIC_KEY" \
      CLIENT_SIGNING_KEY_DIR="$LOCAL_CLIENT_SIGNING_DIR" \
      python3 "$builder" \
        --project-root "$ROOT" \
        --mirror-base "$MIRROR_BASE" \
        --selective-root "$SELECTIVE_ROOT" \
        --output-dir "$ARTIFACT_DIR" \
        --signing-private-key "$LOCAL_SIGNING_PRIVATE_KEY" \
        --signing-public-key "$LOCAL_SIGNING_PUBLIC_KEY" \
      || {
        echo "CLIENT_REBUILD=FAIL hop=${hop}" >&2
        echo "CLIENT_SET_BUILD_COMPLETE=NO" >&2
        exit 1
      }
    echo "CLIENT_REBUILD=PASS hop=${hop}"
  done
  echo "CLIENT_SET_BUILD_COMPLETE=YES"
  echo "INSTALL_BUILDS_LOCAL_CLIENT_SET=YES"
fi

for hop in "${HOPS[@]}"; do
  artifact="${ARTIFACT_DIR}/$(hop_script_name "$hop")"
  [[ -f "$artifact" ]] || { echo "missing artifact ${artifact}" >&2; exit 1; }
  client_assert_mirror_base_match "$artifact" "$MIRROR_BASE" || {
    echo "HOST_PIN_GATE=FAIL hop=${hop}" >&2
    exit 1
  }
done

# Signature verification against the local public key for every hop.
for hop in "${HOPS[@]}"; do
  artifact="${ARTIFACT_DIR}/$(hop_script_name "$hop")"
  if ! python3 - "$ROOT" "$artifact" "$LOCAL_KEY_FINGERPRINT" <<'PY'
import importlib.util, sys
root, artifact, want = sys.argv[1:4]
mod_path = root + "/scripts/lib/build_client_xenial_to_bionic.py"
spec = importlib.util.spec_from_file_location("build_client_x2b", mod_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
info = mod.verify_client_artifact_signature(artifact, allowed_fingerprint=want)
print("LOCAL_SIGNATURE_VERIFY=PASS fingerprint=%s" % info["fingerprint"])
PY
  then
    echo "LOCAL_SIGNATURE_VERIFY=FAIL hop=${hop}" >&2
    echo "CLIENT_SET_SIGN_COMPLETE=NO" >&2
    exit 1
  fi
done
echo "CLIENT_SET_SIGN_COMPLETE=YES"
echo "INSTALL_SIGNS_LOCAL_CLIENT_SET=YES"
echo "LOCAL_MANIFEST_SIGNING=PASS"
echo "LOCAL_PUBLIC_KEY_EXPORT=PASS"
echo "LOCAL_SIGNATURE_VERIFY=PASS"
echo "ALL_FOUR_CLIENTS_BUILT=YES"
echo "ALL_FOUR_CLIENTS_SIGNED=YES"
echo "ALL_FOUR_CLIENTS_SIGNATURE_VALID=YES"

if [[ "$SKIP_DEPLOY" == "1" ]]; then
  echo "CLIENT_DEPLOY=SKIPPED"
  echo "REBUILD_PUBLISH_CLIENTS=PASS"
  exit 0
fi

STAGE_DIR="$(mktemp -d "${CLIENT_HTTP_ROOT}.stage.XXXXXX")"
mkdir -p "$STAGE_DIR"

# Stage full set: clients, sidecars, hop dirs, public key, fingerprint, phase2 helpers.
for hop in "${HOPS[@]}"; do
  name="$(hop_script_name "$hop")"
  install -m 0755 "${ARTIFACT_DIR}/${name}" "${STAGE_DIR}/${name}"
  if [[ -f "${ARTIFACT_DIR}/${name}.sha256" ]]; then
    install -m 0644 "${ARTIFACT_DIR}/${name}.sha256" "${STAGE_DIR}/${name}.sha256"
  else
    ( cd "$STAGE_DIR" && sha256sum "$name" >"${name}.sha256" )
  fi
  if [[ -d "${ARTIFACT_DIR}/${hop}" ]]; then
    mkdir -p "${STAGE_DIR}/${hop}"
    cp -a "${ARTIFACT_DIR}/${hop}/." "${STAGE_DIR}/${hop}/"
  fi
done

# Publish local public key + fingerprint metadata (never the private key).
install -m 0644 "$LOCAL_SIGNING_PUBLIC_KEY" "${STAGE_DIR}/offline-client-manifest.gpg"
install -m 0644 "$LOCAL_SIGNING_PUBLIC_KEY" "${STAGE_DIR}/public.gpg"
printf '%s\n' "$LOCAL_KEY_FINGERPRINT" >"${STAGE_DIR}/signing-key-fingerprint"
chmod 0644 "${STAGE_DIR}/signing-key-fingerprint"
if [[ -f "$LOCAL_SIGNING_FINGERPRINT_FILE" ]]; then
  install -m 0644 "$LOCAL_SIGNING_FINGERPRINT_FILE" "${STAGE_DIR}/fingerprint"
fi

# Phase 2 helpers from source tree (not host-pinned hop clients).
for f in stage-dp-phase2.sh stage-dp-phase2-6.5.0.sh; do
  if [[ -f "${ROOT}/client/${f}" ]]; then
    install -m 0755 "${ROOT}/client/${f}" "${STAGE_DIR}/${f}"
    ( cd "$STAGE_DIR" && sha256sum "$f" >"${f}.sha256" )
  fi
done
if [[ -d "${ROOT}/client/lib" ]]; then
  mkdir -p "${STAGE_DIR}/lib"
  cp -a "${ROOT}/client/lib/." "${STAGE_DIR}/lib/"
fi

local_signing_assert_private_not_published "$STAGE_DIR" || {
  echo "CLIENT_SET_DEPLOY_ATOMIC=NO private key staged for HTTP" >&2
  exit 1
}

# Final verify on staged tree before cutover.
for hop in "${HOPS[@]}"; do
  name="$(hop_script_name "$hop")"
  ( cd "$STAGE_DIR" && sha256sum -c "${name}.sha256" >/dev/null ) || {
    echo "CLIENT_SET_VERIFY_COMPLETE=NO checksum ${name}" >&2
    exit 1
  }
  client_assert_mirror_base_match "${STAGE_DIR}/${name}" "$MIRROR_BASE" || exit 1
done
echo "CLIENT_SET_VERIFY_COMPLETE=YES"

# Atomic directory swap — leave previous set untouched on any prior failure.
if [[ -d "$CLIENT_HTTP_ROOT" ]] && compgen -G "${CLIENT_HTTP_ROOT}/dp-offline-upgrade-*.sh" >/dev/null 2>&1; then
  LIVE_BACKUP="${CLIENT_HTTP_ROOT}.prev.$$"
  mv "$CLIENT_HTTP_ROOT" "$LIVE_BACKUP"
else
  rm -rf "$CLIENT_HTTP_ROOT"
fi
mv "$STAGE_DIR" "$CLIENT_HTTP_ROOT"
STAGE_DIR=""
rm -rf "$LIVE_BACKUP"
LIVE_BACKUP=""

local_signing_assert_private_not_published "$CLIENT_HTTP_ROOT" || exit 1

echo "CLIENT_SET_DEPLOY_ATOMIC=YES"
echo "INSTALL_ATOMICALLY_PUBLISHES_FULL_SET=YES"
echo "INSTALL_PUBLISHES_LOCAL_PUBLIC_KEY=YES"
echo "PRIVATE_KEY_HTTP_PUBLISHED=NO"

if [[ "$SKIP_HTTP_VERIFY" == "1" ]]; then
  echo "CLIENT_PUBLISH_HTTP_VERIFY=SKIPPED"
else
  tmp="$(mktemp -d)"
  for hop in "${HOPS[@]}"; do
    name="$(hop_script_name "$hop")"
    curl -fsS -o "${tmp}/${name}" "${MIRROR_BASE}/client/${name}" || {
      echo "CLIENT_PUBLISH_HTTP_VERIFY=FAIL hop=${hop} fetch" >&2
      rm -rf "$tmp"
      exit 1
    }
    local_sha="$(sha256sum "${ARTIFACT_DIR}/${name}" | awk '{print $1}')"
    http_sha="$(sha256sum "${tmp}/${name}" | awk '{print $1}')"
    [[ "$local_sha" == "$http_sha" ]] || {
      echo "CLIENT_PUBLISH_HTTP_VERIFY=FAIL hop=${hop} sha mismatch" >&2
      rm -rf "$tmp"
      exit 1
    }
    client_assert_mirror_base_match "${tmp}/${name}" "$MIRROR_BASE" >/dev/null || {
      echo "CLIENT_PUBLISH_HTTP_VERIFY=FAIL hop=${hop} pin mismatch" >&2
      rm -rf "$tmp"
      exit 1
    }
    echo "CLIENT_PUBLISH_HTTP_VERIFY=PASS hop=${hop} sha256=${http_sha}"
  done
  curl -fsS -o "${tmp}/public.gpg" "${MIRROR_BASE}/client/public.gpg" \
    || curl -fsS -o "${tmp}/public.gpg" "${MIRROR_BASE}/client/offline-client-manifest.gpg" \
    || { echo "CLIENT_PUBLISH_HTTP_VERIFY=FAIL public key" >&2; rm -rf "$tmp"; exit 1; }
  rm -rf "$tmp"
fi

echo "REBUILD_PUBLISH_CLIENTS=PASS"
