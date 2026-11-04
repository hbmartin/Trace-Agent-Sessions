import XCTest
import os
@testable import TraceCore

final class FSEventsWatcherTests: XCTestCase {
    #if DEBUG
    func testCombinedWrapFlagsPreserveGlobalRecoveryPrecedence() throws {
        let root = TraceFileIO.canonicalPath("/tmp/TraceCombinedWrap").path
        let path = root + "/nested/session.jsonl"
        let wrap = UInt32(kFSEventStreamEventFlagEventIdsWrapped)
        let combinations = [
            UInt32(kFSEventStreamEventFlagRootChanged),
            UInt32(kFSEventStreamEventFlagMustScanSubDirs),
            UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs),
            UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed),
            UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCloned),
            UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped),
            UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagHistoryDone)
        ]
        for extra in combinations {
            for wrapped in [false, true] {
                for accepted in [false, true] {
                    for tracked in [false, true] {
                        let flags = extra | (wrapped ? wrap : 0)
                        let context = "flags=\(flags), accepted=\(accepted), tracked=\(tracked)"
                        let watcher = FSEventsWatcher(roots: [URL(fileURLWithPath: root)], identifier: "stream",
                            eventFilter: { _, _ in accepted }, tracksWatermarks: tracked, onChange: { _ in })
                        let before = watcher.changesForTesting([])
                        var expected = SourceChanges()
                        expected.streamEpochs = before.streamEpochs
                        if accepted {
                            expected.include(path: path, flags: flags, eventID: 1, streamIdentifier: "stream", streamRoots: [root])
                        } else if wrapped {
                            expected.include(path: path, flags: wrap | UInt32(kFSEventStreamEventFlagItemIsDir),
                                eventID: 1, streamIdentifier: "stream", streamRoots: [root])
                        }
                        if !tracked {
                            expected.streamEpochs = [:]; expected.watermarks = [:]
                            expected.streamRoots = [:]; expected.wrappedStreams = []
                        }
                        let actual = watcher.changesForTesting([(path, flags, 1)])
                        XCTAssertEqual(actual.paths, expected.paths, context)
                        XCTAssertEqual(actual.lexicalPaths, expected.lexicalPaths, context)
                        XCTAssertEqual(actual.structuralPaths, expected.structuralPaths, context)
                        XCTAssertEqual(actual.reconciliationPaths, expected.reconciliationPaths, context)
                        XCTAssertEqual(actual.recoveryReasons, expected.recoveryReasons, context)
                        XCTAssertEqual(actual.watermarks, expected.watermarks, context)
                        XCTAssertEqual(actual.streamRoots, expected.streamRoots, context)
                        XCTAssertEqual(actual.wrappedStreams, expected.wrappedStreams, context)
                        XCTAssertEqual(actual.historyDone, expected.historyDone, context)
                        if tracked && wrapped {
                            let previous = try XCTUnwrap(before.streamEpochs["stream"])
                            let current = try XCTUnwrap(actual.streamEpochs["stream"])
                            XCTAssertNotEqual(current.id, previous.id, context)
                            XCTAssertEqual(current.predecessors, [previous.id], context)
                        } else {
                            XCTAssertEqual(actual.streamEpochs, before.streamEpochs, context)
                        }
                    }
                }
            }
        }
    }

    func testFilteredWrapStillAdvancesChronologyAndReconciliation() {
        let watcher = FSEventsWatcher(roots: [URL(fileURLWithPath: "/tmp")], identifier: "stream",
            eventFilter: { path, _ in path.hasSuffix("accepted.jsonl") }, onChange: { _ in })
        let before = watcher.changesForTesting([("/tmp/accepted.jsonl", 0, 1_000)])
        let wrapped = watcher.changesForTesting([("/tmp/filtered", UInt32(kFSEventStreamEventFlagEventIdsWrapped), 1)])
        XCTAssertTrue(wrapped.paths.isEmpty)
        XCTAssertEqual(wrapped.wrappedStreams, ["stream"])
        XCTAssertEqual(wrapped.reconciliationPaths, [TraceFileIO.canonicalPath("/tmp").path])
        XCTAssertNotEqual(wrapped.streamEpochs["stream"], before.streamEpochs["stream"])
        let after = watcher.changesForTesting([("/tmp/accepted.jsonl", 0, 20)])
        XCTAssertEqual(after.streamEpochs["stream"], wrapped.streamEpochs["stream"])
        var delayed = after; delayed.merge(before); delayed.merge(wrapped)
        XCTAssertEqual(delayed.watermarks["stream"], 20)
    }

    func testAcceptedWrapAdvancesOnceAndUntrackedWrapKeepsReconciliation() throws {
        for tracked in [false, true] {
            let watcher = FSEventsWatcher(roots: [URL(fileURLWithPath: "/tmp")], identifier: "stream",
                tracksWatermarks: tracked, onChange: { _ in })
            let before = watcher.changesForTesting([("/tmp/session.jsonl", 0, 1_000)])
            let wrapped = watcher.changesForTesting([("/tmp/session.jsonl", UInt32(kFSEventStreamEventFlagEventIdsWrapped), 1)])
            XCTAssertEqual(wrapped.paths, [TraceFileIO.canonicalPath("/tmp/session.jsonl").path])
            XCTAssertEqual(wrapped.reconciliationPaths, [TraceFileIO.canonicalPath("/tmp").path])
            if tracked {
                XCTAssertEqual(wrapped.streamEpochs["stream"]?.predecessors, Set([try XCTUnwrap(before.streamEpochs["stream"]).id]))
                XCTAssertEqual(wrapped.watermarks["stream"], 1)
            } else {
                XCTAssertTrue(wrapped.streamEpochs.isEmpty)
                XCTAssertTrue(wrapped.watermarks.isEmpty)
                XCTAssertTrue(wrapped.wrappedStreams.isEmpty)
            }
        }
    }
    #endif

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

    func testClonedDirectoriesRequireReconciliationWithoutCreatedFlag() {
        for extra in [UInt32(0), UInt32(kFSEventStreamEventFlagItemCreated)] {
            var changes = SourceChanges()
            changes.include(path: "/tmp/cloned", flags: UInt32(kFSEventStreamEventFlagItemIsDir
                | kFSEventStreamEventFlagItemCloned) | extra, eventID: 42,
                streamIdentifier: "volume", streamRoots: ["/tmp"])
            XCTAssertEqual(changes.reconciliationPaths, ["/tmp/cloned"])
            XCTAssertTrue(changes.hasIndexWork)
            XCTAssertEqual(changes.watermarks["volume"], 42)
        }
        var created = SourceChanges()
        created.include(path: "/tmp/created", flags: UInt32(kFSEventStreamEventFlagItemIsDir
            | kFSEventStreamEventFlagItemCreated), eventID: 43, streamIdentifier: "volume")
        XCTAssertTrue(created.reconciliationPaths.isEmpty)
        XCTAssertFalse(created.hasIndexWork)
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

    @MainActor func testMainActorStopReturnsWhileFilesystemCallbackIsBlocked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceMainStop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = OSAllocatedUnfairLock(initialState: false)
        let released = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        var watcher: FSEventsWatcher? = FSEventsWatcher(roots: [directory], eventFilter: { path, _ in
            guard path.hasSuffix("/session.jsonl") else { return false }
            if !entered.withLock({ value in let old = value; value = true; return old }) {
                _ = release.wait(timeout: .now() + 5)
            }
            return true
        }, tracksWatermarks: false) { _ in released.withLock { $0 = true } }
        XCTAssertTrue(watcher!.start())
        defer { release.signal() }
        try Data("{}\n".utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        for _ in 0..<100 where !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(entered.withLock { $0 })
        weak var retiring = watcher
        watcher?.stop(flushPending: true)
        watcher = nil
        // This actor turn completes before releasing the filesystem queue.
        await Task.yield()
        XCTAssertFalse(released.withLock { $0 })
        XCTAssertNotNil(retiring, "stop retains the watcher while its callback drains")
        release.signal()
        for _ in 0..<100 where retiring != nil { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertNil(retiring)
        XCTAssertTrue(released.withLock { $0 })
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
