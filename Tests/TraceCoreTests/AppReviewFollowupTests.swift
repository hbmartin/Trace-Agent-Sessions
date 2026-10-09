import XCTest
@testable import TraceCore

#if DEBUG
@MainActor
final class AppReviewFollowupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let model: TraceModel
        let database: IndexDatabase
        let coordinator: IndexCoordinator
        let project: ProjectSummary
    }

    private func fixture(count: Int = 430) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceAppReview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sessions.jsonl")
        var data = Data()
        for index in 0..<(count + 4) {
            data.append(try line(index, project: index < count ? "NavigationReview" : "OtherReview"))
        }
        try data.write(to: file)
        let source = ClaudeCodeSource(roots: [root])
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)
        let suite = "TraceAppReview.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = TraceModel(settings: AppSettings(defaults: defaults), diagnosticsURL: root.appendingPathComponent("diagnostics.json"))
        model.attachForTesting(database: database, sources: [source])
        await model.refreshSummariesForTesting()
        addTeardownBlock { @MainActor in
            await model.prepareToTerminate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try XCTUnwrap(model.projects.first { $0.displayName == "NavigationReview" })
        return .init(root: root, model: model, database: database, coordinator: coordinator, project: project)
    }

    private func line(_ index: Int, project: String = "NavigationReview") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "m-\(index)", "sessionId": "s-\(index)",
            "cwd": "/tmp/\(project)", "timestamp": 1_700_000_000_000 + index,
            "message": ["content": "NavigationNeedle \(index)"]]) + Data([10])
    }

    private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for app state", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func search(_ model: TraceModel) async throws {
        model.mainSearch.query = "NavigationNeedle"
        model.searchMain()
        try await wait { !model.mainSearch.isSearching && model.mainSearch.results.count == 200 }
    }

    func testOutsideSearchSelectionReplacesProtectedResultsWithNewScope() async throws {
        let f = try await fixture()
        try await search(f.model)
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.hasLoadedAdditionalPages }
        XCTAssertTrue(f.model.mainSearch.results.contains { $0.projectCanonicalKey != f.project.canonicalKey })
        let rows = try await f.database.sessions(projectCanonicalKey: f.project.canonicalKey)
        f.model.openSession(try XCTUnwrap(rows.first))
        try await wait { f.model.selectedSession != nil && !f.model.mainSearch.isSearching }
        f.model.returnFromSession()
        XCTAssertEqual(f.model.mainSearch.projectFilterCanonicalKey, f.project.canonicalKey)
        XCTAssertFalse(f.model.mainSearch.hasLoadedAdditionalPages)
        XCTAssertEqual(f.model.mainSearch.results.count, 200)
        XCTAssertTrue(f.model.mainSearch.results.allSatisfy { $0.projectCanonicalKey == f.project.canonicalKey })
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.hasLoadedAdditionalPages }
        XCTAssertTrue(f.model.mainSearch.results.allSatisfy { $0.projectCanonicalKey == f.project.canonicalKey })
    }

    func testQueuedRefreshAndSameSessionReselectionRetainReturnContextAndAnchor() async throws {
        let f = try await fixture()
        try await search(f.model)
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        let ids = f.model.mainSearch.results.map(\.id)
        let anchor = SearchResultAnchor(id: result.id, offset: 37, oldOrder: ids)
        f.model.queueMainSearchRefreshForTesting()
        f.model.openSearchResult(result, fromMainSearch: true, anchor: anchor)
        try await wait { f.model.selectedSession != nil }
        let session = try XCTUnwrap(f.model.selectedSession)
        f.model.openSession(session)
        XCTAssertTrue(f.model.hasSearchReturnContext)
        f.model.returnFromSession()
        XCTAssertNil(f.model.mainSearch.projectFilterCanonicalKey)
        XCTAssertNil(f.model.selectedProjectCanonicalKey)
        XCTAssertEqual(f.model.mainSearch.results.map(\.id), ids)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.offset, 37)
        XCTAssertTrue(f.model.mainSearch.resultsMayBeStale)
    }

    func testInterruptedAutomaticRefreshRetainsCommittedCursorThroughRepeatedResets() async throws {
        let f = try await fixture()
        try await search(f.model)
        let ids = f.model.mainSearch.results.map(\.id)
        let set = f.model.mainSearch.resultSetID
        let gate = ReviewReadGate()
        let gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        f.model.mainSearch.gateAutomaticResultsForTesting(gateTask)
        f.model.mainSearch.search(trigger: .automatic)
        try await wait { f.model.mainSearch.automaticResultWaitingForTesting }
        f.model.mainSearch.search(trigger: .automatic)
        try await wait { f.model.mainSearch.automaticResultWaitingForTesting }
        f.model.mainSearch.suspendForNavigation()
        await gate.open()
        XCTAssertFalse(f.model.mainSearch.isSearching)
        XCTAssertTrue(f.model.mainSearch.resultsMayBeStale)
        XCTAssertEqual(f.model.mainSearch.results.map(\.id), ids)
        XCTAssertEqual(f.model.mainSearch.resultSetID, set)
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.results.count == 400 }
        XCTAssertEqual(Set(f.model.mainSearch.results.map(\.id)).count, 400)
        XCTAssertTrue(f.model.mainSearch.hasLoadedAdditionalPages)
    }

    func testTerminalProjectResolutionCompletesWhileReturnContextIsRetained() async throws {
        let f = try await fixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f.model)
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        _ = f.model.mainSearch.resolveProjectFilter(in: [], missingProject: .keepResolving)
        XCTAssertTrue(f.model.mainSearch.isResolvingProjectFilter)
        f.model.openSearchResult(result, fromMainSearch: true)
        try await wait { f.model.selectedSession != nil }
        await f.model.refreshSummariesForTesting()
        XCTAssertFalse(f.model.mainSearch.isResolvingProjectFilter)
        XCTAssertTrue(f.model.hasSearchReturnContext)
        f.model.returnFromSession()
        XCTAssertEqual(f.model.mainSearch.projectFilterCanonicalKey, f.project.canonicalKey)
        XCTAssertTrue(f.model.mainSearch.resultsMayBeStale)
    }

    func testRefreshWaitsForPageThenPublishesAllLoadedRowsIncludingNewSession() async throws {
        let f = try await fixture(count: 605)
        let pageGate = ReviewReadGate()
        let pageTask = Task { await pageGate.wait() }
        defer { pageTask.cancel(); Task { await pageGate.open() } }
        f.model.gateSessionPagesForTesting(pageTask)
        f.model.loadMoreSessions()
        try await wait { f.model.isLoadingSessions }
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: line(10_000)); try handle.close()
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await pageGate.open()
        await refresh.value
        XCTAssertEqual(f.model.sessions.count, 400)
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 400)
        XCTAssertEqual(f.model.totalSessionCount, 610)
        XCTAssertEqual(f.model.sessions.first?.title, "NavigationNeedle 10000")
        XCTAssertFalse(f.model.isLoadingSessions)
    }

    func testRefreshOwnsLoadingStateAndLaterLoadMoreUsesRefreshedCursor() async throws {
        let f = try await fixture(count: 605)
        let gate = ReviewReadGate()
        let gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(gateTask)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        XCTAssertTrue(f.model.isLoadingSessions)
        f.model.loadMoreSessions()
        XCTAssertEqual(f.model.sessions.count, 200)
        await gate.open()
        await refresh.value
        await f.database.gateSessionListReadsForTesting(nil)
        XCTAssertFalse(f.model.isLoadingSessions)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 400)
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 400)
    }

    func testSidebarRetryRepeatsEnsuredReloadInsteadOfLoadingNextPage() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let page = try await f.database.search(query: "NavigationNeedle", filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1_000)
        let target = try XCTUnwrap(page.results.last)
        XCTAssertFalse(f.model.sessions.contains { $0.id == target.sessionID })
        await f.database.failSessionListReadOnceForTesting()
        f.model.openSearchResult(target)
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil && f.model.selectedSession != nil }
        XCTAssertFalse(f.model.sessions.contains { $0.id == target.sessionID })
        f.model.retrySessionLoad()
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError == nil }
        XCTAssertTrue(f.model.sessions.contains { $0.id == target.sessionID })
        XCTAssertEqual(f.model.sessions.count, 201)
        XCTAssertTrue(f.model.hasMoreSessions)
    }
}

private actor ReviewReadGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: { Task { await self.open() } }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
#endif
