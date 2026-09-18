import Combine
import Foundation
import TraceCore

@MainActor
final class SessionSearchModel: ObservableObject {
    enum SearchTrigger {
        case user
        case automatic
    }
    enum ProjectFilterReconciliation {
        case unchanged
        case resolved
        case retained
        case cleared

        var requiresSearchRefresh: Bool {
            switch self {
            case .unchanged: false
            case .resolved, .retained, .cleared: true
            }
        }
    }
    enum MissingProjectPolicy {
        case keepResolving
        case retain
        case clear
    }
    @Published var query = ""
    @Published var filters = SearchFilters()
    @Published var datePreset = SearchDatePreset.anyTime
    @Published private(set) var projectFilterDisplayName: String?
    @Published private(set) var isResolvingProjectFilter = false
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
    private var ignoredAutomaticQueryValueForTesting: String?

    var protectsPagination: Bool { loadingAdditionalPage || hasLoadedAdditionalPages }
    var projectFilterCanonicalKey: String? { filters.projectCanonicalKey }
    var hasActiveFilters: Bool {
        filters != SearchFilters() || datePreset != .anyTime
    }

    private struct SearchRequestCriteria: Sendable {
        let query: String
        let filters: SearchFilters
        let sort: SearchSort
    }

    func markResultsStale() {
        if !query.isEmpty, !resultsMayBeStale { resultsMayBeStale = true }
    }

    func mutateLiveCriteriaAndLoadMoreForTesting() {
        guard TraceTestHooks.isUITesting,
              let query = TraceTestHooks.environment["TRACE_TEST_PAGINATION_LIVE_QUERY"],
              task == nil, nextCursor != nil, activeRequestCriteria != nil else {
            return
        }
        ignoredAutomaticQueryValueForTesting = query
        self.query = query
        if let rawSort = TraceTestHooks.environment["TRACE_TEST_PAGINATION_LIVE_SORT"],
           let sort = SearchSort(rawValue: rawSort) {
            self.sort = sort
        }
        if let rawAgent = TraceTestHooks.environment["TRACE_TEST_PAGINATION_LIVE_AGENT"],
           let agent = AgentKind(rawValue: rawAgent) {
            filters.agents = [agent]
        }
        search(reset: false)
    }

    func shouldSearchAfterQueryChange(to query: String) -> Bool {
        !TraceTestHooks.isUITesting || ignoredAutomaticQueryValueForTesting != query
    }

    func attach(database: IndexDatabase, coordinator: IndexCoordinator, diagnostics: DiagnosticsStore? = nil) {
        self.database = database
        self.coordinator = coordinator
        self.diagnostics = diagnostics
    }

    func selectProject(_ project: ProjectSummary?) {
        setProjectFilter(
            canonicalKey: project?.canonicalKey,
            displayName: project?.displayName
        )
    }

    func setProjectFilter(canonicalKey: String?, displayName: String?) {
        if filters.projectCanonicalKey != canonicalKey {
            filters.projectCanonicalKey = canonicalKey
        }
        if projectFilterDisplayName != displayName {
            projectFilterDisplayName = displayName
        }
        if isResolvingProjectFilter { isResolvingProjectFilter = false }
    }

    func resolveProjectFilter(
        in projects: [ProjectSummary], missingProject policy: MissingProjectPolicy
    ) -> ProjectFilterReconciliation {
        guard let projectFilterCanonicalKey else {
            if isResolvingProjectFilter { isResolvingProjectFilter = false }
            return .unchanged
        }
        if let project = projects.first(where: { $0.canonicalKey == projectFilterCanonicalKey }) {
            let wasResolving = isResolvingProjectFilter
            if projectFilterDisplayName != project.displayName {
                projectFilterDisplayName = project.displayName
            }
            if isResolvingProjectFilter { isResolvingProjectFilter = false }
            return wasResolving ? .resolved : .unchanged
        }
        switch policy {
        case .keepResolving:
            if !isResolvingProjectFilter {
                isResolvingProjectFilter = true
                invalidateActiveRequest(markStale: true)
            }
            return .unchanged
        case .retain:
            let wasResolving = isResolvingProjectFilter
            if isResolvingProjectFilter { isResolvingProjectFilter = false }
            if wasResolving { invalidateActiveRequest(markStale: true) }
            return wasResolving ? .retained : .unchanged
        case .clear:
            filters.projectCanonicalKey = nil
            if projectFilterDisplayName != nil { projectFilterDisplayName = nil }
            if isResolvingProjectFilter { isResolvingProjectFilter = false }
            invalidateActiveRequest(markStale: true)
            return .cleared
        }
    }

    func clearFilters() {
        filters = SearchFilters()
        datePreset = .anyTime
        projectFilterDisplayName = nil
        isResolvingProjectFilter = false
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
        guard !isResolvingProjectFilter else {
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
            searchCriteriaAuditLine(
                reset: reset, query: query, filters: filters, sort: sort,
                cursor: initialCursor
            ),
            pathKey: "TRACE_TEST_SEARCH_CRITERIA_AUDIT_PATH"
        )
        task = Task { [weak self] in
            defer { if !reset { self?.ignoredAutomaticQueryValueForTesting = nil } }
            do {
                if reset { try await Task.sleep(for: .milliseconds(100)) }
                if reset, trigger == .automatic {
                    if let delay = TraceTestHooks.delayMilliseconds(
                        for: "TRACE_TEST_AUTOMATIC_SEARCH_DELAY_MS",
                        cappedAt: 5_000,
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
                if !reset {
                    self.hasLoadedAdditionalPages = true
                    TraceTestHooks.touch(pathKey: "TRACE_TEST_PAGINATION_COMPLETED_PATH")
                }
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

    private func searchCriteriaAuditLine(
        reset: Bool, query: String, filters: SearchFilters, sort: SearchSort,
        cursor: SearchCursor?
    ) -> String {
        let agents = filters.agents.isEmpty
            ? "all"
            : filters.agents.map(\.rawValue).sorted().joined(separator: ",")
        return "\(reset ? "reset" : "more")|\(query)|\(sort.rawValue)|"
            + "\(filters.projectCanonicalKey ?? "all")|agents:\(agents)|"
            + "cursor:\(cursor == nil ? "none" : "present")"
    }

    func resetForIndexReset(awaitsProjectResolution: Bool = false) {
        task?.cancel()
        task = nil
        requestID = UUID()
        resultSetID = UUID()
        isResolvingProjectFilter = awaitsProjectResolution
            && filters.projectCanonicalKey != nil
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

    private func invalidateActiveRequest(markStale: Bool) {
        task?.cancel()
        task = nil
        requestID = UUID()
        nextCursor = nil
        activeRequestCriteria = nil
        loadingAdditionalPage = false
        activeTaskIsReset = false
        pendingLoadMore = false
        hasLoadedAdditionalPages = false
        isSearching = false
        if markStale { markResultsStale() }
    }

    func hydrate(_ result: SearchResult) async {
        guard snippets[result.id] == nil, let coordinator else { return }
        let setID = resultSetID
        if let delay = TraceTestHooks.delayMilliseconds(
            for: "TRACE_TEST_SNIPPET_HYDRATION_DELAY_MS",
            cappedAt: 5_000,
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
