#!/usr/bin/env python3
"""Regression tests for Phase 2 Ubuntu dependency closure and transaction safety."""
from __future__ import print_function, unicode_literals

import json
import os
import shutil
import subprocess
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
            'extra_deb': [],
            'skip_acquire': True,
            'archive_base': 'http://127.0.0.1:1/ubuntu',
            'security_base': 'http://127.0.0.1:1/ubuntu',
        })())
        self.assertEqual(rc, 0)
        art = os.path.join(dest, p2p.ARTIFACT_NAME)
        self.assertTrue(os.path.isfile(art))
        self.assertTrue(os.path.isfile(art + '.sha256'))
        state = os.path.join(dest, p2p.STATE_NAME)
        self.assertTrue(os.path.isfile(state))
        text = open(state).read()
        self.assertIn('PHASE2_PREREQ_REQUIRED=YES', text)
        self.assertIn('PHASE2_PREREQ_BUILD=PASS', text)
        with tarfile.open(art, 'r:gz') as tf:
            names = tf.getnames()
        self.assertTrue(any(n.endswith('python3-click_1_all.deb') for n in names))
        self.assertFalse(any('python3-flask_' in n for n in names))
        self.assertIn(p2p.INSTALL_ORDER_NAME, names)
        with open(os.path.join(dest, p2p.MANIFEST_NAME)) as fh:
            manifest = json.loads(fh.read())
        order = manifest.get('install_order') or []
        self.assertIn('python3-colorama', order)
        self.assertIn('python3-click', order)
        self.assertLess(order.index('python3-colorama'), order.index('python3-click'))


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


class InstallPlanTests(unittest.TestCase):
    def test_deps_before_dependents(self):
        packages = OrderedDict([
            ('a', OrderedDict([('Package', 'a'), ('Depends', 'b')])),
            ('b', OrderedDict([('Package', 'b'), ('Depends', 'c')])),
            ('c', OrderedDict([('Package', 'c'), ('Depends', '')])),
        ])
        plan = p2p.build_install_plan(['a', 'b', 'c'], packages)
        order = plan['install_order']
        self.assertLess(order.index('c'), order.index('b'))
        self.assertLess(order.index('b'), order.index('a'))

    def test_shared_dependency_once(self):
        packages = OrderedDict([
            ('a', OrderedDict([('Package', 'a'), ('Depends', 'c')])),
            ('b', OrderedDict([('Package', 'b'), ('Depends', 'c')])),
            ('c', OrderedDict([('Package', 'c'), ('Depends', '')])),
        ])
        plan = p2p.build_install_plan(['a', 'b', 'c'], packages)
        self.assertEqual(plan['install_order'].count('c'), 1)
        self.assertEqual(plan['install_order'][0], 'c')

    def test_cycle_is_one_group(self):
        packages = OrderedDict([
            ('a', OrderedDict([('Package', 'a'), ('Depends', 'b')])),
            ('b', OrderedDict([('Package', 'b'), ('Depends', 'a')])),
            ('c', OrderedDict([('Package', 'c'), ('Depends', '')])),
        ])
        plan = p2p.build_install_plan(['a', 'b', 'c'], packages)
        groups = plan['install_groups']
        self.assertTrue(any(sorted(g) == ['a', 'b'] for g in groups))
        self.assertGreaterEqual(plan['cycle_group_count'], 1)
        self.assertEqual(plan['install_order'].count('a'), 1)
        self.assertEqual(plan['install_order'].count('b'), 1)

    def test_deterministic_across_runs(self):
        packages = OrderedDict([
            ('zpkg', OrderedDict([('Package', 'zpkg'), ('Depends', 'apkg')])),
            ('apkg', OrderedDict([('Package', 'apkg'), ('Depends', '')])),
            ('mpkg', OrderedDict([('Package', 'mpkg'), ('Depends', 'apkg')])),
        ])
        a = p2p.build_install_plan(['zpkg', 'mpkg', 'apkg'], packages)
        b = p2p.build_install_plan(['mpkg', 'apkg', 'zpkg'], packages)
        self.assertEqual(a['install_order'], b['install_order'])
        self.assertEqual(a['install_groups'], b['install_groups'])


class MissingDebFailClosedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='phase2-missing-deb-')
        self.ubuntu = os.path.join(self.tmp, 'ubuntu')
        self.acps = os.path.join(self.tmp, 'acps')
        os.makedirs(self.acps)
        rec = stanza('python3-click', 'python3-colorama', component='universe')
        rec2 = stanza('python3-colorama', component='universe')
        rec3 = stanza('python3-flask', 'python3-click', component='universe')
        write_packages_index(self.ubuntu, 'noble', 'universe', [rec, rec2, rec3])
        # Candidate exists; only colorama is materialized.
        for s in (rec2,):
            path = os.path.join(self.ubuntu, s['Filename'])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as fh:
                fh.write(b'deb-fixture\n')
        inner = os.path.join(self.tmp, 'py3-inner')
        os.makedirs(inner)
        deb = os.path.join(inner, 'python3-flask_1_all.deb')
        with open(deb, 'wb') as fh:
            fh.write(b'acps\n')
        with open(deb + '.control', 'w') as fh:
            fh.write('Package: python3-flask\nVersion: 1\nArchitecture: all\nDepends: python3-click\n')
        self.tarball = os.path.join(self.tmp, 'py3-apt-packages.tar.gz')
        with tarfile.open(self.tarball, 'w:gz') as tf:
            for fn in os.listdir(inner):
                tf.add(os.path.join(inner, fn), arcname=fn)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_missing_deb_does_not_omit_silently(self):
        dest = os.path.join(self.tmp, 'extras')
        rc = p2p.run_build(type('Args', (), {
            'source': self.tarball,
            'ubuntu_root': self.ubuntu,
            'dest': dest,
            'suites': None,
            'components': None,
            'allow_missing_candidate': False,
            'ensure_selective': False,
            'extra_deb': [],
            'skip_acquire': True,
            'archive_base': 'http://127.0.0.1:1/ubuntu',
            'security_base': 'http://127.0.0.1:1/ubuntu',
        })())
        self.assertNotEqual(rc, 0)
        state = os.path.join(dest, p2p.STATE_NAME)
        self.assertTrue(os.path.isfile(state))
        text = open(state).read()
        self.assertIn('PHASE2_PREREQ_BUILD=FAIL', text)
        self.assertIn('PHASE2_PREREQ_MISSING_DEB_PACKAGES=python3-click', text)
        art = os.path.join(dest, p2p.ARTIFACT_NAME)
        self.assertFalse(os.path.isfile(art))

    def test_zero_extra_is_not_required(self):
        inner = os.path.join(self.tmp, 'complete-inner')
        os.makedirs(inner)
        for name in ('python3-flask', 'python3-click', 'python3-colorama'):
            deb = os.path.join(inner, '%s_1_all.deb' % name)
            with open(deb, 'wb') as fh:
                fh.write(b'acps\n')
            depends = {
                'python3-flask': 'python3-click',
                'python3-click': 'python3-colorama',
                'python3-colorama': '',
            }[name]
            with open(deb + '.control', 'w') as fh:
                fh.write(
                    'Package: %s\nVersion: 1\nArchitecture: all\nDepends: %s\n' % (
                        name, depends,
                    )
                )
        tarball = os.path.join(self.tmp, 'complete.tar.gz')
        with tarfile.open(tarball, 'w:gz') as tf:
            for fn in os.listdir(inner):
                tf.add(os.path.join(inner, fn), arcname=fn)
        dest = os.path.join(self.tmp, 'zero-extras')
        rc = p2p.run_build(type('Args', (), {
            'source': tarball,
            'ubuntu_root': self.ubuntu,
            'dest': dest,
            'suites': None,
            'components': None,
            'allow_missing_candidate': False,
            'ensure_selective': False,
            'extra_deb': [],
            'skip_acquire': True,
            'archive_base': 'http://127.0.0.1:1/ubuntu',
            'security_base': 'http://127.0.0.1:1/ubuntu',
        })())
        self.assertEqual(rc, 0)
        text = open(os.path.join(dest, p2p.STATE_NAME)).read()
        self.assertIn('PHASE2_PREREQ_REQUIRED=NO', text)
        self.assertIn('PHASE2_PREREQ_PACKAGE_COUNT=0', text)
        self.assertIn('PHASE2_PREREQ_BUILD=PASS', text)


class PackageAcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='phase2-acquire-')
        self.ubuntu = os.path.join(self.tmp, 'ubuntu')
        self.http_root = os.path.join(self.tmp, 'http')
        os.makedirs(self.http_root)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _tiny_deb(self, path, package, version='1', depends=''):
        work = tempfile.mkdtemp(prefix='tiny-deb-')
        debian = os.path.join(work, 'DEBIAN')
        os.makedirs(debian)
        os.makedirs(os.path.join(work, 'usr', 'share', 'doc', package))
        with open(os.path.join(work, 'usr', 'share', 'doc', package, 'README'), 'w') as fh:
            fh.write('fixture\n')
        control = [
            'Package: %s' % package,
            'Version: %s' % version,
            'Architecture: all',
            'Maintainer: fixture@example.com',
            'Description: fixture %s' % package,
        ]
        if depends:
            control.append('Depends: %s' % depends)
        with open(os.path.join(debian, 'control'), 'w') as fh:
            fh.write('\n'.join(control) + '\n')
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.check_call(
            ['dpkg-deb', '-Zgzip', '--build', work, path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        shutil.rmtree(work, ignore_errors=True)

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

    def test_acquire_exact_package_and_reject_corrupt_checksum(self):
        pkg_rel = 'pool/universe/p/python3-needme/python3-needme_1_all.deb'
        http_deb = os.path.join(self.http_root, 'ubuntu', pkg_rel)
        self._tiny_deb(http_deb, 'python3-needme')
        digest = p2p.sha256_file(http_deb)
        size = os.path.getsize(http_deb)
        rec = OrderedDict([
            ('Package', 'python3-needme'),
            ('Version', '1'),
            ('Architecture', 'all'),
            ('Filename', pkg_rel),
            ('SHA256', digest),
            ('Size', str(size)),
            ('Depends', ''),
        ])
        write_packages_index(self.ubuntu, 'noble', 'universe', [rec])
        inner = os.path.join(self.tmp, 'py3-inner')
        os.makedirs(inner)
        root_deb = os.path.join(inner, 'python3-root_1_all.deb')
        with open(root_deb, 'wb') as fh:
            fh.write(b'acps\n')
        with open(root_deb + '.control', 'w') as fh:
            fh.write('Package: python3-root\nVersion: 1\nArchitecture: all\nDepends: python3-needme\n')
        tarball = os.path.join(self.tmp, 'py3-apt-packages.tar.gz')
        with tarfile.open(tarball, 'w:gz') as tf:
            for fn in os.listdir(inner):
                tf.add(os.path.join(inner, fn), arcname=fn)

        base = self._start_http() + '/ubuntu'
        dest = os.path.join(self.tmp, 'extras-ok')
        rc = p2p.run_build(type('Args', (), {
            'source': tarball,
            'ubuntu_root': self.ubuntu,
            'dest': dest,
            'suites': None,
            'components': None,
            'allow_missing_candidate': False,
            'ensure_selective': False,
            'extra_deb': [],
            'skip_acquire': False,
            'archive_base': base,
            'security_base': base,
        })())
        self.assertEqual(rc, 0, msg=open(os.path.join(dest, p2p.STATE_NAME)).read()
                         if os.path.isfile(os.path.join(dest, p2p.STATE_NAME)) else 'no state')
        local = os.path.join(self.ubuntu, pkg_rel)
        self.assertTrue(os.path.isfile(local))
        self.assertEqual(p2p.sha256_file(local), digest)
        art = os.path.join(dest, p2p.ARTIFACT_NAME)
        self.assertTrue(os.path.isfile(art))
        with tarfile.open(art, 'r:gz') as tf:
            self.assertTrue(any(n.endswith('python3-needme_1_all.deb') for n in tf.getnames()))

        # Corrupt checksum must fail closed and must not publish an artifact.
        rec_bad = OrderedDict(rec)
        rec_bad['SHA256'] = '0' * 64
        write_packages_index(self.ubuntu, 'noble', 'universe', [rec_bad])
        os.unlink(local)
        dest_bad = os.path.join(self.tmp, 'extras-bad')
        rc_bad = p2p.run_build(type('Args', (), {
            'source': tarball,
            'ubuntu_root': self.ubuntu,
            'dest': dest_bad,
            'suites': None,
            'components': None,
            'allow_missing_candidate': False,
            'ensure_selective': False,
            'extra_deb': [],
            'skip_acquire': False,
            'archive_base': base,
            'security_base': base,
        })())
        self.assertNotEqual(rc_bad, 0)
        self.assertFalse(os.path.isfile(os.path.join(dest_bad, p2p.ARTIFACT_NAME)))
        self.server.shutdown()
        self.server.server_close()


if __name__ == '__main__':
    unittest.main()
