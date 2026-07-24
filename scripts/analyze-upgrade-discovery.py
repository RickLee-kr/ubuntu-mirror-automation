#!/usr/bin/env python3
"""Read-only analyzer for artifacts/upgrade-discovery manifests.

Does not modify original hop exports. Writes derived TSV/JSON under
artifacts/upgrade-discovery/analysis/ (or --output-dir).

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
from collections import Counter, defaultdict, OrderedDict

try:
    from urllib.parse import urlparse, urlunparse, unquote
except ImportError:  # pragma: no cover - Python 2 leftover
    from urlparse import urlparse, urlunparse  # type: ignore
    from urllib import unquote  # type: ignore

HOPS = (
    'xenial-to-bionic',
    'bionic-to-focal',
    'focal-to-jammy',
    'jammy-to-noble',
)

EXPECTED_INDEX = OrderedDict([
    ('xenial-to-bionic', {
        'validation': 'PASS',
        'required_packages': 1106,
        'required_files': 1143,
        'required_urls': 860,
        'unresolved_packages': 0,
        'unresolved_files': 0,
        'failed_requests_total': 1,
        'failed_requests_blocking': 0,
        'failed_requests_non_blocking': 1,
        'recovered_post_hop': True,
    }),
    ('bionic-to-focal', {
        'validation': 'PASS',
        'required_packages': 1183,
        'required_files': 1238,
        'required_urls': 964,
        'unresolved_packages': 0,
        'unresolved_files': 0,
        'recovered_post_hop': True,
    }),
    ('focal-to-jammy', {
        'validation': 'PASS',
        'required_packages': 1166,
        'required_files': 1220,
        'required_urls': 965,
        'unresolved_packages': 0,
        'unresolved_files': 0,
        'recovered_post_hop': True,
    }),
    ('jammy-to-noble', {
        'validation': 'PASS',
        'required_packages': 1166,
        'required_files': 1222,
        'required_urls': 961,
        'unresolved_packages': 0,
        'unresolved_files': 0,
        'recovered_post_hop': True,
    }),
])

HOP_MANIFESTS = (
    'required-packages.tsv',
    'required-files.tsv',
    'required-urls.tsv',
    'unresolved-packages.tsv',
    'unresolved-files.tsv',
    'failed-requests.tsv',
    'evidence.json',
    'validation.txt',
    'export-summary.json',
    'checksums.sha256',
)


def eprint(*args):
    print(*args, file=sys.stderr)


def read_tsv(path):
    with open(path, 'r') as fh:
        return list(csv.DictReader(fh, delimiter='\t'))


def write_tsv(path, fieldnames, rows):
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open(path, 'w') as fh:
        writer = csv.DictWriter(
            fh, fieldnames=fieldnames, delimiter='\t', lineterminator='\n',
            extrasaction='ignore')
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def count_data_rows(path):
    with open(path, 'r') as fh:
        lines = fh.readlines()
    if not lines:
        return 0
    return max(0, len(lines) - 1)


def suite_from_url(url):
    if not url:
        return ''
    m = re.search(r'/dists/([^/]+)/', url)
    return m.group(1) if m else ''


def pocket_from_suite(suite):
    if not suite:
        return ''
    if '-' not in suite:
        return 'release'
    return suite.split('-', 1)[1]


def component_from_url(url):
    if not url:
        return ''
    m = re.search(r'/dists/[^/]+/([^/]+)/', url)
    if m and m.group(1) not in ('InRelease', 'Release', 'Release.gpg'):
        return m.group(1)
    m = re.search(r'/pool/([^/]+)/', url)
    return m.group(1) if m else ''


def classify_url(url):
    path = urlparse(url).path or ''
    lower = path.lower()
    base = path.rsplit('/', 1)[-1]
    if 'meta-release' in lower:
        return 'meta-release'
    # Prefer concrete package/index types before substring matches on package names.
    if path.endswith('.deb') or '/pool/' in path:
        return 'pool_deb'
    if '/by-hash/' in path:
        return 'by-hash'
    if 'dist-upgrader' in path:
        if path.endswith('.tar.gz.gpg') or (base.endswith('.gpg') and 'tar.gz' in base):
            return 'release_upgrader_gpg'
        if path.endswith('.tar.gz'):
            return 'release_upgrader_tarball'
        return 'release_upgrader_other'
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
        return 'cnf'
    if base.startswith('Packages'):
        return 'Packages'
    if base.startswith('Sources'):
        return 'Sources'
    return 'other'


def classify_file_row(row):
    ftype = row.get('file_type') or ''
    url = row.get('original_url') or ''
    path = urlparse(url).path if url else ''
    local = row.get('local_path') or ''
    name = row.get('filename') or ''

    if ftype == 'deb' or name.endswith('.deb') or path.endswith('.deb'):
        return 'deb_package'
    if ftype == 'by_hash' or '/by-hash/' in path:
        return 'by_hash'
    if ftype == 'inrelease' or path.endswith('/InRelease'):
        return 'ubuntu_repository_metadata'
    if ftype == 'release_upgrader' or 'dist-upgrader' in path:
        if name.endswith('.gpg') or path.endswith('.gpg'):
            return 'release_upgrader_signature'
        if name.endswith('.tar.gz') or path.endswith('.tar.gz'):
            return 'release_upgrader_tarball'
        return 'release_upgrader_metadata'
    if 'meta-release' in (url + name).lower():
        return 'release_upgrader_metadata'
    if '/dep11/' in path:
        return 'apt_index_dep11'
    if '/cnf/' in path:
        return 'apt_index_cnf'
    if 'Packages' in name or '/binary-' in path:
        return 'apt_index'
    if local.startswith('/var/log') or '/tmp/' in local:
        return 'log_or_temp'
    if re.search(r'(stellar|aella|/opt/aella)', (url + local + name), re.I):
        return 'stellar_aella_application'
    if path.startswith('/etc/') or local.startswith('/etc/'):
        return 'configuration_file'
    if ftype:
        return 'other_' + ftype
    return 'other'


def is_vendorish(text):
    return bool(re.search(r'(stellar|aella|gdc-platform)', text or '', re.I))


def mirror_coverage_for_url(url):
    """Map a collected URL to coverage vs current repo implementation."""
    host = urlparse(url).hostname or ''
    path = urlparse(url).path or ''
    utype = classify_url(url)

    if host in ('archive.ubuntu.com',):
        if utype == 'by-hash':
            return 'PARTIALLY_COVERED', (
                'apt-mirror syncs named indexes/debs under archive.ubuntu.com; '
                'by-hash tree is not explicitly seeded (seed-dists-metadata.sh '
                'fetches Packages/InRelease only)')
        if utype.startswith('release_upgrader'):
            return 'COVERED', (
                'ubuntu-offline-mirror.sh syncs dist-upgrader tarball/gpg into '
                'dists/<target>-updates/main/dist-upgrader-all/current/')
        if utype in ('InRelease', 'Release', 'Release.gpg', 'Packages',
                     'pool_deb', 'Translation', 'DEP-11', 'cnf'):
            return 'COVERED', (
                'templates/mirror.list + apt-mirror cover archive suites; '
                'nginx /ubuntu/ aliases archive.ubuntu.com/ubuntu/')
        return 'PARTIALLY_COVERED', 'archive host path may be served via /ubuntu/'

    if host == 'security.ubuntu.com':
        if utype == 'by-hash':
            return 'PARTIALLY_COVERED', (
                'security suites are mirrored as <codename>-security from '
                'archive.ubuntu.com; client-setup rewrites security host to '
                'local /ubuntu/, but nginx has no security.ubuntu.com vhost and '
                'by-hash is not explicitly preserved')
        return 'PARTIALLY_COVERED', (
            'content expected via archive *-security suites + client host rewrite; '
            'no nginx security.ubuntu.com alias; raw security hostname requests fail '
            'unless sources/meta rewrite is applied')

    if host == 'old-releases.ubuntu.com':
        return 'COVERED', (
            'sync_legacy_releases.py probes old-releases when archive is incomplete, '
            'promotes COMPLETE Xenial snapshots into the canonical archive.ubuntu.com '
            'tree; client rewrites old-releases → /ubuntu; optional nginx Host alias')

    if host == 'changelogs.ubuntu.com':
        if 'meta-release' in path:
            return 'COVERED', (
                'ubuntu-offline-mirror syncs meta-release-lts to /offline/ and '
                'rewrites UpgradeTool URLs; nginx serves /offline/')
        return 'PARTIALLY_COVERED', 'changelogs host not published; announcements optional'

    if not host:
        return 'NOT_REQUIRED', 'no HTTP URL (local apt_archives / state only)'

    return 'NEEDS_DECISION', 'unexpected host: ' + host


def load_hop(discovery_root, hop):
    base = os.path.join(discovery_root, hop)
    data = {
        'hop': hop,
        'packages': read_tsv(os.path.join(base, 'required-packages.tsv')),
        'files': read_tsv(os.path.join(base, 'required-files.tsv')),
        'urls': read_tsv(os.path.join(base, 'required-urls.tsv')),
        'unresolved_packages': read_tsv(os.path.join(base, 'unresolved-packages.tsv')),
        'unresolved_files': read_tsv(os.path.join(base, 'unresolved-files.tsv')),
        'failed_requests': read_tsv(os.path.join(base, 'failed-requests.tsv')),
    }
    with open(os.path.join(base, 'evidence.json'), 'r') as fh:
        data['evidence'] = json.load(fh)
    with open(os.path.join(base, 'export-summary.json'), 'r') as fh:
        data['export_summary'] = json.load(fh)
    with open(os.path.join(base, 'validation.txt'), 'r') as fh:
        data['validation_txt'] = fh.read()
    return data


def recount_hop(hop_data):
    return {
        'required_packages': len(hop_data['packages']),
        'required_files': len(hop_data['files']),
        'required_urls': len(hop_data['urls']),
        'unresolved_packages': len(hop_data['unresolved_packages']),
        'unresolved_files': len(hop_data['unresolved_files']),
        'failed_requests_total': len(hop_data['failed_requests']),
        'validation_pass': 'VALIDATION: PASS' in hop_data['validation_txt'],
        'recovered_post_hop': bool(hop_data['evidence'].get('recovered_post_hop')),
    }


def parse_index(path):
    rows = read_tsv(path)
    out = OrderedDict()
    for row in rows:
        hop = row['hop']
        out[hop] = row
    return out


def bool_from_index(value):
    return str(value).strip().lower() == 'true'


def analyze(discovery_root, output_dir):
    index_path = os.path.join(discovery_root, 'index.tsv')
    if not os.path.isfile(index_path):
        raise SystemExit('missing index.tsv under {}'.format(discovery_root))

    for hop in HOPS:
        hop_dir = os.path.join(discovery_root, hop)
        if not os.path.isdir(hop_dir):
            raise SystemExit('missing hop directory: {}'.format(hop_dir))
        for name in HOP_MANIFESTS:
            path = os.path.join(hop_dir, name)
            if not os.path.isfile(path):
                raise SystemExit('missing {}: {}'.format(hop, path))

    index = parse_index(index_path)
    hops_data = OrderedDict((hop, load_hop(discovery_root, hop)) for hop in HOPS)

    # --- integrity / recount ---
    identity_rows = []
    mismatches = []
    for hop in HOPS:
        recount = recount_hop(hops_data[hop])
        idx = index[hop]
        summary = hops_data[hop]['export_summary']
        checks = [
            ('required_packages', recount['required_packages'], int(idx['required_packages']), summary['required_packages']),
            ('required_files', recount['required_files'], int(idx['required_files']), summary['required_files']),
            ('required_urls', recount['required_urls'], int(idx['required_urls']), summary['required_urls']),
            ('unresolved_packages', recount['unresolved_packages'], int(idx['unresolved_packages']), summary['unresolved_packages']),
            ('unresolved_files', recount['unresolved_files'], int(idx['unresolved_files']), summary['unresolved_files']),
            ('failed_requests_total', recount['failed_requests_total'], int(idx.get('failed_requests_total', idx.get('failed_requests', -1))), summary.get('failed_requests_total', summary.get('failed_requests'))),
        ]
        for field, actual, index_v, summary_v in checks:
            ok = (actual == index_v == int(summary_v))
            if not ok:
                mismatches.append((hop, field, actual, index_v, summary_v))
            identity_rows.append({
                'hop': hop,
                'field': field,
                'manifest_recount': actual,
                'index_tsv': index_v,
                'export_summary': int(summary_v),
                'match': 'true' if ok else 'false',
            })
        exp = EXPECTED_INDEX[hop]
        for key, expected in exp.items():
            if key == 'recovered_post_hop':
                actual = recount['recovered_post_hop']
                index_v = bool_from_index(idx['recovered_post_hop'])
            elif key == 'validation':
                actual = 'PASS' if recount['validation_pass'] else 'FAIL'
                index_v = idx['validation']
            else:
                actual = recount.get(key, int(idx.get(key, -1)))
                if key.startswith('failed_requests') and key != 'failed_requests_total':
                    actual = int(idx.get(key, summary.get(key, -1)))
                    index_v = int(idx.get(key, -1))
                else:
                    if key in recount:
                        actual = recount[key]
                    else:
                        actual = int(idx.get(key, -1))
                    index_v = int(idx[key]) if key != 'validation' else idx[key]
                    if key != 'validation':
                        expected = int(expected)
            if actual != expected or index_v != expected:
                mismatches.append((hop, 'expected:' + key, actual, expected, index_v))

    # --- packages ---
    all_pkg_rows = []
    pkg_names_by_hop = {}
    pkg_sha_by_hop = {}
    urlenc_collisions = []
    suspect_packages = []
    vendor_packages = []

    for hop, data in hops_data.items():
        names = set()
        shas = set()
        decoded_map = defaultdict(set)
        for row in data['packages']:
            pkg = row.get('package') or ''
            names.add(pkg)
            decoded_map[unquote(pkg)].add(pkg)
            if row.get('sha256'):
                shas.add(row['sha256'])
            suite = suite_from_url(row.get('original_url') or row.get('final_url') or '')
            component = row.get('component') or component_from_url(row.get('original_url') or '')
            host = row.get('repository_host') or (urlparse(row.get('original_url') or '').hostname or '')
            mirror_need = 'mirror_deb'
            if not row.get('original_url') and row.get('evidence_source') == 'apt_archives':
                mirror_need = 'mirror_deb_via_archives_no_url'
            if row.get('downloaded') == 'true' and row.get('installed') == 'false':
                mirror_need = 'downloaded_not_installed'
            out = {
                'hop': hop,
                'package': pkg,
                'package_decoded': unquote(pkg),
                'version': row.get('version') or '',
                'architecture': row.get('architecture') or '',
                'source_package': row.get('source_package') or '',
                'filename': unquote(row.get('filename') or ''),
                'repository_host': host,
                'suite': suite,
                'pocket': pocket_from_suite(suite),
                'component': component,
                'size_bytes': row.get('size_bytes') or '',
                'sha256': row.get('sha256') or '',
                'original_url': row.get('original_url') or '',
                'requested': row.get('requested') or '',
                'downloaded': row.get('downloaded') or '',
                'installed': row.get('installed') or '',
                'evidence_source': row.get('evidence_source') or '',
                'mirror_need': mirror_need,
                'vendor_class': 'stellar_aella' if is_vendorish(
                    ' '.join([pkg, row.get('source_package') or '', row.get('filename') or '', row.get('original_url') or ''])
                ) else 'ubuntu_or_unknown',
            }
            all_pkg_rows.append(out)
            if '/' in pkg or pkg.endswith('.deb') or ' ' in pkg:
                suspect_packages.append(out)
            if out['vendor_class'] != 'ubuntu_or_unknown':
                vendor_packages.append(out)
        for decoded, variants in decoded_map.items():
            if len(variants) > 1:
                urlenc_collisions.append({
                    'hop': hop,
                    'package_decoded': decoded,
                    'variants': '|'.join(sorted(variants)),
                    'variant_count': str(len(variants)),
                })
        pkg_names_by_hop[hop] = names
        pkg_sha_by_hop[hop] = shas

    common_names = set.intersection(*[pkg_names_by_hop[h] for h in HOPS])
    common_decoded = set.intersection(*[
        set(unquote(n) for n in pkg_names_by_hop[h]) for h in HOPS
    ])
    hop_specific_rows = []
    for hop in HOPS:
        others = set.union(*[pkg_names_by_hop[h] for h in HOPS if h != hop])
        only = pkg_names_by_hop[hop] - others
        for name in sorted(only):
            hop_specific_rows.append({'hop': hop, 'package': name, 'scope': 'hop_unique_name'})

    version_diff_rows = []
    vers = defaultdict(set)
    for row in all_pkg_rows:
        vers[(row['package_decoded'], row['architecture'])].add((row['hop'], row['version']))
    for (name, arch), items in sorted(vers.items()):
        versions = sorted({v for _, v in items if v})
        if len(versions) > 1:
            version_diff_rows.append({
                'package': name,
                'architecture': arch,
                'version_count': str(len(versions)),
                'versions': '|'.join(versions),
                'hops': '|'.join(sorted({h for h, _ in items})),
            })

    # --- files ---
    all_file_rows = []
    file_type_counter = Counter()
    recovered_rows = []
    for hop, data in hops_data.items():
        repair_notes = data['evidence'].get('repair_notes') or {}
        recovered_count = int(repair_notes.get('recovered_count') or 0)
        for row in data['files']:
            cat = classify_file_row(row)
            file_type_counter[cat] += 1
            ev = row.get('evidence_source') or ''
            recovery = 'during_hop_or_archives'
            if 'repair' in ev or data['evidence'].get('checksum_source') == 'post_hop_download':
                # checksum_source is hop-global; mark metadata specially
                if cat in ('ubuntu_repository_metadata', 'by_hash', 'apt_index',
                           'apt_index_cnf', 'apt_index_dep11'):
                    recovery = 'checksum_may_be_post_hop'
            if recovered_count and cat in ('ubuntu_repository_metadata', 'by_hash'):
                recovery = 'eligible_post_hop_repair_target'
            out = {
                'hop': hop,
                'file_type': row.get('file_type') or '',
                'analysis_category': cat,
                'filename': row.get('filename') or '',
                'original_url': row.get('original_url') or '',
                'final_url': row.get('final_url') or '',
                'local_path': row.get('local_path') or '',
                'size_bytes': row.get('size_bytes') or '',
                'sha256': row.get('sha256') or '',
                'http_status': row.get('http_status') or '',
                'request_count': row.get('request_count') or '',
                'evidence_source': ev,
                'recovery_class': recovery,
                'mirror_payload': (
                    'required' if cat in (
                        'deb_package', 'by_hash', 'ubuntu_repository_metadata',
                        'release_upgrader_tarball', 'release_upgrader_signature',
                        'apt_index', 'apt_index_cnf', 'apt_index_dep11',
                    ) and (row.get('original_url') or cat == 'deb_package')
                    else 'not_required_local_only'
                ),
            }
            coverage, reason = mirror_coverage_for_url(out['original_url'])
            if not out['original_url'] and cat == 'deb_package':
                coverage, reason = 'COVERED', 'deb expected in apt-mirror pool if suite/component mirrored'
            out['coverage'] = coverage
            out['coverage_reason'] = reason
            all_file_rows.append(out)
            if recovery != 'during_hop_or_archives':
                recovered_rows.append(out)

    # --- urls ---
    all_url_rows = []
    host_counter = Counter()
    type_counter = Counter()
    suite_counter = Counter()
    pocket_counter = Counter()
    component_counter = Counter()
    status_counter = Counter()
    query_dup_bases = defaultdict(list)
    sha_to_urls = defaultdict(list)

    for hop, data in hops_data.items():
        for row in data['urls']:
            url = row.get('original_url') or ''
            parsed = urlparse(url)
            host = parsed.hostname or ''
            utype = classify_url(url)
            suite = suite_from_url(url)
            pocket = pocket_from_suite(suite)
            component = component_from_url(url)
            host_counter[host] += 1
            type_counter[utype] += 1
            if suite:
                suite_counter[suite] += 1
            if pocket:
                pocket_counter[pocket] += 1
            if component:
                component_counter[component] += 1
            status_counter[row.get('http_status') or ''] += 1
            base = urlunparse((parsed.scheme, parsed.netloc, parsed.path, '', '', ''))
            if parsed.query:
                query_dup_bases[base].append(url)
            if row.get('sha256'):
                sha_to_urls[row['sha256']].append((hop, url, row.get('size_bytes') or ''))
            coverage, reason = mirror_coverage_for_url(url)
            offline_must = 'must_mirror'
            if utype == 'by-hash':
                offline_must = 'must_mirror_or_named_index_fallback'
            if host == 'changelogs.ubuntu.com':
                offline_must = 'must_provide_via_offline_meta'
            out = {
                'hop': hop,
                'original_url': url,
                'final_url': row.get('final_url') or '',
                'hostname': host,
                'url_type': utype,
                'suite': suite,
                'pocket': pocket,
                'component': component,
                'http_status': row.get('http_status') or '',
                'size_bytes': row.get('size_bytes') or '',
                'sha256': row.get('sha256') or '',
                'local_path': row.get('local_path') or '',
                'redirected': 'true' if url != (row.get('final_url') or url) else 'false',
                'has_query': 'true' if parsed.query else 'false',
                'coverage': coverage,
                'coverage_reason': reason,
                'offline_requirement': offline_must,
                'hostname_rewrite': (
                    'client_or_meta_rewrite_to_/ubuntu/' if host in (
                        'archive.ubuntu.com', 'security.ubuntu.com', 'old-releases.ubuntu.com')
                    else ('offline_meta_path' if host == 'changelogs.ubuntu.com'
                          else 'special_handling')
                ),
            }
            all_url_rows.append(out)

    # failed requests
    failed_rows = []
    for hop, data in hops_data.items():
        for row in data['failed_requests']:
            failed_rows.append({
                'hop': hop,
                'original_url': row.get('original_url') or '',
                'final_url': row.get('final_url') or '',
                'http_status': row.get('http_status') or '',
                'reason': row.get('reason') or '',
                'file_type': row.get('file_type') or '',
                'classification': (
                    'COLLECTION_ARTIFACT_non_blocking_stale_by_hash'
                    if (row.get('file_type') == 'by_hash' and str(row.get('http_status')) == '404')
                    else 'failed_request'
                ),
            })

    # duplicate content
    duplicate_content_rows = []
    for sha, items in sorted(sha_to_urls.items()):
        urls = sorted({u for _, u, _ in items})
        hops = sorted({h for h, _, _ in items})
        if len(urls) > 1 or len(hops) > 1:
            duplicate_content_rows.append({
                'sha256': sha,
                'url_count': str(len(urls)),
                'hop_count': str(len(hops)),
                'hops': '|'.join(hops),
                'urls': '|'.join(urls[:5]),
                'size_bytes': items[0][2],
            })

    # coverage summary
    coverage_counter = Counter(r['coverage'] for r in all_url_rows)
    coverage_rows = []
    for cov, count in sorted(coverage_counter.items()):
        coverage_rows.append({
            'coverage': cov,
            'url_count': str(count),
            'share_of_required_urls': '{:.4f}'.format(count / float(len(all_url_rows)) if all_url_rows else 0),
        })
    # add synthetic rows for missing hosts of interest
    for host in ('changelogs.ubuntu.com', 'old-releases.ubuntu.com'):
        if host_counter.get(host, 0) == 0:
            coverage_rows.append({
                'coverage': 'NOT_PRESENT_IN_CAPTURE',
                'url_count': '0',
                'share_of_required_urls': '0',
                'note': host + ' absent from required-urls.tsv across all hops',
            })

    host_summary_rows = [
        {'hostname': host, 'url_count': str(count)}
        for host, count in host_counter.most_common()
    ]
    type_summary_rows = [
        {'url_type': utype, 'url_count': str(count)}
        for utype, count in type_counter.most_common()
    ]
    suite_summary_rows = [
        {'suite': suite, 'pocket': pocket_from_suite(suite), 'url_count': str(count)}
        for suite, count in suite_counter.most_common()
    ]
    component_summary_rows = [
        {'component': comp, 'url_count': str(count)}
        for comp, count in component_counter.most_common()
    ]

    # dedupe stats
    all_urls = [r['original_url'] for r in all_url_rows]
    unique_urls = set(all_urls)
    all_pkg_sha = [r['sha256'] for r in all_pkg_rows if r['sha256']]
    unique_pkg_sha = set(all_pkg_sha)
    all_file_sha = [r['sha256'] for r in all_file_rows if r['sha256']]
    unique_file_sha = set(all_file_sha)

    captured_bytes = sum(
        int(hops_data[h]['export_summary'].get('captured_bytes') or 0) for h in HOPS
    )
    pkg_bytes = sum(int(r['size_bytes'] or 0) for r in all_pkg_rows if str(r['size_bytes']).isdigit())

    # original checksum inventory (for "no mutation" proof)
    original_checksums = []
    for hop in HOPS:
        for name in HOP_MANIFESTS:
            path = os.path.join(discovery_root, hop, name)
            original_checksums.append({
                'path': os.path.relpath(path, discovery_root),
                'sha256': sha256_file(path),
                'size_bytes': str(os.path.getsize(path)),
            })
    original_checksums.append({
        'path': 'index.tsv',
        'sha256': sha256_file(index_path),
        'size_bytes': str(os.path.getsize(index_path)),
    })

    # component necessity from capture
    components_needed = sorted(component_counter.keys())
    pockets_needed = sorted(pocket_counter.keys())
    suites_needed = sorted(suite_counter.keys())

    summary = OrderedDict([
        ('schema_version', 1),
        ('discovery_root', os.path.abspath(discovery_root)),
        ('hops', list(HOPS)),
        ('validation', OrderedDict(
            (hop, 'PASS' if recount_hop(hops_data[hop])['validation_pass'] else 'FAIL')
            for hop in HOPS
        )),
        ('index_expected_match', len(mismatches) == 0),
        ('mismatches', [
            {'hop': h, 'field': f, 'manifest': a, 'expected_or_index': b, 'other': c}
            for (h, f, a, b, c) in mismatches
        ]),
        ('totals_raw', OrderedDict([
            ('required_packages', sum(len(hops_data[h]['packages']) for h in HOPS)),
            ('required_files', sum(len(hops_data[h]['files']) for h in HOPS)),
            ('required_urls', sum(len(hops_data[h]['urls']) for h in HOPS)),
            ('unresolved_packages', sum(len(hops_data[h]['unresolved_packages']) for h in HOPS)),
            ('unresolved_files', sum(len(hops_data[h]['unresolved_files']) for h in HOPS)),
            ('failed_requests', sum(len(hops_data[h]['failed_requests']) for h in HOPS)),
        ])),
        ('totals_deduped', OrderedDict([
            ('unique_package_sha256', len(unique_pkg_sha)),
            ('unique_package_names_raw', len(set(r['package'] for r in all_pkg_rows))),
            ('unique_package_names_decoded', len(set(r['package_decoded'] for r in all_pkg_rows))),
            ('common_package_names_raw', len(common_names)),
            ('common_package_names_decoded', len(common_decoded)),
            ('unique_file_sha256', len(unique_file_sha)),
            ('unique_urls', len(unique_urls)),
            ('urlenc_package_name_collisions', len(urlenc_collisions)),
            ('packages_with_cross_hop_version_diff', len(version_diff_rows)),
        ])),
        ('hosts', OrderedDict(host_counter.most_common())),
        ('url_types', OrderedDict(type_counter.most_common())),
        ('http_status', OrderedDict(status_counter.most_common())),
        ('suites_in_urls', suites_needed),
        ('pockets_in_urls', pockets_needed),
        ('components_in_urls', components_needed),
        ('file_analysis_categories', OrderedDict(file_type_counter.most_common())),
        ('coverage_url_counts', OrderedDict(coverage_counter.most_common())),
        ('vendor_packages_count', len(vendor_packages)),
        ('suspect_packages_count', len(suspect_packages)),
        ('query_string_url_count', sum(len(v) for v in query_dup_bases.values())),
        ('captured_bytes_sum', captured_bytes),
        ('package_size_bytes_sum', pkg_bytes),
        ('hop_export', OrderedDict(
            (hop, {
                'required_packages': len(hops_data[hop]['packages']),
                'required_files': len(hops_data[hop]['files']),
                'required_urls': len(hops_data[hop]['urls']),
                'unresolved_packages': len(hops_data[hop]['unresolved_packages']),
                'unresolved_files': len(hops_data[hop]['unresolved_files']),
                'failed_requests': len(hops_data[hop]['failed_requests']),
                'recovered_post_hop': bool(hops_data[hop]['evidence'].get('recovered_post_hop')),
                'checksum_source': hops_data[hop]['evidence'].get('checksum_source'),
                'repair_notes': hops_data[hop]['evidence'].get('repair_notes'),
                'captured_bytes': hops_data[hop]['export_summary'].get('captured_bytes'),
                'non_blocking_failure_reasons': hops_data[hop]['export_summary'].get(
                    'non_blocking_failure_reasons'),
            }) for hop in HOPS
        )),
        ('implementation_verdict', 'INSUFFICIENT'),
        ('implementation_verdict_rationale', [
            'apt-mirror archive suites cover most pool/*.deb and named dists metadata',
            'security.ubuntu.com host compatibility depends on client rewrite; nginx lacks security/old-releases vhosts',
            'by-hash objects were requested on every hop but are not explicitly synced/validated',
            'meta-release/changelogs URLs absent from this capture but offline-mirror provides /offline/meta-release-lts separately',
            'old-releases.ubuntu.com absent from capture (archive still served xenial); offline durability via sync_legacy_releases.py (P0-4)',
            'universe/multiverse/restricted/backports all appear in required URLs; minimal main+restricted is insufficient',
            'discovery payload (~3.45 GiB captured bodies) is not a substitute for full suite mirror size estimates (320 / 700-900 GiB)',
        ]),
    ])

    # final verdict refinement
    if coverage_counter.get('NOT_COVERED', 0) == 0 and coverage_counter.get('PARTIALLY_COVERED', 0) > 0:
        summary['implementation_verdict'] = 'INSUFFICIENT'
    if (
        coverage_counter.get('NOT_COVERED', 0) == 0
        and coverage_counter.get('PARTIALLY_COVERED', 0) == 0
        and mismatches == []
    ):
        summary['implementation_verdict'] = 'COMPLETE'
    elif coverage_counter.get('COVERED', 0) > 0 and (
        coverage_counter.get('PARTIALLY_COVERED', 0) > 0
        or host_counter.get('security.ubuntu.com', 0) > 0
    ):
        # Keep INSUFFICIENT for offline guarantees; expose PARTIAL as secondary label
        summary['implementation_verdict'] = 'INSUFFICIENT'
        summary['implementation_verdict_alias'] = 'PARTIAL_with_critical_gaps'

    if not os.path.isdir(output_dir):
        os.makedirs(output_dir)

    write_tsv(os.path.join(output_dir, 'index-identity.tsv'),
              ['hop', 'field', 'manifest_recount', 'index_tsv', 'export_summary', 'match'],
              identity_rows)
    write_tsv(os.path.join(output_dir, 'all-required-packages.tsv'),
              list(all_pkg_rows[0].keys()) if all_pkg_rows else ['hop'],
              all_pkg_rows)
    write_tsv(os.path.join(output_dir, 'all-required-files.tsv'),
              list(all_file_rows[0].keys()) if all_file_rows else ['hop'],
              all_file_rows)
    write_tsv(os.path.join(output_dir, 'all-required-urls.tsv'),
              list(all_url_rows[0].keys()) if all_url_rows else ['hop'],
              all_url_rows)
    write_tsv(os.path.join(output_dir, 'common-packages.tsv'),
              ['package'],
              [{'package': n} for n in sorted(common_decoded)])
    write_tsv(os.path.join(output_dir, 'hop-specific-packages.tsv'),
              ['hop', 'package', 'scope'],
              hop_specific_rows)
    write_tsv(os.path.join(output_dir, 'version-diff-packages.tsv'),
              ['package', 'architecture', 'version_count', 'versions', 'hops'],
              version_diff_rows)
    write_tsv(os.path.join(output_dir, 'urlenc-package-collisions.tsv'),
              ['hop', 'package_decoded', 'variants', 'variant_count'],
              urlenc_collisions)
    write_tsv(os.path.join(output_dir, 'url-host-summary.tsv'),
              ['hostname', 'url_count'],
              host_summary_rows)
    write_tsv(os.path.join(output_dir, 'url-type-summary.tsv'),
              ['url_type', 'url_count'],
              type_summary_rows)
    write_tsv(os.path.join(output_dir, 'url-suite-summary.tsv'),
              ['suite', 'pocket', 'url_count'],
              suite_summary_rows)
    write_tsv(os.path.join(output_dir, 'url-component-summary.tsv'),
              ['component', 'url_count'],
              component_summary_rows)
    write_tsv(os.path.join(output_dir, 'mirror-coverage.tsv'),
              ['coverage', 'url_count', 'share_of_required_urls', 'note'],
              coverage_rows)
    write_tsv(os.path.join(output_dir, 'duplicate-content.tsv'),
              ['sha256', 'url_count', 'hop_count', 'hops', 'urls', 'size_bytes'],
              duplicate_content_rows)
    write_tsv(os.path.join(output_dir, 'recovered-post-hop.tsv'),
              ['hop', 'file_type', 'analysis_category', 'filename', 'original_url',
               'evidence_source', 'recovery_class', 'sha256'],
              [{
                  'hop': r['hop'],
                  'file_type': r['file_type'],
                  'analysis_category': r['analysis_category'],
                  'filename': r['filename'],
                  'original_url': r['original_url'],
                  'evidence_source': r['evidence_source'],
                  'recovery_class': r['recovery_class'],
                  'sha256': r['sha256'],
              } for r in recovered_rows])
    write_tsv(os.path.join(output_dir, 'failed-requests-classified.tsv'),
              ['hop', 'original_url', 'final_url', 'http_status', 'reason',
               'file_type', 'classification'],
              failed_rows)
    write_tsv(os.path.join(output_dir, 'original-manifest-checksums.tsv'),
              ['path', 'sha256', 'size_bytes'],
              original_checksums)

    summary_path = os.path.join(output_dir, 'analysis-summary.json')
    with open(summary_path, 'w') as fh:
        json.dump(summary, fh, indent=2, sort_keys=False)
        fh.write('\n')

    # human-readable stdout report
    print('Upgrade discovery analysis')
    print('root={}'.format(os.path.abspath(discovery_root)))
    print('output={}'.format(os.path.abspath(output_dir)))
    print('index_expected_match={}'.format(summary['index_expected_match']))
    print('verdict={}'.format(summary['implementation_verdict']))
    for hop in HOPS:
        h = summary['hop_export'][hop]
        print('hop={} packages={} files={} urls={} unresolved_p={} unresolved_f={} failed={} recovered={}'.format(
            hop, h['required_packages'], h['required_files'], h['required_urls'],
            h['unresolved_packages'], h['unresolved_files'], h['failed_requests'],
            h['recovered_post_hop']))
    print('raw_packages={} unique_sha={} raw_urls={} unique_urls={}'.format(
        summary['totals_raw']['required_packages'],
        summary['totals_deduped']['unique_package_sha256'],
        summary['totals_raw']['required_urls'],
        summary['totals_deduped']['unique_urls']))
    print('hosts={}'.format(dict(summary['hosts'])))
    print('url_types={}'.format(dict(summary['url_types'])))
    print('components={}'.format(summary['components_in_urls']))
    print('coverage={}'.format(dict(summary['coverage_url_counts'])))
    if mismatches:
        print('MISMATCHES:', file=sys.stderr)
        for item in summary['mismatches']:
            print(' ', item, file=sys.stderr)
        return 2
    return 0


def build_parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        '--discovery-root',
        default=os.path.join('artifacts', 'upgrade-discovery'),
        help='Path to upgrade-discovery artifacts root')
    p.add_argument(
        '--output-dir',
        default=None,
        help='Derived analysis output directory (default: <discovery-root>/analysis)')
    p.add_argument(
        '--json-summary',
        action='store_true',
        help='Print analysis-summary.json path only on success')
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    discovery_root = args.discovery_root
    output_dir = args.output_dir or os.path.join(discovery_root, 'analysis')
    rc = analyze(discovery_root, output_dir)
    if args.json_summary and rc == 0:
        print(os.path.join(output_dir, 'analysis-summary.json'))
    return rc


if __name__ == '__main__':
    sys.exit(main())
