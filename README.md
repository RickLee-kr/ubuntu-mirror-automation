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

### Mirror Server sizing

| Resource | Baseline | Recommendation / notes |
|----------|----------|------------------------|
| OS | Clean **Ubuntu 24.04 LTS amd64** | Server or minimal installation |
| CPU | **2 vCPU** | 4 vCPU recommended to reduce SHA256 verification and tar creation time |
| Memory | **4 GB RAM** | 8 GB recommended for operational headroom |
| Disk | **100 GB total** | Validated on the current test Mirror Server with Ubuntu OS and all mirror data on one disk |
| Network | **100 Mbps or faster** outbound | Faster connectivity reduces the initial R2 and ACPS download time |
| Distribution | **TCP 80** inbound from DP hosts | nginx HTTP mirror distribution |

The current workflow does **not** build a full Ubuntu archive mirror. It keeps only
one discovery-exact selective OS data set and one DP 6.5.0 Phase 2 bundle. For the
current artifacts:

- R2 OS Core / selective tree: approximately **3.4 GiB**
- Phase 2 final bundle: approximately **28.2 GiB**
- Fresh Download and Prepare projected peak: approximately **70 GiB**
- Tested disk configuration: **one 100 GB disk including Ubuntu OS and mirror data**

A separate data disk is optional, not required. When a separate filesystem is
used, `/var/spool/apt-mirror`, `.install-cache`, `selective`, and `dp-phase2`
must remain on the same filesystem because the workflow uses hard links and
atomic rename operations.

Other requirements:

- `sudo` / root
- An operator-confirmed static IPv4 address on an active interface
- Outbound HTTPS to:
  - `https://xdrsolutions.uk` (R2 OS Core)
  - fixed ACPS endpoint (credentials entered in GUI)
  - Ubuntu apt repositories (bootstrap package install only)
- Port **80** available for HTTP distribution

At **Download and Prepare**, the application calculates the exact free-space
requirement from the current R2 package size, extracted OS payload, ACPS
Content-Length, Phase 2 bundle output, metadata overhead, and a safety reserve
of at least **10 GiB**. Insufficient space fails closed before the large build
steps. Therefore **100 GB or larger** is the supported baseline for the current
artifact set; future larger artifacts are governed by the same preflight rather
than by an inflated fixed recommendation such as 500 GB.

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
Workflow: Configuration → Download → Enable HTTP → Verify Readiness
Progress: 3 of 4 workflow steps completed

1 Configuration [COMPLETED]
2 Download and Prepare Upgrade Files [COMPLETED]
3 Enable HTTP Distribution [COMPLETED]
4 Verify Upgrade Readiness
5 Show Current Status
6 View Logs
7 Show DP Client Upgrade Commands
0 Exit
```

`[COMPLETED]` means the step is currently valid. The label is removed automatically if its configuration, artifacts, HTTP service, or readiness state is no longer valid. SHA256 verification displays a heartbeat every 30 seconds.

Enable HTTP (3) before Verify Readiness (4). Menu 7 prints three-line DP hop command blocks and saves them to `/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`.

### 1. Configuration

Enter only:

- Preparation Mode
  - Full OS Upgrade + Phase 2
  - Phase 2 Only — DP is already running Ubuntu 24.04
- ACPS Username
- ACPS Password (password box; not echoed)
- Test ACPS Connection
- Save Configuration

Configuration footer (always shown):

```
Starting DP Version: 6.2.0 / 6.3.0 / 6.4.0 / 6.5.0
Phase 2 Target:      6.5.0 고정
DP OS version: 16.04

If the DP is already running Ubuntu 24.04, select Phase 2 Only.

Login shells: operators do not manually run `getent`/`chsh`/`usermod` for
aella/root in Full mode. The Xenial-to-Bionic client sets both shells to
`/bin/bash` after upgrade confirmation and re-verifies with `getent`.

Each Mirror Server install resolves its own primary IPv4 and embeds that
`MIRROR_HTTP_URL` into the four OS-hop clients. Do not hardcode development
or test server addresses into source; install.sh detects the current host.

```

Phase 2 Target is fixed at 6.5.0 and is not editable. Starting DP Version is detected on the DP (not configured on the Mirror Server).

Decision matrix:

| Starting DP | Starting OS | Action | Final State |
| --- | --- | --- | --- |
| 6.2 / 6.3 / 6.4 | 16.04 | Phase 1 + Phase 2 | DP 6.5.0 / Ubuntu 24.04 |
| 6.2 / 6.3 / 6.4 | 24.04 | Phase 2 Only | DP 6.5.0 / Ubuntu 24.04 |
| 6.5.0 | 16.04 | Phase 1 + recovery | DP 6.5.0 / Ubuntu 24.04 |
| 6.5.0 | 24.04 healthy | No action | DP 6.5.0 / Ubuntu 24.04 |
| 6.5.0 | 24.04 recovery state | Gated recovery | DP 6.5.0 / Ubuntu 24.04 |

Credentials are stored as root-owned mode `600` under `/etc/ubuntu-mirror/dp-upgrade-mirror.conf` and are redacted from logs.

### 2. Download and Prepare Upgrade Files

**Full mode** downloads OS Core from R2, materializes the selective OS tree, then prepares the single DP 6.5.0 Phase 2 bundle. The R2 package is removed immediately after OS materialize. A valid existing 6.5.0 final bundle is reused (no ACPS re-download or rebuild).

**Phase 2 Only** skips R2 and OS hops; it prepares or reuses the same single 6.5.0 Phase 2 bundle only.

Mirror server disk requirement: **100 GB total including Ubuntu OS and mirror data** for the current 6.5.0 artifact set. This configuration is validated on the test Mirror Server; the projected fresh-prepare peak is approximately **70 GiB**, and the exact free-space preflight runs before the large download/build steps.

### 3. Enable HTTP Distribution

Requires Download and Prepare artifacts. Validates the prepared layout (HTTP probes deferred until nginx is up), installs/enables the nginx site, runs `nginx -t`, reloads nginx, then runs live HTTP validation. Sets `HTTP_DISTRIBUTION=ENABLED` only on success. On failure, restores the previous nginx site and does not mark ENABLED.

### 4. Verify Upgrade Readiness

Requires HTTP distribution ENABLED. Probes live HTTP URLs (200-only) for stage helper and Phase 2 paths; Full mode also checks OS hop scripts and offline metadata. Sets `UPGRADE_READINESS=PASS` only when status keys and HTTP checks succeed. Status shows exactly one of: `PASS`, `NOT VERIFIED`, `NOT READY`, or `FAIL`.

### 5–7. Status, logs, client commands

Status shows Supported Starting DP Versions, fixed Phase 2 Target 6.5.0, Preparation Mode, Starting/Final OS, and Upgrade Readiness. Menu 7 asks topology only (no version prompts). Full mode prints OS hops 16.04→24.04 then stage/bringup; Phase 2 Only prints Ubuntu 24.04 prerequisites then stage/bringup. Stage uses `--target-version 6.5.0 --same-version-recovery` with source auto-detection on the DP.

Worker `--worker-ips` may use management IPs or cluster IPs; cluster IPs are recommended when reachable. Do not include the master IP.

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

Open Mirror Manager menu **7 Show DP Client Upgrade Commands** for the exact three-line hop command blocks (download + authenticate + execute) for this host’s mirror URL. Prefer those blocks over hand-written examples. Copy all three lines together, including trailing backslashes on the first two lines.

Each OS hop is one logical Bash command shown on three physical lines that authenticates `dp-client-command-runner.sh`, then runs the hop client.

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

## Developer testing

See [docs/development/testing.md](docs/development/testing.md) for Ubuntu 24.04
dependencies, hermetic fixtures, and ShellCheck policy.

```bash
bash tests/run_all.sh
```
