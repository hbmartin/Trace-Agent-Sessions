import Foundation

public struct LatencyHistogram: Codable, Equatable, Sendable {
    public static let upperBoundsMilliseconds = [5, 10, 20, 30, 50, 80, 100, 150, 200, 500, 1_000]
    public var buckets: [Int]

    public init(buckets: [Int] = Array(repeating: 0, count: upperBoundsMilliseconds.count + 1)) {
        self.buckets = buckets.count == Self.upperBoundsMilliseconds.count + 1
            ? buckets
            : Array(repeating: 0, count: Self.upperBoundsMilliseconds.count + 1)
    }

    public mutating func record(milliseconds: Double) {
        let index = Self.upperBoundsMilliseconds.firstIndex { milliseconds <= Double($0) }
            ?? Self.upperBoundsMilliseconds.count
        buckets[index] += 1
    }
}

public struct DiagnosticDay: Codable, Equatable, Identifiable, Sendable {
    public var id: String { day }
    public let day: String
    public var searchCount: Int
    public var openCount: Int
    public var searchLatency: LatencyHistogram
    public var hydrationLatency: LatencyHistogram
    public var indexSizeBytes: Int64
    public var launches: Int
    public var uncleanLaunchesDetected: Int

    public init(day: String) {
        self.day = day
        searchCount = 0
        openCount = 0
        searchLatency = .init()
        hydrationLatency = .init()
        indexSizeBytes = 0
        launches = 0
        uncleanLaunchesDetected = 0
    }
}

public struct DiagnosticsSnapshot: Codable, Sendable {
    public var formatVersion: Int
    public var launchOpen: Bool
    public var days: [DiagnosticDay]

    public init(formatVersion: Int = 1, launchOpen: Bool = false, days: [DiagnosticDay] = []) {
        self.formatVersion = formatVersion
        self.launchOpen = launchOpen
        self.days = days
    }
}

public actor DiagnosticsStore {
    private let url: URL
    private var snapshot: DiagnosticsSnapshot

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trace", isDirectory: true)
            .appendingPathComponent("diagnostics.json")
    }

    public init(url: URL = DiagnosticsStore.defaultURL()) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(DiagnosticsSnapshot.self, from: data),
           decoded.formatVersion == 1 {
            snapshot = decoded
        } else {
            snapshot = .init()
        }
    }

    public func markLaunchStarted(at date: Date = Date()) throws {
        var day = entry(for: date)
        day.launches += 1
        if snapshot.launchOpen { day.uncleanLaunchesDetected += 1 }
        replace(day)
        snapshot.launchOpen = true
        try persist()
    }

    public func markCleanShutdown() throws {
        snapshot.launchOpen = false
        try persist()
    }

    public func recordSearch(milliseconds: Double, at date: Date = Date()) throws {
        var day = entry(for: date)
        day.searchCount += 1
        day.searchLatency.record(milliseconds: milliseconds)
        replace(day)
        try persist()
    }

    public func recordOpen(hydrationMilliseconds: Double? = nil, at date: Date = Date()) throws {
        var day = entry(for: date)
        day.openCount += 1
        if let hydrationMilliseconds {
            day.hydrationLatency.record(milliseconds: hydrationMilliseconds)
        }
        replace(day)
        try persist()
    }

    public func recordIndexSize(bytes: Int64, at date: Date = Date()) throws {
        var day = entry(for: date)
        day.indexSizeBytes = max(0, bytes)
        replace(day)
        try persist()
    }

    public func value() -> DiagnosticsSnapshot { snapshot }

    public func export(to destination: URL) throws {
        try encoded().write(to: destination, options: .atomic)
    }

    public func reset() throws {
        snapshot = .init(launchOpen: snapshot.launchOpen)
        try persist()
    }

    private func entry(for date: Date) -> DiagnosticDay {
        let key = Self.dayFormatter.string(from: date)
        return snapshot.days.first { $0.day == key } ?? .init(day: key)
    }

    private func replace(_ day: DiagnosticDay) {
        snapshot.days.removeAll { $0.day == day.day }
        snapshot.days.append(day)
        let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date()
        let cutoffKey = Self.dayFormatter.string(from: cutoff)
        snapshot.days = snapshot.days.filter { $0.day >= cutoffKey }.sorted { $0.day > $1.day }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }

    private func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
