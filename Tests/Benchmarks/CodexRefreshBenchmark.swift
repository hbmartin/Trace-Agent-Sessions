import Foundation
import TraceCore

// Compile against a Release TraceCore.framework to compare the same workload
// across revisions. The output is seconds for 100 metadata-change events.
@main
struct CodexRefreshBenchmark {
    static func main() async throws {
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
}
