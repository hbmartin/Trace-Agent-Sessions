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

    func testScopedReconciliationDeletesOnlyFilesBelowAffectedDirectory() async throws {
        let root = try directory()
        let firstDirectory = root.appendingPathComponent("first")
        let secondDirectory = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("first.jsonl")
        let second = secondDirectory.appendingPathComponent("second.jsonl")
        try Data(line(1).utf8).write(to: first)
        try Data(line(2).utf8).write(to: second)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [root])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        try FileManager.default.removeItem(at: firstDirectory)

        let terminal = await coordinator.reconcile(
            paths: [firstDirectory.path], scope: .proseOnly, activity: .subtreeRecovery
        )

        XCTAssertEqual(terminal.activity, .subtreeRecovery)
        let statistics = try await database.statistics()
        let secondState = try await database.sourceState(path: second.path)
        XCTAssertEqual(statistics.sourceFileCount, 1)
        XCTAssertNotNil(secondState)
    }

    func testAncestorSymlinkRefreshUsesCanonicalContainment() async throws {
        let parent = try directory()
        let realParent = parent.appendingPathComponent("real")
        let realRoot = realParent.appendingPathComponent("sessions")
        let aliasParent = parent.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: aliasParent.path, withDestinationPath: realParent.lastPathComponent
        )
        let configuredRoot = aliasParent.appendingPathComponent("sessions")
        let file = realRoot.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: parent.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [configuredRoot])]
        )
        await coordinator.indexAll(scope: .proseOnly)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        await coordinator.refresh(
            paths: [configuredRoot.appendingPathComponent("session.jsonl").path],
            scope: .proseOnly
        )

        let search = try await database.search(query: "message 2")
        XCTAssertEqual(search.results.count, 1)
    }

    func testPrivateVarConfiguredRootKeepsDatabaseIdentityDuringIndexing() async throws {
        let physicalRoot = try directory()
        guard physicalRoot.path.hasPrefix("/var/") else {
            throw XCTSkip("temporary directory is not exposed through the /private/var alias")
        }
        let configuredRoot = URL(fileURLWithPath: "/private" + physicalRoot.path)
        let file = physicalRoot.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: physicalRoot.appendingPathComponent("index.sqlite"))
        let source = ClaudeCodeSource(roots: [configuredRoot])

        let result = await IndexCoordinator(database: database, sources: [source])
            .indexAllResult(scope: .proseOnly)

        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(result.indexedFiles, 1)
        let search = try await database.search(query: "searchable")
        let health = try await database.sourceHealth()
        XCTAssertEqual(search.results.count, 1)
        XCTAssertEqual(health.first?.rootPath, configuredRoot.path)
    }

    func testEquivalentClaudeRootsAreDeduplicatedWithDefaultPreferred() throws {
        let parent = try directory()
        let target = parent.appendingPathComponent("target")
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path, withDestinationPath: target.lastPathComponent
        )

        let source = ClaudeCodeSource(roots: [target, alias, target])

        XCTAssertEqual(source.roots.count, 1)
        XCTAssertTrue(source.roots[0].isDefault)
        XCTAssertEqual(source.roots[0].url.path, target.path)
    }

    func testTrustedWholeFileDigestSkipsParsingIdenticalAtomicReplacement() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let content = Data(line(1).utf8)
        try content.write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let counter = ReadCounter()
        let coordinator = IndexCoordinator(
            database: database,
            sources: [CountingSource(base: ClaudeCodeSource(roots: [root]), counter: counter)]
        )
        await coordinator.indexAll(scope: .proseOnly)
        try content.write(to: file, options: .atomic)

        await coordinator.refresh(paths: [file.path], scope: .proseOnly)

        XCTAssertEqual(counter.value, 1)
        let statistics = try await database.statistics()
        XCTAssertEqual(statistics.messageCount, 1)
    }

    func testRootReconciliationRemovesFilesFromDetachedRoot() async throws {
        let directory = try directory()
        let removedRoot = directory.appendingPathComponent("removed")
        let retainedRoot = directory.appendingPathComponent("retained")
        try FileManager.default.createDirectory(at: removedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedRoot, withIntermediateDirectories: true)
        let removedFile = removedRoot.appendingPathComponent("removed.jsonl")
        let retainedFile = retainedRoot.appendingPathComponent("retained.jsonl")
        try Data(line(1).utf8).write(to: removedFile)
        try Data(line(2).utf8).write(to: retainedFile)
        let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(
            database: database,
            sources: [ClaudeCodeSource(roots: [removedRoot, retainedRoot])]
        ).indexAll(scope: .proseOnly)

        await IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [retainedRoot])]
        ).reconcile(
            paths: [removedRoot.path, retainedRoot.path], scope: .proseOnly,
            activity: .rootRecovery
        )

        let removedState = try await database.sourceState(path: removedFile.path)
        let retainedState = try await database.sourceState(path: retainedFile.path)
        XCTAssertNil(removedState)
        XCTAssertNotNil(retainedState)
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

    func testProjectSessionsUseSessionIDToBreakActivityTies() async throws {
        let root = try directory()
        for name in ["alpha", "beta"] {
            let row = """
            {"type":"user","uuid":"\(name)-message","sessionId":"\(name)","cwd":"/tmp/TraceExample","timestamp":"2026-09-14T10:00:00Z","message":{"content":"\(name)"}}
            """
            try Data((row + "\n").utf8).write(
                to: root.appendingPathComponent("\(name).jsonl")
            )
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(
            database: database,
            sources: [ClaudeCodeSource(roots: [root])]
        ).indexAll(scope: .proseOnly)

        let sessions = try await database.sessions(projectCanonicalKey: "/tmp/traceexample")
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(
            Set(sessions.map(\.lastActivityMilliseconds)).count, 1,
            "the fixture must exercise the session-ID tie-break"
        )
        XCTAssertEqual(sessions.map(\.id), sessions.map(\.id).sorted(by: >))
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
        let completions = CompletionRecorder()
        let scheduler = IndexScheduler(coordinator: coordinator, scope: .proseOnly) { progress in
            await recorder.receive(progress)
            if progress.phase == .indexing && progress.currentFileBytes > 0 { await latch.pauseOnce() }
        } didComplete: { activity, watermarks in
            await completions.receive(activity: activity, watermarks: watermarks)
        }
        await scheduler.request(reconcile: true, watermarks: ["volume": 1])
        try await latch.waitForPause()
        for eventID in 2...30 {
            await scheduler.request(paths: [file.path], watermarks: ["volume": UInt64(eventID)])
        }
        await scheduler.request(
            rebuild: true, scope: .everything, watermarks: ["volume": 31]
        )
        await latch.release()
        await scheduler.waitUntilIdle()
        let phases = await recorder.terminalPhases
        XCTAssertEqual(phases, [.cancelled, .complete])
        let completed = await completions.values
        XCTAssertEqual(completed.count, 1, "the replacement full scan must absorb cancelled work")
        XCTAssertEqual(completed.first?.watermarks["volume"], 31)
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
        let emptyAssistant = MessageSummary(
            id: 3, role: .assistant, timestampMilliseconds: 1, prefix: "", toolSummary: nil,
            characterCount: 0, hasError: false, sourcePath: "/tmp/source",
            sourceFormat: .claudeJSONL, locator: .byteRange(offset: 2, length: 1), sectionFlags: 0
        )
        let emptyReasoning = MessageSummary(
            id: 4, role: .reasoning, timestampMilliseconds: 1, prefix: "", toolSummary: nil,
            characterCount: 0, hasError: false, sourcePath: "/tmp/source",
            sourceFormat: .codexJSONL, locator: .byteRange(offset: 3, length: 1), sectionFlags: 0
        )
        XCTAssertFalse(all.includes(emptyAssistant))
        XCTAssertFalse(all.includes(emptyReasoning))
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

    func testInodeRenameKeepsSourceAndMessageIDsForBothPathOrders() async throws {
        for (originalName, renamedName) in [("a-session.jsonl", "z-session.jsonl"),
                                            ("z-session.jsonl", "a-session.jsonl")] {
            let root = try directory()
            let original = root.appendingPathComponent(originalName)
            let renamed = root.appendingPathComponent(renamedName)
            try Data(line(1).utf8).write(to: original)
            let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
            let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
            await coordinator.indexAll(scope: .proseOnly)
            let initialState = try await database.sourceState(path: original.path)
            let sourceID = try XCTUnwrap(initialState?.id)
            let initialSearch = try await database.search(query: "searchable")
            let originalResult = try XCTUnwrap(initialSearch.results.first)

            try FileManager.default.moveItem(at: original, to: renamed)
            let recorder = ProgressRecorder()
            await coordinator.refresh(paths: [original.path, renamed.path], scope: .proseOnly) {
                recorder.receive($0)
            }
            let terminal = try XCTUnwrap(recorder.terminal)
            XCTAssertEqual(terminal.phase, .complete)
            XCTAssertTrue(terminal.indexChanged)
            XCTAssertGreaterThan(terminal.mutationRevision, 0)
            let oldState = try await database.sourceState(path: original.path)
            let newState = try await database.sourceState(path: renamed.path)
            XCTAssertNil(oldState)
            XCTAssertEqual(newState?.id, sourceID)
            let movedSearch = try await database.search(query: "searchable")
            let movedResult = try XCTUnwrap(movedSearch.results.first)
            XCTAssertEqual(movedResult.id, originalResult.id)
            XCTAssertEqual(movedResult.sourcePath, renamed.path)
            let hydrated = try await coordinator.hydrate(messageID: movedResult.id)
            XCTAssertTrue(hydrated.sections.prose.contains("searchable message 1"))
        }
    }

    func testCaseOnlyRenameKeepsSourceAndMessageIDs() async throws {
        let root = try directory()
        let original = root.appendingPathComponent("Session.jsonl")
        let renamed = root.appendingPathComponent("session.jsonl")
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames
        if caseSensitive != false { throw XCTSkip("Requires a case-insensitive volume") }
        try Data(line(1).utf8).write(to: original)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let oldState = try await database.sourceState(path: original.path)
        let oldID = try XCTUnwrap(oldState?.id)
        let oldResults = try await database.search(query: "searchable")
        let oldMessageID = try XCTUnwrap(oldResults.results.first?.id)

        try FileManager.default.moveItem(at: original, to: renamed)
        await coordinator.refresh(paths: [original.path, renamed.path], scope: .proseOnly)
        let missing = try await database.sourceState(path: original.path)
        let moved = try await database.sourceState(path: renamed.path)
        XCTAssertNil(missing)
        XCTAssertEqual(moved?.id, oldID)
        let results = try await database.search(query: "searchable")
        XCTAssertEqual(results.results.map(\.id), [oldMessageID])
        XCTAssertEqual(results.results.first?.sourcePath, renamed.path)
    }

    func testPlaceholderRecoveryMovesSameFormatInodeWithoutLosingIDs() async throws {
        let root = try directory()
        let original = root.appendingPathComponent("original.jsonl")
        let renamed = root.appendingPathComponent("renamed.jsonl")
        let usage = #"{"type":"assistant","uuid":"usage","sessionId":"session","cwd":"/tmp/TraceExample","timestamp":1700000000000,"message":{"id":"response","model":"claude-sonnet-5","content":"cost record","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        try Data((line(1) + usage).utf8).write(to: original)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = ClaudeCodeSource(roots: [root])
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)
        let indexedState = try await database.sourceState(path: original.path)
        let sourceID = try XCTUnwrap(indexedState?.id)
        let initialSearch = try await database.search(query: "searchable")
        let messageID = try XCTUnwrap(initialSearch.results.first?.id)
        let originalUsage = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertEqual(originalUsage.first?.inputTokens, 10)

        try FileManager.default.moveItem(at: original, to: renamed)
        let rootID = try await database.register(root: source.roots[0])
        try await database.recordSourceError(
            file: .init(agent: .claudeCode, root: root, url: renamed, format: .claudeJSONL),
            rootID: rootID, error: "synthetic error before recovery"
        )
        let placeholder = try await database.sourceState(path: renamed.path)
        XCTAssertTrue(try XCTUnwrap(placeholder).isPlaceholder)
        await coordinator.refresh(paths: [original.path, renamed.path], scope: .proseOnly)
        let recoveredState = try await database.sourceState(path: renamed.path)
        let recovered = try XCTUnwrap(recoveredState)
        XCTAssertEqual(recovered.id, sourceID)
        XCTAssertFalse(recovered.isPlaceholder)
        XCTAssertNil(recovered.lastError)
        let missing = try await database.sourceState(path: original.path)
        let recoveredSearch = try await database.search(query: "searchable")
        let failureCount = try await database.unresolvedSourceFailureCount()
        XCTAssertNil(missing)
        XCTAssertEqual(recoveredSearch.results.first?.id, messageID)
        XCTAssertEqual(failureCount, 0)
        let recoveredUsage = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertEqual(recoveredUsage.first?.inputTokens, 10)
    }

    func testPlaceholderPromotionIndexesNewFileWithoutContentReplacement() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("new.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = ClaudeCodeSource(roots: [root])
        let rootID = try await database.register(root: source.roots[0])
        try await database.recordSourceError(
            file: .init(agent: .claudeCode, root: root, url: file, format: .claudeJSONL),
            rootID: rootID, error: "synthetic transient error"
        )
        let placeholder = try await database.sourceState(path: file.path)
        let placeholderID = try XCTUnwrap(placeholder?.id)
        await IndexCoordinator(database: database, sources: [source]).indexAll(scope: .proseOnly)
        let indexedState = try await database.sourceState(path: file.path)
        let state = try XCTUnwrap(indexedState)
        XCTAssertEqual(state.id, placeholderID)
        XCTAssertFalse(state.isPlaceholder)
        XCTAssertEqual(state.contentGeneration, 0)
        XCTAssertNil(state.lastError)
        let search = try await database.search(query: "searchable")
        XCTAssertEqual(search.results.count, 1)
    }

    func testInodeRenameAcrossGeminiFormatsReindexesNewSource() async throws {
        let root = try directory()
        let chats = root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let original = chats.appendingPathComponent("session-switch.json")
        let renamed = chats.appendingPathComponent("session-switch.jsonl")
        let object: [String: Any] = ["sessionId": "switch", "messages": [[
            "id": "one", "type": "user", "timestamp": "2026-03-04T05:06:07Z", "content": "searchable switch"
        ]]]
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.write(to: original)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [GeminiSource(root: root)])
        await coordinator.indexAll(scope: .proseOnly)
        let originalState = try await database.sourceState(path: original.path)
        let oldID = try XCTUnwrap(originalState?.id)
        try FileManager.default.moveItem(at: original, to: renamed)
        await coordinator.refresh(paths: [original.path, renamed.path], scope: .proseOnly)
        let reindexedState = try await database.sourceState(path: renamed.path)
        let state = try XCTUnwrap(reindexedState)
        XCTAssertNotEqual(state.id, oldID)
        XCTAssertEqual(state.format, .geminiJSONL)
        let missing = try await database.sourceState(path: original.path)
        let search = try await database.search(query: "searchable")
        XCTAssertNil(missing)
        XCTAssertEqual(search.results.count, 1)
    }

    func testUnresolvedSourceErrorSurvivesQuietAndCancelledPasses() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(0).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = ClaudeCodeSource(roots: [root])
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)
        let rootID = try await database.register(root: source.roots[0])
        let failedFile = root.appendingPathComponent("failed.jsonl")
        try await database.recordSourceError(
            file: .init(agent: .claudeCode, root: root, url: failedFile, format: .claudeJSONL),
            rootID: rootID, error: "synthetic unreadable file"
        )
        let quiet = ProgressRecorder()
        await coordinator.refresh(paths: [], scope: .proseOnly) { quiet.receive($0) }
        XCTAssertEqual(quiet.terminal?.phase, .complete)
        XCTAssertEqual(quiet.terminal?.unresolvedFailedFiles, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((1..<601).map { line($0) }.joined().utf8))
        try handle.close()

        let latch = BatchLatch()
        let cancelled = ProgressRecorder()
        let run = Task {
            await coordinator.indexAll(scope: .proseOnly) { update in
                cancelled.receive(update)
                if update.phase == .indexing && update.currentFileBytes > 0 { await latch.pauseOnce() }
            }
        }
        try await latch.waitForPause()
        run.cancel()
        await latch.release()
        await run.value
        XCTAssertEqual(cancelled.terminal?.phase, .cancelled)
        XCTAssertEqual(cancelled.terminal?.unresolvedFailedFiles, 1)
        let unresolved = try await database.unresolvedSourceFailureCount()
        XCTAssertEqual(unresolved, 1)
    }

    func testSuccessfulQuietPassClearsAdapterHealthOnlyError() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE adapter_health SET last_error='legacy error'")
            try db.execute(sql: "UPDATE source_file SET last_error=NULL")
        }
        let recordedError = try await database.sourceState(path: file.path)?.hadRecordedError
        XCTAssertEqual(recordedError, true)
        let unhealthy = try await database.sourceHealth()
        XCTAssertTrue(unhealthy.contains { $0.error != nil })
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let healthy = try await database.sourceHealth()
        let clearedError = try await database.sourceState(path: file.path)?.hadRecordedError
        XCTAssertEqual(clearedError, false)
        let clearedAgain = try await database.clearSourceError(path: file.path)
        XCTAssertFalse(healthy.contains { $0.error != nil })
        XCTAssertFalse(clearedAgain)
    }

    func testQuietPassReportsDirtyRollupRepairWithoutIndexMutation() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { try $0.execute(sql: "UPDATE trace_meta SET value='1' WHERE key='usage_rollups_dirty'") }
        let repaired = ProgressRecorder()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly) { repaired.receive($0) }
        XCTAssertEqual(repaired.terminal?.phase, .complete)
        XCTAssertEqual(repaired.terminal?.indexChanged, false)
        XCTAssertEqual(repaired.terminal?.rollupsChanged, true)
        let quiet = ProgressRecorder()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly) { quiet.receive($0) }
        XCTAssertEqual(quiet.terminal?.rollupsChanged, false)
    }

    func testRelevancePageMergeDropsRepeatedIDsAndPreservesCursor() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data((line(1) + line(2)).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
            .indexAll(scope: .proseOnly)
        let ranked = try await database.search(query: "searchable", sort: .relevance)
        XCTAssertEqual(ranked.results.count, 2)
        let first = try XCTUnwrap(ranked.results.first)
        let second = try XCTUnwrap(ranked.results.last)
        let cursor = SearchCursor(rowID: second.id, rank: second.rank)
        let shiftedPage = SearchPage(results: [first, first, second], nextCursor: cursor)
        XCTAssertEqual(shiftedPage.uniqueResults(excluding: []).map(\.id), [first.id, second.id],
                       "reset pages must also drop duplicate IDs")
        let unique = shiftedPage.uniqueResults(excluding: [first.id])
        XCTAssertEqual(unique.map(\.id), [second.id])
        XCTAssertEqual(shiftedPage.nextCursor?.rowID, cursor.rowID)
        let duplicateOnly = SearchPage(results: [first, first], nextCursor: cursor)
        XCTAssertTrue(duplicateOnly.uniqueResults(excluding: [first.id]).isEmpty)
        XCTAssertEqual(duplicateOnly.nextCursor?.rowID, cursor.rowID,
                       "deduplication must retain the cursor needed to advance")
    }

    func testRollupFailureLeavesSearchAvailableAndDirtyForRetry() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let usage = #"{"type":"assistant","uuid":"one","sessionId":"session","cwd":"/tmp/project","timestamp":1700000000000,"message":{"id":"response","model":"claude-sonnet-5","content":"searchable cost","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        try Data(usage.utf8).write(to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_rollup BEFORE DELETE ON usage_daily BEGIN SELECT RAISE(ABORT, 'rollup unavailable'); END")
        }
        let appended = #"{"type":"assistant","uuid":"two","sessionId":"session","cwd":"/tmp/project","timestamp":1700000001000,"message":{"id":"response-two","model":"claude-sonnet-5","content":"more searchable cost","usage":{"input_tokens":4,"output_tokens":1}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let recorder = ProgressRecorder()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly) { recorder.receive($0) }
        XCTAssertEqual(recorder.terminal?.phase, .complete)
        XCTAssertNotNil(recorder.terminal?.rollupError)
        let search = try await database.search(query: "searchable")
        XCTAssertEqual(search.results.count, 2)
        let dirty = try await raw.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_dirty'")
        }
        XCTAssertEqual(dirty, "1")
        try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_rollup") }
        try await database.rebuildUsageRollupsIfDirty()
        let repaired = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertEqual(repaired.first?.inputTokens, 14)
    }

    func testTimezoneMarkerForcesRollupRebuildWithoutDirtyFlag() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let usage = #"{"type":"assistant","uuid":"one","sessionId":"session","cwd":"/tmp/project","timestamp":1700000000000,"message":{"id":"response","model":"claude-sonnet-5","content":"answer","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        try Data(usage.utf8).write(to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE timezone_rollup_audit(value INTEGER)")
            try db.execute(sql: "CREATE TRIGGER timezone_rollup AFTER DELETE ON usage_daily BEGIN INSERT INTO timezone_rollup_audit VALUES (1); END")
        }
        try await database.rebuildUsageRollupsIfDirty(timeZoneID: "Test/ZoneA")
        try await database.rebuildUsageRollupsIfDirty(timeZoneID: "Test/ZoneA")
        try await database.rebuildUsageRollupsIfDirty(timeZoneID: "Test/ZoneB")
        let (deletes, zone, dirty) = try await raw.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM timezone_rollup_audit"),
             try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_timezone'"),
             try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_dirty'"))
        }
        XCTAssertEqual(deletes, 2)
        XCTAssertEqual(zone, "Test/ZoneB")
        XCTAssertEqual(dirty, "0")
    }

    func testConcurrentDirtyRollupRequestsRebuildExactlyOnce() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let usage = #"{"type":"assistant","uuid":"one","sessionId":"session","cwd":"/tmp/project","timestamp":1700000000000,"message":{"id":"response","model":"claude-sonnet-5","content":"answer","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        try Data(usage.utf8).write(to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
            .indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE concurrent_rollup_audit(value INTEGER)")
            try db.execute(sql: """
                CREATE TRIGGER concurrent_rollup AFTER DELETE ON usage_daily
                BEGIN INSERT INTO concurrent_rollup_audit VALUES (1); END
                """)
            try db.execute(
                sql: "UPDATE trace_meta SET value='1' WHERE key='usage_rollups_dirty'"
            )
        }

        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await database.rebuildUsageRollupsIfDirty(
                        timeZoneID: "Test/Concurrent"
                    )
                }
            }
            var results: [Bool] = []
            for try await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let (deletes, dirty, zone) = try await raw.read { db in
            (
                try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM concurrent_rollup_audit"
                ),
                try String.fetchOne(
                    db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_dirty'"
                ),
                try String.fetchOne(
                    db, sql: "SELECT value FROM trace_meta WHERE key='usage_rollups_timezone'"
                )
            )
        }
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(dirty, "0")
        XCTAssertEqual(zone, "Test/Concurrent")
    }

    func testIndexFormatResetIsReportedAndBatchCheckpointsAreBounded() async throws {
        let root = try directory()
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: databaseURL)
        try await database.saveEventCheckpoints(["volume": 44])
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
        let resetCheckpoint = try await reopened.eventCheckpoint(volumeID: "volume")
        XCTAssertNil(resetCheckpoint)
        let afterReset = try await reopened.statistics()
        XCTAssertEqual(afterReset.messageCount, 0)
        let rootsAfterReset = try await raw.read {
            try Int.fetchOne($0, sql: "SELECT count(*) FROM source_root") ?? -1
        }
        XCTAssertEqual(rootsAfterReset, 0, "the stable-root migration must discard old identities")
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

    func testClearIndexAndV9MigrationInvalidateEventCheckpoints() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        try await database.saveEventCheckpoints(["volume": 101])
        try await database.clearIndex()
        let clearedCheckpoint = try await database.eventCheckpoint(volumeID: "volume")
        XCTAssertNil(clearedCheckpoint)

        try await database.saveEventCheckpoints(["volume": 202])
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v9-reset-fsevents-checkpoints'"
            )
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v10-scoped-discovery-errors'"
            )
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v11-remove-redundant-scan-error-index'"
            )
            try db.execute(sql: "DROP TABLE source_scan_error")
            try db.execute(sql: "UPDATE trace_meta SET value='8' WHERE key='schema_version'")
        }
        let migrated = try IndexDatabase(url: url)
        let migratedCheckpoint = try await migrated.eventCheckpoint(volumeID: "volume")
        XCTAssertNil(migratedCheckpoint)
        let schema = try await raw.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='schema_version'")
        }
        XCTAssertEqual(schema, "11")
    }

    func testV10MigrationPreservesIndexCheckpointAndMigratesRootError() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let url = root.appendingPathComponent("index.sqlite")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: url)
        let source = ClaudeCodeSource(roots: [root])
        await IndexCoordinator(database: database, sources: [source]).indexAll(scope: .proseOnly)
        try await database.saveEventCheckpoints(["volume": 303])
        let originalIDs = try await database.search(query: "searchable").results.map(\.id)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE source_root SET last_error='legacy discovery error'")
            try db.execute(sql: "DROP TABLE source_scan_error")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v10-scoped-discovery-errors'"
            )
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v11-remove-redundant-scan-error-index'"
            )
            try db.execute(sql: "UPDATE trace_meta SET value='9' WHERE key='schema_version'")
        }

        let migrated = try IndexDatabase(url: url)

        XCTAssertFalse(migrated.contentWasResetOnOpen)
        let migratedCheckpoint = try await migrated.eventCheckpoint(volumeID: "volume")
        let migratedIDs = try await migrated.search(query: "searchable").results.map(\.id)
        XCTAssertEqual(migratedCheckpoint, 303)
        XCTAssertEqual(migratedIDs, originalIDs)
        let recovery = try await migrated.unresolvedRecoveryWork()
        XCTAssertEqual(recovery.reconciliationPaths, [source.roots[0].url.path])
        let health = try await migrated.sourceHealth()
        XCTAssertEqual(health.first?.error, "legacy discovery error")
        let redundantIndex = try await raw.read { db in
            try String.fetchOne(
                db, sql: "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_source_scan_error_root'"
            )
        }
        XCTAssertNil(redundantIndex)
        let schema = try await raw.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='schema_version'")
        }
        XCTAssertEqual(schema, "11")
    }

    func testConfiguredRootSynchronizationPurgesRemovedRootImmediately() async throws {
        let parent = try directory()
        let retained = parent.appendingPathComponent("retained")
        let removed = parent.appendingPathComponent("removed")
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        let retainedUsage = #"{"type":"assistant","uuid":"retained-usage","sessionId":"session","cwd":"/tmp/Retained","timestamp":1700000000000,"message":{"id":"retained-response","model":"claude-sonnet-5","content":"retained usage","usage":{"input_tokens":10,"output_tokens":2}}}"# + "\n"
        let removedUsage = #"{"type":"assistant","uuid":"removed-usage","sessionId":"session","cwd":"/tmp/Removed","timestamp":1700000000000,"message":{"id":"removed-response","model":"claude-sonnet-5","content":"removed usage","usage":{"input_tokens":20,"output_tokens":4}}}"# + "\n"
        try Data((line(1, project: "/tmp/Retained") + retainedUsage).utf8)
            .write(to: retained.appendingPathComponent("retained.jsonl"))
        try Data((line(2, project: "/tmp/Removed") + removedUsage).utf8)
            .write(to: removed.appendingPathComponent("removed.jsonl"))
        let url = parent.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let source = ClaudeCodeSource(roots: [retained, removed])
        await IndexCoordinator(database: database, sources: [source]).indexAll(scope: .proseOnly)
        let initialStatistics = try await database.statistics()
        let initialProjects = try await database.projects()
        let initialSessions = try await database.sessions()
        let initialUsage = try await database.usage(
            fromDay: nil, throughDay: nil, includeSidechains: true
        )
        XCTAssertEqual(initialStatistics.sourceFileCount, 2)
        XCTAssertEqual(initialProjects.count, 2)
        XCTAssertEqual(initialSessions.count, 2)
        XCTAssertEqual(initialUsage.reduce(0) { $0 + $1.inputTokens }, 30)

        let changed = try await database.synchronizeConfiguredRoots([
            SourceRoot(agent: .claudeCode, url: retained)
        ])

        XCTAssertTrue(changed)
        _ = try await database.rebuildUsageRollupsIfDirty()
        let synchronizedStatistics = try await database.statistics()
        let synchronizedProjects = try await database.projects()
        let synchronizedSessions = try await database.sessions()
        let synchronizedUsage = try await database.usage(
            fromDay: nil, throughDay: nil, includeSidechains: true
        )
        let removedSearch = try await database.search(query: "message 2")
        let retainedSearch = try await database.search(query: "message 1")
        XCTAssertEqual(synchronizedStatistics.sourceFileCount, 1)
        XCTAssertEqual(synchronizedProjects.map(\.displayName), ["Retained"])
        XCTAssertEqual(synchronizedSessions.count, 1)
        XCTAssertEqual(synchronizedUsage.reduce(0) { $0 + $1.inputTokens }, 10)
        XCTAssertTrue(removedSearch.results.isEmpty)
        XCTAssertFalse(retainedSearch.results.isEmpty)
        let reopened = try IndexDatabase(url: url)
        let changedAfterReopen = try await reopened.synchronizeConfiguredRoots([
            SourceRoot(agent: .claudeCode, url: retained)
        ])
        let removedSearchAfterReopen = try await reopened.search(query: "message 2")
        XCTAssertFalse(changedAfterReopen)
        XCTAssertTrue(removedSearchAfterReopen.results.isEmpty)

        try await reopened.saveEventCheckpoints(["volume": 404])
        let readdedRootNeedsScan = try await reopened.synchronizeConfiguredRoots([
            SourceRoot(agent: .claudeCode, url: retained),
            SourceRoot(agent: .claudeCode, url: removed),
        ])
        let checkpointAfterReadding = try await reopened.eventCheckpoint(volumeID: "volume")
        XCTAssertTrue(readdedRootNeedsScan)
        XCTAssertNil(checkpointAfterReadding)
    }

    func testCheckpointOnlyRequestSkipsCoordinatorAndFailedWorkRetriesBeforeLaterWatermark() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let url = root.appendingPathComponent("index.sqlite")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [root])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let progress = RunRecorder()
        let completions = CompletionRecorder()
        let scheduler = IndexScheduler(
            coordinator: coordinator, scope: .proseOnly, retryDelay: .milliseconds(20)
        ) {
            await progress.receive($0)
        } didComplete: { activity, watermarks in
            await completions.receive(activity: activity, watermarks: watermarks)
        }

        await scheduler.request(activity: .fileChanges, watermarks: ["volume": 1])
        await scheduler.waitUntilIdle()
        let checkpointOnlyPhases = await progress.terminalPhases
        let checkpointOnlyCompletions = await completions.values
        XCTAssertTrue(checkpointOnlyPhases.isEmpty)
        XCTAssertEqual(checkpointOnlyCompletions.last?.watermarks["volume"], 1)

        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_incremental_root BEFORE UPDATE OF agent ON source_root
                BEGIN SELECT RAISE(ABORT, 'forced incremental failure'); END
                """)
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        await scheduler.request(
            paths: [file.path], reconciliationPaths: [root.path],
            rebuild: true, scope: .everything, watermarks: ["volume": 2]
        )
        await scheduler.waitUntilIdle()
        let failedPhases = await progress.terminalPhases
        let failedCompletions = await completions.values
        XCTAssertEqual(failedPhases.last, .failed)
        XCTAssertEqual(failedCompletions.last?.watermarks["volume"], 1)

        try await Task.sleep(for: .milliseconds(100))
        await scheduler.waitUntilIdle()
        let automaticallyRetriedPhases = await progress.terminalPhases
        XCTAssertEqual(Array(automaticallyRetriedPhases.suffix(2)), [.failed, .failed])

        await scheduler.request(activity: .fileChanges, watermarks: ["volume": 3])
        await scheduler.waitUntilIdle()
        let secondFailurePhases = await progress.terminalPhases
        let secondFailureCompletions = await completions.values
        XCTAssertEqual(secondFailurePhases, automaticallyRetriedPhases,
                       "watermark-only work must not reactivate a dormant failure")
        XCTAssertEqual(secondFailureCompletions.last?.watermarks["volume"], 1)

        try await Task.sleep(for: .milliseconds(100))
        let phasesAfterSecondFailure = await progress.terminalPhases
        XCTAssertEqual(phasesAfterSecondFailure, secondFailurePhases,
                       "a retained batch must not hot-loop after a second failure")

        try await raw.write { try $0.execute(sql: "DROP TRIGGER fail_incremental_root") }
        await scheduler.request(
            reconcile: true, activity: .safetyVerification,
            watermarks: ["volume": 4]
        )
        await scheduler.waitUntilIdle()
        let retriedPhases = await progress.terminalPhases
        let retriedCompletions = await completions.values
        XCTAssertEqual(Array(retriedPhases.suffix(2)), [.failed, .complete])
        XCTAssertEqual(retriedCompletions.suffix(2).compactMap { $0.watermarks["volume"] }, [1, 4])
        XCTAssertEqual(retriedCompletions.last?.activity, .rebuild)
        let storedScope = try await database.storedIndexScope()
        XCTAssertEqual(storedScope, .everything)
        let retriedSearch = try await database.search(query: "message 2")
        XCTAssertFalse(retriedSearch.results.isEmpty)

        await scheduler.request(activity: .fileChanges, watermarks: ["volume": 5])
        await scheduler.waitUntilIdle()
        let clearedCompletions = await completions.values
        XCTAssertEqual(clearedCompletions.last?.watermarks["volume"], 5)
        let phasesAfterClearedRetry = await progress.terminalPhases
        XCTAssertEqual(phasesAfterClearedRetry, retriedPhases,
                       "successful retry must clear retained operation work")
    }

    func testSchedulerCompletesCheckpointForPassWithDurablyRecordedFileFailures() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let invocation = ReadCounter()
        let source = ThrowAfterIncrementalEOFSource(
            base: ClaudeCodeSource(roots: [root]), invocation: invocation
        )
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        let terminal = ProgressRecorder()
        let completions = CompletionRecorder()
        let scheduler = IndexScheduler(
            coordinator: coordinator, scope: .proseOnly, retryDelay: .milliseconds(20)
        ) {
            terminal.receive($0)
        } didComplete: { activity, watermarks in
            await completions.receive(activity: activity, watermarks: watermarks)
        }

        let healthyRoot = root.deletingLastPathComponent().appendingPathComponent("healthy-root")
        await scheduler.request(
            paths: [file.path], activity: .safetyVerification,
            watermarks: ["failed-volume": 8, "healthy-volume": 9],
            streamRoots: [
                "failed-volume": [root.path],
                "healthy-volume": [healthyRoot.path],
            ]
        )
        await scheduler.waitUntilIdle()

        XCTAssertEqual(terminal.terminal?.phase, .complete)
        XCTAssertEqual(terminal.terminal?.failedFiles, 1)
        XCTAssertEqual(terminal.terminal?.unresolvedFailedFiles, 1)
        try await Task.sleep(for: .milliseconds(100))
        await scheduler.waitUntilIdle()
        var values = await completions.values
        XCTAssertFalse(values.contains { $0.watermarks["failed-volume"] != nil },
                       "the failed stream watermark must remain blocked")
        XCTAssertEqual(values.first(where: { $0.activity == .safetyVerification })?
            .watermarks["healthy-volume"], 9,
        "a completed safety pass must report completion and checkpoint an unaffected volume")

        await scheduler.request(activity: .fileChanges, watermarks: ["later-volume": 10])
        await scheduler.waitUntilIdle()
        values = await completions.values
        XCTAssertEqual(values.last?.watermarks["later-volume"], 10,
                       "an unrelated stream must checkpoint independently")
        let invocationsBeforeStop = invocation.value
        await scheduler.stop()
        await scheduler.request(paths: [file.path], watermarks: ["volume": 9])
        await scheduler.waitUntilIdle()
        XCTAssertEqual(invocation.value, invocationsBeforeStop,
                       "stop must discard retained work and reject later requests")
        let completionsAfterStop = await completions.values
        XCTAssertEqual(completionsAfterStop.count, values.count)
    }

    func testCompletedSafetyPassReportsCompletionWhenItsOnlyWatermarkIsBlocked() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = ThrowAfterIncrementalEOFSource(
            base: ClaudeCodeSource(roots: [root]), invocation: ReadCounter()
        )
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(2).utf8))
        try handle.close()
        let completions = CompletionRecorder()
        let scheduler = IndexScheduler(
            coordinator: coordinator, scope: .proseOnly, retryDelay: .seconds(30),
            progress: { _ in }
        ) { activity, watermarks in
            await completions.receive(activity: activity, watermarks: watermarks)
        }

        await scheduler.request(
            paths: [file.path], activity: .safetyVerification,
            watermarks: ["failed-volume": 12],
            streamRoots: ["failed-volume": [root.path]]
        )
        await scheduler.waitUntilIdle()

        let values = await completions.values
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.activity, .safetyVerification)
        XCTAssertTrue(values.first?.watermarks.isEmpty == true)
        await scheduler.stop()
    }

    func testFailedFileRecoveryDoesNotBlockLaterHealthyFile() async throws {
        let root = try directory()
        let bad = root.appendingPathComponent("bad.jsonl")
        let healthy = root.appendingPathComponent("healthy.jsonl")
        try Data(line(1).utf8).write(to: bad)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = SelectiveReadFailureSource(
            base: ClaudeCodeSource(roots: [root]), failedName: bad.lastPathComponent
        )
        let coordinator = IndexCoordinator(database: database, sources: [source])
        let completions = CompletionRecorder()
        let scheduler = IndexScheduler(
            coordinator: coordinator, scope: .proseOnly, retryDelay: .seconds(30),
            progress: { _ in }
        ) { activity, watermarks in
            await completions.receive(activity: activity, watermarks: watermarks)
        }

        await scheduler.request(paths: [bad.path], watermarks: ["volume": 1])
        await scheduler.waitUntilIdle()
        try Data(line(2).utf8).write(to: healthy)
        await scheduler.request(paths: [healthy.path], watermarks: ["volume": 2])
        await scheduler.waitUntilIdle()

        let search = try await database.search(query: "message 2")
        let values = await completions.values
        XCTAssertFalse(search.results.isEmpty)
        XCTAssertTrue(values.compactMap { $0.watermarks["volume"] }.isEmpty,
                      "the failed volume must remain blocked while healthy work continues")
        await scheduler.stop()
    }

    func testUnreadableScopedDiscoveryPreservesIndexedFilesAndRecordsRootError() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let source = ScopedDiscoveryFailureSource(
            base: ClaudeCodeSource(roots: [root]), invocation: ReadCounter()
        )
        let coordinator = IndexCoordinator(database: database, sources: [source])
        let initial = await coordinator.indexAllResult(scope: .proseOnly)
        XCTAssertEqual(initial.phase, .complete)
        let initialStatistics = try await database.statistics()
        XCTAssertEqual(initialStatistics.sourceFileCount, 1)

        try FileManager.default.removeItem(at: file)
        let reconciliation = await coordinator.reconcile(
            paths: [root.path], scope: .proseOnly, activity: .subtreeRecovery
        )

        XCTAssertEqual(reconciliation.phase, .complete)
        XCTAssertEqual(reconciliation.failedFiles, 1)
        let retainedStatistics = try await database.statistics()
        XCTAssertEqual(retainedStatistics.sourceFileCount, 1)
        let retained = try await database.search(query: "searchable")
        XCTAssertEqual(retained.results.count, 1)
        let health = try await database.sourceHealth()
        XCTAssertTrue(health.first?.error?.contains("synthetic unreadable scope") == true)
    }

    func testSuccessfulSiblingScanDoesNotClearAnotherSubtreeError() async throws {
        let root = try directory()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let sourceRoot = SourceRoot(agent: .claudeCode, url: root)
        let rootID = try await database.register(root: sourceRoot)
        let firstFailure = DiscoveryFailure(
            agent: .claudeCode, root: root, path: first.path, message: "first failed"
        )
        let secondFailure = DiscoveryFailure(
            agent: .claudeCode, root: root, path: second.path, message: "second failed"
        )
        try await database.replaceDiscoveryErrors(
            rootID: rootID, scannedScope: first.path, failures: [firstFailure]
        )
        try await database.replaceDiscoveryErrors(
            rootID: rootID, scannedScope: second.path, failures: [secondFailure]
        )

        try await database.replaceDiscoveryErrors(
            rootID: rootID, scannedScope: first.path, failures: []
        )

        let recovery = try await database.unresolvedRecoveryWork()
        let failureCounts = try await database.unresolvedSourceFailureCounts()
        XCTAssertEqual(recovery.reconciliationPaths, [second.path])
        XCTAssertEqual(failureCounts, .init(fileFailures: 0, discoveryFailures: 1))
    }

    func testDiscoveryErrorReplacementsCommitAsOneTransaction() async throws {
        let parent = try directory()
        let first = parent.appendingPathComponent("first")
        let second = parent.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let databaseURL = parent.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let firstID = try await database.register(root: .init(agent: .claudeCode, url: first))
        let secondID = try await database.register(root: .init(agent: .codex, url: second))
        try await database.replaceDiscoveryErrors([
            (firstID, first.path, [.init(
                agent: .claudeCode, root: first, path: first.path, message: "first"
            )]),
            (secondID, second.path, [.init(
                agent: .codex, root: second, path: second.path, message: "second"
            )]),
        ])
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_second_scan_update BEFORE UPDATE ON source_root
                WHEN old.id = \(secondID)
                BEGIN SELECT RAISE(ABORT, 'forced replacement failure'); END
                """)
        }

        do {
            try await database.replaceDiscoveryErrors([
                (firstID, first.path, []),
                (secondID, second.path, []),
            ])
            XCTFail("expected the second replacement to abort the transaction")
        } catch { }

        let recovery = try await database.unresolvedRecoveryWork()
        XCTAssertEqual(recovery.reconciliationPaths, [first.path, second.path],
                       "the first replacement must roll back with the second")
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
            try db.execute(sql: "DROP INDEX idx_usage_project")
            try db.execute(sql: "DROP INDEX idx_source_error")
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN is_placeholder")
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN content_session_id")
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN metadata_session_id")
            try db.execute(sql: "ALTER TABLE session DROP COLUMN error_revision")
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN content_generation")
            try db.execute(sql: "ALTER TABLE usage_observation DROP COLUMN project_id")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v4-source-generation'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v5-usage-project'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v6-checkpoint-context'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v7-source-placeholders'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v8-fsevents-checkpoints'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v9-reset-fsevents-checkpoints'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v10-scoped-discovery-errors'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v11-remove-redundant-scan-error-index'")
            try db.execute(sql: "DROP TABLE source_scan_error")
            try db.execute(sql: "DROP TABLE fsevents_checkpoint")
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
        XCTAssertEqual(schema, "11")
    }

    func testV7MigrationBackfillsPlaceholdersWithoutChangingIndexedIDs() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let failed = root.appendingPathComponent("failed.jsonl")
        let url = root.appendingPathComponent("index.sqlite")
        try Data(line(1).utf8).write(to: file)
        let database = try IndexDatabase(url: url)
        let source = ClaudeCodeSource(roots: [root])
        await IndexCoordinator(database: database, sources: [source]).indexAll(scope: .proseOnly)
        let sourceID = try await database.sourceState(path: file.path)?.id
        let page = try await database.search(query: "searchable")
        let messageID = page.results.first?.id
        let rootID = try await database.register(root: source.roots[0])
        try await database.recordSourceError(
            file: .init(agent: .claudeCode, root: root, url: failed, format: .claudeJSONL),
            rootID: rootID, error: "synthetic legacy placeholder"
        )
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN is_placeholder")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v7-source-placeholders'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v8-fsevents-checkpoints'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v9-reset-fsevents-checkpoints'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v10-scoped-discovery-errors'")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v11-remove-redundant-scan-error-index'")
            try db.execute(sql: "DROP TABLE source_scan_error")
            try db.execute(sql: "DROP TABLE fsevents_checkpoint")
            try db.execute(sql: "UPDATE trace_meta SET value='6' WHERE key='schema_version'")
        }
        let migrated = try IndexDatabase(url: url)
        XCTAssertFalse(migrated.contentWasResetOnOpen)
        let indexed = try await migrated.sourceState(path: file.path)
        let placeholder = try await migrated.sourceState(path: failed.path)
        let reopenedPage = try await migrated.search(query: "searchable")
        XCTAssertEqual(indexed?.id, sourceID)
        XCTAssertFalse(try XCTUnwrap(indexed).isPlaceholder)
        XCTAssertTrue(try XCTUnwrap(placeholder).isPlaceholder)
        XCTAssertEqual(reopenedPage.results.first?.id, messageID)
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
        let additionalUsage = #"{"type":"assistant","uuid":"two","sessionId":"session","cwd":"/tmp/project","timestamp":1700000001000,"message":{"id":"response-two","model":"claude-sonnet-5","content":"another answer","usage":{"input_tokens":4,"output_tokens":1}}}"# + "\n"
        try handle.write(contentsOf: Data(additionalUsage.utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let changedDeletes = try await raw.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM rollup_audit") }
        XCTAssertEqual(changedDeletes, 1)
    }

    func testNoOpPassAndReopenRepairRollupsAfterDestructiveChanges() async throws {
        let root = try directory()
        var files: [URL] = []
        for (key, tokens) in [("a", 10), ("b", 20), ("c", 30)] {
            let file = root.appendingPathComponent("\(key).jsonl")
            let row = #"{"type":"assistant","uuid":"\#(key)","sessionId":"session-\#(key)","cwd":"/tmp/project","timestamp":1700000000000,"message":{"id":"response-\#(key)","model":"claude-sonnet-5","content":"answer","usage":{"input_tokens":\#(tokens),"output_tokens":1}}}"# + "\n"
            try Data(row.utf8).write(to: file)
            files.append(file)
        }
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)

        let stateB = try await database.sourceState(path: files[1].path)
        let removedB = try XCTUnwrap(stateB)
        try await database.deleteSource(id: removedB.id)
        let empty = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertTrue(empty.isEmpty)
        await coordinator.refresh(paths: [files[0].path], scope: .proseOnly)
        let repaired = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertEqual(repaired.first?.inputTokens, 40)

        let stateC = try await database.sourceState(path: files[2].path)
        let removedC = try XCTUnwrap(stateC)
        try await database.deleteSource(id: removedC.id)
        let reopened = try IndexDatabase(url: url)
        try await reopened.rebuildUsageRollupsIfDirty()
        let onOpen = try await reopened.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertEqual(onOpen.first?.inputTokens, 10)

        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "DELETE FROM trace_meta WHERE key='usage_rollups_dirty'")
            try db.execute(sql: "DELETE FROM usage_daily")
        }
        let legacyMarker = try IndexDatabase(url: url)
        try await legacyMarker.rebuildUsageRollupsIfDirty()
        let legacyRepair = try await legacyMarker.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        XCTAssertEqual(legacyRepair.first?.inputTokens, 10)
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

    func testDiscoveryDistinguishesMissingAndUnreadableRoots() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraceMissing-\(UUID().uuidString)")
        XCTAssertTrue(try ClaudeCodeSource(roots: [missing]).discover().isEmpty)

        let invalid = URL(fileURLWithPath: "/dev/null/session-root")
        XCTAssertThrowsError(try ClaudeCodeSource(roots: [invalid]).discover()) { error in
            guard let sourceError = error as? SessionSourceError,
                  case .unreadableDirectory(let path, _) = sourceError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, invalid.path)
        }
    }

    func testScopedDiscoveryDoesNotTouchUnrelatedUnreadableRoot() throws {
        let healthy = try directory()
        let file = healthy.appendingPathComponent("healthy.jsonl")
        try Data(line(1).utf8).write(to: file)
        let inaccessible = URL(fileURLWithPath: "/dev/null/unrelated-root")
        let source = ClaudeCodeSource(roots: [healthy, inaccessible])

        let result = try source.discoverResult(scopedTo: [healthy.path])

        XCTAssertEqual(result.files.map(\.url.path), [file.path])
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testSourceRootIdentitySurvivesDanglingSymlinkTarget() throws {
        let parent = try directory()
        let target = parent.appendingPathComponent("mounted/source")
        let alias = parent.appendingPathComponent("configured-root")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let root = SourceRoot(agent: .claudeCode, url: alias, isDefault: false)
        let identity = root.id
        let scanPath = root.scanURL.path

        try FileManager.default.removeItem(at: target.deletingLastPathComponent())

        XCTAssertEqual(root.id, identity)
        XCTAssertEqual(root.url.path, alias.path)
        XCTAssertEqual(root.scanURL.path, scanPath)
        XCTAssertEqual(
            TraceFileIO.canonicalPath(scanPath).comparisonKey,
            TraceFileIO.canonicalPath(target.path).comparisonKey
        )
    }

    func testUnmountedSymlinkRootPreservesIndexedContentAndCheckpoint() async throws {
        let parent = try directory()
        let target = parent.appendingPathComponent("mounted/source")
        let alias = parent.appendingPathComponent("configured-root")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(line(1).utf8).write(to: target.appendingPathComponent("session.jsonl"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let database = try IndexDatabase(url: parent.appendingPathComponent("index.sqlite"))
        let source = ClaudeCodeSource(roots: [alias])
        await IndexCoordinator(database: database, sources: [source]).indexAll(scope: .proseOnly)
        try await database.saveEventCheckpoints(["volume": 77])
        let beforeUnmount = try await database.statistics()
        XCTAssertEqual(beforeUnmount.sourceFileCount, 1)

        try FileManager.default.removeItem(at: target.deletingLastPathComponent())
        let changed = try await database.synchronizeConfiguredRoots([
            SourceRoot(agent: .claudeCode, url: alias)
        ])

        XCTAssertFalse(changed)
        let afterUnmount = try await database.statistics()
        let checkpoint = try await database.eventCheckpoint(volumeID: "volume")
        XCTAssertEqual(afterUnmount.sourceFileCount, 1)
        XCTAssertEqual(checkpoint, 77)
    }

    func testDeletedRootDoesNotReuseCachedURLResourceValues() throws {
        let root = try directory()
        _ = try root.resourceValues(forKeys: [.isDirectoryKey])
        try FileManager.default.removeItem(at: root)

        let result = try ClaudeCodeSource(roots: [root]).discoverResult(scopedTo: nil)

        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.kind, .missingRoot)
        XCTAssertEqual(
            result.failures.first.map { TraceFileIO.canonicalPath($0.path).comparisonKey },
            TraceFileIO.canonicalPath(root.path).comparisonKey
        )
    }

    func testNeverSeenMissingDefaultRootStaysQuietAndUnscanned() async throws {
        let parent = try directory()
        let missing = parent.appendingPathComponent("optional-default")
        let database = try IndexDatabase(url: parent.appendingPathComponent("index.sqlite"))
        let terminal = await IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [missing])]
        ).indexAllResult(scope: .proseOnly)

        let health = try await database.sourceHealth()
        let recovery = try await database.unresolvedRecoveryWork()
        XCTAssertEqual(terminal.phase, .complete)
        XCTAssertEqual(terminal.failedFiles, 0)
        XCTAssertNil(health.first?.lastScanMilliseconds)
        XCTAssertNil(health.first?.error)
        XCTAssertEqual(recovery.reconciliationPaths, [])
    }

    func testPreviouslyScannedMissingDefaultRootPreservesContent() async throws {
        let parent = try directory()
        let root = parent.appendingPathComponent("default-root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(line(1).utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let database = try IndexDatabase(url: parent.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [root])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        try FileManager.default.removeItem(at: root)

        let terminal = await coordinator.indexAllResult(scope: .proseOnly)
        let statistics = try await database.statistics()
        let search = try await database.search(query: "searchable")

        XCTAssertEqual(terminal.failedFiles, 1)
        XCTAssertEqual(statistics.sourceFileCount, 1)
        XCTAssertEqual(search.results.count, 1)
    }

    func testWatcherFlagsDistinguishFileChangesFromRecovery() {
        var changes = SourceChanges()
        XCTAssertFalse(changes.hasIndexWork)
        changes.include(
            path: "/unrelated/directory",
            flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified),
            eventID: 1
        )
        XCTAssertFalse(changes.hasIndexWork, "a watermark alone must not request an indexing pass")
        changes.include(path: "/root/rollout.jsonl", flags: UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified))
        changes.include(path: "/root", flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified))
        XCTAssertEqual(changes.paths, ["/root/rollout.jsonl"])
        XCTAssertTrue(changes.hasIndexWork)
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

    func testCanonicalPathResolvesNestedMissingPathThroughSymlinkedAncestor() throws {
        let root = try directory()
        let real = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        TraceFileIO.resetVolumeCaseSensitivityCacheForTesting()
        defer { TraceFileIO.resetVolumeCaseSensitivityCacheForTesting() }

        let direct = TraceFileIO.canonicalPath(
            real.appendingPathComponent("missing/child/session.jsonl").path
        )
        let canonical = TraceFileIO.canonicalPath(
            alias.appendingPathComponent("missing/child/session.jsonl").path
        )
        XCTAssertEqual(
            canonical.path,
            real.resolvingSymlinksInPath()
                .appendingPathComponent("missing/child/session.jsonl").path
        )
        XCTAssertEqual(canonical.comparisonKey, direct.comparisonKey)
        XCTAssertEqual(canonical.isCaseSensitive, direct.isCaseSensitive)
        XCTAssertEqual(TraceFileIO.volumeCaseSensitivityProbeCountForTesting, 1)
    }

    func testCanonicalComparisonKeyCanBeForcedForEitherVolumeBehavior() {
        let path = "/tmp/Trace/Résumé.JSONL"
        XCTAssertEqual(TraceFileIO.comparisonKey(path, caseSensitive: true), path)
        XCTAssertEqual(
            TraceFileIO.comparisonKey(path, caseSensitive: false),
            "/tmp/trace/resume.jsonl"
        )
    }

    func testCanonicalPathProbesCaseSensitivityOncePerVolume() throws {
        let root = try directory()
        TraceFileIO.resetVolumeCaseSensitivityCacheForTesting()
        defer { TraceFileIO.resetVolumeCaseSensitivityCacheForTesting() }

        _ = TraceFileIO.canonicalPath(root.appendingPathComponent("first/missing.jsonl").path)
        _ = TraceFileIO.canonicalPath(root.appendingPathComponent("second/missing.jsonl").path)
        XCTAssertEqual(TraceFileIO.volumeCaseSensitivityProbeCountForTesting, 1)
    }

    func testCaseSensitivityCacheUsesVolumeUUIDAndSkipsUnknownVolumes() {
        TraceFileIO.resetVolumeCaseSensitivityCacheForTesting()
        defer { TraceFileIO.resetVolumeCaseSensitivityCacheForTesting() }
        var firstVolumeProbes = 0
        var secondVolumeProbes = 0
        var unknownVolumeProbes = 0

        XCTAssertTrue(TraceFileIO.cachedVolumeCaseSensitivity(volumeID: "volume-a") {
            firstVolumeProbes += 1
            return true
        })
        XCTAssertTrue(TraceFileIO.cachedVolumeCaseSensitivity(volumeID: "volume-a") {
            firstVolumeProbes += 1
            return false
        })
        XCTAssertFalse(TraceFileIO.cachedVolumeCaseSensitivity(volumeID: "volume-b") {
            secondVolumeProbes += 1
            return false
        })
        XCTAssertTrue(TraceFileIO.cachedVolumeCaseSensitivity(volumeID: nil) {
            unknownVolumeProbes += 1
            return true
        })
        XCTAssertFalse(TraceFileIO.cachedVolumeCaseSensitivity(volumeID: nil) {
            unknownVolumeProbes += 1
            return false
        })

        XCTAssertEqual(firstVolumeProbes, 1)
        XCTAssertEqual(secondVolumeProbes, 1)
        XCTAssertEqual(unknownVolumeProbes, 2)
        XCTAssertEqual(TraceFileIO.volumeCaseSensitivityProbeCountForTesting, 2)
    }

    func testReportedVolumeCaseSensitivityAvoidsPathConfigurationProbe() {
        var pathConfigurationProbes = 0
        let detected = TraceFileIO.probeVolumeCaseSensitivity(resourceValue: false) {
            pathConfigurationProbes += 1
            return 1
        }

        XCTAssertFalse(detected)
        XCTAssertEqual(pathConfigurationProbes, 0)
    }

    func testVolumeCaseSensitivityFallsBackConservativelyWhenMetadataIsMissing() {
        var pathConfigurationProbes = 0
        let detected = TraceFileIO.probeVolumeCaseSensitivity(resourceValue: nil) {
            pathConfigurationProbes += 1
            return -1
        }

        XCTAssertTrue(detected)
        XCTAssertEqual(pathConfigurationProbes, 1)
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
            let page = try await database.search(
                query: "the",
                filters: .init(projectCanonicalKey: project.canonicalKey)
            )
            XCTAssertTrue(page.results.allSatisfy { $0.projectID == project.id })
        }
        let missing = try await database.search(
            query: "the",
            filters: .init(projectCanonicalKey: "missing-project")
        )
        XCTAssertTrue(missing.results.isEmpty)
    }

    func testCanonicalProjectFilterSurvivesNumericIDReuse() async throws {
        let root = try directory()
        let wanted = root.appendingPathComponent("wanted.jsonl")
        try Data(line(1, project: "/tmp/WantedProject").utf8).write(to: wanted)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [ClaudeCodeSource(roots: [root])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let originalProjects = try await database.projects()
        let original = try XCTUnwrap(
            originalProjects.first { $0.displayName == "WantedProject" }
        )

        let decoy = root.appendingPathComponent("000-decoy.jsonl")
        try Data(line(2, project: "/tmp/DecoyProject").utf8).write(to: decoy)
        await coordinator.indexAll(scope: .proseOnly, rebuild: true)
        let rebuiltProjects = try await database.projects()
        let rebuilt = try XCTUnwrap(
            rebuiltProjects.first { $0.canonicalKey == original.canonicalKey }
        )
        let replacement = try XCTUnwrap(
            rebuiltProjects.first { $0.displayName == "DecoyProject" }
        )
        XCTAssertEqual(replacement.id, original.id)
        XCTAssertNotEqual(rebuilt.id, original.id)

        for sort in [SearchSort.recency, .relevance] {
            let page = try await database.search(
                query: "searchable",
                filters: .init(projectCanonicalKey: original.canonicalKey),
                sort: sort
            )
            XCTAssertFalse(page.results.isEmpty)
            XCTAssertTrue(page.results.allSatisfy { $0.projectName == "WantedProject" })
            XCTAssertTrue(page.results.allSatisfy {
                $0.projectCanonicalKey == original.canonicalKey
            })
        }

        let missing = try await database.search(
            query: "searchable",
            filters: .init(projectCanonicalKey: "missing-project")
        )
        XCTAssertTrue(missing.results.isEmpty)
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
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialSessionID: String?) -> AsyncThrowingStream<ParsedRecord, Error> {
        counter.increment()
        return base.records(in: file, from: offset, through: boundary, initialSessionID: initialSessionID)
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
        records(in: file, from: offset, through: boundary, initialSessionID: nil)
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let source = base.records(in: file, from: offset, through: boundary, initialSessionID: initialSessionID)
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

private struct SelectiveReadFailureSource: SessionSource {
    let base: ClaudeCodeSource
    let failedName: String
    var agent: AgentKind { base.agent }
    var roots: [SourceRoot] { base.roots }

    func discover() throws -> [DiscoveredSourceFile] { try base.discover() }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary, initialSessionID: nil)
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        guard file.url.lastPathComponent == failedName else {
            return base.records(
                in: file, from: offset, through: boundary,
                initialSessionID: initialSessionID
            )
        }
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: SessionSourceError.malformedRecord(
                "synthetic permanent failure"
            ))
        }
    }

    func hydrate(
        fileURL: URL, format: SourceFormat, locator: RecordLocator
    ) throws -> HydratedMessage {
        try base.hydrate(fileURL: fileURL, format: format, locator: locator)
    }
}

private struct ScopedDiscoveryFailureSource: SessionSource {
    let base: ClaudeCodeSource
    let invocation: ReadCounter
    var agent: AgentKind { base.agent }
    var roots: [SourceRoot] { base.roots }

    func discover() throws -> [DiscoveredSourceFile] { try base.discover() }

    func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile] {
        guard invocation.nextInvocation() > 1 else {
            return try base.discover(scopedTo: paths)
        }
        throw SessionSourceError.unreadableDirectory(
            paths.sorted().first ?? "unknown", "synthetic unreadable scope"
        )
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        base.records(in: file, from: offset, through: boundary)
    }

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        base.records(
            in: file, from: offset, through: boundary, initialSessionID: initialSessionID
        )
    }

    func hydrate(
        fileURL: URL, format: SourceFormat, locator: RecordLocator
    ) throws -> HydratedMessage {
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
        records(in: discovered, from: offset, through: boundary, initialSessionID: nil)
    }

    func records(
        in discovered: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        let number = invocation.nextInvocation()
        guard number == 2 else {
            return base.records(in: discovered, from: offset, through: boundary, initialSessionID: initialSessionID)
        }
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

    func records(
        in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
        initialSessionID: String?
    ) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary)
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

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTerminal: IndexProgress?
    func receive(_ update: IndexProgress) {
        guard [.complete, .cancelled, .failed].contains(update.phase) else { return }
        lock.withLock { lastTerminal = update }
    }
    var terminal: IndexProgress? { lock.withLock { lastTerminal } }
}

private actor RunRecorder {
    var terminalPhases: [IndexProgress.Phase] = []
    func receive(_ progress: IndexProgress) {
        if [.complete, .cancelled, .failed].contains(progress.phase) { terminalPhases.append(progress.phase) }
    }
}

private actor CompletionRecorder {
    struct Entry: Sendable {
        let activity: IndexActivity
        let watermarks: [String: UInt64]
    }

    private(set) var values: [Entry] = []

    func receive(activity: IndexActivity, watermarks: [String: UInt64]) {
        values.append(.init(activity: activity, watermarks: watermarks))
    }
}
