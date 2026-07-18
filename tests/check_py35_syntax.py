#!/usr/bin/env python3
"""Fail if discovery Python helpers use syntax/APIs unsupported on Python 3.5.

Runs on any modern CPython by inspecting AST/tokens. When python3.5 is on PATH,
also executes a real import/compile under that interpreter.
"""
from __future__ import print_function

import ast
import os
import subprocess
import sys
import tokenize


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
FILES = [
    os.path.join(ROOT, 'scripts/lib/discover_upgrade_requirements.py'),
    os.path.join(ROOT, 'scripts/lib/discover_upgrade_http_proxy.py'),
]
# Bash scripts that embed python3 <<'PY' heredocs must also be 3.5-safe.
SHELL_WITH_PY = [
    os.path.join(ROOT, 'scripts/lib/discover-upgrade-requirements-common.sh'),
    os.path.join(ROOT, 'scripts/discover-upgrade-requirements.sh'),
]


def check_ast(path):
    # Read as UTF-8 bytes so LC_ALL=C / ASCII locale cannot fail the checker.
    with open(path, 'rb') as fh:
        src = fh.read().decode('utf-8')
    try:
        tree = ast.parse(src, filename=path)
    except SyntaxError as exc:
        return ['SyntaxError: {}:{}: {}'.format(path, exc.lineno, exc.msg)]
    issues = []
    for node in ast.walk(tree):
        if isinstance(node, ast.JoinedStr):
            issues.append('{}:{}: f-string (JoinedStr) not allowed on Python 3.5'.format(
                path, getattr(node, 'lineno', '?')))
        if isinstance(node, ast.AnnAssign):
            issues.append('{}:{}: variable annotation (AnnAssign) not allowed on Python 3.5'.format(
                path, getattr(node, 'lineno', '?')))
        if type(node).__name__ == 'NamedExpr':
            issues.append('{}:{}: walrus operator not allowed on Python 3.5'.format(
                path, getattr(node, 'lineno', '?')))
        if type(node).__name__ == 'Match':
            issues.append('{}:{}: match/case not allowed on Python 3.5'.format(
                path, getattr(node, 'lineno', '?')))
    if 'from __future__ import annotations' in src:
        issues.append('{}: from __future__ import annotations requires Python 3.7+'.format(path))
    if 'dataclasses' in src:
        issues.append('{}: dataclasses requires Python 3.7+'.format(path))
    if 'fromisoformat' in src:
        issues.append('{}: datetime.fromisoformat requires Python 3.7+'.format(path))
    if 'capture_output' in src:
        issues.append('{}: subprocess capture_output requires Python 3.7+'.format(path))
    # Token scan for f-string starts on 3.12+
    try:
        with open(path, 'rb') as fh:
            for tok in tokenize.tokenize(fh.readline):
                if tok.type == getattr(tokenize, 'FSTRING_START', -1):
                    issues.append('{}:{}: f-string token'.format(path, tok.start[0]))
    except tokenize.TokenError as exc:
        issues.append('{}: tokenize error: {}'.format(path, exc))
    return issues


def check_python35_runtime(path):
    py35 = None
    for cand in ('python3.5', 'python3.5m'):
        try:
            subprocess.check_call([cand, '-c', 'import sys; assert sys.version_info[:2]==(3,5)'],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            py35 = cand
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    if not py35:
        return None, ['python3.5 not installed; AST/token checks only']
    cmd = [
        py35, '-c',
        'import sys; p=sys.argv[1]; src=open(p).read(); compile(src,p,"exec"); '
        'import importlib.machinery as m; '
        # Avoid importing http server side-effects: compile-only is enough.
        'print("compiled-ok")',
        path,
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, universal_newlines=True)
        return py35, [] if 'compiled-ok' in out else ['unexpected output: {}'.format(out)]
    except subprocess.CalledProcessError as exc:
        return py35, [exc.output.strip() or str(exc)]


def extract_python_heredocs(path):
    """Extract python3 <<'PY' ... PY blocks from bash scripts."""
    with open(path, 'r') as fh:
        lines = fh.readlines()
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if '<<' in line and ('PY' in line or 'PYTHON' in line) and 'python' in line.lower():
            # python3 - ... <<'PY'  or  python3 <<'PY'
            marker = None
            for token in ("<<'PY'", '<<"PY"', '<<PY', "<<'PYTHON'", '<<"PYTHON"'):
                if token in line:
                    marker = token.split('<<', 1)[1].strip().strip("'\"")
                    break
            if not marker:
                i += 1
                continue
            i += 1
            body = []
            start = i + 1
            while i < len(lines) and lines[i].rstrip('\n') != marker:
                body.append(lines[i])
                i += 1
            blocks.append((start, ''.join(body)))
        i += 1
    return blocks


def check_shell_embedded_python(path):
    issues = []
    for start_line, body in extract_python_heredocs(path):
        # Direct f-string pattern scan (works even if host python can't parse 3.6+)
        for offset, line in enumerate(body.splitlines(), start=start_line):
            stripped = line.lstrip()
            if 'f"' in line or "f'" in line:
                # Avoid false positives like suffix.endswith("f'")
                if 'print(f' in line or '= f"' in line or "= f'" in line or line.strip().startswith('f"') or line.strip().startswith("f'"):
                    issues.append('{}:{}: embedded f-string not allowed on Python 3.5: {}'.format(
                        path, offset, stripped[:80]))
        try:
            tree = ast.parse(body, filename='{}:heredoc'.format(path))
        except SyntaxError as exc:
            # On modern python, f-strings parse fine; still flag JoinedStr below.
            # On failure, report it.
            issues.append('{}:{}: embedded python SyntaxError: {}'.format(path, start_line, exc.msg))
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.JoinedStr):
                issues.append('{}:{}: embedded f-string (JoinedStr)'.format(
                    path, start_line + getattr(node, 'lineno', 1) - 1))
            if isinstance(node, ast.AnnAssign):
                issues.append('{}:{}: embedded AnnAssign'.format(
                    path, start_line + getattr(node, 'lineno', 1) - 1))
    return issues


def main():
    all_issues = []
    warnings = []
    for path in FILES:
        if not os.path.isfile(path):
            all_issues.append('missing file: {}'.format(path))
            continue
        all_issues.extend(check_ast(path))
        py35, runtime_issues = check_python35_runtime(path)
        if py35 is None:
            warnings.extend(runtime_issues)
        else:
            all_issues.extend(runtime_issues)
            print('PASS python3.5 compile: {}'.format(path))
    for path in SHELL_WITH_PY:
        if not os.path.isfile(path):
            all_issues.append('missing file: {}'.format(path))
            continue
        found = check_shell_embedded_python(path)
        if found:
            all_issues.extend(found)
        else:
            print('PASS embedded python 3.5 checks: {}'.format(path))
    if warnings:
        for w in warnings:
            print('WARN: {}'.format(w))
    if all_issues:
        print('FAIL Python 3.5 compatibility checks:')
        for i in all_issues:
            print('  - {}'.format(i))
        return 1
    print('PASS Python 3.5 compatibility checks for {} python + {} shell files'.format(
        len(FILES), len(SHELL_WITH_PY)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
