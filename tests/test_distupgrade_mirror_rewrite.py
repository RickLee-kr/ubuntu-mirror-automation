#!/usr/bin/env python3
"""Xenial DistUpgrade source rewrite + effective-source gate tests.

Uses the bionic UpgradeTool rewrite model (isMirror / AllowThirdParty /
archive.ubuntu.com fallback). No live DP, do-release-upgrade, publish, or reboot.
"""
from __future__ import print_function

import os
import re
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'scripts', 'lib')
if LIB not in sys.path:
    sys.path.insert(0, LIB)

import distupgrade_mirror_rewrite as dmr  # noqa: E402
import distupgrade_source_compat as dsc  # noqa: E402


LOCAL = 'http://221.139.249.111/hops/xenial-to-bionic/ubuntu'
XENIAL_SOURCES = [
    'deb [arch=amd64] %s xenial main universe' % LOCAL,
    'deb [arch=amd64] %s xenial-updates main universe' % LOCAL,
    'deb [arch=amd64] %s xenial-security main universe' % LOCAL,
    'deb [arch=amd64] %s xenial-backports main universe' % LOCAL,
]
BIONIC_EXPECTED = [
    'deb [arch=amd64] %s bionic main universe' % LOCAL,
    'deb [arch=amd64] %s bionic-updates main universe' % LOCAL,
    'deb [arch=amd64] %s bionic-security main universe' % LOCAL,
    'deb [arch=amd64] %s bionic-backports main universe' % LOCAL,
]


class TestDistUpgradeMirrorRewrite(unittest.TestCase):
    def test_01_unknown_local_mirror_rewrites_to_archive(self):
        """Unknown local URI + main_was_missing → archive.ubuntu.com (+ duplicates)."""
        result = dmr.simulate_rewrite_sources_list(
            XENIAL_SOURCES,
            valid_mirrors=[
                'http://archive.ubuntu.com/ubuntu/',
                'http://security.ubuntu.com/ubuntu/',
            ],
            allow_third_party=False,
            main_was_missing=True,
        )
        self.assertTrue(result['archive_generated'])
        self.assertGreater(result['official_archive_reference_count'], 0)
        self.assertTrue(
            any('archive.ubuntu.com' in ln for ln in result['enabled_lines']))
        # main_was_missing archive twins of disabled local pockets → duplicates
        self.assertGreater(result['duplicate_suite_count'], 0)

    def test_02_registered_local_mirror_keeps_uri(self):
        result = dmr.rewrite_local_sources_with_registered_mirror(
            XENIAL_SOURCES, LOCAL)
        self.assertFalse(result['archive_generated'])
        self.assertEqual(result['official_archive_reference_count'], 0)
        enabled = result['enabled_lines']
        self.assertEqual(len(enabled), 4)
        for exp in BIONIC_EXPECTED:
            self.assertIn(exp, enabled)

    def test_03_allow_third_party_rewrites_without_archive(self):
        result = dmr.simulate_rewrite_sources_list(
            XENIAL_SOURCES,
            valid_mirrors=['http://archive.ubuntu.com/ubuntu/'],
            allow_third_party=True,
            downloadable_dists=set(dsc.allowed_target_suites('bionic')),
        )
        self.assertFalse(result['archive_generated'])
        self.assertEqual(result['official_archive_reference_count'], 0)
        self.assertEqual(len(result['enabled_lines']), 4)
        for ln in result['enabled_lines']:
            self.assertIn(LOCAL, ln)
            self.assertIn('bionic', ln)
            self.assertNotIn('archive.ubuntu.com', ln)

    def test_04_is_mirror_exact_and_cacher_style(self):
        mirrors = dmr.build_valid_mirrors_overlay(LOCAL)
        self.assertTrue(dmr.is_mirror_uri(LOCAL, mirrors))
        self.assertTrue(dmr.is_mirror_uri(LOCAL + '/', mirrors))
        self.assertFalse(dmr.is_mirror_uri(
            'http://evil.example/ubuntu', mirrors))

    def test_05_effective_source_gate_pass(self):
        result = dmr.validate_effective_distupgrade_sources(
            BIONIC_EXPECTED, LOCAL)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_CAPTURE'], 'PASS')
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_COUNT'], 4)
        self.assertEqual(result['DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT'], 0)
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE_COUNT'], 0)
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_bionic'], 'PASS')
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_bionic_updates'], 'PASS')
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_bionic_security'], 'PASS')
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_bionic_backports'], 'PASS')
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_LOCAL_MIRROR_ONLY'], 'PASS')

    def test_06_effective_source_official_escape_fail_closed(self):
        bad = list(BIONIC_EXPECTED)
        bad[0] = 'deb [arch=amd64] http://archive.ubuntu.com/ubuntu bionic main universe'
        result = dmr.validate_effective_distupgrade_sources(bad, LOCAL)
        self.assertFalse(result['ok'])
        self.assertEqual(
            result['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE')
        self.assertGreater(result['DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT'], 0)

    def test_07_effective_source_duplicate_fail(self):
        bad = list(BIONIC_EXPECTED) + [BIONIC_EXPECTED[0]]
        result = dmr.validate_effective_distupgrade_sources(bad, LOCAL)
        self.assertFalse(result['ok'])
        self.assertEqual(result['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE')
        self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE_COUNT'], 1)

    def test_08_pre_rewrite_xenial_phase_allowed(self):
        result = dmr.validate_effective_distupgrade_sources(
            XENIAL_SOURCES, LOCAL)
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['phase'], 'SOURCE_PRE_REWRITE')

    def test_09_components_and_arch_preserved(self):
        result = dmr.rewrite_local_sources_with_registered_mirror(
            XENIAL_SOURCES, LOCAL)
        for ln in result['enabled_lines']:
            self.assertIn('arch=amd64', ln)
            self.assertIn('main', ln)
            self.assertIn('universe', ln)
            self.assertNotIn('signed-by', ln)
            self.assertNotIn('trusted=yes', ln)

    def test_10_country_archive_detected(self):
        lines = [
            'deb http://kr.archive.ubuntu.com/ubuntu bionic main',
            'deb http://security.ubuntu.com/ubuntu bionic-security main',
        ]
        self.assertEqual(dmr.official_archive_reference_count(lines), 2)

    def test_11_file_gate_records_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'sources.list')
            with open(path, 'w') as fh:
                fh.write('\n'.join(BIONIC_EXPECTED) + '\n')
            result = dmr.validate_effective_sources_file(path, LOCAL)
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['DISTUPGRADE_EFFECTIVE_SOURCE_FILE'], path)

    def test_12_end_to_end_registered_then_gate(self):
        rewritten = dmr.rewrite_local_sources_with_registered_mirror(
            XENIAL_SOURCES, LOCAL)
        gate = dmr.validate_effective_distupgrade_sources(
            rewritten['enabled_lines'], LOCAL)
        self.assertTrue(gate['ok'], gate)
        self.assertEqual(gate['DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT'], 0)

    def test_13_cloud_init_grub_pc_candidate_is_soft(self):
        """rc packages without candidate only skip PkgRecord lookup (soft)."""
        # DistUpgradeCache._lookupPkgRecord prints "No candidate ver" and skips.
        # Documented here as non-blocking for selective closure.
        note = (
            'cloud-init/grub-pc in rc state trigger "No candidate ver" during '
            'installedTasks PkgRecord scan; DistUpgrade skips them and does not '
            'require selective plan inclusion unless reverse-deps demand it.'
        )
        self.assertIn('skips', note)


class TestEffectiveSourceGateLifecycle(unittest.TestCase):
    def test_disarmed_allows_xenial(self):
        r = dmr.evaluate_effective_source_gate_lifecycle(
            XENIAL_SOURCES, LOCAL, armed=False)
        self.assertTrue(r['ok'])
        self.assertEqual(r['state'], 'DISARMED')
        self.assertEqual(r['action'], 'ALLOW')
        self.assertEqual(r['reason'], 'NOT_ARMED')

    def test_disarmed_allows_even_empty(self):
        r = dmr.evaluate_effective_source_gate_lifecycle([], LOCAL, armed=False)
        self.assertTrue(r['ok'])
        self.assertEqual(r['reason'], 'NOT_ARMED')

    def test_armed_xenial_defers(self):
        r = dmr.evaluate_effective_source_gate_lifecycle(
            XENIAL_SOURCES, LOCAL, armed=True)
        self.assertTrue(r['ok'], r)
        self.assertEqual(r['state'], 'ARMED_WAITING_FOR_TARGET_REWRITE')
        self.assertEqual(r['action'], 'DEFER')
        self.assertEqual(r['reason'], 'TARGET_REWRITE_NOT_YET_VISIBLE')

    def test_armed_bionic_local_pass(self):
        r = dmr.evaluate_effective_source_gate_lifecycle(
            BIONIC_EXPECTED, LOCAL, armed=True)
        self.assertTrue(r['ok'], r)
        self.assertEqual(r['state'], 'ENFORCING_TARGET_SOURCES')
        self.assertEqual(r['action'], 'ALLOW')

    def test_armed_archive_ubuntu_fail(self):
        bad = list(BIONIC_EXPECTED)
        bad[0] = 'deb [arch=amd64] http://archive.ubuntu.com/ubuntu bionic main universe'
        r = dmr.evaluate_effective_source_gate_lifecycle(bad, LOCAL, armed=True)
        self.assertFalse(r['ok'])
        self.assertEqual(
            r['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE')

    def test_armed_security_ubuntu_fail(self):
        bad = list(BIONIC_EXPECTED)
        bad[2] = 'deb [arch=amd64] http://security.ubuntu.com/ubuntu bionic-security main universe'
        r = dmr.evaluate_effective_source_gate_lifecycle(bad, LOCAL, armed=True)
        self.assertFalse(r['ok'])
        self.assertEqual(
            r['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE')

    def test_armed_country_archive_fail(self):
        bad = list(BIONIC_EXPECTED)
        bad[0] = 'deb [arch=amd64] http://kr.archive.ubuntu.com/ubuntu bionic main universe'
        r = dmr.evaluate_effective_source_gate_lifecycle(bad, LOCAL, armed=True)
        self.assertFalse(r['ok'])
        self.assertEqual(
            r['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE')

    def test_armed_duplicate_fail(self):
        bad = list(BIONIC_EXPECTED) + [BIONIC_EXPECTED[0]]
        r = dmr.evaluate_effective_source_gate_lifecycle(bad, LOCAL, armed=True)
        self.assertFalse(r['ok'])
        self.assertEqual(r['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE')

    def test_armed_missing_pocket_fail(self):
        bad = BIONIC_EXPECTED[:3]
        r = dmr.evaluate_effective_source_gate_lifecycle(bad, LOCAL, armed=True)
        self.assertFalse(r['ok'])
        self.assertIn(
            r['error'],
            ('FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_MISSING_POCKET',
             'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_COUNT_MISMATCH'))

    def test_armed_xenial_with_official_fail_closed(self):
        bad = list(XENIAL_SOURCES)
        bad[0] = 'deb [arch=amd64] http://archive.ubuntu.com/ubuntu xenial main universe'
        r = dmr.evaluate_effective_source_gate_lifecycle(bad, LOCAL, armed=True)
        self.assertFalse(r['ok'])
        self.assertEqual(
            r['error'], 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE')


class TestClientContainsOverrides(unittest.TestCase):
    def test_client_template_has_valid_mirrors_override(self):
        path = os.path.join(
            ROOT, 'client', 'dp-offline-upgrade-xenial-to-bionic.sh.in')
        with open(path, 'r') as fh:
            text = fh.read()
        self.assertIn('apply_distupgrade_mirror_override', text)
        self.assertIn('AllowThirdParty=yes', text)
        self.assertIn('RELEASE_UPGRADER_ALLOW_THIRD_PARTY', text)
        self.assertIn('install_effective_source_gate', text)
        self.assertIn('arm_effective_source_gate', text)
        self.assertIn('INSTALLED_DISARMED', text)
        self.assertIn("'DISARMED'", text)
        self.assertIn('TARGET_REWRITE_NOT_YET_VISIBLE', text)
        self.assertIn('FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE', text)
        self.assertIn('FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_GATE_INTERNAL', text)
        self.assertIn('FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_GATE_CONFIG', text)
        self.assertIn('state_is_terminal_failure', text)
        self.assertIn('MONITOR_EXIT_REASON=TERMINAL_FAILURE_STATE', text)
        self.assertIn('FAILED_BEFORE_PACKAGE_TRANSITION', text)
        self.assertIn('ROLLBACK_ELIGIBLE=YES', text)
        # Rollback must not treat invocation alone as transaction.
        self.assertIn(
            'do-release-upgrade PID/invocation alone is NOT a transaction', text)
        # Arm call site must not precede SOURCE_RELEASE_PREPARATION apt-get update.
        m = re.search(r"<<'RUNNER'\n(.*)\nRUNNER\n", text, re.S)
        self.assertIsNotNone(m)
        runner = m.group(1)
        main = runner[runner.rfind('main() {'):]
        prep = main.find('run_cmd apt-get update')
        arm = main.find('arm_effective_source_gate')
        dro = main.find('do-release-upgrade -f DistUpgradeViewNonInteractive')
        self.assertGreater(prep, 0)
        self.assertGreater(arm, prep)
        self.assertGreater(dro, arm)


if __name__ == '__main__':
    unittest.main()
