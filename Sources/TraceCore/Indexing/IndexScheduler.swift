import Clocks
import Foundation
import os

// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT
#if TRACE_CHECKPOINT_BENCHMARK
import Darwin
/// Enabled only in synchronized local benchmark builds. Control handshakes
/// occur outside these instrumented execution intervals.
public enum CheckpointAcceptanceBenchmark {
    struct Stamp { let start: ContinuousClock.Instant; let cpu: Double }
    private struct Samples { var elapsed = 0.0; var cpu = 0.0; var calls = 0 }
    private static let samples = OSAllocatedUnfairLock(initialState: Samples())
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func begin() -> Stamp { .init(start: .now, cpu: cpuSeconds()) }
    static func end(_ stamp: Stamp) {
        let duration = stamp.start.duration(to: .now).components
        let cpu = cpuSeconds() - stamp.cpu
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        samples.withLock { $0.elapsed += elapsed; $0.cpu += cpu; $0.calls += 1 }
    }
    public static func reset() { samples.withLock { $0 = Samples() } }
    public static func snapshot() -> [String: Double] {
        samples.withLock { ["elapsedSeconds": $0.elapsed, "cpuSeconds": $0.cpu, "acceptanceTurns": Double($0.calls)] }
    }
}
#endif
// END CHECKPOINT ACCEPTANCE MEASUREMENT

/// Durable checkpoint value with stream-epoch qualification. Values are created
/// by database reads or accepted ledger coverage, never by presentation code.
public struct IndexEventCheckpoint: Sendable {
    public let value: UInt64
    let epoch: String
    let replacingEpochs: Set<String>
    var contentGeneration: IndexContentGeneration? = nil
}

/// An opaque obligation enrolled before an asynchronous handoff can delay work.
public struct IndexCheckpointReservation: Sendable {
    fileprivate struct Entry: Sendable {
        let id: UUID
        let stream: String
        let epoch: String
        let version: UInt64
        let watermark: UInt64
        let roots: Set<TraceFileIO.CanonicalPath>
    }
    fileprivate let ledger: UUID
    fileprivate let entries: [Entry]

    static func coalesced(_ reservations: [Self]) -> [Self] {
        var ledgers: [UUID: [UUID: Entry]] = [:]
        for reservation in reservations {
            for entry in reservation.entries where ledgers[reservation.ledger]?[entry.id].map({ $0.version < entry.version }) ?? true {
                ledgers[reservation.ledger, default: [:]][entry.id] = entry
            }
        }
        return ledgers.map { .init(ledger: $0.key, entries: Array($0.value.values)) }
    }
}

fileprivate struct IndexWorkRequirement: Sendable {
    var paths: Set<TraceFileIO.CanonicalPath> = []
    var reconciliation: Set<TraceFileIO.CanonicalPath> = []
    var fullScan = false
    var unknownWork = false
    var roots: Set<TraceFileIO.CanonicalPath> = []

    func covered(paths changed: Set<TraceFileIO.CanonicalPath>, reconciliation scanned: Set<TraceFileIO.CanonicalPath>,
                 fullScan: Bool, failures: Set<TraceFileIO.CanonicalPath>) -> Bool {
        let relevantFailures = failures.filter { failure in roots.isEmpty || roots.contains { $0.intersects(failure) } }
        if !relevantFailures.isEmpty {
            let required = paths.union(reconciliation)
            if required.isEmpty || required.contains(where: { input in relevantFailures.contains { $0.intersects(input) } }) { return false }
        }
        if fullScan { return true }
        guard !self.fullScan, !unknownWork else { return false }
        return paths.allSatisfy { input in changed.contains(input) || scanned.contains(where: { $0.contains(input) }) }
            && reconciliation.allSatisfy { input in scanned.contains { $0.contains(input) } }
    }

    func remaining(paths changed: Set<TraceFileIO.CanonicalPath>, reconciliation scanned: Set<TraceFileIO.CanonicalPath>,
                   fullScan: Bool, fileFailures: Set<TraceFileIO.CanonicalPath>,
                   reconciliationFailures: Set<TraceFileIO.CanonicalPath>) -> Self? {
        let failures = fileFailures.union(reconciliationFailures)
        if covered(paths: changed, reconciliation: scanned, fullScan: fullScan, failures: failures) { return nil }
        var next = self
        let attempted = paths.filter { input in fullScan || changed.contains(input) || scanned.contains { $0.contains(input) } }
        let attemptedRoots = reconciliation.filter { input in fullScan || scanned.contains { $0.contains(input) } }
        next.paths.subtract(attempted.filter { input in !failures.contains { $0.intersects(input) } })
        next.reconciliation.subtract(attemptedRoots.filter { input in !reconciliationFailures.contains { $0.intersects(input) } })
        if fullScan { next.fullScan = false; next.unknownWork = false }
        if fullScan || !attemptedRoots.isEmpty {
            let scope = paths.union(reconciliation).union(roots)
            let relevant: (TraceFileIO.CanonicalPath) -> Bool = { failure in
                scope.isEmpty || scope.contains { $0.intersects(failure) }
            }
            next.paths.formUnion(fileFailures.filter(relevant))
            next.reconciliation.formUnion(reconciliationFailures.filter(relevant))
        }
        return next
    }

}

/// Database-owned obligations and completed execution proofs. No scheduler or
/// callback is retained. Mutable containers never escape the ingress lock.
public final class IndexCheckpointLedger: Sendable {
    fileprivate typealias Entry = IndexCheckpointReservation.Entry
    private struct Stamp: Sendable {
        let sequence: UInt64
        let paths: Set<TraceFileIO.CanonicalPath>
        let reconciliation: Set<TraceFileIO.CanonicalPath>
        let fullScan: Bool
        func covers(_ path: TraceFileIO.CanonicalPath, root: Bool = false) -> Bool {
            fullScan || reconciliation.contains { $0.contains(path) } || (!root && paths.contains(path))
        }
    }
    private final class Record: @unchecked Sendable {
        var entry: Entry
        var remaining: IndexWorkRequirement
        var stamps: [Stamp] = []
        weak var previous: Record?
        var next: Record?
        var covered: Bool { !remaining.fullScan && !remaining.unknownWork && remaining.paths.isEmpty && remaining.reconciliation.isEmpty }
        init(entry: Entry, remaining: IndexWorkRequirement) { self.entry = entry; self.remaining = remaining }
    }
    private struct Mark {
        let value: UInt64
        let id: UUID
    }
    /// Lazy deletion permits O(log n) qualification changes without rebuilding
    /// or copying the record dictionary on event ingress.
    private struct Marks {
        var values: [Mark] = []
        private var positions: [UUID: Int] = [:]
        mutating func insert(_ mark: Mark) {
            let index: Int
            if let current = positions[mark.id] { index = current; values[index] = mark }
            else { index = values.count; values.append(mark); positions[mark.id] = index }
            sift(index)
        }
        private mutating func swap(_ a: Int, _ b: Int) {
            values.swapAt(a, b); positions[values[a].id] = a; positions[values[b].id] = b
        }
        private mutating func sift(_ start: Int) {
            var i = start
            while i > 0 {
                let parent = (i - 1) / 2
                guard values[i].value < values[parent].value else { break }
                swap(i, parent); i = parent
            }
            while i * 2 + 1 < values.count {
                var child = i * 2 + 1
                if child + 1 < values.count && values[child + 1].value < values[child].value { child += 1 }
                guard values[child].value < values[i].value else { break }
                swap(i, child); i = child
            }
        }
        mutating func pop() -> Mark? {
            guard let first = values.first else { return nil }
            let last = values.removeLast(); positions[first.id] = nil
            if !values.isEmpty { values[0] = last; positions[last.id] = 0; sift(0) }
            return first
        }
    }
    private final class Stream {
        var epoch = ""
        var predecessors: Set<String> = []
        var floor: UInt64?
        var roots: Set<TraceFileIO.CanonicalPath> = []
        var records: [UUID: Record] = [:]
        var unpaid = Marks()
        var paid = Marks()
        var tail: UUID?
        var initialized = false
        var initializationFailed = false
        var ingressEpoch: IndexEventStreamEpoch?
    }
    fileprivate struct Coverage: Sendable {
        let entries: [Entry]
        let owner: UUID
        let revision: UInt64
        let sequence: UInt64
    }
    fileprivate struct ExecutionProof: Sendable {
        let coverage: Coverage
        let paths: Set<TraceFileIO.CanonicalPath>
        let reconciliation: Set<TraceFileIO.CanonicalPath>
        let failures: Set<TraceFileIO.CanonicalPath>
        let reconciliationFailures: Set<TraceFileIO.CanonicalPath>
        let fullScan: Bool
        let content: IndexContentGeneration?
        let scope: IndexScope
        var activity: IndexActivity = .fileChanges
    }
    private final class ProofCursor {
        let proof: ExecutionProof
        var offset = 0
        init(_ proof: ExecutionProof) { self.proof = proof }
    }
    private struct State: @unchecked Sendable {
        var streams: [String: Stream] = [:]
        var revision: UInt64 = 0
        var sequence: UInt64 = 0
        var proofs: [ProofCursor] = []
        var proofIDs: Set<UInt64> = []
        var processing = false
        var fences: Set<UUID> = []
        var updates: [String: IndexEventCheckpoint] = [:]
        var content: IndexContentGeneration?
        var publicationActivity: IndexActivity = .fileChanges
        var lastPublicationActivity: IndexActivity = .fileChanges
        var prefixStreams: Set<String> = []
        var head: Record?
        var tail: Record?
    }
    #if DEBUG
    private let acceptanceCommitHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    func setAcceptanceCommitHookForTesting(_ hook: (@Sendable () -> Void)?) { acceptanceCommitHook.withLock { $0 = hook } }
    #endif
    private let id = UUID()
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}

    public func seed(stream name: String, checkpoint: IndexEventCheckpoint?) {
        state.withLock { value in
            let stream = value.streams[name] ?? Stream()
            guard !stream.initialized else { return }
            if stream.predecessors.isEmpty {
                stream.epoch = checkpoint?.epoch ?? UUID().uuidString
                stream.predecessors = checkpoint == nil ? ["legacy"] : []
                stream.floor = checkpoint?.value
            } else {
                stream.epoch = UUID().uuidString
                stream.predecessors = [checkpoint?.epoch ?? "legacy"]
            }
            if value.content == nil { value.content = checkpoint?.contentGeneration }
            stream.initialized = true; stream.initializationFailed = false
            value.streams[name] = stream
            value.prefixStreams.insert(name)
        }
    }
    fileprivate var uninitializedStreams: Set<String> {
        state.withLock { Set($0.streams.filter { !$0.value.initialized && !$0.value.initializationFailed }.keys) }
    }
    fileprivate var pausedStreams: Set<String> { state.withLock { Set($0.streams.filter { $0.value.initializationFailed }.keys) } }
    fileprivate func resumeInitialization() { state.withLock { value in for stream in value.streams.values { stream.initializationFailed = false } } }
    fileprivate func pauseInitialization(_ stream: String) { state.withLock { $0.streams[stream]?.initializationFailed = true } }
    #if DEBUG
    func initializationForTesting(stream: String) -> (initialized: Bool, epoch: String?, floor: UInt64?) {
        state.withLock { let item = $0.streams[stream]; return (item?.initialized == true, item?.initialized == true ? item?.epoch : nil, item?.floor) }
    }
    struct ProofForTesting: Sendable { fileprivate let value: ExecutionProof }
    func prepareProofForTesting(_ reservations: [IndexCheckpointReservation], paths: Set<String> = [],
                               reconciliation: Set<String> = [], failures: Set<String> = [],
                               fullScan: Bool = false, content: IndexContentGeneration) -> ProofForTesting {
        .init(value: .init(coverage: begin(entries(reservations), owner: UUID()),
            paths: Set(paths.map(TraceFileIO.canonicalPath)), reconciliation: Set(reconciliation.map(TraceFileIO.canonicalPath)),
            failures: Set(failures.map(TraceFileIO.canonicalPath)), reconciliationFailures: [], fullScan: fullScan,
            content: content, scope: .proseOnly))
    }
    func retainProofForTesting(_ proof: ProofForTesting) { retain(proof.value) }
    func drainProofsForTesting(content: IndexContentGeneration) -> [String: IndexEventCheckpoint] {
        var updates: [String: IndexEventCheckpoint] = [:]
        for _ in 0..<1_000 {
            if !hasReadyProofs { break }
            updates.merge(drainProofs(scope: .proseOnly, content: content), uniquingKeysWith: { _, last in last })
        }
        return updates
    }
    func remainingPathsForTesting(_ reservations: [IndexCheckpointReservation]) -> Set<String> {
        Set(requirements(entries(reservations)).flatMap { $0.paths.map(\.path) })
    }
    var retainedProofCountForTesting: Int { state.withLock { $0.proofs.count } }
    #endif

    public func reserve(watermarks: [String: UInt64], streamRoots: [String: Set<String>],
                        hasIndexWork: Bool, wrappedStreams: Set<String> = [],
                        paths: Set<String> = [], reconciliationPaths: Set<String> = []) -> IndexCheckpointReservation {
        reserve(watermarks: watermarks, streamRoots: streamRoots, hasIndexWork: hasIndexWork,
            wrappedStreams: wrappedStreams, paths: paths, reconciliationPaths: reconciliationPaths, streamEpochs: [:])
    }
    public func reserve(watermarks: [String: UInt64], streamRoots: [String: Set<String>],
                        hasIndexWork: Bool, wrappedStreams: Set<String> = [],
                        paths: Set<String> = [], reconciliationPaths: Set<String> = [],
                        streamEpochs: [String: IndexEventStreamEpoch]) -> IndexCheckpointReservation {
        let inputs = Set(paths.map(TraceFileIO.canonicalPath))
        let reconciliation = Set(reconciliationPaths.map(TraceFileIO.canonicalPath))
        let roots = streamRoots.mapValues { Set($0.map(TraceFileIO.canonicalPath)) }
        return state.withLock { value in
            var entries: [Entry] = []
            for (name, mark) in watermarks {
                let stream = value.streams[name] ?? Stream()
                value.streams[name] = stream
                let incoming = streamEpochs[name]
                if let incoming, stream.ingressEpoch?.predecessors.contains(incoming.id) == true { continue }
                let same = incoming != nil && incoming == stream.ingressEpoch
                let descends = incoming.map { next in stream.ingressEpoch.map { next.predecessors.contains($0.id) } ?? !next.predecessors.isEmpty } ?? false
                // Unrelated watcher lineages cannot replace a known epoch merely
                // because they wrapped sometime in their own history.
                let wrap = descends || (wrappedStreams.contains(name) && !same)
                if wrap {
                    stream.predecessors.insert(stream.epoch.isEmpty ? "legacy" : stream.epoch)
                    stream.epoch = stream.initialized ? UUID().uuidString : ""
                    stream.floor = nil
                    for record in stream.records.values { Self.unlink(record, state: &value) }
                    stream.records.removeAll(); stream.tail = nil
                    stream.paid = Marks(); stream.unpaid = Marks()
                    value.updates[name] = nil
                }
                if let incoming { stream.ingressEpoch = incoming }
                let qualification = roots[name] ?? []
                stream.roots.formUnion(qualification)
                // Qualification grows independently of immutable work. In-flight
                // executions keep the same obligation and covered work stays paid.
                if !hasIndexWork, !wrap, let tail = stream.tail, let previous = stream.records[tail] {
                    previous.entry = .init(id: tail, stream: name, epoch: stream.epoch, version: previous.entry.version,
                        watermark: max(mark, previous.entry.watermark), roots: previous.entry.roots.union(qualification))
                    if previous.covered { stream.paid.insert(.init(value: previous.entry.watermark, id: tail)) }
                    else { stream.unpaid.insert(.init(value: previous.entry.watermark, id: tail)) }
                    entries.append(previous.entry)
                    value.prefixStreams.insert(name)
                    continue
                }
                let key = UUID()
                let entry = Entry(id: key, stream: name, epoch: stream.epoch, version: 1, watermark: mark, roots: qualification)
                let scopedPaths = inputs.filter { input in qualification.isEmpty || qualification.contains { $0.intersects(input) } }
                let scopedRoots = reconciliation.filter { input in qualification.isEmpty || qualification.contains { $0.intersects(input) } }
                let unspecified = hasIndexWork && inputs.isEmpty && reconciliation.isEmpty
                let requirement = IndexWorkRequirement(paths: scopedPaths,
                    reconciliation: scopedRoots.union((wrap || wrappedStreams.contains(name)) ? stream.roots : []),
                    fullScan: unspecified && !wrap && !wrappedStreams.contains(name),
                    unknownWork: (wrap || wrappedStreams.contains(name)) && stream.roots.isEmpty, roots: qualification)
                let record = Record(entry: entry, remaining: requirement)
                stream.records[key] = record
                record.previous = value.tail
                value.tail?.next = record
                if value.head == nil { value.head = record }
                value.tail = record
                stream.tail = hasIndexWork ? nil : key
                if record.covered { stream.paid.insert(.init(value: mark, id: key)) }
                else { stream.unpaid.insert(.init(value: mark, id: key)) }
                entries.append(entry)
                value.prefixStreams.insert(name)
            }
            return .init(ledger: id, entries: entries)
        }
    }
    fileprivate func entries(_ reservations: [IndexCheckpointReservation]) -> [Entry] {
        let supplied = reservations.filter { $0.ledger == id }.flatMap(\.entries)
        return state.withLock { value in supplied.compactMap { value.streams[$0.stream]?.records[$0.id]?.entry } }
    }
    fileprivate func requirements(_ entries: [Entry]) -> [IndexWorkRequirement] {
        state.withLock { value in entries.compactMap { value.streams[$0.stream]?.records[$0.id]?.remaining } }
    }
    fileprivate func metadataOnlyEntries(_ entries: [Entry]) -> [Entry] {
        state.withLock { value in entries.compactMap { entry in
            guard let record = value.streams[entry.stream]?.records[entry.id], record.covered else { return nil }
            return record.entry
        } }
    }
    fileprivate func fenceReset(_ token: UUID) { state.withLock { $0.fences.insert(token) } }
    fileprivate func releaseReset(_ token: UUID) { state.withLock { $0.fences.remove(token) } }
    /// Called synchronously from the database's committed-reset callback.
    fileprivate func committedReset(content: IndexContentGeneration, extending coverage: Coverage) -> Coverage {
        state.withLock { value in
            Self.resetRecords(content: content, state: &value)
            // The scan begins after commitment: include every obligation that
            // arrived before that boundary, including ingress during preparation.
            value.sequence &+= 1
            return Coverage(entries: value.streams.values.flatMap { $0.records.values.map(\.entry) },
                owner: coverage.owner, revision: value.revision, sequence: value.sequence)
        }
    }
    private static func resetRecords(content: IndexContentGeneration, state value: inout State) {
        value.revision &+= 1; value.content = content
        value.proofs.removeAll(); value.proofIDs.removeAll(); value.updates.removeAll()
        for (name, stream) in value.streams {
            stream.paid = Marks(); stream.unpaid = Marks()
            // clearIndex deletes durable checkpoints too. Preserve their last
            // qualification as reset-owned debt even when no records remained.
            if let floor = stream.floor {
                let key = UUID(), roots = stream.roots
                let entry = Entry(id: key, stream: name, epoch: stream.epoch, version: 1, watermark: floor, roots: roots)
                let record = Record(entry: entry, remaining: .init(reconciliation: roots, fullScan: roots.isEmpty, roots: roots))
                stream.records[key] = record
                record.previous = value.tail; value.tail?.next = record
                if value.head == nil { value.head = record }
                value.tail = record
            }
            stream.floor = nil
            for record in stream.records.values {
                let roots = record.entry.roots.union(stream.roots)
                record.remaining.reconciliation.formUnion(roots)
                if roots.isEmpty { record.remaining.fullScan = true }
                record.stamps.removeAll()
                stream.unpaid.insert(.init(value: record.entry.watermark, id: record.entry.id))
            }
            value.prefixStreams.insert(name)
        }
    }
    fileprivate func synchronizeContext(content: IndexContentGeneration) {
        state.withLock { value in
            if let prior = value.content, prior != content { Self.resetRecords(content: content, state: &value) }
            else { value.content = content }
        }
    }
    fileprivate func coverableEntries(paths changedPaths: Set<String>, reconciliationPaths: Set<String>, fullScan: Bool) -> [Entry] {
        let changed = Set(changedPaths.map(TraceFileIO.canonicalPath)), scanned = Set(reconciliationPaths.map(TraceFileIO.canonicalPath))
        // Capture bounded descriptor chunks. Ingress never copies a shared
        // record dictionary and never waits on a whole-ledger scan or sort.
        let endpoints = state.withLock { ($0.head, $0.tail) }
        var cursor = endpoints.0
        var result: [Entry] = []
        while cursor != nil {
            let start = cursor
            let chunk = state.withLock { value -> ([(Entry, IndexWorkRequirement)], Record?) in
                var descriptors: [(Entry, IndexWorkRequirement)] = []
                var node = start
                while let current = node, descriptors.count < 128 {
                    if value.streams[current.entry.stream]?.records[current.entry.id] === current {
                        descriptors.append((current.entry, current.remaining))
                    }
                    node = current === endpoints.1 ? nil : current.next
                    if current === endpoints.1 { break }
                }
                return (descriptors, node)
            }
            for (entry, required) in chunk.0 {
                if fullScan || required.covered(paths: changed, reconciliation: scanned, fullScan: false, failures: []) {
                    result.append(entry); continue
                }
                let inputs = required.paths.union(required.reconciliation).union(required.roots)
                if inputs.contains(where: { root in changed.contains { root.intersects($0) } || scanned.contains { root.intersects($0) } }) { result.append(entry) }
            }
            cursor = chunk.1
        }
        return result
    }
    private static func unlink(_ record: Record, state: inout State) {
        record.previous?.next = record.next
        record.next?.previous = record.previous
        if state.head === record { state.head = record.next }
        if state.tail === record { state.tail = record.previous }
        // Preserve next for a worker already traversing this retired node.
        record.previous = nil
    }
    fileprivate func begin(_ entries: [Entry], owner: UUID) -> Coverage {
        state.withLock { value in
            value.sequence &+= 1
            return .init(entries: entries.filter { value.streams[$0.stream]?.records[$0.id] != nil },
                owner: owner, revision: value.revision, sequence: value.sequence)
        }
    }
    fileprivate func retain(_ proof: ExecutionProof) {
        state.withLock { value in
            guard proof.coverage.revision == value.revision, value.proofIDs.insert(proof.coverage.sequence).inserted else { return }
            value.proofs.append(ProofCursor(proof))
        }
    }
    fileprivate var lastPublicationActivity: IndexActivity { state.withLock { $0.lastPublicationActivity } }
    fileprivate var hasCompletedProofs: Bool { state.withLock { !$0.proofs.isEmpty } }
    fileprivate var hasReadyProofs: Bool {
        state.withLock { value in
            !value.proofs.isEmpty || (value.fences.isEmpty && (!value.updates.isEmpty || value.prefixStreams.contains { value.streams[$0]?.initialized == true }))
        }
    }
    /// One bounded worker turn. Reentrant ingress never invalidates unrelated
    /// computation. Only reset/epoch retirement can discard the captured records.
    fileprivate func drainProofs(scope: IndexScope, content: IndexContentGeneration) -> [String: IndexEventCheckpoint] {
        synchronizeContext(content: content)
        #if TRACE_CHECKPOINT_BENCHMARK
        let measurement = CheckpointAcceptanceBenchmark.begin()
        defer { CheckpointAcceptanceBenchmark.end(measurement) }
        #endif
        struct Item { let entry: Entry; let remaining: IndexWorkRequirement; let stamps: [Stamp] }
        let work: (ExecutionProof, [Item])? = state.withLock { value in
            guard !value.processing, let cursor = value.proofs.first else { return nil }
            let proof = cursor.proof
            guard proof.coverage.revision == value.revision, proof.scope == scope,
                  proof.content == nil || proof.content == content else {
                value.proofs.removeFirst(); value.proofIDs.remove(proof.coverage.sequence); return nil
            }
            value.processing = true
            value.publicationActivity = IndexActivity.moreSignificant(value.publicationActivity, proof.activity)
            let end = min(cursor.offset + 128, proof.coverage.entries.count)
            let items = proof.coverage.entries[cursor.offset..<end].compactMap { entry -> Item? in
                guard let record = value.streams[entry.stream]?.records[entry.id] else { return nil }
                return .init(entry: entry, remaining: record.remaining, stamps: record.stamps)
            }
            cursor.offset = end
            return (proof, items)
        }
        if let (proof, items) = work {
            let stamp = Stamp(sequence: proof.coverage.sequence, paths: proof.paths, reconciliation: proof.reconciliation, fullScan: proof.fullScan)
            let allFailures = proof.failures.union(proof.reconciliationFailures)
            let results = items.map { item -> (Entry, IndexWorkRequirement, [Stamp]) in
                var remaining = item.remaining
                if !remaining.fullScan, !remaining.unknownWork, remaining.paths.isEmpty, remaining.reconciliation.isEmpty {
                    return (item.entry, remaining, item.stamps)
                }
                func newer(_ path: TraceFileIO.CanonicalPath, root: Bool = false) -> Bool {
                    item.stamps.contains { $0.sequence > stamp.sequence && $0.covers(path, root: root) }
                }
                remaining.paths = remaining.paths.filter { input in
                    newer(input) || !stamp.covers(input) || allFailures.contains { $0.intersects(input) }
                }
                remaining.reconciliation = remaining.reconciliation.filter { input in
                    newer(input, root: true) || !stamp.covers(input, root: true) || proof.reconciliationFailures.contains { $0.intersects(input) }
                }
                if proof.fullScan, !item.stamps.contains(where: { $0.sequence > stamp.sequence && $0.fullScan }) {
                    remaining.fullScan = false; remaining.unknownWork = false
                }
                if proof.fullScan || !proof.reconciliation.isEmpty {
                    let scope = item.remaining.roots.union(item.remaining.paths).union(item.remaining.reconciliation)
                    func relevant(_ failure: TraceFileIO.CanonicalPath) -> Bool {
                        !newer(failure) && stamp.covers(failure) && (scope.isEmpty || scope.contains { $0.intersects(failure) })
                    }
                    remaining.paths.formUnion(proof.failures.filter(relevant))
                    remaining.reconciliation.formUnion(proof.reconciliationFailures.filter(relevant))
                }
                // Newer full scans subsume earlier stamps; other stamps remain
                // until this obligation is paid and removed from the prefix.
                var stamps = item.stamps.filter { !(proof.fullScan && $0.sequence < stamp.sequence) }
                if !stamps.contains(where: { $0.sequence == stamp.sequence }) { stamps.append(stamp) }
                return (item.entry, remaining, stamps)
            }
            #if DEBUG
            acceptanceCommitHook.withLock { $0 }?()
            #endif
            state.withLock { value in
                defer { value.processing = false }
                guard proof.coverage.revision == value.revision else { return }
                for (entry, remaining, stamps) in results {
                    guard let stream = value.streams[entry.stream], let record = stream.records[entry.id] else { continue }
                    record.remaining = remaining; record.stamps = stamps
                    if record.covered { stream.paid.insert(.init(value: record.entry.watermark, id: record.entry.id)) }
                    else { stream.unpaid.insert(.init(value: record.entry.watermark, id: record.entry.id)) }
                    value.prefixStreams.insert(entry.stream)
                }
                if let cursor = value.proofs.first, cursor.proof.coverage.sequence == proof.coverage.sequence,
                   cursor.offset == proof.coverage.entries.count {
                    value.proofs.removeFirst(); value.proofIDs.remove(proof.coverage.sequence)
                }
            }
        }
        return state.withLock { value in
            guard value.fences.isEmpty else { return [:] }
            var budget = 128
            for name in Array(value.prefixStreams) where budget > 0 {
                guard let stream = value.streams[name], stream.initialized else { continue }
                while let first = stream.unpaid.values.first,
                      stream.records[first.id].map({ $0.covered || $0.entry.watermark != first.value }) ?? true {
                    _ = stream.unpaid.pop()
                }
                while budget > 0, let first = stream.paid.values.first {
                    guard let record = stream.records[first.id], record.covered, record.entry.watermark == first.value else {
                        _ = stream.paid.pop(); continue
                    }
                    if let barrier = stream.unpaid.values.first?.value, first.value >= barrier { break }
                    _ = stream.paid.pop(); Self.unlink(record, state: &value); stream.records.removeValue(forKey: first.id)
                    if stream.tail == first.id { stream.tail = nil }
                    if stream.floor == nil || first.value > stream.floor! {
                        stream.floor = first.value
                        value.updates[name] = .init(value: first.value, epoch: stream.epoch,
                            replacingEpochs: stream.predecessors, contentGeneration: content)
                    }
                    budget -= 1
                }
                if budget > 0 { value.prefixStreams.remove(name) }
            }
            guard value.fences.isEmpty, value.proofs.isEmpty,
                  !value.prefixStreams.contains(where: { value.streams[$0]?.initialized == true }) else { return [:] }
            let updates = value.updates; value.updates = [:]
            value.lastPublicationActivity = value.publicationActivity
            value.publicationActivity = .fileChanges
            return updates
        }
    }
    #if TRACE_CHECKPOINT_BENCHMARK
    public var checkpointBenchmarkCounts: [String: Int] {
        state.withLock { ["records": $0.streams.values.reduce(0) { $0 + $1.records.count }, "proofs": $0.proofs.count] }
    }
    #endif
    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK
    var retainedRecordCount: Int { state.withLock { $0.streams.values.reduce(0) { $0 + $1.records.count } } }
    #endif
}

/// All app indexing requests enter here. Events arriving during a pass are merged for its successor.
public actor IndexScheduler {
    private typealias CanonicalStreamRoots = [String: Set<TraceFileIO.CanonicalPath>]

    private final class ResetReceipt: Sendable {
        private enum Outcome { case pending, committed, deferred }
        private let outcome = OSAllocatedUnfairLock(initialState: Outcome.pending)
        let onCommit: @Sendable () -> Void
        let onDeferred: (@Sendable () -> Void)?
        let automaticallyRetry: Bool
        init(onCommit: @escaping @Sendable () -> Void,
             onDeferred: (@Sendable () -> Void)?, automaticallyRetry: Bool) {
            self.onCommit = onCommit; self.onDeferred = onDeferred
            self.automaticallyRetry = automaticallyRetry
        }
        var isPending: Bool { outcome.withLock { $0 == .pending } }
        var isCommitted: Bool { outcome.withLock { $0 == .committed } }
        func commit() {
            let first = outcome.withLock { value in
                guard value == .pending else { return false }
                value = .committed
                return true
            }
            if first { onCommit() }
        }
        func deferToCaller() {
            guard let onDeferred else { return }
            let first = outcome.withLock { value in
                guard value == .pending else { return false }
                value = .deferred
                return true
            }
            if first { onDeferred() }
        }
    }

    private final class OrdinaryReceipt: Sendable {
        private let completed = OSAllocatedUnfairLock(initialState: false)
        let completion: @Sendable () -> Void
        private let requirements: OSAllocatedUnfairLock<[IndexWorkRequirement]>
        var isComplete: Bool { completed.withLock { $0 } }
        init(_ completion: @escaping @Sendable () -> Void, requirements: [IndexWorkRequirement]) {
            self.completion = completion; self.requirements = .init(initialState: requirements)
        }
        func observe(paths: Set<TraceFileIO.CanonicalPath>, reconciliation: Set<TraceFileIO.CanonicalPath>, fullScan: Bool,
                     failures: Set<TraceFileIO.CanonicalPath>, reconciliationFailures: Set<TraceFileIO.CanonicalPath>) -> Bool {
            requirements.withLock { required in
                required = required.compactMap { $0.remaining(paths: paths, reconciliation: reconciliation, fullScan: fullScan,
                    fileFailures: failures, reconciliationFailures: reconciliationFailures) }
                return required.isEmpty
            }
        }
        func complete() {
            let first = completed.withLock { value in
                guard !value else { return false }; value = true; return true
            }
            if first { completion() }
        }
    }

    private typealias CheckpointReceipt = IndexCheckpointReservation.Entry
    public nonisolated let checkpointLedger: IndexCheckpointLedger
    private let installationID = UUID()
    private let qualifiedCompletion: (@Sendable ([String: IndexEventCheckpoint]) async -> Void)?
    private var pendingCheckpointReceipts: [CheckpointReceipt] = []
    private let pausedCheckpointStreamsChanged = OSAllocatedUnfairLock<(@Sendable (Set<String>) async -> Void)?>(initialState: nil)
    private var publishedPausedCheckpointStreams: Set<String>?

    private struct Batch: Sendable {
        // A reset forces a full scan; preserve independently requested scans if
        // lifecycle-aware reset ownership is returned to the caller.
        let independentFullScan: Bool
        let resets: [ResetReceipt]
        var fullScan: Bool { independentFullScan || !resets.isEmpty }
        var rebuild: Bool { resets.contains { $0.isPending } }
        var permitsResetRetry: Bool {
            let pending = resets.filter { $0.isPending }
            return pending.isEmpty || pending.contains { $0.automaticallyRetry }
        }
        var paths: Set<String>
        var reconciliationPaths: Set<String>
        let watermarks: [String: UInt64]
        let streamRoots: CanonicalStreamRoots
        let scope: IndexScope
        let activity: IndexActivity
        let satisfiesSafetyReconciliation: Bool
        let retryAttempt: Int
        let resetRetryAttempt: Int
        let usesCommittedScope: Bool
        let generation: UInt64
        var ordinaryReceipts: [OrdinaryReceipt] = []
        var checkpointReceipts: [CheckpointReceipt] = []
    }

    private let coordinator: IndexCoordinator
    private let progress: @Sendable (IndexProgress) async -> Void
    private let didComplete: @Sendable (IndexActivity, [String: UInt64]) async -> Void
    private let didSatisfySafetyReconciliation: @Sendable () async -> Void
    private let retryDelay: Duration
    private let clock: AnyClock<Duration>
    private var scope: IndexScope
    private var pendingPaths: Set<String> = []
    private var pendingReconciliationPaths: Set<String> = []
    private var pendingWatermarks: [String: UInt64] = [:]
    private var pendingStreamRoots: CanonicalStreamRoots = [:]
    private var pendingActivity: IndexActivity?
    private var pendingSatisfiesSafetyReconciliation = false
    private var fullScan = false
    private var pendingResets: [ResetReceipt] = []
    private var pendingOrdinaryReceipts: [OrdinaryReceipt] = []
    private var unprovenOrdinaryReceipts: [OrdinaryReceipt] = []
    private var worker: Task<Void, Never>?
    private var operation: Task<IndexProgress, Never>?
    private struct WaitingRetry {
        let id = UUID()
        var batch: Batch
        let deadline: AnyClock<Duration>.Instant
    }
    private var waitingRetries: [WaitingRetry] = []
    private var ordinaryRecovery: Batch?
    private var dormantBatch: Batch?
    private var retryTask: Task<Void, Never>?
    private var retryTaskID: UUID?
    private var configurationGeneration: UInt64 = 0
    private var stopping = false
    private var preservingDeferredScope = false
    private var pendingUsesCommittedScope = false
    #if DEBUG
    private var deferredCheckpointAcceptanceHookForTesting: (@Sendable () async -> Void)?
    func setDeferredCheckpointAcceptanceHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        deferredCheckpointAcceptanceHookForTesting = hook
    }
    var generationForTesting: UInt64 { configurationGeneration }
    var stoppingForTesting: Bool { stopping }
    var retainedOrdinaryReceiptCountForTesting: Int {
        waitingRetries.reduce(0) { $0 + $1.batch.ordinaryReceipts.count }
            + (ordinaryRecovery?.ordinaryReceipts.count ?? 0) + (dormantBatch?.ordinaryReceipts.count ?? 0)
            + pendingOrdinaryReceipts.count
    }
    #endif

    public init(coordinator: IndexCoordinator, scope: IndexScope,
                progress: @escaping @Sendable (IndexProgress) async -> Void,
                retryDelay: Duration = .seconds(5),
                clock: any Clock<Duration> = ContinuousClock(),
                didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void = { _, _ in },
                didSatisfySafetyReconciliation: @escaping @Sendable () async -> Void = {}) {
        self.init(coordinator: coordinator, scope: scope, progress: progress,
            retryDelay: retryDelay, clock: clock, didComplete: didComplete,
            didSatisfySafetyReconciliation: didSatisfySafetyReconciliation,
            checkpointLedger: IndexCheckpointLedger())
    }

    public init(coordinator: IndexCoordinator, scope: IndexScope,
                progress: @escaping @Sendable (IndexProgress) async -> Void,
                retryDelay: Duration = .seconds(5),
                clock: any Clock<Duration> = ContinuousClock(),
                didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void = { _, _ in },
                didSatisfySafetyReconciliation: @escaping @Sendable () async -> Void = {},
                checkpointLedger: IndexCheckpointLedger,
                didCompleteCheckpoints: (@Sendable ([String: IndexEventCheckpoint]) async -> Void)? = nil) {
        self.checkpointLedger = checkpointLedger
        checkpointLedger.synchronizeContext(content: coordinator.checkpointContentGeneration)
        checkpointLedger.resumeInitialization()
        self.qualifiedCompletion = didCompleteCheckpoints
        self.coordinator = coordinator
        self.scope = scope
        self.retryDelay = retryDelay
        self.clock = AnyClock(clock)
        self.progress = progress
        self.didComplete = didComplete
        self.didSatisfySafetyReconciliation = didSatisfySafetyReconciliation
    }

    /// Reports paused initialization without manufacturing an indexing pass.
    /// Existing initializer signatures and their behavior remain available.
    public init(coordinator: IndexCoordinator, scope: IndexScope,
                progress: @escaping @Sendable (IndexProgress) async -> Void,
                retryDelay: Duration = .seconds(5), clock: any Clock<Duration> = ContinuousClock(),
                didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void = { _, _ in },
                didSatisfySafetyReconciliation: @escaping @Sendable () async -> Void = {},
                checkpointLedger: IndexCheckpointLedger,
                didCompleteCheckpoints: (@Sendable ([String: IndexEventCheckpoint]) async -> Void)? = nil,
                didChangePausedCheckpointStreams: @escaping @Sendable (Set<String>) async -> Void) {
        self.init(coordinator: coordinator, scope: scope, progress: progress, retryDelay: retryDelay,
            clock: clock, didComplete: didComplete, didSatisfySafetyReconciliation: didSatisfySafetyReconciliation,
            checkpointLedger: checkpointLedger, didCompleteCheckpoints: didCompleteCheckpoints)
        self.pausedCheckpointStreamsChanged.withLock { $0 = didChangePausedCheckpointStreams }
    }

    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:],
                        streamRoots: [String: Set<String>] = [:]) {
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: rebuild, scope: scope, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
            watermarks: watermarks, streamRoots: streamRoots, onRebuildReset: nil,
            onRebuildDeferred: nil, automaticallyRetryReset: true)
    }

    /// Called once when this request's reset commits, on the database execution
    /// context. Cancellation or a later checkpoint failure cannot suppress it.
    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:],
                        streamRoots: [String: Set<String>] = [:],
                        onRebuildReset: @escaping @Sendable () -> Void) {
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: rebuild, scope: scope, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
            watermarks: watermarks, streamRoots: streamRoots, onRebuildReset: onRebuildReset,
            onRebuildDeferred: nil, automaticallyRetryReset: true)
    }

    /// Lifecycle-aware reset ownership returns to the caller when its bounded
    /// attempts are exhausted. Ordinary scan/path recovery remains scheduled.
    /// The deferred callback runs on scheduler execution, only after the failed
    /// operation ends. Stopping/replacing the scheduler does not defer intent.
    /// Disable automatic reset retry for a later event's single recovery attempt.
    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:],
                        streamRoots: [String: Set<String>] = [:],
                        onRebuildReset: @escaping @Sendable () -> Void,
                        onRebuildDeferred: @escaping @Sendable () -> Void,
                        automaticallyRetryReset: Bool = true) {
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: rebuild, scope: scope, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
            watermarks: watermarks, streamRoots: streamRoots, onRebuildReset: onRebuildReset,
            onRebuildDeferred: onRebuildDeferred, automaticallyRetryReset: automaticallyRetryReset)
    }

    /// Reports accepted coverage of this payload's ordinary inputs. A failed
    /// reset or a stopped scheduler cannot acknowledge those inputs.
    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:],
                        streamRoots: [String: Set<String>] = [:],
                        onRebuildReset: @escaping @Sendable () -> Void,
                        onRebuildDeferred: @escaping @Sendable () -> Void,
                        automaticallyRetryReset: Bool = true,
                        onOrdinaryWorkCompleted: @escaping @Sendable () -> Void) {
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: rebuild, scope: scope, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
            watermarks: watermarks, streamRoots: streamRoots, onRebuildReset: onRebuildReset,
            onRebuildDeferred: onRebuildDeferred, automaticallyRetryReset: automaticallyRetryReset,
            onOrdinaryWorkCompleted: onOrdinaryWorkCompleted)
    }

    /// Reports accepted coverage of this payload's ordinary inputs. A failed
    /// reset or a stopped scheduler cannot acknowledge those inputs.
    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:],
                        streamRoots: [String: Set<String>] = [:],
                        onRebuildReset: @escaping @Sendable () -> Void,
                        onRebuildDeferred: @escaping @Sendable () -> Void,
                        automaticallyRetryReset: Bool = true,
                        onOrdinaryWorkCompleted: @escaping @Sendable () -> Void,
                        checkpointReservations: [IndexCheckpointReservation]) {
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: rebuild, scope: scope, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
            watermarks: watermarks, streamRoots: streamRoots, onRebuildReset: onRebuildReset,
            onRebuildDeferred: onRebuildDeferred, automaticallyRetryReset: automaticallyRetryReset,
            onOrdinaryWorkCompleted: onOrdinaryWorkCompleted, checkpointReservations: checkpointReservations)
    }

    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [], scope: IndexScope? = nil,
                        activity: IndexActivity? = nil, satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:], streamRoots: [String: Set<String>] = [:],
                        checkpointReservations: [IndexCheckpointReservation]) {
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: false, scope: scope, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation, watermarks: watermarks,
            streamRoots: streamRoots, onRebuildReset: nil, onRebuildDeferred: nil,
            automaticallyRetryReset: true, checkpointReservations: checkpointReservations)
    }

    /// Recovers ordinary inputs against the committed scope without changing
    /// the requested scope or implicitly clearing an index whose reset is owed.
    public func requestOrdinaryRecovery(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [], activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:], streamRoots: [String: Set<String>] = [:],
                        onOrdinaryWorkCompleted: (@Sendable () -> Void)? = nil) {
        guard !stopping else { return }
        pendingUsesCommittedScope = true
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: false, scope: nil, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation, watermarks: watermarks,
            streamRoots: streamRoots, onRebuildReset: nil, onRebuildDeferred: nil,
            automaticallyRetryReset: true, onOrdinaryWorkCompleted: onOrdinaryWorkCompleted)
    }

    /// Recovers ordinary inputs against the committed scope without changing
    /// the requested scope or implicitly clearing an index whose reset is owed.
    public func requestOrdinaryRecovery(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [], activity: IndexActivity? = nil,
                        satisfiesSafetyReconciliation: Bool? = nil,
                        watermarks: [String: UInt64] = [:], streamRoots: [String: Set<String>] = [:],
                        onOrdinaryWorkCompleted: (@Sendable () -> Void)? = nil,
                        checkpointReservations: [IndexCheckpointReservation]) {
        guard !stopping else { return }
        pendingUsesCommittedScope = true
        enqueue(paths: paths, reconcile: reconcile, reconciliationPaths: reconciliationPaths,
            rebuild: false, scope: nil, activity: activity,
            satisfiesSafetyReconciliation: satisfiesSafetyReconciliation, watermarks: watermarks,
            streamRoots: streamRoots, onRebuildReset: nil, onRebuildDeferred: nil,
            automaticallyRetryReset: true, onOrdinaryWorkCompleted: onOrdinaryWorkCompleted, checkpointReservations: checkpointReservations)
    }

    private func enqueue(paths: Set<String>, reconcile: Bool, reconciliationPaths: Set<String>,
                         rebuild: Bool, scope: IndexScope?, activity: IndexActivity?,
                         satisfiesSafetyReconciliation: Bool?, watermarks: [String: UInt64],
                         streamRoots: [String: Set<String>], onRebuildReset: (@Sendable () -> Void)?,
                         onRebuildDeferred: (@Sendable () -> Void)?, automaticallyRetryReset: Bool,
                         onOrdinaryWorkCompleted: (@Sendable () -> Void)? = nil,
                         checkpointReservations: [IndexCheckpointReservation]? = nil) {
        guard !stopping else { return }
        let canonicalRoots = streamRoots.mapValues { Set($0.map(TraceFileIO.canonicalPath)) }
        let reservations = checkpointReservations ?? [checkpointLedger.reserve(watermarks: watermarks,
            streamRoots: streamRoots, hasIndexWork: !paths.isEmpty || !reconciliationPaths.isEmpty || reconcile || rebuild,
            paths: paths, reconciliationPaths: reconciliationPaths)]
        let checkpointEntries = checkpointLedger.entries(reservations)
        pendingCheckpointReceipts = uniqueCheckpoints(pendingCheckpointReceipts + checkpointEntries)
        if let onOrdinaryWorkCompleted {
            let required = IndexWorkRequirement(paths: Set(paths.map(TraceFileIO.canonicalPath)),
                reconciliation: Set(reconciliationPaths.map(TraceFileIO.canonicalPath)), fullScan: reconcile)
            pendingOrdinaryReceipts.append(OrdinaryReceipt(onOrdinaryWorkCompleted,
                requirements: [required] + checkpointLedger.requirements(checkpointEntries)))
        }
        if rebuild {
            pendingResets.append(ResetReceipt(onCommit: onRebuildReset ?? {},
                onDeferred: onRebuildDeferred, automaticallyRetry: automaticallyRetryReset))
        }
        let scopeChanged = scope.map { $0 != self.scope } ?? false
        if scopeChanged { preservingDeferredScope = false; pendingUsesCommittedScope = false }
        if scopeChanged || rebuild {
            // Admission fences publication; only the transaction commit adds
            // reset coverage requirements. A rollback preserves completed work.
            checkpointLedger.fenceReset(installationID)
            for batch in waitingRetries.map(\.batch) + [dormantBatch, ordinaryRecovery].compactMap({ $0 }) {
                carryPendingResets(batch)
                pendingOrdinaryReceipts = uniqueOrdinary(pendingOrdinaryReceipts + batch.ordinaryReceipts)
                pendingCheckpointReceipts = uniqueCheckpoints(pendingCheckpointReceipts + batch.checkpointReceipts)
                pendingPaths.formUnion(batch.paths)
                pendingReconciliationPaths.formUnion(batch.reconciliationPaths)
                fullScan = fullScan || batch.independentFullScan
                mergeWatermarks(batch.watermarks)
                mergeCanonicalStreamRoots(batch.streamRoots)
            }
            ordinaryRecovery = nil
            waitingRetries.removeAll()
            dormantBatch = nil
            cancelScheduledRetry()
            configurationGeneration &+= 1
            operation?.cancel()
        }
        if let scope { self.scope = scope }
        pendingPaths.formUnion(paths)
        pendingReconciliationPaths.formUnion(reconciliationPaths)
        for (volume, eventID) in watermarks {
            pendingWatermarks[volume] = max(pendingWatermarks[volume] ?? 0, eventID)
        }
        mergeCanonicalStreamRoots(canonicalRoots)
        let inferred = activity ?? (rebuild ? .rebuild : (scopeChanged ? .scopeChange : (reconcile ? .initialBuild
            : (!reconciliationPaths.isEmpty ? .subtreeRecovery : .fileChanges))))
        let requestsPass = reconcile || rebuild || !paths.isEmpty
            || !reconciliationPaths.isEmpty || inferred != .fileChanges || scopeChanged
        fullScan = fullScan || reconcile || scopeChanged
        if requestsPass {
            pendingActivity = IndexActivity.moreSignificant(pendingActivity, inferred)
            pendingSatisfiesSafetyReconciliation = pendingSatisfiesSafetyReconciliation
                || (satisfiesSafetyReconciliation ?? inferred.satisfiesSafetyReconciliation)
        }
        reactivateDormantIfCovered()
        coalesceFullScanWithResetRetry()
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        defer { worker = nil }
        while !stopping && (hasPendingWork || !pendingOrdinaryReceipts.isEmpty || !checkpointLedger.uninitializedStreams.isEmpty || ordinaryRecovery != nil || readyRetryIndex != nil
            || checkpointLedger.hasReadyProofs) {
            await drainCheckpointProofs()
            guard !stopping else { return }
            for stream in checkpointLedger.uninitializedStreams.sorted() {
                do {
                    let record = try await coordinator.checkpointRecord(stream: stream)
                    guard !stopping else { return }
                    checkpointLedger.seed(stream: stream, checkpoint: record)
                } catch {
                    guard !stopping else { return }
                    checkpointLedger.pauseInitialization(stream)
                }
            }
            guard !stopping else { return }
            let paused = checkpointLedger.pausedStreams
            if publishedPausedCheckpointStreams != paused {
                publishedPausedCheckpointStreams = paused
                let changed = pausedCheckpointStreamsChanged.withLock { $0 }
                await changed?(paused)
                guard !stopping else { return }
            }
            // Fresh work always wins over a delayed retry, so a bad source cannot
            // starve later filesystem events.
            let retrying = !hasPendingIndexWork && ordinaryRecovery == nil && readyRetryIndex != nil
            if !retrying, ordinaryRecovery == nil, !fullScan, pendingResets.isEmpty, pendingPaths.isEmpty, pendingReconciliationPaths.isEmpty,
               pendingActivity == nil {
                let receipts = checkpointLedger.metadataOnlyEntries(pendingCheckpointReceipts)
                let ordinary = pendingOrdinaryReceipts
                pendingOrdinaryReceipts.removeAll()
                pendingCheckpointReceipts.removeAll()
                pendingWatermarks.removeAll()
                pendingStreamRoots.removeAll()
                let content = coordinator.checkpointContentGeneration
                guard !stopping else { return }
                completeOrdinary(ordinary, paths: [], reconciliationPaths: [], fullScan: false, failures: [])
                checkpointLedger.retain(.init(coverage: checkpointLedger.begin(receipts, owner: installationID),
                    paths: [], reconciliation: [], failures: [], reconciliationFailures: [],
                    fullScan: false, content: content, scope: coordinator.checkpointScope))
                await drainCheckpointProofs()
                continue
            }
            var batch: Batch
            if retrying, let index = readyRetryIndex {
                // Execution owns this batch exclusively. New arrivals cannot
                // merge into it and its continuation cannot merge with itself.
                batch = waitingRetries.remove(at: index).batch
                scheduleRetry()
            } else if !hasPendingIndexWork, let recovery = ordinaryRecovery {
                batch = recovery
                ordinaryRecovery = nil
            } else {
                batch = Batch(
                    independentFullScan: fullScan,
                    resets: pendingResets,
                    paths: pendingPaths,
                    reconciliationPaths: pendingReconciliationPaths,
                    watermarks: pendingWatermarks,
                    streamRoots: pendingStreamRoots,
                    scope: scope,
                    activity: pendingActivity ?? .fileChanges,
                    satisfiesSafetyReconciliation: pendingSatisfiesSafetyReconciliation,
                    retryAttempt: 0, resetRetryAttempt: 0, usesCommittedScope: preservingDeferredScope || pendingUsesCommittedScope,
                    generation: configurationGeneration, ordinaryReceipts: pendingOrdinaryReceipts, checkpointReceipts: pendingCheckpointReceipts
                )
                fullScan = false
                pendingResets.removeAll()
                pendingOrdinaryReceipts.removeAll()
                pendingCheckpointReceipts.removeAll()
                pendingPaths.removeAll()
                pendingReconciliationPaths.removeAll()
                pendingWatermarks.removeAll()
                pendingStreamRoots.removeAll()
                pendingActivity = nil
                pendingSatisfiesSafetyReconciliation = false
                pendingUsesCommittedScope = false
            }
            let canonicalPaths = Set(batch.paths.map(TraceFileIO.canonicalPath))
            let canonicalReconciliation = Set(batch.reconciliationPaths.map(TraceFileIO.canonicalPath))
            batch.paths = Set(canonicalPaths.map(\.path))
            batch.reconciliationPaths = Set(canonicalReconciliation.map(\.path))
            checkpointLedger.synchronizeContext(content: coordinator.checkpointContentGeneration)
            batch.checkpointReceipts = uniqueCheckpoints(batch.checkpointReceipts + checkpointLedger.coverableEntries(
                paths: batch.paths, reconciliationPaths: batch.reconciliationPaths, fullScan: batch.fullScan))
            let checkpointCoverage = checkpointLedger.begin(batch.checkpointReceipts, owner: installationID)
            let resetCoverage = OSAllocatedUnfairLock<IndexCheckpointLedger.Coverage?>(initialState: nil)
            let ledger = checkpointLedger
            let execution = batch
            let forward: @Sendable (IndexProgress) async -> Void = { [weak self] update in
                await self?.forwardProgress(update, generation: execution.generation)
            }
            let operation = Task {
                await coordinator.executeScheduled(paths: execution.paths, reconciliationPaths: execution.reconciliationPaths,
                    fullScan: execution.fullScan, rebuild: execution.rebuild,
                    preservingCommittedScope: execution.usesCommittedScope && !execution.rebuild,
                    scope: execution.scope, activity: execution.activity,
                    satisfiesSafetyReconciliation: execution.satisfiesSafetyReconciliation,
                    onRebuildReset: { for reset in execution.resets { reset.commit() } },
                    onIndexReset: { content in
                        let coverage = ledger.committedReset(content: content, extending: checkpointCoverage)
                        resetCoverage.withLock { $0 = coverage }
                    }, progress: forward)
            }
            self.operation = operation
            let result = await operation.value
            self.operation = nil
            // Proof transfer precedes stop/replacement checks. A complete pass is
            // database-owned even if its scheduler is being retired.
            if result.phase == .complete {
                let coverage = resetCoverage.withLock { $0 } ?? checkpointCoverage
                checkpointLedger.retain(.init(coverage: coverage, paths: canonicalPaths,
                    reconciliation: canonicalReconciliation,
                    failures: Set(result.failedPaths.map(TraceFileIO.canonicalPath)),
                    reconciliationFailures: Set(result.failedReconciliationPaths.map(TraceFileIO.canonicalPath)),
                    fullScan: batch.fullScan, content: result.checkpointContentGeneration, scope: result.checkpointScope ?? batch.scope, activity: batch.activity))
            }
            if batch.generation == configurationGeneration { checkpointLedger.releaseReset(installationID) }
            guard !stopping else { return }
            if batch.resets.contains(where: { $0.isCommitted }) { preservingDeferredScope = false }
            if batch.generation != configurationGeneration {
                if !stopping {
                    carryPendingResets(batch)
                    pendingOrdinaryReceipts = uniqueOrdinary(pendingOrdinaryReceipts + batch.ordinaryReceipts)
                    pendingCheckpointReceipts = uniqueCheckpoints(pendingCheckpointReceipts + batch.checkpointReceipts)
                    pendingPaths.formUnion(batch.paths)
                    pendingReconciliationPaths.formUnion(batch.reconciliationPaths)
                    fullScan = fullScan || batch.independentFullScan || batch.resets.contains { $0.isCommitted }
                }
                mergeWatermarks(batch.watermarks)
                mergeCanonicalStreamRoots(batch.streamRoots)
                continue
            }
            if result.phase == .complete {
                let hasFailures = !result.failedPaths.isEmpty
                    || !result.failedReconciliationPaths.isEmpty
                if hasFailures {
                    let failedPaths = result.failedPaths.union(result.failedReconciliationPaths)
                    let recovery = Batch(
                        independentFullScan: false, resets: [],
                        paths: result.failedPaths,
                        reconciliationPaths: result.failedReconciliationPaths,
                        watermarks: affectedWatermarks(
                            batch.watermarks, streamRoots: batch.streamRoots,
                            failedPaths: failedPaths
                        ),
                        streamRoots: batch.streamRoots, scope: batch.scope,
                        activity: .subtreeRecovery, satisfiesSafetyReconciliation: false,
                        retryAttempt: batch.retryAttempt, resetRetryAttempt: 0,
                        usesCommittedScope: batch.usesCommittedScope,
                        generation: configurationGeneration, ordinaryReceipts: batch.ordinaryReceipts, checkpointReceipts: batch.checkpointReceipts
                    )
                    if batch.retryAttempt == 0 {
                        retainForRetry(recovery)
                    } else {
                        parkDormant(recovery)
                    }
                }
                completeOrdinary(batch.ordinaryReceipts, paths: batch.paths,
                    reconciliationPaths: batch.reconciliationPaths, fullScan: batch.fullScan,
                    failures: result.failedPaths, failedReconciliationPaths: result.failedReconciliationPaths)
                // Failed paths retain their stream watermarks through the one
                // scheduled retry and any dormant period. Unrelated streams can
                // still advance independently.
                await drainCheckpointProofs()
                if batch.satisfiesSafetyReconciliation {
                    await didSatisfySafetyReconciliation()
                }
            } else if result.phase == .failed {
                if batch.rebuild {
                    if batch.resetRetryAttempt == 0 && batch.permitsResetRetry {
                        retainForRetry(batch, reset: true)
                    } else {
                        deferResetAndRecoverOrdinary(batch)
                    }
                } else if batch.retryAttempt == 0 {
                    retainForRetry(batch)
                } else {
                    parkDormant(batch)
                }
            } else if result.phase == .cancelled, !stopping {
                if batch.rebuild && !batch.permitsResetRetry { deferResetAndRecoverOrdinary(batch) }
                else { retainForRetry(batch, reset: batch.rebuild) }
            }
        }
    }

    private func forwardProgress(_ update: IndexProgress, generation: UInt64) async {
        // A cancelled operation may still finish database awaits and its final
        // callback. The app also checks cancellation after the main-actor hop.
        guard !Task.isCancelled, !stopping, generation == configurationGeneration else { return }
        await progress(update)
    }

    private var hasPendingWork: Bool {
        fullScan || !pendingResets.isEmpty || !pendingPaths.isEmpty || !pendingReconciliationPaths.isEmpty
            || pendingActivity != nil || !pendingWatermarks.isEmpty || !pendingCheckpointReceipts.isEmpty
    }

    private var hasPendingIndexWork: Bool {
        fullScan || !pendingResets.isEmpty || !pendingPaths.isEmpty || !pendingReconciliationPaths.isEmpty
            || pendingActivity != nil
    }

    private func mergeWatermarks(_ watermarks: [String: UInt64]) {
        for (volume, eventID) in watermarks {
            pendingWatermarks[volume] = max(pendingWatermarks[volume] ?? 0, eventID)
        }
    }

    private func mergeCanonicalStreamRoots(_ roots: CanonicalStreamRoots) {
        for (volume, paths) in roots {
            pendingStreamRoots[volume, default: []].formUnion(paths)
        }
    }

    private func retainForRetry(_ batch: Batch, reset: Bool = false) {
        guard !stopping else { return }
        let candidate = Batch(
            independentFullScan: batch.independentFullScan, resets: batch.resets,
            paths: batch.paths,
            reconciliationPaths: batch.reconciliationPaths,
            watermarks: batch.watermarks,
            streamRoots: batch.streamRoots,
            scope: scope,
            activity: batch.activity,
            satisfiesSafetyReconciliation: batch.satisfiesSafetyReconciliation,
            retryAttempt: batch.retryAttempt + (reset ? 0 : 1),
            resetRetryAttempt: batch.resetRetryAttempt + (reset ? 1 : 0),
            usesCommittedScope: batch.usesCommittedScope,
            generation: configurationGeneration, ordinaryReceipts: batch.ordinaryReceipts, checkpointReceipts: batch.checkpointReceipts
        )
        if !reset, !candidate.rebuild,
           let index = waitingRetries.firstIndex(where: {
               !$0.batch.rebuild && $0.batch.generation == candidate.generation
                   && $0.batch.scope == candidate.scope && $0.batch.usesCommittedScope == candidate.usesCommittedScope
                   && $0.batch.retryAttempt == candidate.retryAttempt
                   && $0.batch.resetRetryAttempt == candidate.resetRetryAttempt
           }) {
            waitingRetries[index].batch = merged(waitingRetries[index].batch, candidate, retryAttempt: candidate.retryAttempt)
        } else {
            waitingRetries.append(WaitingRetry(batch: candidate, deadline: clock.now.advanced(by: retryDelay)))
        }
        scheduleRetry()
    }

    private func parkDormant(_ batch: Batch) {
        guard !stopping else { return }
        // Notify only after execution has ended. Legacy enrollments retain their
        // pending reset; lifecycle-aware enrollments return it exactly once.
        for reset in batch.resets { reset.deferToCaller() }
        let retained = batch.resets.filter { $0.isPending || $0.isCommitted }
        let hasWork = batch.independentFullScan || !retained.isEmpty
            || !batch.paths.isEmpty || !batch.reconciliationPaths.isEmpty || !batch.watermarks.isEmpty
        guard hasWork else { return }
        let activity: IndexActivity = retained.isEmpty && batch.activity == .rebuild
            ? (batch.independentFullScan ? .initialBuild
                : (batch.reconciliationPaths.isEmpty ? .fileChanges : .subtreeRecovery)) : batch.activity
        let candidate = Batch(
            independentFullScan: batch.independentFullScan, resets: retained,
            paths: batch.paths, reconciliationPaths: batch.reconciliationPaths,
            watermarks: batch.watermarks, streamRoots: batch.streamRoots, scope: scope,
            activity: activity,
            satisfiesSafetyReconciliation: batch.satisfiesSafetyReconciliation,
            retryAttempt: batch.retryAttempt, resetRetryAttempt: batch.resetRetryAttempt,
            usesCommittedScope: batch.usesCommittedScope,
            generation: configurationGeneration, ordinaryReceipts: batch.ordinaryReceipts, checkpointReceipts: batch.checkpointReceipts
        )
        dormantBatch = merged(dormantBatch, candidate, retryAttempt: candidate.retryAttempt)
    }

    /// A failed reset has not attempted its ordinary inputs. Return only reset
    /// ownership, then give those inputs their own first pass and retry budget.
    private func deferResetAndRecoverOrdinary(_ batch: Batch) {
        guard !stopping else { return }
        preservingDeferredScope = true
        for receipt in batch.resets { receipt.deferToCaller() }
        let legacy = batch.resets.filter { $0.isPending }
        if !legacy.isEmpty {
            let debt = Batch(independentFullScan: false, resets: legacy, paths: [],
                reconciliationPaths: [], watermarks: [:], streamRoots: [:], scope: batch.scope,
                activity: .rebuild, satisfiesSafetyReconciliation: false, retryAttempt: 0,
                resetRetryAttempt: batch.resetRetryAttempt, usesCommittedScope: false,
                generation: configurationGeneration)
            dormantBatch = merged(dormantBatch, debt, retryAttempt: 0)
        }
        let full = batch.independentFullScan || batch.resets.contains { $0.isCommitted }
        let ordinary = Batch(independentFullScan: full, resets: [], paths: batch.paths,
            reconciliationPaths: batch.reconciliationPaths, watermarks: batch.watermarks,
            streamRoots: batch.streamRoots, scope: batch.scope,
            activity: batch.activity == .rebuild
                ? (full ? .initialBuild : (batch.reconciliationPaths.isEmpty ? .fileChanges : .subtreeRecovery))
                : batch.activity,
            satisfiesSafetyReconciliation: batch.satisfiesSafetyReconciliation,
            retryAttempt: batch.retryAttempt, resetRetryAttempt: 0, usesCommittedScope: true,
            generation: configurationGeneration, ordinaryReceipts: batch.ordinaryReceipts, checkpointReceipts: batch.checkpointReceipts)
        if full || !ordinary.paths.isEmpty || !ordinary.reconciliationPaths.isEmpty {
            ordinaryRecovery = merged(ordinaryRecovery, ordinary, retryAttempt: ordinary.retryAttempt)
        } else if !ordinary.watermarks.isEmpty {
            // A reset-only checkpoint has no independently covered scan yet.
            dormantBatch = merged(dormantBatch, ordinary, retryAttempt: ordinary.retryAttempt)
        }
    }

    private func carryPendingResets(_ batch: Batch) {
        let pending = batch.resets.filter { $0.isPending }
        guard !pending.isEmpty else { return }
        pendingResets = uniqueResets(pendingResets + pending)
        pendingActivity = IndexActivity.moreSignificant(pendingActivity, .rebuild)
    }

    private func uniqueResets(_ resets: [ResetReceipt]) -> [ResetReceipt] {
        uniqueObjects(resets)
    }

    private func coalesceFullScanWithResetRetry() {
        guard fullScan, pendingResets.isEmpty,
              let index = waitingRetries.firstIndex(where: { $0.batch.rebuild && $0.batch.scope == scope }) else { return }
        let retry = waitingRetries[index].batch
        let incoming = Batch(independentFullScan: true, resets: [], paths: pendingPaths,
            reconciliationPaths: pendingReconciliationPaths, watermarks: pendingWatermarks,
            streamRoots: pendingStreamRoots, scope: scope, activity: pendingActivity ?? .initialBuild,
            satisfiesSafetyReconciliation: pendingSatisfiesSafetyReconciliation,
            retryAttempt: 0, resetRetryAttempt: retry.resetRetryAttempt,
            usesCommittedScope: retry.usesCommittedScope, generation: configurationGeneration,
            ordinaryReceipts: pendingOrdinaryReceipts, checkpointReceipts: pendingCheckpointReceipts)
        waitingRetries[index].batch = merged(retry, incoming, retryAttempt: retry.retryAttempt)
        fullScan = false
        pendingPaths.removeAll(); pendingReconciliationPaths.removeAll()
        pendingWatermarks.removeAll(); pendingStreamRoots.removeAll()
        pendingActivity = nil; pendingSatisfiesSafetyReconciliation = false
        pendingOrdinaryReceipts.removeAll()
        pendingCheckpointReceipts.removeAll()
        // Keep the original scheduled deadline and retry readiness.
    }

    private func merged(_ existing: Batch?, _ incoming: Batch, retryAttempt: Int) -> Batch {
        guard let existing else { return incoming }
        var watermarks = existing.watermarks
        for (volume, eventID) in incoming.watermarks {
            watermarks[volume] = max(watermarks[volume] ?? 0, eventID)
        }
        var streamRoots = existing.streamRoots
        for (volume, roots) in incoming.streamRoots {
            streamRoots[volume, default: []].formUnion(roots)
        }
        let resets = uniqueResets(existing.resets + incoming.resets)
        return Batch(
            independentFullScan: existing.independentFullScan || incoming.independentFullScan,
            resets: resets,
            paths: existing.paths.union(incoming.paths),
            reconciliationPaths: existing.reconciliationPaths.union(incoming.reconciliationPaths),
            watermarks: watermarks, streamRoots: streamRoots,
            scope: scope,
            activity: IndexActivity.moreSignificant(existing.activity, incoming.activity),
            satisfiesSafetyReconciliation: existing.satisfiesSafetyReconciliation
                || incoming.satisfiesSafetyReconciliation,
            retryAttempt: retryAttempt,
            resetRetryAttempt: max(existing.resetRetryAttempt, incoming.resetRetryAttempt),
            usesCommittedScope: !resets.contains { $0.isPending } && (existing.usesCommittedScope || incoming.usesCommittedScope),
            generation: configurationGeneration,
            ordinaryReceipts: uniqueOrdinary(existing.ordinaryReceipts + incoming.ordinaryReceipts),
            checkpointReceipts: uniqueCheckpoints(existing.checkpointReceipts + incoming.checkpointReceipts)
        )
    }

    private func completeOrdinary(_ receipts: [OrdinaryReceipt], paths: Set<String>,
                                  reconciliationPaths: Set<String>, fullScan: Bool, failures: Set<String>,
                                  failedReconciliationPaths: Set<String> = []) {
        let changed = Set(paths.map(TraceFileIO.canonicalPath))
        let reconciled = Set(reconciliationPaths.map(TraceFileIO.canonicalPath))
        let failed = Set(failures.map(TraceFileIO.canonicalPath))
        let failedReconciliation = Set(failedReconciliationPaths.map(TraceFileIO.canonicalPath))
        let all = uniqueOrdinary(unprovenOrdinaryReceipts + receipts)
        unprovenOrdinaryReceipts = []
        for receipt in all {
            if receipt.observe(paths: changed, reconciliation: reconciled, fullScan: fullScan,
                               failures: failed, reconciliationFailures: failedReconciliation) {
                receipt.complete()
            } else { unprovenOrdinaryReceipts.append(receipt) }
        }
    }

    private func drainCheckpointProofs() async {
        while !stopping && checkpointLedger.hasReadyProofs {
            #if DEBUG
            if checkpointLedger.hasCompletedProofs { await deferredCheckpointAcceptanceHookForTesting?() }
            guard !stopping else { return }
            #endif
            let context = coordinator.checkpointContext
            let updates = checkpointLedger.drainProofs(scope: context.scope, content: context.generation)
            guard !stopping else { return }
            await publishCheckpoints(updates, activity: checkpointLedger.lastPublicationActivity)
            await Task.yield()
        }
    }

    private func publishCheckpoints(_ updates: [String: IndexEventCheckpoint], activity: IndexActivity) async {
        guard !updates.isEmpty else { return }
        if let qualifiedCompletion { await qualifiedCompletion(updates) }
        else { await didComplete(activity, updates.mapValues(\.value)) }
    }

    private func uniqueCheckpoints(_ receipts: [CheckpointReceipt]) -> [CheckpointReceipt] {
        var newest: [UUID: CheckpointReceipt] = [:]
        for receipt in receipts where newest[receipt.id].map({ $0.version < receipt.version }) ?? true {
            newest[receipt.id] = receipt
        }
        return Array(newest.values)
    }

    private func affectedWatermarks(
        _ watermarks: [String: UInt64], streamRoots: CanonicalStreamRoots,
        failedPaths: Set<String>
    ) -> [String: UInt64] {
        guard !failedPaths.isEmpty else { return watermarks }
        let failures = failedPaths.map(TraceFileIO.canonicalPath)
        return watermarks.filter { volume, _ in
            guard let roots = streamRoots[volume], !roots.isEmpty else { return true }
            return roots.contains { root in
                failures.contains { root.intersects($0) }
            }
        }
    }

    private func reactivateDormantIfCovered() {
        guard let dormantBatch else { return }
        let covered: Bool
        if fullScan || !pendingResets.isEmpty {
            covered = true
        } else {
            let pending = (pendingPaths.union(pendingReconciliationPaths)).map(
                TraceFileIO.canonicalPath
            )
            let required = dormantBatch.paths.union(dormantBatch.reconciliationPaths).map(
                TraceFileIO.canonicalPath
            )
            covered = !required.isEmpty && required.allSatisfy { requiredPath in
                pending.contains { $0.contains(requiredPath) }
            }
        }
        guard covered else { return }
        pendingPaths.formUnion(dormantBatch.paths)
        pendingReconciliationPaths.formUnion(dormantBatch.reconciliationPaths)
        mergeWatermarks(dormantBatch.watermarks)
        mergeCanonicalStreamRoots(dormantBatch.streamRoots)
        fullScan = fullScan || dormantBatch.independentFullScan
        // A committed reset still owes its scan; an uncommitted one must reset.
        pendingResets = uniqueResets(pendingResets + dormantBatch.resets)
        pendingOrdinaryReceipts = uniqueOrdinary(pendingOrdinaryReceipts + dormantBatch.ordinaryReceipts)
        pendingCheckpointReceipts = uniqueCheckpoints(pendingCheckpointReceipts + dormantBatch.checkpointReceipts)
        pendingActivity = IndexActivity.moreSignificant(
            pendingActivity, dormantBatch.activity
        )
        pendingSatisfiesSafetyReconciliation = pendingSatisfiesSafetyReconciliation
            || dormantBatch.satisfiesSafetyReconciliation
        self.dormantBatch = nil
    }

    private var readyRetryIndex: Int? {
        waitingRetries.indices.filter { waitingRetries[$0].deadline <= clock.now }
            .min { waitingRetries[$0].deadline < waitingRetries[$1].deadline }
    }

    private func scheduleRetry() {
        cancelScheduledRetry()
        guard !stopping, let next = waitingRetries.min(by: { $0.deadline < $1.deadline }) else { return }
        let id = next.id
        retryTaskID = id
        let clock = clock
        retryTask = Task { [weak self] in
            do { try await clock.sleep(until: next.deadline) }
            catch { return }
            await self?.startScheduledRetry(id)
        }
    }

    private func startScheduledRetry(_ id: UUID) {
        guard retryTaskID == id else { return }
        retryTask = nil
        retryTaskID = nil
        guard !stopping, readyRetryIndex != nil else { return }
        if worker == nil { worker = Task { await drain() } }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
        retryTaskID = nil
    }

    private func uniqueObjects<Value: AnyObject>(_ values: [Value]) -> [Value] {
        var seen = Set<ObjectIdentifier>()
        return values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func uniqueOrdinary(_ receipts: [OrdinaryReceipt]) -> [OrdinaryReceipt] {
        uniqueObjects(receipts).filter { !$0.isComplete }
    }

    #if TRACE_CHECKPOINT_BENCHMARK
    public func checkpointBenchmarkCounts() -> [String: Int] { checkpointLedger.checkpointBenchmarkCounts }
    #endif

    public func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    public func stop() async {
        stopping = true
        pendingCheckpointReceipts.removeAll()
        unprovenOrdinaryReceipts.removeAll()
        pendingResets.removeAll()
        pendingOrdinaryReceipts.removeAll()
        fullScan = false
        pendingPaths.removeAll()
        pendingReconciliationPaths.removeAll()
        pendingWatermarks.removeAll()
        pendingStreamRoots.removeAll()
        pendingActivity = nil
        pendingSatisfiesSafetyReconciliation = false
        waitingRetries.removeAll()
        dormantBatch = nil
        ordinaryRecovery = nil
        cancelScheduledRetry()
        operation?.cancel()
        await worker?.value
        checkpointLedger.releaseReset(installationID)
    }
}
