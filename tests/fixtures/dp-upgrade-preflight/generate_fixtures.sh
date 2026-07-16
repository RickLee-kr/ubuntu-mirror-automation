#!/usr/bin/env bash
# Generate synthetic collector 1.0.2-compatible fixtures for preflight tests.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

reset_vars() {
  hostname="fixture-host"
  os_ver="16.04"
  os_code="xenial"
  dp_ver="6.5.0ubuntu1"
  dp_status="detected"
  dp_role="AIO"
  cluster="true"
  workers="[]"
  shell_root="/bin/bash"
  shell_aella="/bin/bash"
  root_avail="500000000000"
  boot_avail="500000000000"
  aella_avail="500000000000"
  aella_mounted="false"
  ntp="true"
  held_count="0"
  coll_status="complete"
  script_ver="1.0.2"
  schema_ver="1.0"
  py3="false"
  py3_count="0"
  legacy="true"
  legacy_count="25"
  upgrade_state="null"
  upgrade_detected="false"
  hop="false"
}

make_base() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"/{system,storage,apt/sources.list.d,network,services,dp,upgrade/{state-files,apt-logs,dist-upgrade-logs,aella-upgrade-logs},data-preservation,security}
  : >"$dir/collection.log"
  printf 'check_id\tcategory\tcommand_description\tcommand\tstarted_at_utc\tduration_ms\treturn_code\tstatus\toutput_file\terror_summary\n' >"$dir/commands.tsv"
  printf 'smoke\tself\tok\ttrue\t2026-07-16T00:00:00Z\t1\t0\tSUCCESS\tcollection.log\t\n' >>"$dir/commands.tsv"
  printf '(no automatic findings)\n' >"$dir/findings.txt"
  printf 'Synthetic fixture summary\n' >"$dir/summary.txt"
  printf 'redaction: none\n' >"$dir/security/redaction-report.txt"
  printf 'root:x:0:0:root:/root:/bin/bash\naella:x:1001:1001:aella:/home/aella:/bin/bash\n' >"$dir/system/users-and-shells.txt"
  printf 'Ubuntu\n' >"$dir/system/os-release.txt"
  printf 'codename\n' >"$dir/system/lsb-release.txt"
  printf 'Linux\n' >"$dir/system/uname.txt"
  printf 'fixture-host\n' >"$dir/system/hostname.txt"
  cat >"$dir/storage/target-filesystems.txt" <<'EOF'
path	filesystem	mountpoint	fstype	total_bytes	used_bytes	avail_bytes	inodes_used	inodes_free	read_only
/	/dev/sda1	/	ext4	623852371968	100000000000	500000000000	1000000	70000000	false
/boot	/dev/sda1	/	ext4	623852371968	100000000000	500000000000	1000000	70000000	false
/opt/aelladata	/dev/sda1	/	ext4	623852371968	100000000000	500000000000	1000000	70000000	false
EOF
  printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/sda1 78396464 1000000 70000000 2%% /\n' >"$dir/storage/df-inodes.txt"
  printf 'Filesystem Size Used Avail Use%% Mounted on\n/dev/sda1 581G 93G 466G 17%% /\n' >"$dir/storage/df-h.txt"
  : >"$dir/storage/mounts.txt"
  : >"$dir/apt/dpkg-audit.txt"
  : >"$dir/apt/dpkg-status-check.txt"
  printf '=== lock files ===\nexists /var/lib/dpkg/lock\n  in_use=false_or_unknown\n' >"$dir/apt/apt-locks.txt"
  : >"$dir/apt/held-packages.txt"
  printf '# deduplicated source URIs\nhttp://archive.ubuntu.com/ubuntu/\nhttp://security.ubuntu.com/ubuntu/\n' >"$dir/apt/source-uris.txt"
  : >"$dir/apt/third-party-repositories.txt"
  printf 'codename ok\n' >"$dir/apt/codename-check.txt"
  : >"$dir/apt/pending-actions.txt"
  printf 'hostname\tstatus\tdetail\narchive.ubuntu.com\tSUCCESS\t1.2.3.4\nsecurity.ubuntu.com\tSUCCESS\t1.2.3.5\nchangelogs.ubuntu.com\tSUCCESS\t1.2.3.6\nold-releases.ubuntu.com\tSUCCESS\t1.2.3.7\n' >"$dir/network/dns-tests.tsv"
  cat >"$dir/network/http-tests.tsv" <<'HTTPEOF'
url	http_status	result
http://archive.ubuntu.com/ubuntu/dists/xenial/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release	200	200
http://security.ubuntu.com/ubuntu/dists/xenial-security/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/bionic/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/focal/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/jammy/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/noble/Release	200	200
http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release	404	404
http://changelogs.ubuntu.com/meta-release-lts	200	200
HTTPEOF
  printf 'NTP synchronized: yes\n' >"$dir/network/ntp-status.txt"
  printf 'PRESENT\tdir\t/opt/aelladata\nABSENT\t-\t/opt/aelladata/os-upgrade\nABSENT\t-\t/opt/aelladata/aelladeb_py3\nPRESENT\tdir\t/opt/aelladata/aelladeb\n' >"$dir/dp/important-paths.txt"
  printf '# DP version evidence\naella-uvp\t6.5.0ubuntu1\tinstall ok installed\n' >"$dir/dp/version-evidence.txt"
  printf '# Role evidence\nrole=AIO\n' >"$dir/dp/role-evidence.txt"
  printf '# Cluster\ncluster services present\n' >"$dir/dp/cluster-evidence.txt"
  : >"$dir/dp/worker-ips.txt"
  printf 'aelladeb_py3_exists=false\n' >"$dir/dp/aelladeb-py3-summary.txt"
  printf 'aelladeb_exists=true\nfile_count=25\n' >"$dir/dp/aelladeb-summary.txt"
  printf 'not a separate mount\n' >"$dir/dp/aelladata-mount.txt"
  printf 'ABSENT\n' >"$dir/upgrade/os-upgrade-state.txt"
  printf 'ABSENT\n' >"$dir/upgrade/hop-history.txt"
  cat >"$dir/data-preservation/aelladata-size-summary.txt" <<'EOF'
=== total ===
58G	/opt/aelladata
=== counts ===
files=13739
dirs=1827
EOF
  printf 'path\tsize_bytes\tsha256\n/opt/aelladata/cluster-name\t0\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n/opt/aelladata/release-metadata.yml\t138\tabc123\n/opt/aelladata/release-image.yml\t4537\tdef456\n' >"$dir/data-preservation/critical-config-checksums.tsv"
  printf 'path\ttype\tsize\n' >"$dir/data-preservation/aelladata-metadata-manifest.tsv"
  local i
  for i in $(seq 1 30); do printf '/opt/aelladata/f%s\tfile\t%d\n' "$i" "$i" >>"$dir/data-preservation/aelladata-metadata-manifest.tsv"; done
  printf 'notes\n' >"$dir/data-preservation/manifest-notes.txt"
  printf 'top\n' >"$dir/data-preservation/aelladata-top-level.txt"
}

write_summary() {
  local dir="$1"
  local coll_id upgrade_state_json role_json dp_ver_json
  coll_id="$(basename "$dir")"
  upgrade_state_json="$upgrade_state"
  if [[ "$upgrade_state" != "null" ]]; then
    upgrade_state_json="\"$upgrade_state\""
  fi
  if [[ "$dp_role" == "null" ]]; then role_json="null"; else role_json="\"$dp_role\""; fi
  if [[ "$dp_ver" == "null" ]]; then dp_ver_json="null"; else dp_ver_json="\"$dp_ver\""; fi

  cat >"$dir/summary.json" <<EOF
{
  "schema_version": "${schema_ver}",
  "script_version": "${script_ver}",
  "collection_id": "${coll_id}",
  "started_at_utc": "2026-07-16T00:00:00Z",
  "completed_at_utc": "2026-07-16T00:00:30Z",
  "duration_seconds": 30,
  "hostname": "${hostname}",
  "fqdn": "${hostname}",
  "execution_user": "root",
  "effective_user_id": 0,
  "is_root": true,
  "sudo_user": "root",
  "os": {
    "id": "ubuntu",
    "version_id": "${os_ver}",
    "codename": "${os_code}",
    "kernel": "4.4.0-210-generic",
    "architecture": "x86_64"
  },
  "dp": {
    "version": ${dp_ver_json},
    "version_status": "${dp_status}",
    "role": ${role_json},
    "cluster_detected": ${cluster},
    "worker_ips": ${workers}
  },
  "shells": {
    "root": "${shell_root}",
    "aella": "${shell_aella}"
  },
  "storage": {
    "root_available_bytes": ${root_avail},
    "boot_available_bytes": ${boot_avail},
    "aelladata_available_bytes": ${aella_avail},
    "aelladata_mounted": ${aella_mounted}
  },
  "time": {
    "utc_now": "2026-07-16T00:00:10Z",
    "ntp_synchronized": ${ntp},
    "source": "timedatectl"
  },
  "apt": {
    "dpkg_audit_clean": true,
    "held_package_count": ${held_count},
    "source_uri_count": 2
  },
  "upgrade": {
    "existing_state_detected": ${upgrade_detected},
    "state": ${upgrade_state_json},
    "hop_history_detected": ${hop}
  },
  "bringup": {
    "aelladeb_py3_exists": ${py3},
    "aelladeb_py3_file_count": ${py3_count},
    "aelladeb_exists": ${legacy},
    "aelladeb_file_count": ${legacy_count}
  },
  "collection": {
    "status": "${coll_status}",
    "successful_checks": 39,
    "failed_checks": 0,
    "skipped_checks": 0,
    "warnings": []
  }
}
EOF
}

mk() {
  reset_vars
  make_base "$1"
}

# xenial-aio-current-blocked
mk xenial-aio-current-blocked
hostname=stellar shell_aella=/usr/bin/aella_cli held_count=2
write_summary xenial-aio-current-blocked
printf 'systemd\nudev\n' >xenial-aio-current-blocked/apt/held-packages.txt
printf 'aella shell is not /bin/bash\n/opt/aelladata is not a separate mount\naelladeb_py3 was not found\n' >xenial-aio-current-blocked/findings.txt
cat >xenial-aio-current-blocked/network/http-tests.tsv <<'EOF'
url	http_status	result
http://archive.ubuntu.com/ubuntu/dists/xenial/Release	404	404
http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release	404	404
http://security.ubuntu.com/ubuntu/dists/xenial-security/Release	404	404
http://archive.ubuntu.com/ubuntu/dists/bionic/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/focal/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/jammy/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/noble/Release	200	200
http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release	404	404
http://changelogs.ubuntu.com/meta-release-lts	200	200
EOF
printf 'path\ttype\tsize\n' >xenial-aio-current-blocked/data-preservation/aelladata-metadata-manifest.tsv
for i in $(seq 1 100); do printf '/opt/aelladata/f%s\tfile\t%d\n' "$i" "$i" >>xenial-aio-current-blocked/data-preservation/aelladata-metadata-manifest.tsv; done

mk xenial-aio-ready
hostname=ready-aio
write_summary xenial-aio-ready
cat >xenial-aio-ready/network/http-tests.tsv <<'EOF'
url	http_status	result
http://archive.ubuntu.com/ubuntu/dists/xenial/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release	200	200
http://security.ubuntu.com/ubuntu/dists/xenial-security/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/bionic/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/focal/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/jammy/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/noble/Release	200	200
http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release	404	404
http://changelogs.ubuntu.com/meta-release-lts	200	200
EOF
printf 'http://archive.ubuntu.com/ubuntu/\nhttp://security.ubuntu.com/ubuntu/\n' >xenial-aio-ready/apt/source-uris.txt

mk xenial-archive-200-old-releases-404
hostname=xenial-archive-ok
write_summary xenial-archive-200-old-releases-404
cat >xenial-archive-200-old-releases-404/network/http-tests.tsv <<'EOF'
url	http_status	result
http://archive.ubuntu.com/ubuntu/dists/xenial/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release	200	200
http://security.ubuntu.com/ubuntu/dists/xenial-security/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/bionic/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/focal/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/jammy/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/noble/Release	200	200
http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release	404	404
http://changelogs.ubuntu.com/meta-release-lts	200	200
EOF
printf 'http://archive.ubuntu.com/ubuntu/\nhttp://security.ubuntu.com/ubuntu/\n' >xenial-archive-200-old-releases-404/apt/source-uris.txt

mk noble-650-noop
hostname=noble-noop os_ver=24.04 os_code=noble dp_ver=6.5.0 aella_mounted=true py3=true py3_count=5
write_summary noble-650-noop
printf 'PRESENT\tdir\t/opt/aelladata\nPRESENT\tdir\t/opt/aelladata/aelladeb_py3\n' >noble-650-noop/dp/important-paths.txt
cat >noble-650-noop/network/http-tests.tsv <<'EOF'
url	http_status	result
http://archive.ubuntu.com/ubuntu/dists/noble/Release	200	200
http://changelogs.ubuntu.com/meta-release-lts	200	200
EOF

mk noble-640-offline-missing-bundle
hostname=noble-phase2 os_ver=24.04 os_code=noble dp_ver=6.4.0
write_summary noble-640-offline-missing-bundle

mk unknown-dp-version
hostname=unknown-dp dp_ver=null dp_status=unknown
write_summary unknown-dp-version
printf '# no versions\n' >unknown-dp-version/dp/version-evidence.txt

mk conflicting-dp-version
hostname=conflict-dp dp_ver=6.5.0 dp_status=conflicting
write_summary conflicting-dp-version

mk master-workers-complete
hostname=master1 dp_role=master workers='["10.0.0.2","10.0.0.3"]'
write_summary master-workers-complete

mk master-workers-missing
hostname=master-missing dp_role=master workers='[]'
write_summary master-workers-missing
printf '10.0.0.9\n' >master-workers-missing/dp/worker-ips.txt

mk partial-collection-critical-missing
hostname=partial coll_status=partial
write_summary partial-collection-critical-missing
rm -f partial-collection-critical-missing/network/ntp-status.txt
rm -f partial-collection-critical-missing/apt/held-packages.txt

mk xenial-archive-404-old-releases-200
hostname=xenial-fallback
write_summary xenial-archive-404-old-releases-200
cat >xenial-archive-404-old-releases-200/network/http-tests.tsv <<'EOF'
url	http_status	result
http://archive.ubuntu.com/ubuntu/dists/xenial/Release	404	404
http://archive.ubuntu.com/ubuntu/dists/xenial-updates/Release	404	404
http://security.ubuntu.com/ubuntu/dists/xenial-security/Release	404	404
http://old-releases.ubuntu.com/ubuntu/dists/xenial/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/bionic/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/focal/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/jammy/Release	200	200
http://archive.ubuntu.com/ubuntu/dists/noble/Release	200	200
http://changelogs.ubuntu.com/meta-release-lts	200	200
EOF
printf 'http://old-releases.ubuntu.com/ubuntu/\n' >xenial-archive-404-old-releases-200/apt/source-uris.txt

mk corrupt-state
hostname=corrupt-state upgrade_state=COMPLETED upgrade_detected=true
write_summary corrupt-state
printf 'COMPLETED\n' >corrupt-state/upgrade/os-upgrade-state.txt

mk low-root-space
hostname=lowroot root_avail=1000
write_summary low-root-space
sed -i 's/500000000000/1000/g' low-root-space/storage/target-filesystems.txt

mk low-boot-space
hostname=lowboot boot_avail=1000
write_summary low-boot-space

mk low-inodes
hostname=lowinode
write_summary low-inodes
cat >low-inodes/storage/target-filesystems.txt <<'EOF'
path	filesystem	mountpoint	fstype	total_bytes	used_bytes	avail_bytes	inodes_used	inodes_free	read_only
/	/dev/sda1	/	ext4	623852371968	100000000000	500000000000	9000000	500000	false
/boot	/dev/sda1	/	ext4	623852371968	100000000000	500000000000	9000000	500000	false
/opt/aelladata	/dev/sda1	/	ext4	623852371968	100000000000	500000000000	9000000	500000	false
EOF

mk root-aella-cli
hostname=rootshell shell_root=/usr/bin/aella_cli
write_summary root-aella-cli

mk apt-lock-active
hostname=aptlock
write_summary apt-lock-active
printf '=== lock files ===\nexists /var/lib/dpkg/lock\n  in_use=true\n' >apt-lock-active/apt/apt-locks.txt

mk failed-upgrade-state
hostname=failed-up upgrade_state=FAILED upgrade_detected=true
write_summary failed-upgrade-state
printf 'FAILED\n' >failed-upgrade-state/upgrade/os-upgrade-state.txt

mk dp61-blocked
hostname=dp61 dp_ver=6.1.5
write_summary dp61-blocked

mk focal-remaining-hops
hostname=focal20 os_ver=20.04 os_code=focal
write_summary focal-remaining-hops

mk invalid-summary-json
hostname=badsjon
write_summary invalid-summary-json
printf '{ not valid json' >invalid-summary-json/summary.json

mk unsupported-collector
hostname=oldcol script_ver=0.9.0
write_summary unsupported-collector

mkdir -p malicious-archive
printf 'placeholder\n' >malicious-archive/README.txt

mk noble-640-with-bundle
hostname=noble-bundle os_ver=24.04 os_code=noble dp_ver=6.4.0 py3=true py3_count=10
write_summary noble-640-with-bundle
printf 'aelladeb_py3_exists=true\nbringup_py3_dp_after_os_upgrade.sh\nfile_count=10\n' >noble-640-with-bundle/dp/aelladeb-py3-summary.txt

echo "Fixtures regenerated under $ROOT"
