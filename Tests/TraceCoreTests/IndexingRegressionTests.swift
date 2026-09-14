import CoreServices
import GRDB
import XCTest
@testable import TraceCore

final class IndexingRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TraceRegression-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func line(_ id: Int, project: String = "/tmp/TraceExample") -> String {
        "{\"type\":\"user\",\"uuid\":\"\(id)\",\"sessionId\":\"session\",\"cwd\":\"\(project)\",\"timestamp\":\"2026-09-14T10:00:00Z\",\"message\":{\"content\":\"searchable message \(id)\"}}\n"
    }

    func testConcurrentPassesSerializeAndUnchangedFilesAreNotParsed() async throws {
        let root = try directory()
        try Data(line(1).utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let counter = ReadCounter()
        let source = CountingSource(base: ClaudeCodeSource(roots: [root]), counter: counter)
        let coordinator = IndexCoordinator(database: database, sources: [source])
        async let first: Void = coordinator.indexAll(scope: .proseOnly)
        async let second: Void = coordinator.indexAll(scope: .proseOnly)
        _ = await (first, second)
        XCTAssertEqual(counter.value, 1)
        let count = try await database.statistics().messageCount
        XCTAssertEqual(count, 1)
    }

    func testFiniteReaderDefersAppendsAndPartialLine() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let cursor = try JSONLineCursor(url: file, from: 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line(2) + "{\"type\":").utf8))
        try handle.close()
        XCTAssertNotNil(try cursor.next())
        XCTAssertNil(try cursor.next(), "a continuously growing file must not extend the captured pass")
        let next = try JSONLineCursor(url: file, from: cursor.checkpoint)
        XCTAssertNotNil(try next.next())
        XCTAssertNil(try next.next())
        XCTAssertEqual(next.checkpoint, Int64((line(1) + line(2)).utf8.count))
    }

    func testCancellationCommitsCheckpointAndResumesWithoutDuplicates() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data((0..<600).map { line($0) }.joined().utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        let latch = BatchLatch()
        let run = Task {
            await coordinator.indexAll(scope: .proseOnly) { progress in
                if progress.phase == .indexing && progress.currentFileBytes > 0 { await latch.pauseOnce() }
            }
        }
        await latch.waitForPause()
        let liveProjects = try await database.projects()
        XCTAssertEqual(liveProjects.count, 1, "committed projects must be readable before the pass completes")
        XCTAssertEqual(liveProjects.first?.displayName, "TraceExample")
        run.cancel()
        await latch.release()
        await run.value
        let state = try await database.sourceState(path: file.path)
        let checkpoint = try XCTUnwrap(state?.scannedBytes)
        XCTAssertGreaterThan(checkpoint, 0)
        XCTAssertLessThan(checkpoint, Int64(try Data(contentsOf: file).count))
        let before = try await database.statistics().messageCount
        XCTAssertGreaterThan(before, 0)
        XCTAssertLessThan(before, 600)
        await coordinator.indexAll(scope: .proseOnly)
        let after = try await database.statistics().messageCount
        XCTAssertEqual(after, 600)
        let sessions = try await database.sessions()
        let messages = try await database.messages(sessionID: try XCTUnwrap(sessions.first?.id))
        XCTAssertEqual(Set(messages.map(\.id)).count, 600)
    }

    func testSchedulerCoalescesEventsAndRebuildWaitsForCancellation() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data((0..<400).map { line($0) }.joined().utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        let latch = BatchLatch()
        let recorder = RunRecorder()
        let scheduler = IndexScheduler(coordinator: coordinator, scope: .proseOnly) { progress in
            await recorder.receive(progress)
            if progress.phase == .indexing && progress.currentFileBytes > 0 { await latch.pauseOnce() }
        }
        await scheduler.request(reconcile: true)
        await latch.waitForPause()
        for _ in 0..<30 { await scheduler.request(paths: [file.path]) }
        await scheduler.request(rebuild: true, scope: .everything)
        await latch.release()
        await scheduler.waitUntilIdle()
        let phases = await recorder.terminalPhases
        XCTAssertEqual(phases, [.cancelled, .complete])
        let count = try await database.statistics().messageCount
        XCTAssertEqual(count, 400)
        let scope = try await database.storedIndexScope()
        XCTAssertEqual(scope, .everything)
    }

    func testAdditiveMigrationAndRelaunchPreserveSearchAndIDs() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let url = root.appendingPathComponent("index.sqlite")
        try Data(line(1).utf8).write(to: file)
        let initial = try IndexDatabase(url: url)
        await IndexCoordinator(database: initial, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
        let original = try await initial.search(query: "searchable").results.map(\.id)
        // Recreate the previous schema without changing any content or FTS postings.
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "DROP TABLE session_failure")
            try db.execute(sql: "ALTER TABLE message DROP COLUMN section_flags")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v2-details'")
        }
        let reopened = try IndexDatabase(url: url)
        let counter = ReadCounter()
        await IndexCoordinator(database: reopened, sources: [CountingSource(base: ClaudeCodeSource(roots: [root]), counter: counter)]).indexAll(scope: .proseOnly)
        let results = try await reopened.search(query: "searchable").results.map(\.id)
        XCTAssertEqual(results, original)
        XCTAssertEqual(counter.value, 0)
    }

    func testVisibilityHandlesMixedMessagesAndCopy() {
        let visibility = TranscriptVisibility(tools: false, system: false, reasoning: false)
        let message = HydratedMessage(role: .assistant, sections: .init(prose: "Answer", toolInvocation: "Read", toolOutput: "Output", reasoning: "Reason"), toolName: "Read", hasError: false)
        XCTAssertEqual(visibility.text(message, expandedReasoning: true), "Answer")
        XCTAssertFalse(visibility.includes(role: .system))
        XCTAssertFalse(visibility.includes(role: .reasoning))
        XCTAssertFalse(visibility.includes(role: .toolResult))
        let all = TranscriptVisibility()
        XCTAssertFalse(all.text(message, expandedReasoning: false).contains("Reason"))
        XCTAssertTrue(all.text(message, expandedReasoning: true).contains("Reason"))
    }

    func testEverySearchScopeAndMissingLegacyErrorSource() async throws {
        let root = try directory()
        let sources = root.appendingPathComponent("Claude")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Claude")
        try FileManager.default.copyItem(at: fixture, to: sources)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [sources])])
        for scope in IndexScope.allCases {
            await coordinator.indexAll(scope: scope)
            let prose = try await database.search(query: "resume")
            let invocation = try await database.search(query: "Read")
            let output = try await database.search(query: "missing")
            let reasoning = try await database.search(query: "Private chain")
            XCTAssertFalse(prose.results.isEmpty)
            XCTAssertEqual(invocation.results.isEmpty, scope == .proseOnly)
            XCTAssertEqual(output.results.isEmpty, scope != .everything)
            XCTAssertTrue(reasoning.results.isEmpty)
        }
        let allSessions = try await database.sessions()
        let session = try XCTUnwrap(allSessions.first)
        let raw = try DatabaseQueue(path: root.appendingPathComponent("index.sqlite").path)
        try await raw.write { try $0.execute(sql: "DELETE FROM session_failure") }
        let legacy = try await coordinator.failures(for: session)
        XCTAssertTrue(legacy.contains { $0.detail.contains("file missing") })
        try FileManager.default.removeItem(at: sources)
        do {
            _ = try await coordinator.failures(for: session)
            XCTFail("A missing source must report an explicit read error")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testWatcherFlagsDistinguishFileChangesFromRecovery() {
        var changes = SourceChanges()
        changes.include(path: "/root/rollout.jsonl", flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified))
        changes.include(path: "/root", flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified))
        XCTAssertEqual(changes.paths, ["/root/rollout.jsonl"])
        XCTAssertFalse(changes.requiresReconciliation)
        changes.include(path: "/root", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        XCTAssertTrue(changes.requiresReconciliation)
    }

    func testFailureDetailsAndProjectSearchAcrossProviders() async throws {
        let root = try directory()
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [fixtures.appendingPathComponent("Claude")]), CodexSource(root: fixtures.appendingPathComponent("Codex")), GeminiSource(root: fixtures.appendingPathComponent("Gemini"))])
        await coordinator.indexAll(scope: .everything)
        let sessions = try await database.sessions()
        for session in sessions where session.hadError {
            let failures = try await coordinator.failures(for: session)
            XCTAssertFalse(failures.isEmpty)
            XCTAssertTrue(failures.allSatisfy { !$0.detail.isEmpty })
        }
        for project in try await database.projects() {
            let page = try await database.search(query: "the", filters: .init(projectID: project.id))
            XCTAssertTrue(page.results.allSatisfy { $0.projectID == project.id })
        }
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct CountingSource: SessionSource {
    let base: ClaudeCodeSource
    let counter: ReadCounter
    var agent: AgentKind { base.agent }
    var roots: [SourceRoot] { base.roots }
    func discover() throws -> [DiscoveredSourceFile] { try base.discover() }
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?) -> AsyncThrowingStream<ParsedRecord, Error> {
        counter.increment()
        return base.records(in: file, from: offset, through: boundary)
    }
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        try base.hydrate(fileURL: fileURL, format: format, locator: locator)
    }
}

private actor BatchLatch {
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        guard !paused else { return }
        paused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters = []
        if !released { await withCheckedContinuation { resume = $0 } }
    }
    func waitForPause() async {
        if !paused { await withCheckedContinuation { pauseWaiters.append($0) } }
    }
    func release() { released = true; resume?.resume(); resume = nil }
}

private actor RunRecorder {
    var terminalPhases: [IndexProgress.Phase] = []
    func receive(_ progress: IndexProgress) {
        if [.complete, .cancelled, .failed].contains(progress.phase) { terminalPhases.append(progress.phase) }
    }
}
