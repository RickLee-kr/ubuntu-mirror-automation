#!/usr/bin/env bash
# shellcheck shell=bash
# Offline mirror helpers — sourced by ubuntu-offline-mirror.sh and unit tests.
# Safe to source; does not execute commands at load time.

# shellcheck disable=SC2317
if [[ -n "${UOM_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
UOM_LIB_LOADED=1

uom_url_host() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  url="${url%%:*}"
  printf '%s\n' "$url"
}

uom_url_path() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  if [[ "$url" == */* ]]; then
    printf '/%s\n' "${url#*/}"
  else
    printf '/\n'
  fi
}

# Return 0 if host is in allowlist (space/comma separated)
uom_host_allowed() {
  local host="$1"
  local allow="${2:-}"
  local h
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  allow="$(printf '%s' "$allow" | tr '[:upper:]' '[:lower:]' | tr ',' ' ')"
  for h in $allow; do
    [[ -n "$h" ]] || continue
    if [[ "$host" == "$h" ]]; then
      return 0
    fi
  done
  return 1
}

# Extract a Dist stanza from meta-release-lts text into stdout (key: value lines)
uom_extract_dist_stanza() {
  local meta_file="$1"
  local dist="$2"
  local in=0
  local line key
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^Dist:[[:space:]]*(.+)$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$dist" ]]; then
        in=1
        printf '%s\n' "$line"
        continue
      elif [[ "$in" -eq 1 ]]; then
        break
      fi
    fi
    if [[ "$in" -eq 1 ]]; then
      if [[ -z "$line" ]]; then
        break
      fi
      printf '%s\n' "$line"
    fi
  done <"$meta_file"
}

uom_stanza_get() {
  local stanza="$1"
  local key="$2"
  printf '%s\n' "$stanza" | awk -F': ' -v k="$key" '
    $1 == k { sub(/^[^:]+: /,""); print; exit }
  '
}

# Rewrite allowed Ubuntu archive URLs to PUBLIC_BASE_URL local paths.
# http://archive.ubuntu.com/ubuntu/... -> ${PUBLIC_BASE_URL}/ubuntu/...
# http://changelogs.ubuntu.com/...     -> ${PUBLIC_BASE_URL}/offline/<basename> when mapped,
#                                        else keep under /offline/announcements/ if announcement.
uom_rewrite_url() {
  local url="$1"
  local public_base="${2%/}"
  local host path

  host="$(uom_url_host "$url")"
  path="$(uom_url_path "$url")"

  case "$host" in
    archive.ubuntu.com|security.ubuntu.com|old-releases.ubuntu.com)
      # Expect /ubuntu/... paths
      if [[ "$path" == /ubuntu/* ]] || [[ "$path" == /ubuntu ]]; then
        printf '%s%s\n' "$public_base" "$path"
        return 0
      fi
      # Some mirrors use host root differently — map /ubuntu prefix if missing
      printf '%s/ubuntu%s\n' "$public_base" "$path"
      return 0
      ;;
    changelogs.ubuntu.com)
      # Announcements referenced by basename under offline tree
      local base
      base="$(basename "$path")"
      printf '%s/offline/announcements/%s\n' "$public_base" "$base"
      return 0
      ;;
    *)
      # Unknown host — return empty to signal failure
      return 1
      ;;
  esac
}

# Build local meta-release-lts containing only requested dists, with rewritten URLs.
# Args: upstream_file public_base dists...
uom_build_local_meta() {
  local upstream="$1"
  local public_base="$2"
  shift 2
  local dists=("$@")
  local dist stanza line key val newurl first=1
  local required

  for dist in "${dists[@]}"; do
    stanza="$(uom_extract_dist_stanza "$upstream" "$dist")"
    if [[ -z "$stanza" ]]; then
      printf 'ERROR: Dist %s not found in upstream meta-release-lts\n' "$dist" >&2
      return 1
    fi
    for required in UpgradeTool UpgradeToolSignature; do
      val="$(uom_stanza_get "$stanza" "$required")"
      if [[ -z "$val" ]]; then
        printf 'ERROR: %s missing for Dist %s\n' "$required" "$dist" >&2
        return 1
      fi
    done
    if [[ "$first" -eq 0 ]]; then
      printf '\n'
    fi
    first=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^([A-Za-z0-9_-]+):[[:space:]]*(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
          UpgradeTool|UpgradeToolSignature|Release-File|ReleaseNotes|ReleaseNotesHtml)
            if [[ -z "$val" ]]; then
              printf 'ERROR: %s missing for Dist %s\n' "$key" "$dist" >&2
              return 1
            fi
            if ! newurl="$(uom_rewrite_url "$val" "$public_base")"; then
              printf 'ERROR: cannot rewrite URL for %s (%s): %s\n' "$dist" "$key" "$val" >&2
              return 1
            fi
            printf '%s: %s\n' "$key" "$newurl"
            ;;
          *)
            printf '%s\n' "$line"
            ;;
        esac
      else
        printf '%s\n' "$line"
      fi
    done <<<"$stanza"
  done
}

# Validate local meta has no external http hosts in UpgradeTool* fields
uom_local_meta_urls_ok() {
  local meta="$1"
  local public_base="${2%/}"
  local line key val host
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^(UpgradeTool|UpgradeToolSignature|Release-File|ReleaseNotes|ReleaseNotesHtml):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      if [[ "$val" != "${public_base}"* ]]; then
        printf 'external or mismatched URL in %s: %s\n' "$key" "$val" >&2
        return 1
      fi
      host="$(uom_url_host "$val")"
      # host part of PUBLIC_BASE_URL may be hostname — already checked prefix
      if [[ "$val" =~ https?://([^/]+) ]] && [[ "${BASH_REMATCH[1]}" != "$(uom_url_host "$public_base")"* ]]; then
        # Strict: must start with public_base
        :
      fi
    fi
  done <"$meta"
  return 0
}

# Required package names per release (override list when a name is absent in Packages)
uom_required_packages_for() {
  local release="$1"
  case "$release" in
    xenial|bionic|focal|jammy|noble)
      printf '%s\n' \
        ubuntu-minimal \
        ubuntu-standard \
        ubuntu-server \
        update-manager-core \
        ubuntu-release-upgrader-core \
        linux-generic \
        linux-image-generic \
        linux-headers-generic
      ;;
    *)
      printf 'unknown release: %s\n' "$release" >&2
      return 1
      ;;
  esac
}

# List all suite names for releases x suffixes
uom_all_suites() {
  local releases="$1"
  local suffixes="$2"
  local r s
  for r in $releases; do
    printf '%s\n' "$r"
    for s in $suffixes; do
      [[ -n "$s" ]] || continue
      printf '%s\n' "${r}-${s}"
    done
  done
}

uom_file_sha256() {
  local f="$1"
  sha256sum "$f" | awk '{print $1}'
}

uom_is_probably_html() {
  local f="$1"
  # Avoid embedding binary NUL into bash strings (tarball false positives / warnings)
  if LC_ALL=C grep -a -m1 -E -q '<(!DOCTYPE[[:space:]]+)?[Hh][Tt][Mm][Ll]' \
      < <(head -c 256 "$f" 2>/dev/null | tr -d '\000'); then
    return 0
  fi
  return 1
}
