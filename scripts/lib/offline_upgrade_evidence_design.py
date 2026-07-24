#!/usr/bin/env python3
"""Design-only offline upgrade transaction evidence manifest schema.

Intended path on DP (not applied in this change):
  /opt/aelladata/os-upgrade/offline/evidence/<timestamp>/

This module only documents and validates fixture shapes for pre/post
upgrade read-only manifests. It does not modify live DPs.
"""
from __future__ import print_function, unicode_literals

from collections import OrderedDict

EVIDENCE_SCHEMA_VERSION = 1

PRE_UPGRADE_FILES = OrderedDict([
    ('installed-packages.tsv', 'package\\tversion\\tstatus'),
    ('apt-candidates-core.txt', 'apt-cache policy for core packages'),
    ('apt-mark-hold.txt', 'apt-mark showhold'),
    ('apt-policy.txt', 'apt-cache policy summary / preferences'),
    ('sources.list', 'copy of /etc/apt/sources.list'),
    ('sources.list.d/', 'copy of sources.list.d'),
    ('expected-target-packages.json', 'expected Bionic core set from mirror index'),
])

POST_UPGRADE_FILES = OrderedDict([
    ('installed-packages.tsv', 'package\\tversion\\tstatus'),
    ('dpkg-status-dirty.txt', 'half-configured / unpacked packages'),
    ('apt-get-check.txt', 'apt-get check'),
    ('kernel-packages.tsv', 'linux-image/modules/modules-extra versions'),
    ('boot-listing.txt', 'ls -la /boot'),
    ('initramfs-files.txt', 'initrd.img-* paths and sizes'),
    ('modules-trees.txt', '/lib/modules summary'),
    ('core-versions.tsv', 'systemd/udev/dbus/network package versions'),
    ('packages-index-provenance.json', 'suite/component sha256 of Packages used'),
    ('distupgrade-main.log', 'copy of /var/log/dist-upgrade/main.log'),
])


def evidence_layout(timestamp='YYYYMMDDTHHMMSSZ'):
    base = '/opt/aelladata/os-upgrade/offline/evidence/%s' % timestamp
    return OrderedDict([
        ('schema_version', EVIDENCE_SCHEMA_VERSION),
        ('base_path', base),
        ('pre_upgrade_dir', base + '/pre-upgrade'),
        ('post_upgrade_dir', base + '/post-upgrade-pre-reboot'),
        ('pre_upgrade_files', PRE_UPGRADE_FILES),
        ('post_upgrade_files', POST_UPGRADE_FILES),
        ('note', 'Design only; runner integration deferred until root cause confirmed'),
    ])


def validate_manifest_dir(files_present, phase='pre'):
    """Return list of missing required filenames for a phase."""
    required = PRE_UPGRADE_FILES if phase == 'pre' else POST_UPGRADE_FILES
    missing = []
    present = set(files_present or [])
    for name in required:
        # directory keys end with /
        key = name.rstrip('/')
        if name.endswith('/'):
            if not any(p == key or p.startswith(key + '/') for p in present):
                missing.append(name)
        elif name not in present:
            missing.append(name)
    return missing
