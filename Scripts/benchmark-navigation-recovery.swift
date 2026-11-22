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
private func seconds(_ d: Duration) -> Double { let v = d.components; return Double(v.seconds) + Double(v.attoseconds) / 1e18 }
@main struct NavigationRecoveryBenchmark {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4, let count = Int(CommandLine.arguments[1]), count > 0,
                  ["coverage", "target"].contains(CommandLine.arguments[3]) else {
                throw NSError(domain: "NavigationBenchmark.arguments", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected a positive count, label, and coverage|target mode"])
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
            let p95 = latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
            latencies = []
            try await Task.sleep(for: .seconds(2))
            let retained = memoryBytes(); sampling.withLock { $0.peak = max($0.peak, retained); $0.done = true }; try await sampler.value
            withExtendedLifetime(retainedCoverage) {}
            let result: [String: Any] = ["mode": mode, "label": label, "inputs": count,
                "elapsedSeconds": elapsed, "processCPUSeconds": cpu,
                "processCPUDefinition": "All process threads during cache updates or pending lookups only",
                "mainActorCallP95Seconds": p95, "prePayloadFootprintBytes": beforeFixtures,
                "postSetupFootprintBytes": postSetup,
                "peakFootprintBytes": sampling.withLock { $0.peak }, "retainedFootprintBytes": retained,
                "signedRetainedGrowthBytes": Int64(retained) - Int64(beforeFixtures), "snapshotReads": reads,
                "readerPublications": publications, "validatedEntries": retainedEntries, "correct": true]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            fputs("Navigation benchmark failed: \(error)\n", stderr); exit(1)
        }
    }
}
