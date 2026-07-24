#!/usr/bin/env bash
# Read-only evidence collector for Xenial→Bionic upgrade comparison.
# Compatible with Bash 4.3 (Ubuntu 16.04).
#
# Usage (on internet-upgraded OR offline-upgraded VM, as root preferred):
#   sudo bash collect-xenial-bionic-upgrade-baseline.sh [output-dir]
#
# Does NOT install/remove packages, does NOT reboot, does NOT alter apt sources.
set -euo pipefail

OUT_BASE="${1:-/tmp/xenial-bionic-upgrade-evidence}"
TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%Y%m%dT%H%M%S)"
HOST="$(hostname 2>/dev/null || echo unknown)"
OUT_DIR="${OUT_BASE%/}/${HOST}-${TS}"
mkdir -p "$OUT_DIR"

log() { printf '%s\n' "$*" >&2; }

run_capture() {
  # run_capture <outfile> <command...>
  local outfile="$1"
  shift
  set +e
  {
    printf '+ %s\n' "$*"
    "$@"
  } >"$outfile" 2>&1
  local rc=$?
  set -e
  printf 'rc=%s\n' "$rc" >>"$outfile"
  return 0
}

copy_if_exists() {
  local src="$1"
  local dest="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest" 2>/dev/null || true
  fi
}

log "Collecting read-only upgrade evidence into ${OUT_DIR}"

# Identity / OS
run_capture "$OUT_DIR/os-release.txt" cat /etc/os-release
run_capture "$OUT_DIR/lsb-release.txt" cat /etc/lsb-release
run_capture "$OUT_DIR/uname.txt" uname -a
run_capture "$OUT_DIR/cmdline.txt" cat /proc/cmdline

# Package / apt state
run_capture "$OUT_DIR/dpkg-query.tsv" \
  dpkg-query -W -f '${Package}\t${Version}\t${Status}\t${Architecture}\n'
run_capture "$OUT_DIR/dpkg-audit.txt" dpkg --audit
run_capture "$OUT_DIR/apt-mark-hold.txt" apt-mark showhold
run_capture "$OUT_DIR/apt-get-check.txt" apt-get check
run_capture "$OUT_DIR/apt-cache-policy-core.txt" \
  bash -c 'for p in libc6 libc-bin systemd systemd-sysv libsystemd0 udev libudev1 dbus initramfs-tools busybox-initramfs linux-generic linux-image-generic grub-pc grub-pc-bin ubuntu-minimal ubuntu-server apt dpkg openssh-server ifupdown netplan.io; do echo "==== $p ===="; apt-cache policy "$p" 2>&1; done'

# Sources
copy_if_exists /etc/apt/sources.list "$OUT_DIR/apt/sources.list"
if [[ -d /etc/apt/sources.list.d ]]; then
  mkdir -p "$OUT_DIR/apt/sources.list.d"
  cp -a /etc/apt/sources.list.d/. "$OUT_DIR/apt/sources.list.d/" 2>/dev/null || true
fi
if [[ -d /etc/apt/apt.conf.d ]]; then
  mkdir -p "$OUT_DIR/apt/apt.conf.d"
  cp -a /etc/apt/apt.conf.d/. "$OUT_DIR/apt/apt.conf.d/" 2>/dev/null || true
fi

# Boot / kernel / initramfs / grub
run_capture "$OUT_DIR/boot-listing.txt" bash -c 'ls -la /boot 2>&1'
run_capture "$OUT_DIR/boot-sha256.txt" bash -c '
  if [[ -d /boot ]]; then
    # Portable: find + sha256sum; tolerate missing sha256sum
    if command -v sha256sum >/dev/null 2>&1; then
      find /boot -type f -maxdepth 1 -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null
    else
      find /boot -type f -maxdepth 1 -print 2>/dev/null | sort
    fi
  fi
'
run_capture "$OUT_DIR/modules-tree-summary.txt" bash -c '
  if [[ -d /lib/modules ]]; then
    for d in /lib/modules/*; do
      [[ -d "$d" ]] || continue
      echo "DIR=$d"
      echo "FILE_COUNT=$(find "$d" -type f 2>/dev/null | wc -l)"
      echo "MODULES_DEP=$([ -f "$d/modules.dep" ] && echo present || echo missing)"
    done
  fi
'
run_capture "$OUT_DIR/initramfs-list.txt" bash -c '
  for img in /boot/initrd.img-*; do
    [[ -e "$img" ]] || continue
    echo "==== $img ===="
    if command -v lsinitramfs >/dev/null 2>&1; then
      lsinitramfs "$img" 2>&1 | head -n 200
    else
      echo "lsinitramfs unavailable; size=$(stat -c%s "$img" 2>/dev/null || echo unknown)"
    fi
  done
'
run_capture "$OUT_DIR/grub-cfg-kernels.txt" bash -c '
  for f in /boot/grub/grub.cfg /boot/efi/EFI/*/grub.cfg; do
    [[ -f "$f" ]] || continue
    echo "==== $f ===="
    grep -E "menuentry |linux |initrd " "$f" 2>/dev/null | head -n 200
  done
'

# Network / systemd versions
run_capture "$OUT_DIR/network-config.txt" bash -c '
  echo "==== interfaces ===="
  cat /etc/network/interfaces 2>&1 || true
  echo "==== netplan ===="
  ls -la /etc/netplan 2>&1 || true
  cat /etc/netplan/* 2>&1 || true
  echo "==== resolv.conf ===="
  cat /etc/resolv.conf 2>&1 || true
'
run_capture "$OUT_DIR/systemd-versions.txt" bash -c '
  systemctl --version 2>&1 | head -n 5 || true
  udevadm --version 2>&1 || true
  dpkg-query -W -f "${Package}\t${Version}\n" systemd systemd-sysv udev libudev1 libsystemd0 dbus 2>&1 || true
'

# Dist-upgrade logs (copy, do not truncate)
mkdir -p "$OUT_DIR/dist-upgrade"
for f in main.log apt.log term.log; do
  copy_if_exists "/var/log/dist-upgrade/$f" "$OUT_DIR/dist-upgrade/$f"
done
# Also hop evidence paths used by stellar runner if present
if [[ -d /opt/aelladata/os-upgrade ]]; then
  mkdir -p "$OUT_DIR/os-upgrade-hop"
  find /opt/aelladata/os-upgrade -type f \( -name 'main.log' -o -name 'apt.log' -o -name 'term.log' -o -name 'state.json' \) \
    -exec cp -a {} "$OUT_DIR/os-upgrade-hop/" \; 2>/dev/null || true
fi

# Journal previous boot (best effort)
run_capture "$OUT_DIR/journal-previous-boot.txt" bash -c '
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -b -1 --no-pager 2>&1 | tail -n 400
  else
    echo "journalctl unavailable"
  fi
'

# Manifest meta
{
  echo "collected_at_utc=$TS"
  echo "hostname=$HOST"
  echo "collector=collect-xenial-bionic-upgrade-baseline.sh"
  echo "bash_version=${BASH_VERSION}"
} >"$OUT_DIR/collector-meta.txt"

# Bundle
PARENT="$(dirname "$OUT_DIR")"
BASE="$(basename "$OUT_DIR")"
TAR="${PARENT}/${BASE}.tar.gz"
tar -C "$PARENT" -czf "$TAR" "$BASE"
if command -v sha256sum >/dev/null 2>&1; then
  SUM="$(sha256sum "$TAR" | awk '{print $1}')"
else
  SUM="$(openssl dgst -sha256 "$TAR" 2>/dev/null | awk '{print $NF}')"
fi
printf '%s  %s\n' "$SUM" "$(basename "$TAR")" >"${TAR}.sha256"
log "BUNDLE=$TAR"
log "SHA256=$SUM"
printf '%s\n' "$TAR"
