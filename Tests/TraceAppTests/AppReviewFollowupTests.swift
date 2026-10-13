import AppKit
import Clocks
import Combine
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
        await model.attachForTesting(database: database, sources: [source])
        model.sourceReloadSourcesForTesting = [source]
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

    private func search(_ f: Fixture, expectedCount: Int = 200) async throws {
        f.model.mainSearch.query = "NavigationNeedle"
        f.model.searchMain()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == expectedCount }
    }

    private func uninstalledModel(clock: TestClock<Duration>, diagnosticsURL: URL,
                                  savedSessionID: Int64? = nil,
                                  startupActivityObserver: @escaping (IndexActivity) -> Void = { _ in }) throws -> TraceModel {
        let suite = "TraceAppReview.Uninstalled.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.lastSessionID = savedSessionID
        let model = TraceModel(settings: settings, clock: clock,
                               startupActivityObserver: startupActivityObserver, diagnosticsURL: diagnosticsURL)
        addTeardownBlock { @MainActor in
            await model.prepareToTerminate()
            defaults.removePersistentDomain(forName: suite)
        }
        return model
    }

    func testRecoveryBudgetCoalescesFailuresAndManualRetryPreservesRows() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let rows = f.model.messages
        await f.database.failTranscriptReadsForTesting(count: 5)
        await f.model.refreshSummariesForTesting()
        await f.model.refreshSummariesForTesting()
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        await f.clock.advance(by: .milliseconds(249))
        let early = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(early, before)
        for (index, delay) in [Duration.milliseconds(1), .seconds(1), .seconds(4)].enumerated() {
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        }
        try await wait { f.model.transcriptLoadError != nil && !f.model.transcriptRecoveryPendingForTesting }
        await f.clock.advance(by: .seconds(60))
        let exhausted = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(exhausted, before + 3, "exhaustion must stop automatic reads")
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting()
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting, "fresh failures do not reset an exhausted episode")
        f.model.retrySelectedTranscript()
        XCTAssertNil(f.model.transcriptLoadError)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertNil(f.model.transcriptLoadError)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
    }

    func testRecoveryCancelsAfterSelectionClearReplacementAndTermination() async throws {
        for change in 0..<4 {
            let f = try await fixture(count: 2)
            let session = try XCTUnwrap(f.model.sessions.first)
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            await f.database.failTranscriptReadOnceForTesting()
            await f.model.refreshSummariesForTesting()
            try await wait { f.model.transcriptRecoveryPendingForTesting }
            let gate = ReviewReadGate(), task = Task { await gate.wait() }
            defer { task.cancel(); Task { await gate.open() } }
            f.model.transcriptRecoveryPublicationGateForTesting = task
            await f.clock.advance(by: .milliseconds(250))
            try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
            switch change {
            case 0:
                let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
                f.model.selectSession(other.id)
                try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
            case 1: f.model.clearSession()
            case 2:
                let replacement = try await fixture(count: 3)
                await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            default: await f.model.prepareToTerminate()
            }
            let selected = f.model.selectedSessionID, rows = f.model.messages, revision = f.model.transcriptMessageRevision
            await gate.open()
            try await wait { !f.model.transcriptRecoveryPublicationWaitingForTesting }
            await f.clock.advance(by: .seconds(10))
            XCTAssertEqual(f.model.selectedSessionID, selected)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            XCTAssertEqual(f.model.transcriptMessageRevision, revision)
            XCTAssertNil(f.model.transcriptLoadError)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        }
    }

    func testRecoverySelectionFailureLoadsWithoutAnotherSummary() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        await f.database.failTranscriptReadOnceForTesting()
        f.model.selectSession(session.id)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        XCTAssertTrue(f.model.messages.isEmpty)
        await f.clock.advance(by: .milliseconds(250))
        try await wait { !f.model.messages.isEmpty }
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertNil(f.model.transcriptLoadError)
    }

    func testRecoveredSelectionCompletesNavigationOnceAcrossAllPublishers() async throws {
        for publisher in 0..<3 {
            let f = try await fixture(count: 2)
            let session = try XCTUnwrap(f.model.sessions.first)
            let rows = try await f.database.messages(sessionID: session.id)
            let messageID = try XCTUnwrap(rows.first?.id)
            let initialReadCount = await f.database.transcriptReadCountForTesting()
            let events = ReviewSelectionEvents()
            let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { events.windows += 1 }
            }
            let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
            defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
            await f.database.failTranscriptReadsForTesting(count: publisher == 1 ? 4 : 1)
            f.model.selectSession(session.id, showWindow: true, messageID: messageID)
            try await wait { f.model.transcriptRecoveryPendingForTesting }
            XCTAssertEqual(events.windows, 0)
            XCTAssertEqual(events.scrolls, 0)
            if publisher == 1 {
                await f.clock.advance(by: .milliseconds(250))
                try await wait { await f.database.transcriptReadCountForTesting() >= initialReadCount + 2 }
                await f.clock.advance(by: .seconds(1))
                try await wait { await f.database.transcriptReadCountForTesting() >= initialReadCount + 3 }
                await f.clock.advance(by: .seconds(4))
                try await wait { f.model.transcriptLoadError != nil }
                XCTAssertEqual(events.windows, 1, "exhausted recovery must expose the Retry button")
                XCTAssertEqual(events.scrolls, 0)
                f.model.retrySelectedTranscript()
                await f.clock.advance()
            } else if publisher == 2 {
                await f.model.refreshSummariesForTesting()
            } else {
                await f.clock.advance(by: .milliseconds(250))
            }
            try await wait { !f.model.messages.isEmpty && events.windows == 1 }
            try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
            XCTAssertEqual(events.scrolls, 1)
            XCTAssertEqual(f.model.requestedMessageID, messageID)
            await f.model.refreshSummariesForTesting()
            await f.model.refreshSummariesForTesting()
            await f.clock.advance(by: .seconds(10))
            XCTAssertEqual(events.windows, 1)
            XCTAssertEqual(events.scrolls, 1)
            let diagnostics = await f.model.diagnostics.value()
            XCTAssertEqual(diagnostics.days.reduce(0) { $0 + $1.openCount }, 1)
        }
    }

    func testSupersededFailedSelectionDoesNotReplayWindowOrScrollIntent() async throws {
        let f = try await fixture(count: 2)
        let first = try XCTUnwrap(f.model.sessions.first), second = f.model.sessions[1]
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        await f.database.failTranscriptReadOnceForTesting()
        f.model.selectSession(first.id, showWindow: true, messageID: 123)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        f.model.selectSession(second.id)
        try await wait { f.model.selectedSession?.id == second.id && !f.model.messages.isEmpty }
        await f.clock.advance(by: .seconds(10))
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
        XCTAssertEqual(events.windows, 0)
        XCTAssertEqual(events.scrolls, 1)
        XCTAssertNil(f.model.requestedMessageID)
    }

    func testRepeatedSelectionDuringRecoveryCoalescesWindowIntent() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        await f.database.failTranscriptReadOnceForTesting()
        f.model.selectSession(session.id)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        f.model.selectSession(session.id, showWindow: true)
        f.model.selectSession(session.id, showWindow: true)
        XCTAssertEqual(events.windows, 0)
        await f.clock.advance(by: .milliseconds(250))
        try await wait { !f.model.messages.isEmpty && events.windows == 1 }
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
        XCTAssertEqual(events.scrolls, 1)
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 1)
    }

    func testReselectingExhaustedSelectionShowsWindowWithoutCompletingOpen() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        await f.database.failTranscriptReadsForTesting(count: 4)
        f.model.selectSession(session.id)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1), .seconds(4)].enumerated() {
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
        }
        try await wait { f.model.transcriptLoadError != nil }
        XCTAssertEqual(events.windows, 0)
        f.model.selectSession(session.id, showWindow: true)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 0)
        let failedDiagnostics = await f.model.diagnostics.value()
        XCTAssertEqual(failedDiagnostics.days.reduce(0) { $0 + $1.openCount }, 0)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { !f.model.messages.isEmpty }
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 1)
    }

    func testDeletedLauncherSelectionShowsWindowAndClearsSelection() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        f.model.selectionTranscriptReadGateForTesting = task
        f.model.openSession(session)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await gate.open()
        try await wait { events.windows == 1 }
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertNil(f.model.settings.lastSessionID)
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertEqual(events.scrolls, 0)
        await f.model.refreshSummariesForTesting()
        let diagnostics = await f.model.diagnostics.value()
        XCTAssertEqual(diagnostics.days.reduce(0) { $0 + $1.openCount }, 0)
        XCTAssertEqual(events.windows, 1)
    }

    func testRecoveryNewerMissingSelectionAlreadyPublishedNeedsNoConfirmation() async throws {
        let pending = try await preparePendingMissingSummary()
        let f = pending.fixture
        await pending.readGate.open()
        try await wait { f.model.selectionTranscriptWaitingForTesting }
        await pending.publicationGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        XCTAssertNil(f.model.selectedSession)
        XCTAssertEqual(f.model.selectedSessionID, pending.session.id)
        let before = await f.database.transcriptReadCountForTesting()
        let revision = f.model.transcriptMessageRevision
        await pending.summaryGate.open()
        try await wait { pending.finished() }
        assertMissingSummaryCleared(pending, revision: revision)
        let after = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, before)
    }

    func testRecoveryAcceptedMovedSelectionCancelsRevealBeforeStaleTerminalSummary() async throws {
        let f = try await fixture(count: 2)
        let staleSession = try XCTUnwrap(f.model.sessions.first)
        let readGate = ReviewReadGate(), readTask = Task { await readGate.wait() }
        let summaryGate = ReviewReadGate(), summaryTask = Task { await summaryGate.wait() }
        defer { readTask.cancel(); summaryTask.cancel(); Task { await readGate.open(); await summaryGate.open() } }
        f.model.selectionTranscriptReadGateForTesting = readTask
        f.model.openSession(staleSession)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        XCTAssertEqual(f.model.sidebarRevealRequest?.projectCanonicalKey, staleSession.projectCanonicalKey)
        f.model.summaryTranscriptGateForTesting = summaryTask
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        addTeardownBlock { await readGate.open(); await summaryGate.open(); await refresh.value }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        var moved = Data()
        for index in 0..<6 { moved.append(try line(index, project: "MovedReview")) }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        try moved.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await readGate.open()
        try await wait { f.model.selectedSession?.projectCanonicalKey != staleSession.projectCanonicalKey && !f.model.messages.isEmpty }
        XCTAssertNil(f.model.sidebarRevealRequest, "accepted selection must invalidate the old project reveal immediately")
        await summaryGate.open()
        await refresh.value
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertEqual(f.model.selectedSessionID, staleSession.id)
        XCTAssertEqual(f.model.selectedProjectCanonicalKey, f.model.selectedSession?.projectCanonicalKey)
    }

    func testRecoveryActiveSchedulerReplacementFencesProgressAndLatestAttachmentWins() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3), latest = try await fixture(count: 4)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        let first = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.schedulerForTesting == nil }
        let second = Task { await f.model.attach(database: latest.database, coordinator: latest.coordinator) }
        try await wait { f.model.pendingDatabaseForTesting === latest.database }
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        XCTAssertNotNil(f.model.coordinatorForTesting)
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        let firstCommitted = await first.value, secondCommitted = await second.value
        XCTAssertFalse(firstCommitted)
        XCTAssertTrue(secondCommitted)
        XCTAssertTrue(f.model.coordinatorForTesting === latest.coordinator)
        XCTAssertEqual(f.model.progress.phase, .waiting)
        XCTAssertNil(f.model.statistics)
        await previous.waitUntilIdle()
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(f.model.sessions.count, 8)
    }

    func testRecoverySchedulerReplacementCannotCheckpointReplacementDatabase() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerCompletionGateForTesting = task
        await previous.request(watermarks: ["retired": 42])
        try await wait { f.model.schedulerCompletionWaitingForTesting }
        let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.schedulerForTesting == nil }
        f.model.schedulerCompletionGateForTesting = nil
        await gate.open()
        let committed = await attachment.value
        XCTAssertTrue(committed)
        let oldCheckpoint = try await f.database.eventCheckpoint(volumeID: "retired")
        let replacementCheckpoint = try await replacement.database.eventCheckpoint(volumeID: "retired")
        XCTAssertNil(oldCheckpoint)
        XCTAssertNil(replacementCheckpoint)
        let current = try XCTUnwrap(f.model.schedulerForTesting)
        await current.request(watermarks: ["fresh": 99])
        await current.waitUntilIdle()
        let fresh = try await replacement.database.eventCheckpoint(volumeID: "fresh")
        XCTAssertEqual(fresh, 99)
    }

    func testRecoveryReplacementDiscardsPendingSourceReconfiguration() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.sourceChangeAttachmentGateForTesting = task
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        await gate.open()
        try await wait { !f.model.sourceChangeAttachmentWaitingForTesting }
        XCTAssertTrue(f.model.coordinatorForTesting === replacement.coordinator)
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(f.model.sessions.count, 7)
    }

    func testRecoveryTerminationWaitsForRetirementAndRejectsPendingAttachment() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.schedulerForTesting == nil }
        let termination = Task { await f.model.prepareToTerminate() }
        try await wait { f.model.isTerminatingForTesting }
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        let committed = await attachment.value
        await termination.value
        XCTAssertFalse(committed)
        XCTAssertNil(f.model.schedulerForTesting)
        let afterTermination = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertFalse(afterTermination)
        await previous.waitUntilIdle()
    }

    func testRecoveryIdenticalAttachmentAndRebuildRetainScheduler() async throws {
        let f = try await fixture(count: 2)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let committed = await f.model.attach(database: f.database, coordinator: coordinator)
        XCTAssertTrue(committed)
        XCTAssertTrue(f.model.schedulerForTesting === previous)
        f.model.settings.onboardingComplete = true
        f.model.rebuildIndex()
        await previous.waitUntilIdle()
        try await wait { f.model.progress.phase == .complete }
        XCTAssertTrue(f.model.schedulerForTesting === previous)
        try await wait { f.model.statistics?.sessionCount == 6 }
        XCTAssertEqual(f.model.statistics?.sessionCount, 6)
    }

    func testOverlappingReloadsDuringRetirementInstallNewestRootsAndRetainWorkflow() async throws {
        let f = try await fixture(count: 2), newest = try await fixture(count: 3)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        var loaded = IndexProgress(phase: .indexing)
        loaded.unresolvedFailedFiles = 2
        loaded.unresolvedDiscoveryFailures = 3
        await f.model.receiveProgress(loaded)
        f.model.reloadSourcesAndRebuild()
        XCTAssertNil(f.model.schedulerForTesting)
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [newest.root])]
        f.model.reloadSourcesAndRebuild()
        f.model.reloadSourcesAndRebuild()
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        XCTAssertNotNil(f.model.coordinatorForTesting)
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertEqual(f.model.progress.unresolvedFailedFiles, 2)
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        try await wait { f.model.schedulerForTesting != nil && f.model.pendingDatabaseForTesting == nil }
        XCTAssertFalse(f.model.indexingPassActiveForTesting, "onboarding defers the replacement pass")
        XCTAssertEqual(f.model.progress.phase, .waiting)
        XCTAssertEqual(f.model.progress.unresolvedDiscoveryFailures, 3)
        let current = try XCTUnwrap(f.model.schedulerForTesting)
        await current.request(reconcile: true)
        await current.waitUntilIdle()
        let sessions = try await f.database.sessions(limit: 100)
        XCTAssertEqual(sessions.count, 7)
        XCTAssertTrue(sessions.allSatisfy { $0.sourcePath.hasPrefix(newest.root.path) })
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
    }

    func testReloadDuringPendingDatabaseReplacementUsesPendingTarget() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3), newest = try await fixture(count: 4)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.pendingDatabaseForTesting === replacement.database }
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [newest.root])]
        f.model.reloadSourcesAndRebuild()
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        let supersededCommitted = await attachment.value
        XCTAssertFalse(supersededCommitted)
        try await wait { f.model.schedulerForTesting != nil && f.model.pendingDatabaseForTesting == nil }
        XCTAssertTrue(f.model.databaseForTesting === replacement.database)
        let current = try XCTUnwrap(f.model.schedulerForTesting)
        await current.request(reconcile: true)
        await current.waitUntilIdle()
        let sessions = try await replacement.database.sessions(limit: 100)
        XCTAssertEqual(sessions.count, 8)
        XCTAssertTrue(sessions.allSatisfy { $0.sourcePath.hasPrefix(newest.root.path) })
        let installedSessions = try await f.database.sessions(limit: 100)
        XCTAssertEqual(installedSessions.count, 6)
    }

    func testReloadRetainsReplacementAndCountsUntilWatchingPassStarts() async throws {
        let f = try await fixture(count: 2)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let retirementGate = ReviewReadGate(), retirementTask = Task { await retirementGate.wait() }
        let replacementGate = ReviewReadGate(), replacementTask = Task { await replacementGate.wait() }
        defer {
            retirementTask.cancel(); replacementTask.cancel()
            Task { await retirementGate.open(); await replacementGate.open() }
        }
        f.model.schedulerProgressGateForTesting = retirementTask
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        var loaded = IndexProgress(phase: .indexing)
        loaded.unresolvedFailedFiles = 2
        loaded.unresolvedDiscoveryFailures = 3
        await f.model.receiveProgress(loaded)
        f.model.settings.onboardingComplete = true
        f.model.reloadSourcesAndRebuild()
        f.model.schedulerProgressGateForTesting = replacementTask
        await retirementGate.open()
        try await wait { f.model.schedulerForTesting != nil && f.model.schedulerProgressWaitingForTesting }
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertEqual(f.model.progress.phase, .indexing)
        XCTAssertEqual(f.model.progress.unresolvedFailedFiles, 2)
        XCTAssertEqual(f.model.progress.unresolvedDiscoveryFailures, 3)
        f.model.schedulerProgressGateForTesting = nil
        await replacementGate.open()
        try await wait { f.model.progress.phase == .complete }
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
    }

    func testCancelledAttachmentRetainsInstalledReadersAndAllowsAnotherAttachment() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let installed = try XCTUnwrap(f.model.coordinatorForTesting)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.pendingDatabaseForTesting === replacement.database }
        attachment.cancel()
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        let committed = await attachment.value
        XCTAssertFalse(committed)
        XCTAssertNil(f.model.pendingDatabaseForTesting)
        XCTAssertEqual(f.model.progress.phase, .cancelled)
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        XCTAssertTrue(f.model.coordinatorForTesting === installed)
        let retried = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertTrue(retried)
        XCTAssertTrue(f.model.databaseForTesting === replacement.database)
    }

    func testReplacementFailureCountReadFailureAbortsCommit() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let installed = try XCTUnwrap(f.model.coordinatorForTesting)
        let queue = try DatabaseQueue(path: replacement.root.appendingPathComponent("index.sqlite").path)
        try await queue.write { db in try db.execute(sql: "DROP TABLE source_scan_error") }
        let committed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertFalse(committed)
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        XCTAssertTrue(f.model.coordinatorForTesting === installed)
        XCTAssertEqual(f.model.progress.phase, .failed)
        XCTAssertNotNil(f.model.startupError)
        XCTAssertNil(f.model.pendingDatabaseForTesting)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
        try await search(f, expectedCount: 6)
    }

    func testInstalledSearchHydrationAndCopyRemainUsableUntilReplacementCommit() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let session = try XCTUnwrap(f.model.sessions.first { $0.projectID == f.project.id })
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let message = try XCTUnwrap(f.model.messages.first)
        let installedCoordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.pendingDatabaseForTesting === replacement.database }
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        XCTAssertTrue(f.model.coordinatorForTesting === installedCoordinator)
        f.model.globalSearch.query = "NavigationNeedle"
        f.model.search()
        try await search(f, expectedCount: 2)
        try await wait { !f.model.globalSearch.isSearching && f.model.globalSearch.results.count == 6 }
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        var copied: String?
        f.model.transcriptCopyForTesting = { copied = $0 }
        f.model.copyTranscript()
        try await wait { copied != nil }
        XCTAssertTrue(copied?.contains("NavigationNeedle") == true)
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        let committed = await attachment.value
        XCTAssertTrue(committed)
        XCTAssertTrue(f.model.databaseForTesting === replacement.database)
        XCTAssertTrue(f.model.coordinatorForTesting === replacement.coordinator)
        await f.model.refreshSummariesForTesting()
        f.model.search()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.globalSearch.isSearching && f.model.globalSearch.results.count == 7 }
    }

    private func seedSourceFailures(_ f: Fixture, discoveryFailures: Int) throws {
        let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "UPDATE source_file SET last_error='persisted failure'")
            for index in 0..<discoveryFailures {
                try db.execute(sql: """
                    INSERT INTO source_scan_error(root_id, relative_scope, error, updated_at_ms)
                    SELECT id, ?, 'persisted discovery failure', 1 FROM source_root
                    """, arguments: ["failed-\(index)"])
            }
        }
    }

    func testAttachmentsPreserveLoadedCountsAndReplacementUsesItsOwnCounts() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        try seedSourceFailures(f, discoveryFailures: 2)
        try seedSourceFailures(replacement, discoveryFailures: 3)
        let model = TraceModel(settings: f.model.settings, clock: f.clock,
                               diagnosticsURL: f.root.appendingPathComponent("initial-diagnostics.json"))
        addTeardownBlock { @MainActor in await model.prepareToTerminate() }
        await model.attach(database: f.database, coordinator: f.coordinator)
        XCTAssertEqual(model.progress.unresolvedFailedFiles, 1)
        XCTAssertEqual(model.progress.unresolvedDiscoveryFailures, 2)
        var loaded = IndexProgress(phase: .waiting)
        loaded.unresolvedFailedFiles = 4
        loaded.unresolvedDiscoveryFailures = 5
        await model.receiveProgress(loaded)
        let coordinator = IndexCoordinator(database: f.database, sources: [ClaudeCodeSource(roots: [f.root])], clock: f.clock)
        await model.attach(database: f.database, coordinator: coordinator)
        XCTAssertEqual(model.progress.unresolvedFailedFiles, 4)
        XCTAssertEqual(model.progress.unresolvedDiscoveryFailures, 5)
        XCTAssertFalse(model.indexingPassActiveForTesting)
        await model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertEqual(model.progress.unresolvedFailedFiles, 1)
        XCTAssertEqual(model.progress.unresolvedDiscoveryFailures, 3)
    }

    func testFailedReloadKeepsReadableAttachmentAndCanRetryWithoutScheduler() async throws {
        let f = try await fixture(count: 2)
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.progress.phase == .failed }
        XCTAssertNotNil(f.model.startupError)
        XCTAssertNil(f.model.schedulerForTesting)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
        XCTAssertTrue(f.model.databaseForTesting === f.database)
        XCTAssertTrue(f.model.coordinatorForTesting === coordinator)
        try await search(f, expectedCount: 6)
        f.model.failSourceConfigurationForTesting = false
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.schedulerForTesting != nil }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.request(reconcile: true)
        await scheduler.waitUntilIdle()
        XCTAssertEqual(f.model.progress.phase, .complete)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
    }

    func testRebuildRequestedDuringRetirementReindexesWithLatestScope() async throws {
        let f = try await fixture(count: 2)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let tool = try JSONSerialization.data(withJSONObject: ["type": "assistant", "uuid": "tool-scope",
            "sessionId": "s-0", "cwd": "/tmp/NavigationReview", "timestamp": 1_700_000_010_000,
            "message": ["content": [["type": "tool_use", "id": "scope-tool", "name": "Bash", "input": ["command": "QueuedScopeNeedle"]]]]]) + Data([10])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: tool); try handle.close()
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let before = try await f.database.search(query: "QueuedScopeNeedle", filters: .init(), sort: .relevance)
        XCTAssertTrue(before.results.isEmpty)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await previous.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        f.model.reloadSourcesAndRebuild()
        f.model.settings.onboardingComplete = true
        f.model.settings.indexScope = .everything
        f.model.rebuildIndex()
        f.model.rebuildIndex()
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        try await wait { f.model.progress.phase == .complete && f.model.schedulerForTesting != nil }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let after = try await f.database.search(query: "QueuedScopeNeedle", filters: .init(), sort: .relevance)
        XCTAssertEqual(after.results.count, 1)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
        XCTAssertFalse(f.model.pendingRebuildForTesting)
    }

    func testStartupDoesNotResubmitRebuildWaitingForFirstProgress() async throws {
        let f = try await fixture(count: 2)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.settings.onboardingComplete = true
        f.model.schedulerProgressGateForTesting = task
        f.model.selectionTranscriptReadGateForTesting = task
        f.model.rebuildIndex()
        try await wait { f.model.schedulerProgressWaitingForTesting }
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        // A second reset would erase this navigation while the rebuild is held.
        f.model.selectSession(-123)
        f.model.startIndexing(sources: [ClaudeCodeSource(roots: [f.root])])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.model.selectedSessionID, -123)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        await scheduler.waitUntilIdle()
        XCTAssertFalse(f.model.pendingRebuildForTesting)
    }

    func testFailedReloadDiscardsQueuedRebuildAndManualRebuildRetries() async throws {
        let f = try await fixture(count: 2)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        await scheduler.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        f.model.rebuildIndex()
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        try await wait { f.model.progress.phase == .failed }
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
        // An unrelated installation must not resurrect the abandoned request.
        await f.model.attach(database: f.database, coordinator: f.coordinator)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.progress.phase == .failed }
        f.model.failSourceConfigurationForTesting = false
        f.model.rebuildIndex()
        try await wait { f.model.schedulerForTesting != nil && f.model.progress.phase == .complete }
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        XCTAssertNil(f.model.startupError)
    }

    func testInitialAndReplacementAttachmentsPreserveUnrelatedAlerts() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        let source = ClaudeCodeSource(roots: [f.root])
        for error in ["Could not load pending index recovery", "Could not copy message",
                      "Could not update the login item", "Could not load source failures"] {
            let model = try uninstalledModel(clock: f.clock,
                diagnosticsURL: f.root.appendingPathComponent("alert-\(UUID()).json"))
            model.startupError = error
            await model.attach(database: f.database,
                               coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
            XCTAssertEqual(model.startupError, error, "initial attachment must preserve the alert")
            await model.attach(database: f.database,
                               coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
            XCTAssertEqual(model.startupError, error, "replacement must preserve the alert")
            await model.prepareToTerminate()
        }
    }

    func testSuccessfulReloadClearsOnlyItsOwnedAlert() async throws {
        for assignment in 0..<4 {
            let f = try await fixture(count: 2)
            f.model.settings.onboardingComplete = true
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.sourceReloadRecovery.error != nil }
            let error = try XCTUnwrap(f.model.startupError)
            let expected: String?
            switch assignment {
            case 0: expected = nil
            case 1:
                f.model.startupError = nil
                expected = nil
            case 2:
                f.model.startupError = "Unrelated copy failure"
                expected = "Unrelated copy failure"
            default:
                // Identical text from another action must still relinquish ownership.
                f.model.startupError = error
                expected = error
            }
            f.model.failSourceConfigurationForTesting = false
            f.model.retrySourceConfiguration()
            try await wait { f.model.progress.phase == .complete }
            XCTAssertEqual(f.model.startupError, expected)
            XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
            await f.model.prepareToTerminate()
        }
    }

    func testSupersededReloadCannotClearANewerAlert() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.sourceChangeAttachmentGateForTesting = task
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { !f.model.sourceReloadRecovery.isRetrying }
        f.model.startupError = "A newer unrelated failure"
        await gate.open()
        try await wait { !f.model.sourceChangeAttachmentWaitingForTesting }
        XCTAssertEqual(f.model.startupError, "A newer unrelated failure")
        XCTAssertNotNil(f.model.sourceReloadRecovery.error)
        XCTAssertNil(f.model.schedulerForTesting)
    }

    func testRebuildBeforeInitialAttachmentPreservesRestorationAndUsesLatestScope() async throws {
        let f = try await fixture(count: 2)
        let saved = try XCTUnwrap(f.model.sessions.first)
        await f.model.prepareToTerminate()
        let model = try uninstalledModel(clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("startup-rebuild.json"), savedSessionID: saved.id)
        model.settings.onboardingComplete = true
        model.settings.indexScope = .everything
        model.rebuildIndex()
        model.rebuildIndex()
        XCTAssertFalse(model.pendingRebuildForTesting)
        XCTAssertEqual(model.settings.lastSessionID, saved.id)
        XCTAssertFalse(model.indexingPassActiveForTesting)
        let tool = try JSONSerialization.data(withJSONObject: ["type": "assistant", "uuid": "startup-tool",
            "sessionId": "s-0", "cwd": "/tmp/NavigationReview", "timestamp": 1_700_000_100_000,
            "message": ["content": [["type": "tool_use", "id": "startup-tool", "name": "Bash",
                                     "input": ["command": "StartupScopeNeedle"]]]]]) + Data([10])
        let file = f.root.appendingPathComponent("sessions.jsonl")
        var data = try Data(contentsOf: file)
        data.append(tool)
        try data.write(to: file)
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attach(database: f.database,
                           coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
        await model.refreshSummariesForTesting(lightweight: false)
        try await wait { model.selectedSessionID == saved.id && !model.messages.isEmpty }
        // Real startup can spend long enough opening the index for its first
        // discovering publication to refresh summaries during the scope reset.
        await f.clock.advance(by: .milliseconds(300))
        model.startIndexing(sources: [source])
        try await wait { model.progress.phase == .complete }
        let indexed = try await f.database.search(query: "StartupScopeNeedle", filters: .init(), sort: .relevance)
        XCTAssertEqual(indexed.results.count, 1)
        XCTAssertEqual(model.settings.lastSessionID, saved.id)
        XCTAssertEqual(model.selectedSessionID, saved.id)
        XCTAssertEqual(model.rebuildSubmissionCountForTesting, 0)
    }

    func testSourceReloadRetrySurvivesAlertDismissalAndCoalescesUntilProgress() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let error = try XCTUnwrap(f.model.sourceReloadRecovery.error)
        f.model.startupError = nil
        XCTAssertEqual(f.model.sourceReloadRecovery, .failed(error))
        f.model.globalSearch.query = "NavigationNeedle"
        f.model.search()
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.globalSearch.isSearching && f.model.globalSearch.results.count == 6 }

        let attachmentGate = ReviewReadGate(), attachmentTask = Task { await attachmentGate.wait() }
        let progressGate = ReviewReadGate(), progressTask = Task { await progressGate.wait() }
        defer {
            attachmentTask.cancel(); progressTask.cancel()
            Task { await attachmentGate.open(); await progressGate.open() }
        }
        f.model.sourceChangeAttachmentGateForTesting = attachmentTask
        f.model.schedulerProgressGateForTesting = progressTask
        f.model.failSourceConfigurationForTesting = false
        var retries = 0
        let subscription = f.model.$sourceReloadRecovery.dropFirst().sink { state in
            if state.isRetrying { retries += 1 }
        }
        defer { subscription.cancel() }
        f.model.retrySourceConfiguration()
        f.model.retrySourceConfiguration()
        XCTAssertEqual(f.model.sourceReloadRecovery, .retrying(error))
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        f.model.retrySourceConfiguration()
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        await attachmentGate.open()
        try await wait { f.model.schedulerProgressWaitingForTesting }
        XCTAssertNotNil(f.model.schedulerForTesting)
        XCTAssertEqual(f.model.sourceReloadRecovery, .retrying(error), "installation alone does not finish recovery")
        f.model.schedulerProgressGateForTesting = nil
        await progressGate.open()
        try await wait { f.model.progress.phase == .complete }
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
    }

    func testSourceReloadRetryFailureRemainsRetryableAndOnboardingDefersSuccess() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let error = try XCTUnwrap(f.model.sourceReloadRecovery.error)
        f.model.retrySourceConfiguration()
        XCTAssertTrue(f.model.sourceReloadRecovery.isRetrying)
        try await wait { f.model.sourceReloadRecovery == .failed(error) }
        XCTAssertNil(f.model.schedulerForTesting)
        f.model.settings.onboardingComplete = false
        f.model.retrySourceConfiguration()
        XCTAssertEqual(f.model.sourceReloadRecovery, .failed(error), "retry requires completed onboarding")
        var progress = IndexProgress(phase: .failed)
        progress.unresolvedFailedFiles = 2
        progress.unresolvedDiscoveryFailures = 3
        await f.model.receiveProgress(progress)
        f.model.failSourceConfigurationForTesting = false
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.schedulerForTesting != nil && f.model.progress.phase == .waiting }
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        XCTAssertEqual(f.model.progress.unresolvedFailedFiles, 2)
        XCTAssertEqual(f.model.progress.unresolvedDiscoveryFailures, 3)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
    }

    func testSourceReloadRecoverySupersessionAndTerminationRejectStaleUpdates() async throws {
        for terminates in [false, true] {
            let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
            f.model.settings.onboardingComplete = true
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.sourceReloadRecovery.error != nil }
            let gate = ReviewReadGate(), task = Task { await gate.wait() }
            defer { task.cancel(); Task { await gate.open() } }
            f.model.sourceChangeAttachmentGateForTesting = task
            f.model.failSourceConfigurationForTesting = false
            f.model.retrySourceConfiguration()
            try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
            if terminates { await f.model.prepareToTerminate() }
            else { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
            XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
            await gate.open()
            try await wait { !f.model.sourceChangeAttachmentWaitingForTesting }
            XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
            if terminates {
                f.model.retrySourceConfiguration()
                XCTAssertNil(f.model.pendingDatabaseForTesting)
            } else {
                XCTAssertTrue(f.model.databaseForTesting === replacement.database)
            }
        }
    }

    func testCancelledRetryAttachmentRestoresFailureAndRejectsRetiredProgress() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let error = try XCTUnwrap(f.model.sourceReloadRecovery.error)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = task
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.schedulerProgressWaitingForTesting }
        XCTAssertEqual(f.model.sourceReloadRecovery, .retrying(error))
        let attachment = Task { await f.model.attach(database: f.database, coordinator: f.coordinator) }
        try await wait { f.model.pendingDatabaseForTesting != nil }
        attachment.cancel()
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        let committed = await attachment.value
        XCTAssertFalse(committed)
        XCTAssertEqual(f.model.sourceReloadRecovery, .failed(error))
        XCTAssertNil(f.model.schedulerForTesting)
    }

    func testOrdinaryIndexFailureDoesNotOfferSourceConfigurationRetry() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let scheduler = f.model.schedulerForTesting
        var failed = IndexProgress(phase: .failed)
        failed.error = "Index pass failed"
        await f.model.receiveProgress(failed)
        f.model.retrySourceConfiguration()
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        XCTAssertTrue(f.model.schedulerForTesting === scheduler)
        XCTAssertNil(f.model.pendingDatabaseForTesting)
    }

    func testBackgroundAbsenceDuringPassPreservesTranscriptUntilTerminalDeletion() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let messages = f.model.messages
        var pass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(pass)
        _ = try await f.database.synchronizeConfiguredRoots([])
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertEqual(f.model.messages.map(\.id), messages.map(\.id))
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertNil(f.model.settings.lastSessionID)
        XCTAssertTrue(f.model.messages.isEmpty)
    }

    func testTransientExplicitSelectionCompletesOnceAcrossAllPublishers() async throws {
        for publisher in 0..<4 {
            let f = try await fixture(count: 2)
            let session = try XCTUnwrap(f.model.sessions.first)
            let events = ReviewSelectionEvents()
            let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { events.windows += 1 }
            }
            let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
            defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
            await f.model.receiveProgress(.init(phase: .indexing))
            _ = try await f.database.synchronizeConfiguredRoots([])
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            if publisher == 1 { f.model.selectionTranscriptGateForTesting = held }
            if publisher >= 2 { await f.database.failTranscriptReadsForTesting(count: publisher == 3 ? 4 : 1) }
            f.model.selectSession(session.id, showWindow: true)
            if publisher == 1 {
                try await wait { f.model.selectionTranscriptWaitingForTesting }
                await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            } else if publisher >= 2 {
                try await wait { f.model.transcriptRecoveryPendingForTesting }
                await f.clock.advance(by: .milliseconds(250))
                if publisher == 3 {
                    let reads = await f.database.transcriptReadCountForTesting()
                    await f.clock.advance(by: .seconds(1))
                    try await wait { await f.database.transcriptReadCountForTesting() > reads }
                    await f.clock.advance(by: .seconds(4))
                    try await wait { !f.model.transcriptRecoveryPendingForTesting }
                    f.model.retrySelectedTranscript()
                    await f.clock.advance()
                }
            }
            try await wait { f.model.transcriptIsTemporarilyUnavailable }
            XCTAssertEqual(f.model.selectedSessionID, session.id)
            XCTAssertEqual(f.model.settings.lastSessionID, session.id)
            XCTAssertEqual(events.windows, 1, "missing data must expose the main window promptly")
            XCTAssertEqual(events.scrolls, 0)
            let before = await f.model.diagnostics.value()
            XCTAssertEqual(before.days.reduce(0) { $0 + $1.openCount }, 0)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
            XCTAssertTrue(try XCTUnwrap(f.model.transcriptLoadError).contains("temporarily unavailable"))
            await f.coordinator.indexAll(scope: .proseOnly)
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
            XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
            XCTAssertFalse(f.model.messages.isEmpty)
            XCTAssertEqual(events.scrolls, 1)
            await gate.open()
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            XCTAssertEqual(events.windows, 1)
            XCTAssertEqual(events.scrolls, 1)
        }
    }

    func testTransientSummaryPreservesCacheAndFencesOlderRecovery() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        let rows = f.model.messages, project = f.model.selectedProjectID
        await f.model.receiveProgress(.init(phase: .indexing))
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryPublicationGateForTesting = held
        _ = try await f.database.synchronizeConfiguredRoots([])
        await f.clock.advance(by: .milliseconds(250))
        try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertEqual(f.model.messages.map(\.id), rows.map(\.id))
        XCTAssertNotNil(f.model.hydratedMessages[message.id])
        XCTAssertEqual(f.model.selectedProjectID, project)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        f.model.transcriptRecoveryPublicationGateForTesting = nil
        f.model.retrySelectedTranscript()
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable, "manual Retry preserves absence feedback")
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
        await f.coordinator.indexAll(scope: .proseOnly)
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        await gate.open()
        try await wait { !f.model.transcriptRecoveryPublicationWaitingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertNil(f.model.transcriptLoadError)
        XCTAssertEqual(f.model.messages.map(\.id), rows.map(\.id))
    }

    func testTransientAbsenceClearsAtTerminalPassAndSelectionBoundaries() async throws {
        for boundary in 0..<7 {
            let f = try await fixture(count: 2)
            let session = try XCTUnwrap(f.model.sessions.first)
            let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            _ = try await f.database.synchronizeConfiguredRoots([])
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
            switch boundary {
            case 0, 1, 2:
                pass.phase = [.complete, .failed, .cancelled][boundary]
                await f.model.receiveProgress(pass)
                XCTAssertNil(f.model.selectedSessionID)
                XCTAssertNil(f.model.settings.lastSessionID)
            case 3: f.model.clearSession()
            case 4:
                await f.coordinator.indexAll(scope: .proseOnly)
                f.model.selectSession(other.id)
                try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
            case 5:
                let replacement = try await fixture(count: 3)
                await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            default: await f.model.prepareToTerminate()
            }
            XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
            XCTAssertNil(f.model.transcriptLoadError)
        }
    }

    private func exhaustReadRecovery(_ f: Fixture) async throws {
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1), .seconds(4)].enumerated() {
            XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable, "feedback remains until the budget finishes")
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
        }
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
    }

    func testTerminalReadRecoveryRetiresTemporaryFeedbackAfterBudget() async throws {
        for phase in [IndexProgress.Phase.complete, .failed, .cancelled] {
            let f = try await fixture(count: 2)
            let session = try XCTUnwrap(f.model.sessions.first)
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            let message = try XCTUnwrap(f.model.messages.first)
            f.model.hydrate(message)
            try await wait { f.model.hydratedMessages[message.id] != nil }
            let rows = f.model.messages, project = f.model.selectedProjectID
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            _ = try await f.database.synchronizeConfiguredRoots([])
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            await f.database.failTranscriptReadsForTesting(count: 4)
            pass.phase = phase
            await f.model.receiveProgress(pass)
            XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
            try await exhaustReadRecovery(f)
            XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
            XCTAssertTrue(try XCTUnwrap(f.model.transcriptLoadError).contains("Synthetic transcript read failure"))
            XCTAssertFalse(try XCTUnwrap(f.model.transcriptLoadError).contains("wait for indexing"))
            XCTAssertEqual(f.model.selectedSessionID, session.id)
            XCTAssertEqual(f.model.settings.lastSessionID, session.id)
            XCTAssertEqual(f.model.messages.map(\.id), rows.map(\.id))
            XCTAssertNotNil(f.model.hydratedMessages[message.id])
            XCTAssertEqual(f.model.selectedProjectID, project)
            let exhausted = await f.database.transcriptReadCountForTesting()
            await f.clock.advance(by: .seconds(60))
            let after = await f.database.transcriptReadCountForTesting()
            XCTAssertEqual(after, exhausted, "exhaustion adds no automatic reads")
            await f.coordinator.indexAll(scope: .proseOnly)
            f.model.retrySelectedTranscript()
            await f.clock.advance()
            try await wait { !f.model.transcriptRecoveryPendingForTesting }
            XCTAssertNil(f.model.transcriptLoadError)
            XCTAssertEqual(f.model.selectedSessionID, session.id)
        }
    }

    func testPendingTransientSelectionCompletesOnceAfterTerminalRecoveryFailure() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        var pass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(pass)
        _ = try await f.database.synchronizeConfiguredRoots([])
        f.model.selectSession(session.id, showWindow: true)
        try await wait { f.model.transcriptIsTemporarilyUnavailable }
        XCTAssertEqual(events.windows, 1)
        await f.database.failTranscriptReadsForTesting(count: 4)
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        try await exhaustReadRecovery(f)
        XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertEqual(events.scrolls, 0)
        let before = await f.model.diagnostics.value()
        XCTAssertEqual(before.days.reduce(0) { $0 + $1.openCount }, 0)
        await f.coordinator.indexAll(scope: .proseOnly)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
        XCTAssertNil(f.model.transcriptLoadError)
        XCTAssertFalse(f.model.messages.isEmpty)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 1)
        await f.model.refreshSummariesForTesting()
        await f.clock.advance(by: .seconds(60))
        let after = await f.model.diagnostics.value()
        XCTAssertEqual(after.days.reduce(0) { $0 + $1.openCount }, 1)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 1)
    }

    func testAlreadyExhaustedRecoveryRetiresAbsenceOnTerminalReadFailure() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        var pass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(pass)
        _ = try await f.database.synchronizeConfiguredRoots([])
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        await f.database.failTranscriptReadsForTesting(count: 4)
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await exhaustReadRecovery(f)
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable, "an active pass retains temporary feedback")
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptLoadError).contains("Synthetic transcript read failure"))
        let before = await f.database.transcriptReadCountForTesting()
        await f.database.failTranscriptReadOnceForTesting()
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptLoadError).contains("Synthetic transcript read failure"))
        await f.clock.advance(by: .seconds(60))
        let after = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, before + 1, "terminal feedback does not renew the exhausted budget")
    }

    func testNewerPassKeepsAbsenceWhenOlderRecoveryExhausts() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        var oldPass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(oldPass)
        _ = try await f.database.synchronizeConfiguredRoots([])
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        await f.database.failTranscriptReadsForTesting(count: 4)
        oldPass.phase = .complete
        await f.model.receiveProgress(oldPass)
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1)].enumerated() {
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
        }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryPublicationGateForTesting = held
        await f.clock.advance(by: .seconds(4))
        try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
        var successor = IndexProgress(phase: .indexing)
        successor.incremental = true // Start a pass without requesting another summary.
        await f.model.receiveProgress(successor)
        await gate.open()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptLoadError).contains("Synthetic transcript read failure"))
        await f.database.failTranscriptReadOnceForTesting()
        successor.phase = .complete
        await f.model.receiveProgress(successor)
        XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        XCTAssertNotNil(f.model.transcriptLoadError)
    }

    func testObsoleteTerminalReadFailureCannotPublishFeedback() async throws {
        for boundary in 0..<4 {
            let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
            let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            _ = try await f.database.synchronizeConfiguredRoots([])
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summaryTranscriptFailureGateForTesting = held
            await f.database.failTranscriptReadOnceForTesting()
            pass.phase = .complete
            let terminal = Task { await f.model.receiveProgress(pass) }
            try await wait { f.model.summaryTranscriptFailureWaitingForTesting }
            switch boundary {
            case 0:
                await f.coordinator.indexAll(scope: .proseOnly)
                await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            case 1:
                await f.coordinator.indexAll(scope: .proseOnly)
                f.model.selectSession(other.id)
                try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
            case 2:
                let replacement = try await fixture(count: 3)
                await replacement.model.prepareToTerminate()
                await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            default: await f.model.prepareToTerminate()
            }
            await gate.open()
            await terminal.value
            XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
            XCTAssertNil(f.model.transcriptLoadError)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        }
    }

    func testObsoleteRecoveryExhaustionCannotPublishFeedback() async throws {
        for boundary in 0..<4 {
            let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
            let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            _ = try await f.database.synchronizeConfiguredRoots([])
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            await f.database.failTranscriptReadsForTesting(count: 4)
            pass.phase = .complete
            await f.model.receiveProgress(pass)
            let before = await f.database.transcriptReadCountForTesting()
            for (index, delay) in [Duration.milliseconds(250), .seconds(1)].enumerated() {
                await f.clock.advance(by: delay)
                try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
            }
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.transcriptRecoveryPublicationGateForTesting = held
            await f.clock.advance(by: .seconds(4))
            try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
            switch boundary {
            case 0:
                await f.coordinator.indexAll(scope: .proseOnly)
                await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            case 1:
                await f.coordinator.indexAll(scope: .proseOnly)
                f.model.selectSession(other.id)
                try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
            case 2:
                let replacement = try await fixture(count: 3)
                await replacement.model.prepareToTerminate()
                await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            default: await f.model.prepareToTerminate()
            }
            await gate.open()
            try await wait { !f.model.transcriptRecoveryPublicationWaitingForTesting }
            XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
            XCTAssertNil(f.model.transcriptLoadError)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        }
    }

    private func replacementGap() async throws -> (Fixture, Int64, Int64, ReviewReadGate, Task<Void, Never>) {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        await f.model.receiveProgress(.init(phase: .indexing))
        _ = try await f.database.synchronizeConfiguredRoots([])
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        addTeardownBlock { held.cancel(); await gate.open() }
        f.model.watcherReadinessGateForTesting = held
        f.model.settings.onboardingComplete = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.watcherReadinessWaitingForTesting }
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertNil(f.model.activeIndexPassIDForTesting, "the replacement owns activity before its pass starts")
        XCTAssertEqual(f.model.startupSubmissionCountForTesting, 0)
        return (f, session.id, other.id, gate, held)
    }

    private func exhaustTransientRecovery(_ f: Fixture) async throws {
        await f.database.failTranscriptReadsForTesting(count: 4)
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await exhaustReadRecovery(f)
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
    }

    func testExhaustedRecoveryRetiresAfterSupersedingNonterminalFailure() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let rows = f.model.messages
        var pass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(pass)
        _ = try await f.database.synchronizeConfiguredRoots([])
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await exhaustTransientRecovery(f)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryTranscriptFailureGateForTesting = held
        await f.database.failTranscriptReadOnceForTesting()
        pass.phase = .complete
        let terminal = Task { await f.model.receiveProgress(pass) }
        try await wait { f.model.summaryTranscriptFailureWaitingForTesting }
        f.model.summaryTranscriptFailureGateForTesting = nil
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        XCTAssertFalse(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertNotNil(f.model.transcriptLoadError)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        let before = await f.database.transcriptReadCountForTesting()
        await gate.open(); await terminal.value
        await f.clock.advance(by: .seconds(60))
        let after = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, before, "a superseding failure must not renew the exhausted budget")
    }

    func testReplacementGapPreservesMissingSnapshotsAndExhaustedFeedback() async throws {
        let (f, sessionID, _, gate, _) = try await replacementGap()
        let rows = f.model.messages, project = f.model.selectedProjectID
        let message = try XCTUnwrap(rows.first)
        // Summary and manual-recovery publishers must preserve the selection in this gap.
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertTrue(f.model.transcriptIsTemporarilyUnavailable)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        try await exhaustTransientRecovery(f)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
        XCTAssertEqual(f.model.selectedProjectID, project)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.messages.first?.id, message.id)
        XCTAssertNotNil(f.model.hydratedMessages[message.id])
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptLoadError).contains("wait for indexing"))
        await gate.open()
        try await wait { f.model.progress.phase == .complete && !f.model.transcriptIsTemporarilyUnavailable }
        XCTAssertNil(f.model.transcriptLoadError)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertFalse(f.model.messages.isEmpty)
        XCTAssertEqual(f.model.startupSubmissionCountForTesting, 1)
    }

    func testExplicitMissingSelectionInReplacementGapCompletesOnce() async throws {
        let (f, _, sessionID, gate, _) = try await replacementGap()
        // The source has not yet been indexed by the replacement, so this read is missing.
        let before = await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount }
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.$scrollRequest.dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        f.model.selectSession(sessionID, showWindow: true)
        try await wait { f.model.transcriptIsTemporarilyUnavailable && events.windows == 1 }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
        XCTAssertEqual(events.scrolls, 0)
        try await exhaustTransientRecovery(f)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 0)
        await gate.open()
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == before + 1 }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertNil(f.model.transcriptLoadError)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 1)
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(events.scrolls, 1)
    }

    func testReplacementSettlementRetiresExhaustedFeedbackWithoutReading() async throws {
        for boundary in 0..<4 {
            let (f, sessionID, _, gate, _) = try await replacementGap()
            try await exhaustTransientRecovery(f)
            let rows = f.model.messages
            var before = await f.database.transcriptReadCountForTesting()
            switch boundary {
            case 0:
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.progress.phase == .failed }
            case 1:
                let progressGate = ReviewReadGate(), held = Task { await progressGate.wait() }
                defer { held.cancel(); Task { await progressGate.open() } }
                f.model.schedulerProgressGateForTesting = held
                await f.model.schedulerForTesting?.request(reconcile: true)
                try await wait { f.model.schedulerProgressWaitingForTesting }
                before = await f.database.transcriptReadCountForTesting()
                let attachment = Task { await f.model.attach(database: f.database, coordinator: f.coordinator) }
                try await wait { f.model.pendingDatabaseForTesting != nil }
                attachment.cancel()
                f.model.schedulerProgressGateForTesting = nil
                await progressGate.open()
                let committed = await attachment.value
                XCTAssertFalse(committed)
                XCTAssertEqual(f.model.progress.phase, .cancelled)
            case 2:
                f.model.settings.onboardingComplete = false
                await gate.open()
                try await wait { f.model.progress.phase == .waiting && !f.model.watcherReadinessWaitingForTesting }
            default:
                let committed = await f.model.attach(database: f.database, coordinator: f.coordinator)
                XCTAssertTrue(committed)
            }
            try await wait { !f.model.transcriptIsTemporarilyUnavailable }
            XCTAssertFalse(f.model.indexingPassActiveForTesting)
            XCTAssertNotNil(f.model.transcriptLoadError)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
            XCTAssertEqual(f.model.selectedSessionID, sessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            let after = await f.database.transcriptReadCountForTesting()
            XCTAssertEqual(after, before, "settlement only reevaluates retained episode state")
            await gate.open()
        }
    }

    func testSavedSessionTemporaryAbsenceNeverOpensWindow() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        await f.model.prepareToTerminate()
        let model = try uninstalledModel(clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("transient-restoration.json"), savedSessionID: session.id)
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attach(database: f.database,
            coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
        await model.refreshSummariesForTesting(lightweight: false)
        try await wait { model.selectedSessionID == session.id && !model.messages.isEmpty }
        await model.receiveProgress(.init(phase: .indexing))
        _ = try await f.database.synchronizeConfiguredRoots([])
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await wait { model.transcriptIsTemporarilyUnavailable }
        XCTAssertEqual(model.settings.lastSessionID, session.id)
        await f.coordinator.indexAll(scope: .proseOnly)
        await model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        XCTAssertEqual(model.selectedSessionID, session.id)
        XCTAssertFalse(model.messages.isEmpty)
        XCTAssertFalse(model.transcriptIsTemporarilyUnavailable)
        XCTAssertEqual(events.windows, 0)
    }

    func testFailedMonitoringRetriesOneOwnedReconciliationAndRestoresDelivery() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.failsWatcherStartForTesting = true
        let first = await f.model.startWatchingForTesting([source])
        XCTAssertTrue(first)
        XCTAssertEqual(f.model.activeWatcherCountForTesting, 0)
        XCTAssertFalse(f.model.monitoringWarnings.isEmpty)
        f.model.startIndexing(sources: [source])
        try await wait { f.model.progress.phase == .complete && f.model.safetyVerificationActiveForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        try line(98).write(to: f.root.appendingPathComponent("watcher-gap.jsonl"))
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.watcherPreparationGateForTesting = held
        f.model.failsWatcherStartForTesting = false
        let second = Task { await f.model.startWatchingForTesting([source]) }
        try await wait { f.model.watcherPreparationWaitingForTesting }
        let third = Task { await f.model.startWatchingForTesting([source]) }
        await gate.open()
        let secondStarted = await second.value, thirdStarted = await third.value
        XCTAssertTrue(secondStarted)
        XCTAssertTrue(thirdStarted)
        XCTAssertEqual(f.model.watcherStartCountForTesting, 2)
        XCTAssertEqual(f.model.activeWatcherCountForTesting, 1)
        XCTAssertTrue(f.model.watcherRequiresRootReconciliationForTesting)
        f.model.startIndexing(sources: [source])
        f.model.startIndexing(sources: [source])
        try await wait { f.model.startupSubmissionCountForTesting == 2 && f.model.progress.phase == .complete
            && f.model.safetyVerificationActiveForTesting }
        XCTAssertTrue(f.model.monitoringWarnings.isEmpty)
        let reconciled = try await f.database.sessions(limit: 100)
        XCTAssertTrue(reconciled.contains { $0.title == "NavigationNeedle 98" }, "the retry scans changes from the monitoring gap")
        try line(99).write(to: f.root.appendingPathComponent("watcher-resumed.jsonl"))
        try await wait {
            await f.clock.advance(by: .milliseconds(250))
            return (try? await f.database.sessions(limit: 100).contains { $0.title == "NavigationNeedle 99" }) == true
        }
    }

    func testInstalledStreamsRetireOnOnboardingReversalAndResumeOnce() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.watcherReadinessGateForTesting = held
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.watcherReadinessWaitingForTesting }
        XCTAssertEqual(f.model.activeWatcherCountForTesting, 1)
        XCTAssertTrue(f.model.metadataWatcherAttachedForTesting)
        let generation = f.model.watcherGenerationForTesting
        f.model.settings.onboardingComplete = false
        await gate.open()
        try await wait { f.model.progress.phase == .waiting && !f.model.watcherReadinessWaitingForTesting }
        XCTAssertGreaterThan(f.model.watcherGenerationForTesting, generation)
        XCTAssertEqual(f.model.activeWatcherCountForTesting, 0)
        XCTAssertFalse(f.model.metadataWatcherAttachedForTesting)
        XCTAssertFalse(f.model.safetyVerificationActiveForTesting)
        XCTAssertFalse(f.model.watcherReadyForTesting)
        XCTAssertTrue(f.model.watcherRequiresRootReconciliationForTesting)
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        f.model.watcherReadinessGateForTesting = nil
        f.model.settings.onboardingComplete = true
        let source = ClaudeCodeSource(roots: [f.root])
        let resumed = await f.model.startWatchingForTesting([source])
        XCTAssertTrue(resumed)
        f.model.startIndexing(sources: [source])
        f.model.startIndexing(sources: [source])
        try await wait { f.model.progress.phase == .complete }
        XCTAssertEqual(f.model.startupSubmissionCountForTesting, 1)
        XCTAssertEqual(f.model.progress.activity, .rootRecovery)
        XCTAssertEqual(f.model.activeWatcherCountForTesting, 1)
    }

    func testObsoleteDeferralCannotSettleSuccessorOrClearAlert() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let readiness = ReviewReadGate(), readyHeld = Task { await readiness.wait() }
        let outcome = ReviewReadGate(), outcomeHeld = Task { await outcome.wait() }
        defer { readyHeld.cancel(); outcomeHeld.cancel(); Task { await readiness.open(); await outcome.open() } }
        f.model.watcherReadinessGateForTesting = readyHeld
        let source = ClaudeCodeSource(roots: [f.root])
        let obsolete = Task { await f.model.startWatchingForTesting([source]) }
        try await wait { f.model.watcherReadinessWaitingForTesting }
        f.model.watcherOutcomeGateForTesting = outcomeHeld
        f.model.settings.onboardingComplete = false
        await readiness.open()
        try await wait { f.model.watcherOutcomeWaitingForTesting }
        XCTAssertEqual(f.model.activeWatcherCountForTesting, 0)
        f.model.watcherOutcomeGateForTesting = nil
        f.model.watcherReadinessGateForTesting = nil
        f.model.settings.onboardingComplete = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.progress.phase == .complete && f.model.watcherReadyForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let progress = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(progress)
        f.model.startupError = "Unrelated successor error"
        let generation = f.model.watcherGenerationForTesting
        await outcome.open()
        let started = await obsolete.value
        XCTAssertFalse(started)
        XCTAssertEqual(f.model.progress.passID, progress.passID)
        XCTAssertEqual(f.model.progress.phase, .indexing)
        XCTAssertTrue(f.model.watcherReadyForTesting)
        XCTAssertEqual(f.model.watcherGenerationForTesting, generation)
        XCTAssertEqual(f.model.startupError, "Unrelated successor error")
    }

    func testMonitoringWarningReentrancyCannotPublishReadyAfterDeferral() async throws {
        for replacesConfiguration in [false, true] {
            let f = try await fixture(count: 2)
            f.model.settings.onboardingComplete = true
            f.model.failsWatcherStartForTesting = true
            var handled = false
            let subscription = f.model.$monitoringWarnings.sink { warnings in
                guard !warnings.isEmpty, !handled else { return }
                handled = true
                if replacesConfiguration {
                    f.model.failsWatcherStartForTesting = false
                    f.model.reloadSourcesAndRebuild()
                } else { f.model.settings.onboardingComplete = false }
            }
            defer { subscription.cancel() }
            let started = await f.model.startWatchingForTesting([ClaudeCodeSource(roots: [f.root])])
            XCTAssertFalse(started)
            if replacesConfiguration {
                try await wait { f.model.watcherReadyForTesting && f.model.progress.phase == .complete }
                XCTAssertEqual(f.model.activeWatcherCountForTesting, 1)
                XCTAssertEqual(f.model.startupSubmissionCountForTesting, 1)
                XCTAssertTrue(f.model.monitoringWarnings.isEmpty)
            } else {
                XCTAssertFalse(f.model.watcherReadyForTesting)
                XCTAssertEqual(f.model.activeWatcherCountForTesting, 0)
                XCTAssertFalse(f.model.metadataWatcherAttachedForTesting)
                XCTAssertTrue(f.model.watcherRequiresRootReconciliationForTesting)
                XCTAssertEqual(f.model.progress.phase, .waiting)
            }
        }
    }

    func testInitialAttachmentFailureFeedbackSurvivesDismissalAndClearsOnInstallation() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        let model = try uninstalledModel(clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("initial-failure.json"))
        model.settings.onboardingComplete = true
        model.initialIndexOpenErrorForTesting = "Synthetic startup error"
        model.start()
        try await wait { model.progress.phase == .failed && model.startupError != nil }
        model.startupError = nil
        XCTAssertFalse(model.canRebuildIndex)
        XCTAssertEqual(model.rebuildUnavailableReason,
            "Rebuild is unavailable because index startup failed. Resolve the startup error and restart Trace.")
        model.startupError = "Unrelated copy error"
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attach(database: f.database,
            coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
        XCTAssertTrue(model.canRebuildIndex)
        XCTAssertNil(model.rebuildUnavailableReason)
        XCTAssertEqual(model.startupError, "Unrelated copy error")
    }

    func testWatcherStartupCoalescesAndMergesForcedReconciliation() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        var activities: [IndexActivity] = []
        let model = try uninstalledModel(clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("shared-watchers.json"),
            startupActivityObserver: { activities.append($0) })
        model.settings.onboardingComplete = true
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attach(database: f.database,
            coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        model.watcherPreparationGateForTesting = held
        let first = Task { await model.startWatchingForTesting([source]) }
        try await wait { model.watcherPreparationWaitingForTesting }
        let generation = model.watcherGenerationForTesting
        let second = Task { await model.startWatchingForTesting([source], force: true) }
        try await wait { model.watcherRequiresRootReconciliationForTesting }
        XCTAssertEqual(model.watcherStartCountForTesting, 1)
        XCTAssertFalse(model.watcherReadyForTesting)
        await gate.open()
        let firstStarted = await first.value, secondStarted = await second.value
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(model.watcherGenerationForTesting, generation)
        XCTAssertTrue(model.watcherReadyForTesting)
        XCTAssertTrue(model.startupReconciliationPathsForTesting.contains(TraceFileIO.canonicalPath(f.root.path).path))
        model.startIndexing(sources: [source])
        model.startIndexing(sources: [source])
        try await wait { model.progress.phase == .complete }
        XCTAssertEqual(model.startupSubmissionCountForTesting, 1)
        XCTAssertEqual(activities, [.rootRecovery])
    }

    func testObsoleteWatcherStartupCannotResetItsSuccessor() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.watcherPreparationGateForTesting = held
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.watcherPreparationWaitingForTesting }
        let retiredGeneration = f.model.watcherGenerationForTesting
        f.model.watcherPreparationGateForTesting = nil
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.progress.phase == .complete && f.model.watcherReadyForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertGreaterThan(f.model.watcherGenerationForTesting, retiredGeneration)
        var ongoing = IndexProgress(phase: .indexing)
        ongoing.unresolvedFailedFiles = 2
        ongoing.unresolvedDiscoveryFailures = 3
        await f.model.receiveProgress(ongoing)
        let currentGeneration = f.model.watcherGenerationForTesting
        await gate.open()
        try await wait { !f.model.watcherPreparationWaitingForTesting }
        XCTAssertEqual(f.model.progress.passID, ongoing.passID)
        XCTAssertEqual(f.model.progress.phase, .indexing)
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertEqual(f.model.progress.unresolvedFailedFiles, 2)
        XCTAssertEqual(f.model.progress.unresolvedDiscoveryFailures, 3)
        XCTAssertEqual(f.model.watcherGenerationForTesting, currentGeneration)
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
    }

    func testRebuildProgressCannotFinishRetryBeforeWatcherReadiness() async throws {
        for changesScope in [false, true] {
            let f = try await fixture(count: 2)
            f.model.settings.onboardingComplete = true
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.sourceReloadRecovery.error != nil }
            let error = try XCTUnwrap(f.model.sourceReloadRecovery.error)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            let progressGate = ReviewReadGate(), progressHeld = Task { await progressGate.wait() }
            defer {
                held.cancel(); progressHeld.cancel()
                Task { await gate.open(); await progressGate.open() }
            }
            f.model.watcherReadinessGateForTesting = held
            f.model.failSourceConfigurationForTesting = false
            f.model.retrySourceConfiguration()
            try await wait { f.model.watcherReadinessWaitingForTesting }
            if changesScope { f.model.settings.indexScope = .everything }
            f.model.rebuildIndex()
            try await wait { f.model.rebuildSubmissionCountForTesting == 1 && f.model.progress.phase == .complete }
            await f.model.schedulerForTesting?.waitUntilIdle()
            XCTAssertEqual(f.model.sourceReloadRecovery, .retrying(error))
            XCTAssertFalse(f.model.watcherReadyForTesting)
            f.model.schedulerProgressGateForTesting = progressHeld
            await gate.open()
            try await wait { f.model.schedulerProgressWaitingForTesting }
            XCTAssertTrue(f.model.watcherReadyForTesting)
            XCTAssertEqual(f.model.sourceReloadRecovery, .retrying(error), "early progress is not a completion credit")
            f.model.schedulerProgressGateForTesting = nil
            await progressGate.open()
            try await wait { f.model.sourceReloadRecovery == .normal && f.model.progress.phase == .complete }
            XCTAssertEqual(f.model.startupSubmissionCountForTesting, 1)
        }
    }

    func testOnboardingDeferredReloadRetainsForcedReconciliationForResume() async throws {
        let f = try await fixture(count: 2), added = try await fixture(count: 3)
        let source = ClaudeCodeSource(roots: [f.root, added.root])
        f.model.sourceReloadSourcesForTesting = [source]
        f.model.settings.onboardingComplete = false
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.schedulerForTesting != nil
            && f.model.progress.phase == .waiting }
        let cached = try await f.database.sessions(limit: 100)
        XCTAssertFalse(cached.contains { $0.sourcePath.hasPrefix(added.root.path) })
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        f.model.settings.onboardingComplete = true
        let started = await f.model.startWatchingForTesting([source])
        XCTAssertTrue(started)
        XCTAssertTrue(f.model.watcherRequiresRootReconciliationForTesting)
        f.model.startIndexing(sources: [source])
        try await wait { f.model.progress.phase == .complete }
        let current = try await f.database.sessions(limit: 100)
        XCTAssertTrue(current.contains { $0.sourcePath.hasPrefix(added.root.path) })
        XCTAssertEqual(f.model.progress.activity, .rootRecovery)
    }

    func testTerminationRejectsHeldWatcherReadiness() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.watcherReadinessGateForTesting = held
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.watcherReadinessWaitingForTesting }
        await f.model.prepareToTerminate()
        await gate.open()
        try await wait { !f.model.watcherReadinessWaitingForTesting }
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        XCTAssertFalse(f.model.watcherReadyForTesting)
        XCTAssertFalse(f.model.canRebuildIndex)
        XCTAssertEqual(f.model.startupSubmissionCountForTesting, 0)
    }

    func testRebuildAvailabilityTracksInstallationSettingsRetirementAndFailure() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        let model = try uninstalledModel(clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("rebuild-availability.json"))
        model.settings.onboardingComplete = true
        XCTAssertFalse(model.canRebuildIndex)
        XCTAssertEqual(model.rebuildUnavailableReason, "Rebuild is available after the index finishes opening.")
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attach(database: f.database,
            coordinator: IndexCoordinator(database: f.database, sources: [source], clock: f.clock))
        XCTAssertTrue(model.canRebuildIndex)
        model.settings.onboardingComplete = false
        XCTAssertFalse(model.canRebuildIndex)
        model.settings.onboardingComplete = true
        XCTAssertTrue(model.canRebuildIndex)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        model.schedulerProgressGateForTesting = held
        await model.schedulerForTesting?.request(reconcile: true)
        try await wait { model.schedulerProgressWaitingForTesting }
        model.sourceReloadSourcesForTesting = [source]
        model.failSourceConfigurationForTesting = true
        model.reloadSourcesAndRebuild()
        XCTAssertTrue(model.canRebuildIndex, "readable attachment permits queued rebuilds")
        model.schedulerProgressGateForTesting = nil
        await gate.open()
        try await wait { model.sourceReloadRecovery.error != nil }
        XCTAssertTrue(model.canRebuildIndex, "manual Rebuild can retry configuration failure")
        await model.prepareToTerminate()
        XCTAssertFalse(model.canRebuildIndex)
    }

    func testFailedReloadExplainsQueuedRebuildCancellationAndRetryDoesNotRebuild() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.schedulerProgressGateForTesting = held
        await f.model.schedulerForTesting?.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        f.model.rebuildIndex()
        f.model.schedulerProgressGateForTesting = nil
        await gate.open()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let notice = "The queued index rebuild was cancelled. Retry resumes updates without rebuilding. Choose Rebuild Index again to rebuild."
        XCTAssertTrue(try XCTUnwrap(f.model.startupError).contains(notice))
        XCTAssertTrue(try XCTUnwrap(f.model.sourceReloadRecovery.error).contains(notice))
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        f.model.startupError = nil
        XCTAssertTrue(try XCTUnwrap(f.model.sourceReloadRecovery.error).contains(notice))
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.sourceReloadRecovery == .normal && f.model.progress.phase == .complete }
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionCountForTesting == 1 && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
    }

    func testSourceReloadRetryReconcilesPausedFileChangesWithLatestRootsAndScope() async throws {
        let f = try await fixture(count: 2), removed = try await fixture(count: 3), latest = try await fixture(count: 4)
        f.model.settings.onboardingComplete = true
        let deletedFile = f.root.appendingPathComponent("deleted-during-pause.jsonl")
        try line(90).write(to: deletedFile)
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root, removed.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.progress.phase == .complete && f.model.watcherReadyForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let initiallyIndexed = try await f.database.sessions(limit: 100)
        XCTAssertTrue(initiallyIndexed.contains { $0.sourcePath.hasPrefix(removed.root.path) })
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let cached = try await f.database.sessions(limit: 100)
        XCTAssertEqual(cached.count, 14)
        XCTAssertTrue(cached.contains { $0.sourcePath.hasPrefix(removed.root.path) })
        let file = f.root.appendingPathComponent("sessions.jsonl")
        // Drop s-1, rewrite s-0, and append a new session while no watcher runs.
        var changed = Data(String(decoding: try line(0), as: UTF8.self)
            .replacingOccurrences(of: "NavigationNeedle 0", with: "PausedRewriteNeedle").utf8)
        for index in 2..<7 { changed.append(try line(index)) }
        let tool = try JSONSerialization.data(withJSONObject: ["type": "assistant", "uuid": "paused-tool",
            "sessionId": "s-0", "cwd": "/tmp/NavigationReview", "timestamp": 1_700_000_010_000,
            "message": ["content": [["type": "tool_use", "id": "paused-tool", "name": "Bash",
                                     "input": ["command": "PausedScopeNeedle"]]]]]) + Data([10])
        changed.append(tool)
        try changed.write(to: file, options: .atomic)
        try FileManager.default.removeItem(at: deletedFile)
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root, latest.root])]
        f.model.settings.indexScope = .everything
        let stillCached = try await f.database.sessions(limit: 100)
        XCTAssertEqual(stillCached.map(\.id), cached.map(\.id))
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.schedulerForTesting != nil && f.model.progress.phase == .complete }
        let current = try await f.database.sessions(limit: 100)
        XCTAssertTrue(current.contains { $0.sourcePath.hasPrefix(latest.root.path) })
        XCTAssertFalse(current.contains { $0.sourcePath.hasPrefix(removed.root.path) })
        XCTAssertEqual(current.filter { $0.sourcePath == file.path }.count, 6)
        XCTAssertFalse(current.contains { $0.sourcePath == deletedFile.path })
        XCTAssertFalse(current.contains { $0.sourcePath == file.path && $0.title == "NavigationNeedle 1" })
        for query in ["PausedRewriteNeedle", "PausedScopeNeedle"] {
            let found = try await f.database.search(query: query, filters: .init(), sort: .relevance)
            XCTAssertEqual(found.results.count, 1)
        }
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
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

    func testOlderSelectionPublishingFirstCannotDiscardNewerSummary() async throws {
        try await overlappingTranscriptReads(staleSelection: true, staleFirst: true)
    }

    func testNewerSummaryPublishingFirstRejectsOlderSelection() async throws {
        try await overlappingTranscriptReads(staleSelection: true, staleFirst: false)
    }

    func testOlderSummaryPublishingFirstCannotDiscardNewerSelection() async throws {
        try await overlappingTranscriptReads(staleSelection: false, staleFirst: true)
    }

    func testRowBearingSummaryCannotOverwriteNewerSelectionAfterSourceReplacement() async throws {
        try await overlappingTranscriptReads(staleSelection: false, staleFirst: false)
    }

    private func overlappingTranscriptReads(staleSelection: Bool, staleFirst: Bool) async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let selectionReadGate = ReviewReadGate()
        let selectionReadTask = Task { await selectionReadGate.wait() }
        let selectionGate = ReviewReadGate()
        let selectionTask = Task { await selectionGate.wait() }
        let summaryGate = ReviewReadGate()
        let summaryTask = Task { await summaryGate.wait() }
        defer {
            selectionReadTask.cancel(); selectionTask.cancel(); summaryTask.cancel()
            Task { await selectionReadGate.open(); await selectionGate.open(); await summaryGate.open() }
        }
        if !staleSelection { f.model.selectionTranscriptReadGateForTesting = selectionReadTask }
        f.model.selectionTranscriptGateForTesting = selectionTask
        f.model.summaryTranscriptGateForTesting = summaryTask
        f.model.selectSession(session.id)
        if staleSelection {
            try await wait { f.model.selectionTranscriptWaitingForTesting }
        } else {
            try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        }
        XCTAssertTrue(f.model.messages.isEmpty)
        let old = try await f.database.transcriptSnapshot(sessionID: session.id,
            knownSession: f.model.selectedSession, knownMessageCount: f.model.messages.count)
        let oldRows = try XCTUnwrap(old.messages)
        XCTAssertFalse(oldRows.isEmpty, "the older snapshot must contain rows")
        var summaryRefresh: Task<Void, Never>?
        if !staleSelection {
            summaryRefresh = Task { await f.model.refreshSummariesForTesting() }
            try await wait { f.model.summaryTranscriptWaitingForTesting }
        }

        let file = f.root.appendingPathComponent("sessions.jsonl")
        let rewritten = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(
            of: "NavigationNeedle", with: "RewrittenNavigationNeedle with longer locators")
        try Data(rewritten.utf8).write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: session.id)
        let currentSession = try XCTUnwrap(current.session)
        let currentRows = try XCTUnwrap(current.messages)
        XCTAssertEqual(currentSession.id, old.session?.id, "exercise replacement with a reused session ID")
        XCTAssertEqual(currentRows.count, oldRows.count, "row count cannot detect this replacement")
        XCTAssertNotEqual(currentSession.sourceGeneration, old.session?.sourceGeneration)
        XCTAssertNotEqual(currentRows.map(\.locator), oldRows.map(\.locator))
        if staleSelection {
            summaryRefresh = Task { await f.model.refreshSummariesForTesting() }
            try await wait { f.model.summaryTranscriptWaitingForTesting }
        } else {
            await selectionReadGate.open()
            try await wait { f.model.selectionTranscriptWaitingForTesting }
        }
        let refresh = try XCTUnwrap(summaryRefresh)

        let selectionPublishesFirst = staleSelection == staleFirst
        if selectionPublishesFirst {
            await selectionGate.open()
            try await wait { !f.model.selectionTranscriptWaitingForTesting }
        } else {
            await summaryGate.open()
            await refresh.value
        }
        XCTAssertEqual(f.model.selectedSession?.sourceGeneration,
                       staleFirst ? old.session?.sourceGeneration : currentSession.sourceGeneration)
        XCTAssertEqual(f.model.messages.map(\.locator), (staleFirst ? oldRows : currentRows).map(\.locator))

        if selectionPublishesFirst {
            await summaryGate.open()
            await refresh.value
        } else {
            await selectionGate.open()
            try await wait { !f.model.selectionTranscriptWaitingForTesting }
        }
        XCTAssertEqual(f.model.selectedSession?.sourceGeneration, currentSession.sourceGeneration)
        XCTAssertEqual(f.model.messages.map(\.locator), currentRows.map(\.locator),
                       "the newest database snapshot must win in both completion orders")
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        XCTAssertTrue(try XCTUnwrap(f.model.hydratedMessages[message.id]).sections.prose.contains("RewrittenNavigationNeedle"))
    }

    func testMissingSummaryCannotClearNewerSelectionAfterSourceRecreation() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let selectionGate = ReviewReadGate(), selectionTask = Task { await selectionGate.wait() }
        let summaryGate = ReviewReadGate(), summaryTask = Task { await summaryGate.wait() }
        defer {
            selectionTask.cancel(); summaryTask.cancel()
            Task { await selectionGate.open(); await summaryGate.open() }
        }
        f.model.selectionTranscriptReadGateForTesting = selectionTask
        f.model.summaryTranscriptGateForTesting = summaryTask
        f.model.openSession(session)
        let revealToken = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let original = try String(contentsOf: file, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let missing = try await f.database.transcriptSnapshot(sessionID: session.id)
        XCTAssertNil(missing.session)
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        try Data(original.replacingOccurrences(of: "NavigationNeedle", with: "RecreatedNavigationNeedle").utf8)
            .write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: session.id)
        // All six fixture sessions belong to this file. Deleting it empties the
        // session table; INTEGER PRIMARY KEY permits recreating the same IDs.
        XCTAssertEqual(current.session?.id, session.id, "exercise a recreated session with the same ID")
        let rows = try XCTUnwrap(current.messages)
        await selectionGate.open()
        try await wait { !f.model.selectionTranscriptReadWaitingForTesting && !f.model.messages.isEmpty }
        await summaryGate.open()
        await refresh.value
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, revealToken)
        XCTAssertEqual(f.model.selectedSession?.sourceGeneration, current.session?.sourceGeneration)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        XCTAssertTrue(try XCTUnwrap(f.model.hydratedMessages[message.id]).sections.prose.contains("RecreatedNavigationNeedle"))
    }

    func testMissingSummaryPublishingFirstCannotInvalidateRecreatedSelection() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let readGate = ReviewReadGate(), readTask = Task { await readGate.wait() }
        let publicationGate = ReviewReadGate(), publicationTask = Task { await publicationGate.wait() }
        let summaryGate = ReviewReadGate(), summaryTask = Task { await summaryGate.wait() }
        defer {
            readTask.cancel(); publicationTask.cancel(); summaryTask.cancel()
            Task { await readGate.open(); await publicationGate.open(); await summaryGate.open() }
        }
        f.model.selectionTranscriptReadGateForTesting = readTask
        f.model.selectionTranscriptGateForTesting = publicationTask
        f.model.summaryTranscriptGateForTesting = summaryTask
        f.model.openSession(session)
        let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let original = try String(contentsOf: file, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        var summaryFinished = false
        let refresh = Task { await f.model.refreshSummariesForTesting(); summaryFinished = true }
        addTeardownBlock { await summaryGate.open(); await publicationGate.open(); await readGate.open(); await refresh.value }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        try Data(original.replacingOccurrences(of: "NavigationNeedle", with: "RecreatedNavigationNeedle").utf8)
            .write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: session.id)
        XCTAssertEqual(current.session?.id, session.id, "the sole source deliberately recreates the same session IDs")
        let rows = try XCTUnwrap(current.messages)
        await readGate.open()
        try await wait { f.model.selectionTranscriptWaitingForTesting }
        let revision = f.model.transcriptMessageRevision

        await summaryGate.open()
        try await wait { summaryFinished }
        XCTAssertTrue(f.model.selectionTranscriptWaitingForTesting, "the summary must finish independently of selection publication")
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        XCTAssertEqual(f.model.transcriptMessageRevision, revision)

        await publicationGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        XCTAssertEqual(f.model.selectedSession?.transcriptIdentity, current.session?.transcriptIdentity)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        XCTAssertTrue(try XCTUnwrap(f.model.hydratedMessages[message.id]).sections.prose.contains("RecreatedNavigationNeedle"))
    }

    private struct PendingMissingSummary {
        let fixture: Fixture
        let session: SessionSummary
        let token: UUID
        let original: Data
        let readGate: ReviewReadGate
        let publicationGate: ReviewReadGate
        let summaryGate: ReviewReadGate
        let refresh: Task<Void, Never>
        let finished: () -> Bool
    }

    private func preparePendingMissingSummary(selectionReadsFirst: Bool = false) async throws -> PendingMissingSummary {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let readGate = ReviewReadGate(), readTask = Task { await readGate.wait() }
        let publicationGate = ReviewReadGate(), publicationTask = Task { await publicationGate.wait() }
        let summaryGate = ReviewReadGate(), summaryTask = Task { await summaryGate.wait() }
        f.model.selectionTranscriptReadGateForTesting = readTask
        f.model.selectionTranscriptGateForTesting = publicationTask
        f.model.openSession(session)
        let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        await f.model.refreshSummariesForTesting()
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        if selectionReadsFirst {
            await readGate.open()
            try await wait { f.model.selectionTranscriptWaitingForTesting }
        }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        f.model.summaryTranscriptGateForTesting = summaryTask
        var finished = false
        let refresh = Task { await f.model.refreshSummariesForTesting(); finished = true }
        addTeardownBlock {
            readTask.cancel(); publicationTask.cancel(); summaryTask.cancel()
            await readGate.open(); await publicationGate.open(); await summaryGate.open(); await refresh.value
        }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        return .init(fixture: f, session: session, token: token, original: original,
                     readGate: readGate, publicationGate: publicationGate, summaryGate: summaryGate,
                     refresh: refresh, finished: { finished })
    }

    private func assertMissingSummaryCleared(_ pending: PendingMissingSummary, revision: Int,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let model = pending.fixture.model
        XCTAssertNil(model.selectedSessionID, file: file, line: line)
        XCTAssertNil(model.selectedSession, file: file, line: line)
        XCTAssertNil(model.settings.lastSessionID, file: file, line: line)
        XCTAssertNil(model.sidebarRevealRequest, file: file, line: line)
        XCTAssertTrue(model.messages.isEmpty, file: file, line: line)
        XCTAssertTrue(model.hydratedMessages.isEmpty, file: file, line: line)
        XCTAssertEqual(model.transcriptMessageRevision, revision + 1, file: file, line: line)
    }

    func testNewerPendingMissingSelectionConfirmsDeletionBeforeNavigating() async throws {
        let pending = try await preparePendingMissingSummary()
        let model = pending.fixture.model
        await pending.readGate.open()
        try await wait { model.selectionTranscriptWaitingForTesting }
        let revision = model.transcriptMessageRevision
        let before = await pending.fixture.database.transcriptReadCountForTesting()
        await pending.summaryGate.open()
        try await wait { pending.finished() }
        assertMissingSummaryCleared(pending, revision: revision)
        let after = await pending.fixture.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, before, "a newer missing selection needs no confirmation")
        await pending.publicationGate.open()
        try await wait { !model.selectionTranscriptWaitingForTesting }
        assertMissingSummaryCleared(pending, revision: revision)
    }

    func testOlderPendingPresentSelectionCannotResurrectConfirmedDeletion() async throws {
        let pending = try await preparePendingMissingSummary(selectionReadsFirst: true)
        let model = pending.fixture.model
        let revision = model.transcriptMessageRevision
        await pending.summaryGate.open()
        try await wait { pending.finished() }
        assertMissingSummaryCleared(pending, revision: revision)
        await pending.publicationGate.open()
        try await wait { !model.selectionTranscriptWaitingForTesting }
        assertMissingSummaryCleared(pending, revision: revision)
    }

    func testFailedPendingSelectionReadPreservesMissingSummaryStateUntilRetry() async throws {
        let pending = try await preparePendingMissingSummary()
        let f = pending.fixture
        let rows = f.model.messages, cache = f.model.hydratedMessages.keys.sorted()
        let revision = f.model.transcriptMessageRevision
        await pending.summaryGate.open()
        try await wait { f.model.missingSummarySelectionReadWaitingForTesting }
        await f.database.failTranscriptReadOnceForTesting()
        await pending.readGate.open()
        try await wait { pending.finished() }
        XCTAssertEqual(f.model.selectedSessionID, pending.session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, pending.session.id)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, pending.token)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.hydratedMessages.keys.sorted(), cache)
        XCTAssertEqual(f.model.transcriptMessageRevision, revision)
        f.model.summaryTranscriptGateForTesting = nil
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        await f.clock.advance(by: .milliseconds(250))
        try await wait { f.model.selectedSessionID == nil }
        assertMissingSummaryCleared(pending, revision: revision)
    }

    func testFailedMissingSummaryConfirmationPreservesStateUntilRetry() async throws {
        let pending = try await preparePendingMissingSummary(selectionReadsFirst: true)
        let f = pending.fixture
        let rows = f.model.messages, cache = f.model.hydratedMessages.keys.sorted()
        let revision = f.model.transcriptMessageRevision
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryReadGateForTesting = task
        await pending.summaryGate.open()
        try await wait { f.model.transcriptRecoveryReadWaitingForTesting }
        await f.database.failTranscriptReadOnceForTesting()
        await gate.open()
        try await wait { pending.finished() }
        XCTAssertEqual(f.model.selectedSessionID, pending.session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, pending.session.id)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, pending.token)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.hydratedMessages.keys.sorted(), cache)
        XCTAssertEqual(f.model.transcriptMessageRevision, revision)
        f.model.transcriptRecoveryReadGateForTesting = nil
        f.model.summaryTranscriptGateForTesting = nil
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        await f.clock.advance(by: .milliseconds(250))
        try await wait { f.model.selectedSessionID == nil }
        assertMissingSummaryCleared(pending, revision: revision)
        await pending.publicationGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        assertMissingSummaryCleared(pending, revision: revision)
    }

    private enum MissingSummarySuspension { case selectionRead, confirmation }
    private enum MissingSummarySupersession { case selection, database, summary }

    private func supersedePendingMissingSummary(_ change: MissingSummarySupersession,
                                               during suspension: MissingSummarySuspension) async throws {
        let pending = try await preparePendingMissingSummary(selectionReadsFirst: suspension == .confirmation)
        let f = pending.fixture
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        if suspension == .confirmation { f.model.transcriptRecoveryPublicationGateForTesting = task }
        await pending.summaryGate.open()
        try await wait {
            suspension == .selectionRead ? f.model.missingSummarySelectionReadWaitingForTesting
                : f.model.transcriptRecoveryPublicationWaitingForTesting
        }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        try pending.original.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        f.model.summaryTranscriptGateForTesting = nil
        f.model.selectionTranscriptReadGateForTesting = nil
        switch change {
        case .selection:
            f.model.selectionTranscriptGateForTesting = nil
            let available = try await f.database.sessions(projectCanonicalKey: f.project.canonicalKey)
            let other = try XCTUnwrap(available.first)
            XCTAssertNotEqual(other.id, pending.session.id)
            f.model.openSession(other)
            try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
        case .database:
            f.model.selectionTranscriptGateForTesting = nil
            let replacement = try await fixture(count: 2)
            await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            await f.model.refreshSummariesForTesting()
            f.model.openSession(try XCTUnwrap(f.model.sessions.first))
            try await wait { f.model.selectedSession?.sourcePath == replacement.root.appendingPathComponent("sessions.jsonl").path
                && !f.model.messages.isEmpty }
        case .summary:
            await f.model.refreshSummariesForTesting()
        }
        let sessionID = f.model.selectedSessionID, identity = f.model.selectedSession?.transcriptIdentity
        let rows = f.model.messages, cache = f.model.hydratedMessages.keys.sorted()
        let token = f.model.sidebarRevealRequest?.token, revision = f.model.transcriptMessageRevision
        await pending.readGate.open()
        await gate.open()
        try await wait { pending.finished() }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.selectedSession?.transcriptIdentity, identity)
        XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.hydratedMessages.keys.sorted(), cache)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        XCTAssertEqual(f.model.transcriptMessageRevision, revision)
        if change == .summary {
            try await wait { f.model.selectionTranscriptWaitingForTesting }
        }
        await pending.publicationGate.open()
        if suspension == .confirmation || change == .summary {
            try await wait { !f.model.selectionTranscriptWaitingForTesting }
        }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.selectedSession?.transcriptIdentity, identity)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
    }

    func testSelectionChangeDiscardsMissingSummaryAtBothSuspensions() async throws {
        for suspension in [MissingSummarySuspension.selectionRead, .confirmation] {
            try await supersedePendingMissingSummary(.selection, during: suspension)
        }
    }

    func testDatabaseChangeDiscardsMissingSummaryAtBothSuspensions() async throws {
        for suspension in [MissingSummarySuspension.selectionRead, .confirmation] {
            try await supersedePendingMissingSummary(.database, during: suspension)
        }
    }

    func testSummaryChangeDiscardsMissingSummaryAtBothSuspensions() async throws {
        for suspension in [MissingSummarySuspension.selectionRead, .confirmation] {
            try await supersedePendingMissingSummary(.summary, during: suspension)
        }
    }

    func testSameDatabaseAttachmentPreservesPendingSelectionRead() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.selectionTranscriptReadGateForTesting = task
        f.model.openSession(session)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        let token = f.model.sidebarRevealRequest?.token
        await f.model.attach(database: f.database, coordinator: f.coordinator)
        await gate.open()
        try await wait { !f.model.messages.isEmpty }
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        XCTAssertEqual(f.model.selectedSession?.transcriptIdentity, session.transcriptIdentity)
    }

    func testObsoleteSelectionCleanupPreservesNewPendingRead() async throws {
        let pending = try await preparePendingMissingSummary(selectionReadsFirst: true)
        let f = pending.fixture
        let file = f.root.appendingPathComponent("sessions.jsonl")
        try pending.original.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let available = try await f.database.sessions(projectCanonicalKey: f.project.canonicalKey)
        let other = try XCTUnwrap(available.first)
        XCTAssertNotEqual(other.id, pending.session.id)
        let readGate = ReviewReadGate(), readTask = Task { await readGate.wait() }
        let publicationGate = ReviewReadGate(), publicationTask = Task { await publicationGate.wait() }
        let summaryGate = ReviewReadGate(), summaryTask = Task { await summaryGate.wait() }
        defer {
            readTask.cancel(); publicationTask.cancel(); summaryTask.cancel()
            Task { await readGate.open(); await publicationGate.open(); await summaryGate.open() }
        }
        f.model.selectionTranscriptReadGateForTesting = readTask
        f.model.selectionTranscriptGateForTesting = publicationTask
        f.model.openSession(other)
        let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }

        await pending.publicationGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        await pending.summaryGate.open()
        try await wait { pending.finished() }
        XCTAssertEqual(f.model.selectedSessionID, other.id)

        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        f.model.summaryTranscriptGateForTesting = summaryTask
        var finished = false
        let refresh = Task { await f.model.refreshSummariesForTesting(); finished = true }
        addTeardownBlock { await readGate.open(); await publicationGate.open(); await summaryGate.open(); await refresh.value }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        try pending.original.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: other.id)
        XCTAssertEqual(current.session?.id, other.id)
        await readGate.open()
        try await wait { f.model.selectionTranscriptWaitingForTesting }
        await summaryGate.open()
        try await wait { finished }
        XCTAssertEqual(f.model.selectedSessionID, other.id)
        XCTAssertEqual(f.model.settings.lastSessionID, other.id)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        await publicationGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        XCTAssertEqual(f.model.selectedSession?.transcriptIdentity, current.session?.transcriptIdentity)
        XCTAssertEqual(f.model.messages.map(\.locator), current.messages?.map(\.locator))
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
    }

    func testTerminationDiscardsPendingMissingSummaryReconciliation() async throws {
        let pending = try await preparePendingMissingSummary()
        let f = pending.fixture
        let rows = f.model.messages, cache = f.model.hydratedMessages.keys.sorted()
        let revision = f.model.transcriptMessageRevision
        await pending.summaryGate.open()
        try await wait { f.model.missingSummarySelectionReadWaitingForTesting }
        await f.model.prepareToTerminate()
        await pending.readGate.open()
        try await wait { pending.finished() && !f.model.selectionTranscriptReadWaitingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, pending.session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, pending.session.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.hydratedMessages.keys.sorted(), cache)
        XCTAssertEqual(f.model.transcriptMessageRevision, revision)
        XCTAssertNil(f.model.sidebarRevealRequest)
    }

    func testPresentTranscriptPreservesRevealDespiteEarlierMissingProjectList() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        await f.database.gateSidebarSnapshotPublicationForTesting(task)
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sidebarSnapshotWaitingForTesting }
        try original.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await gate.open()
        await refresh.value
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.selectedSession?.projectCanonicalKey, session.projectCanonicalKey)
    }

    func testFailedTranscriptReadPreservesRevealDespiteMissingProjectList() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        let rows = f.model.messages
        let file = f.root.appendingPathComponent("sessions.jsonl")
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        await f.clock.advance(by: .milliseconds(250))
        try await wait { f.model.selectedSessionID == nil }
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertTrue(f.model.messages.isEmpty)
    }

    func testMissingSummaryClearsTranscriptExactlyOnce() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        f.model.expandedReasoningIDs.insert(message.id)
        XCTAssertNotNil(f.model.sidebarRevealRequest)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        let revision = f.model.transcriptMessageRevision

        let file = f.root.appendingPathComponent("sessions.jsonl")
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await f.model.refreshSummariesForTesting()

        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertNil(f.model.selectedSession)
        XCTAssertNil(f.model.settings.lastSessionID)
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertTrue(f.model.hydratedMessages.isEmpty)
        XCTAssertTrue(f.model.hydrationFailures.isEmpty)
        XCTAssertTrue(f.model.expandedReasoningIDs.isEmpty)
        XCTAssertEqual(f.model.transcriptMessageRevision, revision + 1,
                       "missing-session navigation should invalidate renderer rows only once")
    }

    func testMissingSummaryRestoresMainSearchProjectContextAndAnchor() async throws {
        let f = try await fixture(count: 2)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f, expectedCount: 2)
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        let anchor = SearchResultAnchor(id: result.id, offset: 37,
                                        oldOrder: f.model.mainSearch.results.map(\.id))
        f.model.openSearchResult(result, fromMainSearch: true, anchor: anchor)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        XCTAssertTrue(f.model.hasSearchReturnContext)

        let file = f.root.appendingPathComponent("sessions.jsonl")
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await f.model.refreshSummariesForTesting()

        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertFalse(f.model.hasSearchReturnContext)
        XCTAssertEqual(f.model.selectedProjectID, f.project.id)
        XCTAssertEqual(f.model.selectedProjectCanonicalKey, f.project.canonicalKey)
        XCTAssertEqual(f.model.selectedProjectDisplayName, f.project.displayName)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.id, anchor.id)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.offset, anchor.offset)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.oldOrder, anchor.oldOrder)
    }

    func testMissingSummaryRejectsDelayedHydrationAfterClearing() async throws {
        let f = try await fixture(count: 2)
        f.model.openSession(try XCTUnwrap(f.model.sessions.first))
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let message = try XCTUnwrap(f.model.messages.first)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.hydrationPublicationGateForTesting = task
        f.model.hydrate(message)
        try await wait { f.model.hydrationPublicationWaitingForTesting }

        let file = f.root.appendingPathComponent("sessions.jsonl")
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await f.model.refreshSummariesForTesting()
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertTrue(f.model.messages.isEmpty)
        let contentRevision = f.model.transcriptContentRevision

        await gate.open()
        try await wait { !f.model.hydrationPublicationWaitingForTesting }
        XCTAssertTrue(f.model.hydratedMessages.isEmpty, "a delayed result cannot repopulate the cleared transcript")
        XCTAssertTrue(f.model.hydrationFailures.isEmpty)
        XCTAssertEqual(f.model.transcriptContentRevision, contentRevision)
    }

    func testOngoingProjectReassignmentPreservesRevealUntilTerminalRefresh() async throws {
        for restoresOriginal in [true, false] {
            let f = try await fixture(count: 2)
            let session = try XCTUnwrap(f.model.sessions.first)
            f.model.openSession(session)
            try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
            let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            let file = f.root.appendingPathComponent("sessions.jsonl")
            let original = try Data(contentsOf: file)
            var moved = Data()
            for index in 0..<6 { moved.append(try line(index, project: "TemporaryReview")) }
            try moved.write(to: file, options: .atomic)
            await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
            XCTAssertNotEqual(f.model.selectedSession?.projectCanonicalKey, session.projectCanonicalKey)
            if restoresOriginal {
                try original.write(to: file, options: .atomic)
                await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
            }
            pass.phase = .complete
            await f.model.receiveProgress(pass)
            if restoresOriginal { XCTAssertEqual(f.model.sidebarRevealRequest?.token, token) }
            else { XCTAssertNil(f.model.sidebarRevealRequest) }
            XCTAssertEqual(f.model.selectedSessionID, session.id)
        }
    }

    func testRecoveryUsesPassStateAtPublicationRatherThanScheduling() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let token = try XCTUnwrap(f.model.sidebarRevealRequest?.token)
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting()
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        // The failed terminal summary scheduled recovery while no pass was active.
        var pass = IndexProgress(phase: .indexing)
        pass.incremental = true
        await f.model.receiveProgress(pass)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        var moved = Data()
        for index in 0..<6 { moved.append(try line(index, project: "TemporaryReview")) }
        try moved.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await f.clock.advance(by: .milliseconds(250))
        try await wait { f.model.selectedSession?.projectCanonicalKey != session.projectCanonicalKey }
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
    }

    func testCurrentSessionProjectChangeCancelsRevealWithoutClearingTranscript() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        XCTAssertNotNil(f.model.sidebarRevealRequest)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        var moved = Data()
        for index in 0..<6 { moved.append(try line(index, project: "MovedReview")) }
        try moved.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let current = try await f.database.transcriptSnapshot(sessionID: session.id)
        XCTAssertNotEqual(current.session?.projectCanonicalKey, session.projectCanonicalKey)
        await f.model.refreshSummariesForTesting()
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.selectedSession?.projectCanonicalKey, current.session?.projectCanonicalKey)
        XCTAssertEqual(f.model.messages.map(\.locator), current.messages?.map(\.locator))
    }

    func testBackgroundProjectMoveKeepsBrowsingProjectUntilExplicitNavigation() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        var moved = Data()
        for index in 0..<6 { moved.append(try line(index, project: "MovedReview")) }
        try moved.write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await f.model.refreshSummariesForTesting()
        let current = try XCTUnwrap(f.model.selectedSession)
        XCTAssertNotEqual(current.projectCanonicalKey, session.projectCanonicalKey)
        XCTAssertEqual(f.model.selectedProjectCanonicalKey, session.projectCanonicalKey,
                       "a background summary must retain the project being browsed")
        XCTAssertNil(f.model.sidebarRevealRequest)
        f.model.openSession(current)
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.selectedProjectCanonicalKey, current.projectCanonicalKey)
        XCTAssertEqual(f.model.sidebarRevealRequest?.projectCanonicalKey, current.projectCanonicalKey)
        XCTAssertEqual(f.model.selectedSessionID, current.id)
    }

    private struct RowRecovery {
        let fixture: Fixture
        let snapshot: SessionTranscriptSnapshot
        let summaryGate: ReviewReadGate
        let refresh: Task<Void, Never>
    }

    private func prepareRowRecovery() async throws -> RowRecovery {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let readGate = ReviewReadGate(), readTask = Task { await readGate.wait() }
        let selectionGate = ReviewReadGate(), selectionTask = Task { await selectionGate.wait() }
        let summaryGate = ReviewReadGate(), summaryTask = Task { await summaryGate.wait() }
        addTeardownBlock {
            readTask.cancel(); selectionTask.cancel(); summaryTask.cancel()
            await readGate.open(); await selectionGate.open(); await summaryGate.open()
        }
        f.model.selectionTranscriptReadGateForTesting = readTask
        f.model.selectionTranscriptGateForTesting = selectionTask
        f.model.openSession(session)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        await f.model.refreshSummariesForTesting()
        XCTAssertFalse(f.model.messages.isEmpty, "a summary publishes before the pending selection reads")
        let knownSession = try XCTUnwrap(f.model.selectedSession)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let original = try String(contentsOf: file, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        await readGate.open()
        try await wait { f.model.selectionTranscriptWaitingForTesting }
        // Recreating this sole source resets its generation and reuses session IDs.
        try Data(original.replacingOccurrences(of: "NavigationNeedle", with: "RecoveredNavigationNeedle with new locators").utf8)
            .write(to: file, options: .atomic)
        await f.coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let snapshot = try await f.database.transcriptSnapshot(sessionID: session.id)
        XCTAssertEqual(snapshot.session?.id, knownSession.id)
        XCTAssertEqual(snapshot.session?.sourceGeneration, knownSession.sourceGeneration)
        let omitted = try await f.database.transcriptSnapshot(sessionID: session.id,
            knownSession: f.model.selectedSession, knownMessageCount: f.model.messages.count)
        XCTAssertNil(omitted.messages, "the newer summary must actually exercise omitted rows")
        f.model.summaryTranscriptGateForTesting = summaryTask
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        addTeardownBlock { await summaryGate.open(); await refresh.value }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        await selectionGate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        XCTAssertNil(f.model.selectedSession)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        return .init(fixture: f, snapshot: snapshot, summaryGate: summaryGate, refresh: refresh)
    }

    private func assertRecovered(_ recovery: RowRecovery, file: StaticString = #filePath, line: UInt = #line) async throws {
        let model = recovery.fixture.model
        XCTAssertEqual(model.selectedSessionID, recovery.snapshot.session?.id, file: file, line: line)
        XCTAssertEqual(model.selectedSession?.sourceGeneration, recovery.snapshot.session?.sourceGeneration, file: file, line: line)
        XCTAssertEqual(model.messages.map(\.locator), recovery.snapshot.messages?.map(\.locator), file: file, line: line)
        let message = try XCTUnwrap(model.messages.first, file: file, line: line)
        model.hydrate(message)
        try await wait { model.hydratedMessages[message.id] != nil }
        XCTAssertTrue(try XCTUnwrap(model.hydratedMessages[message.id]).sections.prose.contains("RecoveredNavigationNeedle"),
                      file: file, line: line)
    }

    func testNilRowsSummaryRecoversAfterOlderMissingSelectionPublishes() async throws {
        let recovery = try await prepareRowRecovery()
        await recovery.summaryGate.open()
        await recovery.refresh.value
        try await assertRecovered(recovery)
    }

    func testFailedCompleteRowRecoveryExhaustsOneEpisodeAndManualRetryRecovers() async throws {
        let recovery = try await prepareRowRecovery(), f = recovery.fixture
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryReadGateForTesting = held
        await recovery.summaryGate.open()
        try await wait { f.model.transcriptRecoveryReadWaitingForTesting }
        await f.database.failTranscriptReadsForTesting(count: 4)
        f.model.transcriptRecoveryReadGateForTesting = nil
        await gate.open(); await recovery.refresh.value
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1), .seconds(4)].enumerated() {
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
        }
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertNotNil(f.model.transcriptLoadError)
        XCTAssertEqual(f.model.selectedSessionID, recovery.snapshot.session?.id)
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        let exhausted = await f.database.transcriptReadCountForTesting()
        await f.clock.advance(by: .seconds(60))
        let after = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, exhausted)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { !f.model.messages.isEmpty }
        XCTAssertNil(f.model.transcriptLoadError)
        try await assertRecovered(recovery)
    }

    func testFailedRowRecoveryRetainsSelectionAndRetriesAutomatically() async throws {
        let recovery = try await prepareRowRecovery()
        let f = recovery.fixture
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryReadGateForTesting = task
        await recovery.summaryGate.open()
        try await wait { f.model.transcriptRecoveryReadWaitingForTesting }
        await f.database.failTranscriptReadOnceForTesting()
        await gate.open()
        await recovery.refresh.value
        XCTAssertEqual(f.model.selectedSessionID, recovery.snapshot.session?.id)
        XCTAssertNotNil(f.model.sidebarRevealRequest)
        XCTAssertTrue(f.model.messages.isEmpty)
        f.model.transcriptRecoveryReadGateForTesting = nil
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        await f.clock.advance(by: .milliseconds(250))
        try await wait { !f.model.messages.isEmpty }
        try await assertRecovered(recovery)
    }

    func testSelectionChangeDiscardsPendingRowRecovery() async throws {
        let recovery = try await prepareRowRecovery()
        let f = recovery.fixture
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryPublicationGateForTesting = task
        await recovery.summaryGate.open()
        try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
        let other = try XCTUnwrap(f.model.sessions.first { $0.id != recovery.snapshot.session?.id })
        f.model.selectionTranscriptReadGateForTesting = nil
        f.model.selectionTranscriptGateForTesting = nil
        f.model.selectSession(other.id)
        try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
        let rows = f.model.messages
        await gate.open()
        await recovery.refresh.value
        XCTAssertEqual(f.model.selectedSessionID, other.id)
        XCTAssertEqual(f.model.selectedSession?.id, other.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
    }

    func testDatabaseChangeDiscardsPendingRowRecovery() async throws {
        let recovery = try await prepareRowRecovery()
        let f = recovery.fixture, replacement = try await fixture(count: 3)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryPublicationGateForTesting = task
        await recovery.summaryGate.open()
        try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
        await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertNil(f.model.selectedSessionID)
        f.model.selectionTranscriptReadGateForTesting = nil
        f.model.selectionTranscriptGateForTesting = nil
        await f.model.refreshSummariesForTesting()
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { f.model.selectedSession?.sourcePath == session.sourcePath && !f.model.messages.isEmpty }
        let rows = f.model.messages
        await gate.open()
        await recovery.refresh.value
        XCTAssertEqual(f.model.selectedSession?.sourcePath, replacement.root.appendingPathComponent("sessions.jsonl").path)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
    }

    func testInitialDatabaseInstallationPreservesSavedSessionRestoration() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.settings.lastSessionID = session.id
        let model = TraceModel(settings: f.model.settings, clock: f.clock,
                               diagnosticsURL: f.root.appendingPathComponent("restoration-diagnostics.json"))
        addTeardownBlock { @MainActor in await model.prepareToTerminate() }
        await model.attach(database: f.database, coordinator: f.coordinator)
        XCTAssertEqual(model.settings.lastSessionID, session.id)
        await model.refreshSummariesForTesting(lightweight: false)
        try await wait { model.selectedSessionID == session.id && !model.messages.isEmpty }
        XCTAssertEqual(model.selectedSession?.sourcePath, session.sourcePath)
    }

    func testSameDatabaseAttachmentPreservesTranscriptHydrationAndBookmark() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty }
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        let token = f.model.sidebarRevealRequest?.token
        let rows = f.model.messages
        f.model.scrollPositions[session.id] = .init(messageID: message.id, offset: 42, index: 0)
        await f.model.attach(database: f.database, coordinator: f.coordinator)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertNotNil(f.model.hydratedMessages[message.id])
        XCTAssertEqual(f.model.scrollPositions[session.id]?.offset, 42)
        XCTAssertEqual(f.model.sidebarRevealRequest?.token, token)
        await f.model.refreshSummariesForTesting()
        XCTAssertNotNil(f.model.hydratedMessages[message.id], "same-instance refresh retains usable hydration")
    }

    func testDatabaseReplacementClearsOldStateAndAcceptsFreshReadRevision() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 2)
        try await search(f, expectedCount: 6)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.openSession(session)
        try await wait { !f.model.messages.isEmpty }
        let message = try XCTUnwrap(f.model.messages.first)
        f.model.hydrate(message)
        try await wait { f.model.hydratedMessages[message.id] != nil }
        f.model.scrollPositions[session.id] = .init(messageID: message.id, offset: 42, index: 0)
        f.model.expandedReasoningIDs.insert(message.id)
        for _ in 0..<3 { await f.model.refreshSummariesForTesting() }
        let current = try await replacement.database.transcriptSnapshot(sessionID: session.id)
        XCTAssertEqual(current.session?.id, session.id, "exercise overlapping IDs in independent databases")
        await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertNil(f.model.selectedSession)
        XCTAssertNil(f.model.settings.lastSessionID)
        XCTAssertNil(f.model.sidebarRevealRequest)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertTrue(f.model.hydratedMessages.isEmpty)
        XCTAssertTrue(f.model.scrollPositions.isEmpty)
        XCTAssertTrue(f.model.expandedReasoningIDs.isEmpty)
        XCTAssertTrue(f.model.projects.isEmpty)
        XCTAssertTrue(f.model.sessions.isEmpty)
        XCTAssertTrue(f.model.mainSearch.results.isEmpty)
        await f.model.refreshSummariesForTesting()
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        XCTAssertEqual(f.model.selectedSession?.sourcePath, current.session?.sourcePath)
        XCTAssertEqual(f.model.messages.map(\.locator), current.messages?.map(\.locator))
    }

    func testDatabaseReplacementRejectsPendingHydrationWithIdenticalMessageIdentity() async throws {
        let f = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let message = try XCTUnwrap(f.model.messages.first)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.hydrationPublicationGateForTesting = task
        f.model.hydrate(message)
        try await wait { f.model.hydrationPublicationWaitingForTesting }
        let reopened = try IndexDatabase(url: f.root.appendingPathComponent("index.sqlite"))
        await f.model.attachForTesting(database: reopened, sources: [ClaudeCodeSource(roots: [f.root])])
        await gate.open()
        try await wait { !f.model.hydrationPublicationWaitingForTesting }
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertTrue(f.model.hydratedMessages.isEmpty, "an old producer cannot repopulate identical message IDs")
        await f.model.refreshSummariesForTesting()
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        f.model.hydrate(try XCTUnwrap(f.model.messages.first))
        try await wait { f.model.hydratedMessages[message.id] != nil }
    }

    func testDatabaseReplacementRejectsDelayedSelectionTranscript() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 2)
        let session = try XCTUnwrap(f.model.sessions.first)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.selectionTranscriptGateForTesting = task
        f.model.openSession(session)
        try await wait { f.model.selectionTranscriptWaitingForTesting }
        await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertNil(f.model.selectedSessionID)
        f.model.selectionTranscriptGateForTesting = nil
        await f.model.refreshSummariesForTesting()
        let current = try XCTUnwrap(f.model.sessions.first { $0.id == session.id })
        f.model.selectSession(current.id)
        try await wait { !f.model.messages.isEmpty }
        let rows = f.model.messages
        await gate.open()
        try await wait { !f.model.selectionTranscriptWaitingForTesting }
        XCTAssertEqual(f.model.selectedSession?.sourcePath, current.sourcePath)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
    }

    func testDatabaseReplacementRejectsDelayedSidebarSnapshot() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        await f.database.gateSidebarSnapshotPublicationForTesting(task)
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { await f.database.sidebarSnapshotWaitingForTesting }
        let reopened = try IndexDatabase(url: f.root.appendingPathComponent("index.sqlite"))
        await f.model.attachForTesting(database: reopened, sources: [ClaudeCodeSource(roots: [f.root])])
        await gate.open()
        await refresh.value
        XCTAssertTrue(f.model.projects.isEmpty)
        XCTAssertTrue(f.model.sessions.isEmpty)
        XCTAssertTrue(f.model.recentSessions.isEmpty)
    }

    func testDatabaseReplacementRejectsDelayedSummaryTail() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), task = Task { await gate.wait() }
        defer { task.cancel(); Task { await gate.open() } }
        f.model.summaryTailGateForTesting = task
        let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summaryTailWaitingForTesting }
        let reopened = try IndexDatabase(url: f.root.appendingPathComponent("index.sqlite"))
        await f.model.attachForTesting(database: reopened, sources: [ClaudeCodeSource(roots: [f.root])])
        await gate.open()
        await refresh.value
        XCTAssertTrue(f.model.sourceHealth.isEmpty)
        XCTAssertNil(f.model.statistics)
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
        try await wait { !f.model.messages.isEmpty }
        for terminal in [false, true] {
            let gate = ReviewReadGate(), task = Task { await gate.wait() }
            defer { task.cancel(); Task { await gate.open() } }
            try await f.database.deleteSource(agent: .claudeCode, path: f.root.appendingPathComponent("sessions.jsonl").path)
            let empty = try await f.database.sidebarSnapshot(projectCanonicalKey: f.project.canonicalKey)
            XCTAssertTrue(empty.projects.isEmpty)
            XCTAssertTrue(empty.sessionList.sessions.isEmpty)
            await f.database.gateSidebarSnapshotPublicationForTesting(task)
            let refresh = Task { await f.model.refreshSummariesForTesting(terminalProjectReconciliation: terminal) }
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

@MainActor
private final class ReviewSelectionEvents {
    var windows = 0
    var scrolls = 0
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
