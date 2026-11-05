// Report-only optimized workload. Compile unchanged against each revision's
// Release TraceCore framework. Enqueue holds a scan; acceptance releases a
// completed scan while the main actor reserves another stream’s inputs.
import Darwin
import Foundation
import os
import TraceCore

private actor ScanGate {
    var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        guard !released else { return }
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS, "task_info failed: \(result)")
    return info.phys_footprint
}

private func cpuSeconds() -> Double {
    var value = rusage()
    precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}

@main struct CheckpointEnqueueWorkload {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let count = Int(arguments.first ?? "1000"), count > 0,
              arguments.count <= 3,
              arguments.count < 3 || ["enqueue", "acceptance"].contains(arguments[2]) else {
            FileHandle.standardError.write(Data("Usage: checkpoint-enqueue [positive event count] [label] [enqueue|acceptance]\n".utf8))
            exit(2)
        }
        let label = arguments.dropFirst().first ?? "sample"
        let mode = arguments.dropFirst(2).first ?? "enqueue"
        if mode == "acceptance" {
            try await measureAcceptance(count: count, label: label)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceCheckpointBenchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"type":"user","uuid":"m","sessionId":"s","cwd":"/tmp/CheckpointBenchmark","timestamp":"2026-01-01T00:00:00Z","message":{"content":"checkpoint workload"}}"# + "\n"
        try Data(line.utf8).write(to: root.appendingPathComponent("session.jsonl"))
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        let gate = ScanGate()
        let scheduler = IndexScheduler(coordinator: coordinator, scope: .proseOnly, progress: { update in
            if update.phase == .discovering { await gate.pause() }
        })
        await scheduler.request(reconcile: true)
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "CheckpointBenchmark.scanGate", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let starting = footprint()
        let sampling = OSAllocatedUnfairLock(initialState: (done: false, peak: starting))
        let sampler = Task.detached {
            while !sampling.withLock({ $0.done }) {
                let current = footprint()
                sampling.withLock { $0.peak = max($0.peak, current) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let cpu = cpuSeconds(), start = ContinuousClock.now
        for value in 1...count {
            await scheduler.request(watermarks: ["stream": UInt64(value)], streamRoots: ["stream": [root.path]])
        }
        let elapsed = start.duration(to: .now).components
        let usedCPU = cpuSeconds() - cpu
        try await Task.sleep(for: .seconds(2))
        let retained = footprint()
        sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }
        try await sampler.value
        let result: [String: Any] = ["events": count, "label": label, "mode": "enqueue",
            "elapsedSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "cpuSeconds": usedCPU, "startingFootprintBytes": starting,
            "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
            "signedRetainedGrowthBytes": Int64(retained) - Int64(starting)]
        await gate.release()
        await scheduler.waitUntilIdle()
        await scheduler.stop()
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    @MainActor
    private static func reserveIngress(ledger: IndexCheckpointLedger, gate: ScanGate,
                                       root: String, count: Int) async -> [Double] {
        var latencies: [Double] = []
        latencies.reserveCapacity(count)
        for value in 1...count {
            let start = ContinuousClock.now
            _ = ledger.reserve(watermarks: ["probe": UInt64(value)],
                streamRoots: ["probe": [root]], hasIndexWork: false)
            latencies.append(seconds(start.duration(to: .now)))
            // Reservation timing ended above. This handshake is outside both
            // reservation and instrumented acceptance execution measurements.
            if value == 1 { await gate.release() }
            await Task.yield()
        }
        return latencies
    }

    private static func measureAcceptance(count: Int, label: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceCheckpointAcceptance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("session.jsonl")
        let line = #"{"type":"user","uuid":"m","sessionId":"s","cwd":"/tmp/CheckpointBenchmark","timestamp":"2026-01-01T00:00:00Z","message":{"content":"checkpoint workload"}}"# + "\n"
        try Data(line.utf8).write(to: source)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
        let ledger = IndexCheckpointLedger()
        ledger.seed(stream: "stream", checkpoint: nil)
        ledger.seed(stream: "probe", checkpoint: nil)
        let setupStart = ContinuousClock.now
        for value in 1...count {
            _ = ledger.reserve(watermarks: ["stream": UInt64(value)],
                streamRoots: ["stream": [root.path]], hasIndexWork: true, paths: [source.path])
        }
        let setupSeconds = seconds(setupStart.duration(to: .now))
        let gate = ScanGate()
        let accepted = OSAllocatedUnfairLock(initialState: [String: UInt64]())
        let scheduler = IndexScheduler(coordinator: coordinator, scope: .proseOnly, progress: { update in
            if update.phase == .complete { await gate.pause() }
        }, checkpointLedger: ledger, didCompleteCheckpoints: { updates in
            accepted.withLock { values in
                for (stream, checkpoint) in updates {
                    values[stream] = max(values[stream] ?? 0, checkpoint.value)
                }
            }
        })
        await scheduler.request(reconcile: true)
        let deadline = ContinuousClock.now + .seconds(30)
        while !(await gate.entered) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "CheckpointBenchmark.acceptanceGate", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let starting = footprint()
        let sampling = OSAllocatedUnfairLock(initialState: (done: false, peak: starting))
        let sampler = Task.detached {
            while !sampling.withLock({ $0.done }) {
                let current = footprint()
                sampling.withLock { $0.peak = max($0.peak, current) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        CheckpointAcceptanceBenchmark.reset()
        let probeCount = 1_000
        let latencies = await reserveIngress(ledger: ledger, gate: gate, root: root.path, count: probeCount)
        await scheduler.waitUntilIdle()
        // Deliver only metadata qualification. This cannot rescue lost indexing
        // coverage with another scan, and performs no coordinator pass.
        await scheduler.request(watermarks: ["probe": UInt64(probeCount)],
            streamRoots: ["probe": [root.path]])
        await scheduler.waitUntilIdle()
        let measurement = CheckpointAcceptanceBenchmark.snapshot()
        let counts = await scheduler.checkpointBenchmarkCounts()
        let final = accepted.withLock { $0 }
        guard final["stream"] == UInt64(count), final["probe"] == UInt64(probeCount) else {
            throw NSError(domain: "CheckpointBenchmark.incompleteCoverage", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Measured work did not cover every stream"])
        }
        try await Task.sleep(for: .seconds(2))
        let retained = footprint()
        sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }
        try await sampler.value
        let ordered = latencies.sorted()
        func percentile(_ fraction: Double) -> Double {
            ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * fraction))]
        }
        let result: [String: Any] = ["events": count, "label": label, "mode": "acceptance",
            "probeCount": probeCount, "setupSeconds": setupSeconds,
            "elapsedSeconds": measurement["elapsedSeconds"]!, "cpuSeconds": measurement["cpuSeconds"]!,
            "timingKind": "sum of instrumented acceptance execution intervals",
            "acceptanceTurns": measurement["acceptanceTurns"]!, "retainedLedgerState": counts,
            "mainActorReservationSeconds": latencies,
            "mainActorReservationMedianSeconds": percentile(0.5),
            "mainActorReservationP95Seconds": percentile(0.95),
            "mainActorReservationP99Seconds": percentile(0.99),
            "mainActorReservationMaxSeconds": ordered.last!,
            "acceptedWatermarks": final, "startingFootprintBytes": starting,
            "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
            "signedRetainedGrowthBytes": Int64(retained) - Int64(starting)]
        await scheduler.stop()
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }

}
