#!/usr/bin/env bash
set -euo pipefail
ROOT=/var/spool/apt-mirror/mirror/archive.ubuntu.com/ubuntu
COMPS="main restricted universe multiverse"
suites="xenial xenial-updates xenial-security xenial-backports bionic bionic-updates bionic-security bionic-backports focal focal-updates focal-security focal-backports jammy jammy-updates jammy-security jammy-backports noble noble-updates noble-security noble-backports"

fetch() {
  local url="$1" dest="$2"
  local code
  mkdir -p "$(dirname "$dest")"
  code=$(curl -sS -o "${dest}.tmp" -w "%{http_code}" "$url" || echo 000)
  if [[ "$code" == "200" ]]; then
    mv "${dest}.tmp" "$dest"
    chmod 0644 "$dest"
    return 0
  fi
  rm -f "${dest}.tmp"
  return 1
}

for suite in $suites; do
  d="$ROOT/dists/$suite"
  mkdir -p "$d"
  for f in InRelease Release Release.gpg; do
    fetch "http://archive.ubuntu.com/ubuntu/dists/$suite/$f" "$d/$f" || true
  done
  for comp in $COMPS; do
    bd="$d/$comp/binary-amd64"
    mkdir -p "$bd"
    got=0
    for f in Packages.xz Packages.gz Packages; do
      if fetch "http://archive.ubuntu.com/ubuntu/dists/$suite/$comp/binary-amd64/$f" "$bd/$f"; then
        got=1
        break
      fi
    done
    [[ "$got" == "1" ]] || echo "WARN missing packages $suite/$comp"

    # Optional appstream / command-not-found indexes (needed by modern apt-get update)
    dep11="$d/$comp/dep11"
    mkdir -p "$dep11"
    for f in Components-amd64.yml.gz Components-amd64.yml Components-amd64.yml.xz; do
      fetch "http://archive.ubuntu.com/ubuntu/dists/$suite/$comp/dep11/$f" "$dep11/$f" && break || true
    done
    cnf="$d/$comp/cnf"
    mkdir -p "$cnf"
    for f in Commands-amd64.xz Commands-amd64.gz Commands-amd64; do
      fetch "http://archive.ubuntu.com/ubuntu/dists/$suite/$comp/cnf/$f" "$cnf/$f" && break || true
    done
  done
  echo "OK $suite"
done
echo META_DONE
du -sh "$ROOT/dists"
ls "$ROOT/dists" | wc -l
