import Clocks
import Combine
import CustomDump
import Foundation
import TraceCore
import XCTest

@MainActor
final class ClockTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let database: IndexDatabase
        let coordinator: IndexCoordinator
        let settings: AppSettings
        let diagnostics: DiagnosticsStore
    }

    private func fixture(clock: TestClock<Duration>, count: Int = 2) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceClock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TraceClockTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try writeMessages(count: count, to: root.appendingPathComponent("session.jsonl"))
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])], clock: clock)
        await coordinator.indexAll(scope: .proseOnly)
        return Fixture(root: root, database: database, coordinator: coordinator,
                       settings: AppSettings(defaults: defaults),
                       diagnostics: DiagnosticsStore(url: root.appendingPathComponent("diagnostics.json")))
    }

    private func writeMessages(count: Int, to file: URL, project: String = "/tmp/TimingProject") throws {
        var data = Data()
        for i in 1...count {
            let record: [String: Any] = ["type": "user", "uuid": "message-\(i)", "sessionId": "timing",
                "cwd": project, "timestamp": 1_700_000_000_000 + i,
                "message": ["content": "needle \(i == 1 ? "alpha" : "beta") message \(i)"]]
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        try data.write(to: file)
    }

    private func searchModel(_ fixture: Fixture, clock: TestClock<Duration>) -> SessionSearchModel {
        let model = SessionSearchModel(clock: clock)
        model.attach(database: fixture.database, coordinator: fixture.coordinator)
        addTeardownBlock {
            await model.suspendForNavigation()
            try await clock.checkSuspension()
        }
        return model
    }

    private func traceModel(_ fixture: Fixture, clock: TestClock<Duration>) -> TraceModel {
        let model = TraceModel(settings: fixture.settings, clock: clock, diagnostics: fixture.diagnostics)
        model.attach(database: fixture.database, coordinator: fixture.coordinator)
        addTeardownBlock {
            await model.prepareToTerminate()
            try await clock.checkSuspension()
        }
        return model
    }

    /// Clock advancement releases delays; database IO still needs a completion signal.
    private func awaitSearch(_ model: SessionSearchModel) async {
        let finished = expectation(description: "Database search finished")
        let subscription = model.$isSearching.filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(model.error)
    }

    private func progress(_ phase: IndexProgress.Phase = .indexing, pass: UUID,
                          incremental: Bool = false, mutation: Int = 0) -> IndexProgress {
        var update = IndexProgress(phase: phase, completedFiles: mutation, totalFiles: 10)
        update.passID = pass
        update.incremental = incremental
        update.activity = .fileChanges
        update.mutationRevision = mutation
        return update
    }

    func testDebounceFiresAt100Milliseconds() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = searchModel(fixture, clock: clock)
        model.query = "alpha"; model.search()
        await clock.advance(by: .milliseconds(99))
        XCTAssertTrue(model.isSearching)
        XCTAssertTrue(model.results.isEmpty)
        await clock.advance(by: .milliseconds(1))
        await awaitSearch(model)
        expectNoDifference(["needle alpha message 1"], model.results.map(\.prefix))
        try await clock.checkSuspension()
    }

    func testSupersededDebounceAndNavigationCancellation() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = searchModel(fixture, clock: clock)
        model.query = "alpha"; model.search()
        await clock.advance(by: .milliseconds(99))
        model.query = "beta"; model.search()
        await clock.advance(by: .milliseconds(1))
        XCTAssertTrue(model.results.isEmpty, "the superseded query must not publish")
        await clock.advance(by: .milliseconds(99))
        await awaitSearch(model)
        expectNoDifference(["needle beta message 2"], model.results.map(\.prefix))
        model.query = "alpha"; model.search()
        model.suspendForNavigation()
        await clock.advance(by: .seconds(1))
        XCTAssertFalse(model.isSearching)
        XCTAssertTrue(model.results.isEmpty)
        try await clock.checkSuspension()
    }

    private struct ResultValue: Equatable {
        let id: Int64
        let sessionID: Int64
        let timestamp: Int64
        let role: MessageRole
        let prefix: String
        init(_ value: SearchResult) {
            id = value.id; sessionID = value.sessionID; timestamp = value.timestampMilliseconds
            role = value.role; prefix = value.prefix
        }
    }

    func testAdditionalPageDoesNotDebounceOrChangeLoadedRows() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock, count: 205)
        let model = searchModel(fixture, clock: clock)
        model.query = "needle"; model.search()
        await clock.advance(by: .milliseconds(100))
        await awaitSearch(model)
        XCTAssertEqual(model.results.count, 200)
        let first = try await fixture.database.search(query: "needle")
        let second = try await fixture.database.search(query: "needle", cursor: try XCTUnwrap(first.nextCursor))
        model.search(reset: false)
        // No advancement: loading another page must go directly to the database.
        await awaitSearch(model)
        expectNoDifference((first.results + second.results).map(ResultValue.init), model.results.map(ResultValue.init))
        XCTAssertTrue(model.hasLoadedAdditionalPages)
        try await clock.checkSuspension()
    }

    func testIncrementalProgressCoalescesAt300MillisecondsAndTerminalCancelsDelay() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        let pass = UUID()
        await model.receiveProgress(progress(pass: pass, incremental: true, mutation: 1))
        await clock.advance(by: .milliseconds(100))
        await model.receiveProgress(progress(pass: pass, incremental: true, mutation: 2))
        await clock.advance(by: .milliseconds(199))
        XCTAssertEqual(model.progress.phase, .waiting)
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(model.progress.completedFiles, 2)
        await model.receiveProgress(progress(.complete, pass: pass, incremental: true))
        XCTAssertEqual(model.progress.phase, .complete)
        let fastPass = UUID()
        await model.receiveProgress(progress(pass: fastPass, incremental: true))
        await model.receiveProgress(progress(.complete, pass: fastPass, incremental: true))
        await clock.advance(by: .milliseconds(300))
        XCTAssertEqual(model.progress.phase, .complete, "a short pass must not publish delayed busy progress")
        try await clock.checkSuspension()
    }

    func testSummaryRefreshAt250MillisecondsAndTerminalBypass() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        let pass = UUID()
        await model.receiveProgress(progress(pass: pass))
        await clock.advance(by: .milliseconds(249))
        await model.receiveProgress(progress(pass: pass))
        XCTAssertTrue(model.projects.isEmpty)
        await clock.advance(by: .milliseconds(1))
        await model.receiveProgress(progress(pass: pass))
        expectNoDifference(["TimingProject"], model.projects.map(\.displayName))
        try writeMessages(count: 1, to: fixture.root.appendingPathComponent("second.jsonl"), project: "/tmp/SecondProject")
        await fixture.coordinator.indexAll(scope: .proseOnly)
        await model.receiveProgress(progress(pass: pass))
        XCTAssertEqual(model.projects.count, 1)
        await model.receiveProgress(progress(.complete, pass: pass))
        expectNoDifference(Set(["TimingProject", "SecondProject"]), Set(model.projects.map(\.displayName)))
    }

    func testAutomaticRefreshCoalescesAtOneSecondAndTerminalBypassesThrottle() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        model.setMainWindowVisible(true); model.setMainSearchPanelVisible(true)
        model.mainSearch.query = "needle"; model.mainSearch.search()
        await clock.advance(by: .milliseconds(100)); await awaitSearch(model.mainSearch)
        let pass = UUID()
        await model.receiveProgress(progress(pass: pass, incremental: true, mutation: 1))
        let initial = try XCTUnwrap(model.mainSearch.automaticRefreshToken)
        await clock.advance(by: .milliseconds(100)); await awaitSearch(model.mainSearch)
        await model.receiveProgress(progress(pass: pass, incremental: true, mutation: 2))
        await model.receiveProgress(progress(pass: pass, incremental: true, mutation: 3))
        await clock.advance(by: .milliseconds(899))
        XCTAssertEqual(model.mainSearch.automaticRefreshToken, initial)
        await clock.advance(by: .milliseconds(1))
        let refreshed = try XCTUnwrap(model.mainSearch.automaticRefreshToken)
        XCTAssertNotEqual(refreshed, initial)
        await clock.advance(by: .milliseconds(100)); await awaitSearch(model.mainSearch)
        var terminal = progress(.complete, pass: pass, incremental: true, mutation: 4)
        terminal.indexChanged = true
        await model.receiveProgress(terminal)
        XCTAssertNotEqual(model.mainSearch.automaticRefreshToken, refreshed)
        await clock.advance(by: .milliseconds(100)); await awaitSearch(model.mainSearch)
        XCTAssertEqual(model.mainSearch.automaticResultRevision, 3)
        try await clock.checkSuspension()
    }

    func testHidingSearchCancelsPendingAutomaticRefresh() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        model.setMainWindowVisible(true); model.setMainSearchPanelVisible(true)
        model.mainSearch.query = "needle"; model.mainSearch.search()
        await clock.advance(by: .milliseconds(100)); await awaitSearch(model.mainSearch)
        let pass = UUID()
        await model.receiveProgress(progress(pass: pass, mutation: 1))
        await clock.advance(by: .milliseconds(100)); await awaitSearch(model.mainSearch)
        let token = model.mainSearch.automaticRefreshToken
        await model.receiveProgress(progress(pass: pass, mutation: 2))
        model.setMainWindowVisible(false)
        await clock.advance(by: .seconds(1))
        XCTAssertEqual(model.mainSearch.automaticRefreshToken, token)
        try await clock.checkSuspension()
    }

    func testSidebarRevealExpiresAtFiveSecondsAndReplacementAndAcknowledgementCancel() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        let page = try await fixture.database.search(query: "needle")
        let result = try XCTUnwrap(page.results.first)
        model.openSearchResult(result)
        await clock.advance(by: .milliseconds(4_999))
        XCTAssertNotNil(model.sidebarRevealRequest)
        await clock.advance(by: .milliseconds(1))
        XCTAssertNil(model.sidebarRevealRequest)
        model.openSearchResult(result)
        let original = try XCTUnwrap(model.sidebarRevealRequest?.token)
        await clock.advance(by: .milliseconds(2_500))
        model.openSearchResult(result)
        let replacement = try XCTUnwrap(model.sidebarRevealRequest?.token)
        XCTAssertNotEqual(original, replacement)
        await clock.advance(by: .milliseconds(2_500))
        XCTAssertEqual(model.sidebarRevealRequest?.token, replacement)
        model.acknowledgeSidebarProjectReveal(token: original)
        model.acknowledgeSidebarSessionReveal(token: original)
        XCTAssertNotNil(model.sidebarRevealRequest, "old acknowledgements must not clear the replacement")
        model.acknowledgeSidebarProjectReveal(token: replacement)
        model.acknowledgeSidebarSessionReveal(token: replacement)
        XCTAssertNil(model.sidebarRevealRequest)
        try await clock.checkSuspension()
    }

    func testUsageRepairWaitsForOneSecondQuietPeriod() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        var terminal = progress(.complete, pass: UUID())
        terminal.rollupError = "Synthetic rollup failure"
        await model.receiveProgress(terminal)
        await clock.advance(by: .milliseconds(999))
        XCTAssertEqual(model.costsError, "Synthetic rollup failure")
        XCTAssertTrue(model.costsTotalsUpdating)
        let finished = expectation(description: "Usage repair completed")
        let subscription = model.$costsTotalsUpdating.filter { !$0 }.prefix(1).sink { _ in finished.fulfill() }
        await clock.advance(by: .milliseconds(1))
        await fulfillment(of: [finished], timeout: 5)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(model.costsError)
        try await clock.checkSuspension()
    }

    func testShutdownCancelsAllPendingBehaviorDelays() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        model.mainSearch.query = "needle"; model.mainSearch.search()
        await model.receiveProgress(progress(pass: UUID(), incremental: true))
        let page = try await fixture.database.search(query: "needle")
        let result = try XCTUnwrap(page.results.first)
        model.openSearchResult(result)
        await clock.advance()
        await model.prepareToTerminate()
        try await clock.checkSuspension()
        await clock.advance(by: .seconds(10))
        XCTAssertEqual(model.progress.phase, .waiting)
        XCTAssertNil(model.sidebarRevealRequest)
        XCTAssertFalse(model.mainSearch.isSearching)
    }

    func testShutdownCancelsDeferredRepairAndVisibilityDelay() async throws {
        let clock = TestClock()
        let fixture = try await fixture(clock: clock)
        let model = traceModel(fixture, clock: clock)
        model.mainSearch.query = "needle"
        model.setMainWindowVisible(true); model.setMainSearchPanelVisible(true)
        var terminal = progress(.complete, pass: UUID())
        terminal.rollupError = "Synthetic rollup failure"
        await model.receiveProgress(terminal)
        await clock.advance()
        await model.prepareToTerminate()
        try await clock.checkSuspension()
        await clock.advance(by: .seconds(1))
        XCTAssertEqual(model.costsError, "Synthetic rollup failure", "shutdown must not run the deferred repair")
        XCTAssertNil(model.mainSearch.automaticRefreshToken)
    }
}
