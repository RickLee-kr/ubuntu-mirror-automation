#!/usr/bin/env python3
"""Orchestrate Xenial→Bionic selective offline boot-failure analysis.

Read-only against local mirror + discovery artifacts + optional main.log.
Does not run do-release-upgrade, reboot, or publish.
"""
from __future__ import print_function, unicode_literals

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from xenial_bionic_upgrade_analysis import (  # noqa: E402
    build_full_report, dump_json,
)

DEFAULT_MIRROR = (
    '/var/spool/apt-mirror/selective/published/hops/xenial-to-bionic/ubuntu'
)
DEFAULT_SUITES = [
    'xenial', 'xenial-updates', 'xenial-security', 'xenial-backports',
    'bionic', 'bionic-updates', 'bionic-security', 'bionic-backports',
]
DEFAULT_COMPONENTS = ['main', 'universe']
DEFAULT_CLIENT_SOURCES = [
    'deb [arch=amd64 signed-by=/etc/apt/keyrings/stellar-offline-upgrade.gpg] '
    'http://221.139.249.111/hops/xenial-to-bionic/ubuntu %s main universe' % s
    for s in (
        'xenial', 'xenial-updates', 'xenial-security', 'xenial-backports',
    )
]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ubuntu-root', default=DEFAULT_MIRROR)
    parser.add_argument('--main-log', default='')
    parser.add_argument('--plan-packages-tsv', default=(
        'artifacts/upgrade-discovery/analysis/selective-mirror-packages.tsv'
    ))
    parser.add_argument('--out', default=(
        'artifacts/upgrade-discovery/analysis/'
        'xenial-bionic-boot-failure-report.json'
    ))
    parser.add_argument('--skip-default-client-sources', action='store_true')
    parser.add_argument('--client-sources-file', default='')
    args = parser.parse_args(argv)

    main_log_text = None
    if args.main_log and os.path.isfile(args.main_log):
        with open(args.main_log, 'rb') as fh:
            main_log_text = fh.read().decode('utf-8', 'replace')

    if args.client_sources_file:
        with open(args.client_sources_file, 'rb') as fh:
            client_lines = fh.read().decode('utf-8', 'replace').splitlines()
    elif args.skip_default_client_sources:
        client_lines = None
    else:
        client_lines = DEFAULT_CLIENT_SOURCES

    report = build_full_report(
        args.ubuntu_root,
        DEFAULT_SUITES,
        DEFAULT_COMPONENTS,
        client_sources_lines=client_lines,
        main_log_text=main_log_text,
        plan_packages_tsv=args.plan_packages_tsv,
    )
    dump_json(report, args.out)

    print('most_likely_root_cause=%s' % report['most_likely_root_cause']['primary'])
    print('summary=%s' % report['most_likely_root_cause']['summary'])
    src = report.get('sources_list_distupgrade_semantics') or {}
    if src:
        print('signed_by_verdict=%s' % src.get('verdict'))
        print(
            'invalid_due_to_signed_by=%s' % src.get('invalid_due_to_signed_by')
        )
    print('target_suite_indexes_identical=%s' % (
        report['repository_audit']['target_suite_indexes_identical']
    ))
    print('grub_pc_present=%s' % report['core_package_analysis']['grub_pc_present'])
    for h in report['hypotheses']:
        print('%s verdict=%s' % (h['id'], h['current_verdict'].split('—')[0].strip()))
    print('wrote %s' % args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
