#!/usr/bin/env bash
# Installed CLI entrypoint. Delegates all normal commands to the authoritative
# runtime and applies a display-only Menu 7 formatter for normal-width SSH
# terminals. The canonical generated command file remains unchanged.
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
    "Copy and paste all three physical lines below into the DP terminal.",
    "They download the Phase 2 script and both required helper libraries together.",
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

    # Canonical SUBSHELL_V2 Phase 2 block is three physical lines. The stage
    # script now depends on two files under client/lib, so the viewer must fetch
    # the complete executable unit into the same temporary directory.
    if (
        i + 2 < len(lines)
        and line.startswith("( [[ ${BASH_SUBSHELL:-0} -gt 0 ]]")
        and "SCRIPT='stage-dp-phase2.sh'" in line
        and "$MIRROR/client/$SCRIPT" in lines[i + 1]
        and 'sha256sum -c "$SCRIPT.sha256"' in lines[i + 2]
        and 'sudo bash "./$SCRIPT"' in lines[i + 2]
    ):
        mirror_match = re.search(r"MIRROR='([^']+)'", line)
        version_match = re.search(r"VER='([^']+)'", line)
        script_match = re.search(r"SCRIPT='([^']+)'", line)
        if not (mirror_match and version_match and script_match):
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=phase2_parse")
        mirror = mirror_match.group(1).rstrip("/")
        version = version_match.group(1)
        script = script_match.group(1)
        if script != "stage-dp-phase2.sh" or not mirror:
            raise SystemExit("MENU7_DISPLAY_FORMAT=FAIL reason=phase2_shape")
        same_version = " --same-version-recovery" if "--same-version-recovery" in lines[i + 2] else ""

        for idx in range(len(out) - 1, max(-1, len(out) - 8), -1):
            if out[idx] == phase2_guidance:
                out[idx : idx + 1] = phase2_replacement_guidance
                break

        client_base = f"{mirror}/client"
        out.extend(
            [
                f"( C='{client_base}' S='{script}' W=$(mktemp -d); trap 'rm -rf \"$W\"' EXIT; cd \"$W\" && mkdir lib && \\",
                "  curl --create-dirs -fsSLo '#1' \"$C/{stage-dp-phase2.sh,stage-dp-phase2.sh.sha256,lib/dp-offline-source-product-version.sh,lib/dp-phase2-operation-progress.sh}\" && \\",
                f"  sha256sum -c \"$S.sha256\" && sudo bash \"./$S\" --target-version '{version}'{same_version} --mirror-url \"${{C%/client}}\" )",
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
