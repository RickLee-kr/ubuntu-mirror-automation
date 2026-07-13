#!/usr/bin/env bash
# client-setup.sh — Configure an Ubuntu client to use the local mirror
# Supports classic sources.list and Ubuntu 24.04+ deb822 (.sources) formats.
set -euo pipefail

MIRROR_URL=""
MIRROR_IP=""
DRY_RUN=0
FORCE=0
BACKUP_DIR="/var/backups/ubuntu-mirror-client"

usage() {
  cat <<'EOF'
Usage: sudo ./client-setup.sh --mirror-url http://MIRROR_IP [--force] [--dry-run]

Detects Ubuntu release and rewrites apt sources to use the local mirror.
  - Ubuntu 24.04+ with .sources (deb822): updates URIs
  - Older / classic: rewrites /etc/apt/sources.list and .list files

Options:
  --mirror-url URL   e.g. http://10.34.200.20
  --mirror-ip IP     Alias for building http://IP
  --force            Overwrite even if already pointing at mirror
  --dry-run          Show changes only
  --non-interactive  Accepted for CLI compatibility (no prompts today)
  -h, --help
EOF
}

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-url) MIRROR_URL="${2:-}"; shift 2 ;;
      --mirror-ip) MIRROR_IP="${2:-}"; shift 2 ;;
      --force) FORCE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --non-interactive) shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  if [[ -z "$MIRROR_URL" ]] && [[ -n "$MIRROR_IP" ]]; then
    MIRROR_URL="http://${MIRROR_IP}"
  fi
  [[ -n "$MIRROR_URL" ]] || die "--mirror-url is required"
  MIRROR_URL="${MIRROR_URL%/}"
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root"
}

detect_codename() {
  # shellcheck disable=SC1091
  . /etc/os-release
  printf '%s\n' "${VERSION_CODENAME:-}"
}

backup_path() {
  local path="$1"
  local dest
  mkdir -p "$BACKUP_DIR"
  dest="$BACKUP_DIR/$(basename "$path").$(date '+%Y%m%d').bak"
  if [[ -e "$dest" ]]; then
    dest="$BACKUP_DIR/$(basename "$path").$(date '+%Y%m%d-%H%M%S').bak"
  fi
  cp -a "$path" "$dest"
  log "Backup: $dest"
}

rewrite_list_file() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  # Replace common Ubuntu archive hosts with local mirror
  sed -E \
    -e "s|https?://([a-zA-Z0-9.-]+\.)?archive\.ubuntu\.com|${MIRROR_URL}|g" \
    -e "s|https?://security\.ubuntu\.com|${MIRROR_URL}|g" \
    -e "s|https?://([a-z0-9-]+\.)?ubuntu\.com/ubuntu|${MIRROR_URL}/ubuntu|g" \
    "$file" >"$tmp"

  # Ensure path ends with /ubuntu for deb lines that only had host replaced
  # If line is: deb http://IP noble ...  without /ubuntu, fix it
  sed -E -i \
    -e "s|^(deb(-src)?[[:space:]]+${MIRROR_URL})([[:space:]]+)|\\1/ubuntu\\3|g" \
    -e "s|/ubuntu/ubuntu|/ubuntu|g" \
    "$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    log "Unchanged: $file"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would update $file"
    diff -u "$file" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  backup_path "$file"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  log "Updated: $file"
}

rewrite_sources_deb822() {
  local file="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v mirror="$MIRROR_URL" '
    BEGIN { updated=0 }
    /^URIs:/ {
      print "URIs: " mirror "/ubuntu"
      updated=1
      next
    }
    { print }
    END { }
  ' "$file" >"$tmp"

  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
    log "Unchanged: $file"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN would update $file"
    diff -u "$file" "$tmp" || true
    rm -f "$tmp"
    return 0
  fi
  backup_path "$file"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  log "Updated: $file"
}

has_deb822() {
  compgen -G "/etc/apt/sources.list.d/*.sources" >/dev/null 2>&1
}

main() {
  parse_args "$@"
  if [[ "$DRY_RUN" != "1" ]]; then
    require_root
  fi

  local codename
  codename="$(detect_codename)"
  log "Client codename: ${codename:-unknown}"
  log "Mirror URL: ${MIRROR_URL}"

  if has_deb822; then
    log "Detected deb822 .sources format"
    local f
    for f in /etc/apt/sources.list.d/*.sources; do
      [[ -f "$f" ]] || continue
      # Only touch Ubuntu archive sources
      if grep -qiE 'ubuntu\.com|archive\.ubuntu|security\.ubuntu' "$f"; then
        rewrite_sources_deb822 "$f"
      elif [[ "$FORCE" == "1" ]]; then
        rewrite_sources_deb822 "$f"
      fi
    done
  fi

  if [[ -f /etc/apt/sources.list ]]; then
    rewrite_list_file /etc/apt/sources.list
  fi

  local list
  for list in /etc/apt/sources.list.d/*.list; do
    [[ -f "$list" ]] || continue
    if grep -qiE 'ubuntu\.com|archive\.ubuntu|security\.ubuntu' "$list" || [[ "$FORCE" == "1" ]]; then
      rewrite_list_file "$list"
    fi
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN complete"
    exit 0
  fi

  log "Running apt-get update"
  apt-get update
  log "Verify with: apt-cache policy | grep ${MIRROR_URL#http://}"
  log "Or: ./client-validate.sh --mirror-url ${MIRROR_URL}"
}

main "$@"
