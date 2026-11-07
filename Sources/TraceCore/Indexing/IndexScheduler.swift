import Clocks
import Foundation
import os

// BEGIN CHECKPOINT ACCEPTANCE MEASUREMENT
#if TRACE_CHECKPOINT_BENCHMARK
import Darwin
/// Enabled only in synchronized local benchmark builds. Control handshakes
/// occur outside these instrumented execution intervals.
public enum CheckpointAcceptanceBenchmark {
    struct Stamp { let start: ContinuousClock.Instant; let cpu: Double; let processCPU: Double; let thread: mach_port_t }
    private struct Samples { var elapsed = 0.0; var cpu = 0.0; var processCPU = 0.0; var calls = 0 }
    private static let samples = OSAllocatedUnfairLock(initialState: Samples())
    private static func cpuSeconds() -> Double {
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
    }
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func begin() -> Stamp { .init(start: .now, cpu: cpuSeconds(), processCPU: processCPUSeconds(), thread: pthread_mach_thread_np(pthread_self())) }
    static func end(_ stamp: Stamp) {
        precondition(stamp.thread == pthread_mach_thread_np(pthread_self()), "Acceptance must remain synchronous")
        let cpu = cpuSeconds() - stamp.cpu
        let processCPU = processCPUSeconds() - stamp.processCPU
        let duration = stamp.start.duration(to: .now).components
        let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        samples.withLock { $0.elapsed += elapsed; $0.cpu += cpu; $0.processCPU += processCPU; $0.calls += 1 }
    }
    public static func reset() { samples.withLock { $0 = Samples() } }
    public static func snapshot() -> [String: Double] {
        samples.withLock { ["elapsedSeconds": $0.elapsed, "cpuSeconds": $0.cpu, "processCPUSecondsDuringAcceptance": $0.processCPU, "acceptanceTurns": Double($0.calls)] }
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
        let watermark: UInt64
        let roots: Set<TraceFileIO.CanonicalPath>
    }
    fileprivate let ledger: UUID
    fileprivate let entries: [Entry]

    static func coalesced(_ reservations: [Self]) -> [Self] {
        var ledgers: [UUID: [UUID: Entry]] = [:]
        for reservation in reservations {
            for entry in reservation.entries {
                ledgers[reservation.ledger, default: [:]][entry.id] = entry
            }
        }
        return ledgers.map { .init(ledger: $0.key, entries: Array($0.value.values)) }
    }
}

/// Canonical reservation inputs prepared without enrolling work. Safe to build
/// off the delivery executor; reserve only after validating the delivery owner.
public struct IndexCheckpointInputs: Sendable {
    fileprivate struct Stream: Sendable {
        let mark: UInt64
        let roots: Set<TraceFileIO.CanonicalPath>
        let paths: Set<TraceFileIO.CanonicalPath>
        let reconciliation: Set<TraceFileIO.CanonicalPath>
        let epoch: IndexEventStreamEpoch?
    }
    fileprivate let streams: [String: Stream]
    fileprivate let wrapped: Set<String>
    fileprivate let unspecified: Bool
    public init(watermarks: [String: UInt64], streamRoots: [String: Set<String>],
                hasIndexWork: Bool, wrappedStreams: Set<String> = [],
                paths: Set<String> = [], reconciliationPaths: Set<String> = [],
                streamEpochs: [String: IndexEventStreamEpoch] = [:]) {
        self.init(watermarks: watermarks,
            canonicalStreamRoots: watermarks.isEmpty ? [:] : streamRoots.mapValues { Set($0.map(TraceFileIO.canonicalPath)) },
            hasIndexWork: hasIndexWork, wrappedStreams: wrappedStreams,
            canonicalPaths: watermarks.isEmpty ? [] : Set(paths.map(TraceFileIO.canonicalPath)),
            canonicalReconciliationPaths: watermarks.isEmpty ? [] : Set(reconciliationPaths.map(TraceFileIO.canonicalPath)),
            streamEpochs: streamEpochs)
    }
    /// Reuse immutable canonical identities from background content preparation.
    /// This overload performs no filesystem resolution and enrolls no work.
    public init(watermarks: [String: UInt64], canonicalStreamRoots roots: [String: Set<TraceFileIO.CanonicalPath>],
                hasIndexWork: Bool, wrappedStreams: Set<String> = [],
                canonicalPaths inputs: Set<TraceFileIO.CanonicalPath> = [],
                canonicalReconciliationPaths reconciliation: Set<TraceFileIO.CanonicalPath> = [],
                streamEpochs: [String: IndexEventStreamEpoch] = [:]) {
        var streams: [String: Stream] = [:]
        for (name, mark) in watermarks {
            let scope = roots[name] ?? []
            streams[name] = .init(mark: mark, roots: scope,
                paths: inputs.filter { input in scope.isEmpty || scope.contains { $0.intersects(input) } },
                reconciliation: reconciliation.filter { input in scope.isEmpty || scope.contains { $0.intersects(input) } },
                epoch: streamEpochs[name])
        }
        self.streams = streams
        self.wrapped = wrappedStreams
        self.unspecified = hasIndexWork && inputs.isEmpty && reconciliation.isEmpty
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
    fileprivate final class Readiness: Sendable {
        private struct State {
            var requested: UInt64 = 0, completed: UInt64 = 0
            var closed = false
            var waiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        let events: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        init() {
            let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            events = pair.stream; continuation = pair.continuation
        }
        func request() {
            let open = state.withLock { value in
                guard !value.closed else { return false }
                value.requested &+= 1; return true
            }
            if open { continuation.yield(()) }
        }
        var ticket: UInt64 { state.withLock { $0.requested } }
        var isSettled: Bool { state.withLock { $0.closed || $0.completed >= $0.requested } }
        func processed(_ ticket: UInt64) {
            let ready = state.withLock { value in
                value.completed = max(value.completed, ticket)
                let ready = value.waiters.filter { $0.0 <= value.completed }
                value.waiters.removeAll { $0.0 <= value.completed }
                return ready.map(\.1)
            }
            ready.forEach { $0.resume() }
        }
        func wait() async {
            await withCheckedContinuation { continuation in
                let done = state.withLock { value in
                    if value.closed || value.completed >= value.requested { return true }
                    value.waiters.append((value.requested, continuation)); return false
                }
                if done { continuation.resume() }
            }
        }
        func close() {
            let waiters = state.withLock { value in
                value.closed = true
                let waiters = value.waiters; value.waiters = []; return waiters.map(\.1)
            }
            continuation.finish(); waiters.forEach { $0.resume() }
        }
    }
    /// Only the latest outcome for an affected input is retained. Histories are
    /// needed solely while an older registered execution can still complete.
    private struct Outcomes: Sendable {
        var paths: [TraceFileIO.CanonicalPath: UInt64] = [:]
        var roots: [TraceFileIO.CanonicalPath: UInt64] = [:]
        var fullScan: UInt64 = 0
        func newer(than sequence: UInt64, path: TraceFileIO.CanonicalPath, root: Bool = false) -> Bool {
            fullScan > sequence || roots.contains { $0.value > sequence && $0.key.contains(path) }
                || (!root && (paths[path] ?? 0) > sequence)
        }
        mutating func prune(through sequence: UInt64) {
            paths = paths.filter { $0.value > sequence }
            roots = roots.filter { $0.value > sequence }
            if fullScan <= sequence { fullScan = 0 }
        }
        mutating func observe(_ proof: ExecutionProof, requirement: IndexWorkRequirement) {
            let sequence = proof.coverage.sequence
            if proof.fullScan {
                fullScan = max(fullScan, sequence)
                paths = paths.filter { $0.value > fullScan }; roots = roots.filter { $0.value > fullScan }
                return
            }
            let relevant = requirement.paths.union(requirement.reconciliation)
            for path in proof.paths where relevant.contains(where: { $0.intersects(path) }) || paths[path] != nil {
                if sequence > fullScan { paths[path] = max(paths[path] ?? 0, sequence) }
            }
            for root in proof.reconciliation where relevant.contains(where: { root.contains($0) }) || roots[root] != nil {
                if sequence > fullScan {
                    roots = roots.filter { !root.contains($0.key) || $0.value > sequence }
                    if !roots.contains(where: { $0.key.contains(root) && $0.value >= sequence }) { roots[root] = max(roots[root] ?? 0, sequence) }
                }
            }
        }
    }
    private final class Record: @unchecked Sendable {
        var entry: Entry
        var remaining: IndexWorkRequirement
        var outcomes = Outcomes()
        weak var previous: Record?
        var next: Record?
        var covered: Bool { !remaining.fullScan && !remaining.unknownWork && remaining.paths.isEmpty && remaining.reconciliation.isEmpty }
        init(entry: Entry, remaining: IndexWorkRequirement) { self.entry = entry; self.remaining = remaining }
    }
    /// Ordered unpaid boundaries and compact paid runs. A later reservation
    /// inside a paid run splits it conservatively at its known endpoints.
    private final class Frontier {
        private final class Node {
            let key: UInt64
            var upper: UInt64
            var unpaid: Int
            let priority = UInt64.random(in: .min ... .max)
            var left: Node?, right: Node?
            init(_ key: UInt64, upper: UInt64? = nil, unpaid: Int) { self.key = key; self.upper = upper ?? key; self.unpaid = unpaid }
        }
        private var root: Node?
        private(set) var count = 0
        private func floor(_ key: UInt64) -> Node? {
            var node = root, result: Node?
            while let current = node { if current.key <= key { result = current; node = current.right } else { node = current.left } }
            return result
        }
        private func successor(_ key: UInt64) -> Node? {
            var node = root, result: Node?
            while let current = node { if current.key > key { result = current; node = current.left } else { node = current.right } }
            return result
        }
        private static func merge(_ a: Node?, _ b: Node?) -> Node? {
            guard let a else { return b }; guard let b else { return a }
            if a.priority < b.priority { a.right = merge(a.right, b); return a }
            b.left = merge(a, b.left); return b
        }
        private static func insert(_ node: Node?, _ added: Node) -> Node {
            guard let node else { return added }
            if added.key < node.key {
                node.left = insert(node.left, added)
                if let child = node.left, child.priority < node.priority { node.left = child.right; child.right = node; return child }
            } else {
                node.right = insert(node.right, added)
                if let child = node.right, child.priority < node.priority { node.right = child.left; child.left = node; return child }
            }
            return node
        }
        private static func remove(_ node: Node?, _ key: UInt64) -> Node? {
            guard let node else { return nil }
            if key == node.key { return merge(node.left, node.right) }
            if key < node.key { node.left = remove(node.left, key) } else { node.right = remove(node.right, key) }
            return node
        }
        private func add(_ node: Node) { root = Self.insert(root, node); count += 1 }
        private func remove(_ key: UInt64) { root = Self.remove(root, key); count -= 1 }
        func reserve(_ value: UInt64) {
            if let prior = floor(value), prior.key == value, prior.unpaid > 0 { prior.unpaid += 1; return }
            if let prior = floor(value), prior.unpaid == 0, value <= prior.upper {
                let lower = prior.key, upper = prior.upper
                remove(lower)
                if lower < value { add(Node(lower, unpaid: 0)) }
                if upper > value { add(Node(upper, unpaid: 0)) }
            }
            add(Node(value, unpaid: 1))
        }
        func qualify(_ value: UInt64) {
            if let prior = floor(value) {
                if prior.unpaid == 0 {
                    prior.upper = max(prior.upper, value)
                    if let next = successor(prior.key), next.unpaid == 0 { prior.upper = max(prior.upper, next.upper); remove(next.key) }
                    return
                }
                if prior.key == value { return }
            }
            var upper = value
            if let next = successor(value), next.unpaid == 0 { upper = next.upper; remove(next.key) }
            add(Node(value, upper: upper, unpaid: 0))
        }
        func cover(_ value: UInt64) {
            guard let current = floor(value), current.key == value, current.unpaid > 0 else { return }
            current.unpaid -= 1
            guard current.unpaid == 0 else { return }
            remove(value)
            qualify(value)
        }
        func takePaidPrefix() -> UInt64? {
            var node = root
            while let left = node?.left { node = left }
            guard let first = node, first.unpaid == 0 else { return nil }
            let upper = first.upper; remove(first.key); return upper
        }
    }
    private final class Stream {
        var epoch = ""
        var predecessors: Set<String> = []
        var floor: UInt64?
        var roots: Set<TraceFileIO.CanonicalPath> = []
        var records: [UUID: Record] = [:]
        var outcomeCount = 0
        var frontier = Frontier()
        var highestQualification: UInt64?
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
    fileprivate struct Publication: Sendable {
        var updates: [String: IndexEventCheckpoint] = [:]
        var activity: IndexActivity = .fileChanges
    }
    private struct Registration {
        let listener: Readiness
        let order: UInt64
        let family: String
    }
    private final class ProofCursor {
        let proof: ExecutionProof
        var offset = 0
        init(_ proof: ExecutionProof) { self.proof = proof }
    }
    private struct State: @unchecked Sendable {
        var streams: [String: Stream] = [:]
        var listeners: [UUID: Registration] = [:]
        var registrationSequence: UInt64 = 0
        var drainOwner: UUID?
        var revision: UInt64 = 0
        var sequence: UInt64 = 0
        var proofs: [ProofCursor] = []
        var proofIDs: Set<UInt64> = []
        var executions: Set<UInt64> = []
        var traversals = 0
        var retired: [Record] = []
        var processing = false
        var fences: Set<UUID> = []
        var updates: [String: IndexEventCheckpoint] = [:]
        var content: IndexContentGeneration?
        var publicationActivity: IndexActivity = .fileChanges
        var prefixStreams: Set<String> = []
        var head: Record?
        var tail: Record?
    }
    #if DEBUG
    private let activationHook = OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
    func setActivationHookForTesting(_ hook: (@Sendable () async -> Void)?) { activationHook.withLock { $0 = hook } }
    fileprivate func takeActivationHookForTesting() -> (@Sendable () async -> Void)? {
        activationHook.withLock { value in let hook = value; value = nil; return hook }
    }
    private let acceptanceCommitHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    func setAcceptanceCommitHookForTesting(_ hook: (@Sendable () -> Void)?) { acceptanceCommitHook.withLock { $0 = hook } }
    #endif
    private let id = UUID()
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}
    fileprivate func registerReadiness(_ listener: Readiness, owner: UUID, content: IndexContentGeneration) {
        state.withLock { value in
            value.registrationSequence &+= 1
            value.listeners[owner] = .init(listener: listener, order: value.registrationSequence,
                                           family: content.databaseFamily)
            value.drainOwner = owner
        }
    }
    fileprivate func unregisterReadiness(_ owner: UUID) {
        let retired = state.withLock { value -> (Readiness?, Readiness?) in
            let listener = value.listeners.removeValue(forKey: owner)?.listener
            guard value.drainOwner == owner else { return (listener, nil) }
            let next = value.listeners.filter { value.content == nil || $0.value.family == value.content?.databaseFamily }
                .max { $0.value.order < $1.value.order }
            value.drainOwner = next?.key
            return (listener, next?.value.listener)
        }
        retired.0?.close()
        // Displaced listeners remain dormant and weakly reference their scheduler.
        // Handback is a registered wakeup; idle waiting never initiates this work.
        retired.1?.request()
    }
    fileprivate func isDrainOwner(_ owner: UUID) -> Bool { state.withLock { $0.drainOwner == owner } }
    private func signalReadiness() {
        let listener = state.withLock { value in value.drainOwner.flatMap { value.listeners[$0]?.listener } }
        listener?.request()
    }
    deinit {
        // Every node is still retained by a dictionary/retirement array while
        // links are detached, so ARC never recursively destroys a long chain.
        state.withLock { value in
            for stream in value.streams.values { for record in stream.records.values { record.next = nil } }
            for record in value.retired { record.next = nil }
            value.head = nil; value.tail = nil; value.retired.removeAll()
        }
    }

    public func seed(stream name: String, checkpoint: IndexEventCheckpoint?) {
        let changed = state.withLock { value in
            let stream = value.streams[name] ?? Stream()
            guard !stream.initialized else { return false }
            let sameStoredEpoch = stream.predecessors.isEmpty
            if sameStoredEpoch {
                stream.epoch = checkpoint?.epoch ?? UUID().uuidString
                stream.predecessors = checkpoint == nil ? ["legacy"] : []
                stream.floor = checkpoint?.value
            } else {
                stream.epoch = UUID().uuidString
                stream.predecessors = [checkpoint?.epoch ?? "legacy"]
            }
            if value.content == nil { value.content = checkpoint?.contentGeneration }
            if sameStoredEpoch, let mark = checkpoint?.value { stream.highestQualification = max(stream.highestQualification ?? 0, mark) }
            stream.initialized = true; stream.initializationFailed = false
            value.streams[name] = stream
            value.prefixStreams.insert(name)
            return true
        }
        if changed { signalReadiness() }
    }
    fileprivate var uninitializedStreams: Set<String> {
        state.withLock { Set($0.streams.filter { !$0.value.initialized && !$0.value.initializationFailed }.keys) }
    }
    fileprivate var pausedStreams: Set<String> { state.withLock { Set($0.streams.filter { $0.value.initializationFailed }.keys) } }
    fileprivate func resumeInitialization(owner: UUID) {
        state.withLock { value in
            guard value.drainOwner == owner else { return }
            for stream in value.streams.values { stream.initializationFailed = false }
        }
    }
    fileprivate func pauseInitialization(_ stream: String) { state.withLock { $0.streams[stream]?.initializationFailed = true } }
    #if DEBUG
    func initializationForTesting(stream: String) -> (initialized: Bool, epoch: String?, floor: UInt64?) {
        state.withLock { let item = $0.streams[stream]; return (item?.initialized == true, item?.initialized == true ? item?.epoch : nil, item?.floor) }
    }
    struct ProofForTesting: Sendable { fileprivate let value: ExecutionProof }
    func prepareProofForTesting(_ reservations: [IndexCheckpointReservation], paths: Set<String> = [],
                               reconciliation: Set<String> = [], failures: Set<String> = [],
                               fullScan: Bool = false, content: IndexContentGeneration, activity: IndexActivity = .fileChanges,
                               allCoverable: Bool = false) -> ProofForTesting {
        let selected = allCoverable ? coverableEntries(paths: [], reconciliationPaths: [], fullScan: fullScan) : entries(reservations)
        return .init(value: .init(coverage: begin(selected, owner: UUID()),
            paths: Set(paths.map(TraceFileIO.canonicalPath)), reconciliation: Set(reconciliation.map(TraceFileIO.canonicalPath)),
            failures: Set(failures.map(TraceFileIO.canonicalPath)), reconciliationFailures: [], fullScan: fullScan,
            content: content, scope: .proseOnly, activity: activity))
    }
    func retainProofForTesting(_ proof: ProofForTesting) { retain(proof.value) }
    func drainProofsForTesting(content: IndexContentGeneration) -> [String: IndexEventCheckpoint] {
        var updates: [String: IndexEventCheckpoint] = [:]
        for _ in 0..<1_000 {
            if !hasReadyProofs { break }
            updates.merge(drainProofs(scope: .proseOnly, content: content).updates, uniquingKeysWith: { _, last in last })
        }
        return updates
    }
    func remainingPathsForTesting(_ reservations: [IndexCheckpointReservation]) -> Set<String> {
        Set(requirements(entries(reservations)).flatMap { $0.paths.map(\.path) })
    }
    var retainedProofCountForTesting: Int { state.withLock { $0.proofs.count } }
    var retainedOutcomeCountForTesting: Int { retainedCounts.outcomes }
    var paidBoundaryCountForTesting: Int { retainedCounts.prefixEntries }
    var outcomeCountsAreConsistentForTesting: Bool {
        state.withLock { $0.streams.values.allSatisfy { stream in
            stream.outcomeCount == stream.records.values.reduce(0) { $0 + Self.outcomeCount($1.outcomes) }
        } }
    }
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
        reserve(IndexCheckpointInputs(watermarks: watermarks, streamRoots: streamRoots,
            hasIndexWork: hasIndexWork, wrappedStreams: wrappedStreams, paths: paths,
            reconciliationPaths: reconciliationPaths, streamEpochs: streamEpochs))
    }
    public func reserve(_ prepared: IndexCheckpointInputs) -> IndexCheckpointReservation {
        return state.withLock { value in
            var entries: [Entry] = []
            for (name, input) in prepared.streams {
                let mark = input.mark
                let stream = value.streams[name] ?? Stream()
                value.streams[name] = stream
                let incoming = input.epoch
                if let incoming, stream.ingressEpoch?.predecessors.contains(incoming.id) == true { continue }
                let same = incoming != nil && incoming == stream.ingressEpoch
                let descends = incoming.map { next in stream.ingressEpoch.map { next.predecessors.contains($0.id) } ?? !next.predecessors.isEmpty } ?? false
                // Unrelated watcher lineages cannot replace a known epoch merely
                // because they wrapped sometime in their own history.
                let wrap = descends || (prepared.wrapped.contains(name) && !same)
                if wrap {
                    stream.predecessors.insert(stream.epoch.isEmpty ? "legacy" : stream.epoch)
                    stream.epoch = stream.initialized ? UUID().uuidString : ""
                    stream.floor = nil
                    for record in stream.records.values { Self.unlink(record, state: &value) }
                    stream.records.removeAll(); stream.outcomeCount = 0
                    stream.frontier = Frontier(); stream.highestQualification = nil
                    value.updates[name] = nil
                }
                if let incoming { stream.ingressEpoch = incoming }
                let qualification = input.roots
                stream.roots.formUnion(qualification)
                stream.highestQualification = max(stream.highestQualification ?? 0, mark)
                // Qualification grows independently of immutable work. In-flight
                // executions keep the same obligation and covered work stays paid.
                let key = UUID()
                let entry = Entry(id: key, stream: name, epoch: stream.epoch, watermark: mark, roots: qualification)
                let requirement = IndexWorkRequirement(paths: input.paths,
                    reconciliation: input.reconciliation.union((wrap || prepared.wrapped.contains(name)) ? stream.roots : []),
                    fullScan: prepared.unspecified && !wrap && !prepared.wrapped.contains(name),
                    unknownWork: (wrap || prepared.wrapped.contains(name)) && stream.roots.isEmpty, roots: qualification)
                if !requirement.fullScan, !requirement.unknownWork, requirement.paths.isEmpty, requirement.reconciliation.isEmpty {
                    stream.frontier.qualify(mark)
                    value.prefixStreams.insert(name)
                    continue
                }
                let record = Record(entry: entry, remaining: requirement)
                stream.records[key] = record
                record.previous = value.tail
                value.tail?.next = record
                if value.head == nil { value.head = record }
                value.tail = record
                stream.frontier.reserve(mark)
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
    fileprivate func fenceReset(_ token: UUID) { state.withLock { $0.fences.insert(token) } }
    fileprivate func releaseReset(_ token: UUID) {
        let removed = state.withLock { $0.fences.remove(token) != nil }
        if removed, !isDrainOwner(token) { signalReadiness() }
    }
    /// Called synchronously from the database's committed-reset callback.
    fileprivate func committedReset(content: IndexContentGeneration, extending coverage: Coverage) -> Coverage {
        state.withLock { value in
            Self.resetRecords(content: content, state: &value)
            // The scan begins after commitment: include every obligation that
            // arrived before that boundary, including ingress during preparation.
            value.sequence &+= 1
            value.executions.insert(value.sequence)
            return Coverage(entries: value.streams.values.flatMap { $0.records.values.map(\.entry) },
                owner: coverage.owner, revision: value.revision, sequence: value.sequence)
        }
    }
    private static func resetRecords(content: IndexContentGeneration, state value: inout State) {
        value.revision &+= 1; value.content = content
        value.proofs.removeAll(); value.proofIDs.removeAll(); value.executions.removeAll(); value.updates.removeAll()
        for (name, stream) in value.streams {
            stream.frontier = Frontier()
            // clearIndex deletes durable checkpoints too. Preserve their last
            // qualification as reset-owned debt even when no records remained.
            if let floor = stream.highestQualification, !stream.records.values.contains(where: { $0.entry.watermark == floor }) {
                let key = UUID(), roots = stream.roots
                let entry = Entry(id: key, stream: name, epoch: stream.epoch, watermark: floor, roots: roots)
                let record = Record(entry: entry, remaining: .init(reconciliation: roots, fullScan: roots.isEmpty, roots: roots))
                stream.records[key] = record
                record.previous = value.tail; value.tail?.next = record
                if value.head == nil { value.head = record }
                value.tail = record
            }
            stream.floor = nil; stream.outcomeCount = 0
            for record in stream.records.values {
                let roots = record.entry.roots.union(stream.roots)
                record.remaining.roots.formUnion(roots)
                record.remaining.reconciliation.formUnion(roots)
                if roots.isEmpty { record.remaining.fullScan = true }
                record.outcomes = Outcomes()
                stream.frontier.reserve(record.entry.watermark)
            }
            value.prefixStreams.insert(name)
        }
    }
    fileprivate func synchronizeContext(content: IndexContentGeneration, owner: UUID? = nil) {
        state.withLock { value in
            guard owner == nil || value.drainOwner == owner else { return }
            if let prior = value.content, prior != content { Self.resetRecords(content: content, state: &value) }
            else { value.content = content }
        }
    }
    fileprivate func coverableEntries(paths changed: Set<TraceFileIO.CanonicalPath>, reconciliationPaths scanned: Set<TraceFileIO.CanonicalPath>, fullScan: Bool) -> [Entry] {
        // Capture bounded descriptor chunks. Ingress never copies a shared
        // record dictionary and never waits on a whole-ledger scan or sort.
        let endpoints = state.withLock { value in value.traversals += 1; return (value.head, value.tail) }
        defer {
            state.withLock { value in
                value.traversals -= 1
                if value.traversals == 0 {
                    for record in value.retired { record.next = nil }
                    value.retired.removeAll()
                }
            }
        }
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
        record.previous = nil
        if state.traversals > 0 { state.retired.append(record) }
        else { record.next = nil }
    }
    private static func pay(_ record: Record, stream: Stream, state: inout State) {
        stream.frontier.cover(record.entry.watermark)
        unlink(record, state: &state)
        stream.outcomeCount -= Self.outcomeCount(record.outcomes)
        stream.records.removeValue(forKey: record.entry.id)
    }
    fileprivate func begin(_ entries: [Entry], owner: UUID) -> Coverage {
        state.withLock { value in
            value.sequence &+= 1
            value.executions.insert(value.sequence)
            return .init(entries: entries.filter { value.streams[$0.stream]?.records[$0.id] != nil },
                owner: owner, revision: value.revision, sequence: value.sequence)
        }
    }
    fileprivate func finishExecution(_ coverage: Coverage) {
        state.withLock { _ = $0.executions.remove(coverage.sequence) }
    }
    fileprivate func retain(_ proof: ExecutionProof) {
        let retained = state.withLock { value in
            guard proof.coverage.revision == value.revision, value.proofIDs.insert(proof.coverage.sequence).inserted else { return false }
            value.proofs.append(ProofCursor(proof)); return true
        }
        if retained { signalReadiness() }
    }
    fileprivate func returnUnpublished(_ publication: Publication) {
        guard !publication.updates.isEmpty else { return }
        let accepted = state.withLock { value in
            var accepted = false
            for (stream, update) in publication.updates where value.streams[stream]?.epoch == update.epoch
                && (update.contentGeneration == nil || update.contentGeneration == value.content) {
                if value.updates[stream].map({ $0.value <= update.value }) ?? true {
                    value.updates[stream] = update; accepted = true
                }
            }
            if accepted { value.publicationActivity = IndexActivity.moreSignificant(value.publicationActivity, publication.activity) }
            return accepted
        }
        if accepted { signalReadiness() }
    }
    fileprivate var hasCompletedProofs: Bool { state.withLock { !$0.proofs.isEmpty } }
    fileprivate var hasReadyProofs: Bool {
        state.withLock { value in
            !value.processing && (!value.proofs.isEmpty || (value.fences.isEmpty && (!value.updates.isEmpty || value.prefixStreams.contains { value.streams[$0]?.initialized == true })))
        }
    }
    /// One bounded worker turn. Reentrant ingress never invalidates unrelated
    /// computation. Only reset/epoch retirement can discard the captured records.
    fileprivate func drainProofs(scope: IndexScope, content: IndexContentGeneration, owner: UUID? = nil) -> Publication {
        synchronizeContext(content: content, owner: owner)
        #if TRACE_CHECKPOINT_BENCHMARK
        let measurement = CheckpointAcceptanceBenchmark.begin()
        defer { CheckpointAcceptanceBenchmark.end(measurement) }
        #endif
        struct Item { let entry: Entry; let remaining: IndexWorkRequirement; let outcomes: Outcomes }
        let work: (ExecutionProof, [Item])? = state.withLock { value in
            guard owner == nil || value.drainOwner == owner,
                  !value.processing, let cursor = value.proofs.first else { return nil }
            let proof = cursor.proof
            guard proof.coverage.revision == value.revision, proof.scope == scope,
                  proof.content == nil || proof.content == content else {
                value.proofs.removeFirst(); value.proofIDs.remove(proof.coverage.sequence); value.executions.remove(proof.coverage.sequence); return nil
            }
            value.processing = true
            value.publicationActivity = IndexActivity.moreSignificant(value.publicationActivity, proof.activity)
            let end = min(cursor.offset + 128, proof.coverage.entries.count)
            let items = proof.coverage.entries[cursor.offset..<end].compactMap { entry -> Item? in
                guard let record = value.streams[entry.stream]?.records[entry.id] else { return nil }
                return .init(entry: entry, remaining: record.remaining, outcomes: record.outcomes)
            }
            cursor.offset = end
            return (proof, items)
        }
        if let (proof, items) = work {
            let sequence = proof.coverage.sequence
            let oldest = state.withLock { $0.executions.min() ?? .max }
            func covers(_ path: TraceFileIO.CanonicalPath, root: Bool = false) -> Bool {
                proof.fullScan || proof.reconciliation.contains { $0.contains(path) } || (!root && proof.paths.contains(path))
            }
            let allFailures = proof.failures.union(proof.reconciliationFailures)
            let results = items.map { item -> (Entry, IndexWorkRequirement, Outcomes) in
                var remaining = item.remaining
                if !remaining.fullScan, !remaining.unknownWork, remaining.paths.isEmpty, remaining.reconciliation.isEmpty {
                    return (item.entry, remaining, item.outcomes)
                }
                func newer(_ path: TraceFileIO.CanonicalPath, root: Bool = false) -> Bool {
                    item.outcomes.newer(than: sequence, path: path, root: root)
                }
                remaining.paths = remaining.paths.filter { input in
                    newer(input) || !covers(input) || allFailures.contains { $0.intersects(input) }
                }
                remaining.reconciliation = remaining.reconciliation.filter { input in
                    newer(input, root: true) || !covers(input, root: true) || proof.reconciliationFailures.contains { $0.intersects(input) }
                }
                if proof.fullScan, item.outcomes.fullScan <= sequence {
                    remaining.fullScan = false; remaining.unknownWork = false
                }
                let attemptedRoots = item.remaining.reconciliation.filter { covers($0, root: true) }
                let wholeRequirement = proof.fullScan && (item.remaining.fullScan || item.remaining.unknownWork)
                if wholeRequirement || !attemptedRoots.isEmpty {
                    let scope = wholeRequirement
                        ? item.remaining.roots
                        : attemptedRoots
                    func relevant(_ failure: TraceFileIO.CanonicalPath) -> Bool {
                        !newer(failure) && covers(failure) && (scope.isEmpty || scope.contains { $0.intersects(failure) })
                    }
                    remaining.paths.formUnion(proof.failures.filter(relevant))
                    remaining.reconciliation.formUnion(proof.reconciliationFailures.filter(relevant))
                }
                var outcomes = item.outcomes
                outcomes.observe(proof, requirement: item.remaining)
                outcomes.prune(through: oldest)
                return (item.entry, remaining, outcomes)
            }
            #if DEBUG
            acceptanceCommitHook.withLock { $0 }?()
            #endif
            state.withLock { value in
                defer { value.processing = false }
                guard proof.coverage.revision == value.revision else { return }
                for (entry, remaining, outcomes) in results {
                    guard let stream = value.streams[entry.stream], let record = stream.records[entry.id] else { continue }
                    stream.outcomeCount += Self.outcomeCount(outcomes) - Self.outcomeCount(record.outcomes)
                    record.remaining = remaining; record.outcomes = outcomes
                    if record.covered { Self.pay(record, stream: stream, state: &value) }
                    value.prefixStreams.insert(entry.stream)
                }
                if let cursor = value.proofs.first, cursor.proof.coverage.sequence == proof.coverage.sequence,
                   cursor.offset == proof.coverage.entries.count {
                    value.proofs.removeFirst(); value.proofIDs.remove(proof.coverage.sequence); value.executions.remove(proof.coverage.sequence)
                }
            }
        }
        if work != nil, let owner, !isDrainOwner(owner) { signalReadiness() }
        return state.withLock { value in
            guard owner == nil || value.drainOwner == owner,
                  !value.processing, value.fences.isEmpty else { return .init() }
            var budget = 128
            for name in Array(value.prefixStreams) where budget > 0 {
                guard let stream = value.streams[name], stream.initialized else { continue }
                while budget > 0, let mark = stream.frontier.takePaidPrefix() {
                    if stream.floor == nil || mark > stream.floor! {
                        stream.floor = mark
                        value.updates[name] = .init(value: mark, epoch: stream.epoch,
                            replacingEpochs: stream.predecessors, contentGeneration: content)
                    }
                    budget -= 1
                }
                if budget > 0 { value.prefixStreams.remove(name) }
            }
            guard value.fences.isEmpty, value.proofs.isEmpty,
                  !value.prefixStreams.contains(where: { value.streams[$0]?.initialized == true }) else { return .init() }
            let publication = Publication(updates: value.updates, activity: value.publicationActivity)
            value.updates = [:]; value.publicationActivity = .fileChanges
            return publication
        }
    }
    private static func outcomeCount(_ outcomes: Outcomes) -> Int {
        outcomes.paths.count + outcomes.roots.count + (outcomes.fullScan == 0 ? 0 : 1)
    }
    #if DEBUG || TRACE_CHECKPOINT_BENCHMARK
    private struct RetainedCounts {
        var records = 0, proofs = 0, outcomes = 0, prefixEntries = 0
    }
    private var retainedCounts: RetainedCounts {
        state.withLock { value in
            var result = RetainedCounts(proofs: value.proofs.count)
            for stream in value.streams.values {
                result.records += stream.records.count
                result.prefixEntries += stream.frontier.count
                result.outcomes += stream.outcomeCount
            }
            return result
        }
    }
    var retainedRecordCount: Int { state.withLock { $0.streams.values.reduce(0) { $0 + $1.records.count } } }
    #endif
    #if TRACE_CHECKPOINT_BENCHMARK
    public var checkpointBenchmarkPrefixIndexEntryKind: String { "frontier-node" }
    public var checkpointBenchmarkCounts: [String: Int] {
        let counts = retainedCounts
        return ["records": counts.records, "proofs": counts.proofs, "outcomes": counts.outcomes,
            "prefixIndexEntries": counts.prefixEntries]
    }
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
    private let readiness = IndexCheckpointLedger.Readiness()
    private let readinessTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let pausedCheckpointStreamsChanged: (@Sendable (Set<String>) async -> Void)?
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
    private var operation: Task<IndexCoordinator.ScheduledExecutionResult, Never>?
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
    private var checkpointPublicationHookForTesting: (@Sendable () async -> Void)?
    func setCheckpointPublicationHookForTesting(_ hook: (@Sendable () async -> Void)?) { checkpointPublicationHookForTesting = hook }
    private var deferredCheckpointAcceptanceHookForTesting: (@Sendable () async -> Void)?
    func setDeferredCheckpointAcceptanceHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        deferredCheckpointAcceptanceHookForTesting = hook
    }
    /// Execute the synchronous acceptance boundary on a dedicated test queue,
    /// so a deliberately blocked commit never occupies the cooperative pool.
    nonisolated func drainCheckpointProofOnQueueForTesting() async {
        let ledger = checkpointLedger, owner = installationID, context = coordinator.checkpointContext
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "Trace.checkpoint-test-acceptance").async {
                let publication = ledger.drainProofs(scope: context.scope, content: context.generation, owner: owner)
                ledger.returnUnpublished(publication)
                continuation.resume()
            }
        }
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
            checkpointLedger: IndexCheckpointLedger(), didCompleteCheckpoints: nil, pausedStreamsChanged: nil)
    }

    public init(coordinator: IndexCoordinator, scope: IndexScope,
                progress: @escaping @Sendable (IndexProgress) async -> Void,
                retryDelay: Duration = .seconds(5),
                clock: any Clock<Duration> = ContinuousClock(),
                didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void = { _, _ in },
                didSatisfySafetyReconciliation: @escaping @Sendable () async -> Void = {},
                checkpointLedger: IndexCheckpointLedger,
                didCompleteCheckpoints: (@Sendable ([String: IndexEventCheckpoint]) async -> Void)? = nil) {
        self.init(coordinator: coordinator, scope: scope, progress: progress,
            retryDelay: retryDelay, clock: clock, didComplete: didComplete,
            didSatisfySafetyReconciliation: didSatisfySafetyReconciliation,
            checkpointLedger: checkpointLedger, didCompleteCheckpoints: didCompleteCheckpoints, pausedStreamsChanged: nil)
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
            checkpointLedger: checkpointLedger, didCompleteCheckpoints: didCompleteCheckpoints,
            pausedStreamsChanged: didChangePausedCheckpointStreams)
    }

    private init(coordinator: IndexCoordinator, scope: IndexScope,
                 progress: @escaping @Sendable (IndexProgress) async -> Void,
                 retryDelay: Duration, clock: any Clock<Duration>,
                 didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void,
                 didSatisfySafetyReconciliation: @escaping @Sendable () async -> Void,
                 checkpointLedger: IndexCheckpointLedger,
                 didCompleteCheckpoints: (@Sendable ([String: IndexEventCheckpoint]) async -> Void)?,
                 pausedStreamsChanged: (@Sendable (Set<String>) async -> Void)?) {
        self.checkpointLedger = checkpointLedger
        self.qualifiedCompletion = didCompleteCheckpoints
        self.coordinator = coordinator
        self.scope = scope
        self.retryDelay = retryDelay
        self.clock = AnyClock(clock)
        self.progress = progress
        self.didComplete = didComplete
        self.didSatisfySafetyReconciliation = didSatisfySafetyReconciliation
        self.pausedCheckpointStreamsChanged = pausedStreamsChanged
        let readiness = readiness, taskHolder = readinessTask
        checkpointLedger.registerReadiness(readiness, owner: installationID, content: coordinator.checkpointContentGeneration)
        checkpointLedger.synchronizeContext(content: coordinator.checkpointContentGeneration, owner: installationID)
        checkpointLedger.resumeInitialization(owner: installationID)
        readiness.request()
        #if DEBUG
        let activationHook = checkpointLedger.takeActivationHookForTesting()
        #endif
        taskHolder.withLock { $0 = Task { [weak self] in
            #if DEBUG
            await activationHook?()
            #endif
            for await _ in readiness.events {
                let ticket = readiness.ticket
                await self?.resumeCompletedProofs()
                readiness.processed(ticket)
            }
        } }
    }

    deinit {
        checkpointLedger.unregisterReadiness(installationID)
        readinessTask.withLock { $0?.cancel() }
    }

    private var hasPendingPausedCheckpointNotice: Bool {
        let paused = checkpointLedger.pausedStreams
        return publishedPausedCheckpointStreams.map { $0 != paused } ?? !paused.isEmpty
    }

    private func resumeCompletedProofs() {
        guard !stopping, checkpointLedger.isDrainOwner(installationID), worker == nil,
              checkpointLedger.hasReadyProofs || !checkpointLedger.uninitializedStreams.isEmpty || hasPendingPausedCheckpointNotice else { return }
        worker = Task { await drain() }
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
        while !stopping && (hasPendingWork || !pendingOrdinaryReceipts.isEmpty || (checkpointLedger.isDrainOwner(installationID) && !checkpointLedger.uninitializedStreams.isEmpty) || ordinaryRecovery != nil || readyRetryIndex != nil
            || (checkpointLedger.isDrainOwner(installationID) && (checkpointLedger.hasReadyProofs || hasPendingPausedCheckpointNotice))) {
            await drainCheckpointProofs()
            guard !stopping else { return }
            for stream in checkpointLedger.uninitializedStreams.sorted() where checkpointLedger.isDrainOwner(installationID) {
                do {
                    let record = try await coordinator.checkpointRecord(stream: stream)
                    guard !stopping else { return }
                    guard checkpointLedger.isDrainOwner(installationID) else { break }
                    checkpointLedger.seed(stream: stream, checkpoint: record)
                } catch {
                    guard !stopping else { return }
                    if checkpointLedger.isDrainOwner(installationID) { checkpointLedger.pauseInitialization(stream) }
                }
            }
            guard !stopping else { return }
            let paused = checkpointLedger.pausedStreams
            if checkpointLedger.isDrainOwner(installationID), publishedPausedCheckpointStreams != paused {
                publishedPausedCheckpointStreams = paused
                await pausedCheckpointStreamsChanged?(paused)
                guard !stopping else { return }
            }
            // Fresh work always wins over a delayed retry, so a bad source cannot
            // starve later filesystem events.
            let retrying = !hasPendingIndexWork && ordinaryRecovery == nil && readyRetryIndex != nil
            if !retrying, ordinaryRecovery == nil, !fullScan, pendingResets.isEmpty, pendingPaths.isEmpty, pendingReconciliationPaths.isEmpty,
               pendingActivity == nil {
                let ordinary = pendingOrdinaryReceipts
                pendingOrdinaryReceipts.removeAll()
                pendingCheckpointReceipts.removeAll()
                pendingWatermarks.removeAll()
                pendingStreamRoots.removeAll()
                guard !stopping else { return }
                completeOrdinary(ordinary, paths: [], reconciliationPaths: [], fullScan: false, failures: [])
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
            checkpointLedger.synchronizeContext(content: coordinator.checkpointContentGeneration)
            batch.checkpointReceipts = uniqueCheckpoints(batch.checkpointReceipts + checkpointLedger.coverableEntries(
                paths: canonicalPaths, reconciliationPaths: canonicalReconciliation, fullScan: batch.fullScan))
            let checkpointCoverage = checkpointLedger.begin(batch.checkpointReceipts, owner: installationID)
            let resetCoverage = OSAllocatedUnfairLock<IndexCheckpointLedger.Coverage?>(initialState: nil)
            let ledger = checkpointLedger
            let execution = batch
            let forward: @Sendable (IndexProgress) async -> Void = { [weak self] update in
                await self?.forwardProgress(update, generation: execution.generation)
            }
            let operation = Task {
                await coordinator.executeScheduled(paths: execution.paths, reconciliationPaths: execution.reconciliationPaths,
                    canonicalPaths: canonicalPaths, canonicalReconciliation: canonicalReconciliation, fullScan: execution.fullScan, rebuild: execution.rebuild,
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
            let executionResult = await operation.value
            let result = executionResult.progress
            self.operation = nil
            // Proof transfer precedes stop/replacement checks. A complete pass is
            // database-owned even if its scheduler is being retired.
            let committedCoverage = resetCoverage.withLock { $0 }
            let performedFullScan = executionResult.performedFullScan
            if result.phase == .complete {
                let coverage = committedCoverage ?? checkpointCoverage
                checkpointLedger.retain(.init(coverage: coverage, paths: canonicalPaths,
                    reconciliation: canonicalReconciliation,
                    failures: Set(result.failedPaths.map(TraceFileIO.canonicalPath)),
                    reconciliationFailures: Set(result.failedReconciliationPaths.map(TraceFileIO.canonicalPath)),
                    fullScan: performedFullScan, content: result.checkpointContentGeneration, scope: result.checkpointScope ?? batch.scope, activity: batch.activity))
            }
            if result.phase != .complete {
                checkpointLedger.finishExecution(committedCoverage ?? checkpointCoverage)
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
                    reconciliationPaths: batch.reconciliationPaths, fullScan: performedFullScan,
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
        while !stopping && checkpointLedger.isDrainOwner(installationID) && checkpointLedger.hasReadyProofs {
            #if DEBUG
            if checkpointLedger.hasCompletedProofs { await deferredCheckpointAcceptanceHookForTesting?() }
            guard !stopping else { return }
            #endif
            let context = coordinator.checkpointContext
            let publication = checkpointLedger.drainProofs(scope: context.scope, content: context.generation, owner: installationID)
            #if DEBUG
            if !publication.updates.isEmpty { await checkpointPublicationHookForTesting?() }
            #endif
            await publishCheckpoints(publication)
            await Task.yield()
        }
    }

    private func publishCheckpoints(_ publication: IndexCheckpointLedger.Publication) async {
        guard !stopping, checkpointLedger.isDrainOwner(installationID), !publication.updates.isEmpty else {
            checkpointLedger.returnUnpublished(publication)
            return
        }
        if let qualifiedCompletion { await qualifiedCompletion(publication.updates) }
        else { await didComplete(publication.activity, publication.updates.mapValues(\.value)) }
    }

    private func uniqueCheckpoints(_ receipts: [CheckpointReceipt]) -> [CheckpointReceipt] {
        var newest: [UUID: CheckpointReceipt] = [:]
        for receipt in receipts {
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
    public func checkpointBenchmarkPrefixIndexEntryKind() -> String { checkpointLedger.checkpointBenchmarkPrefixIndexEntryKind }
    #endif

    public func waitUntilIdle() async {
        while true {
            await readiness.wait()
            if let worker { await worker.value; continue }
            if readiness.isSettled { return }
        }
    }

    public func stop() async {
        stopping = true
        checkpointLedger.unregisterReadiness(installationID)
        readinessTask.withLock { $0?.cancel() }
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
        if let task = readinessTask.withLock({ $0 }) { await task.value }
        readinessTask.withLock { $0 = nil }
        await worker?.value
        checkpointLedger.releaseReset(installationID)
    }
}
