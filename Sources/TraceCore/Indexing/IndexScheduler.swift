import Clocks
import Foundation
import os

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

/// Database-owned coverage survives scheduler replacement. No scheduler or
/// callback is retained here; locks are released before any caller is notified.
public final class IndexCheckpointLedger: Sendable {
    fileprivate typealias Entry = IndexCheckpointReservation.Entry
    private struct Record {
        var entry: Entry
        var covered = false
        var owner: UUID?
        var requiresReconciliation = false
        var hasIndexWork = false
        var requiresFullScan = false
        var inputPaths: Set<TraceFileIO.CanonicalPath> = []
        var inputReconciliationPaths: Set<TraceFileIO.CanonicalPath> = []
    }
    private struct Stream {
        var epoch: String
        var predecessors: Set<String>
        var floor: UInt64?
        var roots: Set<TraceFileIO.CanonicalPath> = []
        var records: [UUID: Record] = [:]
        var tail: UUID?
        var initialized = false
        var initializationFailed = false
        var ingressEpoch: IndexEventStreamEpoch?
    }
    private struct State {
        var streams: [String: Stream] = [:]
        var revision: UInt64 = 0
        var mutation: UInt64 = 0
    }
    fileprivate struct Coverage {
        let entries: [Entry]
        let owner: UUID
        let revision: UInt64
    }
    private let id = UUID()
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}

    public func seed(stream: String, checkpoint: IndexEventCheckpoint?) {
        state.withLock { value in
            var pending = value.streams[stream] ?? Stream(epoch: "", predecessors: [], floor: nil)
            guard !pending.initialized else { return }
            let wrapped = !pending.predecessors.isEmpty
            pending.epoch = UUID().uuidString
            if wrapped {
                pending.predecessors = Set([checkpoint?.epoch ?? "legacy"])
            } else {
                pending.epoch = checkpoint?.epoch ?? pending.epoch
                pending.predecessors = checkpoint == nil ? ["legacy"] : []
                pending.floor = checkpoint?.value
            }
            for key in Array(pending.records.keys) {
                guard let entry = pending.records[key]?.entry else { continue }
                pending.records[key]?.entry = .init(id: entry.id, stream: stream, epoch: pending.epoch,
                    version: entry.version, watermark: entry.watermark, roots: entry.roots)
            }
            pending.initialized = true
            pending.initializationFailed = false
            value.streams[stream] = pending
            value.mutation &+= 1
        }
    }

    fileprivate var uninitializedStreams: Set<String> {
        state.withLock { Set($0.streams.filter { !$0.value.initialized && !$0.value.initializationFailed }.keys) }
    }

    fileprivate func resumeInitialization() {
        state.withLock { value in
            for key in Array(value.streams.keys) { value.streams[key]?.initializationFailed = false }
            value.mutation &+= 1
        }
    }

    fileprivate func pauseInitialization(_ stream: String) {
        state.withLock { $0.streams[stream]?.initializationFailed = true; $0.mutation &+= 1 }
    }

    #if DEBUG
    func initializationForTesting(stream: String) -> (initialized: Bool, epoch: String?, floor: UInt64?) {
        state.withLock { value in
            let item = value.streams[stream]
            return (item?.initialized == true, item?.initialized == true ? item?.epoch : nil, item?.floor)
        }
    }
    #endif

    public func reserve(watermarks: [String: UInt64], streamRoots: [String: Set<String>],
                        hasIndexWork: Bool, wrappedStreams: Set<String> = [],
                        paths: Set<String> = [], reconciliationPaths: Set<String> = [],
                        streamEpochs: [String: IndexEventStreamEpoch] = [:]) -> IndexCheckpointReservation {
        let inputPaths = Set(paths.map(TraceFileIO.canonicalPath))
        let inputReconciliation = Set(reconciliationPaths.map(TraceFileIO.canonicalPath))
        let roots = streamRoots.mapValues { Set($0.map(TraceFileIO.canonicalPath)) }
        return state.withLock { value in
            var entries: [Entry] = []
            for (name, watermark) in watermarks {
                var stream = value.streams[name] ?? Stream(epoch: "", predecessors: [], floor: nil)
                let incoming = streamEpochs[name]
                if let incoming, stream.ingressEpoch?.predecessors.contains(incoming.id) == true { continue }
                let repeatedWrap = incoming != nil && incoming == stream.ingressEpoch
                if wrappedStreams.contains(name) && !repeatedWrap {
                    let retainedRoots = stream.records.values.reduce(into: stream.roots) { $0.formUnion($1.entry.roots) }
                    stream.predecessors.insert(stream.epoch.isEmpty ? "legacy" : stream.epoch)
                    stream.epoch = stream.initialized ? UUID().uuidString : ""
                    stream.floor = nil
                    stream.records.removeAll()
                    stream.tail = nil
                    stream.roots = retainedRoots
                }
                if let incoming { stream.ingressEpoch = incoming }
                let qualification = roots[name] ?? []
                if !hasIndexWork { stream.roots.formUnion(qualification) }
                // Watermark-only inputs share one pending tail. A revision keeps
                // a running older snapshot from accepting newer qualification.
                let previous = !hasIndexWork ? stream.tail.flatMap { stream.records[$0] } : nil
                let key = previous?.entry.id ?? UUID()
                let entry = Entry(id: key, stream: name, epoch: stream.epoch,
                    version: (previous?.entry.version ?? 0) + 1,
                    watermark: max(previous?.entry.watermark ?? 0, watermark),
                    roots: (previous?.entry.roots ?? []).union(qualification))
                let scopedPaths = inputPaths.filter { input in qualification.isEmpty || qualification.contains { $0.intersects(input) } }
                let scopedReconciliation = inputReconciliation.filter { input in qualification.isEmpty || qualification.contains { $0.intersects(input) } }
                let unspecified = hasIndexWork && inputPaths.isEmpty && inputReconciliation.isEmpty
                stream.records[key] = Record(entry: entry,
                    requiresReconciliation: previous?.requiresReconciliation == true || wrappedStreams.contains(name),
                    hasIndexWork: unspecified || !scopedPaths.isEmpty || !scopedReconciliation.isEmpty,
                    requiresFullScan: unspecified && !wrappedStreams.contains(name),
                    inputPaths: scopedPaths, inputReconciliationPaths: scopedReconciliation)
                stream.tail = hasIndexWork ? nil : key
                value.streams[name] = stream
                entries.append(entry)
            }
            value.mutation &+= 1
            return .init(ledger: id, entries: entries)
        }
    }

    fileprivate func entries(_ reservations: [IndexCheckpointReservation]) -> [Entry] {
        let supplied = reservations.filter { $0.ledger == id }.flatMap(\.entries)
        return state.withLock { value in
            supplied.compactMap { entry in
                guard let record = value.streams[entry.stream]?.records[entry.id],
                      record.entry.version == entry.version else { return nil }
                return record.entry
            }
        }
    }

    fileprivate func requirements(_ entries: [Entry]) -> [IndexWorkRequirement] {
        state.withLock { value in
            entries.compactMap { entry in
                guard let record = value.streams[entry.stream]?.records[entry.id] else { return nil }
                return Self.requirement(record, stream: value.streams[entry.stream]!)
            }
        }
    }

    private static func requirement(_ record: Record, stream: Stream) -> IndexWorkRequirement {
        .init(paths: record.inputPaths,
            reconciliation: record.inputReconciliationPaths.union(record.requiresReconciliation ? record.entry.roots.union(stream.roots) : []),
            fullScan: record.requiresFullScan,
            unknownWork: (record.hasIndexWork && !record.requiresReconciliation && record.inputPaths.isEmpty && record.inputReconciliationPaths.isEmpty)
                || (record.requiresReconciliation && record.entry.roots.union(stream.roots).isEmpty),
            roots: record.entry.roots.union(stream.roots))
    }

    /// A metadata-only drain may publish history progress, but cannot prove that
    /// a file or wrapped stream has been reconciled.
    fileprivate func metadataOnlyEntries(_ entries: [Entry]) -> [Entry] {
        state.withLock { value in
            entries.compactMap { entry in
                guard let stream = value.streams[entry.stream], stream.initialized,
                      let record = stream.records[entry.id], record.entry.version == entry.version,
                      !record.hasIndexWork, !record.requiresReconciliation else { return nil }
                return record.entry
            }
        }
    }

    fileprivate func invalidateCoverage() -> [Entry] {
        state.withLock { value in
            value.revision &+= 1
            value.mutation &+= 1
            var entries: [Entry] = []
            for name in Array(value.streams.keys) {
                guard var stream = value.streams[name] else { continue }
                for key in Array(stream.records.keys) {
                    stream.records[key]?.covered = false
                    stream.records[key]?.owner = nil
                    stream.records[key]?.hasIndexWork = true
                    stream.records[key]?.inputReconciliationPaths.formUnion(stream.roots)
                    if let entry = stream.records[key]?.entry {
                        entries.append(.init(id: key, stream: name, epoch: entry.epoch,
                            version: entry.version, watermark: entry.watermark, roots: entry.roots.union(stream.roots)))
                    }
                }
                value.streams[name] = stream
            }
            return entries
        }
    }

    fileprivate func coverableEntries(paths changedPaths: Set<String>, reconciliationPaths: Set<String>, fullScan: Bool) -> [Entry] {
        let changed = Set(changedPaths.map(TraceFileIO.canonicalPath))
        let paths = reconciliationPaths.map(TraceFileIO.canonicalPath)
        let snapshot = state.withLock { $0.streams }
        return snapshot.values.flatMap { stream in
            stream.records.values.compactMap { record in
                guard stream.initialized,
                      Self.requirement(record, stream: stream).covered(paths: changed,
                        reconciliation: Set(paths), fullScan: fullScan, failures: []) else { return nil }
                return record.entry
            }
        }
    }

    fileprivate func begin(_ entries: [Entry], owner: UUID) -> Coverage {
        state.withLock { value in
            let current: [Entry] = entries.compactMap { entry in
                guard let stream = value.streams[entry.stream], stream.initialized,
                      let record = stream.records[entry.id], record.entry.version == entry.version else { return nil }
                value.streams[entry.stream]?.records[entry.id]?.owner = owner
                return record.entry
            }
            value.mutation &+= 1
            return Coverage(entries: current, owner: owner, revision: value.revision)
        }
    }

    fileprivate func accept(_ coverage: Coverage, failedPaths: Set<String>,
                            paths: Set<String> = [], reconciliationPaths: Set<String> = [],
                            failedReconciliationPaths: Set<String> = [], fullScan: Bool = false, contentGeneration: IndexContentGeneration? = nil) -> [String: IndexEventCheckpoint] {
        let changed = Set(paths.map(TraceFileIO.canonicalPath))
        let reconciled = Set(reconciliationPaths.map(TraceFileIO.canonicalPath))
        let fileFailures = Set(failedPaths.map(TraceFileIO.canonicalPath))
        let reconciliationFailures = Set(failedReconciliationPaths.map(TraceFileIO.canonicalPath))
        let failures = fileFailures.union(reconciliationFailures)
        // Sorting and root containment run on scheduler execution, outside the
        // lock used by main-actor event ingress. A conflicting reservation wins.
        for _ in 0..<3 {
            var snapshot = state.withLock { $0 }
            let mutation = snapshot.mutation
            guard snapshot.revision == coverage.revision else { return [:] }
            for entry in coverage.entries {
                guard let stream = snapshot.streams[entry.stream], stream.initialized,
                      stream.epoch == entry.epoch, var record = stream.records[entry.id],
                      record.owner == coverage.owner, record.entry.version == entry.version else { continue }
                let required = Self.requirement(record, stream: stream)
                if required.covered(paths: changed, reconciliation: reconciled, fullScan: fullScan, failures: failures) {
                    record.covered = true
                } else if !record.covered {
                    // A completed discovery can leave only individual failed
                    // files unpaid. Remember that coverage before a file retry;
                    // a reset failure never enters this accepted-result path.
                    let attempted = required.paths.filter { input in
                        fullScan || changed.contains(input) || reconciled.contains { $0.contains(input) }
                    }
                    let scanned = required.reconciliation.filter { input in
                        fullScan || reconciled.contains { $0.contains(input) }
                    }
                    let coversWhole = fullScan || !scanned.isEmpty
                    record.inputPaths.subtract(attempted.filter { input in !failures.contains { $0.intersects(input) } })
                    record.inputReconciliationPaths.subtract(scanned.filter { input in
                        !reconciliationFailures.contains { $0.intersects(input) }
                    })
                    if fullScan { record.requiresFullScan = false }
                    if coversWhole {
                        let scope = required.paths.union(required.reconciliation).union(required.roots)
                        let relevant: (TraceFileIO.CanonicalPath) -> Bool = { failure in
                            scope.isEmpty || scope.contains { $0.intersects(failure) }
                        }
                        record.inputPaths.formUnion(fileFailures.filter(relevant))
                        record.inputReconciliationPaths.formUnion(reconciliationFailures.filter(relevant))
                        if !required.reconciliation.isEmpty && record.inputReconciliationPaths.isEmpty {
                            record.requiresReconciliation = false
                        }
                    }
                    record.hasIndexWork = record.requiresFullScan || !record.inputPaths.isEmpty || !record.inputReconciliationPaths.isEmpty
                    // Unattempted unknown work must never become metadata-only.
                    if required.unknownWork && !fullScan && scanned.isEmpty { record.hasIndexWork = true }
                }
                snapshot.streams[entry.stream]?.records[entry.id] = record
            }
            var accepted: [String: IndexEventCheckpoint] = [:]
            for name in Array(snapshot.streams.keys) {
                guard var stream = snapshot.streams[name], stream.initialized else { continue }
                let barrier = stream.records.values.filter { !$0.covered }.map { $0.entry.watermark }.min()
                let prefix = stream.records.values.filter { $0.covered && (barrier == nil || $0.entry.watermark < barrier!) }
                if let mark = prefix.map({ $0.entry.watermark }).max(), stream.floor == nil || mark > stream.floor! {
                    stream.floor = mark
                    accepted[name] = .init(value: mark, epoch: stream.epoch,
                        replacingEpochs: stream.predecessors, contentGeneration: contentGeneration)
                }
                for record in prefix { stream.records.removeValue(forKey: record.entry.id) }
                if let tail = stream.tail, stream.records[tail] == nil { stream.tail = nil }
                let ordered = stream.records.values.sorted { $0.entry.watermark < $1.entry.watermark }
                var island: Record?
                for record in ordered {
                    guard record.covered else { island = nil; continue }
                    if let prior = island {
                        var combined = record
                        combined.entry = .init(id: record.entry.id, stream: name, epoch: record.entry.epoch,
                            version: record.entry.version, watermark: record.entry.watermark,
                            roots: record.entry.roots.union(prior.entry.roots))
                        combined.inputPaths.formUnion(prior.inputPaths)
                        combined.inputReconciliationPaths.formUnion(prior.inputReconciliationPaths)
                        stream.records.removeValue(forKey: prior.entry.id)
                        stream.records[record.entry.id] = combined
                        island = combined
                    } else { island = record }
                }
                snapshot.streams[name] = stream
            }
            snapshot.mutation &+= 1
            let next = snapshot
            let committed = state.withLock { value in
                guard value.mutation == mutation else { return false }
                value = next
                return true
            }
            if committed { return accepted }
        }
        // Concurrent ingress owns a newer snapshot. Its scheduled successor can
        // accept these still-unpaid records; never publish a speculative prefix.
        return [:]
    }

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
        let paths: Set<String>
        let reconciliationPaths: Set<String>
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
        pendingCheckpointReceipts = uniqueCheckpoints(pendingCheckpointReceipts + checkpointLedger.entries(reservations))
        if let onOrdinaryWorkCompleted {
            let required = IndexWorkRequirement(paths: Set(paths.map(TraceFileIO.canonicalPath)),
                reconciliation: Set(reconciliationPaths.map(TraceFileIO.canonicalPath)), fullScan: reconcile)
            pendingOrdinaryReceipts.append(OrdinaryReceipt(onOrdinaryWorkCompleted,
                requirements: [required] + checkpointLedger.requirements(checkpointLedger.entries(reservations))))
        }
        if rebuild {
            pendingResets.append(ResetReceipt(onCommit: onRebuildReset ?? {},
                onDeferred: onRebuildDeferred, automaticallyRetry: automaticallyRetryReset))
        }
        let scopeChanged = scope.map { $0 != self.scope } ?? false
        if scopeChanged { preservingDeferredScope = false; pendingUsesCommittedScope = false }
        if scopeChanged || rebuild {
            // A reset invalidates accepted-but-not-yet-durable coverage too.
            // Keep every stream's roots with the reset that must cover them.
            let retained = checkpointLedger.invalidateCoverage()
            pendingCheckpointReceipts = uniqueCheckpoints(pendingCheckpointReceipts + retained)
            for entry in retained {
                mergeWatermarks([entry.stream: entry.watermark])
                mergeCanonicalStreamRoots([entry.stream: entry.roots])
            }
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
        while !stopping && (hasPendingWork || ordinaryRecovery != nil || readyRetryIndex != nil) {
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
                let content = await coordinator.checkpointContentGeneration
                guard !stopping else { return }
                completeOrdinary(ordinary, paths: [], reconciliationPaths: [], fullScan: false, failures: [])
                let checkpointable = checkpointLedger.accept(checkpointLedger.begin(receipts, owner: installationID),
                    failedPaths: [], contentGeneration: content)
                await publishCheckpoints(checkpointable, activity: .fileChanges)
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
            batch.checkpointReceipts = uniqueCheckpoints(batch.checkpointReceipts + checkpointLedger.coverableEntries(
                paths: batch.paths, reconciliationPaths: batch.reconciliationPaths, fullScan: batch.fullScan))
            let checkpointCoverage = checkpointLedger.begin(batch.checkpointReceipts, owner: installationID)
            let execution = batch
            let forward: @Sendable (IndexProgress) async -> Void = { [weak self] update in
                await self?.forwardProgress(update, generation: execution.generation)
            }
            let operation = Task {
                if execution.usesCommittedScope && !execution.rebuild {
                    await coordinator.recoverOrdinaryResult(
                        paths: execution.fullScan ? nil : execution.paths,
                        reconciliationPaths: execution.fullScan ? [] : execution.reconciliationPaths, scope: execution.scope,
                        activity: execution.activity,
                        satisfiesSafetyReconciliation: execution.satisfiesSafetyReconciliation,
                        progress: forward
                    )
                } else if execution.fullScan {
                    await coordinator.indexAllResult(
                        scope: execution.scope, rebuild: execution.rebuild,
                        activity: execution.activity,
                        satisfiesSafetyReconciliation: execution.satisfiesSafetyReconciliation,
                        onRebuildReset: { for reset in execution.resets { reset.commit() } }, progress: forward
                    )
                } else if !execution.reconciliationPaths.isEmpty {
                    await coordinator.reconcile(
                        paths: execution.reconciliationPaths, changedPaths: execution.paths,
                        scope: execution.scope, activity: execution.activity,
                        satisfiesSafetyReconciliation: execution.satisfiesSafetyReconciliation,
                        progress: forward
                    )
                } else {
                    await coordinator.refreshResult(
                        paths: execution.paths, scope: execution.scope,
                        activity: execution.activity,
                        satisfiesSafetyReconciliation: execution.satisfiesSafetyReconciliation,
                        progress: forward
                    )
                }
            }
            self.operation = operation
            let result = await operation.value
            self.operation = nil
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
                let checkpointable = checkpointLedger.accept(checkpointCoverage,
                    failedPaths: result.failedPaths, paths: batch.paths,
                    reconciliationPaths: batch.reconciliationPaths,
                    failedReconciliationPaths: result.failedReconciliationPaths, fullScan: batch.fullScan,
                    contentGeneration: result.checkpointContentGeneration)
                await publishCheckpoints(checkpointable, activity: batch.activity)
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
    }
}
