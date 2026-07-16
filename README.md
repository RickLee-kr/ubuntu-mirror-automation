# Ubuntu Mirror Server Automation

Production installer for an Ubuntu package mirror (16.04 → 24.04) using apt-mirror + nginx + systemd.

## Usage (summary)

| What you want | Command / action |
|---------------|------------------|
| Install & start sync | `sudo ./install.sh` → menu **1** (Minimal) or **2** (Full) |
| Watch live progress | Menu **3**, or `sudo mirrorctl watch` |
| Check if sync finished | `sudo mirrorctl status` → look for `State: READY` |
| Follow raw logs | Menu **5**, or `sudo mirrorctl logs` |
| Stop sync | Menu **6**, or `sudo mirrorctl sync stop` |
| Delete existing mirror data | Menu **7** (type `DELETE` to confirm) |
| Quit menu | Menu **8**, or Esc |

### How to run

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

1. Choose **1** (Minimal, recommended) or **2** (Full).
2. A live dashboard opens. Detach with **B**, **Q**, or **Ctrl+C** — sync keeps running.
3. Re-open the menu anytime with `sudo ./install.sh`, or attach the dashboard with `sudo mirrorctl watch`.

### How to confirm sync is complete

```bash
sudo mirrorctl status
```

| `State` | Meaning |
|---------|---------|
| `SYNC_RUNNING` / `SYNC_WAITING` | Still downloading |
| `SYNC_STALLED` | Process alive but no progress (investigate) |
| `SYNC_FAILED` | Failed — check logs / disk |
| `SYNC_COMPLETE` | apt-mirror finished; finalize may still be pending |
| `READY` | **Done** — cleanup done, daily timer enabled, mirror usable |

Also useful:

```bash
# Finalize log (auto-finalize steps)
grep -E 'READY|completed' /var/log/ubuntu-mirror/finalize.log

# HTTP check (replace with your mirror IP)
curl -I http://YOUR_MIRROR_IP/ubuntu/dists/noble/Release
```

If status is `SYNC_COMPLETE` but not `READY`:

```bash
sudo mirrorctl finalize
```

### How to delete existing mirror data

**From the menu (recommended):**

1. `sudo ./install.sh`
2. If sync is running → **6** Stop sync
3. **7** Delete existing mirror data → type `DELETE` → confirm
4. Then **1** or **2** to install/sync again

**From the shell:**

```bash
sudo mirrorctl sync stop
sudo ./uninstall.sh --purge-data --force
```

`--purge-data --force` removes package data under `BASE_PATH` (`mirror/`, `skel/`, `var/`). It does not run unless both flags are given.

---

## Quick Start

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

On an interactive terminal this opens a **dialog-style menu** (whiptail):

```text
┌──────────── Ubuntu Mirror Menu ────────────┐
│ Ubuntu Mirror Server                       │
│                                            │
│ 1 Install / start sync — Minimal (~320 GiB)│
│ 2 Install / start sync — Full (~700 GiB)   │
│ 3 Monitor live dashboard                   │
│ 4 Show status                              │
│ 5 Follow raw logs                          │
│ 6 Stop running synchronization             │
│ 7 Delete existing mirror data (DANGEROUS)  │
│ 8 Exit                                     │
│              <OK>   <Cancel>               │
└────────────────────────────────────────────┘
```

Use **↑ / ↓** to move, **Tab** to switch between **OK** and **Cancel**, **Enter** to select.
Esc also cancels / goes back.
Choose **1** for the recommended default (main + restricted).  
Choose **7** to wipe previous mirror data before re-installing.  
Choose **3** anytime to re-attach the live sync dashboard.

After install starts, the live dashboard appears. Press **B**, **Q**, or **Ctrl+C** to detach; sync continues in the background. Reconnect with menu option **3** or:

```bash
sudo mirrorctl watch
```

### Non-interactive / scripted install

```bash
sudo ./install.sh --full --no-menu          # offline upgrade mirror (default)
sudo ./install.sh --minimal --no-menu       # reduced footprint (not enough for release upgrades)
sudo ./install.sh --non-interactive
```

### Offline upgrade mirror (server-side)

Integrated sync for closed-network LTS upgrades (`xenial → noble`):

```bash
sudo ubuntu-offline-mirror sync
sudo ubuntu-offline-mirror verify
sudo ubuntu-offline-mirror status
sudo ubuntu-offline-mirror freeze   # before air-gap move
```

Config: `/etc/default/ubuntu-offline-mirror` (`PUBLIC_BASE_URL`, `ALLOW_ROOT_FS_MIRROR`, …).  
Ops guide: `docs/operations.md`.

DP host evidence collection (read-only, before upgrade): [`docs/collect-dp-upgrade-readiness.md`](docs/collect-dp-upgrade-readiness.md) / `scripts/collect-dp-upgrade-readiness.sh`.

DP upgrade preflight (read-only READY/BLOCKED verdict from a collection): [`docs/dp-upgrade-preflight.md`](docs/dp-upgrade-preflight.md) / `scripts/dp-os-upgrade-preflight.sh`.

```bash
sudo ./scripts/dp-os-upgrade-preflight.sh \
  --collection /var/tmp/dp-upgrade-readiness-dp01-....tar.gz \
  --package-source-mode mirror \
  --package-source-url http://10.34.200.20 \
    --snapshot-reference "esxi-dp01-before-ubuntu-upgrade" \
  --output-dir /var/tmp \
  --keep-directory
```

Exit codes: `0` READY, `10` READY_WITH_WARNINGS, `20` BLOCKED, `2` CLI/input error, `3` integrity/internal error.

Recommended DP upgrade flow:

```text
Collector
→ OS-only Preflight (dp-os-upgrade-preflight.sh)
→ Discovery OS Hop (or production hop chain)
→ Package/File Analysis
→ Mirror/Offline Set 보완
→ 다음 OS Hop 반복 (new collector + preflight each discovery hop)
→ Ubuntu 24.04 도달
────────────────────────────────
→ 별도 Phase 2 Readiness
→ DP Python/Py3 Bringup
```

Profiles: `production` (snapshot required, full chain allowed) vs `discovery`
(snapshot optional, default one hop, `CHECKPOINT_REACHED`, disposable VM ack).

Phase 1 OS upgrade orchestrator: [`docs/dp-os-upgrade.md`](docs/dp-os-upgrade.md) /
`scripts/dp-os-upgrade-only.sh` (default read-only; `install` requires `--execute` and
destructive acknowledgment). Lab destructive E2E is gated separately:
[`docs/dp-os-upgrade-lab-e2e.md`](docs/dp-os-upgrade-lab-e2e.md).

**Included:** amd64 packages (main/restricted/universe/multiverse), updates/security/backports, release upgraders.  
**Excluded:** i386, deb-src, Ubuntu Pro/ESM, PPAs, Docker/NVIDIA external repos, Snap, vendor private APT.

### Installation modes

```bash
sudo ./install.sh                 # interactive menu (TTY)
sudo ./install.sh --menu          # force menu
sudo ./install.sh --minimal       # skip menu; minimal sync
sudo ./install.sh --full          # skip menu; full offline sync (capacity checked)
sudo ./install.sh --background    # skip menu; start sync and return to shell
sudo ./install.sh --foreground    # skip menu; keep dashboard attached
```

Default mode is **full** for the offline upgrade mirror (~700–900 GiB projected). Use `--minimal` only for a reduced footprint. Before sync starts, capacity checks apply; `/var/spool/apt-mirror` should be a dedicated data mount (override with `ALLOW_ROOT_FS_MIRROR=true` only if necessary).

`--background` example:

```text
Initial synchronization started in background.

Attach dashboard:
  sudo mirrorctl watch

Check status:
  sudo mirrorctl status

Follow raw logs:
  sudo mirrorctl logs
```

Without an interactive terminal (CI / redirected output), the installer automatically uses background mode and never emits ANSI cursor controls.

### Day-to-day monitoring

```bash
sudo mirrorctl watch      # live TUI dashboard (refresh every 20s)
sudo mirrorctl status     # one-shot status snapshot
sudo mirrorctl logs       # follow /var/log/apt-mirror.log
```

You do not need to stitch together journalctl, df, and tail to know whether sync is alive.
The dashboard distinguishes **RUNNING**, **WAITING**, **STALLED**, **FAILED**, and **READY**.

When the first sync finishes, finalization runs automatically (cleanup + daily timer) and the dashboard shows each step. If needed:

```bash
sudo mirrorctl finalize
```

## Operator options

| Option | Behavior |
|--------|----------|
| *(none)* | Interactive menu on a TTY (mode / monitor / delete data) |
| `--menu` | Force interactive menu |
| `--no-menu` / `--non-interactive` | Skip menu (automation / CI) |
| `--full` | Skip menu; explicit full mirror |
| `--minimal` | Skip menu; minimal mirror |
| `--background` | Skip menu; start sync and return to the shell |
| `--foreground` | Skip menu; keep the live dashboard attached |
| `--config FILE` | Use a custom configuration file |
| `--dry-run` | Show planned actions without changing the system |
| `--no-sync` | Install and validate but do not start initial sync |
| `--verbose` | Show full validation details |
| `--force` | Replace changed managed configuration after backup |
| `--help` | Show concise usage |

## Configuration

Edit `mirror.conf` before install if needed:

- `BASE_PATH` (default `/var/spool/apt-mirror`)
- `MIRROR_MODE` (default `minimal`; `full` in config is ignored unless `install.sh --full`)
- `DISK_RESERVE_PERCENT` (default `20`) — free space that must remain after sync
- `PROJECTED_SIZE_GIB_MINIMAL` / `PROJECTED_SIZE_GIB_FULL` — pre-sync size estimates
- `UBUNTU_VERSIONS`, `NTHREADS`, `UPSTREAM_MIRROR`
- `MIRROR_IP` / `MIRROR_URL` (auto-detected when empty)
- `STALL_THRESHOLD_SEC` (default 600) for dashboard stall detection
If `/var/spool/apt-mirror` is already mounted (for example `/dev/sdb1`), leave `DATA_DEVICE` empty. The installer will not format or remount it.

## Day-2 operations

```bash
sudo mirrorctl watch
sudo mirrorctl status
sudo mirrorctl logs
sudo mirrorctl logs --progress
sudo mirrorctl sync start --foreground
sudo mirrorctl sync stop
sudo mirrorctl sync pause
sudo mirrorctl sync resume
sudo mirrorctl validate
sudo mirrorctl finalize    # if auto-finalize did not run
sudo mirrorctl cleanup
sudo mirrorctl timer status
```

### Dashboard keyboard controls

| Key | Action |
|-----|--------|
| `F` | Keep / follow in foreground |
| `B` | Detach to background (return to shell) |
| `L` | Switch to raw log view |
| `S` | Show detailed status |
| `P` | Pause sync (SIGSTOP), if supported |
| `R` | Resume paused sync (SIGCONT) |
| `Q` | Detach and quit dashboard |
| `Ctrl+C` | Detach dashboard only — **does not** stop sync |

Stopping sync requires an explicit command:

```bash
sudo mirrorctl sync stop
```

## Uninstall

```bash
sudo ./uninstall.sh
# Dangerous: also delete mirrored packages
sudo ./uninstall.sh --purge-data --force
```

## Development and Troubleshooting

Advanced scripts remain available for diagnostics:

```bash
./validate.sh --mode install
./validate.sh --mode operational
sudo mirrorctl recover
sudo mirror-status
sudo mirror-recovery
```

Logs:

- `/var/log/ubuntu-mirror/install.log`
- `/var/log/ubuntu-mirror/progress.jsonl`
- `/var/log/ubuntu-mirror/finalize.log`
- `/var/log/apt-mirror.log`

Run the test suite:

```bash
cd tests && ./run_all.sh
```

Includes `bash -n`, ShellCheck, dry-run (no packages required), dashboard fixtures, and install-flow tests.

See also:

- [docs/architecture.md](docs/architecture.md)
- [docs/operations.md](docs/operations.md)
- [docs/recovery.md](docs/recovery.md)
- [docs/collect-dp-upgrade-readiness.md](docs/collect-dp-upgrade-readiness.md)
- [docs/dp-upgrade-preflight.md](docs/dp-upgrade-preflight.md)

### Safety

Normal `sudo ./install.sh` never formats disks, deletes mirror data, or enables the daily timer before the first successful sync. Disk formatting is a hidden expert flag (`--format-device --force`) and is not part of Quick Start. Detaching the dashboard never stops synchronization.
