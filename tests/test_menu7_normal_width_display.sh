#!/usr/bin/env bash
# Verify Menu 7 display-only wrapping for normal-width terminals, including a
# real loopback fetch of the complete Phase 2 client helper unit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${ROOT}/scripts/ubuntu-offline-mirror-entrypoint.sh"
TMP="$(mktemp -d)"
HTTP_PID=""
cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
    wait "$HTTP_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
MIRROR="http://127.0.0.1:${PORT}"
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

CLUSTER:
Run STEP 6 on the DL master, every DL worker,
the DA master, and every DA worker.

Complete STEP 6 on ALL cluster nodes before starting STEP 7.

Use the SAME staging command on every node.

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
grep -q 'Copy and paste all four physical lines below into the DP terminal.' "$DISPLAY"
grep -q 'complete Phase 2 client helper unit' "$DISPLAY"
grep -Fq 'CLUSTER:' "$DISPLAY"
grep -Fq 'Run STEP 6 on the DL master, every DL worker,' "$DISPLAY"
grep -Fq 'Complete STEP 6 on ALL cluster nodes before starting STEP 7.' "$DISPLAY"
grep -Fq 'Use the SAME staging command on every node.' "$DISPLAY"
[[ "$(grep -c '^cd /home/aella && L=' "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c '^  U=' "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c "^  printf '%s  %s" "$DISPLAY")" -eq 4 ]]
[[ "$(grep -c '^( C=' "$DISPLAY")" -eq 1 ]]

grep -Fq 'bringup_py3_dp_lifecycle.sh' "$DISPLAY"
grep -Fq 'lib/dp-{offline-source-product-version,phase2-operation-progress,phase2-bringup-lifecycle}.sh' "$DISPLAY"
grep -Fq 'curl -fsSLo "$F" "$C/$F"' "$DISPLAY"
grep -Fq -- "--target-version '6.5.0' --same-version-recovery" "$DISPLAY"
grep -Fq 'sha256sum -c "$S.sha256"' "$DISPLAY"
! grep -Fq -- "--create-dirs -fsSLo '#1'" "$DISPLAY"
! grep -Eq 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$DISPLAY"
# No whitespace after line-continuation backslashes.
! grep -Eq '\\[[:space:]]+$' "$DISPLAY"

max_line="$(awk '{ if (length > max) max=length } END { print max+0 }' "$DISPLAY")"
[[ "$max_line" -le 190 ]]

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
  p && n==4 { exit }
' "$DISPLAY" >"$phase2_block"
[[ "$(wc -l <"$phase2_block" | tr -d ' ')" -eq 4 ]]
[[ "$(grep -c '\\$' "$phase2_block")" -eq 3 ]]
! grep -Eq 'curl[^|;]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$phase2_block"
! grep -Eq '\\[[:space:]]+$' "$phase2_block"
bash -n "$phase2_block"

# Hermetic end-to-end check of the exact displayed Phase 2 command.
HTTP_ROOT="${TMP}/http"
CLIENT_ROOT="${HTTP_ROOT}/client"
mkdir -p "${CLIENT_ROOT}/lib" "${TMP}/fakebin"
cat >"${CLIENT_ROOT}/stage-dp-phase2.sh" <<'STAGE'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for req in \
  lib/dp-offline-source-product-version.sh \
  lib/dp-phase2-operation-progress.sh \
  lib/dp-phase2-bringup-lifecycle.sh \
  bringup_py3_dp_lifecycle.sh
do
  [[ -s "${here}/${req}" ]] || { printf 'MISSING=%s\n' "$req"; exit 1; }
done
source "${here}/lib/dp-offline-source-product-version.sh"
source "${here}/lib/dp-phase2-operation-progress.sh"
printf 'PHASE2_HELPER_FETCH_E2E=PASS\n'
printf 'PHASE2_STUB_ARGS=%s\n' "$*"
STAGE
cat >"${CLIENT_ROOT}/lib/dp-offline-source-product-version.sh" <<'HELPER1'
#!/usr/bin/env bash
SOURCE_HELPER_LOADED=YES
HELPER1
cat >"${CLIENT_ROOT}/lib/dp-phase2-operation-progress.sh" <<'HELPER2'
#!/usr/bin/env bash
PROGRESS_HELPER_LOADED=YES
HELPER2
cat >"${CLIENT_ROOT}/lib/dp-phase2-bringup-lifecycle.sh" <<'HELPER3'
#!/usr/bin/env bash
LIFECYCLE_LIB_LOADED=YES
HELPER3
cat >"${CLIENT_ROOT}/bringup_py3_dp_lifecycle.sh" <<'HELPER4'
#!/usr/bin/env bash
LIFECYCLE_WRAPPER_LOADED=YES
HELPER4
(
  cd "$CLIENT_ROOT"
  sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256
)
cat >"${TMP}/fakebin/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
chmod +x "${TMP}/fakebin/sudo" "${CLIENT_ROOT}/stage-dp-phase2.sh"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$HTTP_ROOT" \
  >"${TMP}/http.log" 2>&1 &
HTTP_PID=$!
for _ in $(seq 1 50); do
  curl -fsS "${MIRROR}/client/stage-dp-phase2.sh" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS "${MIRROR}/client/stage-dp-phase2.sh" >/dev/null
PATH="${TMP}/fakebin:${PATH}" bash "$phase2_block" >"${TMP}/phase2.out"
grep -q '^stage-dp-phase2.sh: OK$' "${TMP}/phase2.out"
grep -q '^PHASE2_HELPER_FETCH_E2E=PASS$' "${TMP}/phase2.out"
grep -q -- '--target-version 6.5.0 --same-version-recovery --mirror-url' "${TMP}/phase2.out"

# Backward compatibility: old Menu 7 command (stage+sha256 only) still works
# because stage prefetches missing helpers via --mirror-url.
printf 'HTTP_SOURCE_HELPER=YES\n' >"${CLIENT_ROOT}/lib/dp-offline-source-product-version.sh"
printf 'HTTP_PROGRESS_HELPER=YES\n' >"${CLIENT_ROOT}/lib/dp-phase2-operation-progress.sh"
# Use a stage copy whose only recovery path is the early mirror fetch (no
# absolute checkout fallback), so this fixture cannot silently reuse the repo.
python3 - "${ROOT}/client/stage-dp-phase2.sh" "${CLIENT_ROOT}/stage-dp-phase2.sh" <<'PY'
from pathlib import Path
import sys
src, dst = Path(sys.argv[1]), Path(sys.argv[2])
text = src.read_text(encoding="utf-8")
text = text.replace("/home/aella/ubuntu-mirror-automation/client/lib", "/nonexistent/ubuntu-mirror-automation/client/lib")
text = text.replace('"${SCRIPT_DIR}/../client/lib"', '"/nonexistent/relative/client/lib"')
dst.write_text(text, encoding="utf-8")
PY
(
  cd "$CLIENT_ROOT"
  sha256sum stage-dp-phase2.sh >stage-dp-phase2.sh.sha256
)
OLD_WORK="${TMP}/old-work"
mkdir -p "$OLD_WORK"
curl -fsSLo "${OLD_WORK}/stage-dp-phase2.sh" "${MIRROR}/client/stage-dp-phase2.sh"
rm -rf "${OLD_WORK}/lib"
PATH="${TMP}/fakebin:${PATH}" bash "${OLD_WORK}/stage-dp-phase2.sh" \
  --help --mirror-url "${MIRROR}" >/dev/null
grep -qx 'HTTP_SOURCE_HELPER=YES' "${OLD_WORK}/lib/dp-offline-source-product-version.sh"
grep -qx 'HTTP_PROGRESS_HELPER=YES' "${OLD_WORK}/lib/dp-phase2-operation-progress.sh"
bash -n "${OLD_WORK}/lib/dp-offline-source-product-version.sh"
bash -n "${OLD_WORK}/lib/dp-phase2-operation-progress.sh"
echo "PHASE2_OLD_MENU7_HELPER_PREFETCH=PASS"

# Invalid HTML payload must fail closed before helpers are sourced.
printf '<html>nope</html>\n' >"${CLIENT_ROOT}/lib/dp-phase2-operation-progress.sh"
BAD_WORK="${TMP}/bad-work"
mkdir -p "$BAD_WORK"
curl -fsSLo "${BAD_WORK}/stage-dp-phase2.sh" "${MIRROR}/client/stage-dp-phase2.sh"
set +e
PATH="${TMP}/fakebin:${PATH}" bash "${BAD_WORK}/stage-dp-phase2.sh" \
  --help --mirror-url "${MIRROR}" >"${TMP}/bad.out" 2>&1
BAD_RC=$?
set -e
[[ "$BAD_RC" -ne 0 ]]
grep -Eiq 'missing Phase 2 helper|ERROR:' "${TMP}/bad.out"

echo "MENU7_NORMAL_WIDTH_DISPLAY=PASS"
echo "PHASE2_HELPER_FETCH_E2E=PASS"
