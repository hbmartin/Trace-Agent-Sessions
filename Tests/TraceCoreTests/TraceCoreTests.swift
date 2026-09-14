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
