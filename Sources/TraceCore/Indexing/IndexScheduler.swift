import Foundation

/// All app indexing requests enter here. Events arriving during a pass are merged for its successor.
public actor IndexScheduler {
    private let coordinator: IndexCoordinator
    private let progress: @Sendable (IndexProgress) async -> Void
    private var scope: IndexScope
    private var pendingPaths: Set<String> = []
    private var fullScan = false
    private var rebuild = false
    private var worker: Task<Void, Never>?
    private var operation: Task<Void, Never>?

    public init(coordinator: IndexCoordinator, scope: IndexScope,
                progress: @escaping @Sendable (IndexProgress) async -> Void) {
        self.coordinator = coordinator
        self.scope = scope
        self.progress = progress
    }

    public func request(paths: Set<String> = [], reconcile: Bool = false,
                        rebuild: Bool = false, scope: IndexScope? = nil) {
        if let scope { self.scope = scope }
        pendingPaths.formUnion(paths)
        fullScan = fullScan || reconcile || rebuild
        self.rebuild = self.rebuild || rebuild
        if rebuild { operation?.cancel() }
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        while fullScan || !pendingPaths.isEmpty {
            let all = fullScan
            let reset = rebuild
            let paths = pendingPaths
            let scope = scope
            fullScan = false
            rebuild = false
            pendingPaths.removeAll()
            let operation = Task {
                if all { await coordinator.indexAll(scope: scope, rebuild: reset, progress: progress) }
                else { await coordinator.refresh(paths: paths, scope: scope, progress: progress) }
            }
            self.operation = operation
            await operation.value
            self.operation = nil
        }
        worker = nil
    }

    public func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    public func stop() async {
        fullScan = false
        rebuild = false
        pendingPaths.removeAll()
        operation?.cancel()
        await worker?.value
    }
}
