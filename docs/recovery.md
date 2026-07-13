# Recovery & Troubleshooting

Mapped from Setup Guide §11 plus automated recovery.

## Auto recovery

```bash
sudo mirrorctl recover
# or
sudo mirror-recovery.sh --fix-config --resume-sync
```

Actions:

1. Ensure `mirror/skel/var` directories exist
2. Repair `/etc/apt/mirror.list` if `base_path` missing (`--fix-config`)
3. `systemctl daemon-reload` + enable timer
4. Restart nginx if down (only after `nginx -t` passes)
5. Resume `apt-mirror` if `--resume-sync` (safe — resumes downloads)

## Guide issues

### invalid config file

```bash
grep '^set base_path' /etc/apt/mirror.list
sudo mirror-recovery.sh --fix-config
```

### /var/spool/apt-mirror not mounted

```bash
lsblk
# Set DATA_DEVICE=/dev/sdb1 in mirror.conf, then:
sudo ./install.sh --config mirror.conf   # mounts + fstab (no format)
# Format ONLY if empty disk intentionally:
sudo ./install.sh --format-device --force --non-interactive
```

### Sync very slow

- Check `nthreads` in mirror.conf / mirror.list (Guide: 20)
- Switch `UPSTREAM_MIRROR` to a regional mirror
- Check bandwidth contention

### nginx not serving / 404

```bash
sudo mirrorctl nginx recover
sudo nginx -t
ls -la /var/spool/apt-mirror/mirror/
sudo tail -50 /var/log/nginx/apt-mirror-error.log
```

### Disk full

```bash
df -h /var/spool/apt-mirror
# Switch to MIRROR_MODE=minimal, or drop versions, or expand volume:
# growpart + resize2fs (cloud) — not automated by default
```

### Sync stopped / crashed

```bash
sudo mirrorctl sync start    # apt-mirror resumes
# or
sudo mirror-recovery.sh --resume-sync
```

## Uninstall

```bash
sudo ./uninstall.sh                  # units + helpers; keeps data
sudo ./uninstall.sh --purge-data --force   # DANGEROUS: deletes packages
```
