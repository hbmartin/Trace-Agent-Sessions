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
        let originalState = try await database.sourceState(path: file.path)
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT first_user_message FROM session"), "First real request")
            // Emulate an interrupted metadata backfill. Content/checkpoints stay intact.
            try db.execute(sql: "UPDATE source_file SET metadata_revision=NULL")
            try db.execute(sql: "UPDATE session SET title='stale', has_plan=0")
        }
        await coordinator.indexAll(scope: .everything)
        let refreshed = try await database.session(id: session.id)
        let refreshedMessages = try await database.messages(sessionID: session.id)
        let refreshedState = try await database.sourceState(path: file.path)
        XCTAssertEqual(refreshed?.title, "Chosen title")
        XCTAssertEqual(refreshed?.hasPlan, true)
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
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fallback request"]]]],
            ["type": "response_item", "payload": ["type": "plan", "text": "A structured plan"]]
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
        XCTAssertTrue(session.hasPlan)
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
    }

    func testPlanFalsePositivesAndProviderSubmissions() throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.jsonl")
        let source = DiscoveredSourceFile(agent: .claudeCode, root: root, url: file, format: .claudeJSONL)
        try write([message("user", "<proposed_plan>Quoted user plan</proposed_plan>", id: "user"),
                   message("assistant", "I plan to investigate.\n- Read\n- Test", id: "progress"),
                   message("assistant", "<proposed_plan> \n </proposed_plan>", id: "empty"),
                   ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "ExitPlanMode", "input": [:]]]]]], to: file)
        var metadata = try SessionMetadataReader.scan(file: source, boundary: Int64(Data(contentsOf: file).count))
        XCTAssertFalse(metadata.hasPlan)
        try write([["type": "assistant", "message": ["content": [["type": "tool_use", "name": "ExitPlanMode", "input": ["plan": "Implement the feature"]]]]]], to: file)
        metadata = try SessionMetadataReader.scan(file: source, boundary: Int64(Data(contentsOf: file).count))
        XCTAssertTrue(metadata.hasPlan)
        XCTAssertNil(metadata.firstUserMessage)
    }

    func testGeminiSummaryAndFallback() throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.json")
        let source = DiscoveredSourceFile(agent: .gemini, root: root, url: file, format: .geminiJSON)
        let object: [String: Any] = ["title": " ", "summary": "Gemini summary", "sessionId": "gemini-one",
            "messages": [["type": "user", "content": "Actual request"],
                         ["type": "gemini", "content": "<proposed_plan>Generated plan</proposed_plan>"]]]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let result = try SessionMetadataReader.scan(file: source, boundary: Int64(Data(contentsOf: file).count))
        XCTAssertEqual(result.title, "Gemini summary")
        XCTAssertEqual(result.firstUserMessage, "Actual request")
        XCTAssertTrue(result.hasPlan)
        XCTAssertEqual(SessionMetadataReader.userTitle("<environment_context>metadata</environment_context>\nUser request"), "User request")
        XCTAssertNil(SessionMetadataReader.userTitle("# AGENTS.md instructions for /tmp\nInjected instructions"))
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
