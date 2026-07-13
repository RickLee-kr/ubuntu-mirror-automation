# Operations

## Daily

```bash
sudo mirrorctl status
systemctl list-timers apt-mirror.timer
sudo mirrorctl logs sync
df -h /var/spool/apt-mirror
```

## Weekly

```bash
sudo mirrorctl cleanup          # runs var/clean.sh
sudo journalctl -u apt-mirror.service | grep -i error || true
sudo mirrorctl logs nginx
sudo mirrorctl validate
```

## Initial sync (Guide §7–9)

```bash
sudo mirrorctl sync start
sudo mirrorctl logs follow
# After "End time:" appears:
sudo mirrorctl cleanup
sudo mirrorctl timer start
sudo mirrorctl validate
curl -I http://localhost/ubuntu/dists/noble/Release
```

Expected sizes (Guide):

| Mode | Approx size |
|------|-------------|
| Full (main restricted universe multiverse) | ~660 GB |
| Minimal (main restricted) | ~305 GB |

Set `MIRROR_MODE=minimal` in `mirror.conf` before install for the smaller footprint.

## Client rollout

```bash
# On each client
sudo ./client/client-setup.sh --mirror-url http://MIRROR_IP
./client/client-validate.sh --mirror-url http://MIRROR_IP
```

Ubuntu 24.04 clients using `/etc/apt/sources.list.d/ubuntu.sources` are updated automatically (deb822 `URIs:`).

## Changing config after install

1. Edit `/etc/ubuntu-mirror/mirror.conf` (or project `mirror.conf`).
2. Re-run `sudo ./install.sh --config ... --non-interactive` (idempotent).
3. `sudo mirrorctl restart`

## Monitoring tips (Guide §8)

```bash
watch -n 300 'du -sh /var/spool/apt-mirror/mirror/ && df -h /var/spool/apt-mirror'
find /var/spool/apt-mirror/mirror -name '*.deb' 2>/dev/null | wc -l
```
