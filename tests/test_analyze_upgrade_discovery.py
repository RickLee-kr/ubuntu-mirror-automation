#!/usr/bin/env python3
"""Unit tests for scripts/analyze-upgrade-discovery.py (stdlib unittest)."""
from __future__ import print_function

import csv
import json
import os
import shutil
import sys
import tempfile
import unittest

import importlib.util

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SCRIPT = os.path.join(ROOT, 'scripts', 'analyze-upgrade-discovery.py')

_spec = importlib.util.spec_from_file_location('analyze_upgrade_discovery', SCRIPT)
aud = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aud)


def _write_tsv(path, fieldnames, rows):
    parent = os.path.dirname(path)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    with open(path, 'w') as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, delimiter='\t', lineterminator='\n')
        w.writeheader()
        for row in rows:
            w.writerow(row)


def _seed_min_hop(base, hop, pkg_n, file_n, url_n, failed_n=0, recovered=True):
    hop_dir = os.path.join(base, hop)
    os.makedirs(hop_dir)
    pkgs = []
    files = []
    urls = []
    for i in range(pkg_n):
        name = 'pkg{}'.format(i)
        url = 'http://archive.ubuntu.com/ubuntu/pool/main/p/{0}/{0}_1_amd64.deb'.format(name)
        sha = 'a' * 64 if i == 0 else format(i, '064x')
        pkgs.append({
            'hop': hop, 'package': name, 'version': '1', 'architecture': 'amd64',
            'source_package': name, 'filename': name + '_1_amd64.deb',
            'repository_host': 'archive.ubuntu.com', 'suite': '', 'component': 'main',
            'size_bytes': '10', 'sha256': sha, 'original_url': url, 'final_url': url,
            'requested': 'true', 'downloaded': 'true', 'installed': 'true',
            'evidence_source': 'proxy_access_log',
        })
    for i in range(url_n):
        if i < pkg_n:
            url = pkgs[i]['original_url']
            utype = 'deb'
            fname = pkgs[i]['filename']
        elif i == pkg_n:
            url = 'http://archive.ubuntu.com/ubuntu/dists/focal/InRelease'
            utype = 'inrelease'
            fname = 'InRelease'
        else:
            url = 'http://security.ubuntu.com/ubuntu/dists/focal-security/main/binary-amd64/by-hash/SHA256/' + ('b' * 64)
            utype = 'by_hash'
            fname = 'SHA256'
        sha = format(i + 1, '064x')
        urls.append({
            'hop': hop, 'requested_at': '2026-01-01T00:00:00Z', 'method': 'GET',
            'original_url': url, 'final_url': url, 'http_status': '200',
            'size_bytes': '10', 'sha256': sha, 'local_path': '/tmp/x',
        })
        files.append({
            'hop': hop, 'file_type': utype, 'filename': fname,
            'original_url': url, 'final_url': url, 'local_path': '/tmp/x',
            'size_bytes': '10', 'sha256': sha, 'http_status': '200',
            'request_count': '1', 'evidence_source': 'proxy_access_log',
        })
    # pad files if file_n > url_n (apt_archives pattern)
    while len(files) < file_n:
        idx = len(files)
        name = 'local{}'.format(idx)
        files.append({
            'hop': hop, 'file_type': 'deb', 'filename': name + '.deb',
            'original_url': '', 'final_url': '', 'local_path': '/var/cache/apt/archives/' + name + '.deb',
            'size_bytes': '10', 'sha256': format(9000 + idx, '064x'), 'http_status': '',
            'request_count': '0', 'evidence_source': 'apt_archives',
        })
        pkgs.append({
            'hop': hop, 'package': name, 'version': '1', 'architecture': 'amd64',
            'source_package': name, 'filename': name + '.deb',
            'repository_host': '', 'suite': '', 'component': '',
            'size_bytes': '10', 'sha256': format(9000 + idx, '064x'),
            'original_url': '', 'final_url': '',
            'requested': 'false', 'downloaded': 'true', 'installed': 'true',
            'evidence_source': 'apt_archives',
        })
    # ensure package count matches pkg_n after padding logic
    pkgs = pkgs[:pkg_n]
    files = files[:file_n]
    urls = urls[:url_n]

    _write_tsv(os.path.join(hop_dir, 'required-packages.tsv'), list(pkgs[0].keys()), pkgs)
    _write_tsv(os.path.join(hop_dir, 'required-files.tsv'), list(files[0].keys()), files)
    _write_tsv(os.path.join(hop_dir, 'required-urls.tsv'), list(urls[0].keys()), urls)
    _write_tsv(os.path.join(hop_dir, 'unresolved-packages.tsv'),
               ['hop', 'package', 'version', 'architecture', 'original_url', 'final_url', 'reason'], [])
    _write_tsv(os.path.join(hop_dir, 'unresolved-files.tsv'),
               ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'reason'], [])
    failed = []
    if failed_n:
        failed.append({
            'hop': hop,
            'original_url': 'http://archive.ubuntu.com/ubuntu/dists/focal-updates/main/binary-amd64/by-hash/SHA256/' + ('c' * 64),
            'final_url': 'http://archive.ubuntu.com/ubuntu/dists/focal-updates/main/binary-amd64/by-hash/SHA256/' + ('c' * 64),
            'http_status': '404', 'reason': 'HTTP 404', 'file_type': 'by_hash',
        })
    _write_tsv(os.path.join(hop_dir, 'failed-requests.tsv'),
               ['hop', 'original_url', 'final_url', 'http_status', 'reason', 'file_type'], failed)
    evidence = {
        'hop': hop,
        'recovered_post_hop': recovered,
        'checksum_source': 'post_hop_download',
        'repair_notes': {'recovered_count': 0, 'failed_count': 0, 'targets': 0},
        'required_packages': pkg_n,
        'required_files': file_n,
        'required_urls': url_n,
        'unresolved_packages': 0,
        'unresolved_files': 0,
        'failed_requests': failed_n,
        'captured_bytes': 100,
        'captured_http_200': url_n,
    }
    with open(os.path.join(hop_dir, 'evidence.json'), 'w') as fh:
        json.dump(evidence, fh)
    summary = {
        'schema_version': 1,
        'hop': hop,
        'validation': 'PASS',
        'required_packages': pkg_n,
        'required_files': file_n,
        'required_urls': url_n,
        'unresolved_packages': 0,
        'unresolved_files': 0,
        'failed_requests': failed_n,
        'failed_requests_total': failed_n,
        'failed_requests_blocking': 0,
        'failed_requests_non_blocking': failed_n,
        'recovered_post_hop': recovered,
        'captured_bytes': 100,
        'non_blocking_failure_reasons': {'stale_by_hash_404': failed_n} if failed_n else {},
    }
    with open(os.path.join(hop_dir, 'export-summary.json'), 'w') as fh:
        json.dump(summary, fh)
    with open(os.path.join(hop_dir, 'validation.txt'), 'w') as fh:
        fh.write('VALIDATION: PASS\nhop={}\nrequired_packages={}\nrequired_files={}\n'.format(
            hop, pkg_n, file_n))
    # checksums file (content not verified by analyzer beyond presence)
    with open(os.path.join(hop_dir, 'checksums.sha256'), 'w') as fh:
        fh.write('0' * 64 + '  validation.txt\n')
    return {
        'hop': hop,
        'from_os': {'xenial-to-bionic': '16.04', 'bionic-to-focal': '18.04',
                    'focal-to-jammy': '20.04', 'jammy-to-noble': '22.04'}[hop],
        'to_os': {'xenial-to-bionic': '18.04', 'bionic-to-focal': '20.04',
                  'focal-to-jammy': '22.04', 'jammy-to-noble': '24.04'}[hop],
        'pkg_n': pkg_n, 'file_n': file_n, 'url_n': url_n, 'failed_n': failed_n,
        'recovered': recovered,
    }


class ClassifyTests(unittest.TestCase):
    def test_classify_url_types(self):
        self.assertEqual(aud.classify_url('http://changelogs.ubuntu.com/meta-release-lts'), 'meta-release')
        self.assertEqual(
            aud.classify_url('http://archive.ubuntu.com/ubuntu/dists/jammy-updates/main/dist-upgrader-all/current/jammy.tar.gz'),
            'release_upgrader_tarball')
        self.assertEqual(
            aud.classify_url('http://archive.ubuntu.com/ubuntu/dists/jammy/InRelease'),
            'InRelease')
        self.assertEqual(
            aud.classify_url('http://security.ubuntu.com/ubuntu/dists/jammy-security/main/binary-amd64/by-hash/SHA256/' + ('a' * 64)),
            'by-hash')
        self.assertEqual(
            aud.classify_url('http://archive.ubuntu.com/ubuntu/pool/main/a/apt/apt_2.0_amd64.deb'),
            'pool_deb')

    def test_suite_pocket_component(self):
        url = 'http://archive.ubuntu.com/ubuntu/dists/noble-backports/universe/binary-amd64/by-hash/SHA256/abcd'
        self.assertEqual(aud.suite_from_url(url), 'noble-backports')
        self.assertEqual(aud.pocket_from_suite('noble-backports'), 'backports')
        self.assertEqual(aud.component_from_url(url), 'universe')

    def test_mirror_coverage_hosts(self):
        cov, _ = aud.mirror_coverage_for_url('http://archive.ubuntu.com/ubuntu/pool/main/a/apt/apt_1_amd64.deb')
        self.assertEqual(cov, 'COVERED')
        cov, _ = aud.mirror_coverage_for_url(
            'http://security.ubuntu.com/ubuntu/dists/jammy-security/InRelease')
        self.assertEqual(cov, 'PARTIALLY_COVERED')
        cov, _ = aud.mirror_coverage_for_url('http://old-releases.ubuntu.com/ubuntu/dists/xenial/InRelease')
        self.assertEqual(cov, 'COVERED')
        cov, _ = aud.mirror_coverage_for_url('http://changelogs.ubuntu.com/meta-release-lts')
        self.assertEqual(cov, 'COVERED')


class AnalyzerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp(prefix='dur-analysis-')
        self.addCleanup(shutil.rmtree, self.tmpdir, True)

    def test_analyze_fixture_recounts_and_writes(self):
        # Build tiny 4-hop tree matching EXPECTED_INDEX counts is heavy;
        # instead patch EXPECTED_INDEX for this test via local fixture that
        # only checks recount identity + outputs.
        meta = []
        specs = [
            ('xenial-to-bionic', 3, 4, 3, 1),
            ('bionic-to-focal', 3, 4, 3, 0),
            ('focal-to-jammy', 3, 4, 3, 0),
            ('jammy-to-noble', 3, 4, 3, 0),
        ]
        for hop, p, f, u, failed in specs:
            meta.append(_seed_min_hop(self.tmpdir, hop, p, f, u, failed_n=failed))
        index_fields = [
            'hop', 'from_os', 'to_os', 'validation', 'required_packages',
            'required_files', 'required_urls', 'unresolved_packages',
            'unresolved_files', 'failed_requests', 'failed_requests_total',
            'failed_requests_blocking', 'failed_requests_non_blocking',
            'recovered_post_hop', 'exported_at_utc', 'relative_path',
        ]
        index_rows = []
        for m in meta:
            index_rows.append({
                'hop': m['hop'], 'from_os': m['from_os'], 'to_os': m['to_os'],
                'validation': 'PASS',
                'required_packages': str(m['pkg_n']),
                'required_files': str(m['file_n']),
                'required_urls': str(m['url_n']),
                'unresolved_packages': '0', 'unresolved_files': '0',
                'failed_requests': str(m['failed_n']),
                'failed_requests_total': str(m['failed_n']),
                'failed_requests_blocking': '0',
                'failed_requests_non_blocking': str(m['failed_n']),
                'recovered_post_hop': 'true',
                'exported_at_utc': '2026-07-19T00:00:00Z',
                'relative_path': m['hop'],
            })
        _write_tsv(os.path.join(self.tmpdir, 'index.tsv'), index_fields, index_rows)

        # Temporarily relax expected constants for fixture sizes
        old = aud.EXPECTED_INDEX
        aud.EXPECTED_INDEX = aud.OrderedDict([
            (m['hop'], {
                'validation': 'PASS',
                'required_packages': m['pkg_n'],
                'required_files': m['file_n'],
                'required_urls': m['url_n'],
                'unresolved_packages': 0,
                'unresolved_files': 0,
                'failed_requests_total': m['failed_n'],
                'failed_requests_blocking': 0,
                'failed_requests_non_blocking': m['failed_n'],
                'recovered_post_hop': True,
            }) for m in meta
        ])
        try:
            out = os.path.join(self.tmpdir, 'analysis')
            rc = aud.analyze(self.tmpdir, out)
            self.assertEqual(rc, 0)
            with open(os.path.join(out, 'analysis-summary.json')) as fh:
                summary = json.load(fh)
            self.assertTrue(summary['index_expected_match'])
            self.assertEqual(summary['totals_raw']['required_packages'], 12)
            self.assertEqual(summary['hosts'].get('archive.ubuntu.com', 0) > 0, True)
            for name in (
                'all-required-packages.tsv', 'all-required-files.tsv',
                'all-required-urls.tsv', 'url-host-summary.tsv',
                'mirror-coverage.tsv', 'original-manifest-checksums.tsv',
            ):
                self.assertTrue(os.path.isfile(os.path.join(out, name)), name)
            # originals untouched: re-hash matches inventory
            with open(os.path.join(out, 'original-manifest-checksums.tsv')) as fh:
                inv = list(csv.DictReader(fh, delimiter='\t'))
            for row in inv:
                path = os.path.join(self.tmpdir, row['path'])
                self.assertEqual(aud.sha256_file(path), row['sha256'])
        finally:
            aud.EXPECTED_INDEX = old

    def test_real_artifacts_if_present(self):
        real = os.path.join(ROOT, 'artifacts', 'upgrade-discovery')
        if not os.path.isfile(os.path.join(real, 'index.tsv')):
            self.skipTest('real artifacts not present')
        out = os.path.join(self.tmpdir, 'real-analysis')
        rc = aud.analyze(real, out)
        self.assertEqual(rc, 0)
        with open(os.path.join(out, 'analysis-summary.json')) as fh:
            summary = json.load(fh)
        self.assertTrue(summary['index_expected_match'])
        self.assertEqual(summary['totals_raw']['required_packages'], 4621)
        self.assertEqual(summary['totals_raw']['required_urls'], 3750)
        self.assertEqual(summary['hosts'].get('archive.ubuntu.com'), 3695)
        self.assertEqual(summary['hosts'].get('security.ubuntu.com'), 55)
        self.assertNotIn('changelogs.ubuntu.com', summary['hosts'])
        self.assertNotIn('old-releases.ubuntu.com', summary['hosts'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
