import Foundation
import TraceCore

@main
struct TraceBench {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard let command = arguments.first else { throw BenchError.usage }
            let options = Options(Array(arguments.dropFirst()))
            let databaseURL = options.url("--database")
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("build/bench/index.sqlite")

            switch command {
            case "generate":
                let directory = try options.requiredURL("--sources-directory")
                let sessions = max(1, options.integer("--sessions", default: 100))
                let messages = max(1, options.integer("--messages", default: 100))
                try generateCorpus(directory: directory, sessions: sessions, messages: messages)
            case "index":
                if options.has("--cold") { try removeDatabase(at: databaseURL) }
                try await runIndex(
                    databaseURL: databaseURL, scope: options.scope,
                    sourceDirectory: options.url("--sources-directory")
                )
            case "search":
                let query = options.value("--query") ?? "the"
                let iterations = max(1, options.integer("--iterations", default: 50))
                let warmup = max(0, options.integer("--warmup", default: 5))
                let sort = SearchSort(rawValue: options.value("--sort") ?? "recency") ?? .recency
                try await runSearch(
                    databaseURL: databaseURL, query: query, sort: sort,
                    iterations: iterations, warmup: warmup
                )
            case "search-suite":
                let iterations = max(1, options.integer("--iterations", default: 50))
                let warmup = max(0, options.integer("--warmup", default: 5))
                try await runSearchSuite(
                    databaseURL: databaseURL, iterations: iterations, warmup: warmup
                )
            case "corpus":
                try await runCorpusSummary(databaseURL: databaseURL)
            default:
                throw BenchError.usage
            }
        } catch {
            FileHandle.standardError.write(Data("tracebench: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func runIndex(databaseURL: URL, scope: IndexScope, sourceDirectory: URL?) async throws {
        let database = try IndexDatabase(url: databaseURL)
        let sources: [any SessionSource]
        if let sourceDirectory {
            sources = [ClaudeCodeSource(roots: [sourceDirectory.appendingPathComponent("Claude")]),
                       CodexSource(root: sourceDirectory.appendingPathComponent("Codex")),
                       GeminiSource(root: sourceDirectory.appendingPathComponent("Gemini"))]
        } else { sources = [ClaudeCodeSource(), CodexSource(), GeminiSource()] }
        let coordinator = IndexCoordinator(database: database, sources: sources)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await coordinator.indexAllResult(scope: scope) { progress in
            if progress.phase == .indexing,
               progress.currentFileBytes == 0,
               progress.completedFiles.isMultiple(of: 100) {
                FileHandle.standardError.write(Data("Indexed \(progress.completedFiles)/\(progress.totalFiles)\n".utf8))
            }
        }
        guard result.phase == .complete, result.failedFiles == 0,
              result.unresolvedFailedFiles == 0 else {
            throw BenchError.incompleteIndex(
                phase: result.phase.rawValue,
                failedFiles: result.failedFiles,
                unresolvedFailedFiles: result.unresolvedFailedFiles
            )
        }
        let elapsed = milliseconds(start.duration(to: clock.now))
        let stats = try await database.statistics()
        printJSON(IndexReport(
            elapsedMilliseconds: elapsed,
            sourceFiles: stats.sourceFileCount,
            projects: stats.projectCount,
            sessions: stats.sessionCount,
            messages: stats.messageCount,
            databaseBytes: stats.databaseBytes
        ))
    }

    private static func runSearch(
        databaseURL: URL, query: String, sort: SearchSort,
        iterations: Int, warmup: Int
    ) async throws {
        let database = try IndexDatabase(url: databaseURL)
        printJSON(try await measureSearch(
            database: database, query: query, sort: sort,
            iterations: iterations, warmup: warmup
        ))
    }

    private static func runSearchSuite(
        databaseURL: URL, iterations: Int, warmup: Int
    ) async throws {
        let database = try IndexDatabase(url: databaseURL)
        var reports: [SearchReport] = []
        for query in ["commonterm", "PerformanceNeedle", "message 42"] {
            for sort in [SearchSort.recency, .relevance] {
                reports.append(try await measureSearch(
                    database: database, query: query, sort: sort,
                    iterations: iterations, warmup: warmup
                ))
            }
        }
        printJSON(SearchSuiteReport(cases: reports))
    }

    private static func measureSearch(
        database: IndexDatabase, query: String, sort: SearchSort,
        iterations: Int, warmup: Int
    ) async throws -> SearchReport {
        for _ in 0..<warmup {
            _ = try await database.search(query: query, sort: sort, limit: 200)
        }
        var ftsMilliseconds: [Double] = []
        var resultCount = 0
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            let page = try await database.search(query: query, sort: sort, limit: 200)
            ftsMilliseconds.append(milliseconds(start.duration(to: .now)))
            resultCount = page.results.count
        }
        ftsMilliseconds.sort()
        return SearchReport(
            query: query,
            sort: sort.rawValue,
            warmupIterations: warmup,
            iterations: iterations,
            resultCount: resultCount,
            medianMilliseconds: percentile(ftsMilliseconds, 0.50),
            p95Milliseconds: percentile(ftsMilliseconds, 0.95),
            p99Milliseconds: percentile(ftsMilliseconds, 0.99),
            maximumMilliseconds: ftsMilliseconds.last ?? 0
        )
    }

    private static func generateCorpus(
        directory: URL, sessions: Int, messages: Int
    ) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else {
            throw BenchError.destinationExists(directory.path)
        }
        let claude = directory.appendingPathComponent("Claude")
        try manager.createDirectory(at: claude, withIntermediateDirectories: true)
        for session in 0..<sessions {
            var data = Data()
            let title: [String: Any] = [
                "type": "custom-title", "customTitle": "Performance session \(session)",
            ]
            data.append(try JSONSerialization.data(withJSONObject: title))
            data.append(10)
            for message in 0..<messages {
                let record: [String: Any] = [
                    "type": message == 0 ? "user" : "assistant",
                    "uuid": "performance-\(session)-\(message)",
                    "sessionId": "performance-\(session)",
                    "cwd": "/tmp/PerformanceProject-\(session % 20)",
                    "timestamp": "2026-09-18T12:00:00Z",
                    "message": [
                        "content": "PerformanceNeedle commonterm session \(session) message \(message). "
                            + String(repeating: "Representative transcript content. ", count: 4),
                    ],
                ]
                data.append(try JSONSerialization.data(withJSONObject: record))
                data.append(10)
            }
            try data.write(to: claude.appendingPathComponent("performance-\(session).jsonl"))
        }
        printJSON(GeneratedCorpusReport(
            sessions: sessions, messagesPerSession: messages,
            totalMessages: sessions * messages, sourceDirectory: directory.path
        ))
    }

    private static func runCorpusSummary(databaseURL: URL) async throws {
        let database = try IndexDatabase(url: databaseURL)
        let stats = try await database.statistics()
        printJSON(CorpusReport(
            sourceFiles: stats.sourceFileCount,
            projects: stats.projectCount,
            sessions: stats.sessionCount,
            messages: stats.messageCount,
            databaseBytes: stats.databaseBytes
        ))
    }

    private static func removeDatabase(at url: URL) throws {
        for path in [url.path, url.path + "-wal", url.path + "-shm"]
        where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)
        return sorted[max(0, index)]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}

private struct Options {
    let values: [String]
    init(_ values: [String]) { self.values = values }
    func has(_ name: String) -> Bool { values.contains(name) }
    func value(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
        return values[index + 1]
    }
    func integer(_ name: String, default fallback: Int) -> Int {
        Int(value(name) ?? "") ?? fallback
    }
    func url(_ name: String) -> URL? { value(name).map { URL(fileURLWithPath: $0) } }
    func requiredURL(_ name: String) throws -> URL {
        guard let url = url(name) else { throw BenchError.usage }
        return url
    }
    var scope: IndexScope {
        switch value("--scope") {
        case "tools": .proseAndToolInvocations
        case "everything": .everything
        default: .proseOnly
        }
    }
}

private enum BenchError: LocalizedError {
    case usage
    case destinationExists(String)
    case incompleteIndex(phase: String, failedFiles: Int, unresolvedFailedFiles: Int)
    var errorDescription: String? {
        switch self {
        case .usage:
            [
                "usage: tracebench generate --sources-directory PATH",
                "[--sessions N] [--messages N] | index [--cold]",
                "[--scope prose|tools|everything] [--sources-directory PATH] [--database PATH] |",
                "search [--query TEXT] [--sort recency|relevance] [--iterations N]",
                "[--warmup N] [--database PATH] | search-suite [--iterations N]",
                "[--warmup N] [--database PATH] | corpus [--database PATH]",
            ].joined(separator: " ")
        case .destinationExists(let path):
            "Refusing to replace existing benchmark corpus at \(path)"
        case .incompleteIndex(let phase, let failedFiles, let unresolvedFailedFiles):
            "Indexing did not complete cleanly (phase: \(phase), failed files: \(failedFiles), unresolved failures: \(unresolvedFailedFiles))"
        }
    }
}

private struct IndexReport: Codable {
    let elapsedMilliseconds: Double
    let sourceFiles: Int
    let projects: Int
    let sessions: Int
    let messages: Int
    let databaseBytes: Int64
}

private struct SearchReport: Codable {
    let query: String
    let sort: String
    let warmupIterations: Int
    let iterations: Int
    let resultCount: Int
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
}

private struct SearchSuiteReport: Codable {
    let cases: [SearchReport]
}

private struct GeneratedCorpusReport: Codable {
    let sessions: Int
    let messagesPerSession: Int
    let totalMessages: Int
    let sourceDirectory: String
}

private struct CorpusReport: Codable {
    let sourceFiles: Int
    let projects: Int
    let sessions: Int
    let messages: Int
    let databaseBytes: Int64
}
