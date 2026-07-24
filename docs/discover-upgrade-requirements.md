# Ubuntu Upgrade Requirements Discovery (Phase 1)

Independent collector for the packages and files actually requested during each
Ubuntu LTS upgrade hop. It does **not** build mirrors, run offline upgrades, or
perform DP bringup.

Requires **Python 3.5+** (Ubuntu 16.04 system Python is supported).

## Supported hops

| From | To | Directory |
|------|----|-----------|
| 16.04 xenial | 18.04 bionic | `xenial-to-bionic/` |
| 18.04 bionic | 20.04 focal | `bionic-to-focal/` |
| 20.04 focal | 22.04 jammy | `focal-to-jammy/` |
| 22.04 jammy | 24.04 noble | `jammy-to-noble/` |

## Commands

`init` requires `--output-dir`. Later commands should pass the same `--output-dir`.
Omitting it is allowed only when exactly one active discovery run is registered.

```bash
sudo ./scripts/discover-upgrade-requirements.sh init \
  --from 16.04 --to 18.04 \
  --output-dir /opt/aelladata/test-run

sudo ./scripts/discover-upgrade-requirements.sh before-hop \
  --output-dir /opt/aelladata/test-run

sudo ./scripts/discover-upgrade-requirements.sh start-recording \
  --output-dir /opt/aelladata/test-run

# apt update / apt dist-upgrade / do-release-upgrade

sudo ./scripts/discover-upgrade-requirements.sh stop-recording \
  --output-dir /opt/aelladata/test-run

sudo ./scripts/discover-upgrade-requirements.sh after-hop \
  --output-dir /opt/aelladata/test-run

sudo ./scripts/discover-upgrade-requirements.sh finalize-hop \
  --output-dir /opt/aelladata/test-run

sudo ./scripts/discover-upgrade-requirements.sh status \
  --output-dir /opt/aelladata/test-run

# Re-download unresolved URLs without re-running the upgrade hop:
sudo ./scripts/discover-upgrade-requirements.sh repair-hop \
  --output-dir /opt/aelladata/test-run
```

## Export PASS results into the Cursor workspace

After a hop reaches `VALIDATION: PASS` with zero unresolved/failed rows, copy the
lightweight manifests into `artifacts/upgrade-discovery/<hop>/` (never
`before/` / `after/` / `runtime/` / `.deb` bodies). Hop is read from discovery
state/metadata — do not pass a hop name.

### 16.04 → 18.04

```bash
OUT=/opt/aelladata/upgrade-discovery-xenial-bionic-20260717T114445Z

sudo ./scripts/discover-upgrade-requirements.sh export-hop \
  --output-dir "$OUT" \
  --repo-dir /home/aella/ubuntu-mirror-automation
```

### 18.04 → 20.04

```bash
OUT=/opt/aelladata/upgrade-discovery-bionic-focal-20260718T022717Z

sudo ./scripts/discover-upgrade-requirements.sh export-hop \
  --output-dir "$OUT" \
  --repo-dir /home/aella/ubuntu-mirror-automation
```

Repeat the same `export-hop` pattern for the remaining hops (`focal-to-jammy`,
`jammy-to-noble`) after each hop validates PASS.

### Verify export

```bash
find artifacts/upgrade-discovery -maxdepth 2 -type f -print
sha256sum -c artifacts/upgrade-discovery/<hop>/checksums.sha256
column -t -s $'\t' artifacts/upgrade-discovery/index.tsv
```

`finalize-hop` / `repair-hop` rebuilds manifests so stale mutable `by_hash` HTTP
404 failures (not unresolved, with secured repository metadata elsewhere) are
excluded from final `required-files.tsv` / `required-urls.tsv` while remaining
in `failed-requests.tsv`. Evidence records
`historical_non_required_failures` / `historical_non_required_failure_reasons`.
Validation keeps the strict identity
`required_files == resolved_files + unresolved_files`.

`export-hop` refuses FAIL / unresolved rows and blocking failed requests, stages
under `artifacts/upgrade-discovery/.staging-<hop>-<pid>/`, then atomically
replaces `<hop>/` and refreshes `index.tsv` (one row per hop, fixed order).
`failed-requests.tsv` is always copied as historical evidence. Stale `by_hash`
404 rows may be non-blocking when validation is PASS and counts identity holds;
`export-summary.json` / `index.tsv` record `failed_requests_total` /
`_blocking` / `_non_blocking` plus `non_blocking_failure_reasons`. Package
`.deb` / release-upgrader failures and failures linked to unresolved rows still
block export.

## Recording method

`start-recording` requires a successful `before-hop` (including
`before/file-manifest.tsv`). It then:

1. Clears any prior proxy log
2. Starts a local HTTP forward proxy (default `127.0.0.1:18080`)
3. Installs `/etc/apt/apt.conf.d/99upgrade-discovery-recorder` with
   `Acquire::http::Proxy "http://127.0.0.1:<port>/"`
4. Sets `Acquire::https::Proxy "DIRECT"` (HTTPS full URL / `.deb` body capture
   via CONNECT is **not** supported — do not treat HTTPS as recorded)
5. Verifies `apt-config dump` shows the HTTP proxy
6. Runs a proxy self-test against the recorder's built-in endpoint
   (`GET /dur-recorder-self-test/<marker>`, no upstream) and refuses
   `phase=recording` if the marker is missing from `proxy-access.log`.
   This avoids `NO_PROXY` bypass and absolute-URL client quirks on Xenial.
7. Snapshots apt/dpkg/dist-upgrade log offsets

The recorder streams each upstream HTTP 200 body to the client while writing a
durable copy under `runtime/deb-cache/<url-sha256[0:2]>/<url-sha256[2:4]>/<url-sha256>`
(atomic temp + fsync + rename). Basename collisions (InRelease, by-hash, …) are
avoided. APT may delete `/var/cache/apt/archives` copies; recorder objects remain.

`stop-recording` stops the proxy and restores prior APT proxy settings.
After a crash, run `restore-apt-proxy` with the same `--output-dir`.

`validate` fails when unresolved package/file rows remain, when an HTTP 200
response lacks a stored body, on SHA256 mismatch, or when release-upgrader
`*.tar.gz` / `*.gpg` bodies are missing. Self-test URLs are excluded from
required/unresolved manifests. HTTP 304 is accepted only if a prior stored body
exists.

`repair-hop` re-downloads unresolved URLs, appends `runtime/repair-access.log`,
rebuilds manifests/`evidence.json` (with `recovered_post_hop=true`), and
re-runs validate without deleting before/after/runtime evidence.
When a repair GET returns HTTP 304 with no stored body, it retries once with an
unconditional GET (`Cache-Control: no-cache, no-store, max-age=0`,
`Pragma: no-cache`, `Accept-Encoding: identity`, no validators) and a
`dur_repair_nonce` cache-busting query parameter. `original_url` and the object
key stay on the pre-nonce URL; `final_url` records the actual request URL.

Set `DUR_DRY_RECORDING=1` to skip binding the proxy (fixture/tests). APT proxy
config is still installed under `DUR_HOST_ROOT` when that override is set.

## Tests

```bash
bash tests/test_discover_upgrade_requirements.sh
python3 tests/check_py35_syntax.py
```

Fixture-only: no apt upgrade, do-release-upgrade, or reboot.

### Live Ubuntu 16.04 functional retest (HTTP archives, no release upgrade)

```bash
OUT=/opt/aelladata/test-run-discovery
sudo ./scripts/discover-upgrade-requirements.sh init \
  --from 16.04 --to 18.04 --output-dir "$OUT"
sudo ./scripts/discover-upgrade-requirements.sh before-hop --output-dir "$OUT"
# Confirm before/file-manifest.tsv exists and phase is before_collected
sudo ./scripts/discover-upgrade-requirements.sh start-recording --output-dir "$OUT"
# Confirm:
#   apt-config dump | grep -i Acquire::http::Proxy
#   /etc/apt/apt.conf.d/99upgrade-discovery-recorder exists
# Force a real download (avoid /var/cache/apt/archives hits), e.g.:
sudo apt-get -o Dir::Cache::Archives=/var/tmp/dur-apt-archives \
  -o Dir::Cache::pkgcache="" -o Dir::Cache::srcpkgcache="" \
  -o Acquire::Retries=1 update
sudo apt-get -o Dir::Cache::Archives=/var/tmp/dur-apt-archives \
  -o Dir::Cache::pkgcache="" -o Dir::Cache::srcpkgcache="" \
  --download-only --reinstall install bash
# Confirm proxy-access.log has full URL + status + sha256/local_path for .deb
# and runtime/deb-cache contains the .deb
sudo ./scripts/discover-upgrade-requirements.sh stop-recording --output-dir "$OUT"
# Confirm APT proxy conf removed / previous settings restored
```
