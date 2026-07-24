# Ubuntu Mirror Server Automation

Selective offline Ubuntu upgrade mirror for Stellar Cyber DP baselines
(16.04 → 18.04 → 20.04 → 22.04 → 24.04), driven by discovery artifacts — **not** a general full Ubuntu mirror.

## Supported profile

**`offline-upgrade-selective`** (`config/offline-upgrade-profile.json`)

- Exact `.deb` payloads from `artifacts/upgrade-discovery`
- Hop-separated APT snapshots (deterministic package sets)
- Generated `Packages` / `Release` / `InRelease` via `apt-ftparchive`
- Local GPG signing (no `trusted=yes`)
- Meta-release + release upgraders
- Existing full mirror under `/var/spool/apt-mirror/mirror/...` is **seed only** (never auto-deleted)

## Operator flow

```bash
# 1) Analyze discovery (safe on ops host; no copy/download)
sudo ./scripts/ubuntu-offline-mirror.sh plan-selective

# 2) Materialize into /var/spool/apt-mirror/selective/staging
#    (hardlink/reflink/copy from seed; download only missing)
sudo ./scripts/ubuntu-offline-mirror.sh materialize-selective

# 3) Pre-publish verify (staging only — independent of production nginx)
#    Checks plan/discovery checksums, .deb SHA256/size, Packages coverage,
#    Release/InRelease + local GPG, upgraders/meta-release, isolated APT (file://).
#    PASS here does NOT mean published and does NOT write READY.
sudo ./scripts/ubuntu-offline-mirror.sh verify-selective

# 3b) One-time / idempotent: ensure production nginx root is selective/current
#     (legacy installs may still point at /var/spool/apt-mirror/mirror).
sudo ./scripts/ubuntu-offline-mirror.sh migrate-nginx-selective

# 4) Atomic publish + post-publish HTTP smoke (concrete Release/Packages/.deb URLs)
#    Preflight fails fast with SELECTIVE_NGINX_EFFECTIVE_ROOT_MISMATCH if nginx
#    still serves the legacy full-mirror root (no HTTP endpoint storm).
#    Switches selective/current → published; rolls back on HTTP failure; writes READY only on PASS.
#    nginx URL `/` is NOT a readiness criterion (403/404 on `/` is ignored).
sudo ./scripts/ubuntu-offline-mirror.sh publish-selective

# Status — READY only after publish + post-publish HTTP PASS
sudo ./scripts/ubuntu-offline-mirror.sh status
```

`sync` / full `apt-mirror` are **blocked** under this profile (`UNSUPPORTED_FULL_MIRROR_SYNC`).

## Install

```bash
sudo ./install.sh
```

Installs tooling, prepares `/var/spool/apt-mirror/selective`, runs **plan-selective**, and wires existing `mirrorctl` / systemd / nginx to the selective workflow. It does not publish, does not delete the seed mirror, and does not start a full apt-mirror sync.

| Command | Purpose |
|---------|---------|
| `sudo ./install.sh` | Install + plan-selective (menu or `--no-menu`) |
| `sudo mirrorctl sync start` | Start `materialize-selective` via apt-mirror.service |
| `sudo mirrorctl watch` | Live progress dashboard |
| `sudo mirrorctl status` | Selective counts / READY |
| `sudo mirrorctl logs` | Materialize / service logs |
| `sudo mirrorctl sync stop` | Stop selective materialize safely |

Expected selective size ≈ **3.39 GiB** (3557 exact `.deb`s). `READY` only after pre-publish verify PASS **and** atomic publish with post-publish concrete HTTP smoke PASS.

## Client

### Phase 1 — Ubuntu OS-Only Offline Upgrade

Phase 1 upgrades Ubuntu only (`16.04 → 18.04 → 20.04 → 22.04 → 24.04`) via the offline mirror.
DP product install, topology, containers, and service health are **out of scope** (Phase 2).
An uninstalled DP image is a valid Phase 1 test input.

### One-hop offline OS upgrade (16.04 → 18.04 only)

Build the single deliverable script from the READY selective mirror (does not rematerialize/publish):

```bash
sudo ./scripts/ubuntu-offline-mirror.sh build-client-xenial-to-bionic \
  --mirror-base http://MIRROR_IP
```

Outputs:

- `artifacts/client/dp-offline-upgrade-xenial-to-bionic.sh` (also copied to `client/`)
- `artifacts/client/xenial-to-bionic/` (manifest, meta-release, announcements)
- `/var/spool/apt-mirror/client/` for nginx `/client/` (separate from selective READY tree)

On a Xenial host (installed or uninstalled DP image; after snapshot), run **only**:

```bash
sudo ./dp-offline-upgrade-xenial-to-bionic.sh --mode os-only
```

Default mode is already `OS_ONLY_PHASE1`. Optional override: `--mirror-base http://MIRROR_IP`.
This hop does **not** start 18.04→20.04 or DP product validation/bringup.
Phase 1 success for this hop = Ubuntu 18.04 boots with OS health PASS.

### APT client helpers (manual attach)

```bash
sudo ./client/client-setup.sh --mirror-url http://MIRROR_IP [--hop xenial-to-bionic]
./client/client-validate.sh --mirror-url http://MIRROR_IP
```

APT prefs disable Translation / DEP-11 / CNF / Contents / Sources. Prefer hop URL `/hops/<hop>/ubuntu`. `/ubuntu-security` aliases the same selective tree.

### How to confirm sync is complete

```bash
sudo ./scripts/ubuntu-offline-mirror.sh status
```

Look for selective `READY: yes` / `validation_result=PASS` after `publish-selective`.
Dashboard `State: READY` means the published selective mirror gates passed.

### How to delete existing mirror data

Do **not** delete the 2.2TB seed automatically. After selective verify+publish PASS,
review `selective/state/cleanup-plan.json` and only then manually remove the seed if
the selective tree is independently complete (no hardlink dependency).

## Development and Troubleshooting

- Unit tests: `python3 tests/test_selective_mirror.py`
- Profile tests: `python3 tests/test_upgrade_profile.py`
- Full suite: `bash tests/run_all.sh`
- Logs / status: `sudo mirrorctl status` (when installed)

### Git backup staging (no commit/push)

Do **not** paste `set -e` / `exit` audit blocks into an interactive SSH shell, and do **not** `source` the helper. Run only:

```bash
bash scripts/prepare-backup-staging.sh --audit-only
bash scripts/prepare-backup-staging.sh --stage
```

Audits staged blobs for complete PEM/PGP private-key blocks (not bare marker
substrings), and cross-checks production client script SHA pins against
sidecar/hop/manifest signature evidence. See [docs/operations.md](docs/operations.md)
→ **Git backup staging**.

## Docs

- [docs/operations.md](docs/operations.md)
- [docs/upgrade-discovery-analysis.md](docs/upgrade-discovery-analysis.md)
- [docs/discover-upgrade-requirements.md](docs/discover-upgrade-requirements.md)
