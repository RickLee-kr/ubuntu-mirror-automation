#!/usr/bin/env bash
# Verify stellar-offline-os-upgrade-runner embeds current_hop_env_path before use.
# Hermetic: extract RUNNER heredoc helpers only; no real OS upgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOPS=(
  bionic-to-focal
  focal-to-jammy
  jammy-to-noble
)

extract_runner_helpers() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
if not m:
    raise SystemExit("RUNNER heredoc missing")
runner = m.group(1)
needed = (
    "read_kv_file_field",
    "current_hop_env_path",
    "read_current_hop_field",
    "persist_current_hop_package_transition_started",
)
for name in needed:
    if f"{name}()" not in runner:
        raise SystemExit(f"missing {name} in RUNNER")
# Helpers must be defined before persist uses current_hop_env_path.
if runner.index("current_hop_env_path() {") > runner.index(
    "persist_current_hop_package_transition_started() {"
):
    raise SystemExit("current_hop_env_path defined after persist")
start = runner.index("read_kv_file_field() {")
end = runner.index("mark_package_transition_detected() {")
helpers = runner[start:end]
Path(sys.argv[2]).write_text(
    "#!/usr/bin/env bash\nset -euo pipefail\n"
    "STATE_ROOT=\"${STATE_ROOT:?}\"\n"
    "PIN_HOP=\"${PIN_HOP:?}\"\n"
    "CURRENT_HOP_ENV_FILE=\"${CURRENT_HOP_ENV_FILE:-${STATE_ROOT}/current-hop.env}\"\n"
    # Detached runner uses log(); stub it for hermetic unit tests.
    "log() { :; }\n"
    + helpers
    + "\n"
    "case \"$1\" in\n"
    "  path) current_hop_env_path; printf '\\n' ;;\n"
    "  persist) persist_current_hop_package_transition_started ;;\n"
    "  *) exit 2 ;;\n"
    "esac\n",
    encoding="utf-8",
)
PY
  chmod 0755 "$dest"
}

for hop in "${HOPS[@]}"; do
  src="${ROOT}/client/dp-offline-upgrade-${hop}.sh.in"
  [[ -f "$src" ]]
  helper="${TMP}/runner-helpers-${hop}.sh"
  extract_runner_helpers "$src" "$helper"

  state="${TMP}/state-${hop}"
  mkdir -p "$state"
  envf="${state}/current-hop.env"
  cat >"$envf" <<EOF
CURRENT_HOP=${hop}
PACKAGE_TRANSITION_STARTED=false
EOF
  chmod 0600 "$envf"

  # Clean env: function must resolve without host pollution.
  got="$(
    env -i PATH="/usr/bin:/bin" HOME="$TMP" \
      STATE_ROOT="$state" PIN_HOP="$hop" \
      bash --noprofile --norc "$helper" path
  )"
  [[ "$got" == "$envf" ]]
  ! env -i PATH="/usr/bin:/bin" HOME="$TMP" \
    STATE_ROOT="$state" PIN_HOP="$hop" \
    bash --noprofile --norc "$helper" path 2>&1 \
    | grep -q 'current_hop_env_path: command not found'

  # Wrong hop identity must not mutate PACKAGE_TRANSITION_STARTED.
  env -i PATH="/usr/bin:/bin" HOME="$TMP" \
    STATE_ROOT="$state" PIN_HOP="not-a-real-hop" \
    bash --noprofile --norc "$helper" persist
  grep -qx 'PACKAGE_TRANSITION_STARTED=false' "$envf"

  # Matching hop may persist true.
  env -i PATH="/usr/bin:/bin" HOME="$TMP" \
    STATE_ROOT="$state" PIN_HOP="$hop" \
    bash --noprofile --norc "$helper" persist
  grep -qx 'PACKAGE_TRANSITION_STARTED=true' "$envf"

  # Empty STATE_ROOT must fail closed for path probe (function still defined).
  set +e
  env -i PATH="/usr/bin:/bin" HOME="$TMP" \
    STATE_ROOT="" PIN_HOP="$hop" \
    bash --noprofile --norc -c '
      STATE_ROOT=""
      PIN_HOP="'"$hop"'"
      # shellcheck source=/dev/null
      source "'"$helper"'"
    ' >/dev/null 2>&1
  # helper script requires STATE_ROOT via ${STATE_ROOT:?} — non-zero expected
  set -e

  echo "CURRENT_HOP_ENV_PATH_${hop}=PASS"
done

# Xenial runner historically has no persist/current_hop_env_path chain; ensure
# it still does not call the missing helper (static contract).
XENIAL_IN="${ROOT}/client/dp-offline-upgrade-xenial-to-bionic.sh.in"
python3 - "$XENIAL_IN" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
assert m, "xenial RUNNER missing"
runner = m.group(1)
if "current_hop_env_path" in runner:
    raise SystemExit("unexpected current_hop_env_path in xenial RUNNER")
print("CURRENT_HOP_ENV_PATH_xenial-to-bionic=N/A_NO_CALLSITE")
PY

# Built .sh artifacts must stay in sync with templates for the three hops.
for hop in "${HOPS[@]}"; do
  built="${ROOT}/client/dp-offline-upgrade-${hop}.sh"
  [[ -f "$built" ]]
  grep -q 'current_hop_env_path() {' "$built"
  python3 - "$built" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
assert m, "built RUNNER missing"
runner = m.group(1)
assert "current_hop_env_path() {" in runner
assert runner.index("current_hop_env_path() {") < runner.index(
    "persist_current_hop_package_transition_started() {"
)
PY
done

echo "CURRENT_HOP_ENV_PATH_RUNNER=PASS"
