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
        XCTAssertEqual(providersAbsent?.title, "Persisted database title")
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
