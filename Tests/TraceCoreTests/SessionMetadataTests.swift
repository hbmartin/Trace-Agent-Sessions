import Foundation
import GRDB
import XCTest
@testable import TraceCore

final class SessionMetadataTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TraceMetadata-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ objects: [[String: Any]], to url: URL) throws {
        var data = Data()
        for object in objects { data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10) }
        try data.write(to: url)
    }

    private func message(_ type: String, _ text: String, id: String) -> [String: Any] {
        ["type": type, "uuid": id, "sessionId": "session", "cwd": "/tmp/metadata",
         "timestamp": "2026-09-14T10:00:00Z", "message": ["content": text]]
    }

    private func codexRollout(id: String) -> [[String: Any]] {
        [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Request for \(id)"]],
            ]],
        ]
    }

    private func appendCodexPlan(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            #"{"type":"response_item","payload":{"type":"plan","text":"Changed"}}"#.utf8
        ) + Data([10]))
    }

    func testClaudeTitlesPlansAndUnchangedSourceBackfillPreserveIDs() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let objects = [message("user", "<environment_context>injected</environment_context>", id: "context"),
                       message("user", "First real request", id: "request"),
                       message("assistant", "<proposed_plan>\nImplement the requested change.\n</proposed_plan>", id: "plan"),
                       ["type": "summary", "summary": "Generated summary"],
                       ["type": "custom-title", "customTitle": "Chosen title"]]
        try write(objects, to: file)
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .everything)
        let sessions = try await database.sessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.title, "Chosen title")
        XCTAssertTrue(session.hasPlan)
        let originalMessages = try await database.messages(sessionID: session.id)
        let originalState = try await database.sourceState(agent: .claudeCode, path: file.path)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT first_user_message FROM session"), "First real request")
            // Emulate an interrupted metadata backfill. Content/checkpoints stay intact.
            try db.execute(sql: "UPDATE source_file SET metadata_revision='1:0:0'")
            try db.execute(sql: "UPDATE session SET title='Adapter fallback', has_plan=0")
        }
        await coordinator.indexAll(scope: .everything)
        let refreshed = try await database.session(id: session.id)
        let refreshedMessages = try await database.messages(sessionID: session.id)
        let refreshedState = try await database.sourceState(agent: .claudeCode, path: file.path)
        XCTAssertEqual(refreshed?.title, "Chosen title")
        XCTAssertEqual(refreshed?.hasPlan, true)
        let adapterTitle = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM session")
        }
        XCTAssertEqual(adapterTitle, "Adapter fallback")
        XCTAssertEqual(refreshedMessages.map(\.id), originalMessages.map(\.id))
        XCTAssertEqual(refreshedState?.scannedBytes, originalState?.scannedBytes)
        let results = try await database.search(query: "request", filters: .init(), sort: .recency)
        XCTAssertEqual(results.results.first?.sessionTitle, "Chosen title")
        XCTAssertEqual(results.results.first?.sessionHasPlan, true)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"custom-title\",\"customTitle\":\"Renamed session\"}\n".utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .everything)
        let renamed = try await database.session(id: session.id)
        XCTAssertEqual(renamed?.title, "Renamed session")
        let afterRename = try await database.messages(sessionID: session.id)
        XCTAssertEqual(afterRename.map(\.id), originalMessages.map(\.id))
    }

    func testCodexSidecarPrecedenceAndTitleOnlyRefresh() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-test.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "codex-one", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fallback request"]]]]
        ], to: file)
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "codex-one", "thread_name": "New index title", "updated_at": "2026-09-14"],
                   ["id": "codex-one", "thread_name": "Old index title", "updated_at": "2026-09-13"]], to: sidecar)
        let external = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try await external.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('codex-one', 'App title', 'Database title')")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let initial = try await database.sessions()
        let session = try XCTUnwrap(initial.first)
        XCTAssertEqual(session.title, "App title")
        XCTAssertFalse(session.hasPlan)
        try await external.write { try $0.execute(sql: "UPDATE threads SET name='Unobserved database title'") }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"plan\",\"text\":\"A structured plan\"}}\n".utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)
        let plannedSession = try await database.session(id: session.id)
        XCTAssertEqual(plannedSession?.hasPlan, true)
        XCTAssertEqual(plannedSession?.title, "App title", "ordinary rollout appends must not reload Codex names")
        try await external.write { try $0.execute(sql: "UPDATE threads SET name=NULL") }
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let indexed = try await database.session(id: session.id)
        XCTAssertEqual(indexed?.title, "New index title")
        try Data("malformed\n".utf8).write(to: sidecar)
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let titled = try await database.session(id: session.id)
        XCTAssertEqual(titled?.title, "Database title")
        try await external.write { try $0.execute(sql: "UPDATE threads SET title=NULL") }
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let fallback = try await database.session(id: session.id)
        XCTAssertEqual(fallback?.title, "Fallback request")

        try await external.write {
            try $0.execute(sql: "UPDATE threads SET title='Persisted database title'")
        }
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let persisted = try await database.session(id: session.id)
        XCTAssertEqual(persisted?.title, "Persisted database title")

        try Data("not a database".utf8).write(to: root.appendingPathComponent("state_6.sqlite"))
        let warning = MetadataWarningRecorder()
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly) {
            warning.receive($0)
        }
        let newestUnreadable = try await database.session(id: session.id)
        XCTAssertEqual(newestUnreadable?.title, "Persisted database title")
        XCTAssertNotNil(warning.terminal?.metadataWarning)

        try FileManager.default.removeItem(at: root.appendingPathComponent("state_6.sqlite"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("state_5.sqlite"))
        try FileManager.default.removeItem(at: sidecar)
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let providersAbsent = try await database.session(id: session.id)
        XCTAssertEqual(providersAbsent?.title, "Fallback request")
    }

    func testMissingCodexMetadataDirectoryIsAbsentWithoutWarning() async throws {
        let root = try directory().appendingPathComponent("missing/.codex/sessions")
        let database = try IndexDatabase(
            url: root.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("trace.sqlite")
        )
        let recorder = MetadataWarningRecorder()

        let terminal = await IndexCoordinator(
            database: database, sources: [CodexSource(root: root)]
        ).indexAllResult(scope: .proseOnly) { recorder.receive($0) }

        XCTAssertEqual(terminal.phase, .complete)
        XCTAssertNil(recorder.terminal?.metadataWarning)
    }

    func testMissingCodexRootPreservesStoredTitleAndProvenance() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write(codexRollout(id: "missing-root"),
                  to: sessions.appendingPathComponent("rollout-missing.jsonl"))
        try write([["id": "missing-root", "thread_name": "Keep this title"]],
                  to: home.appendingPathComponent("session_index.jsonl"))
        let databaseURL = parent.appendingPathComponent("trace.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: databaseURL.path)
        let before = try await raw.read { db -> (String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT generated_title, codex_name_origin FROM session"))
            return (row["generated_title"], row["codex_name_origin"])
        }
        try FileManager.default.removeItem(at: home)
        _ = await coordinator.indexAllResult(scope: .proseOnly)
        let after = try await raw.read { db -> (String?, String?, Int) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT generated_title, codex_name_origin FROM session"))
            return (row["generated_title"], row["codex_name_origin"],
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM session") ?? 0)
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, 1)
    }

    func testMissingSessionsRootKeepsTitlesDuringMetadataAndSafetyRefreshes() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write(codexRollout(id: "retained-title"),
                  to: sessions.appendingPathComponent("rollout-retained.jsonl"))
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try write([["id": "retained-title", "thread_name": "Keep this title"]], to: sidecar)
        let databaseURL = parent.appendingPathComponent("trace.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: databaseURL.path)
        let before = try await raw.read { db -> (String?, String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT generated_title, codex_name_origin, codex_applied_name FROM session
                """))
            return (row["generated_title"], row["codex_name_origin"], row["codex_applied_name"])
        }
        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.removeItem(at: sidecar)
        _ = await coordinator.reconcile(
            paths: [sessions.path], scope: .proseOnly, activity: .rootRecovery
        )
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        // A directory reappearing does not prove its old scan failure is resolved.
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        _ = await coordinator.reconcile(
            paths: [parent.appendingPathComponent("unrelated").path],
            scope: .proseOnly, activity: .safetyVerification
        )
        let after = try await raw.read { db -> (String?, String?, String?, Int) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT generated_title, codex_name_origin, codex_applied_name FROM session
                """))
            return (row["generated_title"], row["codex_name_origin"],
                    row["codex_applied_name"],
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM session") ?? 0)
        }
        XCTAssertEqual(after.0, before.0)
        XCTAssertEqual(after.1, before.1)
        XCTAssertEqual(after.2, before.2)
        XCTAssertEqual(after.3, 1)
    }

    func testAvailableCodexHomeWithoutSidecarsRemovesStoredTitle() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write(codexRollout(id: "removed-sidecar"),
                  to: sessions.appendingPathComponent("rollout-removed.jsonl"))
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try write([["id": "removed-sidecar", "thread_name": "Temporary title"]], to: sidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "Temporary title")
        try FileManager.default.removeItem(at: sidecar)
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let removedTitle = try await database.sessions().first?.title
        XCTAssertEqual(removedTitle, "Request for removed-sidecar")
    }

    func testCodexWarningsSurviveUnrelatedPassesAndClearPerRoot() async throws {
        let parent = try directory()
        let first = parent.appendingPathComponent("first/sessions")
        let second = parent.appendingPathComponent("second/sessions")
        let claude = parent.appendingPathComponent("claude")
        let gemini = parent.appendingPathComponent("gemini")
        for root in [first, second, claude, gemini] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let firstState = first.deletingLastPathComponent().appendingPathComponent("state_1.sqlite")
        let secondState = second.deletingLastPathComponent().appendingPathComponent("state_1.sqlite")
        try Data("not a database".utf8).write(to: firstState)
        try Data("not a database".utf8).write(to: secondState)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [
            CodexSource(roots: [first, second]), ClaudeCodeSource(roots: [claude]),
            GeminiSource(root: gemini),
        ])
        let initial = await coordinator.indexAllResult(scope: .proseOnly)
        let initialWarning = try XCTUnwrap(initial.metadataWarning)
        XCTAssertTrue(initialWarning.contains(first.deletingLastPathComponent().path))
        XCTAssertTrue(initialWarning.contains(second.deletingLastPathComponent().path))

        let claudeFile = claude.appendingPathComponent("session.jsonl")
        try write([message("user", "Unrelated request", id: "claude-request")], to: claudeFile)
        let unrelated = await coordinator.refreshResult(paths: [claudeFile.path], scope: .proseOnly)
        XCTAssertEqual(unrelated.metadataWarning, initialWarning)
        let claudeRecovery = await coordinator.reconcile(
            paths: [claude.path], scope: .proseOnly, activity: .rootRecovery
        )
        XCTAssertEqual(claudeRecovery.metadataWarning, initialWarning)
        let geminiRecovery = await coordinator.reconcile(
            paths: [gemini.path], scope: .proseOnly, activity: .rootRecovery
        )
        XCTAssertEqual(geminiRecovery.metadataWarning, initialWarning)

        try FileManager.default.removeItem(at: firstState)
        let firstRecovered = await coordinator.refreshResult(paths: [firstState.path], scope: .proseOnly)
        XCTAssertFalse(firstRecovered.metadataWarning?.contains(first.deletingLastPathComponent().path) ?? true)
        XCTAssertTrue(firstRecovered.metadataWarning?.contains(second.deletingLastPathComponent().path) == true)
        try FileManager.default.removeItem(at: secondState)
        let allRecovered = await coordinator.refreshResult(paths: [secondState.path], scope: .proseOnly)
        XCTAssertNil(allRecovered.metadataWarning)
    }

    func testCompleteRootRefreshClearsSupersededLookupWarning() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-warning.jsonl")
        try write(codexRollout(id: "warning-id"), to: rollout)
        let brokenState = home.appendingPathComponent("state_1.sqlite")
        try Data("not a database".utf8).write(to: brokenState)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        let initial = await coordinator.indexAllResult(scope: .proseOnly)
        XCTAssertTrue(initial.metadataWarning?.contains("state_1.sqlite") == true)

        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"plan\",\"text\":\"Changed\"}}\n".utf8))
        try handle.close()
        await database.failCodexTitleLookupOnceForTesting()
        let failedLookup = await coordinator.refreshResult(paths: [rollout.path], scope: .proseOnly)
        XCTAssertTrue(failedLookup.metadataWarning?.contains("state_1.sqlite") == true)
        XCTAssertTrue(failedLookup.metadataWarning?.contains("synthetic Codex title lookup failure") == true)

        try FileManager.default.removeItem(at: brokenState)
        let metadataRecovered = await coordinator.refreshResult(paths: [brokenState.path], scope: .proseOnly)
        XCTAssertNil(metadataRecovered.metadataWarning)
        let secondHandle = try FileHandle(forWritingTo: rollout)
        try secondHandle.seekToEnd()
        try secondHandle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"plan\",\"text\":\"Changed again\"}}\n".utf8))
        try secondHandle.close()
        let lookupRecovered = await coordinator.refreshResult(paths: [rollout.path], scope: .proseOnly)
        XCTAssertNil(lookupRecovered.metadataWarning)
    }

    func testCodexLookupWarningsStayWithTheirSourceAndRebuildClearsThem() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let first = sessions.appendingPathComponent("rollout-first.jsonl")
        let second = sessions.appendingPathComponent("rollout-second.jsonl")
        try write(codexRollout(id: "first"), to: first)
        try write(codexRollout(id: "second"), to: second)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)

        await database.failCodexTitleLookupOnceForTesting()
        try appendCodexPlan(to: first)
        let failed = await coordinator.refreshResult(paths: [first.path], scope: .proseOnly)
        XCTAssertTrue(failed.metadataWarning?.contains("synthetic Codex title lookup failure") == true)

        await database.failCodexTitleLookupOnceForTesting()
        try appendCodexPlan(to: second)
        let secondFailure = await coordinator.refreshResult(paths: [second.path], scope: .proseOnly)
        XCTAssertTrue(secondFailure.metadataWarning?.contains("synthetic Codex title lookup failure") == true)

        try appendCodexPlan(to: second)
        let secondRecovered = await coordinator.refreshResult(paths: [second.path], scope: .proseOnly)
        XCTAssertTrue(secondRecovered.metadataWarning?.contains("synthetic Codex title lookup failure") == true,
            "recovering the second file must retain the first file's warning")
        try appendCodexPlan(to: first)
        let firstRecovered = await coordinator.refreshResult(paths: [first.path], scope: .proseOnly)
        XCTAssertNil(firstRecovered.metadataWarning)

        await database.failCodexTitleLookupOnceForTesting()
        try appendCodexPlan(to: first)
        let failureBeforeRebuild = await coordinator.refreshResult(paths: [first.path], scope: .proseOnly)
        XCTAssertTrue(failureBeforeRebuild.metadataWarning?.contains("synthetic Codex title lookup failure") == true)

        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "first", "thread_name": "First name"],
                   ["id": "second", "thread_name": "Second name"]], to: sidecar)
        let rebuilt = await coordinator.indexAllResult(scope: .proseOnly, rebuild: true)
        XCTAssertNil(rebuilt.metadataWarning)
        let rebuiltTitles = Set(try await database.sessions().map(\.title))
        XCTAssertEqual(rebuiltTitles, ["First name", "Second name"])
    }

    func testFileTitleWriteDoesNotClearFailedRootWrite() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let first = sessions.appendingPathComponent("rollout-first.jsonl")
        let second = sessions.appendingPathComponent("rollout-second.jsonl")
        try write(codexRollout(id: "first"), to: first)
        try write(codexRollout(id: "second"), to: second)
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)

        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "first", "thread_name": "First name"],
                   ["id": "second", "thread_name": "Second name"]], to: sidecar)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_root_title BEFORE UPDATE OF generated_title ON session
                WHEN NEW.generated_title='First name'
                BEGIN SELECT RAISE(ABORT, 'root title write failed'); END
                """)
        }
        let failed = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertTrue(failed.metadataWarning?.contains("root title write failed") == true)
        try await raw.write { db in try db.execute(sql: "DROP TRIGGER reject_root_title") }

        try appendCodexPlan(to: second)
        let fileSuccess = await coordinator.refreshResult(paths: [second.path], scope: .proseOnly)
        XCTAssertTrue(fileSuccess.metadataWarning?.contains("root title write failed") == true)
        let recovered = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNil(recovered.metadataWarning)
    }

    func testSymlinkedCodexHomeLoadsNames() throws {
        let parent = try directory()
        let actual = parent.appendingPathComponent("actual-codex")
        let alias = parent.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try write([["id": "symlink-session", "thread_name": "Symlink title"]],
                  to: actual.appendingPathComponent("session_index.jsonl"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)

        let result = try CodexSessionNames.load(directory: alias)
        guard case .loaded(let loaded) = result else {
            return XCTFail("Expected names from the symlinked Codex home")
        }
        XCTAssertEqual(loaded.names["symlink-session"]?.value, "Symlink title")
        XCTAssertTrue(loaded.complete)
        XCTAssertNil(loaded.warning)
    }

    func testUnreadableCodexIndexStillLoadsStateDatabase() async throws {
        let root = try directory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("session_index.jsonl"),
            withIntermediateDirectories: true
        )
        let state = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try await state.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('database-session', 'Database title', NULL)")
        }

        let result = try CodexSessionNames.load(directory: root)
        guard case .loaded(let loaded) = result else {
            return XCTFail("Expected the readable state database to supply names")
        }
        XCTAssertEqual(loaded.names["database-session"]?.value, "Database title")
        XCTAssertFalse(loaded.complete)
        XCTAssertTrue(loaded.fillOnlyOrigins.contains(
            CodexNameOrigin(directory: root, provider: .stateTitle)
        ))
        XCTAssertNotNil(loaded.warning)
    }

    func testUnreadableIndexDoesNotPromoteLowerPriorityStateTitle() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write([
            ["type": "session_meta", "payload": ["id": "index-owned", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback"]]]],
        ], to: sessions.appendingPathComponent("rollout-index-owned.jsonl"))
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "index-owned", "thread_name": "Index name"]], to: sidecar)
        let state = try DatabaseQueue(path: root.appendingPathComponent("state_1.sqlite").path)
        try await state.write {
            try $0.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try $0.execute(sql: "INSERT INTO threads VALUES ('index-owned', NULL, 'State title')")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "Index name")

        try FileManager.default.removeItem(at: sidecar)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let terminal = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNotNil(terminal.metadataWarning)
        let preservedTitle = try await database.sessions().first?.title
        XCTAssertEqual(preservedTitle, "Index name")
    }

    func testUnreadableIndexFillsNewStateTitleWithoutReplacingExistingTitle() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for id in ["new-title", "existing-title"] {
            try write(codexRollout(id: id),
                      to: sessions.appendingPathComponent("rollout-\(id).jsonl"))
        }
        let databaseURL = root.appendingPathComponent("trace.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE session SET generated_title='Keep existing' WHERE external_id='existing-title'")
        }
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        let state = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try await state.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('new-title', NULL, 'New state title')")
            try db.execute(sql: "INSERT INTO threads VALUES ('existing-title', NULL, 'Do not replace')")
        }
        let result = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNotNil(result.metadataWarning)
        let titles = try await raw.read { db in
            try Row.fetchAll(db, sql: "SELECT external_id, generated_title FROM session")
                .reduce(into: [String: String]()) { values, row in
                    values[row["external_id"] as String] = row["generated_title"]
                }
        }
        XCTAssertEqual(titles["new-title"], "New state title")
        XCTAssertEqual(titles["existing-title"], "Keep existing")
    }

    func testPartialMetadataPromotesRecoveredIndexTitleOverSameHomeStateTitle() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write(codexRollout(id: "promote-index"),
                  to: sessions.appendingPathComponent("rollout-promote.jsonl"))
        let state = try DatabaseQueue(path: root.appendingPathComponent("state_1.sqlite").path)
        try await state.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('promote-index', NULL, 'State title')")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "State title")

        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "promote-index", "thread_name": "Recovered index title"]], to: sidecar)
        try Data("not a database".utf8).write(to: root.appendingPathComponent("state_99.sqlite"))
        let result = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNotNil(result.metadataWarning)
        let stored = try await DatabaseQueue(path: root.appendingPathComponent("trace.sqlite").path).read {
            db -> (String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT generated_title, codex_name_origin FROM session"))
            return (row["generated_title"], row["codex_name_origin"])
        }
        XCTAssertEqual(stored.0, "Recovered index title")
        XCTAssertEqual(stored.1, CodexNameOrigin(directory: root, provider: .sessionIndex).storedValue)
    }

    func testCodexCancellationDoesNotBecomeMetadataWarning() async throws {
        let root = try directory()
        let cancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try CodexSessionNames.load(directory: root)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(cancelled)
    }

    func testUnavailableCodexMetadataIsCachedAcrossFileBursts() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(
            at: sessions, withIntermediateDirectories: true
        )
        let rollout = sessions.appendingPathComponent("rollout-cached.jsonl")
        try write([
            ["type": "session_meta", "payload": [
                "id": "cached-metadata", "cwd": "/tmp/codex",
            ]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback title"]],
            ]],
        ], to: rollout)
        let sidecar = root.appendingPathComponent("state_9.sqlite")
        try Data("not a database".utf8).write(to: sidecar)
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(root: sessions)]
        )
        let initial = await coordinator.indexAllResult(scope: .proseOnly)
        XCTAssertNotNil(initial.metadataWarning)

        try FileManager.default.removeItem(at: sidecar)
        let repaired = try DatabaseQueue(path: sidecar.path)
        try await repaired.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: """
                INSERT INTO threads VALUES ('cached-metadata', 'Repaired title', NULL)
                """)
        }
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Changed"}]}}

            """.utf8))
        try handle.close()
        let burst = MetadataWarningRecorder()

        await coordinator.refresh(paths: [rollout.path], scope: .proseOnly) {
            burst.receive($0)
        }

        XCTAssertNotNil(
            burst.terminal?.metadataWarning,
            "an unavailable result should be reused during a burst instead of reopening metadata"
        )
        let cachedTitle = try await database.sessions().first?.title
        XCTAssertEqual(cachedTitle, "Fallback title")

        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let repairedTitle = try await database.sessions().first?.title
        XCTAssertEqual(repairedTitle, "Repaired title")
    }

    func testCodexPartialDatabaseFailureRenamesIndexOwnedTitlesAndFillsMissing() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (id, fallback) in [("partial-one", "First fallback"), ("partial-two", "Second fallback")] {
            try write([
                ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/codex"]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": fallback]],
                ]],
            ], to: sessions.appendingPathComponent("rollout-\(id).jsonl"))
        }
        try write([
            ["id": "partial-one", "thread_name": "Initial one"],
            ["id": "partial-two", "thread_name": "Initial two"],
        ], to: root.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(root: sessions)]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: root.appendingPathComponent("trace.sqlite").path)
        try await raw.write {
            try $0.execute(sql: "UPDATE session SET generated_title=NULL WHERE external_id='partial-two'")
        }
        try write([
            ["id": "partial-one", "thread_name": "Updated from index"],
            ["id": "partial-two", "thread_name": "Filled from index"],
        ], to: root.appendingPathComponent("session_index.jsonl"))
        try Data("not a database".utf8).write(
            to: root.appendingPathComponent("state_99.sqlite")
        )
        let recorder = MetadataWarningRecorder()

        await coordinator.refresh(
            paths: [root.appendingPathComponent("session_index.jsonl").path],
            scope: .proseOnly
        ) { recorder.receive($0) }

        let titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(
            titles[sessions.appendingPathComponent("rollout-partial-one.jsonl").path],
            "Updated from index"
        )
        XCTAssertEqual(
            titles[sessions.appendingPathComponent("rollout-partial-two.jsonl").path],
            "Filled from index"
        )
        XCTAssertNotNil(recorder.terminal?.metadataWarning)
    }

    func testPartialCodexMetadataPreservesLegacyTitleUntilCompleteRead() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try write([
            ["type": "session_meta", "payload": ["id": "legacy-name", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback request"]],
            ]],
        ], to: sessions.appendingPathComponent("rollout-legacy-name.jsonl"))
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "legacy-name", "thread_name": "Original name"]], to: sidecar)
        let databaseURL = root.appendingPathComponent("trace.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: """
                UPDATE session SET codex_name_origin=NULL, codex_applied_name=NULL
                WHERE external_id='legacy-name'
                """)
        }

        try write([["id": "legacy-name", "thread_name": "Updated name"]], to: sidecar)
        try Data("not a database".utf8).write(to: root.appendingPathComponent("state_99.sqlite"))
        let result = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNotNil(result.metadataWarning)
        XCTAssertTrue(result.metadataWarning?.contains("1 legacy Codex title rename(s) deferred") == true)
        let stored = try await raw.read { db -> (String?, String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT generated_title, codex_name_origin, codex_applied_name
                FROM session WHERE external_id='legacy-name'
                """))
            return (row["generated_title"], row["codex_name_origin"], row["codex_applied_name"])
        }
        let indexOrigin = CodexNameOrigin(directory: root, provider: .sessionIndex)
        XCTAssertEqual(stored.0, "Original name")
        XCTAssertNil(stored.1)
        XCTAssertNil(stored.2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("state_99.sqlite"))
        let recovered = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNil(recovered.metadataWarning)
        let complete = try await raw.read { db -> (String?, String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT generated_title, codex_name_origin, codex_applied_name
                FROM session WHERE external_id='legacy-name'
                """))
            return (row["generated_title"], row["codex_name_origin"], row["codex_applied_name"])
        }
        XCTAssertEqual(complete.0, "Updated name")
        XCTAssertEqual(complete.1, indexOrigin.storedValue)
        XCTAssertEqual(complete.2, "Updated name")

        try await raw.write { db in
            try db.execute(sql: """
                UPDATE session SET generated_title='Legacy inherited',
                    codex_name_origin=NULL, codex_applied_name=NULL
                WHERE external_id='legacy-name'
                """)
        }
        let changed = try await database.updateCodexNames(
            ["legacy-name": CodexName(value: "Inherited change", origin: indexOrigin)],
            root: sessions, policy: .partial,
            fillOnlyOrigins: [indexOrigin]
        )
        XCTAssertFalse(changed)
        let preserved = try await raw.read { db -> (String?, String?, String?) in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: """
                SELECT generated_title, codex_name_origin, codex_applied_name
                FROM session WHERE external_id='legacy-name'
                """))
            return (row["generated_title"], row["codex_name_origin"], row["codex_applied_name"])
        }
        XCTAssertEqual(preserved.0, "Legacy inherited")
        XCTAssertNil(preserved.1)
        XCTAssertNil(preserved.2)
    }

    func testCodexRootLocalMetadataOverridesDefaultAndSecondSidecarRefreshes() async throws {
        let parent = try directory()
        let defaultHome = parent.appendingPathComponent("default")
        let localHome = parent.appendingPathComponent("local")
        let defaultSessions = defaultHome.appendingPathComponent("sessions")
        let localSessions = localHome.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(
            at: defaultSessions, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: localSessions, withIntermediateDirectories: true
        )
        for sessions in [defaultSessions, localSessions] {
            try write([
                ["type": "session_meta", "payload": [
                    "id": "shared-id", "cwd": "/tmp/codex",
                ]],
                ["type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Fallback"]],
                ]],
            ], to: sessions.appendingPathComponent("rollout-shared.jsonl"))
        }
        try write([
            ["id": "shared-id", "thread_name": "Default title"],
        ], to: defaultHome.appendingPathComponent("session_index.jsonl"))
        let localSidecar = localHome.appendingPathComponent("session_index.jsonl")
        try write([
            ["id": "shared-id", "thread_name": "Local title"],
        ], to: localSidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database,
            sources: [CodexSource(roots: [defaultSessions, localSessions])]
        )

        await coordinator.indexAll(scope: .proseOnly)
        var titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(
            titles[defaultSessions.appendingPathComponent("rollout-shared.jsonl").path],
            "Default title"
        )
        XCTAssertEqual(
            titles[localSessions.appendingPathComponent("rollout-shared.jsonl").path],
            "Local title"
        )

        try write([
            ["id": "shared-id", "thread_name": "Updated local title"],
        ], to: localSidecar)
        await coordinator.refresh(paths: [localSidecar.path], scope: .proseOnly)
        titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(
            titles[defaultSessions.appendingPathComponent("rollout-shared.jsonl").path],
            "Default title"
        )
        XCTAssertEqual(
            titles[localSessions.appendingPathComponent("rollout-shared.jsonl").path],
            "Updated local title"
        )
    }

    func testSeparateCodexRootWithoutMetadataDoesNotBorrowDefaultNames() async throws {
        let parent = try directory()
        let defaultHome = parent.appendingPathComponent("default")
        let otherHome = parent.appendingPathComponent("other")
        let defaultSessions = defaultHome.appendingPathComponent("sessions")
        let otherSessions = otherHome.appendingPathComponent("sessions")
        for sessions in [defaultSessions, otherSessions] {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try write([
                ["type": "session_meta", "payload": ["id": "shared-id", "cwd": "/tmp/codex"]],
                ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Local fallback"]]]],
            ], to: sessions.appendingPathComponent("rollout-shared.jsonl"))
        }
        try write([["id": "shared-id", "thread_name": "Default-only title"]],
                  to: defaultHome.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, otherSessions])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        var titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(titles[defaultSessions.appendingPathComponent("rollout-shared.jsonl").path],
                       "Default-only title")
        XCTAssertEqual(titles[otherSessions.appendingPathComponent("rollout-shared.jsonl").path],
                       "Local fallback")

        // A prior build could have borrowed this name from the default home.
        let raw = try DatabaseQueue(path: parent.appendingPathComponent("trace.sqlite").path)
        try await raw.write {
            try $0.execute(sql: "UPDATE session SET generated_title='Legacy borrowed title' WHERE source_file_id IN (SELECT id FROM source_file WHERE path=?)",
                           arguments: [otherSessions.appendingPathComponent("rollout-shared.jsonl").path])
        }
        await coordinator.reconcile(paths: [otherSessions.path], scope: .proseOnly,
                                    activity: .rootRecovery)
        titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(titles[otherSessions.appendingPathComponent("rollout-shared.jsonl").path],
                       "Local fallback")

        let unreadable = otherHome.appendingPathComponent("state_9.sqlite")
        try Data("not a database".utf8).write(to: unreadable)
        await coordinator.refresh(paths: [unreadable.path], scope: .proseOnly)
        titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(titles[otherSessions.appendingPathComponent("rollout-shared.jsonl").path],
                       "Local fallback")
    }

    func testChangedFileUsesOwningCodexSourceForMissingTitle() async throws {
        let parent = try directory()
        let first = parent.appendingPathComponent("first/sessions")
        let second = parent.appendingPathComponent("second/sessions")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let rollout = second.appendingPathComponent("rollout-second.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "second-id", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Second fallback"]]]],
        ], to: rollout)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let sources = [CodexSource(root: first), CodexSource(root: second)]
        let coordinator = IndexCoordinator(database: database, sources: sources)
        await coordinator.indexAll(scope: .proseOnly)
        let raw = try DatabaseQueue(path: parent.appendingPathComponent("trace.sqlite").path)
        let initialGenerated = try await raw.read {
            try String.fetchOne($0, sql: "SELECT generated_title FROM session WHERE external_id='second-id'")
        }
        XCTAssertNil(initialGenerated)
        try write([["id": "second-id", "thread_name": "Second source title"]],
                  to: second.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"))
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"plan\",\"text\":\"Updated\"}}\n".utf8))
        try handle.close()

        let freshCoordinator = IndexCoordinator(database: database, sources: sources)
        let result = await freshCoordinator.refreshResult(paths: [rollout.path], scope: .proseOnly)

        let title = try await database.sessions().first?.title
        XCTAssertEqual(result.phase, .complete)
        XCTAssertEqual(result.indexedFiles, 1)
        XCTAssertNil(result.metadataWarning)
        let generated = try await raw.read {
            try String.fetchOne($0, sql: "SELECT generated_title FROM session WHERE external_id='second-id'")
        }
        XCTAssertEqual(generated, "Second source title")
        XCTAssertEqual(title, "Second source title")
    }

    func testCodexMetadataWarningsAreDirectorySortedAndDeduplicated() async throws {
        let parent = try directory()
        let defaultHome = parent.appendingPathComponent("default")
        let localHome = parent.appendingPathComponent("local")
        let defaultSessions = defaultHome.appendingPathComponent("sessions")
        let localSessions = localHome.appendingPathComponent("sessions")
        for home in [defaultHome, localHome] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("sessions"),
                withIntermediateDirectories: true
            )
            try Data("not a database".utf8).write(
                to: home.appendingPathComponent("state_1.sqlite")
            )
        }
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))

        let terminal = await IndexCoordinator(
            database: database,
            sources: [CodexSource(roots: [defaultSessions, localSessions])]
        ).indexAllResult(scope: .proseOnly)

        let warning = try XCTUnwrap(terminal.metadataWarning)
        XCTAssertEqual(warning.components(separatedBy: defaultHome.path).count - 1, 1)
        XCTAssertEqual(warning.components(separatedBy: localHome.path).count - 1, 1)
        XCTAssertLessThan(
            try XCTUnwrap(warning.range(of: defaultHome.path)).lowerBound,
            try XCTUnwrap(warning.range(of: localHome.path)).lowerBound
        )
    }

    func testCodexMetadataUsesConfiguredParentForSymlinkedSessionsRoot() async throws {
        let parent = try directory()
        let configuredParent = parent.appendingPathComponent("configured")
        let mountedSessions = parent.appendingPathComponent("mounted/sessions")
        try FileManager.default.createDirectory(
            at: configuredParent, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: mountedSessions, withIntermediateDirectories: true
        )
        let configuredSessions = configuredParent.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(
            at: configuredSessions, withDestinationURL: mountedSessions
        )
        let rollout = mountedSessions.appendingPathComponent("rollout-symlink.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "codex-symlink", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback title"]],
            ]],
        ], to: rollout)
        try write([
            ["id": "codex-symlink", "thread_name": "Configured sidecar title",
             "updated_at": "2026-09-20"],
        ], to: configuredParent.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))

        await IndexCoordinator(
            database: database, sources: [CodexSource(root: configuredSessions)]
        ).indexAll(scope: .proseOnly)

        let sessions = try await database.sessions()
        XCTAssertEqual(sessions.first?.title, "Configured sidecar title")
    }

    func testConfiguredNestedSymlinkStillInheritsDefaultCodexNames() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let defaultSessions = home.appendingPathComponent("sessions")
        let mounted = parent.appendingPathComponent("mounted")
        try FileManager.default.createDirectory(at: defaultSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
        let alias = defaultSessions.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mounted)
        try write(codexRollout(id: "configured-nested"),
                  to: mounted.appendingPathComponent("rollout-nested.jsonl"))
        try write([["id": "configured-nested", "thread_name": "Inherited title"]],
                  to: home.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, alias])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let title = try await database.sessions().first?.title
        XCTAssertEqual(title, "Inherited title")
    }

    func testAliasIntoDefaultDoesNotReadUnrelatedParentAsMetadataHome() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let defaultSessions = home.appendingPathComponent("sessions")
        let nested = defaultSessions.appendingPathComponent("2026")
        let aliasParent = parent.appendingPathComponent("aliases")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aliasParent, withIntermediateDirectories: true)
        let alias = aliasParent.appendingPathComponent("codex-sessions")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        try FileManager.default.createDirectory(
            at: aliasParent.appendingPathComponent("session_index.jsonl"),
            withIntermediateDirectories: true
        )
        try write(codexRollout(id: "alias-default"),
                  to: nested.appendingPathComponent("rollout-alias.jsonl"))
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try write([["id": "alias-default", "thread_name": "Original default"]], to: sidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, alias])]
        )
        let initial = await coordinator.indexAllResult(scope: .proseOnly)
        XCTAssertNil(initial.metadataWarning)
        try write([["id": "alias-default", "thread_name": "Renamed default"]], to: sidecar)
        let renamed = await coordinator.refreshResult(paths: [sidecar.path], scope: .proseOnly)
        XCTAssertNil(renamed.metadataWarning)
        let title = try await database.sessions().first?.title
        XCTAssertEqual(title, "Renamed default")
    }

    func testAliasIntoDefaultUsesConfiguredHomeWhenItHasMetadata() async throws {
        let parent = try directory()
        let defaultHome = parent.appendingPathComponent("default")
        let defaultSessions = defaultHome.appendingPathComponent("sessions")
        let nested = defaultSessions.appendingPathComponent("2026")
        let configuredHome = parent.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuredHome, withIntermediateDirectories: true)
        let alias = configuredHome.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        try write(codexRollout(id: "shared-name"),
                  to: nested.appendingPathComponent("rollout-shared.jsonl"))
        try write([["id": "shared-name", "thread_name": "Inherited name"]],
                  to: defaultHome.appendingPathComponent("session_index.jsonl"))
        let localSidecar = configuredHome.appendingPathComponent("session_index.jsonl")
        try write([["id": "shared-name", "thread_name": "Configured name"]], to: localSidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, alias])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "Configured name")
        try write([["id": "shared-name", "thread_name": "Configured rename"]], to: localSidecar)
        await coordinator.refresh(paths: [localSidecar.path], scope: .proseOnly)
        let renamedTitle = try await database.sessions().first?.title
        XCTAssertEqual(renamedTitle, "Configured rename")
    }

    func testDeletingOnlyAliasedHomeSidecarRefreshesInheritedTitle() async throws {
        let parent = try directory()
        let defaultHome = parent.appendingPathComponent("default")
        let defaultSessions = defaultHome.appendingPathComponent("sessions")
        let nested = defaultSessions.appendingPathComponent("2026")
        let configuredHome = parent.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configuredHome, withIntermediateDirectories: true)
        let alias = configuredHome.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        try write(codexRollout(id: "alias-deletion"),
                  to: nested.appendingPathComponent("rollout-alias.jsonl"))
        try write([["id": "alias-deletion", "thread_name": "Inherited name"]],
                  to: defaultHome.appendingPathComponent("session_index.jsonl"))
        let localSidecar = configuredHome.appendingPathComponent("session_index.jsonl")
        try write([["id": "alias-deletion", "thread_name": "Local name"]], to: localSidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, alias])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "Local name")

        try FileManager.default.removeItem(at: localSidecar)
        let refreshed = await coordinator.refreshResult(paths: [localSidecar.path], scope: .proseOnly)
        XCTAssertNil(refreshed.metadataWarning)
        let inheritedTitle = try await database.sessions().first?.title
        XCTAssertEqual(inheritedTitle, "Inherited name")
    }

    func testAliasedHomeLoadsSymlinkedSidecar() async throws {
        let parent = try directory()
        let defaultHome = parent.appendingPathComponent("default")
        let defaultSessions = defaultHome.appendingPathComponent("sessions")
        let nested = defaultSessions.appendingPathComponent("2026")
        let configuredHome = parent.appendingPathComponent("configured")
        let sidecarStore = parent.appendingPathComponent("sidecar-store")
        for directory in [nested, configuredHome, sidecarStore] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let alias = configuredHome.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        try write(codexRollout(id: "symlink-sidecar"),
                  to: nested.appendingPathComponent("rollout-symlink.jsonl"))
        try write([["id": "symlink-sidecar", "thread_name": "Inherited name"]],
                  to: defaultHome.appendingPathComponent("session_index.jsonl"))
        let target = sidecarStore.appendingPathComponent("names.jsonl")
        try write([["id": "symlink-sidecar", "thread_name": "Linked local name"]], to: target)
        try FileManager.default.createSymbolicLink(
            at: configuredHome.appendingPathComponent("session_index.jsonl"),
            withDestinationURL: target
        )
        let database = try IndexDatabase(url: parent.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, alias])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let title = try await database.sessions().first?.title
        XCTAssertEqual(title, "Linked local name")
    }

    func testRepointedAliasReconciliationRefreshesFrozenRootsCodexNames() async throws {
        let parent = try directory()
        let configured = parent.appendingPathComponent("configured")
        let original = parent.appendingPathComponent("original")
        let replacement = parent.appendingPathComponent("replacement")
        for root in [configured, original, replacement] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let alias = configured.appendingPathComponent("sessions")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        try write(codexRollout(id: "repointed"),
                  to: original.appendingPathComponent("rollout-repointed.jsonl"))
        let sidecar = configured.appendingPathComponent("session_index.jsonl")
        try write([["id": "repointed", "thread_name": "Before repoint"]], to: sidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: alias)])
        await coordinator.indexAll(scope: .proseOnly)
        try write([["id": "repointed", "thread_name": "After repoint"]], to: sidecar)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement)
        _ = await coordinator.reconcile(paths: [alias.path], scope: .proseOnly, activity: .rootRecovery)
        let title = try await database.sessions().first?.title
        XCTAssertEqual(title, "After repoint")
    }

    func testMovingCodexSessionToNestedRootWithoutMetadataPreservesTitle() async throws {
        let parent = try directory()
        let sessions = parent.appendingPathComponent("sessions")
        let nested = sessions.appendingPathComponent("2026/09")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("rollout-nested.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "codex-nested", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback nested request"]],
            ]],
        ], to: file)
        try write([
            ["id": "codex-nested", "thread_name": "Preserved nested title",
             "updated_at": "2026-09-21"],
            ["id": "codex-new-nested", "thread_name": "New nested title",
             "updated_at": "2026-09-22"],
        ], to: parent.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))

        await IndexCoordinator(
            database: database, sources: [CodexSource(root: sessions)]
        ).indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "Preserved nested title")

        let nestedSource = CodexSource(roots: [sessions, nested])
        let nestedCoordinator = IndexCoordinator(
            database: database, sources: [nestedSource]
        )
        let terminal = await nestedCoordinator.indexAllResult(scope: .proseOnly)

        XCTAssertEqual(terminal.phase, .complete)
        let preservedTitle = try await database.sessions().first?.title
        XCTAssertEqual(preservedTitle, "Preserved nested title")
        let storedState = try await database.sourceState(agent: .codex, path: file.path)
        let state = try XCTUnwrap(storedState)
        let nestedRoot = try XCTUnwrap(nestedSource.roots.first { $0.url == nested })
        let nestedRootID = try await database.register(root: nestedRoot)
        XCTAssertEqual(state.rootID, nestedRootID)

        let added = nested.appendingPathComponent("rollout-new-nested.jsonl")
        try write([
            ["type": "session_meta", "payload": [
                "id": "codex-new-nested", "cwd": "/tmp/codex",
            ]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "New nested request"]],
            ]],
        ], to: added)
        await nestedCoordinator.refresh(paths: [added.path], scope: .proseOnly)
        let titles = try await database.sessions().map(\.title)
        XCTAssertEqual(Set(titles), ["Preserved nested title", "New nested title"])
    }

    func testNestedRootInheritsDefaultRenamesAndDeletionsThroughSymlinkAlias() async throws {
        let parent = try directory()
        let home = parent.appendingPathComponent("home")
        let defaultSessions = home.appendingPathComponent("sessions")
        let nested = defaultSessions.appendingPathComponent("2026/09")
        let alias = parent.appendingPathComponent("alias-nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        for id in ["rename-id", "delete-id"] {
            try write([
                ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/codex"]],
                ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Fallback \(id)"]]]],
            ], to: nested.appendingPathComponent("rollout-\(id).jsonl"))
        }
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try write([
            ["id": "rename-id", "thread_name": "Old inherited"],
            ["id": "delete-id", "thread_name": "Soon deleted"],
        ], to: sidecar)
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [defaultSessions, alias])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let initial = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(initial[nested.appendingPathComponent("rollout-rename-id.jsonl").path],
                       "Old inherited")

        try write([["id": "rename-id", "thread_name": "New inherited"]], to: sidecar)
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let updated = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(updated[nested.appendingPathComponent("rollout-rename-id.jsonl").path],
                       "New inherited")
        XCTAssertEqual(updated[nested.appendingPathComponent("rollout-delete-id.jsonl").path],
                       "Fallback delete-id")
    }

    func testIncompleteNestedCodexMetadataOnlyReplacesLocallySuppliedNames() async throws {
        let home = try directory()
        let defaultSessions = home.appendingPathComponent("sessions")
        let nestedSessions = defaultSessions.appendingPathComponent("2026/09")
        let localMetadata = nestedSessions.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: nestedSessions, withIntermediateDirectories: true)
        for id in ["inherited-id", "local-id", "fill-id"] {
            try write([
                ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/codex"]],
                ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Fallback for \(id)"]]]],
            ], to: nestedSessions.appendingPathComponent("rollout-\(id).jsonl"))
        }
        let defaultIndex = home.appendingPathComponent("session_index.jsonl")
        let localIndex = localMetadata.appendingPathComponent("session_index.jsonl")
        try write([
            ["id": "inherited-id", "thread_name": "Inherited original"],
            ["id": "fill-id", "thread_name": "Fill original"],
        ], to: defaultIndex)
        try write([["id": "local-id", "thread_name": "Local original"]], to: localIndex)
        let databaseURL = home.appendingPathComponent("trace.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(
            database: database,
            sources: [CodexSource(roots: [defaultSessions, nestedSessions])]
        )
        await coordinator.indexAll(scope: .proseOnly)

        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write {
            try $0.execute(sql: "UPDATE session SET generated_title=NULL WHERE external_id='fill-id'")
        }
        try write([
            ["id": "inherited-id", "thread_name": "Inherited changed"],
            ["id": "fill-id", "thread_name": "Fill changed"],
        ], to: defaultIndex)
        try FileManager.default.removeItem(at: localIndex)
        try FileManager.default.createDirectory(at: localIndex, withIntermediateDirectories: true)
        let localState = try DatabaseQueue(path: localMetadata.appendingPathComponent("state_9.sqlite").path)
        try await localState.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('local-id', 'Local changed', NULL)")
        }

        await coordinator.refresh(paths: [localIndex.path], scope: .proseOnly)
        var titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(titles[nestedSessions.appendingPathComponent("rollout-inherited-id.jsonl").path],
                       "Inherited original")
        XCTAssertEqual(titles[nestedSessions.appendingPathComponent("rollout-local-id.jsonl").path],
                       "Local changed")
        XCTAssertEqual(titles[nestedSessions.appendingPathComponent("rollout-fill-id.jsonl").path],
                       "Fill changed")

        try FileManager.default.removeItem(at: localIndex)
        try write([["id": "local-id", "thread_name": "Local complete"]], to: localIndex)
        try await localState.write {
            try $0.execute(sql: "UPDATE threads SET name='Local complete'")
        }
        await coordinator.refresh(paths: [localIndex.path], scope: .proseOnly)
        titles = Dictionary(uniqueKeysWithValues: try await database.sessions().map {
            ($0.sourcePath, $0.title)
        })
        XCTAssertEqual(titles[nestedSessions.appendingPathComponent("rollout-inherited-id.jsonl").path],
                       "Inherited changed")
        XCTAssertEqual(titles[nestedSessions.appendingPathComponent("rollout-local-id.jsonl").path],
                       "Local complete")
    }

    func testPartialLocalIndexOverridesKnownInheritedName() async throws {
        let home = try directory()
        let defaultSessions = home.appendingPathComponent("sessions")
        let nestedSessions = defaultSessions.appendingPathComponent("2026/09")
        let localMetadata = nestedSessions.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: nestedSessions, withIntermediateDirectories: true)
        try write([
            ["type": "session_meta", "payload": ["id": "local-override", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback"]]]],
        ], to: nestedSessions.appendingPathComponent("rollout-local-override.jsonl"))
        try write([["id": "local-override", "thread_name": "Inherited name"]],
                  to: home.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: home.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database,
            sources: [CodexSource(roots: [defaultSessions, nestedSessions])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let initialTitle = try await database.sessions().first?.title
        XCTAssertEqual(initialTitle, "Inherited name")

        let localIndex = localMetadata.appendingPathComponent("session_index.jsonl")
        try write([["id": "local-override", "thread_name": "Local name"]], to: localIndex)
        try FileManager.default.createDirectory(
            at: localMetadata.appendingPathComponent("state_9.sqlite"),
            withIntermediateDirectories: true
        )
        await coordinator.refresh(paths: [localIndex.path], scope: .proseOnly)
        let refreshedTitle = try await database.sessions().first?.title
        XCTAssertEqual(refreshedTitle, "Local name")
    }

    func testSafetyVerificationRefreshesMissedCodexTitleChange() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-safety.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "codex-safety", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback request"]]]],
        ], to: file)
        let external = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try await external.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('codex-safety', 'Initial title', NULL)")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let indexedSessions = try await database.sessions()
        let sessionID = try XCTUnwrap(indexedSessions.first?.id)
        let initialTitle = try await database.session(id: sessionID)?.title
        XCTAssertEqual(initialTitle, "Initial title")

        try await external.write {
            try $0.execute(sql: "UPDATE threads SET name='Recovered safety title'")
        }
        _ = await coordinator.reconcile(
            paths: [sessions.path], scope: .proseOnly, activity: .safetyVerification
        )

        let refreshedTitle = try await database.session(id: sessionID)?.title
        XCTAssertEqual(refreshedTitle, "Recovered safety title")
    }

    func testStandaloneRootRecoveryRefreshesMissedCodexTitleChange() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-root-safety.jsonl")
        try write([
            ["type": "session_meta", "payload": [
                "id": "codex-root-safety", "cwd": "/tmp/codex",
            ]],
            ["type": "response_item", "payload": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback"]],
            ]],
        ], to: file)
        let external = try DatabaseQueue(
            path: root.appendingPathComponent("state_5.sqlite").path
        )
        try await external.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('codex-root-safety', 'Initial title', NULL)")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(root: sessions)]
        )
        await coordinator.indexAll(scope: .proseOnly)
        try await external.write {
            try $0.execute(sql: "UPDATE threads SET name='Merged safety title'")
        }

        _ = await coordinator.reconcile(
            paths: [sessions.path], scope: .proseOnly, activity: .rootRecovery
        )

        let refreshedTitle = try await database.sessions().first?.title
        XCTAssertEqual(refreshedTitle, "Merged safety title")
    }

    func testCodexWALChangeRefreshesTitleWithoutOpeningWAL() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-wal.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "wal-id", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback"]]]],
        ], to: rollout)
        let stateURL = root.appendingPathComponent("state_5.sqlite")
        let state = try DatabaseQueue(path: stateURL.path)
        try await state.writeWithoutTransaction {
            try $0.execute(sql: "PRAGMA journal_mode=WAL")
        }
        try await state.write { db in
            try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('wal-id', 'Initial name', NULL)")
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        let reader = try DatabaseQueue(path: stateURL.path)
        let beganReading = DispatchSemaphore(value: 0)
        let releaseReader = DispatchSemaphore(value: 0)
        let readerTask = Task.detached {
            try await reader.read { db in
                let name = try String.fetchOne(db, sql: "SELECT name FROM threads WHERE id='wal-id'")
                guard name == "Initial name" else {
                    throw SessionSourceError.malformedRecord("old WAL snapshot was not established")
                }
                beganReading.signal()
                guard releaseReader.wait(timeout: .now() + 20) == .success else {
                    throw SessionSourceError.malformedRecord("WAL reader was not released")
                }
            }
        }
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: beganReading.wait(timeout: .now() + 10))
            }
        }
        XCTAssertEqual(started, .success)
        defer { releaseReader.signal() }
        try await state.write { try $0.execute(sql: "UPDATE threads SET name='Name from WAL event'") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path + "-wal"))

        await coordinator.refresh(
            paths: [stateURL.path + "-wal"], scope: .proseOnly
        )

        let title = try await database.sessions().first?.title
        XCTAssertEqual(title, "Name from WAL event")
        releaseReader.signal()
        try await readerTask.value
    }

    func testWALRefreshSkipsUnrelatedMetadataAndUnchangedNameWrites() async throws {
        let parent = try directory()
        let firstHome = parent.appendingPathComponent("first")
        let secondHome = parent.appendingPathComponent("second")
        let firstSessions = firstHome.appendingPathComponent("sessions")
        let secondSessions = secondHome.appendingPathComponent("sessions")
        for (sessions, id) in [(firstSessions, "first-id"), (secondSessions, "second-id")] {
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try write([
                ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/codex"]],
                ["type": "response_item", "payload": ["type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Fallback"]]]],
            ], to: sessions.appendingPathComponent("rollout-\(id).jsonl"))
        }
        let firstState = firstHome.appendingPathComponent("state_1.sqlite")
        let writer = try DatabaseQueue(path: firstState.path)
        try await writer.write {
            try $0.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
            try $0.execute(sql: "INSERT INTO threads VALUES ('first-id', 'First title', NULL)")
        }
        try write([["id": "second-id", "thread_name": "Second title"]],
                  to: secondHome.appendingPathComponent("session_index.jsonl"))
        let database = try IndexDatabase(url: parent.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(
            database: database, sources: [CodexSource(roots: [firstSessions, secondSessions])]
        )
        await coordinator.indexAll(scope: .proseOnly)
        let firstLoads = await coordinator.codexNameLoadCountForTesting(directory: firstHome)
        let secondLoads = await coordinator.codexNameLoadCountForTesting(directory: secondHome)
        let writes = await database.codexNameWriteTransactionCountForTesting()

        await coordinator.refresh(paths: [firstState.path + "-wal"], scope: .proseOnly)
        let firstLoadsAfterUnchanged = await coordinator.codexNameLoadCountForTesting(directory: firstHome)
        let secondLoadsAfterUnchanged = await coordinator.codexNameLoadCountForTesting(directory: secondHome)
        let writesAfterUnchanged = await database.codexNameWriteTransactionCountForTesting()
        XCTAssertEqual(firstLoadsAfterUnchanged, firstLoads + 1)
        XCTAssertEqual(secondLoadsAfterUnchanged, secondLoads)
        XCTAssertEqual(writesAfterUnchanged, writes)

        try await writer.write { try $0.execute(sql: "UPDATE threads SET name='Renamed first'") }
        await coordinator.refresh(paths: [firstState.path + "-wal"], scope: .proseOnly)
        let writesAfterRename = await database.codexNameWriteTransactionCountForTesting()
        XCTAssertEqual(writesAfterRename, writes + 1)
        let titles = Set(try await database.sessions().map(\.title))
        XCTAssertEqual(titles, ["Renamed first", "Second title"])
    }

    func testSafetyPassRetriesTransientEarlyMetadataFailure() async throws {
        let root = try directory()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let rollout = sessions.appendingPathComponent("rollout-retry.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "retry-id", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Fallback"]]]],
        ], to: rollout)
        let stateURL = root.appendingPathComponent("state_9.sqlite")
        let database = try IndexDatabase(url: root.appendingPathComponent("trace.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: sessions)])
        await coordinator.indexAll(scope: .proseOnly)
        try Data("not a database".utf8).write(to: stateURL)
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"plan\",\"text\":\"Updated\"}}\n".utf8))
        try handle.close()
        let repaired = TestCompletionFlag()

        let terminal = await coordinator.reconcile(
            paths: [sessions.path], scope: .proseOnly, activity: .safetyVerification
        ) { update in
            if update.phase == .indexing, update.metadataWarning != nil, !repaired.value {
                repaired.mark()
                try? FileManager.default.removeItem(at: stateURL)
                if let state = try? DatabaseQueue(path: stateURL.path) {
                    try? await state.write { db in
                        try db.execute(sql: "CREATE TABLE threads (id TEXT, name TEXT, title TEXT)")
                        try db.execute(sql: "INSERT INTO threads VALUES ('retry-id', 'Recovered name', NULL)")
                    }
                }
            }
        }

        XCTAssertTrue(repaired.value)
        XCTAssertEqual(terminal.phase, .complete)
        XCTAssertNil(terminal.metadataWarning)
        let title = try await database.sessions().first?.title
        XCTAssertEqual(title, "Recovered name")
    }

    func testOptionalCodexTitleDatabaseFailureIsMetadataWarning() async throws {
        let root = try directory()
        let rollouts = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let file = rollouts.appendingPathComponent("rollout-title-warning.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "codex-warning", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Indexed request"]]]],
        ], to: file)
        let url = root.appendingPathComponent("trace.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: rollouts)])
        await coordinator.indexAll(scope: .proseOnly)
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([["id": "codex-warning", "thread_name": "Sidecar title"]], to: sidecar)
        await coordinator.refresh(paths: [sidecar.path], scope: .proseOnly)
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE session SET generated_title=NULL")
            try db.execute(sql: "CREATE TRIGGER reject_optional_title BEFORE UPDATE OF generated_title ON session WHEN NEW.generated_title='Sidecar title' BEGIN SELECT RAISE(ABORT, 'optional title unavailable'); END")
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"response_item","payload":{"type":"plan","text":"A structured plan"}}"#.utf8) + Data([10]))
        try handle.close()
        let recorder = MetadataWarningRecorder()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly) { recorder.receive($0) }
        let terminal = try XCTUnwrap(recorder.terminal)
        XCTAssertEqual(terminal.phase, .complete)
        XCTAssertEqual(terminal.failedFiles, 0)
        XCTAssertEqual(terminal.unresolvedFailedFiles, 0)
        XCTAssertTrue(terminal.metadataWarning?.contains("optional title unavailable") == true)
        let indexed = try await database.search(query: "Indexed")
        XCTAssertEqual(indexed.results.count, 1)
        let sessions = try await database.sessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertTrue(session.hasPlan)
    }

    func testNewAndReplacedCodexRolloutsFillSidecarNames() async throws {
        let root = try directory()
        let rollouts = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let original = rollouts.appendingPathComponent("rollout-original.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "original-id", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Original request"]]]],
        ], to: original)
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try write([
            ["id": "original-id", "thread_name": "Original name"],
            ["id": "new-id", "thread_name": "New name"],
        ], to: sidecar)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: rollouts)])
        await coordinator.indexAll(scope: .proseOnly)
        let initial = try await database.sessions()
        XCTAssertEqual(initial.first?.title, "Original name")

        let added = rollouts.appendingPathComponent("rollout-added.jsonl")
        try write([
            ["type": "session_meta", "payload": ["id": "new-id", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "New request"]]]],
        ], to: added)
        await coordinator.refresh(paths: [added.path], scope: .proseOnly)
        let afterAdd = try await database.sessions()
        XCTAssertEqual(Set(afterAdd.map(\.title)), ["Original name", "New name"])

        try write([
            ["type": "session_meta", "payload": ["id": "original-id", "cwd": "/tmp/codex"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Rewritten request"]]]],
        ], to: original)
        await coordinator.refresh(paths: [original.path], scope: .proseOnly)
        let afterReplace = try await database.sessions()
        XCTAssertEqual(Set(afterReplace.map(\.title)), ["Original name", "New name"])
    }

    func testPlanFalsePositivesAndProviderSubmissions() throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let source = DiscoveredSourceFile(agent: .claudeCode, root: root, url: file, format: .claudeJSONL)
        try write([message("user", "<proposed_plan>Quoted user plan</proposed_plan>", id: "user"),
                   message("assistant", "I plan to investigate.\n- Read\n- Test", id: "progress"),
                   message("assistant", "<proposed_plan> \n </proposed_plan>", id: "empty"),
                   ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "ExitPlanMode", "input": [:]]]]]], to: file)
        var scan = try SessionMetadataReader.scan(file: source, through: Int64(Data(contentsOf: file).count))
        var metadata = try XCTUnwrap(scan.sessions["session"])
        XCTAssertFalse(metadata.hasPlan)
        try write([["type": "assistant", "message": ["content": [["type": "tool_use", "name": "ExitPlanMode", "input": ["plan": "Implement the feature"]]]]]], to: file)
        scan = try SessionMetadataReader.scan(file: source, through: Int64(Data(contentsOf: file).count))
        metadata = try XCTUnwrap(scan.sessions["session"])
        XCTAssertTrue(metadata.hasPlan)
        XCTAssertNil(metadata.firstUserMessage)
    }

    func testGeminiSummaryAndFallback() throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.json")
        let source = DiscoveredSourceFile(agent: .gemini, root: root, url: file, format: .geminiJSON)
        let object: [String: Any] = ["title": " ", "summary": "Gemini summary", "sessionId": "gemini-one",
            "messages": [["type": "user", "content": "Actual request"],
                         ["type": "gemini", "content": "",
                          "toolCalls": [["name": "ExitPlanMode", "args": ["plan": "Generated plan"]]]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let scan = try SessionMetadataReader.scan(file: source, through: Int64(Data(contentsOf: file).count))
        XCTAssertEqual(scan.sessions.count, 1)
        let result = try XCTUnwrap(scan.sessions.values.first)
        XCTAssertEqual(result.title, "Gemini summary")
        XCTAssertEqual(result.firstUserMessage, "Actual request")
        XCTAssertTrue(result.hasPlan)
        XCTAssertEqual(SessionMetadataReader.userTitle("<environment_context>metadata</environment_context>\nUser request"), "User request")
        XCTAssertNil(SessionMetadataReader.userTitle("# AGENTS.md instructions for /tmp\nInjected instructions"))
    }

    func testGeminiJSONLSetMessagesAndIncrementalMetadataTail() throws {
        let root = try directory()
        let file = root.appendingPathComponent("session-current.jsonl")
        let source = DiscoveredSourceFile(agent: .gemini, root: root, url: file, format: .geminiJSONL)
        try write([[
            "sessionId": "gemini-current",
            "$set": [
                "summary": "Generated summary",
                "messages": [
                    ["type": "user", "content": [["text": "Request from an untyped part"]]],
                    ["type": "gemini", "content": [["content": "<proposed_plan>Ship it</proposed_plan>"]]],
                ],
            ],
        ]], to: file)
        let initialBoundary = Int64(try Data(contentsOf: file).count)
        let initial = try SessionMetadataReader.scan(file: source, through: initialBoundary)
        let metadata = try XCTUnwrap(initial.sessions["gemini-current"])
        XCTAssertEqual(metadata.title, "Generated summary")
        XCTAssertEqual(metadata.firstUserMessage, "Request from an untyped part")
        XCTAssertTrue(metadata.hasPlan)
        XCTAssertEqual(initial.checkpoint, initialBoundary)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sessionId\":\"gemini-current\",\"title\":\"Explicit title\"}\n".utf8))
        try handle.close()
        let finalBoundary = Int64(try Data(contentsOf: file).count)
        let tail = try SessionMetadataReader.scan(file: source, from: initial.checkpoint, through: finalBoundary)
        let tailMetadata = try XCTUnwrap(tail.sessions["gemini-current"])
        XCTAssertEqual(tailMetadata.title, "Explicit title")
        XCTAssertTrue(tailMetadata.titleIsExplicit)
        XCTAssertNil(tailMetadata.firstUserMessage)
        XCTAssertEqual(tail.checkpoint, finalBoundary)
    }

    func testGeminiJSONLInheritedAndSetSessionIDsMatchMetadata() async throws {
        let root = try directory()
        let chats = root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let headerFile = chats.appendingPathComponent("session-header.jsonl")
        try write([
            ["sessionId": "header-id", "$set": ["messages": [
                ["id": "user-1", "type": "user", "content": "First request"]]]],
            ["$set": ["summary": "Inherited title", "messages": [
                ["id": "reply-1", "type": "gemini", "content": "First answer"]]]],
        ], to: headerFile)
        let setFile = chats.appendingPathComponent("session-set.jsonl")
        try write([
            ["$set": ["sessionId": "set-id", "title": "Set title", "messages": [
                ["id": "user-2", "type": "user", "content": "Second request"]]]],
            ["$set": ["messages": [
                ["id": "reply-2", "type": "gemini", "content": "Second answer"]]]],
        ], to: setFile)

        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [GeminiSource(root: root)])
        await coordinator.indexAll(scope: .proseOnly)
        let sessions = try await database.sessions()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sessions.map { ($0.title, $0.messageCount) }), [
            "Inherited title": 2, "Set title": 2,
        ])

        let handle = try FileHandle(forWritingTo: headerFile)
        try handle.seekToEnd()
        let tail: [String: Any] = ["$set": ["messages": [
            ["id": "user-3", "sessionId": "nested-id", "type": "user", "content": "Follow-up request"]]]]
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: tail) + Data([10]))
        try handle.close()
        await coordinator.refresh(paths: [headerFile.path], scope: .proseOnly)
        let afterAppend = try await database.sessions()
        XCTAssertEqual(afterAppend.count, 2)
        XCTAssertEqual(afterAppend.first(where: { $0.title == "Inherited title" })?.messageCount, 3)
    }

    func testGeminiOneLineAppendsReuseBothSavedSessionIdentities() async throws {
        let root = try directory()
        let chats = root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-live.jsonl")
        try write([["sessionId": "real-session-id", "$set": ["messages": [
            ["id": "initial", "type": "user", "content": "initial request"]]]]], to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [GeminiSource(root: root)])
        await coordinator.indexAll(scope: .proseOnly)
        let initialState = try await database.sourceState(agent: .gemini, path: file.path)
        XCTAssertEqual(initialState?.contentSessionID, "real-session-id")
        XCTAssertEqual(initialState?.metadataSessionID, "real-session-id")

        #if DEBUG
        GeminiJSONLSessionIdentity.resetPrefixScanCount()
        #endif
        for index in 0..<12 {
            let next: [String: Any] = ["$set": ["messages": [
                ["id": "append-\(index)", "type": "gemini", "content": "live answer \(index)"]]]]
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: next) + Data([10]))
            try handle.close()
            await coordinator.refresh(paths: [file.path], scope: .proseOnly)
            let state = try await database.sourceState(agent: .gemini, path: file.path)
            XCTAssertEqual(state?.contentSessionID, "real-session-id")
            XCTAssertEqual(state?.metadataSessionID, "real-session-id")
        }
        #if DEBUG
        XCTAssertEqual(GeminiJSONLSessionIdentity.prefixScanCount, 0,
                       "routine appends must never reopen the JSONL prefix")
        #endif
        let sessions = try await database.sessions()
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.messageCount, 13)
        XCTAssertEqual(session.title, "initial request")
    }

    func testLegacyGeminiPrefixScanLeavesCoordinatorAvailableForHydration() async throws {
        let root = try directory()
        let chats = root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-legacy-prefix.jsonl")
        let first: [String: Any] = ["sessionId": "legacy-id", "$set": ["messages": [
            ["id": "initial", "type": "user", "content": "initial request"]]]]
        var objects = [first]
        for index in 0..<100 {
            objects.append(["$set": ["messages": [
                ["id": "filler-\(index)", "type": "gemini", "content": "filler answer"]]]])
        }
        try write(objects, to: file)
        let databaseURL = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: databaseURL)
        let coordinator = IndexCoordinator(database: database, sources: [GeminiSource(root: root)])
        await coordinator.indexAll(scope: .proseOnly)
        let initialPage = try await database.search(query: "initial")
        let messageID = try XCTUnwrap(initialPage.results.first?.id)
        let raw = try DatabaseQueue(path: databaseURL.path)
        try await raw.write { db in
            try db.execute(sql: "UPDATE source_file SET content_session_id=NULL, metadata_session_id=NULL WHERE path=?",
                           arguments: [file.path])
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: ["$set": ["messages": [
            ["id": "tail", "type": "gemini", "content": "tail answer"]]]]) + Data([10]))
        try handle.close()
        #if DEBUG
        GeminiJSONLSessionIdentity.resetPrefixScanCount()
        GeminiJSONLSessionIdentity.delayPrefixScan(path: file.path, secondsPerLine: 0.01)
        defer { GeminiJSONLSessionIdentity.delayPrefixScan(path: nil) }
        #endif
        let finished = TestCompletionFlag()
        let run = Task {
            await coordinator.refresh(paths: [file.path], scope: .proseOnly)
            finished.mark()
        }
        #if DEBUG
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && GeminiJSONLSessionIdentity.prefixScanCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(GeminiJSONLSessionIdentity.prefixScanCount, 0)
        #endif
        let hydrated = try await coordinator.hydrate(messageID: messageID)
        XCTAssertTrue(hydrated.sections.prose.contains("initial request"))
        XCTAssertFalse(finished.value,
                       "hydration should finish while the detached legacy scan is still running")
        await run.value
        let state = try await database.sourceState(agent: .gemini, path: file.path)
        XCTAssertEqual(state?.contentSessionID, "legacy-id")
    }

    func testMetadataIsScopedToExternalSessionIDAndCodexPlanShapes() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("mixed.jsonl")
        try write([
            message("user", "First session request", id: "one").merging(["sessionId": "one"]) { _, new in new },
            ["type": "custom-title", "sessionId": "one", "customTitle": "First title"],
            message("user", "Second session request", id: "two").merging(["sessionId": "two"]) { _, new in new },
            ["type": "summary", "sessionId": "two", "summary": "Second summary"],
        ], to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .everything)
        let sessions = try await database.sessions()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: sessions.map { ($0.title, $0.messageCount) }), [
            "First title": 1,
            "Second summary": 1,
        ])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"custom-title\",\"customTitle\":\"Newest second title\"}\n".utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .everything)
        let refreshedTitles = try await database.sessions().map(\.title)
        XCTAssertEqual(Set(refreshedTitles), ["First title", "Newest second title"])

        let codexFile = root.appendingPathComponent("rollout-plans.jsonl")
        let codexSource = DiscoveredSourceFile(agent: .codex, root: root, url: codexFile, format: .codexJSONL)
        for (field, value) in [
            ("text", "Text plan"),
            ("message", "Message plan"),
            ("content", [["output": "Content plan"]]),
        ] as [(String, Any)] {
            try write([
                ["type": "session_meta", "payload": ["id": "codex-\(field)"]],
                ["type": "response_item", "payload": ["type": "plan", field: value]],
            ], to: codexFile)
            let scan = try SessionMetadataReader.scan(
                file: codexSource,
                through: Int64(try Data(contentsOf: codexFile).count)
            )
            XCTAssertTrue(try XCTUnwrap(scan.sessions["codex-\(field)"]).hasPlan)
        }
    }

    func testReplacementClearsStaleDerivedMetadata() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try write([
            message("user", "Original request", id: "original"),
            ["type": "custom-title", "sessionId": "session", "customTitle": "Stale title"],
            message("assistant", "<proposed_plan>Old plan</proposed_plan>", id: "plan"),
        ], to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .everything)
        let originalSessions = try await database.sessions()
        let original = try XCTUnwrap(originalSessions.first)
        XCTAssertEqual(original.title, "Stale title")
        XCTAssertTrue(original.hasPlan)

        try write([message("user", "Replacement request", id: "replacement")], to: file)
        await coordinator.refresh(paths: [file.path], scope: .everything)

        let replacementSessions = try await database.sessions()
        let replacement = try XCTUnwrap(replacementSessions.first)
        XCTAssertEqual(replacement.title, "Replacement request")
        XCTAssertFalse(replacement.hasPlan)
    }

    func testV2MigrationPreservesContentAndBackfills() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        try write([message("user", "Migration request", id: "first")], to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
        let original = try await database.sessions()
        let id = try XCTUnwrap(original.first?.id)
        let messages = try await database.messages(sessionID: id)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            for column in ["first_user_message", "generated_title", "has_plan"] { try db.execute(sql: "ALTER TABLE session DROP COLUMN \(column)") }
            try db.execute(sql: "ALTER TABLE source_file DROP COLUMN metadata_revision")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='trace-v3-session-metadata'")
            try db.execute(sql: "UPDATE trace_meta SET value='2' WHERE key='schema_version'")
        }
        let migrated = try IndexDatabase(url: url)
        await IndexCoordinator(database: migrated, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
        let after = try await migrated.messages(sessionID: id)
        XCTAssertEqual(after.map(\.id), messages.map(\.id))
        let result = try await migrated.search(query: "Migration", filters: .init(), sort: .recency)
        XCTAssertEqual(result.results.count, 1)
    }

    func testBundledPricingAndInvalidOverride() throws {
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Pricing/default-pricing.json")
        let override = try directory().appendingPathComponent("pricing.json")
        let normal = try PricingCatalog.load(bundledURL: bundled, overrideURL: override)
        XCTAssertFalse(normal.catalog.rates.isEmpty)
        XCTAssertNil(normal.overrideError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override.path))
        try Data("not JSON".utf8).write(to: override)
        let fallback = try PricingCatalog.load(bundledURL: bundled, overrideURL: override)
        XCTAssertEqual(fallback.catalog.rates, normal.catalog.rates)
        XCTAssertNotNil(fallback.overrideError)
    }
}

private final class MetadataWarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTerminal: IndexProgress?
    func receive(_ update: IndexProgress) {
        guard [.complete, .failed, .cancelled].contains(update.phase) else { return }
        lock.withLock { lastTerminal = update }
    }
    var terminal: IndexProgress? { lock.withLock { lastTerminal } }
}

private final class TestCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    func mark() { lock.withLock { complete = true } }
    var value: Bool { lock.withLock { complete } }
}
