# Developer testing

Hermetic unit/integration suite for a clean clone. No R2/ACPS credentials, no
production `/var/spool/apt-mirror` state, and no downloads of upstream payloads.

## Dependencies (Ubuntu 24.04)

```bash
sudo apt-get update
sudo apt-get install -y bash python3 gpg gpgv shellcheck curl coreutils findutils gzip tar
```

Optional: `nginx` / `whiptail` are only needed for install/GUI paths, not `run_all`.

## Run

```bash
cd /path/to/ubuntu-mirror-automation
bash tests/run_all.sh
```

Individual suites under `tests/test_*.sh` and `tests/test_*.py` can be run the
same way. Prefer the suite entrypoint when validating a clean clone.

## Fixtures

Tracked fixtures live under `tests/fixtures/`:

| Path | Purpose |
|------|---------|
| `tests/fixtures/dp-upgrade-preflight/` | Preflight collection.log trees (`generate_fixtures.sh`) |
| `tests/fixtures/upgrade-discovery/` | Synthetic discovery TSV + durable analysis script |
| `tests/fixtures/distupgrade/bionic-upgrader/` | Minimal DistUpgradeConfigParser + `bionic.tar.gz` |

Do not rely on gitignored `artifacts/upgrade-discovery/` for unit tests.

## ShellCheck policy

Supported version: ShellCheck **0.9.0** (Ubuntu 24.04 `shellcheck` package).

- Product scripts: `tests/run_all.sh` runs `shellcheck -x` on scripts under
  `scripts/`, `lib/`, `client/` (excluding large hop clients), `install.sh`, etc.
- Excluded from ShellCheck scan (still `bash -n`):
  - `*/tests/*` — tests run their own shellcheck where needed
  - `*/artifacts/*` — generated client copies
  - `*/vendor/*` — upstream bringup; covered by extract + dedicated tests
  - `*/client/dp-offline-upgrade-*.sh` — validated by hop offline-upgrade tests + `bash -n`
- Excludes: `SC1090`/`SC1091` (dynamic `source`), plus intentional patterns
  (`SC1003`, `SC2009`, `SC2012`, `SC2016`, `SC2185`, `SC2094`, `SC2001`, `SC2002`)
  and a small shared set (`SC2015`, `SC2034`, `SC2119`, `SC2120`, `SC2317`).
- Individual test harnesses may add suite-specific `-e` codes with an inline
  comment explaining why.
- Extracted temp fragments must start with `# shellcheck shell=bash`.

## Clean-clone reproducibility

A fresh `git clone` plus the apt packages above must pass `bash tests/run_all.sh`
without:

- production READY / selective trees
- client-signing private keys in the repo (tests generate ephemeral keys in `mktemp`)
- R2 or ACPS downloads

## Optional live integration

Live mirror / production-symlink smoke checks (for example Mirror Manager Q)
SKIP with a clear reason when production paths are absent. They are optional and
must never hard-fail a clean host.
