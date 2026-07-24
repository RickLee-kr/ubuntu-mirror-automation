#!/usr/bin/env python3
"""Xenial→Bionic DistUpgrade source rewrite model + effective-source gate.

Faithfully models bionic UpgradeTool DistUpgradeController.rewriteSourcesList
mirror classification (isMirror / AllowThirdParty / unknown→archive.ubuntu.com)
without invoking do-release-upgrade or touching a live DP.
"""
from __future__ import print_function

import os
import re
from collections import OrderedDict, Counter

try:
    from distupgrade_source_compat import (
        distupgrade_source_entry_valid,
        allowed_target_suites,
        line_has_forbidden_auth,
    )
except ImportError:
    from scripts.lib.distupgrade_source_compat import (  # type: ignore
        distupgrade_source_entry_valid,
        allowed_target_suites,
        line_has_forbidden_auth,
    )


OFFICIAL_ARCHIVE_HOST_RE = re.compile(
    r'(?:^|://)'
    r'(?:'
    r'(?:[a-z]{2}\.)?archive\.ubuntu\.com|'
    r'security\.ubuntu\.com|'
    r'ports\.ubuntu\.com|'
    r'old-releases\.ubuntu\.com'
    r')'
    r'(?:[:/]|$)',
    re.I,
)

DEFAULT_POCKETS = ('security', 'updates', 'proposed', 'backports')


def uri_rstrip(uri):
    return (uri or '').rstrip('/')


def is_mirror_uri(uri, valid_mirrors):
    """Replicate DistUpgradeController.isMirror + sourceslist.is_mirror."""
    raw = uri_rstrip(uri)
    if not raw:
        return False
    # strip userinfo
    if '://' in raw:
        scheme, rest = raw.split('://', 1)
        if '@' in rest.split('/', 1)[0]:
            hostpath = rest.split('@', 1)[1]
            raw = '%s://%s' % (scheme, hostpath)
    for mirror in valid_mirrors or []:
        mirror = uri_rstrip(mirror)
        if not mirror or mirror.startswith('#'):
            continue
        if raw == mirror:
            return True
        # country-mirror style (de.archive.ubuntu.com vs archive.ubuntu.com)
        try:
            compare_srv = raw.split('//', 1)[1]
            master_srv = mirror.split('//', 1)[1]
        except IndexError:
            continue
        if '.' in compare_srv and compare_srv[compare_srv.index('.') + 1:] == master_srv:
            return True
        # apt-cacher / apt-torrent style (uri ends with mirror host path)
        try:
            mirror_host_part = mirror.split('//', 1)[1]
        except IndexError:
            continue
        if raw.endswith(mirror_host_part):
            return True
    return False


def official_archive_reference_count(lines):
    n = 0
    for line in lines or []:
        s = (line or '').strip()
        if not s or s.startswith('#'):
            continue
        if OFFICIAL_ARCHIVE_HOST_RE.search(s):
            n += 1
    return n


def _entry_line(parsed):
    opts = []
    if parsed.get('architectures'):
        opts.append('arch=' + ','.join(parsed['architectures']))
    prefix = 'deb'
    if opts:
        prefix = 'deb [%s]' % ' '.join(opts)
    comps = ' '.join(parsed.get('comps') or [])
    return '%s %s %s %s' % (prefix, parsed['uri'], parsed['dist'], comps)


def simulate_rewrite_sources_list(
        source_lines,
        from_dist='xenial',
        to_dist='bionic',
        valid_mirrors=None,
        allow_third_party=False,
        pockets=None,
        downloadable_dists=None,
        noninteractive_rewrite_anyway=True,
        generate_default_on_failure=True,
        main_was_missing=False):
    """Simulate DistUpgradeController.rewriteSourcesList + updateSourcesList fallback.

    downloadable_dists: set of suite names the local URI can serve (for
    _sourcesListEntryDownloadable). None means all target suites are downloadable.

    main_was_missing: when True and mirror_check is on, unknown mirrors cause
    DistUpgrade to add archive.ubuntu.com counterparts (duplicate risk).
    """
    pockets = list(pockets or DEFAULT_POCKETS)
    valid_mirrors = list(valid_mirrors or [])
    from_dists = [from_dist] + ['%s-%s' % (from_dist, p) for p in pockets]
    to_dists = [to_dist] + ['%s-%s' % (to_dist, p) for p in pockets]
    if downloadable_dists is None:
        downloadable_dists = set(to_dists)

    entries = []
    for line in source_lines or []:
        raw = (line or '').rstrip('\n')
        if not raw.strip() or raw.strip().startswith('#'):
            continue
        parsed = distupgrade_source_entry_valid(raw)
        if parsed['invalid']:
            continue
        entries.append(OrderedDict([
            ('type', parsed['type']),
            ('uri', parsed['uri']),
            ('dist', parsed['dist']),
            ('comps', list(parsed['comps'])),
            ('architectures', list(parsed.get('architectures') or [])),
            ('disabled', bool(parsed.get('disabled'))),
            ('comment', ''),
        ]))

    def _run(mirror_check, seed_entries=None):
        found_to = False
        uri_results = {}
        out = []
        work = [OrderedDict(e) for e in (seed_entries if seed_entries is not None else entries)]
        # main_was_missing + NoDistroTemplateException last resort (only when mirror_check)
        if mirror_check and main_was_missing:
            for dist, comps in (
                (to_dist, ['main', 'restricted']),
                ('%s-updates' % to_dist, ['main', 'restricted']),
                ('%s-security' % to_dist, ['main', 'restricted']),
            ):
                work.append(OrderedDict([
                    ('type', 'deb'),
                    ('uri', 'http://archive.ubuntu.com/ubuntu'
                     if 'security' not in dist else 'http://security.ubuntu.com/ubuntu'),
                    ('dist', dist if 'security' not in dist else '%s-security' % to_dist),
                    ('comps', list(comps)),
                    ('architectures', []),
                    ('disabled', False),
                    ('comment', 'auto generated by ubuntu-release-upgrader'),
                ]))
            # Fix security uri/dist for the third seed
            work[-1]['uri'] = 'http://security.ubuntu.com/ubuntu'
            work[-1]['dist'] = '%s-security' % to_dist

        for entry in work:
            if entry['disabled']:
                out.append(entry)
                continue
            uri = entry['uri']
            if uri not in uri_results:
                uri_results[uri] = 'unknown'
            valid_mirror = is_mirror_uri(uri, valid_mirrors)
            third_party = (not mirror_check)
            if valid_mirror or third_party:
                valid_to = True
                if (entry['type'] == 'deb-src'
                        or '/security.ubuntu.com' in uri
                        or '%s-security' % from_dist in entry['dist']
                        or '%s-backports' % from_dist in entry['dist']
                        or '%s-security' % to_dist in entry['dist']
                        or '%s-backports' % to_dist in entry['dist']):
                    valid_to = False
                if entry['dist'] in to_dists:
                    found_to = found_to or valid_to
                elif entry['dist'] in from_dists:
                    if uri_results[uri] == 'unknown':
                        if to_dist not in downloadable_dists:
                            uri_results[uri] = 'failed'
                        else:
                            uri_results[uri] = 'passed'
                    if uri_results[uri] == 'failed':
                        entry['disabled'] = True
                        entry['comment'] = 'disabled (no Release file)'
                    else:
                        found_to = found_to or valid_to
                        idx = from_dists.index(entry['dist'])
                        entry['dist'] = to_dists[idx]
                elif valid_mirror:
                    # already on toDist from seed, or unknown dist
                    if entry['dist'] not in to_dists:
                        entry['disabled'] = True
                        entry['comment'] = 'disabled (unknown dist)'
                out.append(entry)
            else:
                # unknown mirror — disable; with main_was_missing add archive twin
                orig_dist = entry['dist']
                if entry['dist'] == from_dist:
                    entry['dist'] = to_dist
                elif entry['dist'] in from_dists:
                    entry['dist'] = to_dists[from_dists.index(entry['dist'])]
                entry['disabled'] = True
                entry['comment'] = 'disabled on upgrade to %s' % to_dist
                out.append(entry)
                if mirror_check and main_was_missing and entry['dist'] in to_dists:
                    out.append(OrderedDict([
                        ('type', entry['type']),
                        ('uri', 'http://archive.ubuntu.com/ubuntu'),
                        ('dist', entry['dist']),
                        ('comps', list(entry['comps'])),
                        ('architectures', list(entry.get('architectures') or [])),
                        ('disabled', False),
                        ('comment', 'auto generated by ubuntu-release-upgrader'),
                    ]))
                    if entry['dist'] == to_dist or entry['dist'].endswith('-updates'):
                        found_to = True
                del orig_dist
        return found_to, out

    mirror_check = True
    if allow_third_party:
        mirror_check = False
    # AllowThirdParty skips the main_was_missing block in real DistUpgrade.
    effective_main_missing = main_was_missing if mirror_check else False
    # monkey-patch local for _run closure
    main_was_missing = effective_main_missing

    found, rewritten = _run(mirror_check)
    path = 'rewrite_mirror_check_%s' % ('off' if not mirror_check else 'on')
    archive_generated = any(
        'archive.ubuntu.com' in e.get('uri', '') or 'security.ubuntu.com' in e.get('uri', '')
        for e in rewritten if not e.get('disabled'))

    if not found and noninteractive_rewrite_anyway:
        # updateSourcesList second pass: reload originals, mirror_check=False
        found, rewritten = _run(False, seed_entries=entries)
        path = 'rewrite_allow_third_party_pass'
        archive_generated = any(
            'archive.ubuntu.com' in e.get('uri', '') or 'security.ubuntu.com' in e.get('uri', '')
            for e in rewritten if not e.get('disabled'))
        if not found and generate_default_on_failure:
            comps = ['main', 'restricted']
            rewritten = [
                OrderedDict([
                    ('type', 'deb'), ('uri', 'http://archive.ubuntu.com/ubuntu'),
                    ('dist', to_dist), ('comps', list(comps)),
                    ('architectures', []), ('disabled', False), ('comment', 'default'),
                ]),
                OrderedDict([
                    ('type', 'deb'), ('uri', 'http://archive.ubuntu.com/ubuntu'),
                    ('dist', '%s-updates' % to_dist), ('comps', list(comps)),
                    ('architectures', []), ('disabled', False), ('comment', 'default'),
                ]),
                OrderedDict([
                    ('type', 'deb'), ('uri', 'http://security.ubuntu.com/ubuntu/'),
                    ('dist', '%s-security' % to_dist), ('comps', list(comps)),
                    ('architectures', []), ('disabled', False), ('comment', 'default'),
                ]),
            ]
            archive_generated = True
            path = 'generate_default_archive_ubuntu_com'
            found = True

    lines = []
    for e in rewritten:
        if e.get('disabled'):
            lines.append('# %s %s' % (_entry_line(e), e.get('comment') or ''))
        else:
            lines.append(_entry_line(e))

    enabled = [ln for ln in lines if not ln.lstrip().startswith('#')]
    return OrderedDict([
        ('found_to_dist', bool(found)),
        ('archive_generated', archive_generated),
        ('path', path),
        ('lines', lines),
        ('enabled_lines', enabled),
        ('official_archive_reference_count',
         official_archive_reference_count(enabled)),
        ('duplicate_suite_count',
         sum(c - 1 for c in Counter(
             distupgrade_source_entry_valid(ln)['dist']
             for ln in enabled
             if not distupgrade_source_entry_valid(ln)['invalid']
         ).values() if c > 1)),
    ])


def evaluate_effective_source_gate_lifecycle(
        lines,
        expected_mirror_uri,
        armed=False,
        to_series='bionic',
        source_series='xenial',
        expected_components=None,
        arch='amd64'):
    """Evaluate DISARMED / DEFER / ENFORCE lifecycle for the APT Pre-Invoke gate.

    armed=False → DISARMED allow (exit-equivalent ok=True) regardless of suites.
    armed=True + source-only → ARMED_WAITING_FOR_TARGET_REWRITE / DEFER
      (official or unexpected URI → fail closed).
    armed=True + target visible → strict validate_effective_distupgrade_sources.
    """
    expected_components = list(expected_components or ['main', 'universe'])
    result = OrderedDict([
        ('ok', False),
        ('state', 'UNKNOWN'),
        ('action', 'DENY'),
        ('reason', ''),
        ('error', ''),
        ('phase', 'UNKNOWN'),
    ])
    if not armed:
        result['ok'] = True
        result['state'] = 'DISARMED'
        result['action'] = 'ALLOW'
        result['reason'] = 'NOT_ARMED'
        result['phase'] = 'DISARMED'
        return result

    # Reuse strict validator; interpret pre-rewrite as DEFER when armed.
    strict = validate_effective_distupgrade_sources(
        lines,
        expected_mirror_uri,
        to_series=to_series,
        expected_components=expected_components,
        arch=arch,
        source_series=source_series,
        armed_defer_source_only=True,
    )
    result.update(strict)
    if strict.get('phase') == 'SOURCE_PRE_REWRITE' or strict.get('phase') == 'ARMED_WAITING_FOR_TARGET_REWRITE':
        if strict.get('ok'):
            result['state'] = 'ARMED_WAITING_FOR_TARGET_REWRITE'
            result['action'] = 'DEFER'
            result['reason'] = 'TARGET_REWRITE_NOT_YET_VISIBLE'
            result['phase'] = 'ARMED_WAITING_FOR_TARGET_REWRITE'
        else:
            result['state'] = 'ARMED_WAITING_FOR_TARGET_REWRITE'
            result['action'] = 'DENY'
            result['reason'] = strict.get('error') or 'PRE_REWRITE_INVALID'
        return result
    result['state'] = 'ENFORCING_TARGET_SOURCES'
    result['action'] = 'ALLOW' if strict.get('ok') else 'DENY'
    result['reason'] = 'TARGET_SOURCES_VALID' if strict.get('ok') else (strict.get('error') or 'ENFORCE_FAIL')
    result['phase'] = 'TARGET_POST_REWRITE'
    return result


def validate_effective_distupgrade_sources(
        lines,
        expected_mirror_uri,
        to_series='bionic',
        expected_components=None,
        arch='amd64',
        source_series='xenial',
        armed_defer_source_only=False):
    """Validate DistUpgrade post-rewrite effective sources (fail-closed).

    Returns OrderedDict with DISTUPGRADE_EFFECTIVE_SOURCE_* keys.
    If only source_series pockets remain (pre-rewrite apt update), returns
    phase=SOURCE_PRE_REWRITE and ok=True without enforcing target count.
    When armed_defer_source_only=True, official/unexpected URI in that phase
    fail closed instead of soft-pass.
    """
    expected_components = list(expected_components or ['main', 'universe'])
    expected_suites = allowed_target_suites(to_series)
    expected_uri = uri_rstrip(expected_mirror_uri)
    result = OrderedDict([
        ('ok', False),
        ('phase', 'UNKNOWN'),
        ('error', ''),
        ('DISTUPGRADE_EFFECTIVE_SOURCE_CAPTURE', 'FAIL'),
        ('DISTUPGRADE_EFFECTIVE_SOURCE_COUNT', 0),
        ('DISTUPGRADE_EFFECTIVE_SOURCE_LOCAL_MIRROR_ONLY', 'FAIL'),
        ('DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE_COUNT', 0),
        ('DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT', 0),
        ('DISTUPGRADE_EFFECTIVE_SOURCE_FILE', ''),
        ('enabled_lines', []),
        ('suite_results', OrderedDict()),
    ])

    enabled = []
    for line in lines or []:
        s = (line or '').strip()
        if not s or s.startswith('#'):
            continue
        auth_err = line_has_forbidden_auth(s)
        if auth_err:
            result['error'] = auth_err
            return result
        parsed = distupgrade_source_entry_valid(s)
        if parsed['invalid'] or parsed.get('disabled'):
            continue
        if parsed['type'] != 'deb':
            continue
        enabled.append(parsed)

    result['enabled_lines'] = [_entry_line(e) for e in enabled]
    result['DISTUPGRADE_EFFECTIVE_SOURCE_COUNT'] = len(enabled)
    result['DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT'] = (
        official_archive_reference_count(result['enabled_lines']))

    dists = [e['dist'] for e in enabled]
    has_target = any(
        d == to_series or d.startswith(to_series + '-') for d in dists)
    has_source = any(
        d == source_series or d.startswith(source_series + '-') for d in dists)

    # Pre-rewrite apt update during DRO still has source suites only.
    if has_source and not has_target:
        result['phase'] = 'SOURCE_PRE_REWRITE'
        if armed_defer_source_only:
            if result['DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT']:
                result['ok'] = False
                result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'
                result['DISTUPGRADE_EFFECTIVE_SOURCE_LOCAL_MIRROR_ONLY'] = 'FAIL'
                return result
            bad_uri = any(
                uri_rstrip(e['uri']) != expected_uri for e in enabled)
            if bad_uri:
                result['ok'] = False
                result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'
                result['DISTUPGRADE_EFFECTIVE_SOURCE_LOCAL_MIRROR_ONLY'] = 'FAIL'
                return result
            result['phase'] = 'ARMED_WAITING_FOR_TARGET_REWRITE'
        result['ok'] = True
        result['DISTUPGRADE_EFFECTIVE_SOURCE_CAPTURE'] = 'PASS'
        result['DISTUPGRADE_EFFECTIVE_SOURCE_LOCAL_MIRROR_ONLY'] = 'PASS'
        result['error'] = ''
        return result

    if result['DISTUPGRADE_OFFICIAL_ARCHIVE_REFERENCE_COUNT']:
        result['phase'] = 'TARGET_POST_REWRITE'
        result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'
        return result

    # Duplicate suite detection (enabled deb entries)
    counts = Counter(dists)
    dup = sum(v - 1 for v in counts.values() if v > 1)
    result['DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE_COUNT'] = dup
    if dup:
        result['phase'] = 'TARGET_POST_REWRITE'
        result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_DUPLICATE'
        return result

    missing = [s for s in expected_suites if s not in dists]
    if missing:
        result['phase'] = 'TARGET_POST_REWRITE'
        result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_MISSING_POCKET'
        return result

    if len(enabled) != len(expected_suites):
        result['phase'] = 'TARGET_POST_REWRITE'
        result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_COUNT_MISMATCH'
        return result

    suite_results = OrderedDict()
    for suite in expected_suites:
        key = 'DISTUPGRADE_EFFECTIVE_SOURCE_%s' % suite.replace('-', '_')
        matches = [e for e in enabled if e['dist'] == suite]
        ok = (
            len(matches) == 1
            and uri_rstrip(matches[0]['uri']) == expected_uri
            and all(c in matches[0]['comps'] for c in expected_components)
            and (not arch or arch in (matches[0].get('architectures') or [arch]))
            and 'signed-by' not in ' '.join(matches[0].get('rejected_options') or [])
        )
        suite_results[key] = 'PASS' if ok else 'FAIL'
        result[key] = suite_results[key]

    result['suite_results'] = suite_results
    result['phase'] = 'TARGET_POST_REWRITE'

    if any(v != 'PASS' for v in suite_results.values()):
        # Prefer offline-escape style messaging when URI drifted.
        bad_uri = any(
            uri_rstrip(e['uri']) != expected_uri for e in enabled)
        if bad_uri:
            result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_OFFLINE_ESCAPE'
        else:
            result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_COUNT_MISMATCH'
        return result

    result['ok'] = True
    result['DISTUPGRADE_EFFECTIVE_SOURCE_CAPTURE'] = 'PASS'
    result['DISTUPGRADE_EFFECTIVE_SOURCE_LOCAL_MIRROR_ONLY'] = 'PASS'
    result['error'] = ''
    return result


def validate_effective_sources_file(path, expected_mirror_uri, **kwargs):
    result = OrderedDict()
    if not path or not os.path.isfile(path):
        result['ok'] = False
        result['error'] = 'FAIL_DISTUPGRADE_EFFECTIVE_SOURCE_COUNT_MISMATCH'
        result['DISTUPGRADE_EFFECTIVE_SOURCE_FILE'] = path or ''
        result['DISTUPGRADE_EFFECTIVE_SOURCE_CAPTURE'] = 'FAIL'
        return result
    with open(path, 'rb') as fh:
        raw = fh.read()
    text = raw.decode('utf-8-sig')
    result = validate_effective_distupgrade_sources(
        text.splitlines(), expected_mirror_uri, **kwargs)
    result['DISTUPGRADE_EFFECTIVE_SOURCE_FILE'] = path
    return result


def build_valid_mirrors_overlay(local_mirror_uri, base_mirrors=None):
    """Build ValidMirrors file lines: essentials + local selective mirror."""
    essentials = list(base_mirrors or [
        'http://archive.ubuntu.com/ubuntu/',
        'http://security.ubuntu.com/ubuntu/',
        'http://ports.ubuntu.com/ubuntu-ports/',
        'http://old-releases.ubuntu.com/ubuntu/',
    ])
    local = uri_rstrip(local_mirror_uri)
    lines = ['# stellar offline DistUpgrade ValidMirrors overlay']
    seen = set()
    for m in essentials + [local, local + '/']:
        key = uri_rstrip(m)
        if not key or key in seen:
            continue
        seen.add(key)
        lines.append(m if m.endswith('/') or m == local else m)
    # ensure both slash variants for local
    if local not in seen:
        lines.append(local)
    if (local + '/') not in [uri_rstrip(x) + ('/' if x.endswith('/') else '') for x in lines]:
        lines.append(local + '/')
    # normalize: always include exact local and local/
    out = ['# stellar offline DistUpgrade ValidMirrors overlay']
    out.extend(essentials)
    out.append(local)
    out.append(local + '/')
    # dedupe preserving order
    final = []
    seen = set()
    for ln in out:
        if ln.startswith('#'):
            final.append(ln)
            continue
        k = uri_rstrip(ln)
        if k in seen:
            continue
        seen.add(k)
        final.append(ln)
    return final


def rewrite_local_sources_with_registered_mirror(
        source_lines, local_mirror_uri, from_dist='xenial', to_dist='bionic'):
    """End-to-end: register local URI as ValidMirror and rewrite suites."""
    mirrors = build_valid_mirrors_overlay(local_mirror_uri)
    return simulate_rewrite_sources_list(
        source_lines,
        from_dist=from_dist,
        to_dist=to_dist,
        valid_mirrors=mirrors,
        allow_third_party=False,
        downloadable_dists=set(allowed_target_suites(to_dist) + [
            '%s-proposed' % to_dist]),
    )
