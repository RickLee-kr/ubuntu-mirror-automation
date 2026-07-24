# Bionic → Focal offline OS upgrade (Phase 1 OS-only)

- Hop ID: `bionic-to-focal`
- Source: Ubuntu 18.04 Bionic
- Target: Ubuntu 20.04 Focal
- Scope: Phase 1 OS-only (no DP product bringup / cluster / sensor validation)

This hop is independent of Xenial → Bionic. Do **not** reuse a successful Bionic
evidence VM for integration testing — deploy or snapshot-restore a clean Bionic DP.

## Prerequisites

- Selective mirror READY with hop gates for `bionic-to-focal` PASS
- Published repository: `http://221.139.249.111/hops/bionic-to-focal/ubuntu`
- Mirror signer fingerprint: `D1FF722556ED95F5E779BAE66B1BA1673A997CA5`
- Client manifest signer: `C786FE9887290E2CF759271DFDD38BE958EABD4A`
- Suites registered: `bionic`, `bionic-updates`, `bionic-security`, `bionic-backports`,
  `focal`, `focal-updates`, `focal-security`, `focal-backports`

## Discovery

Discovery artifacts live under `artifacts/upgrade-discovery/bionic-to-focal/`.

```bash
# Collector (clean Bionic host with discovery tooling) — do not invent package plans
./scripts/discover-upgrade-requirements.sh   # hop resolved from host OS
```

Validation must be PASS with unresolved packages/files = 0 before materialize.

## Selective mirror lifecycle

```bash
sudo ./scripts/ubuntu-offline-mirror.sh plan-selective
sudo ./scripts/ubuntu-offline-mirror.sh materialize-selective bionic-to-focal
sudo ./scripts/ubuntu-offline-mirror.sh verify-selective
sudo ./scripts/ubuntu-offline-mirror.sh publish-selective
```

Or hop refresh without rebuilding siblings:

```bash
sudo ./scripts/ubuntu-offline-mirror.sh refresh-hop-selective bionic-to-focal
```

PASS gates include Packages/deb metadata consistency, suite semantics, GPG, and
offline DistUpgrade target source checks (`gate_*_bionic-to-focal=PASS` in READY).

## Client build (source template → signed artifact)

Never edit generated artifacts by hand.

```bash
# Unsigned test only (artifacts/client-unsigned-test/)
./scripts/ubuntu-offline-mirror.sh build-client-bionic-to-focal \
  --mirror-base http://221.139.249.111 --skip-sign

# Production signed
./scripts/ubuntu-offline-mirror.sh build-client-bionic-to-focal \
  --mirror-base http://221.139.249.111
```

- Source template: `client/dp-offline-upgrade-bionic-to-focal.sh.in`
- Production artifact: `artifacts/client/dp-offline-upgrade-bionic-to-focal.sh`

Expected build logs:

- `CLIENT_MANIFEST_SIGNATURE_MODE=PRODUCTION_SIGNED`
- `CLIENT_MANIFEST_SIGNATURE_STATUS=PASS`
- `CLIENT_MANIFEST_SIGNER_FINGERPRINT=C786FE9887290E2CF759271DFDD38BE958EABD4A`
- `CLIENT_MANIFEST_UNSIGNED_TEST_COUNT=0`

## Atomic deploy

```bash
sudo ./scripts/deploy-client-bionic-to-focal-atomic.sh
```

HTTP endpoints:

- `http://221.139.249.111/client/dp-offline-upgrade-bionic-to-focal.sh`
- `http://221.139.249.111/client/dp-offline-upgrade-bionic-to-focal.sh.sha256`

Deploy must leave selective READY unchanged and verify HTTP SHA + signature.

## Clean Bionic test VM

1. Deploy a **new** Ubuntu 18.04 Bionic DP (or restore a pre-upgrade snapshot).
2. Do **not** use the Xenial→Bionic success evidence VM.
3. Snapshot before package mutation.
4. Download + SHA + signature verify the client.
5. Run as root:

```bash
curl -fsSO http://221.139.249.111/client/dp-offline-upgrade-bionic-to-focal.sh
curl -fsSO http://221.139.249.111/client/dp-offline-upgrade-bionic-to-focal.sh.sha256
sha256sum -c dp-offline-upgrade-bionic-to-focal.sh.sha256
sudo bash ./dp-offline-upgrade-bionic-to-focal.sh
# confirmation phrase:
UPGRADE-BIONIC-TO-FOCAL
```

## Monitoring

- Detached unit: `stellar-offline-os-upgrade.service`
- Postboot unit: `stellar-offline-os-upgrade-postboot.service`
- State: `/opt/aelladata/os-upgrade/offline/state`
- Log: `/var/log/aella/offline_os_upgrade.log`
- Ctrl+C ends the foreground monitor only; upgrade continues under systemd.

Expected states: `PREPARING_BIONIC` → `UPGRADING_BIONIC_TO_FOCAL` → `REBOOTING` → `COMPLETED_FOCAL`

## Postboot PASS criteria

- `VERSION_ID=20.04` / `VERSION_CODENAME=focal`
- Focal-series kernel booted (exact version from discovery/plan, not hardcoded)
- `state=COMPLETED_FOCAL`
- `dpkg --audit` empty
- `os_validation_result=PASS`
- `product_validation_result=NOT_RUN_PHASE1`
- conffile prompts = 0; policy cleanup logged
- official archive references = 0; local selective mirror only
- Does **not** auto-start 20.04 → 22.04

## Failure classification

| Class | Meaning | Action |
|-------|---------|--------|
| `FAILED_BEFORE_PACKAGE_TRANSITION` | `ROLLBACK_ELIGIBLE=YES` | Temporary sources/holds/policy restored; may retry after fix |
| `FAILED_AFTER_PACKAGE_TRANSITION` | `ROLLBACK_ELIGIBLE=NO` | Preserve evidence; restore snapshot or new VM — never reuse |

## Evidence paths

- Client log: `/var/log/aella/offline_os_upgrade.log`
- Effective source gate: `/var/log/aella/distupgrade_effective_source_gate.log`
- DistUpgrade: `/var/log/dist-upgrade/`
- State/markers: `/opt/aelladata/os-upgrade/offline/`
