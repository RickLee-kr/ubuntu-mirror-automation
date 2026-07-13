# Operations

## Install (one command)

```bash
cd ubuntu-mirror-automation
sudo ./install.sh
```

The installer starts the initial sync through systemd and opens a live terminal dashboard.
Press `B`, `Q`, or `Ctrl+C` to detach — synchronization continues in the background.

```bash
sudo ./install.sh --background   # start sync, return to shell
sudo ./install.sh --foreground   # keep dashboard attached
sudo mirrorctl watch             # reattach dashboard anytime
sudo mirrorctl status
sudo mirrorctl logs
```

After the first sync finishes, auto-finalize enables the daily timer and the dashboard shows each step. Manual fallback:

```bash
sudo mirrorctl finalize
```

## Daily

```bash
sudo mirrorctl watch
sudo mirrorctl status
systemctl list-timers apt-mirror.timer
sudo mirrorctl logs
df -h /var/spool/apt-mirror
```

## Weekly

```bash
sudo mirrorctl cleanup
sudo journalctl -u apt-mirror.service | grep -i error || true
sudo mirrorctl validate
```

## Sync control

```bash
sudo mirrorctl sync start --background
sudo mirrorctl sync start --foreground
sudo mirrorctl sync pause
sudo mirrorctl sync resume
sudo mirrorctl sync stop          # explicit stop only
```

`Ctrl+C` in the dashboard detaches only; it does **not** stop `apt-mirror.service`.

## Mirror sizes

| Mode | Approx size |
|------|-------------|
| Full | ~660 GB |
| Minimal (`--minimal`) | ~305 GB |

## Client rollout

```bash
sudo ./client/client-setup.sh --mirror-url http://MIRROR_IP
./client/client-validate.sh --mirror-url http://MIRROR_IP
```

## Re-apply config

```bash
sudo ./install.sh --force
sudo mirrorctl restart
```
