import Combine
import Foundation
import TraceCore

@MainActor
final class SessionSearchModel: ObservableObject {
    enum SearchTrigger {
        case user
        case automatic
    }
    @Published var query = ""
    @Published var filters = SearchFilters()
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var snippets: [Int64: String] = [:]
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoadedAdditionalPages = false
    @Published private(set) var resultsMayBeStale = false
    @Published private(set) var resultSetID = UUID()
    @Published private(set) var automaticRefreshToken: UUID?
    @Published private(set) var automaticResultRevision = 0
    private var database: IndexDatabase?
    private var coordinator: IndexCoordinator?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var nextCursor: SearchCursor?
    private var sort = SearchSort.recency
    private var lastQuery = ""
    private var lastFilters = SearchFilters()
    private var lastSort = SearchSort.recency
    private var diagnostics: DiagnosticsStore?
    private var loadingAdditionalPage = false
    private var activeTaskIsReset = false
    private var pendingLoadMore = false

    var protectsPagination: Bool { loadingAdditionalPage || hasLoadedAdditionalPages }

    func markResultsStale() {
        if !query.isEmpty { resultsMayBeStale = true }
    }

    func attach(database: IndexDatabase, coordinator: IndexCoordinator, diagnostics: DiagnosticsStore? = nil) {
        self.database = database
        self.coordinator = coordinator
        self.diagnostics = diagnostics
    }

    func search(sort: SearchSort? = nil, reset: Bool = true,
                trigger: SearchTrigger = .user) {
        if let sort { self.sort = sort }
        if reset {
            if trigger == .automatic { automaticRefreshToken = UUID() }
            resultsMayBeStale = false
            let criteriaChanged = query != lastQuery || filters != lastFilters || self.sort != lastSort
            if trigger == .user || criteriaChanged { resultSetID = UUID() }
            if trigger == .user || criteriaChanged { pendingLoadMore = false }
            task?.cancel()
            task = nil
            activeTaskIsReset = false
            requestID = UUID()
            if criteriaChanged {
                results = []
                snippets.removeAll()
            }
            lastQuery = query
            lastFilters = filters
            lastSort = self.sort
            nextCursor = nil
            loadingAdditionalPage = false
            hasLoadedAdditionalPages = false
        } else {
            if task != nil {
                if activeTaskIsReset { pendingLoadMore = true }
                return
            }
            guard nextCursor != nil else { return }
        }
        guard let database, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            error = nil
            return
        }
        let id = UUID()
        requestID = id
        let query = query
        let filters = filters
        let sort = self.sort
        let cursor = reset ? nil : nextCursor
        loadingAdditionalPage = !reset
        activeTaskIsReset = reset
        isSearching = true
        error = nil
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let path = ProcessInfo.processInfo.environment["TRACE_TEST_SEARCH_REQUEST_AUDIT_PATH"] {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("\(trigger == .automatic ? "automatic" : reset ? "reset" : "more")\n".utf8))
                try? handle.close()
            }
        }
        task = Task { [weak self] in
            do {
                if reset { try await Task.sleep(for: .milliseconds(100)) }
                if reset, trigger == .automatic,
                   ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                   let delay = ProcessInfo.processInfo.environment["TRACE_TEST_AUTOMATIC_SEARCH_DELAY_MS"].flatMap(Int.init),
                   delay > 0 {
                    if let path = ProcessInfo.processInfo.environment["TRACE_TEST_AUTOMATIC_SEARCH_STARTED_PATH"] {
                        try? Data().write(to: URL(fileURLWithPath: path))
                    }
                    try await Task.sleep(for: .milliseconds(delay))
                }
                let started = ContinuousClock.now
                let page = try await database.search(query: query, filters: filters, sort: sort, cursor: cursor)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                if reset {
                    let previous = Dictionary(uniqueKeysWithValues: self.results.map { ($0.id, $0) })
                    let current = Dictionary(uniqueKeysWithValues: page.results.map { ($0.id, $0) })
                    self.results = page.results
                    self.snippets = self.snippets.filter { key, _ in
                        guard let old = previous[key], let new = current[key] else { return false }
                        return old.sourcePath == new.sourcePath && old.prefix == new.prefix
                            && old.timestampMilliseconds == new.timestampMilliseconds
                    }
                    if trigger == .automatic { self.automaticResultRevision += 1 }
                } else { self.results += page.results }
                if !reset { self.hasLoadedAdditionalPages = true }
                self.nextCursor = page.nextCursor
                self.task = nil
                self.loadingAdditionalPage = false
                self.activeTaskIsReset = false
                self.isSearching = false
                if reset, self.pendingLoadMore {
                    self.pendingLoadMore = false
                    if self.nextCursor != nil { self.search(reset: false) }
                }
                let elapsed = started.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                try? await self.diagnostics?.recordSearch(milliseconds: milliseconds)
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }
                self.task = nil
                self.loadingAdditionalPage = false
                self.activeTaskIsReset = false
                self.isSearching = false
                self.pendingLoadMore = false
            }
            catch {
                guard let self, self.requestID == id else { return }
                self.error = error.localizedDescription
                self.task = nil
                self.loadingAdditionalPage = false
                self.activeTaskIsReset = false
                self.isSearching = false
                self.pendingLoadMore = false
            }
        }
    }

    func resetForIndexReset() {
        task?.cancel()
        task = nil
        requestID = UUID()
        resultSetID = UUID()
        nextCursor = nil
        results = []
        snippets = [:]
        isSearching = false
        error = nil
        loadingAdditionalPage = false
        activeTaskIsReset = false
        pendingLoadMore = false
        hasLoadedAdditionalPages = false
        resultsMayBeStale = false
        automaticRefreshToken = nil
    }

    func hydrate(_ result: SearchResult) async {
        guard snippets[result.id] == nil, let coordinator else { return }
        let setID = resultSetID
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let delay = ProcessInfo.processInfo.environment["TRACE_TEST_SNIPPET_HYDRATION_DELAY_MS"].flatMap(Int.init),
           delay > 0 {
            if let path = ProcessInfo.processInfo.environment["TRACE_TEST_SNIPPET_HYDRATION_STARTED_PATH"] {
                try? Data().write(to: URL(fileURLWithPath: path))
            }
            do { try await Task.sleep(for: .milliseconds(delay)) }
            catch { return }
        }
        guard let message = try? await coordinator.hydrate(messageID: result.id),
              !Task.isCancelled, setID == resultSetID,
              results.contains(where: {
                  $0.id == result.id && $0.sourcePath == result.sourcePath
                      && $0.prefix == result.prefix && $0.timestampMilliseconds == result.timestampMilliseconds
              }) else { return }
        snippets[result.id] = [message.sections.prose, message.sections.toolInvocation, message.sections.toolOutput]
            .first { !$0.isEmpty }
    }
}
