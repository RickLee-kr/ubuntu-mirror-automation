#!/usr/bin/env python3
"""Compare internet vs selective-mirror Xenial→Bionic evidence bundles.

Accepts extracted directories produced by
collect-xenial-bionic-upgrade-baseline.sh.
"""
from __future__ import print_function, unicode_literals

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from xenial_bionic_upgrade_analysis import (  # noqa: E402
    compare_evidence_bundles, dump_json,
)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--internet-dir', required=True)
    parser.add_argument('--mirror-dir', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args(argv)

    for d in (args.internet_dir, args.mirror_dir):
        if not os.path.isdir(d):
            print('missing directory: %s' % d, file=sys.stderr)
            return 2

    report = compare_evidence_bundles(args.internet_dir, args.mirror_dir)
    dump_json(report, args.out)
    print('version_mismatch_count=%d' % report['version_mismatch_count'])
    print('core_package_mismatch_count=%d' % len(report['core_package_mismatch']))
    print('kernel_mismatch_count=%d' % len(report['kernel_mismatch']))
    print('only_internet=%d' % len(report['package_only_in_internet']))
    print('only_mirror=%d' % len(report['package_only_in_mirror']))
    print('wrote %s' % args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
