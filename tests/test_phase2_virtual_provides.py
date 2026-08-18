#!/usr/bin/env python3
"""Focused tests for generic Debian Provides resolution in Phase 2.

Debian Policy 7.5: versioned Provides use ``(= version)``. That provided
version is what versioned Depends are evaluated against. Unversioned
Provides cannot satisfy a versioned virtual dependency; the provider
package's own Version field is never used as the virtual version.
"""
from __future__ import print_function, unicode_literals

import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from collections import OrderedDict
from contextlib import redirect_stderr

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
LIB = os.path.join(ROOT, 'scripts', 'lib')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LIB)

import phase2_ubuntu_prerequisites as p2p  # noqa: E402

from test_phase2_ubuntu_prerequisites import (  # noqa: E402
    build_args,
    write_packages_index,
)


def stanza(name, depends='', provides='', version='1', component='universe',
           suite='noble', filename=None, sha256=None, size=None,
           architecture='all', source='local_selective'):
    rec = OrderedDict([
        ('Package', name),
        ('Version', version),
        ('Architecture', architecture),
        ('Filename', filename or ('pool/%s/%s/%s_%s_%s.deb' % (
            component, name[:1], name, version, architecture,
        ))),
        ('Depends', depends),
        ('Provides', provides),
        ('_suite', suite),
        ('_component', component),
        ('_source', source),
    ])
    if sha256:
        rec['SHA256'] = sha256
    if size is not None:
        rec['Size'] = str(size)
    return rec


def write_tiny_deb_with_provides(
    path, package, version='1', depends='', provides='', architecture='all',
):
    work = tempfile.mkdtemp(prefix='tiny-deb-provides-')
    debian = os.path.join(work, 'DEBIAN')
    os.makedirs(debian)
    os.makedirs(os.path.join(work, 'usr', 'share', 'doc', package))
    with open(os.path.join(work, 'usr', 'share', 'doc', package, 'README'), 'w') as fh:
        fh.write('fixture\n')
    control = [
        'Package: %s' % package,
        'Version: %s' % version,
        'Architecture: %s' % architecture,
        'Maintainer: fixture@example.com',
        'Description: fixture %s' % package,
    ]
    if depends:
        control.append('Depends: %s' % depends)
    if provides:
        control.append('Provides: %s' % provides)
    with open(os.path.join(debian, 'control'), 'w') as fh:
        fh.write('\n'.join(control) + '\n')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    subprocess.check_call(
        ['dpkg-deb', '-Zgzip', '--build', work, path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    shutil.rmtree(work, ignore_errors=True)
    return path


def indexed_deb_with_provides(
    ubuntu_root, package, version='1', depends='', provides='',
    component='universe', architecture='all',
):
    rec = stanza(
        package, depends=depends, provides=provides, version=version,
        component=component, architecture=architecture,
    )
    rec.pop('_suite', None)
    rec.pop('_component', None)
    rec.pop('_source', None)
    path = os.path.join(ubuntu_root, rec['Filename'])
    write_tiny_deb_with_provides(
        path, package, version=version, depends=depends, provides=provides,
        architecture=architecture,
    )
    rec['SHA256'] = p2p.sha256_file(path)
    rec['Size'] = str(os.path.getsize(path))
    return rec


def write_acps_bundle(tmp, packages):
    """packages: list of (name, depends, provides)."""
    inner = os.path.join(tmp, 'py3-inner')
    if os.path.isdir(inner):
        shutil.rmtree(inner)
    os.makedirs(inner)
    for name, depends, provides in packages:
        deb = os.path.join(inner, '%s_1_all.deb' % name)
        with open(deb, 'wb') as fh:
            fh.write(b'acps\n')
        lines = [
            'Package: %s' % name,
            'Version: 1',
            'Architecture: all',
            'Depends: %s' % depends,
        ]
        if provides:
            lines.append('Provides: %s' % provides)
        with open(deb + '.control', 'w') as fh:
            fh.write('\n'.join(lines) + '\n')
    tarball = os.path.join(tmp, 'py3-apt-packages.tar.gz')
    with tarfile.open(tarball, 'w:gz') as tf:
        for fn in os.listdir(inner):
            tf.add(os.path.join(inner, fn), arcname=fn)
    return tarball


def extra_root(name, depends='', provides='', version='1'):
    return OrderedDict([
        (name, OrderedDict([
            ('Package', name),
            ('Version', version),
            ('Architecture', 'all'),
            ('Depends', depends),
            ('Provides', provides),
            ('_suite', 'acps'),
            ('_component', 'acps'),
            ('_source', 'acps_py3_apt_packages'),
        ])),
    ])


def resolve(root_depends, candidates, extra_provides='', on_missing=None):
    extra = extra_root('root', depends=root_depends, provides=extra_provides)
    return p2p.resolve_phase2_dependency_closure(
        ['root'], None, extra,
        candidate_index=candidates,
        on_missing_name=on_missing,
    )


def selected_names(closure):
    return list((closure.get('selected') or {}).keys())


class DirectPackageUnchangedTests(unittest.TestCase):
    def test_1_direct_real_package_dependency_unchanged(self):
        candidates = OrderedDict([
            ('foo', [stanza('foo', version='1.2')]),
        ])
        closure = resolve('foo (>= 1.0)', candidates)
        self.assertFalse(closure['constraint_failures'])
        self.assertNotIn('foo', closure['missing_from_index'])
        self.assertEqual(closure['selected']['foo']['Package'], 'foo')
        self.assertEqual(closure['selected']['foo']['Version'], '1.2')
        self.assertTrue(any(
            e.get('from') == 'root' and e.get('to') == 'foo'
            for e in (closure.get('edges_sample') or [])
        ))


class VirtualProvidesResolutionTests(unittest.TestCase):
    def test_2_unversioned_virtual_to_unversioned_provider(self):
        candidates = OrderedDict([
            ('real-provider', [stanza(
                'real-provider', provides='virtual-foo',
            )]),
        ])
        closure = resolve('virtual-foo', candidates)
        self.assertFalse(closure['constraint_failures'])
        self.assertNotIn('virtual-foo', closure['missing_from_index'])
        self.assertNotIn('virtual-foo', closure['selected'])
        self.assertEqual(closure['selected']['real-provider']['Package'], 'real-provider')
        self.assertTrue(any(
            e.get('to') == 'real-provider' for e in (closure.get('edges_sample') or [])
        ))

    def test_3_versioned_virtual_matches_versioned_provides(self):
        candidates = OrderedDict([
            ('real-provider', [stanza(
                'real-provider', version='1.2.3',
                provides='virtual-api (= 10495)',
            )]),
        ])
        closure = resolve('virtual-api (>= 9729)', candidates)
        self.assertFalse(closure['constraint_failures'])
        self.assertNotIn('virtual-api', closure['missing_from_index'])
        self.assertEqual(closure['selected']['real-provider']['Package'], 'real-provider')
        self.assertEqual(closure['selected']['real-provider']['Version'], '1.2.3')

    def test_4_versioned_virtual_provider_too_low_fail_closed(self):
        candidates = OrderedDict([
            ('real-provider', [stanza(
                'real-provider', version='9.9.9',
                provides='virtual-api (= 9729)',
            )]),
        ])
        closure = resolve('virtual-api (>= 10000)', candidates)
        self.assertTrue(closure['constraint_failures'])
        self.assertNotIn('virtual-api', closure['selected'])
        self.assertNotIn('real-provider', closure['selected'])
        expr = closure['constraint_failures'][0]['expression']
        self.assertIn('virtual-api (>= 10000)', expr)

    def test_5_versioned_dep_unversioned_provides_fail_closed(self):
        candidates = OrderedDict([
            ('real-provider', [stanza(
                'real-provider', version='9.9.9',
                provides='virtual-api',
            )]),
        ])
        closure = resolve('virtual-api (>= 10000)', candidates)
        self.assertTrue(closure['constraint_failures'])
        self.assertNotIn('virtual-api', closure['selected'])
        self.assertNotIn('real-provider', closure['selected'])

    def test_6_two_virtual_names_one_physical_provider(self):
        candidates = OrderedDict([
            ('python3-cffi-backend', [stanza(
                'python3-cffi-backend', version='1.16.0',
                provides=(
                    'python3-cffi-backend-api-max (= 10495), '
                    'python3-cffi-backend-api-min (= 9729)'
                ),
            )]),
        ])
        extra = extra_root(
            'python3-cryptography',
            depends=(
                'python3-cffi-backend-api-max (>= 9729), '
                'python3-cffi-backend-api-min (<= 9729)'
            ),
        )
        closure = p2p.resolve_phase2_dependency_closure(
            ['python3-cryptography'], None, extra, candidate_index=candidates,
        )
        self.assertFalse(closure['constraint_failures'])
        self.assertNotIn('python3-cffi-backend-api-max', closure['missing_from_index'])
        self.assertNotIn('python3-cffi-backend-api-min', closure['missing_from_index'])
        self.assertNotIn('python3-cffi-backend-api-max', closure['selected'])
        self.assertNotIn('python3-cffi-backend-api-min', closure['selected'])
        self.assertEqual(
            selected_names(closure).count('python3-cffi-backend'), 1,
        )
        targets = [
            e.get('to') for e in (closure.get('edges_sample') or [])
            if e.get('from') == 'python3-cryptography'
        ]
        self.assertEqual(targets.count('python3-cffi-backend'), 2)

    def test_7_alternative_virtual_fail_selects_real_fallback(self):
        candidates = OrderedDict([
            ('real-good', [stanza('real-good', version='1.0')]),
            ('bad-provider', [stanza(
                'bad-provider', provides='virtual-bad (= 1)',
            )]),
        ])
        closure = resolve('virtual-bad (>= 100) | real-good', candidates)
        self.assertFalse(closure['constraint_failures'])
        self.assertEqual(closure['selected']['real-good']['Package'], 'real-good')
        self.assertNotIn('bad-provider', closure['selected'])
        self.assertNotIn('virtual-bad', closure['selected'])

    def test_8_multiple_valid_providers_use_existing_pin_version_policy(self):
        candidates = OrderedDict([
            ('pkg-old', [stanza(
                'pkg-old', version='1.0', suite='noble',
                provides='virtual-foo (= 2)',
            )]),
            ('pkg-new', [stanza(
                'pkg-new', version='2.0', suite='noble',
                provides='virtual-foo (= 2)',
            )]),
            ('pkg-backports', [stanza(
                'pkg-backports', version='9.0', suite='noble-backports',
                provides='virtual-foo (= 2)',
            )]),
        ])
        closure = resolve('virtual-foo (>= 1)', candidates)
        self.assertFalse(closure['constraint_failures'])
        self.assertEqual(closure['selected']['pkg-new']['Package'], 'pkg-new')
        self.assertNotIn('pkg-old', closure['selected'])
        self.assertNotIn('pkg-backports', closure['selected'])

        security = OrderedDict([
            ('pkg-a', [stanza(
                'pkg-a', version='1.2.3', suite='noble',
                provides='virtual-foo',
            )]),
            ('pkg-b', [stanza(
                'pkg-b', version='1.2.3', suite='noble-security',
                provides='virtual-foo',
            )]),
        ])
        closure2 = resolve('virtual-foo', security)
        self.assertEqual(closure2['selected']['pkg-b']['_suite'], 'noble-security')
        self.assertNotIn('pkg-a', closure2['selected'])


class AuthoritativeAndLocalProviderTests(unittest.TestCase):
    def test_9_provider_from_authoritative_after_local_miss(self):
        calls = []
        loaded = {'done': False}
        local = OrderedDict()
        auth = OrderedDict([
            ('real-provider', [stanza(
                'real-provider', version='1.0',
                provides='virtual-foo (= 5)',
                source='authoritative_noble',
            )]),
        ])

        def on_missing(name, candidates):
            calls.append(name)
            if not loaded['done']:
                merged = p2p.merge_candidate_indexes(candidates, auth)
                candidates.clear()
                candidates.update(merged)
                loaded['done'] = True
            return bool(candidates.get(name))

        closure = resolve('virtual-foo (>= 2)', local, on_missing=on_missing)
        self.assertEqual(calls, ['virtual-foo'])
        self.assertFalse(closure['constraint_failures'])
        self.assertEqual(closure['selected']['real-provider']['Package'], 'real-provider')
        self.assertEqual(
            closure['selected']['real-provider'].get('_source'),
            'authoritative_noble',
        )

    def test_10_provider_already_in_local_selective_index(self):
        calls = []

        def on_missing(name, candidates):
            calls.append(name)
            return False

        candidates = OrderedDict([
            ('real-provider', [stanza(
                'real-provider', provides='virtual-foo',
                source='local_selective',
            )]),
        ])
        closure = resolve('virtual-foo', candidates, on_missing=on_missing)
        self.assertEqual(calls, [])
        self.assertFalse(closure['constraint_failures'])
        self.assertEqual(
            closure['selected']['real-provider'].get('_source'),
            'local_selective',
        )

    def test_local_satisfying_provider_not_hidden_by_authoritative(self):
        candidates = OrderedDict([
            ('real-provider', [
                stanza(
                    'real-provider', version='1.0',
                    provides='virtual-foo (= 5)',
                    source='local_selective',
                ),
                stanza(
                    'real-provider', version='9.0',
                    provides='virtual-foo (= 5)',
                    source='authoritative_noble',
                ),
            ]),
        ])
        closure = resolve('virtual-foo (>= 2)', candidates)
        self.assertFalse(closure['constraint_failures'])
        self.assertEqual(closure['selected']['real-provider']['Version'], '1.0')
        self.assertEqual(
            closure['selected']['real-provider'].get('_source'),
            'local_selective',
        )


class AcpsProvidesMetadataTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='phase2-acps-provides-')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_11_acps_root_deb_provides_retained_and_usable(self):
        deb = os.path.join(self.tmp, 'real-provider_1_all.deb')
        write_tiny_deb_with_provides(
            deb, 'real-provider', provides='virtual-foo (= 3)',
        )
        rec = p2p.inspect_one_deb(deb, source_label='acps_extra_deb')
        self.assertIn('virtual-foo', rec.get('provides') or '')
        extra = p2p.roots_as_index([rec])
        self.assertIn('Provides', extra['real-provider'])
        self.assertIn('virtual-foo', extra['real-provider']['Provides'])

        consumer = extra_root('consumer', depends='virtual-foo (>= 2)')
        extra.update(consumer)
        closure = p2p.resolve_phase2_dependency_closure(
            ['consumer', 'real-provider'], None, extra, candidate_index={},
        )
        self.assertFalse(closure['constraint_failures'])
        self.assertNotIn('virtual-foo', closure['missing_from_index'])
        unsat = p2p.unsatisfied_from_acps(
            closure, ['consumer', 'real-provider'],
        )
        self.assertNotIn('virtual-foo', unsat['unsatisfied'])
        self.assertNotIn('real-provider', unsat['unsatisfied'])

    def test_sidecar_provides_retained(self):
        tarball = write_acps_bundle(self.tmp, [
            ('consumer', 'virtual-foo', ''),
            ('real-provider', '', 'virtual-foo'),
        ])
        roots = p2p.inspect_acps_py3_apt_packages(tarball)
        by_name = {r['package']: r for r in roots}
        self.assertEqual(by_name['real-provider'].get('provides'), 'virtual-foo')
        extra = p2p.roots_as_index(roots)
        closure = p2p.resolve_phase2_dependency_closure(
            [r['package'] for r in roots], None, extra, candidate_index={},
        )
        self.assertFalse(closure['constraint_failures'])
        self.assertNotIn('virtual-foo', closure['missing_from_index'])


class ProductionCffiCaseTests(unittest.TestCase):
    def test_12_cffi_backend_api_min_max_resolve_to_one_provider(self):
        candidates = OrderedDict([
            ('python3-cffi-backend', [stanza(
                'python3-cffi-backend', version='1.16.0-2build1',
                provides=(
                    'python3-cffi-backend-api-max (= 10495), '
                    'python3-cffi-backend-api-min (= 9729)'
                ),
                component='main',
            )]),
        ])
        extra = extra_root(
            'python3-cryptography',
            depends=(
                'python3-cffi-backend-api-max (>= 9729), '
                'python3-cffi-backend-api-min (<= 9729)'
            ),
        )
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            closure = p2p.resolve_phase2_dependency_closure(
                ['python3-cryptography'], None, extra,
                candidate_index=candidates,
            )
        self.assertFalse(closure['constraint_failures'])
        self.assertFalse(closure['missing_from_index'])
        self.assertNotIn('python3-cffi-backend-api-max', closure['selected'])
        self.assertNotIn('python3-cffi-backend-api-min', closure['selected'])
        self.assertEqual(
            closure['selected']['python3-cffi-backend']['Package'],
            'python3-cffi-backend',
        )
        self.assertEqual(
            selected_names(closure).count('python3-cffi-backend'), 1,
        )
        unsat = p2p.unsatisfied_from_acps(closure, ['python3-cryptography'])
        self.assertEqual(unsat['unsatisfied'].count('python3-cffi-backend'), 1)
        self.assertNotIn('python3-cffi-backend-api-max', unsat['unsatisfied'])
        self.assertNotIn('python3-cffi-backend-api-min', unsat['unsatisfied'])
        collected = p2p.collect_artifact_packages(
            unsat['unsatisfied'],
            OrderedDict([
                ('python3-cffi-backend', closure['selected']['python3-cffi-backend']),
            ]),
        )
        names = [r.get('package') for r in collected['packages']]
        self.assertEqual(names, ['python3-cffi-backend'])
        self.assertNotIn(
            'python3-cffi-backend-api-max', collected['missing_candidate'],
        )
        self.assertNotIn(
            'python3-cffi-backend-api-min', collected['missing_candidate'],
        )
        log = stderr.getvalue()
        self.assertIn('PHASE2_PREREQ_VIRTUAL_PROVIDER=PASS', log)
        self.assertIn('virtual=python3-cffi-backend-api-max', log)
        self.assertIn('virtual=python3-cffi-backend-api-min', log)
        self.assertIn('provider=python3-cffi-backend', log)


class FoldedProvidesIndexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='phase2-folded-provides-')
        self.ubuntu = os.path.join(self.tmp, 'ubuntu')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_noble_folded_provides_preserved(self):
        path = os.path.join(
            self.ubuntu, 'dists', 'noble', 'main', 'binary-amd64', 'Packages',
        )
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(
                'Package: real-provider\n'
                'Version: 1.2.3\n'
                'Architecture: all\n'
                'Filename: pool/main/r/real-provider_1.2.3_all.deb\n'
                'SHA256: %s\n' % ('a' * 64)
                + 'Size: 12\n'
                'Provides: virtual-api-max (= 10495),\n'
                ' virtual-api-min (= 9729)\n'
                '\n'
            )
        by_name, _prov = p2p.load_all_package_candidates(self.ubuntu)
        provides = by_name['real-provider'][0].get('Provides') or ''
        self.assertIn('virtual-api-max', provides)
        self.assertIn('virtual-api-min', provides)
        extra = extra_root(
            'consumer',
            depends='virtual-api-max (>= 9729), virtual-api-min (<= 9729)',
        )
        closure = p2p.resolve_phase2_dependency_closure(
            ['consumer'], None, extra, candidate_index=by_name,
        )
        self.assertFalse(closure['constraint_failures'])
        self.assertEqual(
            closure['selected']['real-provider']['Package'], 'real-provider',
        )


class MissingDebAfterVirtualResolutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='phase2-virtual-missing-deb-')
        self.ubuntu = os.path.join(self.tmp, 'ubuntu')
        self.http_root = os.path.join(self.tmp, 'http')
        os.makedirs(self.http_root)
        self.tarball = write_acps_bundle(self.tmp, [
            ('python3-root', 'virtual-foo (>= 2)', ''),
        ])

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _start_http(self):
        import http.server
        import socketserver
        import threading

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                kwargs['directory'] = Handler.directory
                http.server.SimpleHTTPRequestHandler.__init__(self, *args, **kwargs)

            def log_message(self, *args):
                return

        Handler.directory = self.http_root

        class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        server = Server(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.daemon = True
        thread.start()
        self.server = server
        host, port = server.server_address
        return 'http://%s:%s' % (host, port)

    def test_closure_reaches_acquire_not_missing_candidate(self):
        rec = indexed_deb_with_provides(
            self.ubuntu, 'real-provider', version='1.0',
            provides='virtual-foo (= 5)', component='universe',
        )
        write_packages_index(self.ubuntu, 'noble', 'universe', [rec])
        os.unlink(os.path.join(self.ubuntu, rec['Filename']))
        dest = os.path.join(self.tmp, 'extras-skip-acquire')
        rc = p2p.run_build(build_args(
            source=self.tarball,
            ubuntu_root=self.ubuntu,
            dest=dest,
            skip_acquire=True,
        ))
        self.assertEqual(rc, 4)
        text = open(os.path.join(dest, p2p.STATE_NAME)).read()
        self.assertIn('PHASE2_PREREQ_BUILD=FAIL', text)
        self.assertIn('PHASE2_PREREQ_MISSING_DEB_PACKAGES=real-provider', text)
        self.assertNotIn('virtual-foo', text)
        self.assertIn('PHASE2_PREREQ_MISSING_CANDIDATE=0', text)
        self.assertFalse(os.path.isfile(os.path.join(dest, p2p.ARTIFACT_NAME)))

    def test_acquire_missing_debs_reached_and_succeeds(self):
        rec = indexed_deb_with_provides(
            self.http_root, 'real-provider', version='1.0',
            provides='virtual-foo (= 5)', component='universe',
        )
        write_packages_index(self.ubuntu, 'noble', 'universe', [rec])
        dest = os.path.join(self.tmp, 'extras-acquire')
        calls = []
        orig = p2p.acquire_missing_debs

        def wrapped(*args, **kwargs):
            calls.append(True)
            return orig(*args, **kwargs)

        p2p.acquire_missing_debs = wrapped
        base = self._start_http()
        try:
            rc = p2p.run_build(build_args(
                source=self.tarball,
                ubuntu_root=self.ubuntu,
                dest=dest,
                skip_acquire=False,
                skip_authoritative_fetch=True,
                archive_base=base,
                security_base=base,
            ))
        finally:
            p2p.acquire_missing_debs = orig
            self.server.shutdown()
            self.server.server_close()
        self.assertEqual(calls, [True])
        self.assertEqual(rc, 0, msg=open(os.path.join(dest, p2p.STATE_NAME)).read()
                         if os.path.isfile(os.path.join(dest, p2p.STATE_NAME)) else 'no state')
        text = open(os.path.join(dest, p2p.STATE_NAME)).read()
        self.assertIn('PHASE2_PREREQ_BUILD=PASS', text)
        self.assertIn('PHASE2_PREREQ_MISSING_CANDIDATE=0', text)
        art = os.path.join(dest, p2p.ARTIFACT_NAME)
        self.assertTrue(os.path.isfile(art))
        with tarfile.open(art, 'r:gz') as tf:
            names = tf.getnames()
        self.assertTrue(any('real-provider_1.0_all.deb' in n for n in names))
        self.assertFalse(any('virtual-foo' in n for n in names))
        with open(os.path.join(dest, p2p.MANIFEST_NAME)) as fh:
            import json
            manifest = json.loads(fh.read())
        packed = [p.get('package') for p in manifest.get('packages') or []]
        self.assertEqual(packed, ['real-provider'])


class InstallPlanVirtualProviderTests(unittest.TestCase):
    def test_install_plan_uses_real_provider_not_virtual_name(self):
        packages = OrderedDict([
            ('consumer', OrderedDict([
                ('Package', 'consumer'),
                ('Depends', 'virtual-foo (>= 2)'),
            ])),
            ('real-provider', OrderedDict([
                ('Package', 'real-provider'),
                ('Depends', ''),
                ('Provides', 'virtual-foo (= 5)'),
            ])),
        ])
        plan = p2p.build_install_plan(
            ['consumer', 'real-provider'], packages,
        )
        self.assertNotIn('virtual-foo', plan['install_order'])
        self.assertEqual(plan['install_order'].count('real-provider'), 1)
        self.assertLess(
            plan['install_order'].index('real-provider'),
            plan['install_order'].index('consumer'),
        )


class NoPackageSpecificWorkaroundTests(unittest.TestCase):
    def test_resolver_has_no_cffi_hardcode(self):
        src_path = os.path.join(LIB, 'phase2_ubuntu_prerequisites.py')
        with open(src_path) as fh:
            src = fh.read()
        self.assertNotIn(
            'python3-cffi-backend-api-min', src,
        )
        self.assertNotIn(
            'python3-cffi-backend-api-max', src,
        )


if __name__ == '__main__':
    unittest.main()
