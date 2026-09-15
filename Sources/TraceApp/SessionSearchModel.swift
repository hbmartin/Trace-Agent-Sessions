import Combine
import Foundation
import TraceCore

@MainActor
final class SessionSearchModel: ObservableObject {
    @Published var query = ""
    @Published var filters = SearchFilters()
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var snippets: [Int64: String] = [:]
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoadedAdditionalPages = false
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

    var protectsPagination: Bool { loadingAdditionalPage || hasLoadedAdditionalPages }

    func attach(database: IndexDatabase, coordinator: IndexCoordinator, diagnostics: DiagnosticsStore? = nil) {
        self.database = database
        self.coordinator = coordinator
        self.diagnostics = diagnostics
    }

    func search(sort: SearchSort? = nil, reset: Bool = true) {
        if let sort { self.sort = sort }
        if reset {
            task?.cancel()
            task = nil
            requestID = UUID()
            if query != lastQuery || filters != lastFilters || self.sort != lastSort {
                results = []
                snippets.removeAll()
            }
            lastQuery = query
            lastFilters = filters
            lastSort = self.sort
            nextCursor = nil
            loadingAdditionalPage = false
            hasLoadedAdditionalPages = false
        } else if task != nil || nextCursor == nil { return }
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
        isSearching = true
        error = nil
        task = Task { [weak self] in
            do {
                if reset { try await Task.sleep(for: .milliseconds(100)) }
                let started = ContinuousClock.now
                let page = try await database.search(query: query, filters: filters, sort: sort, cursor: cursor)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                if reset { self.results = page.results } else { self.results += page.results }
                if !reset { self.hasLoadedAdditionalPages = true }
                self.nextCursor = page.nextCursor
                self.task = nil
                self.loadingAdditionalPage = false
                self.isSearching = false
                let elapsed = started.duration(to: .now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
                try? await self.diagnostics?.recordSearch(milliseconds: milliseconds)
            } catch is CancellationError {
                guard let self, self.requestID == id else { return }
                self.task = nil
                self.loadingAdditionalPage = false
                self.isSearching = false
            }
            catch {
                guard let self, self.requestID == id else { return }
                self.error = error.localizedDescription
                self.task = nil
                self.loadingAdditionalPage = false
                self.isSearching = false
            }
        }
    }

    func resetForIndexReset() {
        task?.cancel()
        task = nil
        requestID = UUID()
        nextCursor = nil
        results = []
        snippets = [:]
        isSearching = false
        error = nil
        loadingAdditionalPage = false
        hasLoadedAdditionalPages = false
    }

    func hydrate(_ result: SearchResult) async {
        guard snippets[result.id] == nil, let coordinator else { return }
        let id = requestID
        guard let message = try? await coordinator.hydrate(messageID: result.id),
              !Task.isCancelled, id == requestID, results.contains(where: { $0.id == result.id }) else { return }
        snippets[result.id] = [message.sections.prose, message.sections.toolInvocation, message.sections.toolOutput]
            .first { !$0.isEmpty }
    }
}
