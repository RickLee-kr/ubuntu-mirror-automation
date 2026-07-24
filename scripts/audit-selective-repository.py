#!/usr/bin/env python3
"""Audit selective hop repository suite/component Packages semantics.

Read-only. Example:
  python3 scripts/audit-selective-repository.py \\
    --ubuntu-root /var/spool/apt-mirror/selective/published/hops/xenial-to-bionic/ubuntu \\
    --out artifacts/upgrade-discovery/analysis/repo-audit-xenial-to-bionic.json
"""
from __future__ import print_function, unicode_literals

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from xenial_bionic_upgrade_analysis import (  # noqa: E402
    audit_repository, dump_json,
)

DEFAULT_SUITES = [
    'xenial', 'xenial-updates', 'xenial-security', 'xenial-backports',
    'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
]
DEFAULT_COMPONENTS = ['main', 'universe']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ubuntu-root', required=True)
    parser.add_argument('--from-series', default='xenial')
    parser.add_argument('--to-series', default='bionic')
    parser.add_argument('--suite', action='append', dest='suites')
    parser.add_argument('--component', action='append', dest='components')
    parser.add_argument('--out', required=True)
    parser.add_argument('--tsv-out', default='')
    args = parser.parse_args(argv)

    suites = args.suites or DEFAULT_SUITES
    components = args.components or DEFAULT_COMPONENTS
    report = audit_repository(
        args.ubuntu_root, suites, components,
        from_series=args.from_series, to_series=args.to_series,
    )
    dump_json(report, args.out)

    if args.tsv_out:
        cols = [
            'suite', 'component', 'role', 'release_component_declared',
            'packages_index_exists', 'packages_uncompressed_size',
            'packages_gz_size', 'package_stanza_count', 'unique_package_count',
            'unique_version_count', 'referenced_deb_count', 'existing_deb_count',
            'missing_deb_count', 'checksum_mismatch_count', 'semantic_result',
        ]
        lines = ['\t'.join(cols)]
        for row in report['rows']:
            lines.append('\t'.join(str(row.get(c, '')) for c in cols))
        parent = os.path.dirname(args.tsv_out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(args.tsv_out, 'w') as fh:
            fh.write('\n'.join(lines) + '\n')

    # Human-readable summary to stdout
    for row in report['rows']:
        print(
            'SUITE=%s COMPONENT=%s RELEASE_DECLARED=%s PACKAGES_PRESENT=%s '
            'PACKAGE_COUNT=%s SEMANTIC_RESULT=%s' % (
                row['suite'], row['component'],
                'YES' if row['release_component_declared'] else 'NO',
                'YES' if row['packages_index_exists'] else 'NO',
                row['package_stanza_count'], row['semantic_result'],
            )
        )
    print('target_suite_indexes_identical=%s' % report['target_suite_indexes_identical'])
    print('wrote %s' % args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
