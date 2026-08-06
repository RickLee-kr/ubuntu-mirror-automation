#!/usr/bin/env bash
# Verify Menu 7 display-only wrapping for normal-width terminals, including
# the complete Phase 2 script + helper-library executable unit.
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
FORMAT_LOG="${TMP}/format.log"

{
  cat <<'EOF_HEADER'
DP Client Upgrade Commands
==========================

DP_COMMAND_BLOCK_VERSION=SUBSHELL_V2
DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1

OS-hop steps use one hash-pinned launcher command per hop (DP_OS_HOP_COMMAND_VERSION=LAUNCHER_V1).
The Phase 2 staging step remains a three-line SUBSHELL_V2 block.
EOF_HEADER
  for hop in "${HOPS[@]}"; do
    launcher="dp-launch-${hop}.sh"
    cat <<EOF_HOP

STEP — ${hop}

Copy and paste the following entire line into the DP terminal:

cd /home/aella && curl -fsSLo ${launcher}.download ${MIRROR}/client/${launcher} && printf '%s  %s\\n' '${SHA}' '${launcher}.download' | sha256sum -c - && mv -f ${launcher}.download ${launcher} && bash ./${launcher}
EOF_HOP
  done
  cat <<EOF_PHASE2

STEP 6 — STAGE DP 6.5.0 FILES

Copy all three lines of the following block into the DP terminal once:

( [[ \${BASH_SUBSHELL:-0} -gt 0 ]] || { printf '%s\n' 'DP_COMMAND_SUBSHELL_REQUIRED=YES' >&2; exit 97; }; cd /home/aella && MIRROR='${MIRROR}' && VER='6.5.0' && SCRIPT='stage-dp-phase2.sh' && W=\$(mktemp -d)&&trap 'rm -rf "\$W"' EXIT&&cd "\$W" && \\
curl -fsSLo "\$SCRIPT" "\$MIRROR/client/\$SCRIPT" && curl -fsSLo "\$SCRIPT.sha256" "\$MIRROR/client/\$SCRIPT.sha256" && test -s "\$SCRIPT" && test -s "\$SCRIPT.sha256" && \\
sha256sum -c "\$SCRIPT.sha256" && { sudo bash "./\$SCRIPT" --target-version "\$VER" --same-version-recovery --mirror-url "\$MIRROR"; })
EOF_PHASE2
} >"$CANONICAL"

canonical_before="$(sha256sum "$CANONICAL" | awk '{print $1}')"
bash "$WRAPPER" --format-menu7 "$CANONICAL" "$DISPLAY" 2>"$FORMAT_LOG"
canonical_after="$(sha256sum "$CANONICAL" | awk '{print $1}')"
[[ "$canonical_before" == "$canonical_after" ]]

grep -q 'MENU7_DISPLAY_FORMAT=PASS wrapped_launchers=4 wrapped_phase2=1' "$FORMAT_LOG"
grep -q 'Copy and paste all three physical lines below into the DP terminal.' "$DISPLAY"
[[ "$(grep -c '^cd /home/aella && L=' "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c '^  U=' "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c "^  printf '%s  %s" "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c '^( C=' "$DISPLAY")" -eq 1 ]]
[[ "$(grep -c 'They download the Phase 2 script and both required helper libraries together.' "$DISPLAY")" -eq 1 ]]

grep -Fq 'lib/dp-offline-source-product-version.sh' "$DISPLAY"
grep -Fq 'lib/dp-phase2-operation-progress.sh' "$DISPLAY"
grep -Fq -- "--target-version '6.5.0' --same-version-recovery" "$DISPLAY"
grep -Fq 'sha256sum -c "$S.sha256"' "$DISPLAY"

max_line="$(awk '{ if (length > max) max=length } END { print max+0 }' "$DISPLAY")"
[[ "$max_line" -le 180 ]]

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

phase2_block="${TMP}/phase2.sh"
awk '
  /^\( C=/ { p=1; n=0 }
  p { print; n++ }
  p && n==3 { exit }
' "$DISPLAY" >"$phase2_block"
[[ "$(wc -l <"$phase2_block" | tr -d ' ')" -eq 3 ]]
[[ "$(grep -c '\\$' "$phase2_block")" -eq 2 ]]
! grep -Eq 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$phase2_block"
bash -n "$phase2_block"

echo "MENU7_NORMAL_WIDTH_DISPLAY=PASS"
