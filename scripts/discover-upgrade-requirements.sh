#!/usr/bin/env bash
# discover-upgrade-requirements.sh — Collect real APT/do-release-upgrade requirements
# for one Ubuntu LTS hop. Independent of the dp-os-upgrade orchestrator.
#
# Commands:
#   init | before-hop | start-recording | stop-recording
#   after-hop | finalize-hop | status | validate | restore-apt-proxy
#
# Compatible with Bash 4.3+ / Ubuntu 16.04 base utilities (+ python3).
# shellcheck disable=SC2034

set -uo pipefail
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/discover-upgrade-requirements-common.sh
source "${SCRIPT_DIR}/lib/discover-upgrade-requirements-common.sh"

DUR_OUTPUT_DIR_CLI=""
DUR_FROM_OS=""
DUR_TO_OS=""
DUR_HOP=""
DUR_PHASE=""
DUR_OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage:
  discover-upgrade-requirements.sh init --from FROM --to TO --output-dir DIR
  discover-upgrade-requirements.sh before-hop [--output-dir DIR]
  discover-upgrade-requirements.sh start-recording [--output-dir DIR]
  discover-upgrade-requirements.sh stop-recording [--output-dir DIR]
  discover-upgrade-requirements.sh after-hop [--output-dir DIR]
  discover-upgrade-requirements.sh finalize-hop [--output-dir DIR]
  discover-upgrade-requirements.sh status [--output-dir DIR]
  discover-upgrade-requirements.sh validate [--output-dir DIR]
  discover-upgrade-requirements.sh restore-apt-proxy [--output-dir DIR]

Supported hops:
  16.04/xenial -> 18.04/bionic
  18.04/bionic -> 20.04/focal
  20.04/focal  -> 22.04/jammy
  22.04/jammy  -> 24.04/noble

Typical flow:
  sudo ./scripts/discover-upgrade-requirements.sh init --from 16.04 --to 18.04 \
    --output-dir /opt/aelladata/test-run
  sudo ./scripts/discover-upgrade-requirements.sh before-hop \
    --output-dir /opt/aelladata/test-run
  sudo ./scripts/discover-upgrade-requirements.sh start-recording \
    --output-dir /opt/aelladata/test-run
  # run apt update / dist-upgrade / do-release-upgrade here (HTTP via local recorder)
  sudo ./scripts/discover-upgrade-requirements.sh stop-recording \
    --output-dir /opt/aelladata/test-run
  sudo ./scripts/discover-upgrade-requirements.sh after-hop \
    --output-dir /opt/aelladata/test-run
  sudo ./scripts/discover-upgrade-requirements.sh finalize-hop \
    --output-dir /opt/aelladata/test-run

  # Later commands may omit --output-dir only when exactly one active run exists.
  # After a crash during recording, restore APT proxy with restore-apt-proxy.

Environment:
  DUR_HOST_ROOT       Prefix host paths (fixture tests)
  DUR_DRY_RECORDING=1 Do not bind HTTP proxy (fixture / offline); still installs APT proxy conf
  DUR_PROXY_PORT      Proxy listen port (default 18080)
  DUR_HASH_MAX_BYTES  Max file size to SHA256 during inventory
  DUR_REGISTRY_DIR    Active-run registry location
EOF
}

cmd_init() {
  local from_raw="" to_raw=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from_raw="${2:-}"; shift 2 ;;
      --to) to_raw="${2:-}"; shift 2 ;;
      --output-dir) DUR_OUTPUT_DIR_CLI="${2:-}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) dur_die "unknown init option: $1" ;;
    esac
  done
  [[ -n "$from_raw" ]] || dur_die "init requires --from"
  [[ -n "$to_raw" ]] || dur_die "init requires --to"
  [[ -n "${DUR_OUTPUT_DIR_CLI:-}" ]] || dur_die "init requires --output-dir DIR"

  # Validate Python helpers before creating any state.
  dur_require_python || exit 1
  dur_resolve_output_dir init
  DUR_FROM_OS="$(dur_normalize_version "$from_raw")" || exit 1
  DUR_TO_OS="$(dur_normalize_version "$to_raw")" || exit 1
  DUR_HOP="$(dur_hop_name "$DUR_FROM_OS" "$DUR_TO_OS")" || exit 1

  local hop_dir root sf
  root="$(dur_root_dir)"
  hop_dir="$(dur_hop_dir)"
  sf="$(dur_state_file)"

  if [[ -f "${hop_dir}/run.json" ]]; then
    local existing_phase
    existing_phase="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("phase",""))' "${hop_dir}/run.json" 2>/dev/null || true)"
    if [[ "$existing_phase" == "finalized" ]]; then
      dur_die "refusing overwrite: ${hop_dir} already finalized"
    fi
    if [[ -n "$existing_phase" && "$existing_phase" != "initialized" ]]; then
      dur_log INFO "resuming existing incomplete hop ${DUR_HOP} (phase=${existing_phase})"
      DUR_PHASE="$existing_phase"
      dur_save_state
      dur_write_run_json "$DUR_PHASE"
      dur_register_output_dir "$DUR_OUTPUT_DIR"
      printf 'Resumed hop=%s phase=%s output=%s\n' "$DUR_HOP" "$DUR_PHASE" "$DUR_OUTPUT_DIR"
      return 0
    fi
  fi

  # Create state only after all validations succeeded.
  mkdir -p "$root" || dur_die "cannot create ${root}"
  if ! dur_ensure_hop_layout; then
    rm -rf "$root" 2>/dev/null || true
    dur_die "failed to create hop layout under ${root}"
  fi
  DUR_PHASE="initialized"
  if ! dur_save_state || ! dur_write_run_json "initialized"; then
    rm -rf "$root" 2>/dev/null || true
    dur_unregister_output_dir "$DUR_OUTPUT_DIR"
    dur_die "failed to write discovery state; no active run left"
  fi
  dur_register_output_dir "$DUR_OUTPUT_DIR"
  dur_hook BEFORE_HOP || true
  printf 'Initialized hop=%s from=%s to=%s output=%s\n' \
    "$DUR_HOP" "$DUR_FROM_OS" "$DUR_TO_OS" "$DUR_OUTPUT_DIR"
}

cmd_before_hop() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  dur_assert_not_finalized
  if [[ "$DUR_PHASE" == "before_failed" ]]; then
    dur_log INFO "retrying before-hop after previous before_failed"
  elif [[ "$(dur_phase_rank "$DUR_PHASE")" -gt "$(dur_phase_rank initialized)" && "$DUR_PHASE" != "initialized" ]]; then
    if [[ -f "$(dur_hop_dir)/before/installed-packages.tsv" && -f "$(dur_hop_dir)/before/file-manifest.tsv" ]]; then
      dur_log INFO "before inventory already present; resume OK"
      return 0
    fi
    if [[ -f "$(dur_hop_dir)/before/installed-packages.tsv" && ! -f "$(dur_hop_dir)/before/file-manifest.tsv" ]]; then
      dur_log INFO "before inventory incomplete (file-manifest missing); re-running"
    fi
  fi
  [[ "$DUR_PHASE" == "initialized" || "$DUR_PHASE" == "before_collected" || "$DUR_PHASE" == "before_failed" ]] || \
    dur_die "before-hop requires phase initialized (have ${DUR_PHASE})"

  dur_hook BEFORE_HOP
  dur_ensure_hop_layout
  dur_write_apt_keep_downloads
  if ! dur_collect_inventory before; then
    DUR_PHASE="before_failed"
    dur_save_state || true
    dur_write_run_json "before_failed" || true
    dur_die "before-hop failed; state=before_failed (file-manifest/inventory incomplete)"
  fi
  if [[ ! -f "$(dur_hop_dir)/before/file-manifest.tsv" ]]; then
    DUR_PHASE="before_failed"
    dur_save_state || true
    dur_write_run_json "before_failed" || true
    dur_die "before-hop failed; file-manifest.tsv missing; state=before_failed"
  fi
  DUR_PHASE="before_collected"
  dur_save_state
  dur_write_run_json
  printf 'before-hop complete: %s\n' "$(dur_hop_dir)/before"
}

cmd_start_recording() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  dur_assert_not_finalized
  if [[ "$DUR_PHASE" == "before_failed" ]]; then
    dur_die "cannot start-recording after before_failed; re-run before-hop first"
  fi
  if [[ "$DUR_PHASE" != "before_collected" && "$DUR_PHASE" != "recording" ]]; then
    if [[ "$(dur_phase_rank "$DUR_PHASE")" -lt "$(dur_phase_rank before_collected)" ]]; then
      dur_die "start-recording requires successful before-hop (have ${DUR_PHASE})"
    fi
  fi
  dur_assert_phase_at_least before_collected
  local hop_dir
  hop_dir="$(dur_hop_dir)"
  if [[ ! -f "${hop_dir}/before/file-manifest.tsv" ]]; then
    dur_die "cannot start-recording: ${hop_dir}/before/file-manifest.tsv missing (before-hop incomplete)"
  fi
  if [[ "$DUR_PHASE" == "recording" ]]; then
    dur_log INFO "already recording"
    return 0
  fi
  if [[ "$(dur_phase_rank "$DUR_PHASE")" -gt "$(dur_phase_rank recording)" ]]; then
    dur_die "cannot start-recording from phase ${DUR_PHASE}"
  fi

  local started
  started="$(dur_utc_now)"
  mkdir -p "${hop_dir}/runtime"
  # Discard any pre-recording proxy noise; only requests after this point count.
  : >"${hop_dir}/runtime/proxy-access.log"
  rm -f "${hop_dir}/runtime/requested-urls.tsv" 2>/dev/null || true
  dur_save_log_offsets
  printf '%s\n' "$started" >"${hop_dir}/runtime/recording-started-at.txt"

  # Do not mark phase=recording until proxy + APT config + self-test succeed.
  if ! dur_start_http_recorder; then
    rm -f "${hop_dir}/runtime/recording-active" 2>/dev/null || true
    dur_stop_http_recorder || true
    dur_record_command "start-recording" 1 "$started" "$(dur_utc_now)" false
    dur_die "start-recording failed: HTTP recorder / APT proxy / self-test not ready"
  fi

  printf 'true\n' >"${hop_dir}/runtime/recording-active"
  DUR_PHASE="recording"
  dur_save_state
  dur_write_run_json
  dur_record_command "start-recording" 0 "$started" "$(dur_utc_now)" false
  local port conf
  port="${DUR_PROXY_PORT:-18080}"
  conf="$(dur_apt_recorder_conf_path)"
  printf 'Recording started for hop=%s\n' "$DUR_HOP"
  printf 'APT Acquire::http::Proxy -> http://127.0.0.1:%s/ via %s\n' "$port" "$conf"
  printf 'HTTPS full-URL capture is unsupported; Acquire::https::Proxy=DIRECT.\n'
  printf 'Prefer http:// archive mirrors for discovery. Then run apt update / dist-upgrade.\n'
}

cmd_stop_recording() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  dur_assert_not_finalized
  if [[ "$DUR_PHASE" != "recording" && "$DUR_PHASE" != "recording_stopped" ]]; then
    dur_die "stop-recording requires phase recording (have ${DUR_PHASE})"
  fi
  local started ended
  started="$(cat "$(dur_hop_dir)/runtime/recording-started-at.txt" 2>/dev/null || dur_utc_now)"
  ended="$(dur_utc_now)"
  dur_stop_http_recorder
  rm -f "$(dur_hop_dir)/runtime/recording-active" 2>/dev/null || true
  dur_capture_logs_since_offsets
  dur_preserve_apt_archives
  printf '%s\n' "$ended" >"$(dur_hop_dir)/runtime/recording-ended-at.txt"
  DUR_PHASE="recording_stopped"
  dur_save_state
  dur_write_run_json
  dur_record_command "stop-recording" 0 "$started" "$ended" false
  printf 'Recording stopped; APT proxy restored; logs under %s/runtime\n' "$(dur_hop_dir)"
}

cmd_restore_apt_proxy() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  dur_restore_apt_recorder_proxy
  printf 'APT proxy restore complete for %s\n' "$(dur_hop_dir)"
}

cmd_after_hop() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  dur_assert_not_finalized
  dur_assert_phase_at_least recording_stopped
  if [[ "$DUR_PHASE" == "after_collected" || "$DUR_PHASE" == "finalized" ]]; then
    if [[ -f "$(dur_hop_dir)/after/installed-packages.tsv" ]]; then
      dur_log INFO "after inventory already present"
      return 0
    fi
  fi

  dur_hook AFTER_HOP
  # Re-capture archives/logs in case upgrade cleaned cache after stop
  dur_capture_logs_since_offsets
  dur_preserve_apt_archives
  if ! dur_collect_inventory after; then
    dur_die "after-hop inventory failed"
  fi
  DUR_PHASE="after_collected"
  dur_save_state
  dur_write_run_json
  dur_hook HOP_FINISH
  printf 'after-hop complete: %s\n' "$(dur_hop_dir)/after"
}

cmd_finalize_hop() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  if [[ "$DUR_PHASE" == "finalized" ]]; then
    dur_die "hop already finalized; refusing overwrite"
  fi
  dur_assert_phase_at_least after_collected

  local hop_dir
  hop_dir="$(dur_hop_dir)"

  # Ensure minimum runtime log placeholders exist for validation
  mkdir -p "${hop_dir}/runtime/dist-upgrade"
  [[ -f "${hop_dir}/runtime/apt-history.log" ]] || : >"${hop_dir}/runtime/apt-history.log"
  [[ -f "${hop_dir}/runtime/apt-term.log" ]] || : >"${hop_dir}/runtime/apt-term.log"
  [[ -f "${hop_dir}/runtime/dpkg.log" ]] || : >"${hop_dir}/runtime/dpkg.log"
  [[ -f "${hop_dir}/runtime/proxy-access.log" ]] || : >"${hop_dir}/runtime/proxy-access.log"
  [[ -f "${hop_dir}/runtime/proxy-error.log" ]] || : >"${hop_dir}/runtime/proxy-error.log"

  dur_log INFO "building manifests for ${DUR_HOP}"
  if ! dur_py build-manifests --hop-dir "$hop_dir" --hop "$DUR_HOP" >/dev/null; then
    dur_log ERROR "manifest build failed; not running validate; phase left unchanged (${DUR_PHASE})"
    return 1
  fi

  dur_log INFO "validating ${DUR_HOP}"
  if ! dur_py validate --hop-dir "$hop_dir" --hop "$DUR_HOP" --from-os "$DUR_FROM_OS" --to-os "$DUR_TO_OS"; then
    dur_log ERROR "validation FAILED - finalize not marked successful"
    DUR_PHASE="after_collected"
    dur_save_state
    dur_write_run_json "validation_failed"
    return 1
  fi

  DUR_PHASE="finalized"
  dur_save_state
  dur_write_run_json "finalized"
  printf 'finalize-hop PASS\n'
  printf '  %s\n' "${hop_dir}/required-packages.tsv"
  printf '  %s\n' "${hop_dir}/required-files.tsv"
  printf '  %s\n' "${hop_dir}/required-urls.tsv"
  printf '  %s\n' "${hop_dir}/validation.txt"
}

cmd_status() {
  _parse_output_dir "$@"
  # status uses the same output-dir resolution rules as other commands
  if [[ -z "${DUR_OUTPUT_DIR_CLI:-}" && -z "${DUR_OUTPUT_DIR:-}" ]]; then
    local actives active_count
    mapfile -t actives < <(dur_list_active_output_dirs | sort -u)
    active_count="${#actives[@]}"
    if [[ "$active_count" -eq 1 && -z "${actives[0]:-}" ]]; then
      active_count=0
    fi
    if [[ "$active_count" -eq 0 ]]; then
      printf 'status: no active discovery state; pass --output-dir DIR\n'
      return 0
    fi
    if [[ "$active_count" -gt 1 ]]; then
      {
        printf 'ERROR: ambiguous active discovery runs (%s); pass --output-dir DIR\n' "$active_count"
        local a
        for a in "${actives[@]}"; do
          printf '  - %s\n' "$a"
        done
      } >&2
      return 1
    fi
    DUR_OUTPUT_DIR="${actives[0]}"
  else
    dur_resolve_output_dir existing
  fi
  local sf
  sf="$(dur_state_file)"
  if [[ ! -f "$sf" ]]; then
    printf 'status: no discovery state at %s\n' "$sf"
    return 0
  fi
  DUR_FROM_OS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("from_os",""))' "$sf")"
  DUR_TO_OS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("to_os",""))' "$sf")"
  DUR_HOP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("hop",""))' "$sf")"
  DUR_PHASE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("phase",""))' "$sf")"
  printf 'status:\n'
  printf '  output_dir: %s\n' "${DUR_OUTPUT_DIR}"
  printf '  hop: %s\n' "${DUR_HOP}"
  printf '  from_os: %s\n' "${DUR_FROM_OS}"
  printf '  to_os: %s\n' "${DUR_TO_OS}"
  printf '  phase: %s\n' "${DUR_PHASE}"
  printf '  hop_dir: %s\n' "$(dur_hop_dir)"
  if [[ -f "$(dur_hop_dir)/validation.txt" ]]; then
    printf '  validation:\n'
    sed 's/^/    /' "$(dur_hop_dir)/validation.txt" || true
  fi
  return 0
}

cmd_validate() {
  _parse_output_dir "$@"
  dur_load_active_or_die
  dur_py validate --hop-dir "$(dur_hop_dir)" --hop "$DUR_HOP" --from-os "$DUR_FROM_OS" --to-os "$DUR_TO_OS"
}

_parse_output_dir() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir) DUR_OUTPUT_DIR_CLI="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) dur_die "unknown option: $1" ;;
    esac
  done
  if [[ -n "${DUR_OUTPUT_DIR_CLI}" ]]; then
    DUR_OUTPUT_DIR="$DUR_OUTPUT_DIR_CLI"
  fi
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    before-hop) cmd_before_hop "$@" ;;
    start-recording) cmd_start_recording "$@" ;;
    stop-recording) cmd_stop_recording "$@" ;;
    after-hop) cmd_after_hop "$@" ;;
    finalize-hop) cmd_finalize_hop "$@" ;;
    status) cmd_status "$@" ;;
    validate) cmd_validate "$@" ;;
    restore-apt-proxy) cmd_restore_apt_proxy "$@" ;;
    -h|--help|help|"") usage; [[ -n "$cmd" ]] || return 0; return 0 ;;
    --version|version) printf '%s %s\n' "$(basename "$0")" "$DUR_SCRIPT_VERSION" ;;
    *) dur_die "unknown command: $cmd (see --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
