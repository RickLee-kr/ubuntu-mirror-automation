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
```

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

`stop-recording` stops the proxy and restores prior APT proxy settings.
After a crash, run `restore-apt-proxy` with the same `--output-dir`.

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
