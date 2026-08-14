# DP Phase 2 bringup — source roles and provenance

This repository does **not** author the bringup script. The authoritative
upstream is the ACPS release artifact. Files under `vendor/dp-phase2/` are a
locally maintained patched copy used for dark-site operations.

## A. Source roles

| Role | Term | Meaning |
|------|------|---------|
| ACPS artifact | `UPSTREAM_AUTHORITATIVE_SOURCE` | Unmodified bringup from the ACPS release; sole authoritative upstream |
| Vendor bringup | `LOCAL_PATCHED_SOURCE` | Locally maintained patched copy of that upstream |
| Upstream checksum | `*.upstream.sha1` | SHA1 of the **unmodified** upstream baseline (not the patched vendor file) |
| Spool release | `GENERATED_BUNDLE_ARTIFACT` / `PUBLISHED_RELEASE` | Timestamped deployment artifact derived from the patched source; not an editable source of truth |

Do **not** call both the ACPS artifact and the vendor file “SoT”.
Prefer the explicit names above.

## B. Current provenance

- **Target DP version:** 6.5.0
- **Upstream release ID:** `20260726T155911Z`
- **UPSTREAM_AUTHORITATIVE_SOURCE** (artifact path):
  `/var/spool/apt-mirror/dp-phase2/6.5.0/releases/20260726T155911Z/files/bringup_py3_dp_after_os_upgrade.sh`
- **Reference / last-known unmodified upstream SHA1:**
  `70de02dd62409110dadb7553991d1ffb0a79f396`
  (recorded in `bringup_py3_dp_after_os_upgrade.sh.upstream.sha1`).
  This is observability / change detection only. Download-and-prepare
  integrity is the current ACPS `.sha1` sidecar, not this reference hash.
- **LOCAL_PATCHED_SOURCE:**
  `vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh`
- **Local patches currently applied:**
  - Image import heartbeat and long-running-operation notice
  - Post-bringup DP pause/resume operator guidance
- The local patched file is **expected not** to match `*.upstream.sha1`.

`GENERATED_BUNDLE_ARTIFACT` / `PUBLISHED_RELEASE` live under the apt-mirror
spool (timestamped release directories and any `current` symlink). They are
outputs of a rebuild/publish step, not editable sources.

## C. Future upstream refresh procedure

1. Download or copy the new ACPS upstream file.
2. Record its release ID and exact SHA1.
3. Compare the new upstream with the previous upstream baseline.
4. Reapply or merge local patches onto the new upstream.
5. Run `bash -n` and all bringup-related tests.
6. Update `bringup_py3_dp_after_os_upgrade.sh.upstream.sha1` to the new
   **unmodified** upstream checksum.
7. Update this README’s provenance section.
8. Only afterward rebuild a new timestamped bundle
   (`GENERATED_BUNDLE_ARTIFACT`).
9. Never overwrite an existing `PUBLISHED_RELEASE`.

## D. Explicit naming

Use these terms consistently in docs, comments, and operational notes:

- `UPSTREAM_AUTHORITATIVE_SOURCE`
- `LOCAL_PATCHED_SOURCE`
- `GENERATED_BUNDLE_ARTIFACT`
- `PUBLISHED_RELEASE`
