# Architecture

## Purpose

Automate the **Ubuntu Mirror Server - Complete Setup Guide** (Stellar Cyber) into an idempotent, config-driven, production-operable installer for offline OS upgrades across Ubuntu 16.04 → 24.04.

## Components

```
┌─────────────────┐     HTTP :80      ┌──────────────────────────┐
│ Ubuntu clients  │ ───────────────► │ nginx (apt-mirror site)  │
│ sources.list /  │   /ubuntu/...     │ alias → archive.ubuntu  │
│ *.sources       │                   └────────────▲─────────────┘
└─────────────────┘                                │
                                                   │ files
                                      ┌────────────┴─────────────┐
                                      │ /var/spool/apt-mirror    │
                                      │   mirror/ skel/ var/     │
                                      └────────────▲─────────────┘
                                                   │ apt-mirror
                                      ┌────────────┴─────────────┐
                                      │ apt-mirror.service       │
                                      │ apt-mirror.timer (02:00) │
                                      └────────────▲─────────────┘
                                                   │
                                      ┌────────────┴─────────────┐
                                      │ archive.ubuntu.com       │
                                      └──────────────────────────┘
```

## Config flow

1. Operator edits `mirror.conf` (versions, mode full/minimal, threads, disk, port).
2. `install.sh` generates `/etc/apt/mirror.list`, nginx site, systemd units from config.
3. Helpers install to `/usr/local/bin` and libs to `/usr/local/lib/ubuntu-mirror`.
4. `validate.sh` / `mirrorctl` / `mirror-status.sh` read the same config.

## Safety model

| Action | Default | Required flags |
|--------|---------|----------------|
| Rewrite configs | Backup first | — |
| Disable nginx default site | Prompt / non-interactive | `--non-interactive` or `--force` |
| Format data disk | Never | `--format-device --force` + `DATA_DEVICE` |
| Delete mirror data | Never | `uninstall.sh --purge-data --force` |

## Logging

| Log | Path |
|-----|------|
| Install | `/var/log/ubuntu-mirror/install.log` |
| Validate | `/var/log/ubuntu-mirror/validate.log` |
| Health | `/var/log/ubuntu-mirror/health.log` |
| Sync | `/var/log/apt-mirror.log`, `apt-mirror-initial.log` |
| nginx | `/var/log/nginx/apt-mirror-*.log` |

## Idempotency

Re-running `install.sh` compares generated content with on-disk files (`cmp`) and skips unchanged targets. systemd enable and nginx site symlink use force-link semantics without duplicating units.
