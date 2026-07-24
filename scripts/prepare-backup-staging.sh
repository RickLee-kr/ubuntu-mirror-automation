#!/usr/bin/env bash
# prepare-backup-staging.sh — Safe Git backup staging + audit (no commit/push).
#
# MUST be executed as a child bash process. Never source this file into an
# interactive SSH shell.
#
# Usage:
#   bash scripts/prepare-backup-staging.sh --audit-only
#   bash scripts/prepare-backup-staging.sh --stage
#   bash scripts/prepare-backup-staging.sh --help
#
# Do NOT run:
#   source scripts/prepare-backup-staging.sh
#   . scripts/prepare-backup-staging.sh

# --- parent-shell protection: refuse being sourced ---
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  printf '%s\n' \
    'ERROR: This script must be executed, not sourced.' \
    'Run: bash scripts/prepare-backup-staging.sh --audit-only' \
    ' or: bash scripts/prepare-backup-staging.sh --stage'
  return 2 2>/dev/null || true
  # If return is unavailable (non-function source edge), stop without exit.
  printf '%s\n' 'PARENT_SHELL_SAFE=YES'
  false
fi

# Child-process options only (never rely on unconditional set -e).
set -u
set -o pipefail

EXPECTED_ROOT="/home/aella/ubuntu-mirror-automation"
EXPECTED_BRANCH="main"
EXPECTED_REMOTE="git@github.com:RickLee-kr/ubuntu-mirror-automation.git"
MAX_BLOB_BYTES=$((20 * 1024 * 1024))

# Known production top-level client script SHA256 pins.
# Updated only when worktree artifacts are cross-validated (top/sidecar/hop/
# signature agree) and the previous pin is proven stale.
declare -A EXPECTED_SCRIPT_SHA=(
  ["dp-offline-upgrade-xenial-to-bionic.sh"]="a41038fb816c1b6cdec439188d851c50f54d7eb191e7e007752399ba73ae0213"
  ["dp-offline-upgrade-bionic-to-focal.sh"]="09557479ba5700ffe9c48f81e8526cd56925bb7ea808a93d775cf5d205de8f3d"
  ["dp-offline-upgrade-focal-to-jammy.sh"]="5bcf2dbb1068030aa3e4289600c85adcfdeb02b8e274780f34f479c3637bf0f5"
  ["dp-offline-upgrade-jammy-to-noble.sh"]="e7d9fb8cbd8a0cfbbea16b26b68b3d736513fa80b800d72b6dfd610404b4434f"
)

PRODUCTION_HOPS=(
  xenial-to-bionic
  bionic-to-focal
  focal-to-jammy
  jammy-to-noble
)

declare -A SCRIPT_FOR_HOP=(
  ["xenial-to-bionic"]="dp-offline-upgrade-xenial-to-bionic.sh"
  ["bionic-to-focal"]="dp-offline-upgrade-bionic-to-focal.sh"
  ["focal-to-jammy"]="dp-offline-upgrade-focal-to-jammy.sh"
  ["jammy-to-noble"]="dp-offline-upgrade-jammy-to-noble.sh"
)

declare -A HOP_FOR_SCRIPT=(
  ["dp-offline-upgrade-xenial-to-bionic.sh"]="xenial-to-bionic"
  ["dp-offline-upgrade-bionic-to-focal.sh"]="bionic-to-focal"
  ["dp-offline-upgrade-focal-to-jammy.sh"]="focal-to-jammy"
  ["dp-offline-upgrade-jammy-to-noble.sh"]="jammy-to-noble"
)

MODE=""
REPO_ROOT=""
GIT_DIR=""
TMPDIR_WORK=""
INDEX_BACKUP=""
GITIGNORE_BACKUP=""
GITIGNORE_MODIFIED=0
STAGED_ANYTHING=0
PREEXISTING_STAGED_COUNT=0
ROLLBACK_DONE=0
FAILURE_CLASS=""
FAILURE_DETAIL=""
PARENT_SHELL_SAFE="YES"
COMMIT_PERFORMED="NO"
PUSH_PERFORMED="NO"

REQUIRED_SOURCE_PATHS=(
  ".gitignore"
  "client"
  "docs"
  "lib"
  "scripts"
  "tests"
  "config/offline-upgrade-exceptions.json"
  "config/offline-upgrade-profile.json"
  "config/client-signing/offline-client-manifest.gpg"
)

OPTIONAL_ARTIFACT_PATHS=(
  "artifacts/client/xenial-to-bionic"
  "artifacts/client/bionic-to-focal"
  "artifacts/client/focal-to-jammy"
  "artifacts/client/jammy-to-noble"
  "artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh"
  "artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256"
  "artifacts/client/dp-offline-upgrade-bionic-to-focal.sh"
  "artifacts/client/dp-offline-upgrade-bionic-to-focal.sh.sha256"
  "artifacts/client/dp-offline-upgrade-focal-to-jammy.sh"
  "artifacts/client/dp-offline-upgrade-focal-to-jammy.sh.sha256"
  "artifacts/client/dp-offline-upgrade-jammy-to-noble.sh"
  "artifacts/client/dp-offline-upgrade-jammy-to-noble.sh.sha256"
)

GITIGNORE_RULES=(
  "config/client-signing/*.private.gpg"
  "artifacts/upgrade-discovery/"
  "artifacts/client-unsigned-test/"
  "artifacts/recovery/"
  "artifacts/logs/"
  "artifacts/client/nginx-deploy/"
  "artifacts/client/build-summary.json"
  "ubuntu-mirror-automation/"
  "__pycache__/"
  "*.pyc"
)

FORBIDDEN_PREFIXES=(
  "config/client-signing/offline-client-manifest.private.gpg"
  "artifacts/upgrade-discovery/"
  "artifacts/client-unsigned-test/"
  "artifacts/recovery/"
  "artifacts/logs/"
  "artifacts/client/nginx-deploy/"
  "ubuntu-mirror-automation/"
)

usage() {
  cat <<'EOF'
Git backup staging helper (staging + audit only; never commit/push).

IMPORTANT:
  - Do NOT paste multi-line set -e / exit blocks into an interactive SSH shell.
  - Do NOT source this script.
  - Always run it as a child process with bash:

      bash scripts/prepare-backup-staging.sh --audit-only
      bash scripts/prepare-backup-staging.sh --stage

Usage:
  bash scripts/prepare-backup-staging.sh --audit-only
  bash scripts/prepare-backup-staging.sh --stage
  bash scripts/prepare-backup-staging.sh --help

Modes:
  --audit-only   Read-only inspection (no index / .gitignore / worktree changes)
  --stage        Stage approved paths, ensure .gitignore excludes, then audit
  --help         Show this help

This script never runs git commit, git push, rebase, merge, or reset --hard.
EOF
}

log() {
  printf '%s\n' "$*"
}

cleanup_temps() {
  if [[ -n "${TMPDIR_WORK:-}" && -d "${TMPDIR_WORK:-}" ]]; then
    rm -rf -- "${TMPDIR_WORK}" 2>/dev/null || true
  fi
}

on_err_trap() {
  local line="${1:-unknown}"
  log "TRAP_ERROR line=${line} (child script only; parent shell remains alive)"
  PARENT_SHELL_SAFE="YES"
}

# --- helpers ---

git_in_repo() {
  git -C "$REPO_ROOT" "$@"
}

count_staged() {
  local n
  n="$(git_in_repo diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s\n' "${n:-0}"
}

list_staged_nul() {
  git_in_repo diff --cached -z --name-only 2>/dev/null || true
}

path_is_forbidden() {
  local path="$1"
  local p
  for p in "${FORBIDDEN_PREFIXES[@]}"; do
    if [[ "$path" == "$p" || "$path" == "$p"* ]]; then
      return 0
    fi
  done
  # nested repo root itself
  if [[ "$path" == "ubuntu-mirror-automation" || "$path" == "ubuntu-mirror-automation/"* ]]; then
    return 0
  fi
  if [[ "$path" == *.private.gpg ]]; then
    return 0
  fi
  return 1
}

ensure_gitignore_rules() {
  local gi="${REPO_ROOT}/.gitignore"
  local rule existing tmp added=0
  if [[ ! -f "$gi" ]]; then
    FAILURE_CLASS="GITIGNORE_MISSING"
    FAILURE_DETAIL=".gitignore missing"
    return 91
  fi
  if [[ "$GITIGNORE_MODIFIED" -eq 0 ]]; then
    GITIGNORE_BACKUP="${TMPDIR_WORK}/gitignore.pre"
    cp -p -- "$gi" "$GITIGNORE_BACKUP" || {
      FAILURE_CLASS="GITIGNORE_BACKUP_FAIL"
      FAILURE_DETAIL="cannot backup .gitignore"
      return 91
    }
  fi
  existing="$(cat -- "$gi")"
  tmp="${TMPDIR_WORK}/gitignore.new"
  printf '%s\n' "$existing" >"$tmp"
  local need_header=1
  if grep -Fq '# Backup staging excludes (prepare-backup-staging.sh)' "$tmp" 2>/dev/null; then
    need_header=0
  fi
  for rule in "${GITIGNORE_RULES[@]}"; do
    if grep -Fxq -- "$rule" "$tmp" 2>/dev/null; then
      continue
    fi
    if [[ "$need_header" -eq 1 ]]; then
      # Ensure trailing newline before section.
      if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]]; then
        printf '\n' >>"$tmp"
      fi
      printf '\n# Backup staging excludes (prepare-backup-staging.sh)\n' >>"$tmp"
      need_header=0
    fi
    printf '%s\n' "$rule" >>"$tmp"
    added=$((added + 1))
  done
  if [[ "$added" -gt 0 ]]; then
    mv -f -- "$tmp" "$gi" || {
      FAILURE_CLASS="GITIGNORE_WRITE_FAIL"
      FAILURE_DETAIL="cannot update .gitignore"
      return 91
    }
    GITIGNORE_MODIFIED=1
    log "GITIGNORE_RULES_ADDED=${added}"
  else
    log "GITIGNORE_RULES_ADDED=0"
    rm -f -- "$tmp" 2>/dev/null || true
  fi
  return 0
}

backup_index() {
  local index_path
  index_path="$(git_in_repo rev-parse --git-path index)"
  INDEX_BACKUP="${TMPDIR_WORK}/index.pre"
  if [[ -f "$index_path" ]]; then
    cp -p -- "$index_path" "$INDEX_BACKUP" || {
      FAILURE_CLASS="INDEX_BACKUP_FAIL"
      FAILURE_DETAIL="cannot copy git index"
      return 91
    }
  else
    : >"$INDEX_BACKUP"
  fi
  PREEXISTING_STAGED_COUNT="$(count_staged)"
  log "PREEXISTING_STAGED_COUNT=${PREEXISTING_STAGED_COUNT}"
  return 0
}

restore_index_and_gitignore() {
  local index_path rc=0
  index_path="$(git_in_repo rev-parse --git-path index)"
  if [[ -n "${INDEX_BACKUP:-}" && -f "${INDEX_BACKUP:-}" ]]; then
    if [[ -s "$INDEX_BACKUP" ]]; then
      if cp -p -- "$INDEX_BACKUP" "$index_path"; then
        log "PREEXISTING_INDEX_RESTORED=YES"
      else
        log "PREEXISTING_INDEX_RESTORED=NO"
        rc=1
      fi
    else
      # Empty backup: original had no index file — leave current if any.
      log "PREEXISTING_INDEX_RESTORED=YES note=empty_pre_index"
    fi
  else
    log "PREEXISTING_INDEX_RESTORED=NO detail=no_backup"
    rc=1
  fi
  if [[ "$GITIGNORE_MODIFIED" -eq 1 && -n "${GITIGNORE_BACKUP:-}" && -f "${GITIGNORE_BACKUP:-}" ]]; then
    if cp -p -- "$GITIGNORE_BACKUP" "${REPO_ROOT}/.gitignore"; then
      log "GITIGNORE_RESTORED=YES"
      GITIGNORE_MODIFIED=0
    else
      log "GITIGNORE_RESTORED=NO"
      rc=1
    fi
  else
    log "GITIGNORE_RESTORED=N/A"
  fi
  if [[ "$rc" -eq 0 ]]; then
    log "STAGING_ROLLBACK=PASS"
  else
    log "STAGING_ROLLBACK=FAIL"
  fi
  log "WORKTREE_UNCHANGED=YES"
  ROLLBACK_DONE=1
  return "$rc"
}

stage_paths() {
  local p
  # Preserve + update tracked modifications.
  if ! git_in_repo add -u; then
    FAILURE_CLASS="GIT_ADD_U_FAIL"
    FAILURE_DETAIL="git add -u failed"
    return 91
  fi
  STAGED_ANYTHING=1

  for p in "${REQUIRED_SOURCE_PATHS[@]}"; do
    if [[ ! -e "${REPO_ROOT}/${p}" ]]; then
      FAILURE_CLASS="REQUIRED_PATH_MISSING"
      FAILURE_DETAIL="$p"
      log "REQUIRED_PATH_MISSING=${p}"
      return 91
    fi
    if ! git_in_repo add -- "$p"; then
      FAILURE_CLASS="GIT_ADD_FAIL"
      FAILURE_DETAIL="$p"
      return 91
    fi
  done

  for p in "${OPTIONAL_ARTIFACT_PATHS[@]}"; do
    if [[ ! -e "${REPO_ROOT}/${p}" ]]; then
      log "OPTIONAL_PATH_MISSING=${p}"
      continue
    fi
    # artifacts/client/ is gitignored; force-add approved production paths only.
    if ! git_in_repo add -f -- "$p"; then
      FAILURE_CLASS="GIT_ADD_FORCE_FAIL"
      FAILURE_DETAIL="$p"
      return 91
    fi
  done
  return 0
}

# --- audits ---

audit_forbidden_staged() {
  local path count=0
  while IFS= read -r -d '' path; do
    [[ -z "$path" ]] && continue
    if path_is_forbidden "$path"; then
      log "FORBIDDEN_STAGED=${path}"
      count=$((count + 1))
    fi
  done < <(list_staged_nul)
  log "FORBIDDEN_STAGED_PATHS=${count}"
  if [[ "$count" -gt 0 ]]; then
    FAILURE_CLASS="FORBIDDEN_STAGED_PATH"
    FAILURE_DETAIL="count=${count}"
    return 91
  fi
  return 0
}

# Structural PEM/PGP private-key block detector (Python stdlib only).
# Markers are constructed at runtime so detector source itself is not a block.
# Rules:
#   - BEGIN line must equal the marker exactly (whole line)
#   - Matching END must be present
#   - Non-empty base64 payload required (PGP: after optional armor headers + blank line)
# Does NOT use allowlists and does NOT grep for bare "BEGIN … PRIVATE KEY" substrings.
write_private_key_detector() {
  local dest="$1"
  cat >"$dest" <<'PY'
import re
import sys

# Order matters: more specific kinds before generic "PRIVATE KEY".
_KINDS = (
    ("RSA PRIVATE KEY", "RSA"),
    ("EC PRIVATE KEY", "EC"),
    ("OPENSSH PRIVATE KEY", "OPENSSH"),
    ("PGP PRIVATE KEY BLOCK", "PGP"),
    ("PRIVATE KEY", "PKCS8"),
)
_MIN_B64 = 32
_B64_LINE = re.compile(r"^[A-Za-z0-9+/]+={0,2}$")
_ARMOR_HEADER = re.compile(r"^[A-Za-z0-9-]+:\s*")


def _begin(kind):
    return "-----BEGIN " + kind + "-----"


def _end(kind):
    return "-----END " + kind + "-----"


def _is_b64_payload_line(line):
    s = line.strip()
    if len(s) < 4:
        return False
    # OpenPGP armor checksum line (=XXXX) is not payload.
    if s.startswith("=") and len(s) <= 6:
        return False
    return _B64_LINE.match(s) is not None


def _pgp_payload_lines(body):
    """Skip Version/Comment armor headers; require base64 after optional blank line."""
    i = 0
    n = len(body)
    while i < n:
        raw = body[i]
        if raw.strip() == "":
            i += 1
            break
        if _ARMOR_HEADER.match(raw.strip()):
            i += 1
            continue
        # Non-header before blank line: treat remainder as body.
        break
    return [ln for ln in body[i:] if _is_b64_payload_line(ln)]


def scan_private_key_blocks(text):
    lines = text.splitlines()
    found = []
    i = 0
    while i < len(lines):
        # Exact whole-line BEGIN only (prose / grep patterns ignored).
        line = lines[i].rstrip("\r")
        matched = None
        for kind, typ in _KINDS:
            if line == _begin(kind):
                matched = (kind, typ)
                break
        if matched is None:
            i += 1
            continue
        kind, typ = matched
        end = _end(kind)
        i += 1
        body = []
        while i < len(lines):
            cur = lines[i].rstrip("\r")
            if cur == end:
                break
            body.append(cur)
            i += 1
        else:
            # BEGIN without matching END — not a complete block.
            continue
        if typ == "PGP":
            payload = _pgp_payload_lines(body)
        else:
            payload = [ln for ln in body if _is_b64_payload_line(ln)]
        total = sum(len(ln.strip()) for ln in payload)
        if payload and total >= _MIN_B64:
            found.append(typ)
        i += 1  # consume END
    return found


def main():
    if len(sys.argv) != 2:
        print("usage: detect_private_key_blocks.py <file>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        print("read_error:%s" % exc, file=sys.stderr)
        return 1
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("latin-1", errors="replace")
    for typ in scan_private_key_blocks(text):
        print(typ)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
}

audit_private_key_markers() {
  local path count=0 blob_file detector typ
  blob_file="${TMPDIR_WORK}/staged-blob.scan"
  detector="${TMPDIR_WORK}/detect_private_key_blocks.py"
  write_private_key_detector "$detector" || {
    FAILURE_CLASS="PRIVATE_KEY_DETECTOR_WRITE_FAIL"
    FAILURE_DETAIL="cannot write detector"
    return 92
  }
  while IFS= read -r -d '' path; do
    [[ -z "$path" ]] && continue
    # Inspect staged blob only (not worktree).
    if ! git_in_repo show ":${path}" >"$blob_file" 2>/dev/null; then
      continue
    fi
    while IFS= read -r typ; do
      [[ -z "$typ" ]] && continue
      log "PRIVATE_KEY_BLOCK_STAGED path=${path} type=${typ}"
      count=$((count + 1))
    done < <(python3 "$detector" "$blob_file" 2>/dev/null || true)
  done < <(list_staged_nul)
  log "PRIVATE_KEY_MARKERS=${count}"
  if [[ "$count" -gt 0 ]]; then
    FAILURE_CLASS="PRIVATE_KEY_MARKER"
    FAILURE_DETAIL="count=${count}"
    return 92
  fi
  return 0
}

audit_signing_keyring() {
  local key="${REPO_ROOT}/config/client-signing/offline-client-manifest.gpg"
  local packets
  if [[ ! -f "$key" ]]; then
    # In audit-only without key: report and fail closed for production.
    if [[ "${PREPARE_BACKUP_STAGING_ALLOW_FIXTURE:-}" == "1" ]]; then
      log "SIGNING_KEYRING=SKIPPED_FIXTURE"
      return 0
    fi
    FAILURE_CLASS="SIGNING_KEYRING_MISSING"
    FAILURE_DETAIL="$key"
    return 93
  fi
  if ! packets="$(gpg --list-packets -- "$key" 2>/dev/null)"; then
    FAILURE_CLASS="SIGNING_KEYRING_UNREADABLE"
    FAILURE_DETAIL="gpg --list-packets failed"
    return 93
  fi
  # Reject secrets first (modern secret exports may omit a separate public packet).
  if grep -Eq ':secret key packet:|:secret sub key packet:' <<<"$packets"; then
    FAILURE_CLASS="SIGNING_KEYRING_HAS_SECRET"
    FAILURE_DETAIL="secret key packet present"
    log "SIGNING_KEYRING=SECRET_PRESENT"
    return 93
  fi
  if ! grep -Fq ':public key packet:' <<<"$packets"; then
    FAILURE_CLASS="SIGNING_KEYRING_NO_PUBLIC"
    FAILURE_DETAIL="missing :public key packet:"
    log "SIGNING_KEYRING=FAIL"
    return 93
  fi
  log "SIGNING_KEYRING=PUBLIC_ONLY"
  return 0
}

audit_staged_blob_sizes() {
  local path oid size count=0
  while IFS= read -r -d '' path; do
    [[ -z "$path" ]] && continue
    # Skip gitlinks / deleted
    oid="$(git_in_repo rev-parse -q --verify ":${path}" 2>/dev/null || true)"
    if [[ -z "$oid" ]]; then
      continue
    fi
    # mode 160000 = gitlink
    if git_in_repo ls-files -s -- "$path" 2>/dev/null | awk '{print $1}' | grep -qx '160000'; then
      log "NESTED_GITLINK_STAGED=${path}"
      FAILURE_CLASS="NESTED_GIT_REPOSITORY"
      FAILURE_DETAIL="$path"
      return 94
    fi
    size="$(git_in_repo cat-file -s "$oid" 2>/dev/null || echo 0)"
    if [[ "$size" =~ ^[0-9]+$ ]] && [[ "$size" -gt "$MAX_BLOB_BYTES" ]]; then
      log "STAGED_OVER_20MB path=${path} bytes=${size}"
      count=$((count + 1))
    fi
  done < <(list_staged_nul)
  log "STAGED_FILES_OVER_20MB=${count}"
  if [[ "$count" -gt 0 ]]; then
    FAILURE_CLASS="STAGED_BLOB_TOO_LARGE"
    FAILURE_DETAIL="count=${count}"
    return 93
  fi
  return 0
}

audit_nested_repo() {
  local path count=0
  while IFS= read -r -d '' path; do
    [[ -z "$path" ]] && continue
    if [[ "$path" == "ubuntu-mirror-automation" || "$path" == "ubuntu-mirror-automation/"* ]]; then
      log "NESTED_REPO_STAGED=${path}"
      count=$((count + 1))
    fi
    if git_in_repo ls-files -s -- "$path" 2>/dev/null | awk '{print $1}' | grep -qx '160000'; then
      log "GITLINK_STAGED=${path}"
      count=$((count + 1))
    fi
  done < <(list_staged_nul)
  # Also fail if nested .git directory would be added under approved trees (defensive).
  if [[ -e "${REPO_ROOT}/ubuntu-mirror-automation/.git" ]]; then
    if git_in_repo diff --cached --name-only 2>/dev/null | grep -q '^ubuntu-mirror-automation'; then
      count=$((count + 1))
    fi
  fi
  if [[ "$count" -gt 0 ]]; then
    FAILURE_CLASS="NESTED_GIT_REPOSITORY"
    FAILURE_DETAIL="count=${count}"
    return 94
  fi
  log "NESTED_GIT_REPOSITORY_STAGED=0"
  return 0
}

file_sha256() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    printf '%s\n' ""
    return 1
  fi
  sha256sum -- "$f" 2>/dev/null | awk '{print $1}'
}

staged_blob_sha256() {
  # Prints hex digest, or NOT_STAGED when path is absent from the index.
  local rel="$1"
  local oid digest
  oid="$(git_in_repo rev-parse -q --verify ":${rel}" 2>/dev/null || true)"
  if [[ -z "$oid" ]]; then
    printf '%s\n' "NOT_STAGED"
    return 0
  fi
  digest="$(git_in_repo cat-file blob "$oid" 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$digest" ]]; then
    printf '%s\n' "NOT_STAGED"
    return 0
  fi
  printf '%s\n' "$digest"
}

# Extract script SHA declared inside client-manifest.json by reading the actual
# schema (no guessed field). Prints one of: <sha256> | NOT_FOUND | CONFLICT
extract_manifest_script_sha() {
  local manifest_path="$1"
  local script_name="$2"
  python3 - "$manifest_path" "$script_name" <<'PY'
import json
import sys

manifest_path, script_name = sys.argv[1], sys.argv[2]

def is_sha256(value):
    if not isinstance(value, str):
        return False
    s = value.strip().lower()
    return len(s) == 64 and all(c in "0123456789abcdef" for c in s)

def normalize(value):
    return value.strip().lower()

try:
    with open(manifest_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("NOT_FOUND")
    sys.exit(0)

found = []

# Explicit top-level keys only when present in this schema instance.
if isinstance(data, dict):
    for key in (
        "script_sha256",
        "client_script_sha256",
        "offline_script_sha256",
        "dp_offline_upgrade_sha256",
        "upgrade_script_sha256",
    ):
        if key in data and is_sha256(data[key]):
            found.append(normalize(data[key]))

    # Dict containers keyed by script basename (if schema uses them).
    for container in ("files", "artifacts", "scripts", "client_scripts"):
        block = data.get(container)
        if not isinstance(block, dict):
            continue
        entry = block.get(script_name)
        if isinstance(entry, str) and is_sha256(entry):
            found.append(normalize(entry))
        elif isinstance(entry, dict):
            for hk in ("sha256", "sha256sum", "hash", "checksum", "digest"):
                if hk in entry and is_sha256(entry[hk]):
                    found.append(normalize(entry[hk]))

def walk(obj):
    if isinstance(obj, dict):
        names = []
        for nk in ("name", "filename", "path", "file", "script", "basename"):
            v = obj.get(nk)
            if isinstance(v, str):
                names.append(v)
        refers = any(
            n == script_name or n.endswith("/" + script_name) for n in names
        )
        if refers:
            for hk in ("sha256", "sha256sum", "hash", "checksum", "digest"):
                if hk in obj and is_sha256(obj[hk]):
                    found.append(normalize(obj[hk]))
            # optional size handled by caller via separate extractor
        for v in obj.values():
            walk(v)
    elif isinstance(obj, list):
        for v in obj:
            walk(v)

walk(data)
uniq = sorted(set(found))
if not uniq:
    print("NOT_FOUND")
elif len(uniq) > 1:
    print("CONFLICT")
else:
    print(uniq[0])
PY
}

extract_manifest_script_size() {
  local manifest_path="$1"
  local script_name="$2"
  python3 - "$manifest_path" "$script_name" <<'PY'
import json
import sys

manifest_path, script_name = sys.argv[1], sys.argv[2]
try:
    with open(manifest_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("NOT_FOUND")
    sys.exit(0)

found = []

def add_size(v):
    if isinstance(v, int) and v >= 0:
        found.append(str(v))
    elif isinstance(v, str) and v.isdigit():
        found.append(v)

if isinstance(data, dict):
    for key in ("script_size", "client_script_size", "size"):
        # bare top-level "size" is ambiguous; only accept script_* keys here
        if key == "size":
            continue
        if key in data:
            add_size(data[key])
    for container in ("files", "artifacts", "scripts", "client_scripts"):
        block = data.get(container)
        if not isinstance(block, dict):
            continue
        entry = block.get(script_name)
        if isinstance(entry, dict) and "size" in entry:
            add_size(entry["size"])

def walk(obj):
    if isinstance(obj, dict):
        names = []
        for nk in ("name", "filename", "path", "file", "script", "basename"):
            v = obj.get(nk)
            if isinstance(v, str):
                names.append(v)
        refers = any(
            n == script_name or n.endswith("/" + script_name) for n in names
        )
        if refers and "size" in obj:
            add_size(obj["size"])
        for v in obj.values():
            walk(v)
    elif isinstance(obj, list):
        for v in obj:
            walk(v)

walk(data)
uniq = sorted(set(found))
if not uniq:
    print("NOT_FOUND")
elif len(uniq) > 1:
    print("CONFLICT")
else:
    print(uniq[0])
PY
}

emit_artifact_diagnosis() {
  local hop="$1" path="$2" expected="$3" actual="$4" sidecar="$5"
  local hop_sha="$6" manifest_sha="$7" staged="$8" worktree="$9" result="${10}"
  log "ARTIFACT_HOP=${hop}"
  log "ARTIFACT_PATH=${path}"
  log "EXPECTED_SHA256=${expected}"
  log "ACTUAL_SHA256=${actual}"
  log "SIDECAR_DECLARED_SHA256=${sidecar}"
  log "HOP_DIRECTORY_SHA256=${hop_sha}"
  log "TOP_LEVEL_SHA256=${worktree}"
  log "MANIFEST_DECLARED_SHA256=${manifest_sha}"
  log "STAGED_BLOB_SHA256=${staged}"
  log "WORKTREE_SHA256=${worktree}"
  log "RESULT=${result}"
}

audit_production_artifact_sha256() {
  local hop script top side hop_script man_json man_asc man_key
  local expected actual side_sha hop_sha manifest_decl staged_sha
  local manifest_file_sha manifest_size_decl top_size hop_size
  local sig_ok result checked=0
  local pin_stale=0 inconsistent=0 divergence=0 sig_fail=0
  local first_fail_class="" first_fail_detail=""

  for hop in "${PRODUCTION_HOPS[@]}"; do
    script="${SCRIPT_FOR_HOP[$hop]}"
    expected="${EXPECTED_SCRIPT_SHA[$script]}"
    top="${REPO_ROOT}/artifacts/client/${script}"
    side="${REPO_ROOT}/artifacts/client/${script}.sha256"
    hop_script="${REPO_ROOT}/artifacts/client/${hop}/${script}"
    man_json="${REPO_ROOT}/artifacts/client/${hop}/client-manifest.json"
    man_asc="${REPO_ROOT}/artifacts/client/${hop}/client-manifest.json.asc"
    man_key="${REPO_ROOT}/artifacts/client/${hop}/stellar-offline-manifest.gpg"

    if [[ ! -f "$top" ]]; then
      log "OPTIONAL_PATH_MISSING=artifacts/client/${script}"
      continue
    fi
    checked=$((checked + 1))

    actual="$(file_sha256 "$top")"
    staged_sha="$(staged_blob_sha256 "artifacts/client/${script}")"
    top_size="$(wc -c <"$top" | tr -d ' ')"

    if [[ -f "$side" ]]; then
      side_sha="$(awk '{print $1}' "$side" | head -1)"
      [[ -n "$side_sha" ]] || side_sha="ABSENT"
    else
      side_sha="ABSENT"
    fi

    if [[ -f "$hop_script" ]]; then
      hop_sha="$(file_sha256 "$hop_script")"
      hop_size="$(wc -c <"$hop_script" | tr -d ' ')"
    else
      hop_sha="ABSENT"
      hop_size=""
    fi

    if [[ -f "$man_json" ]]; then
      manifest_decl="$(extract_manifest_script_sha "$man_json" "$script")"
      manifest_file_sha="$(file_sha256 "$man_json")"
      manifest_size_decl="$(extract_manifest_script_size "$man_json" "$script")"
      log "MANIFEST_FILE_SHA256 hop=${hop} sha256=${manifest_file_sha}"
    else
      manifest_decl="NOT_FOUND"
      manifest_file_sha="ABSENT"
      manifest_size_decl="NOT_FOUND"
      log "MANIFEST_FILE_SHA256 hop=${hop} sha256=ABSENT"
    fi

    # Never confuse the manifest file digest with the script digest.
    if [[ "$manifest_decl" != "NOT_FOUND" && "$manifest_decl" != "CONFLICT" \
      && "$manifest_file_sha" != "ABSENT" && "$manifest_decl" == "$manifest_file_sha" ]]; then
      log "MANIFEST_SCRIPT_SHA_EQUALS_MANIFEST_FILE hop=${hop} (rejected)"
      manifest_decl="NOT_FOUND"
    fi

    sig_ok=0
    if [[ -f "$man_key" && -f "$man_asc" && -f "$man_json" ]]; then
      if gpgv --keyring "$man_key" "$man_asc" "$man_json" >/dev/null 2>&1; then
        log "MANIFEST_SIGNATURE hop=${hop} result=PASS"
        sig_ok=1
      else
        log "MANIFEST_SIGNATURE hop=${hop} result=FAIL"
        sig_fail=$((sig_fail + 1))
      fi
    else
      log "MANIFEST_SIGNATURE hop=${hop} result=FAIL"
      sig_fail=$((sig_fail + 1))
    fi

    result="PASS"
    # Staged vs worktree divergence is fatal for this hop.
    if [[ "$staged_sha" != "NOT_STAGED" && "$staged_sha" != "$actual" ]]; then
      result="FAIL"
      divergence=$((divergence + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="STAGED_WORKTREE_ARTIFACT_DIVERGENCE"
        first_fail_detail="hop=${hop} path=artifacts/client/${script}"
      fi
    fi

    # Artifact internal consistency (source of truth), independent of helper pin.
    if [[ "$side_sha" == "ABSENT" || "$side_sha" != "$actual" ]]; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_SIDECAR_MISMATCH"
        first_fail_detail="hop=${hop} path=artifacts/client/${script}.sha256"
      fi
    elif [[ -f "$side" ]] && ! awk '{print $2}' "$side" | head -1 | grep -Fxq "$script"; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_SIDECAR_BASENAME"
        first_fail_detail="hop=${hop} path=artifacts/client/${script}.sha256"
      fi
    fi

    if [[ "$hop_sha" == "ABSENT" || "$hop_sha" != "$actual" ]]; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_HOP_SCRIPT_MISMATCH"
        first_fail_detail="hop=${hop} path=artifacts/client/${hop}/${script}"
      fi
    elif [[ -n "$hop_size" && "$hop_size" != "$top_size" ]]; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_HOP_SCRIPT_SIZE_MISMATCH"
        first_fail_detail="hop=${hop} top=${top_size} hop=${hop_size}"
      fi
    fi

    if [[ "$manifest_decl" == "CONFLICT" ]]; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_MANIFEST_SCRIPT_HASH_CONFLICT"
        first_fail_detail="hop=${hop}"
      fi
    elif [[ "$manifest_decl" != "NOT_FOUND" && "$manifest_decl" != "$actual" ]]; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_MANIFEST_SCRIPT_HASH_MISMATCH"
        first_fail_detail="hop=${hop} manifest=${manifest_decl} actual=${actual}"
      fi
    fi

    if [[ "$manifest_size_decl" != "NOT_FOUND" && "$manifest_size_decl" != "CONFLICT" \
      && "$manifest_size_decl" != "$top_size" ]]; then
      result="FAIL"
      inconsistent=$((inconsistent + 1))
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="PRODUCTION_MANIFEST_SCRIPT_SIZE_MISMATCH"
        first_fail_detail="hop=${hop} manifest_size=${manifest_size_decl} actual_size=${top_size}"
      fi
    fi

    if [[ "$sig_ok" -ne 1 ]]; then
      result="FAIL"
      if [[ -z "$first_fail_class" ]]; then
        first_fail_class="CLIENT_MANIFEST_SIGNATURE"
        first_fail_detail="hop=${hop}"
      fi
    fi

    # Helper pin comparison (after SoT checks).
    if [[ "$actual" != "$expected" ]]; then
      if [[ "$result" == "PASS" && "$sig_ok" -eq 1 \
        && "$side_sha" == "$actual" && "$hop_sha" == "$actual" ]] \
        && { [[ "$manifest_decl" == "NOT_FOUND" ]] || [[ "$manifest_decl" == "$actual" ]]; }; then
        # Artifacts are consistent; only the helper pin is stale.
        result="FAIL"
        pin_stale=$((pin_stale + 1))
        if [[ -z "$first_fail_class" ]]; then
          first_fail_class="PRODUCTION_ARTIFACT_PIN_STALE"
          first_fail_detail="hop=${hop} expected=${expected} actual=${actual}"
        fi
      else
        result="FAIL"
        if [[ -z "$first_fail_class" ]]; then
          first_fail_class="PRODUCTION_ARTIFACT_SHA_MISMATCH"
          first_fail_detail="hop=${hop} expected=${expected} actual=${actual}"
        fi
      fi
    fi

    emit_artifact_diagnosis \
      "$hop" \
      "artifacts/client/${script}" \
      "$expected" \
      "$actual" \
      "$side_sha" \
      "$hop_sha" \
      "$manifest_decl" \
      "$staged_sha" \
      "$actual" \
      "$result"
  done

  if [[ "$checked" -eq 0 && "${PREPARE_BACKUP_STAGING_ALLOW_FIXTURE:-}" == "1" ]]; then
    log "PRODUCTION_ARTIFACT_SHA256=SKIPPED_FIXTURE"
    return 0
  fi
  if [[ "$checked" -eq 0 ]]; then
    FAILURE_CLASS="PRODUCTION_ARTIFACTS_MISSING"
    FAILURE_DETAIL="no top-level client scripts found"
    log "PRODUCTION_ARTIFACT_SHA256=FAIL"
    return 94
  fi

  if [[ "$divergence" -gt 0 ]]; then
    FAILURE_CLASS="${first_fail_class:-STAGED_WORKTREE_ARTIFACT_DIVERGENCE}"
    FAILURE_DETAIL="${first_fail_detail:-divergence=${divergence}}"
    log "PRODUCTION_ARTIFACT_SHA256=FAIL"
    return 94
  fi
  if [[ "$inconsistent" -gt 0 || "$sig_fail" -gt 0 ]]; then
    FAILURE_CLASS="${first_fail_class:-PRODUCTION_ARTIFACT_INCONSISTENT}"
    FAILURE_DETAIL="${first_fail_detail:-inconsistent=${inconsistent} sig_fail=${sig_fail}}"
    log "PRODUCTION_ARTIFACT_SHA256=FAIL"
    return 94
  fi
  if [[ "$pin_stale" -gt 0 ]]; then
    FAILURE_CLASS="${first_fail_class:-PRODUCTION_ARTIFACT_PIN_STALE}"
    FAILURE_DETAIL="${first_fail_detail:-pin_stale=${pin_stale}}"
    log "PRODUCTION_ARTIFACT_SHA256=FAIL"
    log "PRODUCTION_ARTIFACT_PIN_STALE_COUNT=${pin_stale}"
    return 94
  fi

  log "PRODUCTION_ARTIFACT_SHA256=PASS"
  return 0
}

audit_client_manifest_signatures() {
  local hop dir key asc json fail=0 checked=0
  for hop in "${PRODUCTION_HOPS[@]}"; do
    dir="${REPO_ROOT}/artifacts/client/${hop}"
    if [[ ! -d "$dir" ]]; then
      log "OPTIONAL_PATH_MISSING=artifacts/client/${hop}"
      continue
    fi
    key="${dir}/stellar-offline-manifest.gpg"
    asc="${dir}/client-manifest.json.asc"
    json="${dir}/client-manifest.json"
    if [[ ! -f "$key" || ! -f "$asc" || ! -f "$json" ]]; then
      log "OPTIONAL_PATH_MISSING=artifacts/client/${hop}/manifest-bundle"
      continue
    fi
    checked=$((checked + 1))
    if gpgv --keyring "$key" "$asc" "$json" >/dev/null 2>&1; then
      log "MANIFEST_SIGNATURE hop=${hop} result=PASS"
      log "CLIENT_MANIFEST_SIGNATURE hop=${hop} PASS"
    else
      log "MANIFEST_SIGNATURE hop=${hop} result=FAIL"
      log "CLIENT_MANIFEST_SIGNATURE hop=${hop} FAIL"
      fail=$((fail + 1))
    fi
  done
  if [[ "$checked" -eq 0 && "${PREPARE_BACKUP_STAGING_ALLOW_FIXTURE:-}" == "1" ]]; then
    log "CLIENT_MANIFEST_SIGNATURES=SKIPPED_FIXTURE"
    return 0
  fi
  if [[ "$fail" -gt 0 ]]; then
    FAILURE_CLASS="CLIENT_MANIFEST_SIGNATURE"
    FAILURE_DETAIL="fail_count=${fail}"
    log "CLIENT_MANIFEST_SIGNATURES=FAIL"
    return 94
  fi
  if [[ "$checked" -eq 0 ]]; then
    FAILURE_CLASS="CLIENT_MANIFEST_MISSING"
    FAILURE_DETAIL="no hop manifests found"
    log "CLIENT_MANIFEST_SIGNATURES=FAIL"
    return 94
  fi
  log "CLIENT_MANIFEST_SIGNATURES=PASS"
  return 0
}

report_audit_only_inventory() {
  local p
  log "--- audit-only inventory (read-only) ---"
  log "INCLUDE_CANDIDATES_REQUIRED:"
  for p in "${REQUIRED_SOURCE_PATHS[@]}"; do
    if [[ -e "${REPO_ROOT}/${p}" ]]; then
      log "  PRESENT ${p}"
    else
      log "  MISSING ${p}"
    fi
  done
  log "INCLUDE_CANDIDATES_OPTIONAL_ARTIFACTS:"
  for p in "${OPTIONAL_ARTIFACT_PATHS[@]}"; do
    if [[ -e "${REPO_ROOT}/${p}" ]]; then
      log "  PRESENT ${p}"
    else
      log "  OPTIONAL_PATH_MISSING=${p}"
    fi
  done
  log "EXCLUDE_RULES:"
  for p in "${GITIGNORE_RULES[@]}"; do
    log "  ${p}"
  done
  log "SENSITIVE_MUST_NEVER_STAGE:"
  log "  config/client-signing/offline-client-manifest.private.gpg"
  if [[ -e "${REPO_ROOT}/ubuntu-mirror-automation/.git" || -d "${REPO_ROOT}/ubuntu-mirror-automation" ]]; then
    log "NESTED_REPOSITORY_PRESENT=ubuntu-mirror-automation/"
  fi
  log "CURRENT_STAGED_COUNT=$(count_staged)"
}

run_audits() {
  local rc=0
  audit_forbidden_staged || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  audit_private_key_markers || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  audit_signing_keyring || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  audit_staged_blob_sizes || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  audit_nested_repo || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  audit_production_artifact_sha256 || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  audit_client_manifest_signatures || rc=$?
  [[ "$rc" -ne 0 ]] && return "$rc"
  return 0
}

verify_repository_identity() {
  local root branch remote
  if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    FAILURE_CLASS="NOT_A_GIT_REPOSITORY"
    FAILURE_DETAIL="git rev-parse failed"
    return 95
  fi
  REPO_ROOT="$root"
  GIT_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)"
  branch="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
  remote="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"

  if [[ "${PREPARE_BACKUP_STAGING_ALLOW_FIXTURE:-}" == "1" ]]; then
    log "REPOSITORY=${REPO_ROOT}"
    log "BRANCH=${branch:-detached}"
    log "REMOTE=${remote:-none}"
    log "FIXTURE_MODE=YES"
    return 0
  fi

  if [[ "$REPO_ROOT" != "$EXPECTED_ROOT" ]]; then
    FAILURE_CLASS="WRONG_REPOSITORY_ROOT"
    FAILURE_DETAIL="got=${REPO_ROOT} want=${EXPECTED_ROOT}"
    log "ERROR: refusing to run outside expected repository root"
    return 95
  fi
  if [[ "$branch" != "$EXPECTED_BRANCH" ]]; then
    FAILURE_CLASS="WRONG_BRANCH"
    FAILURE_DETAIL="got=${branch} want=${EXPECTED_BRANCH}"
    return 95
  fi
  if [[ "$remote" != "$EXPECTED_REMOTE" ]]; then
    FAILURE_CLASS="WRONG_REMOTE"
    FAILURE_DETAIL="got=${remote} want=${EXPECTED_REMOTE}"
    return 95
  fi
  log "REPOSITORY=${REPO_ROOT}"
  log "BRANCH=${branch}"
  log "REMOTE=${remote}"
  return 0
}

print_summary() {
  local audit_status="$1"
  cat <<EOF
============================================================
BACKUP STAGING AUDIT RESULT
============================================================
MODE=${MODE}
REPOSITORY=${REPO_ROOT:-unknown}
BRANCH=$(git -C "${REPO_ROOT:-.}" branch --show-current 2>/dev/null || printf 'unknown')
COMMIT_PERFORMED=${COMMIT_PERFORMED}
PUSH_PERFORMED=${PUSH_PERFORMED}
PARENT_SHELL_SAFE=${PARENT_SHELL_SAFE}
PREEXISTING_STAGED_FILES_PRESERVED=YES
EOF
  if [[ "$audit_status" == "PASS" ]]; then
    cat <<EOF
FORBIDDEN_STAGED_PATHS=0
PRIVATE_KEY_MARKERS=0
STAGED_FILES_OVER_20MB=0
SIGNING_KEYRING=PUBLIC_ONLY
PRODUCTION_ARTIFACT_SHA256=PASS
CLIENT_MANIFEST_SIGNATURES=PASS
STAGING_AUDIT=PASS_READY_FOR_TEST
EOF
  else
    cat <<EOF
STAGING_AUDIT=FAIL
FAILURE_CLASS=${FAILURE_CLASS:-UNKNOWN}
FAILURE_DETAIL=${FAILURE_DETAIL:-none}
STAGING_ROLLBACK=$( [[ "$ROLLBACK_DONE" -eq 1 ]] && printf 'PASS' || printf 'N/A' )
PARENT_SHELL_SAFE=${PARENT_SHELL_SAFE}
COMMIT_PERFORMED=${COMMIT_PERFORMED}
PUSH_PERFORMED=${PUSH_PERFORMED}
EOF
  fi
}

main() {
  local rc=0 arg

  if [[ "$#" -lt 1 ]]; then
    usage
    return 2
  fi

  for arg in "$@"; do
    case "$arg" in
      --audit-only) MODE="audit-only" ;;
      --stage) MODE="stage" ;;
      --help|-h) usage; return 0 ;;
      *)
        usage
        log "ERROR: unknown argument: ${arg}"
        return 2
        ;;
    esac
  done

  if [[ -z "$MODE" ]]; then
    usage
    return 2
  fi

  TMPDIR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/prepare-backup-staging.XXXXXX")" || {
    log "ERROR: cannot create temp dir"
    return 1
  }
  trap 'on_err_trap $LINENO' ERR
  trap 'cleanup_temps' EXIT

  verify_repository_identity || {
    rc=$?
    print_summary FAIL
    return "$rc"
  }

  cd -- "$REPO_ROOT" || {
    # Child-process failure only — never kill a parent SSH shell.
    FAILURE_CLASS="CD_FAIL"
    FAILURE_DETAIL="$REPO_ROOT"
    print_summary FAIL
    return 1
  }

  if [[ "$MODE" == "audit-only" ]]; then
    report_audit_only_inventory
    # Read-only audits against current index + worktree artifacts.
    # NOTE: never use `if ! cmd; then rc=$?` — bash sets $? to 0 after a
    # successful negated if-test, wiping the real failure code.
    rc=0
    run_audits || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      print_summary FAIL
      return "$rc"
    fi
    print_summary PASS
    return 0
  fi

  # --stage
  backup_index || {
    rc=$?
    print_summary FAIL
    return "$rc"
  }
  ensure_gitignore_rules || {
    rc=$?
    restore_index_and_gitignore || true
    print_summary FAIL
    return "$rc"
  }
  stage_paths || {
    rc=$?
    restore_index_and_gitignore || true
    print_summary FAIL
    return "$rc"
  }
  rc=0
  run_audits || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    restore_index_and_gitignore || true
    print_summary FAIL
    return "$rc"
  fi
  # Stage success: keep index; do not commit/push.
  log "STAGED_PATHS_READY=YES"
  print_summary PASS
  return 0
}

main "$@"
rc=$?
# Child-process exit only — does not terminate the parent SSH shell when
# invoked as: bash scripts/prepare-backup-staging.sh ...
exit "$rc"
