#!/usr/bin/env python3
"""Fixture tests for Xenial→Bionic upgrade failure analysis tooling."""
from __future__ import print_function, unicode_literals

import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import OrderedDict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'lib'))

import xenial_bionic_upgrade_analysis as xba  # noqa: E402
import offline_upgrade_evidence_design as oed  # noqa: E402

FIXTURE_ROOT = os.path.join(
    ROOT, 'tests', 'fixtures', 'xenial-bionic-upgrade-analysis',
)


def write(path, content):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if isinstance(content, bytes):
        with open(path, 'wb') as fh:
            fh.write(content)
    else:
        with open(path, 'w') as fh:
            fh.write(content)


def write_packages(path, stanzas):
    body = ''
    for st in stanzas:
        for k, v in st.items():
            body += '%s: %s\n' % (k, v)
        body += '\n'
    write(path, body)
    with gzip.open(path + '.gz', 'wb') as fh:
        fh.write(body.encode('utf-8'))
    return body


def sha256_bytes(data):
    if not isinstance(data, bytes):
        data = data.encode('utf-8')
    return hashlib.sha256(data).hexdigest()


def make_release(path, suite, codename, components, files_meta):
    """files_meta: [(relpath, content_bytes)]"""
    lines = [
        'Origin: Ubuntu-Selective',
        'Label: Ubuntu-Selective',
        'Suite: %s' % suite,
        'Codename: %s' % codename,
        'Architectures: amd64',
        'Components: %s' % ' '.join(components),
        'Date: Tue, 21 Jul 2026 11:30:00 +0000',
        'Description: test',
        'SHA256:',
    ]
    for rel, content in files_meta:
        if not isinstance(content, bytes):
            content = content.encode('utf-8')
        lines.append(' %s %d %s' % (sha256_bytes(content), len(content), rel))
    write(path, '\n'.join(lines) + '\n')


class RepositorySemanticTests(unittest.TestCase):
    def test_empty_target_packages_fail(self):
        tmp = tempfile.mkdtemp(prefix='xb-empty-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            pkgs_path = os.path.join(
                ubuntu, 'dists/bionic-updates/main/binary-amd64/Packages',
            )
            body = write_packages(pkgs_path, [])  # empty
            with open(pkgs_path + '.gz', 'rb') as gzh:
                gz_bytes = gzh.read()
            make_release(
                os.path.join(ubuntu, 'dists/bionic-updates/Release'),
                'bionic-updates', 'bionic', ['main'],
                [('main/binary-amd64/Packages', body),
                 ('main/binary-amd64/Packages.gz', gz_bytes)],
            )
            row = xba.audit_suite_component(
                ubuntu, 'bionic-updates', 'main',
                from_series='xenial', to_series='bionic',
            )
            self.assertEqual(row['semantic_result'], xba.SEMANTIC_FAIL_EMPTY_TARGET)
            self.assertIn(xba.ERROR_TARGET_PACKAGES_INDEX_EMPTY, row['errors'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_empty_source_suite_ok(self):
        tmp = tempfile.mkdtemp(prefix='xb-src-empty-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            pkgs_path = os.path.join(
                ubuntu, 'dists/xenial/main/binary-amd64/Packages',
            )
            body = write_packages(pkgs_path, [])
            make_release(
                os.path.join(ubuntu, 'dists/xenial/Release'),
                'xenial', 'xenial', ['main'],
                [('main/binary-amd64/Packages', body)],
            )
            row = xba.audit_suite_component(
                ubuntu, 'xenial', 'main',
                from_series='xenial', to_series='bionic',
            )
            self.assertEqual(
                row['semantic_result'], xba.SEMANTIC_OK_EMPTY_SOURCE,
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_release_universe_missing_vs_plan(self):
        tmp = tempfile.mkdtemp(prefix='xb-univ-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            stanzas = [OrderedDict([
                ('Package', 'hello'),
                ('Version', '1.0'),
                ('Architecture', 'amd64'),
                ('Filename', 'pool/universe/h/hello/hello_1.0_amd64.deb'),
                ('Size', '4'),
                ('SHA256', sha256_bytes(b'deb\n')),
            ])]
            # Only main declared in Release, but universe Packages exists
            pkgs = os.path.join(
                ubuntu, 'dists/bionic/universe/binary-amd64/Packages',
            )
            body = write_packages(pkgs, stanzas)
            write(
                os.path.join(ubuntu, 'pool/universe/h/hello/hello_1.0_amd64.deb'),
                b'deb\n',
            )
            make_release(
                os.path.join(ubuntu, 'dists/bionic/Release'),
                'bionic', 'bionic', ['main'],  # universe NOT declared
                [('universe/binary-amd64/Packages', body)],
            )
            row = xba.audit_suite_component(
                ubuntu, 'bionic', 'universe',
                from_series='xenial', to_series='bionic',
            )
            self.assertFalse(row['release_component_declared'])
            self.assertIn(
                xba.ERROR_TARGET_COMPONENT_NOT_DECLARED, row['errors'],
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_missing_deb_payload(self):
        tmp = tempfile.mkdtemp(prefix='xb-missing-deb-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            stanzas = [OrderedDict([
                ('Package', 'foo'),
                ('Version', '1'),
                ('Architecture', 'amd64'),
                ('Filename', 'pool/main/f/foo/foo_1_amd64.deb'),
                ('Size', '3'),
                ('SHA256', sha256_bytes(b'abc')),
            ])]
            pkgs = os.path.join(
                ubuntu, 'dists/bionic/main/binary-amd64/Packages',
            )
            body = write_packages(pkgs, stanzas)
            make_release(
                os.path.join(ubuntu, 'dists/bionic/Release'),
                'bionic', 'bionic', ['main'],
                [('main/binary-amd64/Packages', body)],
            )
            row = xba.audit_suite_component(
                ubuntu, 'bionic', 'main',
                from_series='xenial', to_series='bionic',
            )
            self.assertEqual(row['missing_deb_count'], 1)
            self.assertEqual(row['semantic_result'], xba.SEMANTIC_FAIL_DEB)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class CoreAndKeepTests(unittest.TestCase):
    def test_systemd_candidate_missing_unexpected_core_keep(self):
        packages = OrderedDict()  # no systemd
        row = xba.classify_keep_package(
            'systemd', packages, installed_versions={'systemd': '229-4ubuntu21'},
        )
        self.assertEqual(row['classification'], 'H')
        self.assertEqual(row['severity'], 'CRITICAL')

    def test_udev_libudev_family_mismatch(self):
        tmp = tempfile.mkdtemp(prefix='xb-udev-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            stanzas = [
                OrderedDict([
                    ('Package', 'udev'),
                    ('Version', '237-3ubuntu10.57'),
                    ('Architecture', 'amd64'),
                    ('Filename', 'pool/main/s/systemd/udev_1_amd64.deb'),
                    ('Size', '3'),
                ]),
                OrderedDict([
                    ('Package', 'libudev1'),
                    ('Version', '229-4ubuntu21'),
                    ('Architecture', 'amd64'),
                    ('Filename', 'pool/main/s/systemd/libudev1_1_amd64.deb'),
                    ('Size', '3'),
                ]),
            ]
            pkgs = os.path.join(
                ubuntu, 'dists/bionic/main/binary-amd64/Packages',
            )
            write_packages(pkgs, stanzas)
            for st in stanzas:
                write(os.path.join(ubuntu, st['Filename']), b'abc')
            packages, _ = xba.load_suite_packages(
                ubuntu, ['bionic'], ['main'],
            )
            core = xba.analyze_core_packages(packages, ubuntu)
            self.assertIn(
                'udev_libudev1_version_family_mismatch', core['family_issues'],
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_kernel_image_without_modules(self):
        tmp = tempfile.mkdtemp(prefix='xb-kimg-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            stanzas = [OrderedDict([
                ('Package', 'linux-image-4.15.0-20-generic'),
                ('Version', '4.15.0-20.21'),
                ('Architecture', 'amd64'),
                ('Filename', 'pool/main/l/linux/linux-image-4.15.0-20-generic_1_amd64.deb'),
                ('Size', '3'),
            ])]
            pkgs = os.path.join(
                ubuntu, 'dists/bionic/main/binary-amd64/Packages',
            )
            write_packages(pkgs, stanzas)
            write(os.path.join(ubuntu, stanzas[0]['Filename']), b'abc')
            packages, _ = xba.load_suite_packages(ubuntu, ['bionic'], ['main'])
            core = xba.analyze_core_packages(packages, ubuntu)
            self.assertTrue(core['kernel_families'])
            self.assertEqual(
                core['kernel_families'][0]['severity'],
                'INCOMPLETE_KERNEL_FAMILY_MISSING_MODULES',
            )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_kernel_modules_without_extra_warning(self):
        tmp = tempfile.mkdtemp(prefix='xb-kmod-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            stanzas = [
                OrderedDict([
                    ('Package', 'linux-image-4.15.0-20-generic'),
                    ('Version', '4.15.0-20.21'),
                    ('Filename', 'pool/main/l/a.deb'),
                    ('Size', '3'),
                ]),
                OrderedDict([
                    ('Package', 'linux-modules-4.15.0-20-generic'),
                    ('Version', '4.15.0-20.21'),
                    ('Filename', 'pool/main/l/b.deb'),
                    ('Size', '3'),
                ]),
            ]
            pkgs = os.path.join(
                ubuntu, 'dists/bionic/main/binary-amd64/Packages',
            )
            write_packages(pkgs, stanzas)
            for st in stanzas:
                write(os.path.join(ubuntu, st['Filename']), b'abc')
            packages, _ = xba.load_suite_packages(ubuntu, ['bionic'], ['main'])
            core = xba.analyze_core_packages(packages, ubuntu)
            kf = core['kernel_families'][0]
            self.assertTrue(kf['modules_present'])
            self.assertFalse(kf['modules_extra_present'])
            # modules present → severity OK per current policy (extra is warn-level
            # via modules_extra_present flag for callers)
            self.assertEqual(kf['severity'], 'OK')
            self.assertFalse(kf['modules_extra_present'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_initramfs_dependency_missing(self):
        packages = OrderedDict([
            ('initramfs-tools', OrderedDict([
                ('Package', 'initramfs-tools'),
                ('Version', '0.130'),
                ('Depends', 'initramfs-tools-core, busybox-initramfs'),
            ])),
            ('initramfs-tools-core', OrderedDict([
                ('Package', 'initramfs-tools-core'),
                ('Version', '0.130'),
                ('Depends', 'klibc-utils'),
            ])),
        ])
        closure = xba.follow_dependency_closure(
            packages, ['initramfs-tools'], fields=('Depends',),
        )
        self.assertIn('busybox-initramfs', closure['missing_from_index'])
        self.assertIn('klibc-utils', closure['missing_from_index'])

    def test_third_party_keep_expected(self):
        row = xba.classify_keep_package(
            'aella-cm-master', OrderedDict(),
            installed_versions={'aella-cm-master': '6.5.0'},
        )
        self.assertEqual(row['classification'], 'A')
        self.assertEqual(row['severity'], 'EXPECTED')

    def test_simulation_core_keep_fails(self):
        packages = OrderedDict()  # empty mirror
        installed = OrderedDict([
            ('systemd', '229-4ubuntu21'),
            ('libc6', '2.23-0ubuntu11'),
        ])
        sim = xba.simulate_mirror_candidates(installed, packages)
        self.assertIn('systemd', sim['unexpected_kept_core_packages'])
        self.assertIn('libc6', sim['unexpected_kept_core_packages'])


class SourcesAndCompareTests(unittest.TestCase):
    def test_signed_by_invalidates_distupgrade_parser(self):
        line = (
            'deb [arch=amd64 signed-by=/etc/apt/keyrings/stellar-offline-upgrade.gpg] '
            'http://221.139.249.111/hops/xenial-to-bionic/ubuntu xenial-updates '
            'main universe'
        )
        parsed = xba.distupgrade_source_entry_valid(line)
        self.assertTrue(parsed['invalid'])
        self.assertIn('signed-by', parsed['rejected_options'])

        analysis = xba.analyze_client_sources_lines([
            'deb [arch=amd64 signed-by=/x.gpg] http://m/ubuntu xenial main universe',
            'deb [arch=amd64 signed-by=/x.gpg] http://m/ubuntu xenial-updates main universe',
            'deb [arch=amd64 signed-by=/x.gpg] http://m/ubuntu xenial-security main universe',
        ])
        self.assertEqual(analysis['valid_entry_count'], 0)
        self.assertEqual(
            analysis['verdict'], 'FAIL_SIGNED_BY_INVALIDATES_ALL_ENTRIES',
        )

    def test_found_components_parser(self):
        log = (
            "DEBUG:found components: "
            "{'bionic-updates': set(), 'bionic-security': set(), "
            "'bionic': {'main'}}\n"
        )
        fc = xba.parse_found_components(log)
        self.assertEqual(fc.get('bionic'), ['main'])
        self.assertEqual(fc.get('bionic-updates'), [])
        self.assertEqual(fc.get('bionic-security'), [])

    def test_keep_list_parser(self):
        log = (
            "DEBUG:Keep at same version: libc6 aella-cm-master systemd "
            "docker-ce\n"
        )
        keeps = xba.parse_keep_at_same_version(log)
        self.assertEqual(
            keeps, ['libc6', 'aella-cm-master', 'systemd', 'docker-ce'],
        )

    def test_internet_mirror_manifest_diff(self):
        tmp = tempfile.mkdtemp(prefix='xb-cmp-')
        try:
            i_dir = os.path.join(tmp, 'internet')
            m_dir = os.path.join(tmp, 'mirror')
            os.makedirs(i_dir)
            os.makedirs(m_dir)
            write(os.path.join(i_dir, 'dpkg-query.tsv'),
                  'package\tversion\tstatus\n'
                  'systemd\t237-3ubuntu10.57\tinstall ok installed\n'
                  'linux-image-4.15.0-213-generic\t4.15.0-213.224\tinstall ok installed\n'
                  'only-internet\t1\tinstall ok installed\n')
            write(os.path.join(m_dir, 'dpkg-query.tsv'),
                  'package\tversion\tstatus\n'
                  'systemd\t229-4ubuntu21\tinstall ok installed\n'
                  'linux-image-4.15.0-20-generic\t4.15.0-20.21\tinstall ok installed\n'
                  'only-mirror\t1\tinstall ok installed\n')
            write(os.path.join(i_dir, 'boot-listing.txt'),
                  'initrd.img-4.15.0-213-generic\n')
            write(os.path.join(m_dir, 'boot-listing.txt'),
                  'initrd.img-4.4.0-210-generic\n')
            report = xba.compare_evidence_bundles(i_dir, m_dir)
            self.assertIn('only-internet', report['package_only_in_internet'])
            self.assertIn('only-mirror', report['package_only_in_mirror'])
            self.assertTrue(any(
                r['package'] == 'systemd' for r in report['core_package_mismatch']
            ))
            self.assertTrue(report['kernel_mismatch'] or report['version_mismatch_count'] >= 1)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_same_package_different_version_diff(self):
        tmp = tempfile.mkdtemp(prefix='xb-ver-')
        try:
            i_dir = os.path.join(tmp, 'i')
            m_dir = os.path.join(tmp, 'm')
            os.makedirs(i_dir)
            os.makedirs(m_dir)
            write(os.path.join(i_dir, 'dpkg-query.tsv'),
                  'libc6\t2.27-3ubuntu1.6\tinstall ok installed\n')
            write(os.path.join(m_dir, 'dpkg-query.tsv'),
                  'libc6\t2.23-0ubuntu11\tinstall ok installed\n')
            report = xba.compare_evidence_bundles(i_dir, m_dir)
            self.assertEqual(report['version_mismatch_count'], 1)
            self.assertEqual(report['core_package_mismatch'][0]['package'], 'libc6')
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_deterministic_json(self):
        obj = OrderedDict([('b', 2), ('a', 1)])
        t1 = xba.dump_json(obj)
        t2 = xba.dump_json(obj)
        self.assertEqual(t1, t2)
        # sorted keys → a before b
        self.assertLess(t1.index('"a"'), t1.index('"b"'))


class CollectorAndEvidenceDesignTests(unittest.TestCase):
    def test_bash_43_collector_syntax(self):
        script = os.path.join(
            ROOT, 'scripts', 'collect-xenial-bionic-upgrade-baseline.sh',
        )
        # bash -n syntax check (host bash; script avoids 4.4+ only features)
        subprocess.check_call(['bash', '-n', script])

    def test_collector_fixture_bundle(self):
        """Run collector against a fake root-like temp layout via env?

        Collector reads live host paths; instead validate fixture evidence
        layout and that compare tool accepts collector-shaped files.
        """
        fix = os.path.join(FIXTURE_ROOT, 'evidence-internet')
        if not os.path.isdir(fix):
            self.skipTest('fixture not generated yet')
        self.assertTrue(os.path.isfile(os.path.join(fix, 'dpkg-query.tsv')))

    def test_evidence_design_missing_files(self):
        missing = oed.validate_manifest_dir(
            ['installed-packages.tsv'], phase='pre',
        )
        self.assertIn('sources.list', missing)
        self.assertNotIn('installed-packages.tsv', missing)

    def test_bionic_base_only_vs_updates_clone_detection(self):
        tmp = tempfile.mkdtemp(prefix='xb-clone-')
        try:
            ubuntu = os.path.join(tmp, 'ubuntu')
            stanzas = [OrderedDict([
                ('Package', 'libc6'),
                ('Version', '2.27-3ubuntu1.6'),
                ('Filename', 'pool/main/g/glibc/libc6_1_amd64.deb'),
                ('Size', '3'),
                ('SHA256', sha256_bytes(b'abc')),
            ])]
            body = None
            for suite in ('bionic', 'bionic-updates'):
                pkgs = os.path.join(
                    ubuntu, 'dists', suite, 'main/binary-amd64/Packages',
                )
                body = write_packages(pkgs, stanzas)
                write(os.path.join(ubuntu, stanzas[0]['Filename']), b'abc')
                make_release(
                    os.path.join(ubuntu, 'dists', suite, 'Release'),
                    suite, 'bionic', ['main'],
                    [('main/binary-amd64/Packages', body)],
                )
            report = xba.audit_repository(
                ubuntu,
                ['bionic', 'bionic-updates'],
                ['main'],
                from_series='xenial', to_series='bionic',
            )
            self.assertTrue(report['target_suite_indexes_identical'])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class LiveMirrorReadOnlySmoke(unittest.TestCase):
    """Optional smoke against live selective publish; skips if absent."""

    MIRROR = (
        '/var/spool/apt-mirror/selective/published/hops/'
        'xenial-to-bionic/ubuntu'
    )

    def test_live_mirror_audit_does_not_mutate(self):
        if not os.path.isdir(self.MIRROR):
            self.skipTest('live selective mirror not present')
        before = []
        sample = os.path.join(
            self.MIRROR, 'dists/bionic/main/binary-amd64/Packages',
        )
        if os.path.isfile(sample):
            before.append((sample, os.path.getmtime(sample), os.path.getsize(sample)))
        report = xba.audit_repository(
            self.MIRROR,
            ['xenial', 'bionic', 'bionic-updates', 'bionic-security'],
            ['main', 'universe'],
            from_series='xenial', to_series='bionic',
        )
        # Source empty OK; target non-empty on current publish
        by = {(r['suite'], r['component']): r for r in report['rows']}
        self.assertEqual(
            by[('xenial', 'main')]['semantic_result'],
            xba.SEMANTIC_OK_EMPTY_SOURCE,
        )
        self.assertGreater(by[('bionic', 'main')]['package_stanza_count'], 0)
        self.assertTrue(report['target_suite_indexes_identical'])
        if before:
            path, mtime, size = before[0]
            self.assertEqual(os.path.getmtime(path), mtime)
            self.assertEqual(os.path.getsize(path), size)


if __name__ == '__main__':
    unittest.main()
