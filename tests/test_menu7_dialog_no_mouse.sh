#!/usr/bin/env bash
# tests/test_menu7_dialog_no_mouse.sh
# Prove Menu 7 invokes dialog with --no-mouse --textbox and has no whiptail/less fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-dp-upgrade-mirror.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

echo "=== test_menu7_dialog_no_mouse ==="

# Structural: exact production invocation
if grep -nE 'dialog[[:space:]]+--no-mouse[[:space:]]+--title' "$INSTALLER" | grep -q textbox; then
  pass "dialog --no-mouse --title ... --textbox present"
else
  # Allow argv order: --no-mouse before --textbox on same logical call
  awk '
    /^mm_menu7_textbox\(\)/ {infn=1}
    infn && /^}/ {infn=0}
    infn {print}
  ' "$INSTALLER" >"${TMPDIR:-/tmp}/menu7_fn.$$"
  if grep -q -- '--no-mouse' "${TMPDIR:-/tmp}/menu7_fn.$$" \
    && grep -q -- '--textbox' "${TMPDIR:-/tmp}/menu7_fn.$$" \
    && grep -q 'dialog' "${TMPDIR:-/tmp}/menu7_fn.$$"
  then
    pass "mm_menu7_textbox uses dialog --no-mouse --textbox"
  else
    fail "mm_menu7_textbox missing dialog --no-mouse --textbox"
  fi
  rm -f "${TMPDIR:-/tmp}/menu7_fn.$$"
fi

fn="$(awk '/^mm_menu7_textbox\(\)/,/^}/' "$INSTALLER")"
printf '%s\n' "$fn" | grep -q 'mm_whiptail_textbox' \
  && fail "whiptail textbox fallback still in mm_menu7_textbox" \
  || pass "no Menu 7 whiptail textbox fallback"
printf '%s\n' "$fn" | grep -qE '\bless\b' \
  && fail "less present in mm_menu7_textbox" \
  || pass "no less in Menu 7 viewer"
printf '%s\n' "$fn" | grep -q 'MENU7_VIEWER_REASON=dialog_missing' \
  && pass "dialog_missing error path" \
  || fail "dialog_missing error path missing"
printf '%s\n' "$fn" | grep -q 'MENU7_VIEWER=FAIL' \
  && pass "MENU7_VIEWER=FAIL reported" \
  || fail "MENU7_VIEWER=FAIL missing"

# Argv-recording dialog stub: mm_menu7_textbox must pass --no-mouse and --textbox
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MM_PROJECT_ROOT="$ROOT"
export SKIP_MIRROR_HOST_VALIDATE=1
export MM_LOG_DIR="$TMP/logs"
export MM_CONFIG_DIR="$TMP/config"
export MM_CONFIG_FILE="$TMP/config/dp-upgrade-mirror.conf"
export MM_STATUS_FILE="$TMP/config/status"
export SCRIPT_DIR="${ROOT}/scripts"
mkdir -p "$MM_LOG_DIR" "$MM_CONFIG_DIR" "$TMP/bin"
: >"$MM_STATUS_FILE"

ARGV_LOG="$TMP/dialog.argv"
cat >"$TMP/bin/dialog" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${ARGV_LOG}"
# Simulate immediate Exit (textbox returns 0)
exit 0
EOF
chmod +x "$TMP/bin/dialog"

LIB="$TMP/installer-lib.sh"
awk -v sd="${ROOT}/scripts" '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"" sd "\""; next }
  /^main "\$@"$/ { next }
  { print }
' "$INSTALLER" >"$LIB"
# shellcheck disable=SC1090
source "$LIB"
# Installer registers an EXIT cleanup trap; restore test lifecycle control.
trap 'rm -rf "$TMP"' EXIT

HEIGHT=40 WIDTH=100
export PATH="$TMP/bin:/usr/bin:/bin"
SAMPLE="$TMP/sample.txt"
printf 'sample command file\n' >"$SAMPLE"
mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
[[ -f "$ARGV_LOG" ]] || fail "dialog stub was not invoked"
grep -q -- '--no-mouse' "$ARGV_LOG" && pass "stub argv contains --no-mouse" \
  || fail "stub argv missing --no-mouse: $(cat "$ARGV_LOG")"
grep -q -- '--textbox' "$ARGV_LOG" && pass "stub argv contains --textbox" \
  || fail "stub argv missing --textbox"
grep -q -- '--title' "$ARGV_LOG" && pass "stub argv contains --title" \
  || fail "stub argv missing --title"

# dialog missing → error, no whiptail textbox
rm -f "$TMP/bin/dialog"
hash -r 2>/dev/null || true
# Ensure no system dialog is visible on PATH for this negative check.
SAVE_PATH="$PATH"
export PATH="/nonexistent:$TMP/bin"
MSG_LOG="$TMP/msg.log"
mm_whiptail_msg() { printf '%s\n' "$*" >"$MSG_LOG"; return 0; }
mm_whiptail_textbox() { fail "whiptail textbox must not be used"; return 0; }
set +e
mm_menu7_textbox "DP Client Upgrade Commands" "$SAMPLE"
miss_rc=$?
set -e
export PATH="/usr/bin:/bin:${TMP}/bin:${SAVE_PATH}"
hash -r 2>/dev/null || true
[[ "$miss_rc" -ne 0 ]] && pass "dialog missing returns non-zero" \
  || fail "dialog missing should fail closed"
grep -q 'MENU7_VIEWER=FAIL' "$MSG_LOG" && pass "error reports MENU7_VIEWER=FAIL" \
  || fail "missing MENU7_VIEWER=FAIL in message"
grep -q 'MENU7_VIEWER_REASON=dialog_missing' "$MSG_LOG" \
  && pass "error reports dialog_missing" \
  || fail "missing dialog_missing reason"

# Main menu: only choice 0 exits
grep -q 'GUI_EXITS_ONLY_ON_EXPLICIT_ZERO' "$INSTALLER" \
  && pass "main menu exit path present" || fail "explicit-zero exit marker missing"
grep -A80 'cmd_mirror_manager()' "$INSTALLER" | grep -qE '^[[:space:]]*0\)' \
  && pass "explicit main-menu 0 remains exit" \
  || fail "main-menu 0 exit missing"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== test_menu7_dialog_no_mouse PASS ==="
  echo "TEST_MENU7_NO_MOUSE=PASS"
  exit 0
fi
echo "=== test_menu7_dialog_no_mouse FAIL ==="
exit 1
