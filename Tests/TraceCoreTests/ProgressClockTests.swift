import Clocks
import CustomDump
import Foundation
@testable import TraceCore
import XCTest

final class ProgressClockTests: XCTestCase, @unchecked Sendable {
    func testCommittedProgressIsThrottledAt250MillisecondsAndFinalBoundaryAlwaysPublishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceProgressClock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var data = Data()
        var boundaries: [Int: Int64] = [:]
        for i in 1...750 {
            let record: [String: Any] = ["type": "user", "uuid": "\(i)", "sessionId": "progress",
                "cwd": "/tmp/project", "timestamp": 1_700_000_000_000 + i,
                "message": ["content": "progress message \(i)"]]
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
            if i % 250 == 0 { boundaries[i] = Int64(data.count) }
        }
        try data.write(to: root.appendingPathComponent("session.jsonl"))
        let clock = TestClock()
        let origin = clock.now
        let source = ClockSteppedSource(base: ClaudeCodeSource(roots: [root]), clock: clock)
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [source], clock: clock)
        let recorder = ProgressClockRecorder()
        await coordinator.indexAll(scope: .proseOnly) { update in
            if update.phase == .indexing, update.completedFiles == 0, update.currentFileBytes > 0 {
                await recorder.append(.init(bytes: update.currentFileBytes, elapsed: origin.duration(to: clock.now)))
            }
        }
        let expected: [ProgressClockRecorder.Event] = [
            .init(bytes: try XCTUnwrap(boundaries[250]), elapsed: .zero),
            .init(bytes: try XCTUnwrap(boundaries[750]), elapsed: .milliseconds(250)),
            .init(bytes: try XCTUnwrap(boundaries[750]), elapsed: .milliseconds(250)),
        ]
        let events = await recorder.events
        expectNoDifference(expected, events,
            "the batch at 249 ms must be suppressed; the final boundary must still be published")
        let stats = try await database.statistics()
        XCTAssertEqual(stats.messageCount, 750)
        try await clock.checkSuspension()
    }
}

private actor ProgressClockRecorder {
    struct Event: Equatable, Sendable { let bytes: Int64; let elapsed: Duration }
    var events: [Event] = []
    func append(_ event: Event) { events.append(event) }
}

private struct ClockSteppedSource: SessionSource {
    let base: ClaudeCodeSource
    let clock: TestClock<Duration>
    var agent: AgentKind { base.agent }
    var roots: [SourceRoot] { base.roots }
    func discover() throws -> [DiscoveredSourceFile] { try base.discover() }
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?) -> AsyncThrowingStream<ParsedRecord, Error> {
        stepped(base.records(in: file, from: offset, through: boundary))
    }
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialSessionID: String?) -> AsyncThrowingStream<ParsedRecord, Error> {
        stepped(base.records(in: file, from: offset, through: boundary, initialSessionID: initialSessionID))
    }
    private func stepped(_ records: AsyncThrowingStream<ParsedRecord, Error>) -> AsyncThrowingStream<ParsedRecord, Error> {
        let state = ClockSteppedRecords(iterator: records.makeAsyncIterator(), clock: clock)
        return AsyncThrowingStream(unfolding: { try await state.next() })
    }
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage {
        try base.hydrate(fileURL: fileURL, format: format, locator: locator)
    }
}

/// AsyncThrowingStream calls the unfolding closure serially for its single consumer.
private final class ClockSteppedRecords: @unchecked Sendable {
    var iterator: AsyncThrowingStream<ParsedRecord, Error>.Iterator
    let clock: TestClock<Duration>
    var checkpoints = 0
    init(iterator: AsyncThrowingStream<ParsedRecord, Error>.Iterator, clock: TestClock<Duration>) {
        self.iterator = iterator; self.clock = clock
    }
    func next() async throws -> ParsedRecord? {
        guard let record = try await iterator.next() else { return nil }
        if case .checkpoint = record {
            checkpoints += 1
            if checkpoints == 500 { await clock.advance(by: .milliseconds(249)) }
            if checkpoints == 750 { await clock.advance(by: .milliseconds(1)) }
        }
        return record
    }
}
