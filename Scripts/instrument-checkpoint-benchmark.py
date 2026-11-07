#!/usr/bin/env python3
"""Apply synchronized timing and explicitly defined state counters to local builds."""
import argparse
import hashlib
import json
from pathlib import Path

BEGIN = '// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT'
END = '// END CHECKPOINT ACCEPTANCE MEASUREMENT'
MEASURE = 'let measurement = CheckpointAcceptanceBenchmark.begin()'
FINISH = 'defer { CheckpointAcceptanceBenchmark.end(measurement) }'
IDLE = '    public func waitUntilIdle()'
COUNTS = '    public var checkpointBenchmarkCounts: [String: Int] {'
KIND = '    public var checkpointBenchmarkPrefixIndexEntryKind: String {'
SCHEDULER_KIND = '    public func checkpointBenchmarkPrefixIndexEntryKind() -> String {'


def unique(source, markers, label):
    for marker in markers:
        if source.count(marker) != 1:
            raise ValueError('Missing unique ' + label + ': ' + marker)


def block(source, marker):
    """Return the complete body of a validated Swift declaration."""
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    position = opening + 1
    while depth:
        if position >= len(source):
            raise ValueError('Unclosed instrumentation declaration: ' + marker)
        depth += (source[position] == '{') - (source[position] == '}')
        position += 1
    return source[start:position]


def counter_layout(source):
    if 'var stamps: [Stamp]' in source:
        return 'heap-mark', '$1.stamps.count', '$1.unpaid.values.count + $1.paid.values.count'
    if 'class Frontier {' in source or 'struct Frontier {' in source:
        return 'frontier-node', '$1.outcomes.paths.count + $1.outcomes.roots.count + ($1.outcomes.fullScan == 0 ? 0 : 1)', '$1.frontier.count'
    return 'unavailable', None, None


def counters(source):
    kind, outcomes, prefix = counter_layout(source)
    values = '["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": ' + ('$0.proofs.count' if kind != 'unavailable' else '0')
    if outcomes is not None:
        values += ', "outcomes": $0.streams.values.reduce(0) { total, stream in total + stream.records.values.reduce(0) { $0 + ' + outcomes + ' } }'
        values += ', "prefixIndexEntries": $0.streams.values.reduce(0) { $0 + ' + prefix + ' }'
    values += ']'
    return COUNTS + '\n        state.withLock { ' + values + ' }\n    }'


def instrument(source, probe_source, synchronize_existing=False):
    unique(probe_source, [BEGIN, END], 'probe boundary')
    start = probe_source.index(BEGIN)
    end = probe_source.index(END, start) + len(END)
    probe = probe_source[start:end]
    installed = BEGIN in source
    if installed:
        unique(source, [BEGIN, END, MEASURE, FINISH, IDLE, COUNTS], 'existing instrumentation boundary')
        existing_start = source.index(BEGIN)
        existing_end = source.index(END)
        if existing_end < existing_start:
            raise ValueError('Invalid instrumentation boundary order')
        old = source[existing_start:existing_end + len(END)]
        if old != probe and not synchronize_existing:
            raise ValueError('Different acceptance instrumentation is already installed')
        synchronized = source.replace(old, probe, 1)
        # Current builds share their DEBUG and benchmark count implementation.
        if 'private struct RetainedCounts {' not in source:
            old_counts = block(source, COUNTS)
            new_counts = counters(source)
            if old_counts != new_counts and not synchronize_existing:
                raise ValueError('Historical count instrumentation requires explicit synchronization')
            synchronized = synchronized.replace(old_counts, new_counts, 1)
    else:
        if 'fileprivate func accept(_ coverage: Coverage,' not in source:
            raise ValueError('Unsupported baseline checkpoint implementation')
        boundary = '        guard !coverage.entries.isEmpty else { return .committed([:]) }'
        ledger_end = '    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK\n    var retainedRecordCount:'
        unique(source, ['/// Durable checkpoint value', boundary, ledger_end, IDLE], 'historical boundary')
        synchronized = source.replace('/// Durable checkpoint value', probe + '\n\n/// Durable checkpoint value', 1)
        synchronized = synchronized.replace(boundary, '        #if TRACE_CHECKPOINT_BENCHMARK\n        ' + MEASURE + '\n        ' + FINISH + '\n        #endif\n' + boundary, 1)
        synchronized = synchronized.replace(ledger_end, '    #if TRACE_CHECKPOINT_BENCHMARK\n' + counters(source) + '\n    #endif\n' + ledger_end, 1)
        synchronized = synchronized.replace(IDLE, '''    #if TRACE_CHECKPOINT_BENCHMARK
    public func checkpointBenchmarkCounts() -> [String: Int] {
        var counts = checkpointLedger.checkpointBenchmarkCounts
        counts["proofs"] = pendingCheckpointAcceptances.count
        return counts
    }
    #endif

''' + IDLE, 1)
    kind = counter_layout(source)[0]
    kind_declaration = KIND + ' "' + kind + '" }'
    if KIND in synchronized:
        unique(synchronized, [KIND], 'counter kind boundary')
        existing_kind = block(synchronized, KIND)
        if existing_kind != kind_declaration and not synchronize_existing:
            raise ValueError('Different counter kind requires explicit synchronization')
        synchronized = synchronized.replace(existing_kind, kind_declaration, 1)
    else:
        declaration = block(synchronized, COUNTS)
        synchronized = synchronized.replace(declaration, declaration + '\n' + kind_declaration, 1)
    scheduler_kind = SCHEDULER_KIND + ' checkpointLedger.checkpointBenchmarkPrefixIndexEntryKind }'
    if SCHEDULER_KIND in synchronized:
        unique(synchronized, [SCHEDULER_KIND], 'scheduler counter kind boundary')
        synchronized = synchronized.replace(block(synchronized, SCHEDULER_KIND), scheduler_kind, 1)
    else:
        synchronized = synchronized.replace(IDLE, '    #if TRACE_CHECKPOINT_BENCHMARK\n' + scheduler_kind + '\n    #endif\n\n' + IDLE, 1)
    return synchronized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--probe-source', type=Path, required=True)
    parser.add_argument('--synchronize-existing', action='store_true', help='Explicitly replace historical timing and count instrumentation')
    args = parser.parse_args()
    path = args.root / 'Sources/TraceCore/Indexing/IndexScheduler.swift'
    original = path.read_text()
    updated = instrument(original, args.probe_source.read_text(), args.synchronize_existing)
    path.write_text(updated)
    print(json.dumps({'path': str(path), 'originalSHA256': hashlib.sha256(original.encode()).hexdigest(),
                      'instrumentedSHA256': hashlib.sha256(updated.encode()).hexdigest()}, sort_keys=True))


if __name__ == '__main__':
    main()
