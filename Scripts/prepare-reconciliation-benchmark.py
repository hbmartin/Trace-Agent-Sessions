#!/usr/bin/env python3
"""Install reproducible decoded-row instrumentation in an exported source tree."""
import argparse
import hashlib
import json
from pathlib import Path

BEGIN = "// BEGIN RECONCILIATION ROW MEASUREMENT"
END = "// END RECONCILIATION ROW MEASUREMENT"
PROBE = '''    #if TRACE_CHECKPOINT_BENCHMARK
    // BEGIN RECONCILIATION ROW MEASUREMENT
    private nonisolated let measuredReconciliationRows = OSAllocatedUnfairLock(initialState: 0)
    public nonisolated var reconciliationBenchmarkDecodedRows: Int { measuredReconciliationRows.withLock { $0 } }
    private nonisolated func measureReconciliationRow(_ row: IndexedSourcePath) -> IndexedSourcePath {
        measuredReconciliationRows.withLock { $0 += 1 }
        return row
    }
    public func reconciliationBenchmarkRoot(_ root: URL) throws -> Int64 {
        try register(root: SourceRoot(agent: .claudeCode, url: root))
    }
    public func reconciliationBenchmarkQuery(rootID: Int64, scopes: [String], caseSensitive: Bool) throws -> Int {
        try paths(agent: .claudeCode, rootID: rootID, scopes: scopes, caseSensitive: caseSensitive).count
    }
    // END RECONCILIATION ROW MEASUREMENT
    #else
    private nonisolated func measureReconciliationRow(_ row: IndexedSourcePath) -> IndexedSourcePath { row }
    #endif
'''
EXPRESSION = 'IndexedSourcePath(id: $0["id"], rootID: $0["root_id"], path: $0["path"])'


def instrument(source):
    if BEGIN in source:
        if source.count(PROBE) != 1 or source.count('measureReconciliationRow(' + EXPRESSION + ')') != 1:
            raise ValueError('Conflicting reconciliation instrumentation')
        return source
    if 'reconciliationBenchmarkDecodedRows' in source or END in source:
        raise ValueError('Conflicting reconciliation instrumentation')
    anchor = '    private let pool: DatabasePool'
    for marker in (anchor, '    func paths(agent:', '    private var rollupFailures'):
        if marker == '    func paths(agent:':
            if not source.count(marker): raise ValueError('Missing paths boundary')
        elif source.count(marker) != 1:
            raise ValueError('Missing unique reconciliation anchor: ' + marker)
    start, end = source.index('    func paths(agent:'), source.index('    private var rollupFailures')
    body = source[start:end]
    if body.count(EXPRESSION) != 1:
        raise ValueError('Missing unique decoded-row anchor')
    body = body.replace(EXPRESSION, 'measureReconciliationRow(' + EXPRESSION + ')', 1)
    return (source[:start] + body + source[end:]).replace(anchor, PROBE + anchor, 1)


def prepare(root, *, allow_checkout=False):
    if (root / '.git').exists() and not allow_checkout:
        raise ValueError('Use an exported source tree, not a Git checkout')
    path = root / 'Sources/TraceCore/Database/IndexDatabase.swift'
    source = path.read_text()
    result = instrument(source)
    if result != source: path.write_text(result)
    return {'instrumentation': 'reconciliation-decoded-row-v1',
            'counterDefinition': 'materialized IndexedSourcePath objects; not SQLite rows visited or physical I/O',
            'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
            'instrumentedSHA256': hashlib.sha256(result.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.source_root.resolve()), sort_keys=True))
        return 0
    except (ValueError, OSError) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
