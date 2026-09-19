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
        if rebuild {
            retryBatch = nil
            cancelScheduledRetry()
            operation?.cancel()
        }
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        defer { worker = nil }
        while retryBatch != nil || hasPendingWork {
            if retryBatch != nil, !hasPendingIndexWork, !pendingWatermarks.isEmpty {
                mergePendingWatermarksIntoRetry()
            }
            // Fresh work always wins over a delayed retry, so a bad source cannot
            // starve later filesystem events.
            let retrying = !hasPendingIndexWork && retryBatch != nil
            if !retrying, !fullScan, pendingPaths.isEmpty, pendingReconciliationPaths.isEmpty,
               pendingActivity == nil {
                let watermarks = pendingWatermarks
                pendingWatermarks.removeAll()
                await didComplete(.fileChanges, watermarks)
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
                if retrying { retryBatch = nil }
                // A completed pass has durably recorded isolated source failures.
                // Checkpoint it and retry only the failed paths/scopes.
                await didComplete(batch.activity, batch.watermarks)
                if (!result.failedPaths.isEmpty || !result.failedReconciliationPaths.isEmpty),
                   batch.retryAttempt == 0 {
                    retainForRetry(Batch(
                        fullScan: false, rebuild: false,
                        paths: result.failedPaths,
                        reconciliationPaths: result.failedReconciliationPaths,
                        watermarks: [:], scope: batch.scope,
                        activity: .subtreeRecovery, retryAttempt: batch.retryAttempt
                    ))
                    break
                }
            } else if result.phase == .failed {
                if batch.retryAttempt == 0 {
                    retainForRetry(batch)
                    break
                }
                // Keep the fatal operation dormant. A later accepted request may
                // trigger it again, but it never hot-loops on its own.
                retryBatch = batch
                break
            } else if result.phase == .cancelled, !stopping {
                if fullScan {
                    mergeWatermarks(batch.watermarks)
                    if retrying { retryBatch = nil }
                } else {
                    retainForRetry(batch)
                    break
                }
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

    private func mergePendingWatermarksIntoRetry() {
        guard let batch = retryBatch else { return }
        var watermarks = batch.watermarks
        for (volume, eventID) in pendingWatermarks {
            watermarks[volume] = max(watermarks[volume] ?? 0, eventID)
        }
        pendingWatermarks.removeAll()
        retryBatch = Batch(
            fullScan: batch.fullScan, rebuild: batch.rebuild,
            paths: batch.paths, reconciliationPaths: batch.reconciliationPaths,
            watermarks: watermarks, scope: batch.scope,
            activity: batch.activity, retryAttempt: batch.retryAttempt
        )
    }

    private func retainForRetry(_ batch: Batch) {
        retryBatch = Batch(
            fullScan: batch.fullScan,
            // Clearing the index is a one-shot setup step. Retried scans must
            // never wipe it again.
            rebuild: false,
            paths: batch.paths,
            reconciliationPaths: batch.reconciliationPaths,
            watermarks: batch.watermarks,
            scope: batch.scope,
            activity: batch.activity,
            retryAttempt: batch.retryAttempt + 1
        )
        scheduleRetry()
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
