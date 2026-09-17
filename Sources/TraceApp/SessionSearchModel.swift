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
    @Published var datePreset = SearchDatePreset.anyTime
    @Published private(set) var projectFilterCanonicalKey: String?
    @Published private(set) var projectFilterDisplayName: String?
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
    private var lastDatePreset = SearchDatePreset.anyTime
    private var lastSort = SearchSort.recency
    private var activeRequestCriteria: SearchRequestCriteria?
    private var diagnostics: DiagnosticsStore?
    private var loadingAdditionalPage = false
    private var activeTaskIsReset = false
    private var pendingLoadMore = false
    private var injectedDuplicateAdditionalPage = false

    var protectsPagination: Bool { loadingAdditionalPage || hasLoadedAdditionalPages }
    var isWaitingForProjectFilterResolution: Bool {
        projectFilterCanonicalKey != nil && filters.projectID == nil
    }
    var hasActiveFilters: Bool {
        filters != SearchFilters() || datePreset != .anyTime
            || projectFilterCanonicalKey != nil
    }

    private struct SearchRequestCriteria: Sendable {
        let query: String
        let filters: SearchFilters
        let sort: SearchSort
    }

    func markResultsStale() {
        if !query.isEmpty { resultsMayBeStale = true }
    }

    func mutateLiveCriteriaAndLoadMoreForTesting() {
        guard TraceTestHooks.isUITesting,
              let query = TraceTestHooks.environment["TRACE_TEST_PAGINATION_LIVE_QUERY"] else {
            return
        }
        self.query = query
        if let rawSort = TraceTestHooks.environment["TRACE_TEST_PAGINATION_LIVE_SORT"],
           let sort = SearchSort(rawValue: rawSort) {
            self.sort = sort
        }
        search(reset: false)
    }

    func attach(database: IndexDatabase, coordinator: IndexCoordinator, diagnostics: DiagnosticsStore? = nil) {
        self.database = database
        self.coordinator = coordinator
        self.diagnostics = diagnostics
    }

    func selectProject(_ project: ProjectSummary?) {
        filters.projectID = project?.id
        projectFilterCanonicalKey = project?.canonicalKey
        projectFilterDisplayName = project?.displayName
    }

    @discardableResult
    func resolveProjectFilter(in projects: [ProjectSummary], final: Bool) -> Bool {
        guard let projectFilterCanonicalKey else { return false }
        if let project = projects.first(where: { $0.canonicalKey == projectFilterCanonicalKey }) {
            let changed = filters.projectID != project.id
                || projectFilterDisplayName != project.displayName
            filters.projectID = project.id
            projectFilterDisplayName = project.displayName
            return changed
        }
        guard final else { return false }
        filters.projectID = nil
        self.projectFilterCanonicalKey = nil
        projectFilterDisplayName = nil
        return true
    }

    func clearFilters() {
        filters = SearchFilters()
        datePreset = .anyTime
        projectFilterCanonicalKey = nil
        projectFilterDisplayName = nil
    }

    func search(sort: SearchSort? = nil, reset: Bool = true,
                trigger: SearchTrigger = .user) {
        if let sort { self.sort = sort }
        let criteria: SearchRequestCriteria
        if reset {
            let bounds = datePreset.bounds(now: Date())
            var requestFilters = filters
            requestFilters.fromMilliseconds = bounds.from
            requestFilters.toMilliseconds = bounds.to
            if trigger == .automatic { automaticRefreshToken = UUID() }
            resultsMayBeStale = false
            let criteriaChanged = query != lastQuery || filters != lastFilters
                || datePreset != lastDatePreset || self.sort != lastSort
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
            lastDatePreset = datePreset
            lastSort = self.sort
            nextCursor = nil
            loadingAdditionalPage = false
            hasLoadedAdditionalPages = false
            injectedDuplicateAdditionalPage = false
            criteria = .init(query: query, filters: requestFilters, sort: self.sort)
            activeRequestCriteria = criteria
        } else {
            if task != nil {
                if activeTaskIsReset { pendingLoadMore = true }
                return
            }
            guard nextCursor != nil, let activeRequestCriteria else { return }
            criteria = activeRequestCriteria
        }
        performSearch(reset: reset, trigger: trigger, criteria: criteria)
    }

    private func performSearch(
        reset: Bool, trigger: SearchTrigger, criteria: SearchRequestCriteria
    ) {
        guard let database,
              !criteria.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            isSearching = false
            error = nil
            return
        }
        guard !isWaitingForProjectFilterResolution else {
            results = []
            isSearching = false
            error = nil
            return
        }
        let id = UUID()
        requestID = id
        let query = criteria.query
        let filters = criteria.filters
        let sort = criteria.sort
        let initialCursor = reset ? nil : nextCursor
        loadingAdditionalPage = !reset
        activeTaskIsReset = reset
        isSearching = true
        error = nil
        TraceTestHooks.appendLine(trigger == .automatic ? "automatic" : reset ? "reset" : "more",
                                  pathKey: "TRACE_TEST_SEARCH_REQUEST_AUDIT_PATH")
        TraceTestHooks.appendLine(
            "\(reset ? "reset" : "more")|\(query)|\(sort.rawValue)|\(filters.projectID.map(String.init) ?? "all")",
            pathKey: "TRACE_TEST_SEARCH_CRITERIA_AUDIT_PATH"
        )
        task = Task { [weak self] in
            do {
                if reset { try await Task.sleep(for: .milliseconds(100)) }
                if reset, trigger == .automatic {
                    if let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_AUTOMATIC_SEARCH_DELAY_MS",
                        marker: .touch(pathKey: "TRACE_TEST_AUTOMATIC_SEARCH_STARTED_PATH")
                    ) {
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                }
                let started = ContinuousClock.now
                guard let self, self.requestID == id else { return }
                var cursor = initialCursor
                var visitedCursors = Set<SearchCursor>()
                if let cursor { visitedCursors.insert(cursor) }
                var seenResultIDs = reset ? Set<Int64>() : Set(self.results.map(\.id))
                var bufferedTestPage: SearchPage?
                while true {
                    let page: SearchPage
                    if let buffered = bufferedTestPage {
                        page = buffered
                        bufferedTestPage = nil
                    } else {
                        page = try await database.search(
                            query: query, filters: filters, sort: sort, cursor: cursor
                        )
                    }
                    try Task.checkCancellation()
                    guard self.requestID == id else { return }
                    var effectiveResults = page.results
                    var effectiveNextCursor = page.nextCursor
                    var injectedTestPage = false
                    var appendedUniqueResults = true
                    if !reset, TraceTestHooks.isUITesting,
                       TraceTestHooks.environment["TRACE_TEST_DUPLICATE_FIRST_ADDITIONAL_SEARCH_PAGE"] != nil,
                        !self.injectedDuplicateAdditionalPage {
                        self.injectedDuplicateAdditionalPage = true
                        bufferedTestPage = page
                        effectiveResults = Array(self.results.prefix(max(1, page.results.count)))
                        effectiveNextCursor = cursor
                        injectedTestPage = true
                    }
                    let unique = injectedTestPage
                        ? []
                        : page.uniqueResults(excluding: seenResultIDs)
                    seenResultIDs.formUnion(unique.map(\.id))
                    if reset {
                        let previous = Dictionary(
                            self.results.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }
                        )
                        let current = Dictionary(
                            unique.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }
                        )
                        self.results = unique
                        self.snippets = self.snippets.filter { key, _ in
                            guard let old = previous[key], let new = current[key] else { return false }
                            return old.sourcePath == new.sourcePath && old.prefix == new.prefix
                                && old.timestampMilliseconds == new.timestampMilliseconds
                        }
                        if unique.count != effectiveResults.count { self.resultsMayBeStale = true }
                        if trigger == .automatic {
                            self.automaticResultRevision += 1
                            TraceTestHooks.appendLine(
                                "results:\(unique.count)",
                                pathKey: "TRACE_TEST_AUTOMATIC_SEARCH_COMPLETED_PATH"
                            )
                        }
                    } else {
                        self.results += unique
                        appendedUniqueResults = !unique.isEmpty
                        if unique.count != effectiveResults.count { self.resultsMayBeStale = true }
                    }
                    self.nextCursor = effectiveNextCursor
                    if !reset, !injectedTestPage, let next = effectiveNextCursor,
                       !visitedCursors.insert(next).inserted {
                        self.resultsMayBeStale = true
                        self.nextCursor = nil
                        break
                    }
                    if reset || appendedUniqueResults || effectiveNextCursor == nil {
                        break
                    }
                    cursor = effectiveNextCursor
                }
                if !reset { self.hasLoadedAdditionalPages = true }
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
        if projectFilterCanonicalKey != nil { filters.projectID = nil }
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
        activeRequestCriteria = nil
    }

    func hydrate(_ result: SearchResult) async {
        guard snippets[result.id] == nil, let coordinator else { return }
        let setID = resultSetID
        if let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SNIPPET_HYDRATION_DELAY_MS",
                marker: .line("started", pathKey: "TRACE_TEST_SNIPPET_HYDRATION_STARTED_PATH")
        ) {
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
