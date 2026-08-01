# DP Ubuntu Upgrade Mirror Manager

## Purpose

Build a DP Ubuntu upgrade HTTP mirror server in one fixed workflow:

1. Bootstrap a clean Ubuntu 24.04 host with `sudo ./install.sh`
2. Configure Target DP Version + ACPS credentials in the GUI
3. Download Ubuntu OS Core from Cloudflare R2
4. Verify OS Core checksums
5. Download DP Phase 2 artifacts from ACPS
6. Verify ACPS checksums and upstream bringup baseline
7. Apply the local patched bringup
8. Materialize one Phase 1 OS mirror set and one Phase 2 bundle
9. Enable HTTP distribution (real nginx enable + smoke tests)
10. Serve clients over HTTP only

Contracts:

```
INSTALLATION_MODE_COUNT=1
OS_CORE_SOURCE=R2
DP_PHASE2_SOURCE=ACPS
CLIENT_R2_ACCESS=NO
CLIENT_ACPS_ACCESS=NO
CLIENT_DOWNLOAD_SOURCE=MIRROR_SERVER_ONLY
```

## Entrypoint

Fresh host bootstrap (authoritative):

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

Re-open GUI after install (system command; no checkout required):

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Repository-relative equivalents (development):

```bash
sudo ./scripts/ubuntu-offline-mirror.sh mirror-manager
sudo ./scripts/install-dp-upgrade-mirror.sh mirror-manager
```

## GUI menu

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

`[COMPLETED]` means the step is currently valid.
The label is removed automatically if its configuration, artifacts, HTTP service, or readiness state is no longer valid.
SHA256 verification displays a heartbeat every 30 seconds.

Order is intentional: enable HTTP before verifying readiness (readiness checks live HTTP URLs).

Menu 3 refuses to run until Download and Prepare has produced OS + Phase 2 artifacts.
Menu 4 refuses to PASS until HTTP distribution is ENABLED.

Menu 7 shows copy-paste one-line DP commands (download + checksum + execute) and
writes the same text to
`/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`.

There is no install-mode menu, no local OS Core path picker, no R2/ACPS URL editor, and no rollback menu.

## Configuration

GUI fields only:

- Target DP Version (default `6.5.0`)
- ACPS Username
- ACPS Password
- Test ACPS Connection
- Save Configuration

Read-only:

- ACPS Server: fixed (`https://acps.stellarcyber.ai/provision/aelladeb_py3`)
- OS Core Source: Cloudflare R2 — configured by installer

R2 URL is a single code constant (`OS_CORE_R2_URL_CONSTANT` in
`scripts/lib/mirror_manager_common.sh`). It is not user-editable. If unset,
prepare stops with `CONFIGURATION_REQUIRED`.

```
OS_CORE_SOURCE=R2
R2_PRODUCTION_URL_CONFIGURED=YES
R2_PUBLIC_BASE_URL=https://xdrsolutions.uk
OS_CORE_PACKAGE_URL=https://xdrsolutions.uk/ubuntu-os-core/ubuntu-os-core-xenial-to-noble.tar
```

The checksum sidecar URL is derived as `${OS_CORE_PACKAGE_URL}.sha256` (no separate
constant). Clients never download from R2; only the Mirror Manager host does.

Credentials are stored root-owned mode `600` at
`/etc/ubuntu-mirror/dp-upgrade-mirror.conf` and redacted from logs.

## Download and Prepare

Automatic sequence: config check → client artifact check → R2 download
(`.part`, safe resume, retry) → OS Core verify/extract → ACPS download →
checksum → upstream bringup drift gate → patched bringup → Phase 2 bundle
(9 entries) → place final HTTP files → delete download cache/staging.

### Expected duration (disk-dependent)

These times vary by host disk throughput. A long silent gap is **not** normal:
the manager emits a heartbeat at least every 30 seconds during long steps.

| Step | Algorithm / action | Typical duration |
| --- | --- | --- |
| ACPS `images-*.tar` verification | **SHA256** (not SHA1) | approximately 5–10 minutes |
| Small ACPS sidecars / bringup | **SHA1** | seconds |
| Phase 2 bundle creation (`tar -cf`) | archive write | several minutes |
| Bundle SHA256 sidecar generation | **SHA256** full read | approximately 5–10 minutes |
| Final published bundle verification | **SHA256** after atomic publish | approximately 5–10 minutes |

Do not close the terminal or interrupt while heartbeats / progress lines are
printing. Logs show the current `DP_PHASE=` name and `elapsed=` seconds.

Integrity policy (same-filesystem hardlink pipeline):

- Source `images-*.tar` is SHA256-verified once after ACPS download.
- Hard-linked work-tree copies of that inode are not re-hashed.
- Bundle SHA256 is computed when the `.new` archive is created, then verified
  once more on the published final path (at most two full bundle reads).

Resume rules for the R2 package download:

- Requests send `Cache-Control: no-cache` and `Pragma: no-cache`.
- HTTP 206 with matching `Content-Range` start → append to `.part` only.
- HTTP 200 while a `.part` exists (Range ignored) → discard `.part` and replace
  (never append a full body onto a partial).
- Invalid `Content-Range` → fail; do not finalize.

## Enable HTTP Distribution

Not a status-only flag. On success the manager:

1. Validates prepared layout and client files
2. Renders/installs the nginx site
3. Enables the site symlink and disables the default site when needed
4. Runs `nginx -t`
5. `systemctl enable` + reload/start nginx
6. Smoke-tests concrete artifact URLs
7. Sets `HTTP_DISTRIBUTION=ENABLED` only after smoke PASS

On failure the previous nginx site is restored and ENABLED is not recorded.

## Storage

One final OS data set and one final DP bundle. No `releases/<timestamp>/`, no
`current`/`previous` symlinks, no `published.previous`. Keep only one Target DP
Version artifact set on the mirror host.

Final DP files:

```
/var/spool/apt-mirror/dp-phase2/<version>/release.env
/var/spool/apt-mirror/dp-phase2/<version>/dp_bundle_<version>-current.tar
/var/spool/apt-mirror/dp-phase2/<version>/dp_bundle_<version>-current.tar.sha256
```

The `current` token in the bundle **filename** is the existing client contract
name only; it is not a symlink generation.

OS selective tree is materialized directly under `selective/` for nginx paths
`/ubuntu/`, `/ubuntu-security/`, `/offline/`, `/hops/`. Client scripts remain
under `/client/` and must include hop scripts plus `stage-dp-phase2.sh` and
checksum sidecars (`CLIENT_FILES_READY` rejects an empty directory).

### Disk sizing (selective R2 + ACPS workflow)

This workflow is **not** a 1TB/2TB full apt-mirror. Current DP 6.5.0 finals are
approximately:

| Artifact | Size (approx.) |
| --- | --- |
| R2 OS Core / selective tree | ~3.4 GiB |
| Phase 2 final bundle | ~28.2 GiB (30307553280 bytes) |
| Host after successful prepare | ~40 GiB used on a clean Ubuntu Server |

Download-and-prepare peak model (same filesystem, optimized pipeline):

- one ACPS source tree
- one bundle `.new` being written directly under `dp-phase2/<version>.new.<pid>/`
- OS payload materialize temp + small metadata overhead
- safety reserve: `max(10 GiB, 10% of filesystem)`
- existing final is retained until the new bundle verifies, then removed immediately

Hard requirements:

- `MM_MIRROR_ROOT`, `.install-cache`, `selective`, and `dp-phase2` must share one
  filesystem (hard links + atomic rename). Split mounts are blocked in preflight.
- Large ACPS payloads are hard-linked into the work staging dir; automatic full
  copy of large files is refused.
- ACPS cache/work is deleted as soon as the verified `.new` bundle exists, before
  the atomic publish rename.
- Checksums and entry-count checks are never skipped. Failed publishes restore the
  previous final artifact when present.

Sizing policy for current 6.5.0 data (clean install, one version, no stale
partials):

```
MINIMUM_SUPPORTED_DISK=100GB
RECOMMENDED_DISK=120GB
```

Preflight logs structured fields (`DISK_PREFLIGHT_*`). If a future ACPS bundle
grows beyond the available budget, prepare fails closed with `DISK_PREFLIGHT=FAIL`
rather than attempting multi-copy staging.

## Bringup drift gate

ACPS upstream bringup SHA1 must match
`vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh.upstream.sha1`.
Only then is
`vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh` applied.
Drift fails the install (`UPSTREAM_BRINGUP_DRIFT=YES`); patches are never
auto-ported onto new upstream.

## Client HTTP only

DP clients must use the mirror HTTP address only. They must not reach R2 or ACPS.

## Recovery boundary

```
PROJECT_ROLLBACK_SUPPORTED=NO
OS_ROLLBACK_SUPPORTED=NO
DP_RUNTIME_ROLLBACK_SUPPORTED=NO
RECOVERY_METHOD=HYPERVISOR_SNAPSHOT
RECOVERY_TARGET=PRE_UPGRADE_UBUNTU_16_04_STATE
INTERMEDIATE_OS_RECOVERY_SUPPORTED=NO
```

Create a full DP VM hypervisor snapshot before upgrade. Intermediate Ubuntu
versions are not recovery points. This project does not create or validate
snapshots and does not provide rollback commands.

## Production note

Repository tests use synthetic fixtures and mock HTTP only. Real R2/ACPS
downloads on a disposable fresh mirror VM require separate operator approval.
Bootstrap tests use temporary roots and must not modify production mirror data.
