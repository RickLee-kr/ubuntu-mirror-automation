#!/usr/bin/env python3
"""Mirror-only candidate resolution simulation (no downloads, no host mutation).

Inputs:
  --installed-tsv   package\\tversion rows (e.g. from dpkg-query)
  --ubuntu-root     selective hop ubuntu root

Outputs under --out-dir:
  mirror-simulation.json
  internet-baseline-schema.json
  package-diff.json
  unresolved-dependencies.json
  unexpected-kept-core-packages.json
"""
from __future__ import print_function, unicode_literals

import argparse
import os
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from xenial_bionic_upgrade_analysis import (  # noqa: E402
    CORE_PACKAGE_NAMES, dump_json, follow_dependency_closure,
    load_suite_packages, simulate_mirror_candidates,
)

TARGET_SUITES = [
    'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
]
COMPONENTS = ['main', 'universe']


def load_installed(path):
    out = OrderedDict()
    with open(path, 'r') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('package\t') or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) >= 2:
                out[parts[0]] = parts[1]
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ubuntu-root', required=True)
    parser.add_argument('--installed-tsv', required=True)
    parser.add_argument('--out-dir', required=True)
    args = parser.parse_args(argv)

    installed = load_installed(args.installed_tsv)
    packages, _prov = load_suite_packages(
        args.ubuntu_root, TARGET_SUITES, COMPONENTS,
    )
    sim = simulate_mirror_candidates(installed, packages)
    closure = follow_dependency_closure(
        packages, list(CORE_PACKAGE_NAMES),
        fields=('Pre-Depends', 'Depends'),
    )

    os.makedirs(args.out_dir, exist_ok=True)
    dump_json(sim, os.path.join(args.out_dir, 'mirror-simulation.json'))
    dump_json(OrderedDict([
        ('description',
         'Schema placeholder for internet repository candidate resolution. '
         'Actual internet downloads are not performed by this tool.'),
        ('required_fields', [
            'package', 'installed_version', 'candidate_version',
            'candidate_suite', 'candidate_component', 'action',
        ]),
        ('actions', ['install', 'upgrade', 'remove', 'keep']),
        ('note', 'Populate from collect-xenial-bionic-upgrade-baseline.sh '
                 'on an internet-upgraded VM, then compare.'),
    ]), os.path.join(args.out_dir, 'internet-baseline-schema.json'))

    package_diff = OrderedDict([
        ('upgrades', sim.get('upgrades_sample')),
        ('keeps', sim.get('keeps_sample')),
        ('missing_candidates', sim.get('missing_sample')),
        ('counts', OrderedDict([
            ('upgrade', sim['upgrade_count']),
            ('keep', sim['keep_count']),
            ('missing', sim['missing_candidate_count']),
        ])),
    ])
    dump_json(package_diff, os.path.join(args.out_dir, 'package-diff.json'))
    dump_json(OrderedDict([
        ('missing_from_index', closure.get('missing_from_index')),
        ('visited_count', closure.get('visited_count')),
    ]), os.path.join(args.out_dir, 'unresolved-dependencies.json'))
    dump_json(OrderedDict([
        ('unexpected_kept_core_packages',
         sim.get('unexpected_kept_core_packages')),
    ]), os.path.join(args.out_dir, 'unexpected-kept-core-packages.json'))

    print('upgrade_count=%d' % sim['upgrade_count'])
    print('keep_count=%d' % sim['keep_count'])
    print('unexpected_core_keeps=%d' % len(sim['unexpected_kept_core_packages']))
    print('wrote %s' % args.out_dir)
    fail = 1 if sim['unexpected_kept_core_packages'] else 0
    return fail


if __name__ == '__main__':
    sys.exit(main())
