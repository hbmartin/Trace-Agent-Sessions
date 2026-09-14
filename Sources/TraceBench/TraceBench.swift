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
            case "index":
                if options.has("--cold") { try removeDatabase(at: databaseURL) }
                try await runIndex(databaseURL: databaseURL, scope: options.scope, sourceDirectory: options.url("--sources-directory"))
            case "search":
                let query = options.value("--query") ?? "the"
                let iterations = max(1, Int(options.value("--iterations") ?? "50") ?? 50)
                try await runSearch(databaseURL: databaseURL, query: query, iterations: iterations)
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
        await coordinator.indexAll(scope: scope) { progress in
            if progress.phase == .indexing, progress.currentFileBytes == 0, progress.completedFiles.isMultiple(of: 100) {
                FileHandle.standardError.write(Data("Indexed \(progress.completedFiles)/\(progress.totalFiles)\n".utf8))
            }
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

    private static func runSearch(databaseURL: URL, query: String, iterations: Int) async throws {
        let database = try IndexDatabase(url: databaseURL)
        var ftsMilliseconds: [Double] = []
        var resultCount = 0
        for _ in 0..<iterations {
            let start = ContinuousClock.now
            let page = try await database.search(query: query, limit: 200)
            ftsMilliseconds.append(milliseconds(start.duration(to: .now)))
            resultCount = page.results.count
        }
        ftsMilliseconds.sort()
        printJSON(SearchReport(
            query: query,
            iterations: iterations,
            resultCount: resultCount,
            medianMilliseconds: percentile(ftsMilliseconds, 0.50),
            p95Milliseconds: percentile(ftsMilliseconds, 0.95),
            p99Milliseconds: percentile(ftsMilliseconds, 0.99),
            maximumMilliseconds: ftsMilliseconds.last ?? 0
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
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
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
    func url(_ name: String) -> URL? { value(name).map { URL(fileURLWithPath: $0) } }
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
    var errorDescription: String? {
        "usage: tracebench index [--cold] [--scope prose|tools|everything] [--sources-directory PATH] [--database PATH] | search [--query TEXT] [--iterations N] [--database PATH] | corpus [--database PATH]"
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
    let iterations: Int
    let resultCount: Int
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let p99Milliseconds: Double
    let maximumMilliseconds: Double
}

private struct CorpusReport: Codable {
    let sourceFiles: Int
    let projects: Int
    let sessions: Int
    let messages: Int
    let databaseBytes: Int64
}
