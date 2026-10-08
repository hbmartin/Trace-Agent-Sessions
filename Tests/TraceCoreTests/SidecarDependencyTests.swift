import CoreServices
import Darwin
import Foundation
import GRDB
import os
import XCTest
@testable import TraceCore

@MainActor
final class SidecarDependencyTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceDependencies-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testSymlinkedHomeRelativeChainAndAncestorRetargeting() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("real/home")
        let store = root.appendingPathComponent("real/store")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "real")
        let configuredHome = alias.appendingPathComponent("home")
        let sidecar = configuredHome.appendingPathComponent("state_7.sqlite")
        let hop = store.appendingPathComponent("hop")
        let target = store.appendingPathComponent("final.sqlite")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(atPath: hop.path, withDestinationPath: "final.sqlite")
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: "../store/hop")
        let otherHome = root.appendingPathComponent("unaffected")
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true)
        let otherSidecar = otherHome.appendingPathComponent("session_index.jsonl")
        try Data().write(to: otherSidecar)
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [configuredHome, otherHome])
        XCTAssertEqual(mapping.configuredChangePaths(for: target.path), [sidecar.path])
        XCTAssertEqual(mapping.configuredChangePaths(for: target.path + "-wal"), [sidecar.path])
        XCTAssertEqual(mapping.configuredChangePaths(for: hop.path), [sidecar.path])
        XCTAssertTrue(mapping.configuredChangePaths(for: alias.path).contains(sidecar.path))
        XCTAssertTrue(mapping.diagnostics.isEmpty)
        let replacement = root.appendingPathComponent("replacement")
        try FileManager.default.createDirectory(at: replacement.appendingPathComponent("home"), withIntermediateDirectories: true)
        try Data().write(to: replacement.appendingPathComponent("home/state_7.sqlite"))
        let next = root.appendingPathComponent("next")
        try FileManager.default.createSymbolicLink(at: next, withDestinationURL: replacement)
        XCTAssertEqual(rename(next.path, alias.path), 0)
        let changed = CodexMetadataSidecarMapping(metadataDirectories: [configuredHome, otherHome])
        XCTAssertNotEqual(changed, mapping)
        XCTAssertEqual(changed.configuredChangePaths(for: replacement.appendingPathComponent("home/state_7.sqlite").path), [sidecar.path])
        let affected = mapping.configuredSidecarsWithChangedDependencies(comparedTo: changed)
        XCTAssertTrue(affected.contains(sidecar.path))
        XCTAssertFalse(affected.contains(otherSidecar.path))
    }
    func testMissingTargetsAtomicReplacementCyclesAndHopLimit() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        let missing = root.appendingPathComponent("missing/deep/names")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: missing)
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [home])
        XCTAssertEqual(mapping.configuredChangePaths(for: missing.path), [sidecar.path])
        XCTAssertEqual(mapping.configuredRecoveryPaths(for: root.appendingPathComponent("missing").path), [sidecar.path])
        XCTAssertTrue(mapping.namespaceDirectories.contains { $0.path == root.path })
        let temporary = home.appendingPathComponent("replacement")
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: "session_index.jsonl")
        XCTAssertEqual(rename(temporary.path, sidecar.path), 0)
        let cyclic = CodexMetadataSidecarMapping(metadataDirectories: [home])
        XCTAssertEqual(cyclic.diagnostics.count, 1)
        XCTAssertEqual(cyclic.configuredRawChangePaths(for: sidecar.path), [sidecar.path])
        try FileManager.default.removeItem(at: sidecar)
        for index in 0..<41 {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("hop-\(index)").path,
                withDestinationPath: "hop-\(index + 1)")
        }
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: root.appendingPathComponent("hop-0"))
        XCTAssertEqual(CodexMetadataSidecarMapping(metadataDirectories: [home]).diagnostics.count, 1)
    }
    func testExternalOnlyRecoveryAcrossSimulatedVolumeIdentifiers() throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let external = root.appendingPathComponent("external")
        for url in [home, external] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let target = external.appendingPathComponent("names")
        try Data().write(to: target)
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [home])
        for flag in [kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged,
                     kFSEventStreamEventFlagMustScanSubDirs] {
            var changes = SourceChanges()
            changes.include(path: external.path, flags: UInt32(flag), eventID: 12,
                streamIdentifier: "simulated-external-volume", streamRoots: [external.path])
            let relevant = CodexMetadataWatcher.configuredChanges(changes, mapping: mapping)
            XCTAssertTrue(relevant.paths.contains(sidecar.path))
            XCTAssertTrue(relevant.watermarks.isEmpty)
            XCTAssertTrue(relevant.streamRoots.isEmpty)
            XCTAssertTrue(relevant.reconciliationPaths.isEmpty)
        }
        for index in 0..<10_000 {
            XCTAssertFalse(CodexMetadataWatcher.accepts(path: external.appendingPathComponent("unrelated-\(index)").path,
                flags: UInt32(kFSEventStreamEventFlagItemModified), mapping: mapping))
        }
        XCTAssertFalse(CodexMetadataWatcher.accepts(path: external.appendingPathComponent("unrelated-directory").path,
            flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated), mapping: mapping))
        XCTAssertFalse(CodexMetadataWatcher.accepts(path: external.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified), mapping: mapping))
        XCTAssertTrue(CodexMetadataWatcher.accepts(path: target.path, flags: UInt32(kFSEventStreamEventFlagItemModified), mapping: mapping))
        if !TraceFileIO.canonicalPath(target.path).isCaseSensitive {
            XCTAssertEqual(mapping.configuredRawChangePaths(for: target.path.uppercased()), [sidecar.path])
            XCTAssertTrue(mapping.configuredRecoveryPaths(for: external.path.uppercased()).contains(sidecar.path))
        }
    }
    func testNegativeDeviceIdentityAndDevNullTargetAreSafe() throws {
        XCTAssertEqual(TraceFileIO.unsignedDevice(-1), UInt64(UInt32.max))
        XCTAssertEqual(TraceFileIO.unsignedDevice(Int32.min), 2_147_483_648)
        let root = try fixture()
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: "/dev/null")
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [root])
        XCTAssertEqual(mapping.configuredChangePaths(for: "/dev/null"), [sidecar.path])
        XCTAssertFalse(mapping.topologyHasChanged)
        var status = stat()
        XCTAssertEqual(lstat("/dev/null", &status), 0)
        let fingerprint = try TraceFileIO.fingerprint(url: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(fingerprint.device, UInt64(UInt32(bitPattern: status.st_dev)))
    }

    func testFifoSidecarsDoNotBlockActivationOrMetadataReads() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("configured")
        let userHome = root.appendingPathComponent("user-home")
        for directory in [home, userHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let pipe = userHome.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for name in ["state_7.sqlite", "session_index.jsonl"] {
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(name), withDestinationURL: pipe)
        }
        let received = OSAllocatedUnfairLock(initialState: [String]())
        let watcher = CodexMetadataWatcher(metadataDirectories: [home],
            mapping: CodexMetadataSidecarMapping(metadataDirectories: [home], userHome: userHome)) { _, warnings in
                received.withLock { $0 = warnings }
            }
        watcher.userHomeForTesting = userHome
        let descriptors = OSAllocatedUnfairLock(initialState: [Int32]())
        watcher.openNamespaceForTesting = { path in
            let fd = open(path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            if fd >= 0 { descriptors.withLock { $0.append(fd) } }
            return fd
        }
        let started = expectation(description: "FIFO monitoring activation returns")
        let activated = OSAllocatedUnfairLock(initialState: false)
        Task {
            await watcher.start()
            activated.withLock { $0 = true }
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        defer { watcher.stop() }
        guard activated.withLock({ $0 }) else { return }
        XCTAssertFalse(received.withLock { $0.isEmpty })
        XCTAssertTrue(watcher.directContentPathsForTesting.isEmpty)
        let metadataRead = expectation(description: "FIFO metadata reads return")
        let unavailable = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            if case .unavailable? = try? CodexSessionNames.load(directory: home) {
                unavailable.withLock { $0 = true }
            }
            metadataRead.fulfill()
        }
        await fulfillment(of: [metadataRead], timeout: 2)
        XCTAssertTrue(unavailable.withLock { $0 }, "Special metadata files must produce an optional-source warning")
        let stopped = expectation(description: "FIFO watcher shutdown closes descriptors")
        let closed = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            let opened = watcher.monitorDescriptorsForTesting
            watcher.stop()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !opened.allSatisfy({ fcntl($0, F_GETFD) == -1 && errno == EBADF }),
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            closed.withLock { $0 = !opened.isEmpty && opened.allSatisfy { fcntl($0, F_GETFD) == -1 && errno == EBADF } }
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertTrue(closed.withLock { $0 })
    }

    func testJSONMetadataOpenRejectsRetargetedFifoAndClosesItsDescriptor() throws {
        let root = try fixture()
        let original = root.appendingPathComponent("names")
        try Data("original\n".utf8).write(to: original)
        let pipe = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: original)
        var descriptor: Int32 = -1
        XCTAssertThrowsError(try JSONLineCursor(url: sidecar, from: 0, openFile: { path, flags in
            XCTAssertNotEqual(flags & O_NONBLOCK, 0)
            XCTAssertEqual(unlink(path), 0)
            XCTAssertEqual(symlink(pipe.path, path), 0)
            // Keep this regression bounded even if nonblocking behavior regresses.
            descriptor = open(path, flags | O_NONBLOCK)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            return descriptor
        })) { error in
            guard case SessionSourceError.unreadableFile(let message) = error else {
                return XCTFail("Expected descriptor type rejection, got \(error)")
            }
            XCTAssertTrue(message.contains("not a regular file"))
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testJSONMetadataCursorReadsTheOpenedFileAfterSymlinkRetarget() throws {
        let root = try fixture()
        let original = root.appendingPathComponent("names")
        let data = Data("original names\n".utf8)
        try data.write(to: original)
        let pipe = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: original)
        let cursor = try JSONLineCursor(url: sidecar, from: 0, openFile: { path, flags in
            let fd = open(path, flags)
            XCTAssertGreaterThanOrEqual(fd, 0)
            XCTAssertEqual(unlink(path), 0)
            XCTAssertEqual(symlink(pipe.path, path), 0)
            return fd
        })
        XCTAssertEqual(try cursor.next()?.data, Data("original names".utf8))
        XCTAssertNil(try cursor.next())
    }

    func testSQLiteVFSRejectsAFileReplacedByFifoDuringOpen() throws {
        let root = try fixture()
        let target = root.appendingPathComponent("state_7.sqlite")
        try Data().write(to: target)
        let vfs = try XCTUnwrap(sqlite3_vfs_find(nil))
        let setSystemCall = try XCTUnwrap(vfs.pointee.xSetSystemCall)
        let getSystemCall = try XCTUnwrap(vfs.pointee.xGetSystemCall)
        let originalOpen = try XCTUnwrap(getSystemCall(vfs, "open"))
        SQLiteMetadataOpenRace.state.withLock { $0 = .init(path: target.path) }
        let injectedOpen = unsafeBitCast(SQLiteMetadataOpenRace.open, to: sqlite3_syscall_ptr.self)
        XCTAssertEqual(setSystemCall(vfs, "open", injectedOpen), SQLITE_OK)
        defer {
            XCTAssertEqual(setSystemCall(vfs, "open", originalOpen), SQLITE_OK)
            SQLiteMetadataOpenRace.state.withLock { $0 = .init() }
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(vfs.pointee.szOsFile), alignment: MemoryLayout<sqlite3_file>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(vfs.pointee.szOsFile))
        let file = storage.assumingMemoryBound(to: sqlite3_file.self)
        // SQLite's VFS requires a filename terminated by two zero bytes.
        let filename = target.path.utf8.map { CChar(bitPattern: $0) } + [0, 0]
        try filename.withUnsafeBufferPointer { name in
            let openFile = try XCTUnwrap(vfs.pointee.xOpen)
            let result = openFile(vfs, name.baseAddress, file, SQLITE_OPEN_READONLY | SQLITE_OPEN_MAIN_DB, nil)
            defer { if let methods = file.pointee.pMethods { _ = methods.pointee.xClose?(file) } }
            XCTAssertEqual(result & 0xff, SQLITE_CANTOPEN)
            let observed = SQLiteMetadataOpenRace.state.withLock { $0 }
            XCTAssertNotEqual(observed.flags & O_NONBLOCK, 0, "SQLite must pass nonblocking flags to its actual open")
            XCTAssertEqual(observed.retargetResult, 0)
            XCTAssertGreaterThanOrEqual(observed.descriptor, 0, "Exercise fstat rejection of a successfully opened FIFO")
            XCTAssertEqual(fcntl(observed.descriptor, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testSQLiteSpecialCompanionsRejectWithoutBlockingOrLeakingDescriptors() throws {
        // Link the exact static SQLite archive used by this test host into a
        // child-loadable library; system SQLite would not exercise our VFS.
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let library = try fixture().appendingPathComponent("sqlite-probe.dylib").path
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = ["-dynamiclib", "-fprofile-instr-generate", "-Wl,-force_load," + build.appendingPathComponent("libsqlitecustom.a").path,
                              "-framework", "Foundation", "-o", library]
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let script = #"""
        import ctypes, json, os, sys
        sqlite = ctypes.CDLL(sys.argv[1])
        sqlite.sqlite3_open_v2.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_int, ctypes.c_char_p]
        sqlite.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        sqlite.sqlite3_close.argtypes = [ctypes.c_void_p]
        before = len(os.listdir('/dev/fd'))
        db = ctypes.c_void_p()
        rc = sqlite.sqlite3_open_v2(sys.argv[2].encode(), ctypes.byref(db), 1 | 64, None)
        if rc == 0: rc = sqlite.sqlite3_exec(db, b'SELECT * FROM threads', None, None, None)
        sqlite.sqlite3_close(db)
        print(json.dumps({'result': rc, 'before': before, 'after': len(os.listdir('/dev/fd'))}))
        sys.exit(0 if rc != 0 else 2)
        """#
        for suffix in ["", "-journal", "-wal", "-shm", "-shm-readonly"] {
            for symlinked in [false, true] {
                let root = try fixture()
                let database = root.appendingPathComponent("state_7.sqlite")
                let queue = try DatabaseQueue(path: database.path)
                if suffix.hasPrefix("-shm") || suffix == "-wal" {
                    try queue.writeWithoutTransaction { db in
                        XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL"), "wal")
                    }
                }
                try queue.write { db in
                    try db.execute(sql: "CREATE TABLE threads(id TEXT, title TEXT)")
                    try db.execute(sql: "INSERT INTO threads VALUES ('id', 'Preserved title')")
                }
                let target = URL(fileURLWithPath: database.path + (suffix == "-shm-readonly" ? "-shm" : suffix))
                try? FileManager.default.removeItem(at: target)
                if symlinked {
                    let pipe = root.appendingPathComponent("pipe")
                    XCTAssertEqual(mkfifo(pipe.path, 0o400), 0)
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: pipe)
                } else {
                    XCTAssertEqual(mkfifo(target.path, suffix == "-shm-readonly" ? 0o400 : 0o600), 0)
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                let uri = "file:" + database.path + (suffix == "-shm-readonly" ? "?readonly_shm=1" : "")
                process.arguments = ["-c", script, library, uri]
                let output = Pipe(); process.standardOutput = output; process.standardError = output
                try process.run()
                let deadline = Date().addingTimeInterval(4)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                let evidence = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTAssertEqual(process.terminationStatus, 0, "\(suffix), symlink=\(symlinked): bounded SQLite rejection; \(evidence)")
                if let data = evidence.data(using: .utf8),
                   let values = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
                    XCTAssertLessThanOrEqual(values["after"] ?? 1000, (values["before"] ?? 0) + 1,
                        "Rejected SQLite descriptors must close")
                }
                withExtendedLifetime(queue) {}
            }
        }
    }

    func testNullSessionIndexIsCompleteAndLoadsAllStateTitles() throws {
        let root = try fixture()
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("session_index.jsonl").path,
                                                   withDestinationPath: "/dev/null")
        let queue = try DatabaseQueue(path: root.appendingPathComponent("state_7.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT, name TEXT, title TEXT)")
            try db.execute(sql: "INSERT INTO threads VALUES ('one', NULL, 'First title'), ('two', NULL, 'Second title')")
        }
        guard case .loaded(let names) = try CodexSessionNames.load(directory: root) else {
            return XCTFail("Null session index should be an empty successful provider")
        }
        XCTAssertTrue(names.complete)
        XCTAssertNil(names.warning)
        XCTAssertEqual(names.names["one"]?.value, "First title")
        XCTAssertEqual(names.names["two"]?.value, "Second title")
        XCTAssertThrowsError(try TraceFileIO.openRegularMetadataFile(URL(fileURLWithPath: "/dev/null")))
        XCTAssertThrowsError(try JSONLineCursor(url: URL(fileURLWithPath: "/dev/zero"), from: 0,
                                              allowingNullSessionIndex: true))
    }

    func testRejectedMonitorDescriptorsAreClosed() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("configured")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("names")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("session_index.jsonl"), withDestinationURL: target)
        let descriptors = OSAllocatedUnfairLock(initialState: [Int32]())
        let watcher = CodexMetadataWatcher(metadataDirectories: [home],
            mapping: CodexMetadataSidecarMapping(metadataDirectories: [home], userHome: root)) { _, _ in }
        watcher.userHomeForTesting = root
        watcher.openNamespaceForTesting = { _ in
            let fd = open(target.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            descriptors.withLock { $0.append(fd) }
            return fd
        }
        watcher.openFileForTesting = { _ in
            let fd = open(root.path, O_EVTONLY | O_NONBLOCK | O_CLOEXEC)
            descriptors.withLock { $0.append(fd) }
            return fd
        }
        await watcher.start()
        defer { watcher.stop() }
        XCTAssertFalse(descriptors.withLock { $0.isEmpty })
        for fd in descriptors.withLock({ $0 }) {
            XCTAssertEqual(fcntl(fd, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF)
        }
    }

    func testHomeFileMonitorObservesAppendReplacementAndMissingWalCreation() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("configured")
        let userHome = root.appendingPathComponent("user-home")
        for dir in [home, userHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let target = userHome.appendingPathComponent("names")
        let sidecar = home.appendingPathComponent("state_7.sqlite")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        let snapshot = CodexMetadataSidecarMapping(metadataDirectories: [home], userHome: userHome)
        XCTAssertFalse(snapshot.targetDirectories.contains { $0.path == userHome.path || $0.path == "/" })
        XCTAssertTrue(snapshot.namespaceDirectories.contains { $0.path == userHome.path })
        XCTAssertTrue(snapshot.directContentFiles.contains(target))
        let received = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: snapshot) { changes, _ in
            if changes.hasIndexWork { received.withLock { $0.append(changes.paths) } }
        }
        watcher.userHomeForTesting = userHome
        await watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(250))
        func count() -> Int { received.withLock { $0.filter { $0.contains(sidecar.path) }.count } }
        var prior = count()
        try Data("first".utf8).write(to: target)
        var observed = await eventually { count() > prior && watcher.directContentPathsForTesting.contains(target.path) }
        XCTAssertTrue(observed, "namespace creation must install the missing target")
        try await Task.sleep(for: .milliseconds(200)); prior = count()
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("append".utf8)); try handle.close()
        observed = await eventually { count() > prior }; XCTAssertTrue(observed)
        try await Task.sleep(for: .milliseconds(200)); prior = count()
        let replacement = userHome.appendingPathComponent("replacement")
        try Data("replace".utf8).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, target.path), 0)
        observed = await eventually { count() > prior }; XCTAssertTrue(observed)
        try await Task.sleep(for: .milliseconds(200)); prior = count()
        let reopened = try FileHandle(forWritingTo: target)
        try reopened.seekToEnd(); try reopened.write(contentsOf: Data("new inode append".utf8)); try reopened.close()
        observed = await eventually { count() > prior }; XCTAssertTrue(observed, "replacement inode must be reopened")
        try await Task.sleep(for: .milliseconds(200)); prior = count()
        let wal = URL(fileURLWithPath: target.path + "-wal")
        try Data("wal".utf8).write(to: wal)
        observed = await eventually { count() > prior && watcher.directContentPathsForTesting.contains(wal.path) }
        XCTAssertTrue(observed)
        try await Task.sleep(for: .milliseconds(200)); prior = count()
        let walHandle = try FileHandle(forWritingTo: wal)
        try walHandle.seekToEnd(); try walHandle.write(contentsOf: Data("append".utf8)); try walHandle.close()
        observed = await eventually { count() > prior }; XCTAssertTrue(observed)
        watcher.stop()
        _ = watcher.namespaceMonitorCountForTesting // Drain shutdown before checking descriptors.
        XCTAssertTrue(watcher.directContentPathsForTesting.isEmpty)
    }

    func testIndependentlySymlinkedWalTargetInHomeGetsDirectFileMonitor() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("configured")
        let userHome = root.appendingPathComponent("user-home")
        for dir in [home, userHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let database = home.appendingPathComponent("state_7.sqlite")
        let target = userHome.appendingPathComponent("independent-wal")
        try Data().write(to: database); try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: URL(fileURLWithPath: database.path + "-wal"), withDestinationURL: target)
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [home], userHome: userHome)
        XCTAssertTrue(mapping.directContentFiles.contains(target))
        XCTAssertFalse(mapping.targetDirectories.contains(userHome))
        let received = OSAllocatedUnfairLock(initialState: Set<String>())
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: mapping) { changes, _ in
            received.withLock { $0.formUnion(changes.paths) }
        }
        watcher.userHomeForTesting = userHome
        await watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(250)); received.withLock { $0 = [] }
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("append".utf8)); try handle.close()
        let observed = await eventually { received.withLock { $0.contains(database.path) } }
        XCTAssertTrue(observed)
    }

    func testRootTargetUsesFileAndNamespaceMonitorsWithoutRecursiveRootStream() throws {
        let root = try fixture()
        let sidecar = root.appendingPathComponent("session_index.jsonl")
        let target = "/TraceMissing-" + UUID().uuidString
        try FileManager.default.createSymbolicLink(atPath: sidecar.path, withDestinationPath: target)
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [root])
        XCTAssertTrue(mapping.directContentFiles.contains { $0.path == target })
        XCTAssertTrue(mapping.namespaceDirectories.contains { $0.path == "/" })
        XCTAssertFalse(mapping.targetDirectories.contains { $0.path == "/" })
    }

    func testSelectiveRecoveryBackoffWarningsAndShutdownUseInjectedSchedule() async throws {
        let root = try fixture()
        let homes = [root.appendingPathComponent("first/config"), root.appendingPathComponent("second/config")]
        let parents = homes.map { $0.deletingLastPathComponent() }
        for parent in parents { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        let clock = OSAllocatedUnfairLock(initialState: 100.0)
        let failedPaths = OSAllocatedUnfairLock(initialState: Set(parents.map(\.path)))
        let opens = OSAllocatedUnfairLock(initialState: [String: Int]())
        let scheduled = OSAllocatedUnfairLock(initialState: [ScheduledMetadataWork]())
        let received = OSAllocatedUnfairLock(initialState: [(Set<String>, [String])]())
        let watcher = CodexMetadataWatcher(metadataDirectories: homes,
            mapping: CodexMetadataSidecarMapping(metadataDirectories: homes)) { changes, warnings in
            received.withLock { $0.append((changes.paths, warnings)) }
        }
        watcher.nowForTesting = { clock.withLock { $0 } }
        watcher.scheduleForTesting = { delay, work in let entry = ScheduledMetadataWork(delay: delay, work: work); scheduled.withLock { $0.append(entry) } }
        watcher.openNamespaceForTesting = { path in
            opens.withLock { $0[path, default: 0] += 1 }
            if failedPaths.withLock({ $0.contains(path) }) { errno = EACCES; return -1 }
            return open(path, O_EVTONLY | O_CLOEXEC)
        }
        await watcher.start()
        defer { watcher.stop() }
        let firstKey = "namespace:" + parents[0].path
        let secondKey = "namespace:" + parents[1].path
        XCTAssertEqual(watcher.retryDelaysForTesting[firstKey], 5)
        XCTAssertEqual(watcher.retryDelaysForTesting[secondKey], 5)
        let initialCount = received.withLock { $0.count }
        watcher.retryMonitoringForTesting()
        XCTAssertEqual(received.withLock { $0.count }, initialCount, "not-due monitors and unchanged warnings stay quiet")
        failedPaths.withLock { _ = $0.remove(parents[0].path) }
        clock.withLock { $0 += 5 }
        watcher.retryMonitoringForTesting()
        XCTAssertNil(watcher.retryDelaysForTesting[firstKey])
        XCTAssertEqual(watcher.retryDelaysForTesting[secondKey], 10)
        let recovery = received.withLock { $0.last! }
        XCTAssertTrue(recovery.0.contains(homes[0].appendingPathComponent("session_index.jsonl").path))
        XCTAssertFalse(recovery.0.contains(homes[1].appendingPathComponent("session_index.jsonl").path))
        XCTAssertEqual(recovery.1.count, 1, "one unavailable monitor must not block refreshing the recovered scope")
        let recoveredCount = received.withLock { $0.count }
        for delay in [10.0, 20, 40, 80, 160, 300] {
            XCTAssertEqual(watcher.retryDelaysForTesting[secondKey], delay)
            clock.withLock { $0 += delay }
            watcher.retryMonitoringForTesting()
            XCTAssertEqual(received.withLock { $0.count }, recoveredCount, "unchanged warnings must not be republished")
        }
        XCTAssertEqual(watcher.retryDelaysForTesting[secondKey], 300)
        watcher.stop(); _ = watcher.namespaceMonitorCountForTesting
        let openCount = opens.withLock { $0 }
        for entry in scheduled.withLock({ $0 }) { watcher.performForTesting(entry.work) }
        watcher.retryMonitoringForTesting()
        XCTAssertEqual(opens.withLock { $0 }, openCount)
        XCTAssertEqual(received.withLock { $0.count }, recoveredCount)
    }

    func testLiveWalCreationAndLaterWritesAreDelivered() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("state_7.sqlite")
        let wal = URL(fileURLWithPath: file.path + "-wal")
        try Data().write(to: file)
        let received = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let watcher = CodexMetadataWatcher(metadataDirectories: [root], mapping: CodexMetadataSidecarMapping(metadataDirectories: [root])) {
            changes, _ in if changes.paths.contains(file.path) { received.withLock { $0.append(changes.paths) } }
        }
        await watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(250))
        received.withLock { $0 = [] }
        try Data("wal".utf8).write(to: wal)
        var observed = await eventually { received.withLock { !$0.isEmpty } }
        XCTAssertTrue(observed)
        try await Task.sleep(for: .milliseconds(200))
        let priorCount = received.withLock { $0.count }
        let handle = try FileHandle(forWritingTo: wal)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("later write".utf8)); try handle.close()
        observed = await eventually { received.withLock { $0.count > priorCount } }
        XCTAssertTrue(observed, "a later write must create a new batch")
    }

    func testContentAndNamespaceBatchUsesQuietWindowAndMaximumDelay() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("state_7.sqlite")
        try Data().write(to: file)
        let clock = OSAllocatedUnfairLock(initialState: 10.0)
        let scheduled = OSAllocatedUnfairLock(initialState: [ScheduledMetadataWork]())
        let received = OSAllocatedUnfairLock(initialState: [Set<String>]())
        let watcher = CodexMetadataWatcher(metadataDirectories: [root], mapping: CodexMetadataSidecarMapping(metadataDirectories: [root])) {
            changes, _ in received.withLock { $0.append(changes.paths) }
        }
        watcher.nowForTesting = { clock.withLock { $0 } }
        watcher.scheduleForTesting = { delay, work in let entry = ScheduledMetadataWork(delay: delay, work: work); scheduled.withLock { $0.append(entry) } }
        watcher.nativeMonitoringEnabledForTesting = false
        await watcher.start()
        defer { watcher.stop() }
        watcher.refreshTopologyForTesting()
        scheduled.withLock { $0 = [] }; received.withLock { $0 = [] }
        var changes = SourceChanges()
        changes.include(path: file.path + "-wal", flags: UInt32(kFSEventStreamEventFlagItemCreated),
            eventID: 1, streamIdentifier: "metadata")
        watcher.receiveForTesting(changes, namespacePath: root.path)
        XCTAssertEqual(scheduled.withLock { $0.last!.delay }, 0.05, accuracy: 0.0001)
        clock.withLock { $0 += 0.04 }
        watcher.receiveForTesting(changes)
        XCTAssertEqual(scheduled.withLock { $0.last!.delay }, 0.05, accuracy: 0.0001)
        clock.withLock { $0 += 0.04 }
        watcher.receiveForTesting(changes)
        XCTAssertEqual(scheduled.withLock { $0.last!.delay }, 0.02, accuracy: 0.0001)
        let work = scheduled.withLock { $0.last! }.work
        for entry in scheduled.withLock({ Array($0.dropLast()) }) { watcher.performForTesting(entry.work) }
        XCTAssertTrue(received.withLock { $0.isEmpty })
        clock.withLock { $0 += 0.02 }; watcher.performForTesting(work)
        XCTAssertEqual(received.withLock { $0 }, [[file.path]])
        watcher.receiveForTesting(changes)
        watcher.performForTesting(scheduled.withLock { $0.last! }.work)
        XCTAssertEqual(received.withLock { $0.count }, 2, "subsequent writes require a new batch")
        watcher.receiveForTesting(changes)
        watcher.stop(); _ = watcher.namespaceMonitorCountForTesting
        watcher.performForTesting(scheduled.withLock { $0.last! }.work)
        XCTAssertEqual(received.withLock { $0.count }, 2, "shutdown discards pending batches")
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func testMissingHomeAndEmptySymlinkTargetUseNamespaceMonitors() throws {
        let root = try fixture()
        let home = root.appendingPathComponent(".codex")
        let target = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let missing = CodexMetadataSidecarMapping(metadataDirectories: [home])
        XCTAssertFalse(missing.targetDirectories.contains { $0.path == root.path || $0.path == "/" })
        XCTAssertTrue(missing.namespaceDirectories.contains { $0.path == root.path })
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: target)
        XCTAssertTrue(missing.topologyHasChanged)
        let linked = CodexMetadataSidecarMapping(metadataDirectories: [home])
        XCTAssertTrue(linked.targetDirectories.contains { $0.path == target.path })
        XCTAssertFalse(linked.targetDirectories.contains { $0.path == "/" })
        try FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertTrue(linked.topologyHasChanged)
    }

    func testSystemAliasAncestorsNeverCreateRecursiveRootStreams() throws {
        let root = try fixture()
        let home = root.appendingPathComponent(".codex")
        try FileManager.default.createSymbolicLink(atPath: home.path,
            withDestinationPath: "/tmp/TraceMissing-" + UUID().uuidString + "/home")
        let mapping = CodexMetadataSidecarMapping(metadataDirectories: [home])
        XCTAssertFalse(mapping.targetDirectories.contains { $0.path == "/" })
        XCTAssertTrue(mapping.namespaceDirectories.contains { $0.path == "/" })
    }

    func testStartupRebuildsStaleSnapshotAndRechecksAfterActivation() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let external = root.appendingPathComponent("external")
        for path in [home, external] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let snapshot = CodexMetadataSidecarMapping(metadataDirectories: [home])
        let target = external.appendingPathComponent("names")
        try Data().write(to: target)
        let sidecar = home.appendingPathComponent("state_7.sqlite")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        let records = OSAllocatedUnfairLock<[SourceChanges]>(initialState: [])
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: snapshot) {
            changes, _ in records.withLock { $0.append(changes) }
        }
        let index = home.appendingPathComponent("session_index.jsonl")
        watcher.afterActivationForTesting = {
            try? FileManager.default.createSymbolicLink(at: index, withDestinationURL: target)
        }
        await watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        records.withLock { $0 = [] }
        try Data([1]).write(to: target)
        let observed = await eventually { records.withLock { $0.contains { $0.paths.isSuperset(of: [index.path, sidecar.path]) } } }
        XCTAssertTrue(observed)
    }

    func testRefreshObservesDirectoryCreatedBetweenSnapshotAndActivation() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let external = root.appendingPathComponent("external")
        for path in [home, external] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let intermediate = external.appendingPathComponent("new")
        let targetDirectory = intermediate.appendingPathComponent("deep")
        let target = targetDirectory.appendingPathComponent("names")
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        let records = OSAllocatedUnfairLock<[SourceChanges]>(initialState: [])
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: .init(metadataDirectories: [home])) {
            changes, _ in records.withLock { $0.append(changes) }
        }
        // Deliver the parent notification explicitly. A quiet vnode prevents a
        // second native parent event from accidentally repairing the activation gap.
        watcher.openNamespaceForTesting = { _ in open("/dev/null", O_EVTONLY | O_CLOEXEC) }
        await watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: false)
        let injected = OSAllocatedUnfairLock(initialState: false)
        watcher.beforeActivationForTesting = {
            if injected.withLock({ value in let old = value; value = true; return old }) { return }
            try? FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
            try? Data().write(to: target)
        }
        watcher.refreshTopologyForTesting()
        XCTAssertTrue(injected.withLock { $0 })
        XCTAssertTrue(watcher.contentDirectoryPathsForTesting.contains(targetDirectory.path),
                      "refresh must recheck the namespace after activating its next level")
        records.withLock { $0 = [] }
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let observed = await eventually { records.withLock { $0.contains { $0.paths.contains(sidecar.path) } } }
        XCTAssertTrue(observed, "a later write must reach the configured sidecar without another parent event")
    }

    func testLiveEmptyHomeLinkAndMissingAncestorsBecomeMonitored() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let external = root.appendingPathComponent("missing/deep")
        let records = OSAllocatedUnfairLock<[SourceChanges]>(initialState: [])
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: .init(metadataDirectories: [home])) {
            changes, _ in records.withLock { $0.append(changes) }
        }
        await watcher.start()
        defer { watcher.stop() }
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: external)
        try await Task.sleep(for: .milliseconds(200))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(200))
        let index = external.appendingPathComponent("session_index.jsonl")
        try Data([1]).write(to: index)
        let created = await eventually { records.withLock { $0.contains { $0.paths.contains(home.appendingPathComponent("session_index.jsonl").path) } } }
        XCTAssertTrue(created)
        try await Task.sleep(for: .milliseconds(200))
        records.withLock { $0 = [] }
        try Data([2]).write(to: index)
        let changed = await eventually { records.withLock { !$0.isEmpty } }
        XCTAssertTrue(changed)
    }

    func testUnrelatedNamespaceTrafficDoesNotPublishAndDescriptorsClose() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let records = OSAllocatedUnfairLock<Int>(initialState: 0)
        let descriptors = OSAllocatedUnfairLock<[Int32]>(initialState: [])
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: .init(metadataDirectories: [home])) {
            _, _ in records.withLock { $0 += 1 }
        }
        watcher.openNamespaceForTesting = { path in
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            if fd >= 0 { descriptors.withLock { $0.append(fd) } }
            return fd
        }
        await watcher.start()
        try await Task.sleep(for: .milliseconds(150))
        records.withLock { $0 = 0 }
        for index in 0..<500 { try Data().write(to: root.appendingPathComponent("unrelated-\(index)")) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(records.withLock { $0 }, 0)
        watcher.stop()
        let closed = await eventually { watcher.namespaceMonitorCountForTesting == 0
            && descriptors.withLock { $0.allSatisfy { fcntl($0, F_GETFD) == -1 } } }
        XCTAssertTrue(closed)
    }

    func testFailedNamespaceMonitoringRetriesAndClearsWarnings() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let fail = OSAllocatedUnfairLock(initialState: true)
        let warnings = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: .init(metadataDirectories: [home])) {
            _, value in warnings.withLock { $0.append(value) }
        }
        watcher.retryIntervalForTesting = 0.05
        watcher.openNamespaceForTesting = { path in
            fail.withLock { $0 } ? -1 : open(path, O_EVTONLY | O_CLOEXEC)
        }
        await watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(warnings.withLock { $0.first?.isEmpty == false })
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(warnings.withLock { $0.count }, 1, "identical failures are deduplicated")
        fail.withLock { $0 = false }
        let recovered = await eventually { warnings.withLock { $0.last?.isEmpty == true } }
        XCTAssertTrue(recovered)
    }

    func testRelevantChangesSurviveWatcherReplacement() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let oldStore = root.appendingPathComponent("old")
        let newStore = root.appendingPathComponent("new")
        for url in [home, oldStore, newStore] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let old = oldStore.appendingPathComponent("names")
        let new = newStore.appendingPathComponent("names")
        try Data().write(to: old); try Data().write(to: new)
        let hop = root.appendingPathComponent("hop")
        try FileManager.default.createSymbolicLink(at: hop, withDestinationURL: old)
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: hop)
        let recorder = OSAllocatedUnfairLock<[SourceChanges]>(initialState: [])
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: .init(metadataDirectories: [home])) {
            changes, _ in recorder.withLock { $0.append(changes) }
        }
        await watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(200))
        recorder.withLock { $0 = [] }
        try Data([1]).write(to: oldStore.appendingPathComponent("unrelated"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(recorder.withLock { $0.isEmpty }, "unrelated traffic must not reach the callback")
        let next = root.appendingPathComponent("next")
        try FileManager.default.createSymbolicLink(at: next, withDestinationURL: new)
        XCTAssertEqual(rename(next.path, hop.path), 0)
        try Data([2]).write(to: new)
        for _ in 0..<100 {
            if recorder.withLock({ $0.contains { $0.paths.contains(sidecar.path) } }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(recorder.withLock { $0.contains { $0.paths.contains(sidecar.path) } })
        try await Task.sleep(for: .milliseconds(250))
        recorder.withLock { $0 = [] }
        try Data([3]).write(to: new)
        for _ in 0..<100 {
            if recorder.withLock({ !$0.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(recorder.withLock { $0.contains { $0.paths.contains(sidecar.path) && $0.watermarks.isEmpty } })
    }

    func testHomeDeletionRecreationAndPopulatedLinkReopenMonitors() async throws {
        let root = try fixture()
        let home = root.appendingPathComponent("home")
        let target = root.appendingPathComponent("target")
        for path in [home, target] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let sidecar = home.appendingPathComponent("session_index.jsonl")
        let final = target.appendingPathComponent("session_index.jsonl")
        try Data("old\n".utf8).write(to: sidecar)
        try Data("new\n".utf8).write(to: final)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let watcher = CodexMetadataWatcher(metadataDirectories: [home], mapping: .init(metadataDirectories: [home])) { changes, _ in
            if changes.paths.contains(sidecar.path) { calls.withLock { $0 += 1 } }
        }
        await watcher.start()
        defer { watcher.stop() }
        calls.withLock { $0 = 0 }
        try FileManager.default.removeItem(at: home)
        let deleted = await eventually { calls.withLock { $0 > 0 } }
        XCTAssertTrue(deleted)
        calls.withLock { $0 = 0 }
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: target)
        let recreated = await eventually {
            calls.withLock { $0 > 0 } && watcher.contentDirectoryPathsForTesting.contains(target.path)
                && !watcher.contentDirectoryPathsForTesting.contains(home.path)
        }
        XCTAssertTrue(recreated)
        calls.withLock { $0 = 0 }
        try Data("updated\n".utf8).write(to: final)
        let updated = await eventually { calls.withLock { $0 > 0 } }
        XCTAssertTrue(updated, "the recreated namespace must monitor subsequent target writes; streams=\(watcher.contentDirectoryPathsForTesting)")
    }
}

private enum SQLiteMetadataOpenRace {
    struct State: Sendable {
        var path: String? = nil
        var flags: Int32 = 0
        var descriptor: Int32 = -1
        var retargetResult: Int32 = -1
    }
    static let state = OSAllocatedUnfairLock(initialState: State())
    static let open: @convention(c) (UnsafePointer<CChar>?, Int32, Int32) -> Int32 = { path, flags, mode in
        guard let path else { errno = EINVAL; return -1 }
        let filename = String(cString: path)
        let inject = state.withLock { $0.path == filename }
        guard inject else { return Darwin.open(path, flags, mode_t(truncatingIfNeeded: mode)) }
        let removed = unlink(path)
        let replaced = removed == 0 ? mkfifo(path, 0o600) : removed
        // Avoid hanging the test if the VFS loses its nonblocking flag.
        let fd = Darwin.open(path, flags | O_NONBLOCK, mode_t(truncatingIfNeeded: mode))
        state.withLock { $0.flags = flags; $0.descriptor = fd; $0.retargetResult = replaced }
        return fd
    }
}

private struct ScheduledMetadataWork: @unchecked Sendable {
    let delay: TimeInterval
    let work: DispatchWorkItem
}
