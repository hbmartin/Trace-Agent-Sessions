// Compile with the revision's extracted SourceIngressMailbox and optimized TraceCore.
import Darwin
import Foundation
import os
import TraceCore

private func footprint() -> UInt64 {
    var value = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &value) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS); return value.phys_footprint
}
private func cpu() -> Double {
    var value = rusage(); precondition(getrusage(RUSAGE_SELF, &value) == 0)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
}
private func seconds(_ duration: Duration) -> Double {
    let value = duration.components; return Double(value.seconds) + Double(value.attoseconds) / 1e18
}
private struct DeclaredSource: SessionSource {
    let base: ClaudeCodeSource, files: [DiscoveredSourceFile]
    let reads: OSAllocatedUnfairLock<Int>
    var agent: AgentKind { base.agent }; var roots: [SourceRoot] { base.roots }
    func discover() throws -> [DiscoveredSourceFile] { files }
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary, initialContext: .init(fallbackTimestampMilliseconds: 0))
    }
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialSessionID: String?) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary)
    }
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialContext: SourceReadContext) -> AsyncThrowingStream<ParsedRecord, Error> {
        reads.withLock { $0 += 1 }; return base.records(in: file, from: offset, through: boundary, initialContext: initialContext)
    }
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        try base.hydrate(fileURL: fileURL, format: format, locator: locator)
    }
}
private final class PreparedPayload: Sendable {
    let values: [SourceIngressMailbox.Prepared]
    init(_ values: [SourceIngressMailbox.Prepared]) { self.values = values }
}
@main struct NavigationAdmissionWorkload {
    @MainActor static func main() async {
        do {
            guard CommandLine.arguments.count == 4, let count = Int(CommandLine.arguments[1]), count > 0,
                  ["outside", "mixed", "adapter", "long-outside"].contains(CommandLine.arguments[3]) else {
                throw NSError(domain: "NavigationAdmission.arguments", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected positive count, label, and outside|mixed|adapter|long-outside mode"])
            }
            let mode = CommandLine.arguments[3], beforePayload = footprint()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceAdmission-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var elapsed = 0.0, processCPU = 0.0, readCount = 0, correct = false, setup: UInt64 = 0
            var latencies: [Double] = [], counts: [String: Int] = [:]
            var retained: IndexNavigationWorkLedger?
            weak var preparedLifetime: PreparedPayload?
            let peak = OSAllocatedUnfairLock(initialState: beforePayload)
            let sampler = Task.detached {
                while !Task.isCancelled {
                    let value = footprint(); peak.withLock { $0 = max($0, value) }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            var preparationElapsed = 0.0, preparationCPU = 0.0
            var absenceElapsed = 0.0, absenceCPU = 0.0, absenceQueries = 0
            if mode == "adapter" {
                let root = directory.appendingPathComponent("sources"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                func data(_ index: Int, _ content: String) -> Data {
                    Data("{\"type\":\"user\",\"uuid\":\"m-\(index)\",\"sessionId\":\"s-\(index)\",\"message\":{\"content\":\"\(content)\"}}\n".utf8)
                }
                var files: [DiscoveredSourceFile] = []
                for index in 0..<count {
                    let file = root.appendingPathComponent("declared-\(index).trace")
                    try data(index, "before").write(to: file)
                    files.append(.init(agent: .claudeCode, root: root, url: file, format: .claudeJSONL))
                }
                let reads = OSAllocatedUnfairLock(initialState: 0)
                let source = DeclaredSource(base: .init(roots: [root]), files: files, reads: reads)
                let database = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
                let coordinator = IndexCoordinator(database: database, sources: [source])
                await coordinator.indexAll(scope: .proseOnly)
                for (index, file) in files.enumerated() { try data(index, "after").write(to: file.url, options: .atomic) }
                let paths = Set(files.map { $0.url.path }); reads.withLock { $0 = 0 }; setup = footprint()
                let terminal = OSAllocatedUnfairLock<IndexProgress?>(initialState: nil)
                let startCPU = cpu(), start = ContinuousClock.now
                await coordinator.refresh(paths: paths, scope: .proseOnly, progress: { value in
                    if value.phase == .complete { terminal.withLock { $0 = value } }
                })
                elapsed = seconds(start.duration(to: .now)); processCPU = cpu() - startCPU
                readCount = reads.withLock { $0 }
                let sessions = try await database.sessions()
                let messages = try await database.messages(sessionID: sessions[0].id)
                correct = readCount == count && terminal.withLock { $0?.failedFiles } == 0 && messages.first?.prefix.contains("after") == true
            } else {
                let roots = [TraceFileIO.canonicalPath("/tmp/navigation-domain/sessions")]
                // Raw payload construction precedes normalization and reservation timing.
                var raw: [SourceChanges]? = (0..<count).map { index in
                    var value = SourceChanges()
                    let prefix = mode == "long-outside" ? String(repeating: "long-component/", count: 8) : ""
                    value.paths = [mode == "mixed" && index.isMultiple(of: 2)
                        ? "/tmp/navigation-domain/sessions/file-\(index).trace"
                        : "/tmp/navigation-domain/\(prefix)metadata-\(index).jsonl"]
                    return value
                }
                let unprepared = raw!
                let result = await Task.detached {
                    let startCPU = cpu(), start = ContinuousClock.now
                    let values = unprepared.map { benchmarkMetadataPrepared($0, roots: roots) }
                    return (PreparedPayload(values), seconds(start.duration(to: .now)), cpu() - startCPU)
                }.value
                var payload: PreparedPayload? = result.0
                preparedLifetime = payload
                preparationElapsed = result.1; preparationCPU = result.2
                raw = nil; setup = footprint()
                let ledger = IndexNavigationWorkLedger()
                var admissionCorrect = true
                elapsed = 0; processCPU = 0
                for (index, value) in payload!.values.enumerated() {
                    let callCPU = cpu(), call = ContinuousClock.now
                    let work = ledger.reserve(value.navigationInputs)
                    let duration = seconds(call.duration(to: .now))
                    processCPU += cpu() - callCPU; elapsed += duration
                    latencies.append(duration)
                    let expectedWork = mode == "mixed" && index.isMultiple(of: 2)
                    admissionCorrect = admissionCorrect && (!work.isEmpty == expectedWork)
                    // Validation and deliberate owner retirement are outside timing.
                    for item in work { item.retire() }
                }
                counts = ledger.benchmarkCounts
                correct = admissionCorrect && counts["pendingReceipts"] == 0
                retained = ledger
                payload = nil
                let queryDatabase = try IndexDatabase(url: directory.appendingPathComponent("query.sqlite"))
                let coverage = IndexNavigationCoverage.benchmarkFixture(generation: queryDatabase.contentGeneration,
                    names: ["selected.jsonl"], covered: true)
                guard let reference = coverage.benchmarkReferences("selected.jsonl").first else { throw CancellationError() }
                let queryCPU = cpu(), queryStart = ContinuousClock.now
                var allowed = 0
                for _ in 0..<100 { if ledger.permitsAbsence(reference, coverage: coverage) { allowed += 1 } }
                absenceElapsed = seconds(queryStart.duration(to: .now)); absenceCPU = cpu() - queryCPU
                absenceQueries = allowed
                guard allowed == 100 else { throw NSError(domain: "NavigationAdmission.absenceCorrectness", code: 1) }

            }
            guard preparedLifetime == nil else { throw NSError(domain: "NavigationAdmission.fixtureLifetime", code: 1) }
            let (median, p95): (Double, Double) = {
                let sorted = latencies.sorted()
                return (sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                    sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(0.95 * Double(sorted.count))) - 1)])
            }()
            latencies = []
            let ending = footprint(); peak.withLock { $0 = max($0, ending) }
            try await Task.sleep(for: .seconds(2))
            sampler.cancel(); _ = try? await sampler.value
            let idle = footprint()
            let output: [String: Any] = ["label": CommandLine.arguments[2], "mode": mode, "count": count,
                "elapsedSeconds": elapsed, "processCPUSeconds": processCPU,
                "preparationElapsedSeconds": preparationElapsed, "preparationProcessCPUSeconds": preparationCPU,
                "cpuDefinition": "process-wide CPU around each named execution phase; no setup or idle interval",
                "absenceQueryElapsedSeconds": absenceElapsed, "absenceQueryProcessCPUSeconds": absenceCPU, "absenceQueries": absenceQueries,
                "reservationMedianSeconds": median, "reservationP95Seconds": p95, "fixturesReleased": preparedLifetime == nil, "prePayloadFootprintBytes": beforePayload,
                "postSetupFootprintBytes": setup, "peakFootprintBytes": peak.withLock { $0 },
                "retainedFootprintBytes": idle, "retainedGrowthBytes": Int64(idle) - Int64(beforePayload),
                "navigationState": counts, "readCount": readCount, "correct": correct]
            withExtendedLifetime(retained) {}
            print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
            if !correct { exit(2) }
        } catch {
            FileHandle.standardError.write(Data(("Navigation admission workload failed: \(error)\n").utf8)); exit(1)
        }
    }
}
