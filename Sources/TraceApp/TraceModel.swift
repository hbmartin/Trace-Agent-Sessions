import AppKit
import Darwin
import Foundation
import TraceCore

@MainActor
final class TraceModel: ObservableObject {
    enum GlobalSearchSurface: Hashable { case popover, launcher }
    let settings: AppSettings
    let globalSearch = SessionSearchModel()
    var mainSearch = SessionSearchModel()
    let diagnostics: DiagnosticsStore

    @Published private(set) var progress = IndexProgress(phase: .waiting)
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var recentSessions: [SessionSummary] = []
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var hydratedMessages: [Int64: HydratedMessage] = [:]
    @Published private(set) var hydrationFailures: Set<Int64> = []
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
    @Published var selectedProjectID: Int64?
    @Published var selectedSessionID: Int64?
    @Published var customCostStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @Published var customCostEnd = Date()
    @Published var expandedReasoningIDs: Set<Int64> = []
    @Published var startupError: String?

    private var database: IndexDatabase?
    private var coordinator: IndexCoordinator?
    private var watcher: FSEventsWatcher?
    private var scheduler: IndexScheduler?
    private var sourceChangeTask: Task<Void, Never>?
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
    private var indexingPassActive = false
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

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
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
                       let delay = ProcessInfo.processInfo.environment["TRACE_TEST_INDEX_OPEN_DELAY_MS"].flatMap(Double.init),
                       delay > 0 {
                        try await Task.sleep(for: .milliseconds(Int(min(delay, 5_000))))
                    }
                    let url = try isolatedURL ?? IndexDatabase.defaultURL()
                    return try IndexDatabase(url: url)
                }.value
                self.database = database
                if database.contentWasResetOnOpen { prepareForIndexReset() }
                let sources = makeSources()
                let coordinator = IndexCoordinator(database: database, sources: sources)
                self.coordinator = coordinator
                globalSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
                mainSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
                scheduler = makeScheduler(coordinator)
                progress.unresolvedFailedFiles = (try? await database.unresolvedSourceFailureCount()) ?? 0
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
                if settings.onboardingComplete {
                    startWatching(sources.flatMap(\.roots).map(\.url))
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
                            await self.loadCachedUsageAtStartup()
                            self.startIndexing()
                        }
                    }
                } else {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.loadCachedUsageAtStartup()
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
        if coordinator != nil {
            startWatching(makeSources().flatMap(\.roots).map(\.url))
            startIndexing()
        }
    }

    private func makeScheduler(_ coordinator: IndexCoordinator) -> IndexScheduler {
        IndexScheduler(coordinator: coordinator, scope: settings.indexScope) { [weak self] update in
            await self?.receiveProgress(update)
        }
    }

    private func receiveProgress(_ update: IndexProgress) async {
        let terminal = [.complete, .failed, .cancelled].contains(update.phase)
        indexingPassActive = !terminal
        if !terminal { usageSnapshotRequestID = UUID() }
        if terminal, TraceTestHooks.isUITesting,
           let path = TraceTestHooks.environment["TRACE_TEST_INDEX_PASS_COMPLETED_PATH"] {
            try? Data().write(to: URL(fileURLWithPath: path))
        }
        if update.incremental {
            if terminal {
                incrementalProgressTask?.cancel()
                incrementalProgressTask = nil
                pendingIncrementalProgress = nil
                if incrementalProgressVisible || update.phase == .failed || update.failedFiles > 0
                    || progress.phase == .failed || progress.failedFiles > 0
                    || update.unresolvedFailedFiles > 0 || progress.unresolvedFailedFiles > 0
                    || update.metadataWarning != nil || update.rollupError != nil {
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
        } else {
            progress = update
        }

        if terminal { handleTerminalUsageProgress(update) }
        else { updateCostsTotalsUpdating() }
        observeSearchMutation(update, terminal: terminal)

        let shouldRefresh = terminal
            || ((!update.incremental || incrementalProgressVisible)
                && lastSummaryRefresh.duration(to: .now) >= .milliseconds(250))
        if shouldRefresh {
            lastSummaryRefresh = .now
            await reloadSummaries(lightweight: !terminal)
        }
    }

    private func handleTerminalUsageProgress(_ update: IndexProgress) {
        if let rollupError = update.rollupError { costsError = rollupError }
        if update.phase != .complete && (update.indexChanged || update.rollupsChanged) {
            usageRepairPending = true
            usageRefreshPending = true
        }
        if update.phase == .complete {
            if update.rollupError != nil {
                if usageRepairPending { scheduleDeferredUsageRepair() }
                else { usageRefreshPending = false }
            } else if usageRepairPending {
                scheduleDeferredUsageRepair()
            } else if update.indexChanged || update.rollupsChanged || usageRefreshPending {
                scheduleCompletedUsageRefresh(repairIfDirty: false)
            }
        } else if usageRepairPending {
            scheduleDeferredUsageRepair()
        } else if usageRefreshPending {
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
            && !globalSearch.isWaitingForProjectFilterResolution)
        || (mainSearchNeedsRefresh && mainSearchIsVisible
            && !mainSearch.query.isEmpty && !mainSearch.protectsPagination)
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
                changed = changed || globalSearch.filters != SearchFilters()
                    || globalSearch.datePreset != .anyTime
                    || globalSearch.projectFilterCanonicalKey != nil
                globalSearch.filters = SearchFilters()
                globalSearch.clearProjectFilter()
                globalSearch.datePreset = .anyTime
            }
            if changed {
                globalSearch.search(sort: settings.searchSort)
                globalSearchNeedsRefresh = false
            }
        }
        searchVisibilityChanged()
    }

    func clearGlobalSearchFilters() {
        guard globalSearch.filters != SearchFilters() || globalSearch.datePreset != .anyTime
                || globalSearch.projectFilterCanonicalKey != nil else { return }
        globalSearch.filters = SearchFilters()
        globalSearch.clearProjectFilter()
        globalSearch.datePreset = .anyTime
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
           !globalSearch.isWaitingForProjectFilterResolution {
            globalSearchNeedsRefresh = false
            globalSearch.search(sort: settings.searchSort, trigger: .automatic)
        }
        if mainSearchNeedsRefresh, mainSearchIsVisible,
           !mainSearch.query.isEmpty, !mainSearch.protectsPagination {
            mainSearchNeedsRefresh = false
            mainSearch.filters.projectID = selectedProjectID
            mainSearch.search(sort: settings.searchSort, trigger: .automatic)
        }
    }

    func startIndexing() {
        guard settings.onboardingComplete, !initialIndexRequested, let scheduler else { return }
        initialIndexRequested = true
        Task { await scheduler.request(reconcile: true, scope: settings.indexScope) }
    }

    func rebuildIndex() {
        guard settings.onboardingComplete, let scheduler else { return }
        prepareForIndexReset()
        Task { await scheduler.request(rebuild: true, scope: settings.indexScope) }
    }

    func reloadSourcesAndRebuild() {
        sourceChangeTask?.cancel()
        watcher?.stop()
        watcher = nil
        sourceChangeTask = Task {
            await scheduler?.stop()
            guard !Task.isCancelled, let database else { return }
            let sources = makeSources()
            let coordinator = IndexCoordinator(database: database, sources: sources)
            self.coordinator = coordinator
            globalSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
            mainSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
            scheduler = makeScheduler(coordinator)
            initialIndexRequested = false
            startWatching(sources.flatMap(\.roots).map(\.url))
            // Root changes reconcile existing files; unchanged sources retain their index.
            startIndexing()
        }
    }

    func search(reset: Bool = true) {
        if reset { globalSearchNeedsRefresh = false }
        globalSearch.search(sort: settings.searchSort, reset: reset)
    }
    func searchMain() {
        mainSearchNeedsRefresh = false
        mainSearch.filters.projectID = selectedProjectID
        mainSearch.search(sort: settings.searchSort)
    }
    var filteredProjects: [ProjectSummary] {
        let query = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? projects : projects.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    func sessionErrorText(_ session: SessionSummary) async -> String {
        if TraceRuntime.testDirectory != nil,
           let delay = ProcessInfo.processInfo.environment["TRACE_TEST_ERROR_LOAD_DELAY_MS"].flatMap(Double.init),
           delay > 0 {
            try? await Task.sleep(for: .milliseconds(Int(min(delay, 5_000))))
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
        return projects.first { $0.id == selectedProjectID }?.displayName ?? "Trace"
    }

    func clearSession() {
        mayRestoreSession = false
        sessionRequestID = UUID()
        selectedSessionID = nil
        selectedSession = nil
        settings.lastSessionID = nil
        messages = []
        hydratedMessages.removeAll()
        hydrationFailures.removeAll()
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
        selectedProjectID = nil
        selectedSessionID = nil
        selectedSession = nil
        settings.lastSessionID = nil
        projects = []
        sessions = []
        recentSessions = []
        messages = []
        hydratedMessages = [:]
        hydrationFailures = []
        expandedReasoningIDs = []
        scrollPositions = [:]
        requestedMessageID = nil
        sourceHealth = []
        statistics = nil
        globalSearch.resetForIndexReset()
        mainSearch.resetForIndexReset()
    }

    func selectProject(_ projectID: Int64?) {
        guard selectedProjectID != projectID else { return }
        clearSession()
        selectedProjectID = projectID
        loadProjectSessions()
    }

    private func loadProjectSessions() {
        let request = UUID()
        projectRequestID = request
        let project = selectedProjectID
        sessions = []
        searchMain()
        guard let database else { return }
        Task {
            let rows = (try? await database.sessions(projectID: project)) ?? []
            guard projectRequestID == request, selectedProjectID == project else { return }
            sessions = rows
        }
    }

    func selectSession(_ sessionID: Int64, showWindow: Bool = false, messageID: Int64? = nil) {
        mayRestoreSession = false
        if selectedSessionID == sessionID, selectedSession != nil, messageID == nil {
            if showWindow { NotificationCenter.default.post(name: .traceShowMainWindow, object: nil) }
            return
        }
        selectedSessionID = sessionID
        settings.lastSessionID = sessionID
        selectedSession = (sessions + recentSessions).first { $0.id == sessionID }
        let request = UUID()
        sessionRequestID = request
        requestedMessageID = messageID
        messages = []
        hydratedMessages.removeAll(keepingCapacity: true)
        hydrationFailures.removeAll(keepingCapacity: true)
        expandedReasoningIDs.removeAll()
        mainSearch.query = ""
        mainSearch.search()
        guard let database else { return }
        Task {
            let session = try? await database.session(id: sessionID)
            let rows = (try? await database.messages(sessionID: sessionID)) ?? []
            guard sessionRequestID == request, selectedSessionID == sessionID else { return }
            selectedSession = session
            if let session, selectedProjectID != session.projectID {
                selectedProjectID = session.projectID
                loadProjectSessions()
            }
            messages = rows
            scrollRequest = UUID()
            try? await diagnostics.recordOpen()
            if showWindow, sessionRequestID == request {
                NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
            }
        }
    }

    func openSearchResult(_ result: SearchResult) {
        selectSession(result.sessionID, showWindow: true, messageID: result.id)
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
        guard hydratedMessages[message.id] == nil, let coordinator else { return }
        let request = sessionRequestID
        let generation = selectedSession?.sourceGeneration
        hydrationFailures.remove(message.id)
        Task {
            let start = ContinuousClock.now
            do {
                let hydrated = try await coordinator.hydrate(message)
                guard sessionRequestID == request, selectedSession?.sourceGeneration == generation else { return }
                hydratedMessages[message.id] = hydrated
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
            if TraceTestHooks.isUITesting,
               let delay = TraceTestHooks.environment["TRACE_TEST_USAGE_SNAPSHOT_DELAY_MS"]
                .flatMap(Int.init),
               delay > 0 {
                TraceTestHooks.appendLine(
                    "started", pathKey: "TRACE_TEST_USAGE_SNAPSHOT_STARTED_PATH"
                )
                try await Task.sleep(for: .milliseconds(min(delay, 5_000)))
                guard usageSnapshotRequestID == request else { return }
            }
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
        watcher?.stop()
        sourceChangeTask?.cancel()
        cancelAutomaticSearch()
        if let timeZoneObserver {
            NotificationCenter.default.removeObserver(timeZoneObserver)
            self.timeZoneObserver = nil
        }
        await scheduler?.stop()
        try? await diagnostics.markCleanShutdown()
    }

    private func makeSources() -> [any SessionSource] {
        if let directory = TraceRuntime.testDirectory {
            let roots = directory.appendingPathComponent("Sources")
            return [ClaudeCodeSource(roots: [roots.appendingPathComponent("Claude")]),
                    CodexSource(root: roots.appendingPathComponent("Codex")),
                    GeminiSource(root: roots.appendingPathComponent("Gemini"))]
        }
        let defaultClaude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let custom = settings.additionalClaudeRoots.map { URL(fileURLWithPath: $0) }
        return [ClaudeCodeSource(roots: [defaultClaude] + custom), CodexSource(), GeminiSource()]
    }

    private func startWatching(_ roots: [URL]) {
        guard watcher == nil, settings.onboardingComplete else { return }
        let metadataRoots = makeSources().filter { $0.agent == .codex }.flatMap(\.roots).map { $0.url.deletingLastPathComponent() }
        let canonicalRoots = roots.map { TraceFileIO.canonicalPath($0.path) }
        let canonicalMetadataRoots = metadataRoots.map { TraceFileIO.canonicalPath($0.path) }
        let watcher = FSEventsWatcher(roots: roots + metadataRoots, onChange: { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, self.settings.onboardingComplete else { return }
                let paths = changes.paths.compactMap { path -> String? in
                    let canonical = TraceFileIO.canonicalPath(path)
                    if canonicalRoots.contains(where: { $0.contains(canonical) }) { return canonical.path }
                    let url = URL(fileURLWithPath: canonical.path)
                    let parent = TraceFileIO.canonicalPath(url.deletingLastPathComponent().path)
                    if canonicalMetadataRoots.contains(where: { $0.comparisonKey == parent.comparisonKey }),
                       TraceFileIO.isCodexMetadataSidecar(url) {
                        return canonical.path
                    }
                    return nil
                }
                let reconcile = changes.reconciliationPaths.contains { path in
                    let changed = TraceFileIO.canonicalPath(path)
                    return canonicalRoots.contains { $0.intersects(changed) }
                }
                guard !paths.isEmpty || reconcile else { return }
                await self.scheduler?.request(paths: Set(paths), reconcile: reconcile,
                                              scope: self.settings.indexScope)
            }
        })
        watcher.start()
        self.watcher = watcher
    }

    private func reloadSummaries(lightweight: Bool = false, loadCosts: Bool = true) async {
        guard let database else { return }
        let refresh = UUID()
        summaryRequestID = refresh
        let loadedProjects = (try? await database.projects()) ?? []
        let loadedRecent = (try? await database.sessions(limit: 10)) ?? []
        let project = selectedProjectID
        let projectRequest = projectRequestID
        let loadedSessions = (try? await database.sessions(projectID: project)) ?? []
        guard summaryRequestID == refresh else { return }
        let projectFilterChanged = globalSearch.resolveProjectFilter(
            in: loadedProjects, final: !lightweight
        )
        projects = loadedProjects
        recentSessions = loadedRecent
        if projectFilterChanged, !globalSearch.query.isEmpty {
            globalSearchNeedsRefresh = true
            scheduleAutomaticSearch()
        }
        if selectedProjectID == project, projectRequestID == projectRequest { sessions = loadedSessions }
        if let sessionID = selectedSessionID {
            let request = sessionRequestID
            let loadedSession = try? await database.session(id: sessionID)
            if selectedSessionID == sessionID, sessionRequestID == request, summaryRequestID == refresh {
                if let loadedSession {
                    let changed = selectedSession?.sourceGeneration != loadedSession.sourceGeneration
                    selectedSession = loadedSession
                    if changed || loadedSession.messageCount != messages.count {
                        let rows = (try? await database.messages(sessionID: sessionID)) ?? []
                        if selectedSessionID == sessionID, sessionRequestID == request,
                           summaryRequestID == refresh {
                            if changed {
                                hydratedMessages.removeAll(keepingCapacity: true)
                                hydrationFailures.removeAll(keepingCapacity: true)
                            }
                            messages = rows
                        }
                    }
                } else {
                    clearSession()
                }
            }
        }
        if lightweight || summaryRequestID != refresh { return }
        sourceHealth = (try? await database.sourceHealth()) ?? []
        statistics = try? await database.statistics()
        if let bytes = statistics?.databaseBytes { try? await diagnostics.recordIndexSize(bytes: bytes) }
        guard summaryRequestID == refresh else { return }
        if mayRestoreSession {
            if let stored = settings.lastSessionID {
                let restored = try? await database.session(id: stored)
                guard summaryRequestID == refresh,
                      mayRestoreSession,
                      settings.lastSessionID == stored,
                      selectedSessionID == nil else { return }
                if restored != nil {
                    selectSession(stored)
                } else if [.complete, .failed].contains(progress.phase) {
                    mayRestoreSession = false
                }
            } else if [.complete, .failed].contains(progress.phase) {
                mayRestoreSession = false
            }
        }
        if loadCosts { reloadCosts() }
        refreshDiagnostics()
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
    let settings = AppSettings()
    lazy var model = TraceModel(settings: settings)
    private init() {}
}
