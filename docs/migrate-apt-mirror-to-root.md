# Migrate apt-mirror spool from 2.4TB data disk to root filesystem

## Purpose

Move the selective offline mirror data currently stored on `/dev/sdb1`
(mounted at `/var/spool/apt-mirror`) onto the root filesystem **without
changing the public service path**.

Final service path (unchanged):

```text
/var/spool/apt-mirror
```

Staging path on root:

```text
/var/spool/apt-mirror.root-stage
```

Tool:

```bash
scripts/migrate-apt-mirror-to-root.sh
```

## State machine

```text
preflight (read-only)
    |
    v
initial-copy --execute     # online rsync to root-stage; nginx stays up
    |
    v
cutover --execute          # maintenance window only
    |                      # stop nginx, stop gpg-agent on mount, final rsync,
    |                      # umount sdb1, disable fstab UUID, atomic rename,
    |                      # ALLOW_ROOT_FS_MIRROR=true (effective configs),
    |                      # nginx -t/start, HTTP verify
    |-- failure --> rollback --execute
    v
operator reboot (manual)
    |
    v
post-reboot-verify (read-only)
    |
    v
operator VM shutdown + ESXi "Remove from virtual machine" (manual)
    |
    v
post-reboot-verify again
    |
    v
later: delete VMDK from datastore (manual, after retention)
```

The script **never** runs `reboot`, `shutdown`, or any ESXi detach command.

## Modes

| Mode | Mutation | Extra gate |
|------|----------|------------|
| `--preflight` | No | — |
| `--verify` | No | — |
| `--post-reboot-verify` | No | — |
| `--initial-copy --execute` | Yes (stage only) | `--execute` |
| `--cutover --execute` | Yes | `--execute` + type `CUTOVER_TO_ROOT` |
| `--rollback --execute` | Yes | `--execute` |

Default invocation (no args) prints usage and changes nothing.

## Source / destination guards

Preflight refuses to continue unless all hold:

- Candidate disk `/dev/sdb`, partition `/dev/sdb1`
- UUID `d48ae479-10f5-4ff5-b9be-4baa34dd15ea`
- Mountpoint `/var/spool/apt-mirror`, fstype `ext4`
- Source is not root/boot/EFI/swap/LVM/RAID
- Staging parent is on the root filesystem
- Source and staging are **different** filesystems
- Root free space: `max(unique×2, 10GiB, apparent)` budget and ≥20GiB headroom after copy
- Git worktree clean and `HEAD == origin/main`
- Selective `current`/`active` symlinks valid
- Private signing key present (metadata only logged)
- No materialize/sync/rsync migration processes

## Hardlink preservation

Copy uses:

```bash
rsync -aHAX --numeric-ids --sparse --human-readable --partial --info=progress2
```

Final delta also uses `--delete-delay` only after canonical path guards pass.

`published` and `published.previous` hardlinks are verified by inode equality
on a sample pair and by `HARDLINKED_FILE_PATH_COUNT` inventory match.

## Private key protection

Required path:

```text
/var/spool/apt-mirror/selective/keys/ubuntu-mirror-selective.private.gpg
```

The script never prints key material or content hashes. It only checks
existence, type, size, mode, uid/gid. `set -x` is not used. Logs redact
PEM/PGP private headers if they ever appear in messages.

Public key and keyring files under `selective/keys/` are copied with the tree.

## gpg-agent handling

During cutover the script:

1. Lists processes with open handles / cwd under the mount
2. Terminates only `gpg-agent` PIDs among them
3. Re-checks that no user process handles remain
4. Aborts cutover if handles remain

## fstab change and restore

Cutover comments **only** the active line matching the candidate UUID:

```text
# migrate-apt-mirror-to-root.sh disabled <timestamp>
#UUID=d48ae479-10f5-4ff5-b9be-4baa34dd15ea /var/spool/apt-mirror ext4 defaults,noatime 0 2
```

A full pre-cutover fstab copy is stored under the evidence directory.
Rollback restores that backup verbatim, then `systemctl daemon-reload`,
then remounts `UUID=<candidate>` at `/var/spool/apt-mirror`.

## ALLOW_ROOT_FS_MIRROR handling

Runtime check lives in `ubuntu-offline-mirror.sh` → `check_mirror_mount()`,
loaded from:

1. `/etc/default/ubuntu-offline-mirror` (primary for materialize)
2. `/etc/ubuntu-mirror/mirror.conf` (effective `um_load_config` consumers)

Cutover sets `ALLOW_ROOT_FS_MIRROR=true` **only** in those effective files.

Not auto-modified (report only if still false):

- repository `mirror.conf`
- `templates/ubuntu-offline-mirror.default`

Tracked source updates, if desired, are a separate commit.

## nginx validation

- `nginx -t` before cutover (preflight) and after cutover rename
- Stop nginx before unmount; start after rename
- HTTP checks for `/client/` scripts + `.sha256`, hop `Release` files,
  public signing key, `meta-release-lts`, and related paths derived from
  the effective site config

## Rollback

On cutover failure after evidence exists:

1. Stop nginx
2. Move root spool aside (preserve; never `rm -rf`)
3. Restore empty mountpoint directory name
4. Restore fstab backup + daemon-reload
5. Remount candidate UUID/partition
6. Restore effective ALLOW_ROOT_FS_MIRROR backups
7. `nginx -t` + start + HTTP check

Success markers:

```text
ROLLBACK=PASS
SOURCE_DISK_DATA_PRESERVED=YES
```

## ESXi detach (manual only — not automated)

1. `--post-reboot-verify` → `READY_FOR_POWER_OFF_AND_ESXI_DETACH=YES`
2. Clean VM shutdown (operator)
3. ESXi: remove the 2.4TB disk from the VM only (**do not** delete datastore file yet)
4. Power on VM
5. Run `--post-reboot-verify` again
6. After an agreed retention window, delete the VMDK from the datastore

## Evidence

Default evidence root:

```text
/var/backups/ubuntu-mirror/migrate-to-root/<timestamp>/
```

Contains fstab/nginx/defaults backups, cutover metadata, logs.

## Example (production)

Read-only readiness check:

```bash
bash scripts/migrate-apt-mirror-to-root.sh --preflight
```

Do **not** run mutation modes until a maintenance window is approved:

```bash
# NOT run during tool bring-up:
# bash scripts/migrate-apt-mirror-to-root.sh --initial-copy --execute
# bash scripts/migrate-apt-mirror-to-root.sh --cutover --execute
```
