import Foundation
import GRDB
import TraceCore

// Compile against a Release TraceCore.framework to compare the same workload
// across revisions. The output is seconds for 100 metadata-change events.
@main
struct CodexRefreshBenchmark {
    static func main() async throws {
        if CommandLine.arguments.contains("--title-query") {
            try benchmarkTitleQuery()
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraceRefreshBench-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var sources: [any SessionSource] = []
        for index in 0..<8 {
            let home = root.appendingPathComponent("home-\(index)")
            let sessions = home.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let id = "bench-\(index)"
            let rollout = """
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"/tmp/codex"}}
            {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fallback"}]}}

            """
            try Data(rollout.utf8).write(
                to: sessions.appendingPathComponent("rollout-\(id).jsonl")
            )
            let sidecar = "{\"id\":\"\(id)\",\"thread_name\":\"Title \(index)\"}\n"
            try Data(sidecar.utf8).write(
                to: home.appendingPathComponent("session_index.jsonl")
            )
            sources.append(CodexSource(root: sessions))
        }
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: sources)
        await coordinator.indexAll(scope: .proseOnly)
        let event = root.appendingPathComponent("home-0/state_1.sqlite-wal").path
        let start = Date()
        for _ in 0..<100 {
            await coordinator.refresh(paths: [event], scope: .proseOnly)
        }
        print(String(format: "%.4f", Date().timeIntervalSince(start)))
    }

    private static func benchmarkTitleQuery() throws {
        let database = try DatabaseQueue(path: ":memory:")
        let oldQuery = """
            SELECT s.id, s.external_id, s.generated_title,
                   s.codex_name_origin, s.codex_applied_name FROM session s
            JOIN source_file sf ON sf.id=s.source_file_id
            JOIN source_root sr ON sr.id=sf.root_id
            WHERE s.agent=? AND sr.path=? AND (? IS NULL OR sf.id=?)
            """
        let newQuery = """
            SELECT s.id, s.external_id, s.generated_title,
                   s.codex_name_origin, s.codex_applied_name FROM session s
            JOIN source_file sf ON sf.id=s.source_file_id
            JOIN source_root sr ON sr.id=sf.root_id
            WHERE s.source_file_id=? AND s.agent=? AND sr.path=?
            """
        try database.write { db in
            try db.execute(sql: "CREATE TABLE source_root (id INTEGER PRIMARY KEY, path TEXT NOT NULL)")
            try db.execute(sql: "CREATE TABLE source_file (id INTEGER PRIMARY KEY, root_id INTEGER NOT NULL)")
            try db.execute(sql: """
                CREATE TABLE session (
                    id INTEGER PRIMARY KEY, source_file_id INTEGER NOT NULL,
                    external_id TEXT NOT NULL, agent TEXT NOT NULL,
                    generated_title TEXT, codex_name_origin TEXT, codex_applied_name TEXT,
                    UNIQUE(source_file_id, external_id)
                )
                """)
            try db.execute(sql: "INSERT INTO source_root VALUES (1, '/benchmark/sessions')")
            for id in 1...50_000 {
                try db.execute(sql: "INSERT INTO source_file VALUES (?, 1)", arguments: [id])
                try db.execute(sql: "INSERT INTO session (source_file_id, external_id, agent) VALUES (?, ?, 'codex')",
                               arguments: [id, "session-\(id)"])
            }
        }
        let sourceID = 25_000
        let oldArguments: StatementArguments = ["codex", "/benchmark/sessions", sourceID, sourceID]
        let newArguments: StatementArguments = [sourceID, "codex", "/benchmark/sessions"]
        let plans = try database.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + newQuery, arguments: newArguments)
                .map { $0["detail"] as String }
        }
        guard plans.contains(where: { $0.contains("source_file_id") }) else {
            throw NSError(domain: "CodexRefreshBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Per-file query did not use the source-file index: \(plans)"])
        }
        for (label, sql, arguments) in [
            ("before", oldQuery, oldArguments), ("after", newQuery, newArguments),
        ] {
            let start = Date()
            for _ in 0..<10 {
                _ = try database.read { db in
                    try Row.fetchAll(db, sql: sql, arguments: arguments).count
                }
            }
            print(String(format: "%@ %.4f s/10 queries", label, Date().timeIntervalSince(start)))
        }
        print("plan: \(plans.joined(separator: "; "))")
    }
}
