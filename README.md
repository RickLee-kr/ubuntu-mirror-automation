# DP Ubuntu Upgrade Mirror Manager

Offline upgrade mirror for Stellar Cyber DP hosts:
**Ubuntu 16.04 → 18.04 → 20.04 → 22.04 → 24.04**, then DP Phase 2 bringup.

| Source | Role |
|--------|------|
| Cloudflare R2 | OS Core selective APT tree (Mirror Manager host only) |
| ACPS | DP Phase 2 artifacts (Mirror Manager host only) |
| Mirror Server HTTP | **Only** source used by DP clients |

```
INSTALLATION_MODE_COUNT=1
OS_CORE_SOURCE=R2
DP_PHASE2_SOURCE=ACPS
CLIENT_DOWNLOAD_SOURCE=MIRROR_SERVER_ONLY
PROJECT_ROLLBACK_SUPPORTED=NO
RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
```

## Supported environment

- Clean **Ubuntu 24.04 LTS amd64**
- `sudo` / root
- Outbound HTTPS to:
  - `https://xdrsolutions.uk` (R2 OS Core)
  - fixed ACPS endpoint (credentials entered in GUI)
  - Ubuntu apt repositories (bootstrap package install only)
- Enough free space under `/var/spool/apt-mirror` (exact requirement is calculated at **Download and Prepare** from package size + extract + Phase 2 + safety margin)
- Port **80** for HTTP distribution

## Install

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

### What `sudo ./install.sh` does

1. Confirms Ubuntu 24.04 LTS amd64, root, systemd, apt
2. Installs required packages (`nginx`, `whiptail`, `curl`, `python3`, …) — not `apt-mirror`
3. Creates mirror directories (does **not** format disks)
4. Installs Mirror Manager runtime under `/usr/local/lib/ubuntu-mirror`
5. Installs nginx base site for the final HTTP layout
6. On an interactive TTY, starts the Mirror Manager GUI

Large R2 / ACPS downloads are **not** started by bootstrap. Start them from the GUI.

Non-interactive / CI:

```bash
sudo ./install.sh --non-interactive
```

Re-open the GUI later (no git checkout required):

```bash
sudo ubuntu-offline-mirror mirror-manager
```

## Mirror Manager GUI

```
1. Configuration
2. Download and Prepare Upgrade Files
3. Verify Upgrade Readiness
4. Enable HTTP Distribution
5. Show Current Status
6. View Logs
7. Show DP Client Upgrade Instructions
0. Exit
```

### 1. Configuration

Enter only:

- Target DP Version (default `6.5.0`)
- ACPS Username
- ACPS Password (password box; not echoed)
- Test ACPS Connection
- Save Configuration

Read-only:

- ACPS Server: fixed
- OS Core Source: Cloudflare R2 — fixed

There is no install-mode menu, no local/USB OS Core picker, no R2/ACPS URL editor, and no rollback menu.

Credentials are stored as root-owned mode `600` under `/etc/ubuntu-mirror/dp-upgrade-mirror.conf` and are redacted from logs.

### 2. Download and Prepare Upgrade Files

Downloads OS Core from R2 (safe resume), verifies checksums, materializes one selective tree, downloads ACPS Phase 2, applies the patched bringup, and publishes one final Phase 2 bundle. Staging is never served over HTTP.

### 3. Verify Upgrade Readiness

Expect:

```
CONFIGURATION_READY=PASS
R2_OS_CORE_DOWNLOADED=PASS
R2_OS_CORE_CHECKSUM=PASS
OS_MIRROR_READY=PASS
ACPS_CONNECTION=PASS
ACPS_PHASE2_DOWNLOADED=PASS
ACPS_CHECKSUM=PASS
UPSTREAM_BRINGUP_DRIFT=NO
PATCHED_BRINGUP_APPLIED=YES
PHASE2_BUNDLE_ENTRY_COUNT=9
PHASE2_BUNDLE_CHECKSUM=PASS
CLIENT_FILES_READY=PASS
HTTP_CONFIGURATION_READY=PASS
UPGRADE_READINESS=PASS
```

### 4. Enable HTTP Distribution

Validates the prepared layout, installs/enables the nginx site, runs `nginx -t`, reloads nginx, and smoke-tests concrete artifact URLs. Sets `HTTP_DISTRIBUTION=ENABLED` only on success. On failure, restores the previous nginx site and does not mark ENABLED.

### 5–7. Status, logs, client instructions

Status and redacted logs live under `/var/log/ubuntu-mirror-automation/`. Menu 7 prints DP client steps that use the mirror IP only.

## HTTP layout

One final selective tree and one final Phase 2 version directory (no `current`/`previous`/`releases/` generations):

```
/ubuntu/
/ubuntu-security/
/offline/
/hops/
/client/
/dp-phase2/<version>/release.env
/dp-phase2/<version>/dp_bundle_<version>-current.tar
/dp-phase2/<version>/dp_bundle_<version>-current.tar.sha256
```

The `current` token in the Phase 2 **filename** is the client contract name only, not a symlink generation.

### HTTP verify examples

Replace `MIRROR_IP` with the mirror server address:

```bash
curl -fsSI http://MIRROR_IP/ubuntu/
curl -fsSI http://MIRROR_IP/ubuntu-security/
curl -fsSI http://MIRROR_IP/offline/
curl -fsSI http://MIRROR_IP/client/dp-offline-upgrade-xenial-to-bionic.sh
curl -fsS  http://MIRROR_IP/dp-phase2/6.5.0/release.env
curl -fsSI http://MIRROR_IP/dp-phase2/6.5.0/dp_bundle_6.5.0-current.tar.sha256
```

Root URL `/` returning 403/404 is ignored; use the concrete paths above.

## DP client usage

DP clients must **not** reach R2 or ACPS. Use the mirror HTTP address only.

Example Phase 1 hop:

```bash
curl -fsSO http://MIRROR_IP/client/dp-offline-upgrade-xenial-to-bionic.sh
curl -fsSO http://MIRROR_IP/client/dp-offline-upgrade-xenial-to-bionic.sh.sha256
sha256sum -c dp-offline-upgrade-xenial-to-bionic.sh.sha256
sudo bash ./dp-offline-upgrade-xenial-to-bionic.sh
```

Repeat for bionic→focal, focal→jammy, jammy→noble. Then stage Phase 2 from the same mirror:

```bash
sudo bash stage-dp-phase2.sh \
  --source-dp-version <current-dp> \
  --target-version 6.5.0 \
  --mirror-url http://MIRROR_IP
```

## Jammy (22.04) intermediate note

On Ubuntu 22.04 during the hop chain:

- `aella_cli` may be absent
- kubelet v1.19.12 can mismatch the Docker API and stop workloads

Do **not** treat this as a Phase 1 failure. Do **not** temporarily repair kubelet/Docker. Continue OS upgrade to 24.04; Phase 2 `bringup_py3` reconfigures runtime.

## Recovery

```
PROJECT_ROLLBACK_SUPPORTED=NO
OS_ROLLBACK_SUPPORTED=NO
DP_RUNTIME_ROLLBACK_SUPPORTED=NO
RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
```

Take a full hypervisor snapshot of the DP VM before upgrade. Intermediate Ubuntu releases are not recovery points. This project does not provide rollback commands.

## Re-run / failure recovery

- `sudo ./install.sh` is idempotent (safe to re-run)
- Re-run **Download and Prepare** after a failed download (R2 `.part` resume is supported)
- Re-enter ACPS credentials in Configuration if needed
- Check logs via GUI menu 6 or `/var/log/ubuntu-mirror-automation/`

## Status and logs

```bash
sudo ubuntu-offline-mirror mirror-manager   # GUI: status / logs
ls -lt /var/log/ubuntu-mirror-automation/
cat /etc/ubuntu-mirror/dp-upgrade-mirror.status
```

## Design docs

- [docs/deployment/DP_UPGRADE_MIRROR_MANAGER.md](docs/deployment/DP_UPGRADE_MIRROR_MANAGER.md)
- [docs/deployment/OS_CORE_ARTIFACT_FORMAT.md](docs/deployment/OS_CORE_ARTIFACT_FORMAT.md)

## Development tests

```bash
bash tests/run_all.sh
```
