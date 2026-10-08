#!/usr/bin/env python3
"""Publish only fully prepared baseline caches; retain interrupted preparation."""
import argparse
import fcntl
import importlib.util
import json
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


def module(root, name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), root / 'Scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def prepare(candidate, cache, revision):
    candidate, cache = candidate.resolve(), cache.resolve()
    validator = module(candidate, 'validate-benchmark-baseline')
    synchronize = module(candidate, 'synchronize-benchmark-harness').synchronize
    revision = validator.git(candidate, 'rev-parse', revision + '^{commit}').decode().strip()
    cache.parent.mkdir(parents=True, exist_ok=True)
    with cache.with_name(cache.name + '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        records = validator.validate(candidate, cache, revision, role='baseline', allow_uninitialized=True) if cache.exists() else None
        if records is not None and not records.get('uninitialized_submodules'):
            synchronize(candidate, cache)
            subprocess.run([str(cache / 'Scripts/configure-grdb.sh')], check=True, stdout=subprocess.DEVNULL)
            return validator.validate(candidate, cache, revision, role='baseline')
        stage = Path(tempfile.mkdtemp(prefix=cache.name + '.preparing-', dir=cache.parent))
        record = stage.with_name(stage.name + '.json')
        evidence = {'candidate': str(candidate), 'cache': str(cache), 'revision': revision,
                    'staging': str(stage), 'status': 'preparing', 'previousValidation': records}
        def save():
            record.write_text(json.dumps(evidence, indent=2) + '\n')
        save()
        try:
            subprocess.run(['git', 'clone', '--quiet', '--shared', '--no-checkout', str(candidate), str(stage)], check=True)
            subprocess.run(['git', '-C', str(stage), 'checkout', '--quiet', '--detach', revision], check=True)
            subprocess.run(['git', '-C', str(stage), 'submodule', 'update', '--init', '--recursive'], check=True, stdout=sys.stderr)
            synchronize(candidate, stage)
            subprocess.run([str(stage / 'Scripts/configure-grdb.sh')], check=True, stdout=subprocess.DEVNULL)
            prepared = validator.validate(candidate, stage, revision, role='baseline')
            if cache.exists():
                quarantine = cache.with_name(cache.name + '.incomplete-' + uuid.uuid4().hex[:12])
                cache.rename(quarantine)
                evidence['previousCache'] = str(quarantine)
                save()
            stage.rename(cache)
            evidence['status'] = 'published'
            save()
            return prepared
        except BaseException as error:
            evidence.update(status='interrupted', error=str(error))
            save()
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('cache', type=Path)
    parser.add_argument('revision')
    args = parser.parse_args()
    print(json.dumps(prepare(args.candidate, args.cache, args.revision), indent=2))
