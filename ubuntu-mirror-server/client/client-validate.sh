#!/usr/bin/env bash
# client-validate.sh — Client-side mirror connectivity & availability tests
# Based on Setup Guide test-mirror-connectivity.sh, extended for all versions.
set -euo pipefail

MIRROR_URL=""
MIRROR_IP=""
TIMEOUT=10
EXPECT_VERSIONS="xenial bionic focal jammy noble"

usage() {
  cat <<'EOF'
Usage: ./client-validate.sh --mirror-url http://MIRROR_IP
       ./client-validate.sh --mirror-ip 10.34.200.20

Tests ICMP, TCP/80, HTTP Release files, and reports PASS/WARNING/FAIL.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mirror-url) MIRROR_URL="${2:-}"; shift 2 ;;
      --mirror-ip) MIRROR_IP="${2:-}"; shift 2 ;;
      --timeout) TIMEOUT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)
        # Positional IP for guide compatibility
        if [[ -z "$MIRROR_IP" ]] && [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          MIRROR_IP="$1"
          shift
        else
          die "Unknown option: $1"
        fi
        ;;
    esac
  done
  if [[ -z "$MIRROR_URL" ]] && [[ -n "$MIRROR_IP" ]]; then
    MIRROR_URL="http://${MIRROR_IP}"
  fi
  [[ -n "$MIRROR_URL" ]] || die "Provide --mirror-url or --mirror-ip"
  MIRROR_URL="${MIRROR_URL%/}"
  if [[ -z "$MIRROR_IP" ]]; then
    MIRROR_IP="${MIRROR_URL#http://}"
    MIRROR_IP="${MIRROR_IP#https://}"
    MIRROR_IP="${MIRROR_IP%%/*}"
    MIRROR_IP="${MIRROR_IP%%:*}"
  fi
}

PASS=0 WARN=0 FAIL=0
result() {
  local st="$1" name="$2" detail="${3:-}"
  case "$st" in
    PASS) ((PASS++)) || true; printf '[PASS]    %s%s\n' "$name" "${detail:+ — $detail}" ;;
    WARNING) ((WARN++)) || true; printf '[WARNING] %s%s\n' "$name" "${detail:+ — $detail}" ;;
    FAIL) ((FAIL++)) || true; printf '[FAIL]    %s%s\n' "$name" "${detail:+ — $detail}" ;;
  esac
}

main() {
  parse_args "$@"
  printf 'Testing mirror: %s\n\n' "$MIRROR_URL"

  # 1. Ping
  if ping -c 3 -W 5 "$MIRROR_IP" >/dev/null 2>&1; then
    result PASS "ICMP Ping" "$MIRROR_IP"
  else
    result WARNING "ICMP Ping" "may be blocked by firewall"
  fi

  # 2. TCP 80
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${MIRROR_IP}/80" 2>/dev/null; then
    result PASS "TCP Port 80" "reachable"
  else
    result FAIL "TCP Port 80" "not reachable"
  fi

  # 3. HTTP GET noble Release
  local code
  code="$(curl -sS -o /dev/null --max-time "$TIMEOUT" -w '%{http_code}' \
    "${MIRROR_URL}/ubuntu/dists/noble/Release" 2>/dev/null || true)"
  [[ -z "$code" ]] && code="000"
  if [[ "$code" == "200" ]]; then
    result PASS "HTTP GET noble/Release" "200"
  else
    result FAIL "HTTP GET noble/Release" "HTTP $code"
  fi

  # 4. All versions
  local ver available=0
  for ver in $EXPECT_VERSIONS; do
    if curl -sS -f --max-time "$TIMEOUT" \
        "${MIRROR_URL}/ubuntu/dists/${ver}/Release" >/dev/null 2>&1; then
      result PASS "Version $ver" "available"
      ((available++)) || true
    else
      result FAIL "Version $ver" "NOT available"
    fi
  done

  # 5. apt policy (if configured)
  if command -v apt-cache >/dev/null 2>&1; then
    if apt-cache policy 2>/dev/null | grep -q "$MIRROR_IP"; then
      result PASS "apt-cache policy" "mirror in use"
    else
      result WARNING "apt-cache policy" "mirror IP not seen — run client-setup.sh?"
    fi
  fi

  printf '\nSummary: PASS=%s WARNING=%s FAIL=%s (versions %s/5)\n' \
    "$PASS" "$WARN" "$FAIL" "$available"

  if [[ "$FAIL" -gt 0 ]]; then
    exit 2
  fi
  if [[ "$WARN" -gt 0 ]] || [[ "$available" -lt 5 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
