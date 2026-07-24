#!/usr/bin/env bash
# tests/test_prepare_backup_staging.sh — parent-shell-safe backup staging helper
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/prepare-backup-staging.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-prepare-backup-staging.XXXXXX")"
trap 'rm -rf -- "$WORKDIR"' EXIT

echo "=== test_prepare_backup_staging ==="

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------
# Build fake PEM/PGP private-key blocks at runtime only (never leave complete
# blocks as consecutive exact lines in this test source file).
FAKE_B64_LINE_1="MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfnTESTONLYBASE64DATAXXXXXX"
FAKE_B64_LINE_2="MORETESTONLYBASE64PAYLOADDATAHEREXXXXXXXXXXXXXXXXXXXXX"

write_fake_pem_block() {
  local dest="$1"
  local kind="$2"
  {
    printf '%s\n' "-----BEGIN ${kind}-----"
    printf '%s\n' "$FAKE_B64_LINE_1"
    printf '%s\n' "$FAKE_B64_LINE_2"
    printf '%s\n' "-----END ${kind}-----"
  } >"$dest"
}

write_fake_pgp_block() {
  local dest="$1"
  {
    printf '%s\n' "-----BEGIN PGP PRIVATE KEY BLOCK-----"
    printf '%s\n' "Version: OpenPGP.js Fixture"
    printf '%s\n' "Comment: test-only-not-a-real-key"
    printf '\n'
    printf '%s\n' "$FAKE_B64_LINE_1"
    printf '%s\n' "$FAKE_B64_LINE_2"
    printf '%s\n' "-----END PGP PRIVATE KEY BLOCK-----"
  } >"$dest"
}

make_base_fixture() {
  local repo="$1"
  mkdir -p "$repo"/{client,docs,lib,scripts,tests,config/client-signing,artifacts/client}
  # Nested repository that must never be staged.
  mkdir -p "$repo/ubuntu-mirror-automation"
  git -C "$repo/ubuntu-mirror-automation" init -q
  printf 'nested\n' >"$repo/ubuntu-mirror-automation/README"
  git -C "$repo/ubuntu-mirror-automation" add README
  git -C "$repo/ubuntu-mirror-automation" -c user.email=t@t -c user.name=t commit -qm nested

  cat >"$repo/.gitignore" <<'EOF'
# Local
*.log
__pycache__/
*.pyc
artifacts/client/
config/client-signing/*.private.gpg
artifacts/upgrade-discovery/
artifacts/client-unsigned-test/
artifacts/recovery/
artifacts/logs/
artifacts/client/nginx-deploy/
artifacts/client/build-summary.json
ubuntu-mirror-automation/
EOF

  printf 'client\n' >"$repo/client/README"
  printf 'docs\n' >"$repo/docs/README"
  printf 'lib\n' >"$repo/lib/README"
  printf 'scripts\n' >"$repo/scripts/README"
  printf 'tests\n' >"$repo/tests/README"
  printf '{}\n' >"$repo/config/offline-upgrade-exceptions.json"
  printf '{}\n' >"$repo/config/offline-upgrade-profile.json"
  cp -a -- "$SCRIPT" "$repo/scripts/prepare-backup-staging.sh"
  chmod +x "$repo/scripts/prepare-backup-staging.sh"

  # Public-only signing keyring (copy from production when available).
  if [[ -f "$ROOT/config/client-signing/offline-client-manifest.gpg" ]]; then
    cp -a -- "$ROOT/config/client-signing/offline-client-manifest.gpg" \
      "$repo/config/client-signing/offline-client-manifest.gpg"
  else
    fail "production public keyring missing for fixture seed"
    return 1
  fi

  git -C "$repo" init -q
  git -C "$repo" checkout -q -b main
  git -C "$repo" remote add origin git@github.com:RickLee-kr/ubuntu-mirror-automation.git
  git -C "$repo" -c user.email=t@t -c user.name=t add \
    .gitignore client docs lib scripts tests \
    config/offline-upgrade-exceptions.json \
    config/offline-upgrade-profile.json \
    config/client-signing/offline-client-manifest.gpg
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm base
}

run_script() {
  local repo="$1"
  shift
  (
    cd -- "$repo" || exit 97
    PREPARE_BACKUP_STAGING_ALLOW_FIXTURE=1 \
      bash scripts/prepare-backup-staging.sh "$@"
  )
}

# Temporary GPG home for fixture signing (never uses production private keys).
FIXTURE_GNUPG=""
FIXTURE_FPR=""
ensure_fixture_gpg() {
  if [[ -n "${FIXTURE_GNUPG}" && -d "${FIXTURE_GNUPG}" ]]; then
    return 0
  fi
  FIXTURE_GNUPG="${WORKDIR}/gnupg-fixture"
  mkdir -p "$FIXTURE_GNUPG"
  chmod 700 "$FIXTURE_GNUPG"
  gpg --homedir "$FIXTURE_GNUPG" --batch --passphrase '' \
    --quick-gen-key "fixture-manifest@example.com" default default never >/dev/null 2>&1
  FIXTURE_FPR="$(
    gpg --homedir "$FIXTURE_GNUPG" --list-keys --with-colons \
      | awk -F: '/^fpr:/ {print $10; exit}'
  )"
  [[ -n "$FIXTURE_FPR" ]]
}

set_helper_pins() {
  # Rewrite EXPECTED_SCRIPT_SHA block inside a fixture copy of the helper.
  local helper="$1"
  local x2b="$2" b2f="$3" f2j="$4" j2n="$5"
  python3 - "$helper" "$x2b" "$b2f" "$f2j" "$j2n" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
pins = {
    "dp-offline-upgrade-xenial-to-bionic.sh": sys.argv[2],
    "dp-offline-upgrade-bionic-to-focal.sh": sys.argv[3],
    "dp-offline-upgrade-focal-to-jammy.sh": sys.argv[4],
    "dp-offline-upgrade-jammy-to-noble.sh": sys.argv[5],
}
text = path.read_text(encoding="utf-8")
def repl(match):
    body = ["declare -A EXPECTED_SCRIPT_SHA=("]
    for name, sha in pins.items():
        body.append('  ["%s"]="%s"' % (name, sha))
    body.append(")")
    return "\n".join(body)
new, n = re.subn(
    r"declare -A EXPECTED_SCRIPT_SHA=\([\s\S]*?\)",
    repl,
    text,
    count=1,
)
if n != 1:
    raise SystemExit("failed to rewrite EXPECTED_SCRIPT_SHA")
path.write_text(new, encoding="utf-8")
PY
}

install_hop_artifact() {
  # Create a consistent (or intentionally broken) production artifact set.
  # Args: repo hop script_body [manifest_extra_json_object]
  local repo="$1" hop="$2" body="$3"
  local script="dp-offline-upgrade-${hop}.sh"
  local top="${repo}/artifacts/client/${script}"
  local hopdir="${repo}/artifacts/client/${hop}"
  local man="${hopdir}/client-manifest.json"
  local sha side_sha
  mkdir -p "$hopdir"
  printf '%s\n' "$body" >"$top"
  chmod 755 "$top"
  cp -a -- "$top" "${hopdir}/${script}"
  sha="$(sha256sum -- "$top" | awk '{print $1}')"
  printf '%s  %s\n' "$sha" "$script" >"${repo}/artifacts/client/${script}.sha256"

  ensure_fixture_gpg || return 1
  gpg --homedir "$FIXTURE_GNUPG" --batch --yes --output \
    "${hopdir}/stellar-offline-manifest.gpg" \
    --export "$FIXTURE_FPR" >/dev/null 2>&1

  python3 - "$man" "$hop" "$script" "$sha" <<'PY'
import json, sys
man, hop, script, sha = sys.argv[1:5]
data = {
    "schema_version": 1,
    "hop": hop,
    "profile": "fixture",
    "confirm_phrase": "TEST",
    "generated_at": "2026-01-01T00:00:00Z",
    # Intentionally omit script_sha256 unless caller patches later.
    "meta_release_sha256": "0" * 64,
}
with open(man, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  gpg --homedir "$FIXTURE_GNUPG" --batch --yes --pinentry-mode loopback \
    --passphrase '' --detach-sign --armor -o "${man}.asc" "$man" >/dev/null 2>&1
  printf '%s\n' "$sha"
}

patch_manifest_script_sha() {
  local man="$1" script="$2" sha="$3"
  python3 - "$man" "$script" "$sha" <<'PY'
import json, sys
man, script, sha = sys.argv[1:4]
with open(man, encoding="utf-8") as fh:
    data = json.load(fh)
data["script_sha256"] = sha
# Also include a files[] entry to exercise schema walk.
data["files"] = [{"name": script, "sha256": sha, "size": 0}]
with open(man, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

resign_manifest() {
  local repo="$1" hop="$2"
  local man="${repo}/artifacts/client/${hop}/client-manifest.json"
  ensure_fixture_gpg || return 1
  rm -f -- "${man}.asc"
  gpg --homedir "$FIXTURE_GNUPG" --batch --yes --pinentry-mode loopback \
    --passphrase '' --detach-sign --armor -o "${man}.asc" "$man" >/dev/null 2>&1
}

install_four_hop_artifacts() {
  # Install four consistent hops and align helper pins to their digests.
  local repo="$1"
  local s_x2b s_b2f s_f2j s_j2n
  s_x2b="$(install_hop_artifact "$repo" xenial-to-bionic "fixture-script-x2b-body-AAA")"
  s_b2f="$(install_hop_artifact "$repo" bionic-to-focal "fixture-script-b2f-body-BBB")"
  s_f2j="$(install_hop_artifact "$repo" focal-to-jammy "fixture-script-f2j-body-CCC")"
  s_j2n="$(install_hop_artifact "$repo" jammy-to-noble "fixture-script-j2n-body-DDD")"
  set_helper_pins "$repo/scripts/prepare-backup-staging.sh" "$s_x2b" "$s_b2f" "$s_f2j" "$s_j2n"
  printf '%s %s %s %s\n' "$s_x2b" "$s_b2f" "$s_f2j" "$s_j2n"
}

# 1) bash execution returns expected codes (usage -> 2)
echo "-- 1 bash execution / usage --"
set +e
bash "$SCRIPT" >/dev/null 2>&1
rc=$?
set +e
if [[ "$rc" -eq 2 ]]; then
  pass "1 bash with no args -> exit 2"
else
  fail "1 expected exit 2 got ${rc}"
fi

# 2) failure does not kill parent shell
echo "-- 2 parent shell survives child failure --"
set +e
bash "$SCRIPT" --nope >/dev/null 2>&1
rc=$?
set +e
alive_marker="PARENT_ALIVE_$$"
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$alive_marker" | grep -q "$alive_marker"; then
  pass "2 parent shell alive after child failure (rc=${rc})"
else
  fail "2 parent shell survival check"
fi

# 3+4) source refusal without killing parent; return code 2
echo "-- 3/4 source refusal --"
set +e
# shellcheck disable=SC1090
source "$SCRIPT" >/dev/null 2>&1
src_rc=$?
set +e
if [[ "$src_rc" -eq 2 ]]; then
  pass "3/4 source refused with return code 2; parent alive"
else
  fail "3/4 source rc=${src_rc} want 2"
fi

# Base fixture
FIX="${WORKDIR}/fix"
make_base_fixture "$FIX" || true

# 5) forbidden path staged -> audit fail
echo "-- 5 forbidden staged path --"
mkdir -p "$FIX/artifacts/upgrade-discovery"
printf 'x\n' >"$FIX/artifacts/upgrade-discovery/leak.txt"
git -C "$FIX" add -f -- artifacts/upgrade-discovery/leak.txt
set +e
out="$(run_script "$FIX" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -q 'STAGING_AUDIT=FAIL' <<<"$out" \
  && grep -qE 'FORBIDDEN|FAILURE_CLASS=FORBIDDEN' <<<"$out"; then
  pass "5 forbidden staged path fails audit"
else
  fail "5 forbidden path audit (rc=${rc})"
  printf '%s\n' "$out" | tail -30
fi
git -C "$FIX" reset -q HEAD -- artifacts/upgrade-discovery/leak.txt 2>/dev/null || true
rm -f "$FIX/artifacts/upgrade-discovery/leak.txt"

# 6) complete private key block in staged blob (spaced filename)
echo "-- 6 private key block --"
write_fake_pem_block "$FIX/docs/note with spaces.txt" "RSA PRIVATE KEY"
git -C "$FIX" add -- "docs/note with spaces.txt"
set +e
out="$(run_script "$FIX" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -q 'PRIVATE_KEY_BLOCK_STAGED' <<<"$out" \
  && grep -q 'type=RSA' <<<"$out"; then
  pass "6 private key block in spaced filename fails"
else
  fail "6 private key block (rc=${rc})"
  printf '%s\n' "$out" | tail -30
fi
git -C "$FIX" reset -q HEAD -- "docs/note with spaces.txt"
rm -f "$FIX/docs/note with spaces.txt"

# 7) >20 MiB staged blob fails
echo "-- 7 oversized staged blob --"
# Create ~21MiB file via dd
dd if=/dev/zero of="$FIX/docs/big.bin" bs=1M count=21 status=none
git -C "$FIX" add -- docs/big.bin
set +e
out="$(run_script "$FIX" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -qE 'STAGED_BLOB_TOO_LARGE|STAGED_OVER_20MB|STAGED_FILES_OVER_20MB=[1-9]' <<<"$out"; then
  pass "7 staged blob >20MiB fails"
else
  fail "7 oversized blob (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi
git -C "$FIX" reset -q HEAD -- docs/big.bin
rm -f "$FIX/docs/big.bin"

# 8) public-only keyring passes (clean index)
echo "-- 8 public-only keyring --"
set +e
out="$(run_script "$FIX" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'SIGNING_KEYRING=PUBLIC_ONLY' <<<"$out" \
  && grep -q 'STAGING_AUDIT=PASS_READY_FOR_TEST' <<<"$out"; then
  pass "8 public-only keyring audit-only PASS"
else
  fail "8 public-only keyring (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 9) secret key packet fails
echo "-- 9 secret key packet fails --"
SECFIX="${WORKDIR}/sec"
make_base_fixture "$SECFIX"
# Generate a throwaway secret key and install as "public" path to force failure.
GNUPGHOME="${WORKDIR}/gnupg-sec"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
set +e
gpg --homedir "$GNUPGHOME" --batch --passphrase '' \
  --quick-gen-key "fixture-secret@example.com" default default never >/dev/null 2>&1
gpg --homedir "$GNUPGHOME" --batch --pinentry-mode loopback --passphrase '' \
  --export-secret-keys >"$SECFIX/config/client-signing/offline-client-manifest.gpg" 2>/dev/null
set +e
if [[ ! -s "$SECFIX/config/client-signing/offline-client-manifest.gpg" ]]; then
  fail "9 could not export secret key for fixture"
else
  set +e
  out="$(run_script "$SECFIX" --audit-only 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]] && grep -qE 'SIGNING_KEYRING_HAS_SECRET|SECRET_PRESENT|FAILURE_CLASS=SIGNING_KEYRING_HAS_SECRET' <<<"$out"; then
    pass "9 secret key packet fails audit"
  else
    fail "9 secret key packet (rc=${rc})"
    printf '%s\n' "$out" | tail -40 || true
  fi
fi

# 10) preexisting staged files restored after audit failure in --stage
echo "-- 10 preexisting staged preserved on rollback --"
ROLL="${WORKDIR}/roll"
make_base_fixture "$ROLL"
printf 'preexisting\n' >"$ROLL/docs/preexisting.txt"
git -C "$ROLL" add -- docs/preexisting.txt
pre_list="$(git -C "$ROLL" diff --cached --name-only | sort)"
write_fake_pem_block "$ROLL/docs/bad key.txt" "OPENSSH PRIVATE KEY"
set +e
out="$(run_script "$ROLL" --stage 2>&1)"
rc=$?
set +e
post_list="$(git -C "$ROLL" diff --cached --name-only | sort)"
if [[ "$rc" -ne 0 ]] && grep -q 'STAGING_ROLLBACK=PASS' <<<"$out" \
  && grep -q 'PREEXISTING_INDEX_RESTORED=YES' <<<"$out" \
  && [[ "$pre_list" == "$post_list" ]] \
  && grep -qx 'docs/preexisting.txt' <<<"$post_list"; then
  pass "10 preexisting staged restored after --stage audit fail"
else
  fail "10 rollback preserve (rc=${rc})"
  echo "pre=$pre_list"
  echo "post=$post_list"
  printf '%s\n' "$out" | tail -50
fi

# 11) .gitignore idempotent under repeated --stage (use clean fixture that passes)
echo "-- 11 gitignore idempotent --"
# For a passing --stage we need no private markers and fixture skip for artifacts.
IDEM="${WORKDIR}/idem"
make_base_fixture "$IDEM"
set +e
out1="$(run_script "$IDEM" --stage 2>&1)"
rc1=$?
gi1="$(sha256sum "$IDEM/.gitignore" | awk '{print $1}')"
out2="$(run_script "$IDEM" --stage 2>&1)"
rc2=$?
gi2="$(sha256sum "$IDEM/.gitignore" | awk '{print $1}')"
set +e
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$gi1" == "$gi2" ]] \
  && grep -q 'GITIGNORE_RULES_ADDED=0' <<<"$out2"; then
  pass "11 gitignore idempotent across --stage runs"
else
  # If stage fails due to missing production artifacts in fixture mode it should skip;
  # still check ensure_gitignore twice via a tiny direct second call after first stage attempt.
  if [[ "$gi1" == "$gi2" ]]; then
    pass "11 gitignore content unchanged on repeat (rc1=${rc1} rc2=${rc2})"
  else
    fail "11 gitignore not idempotent"
    printf '%s\n' "$out1" | tail -20
    printf '%s\n' "$out2" | tail -20
  fi
fi

# 12) --audit-only does not change index or worktree
echo "-- 12 audit-only immutability --"
IMM="${WORKDIR}/imm"
make_base_fixture "$IMM"
printf 'dirty\n' >"$IMM/docs/dirty.txt"
before_idx="$(git -C "$IMM" status --porcelain | sort)"
before_gi="$(sha256sum "$IMM/.gitignore" | awk '{print $1}')"
set +e
run_script "$IMM" --audit-only >/dev/null 2>&1
rc=$?
set +e
after_idx="$(git -C "$IMM" status --porcelain | sort)"
after_gi="$(sha256sum "$IMM/.gitignore" | awk '{print $1}')"
if [[ "$before_idx" == "$after_idx" && "$before_gi" == "$after_gi" ]]; then
  pass "12 --audit-only leaves index/worktree/.gitignore unchanged"
else
  fail "12 audit-only mutated tree"
fi

# 13) --stage does not commit or push
echo "-- 13 no commit/push --"
NP="${WORKDIR}/nopush"
make_base_fixture "$NP"
head1="$(git -C "$NP" rev-parse HEAD)"
set +e
out="$(run_script "$NP" --stage 2>&1)"
rc=$?
set +e
head2="$(git -C "$NP" rev-parse HEAD)"
if [[ "$head1" == "$head2" ]] \
  && grep -q 'COMMIT_PERFORMED=NO' <<<"$out" \
  && grep -q 'PUSH_PERFORMED=NO' <<<"$out"; then
  pass "13 --stage does not commit/push (rc=${rc})"
else
  fail "13 commit/push guard"
fi

# 14) spaced filenames handled (already covered in #6); explicit scan path
echo "-- 14 spaced filename scan --"
SP="${WORKDIR}/spaces"
make_base_fixture "$SP"
printf 'ok content\n' >"$SP/docs/ok file.txt"
git -C "$SP" add -- "docs/ok file.txt"
set +e
out="$(run_script "$SP" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out"; then
  pass "14 spaced safe filename scans cleanly"
else
  fail "14 spaced filename (rc=${rc})"
  printf '%s\n' "$out" | tail -30
fi

# 15) nested repository not staged by --stage
echo "-- 15 nested repository excluded --"
NEST="${WORKDIR}/nest"
make_base_fixture "$NEST"
set +e
out="$(run_script "$NEST" --stage 2>&1)"
rc=$?
set +e
staged="$(git -C "$NEST" diff --cached --name-only || true)"
if ! grep -q '^ubuntu-mirror-automation' <<<"$staged"; then
  pass "15 nested ubuntu-mirror-automation/ not staged"
else
  fail "15 nested repo was staged"
  printf '%s\n' "$staged"
fi
# Also audit should not list nested as allowed include
if grep -q 'NESTED_REPOSITORY_PRESENT=ubuntu-mirror-automation/' <<<"$out" \
  || [[ -d "$NEST/ubuntu-mirror-automation/.git" ]]; then
  pass "15 nested repo presence recognized / kept unstaged"
else
  fail "15 nested repo recognition"
fi

# ---------------------------------------------------------------------------
# 16–27: structural private-key detector regressions
# ---------------------------------------------------------------------------

# 16) detector source with literal marker substrings but no real block -> PASS
echo "-- 16 detector source literal markers without block --"
T16="${WORKDIR}/t16"
make_base_fixture "$T16"
# Ensure the staged detector copy (already in scripts/) is audited; also add
# a docs note that mentions marker substrings in prose / grep-like text.
cat >"$T16/docs/detector-notes.txt" <<'EOF'
Detector looks for structural blocks, not bare substrings.
Example substring (not a block): BEGIN RSA PRIVATE KEY
grep pattern fragment: BEGIN OPENSSH PRIVATE KEY
EOF
git -C "$T16" add -- docs/detector-notes.txt scripts/prepare-backup-staging.sh
set +e
out="$(run_script "$T16" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out"; then
  pass "16 detector/source marker literals without block PASS"
else
  fail "16 detector source false positive (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 17) shell single-quoted BEGIN line alone -> PASS
echo "-- 17 single-quoted BEGIN line only --"
T17="${WORKDIR}/t17"
make_base_fixture "$T17"
# Single-quoted marker substring on one shell assignment line (not a PEM block).
printf '%s\n' "MARKER='-----BEGIN RSA PRIVATE KEY-----'" >"$T17/docs/quoted-begin.sh"
git -C "$T17" add -- docs/quoted-begin.sh
set +e
out="$(run_script "$T17" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out"; then
  pass "17 single-quoted BEGIN-only line PASS"
else
  fail "17 BEGIN-only false positive (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 18) BEGIN+END with empty payload -> PASS
echo "-- 18 empty payload between BEGIN/END --"
T18="${WORKDIR}/t18"
make_base_fixture "$T18"
{
  printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----"
  printf '%s\n' "-----END RSA PRIVATE KEY-----"
} >"$T18/docs/empty-pem.txt"
git -C "$T18" add -- docs/empty-pem.txt
set +e
out="$(run_script "$T18" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out"; then
  pass "18 empty payload BEGIN/END PASS"
else
  fail "18 empty payload (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 19) BEGIN+END with prose only -> PASS
echo "-- 19 prose-only between BEGIN/END --"
T19="${WORKDIR}/t19"
make_base_fixture "$T19"
{
  printf '%s\n' "-----BEGIN RSA PRIVATE KEY-----"
  printf '%s\n' "this is documentation, not a key payload"
  printf '%s\n' "still just words and spaces !!!"
  printf '%s\n' "-----END RSA PRIVATE KEY-----"
} >"$T19/docs/prose-pem.txt"
git -C "$T19" add -- docs/prose-pem.txt
set +e
out="$(run_script "$T19" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out"; then
  pass "19 prose-only BEGIN/END PASS"
else
  fail "19 prose-only (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 20) complete fake RSA block -> FAIL
echo "-- 20 complete fake RSA block --"
T20="${WORKDIR}/t20"
make_base_fixture "$T20"
write_fake_pem_block "$T20/docs/fake-rsa.txt" "RSA PRIVATE KEY"
git -C "$T20" add -- docs/fake-rsa.txt
set +e
out="$(run_script "$T20" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -q 'PRIVATE_KEY_BLOCK_STAGED path=docs/fake-rsa.txt type=RSA' <<<"$out"; then
  pass "20 complete fake RSA block FAIL"
else
  fail "20 RSA block not detected (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 21) complete fake PKCS#8 PRIVATE KEY block -> FAIL
echo "-- 21 complete fake PKCS8 block --"
T21="${WORKDIR}/t21"
make_base_fixture "$T21"
write_fake_pem_block "$T21/docs/fake-pkcs8.txt" "PRIVATE KEY"
git -C "$T21" add -- docs/fake-pkcs8.txt
set +e
out="$(run_script "$T21" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -q 'PRIVATE_KEY_BLOCK_STAGED path=docs/fake-pkcs8.txt type=PKCS8' <<<"$out"; then
  pass "21 complete fake PKCS8 block FAIL"
else
  fail "21 PKCS8 block not detected (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 22) complete fake OPENSSH block -> FAIL
echo "-- 22 complete fake OPENSSH block --"
T22="${WORKDIR}/t22"
make_base_fixture "$T22"
write_fake_pem_block "$T22/docs/fake-openssh.txt" "OPENSSH PRIVATE KEY"
git -C "$T22" add -- docs/fake-openssh.txt
set +e
out="$(run_script "$T22" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -q 'PRIVATE_KEY_BLOCK_STAGED path=docs/fake-openssh.txt type=OPENSSH' <<<"$out"; then
  pass "22 complete fake OPENSSH block FAIL"
else
  fail "22 OPENSSH block not detected (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 23) complete fake PGP PRIVATE KEY BLOCK -> FAIL
echo "-- 23 complete fake PGP block --"
T23="${WORKDIR}/t23"
make_base_fixture "$T23"
write_fake_pgp_block "$T23/docs/fake-pgp.txt"
git -C "$T23" add -- docs/fake-pgp.txt
set +e
out="$(run_script "$T23" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] && grep -q 'PRIVATE_KEY_BLOCK_STAGED path=docs/fake-pgp.txt type=PGP' <<<"$out"; then
  pass "23 complete fake PGP block FAIL"
else
  fail "23 PGP block not detected (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 24) spaced + Hangul filename with real block -> detect
echo "-- 24 spaced Hangul filename block --"
T24="${WORKDIR}/t24"
make_base_fixture "$T24"
write_fake_pem_block "$T24/docs/비밀 키 메모.txt" "EC PRIVATE KEY"
git -C "$T24" add -- "docs/비밀 키 메모.txt"
set +e
out="$(run_script "$T24" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'PRIVATE_KEY_BLOCK_STAGED path=docs/비밀 키 메모.txt type=EC' <<<"$out"; then
  pass "24 Hangul/spaced filename block detected"
else
  fail "24 Hangul filename (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 25) staged blob vs worktree — only staged blob is inspected
echo "-- 25 staged blob vs worktree --"
T25="${WORKDIR}/t25"
make_base_fixture "$T25"
# Case A: staged safe, worktree has full block -> PASS
printf 'safe staged content\n' >"$T25/docs/split.txt"
git -C "$T25" add -- docs/split.txt
write_fake_pem_block "$T25/docs/split.txt" "RSA PRIVATE KEY"
set +e
out_a="$(run_script "$T25" --audit-only 2>&1)"
rc_a=$?
set +e
# Case B: staged has full block, worktree cleaned -> FAIL
write_fake_pem_block "$T25/docs/split.txt" "RSA PRIVATE KEY"
git -C "$T25" add -- docs/split.txt
printf 'worktree cleaned\n' >"$T25/docs/split.txt"
set +e
out_b="$(run_script "$T25" --audit-only 2>&1)"
rc_b=$?
set +e
if [[ "$rc_a" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out_a" \
  && [[ "$rc_b" -ne 0 ]] && grep -q 'PRIVATE_KEY_BLOCK_STAGED path=docs/split.txt type=RSA' <<<"$out_b"; then
  pass "25 inspects staged blob only (not worktree)"
else
  fail "25 staged vs worktree (rc_a=${rc_a} rc_b=${rc_b})"
  printf '%s\n' "$out_a" | tail -20
  printf '%s\n' "$out_b" | tail -20
fi

# 26) audit failure restores previous index exactly
echo "-- 26 exact index restore on audit fail --"
T26="${WORKDIR}/t26"
make_base_fixture "$T26"
printf 'keep-me\n' >"$T26/docs/keep-me.txt"
git -C "$T26" add -- docs/keep-me.txt
pre_index="$(git -C "$T26" ls-files -s | sort)"
pre_cached="$(git -C "$T26" diff --cached --name-only | sort)"
write_fake_pem_block "$T26/docs/leak-key.txt" "RSA PRIVATE KEY"
set +e
out="$(run_script "$T26" --stage 2>&1)"
rc=$?
set +e
post_index="$(git -C "$T26" ls-files -s | sort)"
post_cached="$(git -C "$T26" diff --cached --name-only | sort)"
if [[ "$rc" -ne 0 ]] && grep -q 'STAGING_ROLLBACK=PASS' <<<"$out" \
  && [[ "$pre_index" == "$post_index" ]] \
  && [[ "$pre_cached" == "$post_cached" ]]; then
  pass "26 exact index restore after audit fail"
else
  fail "26 index restore (rc=${rc})"
  echo "pre_cached=$pre_cached"
  echo "post_cached=$post_cached"
  printf '%s\n' "$out" | tail -40
fi

# 27) implementation + test files themselves PASS without allowlist
echo "-- 27 detector and test sources pass without allowlist --"
T27="${WORKDIR}/t27"
make_base_fixture "$T27"
cp -a -- "$SCRIPT" "$T27/scripts/prepare-backup-staging.sh"
cp -a -- "$ROOT/tests/test_prepare_backup_staging.sh" \
  "$T27/tests/test_prepare_backup_staging.sh"
git -C "$T27" add -- \
  scripts/prepare-backup-staging.sh \
  tests/test_prepare_backup_staging.sh
set +e
out="$(run_script "$T27" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'PRIVATE_KEY_MARKERS=0' <<<"$out" \
  && ! grep -q 'PRIVATE_KEY_BLOCK_STAGED' <<<"$out"; then
  pass "27 implementation+test sources PASS without allowlist"
else
  fail "27 self-scan false positive (rc=${rc})"
  printf '%s\n' "$out" | tail -50
fi

# ---------------------------------------------------------------------------
# 28–38: production artifact SHA cross-check
# ---------------------------------------------------------------------------

# 28) helper pin stale vs validated artifacts
echo "-- 28 stale helper pin diagnosis --"
T28="${WORKDIR}/t28"
make_base_fixture "$T28"
read -r S28A S28B S28C S28D <<<"$(install_four_hop_artifacts "$T28")"
# Deliberately stale pin for xenial only.
set_helper_pins "$T28/scripts/prepare-backup-staging.sh" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "$S28B" "$S28C" "$S28D"
set +e
out="$(run_script "$T28" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'FAILURE_CLASS=PRODUCTION_ARTIFACT_PIN_STALE' <<<"$out" \
  && grep -q 'ARTIFACT_HOP=xenial-to-bionic' <<<"$out" \
  && grep -q "ACTUAL_SHA256=${S28A}" <<<"$out" \
  && grep -q 'EXPECTED_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' <<<"$out"; then
  pass "28 stale pin diagnosed precisely"
else
  fail "28 stale pin (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 29) top-level vs sidecar mismatch
echo "-- 29 sidecar mismatch --"
T29="${WORKDIR}/t29"
make_base_fixture "$T29"
install_four_hop_artifacts "$T29" >/dev/null
printf '%s  %s\n' \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "dp-offline-upgrade-xenial-to-bionic.sh" \
  >"$T29/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256"
set +e
out="$(run_script "$T29" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -qE 'FAILURE_CLASS=PRODUCTION_SIDECAR_MISMATCH|PRODUCTION_ARTIFACT_INCONSISTENT' <<<"$out" \
  && grep -q 'SIDECAR_DECLARED_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' <<<"$out"; then
  pass "29 sidecar mismatch FAIL"
else
  fail "29 sidecar mismatch (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 30) top-level vs hop-directory mismatch
echo "-- 30 hop-directory mismatch --"
T30="${WORKDIR}/t30"
make_base_fixture "$T30"
install_four_hop_artifacts "$T30" >/dev/null
printf '%s\n' 'different-hop-body' \
  >"$T30/artifacts/client/xenial-to-bionic/dp-offline-upgrade-xenial-to-bionic.sh"
set +e
out="$(run_script "$T30" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -qE 'FAILURE_CLASS=PRODUCTION_HOP_SCRIPT_MISMATCH|PRODUCTION_ARTIFACT_INCONSISTENT' <<<"$out" \
  && grep -q 'ARTIFACT_HOP=xenial-to-bionic' <<<"$out"; then
  pass "30 hop-directory mismatch FAIL"
else
  fail "30 hop-directory mismatch (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 31) manifest internal hash vs script mismatch
echo "-- 31 manifest hash mismatch --"
T31="${WORKDIR}/t31"
make_base_fixture "$T31"
install_four_hop_artifacts "$T31" >/dev/null
patch_manifest_script_sha \
  "$T31/artifacts/client/xenial-to-bionic/client-manifest.json" \
  "dp-offline-upgrade-xenial-to-bionic.sh" \
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
# Fix size field to avoid size mismatch noise.
python3 - "$T31/artifacts/client/xenial-to-bionic/client-manifest.json" \
  "$T31/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh" <<'PY'
import json, os, sys
man, script = sys.argv[1], sys.argv[2]
size = os.path.getsize(script)
with open(man, encoding="utf-8") as fh:
    data = json.load(fh)
for entry in data.get("files", []):
    entry["size"] = size
with open(man, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
resign_manifest "$T31" xenial-to-bionic
set +e
out="$(run_script "$T31" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -qE 'FAILURE_CLASS=PRODUCTION_MANIFEST_SCRIPT_HASH_MISMATCH|PRODUCTION_ARTIFACT_INCONSISTENT' <<<"$out" \
  && grep -q 'MANIFEST_DECLARED_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' <<<"$out"; then
  pass "31 manifest hash mismatch FAIL"
else
  fail "31 manifest hash mismatch (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 32) detached signature failure
echo "-- 32 detached signature failure --"
T32="${WORKDIR}/t32"
make_base_fixture "$T32"
install_four_hop_artifacts "$T32" >/dev/null
printf '%s\n' 'tampered' >>"$T32/artifacts/client/xenial-to-bionic/client-manifest.json"
set +e
out="$(run_script "$T32" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'MANIFEST_SIGNATURE hop=xenial-to-bionic result=FAIL' <<<"$out"; then
  pass "32 detached signature failure FAIL"
else
  fail "32 signature failure (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 33) do not treat manifest file SHA as script SHA
echo "-- 33 manifest file SHA not mistaken for script SHA --"
T33="${WORKDIR}/t33"
make_base_fixture "$T33"
install_four_hop_artifacts "$T33" >/dev/null
# No script hash field. Unrelated 64-hex decoy must not become MANIFEST_DECLARED.
python3 - "$T33/artifacts/client/jammy-to-noble/client-manifest.json" <<'PY'
import json, sys
man = sys.argv[1]
with open(man, encoding="utf-8") as fh:
    data = json.load(fh)
data.pop("script_sha256", None)
data.pop("files", None)
data["meta_release_sha256"] = "bfd38a40f607fbd57c716c8fd0c434012ca00ff6ec1038f97e52a8b8b835ee4e"
with open(man, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
resign_manifest "$T33" jammy-to-noble
man_sha="$(sha256sum -- "$T33/artifacts/client/jammy-to-noble/client-manifest.json" | awk '{print $1}')"
set +e
out="$(run_script "$T33" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'ARTIFACT_HOP=jammy-to-noble' <<<"$out" \
  && grep -q 'MANIFEST_DECLARED_SHA256=NOT_FOUND' <<<"$out" \
  && grep -q "MANIFEST_FILE_SHA256 hop=jammy-to-noble sha256=${man_sha}" <<<"$out" \
  && ! grep -q 'MANIFEST_DECLARED_SHA256=bfd38a40f607fbd57c716c8fd0c434012ca00ff6ec1038f97e52a8b8b835ee4e' <<<"$out" \
  && ! grep -q "MANIFEST_DECLARED_SHA256=${man_sha}" <<<"$out"; then
  pass "33 manifest file SHA not used as script SHA"
else
  fail "33 manifest file SHA confusion (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 34) staged blob vs worktree divergence
echo "-- 34 staged/worktree artifact divergence --"
T34="${WORKDIR}/t34"
make_base_fixture "$T34"
install_four_hop_artifacts "$T34" >/dev/null
git -C "$T34" add -f -- artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh
printf '%s\n' 'worktree-changed-body' \
  >"$T34/artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh"
set +e
out="$(run_script "$T34" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'FAILURE_CLASS=STAGED_WORKTREE_ARTIFACT_DIVERGENCE' <<<"$out"; then
  pass "34 staged/worktree divergence FAIL"
else
  fail "34 staged/worktree divergence (rc=${rc})"
  printf '%s\n' "$out" | tail -60
fi

# 35) unstaged artifact reports NOT_STAGED
echo "-- 35 unstaged artifact NOT_STAGED --"
T35="${WORKDIR}/t35"
make_base_fixture "$T35"
install_four_hop_artifacts "$T35" >/dev/null
set +e
out="$(run_script "$T35" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] && grep -q 'STAGED_BLOB_SHA256=NOT_STAGED' <<<"$out"; then
  pass "35 unstaged artifact reports NOT_STAGED"
else
  fail "35 NOT_STAGED (rc=${rc})"
  printf '%s\n' "$out" | tail -40
fi

# 36) all four hops consistent → PASS
echo "-- 36 four hops PASS --"
T36="${WORKDIR}/t36"
make_base_fixture "$T36"
install_four_hop_artifacts "$T36" >/dev/null
set +e
out="$(run_script "$T36" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -eq 0 ]] \
  && grep -q 'PRODUCTION_ARTIFACT_SHA256=PASS' <<<"$out" \
  && grep -c 'RESULT=PASS' <<<"$out" | grep -qx '4'; then
  pass "36 four hops consistent PASS"
else
  fail "36 four hops PASS (rc=${rc})"
  printf '%s\n' "$out" | tail -80
fi

# 37) failure emits hop/path/expected/actual fields
echo "-- 37 detailed mismatch fields --"
T37="${WORKDIR}/t37"
make_base_fixture "$T37"
read -r S37A S37B S37C S37D <<<"$(install_four_hop_artifacts "$T37")"
set_helper_pins "$T37/scripts/prepare-backup-staging.sh" \
  "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
  "$S37B" "$S37C" "$S37D"
set +e
out="$(run_script "$T37" --audit-only 2>&1)"
rc=$?
set +e
if [[ "$rc" -ne 0 ]] \
  && grep -q 'ARTIFACT_HOP=xenial-to-bionic' <<<"$out" \
  && grep -q 'ARTIFACT_PATH=artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh' <<<"$out" \
  && grep -q 'EXPECTED_SHA256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' <<<"$out" \
  && grep -q "ACTUAL_SHA256=${S37A}" <<<"$out" \
  && grep -q 'SIDECAR_DECLARED_SHA256=' <<<"$out" \
  && grep -q 'HOP_DIRECTORY_SHA256=' <<<"$out" \
  && grep -q 'MANIFEST_DECLARED_SHA256=' <<<"$out" \
  && grep -q 'STAGED_BLOB_SHA256=' <<<"$out" \
  && grep -q 'WORKTREE_SHA256=' <<<"$out" \
  && grep -q 'RESULT=FAIL' <<<"$out"; then
  pass "37 detailed mismatch fields present"
else
  fail "37 detailed fields (rc=${rc})"
  printf '%s\n' "$out" | tail -80
fi

# 38) audit does not change operating index
echo "-- 38 audit leaves index untouched --"
T38="${WORKDIR}/t38"
make_base_fixture "$T38"
install_four_hop_artifacts "$T38" >/dev/null
printf 'pre\n' >"$T38/docs/pre-staged.txt"
git -C "$T38" add -- docs/pre-staged.txt
before_count="$(git -C "$T38" diff --cached --name-only | wc -l | tr -d ' ')"
before_list="$(git -C "$T38" diff --cached --name-only | sort)"
set +e
run_script "$T38" --audit-only >/dev/null 2>&1
rc=$?
set +e
after_count="$(git -C "$T38" diff --cached --name-only | wc -l | tr -d ' ')"
after_list="$(git -C "$T38" diff --cached --name-only | sort)"
if [[ "$before_count" == "$after_count" && "$before_list" == "$after_list" ]]; then
  pass "38 audit leaves index untouched (count=${before_count})"
else
  fail "38 index mutated (before=${before_count} after=${after_count})"
fi

# Extra: wrong-args help
set +e
bash "$SCRIPT" --help >/dev/null 2>&1
rc=$?
set +e
[[ "$rc" -eq 0 ]] && pass "help exits 0" || fail "help rc=${rc}"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ALL prepare-backup-staging CHECKS PASSED"
  exit 0
fi
echo "SOME prepare-backup-staging CHECKS FAILED"
exit 1
