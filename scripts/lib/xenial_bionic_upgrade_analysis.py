#!/usr/bin/env python3
"""Xenial→Bionic selective offline upgrade failure analysis library.

Read-only analysis of repository indexes, discovery/plan provenance,
DistUpgrade SourceEntry semantics, Keep-at-same-version classification,
core package family consistency, and reboot gate proposals.

Does not mutate live DP or published mirrors.
Python 3.5+; stdlib only.
"""
from __future__ import print_function, unicode_literals

import gzip
import hashlib
import json
import os
import re
import time
from collections import OrderedDict, defaultdict, Counter

ERROR_TARGET_SUITE_NOT_DECLARED = 'TARGET_SUITE_NOT_DECLARED'
ERROR_TARGET_COMPONENT_NOT_DECLARED = 'TARGET_COMPONENT_NOT_DECLARED'
ERROR_TARGET_PACKAGES_INDEX_MISSING = 'TARGET_PACKAGES_INDEX_MISSING'
ERROR_TARGET_PACKAGES_INDEX_EMPTY = 'TARGET_PACKAGES_INDEX_EMPTY'
ERROR_RELEASE_PACKAGES_CHECKSUM_MISMATCH = 'RELEASE_PACKAGES_CHECKSUM_MISMATCH'
ERROR_PACKAGES_REFERENCED_DEB_MISSING = 'PACKAGES_REFERENCED_DEB_MISSING'
SEMANTIC_FAIL_EMPTY_TARGET = 'FAIL_EMPTY_TARGET_INDEX'
SEMANTIC_OK_EMPTY_SOURCE = 'OK_EMPTY_SOURCE_STABILIZATION_INDEX'
SEMANTIC_OK = 'OK'
SEMANTIC_FAIL_MISSING = 'FAIL_PACKAGES_MISSING'
SEMANTIC_FAIL_CHECKSUM = 'FAIL_RELEASE_PACKAGES_CHECKSUM'
SEMANTIC_FAIL_DEB = 'FAIL_REFERENCED_DEB_MISSING'

CORE_PACKAGE_FAMILIES = OrderedDict([
    ('libc', ('libc6', 'libc-bin')),
    ('systemd', ('systemd', 'systemd-sysv', 'libsystemd0')),
    ('udev', ('udev', 'libudev1')),
    ('dbus', ('dbus',)),
    ('initramfs', (
        'initramfs-tools', 'initramfs-tools-core', 'initramfs-tools-bin',
        'busybox-initramfs', 'klibc-utils',
    )),
    ('kernel', (
        'linux-generic', 'linux-image-generic',
        'linux-firmware',
    )),
    ('grub', ('grub-common', 'grub2-common', 'grub-pc', 'grub-pc-bin')),
    ('network', (
        'ifupdown', 'netplan.io', 'networkd-dispatcher',
        'isc-dhcp-client', 'openssh-server', 'openssh-client',
    )),
    ('apt_dpkg', ('apt', 'dpkg')),
    ('python', ('python3', 'python3-apt')),
    ('ubuntu_meta', ('ubuntu-minimal', 'ubuntu-standard', 'ubuntu-server')),
    ('init', ('init', 'init-system-helpers')),
])

CORE_PACKAGE_NAMES = []
for _names in CORE_PACKAGE_FAMILIES.values():
    CORE_PACKAGE_NAMES.extend(_names)

THIRD_PARTY_PATTERNS = (
    r'^aella', r'^stellar', r'^docker', r'^kube', r'^kubernetes',
    r'^containerd', r'^cri-o', r'^nvidia', r'^postgres', r'^kafka',
    r'^zookeeper', r'^elasticsearch', r'^redis', r'^mongo',
    r'^nodejs', r'^npm$', r'^yarn$', r'^java-', r'^openjdk',
    r'^salt', r'^puppet', r'^chef', r'^ansible',
)

XENIAL_VERSION_HINTS = OrderedDict([
    ('libc6', '2.23'),
    ('libc-bin', '2.23'),
    ('systemd', '229'),
    ('udev', '229'),
    ('libsystemd0', '229'),
    ('libudev1', '229'),
    ('apt', '1.2'),
    ('dpkg', '1.18'),
    ('python3', '3.5'),
])

BIONIC_VERSION_HINTS = OrderedDict([
    ('libc6', '2.27'),
    ('libc-bin', '2.27'),
    ('systemd', '237'),
    ('udev', '237'),
    ('libsystemd0', '237'),
    ('libudev1', '237'),
    ('apt', '1.6'),
    ('dpkg', '1.19'),
    ('python3', '3.6'),
])


def iso_now():
    return time.strftime('%Y-%m-%dT%H:%M:%S%z')


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
    """Deterministic JSON (sorted keys, stable separators)."""
    text = json.dumps(obj, indent=2, sort_keys=True, separators=(',', ': ')) + '\n'
    if path:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, 'w') as fh:
            fh.write(text)
    return text


def series_from_suite(suite):
    suite = suite or ''
    for suffix in ('-updates', '-security', '-backports', '-proposed'):
        if suite.endswith(suffix):
            return suite[:-len(suffix)]
    return suite


def pocket_from_suite(suite):
    suite = suite or ''
    for suffix in ('updates', 'security', 'backports', 'proposed'):
        if suite.endswith('-' + suffix):
            return suffix
    return 'base'


def parse_release_headers(text):
    headers = OrderedDict()
    for line in text.splitlines():
        if not line or line[0].isspace():
            break
        if ':' in line:
            key, val = line.split(':', 1)
            headers[key.strip()] = val.strip()
    return headers


def parse_release_checksums(text, algo='SHA256'):
    """Return {relative_path: (digest, size)} from a Release file section."""
    out = OrderedDict()
    in_section = False
    for line in text.splitlines():
        if line.startswith(algo + ':'):
            in_section = True
            continue
        if in_section:
            if not line or (line[0] and not line[0].isspace()):
                if line and not line[0].isspace():
                    in_section = False
                if not in_section and line.startswith(algo):
                    in_section = True
                continue
            parts = line.split()
            if len(parts) >= 3:
                digest, size_s, rel = parts[0], parts[1], parts[2]
                try:
                    size = int(size_s)
                except ValueError:
                    continue
                out[rel] = (digest, size)
    return out


def open_packages_text(path):
    if path.endswith('.gz'):
        with gzip.open(path, 'rb') as fh:
            return fh.read().decode('utf-8', 'replace')
    with open(path, 'rb') as fh:
        return fh.read().decode('utf-8', 'replace')


def parse_packages_index(text):
    """Yield OrderedDict stanzas from a Packages index body."""
    cur = OrderedDict()
    for line in text.splitlines():
        if not line.strip():
            if cur:
                yield cur
                cur = OrderedDict()
            continue
        if line.startswith(' ') or line.startswith('\t'):
            continue
        if ':' in line:
            key, val = line.split(':', 1)
            cur[key.strip()] = val.strip()
    if cur:
        yield cur


def parse_dep_field(field):
    """Return list of dependency name alternatives groups.

    Each group is a list of (name, version_constraint_or_None, arch_qual_or_None).
    """
    if not field:
        return []
    groups = []
    for alt_group in field.split(','):
        alts = []
        for alt in alt_group.split('|'):
            tok = alt.strip()
            if not tok:
                continue
            arch = None
            if ':any' in tok:
                tok = tok.replace(':any', '')
                arch = 'any'
            m = re.match(
                r'^([a-zA-Z0-9.+\-]+)(?:\s*\(([^)]+)\))?',
                tok,
            )
            if not m:
                continue
            alts.append((m.group(1), m.group(2), arch))
        if alts:
            groups.append(alts)
    return groups


def dep_names(field):
    names = []
    for group in parse_dep_field(field):
        if group:
            names.append(group[0][0])
    return names


def read_text(path):
    with open(path, 'rb') as fh:
        return fh.read().decode('utf-8', 'replace')


# ---------------------------------------------------------------------------
# DistUpgrade SourceEntry signed-by semantics (from bionic upgrader tarball)
# ---------------------------------------------------------------------------

def distupgrade_source_entry_valid(line):
    """Replicate DistUpgrade bundled sourceslist.SourceEntry option rules.

    Only arch= and trusted= options are accepted. signed-by= → invalid=True.
    Returns OrderedDict with parse result; does not import system aptsources.
    """
    result = OrderedDict([
        ('line', line.rstrip('\n')),
        ('invalid', False),
        ('disabled', False),
        ('type', ''),
        ('architectures', []),
        ('uri', ''),
        ('dist', ''),
        ('comps', []),
        ('rejected_options', []),
    ])
    raw = line.strip()
    if not raw or raw == '#':
        result['invalid'] = True
        return result
    if raw[0] == '#':
        result['disabled'] = True
        pieces = raw[1:].strip().split()
        if not pieces or pieces[0] not in ('rpm', 'rpm-src', 'deb', 'deb-src'):
            result['invalid'] = True
            return result
        raw = raw[1:]
    comment_i = raw.find('#')
    if comment_i > 0:
        raw = raw[:comment_i]
    # mysplit-equivalent for [options]
    pieces = []
    tmp = ''
    p_found = False
    space_found = False
    for ch in raw.strip():
        if ch == '[':
            if space_found:
                space_found = False
                p_found = True
                pieces.append(tmp)
                tmp = ch
            else:
                p_found = True
                tmp += ch
        elif ch == ']':
            p_found = False
            tmp += ch
        elif space_found and not ch.isspace():
            space_found = False
            pieces.append(tmp)
            tmp = ch
        elif ch.isspace() and not p_found:
            space_found = True
        else:
            tmp += ch
    if tmp:
        pieces.append(tmp)
    if len(pieces) < 3:
        result['invalid'] = True
        return result
    result['type'] = pieces[0].strip()
    if result['type'] not in ('deb', 'deb-src', 'rpm', 'rpm-src'):
        result['invalid'] = True
        return result
    idx = 1
    if pieces[1].strip().startswith('['):
        options = pieces[1].strip()[1:-1].split()
        idx = 2
        for option in options:
            if '=' not in option:
                result['invalid'] = True
                result['rejected_options'].append(option)
                continue
            key, value = option.split('=', 1)
            if key == 'arch':
                result['architectures'] = value.split(',')
            elif key == 'trusted':
                pass
            else:
                result['invalid'] = True
                result['rejected_options'].append(key)
    if idx >= len(pieces):
        result['invalid'] = True
        return result
    result['uri'] = pieces[idx].strip()
    if idx + 1 >= len(pieces):
        result['invalid'] = True
        return result
    result['dist'] = pieces[idx + 1].strip()
    result['comps'] = [p.strip() for p in pieces[idx + 2:]]
    return result


def analyze_client_sources_lines(lines, components_expected=None):
    """Analyze generated sources.list lines against DistUpgrade parser rules."""
    components_expected = list(components_expected or ['main', 'universe'])
    entries = []
    valid_count = 0
    invalid_signed_by = 0
    found = OrderedDict()
    for line in lines:
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        if not s.startswith('deb'):
            continue
        parsed = distupgrade_source_entry_valid(s)
        entries.append(parsed)
        if parsed['invalid']:
            if 'signed-by' in parsed['rejected_options']:
                invalid_signed_by += 1
            continue
        valid_count += 1
        d = parsed['dist']
        found.setdefault(d, set())
        for c in parsed['comps']:
            found[d].add(c)
    # Normalize found to sorted lists for JSON
    found_json = OrderedDict(
        (k, sorted(v)) for k, v in sorted(found.items())
    )
    return OrderedDict([
        ('entry_count', len(entries)),
        ('valid_entry_count', valid_count),
        ('invalid_entry_count', len(entries) - valid_count),
        ('invalid_due_to_signed_by', invalid_signed_by),
        ('found_components_after_distupgrade_parse', found_json),
        ('expected_components', components_expected),
        ('verdict', (
            'FAIL_SIGNED_BY_INVALIDATES_ALL_ENTRIES'
            if invalid_signed_by and valid_count == 0 else
            'FAIL_SIGNED_BY_PARTIAL'
            if invalid_signed_by else
            'OK'
        )),
        ('entries', entries),
    ])


# ---------------------------------------------------------------------------
# Repository audit
# ---------------------------------------------------------------------------

def audit_suite_component(ubuntu_root, suite, component, arch='amd64',
                          from_series='', to_series=''):
    """Build one suite/component audit row."""
    dists = os.path.join(ubuntu_root, 'dists', suite)
    release_path = os.path.join(dists, 'Release')
    binary = os.path.join(dists, component, 'binary-%s' % arch)
    packages_path = os.path.join(binary, 'Packages')
    packages_gz = packages_path + '.gz'

    row = OrderedDict([
        ('suite', suite),
        ('component', component),
        ('series', series_from_suite(suite)),
        ('pocket', pocket_from_suite(suite)),
        ('role', ''),
        ('release_exists', os.path.isfile(release_path)),
        ('release_component_declared', False),
        ('packages_index_exists', False),
        ('packages_uncompressed_size', 0),
        ('packages_gz_size', 0),
        ('package_stanza_count', 0),
        ('unique_package_count', 0),
        ('unique_version_count', 0),
        ('referenced_deb_count', 0),
        ('existing_deb_count', 0),
        ('missing_deb_count', 0),
        ('checksum_mismatch_count', 0),
        ('semantic_result', ''),
        ('errors', []),
        ('missing_debs_sample', []),
    ])

    series = row['series']
    if from_series and series == from_series:
        row['role'] = 'source-stabilization'
    elif to_series and series == to_series:
        row['role'] = 'target-upgrade'
    else:
        row['role'] = 'unknown'

    release_text = ''
    checksums = OrderedDict()
    if row['release_exists']:
        release_text = read_text(release_path)
        headers = parse_release_headers(release_text)
        comps = headers.get('Components', '').split()
        row['release_component_declared'] = component in comps
        checksums = parse_release_checksums(release_text, 'SHA256')
        if not row['release_component_declared'] and row['role'] == 'target-upgrade':
            row['errors'].append(ERROR_TARGET_COMPONENT_NOT_DECLARED)
    else:
        if row['role'] == 'target-upgrade':
            row['errors'].append(ERROR_TARGET_SUITE_NOT_DECLARED)

    pkg_text = ''
    if os.path.isfile(packages_path):
        row['packages_index_exists'] = True
        row['packages_uncompressed_size'] = os.path.getsize(packages_path)
        pkg_text = read_text(packages_path)
    elif os.path.isfile(packages_gz):
        row['packages_index_exists'] = True
        row['packages_gz_size'] = os.path.getsize(packages_gz)
        pkg_text = open_packages_text(packages_gz)
        # synthesize size of uncompressed for reporting
        row['packages_uncompressed_size'] = len(pkg_text.encode('utf-8'))
    if os.path.isfile(packages_gz):
        row['packages_gz_size'] = os.path.getsize(packages_gz)

    if not row['packages_index_exists']:
        if row['role'] == 'target-upgrade':
            row['errors'].append(ERROR_TARGET_PACKAGES_INDEX_MISSING)
            row['semantic_result'] = SEMANTIC_FAIL_MISSING
        else:
            row['semantic_result'] = SEMANTIC_OK_EMPTY_SOURCE
        return row

    # Release checksum validation for Packages / Packages.gz
    for rel_name, local_path in (
        ('%s/binary-%s/Packages' % (component, arch), packages_path),
        ('%s/binary-%s/Packages.gz' % (component, arch), packages_gz),
    ):
        if rel_name in checksums and os.path.isfile(local_path):
            expect_digest, expect_size = checksums[rel_name]
            actual_size = os.path.getsize(local_path)
            actual_digest = sha256_file(local_path)
            if actual_size != expect_size or actual_digest != expect_digest:
                row['checksum_mismatch_count'] += 1
                row['errors'].append(ERROR_RELEASE_PACKAGES_CHECKSUM_MISMATCH)

    names = []
    versions = []
    missing = []
    existing = 0
    referenced = 0
    for stanza in parse_packages_index(pkg_text):
        names.append(stanza.get('Package', ''))
        versions.append('%s=%s' % (stanza.get('Package', ''), stanza.get('Version', '')))
        fn = stanza.get('Filename')
        if not fn:
            continue
        referenced += 1
        deb_path = os.path.join(ubuntu_root, fn)
        if os.path.isfile(deb_path):
            existing += 1
            try:
                expect_size = int(stanza.get('Size') or '0')
            except ValueError:
                expect_size = 0
            if expect_size and os.path.getsize(deb_path) != expect_size:
                missing.append('SIZE_MISMATCH:' + fn)
        else:
            missing.append(fn)

    row['package_stanza_count'] = len(names)
    row['unique_package_count'] = len(set(names))
    row['unique_version_count'] = len(set(versions))
    row['referenced_deb_count'] = referenced
    row['existing_deb_count'] = existing
    row['missing_deb_count'] = len(missing)
    row['missing_debs_sample'] = missing[:20]
    if missing:
        row['errors'].append(ERROR_PACKAGES_REFERENCED_DEB_MISSING)

    if row['package_stanza_count'] == 0:
        if row['role'] == 'target-upgrade':
            row['errors'].append(ERROR_TARGET_PACKAGES_INDEX_EMPTY)
            row['semantic_result'] = SEMANTIC_FAIL_EMPTY_TARGET
        else:
            row['semantic_result'] = SEMANTIC_OK_EMPTY_SOURCE
    elif row['checksum_mismatch_count']:
        row['semantic_result'] = SEMANTIC_FAIL_CHECKSUM
    elif row['missing_deb_count']:
        row['semantic_result'] = SEMANTIC_FAIL_DEB
    else:
        row['semantic_result'] = SEMANTIC_OK
    return row


def audit_repository(ubuntu_root, suites, components, arch='amd64',
                     from_series='xenial', to_series='bionic'):
    rows = []
    for suite in suites:
        for component in components:
            rows.append(audit_suite_component(
                ubuntu_root, suite, component, arch=arch,
                from_series=from_series, to_series=to_series,
            ))
    # Detect identical Packages across target suites
    target_hashes = OrderedDict()
    for suite in suites:
        if series_from_suite(suite) != to_series:
            continue
        path = os.path.join(
            ubuntu_root, 'dists', suite, 'main', 'binary-%s' % arch, 'Packages',
        )
        if os.path.isfile(path):
            target_hashes[suite] = sha256_file(path)
    identical_target_indexes = (
        len(set(target_hashes.values())) == 1 and len(target_hashes) > 1
    )
    return OrderedDict([
        ('ubuntu_root', ubuntu_root),
        ('from_series', from_series),
        ('to_series', to_series),
        ('suites', list(suites)),
        ('components', list(components)),
        ('rows', rows),
        ('target_main_packages_sha256', target_hashes),
        ('target_suite_indexes_identical', identical_target_indexes),
        ('fail_empty_target_index', [
            r for r in rows if r['semantic_result'] == SEMANTIC_FAIL_EMPTY_TARGET
        ]),
        ('generated_at', iso_now()),
    ])


# ---------------------------------------------------------------------------
# Package index helpers / core family / dependency closure
# ---------------------------------------------------------------------------

def load_suite_packages(ubuntu_root, suites, components, arch='amd64'):
    """Return {name: best_stanza} preferring later suites in list order."""
    by_name = OrderedDict()
    provenance = OrderedDict()
    for suite in suites:
        for component in components:
            path = os.path.join(
                ubuntu_root, 'dists', suite, component,
                'binary-%s' % arch, 'Packages',
            )
            if not os.path.isfile(path):
                gz = path + '.gz'
                if not os.path.isfile(gz):
                    continue
                text = open_packages_text(gz)
            else:
                text = read_text(path)
            for stanza in parse_packages_index(text):
                name = stanza.get('Package')
                if not name:
                    continue
                stanza = OrderedDict(stanza)
                stanza['_suite'] = suite
                stanza['_component'] = component
                # later suite wins (caller should order updates/security last
                # if pocket-distinct; for identical clones order is irrelevant)
                by_name[name] = stanza
                provenance.setdefault(name, [])
                provenance[name].append('%s/%s' % (suite, component))
    return by_name, provenance


def follow_dependency_closure(packages, roots, fields=None):
    """Name-based dependency closure (first alternative only)."""
    fields = fields or ('Pre-Depends', 'Depends', 'Recommends')
    seen = set()
    missing = []
    queue = list(roots)
    edges = []
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.add(name)
        info = packages.get(name)
        if not info:
            missing.append(name)
            continue
        for field in fields:
            for dep in dep_names(info.get(field)):
                edges.append(OrderedDict([
                    ('from', name), ('field', field), ('to', dep),
                ]))
                if dep not in seen:
                    queue.append(dep)
    return OrderedDict([
        ('roots', list(roots)),
        ('fields', list(fields)),
        ('visited_count', len(seen)),
        ('visited', sorted(seen)),
        ('missing_from_index', sorted(set(missing))),
        ('edge_count', len(edges)),
        ('edges_sample', edges[:50]),
    ])


def analyze_core_packages(packages, ubuntu_root):
    rows = []
    for family, names in CORE_PACKAGE_FAMILIES.items():
        for name in names:
            info = packages.get(name)
            row = OrderedDict([
                ('family', family),
                ('package', name),
                ('present_in_index', info is not None),
                ('version', info.get('Version') if info else ''),
                ('suite', info.get('_suite') if info else ''),
                ('component', info.get('_component') if info else ''),
                ('filename', info.get('Filename') if info else ''),
                ('deb_present', False),
                ('looks_xenial', False),
                ('looks_bionic', False),
                ('severity', 'OK'),
            ])
            if info and info.get('Filename'):
                deb = os.path.join(ubuntu_root, info['Filename'])
                row['deb_present'] = os.path.isfile(deb)
            ver = row['version'] or ''
            xhint = XENIAL_VERSION_HINTS.get(name)
            bhint = BIONIC_VERSION_HINTS.get(name)
            if xhint and ver.startswith(xhint):
                row['looks_xenial'] = True
            if bhint and ver.startswith(bhint):
                row['looks_bionic'] = True
            if not info:
                row['severity'] = 'MISSING_FROM_INDEX'
            elif not row['deb_present']:
                row['severity'] = 'DEB_ABSENT'
            elif row['looks_xenial'] and name in BIONIC_VERSION_HINTS:
                row['severity'] = 'UNEXPECTED_XENIAL_VERSION_IN_TARGET'
            rows.append(row)
    # family consistency: systemd/udev major versions
    def ver_of(n):
        info = packages.get(n) or {}
        return info.get('Version') or ''

    fam_issues = []
    if ver_of('systemd') and ver_of('libsystemd0'):
        if ver_of('systemd').split('-')[0] != ver_of('libsystemd0').split('-')[0]:
            fam_issues.append('systemd_libsystemd0_version_family_mismatch')
    if ver_of('udev') and ver_of('libudev1'):
        if ver_of('udev').split('-')[0] != ver_of('libudev1').split('-')[0]:
            fam_issues.append('udev_libudev1_version_family_mismatch')

    # kernel family completeness from concrete image packages in index
    kernel_images = sorted(
        n for n in packages
        if n.startswith('linux-image-') and n[len('linux-image-'):][:1].isdigit()
    )
    kernel_rows = []
    for img in kernel_images:
        # linux-image-4.15.0-213-generic → 4.15.0-213-generic
        ver_abi = img[len('linux-image-'):]
        mods = 'linux-modules-' + ver_abi
        extra = 'linux-modules-extra-' + ver_abi
        kernel_rows.append(OrderedDict([
            ('image', img),
            ('image_version', (packages.get(img) or {}).get('Version', '')),
            ('modules', mods),
            ('modules_present', mods in packages),
            ('modules_extra', extra),
            ('modules_extra_present', extra in packages),
            ('severity', (
                'OK' if mods in packages else 'INCOMPLETE_KERNEL_FAMILY_MISSING_MODULES'
            )),
        ]))

    return OrderedDict([
        ('packages', rows),
        ('family_issues', fam_issues),
        ('kernel_families', kernel_rows),
        ('grub_pc_present', 'grub-pc' in packages),
        ('grub_pc_bin_present', 'grub-pc-bin' in packages),
    ])


# ---------------------------------------------------------------------------
# Keep-at-same-version classification
# ---------------------------------------------------------------------------

def parse_keep_at_same_version(main_log_text):
    """Parse DistUpgrade main.log Keep at same version list."""
    keeps = []
    for line in main_log_text.splitlines():
        if 'Keep at same version:' not in line:
            continue
        _, _, rest = line.partition('Keep at same version:')
        for tok in rest.strip().split():
            if tok:
                keeps.append(tok)
    return keeps


def parse_found_components(main_log_text):
    for line in main_log_text.splitlines():
        if 'found components:' not in line:
            continue
        _, _, rest = line.partition('found components:')
        rest = rest.strip()
        try:
            # main.log uses Python repr of dict with sets
            # e.g. {'bionic-updates': set(), 'bionic': {'main'}}
            return _parse_found_components_repr(rest)
        except Exception:
            return OrderedDict([('raw', rest), ('parse_error', True)])
    return OrderedDict()


def _parse_found_components_repr(text):
    """Parse DistUpgrade found_components repr into sorted-list values."""
    # Replace empty set() so literal_eval can handle the structure after
    # converting set displays. We evaluate via a tiny restricted transform:
    # set() → [] and {...} set-literals remain invalid for literal_eval when
    # mixed; use ast + Constant-only walk.
    import ast

    class _V(ast.NodeVisitor):
        def visit(self, node):
            if isinstance(node, ast.Dict):
                out = OrderedDict()
                for k, v in zip(node.keys, node.values):
                    out[self.visit(k)] = self.visit(v)
                return out
            if isinstance(node, ast.Set):
                return sorted(self.visit(elt) for elt in node.elts)
            if isinstance(node, ast.List):
                return [self.visit(elt) for elt in node.elts]
            if isinstance(node, ast.Tuple):
                return [self.visit(elt) for elt in node.elts]
            if isinstance(node, ast.Call):
                if isinstance(node.func, ast.Name) and node.func.id == 'set':
                    if not node.args:
                        return []
                    return self.visit(node.args[0])
            if isinstance(node, ast.Constant):
                val = node.value
                if isinstance(val, bytes):
                    return val.decode('utf-8', 'replace')
                return val
            raise ValueError('unsupported node %s' % type(node).__name__)

    return _V().visit(ast.parse(text, mode='eval').body)


def is_third_party_name(name):
    for pat in THIRD_PARTY_PATTERNS:
        if re.search(pat, name, re.I):
            return True
    return False


def classify_keep_package(name, packages_index, installed_versions=None,
                          holds=None, pinned=None):
    """Classify one Keep-at-same-version package.

    Categories A–J per investigation brief.
    """
    installed_versions = installed_versions or {}
    holds = set(holds or [])
    pinned = set(pinned or [])
    info = packages_index.get(name)
    installed = installed_versions.get(name, '')
    candidate = info.get('Version') if info else ''
    row = OrderedDict([
        ('package', name),
        ('installed_version', installed),
        ('candidate_version', candidate),
        ('candidate_suite', info.get('_suite') if info else ''),
        ('candidate_component', info.get('_component') if info else ''),
        ('mirror_deb_present', False),
        ('classification', 'J'),
        ('classification_label', 'unexplained'),
        ('severity', 'INFO'),
        ('keep_reason', ''),
        ('evidence', []),
    ])
    if info and info.get('Filename'):
        # deb presence checked by caller optionally via ubuntu_root; here flag
        # presence in index only. Caller may enrich.
        row['mirror_index_present'] = True
    else:
        row['mirror_index_present'] = False

    if name in holds or name in pinned:
        row['classification'] = 'E'
        row['classification_label'] = 'package_held_or_pinned'
        row['keep_reason'] = 'held_or_pinned'
        row['evidence'].append('hold_or_pin')
        return row

    if is_third_party_name(name):
        row['classification'] = 'A'
        row['classification_label'] = 'third_party_or_product'
        row['keep_reason'] = 'third_party_expected'
        row['severity'] = 'EXPECTED'
        return row

    if not info:
        row['classification'] = 'B'
        row['classification_label'] = 'not_available_in_bionic_index'
        row['keep_reason'] = 'no_bionic_candidate_in_selective_index'
        if name in CORE_PACKAGE_NAMES:
            row['severity'] = 'CRITICAL'
            row['classification'] = 'H'
            row['classification_label'] = 'selective_mirror_payload_missing_core'
        else:
            row['severity'] = 'WARN'
        return row

    if not candidate:
        row['classification'] = 'C'
        row['classification_label'] = 'available_but_no_candidate'
        row['keep_reason'] = 'empty_candidate'
        row['severity'] = 'WARN'
        return row

    # Candidate exists — kept due to resolver / conflict / expected
    if name in CORE_PACKAGE_NAMES:
        xhint = XENIAL_VERSION_HINTS.get(name)
        if xhint and installed.startswith(xhint) and candidate.startswith(
                BIONIC_VERSION_HINTS.get(name, 'NOPE')):
            row['classification'] = 'H'
            row['classification_label'] = 'UNEXPECTED_CORE_PACKAGE_KEEP'
            row['keep_reason'] = 'core_package_kept_despite_bionic_candidate'
            row['severity'] = 'CRITICAL'
            row['evidence'].append(
                'installed_looks_xenial_candidate_looks_bionic'
            )
            return row
        row['classification'] = 'D'
        row['classification_label'] = 'core_keep_dependency_or_conflict'
        row['keep_reason'] = 'dependency_resolution_or_conflict'
        row['severity'] = 'HIGH'
        return row

    # transitional / obsolete heuristics
    if 'transitional' in (info.get('Description') or '').lower():
        row['classification'] = 'F'
        row['classification_label'] = 'obsolete_or_transitional'
        row['keep_reason'] = 'transitional'
        row['severity'] = 'EXPECTED'
        return row

    row['classification'] = 'I'
    row['classification_label'] = 'normal_expected_keep'
    row['keep_reason'] = 'candidate_exists_non_core_keep'
    row['severity'] = 'INFO'
    return row


def classify_keep_list(names, packages_index, installed_versions=None,
                       holds=None, pinned=None, ubuntu_root=None):
    rows = []
    for name in names:
        row = classify_keep_package(
            name, packages_index, installed_versions=installed_versions,
            holds=holds, pinned=pinned,
        )
        if ubuntu_root and row.get('mirror_index_present'):
            info = packages_index.get(name) or {}
            fn = info.get('Filename')
            if fn:
                row['mirror_deb_present'] = os.path.isfile(
                    os.path.join(ubuntu_root, fn)
                )
                if not row['mirror_deb_present'] and row['severity'] != 'CRITICAL':
                    row['classification'] = 'H'
                    row['classification_label'] = 'selective_mirror_payload_missing'
                    row['severity'] = 'HIGH'
                    row['keep_reason'] = 'index_lists_deb_but_file_absent'
        rows.append(row)
    summary = Counter(r['classification'] for r in rows)
    critical = [r for r in rows if r['severity'] == 'CRITICAL']
    return OrderedDict([
        ('total', len(rows)),
        ('by_classification', OrderedDict(sorted(summary.items()))),
        ('critical_keeps', critical),
        ('packages', rows),
    ])


# ---------------------------------------------------------------------------
# Simulation (mirror-only candidate resolution; no network download)
# ---------------------------------------------------------------------------

def simulate_mirror_candidates(installed_manifest, packages_index):
    """Compare installed versions vs mirror candidates.

    installed_manifest: {package: version}
    """
    upgrade = []
    keep = []
    missing = []
    unexpected_core_keep = []
    for name, installed in sorted(installed_manifest.items()):
        info = packages_index.get(name)
        if not info:
            missing.append(name)
            keep.append(OrderedDict([
                ('package', name),
                ('installed', installed),
                ('action', 'keep'),
                ('reason', 'no_candidate_in_mirror'),
            ]))
            if name in CORE_PACKAGE_NAMES:
                unexpected_core_keep.append(name)
            continue
        candidate = info.get('Version') or ''
        if candidate and candidate != installed:
            upgrade.append(OrderedDict([
                ('package', name),
                ('installed', installed),
                ('candidate', candidate),
                ('suite', info.get('_suite')),
                ('action', 'upgrade'),
            ]))
        else:
            keep.append(OrderedDict([
                ('package', name),
                ('installed', installed),
                ('candidate', candidate),
                ('action', 'keep'),
                ('reason', 'same_version_or_empty'),
            ]))
            if name in CORE_PACKAGE_NAMES:
                xhint = XENIAL_VERSION_HINTS.get(name)
                bhint = BIONIC_VERSION_HINTS.get(name)
                if xhint and installed.startswith(xhint) and (
                        not candidate or not candidate.startswith(bhint or '')
                ):
                    unexpected_core_keep.append(name)
    return OrderedDict([
        ('upgrade_count', len(upgrade)),
        ('keep_count', len(keep)),
        ('missing_candidate_count', len(missing)),
        ('unexpected_kept_core_packages', sorted(set(unexpected_core_keep))),
        ('upgrades_sample', upgrade[:100]),
        ('keeps_sample', keep[:100]),
        ('missing_sample', missing[:100]),
    ])


# ---------------------------------------------------------------------------
# Evidence comparison
# ---------------------------------------------------------------------------

def compare_evidence_bundles(internet_dir, mirror_dir):
    """Compare two baseline evidence directories (extracted collector output)."""
    def load_pkg_versions(root):
        path = os.path.join(root, 'dpkg-query.tsv')
        out = OrderedDict()
        if not os.path.isfile(path):
            return out
        with open(path, 'r') as fh:
            for line in fh:
                if line.startswith('package\t') or not line.strip():
                    continue
                parts = line.rstrip('\n').split('\t')
                if len(parts) >= 2:
                    out[parts[0]] = parts[1]
        return out

    def load_lines(root, rel):
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            return []
        with open(path, 'r') as fh:
            return [ln.rstrip('\n') for ln in fh]

    i_pkgs = load_pkg_versions(internet_dir)
    m_pkgs = load_pkg_versions(mirror_dir)
    only_internet = sorted(set(i_pkgs) - set(m_pkgs))
    only_mirror = sorted(set(m_pkgs) - set(i_pkgs))
    version_mismatch = []
    core_mismatch = []
    for name in sorted(set(i_pkgs) & set(m_pkgs)):
        if i_pkgs[name] != m_pkgs[name]:
            rec = OrderedDict([
                ('package', name),
                ('internet', i_pkgs[name]),
                ('mirror', m_pkgs[name]),
            ])
            version_mismatch.append(rec)
            if name in CORE_PACKAGE_NAMES or name.startswith('linux-'):
                core_mismatch.append(rec)

    return OrderedDict([
        ('package_only_in_internet', only_internet),
        ('package_only_in_mirror', only_mirror),
        ('version_mismatch_count', len(version_mismatch)),
        ('version_mismatch_sample', version_mismatch[:200]),
        ('core_package_mismatch', core_mismatch),
        ('kernel_mismatch', [
            r for r in version_mismatch
            if r['package'].startswith('linux-')
        ]),
        ('initramfs_list_internet', load_lines(internet_dir, 'initramfs-list.txt')),
        ('initramfs_list_mirror', load_lines(mirror_dir, 'initramfs-list.txt')),
        ('boot_listing_internet', load_lines(internet_dir, 'boot-listing.txt')),
        ('boot_listing_mirror', load_lines(mirror_dir, 'boot-listing.txt')),
        ('grub_cfg_internet', load_lines(internet_dir, 'grub-cfg-kernels.txt')),
        ('grub_cfg_mirror', load_lines(mirror_dir, 'grub-cfg-kernels.txt')),
        ('generated_at', iso_now()),
    ])


# ---------------------------------------------------------------------------
# Reboot gate proposal (design only)
# ---------------------------------------------------------------------------

def propose_reboot_gates():
    return OrderedDict([
        ('policy_name', 'pre_reboot_core_package_consistency_gate'),
        ('block_reboot_when', [
            'core package retained at Xenial version despite Bionic candidate',
            'core package candidate missing from selective mirror index',
            'dpkg status shows unpacked/half-configured for core packages',
            'apt-get check reports broken dependencies',
            'kernel image installed without matching modules package',
            'kernel image/modules installed but initrd.img for that ABI missing',
            'update-grub lists new vmlinuz without matching initrd',
            'systemd/udev/libsystemd0/libudev1 version family inconsistent',
            'required .deb referenced by Packages absent from pool',
            'DistUpgrade sources.list entries invalidated by signed-by option',
        ]),
        ('required_checks', OrderedDict([
            ('libc_family', ['libc6', 'libc-bin']),
            ('systemd_family', ['systemd', 'systemd-sysv', 'libsystemd0']),
            ('udev_family', ['udev', 'libudev1']),
            ('dbus', ['dbus']),
            ('initramfs_family', list(CORE_PACKAGE_FAMILIES['initramfs'])),
            ('kernel_family', [
                'linux-image-* matching modules/modules-extra',
                'initrd.img-$ABI present and non-empty',
                'grub.cfg references initrd for default entry',
            ]),
            ('ubuntu_meta', ['ubuntu-minimal', 'ubuntu-server']),
            ('apt_dpkg', ['apt', 'dpkg']),
            ('network_stack', list(CORE_PACKAGE_FAMILIES['network'])),
            ('openssh', ['openssh-server']),
        ])),
        ('note', (
            'Design only — do not apply to upgrade client until root cause is '
            'confirmed with internet vs mirror baseline evidence bundles.'
        )),
    ])


# ---------------------------------------------------------------------------
# Hypotheses
# ---------------------------------------------------------------------------

def evaluate_hypotheses(repo_audit, sources_analysis, core_analysis,
                        keep_analysis, plan_suite_summary, extras=None):
    extras = extras or {}
    empty_targets = repo_audit.get('fail_empty_target_index') or []
    identical = repo_audit.get('target_suite_indexes_identical')
    signed_by_verdict = (sources_analysis or {}).get('verdict')
    grub_pc = (core_analysis or {}).get('grub_pc_present')
    critical_keeps = (keep_analysis or {}).get('critical_keeps') or []
    kernel_issues = [
        k for k in (core_analysis or {}).get('kernel_families') or []
        if k.get('severity') != 'OK'
    ]

    def H(hid, title, supporting, contradicting, verdict, additional):
        return OrderedDict([
            ('id', hid),
            ('title', title),
            ('supporting_evidence', supporting),
            ('contradicting_evidence', contradicting),
            ('current_verdict', verdict),
            ('additional_evidence_required', additional),
        ])

    hypotheses = []
    hypotheses.append(H(
        'H1',
        'bionic-updates/security Packages empty → only base bionic installed',
        [
            'User main.log found_components shows empty sets for '
            'bionic-updates and bionic-security',
            'DistUpgrade SourceEntry marks signed-by= invalid, so pocket '
            'rewrite may not register updates/security components',
            'Failed run installed linux-image-4.15.0-20-generic (GA), not '
            'discovery/current-mirror 4.15.0-213',
        ],
        [
            'Current published selective mirror has non-empty Packages for '
            'bionic-updates/security (identical clones of bionic base, '
            'sha256 match=%s)' % identical,
            'empty Packages is NOT observed on live published tree today',
        ],
        'PARTIALLY_SUPPORTED — empty component *registration* in DistUpgrade '
        'is supported; empty Packages index on current publish is NOT observed',
        [
            'Preserve pre-reboot sources.list and main.log from a failing DP',
            'Confirm whether failing runs used an older publish with empty '
            'pocket indexes',
        ],
    ))
    hypotheses.append(H(
        'H2',
        'Discovery collected only initial Xenial-visible deps; upgrader '
        'transaction deps missing',
        [
            'selection_mode=discovery_exact; plan does not recompute full '
            'Bionic task/meta closure beyond observed HTTP GETs',
            'grub-pc absent from selective index while grub-pc-bin present',
            'All xenial-to-bionic packages tagged original_suite=bionic base '
            '(pocket provenance lost): %s' % plan_suite_summary,
        ],
        [
            'Core boot packages (systemd/udev/initramfs/linux 4.15.0-213) are '
            'present in current index',
            'initramfs-tools dependency closure missing_from_index empty on '
            'current publish',
        ],
        'SUPPORTED for pocket/provenance and some boot-adjacent packages '
        '(grub-pc); NOT sole explanation for boot hang',
        ['Internet baseline package set vs discovery required-packages.tsv'],
    ))
    hypotheses.append(H(
        'H3',
        'Core packages kept at Xenial → mixed userland',
        [
            'User reports many Keep at same version entries including '
            'kernel/network/system packages',
            'Critical keep classifier fires when core pkgs kept with Bionic '
            'candidates present (count=%d)' % len(critical_keeps),
        ],
        [
            'Current mirror index contains Bionic versions of libc6/systemd/'
            'udev; keep must be proven from actual failing main.log list',
        ],
        'PLAUSIBLE — requires full Keep list from failing DP main.log',
        ['Parse complete Keep at same version + dpkg -l from failing DP'],
    ))
    hypotheses.append(H(
        'H4',
        'Kernel image installed but modules/initramfs incomplete',
        [
            'Prior failure evidence: vmlinuz-4.15.0-20 present; update-grub '
            'found only initrd.img-4.4.0-210-generic, not 4.15.0-20',
            'Boot console stops after random: crng init done '
            '(consistent with rootfs mount failure without initrd modules)',
            'kernel family gaps in analysis: %d' % len(kernel_issues),
        ],
        [
            'Current mirror includes modules + modules-extra for 4.15.0-213',
            '4.15.0-20 is absent from current selective pool entirely',
        ],
        'STRONGLY_SUPPORTED for the observed failing boot symptom; package '
        'version (20 vs 213) indicates failing run ≠ current publish payload',
        [
            'ls -l /boot and lsinitramfs on failing DP (read-only)',
            'Internet baseline /boot listing',
        ],
    ))
    hypotheses.append(H(
        'H5',
        'network/systemd/udev/dbus version family mix',
        [
            'family_issues=%s' % ((core_analysis or {}).get('family_issues')),
        ],
        [
            'Current index has matching 237-3ubuntu10.57 for systemd/udev '
            'family',
        ],
        'INCONCLUSIVE on current mirror; needs post-upgrade dpkg manifest '
        'from failing DP',
        ['dpkg -l systemd udev libudev1 libsystemd0 dbus from both VMs'],
    ))
    hypotheses.append(H(
        'H6',
        'universe in plan but Release/Packages only expose main',
        [
            'found_components user log shows only main for bionic',
            'Client PIN_COMPONENTS includes universe but DistUpgrade '
            'signed-by invalidation can drop component registration',
        ],
        [
            'Current Release declares Components: main universe and universe '
            'Packages has stanzas',
        ],
        'PARTIALLY_SUPPORTED for DistUpgrade component registration; NOT '
        'supported for current Release metadata omission',
        ['Post-rewrite sources.list from failing DP'],
    ))
    hypotheses.append(H(
        'H7',
        'do-release-upgrade mis-read components due to Release/meta-release/'
        'sources generation errors',
        [
            'DistUpgrade bundled sourceslist.py: unknown options (signed-by) '
            'set invalid=True — client apply_local_sources uses signed-by',
            'Offline mirror URI not in upgrader mirrors.cfg ValidMirrors',
            'Client does not set RELEASE_UPGRADER_ALLOW_THIRD_PARTY',
            'sources_analysis verdict=%s' % signed_by_verdict,
            'NonInteractive frontend auto-answers Yes to generate default '
            'archive.ubuntu.com sources (main,restricted) when rewrite fails',
        ],
        [],
        'SUPPORTED — strongest repository/transaction structural root-cause '
        'candidate for empty found_components and divergent package sets',
        [
            'Failing DP /var/log/dist-upgrade/main.log around '
            'updateSourcesList / No valid mirror / Generated new default',
            'Failing DP /etc/apt/sources.list after upgrade attempt',
        ],
    ))
    hypotheses.append(H(
        'H8',
        'Mirror dependency-complete but version set differs from internet',
        [
            'Discovery-exact payload ≠ full Ubuntu pocket contents',
            'identical target suite indexes collapse pocket diversity',
            'Failed kernel 4.15.0-20 vs mirror/discovery 4.15.0-213',
            'grub-pc present=%s' % grub_pc,
        ],
        [
            'Many core packages are present at current Bionic SRU versions',
        ],
        'SUPPORTED as contributing structural difference; may combine with H7',
        ['Internet vs mirror evidence bundle comparison'],
    ))
    return hypotheses


def build_full_report(
        ubuntu_root,
        suites,
        components,
        from_series='xenial',
        to_series='bionic',
        client_sources_lines=None,
        main_log_text=None,
        plan_packages_tsv=None,
        installed_manifest=None,
):
    repo_audit = audit_repository(
        ubuntu_root, suites, components,
        from_series=from_series, to_series=to_series,
    )
    target_suites = [s for s in suites if series_from_suite(s) == to_series]
    packages, provenance = load_suite_packages(
        ubuntu_root, target_suites, components,
    )
    core_analysis = analyze_core_packages(packages, ubuntu_root)
    closure = follow_dependency_closure(
        packages,
        [
            'initramfs-tools', 'systemd', 'udev', 'ubuntu-minimal',
            'linux-generic', 'busybox-initramfs',
        ],
        fields=('Pre-Depends', 'Depends'),
    )
    sources_analysis = analyze_client_sources_lines(
        client_sources_lines or [],
    ) if client_sources_lines is not None else OrderedDict()

    keep_analysis = OrderedDict()
    found_components = OrderedDict()
    if main_log_text:
        found_components = parse_found_components(main_log_text)
        keeps = parse_keep_at_same_version(main_log_text)
        keep_analysis = classify_keep_list(
            keeps, packages, installed_versions=installed_manifest or {},
            ubuntu_root=ubuntu_root,
        )

    plan_suite_summary = OrderedDict()
    if plan_packages_tsv and os.path.isfile(plan_packages_tsv):
        suite_c = Counter()
        pocket_c = Counter()
        with open(plan_packages_tsv, 'r') as fh:
            header = fh.readline().rstrip('\n').split('\t')
            for line in fh:
                parts = line.rstrip('\n').split('\t')
                if len(parts) < 7:
                    continue
                if parts[0] != 'xenial-to-bionic':
                    continue
                suite_c[parts[5]] += 1
                pocket_c[parts[6]] += 1
        plan_suite_summary = OrderedDict([
            ('suite_counts', OrderedDict(sorted(suite_c.items()))),
            ('pocket_counts', OrderedDict(sorted(pocket_c.items()))),
        ])

    sim = OrderedDict()
    if installed_manifest:
        sim = simulate_mirror_candidates(installed_manifest, packages)

    hypotheses = evaluate_hypotheses(
        repo_audit, sources_analysis, core_analysis, keep_analysis,
        plan_suite_summary,
    )

    return OrderedDict([
        ('schema_version', 1),
        ('generated_at', iso_now()),
        ('hop', '%s-to-%s' % (from_series, to_series)),
        ('repository_audit', repo_audit),
        ('sources_list_distupgrade_semantics', sources_analysis),
        ('found_components_from_main_log', found_components),
        ('core_package_analysis', core_analysis),
        ('dependency_closure', closure),
        ('keep_classification', keep_analysis),
        ('plan_suite_summary', plan_suite_summary),
        ('mirror_simulation', sim),
        ('reboot_gate_proposal', propose_reboot_gates()),
        ('hypotheses', hypotheses),
        ('most_likely_root_cause', OrderedDict([
            ('primary', 'H7'),
            ('secondary', ['H4', 'H8', 'H1']),
            ('summary', (
                'Client sources.list uses signed-by=, which DistUpgrade\'s '
                'bundled SourceEntry parser marks invalid. Pocket/component '
                'rewrite then fails to register bionic-updates/security '
                'components (matches found_components evidence). Combined '
                'with discovery-exact payload / pocket-clone indexes, the '
                'upgrade transaction diverges from internet upgrade; observed '
                'boot failure correlates with missing initrd for the installed '
                'Bionic kernel ABI.'
            )),
        ])),
    ])
