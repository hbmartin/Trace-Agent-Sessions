// Compile against identical exported TRACE_CHECKPOINT_BENCHMARK instrumentation.
import Darwin
import Foundation
import os
import TraceCore

private func footprint() -> UInt64 {
    var value = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return value.phys_footprint
}
private func processCPU() -> Double {
    var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func threadCPU() -> Double {
    var value = timespec(); precondition(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0)
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1e9
}
@main struct LinkDiscoveryWorkload {
    static func main() async { exit(await run()) }
    static func run() async -> Int32 {
        do {
            let args = CommandLine.arguments
            guard args.count == 4, let count = Int(args[1]), count > 0, count <= 1_000_000,
                  ["discovery-sensitive", "discovery-insensitive", "lexical-short", "lexical-deep"].contains(args[3]) else {
                throw NSError(domain: "LinkDiscovery.arguments", code: 1)
            }
            let mode = args[3], lexical = mode.hasPrefix("lexical-")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceLexical-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let before = footprint(), scopes = min(count, 1000)
            var workload: IndexDatabase.ReconciliationDiscoveryBenchmark? = .init(root: directory, count: count,
                scopeCount: scopes, caseSensitive: mode == "discovery-sensitive", depth: mode == "lexical-deep" ? 6 : 1)
            let expectedBytes = workload!.expectedLexicalBytes
            let capturedSensitive = workload!.actualCaseSensitive
            let setup = footprint(), peak = OSAllocatedUnfairLock(initialState: setup)
            let sampler = Task.detached {
                while !Task.isCancelled {
                    let current = footprint(); peak.withLock { $0 = max($0, current) }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            var elapsed = 0.0, cpu = 0.0, workerCPU = 0.0, correct = true
            for _ in 0..<5 {
                let startCPU = processCPU(), startThread = threadCPU(), start = ContinuousClock.now
                let observed: (Int, Int)
                if lexical {
                    let result = workload!.lexical(); observed = (result.accepted, result.bytes)
                } else {
                    let result = workload!.run(); observed = (result.accepted, result.failures)
                }
                let duration = start.duration(to: .now)
                workerCPU += threadCPU() - startThread; cpu += processCPU() - startCPU
                elapsed += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                correct = correct && observed.0 == (lexical ? count : scopes) && observed.1 == (lexical ? expectedBytes : 0)
            }
            workload = nil
            sampler.cancel(); _ = try? await sampler.value
            try await Task.sleep(for: .seconds(2))
            let retained = footprint()
            let result: [String: Any] = ["label": args[2], "mode": mode, "count": count, "iterations": 5,
                "workloadKind": lexical ? "captured lexical mapping" : "captured scoped discovery verification",
                "actualRootCaseSensitive": capturedSensitive, "forcedCaseSensitive": mode == "discovery-sensitive",
                "elapsedSeconds": elapsed, "processCPUSeconds": cpu, "executionThreadCPUSeconds": workerCPU,
                "cpuDefinition": "Process CPU includes sampler; thread CPU covers synchronous work on its execution thread. Both exclude setup, validation, controls and idle.",
                "prePayloadFootprintBytes": before, "postSetupFootprintBytes": setup,
                "peakFootprintBytes": peak.withLock { $0 }, "retainedFootprintBytes": retained,
                "retainedGrowthBytes": Int64(retained) - Int64(before), "correct": correct]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            return correct ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data(("Link discovery workload failed: \(error)\n").utf8))
            return 1
        }
    }
}
