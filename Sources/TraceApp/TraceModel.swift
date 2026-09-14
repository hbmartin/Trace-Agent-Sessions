import AppKit
import Combine
import Foundation
import TraceCore

@MainActor
final class TraceModel: ObservableObject {
    var settings: AppSettings
    let diagnostics = DiagnosticsStore()

    @Published private(set) var progress = IndexProgress(phase: .discovering)
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var recentSessions: [SessionSummary] = []
    @Published private(set) var messages: [MessageSummary] = []
    @Published private(set) var hydratedMessages: [Int64: HydratedMessage] = [:]
    @Published private(set) var searchResults: [SearchResult] = []
    @Published private(set) var searchSnippets: [Int64: String] = [:]
    @Published private(set) var sourceHealth: [SourceHealth] = []
    @Published private(set) var usage: [UsageRollup] = []
    @Published private(set) var statistics: IndexStatistics?
    @Published private(set) var diagnosticsSnapshot = DiagnosticsSnapshot()
    @Published private(set) var pricing: PricingCatalog?
    @Published private(set) var pricingError: String?
    @Published var selectedProjectID: Int64?
    @Published var selectedSessionID: Int64?
    @Published var searchQuery = ""
    @Published var searchFilters = SearchFilters()
    @Published var customCostStart = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
    @Published var customCostEnd = Date()
    @Published var expandedReasoningIDs: Set<Int64> = []
    @Published var startupError: String?

    private var database: IndexDatabase?
    private var coordinator: IndexCoordinator?
    private var watcher: FSEventsWatcher?
    private var searchTask: Task<Void, Never>?
    private var searchRequestID = UUID()
    private var nextSearchCursor: SearchCursor?
    private var indexTask: Task<Void, Never>?
    private var started = false

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    func start() {
        guard !started else { return }
        started = true
        Task {
            do {
                try await diagnostics.markLaunchStarted()
                let database = try IndexDatabase(url: IndexDatabase.defaultURL())
                self.database = database
                let sources = makeSources()
                let coordinator = IndexCoordinator(database: database, sources: sources)
                self.coordinator = coordinator
                loadPricing()
                await reloadSummaries()
                startWatching(sources.flatMap(\.roots).map(\.url))
                if settings.onboardingComplete {
                    startIndexing()
                }
            } catch {
                startupError = error.localizedDescription
                progress = .init(phase: .failed, error: error.localizedDescription)
            }
        }
    }

    func completeOnboarding(enableLoginItem: Bool) {
        do {
            try settings.setLaunchAtLogin(enableLoginItem)
        } catch {
            startupError = "Could not update the login item: \(error.localizedDescription)"
        }
        settings.onboardingComplete = true
        startIndexing()
    }

    func startIndexing() {
        guard let coordinator, indexTask == nil else { return }
        let scope = settings.indexScope
        let model = self
        indexTask = Task {
            await coordinator.indexAll(scope: scope) { update in
                Task { @MainActor in model.progress = update }
            }
            model.indexTask = nil
            await model.reloadSummaries()
        }
    }

    func rebuildIndex() {
        guard let database else { return }
        indexTask?.cancel()
        indexTask = nil
        Task {
            do {
                try await database.clearIndex()
                hydratedMessages.removeAll()
                messages.removeAll()
                searchResults.removeAll()
                startIndexing()
            } catch {
                startupError = "Rebuild failed: \(error.localizedDescription)"
            }
        }
    }

    func reloadSourcesAndRebuild() {
        watcher?.stop()
        watcher = nil
        guard let database else { return }
        let sources = makeSources()
        coordinator = IndexCoordinator(database: database, sources: sources)
        startWatching(sources.flatMap(\.roots).map(\.url))
        rebuildIndex()
    }

    func search(reset: Bool = true) {
        if reset {
            searchTask?.cancel()
            searchSnippets.removeAll(keepingCapacity: true)
            nextSearchCursor = nil
        } else {
            guard searchTask == nil, nextSearchCursor != nil else { return }
        }
        guard let database, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            nextSearchCursor = nil
            return
        }
        let query = searchQuery
        let filters = searchFilters
        let sort = settings.searchSort
        let cursor = reset ? nil : nextSearchCursor
        let requestID = UUID()
        searchRequestID = requestID
        searchTask = Task { [weak self] in
            let start = ContinuousClock.now
            do {
                let page = try await database.search(query: query, filters: filters, sort: sort, cursor: cursor)
                try Task.checkCancellation()
                guard let self, self.searchRequestID == requestID else { return }
                if reset {
                    self.searchResults = page.results
                } else {
                    self.searchResults.append(contentsOf: page.results)
                }
                self.nextSearchCursor = page.nextCursor
                self.searchTask = nil
                let elapsed = start.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                try? await self.diagnostics.recordSearch(milliseconds: milliseconds)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.searchRequestID == requestID else { return }
                self.searchTask = nil
                self.startupError = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    func hydrateSearchResult(_ result: SearchResult) async {
        guard searchSnippets[result.id] == nil, let coordinator else { return }
        do {
            let hydrated = try await coordinator.hydrate(messageID: result.id)
            try Task.checkCancellation()
            guard searchResults.contains(where: { $0.id == result.id }) else { return }
            let sections = [
                hydrated.sections.prose,
                hydrated.sections.toolInvocation,
                hydrated.sections.toolOutput,
            ].filter { !$0.isEmpty }
            if let snippet = sections.first {
                searchSnippets[result.id] = snippet
            }
        } catch is CancellationError {
            return
        } catch {
            // The zero-I/O prefix remains usable if the source changed before hydration.
        }
    }

    func selectProject(_ projectID: Int64?) {
        selectedProjectID = projectID
        guard let database else { return }
        Task {
            sessions = (try? await database.sessions(projectID: projectID)) ?? []
        }
    }

    func selectSession(_ sessionID: Int64, showWindow: Bool = false) {
        selectedSessionID = sessionID
        settings.lastSessionID = sessionID
        hydratedMessages.removeAll(keepingCapacity: true)
        guard let database else { return }
        Task {
            messages = (try? await database.messages(sessionID: sessionID)) ?? []
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
        Task {
            let start = ContinuousClock.now
            do {
                let hydrated = try await coordinator.hydrate(message)
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
        Task {
            var blocks: [String] = []
            for summary in summaries {
                guard let hydrated = try? await coordinator.hydrate(summary) else { continue }
                var sections = [hydrated.sections.prose, hydrated.sections.toolInvocation, hydrated.sections.toolOutput]
                if expanded.contains(summary.id) { sections.append(hydrated.sections.reasoning) }
                let body = sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
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
        try? await diagnostics.markCleanShutdown()
    }

    private func makeSources() -> [any SessionSource] {
        let defaultClaude = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let custom = settings.additionalClaudeRoots.map { URL(fileURLWithPath: $0) }
        return [ClaudeCodeSource(roots: [defaultClaude] + custom), CodexSource(), GeminiSource()]
    }

    private func startWatching(_ roots: [URL]) {
        let watcher = FSEventsWatcher(roots: roots) { [weak self] paths in
            Task { @MainActor [weak self] in await self?.refresh(paths: paths) }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func refresh(paths: Set<String>) async {
        guard let coordinator else { return }
        await coordinator.refresh(paths: paths, scope: settings.indexScope) { update in
            Task { @MainActor [weak self] in self?.progress = update }
        }
        await reloadSummaries()
        if !searchQuery.isEmpty { search() }
    }

    private func reloadSummaries() async {
        guard let database else { return }
        projects = (try? await database.projects()) ?? []
        recentSessions = (try? await database.sessions(limit: 10)) ?? []
        sessions = (try? await database.sessions(projectID: selectedProjectID)) ?? []
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
