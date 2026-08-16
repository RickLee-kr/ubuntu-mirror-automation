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
import sys
import tarfile
import tempfile
from collections import OrderedDict

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
    ])


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
            missing_candidate.append(name)
            rows.append(rec)
            continue
        rec['candidate'] = '%s/%s' % (
            info.get('_suite') or '',
            info.get('_component') or '',
        )
        deb_path = ''
        filename = info.get('Filename') or ''
        if pool_root and filename:
            cand = os.path.join(pool_root, filename)
            if os.path.isfile(cand):
                deb_path = cand
        if not deb_path and pool_root:
            # Search pool by package name as a last resort.
            for dirpath, _dns, filenames in os.walk(pool_root):
                for fn in filenames:
                    if fn.startswith(name + '_') and fn.endswith('.deb'):
                        deb_path = os.path.join(dirpath, fn)
                        rec['filename'] = os.path.relpath(deb_path, pool_root)
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


def build_prerequisite_artifact(package_rows, dest_dir, include_missing=False):
    """Write phase2-ubuntu-prerequisites.tar.gz + manifest + sha256 sidecar.

    Only packages with an on-disk .deb are packed. Returns manifest dict.
    """
    os.makedirs(dest_dir, exist_ok=True)
    work = tempfile.mkdtemp(prefix='phase2-prereq-art-')
    packed = []
    try:
        debs_dir = os.path.join(work, 'debs')
        os.makedirs(debs_dir)
        for rec in package_rows:
            src = rec.get('deb_path') or ''
            if not src or not os.path.isfile(src):
                if include_missing:
                    packed.append(rec)
                continue
            dest_name = os.path.basename(src)
            shutil.copy2(src, os.path.join(debs_dir, dest_name))
            out = OrderedDict(rec)
            out['artifact_filename'] = dest_name
            packed.append(out)
        manifest = OrderedDict([
            ('artifact', ARTIFACT_NAME),
            ('package_count', len(packed)),
            ('packages', packed),
            ('protected_packages', list(PROTECTED_PACKAGES)),
            ('fields', list(PHASE2_PREREQ_FIELDS)),
            ('acps_payload_modified', False),
        ])
        dump_json(manifest, os.path.join(work, MANIFEST_NAME))
        artifact_path = os.path.join(dest_dir, ARTIFACT_NAME)
        tmp_art = artifact_path + '.part'
        with tarfile.open(tmp_art, 'w:gz') as tf:
            tf.add(os.path.join(work, MANIFEST_NAME), arcname=MANIFEST_NAME)
            for rec in packed:
                fn = rec.get('artifact_filename')
                if not fn:
                    continue
                tf.add(os.path.join(debs_dir, fn), arcname='debs/%s' % fn)
        os.rename(tmp_art, artifact_path)
        digest = sha256_file(artifact_path)
        sidecar = artifact_path + '.sha256'
        with open(sidecar, 'w') as fh:
            fh.write('%s  %s\n' % (digest, ARTIFACT_NAME))
        manifest['sha256'] = digest
        manifest['artifact_path'] = artifact_path
        dump_json(manifest, os.path.join(dest_dir, MANIFEST_NAME))
        return manifest
    finally:
        shutil.rmtree(work, ignore_errors=True)


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


def run_resolve(args):
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    root_names = [r['package'] for r in roots if r.get('package')]
    extra = roots_as_index(roots)
    packages, _prov = load_noble_packages(
        args.ubuntu_root,
        suites=args.suites.split(',') if args.suites else None,
        components=args.components.split() if args.components else None,
    )
    closure = resolve_phase2_dependency_closure(root_names, packages, extra)
    unsat = unsatisfied_from_acps(closure, root_names)
    collected = collect_artifact_packages(
        unsat['unsatisfied'], packages, pool_root=args.ubuntu_root,
    )
    result = OrderedDict([
        ('roots', root_names),
        ('closure', closure),
        ('unsatisfied', unsat),
        ('collected', collected),
    ])
    dump_json(result, args.output)
    print('PHASE2_PREREQ_ROOTS=%d' % len(root_names))
    print('PHASE2_PREREQ_CLOSURE=%d' % closure.get('visited_count', 0))
    print('PHASE2_PREREQ_UNSATISFIED=%d' % len(unsat['unsatisfied']))
    print('PHASE2_PREREQ_MISSING_CANDIDATE=%d' % len(collected['missing_candidate']))
    if collected['missing_candidate'] and not args.allow_missing_candidate:
        eprint('PHASE2_PREREQ_CANDIDATE=NONE packages=%s' %
               ','.join(collected['missing_candidate']))
        return 2
    return 0


def run_build(args):
    roots = collect_phase2_roots(args.source, extra_debs_from_args(args))
    root_names = [r['package'] for r in roots if r.get('package')]
    extra = roots_as_index(roots)
    packages, _prov = load_noble_packages(
        args.ubuntu_root,
        suites=args.suites.split(',') if args.suites else None,
        components=args.components.split() if args.components else None,
    )
    closure = resolve_phase2_dependency_closure(root_names, packages, extra)
    unsat = unsatisfied_from_acps(closure, root_names)
    collected = collect_artifact_packages(
        unsat['unsatisfied'], packages, pool_root=args.ubuntu_root,
    )
    if collected['missing_candidate'] and not args.allow_missing_candidate:
        eprint('PHASE2_PREREQ_CANDIDATE=NONE packages=%s' %
               ','.join(collected['missing_candidate']))
        return 2
    manifest = build_prerequisite_artifact(collected['packages'], args.dest)
    if args.ensure_selective:
        ensure_packages_in_selective(args.ubuntu_root, collected['packages'])
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
    p_res.set_defaults(func=run_resolve)

    p_bld = sub.add_parser('build')
    p_bld.add_argument('--source', required=True)
    p_bld.add_argument('--ubuntu-root', required=True)
    p_bld.add_argument('--dest', required=True)
    p_bld.add_argument('--extra-deb', action='append', default=[])
    p_bld.add_argument('--suites')
    p_bld.add_argument('--components')
    p_bld.add_argument('--allow-missing-candidate', action='store_true')
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
