#!/usr/bin/env python3
"""Apply identical measurement boundaries to a pinned historical checkpoint build."""
import argparse
import hashlib
import json
from pathlib import Path


def instrument(source, probe_source):
    start = probe_source.index('// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT')
    end = probe_source.index('// END CHECKPOINT ACCEPTANCE MEASUREMENT', start) + len('// END CHECKPOINT ACCEPTANCE MEASUREMENT')
    probe = probe_source[start:end] + '\n\n'
    if '// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT' in source:
        if probe.strip() not in source:
            raise ValueError('Different acceptance instrumentation is already installed')
        return source
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
    args = parser.parse_args()
    path = args.root / 'Sources/TraceCore/Indexing/IndexScheduler.swift'
    original = path.read_text()
    updated = instrument(original, args.probe_source.read_text())
    path.write_text(updated)
    print(json.dumps({'path': str(path), 'originalSHA256': hashlib.sha256(original.encode()).hexdigest(),
                      'instrumentedSHA256': hashlib.sha256(updated.encode()).hexdigest()}, sort_keys=True))


if __name__ == '__main__':
    main()
