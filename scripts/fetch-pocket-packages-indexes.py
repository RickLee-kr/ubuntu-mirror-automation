#!/usr/bin/env python3
"""Fetch Ubuntu Packages indexes only (not pool/.deb) for pocket provenance.

Writes a local ubuntu/dists tree usable as --pocket-index-root for
build-selective-mirror-plan.py. Does not publish, does not sync pool.

Example:
  python3 scripts/fetch-pocket-packages-indexes.py \\
    --out-root artifacts/upgrade-discovery/analysis/pocket-indexes/ubuntu \\
    --series bionic
"""
from __future__ import print_function, unicode_literals

import argparse
import gzip
import os
import sys

try:
    from urllib.request import urlopen, Request
except ImportError:  # pragma: no cover
    from urllib2 import urlopen, Request  # type: ignore

DEFAULT_SUITES_TMPL = (
    '{series}',
    '{series}-updates',
    '{series}-security',
    '{series}-backports',
)
DEFAULT_COMPONENTS = ('main', 'universe')
DEFAULT_ARCH = 'amd64'
ARCHIVE = 'http://archive.ubuntu.com/ubuntu'
SECURITY = 'http://security.ubuntu.com/ubuntu'


def suite_base_url(suite):
    if suite.endswith('-security'):
        return SECURITY
    return ARCHIVE


def fetch(url, timeout=120):
    req = Request(url, headers={'User-Agent': 'ubuntu-mirror-automation-pocket-index/1.0'})
    resp = urlopen(req, timeout=timeout)
    try:
        return resp.read()
    finally:
        resp.close()


def write_bytes(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-root', required=True,
                        help='Ubuntu root (…/ubuntu) to write dists/ into')
    parser.add_argument('--series', action='append', dest='series',
                        default=None)
    parser.add_argument('--component', action='append', dest='components')
    parser.add_argument('--arch', default=DEFAULT_ARCH)
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args(argv)

    series_list = args.series or ['bionic']
    components = args.components or list(DEFAULT_COMPONENTS)
    written = []
    for series in series_list:
        suites = [tmpl.format(series=series) for tmpl in DEFAULT_SUITES_TMPL]
        for suite in suites:
            base = suite_base_url(suite)
            for component in components:
                rel = 'dists/%s/%s/binary-%s' % (suite, component, args.arch)
                url_gz = '%s/%s/Packages.gz' % (base, rel)
                dest_dir = os.path.join(args.out_root, rel)
                dest_gz = os.path.join(dest_dir, 'Packages.gz')
                dest = os.path.join(dest_dir, 'Packages')
                try:
                    data = fetch(url_gz, timeout=args.timeout)
                except Exception as exc:
                    print('FAIL %s: %s' % (url_gz, exc), file=sys.stderr)
                    return 2
                write_bytes(dest_gz, data)
                try:
                    plain = gzip.decompress(data)
                except Exception:
                    plain = gzip.GzipFile(fileobj=__import__('io').BytesIO(data)).read()
                write_bytes(dest, plain)
                count = plain.count(b'\nPackage:')
                # also count first-line Package:
                if plain.startswith(b'Package:'):
                    count = plain.count(b'Package:')
                else:
                    count = len([
                        ln for ln in plain.splitlines() if ln.startswith(b'Package:')
                    ])
                written.append((suite, component, len(plain), count, url_gz))
                print('OK suite=%s component=%s bytes=%d packages=%d' % (
                    suite, component, len(plain), count,
                ))
    print('wrote_root=%s files=%d' % (args.out_root, len(written)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
