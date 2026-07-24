#!/usr/bin/env python3
"""Seed URL-hash captures for fixture access logs (test helper)."""
from __future__ import print_function

import hashlib
import json
import os
import sys


def url_key(url):
    return hashlib.sha256(url.encode('utf-8', 'surrogateescape')).hexdigest()


def store(cache_dir, url, body, meta_extra=None):
    key = url_key(url)
    directory = os.path.join(cache_dir, key[0:2], key[2:4])
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, key)
    with open(path, 'wb') as fh:
        fh.write(body)
        fh.flush()
        os.fsync(fh.fileno())
    sha = hashlib.sha256(body).hexdigest()
    meta = {
        'original_url': url,
        'final_url': url,
        'redirect_chain': [url],
        'http_status': 200,
        'content_length': len(body),
        'size_bytes': len(body),
        'sha256': sha,
        'local_path': path,
    }
    if meta_extra:
        meta.update(meta_extra)
    with open(path + '.meta.json', 'w', encoding='utf-8') as mf:
        json.dump(meta, mf, indent=2, sort_keys=True)
        mf.write('\n')
    return path, sha


def main():
    hop_dir = sys.argv[1]
    fixtures = sys.argv[2]
    cache = os.path.join(hop_dir, 'runtime', 'deb-cache')
    os.makedirs(cache, exist_ok=True)

    # Copy known debs into URL-hash object store (and keep basename copies for legacy).
    deb_map = {
        'http://archive.ubuntu.com/ubuntu/pool/main/b/bash/bash_4.4.18-2ubuntu1_amd64.deb':
            'bash_4.4.18-2ubuntu1_amd64.deb',
        'http://archive.ubuntu.com/ubuntu/pool/main/c/coreutils/coreutils_8.28-1ubuntu1_amd64.deb':
            'coreutils_8.28-1ubuntu1_amd64.deb',
        'http://archive.ubuntu.com/ubuntu/pool/main/z/zlib/zlib1g_1.2.11.dfsg-0ubuntu2_amd64.deb':
            'zlib1g_1.2.11.dfsg-0ubuntu2_amd64.deb',
        'http://ppa.launchpad.net/example/ppa/ubuntu/pool/main/e/extra/extra_1.0_amd64.deb':
            None,  # stub
    }
    captured = {}
    for url, name in deb_map.items():
        if name:
            src = os.path.join(fixtures, 'debs', name)
            body = open(src, 'rb').read()
            # legacy basename
            with open(os.path.join(cache, name), 'wb') as fh:
                fh.write(body)
        else:
            body = b'extra-stub-deb-body\n'
        path, sha = store(cache, url, body)
        captured[url] = (path, sha)

    meta_urls = [
        ('http://archive.ubuntu.com/ubuntu/dists/bionic-updates/InRelease', b'InRelease-body\n'),
        ('http://archive.ubuntu.com/ubuntu/dists/bionic/main/binary-amd64/Packages.gz', b'\x1f\x8bPackages'),
        ('http://changelogs.ubuntu.com/meta-release-lts', b'MetaRelease\n'),
        ('http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz', b'tar-gz-body\n'),
        ('http://archive.ubuntu.com/ubuntu/dists/bionic-updates/main/dist-upgrader-all/current/bionic.tar.gz.gpg', b'gpg-body\n'),
        ('http://archive.ubuntu.com/ubuntu/dists/bionic/Release.gpg', b'Release.gpg\n'),
        ('http://archive.ubuntu.com/ubuntu/dists/bionic/main/i18n/Translation-en', b'Translation\n'),
        ('http://archive.ubuntu.com/ubuntu/dists/bionic/main/binary-amd64/by-hash/SHA256/' + ('b' * 64), b'by-hash-body\n'),
    ]
    for url, body in meta_urls:
        path, sha = store(cache, url, body)
        captured[url] = (path, sha)

    # Also store under original redirected InRelease URL key (same body).
    redir_orig = 'http://archive.ubuntu.com/ubuntu/dists/bionic/InRelease'
    path, sha = store(
        cache, redir_orig, b'InRelease-body\n',
        meta_extra={
            'final_url': 'http://archive.ubuntu.com/ubuntu/dists/bionic-updates/InRelease',
            'redirect_chain': [
                redir_orig,
                'http://archive.ubuntu.com/ubuntu/dists/bionic-updates/InRelease',
            ],
        })
    captured[redir_orig] = (path, sha)

    # Rewrite access log lines to include sha256 + local_path for HTTP 200 bodies.
    log_path = os.path.join(hop_dir, 'runtime', 'proxy-access.log')
    lines_out = []
    for raw in open(log_path, 'r', encoding='utf-8', errors='surrogateescape'):
        line = raw.rstrip('\n')
        if not line or line.startswith('#') or ' REDIRECT ' in line or ' TRACE ' in line:
            lines_out.append(line)
            continue
        parts = line.split()
        if len(parts) < 5 or parts[1] not in ('GET', 'HEAD', 'POST'):
            lines_out.append(line)
            continue
        url = parts[2]
        status = parts[3]
        # Strip old sha/local tokens; rebuild.
        keep = parts[:5]
        extras = []
        final = None
        for tok in parts[5:]:
            if tok.startswith('final='):
                final = tok.split('=', 1)[1]
                extras.append(tok)
            elif tok.startswith('redirects=') or tok.startswith('content_length='):
                extras.append(tok)
            # drop old sha256/local_path
        lookup = url
        if status == '200' and lookup in captured:
            path, sha = captured[lookup]
            extras.append('sha256={}'.format(sha))
            extras.append('local_path={}'.format(path))
        elif status == '200' and final and final in captured:
            path, sha = captured[final]
            extras.append('sha256={}'.format(sha))
            extras.append('local_path={}'.format(path))
        lines_out.append(' '.join(keep + extras))

    # Append by-hash request if missing
    by_hash_url = meta_urls[-1][0]
    if not any(by_hash_url in ln for ln in lines_out):
        path, sha = captured[by_hash_url]
        lines_out.append(
            '2026-07-17T01:00:15Z GET {} 200 {} sha256={} local_path={}'.format(
                by_hash_url, len(b'by-hash-body\n'), sha, path))

    with open(log_path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
        fh.write('\n'.join(lines_out) + '\n')
    print('seeded {} captures'.format(len(captured)))


if __name__ == '__main__':
    main()
