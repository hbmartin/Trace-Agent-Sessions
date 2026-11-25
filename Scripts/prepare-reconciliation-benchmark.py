#!/usr/bin/env python3
"""Install reproducible, flag-gated instrumentation in an exported source tree."""
import argparse
import hashlib
import json
from pathlib import Path

BEGIN = "// BEGIN RECONCILIATION ROW MEASUREMENT"
END = "// END RECONCILIATION ROW MEASUREMENT"
LAYOUTS = ('pr106', 'count-cache')
CACHE_ANCHOR = '    private var nonASCIIPathCounts: [SourcePathKey: Int] = [:]'
FALLBACK_ANCHOR = 'let function = DatabaseFunction("trace_reconciliation_matches"'
CLASSIFICATION_ANCHOR = 'count = try Int.fetchOne(db, sql: "SELECT count(*) FROM source_file WHERE agent=? AND root_id=? AND path GLOB ?",'
EXPRESSION = 'IndexedSourcePath(id: $0["id"], rootID: $0["root_id"], path: $0["path"])'
WRAPPED = 'self.measureReconciliationRow(' + EXPRESSION + ')'
FALLBACK_CALL = 'self.recordReconciliationFallback()\n'
CLASSIFICATION_CALL = 'self.recordReconciliationClassification()\n'


def probe(layout):
    if layout not in LAYOUTS: raise ValueError('Unsupported instrumentation layout: ' + str(layout))
    roots = 'nonASCIIPathCounts.count' if layout == 'count-cache' else '0'
    return '''    #if TRACE_CHECKPOINT_BENCHMARK
    // BEGIN RECONCILIATION ROW MEASUREMENT
    private nonisolated let measuredReconciliationRows = OSAllocatedUnfairLock(initialState: 0)
    private nonisolated let measuredReconciliationFallbacks = OSAllocatedUnfairLock(initialState: 0)
    private nonisolated let measuredReconciliationClassifications = OSAllocatedUnfairLock(initialState: 0)
    public nonisolated var reconciliationBenchmarkDecodedRows: Int { measuredReconciliationRows.withLock { $0 } }
    private nonisolated func measureReconciliationRow(_ row: IndexedSourcePath) -> IndexedSourcePath {
        measuredReconciliationRows.withLock { $0 += 1 }; return row
    }
    private nonisolated func recordReconciliationFallback() { measuredReconciliationFallbacks.withLock { $0 += 1 } }
    private nonisolated func recordReconciliationClassification() { measuredReconciliationClassifications.withLock { $0 += 1 } }
    public nonisolated func reconciliationBenchmarkCaseSensitive(_ path: String) -> Bool {
        TraceFileIO.canonicalPath(path).isCaseSensitive
    }
    public func reconciliationBenchmarkState() -> [String: Int] {
        ["cacheRoots": ''' + roots + ''', "fallbackQueries": measuredReconciliationFallbacks.withLock { $0 },
         "classifications": measuredReconciliationClassifications.withLock { $0 }]
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
    private nonisolated func recordReconciliationFallback() {}
    private nonisolated func recordReconciliationClassification() {}
    #endif
'''


def insert_call(source, anchor, call):
    if source.count(anchor) != 1: raise ValueError('Missing unique instrumentation anchor: ' + anchor)
    start = source.rfind('\n', 0, source.index(anchor)) + 1
    indentation = source[start:source.index(anchor)]
    return source[:start] + indentation + call + source[start:]


def instrument(source, *, layout):
    value = probe(layout)
    if source.count(CACHE_ANCHOR) != (1 if layout == 'count-cache' else 0):
        raise ValueError('Source does not match explicit layout: ' + layout)
    if BEGIN in source:
        if (source.count(value) != 1 or source.count(WRAPPED) != 1
                or source.count(FALLBACK_CALL) != 1
                or source.count(CLASSIFICATION_CALL) != (1 if layout == 'count-cache' else 0)):
            raise ValueError('Conflicting reconciliation instrumentation')
        return source
    if 'reconciliationBenchmarkDecodedRows' in source or END in source:
        raise ValueError('Conflicting reconciliation instrumentation')
    anchor = '    private let pool: DatabasePool'
    for marker in (anchor, '    private var rollupFailures', FALLBACK_ANCHOR, EXPRESSION):
        if source.count(marker) != 1: raise ValueError('Missing unique reconciliation anchor: ' + marker)
    source = insert_call(source, FALLBACK_ANCHOR, FALLBACK_CALL)
    if layout == 'count-cache': source = insert_call(source, CLASSIFICATION_ANCHOR, CLASSIFICATION_CALL)
    source = source.replace(EXPRESSION, WRAPPED, 1)
    return source.replace(anchor, value + anchor, 1)


def prepare(root, *, layout, allow_checkout=False):
    if (root / '.git').exists() and not allow_checkout:
        raise ValueError('Use an exported source tree, not a Git checkout')
    path = root / 'Sources/TraceCore/Database/IndexDatabase.swift'
    source = path.read_text()
    result = instrument(source, layout=layout)
    if result != source: path.write_text(result)
    return {'instrumentation': 'reconciliation-query-v2', 'layout': layout,
            'counterDefinitions': {'decodedRows': 'materialized IndexedSourcePath values, not rows visited or physical I/O',
                'fallbackQueries': 'executed fallback SELECT branches', 'classifications': 'cold or invalidated non-ASCII count queries',
                'cacheRoots': 'retained root-count entries; zero for pr106, which has no count cache'},
            'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
            'instrumentedSHA256': hashlib.sha256(result.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--layout', choices=LAYOUTS, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(args.source_root.resolve(), layout=args.layout), sort_keys=True))
        return 0
    except (ValueError, OSError) as error: parser.exit(2, str(error) + '\n')


if __name__ == '__main__': raise SystemExit(main())
