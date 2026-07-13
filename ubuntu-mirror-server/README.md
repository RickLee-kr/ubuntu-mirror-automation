# Ubuntu Mirror Server Automation

Production-oriented automation for the **Ubuntu Mirror Server - Complete Setup Guide** (offline package mirror for Ubuntu 16.04 → 24.04).

This is not a one-shot command dump: installs are **idempotent**, **config-driven**, **backed up**, **validated**, and **recoverable**.

## Features

- Idempotent `install.sh` (safe to re-run)
- `mirror.conf` for path, versions, full/minimal mode, threads, upstream, sync time, port, disk
- Automatic timestamped backups before changing configs
- systemd timer (daily 02:00) + oneshot service
- nginx site with `/ubuntu` alias (per guide)
- `validate.sh` with PASS / WARNING / FAIL
- Enhanced `mirror-status.sh` (CPU, memory, disk, inode, latency, errors, …)
- `mirrorctl` operator CLI
- Auto recovery (`mirror-recovery.sh`)
- Client setup for classic `sources.list` and Ubuntu 24.04 `.sources` (deb822)
- ShellCheck-clean Bash, automated tests

## Prerequisites (from guide)

- Ubuntu 24.04 LTS server (other Ubuntu versions may work with warnings)
- Data disk recommended (~1 TB) mounted at `/var/spool/apt-mirror`
- Root/sudo, internet for initial sync (100+ Mbps recommended)
- Static IP for clients

## Quick install

```bash
cd ubuntu-mirror-server
sudo ./install.sh --non-interactive --validate
sudo ./install.sh --start-sync          # begins ~660 GB full sync
sudo mirrorctl status
```

Dry-run:

```bash
sudo ./install.sh --dry-run
```

Minimal mirror (~305 GB):

```bash
# edit mirror.conf: MIRROR_MODE="minimal"
sudo ./install.sh --non-interactive
```

Custom config:

```bash
sudo ./install.sh --config /path/to/mirror.conf --non-interactive
```

## Upgrade / re-apply

```bash
sudo ./install.sh --config mirror.conf --non-interactive
sudo mirrorctl restart
```

Existing `/etc/ubuntu-mirror/mirror.conf` is preserved unless `--force`.

## Uninstall

```bash
sudo ./uninstall.sh                 # remove units/helpers; keep mirror data
sudo ./uninstall.sh --purge-data --force   # delete mirrored packages (DANGEROUS)
```

## Operator CLI (`mirrorctl`)

```bash
sudo mirrorctl status
sudo mirrorctl validate
sudo mirrorctl sync start|stop|status
sudo mirrorctl logs sync|nginx|follow
sudo mirrorctl cleanup
sudo mirrorctl nginx status|test|reload|restart|recover
sudo mirrorctl timer status|start|stop|enable|disable
sudo mirrorctl client setup|validate
sudo mirrorctl restart
sudo mirrorctl recover
sudo mirrorctl info
```

## Validation

```bash
sudo ./validate.sh
# Exit: 0=PASS, 1=WARNING, 2=FAIL
```

Checks include: Ubuntu version, disk mount/space, directories, apt-mirror, nginx, systemd, URL reachability, xenial/bionic/focal/jammy/noble, HTTP status, permissions, logs, health.

## Client

```bash
sudo ./client/client-setup.sh --mirror-url http://10.34.200.20
./client/client-validate.sh --mirror-url http://10.34.200.20
```

## Project layout

```
ubuntu-mirror-server/
  install.sh uninstall.sh validate.sh mirror.conf README.md
  lib/          common.sh config.sh
  templates/    mirror.list nginx.conf apt-mirror.service/.timer
  scripts/      mirrorctl mirror-status.sh mirror-recovery.sh
  client/       client-setup.sh client-validate.sh
  docs/         architecture.md operations.md recovery.md
  tests/        test_*.sh run_all.sh
```

## Troubleshooting

See [docs/recovery.md](docs/recovery.md). Common guide issues:

| Symptom | Action |
|---------|--------|
| invalid config file | `sudo mirrorctl recover --fix-config` or re-install |
| path not mounted | set `DATA_DEVICE`, re-run install (format only with `--format-device --force`) |
| sync crashed | `sudo mirrorctl sync start` (resumes) |
| nginx 404 | `sudo mirrorctl nginx recover`; wait for sync |
| disk full | minimal mode / expand volume / drop releases |

## FAQ

**Q: Can I run install twice?**  
Yes. Unchanged files are skipped; changed files are backed up under `/var/backups/ubuntu-mirror/`.

**Q: Will it format my disk?**  
Never, unless you pass `--format-device --force` and set `DATA_DEVICE`.

**Q: When should I start the daily timer?**  
After the initial sync completes (guide §9): `sudo mirrorctl timer start`.

**Q: Full vs minimal?**  
`MIRROR_MODE=full` includes universe/multiverse (~660 GB). `minimal` is main+restricted (~305 GB).

**Q: Where are logs?**  
`/var/log/ubuntu-mirror/` and `/var/log/apt-mirror*.log`.

## Tests

```bash
cd tests && ./run_all.sh
```

## Documentation

- [Architecture](docs/architecture.md)
- [Operations](docs/operations.md)
- [Recovery](docs/recovery.md)

## License / provenance

Implements procedures from *Ubuntu Mirror Server - Complete Setup Guide* (Last Updated: January 31, 2026). Automation additions are operational hardening on top of that guide.
