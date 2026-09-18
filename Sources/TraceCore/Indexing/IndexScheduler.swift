import Foundation

/// All app indexing requests enter here. Events arriving during a pass are merged for its successor.
public actor IndexScheduler {
    private let coordinator: IndexCoordinator
    private let progress: @Sendable (IndexProgress) async -> Void
    private let didComplete: @Sendable (IndexActivity, [String: UInt64]) async -> Void
    private var scope: IndexScope
    private var pendingPaths: Set<String> = []
    private var pendingReconciliationPaths: Set<String> = []
    private var pendingWatermarks: [String: UInt64] = [:]
    private var pendingActivity: IndexActivity?
    private var fullScan = false
    private var rebuild = false
    private var worker: Task<Void, Never>?
    private var operation: Task<IndexProgress, Never>?

    public init(coordinator: IndexCoordinator, scope: IndexScope,
                progress: @escaping @Sendable (IndexProgress) async -> Void,
                didComplete: @escaping @Sendable (IndexActivity, [String: UInt64]) async -> Void = { _, _ in }) {
        self.coordinator = coordinator
        self.scope = scope
        self.progress = progress
        self.didComplete = didComplete
    }

    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        reconciliationPaths: Set<String> = [],
                        rebuild: Bool = false, scope: IndexScope? = nil,
                        activity: IndexActivity? = nil,
                        watermarks: [String: UInt64] = [:]) {
        if let scope { self.scope = scope }
        pendingPaths.formUnion(paths)
        pendingReconciliationPaths.formUnion(reconciliationPaths)
        for (volume, eventID) in watermarks {
            pendingWatermarks[volume] = max(pendingWatermarks[volume] ?? 0, eventID)
        }
        fullScan = fullScan || reconcile || rebuild
        self.rebuild = self.rebuild || rebuild
        let inferred = activity ?? (rebuild ? .rebuild : (reconcile ? .initialBuild
            : (!reconciliationPaths.isEmpty ? .subtreeRecovery : .fileChanges)))
        pendingActivity = Self.moreSignificant(pendingActivity, inferred)
        if rebuild { operation?.cancel() }
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        while fullScan || !pendingPaths.isEmpty || !pendingReconciliationPaths.isEmpty
            || pendingActivity != nil || !pendingWatermarks.isEmpty {
            let all = fullScan
            let reset = rebuild
            let paths = pendingPaths
            let reconciliationPaths = pendingReconciliationPaths
            let watermarks = pendingWatermarks
            let scope = scope
            let activity = pendingActivity ?? .fileChanges
            fullScan = false
            rebuild = false
            pendingPaths.removeAll()
            pendingReconciliationPaths.removeAll()
            pendingWatermarks.removeAll()
            pendingActivity = nil
            let operation = Task {
                if all {
                    await coordinator.indexAllResult(
                        scope: scope, rebuild: reset, activity: activity, progress: progress
                    )
                } else if !reconciliationPaths.isEmpty {
                    await coordinator.reconcile(
                        paths: reconciliationPaths, changedPaths: paths, scope: scope,
                        activity: activity, progress: progress
                    )
                } else {
                    await coordinator.refreshResult(
                        paths: paths, scope: scope, activity: activity, progress: progress
                    )
                }
            }
            self.operation = operation
            let result = await operation.value
            self.operation = nil
            if result.phase == .complete { await didComplete(activity, watermarks) }
        }
        worker = nil
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
        fullScan = false
        rebuild = false
        pendingPaths.removeAll()
        pendingReconciliationPaths.removeAll()
        pendingWatermarks.removeAll()
        pendingActivity = nil
        operation?.cancel()
        await worker?.value
    }
}
