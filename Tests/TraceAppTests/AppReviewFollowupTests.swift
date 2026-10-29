import AppKit
import Clocks
import Combine
import CustomDump
import GRDB
import os
import SwiftUI
import XCTest
@testable import TraceCore

#if DEBUG
@MainActor
final class AppReviewFollowupTests: XCTestCase {
    private final class WeakModelReference { weak var value: TraceModel? }
    private final class WeakSchedulerReference { weak var value: IndexScheduler? }

    func testFailedAttachmentDoesNotReportCommittedRebuildAsCancelled() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let delivery = ReviewReadGate(), held = Task { await delivery.wait() }
        defer { held.cancel(); Task { await delivery.open() } }
        f.model.rebuildResetDeliveryGateForTesting = held
        f.model.rebuildAcknowledgmentGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildResetDeliveryWaitingForTesting && f.model.rebuildAcknowledgmentWaitingForTesting }
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.sourceReloadRecovery.error != nil }
        let error = try XCTUnwrap(f.model.sourceReloadRecovery.error)
        XCTAssertFalse(error.contains("queued index rebuild was cancelled"),
            "a reset committed before replacement cannot be reported as unfulfilled intent cancelled by failure")
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets, 1)
        await delivery.open()
        try await wait { !f.model.rebuildResetDeliveryWaitingForTesting && !f.model.rebuildAcknowledgmentWaitingForTesting }
        XCTAssertEqual(f.model.sourceReloadRecovery.error, error)
    }

    func testDelayedResetCallbackCannotConsumeNewerManualRequest() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let delivery = ReviewReadGate(), delivered = Task { await delivery.wait() }
        let oldTail = ReviewReadGate(), tail = Task { await oldTail.wait() }
        let preparation = ReviewReadGate(), prepared = Task { await preparation.wait() }
        defer { delivered.cancel(); tail.cancel(); prepared.cancel()
            Task { await delivery.open(); await oldTail.open(); await preparation.open() } }
        f.model.rebuildResetDeliveryGateForTesting = delivered
        await coordinator.gatePostResetForTesting(tail)
        f.model.rebuildIndex()
        let old = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        try await wait { f.model.rebuildResetDeliveryWaitingForTesting }
        await coordinator.gatePreparationForTesting(prepared)
        f.model.rebuildIndex()
        let newer = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        XCTAssertNotEqual(newer, old)
        await oldTail.open()
        try await wait { await coordinator.preparationWaitingForTesting }
        try await wait { f.model.rebuildAcceptedForTesting }
        await delivery.open()
        try await wait { !f.model.rebuildResetDeliveryWaitingForTesting }
        XCTAssertEqual(f.model.rebuildRequestIDForTesting, newer)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        XCTAssertTrue(f.model.isPreparingRebuild)
        await preparation.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets, 2)
    }

    func testReplacementInspectsCommittedReceiptBeforeDelayedCallback() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let delivery = ReviewReadGate(), delivered = Task { await delivery.wait() }
        defer { delivered.cancel(); Task { await delivery.open() } }
        f.model.rebuildResetDeliveryGateForTesting = delivered
        f.model.rebuildAcknowledgmentGateForTesting = delivered
        f.model.rebuildIndex()
        try await wait { f.model.rebuildResetDeliveryWaitingForTesting && f.model.rebuildAcknowledgmentWaitingForTesting }
        XCTAssertTrue(f.model.pendingRebuildForTesting, "hold both acknowledgment and callback delivery until replacement inspects commitment")
        f.model.reloadSourcesAndRebuild()
        try await wait { !f.model.watcherStartupPendingForTesting && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets, 1)
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.rebuild, false)
        await delivery.open()
        try await wait { !f.model.rebuildResetDeliveryWaitingForTesting }
        XCTAssertFalse(f.model.pendingRebuildForTesting)
    }

    func testFailedResetResumesStartupAndRecoversOnOneLaterEvent() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        await f.database.setResetFaultForTesting(.rollback)
        f.model.rebuildIndex()
        let request = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        try await wait { f.model.progress.phase == .failed && f.model.rebuildAcceptedForTesting }
        let firstPass = f.model.progress.passID
        f.model.startReadyStartupForTesting(sources: [source])
        f.model.startReadyStartupForTesting(sources: [source])
        XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting()).isEmpty)
        await f.database.setResetFaultForTesting(.rollback)
        await f.clock.advance(by: .seconds(5))
        try await wait { f.model.isRebuildPendingRecovery && !f.model.watcherStartupPendingForTesting
            && f.model.safetyVerificationActiveForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertNotEqual(f.model.progress.passID, firstPass)
        XCTAssertFalse(f.model.isPreparingRebuild)
        XCTAssertEqual(f.model.rebuildRequestIDForTesting, request)
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertFalse(try XCTUnwrap(raw.first).rebuild)
        var watermarks = SourceChanges(); watermarks.watermarks = ["watermark-only": 5]
        XCTAssertFalse(f.model.recoverDeferredRebuildForTesting(watermarks))
        await f.model.bufferSourceChangesForTesting(watermarks)
        var irrelevant = SourceChanges()
        irrelevant.paths = [f.root.appendingPathComponent("index.sqlite-wal").path, f.root.appendingPathComponent("diagnostics.json").path]
        XCTAssertFalse(f.model.recoverDeferredRebuildForTesting(irrelevant), "Trace's own writes cannot admit a reset")
        var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        await f.model.bufferSourceChangesForTesting(changes)
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertTrue(f.model.isRebuildPendingRecovery, "buffered/replayed input cannot admit reset recovery")
        let before = await f.database.committedResetCountForTesting
        XCTAssertEqual(before, 0)
        let beforeRecoveryPass = f.model.progress.passID
        await f.database.setResetFaultForTesting(.rollback)
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { f.model.progress.passID != beforeRecoveryPass
            && f.model.isRebuildPendingRecovery && !f.model.rebuildClaimedForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let failedAttempts = await f.database.resetAttemptCountForTesting
        await f.clock.advance(by: .seconds(5))
        await f.model.schedulerForTesting?.waitUntilIdle()
        let afterDelay = await f.database.resetAttemptCountForTesting
        XCTAssertEqual(afterDelay, failedAttempts, "ordinary live passes may run, but reset recovery cannot get a timer retry")
        XCTAssertEqual(f.model.rebuildRequestIDForTesting, request)
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes, safety: true))
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertFalse(f.model.isRebuildPendingRecovery)
        let after = await f.database.committedResetCountForTesting
        XCTAssertEqual(after, 1)
    }

    private func deferredResetFixture(count: Int = 3) async throws -> Fixture {
        let f = try await fixture(count: count)
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.suppressLiveWatcherIngressForTesting = true
        await f.database.setResetFaultForTesting(.rollback)
        f.model.rebuildIndex()
        try await wait { f.model.progress.phase == .failed && f.model.rebuildAcceptedForTesting }
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        await f.model.schedulerForTesting?.waitUntilIdle()
        await f.database.setResetFaultForTesting(.rollback)
        await f.clock.advance(by: .seconds(5))
        try await wait { f.model.isRebuildPendingRecovery && !f.model.watcherStartupPendingForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        await f.model.refreshSummariesForTesting(lightweight: false)
        return f
    }

    func testAutomaticResetFailurePreservesNavigationAndRunsLiveWork() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        try await search(f, expectedCount: 3)
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        let anchor = SearchResultAnchor(id: result.id, offset: 37, oldOrder: f.model.mainSearch.results.map(\.id))
        f.model.openSearchResult(result, fromMainSearch: true, anchor: anchor)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let id = try XCTUnwrap(f.model.selectedSessionID), message = try XCTUnwrap(f.model.messages.first)
        f.model.scrollPositions[id] = .init(messageID: message.id, offset: 29, index: 0)
        let title = f.model.selectedSession?.title, query = f.model.mainSearch.query
        let project = f.model.selectedProjectCanonicalKey
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await f.model.coordinatorForTesting?.gatePreparationForTesting(held)
        await f.database.setResetFaultForTesting(.rollback)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: line(99)); try handle.close()
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { await f.model.coordinatorForTesting?.preparationWaitingForTesting == true }
        XCTAssertEqual(f.model.selectedSessionID, id); XCTAssertEqual(f.model.selectedSession?.title, title)
        XCTAssertEqual(f.model.settings.lastSessionID, id); XCTAssertEqual(f.model.scrollPositions[id]?.offset, 29)
        XCTAssertEqual(f.model.mainSearch.query, query); XCTAssertTrue(f.model.hasSearchReturnContext)
        await gate.open()
        try await wait { f.model.isRebuildPendingRecovery && !f.model.rebuildClaimedForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let rows = try await f.database.sessions(limit: 50)
        XCTAssertTrue(rows.contains { $0.title.contains("99") }, "the triggering ordinary update must run despite reset failure")
        XCTAssertEqual(f.model.selectedSessionID, id); XCTAssertEqual(f.model.settings.lastSessionID, id)
        XCTAssertEqual(f.model.selectedProjectCanonicalKey, project)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.offset, 37)
        XCTAssertEqual(f.model.scrollPositions[id]?.offset, 29)
        try await wait { f.model.retainedRebuildPathCountForTesting == 0 }
    }

    func testAutomaticResetRestoresSourceSessionWhenRowsAreReused() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let selected = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(selected.id)
        try await wait { f.model.selectedSession != nil && !f.model.messages.isEmpty }
        let original = try XCTUnwrap(f.model.messages.first)
        f.model.scrollPositions[selected.id] = .init(messageID: original.id, offset: 23, index: 0)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let data = try String(contentsOf: file, encoding: .utf8)
        try Data((data.split(separator: "\n").reversed().joined(separator: "\n") + "\n").utf8).write(to: file)
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete
            && f.model.selectedSession?.title == selected.title && !f.model.isLoadingSessions }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let id = try XCTUnwrap(f.model.selectedSessionID)
        XCTAssertNotEqual(id, selected.id, "reversing insertion order must exercise identity rather than row-ID restoration")
        XCTAssertEqual(f.model.selectedSession?.sourcePath, selected.sourcePath)
        XCTAssertEqual(f.model.messages.first?.prefix, original.prefix)
        XCTAssertEqual(f.model.settings.lastSessionID, id)
        XCTAssertEqual(f.model.scrollPositions[id]?.offset, 23)
        XCTAssertEqual(f.model.scrollPositions[id]?.messageID, f.model.messages.first?.id)
        XCTAssertTrue(f.model.sessions.contains { $0.id == id })
    }

    func testAutomaticAbsenceWaitsForScanCoverageAfterCommittedCheckpointFailure() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id); try await wait { !f.model.messages.isEmpty }
        await f.database.setResetFaultForTesting(.checkpoint)
        var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .failed }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let unrelated = f.root.appendingPathComponent("unrelated.jsonl")
        try line(99).write(to: unrelated)
        await f.model.schedulerForTesting?.request(paths: [unrelated.path], activity: .fileChanges)
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertEqual(f.model.selectedSessionID, session.id,
            "an unrelated successful path pass cannot confirm absence before the reset's scan runs")
        XCTAssertEqual(f.model.selectedSession?.title, session.title)
        XCTAssertNotNil(f.model.settings.pendingNavigationReference)
        await f.clock.advance(by: .seconds(5))
        try await wait { f.model.settings.pendingNavigationReference == nil && f.model.selectedSession?.title == session.title }
        XCTAssertEqual(f.model.messages.first?.prefix, session.title)
    }

    func testAutomaticResetClearsOnlyAuthoritativelyMissingSelection() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        let session = try XCTUnwrap(f.model.sessions.first { $0.title == "NavigationNeedle 0" })
        f.model.selectSession(session.id); try await wait { !f.model.messages.isEmpty }
        var remaining = Data()
        for index in 1..<7 { remaining.append(try line(index, project: index < 3 ? "NavigationReview" : "OtherReview")) }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        try remaining.write(to: file)
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.pendingRebuildForTesting && f.model.selectedSessionID == nil }
        XCTAssertNil(f.model.settings.lastSessionID)
        XCTAssertNil(f.model.settings.pendingNavigationReference)
        XCTAssertTrue(f.model.messages.isEmpty)
    }

    func testUnclaimedRecoveryOnboardingExitReleasesAdmission() async throws {
        for grouped in [false, true] {
            let f = try await deferredResetFixture()
            var deferred = false
            let observe = {
                guard f.model.isPreparingRebuild, !deferred else { return }
                deferred = true; f.model.settings.onboardingComplete = false
            }
            let subscription = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                : f.model.objectWillChange.sink { observe() }
            defer { subscription.cancel() }
            var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
            XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
            try await wait { deferred && !f.model.isPreparingRebuild && f.model.rebuildAdmissionIDForTesting == nil }
            XCTAssertTrue(f.model.pendingRebuildForTesting)
            await f.model.schedulerForTesting?.waitUntilIdle()
            f.model.settings.onboardingComplete = true
            f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
            try await wait { !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting }
        }
    }

    func testSafetyRecoveryWaitsForItsActualDelivery() async throws {
        let f = try await deferredResetFixture()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.rebuildSubmissionGateForTesting = held
        var delivered: Bool?
        let recovery = Task { delivered = await f.model.admitSafetyRecoveryForTesting() }
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertNil(delivered, "idle before submission must not settle the recovery enrollment")
        await gate.open(); await recovery.value
        XCTAssertEqual(delivered, true)
        await f.model.schedulerForTesting?.waitUntilIdle()
        let safety = try await f.database.lastSafetyReconciliationMilliseconds()
        XCTAssertNotNil(safety)
    }

    func testNavigationDuringAutomaticCaptureCancelsUnsentReset() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let first = try XCTUnwrap(f.model.sessions.first), second = try XCTUnwrap(f.model.sessions.last)
        f.model.selectSession(first.id)
        try await wait { !f.model.messages.isEmpty }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.automaticNavigationCaptureGateForTesting = held
        let before = await f.database.resetAttemptCountForTesting
        var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { f.model.automaticNavigationCaptureWaitingForTesting }
        f.model.selectSession(second.id)
        try await wait { f.model.selectedSession?.id == second.id }
        await gate.open()
        try await wait { !f.model.automaticNavigationCaptureWaitingForTesting && !f.model.isPreparingRebuild }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let after = await f.database.resetAttemptCountForTesting
        XCTAssertEqual(after, before)
        XCTAssertEqual(f.model.selectedSessionID, second.id)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
    }

    func testAutomaticCaptureFailureKeepsOrdinaryInputsAndCachedNavigation() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id); try await wait { !f.model.messages.isEmpty }
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: line(99)); try handle.close()
        await f.database.failNavigationCaptureOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY,
            message: "private-navigation-sentinel", sql: "SELECT private_navigation_sql", arguments: ["private-argument"]))
        let before = await f.database.resetAttemptCountForTesting
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.rebuildClaimedForTesting && !f.model.isPreparingRebuild }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let rows = try await f.database.sessions(limit: 50), after = await f.database.resetAttemptCountForTesting
        XCTAssertTrue(rows.contains { $0.title.contains("99") }); XCTAssertEqual(before, after)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        XCTAssertFalse(f.model.transcriptBanner?.details.contains("private-") == true)
    }

    func testNavigationDuringAutomaticRestorationRejectsOlderContinuation() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id); try await wait { !f.model.messages.isEmpty }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.automaticNavigationRestoreGateForTesting = held
        var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { f.model.automaticNavigationRestoreWaitingForTesting }
        let rows = try await f.database.sessions(limit: 50)
        let other = try XCTUnwrap(rows.first { $0.title != session.title })
        f.model.selectSession(other.id)
        try await wait { f.model.selectedSession?.id == other.id }
        await gate.open()
        try await wait { !f.model.automaticNavigationRestoreWaitingForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertEqual(f.model.selectedSessionID, other.id)
        XCTAssertEqual(f.model.settings.lastSessionID, other.id)
        XCTAssertNil(f.model.settings.pendingNavigationReference)
    }

    func testAutomaticRestorationFailureWaitsForDistinctFullRefresh() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id); try await wait { !f.model.messages.isEmpty }
        await f.database.failNavigationResolutionOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY,
            message: "private-resolution-sentinel", sql: "SELECT private_sql", arguments: ["private-argument"]))
        var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.pendingRebuildForTesting && f.model.transcriptBanner?.feedback == .readError }
        await f.model.schedulerForTesting?.waitUntilIdle()
        XCTAssertNotNil(f.model.settings.pendingNavigationReference, "the same terminal summary tail cannot retry the failed resolution")
        XCTAssertFalse(f.model.transcriptBanner?.details.contains("private-") == true)
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.settings.pendingNavigationReference == nil && f.model.transcriptBanner == nil }
        XCTAssertEqual(f.model.selectedSession?.title, session.title)
    }

    func testTerminatedRestorationPersistsSourceIdentityAcrossRowReuse() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        let session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id); try await wait { !f.model.messages.isEmpty }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.automaticNavigationRestoreGateForTesting = held
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let data = try String(contentsOf: file, encoding: .utf8)
        try Data((data.split(separator: "\n").reversed().joined(separator: "\n") + "\n").utf8).write(to: file)
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { f.model.automaticNavigationRestoreWaitingForTesting }
        let stopping = Task { await f.model.prepareToTerminate() }
        try await wait { f.model.terminationStartedForTesting }
        await gate.open(); await stopping.value
        XCTAssertNotNil(f.model.settings.pendingNavigationReference)
        let restarted = TraceModel(settings: f.model.settings, clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("restart-diagnostics.json"))
        await restarted.attachForTesting(database: f.database, sources: [ClaudeCodeSource(roots: [f.root])])
        await restarted.refreshSummariesForTesting(lightweight: false)
        try await wait { restarted.selectedSession?.title == session.title }
        XCTAssertNotEqual(restarted.selectedSessionID, session.id)
        XCTAssertNil(restarted.settings.pendingNavigationReference)
        await restarted.prepareToTerminate()
    }

    func testAutomaticCommitRemapsSearchReturnAnchorAndKeepsCriteria() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        try await search(f, expectedCount: 3)
        let result = try XCTUnwrap(f.model.mainSearch.results.first)
        let anchor = SearchResultAnchor(id: result.id, offset: 41, oldOrder: f.model.mainSearch.results.map(\.id))
        f.model.openSearchResult(result, fromMainSearch: true, anchor: anchor)
        try await wait { !f.model.messages.isEmpty && !f.model.isLoadingSessions }
        let originalTitle = f.model.selectedSession?.title
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let data = try String(contentsOf: file, encoding: .utf8)
        try Data((data.split(separator: "\n").reversed().joined(separator: "\n") + "\n").utf8).write(to: file)
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.pendingRebuildForTesting && f.model.selectedSession?.title == originalTitle
            && f.model.selectedSessionID != result.sessionID }
        XCTAssertTrue(f.model.hasSearchReturnContext)
        XCTAssertEqual(f.model.mainSearch.query, "NavigationNeedle")
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.offset, 41)
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.id, f.model.messages.first?.id)
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && f.model.mainSearch.results.count == 3 }
        XCTAssertTrue(f.model.mainSearch.results.contains { $0.id == f.model.mainSearchReturnAnchor?.id })
        f.model.returnFromSession()
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertEqual(f.model.mainSearch.query, "NavigationNeedle")
        XCTAssertEqual(f.model.mainSearchReturnAnchor?.offset, 41)
    }

    func testAutomaticCommitWithoutSelectionInvalidatesCursorAndRetainsDepth() async throws {
        let f = try await deferredResetFixture(count: 430)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 200 }
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        XCTAssertNotNil(f.model.sessionCursorIDForTesting)
        XCTAssertNil(f.model.selectedSessionID)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        await coordinator.gatePostResetForTesting(held)
        var changes = SourceChanges(); changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { await coordinator.postResetWaitingForTesting }
        try await wait { f.model.sessionCursorIDForTesting == nil }
        XCTAssertEqual(f.model.requestedPageDepthForTesting, 2)
        XCTAssertNil(f.model.selectedSessionID)
        await gate.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.sessions.count == 400 && !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.totalSessionCount, 430)
        XCTAssertTrue(f.model.hasMoreSessions)
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 2)
    }

    func testAutomaticCommitRemapsInactiveSessionBookmarksBySourceIdentity() async throws {
        let f = try await deferredResetFixture()
        f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions }
        let first = try XCTUnwrap(f.model.sessions.first)
        let allRows = try await f.database.sessions(limit: 20)
        let second = try XCTUnwrap(allRows.first { $0.title == "NavigationNeedle 4" })
        f.model.selectSession(first.id); try await wait { !f.model.messages.isEmpty }
        let firstMessage = try XCTUnwrap(f.model.messages.first)
        f.model.scrollPositions[first.id] = .init(messageID: firstMessage.id, offset: 19, index: 0)
        f.model.selectSession(second.id); try await wait { f.model.selectedSession?.id == second.id && !f.model.messages.isEmpty }
        let secondMessage = try XCTUnwrap(f.model.messages.first)
        f.model.scrollPositions[second.id] = .init(messageID: secondMessage.id, offset: 31, index: 0)
        let file = f.root.appendingPathComponent("sessions.jsonl")
        let data = try String(contentsOf: file, encoding: .utf8)
        try Data((data.split(separator: "\n").reversed().joined(separator: "\n") + "\n").utf8).write(to: file)
        var changes = SourceChanges(); changes.paths = [file.path]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { !f.model.pendingRebuildForTesting && f.model.selectedSession?.title == second.title
            && f.model.selectedSessionID != second.id }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let rows = try await f.database.sessions(limit: 20)
        let restoredFirst = try XCTUnwrap(rows.first { $0.title == first.title })
        let restoredSecond = try XCTUnwrap(rows.first { $0.title == second.title })
        XCTAssertEqual(f.model.scrollPositions[restoredFirst.id]?.offset, 19)
        XCTAssertEqual(f.model.scrollPositions[restoredSecond.id]?.offset, 31)
        XCTAssertEqual(f.model.scrollPositions[restoredFirst.id]?.messageID, firstMessage.id)
        XCTAssertEqual(f.model.scrollPositions[restoredSecond.id]?.messageID, secondMessage.id)
    }

    func testPendingRebuildDoesNotHideUnrelatedFailureLabel() {
        var progress = IndexProgress(phase: .failed)
        progress.error = "Could not refresh session metadata."
        let label = IndexProgressLabel(progress: progress, rebuildPendingRecovery: true)
        XCTAssertEqual(label.textForTesting, progress.error)
        XCTAssertTrue(label.details.contains("The rebuild has not completed."))
        let idle = IndexProgressLabel(progress: .init(phase: .waiting), rebuildPendingRecovery: true)
        XCTAssertEqual(idle.textForTesting, "Rebuild pending")
    }

    func testPendingRebuildPresentationIsIdleAndSourceFailureTakesPrecedence() {
        let progress = IndexProgress(phase: .complete)
        let label = IndexProgressLabel(progress: progress, rebuildPendingRecovery: true)
        XCTAssertTrue(label.details.contains("The rebuild has not completed. Live updates continue."))
        let paused = IndexProgressLabel(progress: progress, sourceReloadRecovery: .failed("Source settings failed"),
            rebuildPendingRecovery: true)
        XCTAssertTrue(paused.details.contains("Live updates are paused."))
        XCTAssertTrue(paused.details.contains("The rebuild has not completed."))
    }

    func testDeferredEventsCoalesceBeforeAdmissionAndActiveEventsDoNotReplayReset() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        await f.database.setResetFaultForTesting(.rollback)
        f.model.rebuildIndex()
        try await wait { f.model.progress.phase == .failed && f.model.rebuildAcceptedForTesting }
        f.model.startReadyStartupForTesting(sources: [source])
        await f.database.setResetFaultForTesting(.rollback)
        await f.clock.advance(by: .seconds(5))
        try await wait { f.model.isRebuildPendingRecovery && !f.model.watcherStartupPendingForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await coordinator.gatePreparationForTesting(held)
        var first = SourceChanges()
        first.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        first.watermarks = ["coalesced-first": 41]; first.streamRoots = ["coalesced-first": [f.root.path]]
        var second = first
        second.watermarks = ["coalesced-second": 52]; second.streamRoots = ["coalesced-second": [f.root.path]]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(first))
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(second))
        try await wait { await coordinator.preparationWaitingForTesting }
        XCTAssertFalse(f.model.recoverDeferredRebuildForTesting(first), "an active attempt cannot enroll its successor")
        await gate.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let firstCheckpoint = try await f.database.eventCheckpoint(volumeID: "coalesced-first")
        let secondCheckpoint = try await f.database.eventCheckpoint(volumeID: "coalesced-second")
        XCTAssertEqual(firstCheckpoint, 41); XCTAssertEqual(secondCheckpoint, 52)
        let attempts = await f.database.resetAttemptCountForTesting
        XCTAssertEqual(attempts, 3, "two initial failures and one coalesced recovery")
        await f.clock.advance(by: .seconds(5))
        await f.model.schedulerForTesting?.waitUntilIdle()
        let after = await f.database.resetAttemptCountForTesting
        XCTAssertEqual(after, attempts)
    }

    func testEventRecoveryInputsSurviveAcknowledgedSchedulerReplacement() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        await f.database.setResetFaultForTesting(.rollback)
        f.model.rebuildIndex()
        let request = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        try await wait { f.model.progress.phase == .failed && f.model.rebuildAcceptedForTesting }
        f.model.startReadyStartupForTesting(sources: [source])
        await f.database.setResetFaultForTesting(.rollback)
        await f.clock.advance(by: .seconds(5))
        try await wait { f.model.isRebuildPendingRecovery && !f.model.watcherStartupPendingForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await coordinator.gatePreparationForTesting(held)
        var changes = SourceChanges()
        changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        changes.watermarks = ["retained-reset-volume": 42]
        changes.streamRoots = ["retained-reset-volume": [f.root.path]]
        XCTAssertTrue(f.model.recoverDeferredRebuildForTesting(changes))
        try await wait { await coordinator.preparationWaitingForTesting }
        try await wait { f.model.rebuildAcceptedForTesting && !f.model.rebuildClaimedForTesting }
        f.model.reloadSourcesAndRebuild()
        await gate.open()
        try await wait { !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting
            && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let receipts = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        let payload = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(payload.rebuild)
        XCTAssertEqual(payload.rebuildRequestID, request)
        XCTAssertTrue(payload.paths.contains(f.root.appendingPathComponent("sessions.jsonl").path))
        XCTAssertEqual(payload.watermarks["retained-reset-volume"], 42)
        XCTAssertEqual(payload.streamRoots["retained-reset-volume"], [f.root.path])
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets, 1)
    }

    func testDeferredRebuildDoesNotRetainReplacedScheduler() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        await f.database.setResetFaultForTesting(.rollback)
        f.model.rebuildIndex()
        try await wait { f.model.progress.phase == .failed && f.model.rebuildAcceptedForTesting }
        await f.database.setResetFaultForTesting(.rollback)
        await f.clock.advance(by: .seconds(5))
        try await wait { f.model.isRebuildPendingRecovery }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let retired = WeakSchedulerReference()
        retired.value = f.model.schedulerForTesting
        f.model.settings.onboardingComplete = false
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.schedulerForTesting != nil }
        try await wait { retired.value == nil }
        XCTAssertTrue(f.model.pendingRebuildForTesting)
    }

    func testDeferredPublicationReentryCannotDiscardNewManualRebuild() async throws {
        for grouped in [false, true] {
            let f = try await fixture(count: 2)
            f.model.settings.onboardingComplete = true
            await f.database.setResetFaultForTesting(.rollback)
            f.model.rebuildIndex()
            try await wait { f.model.progress.phase == .failed && f.model.rebuildAcceptedForTesting }
            let old = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            var replaced = false
            let observe = {
                guard f.model.isRebuildPendingRecovery, !replaced else { return }
                replaced = true
                f.model.rebuildSubmissionGateForTesting = held
                f.model.rebuildIndex()
            }
            let subscription = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                : f.model.objectWillChange.sink { observe() }
            defer { subscription.cancel() }
            await f.database.setResetFaultForTesting(.rollback)
            await f.clock.advance(by: .seconds(5))
            try await wait { replaced && f.model.rebuildRequestIDForTesting != old }
            let newer = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
            XCTAssertTrue(f.model.pendingRebuildForTesting)
            await gate.open()
            try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
            XCTAssertNotEqual(old, newer)
            let resets = await f.database.committedResetCountForTesting
            XCTAssertEqual(resets, 1)
        }
    }

    func testNonRebuildStartupCannotConsumeNextResetDeliveryGate() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let payload = ReviewReadGate(), payloadTask = Task { await payload.wait() }
        let explicit = ReviewReadGate(), explicitTask = Task { await explicit.wait() }
        let delivery = ReviewReadGate(), deliveryTask = Task { await delivery.wait() }
        defer { payloadTask.cancel(); explicitTask.cancel(); deliveryTask.cancel()
            Task { await payload.open(); await explicit.open(); await delivery.open() } }
        f.model.startupPayloadGateForTesting = payloadTask
        f.model.queueRebuildForTesting()
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.rebuildClaimedForTesting }
        f.model.rebuildClaimGateForTesting = explicitTask
        f.model.rebuildResetDeliveryGateForTesting = deliveryTask
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        await payload.open()
        try await wait { !f.model.watcherStartupPendingForTesting && f.model.startupHandoffIDForTesting == nil }
        XCTAssertNotNil(f.model.rebuildResetDeliveryGateForTesting,
            "an invalid startup claim's ordinary payload must not consume the successor's delivery gate")
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertFalse(try XCTUnwrap(raw.first).rebuild)
        await explicit.open()
        try await wait { f.model.rebuildResetDeliveryWaitingForTesting }
        await delivery.open()
        try await wait { !f.model.rebuildResetDeliveryWaitingForTesting && f.model.progress.phase == .complete }
    }

    func testAcknowledgedRebuildSurvivesReplacementBeforeReset() async throws {
        let f = try await fixture(count: 2)
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await coordinator.gatePreparationForTesting(held)
        f.model.settings.onboardingComplete = true
        f.model.rebuildIndex()
        try await wait { f.model.rebuildAcceptedForTesting && !f.model.rebuildClaimedForTesting }
        let request = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        XCTAssertTrue(f.model.isPreparingRebuild)
        let before = await f.database.committedResetCountForTesting
        f.model.reloadSourcesAndRebuild()
        await gate.open()
        try await wait { !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting
            && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets - before, 1)
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.rebuildRequestID, request)
        XCTAssertEqual(raw.first?.rebuild, true)
    }

    func testCommittedResetSurvivesSuppressedProgressAndReplacement() async throws {
        let f = try await fixture(count: 2)
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await coordinator.gatePostResetForTesting(held)
        f.model.settings.onboardingComplete = true
        let before = await f.database.committedResetCountForTesting
        f.model.rebuildIndex()
        try await wait { await coordinator.postResetWaitingForTesting }
        try await wait { !f.model.pendingRebuildForTesting }
        f.model.reloadSourcesAndRebuild()
        await gate.open()
        try await wait { !f.model.watcherStartupPendingForTesting && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets - before, 1, "committed reset cannot be repeated because progress was suppressed")
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.rebuild, false)
    }

    func testReadyStartupCombinesWithReservedCurrentSchedulerClaim() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.rebuildSubmissionGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let request = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        var changes = SourceChanges()
        changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        changes.reconciliationPaths = [f.root.path]
        changes.watermarks = ["combined-owner": 90]
        changes.streamRoots = ["combined-owner": [f.root.path]]
        f.model.queueStartupWorkForTesting(changes)
        f.model.startReadyStartupForTesting(sources: [source])
        XCTAssertNil(f.model.startupHandoffIDForTesting)
        XCTAssertNotNil(f.model.pendingStartupHandoffIDForTesting)
        await gate.open()
        try await wait { !f.model.watcherStartupPendingForTesting && !f.model.pendingRebuildForTesting
            && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.rebuildRequestID, request)
        XCTAssertEqual(raw.first?.rebuild, true)
        XCTAssertEqual(raw.first?.watermarks["combined-owner"], 90)
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets, 1)
    }

    func testReadyStartupAfterDeliveryRetainsUnsubmittedInputs() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await coordinator.gatePreparationForTesting(held)
        f.model.rebuildIndex()
        try await wait { f.model.rebuildAcceptedForTesting }
        let path = f.root.appendingPathComponent("after-delivery.jsonl")
        try line(997).write(to: path)
        var changes = SourceChanges(); changes.paths = [path.path]
        changes.watermarks = ["after-delivery": 92]
        changes.streamRoots = ["after-delivery": [f.root.path]]
        f.model.queueStartupWorkForTesting(changes)
        f.model.startReadyStartupForTesting(sources: [source])
        XCTAssertNotNil(f.model.pendingStartupHandoffIDForTesting)
        XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting()).isEmpty)
        await gate.open()
        try await wait { !f.model.watcherStartupPendingForTesting && f.model.progress.phase == .complete }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.rebuild, false)
        XCTAssertEqual(raw.first?.paths, [path.path])
        XCTAssertEqual(raw.first?.watermarks["after-delivery"], 92)
        let resets = await f.database.committedResetCountForTesting
        XCTAssertEqual(resets, 1)
    }

    func testRepeatedWatcherRestartsCreateDistinctReadyOwners() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { !f.model.watcherStartupPendingForTesting }
        var generation = f.model.watcherGenerationForTesting
        var attempts = Set<UUID>()
        for _ in 0..<2 {
            let invocation = f.model.restartStartupWatchersForUITesting()
            try await wait { f.model.watcherRestartOutcomesForTesting.contains { $0.invocation == invocation }
                && !f.model.watcherStartupPendingForTesting }
            let outcome = try XCTUnwrap(f.model.watcherRestartOutcomesForTesting.first { $0.invocation == invocation })
            XCTAssertEqual(outcome.phase, .started)
            let next = try XCTUnwrap(outcome.watcherGeneration)
            XCTAssertGreaterThan(next, generation)
            generation = next
            XCTAssertTrue(attempts.insert(try XCTUnwrap(outcome.watcherAttempt)).inserted)
        }
        await f.model.schedulerForTesting?.waitUntilIdle()
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual(Set(raw.map(\.watcherAttempt)).count, 3)
    }

    func testWatcherRestartReportsDeferredSupersededAndEarlyAbortOwners() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = false
        let deferred = f.model.restartStartupWatchersForUITesting()
        try await wait { f.model.watcherRestartOutcomesForTesting.contains { $0.invocation == deferred } }
        XCTAssertEqual(f.model.watcherRestartOutcomesForTesting.first?.phase, .deferred)
        f.model.settings.onboardingComplete = true
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.watcherOutcomeGateForTesting = held
        let superseded = f.model.restartStartupWatchersForUITesting()
        try await wait { f.model.watcherOutcomeWaitingForTesting }
        f.model.reloadSourcesAndRebuild()
        await gate.open()
        try await wait { f.model.watcherRestartOutcomesForTesting.contains { $0.invocation == superseded } }
        XCTAssertEqual(f.model.watcherRestartOutcomesForTesting.first { $0.invocation == superseded }?.phase, .superseded)
        XCTAssertEqual(f.model.watcherRestartOutcomesForTesting.first { $0.invocation == superseded }?.reason, "Owner replaced")
        await f.model.prepareToTerminate()
        let aborted = f.model.restartStartupWatchersForUITesting()
        try await wait { f.model.watcherRestartOutcomesForTesting.contains { $0.invocation == aborted } }
        let result = try XCTUnwrap(f.model.watcherRestartOutcomesForTesting.first { $0.invocation == aborted })
        XCTAssertEqual(result.phase, .aborted)
        XCTAssertEqual(result.reason, "Terminating")
    }

    func testCapturedStartupScopeDetectsLateSubmissionAfterTermination() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let scope = f.model.startupReceiptScopeForTesting()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.startupSubmissionRecordingGateForTesting = held
        f.model.startReadyStartupForTesting(sources: [source])
        let handoff = try XCTUnwrap(f.model.startupHandoffIDForTesting)
        try await wait { f.model.startupSubmissionRecordingWaitingForTesting }
        XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: scope).isEmpty)
        await f.model.prepareToTerminate()
        await gate.open()
        try await wait { f.model.completedStartupHandoffsForTesting.contains(handoff) }
        let raw = try f.model.startupSubmissionsForTesting(in: scope)
        XCTAssertEqual(raw.map(\.handoffID), [handoff], "the terminated owner's late submission must remain visible")
        XCTAssertFalse(f.model.startupHandoffReceiptsForTesting.contains { $0.phase == .settled })
    }

    func testSourceReplacementRetainsDemandAcrossEachClaimPhase() async throws {
        for phase in 0..<3 {
            let f = try await fixture(count: 2)
            let source = ClaudeCodeSource(roots: [f.root])
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [source])
            let oldScheduler = try XCTUnwrap(f.model.schedulerForTesting)
            let scope = f.model.startupReceiptScopeForTesting()
            let preparation = ReviewReadGate(), prepared = Task { await preparation.wait() }
            let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
            await coordinator.gatePreparationForTesting(prepared)
            defer { prepared.cancel(); Task { await preparation.open() } }
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            if phase == 0 { f.model.rebuildSubmissionGateForTesting = held }
            if phase == 1 { f.model.rebuildHandoffGateForTesting = held }
            if phase == 2 { f.model.rebuildAcknowledgmentGateForTesting = held }
            f.model.queueRebuildForTesting()
            f.model.startReadyStartupForTesting(sources: [source])
            try await wait {
                if phase == 0 { return f.model.rebuildSubmissionWaitingForTesting }
                if phase == 1 { return f.model.rebuildHandoffWaitingForTesting }
                return f.model.rebuildAcknowledgmentWaitingForTesting
            }
            f.model.reloadSourcesAndRebuild()
            await preparation.open()
            try await wait { f.model.pendingDatabaseForTesting == nil && f.model.schedulerForTesting != nil
                && f.model.schedulerForTesting !== oldScheduler }
            if phase > 0 {
                XCTAssertTrue(f.model.pendingRebuildForTesting)
                XCTAssertTrue(f.model.rebuildClaimedForTesting, "replacement must preserve the in-flight claimant until its handoff returns")
            }
            if phase > 0 {
                try await wait { f.model.pendingStartupHandoffIDForTesting != nil }
                XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting()).isEmpty,
                    "replacement must not run an ordinary pass ahead of retained rebuild intent")
                XCTAssertTrue(f.model.sessions.isEmpty)
            }
            await gate.open()
            try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete
                && !f.model.watcherStartupPendingForTesting }
            let current = try XCTUnwrap(f.model.schedulerForTesting)
            await current.waitUntilIdle()
            let generation = await current.generationForTesting
            XCTAssertEqual(generation, 1, "the replacement owner gets one rebuild, phase \(phase)")
            let oldGeneration = await oldScheduler.generationForTesting
            XCTAssertEqual(oldGeneration, phase > 0 ? 1 : 0)
            let oldReceipts = try f.model.startupSubmissionsForTesting(in: scope)
            XCTAssertEqual(oldReceipts.filter(\.rebuild).count, phase == 0 ? 0 : 1)
            let replacement = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
            XCTAssertEqual(replacement.count, 1, "count all startup submissions, not only rebuild generations")
            let accepted = try XCTUnwrap(replacement.first)
            XCTAssertTrue(accepted.rebuild)
            XCTAssertNotNil(accepted.rebuildRequestID)
            XCTAssertNotNil(accepted.rebuildClaimID)
            let narrowed = f.model.startupReceiptScopeForTesting(watcherAttempt: accepted.watcherAttempt)
            XCTAssertEqual(try f.model.startupSubmissionsForTesting(in: narrowed).map(\.handoffID), [accepted.handoffID])
            let other = f.model.startupReceiptScopeForTesting(watcherAttempt: UUID())
            XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: other).isEmpty)
            if let displaced = oldReceipts.first {
                XCTAssertEqual(displaced.rebuildRequestID, accepted.rebuildRequestID)
                XCTAssertNotEqual(displaced.rebuildClaimID, accepted.rebuildClaimID)
            }
            XCTAssertFalse(f.model.sessions.isEmpty)
            await oldScheduler.waitUntilIdle()
        }
    }

    func testReentrantNewRequestBypassesObsoleteSubmissionGate() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.queueRebuildForTesting()
        f.model.rebuildSubmissionGateForTesting = held
        var replaced = false
        let token = f.model.objectWillChange.sink {
            guard !replaced, f.model.rebuildClaimedForTesting, f.model.sessions.isEmpty else { return }
            replaced = true
            f.model.rebuildIndex()
        }
        defer { token.cancel() }
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { replaced && !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let generation = await scheduler.generationForTesting
        XCTAssertEqual(generation, 1)
        XCTAssertFalse(f.model.rebuildSubmissionWaitingForTesting)
        XCTAssertEqual(f.model.startupHandoffReceiptsForTesting.filter { $0.phase == .submitted && $0.rebuild }.count, 0)
    }

    func testRetainedFallbackCannotConsumeNextManualRequestGate() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let submission = ReviewReadGate(), first = Task { await submission.wait() }
        let explicit = ReviewReadGate(), second = Task { await explicit.wait() }
        defer { first.cancel(); second.cancel(); Task { await submission.open(); await explicit.open() } }
        f.model.queueRebuildForTesting()
        f.model.rebuildSubmissionGateForTesting = first
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        f.model.rebuildClaimGateForTesting = second
        let ready = await f.model.startWatchingForTesting([source], force: true)
        XCTAssertTrue(ready)
        await submission.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        XCTAssertTrue(f.model.hasExplicitRebuildGateForTesting)
        XCTAssertFalse(f.model.rebuildClaimWaitingForTesting)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let before = await scheduler.generationForTesting
        XCTAssertEqual(before, 1)
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        XCTAssertFalse(f.model.hasExplicitRebuildGateForTesting)
        let waiting = await scheduler.generationForTesting
        XCTAssertEqual(waiting, 1)
        await explicit.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        await scheduler.waitUntilIdle()
        let after = await scheduler.generationForTesting
        XCTAssertEqual(after, 2)
    }

    func testWatcherRestartControlSettlesOnboardingDeferral() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.rebuildSubmissionGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        f.model.settings.onboardingComplete = false
        f.model.restartStartupWatchersForUITesting()
        try await wait { !f.model.isPreparingRebuild && !f.model.rebuildClaimedForTesting }
        XCTAssertEqual(f.model.progress.phase, .waiting)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
        f.model.settings.onboardingComplete = true
        let source = ClaudeCodeSource(roots: [f.root])
        let ready = await f.model.startWatchingForTesting([source])
        XCTAssertTrue(ready)
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
    }

    func testStartupActivityHoldIsOneShotAndRequiresReleasePath() async throws {
        for valid in [false, true] {
            let f = try await fixture(count: 2)
            f.model.startupActivityHoldConfigurationForTesting = (120_000, valid ? "/tmp/invocation-release" : nil)
            XCTAssertEqual(f.model.takeStartupActivityHoldForTesting(), valid
                ? .init(delay: 120_000, releasePath: "/tmp/invocation-release") : nil)
            XCTAssertNil(f.model.takeStartupActivityHoldForTesting())
            XCTAssertEqual(f.model.startupTestControlFailuresForTesting, valid ? [] : ["Missing startup activity release path"])
        }
    }

    func testInvalidClaimCleanupRetiresStartupSlotBeforeReentrantReadiness() async throws {
        for grouped in [false, true] {
            let f = try await fixture(count: 2)
            let source = ClaudeCodeSource(roots: [f.root])
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [source])
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.rebuildSubmissionGateForTesting = held
            f.model.queueRebuildForTesting()
            let request = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
            f.model.startReadyStartupForTesting(sources: [source])
            try await wait { f.model.rebuildSubmissionWaitingForTesting }
            var reentered = false
            let observe = {
                guard !reentered, !f.model.isPreparingRebuild, f.model.pendingRebuildForTesting else { return }
                reentered = true
                XCTAssertNil(f.model.startupHandoffIDForTesting,
                    "cleanup notifications must not expose an abandoned claim's live startup slot")
                XCTAssertFalse(f.model.rebuildClaimedForTesting)
                f.model.settings.onboardingComplete = true
                f.model.startReadyStartupForTesting(sources: [source])
                f.model.startReadyStartupForTesting(sources: [source])
            }
            let token = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                : f.model.objectWillChange.sink { observe() }
            defer { token.cancel() }
            f.model.settings.onboardingComplete = false
            await gate.open()
            try await wait { reentered && !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
            let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
            XCTAssertEqual(raw.count, 1)
            XCTAssertEqual(raw.first?.rebuildRequestID, request)
            XCTAssertEqual(raw.first?.rebuild, true)
        }
    }

    func testConfiguredStartupActivityPathActuallyReleasesAndCancellationEscapes() async throws {
        let f = try await fixture(count: 2)
        let release = f.root.appendingPathComponent("configured-activity-release")
        f.model.startupActivityHoldConfigurationForTesting = (2_000, release.path)
        let hold = try XCTUnwrap(f.model.takeStartupActivityHoldForTesting())
        var started = false, finished = false
        let waiting = Task {
            started = true
            try await f.model.waitForStartupActivityHoldForTesting(hold)
            finished = true
        }
        defer { waiting.cancel() }
        try await wait { started }
        XCTAssertFalse(finished)
        try Data().write(to: release)
        try await wait { finished }
        try await waiting.value
        XCTAssertNil(f.model.takeStartupActivityHoldForTesting())
        let missing = TraceModel.StartupActivityHold(delay: 50, releasePath: f.root.appendingPathComponent("missing").path)
        do {
            try await f.model.waitForStartupActivityHoldForTesting(missing)
            XCTFail("missing release must time out")
        } catch { XCTAssertEqual((error as NSError).domain, "TraceTestHooks") }
        let cancelled = Task { try await f.model.waitForStartupActivityHoldForTesting(.init(delay: 2_000, releasePath: missing.releasePath)) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled wait must escape") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAttachmentContinuationPreservesManualRequestAndItsExplicitGate() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let first = ReviewReadGate(), held = Task { await first.wait() }
        let later = ReviewReadGate(), next = Task { await later.wait() }
        defer { held.cancel(); next.cancel(); Task { await first.open(); await later.open() } }
        f.model.rebuildClaimGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        let requestID = try XCTUnwrap(f.model.rebuildRequestIDForTesting)
        let admission = try XCTUnwrap(f.model.rebuildAdmissionIDForTesting)
        f.model.rebuildClaimGateForTesting = next
        let coordinator = IndexCoordinator(database: f.database, sources: [ClaudeCodeSource(roots: [f.root])], clock: f.clock)
        let installed = await f.model.attach(database: f.database, coordinator: coordinator)
        XCTAssertTrue(installed)
        try await wait { f.model.rebuildAdmissionIDForTesting != admission && f.model.rebuildClaimWaitingForTesting }
        XCTAssertEqual(f.model.rebuildRequestIDForTesting, requestID)
        XCTAssertTrue(f.model.hasExplicitRebuildGateForTesting)
        XCTAssertEqual(f.model.explicitRebuildGateOpenForTesting, false,
            "retiring the old admission cannot release a request gate retained by its successor")
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        let before = await scheduler.generationForTesting
        XCTAssertEqual(before, 0)
        await first.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        XCTAssertNotEqual(f.model.rebuildRequestIDForTesting, requestID)
        XCTAssertFalse(f.model.hasExplicitRebuildGateForTesting)
        await later.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        await scheduler.waitUntilIdle()
        let after = await scheduler.generationForTesting
        XCTAssertEqual(after, 2)
    }

    func testPreHandoffHoldPreservesBufferedInputsAcrossReplacement() async throws {
        for replace in [false, true] {
            let f = try await fixture(count: 2)
            let source = ClaudeCodeSource(roots: [f.root])
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [source])
            let scope = f.model.startupReceiptScopeForTesting()
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.rebuildPreHandoffGateForTesting = held
            var before = SourceChanges()
            let firstPath = f.root.appendingPathComponent("before-hold.jsonl")
            try line(997).write(to: firstPath)
            before.paths = [firstPath.path]
            before.watermarks = ["coordination-volume": 41]
            before.streamRoots = ["coordination-volume": [f.root.path]]
            f.model.queueStartupWorkForTesting(before)
            f.model.queueRebuildForTesting()
            f.model.startReadyStartupForTesting(sources: [source])
            try await wait { f.model.rebuildPreHandoffWaitingForTesting }
            var during = SourceChanges()
            let laterPath = f.root.appendingPathComponent("during-hold.jsonl")
            try line(998).write(to: laterPath)
            during.paths = [laterPath.path]
            during.reconciliationPaths = [f.root.path]
            during.watermarks = ["coordination-volume": 99]
            during.streamRoots = ["coordination-volume": [f.root.path]]
            f.model.queueStartupWorkForTesting(during,
                recovery: .init(filePaths: [firstPath.path], reconciliationPaths: [f.root.path]))
            if replace {
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.pendingStartupHandoffIDForTesting != nil }
                XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: scope).isEmpty)
            }
            await gate.open()
            try await wait { !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting
                && f.model.progress.phase == .complete }
            let current = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
            XCTAssertEqual(current.count, 1)
            let receipt = try XCTUnwrap(current.first)
            XCTAssertTrue(receipt.rebuild)
            XCTAssertTrue(receipt.paths.isSuperset(of: [firstPath.path, laterPath.path]))
            XCTAssertTrue(receipt.reconciliationPaths.contains(f.root.path))
            XCTAssertEqual(receipt.watermarks["coordination-volume"], 99)
            XCTAssertEqual(receipt.streamRoots["coordination-volume"], [f.root.path])
            XCTAssertEqual(receipt.recoveryPaths, [firstPath.path])
            if replace { XCTAssertTrue(try f.model.startupSubmissionsForTesting(in: scope).isEmpty) }
        }
    }

    func testDisplacedClaimDoesNotAwaitObsoleteStartupSettlementGate() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let preparation = ReviewReadGate(), prepared = Task { await preparation.wait() }
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        await coordinator.gatePreparationForTesting(prepared)
        defer { prepared.cancel(); Task { await preparation.open() } }
        let acknowledgment = ReviewReadGate(), held = Task { await acknowledgment.wait() }
        let settlement = ReviewReadGate(), tail = Task { await settlement.wait() }
        defer { held.cancel(); tail.cancel(); Task { await acknowledgment.open(); await settlement.open() } }
        f.model.rebuildAcknowledgmentGateForTesting = held
        f.model.startupSettlementGateForTesting = tail
        f.model.queueRebuildForTesting()
        f.model.startReadyStartupForTesting(sources: [source])
        let obsolete = try XCTUnwrap(f.model.startupHandoffIDForTesting)
        try await wait { f.model.rebuildAcknowledgmentWaitingForTesting }
        f.model.reloadSourcesAndRebuild()
        await preparation.open()
        try await wait { f.model.pendingStartupHandoffIDForTesting != nil }
        await acknowledgment.open()
        try await wait { f.model.completedStartupHandoffsForTesting.contains(obsolete)
            && !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting
            && f.model.progress.phase == .complete }
        XCTAssertFalse(f.model.startupSettlementWaitingForTesting.contains(obsolete))
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.rebuild, true)
    }

    func testDatabaseReplacementDiscardsBufferedStartupProvenance() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        f.model.settings.onboardingComplete = true
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.sourceChangeAttachmentGateForTesting = held
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        var old = SourceChanges()
        let path = f.root.appendingPathComponent("obsolete-input.jsonl").path
        old.paths = [path]
        old.watermarks = ["obsolete-volume": 88]
        old.streamRoots = ["obsolete-volume": [f.root.path]]
        f.model.queueStartupWorkForTesting(old,
            recovery: .init(filePaths: [path], reconciliationPaths: [f.root.path]))
        XCTAssertEqual(f.model.bufferedStartupInputsForTesting.paths, [path])
        XCTAssertEqual(f.model.bufferedStartupInputsForTesting.watermarks["obsolete-volume"], 88)
        let source = ClaudeCodeSource(roots: [replacement.root])
        let coordinator = IndexCoordinator(database: replacement.database, sources: [source], clock: f.clock)
        let installed = await f.model.attach(database: replacement.database, coordinator: coordinator)
        XCTAssertTrue(installed)
        await gate.open()
        try await prepareStartup(f.model, sources: [source])
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { !f.model.watcherStartupPendingForTesting && f.model.progress.phase == .complete }
        let raw = try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())
        XCTAssertEqual(raw.count, 1)
        let receipt = try XCTUnwrap(raw.first)
        XCTAssertFalse(receipt.paths.contains(path))
        XCTAssertNil(receipt.watermarks["obsolete-volume"])
        XCTAssertNil(receipt.streamRoots["obsolete-volume"])
        XCTAssertTrue(receipt.recoveryPaths.isEmpty)
        XCTAssertFalse(receipt.reconciliationPaths.contains(f.root.path))
    }

    func testWatcherOnlyDeferralPreservesFailedSourceRecovery() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.sourceReloadRecovery.error != nil }
        let error = try XCTUnwrap(f.model.sourceReloadRecovery.error)
        f.model.settings.onboardingComplete = false
        f.model.restartStartupWatchersForUITesting()
        try await wait { f.model.progress.phase == .waiting }
        XCTAssertEqual(f.model.sourceReloadRecovery, .failed(error))
        f.model.settings.onboardingComplete = true
        f.model.failSourceConfigurationForTesting = false
        f.model.retrySourceConfiguration()
        try await wait { f.model.sourceReloadRecovery.error == nil && f.model.progress.phase == .complete }
    }

    func testStartupRejectsPreparingAndStaleWatcherReceipts() async throws {
        for holdReadiness in [false, true] {
            let f = try await fixture(count: 2)
            let source = ClaudeCodeSource(roots: [f.root])
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [source])
            let staleStartup = try XCTUnwrap(f.model.captureReadyStartupForTesting(sources: [source]))
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            if holdReadiness { f.model.watcherReadinessGateForTesting = held }
            else { f.model.watcherPreparationGateForTesting = held }
            let replacement = Task { await f.model.startWatchingForTesting([source], force: true) }
            try await wait { holdReadiness ? f.model.watcherReadinessWaitingForTesting
                : f.model.watcherPreparationWaitingForTesting }
            staleStartup()
            f.model.startReadyStartupForTesting(sources: [source])
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(f.model.startupHandoffIDForTesting)
            XCTAssertTrue(f.model.startupHandoffReceiptsForTesting.isEmpty)
            XCTAssertFalse(f.model.safetyVerificationActiveForTesting)
            await gate.open()
            let ready = await replacement.value
            XCTAssertTrue(ready)
            var changes = SourceChanges()
            changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
            changes.reconciliationPaths = [f.root.path]
            changes.watermarks = ["ready-watcher": 92]
            changes.streamRoots = ["ready-watcher": [f.root.path]]
            await f.model.bufferSourceChangesForTesting(changes)
            staleStartup()
            XCTAssertTrue(f.model.watcherStartupPendingForTesting)
            f.model.startReadyStartupForTesting(sources: [source])
            try await wait { !f.model.watcherStartupPendingForTesting && f.model.safetyVerificationActiveForTesting }
            await f.model.schedulerForTesting?.waitUntilIdle()
            let receipt = try XCTUnwrap((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).first)
            XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
            XCTAssertEqual(receipt.watcherGeneration, f.model.watcherGenerationForTesting)
            XCTAssertTrue(receipt.reconciliationPaths.contains(f.root.path))
            XCTAssertEqual(receipt.watermarks["ready-watcher"], 92)
            XCTAssertEqual(receipt.streamRoots["ready-watcher"], [f.root.path])
            let later = f.root.appendingPathComponent("after-ready.jsonl")
            try line(999).write(to: later)
            var live = SourceChanges(); live.paths = [later.path]
            await f.model.bufferSourceChangesForTesting(live)
            await f.model.schedulerForTesting?.waitUntilIdle()
            let rows = try await f.database.sessions(limit: 100)
            XCTAssertTrue(rows.contains { $0.title == "NavigationNeedle 999" })
        }
    }

    func testStaleStartupFinalizationGivesReplacementItsRetainedRebuild() async throws {
        for grouped in [false, true] {
            let f = try await fixture(count: 2)
            let source = ClaudeCodeSource(roots: [f.root])
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [source])
            let explicit = ReviewReadGate(), explicitHeld = Task { await explicit.wait() }
            let submission = ReviewReadGate(), submissionHeld = Task { await submission.wait() }
            defer { explicitHeld.cancel(); submissionHeld.cancel(); Task { await explicit.open(); await submission.open() } }
            f.model.rebuildClaimGateForTesting = explicitHeld
            f.model.rebuildSubmissionGateForTesting = submissionHeld
            f.model.rebuildIndex()
            try await wait { f.model.rebuildClaimWaitingForTesting }
            f.model.startReadyStartupForTesting(sources: [source])
            let obsolete = try XCTUnwrap(f.model.startupHandoffIDForTesting)
            try await wait { f.model.rebuildSubmissionWaitingForTesting }
            let ready = await f.model.startWatchingForTesting([source], force: true)
            XCTAssertTrue(ready)
            f.model.startReadyStartupForTesting(sources: [source])
            let replacement = try XCTUnwrap(f.model.pendingStartupHandoffIDForTesting)
            var reentered = false
            let observe = {
                guard !reentered, !f.model.isPreparingRebuild,
                      f.model.pendingStartupHandoffIDForTesting == replacement else { return }
                reentered = true
                f.model.startReadyStartupForTesting(sources: [source])
            }
            let token = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                : f.model.objectWillChange.sink { observe() }
            defer { token.cancel() }
            await submission.open()
            try await wait { f.model.completedStartupHandoffsForTesting.contains(obsolete)
                && !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting }
            await explicit.open()
            try await wait { !f.model.rebuildClaimWaitingForTesting }
            let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
            await scheduler.waitUntilIdle()
            XCTAssertTrue(reentered)
            let receipts = (try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting()))
            XCTAssertEqual(receipts.count, 1)
            XCTAssertEqual(receipts.first?.handoffID, replacement)
            XCTAssertEqual(receipts.first?.rebuild, true)
            let generation = await scheduler.generationForTesting
            XCTAssertEqual(generation, 1, "replacement startup must carry the only rebuild submission")
            XCTAssertFalse(f.model.sessions.isEmpty)
        }
    }

    func testReplacementReleasesWaitersAndPreservesSuccessorClaim() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        let first = ReviewReadGate(), firstHeld = Task { await first.wait() }
        let second = ReviewReadGate(), secondHeld = Task { await second.wait() }
        defer { firstHeld.cancel(); secondHeld.cancel(); Task { await first.open(); await second.open() } }
        f.model.rebuildSubmissionGateForTesting = firstHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let obsolete = try XCTUnwrap(f.model.rebuildAdmissionIDForTesting)
        var progress = IndexProgress(phase: .indexing)
        progress.activity = .rebuild
        let delivery = Task { await f.model.receiveProgress(progress) }
        try await wait { f.model.admissionWaitingPassesForTesting.contains(progress.passID) }
        f.model.rebuildSubmissionGateForTesting = secondHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildAdmissionIDForTesting != obsolete && f.model.rebuildSubmissionWaitingForTesting }
        let successor = try XCTUnwrap(f.model.rebuildAdmissionIDForTesting)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        XCTAssertTrue(f.model.rebuildClaimedForTesting)
        await first.open()
        try await wait { f.model.completedRebuildSubmissionsForTesting.contains(obsolete) }
        XCTAssertEqual(f.model.rebuildAdmissionIDForTesting, successor)
        XCTAssertTrue(f.model.rebuildClaimedForTesting)
        await second.open()
        await delivery.value
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        await f.model.prepareToTerminate()
        XCTAssertTrue(f.model.admissionWaitingPassesForTesting.isEmpty)
    }

    func testStartupAdmissionDoesNotConsumeExplicitOnlyGate() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        let explicit = ReviewReadGate(), explicitHeld = Task { await explicit.wait() }
        let submission = ReviewReadGate(), submissionHeld = Task { await submission.wait() }
        defer { explicitHeld.cancel(); submissionHeld.cancel(); Task { await explicit.open(); await submission.open() } }
        f.model.rebuildClaimGateForTesting = explicitHeld
        f.model.rebuildSubmissionGateForTesting = submissionHeld
        f.model.queueRebuildForTesting()
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        XCTAssertTrue(f.model.hasExplicitRebuildGateForTesting)
        XCTAssertFalse(f.model.rebuildClaimWaitingForTesting)
        await submission.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.safetyVerificationActiveForTesting }
        await f.model.schedulerForTesting?.waitUntilIdle()
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        XCTAssertFalse(f.model.hasExplicitRebuildGateForTesting)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        await explicit.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
        let generation = await f.model.schedulerForTesting?.generationForTesting
        XCTAssertEqual(generation, 2)
    }

    func testStartupReceiptHistoryRequiresExplicitCollection() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        f.model.collectsStartupHandoffsForTesting = false
        XCTAssertThrowsError(try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())) {
            XCTAssertTrue($0 is TraceModel.StartupEvidenceError)
        }
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.startupHandoffIDForTesting == nil && f.model.safetyVerificationActiveForTesting }
        XCTAssertTrue(f.model.startupHandoffReceiptsForTesting.isEmpty)
        f.model.collectsStartupHandoffsForTesting = true
        let ready = await f.model.startWatchingForTesting([source], force: true)
        XCTAssertTrue(ready)
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.startupHandoffIDForTesting == nil && f.model.safetyVerificationActiveForTesting }
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
        XCTAssertEqual(f.model.startupHandoffReceiptsForTesting.filter { $0.phase == .settled }.count, 1)
    }


    func testStartupAcknowledgesRebuildAcrossWatcherGenerationChange() async throws {
        let f = try await fixture(count: 2)
        let source = ClaudeCodeSource(roots: [f.root])
        let explicit = ReviewReadGate(), explicitHeld = Task { await explicit.wait() }
        let acknowledgment = ReviewReadGate(), ackHeld = Task { await acknowledgment.wait() }
        defer { explicitHeld.cancel(); ackHeld.cancel(); Task { await explicit.open(); await acknowledgment.open() } }
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [source])
        f.model.rebuildClaimGateForTesting = explicitHeld
        f.model.rebuildAcknowledgmentGateForTesting = ackHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.rebuildAcknowledgmentWaitingForTesting }
        let generation = f.model.watcherGenerationForTesting
        let started = await f.model.startWatchingForTesting([source], force: true)
        XCTAssertTrue(started)
        XCTAssertGreaterThan(f.model.watcherGenerationForTesting, generation)
        var changes = SourceChanges()
        changes.paths = [f.root.appendingPathComponent("sessions.jsonl").path]
        changes.reconciliationPaths = [f.root.path]
        changes.watermarks = ["new-watcher": 42]
        changes.streamRoots = ["new-watcher": [f.root.path]]
        await f.model.bufferSourceChangesForTesting(changes)
        f.model.startReadyStartupForTesting(sources: [source])
        let replacement = try XCTUnwrap(f.model.pendingStartupHandoffIDForTesting)
        f.model.startReadyStartupForTesting(sources: [source])
        XCTAssertEqual(f.model.pendingStartupHandoffIDForTesting, replacement)
        XCTAssertTrue(f.model.watcherStartupPendingForTesting)
        await acknowledgment.open()
        try await wait { !f.model.pendingRebuildForTesting && !f.model.watcherStartupPendingForTesting
            && f.model.safetyVerificationActiveForTesting }
        await explicit.open()
        f.model.startReadyStartupForTesting(sources: [source])
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let submittedGeneration = await scheduler.generationForTesting
        XCTAssertEqual(submittedGeneration, 1)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 2)
        let receipts = f.model.startupHandoffReceiptsForTesting
        XCTAssertEqual(receipts.filter { $0.phase == .submitted && $0.rebuild }.count, 1)
        XCTAssertEqual(receipts.filter { $0.phase == .settled }.map(\.handoffID), [replacement])
        let current = try XCTUnwrap(receipts.first { $0.handoffID == replacement && $0.phase == .submitted })
        XCTAssertEqual(current.watcherGeneration, f.model.watcherGenerationForTesting)
        XCTAssertTrue(current.paths.isSuperset(of: changes.paths))
        XCTAssertTrue(current.reconciliationPaths.isSuperset(of: changes.reconciliationPaths))
        XCTAssertEqual(current.watermarks["new-watcher"], 42)
        XCTAssertEqual(current.streamRoots["new-watcher"], [f.root.path])
        XCTAssertFalse(f.model.isPreparingRebuild)
        XCTAssertFalse(f.model.sessions.isEmpty)
        let later = f.root.appendingPathComponent("later.jsonl")
        try line(999).write(to: later)
        var subsequent = SourceChanges(); subsequent.paths = [later.path]
        await f.model.bufferSourceChangesForTesting(subsequent)
        await scheduler.waitUntilIdle()
        let rows = try await f.database.sessions(limit: 100)
        XCTAssertTrue(rows.contains { $0.title == "NavigationNeedle 999" })
    }

    func testUnclaimedExplicitAbortCannotReleaseStartupClaim() async throws {
        let f = try await fixture(count: 2)
        let explicit = ReviewReadGate(), explicitHeld = Task { await explicit.wait() }
        let submission = ReviewReadGate(), held = Task { await submission.wait() }
        defer { explicitHeld.cancel(); held.cancel(); Task { await explicit.open(); await submission.open() } }
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.rebuildClaimGateForTesting = explicitHeld
        f.model.rebuildSubmissionGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let owner = f.model.rebuildAdmissionIDForTesting
        f.model.settings.onboardingComplete = false
        await explicit.open()
        try await wait { !f.model.rebuildClaimWaitingForTesting }
        XCTAssertTrue(f.model.rebuildClaimedForTesting)
        XCTAssertEqual(f.model.rebuildAdmissionIDForTesting, owner)
        XCTAssertTrue(f.model.isPreparingRebuild)
        f.model.settings.onboardingComplete = true
        await submission.open()
        try await wait { !f.model.pendingRebuildForTesting }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let generation = await scheduler.generationForTesting
        XCTAssertEqual(generation, 1)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
    }

    func testPostStartupRebuildResumesAfterOnboardingDeferral() async throws {
        for grouped in [false, true] {
            let f = try await fixture(count: 2)
            let source = ClaudeCodeSource(roots: [f.root])
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [source])
            f.model.startReadyStartupForTesting(sources: [source])
            try await wait { (try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count == 1 && f.model.progress.phase == .complete }
            await f.model.schedulerForTesting?.waitUntilIdle()
            var deferred = false
            let observe = {
                guard !deferred, f.model.rebuildClaimedForTesting, f.model.sessions.isEmpty else { return }
                deferred = true
                f.model.settings.onboardingComplete = false
            }
            let token = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                : f.model.objectWillChange.sink { observe() }
            f.model.rebuildIndex()
            try await wait { deferred && !f.model.isPreparingRebuild }
            token.cancel()
            XCTAssertTrue(f.model.pendingRebuildForTesting)
            XCTAssertFalse(f.model.rebuildClaimedForTesting)
            XCTAssertFalse(f.model.indexingPassActiveForTesting)
            f.model.settings.onboardingComplete = true
            f.model.startReadyStartupForTesting(sources: [source]) // Same resume entry used after watcher readiness.
            f.model.startReadyStartupForTesting(sources: [source])
            try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
            let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
            await scheduler.waitUntilIdle()
            let generation = await scheduler.generationForTesting
            XCTAssertEqual(generation, 1)
            XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
            XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
            XCTAssertFalse(f.model.sessions.isEmpty)
        }
    }

    func testReplacingAdmissionDoesNotStartIdleUsageSettlement() async throws {
        let f = try await fixture(count: 2)
        let first = ReviewReadGate(), firstHeld = Task { await first.wait() }
        let second = ReviewReadGate(), secondHeld = Task { await second.wait() }
        defer { firstHeld.cancel(); secondHeld.cancel(); Task { await first.open(); await second.open() } }
        f.model.settings.onboardingComplete = true
        f.model.rebuildSubmissionGateForTesting = firstHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        XCTAssertTrue(f.model.usagePendingForTesting)
        let starts = f.model.usageWorkerStartsForTesting
        f.model.rebuildSubmissionGateForTesting = secondHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        XCTAssertEqual(f.model.usageWorkerStartsForTesting, starts)
        XCTAssertFalse(f.model.usageRefreshWaitingForTesting)
        XCTAssertFalse(f.model.usageRefreshRunningForTesting)
        await first.open(); await second.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete }
    }

    func testOlderAcknowledgmentCannotConsumeNewerRebuildDemand() async throws {
        let f = try await fixture(count: 2)
        let first = ReviewReadGate(), firstHeld = Task { await first.wait() }
        let second = ReviewReadGate(), secondHeld = Task { await second.wait() }
        defer { firstHeld.cancel(); secondHeld.cancel(); Task { await first.open(); await second.open() } }
        f.model.settings.onboardingComplete = true
        f.model.rebuildAcknowledgmentGateForTesting = firstHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildAcknowledgmentWaitingForTesting }
        f.model.rebuildSubmissionGateForTesting = secondHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let newer = f.model.rebuildAdmissionIDForTesting
        await first.open()
        try await wait { !f.model.rebuildAcknowledgmentWaitingForTesting }
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        XCTAssertTrue(f.model.rebuildClaimedForTesting)
        XCTAssertEqual(f.model.rebuildAdmissionIDForTesting, newer)
        XCTAssertTrue(f.model.isPreparingRebuild)
        await second.open()
        try await wait { !f.model.pendingRebuildForTesting }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let generation = await scheduler.generationForTesting
        XCTAssertEqual(generation, 2)
        XCTAssertFalse(f.model.isPreparingRebuild)
    }

    func testAuditObserverDoesNotRetainTerminatedModel() async throws {
        let f = try await fixture(count: 2)
        let reference = WeakModelReference()
        var callbacks = 0
        var model: TraceModel? = TraceModel(settings: f.model.settings, clock: f.clock,
            startupActivityObserver: { _ in
                callbacks += 1
                XCTAssertFalse(reference.value?.watcherStartupPendingForTesting ?? true)
                reference.value?.rebuildIndex()
            }, diagnosticsURL: f.root.appendingPathComponent("weak-audit.json"))
        model?.collectsStartupHandoffsForTesting = true
        reference.value = model
        let source = ClaudeCodeSource(roots: [f.root])
        await model?.attachForTesting(database: f.database, sources: [source])
        model?.settings.onboardingComplete = true
        try await prepareStartup(try XCTUnwrap(model), sources: [source])
        model?.startReadyStartupForTesting(sources: [source])
        try await wait { callbacks == 1 && reference.value?.pendingRebuildForTesting == false
            && reference.value?.progress.phase == .complete }
        await model?.prepareToTerminate()
        model = nil
        try await wait { reference.value == nil }
    }

    func testStartupCompletionResumesRebuildDeferredDuringItsHandoff() async throws {
        let f = try await fixture(count: 2)
        let startup = ReviewReadGate(), startupHeld = Task { await startup.wait() }
        let submission = ReviewReadGate(), submissionHeld = Task { await submission.wait() }
        defer { startupHeld.cancel(); submissionHeld.cancel(); Task { await startup.open(); await submission.open() } }
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.startupSettlementGateForTesting = startupHeld
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        let handoff = try XCTUnwrap(f.model.startupHandoffIDForTesting)
        try await wait { f.model.startupSettlementWaitingForTesting.contains(handoff) }
        f.model.rebuildSubmissionGateForTesting = submissionHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        f.model.settings.onboardingComplete = false
        await submission.open()
        try await wait { !f.model.rebuildClaimedForTesting && !f.model.isPreparingRebuild }
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        f.model.settings.onboardingComplete = true
        // Releasing startup must service retained demand without another startIndexing call.
        await startup.open()
        try await wait { !f.model.pendingRebuildForTesting && f.model.progress.phase == .complete
            && !f.model.watcherStartupPendingForTesting && f.model.safetyVerificationActiveForTesting }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let generation = await scheduler.generationForTesting
        XCTAssertEqual(generation, 1)
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
        XCTAssertEqual(f.model.startupHandoffReceiptsForTesting.filter { $0.phase == .settled }.count, 1)
    }

    func testSupersededStartupAuditsOnlyCurrentSettlement() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        let reference = WeakModelReference()
        var activities: [IndexActivity] = []
        let model = try uninstalledModel(clock: f.clock, diagnosticsURL: f.root.appendingPathComponent("settled-audit.json"),
            startupActivityObserver: { activity in
                guard let current = reference.value else { return }
                XCTAssertFalse(current.watcherStartupPendingForTesting)
                activities.append(activity)
                current.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
            })
        reference.value = model
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attachForTesting(database: f.database, sources: [source])
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        model.settings.onboardingComplete = true
        try await prepareStartup(model, sources: [source])
        model.startupSettlementGateForTesting = held
        model.startReadyStartupForTesting(sources: [source])
        let first = try XCTUnwrap(model.startupHandoffIDForTesting)
        try await wait { model.startupSettlementWaitingForTesting.contains(first) }
        XCTAssertTrue(activities.isEmpty)
        let started = await model.startWatchingForTesting([source], force: true)
        XCTAssertTrue(started)
        model.startReadyStartupForTesting(sources: [source])
        let newest = try XCTUnwrap(model.pendingStartupHandoffIDForTesting)
        await gate.open()
        try await wait { model.completedStartupHandoffsForTesting.contains(newest)
            && model.safetyVerificationActiveForTesting }
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(model.startupHandoffReceiptsForTesting.filter { $0.phase == .submitted }.count, 2)
        XCTAssertEqual(model.startupHandoffReceiptsForTesting.filter { $0.phase == .settled }.map(\.handoffID), [newest])
        XCTAssertFalse(model.watcherStartupPendingForTesting)
    }

    func testStartupReplacementAndTerminationDiscardObsoleteSettlement() async throws {
        for terminate in [false, true] {
            let f = try await fixture(count: 2)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.settings.onboardingComplete = true
            try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
            f.model.startupSettlementGateForTesting = held
            f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
            let first = try XCTUnwrap(f.model.startupHandoffIDForTesting)
            try await wait { f.model.startupSettlementWaitingForTesting.contains(first) }
            if terminate { await f.model.prepareToTerminate() }
            else {
                let replacement = try IndexDatabase(url: f.root.appendingPathComponent("replacement.sqlite"))
                await f.model.attachForTesting(database: replacement, sources: [])
                try await prepareStartup(f.model, sources: [])
                f.model.startReadyStartupForTesting(sources: [])
            }
            await gate.open()
            try await wait { f.model.completedStartupHandoffsForTesting.contains(first) }
            XCTAssertTrue(f.model.startupHandoffReceiptsForTesting.contains { $0.handoffID == first && $0.phase == .submitted })
            XCTAssertFalse(f.model.startupHandoffReceiptsForTesting.contains { $0.handoffID == first && $0.phase == .settled })
            if terminate {
                XCTAssertNil(f.model.startupHandoffIDForTesting)
                XCTAssertNil(f.model.pendingStartupHandoffIDForTesting)
                XCTAssertFalse(f.model.safetyVerificationActiveForTesting)
            } else {
                try await wait { !f.model.watcherStartupPendingForTesting && f.model.safetyVerificationActiveForTesting }
                XCTAssertTrue(f.model.sessions.isEmpty)
            }
        }
    }

    func testDeferredSourceReloadKeepsUnpaidRollupStatusUntilRepair() async throws {
        let f = try await fixture(count: 2)
        var failed = IndexProgress(phase: .failed)
        failed.rollupError = "Could not update token totals."
        failed.unresolvedFailedFiles = 3
        f.model.setPublishedProgressForTesting(failed)
        f.model.settings.onboardingComplete = false
        _ = await f.model.startWatchingForTesting([ClaudeCodeSource(roots: [f.root])])
        XCTAssertEqual(f.model.progress.phase, .waiting)
        XCTAssertEqual(f.model.progress.passID, failed.passID)
        XCTAssertEqual(f.model.progress.rollupError, failed.rollupError)
        let details = IndexProgressLabel(progress: f.model.progress).details
        XCTAssertTrue(details.contains("Token totals: Could not update token totals."))
        XCTAssertTrue(details.contains("3 files still failing"))
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        try await wait { !f.model.usagePendingForTesting && !f.model.costsTotalsUpdating }
        XCTAssertNil(f.model.progress.rollupError)
    }

    func testStartupClaimRetainsRebuildAcrossOnboardingAndSourceReload() async throws {
        for grouped in [false, true] {
            for reload in [false, true] {
                let f = try await fixture(count: 2)
                let claim = ReviewReadGate(), held = Task { await claim.wait() }
                defer { held.cancel(); Task { await claim.open() } }
                f.model.settings.onboardingComplete = true
                try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
                f.model.rebuildClaimGateForTesting = held
                var observed = false
                let observe = {
                    guard !observed, f.model.rebuildClaimedForTesting, f.model.sessions.isEmpty else { return }
                    observed = true
                    XCTAssertTrue(f.model.pendingRebuildForTesting)
                    if reload { f.model.reloadSourcesAndRebuild() }
                    else { f.model.settings.onboardingComplete = false }
                }
                let token = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                    : f.model.objectWillChange.sink { observe() }
                defer { token.cancel() }
                f.model.rebuildIndex()
                try await wait { f.model.rebuildClaimWaitingForTesting }
                f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
                try await wait { observed }
                if !reload {
                    try await wait { !f.model.isPreparingRebuild }
                    XCTAssertTrue(f.model.pendingRebuildForTesting)
                    XCTAssertFalse(f.model.rebuildClaimedForTesting)
                    XCTAssertFalse(f.model.indexingPassActiveForTesting)
                    XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 0)
                    f.model.settings.onboardingComplete = true
                    f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
                }
                await claim.open()
                try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
                let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
                await scheduler.waitUntilIdle()
                let submitted = await scheduler.generationForTesting
                XCTAssertEqual(submitted, 1)
                XCTAssertFalse(f.model.pendingRebuildForTesting)
                XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
                XCTAssertFalse(f.model.sessions.isEmpty)
            }
        }
    }

    func testAcknowledgedStartupKeepsPreparationWhenExplicitClaimArrivesLate() async throws {
        let f = try await fixture(count: 2)
        let claim = ReviewReadGate(), claimed = Task { await claim.wait() }
        let preparation = ReviewReadGate(), prepared = Task { await preparation.wait() }
        defer { claimed.cancel(); prepared.cancel(); Task { await claim.open(); await preparation.open() } }
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        await coordinator.gatePreparationForTesting(prepared)
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.rebuildClaimGateForTesting = claimed
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        try await wait { await coordinator.preparationWaitingForTesting }
        try await wait { f.model.rebuildAcceptedForTesting }
        XCTAssertTrue(f.model.isPreparingRebuild)
        XCTAssertTrue(f.model.pendingRebuildForTesting, "acknowledgment must retain unpaid reset intent")
        await claim.open()
        try await wait { !f.model.rebuildClaimWaitingForTesting }
        XCTAssertTrue(f.model.isPreparingRebuild, "a late unclaimed submitter cannot retire acknowledged preparation")
        await preparation.open()
        try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        XCTAssertFalse(f.model.isPreparingRebuild)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
    }

    func testStartupAuditDescribesHandoffBeforeReentrantNewRebuild() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        var activities: [IndexActivity] = []
        let reference = WeakModelReference()
        let model = try uninstalledModel(clock: f.clock, diagnosticsURL: f.root.appendingPathComponent("handoff-audit.json"),
            startupActivityObserver: { activity in
                guard let model = reference.value else { return }
                activities.append(activity)
                XCTAssertTrue(!model.pendingRebuildForTesting || model.rebuildAcceptedForTesting,
                    "activity observes scheduler acceptance, not an unsubmitted rebuild")
                XCTAssertFalse(model.watcherStartupPendingForTesting)
                model.rebuildIndex()
            })
        reference.value = model
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attachForTesting(database: f.database, sources: [source])
        await model.refreshSummariesForTesting()
        model.settings.onboardingComplete = true
        try await prepareStartup(model, sources: [source])
        let claim = ReviewReadGate(), held = Task { await claim.wait() }
        defer { held.cancel(); Task { await claim.open() } }
        model.rebuildClaimGateForTesting = held
        model.rebuildIndex()
        try await wait { model.rebuildClaimWaitingForTesting }
        model.startReadyStartupForTesting(sources: [source])
        try await wait { activities.count == 1 }
        await claim.open()
        try await wait { model.progress.phase == .complete && !model.indexingPassActiveForTesting }
        XCTAssertEqual(activities, [.rebuild])
        XCTAssertFalse(model.pendingRebuildForTesting)
        let scheduler = try XCTUnwrap(model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let generation = await scheduler.generationForTesting
        XCTAssertEqual(generation, 2)
    }

    func testOnboardingDeferralBeforeEitherClaimRetainsRequestAndSettlesPreparation() async throws {
        let f = try await fixture(count: 2)
        let rows = f.model.sessions.map(\.id)
        let claim = ReviewReadGate(), held = Task { await claim.wait() }
        defer { held.cancel(); Task { await claim.open() } }
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.rebuildClaimGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.settings.onboardingComplete = false
        await claim.open()
        try await wait { !f.model.isPreparingRebuild }
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
        XCTAssertEqual(f.model.sessions.map(\.id), rows)
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 0)
        f.model.settings.onboardingComplete = true
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let generation = await scheduler.generationForTesting
        XCTAssertEqual(generation, 1)
    }

    func testStartupAbortedBeforeClaimDoesNotResetRowsOrAudit() async throws {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        var activities: [IndexActivity] = []
        let model = try uninstalledModel(clock: f.clock, diagnosticsURL: f.root.appendingPathComponent("aborted-audit.json"),
            startupActivityObserver: { activities.append($0) })
        let source = ClaudeCodeSource(roots: [f.root])
        await model.attachForTesting(database: f.database, sources: [source])
        await model.refreshSummariesForTesting()
        let rows = model.sessions
        model.settings.onboardingComplete = true
        try await prepareStartup(model, sources: [source])
        model.startReadyStartupForTesting(sources: [source])
        let handoff = try XCTUnwrap(model.startupHandoffIDForTesting)
        model.settings.onboardingComplete = false
        try await wait { model.completedStartupHandoffsForTesting.contains(handoff) }
        XCTAssertEqual(model.sessions.map(\.id), rows.map(\.id))
        XCTAssertTrue(activities.isEmpty)
        XCTAssertEqual((try model.startupSubmissionsForTesting(in: model.startupReceiptScopeForTesting())).count, 0)
        model.settings.onboardingComplete = true
        model.startReadyStartupForTesting(sources: [source])
        try await wait { activities.count == 1 && model.progress.phase == .complete }
        XCTAssertEqual(activities, [.launchReconciliation])
    }

    func testPreparationCommitsFreshProgressAndRetainsRollupOwnership() async throws {
        let f = try await fixture(count: 2)
        var old = IndexProgress(phase: .failed, completedFiles: 5, totalFiles: 10, currentPath: "/old/path", error: "old error")
        old.currentFileTotalBytes = 999; old.metadataWarning = "old metadata"
        old.unresolvedFailedFiles = 3; old.unresolvedDiscoveryFailures = 2
        old.rollupError = "Could not update token totals."
        f.model.setPublishedProgressForTesting(old)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.settings.onboardingComplete = true
        f.model.rebuildSubmissionGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let preparing = f.model.progress
        XCTAssertEqual(preparing.phase, .waiting)
        XCTAssertEqual(preparing.passID, old.passID)
        XCTAssertEqual(preparing.activity, .rebuild)
        XCTAssertEqual(preparing.completedFiles, 0)
        XCTAssertEqual(preparing.totalFiles, 0)
        XCTAssertNil(preparing.currentPath)
        XCTAssertNil(preparing.error)
        XCTAssertNil(preparing.metadataWarning)
        XCTAssertEqual(preparing.unresolvedFailedFiles, 3)
        XCTAssertEqual(preparing.unresolvedDiscoveryFailures, 2)
        XCTAssertEqual(preparing.rollupError, old.rollupError)
        f.model.settings.onboardingComplete = false
        await gate.open()
        try await wait { !f.model.isPreparingRebuild }
        XCTAssertEqual(f.model.progress.phase, .waiting)
        XCTAssertFalse(f.model.indexingPassActiveForTesting)
        XCTAssertTrue(f.model.pendingRebuildForTesting)
    }

    func testDeferredSettlementCommitsBeforeReentrantOnboardingAndRebuild() async throws {
        for grouped in [false, true] {
            for action in 0..<4 {
                let f = try await fixture(count: 2)
                var old = IndexProgress(phase: .failed)
                old.unresolvedFailedFiles = 7
                f.model.setPublishedProgressForTesting(old)
                var observed = false
                let observe = {
                    guard !observed, f.model.progress.phase == .waiting else { return }
                    observed = true
                    XCTAssertEqual(f.model.progress.unresolvedFailedFiles, 7)
                    switch action {
                    case 0:
                        f.model.settings.onboardingComplete = true
                        f.model.rebuildIndex()
                    case 1: f.model.reloadSourcesAndRebuild()
                    case 2: f.model.beginTerminationForTesting()
                    default: f.model.rebuildIndex() // Still deferred: rejected.
                    }
                }
                let token = grouped ? f.model.progressChanges.dropFirst().sink { _ in observe() }
                    : f.model.objectWillChange.sink { observe() }
                defer { token.cancel() }
                _ = await f.model.startWatchingForTesting([ClaudeCodeSource(roots: [f.root])])
                XCTAssertTrue(observed)
                switch action {
                case 0:
                    try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
                    XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
                    XCTAssertFalse(f.model.pendingRebuildForTesting)
                case 1:
                    try await wait { f.model.pendingAttachmentTokenForTesting == nil && f.model.schedulerForTesting != nil }
                    XCTAssertEqual(f.model.progress.phase, .waiting)
                case 2: XCTAssertTrue(f.model.isTerminatingForTesting)
                default:
                    XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
                    XCTAssertFalse(f.model.pendingRebuildForTesting)
                }
                XCTAssertFalse(f.model.isPreparingRebuild)
            }
        }
    }

    func testStartupClaimCannotBeRetiredByExplicitSubmitter() async throws {
        let f = try await fixture(count: 2)
        let claim = ReviewReadGate(), claimed = Task { await claim.wait() }
        let submission = ReviewReadGate(), held = Task { await submission.wait() }
        defer { claimed.cancel(); held.cancel(); Task { await claim.open(); await submission.open() } }
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.rebuildClaimGateForTesting = claimed
        f.model.rebuildSubmissionGateForTesting = held
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        let owner = try XCTUnwrap(f.model.rebuildAdmissionIDForTesting)
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        await claim.open()
        try await wait { !f.model.rebuildClaimWaitingForTesting }
        XCTAssertEqual(f.model.rebuildAdmissionIDForTesting, owner)
        XCTAssertTrue(f.model.isPreparingRebuild)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
        await submission.open()
        try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
        XCTAssertFalse(f.model.watcherStartupPendingForTesting)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        XCTAssertFalse(f.model.isPreparingRebuild)
    }

    func testSupersededStartupRebuildPreservesItsBufferedHandoff() async throws {
        let f = try await fixture(count: 2)
        let claim = ReviewReadGate(), claimed = Task { await claim.wait() }
        let first = ReviewReadGate(), firstHeld = Task { await first.wait() }
        let second = ReviewReadGate(), secondHeld = Task { await second.wait() }
        let third = ReviewReadGate(), thirdHeld = Task { await third.wait() }
        let payload = ReviewReadGate(), payloadHeld = Task { await payload.wait() }
        defer {
            claimed.cancel(); firstHeld.cancel(); secondHeld.cancel(); thirdHeld.cancel(); payloadHeld.cancel()
            Task { await claim.open(); await first.open(); await second.open(); await third.open(); await payload.open() }
        }
        let path = f.root.appendingPathComponent("sessions.jsonl").path
        var changes = SourceChanges()
        changes.paths = [path]; changes.reconciliationPaths = [f.root.path]
        changes.watermarks = ["startup": 42]; changes.streamRoots = ["startup": [f.root.path]]
        let recovery = IndexRecoveryWork(filePaths: [path], reconciliationPaths: [f.root.path])
        f.model.settings.onboardingComplete = true
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.queueStartupWorkForTesting(changes, recovery: recovery)
        f.model.rebuildClaimGateForTesting = claimed
        f.model.rebuildSubmissionGateForTesting = firstHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildClaimWaitingForTesting }
        f.model.startupPayloadGateForTesting = payloadHeld
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        await claim.open()
        try await wait { !f.model.rebuildClaimWaitingForTesting }
        for gate in [secondHeld, thirdHeld] {
            f.model.rebuildSubmissionGateForTesting = gate
            let previous = f.model.rebuildAdmissionIDForTesting
            f.model.rebuildIndex()
            try await wait { f.model.rebuildAdmissionIDForTesting != previous && f.model.rebuildSubmissionWaitingForTesting }
        }
        let newest = f.model.rebuildAdmissionIDForTesting
        changes.watermarks = ["startup": 99]
        f.model.queueStartupWorkForTesting(changes)
        await first.open(); await payload.open()
        try await wait { !f.model.watcherStartupPendingForTesting }
        XCTAssertEqual(f.model.rebuildAdmissionIDForTesting, newest)
        XCTAssertTrue(f.model.isPreparingRebuild)
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
        let handoff = try XCTUnwrap((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).first)
        XCTAssertEqual(handoff.bufferedPaths, [path])
        XCTAssertEqual(handoff.bufferedReconciliationPaths, [f.root.path])
        XCTAssertEqual(handoff.bufferedWatermarks["startup"], 99)
        XCTAssertEqual(handoff.bufferedStreamRoots["startup"], [f.root.path])
        XCTAssertTrue(handoff.watermarks.allSatisfy { handoff.bufferedWatermarks[$0.key] == $0.value })
        XCTAssertEqual(handoff.streamRoots, handoff.bufferedStreamRoots)
        XCTAssertEqual(handoff.recoveryPaths, recovery.filePaths)
        XCTAssertEqual(handoff.recoveryReconciliationPaths, recovery.reconciliationPaths)
        await second.open(); await third.open()
        try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        await scheduler.waitUntilIdle()
        let previousPass = f.model.progress.passID
        let file = URL(fileURLWithPath: path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: line(999)); try handle.close()
        var later = SourceChanges(); later.paths = [path]
        await f.model.bufferSourceChangesForTesting(later)
        try await wait { f.model.activeIndexPassIDForTesting != nil || f.model.progress.passID != previousPass }
        await scheduler.waitUntilIdle()
        XCTAssertFalse(f.model.watcherStartupPendingForTesting)
        let rows = try await f.database.sessions(limit: 100)
        XCTAssertEqual(rows.count, 7)
    }

    func testSupersededTerminalRetiresItsOwnActivePass() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        var old = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(old)
        f.model.sourceChangeAttachmentGateForTesting = held
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        let event = f.model.usageRecoveryEventForTesting
        old.phase = .cancelled
        await f.model.receiveProgress(old)
        XCTAssertNil(f.model.activeIndexPassIDForTesting)
        XCTAssertTrue(f.model.indexingPassActiveForTesting, "the pending replacement still owns the workflow")
        XCTAssertEqual(f.model.usageRecoveryEventForTesting, event)
        await gate.open()
        try await wait { f.model.pendingAttachmentTokenForTesting == nil && !f.model.indexingPassActiveForTesting }
    }

    func testSearchDemandSurvivesReentrantSourceRecovery() async throws {
        for main in [false, true] {
            for failed in [false, true] {
                let f = try await fixture(count: 2)
                let search = main ? f.model.mainSearch : f.model.globalSearch
                if main { f.model.setMainWindowVisible(true); f.model.setMainSearchPanelVisible(true) }
                else { f.model.setGlobalSearchSurface(.popover, visible: true) }
                search.query = "NavigationNeedle"
                if main { f.model.searchMain() } else { f.model.search() }
                await f.clock.advance(by: .milliseconds(100))
                try await wait { !search.isSearching && !search.results.isEmpty }
                let revision = search.automaticResultRevision
                var mutation = IndexProgress(phase: .indexing); mutation.mutationRevision = 1
                var observed = false
                let token = f.model.objectWillChange.sink {
                    guard !observed, f.model.progress.passID == mutation.passID else { return }
                    observed = true
                    f.model.failSourceConfigurationForTesting = failed
                    f.model.reloadSourcesAndRebuild()
                }
                defer { token.cancel() }
                await f.model.receiveProgress(mutation)
                XCTAssertTrue(observed)
                try await wait { search.isSearching }
                await f.clock.advance(by: .milliseconds(100))
                try await wait { search.automaticResultRevision == revision + 1 }
                try await wait { f.model.pendingAttachmentTokenForTesting == nil }
                XCTAssertEqual(f.model.sourceReloadRecovery.error != nil, failed)
                XCTAssertFalse(search.results.isEmpty)
                // Further mutations coalesce under the existing one-second throttle.
                for index in 2...3 {
                    mutation.mutationRevision = index
                    mutation.incremental = true
                    await f.model.receiveProgress(mutation)
                }
                await f.clock.advance(by: .milliseconds(899))
                XCTAssertEqual(search.automaticResultRevision, revision + 1)
                await f.clock.advance(by: .milliseconds(1))
                await f.clock.advance(by: .milliseconds(100))
                try await wait { search.automaticResultRevision == revision + 2 }
            }
        }
    }

    func testPreparationPresentationDoesNotUseDisplacedFailureProgress() {
        var progress = IndexProgress(phase: .failed)
        progress.error = "old pass failure"; progress.metadataWarning = "old metadata"
        progress.currentPath = "/old/path"; progress.projectName = "Old project"; progress.agent = .codex
        progress.totalFiles = 123; progress.currentFileBytes = 456; progress.currentFileTotalBytes = 789
        progress.unresolvedFailedFiles = 3; progress.rollupError = "old rollup"
        let label = IndexProgressLabel(progress: progress, monitoringWarnings: ["Current monitor warning"], preparingRebuild: true)
        XCTAssertEqual(label.statusColor, .secondary)
        XCTAssertEqual(label.details, "Preparing the index rebuild…\n3 files still failing\nCurrent monitor warning\nToken totals: Could not update token totals.")
        let paused = IndexProgressLabel(progress: progress, sourceReloadRecovery: .failed("Source settings failed"), preparingRebuild: true)
        XCTAssertEqual(paused.statusColor, .red)
        XCTAssertTrue(paused.details.hasPrefix("Live updates are paused."))
        XCTAssertTrue(paused.details.contains("The index rebuild is waiting for source settings."))
        XCTAssertTrue(paused.details.contains("3 files still failing"))
        XCTAssertFalse(paused.details.contains("Preparing the index rebuild…"))
        XCTAssertTrue(paused.details.contains("Source settings failed"))
        XCTAssertFalse(paused.details.contains("old pass"))
        XCTAssertTrue(IndexProgressLabel(progress: progress).details.contains("/old/path"))
    }

    func testRunningPassCannotRefillSidebarBeforeRebuildSubmission() async throws {
        let f = try await fixture(count: 430)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let oldProgress = ReviewReadGate(), oldHeld = Task { await oldProgress.wait() }
        let submission = ReviewReadGate(), submitted = Task { await submission.wait() }
        let preparation = ReviewReadGate(), prepared = Task { await preparation.wait() }
        defer {
            oldHeld.cancel(); submitted.cancel(); prepared.cancel()
            Task { await oldProgress.open(); await submission.open(); await preparation.open() }
        }
        f.model.schedulerProgressGateForTesting = oldHeld
        await scheduler.request(reconcile: true)
        try await wait { f.model.schedulerProgressWaitingForTesting }
        let oldPass = try XCTUnwrap(f.model.schedulerProgressPassForTesting)
        let reads = await f.database.sessionListReadCountForTesting()
        await f.clock.advance(by: .seconds(1))
        f.model.rebuildSubmissionGateForTesting = submitted
        f.model.settings.onboardingComplete = true
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let workflow = f.model.workflowGenerationForTesting, event = f.model.usageRecoveryEventForTesting
        XCTAssertTrue(f.model.isPreparingRebuild)
        XCTAssertTrue(f.model.projects.isEmpty)
        XCTAssertEqual(f.model.totalSessionCount, 0)
        f.model.schedulerProgressGateForTesting = nil
        await oldProgress.open()
        try await wait { f.model.admissionWaitingPassesForTesting.contains(oldPass) }
        XCTAssertTrue(f.model.sessions.isEmpty)
        let beforeSubmission = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(beforeSubmission, reads)
        XCTAssertEqual(f.model.workflowGenerationForTesting, workflow)
        XCTAssertEqual(f.model.usageRecoveryEventForTesting, event)
        // Preparation belongs to the replacement: the old pass has already passed it.
        await coordinator.gatePreparationForTesting(prepared)
        await submission.open()
        try await wait { await coordinator.preparationWaitingForTesting }
        XCTAssertTrue(f.model.isPreparingRebuild)
        XCTAssertFalse(f.model.admissionWaitingPassesForTesting.contains(oldPass))
        XCTAssertTrue(f.model.sessions.isEmpty)
        let duringPreparation = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(duringPreparation, reads)
        await preparation.open()
        try await wait {
            f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting && !f.model.projects.isEmpty
        }
        XCTAssertFalse(f.model.isPreparingRebuild)
        XCTAssertEqual(f.model.usageRecoveryEventForTesting, event + 1)
        XCTAssertFalse(f.model.projects.isEmpty)
    }

    func testOlderSubmissionCannotOpenNewerRebuildAdmission() async throws {
        let f = try await fixture(count: 2)
        let first = ReviewReadGate(), firstHeld = Task { await first.wait() }
        let second = ReviewReadGate(), secondHeld = Task { await second.wait() }
        defer { firstHeld.cancel(); secondHeld.cancel(); Task { await first.open(); await second.open() } }
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        f.model.settings.onboardingComplete = true
        f.model.rebuildSubmissionGateForTesting = firstHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let firstOwner = try XCTUnwrap(f.model.rebuildAdmissionIDForTesting)
        f.model.rebuildSubmissionGateForTesting = secondHeld
        f.model.rebuildIndex()
        try await wait { f.model.rebuildSubmissionWaitingForTesting }
        let workflow = f.model.workflowGenerationForTesting
        await first.open()
        try await wait { f.model.completedRebuildSubmissionsForTesting.contains(firstOwner) }
        let admitted = await scheduler.generationForTesting
        XCTAssertEqual(admitted, 0)
        XCTAssertTrue(f.model.isPreparingRebuild)
        XCTAssertTrue(f.model.rebuildSubmissionWaitingForTesting)
        XCTAssertEqual(f.model.workflowGenerationForTesting, workflow)
        await second.open()
        try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        let final = await scheduler.generationForTesting
        XCTAssertEqual(final, 1)
        XCTAssertFalse(f.model.isPreparingRebuild)
    }

    func testAttachmentAndTerminationRetireWaitingRebuildProgress() async throws {
        for terminate in [false, true] {
            let f = try await fixture(count: 2)
            let submission = ReviewReadGate(), held = Task { await submission.wait() }
            defer { held.cancel(); Task { await submission.open() } }
            f.model.settings.onboardingComplete = true
            f.model.rebuildSubmissionGateForTesting = held
            f.model.rebuildIndex()
            try await wait { f.model.rebuildSubmissionWaitingForTesting }
            let pass = IndexProgress(phase: .indexing)
            let progress = Task { await f.model.receiveProgress(pass) }
            try await wait { f.model.admissionWaitingPassesForTesting.contains(pass.passID) }
            if terminate { await f.model.prepareToTerminate() }
            else {
                let replacement = try await fixture(count: 3)
                _ = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            }
            await submission.open(); await progress.value
            XCTAssertTrue(f.model.admissionWaitingPassesForTesting.isEmpty)
            XCTAssertFalse(f.model.isPreparingRebuild)
            XCTAssertNotEqual(f.model.progress.passID, pass.passID)
        }
    }

    func testAttachmentFailureCommitsRetirementBeforeReentrantRecovery() async throws {
        for grouped in [false, true] {
            for action in 0..<3 {
                let f = try await fixture(count: 2)
                f.model.settings.onboardingComplete = true
                f.model.failSourceConfigurationForTesting = true
                var observed = false
                let observe = {
                    guard !observed, case .failed = f.model.sourceReloadRecovery else { return }
                    observed = true
                    XCTAssertNil(f.model.pendingAttachmentTokenForTesting)
                    XCTAssertFalse(f.model.pendingRebuildForTesting)
                    XCTAssertFalse(f.model.indexingPassActiveForTesting)
                    f.model.failSourceConfigurationForTesting = false
                    switch action {
                    case 0: f.model.reloadSourcesAndRebuild()
                    case 1: f.model.rebuildIndex()
                    default: f.model.beginTerminationForTesting()
                    }
                }
                let token = grouped ? f.model.sidebarChanges.dropFirst().sink { _ in observe() }
                    : f.model.objectWillChange.sink { observe() }
                defer { token.cancel() }
                f.model.reloadSourcesAndRebuild()
                try await wait { observed }
                if action == 2 {
                    XCTAssertTrue(f.model.isTerminatingForTesting)
                    XCTAssertNil(f.model.pendingAttachmentTokenForTesting)
                } else {
                    try await wait { f.model.progress.phase == .complete && f.model.pendingAttachmentTokenForTesting == nil }
                    XCTAssertNotNil(f.model.schedulerForTesting)
                    XCTAssertNil(f.model.sourceReloadRecovery.error)
                    XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, action == 1 ? 1 : 0)
                }
            }
        }
    }

    func testRebuildIntentSurvivesSourceReloadAdmissionNotification() async throws {
        let f = try await fixture(count: 2)
        f.model.settings.onboardingComplete = true
        var queued = false
        let token = f.model.objectWillChange.sink {
            guard !queued, f.model.indexingPassActiveForTesting,
                  f.model.pendingAttachmentTokenForTesting == nil else { return }
            queued = true
            f.model.rebuildIndex()
        }
        defer { token.cancel() }
        f.model.reloadSourcesAndRebuild()
        try await wait { queued && f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        XCTAssertNotNil(f.model.schedulerForTesting)
        XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1)
        XCTAssertFalse(f.model.pendingRebuildForTesting)
    }

    func testAcceptedMutationIsRecordedBeforeReentrantStatusNotification() async throws {
        let f = try await fixture(count: 2)
        let generation = f.model.sidebarDataGenerationForTesting
        var seen = false
        var mutation = IndexProgress(phase: .indexing)
        mutation.mutationRevision = 1
        let token = f.model.objectWillChange.sink {
            guard !seen, f.model.progress.passID == mutation.passID else { return }
            seen = true
            XCTAssertNotEqual(f.model.sidebarDataGenerationForTesting, generation)
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
        }
        defer { token.cancel() }
        await f.model.receiveProgress(mutation)
        XCTAssertTrue(seen)
        try await wait { f.model.sourceReloadRecovery.error != nil }
    }

    func testSearchResetPreservesAutomaticCompletionRevision() async throws {
        let f = try await fixture(count: 2)
        let search = f.model.mainSearch
        search.query = "NavigationNeedle"
        search.search(trigger: .automatic)
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !search.isSearching && search.automaticResultRevision > 0 }
        let revision = search.automaticResultRevision
        search.resetForIndexReset()
        XCTAssertEqual(search.automaticResultRevision, revision)
        XCTAssertTrue(search.results.isEmpty)
        search.search(trigger: .automatic)
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !search.isSearching && !search.results.isEmpty }
        XCTAssertEqual(search.automaticResultRevision, revision + 1)
    }

    func testResetCommitsAllBackingStateBeforeReentrantNavigation() async throws {
        for surface in 0..<5 {
            let f = try await fixture(count: 430)
            await f.model.refreshSummariesForTesting(lightweight: false)
            try await search(f)
            f.model.globalSearch.query = "NavigationNeedle"
            f.model.search()
            await f.clock.advance(by: .milliseconds(100))
            try await wait { !f.model.globalSearch.isSearching }
            let current = try XCTUnwrap(f.model.sessions.first)
            let target = try XCTUnwrap(f.model.sessions.dropFirst().first)
            f.model.selectSession(current.id, preservingMainSearch: true)
            try await wait { !f.model.messages.isEmpty }
            var observed = false
            let observe = {
                guard !observed, f.model.selectedSessionID == nil, f.model.projects.isEmpty else { return }
                observed = true
                XCTAssertTrue(f.model.sessions.isEmpty)
                XCTAssertEqual(f.model.totalSessionCount, 0)
                XCTAssertNil(f.model.sessionCursorIDForTesting)
                XCTAssertEqual(f.model.sessionPageDepthForTesting, 1)
                XCTAssertFalse(f.model.isLoadingSessions)
                XCTAssertTrue(f.model.mainSearch.results.isEmpty)
                XCTAssertTrue(f.model.globalSearch.results.isEmpty)
                XCTAssertFalse(f.model.mainSearch.isSearching)
                XCTAssertTrue(f.model.sourceHealth.isEmpty)
                XCTAssertNil(f.model.statistics)
                XCTAssertNil(f.model.settings.lastSessionID)
                f.model.selectSession(target.id)
            }
            let subscription: AnyCancellable
            switch surface {
            case 0: subscription = f.model.objectWillChange.sink { observe() }
            case 1: subscription = f.model.transcriptChanges.dropFirst().sink { _ in observe() }
            case 2: subscription = f.model.sessionPageChanges.dropFirst().sink { _ in observe() }
            case 3: subscription = f.model.mainSearch.changes.dropFirst().sink { _ in observe() }
            default: subscription = f.model.settings.objectWillChange.sink { observe() }
            }
            defer { subscription.cancel() }
            XCTAssertTrue(f.model.resetIndexForTesting(), "selection changes do not supersede a database reset")
            XCTAssertTrue(observed)
            XCTAssertEqual(f.model.selectedSessionID, target.id)
            XCTAssertEqual(f.model.settings.lastSessionID, target.id)
            try await wait { f.model.selectedSession?.id == target.id && !f.model.messages.isEmpty }
        }
    }

    func testAttachmentResetNavigationUsesInstalledDatabaseAndScheduler() async throws {
        for objectNotification in [false, true] {
            let f = try await fixture(count: 430), replacement = try await fixture(count: 2)
            let target = try XCTUnwrap(replacement.model.sessions.first)
            var observed = false
            let observe = {
                guard !observed, f.model.databaseForTesting === replacement.database,
                      f.model.sessions.isEmpty else { return }
                observed = true
                XCTAssertNotNil(f.model.schedulerForTesting)
                XCTAssertTrue(f.model.coordinatorForTesting === replacement.coordinator)
                XCTAssertTrue(f.model.mainSearch.results.isEmpty)
                f.model.selectSession(target.id)
            }
            let subscription = objectNotification
                ? f.model.objectWillChange.sink { observe() }
                : f.model.transcriptChanges.dropFirst().sink { _ in observe() }
            defer { subscription.cancel() }
            let installed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            XCTAssertTrue(installed)
            XCTAssertTrue(observed)
            XCTAssertTrue(f.model.databaseForTesting === replacement.database)
            XCTAssertNotNil(f.model.schedulerForTesting)
            try await wait { f.model.selectedSession?.id == target.id && !f.model.messages.isEmpty }
            XCTAssertEqual(f.model.selectedSession?.sourcePath, target.sourcePath)
            XCTAssertEqual(f.model.settings.lastSessionID, target.id)
        }
    }

    func testRebuildCannotReloadOldSidebarDuringPreparation() async throws {
        let f = try await fixture(count: 430)
        let coordinator = try XCTUnwrap(f.model.coordinatorForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await coordinator.gatePreparationForTesting(held)
        let before = await f.database.sessionListReadCountForTesting()
        await f.clock.advance(by: .seconds(1))
        f.model.settings.onboardingComplete = true
        f.model.rebuildIndex()
        try await wait { await coordinator.preparationWaitingForTesting }
        XCTAssertTrue(f.model.projects.isEmpty)
        XCTAssertTrue(f.model.sessions.isEmpty)
        XCTAssertEqual(f.model.totalSessionCount, 0)
        await f.clock.advance(by: .seconds(1))
        let heldReads = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(heldReads, before, "pass admission must not read the pre-clear database")
        let generation = f.model.workflowGenerationForTesting
        let event = f.model.usageRecoveryEventForTesting
        // A second replacement cancels the held, not-yet-admitted operation.
        f.model.rebuildIndex()
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        try await wait { await scheduler.generationForTesting == 2 }
        await gate.open()
        try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
        await scheduler.waitUntilIdle()
        XCTAssertNotEqual(f.model.workflowGenerationForTesting, generation)
        XCTAssertEqual(f.model.usageRecoveryEventForTesting, event + 1,
                       "only the current replacement may produce terminal recovery")
        XCTAssertEqual(f.model.progress.activity, .rebuild)
        XCTAssertFalse(f.model.projects.isEmpty)
    }

    func testUsageControlTimeoutCannotBecomeAcceptedCostsFailure() async throws {
        let f = try await fixture(count: 2)
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.loadCachedUsageForTesting()
        let before = f.model.usageAttemptReceiptsForTesting.count
        let cached = f.model.usage.map(\.inputTokens)
        f.model.usageControlErrorForTesting = NSError(domain: "TraceTestHooks", code: 1)
        f.model.retryCosts()
        try await wait { !f.model.usageControlFailuresForTesting.isEmpty && !f.model.costsTotalsUpdating }
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.count, before)
        XCTAssertEqual(f.model.costsError, "Could not load cached token totals.")
        XCTAssertEqual(f.model.usage.map(\.inputTokens), cached)
        XCTAssertTrue(f.model.canRetryCosts)
        f.model.retryCosts()
        try await wait { f.model.costsError == nil && !f.model.costsTotalsUpdating }
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.dropFirst(before).map(\.outcome), [.success])
    }

    func testAppendDoesNotRepeatAnUnchangedMissingSelectionEnsure() async throws {
        let f = try await fixture(count: 1_405)
        f.model.setUnresolvedSelectionForTesting(Int64.max)
        let before = await f.database.sessionListReadCountForTesting()
        for depth in 2...4 {
            f.model.loadMoreSessions()
            try await wait { !f.model.isLoadingSessions && f.model.sessionPageDepthForTesting == depth }
            XCTAssertEqual(f.model.sessions.count, depth * 200)
            XCTAssertEqual(f.model.totalSessionCount, 1_409)
            XCTAssertNil(f.model.sessionListError)
        }
        let attempts = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(attempts, before + 1, "only the first append needs a full missing-row ensure")
        var mutation = IndexProgress(phase: .indexing)
        mutation.incremental = true
        mutation.mutationRevision = 1
        await f.model.receiveProgress(mutation)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions && f.model.sessionPageDepthForTesting == 5 }
        let afterMutation = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(afterMutation, attempts + 1, "a new data generation permits another ensure")
        let expected = try await f.database.sessionListSnapshot(projectCanonicalKey: nil, pageCount: 5)
        XCTAssertEqual(f.model.sessions.map(\.id), expected.sessions.map(\.id))
        XCTAssertEqual(f.model.sessionCursorIDForTesting, expected.nextCursor?.sessionID)
    }

    func testStartupRecoveryLoadFailureUsesSafeTextAndPrivateDiagnostic() async throws {
        let f = try await fixture(count: 2)
        let model = try uninstalledModel(clock: f.clock, diagnosticsURL: f.root.appendingPathComponent("startup-safe.json"))
        model.initialDatabaseForTesting = f.database
        model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        model.recoveryLoadErrorForTesting = DatabaseError(resultCode: .SQLITE_BUSY,
            message: "private-recovery-message", sql: "SELECT 'private-recovery-sql'",
            arguments: ["private-recovery-argument"], publicStatementArguments: true)
        var diagnostics: [TraceModel.SummaryReadFailure] = []
        model.summaryReadFailureForTesting = { diagnostics.append($0) }
        model.start()
        try await wait { model.coordinatorForTesting != nil && model.startupError != nil }
        XCTAssertEqual(model.startupError,
            "Could not load pending index recovery; a safe root scan was queued. Could not update the index. Try again.")
        XCTAssertFalse(model.startupError?.contains("private-") == true)
        XCTAssertEqual(diagnostics.filter { $0.operation == .indexStatus }.map(\.primaryCode), [ResultCode.SQLITE_BUSY.rawValue])
    }

    func testDeletedSelectionDoesNotForceAFullReadAfterEveryAppend() async throws {
        let f = try await fixture(count: 1_005)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let selected = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(selected.id)
        try await wait { f.model.selectedSession?.id == selected.id && !f.model.messages.isEmpty }
        let raw = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
        try await raw.write { try $0.execute(sql: "DELETE FROM session WHERE id=?", arguments: [selected.id]) }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryTranscriptGateForTesting = held
        let refresh = Task { await f.model.refreshSummariesForTesting() }
        try await wait { f.model.summaryTranscriptWaitingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, selected.id, "hold deletion confirmation after page acceptance")
        XCTAssertFalse(f.model.sessions.contains { $0.id == selected.id })
        let before = await f.database.sessionListReadCountForTesting()
        for depth in 2...4 {
            f.model.loadMoreSessions()
            try await wait { !f.model.isLoadingSessions && f.model.sessionPageDepthForTesting == depth }
            XCTAssertFalse(f.model.sessions.contains { $0.id == selected.id })
            XCTAssertEqual(f.model.totalSessionCount, 1_004)
            XCTAssertNil(f.model.sessionListError)
        }
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, before, "the accepted missing ensure covers later appends until data or selection changes")
        f.model.summaryTranscriptGateForTesting = nil
        await gate.open(); await refresh.value
        XCTAssertNil(f.model.selectedSessionID)
    }

    func testTerminalFirstReplacementFailureRetiresItsDisplacedActivePass() async throws {
        let f = try await fixture(count: 2)
        await f.model.receiveProgress(.init(phase: .indexing))
        XCTAssertNotNil(f.model.activeIndexPassIDForTesting)
        let event = f.model.usageRecoveryEventForTesting
        await f.database.failScopeReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.settings.onboardingComplete = true
        f.model.rebuildIndex()
        try await wait { f.model.progress.phase == .failed && !f.model.indexingPassActiveForTesting }
        XCTAssertNil(f.model.activeIndexPassIDForTesting)
        XCTAssertEqual(f.model.usageRecoveryEventForTesting, event + 1)
        XCTAssertEqual(f.model.progress.error, "Could not update the index. Try again.")
    }

    func testResetCannotContinueAfterReentrantWorkflowAttachmentOrTermination() async throws {
        for action in 0..<3 {
            let f = try await fixture(count: 2)
            f.model.settings.onboardingComplete = true
            var observed = false
            let subscription = f.model.objectWillChange.sink {
                guard !observed, f.model.projects.isEmpty, f.model.sessions.isEmpty else { return }
                observed = true
                XCTAssertNil(f.model.sessionCursorIDForTesting)
                XCTAssertEqual(f.model.totalSessionCount, 0)
                XCTAssertTrue(f.model.mainSearch.results.isEmpty)
                switch action {
                case 0: f.model.rebuildIndex()
                case 1: f.model.reloadSourcesAndRebuild()
                default: f.model.beginTerminationForTesting()
                }
            }
            defer { subscription.cancel() }
            f.model.rebuildIndex()
            try await wait { observed }
            if action == 2 {
                XCTAssertTrue(f.model.isTerminatingForTesting)
                XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 0)
                XCTAssertTrue(f.model.sessions.isEmpty)
                XCTAssertNil(f.model.sessionCursorIDForTesting)
            } else {
                try await wait { f.model.progress.phase == .complete && !f.model.indexingPassActiveForTesting }
                XCTAssertNotNil(f.model.schedulerForTesting)
                XCTAssertNil(f.model.pendingAttachmentTokenForTesting)
                XCTAssertEqual(f.model.rebuildSubmissionCountForTesting, 1,
                               "the successor must submit the retained same-database rebuild exactly once")
                XCTAssertFalse(f.model.pendingRebuildForTesting)
                let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
                await scheduler.waitUntilIdle()
                let generation = await scheduler.generationForTesting
                XCTAssertEqual(generation, 1)
            }
        }
    }

    private func prepareStartup(_ model: TraceModel, sources: [any SessionSource],
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let ready = await model.startWatchingForTesting(sources)
        XCTAssertTrue(ready, "startup fixtures require a real ready watcher", file: file, line: line)
        guard ready else { throw CancellationError() }
    }

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
        model.collectsStartupHandoffsForTesting = true
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

    private func wait(_ condition: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(try await condition()) {
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
        model.collectsStartupHandoffsForTesting = true
        return model
    }

    private func restorationFixture(count: Int = 2) async throws -> (Fixture, SessionSummary) {
        let f = try await fixture(count: count)
        let saved = try XCTUnwrap(f.model.sessions.first)
        await f.model.prepareToTerminate()
        let model = try uninstalledModel(clock: f.clock,
            diagnosticsURL: f.root.appendingPathComponent("lookup-restoration.json"), savedSessionID: saved.id)
        let source = ClaudeCodeSource(roots: [f.root])
        let coordinator = IndexCoordinator(database: f.database, sources: [source], clock: f.clock)
        let committed = await model.attach(database: f.database, coordinator: coordinator)
        XCTAssertTrue(committed)
        model.sourceReloadSourcesForTesting = [source]
        return (.init(root: f.root, clock: f.clock, model: model, database: f.database,
                      coordinator: coordinator, project: f.project), saved)
    }

    func testTranscriptAndStatusPublishersReplaySafelyDuringNotification() async throws {
        let f = try await fixture(count: 2), target = f.model.sessions[0]
        var transcriptObserved = false, statusObserved = false
        let subscription = f.model.objectWillChange.sink {
            do {
                if !statusObserved, f.model.progress.phase == .complete {
                    statusObserved = true
                    let current = try self.backgroundSubscription(ReviewPublisher(publisher: f.model.progressChanges.prefix(1).eraseToAnyPublisher())) {
                        XCTAssertFalse(Thread.isMainThread)
                        XCTAssertEqual($0.phase, .complete)
                    }
                    withExtendedLifetime(current) {}
                }
                if !transcriptObserved, f.model.selectedSessionID == target.id, !f.model.messages.isEmpty {
                    transcriptObserved = true
                    let current = try self.backgroundSubscription(ReviewPublisher(publisher: f.model.transcriptChanges.prefix(1).eraseToAnyPublisher())) {
                        XCTAssertFalse(Thread.isMainThread)
                        XCTAssertEqual($0.sessionID, target.id)
                        XCTAssertEqual($0.session?.id, target.id)
                        XCTAssertEqual($0.messages.count, target.messageCount)
                    }
                    withExtendedLifetime(current) {}
                }
            } catch { XCTFail("Subscription failed: \(error)") }
        }
        defer { subscription.cancel() }
        f.model.publishProgressForTesting(.init(phase: .complete))
        f.model.selectSession(target.id)
        try await wait { transcriptObserved && statusObserved }
    }

    func testTranscriptCommitReentryReplacementAndTerminationCannotRestoreOldSelection() async throws {
        for replacing in [false, true] {
            let f = try await fixture(count: 3), replacement = try await fixture(count: 2)
            let target = f.model.sessions[0]
            var action: Task<Void, Never>?
            let subscription = f.model.objectWillChange.sink {
                guard action == nil, f.model.selectedSession?.id == target.id, !f.model.messages.isEmpty else { return }
                // Mark first, because clearing also notifies synchronously.
                action = Task { }
                f.model.clearSession()
                action = Task {
                    if replacing {
                        let committed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
                        XCTAssertTrue(committed)
                    } else { await f.model.prepareToTerminate() }
                }
            }
            defer { subscription.cancel() }
            f.model.selectSession(target.id)
            try await wait { action != nil }
            await action?.value
            XCTAssertNil(f.model.selectedSessionID)
            XCTAssertNil(f.model.selectedSession)
            XCTAssertTrue(f.model.messages.isEmpty)
            XCTAssertTrue(f.model.hydratedMessages.isEmpty)
            if replacing { XCTAssertTrue(f.model.databaseForTesting === replacement.database) }
            else { XCTAssertTrue(f.model.terminationStartedForTesting) }
        }
    }

    func testTranscriptCommitCannotOverwriteReentrantSelectionOrNavigation() async throws {
        for objectNotification in [false, true] {
            for navigation in 0..<3 {
                let f = try await fixture(count: 5)
                let target = f.model.sessions[0], next = f.model.sessions[1]
                let targetRows = try await f.database.messages(sessionID: target.id)
                let nextRows = try await f.database.messages(sessionID: next.id)
                let otherProject = try XCTUnwrap(f.model.projects.first { $0.id != target.projectID })
                var observed = false
                let observe = {
                    guard !observed, f.model.selectedSession?.id == target.id,
                          !f.model.messages.isEmpty else { return }
                    observed = true
                    XCTAssertEqual(f.model.selectedSessionID, target.id)
                    XCTAssertEqual(f.model.messages.map(\.id), targetRows.map(\.id))
                    if navigation == 0 { f.model.selectSession(next.id) }
                    else if navigation == 1 { f.model.clearSession() }
                    else { f.model.selectProject(otherProject.id) }
                }
                let subscription = objectNotification
                    ? f.model.objectWillChange.sink { observe() }
                    : f.model.transcriptChanges.dropFirst().sink { _ in observe() }
                defer { subscription.cancel() }
                f.model.selectSession(target.id)
                try await wait { observed && (navigation == 0 ? f.model.messages.map(\.id) == nextRows.map(\.id) : f.model.selectedSessionID == nil) }
                if navigation == 0 {
                    XCTAssertEqual(f.model.selectedSession?.id, next.id)
                    XCTAssertEqual(f.model.selectedSessionID, next.id)
                } else {
                    XCTAssertNil(f.model.selectedSession)
                    XCTAssertTrue(f.model.messages.isEmpty)
                    if navigation == 2 { XCTAssertEqual(f.model.selectedProjectID, otherProject.id) }
                }
            }
        }
    }

    func testHydrationCommitCannotRestoreCacheAfterReentrantSelection() async throws {
        for objectNotification in [false, true] {
            let f = try await fixture(count: 3), target = f.model.sessions[0], next = f.model.sessions[1]
            f.model.selectSession(target.id)
            try await wait { !f.model.messages.isEmpty }
            let message = try XCTUnwrap(f.model.messages.first)
            var observed = false
            let observe = {
                guard !observed, f.model.hydratedMessages[message.id] != nil else { return }
                observed = true
                f.model.selectSession(next.id)
            }
            let subscription = objectNotification
                ? f.model.objectWillChange.sink { observe() }
                : f.model.transcriptChanges.dropFirst().sink { _ in observe() }
            defer { subscription.cancel() }
            f.model.hydrate(message)
            try await wait { observed && f.model.selectedSession?.id == next.id && !f.model.messages.isEmpty }
            XCTAssertTrue(f.model.hydratedMessages.isEmpty)
            XCTAssertTrue(f.model.hydrationFailures.isEmpty)
        }
    }

    func testProgressCommitPreservesReentrantStatusWrite() async throws {
        for objectNotification in [false, true] {
            let f = try await fixture(count: 2)
            var observed = false
            let observe = {
                guard !observed, f.model.progress.phase == .complete else { return }
                observed = true
                f.model.publishProgressForTesting(.init(phase: .failed, error: "newer-status"))
            }
            let subscription = objectNotification
                ? f.model.objectWillChange.sink { observe() }
                : f.model.progressChanges.dropFirst().sink { _ in observe() }
            defer { subscription.cancel() }
            f.model.publishProgressForTesting(.init(phase: .complete))
            XCTAssertTrue(observed)
            XCTAssertEqual(f.model.progress.phase, .failed)
            XCTAssertEqual(f.model.progress.error, "newer-status")
        }
    }

    func testCommittedUsageReceiptsSurviveReentrantNewDemand() async throws {
        for objectNotification in [false, true] {
            for fails in [false, true] {
                let (f, _) = try await twoRootUsageFixture()
                await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
                await f.model.loadCachedUsageForTesting()
                if fails { await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY)) }
                let before = f.model.usageAttemptReceiptsForTesting.count
                var observed = false
                let observe = {
                    let expected = fails ? "Could not update token totals." : nil
                    guard !observed, f.model.costsError == expected else { return }
                    observed = true
                    XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.count, before + 1,
                                   "receipt must exist before a committed outcome notifies observers")
                    f.model.requestUsageRefreshForTesting(repair: false, immediately: true)
                }
                let subscription = objectNotification
                    ? f.model.objectWillChange.sink { observe() }
                    : f.model.costsChanges.dropFirst().sink { _ in observe() }
                defer { subscription.cancel() }
                f.model.retryCosts()
                try await wait { observed && !f.model.costsTotalsUpdating }
                XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.dropFirst(before).map(\.outcome),
                               [fails ? .failure : .success, .success])
                XCTAssertNil(f.model.costsError)
            }
        }
    }

    func testAcceptedCostsRepairClearsOnlyItsMatchingRollupStatusBeforeNotification() async throws {
        for newerFailure in [false, true] {
            let f = try await fixture(count: 2)
            await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            var failedPass = IndexProgress(phase: .complete)
            failedPass.rollupError = "Could not update token totals."
            await f.model.receiveProgress(failedPass)
            await f.clock.advance(by: .seconds(1))
            try await wait { f.model.canRetryCosts }
            XCTAssertNotNil(f.model.progress.rollupError)
            var observed = false
            let subscription = f.model.costsChanges.dropFirst().sink { state in
                guard !observed, state.error == nil else { return }
                observed = true
                XCTAssertNil(f.model.progress.rollupError)
                if newerFailure {
                    var newer = IndexProgress(phase: .complete)
                    newer.rollupError = "newer-rollup-failure"
                    f.model.publishProgressForTesting(newer)
                }
            }
            defer { subscription.cancel() }
            f.model.retryCosts()
            try await wait { observed && !f.model.costsTotalsUpdating }
            XCTAssertNil(f.model.costsError)
            XCTAssertEqual(f.model.progress.rollupError, newerFailure ? "newer-rollup-failure" : nil)
            if !newerFailure {
                XCTAssertFalse(IndexProgressLabel(progress: f.model.progress).details.contains("Token totals:"))
            }
        }
    }

    func testEarlyFailedOrCancelledRebuildRetainsCostsDebtForProductionRetry() async throws {
        for cancelled in [false, true] {
            let (f, _) = try await twoRootUsageFixture()
            await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            await f.model.loadCachedUsageForTesting()
            let before = await f.database.usageReadCountForTesting()
            f.model.settings.onboardingComplete = true
            let error: Error = cancelled ? CancellationError() : DatabaseError(resultCode: .SQLITE_BUSY)
            await f.database.failScopeReadOnceForTesting(error)
            await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            f.model.rebuildIndex()
            try await wait { f.model.progress.phase == (cancelled ? .cancelled : .failed) && f.model.canRetryCosts }
            XCTAssertTrue(f.model.usageDemandOwedForTesting)
            XCTAssertFalse(f.model.costsTotalsUpdating)
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
            f.model.retryCosts(); f.model.retryCosts()
            try await wait { !f.model.costsTotalsUpdating }
            XCTAssertNil(f.model.costsError)
            let after = await f.database.usageReadCountForTesting()
            XCTAssertEqual(after, before + 2, "one terminal recovery plus one explicit Retry")
        }
    }

    func testAppendCompletionEnsuresSelectionResolvedWhilePageWasLoading() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let matches = try await f.database.search(query: "NavigationNeedle", filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000).results
        let target = try XCTUnwrap(matches.last)
        XCTAssertFalse(f.model.sessions.contains { $0.id == target.sessionID })
        let transcript = ReviewReadGate(), page = ReviewReadGate()
        let heldTranscript = Task { await transcript.wait() }, heldPage = Task { await page.wait() }
        defer { heldTranscript.cancel(); heldPage.cancel(); Task { await transcript.open(); await page.open() } }
        f.model.selectionTranscriptReadGateForTesting = heldTranscript
        f.model.gateSessionPagesForTesting(heldPage)
        f.model.selectSession(target.sessionID)
        try await wait { f.model.selectionTranscriptReadWaitingForTesting }
        var prematureIdle = false
        let subscription = f.model.sessionPageChanges.dropFirst().sink { state in
            if !state.isLoading && !state.sessions.contains(where: { $0.id == target.sessionID }) { prematureIdle = true }
        }
        defer { subscription.cancel() }
        f.model.loadMoreSessions()
        f.model.selectionTranscriptReadGateForTesting = nil
        await transcript.open()
        try await wait { f.model.selectedSession?.id == target.sessionID && !f.model.messages.isEmpty }
        XCTAssertTrue(f.model.isLoadingSessions)
        f.model.gateSessionPagesForTesting(nil)
        await page.open()
        try await wait { !f.model.isLoadingSessions }
        let expected = try await f.database.sessionListSnapshot(projectCanonicalKey: f.project.canonicalKey,
                                                               pageCount: 2, ensuringSessionID: target.sessionID)
        XCTAssertEqual(f.model.sessions.map(\.id), expected.sessions.map(\.id))
        XCTAssertEqual(f.model.totalSessionCount, expected.totalCount)
        XCTAssertEqual(f.model.sessionPageDepthForTesting, expected.pageCount)
        XCTAssertEqual(f.model.sessionCursorIDForTesting, expected.nextCursor?.sessionID)
        XCTAssertFalse(prematureIdle)
    }

    func testAttachmentDatabaseFailureUsesSafeStatusAndPrivateDiagnostic() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let error = DatabaseError(resultCode: .SQLITE_BUSY, message: "private-attachment-message",
            sql: "SELECT 'private-attachment-sql'", arguments: ["private-attachment-argument"], publicStatementArguments: true)
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        await replacement.database.failFailureCountsOnceForTesting(error)
        let committed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertFalse(committed)
        XCTAssertEqual(f.model.progress.error, "Could not update the index. Try again.")
        XCTAssertEqual(f.model.startupError, "Could not update the index. Try again.")
        XCTAssertFalse(IndexProgressLabel(progress: f.model.progress).details.contains("private-"))
        XCTAssertEqual(failures.map(\.primaryCode), [ResultCode.SQLITE_BUSY.rawValue])
    }

    func testSourceReloadDatabaseFailureUsesSafeTextAndResetsItsDiagnosticEpisode() async throws {
        let (f, removed) = try await twoRootUsageFixture()
        let raw = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
        try await raw.write {
            try $0.execute(sql: "CREATE TRIGGER private_source_sql BEFORE DELETE ON source_root BEGIN SELECT RAISE(ABORT, 'private-source-message'); END")
        }
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        var failedPublications = 0
        let subscription = f.model.sidebarChanges.map(\.sourceReloadRecovery).removeDuplicates().sink { if case .failed = $0 { failedPublications += 1 } }
        defer { subscription.cancel() }
        for _ in 0..<2 {
            let before = failedPublications
            f.model.reloadSourcesAndRebuild()
            try await wait { failedPublications > before && f.model.pendingDatabaseForTesting == nil }
            XCTAssertEqual(f.model.sourceReloadRecovery.error, "Could not apply source settings. Try again.")
            XCTAssertEqual(f.model.progress.error, "Could not apply source settings. Try again.")
            XCTAssertFalse(IndexProgressLabel(progress: f.model.progress, sourceReloadRecovery: f.model.sourceReloadRecovery).details.contains("private-"))
        }
        XCTAssertEqual(failures.filter { $0.operation == .sourceReload }.count, 1)
        XCTAssertEqual(failures.first?.primaryCode, ResultCode.SQLITE_CONSTRAINT.rawValue)
        try await raw.write { try $0.execute(sql: "DROP TRIGGER private_source_sql") }
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.sourceReloadRecovery.error == nil && !f.model.costsTotalsUpdating }
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
        _ = try await f.database.register(root: ClaudeCodeSource(roots: [removed]).roots[0])
        try await raw.write {
            try $0.execute(sql: "CREATE TRIGGER private_source_sql BEFORE DELETE ON source_root BEGIN SELECT RAISE(ABORT, 'private-source-message'); END")
        }
        let before = failedPublications
        f.model.reloadSourcesAndRebuild()
        try await wait { failedPublications > before && f.model.pendingDatabaseForTesting == nil }
        XCTAssertEqual(failures.filter { $0.operation == .sourceReload }.count, 2,
                       "an accepted same-database recovery resets the diagnostic episode")
    }

    func testSidebarMarkerWriteFailureDoesNotDiscardSuccessfulDatabaseRead() async throws {
        let f = try await fixture(count: 5)
        let expected = f.model.sessions.map(\.id)
        f.model.sidebarMarkerPathForTesting = f.root.path
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertEqual(f.model.sessions.map(\.id), expected)
        XCTAssertNil(f.model.sidebarSummaryError)
        XCTAssertEqual(f.model.sidebarTestControlFailuresForTesting.count, 1)
        f.model.sidebarMarkerPathForTesting = nil
    }

    func testFailedOrCancelledAttachmentResumesInstalledUsageDemand() async throws {
        for cancelled in [false, true] {
            let (f, _) = try await twoRootUsageFixture()
            let replacement = try await fixture(count: 3)
            let previous = try XCTUnwrap(f.model.schedulerForTesting)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.schedulerCompletionGateForTesting = held
            await previous.request(watermarks: ["queued-usage": 1])
            try await wait { f.model.schedulerCompletionWaitingForTesting }
            let currentZone = TimeZone.autoupdatingCurrent.identifier
            try await f.database.rebuildUsageRollups(timeZoneID: currentZone == "UTC" ? "Pacific/Auckland" : "UTC")
            let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
            try await wait { f.model.pendingDatabaseForTesting === replacement.database }
            let before = await f.database.usageReadCountForTesting()
            f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
            XCTAssertFalse(f.model.costsTotalsUpdating)
            if cancelled { attachment.cancel() }
            else { await replacement.database.failFailureCountsOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY)) }
            f.model.schedulerCompletionGateForTesting = nil
            await gate.open()
            let committed = await attachment.value
            XCTAssertFalse(committed)
            try await wait { !f.model.costsTotalsUpdating }
            let after = await f.database.usageReadCountForTesting()
            XCTAssertEqual(after, before + 1)
            XCTAssertTrue(f.model.databaseForTesting === f.database)
            XCTAssertNil(f.model.costsError)
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
            let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
            let repairedZone = try await queue.read {
                try String.fetchOne($0, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_timezone'")
            }
            XCTAssertEqual(repairedZone, currentZone)
            let repaired = try await f.database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
            XCTAssertEqual(f.model.usage.map(\.day), repaired.map(\.day))
        }
    }

    func testAttachmentRetiresQuietWaitAndResumesItsInstalledDemandAfterFailure() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let previous = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.schedulerCompletionGateForTesting = held
        await previous.request(watermarks: ["waiting-usage": 1])
        try await wait { f.model.schedulerCompletionWaitingForTesting }
        f.model.requestUsageRefreshForTesting(repair: true, immediately: false)
        try await wait { f.model.usageRefreshWaitingForTesting }
        XCTAssertTrue(f.model.costsTotalsUpdating)
        let before = await f.database.usageReadCountForTesting()
        let attachment = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
        try await wait { f.model.pendingDatabaseForTesting === replacement.database }
        XCTAssertFalse(f.model.usageRefreshWaitingForTesting)
        XCTAssertFalse(f.model.costsTotalsUpdating)
        await replacement.database.failFailureCountsOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.schedulerCompletionGateForTesting = nil
        await gate.open()
        let committed = await attachment.value
        XCTAssertFalse(committed)
        try await wait { !f.model.costsTotalsUpdating }
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 1)
        XCTAssertNil(f.model.costsError)
    }

    func testFullSummariesCoalesceRootUsageDemandWithoutDiscardingItsSnapshot() async throws {
        for newerDemand in [false, true] {
            let (f, _) = try await twoRootUsageFixture()
            try await f.model.synchronizeRootsForTesting(ClaudeCodeSource(roots: [f.root]).roots, database: f.database)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            let before = await f.database.usageReadCountForTesting()
            f.model.usageSnapshotGateForTesting = held
            await f.model.refreshSummariesForTesting(lightweight: false)
            try await wait { f.model.usageSnapshotWaitingForTesting }
            for _ in 0..<4 { await f.model.refreshSummariesForTesting(lightweight: false) }
            let running = await f.database.usageReadCountForTesting()
            XCTAssertEqual(running, before + 1)
            if newerDemand { f.model.requestUsageRefreshForTesting(repair: true, immediately: true) }
            f.model.usageSnapshotGateForTesting = nil
            await gate.open()
            try await wait { !f.model.costsTotalsUpdating }
            let after = await f.database.usageReadCountForTesting()
            XCTAssertEqual(after, before + (newerDemand ? 2 : 1))
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
            XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        }
    }

    func testFailedUsageAttemptCannotBeRearmedByItsTerminalTail() async throws {
        for inheritedTail in [false, true] {
            let f = try await fixture(count: 2)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            let before = await f.database.usageReadCountForTesting()
            await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            f.model.summaryTailGateForTesting = held
            var terminal = IndexProgress(phase: .failed)
            terminal.indexChanged = true
            let task = Task { await f.model.receiveProgress(terminal) }
            try await wait { f.model.summaryTailWaitingForTesting }
            await f.clock.advance(by: .seconds(1))
            try await wait { f.model.costsError != nil && !f.model.costsTotalsUpdating }
            f.model.summaryTailGateForTesting = nil
            if inheritedTail { await f.model.refreshSummariesForTesting(lightweight: true) }
            await gate.open(); await task.value
            await f.clock.advance(by: .seconds(60))
            let failed = await f.database.usageReadCountForTesting()
            XCTAssertEqual(failed, before + 1, "one terminal event gets one model repair attempt")
            XCTAssertNotNil(f.model.costsError)
            XCTAssertFalse(f.model.costsTotalsUpdating)
            await f.model.refreshSummariesForTesting(lightweight: false)
            try await wait { !f.model.costsTotalsUpdating }
            let retried = await f.database.usageReadCountForTesting()
            XCTAssertEqual(retried, before + 2, "a distinct full event may retry retained debt")
            XCTAssertNil(f.model.costsError)
        }
    }

    func testExplicitFullEventRetriesWhileOlderTerminalTailIsStillHeld() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.summaryTailGateForTesting = held
        var terminal = IndexProgress(phase: .failed)
        terminal.indexChanged = true
        let task = Task { await f.model.receiveProgress(terminal) }
        try await wait { f.model.summaryTailWaitingForTesting }
        await f.clock.advance(by: .seconds(1))
        try await wait { f.model.costsError != nil && !f.model.costsTotalsUpdating }
        let before = await f.database.usageReadCountForTesting()
        f.model.summaryTailGateForTesting = nil
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { !f.model.costsTotalsUpdating }
        XCTAssertNil(f.model.costsError)
        let recovered = await f.database.usageReadCountForTesting()
        XCTAssertEqual(recovered, before + 1)
        await gate.open(); await task.value
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, recovered)
    }

    func testLaterUnchangedTerminalEventRetriesRetainedUsageDebtOnce() async throws {
        let f = try await fixture(count: 2)
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        try await wait { f.model.costsError != nil && !f.model.costsTotalsUpdating }
        let before = await f.database.usageReadCountForTesting()
        var pass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(pass)
        XCTAssertTrue(f.model.usageDemandOwedForTesting)
        XCTAssertFalse(f.model.usageRefreshWaitingForTesting)
        XCTAssertFalse(f.model.usageRefreshRunningForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryTailGateForTesting = held
        pass.phase = .complete
        let terminalProgress = pass
        let terminal = Task { await f.model.receiveProgress(terminalProgress) }
        try await wait { f.model.summaryTailWaitingForTesting }
        await f.clock.advance(by: .milliseconds(999))
        let waiting = await f.database.usageReadCountForTesting()
        XCTAssertEqual(waiting, before)
        await f.clock.advance(by: .milliseconds(1))
        try await wait { !f.model.costsTotalsUpdating }
        XCTAssertNil(f.model.costsError)
        f.model.summaryTailGateForTesting = nil
        await gate.open(); await terminal.value
        await f.clock.advance(by: .seconds(60))
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 1)
    }

    func testProductionCostsRetryRecoversWithoutSummaryAndCoalescesReentrantClicks() async throws {
        let (f, _) = try await twoRootUsageFixture()
        let error = DatabaseError(resultCode: .SQLITE_BUSY, message: "private-retry-message")
        await f.database.failUsageReadOnceForTesting(error)
        await f.model.loadCachedUsageForTesting()
        XCTAssertTrue(f.model.canRetryCosts)
        let reads = await f.database.usageReadCountForTesting()
        let receipts = f.model.usageAttemptReceiptsForTesting.count
        let sidebar = await f.database.sessionListReadCountForTesting()
        let metadata = await f.database.summaryMetadataReadCountsForTesting()
        let publications = OSAllocatedUnfairLock(initialState: [(Bool, Bool)]())
        let objectSubscription = f.model.objectWillChange.sink {
            if f.model.costsTotalsUpdating { f.model.retryCosts() }
        }
        let subscription = f.model.costsChanges.sink { state in
            publications.withLock { $0.append((state.canRetry, state.updating)) }
            if state.updating { f.model.retryCosts() }
        }
        defer { subscription.cancel(); objectSubscription.cancel() }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.usageFailureGateForTesting = held
        await f.database.failUsageReadOnceForTesting(error)
        f.model.retryCosts(); f.model.retryCosts()
        try await wait { f.model.usageFailureWaitingForTesting }
        XCTAssertFalse(f.model.canRetryCosts)
        XCTAssertEqual(f.model.costsError, "Could not load cached token totals.")
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.count, receipts)
        f.model.usageFailureGateForTesting = nil
        await gate.open()
        try await wait { f.model.canRetryCosts }
        XCTAssertEqual(f.model.costsError, "Could not update token totals.")
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.dropFirst(receipts).map(\.outcome), [.failure])
        f.model.retryCosts()
        try await wait { !f.model.costsTotalsUpdating }
        XCTAssertNil(f.model.costsError)
        XCTAssertFalse(f.model.canRetryCosts)
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.dropFirst(receipts).map(\.outcome), [.failure, .success])
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, reads + 2)
        let sidebarAfter = await f.database.sessionListReadCountForTesting()
        let metadataAfter = await f.database.summaryMetadataReadCountsForTesting()
        XCTAssertEqual(sidebarAfter, sidebar)
        XCTAssertEqual(metadataAfter.health, metadata.health)
        XCTAssertEqual(metadataAfter.statistics, metadata.statistics)
        XCTAssertTrue(publications.withLock { $0.contains { !$0.0 } })
        XCTAssertTrue(publications.withLock { $0.allSatisfy { !($0.0 && $0.1) } })
    }

    func testCostsRetryIsDisabledForIndexingAttachmentAndTermination() async throws {
        let f = try await fixture(count: 2)
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.loadCachedUsageForTesting()
        XCTAssertTrue(f.model.canRetryCosts)
        await f.model.receiveProgress(.init(phase: .indexing))
        XCTAssertFalse(f.model.canRetryCosts)
        let reads = await f.database.usageReadCountForTesting()
        f.model.retryCosts()
        let unchanged = await f.database.usageReadCountForTesting()
        XCTAssertEqual(unchanged, reads)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.sourceChangeAttachmentGateForTesting = held
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        XCTAssertFalse(f.model.canRetryCosts)
        let attachmentRevision = f.model.usageDemandRevisionForTesting
        let attachmentReceipts = f.model.usageAttemptReceiptsForTesting.count
        let attachmentReads = await f.database.usageReadCountForTesting()
        let wasPending = f.model.usagePendingForTesting
        f.model.retryCosts()
        await Task.yield()
        XCTAssertEqual(f.model.usageDemandRevisionForTesting, attachmentRevision)
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.count, attachmentReceipts)
        XCTAssertEqual(f.model.usagePendingForTesting, wasPending)
        let duringAttachment = await f.database.usageReadCountForTesting()
        XCTAssertEqual(duringAttachment, attachmentReads)
        f.model.sourceChangeAttachmentGateForTesting = nil
        await gate.open()
        try await wait { f.model.pendingDatabaseForTesting == nil && !f.model.costsTotalsUpdating }
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.loadCachedUsageForTesting()
        XCTAssertTrue(f.model.canRetryCosts)
        await f.model.prepareToTerminate()
        XCTAssertFalse(f.model.canRetryCosts)
        let terminatedReads = await f.database.usageReadCountForTesting()
        let terminatedReceipts = f.model.usageAttemptReceiptsForTesting.count
        f.model.retryCosts()
        await Task.yield()
        XCTAssertFalse(f.model.usagePendingForTesting)
        XCTAssertFalse(f.model.usageRefreshWaitingForTesting)
        XCTAssertFalse(f.model.usageRefreshRunningForTesting)
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.count, terminatedReceipts)
        let afterTermination = await f.database.usageReadCountForTesting()
        XCTAssertEqual(afterTermination, terminatedReads)
    }

    func testCostsRetryRejectsObsoleteFailureReceiptAfterReplacement() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.loadCachedUsageForTesting()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.usageFailureGateForTesting = held
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.retryCosts()
        try await wait { f.model.usageFailureWaitingForTesting }
        let committed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertTrue(committed)
        f.model.usageFailureGateForTesting = nil
        await gate.open()
        try await wait { !f.model.usageFailureWaitingForTesting }
        XCTAssertTrue(f.model.usageAttemptReceiptsForTesting.isEmpty)
        XCTAssertNil(f.model.costsError)
        XCTAssertFalse(f.model.canRetryCosts)
    }

    func testIndexStatusDetailsDoNotExposeRawRollupError() {
        var progress = IndexProgress(phase: .complete)
        progress.rollupError = "private-message SELECT private-sql 'private-argument'"
        let details = IndexProgressLabel(progress: progress).details
        XCTAssertTrue(details.contains("Token totals: Could not update token totals."))
        XCTAssertFalse(details.contains("private-"))
    }

    func testFailedCachedStartupReadRecordsDormantDebtAndRecoversOnDistinctEvent() async throws {
        let (f, _) = try await twoRootUsageFixture()
        XCTAssertFalse(f.model.usageDemandOwedForTesting)
        let before = await f.database.usageReadCountForTesting()
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.loadCachedUsageForTesting()
        XCTAssertEqual(f.model.costsError, "Could not load cached token totals.")
        XCTAssertTrue(f.model.usageDemandOwedForTesting)
        XCTAssertFalse(f.model.costsTotalsUpdating)
        await f.clock.advance(by: .seconds(60))
        let dormant = await f.database.usageReadCountForTesting()
        XCTAssertEqual(dormant, before + 1)
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { !f.model.costsTotalsUpdating }
        let recovered = await f.database.usageReadCountForTesting()
        XCTAssertEqual(recovered, before + 2)
        XCTAssertNil(f.model.costsError)
        XCTAssertFalse(f.model.usageDemandOwedForTesting)
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
    }

    func testFailedCachedReadCoalescesWithRepairAlreadyRunning() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        let before = await f.database.usageReadCountForTesting()
        f.model.usageSnapshotGateForTesting = held
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        try await wait { f.model.usageSnapshotWaitingForTesting }
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.loadCachedUsageForTesting()
        XCTAssertEqual(f.model.costsError, "Could not load cached token totals.")
        f.model.usageSnapshotGateForTesting = nil
        await gate.open()
        try await wait { !f.model.costsTotalsUpdating }
        XCTAssertNil(f.model.costsError)
        XCTAssertFalse(f.model.usageDemandOwedForTesting)
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 2, "the cached failure must not invalidate the held repair")
    }

    func testObsoleteCachedFailureCannotEnrollDebtInReplacementDatabase() async throws {
        let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.cachedUsageFailureGateForTesting = held
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        let load = Task { await f.model.loadCachedUsageForTesting() }
        try await wait { f.model.cachedUsageFailureWaitingForTesting }
        let committed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
        XCTAssertTrue(committed)
        f.model.cachedUsageFailureGateForTesting = nil
        await gate.open(); await load.value
        XCTAssertNil(f.model.costsError)
        XCTAssertFalse(f.model.usageDemandOwedForTesting)
    }

    func testStartupRepairEnrollmentSurvivesSuccessFailureAndSameDatabaseHandoff() async throws {
        for fails in [false, true] {
            let f = try await fixture(count: 2)
            XCTAssertFalse(f.model.startupUsageRepairEnrolledForTesting)
            if fails { await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY)) }
            let before = await f.database.usageReadCountForTesting()
            await f.model.finalizeStartupUsageForTesting()
            XCTAssertTrue(f.model.startupUsageRepairEnrolledForTesting)
            XCTAssertEqual(f.model.costsError != nil, fails)
            for _ in 0..<2 { await f.model.finalizeStartupUsageForTesting() }
            let same = await f.model.attach(database: f.database, coordinator: f.coordinator)
            XCTAssertTrue(same)
            await f.model.finalizeStartupUsageForTesting()
            let after = await f.database.usageReadCountForTesting()
            // A handoff has its own recovery event and may retry failed debt once.
            XCTAssertEqual(after, before + (fails ? 2 : 1))
            XCTAssertTrue(f.model.startupUsageRepairEnrolledForTesting)
            let replacement = try await fixture(count: 3)
            let changed = await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            XCTAssertTrue(changed)
            XCTAssertFalse(f.model.startupUsageRepairEnrolledForTesting)
            await f.model.finalizeStartupUsageForTesting()
            XCTAssertTrue(f.model.startupUsageRepairEnrolledForTesting)
        }
    }

    func testEarlierFailedRepairCountsAsStartupEnrollment() async throws {
        let f = try await fixture(count: 2)
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        try await wait { f.model.costsError != nil && !f.model.costsTotalsUpdating }
        let before = await f.database.usageReadCountForTesting()
        await f.model.finalizeStartupUsageForTesting()
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before)
        XCTAssertEqual(f.model.costsError, "Could not update token totals.")
    }

    func testCostsFailuresUseSafeTextAndDeduplicateEachOperationUntilRecovery() async throws {
        let f = try await fixture(count: 2)
        let error = DatabaseError(resultCode: .SQLITE_BUSY, message: "private-cost-message",
            sql: "SELECT 'private-cost-sql'", arguments: ["private-cost-argument"], publicStatementArguments: true)
        var logs: [TraceModel.CostsFailure] = []
        f.model.costsFailureForTesting = { logs.append($0) }
        for _ in 0..<2 {
            await f.database.failUsageReadOnceForTesting(error)
            await f.model.loadCachedUsageForTesting()
            XCTAssertEqual(f.model.costsError, "Could not load cached token totals.")
        }
        XCTAssertEqual(logs.filter { $0.operation == .cachedUsage }.count, 1)
        for _ in 0..<2 {
            await f.database.failUsageReadOnceForTesting(error)
            f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
            try await wait { !f.model.costsTotalsUpdating }
            XCTAssertEqual(f.model.costsError, "Could not update token totals.")
        }
        XCTAssertEqual(logs.filter { $0.operation == .usageRefresh }.count, 1)
        XCTAssertEqual(f.model.usageAttemptReceiptsForTesting.filter { $0.outcome == .failure }.count, 2,
                       "accepted failures are receipted even when their diagnostic is deduplicated")
        for _ in 0..<2 {
            var pass = IndexProgress(phase: .complete)
            pass.rollupError = error.localizedDescription
            await f.model.receiveProgress(pass)
            XCTAssertEqual(f.model.costsError, "Could not update token totals.")
        }
        XCTAssertEqual(logs.count, 2, "repair diagnostics belong to the database, not the safe presentation string")
        await f.clock.advance(by: .seconds(1))
        try await wait { !f.model.costsTotalsUpdating }
        XCTAssertNil(f.model.costsError)
        await f.database.failUsageReadOnceForTesting(error)
        await f.model.loadCachedUsageForTesting()
        XCTAssertEqual(logs.filter { $0.operation == .cachedUsage }.count, 2)
        XCTAssertTrue(logs.allSatisfy { $0.primaryCode == ResultCode.SQLITE_BUSY.rawValue })
    }

    func testExplicitFullEventPromotesWaitingDemandWithoutAnotherAttempt() async throws {
        let f = try await fixture(count: 2)
        let before = await f.database.usageReadCountForTesting()
        f.model.requestUsageRefreshForTesting(repair: true, immediately: false)
        try await wait { f.model.usageRefreshWaitingForTesting }
        await f.clock.advance(by: .milliseconds(999))
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { !f.model.costsTotalsUpdating }
        await f.clock.advance(by: .seconds(60))
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 1)
        XCTAssertNil(f.model.costsError)
    }

    func testSelectionChangeDuringPageReadEnsuresTheLatestSessionWithoutConfigurationChange() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let page = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000)
        let original = page.results[page.results.count - 1], latest = page.results[page.results.count - 2]
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(held)
        let before = await f.database.sessionListReadCountForTesting()
        f.model.openSearchResult(original)
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        f.model.selectSession(latest.sessionID)
        await f.database.gateSessionListReadsForTesting(nil)
        await gate.open()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 201)
        XCTAssertTrue(f.model.sessions.contains { $0.id == latest.sessionID })
        XCTAssertFalse(f.model.sessions.contains { $0.id == original.sessionID })
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 1)
    }

    func testUnresolvedSelectionDoesNotReloadWrongProjectAndResolvesOnItsExistingTranscriptRead() async throws {
        for direct in [false, true] {
            for sameProject in [false, true] {
                let f = try await fixture(count: 605)
                f.model.selectProject(f.project.id)
                try await wait { !f.model.isLoadingSessions }
                f.model.loadMoreSessions()
                try await wait { !f.model.isLoadingSessions }
                let file = f.root.appendingPathComponent("unresolved-selection.jsonl")
                let project = sameProject ? "NavigationReview" : "UncachedOtherProject"
                let row: [String: Any] = ["type": "user", "uuid": "unresolved", "sessionId": "unresolved",
                    "cwd": "/tmp/\(project)", "timestamp": 1_600_000_000_000,
                    "message": ["content": "UnresolvedSelectionNeedle"]]
                try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: file)
                await f.coordinator.indexAll(scope: .proseOnly)
                await f.model.refreshSummariesForTesting()
                let targets = try await f.database.search(query: "UnresolvedSelectionNeedle")
                let target = try XCTUnwrap(targets.results.first)
                XCTAssertFalse((f.model.sessions + f.model.recentSessions).contains { $0.id == target.sessionID })
                let pageGate = ReviewReadGate(), pageHeld = Task { await pageGate.wait() }
                let transcriptGate = ReviewReadGate(), transcriptHeld = Task { await transcriptGate.wait() }
                defer {
                    pageHeld.cancel(); transcriptHeld.cancel()
                    Task { await pageGate.open(); await transcriptGate.open() }
                }
                let before = await f.database.sessionListReadCountForTesting()
                let summary: Task<Void, Never>?
                if direct {
                    await f.database.gateSessionListReadsForTesting(pageHeld)
                    let prefixes = try await f.database.search(query: "NavigationNeedle",
                        filters: .init(projectCanonicalKey: f.project.canonicalKey))
                    let prefix = try XCTUnwrap(prefixes.results.first)
                    f.model.openSearchResult(prefix)
                    try await wait { await f.database.sessionListReadCountForTesting() > before }
                    summary = nil
                } else {
                    f.model.summarySidebarGateForTesting = pageHeld
                    summary = Task { await f.model.refreshSummariesForTesting() }
                    try await wait { f.model.summarySidebarWaitingForTesting }
                }
                f.model.selectionTranscriptReadGateForTesting = transcriptHeld
                f.model.selectSession(target.sessionID)
                try await wait { f.model.selectionTranscriptReadWaitingForTesting }
                XCTAssertEqual(f.model.selectedProjectCanonicalKey, f.project.canonicalKey)
                var loading: [Bool] = []
                let subscription = f.model.sessionPageChanges.map(\.isLoading).removeDuplicates().dropFirst().sink { loading.append($0) }
                defer { subscription.cancel() }
                f.model.summarySidebarGateForTesting = nil
                await f.database.gateSessionListReadsForTesting(nil)
                await pageGate.open()
                await summary?.value
                try await wait { !f.model.isLoadingSessions }
                let withoutSpeculation = await f.database.sessionListReadCountForTesting()
                XCTAssertEqual(withoutSpeculation, before + 1)
                XCTAssertEqual(loading, direct ? [false] : [])
                XCTAssertEqual(f.model.selectedProjectCanonicalKey, f.project.canonicalKey)
                f.model.selectionTranscriptReadGateForTesting = nil
                await transcriptGate.open()
                try await wait {
                    !f.model.isLoadingSessions && f.model.selectedSession?.id == target.sessionID
                        && f.model.sessions.contains { $0.id == target.sessionID }
                }
                XCTAssertEqual(f.model.selectedProjectCanonicalKey, target.projectCanonicalKey)
                XCTAssertEqual(f.model.sessionPageDepthForTesting, sameProject ? 2 : 1)
                XCTAssertEqual(f.model.totalSessionCount, sameProject ? 606 : 1)
                let after = await f.database.sessionListReadCountForTesting()
                XCTAssertEqual(after, before + 2)
            }
        }
    }

    func testQueuedExplicitSummaryCannotDisplaceANewerSummary() async throws {
        let f = try await fixture(count: 2)
        let before = await f.database.sessionListReadCountForTesting()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        let queued = try XCTUnwrap(f.model.refreshSidebarForUITesting(launchGate: held))
        await f.model.refreshSummariesForTesting(lightweight: false)
        let accepted = try XCTUnwrap(f.model.fullSummaryCompletionForTesting).summaryID
        await gate.open(); await queued.value
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, before + 1, "a queued older explicit refresh must retire before reading")
        XCTAssertEqual(f.model.fullSummaryCompletionForTesting?.summaryID, accepted)
    }

    func testOwnedSummaryHoldCannotBeConsumedByBackgroundFailureOrSupersededRefresh() async throws {
        let f = try await fixture(count: 2)
        let backgroundGate = ReviewReadGate(), backgroundHeld = Task { await backgroundGate.wait() }
        let ownedGate = ReviewReadGate(), ownedHeld = Task { await ownedGate.wait() }
        defer {
            backgroundHeld.cancel(); ownedHeld.cancel()
            Task { await backgroundGate.open(); await ownedGate.open() }
        }
        f.model.summarySidebarGateForTesting = backgroundHeld
        let background = Task { await f.model.refreshSummariesForTesting() }
        try await wait { f.model.summarySidebarWaitingForTesting }
        f.model.summarySidebarGateForTesting = nil
        let owned = Task { await f.model.refreshHeldSummaryForTesting(gate: ownedHeld) }
        try await wait { f.model.heldSidebarSummaryIDsForTesting.count == 1 }
        let heldID = try XCTUnwrap(f.model.heldSidebarSummaryIDsForTesting.first)
        await backgroundGate.open(); await background.value
        XCTAssertEqual(f.model.heldSidebarSummaryIDsForTesting, [heldID])
        await f.model.refreshSummariesForTesting(lightweight: false)
        let accepted = try XCTUnwrap(f.model.fullSummaryCompletionForTesting).summaryID
        XCTAssertNotEqual(accepted, heldID)
        await ownedGate.open(); await owned.value
        XCTAssertEqual(f.model.fullSummaryCompletionForTesting?.summaryID, accepted)
        let failingGate = ReviewReadGate(), failingHeld = Task { await failingGate.wait() }
        defer { failingHeld.cancel(); Task { await failingGate.open() } }
        await f.model.refreshHeldSummaryForTesting(gate: failingHeld, failRead: true)
        XCTAssertEqual(f.model.heldSidebarSummaryIDsForTesting, [heldID])
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(f.model.heldSidebarSummaryIDsForTesting, [heldID])
    }

    func testSummarySelectionChangesPreserveEnsuredRowAndLoadingThroughReplacement() async throws {
        for duringNotification in [false, true] {
            let f = try await fixture(count: 605)
            let results = try await f.database.search(query: "NavigationNeedle",
                filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000).results
            let beyond = try XCTUnwrap(results.last)
            f.model.openSearchResult(beyond)
            try await wait { !f.model.isLoadingSessions && f.model.selectedSessionID == beyond.sessionID }
            let prefix = try XCTUnwrap(f.model.sessions.first)
            f.model.selectSession(prefix.id)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summarySidebarGateForTesting = held
            let before = await f.database.sessionListReadCountForTesting()
            let summary = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
            try await wait { f.model.summarySidebarWaitingForTesting }
            var changed = false
            let subscription = f.model.sessionPageChanges.dropFirst().sink { state in
                guard duringNotification, !changed, state.sessions.count == 200 else { return }
                changed = true
                f.model.selectSession(beyond.sessionID)
            }
            defer { subscription.cancel() }
            if !duringNotification { f.model.selectSession(beyond.sessionID); changed = true }
            let pageGate = ReviewReadGate(), pageHeld = Task { await pageGate.wait() }
            defer { pageHeld.cancel(); Task { await pageGate.open() } }
            await f.database.gateSessionListReadsForTesting(pageHeld)
            f.model.summarySidebarGateForTesting = nil
            await gate.open(); await summary.value
            try await wait { f.model.isLoadingSessions }
            var loading: [Bool] = []
            let loadingSubscription = f.model.sessionPageChanges.map(\.isLoading).removeDuplicates().dropFirst().sink { loading.append($0) }
            defer { loadingSubscription.cancel() }
            await f.database.gateSessionListReadsForTesting(nil)
            await pageGate.open()
            try await wait { !f.model.isLoadingSessions }
            XCTAssertTrue(changed)
            XCTAssertEqual(f.model.sessions.count, 201)
            XCTAssertTrue(f.model.sessions.contains { $0.id == beyond.sessionID })
            XCTAssertEqual(f.model.totalSessionCount, 605)
            XCTAssertEqual(f.model.sessionPageDepthForTesting, 1)
            XCTAssertNotNil(f.model.sessionCursorIDForTesting)
            XCTAssertEqual(loading, [false])
            let after = await f.database.sessionListReadCountForTesting()
            XCTAssertEqual(after, before + 2)
        }
    }

    func testDirectPageSelectionChangesDuringPublicationAreReissuedOnce() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let results = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000).results
        let beyond = try XCTUnwrap(results.last)
        f.model.openSearchResult(beyond)
        try await wait { !f.model.isLoadingSessions && f.model.selectedSession?.id == beyond.sessionID }
        f.model.selectSession(try XCTUnwrap(f.model.sessions.first).id)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await f.database.gateSessionListReadsForTesting(held)
        var armed = false
        var changed = false
        let subscription = f.model.sessionPageChanges.sink { state in
            guard armed, !changed, state.sessions.count == 400 else { return }
            changed = true
            f.model.selectSession(beyond.sessionID)
        }
        defer { subscription.cancel() }
        // A full two-page read (rather than append) has a selected-row contract.
        let before = await f.database.sessionListReadCountForTesting()
        f.model.openSearchResult(try XCTUnwrap(results.first))
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        armed = true
        await f.database.gateSessionListReadsForTesting(nil)
        await gate.open()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertTrue(changed)
        XCTAssertTrue(f.model.sessions.contains { $0.id == beyond.sessionID })
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 2)
    }

    func testSummarySelectionReplacementRetainsRootPageDebtUntilFullPageSucceeds() async throws {
        let f = try await fixture(count: 605)
        let results = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000).results
        let beyond = try XCTUnwrap(results.last)
        f.model.openSearchResult(beyond)
        try await wait { !f.model.isLoadingSessions }
        f.model.selectSession(try XCTUnwrap(f.model.sessions.first).id)
        let empty = f.root.appendingPathComponent("empty-root")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await f.model.synchronizeRootsForTesting(ClaudeCodeSource(roots: [f.root, empty]).roots, database: f.database)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summarySidebarGateForTesting = held
        let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summarySidebarWaitingForTesting }
        f.model.selectSession(beyond.sessionID)
        await f.database.failSessionListReadOnceForTesting()
        f.model.summarySidebarGateForTesting = nil
        await gate.open(); await refresh.value
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        XCTAssertNil(f.model.sidebarSummaryError)
        XCTAssertTrue(f.model.rootSessionRefreshPendingForTesting)
        XCTAssertTrue(f.model.sessions.contains { $0.id == beyond.sessionID })
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertNil(f.model.sessionListError)
        XCTAssertFalse(f.model.rootSessionRefreshPendingForTesting)
        XCTAssertTrue(f.model.sessions.contains { $0.id == beyond.sessionID })
    }

    func testMissingLatestSelectionInAllProjectsHasOnlyOneEnsuredAttempt() async throws {
        let f = try await fixture(count: 605)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summarySidebarGateForTesting = held
        let before = await f.database.sessionListReadCountForTesting()
        let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summarySidebarWaitingForTesting }
        f.model.setUnresolvedSelectionForTesting(Int64.max)
        f.model.summarySidebarGateForTesting = nil
        await gate.open(); await refresh.value
        try await wait { !f.model.isLoadingSessions }
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, before + 2)
        XCTAssertEqual(f.model.sessions.count, 200)
        XCTAssertEqual(f.model.totalSessionCount, 609)
    }

    func testAutomaticReadOnlyUsageNeedsNoRepairQuietPeriod() async throws {
        let f = try await fixture(count: 2)
        let before = await f.database.usageReadCountForTesting()
        f.model.requestUsageRefreshForTesting(repair: false, immediately: false)
        try await wait { !f.model.costsTotalsUpdating }
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 1)
        XCTAssertFalse(f.model.usageDemandOwedForTesting)
        XCTAssertFalse(f.model.startupUsageRepairEnrolledForTesting)
    }

    func testSnapshotPublishersReadSafelyOnSubscriptionThreadBeforeAndDuringCommit() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let pages = ReviewPublisher(publisher: f.model.sessionPageChanges)
        let costs = ReviewPublisher(publisher: f.model.costsChanges)
        let observedPages = OSAllocatedUnfairLock(initialState: [(Int, Int, Bool)]())
        let observedCosts = OSAllocatedUnfairLock(initialState: [(UInt64, Bool)]())
        let pageSubscription = try backgroundSubscription(pages) { state in
                observedPages.withLock { $0.append((state.sessions.count, state.totalCount, Thread.isMainThread)) }
        }
        let costSubscription = try backgroundSubscription(costs) { state in
                observedCosts.withLock { $0.append((state.usagePublicationRevision, Thread.isMainThread)) }
        }
        defer { pageSubscription.cancel(); costSubscription.cancel() }
        XCTAssertEqual(observedPages.withLock { $0.first?.0 }, 200)
        XCTAssertEqual(observedPages.withLock { $0.first?.2 }, false)
        XCTAssertEqual(observedCosts.withLock { $0.first?.1 }, false)
        var subscribedDuringCommit = false
        let reentry = f.model.objectWillChange.sink {
            guard !subscribedDuringCommit, f.model.sessions.count == 400 else { return }
            subscribedDuringCommit = true
            do {
            let current = try self.backgroundSubscription(ReviewPublisher(publisher: pages.publisher.prefix(1).eraseToAnyPublisher())) { state in
                    XCTAssertEqual(state.sessions.count, 400)
                    XCTAssertEqual(state.totalCount, 605)
                    XCTAssertFalse(Thread.isMainThread)
            }
            withExtendedLifetime(current) {}
            } catch { XCTFail("Subscription failed: \(error)") }
        }
        defer { reentry.cancel() }
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertTrue(subscribedDuringCommit)
        XCTAssertEqual(observedPages.withLock { $0.last?.0 }, 400)
        XCTAssertTrue(observedPages.withLock { $0.dropFirst().allSatisfy { $0.2 && $0.1 == 605 } })
        f.model.reloadCosts()
        XCTAssertTrue(observedCosts.withLock { $0.dropFirst().allSatisfy { $0.1 } })
        XCTAssertEqual(observedCosts.withLock { $0.last?.0 }, observedCosts.withLock { ($0.first?.0 ?? 0) + 1 })
    }

    private enum SubscriptionWaitError: Error { case timedOut }

    nonisolated private func backgroundSubscription<Value: Sendable>(_ transfer: ReviewPublisher<Value>,
        timeout: DispatchTimeInterval = .seconds(3), beforeSubscribe: @escaping @Sendable () -> Void = {},
        receive: @escaping @Sendable (Value) -> Void) throws -> AnyCancellable {
        let ready = DispatchSemaphore(value: 0)
        let slot = OSAllocatedUnfairLock(initialState: (subscription: Optional<ReviewSubscription>.none, abandoned: false))
        DispatchQueue.global().async {
            beforeSubscribe()
            let subscription = ReviewSubscription(value: transfer.publisher.sink(receiveValue: receive))
            let abandoned = slot.withLock {
                if $0.abandoned { return true }
                $0.subscription = subscription
                return false
            }
            if abandoned { subscription.value.cancel() }
            ready.signal()
        }
        guard ready.wait(timeout: .now() + timeout) == .success else {
            let late = slot.withLock {
                $0.abandoned = true
                let subscription = $0.subscription
                $0.subscription = nil
                return subscription
            }
            late?.value.cancel()
            throw SubscriptionWaitError.timedOut
        }
        return try XCTUnwrap(slot.withLock { $0.subscription }).value
    }

    func testBackgroundSubscriptionTimeoutThrowsAndCancelsLateSubscription() throws {
        let released = DispatchSemaphore(value: 0), cancelled = DispatchSemaphore(value: 0)
        let subject = PassthroughSubject<Int, Never>()
        let publisher = ReviewPublisher(publisher: subject.handleEvents(receiveCancel: { @Sendable in cancelled.signal() }).eraseToAnyPublisher())
        XCTAssertThrowsError(try backgroundSubscription(publisher, timeout: .milliseconds(10),
            beforeSubscribe: { released.wait() }, receive: { _ in })) { error in
            XCTAssertTrue(error is SubscriptionWaitError)
        }
        released.signal()
        XCTAssertEqual(cancelled.wait(timeout: .now() + 3), .success)
    }

    func testPagePublicationReentryObservesCommittedCursorAndCannotOverwriteNavigation() async throws {
        for objectNotification in [false, true] {
            let f = try await fixture(count: 605)
            f.model.selectProject(f.project.id)
            try await wait { !f.model.isLoadingSessions }
            let other = try XCTUnwrap(f.model.projects.first { $0.id != f.project.id })
            var reentered = false
            let observe = {
                guard !reentered, f.model.sessions.count == 400 else { return }
                reentered = true
                XCTAssertEqual(f.model.totalSessionCount, 605)
                XCTAssertEqual(f.model.sessionPageDepthForTesting, 2)
                XCTAssertEqual(f.model.sessionCursorIDForTesting, f.model.sessions.last?.id)
                let latest = f.model.sessionPageChanges.prefix(1).sink {
                    XCTAssertEqual($0.sessions.count, 400, "a subscriber added during notification starts at committed state")
                    XCTAssertEqual($0.totalCount, 605)
                }
                withExtendedLifetime(latest) {}
                f.model.selectProject(other.id)
            }
            let subscription: AnyCancellable
            if objectNotification { subscription = f.model.objectWillChange.sink { observe() } }
            else { subscription = f.model.sessionPageChanges.dropFirst().sink { _ in observe() } }
            defer { subscription.cancel() }
            f.model.loadMoreSessions()
            try await wait { reentered && !f.model.isLoadingSessions }
            XCTAssertEqual(f.model.sessions.count, 4)
            XCTAssertEqual(f.model.totalSessionCount, 4)
            XCTAssertEqual(f.model.sessionPageDepthForTesting, 1)
            XCTAssertNil(f.model.sessionCursorIDForTesting)
            XCTAssertTrue(f.model.sessions.allSatisfy { $0.projectID == other.id })
        }
    }

    func testReentrantPaginationUsesTheCommittedBackgroundCursor() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let handle = try FileHandle(forWritingTo: f.root.appendingPathComponent("sessions.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: line(1000))
        try handle.close()
        await f.coordinator.refresh(paths: [f.root.appendingPathComponent("sessions.jsonl").path], scope: .proseOnly)
        let expected = try await f.database.sessionListSnapshot(projectCanonicalKey: f.project.canonicalKey, pageCount: 2)
        var queued = false
        let subscription = f.model.objectWillChange.sink {
            guard !queued, f.model.totalSessionCount == 606, f.model.sessions.count == 200 else { return }
            queued = true
            XCTAssertEqual(f.model.sessionCursorIDForTesting, f.model.sessions.last?.id)
            XCTAssertEqual(f.model.sessionPageDepthForTesting, 1)
            f.model.loadMoreSessions()
        }
        defer { subscription.cancel() }
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { queued && !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.map(\.id), expected.sessions.map(\.id))
        XCTAssertEqual(f.model.sessionCursorIDForTesting, expected.nextCursor?.sessionID)
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 2)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 600)
        XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 600)
    }

    func testCostsErrorClearReentryObservesAcceptedTotalsAndPreservesNewerWork() async throws {
        for objectNotification in [false, true] {
            let (f, _) = try await twoRootUsageFixture()
            await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
            try await wait { f.model.costsError != nil && !f.model.costsTotalsUpdating }
            try await f.model.synchronizeRootsForTesting(ClaudeCodeSource(roots: [f.root]).roots, database: f.database)
            var reentered = false
            let observe = {
                guard !reentered, f.model.costsError == nil,
                      f.model.usage.reduce(0, { $0 + $1.inputTokens }) == 10 else { return }
                reentered = true
                let latest = f.model.costsChanges.prefix(1).sink {
                    XCTAssertNil($0.error)
                    XCTAssertEqual($0.usage.reduce(0) { $0 + $1.inputTokens }, 10)
                }
                withExtendedLifetime(latest) {}
                f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
                f.model.reloadCosts()
            }
            let subscription: AnyCancellable
            if objectNotification { subscription = f.model.objectWillChange.sink { observe() } }
            else { subscription = f.model.costsChanges.dropFirst().sink { _ in observe() } }
            defer { subscription.cancel() }
            let before = await f.database.usageReadCountForTesting()
            await f.model.refreshSummariesForTesting(lightweight: false)
            try await wait { reentered && !f.model.costsTotalsUpdating }
            let after = await f.database.usageReadCountForTesting()
            XCTAssertEqual(after, before + 2)
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
            XCTAssertNil(f.model.costsError)
            XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        }
    }

    func testConfigurationReissuesFollowLatestSameProjectSelection() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let results = try await f.database.search(query: "NavigationNeedle",
            filters: .init(projectCanonicalKey: f.project.canonicalKey), limit: 1000).results
        let original = results[results.count - 1], middle = results[results.count - 2], latest = results[results.count - 3]
        let first = ReviewReadGate(), firstTask = Task { await first.wait() }
        let second = ReviewReadGate(), secondTask = Task { await second.wait() }
        defer { firstTask.cancel(); secondTask.cancel(); Task { await first.open(); await second.open() } }
        await f.database.gateSessionListReadsForTesting(firstTask)
        let before = await f.database.sessionListReadCountForTesting()
        f.model.openSearchResult(original)
        try await wait { await f.database.sessionListReadCountForTesting() > before }
        f.model.selectSession(middle.sessionID)
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil && f.model.pendingDatabaseForTesting == nil }
        await f.database.gateSessionListReadsForTesting(secondTask)
        await first.open()
        try await wait { await f.database.sessionListReadCountForTesting() >= before + 2 }
        f.model.selectSession(latest.sessionID)
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && !f.model.sourceReloadRecovery.isRetrying }
        await f.database.gateSessionListReadsForTesting(nil)
        await second.open()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 201)
        XCTAssertTrue(f.model.sessions.contains { $0.id == latest.sessionID })
        XCTAssertFalse(f.model.sessions.contains { $0.id == original.sessionID || $0.id == middle.sessionID })
        XCTAssertEqual(f.model.requestedPageDepthForTesting, 1)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 401)
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 2)
    }

    private func failReissuedSecondPage(_ f: Fixture) async throws {
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.gateSessionPagesForTesting(held)
        f.model.loadMoreSessions()
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.sourceReloadRecovery.error != nil }
        await f.database.failSessionListReadOnceForTesting()
        f.model.gateSessionPagesForTesting(nil)
        await gate.open()
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 1)
        XCTAssertEqual(f.model.requestedPageDepthForTesting, 2)
    }

    func testUnclickedDeeperRetryIsSatisfiedOnlyByCoveringBackgroundSnapshot() async throws {
        let f = try await fixture(count: 605)
        try await failReissuedSecondPage(f)
        let before = await f.database.sessionListReadCountForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertEqual(f.model.sessions.count, 400)
        XCTAssertEqual(f.model.sessionPageDepthForTesting, 2)
        XCTAssertNil(f.model.sessionListError)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 600)
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, before + 1)
    }

    func testExhaustedBackgroundSnapshotSatisfiesQueuedDeeperRetryWithoutAnotherRead() async throws {
        let f = try await fixture(count: 605)
        try await failReissuedSecondPage(f)
        let retained = f.model.sessions.prefix(100).map { String($0.id) }.joined(separator: ",")
        let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM session WHERE project_id = ? AND id NOT IN (" + retained + ")", arguments: [f.project.id])
        }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summarySidebarGateForTesting = held
        let before = await f.database.sessionListReadCountForTesting()
        let summary = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summarySidebarWaitingForTesting }
        f.model.retrySessionLoad()
        var loading: [Bool] = []
        let subscription = f.model.sessionPageChanges.map(\.isLoading).removeDuplicates().dropFirst().sink { loading.append($0) }
        defer { subscription.cancel() }
        f.model.summarySidebarGateForTesting = nil
        await gate.open(); await summary.value
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, before + 1)
        XCTAssertEqual(f.model.sessions.count, 100)
        XCTAssertFalse(f.model.hasMoreSessions)
        XCTAssertNil(f.model.sessionListError)
        XCTAssertTrue(loading.isEmpty)
    }

    func testSessionPageErrorsRedactSQLAndArgumentsAndDeduplicateDiagnostics() async throws {
        for pagination in [false, true] {
            let f = try await fixture(count: 430)
            if pagination { f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions } }
            let error = DatabaseError(resultCode: .SQLITE_BUSY, message: "private-page-message",
                sql: "SELECT 'private-page-sql'", arguments: ["private-page-argument"], publicStatementArguments: true)
            var logs: [TraceModel.SummaryReadFailure] = []
            f.model.summaryReadFailureForTesting = { logs.append($0) }
            for attempt in 0..<2 {
                if pagination { await f.database.failSessionPageReadOnceForTesting(error) }
                else { await f.database.failSessionListReadOnceForTesting(error) }
                if attempt > 0 { f.model.retrySessionLoad() }
                else if pagination { f.model.loadMoreSessions() }
                else { f.model.selectProject(f.project.id) }
                try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
                XCTAssertEqual(f.model.sessionListError, pagination
                    ? "Could not load more sessions. Try again." : "Could not load sessions. Try again.")
            }
            XCTAssertEqual(logs.count, 1)
            f.model.retrySessionLoad()
            try await wait { !f.model.isLoadingSessions && f.model.sessionListError == nil }
            if pagination { await f.database.failSessionPageReadOnceForTesting(error); f.model.loadMoreSessions() }
            else {
                let page = try await f.database.search(query: "NavigationNeedle")
                let result = try XCTUnwrap(page.results.first)
                await f.database.failSessionListReadOnceForTesting(error)
                f.model.openSearchResult(result)
            }
            try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
            XCTAssertEqual(logs.count, 2)
        }
    }

    func testTerminalRestorationLookupFailureRetainsEligibilityAndCompletesSummaryTail() async throws {
        for code in [ResultCode.SQLITE_BUSY, .SQLITE_IOERR] {
            for phase in [IndexProgress.Phase.complete, .failed, .cancelled] {
                let (f, saved) = try await restorationFixture()
                var failures: [TraceModel.SummaryReadFailure] = []
                f.model.summaryReadFailureForTesting = { failures.append($0) }
                var pass = IndexProgress(phase: .indexing)
                await f.model.receiveProgress(pass)
                await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: code, message: "Synthetic restoration failure"))
                let attemptsBefore = await f.database.sessionReadCountForTesting()
                var costPublications = 0
                let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costPublications += 1 }
                defer { subscription.cancel() }
                pass.phase = phase
                await f.model.receiveProgress(pass)
                let attemptsAfter = await f.database.sessionReadCountForTesting()
                let injectionPending = await f.database.sessionReadFailurePendingForTesting()
                XCTAssertEqual(attemptsAfter, attemptsBefore + 1)
                XCTAssertFalse(injectionPending)
                XCTAssertEqual(failures, [.init(operation: .restoration, primaryCode: code.rawValue, extendedCode: code.rawValue)])
                XCTAssertNil(f.model.selectedSessionID)
                XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
                XCTAssertNil(f.model.startupError)
                XCTAssertGreaterThan(costPublications, 0)
                try await assertFullSummary(f, messageCount: 6)
                let present = try await f.database.session(id: saved.id)
                XCTAssertNotNil(present)
                let idleAttempts = await f.database.sessionReadCountForTesting()
                await f.clock.advance(by: .seconds(60))
                // Observe scheduled work as well as selection: no hidden lookup may
                // consume an attempt without finishing navigation yet.
                for _ in 0..<3 {
                    await Task.yield()
                    let currentAttempts = await f.database.sessionReadCountForTesting()
                    XCTAssertEqual(currentAttempts, idleAttempts)
                }
                XCTAssertNil(f.model.selectedSessionID, "lookup failures add no automatic restoration retry")
                await f.model.refreshSummariesForTesting(lightweight: false)
                try await wait { f.model.selectedSessionID == saved.id && !f.model.messages.isEmpty }
                XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
            }
        }
    }

    func testConfirmedTerminalMissingRestorationStillEndsEligibility() async throws {
        for phase in [IndexProgress.Phase.complete, .failed, .cancelled] {
            let (f, saved) = try await restorationFixture()
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            _ = try await f.database.synchronizeConfiguredRoots([])
            pass.phase = phase
            await f.model.receiveProgress(pass)
            XCTAssertNil(f.model.selectedSessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
            try await assertFullSummary(f, messageCount: 0)
            await f.coordinator.indexAll(scope: .proseOnly)
            let present = try await f.database.session(id: saved.id)
            XCTAssertNotNil(present)
            await f.model.refreshSummariesForTesting(lightweight: false)
            XCTAssertNil(f.model.selectedSessionID, "confirmed terminal absence ends launch restoration")
        }
    }

    func testActiveWorkflowRestorationFailureOrAbsenceRemainsEligible() async throws {
        for missing in [false, true] {
            let (f, saved) = try await restorationFixture()
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            if missing { _ = try await f.database.synchronizeConfiguredRoots([]) }
            else {
                await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY, message: "Synthetic restoration failure"))
            }
            await f.model.refreshSummariesForTesting(lightweight: false)
            XCTAssertNil(f.model.selectedSessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
            if missing { await f.coordinator.indexAll(scope: .proseOnly) }
            pass.phase = .complete
            await f.model.receiveProgress(pass)
            try await wait { f.model.selectedSessionID == saved.id && !f.model.messages.isEmpty }
        }
    }

    func testGatedRestorationResultsRejectSupersedingActions() async throws {
        for fails in [false, true] {
            for boundary in 0..<6 {
                let (f, saved) = try await restorationFixture()
                let sessions = try await f.database.sessions()
                var failures: [TraceModel.SummaryReadFailure] = []
                f.model.summaryReadFailureForTesting = { failures.append($0) }
                let other = try XCTUnwrap(sessions.first { $0.id != saved.id })
                if fails {
                    await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR, message: "Synthetic restoration failure"))
                }
                let gate = ReviewReadGate(), held = Task { await gate.wait() }
                defer { held.cancel(); Task { await gate.open() } }
                f.model.summaryRestorationGateForTesting = held
                let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
                try await wait { f.model.summaryRestorationWaitingForTesting }
                f.model.summaryRestorationGateForTesting = nil
                switch boundary {
                case 0:
                    f.model.settings.lastSessionID = other.id
                    await f.model.refreshSummariesForTesting(lightweight: false)
                    try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
                case 1:
                    f.model.selectSession(other.id)
                    try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
                case 2: f.model.clearSession()
                case 3:
                    let replacement = try IndexDatabase(url: f.root.appendingPathComponent("replacement.sqlite"))
                    let coordinator = IndexCoordinator(database: replacement, sources: [], clock: f.clock)
                    let committed = await f.model.attach(database: replacement, coordinator: coordinator)
                    XCTAssertTrue(committed)
                case 4: await f.model.prepareToTerminate()
                default:
                    f.model.settings.onboardingComplete = true
                    f.model.failSourceConfigurationForTesting = true
                    f.model.reloadSourcesAndRebuild()
                    try await wait { f.model.sourceReloadRecovery.error != nil }
                }
                let selected = f.model.selectedSessionID, stored = f.model.settings.lastSessionID
                let rows = f.model.messages.map(\.locator), alert = f.model.startupError
                await gate.open()
                await refresh.value
                XCTAssertEqual(f.model.selectedSessionID, selected)
                XCTAssertEqual(f.model.settings.lastSessionID, stored)
                XCTAssertEqual(f.model.messages.map(\.locator), rows)
                XCTAssertEqual(f.model.startupError, alert)
                XCTAssertNotEqual(f.model.selectedSessionID, saved.id)
                XCTAssertTrue(failures.isEmpty, "obsolete restoration failures must not be logged")
            }
        }
    }

    private func takeBrowsingIntent(_ model: TraceModel, action: Int) {
        func edit<Value: Equatable>(_ value: Value, _ binding: Binding<Value>) {
            userIntentBinding(binding, model: model).wrappedValue = value
        }
        switch action {
        case 0:
            edit("New main search", Binding(get: { model.mainSearch.query }, set: { model.mainSearch.query = $0 }))
            model.searchMain()
        case 1:
            edit("New global search", Binding(get: { model.globalSearch.query }, set: { model.globalSearch.query = $0 }))
            model.search()
        case 2: edit("OtherReview", Binding(get: { model.projectFilter }, set: { model.projectFilter = $0 }))
        case 3: model.cancelLaunchRestorationForUserIntent(); model.globalSearch.filters.errorsOnly = true
        case 4: model.cancelLaunchRestorationForUserIntent(); model.globalSearch.filters.agents = [.codex]
        case 5: edit(.relevance, Binding(get: { model.settings.searchSort }, set: { model.settings.searchSort = $0 }))
        case 6:
            model.mainSearch.query = "Prior automatic query"
            edit("", Binding(get: { model.mainSearch.query }, set: { model.mainSearch.query = $0 }))
            model.searchMain()
        default: edit(false, Binding(get: { true }, set: { model.setMainSearchPanelVisible($0) }))
        }
    }

    func testUserIntentBindingCancelsBeforeChangedAssignmentAndIgnoresUnchangedValues() async throws {
        let (f, saved) = try await restorationFixture()
        var value = "existing"
        var writes = 0
        let binding = userIntentBinding(Binding(get: { value }, set: {
            XCTAssertFalse(f.model.launchRestorationEligibleForTesting, "cancel before the underlying setter can reenter")
            writes += 1
            value = $0
        }), model: f.model)
        binding.wrappedValue = "existing"
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
        binding.wrappedValue = "edited"
        binding.wrappedValue = "edited"
        XCTAssertEqual(writes, 1)
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        XCTAssertFalse(try XCTUnwrap(f.model.fullSummaryCompletionForTesting).mayRestoreSession)
    }

    func testExplicitRestorationCancellationIsIdempotentWithoutClearingSavedSession() async throws {
        let (f, saved) = try await restorationFixture()
        f.model.cancelLaunchRestorationForUserIntent()
        f.model.cancelLaunchRestorationForUserIntent()
        await f.model.receiveProgress(.init(phase: .complete))
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        XCTAssertEqual(f.model.fullSummaryCompletionForTesting?.storedSessionID, saved.id)
        XCTAssertFalse(f.model.launchRestorationEligibleForTesting)
    }

    func testUnchangedIntentBindingAndAutomaticPaginationKeepRestorationEligible() async throws {
        let (f, saved) = try await restorationFixture(count: 605)
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertEqual(f.model.sessions.count, 200)
        userIntentBinding(Binding(get: { f.model.projectFilter }, set: { f.model.projectFilter = $0 }),
                          model: f.model).wrappedValue = f.model.projectFilter
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        await f.database.failSessionListReadOnceForTesting()
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertNotNil(f.model.sidebarSummaryError)
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        let beforeRetry = await f.database.sessionListReadCountForTesting()
        f.model.retrySidebarSummary()
        try await wait { !f.model.sidebarSummaryRetryPendingForTesting && f.model.sidebarSummaryError == nil }
        let afterRetry = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(afterRetry, beforeRetry + 1, "execute a real summary Retry")
        XCTAssertEqual(f.model.sessions.count, 400)
        XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.selectedSession?.id == saved.id && !f.model.messages.isEmpty }
        let completed = try XCTUnwrap(f.model.fullSummaryCompletionForTesting)
        XCTAssertFalse(completed.mayRestoreSession)
        XCTAssertEqual(completed.selectedSessionID, saved.id)
    }

    func testUserIntentBindingForwardsWrapperAndUnderlyingTransactions() async throws {
        for decorateUnderlying in [false, true] {
            let (f, saved) = try await restorationFixture()
            var value = 0
            var animations: [Animation?] = []
            let base = Binding(get: { value }, set: { newValue, transaction in
                XCTAssertFalse(f.model.launchRestorationEligibleForTesting)
                animations.append(transaction.animation)
                value = newValue
            })
            let binding = decorateUnderlying
                ? userIntentBinding(base.animation(.linear), model: f.model)
                : userIntentBinding(base, model: f.model).animation(.linear)
            binding.wrappedValue = 0
            XCTAssertTrue(animations.isEmpty)
            XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
            binding.wrappedValue = 1
            XCTAssertEqual(animations, [.linear])
            XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        }
    }

    func testSidebarSummaryFailureRetainsBrowsingAndRetryCompletesFullTail() async throws {
        let (f, saved) = try await restorationFixture(count: 605)
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.refreshSummariesForTesting(lightweight: false)
        let projects = f.model.projects.map(\.id), sessions = f.model.sessions.map(\.id)
        let recent = f.model.recentSessions.map(\.id), statistics = f.model.statistics?.messageCount
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        await f.database.failSessionListReadOnceForTesting()
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        var costs = 0
        let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costs += 1 }
        defer { subscription.cancel() }
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertNotNil(f.model.sidebarSummaryError)
        XCTAssertEqual(f.model.projects.map(\.id), projects)
        XCTAssertEqual(f.model.sessions.map(\.id), sessions)
        XCTAssertEqual(f.model.recentSessions.map(\.id), recent)
        XCTAssertEqual(f.model.statistics?.messageCount, statistics)
        XCTAssertEqual(costs, 1)
        XCTAssertTrue(failures.contains { $0.operation == .sidebar })
        XCTAssertNotNil(f.model.fullSummaryCompletionForTesting)
        XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summarySidebarGateForTesting = held
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        let before = await f.database.sessionListReadCountForTesting()
        f.model.retrySidebarSummary(); f.model.retrySidebarSummary()
        try await wait { f.model.summarySidebarWaitingForTesting }
        let during = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(during, before + 1)
        XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
        f.model.summarySidebarGateForTesting = nil
        await gate.open()
        try await wait { !f.model.sidebarSummaryRetryPendingForTesting }
        XCTAssertNil(f.model.sidebarSummaryError)
        XCTAssertEqual(costs, 2)
        XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        let after = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(after, before + 1)
        await f.clock.advance(by: .seconds(60))
        for _ in 0..<3 { await Task.yield() }
        let idle = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(idle, after, "failure feedback introduces no automatic retry")
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.selectedSessionID == saved.id && !f.model.messages.isEmpty }
    }

    func testPageSuccessDoesNotClearOutstandingSidebarSummaryFailure() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        let error = try XCTUnwrap(f.model.sidebarSummaryError)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        XCTAssertEqual(f.model.sidebarSummaryError, error)
        f.model.retrySidebarSummary()
        try await wait { !f.model.sidebarSummaryRetryPendingForTesting && f.model.sidebarSummaryError == nil }
        XCTAssertEqual(f.model.sessions.count, 400)
    }

    func testQueuedSummaryRetryCoalescesAndSuccessfulRefreshSatisfiesIt() async throws {
        for failBackground in [false, true] {
            let f = try await fixture()
            await f.database.failSessionListReadOnceForTesting()
            await f.model.refreshSummariesForTesting(lightweight: false)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summarySidebarGateForTesting = held
            if failBackground { await f.database.failSessionListReadOnceForTesting() }
            let before = await f.database.sessionListReadCountForTesting()
            let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
            try await wait { f.model.summarySidebarWaitingForTesting }
            f.model.retrySidebarSummary(); f.model.retrySidebarSummary()
            f.model.summarySidebarGateForTesting = nil
            await gate.open(); await refresh.value
            try await wait { !f.model.sidebarSummaryRetryPendingForTesting && f.model.sidebarSummaryError == nil }
            let after = await f.database.sessionListReadCountForTesting()
            XCTAssertEqual(after, before + (failBackground ? 2 : 1))
        }
    }

    func testObsoleteSidebarFailuresCannotPublishErrorsOrDiagnostics() async throws {
        for boundary in 0..<6 {
            let f = try await fixture()
            var failures: [TraceModel.SummaryReadFailure] = []
            f.model.summaryReadFailureForTesting = { failures.append($0) }
            await f.database.failSessionListReadOnceForTesting()
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summarySidebarGateForTesting = held
            let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
            try await wait { f.model.summarySidebarWaitingForTesting }
            f.model.summarySidebarGateForTesting = nil
            switch boundary {
            case 0: await f.model.refreshSummariesForTesting(lightweight: false)
            case 1:
                f.model.selectProject(f.project.id)
                try await wait { !f.model.isLoadingSessions }
            case 2:
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.sourceReloadRecovery.error != nil }
            case 3:
                let replacement = try IndexDatabase(url: f.root.appendingPathComponent("sidebar-replacement.sqlite"))
                let committed = await f.model.attach(database: replacement,
                    coordinator: IndexCoordinator(database: replacement, sources: [], clock: f.clock))
                XCTAssertTrue(committed)
            case 4: await f.model.prepareToTerminate()
            default: refresh.cancel()
            }
            await gate.open(); await refresh.value
            if boundary == 1 {
                XCTAssertNotNil(f.model.sidebarSummaryError, "project navigation cannot discard a global read failure")
                XCTAssertTrue(failures.contains { $0.operation == .sidebar })
            } else {
                XCTAssertNil(f.model.sidebarSummaryError)
                XCTAssertFalse(failures.contains { $0.operation == .sidebar })
            }
        }
    }

    func testSidebarErrorPublicationReentryRejectsItsFullTail() async throws {
        let f = try await fixture()
        await f.database.failSessionListReadOnceForTesting()
        let before = await f.database.summaryMetadataReadCountsForTesting()
        var reentered = false
        let subscription = f.model.sidebarChanges.map(\.sidebarSummaryError).removeDuplicates().dropFirst().sink { error in
            if error != nil, !reentered {
                reentered = true
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
            }
        }
        defer { subscription.cancel() }
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.sourceReloadRecovery.error != nil }
        let after = await f.database.summaryMetadataReadCountsForTesting()
        XCTAssertTrue(reentered)
        XCTAssertEqual(after.health, before.health)
        XCTAssertEqual(after.statistics, before.statistics)
    }

    func testRootRefreshDebtSurvivesSupersededSynchronizationBeforeBookkeeping() async throws {
        let (f, removed) = try await twoRootHealthFixture()
        try line(99, project: "RemovedHealthProject").write(to: removed.appendingPathComponent("removed.jsonl"))
        await f.coordinator.indexAll(scope: .proseOnly)
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertTrue(f.model.projects.contains { $0.displayName == "RemovedHealthProject" })
        let removedSession = try XCTUnwrap(f.model.sessions.first { $0.sourcePath.hasPrefix(removed.path) })
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.rootSynchronizationBookkeepingGateForTesting = held
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.rootSynchronizationBookkeepingWaitingForTesting }
        XCTAssertTrue(f.model.sessions.contains { $0.id == removedSession.id })
        f.model.rootSynchronizationBookkeepingGateForTesting = nil
        f.model.reloadSourcesAndRebuild()
        await gate.open()
        try await wait { f.model.schedulerForTesting != nil && f.model.progress.phase == .waiting }
        XCTAssertFalse(f.model.projects.isEmpty)
        XCTAssertFalse(f.model.projects.contains { $0.displayName == "RemovedHealthProject" })
        XCTAssertFalse(f.model.sessions.contains { $0.id == removedSession.id })
        XCTAssertEqual(f.model.statistics?.messageCount, 6)
        try await wait { !f.model.rootSummaryRefreshPendingForTesting }
        XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertEqual(f.model.sourceHealth.map(\.rootPath), [f.root.path])
    }

    func testRootRefreshDebtRetainsFailedPartsAndOrdinarySummaryFinishesThem() async throws {
        for failSidebar in [false, true] {
            let (f, removed) = try await twoRootHealthFixture()
            let removedSession = try XCTUnwrap(f.model.sessions.first { $0.sourcePath.hasPrefix(removed.path) })
            if failSidebar { await f.database.failSessionListReadOnceForTesting() }
            else { await f.database.failStatisticsReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY)) }
            f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.schedulerForTesting != nil && f.model.progress.phase == .waiting }
            XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
            if failSidebar { XCTAssertTrue(f.model.sessions.contains { $0.id == removedSession.id }) }
            else { XCTAssertEqual(f.model.statistics?.messageCount, 7) }
            await f.model.refreshSummariesForTesting(lightweight: true)
            if !failSidebar { XCTAssertEqual(f.model.statistics?.messageCount, 7) }
            await f.model.refreshSummariesForTesting(lightweight: false)
            try await wait { !f.model.rootSummaryRefreshPendingForTesting }
            XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
            XCTAssertFalse(f.model.sessions.contains { $0.id == removedSession.id })
            XCTAssertEqual(f.model.statistics?.messageCount, 6)
            XCTAssertNotNil(f.model.fullSummaryCompletionForTesting)
        }
    }

    func testFailedSuccessorRetainsRootRefreshDebtAndDatabaseReplacementDiscardsIt() async throws {
        for replace in [false, true] {
            let (f, removed) = try await twoRootHealthFixture()
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.configuredRootsPublicationGateForTesting = held
            f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.configuredRootsPublicationWaitingForTesting }
            XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
            f.model.configuredRootsPublicationGateForTesting = nil
            if replace {
                let database = try IndexDatabase(url: f.root.appendingPathComponent("root-debt-replacement.sqlite"))
                let committed = await f.model.attach(database: database,
                    coordinator: IndexCoordinator(database: database, sources: [], clock: f.clock))
                XCTAssertTrue(committed)
                XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
            } else {
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.sourceReloadRecovery.error != nil }
                XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
                XCTAssertFalse(f.model.costsTotalsUpdating, "installed database debt is not active work after attachment failure")
                await f.model.refreshSummariesForTesting(lightweight: false)
                try await wait { !f.model.rootSummaryRefreshPendingForTesting }
                XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
                XCTAssertFalse(f.model.sourceHealth.contains { $0.rootPath == removed.path })
                XCTAssertEqual(f.model.statistics?.messageCount, 6)
            }
            await gate.open()
            try await wait { !f.model.configuredRootsPublicationWaitingForTesting }
            XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        }
    }

    func testFailedSummaryRetryStaysRetryableAndExplicitIntentPreventsRestoration() async throws {
        let (f, saved) = try await restorationFixture()
        await f.database.failSessionListReadOnceForTesting()
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertTrue(f.model.launchRestorationEligibleForTesting)
        XCTAssertNotNil(f.model.statistics)
        f.model.cancelLaunchRestorationForUserIntent()
        await f.database.failSessionListReadOnceForTesting()
        let before = await f.database.sessionListReadCountForTesting()
        f.model.retrySidebarSummary(); f.model.retrySidebarSummary()
        try await wait { !f.model.sidebarSummaryRetryPendingForTesting }
        XCTAssertNotNil(f.model.sidebarSummaryError)
        let failed = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(failed, before + 1)
        f.model.retrySidebarSummary()
        try await wait { !f.model.sidebarSummaryRetryPendingForTesting && f.model.sidebarSummaryError == nil }
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        XCTAssertFalse(f.model.launchRestorationEligibleForTesting)
        let successful = await f.database.sessionListReadCountForTesting()
        XCTAssertEqual(successful, before + 2)
    }

    func testSummaryRetryRejectsObsoleteResultsAndSuccessfulEmptyDataClearsCache() async throws {
        for boundary in 0..<4 {
            let f = try await fixture()
            await f.database.failSessionListReadOnceForTesting()
            await f.model.refreshSummariesForTesting(lightweight: false)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summarySidebarGateForTesting = held
            f.model.retrySidebarSummary()
            try await wait { f.model.summarySidebarWaitingForTesting }
            f.model.summarySidebarGateForTesting = nil
            switch boundary {
            case 0:
                let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
                try await queue.write { db in try db.execute(sql: "DELETE FROM source_root") }
                await f.model.refreshSummariesForTesting(lightweight: false)
                XCTAssertTrue(f.model.projects.isEmpty)
                XCTAssertTrue(f.model.sessions.isEmpty)
                XCTAssertEqual(f.model.statistics?.messageCount, 0)
            case 1:
                f.model.selectProject(f.project.id)
                try await wait { !f.model.isLoadingSessions }
            case 2:
                let database = try IndexDatabase(url: f.root.appendingPathComponent("retry-replacement.sqlite"))
                let committed = await f.model.attach(database: database,
                    coordinator: IndexCoordinator(database: database, sources: [], clock: f.clock))
                XCTAssertTrue(committed)
            default: await f.model.prepareToTerminate()
            }
            let sessions = f.model.sessions.map(\.id), projects = f.model.projects.map(\.id)
            let error = f.model.sidebarSummaryError
            await gate.open()
            try await wait { !f.model.sidebarSummaryRetryPendingForTesting && !f.model.summarySidebarWaitingForTesting }
            XCTAssertEqual(f.model.sessions.map(\.id), sessions)
            XCTAssertEqual(f.model.projects.map(\.id), projects)
            if boundary == 1 { XCTAssertNil(f.model.sidebarSummaryError) }
            else { XCTAssertEqual(f.model.sidebarSummaryError, error) }
        }
    }

    func testTerminationDiscardsInFlightRootBookkeepingAndItsCachedPublication() async throws {
        let (f, _) = try await twoRootHealthFixture()
        let cached = f.model.sessions.map(\.id)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.rootSynchronizationBookkeepingGateForTesting = held
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.rootSynchronizationBookkeepingWaitingForTesting }
        let terminating = Task { await f.model.prepareToTerminate() }
        try await wait { f.model.terminationStartedForTesting }
        await gate.open(); await terminating.value
        XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertEqual(f.model.sessions.map(\.id), cached)
        XCTAssertNil(f.model.sidebarSummaryError)
    }

    func testSameDatabaseSourceReloadCommitAcceptsInitialAndAdditionalPages() async throws {
        for initialPage in [true, false] {
            let f = try await fixture(count: 605)
            if !initialPage {
                f.model.selectProject(f.project.id)
                try await wait { !f.model.isLoadingSessions }
            }
            let attachmentGate = ReviewReadGate(), attachmentTask = Task { await attachmentGate.wait() }
            let pageGate = ReviewReadGate(), pageTask = Task { await pageGate.wait() }
            defer {
                attachmentTask.cancel(); pageTask.cancel()
                Task { await attachmentGate.open(); await pageGate.open() }
            }
            f.model.sourceChangeAttachmentGateForTesting = attachmentTask
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
            if initialPage {
                await f.database.gateSessionListReadsForTesting(pageTask)
                f.model.selectProject(f.project.id)
            } else {
                f.model.gateSessionPagesForTesting(pageTask)
                f.model.loadMoreSessions()
            }
            try await wait { f.model.isLoadingSessions }
            await attachmentGate.open()
            try await wait { !f.model.sourceChangeAttachmentWaitingForTesting && f.model.schedulerForTesting != nil }
            await f.database.gateSessionListReadsForTesting(nil)
            f.model.gateSessionPagesForTesting(nil)
            await pageGate.open()
            try await wait { !f.model.isLoadingSessions }
            XCTAssertEqual(f.model.sessions.count, initialPage ? 200 : 400)
            XCTAssertEqual(f.model.totalSessionCount, 605)
            XCTAssertTrue(f.model.hasMoreSessions)
            XCTAssertNil(f.model.sessionListError)
            while f.model.hasMoreSessions {
                f.model.loadMoreSessions()
                try await wait { !f.model.isLoadingSessions }
            }
            XCTAssertEqual(Set(f.model.sessions.map(\.id)).count, 605)
        }
    }

    func testConfigurationSupersessionReissuesStillCurrentPageAndLoadMoreIntent() async throws {
        for additionalPage in [false, true] {
            let f = try await fixture()
            if additionalPage {
                f.model.selectProject(f.project.id)
                try await wait { !f.model.isLoadingSessions }
            }
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            let before = await f.database.sessionListReadCountForTesting()
            if additionalPage {
                f.model.gateSessionPagesForTesting(held)
                f.model.loadMoreSessions()
            } else {
                await f.database.gateSessionListReadsForTesting(held)
                f.model.selectProject(f.project.id)
                try await wait { await f.database.sessionListReadCountForTesting() == before + 1 }
            }
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.sourceReloadRecovery.error != nil }
            await f.database.gateSessionListReadsForTesting(nil)
            f.model.gateSessionPagesForTesting(nil)
            await gate.open()
            try await wait { !f.model.isLoadingSessions && f.model.sessions.count == (additionalPage ? 400 : 200) }
            let after = await f.database.sessionListReadCountForTesting()
            XCTAssertEqual(after, before + (additionalPage ? 1 : 2))
            XCTAssertEqual(f.model.totalSessionCount, 430)
            XCTAssertTrue(f.model.hasMoreSessions)
            XCTAssertNil(f.model.sessionListError)
        }
    }

    func testObsoleteInitialPagesCannotReplaceNavigationDatabaseOrTermination() async throws {
        for boundary in 0..<3 {
            let f = try await fixture()
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            let before = await f.database.sessionListReadCountForTesting()
            await f.database.gateSessionListReadsForTesting(held)
            f.model.selectProject(f.project.id)
            try await wait { await f.database.sessionListReadCountForTesting() == before + 1 }
            await f.database.gateSessionListReadsForTesting(nil)
            switch boundary {
            case 0:
                let other = try XCTUnwrap(f.model.projects.first { $0.id != f.project.id })
                f.model.selectProject(other.id)
                try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 4 }
            case 1:
                let replacement = try IndexDatabase(url: f.root.appendingPathComponent("page-replacement.sqlite"))
                await f.model.attachForTesting(database: replacement, sources: [])
            default: await f.model.prepareToTerminate()
            }
            let accepted = f.model.sessions.map(\.id)
            await gate.open()
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(f.model.sessions.map(\.id), accepted)
            XCTAssertNil(f.model.sessionListError)
        }
    }

    func testSearchNavigationPreservesGlobalSummaryFailure() async throws {
        let f = try await fixture()
        try await search(f)
        let result = try XCTUnwrap(f.model.mainSearch.results.first { $0.projectCanonicalKey != f.project.canonicalKey })
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        let failure = try XCTUnwrap(f.model.sidebarSummaryError)
        f.model.openSearchResult(result, fromMainSearch: true)
        try await wait { !f.model.isLoadingSessions && f.model.selectedSession != nil }
        XCTAssertEqual(f.model.selectedProjectCanonicalKey, result.projectCanonicalKey)
        XCTAssertEqual(f.model.sidebarSummaryError, failure)
        XCTAssertNil(f.model.sessionListError)
        f.model.retrySidebarSummary()
        try await wait { !f.model.isRetryingSidebarSummary }
        XCTAssertNil(f.model.sidebarSummaryError)
    }

    func testPageRetryExecutesWhileSummaryRetryTailIsHeld() async throws {
        let f = try await fixture(count: 605)
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryTailGateForTesting = held
        f.model.retrySidebarSummary()
        try await wait { f.model.summaryTailWaitingForTesting }
        XCTAssertTrue(f.model.isRetryingSidebarSummary)
        XCTAssertNil(f.model.sidebarSummaryError)
        await f.database.failSessionPageReadOnceForTesting()
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        f.model.retrySessionLoad()
        try await wait { !f.model.isLoadingSessions && f.model.sessions.count == 400 }
        XCTAssertNil(f.model.sessionListError)
        XCTAssertTrue(f.model.isRetryingSidebarSummary)
        await gate.open()
        try await wait { !f.model.isRetryingSidebarSummary }
    }

    func testSameSummaryRetryErrorStillPublishesStartAndFinish() async throws {
        let f = try await fixture()
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        let error = f.model.sidebarSummaryError
        var states: [Bool] = []
        let subscription = f.model.sidebarChanges.map(\.isRetryingSidebarSummary).removeDuplicates().dropFirst().sink { states.append($0) }
        defer { subscription.cancel() }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summarySidebarGateForTesting = held
        await f.database.failSessionListReadOnceForTesting()
        f.model.retrySidebarSummary(); f.model.retrySidebarSummary()
        try await wait { f.model.summarySidebarWaitingForTesting }
        XCTAssertEqual(states, [true])
        await gate.open()
        try await wait { !f.model.isRetryingSidebarSummary }
        XCTAssertEqual(states, [true, false])
        XCTAssertEqual(f.model.sidebarSummaryError, error)
        XCTAssertNil(f.model.fullSummaryCompletionForTesting?.terminalWorkflowID)
    }

    func testDeletedProjectRetryPreservesTerminalPolicyAndRejectsItForNewWorkflow() async throws {
        for phase in [IndexProgress.Phase.complete, .failed, .cancelled] {
            for newerWorkflow in [false, true] {
                let f = try await fixture(count: 2)
                for search in [f.model.globalSearch, f.model.mainSearch] { search.selectProject(f.project) }
                var pass = IndexProgress(phase: .indexing)
                await f.model.receiveProgress(pass)
                _ = try await f.database.synchronizeConfiguredRoots([])
                await f.clock.advance(by: .milliseconds(250))
                await f.model.receiveProgress(pass)
                XCTAssertTrue(f.model.globalSearch.isResolvingProjectFilter)
                await f.database.failSessionListReadOnceForTesting()
                pass.phase = phase
                await f.model.receiveProgress(pass)
                XCTAssertFalse(f.model.globalSearch.isResolvingProjectFilter)
                XCTAssertNotNil(f.model.sidebarSummaryError)
                // Repeated failures must not consume the terminal policy.
                await f.database.failSessionListReadOnceForTesting()
                f.model.retrySidebarSummary()
                try await wait { !f.model.isRetryingSidebarSummary }
                if newerWorkflow {
                    var next = IndexProgress(phase: .indexing)
                    next.incremental = true
                    await f.model.receiveProgress(next)
                }
                f.model.retrySidebarSummary()
                try await wait { !f.model.isRetryingSidebarSummary }
                XCTAssertNil(f.model.sidebarSummaryError)
                XCTAssertEqual(f.model.globalSearch.isResolvingProjectFilter, newerWorkflow)
                XCTAssertEqual(f.model.mainSearch.isResolvingProjectFilter, newerWorkflow)
                XCTAssertEqual(f.model.globalSearch.projectFilterCanonicalKey,
                    !newerWorkflow && phase == .complete ? nil : f.project.canonicalKey)
                XCTAssertEqual(f.model.mainSearch.projectFilterCanonicalKey, f.project.canonicalKey)
            }
        }
    }

    func testLightweightSidebarFailureDisplayAndLogsAreEpisodeScoped() async throws {
        let f = try await fixture(count: 2)
        let cached = f.model.sessions.map(\.id)
        let metadata = await f.database.summaryMetadataReadCountsForTesting()
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        for index in 0...4 {
            if index > 0 { await f.clock.advance(by: .milliseconds(250)) }
            await f.database.failSessionListReadOnceForTesting()
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false, lightweight: true)
            XCTAssertEqual(f.model.sidebarSummaryError != nil, index == 4)
            XCTAssertEqual(f.model.sessions.map(\.id), cached)
            XCTAssertNil(f.model.sessionListError)
        }
        XCTAssertEqual(failures.count, 1)
        let after = await f.database.summaryMetadataReadCountsForTesting()
        XCTAssertEqual(after.health, metadata.health)
        XCTAssertEqual(after.statistics, metadata.statistics)
        await f.model.refreshSummariesForTesting(lightweight: true)
        XCTAssertNil(f.model.sidebarSummaryError)
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: true)
        XCTAssertNil(f.model.sidebarSummaryError)
        XCTAssertEqual(failures.count, 2)
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertNotNil(f.model.sidebarSummaryError)
        XCTAssertEqual(failures.count, 2)
    }

    func testRootDebtDoesNotAddMetadataOrRestorationReadsToProgressUpdates() async throws {
        let (f, _) = try await twoRootHealthFixture()
        await f.database.failStatisticsReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.schedulerForTesting != nil && !f.model.indexingPassActiveForTesting && !f.model.costsTotalsUpdating }
        XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
        f.model.settings.lastSessionID = try XCTUnwrap(f.model.sessions.first).id
        let metadata = await f.database.summaryMetadataReadCountsForTesting()
        let restorationReads = await f.database.sessionReadCountForTesting()
        var pass = IndexProgress(phase: .indexing)
        for _ in 0..<10 {
            await f.clock.advance(by: .milliseconds(250))
            await f.model.receiveProgress(pass)
        }
        let after = await f.database.summaryMetadataReadCountsForTesting()
        let afterRestoration = await f.database.sessionReadCountForTesting()
        XCTAssertEqual(after.health, metadata.health)
        XCTAssertEqual(after.statistics, metadata.statistics)
        XCTAssertEqual(afterRestoration, restorationReads)
        XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertEqual(f.model.statistics?.messageCount, 6)
    }

    private func twoRootUsageFixture() async throws -> (Fixture, URL) {
        let (f, removed) = try await twoRootHealthFixture()
        for (root, tokens, id) in [(f.root, 10, "kept-cost"), (removed, 20, "removed-cost")] {
            let record: [String: Any] = ["type": "assistant", "uuid": id, "sessionId": id,
                "cwd": "/tmp/\(id)", "timestamp": 1_700_000_000_000,
                "message": ["model": "claude-sonnet-4-20250514", "content": id,
                            "usage": ["input_tokens": tokens, "output_tokens": 1]]]
            let name = root == f.root ? "sessions.jsonl" : "removed.jsonl"
            try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: root.appendingPathComponent(name))
        }
        await f.coordinator.indexAll(scope: .proseOnly)
        f.model.settings.costRange = .allTime
        var terminal = IndexProgress(phase: .complete)
        terminal.indexChanged = true
        terminal.rollupsChanged = true
        await f.model.receiveProgress(terminal)
        try await wait { f.model.usage.reduce(0) { $0 + $1.inputTokens } == 30 && !f.model.costsTotalsUpdating }
        return (f, removed)
    }

    func testRootRemovalRepairsUsageWithoutIndexingAndRetainsFailedUsageDebt() async throws {
        for failRepair in [false, true] {
            let (f, _) = try await twoRootUsageFixture()
            if failRepair { await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY)) }
            f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.schedulerForTesting != nil && !f.model.indexingPassActiveForTesting && !f.model.costsTotalsUpdating }
            if failRepair {
                XCTAssertNotNil(f.model.costsError)
                XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
                XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
                await f.clock.advance(by: .seconds(60))
                XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
                await f.model.refreshSummariesForTesting(lightweight: false)
            }
            try await wait { !f.model.rootSummaryRefreshPendingForTesting }
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
            XCTAssertEqual(f.model.usage.map(\.projectName), ["kept-cost"])
            XCTAssertNil(f.model.costsError)
            XCTAssertFalse(f.model.indexingPassActiveForTesting)
        }
    }

    func testRootSummaryLoadCostsFalseDoesNotRepublishCachedUsage() async throws {
        let (f, _) = try await twoRootUsageFixture()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        var publications = 0
        let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        f.model.sourceChangeAttachmentGateForTesting = held
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
        XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertEqual(publications, 0, "the source reload's loadCosts:false must be respected")
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
        await gate.open()
        try await wait { !f.model.rootSummaryRefreshPendingForTesting }
        XCTAssertEqual(publications, 1, "publish only the accepted repaired snapshot")
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
    }

    func testSummaryReadLoggingDistinguishesErrorsAndResetsOnSuccess() async throws {
        let f = try await fixture(count: 2)
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        for code in [ResultCode.SQLITE_BUSY, .SQLITE_BUSY, .SQLITE_IOERR_READ] {
            await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: code, message: "Read failed"))
            await f.model.refreshSummariesForTesting(lightweight: false)
        }
        XCTAssertEqual(failures.map(\.extendedCode), [ResultCode.SQLITE_BUSY.rawValue, ResultCode.SQLITE_IOERR_READ.rawValue])
        await f.model.refreshSummariesForTesting(lightweight: false)
        await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY, message: "Read failed"))
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertEqual(failures.count, 3)
    }

    func testRootRemovalRejectsOlderCompletedUsageSnapshot() async throws {
        let (f, _) = try await twoRootUsageFixture()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.usageSnapshotGateForTesting = held
        var terminal = IndexProgress(phase: .complete)
        terminal.indexChanged = true
        await f.model.receiveProgress(terminal)
        try await wait { f.model.usageSnapshotWaitingForTesting }
        f.model.usageSnapshotGateForTesting = nil
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { !f.model.indexingPassActiveForTesting && f.model.schedulerForTesting != nil }
        XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
        await gate.open()
        try await wait { !f.model.usageSnapshotWaitingForTesting && !f.model.costsTotalsUpdating }
        try await wait { f.model.usage.reduce(0) { $0 + $1.inputTokens } == 10 }
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
        XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
    }

    func testRepeatedConfigurationSupersessionRetainsPageIntentAndLoading() async throws {
        for more in [false, true] {
            let f = try await fixture(count: 605)
            if more { f.model.selectProject(f.project.id); try await wait { !f.model.isLoadingSessions } }
            let first = ReviewReadGate(), firstTask = Task { await first.wait() }
            let second = ReviewReadGate(), secondTask = Task { await second.wait() }
            defer { firstTask.cancel(); secondTask.cancel(); Task { await first.open(); await second.open() } }
            var states: [Bool] = []
            let subscription = f.model.sessionPageChanges.map(\.isLoading).removeDuplicates().dropFirst().sink {
                if $0 || !states.isEmpty { states.append($0) }
            }
            defer { subscription.cancel() }
            let before = await f.database.sessionListReadCountForTesting()
            if more { f.model.gateSessionPagesForTesting(firstTask); f.model.loadMoreSessions() }
            else {
                await f.database.gateSessionListReadsForTesting(firstTask)
                f.model.selectProject(f.project.id)
                try await wait { await f.database.sessionListReadCountForTesting() > before }
            }
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.pendingDatabaseForTesting == nil && f.model.sourceReloadRecovery.error != nil }
            await f.database.gateSessionListReadsForTesting(secondTask)
            f.model.gateSessionPagesForTesting(nil)
            await first.open()
            let replacementCount = before + (more ? 1 : 2)
            try await wait { await f.database.sessionListReadCountForTesting() == replacementCount }
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.pendingDatabaseForTesting == nil && !f.model.sourceReloadRecovery.isRetrying }
            await f.database.gateSessionListReadsForTesting(nil)
            await second.open()
            try await wait { !f.model.isLoadingSessions }
            XCTAssertEqual(states, [true, false])
            XCTAssertEqual(f.model.sessions.count, more ? 400 : 200)
            XCTAssertEqual(f.model.totalSessionCount, 605)
            XCTAssertTrue(f.model.hasMoreSessions)
            XCTAssertNil(f.model.sessionListError)
            f.model.loadMoreSessions()
            try await wait { !f.model.isLoadingSessions }
            XCTAssertEqual(f.model.sessions.count, more ? 600 : 400)
        }
    }

    func testQueuedRetryOfReissuedExtraPageRetainsRequestedDepth() async throws {
        let f = try await fixture(count: 605)
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let pageGate = ReviewReadGate(), heldPage = Task { await pageGate.wait() }
        let summaryGate = ReviewReadGate(), heldSummary = Task { await summaryGate.wait() }
        defer { heldPage.cancel(); heldSummary.cancel(); Task { await pageGate.open(); await summaryGate.open() } }
        f.model.gateSessionPagesForTesting(heldPage)
        f.model.loadMoreSessions()
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.pendingDatabaseForTesting == nil && f.model.sourceReloadRecovery.error != nil }
        await f.database.failSessionListReadOnceForTesting()
        f.model.gateSessionPagesForTesting(nil)
        await pageGate.open()
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        XCTAssertEqual(f.model.sessions.count, 200)
        f.model.summarySidebarGateForTesting = heldSummary
        let summary = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summarySidebarWaitingForTesting }
        f.model.retrySessionLoad()
        f.model.summarySidebarGateForTesting = nil
        await summaryGate.open(); await summary.value
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 400)
        XCTAssertEqual(f.model.totalSessionCount, 605)
        XCTAssertTrue(f.model.hasMoreSessions)
        XCTAssertNil(f.model.sessionListError)
        f.model.loadMoreSessions()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertEqual(f.model.sessions.count, 600)
    }

    func testQueuedSummaryRetryRetiresOnRebuildWithoutClearingFailure() async throws {
        for summaryBlocker in [false, true] {
            let f = try await fixture(count: 2)
            await f.database.failSessionListReadOnceForTesting()
            await f.model.refreshSummariesForTesting(lightweight: false)
            let error = try XCTUnwrap(f.model.sidebarSummaryError)
            let blocker = ReviewReadGate(), blocked = Task { await blocker.wait() }
            let progress = ReviewReadGate(), heldProgress = Task { await progress.wait() }
            defer { blocked.cancel(); heldProgress.cancel(); Task { await blocker.open(); await progress.open() } }
            var background: Task<Void, Never>?
            if summaryBlocker {
                f.model.summarySidebarGateForTesting = blocked
                background = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
                try await wait { f.model.summarySidebarWaitingForTesting }
            } else {
                await f.database.gateSessionListReadsForTesting(blocked)
                f.model.selectProject(f.project.id)
                try await wait { f.model.isLoadingSessions }
            }
            f.model.retrySidebarSummary()
            XCTAssertTrue(f.model.isRetryingSidebarSummary)
            f.model.settings.onboardingComplete = true
            f.model.schedulerProgressGateForTesting = heldProgress
            f.model.rebuildIndex()
            try await wait { f.model.schedulerProgressWaitingForTesting }
            XCTAssertFalse(f.model.isRetryingSidebarSummary)
            XCTAssertFalse(f.model.sidebarSummaryRetryPendingForTesting)
            XCTAssertEqual(f.model.sidebarSummaryError, error)
            f.model.summarySidebarGateForTesting = nil
            await f.database.gateSessionListReadsForTesting(nil)
            await blocker.open(); await background?.value
            f.model.retrySidebarSummary()
            try await wait { !f.model.isRetryingSidebarSummary && f.model.sidebarSummaryError == nil }
            f.model.schedulerProgressGateForTesting = nil
            await progress.open()
            await f.model.schedulerForTesting?.waitUntilIdle()
        }
    }

    func testNavigationDrainsQueuedGlobalRetryAndAttachmentRetiresIt() async throws {
        for attachment in [false, true] {
            let f = try await fixture(count: 2)
            await f.database.failSessionListReadOnceForTesting()
            await f.model.refreshSummariesForTesting(lightweight: false)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summarySidebarGateForTesting = held
            let background = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
            try await wait { f.model.summarySidebarWaitingForTesting }
            f.model.retrySidebarSummary()
            f.model.summarySidebarGateForTesting = nil
            if attachment {
                await f.model.attachForTesting(database: f.database, sources: [ClaudeCodeSource(roots: [f.root])])
                XCTAssertFalse(f.model.isRetryingSidebarSummary)
                XCTAssertNotNil(f.model.sidebarSummaryError)
            } else {
                f.model.selectProject(f.project.id)
                try await wait { !f.model.isLoadingSessions && !f.model.isRetryingSidebarSummary }
                XCTAssertNil(f.model.sidebarSummaryError)
            }
            await gate.open(); await background.value
            XCTAssertFalse(f.model.isRetryingSidebarSummary)
        }
    }

    func testUsageRequestsSurviveRunningWorkAndImmediatePromotesWaiting() async throws {
        let f = try await fixture(count: 2)
        let before = await f.database.usageReadCountForTesting()
        f.model.requestUsageRefreshForTesting(repair: true, immediately: false)
        try await wait { f.model.usageRefreshWaitingForTesting }
        await f.clock.advance(by: .milliseconds(999))
        let waiting = await f.database.usageReadCountForTesting()
        XCTAssertEqual(waiting, before)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.usageSnapshotGateForTesting = held
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        try await wait { f.model.usageSnapshotWaitingForTesting }
        XCTAssertTrue(f.model.usageRefreshRunningForTesting)
        var publications = 0
        let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        f.model.requestUsageRefreshForTesting(repair: true, immediately: false)
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        f.model.usageSnapshotGateForTesting = nil
        await gate.open()
        try await wait { !f.model.costsTotalsUpdating }
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 2)
        XCTAssertEqual(publications, 1, "the older snapshot cannot satisfy newer requests")
        XCTAssertNil(f.model.costsError)
        await f.clock.advance(by: .seconds(60))
        let idle = await f.database.usageReadCountForTesting()
        XCTAssertEqual(idle, after)
    }

    func testNonterminalProgressPreservesRunningUsageRepairForTerminalRecovery() async throws {
        for repair in [false, true] {
            let f = try await fixture(count: 2)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.usageSnapshotGateForTesting = held
            f.model.requestUsageRefreshForTesting(repair: repair, immediately: true)
            try await wait { f.model.usageSnapshotWaitingForTesting }
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            XCTAssertTrue(f.model.usageRefreshRunningForTesting)
            f.model.usageSnapshotGateForTesting = nil
            await gate.open()
            try await wait { !f.model.usageRefreshRunningForTesting }
            let before = await f.database.usageReadCountForTesting()
            pass.phase = .complete
            await f.model.receiveProgress(pass)
            await f.clock.advance(by: .seconds(1))
            try await wait { !f.model.costsTotalsUpdating }
            let after = await f.database.usageReadCountForTesting()
            XCTAssertEqual(after, before + 1)
        }
    }

    func testOlderUsageFailureCannotConsumeNewerRepairRequest() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        let before = await f.database.usageReadCountForTesting()
        f.model.usageFailureGateForTesting = held
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        try await wait { f.model.usageFailureWaitingForTesting }
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        f.model.usageFailureGateForTesting = nil
        await gate.open()
        try await wait { !f.model.costsTotalsUpdating }
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 2)
        XCTAssertNil(f.model.costsError)
        await f.clock.advance(by: .seconds(60))
        let idle = await f.database.usageReadCountForTesting()
        XCTAssertEqual(idle, after)
    }

    func testAttachmentCommitResumesQueuedInstalledUsageWork() async throws {
        let f = try await fixture(count: 2)
        let scheduler = try XCTUnwrap(f.model.schedulerForTesting)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.schedulerCompletionGateForTesting = held
        await scheduler.request(watermarks: ["usage-retirement": 1])
        try await wait { f.model.schedulerCompletionWaitingForTesting }
        let attachment = Task { await f.model.attachForTesting(database: f.database, sources: [ClaudeCodeSource(roots: [f.root])]) }
        try await wait { f.model.pendingDatabaseForTesting != nil }
        let before = await f.database.usageReadCountForTesting()
        f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
        XCTAssertFalse(f.model.costsTotalsUpdating)
        f.model.schedulerCompletionGateForTesting = nil
        await gate.open(); await attachment.value
        try await wait { !f.model.costsTotalsUpdating }
        let after = await f.database.usageReadCountForTesting()
        XCTAssertEqual(after, before + 1)
    }

    func testIdleAttachmentHandoffReschedulesRunningUsageWithoutRootChanges() async throws {
        for sourceReload in [false, true] {
            let (f, _) = try await twoRootUsageFixture()
            let record: [String: Any] = ["type": "assistant", "uuid": "kept-cost", "sessionId": "kept-cost",
                "cwd": "/tmp/kept-cost", "timestamp": 1_700_000_000_000,
                "message": ["model": "claude-sonnet-4-20250514", "content": "kept-cost",
                            "usage": ["input_tokens": 12, "output_tokens": 1]]]
            try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: f.root.appendingPathComponent("sessions.jsonl"))
            await f.coordinator.indexAll(scope: .proseOnly)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            var publications = 0
            let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in publications += 1 }
            defer { subscription.cancel() }
            let before = await f.database.usageReadCountForTesting()
            f.model.usageSnapshotGateForTesting = held
            f.model.requestUsageRefreshForTesting(repair: true, immediately: true)
            try await wait { f.model.usageSnapshotWaitingForTesting }
            if sourceReload {
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.schedulerForTesting != nil && !f.model.indexingPassActiveForTesting }
            } else {
                let sources = try XCTUnwrap(f.model.sourceReloadSourcesForTesting)
                await f.model.attachForTesting(database: f.database, sources: sources)
            }
            XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 30)
            f.model.usageSnapshotGateForTesting = nil
            await gate.open()
            try await wait { !f.model.costsTotalsUpdating }
            let after = await f.database.usageReadCountForTesting()
            XCTAssertEqual(after, before + 2)
            XCTAssertEqual(publications, 1)
            XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 32)
        }
    }

    func testUsageOnlySourceReloadSkipsMetadataAndRepairsFailedDebt() async throws {
        let (f, _) = try await twoRootUsageFixture()
        await f.database.failUsageReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.schedulerForTesting != nil && !f.model.costsTotalsUpdating }
        XCTAssertNotNil(f.model.costsError)
        XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertFalse(f.model.rootMetadataRefreshPendingForTesting)
        let metadata = await f.database.summaryMetadataReadCountsForTesting()
        let restores = await f.database.sessionReadCountForTesting()
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.schedulerForTesting != nil && !f.model.rootSummaryRefreshPendingForTesting }
        let after = await f.database.summaryMetadataReadCountsForTesting()
        let restored = await f.database.sessionReadCountForTesting()
        XCTAssertEqual(after.health, metadata.health)
        XCTAssertEqual(after.statistics, metadata.statistics)
        XCTAssertEqual(restored, restores)
        XCTAssertEqual(f.model.usage.reduce(0) { $0 + $1.inputTokens }, 10)
        XCTAssertFalse(f.model.costsTotalsUpdating)
    }

    func testRejectedRootSessionSnapshotRetainsDebtAfterReplacementFailure() async throws {
        let (f, removed) = try await twoRootHealthFixture()
        f.model.selectProject(f.project.id)
        try await wait { !f.model.isLoadingSessions }
        let removedID = try XCTUnwrap(f.model.sessions.first { $0.sourcePath.hasPrefix(removed.path) }).id
        let searchPage = try await f.database.search(query: "NavigationNeedle")
        let result = try XCTUnwrap(searchPage.results.first {
            $0.projectCanonicalKey == f.project.canonicalKey && !$0.sourcePath.hasPrefix(removed.path)
        })
        try await f.model.synchronizeRootsForTesting(ClaudeCodeSource(roots: [f.root]).roots, database: f.database)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summarySidebarGateForTesting = held
        let summary = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summarySidebarWaitingForTesting }
        await f.database.failSessionListReadOnceForTesting()
        f.model.openSearchResult(result, fromMainSearch: true)
        try await wait { !f.model.isLoadingSessions && f.model.sessionListError != nil }
        f.model.summarySidebarGateForTesting = nil
        await gate.open(); await summary.value
        XCTAssertNil(f.model.sidebarSummaryError)
        XCTAssertTrue(f.model.rootSessionRefreshPendingForTesting)
        XCTAssertTrue(f.model.sessions.contains { $0.id == removedID })
        f.model.retrySessionLoad()
        try await wait { !f.model.isLoadingSessions }
        XCTAssertFalse(f.model.rootSessionRefreshPendingForTesting)
        XCTAssertFalse(f.model.sessions.contains { $0.id == removedID })
        try await wait { !f.model.rootSummaryRefreshPendingForTesting }
    }

    func testSidebarVisibleErrorNeverIncludesDatabaseSQLOrArguments() async throws {
        let f = try await fixture(count: 2)
        let error = DatabaseError(resultCode: .SQLITE_BUSY, message: "private-message-sentinel",
                                  sql: "SELECT 'private-sql-sentinel'", arguments: ["private-argument-sentinel"])
        var logs: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { logs.append($0) }
        for _ in 0..<2 {
            await f.database.failSessionListReadOnceForTesting(error)
            await f.model.refreshSummariesForTesting(lightweight: false)
            XCTAssertEqual(f.model.sidebarSummaryError, "Could not refresh projects. Try again.")
        }
        XCTAssertEqual(logs.count, 1)
        await f.model.refreshSummariesForTesting()
        XCTAssertNil(f.model.sidebarSummaryError)
        await f.database.failSessionListReadOnceForTesting(error)
        await f.model.refreshSummariesForTesting(lightweight: false)
        XCTAssertEqual(logs.count, 2)
    }

    func testPendingDatabaseRootDebtIsInheritedPromotedOrDiscardedWithoutSpinner() async throws {
        for failure in [false, true] {
            let f = try await fixture(count: 2), replacement = try await fixture(count: 3)
            let previous = try XCTUnwrap(f.model.schedulerForTesting)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.schedulerCompletionGateForTesting = held
            await previous.request(watermarks: ["retirement": 1])
            try await wait { f.model.schedulerCompletionWaitingForTesting }
            let first = Task { await f.model.attach(database: replacement.database, coordinator: replacement.coordinator) }
            try await wait { f.model.pendingDatabaseForTesting === replacement.database }
            try await f.model.synchronizeRootsForTesting([], database: replacement.database)
            XCTAssertTrue(f.model.pendingAttachmentRootRefreshForTesting)
            XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
            XCTAssertFalse(f.model.costsTotalsUpdating)
            let firstToken = f.model.pendingAttachmentTokenForTesting
            let successor = IndexCoordinator(database: replacement.database, sources: [], clock: f.clock)
            let second = Task { await f.model.attach(database: replacement.database, coordinator: successor) }
            try await wait { f.model.pendingAttachmentTokenForTesting != firstToken }
            XCTAssertTrue(f.model.pendingAttachmentRootRefreshForTesting)
            if failure { await replacement.database.failFailureCountsOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY)) }
            f.model.schedulerCompletionGateForTesting = nil
            await gate.open()
            let firstCommitted = await first.value, secondCommitted = await second.value
            XCTAssertFalse(firstCommitted)
            XCTAssertEqual(secondCommitted, !failure)
            XCTAssertFalse(f.model.pendingAttachmentRootRefreshForTesting)
            if failure {
                XCTAssertFalse(f.model.costsTotalsUpdating)
                XCTAssertTrue(f.model.databaseForTesting === f.database)
                XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
            } else {
                // Commit makes promoted usage work eligible; its spinner lasts
                // only until that actual repaired read completes.
                try await wait { !f.model.costsTotalsUpdating }
                XCTAssertTrue(f.model.rootSummaryRefreshPendingForTesting)
                await f.model.refreshSummariesForTesting(lightweight: false)
                try await wait { !f.model.rootSummaryRefreshPendingForTesting }
                XCTAssertTrue(f.model.sessions.isEmpty)
            }
        }
    }

    func testErrorClearReentryCannotLoseAcceptedRootPageAcknowledgment() async throws {
        let (f, _) = try await twoRootHealthFixture()
        try await f.model.synchronizeRootsForTesting(ClaudeCodeSource(roots: [f.root]).roots, database: f.database)
        await f.database.failSessionListReadOnceForTesting()
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { !f.model.costsTotalsUpdating }
        XCTAssertTrue(f.model.rootSessionRefreshPendingForTesting)
        var reentered = false
        let subscription = f.model.sidebarChanges.map(\.sidebarSummaryError).removeDuplicates().dropFirst().sink { error in
            if error == nil, !reentered {
                reentered = true
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
            }
        }
        defer { subscription.cancel() }
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.sourceReloadRecovery.error != nil }
        XCTAssertTrue(reentered)
        XCTAssertFalse(f.model.rootSessionRefreshPendingForTesting)
        XCTAssertFalse(f.model.rootSummaryRefreshPendingForTesting)
        XCTAssertFalse(f.model.costsTotalsUpdating)
    }

    func testFullSummaryCompletionRejectsObsoleteRestorationWork() async throws {
        for boundary in 0..<3 {
            let (f, _) = try await restorationFixture()
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summaryRestorationGateForTesting = held
            let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
            try await wait { f.model.summaryRestorationWaitingForTesting }
            f.model.summaryRestorationGateForTesting = nil
            switch boundary {
            case 0:
                f.model.cancelLaunchRestorationForUserIntent()
                await f.model.refreshSummariesForTesting(lightweight: false)
            case 1:
                let replacement = try IndexDatabase(url: f.root.appendingPathComponent("receipt-replacement.sqlite"))
                let committed = await f.model.attach(database: replacement,
                    coordinator: IndexCoordinator(database: replacement, sources: [], clock: f.clock))
                XCTAssertTrue(committed)
            default: await f.model.prepareToTerminate()
            }
            let receipt = f.model.fullSummaryCompletionForTesting?.summaryID
            await gate.open(); await refresh.value
            XCTAssertEqual(f.model.fullSummaryCompletionForTesting?.summaryID, receipt)
            if boundary == 0 { XCTAssertNotNil(receipt) }
            else { XCTAssertNil(receipt) }
        }
    }

    func testBrowsingIntentEndsFailedLaunchRestorationWithoutClearingSavedSession() async throws {
        for action in 0..<8 {
            let (f, saved) = try await restorationFixture()
            await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            await f.model.refreshSummariesForTesting(lightweight: false)
            XCTAssertNil(f.model.selectedSessionID)
            takeBrowsingIntent(f.model, action: action)
            let mainQuery = f.model.mainSearch.query, globalQuery = f.model.globalSearch.query
            let attempts = await f.database.sessionReadCountForTesting()
            await f.model.receiveProgress(.init(phase: .complete))
            await f.model.refreshSummariesForTesting(lightweight: false)
            let after = await f.database.sessionReadCountForTesting()
            XCTAssertEqual(after, attempts, "user intent ends even later launch lookups")
            XCTAssertNil(f.model.selectedSessionID)
            XCTAssertNil(f.model.selectedProjectCanonicalKey)
            XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
            XCTAssertEqual(f.model.mainSearch.query, mainQuery)
            XCTAssertEqual(f.model.globalSearch.query, globalQuery)
            if action == 2 { XCTAssertEqual(f.model.projectFilter, "OtherReview") }
            if action == 3 { XCTAssertTrue(f.model.globalSearch.filters.errorsOnly) }
            if action == 4 { XCTAssertEqual(f.model.globalSearch.filters.agents, [.codex]) }
        }
    }

    func testBrowsingIntentRejectsGatedSuccessfulRestorationButCompletesFullTail() async throws {
        for action in 0..<8 {
            let (f, saved) = try await restorationFixture()
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summaryRestorationGateForTesting = held
            let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
            try await wait { f.model.summaryRestorationWaitingForTesting }
            takeBrowsingIntent(f.model, action: action)
            var costPublications = 0
            let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costPublications += 1 }
            defer { subscription.cancel() }
            await gate.open(); await refresh.value
            XCTAssertNil(f.model.selectedSessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
            XCTAssertEqual(costPublications, 1)
            try await assertFullSummary(f, messageCount: 6)
        }
    }

    func testAutomaticSearchAndVisibilityDoNotEndLaunchRestoration() async throws {
        let (f, saved) = try await restorationFixture()
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.model.refreshSummariesForTesting(lightweight: false)
        f.model.setMainWindowVisible(true)
        f.model.setMainSearchPanelVisible(true)
        f.model.mainSearch.query = "NavigationNeedle"
        f.model.searchMain()
        f.model.globalSearch.query = "NavigationNeedle"
        f.model.search()
        f.model.projectFilter = "NavigationReview"
        f.model.settings.searchSort = .relevance
        await f.clock.advance(by: .milliseconds(100))
        try await wait { !f.model.mainSearch.isSearching && !f.model.globalSearch.isSearching }
        f.model.mainSearch.search(reset: false)
        f.model.globalSearch.search(reset: false)
        await f.clock.advance(by: .milliseconds(100))
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.selectedSession?.id == saved.id && !f.model.messages.isEmpty }
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
    }

    func testMetadataReadFailuresRetainIndependentCachedValuesAndCompleteTail() async throws {
        for mask in 1...3 {
            let f = try await fixture(count: 2)
            await f.model.refreshSummariesForTesting(lightweight: false)
            let healthFiles = f.model.sourceHealth.map(\.fileCount)
            let old = try XCTUnwrap(f.model.statistics)
            XCTAssertFalse(healthFiles.isEmpty)
            XCTAssertEqual(old.messageCount, 6)
            let queue = try DatabaseQueue(path: f.root.appendingPathComponent("index.sqlite").path)
            try await queue.write { db in try db.execute(sql: "DELETE FROM source_root") }
            try await f.model.diagnostics.reset()
            if mask & 1 != 0 {
                await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR_READ))
            }
            if mask & 2 != 0 {
                await f.database.failStatisticsReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            }
            var failures: [TraceModel.SummaryReadFailure] = []
            f.model.summaryReadFailureForTesting = { failures.append($0) }
            var costs = 0
            let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costs += 1 }
            defer { subscription.cancel() }
            let before = await f.database.summaryMetadataReadCountsForTesting()
            await f.model.refreshSummariesForTesting(lightweight: false)
            let after = await f.database.summaryMetadataReadCountsForTesting()
            XCTAssertEqual(after.health, before.health + 1)
            XCTAssertEqual(after.statistics, before.statistics + 1)
            XCTAssertEqual(costs, 1)
            XCTAssertEqual(f.model.sourceHealth.map(\.fileCount), mask & 1 != 0 ? healthFiles : [])
            XCTAssertEqual(f.model.statistics?.messageCount, mask & 2 != 0 ? old.messageCount : 0)
            XCTAssertEqual(failures.map(\.operation), (mask & 1 != 0 ? [.sourceHealth] : []) + (mask & 2 != 0 ? [.statistics] : []))
            if mask & 1 != 0 {
                XCTAssertEqual(failures.first?.primaryCode, ResultCode.SQLITE_IOERR.rawValue)
                XCTAssertEqual(failures.first?.extendedCode, ResultCode.SQLITE_IOERR_READ.rawValue)
            }
            let snapshot = await f.model.diagnostics.value()
            if mask & 2 != 0 {
                XCTAssertFalse(snapshot.days.contains { $0.indexSizeBytes > 0 }, "failed statistics must not record cached bytes")
                XCTAssertEqual(f.model.statistics?.databaseBytes, old.databaseBytes)
            } else { XCTAssertTrue(snapshot.days.contains { $0.indexSizeBytes > 0 }) }
            await f.model.refreshSummariesForTesting(lightweight: false)
            XCTAssertTrue(f.model.sourceHealth.isEmpty)
            XCTAssertEqual(f.model.statistics?.messageCount, 0)
            XCTAssertEqual(costs, 2)
            XCTAssertEqual(failures.count, mask == 3 ? 2 : 1, "success must not repeat failure diagnostics")
        }
    }

    private func twoRootHealthFixture() async throws -> (Fixture, URL) {
        let f = try await fixture(count: 2)
        await f.model.prepareToTerminate()
        let removed = FileManager.default.temporaryDirectory.appendingPathComponent("TraceRemovedHealth-\(UUID())")
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try line(99).write(to: removed.appendingPathComponent("removed.jsonl"))
        addTeardownBlock { try? FileManager.default.removeItem(at: removed) }
        let source = ClaudeCodeSource(roots: [f.root, removed])
        let coordinator = IndexCoordinator(database: f.database, sources: [source], clock: f.clock)
        await coordinator.indexAll(scope: .proseOnly)
        let model = try uninstalledModel(clock: f.clock, diagnosticsURL: f.root.appendingPathComponent("health-pruning.json"))
        let committed = await model.attach(database: f.database, coordinator: coordinator)
        XCTAssertTrue(committed)
        model.sourceReloadSourcesForTesting = [source]
        await model.refreshSummariesForTesting(lightweight: false)
        XCTAssertEqual(Set(model.sourceHealth.map(\.rootPath)), Set([f.root.path, removed.path]))
        return (.init(root: f.root, clock: f.clock, model: model, database: f.database,
                      coordinator: coordinator, project: f.project), removed)
    }

    func testRootReconciliationPrunesHealthBeforeFailedReadEvenWhenRootsAreUnchanged() async throws {
        for alreadySynchronized in [false, true] {
            let (f, removed) = try await twoRootHealthFixture()
            let old = try XCTUnwrap(f.model.sourceHealth.first { $0.rootPath == f.root.path })
            let source = ClaudeCodeSource(roots: [f.root])
            if alreadySynchronized { _ = try await f.database.synchronizeConfiguredRoots(source.roots) }
            await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.sourceChangeAttachmentGateForTesting = held
            f.model.sourceReloadSourcesForTesting = [source]
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.sourceChangeAttachmentWaitingForTesting }
            if alreadySynchronized { await f.model.refreshSummariesForTesting(lightweight: false) }
            XCTAssertFalse(f.model.sourceHealth.contains { $0.rootPath == removed.path })
            let retained = try XCTUnwrap(f.model.sourceHealth.first)
            XCTAssertEqual(retained.rootPath, old.rootPath)
            XCTAssertEqual(retained.fileCount, old.fileCount)
            XCTAssertEqual(retained.earliestSessionMilliseconds, old.earliestSessionMilliseconds)
            XCTAssertEqual(retained.lastScanMilliseconds, old.lastScanMilliseconds)
            await gate.open()
            try await wait { !f.model.sourceChangeAttachmentWaitingForTesting && f.model.schedulerForTesting != nil }
            await f.model.refreshSummariesForTesting(lightweight: false)
            XCTAssertEqual(f.model.sourceHealth.map(\.rootPath), [f.root.path])
        }
    }

    func testFailedRootSynchronizationRetainsCachedHealth() async throws {
        let (f, _) = try await twoRootHealthFixture()
        let cached = f.model.sourceHealth.map(\.rootPath)
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        XCTAssertEqual(f.model.sourceHealth.map(\.rootPath), cached)
    }

    func testObsoleteRootSynchronizationCannotPruneSuccessorHealth() async throws {
        for terminate in [false, true] {
            let (f, removed) = try await twoRootHealthFixture()
            let cached = f.model.sourceHealth.map(\.rootPath)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.configuredRootsPublicationGateForTesting = held
            f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.configuredRootsPublicationWaitingForTesting }
            f.model.configuredRootsPublicationGateForTesting = nil
            if terminate { await f.model.prepareToTerminate() }
            else {
                await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR))
                f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root, removed])]
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.schedulerForTesting != nil && f.model.progress.phase == .waiting }
            }
            let current = f.model.sourceHealth.map(\.rootPath)
            XCTAssertEqual(current, cached)
            await gate.open()
            try await wait { !f.model.configuredRootsPublicationWaitingForTesting }
            XCTAssertEqual(f.model.sourceHealth.map(\.rootPath), current)
        }
    }

    func testHealthPruningPublicationReentrancyRejectsRetiredConfiguration() async throws {
        let (f, removed) = try await twoRootHealthFixture()
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.configuredRootsPublicationGateForTesting = held
        f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root])]
        let before = await f.database.summaryMetadataReadCountsForTesting()
        var reentered = false
        let subscription = f.model.sidebarChanges.map(\.sourceHealth).dropFirst().sink { health in
            if !reentered && !health.contains(where: { $0.rootPath == removed.path }) {
                reentered = true
                f.model.sourceReloadSourcesForTesting = [ClaudeCodeSource(roots: [f.root, removed])]
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
            }
        }
        defer { subscription.cancel() }
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.configuredRootsPublicationWaitingForTesting }
        f.model.configuredRootsPublicationGateForTesting = nil
        await gate.open()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        XCTAssertTrue(reentered)
        let after = await f.database.summaryMetadataReadCountsForTesting()
        XCTAssertEqual(after.health, before.health, "obsolete pruning must not continue into a summary refresh")
        XCTAssertEqual(after.statistics, before.statistics)
        XCTAssertNil(f.model.schedulerForTesting)
    }

    func testMetadataReadFailureDoesNotPreventSavedSessionRestoration() async throws {
        let (f, saved) = try await restorationFixture()
        await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR))
        await f.database.failStatisticsReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.selectedSession?.id == saved.id && !f.model.messages.isEmpty }
        XCTAssertEqual(failures.map(\.operation), [.sourceHealth, .statistics])
        XCTAssertNil(f.model.startupError)
    }

    func testGatedMetadataFailuresRejectObsoleteSummaryOwners() async throws {
        for boundary in 0..<5 {
            let f = try await fixture(count: 2)
            await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
            await f.database.failStatisticsReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR))
            var failures: [TraceModel.SummaryReadFailure] = []
            f.model.summaryReadFailureForTesting = { failures.append($0) }
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summaryMetadataGateForTesting = held
            let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
            try await wait { f.model.summaryMetadataWaitingForTesting }
            f.model.summaryMetadataGateForTesting = nil
            switch boundary {
            case 0: await f.model.refreshSummariesForTesting(lightweight: false)
            case 1:
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.sourceReloadRecovery.error != nil }
            case 2:
                let replacement = try IndexDatabase(url: f.root.appendingPathComponent("metadata-replacement.sqlite"))
                await f.model.attachForTesting(database: replacement, sources: [])
            case 3: await f.model.prepareToTerminate()
            default: refresh.cancel()
            }
            let messages = f.model.statistics?.messageCount, health = f.model.sourceHealth.map(\.fileCount)
            await gate.open(); await refresh.value
            XCTAssertTrue(failures.isEmpty)
            XCTAssertEqual(f.model.statistics?.messageCount, messages)
            XCTAssertEqual(f.model.sourceHealth.map(\.fileCount), health)
        }
    }

    func testCancelledRestorationFailureCannotLogOrRestore() async throws {
        let (f, saved) = try await restorationFixture()
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR))
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryRestorationGateForTesting = held
        let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summaryRestorationWaitingForTesting }
        refresh.cancel()
        await gate.open(); await refresh.value
        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        f.model.summaryRestorationGateForTesting = nil
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.selectedSession?.id == saved.id }
    }

    func testUserIntentRejectsGatedRestorationFailureDiagnostics() async throws {
        let (f, saved) = try await restorationFixture()
        await f.database.failSessionReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR))
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = { failures.append($0) }
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryRestorationGateForTesting = held
        let refresh = Task { await f.model.refreshSummariesForTesting(lightweight: false) }
        try await wait { f.model.summaryRestorationWaitingForTesting }
        takeBrowsingIntent(f.model, action: 0)
        await gate.open(); await refresh.value
        XCTAssertTrue(failures.isEmpty)
        XCTAssertNil(f.model.selectedSessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, saved.id)
        try await assertFullSummary(f, messageCount: 6)
    }

    func testFailureObservationReentrancyRejectsRemainingSummaryTail() async throws {
        let f = try await fixture(count: 2)
        defer { f.model.summaryReadFailureForTesting = nil }
        await f.database.failSourceHealthReadOnceForTesting(DatabaseError(resultCode: .SQLITE_BUSY))
        await f.database.failStatisticsReadOnceForTesting(DatabaseError(resultCode: .SQLITE_IOERR))
        f.model.failSourceConfigurationForTesting = true
        var failures: [TraceModel.SummaryReadFailure] = []
        f.model.summaryReadFailureForTesting = {
            failures.append($0)
            f.model.reloadSourcesAndRebuild()
        }
        await f.model.refreshSummariesForTesting(lightweight: false)
        try await wait { f.model.sourceReloadRecovery.error != nil }
        XCTAssertEqual(failures.map(\.operation), [.sourceHealth])
        XCTAssertNil(f.model.statistics)
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
        try await wait { f.model.transcriptBanner?.details != nil && !f.model.transcriptRecoveryPendingForTesting }
        await f.clock.advance(by: .seconds(60))
        let exhausted = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(exhausted, before + 3, "exhaustion must stop automatic reads")
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting()
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting, "fresh failures do not reset an exhausted episode")
        f.model.retrySelectedTranscript()
        XCTAssertNil(f.model.transcriptBanner?.details)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertNil(f.model.transcriptBanner?.details)
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
            XCTAssertNil(f.model.transcriptBanner?.details)
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
        XCTAssertNil(f.model.transcriptBanner?.details)
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
            let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
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
                try await wait { f.model.transcriptBanner?.details != nil }
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
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
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
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
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
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        await f.database.failTranscriptReadsForTesting(count: 4)
        f.model.selectSession(session.id)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1), .seconds(4)].enumerated() {
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
        }
        try await wait { f.model.transcriptBanner?.details != nil }
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
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
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
        try await prepareStartup(f.model, sources: [ClaudeCodeSource(roots: [f.root])])
        f.model.schedulerProgressGateForTesting = task
        f.model.selectionTranscriptReadGateForTesting = task
        f.model.rebuildIndex()
        try await wait { f.model.schedulerProgressWaitingForTesting }
        XCTAssertFalse(f.model.pendingRebuildForTesting)
        // A second reset would erase this navigation while the rebuild is held.
        f.model.selectSession(-123)
        f.model.startReadyStartupForTesting(sources: [ClaudeCodeSource(roots: [f.root])])
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
        try await prepareStartup(model, sources: [source])
        model.startReadyStartupForTesting(sources: [source])
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
        let subscription = f.model.sidebarChanges.map(\.sourceReloadRecovery).removeDuplicates().dropFirst().sink { state in
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
            let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
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
            try await wait { (f.model.transcriptBanner?.feedback == .updating) }
            XCTAssertEqual(f.model.selectedSessionID, session.id)
            XCTAssertEqual(f.model.settings.lastSessionID, session.id)
            XCTAssertEqual(events.windows, 1, "missing data must expose the main window promptly")
            XCTAssertEqual(events.scrolls, 0)
            let before = await f.model.diagnostics.value()
            XCTAssertEqual(before.days.reduce(0) { $0 + $1.openCount }, 0)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
            XCTAssertTrue(try XCTUnwrap(f.model.transcriptBanner?.details).contains("temporarily unavailable"))
            await f.coordinator.indexAll(scope: .proseOnly)
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
            XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
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
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertEqual(f.model.messages.map(\.id), rows.map(\.id))
        XCTAssertNotNil(f.model.hydratedMessages[message.id])
        XCTAssertEqual(f.model.selectedProjectID, project)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        f.model.transcriptRecoveryPublicationGateForTesting = nil
        f.model.retrySelectedTranscript()
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating), "manual Retry preserves absence feedback")
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
        await f.coordinator.indexAll(scope: .proseOnly)
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        await gate.open()
        try await wait { !f.model.transcriptRecoveryPublicationWaitingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertNil(f.model.transcriptBanner?.details)
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
            XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
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
            XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
            XCTAssertNil(f.model.transcriptBanner?.details)
        }
    }

    private func exhaustReadRecovery(_ f: Fixture) async throws {
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1), .seconds(4)].enumerated() {
            XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating), "feedback remains until the budget finishes")
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
            XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
            try await exhaustReadRecovery(f)
            XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
            XCTAssertTrue(try XCTUnwrap(f.model.transcriptBanner?.details).contains("Synthetic transcript read failure"))
            XCTAssertFalse(try XCTUnwrap(f.model.transcriptBanner?.details).contains("wait for indexing"))
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
            XCTAssertNil(f.model.transcriptBanner?.details)
            XCTAssertEqual(f.model.selectedSessionID, session.id)
        }
    }

    func testPendingTransientSelectionCompletesOnceAfterTerminalRecoveryFailure() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        var pass = IndexProgress(phase: .indexing)
        await f.model.receiveProgress(pass)
        _ = try await f.database.synchronizeConfiguredRoots([])
        f.model.selectSession(session.id, showWindow: true)
        try await wait { (f.model.transcriptBanner?.feedback == .updating) }
        XCTAssertEqual(events.windows, 1)
        await f.database.failTranscriptReadsForTesting(count: 4)
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        try await exhaustReadRecovery(f)
        XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.settings.lastSessionID, session.id)
        XCTAssertEqual(events.scrolls, 0)
        let before = await f.model.diagnostics.value()
        XCTAssertEqual(before.days.reduce(0) { $0 + $1.openCount }, 0)
        await f.coordinator.indexAll(scope: .proseOnly)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == 1 }
        XCTAssertNil(f.model.transcriptBanner?.details)
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
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating), "an active pass retains temporary feedback")
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptBanner?.details).contains("Synthetic transcript read failure"))
        let before = await f.database.transcriptReadCountForTesting()
        await f.database.failTranscriptReadOnceForTesting()
        pass.phase = .complete
        await f.model.receiveProgress(pass)
        XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptBanner?.details).contains("Synthetic transcript read failure"))
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
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptBanner?.details).contains("Synthetic transcript read failure"))
        await f.database.failTranscriptReadOnceForTesting()
        successor.phase = .complete
        await f.model.receiveProgress(successor)
        XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        XCTAssertNotNil(f.model.transcriptBanner?.details)
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
            XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
            XCTAssertNil(f.model.transcriptBanner?.details)
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
            XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
            XCTAssertNil(f.model.transcriptBanner?.details)
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
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 0)
        return (f, session.id, other.id, gate, held)
    }

    private func exhaustTransientRecovery(_ f: Fixture) async throws {
        await f.database.failTranscriptReadsForTesting(count: 4)
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await exhaustReadRecovery(f)
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
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
        XCTAssertFalse((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertNotNil(f.model.transcriptBanner?.details)
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
        XCTAssertTrue((f.model.transcriptBanner?.feedback == .updating))
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        try await exhaustTransientRecovery(f)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
        XCTAssertEqual(f.model.selectedProjectID, project)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        XCTAssertEqual(f.model.messages.first?.id, message.id)
        XCTAssertNotNil(f.model.hydratedMessages[message.id])
        XCTAssertTrue(try XCTUnwrap(f.model.transcriptBanner?.details).contains("wait for indexing"))
        await gate.open()
        try await wait { f.model.progress.phase == .complete && !(f.model.transcriptBanner?.feedback == .updating) }
        XCTAssertNil(f.model.transcriptBanner?.details)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertFalse(f.model.messages.isEmpty)
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
    }

    func testExplicitMissingSelectionInReplacementGapCompletesOnce() async throws {
        let (f, _, sessionID, gate, _) = try await replacementGap()
        // The source has not yet been indexed by the replacement, so this read is missing.
        let before = await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount }
        let events = ReviewSelectionEvents()
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        f.model.selectSession(sessionID, showWindow: true)
        try await wait { (f.model.transcriptBanner?.feedback == .updating) && events.windows == 1 }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
        XCTAssertEqual(events.scrolls, 0)
        try await exhaustTransientRecovery(f)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 0)
        await gate.open()
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == before + 1 }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertNil(f.model.transcriptBanner?.details)
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
            try await wait { !(f.model.transcriptBanner?.feedback == .updating) }
            XCTAssertFalse(f.model.indexingPassActiveForTesting)
            XCTAssertNotNil(f.model.transcriptBanner?.details)
            XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
            XCTAssertEqual(f.model.selectedSessionID, sessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            let after = await f.database.transcriptReadCountForTesting()
            XCTAssertEqual(after, before, "settlement only reevaluates retained episode state")
            await gate.open()
        }
    }

    private func stopReplacement(_ f: Fixture, gate: ReviewReadGate, boundary: Int) async throws {
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
        try await wait { !f.model.transcriptSettlementPendingForTesting }
    }

    func testBareReplacementAbsenceSettlesToPausedWithOneRead() async throws {
        for boundary in 0..<4 {
            let (f, sessionID, _, gate, _) = try await replacementGap()
            let rows = f.model.messages, hydrated = f.model.hydratedMessages, project = f.model.selectedProjectID
            let before = await f.database.transcriptReadCountForTesting()
            try await stopReplacement(f, gate: gate, boundary: boundary)
            XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
            XCTAssertFalse(f.model.indexingPassActiveForTesting)
            XCTAssertEqual(f.model.selectedSessionID, sessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
            XCTAssertEqual(f.model.selectedProjectID, project)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            XCTAssertEqual(f.model.hydratedMessages.keys.sorted(), hydrated.keys.sorted())
            XCTAssertEqual(f.model.transcriptBanner?.details, TraceModel.TranscriptFeedback.paused.message)
            let settled = await f.database.transcriptReadCountForTesting()
            XCTAssertEqual(settled, before + 1)
            await f.clock.advance(by: .seconds(60))
            let later = await f.database.transcriptReadCountForTesting()
            XCTAssertEqual(later, settled, "a paused missing session does not poll")
        }
    }

    func testPausedManualMissingRetryPreservesCacheUntilAcceptedTerminalPass() async throws {
        for phase in [IndexProgress.Phase.complete, .failed, .cancelled] {
            let (f, sessionID, _, gate, _) = try await replacementGap()
            let rows = f.model.messages
            try await stopReplacement(f, gate: gate, boundary: 0)
            f.model.retrySelectedTranscript()
            await f.clock.advance()
            try await wait { !f.model.transcriptRecoveryPendingForTesting }
            XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
            XCTAssertEqual(f.model.selectedSessionID, sessionID)
            XCTAssertEqual(f.model.settings.lastSessionID, sessionID)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            var successor = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(successor)
            XCTAssertEqual(f.model.transcriptBanner?.feedback, .updating)
            successor.phase = phase
            await f.model.receiveProgress(successor)
            XCTAssertNil(f.model.selectedSessionID)
            XCTAssertNil(f.model.settings.lastSessionID)
            XCTAssertNil(f.model.transcriptBanner?.feedback)
        }
    }

    func testPausedPendingSelectionCompletesOnceAfterPresentManualRetry() async throws {
        let (f, _, sessionID, gate, _) = try await replacementGap()
        let events = ReviewSelectionEvents()
        let before = await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount }
        let observer = NotificationCenter.default.addObserver(forName: .traceShowMainWindow, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { events.windows += 1 }
        }
        let subscription = f.model.sidebarChanges.map(\.scrollRequest).removeDuplicates().dropFirst().sink { _ in events.scrolls += 1 }
        defer { NotificationCenter.default.removeObserver(observer); subscription.cancel() }
        f.model.selectSession(sessionID, showWindow: true)
        try await wait { (f.model.transcriptBanner?.feedback == .updating) && events.windows == 1 }
        try await stopReplacement(f, gate: gate, boundary: 0)
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(events.scrolls, 0)
        await f.coordinator.indexAll(scope: .proseOnly)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { await f.model.diagnostics.value().days.reduce(0) { $0 + $1.openCount } == before + 1 }
        XCTAssertNil(f.model.transcriptBanner?.feedback)
        XCTAssertNil(f.model.transcriptBanner)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(events.windows, 1)
        XCTAssertEqual(events.scrolls, 1)
        await f.model.refreshSummariesForTesting()
        XCTAssertEqual(events.scrolls, 1)
    }

    private func assertFullSummary(_ f: Fixture, messageCount: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(f.model.statistics?.messageCount, messageCount, file: file, line: line)
        let expectedHealth = try await f.database.sourceHealth()
        XCTAssertEqual(f.model.sourceHealth.map(\.rootPath), expectedHealth.map(\.rootPath), file: file, line: line)
        let bytes = try XCTUnwrap(f.model.statistics?.databaseBytes, file: file, line: line)
        XCTAssertGreaterThan(bytes, 0, file: file, line: line)
        let diagnostics = await f.model.diagnostics.value()
        XCTAssertEqual(diagnostics.days.first?.indexSizeBytes, bytes, file: file, line: line)
        try await wait { f.model.diagnosticsSnapshot.days.first?.indexSizeBytes == bytes }
        XCTAssertFalse(f.model.fullSummaryRefreshPendingForTesting, file: file, line: line)
    }

    func testTerminalSummarySurvivesSidebarSelectionChangesAndConfirmedDeletion() async throws {
        for boundary in 0..<3 {
            let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
            let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            for search in [f.model.globalSearch, f.model.mainSearch] {
                search.selectProject(f.project)
                _ = search.resolveProjectFilter(in: [], missingProject: .keepResolving)
                XCTAssertTrue(search.isResolvingProjectFilter)
            }
            var costPublications = 0
            let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costPublications += 1 }
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { subscription.cancel(); held.cancel(); Task { await gate.open() } }
            await f.database.gateSidebarSnapshotPublicationForTesting(held)
            let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
            try await wait { await f.database.sidebarSnapshotWaitingForTesting }
            switch boundary {
            case 0:
                f.model.selectSession(other.id)
                try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
            case 1: f.model.clearSession()
            default: _ = try await f.database.synchronizeConfiguredRoots([])
            }
            await gate.open()
            await refresh.value
            XCTAssertFalse(f.model.globalSearch.isResolvingProjectFilter)
            XCTAssertFalse(f.model.mainSearch.isResolvingProjectFilter)
            try await assertFullSummary(f, messageCount: boundary == 2 ? 0 : 6)
            XCTAssertEqual(costPublications, 1)
            if boundary == 0 { XCTAssertEqual(f.model.selectedSessionID, other.id) }
            else { XCTAssertNil(f.model.selectedSessionID) }
        }
    }

    func testTerminalSummaryTailSurvivesSelectionAtTranscriptAndTailGates() async throws {
        for tail in [false, true] {
            let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
            let other = try XCTUnwrap(f.model.sessions.first { $0.id != session.id })
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            if tail { f.model.summaryTailGateForTesting = held }
            else { f.model.summaryTranscriptGateForTesting = held }
            let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
            try await wait { tail ? f.model.summaryTailWaitingForTesting : f.model.summaryTranscriptWaitingForTesting }
            f.model.selectSession(other.id)
            try await wait { f.model.selectedSession?.id == other.id && !f.model.messages.isEmpty }
            let rows = f.model.messages
            await gate.open()
            await refresh.value
            XCTAssertEqual(f.model.selectedSessionID, other.id)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            try await assertFullSummary(f, messageCount: 6)
        }
    }

    func testTerminalSummaryTailSurvivesUserActionDuringRestorationRead() async throws {
        for boundary in 0..<3 {
            let f = try await fixture(count: 2), saved = try XCTUnwrap(f.model.sessions.first)
            let other = try XCTUnwrap(f.model.sessions.first { $0.id != saved.id })
            await f.model.prepareToTerminate()
            let model = try uninstalledModel(clock: f.clock,
                diagnosticsURL: f.root.appendingPathComponent("terminal-restoration.json"), savedSessionID: boundary == 2 ? -1 : saved.id)
            let coordinator = IndexCoordinator(database: f.database, sources: [ClaudeCodeSource(roots: [f.root])], clock: f.clock)
            let committed = await model.attach(database: f.database, coordinator: coordinator)
            XCTAssertTrue(committed)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            model.summaryRestorationGateForTesting = held
            var costPublications = 0
            let subscription = model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costPublications += 1 }
            defer { subscription.cancel() }
            let refresh = Task { await model.receiveProgress(.init(phase: .complete)) }
            try await wait { model.summaryRestorationWaitingForTesting }
            if boundary == 0 {
                model.selectSession(other.id)
                try await wait { model.selectedSession?.id == other.id && !model.messages.isEmpty }
            } else if boundary == 1 { model.clearSession() }
            else {
                var successor = IndexProgress(phase: .indexing)
                successor.incremental = true
                await model.receiveProgress(successor)
            }
            await gate.open()
            await refresh.value
            XCTAssertEqual(model.selectedSessionID, boundary == 0 ? other.id : nil)
            XCTAssertEqual(model.settings.lastSessionID, boundary == 0 ? other.id : boundary == 1 ? nil : -1)
            try await assertFullSummary(.init(root: f.root, clock: f.clock, model: model,
                database: f.database, coordinator: coordinator, project: f.project), messageCount: 6)
            XCTAssertEqual(costPublications, 1)
            if boundary == 2 {
                model.summaryRestorationGateForTesting = nil
                model.settings.lastSessionID = saved.id
                await model.refreshSummariesForTesting(terminalProjectReconciliation: false, lightweight: false)
                try await wait { model.selectedSessionID == saved.id && !model.messages.isEmpty }
            }
        }
    }

    func testSuccessorKeepsTerminalSummaryButUsesOngoingProjectRules() async throws {
        let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
        f.model.selectSession(session.id)
        try await wait { !f.model.messages.isEmpty }
        let rows = f.model.messages
        for search in [f.model.globalSearch, f.model.mainSearch] { search.selectProject(f.project) }
        _ = try await f.database.synchronizeConfiguredRoots([])
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        await f.database.gateSidebarSnapshotPublicationForTesting(held)
        let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
        try await wait { await f.database.sidebarSnapshotWaitingForTesting }
        var successor = IndexProgress(phase: .indexing)
        successor.incremental = true
        await f.model.receiveProgress(successor)
        await gate.open()
        await refresh.value
        XCTAssertTrue(f.model.indexingPassActiveForTesting)
        XCTAssertTrue(f.model.globalSearch.isResolvingProjectFilter)
        XCTAssertTrue(f.model.mainSearch.isResolvingProjectFilter)
        XCTAssertEqual(f.model.globalSearch.projectFilterCanonicalKey, f.project.canonicalKey)
        XCTAssertEqual(f.model.selectedSessionID, session.id)
        XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
        try await assertFullSummary(f, messageCount: 0)
    }

    func testLightweightSuccessorInheritsUnfinishedTerminalSummaryTail() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.summaryTailGateForTesting = held
        let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
        try await wait { f.model.summaryTailWaitingForTesting }
        XCTAssertTrue(f.model.fullSummaryRefreshPendingForTesting)
        XCTAssertNil(f.model.statistics)
        try line(99).write(to: f.root.appendingPathComponent("new.jsonl"))
        await f.coordinator.indexAll(scope: .proseOnly)
        var successor = IndexProgress(phase: .indexing)
        successor.incremental = true
        await f.model.receiveProgress(successor)
        f.model.summaryTailGateForTesting = nil
        var costPublications = 0
        let subscription = f.model.costsChanges.map(\.usagePublicationRevision).removeDuplicates().dropFirst().sink { _ in costPublications += 1 }
        defer { subscription.cancel() }
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false, lightweight: true)
        try await assertFullSummary(f, messageCount: 7)
        XCTAssertEqual(costPublications, 1)
        let bytes = f.model.statistics?.databaseBytes
        await gate.open()
        await refresh.value
        XCTAssertEqual(f.model.statistics?.databaseBytes, bytes)
        XCTAssertEqual(costPublications, 1, "the superseded refresh must not run a second tail")
    }

    func testTerminalSummaryRejectsObsoleteAttachmentConfigurationAndTermination() async throws {
        for boundary in 0..<3 {
            let f = try await fixture(count: 2)
            let gate = ReviewReadGate(), held = Task { await gate.wait() }
            defer { held.cancel(); Task { await gate.open() } }
            f.model.summaryTailGateForTesting = held
            let refresh = Task { await f.model.receiveProgress(.init(phase: .complete)) }
            try await wait { f.model.summaryTailWaitingForTesting }
            switch boundary {
            case 0:
                f.model.failSourceConfigurationForTesting = true
                f.model.reloadSourcesAndRebuild()
                try await wait { f.model.sourceReloadRecovery.error != nil }
            case 1:
                let reopened = try IndexDatabase(url: f.root.appendingPathComponent("index.sqlite"))
                await f.model.attachForTesting(database: reopened, sources: [ClaudeCodeSource(roots: [f.root])])
            default: await f.model.prepareToTerminate()
            }
            let health = f.model.sourceHealth.map(\.rootPath)
            XCTAssertFalse(f.model.fullSummaryRefreshPendingForTesting)
            await gate.open()
            await refresh.value
            XCTAssertNil(f.model.statistics)
            XCTAssertEqual(f.model.sourceHealth.map(\.rootPath), health)
            let diagnostics = await f.model.diagnostics.value()
            XCTAssertFalse(diagnostics.days.contains { $0.indexSizeBytes > 0 })
        }
    }

    func testSynchronousTerminalPublicationRejectsReplacedConfiguration() async throws {
        let f = try await fixture(count: 2)
        f.model.failSourceConfigurationForTesting = true
        var handled = false
        let subscription = f.model.progressChanges.sink { progress in
            guard progress.phase == .complete, !handled else { return }
            handled = true
            f.model.reloadSourcesAndRebuild()
        }
        defer { subscription.cancel() }
        await f.model.receiveProgress(.init(phase: .complete))
        try await wait { f.model.sourceReloadRecovery.error != nil }
        XCTAssertTrue(handled)
        XCTAssertNil(f.model.statistics)
        XCTAssertFalse(f.model.fullSummaryRefreshPendingForTesting)
        XCTAssertFalse(f.model.terminalSummaryPendingForTesting)
    }

    func testExhaustedReplacementSettlementDoesNotPublishPausedBanner() async throws {
        let (f, sessionID, _, gate, _) = try await replacementGap()
        try await exhaustTransientRecovery(f)
        let publicationGate = ReviewReadGate(), held = Task { await publicationGate.wait() }
        defer { held.cancel(); Task { await publicationGate.open() } }
        f.model.transcriptSettlementGateForTesting = held
        var feedback: [TraceModel.TranscriptFeedback] = []
        let subscription = f.model.objectWillChange.sink {
            if let value = f.model.transcriptBanner?.feedback { feedback.append(value) }
        }
        defer { subscription.cancel() }
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.transcriptSettlementWaitingForTesting }
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .updating)
        let updatingBanner = try XCTUnwrap(f.model.transcriptBanner)
        XCTAssertEqual(updatingBanner.message, "This session is temporarily unavailable while the index updates. Retry now or wait for indexing to finish.")
        XCTAssertEqual(updatingBanner.details, updatingBanner.message + "\nUnable to read Synthetic transcript read failure")
        XCTAssertFalse(feedback.contains(.paused))
        await publicationGate.open()
        try await wait { !f.model.transcriptSettlementPendingForTesting }
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .readError)
        let readErrorBanner = try XCTUnwrap(f.model.transcriptBanner)
        XCTAssertEqual(readErrorBanner.message, "Could not refresh this session. Try again.")
        XCTAssertEqual(readErrorBanner.details, "Unable to read Synthetic transcript read failure")
        XCTAssertEqual(updatingBanner.feedback, .updating, "a captured presentation retains its original feedback")
        XCTAssertFalse(feedback.contains(.paused))
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        await f.database.failTranscriptReadsForTesting(count: 0)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, sessionID, "exhausted feedback keeps private paused selection protection")
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
        let pausedBanner = try XCTUnwrap(f.model.transcriptBanner)
        XCTAssertEqual(pausedBanner.message, "This session is unavailable because index updates are paused. Retry now or resume indexing to check again.")
        XCTAssertEqual(pausedBanner.details, pausedBanner.message)
        await gate.open()
    }

    func testEmptyReplacementDoesNotScheduleTranscriptSettlement() async throws {
        let f = try await fixture(count: 2)
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.transcriptSettlementGateForTesting = held
        let before = await f.database.transcriptReadCountForTesting()
        let committed = await f.model.attach(database: f.database, coordinator: f.coordinator)
        XCTAssertTrue(committed)
        XCTAssertFalse(f.model.transcriptSettlementPendingForTesting)
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.sourceReloadRecovery.error != nil }
        XCTAssertFalse(f.model.transcriptSettlementPendingForTesting)
        let after = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, before)
    }

    func testTerminalRereadNeverPublishesExhaustedErrorBeforePresentData() async throws {
        for cancelledDelivery in [false, true] {
            let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
            f.model.selectSession(session.id)
            try await wait { !f.model.messages.isEmpty }
            var pass = IndexProgress(phase: .indexing)
            await f.model.receiveProgress(pass)
            _ = try await f.database.synchronizeConfiguredRoots([])
            await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
            try await exhaustTransientRecovery(f)
            await f.coordinator.indexAll(scope: .proseOnly)
            var feedback: [TraceModel.TranscriptFeedback] = []
            let subscription = f.model.objectWillChange.sink {
                if let value = f.model.transcriptBanner?.feedback { feedback.append(value) }
            }
            let deliveryGate = ReviewReadGate(), publicationGate = ReviewReadGate()
            let held = Task { await publicationGate.wait() }
            defer { subscription.cancel(); held.cancel(); Task { await deliveryGate.open(); await publicationGate.open() } }
            f.model.summaryTranscriptGateForTesting = held
            pass.phase = cancelledDelivery ? .cancelled : .complete
            let terminalPass = pass
            let delivery = Task {
                await deliveryGate.wait()
                XCTAssertEqual(Task.isCancelled, cancelledDelivery)
                await f.model.receiveProgress(terminalPass)
            }
            if cancelledDelivery { delivery.cancel() }
            await deliveryGate.open()
            try await wait { f.model.summaryTranscriptWaitingForTesting }
            XCTAssertEqual(f.model.transcriptBanner?.feedback, .updating)
            XCTAssertFalse(feedback.contains(.readError))
            await publicationGate.open()
            await delivery.value
            XCTAssertNil(f.model.transcriptBanner?.feedback)
            XCTAssertEqual(f.model.selectedSessionID, session.id)
            XCTAssertFalse(feedback.contains(.readError), "even synchronous publications must not expose the old error")
        }
    }

    func testSettlementPublishesCurrentErrorRatherThanCapturedEpisode() async throws {
        let (f, _, _, gate, _) = try await replacementGap()
        try await exhaustTransientRecovery(f)
        let publicationGate = ReviewReadGate(), held = Task { await publicationGate.wait() }
        defer { held.cancel(); Task { await publicationGate.open() } }
        f.model.transcriptSettlementGateForTesting = held
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.transcriptSettlementWaitingForTesting }
        f.model.failSelectedTranscriptForTesting("Newer retained read error")
        XCTAssertEqual(f.model.transcriptBanner?.details, "Newer retained read error")
        await publicationGate.open()
        try await wait { !f.model.transcriptSettlementPendingForTesting }
        XCTAssertEqual(f.model.transcriptBanner?.details, "Newer retained read error")
        await gate.open()
    }

    func testObsoleteSettlementCannotReadOrPublish() async throws {
        for boundary in 0..<5 {
            let (f, _, otherID, gate, _) = try await replacementGap()
            try await exhaustTransientRecovery(f)
            let publicationGate = ReviewReadGate(), held = Task { await publicationGate.wait() }
            defer { held.cancel(); Task { await publicationGate.open() } }
            f.model.transcriptSettlementGateForTesting = held
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.transcriptSettlementWaitingForTesting }
            switch boundary {
            case 0:
                await f.database.failTranscriptReadOnceForTesting()
                await f.model.refreshSummariesForTesting()
                f.model.failSelectedTranscriptForTesting("Newer summary error")
            case 1:
                var pass = IndexProgress(phase: .indexing)
                pass.incremental = true
                await f.model.receiveProgress(pass)
            case 2:
                await f.coordinator.indexAll(scope: .proseOnly)
                f.model.selectSession(otherID)
                try await wait { f.model.selectedSession?.id == otherID && !f.model.messages.isEmpty }
            case 3:
                let replacement = try await fixture(count: 3)
                await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            default: await f.model.prepareToTerminate()
            }
            let selected = f.model.selectedSessionID, feedback = f.model.transcriptBanner?.details
            let rows = f.model.messages, before = await f.database.transcriptReadCountForTesting()
            await publicationGate.open()
            try await wait { !f.model.transcriptSettlementWaitingForTesting }
            XCTAssertEqual(f.model.selectedSessionID, selected)
            XCTAssertEqual(f.model.transcriptBanner?.details, feedback)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            let after = await f.database.transcriptReadCountForTesting()
            XCTAssertEqual(after, before)
            await gate.open()
        }
    }

    func testRunningRecoveryCoalescesReplacementSettlement() async throws {
        let (f, sessionID, _, gate, _) = try await replacementGap()
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        try await stopReplacement(f, gate: gate, boundary: 0)
        let settled = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(settled, before)
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
        await f.clock.advance(by: .milliseconds(250))
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
        let recovered = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(recovered, before + 1)
    }

    func testObsoleteReplacementRevalidationRejectsSuspendedRead() async throws {
        for boundary in 0..<5 {
            let (f, _, otherID, gate, _) = try await replacementGap()
            let publicationGate = ReviewReadGate(), held = Task { await publicationGate.wait() }
            defer { held.cancel(); Task { await publicationGate.open() } }
            f.model.transcriptRecoveryPublicationGateForTesting = held
            f.model.failSourceConfigurationForTesting = true
            f.model.reloadSourcesAndRebuild()
            try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
            f.model.transcriptRecoveryPublicationGateForTesting = nil
            switch boundary {
            case 0: await f.model.refreshSummariesForTesting()
            case 1:
                var pass = IndexProgress(phase: .indexing)
                pass.incremental = true
                await f.model.receiveProgress(pass)
            case 2:
                await f.coordinator.indexAll(scope: .proseOnly)
                f.model.selectSession(otherID)
                try await wait { f.model.selectedSession?.id == otherID && !f.model.messages.isEmpty }
            case 3:
                let replacement = try await fixture(count: 3)
                await f.model.attach(database: replacement.database, coordinator: replacement.coordinator)
            default: await f.model.prepareToTerminate()
            }
            let selected = f.model.selectedSessionID, feedback = f.model.transcriptBanner?.details, rows = f.model.messages
            await publicationGate.open()
            try await wait { !f.model.transcriptRecoveryPublicationWaitingForTesting }
            XCTAssertEqual(f.model.selectedSessionID, selected)
            XCTAssertEqual(f.model.transcriptBanner?.details, feedback)
            XCTAssertEqual(f.model.messages.map(\.locator), rows.map(\.locator))
            await gate.open()
        }
    }

    func testCompletedRecoveryIsNotReadAgainByHeldSettlement() async throws {
        let (f, sessionID, _, gate, _) = try await replacementGap()
        await f.database.failTranscriptReadOnceForTesting()
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let publicationGate = ReviewReadGate(), held = Task { await publicationGate.wait() }
        defer { held.cancel(); Task { await publicationGate.open() } }
        f.model.transcriptSettlementGateForTesting = held
        f.model.failSourceConfigurationForTesting = true
        f.model.reloadSourcesAndRebuild()
        try await wait { f.model.transcriptSettlementWaitingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        await f.clock.advance(by: .milliseconds(250))
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        await publicationGate.open()
        try await wait { !f.model.transcriptSettlementPendingForTesting }
        let after = await f.database.transcriptReadCountForTesting()
        XCTAssertEqual(after, before + 1, "settlement must coalesce even when recovery finishes before publication")
        await gate.open()
    }

    func testPausedRevalidationFailureExhaustsOneBudgetWithoutLosingPreservation() async throws {
        let (f, sessionID, _, gate, _) = try await replacementGap()
        await f.database.failTranscriptReadsForTesting(count: 4)
        try await stopReplacement(f, gate: gate, boundary: 0)
        try await wait { f.model.transcriptRecoveryPendingForTesting }
        let before = await f.database.transcriptReadCountForTesting()
        for (index, delay) in [Duration.milliseconds(250), .seconds(1), .seconds(4)].enumerated() {
            XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
            await f.clock.advance(by: delay)
            try await wait { await f.database.transcriptReadCountForTesting() == before + UInt64(index + 1) }
        }
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .readError)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
        f.model.retrySelectedTranscript()
        await f.clock.advance()
        try await wait { !f.model.transcriptRecoveryPendingForTesting }
        XCTAssertEqual(f.model.transcriptBanner?.feedback, .paused)
        XCTAssertEqual(f.model.selectedSessionID, sessionID)
    }

    func testRestorationDistinguishesCancelledReceiptFromCancelledFallback() async throws {
        for receipt in [false, true] {
            let f = try await fixture(count: 2), session = try XCTUnwrap(f.model.sessions.first)
            await f.model.prepareToTerminate()
            _ = try await f.database.synchronizeConfiguredRoots([])
            let model = try uninstalledModel(clock: f.clock,
                diagnosticsURL: f.root.appendingPathComponent("cancelled-restoration.json"), savedSessionID: session.id)
            await model.attach(database: f.database, coordinator: f.coordinator)
            if receipt {
                var pass = IndexProgress(phase: .indexing)
                await model.receiveProgress(pass)
                pass.phase = .cancelled
                await model.receiveProgress(pass)
            } else {
                model.setPublishedProgressForTesting(.init(phase: .cancelled))
                await model.refreshSummariesForTesting(lightweight: false)
            }
            XCTAssertEqual(model.settings.lastSessionID, session.id)
            await f.coordinator.indexAll(scope: .proseOnly)
            await model.refreshSummariesForTesting(lightweight: false)
            if receipt { XCTAssertNil(model.selectedSessionID) }
            else { try await wait { model.selectedSessionID == session.id && !model.messages.isEmpty } }
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
        try await wait { (model.transcriptBanner?.feedback == .updating) }
        XCTAssertEqual(model.settings.lastSessionID, session.id)
        await f.coordinator.indexAll(scope: .proseOnly)
        await model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        XCTAssertEqual(model.selectedSessionID, session.id)
        XCTAssertFalse(model.messages.isEmpty)
        XCTAssertFalse((model.transcriptBanner?.feedback == .updating))
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
        f.model.startReadyStartupForTesting(sources: [source])
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
        f.model.startReadyStartupForTesting(sources: [source])
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { (try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count == 2 && f.model.progress.phase == .complete
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
        f.model.startReadyStartupForTesting(sources: [source])
        f.model.startReadyStartupForTesting(sources: [source])
        try await wait { f.model.progress.phase == .complete }
        XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
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
            let subscription = f.model.sidebarChanges.map(\.monitoringWarnings).removeDuplicates().sink { warnings in
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
                XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
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
        model.startReadyStartupForTesting(sources: [source])
        model.startReadyStartupForTesting(sources: [source])
        try await wait { model.progress.phase == .complete }
        XCTAssertEqual((try model.startupSubmissionsForTesting(in: model.startupReceiptScopeForTesting())).count, 1)
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
        // Keep legitimate filesystem progress from replacing the injected pass
        // while this test releases only the obsolete watcher startup.
        let progressGate = ReviewReadGate(), progressHeld = Task { await progressGate.wait() }
        defer { progressHeld.cancel(); Task { await progressGate.open() } }
        f.model.schedulerProgressGateForTesting = progressHeld
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
            XCTAssertEqual((try f.model.startupSubmissionsForTesting(in: f.model.startupReceiptScopeForTesting())).count, 1)
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
        f.model.startReadyStartupForTesting(sources: [source])
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
        let scope = f.model.startupReceiptScopeForTesting()
        await f.model.prepareToTerminate()
        await gate.open()
        try await wait { !f.model.watcherReadinessWaitingForTesting }
        XCTAssertEqual(f.model.sourceReloadRecovery, .normal)
        XCTAssertFalse(f.model.watcherReadyForTesting)
        XCTAssertFalse(f.model.canRebuildIndex)
        XCTAssertEqual(try f.model.startupSubmissionsForTesting(in: scope).count, 0)
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

    private func prepareRowRecovery(terminalRefresh: Bool = false) async throws -> RowRecovery {
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
        let refresh = Task {
            if terminalRefresh { await f.model.receiveProgress(.init(phase: .complete)) }
            else { await f.model.refreshSummariesForTesting() }
        }
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

    func testSuccessorRejectsSuspendedTerminalCompleteRowRecovery() async throws {
        let recovery = try await prepareRowRecovery(terminalRefresh: true), f = recovery.fixture
        let gate = ReviewReadGate(), held = Task { await gate.wait() }
        defer { held.cancel(); Task { await gate.open() } }
        f.model.transcriptRecoveryPublicationGateForTesting = held
        await recovery.summaryGate.open()
        try await wait { f.model.transcriptRecoveryPublicationWaitingForTesting }
        var successor = IndexProgress(phase: .indexing)
        successor.incremental = true
        await f.model.receiveProgress(successor)
        await gate.open()
        await recovery.refresh.value
        XCTAssertNil(f.model.selectedSession)
        XCTAssertTrue(f.model.messages.isEmpty)
        XCTAssertEqual(f.model.selectedSessionID, recovery.snapshot.session?.id)
        XCTAssertFalse(f.model.transcriptRecoveryPendingForTesting)
        try await assertFullSummary(f, messageCount: 6)
        f.model.summaryTranscriptGateForTesting = nil
        f.model.transcriptRecoveryPublicationGateForTesting = nil
        await f.model.refreshSummariesForTesting(terminalProjectReconciliation: false)
        try await assertRecovered(recovery)
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
        XCTAssertNotNil(f.model.transcriptBanner?.details)
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
        XCTAssertNil(f.model.transcriptBanner?.details)
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

private struct ReviewPublisher<Value>: @unchecked Sendable {
    let publisher: AnyPublisher<Value, Never>
}

private struct ReviewSubscription: @unchecked Sendable {
    let value: AnyCancellable
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
