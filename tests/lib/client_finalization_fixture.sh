#!/usr/bin/env bash
# tests/lib/client_finalization_fixture.sh — production-shaped OS Core + signing fixtures
# for real four-hop local-fs client finalization tests.
# shellcheck shell=bash

client_fixture_require() {
  command -v gpg >/dev/null 2>&1 || { echo "gpg required" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; return 1; }
  command -v gzip >/dev/null 2>&1 || { echo "gzip required" >&2; return 1; }
}

# Create ephemeral GPG keys under $1/{selective,signing}
client_fixture_gen_keys() {
  local work="$1"
  local gpg_sel="${work}/gpg-selective"
  local gpg_sign="${work}/gpg-signing"
  mkdir -p "$gpg_sel" "$gpg_sign"
  chmod 700 "$gpg_sel" "$gpg_sign"
  cat >"${gpg_sel}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Fixture Selective Mirror
Name-Email: selective-fixture@local
Expire-Date: 0
%no-protection
%commit
EOF
  cat >"${gpg_sign}/batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Fixture Client Manifest
Name-Email: client-manifest-fixture@local
Expire-Date: 0
%no-protection
%commit
EOF
  gpg --homedir "$gpg_sel" --batch --gen-key "${gpg_sel}/batch" >/dev/null 2>&1
  gpg --homedir "$gpg_sign" --batch --gen-key "${gpg_sign}/batch" >/dev/null 2>&1
  mkdir -p "${work}/selective/keys" "${work}/client-signing"
  gpg --homedir "$gpg_sel" --batch --export --armor \
    >"${work}/selective/keys/ubuntu-mirror-selective.gpg"
  gpg --homedir "$gpg_sign" --batch --export-secret-keys --armor \
    >"${work}/client-signing/private.gpg"
  gpg --homedir "$gpg_sign" --batch --export --armor \
    >"${work}/client-signing/public.gpg"
  chmod 600 "${work}/client-signing/private.gpg"
  chmod 644 "${work}/client-signing/public.gpg"
  gpg --homedir "$gpg_sign" --batch --with-colons --fingerprint \
    | awk -F: '/^fpr:/ {print toupper($10); exit}' \
    >"${work}/client-signing/fingerprint"
  CLIENT_FIXTURE_GPG_SEL="$gpg_sel"
  CLIENT_FIXTURE_GPG_SIGN="$gpg_sign"
}

client_fixture_write_release() {
  local suite="$1" dest="$2"
  cat >"$dest" <<EOF
Origin: Ubuntu
Label: Ubuntu
Suite: ${suite}
Codename: ${suite%%-*}
Architectures: amd64
Components: main restricted universe multiverse
Description: Ubuntu ${suite} fixture
EOF
}

# Populate one hop under selective/hops/<hop>/ubuntu with signed InRelease + Packages + deb
client_fixture_populate_hop() {
  local sel_root="$1"
  local hop="$2"
  local source="$3"
  local target="$4"
  local gpg_sel="$5"
  local ubuntu="${sel_root}/hops/${hop}/ubuntu"
  local suite d

  for suite in "$source" "${source}-updates" "${source}-security" \
               "$target" "${target}-updates" "${target}-security"; do
    d="${ubuntu}/dists/${suite}"
    mkdir -p "${d}/main/binary-amd64"
    client_fixture_write_release "$suite" "${d}/Release"
    gpg --homedir "$gpg_sel" --batch --yes --clearsign \
      -o "${d}/InRelease" "${d}/Release" >/dev/null 2>&1
  done

  python3 - "$ubuntu" "$target" <<'PY'
import gzip, pathlib, sys
ubuntu = pathlib.Path(sys.argv[1])
target = sys.argv[2]
body = (
    b"Package: hello\n"
    b"Version: 2.10\n"
    b"Filename: pool/main/a/hello/hello_2.10_amd64.deb\n"
    b"Size: 1\n"
    b"SHA256: " + (b"0" * 64) + b"\n"
)
for suite in (target, target + "-updates", target + "-security"):
    p = ubuntu / "dists" / suite / "main" / "binary-amd64" / "Packages.gz"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(gzip.compress(body))
deb = ubuntu / "pool/main/a/hello/hello_2.10_amd64.deb"
deb.parent.mkdir(parents=True, exist_ok=True)
deb.write_bytes(b"x")
PY
}

client_fixture_populate_upgrader() {
  local sel_root="$1"
  local codename="$2"
  local gpg_sel="$3"
  local upg_dir="${sel_root}/shared/offline/release-upgraders/${codename}"
  local tmp
  mkdir -p "$upg_dir"
  tmp="$(mktemp -d)"
  printf 'ReleaseAnnouncement %s\n' "$codename" >"${tmp}/ReleaseAnnouncement"
  printf '<html>%s</html>\n' "$codename" >"${tmp}/ReleaseAnnouncement.html"
  ( cd "$tmp" && tar -czf "${upg_dir}/${codename}.tar.gz" ./ReleaseAnnouncement ./ReleaseAnnouncement.html )
  gpg --homedir "$gpg_sel" --batch --yes --detach-sign \
    -o "${upg_dir}/${codename}.tar.gz.gpg" "${upg_dir}/${codename}.tar.gz" >/dev/null 2>&1
  rm -rf "$tmp"
}

# Full four-hop production-shaped selective tree + READY provenance.
client_fixture_build_selective() {
  local work="$1"
  local sel="${work}/selective"
  mkdir -p "${sel}/state" "${sel}/keys"
  client_fixture_require
  client_fixture_gen_keys "$work"

  local hops=(
    "xenial-to-bionic:xenial:bionic"
    "bionic-to-focal:bionic:focal"
    "focal-to-jammy:focal:jammy"
    "jammy-to-noble:jammy:noble"
  )
  local entry hop source target
  for entry in "${hops[@]}"; do
    IFS=: read -r hop source target <<<"$entry"
    client_fixture_populate_hop "$sel" "$hop" "$source" "$target" "$CLIENT_FIXTURE_GPG_SEL"
    client_fixture_populate_upgrader "$sel" "$target" "$CLIENT_FIXTURE_GPG_SEL"
  done

  # READY with package-like provenance fields (64-hex)
  cat >"${sel}/state/READY" <<EOF
selective_plan_checksum=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
discovery_artifact_checksum=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
os_core_provenance_source=PACKAGE_MANIFEST_AND_PAYLOAD_SHA256
EOF
}

# Install a minimal runtime tree mirroring bootstrap layout under $work/runtime
client_fixture_install_runtime() {
  local repo_root="$1"
  local work="$2"
  local runtime="${work}/runtime"
  mkdir -p \
    "${runtime}/usr/local/lib/ubuntu-mirror/scripts/lib" \
    "${runtime}/usr/local/lib/ubuntu-mirror/client/lib" \
    "${runtime}/usr/local/lib/ubuntu-mirror/templates" \
    "${runtime}/var/spool/apt-mirror/.install-cache" \
    "${runtime}/var/spool/apt-mirror/client" \
    "${runtime}/var/spool/apt-mirror/selective" \
    "${runtime}/etc/ubuntu-mirror/client-signing"

  # Copy product scripts needed for rebuild/publish (installed-runtime parity).
  cp -a "${repo_root}/scripts/rebuild-publish-clients.sh" \
    "${runtime}/usr/local/lib/ubuntu-mirror/scripts/"
  cp -a "${repo_root}/scripts/lib/"*.py \
    "${runtime}/usr/local/lib/ubuntu-mirror/scripts/lib/"
  cp -a "${repo_root}/scripts/lib/"*.sh \
    "${runtime}/usr/local/lib/ubuntu-mirror/scripts/lib/" 2>/dev/null || true
  cp -a "${repo_root}/client/"*.sh.in \
    "${runtime}/usr/local/lib/ubuntu-mirror/client/" 2>/dev/null || true
  cp -a "${repo_root}/client/"*.inc \
    "${runtime}/usr/local/lib/ubuntu-mirror/client/" 2>/dev/null || true
  cp -a "${repo_root}/client/lib/"*.sh \
    "${runtime}/usr/local/lib/ubuntu-mirror/client/lib/" 2>/dev/null || true
  # Also copy any nested client helpers required by jammy→noble.
  if [[ -d "${repo_root}/client" ]]; then
    find "${repo_root}/client" -maxdepth 1 -type f \( -name '*.inc' -o -name '*.sh.in' \) \
      -exec cp -a {} "${runtime}/usr/local/lib/ubuntu-mirror/client/" \;
  fi
  for f in stage-dp-phase2.sh stage-dp-phase2-6.5.0.sh; do
    [[ -f "${repo_root}/client/${f}" ]] && \
      cp -a "${repo_root}/client/${f}" "${runtime}/usr/local/lib/ubuntu-mirror/client/"
  done
  if [[ -d "${repo_root}/templates" ]]; then
    cp -a "${repo_root}/templates/." "${runtime}/usr/local/lib/ubuntu-mirror/templates/" 2>/dev/null || true
  fi

  # Place selective + signing into runtime paths.
  cp -a "${work}/selective/." "${runtime}/var/spool/apt-mirror/selective/"
  cp -a "${work}/client-signing/." "${runtime}/etc/ubuntu-mirror/client-signing/"
  chmod 600 "${runtime}/etc/ubuntu-mirror/client-signing/private.gpg"

  CLIENT_FIXTURE_RUNTIME="$runtime"
  CLIENT_FIXTURE_RUNTIME_ROOT="${runtime}/usr/local/lib/ubuntu-mirror"
  CLIENT_FIXTURE_MIRROR_ROOT="${runtime}/var/spool/apt-mirror"
  CLIENT_FIXTURE_SELECTIVE="${runtime}/var/spool/apt-mirror/selective"
  CLIENT_FIXTURE_CLIENT_ROOT="${runtime}/var/spool/apt-mirror/client"
  CLIENT_FIXTURE_SIGNING_DIR="${runtime}/etc/ubuntu-mirror/client-signing"
}
