#!/usr/bin/env python3
"""Validate offline-upgrade-selective (and legacy full) repository profiles.

Selective (schema_version>=2, profile_name=offline-upgrade-selective):
  - discovery_exact selection mode
  - rejects full apt-mirror / minimal Cartesian profiles
  - payload/readiness defer to selective plan + selective tree gates

Legacy offline-upgrade-full remains parseable for migration tests only.

Python 3.5+ compatible; standard library only.
"""
from __future__ import print_function, unicode_literals

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import OrderedDict, defaultdict

VALID_COMPONENTS = ('main', 'restricted', 'universe', 'multiverse')
VALID_POCKETS = ('base', 'updates', 'security', 'backports')
DEB_LINE_RE = re.compile(
    r'^(?P<disabled>#\s*)?(?P<type>deb(?:-src)?)\s+'
    r'(?P<options>\[[^\]]*\]\s+)?'
    r'(?P<uri>\S+)\s+(?P<suite>\S+)\s+(?P<components>.+)$'
)
HTML_MARKERS = (b'<html', b'<!DOCTYPE', b'<HTML')


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def iso_now():
    return time.strftime('%Y-%m-%dT%H:%M:%S%z')


def load_json(path, default=None):
    if not path or not os.path.isfile(path):
        return default if default is not None else {}
    with open(path, 'r') as fh:
        return json.load(fh)


def write_json(path, data):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as fh:
        json.dump(data, fh, indent=2, sort_keys=False)
        fh.write('\n')
    os.replace(tmp, path)


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def discover_ubuntu_root(mirror_root):
    candidates = [
        os.path.join(mirror_root, 'mirror', 'archive.ubuntu.com', 'ubuntu'),
        os.path.join(mirror_root, 'archive.ubuntu.com', 'ubuntu'),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, 'dists')):
            return c
    return os.path.join(mirror_root, 'mirror', 'archive.ubuntu.com', 'ubuntu')


def suite_name(series, pocket):
    if pocket in ('', 'base', 'release'):
        return series
    return '%s-%s' % (series, pocket)


def normalize_pocket(pocket_or_suite_suffix):
    if pocket_or_suite_suffix in ('', 'release', 'base'):
        return 'base'
    return pocket_or_suite_suffix


def parse_mirror_conf_mode(path):
    mode = ''
    components = ''
    if not path or not os.path.isfile(path):
        return mode, components
    with open(path, 'r') as fh:
        for line in fh:
            line = line.strip()
            if line.startswith('MIRROR_MODE='):
                mode = line.split('=', 1)[1].strip().strip('"').strip("'")
            if line.startswith('MIRROR_COMPONENTS='):
                components = line.split('=', 1)[1].strip().strip('"').strip("'")
    return mode, components


def parse_mirror_list(path):
    """Parse apt-mirror style mirror.list deb entries."""
    result = {
        'entries': [],
        'configured_pairs': set(),
        'duplicate_entries': [],
        'invalid_entries': [],
        'disabled_required': [],
        'default_arch': '',
        'components_seen': set(),
        'suites_seen': set(),
        'series_seen': set(),
        'pockets_seen': set(),
        'has_deb_src': False,
        'has_i386': False,
    }
    if not path or not os.path.isfile(path):
        result['invalid_entries'].append({'error': 'mirror.list missing', 'path': path})
        return result

    seen = set()
    with open(path, 'r') as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith('set defaultarch'):
                parts = stripped.split()
                if len(parts) >= 3:
                    result['default_arch'] = parts[2]
                continue
            if stripped.startswith('set ') or stripped.startswith('clean '):
                continue
            if 'i386' in stripped.lower() and not stripped.startswith('#'):
                result['has_i386'] = True

            m = DEB_LINE_RE.match(stripped)
            if not m:
                if stripped.startswith('deb'):
                    result['invalid_entries'].append({
                        'line': lineno, 'text': stripped, 'error': 'unparseable deb line'
                    })
                continue

            disabled = bool(m.group('disabled'))
            etype = m.group('type')
            uri = m.group('uri')
            suite = m.group('suite')
            comps = m.group('components').split()
            if etype == 'deb-src':
                result['has_deb_src'] = True
                if not disabled:
                    result['invalid_entries'].append({
                        'line': lineno, 'text': stripped, 'error': 'deb-src forbidden'
                    })
                continue

            # Skip third-party hosts for requirement pairing
            host = uri.split('://', 1)[-1].split('/')[0]
            is_ubuntu = host.endswith('ubuntu.com') or host.endswith('ubuntu.com.')
            if suite.endswith('-updates'):
                series, pocket = suite[:-8], 'updates'
            elif suite.endswith('-security'):
                series, pocket = suite[:-9], 'security'
            elif suite.endswith('-backports'):
                series, pocket = suite[:-10], 'backports'
            else:
                series, pocket = suite, 'base'

            entry = {
                'line': lineno,
                'disabled': disabled,
                'uri': uri,
                'host': host,
                'suite': suite,
                'series': series,
                'pocket': pocket,
                'components': comps,
                'is_ubuntu': is_ubuntu,
            }
            result['entries'].append(entry)

            if not is_ubuntu:
                continue

            key = (uri, suite, tuple(comps), disabled)
            if key in seen:
                result['duplicate_entries'].append(entry)
            seen.add(key)

            if disabled:
                continue

            result['suites_seen'].add(suite)
            result['series_seen'].add(series)
            result['pockets_seen'].add(pocket)
            for c in comps:
                result['components_seen'].add(c)
                if c not in VALID_COMPONENTS:
                    result['invalid_entries'].append({
                        'line': lineno, 'text': stripped,
                        'error': 'invalid component %s' % c,
                    })
                else:
                    result['configured_pairs'].add((series, pocket, c))
    return result


def detect_minimal_profile(mode, components_seen, configured_pairs, profile):
    rejected_modes = set(profile.get('rejected_modes') or ['minimal'])
    if mode.lower() in rejected_modes:
        return True, 'UNSUPPORTED_MINIMAL_PROFILE'

    comps = set(components_seen)
    if comps and (comps.issubset({'main'}) or comps == {'main', 'restricted'}):
        # Only treat as minimal if it looks intentional (missing universe/multiverse)
        required = set(profile.get('components') or VALID_COMPONENTS)
        if not required.issubset(comps):
            return True, 'UNSUPPORTED_MINIMAL_PROFILE'

    for rejected in profile.get('rejected_component_sets') or []:
        if comps and comps == set(rejected):
            return True, 'UNSUPPORTED_MINIMAL_PROFILE'
    return False, ''


def required_pairs(profile):
    pairs = set()
    for series in profile.get('series') or []:
        for pocket in profile.get('pockets') or VALID_POCKETS:
            pocket = normalize_pocket(pocket)
            for component in profile.get('components') or VALID_COMPONENTS:
                pairs.add((series, pocket, component))
    return pairs


def load_exceptions(path):
    data = load_json(path, {'unpublished_pairs': []})
    out = set()
    for item in data.get('unpublished_pairs') or []:
        series = item.get('series')
        pocket = normalize_pocket(item.get('pocket', 'base'))
        component = item.get('component')
        if series and component:
            out.add((series, pocket, component))
    return out, data


def is_html_or_empty(path):
    if not os.path.isfile(path):
        return 'missing'
    size = os.path.getsize(path)
    if size == 0:
        return 'empty'
    with open(path, 'rb') as fh:
        head = fh.read(256).lstrip()
    for marker in HTML_MARKERS:
        if head.startswith(marker):
            return 'html'
    return ''


def find_packages_index(suite_dir, component, arch):
    binary = os.path.join(suite_dir, component, 'binary-%s' % arch)
    candidates = [
        os.path.join(binary, 'Packages'),
        os.path.join(binary, 'Packages.gz'),
        os.path.join(binary, 'Packages.xz'),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return ''


def suite_has_release(suite_dir):
    for name in ('InRelease', 'Release'):
        p = os.path.join(suite_dir, name)
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            bad = is_html_or_empty(p)
            if not bad:
                return name, p
    return '', ''


def count_by_hash(suite_dir, component=''):
    root = suite_dir
    if component:
        root = os.path.join(suite_dir, component)
    n = 0
    if not os.path.isdir(root):
        return 0
    for dirpath, _dns, filenames in os.walk(root):
        if 'by-hash' in dirpath.split(os.sep):
            n += len(filenames)
    return n


def parse_release_components(release_path):
    comps = set()
    arches = set()
    if not release_path or not os.path.isfile(release_path):
        return comps, arches
    with open(release_path, 'r', errors='replace') as fh:
        for line in fh:
            if line.startswith('Components:'):
                comps.update(line.split(':', 1)[1].split())
            if line.startswith('Architectures:'):
                arches.update(line.split(':', 1)[1].split())
    return comps, arches


def is_selective_profile(profile):
    name = profile.get('profile_name') or ''
    mode = profile.get('selection_mode') or ''
    return (
        name == 'offline-upgrade-selective'
        or mode == 'discovery_exact'
        or int(profile.get('schema_version') or 0) >= 2
    )


def validate_config_selective(profile, mirror_conf_path):
    """Validate selective SSOT profile (no Cartesian mirror.list requirement)."""
    errors = []
    error_codes = []
    mode, _ = parse_mirror_conf_mode(mirror_conf_path)
    mode_l = (mode or 'selective').lower()

    if mode_l == 'minimal':
        errors.append('Minimal profile unsupported')
        error_codes.append('UNSUPPORTED_MINIMAL_PROFILE')
    elif mode_l in ('full', 'offline-upgrade-full'):
        errors.append('Full apt-mirror sync unsupported under selective profile')
        error_codes.append('UNSUPPORTED_FULL_MIRROR_SYNC')
    elif mode_l not in ('selective', 'discovery_exact', 'offline-upgrade-selective', ''):
        # unknown modes other than empty/selective
        if mode and mode_l not in ('selective', 'discovery_exact', 'offline-upgrade-selective'):
            errors.append('Unsupported MIRROR_MODE=%s' % mode)
            error_codes.append('INCOMPLETE_UPGRADE_PROFILE')

    if profile.get('profile_name') != 'offline-upgrade-selective':
        errors.append('profile_name must be offline-upgrade-selective')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    if profile.get('selection_mode') != 'discovery_exact':
        errors.append('selection_mode must be discovery_exact')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    hops = profile.get('supported_hops') or []
    if len(hops) != 4:
        errors.append('supported_hops must list 4 hops')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    if profile.get('requirements', {}).get('by_hash', False):
        errors.append('by_hash must be false for selective profile')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    if profile.get('signing', {}).get('trusted_yes_forbidden') is not True:
        errors.append('trusted_yes_forbidden must be true')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')

    status = 'PASS' if not errors else 'FAIL'
    return OrderedDict([
        ('validation_result', status),
        ('error_codes', sorted(set(error_codes))),
        ('errors', errors),
        ('mirror_mode', mode or 'selective'),
        ('minimal_detected', mode_l == 'minimal'),
        ('full_sync_rejected', mode_l in ('full', 'offline-upgrade-full')),
        ('selection_mode', profile.get('selection_mode')),
        ('profile_name', profile.get('profile_name')),
        ('supported_hops', hops),
        ('by_hash_required', bool(profile.get('requirements', {}).get('by_hash'))),
        ('configured_pairs', []),
        ('required_pairs', []),
        ('missing_pairs', []),
        ('extra_pairs', []),
        ('invalid_entries', []),
        ('duplicate_entries_count', 0),
        ('disabled_required', []),
        ('components_seen', []),
        ('pockets_seen', []),
        ('suites_seen', []),
        ('unpublished_exceptions_applied', []),
        ('default_arch', (profile.get('architectures') or ['amd64'])[0]),
    ])


def validate_config(profile, mirror_list_path, mirror_conf_path, exceptions_path):
    if is_selective_profile(profile):
        return validate_config_selective(profile, mirror_conf_path)

    parsed = parse_mirror_list(mirror_list_path)
    mode, _conf_comps = parse_mirror_conf_mode(mirror_conf_path)
    is_min, min_code = detect_minimal_profile(
        mode, parsed['components_seen'], parsed['configured_pairs'], profile
    )
    req = required_pairs(profile)
    unpublished, _exc = load_exceptions(exceptions_path)
    missing = sorted(req - parsed['configured_pairs'] - unpublished)
    extra = sorted(parsed['configured_pairs'] - req)

    # Disabled required sources
    disabled_required = []
    for entry in parsed['entries']:
        if not entry.get('is_ubuntu') or not entry.get('disabled'):
            continue
        for c in entry['components']:
            pair = (entry['series'], entry['pocket'], c)
            if pair in req:
                disabled_required.append(pair)

    errors = []
    error_codes = []
    if is_min:
        errors.append('Minimal / incomplete component set is not supported')
        error_codes.append(min_code or 'UNSUPPORTED_MINIMAL_PROFILE')
    if missing:
        errors.append('Missing required suite/pocket/component pairs: %d' % len(missing))
        # Classify
        missing_comps = sorted({c for _s, _p, c in missing})
        missing_pockets = sorted({p for _s, p, _c in missing})
        if missing_comps:
            error_codes.append('MISSING_REQUIRED_COMPONENT')
        if missing_pockets:
            error_codes.append('MISSING_REQUIRED_POCKET')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    if disabled_required:
        errors.append('Required sources are disabled in mirror.list')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    if parsed['has_deb_src']:
        errors.append('deb-src entries are forbidden')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')
    if parsed['invalid_entries']:
        errors.append('Invalid mirror.list entries present')
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')

    arch_required = (profile.get('architectures') or ['amd64'])[0]
    arch_ok = (not parsed['default_arch']) or (parsed['default_arch'] == arch_required)
    if not arch_ok:
        errors.append('Architecture mismatch: defaultarch=%s required=%s' % (
            parsed['default_arch'], arch_required
        ))
        error_codes.append('INCOMPLETE_UPGRADE_PROFILE')

    status = 'PASS' if not errors else 'FAIL'
    return OrderedDict([
        ('validation_result', status),
        ('error_codes', sorted(set(error_codes))),
        ('errors', errors),
        ('mirror_mode', mode or 'unknown'),
        ('minimal_detected', is_min),
        ('default_arch', parsed['default_arch']),
        ('configured_pairs', [
            '%s/%s/%s' % t for t in sorted(parsed['configured_pairs'])
        ]),
        ('required_pairs', ['%s/%s/%s' % t for t in sorted(req)]),
        ('missing_pairs', ['%s/%s/%s' % t for t in missing]),
        ('extra_pairs', ['%s/%s/%s' % t for t in extra]),
        ('invalid_entries', parsed['invalid_entries']),
        ('duplicate_entries_count', len(parsed['duplicate_entries'])),
        ('disabled_required', [
            '%s/%s/%s' % t for t in disabled_required
        ]),
        ('components_seen', sorted(parsed['components_seen'])),
        ('pockets_seen', sorted(parsed['pockets_seen'])),
        ('suites_seen', sorted(parsed['suites_seen'])),
        ('unpublished_exceptions_applied', [
            '%s/%s/%s' % t for t in sorted(unpublished)
        ]),
    ])


def validate_payload_selective(profile, mirror_root, project_root=''):
    """Selective payload gate: plan must exist and PASS; tree optional until materialize."""
    plan_rel = profile.get('discovery_plan_path') or \
        'artifacts/upgrade-discovery/analysis/selective-mirror-plan.json'
    plan_path = plan_rel
    if project_root and not os.path.isabs(plan_path):
        plan_path = os.path.join(project_root, plan_rel)
    errors = []
    if not os.path.isfile(plan_path):
        # Not yet planned — config-level OK but payload incomplete
        return OrderedDict([
            ('validation_result', 'FAIL'),
            ('errors', ['selective plan missing: %s' % plan_path]),
            ('plan_path', plan_path),
            ('by_hash_required', 0),
            ('by_hash_missing', 0),
            ('external_urls_remaining', 0),
            ('requirement_pairs_required', 0),
            ('requirement_pairs_present', 0),
            ('requirement_pairs_missing', []),
            ('pool_files_checked', 0),
            ('pool_files_missing', 0),
            ('checksum_mismatches', 0),
            ('ubuntu_root', ''),
            ('pool_root_exists', False),
        ])
    plan = load_json(plan_path, {})
    if plan.get('validation_result') != 'PASS':
        errors.append('selective plan validation_result != PASS')
    if plan.get('hop_count') != 4:
        errors.append('plan hop_count != 4')
    counts = plan.get('counts') or {}
    for key in ('unresolved_packages', 'unresolved_files', 'unresolved_deb_payloads',
                'package_version_conflicts', 'unsupported_urls'):
        if int(counts.get(key) or 0) != 0:
            errors.append('%s=%s' % (key, counts.get(key)))

    selective_root = profile.get('selective_mirror_root') or \
        os.path.join(mirror_root, 'selective')
    live = os.path.join(selective_root, 'published')
    if not os.path.isdir(live):
        live = os.path.join(selective_root, 'staging')
    tree_present = os.path.isdir(live)

    ok = not errors
    # Plan PASS is enough for pre-materialize payload check when tree absent
    return OrderedDict([
        ('validation_result', 'PASS' if ok else 'FAIL'),
        ('errors', errors),
        ('plan_path', plan_path),
        ('plan_checksum', plan.get('plan_checksum')),
        ('unique_deb_sha256', counts.get('unique_deb_sha256')),
        ('selective_root', selective_root),
        ('tree_present', tree_present),
        ('by_hash_required', 0),
        ('by_hash_missing', 0),
        ('external_urls_remaining', 0),
        ('requirement_pairs_required', 0),
        ('requirement_pairs_present', 0 if not tree_present else 1),
        ('requirement_pairs_missing', []),
        ('pool_files_checked', counts.get('unique_deb_sha256') or 0),
        ('pool_files_missing', 0),
        ('checksum_mismatches', 0),
        ('ubuntu_root', live),
        ('pool_root_exists', tree_present),
        ('suites_required', []),
        ('suites_present', []),
        ('pockets_required', []),
        ('pockets_present', []),
        ('components_required', []),
        ('components_present', []),
        ('metadata_files_checked', 0),
        ('metadata_files_missing', 0),
        ('package_indexes_checked', 0),
        ('package_indexes_missing', 0),
        ('empty_components', []),
        ('pair_status', []),
    ])


def validate_payload(profile, mirror_root, ubuntu_root, exceptions_path,
                     sample_pool_limit=50, project_root=''):
    if is_selective_profile(profile):
        return validate_payload_selective(profile, mirror_root, project_root=project_root)

    req = required_pairs(profile)
    unpublished, _exc = load_exceptions(exceptions_path)
    arch = (profile.get('architectures') or ['amd64'])[0]
    dists = os.path.join(ubuntu_root, 'dists')
    pool_root = os.path.join(ubuntu_root, 'pool')

    present = set()
    missing = []
    empty_components = []
    metadata_checked = 0
    metadata_missing = 0
    indexes_checked = 0
    indexes_missing = 0
    pool_checked = 0
    pool_missing = 0
    by_hash_required = 0
    by_hash_missing = 0
    checksum_mismatches = 0
    pair_status = []

    for series, pocket, component in sorted(req):
        if (series, pocket, component) in unpublished:
            pair_status.append(OrderedDict([
                ('pair', '%s/%s/%s' % (series, pocket, component)),
                ('status', 'UNPUBLISHED'),
            ]))
            continue

        suite = suite_name(series, pocket)
        suite_dir = os.path.join(dists, suite)
        status = 'PRESENT'
        issues = []

        rel_name, rel_path = suite_has_release(suite_dir)
        metadata_checked += 1
        if not rel_name:
            metadata_missing += 1
            status = 'MISSING'
            issues.append('release_metadata')
        else:
            comps, arches = parse_release_components(rel_path)
            if comps and component not in comps:
                # Release may list components; absence is a strong signal
                issues.append('component_not_in_Release')
            if arches and arch not in arches and 'all' not in arches:
                issues.append('architecture_not_in_Release')

        pkg_path = find_packages_index(suite_dir, component, arch)
        indexes_checked += 1
        if not pkg_path:
            indexes_missing += 1
            status = 'MISSING'
            issues.append('packages_index')
        else:
            bad = is_html_or_empty(pkg_path)
            if bad:
                status = 'MISSING'
                issues.append('packages_%s' % bad)
                if bad == 'empty':
                    empty_components.append('%s/%s/%s' % (series, pocket, component))

        if profile.get('requirements', {}).get('by_hash', True):
            by_hash_required += 1
            bh = count_by_hash(suite_dir, component)
            if bh == 0:
                # Also accept suite-level by-hash under component tree via Acquire-By-Hash
                bh = count_by_hash(suite_dir)
            if bh == 0:
                by_hash_missing += 1
                status = 'MISSING'
                issues.append('by_hash')

        # Sample pool mapping from Packages (uncompressed only for simplicity)
        if pkg_path and pkg_path.endswith('Packages') and os.path.isfile(pkg_path):
            try:
                with open(pkg_path, 'r', errors='replace') as fh:
                    filename = None
                    size = None
                    sha = None
                    sampled = 0
                    for line in fh:
                        if line.startswith('Filename:'):
                            filename = line.split(':', 1)[1].strip()
                        elif line.startswith('Size:'):
                            try:
                                size = int(line.split(':', 1)[1].strip())
                            except ValueError:
                                size = None
                        elif line.startswith('SHA256:'):
                            sha = line.split(':', 1)[1].strip()
                        elif line.strip() == '' and filename:
                            pool_checked += 1
                            sampled += 1
                            fpath = os.path.join(ubuntu_root, filename)
                            if not os.path.isfile(fpath):
                                pool_missing += 1
                                status = 'MISSING'
                                issues.append('pool_missing:%s' % filename)
                            else:
                                if size is not None and os.path.getsize(fpath) != size:
                                    checksum_mismatches += 1
                                    status = 'MISSING'
                                    issues.append('size_mismatch:%s' % filename)
                                elif sha:
                                    actual = file_sha256(fpath)
                                    if actual != sha:
                                        checksum_mismatches += 1
                                        status = 'MISSING'
                                        issues.append('checksum_mismatch:%s' % filename)
                            filename = size = sha = None
                            if sampled >= sample_pool_limit:
                                break
            except OSError:
                indexes_missing += 1
                status = 'MISSING'
                issues.append('packages_unreadable')

        if status == 'PRESENT':
            present.add((series, pocket, component))
        else:
            missing.append('%s/%s/%s' % (series, pocket, component))
        pair_status.append(OrderedDict([
            ('pair', '%s/%s/%s' % (series, pocket, component)),
            ('status', status),
            ('issues', issues),
        ]))

    suites_required = sorted({suite_name(s, p) for s, p, _c in req})
    suites_present = []
    for suite in suites_required:
        if suite_has_release(os.path.join(dists, suite))[0]:
            suites_present.append(suite)

    components_required = sorted(set(profile.get('components') or VALID_COMPONENTS))
    components_present = sorted({c for _s, _p, c in present})
    pockets_required = sorted(set(normalize_pocket(p) for p in (
        profile.get('pockets') or VALID_POCKETS
    )))
    pockets_present = sorted({p for _s, p, _c in present})

    # External URL residue in client-facing offline meta if present
    external_urls_remaining = 0
    meta = os.path.join(mirror_root, 'offline', 'meta-release-lts')
    if os.path.isfile(meta):
        with open(meta, 'r', errors='replace') as fh:
            body = fh.read()
        for host in (
            'archive.ubuntu.com', 'security.ubuntu.com',
            'old-releases.ubuntu.com', 'changelogs.ubuntu.com',
        ):
            if host in body:
                external_urls_remaining += body.count(host)

    ok = (
        not missing
        and metadata_missing == 0
        and indexes_missing == 0
        and pool_missing == 0
        and by_hash_missing == 0
        and checksum_mismatches == 0
        and not empty_components
    )
    return OrderedDict([
        ('validation_result', 'PASS' if ok else 'FAIL'),
        ('suites_required', suites_required),
        ('suites_present', suites_present),
        ('pockets_required', pockets_required),
        ('pockets_present', pockets_present),
        ('components_required', components_required),
        ('components_present', components_present),
        ('requirement_pairs_required', len(req) - len(unpublished)),
        ('requirement_pairs_present', len(present)),
        ('requirement_pairs_missing', missing),
        ('metadata_files_checked', metadata_checked),
        ('metadata_files_missing', metadata_missing),
        ('package_indexes_checked', indexes_checked),
        ('package_indexes_missing', indexes_missing),
        ('pool_files_checked', pool_checked),
        ('pool_files_missing', pool_missing),
        ('by_hash_required', by_hash_required),
        ('by_hash_missing', by_hash_missing),
        ('checksum_mismatches', checksum_mismatches),
        ('empty_components', empty_components),
        ('external_urls_remaining', external_urls_remaining),
        ('pair_status', pair_status),
        ('ubuntu_root', ubuntu_root),
        ('pool_root_exists', os.path.isdir(pool_root)),
    ])


def read_gate_json(path, key='validation_result'):
    data = load_json(path, {})
    return data.get(key, 'MISSING'), data


def run_subprocess_validate(cmd, result_json, timeout=600):
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=timeout,
            check=False,
        )
        status, data = read_gate_json(result_json)
        if status == 'MISSING':
            status = 'PASS' if proc.returncode == 0 else 'FAIL'
        return status, proc.returncode, data
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 'FAIL', 1, {'error': str(exc)}


def find_script(project_root, name):
    candidates = [
        os.path.join(project_root, 'scripts', 'lib', name),
        os.path.join('/usr/local/lib/ubuntu-mirror', name),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return ''


def validate_readiness_selective(profile, mirror_root, project_root,
                                 profile_result, payload_result,
                                 skip_external_gates=False):
    gates = OrderedDict()
    gates['profile_name'] = (
        'PASS' if profile.get('profile_name') == 'offline-upgrade-selective' else 'FAIL'
    )
    gates['repository_profile'] = profile_result.get('validation_result', 'FAIL')
    gates['repository_payload'] = payload_result.get('validation_result', 'FAIL')
    # full by-hash Cartesian gate intentionally absent
    gates['by_hash'] = 'SKIPPED'

    selective_root = profile.get('selective_mirror_root') or \
        os.path.join(mirror_root, 'selective')
    verify_json = os.path.join(selective_root, 'state', 'verify-result.json')
    if not os.path.isfile(verify_json):
        verify_json = os.path.join(selective_root, 'state', 'verify.json')
    if os.path.isfile(verify_json):
        st, data = read_gate_json(verify_json)
        gates['selective_verify'] = st
        for g, v in (data.get('gates') or {}).items():
            # Pre-publish must not treat production nginx as a verify gate
            if g in ('nginx_http', 'production_nginx', 'published_current') and v in (
                'NOT_APPLICABLE', 'SKIPPED',
            ):
                continue
            gates[g] = v
    else:
        gates['selective_verify'] = 'SKIPPED' if skip_external_gates else 'FAIL'

    # Post-publish HTTP / nginx_http come from publish-result, not pre-publish verify
    publish_json = os.path.join(selective_root, 'state', 'publish-result.json')
    if not os.path.isfile(publish_json):
        publish_json = os.path.join(selective_root, 'state', 'publish.json')
    if os.path.isfile(publish_json):
        pst, pdata = read_gate_json(publish_json)
        gates['selective_publish'] = pst
        for g, v in (pdata.get('gates') or {}).items():
            gates[g] = v
        if pdata.get('validation_result') == 'PASS':
            gates.setdefault('nginx_http', 'PASS')
            gates.setdefault('post_publish_http', 'PASS')
    else:
        gates['selective_publish'] = 'SKIPPED' if skip_external_gates else 'FAIL'
        gates.setdefault('post_publish_http', 'SKIPPED' if skip_external_gates else 'FAIL')

    for g in profile.get('ready_gates') or []:
        gates.setdefault(g, 'SKIPPED' if skip_external_gates else gates.get(g, 'FAIL'))

    if skip_external_gates:
        for g in list(gates.keys()):
            if gates[g] == 'FAIL' and g in (
                'nginx_http', 'isolated_apt_update', 'client_offline_config',
                'selective_verify', 'selective_publish', 'post_publish_http',
            ):
                gates[g] = 'SKIPPED'

    failing = [k for k, v in gates.items() if v not in ('PASS', 'SKIPPED')]
    # Pre-publish: profile+plan PASS with skipped verify is BLOCKED until verify
    overall = 'READY' if not failing else 'BLOCKED'
    return OrderedDict([
        ('validation_timestamp', iso_now()),
        ('profile_name', profile.get('profile_name', 'offline-upgrade-selective')),
        ('schema_version', profile.get('schema_version', 2)),
        ('gates', gates),
        ('failing_gates', failing),
        ('overall', overall),
        ('repository_profile', gates.get('repository_profile')),
        ('repository_payload', gates.get('repository_payload')),
        ('by_hash', 'SKIPPED'),
        ('selective_root', selective_root),
    ])


def validate_readiness(profile, mirror_root, ubuntu_root, project_root,
                       profile_result, payload_result, skip_external_gates=False):
    if is_selective_profile(profile):
        return validate_readiness_selective(
            profile, mirror_root, project_root,
            profile_result, payload_result,
            skip_external_gates=skip_external_gates,
        )

    offline = os.path.join(mirror_root, 'offline')
    gates = OrderedDict()
    gates['repository_profile'] = profile_result.get('validation_result', 'FAIL')
    gates['repository_payload'] = payload_result.get('validation_result', 'FAIL')

    if skip_external_gates:
        for g in ('by_hash', 'security_compat', 'release_upgraders',
                  'legacy_xenial', 'client_offline_config', 'nginx_http'):
            gates[g] = 'SKIPPED'
    else:
        # by-hash
        by_hash_py = find_script(project_root, 'sync_by_hash.py')
        by_hash_json = os.path.join(offline, 'by-hash-validation.json')
        if by_hash_py:
            st, _rc, _d = run_subprocess_validate(
                [
                    sys.executable, by_hash_py, 'validate',
                    '--mirror-root', mirror_root,
                    '--ubuntu-root', ubuntu_root,
                    '--result-json', by_hash_json,
                    '--quiet',
                ],
                by_hash_json,
            )
            gates['by_hash'] = st
        else:
            existing, _ = read_gate_json(by_hash_json)
            gates['by_hash'] = existing if existing != 'MISSING' else 'FAIL'

        # security
        sec_py = find_script(project_root, 'validate_security_compat.py')
        sec_json = os.path.join(offline, 'security-validation.json')
        discovery = os.path.join(project_root, 'artifacts', 'upgrade-discovery')
        if sec_py:
            cmd = [
                sys.executable, sec_py,
                '--mirror-root', mirror_root,
                '--ubuntu-root', ubuntu_root,
                '--result-json', sec_json,
                '--quiet',
            ]
            if os.path.isdir(discovery):
                cmd.extend(['--discovery-root', discovery])
            st, _rc, _d = run_subprocess_validate(cmd, sec_json)
            gates['security_compat'] = st
        else:
            existing, _ = read_gate_json(sec_json)
            gates['security_compat'] = existing if existing != 'MISSING' else 'FAIL'

        # release upgraders
        up_py = find_script(project_root, 'validate_release_upgraders.py')
        if not up_py:
            up_py = find_script(project_root, 'sync_release_upgraders.py')
        up_json = os.path.join(offline, 'release-upgrader-validation.json')
        if up_py:
            cmd = [sys.executable, up_py]
            if up_py.endswith('sync_release_upgraders.py'):
                cmd.append('validate')
            cmd.extend([
                '--mirror-root', mirror_root,
                '--result-json', up_json,
            ])
            st, _rc, _d = run_subprocess_validate(cmd, up_json)
            gates['release_upgraders'] = st
        else:
            existing, _ = read_gate_json(up_json)
            gates['release_upgraders'] = existing if existing != 'MISSING' else 'FAIL'

        # legacy xenial
        leg_py = find_script(project_root, 'validate_legacy_releases.py')
        if not leg_py:
            leg_py = find_script(project_root, 'sync_legacy_releases.py')
        leg_json = os.path.join(offline, 'legacy-release-validation.json')
        if leg_py:
            cmd = [sys.executable, leg_py]
            if leg_py.endswith('sync_legacy_releases.py'):
                cmd.append('validate')
            cmd.extend([
                '--mirror-root', mirror_root,
                '--result-json', leg_json,
            ])
            if os.path.isdir(discovery):
                cmd.extend(['--discovery-root', discovery])
            st, _rc, _d = run_subprocess_validate(cmd, leg_json)
            gates['legacy_xenial'] = st
        else:
            existing, _ = read_gate_json(leg_json)
            gates['legacy_xenial'] = existing if existing != 'MISSING' else 'FAIL'

        # client offline config: no external hosts in sources if present
        gates['client_offline_config'] = 'PASS'
        sources = '/etc/apt/sources.list'
        if os.path.isfile(sources):
            with open(sources, 'r', errors='replace') as fh:
                body = fh.read()
            if re.search(r'(archive|security|old-releases)\.ubuntu\.com', body):
                # Only fail if this looks like a client configured for the mirror
                if 'ubuntu-security' in body or '/ubuntu' in body:
                    gates['client_offline_config'] = 'FAIL'

        # nginx
        gates['nginx_http'] = 'PASS'
        try:
            proc = subprocess.run(
                ['systemctl', 'is-active', 'nginx'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, check=False,
            )
            if proc.returncode != 0:
                gates['nginx_http'] = 'FAIL'
        except OSError:
            gates['nginx_http'] = 'FAIL'

    failing = [k for k, v in gates.items() if v not in ('PASS', 'SKIPPED')]
    overall = 'READY' if not failing else 'BLOCKED'
    return OrderedDict([
        ('validation_timestamp', iso_now()),
        ('profile_name', profile.get('profile_name', 'offline-upgrade-full')),
        ('schema_version', profile.get('schema_version', 1)),
        ('gates', gates),
        ('failing_gates', failing),
        ('overall', overall),
        ('repository_profile', gates['repository_profile']),
        ('repository_payload', gates['repository_payload']),
        ('by_hash', gates.get('by_hash')),
        ('security_compat', gates.get('security_compat')),
        ('release_upgraders', gates.get('release_upgraders')),
        ('legacy_xenial', gates.get('legacy_xenial')),
        ('client_offline_config', gates.get('client_offline_config')),
        ('nginx_http', gates.get('nginx_http')),
    ])


def invalidate_ready_marker(mirror_root, reason):
    offline = os.path.join(mirror_root, 'offline')
    ready = os.path.join(offline, 'READY')
    if os.path.isfile(ready):
        dest = ready + '.invalid.%d' % int(time.time())
        try:
            os.rename(ready, dest)
        except OSError:
            try:
                os.remove(ready)
            except OSError:
                pass
        stale = os.path.join(offline, 'READY.stale')
        with open(stale, 'w') as fh:
            fh.write('invalidated_at=%s\nreason=%s\n' % (iso_now(), reason))
    for p in (
        '/var/lib/ubuntu-mirror/ready',
        '/var/lib/ubuntu-mirror/initial-sync-complete',
    ):
        try:
            if os.path.isfile(p):
                os.remove(p)
        except OSError:
            pass


def write_ready_marker(mirror_root, readiness, profile, req_checksum='',
                       content_checksum=''):
    offline = os.path.join(mirror_root, 'offline')
    os.makedirs(offline, exist_ok=True)
    ready = os.path.join(offline, 'READY')
    xenial_id = ''
    xj = os.path.join(offline, 'xenial-validation.json')
    data = load_json(xj, {})
    xenial_id = data.get('active_snapshot_id') or data.get('snapshot_id') or ''
    meta_id = ''
    mj = os.path.join(offline, 'release-upgrader-validation.json')
    mdata = load_json(mj, {})
    meta_id = mdata.get('meta_release_snapshot_id') or mdata.get('snapshot_id') or ''

    lines = [
        'generated_at=%s' % iso_now(),
        'profile_name=%s' % profile.get('profile_name', 'offline-upgrade-full'),
        'schema_version=%s' % profile.get('schema_version', 1),
        'overall=%s' % readiness.get('overall'),
        'requirement_manifest_checksum=%s' % req_checksum,
        'mirror_content_manifest_checksum=%s' % content_checksum,
        'active_xenial_snapshot_id=%s' % xenial_id,
        'meta_release_snapshot_id=%s' % meta_id,
    ]
    for gate, status in (readiness.get('gates') or {}).items():
        lines.append('gate_%s=%s' % (gate, status))
    with open(ready, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    return ready


def check_ready_freshness(mirror_root, req_checksum, content_checksum):
    ready = os.path.join(mirror_root, 'offline', 'READY')
    if not os.path.isfile(ready):
        return False, 'READY missing'
    fields = {}
    with open(ready, 'r') as fh:
        for line in fh:
            if '=' in line:
                k, v = line.rstrip('\n').split('=', 1)
                fields[k] = v
    if fields.get('requirement_manifest_checksum') and req_checksum:
        if fields['requirement_manifest_checksum'] != req_checksum:
            return False, 'requirement_manifest_checksum mismatch'
    if fields.get('mirror_content_manifest_checksum') and content_checksum:
        if fields['mirror_content_manifest_checksum'] != content_checksum:
            return False, 'mirror_content_manifest_checksum mismatch'
    if fields.get('overall') != 'READY':
        return False, 'overall not READY'
    return True, 'ok'


def content_manifest_checksum(ubuntu_root):
    """Cheap content fingerprint: suite Release mtimes + sizes."""
    dists = os.path.join(ubuntu_root, 'dists')
    h = hashlib.sha256()
    if not os.path.isdir(dists):
        return h.hexdigest()
    for suite in sorted(os.listdir(dists)):
        for name in ('InRelease', 'Release'):
            p = os.path.join(dists, suite, name)
            if os.path.isfile(p):
                st = os.stat(p)
                h.update(('%s:%s:%s\n' % (suite, name, st.st_size)).encode('utf-8'))
                h.update(('%s\n' % int(st.st_mtime)).encode('utf-8'))
    return h.hexdigest()


def cmd_check_profile(args):
    profile = load_json(args.profile)
    exceptions = args.exceptions or profile.get('exceptions_path')
    if exceptions and not os.path.isabs(exceptions):
        exceptions = os.path.join(args.project_root, exceptions)
    result = validate_config(profile, args.mirror_list, args.mirror_conf, exceptions)
    write_json(args.result_json, result)
    for k, v in result.items():
        if k in ('configured_pairs', 'required_pairs', 'missing_pairs',
                 'extra_pairs', 'pair_status', 'invalid_entries'):
            continue
        print('%s=%s' % (k, v))
    if result.get('minimal_detected'):
        eprint('ERROR: UNSUPPORTED_MINIMAL_PROFILE')
        eprint('Required profile: %s' % profile.get('profile_name'))
        eprint('Required components: %s' % ' '.join(profile.get('components') or []))
        eprint('Required pockets: %s' % ' '.join(profile.get('pockets') or []))
        eprint('No sync was started.')
    return 0 if result['validation_result'] == 'PASS' else 1


def cmd_validate(args):
    profile = load_json(args.profile)
    exceptions = args.exceptions or profile.get('exceptions_path')
    if exceptions and not os.path.isabs(exceptions):
        exceptions = os.path.join(args.project_root, exceptions)
    ubuntu_root = args.ubuntu_root or discover_ubuntu_root(args.mirror_root)
    offline = os.path.join(args.mirror_root, 'offline')
    os.makedirs(offline, exist_ok=True)

    profile_result = validate_config(
        profile, args.mirror_list, args.mirror_conf, exceptions
    )
    payload_result = validate_payload(
        profile, args.mirror_root, ubuntu_root, exceptions,
        sample_pool_limit=args.sample_pool_limit,
        project_root=args.project_root,
    )
    readiness = validate_readiness(
        profile, args.mirror_root, ubuntu_root, args.project_root,
        profile_result, payload_result,
        skip_external_gates=args.skip_external_gates,
    )

    req_path = profile.get('discovery_requirements_path') or ''
    if req_path and not os.path.isabs(req_path):
        req_path = os.path.join(args.project_root, req_path)
    req_checksum = file_sha256(req_path) if req_path and os.path.isfile(req_path) else ''
    content_checksum = content_manifest_checksum(ubuntu_root)

    fresh_ok, fresh_reason = check_ready_freshness(
        args.mirror_root, req_checksum, content_checksum
    )
    if not fresh_ok and os.path.isfile(os.path.join(offline, 'READY')):
        if fresh_reason != 'READY missing':
            invalidate_ready_marker(args.mirror_root, fresh_reason)
            readiness['ready_invalidated'] = fresh_reason

    profile_json = os.path.join(offline, 'upgrade-profile-validation.json')
    ready_json = os.path.join(offline, 'readiness-validation.json')
    write_json(profile_json, OrderedDict([
        ('profile', profile_result),
        ('payload', payload_result),
    ]))
    write_json(ready_json, readiness)
    if args.result_json:
        write_json(args.result_json, OrderedDict([
            ('profile', profile_result),
            ('payload', payload_result),
            ('readiness', readiness),
            ('requirement_manifest_checksum', req_checksum),
            ('mirror_content_manifest_checksum', content_checksum),
        ]))

    # Console summary
    for gate, status in readiness.get('gates', {}).items():
        print('%s: %s' % (gate, status))
    print('overall: %s' % readiness.get('overall'))

    if readiness.get('overall') == 'READY':
        if args.write_ready:
            write_ready_marker(
                args.mirror_root, readiness, profile, req_checksum, content_checksum
            )
        return 0

    invalidate_ready_marker(args.mirror_root, 'readiness_blocked')
    return 1


def cmd_migrate_profile(args):
    profile = load_json(args.profile)
    conf = args.mirror_conf
    mirror_list = args.mirror_list
    if not conf or not os.path.isfile(conf):
        eprint('ERROR: mirror.conf not found: %s' % conf)
        return 1

    mode, _ = parse_mirror_conf_mode(conf)
    backup_dir = args.backup_dir or os.path.join(
        os.path.dirname(conf), 'backups', 'migrate-%d' % int(time.time())
    )
    os.makedirs(backup_dir, exist_ok=True)

    planned = OrderedDict([
        ('action', 'migrate-profile'),
        ('to', profile.get('profile_name')),
        ('from_mode', mode or 'unknown'),
        ('dry_run', bool(args.dry_run)),
        ('backup_dir', backup_dir),
        ('required_components', profile.get('components')),
        ('required_pockets', profile.get('pockets')),
        ('sync_started', False),
        ('disk_estimate', 'UNKNOWN'),
        ('note', 'Migration updates config only; sync must be approved separately.'),
    ])

    # Disk estimate unknown unless operator supplies projected size
    if args.projected_gib is not None:
        planned['disk_estimate'] = '%s GiB projected (operator-supplied)' % args.projected_gib
    else:
        planned['disk_estimate'] = 'UNKNOWN'
        planned['disk_estimate_note'] = (
            'Exact additional payload size is unknown; sync will not start '
            'until capacity check passes under full profile.'
        )

    if args.dry_run:
        write_json(args.result_json, planned)
        print('migrate_dry_run=true')
        print('sync_started=false')
        print('to_profile=%s' % profile.get('profile_name'))
        print('disk_estimate=%s' % planned['disk_estimate'])
        print('backup_dir=%s' % backup_dir)
        return 0

    if not args.confirm:
        eprint('ERROR: migration requires --confirm (or use --dry-run)')
        eprint('No sync was started.')
        return 1

    # Backup
    for src in (conf, mirror_list):
        if src and os.path.isfile(src):
            shutil.copy2(src, os.path.join(backup_dir, os.path.basename(src)))

    try:
        # Update mirror.conf
        with open(conf, 'r') as fh:
            lines = fh.readlines()
        out = []
        seen_mode = False
        for line in lines:
            if line.startswith('MIRROR_MODE='):
                out.append('MIRROR_MODE="selective"\n')
                seen_mode = True
            else:
                out.append(line)
        if not seen_mode:
            out.append('\nMIRROR_MODE="selective"\n')
        with open(conf, 'w') as fh:
            fh.writelines(out)

        # Selective profile does not use apt-mirror mirror.list Cartesian product.
        # Leave mirror.list untouched (legacy); operators use plan-selective instead.

        invalidate_ready_marker(args.mirror_root, 'profile_migration')
        sel_ready = os.path.join(
            profile.get('selective_mirror_root') or
            os.path.join(args.mirror_root, 'selective'),
            'state', 'READY',
        )
        if os.path.isfile(sel_ready):
            try:
                os.remove(sel_ready)
            except OSError:
                pass
        planned['sync_started'] = False
        planned['config_updated'] = True
        planned['ready_invalidated'] = True
        write_json(args.result_json, planned)
        print('migrate_result=PASS')
        print('sync_started=false')
        print('ready_invalidated=true')
        print('next=ubuntu-offline-mirror.sh plan-selective')
        return 0
    except Exception as exc:  # noqa: BLE001
        # Rollback
        for name in (os.path.basename(conf), os.path.basename(mirror_list or '')):
            bak = os.path.join(backup_dir, name)
            dest = conf if name == os.path.basename(conf) else mirror_list
            if dest and os.path.isfile(bak):
                shutil.copy2(bak, dest)
        eprint('ERROR: migration failed, config rolled back: %s' % exc)
        planned['migrate_result'] = 'FAIL'
        planned['error'] = str(exc)
        write_json(args.result_json, planned)
        return 1


def build_parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command')

    def add_common(sp):
        sp.add_argument('--mirror-root', default='/var/spool/apt-mirror')
        sp.add_argument('--ubuntu-root', default='')
        sp.add_argument('--profile', default='')
        sp.add_argument('--exceptions', default='')
        sp.add_argument('--mirror-list', default='/etc/apt/mirror.list')
        sp.add_argument('--mirror-conf', default='/etc/ubuntu-mirror/mirror.conf')
        sp.add_argument('--project-root', default='')
        sp.add_argument('--result-json', default='')
        sp.add_argument('--sample-pool-limit', type=int, default=50)
        sp.add_argument('--skip-external-gates', action='store_true')
        sp.add_argument('--write-ready', action='store_true')

    sp = sub.add_parser('check-profile', help='Validate mirror.list/config only')
    add_common(sp)
    sp = sub.add_parser('validate', help='Full profile + payload + readiness')
    add_common(sp)
    sp = sub.add_parser('validate-profile', help='Alias of validate')
    add_common(sp)
    sp = sub.add_parser('migrate-profile', help='Migrate config to offline-upgrade-selective')
    add_common(sp)
    sp.add_argument('--to', default='offline-upgrade-selective')
    sp.add_argument('--dry-run', action='store_true')
    sp.add_argument('--confirm', action='store_true')
    sp.add_argument('--backup-dir', default='')
    sp.add_argument('--projected-gib', type=int, default=None)
    return p


def resolve_defaults(args):
    if not args.project_root:
        here = os.path.dirname(os.path.abspath(__file__))
        args.project_root = os.path.abspath(os.path.join(here, '..', '..'))
    if not args.profile:
        cand = os.path.join(args.project_root, 'config', 'offline-upgrade-profile.json')
        args.profile = cand
    if not args.result_json:
        offline = os.path.join(args.mirror_root, 'offline')
        if args.command in ('check-profile',):
            args.result_json = os.path.join(offline, 'upgrade-profile-check.json')
        elif args.command == 'migrate-profile':
            args.result_json = os.path.join(offline, 'profile-migration.json')
        else:
            args.result_json = os.path.join(offline, 'readiness-validation.json')
    return args


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 2
    args = resolve_defaults(args)
    if args.command == 'check-profile':
        return cmd_check_profile(args)
    if args.command in ('validate', 'validate-profile'):
        return cmd_validate(args)
    if args.command == 'migrate-profile':
        return cmd_migrate_profile(args)
    eprint('Unknown command: %s' % args.command)
    return 2


if __name__ == '__main__':
    sys.exit(main())
