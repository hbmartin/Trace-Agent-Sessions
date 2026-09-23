import AppKit
import CryptoKit
import Darwin
import Foundation
import TraceCore

struct SidebarRevealRequest: Equatable {
    let token = UUID()
    let projectCanonicalKey: String
    let sessionID: Int64
}

enum WatcherGroupingPolicy {
    case byVolume
    case byRoot

    func groupIdentifier(for root: URL, volumeIdentifier: String) -> String {
        switch self {
        case .byVolume:
            return volumeIdentifier
        case .byRoot:
            let key = TraceFileIO.canonicalPath(root.path).comparisonKey
            let digest = SHA256.hash(data: Data(key.utf8)).map {
                String(format: "%02x", $0)
            }.joined()
            return volumeIdentifier + ":root:" + digest
        }
    }
}

@MainActor
final class TraceModel: ObservableObject {
    enum GlobalSearchSurface: Hashable { case popover, launcher }
    private enum ProjectReconciliationMode: Equatable {
        case ongoing
        case completed
        case terminalRetaining

        var globalMissingProjectPolicy: SessionSearchModel.MissingProjectPolicy {
            switch self {
            case .ongoing: .keepResolving
            case .completed: .clear
            case .terminalRetaining: .retain
            }
        }

        var mainMissingProjectPolicy: SessionSearchModel.MissingProjectPolicy {
            switch self {
            case .ongoing: .keepResolving
            case .completed, .terminalRetaining: .retain
            }
        }
    }

    private struct IndexProgressDisposition {
        let passTerminal: Bool
        let workflowTerminal: Bool
        let supersededTerminal: Bool
        let projectReconciliation: ProjectReconciliationMode
    }

    private struct SessionLookupResult {
        let succeeded: Bool
        let session: SessionSummary?
    }

    private struct IndexWorkflowState {
        private struct Replacement {
            var displacedPassIDs: Set<UUID>
        }

        private(set) var activePassID: UUID?
        private var replacement: Replacement?

        var isActive: Bool { activePassID != nil || replacement != nil }

        mutating func beginReplacement() {
            if replacement == nil {
                replacement = .init(displacedPassIDs: [])
            }
            if let activePassID { replacement?.displacedPassIDs.insert(activePassID) }
        }

        mutating func receive(_ update: IndexProgress) -> IndexProgressDisposition {
            let passTerminal = [.complete, .failed, .cancelled].contains(update.phase)
            let supersededTerminal: Bool
            if passTerminal, let replacement {
                supersededTerminal = replacement.displacedPassIDs.contains(update.passID)
                    || (update.phase == .cancelled
                        && activePassID == nil)
            } else {
                supersededTerminal = false
            }

            if passTerminal {
                if activePassID == update.passID { activePassID = nil }
                if supersededTerminal {
                    replacement?.displacedPassIDs.remove(update.passID)
                } else {
                    replacement = nil
                }
            } else {
                activePassID = update.passID
                if replacement?.displacedPassIDs.contains(update.passID) != true {
                    replacement = nil
                }
            }

            let workflowTerminal = passTerminal && !supersededTerminal
            let projectReconciliation: ProjectReconciliationMode
            if !workflowTerminal {
                projectReconciliation = .ongoing
            } else if update.phase == .complete {
                projectReconciliation = .completed
            } else {
                projectReconciliation = .terminalRetaining
            }
            return .init(
                passTerminal: passTerminal,
                workflowTerminal: workflowTerminal,
                supersededTerminal: supersededTerminal,
                projectReconciliation: projectReconciliation
            )
        }
    }
    let settings: AppSettings
    let globalSearch = SessionSearchModel()
    var mainSearch = SessionSearchModel()
    let diagnostics: DiagnosticsStore

    @Published private(set) var progress = IndexProgress(phase: .waiting)
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var recentSessions: [SessionSummary] = []
    @Published private(set) var messages: [MessageSummary] = [] {
        didSet { transcriptMessageRevision &+= 1 }
    }
    @Published private(set) var hydratedMessages: [Int64: HydratedMessage] = [:] {
        didSet { transcriptContentRevision &+= 1 }
    }
    @Published private(set) var hydrationFailures: Set<Int64> = [] {
        didSet { transcriptContentRevision &+= 1 }
    }
    @Published var projectFilter = ""
    @Published private(set) var selectedSession: SessionSummary?
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var usage: [UsageRollup] = []
    @Published private(set) var costsTotalsUpdating = false
    @Published private(set) var statistics: IndexStatistics?
    @Published private(set) var diagnosticsSnapshot = DiagnosticsSnapshot()
    @Published private(set) var pricing: PricingCatalog?
    @Published private(set) var pricingError: String?
    @Published private(set) var costsError: String?
    @Published private(set) var selectedProjectID: Int64?
    @Published private(set) var selectedProjectCanonicalKey: String?
    @Published private(set) var selectedProjectDisplayName: String?
    @Published private(set) var sidebarRevealRequest: SidebarRevealRequest?
    @Published var selectedSessionID: Int64?
    @Published var customCostStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @Published var customCostEnd = Date()
    @Published var expandedReasoningIDs: Set<Int64> = [] {
        didSet { transcriptContentRevision &+= 1 }
    }
    @Published var startupError: String?
    private(set) var transcriptMessageRevision = 0
    private(set) var transcriptContentRevision = 0

    private var database: IndexDatabase?
    private var coordinator: IndexCoordinator?
    private var watchers: [FSEventsWatcher] = []
    private var scheduler: IndexScheduler?
    private var bufferedSourceChanges = SourceChanges()
    private var watcherStartupPending = true
    private var startupReconciliationPaths: Set<String> = []
    private var startupActivity = IndexActivity.cachedLaunch
    private var pendingStartupRecovery = IndexRecoveryWork()
    private var watchedSourceRoots: [URL] = []
    private var watcherGeneration: UInt64 = 0
    private var safetyVerificationTask: Task<Void, Never>?
    private var hydrationOrder: [Int64] = []
    private var hydratingMessageIDs: Set<Int64> = []
    private let hydrationCacheLimit = 512
    private var sourceChangeTask: Task<Void, Never>?
    private var sourceConfigurationRevision: UInt64 = 0
    private var startupSetupComplete = false
    private var lastSummaryRefresh = ContinuousClock.now
    private var incrementalProgressTask: Task<Void, Never>?
    private var pendingIncrementalProgress: IndexProgress?
    private var incrementalProgressVisible = false
    private var automaticSearchTask: Task<Void, Never>?
    private var automaticSearchTaskID: UUID?
    private var globalSearchNeedsRefresh = false
    private var mainSearchNeedsRefresh = false
    private var globalSearchSurfaces: Set<GlobalSearchSurface> = []
    private var mainWindowVisible = false
    private var mainSearchPanelVisible = false
    private var completedUsage: [UsageRollup] = []
    private var completedUsageRevision = 0
    private var usageSnapshotRequestID = UUID()
    private var usageRefreshPending = false
    private var usageRepairPending = false
    private var deferredUsageRepairTask: Task<Void, Never>?
    private var indexWorkflow = IndexWorkflowState()
    private var indexingPassActive: Bool { indexWorkflow.isActive }
    private var lastAutomaticSearchRefresh: ContinuousClock.Instant?
    private var lastObservedPassID: UUID?
    private var lastObservedMutationRevision = 0
    private var lastSearchedPassID: UUID?
    private var lastSearchedMutationRevision = 0
    private var timeZoneObserver: NSObjectProtocol?
    private var sessionRequestID = UUID()
    private var projectRequestID = UUID()
    private var summaryRequestID = UUID()
    var scrollPositions: [Int64: TranscriptBookmark] = [:]
    @Published private(set) var scrollRequest = UUID()
    private(set) var requestedMessageID: Int64?
    private var mayRestoreSession = true
    private var started = false
    private var initialIndexRequested = false
    private var sidebarProjectRevealAcknowledged = false
    private var sidebarSessionRevealAcknowledged = false
    private var sidebarRevealFallbackTask: Task<Void, Never>?
    private let watcherGroupingPolicy: WatcherGroupingPolicy
    private let startupActivityObserver: (IndexActivity) -> Void

    init(
        settings: AppSettings = AppSettings(),
        watcherGroupingPolicy: WatcherGroupingPolicy = .byVolume,
        startupActivityObserver: @escaping (IndexActivity) -> Void = { _ in }
    ) {
        self.settings = settings
        self.watcherGroupingPolicy = watcherGroupingPolicy
        self.startupActivityObserver = startupActivityObserver
        diagnostics = DiagnosticsStore(url: TraceRuntime.testDirectory?.appendingPathComponent("diagnostics.json") ?? DiagnosticsStore.defaultURL())
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            do {
                try await diagnostics.markLaunchStarted()
                let isolatedURL = TraceRuntime.testDirectory?.appendingPathComponent("index.sqlite")
                let database = try await Task.detached(priority: .userInitiated) {
                    if isolatedURL != nil,
                       let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_INDEX_OPEN_DELAY_MS", cappedAt: 5_000
                       ) {
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                    let url = try isolatedURL ?? IndexDatabase.defaultURL()
                    return try IndexDatabase(url: url)
                }.value
                self.database = database
                if database.contentWasResetOnOpen { prepareForIndexReset() }
                var sources: [any SessionSource] = []
                var configuredRevision = sourceConfigurationRevision
                while true {
                    let revision = sourceConfigurationRevision
                    let latestSources = await makeSources()
                    _ = try await database.synchronizeConfiguredRoots(
                        latestSources.flatMap(\.roots)
                    )
                    guard revision == sourceConfigurationRevision else { continue }
                    var recovery = IndexRecoveryWork()
                    var recoveryLoadError: Error?
                    do {
                        if let delay = TraceTestHooks.delayMilliseconds(
                            for: "TRACE_TEST_RECOVERY_LOAD_DELAY_MS", cappedAt: 5_000
                        ) {
                            TraceTestHooks.touch(pathKey: "TRACE_TEST_RECOVERY_LOAD_STARTED_PATH")
                            try await Task.sleep(for: .milliseconds(delay))
                        }
                        if TraceTestHooks.failOnce(for: "TRACE_TEST_FAIL_RECOVERY_LOAD_ONCE") {
                            throw SessionSourceError.unreadableFile("synthetic recovery metadata")
                        }
                        recovery = try await database.unresolvedRecoveryWork()
                        if let delay = TraceTestHooks.delayMilliseconds(
                            for: "TRACE_TEST_RECOVERY_LOADED_DELAY_MS", cappedAt: 10_000,
                            marker: .touch(pathKey: "TRACE_TEST_RECOVERY_LOADED_PATH")
                        ) {
                            try await Task.sleep(for: .milliseconds(delay))
                        }
                    } catch {
                        recoveryLoadError = error
                    }
                    guard revision == sourceConfigurationRevision else { continue }
                    if let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_FAILURE_COUNTS_HOLD_MS", cappedAt: 30_000,
                        marker: .touch(pathKey: "TRACE_TEST_FAILURE_COUNTS_STARTED_PATH")
                    ) {
                        try await TraceTestHooks.waitForRelease(
                            pathKey: "TRACE_TEST_FAILURE_COUNTS_RELEASE_PATH",
                            timeoutMilliseconds: delay
                        )
                    }
                    let counts = try? await database.unresolvedSourceFailureCounts()
                    guard revision == sourceConfigurationRevision else { continue }
                    sources = latestSources
                    configuredRevision = revision
                    if let counts {
                        progress.unresolvedFailedFiles = counts.fileFailures
                        progress.unresolvedDiscoveryFailures = counts.discoveryFailures
                    }
                    if let recoveryLoadError {
                        startupError = "Could not load pending index recovery; a safe root scan was queued: \(recoveryLoadError.localizedDescription)"
                        pendingStartupRecovery = .init(
                            reconciliationPaths: Set(
                                sources.flatMap(\.roots).map { $0.scanURL.path }
                            )
                        )
                    } else {
                        pendingStartupRecovery = recovery
                    }
                    break
                }
                let coordinator = IndexCoordinator(database: database, sources: sources)
                self.coordinator = coordinator
                globalSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
                mainSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
                scheduler = makeScheduler(coordinator)
                timeZoneObserver = NotificationCenter.default.addObserver(
                    forName: Notification.Name.NSSystemTimeZoneDidChange,
                    object: nil, queue: .main
                ) { [weak self] _ in
                    tzset()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.indexingPassActive {
                            self.usageRepairPending = true
                            self.usageRefreshPending = true
                            self.updateCostsTotalsUpdating()
                            return
                        }
                        await self.refreshCompletedUsage(repairIfDirty: true)
                    }
                }
                loadPricing()
                await reloadSummaries(loadCosts: false)
                await loadCachedUsageAtStartup()
                if let delay = TraceTestHooks.delayMilliseconds(
                    for: "TRACE_TEST_STARTUP_FINALIZATION_DELAY_MS", cappedAt: 30_000,
                    marker: .touch(pathKey: "TRACE_TEST_STARTUP_FINALIZATION_PATH")
                ) {
                    try await TraceTestHooks.waitForRelease(
                        pathKey: "TRACE_TEST_STARTUP_FINALIZATION_RELEASE_PATH",
                        timeoutMilliseconds: delay
                    )
                }
                guard configuredRevision == sourceConfigurationRevision else { return }
                startupSetupComplete = true
                if settings.onboardingComplete {
                    guard await startWatching(sources) else { return }
                    guard configuredRevision == sourceConfigurationRevision else { return }
                    if ProcessInfo.processInfo.arguments.contains("--index-smoke"), TraceRuntime.testDirectory != nil {
                        await scheduler?.request(reconcile: true, scope: settings.indexScope)
                        await scheduler?.waitUntilIdle()
                        let snapshot = try await database.statistics()
                        let report: [String: Any] = ["messages": snapshot.messageCount, "sessions": snapshot.sessionCount,
                            "indexedFiles": progress.indexedFiles, "unchangedFiles": progress.unchangedFiles,
                            "failedFiles": progress.failedFiles, "phase": progress.phase.rawValue, "pricingLoaded": pricing != nil]
                        let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
                        FileHandle.standardOutput.write(data + Data("\n".utf8))
                        await prepareToTerminate()
                        exit(progress.phase == .complete && progress.failedFiles == 0 ? 0 : 1)
                    } else {
                        Task { [weak self] in
                            guard let self else { return }
                            self.startIndexing(sources: sources)
                        }
                    }
                } else {
                    Task { [weak self] in
                        guard let self else { return }
                        if !self.settings.onboardingComplete {
                            await self.refreshCompletedUsage(repairIfDirty: true)
                        }
                    }
                }
            } catch {
                startupError = error.localizedDescription
                progress = .init(phase: .failed, error: error.localizedDescription)
            }
        }
    }

    func completeOnboarding(enableLoginItem: Bool) {
        do {
            if TraceRuntime.testDirectory == nil { try settings.setLaunchAtLogin(enableLoginItem) }
        } catch {
            startupError = "Could not update the login item: \(error.localizedDescription)"
        }
        settings.onboardingComplete = true
        if startupSetupComplete, coordinator != nil {
            Task { [weak self] in
                guard let self else { return }
                let sources = await self.makeSources()
                guard await self.startWatching(sources) else { return }
                self.startIndexing(sources: sources)
            }
        }
    }

    private func makeScheduler(_ coordinator: IndexCoordinator) -> IndexScheduler {
        IndexScheduler(
            coordinator: coordinator, scope: settings.indexScope,
            progress: { [weak self] update in
                await self?.receiveProgress(update)
            },
            didComplete: { [weak self] _, watermarks in
                try? await self?.database?.saveEventCheckpoints(watermarks)
            },
            didSatisfySafetyReconciliation: { [weak self] in
                try? await self?.database?.markSafetyReconciliationComplete()
            }
        )
    }

    private func receiveProgress(_ update: IndexProgress) async {
        let disposition = indexWorkflow.receive(update)
        if !disposition.passTerminal { usageSnapshotRequestID = UUID() }
        if disposition.passTerminal {
            TraceTestHooks.touch(pathKey: "TRACE_TEST_INDEX_PASS_COMPLETED_PATH")
            TraceTestHooks.appendLine(
                update.activity.rawValue,
                pathKey: "TRACE_TEST_INDEX_ACTIVITY_AUDIT_PATH"
            )
        }
        if update.incremental {
            if disposition.passTerminal {
                incrementalProgressTask?.cancel()
                incrementalProgressTask = nil
                pendingIncrementalProgress = nil
                if !disposition.supersededTerminal,
                   IndexProgress.shouldPublishIncrementalTerminal(
                    update, after: progress, wasVisible: incrementalProgressVisible
                   ) {
                    progress = update
                }
                incrementalProgressVisible = false
            } else {
                pendingIncrementalProgress = update
                if incrementalProgressTask == nil {
                    incrementalProgressTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(300)) }
                        catch { return }
                        guard let self, let pending = self.pendingIncrementalProgress else { return }
                        self.progress = pending
                        self.incrementalProgressVisible = true
                        self.incrementalProgressTask = nil
                    }
                }
            }
        } else if !disposition.supersededTerminal {
            progress = update
        }

        if disposition.passTerminal {
            handleTerminalUsageProgress(update, finalize: disposition.workflowTerminal)
        }
        else {
            if usageRepairPending, deferredUsageRepairTask != nil {
                deferredUsageRepairTask?.cancel()
                deferredUsageRepairTask = nil
            }
            updateCostsTotalsUpdating()
        }
        observeSearchMutation(update, terminal: disposition.workflowTerminal)

        let shouldRefresh = disposition.passTerminal
            || ((!update.incremental || incrementalProgressVisible)
                && lastSummaryRefresh.duration(to: .now) >= .milliseconds(250))
        if shouldRefresh {
            lastSummaryRefresh = .now
            await reloadSummaries(
                lightweight: !disposition.workflowTerminal,
                projectReconciliation: disposition.projectReconciliation,
                terminalPhase: disposition.workflowTerminal ? update.phase : nil
            )
        }
    }

    private func handleTerminalUsageProgress(_ update: IndexProgress, finalize: Bool) {
        if let rollupError = update.rollupError {
            costsError = rollupError
            usageRepairPending = true
            usageRefreshPending = true
        }
        if update.phase != .complete && (update.indexChanged || update.rollupsChanged) {
            usageRepairPending = true
            usageRefreshPending = true
        }
        guard finalize else {
            updateCostsTotalsUpdating()
            return
        }
        if usageRepairPending {
            scheduleDeferredUsageRepair()
        } else if usageRefreshPending {
            scheduleCompletedUsageRefresh(repairIfDirty: false)
        } else if update.phase == .complete,
                  update.indexChanged || update.rollupsChanged {
            scheduleCompletedUsageRefresh(repairIfDirty: false)
        }
        updateCostsTotalsUpdating()
    }

    private func observeSearchMutation(_ update: IndexProgress, terminal: Bool) {
        if lastObservedPassID != update.passID {
            lastObservedPassID = update.passID
            lastObservedMutationRevision = 0
        }
        if update.mutationRevision > lastObservedMutationRevision {
            lastObservedMutationRevision = update.mutationRevision
            if !globalSearch.query.isEmpty {
                if globalSearch.protectsPagination { globalSearch.markResultsStale() }
                else { globalSearchNeedsRefresh = true }
            }
            if !mainSearch.query.isEmpty {
                if mainSearch.protectsPagination { mainSearch.markResultsStale() }
                else { mainSearchNeedsRefresh = true }
            }
            scheduleAutomaticSearch()
        }
        if terminal && update.indexChanged
            && (lastSearchedPassID != update.passID
                || lastSearchedMutationRevision < update.mutationRevision) {
            cancelAutomaticSearch()
            performAutomaticSearch()
        }
    }

    private var mainSearchIsVisible: Bool {
        mainWindowVisible && mainSearchPanelVisible && selectedSessionID == nil
    }

    private var hasVisibleAutomaticSearch: Bool {
        (globalSearchNeedsRefresh && !globalSearchSurfaces.isEmpty
            && !globalSearch.query.isEmpty && !globalSearch.protectsPagination
            && !globalSearch.isResolvingProjectFilter)
        || (mainSearchNeedsRefresh && mainSearchIsVisible
            && !mainSearch.query.isEmpty && !mainSearch.protectsPagination
            && !mainSearch.isResolvingProjectFilter)
    }

    func setGlobalSearchSurface(_ surface: GlobalSearchSurface, visible: Bool) {
        guard globalSearchSurfaces.contains(surface) != visible else { return }
        if visible { globalSearchSurfaces.insert(surface) }
        else { globalSearchSurfaces.remove(surface) }
        if !visible && globalSearchSurfaces.isEmpty {
            var changed = false
            if settings.clearGlobalSearchOnClose && !globalSearch.query.isEmpty {
                globalSearch.query = ""
                changed = true
            }
            if settings.clearGlobalFiltersOnClose {
                changed = changed || globalSearch.hasActiveFilters
                globalSearch.clearFilters()
            }
            if changed {
                globalSearch.search(sort: settings.searchSort)
                globalSearchNeedsRefresh = false
            }
        }
        searchVisibilityChanged()
    }

    func clearGlobalSearchFilters() {
        guard globalSearch.hasActiveFilters else { return }
        globalSearch.clearFilters()
        globalSearchNeedsRefresh = false
        globalSearch.search(sort: settings.searchSort)
    }

    func setMainWindowVisible(_ visible: Bool) {
        mainWindowVisible = visible
        searchVisibilityChanged()
    }

    func setMainSearchPanelVisible(_ visible: Bool) {
        mainSearchPanelVisible = visible
        searchVisibilityChanged()
    }

    private func searchVisibilityChanged() {
        if !hasVisibleAutomaticSearch {
            cancelAutomaticSearch()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            self?.scheduleAutomaticSearch()
        }
    }

    private func cancelAutomaticSearch() {
        automaticSearchTaskID = nil
        automaticSearchTask?.cancel()
        automaticSearchTask = nil
    }

    private func scheduleAutomaticSearch() {
        guard hasVisibleAutomaticSearch else { return }
        guard automaticSearchTask == nil else { return }
        let elapsed = lastAutomaticSearchRefresh?.duration(to: .now) ?? .seconds(1)
        if elapsed >= .seconds(1) { performAutomaticSearch(); return }
        let id = UUID()
        automaticSearchTaskID = id
        automaticSearchTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1) - elapsed) }
            catch { return }
            guard let self, !Task.isCancelled, self.automaticSearchTaskID == id else { return }
            self.automaticSearchTaskID = nil
            self.automaticSearchTask = nil
            self.performAutomaticSearch()
        }
    }

    private func performAutomaticSearch() {
        guard hasVisibleAutomaticSearch else { return }
        lastAutomaticSearchRefresh = .now
        lastSearchedPassID = lastObservedPassID
        lastSearchedMutationRevision = lastObservedMutationRevision
        if globalSearchNeedsRefresh, !globalSearchSurfaces.isEmpty,
           !globalSearch.query.isEmpty, !globalSearch.protectsPagination,
           !globalSearch.isResolvingProjectFilter {
            globalSearchNeedsRefresh = false
            globalSearch.search(sort: settings.searchSort, trigger: .automatic)
        }
        if mainSearchNeedsRefresh, mainSearchIsVisible,
           !mainSearch.query.isEmpty, !mainSearch.protectsPagination,
           !mainSearch.isResolvingProjectFilter {
            mainSearchNeedsRefresh = false
            syncMainSearchProjectFilter()
            mainSearch.search(sort: settings.searchSort, trigger: .automatic)
        }
    }

    func startIndexing(sources: [any SessionSource]) {
        guard settings.onboardingComplete, !initialIndexRequested, let scheduler else { return }
        initialIndexRequested = true
        Task { [weak self] in
            guard let self else { return }
            let buffered = self.bufferedSourceChanges
            self.bufferedSourceChanges = SourceChanges()
            let recovery = self.pendingStartupRecovery
            let recoveryActivity = recovery.isEmpty ? nil : Self.recoveryActivity(
                for: recovery, sources: sources
            )
            self.pendingStartupRecovery = .init()
            let baseActivity = self.startupReconciliationPaths.isEmpty
                ? (buffered.paths.isEmpty && buffered.reconciliationPaths.isEmpty
                    ? self.startupActivity : self.activity(for: buffered))
                : self.startupActivity
            let activity = recoveryActivity.map {
                IndexActivity.moreSignificant(baseActivity, $0)
            } ?? baseActivity
            let satisfiesSafetyReconciliation = baseActivity.satisfiesSafetyReconciliation
                || (recoveryActivity?.satisfiesSafetyReconciliation ?? false)
            self.startupActivityObserver(activity)
            await scheduler.request(
                paths: buffered.paths.union(recovery.filePaths),
                reconciliationPaths: self.startupReconciliationPaths
                    .union(buffered.reconciliationPaths)
                    .union(recovery.reconciliationPaths),
                scope: self.settings.indexScope,
                activity: activity,
                satisfiesSafetyReconciliation: satisfiesSafetyReconciliation,
                watermarks: buffered.watermarks,
                streamRoots: buffered.streamRoots
            )
            self.watcherStartupPending = false
            let arrivedDuringSubmission = self.bufferedSourceChanges
            self.bufferedSourceChanges = SourceChanges()
            if !arrivedDuringSubmission.paths.isEmpty
                || arrivedDuringSubmission.requiresReconciliation
                || !arrivedDuringSubmission.watermarks.isEmpty {
                await self.submitSourceChanges(arrivedDuringSubmission)
            }
            self.startSafetyVerificationLoop()
        }
    }

    func rebuildIndex() {
        guard settings.onboardingComplete, let scheduler else { return }
        beginIndexReplacement()
        prepareForIndexReset()
        Task { await scheduler.request(rebuild: true, scope: settings.indexScope) }
    }

    func reloadSourcesAndRebuild() {
        sourceConfigurationRevision &+= 1
        let revision = sourceConfigurationRevision
        guard let database, let previousScheduler = scheduler else { return }
        sourceChangeTask?.cancel()
        invalidateWatchers()
        beginIndexReplacement()
        sourceChangeTask = Task {
            await previousScheduler.stop()
            guard !Task.isCancelled, revision == sourceConfigurationRevision else { return }
            let sources = await makeSources()
            do {
                if try await database.synchronizeConfiguredRoots(sources.flatMap(\.roots)) {
                    await reloadSummaries(
                        loadCosts: false, projectReconciliation: .completed
                    )
                }
            } catch {
                startupError = "Could not update source folders: \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, revision == sourceConfigurationRevision else { return }
            let coordinator = IndexCoordinator(database: database, sources: sources)
            self.coordinator = coordinator
            globalSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
            mainSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
            scheduler = makeScheduler(coordinator)
            initialIndexRequested = false
            startupSetupComplete = true
            guard await startWatching(sources, forceRootReconciliation: true) else { return }
            guard !Task.isCancelled, revision == sourceConfigurationRevision else { return }
            // Root changes reconcile existing files; unchanged sources retain their index.
            startIndexing(sources: sources)
        }
    }

    func search(reset: Bool = true) {
        if reset { globalSearchNeedsRefresh = false }
        globalSearch.search(sort: settings.searchSort, reset: reset)
    }
    func searchMain() {
        mainSearchNeedsRefresh = false
        syncMainSearchProjectFilter()
        mainSearch.search(sort: settings.searchSort)
    }

    private func syncMainSearchProjectFilter() {
        mainSearch.setProjectFilter(
            canonicalKey: selectedProjectCanonicalKey,
            displayName: selectedProjectDisplayName
        )
    }
    var filteredProjects: [ProjectSummary] {
        let query = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? projects : projects.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }
    var sidebarSelectedProjectID: Int64? {
        guard let selectedProjectID, let selectedProjectCanonicalKey,
              projects.contains(where: {
                  $0.id == selectedProjectID && $0.canonicalKey == selectedProjectCanonicalKey
              }) else { return nil }
        return selectedProjectID
    }

    func sessionErrorText(_ session: SessionSummary) async -> String {
        if TraceRuntime.testDirectory != nil,
           let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_ERROR_LOAD_DELAY_MS", cappedAt: 5_000
           ) {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        guard let coordinator else {
            return "Error details are unavailable while the index is starting."
        }
        do {
            let failures = try await coordinator.failures(for: session)
            try Task.checkCancellation()
            return failures.isEmpty
                ? "\(session.agent.displayName) recorded an error without a detailed explanation."
                : failures.map { failure in
                    let header = [session.agent.displayName, failure.kind.capitalized,
                        failure.timestampMilliseconds.traceDate, failure.toolName].compactMap { $0 }.joined(separator: " · ")
                    return header + "\n" + (failure.detail.isEmpty
                        ? "The source did not provide an error message."
                        : String(failure.detail.prefix(4_000)))
                }.joined(separator: "\n\n")
        } catch is CancellationError {
            return "Loading error details was cancelled."
        } catch {
            return "Could not read error details from \(session.sourcePath): \(error.localizedDescription)"
        }
    }

    var detailTitle: String {
        if let selectedSession, selectedSession.id == selectedSessionID { return selectedSession.title }
        return selectedProjectDisplayName ?? "Trace"
    }

    func clearSession() {
        mayRestoreSession = false
        invalidateSidebarRevealRequest()
        sessionRequestID = UUID()
        selectedSessionID = nil
        selectedSession = nil
        settings.lastSessionID = nil
        messages = []
        hydratedMessages.removeAll()
        hydrationFailures.removeAll()
        hydrationOrder.removeAll()
        hydratingMessageIDs.removeAll()
        expandedReasoningIDs.removeAll()
        requestedMessageID = nil
    }

    func consumeRequestedMessageID(_ messageID: Int64) {
        if requestedMessageID == messageID { requestedMessageID = nil }
    }

    private func prepareForIndexReset() {
        cancelAutomaticSearch()
        deferredUsageRepairTask?.cancel()
        deferredUsageRepairTask = nil
        completedUsageRevision += 1
        usageSnapshotRequestID = UUID()
        usageRefreshPending = false
        usageRepairPending = false
        updateCostsTotalsUpdating()
        globalSearchNeedsRefresh = false
        mainSearchNeedsRefresh = false
        lastObservedPassID = nil
        lastSearchedPassID = nil
        lastObservedMutationRevision = 0
        lastSearchedMutationRevision = 0
        mayRestoreSession = false
        sessionRequestID = UUID()
        projectRequestID = UUID()
        summaryRequestID = UUID()
        self.selectedProjectID = nil
        selectedSessionID = nil
        selectedSession = nil
        invalidateSidebarRevealRequest()
        settings.lastSessionID = nil
        projects = []
        sessions = []
        recentSessions = []
        messages = []
        hydratedMessages = [:]
        hydrationFailures = []
        hydrationOrder = []
        hydratingMessageIDs = []
        expandedReasoningIDs = []
        scrollPositions = [:]
        requestedMessageID = nil
        sourceHealth = []
        statistics = nil
        globalSearch.resetForIndexReset(awaitsProjectResolution: true)
        mainSearch.resetForIndexReset(awaitsProjectResolution: true)
    }

    private func beginIndexReplacement() {
        indexWorkflow.beginReplacement()
        usageSnapshotRequestID = UUID()
        deferredUsageRepairTask?.cancel()
        deferredUsageRepairTask = nil
        updateCostsTotalsUpdating()
    }

    func selectProject(_ projectID: Int64?) {
        if let projectID {
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            guard selectedProjectID != project.id
                    || selectedProjectCanonicalKey != project.canonicalKey else { return }
            clearSession()
            selectedProjectID = project.id
            selectedProjectCanonicalKey = project.canonicalKey
            selectedProjectDisplayName = project.displayName
            searchMain()
            loadProjectSessions()
            return
        }
        // SwiftUI writes nil when a selected row temporarily disappears. Treat nil as
        // deliberate only while the selected row is still visible.
        guard let selectedProjectID, let selectedCanonicalKey = selectedProjectCanonicalKey,
              filteredProjects.contains(where: {
                  $0.id == selectedProjectID
                      && $0.canonicalKey == selectedCanonicalKey
              }) else { return }
        clearSession()
        self.selectedProjectID = nil
        selectedProjectCanonicalKey = nil
        selectedProjectDisplayName = nil
        searchMain()
        loadProjectSessions()
    }

    private func loadProjectSessions(ensuring ensuringSessionID: Int64? = nil) {
        let request = UUID()
        projectRequestID = request
        let projectCanonicalKey = selectedProjectCanonicalKey
        sessions = []
        guard let database else { return }
        Task {
            let rows = await projectSessions(
                canonicalKey: projectCanonicalKey,
                ensuring: ensuringSessionID,
                database: database
            )
            guard projectRequestID == request,
                  selectedProjectCanonicalKey == projectCanonicalKey else { return }
            sessions = rows
        }
    }

    private func projectSessions(
        canonicalKey: String?,
        ensuring sessionID: Int64? = nil,
        database: IndexDatabase
    ) async -> [SessionSummary] {
        let lookup = await lookupSession(id: sessionID, database: database)
        return await projectSessions(
            canonicalKey: canonicalKey, ensuring: lookup.session, database: database
        )
    }

    private func projectSessions(
        canonicalKey: String?,
        ensuring session: SessionSummary?,
        database: IndexDatabase
    ) async -> [SessionSummary] {
        var rows = (try? await database.sessions(projectCanonicalKey: canonicalKey)) ?? []
        if let session, !rows.contains(where: { $0.id == session.id }),
           session.projectCanonicalKey == canonicalKey {
            rows.append(session)
            rows.sort {
                if $0.lastActivityMilliseconds != $1.lastActivityMilliseconds {
                    return $0.lastActivityMilliseconds > $1.lastActivityMilliseconds
                }
                return $0.id > $1.id
            }
        }
        return rows
    }

    private func lookupSession(
        id: Int64?, database: IndexDatabase
    ) async -> SessionLookupResult {
        guard let id else { return .init(succeeded: true, session: nil) }
        do {
            return .init(succeeded: true, session: try await database.session(id: id))
        } catch {
            return .init(succeeded: false, session: nil)
        }
    }

    func selectSession(_ sessionID: Int64, showWindow: Bool = false, messageID: Int64? = nil) {
        mayRestoreSession = false
        if sidebarRevealRequest?.sessionID != sessionID {
            invalidateSidebarRevealRequest()
        }
        if selectedSessionID == sessionID, selectedSession != nil, messageID == nil {
            if showWindow { NotificationCenter.default.post(name: .traceShowMainWindow, object: nil) }
            return
        }
        selectedSessionID = sessionID
        settings.lastSessionID = sessionID
        selectedSession = (sessions + recentSessions).first { $0.id == sessionID }
        if let selectedSession,
           adoptProjectIdentity(from: selectedSession) {
            loadProjectSessions(ensuring: sessionID)
        }
        let request = UUID()
        sessionRequestID = request
        requestedMessageID = messageID
        messages = []
        hydratedMessages.removeAll(keepingCapacity: true)
        hydrationFailures.removeAll(keepingCapacity: true)
        hydrationOrder.removeAll(keepingCapacity: true)
        hydratingMessageIDs.removeAll(keepingCapacity: true)
        expandedReasoningIDs.removeAll()
        mainSearch.query = ""
        mainSearchNeedsRefresh = false
        syncMainSearchProjectFilter()
        mainSearch.search(sort: settings.searchSort)
        guard let database else { return }
        Task {
            let session = try? await database.session(id: sessionID)
            let rows = (try? await database.messages(sessionID: sessionID)) ?? []
            guard sessionRequestID == request, selectedSessionID == sessionID else { return }
            selectedSession = session
            if let session,
               adoptProjectIdentity(from: session) {
                syncMainSearchProjectFilter()
                loadProjectSessions(ensuring: sessionID)
            }
            messages = rows
            scrollRequest = UUID()
            try? await diagnostics.recordOpen()
            if showWindow, sessionRequestID == request {
                NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
            }
        }
    }

    func openSession(_ session: SessionSummary) {
        prepareExternalSessionSelection(
            projectID: session.projectID,
            projectCanonicalKey: session.projectCanonicalKey,
            projectDisplayName: nil,
            sessionID: session.id
        )
        selectSession(session.id, showWindow: true)
    }

    func openSearchResult(_ result: SearchResult) {
        prepareExternalSessionSelection(
            projectID: result.projectID,
            projectCanonicalKey: result.projectCanonicalKey,
            projectDisplayName: result.projectName,
            sessionID: result.sessionID
        )
        selectSession(result.sessionID, showWindow: true, messageID: result.id)
    }

    private func prepareExternalSessionSelection(
        projectID: Int64,
        projectCanonicalKey: String,
        projectDisplayName: String?,
        sessionID: Int64
    ) {
        let project = projects.first { $0.canonicalKey == projectCanonicalKey }
        let resolvedDisplayName = project?.displayName ?? projectDisplayName
        selectedProjectID = project?.id ?? projectID
        selectedProjectCanonicalKey = projectCanonicalKey
        selectedProjectDisplayName = resolvedDisplayName

        let filter = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !filter.isEmpty,
           resolvedDisplayName?.localizedCaseInsensitiveContains(filter) != true {
            projectFilter = ""
        }
        setSidebarRevealRequest(
            .init(projectCanonicalKey: projectCanonicalKey, sessionID: sessionID)
        )
        loadProjectSessions(ensuring: sessionID)
    }

    @discardableResult
    private func adoptProjectIdentity(from session: SessionSummary) -> Bool {
        let previousCanonicalKey = selectedProjectCanonicalKey
        let previousDisplayName = selectedProjectDisplayName
        let project = projects.first { $0.canonicalKey == session.projectCanonicalKey }
        selectedProjectCanonicalKey = session.projectCanonicalKey
        selectedProjectID = project?.id ?? session.projectID
        selectedProjectDisplayName = project?.displayName ?? (
            previousCanonicalKey == session.projectCanonicalKey
                ? previousDisplayName
                : nil
        )
        return previousCanonicalKey != session.projectCanonicalKey
    }

    private func setSidebarRevealRequest(_ request: SidebarRevealRequest) {
        sidebarRevealFallbackTask?.cancel()
        sidebarProjectRevealAcknowledged = false
        sidebarSessionRevealAcknowledged = false
        sidebarRevealRequest = request
        let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SIDEBAR_REVEAL_FALLBACK_DELAY_MS", cappedAt: 5_000
        ) ?? 5_000
        sidebarRevealFallbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { return }
            guard let self, self.sidebarRevealRequest?.token == request.token else { return }
            TraceTestHooks.touch(pathKey: "TRACE_TEST_SIDEBAR_REVEAL_FALLBACK_PATH")
            self.invalidateSidebarRevealRequest(token: request.token)
        }
    }

    private func invalidateSidebarRevealRequest(token: UUID? = nil) {
        if let token, sidebarRevealRequest?.token != token { return }
        sidebarRevealFallbackTask?.cancel()
        sidebarRevealFallbackTask = nil
        sidebarRevealRequest = nil
        sidebarProjectRevealAcknowledged = false
        sidebarSessionRevealAcknowledged = false
    }

    func acknowledgeSidebarProjectReveal(token: UUID) {
        guard sidebarRevealRequest?.token == token else { return }
        sidebarProjectRevealAcknowledged = true
        finishSidebarRevealIfAcknowledged()
    }

    func acknowledgeSidebarSessionReveal(token: UUID) {
        guard sidebarRevealRequest?.token == token else { return }
        sidebarSessionRevealAcknowledged = true
        finishSidebarRevealIfAcknowledged()
    }

    private func finishSidebarRevealIfAcknowledged() {
        guard sidebarProjectRevealAcknowledged,
              sidebarSessionRevealAcknowledged else { return }
        invalidateSidebarRevealRequest()
    }

    func copyMessage(id: Int64) {
        guard let coordinator else { return }
        Task {
            do {
                let message = try await coordinator.hydrate(messageID: id)
                let sections = message.sections
                let text = [sections.prose, sections.toolInvocation, sections.toolOutput, sections.reasoning]
                    .filter { !$0.isEmpty }.joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } catch {
                startupError = "Could not copy message: \(error.localizedDescription)"
            }
        }
    }

    func hydrate(_ message: MessageSummary) {
        if hydratedMessages[message.id] != nil {
            hydrationOrder.removeAll { $0 == message.id }
            hydrationOrder.append(message.id)
            return
        }
        guard !hydratingMessageIDs.contains(message.id), let coordinator else { return }
        hydratingMessageIDs.insert(message.id)
        let request = sessionRequestID
        let generation = selectedSession?.sourceGeneration
        hydrationFailures.remove(message.id)
        Task {
            defer { hydratingMessageIDs.remove(message.id) }
            let start = ContinuousClock.now
            do {
                let hydrated = try await coordinator.hydrate(message)
                guard sessionRequestID == request, selectedSession?.sourceGeneration == generation else { return }
                var cache = hydratedMessages
                cache[message.id] = hydrated
                hydrationOrder.removeAll { $0 == message.id }
                hydrationOrder.append(message.id)
                if hydrationOrder.count > hydrationCacheLimit {
                    let evicted = hydrationOrder.removeFirst()
                    cache.removeValue(forKey: evicted)
                }
                hydratedMessages = cache
                let elapsed = start.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                try? await diagnostics.recordOpen(hydrationMilliseconds: milliseconds)
            } catch {
                guard sessionRequestID == request, selectedSession?.sourceGeneration == generation else { return }
                hydrationFailures.insert(message.id)
                startupError = "Could not read source message: \(error.localizedDescription)"
            }
        }
    }

    func revealSelectedSession() {
        guard let session = (sessions + recentSessions).first(where: { $0.id == selectedSessionID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.sourcePath)])
    }

    func copyTranscript() {
        guard let coordinator else { return }
        let summaries = messages
        let expanded = expandedReasoningIDs
        let visibility = settings.transcriptVisibility
        Task {
            var blocks: [String] = []
            for summary in summaries where visibility.includes(summary) {
                guard let hydrated = try? await coordinator.hydrate(summary) else { continue }
                let body = visibility.text(hydrated, expandedReasoning: expanded.contains(summary.id))
                if !body.isEmpty { blocks.append("## \(hydrated.role.rawValue)\n\n\(body)") }
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(blocks.joined(separator: "\n\n"), forType: .string)
        }
    }

    func reloadCosts() {
        let dates = costDateBounds()
        usage = completedUsage.filter { row in
            (dates.from.map { row.day >= $0 } ?? true)
                && (dates.through.map { row.day <= $0 } ?? true)
                && (settings.includeSidechains || !row.isSidechain)
        }
    }

    private func loadCachedUsageAtStartup() async {
        guard let database else { return }
        let revision = completedUsageRevision
        do {
            let snapshot = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
            guard completedUsageRevision == revision else { return }
            completedUsage = snapshot
            reloadCosts()
        } catch {
            if completedUsageRevision == revision {
                costsError = "Could not load cached token totals: \(error.localizedDescription)"
            }
        }
    }

    private func scheduleCompletedUsageRefresh(repairIfDirty: Bool) {
        usageRefreshPending = true
        if repairIfDirty { usageRepairPending = true }
        updateCostsTotalsUpdating()
        Task { [weak self] in
            await self?.refreshCompletedUsage(repairIfDirty: repairIfDirty)
        }
    }

    private func scheduleDeferredUsageRepair() {
        usageRepairPending = true
        usageRefreshPending = true
        updateCostsTotalsUpdating()
        guard deferredUsageRepairTask == nil else { return }
        deferredUsageRepairTask = Task { [weak self] in
            guard let self else { return }
            await self.scheduler?.waitUntilIdle()
            guard !Task.isCancelled else { return }
            if self.indexingPassActive {
                self.deferredUsageRepairTask = nil
                return
            }
            TraceTestHooks.touch(
                pathKey: "TRACE_TEST_USAGE_REPAIR_QUIET_PERIOD_STARTED_PATH"
            )
            let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_USAGE_REPAIR_QUIET_DELAY_MS", cappedAt: 5_000
            ) ?? 1_000
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self.scheduler?.waitUntilIdle()
            guard !Task.isCancelled else { return }
            if self.indexingPassActive {
                self.deferredUsageRepairTask = nil
                return
            }
            self.deferredUsageRepairTask = nil
            if self.usageRepairPending {
                await self.refreshCompletedUsage(repairIfDirty: true)
            }
        }
    }

    private func refreshCompletedUsage(repairIfDirty: Bool) async {
        usageRefreshPending = true
        if repairIfDirty { usageRepairPending = true }
        updateCostsTotalsUpdating()
        guard let database else {
            usageRefreshPending = false
            if repairIfDirty { usageRepairPending = false }
            updateCostsTotalsUpdating()
            return
        }
        if repairIfDirty && indexingPassActive {
            usageRepairPending = true
            return
        }
        let request = UUID()
        usageSnapshotRequestID = request
        do {
            if let delay = TraceTestHooks.delayMilliseconds(
                for: "TRACE_TEST_USAGE_SNAPSHOT_DELAY_MS",
                cappedAt: 5_000,
                marker: .line("started", pathKey: "TRACE_TEST_USAGE_SNAPSHOT_STARTED_PATH")
            ) {
                try await Task.sleep(for: .milliseconds(delay))
            }
            guard usageSnapshotRequestID == request else { return }
            if repairIfDirty { try await database.rebuildUsageRollupsIfDirty() }
            let snapshot = try await database.usage(
                fromDay: nil, throughDay: nil, includeSidechains: true
            )
            guard usageSnapshotRequestID == request else { return }
            if indexingPassActive {
                usageRepairPending = usageRepairPending || repairIfDirty
                return
            }
            completedUsage = snapshot
            completedUsageRevision += 1
            if repairIfDirty { usageRepairPending = false }
            usageRefreshPending = usageRepairPending
            costsError = nil
            updateCostsTotalsUpdating()
            reloadCosts()
        } catch is CancellationError {
            guard usageSnapshotRequestID == request else { return }
            usageRepairPending = usageRepairPending || repairIfDirty
            usageRefreshPending = usageRepairPending
            updateCostsTotalsUpdating()
        } catch {
            guard usageSnapshotRequestID == request else { return }
            costsError = "Could not update token totals: \(error.localizedDescription)"
            if repairIfDirty { usageRepairPending = false }
            usageRefreshPending = usageRepairPending
            updateCostsTotalsUpdating()
        }
    }

    private func updateCostsTotalsUpdating() {
        let updating = indexingPassActive || usageRefreshPending
        if costsTotalsUpdating != updating { costsTotalsUpdating = updating }
    }

    func refreshDiagnostics() {
        Task { diagnosticsSnapshot = await diagnostics.value() }
    }

    func resetDiagnostics() {
        Task {
            try? await diagnostics.reset()
            diagnosticsSnapshot = await diagnostics.value()
        }
    }

    func exportDiagnostics(to url: URL) {
        Task { try? await diagnostics.export(to: url) }
    }

    func prepareToTerminate() async {
        invalidateWatchers()
        sourceChangeTask?.cancel()
        cancelAutomaticSearch()
        invalidateSidebarRevealRequest()
        if let timeZoneObserver {
            NotificationCenter.default.removeObserver(timeZoneObserver)
            self.timeZoneObserver = nil
        }
        await scheduler?.stop()
        try? await diagnostics.markCleanShutdown()
    }

    private func makeSources() async -> [any SessionSource] {
        let testDirectory = TraceRuntime.testDirectory
        let additionalClaudeRoots = settings.additionalClaudeRoots
        let useConfiguredTestRoots = ProcessInfo.processInfo.environment[
            "TRACE_TEST_DYNAMIC_CLAUDE_ROOTS"
        ] == "1"
        return await Task.detached(priority: .userInitiated) { () -> [any SessionSource] in
            if let directory = testDirectory {
                let roots = directory.appendingPathComponent("Sources")
                let claudeRoots = [roots.appendingPathComponent("Claude")]
                    + (useConfiguredTestRoots
                        ? additionalClaudeRoots.map { URL(fileURLWithPath: $0) } : [])
                return [ClaudeCodeSource(roots: claudeRoots),
                        CodexSource(root: roots.appendingPathComponent("Codex")),
                        GeminiSource(root: roots.appendingPathComponent("Gemini"))]
            }
            let defaultClaude = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects")
            let custom = additionalClaudeRoots.map { URL(fileURLWithPath: $0) }
            return [ClaudeCodeSource(roots: [defaultClaude] + custom),
                    CodexSource(), GeminiSource()]
        }.value
    }

    private func startWatching(
        _ sources: [any SessionSource], forceRootReconciliation: Bool = false
    ) async -> Bool {
        guard settings.onboardingComplete, let database else { return false }
        if !forceRootReconciliation, !watchers.isEmpty { return true }
        let generation = beginWatcherConfiguration()
        let roots = sources.flatMap(\.roots).map(\.scanURL)
        let metadataRoots = sources.filter { $0.agent == .codex }
            .flatMap(\.roots).map { $0.url.deletingLastPathComponent() }
        let canonicalRoots = roots.map { TraceFileIO.canonicalPath($0.path) }
        let canonicalMetadataRoots = metadataRoots.map { TraceFileIO.canonicalPath($0.path) }
        var reconciliationPaths = forceRootReconciliation
            ? Set(canonicalRoots.map(\.path))
            : []

        let statistics = try? await database.statistics()
        guard generation == watcherGeneration, !Task.isCancelled else { return false }
        let hasCachedIndex = (statistics?.sourceFileCount ?? 0) > 0
        var grouped: [String: [URL]] = [:]
        for root in roots + metadataRoots {
            let volumeID = Self.volumeIdentifier(for: root)
            let groupingID = watcherGroupingPolicy.groupIdentifier(
                for: root, volumeIdentifier: volumeID
            )
            grouped[groupingID, default: []].append(root)
        }
        var configurations: [(id: String, roots: [URL], checkpoint: UInt64?)] = []
        for (groupingID, groupRoots) in grouped.sorted(by: { $0.key < $1.key }) {
            let checkpoint = try? await database.eventCheckpoint(volumeID: groupingID)
            guard generation == watcherGeneration, !Task.isCancelled else { return false }
            if checkpoint == nil {
                let sourcePaths = groupRoots.map { TraceFileIO.canonicalPath($0.path) }
                    .filter { candidate in canonicalRoots.contains { $0.comparisonKey == candidate.comparisonKey } }
                    .map(\.path)
                reconciliationPaths.formUnion(sourcePaths)
            }
            configurations.append((groupingID, groupRoots, checkpoint))
        }

        guard generation == watcherGeneration, !Task.isCancelled else { return false }
        watchedSourceRoots = canonicalRoots.map { URL(fileURLWithPath: $0.path) }
        watcherStartupPending = true
        bufferedSourceChanges = SourceChanges()
        startupReconciliationPaths = reconciliationPaths
        startupActivity = Self.startupActivity(
            hasCachedIndex: hasCachedIndex,
            forceRootReconciliation: forceRootReconciliation,
            reconciliationPaths: startupReconciliationPaths
        )

        let replacements = configurations.map { configuration in
            (configuration, FSEventsWatcher(
                roots: configuration.roots, identifier: configuration.id,
                sinceWhen: configuration.checkpoint
            ) { [weak self] changes in
                Task { @MainActor [weak self] in
                    guard let self, self.settings.onboardingComplete,
                          self.watcherGeneration == generation else { return }
                    var relevant = SourceChanges()
                    relevant.paths = Set(changes.paths.compactMap { path -> String? in
                        let canonical = TraceFileIO.canonicalPath(path)
                        if canonicalRoots.contains(where: { $0.contains(canonical) }) { return canonical.path }
                        let url = URL(fileURLWithPath: canonical.path)
                        let parent = TraceFileIO.canonicalPath(url.deletingLastPathComponent().path)
                        if canonicalMetadataRoots.contains(where: { $0.comparisonKey == parent.comparisonKey }),
                           TraceFileIO.isCodexMetadataChangePath(url) { return canonical.path }
                        return nil
                    })
                    for path in changes.reconciliationPaths {
                        let changed = TraceFileIO.canonicalPath(path)
                        for root in canonicalRoots where root.intersects(changed) {
                            relevant.reconciliationPaths.insert(
                                changed.contains(root) ? root.path : changed.path
                            )
                        }
                    }
                    relevant.recoveryReasons = changes.recoveryReasons
                    relevant.watermarks = changes.watermarks
                    relevant.streamRoots = changes.streamRoots
                    relevant.historyDone = changes.historyDone
                    guard !relevant.paths.isEmpty || relevant.requiresReconciliation
                        || !relevant.watermarks.isEmpty else { return }
                    if self.watcherStartupPending { self.bufferedSourceChanges.merge(relevant) }
                    else { await self.submitSourceChanges(relevant) }
                }
            })
        }
        guard generation == watcherGeneration, !Task.isCancelled else { return false }
        var started: [FSEventsWatcher] = []
        var failedRoots: [URL] = []
        for (configuration, watcher) in replacements {
            if watcher.start() { started.append(watcher) }
            else { failedRoots += configuration.roots }
        }
        watchers = started
        if !failedRoots.isEmpty {
            let failedCanonical = failedRoots.map { TraceFileIO.canonicalPath($0.path) }
            startupReconciliationPaths.formUnion(canonicalRoots.compactMap { root in
                failedCanonical.contains(where: { $0.intersects(root) }) ? root.path : nil
            })
            startupError = "Some source folders could not be monitored; periodic reconciliation remains active."
            startupActivity = Self.startupActivity(
                hasCachedIndex: hasCachedIndex,
                forceRootReconciliation: forceRootReconciliation,
                reconciliationPaths: startupReconciliationPaths
            )
        }
        return true
    }

    private static func startupActivity(
        hasCachedIndex: Bool, forceRootReconciliation: Bool,
        reconciliationPaths: Set<String>
    ) -> IndexActivity {
        guard !reconciliationPaths.isEmpty else { return .cachedLaunch }
        guard hasCachedIndex else { return .initialBuild }
        return forceRootReconciliation ? .rootRecovery : .launchReconciliation
    }

    private static func recoveryActivity(
        for recovery: IndexRecoveryWork, sources: [any SessionSource]
    ) -> IndexActivity {
        let rootKeys = Set(sources.flatMap(\.roots).map {
            TraceFileIO.canonicalPath($0.scanURL.path).comparisonKey
        })
        let includesRoot = recovery.reconciliationPaths.contains {
            rootKeys.contains(TraceFileIO.canonicalPath($0).comparisonKey)
        }
        return includesRoot ? .rootRecovery : .subtreeRecovery
    }

    private func submitSourceChanges(_ changes: SourceChanges) async {
        guard let scheduler else { return }
        await scheduler.request(
            paths: changes.paths,
            reconciliationPaths: changes.reconciliationPaths,
            scope: settings.indexScope,
            activity: changes.hasIndexWork ? activity(for: changes) : .fileChanges,
            watermarks: changes.watermarks,
            streamRoots: changes.streamRoots
        )
    }

    private func activity(for changes: SourceChanges) -> IndexActivity {
        if changes.recoveryReasons.contains(.eventsDropped)
            || changes.recoveryReasons.contains(.eventIDsWrapped) { return .eventStreamRecovery }
        if changes.recoveryReasons.contains(.rootChanged) { return .rootRecovery }
        if changes.requiresReconciliation { return .subtreeRecovery }
        return changes.historyDone ? .launchCatchUp : .fileChanges
    }

    private func beginWatcherConfiguration() -> UInt64 {
        watcherGeneration &+= 1
        watchers.forEach { $0.stop() }
        watchers = []
        safetyVerificationTask?.cancel()
        safetyVerificationTask = nil
        return watcherGeneration
    }

    private func invalidateWatchers() {
        _ = beginWatcherConfiguration()
        watchedSourceRoots = []
        watcherStartupPending = true
        bufferedSourceChanges = SourceChanges()
    }

    private func startSafetyVerificationLoop() {
        guard safetyVerificationTask == nil, database != nil, scheduler != nil else { return }
        let generation = watcherGeneration
        safetyVerificationTask = Task { [weak self] in
            guard let self else { return }
            await self.runSafetyVerificationLoop(generation: generation)
            if self.watcherGeneration == generation {
                self.safetyVerificationTask = nil
            }
        }
    }

    private func runSafetyVerificationLoop(generation: UInt64) async {
        let day = Int64(TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SAFETY_INTERVAL_MS"
        ) ?? 24 * 60 * 60 * 1_000)
        let startupDelay = Int64(TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SAFETY_START_DELAY_MS"
        ) ?? 3_000)
        let retryDelay = Int64(TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SAFETY_RETRY_DELAY_MS"
        ) ?? 15 * 60 * 1_000)
        var firstDueCheck = true
        var retryNotBefore: Int64?

        while !Task.isCancelled, generation == watcherGeneration {
            guard let database, let scheduler else { return }
            let lastSuccess = try? await database.lastSafetyReconciliationMilliseconds()
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            var dueAt = lastSuccess.map { $0 + day } ?? now
            if let retryNotBefore { dueAt = max(dueAt, retryNotBefore) }
            var delay = max(0, dueAt - now)
            if firstDueCheck, delay == 0 { delay = startupDelay }
            firstDueCheck = false
            if delay > 0 {
                do { try await Task.sleep(for: .milliseconds(delay)) }
                catch { return }
            }
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            await scheduler.waitUntilIdle()
            guard !Task.isCancelled, generation == watcherGeneration else { return }

            let refreshedLast = try? await database.lastSafetyReconciliationMilliseconds()
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            let refreshedNow = Int64(Date().timeIntervalSince1970 * 1_000)
            if let refreshedLast, refreshedNow - refreshedLast < day {
                retryNotBefore = nil
                continue
            }

            let before = refreshedLast
            await scheduler.request(
                reconciliationPaths: Set(watchedSourceRoots.map {
                    TraceFileIO.canonicalPath($0.path).path
                }),
                scope: settings.indexScope,
                activity: .safetyVerification
            )
            await scheduler.waitUntilIdle()
            guard !Task.isCancelled, generation == watcherGeneration else { return }
            let after = try? await database.lastSafetyReconciliationMilliseconds()
            if after == before {
                retryNotBefore = Int64(Date().timeIntervalSince1970 * 1_000) + retryDelay
            } else {
                retryNotBefore = nil
            }
        }
    }

    private static func volumeIdentifier(for url: URL) -> String {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        if let identifier = try? candidate.resourceValues(
            forKeys: [.volumeUUIDStringKey]
        ).volumeUUIDString { return identifier }
        var info = stat()
        if stat(candidate.path, &info) == 0 { return "device-\(UInt64(info.st_dev))" }
        return "volume-unknown"
    }

    private func reloadSummaries(
        lightweight: Bool = false,
        loadCosts: Bool = true,
        projectReconciliation: ProjectReconciliationMode = .ongoing,
        terminalPhase: IndexProgress.Phase? = nil
    ) async {
        guard let database else { return }
        let refresh = UUID()
        summaryRequestID = refresh
        let loadedProjects = try? await database.projects()
        let loadedRecent = (try? await database.sessions(limit: 10)) ?? []
        let projectCanonicalKey = selectedProjectCanonicalKey
        let projectRequest = projectRequestID
        let ensuredSessionID = selectedSessionID
        let selectedSessionRequest = sessionRequestID
        let loadedSelectedSession = await lookupSession(
            id: ensuredSessionID, database: database
        )
        let loadedSessions = await projectSessions(
            canonicalKey: projectCanonicalKey,
            ensuring: loadedSelectedSession.session,
            database: database
        )
        if projectReconciliation != .ongoing,
           let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_PROJECT_RECONCILIATION_DELAY_MS",
            cappedAt: 5_000,
            marker: .touch(pathKey: "TRACE_TEST_PROJECT_RECONCILIATION_STARTED_PATH")
           ) {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        guard summaryRequestID == refresh else { return }
        let globalProjectFilterReconciliation: SessionSearchModel.ProjectFilterReconciliation
        let mainProjectFilterReconciliation: SessionSearchModel.ProjectFilterReconciliation
        if let loadedProjects {
            globalProjectFilterReconciliation = globalSearch.resolveProjectFilter(
                in: loadedProjects,
                missingProject: projectReconciliation.globalMissingProjectPolicy
            )
            mainProjectFilterReconciliation = mainSearch.resolveProjectFilter(
                in: loadedProjects,
                missingProject: projectReconciliation.mainMissingProjectPolicy
            )
            projects = loadedProjects
            reconcileSelectedProject(in: loadedProjects)
        } else {
            switch projectReconciliation {
            case .ongoing:
                globalProjectFilterReconciliation = .unchanged
                mainProjectFilterReconciliation = .unchanged
            case .completed, .terminalRetaining:
                // A failed summary read cannot establish that a canonical project was
                // deleted. Retain both filters, but do not leave either search blocked.
                globalProjectFilterReconciliation = globalSearch.resolveProjectFilter(
                    in: projects, missingProject: .retain
                )
                mainProjectFilterReconciliation = mainSearch.resolveProjectFilter(
                    in: projects, missingProject: .retain
                )
            }
        }
        recentSessions = loadedRecent
        if globalProjectFilterReconciliation.requiresSearchRefresh,
           !globalSearch.query.isEmpty {
            globalSearchNeedsRefresh = true
            scheduleAutomaticSearch()
        }
        if mainProjectFilterReconciliation.requiresSearchRefresh,
           !mainSearch.query.isEmpty {
            mainSearchNeedsRefresh = true
            scheduleAutomaticSearch()
        }
        if selectedProjectCanonicalKey == projectCanonicalKey,
           projectRequestID == projectRequest {
            sessions = loadedSessions
        }
        if projectReconciliation != .ongoing,
           let reveal = sidebarRevealRequest {
            let projectUnavailable = loadedProjects.map { projects in
                !projects.contains(where: { $0.canonicalKey == reveal.projectCanonicalKey })
            } ?? false
            let sessionUnavailable = ensuredSessionID == reveal.sessionID
                && loadedSelectedSession.succeeded
                && (loadedSelectedSession.session == nil
                    || loadedSelectedSession.session?.projectCanonicalKey
                        != reveal.projectCanonicalKey)
            if projectUnavailable || sessionUnavailable {
                invalidateSidebarRevealRequest(token: reveal.token)
            }
        }
        if let sessionID = ensuredSessionID,
           selectedSessionID == sessionID,
           sessionRequestID == selectedSessionRequest,
           summaryRequestID == refresh,
           loadedSelectedSession.succeeded {
            let loadedSession = loadedSelectedSession.session
            if let loadedSession {
                let changed = selectedSession?.sourceGeneration != loadedSession.sourceGeneration
                selectedSession = loadedSession
                if changed || loadedSession.messageCount != messages.count {
                    let rows = (try? await database.messages(sessionID: sessionID)) ?? []
                    if selectedSessionID == sessionID,
                       sessionRequestID == selectedSessionRequest,
                       summaryRequestID == refresh {
                        if changed {
                            hydratedMessages.removeAll(keepingCapacity: true)
                            hydrationFailures.removeAll(keepingCapacity: true)
                            hydrationOrder.removeAll(keepingCapacity: true)
                            hydratingMessageIDs.removeAll(keepingCapacity: true)
                        }
                        messages = rows
                    }
                }
            } else {
                clearSession()
            }
        }
        if lightweight || summaryRequestID != refresh { return }
        sourceHealth = (try? await database.sourceHealth()) ?? []
        statistics = try? await database.statistics()
        if let bytes = statistics?.databaseBytes { try? await diagnostics.recordIndexSize(bytes: bytes) }
        guard summaryRequestID == refresh else { return }
        let restorationTerminal = terminalPhase.map {
            [.complete, .failed, .cancelled].contains($0)
        } ?? [.complete, .failed].contains(progress.phase)
        if mayRestoreSession {
            if let stored = settings.lastSessionID {
                let restored = try? await database.session(id: stored)
                guard summaryRequestID == refresh,
                      mayRestoreSession,
                      settings.lastSessionID == stored,
                      selectedSessionID == nil else { return }
                if restored != nil {
                    selectSession(stored)
                } else if restorationTerminal {
                    mayRestoreSession = false
                }
            } else if restorationTerminal {
                mayRestoreSession = false
            }
        }
        if loadCosts { reloadCosts() }
        refreshDiagnostics()
    }

    private func reconcileSelectedProject(in loadedProjects: [ProjectSummary]) {
        guard let selectedProjectCanonicalKey else {
            if selectedProjectID != nil { selectedProjectID = nil }
            if selectedProjectDisplayName != nil { selectedProjectDisplayName = nil }
            return
        }
        guard let project = loadedProjects.first(where: {
            $0.canonicalKey == selectedProjectCanonicalKey
        }) else {
            return
        }
        if selectedProjectID != project.id { selectedProjectID = project.id }
        if selectedProjectDisplayName != project.displayName {
            selectedProjectDisplayName = project.displayName
        }
    }

    private func loadPricing() {
        let candidates = [
            Bundle.main.url(forResource: "default-pricing", withExtension: "json", subdirectory: "Pricing"),
            Bundle.main.url(forResource: "default-pricing", withExtension: "json"),
        ].compactMap { $0 }
        guard let url = candidates.first else {
            pricingError = "Bundled pricing data is missing."
            return
        }
        do {
            let loaded = try PricingCatalog.load(bundledURL: url, overrideURL: TraceRuntime.testDirectory?.appendingPathComponent("pricing.json") ?? PricingCatalog.defaultOverrideURL())
            pricing = loaded.catalog
            pricingError = loaded.overrideError
        } catch {
            pricingError = error.localizedDescription
        }
    }

    private func costDateBounds() -> (from: String?, through: String?) {
        let calendar = Calendar.current
        let now = Date()
        let start: Date?
        switch settings.costRange {
        case .sevenDays: start = calendar.date(byAdding: .day, value: -6, to: now)
        case .thirtyDays: start = calendar.date(byAdding: .day, value: -29, to: now)
        case .yearToDate: start = calendar.date(from: calendar.dateComponents([.year], from: now))
        case .allTime: start = nil
        case .custom: start = customCostStart
        }
        let end = settings.costRange == .custom ? customCostEnd : now
        return (start.map(Self.dayFormatter.string), Self.dayFormatter.string(from: end))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

@MainActor
final class TraceEnvironment {
    static let shared = TraceEnvironment()
    let settings: AppSettings
    lazy var model = TraceModel(
        settings: settings,
        watcherGroupingPolicy: TraceTestHooks.isUITesting
            && TraceTestHooks.environment["TRACE_TEST_SPLIT_WATCHERS_BY_ROOT"] == "1"
            ? .byRoot
            : .byVolume,
        startupActivityObserver: { activity in
            TraceTestHooks.appendLine(
                activity.rawValue, pathKey: "TRACE_TEST_STARTUP_ACTIVITY_AUDIT_PATH"
            )
        }
    )
    private init() {
        let settings = AppSettings()
        if TraceTestHooks.isUITesting {
            let environment = TraceTestHooks.environment
            if environment["TRACE_TEST_SEED_ONBOARDING_COMPLETE"] == "1" {
                settings.onboardingComplete = true
            }
            if settings.additionalClaudeRoots.isEmpty,
               let encodedRoots = environment["TRACE_TEST_SEED_ADDITIONAL_CLAUDE_ROOTS"],
               let data = encodedRoots.data(using: .utf8),
               let roots = try? JSONDecoder().decode([String].self, from: data) {
                settings.additionalClaudeRoots = roots
            }
        }
        self.settings = settings
    }
}
