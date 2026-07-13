# Ubuntu Mirror Server Automation

Production installer for an Ubuntu package mirror (16.04 → 24.04) using apt-mirror + nginx + systemd.

## Quick Start

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation
sudo ./install.sh
```

The installer starts the initial sync and opens a live terminal dashboard.
Press **B**, **Q**, or **Ctrl+C** to detach. The sync continues in the background.
Reconnect at any time with:

```bash
sudo mirrorctl watch
```

The installer automatically:

1. Validates the server
2. Installs apt-mirror and nginx
3. Creates the mirror configuration
4. Configures systemd
5. Starts nginx
6. Starts the initial synchronization (non-blocking) and attaches the live dashboard
7. Prints status and monitoring commands

### Installation modes

```bash
sudo ./install.sh                 # start sync + live dashboard (default on a TTY)
sudo ./install.sh --background    # start sync and return to the shell
sudo ./install.sh --foreground    # start sync and keep the dashboard attached
```

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
sudo mirrorctl watch      # live TUI dashboard
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
| *(none)* | Full automatic installation, start sync, attach live dashboard |
| `--background` | Start sync and return to the shell immediately |
| `--foreground` | Start sync and keep the live dashboard attached |
| `--config FILE` | Use a custom configuration file |
| `--dry-run` | Show planned actions without changing the system |
| `--no-sync` | Install and validate but do not start initial sync |
| `--minimal` | Use minimal mirror components (~305 GB) |
| `--verbose` | Show full validation details |
| `--force` | Replace changed managed configuration after backup |
| `--help` | Show concise usage |

## Configuration

Edit `mirror.conf` before install if needed:

- `BASE_PATH` (default `/var/spool/apt-mirror`)
- `MIRROR_MODE` (`full` or `minimal`)
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

### Safety

Normal `sudo ./install.sh` never formats disks, deletes mirror data, or enables the daily timer before the first successful sync. Disk formatting is a hidden expert flag (`--format-device --force`) and is not part of Quick Start. Detaching the dashboard never stops synchronization.
