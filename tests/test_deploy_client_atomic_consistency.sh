#!/usr/bin/env bash
# Verify atomic publication of a host-pinned signed client generation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_X2B="${ROOT}/scripts/deploy-client-xenial-to-bionic-atomic.sh"
DEPLOY_PY="${ROOT}/scripts/lib/deploy_client_artifacts_atomic.py"
NAME="dp-offline-upgrade-xenial-to-bionic.sh"
HOST_A="http://192.0.2.10"
FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
SRC="${WORKDIR}/source"
HOP="${SRC}/xenial-to-bionic"
DEST="${WORKDIR}/dest/client"
GPG_HOME="${WORKDIR}/gnupg"
mkdir -p "$HOP" "$DEST/other-hop-should-remain" "$GPG_HOME"
chmod 700 "$GPG_HOME"
printf 'keep\n' >"$DEST/other-hop-should-remain/marker"

cat >"${WORKDIR}/gpg.batch" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: Atomic Deploy Fixture
Name-Email: atomic-deploy@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF
gpg --homedir "$GPG_HOME" --batch --gen-key "${WORKDIR}/gpg.batch" >/dev/null 2>&1
FPR="$(gpg --homedir "$GPG_HOME" --batch --with-colons --fingerprint |
  awk -F: '$1=="fpr"{print $10; exit}')"
PUB_KEY="${WORKDIR}/public.gpg"
gpg --homedir "$GPG_HOME" --batch --export >"$PUB_KEY"

cat >"${HOP}/client-manifest.json" <<EOF
{"schema_version":1,"hop":"xenial-to-bionic","mirror_base":"${HOST_A}","sample_deb_url":"${HOST_A}/hops/xenial-to-bionic/sample.deb"}
EOF
gpg --homedir "$GPG_HOME" --batch --yes --armor --detach-sign \
  -o "${HOP}/client-manifest.json.asc" "${HOP}/client-manifest.json"
MAN_SHA="$(sha256sum "${HOP}/client-manifest.json" | awk '{print $1}')"
python3 - "${SRC}/${NAME}" "$MAN_SHA" "$HOST_A" <<'PY'
import base64, json, sys
path, manifest_sha, host = sys.argv[1:4]
meta = (
    "Release-File: {0}/hops/xenial-to-bionic/ubuntu/dists/bionic/Release\n"
    "UpgradeTool: {0}/offline/release-upgraders/bionic/bionic.tar.gz\n"
).format(host)
manifest = json.dumps({"schema_version": 1, "mirror_base": host})
enc = lambda value: base64.b64encode(value.encode()).decode()
open(path, "w", encoding="utf-8").write(
    "#!/usr/bin/env bash\n"
    "PIN_MIRROR_BASE='{0}'\n"
    "PIN_SAMPLE_DEB_URL='{0}/hops/xenial-to-bionic/sample.deb'\n"
    "PIN_MANIFEST_SHA256='{1}'\n"
    "PIN_META_B64='{2}'\n"
    "PIN_MANIFEST_B64='{3}'\n".format(host, manifest_sha, enc(meta), enc(manifest))
)
PY
chmod 755 "${SRC}/${NAME}"
cp "${SRC}/${NAME}" "${HOP}/${NAME}"
for file in meta-release-lts ReleaseAnnouncement ReleaseAnnouncement.html; do
  printf 'fixture\n' >"${HOP}/${file}"
done
cp "$PUB_KEY" "${HOP}/stellar-offline-manifest.gpg"
cp "$PUB_KEY" "${HOP}/stellar-offline-upgrade.gpg"
ART_SHA="$(sha256sum "${SRC}/${NAME}" | awk '{print $1}')"
printf '%s  %s\n' "$ART_SHA" "$NAME" >"${SRC}/${NAME}.sha256"

deploy() {
  local artifact="${1:-${SRC}/${NAME}}" hop="${2:-$HOP}" dest="${3:-$DEST}"
  python3 "$DEPLOY_PY" \
    --artifact "$artifact" --sidecar "${SRC}/${NAME}.sha256" \
    --hop-dir "$hop" --hop-name xenial-to-bionic --script-name "$NAME" \
    --dest-root "$dest" --pub-key "$PUB_KEY" --expected-sha "$ART_SHA" \
    --allowed-fingerprint "$FPR"
}

out="$(deploy "${SRC}/${NAME}" "$HOP" "${WORKDIR}/not-client-root" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 && "$out" == *"refusing dest-root"* ]] \
  && pass "helper refuses non-client dest-root" || fail "non-client root accepted"

BAD_HOP="${WORKDIR}/bad-hop"
cp -a "$HOP" "$BAD_HOP"
printf 'tampered\n' >"${BAD_HOP}/${NAME}"
out="$(deploy "${SRC}/${NAME}" "$BAD_HOP" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 && "$out" == *"top-level/per-hop script SHA mismatch"* ]] \
  && pass "helper refuses top/hop SHA mismatch" || fail "top/hop mismatch accepted"

printf 'stale\n' >"${DEST}/${NAME}"
out="$(deploy 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -eq 0 && "$out" == *"DEPLOY_OK"* && "$out" == *"GENERATION_UNIFIED=YES"* ]]; then
  pass "host-pinned generation deployed atomically"
else
  fail "atomic deploy failed: ${out}"
fi

TOP_SHA="$(sha256sum "${DEST}/${NAME}" | awk '{print $1}')"
HOP_SHA="$(sha256sum "${DEST}/xenial-to-bionic/${NAME}" | awk '{print $1}')"
SIDE_SHA="$(awk '{print $1}' "${DEST}/${NAME}.sha256")"
[[ "$TOP_SHA" == "$ART_SHA" && "$HOP_SHA" == "$ART_SHA" && "$SIDE_SHA" == "$ART_SHA" ]] \
  && pass "top/hop/sidecar generation unified" || fail "published generation differs"
[[ "$(stat -c '%a' "${DEST}/${NAME}")" == 755 ]] || fail "script mode is not 0755"
[[ "$(stat -c '%a' "${DEST}/${NAME}.sha256")" == 644 ]] || fail "sidecar mode is not 0644"
[[ -f "$DEST/other-hop-should-remain/marker" ]] || fail "unrelated hop removed"
compgen -G "${DEST}/${NAME}.bak-*" >/dev/null \
  && pass "existing artifact backed up" || fail "artifact backup missing"
if compgen -G "${DEST}/**/*.tmp.*" >/dev/null; then
  fail "temporary publication files remain"
else
  pass "no temporary publication files remain"
fi

# Wrong signer fingerprint blocks publish
out="$(python3 "$DEPLOY_PY" \
  --artifact "${SRC}/${NAME}" --sidecar "${SRC}/${NAME}.sha256" \
  --hop-dir "$HOP" --hop-name xenial-to-bionic --script-name "$NAME" \
  --dest-root "${WORKDIR}/dest2/client" --pub-key "$PUB_KEY" \
  --allowed-fingerprint "0000000000000000000000000000000000000000" 2>&1)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && pass "wrong fingerprint blocks publish" || fail "wrong fingerprint accepted"

grep -q 'C786FE98' "$DEPLOY_X2B" \
  && fail "wrapper still hardcodes central fingerprint" \
  || pass "wrapper has no central fingerprint hardcode"
bash -n "$DEPLOY_X2B" || fail "deploy wrapper syntax"
python3 -m py_compile "$DEPLOY_PY" || fail "deploy helper syntax"

[[ "$FAIL" -eq 0 ]] && echo "ALL test_deploy_client_atomic_consistency CHECKS PASSED" && exit 0
echo "SOME test_deploy_client_atomic_consistency CHECKS FAILED"
exit 1
