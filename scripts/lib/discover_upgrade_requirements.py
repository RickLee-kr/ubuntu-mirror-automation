#!/usr/bin/env python3
"""Helpers for Ubuntu upgrade requirements discovery.

Fixture-friendly parsing and manifest generation. No live apt/do-release-upgrade.
Compatible with Python 3.5+ (Ubuntu 16.04 Xenial).
"""
from __future__ import print_function

import sys

if sys.version_info < (3, 5):
    sys.stderr.write(
        'ERROR: discover_upgrade_requirements.py requires Python 3.5+\n'
        'Found: Python {}.{}.{}\n'.format(
            sys.version_info[0], sys.version_info[1], sys.version_info[2]
        )
    )
    sys.exit(2)

import argparse
import hashlib
import json
import os
import re
import urllib.parse
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
HOP_MAP = {('16.04', '18.04'): 'xenial-to-bionic', ('18.04', '20.04'): 'bionic-to-focal', ('20.04', '22.04'): 'focal-to-jammy', ('22.04', '24.04'): 'jammy-to-noble'}
CODENAME_TO_VERSION = {'xenial': '16.04', 'bionic': '18.04', 'focal': '20.04', 'jammy': '22.04', 'noble': '24.04'}
VERSION_TO_CODENAME = {v: k for k, v in CODENAME_TO_VERSION.items()}
ACCESS_RE = re.compile('^(?P<ts>\\S+\\s+\\S+|\\d{4}-\\d{2}-\\d{2}T\\S+|\\d+)\\s+(?:\\[(?P<brack_ts>[^\\]]+)\\]\\s+)?(?P<client>\\S+)\\s+(?:\\"(?P<method>[A-Z]+)\\s+(?P<url>[^\\"]+)\\s+HTTP/[^\\"]+\\"|(?P<bare_url>https?://\\S+|\\S+))\\s+(?P<status>\\d{3})\\s+(?P<size>\\d+|-)?(?:\\s+(?P<extra>.*))?$')
SIMPLE_RE = re.compile('^(?P<ts>\\S+)\\s+(?P<method>GET|HEAD|POST)\\s+(?P<url>https?://\\S+)\\s+(?P<status>\\d{3})\\s+(?P<size>\\d+|-)(?:\\s+final=(?P<final>https?://\\S+))?(?:\\s+sha256=(?P<sha256>[0-9a-fA-F]{64}))?(?:\\s+local_path=(?P<local_path>\\S+))?$')
REDIRECT_RE = re.compile('^(?P<ts>\\S+)\\s+REDIRECT\\s+(?P<original>https?://\\S+)\\s+->\\s+(?P<final>https?://\\S+)\\s+(?P<status>\\d{3})$')
DEB_NAME_RE = re.compile('^(?P<package>[^_]+)_(?P<version>.+)_(?P<arch>[^_]+)\\.(?P<ext>deb|udeb)$')


def _as_path_str(path):
    return str(path)


def fs_decode(data):
    """Decode path/log bytes without losing non-UTF-8 sequences (PEP 383)."""
    if isinstance(data, str):
        return data
    return data.decode('utf-8', 'surrogateescape')


def open_text(path, mode='r'):
    """Text I/O safe under LC_ALL=C (never use locale default encoding)."""
    return open(_as_path_str(path), mode, encoding='utf-8', errors='surrogateescape')


def read_text(path):
    """Read entire text file with UTF-8 + surrogateescape."""
    with open(_as_path_str(path), 'rb') as fh:
        return fs_decode(fh.read())


def write_text(path, text):
    """Write text with UTF-8 + surrogateescape (round-trip safe for paths)."""
    parent = os.path.dirname(_as_path_str(path))
    if parent and not os.path.isdir(parent):
        os.makedirs(parent)
    with open_text(path, 'w') as fh:
        fh.write(text)


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def hop_name(from_os: str, to_os: str) -> str:
    from_os = normalize_version(from_os)
    to_os = normalize_version(to_os)
    key = (from_os, to_os)
    if key not in HOP_MAP:
        raise ValueError('unsupported hop {} -> {}'.format(from_os, to_os))
    return HOP_MAP[key]

def normalize_version(value: str) -> str:
    v = value.strip().lower()
    if v in CODENAME_TO_VERSION:
        return CODENAME_TO_VERSION[v]
    if v in VERSION_TO_CODENAME:
        return v
    m = re.search('(\\d+\\.\\d+)', v)
    if m and m.group(1) in VERSION_TO_CODENAME:
        return m.group(1)
    raise ValueError('unknown Ubuntu release: {}'.format(value))

def classify_url(url: str) -> str:
    path = urllib.parse.urlparse(url).path
    base = os.path.basename(path)
    lower = base.lower()
    full = path.lower()
    if lower.endswith('.deb'):
        return 'deb'
    if lower.endswith('.udeb'):
        return 'udeb'
    if lower == 'inrelease':
        return 'inrelease'
    if lower == 'release.gpg':
        return 'release_gpg'
    if lower == 'release':
        return 'release'
    if lower.startswith('packages.') or lower == 'packages':
        return 'packages_index'
    if lower.startswith('sources.') or lower == 'sources':
        return 'sources_index'
    if 'translation' in lower:
        return 'translation'
    if lower.startswith('contents-') or lower.startswith('contents.'):
        return 'contents'
    if 'dep11' in full or lower.startswith('components-') or lower.endswith('.yml.gz'):
        return 'dep11'
    if 'meta-release' in lower:
        return 'meta_release'
    if 'dist-upgrader' in full or 'ubuntu-release-upgrader' in full or 'releaseannouncement' in lower:
        return 'release_upgrader'
    if lower.endswith('.tar.gz') and ('upgrader' in full or 'upgrade' in full):
        return 'release_upgrader'
    if lower.endswith('.gpg') and ('upgrader' in full or 'upgrade' in full):
        return 'release_upgrader'
    if 'distupgrade' in full.replace('-', '') or '/dist-upgrade/' in full or full.endswith('/dist-upgrade'):
        return 'dist_upgrade'
    if lower.endswith('.gpg') or lower.endswith('.asc') or 'keyring' in lower:
        return 'gpg_key'
    return 'other'

def parse_suite_component(url: str) -> Tuple[str, str]:
    """Best-effort suite/codename and component from Ubuntu archive URL."""
    parts = urllib.parse.urlparse(url).path.strip('/').split('/')
    suite = ''
    component = ''
    try:
        if 'dists' in parts:
            i = parts.index('dists')
            if i + 1 < len(parts):
                suite = parts[i + 1].split('-')[0]
            if i + 2 < len(parts):
                component = parts[i + 2]
        elif 'pool' in parts:
            i = parts.index('pool')
            if i + 1 < len(parts):
                component = parts[i + 1]
    except ValueError:
        pass
    return (suite, component)

def host_of(url: str) -> str:
    return urllib.parse.urlparse(url).netloc

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def parse_access_log(text: str) -> List[Dict[str, Any]]:
    """Parse proxy/access log lines into request records."""
    records = []
    redirects = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = REDIRECT_RE.match(line)
        if m:
            redirects[m.group('original')] = m.group('final')
            records.append({'requested_at': m.group('ts'), 'method': 'GET', 'original_url': m.group('original'), 'final_url': m.group('final'), 'http_status': int(m.group('status')), 'size_bytes': '', 'sha256': '', 'local_path': '', 'event': 'redirect'})
            continue
        m = SIMPLE_RE.match(line)
        if m:
            original = m.group('url')
            final = m.group('final') or redirects.get(original, original)
            size = m.group('size')
            records.append({'requested_at': m.group('ts'), 'method': m.group('method'), 'original_url': original, 'final_url': final, 'http_status': int(m.group('status')), 'size_bytes': '' if size in (None, '-') else size, 'sha256': m.group('sha256') or '', 'local_path': m.group('local_path') or '', 'event': 'request'})
            continue
        urls = re.findall('https?://\\S+', line)
        if urls:
            status_m = re.search('\\b([1-5]\\d{2})\\b', line)
            method_m = re.search('\\b(GET|HEAD|POST)\\b', line)
            size_m = re.search('\\b(?:size=)?(\\d+)\\b', line)
            original = urls[0].rstrip(',;')
            final = urls[1].rstrip(',;') if len(urls) > 1 else redirects.get(original, original)
            records.append({'requested_at': line.split()[0], 'method': method_m.group(1) if method_m else 'GET', 'original_url': original, 'final_url': final, 'http_status': int(status_m.group(1)) if status_m else 0, 'size_bytes': size_m.group(1) if size_m else '', 'sha256': '', 'local_path': '', 'event': 'request'})
    return records

def aggregate_urls(records: Iterable[Dict[str, Any]], hop: str) -> List[Dict[str, Any]]:
    agg = OrderedDict()
    for r in records:
        if r.get('event') == 'redirect':
            key = r['original_url']
        else:
            key = r['original_url']
        cur = agg.get(key)
        if not cur:
            agg[key] = {'hop': hop, 'requested_at': r.get('requested_at', ''), 'method': r.get('method', 'GET'), 'original_url': r['original_url'], 'final_url': r.get('final_url') or r['original_url'], 'http_status': r.get('http_status', 0), 'size_bytes': r.get('size_bytes', ''), 'sha256': r.get('sha256', ''), 'local_path': r.get('local_path', ''), 'first_requested_at': r.get('requested_at', ''), 'last_requested_at': r.get('requested_at', ''), 'request_count': 1, 'file_type': classify_url(r.get('final_url') or r['original_url']), 'repository_host': host_of(r.get('final_url') or r['original_url'])}
        else:
            cur['request_count'] += 1
            cur['last_requested_at'] = r.get('requested_at', cur['last_requested_at'])
            if r.get('final_url'):
                cur['final_url'] = r['final_url']
            if r.get('http_status'):
                cur['http_status'] = r['http_status']
            if r.get('size_bytes'):
                cur['size_bytes'] = r['size_bytes']
            if r.get('sha256'):
                cur['sha256'] = r['sha256']
            if r.get('local_path'):
                cur['local_path'] = r['local_path']
    return list(agg.values())

def parse_packages_index(text: str) -> List[Dict[str, str]]:
    pkgs = []
    cur = {}
    last_key = ''
    for line in text.splitlines():
        if not line.strip():
            if cur.get('Package'):
                pkgs.append(cur)
            cur = {}
            last_key = ''
            continue
        if line.startswith(' ') and last_key:
            cur[last_key] = cur.get(last_key, '') + '\n' + line[1:]
            continue
        if ':' not in line:
            continue
        key, val = line.split(':', 1)
        key = key.strip()
        val = val.strip()
        cur[key] = val
        last_key = key
    if cur.get('Package'):
        pkgs.append(cur)
    return pkgs

def parse_installed_packages_tsv(path: Path) -> Dict[Tuple[str, str], Dict[str, str]]:
    """Keyed by (package, architecture)."""
    out = {}
    if not path.exists():
        return out
    with open_text(path) as f:
        header = f.readline().rstrip('\n').split('\t')
        for line in f:
            cols = line.rstrip('\n').split('\t')
            if len(cols) < 3:
                continue
            row = {header[i] if i < len(header) else 'c{}'.format(i): cols[i] for i in range(len(cols))}
            pkg = row.get('package') or row.get('Package') or cols[0]
            ver = row.get('version') or row.get('Version') or cols[1]
            arch = row.get('architecture') or row.get('Architecture') or cols[2]
            status = row.get('status') or row.get('Status') or (cols[3] if len(cols) > 3 else '')
            out[pkg, arch] = {'package': pkg, 'version': ver, 'architecture': arch, 'status': status}
    return out

def dpkg_version_cmp(a: str, b: str) -> int:
    """Approximate Debian version comparison using python apt_pkg if available, else string."""
    try:
        import apt_pkg
        apt_pkg.init_system()
        return apt_pkg.version_compare(a, b)
    except Exception:
        if a == b:
            return 0
        return -1 if a < b else 1

def diff_packages(before: Path, after: Path) -> Dict[str, List[Dict[str, str]]]:
    b = parse_installed_packages_tsv(before)
    a = parse_installed_packages_tsv(after)
    added, upgraded, downgraded, removed, unchanged = ([], [], [], [], [])
    keys = set(b) | set(a)
    for key in sorted(keys):
        pkg, arch = key
        if key not in b:
            added.append({'package': pkg, 'architecture': arch, 'version_before': '', 'version_after': a[key]['version'], 'change_type': 'added'})
        elif key not in a:
            removed.append({'package': pkg, 'architecture': arch, 'version_before': b[key]['version'], 'version_after': '', 'change_type': 'removed'})
        else:
            bv, av = (b[key]['version'], a[key]['version'])
            if bv == av:
                unchanged.append({'package': pkg, 'architecture': arch, 'version_before': bv, 'version_after': av, 'change_type': 'unchanged'})
            else:
                cmpv = dpkg_version_cmp(bv, av)
                row = {'package': pkg, 'architecture': arch, 'version_before': bv, 'version_after': av, 'change_type': 'upgraded' if cmpv < 0 else 'downgraded'}
                if cmpv < 0:
                    upgraded.append(row)
                else:
                    downgraded.append(row)
    return {'added': added, 'upgraded': upgraded, 'downgraded': downgraded, 'removed': removed, 'unchanged': unchanged}

def parse_file_manifest(path: Path) -> Dict[str, Dict[str, str]]:
    """Parse file-manifest.tsv / conffiles.tsv keyed by path (col0).

    Uses UTF-8 + surrogateescape so non-ASCII paths survive under LC_ALL=C.
    """
    out = {}
    if not path.exists():
        return out
    with open_text(path) as f:
        header = f.readline().rstrip('\n').split('\t')
        for line in f:
            cols = line.rstrip('\n').split('\t')
            if not cols or not cols[0]:
                continue
            row = {header[i] if i < len(header) else 'c{}'.format(i): cols[i] for i in range(len(cols))}
            out[cols[0]] = row
    return out

def diff_files(before: Path, after: Path) -> Dict[str, List[Dict[str, str]]]:
    b = parse_file_manifest(before)
    a = parse_file_manifest(after)
    added, modified, removed = ([], [], [])
    # sorted() preserves surrogateescape path strings as-is.
    for p in sorted(set(b) | set(a)):
        if p not in b:
            row = dict(a[p])
            row['change_type'] = 'added'
            # Ensure path key present for writers that look up 'path'.
            row.setdefault('path', p)
            added.append(row)
        elif p not in a:
            row = dict(b[p])
            row['change_type'] = 'removed'
            row.setdefault('path', p)
            removed.append(row)
        else:
            fields = ('size', 'size_bytes', 'mtime', 'mtime_epoch', 'sha256', 'mode')
            changed = False
            for fld in fields:
                if b[p].get(fld, '') != a[p].get(fld, '') and (b[p].get(fld) or a[p].get(fld)):
                    if fld in b[p] or fld in a[p]:
                        changed = True
                        break
            if changed or b[p] != a[p]:
                row = dict(a[p])
                row['change_type'] = 'modified'
                row.setdefault('path', p)
                row['sha256_before'] = b[p].get('sha256', '')
                row['sha256_after'] = a[p].get('sha256', '')
                modified.append(row)
    return {'added': added, 'modified': modified, 'removed': removed}

def write_tsv(path: Path, header: List[str], rows: Iterable[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open_text(path, 'w') as f:
        f.write('\t'.join(header) + '\n')
        for row in rows:
            f.write('\t'.join((str(row.get(h, '')) for h in header)) + '\n')

def read_tsv(path: Path) -> Tuple[List[str], List[Dict[str, str]]]:
    if not path.exists():
        return ([], [])
    with open_text(path) as f:
        header = f.readline().rstrip('\n').split('\t')
        rows = []
        for line in f:
            cols = line.rstrip('\n').split('\t')
            rows.append({header[i] if i < len(header) else 'c{}'.format(i): cols[i] if i < len(cols) else '' for i in range(len(header))})
        return (header, rows)

def deb_fields_from_filename(name: str) -> Dict[str, str]:
    m = DEB_NAME_RE.match(name)
    if not m:
        return {'package': '', 'version': '', 'architecture': '', 'filename': name}
    return {'package': m.group('package'), 'version': m.group('version'), 'architecture': m.group('arch'), 'filename': name, 'ext': m.group('ext')}

def extract_deb_control(path: Path) -> Dict[str, str]:
    """Extract control fields via dpkg-deb when available."""
    import subprocess
    fields = ['Package', 'Version', 'Architecture', 'Source', 'Depends', 'Pre-Depends', 'Recommends', 'Provides', 'Conflicts', 'Replaces']
    out = {}
    for fld in fields:
        try:
            proc = subprocess.run(['dpkg-deb', '-f', str(path), fld], check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
            out[fld.lower().replace('-', '_')] = proc.stdout.strip()
        except Exception:
            out[fld.lower().replace('-', '_')] = ''
    if out.get('package') and (not out.get('source')):
        out['source'] = out['package']
    out['source_package'] = out.get('source', '')
    return out

def build_required_manifests(hop_dir: Path, hop: str) -> Dict[str, Any]:
    runtime = hop_dir / 'runtime'
    packages_dir = hop_dir / 'packages'
    metadata_dir = hop_dir / 'metadata'
    before = hop_dir / 'before'
    after = hop_dir / 'after'
    diff_dir = hop_dir / 'diff'
    deb_cache = hop_dir / 'runtime' / 'deb-cache'
    access_log = runtime / 'proxy-access.log'
    # Only treat proxy/access evidence as collected when recording actually started.
    recording_started = runtime / 'recording-started-at.txt'
    if recording_started.exists() and access_log.exists():
        log_text = read_text(access_log)
        records = parse_access_log(log_text)
    else:
        records = []
    url_rows = aggregate_urls(records, hop)
    req_urls_path = runtime / 'requested-urls.tsv'
    # Rebuild requested-urls from recording-window evidence only (do not merge
    # stale pre-recording rows back into the manifest).
    write_tsv(req_urls_path, ['hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'size_bytes', 'sha256', 'local_path', 'request_count', 'file_type', 'repository_host', 'first_requested_at', 'last_requested_at'], url_rows)
    index_map = {}
    for idx in metadata_dir.glob('**/Packages*'):
        if idx.is_file() and (not str(idx).endswith('.tsv')):
            try:
                if idx.suffix == '.gz':
                    import gzip
                    text = gzip.open(
                        str(idx), 'rt', encoding='utf-8', errors='surrogateescape'
                    ).read()
                elif idx.suffix == '.xz':
                    import lzma
                    text = lzma.open(
                        str(idx), 'rt', encoding='utf-8', errors='surrogateescape'
                    ).read()
                else:
                    text = read_text(idx)
            except Exception:
                continue
            for p in parse_packages_index(text):
                key = (p.get('Package', ''), p.get('Version', ''), p.get('Architecture', ''))
                index_map[key] = p
    pkg_diff = diff_packages(before / 'installed-packages.tsv', after / 'installed-packages.tsv')
    for name, rows in pkg_diff.items():
        write_tsv(diff_dir / 'packages-{}.tsv'.format(name), ['package', 'architecture', 'version_before', 'version_after', 'change_type'], rows)
    file_diff = diff_files(before / 'file-manifest.tsv', after / 'file-manifest.tsv')
    for name, rows in file_diff.items():
        header = ['path', 'change_type', 'file_origin', 'size', 'sha256', 'sha256_before', 'sha256_after']
        norm = []
        for r in rows:
            norm.append({'path': r.get('path') or r.get('relative_path') or '', 'change_type': r.get('change_type', ''), 'file_origin': r.get('file_origin', 'unknown'), 'size': r.get('size') or r.get('size_bytes') or '', 'sha256': r.get('sha256', ''), 'sha256_before': r.get('sha256_before', ''), 'sha256_after': r.get('sha256_after', '')})
        write_tsv(diff_dir / 'files-{}.tsv'.format(name), header, norm)
    conf_b = parse_file_manifest(before / 'conffiles.tsv')
    conf_a = parse_file_manifest(after / 'conffiles.tsv')
    conf_mod = []
    for p in sorted(set(conf_b) | set(conf_a)):
        if p in conf_b and p in conf_a and (conf_b[p] != conf_a[p]):
            conf_mod.append({'path': p, 'hash_before': conf_b[p].get('hash') or conf_b[p].get('sha256') or '', 'hash_after': conf_a[p].get('hash') or conf_a[p].get('sha256') or ''})
    write_tsv(diff_dir / 'conffiles-modified.tsv', ['path', 'hash_before', 'hash_after'], conf_mod)
    write_tsv(diff_dir / 'apt-sources-before-after.tsv', ['side', 'path', 'sha256'], _list_apt_sources(before / 'apt-sources', 'before') + _list_apt_sources(after / 'apt-sources', 'after'))
    installed_after = parse_installed_packages_tsv(after / 'installed-packages.tsv')
    installed_before = parse_installed_packages_tsv(before / 'installed-packages.tsv')
    upgraded_keys = {(r['package'], r['architecture']) for r in pkg_diff['upgraded']}
    added_keys = {(r['package'], r['architecture']) for r in pkg_diff['added']}
    removed_keys = {(r['package'], r['architecture']) for r in pkg_diff['removed']}
    deb_rows = []
    deb_by_pva = {}
    for deb in sorted(deb_cache.glob('**/*')) if deb_cache.exists() else []:
        if not deb.is_file() or not (deb.name.endswith('.deb') or deb.name.endswith('.udeb')):
            continue
        meta = extract_deb_control(deb)
        fn_meta = deb_fields_from_filename(deb.name)
        package = meta.get('package') or fn_meta.get('package') or ''
        version = meta.get('version') or fn_meta.get('version') or ''
        arch = meta.get('architecture') or fn_meta.get('architecture') or ''
        sha = sha256_file(deb)
        size = deb.stat().st_size
        idx = index_map.get((package, version, arch), {})
        row = {'hop': hop, 'package': package, 'version': version, 'architecture': arch, 'source_package': meta.get('source_package') or package, 'filename': deb.name, 'local_path': str(deb), 'size_bytes': str(size), 'sha256': sha, 'Depends': idx.get('Depends', meta.get('depends', '')), 'Pre-Depends': idx.get('Pre-Depends', meta.get('pre_depends', '')), 'Recommends': idx.get('Recommends', meta.get('recommends', '')), 'Provides': idx.get('Provides', meta.get('provides', '')), 'Conflicts': idx.get('Conflicts', meta.get('conflicts', '')), 'Replaces': idx.get('Replaces', meta.get('replaces', '')), 'Filename': idx.get('Filename', '')}
        deb_rows.append(row)
        deb_by_pva[package, version, arch] = row
    write_tsv(packages_dir / 'deb-files.tsv', ['hop', 'package', 'version', 'architecture', 'source_package', 'filename', 'local_path', 'size_bytes', 'sha256', 'Filename', 'Depends', 'Pre-Depends', 'Recommends', 'Provides', 'Conflicts', 'Replaces'], deb_rows)
    required_urls = []
    required_files = []
    required_packages = []
    unresolved_packages = []
    unresolved_files = []
    failed_requests = []
    seen_pkg = set()
    seen_file = set()
    for u in url_rows:
        required_urls.append({'hop': hop, 'requested_at': u.get('first_requested_at') or u.get('requested_at', ''), 'method': u.get('method', 'GET'), 'original_url': u['original_url'], 'final_url': u.get('final_url') or u['original_url'], 'http_status': u.get('http_status', ''), 'size_bytes': u.get('size_bytes', ''), 'sha256': u.get('sha256', ''), 'local_path': u.get('local_path', '')})
        ftype = u.get('file_type') or classify_url(u.get('final_url') or u['original_url'])
        final_url = u.get('final_url') or u['original_url']
        filename = os.path.basename(urllib.parse.urlparse(final_url).path)
        status = int(u.get('http_status') or 0)
        local_path = u.get('local_path') or ''
        sha = u.get('sha256') or ''
        if status and status >= 400:
            failed_requests.append({'hop': hop, 'original_url': u['original_url'], 'final_url': final_url, 'http_status': status, 'reason': 'HTTP {}'.format(status), 'file_type': ftype})
        if ftype in ('deb', 'udeb'):
            fn_meta = deb_fields_from_filename(filename)
            package = fn_meta.get('package') or ''
            version = fn_meta.get('version') or ''
            arch = fn_meta.get('architecture') or ''
            suite, component = parse_suite_component(final_url)
            deb_row = deb_by_pva.get((package, version, arch))
            if deb_row:
                local_path = deb_row['local_path']
                sha = deb_row['sha256']
                size_bytes = deb_row['size_bytes']
                source_package = deb_row.get('source_package', package)
            else:
                size_bytes = u.get('size_bytes', '')
                source_package = package
                if status == 200 or status == 0:
                    unresolved_packages.append({'hop': hop, 'package': package, 'version': version, 'architecture': arch, 'original_url': u['original_url'], 'final_url': final_url, 'reason': 'file removed before capture' if status == 200 else 'cache miss'})
            key = (package, version, arch)
            installed = 'true' if (package, arch) in installed_after else 'false'
            upgraded = 'true' if (package, arch) in upgraded_keys else 'false'
            removed = 'true' if (package, arch) in removed_keys else 'false'
            downloaded = 'true' if deb_row else 'false'
            transitional = 'true' if 'transitional' in (package or '').lower() else 'false'
            third_party = 'false'
            host = host_of(final_url)
            if host and 'ubuntu.com' not in host and ('canonical.com' not in host) and ('launchpad.net' not in host):
                third_party = 'true'
            if key not in seen_pkg and package:
                seen_pkg.add(key)
                required_packages.append({'hop': hop, 'package': package, 'version': version, 'architecture': arch, 'source_package': source_package, 'filename': filename, 'repository_host': host, 'suite': suite, 'component': component, 'size_bytes': size_bytes, 'sha256': sha, 'original_url': u['original_url'], 'final_url': final_url, 'requested': 'true', 'downloaded': downloaded, 'installed': installed, 'evidence_source': 'proxy_access_log', 'upgraded': upgraded, 'removed': removed, 'transitional': transitional, 'third_party': third_party, 'first_requested_at': u.get('first_requested_at', ''), 'last_requested_at': u.get('last_requested_at', ''), 'request_count': u.get('request_count', 1), 'local_path': local_path})
        else:
            fkey = (ftype, final_url)
            if fkey not in seen_file:
                seen_file.add(fkey)
                if status == 200 and local_path and (not Path(local_path).exists()):
                    unresolved_files.append({'hop': hop, 'file_type': ftype, 'filename': filename, 'original_url': u['original_url'], 'final_url': final_url, 'reason': 'file removed before capture'})
                elif status == 200 and (not local_path) and (not sha):
                    unresolved_files.append({'hop': hop, 'file_type': ftype, 'filename': filename, 'original_url': u['original_url'], 'final_url': final_url, 'reason': 'cache miss'})
                required_files.append({'hop': hop, 'file_type': ftype, 'filename': filename, 'original_url': u['original_url'], 'final_url': final_url, 'local_path': local_path, 'size_bytes': u.get('size_bytes', ''), 'sha256': sha, 'http_status': status, 'request_count': u.get('request_count', 1), 'evidence_source': 'proxy_access_log'})
    for key, deb_row in deb_by_pva.items():
        if key in seen_pkg:
            continue
        package, version, arch = key
        seen_pkg.add(key)
        installed = 'true' if (package, arch) in installed_after else 'false'
        required_packages.append({'hop': hop, 'package': package, 'version': version, 'architecture': arch, 'source_package': deb_row.get('source_package', package), 'filename': deb_row['filename'], 'repository_host': '', 'suite': '', 'component': '', 'size_bytes': deb_row['size_bytes'], 'sha256': deb_row['sha256'], 'original_url': '', 'final_url': '', 'requested': 'false', 'downloaded': 'true', 'installed': installed, 'evidence_source': 'apt_archives', 'upgraded': 'true' if (package, arch) in upgraded_keys else 'false', 'removed': 'false', 'transitional': 'false', 'third_party': 'false', 'first_requested_at': '', 'last_requested_at': '', 'request_count': 0, 'local_path': deb_row['local_path']})
        required_files.append({'hop': hop, 'file_type': 'deb', 'filename': deb_row['filename'], 'original_url': '', 'final_url': '', 'local_path': deb_row['local_path'], 'size_bytes': deb_row['size_bytes'], 'sha256': deb_row['sha256'], 'http_status': '', 'request_count': 0, 'evidence_source': 'apt_archives'})
    for rp in required_packages:
        if rp.get('requested') != 'true':
            continue
        fkey = ('deb', rp.get('final_url') or rp.get('filename'))
        if fkey in seen_file:
            continue
        seen_file.add(fkey)
        required_files.append({'hop': hop, 'file_type': 'deb' if not str(rp.get('filename', '')).endswith('.udeb') else 'udeb', 'filename': rp.get('filename', ''), 'original_url': rp.get('original_url', ''), 'final_url': rp.get('final_url', ''), 'local_path': rp.get('local_path', ''), 'size_bytes': rp.get('size_bytes', ''), 'sha256': rp.get('sha256', ''), 'http_status': '', 'request_count': rp.get('request_count', 1), 'evidence_source': rp.get('evidence_source', '')})
    write_tsv(hop_dir / 'required-urls.tsv', ['hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'size_bytes', 'sha256', 'local_path'], required_urls)
    write_tsv(hop_dir / 'required-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'local_path', 'size_bytes', 'sha256', 'http_status', 'request_count', 'evidence_source'], required_files)
    write_tsv(hop_dir / 'required-packages.tsv', ['hop', 'package', 'version', 'architecture', 'source_package', 'filename', 'repository_host', 'suite', 'component', 'size_bytes', 'sha256', 'original_url', 'final_url', 'requested', 'downloaded', 'installed', 'evidence_source'], required_packages)
    write_tsv(packages_dir / 'requested-packages.tsv', ['hop', 'package', 'version', 'architecture', 'filename', 'original_url', 'final_url', 'request_count', 'evidence_source'], [r for r in required_packages if r.get('requested') == 'true'])
    write_tsv(packages_dir / 'downloaded-packages.tsv', ['hop', 'package', 'version', 'architecture', 'filename', 'local_path', 'sha256', 'size_bytes', 'installed', 'evidence_source'], [r for r in required_packages if r.get('downloaded') == 'true'])
    write_tsv(packages_dir / 'package-metadata.tsv', ['hop', 'package', 'version', 'architecture', 'source_package', 'filename', 'local_path', 'original_url', 'final_url', 'repository_host', 'suite', 'component', 'size_bytes', 'sha256', 'first_requested_at', 'last_requested_at', 'request_count', 'downloaded', 'installed', 'upgraded', 'removed', 'transitional', 'third_party', 'evidence_source'], required_packages)
    meta_req = [r for r in required_files if r['file_type'] not in ('deb', 'udeb')]
    write_tsv(metadata_dir / 'requested-metadata.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'http_status', 'request_count', 'evidence_source'], meta_req)
    write_tsv(metadata_dir / 'release-upgrader-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'http_status', 'request_count', 'evidence_source'], [r for r in meta_req if r['file_type'] in ('meta_release', 'release_upgrader', 'dist_upgrade')])
    write_tsv(metadata_dir / 'repository-index-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'http_status', 'request_count', 'evidence_source'], [r for r in meta_req if r['file_type'] in ('inrelease', 'release', 'release_gpg', 'packages_index', 'sources_index', 'translation', 'contents', 'dep11')])
    write_tsv(hop_dir / 'unresolved-packages.tsv', ['hop', 'package', 'version', 'architecture', 'original_url', 'final_url', 'reason'], unresolved_packages)
    write_tsv(hop_dir / 'unresolved-files.tsv', ['hop', 'file_type', 'filename', 'original_url', 'final_url', 'reason'], unresolved_files)
    write_tsv(hop_dir / 'failed-requests.tsv', ['hop', 'original_url', 'final_url', 'http_status', 'reason', 'file_type'], failed_requests)
    evidence = {'hop': hop, 'generated_at': utc_now(), 'required_packages': len(required_packages), 'required_files': len(required_files), 'required_urls': len(required_urls), 'unresolved_packages': len(unresolved_packages), 'unresolved_files': len(unresolved_files), 'failed_requests': len(failed_requests), 'packages_added': len(pkg_diff['added']), 'packages_upgraded': len(pkg_diff['upgraded']), 'packages_removed': len(pkg_diff['removed']), 'downloaded_not_installed': sum((1 for r in required_packages if r.get('downloaded') == 'true' and r.get('installed') != 'true'))}
    write_text(hop_dir / 'evidence.json', json.dumps(evidence, indent=2) + '\n')
    return evidence

def _list_apt_sources(root: Path, side: str) -> List[Dict[str, str]]:
    rows = []
    if not root.exists():
        return rows
    for p in sorted(root.rglob('*')):
        if p.is_file():
            try:
                sha = sha256_file(p)
            except Exception:
                sha = ''
            rows.append({'side': side, 'path': str(p.relative_to(root)), 'sha256': sha})
    return rows

def validate_hop(hop_dir: Path, hop: str, from_os: str, to_os: str) -> Tuple[bool, List[str]]:
    failures = []

    def need(rel: str) -> Path:
        p = hop_dir / rel
        if not p.exists():
            failures.append('missing:{}'.format(rel))
        return p
    need('before/installed-packages.tsv')
    need('after/installed-packages.tsv')
    need('required-packages.tsv')
    need('required-files.tsv')
    need('required-urls.tsv')
    need('runtime/apt-history.log')
    need('runtime/apt-term.log')
    need('runtime/dpkg.log')
    need('runtime/dist-upgrade')
    need('evidence.json')
    run_json = hop_dir / 'run.json'
    if run_json.exists():
        try:
            meta = json.loads(read_text(run_json))
            if meta.get('hop') and meta['hop'] != hop:
                failures.append('hop_mismatch:run.json hop={} expected={}'.format(meta.get('hop'), hop))
            if meta.get('from_os') and normalize_version(meta['from_os']) != normalize_version(from_os):
                failures.append('from_os_mismatch:{}!={}'.format(meta.get('from_os'), from_os))
            if meta.get('to_os') and normalize_version(meta['to_os']) != normalize_version(to_os):
                failures.append('to_os_mismatch:{}!={}'.format(meta.get('to_os'), to_os))
        except Exception as e:
            failures.append('run.json_parse_failed:{}'.format(e))
    else:
        failures.append('missing:run.json')
    deb_cache = hop_dir / 'runtime' / 'deb-cache'
    if deb_cache.exists():
        for deb in deb_cache.glob('**/*'):
            if not deb.is_file() or not (deb.name.endswith('.deb') or deb.name.endswith('.udeb')):
                continue
            try:
                sha256_file(deb)
            except Exception as e:
                failures.append('sha256_failed:{}:{}'.format(deb.name, e))
            meta = extract_deb_control(deb)
            if not meta.get('package') or not meta.get('version') or (not meta.get('architecture')):
                fn = deb_fields_from_filename(deb.name)
                if not (fn.get('package') and fn.get('version') and fn.get('architecture')):
                    failures.append('deb_metadata_missing:{}'.format(deb.name))
    _, req_pkgs = read_tsv(hop_dir / 'required-packages.tsv')
    _, req_files = read_tsv(hop_dir / 'required-files.tsv')
    _, req_urls = read_tsv(hop_dir / 'required-urls.tsv')
    seen = set()
    for r in req_pkgs:
        key = (r.get('package'), r.get('version'), r.get('architecture'))
        if key in seen:
            failures.append('duplicate_package_key:{}'.format(key))
        seen.add(key)
    _, requested = read_tsv(hop_dir / 'packages' / 'requested-packages.tsv')
    req_set = {(r.get('package'), r.get('version'), r.get('architecture')) for r in req_pkgs}
    for r in requested:
        key = (r.get('package'), r.get('version'), r.get('architecture'))
        if key not in req_set:
            failures.append('requested_package_missing_in_required:{}'.format(key))
    _, meta_req = read_tsv(hop_dir / 'metadata' / 'requested-metadata.tsv')
    file_urls = {(r.get('file_type'), r.get('final_url') or r.get('original_url')) for r in req_files}
    for r in meta_req:
        key = (r.get('file_type'), r.get('final_url') or r.get('original_url'))
        if key not in file_urls:
            failures.append('requested_metadata_missing_in_required_files:{}'.format(key))
    _, unresolved_files = read_tsv(hop_dir / 'unresolved-files.tsv')
    _, unresolved_pkgs = read_tsv(hop_dir / 'unresolved-packages.tsv')
    unresolved_urls = {r.get('final_url') or r.get('original_url') for r in unresolved_files + unresolved_pkgs if r.get('final_url') or r.get('original_url')}
    for r in req_urls:
        try:
            st = int(r.get('http_status') or 0)
        except ValueError:
            st = 0
        if st != 200:
            continue
        lp = r.get('local_path') or ''
        url = r.get('final_url') or r.get('original_url') or ''
        ftype = classify_url(url)
        has_local = bool(lp) and Path(lp).exists()
        if ftype in ('deb', 'udeb') and (not has_local):
            base = os.path.basename(urllib.parse.urlparse(url).path)
            has_local = (hop_dir / 'runtime' / 'deb-cache' / base).exists()
        if not has_local and url not in unresolved_urls:
            if r.get('sha256') and ftype not in ('deb', 'udeb'):
                continue
            failures.append('http200_missing_local_evidence:{}'.format(r.get('original_url')))
    for label, rows in (('required-packages', req_pkgs), ('required-files', req_files), ('required-urls', req_urls)):
        for r in rows:
            if r.get('hop') and r['hop'] != hop:
                failures.append('cross_hop_contamination:{}:{}'.format(label, r.get('hop')))
    ok = not failures
    lines = ['VALIDATION: PASS' if ok else 'VALIDATION: FAIL', 'hop={}'.format(hop), 'from_os={}'.format(from_os), 'to_os={}'.format(to_os)]
    if failures:
        lines.append('failures:')
        lines.extend(('  - {}'.format(f) for f in failures))
    else:
        lines.append('failures: none')
    write_text(hop_dir / 'validation.txt', '\n'.join(lines) + '\n')
    return (ok, failures)

def cmd_classify_url(args: argparse.Namespace) -> int:
    print(classify_url(args.url))
    return 0

def cmd_parse_access_log(args: argparse.Namespace) -> int:
    text = read_text(Path(args.log))
    records = parse_access_log(text)
    rows = aggregate_urls(records, args.hop)
    write_tsv(Path(args.output), ['hop', 'requested_at', 'method', 'original_url', 'final_url', 'http_status', 'size_bytes', 'sha256', 'local_path', 'request_count', 'file_type', 'repository_host', 'first_requested_at', 'last_requested_at'], rows)
    print('wrote {} url rows'.format(len(rows)))
    return 0

def cmd_parse_packages_index(args: argparse.Namespace) -> int:
    text = read_text(Path(args.index))
    pkgs = parse_packages_index(text)
    write_tsv(Path(args.output), ['Package', 'Version', 'Architecture', 'Filename', 'SHA256', 'Size', 'Depends', 'Provides'], [{'Package': p.get('Package', ''), 'Version': p.get('Version', ''), 'Architecture': p.get('Architecture', ''), 'Filename': p.get('Filename', ''), 'SHA256': p.get('SHA256', ''), 'Size': p.get('Size', ''), 'Depends': p.get('Depends', ''), 'Provides': p.get('Provides', '')} for p in pkgs])
    print('wrote {} packages'.format(len(pkgs)))
    return 0

def cmd_diff_packages(args: argparse.Namespace) -> int:
    result = diff_packages(Path(args.before), Path(args.after))
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    for name, rows in result.items():
        write_tsv(out / 'packages-{}.tsv'.format(name), ['package', 'architecture', 'version_before', 'version_after', 'change_type'], rows)
    print(json.dumps({k: len(v) for k, v in result.items()}))
    return 0

def cmd_build_manifests(args: argparse.Namespace) -> int:
    try:
        evidence = build_required_manifests(Path(args.hop_dir), args.hop)
        print(json.dumps(evidence))
        return 0
    except Exception as exc:
        import traceback
        sys.stderr.write('[ERROR] build-manifests failed: %s\n' % exc)
        traceback.print_exc()
        return 1

def cmd_validate(args: argparse.Namespace) -> int:
    ok, failures = validate_hop(Path(args.hop_dir), args.hop, args.from_os, args.to_os)
    print('PASS' if ok else 'FAIL')
    for f in failures:
        print(f)
    return 0 if ok else 1

def cmd_sha256(args: argparse.Namespace) -> int:
    print(sha256_file(Path(args.path)))
    return 0

def cmd_extract_deb(args: argparse.Namespace) -> int:
    meta = extract_deb_control(Path(args.deb))
    fn = deb_fields_from_filename(Path(args.deb).name)
    for k in ('package', 'version', 'architecture', 'source_package'):
        print('{}={}'.format(k, meta.get(k) or fn.get(k, '')))
    print('sha256={}'.format(sha256_file(Path(args.deb))))
    print('size_bytes={}'.format(Path(args.deb).stat().st_size))
    return 0

def cmd_hop_name(args: argparse.Namespace) -> int:
    try:
        print(hop_name(args.from_os, args.to_os))
    except ValueError as exc:
        sys.stderr.write('ERROR: {}\n'.format(exc))
        return 2
    return 0


# Directory names skipped while walking product/data trees (basename match).
_SKIP_DIR_NAMES = frozenset([
    'data', 'cache', 'tmp', 'temp', 'logs', 'log', 'journal',
    '.git', 'node_modules', 'lost+found', 'proc', 'sys', 'dev',
    'docker', 'containers', 'volumes', 'snap',
])


# Back-compat aliases for inventory helpers.
_fs_decode = fs_decode
_open_text_surrogateescape = open_text


def _load_dpkg_owned_paths(info_dir, roots, progress_cb=None):
    """Load dpkg *.list paths once (O(packages)), not per-file dpkg-query -S.

    Reads *.list as binary and decodes with surrogateescape so non-ASCII / non-UTF-8
    path bytes never raise UnicodeDecodeError under LC_ALL=C.
    Returns (owned_paths_set, per_file_errors).
    """
    owned = set()
    errors = []
    if not os.path.isdir(info_dir):
        return owned, errors
    try:
        names = [n for n in os.listdir(info_dir) if n.endswith('.list')]
    except (IOError, OSError) as exc:
        raise IOError('cannot list dpkg info dir %s: %s' % (info_dir, exc))
    total = len(names)
    for i, name in enumerate(names, 1):
        path = os.path.join(info_dir, name)
        try:
            with open(path, 'rb') as fh:
                for raw in fh:
                    p = _fs_decode(raw).strip()
                    if not p:
                        continue
                    for root in roots:
                        if p == root or p.startswith(root.rstrip('/') + '/'):
                            owned.add(p)
                            break
        except (IOError, OSError) as exc:
            # One unreadable list must not abort the whole index; record and continue.
            errors.append('%s: %s' % (path, exc))
            if progress_cb:
                progress_cb('WARN skip unreadable dpkg list: %s (%s)' % (name, exc))
            continue
        if progress_cb and i % 200 == 0:
            progress_cb('dpkg-list %s/%s' % (i, total))
    return owned, errors


def collect_file_manifest(output_path, roots, host_root='', hash_max_bytes=262144,
                          max_entries=8000, dpkg_info_dir='/var/lib/dpkg/info'):
    """Fast file inventory for discovery before/after snapshots.

    Avoids per-file ``dpkg-query -S`` (multi-hour on real systems).
    Returns 0 on success, 1 on failure. Never leaves a partial success unmarked:
    callers must treat nonzero as inventory failure.
    """
    try:
        # dpkg *.list entries are host-absolute (/etc/...). Keep logical roots for
        # matching even when DUR_HOST_ROOT remaps the walk paths.
        dpkg_match_roots = []
        for r in roots:
            if r.startswith('/'):
                dpkg_match_roots.append(r)
            else:
                dpkg_match_roots.append('/' + r)

        if host_root:
            roots = [os.path.join(host_root, r.lstrip('/')) if r.startswith('/') else os.path.join(host_root, r)
                     for r in roots]
            dpkg_info_dir = os.path.join(host_root, dpkg_info_dir.lstrip('/'))

        abs_roots = []
        for r in roots:
            ap = os.path.abspath(r)
            if os.path.exists(ap):
                abs_roots.append(ap)

        def log(msg):
            sys.stderr.write('[INFO] file-manifest: %s\n' % msg)
            sys.stderr.flush()

        log('loading dpkg owned-path index (one-time)...')
        owned, load_errors = _load_dpkg_owned_paths(
            dpkg_info_dir, dpkg_match_roots, progress_cb=log)
        if host_root:
            # Also index hostroot-prefixed forms so walk paths match package_owned.
            hr = host_root.rstrip('/')
            prefixed = set()
            for p in owned:
                if p.startswith('/'):
                    prefixed.add(hr + p)
                else:
                    prefixed.add(hr + '/' + p)
            owned = owned | prefixed
        if load_errors:
            log('dpkg-list unreadable files=%s (continued)' % len(load_errors))
        log('owned-path index size=%s' % len(owned))

        import stat as statmod
        try:
            import pwd
            import grp
        except ImportError:
            pwd = None
            grp = None

        seen = [0]
        hashed = [0]
        skipped_hash = [0]

        out_dir = os.path.dirname(output_path)
        if out_dir and not os.path.isdir(out_dir):
            os.makedirs(out_dir)

        def file_origin(path):
            if path in owned:
                return 'package_owned'
            if '/usr/local/' in path or path.endswith('/usr/local') or '/usr/local' in path:
                return 'custom'
            if '/opt/aelladata' in path:
                return 'custom'
            return 'unknown'

        def emit(out, path):
            if seen[0] >= max_entries:
                return False
            try:
                st = os.lstat(path)
            except (OSError, IOError):
                return True
            if os.path.islink(path):
                typ = 'symlink'
            elif statmod.S_ISDIR(st.st_mode):
                typ = 'dir'
            elif statmod.S_ISREG(st.st_mode):
                typ = 'file'
            else:
                typ = 'other'
            size = int(getattr(st, 'st_size', 0) or 0)
            owner = str(st.st_uid)
            group = str(st.st_gid)
            if pwd is not None:
                try:
                    owner = pwd.getpwuid(st.st_uid).pw_name
                except Exception:
                    pass
            if grp is not None:
                try:
                    group = grp.getgrgid(st.st_gid).gr_name
                except Exception:
                    pass
            mode = format(st.st_mode & 0o777, 'o')
            mtime = int(st.st_mtime)
            sha = ''
            reason = ''
            if typ == 'file':
                # Match directory basenames only (avoid false positives like /tmp/foo host roots).
                path_parts = set([p for p in path.split('/') if p])
                heavy = bool(path_parts & set(['data', 'cache', 'tmp', 'temp', 'logs', 'log']))
                if heavy or size > hash_max_bytes or path.endswith((
                        '.iso', '.img', '.qcow2', '.vmdk', '.raw', '.squashfs',
                        '.db', '.sqlite', '.bin', '.pack')):
                    reason = 'skipped_heavy_or_large'
                    skipped_hash[0] += 1
                else:
                    try:
                        sha = sha256_file(Path(path))
                        hashed[0] += 1
                    except Exception:
                        reason = 'hash_failed'
                        skipped_hash[0] += 1
            origin = file_origin(path)
            out.write('%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' % (
                path, typ, size, owner, group, mode, mtime, sha, reason, origin))
            seen[0] += 1
            if seen[0] % 500 == 0:
                log('entries=%s hashed=%s' % (seen[0], hashed[0]))
            return seen[0] < max_entries

        with _open_text_surrogateescape(output_path, 'w') as out:
            out.write('path\ttype\tsize\towner\tgroup\tmode\tmtime\tsha256\thash_skip_reason\tfile_origin\n')

            for root in abs_roots:
                log('walking %s' % root)
                if os.path.islink(root) or os.path.isfile(root):
                    emit(out, root)
                    continue

                for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
                    keep = []
                    for d in dirnames:
                        if d in _SKIP_DIR_NAMES:
                            continue
                        full = os.path.join(dirpath, d)
                        if '/opt/aelladata/' in (full + '/'):
                            if d in ('backup', 'backups', 'archive', 'archives', 'metrics', 'pcap'):
                                continue
                        keep.append(d)
                    dirnames[:] = keep

                    if not emit(out, dirpath):
                        break
                    for name in filenames:
                        if not emit(out, os.path.join(dirpath, name)):
                            break
                    if seen[0] >= max_entries:
                        break
                if seen[0] >= max_entries:
                    log('reached max_entries=%s; truncating further roots' % max_entries)
                    break

        if not os.path.isfile(output_path):
            sys.stderr.write('[ERROR] file-manifest: output missing after write: %s\n' % output_path)
            return 1

        log('done entries=%s hashed=%s hash_skipped=%s -> %s' % (
            seen[0], hashed[0], skipped_hash[0], output_path))
        return 0
    except Exception as exc:
        sys.stderr.write('[ERROR] file-manifest failed: %s\n' % exc)
        try:
            if output_path and os.path.isfile(output_path):
                os.remove(output_path)
        except Exception:
            pass
        return 1


def cmd_collect_file_manifest(args: argparse.Namespace) -> int:
    roots = list(args.roots) if args.roots else ['/etc', '/usr/local', '/opt/aelladata']
    return collect_file_manifest(
        args.output,
        roots,
        host_root=args.host_root or '',
        hash_max_bytes=int(args.hash_max_bytes),
        max_entries=int(args.max_entries),
        dpkg_info_dir=args.dpkg_info_dir,
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog='discover_upgrade_requirements.py')
    sub = p.add_subparsers(dest='cmd')
    s = sub.add_parser('classify-url')
    s.add_argument('url')
    s.set_defaults(func=cmd_classify_url)
    s = sub.add_parser('parse-access-log')
    s.add_argument('--log', required=True)
    s.add_argument('--hop', required=True)
    s.add_argument('--output', required=True)
    s.set_defaults(func=cmd_parse_access_log)
    s = sub.add_parser('parse-packages-index')
    s.add_argument('--index', required=True)
    s.add_argument('--output', required=True)
    s.set_defaults(func=cmd_parse_packages_index)
    s = sub.add_parser('diff-packages')
    s.add_argument('--before', required=True)
    s.add_argument('--after', required=True)
    s.add_argument('--output-dir', required=True)
    s.set_defaults(func=cmd_diff_packages)
    s = sub.add_parser('build-manifests')
    s.add_argument('--hop-dir', required=True)
    s.add_argument('--hop', required=True)
    s.set_defaults(func=cmd_build_manifests)
    s = sub.add_parser('validate')
    s.add_argument('--hop-dir', required=True)
    s.add_argument('--hop', required=True)
    s.add_argument('--from-os', required=True)
    s.add_argument('--to-os', required=True)
    s.set_defaults(func=cmd_validate)
    s = sub.add_parser('sha256')
    s.add_argument('path')
    s.set_defaults(func=cmd_sha256)
    s = sub.add_parser('extract-deb')
    s.add_argument('deb')
    s.set_defaults(func=cmd_extract_deb)
    s = sub.add_parser('hop-name')
    s.add_argument('--from-os', required=True)
    s.add_argument('--to-os', required=True)
    s.set_defaults(func=cmd_hop_name)
    s = sub.add_parser('collect-file-manifest')
    s.add_argument('--output', required=True)
    s.add_argument('--host-root', default='')
    s.add_argument('--hash-max-bytes', default='262144')
    s.add_argument('--max-entries', default='8000')
    s.add_argument('--dpkg-info-dir', default='/var/lib/dpkg/info')
    s.add_argument('roots', nargs='*')
    s.set_defaults(func=cmd_collect_file_manifest)
    return p

def main(argv: Optional[List[str]]=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, 'cmd', None):
        parser.error('command required')
    return int(args.func(args))
if __name__ == '__main__':
    sys.exit(main())
