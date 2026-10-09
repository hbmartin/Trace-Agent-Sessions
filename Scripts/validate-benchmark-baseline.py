#!/usr/bin/env python3
"""Reject cached build-input drift; record exact dependency/configuration hashes."""
import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SQLITE_PATCHES = {
    'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib.xcodeproj/project.pbxproj': (
        'SQLiteLib.xcodeproj/project.pbxproj', 'GRDBCustomSQLite/SQLiteRegularFiles.patch', 'regular-file build dependency'),
    'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib.xcconfig': (
        'SQLiteLib.xcconfig', 'GRDBCustomSQLite/SQLiteLib-macOS15.patch', 'configuration'),
    'Vendor/GRDB.swift/SQLiteCustom/src/sqlite/src/os_unix.c': (
        'sqlite/src/os_unix.c', ('GRDBCustomSQLite/SQLiteRegularFiles.patch',
                              'GRDBCustomSQLite/SQLiteNoControllingTerminal.patch'), 'regular-file'),
}


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def owns_checkout(checkout):
    if not checkout.exists():
        return False
    try:
        return checkout.samefile(Path(git(checkout, 'rev-parse', '--show-toplevel').decode().strip()))
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def harness_files(root):
    spec = importlib.util.spec_from_file_location('benchmark_harness', root / 'Scripts/synchronize-benchmark-harness.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return set(module.FILES)


def validate(candidate, baseline, revision, *, role=None, allow_uninitialized=False):
    candidate, baseline = candidate.resolve(), baseline.resolve()
    role = role or ('candidate' if candidate.samefile(baseline) else 'baseline')
    label = 'Candidate checkout' if role == 'candidate' else 'Cached baseline'
    expected = git(candidate, 'rev-parse', revision + '^{commit}').strip()
    root_is_empty = baseline.exists() and not any(p.name not in {'.git', '.DS_Store'} for p in baseline.iterdir())
    if root_is_empty:
        if not allow_uninitialized:
            raise ValueError(label + ' has an uninitialized checkout')
        return {'uninitialized_submodules': ['.']}
    if git(baseline, 'rev-parse', 'HEAD').strip() != expected:
        raise ValueError(label + ' is at a different revision')
    overlays = harness_files(candidate)
    records = {}
    missing = []

    def signing_configuration(path):
        for line in path.read_text().splitlines():
            line = line.split('//', 1)[0].strip()
            if line and not re.fullmatch(r'DEVELOPMENT_TEAM\s*=\s*[A-Za-z0-9]*\s*;?', line):
                raise ValueError(label + ' signing configuration contains an unsupported build setting')

    def digest_paths(checkout, names):
        result = hashlib.sha256()
        for name in sorted(names):
            path = checkout / name
            if path.is_file():
                result.update(name.encode() + b'\0' + path.read_bytes())
        return result.hexdigest()

    def inspect(checkout, prefix='', expected_revision=None):
        # Git walks upward from an uninitialized submodule, returning the parent
        # HEAD. Establish repository ownership before asking for its revision.
        if not owns_checkout(checkout):
            if not allow_uninitialized:
                raise ValueError(label + ' has an uninitialized dependency: ' + prefix)
            if checkout.exists() and any(p.name not in {'.git', '.DS_Store'} for p in checkout.iterdir()):
                raise ValueError(label + ' has files in an uninitialized dependency: ' + prefix)
            missing.append(prefix.rstrip('/'))
            return
        index = Path(git(checkout, 'rev-parse', '--git-path', 'index').decode().strip())
        if not index.is_absolute():
            index = checkout / index
        empty_worktree = not any(p.name not in {'.git', '.DS_Store'} for p in checkout.iterdir())
        if expected_revision and (not index.exists() or empty_worktree):
            if not empty_worktree:
                raise ValueError(label + ' has files in an incomplete dependency: ' + prefix)
            if not allow_uninitialized:
                raise ValueError(label + ' has an uninitialized dependency: ' + prefix)
            missing.append(prefix.rstrip('/'))
            return
        head = git(checkout, 'rev-parse', 'HEAD').decode().strip()
        if expected_revision and head != expected_revision:
            raise ValueError(label + ': Dependency revision differs: ' + prefix)
        entries = git(checkout, 'ls-tree', '-r', '-z', 'HEAD').decode().split('\0')
        modules = {}
        for entry in entries:
            if entry.startswith('160000 '):
                descriptor, name = entry.split('\t', 1)
                modules[name] = descriptor.split()[2]
        # Dependencies are inspected below. Let their ownership policy handle
        # partial repositories instead of having the parent diff fail first.
        changed = set(filter(None, git(checkout, 'diff', '--ignore-submodules=all', '--name-only', 'HEAD', '-z').decode().split('\0')))
        extra = set(filter(None, git(checkout, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')))
        for name in changed | extra:
            full = prefix + name
            if name in modules:
                continue
            if role == 'baseline' and not prefix and full in overlays:
                continue  # Synchronization replaces these exact benchmark-only files.
            if role == 'candidate' and full == 'Config/Signing.xcconfig' and name not in changed:
                signing_configuration(checkout / name)
                continue
            if full in SQLITE_PATCHES:
                patched_name, patch_name, patch_label = SQLITE_PATCHES[full]
                original = git(checkout, 'show', 'HEAD:' + name)
                with tempfile.TemporaryDirectory() as tmp:
                    directory = Path(tmp)
                    patched = directory / patched_name
                    patched.parent.mkdir(parents=True, exist_ok=True)
                    patched.write_bytes(original)
                    patch_names = patch_name if isinstance(patch_name, tuple) else (patch_name,)
                    for recognized_patch in patch_names:
                        patch_path = baseline / recognized_patch
                        # Older prepared caches have the previous recognized VFS
                        # overlay; preparation adds the independent terminal patch.
                        if not patch_path.exists() and recognized_patch.endswith('SQLiteNoControllingTerminal.patch') and role == 'baseline':
                            continue
                        subprocess.run(['git', 'apply', '--unidiff-zero', '--include=' + patched_name, str(patch_path)],
                                       cwd=directory, check=True, capture_output=True)
                    if (checkout / name).read_bytes() != patched.read_bytes():
                        raise ValueError(label + ': Unexpected SQLite ' + patch_label + ' patch')
                continue
            # Ignored generated dependency files are checked separately below.
            if name in changed or Path(name).suffix in {'.swift', '.yml', '.yaml', '.xcconfig', '.pbxproj', '.sh', '.py', '.h', '.c'}:
                raise ValueError(label + ' contains unexpected build input: ' + full)
        tracked = [entry.split('\t', 1)[1] for entry in entries if entry and not entry.startswith('160000 ')]
        records[prefix or '.'] = {'commit': head, 'tracked_files_sha256': digest_paths(checkout, tracked)}
        for name, sha in modules.items():
            inspect(checkout / name, prefix + name + '/', sha)

    inspect(baseline)
    for folder in ['Config', 'Sources', 'Trace.xcodeproj']:
        ignored = git(baseline, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z', '--', folder).decode().split('\0')
        for name in filter(None, ignored):
            if role == 'candidate' and name == 'Config/Signing.xcconfig':
                signing_configuration(baseline / name)
                continue
            if Path(name).suffix in {'.swift', '.xcconfig', '.pbxproj'}:
                raise ValueError(label + ' contains ignored build input: ' + name)
    generated = {
        'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib-USER.xcconfig': 'GRDBCustomSQLite/SQLiteLib-USER.xcconfig',
        'Vendor/GRDB.swift/SQLiteCustom/GRDBCustomSQLite-USER.xcconfig': 'GRDBCustomSQLite/GRDBCustomSQLite-USER.xcconfig',
        'Vendor/GRDB.swift/SQLiteCustom/GRDBCustomSQLite-USER.h': 'GRDBCustomSQLite/GRDBCustomSQLite-USER.h',
    }
    for output, source in generated.items():
        if (baseline / output).exists() and (baseline / output).read_bytes() != (baseline / source).read_bytes():
            raise ValueError(label + ': Unexpected generated dependency configuration: ' + output)
    inputs = ['project.yml', 'Trace.xcodeproj/project.pbxproj', '.gitmodules', '.mise.toml']
    inputs += list(filter(None, git(baseline, 'ls-files', '-z', '--', 'Config', 'GRDBCustomSQLite').decode().split('\0')))
    if role == 'candidate' and (baseline / 'Config/Signing.xcconfig').is_file():
        inputs.append('Config/Signing.xcconfig')
    inputs += [p for p in generated if (baseline / p).exists()]
    inputs += [name for name in SQLITE_PATCHES if (baseline / name).exists()]
    records['build_input_sha256'] = {name: hashlib.sha256((baseline / name).read_bytes()).hexdigest()
                                   for name in sorted(inputs) if (baseline / name).exists()}
    production = hashlib.sha256()
    for name in sorted(filter(None, git(baseline, 'ls-files', '-z', '--', 'Sources').decode().split('\0'))):
        if name not in overlays:
            production.update(name.encode() + b'\0' + (baseline / name).read_bytes())
    records['production_sources_sha256'] = production.hexdigest()
    records['harness_sha256'] = {name: hashlib.sha256((baseline / name).read_bytes()).hexdigest()
                                for name in sorted(overlays) if (baseline / name).is_file()}
    if missing:
        records['uninitialized_submodules'] = missing
    return records


def require_complete_harness(candidate, records):
    expected = harness_files(candidate)
    missing = expected - records['harness_sha256'].keys()
    extra = records['harness_sha256'].keys() - expected
    if missing or extra:
        raise ValueError('Missing synchronized harness files: ' + ', '.join(sorted(missing))
                         + '; unexpected files: ' + ', '.join(sorted(extra)))


def initialize_missing(candidate, baseline, revision):
    """Repair missing clones only, after checking all initialized dependency drift."""
    candidate, baseline = candidate.resolve(), baseline.resolve()
    previous_missing = None
    while True:
        records = validate(candidate, baseline, revision, role='baseline', allow_uninitialized=True)
        missing = records.get('uninitialized_submodules', [])
        if not missing:
            return
        if missing == previous_missing:
            raise ValueError('Dependency initialization made no progress: ' + ', '.join(missing))
        previous_missing = missing
        # Initialize one level at a time; recursively updating an initialized
        # dependency could otherwise hide a mismatched nested checkout.
        for path in missing:
            if path == '.':
                if not owns_checkout(baseline):
                    raise ValueError('Cached baseline must be its own repository before direct initialization')
                pinned = git(candidate, 'rev-parse', revision + '^{commit}').decode().strip()
                subprocess.run(['git', '-C', str(baseline), 'checkout', '--detach', pinned], check=True)
                continue
            parent, name = Path(path).parent, Path(path).name
            if parent == Path('.'):
                owner = baseline
            else:
                # Locate the nearest initialized repository that owns this gitlink.
                owner = baseline / parent
                while not owns_checkout(owner):
                    if owner == baseline:
                        raise ValueError('Cached baseline has no initialized owner for dependency: ' + path)
                    owner = owner.parent
                name = str((baseline / path).relative_to(owner))
            target = baseline / path
            if owns_checkout(target):
                # A recognized no-checkout clone can have default HEAD ahead of
                # the gitlink. Ordinary submodule update may leave it unchanged.
                pinned = git(owner, 'rev-parse', 'HEAD:' + name).decode().strip()
                subprocess.run(['git', '-C', str(target), 'checkout', '--detach', pinned], check=True)
            else:
                subprocess.run(['git', '-C', str(owner), 'submodule', 'update', '--init', '--', name], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('checkout', type=Path)
    parser.add_argument('revision')
    parser.add_argument('--role', choices=['baseline', 'candidate'])
    parser.add_argument('--initialize-missing', action='store_true')
    args = parser.parse_args()
    try:
        if args.initialize_missing:
            initialize_missing(args.candidate.resolve(), args.checkout.resolve(), args.revision)
        print(json.dumps(validate(args.candidate, args.checkout, args.revision, role=args.role), indent=2))
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
