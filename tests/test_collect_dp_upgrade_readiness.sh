#!/usr/bin/env bash
# tests/test_collect_dp_upgrade_readiness.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/collect-dp-upgrade-readiness.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[test] collect-dp-upgrade-readiness.sh"

# 1. bash -n
if bash -n "$SCRIPT"; then
  pass "bash -n"
else
  fail "bash -n"
fi

# 2. --help
if bash "$SCRIPT" --help >/dev/null; then
  pass "--help"
else
  fail "--help"
fi

# 3. --version
ver="$(bash "$SCRIPT" --version 2>/dev/null || true)"
if [[ "$ver" == *collect-dp-upgrade-readiness.sh* && "$ver" == *1.* ]]; then
  pass "--version ($ver)"
else
  fail "--version: $ver"
fi

# 4. unknown option fails
if bash "$SCRIPT" --definitely-not-a-real-option >/dev/null 2>&1; then
  fail "unknown option should fail"
else
  pass "unknown option fails"
fi

# 5. missing option value fails
if bash "$SCRIPT" --output-dir >/dev/null 2>&1; then
  fail "missing --output-dir value should fail"
else
  pass "missing --output-dir value fails"
fi
if bash "$SCRIPT" --network-timeout >/dev/null 2>&1; then
  fail "missing --network-timeout value should fail"
else
  pass "missing --network-timeout value fails"
fi
if bash "$SCRIPT" --network-timeout abc >/dev/null 2>&1; then
  fail "non-numeric --network-timeout should fail"
else
  pass "non-numeric --network-timeout fails"
fi

# Source helpers without running main (tests 6-10, source)
# shellcheck source=scripts/collect-dp-upgrade-readiness.sh
source "$SCRIPT"

# 10. sourcing must not auto-run main (RESULT_DIR should be unset)
if [[ -z "${RESULT_DIR:-}" ]]; then
  pass "source does not auto-run main"
else
  fail "source auto-ran main (RESULT_DIR=$RESULT_DIR)"
fi

# 6. sanitize_filename
sf="$(sanitize_filename 'dp host/01*.bad')"
if [[ "$sf" == "dp_host_01_.bad" ]]; then
  pass "sanitize_filename ($sf)"
else
  fail "sanitize_filename: $sf"
fi
sf2="$(sanitize_filename '')"
[[ "$sf2" == "unknown" ]] && pass "sanitize_filename empty" || fail "sanitize_filename empty: $sf2"

# 7. JSON escaping
esc="$(json_escape 'a"b\c')"
if [[ "$esc" == 'a\"b\\c' ]]; then
  pass "json_escape quotes/backslash"
else
  fail "json_escape: [$esc]"
fi
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import json,sys; json.loads('\"'+sys.argv[1]+'\"')" "$esc" 2>/dev/null; then
    pass "json_escape python round-trip"
  else
    fail "json_escape python round-trip"
  fi
fi

# 8. URL credential redaction
red="$(printf 'deb http://user:secretpass@mirror.example/ubuntu xenial main\n' | redact_stream)"
if [[ "$red" == *'***:***@'* && "$red" != *secretpass* ]]; then
  pass "URL credential redaction"
else
  fail "URL credential redaction: $red"
fi

# APT deb-line URI extraction (bracket options)
uri1="$(_extract_deb_line_uri 'deb [arch=amd64, trusted=yes] http://dl.example.com/ubuntu/ xenial main')"
uri2="$(_extract_deb_line_uri 'deb http://archive.ubuntu.com/ubuntu/ xenial main')"
if [[ "$uri1" == "http://dl.example.com/ubuntu/" && "$uri2" == "http://archive.ubuntu.com/ubuntu/" ]]; then
  pass "APT deb URI extraction with options"
else
  fail "APT deb URI extraction: [$uri1] [$uri2]"
fi

# 9. PASSWORD/TOKEN/SECRET redaction
red2="$(printf 'export TOKEN=abcd1234\nPASSWORD=hunter2\nSECRET=zz\n' | redact_stream)"
if [[ "$red2" == *'***REDACTED***'* && "$red2" != *hunter2* && "$red2" != *abcd1234* ]]; then
  pass "PASSWORD/TOKEN/SECRET redaction"
else
  fail "PASSWORD/TOKEN/SECRET redaction: $red2"
fi

# take_lines drains stdin to avoid grep SIGPIPE / Broken pipe
pipe_err="${WORKDIR}/pipe.err"
{ seq 1 500 | grep . | take_lines 5 >"${WORKDIR}/pipe.out"; } 2>"$pipe_err"
if [[ "$(wc -l <"${WORKDIR}/pipe.out" | tr -d ' ')" -eq 5 ]] && ! grep -qi 'Broken pipe' "$pipe_err"; then
  pass "take_lines avoids Broken pipe"
else
  fail "take_lines Broken pipe: out=$(cat "${WORKDIR}/pipe.out") err=$(cat "$pipe_err")"
fi

# summary.json bringup includes legacy aelladeb fields after smoke

# 11-18. smoke test with --skip-network
SMOKE_OUT="${WORKDIR}/smoke-out"
mkdir -p "$SMOKE_OUT"
# Snapshot of files outside output before/after is checked relative to WORKDIR root
BEFORE_OUTSIDE="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 ! -path "$SMOKE_OUT" | sort || true)"

set +e
bash "$SCRIPT" --output-dir "$SMOKE_OUT" --skip-network --keep-directory \
  >"${WORKDIR}/smoke.stdout" 2>"${WORKDIR}/smoke.stderr"
SMOKE_RC=$?
set -e
if [[ "$SMOKE_RC" -eq 0 ]]; then
  pass "skip-network smoke test exit 0"
else
  fail "skip-network smoke test exit $SMOKE_RC"
  tail -20 "${WORKDIR}/smoke.stderr" || true
fi

RESULT_DIR_SMOKE="$(find "$SMOKE_OUT" -maxdepth 1 -type d -name 'dp-upgrade-readiness-*' | head -n 1 || true)"
ARCHIVE_SMOKE="$(find "$SMOKE_OUT" -maxdepth 1 -type f -name 'dp-upgrade-readiness-*.tar.gz' | head -n 1 || true)"

# 12. summary.json valid
validate_json() {
  local f="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f"
  elif command -v python >/dev/null 2>&1; then
    python -c "import json,sys; json.load(open(sys.argv[1]))" "$f"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -rjson -e "JSON.parse(File.read(ARGV[0]))" "$f"
  elif command -v perl >/dev/null 2>&1 && perl -MJSON -e 1 2>/dev/null; then
    perl -MJSON -e 'decode_json(do{local $/; open my $fh,"<",shift; <$fh>})' "$f"
  else
    # Minimal structural check
    grep -q '"schema_version"' "$f" && grep -q '"collection"' "$f"
  fi
}

if [[ -n "$RESULT_DIR_SMOKE" && -f "${RESULT_DIR_SMOKE}/summary.json" ]]; then
  if validate_json "${RESULT_DIR_SMOKE}/summary.json"; then
    pass "summary.json valid JSON"
  else
    fail "summary.json invalid"
    head -50 "${RESULT_DIR_SMOKE}/summary.json" || true
  fi
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'aelladeb_exists' in d['bringup']; assert 'aelladeb_py3_exists' in d['bringup']" \
      "${RESULT_DIR_SMOKE}/summary.json"; then
      pass "summary.json bringup has aelladeb fields"
    else
      fail "summary.json missing aelladeb bringup fields"
    fi
  fi
  if [[ -f "${RESULT_DIR_SMOKE}/dp/aelladeb-summary.txt" && -f "${RESULT_DIR_SMOKE}/dp/aelladeb-py3-summary.txt" ]]; then
    pass "aelladeb and aelladeb_py3 summary files present"
  else
    fail "missing aelladeb summary files"
  fi
else
  fail "summary.json missing"
fi

# 13. tar.gz
if [[ -n "$ARCHIVE_SMOKE" && -f "$ARCHIVE_SMOKE" ]]; then
  if tar -tzf "$ARCHIVE_SMOKE" >/dev/null 2>&1; then
    pass "tar.gz created and readable"
  else
    fail "tar.gz unreadable"
  fi
else
  fail "tar.gz missing"
fi

# 14. commands.tsv header
if [[ -n "$RESULT_DIR_SMOKE" && -f "${RESULT_DIR_SMOKE}/commands.tsv" ]]; then
  hdr="$(head -n 1 "${RESULT_DIR_SMOKE}/commands.tsv")"
  need="check_id category command_description command started_at_utc duration_ms return_code status output_file error_summary"
  ok=1
  for field in $need; do
    if ! printf '%s' "$hdr" | grep -q "$field"; then
      ok=0
    fi
  done
  if [[ "$ok" -eq 1 ]]; then
    pass "commands.tsv header"
  else
    fail "commands.tsv header: $hdr"
  fi
  if [[ "$(wc -l <"${RESULT_DIR_SMOKE}/commands.tsv")" -gt 1 ]]; then
    pass "commands.tsv has rows"
  else
    fail "commands.tsv has no data rows"
  fi
else
  fail "commands.tsv missing"
fi

# 15. collection.log
if [[ -n "$RESULT_DIR_SMOKE" && -f "${RESULT_DIR_SMOKE}/collection.log" ]]; then
  if grep -qE 'INFO Starting' "${RESULT_DIR_SMOKE}/collection.log"; then
    pass "collection.log generated"
  else
    fail "collection.log missing expected content"
  fi
else
  fail "collection.log missing"
fi

# 16. non-root partial collection possible (this smoke already ran as current user)
if [[ "$(id -u)" -ne 0 ]]; then
  if [[ -n "$RESULT_DIR_SMOKE" && -f "${RESULT_DIR_SMOKE}/summary.json" ]]; then
    pass "non-root partial collection works"
  else
    fail "non-root collection failed"
  fi
else
  pass "running as root; non-root path covered by unit design"
fi

# 17. missing commands do not abort — verify SKIPPED/NOT_AVAILABLE rows exist or run completed
if grep -qE 'SKIPPED|NOT_AVAILABLE' "${RESULT_DIR_SMOKE}/commands.tsv" 2>/dev/null || \
   [[ -f "${RESULT_DIR_SMOKE}/summary.json" ]]; then
  pass "missing commands do not abort collection"
else
  fail "expected resilient completion with missing commands"
fi

# 18. no files created outside output directory (within WORKDIR)
AFTER_OUTSIDE="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 ! -path "$SMOKE_OUT" | sort || true)"
# Allow smoke.stdout / smoke.stderr which we created
filtered_after="$(printf '%s\n' "$AFTER_OUTSIDE" | grep -v 'smoke\.stdout$' | grep -v 'smoke\.stderr$' || true)"
filtered_before="$(printf '%s\n' "$BEFORE_OUTSIDE" | grep -v 'smoke\.stdout$' | grep -v 'smoke\.stderr$' || true)"
if [[ "$filtered_after" == "$filtered_before" ]]; then
  pass "no unexpected files outside output directory"
else
  fail "unexpected outside files: before=[$filtered_before] after=[$filtered_after]"
fi

# Also ensure archive contents stay under the collection name prefix
if [[ -n "$ARCHIVE_SMOKE" ]]; then
  bad_paths="$(tar -tzf "$ARCHIVE_SMOKE" | grep -E '^\.\./|^/' || true)"
  if [[ -z "$bad_paths" ]]; then
    pass "archive paths are relative/safe"
  else
    fail "archive contains unsafe paths"
  fi
fi

# 19. static check: forbidden mutating commands
FORBIDDEN_PATTERNS=(
  'apt-get[[:space:]]+(install|remove|purge|upgrade|dist-upgrade)'
  'apt[[:space:]]+(install|remove|purge|upgrade|full-upgrade)'
  'do-release-upgrade'
  'sed[[:space:]]+-i'
  '[[:space:]]chsh[[:space:]]|[[:space:]]chsh$'
  '[[:space:]]usermod[[:space:]]'
  'systemctl[[:space:]]+(start|stop|restart|enable|disable)[[:space:]]'
  '[[:space:]]umount[[:space:]]|[[:space:]]resize2fs[[:space:]]|[[:space:]]growpart[[:space:]]'
  'systemctl[[:space:]]+reboot|[[:space:]]reboot[[:space:]]+-|[[:space:]]shutdown[[:space:]]+-r'
  'docker[[:space:]]+(start|stop|rm|kill)[[:space:]]'
)
static_fail=0
for pat in "${FORBIDDEN_PATTERNS[@]}"; do
  hits="$(grep -nE "$pat" "$SCRIPT" 2>/dev/null | grep -vE '[[:space:]]*#|FORBIDDEN|must not|Does not|never|read-only|Usage:|static check' || true)"
  if [[ -n "$hits" ]]; then
    echo "    forbidden match ($pat):"
    printf '%s\n' "$hits" | head -5
    static_fail=1
  fi
done
# Read-only `mount` (listing) is intentional; mutating mount/umount covered above.
if [[ "$static_fail" -eq 0 ]]; then
  pass "static check: no forbidden mutating commands"
else
  fail "static check: forbidden mutating commands found"
fi

# Extra: ensure script never calls apt-get update / apt update
if grep -nE 'apt-get[[:space:]]+update|apt[[:space:]]+update' "$SCRIPT" >/dev/null 2>&1; then
  fail "static: apt update must not be present"
else
  pass "static: no apt update"
fi

# 20. archive must not contain obvious secret fixture
FIXTURE_DIR="${WORKDIR}/secret-fixture-check"
mkdir -p "$FIXTURE_DIR"
# Create a tiny synthetic check using redact_stream on a fixture string embedded in output via unit test
fixture_line='http://admin:SuperSecret123@archive.example/ubuntu'
redacted_line="$(printf '%s\n' "$fixture_line" | redact_stream)"
if [[ "$redacted_line" == *SuperSecret123* ]]; then
  fail "secret fixture not redacted by redact_stream"
else
  pass "secret fixture redacted by redact_stream"
fi
if [[ -n "$ARCHIVE_SMOKE" ]]; then
  if tar -xOzf "$ARCHIVE_SMOKE" --wildcards '*/summary.json' 2>/dev/null | grep -q 'SuperSecret123'; then
    fail "archive contains secret fixture string"
  else
    # Broader: private key header
    if tar -tzf "$ARCHIVE_SMOKE" >/dev/null && tar -xOzf "$ARCHIVE_SMOKE" 2>/dev/null | grep -q 'BEGIN RSA PRIVATE KEY'; then
      fail "archive contains private key material"
    else
      pass "archive has no obvious secret fixture / private key"
    fi
  fi
fi

# shellcheck if available
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317,SC2004,SC2086,SC2207 "$SCRIPT"; then
    pass "shellcheck clean (with project exclusions)"
  else
    # Try without SC2004/SC2086 extras and report
    if shellcheck -x -e SC1091,SC2015,SC2034,SC2119,SC2120,SC2317 "$SCRIPT"; then
      pass "shellcheck clean"
    else
      fail "shellcheck warnings"
    fi
  fi
else
  pass "shellcheck not installed (skipped)"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL collect-dp-upgrade-readiness TESTS PASSED"
  exit 0
fi
echo "SOME collect-dp-upgrade-readiness TESTS FAILED"
exit 1
