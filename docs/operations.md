# Operations

## Install (one command)

```bash
cd ubuntu-mirror-automation
sudo ./install.sh
sudo mirrorctl status
sudo mirrorctl logs
```

After the first sync finishes, auto-finalize enables the daily timer. Manual fallback:

```bash
sudo mirrorctl finalize
```

## Daily

```bash
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
