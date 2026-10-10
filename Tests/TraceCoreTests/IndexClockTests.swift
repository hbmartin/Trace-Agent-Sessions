import Clocks
import CustomDump
import Foundation
import GRDB
@testable import TraceCore
import XCTest

final class IndexClockTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceIndexClock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func failedScheduler(clock: TestClock<Duration>) async throws -> (IndexScheduler, DatabaseQueue, ClockRecorder) {
        let root = try directory()
        try Data(#"{"type":"user","uuid":"one","sessionId":"clock","cwd":"/tmp/project","timestamp":1700000000000,"message":{"content":"clock fixture"}}"#.utf8)
            .write(to: root.appendingPathComponent("session.jsonl"))
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])], clock: clock)
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_clock_root BEFORE UPDATE OF is_default ON source_root
                BEGIN SELECT RAISE(ABORT, 'clock retry failure'); END
                """)
        }
        let recorder = ClockRecorder()
        let scheduler = IndexScheduler(coordinator: coordinator, scope: .proseOnly,
            progress: { await recorder.receive($0) }, clock: clock,
            didComplete: { _, watermarks in await recorder.complete(watermarks) })
        addTeardownBlock {
            await scheduler.stop()
            try await clock.checkSuspension()
        }
        await scheduler.request(reconcile: true, watermarks: ["failed-volume": 10])
        await scheduler.waitUntilIdle()
        let phases = await recorder.phases
        expectNoDifference([.failed], phases)
        return (scheduler, raw, recorder)
    }

    func testRetryRunsAtFiveSecondsAndRetainsWatermark() async throws {
        let clock = TestClock()
        let (scheduler, raw, recorder) = try await failedScheduler(clock: clock)
        await clock.advance(by: .milliseconds(4_999))
        let phasesBefore = await recorder.phases
        expectNoDifference([.failed], phasesBefore)
        let watermarksBefore = await recorder.watermarks
        XCTAssertTrue(watermarksBefore.isEmpty)
        try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_clock_root") }
        let completed = expectation(description: "Retried pass completes")
        await recorder.observeCompletion(completed)
        await clock.advance(by: .milliseconds(1))
        await fulfillment(of: [completed], timeout: 5)
        await scheduler.waitUntilIdle()
        let phases = await recorder.phases
        let watermarks = await recorder.watermarks
        expectNoDifference([.failed, .complete], phases)
        expectNoDifference([["failed-volume": UInt64(10)]], watermarks)
        await scheduler.stop()
        try await clock.checkSuspension()
    }

    func testFreshWorkCompletesBeforeDelayedRetry() async throws {
        let clock = TestClock()
        let (scheduler, raw, recorder) = try await failedScheduler(clock: clock)
        try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_clock_root") }
        // Watermark-only work for an unrelated stream must not wait for a retained failure.
        await scheduler.request(watermarks: ["healthy-volume": 20])
        await scheduler.waitUntilIdle()
        let fresh = await recorder.watermarks
        expectNoDifference([["healthy-volume": UInt64(20)]], fresh)
        let completed = expectation(description: "Retained retry completes")
        await recorder.observeCompletion(completed)
        await clock.advance(by: .seconds(5))
        await fulfillment(of: [completed], timeout: 5)
        await scheduler.waitUntilIdle()
        let watermarks = await recorder.watermarks
        expectNoDifference([["healthy-volume": UInt64(20)], ["failed-volume": UInt64(10)]], watermarks)
    }

    func testStopCancelsRetryAndRejectsNewRequests() async throws {
        let clock = TestClock()
        let (scheduler, _, recorder) = try await failedScheduler(clock: clock)
        await scheduler.stop()
        try await clock.checkSuspension()
        await clock.advance(by: .seconds(10))
        await scheduler.request(reconcile: true, watermarks: ["failed-volume": 30])
        await scheduler.waitUntilIdle()
        let phases = await recorder.phases
        expectNoDifference([.failed], phases)
    }

    func testSecondFailureBecomesDormantUntilCoveredByNewWork() async throws {
        let clock = TestClock()
        let (scheduler, raw, recorder) = try await failedScheduler(clock: clock)
        let retried = expectation(description: "The one scheduled retry fails")
        await recorder.observeTerminal(retried)
        await clock.advance(by: .seconds(5))
        await fulfillment(of: [retried], timeout: 5)
        await scheduler.waitUntilIdle()
        try await clock.checkSuspension()
        await clock.advance(by: .seconds(86_400))
        let dormantPhases = await recorder.phases
        expectNoDifference([.failed, .failed], dormantPhases, "dormant failures must not spin on a timer")
        await scheduler.request(watermarks: ["healthy-volume": 20])
        await scheduler.waitUntilIdle()
        let fresh = await recorder.watermarks
        expectNoDifference([["healthy-volume": UInt64(20)]], fresh)
        try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_clock_root") }
        await scheduler.request(reconcile: true, watermarks: ["failed-volume": 30])
        await scheduler.waitUntilIdle()
        let recovered = await recorder.watermarks
        expectNoDifference([["healthy-volume": UInt64(20)], ["failed-volume": UInt64(30)]], recovered,
                           "covered new work must recover the retained stream with its latest watermark")
        try await clock.checkSuspension()
    }

    func testScopeChangeCancelsOldRetryAndPreservesRetainedWatermark() async throws {
        let clock = TestClock()
        let (scheduler, raw, recorder) = try await failedScheduler(clock: clock)
        try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_clock_root") }
        await scheduler.request(scope: .everything, watermarks: ["fresh-volume": 30])
        await scheduler.waitUntilIdle()
        try await clock.checkSuspension()
        await clock.advance(by: .seconds(10))
        let phases = await recorder.phases
        let watermarks = await recorder.watermarks
        expectNoDifference([.failed, .complete], phases)
        expectNoDifference([["failed-volume": UInt64(10), "fresh-volume": UInt64(30)]], watermarks)
    }

    private func appendCodexMessage(id: String, to file: URL) throws {
        let record: [String: Any] = ["type": "response_item", "timestamp": 1_700_000_001_000,
            "payload": ["type": "message", "id": id, "role": "assistant", "content": "Appended message"]]
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record) + Data([10]))
    }

    func testCodexNameCacheExpiresAtThirtySeconds() async throws {
        let clock = TestClock()
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-clock.jsonl")
        try Data((#"{"type":"session_meta","payload":{"id":"clock","cwd":"/tmp/project"}}"# + "\n"
                  + #"{"type":"response_item","timestamp":1700000000000,"payload":{"type":"message","role":"user","content":"Fallback title"}}"# + "\n").utf8).write(to: rollout)
        let sidecar = try DatabaseQueue(path: root.appendingPathComponent("state_9.sqlite").path)
        try await sidecar.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)], clock: clock)
        await coordinator.indexAll(scope: .proseOnly)
        try await sidecar.write { try $0.execute(sql: "INSERT INTO threads VALUES ('clock', 'Updated title', NULL)") }
        await clock.advance(by: .milliseconds(29_999))
        try appendCodexMessage(id: "before-expiry", to: rollout)
        await coordinator.refresh(paths: [rollout.path], scope: .proseOnly)
        let beforeCount = await coordinator.codexNameLoadCountForTesting(directory: root)
        let beforeTitle = try await database.sessions().first?.title
        XCTAssertEqual(beforeCount, 1)
        expectNoDifference("Fallback title", beforeTitle)
        await clock.advance(by: .milliseconds(1))
        try appendCodexMessage(id: "after-expiry", to: rollout)
        await coordinator.refresh(paths: [rollout.path], scope: .proseOnly)
        let afterCount = await coordinator.codexNameLoadCountForTesting(directory: root)
        let afterTitle = try await database.sessions().first?.title
        XCTAssertEqual(afterCount, 2)
        expectNoDifference("Updated title", afterTitle)
        try await clock.checkSuspension()
    }
}

private actor ClockRecorder {
    var phases: [IndexProgress.Phase] = []
    var watermarks: [[String: UInt64]] = []
    private var completion: XCTestExpectation?
    private var terminal: XCTestExpectation?
    func receive(_ update: IndexProgress) {
        if [.failed, .complete, .cancelled].contains(update.phase) {
            phases.append(update.phase)
            terminal?.fulfill(); terminal = nil
        }
    }
    func complete(_ value: [String: UInt64]) {
        watermarks.append(value)
        completion?.fulfill(); completion = nil
    }
    func observeCompletion(_ expectation: XCTestExpectation) { completion = expectation }
    func observeTerminal(_ expectation: XCTestExpectation) { terminal = expectation }
}
