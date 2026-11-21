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
    public func benchmarkCovers(_ name: String) -> Bool {
        covers(.init(agent: AgentKind.claudeCode.rawValue, root: "/tmp/navigation-cache",
            path: "/tmp/navigation-cache/" + name, externalSessionID: "fixture", anchorSourceKey: nil, anchorExternalID: nil))
    }
}
#endif
'''

HEADER = r'''import Foundation
import TraceCore
@MainActor private enum ModelPublicationBatch { static func perform(_ body: () -> Void) { body() } }
@MainActor final class PendingTargetWorkload {
    struct Intent { let reference: SessionNavigationReference? }
    final class Pending {
        let database: IndexDatabase, generation: IndexContentGeneration, sessionID: Int64, intent: Intent
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
    private func setRequestedMessage(_ id: Int64?) { pendingMessageRestore = nil; requestedMessageID = id }
    private func acceptTranscript(_ snapshot: SessionTranscriptSnapshot) -> Acceptance { .accepted }
    private func applyTranscript(_ snapshot: SessionTranscriptSnapshot) {
        publications += 1; selectedSession = snapshot.session; messages = snapshot.messages ?? []
    }
    private enum ReadOperation { case restoration }
    private func recordSummaryReadFailure(_ error: Error, operation: ReadOperation) { lookupErrors += 1 }
    var transcriptReadError: String?
    func run(_ count: Int) async { for _ in 0..<count { await restorePendingMessageIntent(event: UUID()) } }
'''


def prepare(root, output):
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
            raise ValueError('Conflicting navigation benchmark fixture')
    else:
        models.write_text(source + FACTORY)


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    prepare(a.root, a.output)
