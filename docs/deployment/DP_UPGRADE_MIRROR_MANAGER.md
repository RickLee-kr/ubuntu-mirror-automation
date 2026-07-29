# DP Ubuntu Upgrade Mirror Manager

## Purpose

Build a DP Ubuntu upgrade HTTP mirror server in one fixed workflow:

1. Download Ubuntu OS Core from Cloudflare R2
2. Verify OS Core checksums
3. Download DP Phase 2 artifacts from ACPS (GUI credentials + target version)
4. Verify ACPS checksums and upstream bringup baseline
5. Apply the local patched bringup
6. Materialize one Phase 1 OS mirror set and one Phase 2 bundle
7. Serve clients over HTTP only

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

```bash
sudo ./scripts/ubuntu-offline-mirror.sh mirror-manager
# or
sudo ./scripts/install-dp-upgrade-mirror.sh mirror-manager
```

## GUI menu

1. Configuration
2. Download and Prepare Upgrade Files
3. Verify Upgrade Readiness
4. Enable HTTP Distribution
5. Show Current Status
6. View Logs
7. Show DP Client Upgrade Instructions
0. Exit

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

## Download and Prepare

Automatic sequence: config check → R2 download (`.part`, safe resume, retry) → OS Core
verify/extract → ACPS download → checksum → upstream bringup drift gate → patched
bringup → Phase 2 bundle (9 entries) → place final HTTP files → delete download
cache/staging.

Resume rules for the R2 package download:

- Requests send `Cache-Control: no-cache` and `Pragma: no-cache`.
- HTTP 206 with matching `Content-Range` start → append to `.part` only.
- HTTP 200 while a `.part` exists (Range ignored) → discard `.part` and replace
  (never append a full body onto a partial).
- Invalid `Content-Range` → fail; do not finalize.

## Storage

One final OS data set and one final DP bundle. No `releases/<timestamp>/`, no
`current`/`previous` symlinks, no `published.previous`.

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
under `/client/`.

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
downloads, production path changes, and nginx reload require separate operator
approval / canary on a fresh mirror VM.
