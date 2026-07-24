#!/usr/bin/env python3
"""Derive offline upgrade requirement matrix from discovery artifacts.

Does not modify original hop exports. Writes:
  artifacts/upgrade-discovery/analysis/offline-upgrade-requirements.json
  artifacts/upgrade-discovery/analysis/offline-upgrade-requirements.tsv

Python 3.5+ compatible; standard library only.
"""
from __future__ import print_function, unicode_literals

import argparse
import csv
import hashlib
import json
import os
import re
import sys
from collections import Counter, OrderedDict, defaultdict

try:
    from urllib.parse import urlparse
except ImportError:  # pragma: no cover
    from urlparse import urlparse  # type: ignore

HOPS = (
    'xenial-to-bionic',
    'bionic-to-focal',
    'focal-to-jammy',
    'jammy-to-noble',
)

HOP_OS = OrderedDict([
    ('xenial-to-bionic', ('16.04', '18.04', 'xenial', 'bionic')),
    ('bionic-to-focal', ('18.04', '20.04', 'bionic', 'focal')),
    ('focal-to-jammy', ('20.04', '22.04', 'focal', 'jammy')),
    ('jammy-to-noble', ('22.04', '24.04', 'jammy', 'noble')),
])

SUITE_RE = re.compile(r'/dists/([^/]+)/')
POOL_COMP_RE = re.compile(r'/pool/([^/]+)/')
DISTS_COMP_RE = re.compile(r'/dists/[^/]+/([^/]+)/')


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def suite_from_url(url):
    if not url:
        return ''
    m = SUITE_RE.search(url)
    return m.group(1) if m else ''


def pocket_from_suite(suite):
    if not suite:
        return ''
    if '-' not in suite:
        return 'base'
    return suite.split('-', 1)[1]


def normalize_pocket(pocket):
    if pocket in ('', 'release'):
        return 'base'
    return pocket


def component_from_url(url):
    if not url:
        return ''
    m = DISTS_COMP_RE.search(url)
    if m and m.group(1) not in ('InRelease', 'Release', 'Release.gpg'):
        return m.group(1)
    m = POOL_COMP_RE.search(url)
    return m.group(1) if m else ''


def classify_url(url):
    path = urlparse(url).path or ''
    lower = path.lower()
    base = path.rsplit('/', 1)[-1]
    if 'meta-release' in lower:
        return 'meta-release'
    if path.endswith('.deb') or '/pool/' in path:
        return 'pool_deb'
    if '/by-hash/' in path:
        return 'by-hash'
    if 'dist-upgrader' in path:
        if path.endswith('.tar.gz.gpg') or (base.endswith('.gpg') and 'tar.gz' in base):
            return 'release_upgrader_gpg'
        if path.endswith('.tar.gz'):
            return 'release_upgrader_tarball'
        return 'dist-upgrader'
    if base == 'InRelease':
        return 'InRelease'
    if base == 'Release.gpg':
        return 'Release.gpg'
    if base == 'Release':
        return 'Release'
    if 'Translation' in base:
        return 'Translation'
    if '/dep11/' in path or base.startswith('Components-'):
        return 'DEP-11'
    if '/cnf/' in path or base.startswith('Commands-'):
        return 'CNF'
    if base.startswith('Packages'):
        return 'Packages'
    if base.startswith('Sources'):
        return 'Sources'
    return 'other'


def read_tsv(path):
    if not os.path.isfile(path):
        return []
    with open(path, 'r') as fh:
        return list(csv.DictReader(fh, delimiter='\t'))


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def series_from_suite(suite):
    if not suite:
        return ''
    return suite.split('-', 1)[0]


def derive(discovery_root, output_dir, profile_path=None):
    os.makedirs(output_dir, exist_ok=True)
    pairs = OrderedDict()  # (series, pocket, component, arch) -> stats
    hop_rows = []
    url_type_counts = Counter()
    components = set()
    pockets = set()
    suites = set()
    arches = set()
    by_hash_count = 0
    pool_count = 0
    package_by_component = Counter()
    urls_by_pocket = Counter()
    pool_by_component = Counter()
    collection_artifacts = []
    repaired_post_hop = []

    for hop in HOPS:
        hop_dir = os.path.join(discovery_root, hop)
        urls_path = os.path.join(hop_dir, 'required-urls.tsv')
        pkgs_path = os.path.join(hop_dir, 'required-packages.tsv')
        files_path = os.path.join(hop_dir, 'required-files.tsv')
        export_path = os.path.join(hop_dir, 'export-summary.json')
        evidence_path = os.path.join(hop_dir, 'evidence.json')

        urls = read_tsv(urls_path)
        pkgs = read_tsv(pkgs_path)
        files = read_tsv(files_path)
        export = {}
        if os.path.isfile(export_path):
            with open(export_path, 'r') as fh:
                export = json.load(fh)

        hop_pkg_count = len(pkgs)
        hop_url_count = len(urls)
        hop_by_hash = 0
        hop_pool = 0
        hop_components = set()
        hop_pockets = set()
        hop_suites = set()
        hop_arches = set()

        for row in urls:
            url = row.get('original_url') or row.get('final_url') or ''
            utype = classify_url(url)
            url_type_counts[utype] += 1
            suite = suite_from_url(url)
            pocket = normalize_pocket(pocket_from_suite(suite))
            component = component_from_url(url)
            series = series_from_suite(suite)

            if utype == 'by-hash':
                hop_by_hash += 1
                by_hash_count += 1
            if utype == 'pool_deb':
                hop_pool += 1
                pool_count += 1
                if component:
                    pool_by_component[component] += 1

            if suite:
                suites.add(suite)
                hop_suites.add(suite)
            if pocket:
                pockets.add(pocket)
                hop_pockets.add(pocket)
                urls_by_pocket[pocket] += 1
            if component:
                components.add(component)
                hop_components.add(component)

            # Architecture from by-hash binary-* paths
            m = re.search(r'/binary-([^/]+)/', urlparse(url).path or '')
            arch = m.group(1) if m else ''
            if arch:
                arches.add(arch)
                hop_arches.add(arch)

            if series and pocket and component:
                key = (series, pocket, component, arch or 'amd64')
                if key not in pairs:
                    pairs[key] = {
                        'series': series,
                        'pocket': pocket,
                        'component': component,
                        'architecture': arch or 'amd64',
                        'suite': suite if pocket != 'base' else series,
                        'url_count': 0,
                        'by_hash_count': 0,
                        'pool_file_count': 0,
                        'package_count': 0,
                        'metadata_types': set(),
                        'hops': set(),
                        'status': 'REQUIRED',
                    }
                pairs[key]['url_count'] += 1
                pairs[key]['hops'].add(hop)
                pairs[key]['metadata_types'].add(utype)
                if utype == 'by-hash':
                    pairs[key]['by_hash_count'] += 1
                if utype == 'pool_deb':
                    pairs[key]['pool_file_count'] += 1

        for row in pkgs:
            component = (row.get('component') or '').strip()
            arch = (row.get('architecture') or '').strip()
            if component:
                package_by_component[component] += 1
                components.add(component)
            if arch and arch != 'all':
                arches.add(arch)
                hop_arches.add(arch)
            elif arch == 'all':
                hop_arches.add('all')
            evidence = (row.get('evidence_source') or '').strip()
            if evidence == 'apt_archives':
                collection_artifacts.append({
                    'hop': hop,
                    'kind': 'apt_archives',
                    'package': row.get('package') or '',
                    'sha256': row.get('sha256') or '',
                })

        for row in files:
            if (row.get('evidence_source') or '') == 'post_hop_download':
                repaired_post_hop.append({
                    'hop': hop,
                    'filename': row.get('filename') or '',
                    'sha256': row.get('sha256') or '',
                    'provenance': 'repaired_post_hop',
                })

        from_os, to_os, from_series, to_series = HOP_OS[hop]
        hop_rows.append(OrderedDict([
            ('source_hop', hop),
            ('from_os', from_os),
            ('to_os', to_os),
            ('from_series', from_series),
            ('to_series', to_series),
            ('package_count', hop_pkg_count),
            ('url_count', hop_url_count),
            ('by_hash_count', hop_by_hash),
            ('pool_file_count', hop_pool),
            ('components', sorted(hop_components)),
            ('pockets', sorted(hop_pockets)),
            ('suites', sorted(hop_suites)),
            ('architectures', sorted(hop_arches)),
            ('validation', export.get('validation') or 'UNKNOWN'),
            ('evidence_path', evidence_path if os.path.isfile(evidence_path) else ''),
            ('required_urls_path', urls_path),
            ('required_packages_path', pkgs_path),
            ('required_files_path', files_path),
        ]))

    # Structural Release-chain pairs: every series × pocket × component for
    # repository metadata even when discovery only hit by-hash/InRelease.
    structural = []
    for series in ('xenial', 'bionic', 'focal', 'jammy', 'noble'):
        for pocket in ('base', 'updates', 'security', 'backports'):
            for component in sorted(components) or ('main', 'restricted', 'universe', 'multiverse'):
                key = (series, pocket, component, 'amd64')
                if key not in pairs:
                    structural.append({
                        'series': series,
                        'pocket': pocket,
                        'component': component,
                        'architecture': 'amd64',
                        'suite': series if pocket == 'base' else '%s-%s' % (series, pocket),
                        'url_count': 0,
                        'by_hash_count': 0,
                        'pool_file_count': 0,
                        'package_count': 0,
                        'metadata_types': ['Release_chain'],
                        'hops': [],
                        'status': 'STRUCTURAL_REQUIRED',
                        'note': 'Ubuntu repository Release chain for offline apt',
                    })

    # Ensure discovery-seen components are all present
    required_components = sorted(components) if components else [
        'main', 'restricted', 'universe', 'multiverse'
    ]
    required_pockets = sorted(pockets) if pockets else [
        'base', 'updates', 'security', 'backports'
    ]
    # Always require full four components for offline upgrade profile
    for c in ('main', 'restricted', 'universe', 'multiverse'):
        if c not in required_components:
            required_components.append(c)
    required_components = sorted(set(required_components))
    for p in ('base', 'updates', 'security', 'backports'):
        if p not in required_pockets:
            required_pockets.append(p)
    required_pockets = sorted(set(required_pockets), key=lambda x: (
        ['base', 'updates', 'security', 'backports'].index(x)
        if x in ('base', 'updates', 'security', 'backports') else 99
    ))

    required_arches = sorted(a for a in arches if a and a != 'all') or ['amd64']

    pair_list = []
    for key in sorted(pairs.keys()):
        info = pairs[key]
        pair_list.append(OrderedDict([
            ('series', info['series']),
            ('pocket', info['pocket']),
            ('component', info['component']),
            ('architecture', info['architecture']),
            ('suite', info['suite']),
            ('status', info['status']),
            ('url_count', info['url_count']),
            ('by_hash_count', info['by_hash_count']),
            ('pool_file_count', info['pool_file_count']),
            ('package_count', info['package_count']),
            ('metadata_types', sorted(info['metadata_types']),),
            ('hops', sorted(info['hops'])),
            ('classification', 'discovery'),
        ]))
    for item in structural:
        pair_list.append(OrderedDict([
            ('series', item['series']),
            ('pocket', item['pocket']),
            ('component', item['component']),
            ('architecture', item['architecture']),
            ('suite', item['suite']),
            ('status', item['status']),
            ('url_count', 0),
            ('by_hash_count', 0),
            ('pool_file_count', 0),
            ('package_count', 0),
            ('metadata_types', item['metadata_types']),
            ('hops', []),
            ('classification', 'structural_release_chain'),
            ('note', item.get('note', '')),
        ]))

    profile = {}
    if profile_path and os.path.isfile(profile_path):
        with open(profile_path, 'r') as fh:
            profile = json.load(fh)

    profile_components = set(profile.get('components') or required_components)
    profile_pockets = set(profile.get('pockets') or required_pockets)
    # Normalize profile pocket naming
    profile_pockets = {normalize_pocket(p) for p in profile_pockets}

    discovery_pairs = {
        (p['series'], p['pocket'], p['component'])
        for p in pair_list
        if p['status'] == 'REQUIRED' and p.get('url_count', 0) > 0
    }
    supported = []
    unsupported = []
    profile_series = set(profile.get('series') or [])
    for series, pocket, component in sorted(discovery_pairs):
        if profile:
            ok = (
                series in profile_series
                and pocket in profile_pockets
                and component in profile_components
            )
        else:
            ok = True
        entry = '%s/%s/%s' % (series, pocket, component)
        if ok:
            supported.append(entry)
        else:
            unsupported.append(entry)

    result = OrderedDict([
        ('schema_version', 1),
        ('generated_by', 'derive_upgrade_requirements.py'),
        ('discovery_root', os.path.abspath(discovery_root)),
        ('profile_name', profile.get('profile_name', 'offline-upgrade-full')),
        ('profile_schema_version', profile.get('schema_version', 1)),
        ('discovered_hops', list(HOPS)),
        ('required_suites', sorted(suites)),
        ('required_pockets', required_pockets),
        ('required_components', required_components),
        ('required_architectures', required_arches),
        ('requirement_pairs', pair_list),
        ('supported_requirement_pairs', supported),
        ('unsupported_requirement_pairs', unsupported),
        ('packages_by_component', OrderedDict(sorted(package_by_component.items()))),
        ('urls_by_pocket', OrderedDict(sorted(urls_by_pocket.items()))),
        ('pool_files_by_component', OrderedDict(sorted(pool_by_component.items()))),
        ('url_type_counts', OrderedDict(sorted(url_type_counts.items()))),
        ('totals', OrderedDict([
            ('by_hash_count', by_hash_count),
            ('pool_file_count', pool_count),
            ('requirement_pairs_discovery', sum(
                1 for p in pair_list if p['classification'] == 'discovery'
            )),
            ('requirement_pairs_structural', sum(
                1 for p in pair_list
                if p['classification'] == 'structural_release_chain'
            )),
            ('collection_artifacts', len(collection_artifacts)),
            ('repaired_post_hop', len(repaired_post_hop)),
        ])),
        ('per_hop', hop_rows),
        ('collection_artifacts_sample', collection_artifacts[:20]),
        ('repaired_post_hop_sample', repaired_post_hop[:20]),
        ('reject_mirror_modes', profile.get('rejected_modes', ['minimal'])),
        ('validation_result', 'PASS' if len(unsupported) == 0 else 'FAIL'),
    ])

    json_path = os.path.join(output_dir, 'offline-upgrade-requirements.json')
    tsv_path = os.path.join(output_dir, 'offline-upgrade-requirements.tsv')

    with open(json_path, 'w') as fh:
        json.dump(result, fh, indent=2, sort_keys=False)
        fh.write('\n')

    with open(tsv_path, 'w') as fh:
        writer = csv.writer(fh, delimiter='\t')
        writer.writerow([
            'source_hop', 'target_series', 'suite', 'pocket', 'component',
            'architecture', 'metadata_types', 'package_count', 'url_count',
            'by_hash_count', 'pool_file_count', 'status', 'classification',
            'discovery_evidence_path',
        ])
        # Per discovery pair rows
        for p in pair_list:
            hops = p.get('hops') or ['*']
            for hop in hops:
                target = ''
                if hop in HOP_OS:
                    target = HOP_OS[hop][3]
                writer.writerow([
                    hop,
                    target,
                    p.get('suite', ''),
                    p.get('pocket', ''),
                    p.get('component', ''),
                    p.get('architecture', ''),
                    ','.join(p.get('metadata_types') or []),
                    p.get('package_count', 0),
                    p.get('url_count', 0),
                    p.get('by_hash_count', 0),
                    p.get('pool_file_count', 0),
                    p.get('status', ''),
                    p.get('classification', ''),
                    os.path.join(discovery_root, hop, 'evidence.json') if hop != '*' else '',
                ])

    # Checksums of outputs for READY marker
    result['output_checksums'] = OrderedDict([
        ('offline-upgrade-requirements.json', file_sha256(json_path)),
        ('offline-upgrade-requirements.tsv', file_sha256(tsv_path)),
    ])
    with open(json_path, 'w') as fh:
        json.dump(result, fh, indent=2, sort_keys=False)
        fh.write('\n')

    eprint('Wrote %s' % json_path)
    eprint('Wrote %s' % tsv_path)
    eprint('validation_result=%s unsupported=%d' % (
        result['validation_result'], len(result['unsupported_requirement_pairs'])
    ))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--discovery-root',
        default='artifacts/upgrade-discovery',
        help='Path to upgrade-discovery artifacts root',
    )
    parser.add_argument(
        '--output-dir',
        default='',
        help='Output directory (default: <discovery-root>/analysis)',
    )
    parser.add_argument(
        '--profile',
        default='config/offline-upgrade-profile.json',
        help='Offline upgrade profile JSON (SSOT)',
    )
    args = parser.parse_args(argv)
    output_dir = args.output_dir or os.path.join(args.discovery_root, 'analysis')
    profile = args.profile if os.path.isfile(args.profile) else None
    result = derive(args.discovery_root, output_dir, profile_path=profile)
    return 0 if result.get('validation_result') == 'PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
