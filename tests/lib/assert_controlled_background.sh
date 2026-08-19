#!/usr/bin/env bash
# tests/lib/assert_controlled_background.sh
# Static policy for offline-hop templates:
#   nohup / disown / arbitrary trailing `&`  -> FAIL
#   package-transition watcher `) &`         -> allowed
#   lxd_run_with_heartbeat PID+wait child    -> allowed
#
# Caller must define pass() / fail(). Does not install EXIT traps.
# shellcheck shell=bash

# Print the lxd_run_with_heartbeat function body (empty if absent).
_acb_extract_lxd_heartbeat_fn() {
  awk '
    BEGIN { depth = 0; keep = 0 }
    /^lxd_run_with_heartbeat\(\)/ { keep = 1 }
    keep {
      print
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") depth--
      }
      if (depth <= 0) exit
    }
  ' "$1"
}

# Print script with lxd_run_with_heartbeat() removed so its `&` is not
# scored by the generic detached-background scan.
_acb_strip_lxd_heartbeat_fn() {
  awk '
    BEGIN { depth = 0; skip = 0 }
    /^lxd_run_with_heartbeat\(\)/ { skip = 1 }
    skip {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") depth--
      }
      if (depth <= 0) { skip = 0; depth = 0 }
      next
    }
    { print }
  ' "$1"
}

# Return 0 if a trailing-`&` line is NOT an allowed watcher/comment exception.
_acb_has_unexpected_ampersand() {
  grep -nE '&\s*$' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*\)[[:space:]]*&[[:space:]]*$|grep|#|forbidden|nohup/background|PACKAGE_TRANSITION_WATCHER' \
    >/dev/null
}

assert_offline_hop_background_policy() {
  local script="$1"
  local work fnfile filtered injected
  work="$(mktemp -d "${TMPDIR:-/tmp}/acb-bg.XXXXXX")"
  fnfile="${work}/lxd_fn"
  filtered="${work}/filtered"
  injected="${work}/injected"

  _acb_extract_lxd_heartbeat_fn "$script" >"$fnfile"
  if [[ ! -s "$fnfile" ]]; then
    fail "lxd_run_with_heartbeat missing from expanded template"
    rm -rf "$work"
    return 0
  fi

  if grep -qE '^[[:space:]]*"\$@" >"\$out" 2>"\$err" &' "$fnfile"; then
    pass "lxd_run_with_heartbeat uses controlled background child"
  else
    fail "lxd_run_with_heartbeat missing controlled background child"
  fi
  if grep -qF 'pid=$!' "$fnfile"; then
    pass "lxd_run_with_heartbeat assigns pid=\$!"
  else
    fail "lxd_run_with_heartbeat missing pid=\$!"
  fi
  if grep -qF 'wait "$pid"' "$fnfile"; then
    pass "lxd_run_with_heartbeat waits for pid"
  else
    fail "lxd_run_with_heartbeat missing wait \"\$pid\""
  fi
  if grep -qF 'rc=$?' "$fnfile" && grep -qF 'return "$rc"' "$fnfile"; then
    pass "lxd_run_with_heartbeat returns child rc"
  else
    fail "lxd_run_with_heartbeat does not preserve child rc"
  fi

  _acb_strip_lxd_heartbeat_fn "$script" >"$filtered"
  if grep -qE '^lxd_run_with_heartbeat\(\)' "$filtered"; then
    fail "failed to isolate lxd_run_with_heartbeat from generic & scan"
  fi

  if grep -nE '^\s*nohup |disown' "$filtered"; then
    fail "nohup/disown bypass present"
  elif _acb_has_unexpected_ampersand "$filtered"; then
    grep -nE '&\s*$' "$filtered" \
      | grep -vE '^[0-9]+:[[:space:]]*\)[[:space:]]*&[[:space:]]*$|grep|#|forbidden|nohup/background|PACKAGE_TRANSITION_WATCHER' \
      || true
    fail "unexpected background bypass present"
  else
    pass "no client nohup/disown; watcher-only and LXD heartbeat background allowed"
  fi

  cp "$script" "$injected"
  printf '\nsleep 999 &\n' >>"$injected"
  _acb_strip_lxd_heartbeat_fn "$injected" >"$filtered"
  if _acb_has_unexpected_ampersand "$filtered"; then
    pass "arbitrary sleep 999 & still rejected"
  else
    fail "arbitrary sleep 999 & was not rejected"
  fi

  cp "$script" "$injected"
  printf '\nnohup true &\n' >>"$injected"
  if grep -qE '^\s*nohup |disown' "$injected"; then
    pass "nohup remains rejected"
  else
    fail "nohup was not rejected"
  fi

  cp "$script" "$injected"
  printf '\ndisown\n' >>"$injected"
  if grep -qE '^\s*nohup |disown' "$injected"; then
    pass "disown remains rejected"
  else
    fail "disown was not rejected"
  fi

  rm -rf "$work"
}
