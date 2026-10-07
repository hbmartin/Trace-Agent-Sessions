import Darwin
import Foundation
import os

/// Stable Points of Interest intervals for Instruments and XCTest signpost metrics.
/// Names contain no queries, paths, transcript text, or other user data.
public enum TracePerformance {
    public struct Interval: @unchecked Sendable {
        fileprivate let id: OSSignpostID
        fileprivate let name: StaticString
        fileprivate let started: UInt64?
    }

    private static let log = OSLog(
        subsystem: "me.haroldmartin.Trace", category: .pointsOfInterest
    )

    public static func begin(_ name: StaticString) -> Interval {
        let collector = BenchmarkCollector.shared
        let interval = Interval(id: OSSignpostID(log: log), name: name,
            started: collector != nil && name.description == "Transcript Update" ? DispatchTime.now().uptimeNanoseconds : nil)
        os_signpost(.begin, log: log, name: name, signpostID: interval.id)
        return interval
    }

    public static func end(_ interval: Interval) {
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
        if let started = interval.started {
            BenchmarkCollector.shared?.update(duration: DispatchTime.now().uptimeNanoseconds - started)
        }
    }

    public static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}

/// Activated only by the benchmark launch environment. Storage is bounded to one
/// online aggregate; exports and control acknowledgments stay outside measurement.
private final class BenchmarkCollector: @unchecked Sendable {
    static let shared: BenchmarkCollector? = ProcessInfo.processInfo.environment["TRACE_BENCHMARK_EXPORT_DIRECTORY"]
        .map { BenchmarkCollector(directory: URL(fileURLWithPath: $0)) }
    private struct Sample: Codable {
        var id: String
        var updateCount = 0
        var totalUpdateNanoseconds: UInt64 = 0
        var maximumUpdateNanoseconds: UInt64 = 0
        var startingFootprintBytes: UInt64
        var sampledPeakFootprintBytes: UInt64
        var endingFootprintBytes: UInt64 = 0
        var retainedFootprintBytes: UInt64 = 0
        var footprintSampleCount = 1
        var startingFootprintMiB: Double { Double(startingFootprintBytes) / 1_048_576 }
    }
    private let state = OSAllocatedUnfairLock<Sample?>(initialState: nil)
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.benchmark-memory", qos: .utility)
    private let directory: URL
    private var observer: NSObjectProtocol?
    private var timer: DispatchSourceTimer?

    private init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("traceBenchmarkControl"), object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? String,
                  let action = note.userInfo?["action"] as? String,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
            self.queue.async { self.control(action: action, id: id) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let footprint = Self.footprint() else { return }
            self.state.withLock {
                guard $0 != nil else { return }
                $0!.sampledPeakFootprintBytes = max($0!.sampledPeakFootprintBytes, footprint)
                $0!.footprintSampleCount += 1
            }
        }
        timer.resume()
        self.timer = timer
        acknowledge("ready")
    }

    func update(duration: UInt64) {
        state.withLock {
            guard $0 != nil else { return }
            $0!.updateCount += 1
            $0!.totalUpdateNanoseconds += duration
            $0!.maximumUpdateNanoseconds = max($0!.maximumUpdateNanoseconds, duration)
        }
    }

    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    private func acknowledge(_ name: String) {
        try? Data().write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func control(action: String, id: String) {
        if action == "begin" {
            // Repeated control messages are idempotent while waiting for the ack.
            guard state.withLock({ $0?.id != id }), let footprint = Self.footprint() else { return }
            state.withLock { $0 = Sample(id: id, startingFootprintBytes: footprint, sampledPeakFootprintBytes: footprint) }
            acknowledge("\(id)-begun")
        } else if action == "end" {
            guard let footprint = Self.footprint() else { return }
            let sample = state.withLock { active -> Sample? in
                guard var sample = active, sample.id == id else { return nil }
                sample.endingFootprintBytes = footprint
                sample.sampledPeakFootprintBytes = max(sample.sampledPeakFootprintBytes, footprint)
                active = nil
                return sample
            }
            guard let sample else { return }
            // Quiescence is excluded from CPU/clock measurement and peak sampling.
            queue.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
                guard let retained = Self.footprint() else { return }
                var final = sample
                final.retainedFootprintBytes = retained
                guard let data = try? JSONEncoder().encode(final),
                      var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                for field in ["starting", "sampledPeak", "ending", "retained"] {
                    if let bytes = json["\(field)FootprintBytes"] as? NSNumber {
                        json["\(field)FootprintMiB"] = bytes.doubleValue / 1_048_576
                    }
                }
                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]) {
                    try? data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
                }
            }
        }
    }
}
