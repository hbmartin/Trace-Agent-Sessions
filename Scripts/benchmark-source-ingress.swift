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
private struct WorkloadStamp: Sendable {
    let time = ContinuousClock.now
    let cpu = cpuSeconds()
}
/// One workload owns this completion. Cancellation terminates the entire
/// workload; this is not an independent multi-waiter promise.
@MainActor
private final class DeliveryCompletion {
    private var result: Result<WorkloadStamp, Error>?
    private var waiters: [CheckedContinuation<WorkloadStamp, Error>] = []
    func finish(_ result: Result<WorkloadStamp, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiters = self.waiters; self.waiters = []
        for waiter in waiters { waiter.resume(with: result) }
    }
    func wait() async throws -> WorkloadStamp {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters.append(continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
}
@MainActor
private func mailboxDeadline(_ completion: DeliveryCompletion, after duration: Duration,
                             phase: String, message: String,
                             unless completed: @Sendable () -> Bool = { false }) async {
    do { try await Task.sleep(for: duration) }
    catch { return }
    guard !completed() else { return }
    completion.finish(.failure(NSError(domain: "MailboxBenchmark." + phase, code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])))
}
@main struct SourceIngressWorkload {
    @MainActor static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count <= 3, let count = Int(args.first ?? "1000"), count > 0 else {
            FileHandle.standardError.write(Data("Usage: source-ingress [positive event count] [label] [plain|oversized|structural]\n".utf8)); exit(2)
        }
        let label = args.dropFirst().first ?? "sample"
        let variant = args.dropFirst(2).first ?? "plain"
        guard ["plain", "oversized", "structural"].contains(variant) else {
            FileHandle.standardError.write(Data("Unknown mailbox workload variant: \(variant)\n".utf8)); exit(2)
        }
        let auxiliaryCount = variant == "plain" ? 0 : count
        let completion = DeliveryCompletion()
        var paths: Set<String> = [], lexical: Set<String> = [], structural: Set<String> = []
        var latencies: [Double] = [], marks: [String: UInt64] = [:]
        let mailbox = makeBenchmarkMailbox { changes in
            let now = DispatchTime.now().uptimeNanoseconds
            for path in changes.paths {
                let stamp = UInt64(path.split(separator: "-").last!)!
                latencies.append(Double(now - stamp) / 1e9)
            }
            paths.formUnion(changes.paths); lexical.formUnion(changes.lexicalPaths); structural.formUnion(changes.structuralPaths)
            for (stream, mark) in changes.watermarks { marks[stream] = max(marks[stream] ?? 0, mark) }
            if paths.count == count && lexical.count == auxiliaryCount && structural.count == auxiliaryCount {
                // Capture the boundary before waking the waiting harness.
                completion.finish(.success(WorkloadStamp()))
            }
        }
        let starting = footprint(), sampling = OSAllocatedUnfairLock(initialState: (done: false, peak: starting))
        let sampler = Task.detached {
            while !sampling.withLock({ $0.done }) {
                let current = footprint(); sampling.withLock { $0.peak = max($0.peak, current) }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { mailbox.close(); sampler.cancel() }
        let producerFinished = OSAllocatedUnfairLock(initialState: false)
        let timeout = Task {
            await mailboxDeadline(completion, after: .seconds(30), phase: "producerTimeout",
                message: "Timed out while enqueueing mailbox events", unless: { producerFinished.withLock { $0 } })
        }
        defer { timeout.cancel() }
        let gate = StartGate()
        let producer = Task.detached {
            await gate.wait() // Control handshake completes before measurement.
            defer { producerFinished.withLock { $0 = true } }
            let start = WorkloadStamp()
            var enqueue: [Double] = []
            var oversized = SourceChanges()
            for value in 1...count {
                if value % 128 == 1 { try Task.checkCancellation() }
                var changes = SourceChanges()
                let stream = value.isMultiple(of: 2) ? "a" : "b"
                let path = "/tmp/mailbox/\(stream)/item-\(value)-\(DispatchTime.now().uptimeNanoseconds)"
                changes.paths = [path]
                if variant != "plain" { changes.lexicalPaths = [path + "-link"]; changes.structuralPaths = [path + "-created"] }
                changes.watermarks = [stream: UInt64(value)]
                changes.streamRoots = [stream: ["/tmp/mailbox/\(stream)"]]
                if variant == "oversized" { oversized.merge(changes) }
                else {
                    let call = ContinuousClock.now
                    mailbox.enqueue(changes)
                    enqueue.append(seconds(call.duration(to: .now)))
                }
            }
            if variant == "oversized" {
                let call = ContinuousClock.now; mailbox.enqueue(oversized)
                enqueue.append(seconds(call.duration(to: .now)))
            }
            return (start: start, enqueue: enqueue, end: WorkloadStamp())
        }
        let deliveryDeadline = Task {
            do { _ = try await producer.value }
            catch { completion.finish(.failure(error)); return }
            timeout.cancel()
            await mailboxDeadline(completion, after: .seconds(30), phase: "incompleteDelivery",
                message: "Timed out waiting for final mailbox delivery after enqueueing")
        }
        defer { producer.cancel(); deliveryDeadline.cancel() }
        await gate.open()
        let delivered = try await completion.wait()
        let result = try await producer.value
        timeout.cancel()
        let end = delivered.time > result.end.time ? delivered : result.end
        let elapsed = seconds(result.start.time.duration(to: end.time)), cpu = end.cpu - result.start.cpu
        let expectedA = count.isMultiple(of: 2) ? count : count - 1
        guard marks["b"] == UInt64(count.isMultiple(of: 2) ? count - 1 : count), expectedA == 0 || marks["a"] == UInt64(expectedA) else {
            throw NSError(domain: "MailboxBenchmark.lostWatermarks", code: 1)
        }
        try await Task.sleep(for: .seconds(2))
        let retained = footprint(); sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }; try await sampler.value
        mailbox.close()
        let enqueue = result.enqueue.sorted(), delivery = latencies.sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double { values[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        var output: [String: Any] = ["mode": "mailbox", "variant": variant, "events": count, "label": label, "deliveredPaths": paths.count,
            "deliveredLexicalPaths": lexical.count, "deliveredStructuralPaths": structural.count,
            "elapsedSeconds": elapsed, "enqueueElapsedSeconds": seconds(result.start.time.duration(to: result.end.time)),
            "cpuSeconds": cpu, "cpuKind": "process CPU from first enqueue through final enqueue/delivery completion",
            "enqueueMedianSeconds": percentile(enqueue, 0.5), "enqueueP95Seconds": percentile(enqueue, 0.95), "enqueueMaxSeconds": enqueue.last!,
            "deliveryMedianSeconds": percentile(delivery, 0.5), "deliveryP95Seconds": percentile(delivery, 0.95), "deliveryMaxSeconds": delivery.last!,
            "startingFootprintBytes": starting, "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
            "signedRetainedGrowthBytes": Int64(retained) - Int64(starting)]
        output.merge(benchmarkIngressMetrics(), uniquingKeysWith: { _, last in last })
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
