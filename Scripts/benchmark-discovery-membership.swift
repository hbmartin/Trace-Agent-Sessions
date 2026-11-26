// Compile identically against each explicitly instrumented exported revision.
import Darwin
import Foundation
import os
import TraceCore

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    } }
    precondition(code == KERN_SUCCESS); return info.phys_footprint
}
private func processCPU() -> Double {
    var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func threadCPU() -> Double {
    let thread = mach_thread_self(); defer { mach_port_deallocate(mach_task_self_, thread) }
    var info = thread_basic_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let code = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
    } }
    precondition(code == KERN_SUCCESS)
    return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
}
private func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }
@main struct DiscoveryMembershipWorkload {
    static func main() async { exit(await run()) }
    static func run() async -> Int32 {
        do {
            guard CommandLine.arguments.count == 4, let count = Int(CommandLine.arguments[1]), count > 0,
                  let scopes = Int(CommandLine.arguments[3]), scopes > 0 else {
                throw NSError(domain: "DiscoveryMembership.arguments", code: 1)
            }
            let baseline = footprint()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceDiscovery-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var payload: IndexDatabase.ReconciliationDiscoveryBenchmark? = .init(root: directory, count: count,
                scopeCount: scopes, caseSensitive: false)
            weak var lifetime = payload
            let actual = payload!.actualCaseSensitive
            let setup = footprint(), peak = OSAllocatedUnfairLock(initialState: footprint())
            let sampler = Task.detached {
                while !Task.isCancelled { peak.withLock { $0 = max($0, footprint()) }; try await Task.sleep(for: .milliseconds(50)) }
            }
            defer { sampler.cancel() }
            let measured = await Task.detached { [input = payload!] in
                let processBefore = processCPU(), threadBefore = threadCPU(), start = ContinuousClock.now
                let result = input.run()
                let elapsed = seconds(start.duration(to: .now)), threadAfter = threadCPU(), processAfter = processCPU()
                return (result.accepted, result.failures, elapsed, processAfter - processBefore, threadAfter - threadBefore)
            }.value
            payload = nil
            let released = lifetime == nil
            sampler.cancel(); _ = try? await sampler.value
            try await Task.sleep(for: .seconds(2))
            let retained = footprint(), correct = measured.0 == min(count, scopes) && measured.1 == 0 && released
            let output: [String: Any] = ["label": CommandLine.arguments[2], "files": count, "scopes": min(count, scopes),
                "accepted": measured.0, "failures": measured.1, "correct": correct, "fixtureReleased": released,
                "actualCaseSensitive": actual, "forcedScopeCaseSensitive": false,
                "elapsedSeconds": measured.2, "processCPUSeconds": measured.3, "sameThreadCPUSeconds": measured.4,
                "cpuDefinition": "one synchronous verified discovery call on a background executor; process CPU includes concurrent process threads and CPU-counter reads; same-thread CPU is separate; setup, gates, validation and idle excluded",
                "prePayloadFootprintBytes": baseline, "postSetupFootprintBytes": setup,
                "peakFootprintBytes": peak.withLock { $0 }, "retainedFootprintBytes": retained,
                "retainedGrowthBytes": Int64(retained) - Int64(baseline)]
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
            return correct ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data("Discovery membership workload failed: \(error)\n".utf8)); return 1
        }
    }
}
