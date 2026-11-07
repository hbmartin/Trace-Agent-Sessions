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
    private final class Inputs: Sendable {
        let values: [SourceChanges]
        init(count: Int, variant: String) {
            var result: [SourceChanges] = [], oversized = SourceChanges()
            for value in 1...count {
                let stream = value.isMultiple(of: 2) ? "a" : "b"
                let path = "/tmp/mailbox/\(stream)/item-\(value)"
                var changes = SourceChanges(); changes.paths = [path]
                if variant == "oversized" || variant == "structural" {
                    changes.lexicalPaths = [path + "-link"]; changes.structuralPaths = [path + "-created"]
                }
                if variant != "mixed" || stream == "a" {
                    changes.watermarks = [stream: UInt64(value)]
                    changes.streamRoots = [stream: ["/tmp/mailbox/\(stream)"]]
                }
                if variant == "oversized" { oversized.merge(changes) }
                else { result.append(changes) }
            }
            values = variant == "oversized" ? [oversized] : result
        }
    }
    private final class Submitted: Sendable {
        let values: OSAllocatedUnfairLock<[UInt64]>
        init(count: Int) { values = .init(initialState: Array(repeating: 0, count: count)) }
        func record(_ index: Int) { values.withLock { $0[index] = DispatchTime.now().uptimeNanoseconds } }
        func snapshot(_ indices: [Int]) -> [UInt64] { values.withLock { values in indices.map { values[$0] } } }
    }
    @MainActor private final class Lifetimes {
        weak var inputs: Inputs?
        weak var submitted: Submitted?
    }
    @MainActor private final class Collector {
        var submitted: Submitted?
        let count: Int, auxiliary: Int
        let oversized: Bool
        let completion: DeliveryCompletion
        var paths: Set<String> = [], lexical: Set<String> = [], structural: Set<String> = []
        var marks: [String: UInt64] = [:], latencies: [Double] = []
        var timestampReads = 0
        init(submitted: Submitted, count: Int, auxiliary: Int, oversized: Bool, completion: DeliveryCompletion) {
            self.submitted = submitted; self.count = count; self.auxiliary = auxiliary
            self.oversized = oversized; self.completion = completion
        }
        func receive(_ changes: SourceChanges) {
            guard let submitted else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            var indices: [Int] = []
            for path in changes.paths {
                guard let last = path.split(separator: "-").last, let input = Int(last), input > 0, input <= count else {
                    completion.finish(.failure(NSError(domain: "MailboxBenchmark.invalidDeliveredPath", code: 1))); return
                }
                indices.append(input - 1)
            }
            // One bounded timestamp read per delivery; one value for an oversized callback.
            if !indices.isEmpty {
                let stamps = submitted.snapshot(oversized ? [0] : indices)
                timestampReads += 1
                for index in indices.indices {
                    let stamp = stamps[oversized ? 0 : index]
                    guard stamp > 0 else {
                        completion.finish(.failure(NSError(domain: "MailboxBenchmark.missingSubmissionStamp", code: 1))); return
                    }
                    latencies.append(Double(now - stamp) / 1e9)
                }
            }
            paths.formUnion(changes.paths); lexical.formUnion(changes.lexicalPaths); structural.formUnion(changes.structuralPaths)
            for (stream, mark) in changes.watermarks { marks[stream] = max(marks[stream] ?? 0, mark) }
            if paths.count == count && lexical.count == auxiliary && structural.count == auxiliary {
                completion.finish(.success(WorkloadStamp()))
            }
        }
        func finishMeasurements() -> [String: Any] {
            let delivery = latencies.sorted()
            var result: [String: Any] = ["deliveredPaths": paths.count, "deliveredLexicalPaths": lexical.count,
                "deliveredStructuralPaths": structural.count, "timestampReadBatches": timestampReads]
            result.merge(SourceIngressWorkload.percentiles(delivery, prefix: "delivery"), uniquingKeysWith: { _, last in last })
            // Keep the mailbox alive, but not harness-owned payload-sized storage.
            paths = []; lexical = []; structural = []; marks = [:]; latencies = []; submitted = nil
            return result
        }
        var payloadsReleased: Bool { paths.isEmpty && lexical.isEmpty && structural.isEmpty && marks.isEmpty && latencies.isEmpty && submitted == nil }
    }
    private static func percentiles(_ values: [Double], prefix: String) -> [String: Any] {
        func value(_ p: Double) -> Double { values[min(values.count - 1, Int(Double(values.count - 1) * p))] }
        return [prefix + "MedianSeconds": value(0.5), prefix + "P95Seconds": value(0.95), prefix + "MaxSeconds": values.last!]
    }
    @MainActor private struct Measured {
        let mailbox: SourceIngressMailbox
        let lifetimes: Lifetimes
        let collector: Collector
        let metrics: [String: Any]
    }
    /// This scope owns producer fixtures. It ends before retained sampling.
    @MainActor private static func measure(count: Int, variant: String,
        sampling: OSAllocatedUnfairLock<(done: Bool, active: Bool, peak: UInt64)>) async throws -> Measured {
        let inputs = Inputs(count: count, variant: variant), submitted = Submitted(count: inputs.values.count)
        let lifetimes = Lifetimes(); lifetimes.inputs = inputs; lifetimes.submitted = submitted
        let auxiliary = variant == "plain" || variant == "mixed" ? 0 : benchmarkIngressExpectedAuxiliaryCount(count)
        let completion = DeliveryCompletion()
        let collector = Collector(submitted: submitted, count: count, auxiliary: auxiliary,
            oversized: variant == "oversized", completion: completion)
        let mailbox = makeBenchmarkMailbox({ changes in collector.receive(changes) }, retired: {
            completion.finish(.failure(NSError(domain: "MailboxBenchmark.untransferredBoundary", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Mailbox retired an untransferred boundary"])))
        })
        var transferred = false
        defer { if !transferred { mailbox.close() } }
        let postSetup = footprint()
        sampling.withLock { $0.active = true; $0.peak = postSetup }
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
            var enqueue: [Double] = []; enqueue.reserveCapacity(inputs.values.count)
            let start = WorkloadStamp()
            for (index, changes) in inputs.values.enumerated() {
                if index % 128 == 0 { try Task.checkCancellation() }
                submitted.record(index)
                let call = ContinuousClock.now
                mailbox.enqueue(changes)
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
        var expected: [String: UInt64] = ["b": UInt64(count.isMultiple(of: 2) ? count - 1 : count)]
        if count > 1 { expected["a"] = UInt64(count.isMultiple(of: 2) ? count : count - 1) }
        if variant == "mixed" { expected.removeValue(forKey: "b") }
        guard collector.marks == expected else { throw NSError(domain: "MailboxBenchmark.lostWatermarks", code: 1) }
        var metrics = collector.finishMeasurements()
        metrics.merge(percentiles(result.enqueue.sorted(), prefix: "enqueue"), uniquingKeysWith: { _, last in last })
        metrics.merge(["postSetupFootprintBytes": postSetup, "preparedCallbacks": inputs.values.count,
            "expectedAuxiliaryPaths": auxiliary, "elapsedSeconds": seconds(result.start.time.duration(to: end.time)),
            "enqueueElapsedSeconds": seconds(result.start.time.duration(to: result.end.time)),
            "cpuSeconds": end.cpu - result.start.cpu,
            "cpuKind": "process CPU from first enqueue through final enqueue/delivery completion; payload setup and cleanup excluded"], uniquingKeysWith: { _, last in last })
        transferred = true
        return .init(mailbox: mailbox, lifetimes: lifetimes, collector: collector, metrics: metrics)
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            let error = error as NSError
            let failure: [String: Any] = ["status": "failed", "domain": error.domain,
                "code": error.code, "message": error.localizedDescription]
            let data = (try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys])) ?? Data("{\"status\":\"failed\"}".utf8)
            FileHandle.standardError.write(data + Data([10])); exit(1)
        }
    }
    @MainActor private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count <= 3, let count = Int(args.first ?? "1000"), count > 0 else {
            FileHandle.standardError.write(Data("Usage: source-ingress [positive event count] [label] [plain|oversized|structural|mixed]\n".utf8)); exit(2)
        }
        let label = args.dropFirst().first ?? "sample", variant = args.dropFirst(2).first ?? "plain"
        guard ["plain", "oversized", "structural", "mixed"].contains(variant) else {
            FileHandle.standardError.write(Data("Unknown mailbox workload variant: \(variant)\n".utf8)); exit(2)
        }
        let starting = footprint(), sampling = OSAllocatedUnfairLock(initialState: (done: false, active: false, peak: UInt64(0)))
        let sampler = Task.detached {
            while !sampling.withLock({ $0.done }) {
                if sampling.withLock({ $0.active }) {
                    let current = footprint(); sampling.withLock { $0.peak = max($0.peak, current) }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { sampler.cancel() }
        let measured = try await measure(count: count, variant: variant, sampling: sampling)
        defer { measured.mailbox.close() }
        // Fixtures and collector buffers have left their scope before retained sampling.
        guard measured.lifetimes.inputs == nil, measured.lifetimes.submitted == nil, measured.collector.payloadsReleased else {
            throw NSError(domain: "MailboxBenchmark.retainedFixture", code: 1)
        }
        try await Task.sleep(for: .seconds(2))
        let retained = footprint()
        sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }; try await sampler.value
        var output = measured.metrics
        output.merge(["mode": "mailbox", "variant": variant, "events": count, "label": label,
            "startingFootprintBytes": starting, "peakFootprintBytes": sampling.withLock { $0.peak },
            "retainedFootprintBytes": retained, "signedRetainedGrowthBytes": Int64(retained) - Int64(starting),
            "fixturePayloadsReleased": true, "timestampStorageReleased": true, "collectorPayloadsReleased": true,
            "memoryKind": "pre-payload starting baseline; timed-work peak; retained mailbox after fixture/collector release and two seconds idle"], uniquingKeysWith: { _, last in last })
        output.merge(benchmarkIngressMetrics(), uniquingKeysWith: { _, last in last })
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
