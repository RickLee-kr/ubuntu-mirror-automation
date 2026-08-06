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
pat = re.compile(
    r"^cd /home/aella && curl -fsSLo "
    r"(?P<launcher>dp-launch-[a-z0-9-]+\.sh)\.download "
    r"(?P<url>\S+) && printf '%s  %s\\n' "
    r"'(?P<sha>[0-9A-Fa-f]{64})' "
    r"'(?P=launcher)\.download' \| sha256sum -c - && "
    r"mv -f (?P=launcher)\.download (?P=launcher) && "
    r"bash \./(?P=launcher)$"
)

guidance = "Copy and paste the following entire line into the DP terminal:"
replacement_guidance = [
    "Copy and paste all three physical lines below into the DP terminal.",
    "The first two lines end with a backslash (\\).",
]

lines = src.read_text(encoding="utf-8").splitlines()
out: list[str] = []
wrapped = 0
for line in lines:
    m = pat.match(line)
    if not m:
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
        continue

    # Replace only the guidance immediately preceding an OS-hop launcher. Other
    # one-line commands (prerequisite checks and bringup) keep their own wording.
    for idx in range(len(out) - 1, max(-1, len(out) - 8), -1):
        if out[idx] == guidance:
            out[idx : idx + 1] = replacement_guidance
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

    # Three physical lines, one logical Bash command. The literal SHA256 remains
    # the operator trust anchor; no HTTP sidecar and no curl|bash are introduced.
    out.extend(
        [
            f"cd /home/aella && L='{launcher}' && D=\"$L.download\" && \\",
            f"  U='{mirror}' && H='{sha}' && curl -fsSLo \"$D\" \"$U/client/$L\" && \\",
            "  printf '%s  %s\\n' \"$H\" \"$D\" | sha256sum -c - && "
            "mv -f \"$D\" \"$L\" && bash \"./$L\"",
        ]
    )
    wrapped += 1

if wrapped not in (0, 4):
    raise SystemExit(f"MENU7_DISPLAY_FORMAT=FAIL reason=unexpected_launcher_count count={wrapped}")

dst.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"MENU7_DISPLAY_FORMAT=PASS wrapped_launchers={wrapped}", file=sys.stderr)
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
