# Phase 2 bringup patch fragments

These files are project-owned insertions applied to a **fresh ACPS
upstream** `bringup_py3_dp_after_os_upgrade.sh`.

Production authority:

    FINAL_BRINGUP = current ACPS upstream + deterministic patch layer

`vendor/dp-phase2/bringup_py3_dp_after_os_upgrade.sh` is a reference /
golden output for the last known upstream generation. It is **not**
copied over a newly downloaded ACPS file.

The ACPS file is vendor-owned and immutable. This directory is
project-owned. Incompatible upstream layouts fail closed
(`BRINGUP_PATCH_COMPAT=FAIL`) before any DP upgrade.
