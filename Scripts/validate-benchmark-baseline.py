#!/usr/bin/env python3
"""Reject cached build-input drift; record exact dependency/configuration hashes."""
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def harness_files(root):
    spec = importlib.util.spec_from_file_location('benchmark_harness', root / 'Scripts/synchronize-benchmark-harness.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return set(module.FILES)


def validate(candidate, baseline, revision):
    expected = git(candidate, 'rev-parse', revision + '^{commit}').strip()
    if git(baseline, 'rev-parse', 'HEAD').strip() != expected:
        raise ValueError('Cached baseline is at a different revision')
    overlays = harness_files(candidate)
    records = {}

    def inspect(checkout, prefix='', expected_revision=None):
        head = git(checkout, 'rev-parse', 'HEAD').decode().strip()
        if expected_revision and head != expected_revision:
            raise ValueError('Dependency revision differs: ' + prefix)
        entries = git(checkout, 'ls-tree', '-r', '-z', 'HEAD').decode().split('\0')
        modules = {}
        for entry in entries:
            if entry.startswith('160000 '):
                descriptor, name = entry.split('\t', 1)
                modules[name] = descriptor.split()[2]
        changed = set(filter(None, git(checkout, 'diff', '--name-only', 'HEAD', '-z').decode().split('\0')))
        extra = set(filter(None, git(checkout, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0')))
        for name in changed | extra:
            full = prefix + name
            if name in modules:
                continue
            if not prefix and full in overlays:
                continue  # Synchronization replaces these exact benchmark-only files.
            if full == 'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib.xcconfig':
                original = git(checkout, 'show', 'HEAD:' + name)
                with tempfile.TemporaryDirectory() as tmp:
                    directory = Path(tmp)
                    patched = directory / 'SQLiteLib.xcconfig'
                    patched.write_bytes(original)
                    subprocess.run(['git', 'apply', '--unidiff-zero', str(baseline / 'GRDBCustomSQLite/SQLiteLib-macOS15.patch')],
                                   cwd=directory, check=True, capture_output=True)
                    if (checkout / name).read_bytes() != patched.read_bytes():
                        raise ValueError('Unexpected SQLite configuration patch')
                continue
            # Ignored generated dependency files are checked separately below.
            if name in changed or Path(name).suffix in {'.swift', '.yml', '.yaml', '.xcconfig', '.pbxproj', '.sh', '.py', '.h', '.c'}:
                raise ValueError('Cached baseline contains unexpected build input: ' + full)
        records[prefix or '.'] = {'commit': head}
        for name, sha in modules.items():
            inspect(checkout / name, prefix + name + '/', sha)

    inspect(baseline)
    for folder in ['Config', 'Sources', 'Trace.xcodeproj']:
        ignored = git(baseline, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z', '--', folder).decode().split('\0')
        for name in filter(None, ignored):
            if Path(name).suffix in {'.swift', '.xcconfig', '.pbxproj'}:
                raise ValueError('Cached baseline contains ignored build input: ' + name)
    generated = {
        'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib-USER.xcconfig': 'GRDBCustomSQLite/SQLiteLib-USER.xcconfig',
        'Vendor/GRDB.swift/SQLiteCustom/GRDBCustomSQLite-USER.xcconfig': 'GRDBCustomSQLite/GRDBCustomSQLite-USER.xcconfig',
        'Vendor/GRDB.swift/SQLiteCustom/GRDBCustomSQLite-USER.h': 'GRDBCustomSQLite/GRDBCustomSQLite-USER.h',
    }
    for output, source in generated.items():
        if (baseline / output).exists() and (baseline / output).read_bytes() != (baseline / source).read_bytes():
            raise ValueError('Unexpected generated dependency configuration: ' + output)
    inputs = ['project.yml', 'Trace.xcodeproj/project.pbxproj', '.gitmodules', '.mise.toml']
    inputs += [str(p.relative_to(baseline)) for folder in ['Config', 'GRDBCustomSQLite']
               for p in (baseline / folder).glob('*') if p.is_file()]
    inputs += [p for p in generated if (baseline / p).exists()]
    patched = 'Vendor/GRDB.swift/SQLiteCustom/src/SQLiteLib.xcconfig'
    if (baseline / patched).exists(): inputs.append(patched)
    records['build_input_sha256'] = {name: hashlib.sha256((baseline / name).read_bytes()).hexdigest()
                                   for name in sorted(inputs) if (baseline / name).exists()}
    production = hashlib.sha256()
    for name in sorted(filter(None, git(baseline, 'ls-files', '-z', '--', 'Sources').decode().split('\0'))):
        if name not in overlays:
            production.update(name.encode() + b'\0' + (baseline / name).read_bytes())
    records['production_sources_sha256'] = production.hexdigest()
    return records


if __name__ == '__main__':
    try:
        print(json.dumps(validate(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]), indent=2))
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
