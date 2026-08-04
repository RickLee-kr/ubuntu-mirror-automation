# Clean Snapshot Retest

Operator procedure after restoring a clean Ubuntu 24.04 Mirror Server snapshot.
Follow every step in order. Stop on the first failure.

## Forbidden actions

Do **not**:

- manually delete workflow state, READY markers, or command files
- manually copy selective / Phase 2 / client artifacts
- delete or rotate the local signing key by hand
- set `PYTHONPATH` or copy runtime Python modules by hand
- run `tests/run_all.sh` as a substitute for this procedure
- enable nginx manually to bypass Menu 3
- edit `/etc/ubuntu-mirror/dp-upgrade-workflow.state` by hand

---

## 1. Snapshot restore complete

**Command:** confirm the lab snapshot is restored and the host has rebooted to Ubuntu 24.04.

**Expected:** clean host, Mirror Manager not yet reconfigured for this retest.

**Failure:** wrong snapshot or dirty disk state → restore again.

**Stop if:** previous retest leftovers remain under `/var/spool/apt-mirror` or `/etc/ubuntu-mirror` and the snapshot was supposed to be clean.

---

## 2. Repository clean check

```bash
cd /path/to/ubuntu-mirror-automation
git status --short
```

**Expected:** empty output (clean tree).

**Failure:** local modifications → `git reset --hard` / clean only if this is an intentional discard of uncommitted work.

**Stop if:** unrelated dirty files must be preserved.

---

## 3. Pull origin/main

```bash
git fetch origin
git checkout main
git pull --ff-only
```

**Expected:** fast-forward to current `origin/main`.

**Failure:** diverged local main → stop and resolve with the release owner.

---

## 4. Exact HEAD confirmation

```bash
git rev-parse HEAD
git log -1 --oneline
```

**Expected:** record the exact commit hash in the retest log.

**Failure:** unexpected branch tip → stop.

---

## 5. Install

```bash
sudo ./install.sh
```

**Expected output includes:**

```text
INSTALL_MODE=FRESH|REINSTALL
CONFIG_PRESERVED=...
SELECTIVE_PRESERVED=...
PHASE2_PRESERVED=...
SIGNING_KEY_PRESERVED=...
CLIENT_SET_PRESERVED=...
HTTP_STATE_BEFORE=...
HTTP_STATE_AFTER=...
HTTP_REENABLE_REQUIRED=...
NEXT_REQUIRED_ACTION=...
```

On a clean snapshot: `INSTALL_MODE=FRESH`, `HTTP_STATE_AFTER=DISABLED`, `NEXT_REQUIRED_ACTION=CONFIGURATION_REQUIRED`.

**Failure interpretation:**

- `RUNTIME_DEPENDENCY_CLOSURE=FAIL` → install aborted; do not continue
- `HTTP_REENABLE_REQUIRED=YES` on reinstall → follow Menu 3 after config/prepare, do not start nginx by hand

**Stop if:** install does not complete or reports missing runtime files.

---

## 6. Configuration

```bash
sudo ubuntu-offline-mirror mirror-manager
```

Menu **1 Configuration**:

1. Preparation Mode = **Full OS Upgrade + Phase 2**
2. Confirm **Mirror Server IP** (operator-confirmed; do not rely on auto-detect alone)
3. Enter ACPS username / password
4. Save

**Expected:** Configuration `[COMPLETED]`.

**Failure:** Mirror IP interface validation FAIL → fix networking or choose the correct host IP.

**Stop if:** ACPS credentials are wrong and connection test fails (download will fail later).

---

## 7. Download and Prepare

Menu **2 Download and Prepare Upgrade Files**.

**Expected:**

- OS Core (FULL) prepared
- Phase 2 6.5.0 bundle verified
- four hop clients built, signed, atomically published
- `PRIVATE_KEY_HTTP_PUBLISHED=NO`

**Failure:** network / checksum / client finalization errors → do not skip to Menu 7.

**Stop if:** `CLIENT_SET_ATOMIC_SWAP=NOT_STARTED` or client files incomplete.

---

## 8. Enable HTTP Distribution

Menu **3 Enable HTTP Distribution**.

**Expected:**

- `nginx -t` PASS
- local + advertised HTTP smoke PASS
- public tree modes `0755` / `0644`
- `HTTP_DISTRIBUTION=ENABLED`

**Failure:** smoke FAIL → nginx rolled back; artifacts preserved. Fix and retry Menu 3.

**Stop if:** HTTP remains disabled.

---

## 9. Verify Upgrade Readiness

Menu **4 Verify Upgrade Readiness**.

**Expected:**

```text
UPGRADE_READINESS=PASS
READINESS_VERIFIED_GENERATION_ID=<current publication generation>
```

**Failure:** generation mismatch or HTTP probe FAIL → return to Menu 3/2 as indicated.

**Stop if:** readiness is not PASS.

---

## 10. Menu 7 — DP Client Upgrade Commands

Menu **7 Show DP Client Upgrade Commands**.

**Expected:**

- one scrollable TUI viewer (dialog/whiptail), not `less`, not a terminal reprint
- FULL mode Steps 0–9 in one view
- each executable command is exactly one physical line
- each hop line contains `EXPECTED_FPR='...'`, `public-keyring.gpg`, and `gpgv`
- file written atomically to `/var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt`

If blocked:

```text
DP_CLIENT_COMMANDS_AVAILABLE=NO
BLOCK_REASON=...
REQUIRED_ACTION=...
```

**Failure:** follow `REQUIRED_ACTION` (Enable HTTP / Verify Readiness / regenerate).

**Stop if:** Menu 7 shows commands while HTTP is down.

---

## 11. Full command file generation verification

```bash
sudo grep -E "HOP='(xenial-to-bionic|bionic-to-focal|focal-to-jammy|jammy-to-noble)'" \
  /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt | wc -l
sudo grep -c "EXPECTED_FPR=" \
  /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt
sudo test -s /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt \
  && stat -c '%a' /var/log/ubuntu-mirror-automation/dp-client-upgrade-commands.txt
```

**Expected:** hop count `4`, `EXPECTED_FPR` present, non-empty file mode `644`.

**Failure:** empty file or hop count 0 in FULL mode → do not use the file; regenerate via Menu 7 after readiness.

**Stop if:** command file is empty or PHASE2-only content while mode is FULL.

---

## 12. DP Step 2 execution

On the DP (after hypervisor snapshot), copy the **entire** Step 2 physical line from the viewer
(`cd /home/aella` through the final argument). Visual wrapping is not a newline.

**Expected:** downloads into an isolated temp workdir, fingerprint pin PASS, gpgv PASS, script SHA bindings PASS, then the hop client starts.

**Failure interpretation:**

- connection refused / HTTP 403/404 → Mirror HTTP not ready; return to Menu 3/4
- fingerprint mismatch → stop; do not proceed
- signature / SHA mismatch → stop; do not proceed

**Stop if:** any verification fails before `sudo bash` (execution count must remain 0).

---

## 13. Safe resume result check

If a previous FAILED legacy flag exists without post-baseline package transition:

**Expected:** safe resume (no manual state deletion).

If a real post-baseline package transition is detected:

**Expected:** exit `29` / manual review — do not delete state to force continue.

**Stop if:** exit 29 with real transition evidence — escalate per runbook.

---

## 14. Next hop progress condition

Proceed to the next OS hop only when:

1. current hop completed successfully
2. Mirror HTTP + readiness generations are still current
3. the next hop one-line command is copied complete from Menu 7

Do not reuse a command file generated under a different Mirror IP, mode, or client generation.

---

## 15. Acceptance

Retest PASS only when:

- install reported HTTP state clearly
- FULL prepare → HTTP enable → readiness PASS for one generation
- Menu 7 emitted four one-line hop commands with `EXPECTED_FPR`
- DP Step 2 verified downloads without deleting prior `/home/aella` evidence on HTTP failure
- safe resume / exit 29 behavior matches policy
- no forbidden manual repairs were used

After evidence collection, restore the lab snapshot again for the next run.
