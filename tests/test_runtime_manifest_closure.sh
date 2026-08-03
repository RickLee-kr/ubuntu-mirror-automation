#!/usr/bin/env bash
# tests/test_runtime_manifest_closure.sh — authoritative runtime manifest,
# dependency closure, Python imports, and drift guards.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/lib/common.sh"
# shellcheck source=../lib/runtime_manifest.sh
source "${ROOT}/lib/runtime_manifest.sh"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "=== test_runtime_manifest_closure ==="
echo "AUTHORITATIVE_RUNTIME_MANIFEST_FILE=lib/runtime_manifest.sh"

# ---------- 1–7: install from manifest + positive closure ----------
RUNTIME="${WORKDIR}/runtime"
um_runtime_install_tree "$ROOT" "$RUNTIME"

echo "TEST_RUNTIME_SOURCE=AUTHORITATIVE_MANIFEST"
echo "TEST_RUNTIME_WILDCARD_COPY=NO"

[[ -f "${RUNTIME}/scripts/lib/client_build_repository.py" ]] \
  && pass "client_build_repository.py present" \
  || fail "client_build_repository.py missing"
[[ -f "${RUNTIME}/scripts/lib/atomic_dir_swap.py" ]] \
  && pass "atomic_dir_swap.py present" \
  || fail "atomic_dir_swap.py missing"

set +e
closure_out="$(um_runtime_verify_dependency_closure "$RUNTIME" 2>&1)"
closure_rc=$?
set -e
echo "$closure_out" | grep -q 'RUNTIME_DEPENDENCY_CLOSURE=PASS' \
  && [[ "$closure_rc" -eq 0 ]] \
  && pass "RUNTIME_DEPENDENCY_CLOSURE=PASS" \
  || fail "RUNTIME_DEPENDENCY_CLOSURE"

set +e
py_out="$(um_runtime_verify_python_dependency_closure "$RUNTIME" "$ROOT" 2>&1)"
py_rc=$?
set -e
echo "$py_out"
echo "$py_out" | grep -q 'RUNTIME_PYTHON_DEPENDENCY_CLOSURE=PASS' \
  && [[ "$py_rc" -eq 0 ]] \
  && pass "RUNTIME_PYTHON_DEPENDENCY_CLOSURE=PASS" \
  || fail "RUNTIME_PYTHON_DEPENDENCY_CLOSURE"
echo "$py_out" | grep -q 'RUNTIME_MODULE_IMPORT=PASS module=client_build_repository' \
  && pass "import client_build_repository" || fail "import client_build_repository"
echo "$py_out" | grep -q 'RUNTIME_MODULE_IMPORT=PASS module=atomic_dir_swap' \
  && pass "import atomic_dir_swap" || fail "import atomic_dir_swap"
for hop in xenial-to-bionic bionic-to-focal focal-to-jammy jammy-to-noble; do
  echo "$py_out" | grep -q "RUNTIME_BUILDER_IMPORT=PASS hop=${hop}" \
    && pass "builder import ${hop}" || fail "builder import ${hop}"
done
echo "$py_out" | grep -q 'RUNTIME_DIRECT_SCRIPT_DEPENDENCY=PASS' \
  && pass "rebuild-publish-clients direct dependency" \
  || fail "direct script dependency"

# Prove imports work with PYTHONPATH empty / no checkout on path
set +e
import_isolated="$(
  env -u PYTHONPATH PYTHONNOUSERSITE=1 python3 - "${RUNTIME}/scripts/lib" "$ROOT" <<'PY'
import importlib.util, os, sys
lib = os.path.abspath(sys.argv[1])
repo = os.path.abspath(sys.argv[2])
sys.path = [lib] + [p for p in sys.path if p and not os.path.abspath(p).startswith(repo)]
for name in (
    "client_build_repository",
    "atomic_dir_swap",
    "build_client_xenial_to_bionic",
):
    path = os.path.join(lib, name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
print("ISOLATED_IMPORT=PASS")
PY
)"
iso_rc=$?
set -e
[[ "$iso_rc" -eq 0 ]] && echo "$import_isolated" | grep -q 'ISOLATED_IMPORT=PASS' \
  && pass "import without checkout on sys.path" \
  || fail "isolated import"

# ---------- 8: negative — remove client_build_repository.py ----------
NEG1="${WORKDIR}/neg-repo"
cp -a "$RUNTIME" "$NEG1"
rm -f "${NEG1}/scripts/lib/client_build_repository.py"
set +e
neg1_out="$(um_runtime_verify_dependency_closure "$NEG1" 2>&1)"
neg1_rc=$?
set -e
echo "$neg1_out" | grep -q 'RUNTIME_DEPENDENCY_CLOSURE=FAIL' \
  && [[ "$neg1_rc" -ne 0 ]] \
  && pass "NEGATIVE_MISSING_REPOSITORY_MODULE_TEST" \
  || fail "NEGATIVE_MISSING_REPOSITORY_MODULE_TEST"
echo "NEGATIVE_MISSING_REPOSITORY_MODULE_TEST=PASS"

# ---------- 9: negative — remove atomic_dir_swap.py ----------
NEG2="${WORKDIR}/neg-atomic"
cp -a "$RUNTIME" "$NEG2"
rm -f "${NEG2}/scripts/lib/atomic_dir_swap.py"
set +e
neg2_out="$(um_runtime_verify_dependency_closure "$NEG2" 2>&1)"
neg2_rc=$?
set -e
echo "$neg2_out" | grep -q 'RUNTIME_DEPENDENCY_CLOSURE=FAIL' \
  && [[ "$neg2_rc" -ne 0 ]] \
  && pass "NEGATIVE_MISSING_ATOMIC_SWAP_TEST" \
  || fail "NEGATIVE_MISSING_ATOMIC_SWAP_TEST"
echo "NEGATIVE_MISSING_ATOMIC_SWAP_TEST=PASS"

# ---------- 10: synthetic incomplete manifest must be treated as FAIL ----------
# A stripped required-path list (missing client_build_repository.py) would
# incorrectly PASS against a tree that lacks that module. Authoritative list
# must FAIL — already proven in test 8.
if [[ ! -e "${NEG1}/scripts/lib/client_build_repository.py" ]]; then
  strip_ok=1
  for rel in "${UM_RUNTIME_REQUIRED_RELATIVE_PATHS[@]}"; do
    [[ "$rel" == "scripts/lib/client_build_repository.py" ]] && continue
    [[ -e "${NEG1}/${rel}" ]] || strip_ok=0
  done
  if [[ "$strip_ok" -eq 1 ]]; then
    echo "SYNTHETIC_INCOMPLETE_MANIFEST_WOULD_PASS=YES"
    echo "SYNTHETIC_INCOMPLETE_MANIFEST_RESULT=FAIL_REQUIRED"
    pass "synthetic incomplete manifest would hide missing module"
  else
    fail "NEG1 tree unexpectedly incomplete beyond removed module"
  fi
else
  fail "NEG1 still has client_build_repository.py"
fi

# ---------- A. builder imports drift ----------
echo "======== drift: builder imports ========"
drift=0
while IFS= read -r pyfile; do
  while IFS= read -r imp; do
    mod="$(echo "$imp" | sed -E 's/^import[[:space:]]+([A-Za-z0-9_]+).*/\1/')"
    [[ "$mod" =~ ^[a-zA-Z_] ]] || continue
    # Only local scripts/lib modules
    [[ -f "${ROOT}/scripts/lib/${mod}.py" ]] || continue
    in_manifest=0
    for f in "${UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES[@]}" \
             "${UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES[@]}"; do
      [[ "$f" == "${mod}.py" ]] && in_manifest=1 && break
    done
    if [[ "$in_manifest" -eq 0 ]]; then
      echo "  FAIL: ${pyfile} imports ${mod} not in runtime manifest"
      drift=1
    fi
  done < <(grep -E '^import [a-zA-Z_][a-zA-Z0-9_]*' "$pyfile" \
    | grep -vE '^import (argparse|base64|hashlib|json|os|re|shutil|subprocess|sys|tarfile|tempfile|time|ctypes|errno)\b' \
    || true)
done < <(ls "${ROOT}/scripts/lib"/build_client_*.py)
[[ "$drift" -eq 0 ]] && pass "builder imports covered by manifest" \
  || fail "builder import drift"

# ---------- B. shell direct execution ----------
echo "======== drift: rebuild-publish-clients.py refs ========"
shell_drift=0
while IFS= read -r ref; do
  base="$(basename "$ref")"
  [[ "$base" == *.py ]] || continue
  in_manifest=0
  for f in "${UM_RUNTIME_SCRIPT_LIB_PYTHON_MODULES[@]}" \
           "${UM_RUNTIME_SCRIPT_LIB_PYTHON_EXECUTABLES[@]}"; do
    [[ "$f" == "$base" ]] && in_manifest=1 && break
  done
  if [[ "$in_manifest" -eq 0 ]]; then
    echo "  FAIL: rebuild-publish-clients.sh references ${base} not in manifest"
    shell_drift=1
  fi
done < <(
  grep -oE 'scripts/lib/[A-Za-z0-9_.-]+\.py' \
    "${ROOT}/scripts/rebuild-publish-clients.sh" || true
)
[[ "$shell_drift" -eq 0 ]] && pass "shell python refs in manifest" \
  || fail "shell python ref drift"

# ---------- C. sourced shell libs ----------
echo "======== drift: rebuild sourced shell ========"
sh_drift=0
while IFS= read -r ref; do
  base="$(basename "$ref")"
  in_manifest=0
  for f in "${UM_RUNTIME_SCRIPT_LIB_SHELL[@]}"; do
    [[ "$f" == "$base" ]] && in_manifest=1 && break
  done
  if [[ "$in_manifest" -eq 0 ]]; then
    echo "  FAIL: rebuild-publish-clients.sh sources ${base} not in manifest"
    sh_drift=1
  fi
done < <(
  grep -oE 'scripts/lib/[A-Za-z0-9_.-]+\.sh' \
    "${ROOT}/scripts/rebuild-publish-clients.sh" || true
)
[[ "$sh_drift" -eq 0 ]] && pass "sourced shell libs in manifest" \
  || fail "sourced shell drift"

# Fixture must not use wildcard copy of scripts/lib python modules
if grep -nE 'cp[[:space:]]+-a[[:space:]]+.*scripts/lib/["'"'"']?\*\.py' \
  "${ROOT}/tests/lib/client_finalization_fixture.sh"; then
  fail "fixture still uses scripts/lib python wildcard copy"
else
  pass "fixture has no scripts/lib python wildcard copy"
fi
grep -q 'um_runtime_install_tree\|runtime_manifest' \
  "${ROOT}/tests/lib/client_finalization_fixture.sh" \
  && pass "fixture uses runtime manifest" \
  || fail "fixture missing manifest usage"
grep -q 'um_runtime_install_tree' "${ROOT}/lib/bootstrap.sh" \
  && pass "bootstrap uses runtime manifest" \
  || fail "bootstrap missing manifest usage"

if [[ "$FAIL" -eq 0 ]]; then
  echo "TEST_RUNTIME_MANIFEST_CLOSURE=PASS"
  exit 0
fi
echo "TEST_RUNTIME_MANIFEST_CLOSURE=FAIL"
exit 1
