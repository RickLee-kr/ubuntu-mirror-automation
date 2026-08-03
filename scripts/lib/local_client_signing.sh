#!/usr/bin/env bash
# scripts/lib/local_client_signing.sh — per-mirror-install local signing keypair.
#
# Each Mirror Server install owns its own key pair. There is no central
# production private key and no out-of-band fingerprint trust path.
#
# Layout (overridable via LOCAL_CLIENT_SIGNING_DIR):
#   private.gpg   root:root 0600
#   public.gpg    root:root 0644
#   fingerprint   root:root 0644
#
# shellcheck shell=bash

if [[ -n "${LOCAL_CLIENT_SIGNING_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
LOCAL_CLIENT_SIGNING_LOADED=1

LOCAL_CLIENT_SIGNING_DIR="${LOCAL_CLIENT_SIGNING_DIR:-/etc/ubuntu-mirror/client-signing}"
LOCAL_SIGNING_KEY_ACTION="${LOCAL_SIGNING_KEY_ACTION:-}"
LOCAL_KEY_FINGERPRINT="${LOCAL_KEY_FINGERPRINT:-}"
LOCAL_SIGNING_PRIVATE_KEY="${LOCAL_SIGNING_PRIVATE_KEY:-}"
LOCAL_SIGNING_PUBLIC_KEY="${LOCAL_SIGNING_PUBLIC_KEY:-}"
LOCAL_SIGNING_FINGERPRINT_FILE="${LOCAL_SIGNING_FINGERPRINT_FILE:-}"

local_signing_log() {
  printf '%s\n' "$*"
}

local_signing_err() {
  printf '%s\n' "$*" >&2
}

local_signing_paths() {
  LOCAL_SIGNING_PRIVATE_KEY="${LOCAL_CLIENT_SIGNING_DIR}/private.gpg"
  LOCAL_SIGNING_PUBLIC_KEY="${LOCAL_CLIENT_SIGNING_DIR}/public.gpg"
  LOCAL_SIGNING_FINGERPRINT_FILE="${LOCAL_CLIENT_SIGNING_DIR}/fingerprint"
}

local_signing_fingerprint_of() {
  local key_file="${1:-}" fpr
  [[ -f "$key_file" ]] || return 1
  fpr="$(gpg --batch --with-colons --import-options show-only --import "$key_file" 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  [[ -n "$fpr" ]] || return 1
  printf '%s\n' "${fpr^^}"
}

# Validate an existing pair: both files present, readable, fingerprints match,
# and the on-disk fingerprint file (when present) matches the public key.
local_signing_validate_pair() {
  local priv="${1:-}" pub="${2:-}" fpr_file="${3:-}"
  local priv_fpr pub_fpr stored
  [[ -f "$priv" && -r "$priv" ]] || return 1
  [[ -f "$pub" && -r "$pub" ]] || return 1
  pub_fpr="$(local_signing_fingerprint_of "$pub" || true)"
  [[ -n "$pub_fpr" && ${#pub_fpr} -eq 40 ]] || return 1
  # Private armor/binary must import and expose the same fingerprint.
  priv_fpr="$(gpg --batch --with-colons --import-options show-only --import "$priv" 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  priv_fpr="${priv_fpr^^}"
  [[ -n "$priv_fpr" && "$priv_fpr" == "$pub_fpr" ]] || return 1
  if [[ -f "$fpr_file" ]]; then
    stored="$(tr -d '[:space:]' <"$fpr_file" | tr '[:lower:]' '[:upper:]')"
    [[ "$stored" == "$pub_fpr" ]] || return 1
  fi
  LOCAL_KEY_FINGERPRINT="$pub_fpr"
  return 0
}

local_signing_generate_pair() {
  local dir="${1:-$LOCAL_CLIENT_SIGNING_DIR}"
  local homedir batch priv pub fpr_file fpr
  mkdir -p "$dir"
  chmod 0700 "$dir"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$dir" 2>/dev/null || true
  fi
  priv="${dir}/private.gpg"
  pub="${dir}/public.gpg"
  fpr_file="${dir}/fingerprint"
  homedir="$(mktemp -d "${TMPDIR:-/tmp}/local-client-sign-XXXXXX")"
  chmod 700 "$homedir"
  batch="${homedir}/batch"
  cat >"$batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Ubuntu Mirror Local Client Manifest
Name-Email: local-client-manifest@ubuntu-mirror
Expire-Date: 0
%no-protection
%commit
EOF
  gpg --homedir "$homedir" --batch --gen-key "$batch" >/dev/null 2>&1 \
    || { rm -rf "$homedir"; return 1; }
  gpg --homedir "$homedir" --batch --export-secret-keys --armor >"$priv" 2>/dev/null \
    || { rm -rf "$homedir"; rm -f "$priv"; return 1; }
  gpg --homedir "$homedir" --batch --export --armor >"$pub" 2>/dev/null \
    || { rm -rf "$homedir"; rm -f "$priv" "$pub"; return 1; }
  rm -rf "$homedir"
  chmod 0600 "$priv"
  chmod 0644 "$pub"
  fpr="$(local_signing_fingerprint_of "$pub" || true)"
  [[ -n "$fpr" ]] || { rm -f "$priv" "$pub"; return 1; }
  printf '%s\n' "$fpr" >"$fpr_file"
  chmod 0644 "$fpr_file"
  if [[ "${EUID}" -eq 0 ]]; then
    chown root:root "$priv" "$pub" "$fpr_file" 2>/dev/null || true
  fi
  LOCAL_KEY_FINGERPRINT="$fpr"
  LOCAL_SIGNING_PRIVATE_KEY="$priv"
  LOCAL_SIGNING_PUBLIC_KEY="$pub"
  LOCAL_SIGNING_FINGERPRINT_FILE="$fpr_file"
  return 0
}

# Ensure a usable local keypair. Never rotates automatically.
# Sets LOCAL_SIGNING_KEY_ACTION to GENERATED | REUSED | FAIL.
local_signing_ensure_keypair() {
  local_signing_paths
  LOCAL_SIGNING_KEY_ACTION=""
  LOCAL_KEY_FINGERPRINT=""

  local have_priv=0 have_pub=0
  [[ -e "$LOCAL_SIGNING_PRIVATE_KEY" ]] && have_priv=1
  [[ -e "$LOCAL_SIGNING_PUBLIC_KEY" ]] && have_pub=1

  if [[ "$have_priv" -eq 0 && "$have_pub" -eq 0 ]]; then
    if local_signing_generate_pair "$LOCAL_CLIENT_SIGNING_DIR"; then
      LOCAL_SIGNING_KEY_ACTION=GENERATED
      local_signing_log "LOCAL_SIGNING_KEY_ACTION=GENERATED"
      local_signing_log "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"
      return 0
    fi
    LOCAL_SIGNING_KEY_ACTION=FAIL
    local_signing_err "LOCAL_SIGNING_KEY_ACTION=FAIL generation failed"
    return 1
  fi

  if local_signing_validate_pair \
    "$LOCAL_SIGNING_PRIVATE_KEY" \
    "$LOCAL_SIGNING_PUBLIC_KEY" \
    "$LOCAL_SIGNING_FINGERPRINT_FILE"
  then
    # Refresh fingerprint file if missing but pair is valid.
    if [[ ! -f "$LOCAL_SIGNING_FINGERPRINT_FILE" ]]; then
      printf '%s\n' "$LOCAL_KEY_FINGERPRINT" >"$LOCAL_SIGNING_FINGERPRINT_FILE"
      chmod 0644 "$LOCAL_SIGNING_FINGERPRINT_FILE"
    fi
    LOCAL_SIGNING_KEY_ACTION=REUSED
    local_signing_log "LOCAL_SIGNING_KEY_ACTION=REUSED"
    local_signing_log "LOCAL_KEY_FINGERPRINT=${LOCAL_KEY_FINGERPRINT}"
    return 0
  fi

  LOCAL_SIGNING_KEY_ACTION=FAIL
  local_signing_err "LOCAL_SIGNING_KEY_ACTION=FAIL incomplete or mismatched key pair"
  local_signing_err "INSTALL_RESULT=FAIL"
  return 1
}

# Export env vars consumed by the Python builders.
local_signing_export_build_env() {
  local_signing_paths
  export CLIENT_SIGNING_PRIVATE_KEY="$LOCAL_SIGNING_PRIVATE_KEY"
  export CLIENT_SIGNING_PUBLIC_KEY="$LOCAL_SIGNING_PUBLIC_KEY"
  export CLIENT_SIGNING_KEY_DIR="$LOCAL_CLIENT_SIGNING_DIR"
  if [[ -n "${LOCAL_KEY_FINGERPRINT:-}" ]]; then
    export CLIENT_SIGNING_FINGERPRINT="$LOCAL_KEY_FINGERPRINT"
  fi
}

# Refuse publishing private key material into an HTTP document root.
local_signing_assert_private_not_published() {
  local http_root="${1:-}"
  [[ -n "$http_root" && -d "$http_root" ]] || return 0
  if find "$http_root" -type f \( -name 'private.gpg' -o -name '*private*.gpg' -o -name '*.private.gpg' \) 2>/dev/null | grep -q .; then
    local_signing_err "PRIVATE_KEY_HTTP_PUBLISHED=YES"
    return 1
  fi
  local_signing_log "PRIVATE_KEY_HTTP_PUBLISHED=NO"
  return 0
}
