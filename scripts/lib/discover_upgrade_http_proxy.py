#!/usr/bin/env python3
"""Minimal HTTP forward proxy that logs APT/do-release-upgrade requests.

Records method, URL, status, size, redirects, and caches .deb bodies when possible.
Compatible with Python 3.5+ (Ubuntu 16.04 Xenial).
"""
from __future__ import print_function

import sys

if sys.version_info < (3, 5):
    sys.stderr.write(
        'ERROR: discover_upgrade_http_proxy.py requires Python 3.5+\n'
        'Found: Python {}.{}.{}\n'.format(
            sys.version_info[0], sys.version_info[1], sys.version_info[2]
        )
    )
    sys.exit(2)

import argparse
import hashlib
import os
import select
import socket
import threading
import time
from http.client import HTTPConnection, HTTPSConnection
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse

# pathlib/typing avoided where possible for broader 3.5 safety in hot paths.

SELFTEST_PREFIX = '/dur-recorder-self-test/'


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def utc_ts():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


class Recorder(object):

    def __init__(self, log_path, cache_dir):
        self.log_path = log_path
        self.cache_dir = cache_dir
        self.lock = threading.Lock()
        if not os.path.isdir(self.cache_dir):
            os.makedirs(self.cache_dir)
        parent = os.path.dirname(self.log_path)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)

    def write(self, line):
        with self.lock:
            with open(self.log_path, 'a', encoding='utf-8', errors='surrogateescape') as f:
                f.write(line.rstrip() + '\n')
                f.flush()
                try:
                    os.fsync(f.fileno())
                except Exception:
                    pass

    def log_request(self, method, original, final, status, size, sha256='', local_path=''):
        parts = [utc_ts(), method, original, str(status), str(size if size >= 0 else '-')]
        if final and final != original:
            parts.append('final={}'.format(final))
        if sha256:
            parts.append('sha256={}'.format(sha256))
        if local_path:
            parts.append('local_path={}'.format(local_path))
        self.write(' '.join(parts))

    def log_redirect(self, original, final, status):
        self.write('{} REDIRECT {} -> {} {}'.format(utc_ts(), original, final, status))


RECORDER = None


def _selftest_marker_from_path(path):
    """Return marker if path is a recorder self-test URI (relative or absolute)."""
    if path.startswith(SELFTEST_PREFIX):
        return path[len(SELFTEST_PREFIX):].split('?', 1)[0]
    if path.startswith('http://') or path.startswith('https://'):
        parsed = urlparse(path)
        if parsed.path.startswith(SELFTEST_PREFIX):
            return parsed.path[len(SELFTEST_PREFIX):].split('?', 1)[0]
    return None


class ProxyHandler(BaseHTTPRequestHandler):
    # HTTP/1.0 avoids keep-alive quirks on Python 3.5 ThreadingMixIn.
    protocol_version = 'HTTP/1.0'

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_CONNECT(self):
        # CONNECT is accepted for compatibility, but full HTTPS URLs / .deb bodies
        # cannot be recorded through an opaque tunnel. APT discovery installs
        # Acquire::https::Proxy "DIRECT" and must not claim HTTPS capture support.
        host_port = self.path
        if RECORDER:
            RECORDER.write(
                '{} CONNECT https://{}/ 200 - note=https_path_not_recorded'.format(
                    utc_ts(), host_port))
        try:
            host, port_s = host_port.split(':')
            port = int(port_s)
        except ValueError:
            self.send_error(400, 'bad CONNECT target')
            return
        try:
            upstream = socket.create_connection((host, port), timeout=60)
        except OSError:
            self.send_error(502, 'upstream connect failed')
            return
        self.send_response(200, 'Connection Established')
        self.end_headers()
        self._tunnel(self.connection, upstream)

    def _tunnel(self, client, upstream):
        sockets = [client, upstream]
        try:
            while True:
                r, _, _ = select.select(sockets, [], [], 60)
                if not r:
                    break
                for s in r:
                    other = upstream if s is client else client
                    data = s.recv(65536)
                    if not data:
                        return
                    other.sendall(data)
        finally:
            try:
                upstream.close()
            except Exception:
                pass

    def _dispatch(self):
        assert RECORDER is not None
        # Trace every request immediately so self-test can detect contact.
        RECORDER.write('{} TRACE {} {}'.format(utc_ts(), self.command, self.path))
        marker = _selftest_marker_from_path(self.path)
        if marker is not None:
            self._handle_selftest(marker)
            return
        self._proxy()

    def _handle_selftest(self, marker):
        """Answer locally - no upstream. Guarantees an access-log line on Xenial."""
        body = b'ok'
        original = self.path
        if not original.startswith('http://') and not original.startswith('https://'):
            original = 'http://127.0.0.1{0}{1}'.format(SELFTEST_PREFIX, marker)
        RECORDER.log_request(self.command, original, original, 200, len(body))
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)
        except Exception:
            pass

    def _proxy(self):
        method = self.command
        url = self.path
        if not url.startswith('http://') and (not url.startswith('https://')):
            self.send_error(400, 'absolute URL required')
            return
        original = url
        body = b''
        length = int(self.headers.get('Content-Length', '0') or '0')
        if length > 0:
            body = self.rfile.read(length)
        final_url, status, resp_headers, resp_body, redirects = self._fetch(method, url, body)
        for src, dst, st in redirects:
            RECORDER.log_redirect(src, dst, st)
        sha = ''
        local_path = ''
        path = urlparse(final_url).path
        base = os.path.basename(path)
        if resp_body and (base.endswith('.deb') or base.endswith('.udeb')):
            sha = hashlib.sha256(resp_body).hexdigest()
            dest = os.path.join(RECORDER.cache_dir, base)
            if not os.path.exists(dest):
                with open(dest, 'wb') as fh:
                    fh.write(resp_body)
            local_path = dest
        RECORDER.log_request(
            method, original, final_url, status,
            len(resp_body) if resp_body is not None else -1,
            sha256=sha, local_path=local_path)
        try:
            self.send_response(status)
            for k, v in resp_headers:
                lk = k.lower()
                if lk in ('transfer-encoding', 'connection', 'content-length'):
                    continue
                self.send_header(k, v)
            self.send_header('Content-Length', str(len(resp_body or b'')))
            self.send_header('Connection', 'close')
            self.end_headers()
            if method != 'HEAD' and resp_body:
                self.wfile.write(resp_body)
        except Exception:
            # BrokenPipeError and friends - client already gone.
            pass

    def _fetch(self, method, url, body):
        redirects = []
        current = url
        for _ in range(8):
            parsed = urlparse(current)
            if parsed.scheme == 'https':
                conn = HTTPSConnection(parsed.hostname, parsed.port or 443, timeout=120)
            else:
                conn = HTTPConnection(parsed.hostname, parsed.port or 80, timeout=120)
            path = parsed.path or '/'
            if parsed.query:
                path += '?' + parsed.query
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in ('proxy-connection', 'host')}
            headers['Host'] = parsed.netloc
            try:
                conn.request(
                    method, path,
                    body=body if method in ('POST', 'PUT') else None,
                    headers=headers)
                resp = conn.getresponse()
                data = resp.read()
                status = resp.status
                resp_headers = resp.getheaders()
            finally:
                conn.close()
            if status in (301, 302, 303, 307, 308):
                loc = dict(resp_headers).get('Location') or dict(
                    ((k.lower(), v) for k, v in resp_headers)).get('location')
                if not loc:
                    return (current, status, resp_headers, data, redirects)
                if loc.startswith('/'):
                    loc = '{}://{}{}'.format(parsed.scheme, parsed.netloc, loc)
                redirects.append((current, loc, status))
                current = loc
                if status == 303:
                    method = 'GET'
                    body = b''
                continue
            return (current, status, resp_headers, data, redirects)
        if RECORDER:
            RECORDER.write('{} ERROR redirect_loop {}'.format(utc_ts(), url))
        return (current, 508, [], b'', redirects)


def main():
    global RECORDER
    ap = argparse.ArgumentParser()
    ap.add_argument('--listen', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=18080)
    ap.add_argument('--log', required=True)
    ap.add_argument('--cache-dir', required=True)
    args = ap.parse_args()
    RECORDER = Recorder(args.log, args.cache_dir)
    # Bind first; only then announce readiness in the access log.
    httpd = ThreadingHTTPServer((args.listen, args.port), ProxyHandler)
    RECORDER.write(
        '# discover-upgrade-http-proxy started %s on %s:%s' % (
            utc_ts(), args.listen, args.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
