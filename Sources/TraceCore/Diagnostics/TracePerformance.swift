import Foundation
import os

/// Stable Points of Interest intervals for Instruments and XCTest signpost metrics.
/// Names contain no queries, paths, transcript text, or other user data.
public enum TracePerformance {
    public struct Interval: @unchecked Sendable {
        fileprivate let id: OSSignpostID
        fileprivate let name: StaticString
    }

    private static let log = OSLog(
        subsystem: "me.haroldmartin.Trace", category: .pointsOfInterest
    )

    public static func begin(_ name: StaticString) -> Interval {
        let interval = Interval(id: OSSignpostID(log: log), name: name)
        os_signpost(.begin, log: log, name: name, signpostID: interval.id)
        return interval
    }

    public static func end(_ interval: Interval) {
        os_signpost(.end, log: log, name: interval.name, signpostID: interval.id)
    }

    public static func event(_ name: StaticString) {
        os_signpost(.event, log: log, name: name)
    }
}
