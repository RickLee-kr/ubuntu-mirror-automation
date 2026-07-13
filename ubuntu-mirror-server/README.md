# Ubuntu Mirror Server Automation

Production installer for an Ubuntu package mirror (16.04 → 24.04) using apt-mirror + nginx + systemd.

## Quick Start

```bash
git clone https://github.com/RickLee-kr/ubuntu-mirror-automation.git
cd ubuntu-mirror-automation/ubuntu-mirror-server
sudo ./install.sh
```

The installer automatically:

1. Validates the server
2. Installs apt-mirror and nginx
3. Creates the mirror configuration
4. Configures systemd
5. Starts nginx
6. Starts the initial synchronization
7. Prints status and monitoring commands

Then monitor with:

```bash
sudo mirrorctl status
sudo mirrorctl logs
```

When the first sync finishes, finalization runs automatically (cleanup + daily timer). If needed:

```bash
sudo mirrorctl finalize
```

## Operator options

| Option | Behavior |
|--------|----------|
| *(none)* | Full automatic installation and initial sync |
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

If `/var/spool/apt-mirror` is already mounted (for example `/dev/sdb1`), leave `DATA_DEVICE` empty. The installer will not format or remount it.

## Day-2 operations

```bash
sudo mirrorctl status
sudo mirrorctl logs
sudo mirrorctl validate
sudo mirrorctl finalize    # if auto-finalize did not run
sudo mirrorctl cleanup
sudo mirrorctl timer status
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

Run the test suite:

```bash
cd tests && ./run_all.sh
```

Includes `bash -n`, ShellCheck, dry-run (no packages required), and install-flow fixtures.

See also:

- [docs/architecture.md](docs/architecture.md)
- [docs/operations.md](docs/operations.md)
- [docs/recovery.md](docs/recovery.md)

### Safety

Normal `sudo ./install.sh` never formats disks, deletes mirror data, or enables the daily timer before the first successful sync. Disk formatting is a hidden expert flag (`--format-device --force`) and is not part of Quick Start.
