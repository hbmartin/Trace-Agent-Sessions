import Darwin
import Foundation
import os
import TraceCore

private func memoryBytes() -> UInt64 {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    } }
    precondition(result == KERN_SUCCESS); return info.phys_footprint
}
private func processCPU() -> Double {
    var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private actor LedgerStart {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !open { await withCheckedContinuation { waiter = $0 } } }
    func release() { open = true; waiter?.resume(); waiter = nil }
}
private func seconds(_ d: Duration) -> Double { let v = d.components; return Double(v.seconds) + Double(v.attoseconds) / 1e18 }
// Nearest-rank percentile: the first rank whose cumulative fraction reaches p.
func nearestRankPercentile(_ sorted: [Double], fraction: Double) -> Double {
    precondition(!sorted.isEmpty && fraction > 0 && fraction <= 1)
    return sorted[max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))]
}
@main struct NavigationRecoveryBenchmark {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4, let count = Int(CommandLine.arguments[1]), count > 0,
                  ["coverage", "target", "ledger-short", "ledger-long", "contention-short", "contention-long"].contains(CommandLine.arguments[3]) else {
                throw NSError(domain: "NavigationBenchmark.arguments", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected a positive count, label, and coverage|target|ledger-short|ledger-long|contention-short|contention-long mode"])
            }
            let mode = CommandLine.arguments[3], label = CommandLine.arguments[2]
            let beforeFixtures = memoryBytes()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceNavigationBenchmark-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
            let sampling = OSAllocatedUnfairLock(initialState: (done: false, active: false, peak: beforeFixtures))
            let sampler = Task.detached {
                while !sampling.withLock({ $0.done }) {
                    if sampling.withLock({ $0.active }) {
                        let bytes = memoryBytes(); sampling.withLock { $0.peak = max($0.peak, bytes) }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            var elapsed = 0.0, cpu = 0.0, reads = 0, publications = 0, retainedEntries = 0
            var latencies: [Double] = []
            var retainedCoverage: IndexNavigationCoverage?
            var retainedLedger: IndexNavigationWorkLedger?
            var ledgerCounts: [String: Int] = [:]
            var observationMetrics: [String: Double] = [:]
            var postSetup: UInt64 = 0
            if mode == "coverage" {
                var coverage = IndexNavigationCoverage.benchmarkFixture(generation: database.contentGeneration,
                    names: (0..<count).map { "file-\($0).jsonl" }, covered: true)
                guard (0..<count).allSatisfy({ coverage.benchmarkCovers("file-\($0).jsonl") }) else {
                    throw NSError(domain: "NavigationBenchmark.initialCoverageCorrectness", code: 1)
                }
                var deltas: [IndexNavigationCoverage]? = (0..<count).map {
                    .benchmarkFixture(generation: database.contentGeneration, names: ["file-\($0).jsonl"], covered: false)
                }
                let starting = memoryBytes(); postSetup = starting
                sampling.withLock { $0.active = true; $0.peak = starting }
                let startCPU = processCPU(), start = ContinuousClock.now
                for delta in deltas! {
                    let call = ContinuousClock.now
                    coverage = coverage.merging(delta)
                    latencies.append(seconds(call.duration(to: .now)))
                }
                elapsed = seconds(start.duration(to: .now)); cpu = processCPU() - startCPU
                let ending = memoryBytes(); sampling.withLock { $0.peak = max($0.peak, ending) }
                // Correctness reads/exports are outside timing. Resolution supplies
                // opaque references through the public interface below instead of
                // constructing a navigation reference from display text.
                guard coverage.contentGeneration == database.contentGeneration else { throw CancellationError() }
                guard (0..<count).allSatisfy({ !coverage.benchmarkCovers("file-\($0).jsonl") }) else {
                    throw NSError(domain: "NavigationBenchmark.coverageCorrectness", code: 1)
                }
                retainedEntries = count
                deltas = nil
                retainedCoverage = coverage
            } else if mode.hasPrefix("ledger-") || mode.hasPrefix("contention-") {
                let ledger = IndexNavigationWorkLedger(), count = max(2, count)
                var names: [String]? = (0..<count).map { index in
                    (mode.hasSuffix("long") ? String(repeating: "long-path-component/", count: 8) : "") + "file-\(index).jsonl"
                }
                var admissions: [(@Sendable () -> [IndexNavigationWork])]? = names!.map { name in
                    ledger.benchmarkAdmission([TraceFileIO.canonicalPath("/tmp/navigation-cache/" + name)])
                }
                // Prepared fixtures and canonicalization precede all timed calls.
                var firstCoverage: IndexNavigationCoverage? = .benchmarkFixture(generation: database.contentGeneration,
                    names: mode.hasPrefix("contention-") ? Array(names!.prefix(count / 2)) : names!, covered: true)
                var laterCoverage: IndexNavigationCoverage? = .benchmarkFixture(generation: database.contentGeneration,
                    names: Array(names!.dropFirst(count / 2)), covered: true)
                var firstWork: [IndexNavigationWork] = [], laterWork: [IndexNavigationWork] = []
                let half = mode.hasPrefix("contention-") ? count / 2 : 0
                for index in 0..<half { firstWork += admissions![index]() }
                let gate = LedgerStart()
                let initial = firstCoverage!, enrolled = firstWork
                let observation: Task<Void, Never>?
                if half > 0 {
                    observation = Task.detached {
                        await gate.wait()
                        ledger.benchmarkObserve(initial, work: enrolled)
                    }
                } else { observation = nil }
                CheckpointAcceptanceBenchmark.reset()
                let starting = memoryBytes(); postSetup = starting
                sampling.withLock { $0.active = true; $0.peak = starting }
                // Release synchronization is outside process/elapsed intervals;
                // observation execution has its own same-thread instrumentation.
                await gate.release()
                let startCPU = processCPU(), start = ContinuousClock.now
                for index in half..<count {
                    let call = ContinuousClock.now
                    laterWork += admissions![index]()
                    latencies.append(seconds(call.duration(to: .now)))
                }
                if let observation { await observation.value }
                if half > 0 {
                    let unfinished = ledger.benchmarkCounts
                    guard (unfinished["pendingReceipts"] ?? unfinished["requiredScopeFacts"] ?? 0) >= count - half,
                          !ledger.permitsAbsence(firstCoverage!.benchmarkReference(names!.last!), coverage: laterCoverage!) else {
                        throw NSError(domain: "NavigationBenchmark.newerAdmissionWasConsumed", code: 1)
                    }
                }
                let accepted = half > 0 ? laterCoverage! : firstCoverage!, delivered = laterWork
                await Task.detached { ledger.benchmarkObserve(accepted, work: delivered) }.value
                elapsed = seconds(start.duration(to: .now)); cpu = processCPU() - startCPU
                observationMetrics = CheckpointAcceptanceBenchmark.snapshot()
                let final = firstCoverage!.merging(laterCoverage!)
                guard names!.allSatisfy({ ledger.permitsAbsence(final.benchmarkReference($0), coverage: final) }) else {
                    throw NSError(domain: "NavigationBenchmark.unpaidSourceCoverage", code: 1)
                }
                ledgerCounts = ledger.benchmarkCounts
                retainedEntries = count
                admissions = nil; names = nil; firstWork = []; laterWork = []
                firstCoverage = nil; laterCoverage = nil
                retainedCoverage = final; retainedLedger = ledger
            } else {
                let file = root.appendingPathComponent("session.jsonl")
                func line(_ n: Int) throws -> Data {
                    try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "row-\(n)", "sessionId": "one",
                        "cwd": "/tmp/NavigationBenchmark", "timestamp": 1_700_000_000_000,
                        "message": ["content": "Message \(n)"]]) + Data([10])
                }
                var source = Data()
                for n in 0..<128 { source += try line(n) }; try source.write(to: file)
                let coordinator = IndexCoordinator(database: database, sources: [ClaudeCodeSource(roots: [root])])
                await coordinator.indexAll(scope: .proseOnly)
                let sessions = try await database.sessions(), id = sessions[0].id
                let rows = try await database.messages(sessionID: id)
                let reference = try await database.captureNavigationReference(sessionID: id, anchorMessageID: rows.last!.id)!
                source = Data(); for n in 0..<127 { source += try line(n) }; try source.write(to: file)
                await coordinator.refresh(paths: [file.path], scope: .proseOnly)
                let snapshot = try await database.transcriptSnapshot(sessionID: id)
                var resolver: PendingTargetWorkload? = .init(database: database, snapshot: snapshot, reference: reference)
                let starting = memoryBytes(); postSetup = starting
                sampling.withLock { $0.active = true; $0.peak = starting }
                let startCPU = processCPU(), start = ContinuousClock.now
                for _ in 0..<count {
                    let call = ContinuousClock.now
                    await resolver!.run(1)
                    latencies.append(seconds(call.duration(to: .now)))
                }
                elapsed = seconds(start.duration(to: .now)); cpu = processCPU() - startCPU
                let ending = memoryBytes(); sampling.withLock { $0.peak = max($0.peak, ending) }
                reads = resolver!.snapshotReads; publications = resolver!.publications
                guard resolver!.lookupErrors == 0, resolver!.requestedMessageID == nil,
                      resolver!.messages.count == 127, resolver!.pendingMessageRestore != nil else {
                    throw NSError(domain: "NavigationBenchmark.targetCorrectness", code: 1)
                }
                resolver = nil; retainedEntries = 127
            }
            latencies.sort()
            let p95 = nearestRankPercentile(latencies, fraction: 0.95)
            latencies = []
            try await Task.sleep(for: .seconds(2))
            let retained = memoryBytes(); sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }; try await sampler.value
            withExtendedLifetime(retainedCoverage) {}
            withExtendedLifetime(retainedLedger) {}
            let result: [String: Any] = ["mode": mode, "label": label, "inputs": count,
                "elapsedSeconds": elapsed, "processCPUSeconds": cpu,
                "processCPUDefinition": "All process threads during the selected cache, ledger, or pending-lookup workload; setup and release synchronization excluded",
                "mainActorCallP95Seconds": p95, "prePayloadFootprintBytes": beforeFixtures,
                "postSetupFootprintBytes": postSetup,
                "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
                "signedRetainedGrowthBytes": Int64(retained) - Int64(beforeFixtures), "snapshotReads": reads,
                "readerPublications": publications, "validatedEntries": retainedEntries,
                "ledgerCounts": ledgerCounts, "observationMetrics": observationMetrics,
                "observationCPUDefinition": "Same worker thread around synchronous observation and execution retirement; process workload CPU is separate",
                "correct": true]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            fputs("Navigation benchmark failed: \(error)\n", stderr); exit(1)
        }
    }
}
