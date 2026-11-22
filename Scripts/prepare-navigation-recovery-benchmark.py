#!/usr/bin/env python3
"""Prepare identical cache fixtures and the revision's exact pending resolver."""
import argparse
from pathlib import Path
import runpy

FACTORY = r'''
#if TRACE_CHECKPOINT_BENCHMARK
extension IndexNavigationCoverage {
    public static func benchmarkFixture(generation: IndexContentGeneration, names: [String], covered: Bool) -> Self {
        let root = SourceRoot(agent: .claudeCode, url: URL(fileURLWithPath: "/tmp/navigation-cache"))
        let context = root.mappingContext
        let facts = Dictionary(uniqueKeysWithValues: names.map {
            (RootRelativeScope(components: $0.isEmpty ? [] : [$0], caseSensitive: context.scanPath.isCaseSensitive), Fact(order: 0, covered: covered))
        })
        return .init(contentGeneration: generation, scope: .proseOnly, regions: [Region(root: root, context: context, facts: facts)])
    }
    public static func benchmarkSharedFixture(generation: IndexContentGeneration, names: [String], covered: Bool) -> Self {
        let roots = [AgentKind.claudeCode, .codex].map { SourceRoot(agent: $0, url: URL(fileURLWithPath: "/tmp/navigation-cache")) }
        let regions = roots.map { root in
            let context = root.mappingContext
            let facts = Dictionary(uniqueKeysWithValues: names.map {
                (RootRelativeScope(components: $0.isEmpty ? [] : [$0], caseSensitive: context.scanPath.isCaseSensitive), Fact(order: 0, covered: covered))
            })
            return Region(root: root, context: context, facts: facts)
        }
        return .init(contentGeneration: generation, scope: .proseOnly, regions: regions)
    }
    public func benchmarkReferences(_ name: String) -> [SessionNavigationReference] {
        regions.values.map { region in
            .init(agent: region.root.agent.rawValue, root: region.root.url.path,
                path: region.context.scanPath.path + "/" + name, externalSessionID: "fixture", anchorSourceKey: nil, anchorExternalID: nil)
        }
    }
    public func benchmarkCovers(_ name: String) -> Bool {
        guard let region = regions.values.first else { return false }
        return covers(.init(agent: region.root.agent.rawValue, root: region.root.url.path,
            path: region.context.scanPath.path + "/" + name, externalSessionID: "fixture", anchorSourceKey: nil, anchorExternalID: nil))
    }
}
#endif
'''

# Exact fixture shipped in the pinned #97 baseline; synchronization is explicit.
LEGACY_FACTORY = '\n#if TRACE_CHECKPOINT_BENCHMARK\nextension IndexNavigationCoverage {\n    public static func benchmarkFixture(generation: IndexContentGeneration, names: [String], covered: Bool) -> Self {\n        let root = SourceRoot(agent: .claudeCode, url: URL(fileURLWithPath: "/tmp/navigation-cache"))\n        let context = root.mappingContext\n        let facts = Dictionary(uniqueKeysWithValues: names.map {\n            (RootRelativeScope(components: $0.isEmpty ? [] : [$0], caseSensitive: context.scanPath.isCaseSensitive), Fact(order: 0, covered: covered))\n        })\n        return .init(contentGeneration: generation, scope: .proseOnly, regions: [Region(root: root, context: context, facts: facts)])\n    }\n    public func benchmarkCovers(_ name: String) -> Bool {\n        guard let region = regions.values.first else { return false }\n        return covers(.init(agent: region.root.agent.rawValue, root: region.root.url.path,\n            path: region.context.scanPath.path + "/" + name, externalSessionID: "fixture", anchorSourceKey: nil, anchorExternalID: nil))\n    }\n}\n#endif\n'

HEADER = r'''import Foundation
import TraceCore
@MainActor private enum ModelPublicationBatch { static func perform(_ body: () -> Void) { body() } }
@MainActor final class PendingTargetWorkload {
    struct Intent { let reference: SessionNavigationReference? }
    final class Pending {
        let database: IndexDatabase, generation: IndexContentGeneration, sessionID: Int64
        var intent: Intent
        var running = false, lastEvent: UUID?, demand: UInt64 = 0
        init(database: IndexDatabase, sessionID: Int64, reference: SessionNavigationReference) {
            self.database = database; self.generation = database.contentGeneration
            self.sessionID = sessionID; intent = .init(reference: reference)
        }
    }
    struct Workflow { let isActive = false }
    enum Acceptance { case accepted }
    var pendingMessageRestore: Pending?
    let attachmentGeneration = UUID(), sourceConfigurationRevision = 0, indexWorkflow = Workflow()
    var selectedSession: SessionSummary?, messages: [MessageSummary]
    var requestedMessageID: Int64?, requestedMessageReference: SessionNavigationReference?, scrollRequest = UUID()
    var snapshotReads = 0, publications = 0, lookupErrors = 0
    init(database: IndexDatabase, snapshot: SessionTranscriptSnapshot, reference: SessionNavigationReference) {
        selectedSession = snapshot.session; messages = snapshot.messages ?? []
        pendingMessageRestore = Pending(database: database, sessionID: snapshot.session!.id, reference: reference)
    }
    private func pendingMessageIsCurrent(_ pending: Pending) -> Bool {
        pendingMessageRestore === pending && pending.generation == pending.database.contentGeneration
    }
    // This workload deliberately keeps absence provisional, as an incomplete
    // source does in the app. The production resolver and coherent-read predicate
    // below are extracted without rewriting their control flow.
    private func navigationSourceCovered(_ reference: SessionNavigationReference?, database: IndexDatabase) -> Bool { false }
    private func refreshNavigationReference(sessionID: Int64, current: SessionNavigationReference) {
        // Relocation itself is exercised by App regressions. This steady-source
        // workload uses the same accepted-reference update if its fixture moves.
        pendingMessageRestore?.intent = .init(reference: current)
        requestedMessageReference = current
    }
    private func setRequestedMessage(_ id: Int64?) { pendingMessageRestore = nil; requestedMessageID = id }
    private func acceptTranscript(_ snapshot: SessionTranscriptSnapshot) -> Acceptance { .accepted }
    private func applyTranscript(_ snapshot: SessionTranscriptSnapshot) {
        publications += 1; selectedSession = snapshot.session; messages = snapshot.messages ?? []
    }
    private enum ReadOperation { case restoration }
    private func recordSummaryReadFailure(_ error: Error, operation: ReadOperation) { lookupErrors += 1 }
    var transcriptReadError: String?
    struct TranscriptState { var targetLookupFailed = false }
    private struct StateStore {
        var value = TranscriptState()
        func read<T>(_ key: KeyPath<TranscriptState, T>) -> T { value[keyPath: key] }
    }
    private var transcriptState = StateStore()
    private func updateTranscript(_ body: (inout TranscriptState) -> Void) { body(&transcriptState.value) }
    func run(_ count: Int) async { for _ in 0..<count { await restorePendingMessageIntent(event: UUID()) } }
'''


def prepare(root, output, *, synchronize_existing=False):
    helpers = runpy.run_path(str(Path(__file__).with_name('prepare-source-ingress-benchmark.py')))
    model = (root / 'Sources/TraceApp/TraceModel.swift').read_text()
    body = helpers['swift_body'](model, '    private func restorePendingMessageIntent(event: UUID) async')
    anchor = 'let snapshot = try await pending.database.transcriptSnapshot'
    if body.count(anchor) != 1:
        raise ValueError('Missing unique target snapshot boundary')
    body = body.replace(anchor, 'snapshotReads += 1\n            ' + anchor)
    output.write_text(HEADER + '\n    private func restorePendingMessageIntent(event: UUID) async {' + body + '\n    }\n}\n')
    models = root / 'Sources/TraceCore/Models.swift'
    source = models.read_text()
    if 'public static func benchmarkFixture(' in source:
        if source.count(FACTORY) != 1:
            if synchronize_existing and source.count(LEGACY_FACTORY) == 1:
                source = source.replace(LEGACY_FACTORY, FACTORY, 1)
            else:
                raise ValueError('Conflicting navigation benchmark fixture; supported legacy fixtures require --synchronize-existing')
    else:
        source += FACTORY
    adapter_marker = "// TRACE_NAVIGATION_LEDGER_WORKLOAD_V2"
    if "// TRACE_NAVIGATION_LEDGER_WORKLOAD_" in source and adapter_marker not in source:
        raise ValueError("Conflicting navigation ledger workload instrumentation")
    modern = "private final class NavigationAdmissions:" in source
    legacy = "var required = NavigationScopeIndex()" in source
    if not modern and not legacy:
        raise ValueError("Unsupported navigation ledger workload layout")
    finish = "IndexNavigationWork.finish(executions)" if modern else ""
    admission = ("let inputs = IndexNavigationInputs(canonicalPaths: paths, canonicalReconciliationPaths: [])\n"
                 "        return { self.reserve(inputs) }" if modern else
                 "return { self.reserve(canonicalPaths: paths, canonicalReconciliationPaths: []) }")
    adapter = "\n#if TRACE_CHECKPOINT_BENCHMARK\n" + adapter_marker + "\n" + "extension IndexNavigationWorkLedger {\n" + \
        "    public func benchmarkAdmission(_ paths: Set<TraceFileIO.CanonicalPath>) -> @Sendable () -> [IndexNavigationWork] {\n        " + admission + "\n    }\n" + \
        "    public func benchmarkObserve(_ coverage: IndexNavigationCoverage, work: [IndexNavigationWork]) {\n" + \
        "        let executions = IndexNavigationWork.begin(work)\n" + \
        "        let stamp = CheckpointAcceptanceBenchmark.begin()\n" + \
        "        IndexNavigationWork.observe(coverage, executions: executions)\n" + \
        "        " + finish + "\n        CheckpointAcceptanceBenchmark.end(stamp)\n    }\n}\n" + \
        "extension IndexNavigationCoverage {\n" + \
        "    public func benchmarkReference(_ name: String) -> SessionNavigationReference {\n" + \
        "        let region = regions.values.first!\n" + \
        "        return .init(agent: region.root.agent.rawValue, root: region.root.url.path,\n" + \
        "            path: region.context.scanPath.path + \"/\" + name, externalSessionID: \"fixture\", anchorSourceKey: nil, anchorExternalID: nil)\n    }\n}\n#endif\n"
    if adapter_marker in source:
        if source.count(adapter_marker) != 1 or source.count(adapter) != 1:
            raise ValueError("Conflicting navigation ledger workload instrumentation")
    else:
        source += adapter
    models.write_text(source)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--synchronize-existing', action='store_true')
    a = p.parse_args()
    prepare(a.root, a.output, synchronize_existing=a.synchronize_existing)
