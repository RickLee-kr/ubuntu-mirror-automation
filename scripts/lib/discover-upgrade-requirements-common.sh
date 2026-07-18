#!/usr/bin/env bash
# discover-upgrade-requirements-common.sh — shared helpers for upgrade discovery.
# Compatible with Bash 4.3+ / Ubuntu 16.04. Sourced by the CLI and tests.
# shellcheck disable=SC2034

set -uo pipefail
export LC_ALL=C
export LANG=C

DUR_SCRIPT_VERSION="1.0.0"
DUR_SCHEMA_VERSION="1.0"

DUR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUR_PY="${DUR_LIB_DIR}/discover_upgrade_requirements.py"
# Allow tests to inject a stub recorder via DUR_PROXY_PY=...
DUR_PROXY_PY="${DUR_PROXY_PY:-${DUR_LIB_DIR}/discover_upgrade_http_proxy.py}"

# Optional root override for fixture tests (prepended to host paths).
DUR_HOST_ROOT="${DUR_HOST_ROOT:-}"

# Max file size to hash during inventory (bytes). Larger files skip hash.
DUR_HASH_MAX_BYTES="${DUR_HASH_MAX_BYTES:-1048576}"

dur_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

dur_log() {
  local level="$1"; shift
  printf '[%s] %s\n' "$level" "$*" >&2
}

dur_utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

dur_hostpath() {
  local p="$1"
  if [[ -n "${DUR_HOST_ROOT}" ]]; then
    if [[ "$p" == /* ]]; then
      printf '%s%s' "${DUR_HOST_ROOT}" "$p"
    else
      printf '%s/%s' "${DUR_HOST_ROOT}" "$p"
    fi
  else
    printf '%s' "$p"
  fi
}

dur_require_python() {
  command -v python3 >/dev/null 2>&1 || dur_die "python3 is required"
  [[ -f "$DUR_PY" ]] || dur_die "missing helper: $DUR_PY"
  [[ -f "$DUR_PROXY_PY" ]] || dur_die "missing helper: $DUR_PROXY_PY"
  # Clear error (no traceback) if the interpreter cannot parse helpers (e.g. old f-strings).
  if ! python3 - "$DUR_PY" "$DUR_PROXY_PY" <<'PY'
import sys
if sys.version_info < (3, 5):
    sys.stderr.write(
        "ERROR: discover-upgrade-requirements requires Python 3.5+\n"
        "Found: Python %s.%s.%s\n" % sys.version_info[:3]
    )
    sys.exit(2)
for path in sys.argv[1:]:
    try:
        # LC_ALL=C makes locale encoding ASCII; always read helpers as UTF-8.
        with open(path, "rb") as fh:
            src = fh.read().decode("utf-8")
        compile(src, path, "exec")
    except SyntaxError as exc:
        sys.stderr.write(
            "ERROR: %s is not compatible with this Python (%s.%s.%s)\n"
            "  %s:%s: %s\n"
            "  Ubuntu 16.04 needs Python 3.5-compatible syntax (no f-strings).\n"
            % (path, sys.version_info[0], sys.version_info[1], sys.version_info[2],
               path, exc.lineno, exc.msg)
        )
        sys.exit(2)
    except Exception as exc:
        sys.stderr.write("ERROR: failed to load %s: %s\n" % (path, exc))
        sys.exit(2)
PY
  then
    return 1
  fi
}

dur_py() {
  dur_require_python || return 1
  python3 "$DUR_PY" "$@"
}

dur_hop_name() {
  local out err
  err="$(mktemp)"
  if ! out="$(dur_py hop-name --from-os "$1" --to-os "$2" 2>"$err")"; then
    if grep -q 'unsupported hop\|unknown Ubuntu release\|ValueError' "$err" 2>/dev/null; then
      dur_die "unsupported upgrade hop: $1 -> $2"
    fi
    cat "$err" >&2 || true
    rm -f "$err"
    dur_die "failed to resolve hop name for $1 -> $2"
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

dur_normalize_version() {
  local v="$1"
  case "${v,,}" in
    xenial|16.04) printf '16.04' ;;
    bionic|18.04) printf '18.04' ;;
    focal|20.04) printf '20.04' ;;
    jammy|22.04) printf '22.04' ;;
    noble|24.04) printf '24.04' ;;
    *)
      if [[ "$v" =~ ([0-9]+\.[0-9]+) ]]; then
        dur_normalize_version "${BASH_REMATCH[1]}"
      else
        dur_die "unknown Ubuntu release: $v"
      fi
      ;;
  esac
}

dur_state_file() {
  printf '%s/upgrade-discovery/.discovery-state.json' "${DUR_OUTPUT_DIR}"
}

dur_root_dir() {
  printf '%s/upgrade-discovery' "${DUR_OUTPUT_DIR}"
}

dur_hop_dir() {
  printf '%s/%s' "$(dur_root_dir)" "${DUR_HOP}"
}

dur_json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

dur_write_json_file() {
  local path="$1"
  local content="$2"
  local tmp
  tmp="${path}.tmp.$$"
  printf '%s\n' "$content" >"$tmp"
  mv -f "$tmp" "$path"
}

dur_load_state() {
  local sf
  sf="$(dur_state_file)"
  [[ -f "$sf" ]] || return 1
  DUR_FROM_OS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("from_os",""))' "$sf")"
  DUR_TO_OS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("to_os",""))' "$sf")"
  DUR_HOP="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("hop",""))' "$sf")"
  DUR_PHASE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("phase",""))' "$sf")"
  DUR_OUTPUT_DIR="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("output_dir",""))' "$sf")"
  # Prefer explicit env/CLI output-dir if already set and state is under it
  return 0
}

dur_save_state() {
  local sf root
  root="$(dur_root_dir)"
  mkdir -p "$root"
  sf="$(dur_state_file)"
  dur_write_json_file "$sf" "$(cat <<EOF
{
  "schema_version": "$(dur_json_escape "$DUR_SCHEMA_VERSION")",
  "script_version": "$(dur_json_escape "$DUR_SCRIPT_VERSION")",
  "output_dir": "$(dur_json_escape "$DUR_OUTPUT_DIR")",
  "from_os": "$(dur_json_escape "$DUR_FROM_OS")",
  "to_os": "$(dur_json_escape "$DUR_TO_OS")",
  "hop": "$(dur_json_escape "$DUR_HOP")",
  "phase": "$(dur_json_escape "$DUR_PHASE")",
  "updated_at": "$(dur_utc_now)"
}
EOF
)"
}

dur_write_run_json() {
  local hop_dir status
  hop_dir="$(dur_hop_dir)"
  status="${1:-$DUR_PHASE}"
  mkdir -p "$hop_dir"
  dur_write_json_file "${hop_dir}/run.json" "$(cat <<EOF
{
  "schema_version": "$(dur_json_escape "$DUR_SCHEMA_VERSION")",
  "script_version": "$(dur_json_escape "$DUR_SCRIPT_VERSION")",
  "hop": "$(dur_json_escape "$DUR_HOP")",
  "from_os": "$(dur_json_escape "$DUR_FROM_OS")",
  "to_os": "$(dur_json_escape "$DUR_TO_OS")",
  "phase": "$(dur_json_escape "$status")",
  "updated_at": "$(dur_utc_now)"
}
EOF
)"
}

dur_ensure_hop_layout() {
  local hop_dir
  hop_dir="$(dur_hop_dir)"
  mkdir -p \
    "${hop_dir}/before/apt-sources/sources.list.d" \
    "${hop_dir}/before/apt-sources/preferences.d" \
    "${hop_dir}/after/apt-sources/sources.list.d" \
    "${hop_dir}/after/apt-sources/preferences.d" \
    "${hop_dir}/runtime/dist-upgrade" \
    "${hop_dir}/runtime/deb-cache" \
    "${hop_dir}/runtime/partial" \
    "${hop_dir}/runtime/offsets" \
    "${hop_dir}/packages" \
    "${hop_dir}/metadata" \
    "${hop_dir}/diff"
}

dur_copy_if_exists() {
  local src="$1" dest="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dest")"
    if [[ -d "$src" ]]; then
      mkdir -p "$dest"
      cp -a "$src/." "$dest/" 2>/dev/null || true
    else
      cp -a "$src" "$dest" 2>/dev/null || true
    fi
  else
    # Missing source: keep directory placeholders as dirs; only touch files.
    if [[ -d "$dest" || "$dest" == *.d || "$dest" == */ ]]; then
      mkdir -p "$dest"
    else
      mkdir -p "$(dirname "$dest")"
      : >"$dest"
    fi
  fi
}

dur_file_offset() {
  local f="$1"
  if [[ -f "$f" ]]; then
    wc -c <"$f" | tr -d ' '
  else
    printf '0'
  fi
}

dur_slice_from_offset() {
  local src="$1" offset="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  if [[ ! -f "$src" ]]; then
    : >"$dest"
    return 0
  fi
  if [[ "${offset:-0}" -le 0 ]]; then
    cp -a "$src" "$dest" 2>/dev/null || : >"$dest"
    return 0
  fi
  # Prefer tail -c +N (1-based); busybox-safe fallback via dd
  if tail -c "+$((offset + 1))" "$src" >"$dest" 2>/dev/null; then
    return 0
  fi
  dd if="$src" of="$dest" bs=1 skip="$offset" status=none 2>/dev/null || : >"$dest"
}

dur_sha256_file() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  else
    python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f"
  fi
}

dur_should_hash_file() {
  local path="$1" size="$2"
  # Skip obviously huge / binary data paths
  case "$path" in
    *.iso|*.img|*.qcow2|*.vmdk|*.raw|*.squashfs) return 1 ;;
    */opt/aelladata/*/data/*|*/var/lib/docker/*|*/proc/*|*/sys/*) return 1 ;;
  esac
  if [[ "${size:-0}" -gt "${DUR_HASH_MAX_BYTES}" ]]; then
    return 1
  fi
  return 0
}

dur_hash_skip_reason() {
  local path="$1" size="$2"
  case "$path" in
    *.iso|*.img|*.qcow2|*.vmdk|*.raw|*.squashfs) printf 'binary_image_extension'; return ;;
    */opt/aelladata/*/data/*) printf 'large_product_data_path'; return ;;
  esac
  if [[ "${size:-0}" -gt "${DUR_HASH_MAX_BYTES}" ]]; then
    printf 'size_exceeds_%s' "$DUR_HASH_MAX_BYTES"
    return
  fi
  printf 'unspecified'
}

dur_collect_file_manifest() {
  # Fast path: one Python walk. Never call per-file dpkg-query -S (hours on Xenial).
  # Nonzero exit / missing output is a hard inventory failure (do not continue).
  local out="$1"
  shift
  local roots=("$@")
  local args=()
  local r
  mkdir -p "$(dirname "$out")"
  for r in "${roots[@]}"; do
    args+=("$r")
  done
  if ! dur_py collect-file-manifest \
    --output "$out" \
    --host-root "${DUR_HOST_ROOT:-}" \
    --hash-max-bytes "${DUR_HASH_MAX_BYTES:-262144}" \
    --max-entries "${DUR_FILE_MANIFEST_MAX_ENTRIES:-8000}" \
    "${args[@]}"; then
    dur_log ERROR "file-manifest collection failed"
    rm -f "$out" 2>/dev/null || true
    return 1
  fi
  if [[ ! -f "$out" ]]; then
    dur_log ERROR "file-manifest output missing: $out"
    return 1
  fi
  return 0
}

dur_collect_conffiles() {
  local out="$1"
  {
    printf 'path\thash\tpackage\n'
    if [[ -f "$(dur_hostpath /var/lib/dpkg/status)" ]]; then
      python3 - "$(dur_hostpath /var/lib/dpkg/status)" <<'PY'
import sys
path = sys.argv[1]
pkg = None
in_conf = False
with open(path, errors="replace") as f:
    for line in f:
        if line.startswith("Package: "):
            pkg = line.split(":",1)[1].strip()
            in_conf = False
        elif line.startswith("Conffiles:"):
            in_conf = True
        elif in_conf:
            if not line.startswith(" "):
                in_conf = False
                continue
            parts = line.strip().split()
            if len(parts) >= 2:
                print("%s\t%s\t%s" % (parts[0], parts[1], pkg or ""))
            elif parts:
                print("%s\t\t%s" % (parts[0], pkg or ""))
PY
    fi
  } >"$out"
}

dur_collect_installed_packages() {
  local out="$1"
  {
    printf 'package\tversion\tarchitecture\tstatus\n'
    if command -v dpkg-query >/dev/null 2>&1 && [[ -z "${DUR_HOST_ROOT}" ]]; then
      dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Status}\n' 2>/dev/null || true
    elif [[ -f "$(dur_hostpath /tmp/installed-packages.tsv)" ]]; then
      # Fixture override
      tail -n +2 "$(dur_hostpath /tmp/installed-packages.tsv)" 2>/dev/null || true
    elif [[ -f "$(dur_hostpath /var/lib/dpkg/status)" ]]; then
      python3 - "$(dur_hostpath /var/lib/dpkg/status)" <<'PY'
import sys
pkg=ver=arch=status=""
def flush():
    if pkg:
        print("%s\t%s\t%s\t%s" % (pkg, ver, arch, status))
with open(sys.argv[1], errors="replace") as f:
    for line in f:
        if line.startswith("Package: "):
            flush(); pkg=line.split(":",1)[1].strip(); ver=arch=status=""
        elif line.startswith("Version: "):
            ver=line.split(":",1)[1].strip()
        elif line.startswith("Architecture: "):
            arch=line.split(":",1)[1].strip()
        elif line.startswith("Status: "):
            status=line.split(":",1)[1].strip()
        elif not line.strip():
            flush(); pkg=ver=arch=status=""
    flush()
PY
    fi
  } >"$out"
}

dur_collect_inventory() {
  local side="$1"  # before|after
  local hop_dir dest
  hop_dir="$(dur_hop_dir)"
  dest="${hop_dir}/${side}"
  mkdir -p "$dest/apt-sources/sources.list.d" "$dest/apt-sources/preferences.d"

  dur_log INFO "collecting ${side} inventory into ${dest}"

  dur_log INFO "[1/8] os-release / uname"
  if [[ -f "$(dur_hostpath /etc/os-release)" ]]; then
    cp -a "$(dur_hostpath /etc/os-release)" "${dest}/os-release.txt"
  else
    printf 'NAME="Ubuntu"\nVERSION_ID="unknown"\n' >"${dest}/os-release.txt"
  fi
  uname -a >"${dest}/uname.txt" 2>/dev/null || printf 'unknown\n' >"${dest}/uname.txt"

  dur_log INFO "[2/8] installed packages (dpkg-query)"
  dur_collect_installed_packages "${dest}/installed-packages.tsv"

  dur_log INFO "[3/8] apt-mark manual/auto/hold"
  if command -v apt-mark >/dev/null 2>&1 && [[ -z "${DUR_HOST_ROOT}" ]]; then
    apt-mark showmanual >"${dest}/manual-packages.txt" 2>/dev/null || : >"${dest}/manual-packages.txt"
    apt-mark showauto >"${dest}/auto-packages.txt" 2>/dev/null || : >"${dest}/auto-packages.txt"
    apt-mark showhold >"${dest}/held-packages.txt" 2>/dev/null || : >"${dest}/held-packages.txt"
  else
    : >"${dest}/manual-packages.txt"
    : >"${dest}/auto-packages.txt"
    : >"${dest}/held-packages.txt"
    [[ -f "$(dur_hostpath /tmp/manual-packages.txt)" ]] && cp -a "$(dur_hostpath /tmp/manual-packages.txt)" "${dest}/manual-packages.txt"
    [[ -f "$(dur_hostpath /tmp/auto-packages.txt)" ]] && cp -a "$(dur_hostpath /tmp/auto-packages.txt)" "${dest}/auto-packages.txt"
    [[ -f "$(dur_hostpath /tmp/held-packages.txt)" ]] && cp -a "$(dur_hostpath /tmp/held-packages.txt)" "${dest}/held-packages.txt"
  fi

  dur_log INFO "[4/8] apt sources / dpkg status copies"
  dur_copy_if_exists "$(dur_hostpath /var/lib/dpkg/status)" "${dest}/dpkg-status"
  dur_copy_if_exists "$(dur_hostpath /var/lib/apt/extended_states)" "${dest}/extended_states"
  dur_copy_if_exists "$(dur_hostpath /etc/apt/sources.list)" "${dest}/apt-sources/sources.list"
  dur_copy_if_exists "$(dur_hostpath /etc/apt/sources.list.d)" "${dest}/apt-sources/sources.list.d"
  dur_copy_if_exists "$(dur_hostpath /etc/apt/preferences)" "${dest}/apt-sources/preferences"
  dur_copy_if_exists "$(dur_hostpath /etc/apt/preferences.d)" "${dest}/apt-sources/preferences.d"

  dur_log INFO "[5/8] apt-config dump"
  if command -v apt-config >/dev/null 2>&1 && [[ -z "${DUR_HOST_ROOT}" ]]; then
    apt-config dump >"${dest}/apt-config.txt" 2>/dev/null || : >"${dest}/apt-config.txt"
  else
    : >"${dest}/apt-config.txt"
  fi

  dur_log INFO "[6/8] apt archives listing"
  {
    printf 'filename\tsize\tmtime\n'
    local archdir f
    archdir="$(dur_hostpath /var/cache/apt/archives)"
    if [[ -d "$archdir" ]]; then
      find "$archdir" -maxdepth 1 -type f -printf '%f\t%s\t%T@\n' 2>/dev/null || true
    fi
  } >"${dest}/apt-archives-listing.tsv"

  dur_log INFO "[7/8] conffiles from dpkg status"
  dur_collect_conffiles "${dest}/conffiles.tsv"

  dur_log INFO "[8/8] file manifest (/etc /usr/local /opt/aelladata) — progress on stderr"
  if ! dur_collect_file_manifest "${dest}/file-manifest.tsv" /etc /usr/local /opt/aelladata; then
    dur_log ERROR "${side} inventory failed: file-manifest.tsv not produced"
    return 1
  fi

  printf 'package_owned_files=from_dpkg_info_list_index\n' >"${dest}/package-owned-files.note"
  dur_log INFO "${side} inventory complete"
}

dur_record_command() {
  local cmd="$1" rc="$2" started="$3" ended="$4" timed_out="$5"
  local hop_dir tsv
  hop_dir="$(dur_hop_dir)"
  tsv="${hop_dir}/runtime/commands.tsv"
  if [[ ! -f "$tsv" ]]; then
    printf 'started_at\tended_at\treturn_code\ttimeout\tcommand\n' >"$tsv"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$started" "$ended" "$rc" "$timed_out" "$cmd" >>"$tsv"
}

dur_save_log_offsets() {
  local hop_dir off
  hop_dir="$(dur_hop_dir)"
  off="${hop_dir}/runtime/offsets"
  mkdir -p "$off"
  dur_file_offset "$(dur_hostpath /var/log/apt/history.log)" >"${off}/apt-history.offset"
  dur_file_offset "$(dur_hostpath /var/log/apt/term.log)" >"${off}/apt-term.offset"
  dur_file_offset "$(dur_hostpath /var/log/dpkg.log)" >"${off}/dpkg.offset"
  if [[ -f "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.log)" ]]; then
    dur_file_offset "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.log)" >"${off}/proxy-access.offset"
  elif [[ -f "${hop_dir}/runtime/proxy-access.log" ]]; then
    dur_file_offset "${hop_dir}/runtime/proxy-access.log" >"${off}/proxy-access.offset"
  else
    printf '0' >"${off}/proxy-access.offset"
  fi
  if [[ -f "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.err)" ]]; then
    dur_file_offset "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.err)" >"${off}/proxy-error.offset"
  else
    printf '0' >"${off}/proxy-error.offset"
  fi
  # dist-upgrade dir marker
  printf '%s\n' "$(dur_utc_now)" >"${off}/dist-upgrade-start.txt"
}

dur_capture_logs_since_offsets() {
  local hop_dir off
  hop_dir="$(dur_hop_dir)"
  off="${hop_dir}/runtime/offsets"
  mkdir -p "${hop_dir}/runtime"

  dur_slice_from_offset "$(dur_hostpath /var/log/apt/history.log)" \
    "$(cat "${off}/apt-history.offset" 2>/dev/null || echo 0)" \
    "${hop_dir}/runtime/apt-history.log"
  dur_slice_from_offset "$(dur_hostpath /var/log/apt/term.log)" \
    "$(cat "${off}/apt-term.offset" 2>/dev/null || echo 0)" \
    "${hop_dir}/runtime/apt-term.log"
  dur_slice_from_offset "$(dur_hostpath /var/log/dpkg.log)" \
    "$(cat "${off}/dpkg.offset" 2>/dev/null || echo 0)" \
    "${hop_dir}/runtime/dpkg.log"

  # dist-upgrade tree
  if [[ -d "$(dur_hostpath /var/log/dist-upgrade)" ]]; then
    mkdir -p "${hop_dir}/runtime/dist-upgrade"
    cp -a "$(dur_hostpath /var/log/dist-upgrade)/." "${hop_dir}/runtime/dist-upgrade/" 2>/dev/null || true
  else
    mkdir -p "${hop_dir}/runtime/dist-upgrade"
    printf 'no dist-upgrade logs present\n' >"${hop_dir}/runtime/dist-upgrade/README.txt"
  fi

  # proxy logs: prefer our recorder log; else slice apt-cacher-ng
  if [[ -f "${hop_dir}/runtime/proxy-access.log" ]]; then
    : # already accumulating
  elif [[ -f "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.log)" ]]; then
    dur_slice_from_offset "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.log)" \
      "$(cat "${off}/proxy-access.offset" 2>/dev/null || echo 0)" \
      "${hop_dir}/runtime/proxy-access.log"
  else
    touch "${hop_dir}/runtime/proxy-access.log"
  fi

  if [[ -f "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.err)" ]]; then
    dur_slice_from_offset "$(dur_hostpath /var/log/apt-cacher-ng/apt-cacher.err)" \
      "$(cat "${off}/proxy-error.offset" 2>/dev/null || echo 0)" \
      "${hop_dir}/runtime/proxy-error.log"
  else
    touch "${hop_dir}/runtime/proxy-error.log"
  fi
}

dur_preserve_apt_archives() {
  local hop_dir src
  hop_dir="$(dur_hop_dir)"
  src="$(dur_hostpath /var/cache/apt/archives)"
  mkdir -p "${hop_dir}/runtime/deb-cache" "${hop_dir}/runtime/partial"
  if [[ -d "$src" ]]; then
    find "$src" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.udeb' \) -exec cp -an {} "${hop_dir}/runtime/deb-cache/" \; 2>/dev/null || true
  fi
  if [[ -d "${src}/partial" ]]; then
    cp -an "${src}/partial/." "${hop_dir}/runtime/partial/" 2>/dev/null || true
  fi
}

dur_write_apt_keep_downloads() {
  local confd dest
  confd="$(dur_hostpath /etc/apt/apt.conf.d)"
  mkdir -p "$confd" 2>/dev/null || true
  dest="${confd}/99discover-upgrade-keep-downloads"
  {
    printf '// Managed by discover-upgrade-requirements — keep downloaded packages\n'
    printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n'
    printf 'APT::Keep-Downloaded-Packages "true";\n'
  } >"$dest" 2>/dev/null || dur_log WARN "could not write apt keep-downloads config"
}

# APT recorder proxy conf (lexicographically late so it overrides older Proxy snips).
DUR_APT_RECORDER_CONF_NAME="99upgrade-discovery-recorder"

dur_apt_recorder_conf_path() {
  printf '%s/%s' "$(dur_hostpath /etc/apt/apt.conf.d)" "$DUR_APT_RECORDER_CONF_NAME"
}

dur_apt_proxy_backup_dir() {
  printf '%s/runtime/apt-proxy-backup' "$(dur_hop_dir)"
}

dur_backup_apt_proxy_settings() {
  local hop_dir backup confd f
  hop_dir="$(dur_hop_dir)"
  backup="$(dur_apt_proxy_backup_dir)"
  confd="$(dur_hostpath /etc/apt/apt.conf.d)"
  mkdir -p "$backup/conf.d"
  : >"${backup}/proxy-settings-before.txt"
  if command -v apt-config >/dev/null 2>&1 && [[ -z "${DUR_HOST_ROOT}" ]]; then
    apt-config dump 2>/dev/null | grep -i 'Proxy' >"${backup}/proxy-settings-before.txt" || true
    apt-config dump >"${backup}/apt-config-before.txt" 2>/dev/null || true
  fi
  if [[ -d "$confd" ]]; then
    for f in "$confd"/*; do
      [[ -f "$f" ]] || continue
      if grep -qiE 'Acquire::(http|https)::Proxy|Acquire::ftp::Proxy' "$f" 2>/dev/null; then
        cp -a "$f" "${backup}/conf.d/$(basename "$f")" 2>/dev/null || true
      fi
    done
  fi
  printf '%s\n' "$(dur_apt_recorder_conf_path)" >"${backup}/installed-path.txt"
}

dur_install_apt_recorder_proxy() {
  local port="$1"
  local confd dest
  confd="$(dur_hostpath /etc/apt/apt.conf.d)"
  dest="$(dur_apt_recorder_conf_path)"
  mkdir -p "$confd" || {
    dur_log ERROR "cannot create ${confd}"
    return 1
  }
  dur_backup_apt_proxy_settings
  # HTTP only: CONNECT tunnels cannot record full HTTPS URLs/paths/.deb bodies.
  # Route HTTPS DIRECT so we never claim unsupported HTTPS capture works.
  {
    printf '// Managed by discover-upgrade-requirements — do not edit by hand\n'
    printf '// Restored by stop-recording or: discover-upgrade-requirements.sh restore-apt-proxy\n'
    printf 'Acquire::http::Proxy "http://127.0.0.1:%s/";\n' "$port"
    printf 'Acquire::https::Proxy "DIRECT";\n'
  } >"$dest" || {
    dur_log ERROR "failed to write APT recorder proxy config: $dest"
    return 1
  }
  [[ -f "$dest" ]] || {
    dur_log ERROR "APT recorder proxy config missing after write: $dest"
    return 1
  }
  printf '%s\n' "$port" >"$(dur_hop_dir)/runtime/apt-proxy-port.txt"
  dur_log INFO "installed APT proxy config: $dest"
  return 0
}

dur_restore_apt_recorder_proxy() {
  local hop_dir backup dest confd f base
  hop_dir="$(dur_hop_dir 2>/dev/null || true)"
  [[ -n "${hop_dir:-}" ]] || return 0
  backup="$(dur_apt_proxy_backup_dir)"
  dest="$(dur_apt_recorder_conf_path)"
  confd="$(dur_hostpath /etc/apt/apt.conf.d)"

  # Remove our managed conf first.
  if [[ -f "$dest" ]]; then
    rm -f "$dest" || dur_log WARN "could not remove $dest"
  fi
  # Also remove legacy filename from earlier revisions.
  rm -f "${confd}/99discover-upgrade-proxy" 2>/dev/null || true

  # Restore any pre-existing conf.d snippets we backed up (including our prior file).
  if [[ -d "${backup}/conf.d" ]]; then
    for f in "${backup}/conf.d"/*; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f")"
      # Do not re-install our managed recorder conf.
      if [[ "$base" == "$DUR_APT_RECORDER_CONF_NAME" || "$base" == "99discover-upgrade-proxy" ]]; then
        continue
      fi
      cp -a "$f" "${confd}/${base}" 2>/dev/null || \
        dur_log WARN "could not restore apt conf snippet ${base}"
    done
  fi
  printf 'restored\n' >"${hop_dir}/runtime/apt-proxy-restore.txt" 2>/dev/null || true
  dur_log INFO "restored APT proxy settings (removed ${DUR_APT_RECORDER_CONF_NAME})"
  return 0
}

dur_verify_apt_proxy_applied() {
  local port="$1"
  local dest expect got
  dest="$(dur_apt_recorder_conf_path)"
  expect="http://127.0.0.1:${port}/"
  if [[ ! -f "$dest" ]]; then
    dur_log ERROR "APT proxy config not present: $dest"
    return 1
  fi
  if ! grep -q "Acquire::http::Proxy \"${expect}\"" "$dest"; then
    dur_log ERROR "APT proxy config missing expected Acquire::http::Proxy ${expect}"
    return 1
  fi
  if grep -qiE 'Acquire::https::Proxy[[:space:]]+"http://' "$dest"; then
    dur_log ERROR "APT proxy config incorrectly routes HTTPS via recorder (unsupported)"
    return 1
  fi

  if [[ -n "${DUR_HOST_ROOT}" ]]; then
    # Fixture host root: apt-config cannot see injected files; file content is authoritative.
    dur_log INFO "APT proxy config verified under DUR_HOST_ROOT (file-level)"
    return 0
  fi

  if ! command -v apt-config >/dev/null 2>&1; then
    dur_log ERROR "apt-config not available; cannot verify proxy application"
    return 1
  fi
  got="$(apt-config dump 2>/dev/null | awk -F'"' '/Acquire::http::Proxy /{print $2; exit}')"
  if [[ "$got" != "$expect" && "$got" != "${expect%/}" ]]; then
    dur_log ERROR "apt-config dump Acquire::http::Proxy mismatch: got='${got}' expect='${expect}'"
    return 1
  fi
  dur_log INFO "apt-config dump confirms Acquire::http::Proxy=\"${got}\""
  return 0
}

dur_proxy_self_test() {
  # Hit the recorder's built-in self-test endpoint (no upstream origin).
  # Uses a relative request path so http.client cannot "follow" an absolute URL
  # to a different host/port, and so NO_PROXY cannot bypass the recorder.
  local port="$1" logfile="$2"
  local marker rc
  marker="dur-proxy-self-test-$(date -u +%Y%m%d%H%M%S)-$$"
  rc=0
  python3 - "$port" "$logfile" "$marker" <<'PY' || rc=$?
from __future__ import print_function
import sys
import time
from http.client import HTTPConnection

port = int(sys.argv[1])
logfile = sys.argv[2]
marker = sys.argv[3]
path = "/dur-recorder-self-test/%s" % marker
try:
    conn = HTTPConnection("127.0.0.1", port, timeout=10)
    # Relative form against the recorder itself (built-in handler, no upstream).
    conn.request("GET", path, headers={"Host": "127.0.0.1:%s" % port})
    resp = conn.getresponse()
    body = resp.read()
    status = resp.status
    conn.close()
    if status != 200 or body != b"ok":
        raise RuntimeError("unexpected proxy response status=%s body=%r" % (status, body))
except Exception as exc:
    sys.stderr.write("proxy self-test request failed: %s\n" % exc)
    sys.exit(1)
for _ in range(100):
    try:
        with open(logfile, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except Exception:
        text = ""
    if marker in text and ("GET" in text or "TRACE" in text):
        sys.exit(0)
    time.sleep(0.05)
sys.stderr.write("proxy self-test marker not found in access log: %s\n" % marker)
try:
    with open(logfile, "r", encoding="utf-8", errors="replace") as fh:
        sys.stderr.write("--- proxy-access.log ---\n%s\n" % fh.read())
except Exception as exc:
    sys.stderr.write("could not read access log: %s\n" % exc)
sys.exit(1)
PY
  if [[ "$rc" -ne 0 ]]; then
    dur_log ERROR "proxy self-test failed (request not recorded in access log)"
    return 1
  fi
  if ! grep -q "$marker" "$logfile" 2>/dev/null; then
    dur_log ERROR "proxy self-test marker missing from ${logfile}"
    return 1
  fi
  dur_log INFO "proxy self-test recorded in access log"
  return 0
}
dur_start_http_recorder() {
  local hop_dir port pidfile logfile
  hop_dir="$(dur_hop_dir)"
  port="${DUR_PROXY_PORT:-18080}"
  pidfile="${hop_dir}/runtime/proxy.pid"
  logfile="${hop_dir}/runtime/proxy-access.log"
  mkdir -p "${hop_dir}/runtime" "${hop_dir}/runtime/deb-cache"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    dur_log INFO "recorder already running pid=$(cat "$pidfile")"
    if ! dur_install_apt_recorder_proxy "$port"; then
      return 1
    fi
    if ! dur_verify_apt_proxy_applied "$port"; then
      dur_restore_apt_recorder_proxy
      return 1
    fi
    return 0
  fi

  if [[ ! -f "$DUR_PROXY_PY" ]]; then
    dur_log ERROR "proxy helper missing: $DUR_PROXY_PY"
    return 1
  fi

  # Fixture / no-network mode: still install APT proxy config; skip bind + self-test.
  if [[ "${DUR_DRY_RECORDING:-0}" == "1" ]]; then
    touch "$logfile"
    if ! dur_install_apt_recorder_proxy "$port"; then
      return 1
    fi
    if ! dur_verify_apt_proxy_applied "$port"; then
      dur_restore_apt_recorder_proxy
      return 1
    fi
    printf 'dry-recording port=%s http_proxy=installed https=unsupported\n' "$port" \
      >"${hop_dir}/runtime/proxy-mode.txt"
    dur_log INFO "dry-recording: APT proxy config installed (proxy bind skipped)"
    return 0
  fi

  # Free a stale listener on the recorder port (previous crashed run).
  if python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", port))
except Exception:
    sys.exit(1)
finally:
    try:
        s.close()
    except Exception:
        pass
sys.exit(0)
PY
  then
    dur_log WARN "port 127.0.0.1:${port} already in use; attempting to free it"
    if command -v fuser >/dev/null 2>&1; then
      fuser -k "${port}/tcp" >/dev/null 2>&1 || true
    else
      python3 - "$port" <<'PY' || true
import os, signal, subprocess, sys
port = sys.argv[1]
try:
    out = subprocess.check_output(
        ["ss", "-lptn", "sport = :%s" % port],
        stderr=subprocess.DEVNULL, universal_newlines=True)
except Exception:
    sys.exit(0)
for tok in out.replace(",", " ").split():
    if tok.startswith("pid="):
        try:
            os.kill(int(tok.split("=")[1].split(")")[0]), signal.SIGTERM)
        except Exception:
            pass
PY
    fi
    sleep 0.2
  fi

  : >"$logfile"
  python3 "$DUR_PROXY_PY" --listen 127.0.0.1 --port "$port" --log "$logfile" \
    --cache-dir "${hop_dir}/runtime/deb-cache" \
    >"${hop_dir}/runtime/proxy-stdout.log" 2>"${hop_dir}/runtime/proxy-error.log" &
  echo $! >"$pidfile"
  # Wait until OUR process is alive, port accepts, and startup line is in the log
  # (startup is written only after bind — proves this process owns the port).
  local ready=0 i
  for i in $(seq 1 80); do
    if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      break
    fi
    if python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(("127.0.0.1", port))
except Exception:
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
    then
      if grep -q 'discover-upgrade-http-proxy started' "$logfile" 2>/dev/null; then
        ready=1
        break
      fi
    fi
    sleep 0.05
  done
  if [[ "$ready" -ne 1 ]]; then
    dur_log ERROR "failed to start HTTP recorder on 127.0.0.1:${port}"
    if [[ -f "$pidfile" ]]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      rm -f "$pidfile"
    fi
    [[ -f "${hop_dir}/runtime/proxy-error.log" ]] && \
      dur_log ERROR "proxy-error.log: $(head -c 400 "${hop_dir}/runtime/proxy-error.log" | tr '\n' ' ')"
    [[ -f "$logfile" ]] && dur_log ERROR "proxy-access.log: $(head -c 200 "$logfile" | tr '\n' ' ')"
    return 1
  fi

  if ! dur_install_apt_recorder_proxy "$port"; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    return 1
  fi
  if ! dur_verify_apt_proxy_applied "$port"; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    dur_restore_apt_recorder_proxy
    return 1
  fi
  if ! dur_proxy_self_test "$port" "$logfile"; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    dur_restore_apt_recorder_proxy
    return 1
  fi

  printf 'http-recorder port=%s http_proxy=installed https=unsupported\n' "$port" \
    >"${hop_dir}/runtime/proxy-mode.txt"
  dur_log INFO "HTTP recorder listening on 127.0.0.1:${port}; APT http proxy applied"
  return 0
}

dur_stop_http_recorder() {
  local hop_dir pidfile
  hop_dir="$(dur_hop_dir)"
  pidfile="${hop_dir}/runtime/proxy.pid"
  if [[ -f "$pidfile" ]]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
  dur_restore_apt_recorder_proxy
}

dur_phase_rank() {
  case "$1" in
    initialized) echo 1 ;;
    before_failed) echo 1 ;;
    before_collected) echo 2 ;;
    recording) echo 3 ;;
    recording_stopped) echo 4 ;;
    after_collected) echo 5 ;;
    finalized) echo 6 ;;
    *) echo 0 ;;
  esac
}

dur_assert_phase_at_least() {
  local need="$1"
  local have_r need_r
  have_r="$(dur_phase_rank "${DUR_PHASE:-}")"
  need_r="$(dur_phase_rank "$need")"
  if [[ "$have_r" -lt "$need_r" ]]; then
    dur_die "phase ${DUR_PHASE:-none} is before required ${need}; resume from earlier step"
  fi
}

dur_assert_not_finalized() {
  if [[ "${DUR_PHASE:-}" == "finalized" ]]; then
    dur_die "hop ${DUR_HOP} already finalized; refusing overwrite (init a new output-dir or new hop)"
  fi
}

# Registry of known discovery output dirs (absolute paths, one per line).
# Override with DUR_REGISTRY_DIR for tests.
DUR_REGISTRY_DIR="${DUR_REGISTRY_DIR:-/var/tmp/discover-upgrade-requirements}"

dur_registry_file() {
  printf '%s/active-runs.list' "${DUR_REGISTRY_DIR}"
}

dur_abspath() {
  local p="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$p"
  else
    readlink -f "$p" 2>/dev/null || printf '%s' "$p"
  fi
}

dur_register_output_dir() {
  local out reg tmp
  out="$(dur_abspath "$1")"
  mkdir -p "${DUR_REGISTRY_DIR}" 2>/dev/null || true
  reg="$(dur_registry_file)"
  tmp="${reg}.tmp.$$"
  if [[ -f "$reg" ]]; then
    grep -vxF "$out" "$reg" >"$tmp" 2>/dev/null || : >"$tmp"
  else
    : >"$tmp"
  fi
  printf '%s\n' "$out" >>"$tmp"
  mv -f "$tmp" "$reg"
  printf '%s\n' "$out" >"${DUR_REGISTRY_DIR}/last-output-dir"
}

dur_unregister_output_dir() {
  local out reg tmp
  out="$(dur_abspath "$1")"
  reg="$(dur_registry_file)"
  [[ -f "$reg" ]] || return 0
  tmp="${reg}.tmp.$$"
  grep -vxF "$out" "$reg" >"$tmp" 2>/dev/null || : >"$tmp"
  mv -f "$tmp" "$reg"
}

dur_list_active_output_dirs() {
  # Print absolute output dirs that have non-finalized discovery state.
  local reg cand sf phase
  reg="$(dur_registry_file)"
  [[ -f "$reg" ]] || return 0
  while IFS= read -r cand || [[ -n "$cand" ]]; do
    [[ -n "$cand" ]] || continue
    sf="${cand}/upgrade-discovery/.discovery-state.json"
    [[ -f "$sf" ]] || continue
    phase="$(python3 -c 'import json,sys
try:
  print(json.load(open(sys.argv[1])).get("phase",""))
except Exception:
  print("")
' "$sf" 2>/dev/null || true)"
    if [[ -n "$phase" && "$phase" != "finalized" ]]; then
      printf '%s\n' "$cand"
    fi
  done <"$reg"
}

dur_resolve_output_dir() {
  # For init: CLI --output-dir required (no silent /var/tmp default).
  # mode via $1: "init" | "existing" (default existing)
  local mode="${1:-existing}"
  if [[ -n "${DUR_OUTPUT_DIR_CLI:-}" ]]; then
    DUR_OUTPUT_DIR="$(dur_abspath "$DUR_OUTPUT_DIR_CLI")"
    return 0
  fi
  if [[ -n "${DUR_OUTPUT_DIR:-}" ]]; then
    DUR_OUTPUT_DIR="$(dur_abspath "$DUR_OUTPUT_DIR")"
    return 0
  fi
  if [[ "$mode" == "init" ]]; then
    dur_die "init requires --output-dir DIR (example: --output-dir /opt/aelladata/test-run)"
  fi

  local actives active_count
  mapfile -t actives < <(dur_list_active_output_dirs | sort -u)
  active_count="${#actives[@]}"
  # mapfile yields one empty element when no input on some bash versions
  if [[ "$active_count" -eq 1 && -z "${actives[0]:-}" ]]; then
    active_count=0
  fi
  if [[ "$active_count" -eq 1 ]]; then
    DUR_OUTPUT_DIR="${actives[0]}"
    dur_log INFO "using unique active discovery output-dir: ${DUR_OUTPUT_DIR}"
    return 0
  fi
  if [[ "$active_count" -eq 0 ]]; then
    dur_die "no active discovery state found; pass --output-dir DIR (run init first)"
  fi
  {
    printf 'ERROR: ambiguous active discovery runs (%s); pass --output-dir DIR\n' "$active_count"
    local a
    for a in "${actives[@]}"; do
      printf '  - %s\n' "$a"
    done
  } >&2
  exit 1
}

dur_load_active_or_die() {
  dur_resolve_output_dir existing
  local sf
  sf="$(dur_state_file)"
  if [[ ! -f "$sf" ]]; then
    dur_die "no discovery state at ${sf}; run init --output-dir ${DUR_OUTPUT_DIR} first"
  fi
  DUR_FROM_OS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("from_os",""))' "$sf")"
  DUR_TO_OS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("to_os",""))' "$sf")"
  DUR_HOP="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("hop",""))' "$sf")"
  DUR_PHASE="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("phase",""))' "$sf")"
  local stated_out
  stated_out="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("output_dir",""))' "$sf")"
  if [[ -n "$stated_out" ]]; then
    # Prefer state file's output_dir when it matches the selected root.
    local stated_abs
    stated_abs="$(dur_abspath "$stated_out")"
    if [[ "$stated_abs" != "$(dur_abspath "$DUR_OUTPUT_DIR")" ]]; then
      dur_log WARN "state output_dir=${stated_abs} differs from selected ${DUR_OUTPUT_DIR}; using selected"
    fi
  fi
}

# Optional orchestrator hooks (no-op unless DUR_*_HOOK set to a command)
dur_hook() {
  local name="$1"; shift
  local var="DUR_${name}_HOOK"
  if [[ -n "${!var:-}" ]]; then
    dur_log INFO "running hook ${name}"
    # shellcheck disable=SC2086
    eval "${!var}" "$@" || dur_log WARN "hook ${name} failed rc=$?"
  fi
}
