import AppKit
import Combine
import Foundation
import TraceCore

@MainActor
final class TraceModel: ObservableObject {
    var settings: AppSettings
    let globalSearch = SessionSearchModel()
    var mainSearch = SessionSearchModel()
    private var observations: Set<AnyCancellable> = []
    let diagnostics: DiagnosticsStore

    @Published private(set) var progress = IndexProgress(phase: .waiting)
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var recentSessions: [SessionSummary] = []
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var hydratedMessages: [Int64: HydratedMessage] = [:]
    var searchResults: [SearchResult] { globalSearch.results }
    var searchSnippets: [Int64: String] { globalSearch.snippets }
    @Published private(set) var sessionErrors: [Int64: String] = [:]
    @Published var projectFilter = ""
    @Published private(set) var selectedSession: SessionSummary?
    private var errorTasks: [Int64: Task<Void, Never>] = [:]
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var usage: [UsageRollup] = []
    @Published private(set) var statistics: IndexStatistics?
    @Published private(set) var diagnosticsSnapshot = DiagnosticsSnapshot()
    @Published private(set) var pricing: PricingCatalog?
    @Published private(set) var pricingError: String?
    @Published var selectedProjectID: Int64?
    @Published var selectedSessionID: Int64?
    var searchQuery: String {
        get { globalSearch.query }
        set { globalSearch.query = newValue }
    }
    var searchFilters: SearchFilters {
        get { globalSearch.filters }
        set { globalSearch.filters = newValue }
    }
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
    private var sessionRequestID = UUID()
    private var projectRequestID = UUID()
    private var started = false
    private var initialIndexRequested = false

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        diagnostics = DiagnosticsStore(url: TraceRuntime.testDirectory?.appendingPathComponent("diagnostics.json") ?? DiagnosticsStore.defaultURL())
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        globalSearch.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        mainSearch.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            do {
                try await diagnostics.markLaunchStarted()
                let database = try IndexDatabase(url: TraceRuntime.testDirectory?.appendingPathComponent("index.sqlite") ?? IndexDatabase.defaultURL())
                self.database = database
                let sources = makeSources()
                let coordinator = IndexCoordinator(database: database, sources: sources)
                self.coordinator = coordinator
                globalSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
                mainSearch.attach(database: database, coordinator: coordinator, diagnostics: diagnostics)
                scheduler = makeScheduler(coordinator)
                loadPricing()
                await reloadSummaries()
                if settings.onboardingComplete {
                    startWatching(sources.flatMap(\.roots).map(\.url))
                    if ProcessInfo.processInfo.arguments.contains("--index-smoke"), TraceRuntime.testDirectory != nil {
                        await scheduler?.request(reconcile: true, scope: settings.indexScope)
                        await scheduler?.waitUntilIdle()
                        let snapshot = try await database.statistics()
                        let report: [String: Any] = ["messages": snapshot.messageCount, "sessions": snapshot.sessionCount,
                            "indexedFiles": progress.indexedFiles, "unchangedFiles": progress.unchangedFiles,
                            "failedFiles": progress.failedFiles, "phase": progress.phase.rawValue]
                        let data = try JSONSerialization.data(withJSONObject: report, options: .sortedKeys)
                        FileHandle.standardOutput.write(data + Data("\n".utf8))
                        await prepareToTerminate()
                        exit(progress.phase == .complete && progress.failedFiles == 0 ? 0 : 1)
                    } else { startIndexing() }
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
        progress = update
        let terminal = [.complete, .failed, .cancelled].contains(update.phase)
        if terminal || lastSummaryRefresh.duration(to: .now) >= .milliseconds(250) {
            lastSummaryRefresh = .now
            await reloadSummaries(lightweight: !terminal)
            if !searchQuery.isEmpty { search() }
            if !mainSearch.query.isEmpty { searchMain() }
        }
    }

    func startIndexing() {
        guard settings.onboardingComplete, !initialIndexRequested, let scheduler else { return }
        initialIndexRequested = true
        Task { await scheduler.request(reconcile: true, scope: settings.indexScope) }
    }

    func rebuildIndex() {
        guard settings.onboardingComplete, let scheduler else { return }
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

    func search(reset: Bool = true) { globalSearch.search(sort: settings.searchSort, reset: reset) }
    func searchMain() {
        mainSearch.filters.projectID = selectedProjectID
        mainSearch.search(sort: settings.searchSort)
    }
    func hydrateSearchResult(_ result: SearchResult) async { await globalSearch.hydrate(result) }

    var filteredProjects: [ProjectSummary] {
        let query = projectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? projects : projects.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    func loadSessionError(_ session: SessionSummary) {
        guard sessionErrors[session.id] == nil, errorTasks[session.id] == nil, let coordinator else { return }
        errorTasks[session.id] = Task {
            defer { errorTasks[session.id] = nil }
            do {
                let failures = try await coordinator.failures(for: session)
                try Task.checkCancellation()
                sessionErrors[session.id] = failures.isEmpty
                    ? "\(session.agent.displayName) recorded an error without a detailed explanation."
                    : failures.map { failure in
                        let header = [session.agent.displayName, failure.kind.capitalized,
                            failure.timestampMilliseconds.traceDate, failure.toolName].compactMap { $0 }.joined(separator: " · ")
                        return header + "\n" + (failure.detail.isEmpty ? "The source did not provide an error message." : String(failure.detail.prefix(4_000)))
                    }.joined(separator: "\n\n")
            } catch is CancellationError { }
            catch { sessionErrors[session.id] = "Could not read error details from \(session.sourcePath): \(error.localizedDescription)" }
        }
    }

    func selectProject(_ projectID: Int64?) {
        selectedProjectID = projectID
        guard let database else { return }
        let request = UUID()
        projectRequestID = request
        searchMain()
        Task {
            let rows = (try? await database.sessions(projectID: projectID)) ?? []
            guard projectRequestID == request else { return }
            sessions = rows
        }
    }

    func selectSession(_ sessionID: Int64, showWindow: Bool = false) {
        selectedSessionID = sessionID
        settings.lastSessionID = sessionID
        selectedSession = (sessions + recentSessions).first { $0.id == sessionID } ?? selectedSession
        let request = UUID()
        sessionRequestID = request
        hydratedMessages.removeAll(keepingCapacity: true)
        guard let database else { return }
        Task {
            let rows = (try? await database.messages(sessionID: sessionID)) ?? []
            guard sessionRequestID == request else { return }
            messages = rows
            if selectedSession?.id != sessionID { selectedSession = try? await database.session(id: sessionID) }
            try? await diagnostics.recordOpen()
            if showWindow {
                NotificationCenter.default.post(name: .traceShowMainWindow, object: nil)
            }
        }
    }

    func openSearchResult(_ result: SearchResult) {
        selectedProjectID = result.projectID
        settings.lastScrollMessageID = result.id
        selectSession(result.sessionID, showWindow: true)
    }

    func hydrate(_ message: MessageSummary) {
        guard hydratedMessages[message.id] == nil, let coordinator else { return }
        let request = sessionRequestID
        let revision = selectedSession?.sourceRevision
        Task {
            let start = ContinuousClock.now
            do {
                let hydrated = try await coordinator.hydrate(message)
                guard sessionRequestID == request, selectedSession?.sourceRevision == revision else { return }
                hydratedMessages[message.id] = hydrated
                let elapsed = start.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                try? await diagnostics.recordOpen(hydrationMilliseconds: milliseconds)
            } catch {
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
        guard let database else { return }
        let dates = costDateBounds()
        Task {
            usage = (try? await database.usage(
                fromDay: dates.from,
                throughDay: dates.through,
                includeSidechains: settings.includeSidechains
            )) ?? []
        }
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
        let watcher = FSEventsWatcher(roots: roots, onChange: { [weak self] changes in
            Task { @MainActor [weak self] in
                guard let self, self.settings.onboardingComplete else { return }
                await self.scheduler?.request(paths: changes.paths, reconcile: changes.requiresReconciliation,
                                              scope: self.settings.indexScope)
            }
        })
        watcher.start()
        self.watcher = watcher
    }

    private func reloadSummaries(lightweight: Bool = false) async {
        guard let database else { return }
        let previousSessions = Dictionary((sessions + recentSessions).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projects = (try? await database.projects()) ?? []
        recentSessions = (try? await database.sessions(limit: 10)) ?? []
        let project = selectedProjectID
        let loadedSessions = (try? await database.sessions(projectID: project)) ?? []
        if selectedProjectID == project { sessions = loadedSessions }
        for session in sessions + recentSessions {
            if let old = previousSessions[session.id], old.messageCount != session.messageCount || old.lastActivityMilliseconds != session.lastActivityMilliseconds || old.sourceRevision != session.sourceRevision || old.hadError != session.hadError {
                sessionErrors[session.id] = nil
                errorTasks[session.id]?.cancel()
            }
        }
        if let sessionID = selectedSessionID {
            let loadedSession = try? await database.session(id: sessionID)
            if selectedSessionID == sessionID {
                let changed = selectedSession?.sourceRevision != loadedSession?.sourceRevision
                selectedSession = loadedSession
                if let loadedSession, changed || loadedSession.messageCount != messages.count {
                    let rows = (try? await database.messages(sessionID: sessionID)) ?? []
                    if selectedSessionID == sessionID {
                        if changed { hydratedMessages.removeAll(keepingCapacity: true) }
                        messages = rows
                    }
                }
            }
        }
        if lightweight { return }
        sourceHealth = (try? await database.sourceHealth()) ?? []
        statistics = try? await database.statistics()
        if let bytes = statistics?.databaseBytes { try? await diagnostics.recordIndexSize(bytes: bytes) }
        if selectedSessionID == nil, let stored = settings.lastSessionID,
           sessions.contains(where: { $0.id == stored }) {
            selectSession(stored)
        }
        reloadCosts()
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
            let loaded = try PricingCatalog.load(bundledURL: url)
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
