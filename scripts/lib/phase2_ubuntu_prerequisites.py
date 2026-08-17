#!/usr/bin/env python3
"""Phase 2 Ubuntu prerequisite dependency closure and artifact builder.

Reuses the existing Debian dependency-closure helpers in
xenial_bionic_upgrade_analysis.py (parse_dep_field / dep_names /
follow_dependency_closure / load_suite_packages). Does not invent a second
resolver.

Inspects ACPS py3-apt-packages as root requirements, resolves recursive
Depends/Pre-Depends against Noble main/universe/updates/security indexes,
and builds a separate compatibility artifact. Never modifies ACPS payloads.
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
import tarfile
import tempfile
from collections import OrderedDict, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import xenial_bionic_upgrade_analysis as xba  # noqa: E402

try:
    import selective_mirror as sm  # noqa: E402
except ImportError:  # pragma: no cover
    sm = None

PHASE2_PREREQ_FIELDS = ('Pre-Depends', 'Depends')
PHASE2_DEFAULT_SUITES = (
    'noble',
    'noble-updates',
    'noble-security',
    'noble-backports',
)
PHASE2_DEFAULT_COMPONENTS = ('main', 'restricted', 'universe', 'multiverse')
PROTECTED_PACKAGES = (
    'python3-gevent',
    'python3-kazoo',
    'python3-pyinotify',
    'aella-da-services',
    'aella-da-cli',
    'aella-uvp-2404',
)
VIRTUAL_OR_BASE_SKIP = frozenset((
    'libc6', 'libgcc-s1', 'libstdc++6', 'base-files', 'dpkg',
    'python3', 'python3-minimal', 'python3.12', 'python3.12-minimal',
))
ARTIFACT_NAME = 'phase2-ubuntu-prerequisites.tar.gz'
MANIFEST_NAME = 'phase2-ubuntu-prerequisites.manifest.json'
STATE_NAME = 'phase2-ubuntu-prerequisites.state'
INSTALL_ORDER_NAME = 'install-order.txt'
DEFAULT_ARCHIVE_BASE = 'http://archive.ubuntu.com/ubuntu'
DEFAULT_SECURITY_BASE = 'http://security.ubuntu.com/ubuntu'


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def dump_json(obj, path=None):
    text = json.dumps(obj, indent=2, sort_keys=True, separators=(',', ': ')) + '\n'
    if path:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(text)
    return text


def parse_control_text(text):
    if sm is not None:
        return sm.parse_control_text(text)
    fields = OrderedDict()
    key = None
    for line in text.splitlines():
        if not line:
            continue
        if key and line[:1] in ' \t':
            fields[key] = fields.get(key, '') + '\n' + line
            continue
        if ':' in line:
            k, v = line.split(':', 1)
            key = k.strip()
            fields[key] = v.strip()
    return fields


def _control_from_deb_filename(name):
    """Best-effort Package/Version/Arch from a .deb filename."""
    base = os.path.basename(name)
    if base.endswith('.deb'):
        base = base[:-4]
    m = re.match(r'^(.+)_([^_]+)_([^_]+)$', base)
    if not m:
        return OrderedDict([('Package', base)])
    return OrderedDict([
        ('Package', m.group(1)),
        ('Version', m.group(2)),
        ('Architecture', m.group(3)),
    ])


def inspect_one_deb(path, source_label='acps_deb'):
    """Read Package/Depends metadata from one .deb. Never modifies the file."""
    fn = os.path.basename(path)
    fields = _control_from_deb_filename(fn)
    sidecar = path + '.control'
    if os.path.isfile(sidecar):
        with open(sidecar, 'r') as fh:
            fields = parse_control_text(fh.read())
    elif sm is not None:
        try:
            fields = sm.parse_deb_control(path)
        except Exception:
            fields = _control_from_deb_filename(fn)
    name = fields.get('Package') or _control_from_deb_filename(fn).get('Package')
    return OrderedDict([
        ('package', name),
        ('version', fields.get('Version', '')),
        ('architecture', fields.get('Architecture', '')),
        ('depends', fields.get('Depends', '')),
        ('pre_depends', fields.get('Pre-Depends', '')),
        ('filename', fn),
        ('path', path),
        ('source', source_label),
    ])


def inspect_deb_paths(paths):
    """Inspect extra ACPS/Aella .deb files as additional closure roots.

    Used for published files such as aella-uvp-*.deb / aella-da-*.deb so
    their Ubuntu Depends (for example python3-openssl) enter the recursive
    closure. Original files are never modified or repacked.
    """
    roots = []
    for path in paths or []:
        if not path:
            continue
        if os.path.isdir(path):
            for dirpath, _dns, filenames in os.walk(path):
                for fn in filenames:
                    if fn.endswith('.deb'):
                        roots.append(
                            inspect_one_deb(
                                os.path.join(dirpath, fn),
                                source_label='acps_extra_deb',
                            )
                        )
            continue
        if os.path.isfile(path):
            roots.append(inspect_one_deb(path, source_label='acps_extra_deb'))
    roots.sort(key=lambda r: r.get('package') or '')
    return roots


def collect_phase2_roots(source, extra_debs=None, work_dir=None):
    """ACPS py3-apt roots plus optional extra Aella/UVP .deb metadata."""
    by_name = OrderedDict()
    for rec in inspect_acps_py3_apt_packages(source, work_dir=work_dir):
        name = rec.get('package')
        if name:
            by_name[name] = rec
    for rec in inspect_deb_paths(extra_debs):
        name = rec.get('package')
        if name:
            by_name[name] = rec
    return list(by_name.values())


def extra_debs_from_args(args):
    raw = getattr(args, 'extra_deb', None) or []
    if isinstance(raw, str):
        return [p for p in raw.split(',') if p]
    return [p for p in raw if p]


def inspect_acps_py3_apt_packages(source, work_dir=None):
    """Return root package metadata from an ACPS py3-apt-packages payload.

    ``source`` may be a .tar.gz, a directory of .deb files, or a directory
    containing py3-apt-packages.tar.gz. Original ACPS files are never modified.
    """
    cleanup = None
    roots = []
    try:
        if os.path.isfile(source) and tarfile.is_tarfile(source):
            extract_dir = work_dir or tempfile.mkdtemp(prefix='phase2-py3-apt-')
            if work_dir is None:
                cleanup = extract_dir
            with tarfile.open(source, 'r:*') as tf:
                tf.extractall(extract_dir)
            source = extract_dir
        elif os.path.isdir(source):
            inner = os.path.join(source, 'py3-apt-packages.tar.gz')
            if os.path.isfile(inner):
                return inspect_acps_py3_apt_packages(inner, work_dir=work_dir)
        else:
            raise IOError('ACPS py3-apt source not found: %s' % source)

        for dirpath, _dns, filenames in os.walk(source):
            for fn in filenames:
                if not fn.endswith('.deb'):
                    continue
                roots.append(
                    inspect_one_deb(
                        os.path.join(dirpath, fn),
                        source_label='acps_py3_apt_packages',
                    )
                )
        roots.sort(key=lambda r: r.get('package') or '')
        return roots
    finally:
        if cleanup:
            shutil.rmtree(cleanup, ignore_errors=True)


def roots_as_index(roots):
    """Turn inspected ACPS roots into a mini package index for closure."""
    packages = OrderedDict()
    for rec in roots:
        name = rec.get('package')
        if not name:
            continue
        stanza = OrderedDict([
            ('Package', name),
            ('Version', rec.get('version') or ''),
            ('Architecture', rec.get('architecture') or ''),
            ('Depends', rec.get('depends') or ''),
            ('Pre-Depends', rec.get('pre_depends') or ''),
            ('_suite', 'acps'),
            ('_component', 'acps'),
        ])
        packages[name] = stanza
    return packages


def load_noble_packages(ubuntu_root, suites=None, components=None, arch='amd64'):
    suites = suites or PHASE2_DEFAULT_SUITES
    components = components or PHASE2_DEFAULT_COMPONENTS
    return xba.load_suite_packages(ubuntu_root, suites, components, arch=arch)


def merge_package_indexes(*indexes):
    """Later indexes override earlier ones (caller puts preferred last)."""
    merged = OrderedDict()
    for idx in indexes:
        if not idx:
            continue
        merged.update(idx)
    return merged


def resolve_phase2_dependency_closure(root_names, packages, extra_root_stanzas=None):
    """Resolve recursive Depends/Pre-Depends for Phase 2 Ubuntu packages.

    ACPS root stanzas (when provided) are merged first so the resolver sees
    the actual Depends declared by the extracted ACPS debs, then overlay
    mirror index versions of the same names.
    """
    combined = OrderedDict()
    if packages:
        combined.update(packages)
    # ACPS root stanzas overlay last so the extracted .deb Depends/Pre-Depends
    # are the requirements we actually have to satisfy.
    if extra_root_stanzas:
        combined.update(extra_root_stanzas)
    closure = xba.follow_dependency_closure(
        combined,
        list(root_names),
        fields=PHASE2_PREREQ_FIELDS,
        prefer_available=True,
    )
    closure['algorithm'] = 'follow_dependency_closure'
    closure['prefer_available'] = True
    return closure


def unsatisfied_from_acps(closure, acps_names):
    """Ubuntu packages in the closure that ACPS did not already ship.

    Vendor/Aella packages (aella-*) may appear as extra roots or as Depends
    of those roots. They are not Ubuntu mirror candidates and must not be
    packed into the prerequisite artifact or fail candidate checks.
    """
    acps = set(acps_names)
    visited = list(closure.get('visited') or [])
    missing = list(closure.get('missing_from_index') or [])
    needed = []
    skipped_vendor = []
    for name in visited:
        if name in acps:
            continue
        if name in VIRTUAL_OR_BASE_SKIP:
            continue
        if name.startswith('aella-'):
            skipped_vendor.append(name)
            continue
        needed.append(name)
    return OrderedDict([
        ('acps_root_count', len(acps)),
        ('closure_visited_count', len(visited)),
        ('unsatisfied', needed),
        ('missing_from_index', missing),
        ('skipped_vendor', skipped_vendor),
    ])


def package_record(name, info):
    return OrderedDict([
        ('package', name),
        ('version', (info or {}).get('Version', '')),
        ('architecture', (info or {}).get('Architecture', '')),
        ('suite', (info or {}).get('_suite', '')),
        ('component', (info or {}).get('_component', '')),
        ('filename', (info or {}).get('Filename', '')),
        ('sha256', (info or {}).get('SHA256', '')),
        ('size', (info or {}).get('Size', '')),
        ('depends', (info or {}).get('Depends', '')),
        ('pre_depends', (info or {}).get('Pre-Depends', '')),
    ])


def package_upstream_url(suite, filename, archive_base=None, security_base=None):
    """Build the official Ubuntu pool URL from Packages Filename + suite.

    Does not invent pool paths. Filename comes from the Packages index.
    noble-security uses the security pocket base; all other suites use archive.
    """
    filename = (filename or '').lstrip('/')
    if not filename:
        return ''
    archive_base = (archive_base or DEFAULT_ARCHIVE_BASE).rstrip('/')
    security_base = (security_base or DEFAULT_SECURITY_BASE).rstrip('/')
    suite = suite or ''
    if suite.endswith('-security') or suite == 'security':
        base = security_base
    else:
        base = archive_base
    return '%s/%s' % (base, filename)


def _parse_size(value):
    if value in (None, ''):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def read_deb_control(path):
    """Return control fields from a .deb. Prefer selective_mirror.parse_deb_control."""
    if sm is not None:
        try:
            return sm.parse_deb_control(path)
        except Exception:
            pass
    try:
        out = subprocess.check_output(
            ['dpkg-deb', '-I', path, 'control'],
            stderr=subprocess.DEVNULL,
        ).decode('utf-8', 'replace')
        return parse_control_text(out)
    except (OSError, subprocess.CalledProcessError):
        return OrderedDict()


def verify_local_package_file(path, rec):
    """Verify on-disk .deb against index metadata. Empty reason means OK."""
    if not path or not os.path.isfile(path):
        return 'deb_absent'
    expected_size = _parse_size(rec.get('size'))
    if expected_size is not None:
        try:
            actual_size = os.path.getsize(path)
        except OSError:
            return 'size_unreadable'
        if actual_size != expected_size:
            return 'size_mismatch expected=%s actual=%s' % (expected_size, actual_size)
    expected_sha = (rec.get('sha256') or '').strip().lower()
    if expected_sha:
        actual_sha = sha256_file(path).lower()
        if actual_sha != expected_sha:
            return 'sha256_mismatch expected=%s actual=%s' % (expected_sha, actual_sha)
    fields = read_deb_control(path)
    if fields:
        pkg = fields.get('Package') or ''
        ver = fields.get('Version') or ''
        arch = fields.get('Architecture') or ''
        if rec.get('package') and pkg and pkg != rec.get('package'):
            return 'control_package_mismatch expected=%s actual=%s' % (
                rec.get('package'), pkg,
            )
        if rec.get('version') and ver and ver != rec.get('version'):
            return 'control_version_mismatch expected=%s actual=%s' % (
                rec.get('version'), ver,
            )
        expected_arch = rec.get('architecture') or ''
        if expected_arch and arch and arch != expected_arch and arch != 'all':
            return 'control_architecture_mismatch expected=%s actual=%s' % (
                expected_arch, arch,
            )
    return ''


def direct_install_deps(name, packages, install_set):
    """Depends/Pre-Depends of name that are also in the install set."""
    info = (packages or {}).get(name) or {}
    deps = []
    seen = set()
    for field in PHASE2_PREREQ_FIELDS:
        for dep in xba.dep_names(info.get(field), packages):
            if dep in install_set and dep != name and dep not in seen:
                seen.add(dep)
                deps.append(dep)
    return deps


def _tarjan_scc(nodes, successors):
    """Deterministic Tarjan strongly connected components."""
    nodes = sorted(nodes)
    index_counter = [0]
    stack = []
    onstack = set()
    index = {}
    lowlink = {}
    components = []

    def strongconnect(v):
        index[v] = index_counter[0]
        lowlink[v] = index_counter[0]
        index_counter[0] += 1
        stack.append(v)
        onstack.add(v)
        for w in sorted(successors.get(v, ())):
            if w not in index:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif w in onstack:
                lowlink[v] = min(lowlink[v], index[w])
        if lowlink[v] == index[v]:
            comp = []
            while True:
                w = stack.pop()
                onstack.discard(w)
                comp.append(w)
                if w == v:
                    break
            components.append(tuple(sorted(comp)))

    for v in nodes:
        if v not in index:
            strongconnect(v)
    return components


def build_install_plan(package_names, packages):
    """Deterministic dependency-aware install plan (deps before dependents).

    Shared dependencies appear once. Cycles become one SCC group installed
    together (one dpkg -i invocation), not a false claim of strict order.
    """
    names = []
    seen = set()
    for name in package_names or []:
        if name and name not in seen:
            seen.add(name)
            names.append(name)
    install_set = set(names)
    successors = defaultdict(list)  # dep -> packages that require it
    predecessors = defaultdict(list)  # package -> deps in install set
    for name in names:
        for dep in direct_install_deps(name, packages, install_set):
            predecessors[name].append(dep)
            successors[dep].append(name)
    sccs = _tarjan_scc(install_set, predecessors)
    scc_of = {}
    for scc in sccs:
        for name in scc:
            scc_of[name] = scc
    scc_succ = defaultdict(set)
    for name in names:
        src = scc_of[name]
        for dep in predecessors.get(name, ()):
            dst = scc_of[dep]
            if dst != src:
                # dest SCC must be installed before src SCC
                scc_succ[dst].add(src)
    incoming = {scc: 0 for scc in sccs}
    for src, dests in scc_succ.items():
        for dest in dests:
            incoming[dest] = incoming.get(dest, 0) + 1
    ready = sorted(
        [scc for scc in sccs if incoming.get(scc, 0) == 0],
        key=lambda s: s,
    )
    ordered_sccs = []
    remaining = set(sccs)
    while ready:
        scc = ready.pop(0)
        if scc not in remaining:
            continue
        remaining.discard(scc)
        ordered_sccs.append(scc)
        for dest in sorted(scc_succ.get(scc, ())):
            incoming[dest] -= 1
            if incoming[dest] == 0 and dest in remaining:
                ready.append(dest)
                ready.sort()
    if remaining:
        # Should not happen after Tarjan; append leftover SCCs deterministically.
        ordered_sccs.extend(sorted(remaining))
    groups = [list(scc) for scc in ordered_sccs]
    flat = []
    for group in groups:
        flat.extend(group)
    return OrderedDict([
        ('algorithm', 'tarjan_scc_topo'),
        ('package_count', len(names)),
        ('group_count', len(groups)),
        ('cycle_group_count', sum(1 for g in groups if len(g) > 1)),
        ('install_groups', groups),
        ('install_order', flat),
    ])


def write_install_order_text(groups, filename_by_package):
    """One dpkg -i group per line; space-separated artifact filenames."""
    lines = [
        '# PHASE2_PREREQ_INSTALL_ORDER',
        '# One dpkg -i invocation per line. Space-separated files are one SCC group.',
    ]
    for group in groups:
        files = []
        for name in group:
            fn = filename_by_package.get(name)
            if fn:
                files.append(fn)
        if files:
            lines.append(' '.join(files))
    return '\n'.join(lines) + '\n'


def write_prerequisite_state(path, fields):
    """Write machine-readable PHASE2_PREREQ_* key=value state."""
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    lines = []
    for key, value in fields.items():
        if value is None:
            value = ''
        lines.append('%s=%s' % (key, value))
    text = '\n'.join(lines) + '\n'
    tmp = path + '.part'
    with open(tmp, 'w') as fh:
        fh.write(text)
    os.rename(tmp, path)
    return text


def collect_artifact_packages(unsatisfied_names, packages, pool_root=None):
    """Map unsatisfied names to index records and optional on-disk .deb paths."""
    rows = []
    missing_candidate = []
    missing_deb = []
    for name in unsatisfied_names:
        info = (packages or {}).get(name)
        rec = package_record(name, info)
        if not info:
            rec['candidate'] = 'none'
            rec['deb_path'] = ''
            missing_candidate.append(name)
            rows.append(rec)
            continue
        rec['candidate'] = '%s/%s' % (
            info.get('_suite') or '',
            info.get('_component') or '',
        )
        rec['url'] = package_upstream_url(
            rec.get('suite'), rec.get('filename'),
        )
        deb_path = ''
        filename = info.get('Filename') or ''
        if pool_root and filename:
            cand = os.path.join(pool_root, filename)
            if os.path.isfile(cand):
                reason = verify_local_package_file(cand, rec)
                if reason:
                    rec['local_verify'] = reason
                else:
                    deb_path = cand
                    rec['local_verify'] = 'ok'
        if not deb_path and pool_root:
            # Search pool by package name as a last resort.
            for dirpath, _dns, filenames in os.walk(pool_root):
                for fn in filenames:
                    if fn.startswith(name + '_') and fn.endswith('.deb'):
                        cand = os.path.join(dirpath, fn)
                        reason = verify_local_package_file(cand, rec)
                        if not reason:
                            deb_path = cand
                            rec['filename'] = os.path.relpath(deb_path, pool_root)
                            rec['local_verify'] = 'ok'
                            break
                if deb_path:
                    break
        rec['deb_path'] = deb_path
        if not deb_path:
            missing_deb.append(name)
        rows.append(rec)
    return OrderedDict([
        ('packages', rows),
        ('missing_candidate', missing_candidate),
        ('missing_deb', missing_deb),
    ])


def acquire_missing_debs(
    collected, ubuntu_root, archive_base=None, security_base=None,
):
    """Fetch missing .debs via selective_mirror.acquire_file and verify them.

    Reuses the existing trusted downloader. Does not invent URLs: Filename
    comes from the Packages index; the base is the suite's archive/security
    repository root.
    """
    acquired = []
    failed = []
    skipped = []
    if sm is None:
        for name in collected.get('missing_deb') or []:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=selective_mirror_unavailable' % name)
        return OrderedDict([
            ('acquired', acquired),
            ('failed', failed),
            ('skipped', skipped),
        ])
    rows_by_name = OrderedDict(
        (rec.get('package'), rec) for rec in (collected.get('packages') or [])
    )
    still_missing = []
    for name in collected.get('missing_deb') or []:
        rec = rows_by_name.get(name) or {}
        filename = rec.get('filename') or ''
        if not filename:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=filename_missing' % name)
            continue
        dest = os.path.join(ubuntu_root, filename)
        url = package_upstream_url(
            rec.get('suite'), filename, archive_base, security_base,
        )
        rec['url'] = url
        expected_sha = (rec.get('sha256') or '').strip() or None
        expected_size = _parse_size(rec.get('size'))
        eprint('PHASE2_PREREQ_ACQUIRE=START package=%s suite=%s component=%s sha256=%s' % (
            name, rec.get('suite') or '', rec.get('component') or '',
            expected_sha or '',
        ))
        try:
            sm.acquire_file(
                src='',
                dst=dest,
                allow_download_url=url,
                expected_sha256=expected_sha,
                expected_size=expected_size,
            )
        except Exception as exc:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=%s' % (
                name, type(exc).__name__,
            ))
            continue
        reason = verify_local_package_file(dest, rec)
        if reason:
            failed.append(name)
            eprint('PHASE2_PREREQ_ACQUIRE=FAIL package=%s reason=%s' % (name, reason))
            continue
        rec['deb_path'] = dest
        rec['acquired'] = True
        rec['local_verify'] = 'ok'
        acquired.append(name)
        eprint('PHASE2_PREREQ_ACQUIRE=PASS package=%s path=%s' % (name, dest))
    collected['missing_deb'] = [
        n for n in (collected.get('missing_deb') or [])
        if n not in acquired
    ]
    for rec in collected.get('packages') or []:
        if rec.get('package') in acquired:
            continue
        if rec.get('deb_path'):
            skipped.append(rec.get('package'))
        elif rec.get('candidate') != 'none' and rec.get('package'):
            still_missing.append(rec.get('package'))
    collected['missing_deb'] = [
        n for n in (collected.get('missing_deb') or [])
        if n not in set(acquired)
    ]
    return OrderedDict([
        ('acquired', acquired),
        ('failed', failed),
        ('skipped', skipped),
        ('still_missing', still_missing),
    ])


def parse_apt_simulation(text):
    """Parse apt-get -s / --just-print output for removals and installs."""
    removals = []
    installs = []
    for raw in (text or '').splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.match(r'^(Inst|Remv|Purg)\s+(\S+)', line)
        if not m:
            # Also accept "Removing python3-gevent" prose.
            m2 = re.match(r'^(?:Removing|Purging)\s+(\S+)', line)
            if m2:
                removals.append(m2.group(1).rstrip('.'))
            continue
        action, pkg = m.group(1), m.group(2)
        if action in ('Remv', 'Purg'):
            removals.append(pkg)
        elif action == 'Inst':
            installs.append(pkg)
    return OrderedDict([
        ('installs', installs),
        ('removals', removals),
    ])


def transaction_is_safe(simulation, extra_protected=None):
    """Reject a simulated apt transaction that would remove protected packages."""
    protected = set(PROTECTED_PACKAGES)
    if extra_protected:
        protected.update(extra_protected)
    parsed = simulation
    if not isinstance(simulation, dict):
        parsed = parse_apt_simulation(simulation)
    removals = list(parsed.get('removals') or [])
    blocked = [p for p in removals if p in protected]
    return OrderedDict([
        ('safe', len(blocked) == 0),
        ('removals', removals),
        ('blocked_removals', blocked),
        ('protected', sorted(protected)),
    ])


def build_prerequisite_artifact(package_rows, dest_dir, include_missing=False,
                                install_plan=None):
    """Write phase2-ubuntu-prerequisites.tar.gz + manifest + sha256 sidecar.

    Every required row must have an on-disk .deb. Partial artifacts are never
    published. ``include_missing`` is rejected: omitting a required .deb is
    a hard failure.
    """
    if include_missing:
        raise ValueError('include_missing is not allowed for production artifacts')
    os.makedirs(dest_dir, exist_ok=True)
    required = list(package_rows or [])
    missing = [
        rec.get('package') or rec.get('artifact_filename') or '?'
        for rec in required
        if not rec.get('deb_path') or not os.path.isfile(rec.get('deb_path') or '')
    ]
    if missing:
        eprint('PHASE2_PREREQ_MISSING_DEB=%s' % ','.join(missing))
        eprint('PHASE2_PREREQ_BUILD=FAIL reason=missing_deb')
        return None
    work = tempfile.mkdtemp(prefix='phase2-prereq-art-')
    packed = []
    try:
        debs_dir = os.path.join(work, 'debs')
        os.makedirs(debs_dir)
        filename_by_package = OrderedDict()
        for rec in required:
            src = rec.get('deb_path')
            dest_name = os.path.basename(src)
            shutil.copy2(src, os.path.join(debs_dir, dest_name))
            out = OrderedDict(rec)
            out['artifact_filename'] = dest_name
            packed.append(out)
            if out.get('package'):
                filename_by_package[out['package']] = dest_name
        plan = install_plan
        if plan is None:
            # Fall back to package-index Depends using packed rows as a mini index.
            mini = OrderedDict()
            for rec in packed:
                mini[rec.get('package')] = OrderedDict([
                    ('Package', rec.get('package') or ''),
                    ('Depends', rec.get('depends') or ''),
                    ('Pre-Depends', rec.get('pre_depends') or ''),
                ])
            plan = build_install_plan(
                [rec.get('package') for rec in packed if rec.get('package')],
                mini,
            )
        order_text = write_install_order_text(
            plan.get('install_groups') or [], filename_by_package,
        )
        with open(os.path.join(work, INSTALL_ORDER_NAME), 'w') as fh:
            fh.write(order_text)
        manifest = OrderedDict([
            ('artifact', ARTIFACT_NAME),
            ('package_count', len(packed)),
            ('required_package_count', len(required)),
            ('packages', packed),
            ('install_order', list(plan.get('install_order') or [])),
            ('install_groups', list(plan.get('install_groups') or [])),
            ('install_plan_algorithm', plan.get('algorithm') or ''),
            ('protected_packages', list(PROTECTED_PACKAGES)),
            ('fields', list(PHASE2_PREREQ_FIELDS)),
            ('acps_payload_modified', False),
        ])
        dump_json(manifest, os.path.join(work, MANIFEST_NAME))
        artifact_path = os.path.join(dest_dir, ARTIFACT_NAME)
        tmp_art = artifact_path + '.part'
        with tarfile.open(tmp_art, 'w:gz') as tf:
            tf.add(os.path.join(work, MANIFEST_NAME), arcname=MANIFEST_NAME)
            tf.add(os.path.join(work, INSTALL_ORDER_NAME), arcname=INSTALL_ORDER_NAME)
            packed_names = set()
            for rec in packed:
                fn = rec.get('artifact_filename')
                if not fn:
                    continue
                packed_names.add(fn)
                tf.add(os.path.join(debs_dir, fn), arcname='debs/%s' % fn)
        os.rename(tmp_art, artifact_path)
        digest = sha256_file(artifact_path)
        sidecar = artifact_path + '.sha256'
        with open(sidecar, 'w') as fh:
            fh.write('%s  %s\n' % (digest, ARTIFACT_NAME))
        manifest['sha256'] = digest
        manifest['artifact_path'] = artifact_path
        dump_json(manifest, os.path.join(dest_dir, MANIFEST_NAME))
        with open(os.path.join(dest_dir, INSTALL_ORDER_NAME), 'w') as fh:
            fh.write(order_text)
        verify_reason = verify_built_artifact(
            dest_dir, manifest, required_names=[
                rec.get('package') for rec in required if rec.get('package')
            ],
        )
        if verify_reason:
            eprint('PHASE2_PREREQ_BUILD=FAIL reason=%s' % verify_reason)
            for path in (artifact_path, sidecar):
                try:
                    os.unlink(path)
                except OSError:
                    pass
            return None
        return manifest
    finally:
        shutil.rmtree(work, ignore_errors=True)


def verify_built_artifact(dest_dir, manifest, required_names=None):
    """Post-build gate: complete, no extras, control/checksums match."""
    artifact_path = os.path.join(dest_dir, ARTIFACT_NAME)
    if not os.path.isfile(artifact_path):
        return 'artifact_missing'
    required_names = list(required_names or [])
    if manifest.get('package_count') != len(required_names):
        return 'package_count_mismatch manifest=%s required=%s' % (
            manifest.get('package_count'), len(required_names),
        )
    extract = tempfile.mkdtemp(prefix='phase2-prereq-verify-')
    try:
        with tarfile.open(artifact_path, 'r:gz') as tf:
            members = tf.getnames()
            tf.extractall(extract)
        deb_members = [n for n in members if n.startswith('debs/') and n.endswith('.deb')]
        unexpected = [
            n for n in members
            if n not in (MANIFEST_NAME, INSTALL_ORDER_NAME)
            and not n.startswith('debs/')
        ]
        if unexpected:
            return 'unexpected_members=%s' % ','.join(sorted(unexpected))
        packed = list(manifest.get('packages') or [])
        if len(deb_members) != len(packed):
            return 'tar_deb_count_mismatch tar=%s manifest=%s' % (
                len(deb_members), len(packed),
            )
        seen_files = set()
        for rec in packed:
            fn = rec.get('artifact_filename')
            if not fn:
                return 'manifest_filename_missing package=%s' % rec.get('package')
            tar_path = os.path.join(extract, 'debs', fn)
            if not os.path.isfile(tar_path):
                return 'deb_missing_in_tar file=%s' % fn
            seen_files.add('debs/%s' % fn)
            reason = verify_local_package_file(tar_path, rec)
            if reason:
                return 'verify_fail package=%s %s' % (rec.get('package'), reason)
        extra_debs = [n for n in deb_members if n not in seen_files]
        if extra_debs:
            return 'unexpected_deb=%s' % ','.join(sorted(extra_debs))
        order_path = os.path.join(extract, INSTALL_ORDER_NAME)
        if packed and not os.path.isfile(order_path):
            return 'install_order_missing'
        if packed:
            with open(order_path, 'r') as fh:
                order_text = fh.read()
            ordered_files = []
            for line in order_text.splitlines():
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                ordered_files.extend(line.split())
            manifest_files = [rec.get('artifact_filename') for rec in packed]
            if sorted(ordered_files) != sorted(manifest_files):
                return 'install_order_filename_mismatch'
        return ''
    finally:
        shutil.rmtree(extract, ignore_errors=True)


def ensure_packages_in_selective(ubuntu_root, package_rows, copy_debs=True):
    """Place resolved .debs into the selective pool using index Filename paths.

    Does not rewrite Release signatures here; Packages stanza presence is
    verified by the caller against the already-published indexes. New files
    are copied into pool/<Filename> so a later index regenerate can see them.
    """
    placed = []
    skipped = []
    for rec in package_rows:
        src = rec.get('deb_path') or ''
        filename = rec.get('filename') or ''
        if not src or not os.path.isfile(src):
            skipped.append(rec.get('package'))
            continue
        if not filename:
            pkg = rec.get('package') or 'unknown'
            arch = rec.get('architecture') or 'amd64'
            ver = rec.get('version') or '0'
            component = rec.get('component') or 'universe'
            filename = 'pool/%s/%s/%s/%s_%s_%s.deb' % (
                component, pkg[:1] if pkg else 'u', pkg, pkg, ver, arch,
            )
        dest = os.path.join(ubuntu_root, filename)
        if copy_debs:
            parent = os.path.dirname(dest)
            os.makedirs(parent, exist_ok=True)
            if os.path.abspath(src) != os.path.abspath(dest):
                shutil.copy2(src, dest)
        placed.append(OrderedDict([
            ('package', rec.get('package')),
            ('filename', filename),
            ('dest', dest),
        ]))
    return OrderedDict([
        ('placed', placed),
        ('skipped', skipped),
    ])


def run_inspect(args):
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    out = OrderedDict([
        ('root_count', len(roots)),
        ('roots', [
            OrderedDict((k, r[k]) for k in (
                'package', 'version', 'architecture', 'depends', 'pre_depends',
                'filename', 'source',
            ) if k in r)
            for r in roots
        ]),
    ])
    dump_json(out, args.output)
    print('PHASE2_PREREQ_ROOTS=%d' % len(roots))
    return 0


def _emit_prereq_state(dest_dir, required, count, build, publication,
                       missing_candidate=None, missing_deb=None, sha256='',
                       artifact=''):
    fields = OrderedDict([
        ('PHASE2_PREREQ_REQUIRED', required),
        ('PHASE2_PREREQ_PACKAGE_COUNT', str(count)),
        ('PHASE2_PREREQ_BUILD', build),
        ('PHASE2_PREREQ_PUBLICATION', publication),
        ('PHASE2_PREREQ_MISSING_CANDIDATE', str(len(missing_candidate or []))),
        ('PHASE2_PREREQ_MISSING_DEB', str(len(missing_deb or []))),
        ('PHASE2_PREREQ_ARTIFACT', artifact or ARTIFACT_NAME),
        ('PHASE2_PREREQ_SHA256', sha256 or ''),
    ])
    if missing_candidate:
        fields['PHASE2_PREREQ_MISSING_CANDIDATE_PACKAGES'] = ','.join(missing_candidate)
    if missing_deb:
        fields['PHASE2_PREREQ_MISSING_DEB_PACKAGES'] = ','.join(missing_deb)
    path = os.path.join(dest_dir, STATE_NAME) if dest_dir else None
    if path:
        write_prerequisite_state(path, fields)
    for key, value in fields.items():
        print('%s=%s' % (key, value))
    return fields


def _load_packages_for_args(args):
    return load_noble_packages(
        args.ubuntu_root,
        suites=args.suites.split(',') if getattr(args, 'suites', None) else None,
        components=args.components.split() if getattr(args, 'components', None) else None,
    )


def run_resolve(args):
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    root_names = [r['package'] for r in roots if r.get('package')]
    extra = roots_as_index(roots)
    packages, _prov = _load_packages_for_args(args)
    closure = resolve_phase2_dependency_closure(root_names, packages, extra)
    unsat = unsatisfied_from_acps(closure, root_names)
    collected = collect_artifact_packages(
        unsat['unsatisfied'], packages, pool_root=args.ubuntu_root,
    )
    plan = build_install_plan(unsat['unsatisfied'], packages)
    result = OrderedDict([
        ('roots', root_names),
        ('closure', closure),
        ('unsatisfied', unsat),
        ('collected', collected),
        ('install_plan', plan),
    ])
    dump_json(result, args.output)
    print('PHASE2_PREREQ_ROOTS=%d' % len(root_names))
    print('PHASE2_PREREQ_CLOSURE=%d' % closure.get('visited_count', 0))
    print('PHASE2_PREREQ_UNSATISFIED=%d' % len(unsat['unsatisfied']))
    print('PHASE2_PREREQ_MISSING_CANDIDATE=%d' % len(collected['missing_candidate']))
    print('PHASE2_PREREQ_MISSING_DEB=%d' % len(collected['missing_deb']))
    if collected['missing_candidate'] and not args.allow_missing_candidate:
        eprint('PHASE2_PREREQ_CANDIDATE=NONE packages=%s' %
               ','.join(collected['missing_candidate']))
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 2
    if collected['missing_deb'] and not getattr(args, 'allow_missing_deb', False):
        eprint('PHASE2_PREREQ_MISSING_DEB=%s' % ','.join(collected['missing_deb']))
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 4
    return 0


def run_build(args):
    dest = args.dest
    os.makedirs(dest, exist_ok=True)
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    root_names = [r['package'] for r in roots if r.get('package')]
    extra = roots_as_index(roots)
    packages, _prov = _load_packages_for_args(args)
    closure = resolve_phase2_dependency_closure(root_names, packages, extra)
    unsat = unsatisfied_from_acps(closure, root_names)
    collected = collect_artifact_packages(
        unsat['unsatisfied'], packages, pool_root=args.ubuntu_root,
    )
    if collected['missing_candidate'] and not args.allow_missing_candidate:
        eprint('PHASE2_PREREQ_CANDIDATE=NONE packages=%s' %
               ','.join(collected['missing_candidate']))
        _emit_prereq_state(
            dest, 'YES' if unsat['unsatisfied'] else 'NO',
            len(unsat['unsatisfied']), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
        )
        eprint('PHASE2_PREREQ_BUILD=FAIL')
        return 2

    skip_acquire = getattr(args, 'skip_acquire', False)
    if collected['missing_deb'] and not skip_acquire:
        acquire_missing_debs(
            collected,
            args.ubuntu_root,
            archive_base=getattr(args, 'archive_base', None),
            security_base=getattr(args, 'security_base', None),
        )
        collected['missing_deb'] = [
            rec.get('package') for rec in collected.get('packages') or []
            if rec.get('candidate') != 'none' and not rec.get('deb_path')
        ]

    if collected['missing_deb']:
        eprint('PHASE2_PREREQ_MISSING_DEB=%s' % ','.join(collected['missing_deb']))
        _emit_prereq_state(
            dest, 'YES', len(unsat['unsatisfied']), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
        )
        eprint('PHASE2_PREREQ_BUILD=FAIL reason=missing_deb')
        return 4

    required_rows = [
        rec for rec in collected.get('packages') or []
        if rec.get('candidate') != 'none'
    ]
    plan = build_install_plan(
        [rec.get('package') for rec in required_rows if rec.get('package')],
        packages,
    )
    required = 'YES' if required_rows else 'NO'
    if not required_rows:
        manifest = build_prerequisite_artifact([], dest, install_plan=plan)
        if manifest is None:
            _emit_prereq_state(dest, 'NO', 0, 'FAIL', 'FAIL')
            return 5
        _emit_prereq_state(
            dest, 'NO', 0, 'PASS', 'PASS',
            sha256=manifest.get('sha256'),
            artifact=ARTIFACT_NAME,
        )
        print('PHASE2_PREREQ_ARTIFACT=%s' % manifest.get('artifact_path'))
        print('PHASE2_PREREQ_PACKAGE_COUNT=0')
        print('PHASE2_PREREQ_SHA256=%s' % manifest.get('sha256'))
        return 0

    manifest = build_prerequisite_artifact(
        required_rows, dest, install_plan=plan,
    )
    if manifest is None:
        _emit_prereq_state(
            dest, required, len(required_rows), 'FAIL', 'FAIL',
            missing_candidate=collected['missing_candidate'],
            missing_deb=collected['missing_deb'],
        )
        return 5
    if getattr(args, 'ensure_selective', False):
        ensure_packages_in_selective(args.ubuntu_root, required_rows)
    _emit_prereq_state(
        dest, required, manifest.get('package_count', 0), 'PASS', 'PASS',
        sha256=manifest.get('sha256'),
        artifact=ARTIFACT_NAME,
    )
    print('PHASE2_PREREQ_ARTIFACT=%s' % manifest.get('artifact_path'))
    print('PHASE2_PREREQ_PACKAGE_COUNT=%d' % manifest.get('package_count', 0))
    print('PHASE2_PREREQ_SHA256=%s' % manifest.get('sha256'))
    return 0


def run_transaction(args):
    text = args.simulation
    if args.simulation_file:
        with open(args.simulation_file, 'r') as fh:
            text = fh.read()
    result = transaction_is_safe(text)
    dump_json(result, args.output)
    print('PHASE2_PREREQ_TRANSACTION_SAFE=%s' % ('YES' if result['safe'] else 'NO'))
    if result['blocked_removals']:
        print('PHASE2_PREREQ_BLOCKED_REMOVALS=%s' % ','.join(result['blocked_removals']))
        return 3
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Phase 2 Ubuntu prerequisite dependency closure',
    )
    sub = parser.add_subparsers(dest='cmd')

    p_ins = sub.add_parser('inspect')
    p_ins.add_argument('--source', required=True)
    p_ins.add_argument('--extra-deb', action='append', default=[])
    p_ins.add_argument('--output')
    p_ins.set_defaults(func=run_inspect)

    p_res = sub.add_parser('resolve')
    p_res.add_argument('--source', required=True)
    p_res.add_argument('--ubuntu-root', required=True)
    p_res.add_argument('--extra-deb', action='append', default=[])
    p_res.add_argument('--suites')
    p_res.add_argument('--components')
    p_res.add_argument('--output')
    p_res.add_argument('--allow-missing-candidate', action='store_true')
    p_res.add_argument('--allow-missing-deb', action='store_true')
    p_res.set_defaults(func=run_resolve)

    p_bld = sub.add_parser('build')
    p_bld.add_argument('--source', required=True)
    p_bld.add_argument('--ubuntu-root', required=True)
    p_bld.add_argument('--dest', required=True)
    p_bld.add_argument('--extra-deb', action='append', default=[])
    p_bld.add_argument('--suites')
    p_bld.add_argument('--components')
    p_bld.add_argument('--archive-base', default=DEFAULT_ARCHIVE_BASE)
    p_bld.add_argument('--security-base', default=DEFAULT_SECURITY_BASE)
    p_bld.add_argument('--allow-missing-candidate', action='store_true')
    p_bld.add_argument('--skip-acquire', action='store_true')
    p_bld.add_argument('--ensure-selective', action='store_true')
    p_bld.set_defaults(func=run_build)

    p_tx = sub.add_parser('transaction-check')
    p_tx.add_argument('--simulation')
    p_tx.add_argument('--simulation-file')
    p_tx.add_argument('--output')
    p_tx.set_defaults(func=run_transaction)

    args = parser.parse_args(argv)
    if not getattr(args, 'func', None):
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
