# Operations — Offline Ubuntu Upgrade Mirror

This server builds a **portable offline upgrade mirror** for the LTS chain:

`Ubuntu 16.04 Xenial → 18.04 Bionic → 20.04 Focal → 22.04 Jammy → 24.04 Noble`

Client-side upgrade procedures are **out of scope** for this document. This guide covers **internet-connected mirror server** operations only.

## Scope

### Included

- Official Ubuntu **amd64** binary packages
- Components: `main` `restricted` `universe` `multiverse`
- Suites per release: release, `updates`, `security`, `backports` (20 suites total)
- Release upgrader tarballs + GPG signatures for **bionic / focal / jammy / noble**
- Local `meta-release-lts` rewritten to `PUBLIC_BASE_URL`

### Excluded

- i386 (and any non-amd64) packages
- Source packages (`deb-src`)
- Ubuntu Pro / ESM authenticated repositories
- PPAs
- Docker CE / NVIDIA / CUDA external repositories
- Snap packages
- Stellar Cyber or other vendor-private APT repos

---

## Install

```bash
cd ubuntu-mirror-automation
sudo ./install.sh --full --no-menu --no-sync
```

Or interactive menu (`sudo ./install.sh`) and choose **Full / offline upgrade**.

Installer installs: `apt-mirror`, `nginx`, `curl`, `ca-certificates`, `gpgv`, `ubuntu-keyring`, `jq`, `xz-utils`, `gzip`, `whiptail`, and deploys:

| Path | Purpose |
|------|---------|
| `/etc/apt/mirror.list` | apt-mirror suite definitions (amd64 only) |
| `/etc/default/ubuntu-offline-mirror` | `PUBLIC_BASE_URL`, paths, safety knobs |
| `/usr/local/sbin/ubuntu-offline-mirror.sh` | Integrated `sync` / `verify` / `status` / `freeze` |
| `/etc/nginx/sites-available/apt-mirror` | `/ubuntu/` + `/offline/` |
| `/etc/systemd/system/apt-mirror.service` | `ExecStart=... ubuntu-offline-mirror.sh sync` |
| `/etc/systemd/system/apt-mirror.timer` | Daily + `RandomizedDelaySec` |

Edit public URL **before** freeze / move:

```bash
sudoedit /etc/default/ubuntu-offline-mirror
# PUBLIC_BASE_URL=http://<closed-network-host-or-ip>
```

### Data disk requirement

`/var/spool/apt-mirror` must be a **dedicated data mount**. If it sits on the OS root filesystem, sync fails unless:

```bash
# /etc/default/ubuntu-offline-mirror
ALLOW_ROOT_FS_MIRROR=true   # emergency override only
```

Projected full offline footprint is roughly **700–900 GiB**. Ensure `MIN_FREE_GB` free space remains after sync.

---

## First sync

```bash
sudo ubuntu-offline-mirror sync
# or
sudo systemctl start apt-mirror.service
```

`sync` performs:

1. Mount / disk / inode preflight  
2. flock concurrency lock  
3. `apt-mirror`  
4. Release upgrader download (from `meta-release-lts`)  
5. Local `meta-release-lts` generation  
6. GPG verification of upgrader tarballs  
7. Suite + HTTP + isolated `apt-get update` checks  
8. `manifest.json` + `SHA256SUMS`  
9. Optional `clean.sh` (`RUN_CLEAN=true`)  
10. Writes `/var/spool/apt-mirror/offline/READY` **only if all checks pass**

## Incremental sync

Re-run the same command. Existing package data is retained; apt-mirror downloads increments.

```bash
sudo ubuntu-offline-mirror sync
```

## Progress / status

```bash
sudo ubuntu-offline-mirror status
sudo mirrorctl watch          # live dashboard (apt-mirror activity)
sudo journalctl -u apt-mirror.service -f
sudo tail -f /var/log/ubuntu-offline-mirror.log
sudo tail -f /var/log/apt-mirror.log
```

## verify

Offline validation using **local files + localhost nginx only** (no upstream internet required for the checks themselves):

```bash
sudo ubuntu-offline-mirror verify
```

- Non-zero exit on any failure  
- Invalidates previous `READY` on start  
- Rewrites `READY` only after success  

## freeze (prepare for air-gap move)

```bash
sudo ubuntu-offline-mirror freeze
```

1. Runs verify (abort on failure)  
2. Stops/disables `apt-mirror.timer`  
3. Refuses if a sync is running  
4. Writes `snapshot.json` + `FROZEN` marker  
5. Prints confirmation that the mirror is ready to disconnect  

## READY / FROZEN checks

```bash
cat /var/spool/apt-mirror/offline/READY
cat /var/spool/apt-mirror/offline/FROZEN
curl -sS http://127.0.0.1/offline/READY
```

## Before disconnecting from the internet

```bash
sudo ubuntu-offline-mirror verify
sudo ubuntu-offline-mirror status
# Confirm READY exists, all 20 suites OK, 4 upgrader GPG OK
sudo ubuntu-offline-mirror freeze
```

## After bringing the mirror up on a closed network

1. Ensure nginx is running  
2. Set `PUBLIC_BASE_URL` to the closed-network address and regenerate local meta if the URL changed:

   ```bash
   sudoedit /etc/default/ubuntu-offline-mirror
   # then re-run verify (rebuilds meta if you re-sync upgraders) or re-sync upgrader/meta section
   sudo SKIP_APT_MIRROR=true ubuntu-offline-mirror sync   # only if you need to rebuild meta/upgraders
   sudo ubuntu-offline-mirror verify
   ```

3. Localhost checks:

```bash
curl -I http://127.0.0.1/ubuntu/dists/xenial/InRelease
curl -I http://127.0.0.1/ubuntu/dists/noble/InRelease
curl -I http://127.0.0.1/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz
curl -sS http://127.0.0.1/offline/meta-release-lts | head
curl -sS http://127.0.0.1/offline/manifest.json | jq .
```

## Timer enable / disable

```bash
# Disable (also done by freeze)
sudo systemctl disable --now apt-mirror.timer

# Re-enable on an internet-connected host after unfreeze
sudo systemctl enable --now apt-mirror.timer
systemctl list-timers apt-mirror.timer
```

## Logs

| Log | Path |
|-----|------|
| Offline mirror | `/var/log/ubuntu-offline-mirror.log` |
| apt-mirror (legacy/ops) | `/var/log/apt-mirror.log` |
| nginx access/error | `/var/log/nginx/apt-mirror-*.log` |
| systemd | `journalctl -u apt-mirror.service` |

## Repository paths

```text
/var/spool/apt-mirror/
  mirror/archive.ubuntu.com/ubuntu/     # APT pool + dists
  offline/
    meta-release-lts                    # local rewritten
    meta-release-lts.upstream           # official copy
    manifest.json
    SHA256SUMS
    READY / FROZEN
    snapshot.json
    announcements/
  skel/ var/                            # apt-mirror working trees
```

## HTTP endpoints

```text
http://SERVER/ubuntu/
http://SERVER/ubuntu/dists/<suite>/InRelease
http://SERVER/ubuntu/dists/<suite>/Release
http://SERVER/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz
http://SERVER/ubuntu/dists/focal-updates/main/dist-upgrader-all/current/focal.tar.gz
http://SERVER/ubuntu/dists/jammy-updates/main/dist-upgrader-all/current/jammy.tar.gz
http://SERVER/ubuntu/dists/noble-updates/main/dist-upgrader-all/current/noble.tar.gz
http://SERVER/offline/meta-release-lts
http://SERVER/offline/meta-release-lts.upstream
http://SERVER/offline/manifest.json
http://SERVER/offline/SHA256SUMS
http://SERVER/offline/READY
```

## Failure recovery

| Symptom | Action |
|---------|--------|
| Sync fails: root filesystem | Mount data disk at `/var/spool/apt-mirror` or set `ALLOW_ROOT_FS_MIRROR` only as last resort |
| Sync fails: free space | Expand data volume; do **not** delete mirror blindly |
| GPG upgrader failure | Re-run sync; check keyring `/usr/share/keyrings/ubuntu-archive-keyring.gpg` |
| `READY` missing after sync | Read `/var/log/ubuntu-offline-mirror.log`; fix failing check; re-run `verify`/`sync` |
| nginx 404 on `/ubuntu/` | Confirm alias paths; `nginx -t`; `systemctl reload nginx` |
| Concurrent sync | Wait; lock file `/run/ubuntu-offline-mirror.lock` |
| Need full-tree hashes | `sudo ubuntu-offline-mirror sha256-all` (expensive; optional) |

Do **not** automatically format disks, wipe the mirror, or run host `apt upgrade` as part of recovery.

## Related commands

```bash
sudo mirrorctl status
sudo mirrorctl validate
sudo ./validate.sh
```
