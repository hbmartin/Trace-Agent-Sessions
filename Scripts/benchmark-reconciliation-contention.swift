// Identical exported instrumentation and harness are required for both revisions.
import Darwin
import Foundation
import os
import TraceCore

private func memory() -> UInt64 {
    var value = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &value) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    } }; precondition(result == KERN_SUCCESS); return value.phys_footprint
}
private func cpu() -> Double {
    var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }
private actor StartGate {
    private var arrived = 0
    private var workers: [CheckedContinuation<Void, Never>] = []
    private var ready: CheckedContinuation<Void, Never>?
    func wait() async {
        arrived += 1
        if arrived == 2 { ready?.resume(); ready = nil }
        await withCheckedContinuation { workers.append($0) }
    }
    func waitUntilReady() async { if arrived < 2 { await withCheckedContinuation { ready = $0 } } }
    func release() { workers.forEach { $0.resume() }; workers = [] }
}
private struct Span: Sendable {
    let kind: String
    let start: ContinuousClock.Instant, end: ContinuousClock.Instant
    let cpuBefore: Double, cpuAfter: Double
    let completed: Int
    let latencies: [Double]
}
private func measuredUnion(_ spans: [Span]) -> (Double, Double) {
    let sorted = spans.sorted { $0.start < $1.start }
    precondition(sorted.count == 2)
    let first = sorted[0], second = sorted[1]
    if first.end >= second.start {
        let last = first.end >= second.end ? first : second
        return (seconds(first.start.duration(to: last.end)), last.cpuAfter - first.cpuBefore)
    }
    return (seconds(first.start.duration(to: first.end)) + seconds(second.start.duration(to: second.end)),
        first.cpuAfter - first.cpuBefore + second.cpuAfter - second.cpuBefore)
}
@main struct ReconciliationContentionWorkload {
    static func main() async { exit(await run()) }
    static func run() async -> Int32 {
        do {
            guard CommandLine.arguments.count == 3, let count = Int(CommandLine.arguments[1]), count > 0, count < Int.max else {
                throw NSError(domain: "ReconciliationContention.arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected a positive file count and a revision label."])
            }
            let before = memory(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceContention-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let root = directory.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            func data(_ session: String) -> Data { Data("{\"type\":\"user\",\"uuid\":\"m\",\"sessionId\":\"\(session)\",\"message\":{\"content\":\"content\"}}\n".utf8) }
            for index in 0..<count { try data("s-\(index)").write(to: root.appendingPathComponent("café-\(index).jsonl")) }
            let selected = root.appendingPathComponent("selected.jsonl");try data("selected").write(to: selected)
            let path = TraceFileIO.canonicalPath(selected.path).path
            let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
            await IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])]).indexAll(scope: .proseOnly)
            let initial = try await database.statistics()
            guard initial.sessionCount == count + 1 else { throw NSError(domain: "ReconciliationContention.setup", code: 1) }
            let rootID = try await database.reconciliationBenchmarkRoot(root)
            let mtime = try database.reconciliationBenchmarkMtime(path: path)
            guard mtime >= 0 else { throw NSError(domain: "ReconciliationContention.sourceMissing", code: 1) }
            let setup = memory(), peak = OSAllocatedUnfairLock(initialState: memory())
            let sampler = Task.detached {
                while !Task.isCancelled { peak.withLock { $0 = max($0, memory()) };try await Task.sleep(for: .milliseconds(50)) }
            }
            defer { sampler.cancel() }
            let gate = StartGate()
            let spans = try await withThrowingTaskGroup(of: Span.self) { group in
                group.addTask {
                    await gate.wait()
                    let cpuBefore = cpu(), start = ContinuousClock.now
                    var completed = 0, latencies: [Double] = []
                    for _ in 0..<100 {
                        let call = ContinuousClock.now
                        completed += try await database.reconciliationBenchmarkQuery(rootID: rootID, scopes: [path], caseSensitive: true)
                        latencies.append(seconds(call.duration(to: .now)))
                    }
                    let end = ContinuousClock.now, cpuAfter = cpu()
                    return Span(kind: "query", start: start, end: end, cpuBefore: cpuBefore, cpuAfter: cpuAfter, completed: completed, latencies: latencies)
                }
                group.addTask {
                    await gate.wait()
                    let cpuBefore = cpu(), start = ContinuousClock.now
                    var latencies: [Double] = []
                    for _ in 0..<100 {
                        let call = ContinuousClock.now
                        try database.reconciliationBenchmarkWrite(path: path)
                        latencies.append(seconds(call.duration(to: .now)))
                    }
                    let end = ContinuousClock.now, cpuAfter = cpu()
                    return Span(kind: "writer", start: start, end: end, cpuBefore: cpuBefore, cpuAfter: cpuAfter, completed: 100, latencies: latencies)
                }
                // All control handshakes precede the worker execution intervals.
                await gate.waitUntilReady(); await gate.release()
                var results: [Span] = []
                for try await result in group { results.append(result) }
                return results
            }
            let totals = measuredUnion(spans)
            let queries = spans.first { $0.kind == "query" }!, writes = spans.first { $0.kind == "writer" }!
            let endingMtime = try database.reconciliationBenchmarkMtime(path: path)
            let final = try await database.statistics()
            let correct = queries.completed == 100 && writes.completed == 100 && endingMtime == mtime + 100 && final.sessionCount == count + 1
            let state = await database.reconciliationBenchmarkState()
            sampler.cancel(); _ = try? await sampler.value
            try await Task.sleep(for: .seconds(2))
            let idle = memory()
            func p95(_ values: [Double]) -> Double { values.sorted()[Int(ceil(0.95 * Double(values.count))) - 1] }
            let output: [String: Any] = ["label": CommandLine.arguments[2], "files": count, "correct": correct,
                "forcedQueryCaseSensitive": true, "actualRootCaseSensitive": database.reconciliationBenchmarkCaseSensitive(root.path),
                "elapsedSeconds": totals.0, "processCPUSeconds": totals.1,
                "cpuDefinition": "union of two contiguous worker intervals after the start gate; process-wide CPU; includes query queueing and latency sampling; overlapping intervals counted once; setup, gates, validation and idle excluded",
                "queryP95Seconds": p95(queries.latencies), "writerP95Seconds": p95(writes.latencies),
                "queries": queries.completed, "writes": writes.completed, "queryState": state,
                "prePayloadFootprintBytes": before, "postSetupFootprintBytes": setup,
                "peakFootprintBytes": peak.withLock { $0 }, "retainedFootprintBytes": idle,
                "retainedGrowthBytes": Int64(idle) - Int64(before)]
            withExtendedLifetime(database) {}
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
            return correct ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data("Reconciliation contention failed: \(error)\n".utf8));return 1
        }
    }
}
