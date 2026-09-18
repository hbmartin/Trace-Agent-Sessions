import XCTest
@testable import TraceCore

final class FSEventsWatcherTests: XCTestCase {
    func testEventCheckpointPersistsAcrossDatabaseOpen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraceCheckpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let database = try IndexDatabase(url: url)
        try await database.saveEventCheckpoints(["volume-a": 123])

        let reopened = try IndexDatabase(url: url)
        let checkpoint = try await reopened.eventCheckpoint(volumeID: "volume-a")

        XCTAssertEqual(checkpoint, 123)
    }

    func testDroppedEventsRecoverOnlyWatcherRootsAndCarryCheckpoint() {
        let root = "/tmp/TraceWatcherRoot"
        var changes = SourceChanges()
        changes.include(
            path: root,
            flags: UInt32(kFSEventStreamEventFlagKernelDropped),
            eventID: 42,
            streamIdentifier: "volume-a",
            streamRoots: [root]
        )

        XCTAssertEqual(changes.reconciliationPaths, [root])
        XCTAssertEqual(changes.recoveryReasons, [.eventsDropped])
        XCTAssertEqual(changes.watermarks["volume-a"], 42)
    }

    func testAppendIsReportedAtFileGranularity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceFSEvents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)

        let recorder = EventRecorder(expectedSuffix: "/\(directory.lastPathComponent)/\(file.lastPathComponent)")
        let watcher = FSEventsWatcher(roots: [directory]) { paths in recorder.receive(paths) }
        watcher.start()
        defer { watcher.stop() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()

        let deadline = Date().addingTimeInterval(3)
        while !recorder.found && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(recorder.found, "received paths: \(recorder.receivedPaths)")
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSuffix: String
    private var paths: Set<String> = []

    init(expectedSuffix: String) { self.expectedSuffix = expectedSuffix }
    func receive(_ newPaths: Set<String>) {
        lock.lock()
        paths.formUnion(newPaths)
        lock.unlock()
    }
    var found: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains { $0.hasSuffix(expectedSuffix) }
    }
    var receivedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths.sorted()
    }
}
