#!/usr/bin/env bash
# Verify Menu 7 display-only wrapping for normal-width terminals.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MIRROR="http://192.0.2.55"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HOPS=(xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble)
CANONICAL="${TMP}/canonical.txt"
DISPLAY="${TMP}/display.txt"

{
  cat <<'EOF'
DP Client Upgrade Commands
==========================

DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2
DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1

OS-hop steps use one hash-pinned launcher command per hop (DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1).
The Phase 2 staging step remains a three-line SUBSHELL_V2 block.
EOF
  for hop in "${HOPS[@]}"; do
    launcher="dp-launch-${hop}.sh"
    cat <<EOF

STEP — ${hop}

Copy and paste the following entire line into the DP terminal:

cd /home/aella && curl -fsSLo ${launcher}.download ${MIRROR}/client/${launcher} && printf '%s  %s\\n' '${SHA}' '${launcher}.download' | sha256sum -c - && mv -f ${launcher}.download ${launcher} && bash ./${launcher}
EOF
  done
  cat <<'EOF'

STEP 6 — STAGE DP 6.5.0 FILES

Copy all three lines of the following block into the DP terminal once:

( [[ ${BASH_SUBSHELL:-0} -gt 0 ]] || exit 97; cd /home/aella && \
  true && \
  sudo bash ./stage-dp-phase2.sh --target-version 6.5.0 )
EOF
} >"$CANONICAL"

canonical_before="$(sha256sum "$CANONICAL" | awk '{print $1}')"
bash "$WRAPPER" --format-menu7 "$CANONICAL" "$DISPLAY"
canonical_after="$(sha256sum "$CANONICAL" | awk '{print $1}')"
[[ "$canonical_before" == "$canonical_after" ]]

grep -q 'Copy and paste all three physical lines below into the DP terminal.' "$DISPLAY"
[[ "$(grep -c '^cd /home/aella && L=' "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c '^  U=' "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c "^  printf '%s  %s" "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c 'Copy all three lines of the following block' "$DISPLAY")" -eq 1 ]]

max_line="$(awk '{ if (length > max) max=length } END { print max+0 }' "$DISPLAY")"
[[ "$max_line" -le 140 ]]

for hop in "${HOPS[@]}"; do
  block="${TMP}/${hop}.sh"
  awk -v name="dp-launch-${hop}.sh" '
    index($0, "L=\047" name "\047") { p=1; n=0 }
    p { print; n++ }
    p && n==3 { exit }
  ' "$DISPLAY" >"$block"
  [[ "$(wc -l <"$block" | tr -d ' ')" -eq 3 ]]
  [[ "$(grep -c '\\$' "$block")" -eq 2 ]]
  grep -Fq "H='${SHA}'" "$block"
  grep -Fq 'sha256sum -c - && mv -f "$D" "$L" && bash "./$L"' "$block"
  ! grep -Eq 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)|\.sha256' "$block"
  bash -n "$block"
done

echo "MENU7_NORMAL_WIDTH_DISPLAY=PASS"
