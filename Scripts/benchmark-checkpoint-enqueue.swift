// Report-only optimized workload. Compile unchanged against each revision's
// Release TraceCore framework. The initial scan stays held during measurement.
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
        guard let count = Int(CommandLine.arguments.dropFirst().first ?? "1000"), count > 0 else {
            FileHandle.standardError.write(Data("Usage: checkpoint-enqueue [positive event count] [label]\n".utf8))
            exit(2)
        }
        let label = CommandLine.arguments.dropFirst(2).first ?? "sample"
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
        let result: [String: Any] = ["events": count, "label": label,
            "elapsedSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "cpuSeconds": usedCPU, "startingFootprintBytes": starting,
            "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
            "signedRetainedGrowthBytes": Int64(retained) - Int64(starting)]
        await gate.release()
        await scheduler.waitUntilIdle()
        await scheduler.stop()
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
