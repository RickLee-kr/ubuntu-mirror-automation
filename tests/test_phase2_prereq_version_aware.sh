#!/usr/bin/env bash
# Prerequisite install skip must be version-aware (never package-name-only).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREREQ_LIB="${ROOT}/client/lib/dp-phase2-ubuntu-prerequisites.sh"
FAIL=0
PASS=0
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

echo "======== test_phase2_prereq_version_aware ========"

bash -n "$PREREQ_LIB" && pass "bash -n prereq lib" || fail "bash -n prereq lib"

build_tiny_deb() {
  local dest="$1" package="$2" version="${3:-1}" depends="${4:-}"
  local work debian
  work="$(mktemp -d "${WORKDIR}/deb.XXXXXX")"
  debian="${work}/DEBIAN"
  mkdir -p "$debian" "${work}/usr/share/doc/${package}"
  printf 'fixture\n' >"${work}/usr/share/doc/${package}/README"
  {
    echo "Package: ${package}"
    echo "Version: ${version}"
    echo "Architecture: all"
    echo "Maintainer: fixture@example.com"
    echo "Description: fixture ${package}"
    [[ -n "$depends" ]] && echo "Depends: ${depends}"
  } >"${debian}/control"
  dpkg-deb -Zgzip --build "$work" "$dest" >/dev/null
  rm -rf "$work"
}

write_yes_contract() {
  local tar="$1" count="$2"
  local sha
  sha="$(sha256sum "$tar" | awk '{print $1}')"
  echo "${sha}  phase2-ubuntu-prerequisites.tar.gz" >"${tar}.sha256"
  cat >"${tar%.tar.gz}.state" <<EOF
PHASE2_PREREQ_REQUIRED=YES
PHASE2_PREREQ_PACKAGE_COUNT=${count}
PHASE2_PREREQ_BUILD=PASS
PHASE2_PREREQ_PUBLICATION=PASS
PHASE2_PREREQ_ARTIFACT=phase2-ubuntu-prerequisites.tar.gz
PHASE2_PREREQ_SHA256=${sha}
EOF
  printf '{"package_count": %s, "sha256": "%s"}\n' "$count" "$sha" \
    >"$(dirname "$tar")/phase2-ubuntu-prerequisites.manifest.json"
  printf '%s\n' "$sha"
}

make_bin() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"${bin}/dpkg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "--compare-versions" ]]; then
  exec /usr/bin/dpkg "$@"
fi
echo "DPKG_CALL $*" >>"${DPKG_LOG}"
exit 0
EOF
  cat >"${bin}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
pkg=""
for arg in "$@"; do
  case "$arg" in
    -W|-f=*) continue ;;
    *) pkg="$arg" ;;
  esac
done
if [[ "$*" == *'${Status}'* ]]; then
  if [[ -n "${INSTALLED_VERSION:-}" ]]; then
    echo "install ok installed"
    exit 0
  fi
  exit 1
fi
if [[ "$*" == *'${Version}'* ]]; then
  if [[ -n "${INSTALLED_VERSION:-}" ]]; then
    printf '%s\n' "$INSTALLED_VERSION"
    exit 0
  fi
  exit 1
fi
exit 1
EOF
  cat >"${bin}/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${bin}/dpkg" "${bin}/dpkg-query" "${bin}/apt-get"
}

pack_foo() {
  local dest_dir="$1" version="$2" depends="${3:-}"
  mkdir -p "${dest_dir}/debs"
  build_tiny_deb "${dest_dir}/debs/foo_${version}_all.deb" foo "$version" "$depends"
  printf 'foo_%s_all.deb\n' "$version" >"${dest_dir}/install-order.txt"
  tar -C "$dest_dir" -czf "${dest_dir}/phase2-ubuntu-prerequisites.tar.gz" \
    install-order.txt debs
}

BIN="${WORKDIR}/bin"
make_bin "$BIN"

run_case() {
  local art_dir="$1"
  local tar="${art_dir}/phase2-ubuntu-prerequisites.tar.gz"
  PATH="${BIN}:$PATH"
  export DPKG_LOG
  PHASE2_PREREQ_ARTIFACT="$tar"
  PHASE2_PREREQ_STATE="${tar%.tar.gz}.state"
  PHASE2_PREREQ_MANIFEST="${art_dir}/phase2-ubuntu-prerequisites.manifest.json"
  # shellcheck source=/dev/null
  source "$PREREQ_LIB"
  dp2_validate_apt_dependency_graph() { return 0; }
  dp2_install_phase2_ubuntu_prerequisites
  echo RC=$?
}

# D1. Artifact foo=2.1, installed foo=2.1 => skip
D1="${WORKDIR}/d1"
pack_foo "$D1" 2.1
write_yes_contract "${D1}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d1-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=2.1
  export INSTALLED_VERSION
  run_case "$D1"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED package=foo version=2.1' \
  && echo "$OUT" | grep -q 'RC=0' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && pass "D1 exact same version is skipped" \
  || fail "D1: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# D2. Artifact foo=2.1, installed foo=1.5 => must install
D2="${WORKDIR}/d2"
pack_foo "$D2" 2.1
write_yes_contract "${D2}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d2-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=1.5
  export INSTALLED_VERSION
  run_case "$D2"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_INSTALL_NEEDED package=foo installed=1.5 selected=2.1' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && grep -q 'DPKG_CALL' "$DPKG_LOG" \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED' \
  && pass "D2 older installed version is not skipped" \
  || fail "D2: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# D3. Installed newer than artifact => fail closed, never name-only skip
D3="${WORKDIR}/d3"
pack_foo "$D3" 2.1
write_yes_contract "${D3}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d3-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=3.0
  export INSTALLED_VERSION
  run_case "$D3"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_VERSION_CONFLICT package=foo installed=3.0 selected=2.1' \
  && echo "$OUT" | grep -q 'RC=1' \
  && [[ ! -s "$DPKG_LOG" ]] \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED' \
  && pass "D3 newer installed version fail-closes (no silent skip/downgrade)" \
  || fail "D3: ${OUT} dpkg=$(cat "$DPKG_LOG")"

# D4. Versioned dependency would be unsatisfied by installed version
D4="${WORKDIR}/d4"
pack_foo "$D4" 2.1 "bar (>= 2.0)"
write_yes_contract "${D4}/phase2-ubuntu-prerequisites.tar.gz" 1 >/dev/null
DPKG_LOG="${WORKDIR}/d4-dpkg.log"
: >"$DPKG_LOG"
set +e
OUT="$(
  INSTALLED_VERSION=1.5
  export INSTALLED_VERSION
  run_case "$D4"
)"
set -e
echo "$OUT" | grep -q 'PHASE2_PREREQ_INSTALL_NEEDED' \
  && echo "$OUT" | grep -q 'PHASE2_PREREQ_DPKG=PASS' \
  && echo "$OUT" | grep -q 'RC=0' \
  && grep -q 'DPKG_CALL' "$DPKG_LOG" \
  && ! echo "$OUT" | grep -q 'PHASE2_PREREQ_ALREADY_INSTALLED' \
  && pass "D4 older installed version is not false ALREADY_INSTALLED" \
  || fail "D4: ${OUT} dpkg=$(cat "$DPKG_LOG")"

echo "SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
