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
        try await latch.waitForPause()
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
        try await latch.waitForPause()
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

        let attachment = MessageSummary(
            id: 1, role: .user, timestampMilliseconds: 1, prefix: "", toolSummary: nil,
            characterCount: 0, hasError: false, sourcePath: "/tmp/source",
            sourceFormat: .claudeJSONL, locator: .byteRange(offset: 0, length: 1), sectionFlags: 8
        )
        let emptyError = MessageSummary(
            id: 2, role: .toolResult, timestampMilliseconds: 1, prefix: "", toolSummary: nil,
            characterCount: 0, hasError: true, sourcePath: "/tmp/source",
            sourceFormat: .claudeJSONL, locator: .byteRange(offset: 1, length: 1), sectionFlags: 0
        )
        XCTAssertTrue(visibility.includes(attachment))
        XCTAssertTrue(visibility.includes(emptyError), "error metadata must survive hidden tool content")
    }

    func testSourceGenerationChangesOnlyForReplacement() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let initialSessions = try await database.sessions()
        let initial = try XCTUnwrap(initialSessions.first)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let appendedSessions = try await database.sessions()
        let appended = try XCTUnwrap(appendedSessions.first)
        XCTAssertEqual(appended.id, initial.id)
        XCTAssertEqual(appended.sourceGeneration, initial.sourceGeneration)

        try Data(line(3).utf8).write(to: file, options: .atomic)
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let replacedSessions = try await database.sessions()
        let replaced = try XCTUnwrap(replacedSessions.first)
        XCTAssertGreaterThan(replaced.sourceGeneration, appended.sourceGeneration)
    }

    func testIndexFormatResetIsReportedAndBatchCheckpointsAreBounded() async throws {
        let root = try directory()
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: databaseURL)
        XCTAssertFalse(database.contentWasResetOnOpen)
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
            .indexAll(scope: .proseOnly)
        let beforeReset = try await database.statistics()
        XCTAssertEqual(beforeReset.messageCount, 1)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE trace_meta SET value='1' WHERE key='index_format_version'")
        }
        let reopened = try IndexDatabase(url: databaseURL)
        XCTAssertTrue(reopened.contentWasResetOnOpen)
        let afterReset = try await reopened.statistics()
        XCTAssertEqual(afterReset.messageCount, 0)
        let reopenedAgain = try IndexDatabase(url: databaseURL)
        XCTAssertFalse(reopenedAgain.contentWasResetOnOpen)

        try Data((0..<600).map { line($0) }.joined().utf8).write(to: file)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE checkpoint_audit(value INTEGER)")
            try db.execute(sql: """
                CREATE TRIGGER checkpoint_updates AFTER UPDATE OF scanned_bytes ON source_file
                BEGIN INSERT INTO checkpoint_audit(value) VALUES (new.scanned_bytes); END
                """)
        }
        await IndexCoordinator(database: reopened, sources: [ClaudeCodeSource(roots: [root])])
            .indexAll(scope: .proseOnly)
        let updates = try await raw.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM checkpoint_audit") ?? 0 }
        XCTAssertLessThanOrEqual(updates, 4, "600 lines should commit three batch checkpoints plus final fingerprint state")
    }

    func testV4MigrationAddsSourceGenerationWithoutResettingContent() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let databaseURL = root.appendingPathComponent("index.sqlite")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: databaseURL)
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
            .indexAll(scope: .proseOnly)
        let indexedSessions = try await database.sessions()
        let originalID = try XCTUnwrap(indexedSessions.first?.id)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN content_generation")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v4-source-generation'")
            try db.execute(sql: "UPDATE trace_meta SET value='3' WHERE key='schema_version'")
        }

        let migrated = try IndexDatabase(url: databaseURL)
        XCTAssertFalse(migrated.contentWasResetOnOpen)
        let migratedSessions = try await migrated.sessions()
        let migratedSession = try XCTUnwrap(migratedSessions.first)
        XCTAssertEqual(migratedSession.id, originalID)
        XCTAssertEqual(migratedSession.sourceGeneration, 0)
        let schema = try await raw.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='schema_version'")
        }
        XCTAssertEqual(schema, "4")
    }

    func testIncrementalRollupsSkipUnchangedPassAndRunAfterChangedInput() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let usageLine = #"{"type":"assistant","uuid":"one","sessionId":"session","cwd":"/tmp/project","timestamp":1700000000000,"message":{"id":"response","model":"claude-sonnet-5","content":"answer","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        try Data(usageLine.utf8).write(to: file)
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE rollup_audit(value INTEGER)")
            try db.execute(sql: """
                CREATE TRIGGER rollup_deletes AFTER DELETE ON usage_daily
                BEGIN INSERT INTO rollup_audit(value) VALUES (1); END
                """)
        }

        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let unchangedDeletes = try await raw.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM rollup_audit") }
        XCTAssertEqual(unchangedDeletes, 0)

        let noOpHandle = try FileHandle(forWritingTo: file)
        try noOpHandle.seekToEnd()
        try noOpHandle.write(contentsOf: Data("{}\n".utf8))
        try noOpHandle.close()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let noOpDeletes = try await raw.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM rollup_audit") }
        XCTAssertEqual(noOpDeletes, 0, "checkpoint-only appends must not rebuild usage rollups")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let changedDeletes = try await raw.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM rollup_audit") }
        XCTAssertEqual(changedDeletes, 1)
    }

    func testCommittedBatchRebuildsRollupsEvenWhenThePassLaterFails() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let initial = #"{"type":"assistant","uuid":"initial","sessionId":"session","cwd":"/tmp/project","timestamp":1700000000000,"message":{"id":"initial-response","model":"claude-sonnet-5","content":"initial","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        try Data(initial.utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let invocation = ReadCounter()
        let source = ThrowAfterIncrementalEOFSource(
            base: ClaudeCodeSource(roots: [root]), invocation: invocation
        )
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)

        let appended = (0..<300).map { index in
            #"{"type":"assistant","uuid":"append-#(index)","sessionId":"session","cwd":"/tmp/project","timestamp":1700000001000,"message":{"id":"append-response-#(index)","model":"claude-sonnet-5","content":"append","usage":{"input_tokens":1,"output_tokens":0}}}"#
        }.joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let progress = IndexErrorRecorder()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly) { progress.receive($0) }
        XCTAssertNotNil(progress.error, "the synthetic source should fail after its committed batch")

        let rollups = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        let usage = try XCTUnwrap(rollups.first { $0.model == "claude-sonnet-5" })
        XCTAssertEqual(usage.inputTokens, 260, "the initial observation plus the committed 250-line batch must be aggregated")
    }

    func testQuietSnapshotCancellationPreservesPreviousIndexContents() async throws {
        let root = try directory()
        let project = root.appendingPathComponent("project")
        let chats = project.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-snapshot.json")
        try Data(#"{"sessionId":"snapshot","messages":[{"id":"old","type":"user","timestamp":1700000000000,"content":"preserved phrase"}]}"#.utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(database: database, sources: [GeminiSource(root: root)])
            .indexAll(scope: .proseOnly)
        let initialResults = try await database.search(query: "preserved")
        XCTAssertEqual(initialResults.results.count, 1)

        try Data(#"{"sessionId":"snapshot","messages":[{"id":"new","type":"user","timestamp":1700000001000,"content":"replacement phrase"}]}"#.utf8)
            .write(to: file, options: .atomic)
        let gate = QuietSnapshotGate()
        let source = QuietSnapshotSource(root: root, file: file, gate: gate)
        let run = Task {
            await IndexCoordinator(database: database, sources: [source])
                .refresh(paths: [file.path], scope: .proseOnly)
        }
        try await gate.waitUntilPaused()
        run.cancel()
        await run.value

        let preservedResults = try await database.search(query: "preserved")
        let replacementResults = try await database.search(query: "replacement")
        XCTAssertEqual(preservedResults.results.count, 1)
        XCTAssertTrue(replacementResults.results.isEmpty)
    }

    func testSnapshotMutationDuringScanRetriesBeforeReplacement() async throws {
        let root = try directory()
        let project = root.appendingPathComponent("project")
        let chats = project.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-snapshot.json")
        try Data(#"{"sessionId":"snapshot","messages":[{"id":"old","type":"user","content":"old version"}]}"#.utf8)
            .write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let invocation = ReadCounter()
        let finalDocument = Data(#"{"sessionId":"snapshot","messages":[{"id":"final","type":"user","content":"final version"}]}"#.utf8)
        let source = MutatingSnapshotSource(
            base: GeminiSource(root: root), file: file, replacement: finalDocument, invocation: invocation
        )
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)

        try Data(#"{"sessionId":"snapshot","messages":[{"id":"middle","type":"user","content":"middle version"}]}"#.utf8)
            .write(to: file, options: .atomic)
        let progress = IndexErrorRecorder()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly) { progress.receive($0) }
        XCTAssertNil(progress.error)
        let middleResults = try await database.search(query: "middle")
        let finalResults = try await database.search(query: "final")
        XCTAssertTrue(middleResults.results.isEmpty)
        XCTAssertEqual(finalResults.results.count, 1)
    }

    func testLegacyFailureScanMergesFailedMessageAndAbortedEvent() async throws {
        let root = try directory()
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Codex")
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let source = CodexSource(root: fixtures)
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .everything)
        let sessions = try await database.sessions()
        let session = try XCTUnwrap(sessions.first { $0.hadError })
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE message SET section_flags=NULL WHERE session_id=?", arguments: [session.id])
            try db.execute(sql: "DELETE FROM session_failure WHERE session_id=?", arguments: [session.id])
        }
        let failures = try await coordinator.failures(for: session)
        XCTAssertTrue(failures.contains { $0.kind == "failed tool" })
        XCTAssertTrue(failures.contains { $0.kind == "aborted" })
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
        XCTAssertEqual(changes.reconciliationPaths, ["/root"])

        let privateVar = TraceFileIO.canonicalPath("/private/var/folders")
        let varPath = TraceFileIO.canonicalPath("/var/folders")
        XCTAssertEqual(privateVar.comparisonKey, varPath.comparisonKey)
        XCTAssertEqual(
            TraceFileIO.canonicalPath("/TMP/trace/session.jsonl").comparisonKey,
            TraceFileIO.canonicalPath("/tmp/TRACE/session.jsonl").comparisonKey
        )
        XCTAssertTrue(varPath.intersects(TraceFileIO.canonicalPath("/var/folders/trace")))
        XCTAssertFalse(varPath.intersects(TraceFileIO.canonicalPath("/var/db")))
        XCTAssertTrue(TraceFileIO.canonicalPath("/").contains(varPath))

        XCTAssertTrue(TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: "/tmp/session_index.jsonl")))
        XCTAssertTrue(TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: "/tmp/state_5.sqlite")))
        XCTAssertFalse(TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: "/tmp/state_5.sqlite-wal")))
        XCTAssertFalse(TraceFileIO.isCodexMetadataSidecar(URL(fileURLWithPath: "/tmp/state_latest.sqlite")))
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
    func nextInvocation() -> Int { lock.withLock { count += 1; return count } }
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

private struct ThrowAfterIncrementalEOFSource: SessionSource {
    let base: ClaudeCodeSource
    let invocation: ReadCounter
    var agent: AgentKind { base.agent }
    var roots: [SourceRoot] { base.roots }

    func discover() throws -> [DiscoveredSourceFile] { try base.discover() }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let source = base.records(in: file, from: offset, through: boundary)
        guard invocation.nextInvocation() > 1 else { return source }
        let state: SyntheticIncrementalFailureState
        do {
            state = try SyntheticIncrementalFailureState(file: file, offset: offset, boundary: boundary)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream(unfolding: { try state.next() })
    }

    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        try base.hydrate(fileURL: fileURL, format: format, locator: locator)
    }
}

private final class SyntheticIncrementalFailureState: @unchecked Sendable {
    private let cursor: JSONLineCursor
    private var pending: ArraySlice<ParsedRecord> = []
    private var reachedEOF = false

    init(file: DiscoveredSourceFile, offset: Int64, boundary: Int64?) throws {
        cursor = try JSONLineCursor(url: file.url, from: offset, through: boundary)
    }

    func next() throws -> ParsedRecord? {
        try Task.checkCancellation()
        if let record = pending.popFirst() { return record }
        if let line = try cursor.next() {
            let key = String(line.offset)
            let usage = UsageObservation(
                dedupeKey: "response-\(key)", model: "claude-sonnet-5",
                inputTokens: 1, outputTokens: 0
            )
            pending = [
                .message(.init(
                    sourceKey: key, externalID: key, sessionExternalID: "session",
                    cwd: "/tmp/project", timestampMilliseconds: 1_700_000_001_000 + line.offset,
                    role: .assistant, sections: .init(prose: "append"),
                    locator: .byteRange(offset: line.offset, length: Int64(line.data.count)),
                    model: "claude-sonnet-5", usage: usage
                )),
                .checkpoint(line.endOffset),
            ]
            return pending.popFirst()
        }
        guard !reachedEOF else { return nil }
        reachedEOF = true
        throw SessionSourceError.malformedRecord("synthetic failure after committed records")
    }
}

private struct MutatingSnapshotSource: SessionSource {
    let base: GeminiSource
    let file: URL
    let replacement: Data
    let invocation: ReadCounter
    var agent: AgentKind { base.agent }
    var roots: [SourceRoot] { base.roots }

    func discover() throws -> [DiscoveredSourceFile] { try base.discover() }

    func records(
        in discovered: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let number = invocation.nextInvocation()
        guard number == 2 else { return base.records(in: discovered, from: offset, through: boundary) }
        let state = MutateThenFailState(file: file, replacement: replacement)
        return AsyncThrowingStream(unfolding: { try state.next() })
    }

    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        try base.hydrate(fileURL: fileURL, format: format, locator: locator)
    }
}

private final class MutateThenFailState: @unchecked Sendable {
    private let file: URL
    private let replacement: Data
    private var finished = false

    init(file: URL, replacement: Data) {
        self.file = file
        self.replacement = replacement
    }

    func next() throws -> ParsedRecord? {
        guard !finished else { return nil }
        finished = true
        try replacement.write(to: file, options: .atomic)
        throw SessionSourceError.malformedRecord("synthetic mutation during snapshot scan")
    }
}

private struct QuietSnapshotSource: SessionSource {
    let agent = AgentKind.gemini
    let roots: [SourceRoot]
    let file: URL
    let gate: QuietSnapshotGate

    init(root: URL, file: URL, gate: QuietSnapshotGate) {
        roots = [.init(agent: .gemini, url: root)]
        self.file = file
        self.gate = gate
    }

    func discover() throws -> [DiscoveredSourceFile] {
        [.init(agent: .gemini, root: roots[0].url, url: file, format: .geminiJSON)]
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let state = QuietSnapshotState(gate: gate)
        return AsyncThrowingStream(unfolding: { await state.next() })
    }

    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        throw SessionSourceError.unsupportedLocator
    }
}

private actor QuietSnapshotState {
    let gate: QuietSnapshotGate
    private var emitted = false

    init(gate: QuietSnapshotGate) { self.gate = gate }

    func next() async -> ParsedRecord? {
        if !emitted {
            emitted = true
            return .message(.init(
                sourceKey: "new", externalID: "new", sessionExternalID: "snapshot",
                cwd: "/tmp/project", timestampMilliseconds: 1_700_000_001_000,
                role: .user, sections: .init(prose: "replacement phrase"),
                locator: .byteRange(offset: 0, length: 1)
            ))
        }
        await gate.pauseQuietlyUntilCancelled()
        return nil
    }
}

private actor QuietSnapshotGate {
    private var paused = false

    func pauseQuietlyUntilCancelled() async {
        paused = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { }
    }

    func waitUntilPaused() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !paused {
            guard ContinuousClock.now < deadline else { throw BatchLatchError.timedOut }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor BatchLatch {
    private var paused = false
    private var released = false
    private var pauseWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var resume: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        guard !paused else { return }
        paused = true
        pauseWaiters.values.forEach { $0.resume() }
        pauseWaiters = [:]
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks = [:]
        if !released { await withCheckedContinuation { resume = $0 } }
    }
    func waitForPause() async throws {
        if paused { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if paused {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pauseWaiters[id] = continuation
                    timeoutTasks[id] = Task {
                        do { try await Task.sleep(for: .seconds(2)) }
                        catch { return }
                        self.timeout(id: id)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }
    func release() { released = true; resume?.resume(); resume = nil }

    private func timeout(id: UUID) {
        guard let continuation = pauseWaiters.removeValue(forKey: id) else { return }
        timeoutTasks[id] = nil
        continuation.resume(throwing: BatchLatchError.timedOut)
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = pauseWaiters.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: CancellationError())
    }
}

private enum BatchLatchError: Error { case timedOut }

private final class IndexErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func receive(_ progress: IndexProgress) {
        lock.withLock {
            if let error = progress.error { stored = error }
        }
    }

    var error: String? { lock.withLock { stored } }
}

private actor RunRecorder {
    var terminalPhases: [IndexProgress.Phase] = []
    func receive(_ progress: IndexProgress) {
        if [.complete, .cancelled, .failed].contains(progress.phase) { terminalPhases.append(progress.phase) }
    }
}
