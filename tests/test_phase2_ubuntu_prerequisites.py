#!/usr/bin/env python3
"""Regression tests for Phase 2 Ubuntu dependency closure and transaction safety."""
from __future__ import print_function, unicode_literals

import os
import shutil
import sys
import tarfile
import tempfile
import unittest
from collections import OrderedDict

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
LIB = os.path.join(ROOT, 'scripts', 'lib')
sys.path.insert(0, LIB)

import phase2_ubuntu_prerequisites as p2p  # noqa: E402
import xenial_bionic_upgrade_analysis as xba  # noqa: E402


def write_packages_index(ubuntu_root, suite, component, stanzas, arch='amd64'):
    path = os.path.join(
        ubuntu_root, 'dists', suite, component, 'binary-%s' % arch, 'Packages',
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        for stanza in stanzas:
            for key, val in stanza.items():
                if key.startswith('_'):
                    continue
                fh.write('%s: %s\n' % (key, val))
            fh.write('\n')
    return path


def stanza(name, depends='', pre_depends='', version='1', component='universe',
           suite='noble', filename=None):
    rec = OrderedDict([
        ('Package', name),
        ('Version', version),
        ('Architecture', 'all'),
        ('Filename', filename or ('pool/%s/%s/%s_%s_all.deb' % (
            component, name[:1], name, version,
        ))),
        ('Depends', depends),
        ('Pre-Depends', pre_depends),
    ])
    return rec


class FollowDependencyClosureReuseTests(unittest.TestCase):
    def test_default_first_alternative_unchanged(self):
        packages = OrderedDict([
            ('initramfs-tools', OrderedDict([
                ('Package', 'initramfs-tools'),
                ('Depends', 'busybox-initramfs | busybox, klibc-utils'),
            ])),
        ])
        closure = xba.follow_dependency_closure(
            packages, ['initramfs-tools'], fields=('Depends',),
        )
        self.assertIn('busybox-initramfs', closure['missing_from_index'])
        self.assertNotIn('busybox', closure['visited'])

    def test_prefer_available_selects_present_alternative(self):
        packages = OrderedDict([
            ('python3-flask', OrderedDict([
                ('Package', 'python3-flask'),
                ('Depends', 'python3-click | python3-click-default-group'),
            ])),
            ('python3-click-default-group', OrderedDict([
                ('Package', 'python3-click-default-group'),
            ])),
        ])
        closure = xba.follow_dependency_closure(
            packages, ['python3-flask'], fields=('Depends',),
            prefer_available=True,
        )
        self.assertIn('python3-click-default-group', closure['visited'])
        self.assertNotIn('python3-click', closure['missing_from_index'])


class Phase2ClosureIncidentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='phase2-prereq-')
        self.ubuntu = os.path.join(self.tmp, 'ubuntu')
        self.acps = os.path.join(self.tmp, 'acps')
        os.makedirs(self.acps)
        # Noble index contains the full universe/main closure, including
        # packages that the incident ACPS py3-apt bundle omitted.
        stanzas = [
            stanza('python3-flask', 'python3-click (>= 8.1.3), python3-werkzeug',
                   component='universe'),
            stanza('python3-werkzeug', 'libjs-jquery', component='universe'),
            stanza('python3-click', 'python3-colorama', component='universe'),
            stanza('python3-colorama', component='universe'),
            stanza('libjs-jquery', component='main'),
            stanza('python3-gevent',
                   'python3-zope.event, python3-zope.interface, libev4t64',
                   component='universe'),
            stanza('python3-zope.event', 'python3-zope.interface',
                   component='universe'),
            stanza('python3-zope.interface', component='universe'),
            stanza('libev4t64', component='universe'),
            stanza('python3-pyinotify', 'python3-pyasyncore',
                   component='universe'),
            stanza('python3-pyasyncore', component='universe'),
            stanza('python3-openssl', component='main'),
        ]
        write_packages_index(self.ubuntu, 'noble', 'universe',
                             [s for s in stanzas if 'universe' in s['Filename']])
        write_packages_index(self.ubuntu, 'noble', 'main',
                             [s for s in stanzas if '/main/' in s['Filename']])
        for s in stanzas:
            deb = os.path.join(self.ubuntu, s['Filename'])
            os.makedirs(os.path.dirname(deb), exist_ok=True)
            with open(deb, 'wb') as fh:
                fh.write(b'deb-fixture\n')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write_acps_bundle(self, packages):
        """ACPS py3-apt tarball with .deb + .control sidecars (no real debs)."""
        inner = os.path.join(self.tmp, 'py3-inner')
        os.makedirs(inner)
        for name, depends in packages:
            deb = os.path.join(inner, '%s_1_all.deb' % name)
            with open(deb, 'wb') as fh:
                fh.write(b'acps\n')
            with open(deb + '.control', 'w') as fh:
                fh.write('Package: %s\nVersion: 1\nArchitecture: all\nDepends: %s\n' % (
                    name, depends,
                ))
        tarball = os.path.join(self.tmp, 'py3-apt-packages.tar.gz')
        with tarfile.open(tarball, 'w:gz') as tf:
            for fn in os.listdir(inner):
                tf.add(os.path.join(inner, fn), arcname=fn)
        return tarball

    def test_resolver_discovers_click_and_transitive_deps(self):
        # Incident fixture: ACPS ships flask+werkzeug but omits click.
        tarball = self._write_acps_bundle([
            ('python3-flask', 'python3-click (>= 8.1.3), python3-werkzeug'),
            ('python3-werkzeug', 'libjs-jquery'),
        ])
        roots = p2p.inspect_acps_py3_apt_packages(tarball)
        root_names = [r['package'] for r in roots]
        self.assertEqual(sorted(root_names), ['python3-flask', 'python3-werkzeug'])
        packages, _ = p2p.load_noble_packages(self.ubuntu)
        extra = p2p.roots_as_index(roots)
        closure = p2p.resolve_phase2_dependency_closure(root_names, packages, extra)
        visited = set(closure['visited'])
        # Must be discovered by recursion, not a static allow-list in the
        # resolver. The ACPS bundle itself did not contain these names.
        self.assertIn('python3-click', visited)
        self.assertIn('python3-colorama', visited)
        self.assertIn('libjs-jquery', visited)
        self.assertNotIn('python3-click', root_names)
        edges = closure.get('edges_sample') or []
        self.assertTrue(any(
            e.get('from') == 'python3-flask' and e.get('to') == 'python3-click'
            for e in edges
        ), msg='flask -> click edge missing: %r' % edges)
        unsat = p2p.unsatisfied_from_acps(closure, root_names)
        self.assertIn('python3-click', unsat['unsatisfied'])
        self.assertIn('python3-colorama', unsat['unsatisfied'])

    def test_gevent_and_pyinotify_branches(self):
        tarball = self._write_acps_bundle([
            ('python3-gevent',
             'python3-zope.event, python3-zope.interface, libev4t64'),
            ('python3-pyinotify', 'python3-pyasyncore'),
        ])
        roots = p2p.inspect_acps_py3_apt_packages(tarball)
        root_names = [r['package'] for r in roots]
        packages, _ = p2p.load_noble_packages(self.ubuntu)
        closure = p2p.resolve_phase2_dependency_closure(
            root_names, packages, p2p.roots_as_index(roots),
        )
        visited = set(closure['visited'])
        for name in (
            'python3-zope.event', 'python3-zope.interface', 'libev4t64',
            'python3-pyasyncore',
        ):
            self.assertIn(name, visited)
        unsat = p2p.unsatisfied_from_acps(closure, root_names)
        for name in (
            'python3-zope.event', 'python3-zope.interface', 'libev4t64',
            'python3-pyasyncore',
        ):
            self.assertIn(name, unsat['unsatisfied'])

    def test_missing_candidate_is_reported(self):
        tarball = self._write_acps_bundle([
            ('python3-flask', 'python3-missing-dep'),
        ])
        roots = p2p.inspect_acps_py3_apt_packages(tarball)
        packages, _ = p2p.load_noble_packages(self.ubuntu)
        closure = p2p.resolve_phase2_dependency_closure(
            [r['package'] for r in roots], packages, p2p.roots_as_index(roots),
        )
        self.assertIn('python3-missing-dep', closure['missing_from_index'])

    def test_aella_package_roots_discover_openssl(self):
        # Incident: aella-da-cli / aella-da-services / aella-uvp-2404
        # Depends: python3-openssl, which is not in the ACPS py3-apt bundle.
        tarball = self._write_acps_bundle([
            ('python3-flask', 'python3-click (>= 8.1.3), python3-werkzeug'),
            ('python3-werkzeug', 'libjs-jquery'),
        ])
        extra_dir = os.path.join(self.tmp, 'extra-debs')
        os.makedirs(extra_dir)
        extras = []
        for name in ('aella-da-cli', 'aella-da-services', 'aella-uvp-2404'):
            deb = os.path.join(extra_dir, '%s_6.5.0_amd64.deb' % name)
            with open(deb, 'wb') as fh:
                fh.write(b'aella\n')
            with open(deb + '.control', 'w') as fh:
                fh.write(
                    'Package: %s\nVersion: 6.5.0\nArchitecture: amd64\n'
                    'Depends: python3-openssl\n' % name
                )
            extras.append(deb)
        roots = p2p.collect_phase2_roots(tarball, extra_debs=extras)
        root_names = [r['package'] for r in roots]
        for name in ('aella-da-cli', 'aella-da-services', 'aella-uvp-2404'):
            self.assertIn(name, root_names)
        packages, _ = p2p.load_noble_packages(self.ubuntu)
        closure = p2p.resolve_phase2_dependency_closure(
            root_names, packages, p2p.roots_as_index(roots),
        )
        visited = set(closure['visited'])
        self.assertIn('python3-openssl', visited)
        edges = closure.get('edges_sample') or []
        self.assertTrue(any(
            e.get('from') == 'aella-uvp-2404' and e.get('to') == 'python3-openssl'
            for e in edges
        ), msg='uvp -> openssl edge missing: %r' % edges)
        unsat = p2p.unsatisfied_from_acps(closure, root_names)
        self.assertIn('python3-openssl', unsat['unsatisfied'])
        self.assertNotIn('aella-uvp-2404', unsat['unsatisfied'])

    def test_build_artifact_excludes_acps_roots(self):
        tarball = self._write_acps_bundle([
            ('python3-flask', 'python3-click (>= 8.1.3), python3-werkzeug'),
            ('python3-werkzeug', 'libjs-jquery'),
        ])
        dest = os.path.join(self.tmp, 'extras')
        rc = p2p.run_build(type('Args', (), {
            'source': tarball,
            'ubuntu_root': self.ubuntu,
            'dest': dest,
            'suites': None,
            'components': None,
            'allow_missing_candidate': False,
            'ensure_selective': False,
        })())
        self.assertEqual(rc, 0)
        art = os.path.join(dest, p2p.ARTIFACT_NAME)
        self.assertTrue(os.path.isfile(art))
        self.assertTrue(os.path.isfile(art + '.sha256'))
        with tarfile.open(art, 'r:gz') as tf:
            names = tf.getnames()
        self.assertTrue(any(n.endswith('python3-click_1_all.deb') for n in names))
        self.assertFalse(any('python3-flask_' in n for n in names))


class TransactionSafetyTests(unittest.TestCase):
    def test_rejects_protected_removals(self):
        sim = (
            "Inst python3-click [8.1.3]\n"
            "Remv python3-gevent [24.2.1]\n"
            "Remv python3-kazoo [2.9.0]\n"
            "Purg python3-pyinotify [0.9.6]\n"
        )
        result = p2p.transaction_is_safe(sim)
        self.assertFalse(result['safe'])
        self.assertIn('python3-gevent', result['blocked_removals'])
        self.assertIn('python3-kazoo', result['blocked_removals'])
        self.assertIn('python3-pyinotify', result['blocked_removals'])

    def test_rejects_protected_aella_packages(self):
        sim = "Remv aella-da-services [6.5.0]\nRemv aella-uvp-2404 [6.5.0]\n"
        result = p2p.transaction_is_safe(sim)
        self.assertFalse(result['safe'])
        self.assertIn('aella-da-services', result['blocked_removals'])

    def test_accepts_install_only(self):
        sim = "Inst python3-click [8.1.3]\nInst python3-colorama [0.4.6]\n"
        result = p2p.transaction_is_safe(sim)
        self.assertTrue(result['safe'])
        self.assertEqual(result['blocked_removals'], [])


if __name__ == '__main__':
    unittest.main()
