#!/usr/bin/env python3
"""Install only the current harness and benchmark instrumentation in a baseline."""
import hashlib
import json
import shutil
import sys
from pathlib import Path

FILES = [
    'Tests/TracePerformanceTests/TracePerformanceTests.swift',
    'Scripts/measure-transcript-scroll.sh',
    'Scripts/compare-transcript-scroll-metrics.py',
    'Scripts/export-benchmark-samples.py',
    'Scripts/synchronize-benchmark-harness.py',
    'Scripts/configure-grdb.sh',
    'GRDBCustomSQLite/SQLiteRegularFiles.patch',
    'GRDBCustomSQLite/SQLiteRegularFiles-v1.patch',
    'Scripts/validate-benchmark-baseline.py',
    'GRDBCustomSQLite/SQLiteNoControllingTerminal.patch',
    'Sources/TraceCore/Diagnostics/TracePerformance.swift',
]


def synchronize(candidate, baseline):
    hashes = {}
    for name in FILES:
        source, target = candidate / name, baseline / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if source.read_bytes() != target.read_bytes():
            raise SystemExit(f'Harness differs: {name}')
        hashes[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    return hashes


if __name__ == '__main__':
    print(json.dumps(synchronize(Path(sys.argv[1]), Path(sys.argv[2])), indent=2))
