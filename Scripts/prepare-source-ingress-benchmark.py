#!/usr/bin/env python3
"""Extract the exact revision's mailbox for an isolated optimized workload."""
import argparse
from pathlib import Path


def swift_body(source, marker):
    if source.count(marker) != 1:
        raise ValueError('Missing unique normalization boundary')
    opening = source.index('{', source.index(marker))
    depth, closing = 1, opening + 1
    while depth:
        if closing == len(source):
            raise ValueError('Unclosed normalization boundary')
        depth += (source[closing] == '{') - (source[closing] == '}')
        closing += 1
    return source[opening + 1:closing - 1]


def extract(source, preparation_contract):
    if preparation_contract not in {'consumed-topology', 'preserved-topology'}:
        raise ValueError('Unsupported preparation contract')
    marker = 'final class SourceIngressMailbox: Sendable {'
    end_marker = '\n@MainActor\nenum ModelPublicationBatch'
    if source.count(marker) != 1 or source.count(end_marker) != 1:
        raise ValueError('Missing unique source-ingress boundaries')
    start = source.index(marker)
    end = source.index(end_marker, start)
    mailbox = source[start:end]
    common = r'''
@MainActor private enum IngressMeasurement {
    static let ledger = IndexCheckpointLedger()
    static let roots: [AgentKind: [TraceFileIO.CanonicalPath]] = [.claudeCode: [TraceFileIO.canonicalPath("/tmp/mailbox")]]
    static var preparationSeconds = 0.0, turns = 0, maxInputs = 0, enrollmentCalls = 0
    static func record(_ start: ContinuousClock.Instant, changes: SourceChanges) {
        let duration = start.duration(to: .now).components
        preparationSeconds += Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        turns += 1; maxInputs = max(maxInputs, changes.paths.count + changes.reconciliationPaths.count + changes.lexicalPaths.count + changes.structuralPaths.count)
        enrollmentCalls += changes.checkpointReservations.count
    }
}
@MainActor func benchmarkIngressMetrics() -> [String: Any] {
    ["mainActorPreparationElapsedSeconds": IngressMeasurement.preparationSeconds,
     "mainActorDeliveryTurns": IngressMeasurement.turns, "mainActorDeliveryMaxInputs": IngressMeasurement.maxInputs,
     "reservationDeliveryReferences": IngressMeasurement.enrollmentCalls,
     "ledgerState": IngressMeasurement.ledger.checkpointBenchmarkCounts,
     "prefixIndexEntryKind": IngressMeasurement.ledger.checkpointBenchmarkPrefixIndexEntryKind]
}
'''
    # Expected outputs describe the app preparation contract, not collector observations.
    preparation = swift_body(source, '    static func normalizeTranscript(' if 'struct Prepared: Sendable' in mailbox else '    private func normalizeTranscriptChanges(')
    keeps_auxiliary = preparation_contract == 'preserved-topology'
    common += '\n@MainActor func benchmarkIngressExpectedAuxiliaryCount(_ count: Int) -> Int { ' + ('count' if keeps_auxiliary else '0') + ' }\n'
    header = 'import Foundation\nimport os\nimport TraceCore\n\n' + mailbox + '\n' + common
    if 'struct Prepared: Sendable' in mailbox:
        wrapper = r'''
@MainActor func makeBenchmarkMailbox(_ receive: @escaping @MainActor @Sendable (SourceChanges) async -> Void, retired: @escaping @MainActor @Sendable () -> Void) -> SourceIngressMailbox {
    let roots = IngressMeasurement.roots
    _ = IngressMeasurement.ledger
    return SourceIngressMailbox(prepare: {
        SourceIngressMailbox.normalizeTranscript($0, rootsByAgent: roots, unavailableStreams: [])
    }, receivePrepared: { delivery in
        let start = ContinuousClock.now
        let changes = delivery.enrolled(in: IngressMeasurement.ledger)
        IngressMeasurement.record(start, changes: changes)
        await receive(changes); return TRANSFER
    }, retire: { _ in retired() })
}
'''.replace('TRANSFER', '.ordinaryTransferred' if 'enum Transfer:' in mailbox else 'true')
    else:
        body = preparation
        normalize = '\n@MainActor private func normalizeBenchmarkChanges(_ changes: SourceChanges) -> (changes: SourceChanges, recoveryEligible: Bool) {\n    let watcherRootsByAgent = IngressMeasurement.roots\n' + body + '\n}\n'
        parameters = 'raw, _, _' if 'struct ReplayPosition:' in mailbox else 'raw, _'
        wrapper = normalize + r'''
@MainActor func makeBenchmarkMailbox(_ receive: @escaping @MainActor @Sendable (SourceChanges) async -> Void, retired: @escaping @MainActor @Sendable () -> Void) -> SourceIngressMailbox {
    _ = IngressMeasurement.roots
    _ = IngressMeasurement.ledger
    return SourceIngressMailbox { PARAMETERS in
        let start = ContinuousClock.now
        var changes = normalizeBenchmarkChanges(raw).changes
        changes.checkpointReservations = [IngressMeasurement.ledger.reserve(watermarks: changes.watermarks,
            streamRoots: changes.streamRoots, hasIndexWork: changes.hasIndexWork,
            wrappedStreams: changes.wrappedStreams, paths: changes.paths,
            reconciliationPaths: changes.reconciliationPaths, streamEpochs: changes.streamEpochs)]
        IngressMeasurement.record(start, changes: changes)
        await receive(changes)
    }
}
'''.replace('PARAMETERS', parameters)
    return header + wrapper



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--preparation-contract', choices=['consumed-topology', 'preserved-topology'], required=True)
    args = parser.parse_args()
    source = (args.root / 'Sources/TraceApp/TraceModel.swift').read_text()
    args.output.write_text(extract(source, args.preparation_contract))


if __name__ == '__main__':
    main()
