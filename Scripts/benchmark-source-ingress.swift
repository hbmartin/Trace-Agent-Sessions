// Compiled with the exact revision's extracted mailbox, never a copied implementation.
import Darwin
import Foundation
import os
import TraceCore

private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return info.phys_footprint
}
private func cpuSeconds() -> Double {
    var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func seconds(_ duration: Duration) -> Double {
    let value = duration.components
    return Double(value.seconds) + Double(value.attoseconds) / 1e18
}
private actor StartGate {
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func open() { released = true; continuation?.resume(); continuation = nil }
}
@main struct SourceIngressWorkload {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count <= 2, let count = Int(args.first ?? "1000"), count > 0 else {
            FileHandle.standardError.write(Data("Usage: source-ingress [positive event count] [label]\n".utf8)); exit(2)
        }
        let label = args.dropFirst().first ?? "sample"
        var paths: Set<String> = [], latencies: [Double] = [], marks: [String: UInt64] = [:]
        let mailbox = makeBenchmarkMailbox { changes in
            let now = DispatchTime.now().uptimeNanoseconds
            for path in changes.paths {
                let stamp = UInt64(path.split(separator: "-").last!)!
                latencies.append(Double(now - stamp) / 1e9)
            }
            paths.formUnion(changes.paths)
            for (stream, mark) in changes.watermarks { marks[stream] = max(marks[stream] ?? 0, mark) }
        }
        let starting = footprint(), sampling = OSAllocatedUnfairLock(initialState: (done: false, peak: starting))
        let sampler = Task.detached {
            while !sampling.withLock({ $0.done }) {
                let current = footprint(); sampling.withLock { $0.peak = max($0.peak, current) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let gate = StartGate()
        let producer = Task.detached {
            await gate.wait() // Control handshake completes before measurement.
            let start = ContinuousClock.now, cpu = cpuSeconds()
            var enqueue: [Double] = []
            for value in 1...count {
                var changes = SourceChanges()
                changes.paths = ["/tmp/mailbox/item-\(value)-\(DispatchTime.now().uptimeNanoseconds)"]
                changes.watermarks = [value.isMultiple(of: 2) ? "a" : "b": UInt64(value)]
                let call = ContinuousClock.now
                mailbox.enqueue(changes)
                enqueue.append(seconds(call.duration(to: .now)))
            }
            return (start, cpu, enqueue, seconds(start.duration(to: .now)))
        }
        await gate.open()
        let result = await producer.value
        let deadline = ContinuousClock.now + .seconds(30)
        while paths.count != count {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "MailboxBenchmark.incompleteDelivery", code: 1) }
            await Task.yield()
        }
        let elapsed = seconds(result.0.duration(to: .now)), cpu = cpuSeconds() - result.1
        let expectedA = count.isMultiple(of: 2) ? count : count - 1
        guard marks["b"] == UInt64(count.isMultiple(of: 2) ? count - 1 : count), expectedA == 0 || marks["a"] == UInt64(expectedA) else {
            throw NSError(domain: "MailboxBenchmark.lostWatermarks", code: 1)
        }
        try await Task.sleep(for: .seconds(2))
        let retained = footprint(); sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }; try await sampler.value
        mailbox.close()
        let enqueue = result.2.sorted(), delivery = latencies.sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double { values[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        let output: [String: Any] = ["mode": "mailbox", "events": count, "label": label, "deliveredPaths": paths.count,
            "elapsedSeconds": elapsed, "enqueueElapsedSeconds": result.3, "cpuSeconds": cpu, "cpuKind": "process CPU during enqueue and drain",
            "enqueueMedianSeconds": percentile(enqueue, 0.5), "enqueueP95Seconds": percentile(enqueue, 0.95), "enqueueMaxSeconds": enqueue.last!,
            "deliveryMedianSeconds": percentile(delivery, 0.5), "deliveryP95Seconds": percentile(delivery, 0.95), "deliveryMaxSeconds": delivery.last!,
            "startingFootprintBytes": starting, "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
            "signedRetainedGrowthBytes": Int64(retained) - Int64(starting)]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
