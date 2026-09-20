import Foundation

/// All app indexing requests enter here. Events arriving during a pass are merged for its successor.
public actor IndexScheduler {
    private struct Batch: Sendable {
        let fullScan: Bool
        let rebuild: Bool
        let paths: Set<String>
        let reconciliationPaths: Set<String>
        let watermarks: [String: UInt64]
        let scope: IndexScope
        let activity: IndexActivity
        let retryAttempt: Int
        let generation: UInt64
    }

    private let coordinator: IndexCoordinator
    private let progress: @Sendable (IndexProgress) async -> Void
    private let didComplete: @Sendable (IndexActivity, [String: UInt64]) async -> Void
    private let retryDelay: Duration
    private var scope: IndexScope
    private var pendingPaths: Set<String> = []
    private var pendingReconciliationPaths: Set<String> = []
    private var pendingWatermarks: [String: UInt64] = [:]
    private var pendingActivity: IndexActivity?
    private var fullScan = false
    private var rebuild = false
    private var worker: Task<Void, Never>?
    private var operation: Task<IndexProgress, Never>?
    private var retryBatch: Batch?
    private var retryReady = false
    private var dormantBatch: Batch?
    private var retryTask: Task<Void, Never>?
    private var configurationGeneration: UInt64 = 0
    private var stopping = false

    public init(coordinator: IndexCoordinator, scope: IndexScope,
                retryDelay: Duration = .seconds(5),
                progress: @escaping @Sendable (IndexProgress) async -> Void,
                didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void = { _, _ in }) {
        self.coordinator = coordinator
        self.scope = scope
        self.retryDelay = retryDelay
        self.progress = progress
        self.didComplete = didComplete
    }

    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        watermarks: [String: UInt64] = [:]) {
        guard !stopping else { return }
        let scopeChanged = scope.map { $0 != self.scope } ?? false
        if scopeChanged || rebuild {
            if let retryBatch { mergeWatermarks(retryBatch.watermarks) }
            if let dormantBatch { mergeWatermarks(dormantBatch.watermarks) }
            retryBatch = nil
            retryReady = false
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
        let inferred = activity ?? (rebuild ? .rebuild : (scopeChanged ? .scopeChange : (reconcile ? .initialBuild
            : (!reconciliationPaths.isEmpty ? .subtreeRecovery : .fileChanges))))
        let requestsPass = reconcile || rebuild || !paths.isEmpty
            || !reconciliationPaths.isEmpty || inferred != .fileChanges || scopeChanged
        fullScan = fullScan || reconcile || rebuild || scopeChanged
        self.rebuild = self.rebuild || rebuild
        if requestsPass { pendingActivity = Self.moreSignificant(pendingActivity, inferred) }
        reactivateDormantIfCovered()
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        defer { worker = nil }
        while hasPendingWork || (retryReady && retryBatch != nil) {
            // Fresh work always wins over a delayed retry, so a bad source cannot
            // starve later filesystem events.
            let retrying = !hasPendingIndexWork && retryReady && retryBatch != nil
            if !retrying, !fullScan, pendingPaths.isEmpty, pendingReconciliationPaths.isEmpty,
               pendingActivity == nil {
                let watermarks = pendingWatermarks
                pendingWatermarks.removeAll()
                let checkpointable = checkpointableWatermarks(watermarks)
                if !checkpointable.isEmpty {
                    await didComplete(.fileChanges, checkpointable)
                }
                continue
            }
            let batch: Batch
            if retrying, let retryBatch {
                batch = retryBatch
            } else {
                batch = Batch(
                    fullScan: fullScan,
                    rebuild: rebuild,
                    paths: pendingPaths,
                    reconciliationPaths: pendingReconciliationPaths,
                    watermarks: pendingWatermarks,
                    scope: scope,
                    activity: pendingActivity ?? .fileChanges,
                    retryAttempt: 0,
                    generation: configurationGeneration
                )
                fullScan = false
                rebuild = false
                pendingPaths.removeAll()
                pendingReconciliationPaths.removeAll()
                pendingWatermarks.removeAll()
                pendingActivity = nil
            }
            let operation = Task {
                if batch.fullScan {
                    await coordinator.indexAllResult(
                        scope: batch.scope, rebuild: batch.rebuild,
                        activity: batch.activity, progress: progress
                    )
                } else if !batch.reconciliationPaths.isEmpty {
                    await coordinator.reconcile(
                        paths: batch.reconciliationPaths, changedPaths: batch.paths,
                        scope: batch.scope, activity: batch.activity, progress: progress
                    )
                } else {
                    await coordinator.refreshResult(
                        paths: batch.paths, scope: batch.scope,
                        activity: batch.activity, progress: progress
                    )
                }
            }
            self.operation = operation
            let result = await operation.value
            self.operation = nil
            if batch.generation != configurationGeneration {
                mergeWatermarks(batch.watermarks)
                continue
            }
            if result.phase == .complete {
                let hasFailures = !result.failedPaths.isEmpty
                    || !result.failedReconciliationPaths.isEmpty
                if hasFailures {
                    let recovery = Batch(
                        fullScan: false, rebuild: false,
                        paths: result.failedPaths,
                        reconciliationPaths: result.failedReconciliationPaths,
                        watermarks: batch.watermarks, scope: batch.scope,
                        activity: .subtreeRecovery, retryAttempt: batch.retryAttempt,
                        generation: configurationGeneration
                    )
                    if batch.retryAttempt == 0 {
                        retainForRetry(recovery)
                    } else {
                        if retrying { clearRetry() }
                        parkDormant(recovery)
                    }
                } else if retrying {
                    clearRetry()
                }
                // Failed paths retain their stream watermarks through the one
                // scheduled retry and any dormant period. Unrelated streams can
                // still advance independently.
                let checkpointable = checkpointableWatermarks(batch.watermarks)
                if !checkpointable.isEmpty || batch.watermarks.isEmpty {
                    await didComplete(batch.activity, checkpointable)
                }
            } else if result.phase == .failed {
                if batch.retryAttempt == 0 {
                    retainForRetry(batch)
                } else {
                    if retrying { clearRetry() }
                    parkDormant(batch)
                }
            } else if result.phase == .cancelled, !stopping {
                if retrying { clearRetry() }
                retainForRetry(batch)
            }
        }
    }

    private var hasPendingWork: Bool {
        fullScan || !pendingPaths.isEmpty || !pendingReconciliationPaths.isEmpty
            || pendingActivity != nil || !pendingWatermarks.isEmpty
    }

    private var hasPendingIndexWork: Bool {
        fullScan || !pendingPaths.isEmpty || !pendingReconciliationPaths.isEmpty
            || pendingActivity != nil
    }

    private func mergeWatermarks(_ watermarks: [String: UInt64]) {
        for (volume, eventID) in watermarks {
            pendingWatermarks[volume] = max(pendingWatermarks[volume] ?? 0, eventID)
        }
    }

    private func retainForRetry(_ batch: Batch) {
        let candidate = Batch(
            fullScan: batch.fullScan,
            // Clearing the index is a one-shot setup step. Retried scans must
            // never wipe it again.
            rebuild: false,
            paths: batch.paths,
            reconciliationPaths: batch.reconciliationPaths,
            watermarks: batch.watermarks,
            scope: scope,
            activity: batch.activity,
            retryAttempt: batch.retryAttempt + 1,
            generation: configurationGeneration
        )
        retryBatch = merged(retryBatch, candidate, retryAttempt: max(1, candidate.retryAttempt))
        scheduleRetry()
    }

    private func parkDormant(_ batch: Batch) {
        let candidate = Batch(
            fullScan: batch.fullScan, rebuild: false,
            paths: batch.paths, reconciliationPaths: batch.reconciliationPaths,
            watermarks: batch.watermarks, scope: scope,
            activity: batch.activity, retryAttempt: batch.retryAttempt,
            generation: configurationGeneration
        )
        dormantBatch = merged(dormantBatch, candidate, retryAttempt: candidate.retryAttempt)
    }

    private func merged(_ existing: Batch?, _ incoming: Batch, retryAttempt: Int) -> Batch {
        guard let existing else { return incoming }
        var watermarks = existing.watermarks
        for (volume, eventID) in incoming.watermarks {
            watermarks[volume] = max(watermarks[volume] ?? 0, eventID)
        }
        return Batch(
            fullScan: existing.fullScan || incoming.fullScan,
            rebuild: false,
            paths: existing.paths.union(incoming.paths),
            reconciliationPaths: existing.reconciliationPaths.union(incoming.reconciliationPaths),
            watermarks: watermarks,
            scope: scope,
            activity: Self.moreSignificant(existing.activity, incoming.activity),
            retryAttempt: max(existing.retryAttempt, retryAttempt),
            generation: configurationGeneration
        )
    }

    private func checkpointableWatermarks(_ watermarks: [String: UInt64]) -> [String: UInt64] {
        var checkpointable: [String: UInt64] = [:]
        for (volume, eventID) in watermarks {
            if let retry = retryBatch, retry.watermarks[volume] != nil {
                retryBatch = replacingWatermark(in: retry, volume: volume, eventID: eventID)
            } else if let dormant = dormantBatch, dormant.watermarks[volume] != nil {
                dormantBatch = replacingWatermark(in: dormant, volume: volume, eventID: eventID)
            } else {
                checkpointable[volume] = eventID
            }
        }
        return checkpointable
    }

    private func replacingWatermark(
        in batch: Batch, volume: String, eventID: UInt64
    ) -> Batch {
        var watermarks = batch.watermarks
        watermarks[volume] = max(watermarks[volume] ?? 0, eventID)
        return Batch(
            fullScan: batch.fullScan, rebuild: batch.rebuild,
            paths: batch.paths, reconciliationPaths: batch.reconciliationPaths,
            watermarks: watermarks, scope: batch.scope,
            activity: batch.activity, retryAttempt: batch.retryAttempt,
            generation: batch.generation
        )
    }

    private func reactivateDormantIfCovered() {
        guard let dormantBatch else { return }
        let covered: Bool
        if fullScan {
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
        pendingActivity = Self.moreSignificant(pendingActivity, dormantBatch.activity)
        self.dormantBatch = nil
    }

    private func clearRetry() {
        retryBatch = nil
        retryReady = false
        cancelScheduledRetry()
    }

    private func scheduleRetry() {
        guard retryTask == nil, !stopping else { return }
        let delay = retryDelay
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return }
            await self?.startScheduledRetry()
        }
    }

    private func startScheduledRetry() {
        retryTask = nil
        guard !stopping, retryBatch != nil else { return }
        retryReady = true
        if worker == nil { worker = Task { await drain() } }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    private static func moreSignificant(_ current: IndexActivity?, _ next: IndexActivity) -> IndexActivity {
        guard let current else { return next }
        func rank(_ activity: IndexActivity) -> Int {
            switch activity {
            case .cachedLaunch: 0
            case .fileChanges: 1
            case .launchCatchUp: 2
            case .launchReconciliation: 3
            case .subtreeRecovery: 4
            case .rootRecovery: 5
            case .eventStreamRecovery: 6
            case .safetyVerification: 7
            case .initialBuild: 8
            case .scopeChange: 9
            case .rebuild: 10
            }
        }
        return rank(next) > rank(current) ? next : current
    }

    public func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    public func stop() async {
        stopping = true
        fullScan = false
        rebuild = false
        pendingPaths.removeAll()
        pendingReconciliationPaths.removeAll()
        pendingWatermarks.removeAll()
        pendingActivity = nil
        retryBatch = nil
        retryReady = false
        dormantBatch = nil
        cancelScheduledRetry()
        operation?.cancel()
        await worker?.value
    }
}
