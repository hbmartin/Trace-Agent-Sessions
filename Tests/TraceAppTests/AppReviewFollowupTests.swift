import AppKit
import Clocks
import CustomDump
import GRDB
import XCTest
@testable import TraceCore

#if DEBUG
@MainActor
final class AppReviewFollowupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let clock: TestClock<Duration>
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
        let clock = TestClock()
        let source = ClaudeCodeSource(roots: [root])
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [source], clock: clock)
        await coordinator.indexAll(scope: .proseOnly)
        let suite = "TraceAppReview.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = TraceModel(settings: AppSettings(defaults: defaults), clock: clock, diagnosticsURL: root.appendingPathComponent("diagnostics.json"))
        model.attachForTesting(database: database, sources: [source])
        await model.refreshSummariesForTesting()
        addTeardownBlock { @MainActor in
            await model.prepareToTerminate()
            try await clock.checkSuspension()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let project = try XCTUnwrap(model.projects.first { $0.displayName == "NavigationReview" })
        return .init(root: root, clock: clock, model: model, database: database, coordinator: coordinator, project: project)
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

    private func search(_ f: Fixture) async throws {
        f.model.mainSearch.query = "NavigationNeedle"
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == 200 }
    }

    func testSelectionCannotOverwriteRefreshAndBreakAnUnchangedSnapshot() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let selectionGate = ReviewReadGate()
        let selectionTask = Task { await selectionGate.wait() }
        let refreshGate = ReviewReadGate()
        let refreshTask = Task { await refreshGate.wait() }
        defer {
            selectionTask.cancel(); refreshTask.cancel()
            Task { await selectionGate.open(); await refreshGate.open() }
        }
        f.model.selectionTranscriptGateForTesting = selectionTask
        f.model.selectSession(session.id)
        try await wait { f.model.selectionTranscriptWaitingForTesting }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        var data = Data()
        for index in 0..<6 {
            data.append(try line(index, project: index < 2 ? "NavigationReview" : "OtherReview"))
        }
        let rewritten = String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "NavigationNeedle", with: "RewrittenNavigationNeedle with longer locators")
        try Data(rewritten.utf8).write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: session.id)
        XCTAssertNotNil(current.session, "exercise a replacement with a reused session ID")
        await f.model.refreshSummariesForTesting()
        let expectedRows = f.model.messages
        XCTAssertEqual(expectedRows.map(\.locator), current.messages?.map(\.locator))
        f.model.summaryTranscriptGateForTesting = refreshTask
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        await selectionGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        await refreshGate.open()
        await refresh.value
        XCTAssertEqual(f.model.selectedSession?.sourceGeneration, current.session?.sourceGeneration)
        XCTAssertEqual(f.model.messages.map(\.locator), expectedRows.map(\.locator), "unchanged metadata must keep the rows it actually described")
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        XCTAssertTrue(try XCTUnwrap(f.model.hydratedMessages[message.id]).sections.prose.contains("RewrittenNavigationNeedle"))
    }

    func testRowBearingSummaryCannotOverwriteNewerSelectionAfterSourceReplacement() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let selectionGate = ReviewReadGate()
        let selectionTask = Task { await selectionGate.wait() }
        let summaryGate = ReviewReadGate()
        let summaryTask = Task { await summaryGate.wait() }
        defer {
            selectionTask.cancel(); summaryTask.cancel()
            Task { await selectionGate.open(); await summaryGate.open() }
        }
        f.model.selectionTranscriptReadGateForTesting = selectionTask
        f.model.summaryTranscriptGateForTesting = summaryTask
        f.model.selectSession(session.id)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        XCTAssertTrue(f.model.messages.isEmpty)
        let old = try await f.database.transcriptSnapshot(sessionID: session.id,
            knownSession: f.model.selectedSession, knownMessageCount: f.model.messages.count)
        XCTAssertFalse(try XCTUnwrap(old.messages).isEmpty, "the delayed summary must contain old rows")
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { f.model.summaryTranscriptWaitingForTesting }

        let file = f.root.appendingPathComponent("sessions.jsonl")
        let rewritten = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "NavigationNeedle", with: "RewrittenNavigationNeedle with longer locators")
        try Data(rewritten.utf8).write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: session.id)
        let currentSession = try XCTUnwrap(current.session)
        let currentRows = try XCTUnwrap(current.messages)
        XCTAssertNotEqual(currentSession.sourceGeneration, old.session?.sourceGeneration)
        XCTAssertNotEqual(currentRows.map(\.locator), old.messages?.map(\.locator))
        await selectionGate.open()
        try await wait { !f.model.selectionTranscriptReadWaitingForTesting && !f.model.messages.isEmpty }
        XCTAssertEqual(f.model.selectedSession?.sourceGeneration, currentSession.sourceGeneration)
        XCTAssertEqual(f.model.messages.map(\.locator), currentRows.map(\.locator))

        await summaryGate.open()
        await refresh.value
        XCTAssertEqual(f.model.selectedSession?.sourceGeneration, currentSession.sourceGeneration)
        XCTAssertEqual(f.model.messages.map(\.locator), currentRows.map(\.locator),
                       "a stale row-bearing summary must not replace the newer selection")
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        XCTAssertTrue(try XCTUnwrap(f.model.hydratedMessages[message.id]).sections.prose.contains("RewrittenNavigationNeedle"))
    }

    func testSidebarPaginationIsAvailableDuringTheSlowSummaryTail() async throws {
        let f = try await fixture()
        let gate = ReviewReadGate()
        let gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        f.model.summaryTailGateForTesting = gateTask
        let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summaryTailWaitingForTesting }
        XCTAssertFalse(f.model.isLoadingSessions)
        f.model.loadMoreSessions()
        try await wait { f.model.sessions.count == 400 && !f.model.isLoadingSessions }
        await gate.open()
        await refresh.value
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 400)
    }

    func testOutsideSearchSelectionReplacesProtectedResultsWithNewScope() async throws {
        let f = try await fixture()
        try await search(f)
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.hasLoadedAdditionalPages }
        XCTAssertTrue(f.model.mainSearch.results.contains { $0.projectCanonicalKey != f.project.canonicalKey })
        let retainedSet = f.model.mainSearch.resultSetID
        let rows = try await f.database.sessions(projectCanonicalKey: f.project.canonicalKey)
        f.model.openSession(try XCTUnwrap(rows.first))
        try await wait { f.model.selectedSession != nil && !f.model.mainSearch.isSearching }
        XCTAssertEqual(f.model.mainSearch.resultSetID, retainedSet, "hidden navigation must defer the FTS reset")
        f.model.returnFromSession()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == 200 }
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
        try await search(f)
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
        try await search(f)
        let ids = f.model.mainSearch.results.map(\.id)
        let set = f.model.mainSearch.resultSetID
        let gate = ReviewReadGate()
        let gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        f.model.mainSearch.gateAutomaticResultsForTesting(gateTask)
        f.model.mainSearch.search(trigger: .automatic)
        await f.clock.advance(by: .milliseconds(100))
        try await wait { f.model.mainSearch.automaticResultWaitingForTesting }
        f.model.mainSearch.search(trigger: .automatic)
        await f.clock.advance(by: .milliseconds(100))
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
        try await search(f)
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

    func testBackgroundRefreshQueuesLoadMoreAndUsesRefreshedCursor() async throws {
        let f = try await fixture(count: 605)
        let gate = ReviewReadGate()
        let gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(gateTask)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        XCTAssertFalse(f.model.isLoadingSessions, "background reads keep the footer available")
        f.model.loadMoreSessions()
        XCTAssertEqual(f.model.sessions.count, 200)
        await gate.open()
        await refresh.value
        await f.database.gateSessionListReadsForTesting(nil)
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        XCTAssertEqual(f.model.sessions.count, 400)
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 400)
    }

    func testProjectChangeDiscardsFooterActionsQueuedDuringBackgroundRead() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let other = try XCTUnwrap(f.model.projects.first { $0.canonicalKey != f.project.canonicalKey })
        let gate = ReviewReadGate(), gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(gateTask)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        f.model.loadMoreSessions()
        f.model.loadMoreSessions()
        f.model.selectProject(other.id)
        await gate.open(); await refresh.value
        await f.database.gateSessionListReadsForTesting(nil)
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 4 }
        XCTAssertTrue(f.model.sessions.allSatisfy { $0.projectCanonicalKey == other.canonicalKey })
        let reads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(reads, before + 2, "Discarded actions cannot issue another read in the new project")
    }

    func testSuccessfulBackgroundReloadSatisfiesQueuedRetryWithoutAnotherRead() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let page = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000)
        let target = try XCTUnwrap(page.results.last)
        await f.database.failSessionListReadOnceForTesting()
        f.model.openSearchResult(target)
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil && f.model.selectedSession != nil }
        let gate = ReviewReadGate(), gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(gateTask)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        f.model.loadMoreSessions()
        f.model.loadMoreSessions()
        f.model.retrySessionLoad()
        await gate.open(); await refresh.value
        await f.database.gateSessionListReadsForTesting(nil)
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError == nil }
        XCTAssertEqual(f.model.sessions.count, 201, "Retry reload wins over queued pagination")
        XCTAssertTrue(f.model.sessions.contains { $0.id == target.sessionID })
        let reads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(reads, before + 1, "The successful background reload already satisfies Retry")
    }

    func testFailedBackgroundReloadStillRunsQueuedRetry() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let results = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000)
        let target = try XCTUnwrap(results.results.last)
        await f.database.failSessionListReadOnceForTesting()
        f.model.openSearchResult(target)
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(task)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        await f.database.failSessionListReadOnceForTesting()
        f.model.loadMoreSessions()
        f.model.retrySessionLoad()
        f.model.retrySessionLoad()
        await gate.open(); await refresh.value
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError == nil }
        XCTAssertTrue(f.model.sessions.contains { $0.id == target.sessionID })
        XCTAssertEqual(f.model.sessions.count, 201)
        let reads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(reads, before + 2)
    }

    func testQueuedNextPageRetrySurvivesSuccessfulBackgroundReload() async throws {
        let f = try await fixture(count: 605)
        let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
        try await queue.write { try $0.execute(sql: "ALTER TABLE session RENAME TO unavailable_session") }
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        try await queue.write { try $0.execute(sql: "ALTER TABLE unavailable_session RENAME TO session") }
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(task)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        f.model.retrySessionLoad()
        f.model.loadMoreSessions()
        await gate.open(); await refresh.value
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        XCTAssertNil(f.model.sessionListError)
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 400)
        let reads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(reads, before + 1, "One background snapshot; the successful page is verified by its rows")
    }

    func testQueuedLoadMoreWaitsForExplicitReloadAfterBackgroundSnapshot() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let background = ReviewReadGate(), backgroundTask = Task { await background.wait() }
        let explicit = ReviewReadGate(), explicitTask = Task { await explicit.wait() }
        defer {
            backgroundTask.cancel(); explicitTask.cancel()
            Task { await background.open(); await explicit.open() }
        }
        await f.database.gateSidebarSnapshotPublicationForTesting(backgroundTask)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sidebarSnapshotWaitingForTesting }
        f.model.loadMoreSessions()
        f.model.loadMoreSessions()
        await f.database.gateSessionListReadsForTesting(explicitTask)
        f.model.openSession(try XCTUnwrap(f.model.sessions.first))
        try await wait { await f.database.sessionListReadCountForTesting() == before + 2 }
        await background.open(); await refresh.value
        XCTAssertTrue(f.model.isLoadingSessions)
        XCTAssertEqual(f.model.sessions.count, 200)
        await f.database.gateSidebarSnapshotPublicationForTesting(nil)
        await f.database.gateSessionListReadsForTesting(nil)
        await explicit.open()
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 400)
        let reads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(reads, before + 2, "Background and explicit snapshots; repeated paging intent coalesces to one page")
    }

    func testTerminationDiscardsFooterActionsQueuedDuringBackgroundRead() async throws {
        let f = try await fixture(count: 605)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        await f.database.gateSidebarSnapshotPublicationForTesting(task)
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sidebarSnapshotWaitingForTesting }
        f.model.loadMoreSessions()
        f.model.loadMoreSessions()
        await f.model.prepareToTerminate()
        await gate.open(); await refresh.value
        XCTAssertEqual(f.model.sessions.count, 200)
        XCTAssertFalse(f.model.isLoadingSessions)
        let reads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(reads, before + 1)
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
    func testNavigationBeforeFirstDebounceRestartsTheUncommittedSearch() async throws {
        let f = try await fixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        f.model.mainSearch.query = "NavigationNeedle"
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(99))
        XCTAssertTrue(f.model.mainSearch.results.isEmpty)
        f.model.selectSession(try XCTUnwrap(f.model.sessions.first).id)
        try await wait { f.model.selectedSession != nil }
        f.model.returnFromSession()
        XCTAssertTrue(f.model.mainSearch.isSearching)
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == 200 }
    }

    func testSameProjectSidebarNavigationRetainsThreeSearchPages() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f)
        for count in [400, 600] {
            f.model.mainSearch.search(reset: false)
            try await wait { f.model.mainSearch.results.count == count && !f.model.mainSearch.isSearching }
        }
        let ids = f.model.mainSearch.results.map(\.id)
        let set = f.model.mainSearch.resultSetID
        let reads = await f.database.sessionListReadCountForTesting()
        f.model.selectSession(try XCTUnwrap(f.model.sessions.first).id)
        try await wait { f.model.selectedSession != nil }
        f.model.returnFromSession()
        expectNoDifference(ids, f.model.mainSearch.results.map(\.id))
        XCTAssertEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertTrue(f.model.mainSearch.hasLoadedAdditionalPages)
        XCTAssertFalse(f.model.mainSearch.isSearching)
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, reads, "Returning to unchanged protected results needs no sidebar reload")
    }

    func testSinglePageSidebarReturnRefreshesSearchWithoutReloadingSidebar() async throws {
        let f = try await fixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f)
        let set = f.model.mainSearch.resultSetID
        let reads = await f.database.sessionListReadCountForTesting()
        f.model.selectSession(try XCTUnwrap(f.model.sessions.first).id)
        try await wait { !f.model.messages.isEmpty }
        f.model.returnFromSession()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching }
        XCTAssertFalse(f.model.mainSearch.resultsMayBeStale)
        XCTAssertNotEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertFalse(f.model.mainSearch.hasLoadedAdditionalPages)
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, reads)
    }

    private func invalidateCommittedSearch(_ f: Fixture) async throws {
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f)
        f.model.mainSearch.search(reset: false)
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == 400 }
        _ = f.model.mainSearch.resolveProjectFilter(in: [], missingProject: .keepResolving)
        _ = f.model.mainSearch.resolveProjectFilter(in: [f.project], missingProject: .retain)
        XCTAssertFalse(f.model.mainSearch.matchesCurrentCriteria(sort: .recency))
        XCTAssertEqual(f.model.mainSearch.results.count, 400)
    }

    func testManualRefreshAfterInvalidationRotatesIdentityOnlyOnPublication() async throws {
        let f = try await fixture(count: 605)
        try await invalidateCommittedSearch(f)
        let set = f.model.mainSearch.resultSetID
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        let hydrationGate = ReviewReadGate(), hydrationGateTask = Task { await hydrationGate.wait() }
        defer { hydrationGateTask.cancel(); Task { await hydrationGate.open() } }
        f.model.mainSearch.snippetHydrationGateForTesting = hydrationGateTask
        let hydration = Task { await f.model.mainSearch.hydrate(result) }
        try await wait { f.model.mainSearch.snippetHydrationWaitingForTesting }
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.mainSearch.resetResultGateForTesting = task
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { f.model.mainSearch.resetResultWaitingForTesting }
        XCTAssertEqual(f.model.mainSearch.resultSetID, set)
        await gate.open()
        try await wait { !f.model.mainSearch.isSearching }
        XCTAssertNotEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertEqual(f.model.mainSearch.results.count, 200)
        XCTAssertFalse(f.model.mainSearch.resultsMayBeStale)
        XCTAssertFalse(f.model.mainSearch.hasLoadedAdditionalPages)
        await hydrationGate.open(); await hydration.value
        XCTAssertNil(f.model.mainSearch.snippets[result.id], "Old-set hydration cannot publish into the replacement set")
        f.model.mainSearch.snippetHydrationGateForTesting = nil
        await f.model.mainSearch.hydrate(result)
        XCTAssertNotNil(f.model.mainSearch.snippets[result.id])
        f.model.mainSearch.search(reset: false)
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == 400 }
        XCTAssertEqual(Set(f.model.mainSearch.results.map(\.id)).count, 400)
    }

    func testCancelledManualRefreshAfterInvalidationRetainsRowsAndIdentity() async throws {
        let f = try await fixture(count: 605)
        try await invalidateCommittedSearch(f)
        let ids = f.model.mainSearch.results.map(\.id), set = f.model.mainSearch.resultSetID
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.mainSearch.resetResultGateForTesting = task
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { f.model.mainSearch.resetResultWaitingForTesting }
        f.model.mainSearch.suspendForNavigation()
        await gate.open()
        try await wait { !f.model.mainSearch.resetResultWaitingForTesting }
        expectNoDifference(ids, f.model.mainSearch.results.map(\.id))
        XCTAssertEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertTrue(f.model.mainSearch.resultsMayBeStale)
    }

    func testFailedManualRefreshAfterInvalidationRetainsRowsAndIdentity() async throws {
        let f = try await fixture(count: 605)
        try await invalidateCommittedSearch(f)
        let ids = f.model.mainSearch.results.map(\.id), set = f.model.mainSearch.resultSetID
        let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
        try await queue.write { try $0.execute(sql: "DROP TABLE message_fts") }
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.error != nil }
        expectNoDifference(ids, f.model.mainSearch.results.map(\.id))
        XCTAssertEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertTrue(f.model.mainSearch.resultsMayBeStale)
    }

    func testInterruptedManualRefreshRetainsPagesIdentityAnchorAndCursor() async throws {
        let f = try await fixture(count: 605)
        try await search(f)
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.results.count == 400 && !f.model.mainSearch.isSearching }
        let ids = f.model.mainSearch.results.map(\.id), set = f.model.mainSearch.resultSetID
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        let gate = ReviewReadGate(), gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        f.model.mainSearch.resetResultGateForTesting = gateTask
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { f.model.mainSearch.resetResultWaitingForTesting }
        XCTAssertEqual(f.model.mainSearch.resultSetID, set, "pending refresh cannot replace committed identity")
        f.model.openSearchResult(result, fromMainSearch: true,
            anchor: .init(id: result.id, offset: 42, oldOrder: ids))
        try await wait { f.model.selectedSession != nil }
        f.model.returnFromSession()
        expectNoDifference(ids, f.model.mainSearch.results.map(\.id))
        XCTAssertEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.offset, 42)
        XCTAssertTrue(f.model.mainSearch.resultsMayBeStale)
        await gate.open()
        f.model.mainSearch.resetResultGateForTesting = nil
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.results.count == 600 && !f.model.mainSearch.isSearching }
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { f.model.mainSearch.results.count == 200 && !f.model.mainSearch.isSearching }
        XCTAssertNotEqual(f.model.mainSearch.resultSetID, set)
        XCTAssertFalse(f.model.mainSearch.resultsMayBeStale)
    }

    func testTransientProjectDisappearanceDoesNotInvalidateSavedSearch() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f)
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.results.count == 400 && !f.model.mainSearch.isSearching }
        let ids = f.model.mainSearch.results.map(\.id)
        f.model.openSearchResult(try XCTUnwrap(f.model.mainSearch.results.first), fromMainSearch: true)
        try await wait { f.model.selectedSession != nil }
        for terminal in [false, true] {
            let gate = ReviewReadGate(), task = Task { await gate.wait() }
            defer { task.cancel(); Task { await gate.open() } }
            try await f.database.deleteSource(agent: .claudeCode, path: f.root.appendingPathComponent("sessions.jsonl").path)
            let empty = try await f.database.sidebarSnapshot(projectCanonicalKey: f.project.canonicalKey)
            XCTAssertTrue(empty.projects.isEmpty)
            XCTAssertTrue(empty.sessionList.sessions.isEmpty)
            await f.database.gateSidebarSnapshotPublicationForTesting(task)
            let refresh = Task { await f.model.refreshSummariesForTesting(terminal: terminal) }
            try await wait { await f.database.sidebarSnapshotWaitingForTesting }
            await f.coordinator.indexAll(scope: .proseOnly)
            await gate.open(); await refresh.value
            await f.database.gateSidebarSnapshotPublicationForTesting(nil)
            XCTAssertFalse(f.model.mainSearch.isResolvingProjectFilter, "Reconciliation must leave Refresh usable")
            XCTAssertEqual(f.model.mainSearch.projectFilterCanonicalKey, f.project.canonicalKey)
            expectNoDifference(ids, f.model.mainSearch.results.map(\.id))
        }
        await f.model.refreshSummariesForTesting()
        f.model.returnFromSession()
        expectNoDifference(ids, f.model.mainSearch.results.map(\.id))
        f.model.mainSearch.search(reset: false)
        try await wait { f.model.mainSearch.results.count == 600 && !f.model.mainSearch.isSearching }
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { f.model.mainSearch.results.count == 200 && !f.model.mainSearch.isSearching }
    }

    func testSidebarPagingRemainsAvailableDuringTranscriptRead() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        f.model.selectSession(try XCTUnwrap(f.model.sessions.first).id)
        try await wait { f.model.selectedSession != nil }
        let gate = ReviewReadGate(), gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        f.model.summaryTranscriptGateForTesting = gateTask
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        XCTAssertFalse(f.model.isLoadingSessions)
        f.model.loadMoreSessions()
        try await wait { f.model.sessions.count == 400 && !f.model.isLoadingSessions }
        await gate.open(); await refresh.value
        XCTAssertEqual(f.model.sessions.count, 400, "transcript publication cannot overwrite the later page")
    }

    func testRetryEnsuresTheCurrentSelectionAfterSameProjectSelectionChanges() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let page = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000)
        let old = try XCTUnwrap(page.results.last), current = page.results[page.results.count - 2]
        await f.database.failSessionListReadOnceForTesting()
        f.model.openSearchResult(old)
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil && f.model.selectedSession != nil }
        f.model.selectSession(current.sessionID)
        try await wait { f.model.selectedSession?.id == current.sessionID }
        f.model.retrySessionLoad()
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError == nil }
        XCTAssertTrue(f.model.sessions.contains { $0.id == current.sessionID })
        XCTAssertFalse(f.model.sessions.contains { $0.id == old.sessionID })
    }

    func testProjectSwitchCancelsPendingPageAndCannotPublishIt() async throws {
        let f = try await fixture(count: 605)
        let gate = ReviewReadGate(), gateTask = Task { await gate.wait() }
        defer { gateTask.cancel(); Task { await gate.open() } }
        f.model.gateSessionPagesForTesting(gateTask)
        f.model.loadMoreSessions()
        let other = try XCTUnwrap(f.model.projects.first { $0.canonicalKey != f.project.canonicalKey })
        f.model.selectProject(other.id)
        await gate.open()
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 4 }
        XCTAssertTrue(f.model.sessions.allSatisfy { $0.projectCanonicalKey == other.canonicalKey })
    }

    func testAppendingRewrittenRowsReconfiguresOldCellsButPureAppendDoesNot() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let rows = try await f.database.messages(sessionID: session.id)
        let first = try XCTUnwrap(rows.first)
        let renderer = TranscriptRenderer.Coordinator()
        let table = ReloadObservingTable(), scroll = NSScrollView()
        table.addTableColumn(NSTableColumn(identifier: .init("message")))
        scroll.documentView = table
        renderer.attach(table: table, scrollView: scroll)
        defer { renderer.detach() }
        renderer.updateRowsForTesting([first], generation: 1)
        table.reloaded.removeAll()
        let appended = MessageSummary(id: first.id + 1, role: first.role,
            timestampMilliseconds: first.timestampMilliseconds, prefix: first.prefix,
            toolSummary: first.toolSummary, characterCount: first.characterCount, hasError: false,
            sourcePath: first.sourcePath, sourceFormat: first.sourceFormat, locator: first.locator)
        renderer.updateRowsForTesting([first, appended], generation: 1)
        XCTAssertTrue(table.reloaded.isEmpty)
        let more = MessageSummary(id: first.id + 2, role: first.role,
            timestampMilliseconds: first.timestampMilliseconds, prefix: first.prefix,
            toolSummary: first.toolSummary, characterCount: first.characterCount, hasError: false,
            sourcePath: first.sourcePath, sourceFormat: first.sourceFormat, locator: first.locator)
        renderer.updateRowsForTesting([first, appended, more], generation: 2)
        expectNoDifference(IndexSet([0, 1]), table.reloaded)
        table.reloaded.removeAll()
        let relocated = MessageSummary(id: first.id, role: first.role,
            timestampMilliseconds: first.timestampMilliseconds, prefix: first.prefix,
            toolSummary: first.toolSummary, characterCount: first.characterCount, hasError: false,
            sourcePath: first.sourcePath, sourceFormat: first.sourceFormat,
            locator: .byteRange(offset: 999, length: 12))
        let last = MessageSummary(id: first.id + 3, role: first.role,
            timestampMilliseconds: first.timestampMilliseconds, prefix: first.prefix,
            toolSummary: first.toolSummary, characterCount: first.characterCount, hasError: false,
            sourcePath: first.sourcePath, sourceFormat: first.sourceFormat, locator: first.locator)
        renderer.updateRowsForTesting([relocated, appended, more, last], generation: 2)
        expectNoDifference(IndexSet([0]), table.reloaded,
            "Changed hydration identity reconfigures its row even with the same generation")
    }

}

@MainActor
private final class ReloadObservingTable: NSTableView {
    var reloaded = IndexSet()
    override func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        reloaded.formUnion(rows)
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
