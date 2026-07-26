# Shared destructive confirmation helpers for offline OS upgrade clients.
# Injected into single-file clients at build / stub-render time.
# Compatible with Bash 4.3+ and safe under `set -Eeuo pipefail`.
#
# Contracts:
# - trim_outer_whitespace: strip leading/trailing space, tab, CR (and other
#   [[:space:]] characters) only; never alter interior whitespace; never log.
# - require_destructive_confirmation EXPECTED:
#     return 0 on accept, return 21 after 3 failures or EOF.
# - Never log the raw user input. Expected phrase may be re-printed.
# - Depends on caller-provided `log LEVEL message` function.

trim_outer_whitespace() {
  # Trim leading/trailing whitespace only (space/tab/CR/[[:space:]]).
  # Interior whitespace is preserved. Result is printed without a trailing newline.
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

require_destructive_confirmation() {
  local expected="${1-}"
  local max_attempts=3
  local attempt=0
  local raw trimmed

  if [[ -z "$expected" ]]; then
    return 21
  fi

  while [[ "$attempt" -lt "$max_attempts" ]]; do
    printf 'Confirmation> '
    raw=""
    if ! IFS= read -r raw; then
      return 21
    fi

    trimmed="$(trim_outer_whitespace "$raw")"

    if [[ -z "$trimmed" ]]; then
      attempt=$((attempt + 1))
      if [[ "$attempt" -ge "$max_attempts" ]]; then
        return 21
      fi
      log WARN "Empty confirmation. No action was taken. Try again (${attempt}/${max_attempts})."
      printf 'Type exactly: %s\n\n' "$expected"
      continue
    fi

    if [[ "$trimmed" == "$expected" ]]; then
      if [[ "$raw" != "$trimmed" ]]; then
        log INFO "Leading/trailing whitespace was ignored."
      fi
      log INFO "Confirmation accepted."
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      return 21
    fi
    log WARN "Confirmation mismatch. No action was taken. Try again (${attempt}/${max_attempts})."
    printf 'Type exactly: %s\n\n' "$expected"
  done

  return 21
}
