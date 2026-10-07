import XCTest
import os
@testable import TraceCore

final class FSEventsWatcherTests: XCTestCase {
    func testMergedChangesKeepLexicalSidecarPathAcrossRepointing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraceSidecarEvents-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.jsonl")
        let replacement = directory.appendingPathComponent("replacement.jsonl")
        let link = directory.appendingPathComponent("session_index.jsonl")
        try Data().write(to: original)
        try Data().write(to: replacement)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        var changes = SourceChanges()
        changes.include(path: link.path, flags: UInt32(kFSEventStreamEventFlagItemModified),
                        eventID: 10, streamIdentifier: "sidecars")

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
        var repointed = SourceChanges()
        repointed.include(path: link.path, flags: UInt32(kFSEventStreamEventFlagItemCreated),
                          eventID: 11, streamIdentifier: "sidecars")
        changes.merge(repointed)

        XCTAssertEqual(changes.paths, [TraceFileIO.canonicalPath(original.path).path,
                                      TraceFileIO.canonicalPath(replacement.path).path])
        XCTAssertEqual(changes.lexicalPaths, [link.standardizedFileURL.path])
        XCTAssertEqual(changes.watermarks["sidecars"], 11)
    }

    func testWatcherReportsEmptyRootStartupFailure() {
        let watcher = FSEventsWatcher(roots: []) { _ in }
        XCTAssertFalse(watcher.start())
    }

    func testStopDrainsInFlightCallbacksBeforeRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceWatcherStop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopping = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let recorder = EventRecorder(expectedSuffix: "/\(directory.lastPathComponent)/session.jsonl")
        let firstCallback = OSAllocatedUnfairLock(initialState: true)
        let watcher = FSEventsWatcher(roots: [directory], eventFilter: { path, _ in
            guard path.hasSuffix("/session.jsonl") else { return false }
            if firstCallback.withLock({ first in
                let shouldPause = first
                first = false
                return shouldPause
            }) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return true
        }, tracksWatermarks: false) { recorder.receive($0.paths) }
        XCTAssertTrue(watcher.start())
        defer { release.signal(); watcher.stop() }
        try Data("{}\n".utf8).write(to: file)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        DispatchQueue.global(qos: .utility).async {
            stopping.signal()
            watcher.stop(flushPending: true)
            stopped.signal()
        }
        XCTAssertEqual(stopping.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(recorder.found, "replacement must receive the in-flight batch")
    }

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
        XCTAssertEqual(changes.streamRoots["volume-a"], [root])
    }

    func testAppendIsReportedAtFileGranularity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceFSEvents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: file)

        let recorder = EventRecorder(expectedSuffix: "/\(directory.lastPathComponent)/\(file.lastPathComponent)")
        let watcher = FSEventsWatcher(roots: [directory]) { paths in recorder.receive(paths) }
        XCTAssertTrue(watcher.start())
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
