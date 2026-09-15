import XCTest
@testable import TraceCore

final class TraceCoreTests: XCTestCase {
    func testQueryParserEscapesAndConnectsTerms() {
        XCTAssertEqual(FTSQueryParser.parse("alpha beta"), "\"alpha\"* AND \"beta\"*")
        XCTAssertEqual(FTSQueryParser.parse("  alpha   \"exact phrase\"  "), "\"alpha\"* AND \"exact phrase\"")
        XCTAssertEqual(FTSQueryParser.parse("say \\\"hello\\\""), "\"say\"* AND \"\"\"hello\"\"\"*")
        XCTAssertNil(FTSQueryParser.parse("   "))
    }

    func testJSONScannerFindsOnlyMessageObjects() throws {
        let data = Data(#"{"ignored":"messages", "messages":[{"id":"one","nested":{"value":"}"}},{"id":"two","text":"escaped \" quote"}]}"#.utf8)
        let ranges = JSONDocumentScanner.objectRanges(in: data, arrayKey: "messages")
        XCTAssertEqual(ranges.count, 2)
        let objects = try ranges.map { try JSONSerialization.jsonObject(with: data.subdata(in: $0)) as? [String: Any] }
        XCTAssertEqual(objects.compactMap { $0?["id"] as? String }, ["one", "two"])
    }

    func testJSONLineReaderLeavesPartialRecordForRetry() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("partial.jsonl")
        try Data("{\"id\":1}\n{\"id\":2}".utf8).write(to: url)
        var records: [JSONLineRecord] = []
        let checkpoint = try JSONLineReader.forEachCompleteLine(at: url, from: 0) { records.append($0) }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(checkpoint, 9)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        var retried: [JSONLineRecord] = []
        let final = try JSONLineReader.forEachCompleteLine(at: url, from: checkpoint) { retried.append($0) }
        XCTAssertEqual(retried.count, 1)
        XCTAssertGreaterThan(final, checkpoint)
    }

    func testJSONErrorDescriptionsTrimAndSkipWhitespace() {
        XCTAssertEqual(JSONHelpers.errorDescription([
            "error": " \n\t ", "message": "  actionable detail  ",
        ]), "actionable detail")
    }

    func testAdaptersParseObservedVariantsAndHydrateRanges() async throws {
        let claude = ClaudeCodeSource(roots: [fixtures.appendingPathComponent("Claude")])
        let codex = CodexSource(root: fixtures.appendingPathComponent("Codex"))
        let gemini = GeminiSource(root: fixtures.appendingPathComponent("Gemini"))

        let claudeFiles = try claude.discover()
        let claudeRecords = try await collect(claude.records(in: try XCTUnwrap(claudeFiles.first), from: 0))
        XCTAssertEqual(messages(in: claudeRecords).count, 4)
        XCTAssertEqual(messages(in: claudeRecords)[1].sections.reasoning, "Private chain of thought")
        XCTAssertTrue(messages(in: claudeRecords)[2].hasError)

        let codexFiles = try codex.discover()
        let codexRecords = try await collect(codex.records(in: try XCTUnwrap(codexFiles.first), from: 0))
        XCTAssertEqual(messages(in: codexRecords).count, 4)
        XCTAssertEqual(codexRecords.filter { if case .usage = $0 { true } else { false } }.count, 2)
        XCTAssertTrue(codexRecords.contains { if case .event = $0 { true } else { false } })

        let geminiFiles = try gemini.discover()
        XCTAssertEqual(geminiFiles.count, 2)
        for file in geminiFiles {
            let records = try await collect(gemini.records(in: file, from: 0))
            for message in messages(in: records) {
                let hydrated = try gemini.hydrate(fileURL: file.url, format: file.format, locator: message.locator)
                XCTAssertFalse(hydrated.sections.preferredPreview.isEmpty)
            }
        }
    }

    func testDatabaseIndexSearchScopesFiltersAndUsageDeduplication() async throws {
        let directory = try temporaryDirectory()
        let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [
            ClaudeCodeSource(roots: [fixtures.appendingPathComponent("Claude")]),
            CodexSource(root: fixtures.appendingPathComponent("Codex")),
            GeminiSource(root: fixtures.appendingPathComponent("Gemini")),
        ])
        await coordinator.indexAll(scope: .proseOnly)

        let initialHealth = try await database.sourceHealth()
        XCTAssertTrue(
            initialHealth.allSatisfy { $0.error == nil },
            "adapter failures: \(initialHealth.compactMap { $0.error }.joined(separator: "; "))"
        )
        let initialStatistics = try await database.statistics()
        XCTAssertGreaterThan(initialStatistics.messageCount, 0)

        let unicode = try await database.search(query: "resume")
        XCTAssertEqual(unicode.results.count, 1, "unicode61 should remove résumé diacritics")
        let proseToolSearch = try await database.search(query: "Read")
        XCTAssertTrue(proseToolSearch.results.isEmpty)

        try await database.clearIndex()
        await coordinator.indexAll(scope: .everything)
        let everythingToolSearch = try await database.search(query: "Read")
        XCTAssertFalse(everythingToolSearch.results.isEmpty)
        let errors = try await database.search(query: "failed", filters: .init(errorsOnly: true))
        XCTAssertTrue(errors.results.allSatisfy { $0.agent == .codex })

        let usage = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: true)
        let codexUsage = try XCTUnwrap(usage.first { $0.model == "gpt-5.6-terra" })
        XCTAssertEqual(codexUsage.inputTokens, 1_000, "duplicate response IDs must count once")
        XCTAssertEqual(codexUsage.outputTokens, 200)
        let headlineUsage = try await database.usage(fromDay: nil, throughDay: nil, includeSidechains: false)
        XCTAssertTrue(headlineUsage.allSatisfy { !$0.isSidechain })
    }

    func testRecencyAndRelevanceKeysetsThenRewriteAndDelete() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session-many.jsonl")
        let cwd = directory.appendingPathComponent("repo").path
        let initial = (0..<230).map { index in
            "{\"type\":\"user\",\"uuid\":\"message-\(index)\",\"sessionId\":\"many\",\"cwd\":\"\(cwd)\",\"timestamp\":\(1_700_000_000_000 + index),\"message\":{\"content\":\"boundary term \(index)\"}}"
        }.joined(separator: "\n") + "\n"
        try Data(initial.utf8).write(to: file)

        let source = ClaudeCodeSource(roots: [root])
        let discovered = try XCTUnwrap(source.discover().first)
        let parsed = try await collect(source.records(in: discovered, from: 0))
        XCTAssertEqual(messages(in: parsed).count, 230)
        let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [source])
        let progressRecorder = ProgressErrorRecorder()
        await coordinator.indexAll(scope: .proseOnly) { progressRecorder.receive($0) }
        XCTAssertNil(progressRecorder.error, progressRecorder.error ?? "")
        XCTAssertEqual(progressRecorder.totalFiles, 1)
        let health = try await database.sourceHealth()
        XCTAssertTrue(health.allSatisfy { $0.error == nil }, "adapter failures: \(health.compactMap { $0.error })")
        let stats = try await database.statistics()
        XCTAssertEqual(
            stats.messageCount,
            230,
            "files=\(stats.sourceFileCount) projects=\(stats.projectCount) sessions=\(stats.sessionCount)"
        )

        let first = try await database.search(query: "boundary", limit: 200)
        XCTAssertEqual(first.results.count, 200)
        let second = try await database.search(query: "boundary", cursor: try XCTUnwrap(first.nextCursor), limit: 200)
        XCTAssertEqual(second.results.count, 30)
        XCTAssertTrue(Set(first.results.map(\.id)).isDisjoint(with: second.results.map(\.id)))
        XCTAssertTrue(first.results.map(\.id).elementsEqual(first.results.map(\.id).sorted(by: >)))

        let relevanceFirst = try await database.search(query: "boundary", sort: .relevance, limit: 200)
        let relevanceSecond = try await database.search(
            query: "boundary", sort: .relevance, cursor: try XCTUnwrap(relevanceFirst.nextCursor), limit: 200
        )
        XCTAssertEqual(relevanceFirst.results.count + relevanceSecond.results.count, 230)

        let replacement = "{\"type\":\"user\",\"uuid\":\"replacement\",\"sessionId\":\"many\",\"cwd\":\"\(cwd)\",\"timestamp\":1700000001000,\"message\":{\"content\":\"boundary replacement\"}}\n"
        try Data(replacement.utf8).write(to: file, options: .atomic)
        await coordinator.indexAll(scope: .proseOnly)
        let replacementResults = try await database.search(query: "boundary")
        XCTAssertEqual(replacementResults.results.count, 1)

        try FileManager.default.removeItem(at: file)
        await coordinator.indexAll(scope: .proseOnly)
        let deletedResults = try await database.search(query: "boundary")
        XCTAssertTrue(deletedResults.results.isEmpty)
        let deletedStatistics = try await database.statistics()
        XCTAssertEqual(deletedStatistics.projectCount, 0)
    }

    func testGeminiSnapshotRewriteReplacesContentsAndOrphanedProjectAtomically() async throws {
        let directory = try temporaryDirectory()
        let geminiRoot = directory.appendingPathComponent("gemini")
        let projectDirectory = geminiRoot.appendingPathComponent("project")
        let chats = projectDirectory.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let session = chats.appendingPathComponent("session-snapshot.json")
        let marker = projectDirectory.appendingPathComponent(".project_root")
        try Data("\(directory.path)/old-project\n".utf8).write(to: marker)
        try Data(#"{"sessionId":"snapshot","messages":[{"id":"old","type":"user","timestamp":1700000000000,"content":"obsolete snapshot phrase"}]}"#.utf8).write(to: session)

        let source = GeminiSource(root: geminiRoot)
        let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.indexAll(scope: .proseOnly)
        let originalSearch = try await database.search(query: "obsolete")
        XCTAssertEqual(originalSearch.results.count, 1)

        try Data("\(directory.path)/new-project\n".utf8).write(to: marker, options: .atomic)
        try Data(#"{"sessionId":"snapshot","messages":[{"id":"new","type":"user","timestamp":1700000001000,"content":"replacement snapshot phrase"}]}"#.utf8).write(to: session, options: .atomic)
        await coordinator.indexAll(scope: .proseOnly)

        let obsoleteSearch = try await database.search(query: "obsolete")
        let replacementSearch = try await database.search(query: "replacement")
        let rewrittenStatistics = try await database.statistics()
        XCTAssertTrue(obsoleteSearch.results.isEmpty)
        XCTAssertEqual(replacementSearch.results.count, 1)
        XCTAssertEqual(rewrittenStatistics.projectCount, 1)
    }

    func testProjectCanonicalizationCollapsesLinkedWorktreesButNotClones() throws {
        let directory = try temporaryDirectory()
        let repository = directory.appendingPathComponent("repo")
        let git = repository.appendingPathComponent(".git")
        let worktree = directory.appendingPathComponent("worktree")
        let worktreeAdmin = git.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: worktreeAdmin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(worktreeAdmin.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: worktreeAdmin.appendingPathComponent("commondir"))

        let main = ProjectCanonicalizer.canonicalProject(for: repository.path)
        let linked = ProjectCanonicalizer.canonicalProject(for: worktree.path)
        XCTAssertEqual(main.key, linked.key)

        let clone = directory.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertNotEqual(main.key, ProjectCanonicalizer.canonicalProject(for: clone.path).key)
    }

    func testPricingValidationAndAvailabilityStates() throws {
        let catalog = try PricingCatalog(file: .init(
            formatVersion: 1,
            effectiveDate: "2026-01-01",
            currency: "USD",
            rates: [
                .init(modelPattern: "metered-*", inputPerMillion: 2, outputPerMillion: 10),
                .init(modelPattern: "local-*", unmetered: true),
            ]
        ))
        let usage = UsageRollup(
            day: "2026-01-01", projectID: 1, projectName: "Project", model: "metered-v1",
            isSidechain: false, inputTokens: 1_000_000, outputTokens: 500_000,
            cacheWriteTokens: 0, cacheReadTokens: 0, reasoningTokens: 0
        )
        XCTAssertEqual(catalog.estimate(usage), .estimated(7))
        XCTAssertEqual(catalog.estimate(withModel(usage, "local-v1")), .unmetered)
        XCTAssertEqual(catalog.estimate(withModel(usage, "unknown")), .rateUnavailable)

        let gemini = try PricingCatalog(file: .init(
            formatVersion: 1,
            effectiveDate: "2026-01-01",
            currency: "USD",
            rates: [.init(modelPattern: "gemini-*", inputPerMillion: 2, outputPerMillion: 10,
                          additionalReasoningPerMillion: 10)]
        ))
        let thinkingUsage = UsageRollup(
            day: "2026-01-01", projectID: 1, projectName: "Project", model: "gemini-test",
            isSidechain: false, inputTokens: 1_000_000, outputTokens: 500_000,
            cacheWriteTokens: 0, cacheReadTokens: 0, reasoningTokens: 250_000
        )
        XCTAssertEqual(gemini.estimate(thinkingUsage), .estimated(9.5))
    }

    func testClaudeUsageUsesResponseIDWithoutCollapsingContentRows() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        let snapshots: [(usage: String, model: String, project: String, timestamp: String, sidechain: Bool)] = [
            (#"{"input_tokens":100,"output_tokens":1,"cache_read_input_tokens":30}"#, "claude-sonnet-5", "AlphaProject", "2026-09-14T20:00:00Z", false),
            (#"{"output_tokens":20,"cache_creation_input_tokens":10}"#, "claude-opus-4-7", "BetaProject", "2026-09-15T20:00:00Z", true),
            (#"{"output_tokens":20}"#, "claude-haiku-4-5", "GammaProject", "2026-09-16T20:00:00Z", false),
            (#"{"output_tokens":5}"#, "claude-sonnet-5", "DeltaProject", "2026-09-17T20:00:00Z", true),
        ]
        let rows = snapshots.enumerated().map { index, snapshot in
            #"{"type":"assistant","uuid":"line-\#(index)","sessionId":"session","cwd":"/tmp/\#(snapshot.project)","timestamp":"\#(snapshot.timestamp)","isSidechain":\#(snapshot.sidechain),"message":{"id":"response-one","model":"\#(snapshot.model)","content":"line \#(index)","usage":\#(snapshot.usage)}}"#
        }.joined(separator: "\n") + "\n"
        try Data(rows.utf8).write(to: file)

        let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
            .indexAll(scope: .proseOnly)
        let sessions = try await database.sessions()
        let session = try XCTUnwrap(sessions.first)
        let contentRows = try await database.messages(sessionID: session.id)
        XCTAssertEqual(contentRows.count, 4)
        let rollups = try await database.usage(
            fromDay: nil, throughDay: nil, includeSidechains: true
        )
        let usage = try XCTUnwrap(rollups.first)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.cacheWriteTokens, 10)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(usage.model, "claude-haiku-4-5")
        XCTAssertEqual(usage.projectName, "GammaProject")
        XCTAssertEqual(usage.day, "2026-09-16")
        XCTAssertFalse(usage.isSidechain)
    }

    func testAttachmentDetectionSkipsToolArgumentsAndEmptyValues() {
        let ordinaryTool: [String: Any] = [
            "type": "tool_use", "name": "Read",
            "input": ["file": [Any](), "nested": ["type": "image"]],
        ]
        XCTAssertFalse(JSONHelpers.hasNonTextContent([ordinaryTool]))
        XCTAssertFalse(JSONHelpers.hasNonTextContent([["attachments": [Any]()]]))
        XCTAssertFalse(JSONHelpers.hasNonTextContent([["type": "image", "source": ["type": "base64", "data": ""]]]))
        XCTAssertFalse(JSONHelpers.hasNonTextContent([["type": "image", "source": ["type": "base64", "media_type": "image/png", "mime_type": "image/png", "data": ""]]]))
        XCTAssertFalse(JSONHelpers.hasNonTextContent([["type": "file", "file": ""]]))
        XCTAssertTrue(JSONHelpers.hasNonTextContent([["type": "image", "source": ["data": "encoded"]]]))
    }

    func testAttachmentOnlyClaudeMessageIsClassifiedWithoutStoringMedia() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        let row = #"{"type":"user","uuid":"image","sessionId":"session","cwd":"/tmp/project","message":{"content":[{"type":"image","source":{"type":"base64","data":"secret"}}]}}"# + "\n"
        try Data(row.utf8).write(to: file)
        let source = ClaudeCodeSource(roots: [root])
        let discovered = try XCTUnwrap(try source.discover().first)
        let records = try await collect(source.records(in: discovered, from: 0))
        let message = try XCTUnwrap(messages(in: records).first)
        XCTAssertTrue(message.sections.hasNonTextContent)
        XCTAssertEqual(message.sections.flags, 8)
        XCTAssertTrue(message.sections.prose.isEmpty)
    }

    func testCodexTurnContextModelsInitialAndIncrementalUsage() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-context.jsonl")
        let initial = """
        {"type":"session_meta","timestamp":1700000000000,"payload":{"id":"session","cwd":"/tmp/project"}}
        {"type":"turn_context","timestamp":1700000000001,"payload":{"model":"gpt-5.6-sol"}}
        {"type":"token_usage_record","timestamp":1700000000002,"payload":{"response_id":"one","usage":{"input_tokens":10,"output_tokens":2}}}

        """
        try Data(initial.utf8).write(to: file)
        let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [CodexSource(root: root)])
        await coordinator.indexAll(scope: .proseOnly)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"two\",\"usage\":{\"input_tokens\":20,\"output_tokens\":4}}}\n".utf8))
        try handle.close()
        await coordinator.refresh(paths: [file.path], scope: .proseOnly)

        let rollups = try await database.usage(
            fromDay: nil, throughDay: nil, includeSidechains: true
        )
        let usage = rollups.filter { $0.model == "gpt-5.6-sol" }
        XCTAssertFalse(usage.isEmpty)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.inputTokens }, 30)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.outputTokens }, 6)
    }

    func testMissingTimestampsUseStableFileMtimeAndRecordOffset() async throws {
        let directory = try temporaryDirectory()
        let codexRoot = directory.appendingPathComponent("codex")
        let claudeRoot = directory.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let codexFile = codexRoot.appendingPathComponent("rollout-missing-time.jsonl")
        let claudeFile = claudeRoot.appendingPathComponent("missing-time.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"session","cwd":"/tmp/project"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":"codex text"}}

        """.utf8).write(to: codexFile)
        try Data("""
        {"type":"user","uuid":"line","sessionId":"session","cwd":"/tmp/project","message":{"content":"claude text"}}

        """.utf8).write(to: claudeFile)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: codexFile.path)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: claudeFile.path)

        let codexSource = CodexSource(root: codexRoot)
        let codexDiscovered = try XCTUnwrap(try codexSource.discover().first)
        let codexMessages = messages(in: try await collect(codexSource.records(in: codexDiscovered, from: 0)))
        let codexMessage = try XCTUnwrap(codexMessages.first)
        XCTAssertEqual(
            codexMessage.timestampMilliseconds,
            TraceFileIO.modificationMilliseconds(url: codexFile) + (codexMessage.locator.offset ?? 0)
        )

        let claudeSource = ClaudeCodeSource(roots: [claudeRoot])
        let claudeDiscovered = try XCTUnwrap(try claudeSource.discover().first)
        let firstParse = messages(in: try await collect(claudeSource.records(in: claudeDiscovered, from: 0)))
        let secondParse = messages(in: try await collect(claudeSource.records(in: claudeDiscovered, from: 0)))
        XCTAssertEqual(firstParse.first?.timestampMilliseconds, secondParse.first?.timestampMilliseconds)
        XCTAssertEqual(firstParse.first?.timestampMilliseconds, TraceFileIO.modificationMilliseconds(url: claudeFile))
        XCTAssertGreaterThan(firstParse.first?.timestampMilliseconds ?? 0, 0)
    }

    func testBundledPricingCoversObservedModels() throws {
        let bundled = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Pricing/default-pricing.json")
        let catalog = try PricingCatalog(file: try JSONDecoder().decode(
            PricingFile.self, from: Data(contentsOf: bundled)
        ))
        let observed = [
            "claude-opus-4-8", "claude-opus-4-7", "claude-opus-5", "claude-haiku-4-5",
            "claude-fable-5", "claude-fable-5-1",
            "claude-sonnet-5", "gemini-3-flash-preview", "gemini-3-pro-preview",
            "gemini-3.1-pro-preview",
        ]
        for model in observed { XCTAssertNotNil(catalog.rate(for: model), model) }
        XCTAssertEqual(catalog.rate(for: "claude-sonnet-5")?.inputPerMillion, 2)
        XCTAssertEqual(catalog.rate(for: "claude-sonnet-4-5")?.inputPerMillion, 3)
        XCTAssertEqual(catalog.rate(for: "claude-opus-4-8")?.outputPerMillion, 25)
        XCTAssertEqual(catalog.rate(for: "claude-opus-4-7")?.inputPerMillion, 5)
        XCTAssertEqual(catalog.rate(for: "claude-opus-4-7")?.outputPerMillion, 25)
        XCTAssertEqual(catalog.rate(for: "claude-opus-4-7")?.cacheWritePerMillion, 6.25)
        XCTAssertEqual(catalog.rate(for: "claude-opus-4-7")?.cacheReadPerMillion, 0.5)
        XCTAssertEqual(catalog.rate(for: "claude-haiku-4-5")?.inputPerMillion, 1)
        XCTAssertEqual(catalog.rate(for: "claude-haiku-4-5")?.outputPerMillion, 5)
        XCTAssertEqual(catalog.rate(for: "claude-haiku-4-5")?.cacheWritePerMillion, 1.25)
        XCTAssertEqual(catalog.rate(for: "claude-haiku-4-5")?.cacheReadPerMillion, 0.1)
        XCTAssertEqual(catalog.rate(for: "claude-fable-5-1")?.cacheReadPerMillion, 0.25)
        XCTAssertEqual(catalog.rate(for: "gemini-3-flash-preview")?.additionalReasoningPerMillion, 3)
    }

    func testGeminiSnapshotStreamsAcrossChunksAndRejectsIncompleteDocument() async throws {
        let directory = try temporaryDirectory()
        let project = directory.appendingPathComponent("project")
        let chats = project.appendingPathComponent("chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-large.json")
        let large = String(repeating: "escaped \" brace } ", count: 5_000)
        let document = try JSONSerialization.data(withJSONObject: [
            "sessionId": "streamed",
            "messages": [
                ["id": "one", "type": "user", "content": large],
                ["id": "two", "type": "gemini", "content": "done"],
            ],
            "metadata": ["nested": [["ok": true]]],
        ])
        try document.write(to: file)
        let source = GeminiSource(root: directory)
        let discovered = try XCTUnwrap(try source.discover().first)
        let records = try await collect(source.records(in: discovered, from: 0))
        let parsed = messages(in: records)
        XCTAssertEqual(parsed.map(\.externalID), ["one", "two"])
        XCTAssertEqual(records.compactMap { if case .checkpoint(let value) = $0 { value } else { nil } }, [Int64(document.count)])
        XCTAssertEqual(try source.hydrate(
            fileURL: file, format: .geminiJSON, locator: try XCTUnwrap(parsed.first?.locator)
        ).sections.prose, large)

        let emptyDocument = Data(#"{"sessionId":"empty","messages":[]}"#.utf8)
        try emptyDocument.write(to: file)
        let empty = try XCTUnwrap(try source.discover().first)
        let emptyRecords = try await collect(source.records(in: empty, from: 0))
        XCTAssertTrue(messages(in: emptyRecords).isEmpty)
        XCTAssertEqual(emptyRecords.compactMap {
            if case .checkpoint(let value) = $0 { value } else { nil }
        }, [Int64(emptyDocument.count)])

        try Data(#"{"sessionId":"streamed","messages":[{"id":"one","type":"user","content":"truncated"}"#.utf8)
            .write(to: file)
        let incomplete = try XCTUnwrap(try source.discover().first)
        do {
            _ = try await collect(source.records(in: incomplete, from: 0))
            XCTFail("An incomplete snapshot must not emit a terminal checkpoint")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        try Data(#"{"sessionId":"streamed","messages":[],"metadata":}"#.utf8).write(to: file)
        let malformed = try XCTUnwrap(try source.discover().first)
        do {
            _ = try await collect(source.records(in: malformed, from: 0))
            XCTFail("A syntactically malformed snapshot must not emit a terminal checkpoint")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testGeminiSnapshotChecksCancellationBeforeAndDuringScanning() async throws {
        let directory = try temporaryDirectory()
        let chats = directory.appendingPathComponent("project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-cancellation.json")
        let document = try JSONSerialization.data(withJSONObject: [
            "sessionId": "cancel",
            "messages": [
                ["id": "first", "type": "user", "content": "ready"],
                ["id": "large", "type": "gemini", "content": String(repeating: "scan me ", count: 4_000_000)],
            ],
        ])
        try document.write(to: file)
        let source = GeminiSource(root: directory)
        let discovered = try XCTUnwrap(try source.discover().first)

        let cancelledBeforeStart = Task { () -> [ParsedRecord] in
            withUnsafeCurrentTask { $0?.cancel() }
            return (try? await collect(source.records(in: discovered, from: 0))) ?? []
        }
        let beforeStartRecords = await cancelledBeforeStart.value
        XCTAssertTrue(beforeStartRecords.isEmpty)

        let beganLargeObject = expectation(description: "scanner emitted the first object")
        let cancelledDuringScan = Task { () -> [ParsedRecord] in
            var iterator = source.records(in: discovered, from: 0).makeAsyncIterator()
            var records: [ParsedRecord] = []
            do {
                if let first = try await iterator.next() { records.append(first) }
                beganLargeObject.fulfill()
                while let record = try await iterator.next() { records.append(record) }
            } catch {
            }
            return records
        }
        await fulfillment(of: [beganLargeObject], timeout: 2)
        try await Task.sleep(for: .milliseconds(2))
        cancelledDuringScan.cancel()
        let duringScanRecords = await cancelledDuringScan.value
        XCTAssertEqual(messages(in: duringScanRecords).map(\.externalID), ["first"])
        XCTAssertFalse(duringScanRecords.contains { if case .checkpoint = $0 { true } else { false } })
    }

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TraceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private func collect(_ stream: AsyncThrowingStream<ParsedRecord, Error>) async throws -> [ParsedRecord] {
    var records: [ParsedRecord] = []
    for try await record in stream { records.append(record) }
    return records
}

private func messages(in records: [ParsedRecord]) -> [ParsedMessage] {
    records.compactMap { if case .message(let message) = $0 { message } else { nil } }
}

private func withModel(_ usage: UsageRollup, _ model: String) -> UsageRollup {
    .init(
        day: usage.day, projectID: usage.projectID, projectName: usage.projectName, model: model,
        isSidechain: usage.isSidechain, inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
        cacheWriteTokens: usage.cacheWriteTokens, cacheReadTokens: usage.cacheReadTokens,
        reasoningTokens: usage.reasoningTokens
    )
}

private final class ProgressErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var total = 0
    func receive(_ progress: IndexProgress) {
        lock.lock()
        if let error = progress.error { stored = error }
        total = max(total, progress.totalFiles)
        lock.unlock()
    }
    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    var totalFiles: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
