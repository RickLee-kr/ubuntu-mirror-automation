#!/usr/bin/env bash
# scripts/dp-os-upgrade-runner.sh — Phase 1 hop executor (pinned runtime copy)
# Compatible with Bash 4.3+ / Ubuntu 16.04.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer sibling common library (runtime pin) then repo path
if [[ -f "${SCRIPT_DIR}/dp-os-upgrade-common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/dp-os-upgrade-common.sh"
  OSU_ROOT="${OSU_ROOT:-}"
elif [[ -f "${SCRIPT_DIR}/lib/dp-os-upgrade-common.sh" ]]; then
  # shellcheck source=lib/dp-os-upgrade-common.sh
  source "${SCRIPT_DIR}/lib/dp-os-upgrade-common.sh"
  OSU_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
  printf 'ERROR: cannot locate dp-os-upgrade-common.sh\n' >&2
  exit 3
fi

MODE="run"
for arg in "$@"; do
  case "$arg" in
    --from-install) MODE="from-install" ;;
    --resume) MODE="resume" ;;
    --retry) MODE="retry" ;;
  esac
done

osu_init_test_mode || exit "$EXIT_CLI"
osu_load_config "${OSU_CONFIG_FILE:-}" || exit "$EXIT_CLI"
OSU_EXECUTE="${OSU_EXECUTE:-1}"

# When running from pinned runtime, OSU_ROOT may be empty — recover from state
if [[ -z "${OSU_ROOT:-}" ]]; then
  if [[ -f "${OSU_STATE_DIR}/policy-effective.conf" ]]; then
    OSU_ROOT="$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")" # best effort
  fi
fi

runner_init_state() {
  [[ -f "$(osu_state_path)" ]] || { osu_log ERROR "no state.json"; exit "$EXIT_INTEGRITY"; }
  osu_verify_state_checksum || { osu_log ERROR "state checksum mismatch"; exit "$EXIT_INTEGRITY"; }
  osu_load_state_into_vars || exit "$EXIT_INTEGRITY"
  osu_verify_runtime || { osu_set_blocked "runtime_checksum_changed" false; exit "$EXIT_BLOCKED"; }
}

# Advance OS fake version in test mode after a hop
runner_simulate_os_advance() {
  local to_ver="$1" to_code="$2"
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    export DP_OS_UPGRADE_FAKE_OS_VERSION="$to_ver"
    export DP_OS_UPGRADE_FAKE_OS_CODENAME="$to_code"
    local osr
    osr="$(osu_hostpath /etc/os-release)"
    mkdir -p "$(dirname "$osr")"
    cat >"$osr" <<EOF
NAME="Ubuntu"
VERSION_ID="${to_ver}"
VERSION_CODENAME=${to_code}
ID=ubuntu
EOF
  fi
}

runner_setup_hop_dirs() {
  local hop_num="$1" from_code="$2" to_code="$3"
  local name
  name="$(osu_hop_dirname "$hop_num" "$from_code" "$to_code")"
  OSU_CURRENT_HOP_DIR="${OSU_STATE_DIR}/hops/${name}"
  mkdir -p "$OSU_CURRENT_HOP_DIR"/{repository-before,repository-after,dist-upgrade,apt}
  printf '%s' "$OSU_CURRENT_HOP_DIR"
}

runner_write_hop_plan() {
  local hop_dir="$1" from_ver="$2" from_code="$3" to_ver="$4" to_code="$5"
  cat >"${hop_dir}/plan.json" <<EOF
{
  "from_os": "${from_ver}",
  "from_codename": "${from_code}",
  "to_os": "${to_ver}",
  "to_codename": "${to_code}",
  "package_source_mode": "$(osu_json_escape "${ST_PKG_MODE}")",
  "phase2": false
}
EOF
}

runner_snapshot_before() {
  local hop_dir="$1"
  local osr
  osr="$(osu_hostpath /etc/os-release)"
  [[ -f "$osr" ]] && cp -a "$osr" "${hop_dir}/os-before.txt"
  osu_read_held_packages >"${hop_dir}/held-before.txt" || true
  if [[ -f "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" ]]; then
    cp -a "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" "${hop_dir}/critical-checksums-before.tsv"
  fi
  if [[ -f "$(osu_hostpath /etc/apt/sources.list)" ]]; then
    cp -a "$(osu_hostpath /etc/apt/sources.list)" "${hop_dir}/repository-before/sources.list" || true
  fi
  if declare -F osu_capture_hop_artifacts >/dev/null 2>&1; then
    osu_capture_hop_artifacts "$hop_dir" before || osu_log WARN "artifact before-capture warning"
  fi
}

runner_snapshot_after() {
  local hop_dir="$1"
  local osr
  osr="$(osu_hostpath /etc/os-release)"
  [[ -f "$osr" ]] && cp -a "$osr" "${hop_dir}/os-after.txt"
  osu_read_held_packages >"${hop_dir}/held-after.txt" || true
  if [[ -f "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" ]]; then
    cp -a "${OSU_STATE_DIR}/original-system-state/critical-checksums.tsv" "${hop_dir}/critical-checksums-after.tsv"
  fi
  if [[ -f "$(osu_hostpath /etc/apt/sources.list)" ]]; then
    cp -a "$(osu_hostpath /etc/apt/sources.list)" "${hop_dir}/repository-after/sources.list" || true
  fi
  if declare -F osu_capture_hop_artifacts >/dev/null 2>&1; then
    osu_capture_hop_artifacts "$hop_dir" after || osu_log WARN "artifact after-capture warning"
  fi
}

runner_run_do_release_upgrade() {
  local hop_dir="$1" to_code="$2"
  # Noninteractive; options vary by Ubuntu version — use conservative set
  # Never invent unsupported flags for xenial.
  local args=(-f DistUpgradeViewNonInteractive)
  # Frontend noninteractive via env in osu_run_command
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    osu_run_command "${ST_CURRENT_HOP}" "do-release-upgrade" "simulated do-release-upgrade to ${to_code}" \
      "${POLICY_DO_RELEASE_UPGRADE_TIMEOUT_SECONDS}" false -- \
      do-release-upgrade "${args[@]}" || return 1
    # Stub should advance OS; if not, runner_simulate_os_advance is called by caller
    return 0
  fi
  osu_run_command "${ST_CURRENT_HOP}" "do-release-upgrade" "do-release-upgrade" \
    "${POLICY_DO_RELEASE_UPGRADE_TIMEOUT_SECONDS}" false -- \
    do-release-upgrade "${args[@]}" || return 1
  # Collect dist-upgrade logs
  if [[ -d "$(osu_hostpath /var/log/dist-upgrade)" ]]; then
    cp -a "$(osu_hostpath /var/log/dist-upgrade)/." "${hop_dir}/dist-upgrade/" 2>/dev/null || true
  fi
  return 0
}

runner_execute_hop() {
  local hop_num="$1" from_ver="$2" from_code="$3" to_ver="$4" to_code="$5"
  local hop_dir

  ST_CURRENT_HOP="$hop_num"
  ST_CURRENT_OS="$from_ver"
  ST_CURRENT_CODENAME="$from_code"
  ST_TARGET_OS="$to_ver"
  ST_TARGET_CODENAME="$to_code"
  ST_ATTEMPT=$(( ${ST_ATTEMPT:-0} + 1 ))

  hop_dir="$(runner_setup_hop_dirs "$hop_num" "$from_code" "$to_code")"
  OSU_CURRENT_HOP_DIR="$hop_dir"
  runner_write_hop_plan "$hop_dir" "$from_ver" "$from_code" "$to_ver" "$to_code"

  osu_transition_state HOP_PRECHECK "hop_precheck" || return 1
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  # Confirm current OS matches hop source
  local cur
  cur="$(osu_current_os_version)"
  if [[ "$cur" != "$from_ver" ]]; then
    # If already at target (resume after reboot), skip to validate
    if [[ "$cur" == "$to_ver" ]]; then
      osu_transition_state HOP_VALIDATING "already_at_target" || true
      if osu_post_hop_validate "$to_ver" "$to_code"; then
        runner_snapshot_after "$hop_dir"
        cat >"${hop_dir}/validation.json" <<EOF
{"status":"PASS","os":"${to_ver}","codename":"${to_code}"}
EOF
        cat >"${hop_dir}/result.json" <<EOF
{"status":"HOP_COMPLETED","from":"${from_ver}","to":"${to_ver}"}
EOF
        osu_transition_state HOP_COMPLETED "hop_completed"
        return 0
      else
        osu_set_failed "post_reboot_validation_failed"
        return 1
      fi
    fi
    osu_set_failed "os_state_conflict current=$cur expected=$from_ver"
    return 1
  fi

  # Live precheck
  if ! osu_live_precheck; then
    # classify retryable
    case "${LIVE_PRECHECK_REASONS}" in
      *apt_lock*|*ntp_unsynchronized*)
        osu_set_blocked "${LIVE_PRECHECK_REASONS}" true
        ;;
      *)
        osu_set_blocked "${LIVE_PRECHECK_REASONS}" false
        ;;
    esac
    return 1
  fi

  if ! osu_manage_critical_holds_if_enabled; then
    osu_set_blocked "critical_holds_unmanaged" false
    return 1
  fi

  osu_transition_state HOP_SOURCE_PREPARING "source_preparing" || return 1
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  runner_snapshot_before "$hop_dir"
  osu_backup_apt_sources
  osu_disable_third_party_repos

  if ! osu_verify_hop_repository "$ST_PKG_MODE" "$ST_PKG_URL" "$from_code"; then
    case "$ST_PKG_MODE" in
      mirror|cache) osu_set_blocked "repository_unavailable_${from_code}" true ;;
      *) osu_set_blocked "repository_unavailable_${from_code}" false ;;
    esac
    return 1
  fi
  # Also verify target release metadata exists for next hop planning
  if ! osu_verify_hop_repository "$ST_PKG_MODE" "$ST_PKG_URL" "$to_code"; then
    osu_set_blocked "target_repository_unavailable_${to_code}" false
    return 1
  fi

  osu_apply_sources_for_hop "$ST_PKG_MODE" "$ST_PKG_URL" "$from_code"
  osu_write_source_plan "$ST_PKG_MODE" "$ST_PKG_URL" "$from_code"
  osu_transition_state HOP_SOURCE_READY "source_ready" || return 1

  osu_transition_state HOP_CURRENT_RELEASE_UPDATING "current_release_updating" || return 1
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  # dpkg recovery / update (via stubs in test)
  osu_run_command "$hop_num" "dpkg_configure" "dpkg --configure -a" 600 true -- dpkg --configure -a || true
  osu_run_command "$hop_num" "apt_fix" "apt-get -f install" 600 true -- apt-get -y -f install || {
    osu_set_failed "apt_fix_failed"; return 1
  }
  osu_run_command "$hop_num" "apt_update" "apt-get update" "${POLICY_APT_UPDATE_TIMEOUT_SECONDS}" true -- apt-get update || {
    osu_set_blocked "apt_update_failed" true; return 1
  }
  osu_run_command "$hop_num" "apt_full_upgrade" "apt-get dist-upgrade (current release)" \
    "${POLICY_APT_UPDATE_TIMEOUT_SECONDS}" true -- apt-get -y dist-upgrade || {
    osu_set_failed "current_release_upgrade_failed"; return 1
  }
  # Ensure upgrader present
  osu_run_command "$hop_num" "upgrader_core" "ensure ubuntu-release-upgrader-core" 600 true -- \
    apt-get -y install ubuntu-release-upgrader-core || true

  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  osu_transition_state HOP_RELEASE_UPGRADE_STARTING "release_upgrade_starting" || return 1
  # Persist before long-running upgrade
  osu_write_state_json "$(osu_build_state_json)" || return 1

  osu_transition_state HOP_RELEASE_UPGRADE_RUNNING "release_upgrade_running" || return 1
  if ! runner_run_do_release_upgrade "$hop_dir" "$to_code"; then
    osu_set_failed "do_release_upgrade_failed"
    return 1
  fi

  # In test mode, advance OS representation now (simulates upgrade before reboot)
  runner_simulate_os_advance "$to_ver" "$to_code"

  # Require reboot for each hop by policy
  osu_transition_state REBOOT_REQUIRED "reboot_required" || return 1
  cat >"${hop_dir}/result.json" <<EOF
{"status":"REBOOT_REQUIRED","from":"${from_ver}","to":"${to_ver}"}
EOF
  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi

  # Ensure systemd resume enabled (best effort)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable dp-os-upgrade.service 2>/dev/null || true
  fi

  osu_request_reboot || return 1

  # In test mode, continue as if reboot happened
  if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
    # Simulate new boot id
    mkdir -p "$(dirname "$(osu_hostpath /proc/sys/kernel/random/boot_id)")"
    printf 'boot-%s\n' "$(osu_utc_stamp)" >"$(osu_hostpath /proc/sys/kernel/random/boot_id)"
    osu_transition_state RESUMED "post_reboot_resumed" || return 1
    osu_transition_state HOP_VALIDATING "post_reboot_validating" || return 1
    if ! osu_post_hop_validate "$to_ver" "$to_code"; then
      osu_set_failed "post_hop_validation_failed"
      return 1
    fi
    runner_snapshot_after "$hop_dir"
    cat >"${hop_dir}/validation.json" <<EOF
{"status":"PASS","os":"${to_ver}","codename":"${to_code}"}
EOF
    cat >"${hop_dir}/result.json" <<EOF
{"status":"HOP_COMPLETED","from":"${from_ver}","to":"${to_ver}"}
EOF
    ST_CURRENT_OS="$to_ver"
    ST_CURRENT_CODENAME="$to_code"
    osu_transition_state HOP_COMPLETED "hop_completed" || return 1
    return 0
  fi

  # Production: exit after reboot request; systemd will resume
  exit "$EXIT_RESUME_REQUIRED"
}

runner_handle_reboot_resume() {
  case "$ST_STATE" in
    REBOOT_REQUESTED|REBOOT_REQUIRED)
      local cur_boot
      cur_boot="$(osu_boot_id)"
      if [[ -n "${ST_BOOT_ID:-}" && "$cur_boot" == "$ST_BOOT_ID" && "$OSU_TEST_MODE" -eq 0 ]]; then
        osu_log WARN "boot_id unchanged after REBOOT_REQUESTED — waiting for real reboot"
        exit "$EXIT_RESUME_REQUIRED"
      fi
      osu_transition_state RESUMED "boot_resumed" || return 1
      osu_transition_state HOP_VALIDATING "validating_after_reboot" || return 1
      if ! osu_post_hop_validate "$ST_TARGET_OS" "$ST_TARGET_CODENAME"; then
        # If still on old OS, do not re-run upgrade blindly
        local cur
        cur="$(osu_current_os_version)"
        if [[ "$cur" == "$ST_CURRENT_OS" ]]; then
          osu_set_blocked "reboot_incomplete_still_on_${cur}" false
          return 1
        fi
        osu_set_failed "wrong_target_os_after_reboot"
        return 1
      fi
      local hop_dir
      hop_dir="$(runner_setup_hop_dirs "$ST_CURRENT_HOP" "$ST_CURRENT_CODENAME" "$ST_TARGET_CODENAME")"
      runner_snapshot_after "$hop_dir"
      cat >"${hop_dir}/validation.json" <<EOF
{"status":"PASS","os":"${ST_TARGET_OS}","codename":"${ST_TARGET_CODENAME}"}
EOF
      ST_CURRENT_OS="$ST_TARGET_OS"
      ST_CURRENT_CODENAME="$ST_TARGET_CODENAME"
      osu_transition_state HOP_COMPLETED "hop_completed"
      ;;
  esac
  return 0
}

runner_enter_checkpoint() {
  local cur
  cur="$(osu_current_os_version)"
  ST_CURRENT_OS="$cur"
  ST_CURRENT_CODENAME="$(osu_current_os_codename)"
  ST_NEW_PREFLIGHT_REQUIRED=true
  ST_NEXT_ACTION="RECOLLECT_AND_REPREFLIGHT"
  osu_transition_state CHECKPOINT_REACHED "checkpoint_reached" "${ST_CHECKPOINT_REASON:-hop_limit}"
  osu_generate_reports
  osu_log INFO "CHECKPOINT_REACHED at ${cur}: ${ST_CHECKPOINT_REASON:-}. New collector/preflight required. Phase 2 not evaluated."
  exit "${EXIT_CHECKPOINT:-41}"
}

runner_next_hop_or_complete() {
  local cur
  cur="$(osu_current_os_version)"

  # If we just finished a hop, count it and maybe checkpoint before planning next
  if [[ "${ST_STATE}" == "HOP_COMPLETED" ]]; then
    ST_HOPS_THIS_RUN=$(( ${ST_HOPS_THIS_RUN:-0} + 1 ))
    ST_CURRENT_OS="$cur"
    ST_CURRENT_CODENAME="$(osu_current_os_codename)"
    osu_write_state_json "$(osu_build_state_json)" || true
    if declare -F osu_should_checkpoint_after_hop >/dev/null 2>&1 && osu_should_checkpoint_after_hop "$cur"; then
      runner_enter_checkpoint
    fi
  fi

  if [[ "$cur" == "$POLICY_TARGET_OS_VERSION" ]]; then
    if ! osu_post_hop_validate "$POLICY_TARGET_OS_VERSION" "$POLICY_TARGET_OS_CODENAME"; then
      osu_set_failed "final_validation_failed"
      exit "$EXIT_FAILED"
    fi
    ST_NEXT_ACTION="RUN_SEPARATE_PHASE2_WORKFLOW"
    ST_NEW_PREFLIGHT_REQUIRED=false
    osu_transition_state COMPLETED "phase1_completed"
    osu_generate_reports
    osu_log INFO "Phase 1 OS upgrade completed. Ubuntu 24.04 validation passed. DP Python/Py3 upgrade was not evaluated or executed."
    exit "$EXIT_COMPLETED"
  fi

  # Refuse auto-continue from CHECKPOINT without new preflight
  if [[ "${ST_STATE}" == "CHECKPOINT_REACHED" ]]; then
    osu_log INFO "CHECKPOINT_REACHED — runner no-op; recollect and repreflight required"
    exit "${EXIT_CHECKPOINT:-41}"
  fi

  local line from_ver from_code to_ver to_code hop_num rest
  local -a hop_lines=()
  mapfile -t hop_lines < <(osu_plan_hops "$cur" || true)
  line="${hop_lines[0]:-}"
  if [[ -z "$line" || "$line" == UNSUPPORTED ]]; then
    osu_set_failed "cannot_plan_next_hop_from_${cur}"
    exit "$EXIT_FAILED"
  fi
  from_ver="${line%%:*}"
  rest="${line#*:}"
  from_code="${rest%%->*}"
  rest="${rest#*>}"
  to_ver="${rest%%:*}"
  to_code="${rest##*:}"

  hop_num=$(( ${ST_CURRENT_HOP:-0} + 1 ))
  if [[ "$from_ver" != "$cur" ]]; then
    osu_set_failed "lts_skip_rejected"
    exit "$EXIT_FAILED"
  fi

  # Discovery/production hop-limit before starting another hop when already at limit
  if declare -F osu_should_checkpoint_after_hop >/dev/null 2>&1; then
    # If max hops already reached before starting, checkpoint
    if [[ -n "${ST_MAX_HOPS:-}" && "${ST_HOPS_THIS_RUN:-0}" -ge "${ST_MAX_HOPS}" ]]; then
      ST_CHECKPOINT_REASON="max_hops_${ST_MAX_HOPS}"
      runner_enter_checkpoint
    fi
  fi

  if osu_honor_pause_boundary; then exit "$EXIT_PAUSED"; fi
  runner_execute_hop "$hop_num" "$from_ver" "$from_code" "$to_ver" "$to_code"
}

main() {
  if ! osu_acquire_lock; then
    osu_log ERROR "unable to acquire lock"
    exit "$EXIT_INTEGRITY"
  fi
  trap 'osu_release_lock' EXIT

  runner_init_state

  case "$ST_STATE" in
    COMPLETED)
      osu_log INFO "COMPLETED — runner no-op; Phase 2 not executed"
      exit "$EXIT_COMPLETED"
      ;;
    CHECKPOINT_REACHED)
      osu_log INFO "CHECKPOINT_REACHED — runner no-op; new preflight required"
      exit "${EXIT_CHECKPOINT:-41}"
      ;;
    FAILED)
      osu_log ERROR "FAILED — refusing automatic run"
      exit "$EXIT_FAILED"
      ;;
    PAUSED)
      osu_log ERROR "PAUSED"
      exit "$EXIT_PAUSED"
      ;;
    BLOCKED)
      if [[ "$ST_RETRYABLE" != "true" || "$MODE" != "retry" ]]; then
        if [[ "$MODE" != "resume" || "$ST_RETRYABLE" != "true" ]]; then
          osu_log ERROR "BLOCKED (retryable=${ST_RETRYABLE})"
          exit "$EXIT_BLOCKED"
        fi
      fi
      # retryable resume: go back to hop precheck
      osu_transition_state HOP_PRECHECK "retry_from_blocked" || true
      ;;
  esac

  if osu_pause_active; then
    osu_transition_state PAUSED "pause_marker" || true
    exit "$EXIT_PAUSED"
  fi

  case "$ST_STATE" in
    REBOOT_REQUESTED|REBOOT_REQUIRED)
      runner_handle_reboot_resume || exit "$EXIT_FAILED"
      ;;
  esac

  case "$ST_STATE" in
    INITIALIZED|HOP_COMPLETED|RESUMED|HOP_PRECHECK|PREFLIGHT_ACCEPTED)
      runner_next_hop_or_complete
      # Loop remaining hops in test mode
      while [[ "$(osu_current_os_version)" != "$POLICY_TARGET_OS_VERSION" ]]; do
        case "$(osu_read_state_field current_state)" in
          HOP_COMPLETED|RESUMED|INITIALIZED) ;;
          COMPLETED) break ;;
          CHECKPOINT_REACHED) exit "${EXIT_CHECKPOINT:-41}" ;;
          PAUSED) exit "$EXIT_PAUSED" ;;
          BLOCKED) exit "$EXIT_BLOCKED" ;;
          FAILED) exit "$EXIT_FAILED" ;;
          REBOOT_REQUESTED|REBOOT_REQUIRED)
            if [[ "$OSU_TEST_MODE" -eq 1 ]]; then
              osu_load_state_into_vars
              runner_handle_reboot_resume || exit "$EXIT_FAILED"
            else
              exit "$EXIT_RESUME_REQUIRED"
            fi
            ;;
          *) break ;;
        esac
        osu_load_state_into_vars
        runner_next_hop_or_complete || break
      done
      osu_load_state_into_vars
      if [[ "$(osu_current_os_version)" == "$POLICY_TARGET_OS_VERSION" && "$ST_STATE" != "COMPLETED" ]]; then
        osu_transition_state COMPLETED "phase1_completed"
        osu_generate_reports
      fi
      ;;
    HOP_SOURCE_PREPARING|HOP_SOURCE_READY|HOP_CURRENT_RELEASE_UPDATING|HOP_RELEASE_UPGRADE_STARTING|HOP_RELEASE_UPGRADE_RUNNING|HOP_VALIDATING)
      # Resume mid-hop carefully — re-enter execute with current hop targets
      if [[ -z "${ST_TARGET_OS:-}" ]]; then
        runner_next_hop_or_complete
      else
        runner_execute_hop "$ST_CURRENT_HOP" "$ST_CURRENT_OS" "$ST_CURRENT_CODENAME" "$ST_TARGET_OS" "$ST_TARGET_CODENAME"
      fi
      ;;
    *)
      osu_log ERROR "runner refused for state=$ST_STATE"
      exit "$EXIT_BLOCKED"
      ;;
  esac

  osu_load_state_into_vars || true
  case "$ST_STATE" in
    COMPLETED) exit "$EXIT_COMPLETED" ;;
    CHECKPOINT_REACHED) exit "${EXIT_CHECKPOINT:-41}" ;;
    PAUSED) exit "$EXIT_PAUSED" ;;
    BLOCKED) exit "$EXIT_BLOCKED" ;;
    FAILED) exit "$EXIT_FAILED" ;;
    REBOOT_REQUESTED|REBOOT_REQUIRED) exit "$EXIT_RESUME_REQUIRED" ;;
    *) exit 0 ;;
  esac
}

main "$@"
