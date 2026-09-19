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
    private var retryTask: Task<Void, Never>?
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
        if let scope { self.scope = scope }
        pendingPaths.formUnion(paths)
        pendingReconciliationPaths.formUnion(reconciliationPaths)
        for (volume, eventID) in watermarks {
            pendingWatermarks[volume] = max(pendingWatermarks[volume] ?? 0, eventID)
        }
        let inferred = activity ?? (rebuild ? .rebuild : (reconcile ? .initialBuild
            : (!reconciliationPaths.isEmpty ? .subtreeRecovery : .fileChanges)))
        let requestsPass = reconcile || rebuild || !paths.isEmpty
            || !reconciliationPaths.isEmpty || inferred != .fileChanges
        fullScan = fullScan || reconcile || rebuild
        self.rebuild = self.rebuild || rebuild
        if requestsPass { pendingActivity = Self.moreSignificant(pendingActivity, inferred) }
        if rebuild { operation?.cancel() }
        if worker == nil {
            cancelScheduledRetry()
            worker = Task { await drain() }
        }
    }

    private func drain() async {
        while retryBatch != nil || hasPendingWork {
            let retrying = retryBatch != nil
            if !retrying, !fullScan, pendingPaths.isEmpty, pendingReconciliationPaths.isEmpty,
               pendingActivity == nil {
                let watermarks = pendingWatermarks
                pendingWatermarks.removeAll()
                await didComplete(.fileChanges, watermarks)
                continue
            }
            let batch: Batch
            if let retryBatch {
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
                    retryAttempt: 0
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
            if result.phase == .complete {
                if retrying {
                    retryBatch = nil
                    cancelScheduledRetry()
                }
                if result.failedFiles == 0, result.unresolvedFailedFiles == 0 {
                    await didComplete(batch.activity, batch.watermarks)
                } else if result.failedFiles > 0 {
                    if absorbFailedBatchIntoPendingFullScan(batch) { continue }
                    retainForRetry(batch)
                    break
                }
            } else if result.phase == .failed {
                if absorbFailedBatchIntoPendingFullScan(batch) { continue }
                retainForRetry(batch)
                break
            } else if result.phase == .cancelled, !stopping {
                mergeWatermarks(batch.watermarks)
                if !fullScan {
                    retainForRetry(batch)
                    break
                } else if retrying {
                    retryBatch = nil
                }
            }
        }
        worker = nil
    }

    private var hasPendingWork: Bool {
        fullScan || !pendingPaths.isEmpty || !pendingReconciliationPaths.isEmpty
            || pendingActivity != nil || !pendingWatermarks.isEmpty
    }

    private func mergeWatermarks(_ watermarks: [String: UInt64]) {
        for (volume, eventID) in watermarks {
            pendingWatermarks[volume] = max(pendingWatermarks[volume] ?? 0, eventID)
        }
    }

    private func retainForRetry(_ batch: Batch) {
        retryBatch = Batch(
            fullScan: batch.fullScan,
            rebuild: batch.rebuild,
            paths: batch.paths,
            reconciliationPaths: batch.reconciliationPaths,
            watermarks: batch.watermarks,
            scope: batch.scope,
            activity: batch.activity,
            retryAttempt: batch.retryAttempt + 1
        )
        if batch.retryAttempt == 0 { scheduleRetry() }
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
        guard !stopping, retryBatch != nil, worker == nil else { return }
        worker = Task { await drain() }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// A queued full scan is an authoritative replacement for older failed work.
    /// Carry the older event watermark into it so work queued during the failed
    /// operation cannot be stranded waiting for another scheduler request.
    private func absorbFailedBatchIntoPendingFullScan(_ batch: Batch) -> Bool {
        guard fullScan else { return false }
        mergeWatermarks(batch.watermarks)
        retryBatch = nil
        cancelScheduledRetry()
        return true
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
        cancelScheduledRetry()
        operation?.cancel()
        await worker?.value
    }
}
