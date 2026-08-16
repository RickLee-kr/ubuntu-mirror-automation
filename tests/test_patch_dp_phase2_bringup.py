#!/usr/bin/env python3
"""Deterministic Phase 2 bringup patcher: fresh upstream + project layer."""
from __future__ import print_function, unicode_literals

import os
import shutil
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
LIB = os.path.join(ROOT, 'scripts', 'lib')
sys.path.insert(0, LIB)

import patch_dp_phase2_bringup as patcher  # noqa: E402

FIXTURE = os.path.join(
    ROOT, 'tests', 'fixtures', 'dp-phase2', 'upstream_bringup_unpatched.sh',
)
VENDOR = os.path.join(
    ROOT, 'vendor', 'dp-phase2', 'bringup_py3_dp_after_os_upgrade.sh',
)
ENGINE = os.path.join(ROOT, 'scripts', 'lib', 'mirror_install_engine.sh')


class PatchGenerationTests(unittest.TestCase):
    def test_generation_is_stable_hex(self):
        a = patcher.patch_generation_id()
        b = patcher.patch_generation_id()
        self.assertEqual(a, b)
        self.assertEqual(len(a), 40)
        self.assertRegex(a, r'^[0-9a-f]{40}$')


class FreshUpstreamPatchTests(unittest.TestCase):
    def setUp(self):
        with open(FIXTURE, 'r', encoding='utf-8') as fh:
            self.upstream = fh.read()
        self.assertNotIn('--worker-password', self.upstream)

    def test_a_adds_worker_password(self):
        out, _applied = patcher.patch_bringup_text(self.upstream, emit=False)
        self.assertIn('--worker-password', out)
        self.assertIn('--worker-ips requires --worker-password', out)

    def test_b_preserves_new_upstream_vendor_marker(self):
        src = self.upstream.replace(
            'log "download_artifacts placeholder"',
            'log "download_artifacts placeholder"\n    NEW_UPSTREAM_VENDOR_FIX_MARKER=YES',
        )
        self.assertIn('NEW_UPSTREAM_VENDOR_FIX_MARKER=YES', src)
        out, _applied = patcher.patch_bringup_text(src, emit=False)
        self.assertIn('NEW_UPSTREAM_VENDOR_FIX_MARKER=YES', out)
        self.assertIn('--worker-password', out)
        self.assertIn('MASTER_TOKEN_API_READY', out)
        self.assertIn('APT_DEPENDENCY_CHECK', out)
        self.assertIn('CLUSTER_JOIN_STATE', out)

    def test_c_compatible_unrelated_drift_succeeds(self):
        src = self.upstream.replace(
            'log "download_artifacts placeholder"',
            'log "download_artifacts placeholder"\n    # UNRELATED_UPSTREAM_COMMENT',
        )
        out, _applied = patcher.patch_bringup_text(src, emit=False)
        self.assertIn('# UNRELATED_UPSTREAM_COMMENT', out)
        self.assertIn('wait_for_master_token_api', out)

    def test_d_incompatible_anchor_fails_closed(self):
        src = self.upstream.replace(
            '            --worker-ips)\n'
            '                WORKER_IPS="$2"; shift 2 ;;\n',
            '            --worker-ips)\n'
            '                WORKER_IPS="$2"; shift 2 ;;\n'
            '            --worker-ips-alt)\n'
            '                : ;;\n',
        )
        with self.assertRaises(patcher.PatchCompatError) as ctx:
            patcher.patch_bringup_text(src, emit=False)
        self.assertEqual(ctx.exception.transform, 'parse_args_worker_password_case')
        self.assertIn('anchor_count=0', ctx.exception.reason)

    def test_e_generated_is_not_frozen_vendor_copy(self):
        out, _applied = patcher.patch_bringup_text(self.upstream, emit=False)
        with open(VENDOR, 'r', encoding='utf-8') as fh:
            vendor = fh.read()
        self.assertNotEqual(out, vendor)
        with open(ENGINE, 'r', encoding='utf-8') as fh:
            engine = fh.read()
        self.assertNotIn(
            'cp -f "$patched" "$dest"',
            engine,
        )
        self.assertIn('BRINGUP_PATCH_MODEL=fresh_upstream_plus_project_layer', engine)

    def test_result_markers_and_syntax(self):
        tmp = tempfile.mkdtemp()
        try:
            dest = os.path.join(tmp, 'patched.sh')
            result = patcher.patch_bringup_file(FIXTURE, dest)
            self.assertNotEqual(result['patched_sha1'], result['upstream_sha1'])
            with open(dest, 'r', encoding='utf-8') as fh:
                text = fh.read()
            for marker in patcher.RESULT_MARKERS:
                self.assertIn(marker, text, marker)
            rc = os.system("bash -n %s" % dest)
            self.assertEqual(rc, 0)
        finally:
            shutil.rmtree(tmp)

    def test_does_not_modify_upstream_input(self):
        tmp = tempfile.mkdtemp()
        try:
            src = os.path.join(tmp, 'upstream.sh')
            dest = os.path.join(tmp, 'patched.sh')
            shutil.copy2(FIXTURE, src)
            with open(src, 'rb') as fh:
                before = fh.read()
            patcher.patch_bringup_file(src, dest)
            with open(src, 'rb') as fh2:
                after = fh2.read()
            self.assertEqual(before, after)
            with open(dest, 'rb') as fh3:
                self.assertNotEqual(fh3.read(), before)
        finally:
            shutil.rmtree(tmp)


if __name__ == '__main__':
    unittest.main()
