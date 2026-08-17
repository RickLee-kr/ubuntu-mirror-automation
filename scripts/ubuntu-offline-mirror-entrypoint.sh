#!/usr/bin/env bash
# Installed CLI entrypoint. Delegates all normal commands to the authoritative
# runtime and applies display/status compatibility fixes for operator workflows.
# Canonical generated command files and artifact trust decisions remain unchanged.
set -euo pipefail
set +x

UOM_RUNTIME_ROOT="${UOM_RUNTIME_ROOT:-/usr/local/lib/ubuntu-mirror}"
UOM_CORE_ENTRY="${UOM_CORE_ENTRY:-${UOM_RUNTIME_ROOT}/scripts/ubuntu-offline-mirror.sh}"
UOM_MANAGER_ENTRY="${UOM_MANAGER_ENTRY:-${UOM_RUNTIME_ROOT}/scripts/install-dp-upgrade-mirror.sh}"

uom_format_menu7_file() {
  local input="$1" output="$2"
  [[ -f "$input" ]] || {
    printf 'MENU7_DISPLAY_FORMAT=FAIL reason=input_missing path=%s\n' "$input" >&2
    return 1
  }

  python3 - "$input" "$output" <<'PY'
from pathlib import Path
import re
import sys

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

# Canonical LAUNCHER_V1 command written by gui_client_hop_command_line().
# The formatter changes presentation only; it does not change the saved command
# file or any trust decision.
hop_pat = re.compile(
    r"^cd /home/aella && curl -fsSLo "
    r"(?P<launcher>dp-launch-[a-z0-9-]+\.sh)\.download "
    r"(?P<url>\S+) && printf '%s  %s\\n' "
    r"'(?P<sha>[0-9A-Fa-f]{64})' "
    r"'(?P=launcher)\.download' \| sha256sum -c - && "
    r"mv -f (?P=launcher)\.download (?P=launcher) && "
    r"bash \./(?P=launcher)$"
)

hop_guidance = "Copy and paste the following entire line into the DP terminal:"
hop_replacement_guidance = [
    "Copy and paste all three physical lines below into the DP terminal.",
    "The first two lines end with a backslash (\\).",
]
phase2_guidance = "Copy all three lines of the following block into the DP terminal once:"
phase2_replacement_guidance = [
    "Copy and paste all five physical lines below into the DP terminal.",
    "The command downloads the complete Phase 2 client helper unit",
    "(generation manifest, stage script, lifecycle wrapper, and required lib helpers).",
]

lines = src.read_text(encoding="utf-8").splitlines()
out: list[str] = []
hop_wrapped = 0
phase2_wrapped = 0
i = 0
while i < len(lines):
    line = lines[i]
    m = hop_pat.match(line)
    if m:
        # Replace only the guidance immediately preceding an OS-hop launcher.
        for idx in range(len(out) - 1, max(-1, len(out) - 8), -1):
            if out[idx] == hop_guidance:
                out[idx : idx + 1] = hop_replacement_guidance
                break

        launcher = m.group("launcher")
        url = m.group("url")
        sha = m.group("sha").lower()
        suffix = f"/client/{launcher}"
        if not url.endswith(suffix):
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=launcher_url_shape")
        mirror = url[: -len(suffix)].rstrip("/")
        if not mirror:
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=mirror_url_empty")

        # Three physical lines, one logical Bash command. The literal SHA256
        # remains the operator trust anchor; no sidecar trust and no curl|bash.
        out.extend(
            [
                f"cd /home/aella && L='{launcher}' && D=\"$L.download\" && \\",
                f"  U='{mirror}' && H='{sha}' && curl -fsSLo \"$D\" \"$U/client/$L\" && \\",
                "  printf '%s  %s\\n' \"$H\" \"$D\" | sha256sum -c - && "
                "mv -f \"$D\" \"$L\" && bash \"./$L\"",
            ]
        )
        hop_wrapped += 1
        i += 1
        continue

    # Canonical SUBSHELL_V2 Phase 2 block: download the complete helper unit and
    # pin the generation manifest SHA256 (not an HTTP sidecar).
    if (
        i + 2 < len(lines)
        and line.startswith("( [[ ${BASH_SUBSHELL:-0} -gt 0 ]]")
        and "SCRIPT='stage-dp-phase2.sh'" in line
        and "GEN='phase2-helper-generation.manifest'" in line
        and "H='" in line
        and "$MIRROR/client/$F" in lines[i + 1]
        and 'sha256sum -c -' in lines[i + 2]
        and 'sudo bash "./$SCRIPT"' in lines[i + 2]
    ):
        mirror_match = re.search(r"MIRROR='([^']+)'", line)
        version_match = re.search(r"VER='([^']+)'", line)
        script_match = re.search(r"SCRIPT='([^']+)'", line)
        gen_match = re.search(r"GEN='([^']+)'", line)
        hash_match = re.search(r"H='([0-9a-fA-F]{64}|MISSING_PHASE2_HELPER_GENERATION_SHA256)'", line)
        if not (mirror_match and version_match and script_match and gen_match and hash_match):
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=phase2_parse")
        mirror = mirror_match.group(1).rstrip("/")
        version = version_match.group(1)
        script = script_match.group(1)
        gen = gen_match.group(1)
        sha = hash_match.group(1)
        if script != "stage-dp-phase2.sh" or gen != "phase2-helper-generation.manifest" or not mirror:
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=phase2_shape")
        same_version = " --same-version-recovery" if "--same-version-recovery" in lines[i + 2] else ""

        for idx in range(len(out) - 1, max(-1, len(out) - 8), -1):
            if out[idx] == phase2_guidance:
                out[idx : idx + 1] = phase2_replacement_guidance
                break

        client_base = f"{mirror}/client"
        # Five physical lines, one logical Bash command. Literal H is the trust
        # anchor; sha256sum -c of the manifest then binds every helper.
        out.extend(
            [
                f"( C='{client_base}' S='{script}' G='{gen}' && \\",
                f"  H='{sha}' V='{version}' W=$(mktemp -d); trap 'rm -rf \"$W\"' EXIT; cd \"$W\" && \\",
                "  mkdir -p lib && for F in \"$G\" \"$S\" bringup_py3_dp_lifecycle.sh \\",
                "    lib/dp-{offline-source-product-version,phase2-operation-progress,phase2-bringup-lifecycle,phase2-ubuntu-prerequisites}.sh; do curl -fsSLo \"$F\" \"$C/$F\" || exit; done && \\",
                f"  printf '%s  %s\\n' \"$H\" \"$G\" | sha256sum -c - && sha256sum -c \"$G\" && sudo bash \"./$S\" --target-version '{version}'{same_version} --mirror-url \"${{C%/client}}\" )",
            ]
        )
        phase2_wrapped += 1
        i += 3
        continue

    if line == (
        "OS-hop steps use one hash-pinned launcher command per hop "
        "(DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1)."
    ):
        out.extend(
            [
                "OS-hop steps use one hash-pinned launcher command per hop",
                "(DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1), displayed as three physical lines",
                "for normal-width terminals. Copy all three lines together.",
            ]
        )
    else:
        out.append(line)
    i += 1

if hop_wrapped not in (0, 4):
    raise SystemExit(
        f"MENU7_DISPLAY_FORMAT=FAIL reason=unexpected_launcher_count count={hop_wrapped}"
    )
if phase2_wrapped not in (0, 1):
    raise SystemExit(
        f"MENU7_DISPLAY_FORMAT=FAIL reason=unexpected_phase2_count count={phase2_wrapped}"
    )

dst.write_text("\n".join(out) + "\n", encoding="utf-8")
print(
    f"MENU7_DISPLAY_FORMAT=PASS wrapped_launchers={hop_wrapped} "
    f"wrapped_phase2={phase2_wrapped}",
    file=sys.stderr,
)
PY
}

# Artifact status values written by a successful reuse path are semantically
# equivalent to PASS. Keep the accepted set deliberately narrow: FAIL, blank,
# and unknown values must continue to fail closed.
uom_status_success() {
  case "${1:-}" in
    PASS|REUSED) return 0 ;;
    *) return 1 ;;
  esac
}

# Independent, cheap status checks used by the status screen. These avoid the
# old all-or-nothing MM_WF_DOWNLOAD_COMPLETED coupling, where one OS status
# mismatch incorrectly made the Phase 2 bundle appear NOT READY (and vice versa).
uom_os_upgrade_files_completed() {
  mm_configuration_completed || return 1
  mm_is_phase2_only && return 0
  engine_resolve_paths 2>/dev/null || true
  [[ -d "${MM_SELECTIVE_ROOT}/ubuntu" || -L "${MM_SELECTIVE_ROOT}/ubuntu" ]] || return 1
  uom_status_success "$(mm_status_get OS_MIRROR_READY)" || return 1
  uom_status_success "$(mm_status_get R2_OS_CORE_CHECKSUM)" || return 1
  mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
  mm_client_set_current_source "${MM_CLIENT_ROOT}" >/dev/null 2>&1 || return 1
  return 0
}

uom_phase2_bundle_completed() {
  local bundle_ck entries
  mm_configuration_completed || return 1
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  [[ -f "${MM_WF_PHASE2_RELEASE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_BUNDLE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_SIDECAR}" ]] || return 1
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  entries="$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT)"
  uom_status_success "$bundle_ck" || return 1
  [[ "$entries" == "9" ]] || return 1
  mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
  return 0
}

# Replacement for the runtime's mm_download_completed(). The original accepted
# only the literal value PASS for R2_OS_CORE_CHECKSUM, while successful reuse is
# intentionally recorded as REUSED. That produced a false NOT READY dashboard
# after snapshot restore/reinstall even though readiness and all generations
# had passed. Preserve every other validation and fail-closed condition.
uom_mm_download_completed() {
  local stored_fp current_fp entries bundle_ck os_ready
  mm_configuration_completed || return 1
  engine_resolve_paths 2>/dev/null || true
  mm_phase2_paths
  [[ -f "${MM_WF_PHASE2_RELEASE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_BUNDLE}" ]] || return 1
  [[ -f "${MM_WF_PHASE2_SIDECAR}" ]] || return 1
  bundle_ck="$(mm_status_get PHASE2_BUNDLE_CHECKSUM)"
  entries="$(mm_status_get PHASE2_BUNDLE_ENTRY_COUNT)"
  uom_status_success "$bundle_ck" || return 1
  [[ "$entries" == "9" ]] || return 1
  if mm_is_phase2_only; then
    mm_client_files_ready_phase2 "${MM_CLIENT_ROOT}" || return 1
  else
    [[ -d "${MM_SELECTIVE_ROOT}/ubuntu" || -L "${MM_SELECTIVE_ROOT}/ubuntu" ]] || return 1
    os_ready="$(mm_status_get OS_MIRROR_READY)"
    uom_status_success "$os_ready" || return 1
    uom_status_success "$(mm_status_get R2_OS_CORE_CHECKSUM)" || return 1
    mm_client_files_ready "${MM_CLIENT_ROOT}" || return 1
    mm_client_set_current_source "${MM_CLIENT_ROOT}" >/dev/null 2>&1 || return 1
  fi
  if ! uom_status_success "$(mm_status_get DOWNLOAD_PREPARE_RESULT)" \
    && ! uom_status_success "$(mm_status_get LAST_EXECUTION_RESULT)" \
    && ! uom_status_success "$(mm_status_get INSTALL_RESULT)"; then
    return 1
  fi
  if mm_temps_present; then
    return 1
  fi
  current_fp="$(mm_artifact_fingerprint)"
  stored_fp="$(mm_status_get DOWNLOAD_ARTIFACT_FINGERPRINT)"
  if [[ -z "$stored_fp" ]]; then
    mm_status_set DOWNLOAD_ARTIFACT_FINGERPRINT "$current_fp"
    mm_status_set DOWNLOAD_PREPARE_RESULT PASS
    mm_status_set DOWNLOAD_VALIDATED_AT "$(mm_ts)"
    mm_status_set PHASE2_BUNDLE_SIZE "$(mm_file_bytes "${MM_WF_PHASE2_BUNDLE}")"
    mm_status_set PHASE2_BUNDLE_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_BUNDLE}" 2>/dev/null || echo 0)"
    mm_status_set PHASE2_SIDECAR_MTIME "$(stat -c '%Y' "${MM_WF_PHASE2_SIDECAR}" 2>/dev/null || echo 0)"
    return 0
  fi
  [[ "$stored_fp" == "$current_fp" ]] || return 1
  return 0
}

# Replacement for gui_show_status(): compute OS Core and Phase 2 readiness
# independently, while the overall progress/readiness still uses the generation-
# bound workflow contract through mm_collect_workflow_status().
uom_gui_show_status() {
  load_mirror_defaults
  mm_load_gui_config
  mm_normalize_preparation_mode
  mm_force_phase2_target
  engine_resolve_paths
  local tmp ver config_state os_state bundle_state http_state ready_state start_os final_os
  ver="${PHASE2_TARGET_VERSION}"
  mm_collect_workflow_status
  if [[ "${MM_WF_CONFIG_COMPLETED}" == "1" ]]; then
    config_state="PASS"
  else
    config_state="FAIL"
  fi
  if mm_is_phase2_only; then
    start_os="Ubuntu 24.04"
    final_os="Ubuntu 24.04"
    os_state="NOT REQUIRED"
  else
    start_os="Ubuntu 16.04"
    final_os="Ubuntu 24.04"
    if uom_os_upgrade_files_completed; then
      os_state="READY"
    else
      os_state="NOT READY"
    fi
  fi
  if uom_phase2_bundle_completed; then
    bundle_state="READY (9 files)"
  else
    bundle_state="NOT READY"
  fi
  if [[ "${MM_WF_HTTP_COMPLETED}" == "1" ]]; then
    http_state="ENABLED"
  else
    http_state="$(mm_status_get HTTP_DISTRIBUTION)"
    [[ -n "$http_state" ]] || http_state="DISABLED"
    [[ "$http_state" == "ENABLED" ]] || http_state="DISABLED"
  fi
  ready_state="$(mm_upgrade_readiness_display)"
  [[ -n "$ready_state" ]] || ready_state="NOT VERIFIED"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF_STATUS
DP Upgrade Mirror Status
========================

Supported Starting DP Versions: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target: ${ver}
Preparation Mode: $(mm_preparation_mode_label)
Starting OS: ${start_os}
Final OS: ${final_os}
Configuration: ${config_state}
OS Upgrade Files: ${os_state}
DP ${ver} Bundle: ${bundle_state}
HTTP Distribution: ${http_state}
Upgrade Readiness: ${ready_state}
Last Operation: $(mm_status_get LAST_EXECUTION_RESULT)
Log File: $(mm_status_get LOG_PATH)

$(mm_workflow_progress_text)
EOF_STATUS
  mm_whiptail_textbox "Current Status" "$tmp" || true
  rm -f "$tmp"
  return 0
}

uom_install_status_overrides() {
  eval "$(
    declare -f uom_mm_download_completed \
      | sed '1s/^uom_mm_download_completed[[:space:]]*()/mm_download_completed ()/'
  )"
  eval "$(
    declare -f uom_gui_show_status \
      | sed '1s/^uom_gui_show_status[[:space:]]*()/gui_show_status ()/'
  )"
}

uom_run_mirror_manager() {
  [[ -f "$UOM_MANAGER_ENTRY" ]] || {
    printf 'ERROR: Mirror Manager runtime is missing: %s\n' "$UOM_MANAGER_ENTRY" >&2
    exit 1
  }

  local manager_dir manager_lib
  manager_dir="$(cd "$(dirname "$UOM_MANAGER_ENTRY")" && pwd)"
  manager_lib="$(mktemp /tmp/ubuntu-mirror-manager-lib.XXXXXX.sh)"
  trap 'rm -f "${manager_lib:-}"' EXIT

  # Source the installed manager as a library. Pin SCRIPT_DIR to its installed
  # location so its relative library imports remain authoritative.
  awk -v sd="$manager_dir" '
    /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
    /^main "\$@"$/ { next }
    { print }
  ' "$UOM_MANAGER_ENTRY" >"$manager_lib"
  # shellcheck source=/dev/null
  source "$manager_lib"
  rm -f "$manager_lib"
  manager_lib=""

  uom_install_status_overrides

  if ! declare -F mm_menu7_textbox >/dev/null 2>&1; then
    printf 'ERROR: Menu 7 viewer function is unavailable in installed runtime.\n' >&2
    exit 1
  fi

  # Preserve the core viewer and override only its input presentation.
  eval "$(
    declare -f mm_menu7_textbox \
      | sed '1s/^mm_menu7_textbox[[:space:]]*()/_uom_core_menu7_textbox ()/'
  )"

  mm_menu7_textbox() {
    local title="$1" canonical="$2" display rc=0
    display="$(mktemp /tmp/dp-client-upgrade-commands-display.XXXXXX.txt)"
    if uom_format_menu7_file "$canonical" "$display"; then
      _uom_core_menu7_textbox "$title" "$display" || rc=$?
    else
      rm -f "$display"
      return 1
    fi
    rm -f "$display"
    return "$rc"
  }

  main "$@"
}

uom_main() {
  case "${1:-mirror-manager}" in
    --format-menu7)
      [[ $# -eq 3 ]] || {
        printf 'Usage: %s --format-menu7 INPUT OUTPUT\n' "$0" >&2
        exit 2
      }
      uom_format_menu7_file "$2" "$3"
      ;;
    mirror-manager|install-menu)
      uom_run_mirror_manager "$@"
      ;;
    *)
      [[ -x "$UOM_CORE_ENTRY" || -f "$UOM_CORE_ENTRY" ]] || {
        printf 'ERROR: Core runtime entrypoint is missing: %s\n' "$UOM_CORE_ENTRY" >&2
        exit 1
      }
      exec bash "$UOM_CORE_ENTRY" "$@"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  uom_main "$@"
fi
