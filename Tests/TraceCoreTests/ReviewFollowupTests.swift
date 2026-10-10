import CustomDump
import XCTest
import GRDB
@testable import TraceCore

final class ReviewFollowupTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TraceReview-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testIndentedCodeAndAllFenceLineEndingsPreserveLiteralText() {
        let indented = "    obj.__dict__\n    a*b*c\n    `tick`\n    [label](https://example.test)"
        XCTAssertEqual(String(TranscriptMarkdown.render(indented).characters), indented)
        XCTAssertEqual(String(TranscriptMarkdown.render("\tobj.__dict__").characters), "\tobj.__dict__")
        let lf = "```bash\nnpm install\n    npm test\n```"
        for ending in ["\n", "\r\n", "\r"] {
            let input = lf.replacingOccurrences(of: "\n", with: ending)
            XCTAssertEqual(String(TranscriptMarkdown.render(input).characters), lf)
        }
        XCTAssertEqual(String(TranscriptMarkdown.render("**Prose**\n\n" + indented + "\n\n*after*").characters),
                       "Prose\n\n" + indented + "\n\nafter")
        XCTAssertEqual(String(TranscriptMarkdown.render("~~~swift\nobj.__dict__\n~~~").characters),
                       "~~~swift\nobj.__dict__\n~~~")
    }

    func testQuotedMixedIndentAndIndentedFencesPreserveCodeAndRenderFollowingProse() {
        for code in [">\n>     obj.__dict__\n>     a*b*c", " \tobj.__dict__", "- Item\n\n      obj.__dict__"] {
            expectNoDifference(code, String(TranscriptMarkdown.render(code).characters))
        }
        let code = "    ```\n    obj.__dict__\n\n**after**"
        expectNoDifference("    ```\n    obj.__dict__\n\nafter", String(TranscriptMarkdown.render(code).characters))
        let quoted = "> ```swift\n>     obj.__dict__\n> ```\n\n**after**"
        expectNoDifference(quoted.replacingOccurrences(of: "**after**", with: "after"),
                           String(TranscriptMarkdown.render(quoted).characters))
        for marker in ["```", "~~~"] {
            let fenced = "   " + marker + "swift\n    obj.__dict__\n   " + marker + "\n\n**after**"
            expectNoDifference(fenced.replacingOccurrences(of: "**after**", with: "after"),
                               String(TranscriptMarkdown.render(fenced).characters))
        }
    }

    func testBlockquotedCodePreservesLiteralTextAndLineBreaks() {
        let cases = [
            "> ```\n> a*b*c\n> ```",
            "> ~~~swift\n> obj.__dict__\n> ~~~",
            ">     a*b*c\n>     obj.__dict__",
            "> > ```\n> > a*b*c\n> > ```"
        ]
        for code in cases {
            for ending in ["\n", "\r\n", "\r"] {
                let input = ("**Before**\n\n" + code + "\n\n*After*")
                    .replacingOccurrences(of: "\n", with: ending)
                XCTAssertEqual(String(TranscriptMarkdown.render(input).characters),
                               "Before\n\n" + code + "\n\nAfter")
            }
        }
    }

    func testListContinuationFormattingAndNestedLiteralCode() {
        let input = "1. Step\n\n    Run **this** with `make`\n\n        obj.__dict__\n\n    *Continue*\n\nOutside\n\n    a*b*c"
        XCTAssertEqual(String(TranscriptMarkdown.render(input).characters),
                       "1. Step\n\n    Run this with make\n\n        obj.__dict__\n\n    Continue\n\nOutside\n\n    a*b*c")
        let nested = "- Parent\n  1. Child\n\n     Run **this**\n\n         a*b*c"
        XCTAssertEqual(String(TranscriptMarkdown.render(nested).characters),
                       "- Parent\n  1. Child\n\n     Run this\n\n         a*b*c")
    }

    func testSymbolQueriesMatchTheActualConfiguredTokenizer() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("session.jsonl")
        let symbols = ["🤖", "🙂", "₿", "\u{E0B0}"]
        var data = Data()
        for (index, text) in (symbols.map { $0 + " Generated" } + ["Generated alone"]).enumerated() {
            let object: [String: Any] = ["type": "user", "uuid": "m-\(index)", "sessionId": "s", "cwd": "/tmp/symbols",
                "timestamp": 1_700_000_000_000 + index, "message": ["content": text]]
            data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10)
        }
        try data.write(to: source)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
        for symbol in symbols {
            XCTAssertNotNil(FTSQueryParser.parse(symbol))
            let page = try await database.search(query: symbol + " Generated")
            XCTAssertEqual(page.results.map(\.prefix), [symbol + " Generated"])
        }
        XCTAssertNil(FTSQueryParser.parse("-> :: &&"))
    }

    func testSidebarSnapshotRetainsLoadedPagesCountsAndEnsuredSession() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("sessions.jsonl")
        var data = Data()
        for index in 0..<605 {
            let object: [String: Any] = ["type": "user", "uuid": "m-\(index)", "sessionId": "s-\(index)",
                "cwd": "/tmp/snapshot", "timestamp": 1_700_000_000_000 + index,
                "message": ["content": "Needle \(index)"]]
            data.append(try JSONSerialization.data(withJSONObject: object)); data.append(10)
        }
        try data.write(to: file)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
        let all = try await database.sessions(limit: 1_000)
        let oldest = try XCTUnwrap(all.last)
        let snapshot = try await database.sidebarSnapshot(projectCanonicalKey: oldest.projectCanonicalKey,
                                                          pageCount: 2, ensuringSessionID: oldest.id)
        XCTAssertEqual(snapshot.sessionList.totalCount, 605)
        XCTAssertEqual(snapshot.projects.reduce(0) { $0 + $1.sessionCount }, 605)
        XCTAssertEqual(snapshot.sessionList.sessions.count, 401)
        XCTAssertEqual(snapshot.sessionList.sessions.filter { $0.id == oldest.id }.count, 1)
        XCTAssertEqual(snapshot.sessionList.pageCount, 2)
        let cursor = try XCTUnwrap(snapshot.sessionList.nextCursor)
        XCTAssertEqual(cursor.sessionID, all[399].id, "revealing an old session must not advance the page cursor")
        let next = try await database.sessionsPage(projectCanonicalKey: oldest.projectCanonicalKey, cursor: cursor)
        XCTAssertEqual(next.sessions.map(\.id), Array(all[400..<600]).map(\.id))
        let complete = try await database.sidebarSnapshot(projectCanonicalKey: nil, pageCount: 4)
        XCTAssertEqual(complete.sessionList.sessions.map(\.id), all.map(\.id))
        XCTAssertNil(complete.sessionList.nextCursor)
    }

    func testSaturatedTimestampBucketPreservesDatesAndSearchPaginationAfterRestart() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("sessions.jsonl")
        let timestamp: Int64 = 1_700_000_000_000
        func line(_ id: String, _ date: Int64) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "sessionId": "s", "cwd": "/tmp/overflow",
                "timestamp": date, "message": ["content": "OverflowNeedle \(id)"]]) + Data([10])
        }
        try (line("saturated", timestamp) + line("newer", timestamp + 1_000)).write(to: source)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        await coordinator.indexAll(scope: .proseOnly)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            let old = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM message WHERE prefix='OverflowNeedle saturated'"))
            let upper = (timestamp << 20) | ((1 << 20) - 1)
            try db.execute(sql: "DELETE FROM message_fts WHERE rowid=?", arguments: [old])
            try db.execute(sql: "UPDATE message SET id=? WHERE id=?", arguments: [upper, old])
            try db.execute(sql: "INSERT INTO message_fts(rowid,body) VALUES (?,?)", arguments: [upper, "OverflowNeedle saturated"])
        }
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd(); try handle.write(contentsOf: line("overflow", timestamp) + line("overflow-next", timestamp) + line("older", timestamp - 1_000)); try handle.close()
        await coordinator.refresh(paths: [source.path], scope: .proseOnly)
        let restarted = try IndexDatabase(url: url)
        var cursor: SearchCursor?
        var results: [SearchResult] = []
        repeat {
            let page = try await restarted.search(query: "OverflowNeedle", cursor: cursor, limit: 1)
            results += page.results; cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(Set(results.map(\.id)).count, 5)
        XCTAssertEqual(results.map(\.timestampMilliseconds), [timestamp + 1_000, timestamp, timestamp, timestamp, timestamp - 1_000])
        XCTAssertEqual(results.map(\.prefix), ["OverflowNeedle newer", "OverflowNeedle overflow-next", "OverflowNeedle overflow",
                                               "OverflowNeedle saturated", "OverflowNeedle older"])
        XCTAssertLessThan(try XCTUnwrap(results.first { $0.prefix == "OverflowNeedle overflow" }).id, 0)
        try await restarted.clearIndex()
        let overflowAfterClear = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM trace_meta WHERE key='message_id_overflow'")
        }
        XCTAssertNil(overflowAfterClear, "overflow allocation must not recreate obsolete metadata")
        let health = try await restarted.sourceHealth()
        XCTAssertTrue(health.allSatisfy { $0.error == nil })
    }

    func testGeminiUnknownMetadataPolicyIsIdenticalAcrossLayouts() async throws {
        let root = try directory()
        var scans: [SessionMetadata] = []
        for ext in ["json", "jsonl"] {
            let chats = root.appendingPathComponent(ext + "/project/chats")
            try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
            let file = chats.appendingPathComponent("session-policy." + ext)
            let messages: [[String: Any]] = [
                ["id": "user", "type": "user", "content": "Initial request"],
                ["id": "unknown", "type": "future-agent-event", "title": "Explicit title", "model": "gemini-test",
                 "content": "unknown text", "tokens": ["input": 42, "output": 17],
                 "toolCalls": [["name": "exit_plan_mode", "args": ["plan": "Submitted plan"]]]]
            ]
            let object: [String: Any] = ext == "json" ? ["sessionId": "policy", "messages": messages]
                : ["sessionId": "policy", "$set": ["messages": messages]]
            try (JSONSerialization.data(withJSONObject: object) + Data([10])).write(to: file)
            let source = GeminiSource(root: root.appendingPathComponent(ext))
            let discovered = try XCTUnwrap(try source.discover().first)
            let scan = try SessionMetadataReader.scan(file: discovered, through: Int64(Data(contentsOf: file).count))
            var parsed: [ParsedMessage] = []
            for try await record in source.records(in: discovered, from: 0) {
                if case .message(let message) = record { parsed.append(message) }
            }
            XCTAssertEqual(parsed.count, 1, "unknown types must not become assistant or usage rows")
            // Snapshot identity follows the streaming header; JSON keys are unordered.
            let identity = try XCTUnwrap(parsed.first).sessionExternalID
            scans.append(try XCTUnwrap(scan.sessions[identity]))
            XCTAssertTrue(parsed.allSatisfy { $0.usage == nil })
        }
        XCTAssertEqual(scans.map(\.title), ["Explicit title", "Explicit title"])
        XCTAssertEqual(scans.map(\.hasPlan), [true, true])
        XCTAssertEqual(scans.map(\.firstUserMessage), ["Initial request", "Initial request"])
    }

    func testExistingGeminiMetadataBackfillsWithoutReindexingMessages() async throws {
        let root = try directory()
        let chats = root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-backfill.json")
        let object: [String: Any] = ["sessionId": "backfill", "messages": [
            ["id": "request", "type": "user", "content": "Initial request"],
            ["id": "future", "type": "future-event", "title": "Recovered title",
             "toolCalls": [["name": "exit_plan_mode", "args": ["plan": "Recovered plan"]]]]
        ]]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let url = root.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        let coordinator = IndexCoordinator(database: database, sources: [GeminiSource(root: root)])
        await coordinator.indexAll(scope: .everything)
        let sessions = try await database.sessions()
        let session = try XCTUnwrap(sessions.first)
        let originalMessages = try await database.messages(sessionID: session.id)
        let originalState = try await database.sourceState(agent: .gemini, path: file.path)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            // Emulate fully checkpointed metadata from the previous JSON policy.
            try db.execute(sql: "UPDATE source_file SET metadata_revision='2:' || substr(metadata_revision,3)")
            try db.execute(sql: "UPDATE session SET generated_title=NULL, has_plan=0")
        }
        await coordinator.indexAll(scope: .everything)
        let refreshed = try await database.session(id: session.id)
        let messages = try await database.messages(sessionID: session.id)
        let state = try await database.sourceState(agent: .gemini, path: file.path)
        XCTAssertEqual(refreshed?.title, "Recovered title")
        XCTAssertEqual(refreshed?.hasPlan, true)
        XCTAssertEqual(messages.map(\.id), originalMessages.map(\.id))
        XCTAssertEqual(messages.count, 1, "unknown types remain excluded from the transcript")
        XCTAssertEqual(state?.scannedBytes, originalState?.scannedBytes)
        XCTAssertEqual(state?.contentGeneration, originalState?.contentGeneration)
        let revision = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT metadata_revision FROM source_file")
        }
        XCTAssertTrue(revision?.hasPrefix("3:") == true)
    }


    func testDirectGeminiLegacyTailRecoveryUsesInstrumentedTimestampContext() async throws {
        let root = try directory()
        let chats = root.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-legacy.jsonl")
        let timestamp: Int64 = 1_700_000_000_000
        let prefix = try JSONSerialization.data(withJSONObject: ["sessionId": "legacy-context", "$set": ["messages": [
            ["id": "first", "type": "user", "timestamp": timestamp, "content": "Request"]]]]) + Data([10])
        let tail = try JSONSerialization.data(withJSONObject: ["$set": ["messages": [
            ["id": "tail", "type": "gemini", "content": "Answer"]]]]) + Data([10])
        try (prefix + tail).write(to: file)
        let source = GeminiSource(root: root)
        let discovered = try XCTUnwrap(try source.discover().first)
        #if DEBUG
        GeminiJSONLSessionIdentity.resetPrefixScanCount()
        #endif
        var messages: [ParsedMessage] = []
        for try await record in source.records(in: discovered, from: Int64(prefix.count), through: nil) {
            if case .message(let message) = record { messages.append(message) }
        }
        XCTAssertEqual(messages.map(\.sessionExternalID), ["legacy-context"])
        XCTAssertEqual(messages.map(\.timestampMilliseconds), [timestamp])
        XCTAssertEqual(messages.map(\.externalID), ["tail"])
        #if DEBUG
        XCTAssertEqual(GeminiJSONLSessionIdentity.prefixScanCount, 1,
                       "the direct legacy recovery path must use the same observable prefix reader")
        #endif
    }

}
