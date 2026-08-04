#!/usr/bin/env bash
# scripts/lib/mirror_workflow_state.sh — generation-bound Mirror workflow state
# shellcheck shell=bash
#
# Authoritative workflow phases (monotonic; invalidation demotes):
#   UNCONFIGURED → CONFIGURED → PREPARED → CLIENT_SET_PUBLISHED
#   → HTTP_ENABLED → READINESS_VERIFIED → COMMANDS_GENERATED
#
# Success is never inferred from stale files, boolean flags alone, or past PASS
# strings. Generations must match across config → client set → HTTP → readiness
# → commands.

if [[ -n "${MIRROR_WORKFLOW_STATE_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
MIRROR_WORKFLOW_STATE_LOADED=1

MM_WORKFLOW_FILE="${MM_WORKFLOW_FILE:-${MM_CONFIG_DIR:-/etc/ubuntu-mirror}/dp-upgrade-workflow.state}"

# ---------------------------------------------------------------------------
# Low-level atomic KV store
# ---------------------------------------------------------------------------
mm_wf_file() {
  printf '%s\n' "${MM_WORKFLOW_FILE}"
}

mm_wf_new_generation_id() {
  printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "${RANDOM}$$"
}

mm_wf_atomic_write_file() {
  local dest="$1"
  local src="$2"
  local dir mode old_umask tmp
  dir="$(dirname "$dest")"
  mkdir -p "$dir"
  mode="$(stat -c '%a' "$dest" 2>/dev/null || printf '600')"
  tmp="$(mktemp "${dir}/.wf.XXXXXX")"
  old_umask="$(umask)"
  umask 077
  cat "$src" >"$tmp"
  umask "$old_umask"
  chmod "$mode" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest"
  chmod "$mode" "$dest" 2>/dev/null || chmod 600 "$dest" 2>/dev/null || true
}

mm_wf_ensure_file() {
  local f
  f="$(mm_wf_file)"
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    umask 077
    if ! cat >"$f" <<EOF
WORKFLOW_STATE=UNCONFIGURED
WORKFLOW_GENERATION_ID=
CONFIG_SHA256=
PREPARATION_MODE=
MIRROR_SERVER_IP=
MIRROR_HTTP_URL=
PHASE2_TARGET_VERSION=6.5.0
OS_CORE_GENERATION_ID=
PHASE2_GENERATION_ID=
CLIENT_SET_GENERATION_ID=
CLIENT_SIGNING_FINGERPRINT=
HTTP_PUBLICATION_GENERATION_ID=
READINESS_VERIFIED_GENERATION_ID=
COMMAND_FILE_GENERATION_ID=
CREATED_UTC=
VERIFIED_UTC=
HTTP_REENABLE_REQUIRED=
EOF
    then
      return 1
    fi
    chmod 600 "$f" 2>/dev/null || true
  fi
}

mm_wf_get() {
  local key="$1"
  local f
  f="$(mm_wf_file)"
  [[ -f "$f" ]] || { printf ''; return 0; }
  awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' "$f"
}

mm_wf_set_many() {
  # Usage: mm_wf_set_many KEY=VAL KEY=VAL ...
  # Atomic multi-key update of the workflow state file.
  local f tmp line key val k2
  local -A updates=()
  local -A cur=()
  mm_wf_ensure_file
  f="$(mm_wf_file)"
  for line in "$@"; do
    key="${line%%=*}"
    val="${line#*=}"
    [[ -n "$key" ]] || continue
    updates["$key"]="$val"
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    cur["${line%%=*}"]="${line#*=}"
  done <"$f"
  for k2 in "${!updates[@]}"; do
    cur["$k2"]="${updates[$k2]}"
  done
  tmp="$(mktemp "$(dirname "$f")/.wfset.XXXXXX")"
  {
    for k2 in \
      WORKFLOW_STATE WORKFLOW_GENERATION_ID CONFIG_SHA256 PREPARATION_MODE \
      MIRROR_SERVER_IP MIRROR_HTTP_URL PHASE2_TARGET_VERSION \
      OS_CORE_GENERATION_ID PHASE2_GENERATION_ID CLIENT_SET_GENERATION_ID \
      CLIENT_SIGNING_FINGERPRINT HTTP_PUBLICATION_GENERATION_ID \
      READINESS_VERIFIED_GENERATION_ID COMMAND_FILE_GENERATION_ID \
      CREATED_UTC VERIFIED_UTC HTTP_REENABLE_REQUIRED
    do
      if [[ -n "${cur[$k2]+x}" ]]; then
        printf '%s=%s\n' "$k2" "${cur[$k2]}"
        unset "cur[$k2]"
      fi
    done
    for k2 in "${!cur[@]}"; do
      printf '%s=%s\n' "$k2" "${cur[$k2]}"
    done
  } >"$tmp"
  mm_wf_atomic_write_file "$f" "$tmp"
  rm -f "$tmp"
}

mm_wf_set() {
  local key="$1" val="$2"
  mm_wf_set_many "${key}=${val}"
}

# ---------------------------------------------------------------------------
# Config identity
# ---------------------------------------------------------------------------
mm_wf_config_sha256() {
  local f="${MM_CONFIG_FILE:-/etc/ubuntu-mirror/dp-upgrade-mirror.conf}"
  if [[ ! -f "$f" ]]; then
    printf ''
    return 1
  fi
  # Content digest of operator-relevant keys only (stable across rewrite order).
  # shellcheck disable=SC1090
  (
    set -a
    # shellcheck source=/dev/null
    source "$f"
    set +a
    printf 'PREPARATION_MODE=%s\n' "${PREPARATION_MODE:-}"
    printf 'MIRROR_SERVER_IP=%s\n' "${MIRROR_SERVER_IP:-}"
    printf 'MIRROR_HTTP_URL=%s\n' "${MIRROR_HTTP_URL:-}"
    printf 'ACPS_USERNAME=%s\n' "${ACPS_USERNAME:-}"
    # Password contributes to identity without logging it.
    if [[ -n "${ACPS_PASSWORD:-}" ]]; then
      printf 'ACPS_PASSWORD_SHA256=%s\n' \
        "$(printf '%s' "${ACPS_PASSWORD}" | sha256sum | awk '{print $1}')"
    else
      printf 'ACPS_PASSWORD_SHA256=\n'
    fi
  ) | sha256sum | awk '{print $1}'
}

mm_wf_state() {
  local s
  s="$(mm_wf_get WORKFLOW_STATE)"
  printf '%s\n' "${s:-UNCONFIGURED}"
}

# ---------------------------------------------------------------------------
# Phase transitions + invalidation
# ---------------------------------------------------------------------------
mm_wf_mark_configured() {
  local gen sha mode ip url
  mm_wf_ensure_file
  gen="$(mm_wf_new_generation_id)"
  sha="$(mm_wf_config_sha256 || true)"
  mode="${PREPARATION_MODE:-FULL}"
  ip="${MIRROR_SERVER_IP:-}"
  url="${MIRROR_HTTP_URL:-}"
  mm_wf_set_many \
    "WORKFLOW_STATE=CONFIGURED" \
    "WORKFLOW_GENERATION_ID=${gen}" \
    "CONFIG_SHA256=${sha}" \
    "PREPARATION_MODE=${mode}" \
    "MIRROR_SERVER_IP=${ip}" \
    "MIRROR_HTTP_URL=${url}" \
    "PHASE2_TARGET_VERSION=${PHASE2_TARGET_VERSION:-6.5.0}" \
    "OS_CORE_GENERATION_ID=" \
    "PHASE2_GENERATION_ID=" \
    "CLIENT_SET_GENERATION_ID=" \
    "CLIENT_SIGNING_FINGERPRINT=" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "VERIFIED_UTC=" \
    "HTTP_REENABLE_REQUIRED="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE CONFIGURED
    mm_status_set WORKFLOW_GENERATION_ID "$gen"
    mm_status_set CONFIG_SHA256 "$sha"
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT ""
    mm_status_set CLIENT_COMMANDS_MODE ""
  fi
  mm_info "WORKFLOW_STATE=CONFIGURED WORKFLOW_GENERATION_ID=${gen} CONFIG_SHA256=${sha}"
}

# Config change invalidates everything after CONFIGURED.
mm_wf_invalidate_after_config_change() {
  local prev_sha new_sha prev_ip prev_mode prev_fpr
  mm_wf_ensure_file
  prev_sha="$(mm_wf_get CONFIG_SHA256)"
  prev_ip="$(mm_wf_get MIRROR_SERVER_IP)"
  prev_mode="$(mm_wf_get PREPARATION_MODE)"
  prev_fpr="$(mm_wf_get CLIENT_SIGNING_FINGERPRINT)"
  new_sha="$(mm_wf_config_sha256 || true)"
  if [[ -n "$prev_sha" && "$prev_sha" == "$new_sha" ]]; then
    # Still refresh IP/mode mirrors; no demotion if identity unchanged.
    mm_wf_set_many \
      "PREPARATION_MODE=${PREPARATION_MODE:-FULL}" \
      "MIRROR_SERVER_IP=${MIRROR_SERVER_IP:-}" \
      "MIRROR_HTTP_URL=${MIRROR_HTTP_URL:-}"
    return 0
  fi
  mm_wf_mark_configured
  if [[ -n "$prev_mode" && "$prev_mode" != "${PREPARATION_MODE:-}" ]]; then
    mm_info "WORKFLOW_STALE reason=preparation_mode_changed old=${prev_mode} new=${PREPARATION_MODE:-}"
  fi
  if [[ -n "$prev_ip" && "$prev_ip" != "${MIRROR_SERVER_IP:-}" ]]; then
    mm_info "WORKFLOW_STALE reason=mirror_server_ip_changed"
  fi
  if [[ -n "$prev_fpr" ]]; then
    mm_info "WORKFLOW_STALE reason=config_identity_changed clearing_client_http_readiness_commands"
  fi
}

mm_wf_mark_prepared() {
  local gen os_gen p2_gen
  gen="$(mm_wf_get WORKFLOW_GENERATION_ID)"
  [[ -n "$gen" ]] || gen="$(mm_wf_new_generation_id)"
  os_gen="${1:-$(mm_wf_new_generation_id)}"
  p2_gen="${2:-$(mm_wf_new_generation_id)}"
  mm_wf_set_many \
    "WORKFLOW_STATE=PREPARED" \
    "WORKFLOW_GENERATION_ID=${gen}" \
    "CONFIG_SHA256=$(mm_wf_config_sha256 || true)" \
    "PREPARATION_MODE=${PREPARATION_MODE:-FULL}" \
    "MIRROR_SERVER_IP=${MIRROR_SERVER_IP:-}" \
    "MIRROR_HTTP_URL=${MIRROR_HTTP_URL:-}" \
    "OS_CORE_GENERATION_ID=${os_gen}" \
    "PHASE2_GENERATION_ID=${p2_gen}" \
    "CLIENT_SET_GENERATION_ID=" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE PREPARED
    mm_status_set OS_CORE_GENERATION_ID "$os_gen"
    mm_status_set PHASE2_GENERATION_ID "$p2_gen"
    mm_status_set UPGRADE_READINESS FAIL
  fi
  mm_info "WORKFLOW_STATE=PREPARED OS_CORE_GENERATION_ID=${os_gen} PHASE2_GENERATION_ID=${p2_gen}"
}

mm_wf_mark_client_set_published() {
  local client_gen fpr
  client_gen="${1:-$(mm_wf_new_generation_id)}"
  fpr="${2:-}"
  mm_wf_set_many \
    "WORKFLOW_STATE=CLIENT_SET_PUBLISHED" \
    "CLIENT_SET_GENERATION_ID=${client_gen}" \
    "CLIENT_SIGNING_FINGERPRINT=${fpr}" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE CLIENT_SET_PUBLISHED
    mm_status_set CLIENT_SET_GENERATION_ID "$client_gen"
    mm_status_set CLIENT_SIGNING_FINGERPRINT "$fpr"
    mm_status_set UPGRADE_READINESS FAIL
  fi
  mm_info "WORKFLOW_STATE=CLIENT_SET_PUBLISHED CLIENT_SET_GENERATION_ID=${client_gen}"
}

mm_wf_mark_http_enabled() {
  local pub_gen client_gen
  client_gen="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  pub_gen="${1:-${client_gen}}"
  [[ -n "$pub_gen" ]] || pub_gen="$(mm_wf_new_generation_id)"
  mm_wf_set_many \
    "WORKFLOW_STATE=HTTP_ENABLED" \
    "HTTP_PUBLICATION_GENERATION_ID=${pub_gen}" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "HTTP_REENABLE_REQUIRED=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE HTTP_ENABLED
    mm_status_set HTTP_PUBLICATION_GENERATION_ID "$pub_gen"
    mm_status_set HTTP_DISTRIBUTION ENABLED
    mm_status_set UPGRADE_READINESS FAIL
  fi
  mm_info "WORKFLOW_STATE=HTTP_ENABLED HTTP_PUBLICATION_GENERATION_ID=${pub_gen}"
}

mm_wf_mark_http_disabled() {
  local reason="${1:-}"
  mm_wf_set_many \
    "WORKFLOW_STATE=CLIENT_SET_PUBLISHED" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "HTTP_REENABLE_REQUIRED=YES" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set HTTP_DISTRIBUTION DISABLED
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set HTTP_REENABLE_REQUIRED YES
  fi
  mm_warn "WORKFLOW_HTTP_DISABLED reason=${reason:-unspecified} HTTP_REENABLE_REQUIRED=YES"
}

mm_wf_mark_readiness_verified() {
  local pub_gen
  pub_gen="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)"
  [[ -n "$pub_gen" ]] || pub_gen="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  [[ -n "$pub_gen" ]] || return 1
  mm_wf_set_many \
    "WORKFLOW_STATE=READINESS_VERIFIED" \
    "READINESS_VERIFIED_GENERATION_ID=${pub_gen}" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE READINESS_VERIFIED
    mm_status_set READINESS_VERIFIED_GENERATION_ID "$pub_gen"
    mm_status_set UPGRADE_READINESS PASS
    mm_status_set READINESS_RESULT PASS
  fi
  mm_ok "UPGRADE_READINESS=PASS READINESS_VERIFIED_GENERATION_ID=${pub_gen}"
}

mm_wf_mark_commands_generated() {
  local ready_gen cmd_gen
  ready_gen="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  cmd_gen="${1:-${ready_gen}}"
  [[ -n "$cmd_gen" ]] || return 1
  mm_wf_set_many \
    "WORKFLOW_STATE=COMMANDS_GENERATED" \
    "COMMAND_FILE_GENERATION_ID=${cmd_gen}"
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set WORKFLOW_STATE COMMANDS_GENERATED
    mm_status_set COMMAND_FILE_GENERATION_ID "$cmd_gen"
    mm_status_set CLIENT_COMMANDS_MODE "${PREPARATION_MODE:-FULL}"
    mm_status_set CLIENT_COMMANDS_GENERATED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  mm_info "WORKFLOW_STATE=COMMANDS_GENERATED COMMAND_FILE_GENERATION_ID=${cmd_gen}"
}

# Invalidate HTTP/readiness/commands after client republish or signing change.
mm_wf_invalidate_after_client_republish() {
  mm_wf_set_many \
    "WORKFLOW_STATE=CLIENT_SET_PUBLISHED" \
    "HTTP_PUBLICATION_GENERATION_ID=" \
    "READINESS_VERIFIED_GENERATION_ID=" \
    "COMMAND_FILE_GENERATION_ID=" \
    "VERIFIED_UTC="
  if declare -F mm_status_set >/dev/null 2>&1; then
    mm_status_set UPGRADE_READINESS FAIL
    mm_status_set READINESS_RESULT ""
  fi
}

# ---------------------------------------------------------------------------
# Consistency checks (generation binding)
# ---------------------------------------------------------------------------
mm_wf_config_matches_current() {
  local stored current
  stored="$(mm_wf_get CONFIG_SHA256)"
  current="$(mm_wf_config_sha256 || true)"
  [[ -n "$stored" && -n "$current" && "$stored" == "$current" ]]
}

mm_wf_readiness_generation_current() {
  local ready pub client
  ready="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  pub="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)"
  client="$(mm_wf_get CLIENT_SET_GENERATION_ID)"
  [[ -n "$ready" ]] || return 1
  [[ "$ready" == "$pub" || "$ready" == "$client" ]] || return 1
  [[ "$(mm_wf_get WORKFLOW_STATE)" == "READINESS_VERIFIED" \
    || "$(mm_wf_get WORKFLOW_STATE)" == "COMMANDS_GENERATED" ]] || return 1
  if declare -F mm_status_get >/dev/null 2>&1; then
    [[ "$(mm_status_get UPGRADE_READINESS)" == "PASS" ]] || return 1
  fi
  mm_wf_config_matches_current || return 1
  return 0
}

# Lightweight Menu 7 preflight. Sets MM_WF_BLOCK_REASON / MM_WF_REQUIRED_ACTION.
# shellcheck disable=SC2034 # exported for Menu 7 GUI consumption
mm_wf_commands_preflight() {
  MM_WF_BLOCK_REASON=""
  MM_WF_REQUIRED_ACTION=""
  export MM_WF_BLOCK_REASON MM_WF_REQUIRED_ACTION
  local mode ip state ready pub

  if declare -F mm_normalize_preparation_mode >/dev/null 2>&1; then
    mm_normalize_preparation_mode
  fi
  mode="${PREPARATION_MODE:-}"
  case "$mode" in
    FULL|PHASE2_ONLY) ;;
    *)
      MM_WF_BLOCK_REASON="PREPARATION_MODE_INVALID"
      MM_WF_REQUIRED_ACTION="Configuration"
      return 1
      ;;
  esac

  ip="${MIRROR_SERVER_IP:-}"
  if [[ -z "$ip" ]]; then
    MM_WF_BLOCK_REASON="MIRROR_SERVER_IP_NOT_OPERATOR_CONFIRMED"
    MM_WF_REQUIRED_ACTION="Configuration"
    return 1
  fi

  if ! mm_wf_config_matches_current; then
    MM_WF_BLOCK_REASON="STALE_CONFIG_SHA256"
    MM_WF_REQUIRED_ACTION="Verify Upgrade Readiness"
    return 1
  fi

  state="$(mm_wf_state)"
  if [[ "$(mm_status_get HTTP_DISTRIBUTION 2>/dev/null || true)" != "ENABLED" ]] \
    && [[ "$state" != "HTTP_ENABLED" && "$state" != "READINESS_VERIFIED" && "$state" != "COMMANDS_GENERATED" ]]; then
    MM_WF_BLOCK_REASON="HTTP_NOT_ENABLED"
    MM_WF_REQUIRED_ACTION="Enable HTTP Distribution"
    return 1
  fi

  if [[ "$(mm_status_get UPGRADE_READINESS 2>/dev/null || true)" != "PASS" ]]; then
    MM_WF_BLOCK_REASON="UPGRADE_READINESS_NOT_PASS"
    MM_WF_REQUIRED_ACTION="Verify Upgrade Readiness"
    return 1
  fi

  ready="$(mm_wf_get READINESS_VERIFIED_GENERATION_ID)"
  pub="$(mm_wf_get HTTP_PUBLICATION_GENERATION_ID)"
  if [[ -z "$ready" || -z "$pub" || "$ready" != "$pub" ]]; then
    MM_WF_BLOCK_REASON="READINESS_GENERATION_MISMATCH"
    MM_WF_REQUIRED_ACTION="Verify Upgrade Readiness"
    return 1
  fi

  if [[ -z "$(mm_wf_get CLIENT_SET_GENERATION_ID)" ]]; then
    MM_WF_BLOCK_REASON="CLIENT_SET_GENERATION_MISSING"
    MM_WF_REQUIRED_ACTION="Download and Prepare"
    return 1
  fi

  if [[ -z "$(mm_wf_get CLIENT_SIGNING_FINGERPRINT)" ]]; then
    MM_WF_BLOCK_REASON="CLIENT_SIGNING_FINGERPRINT_MISSING"
    MM_WF_REQUIRED_ACTION="Download and Prepare"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Command file validation + atomic publish
# ---------------------------------------------------------------------------
# Reconstruct a controlled backslash-continued command block for inspection
# (does not execute). Removes only: trailing \ + newline + continuation indent.
mm_wf_reconstruct_command_block() {
  local block="$1"
  printf '%s\n' "$block" | sed -E 's/\\[[:space:]]*$//' | sed -E 's/^[[:space:]]+//' | tr -d '\n'
  printf '\n'
}

# Validate one OS-hop three-line block starting at file line number.
# Prints evidence; returns 0 on PASS.
mm_wf_validate_os_hop_block_at() {
  local file="$1" start_line="$2"
  local max_len="${3:-240}"
  local l1 l2 l3 l4 recon

  l1="$(sed -n "${start_line}p" "$file")"
  l2="$(sed -n "$((start_line + 1))p" "$file")"
  l3="$(sed -n "$((start_line + 2))p" "$file")"
  l4="$(sed -n "$((start_line + 3))p" "$file" || true)"

  [[ -n "$l1" && -n "$l2" && -n "$l3" ]] || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_INCOMPLETE=YES\n'
    return 1
  }
  # Subshell-scoped bootstrap: "( cd /home/aella && ..." (caller cwd/trap preserved).
  [[ "$l1" == \(\ cd\ /home/aella\ \&\&* || "$l1" == cd\ /home/aella\ \&\&* ]] || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_PREFIX=FAIL\n'
    return 1
  }
  [[ "$l1" =~ \\[[:space:]]*$ ]] || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_LINE1_BACKSLASH=FAIL\n'
    return 1
  }
  [[ "$l2" =~ \\[[:space:]]*$ ]] || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_LINE2_BACKSLASH=FAIL\n'
    return 1
  }
  if [[ "$l3" =~ \\[[:space:]]*$ ]]; then
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_FINAL_BACKSLASH=YES\n'
    return 1
  fi
  # No blank line inside the block.
  if [[ -z "${l1// /}" || -z "${l2// /}" || -z "${l3// /}" ]]; then
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_BLANK=YES\n'
    return 1
  fi
  # No fourth continuation line (another trailing-\ line immediately after).
  if [[ -n "$l4" && "$l4" =~ \\[[:space:]]*$ ]]; then
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_EXTRA_CONTINUATION=YES\n'
    return 1
  fi
  if [[ ${#l1} -gt "$max_len" || ${#l2} -gt "$max_len" || ${#l3} -gt "$max_len" ]]; then
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_PHYSICAL_LINE_TOO_LONG=YES\n'
    return 1
  fi

  recon="$(mm_wf_reconstruct_command_block "$(printf '%s\n%s\n%s\n' "$l1" "$l2" "$l3")")"
  [[ -n "${recon// /}" ]] || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_HOP_BLOCK_EMPTY=YES\n'
    return 1
  }
  printf '%s\n' "$recon" | grep -q "EXPECTED_FPR=" || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_FINGERPRINT_PIN=MISSING\n'
    return 1
  }
  printf '%s\n' "$recon" | grep -q "gpgv --keyring" || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_GPGV=MISSING\n'
    return 1
  }
  printf '%s\n' "$recon" | grep -qE 'bash \$R |bash \./\$R |dp-client-command-runner\.sh' || {
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_RUNNER_INVOKE=MISSING\n'
    return 1
  }
  # Reject a second command glued after the runner invocation.
  if printf '%s\n' "$recon" | grep -qE 'bash \$R .*(&&|;[[:space:]])'; then
    printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
    printf 'COMMAND_FILE_TRAILING_COMMAND=YES\n'
    return 1
  fi
  return 0
}

mm_wf_validate_command_file_content() {
  # Args: file mode(FULL|PHASE2_ONLY)
  # Prints COMMAND_FILE_* evidence lines; returns 0 only when structure is valid.
  local file="$1" mode="$2"
  local lines exec_count hop_count stage_count bringup_count
  local xenial bionic focal jammy
  local max_phys=240 max_block_lines=0 block_count=0 hop_block_count=0
  local lineno line cont_ok=1
  local -a hop_starts=()

  if [[ ! -f "$file" || ! -s "$file" ]]; then
    printf 'COMMAND_FILE_BUILD=FAIL\n'
    printf 'COMMAND_FILE_EMPTY=YES\n'
    return 1
  fi

  lines="$(wc -l <"$file" | tr -d ' ')"
  # Count executable command blocks (start lines), not continuation lines.
  # Subshell form: "( cd /home/aella && ..." (Menu 7 bootstrap lifecycle fix).
  exec_count="$(grep -cE '^\( cd /home/aella && |^cd /home/aella && ' "$file" || true)"
  hop_count="$(grep -cE "^\( cd /home/aella && .*HOP='(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)'|^cd /home/aella && .*HOP='(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)'" "$file" || true)"
  stage_count="$(grep -cE "^\( cd /home/aella && .*SCRIPT='stage-dp-phase2\.sh'|^cd /home/aella && .*SCRIPT='stage-dp-phase2\.sh'" "$file" || true)"
  bringup_count="$(grep -cE 'bringup_py3_dp_after_os_upgrade\.sh' "$file" || true)"
  xenial="$(grep -cE "^\( cd /home/aella && .*HOP='xenial-to-bionic'|^cd /home/aella && .*HOP='xenial-to-bionic'" "$file" || true)"
  bionic="$(grep -cE "^\( cd /home/aella && .*HOP='bionic-to-focal'|^cd /home/aella && .*HOP='bionic-to-focal'" "$file" || true)"
  focal="$(grep -cE "^\( cd /home/aella && .*HOP='focal-to-jammy'|^cd /home/aella && .*HOP='focal-to-jammy'" "$file" || true)"
  jammy="$(grep -cE "^\( cd /home/aella && .*HOP='jammy-to-noble'|^cd /home/aella && .*HOP='jammy-to-noble'" "$file" || true)"

  block_count="$exec_count"
  hop_block_count="$hop_count"

  max_phys=0
  lineno=0
  hop_starts=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ ${#line} -gt "$max_phys" ]] && max_phys=${#line}
    if { [[ "$line" == \(\ cd\ /home/aella\ \&\&* ]] || [[ "$line" == cd\ /home/aella\ \&\&* ]]; } \
      && [[ "$line" == *HOP=* ]]; then
      hop_starts+=("$lineno")
    fi
  done <"$file"

  printf 'COMMAND_FILE_MODE=%s\n' "$mode"
  printf 'COMMAND_FILE_LINE_COUNT=%s\n' "$lines"
  printf 'COMMAND_FILE_EXECUTABLE_COUNT=%s\n' "$exec_count"
  printf 'COMMAND_FILE_COMMAND_BLOCK_COUNT=%s\n' "$block_count"
  printf 'COMMAND_FILE_OS_HOP_COUNT=%s\n' "$hop_count"
  printf 'COMMAND_FILE_OS_HOP_BLOCK_COUNT=%s\n' "$hop_block_count"
  printf 'COMMAND_FILE_MAX_PHYSICAL_LINE_LENGTH=%s\n' "$max_phys"

  case "$mode" in
    FULL)
      for n in 0 1 2 3 4 5 6 7 8 9; do
        if ! grep -qE "STEP ${n} —|Step ${n} —" "$file"; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_MISSING_STEP=%s\n' "$n"
          return 1
        fi
      done
      if [[ "$hop_count" -ne 4 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_COUNT=%s\n' "$hop_count"
        printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
        return 1
      fi
      [[ "$xenial" -eq 1 && "$bionic" -eq 1 && "$focal" -eq 1 && "$jammy" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_HOP_COVERAGE=FAIL\n'
        return 1
      }
      [[ "$stage_count" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_PHASE2_STAGE_COUNT=%s\n' "$stage_count"
        return 1
      }
      [[ "$bringup_count" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_BRINGUP_COUNT=%s\n' "$bringup_count"
        return 1
      }
      grep -q "EXPECTED_FPR=" "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_FINGERPRINT_PIN=MISSING\n'
        return 1
      }
      grep -q "public-keyring.gpg" "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_KEYRING=MISSING\n'
        return 1
      }
      grep -q "gpgv --keyring" "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_GPGV=MISSING\n'
        return 1
      }
      # Hop blocks invoke the verified runner; Phase 2 stage still has sudo bash.
      grep -q "dp-client-command-runner.sh\|bash \$R " "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_RUNNER_INVOKE=MISSING\n'
        return 1
      }
      grep -q "sudo bash" "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_SUDO_BASH=MISSING\n'
        return 1
      }

      max_block_lines=3
      for lineno in "${hop_starts[@]}"; do
        if ! mm_wf_validate_os_hop_block_at "$file" "$lineno" 240; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          return 1
        fi
      done
      # Reject trailing backslashes outside hop/stage command blocks.
      local stage_start="" ok_cont hs
      stage_start="$(grep -nE "^\( cd /home/aella && .*SCRIPT='stage-dp-phase2\.sh'|^cd /home/aella && .*SCRIPT='stage-dp-phase2\.sh'" "$file" | head -1 | cut -d: -f1 || true)"
      lineno=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        if [[ "$line" =~ \\[[:space:]]*$ ]]; then
          ok_cont=0
          for hs in "${hop_starts[@]}"; do
            if [[ "$lineno" -eq "$hs" || "$lineno" -eq $((hs + 1)) ]]; then
              ok_cont=1
              break
            fi
          done
          if [[ "$ok_cont" -eq 0 && -n "$stage_start" ]] \
            && { [[ "$lineno" -eq "$stage_start" ]] || [[ "$lineno" -eq $((stage_start + 1)) ]]; }
          then
            ok_cont=1
          fi
          if [[ "$ok_cont" -eq 0 ]]; then
            printf 'COMMAND_FILE_BUILD=FAIL\n'
            printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
            printf 'COMMAND_FILE_ARBITRARY_BACKSLASH=YES\n'
            printf 'COMMAND_FILE_ARBITRARY_BACKSLASH_LINE=%s\n' "$lineno"
            return 1
          fi
        fi
      done <"$file"
      ;;
    PHASE2_ONLY)
      if [[ "$hop_count" -ne 0 ]]; then
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_OS_HOP_COUNT=%s\n' "$hop_count"
        return 1
      fi
      grep -q 'Required OS: Ubuntu 24.04' "$file" || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_REQUIRED_OS=MISSING\n'
        return 1
      }
      [[ "$stage_count" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_PHASE2_STAGE_COUNT=%s\n' "$stage_count"
        return 1
      }
      [[ "$bringup_count" -eq 1 ]] || {
        printf 'COMMAND_FILE_BUILD=FAIL\n'
        printf 'COMMAND_FILE_BRINGUP_COUNT=%s\n' "$bringup_count"
        return 1
      }
      max_block_lines=3
      # Validate phase2 stage continuation if present.
      local stage_start
      stage_start="$(grep -nE "^\( cd /home/aella && .*SCRIPT='stage-dp-phase2\.sh'|^cd /home/aella && .*SCRIPT='stage-dp-phase2\.sh'" "$file" | head -1 | cut -d: -f1 || true)"
      if [[ -n "$stage_start" ]]; then
        local s1 s2 s3
        s1="$(sed -n "${stage_start}p" "$file")"
        s2="$(sed -n "$((stage_start + 1))p" "$file")"
        s3="$(sed -n "$((stage_start + 2))p" "$file")"
        [[ "$s1" =~ \\[[:space:]]*$ ]] || {
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
          return 1
        }
        [[ "$s2" =~ \\[[:space:]]*$ ]] || {
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
          return 1
        }
        if [[ "$s3" =~ \\[[:space:]]*$ ]]; then
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_CONTINUATION_VALIDATION=FAIL\n'
          return 1
        fi
        grep -q "sudo bash" <<<"$s3" || {
          printf 'COMMAND_FILE_BUILD=FAIL\n'
          printf 'COMMAND_FILE_SUDO_BASH=MISSING\n'
          return 1
        }
      fi
      ;;
    *)
      printf 'COMMAND_FILE_BUILD=FAIL\n'
      printf 'COMMAND_FILE_MODE_INVALID=%s\n' "$mode"
      return 1
      ;;
  esac

  printf 'COMMAND_FILE_MAX_BLOCK_LINES=%s\n' "$max_block_lines"
  printf 'COMMAND_FILE_CONTINUATION_VALIDATION=PASS\n'
  printf 'COMMAND_FILE_BUILD=PASS\n'
  return 0
}

mm_wf_atomic_publish_command_file() {
  # Args: tmp_file dest_file mode readiness_generation_id
  local tmp="$1" dest="$2" mode="$3" ready_gen="$4"
  local evidence sha
  evidence="$(mktemp)"
  if ! mm_wf_validate_command_file_content "$tmp" "$mode" | tee "$evidence"; then
    printf 'COMMAND_FILE_ATOMIC_PUBLISH=FAIL\n'
    cat "$evidence"
    rm -f "$evidence"
    return 1
  fi
  sha="$(sha256sum "$tmp" | awk '{print $1}')"
  mkdir -p "$(dirname "$dest")"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  mm_wf_mark_commands_generated "$ready_gen"
  printf 'COMMAND_FILE_BUILD=PASS\n'
  printf 'COMMAND_FILE_MODE=%s\n' "$mode"
  printf 'COMMAND_FILE_GENERATION_ID=%s\n' "$ready_gen"
  printf 'COMMAND_FILE_SHA256=%s\n' "$sha"
  printf 'COMMAND_FILE_ATOMIC_PUBLISH=PASS\n'
  printf 'COMMAND_FILE_VALID_FOR_READINESS_GENERATION=%s\n' "$ready_gen"
  # Re-emit counts from evidence
  grep -E '^COMMAND_FILE_(LINE|EXECUTABLE|OS_HOP|COMMAND_BLOCK|OS_HOP_BLOCK)_COUNT=' "$evidence" || true
  grep -E '^COMMAND_FILE_(MAX_BLOCK_LINES|MAX_PHYSICAL_LINE_LENGTH|CONTINUATION_VALIDATION)=' "$evidence" || true
  rm -f "$evidence"
  return 0
}

# Write client-set generation metadata into a published client root.
mm_wf_write_client_set_metadata() {
  local dest="$1" gen="$2" fpr="$3" mirror_url="$4" mode="$5"
  local meta="${dest}/client-set.env"
  cat >"${meta}.tmp" <<EOF
CLIENT_SET_GENERATION_ID=${gen}
CLIENT_SIGNING_FINGERPRINT=${fpr}
MIRROR_HTTP_URL=${mirror_url}
PREPARATION_MODE=${mode}
PHASE2_TARGET_VERSION=${PHASE2_TARGET_VERSION:-6.5.0}
CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0644 "${meta}.tmp"
  mv -f "${meta}.tmp" "$meta"
  chmod 0644 "$meta"
}

# Xenial-compatible fingerprint extraction from a binary keyring file.
# Prints uppercase 40-hex primary fingerprint or fails.
mm_wf_keyring_fingerprint() {
  local keyring="$1"
  local fpr
  [[ -f "$keyring" && -s "$keyring" ]] || return 1
  # Prefer --with-colons (available on Xenial GnuPG 1.4+/2.x).
  fpr="$(gpg --batch --no-default-keyring --keyring "$keyring" \
    --with-colons --fingerprint 2>/dev/null \
    | awk -F: '/^fpr:/{print $10; exit}')"
  if [[ -z "$fpr" ]]; then
    fpr="$(gpg --batch --no-default-keyring --keyring "$keyring" \
      --fingerprint 2>/dev/null \
      | awk '/key fingerprint =/{gsub(/ /,"",$0); sub(/^.*=/,"",$0); print; exit}')"
  fi
  [[ -n "$fpr" ]] || return 1
  fpr="${fpr^^}"
  fpr="${fpr// /}"
  [[ ${#fpr} -eq 40 ]] || return 1
  printf '%s\n' "$fpr"
}
