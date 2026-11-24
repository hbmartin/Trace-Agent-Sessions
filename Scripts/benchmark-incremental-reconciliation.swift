// Optimized standalone workload; compile against the identically instrumented revision.
import Darwin
import Foundation
import os
import TraceCore

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(code == KERN_SUCCESS)
    return info.phys_footprint
}
private func cpu() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}
private func seconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
}
private func record(_ session: String, _ index: Int) -> Data {
    Data("{\"type\":\"user\",\"uuid\":\"\(session)-\(index)\",\"sessionId\":\"\(session)\",\"message\":{\"content\":\"message \(index)\"}}\n".utf8)
}
@main struct IncrementalReconciliationWorkload {
    static func main() async { exit(await run()) }
    static func run() async -> Int32 {
        do {
            let mode = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "ascii"
            guard (3...4).contains(CommandLine.arguments.count), let count = Int(CommandLine.arguments[1]),
                  count > 0, count < Int.max, ["ascii", "unicode", "query-insensitive", "query-unicode"].contains(mode) else {
                throw NSError(domain: "IncrementalReconciliation.arguments", code: 1)
            }
            let before = footprint()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceIncremental-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let roots = [directory.appendingPathComponent("sessions"), directory.appendingPathComponent("other")]
            for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            for index in 0..<count {
                let prefix = mode == "query-unicode" ? "caf\u{00e9}-" : ""
                try record("unrelated-\(index)", 0).write(to: roots[index % 2].appendingPathComponent(prefix + "unrelated-\(index).jsonl"))
            }
            let selected = roots[0].appendingPathComponent(mode == "unicode" ? "caf\u{00e9}.jsonl" : "selected.jsonl")
            try record("selected", 0).write(to: selected)
            let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
            let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: roots)])
            await coordinator.indexAll(scope: .proseOnly)
            let expectedSessions = try await database.statistics().sessionCount
            var initial = try await database.sessions(limit: count + 1)
            guard let selectedID = initial.first(where: { $0.sourcePath == TraceFileIO.canonicalPath(selected.path).path })?.id else {
                throw NSError(domain: "IncrementalReconciliation.setup", code: 1)
            }
            initial = []
            let queryMode = mode.hasPrefix("query-")
            let queryCount = min((count + 1) / 2, 1000)
            let queryScopes = (0..<queryCount).map { index in
                roots[0].path + "/" + (mode == "query-unicode"
                    ? "caf\u{00e9}-unrelated-\(index * 2).jsonl" : "UNRELATED-\(index * 2).JSONL")
            }
            let queryRoot = try await database.reconciliationBenchmarkRoot(roots[0])
            let setup = footprint(), rowsBefore = database.reconciliationBenchmarkDecodedRows
            let peak = OSAllocatedUnfairLock(initialState: setup)
            let sampler = Task.detached {
                while !Task.isCancelled {
                    let current = footprint()
                    peak.withLock { $0 = max($0, current) }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            var elapsed = 0.0, processCPU = 0.0, durations: [Double] = []
            var correct = expectedSessions == count + 1
            let iterations = queryMode ? 1 : 100
            if queryMode {
                let cpuStart = cpu(), start = ContinuousClock.now
                let matches = try await database.reconciliationBenchmarkQuery(rootID: queryRoot,
                    scopes: queryScopes, caseSensitive: mode == "query-unicode")
                elapsed = seconds(start.duration(to: .now)); processCPU = cpu() - cpuStart
                durations = [elapsed]; correct = correct && matches == queryCount
            }
            for index in queryMode ? [] : Array(1...iterations) {
                // File production, validation and actor handshakes are outside execution timing.
                let writer = try FileHandle(forWritingTo: selected)
                try writer.seekToEnd(); try writer.write(contentsOf: record("selected", index)); try writer.close()
                let terminal = OSAllocatedUnfairLock<IndexProgress?>(initialState: nil)
                let cpuStart = cpu(), start = ContinuousClock.now
                await coordinator.refresh(paths: [selected.path], scope: .proseOnly, progress: { value in
                    if value.phase == .complete { terminal.withLock { $0 = value } }
                })
                let duration = seconds(start.duration(to: .now))
                processCPU += cpu() - cpuStart; elapsed += duration; durations.append(duration)
                correct = correct && terminal.withLock { $0?.totalFiles == 1 && $0?.failedFiles == 0 }
            }
            let decoded = database.reconciliationBenchmarkDecodedRows - rowsBefore
            let messages = try await database.messages(sessionID: selectedID)
            let final = try await database.statistics()
            correct = correct && messages.count == (queryMode ? 1 : iterations + 1) && final.sessionCount == count + 1
            durations.sort()
            let p95 = durations[Int(ceil(0.95 * Double(durations.count))) - 1]
            durations = []
            sampler.cancel(); _ = try? await sampler.value
            try await Task.sleep(for: .seconds(2))
            let retained = footprint()
            let output: [String: Any] = ["label": CommandLine.arguments[2], "mode": mode, "unrelatedSources": count,
                "iterations": iterations, "queryScopeCount": queryMode ? queryCount : 0, "elapsedSeconds": elapsed, "processCPUSeconds": processCPU,
                "cpuDefinition": "process-wide CPU during coordinator refresh or one scoped-query await; includes executor entry, excludes setup, validation, retirement and idle",
                "refreshP95Seconds": p95, "decodedReconciliationRows": decoded,
                "prePayloadFootprintBytes": before, "postSetupFootprintBytes": setup,
                "peakFootprintBytes": peak.withLock { $0 }, "retainedFootprintBytes": retained,
                "retainedGrowthBytes": Int64(retained) - Int64(before), "correct": correct]
            withExtendedLifetime(database) {}
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
            return correct ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data(("Incremental reconciliation failed: \(error)\n").utf8))
            return 1
        }
    }
}
