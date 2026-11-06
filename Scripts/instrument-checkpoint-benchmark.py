#!/usr/bin/env python3
"""Apply identical measurement boundaries to a pinned historical checkpoint build."""
import argparse
import hashlib
import json
from pathlib import Path


def instrument(source, probe_source, synchronize_existing=False):
    start = probe_source.index('// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT')
    end = probe_source.index('// END CHECKPOINT ACCEPTANCE MEASUREMENT', start) + len('// END CHECKPOINT ACCEPTANCE MEASUREMENT')
    probe = probe_source[start:end] + '\n\n'
    if '// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT' in source:
        for marker in ['// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT', '// END CHECKPOINT ACCEPTANCE MEASUREMENT', 'let measurement = CheckpointAcceptanceBenchmark.begin()', 'defer { CheckpointAcceptanceBenchmark.end(measurement) }', '    public func waitUntilIdle()']:
            if source.count(marker) != 1:
                raise ValueError('Missing unique existing instrumentation boundary: ' + marker)
        if probe.strip() in source:
            return source
        if not synchronize_existing:
            raise ValueError('Different acceptance instrumentation is already installed')
        for marker in ['// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT', '// END CHECKPOINT ACCEPTANCE MEASUREMENT', 'let measurement = CheckpointAcceptanceBenchmark.begin()', 'defer { CheckpointAcceptanceBenchmark.end(measurement) }']:
            if source.count(marker) != 1:
                raise ValueError('Missing unique existing instrumentation boundary: ' + marker)
        existing_start = source.index('// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT')
        existing_end = source.index('// END CHECKPOINT ACCEPTANCE MEASUREMENT', existing_start) + len('// END CHECKPOINT ACCEPTANCE MEASUREMENT')
        synchronized = source[:existing_start] + probe.rstrip() + source[existing_end:]
        if 'var stamps: [Stamp]' in source:
            counts = 'state.withLock { ["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": $0.proofs.count] }'
            if synchronized.count(counts) != 1:
                raise ValueError('Missing unique historical count boundary')
            synchronized = synchronized.replace(counts, 'state.withLock { ["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": $0.proofs.count, "outcomes": $0.streams.values.reduce(0) { total, stream in total + stream.records.values.reduce(0) { $0 + $1.stamps.count } }, "checkpointBoundaries": $0.streams.values.reduce(0) { $0 + $1.records.count }] }', 1)
        return synchronized
    marker = '/// Durable checkpoint value'
    if marker not in source or 'fileprivate func accept(_ coverage: Coverage,' not in source:
        raise ValueError('Unsupported baseline checkpoint implementation')
    source = source.replace(marker, probe + marker, 1)
    boundary = '        guard !coverage.entries.isEmpty else { return .committed([:]) }'
    if source.count(boundary) != 1:
        raise ValueError('Missing unique historical acceptance boundary')
    source = source.replace(boundary, '''        #if TRACE_CHECKPOINT_BENCHMARK
        let measurement = CheckpointAcceptanceBenchmark.begin()
        defer { CheckpointAcceptanceBenchmark.end(measurement) }
        #endif
''' + boundary, 1)
    ledger_end = '    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK\n    var retainedRecordCount:'
    if source.count(ledger_end) != 1:
        raise ValueError('Missing unique historical ledger boundary')
    idle = '    public func waitUntilIdle()'
    if source.count(idle) != 1:
        raise ValueError('Missing unique historical idle boundary')
    source = source.replace(ledger_end, '''    #if TRACE_CHECKPOINT_BENCHMARK
    public var checkpointBenchmarkCounts: [String: Int] {
        state.withLock { ["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": 0] }
    }
    #endif
''' + ledger_end, 1)
    source = source.replace('    public func waitUntilIdle()', '''    #if TRACE_CHECKPOINT_BENCHMARK
    public func checkpointBenchmarkCounts() -> [String: Int] {
        var counts = checkpointLedger.checkpointBenchmarkCounts
        counts["proofs"] = pendingCheckpointAcceptances.count
        return counts
    }
    #endif

    public func waitUntilIdle()''', 1)
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--probe-source', type=Path, required=True)
    parser.add_argument('--synchronize-existing', action='store_true', help='Explicitly replace validated historical measurement instrumentation')
    args = parser.parse_args()
    path = args.root / 'Sources/TraceCore/Indexing/IndexScheduler.swift'
    original = path.read_text()
    updated = instrument(original, args.probe_source.read_text(), args.synchronize_existing)
    path.write_text(updated)
    print(json.dumps({'path': str(path), 'originalSHA256': hashlib.sha256(original.encode()).hexdigest(),
                      'instrumentedSHA256': hashlib.sha256(updated.encode()).hexdigest()}, sort_keys=True))


if __name__ == '__main__':
    main()
