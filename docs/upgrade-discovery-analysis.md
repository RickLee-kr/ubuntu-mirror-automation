# Ubuntu Upgrade Discovery Analysis

Read-only analysis of DP-host upgrade-discovery exports for the four LTS hops
16.04→18.04→20.04→22.04→24.04. Operational mirror/install code was **not**
modified for this work.

Machine-recomputed numbers come from:

```bash
python3 scripts/analyze-upgrade-discovery.py \
  --discovery-root artifacts/upgrade-discovery \
  --output-dir artifacts/upgrade-discovery/analysis
```

Primary machine summary: [`artifacts/upgrade-discovery/analysis/analysis-summary.json`](../artifacts/upgrade-discovery/analysis/analysis-summary.json).

---

## 1. Executive Summary

| Item | Value |
|------|------:|
| Hops with `VALIDATION: PASS` | **4 / 4** |
| `unresolved_packages` / `unresolved_files` | **0 / 0** (all hops) |
| Raw required packages (sum) | **4621** |
| Raw required files (sum) | **4823** |
| Raw required URLs (sum) | **3750** |
| Unique package SHA256 | **3557** |
| Unique package names (URL-decoded) | **1327** |
| Common package names (all 4 hops, decoded) | **519** |
| Unique required URLs | **3738** |
| Captured HTTP body bytes (sum) | **3703243308** (~3.45 GiB) |
| Hosts in `required-urls.tsv` | `archive.ubuntu.com` (3695), `security.ubuntu.com` (55) |
| `changelogs.ubuntu.com` / `old-releases.ubuntu.com` in capture | **absent** |

**Most important conclusions**

1. Discovery exports are internally consistent: `index.tsv` matches per-hop
   manifests and `export-summary.json` after full recount
   (`index_expected_match=true`).
2. Offline upgrade needs **more than apt-mirror pool content**: every hop
   requested `InRelease`, `by-hash` indexes, and release-upgrader
   `*.tar.gz` + `*.gpg`.
3. **`main` alone is not enough**; capture includes `universe`, `restricted`,
   `multiverse`, and pockets `release` / `updates` / `security` / `backports`.
4. Current nginx publishes only `/ubuntu/` → `archive.ubuntu.com` and
   `/offline/` meta; it does **not** publish `security.ubuntu.com` or
   `old-releases.ubuntu.com` host trees. Security compatibility depends on
   client/source rewrite.
5. **Current mirror implementation verdict: `INSUFFICIENT`** for guaranteed
   closed-network `do-release-upgrade` replay of these hops (alias:
   `PARTIAL_with_critical_gaps`). apt-mirror + offline meta cover most debs and
   upgrader tarballs, but by-hash preservation, security host compatibility, and
   xenial long-term `old-releases` preservation are not fully implemented or
   validated.

---

## 2. Input Integrity

| Item | Path / result |
|------|----------------|
| Archive | `/home/aella/ubuntu-mirror-automation/ubuntu-upgrade-discovery-20260719T151847Z.tar.gz` |
| SHA256 sidecar | `ubuntu-upgrade-discovery-20260719T151847Z.tar.gz.sha256` |
| Expected digest | `82dbe399aad6cf9ca5bed69f20553cc741ea03df6f855103721ae1395fca3801` |
| Verification | Digest of repo-local archive matches sidecar hash. Sidecar path text points to `/home/aella/...`; verified via content match + temporary symlink for `sha256sum -c` → **OK** |
| Pre-existing `artifacts/upgrade-discovery` | **Did not exist** (no backup required) |
| Extract root | `artifacts/upgrade-discovery/` |
| Per-hop `checksums.sha256` | All four hops **OK** after extract |

Archive layout confirmed:

```text
artifacts/upgrade-discovery/
├── index.tsv
├── xenial-to-bionic/
├── bionic-to-focal/
├── focal-to-jammy/
└── jammy-to-noble/
```

Each hop contains: `required-packages.tsv`, `required-files.tsv`,
`required-urls.tsv`, `unresolved-*.tsv`, `failed-requests.tsv`,
`evidence.json`, `validation.txt`, `export-summary.json`, `checksums.sha256`.

Original manifest digests after analysis (unchanged):
`artifacts/upgrade-discovery/analysis/original-manifest-checksums.tsv`.

---

## 3. Hop Summary

Values below are from `artifacts/upgrade-discovery/index.tsv` and were
recomputed from manifests (`analysis/index-identity.tsv`: all `match=true`).

| Hop | From→To | Validation | Packages | Files | URLs | Unres P/F | Failed (total/block/nonblock) | recovered_post_hop | Captured bytes |
|-----|---------|------------|---------:|------:|-----:|-----------|-------------------------------|--------------------|---------------:|
| xenial-to-bionic | 16.04→18.04 | PASS | 1106 | 1143 | 860 | 0/0 | 1/0/1 (`stale_by_hash_404`) | true | 590649258 |
| bionic-to-focal | 18.04→20.04 | PASS | 1183 | 1238 | 964 | 0/0 | 0/0/0 | true | 716717487 |
| focal-to-jammy | 20.04→22.04 | PASS | 1166 | 1220 | 965 | 0/0 | 0/0/0 | true | 963350952 |
| jammy-to-noble | 22.04→24.04 | PASS | 1166 | 1222 | 961 | 0/0 | 0/0/0 | true | 1432525611 |

`required_files > required_urls` on every hop because many `.deb` rows come from
`evidence_source=apt_archives` (no HTTP URL in the recorder log) while still
belonging in the package/file manifests.

Expected operator checklist from the task brief matches `index.tsv` exactly for
all listed fields (including xenial `failed_requests_*=1/0/1`).

---

## 4. Package Analysis

Sources: `*/required-packages.tsv` →
`artifacts/upgrade-discovery/analysis/all-required-packages.tsv`.

### 4.1 Totals and dedupe

| Metric | Count |
|--------|------:|
| Raw package rows | 4621 |
| Unique SHA256 | 3557 |
| Unique names (raw) | 1335 |
| Unique names (URL-decoded) | 1327 |
| Common across 4 hops (decoded) | 519 |
| Hop-unique names | xenial 105 / bionic 41 / focal 45 / jammy 171 |
| Cross-hop version differences | 1093 |
| URL-encoded name collisions (`g++` vs `g%2b%2b`) | 14 row-groups |

### 4.2 Repository / component / architecture

| Dimension | Observed |
|-----------|----------|
| `repository_host` | `archive.ubuntu.com` dominant; `security.ubuntu.com` only on xenial hop package rows (3); empty host on `apt_archives` rows |
| `component` (package column) | `main`, `universe`, `restricted` (focal hop has 1 restricted package row); many blanks on archive-only rows |
| URL path components (all hops) | `main` 3277, `universe` 366, `multiverse` 38, `restricted` 37 |
| Architecture | `amd64` + `all` only (no i386 in required packages) |
| Suite column in package TSV | empty for all rows; suite must be inferred from URL (`analysis` does this) |

### 4.3 Ubuntu vs Stellar/Aella

No package/source/filename/URL matched `stellar|aella|gdc-platform`
(`vendor_packages_count=0`). This capture is Ubuntu archive/security content
plus local apt archive residue from the DP upgrade path—not a separate vendor
APT repo payload.

### 4.4 Evidence sources / mirror need

| evidence_source | Rows | Interpretation |
|-----------------|-----:|----------------|
| `proxy_access_log` | 3548 | HTTP-fetched during recording |
| `apt_archives` | 1073 | Present under `/var/cache/apt/archives` without recorder URL |

| mirror_need | Rows |
|-------------|-----:|
| `mirror_deb` | 3313 |
| `mirror_deb_via_archives_no_url` | 1002 |
| `downloaded_not_installed` | 306 |

`apt_archives` / no-URL rows are **not** “install-state only”. They are real
`.deb` filenames that must exist in an offline pool (or already on the DP) for
replay. Treat them as **mirror-required packages with incomplete URL evidence**.

### 4.5 Suspect / excludable

| Class | Finding |
|-------|---------|
| Path-like / non-package names | **0** |
| URL-encoded duplicate names | Collection artifact; decode before union (`urlenc-package-collisions.tsv`) |
| Duplicate package names per hop | Expected (multi-version transitional / pro-client / docker stack); identity is `(name, version, arch, sha256)` |
| Stellar app packages | None in this export |

---

## 5. File Analysis

Sources: `*/required-files.tsv` → `analysis/all-required-files.tsv`.

### 5.1 Category counts (all hops)

| analysis_category | Count |
|-------------------|------:|
| `deb_package` | 4621 |
| `by_hash` | 162 |
| `ubuntu_repository_metadata` (`InRelease`) | 32 |
| `release_upgrader_tarball` | 4 |
| `release_upgrader_signature` | 4 |

No separate `meta-release`, configuration, log/temp, or Stellar application
file rows appear in required-files.

### 5.2 Mirror payload vs local-only

Analyzer marked all 4823 required-file rows as `mirror_payload=required`
because each is either a deb, by-hash object, InRelease, or upgrader
tarball/signature used by the hop. Practical split for server design:

| Must be served by offline mirror | Local DP only / not mirror payload |
|----------------------------------|------------------------------------|
| `pool/*.deb` actually fetched or installed from archives | Recorder cache paths under discovery `runtime/` (not exported) |
| `dists/*/InRelease` for from+to suites | dpkg status / local config |
| `dists/**/by-hash/**` (or proven named-index fallback) | apt lists regenerated on client |
| `dists/<to>-updates/main/dist-upgrader-all/current/<to>.tar.gz{.gpg}` | — |

### 5.3 Duplicate content

`duplicate-content.tsv`: **no** SHA256 maps to multiple distinct URLs inside a
hop. A small number of SHA256 values appear across hops (shared immutable
objects). Query-string URL duplicates: **0**.

### 5.4 `recovered_post_hop`

All four hops have `recovered_post_hop=true` and
`checksum_source=post_hop_download`.

| Hop | repair_notes.recovered_count | Notes |
|-----|-----------------------------:|-------|
| xenial-to-bionic | 0 | Still flagged recovered; mutable metadata warning; 1 historical stale by-hash 404 |
| bionic-to-focal | 1 | Post-hop repair target recovered |
| focal-to-jammy | 1 | Post-hop repair target recovered |
| jammy-to-noble | 4 | Post-hop repair targets recovered |

File-level `evidence_source` remains `proxy_access_log` or `apt_archives`
(no `repair` token). Treat InRelease/by-hash checksums as **possibly refreshed
after the hop** (`mutable_metadata_warning=true`); do not assume byte-identical
replay of mutable metadata without freezing the mirror snapshot.

Derived listing: `analysis/recovered-post-hop.tsv`.

---

## 6. URL Analysis

Sources: `*/required-urls.tsv` → `analysis/all-required-urls.tsv`.

### 6.1 Hostname

| Hostname | URL count | Offline handling |
|----------|----------:|------------------|
| archive.ubuntu.com | 3695 | Map to local `/ubuntu/` (nginx alias) |
| security.ubuntu.com | 55 | Needs rewrite to local `/ubuntu/` **or** dedicated vhost; not published today |
| changelogs.ubuntu.com | 0 | **Absent from capture — does not mean unnecessary.** Likely causes: meta-release fetched before recording, existing local override, or HTTPS not captured by the recorder. Offline mirrors must still serve `/offline/meta-release-lts` and pin client `URI_LTS` (P0-3). |
| old-releases.ubuntu.com | 0 | Not in capture; xenial still came from archive/security |

All recorded statuses are HTTP **200**. `original_url == final_url` for all
rows (no redirect pairs in required-urls). HTTP **304** bodies are not present
as required rows (repair logic may use 304 internally; export keeps secured
200 bodies).

### 6.2 URL types

| url_type | Count |
|----------|------:|
| pool_deb | 3548 |
| by-hash | 162 |
| InRelease | 32 |
| release_upgrader_gpg | 4 |
| release_upgrader_tarball | 4 |

No `Release` / `Release.gpg` / `Packages` **named** paths / `Sources` /
`Translation` / `DEP-11` / `meta-release` rows in required-urls. Indexes were
consumed primarily via **by-hash** + **InRelease**.

by-hash path classes include `binary-amd64`, `i18n`, and `cnf` under
main/restricted/universe/multiverse.

### 6.3 Suites / pockets / components

Pockets observed in URL paths: `release`, `updates`, `security`, `backports`.

Suites observed (metadata URLs): xenial{,-updates,-security,-backports},
bionic{,...}, focal{,...}, jammy{,...}, noble{,...}.

Components in URL paths: **main, restricted, universe, multiverse**.

### 6.4 Per-hop InRelease pairs

Each hop fetches InRelease for **from** and **to** including security +
backports. Example (xenial→bionic):

- `archive.../dists/xenial{,-updates,-backports}/InRelease`
- `security.../dists/xenial-security/InRelease`
- `archive.../dists/bionic{,-updates,-backports}/InRelease`
- `security.../dists/bionic-security/InRelease`

Therefore an offline mirror must retain **previous suite InRelease** for the
duration of the hop, not only the target release.

### 6.5 Release upgraders

Exactly one tarball + one gpg per hop, all from archive:

| Hop | UpgradeTool URL |
|-----|-----------------|
| xenial-to-bionic | `.../dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz` |
| bionic-to-focal | `.../focal-updates/.../focal.tar.gz` |
| focal-to-jammy | `.../jammy-updates/.../jammy.tar.gz` |
| jammy-to-noble | `.../noble-updates/.../noble.tar.gz` |

### 6.6 Failed / non-blocking

Only failure row (historical, non-blocking):

```text
xenial-to-bionic
http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/binary-amd64/by-hash/SHA256/dd07a620a98891dfafff5711f8e838fdff773184dcd1fb401cabf947813c49ba
HTTP 404  file_type=by_hash
classification=COLLECTION_ARTIFACT_non_blocking_stale_by_hash
```

### 6.7 Must-mirror vs optional

| Must respond offline | May omit if policy allows |
|----------------------|---------------------------|
| pool debs referenced by hop | Stale by-hash 404 historical artifact |
| InRelease for from/to suites (archive + security path equivalence) | Named Packages if by-hash fully provided (inverse also possible with care) |
| by-hash objects actually requested (162) **or** validated named-index fallback | changelogs HTML announcements if meta points only to local tools |
| upgrader tar.gz + gpg | old-releases **until** archive drops xenial |
| local `meta-release-lts` (even though absent from this capture) | — |

---

## 7. Existing Implementation Coverage

### 7.1 Code map (read-only survey)

| Area | Location | Behavior vs capture |
|------|----------|---------------------|
| apt-mirror list | `templates/mirror.list`, `lib/config.sh:um_generate_mirror_list` | archive.ubuntu.com only; xenial→noble; release+updates+security+backports; full components |
| nginx | `templates/nginx.conf`, `um_generate_nginx_conf` | `/ubuntu/` → archive tree; `/offline/` meta; **no** security/old-releases/changelogs vhosts |
| Offline sync | `scripts/ubuntu-offline-mirror.sh` | Downloads `meta-release-lts`, upgrader tar/gpg, builds local meta with URL rewrite |
| Meta rewrite | `lib/offline.sh:uom_rewrite_url` | Rewrites archive/security/old-releases → `PUBLIC_BASE_URL/ubuntu/...`; changelogs → `/offline/announcements/` |
| Client sources | `client/client-setup.sh` | Rewrites archive + security hosts to `MIRROR_URL/ubuntu` |
| Dists seed helper | `scripts/seed-dists-metadata.sh` | Fetches InRelease/Release/Packages/dep11/cnf; **not** by-hash |
| Postmirror | `templates/postmirror.sh` | No-op logger |
| Validate | `validate.sh` | Disk/nginx/mirror health; not discovery URL coverage |
| DP upgrade | `scripts/dp-os-upgrade-*.sh`, `config/dp-os-upgrade.conf` | mirror mode uses `/offline/meta-release-lts`; direct mode expects changelogs + optional old-releases |
| Discovery collector | `scripts/discover-upgrade-requirements.sh` + `scripts/lib/discover_upgrade_requirements.py` | Produced these artifacts |
| Size estimates | `mirror.conf` / `lib/config.sh` / README / install menu | minimal **320 GiB**, full **700–900 GiB** (not 305/660; see §8) |

### 7.2 Coverage table (URL classes)

| Collected class | Verdict | Evidence |
|-----------------|---------|----------|
| archive `pool/*.deb` | **COVERED** | apt-mirror suites include components seen in capture |
| archive `InRelease` | **COVERED** | apt-mirror + seed-dists-metadata |
| archive `by-hash` | **PARTIALLY_COVERED** | Requested 118 times; no explicit by-hash sync/validate |
| security `InRelease` / by-hash / 3 debs | **PARTIALLY_COVERED** | Content likely via `*-security` on archive + client rewrite; raw security hostname not served |
| release-upgrader tar/gpg | **COVERED** | `sync_release_upgraders` + nginx `/ubuntu/dists/...` |
| changelogs `meta-release-lts` | **COVERED** (mirror mode) / **NOT_PRESENT_IN_CAPTURE** | Provided under `/offline/`; not seen in this HTTP capture |
| old-releases xenial | **NOT_COVERED** (future) / **NOT_PRESENT_IN_CAPTURE** | No sync from old-releases; allowed in rewrite allowlist only |
| universe/multiverse/backports | **COVERED** only in **full** mode | minimal mode (`main restricted`) is **NOT_COVERED** for this capture |
| Stale by-hash 404 | **COLLECTION_ARTIFACT** | Non-blocking historical failure |

Machine rollup for required URLs: **COVERED 3577**, **PARTIALLY_COVERED 173**
(`analysis/mirror-coverage.tsv`).

---

## 8. Critical Gaps

1. **by-hash not first-class** — 162 required by-hash URLs; seed/validate paths
   do not ensure `dists/**/by-hash/**` presence. Offline apt may fail when
   `Acquire-By-Hash` is active and named files diverge.
2. **security.ubuntu.com host compatibility** — 55 URLs. Without client rewrite
   or nginx alias, closed-network clients that still hit `security.ubuntu.com`
   get failures even if `*-security` suites exist under archive.
3. **meta-release not in capture** — Recording did not retain
   `changelogs.ubuntu.com/meta-release-lts`. Offline success still depends on
   `ubuntu-offline-mirror` local meta + DP `mirror` mode wiring; this gap is
   process/evidence, not proof that meta is unused.
4. **xenial durability** — Capture used archive/security for xenial InRelease.
   When archive drops xenial, current `mirror.list` has no old-releases source;
   DP direct-mode fallback exists in orchestrator code, mirror sync does not.
5. **Minimal mirror is invalid for these hops** — universe/multiverse/backports
   appear in required URLs. Install menu correctly warns minimal is insufficient.
6. **Mutable metadata** — `checksum_source=post_hop_download` +
   `mutable_metadata_warning` means frozen snapshot semantics are required for
   replay; live re-sync can invalidate discovery checksums.
7. **Size documentation inconsistency** — Repo states ~320 GiB minimal and
   ~700–900 GiB full (`PROJECTED_SIZE_GIB_MINIMAL=320`,
   `PROJECTED_SIZE_GIB_FULL` 700 in `lib/config.sh` / 900 in `mirror.conf`,
   README/operations “700–900 GiB”). The task’s “305GB / 660GB” figures do **not**
   appear as current prose claims in this repository (PDF binary also has no
   clear 305/660 GB operator claims). Discovery captured bodies (~3.45 GiB) are
   **hop deltas**, not full suite mirrors. A separate “2TB+” full-everything
   figure is outside this repo’s projected offline upgrade scope (no source/i386
   /ESM/PPA); conflict is scope mismatch, not a single measured tree.

---

## 9. Recommended Architecture

| Decision | Recommendation |
|----------|----------------|
| Keep apt-mirror? | **Yes** as bulk pool/dists engine for archive suites |
| Supplemental metadata mirror? | **Yes** — keep/extend `ubuntu-offline-mirror` for meta-release + upgraders; add **by-hash materialization** (hardlink/copy from Packages/Translation/cnf or explicit fetch) |
| Static URL snapshot? | **Yes (P0/P1)** — freeze discovery-required URL set per hop for regression; optional small supplemental tree for any URL apt-mirror misses |
| nginx compatibility | Serve one canonical `/ubuntu/` tree; add optional `server_name` aliases **or** enforce client rewrite for security/old-releases; keep `/offline/meta-release-lts` |
| Hop vs unified mirror | **Unified** xenial→noble full components (matches current design); hop-specific snapshots optional for lab replay |
| Capacity model | Continue projecting **full suite** sizes (hundreds of GiB), not discovery captured bytes; reconcile `PROJECTED_SIZE_GIB_FULL` 700 vs 900; document GiB vs GB |

---

## 10. Implementation Plan

### P0 — blocks offline upgrade confidence

| Work | Files | Change | Tests | Done when | Regression risk |
|------|-------|--------|-------|-----------|-----------------|
| by-hash guarantee | `scripts/lib/sync_by_hash.py`, `scripts/ubuntu-offline-mirror.sh`, `validate.sh` | **Implemented (P0-1):** after apt-mirror + `clean.sh`, supplemental by-hash sync/validate/stale-cleanup from Release metadata; nginx serves via existing `/ubuntu/` alias | `tests/test_sync_by_hash.py` + discovery URL shape check | `validate-by-hash` → `validation_result=PASS`; discovery by-hash path shapes (binary-amd64/i18n/cnf + SHA256) supported without hardcoding URL count | Clean script deleting “unreferenced” files (mitigated: by-hash re-materialized after clean) |
| Security host compatibility | `templates/nginx.conf`, `lib/config.sh`, `client/client-setup.sh`, `scripts/lib/validate_security_compat.py` | **Implemented (P0-2):** `/ubuntu-security/` nginx alias → archive tree; client rewrite archive→`/ubuntu`, security→`/ubuntu-security`; optional Host vhosts; discovery shape coverage | `tests/test_security_compat.py` | `unsupported_security_urls=0` for 55 discovery URLs; client sources have no external `security.ubuntu.com` | Double `/ubuntu/ubuntu` path bugs; accidental third-party rewrite |
| Meta-release offline path | `scripts/lib/sync_release_upgraders.py`, `client/client-setup.sh`, `validate.sh`, `ubuntu-offline-mirror.sh` | **Implemented (P0-3):** sync upstream meta-release-lts → verify upgrader tar/gpg with archive keyring → rewrite UpgradeTool* to local `/ubuntu/...` → atomic promote; client sets `URI`/`URI_LTS` to `/offline/meta-release(-lts)`; no changelogs fallback | `tests/test_release_upgraders.py` | `validate-release-upgraders` → `validation_result=PASS`; client meta-release has zero changelogs URIs; external connection attempts 0 in fixture | Wrong `PUBLIC_BASE_URL`; clean.sh deleting upgraders (mitigated: sync after clean) |
| Xenial / old-releases durability | `scripts/lib/sync_legacy_releases.py`, `ubuntu-offline-mirror.sh`, `client/client-setup.sh`, nginx, `validate.sh` | **Implemented (P0-4):** probe archive/security/old-releases; COMPLETE-only staging → active/previous snapshot; materialize into canonical `/ubuntu` tree; restore after clean; client rewrites old-releases→`/ubuntu` | `tests/test_legacy_releases.py` | `validate-legacy-releases` → `validation_result=PASS`; archive 404 + old-releases COMPLETE promotes; upstream fail preserves active | Mixing archive+old-releases hashes (detected); partial promote |
| Reject minimal for upgrade mirrors | `install.sh`, `lib/install-menu.sh`, docs | Hard-fail or strong gate when mode=minimal and offline upgrade profile selected | install tests | Cannot mark READY for 4-hop offline with minimal components | Operators relying on minimal |

### P1 — durability / completeness

| Work | Files | Change | Tests | Done when | Risk |
|------|-------|--------|-------|-----------|------|
| old-releases xenial preservation | (moved to P0-4) | **Implemented** — see P0 table | `tests/test_legacy_releases.py` | xenial InRelease served after archive EOL via old-releases or frozen snapshot | Mixing archive+old-releases hashes |
| Discovery coverage gate | new script or extend analyze | CI check: READY mirror serves analysis `all-required-urls.tsv` | analyzer unit tests | Coverage report 0 missing must-mirror URLs | Flaky live network if not fixture-based |
| Size estimate reconciliation | `mirror.conf`, `lib/config.sh`, README, operations | Single SSOT for full projected GiB | capacity unit test | One documented full projection | Capacity false negatives |

### P2 — quality

| Work | Files | Change | Tests | Done when | Risk |
|------|-------|--------|-------|-----------|------|
| Decode package names in collector | `discover_upgrade_requirements.py` | Store decoded package names; keep raw as separate column | discovery tests | No `g%2b%2b` duplicates | Manifest schema bump |
| Supplemental static snapshot publisher | new under `scripts/` | Publish frozen discovery URL set beside apt-mirror | e2e lab | Replay hop with `--offline` proxy pointing only at mirror | Snapshot staleness |

---

## 11. Verification Plan

1. **Identity** — `python3 scripts/analyze-upgrade-discovery.py` exits 0;
   `index_expected_match=true`.
2. **Hop checksums** — `sha256sum -c` in each hop directory.
3. **Analyzer unit tests** — `python3 tests/test_analyze_upgrade_discovery.py`.
4. **Mirror URL replay (lab)** — For each hop, HTTP GET every
   `offline_requirement=must_mirror` URL from `all-required-urls.tsv` against
   local mirror (with security host rewritten). Fail on non-200.
5. **Closed-network DP replay** — iptables/no-route deny
   `archive|security|changelogs|old-releases`.ubuntu.com; run
   `dp-os-upgrade` mirror mode per hop; compare apt/nginx access logs for
   missing paths.
6. **Package checksum spot-check** — For random sample of unique SHA256 from
   `all-required-packages.tsv`, verify local pool object hash.
7. **Automation bar for “4 hops ready”** — All PASS validations, unresolved=0,
   coverage gate green, upgrader GPG verify, READY marker present.

---

## 12. Open Questions

1. Why was `changelogs.ubuntu.com/meta-release-lts` absent from required-urls?
   (pre-recording fetch, local override, or recorder gap?) Needs a controlled
   re-record with meta URL forced through the proxy.
2. Can apt on each hop fall back from missing by-hash to named `Packages.xz`
   with the exact InRelease in this snapshot? Needs offline experiment.
3. Are the 1073 `apt_archives` debs all findable via archive pool paths for the
   same SHA256, or did some arrive from non-recorder sources?
4. What is the measured on-disk size of a full apt-mirror tree built from
   current `mirror.list` on the operator’s uplink day? (320 / 700 / 900 are
   projections, not measured here.)
5. Should ubuntu-pro / docker.io / containerd stacks be retained in offline
   mirrors for DP images, or stripped as non-base OS? Capture includes them;
   product policy needed (`NEEDS_DECISION`).

---

## 13. P0-1 by-hash implementation status

Supplemental by-hash sync is implemented in-tree (`scripts/lib/sync_by_hash.py`) and
wired into `ubuntu-offline-mirror sync` / `verify` / `validate.sh` (operational).

Discovery cross-check (read-only over `artifacts/upgrade-discovery`):

| Dimension | Observed |
|-----------|----------|
| by-hash URL rows | 162 (sample size — **not** hardcoded in sync logic) |
| Hosts | `archive.ubuntu.com`, `security.ubuntu.com` |
| Algorithm | `SHA256` only |
| Path kinds | `binary-amd64`, `i18n`, `cnf` under all four components |

## 14. P0-2 security.ubuntu.com compatibility status

**On-disk fact:** apt-mirror does not create `mirror/security.ubuntu.com/`. Security
pockets are `dists/<codename>-security` under `archive.ubuntu.com/ubuntu`.

**Architecture chosen:** client path rewrite + nginx `/ubuntu-security/` alias to that
same tree (plus optional Host vhosts). Not chosen as sole mechanism: DNS/`/etc/hosts`
spoofing (optional only via `--write-hosts`).

| Metric | Result |
|--------|--------|
| Discovery `security.ubuntu.com` URLs | 55 |
| Supported URL shapes | 55 (`unsupported_security_urls=0`) |
| Types | InRelease 8, by-hash 44, pool deb 3 |
| Suites | xenial/bionic/focal/jammy/noble `-security` |

**P0-5 completed:** minimal-mirror rejection + `offline-upgrade-full` READY gate
(see §16). Meta-release/changelogs evidence gap in discovery capture remains a
recorder question; offline path is implemented (P0-3). Xenial/old-releases
durability is implemented (P0-4).

---

## 15. P0-4 Xenial / old-releases durability status

**Problem:** apt-mirror only lists `archive.ubuntu.com`. When Xenial is removed from
archive (or returns 404), sync breaks and `clean.sh` can delete the live tree. Discovery
had **zero** `old-releases.ubuntu.com` URLs, but offline mirrors must outlive upstream.

**Architecture:** keep canonical client paths on `/ubuntu` + `/ubuntu-security`. Probe
archive → security → old-releases; promote only `COMPLETE` staging snapshots to
`offline/legacy-releases/xenial/{active,previous}`; re-materialize into
`mirror/archive.ubuntu.com/ubuntu` after clean. Clients rewrite
`old-releases.ubuntu.com` → `/ubuntu`.

| Check | Result |
|-------|--------|
| Fixture: archive COMPLETE | PASS |
| Fixture: archive 404 + old-releases COMPLETE | PASS |
| Upstream fail + active present | active preserved / restored |
| Discovery xenial-to-bionic URL shapes | `unsupported_urls=0` (pattern coverage; URLs not hardcoded) |
| Client external archive/security/old-releases | FAIL if remaining |

**P0-5 completed:** see §16.

---

## 16. P0-5 superseded — offline-upgrade-selective

**Problem (historical):** `offline-upgrade-full` forced a Cartesian
`5×4×4` suite/component mirror + full by-hash (~2.2TB), losing the selective goal.

**Replacement architecture:**

| Piece | Path |
|-------|------|
| Profile SSOT | `config/offline-upgrade-profile.json` (`offline-upgrade-selective`, schema 2) |
| Plan builder | `scripts/build-selective-mirror-plan.py` → `analysis/selective-mirror-*.{json,tsv}` |
| Materialize / publish | `scripts/lib/selective_mirror.py` |
| Verify / READY | `scripts/lib/validate_selective_mirror.py` |
| CLI | `plan-selective` / `materialize-selective` / `verify-selective` / `publish-selective` |

**Behavior:**

- Full apt-mirror sync and minimal profiles → `UNSUPPORTED_*`, no sync
- Selective tree under `/var/spool/apt-mirror/selective` (seed full mirror preserved)
- READY only after discovery-exact selective gates PASS (no by-hash-3219 requirement)
- Original hop artifacts are never modified

---

## Appendix A — Derived artifacts

Created under `artifacts/upgrade-discovery/analysis/` (originals untouched):

- `analysis-summary.json`
- `offline-upgrade-requirements.json` / `.tsv` (P0-5)
- `index-identity.tsv`
- `all-required-packages.tsv`
- `all-required-files.tsv`
- `all-required-urls.tsv`
- `common-packages.tsv`
- `hop-specific-packages.tsv`
- `version-diff-packages.tsv`
- `urlenc-package-collisions.tsv`
- `url-host-summary.tsv`
- `url-type-summary.tsv`
- `url-suite-summary.tsv`
- `url-component-summary.tsv`
- `mirror-coverage.tsv`
- `duplicate-content.tsv`
- `recovered-post-hop.tsv`
- `failed-requests-classified.tsv`
- `original-manifest-checksums.tsv`

- Analyzer: `scripts/analyze-upgrade-discovery.py`
- Tests: `tests/test_analyze_upgrade_discovery.py`
