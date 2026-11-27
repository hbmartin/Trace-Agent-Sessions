#!/usr/bin/env python3
"""Install reproducible, flag-gated instrumentation in an exported source tree."""
import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path

BEGIN = "// BEGIN RECONCILIATION ROW MEASUREMENT"
END = "// END RECONCILIATION ROW MEASUREMENT"
LAYOUTS = ('pr106', 'count-cache', 'connection-matcher')
CACHE_ANCHOR = '    private var nonASCIIPathCounts: [SourcePathKey: Int] = [:]'
FALLBACK_ANCHOR = 'let function = DatabaseFunction("trace_reconciliation_matches"'
CONNECTION_ANCHOR = 'try functions.withMatcher(matcher, in: db) {'
CLASSIFICATION_ANCHOR = 'count = try Int.fetchOne(db, sql: "SELECT count(*) FROM source_file WHERE agent=? AND root_id=? AND path GLOB ?",'
EXPRESSION = 'IndexedSourcePath(id: $0["id"], rootID: $0["root_id"], path: $0["path"])'
WRAPPED = 'self.measureReconciliationRow(' + EXPRESSION + ')'
FALLBACK_CALL = 'self.recordReconciliationFallback()\n'
CLASSIFICATION_CALL = 'self.recordReconciliationClassification()\n'


def probe(layout):
    if layout not in LAYOUTS: raise ValueError('Unsupported instrumentation layout: ' + str(layout))
    roots = '0' if layout == 'pr106' else 'nonASCIIPathCounts.count'
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
        ["cacheRoots": ''' + roots + ''', "functionRegistrations": ''' + ('reconciliationFunctions.registrations.withLock { $0 }' if layout == 'connection-matcher' else 'measuredReconciliationFallbacks.withLock { $0 }') + ''', "fallbackQueries": measuredReconciliationFallbacks.withLock { $0 },
         "classifications": measuredReconciliationClassifications.withLock { $0 }]
    }
    public final class ReconciliationDiscoveryBenchmark: Sendable {
        public let actualCaseSensitive: Bool
        private let root: SourceRoot
        private let context: SourceRootPathContext
        private let files: [DiscoveredSourceFile]
        private let scopes: [SourceRootScope]
        public init(root url: URL, count: Int, scopeCount: Int, caseSensitive: Bool, depth: Int = 1) {
            root = SourceRoot(agent: .claudeCode, url: url)
            let actual = TraceFileIO.canonicalPath(url.path)
            actualCaseSensitive = actual.isCaseSensitive
            context = .init(scanPath: .init(path: actual.path,
                comparisonKey: TraceFileIO.comparisonKey(actual.path, caseSensitive: caseSensitive),
                isCaseSensitive: caseSensitive), configuredComponents: root.url.pathComponents)
            files = (0..<count).map { index in
                let middle = Array(repeating: "deep folder café %", count: max(0, depth - 1)).joined(separator: "/")
                let path = actual.path + "/p-" + String(index) + "/" + (middle.isEmpty ? "" : middle + "/") + "file.jsonl"
                return .init(agent: .claudeCode, root: url, canonicalPath: .init(path: path,
                    comparisonKey: TraceFileIO.comparisonKey(path, caseSensitive: actual.isCaseSensitive),
                    isCaseSensitive: actual.isCaseSensitive), format: .claudeJSONL)
            }
            scopes = (0..<min(count, scopeCount)).map { index in
                let name = "p-" + String(index), path = actual.path + "/" + name
                return .init(scanPath: .init(path: path,
                    comparisonKey: TraceFileIO.comparisonKey(path, caseSensitive: caseSensitive),
                    isCaseSensitive: caseSensitive), relativeScope: .init(components: [name], caseSensitive: caseSensitive))
            }
        }
        public var expectedLexicalBytes: Int { files.reduce(0) { $0 + $1.discoveryPath.utf8.count } }
        public func lexical() -> (accepted: Int, bytes: Int) {
            var accepted = 0, bytes = 0
            for file in files {
                if let scope = root.lexicalDiscoveryScope(file.discoveryPath, in: context) {
                    accepted += 1; bytes += scope.scanPath.path.utf8.count
                }
            }
            return (accepted, bytes)
        }
        public func run() -> (accepted: Int, failures: Int) {
            let result = verifiedDiscoveryResult(.init(files: files), agent: .claudeCode, root: root,
                capturedContext: context, currentContext: context, configuredRoots: [root], scopes: scopes)
            return (result.files.count, result.failures.count)
        }
    }
    public nonisolated func reconciliationBenchmarkMtime(path: String) throws -> Int64 {
        try pool.read { db in try Int64.fetchOne(db, sql: "SELECT mtime_ns FROM source_file WHERE agent=? AND path=?", arguments: [AgentKind.claudeCode.rawValue, path]) ?? -1 }
    }
    public nonisolated func reconciliationBenchmarkWrite(path: String) throws {
        try pool.write { db in try db.execute(sql: "UPDATE source_file SET mtime_ns=mtime_ns+1 WHERE agent=? AND path=?", arguments: [AgentKind.claudeCode.rawValue, path]) }
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
    if source.count(CACHE_ANCHOR) != (0 if layout == 'pr106' else 1):
        raise ValueError('Source does not match explicit layout: ' + layout)
    fallback = CONNECTION_ANCHOR if layout == 'connection-matcher' else FALLBACK_ANCHOR
    if BEGIN in source:
        if (source.count(value) != 1 or source.count(WRAPPED) != 1
                or source.count(FALLBACK_CALL) != 1
                or source.count(CLASSIFICATION_CALL) != (0 if layout == 'pr106' else 1)):
            raise ValueError('Conflicting reconciliation instrumentation')
        return source
    if 'reconciliationBenchmarkDecodedRows' in source or END in source:
        raise ValueError('Conflicting reconciliation instrumentation')
    anchor = '    private let pool: DatabasePool'
    for marker in (anchor, '    private var rollupFailures', fallback, EXPRESSION):
        if source.count(marker) != 1: raise ValueError('Missing unique reconciliation anchor: ' + marker)
    source = insert_call(source, fallback, FALLBACK_CALL)
    if layout != 'pr106': source = insert_call(source, CLASSIFICATION_ANCHOR, CLASSIFICATION_CALL)
    source = source.replace(EXPRESSION, WRAPPED, 1)
    return source.replace(anchor, value + anchor, 1)


def original_source(source, *, layout):
    if BEGIN not in source:
        return source
    # Validate the complete supported transformation before reversing it.
    instrument(source, layout=layout)
    source = source.replace(probe(layout), '', 1).replace(WRAPPED, EXPRESSION, 1)
    return re.sub(r'^[ \t]*self\.recordReconciliation(?:Fallback|Classification)\(\)\n', '', source, flags=re.MULTILINE)


def prepare(root, *, layout, allow_checkout=False):
    if (root / '.git').exists() and not allow_checkout:
        raise ValueError('Use an exported source tree, not a Git checkout')
    path = root / 'Sources/TraceCore/Database/IndexDatabase.swift'
    incoming = path.read_bytes()
    source = incoming.decode('utf-8')
    original = original_source(source, layout=layout)
    result = instrument(source, layout=layout)
    if result != source:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=path.parent, prefix=path.name+'.', suffix='.tmp', delete=False) as output:
                temporary = Path(output.name)
                output.write(result.encode('utf-8'))
            os.chmod(temporary, path.stat().st_mode & 0o777)
            temporary.replace(path)
        finally:
            if temporary is not None: temporary.unlink(missing_ok=True)
    return {'instrumentation': 'reconciliation-query-v3', 'layout': layout,
            'counterDefinitions': {'decodedRows': 'materialized IndexedSourcePath values, not rows visited or physical I/O',
                'fallbackQueries': 'executed fallback SELECT branches', 'classifications': 'cold or invalidated non-ASCII count queries',
                'functionRegistrations': 'installed reconciliation matchers including connection setup; legacy layouts install once per fallback query',
                'cacheRoots': 'retained root-count entries; zero for pr106, which has no count cache'},
            'sourceSHA256': hashlib.sha256(original.encode('utf-8')).hexdigest(),
            'inputSHA256': hashlib.sha256(incoming).hexdigest(),
            'instrumentedSHA256': hashlib.sha256(result.encode('utf-8')).hexdigest()}


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
