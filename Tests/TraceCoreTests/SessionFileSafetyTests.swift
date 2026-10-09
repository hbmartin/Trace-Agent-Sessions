import CustomDump
import Darwin
import XCTest
@testable import TraceCore

final class SessionFileSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TraceSafeSession-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testOpenerValidatesFlagsAndClosesRejectedDescriptors() throws {
        let root = try directory(), fifo = root.appendingPathComponent("session.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        var descriptor: Int32 = -1
        XCTAssertThrowsError(try TraceFileIO.openRegularSessionFile(fifo, openFile: { path, flags in
            XCTAssertNotEqual(flags & O_NONBLOCK, 0)
            XCTAssertNotEqual(flags & O_NOCTTY, 0)
            XCTAssertNotEqual(flags & O_CLOEXEC, 0)
            // A broken flag must fail the assertion without hanging this test host.
            descriptor = open(path, flags | O_NONBLOCK | O_NOCTTY)
            return descriptor
        }))
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testFingerprintDescribesTheOpenedSymlinkTarget() throws {
        let root = try directory(), file = root.appendingPathComponent("session.jsonl")
        let link = root.appendingPathComponent("alias.jsonl")
        try Data("fixture content".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let actual = try TraceFileIO.fingerprint(url: link)
        let expected = try TraceFileIO.fingerprint(url: file)
        expectNoDifference(expected, actual)
        XCTAssertEqual(try TraceFileIO.read(url: link, offset: 0, length: actual.size), Data("fixture content".utf8))
        XCTAssertThrowsError(try TraceFileIO.read(url: link, offset: -1, length: 1))
    }

    func testSpecialSessionFilesRejectWithinABoundedChild() async throws {
        if ProcessInfo.processInfo.environment["TRACE_SESSION_FILE_CHILD"] != "1" {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "TraceCoreTests.SessionFileSafetyTests/testSpecialSessionFilesRejectWithinABoundedChild",
                               Bundle(for: Self.self).bundleURL.path]
            // XCTest's injected session configuration would attach this child to
            // the parent's runner and wait forever instead of running standalone.
            let inherited = ProcessInfo.processInfo.environment
            var environment = inherited.filter { ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR"].contains($0.key) }
            environment["LLVM_PROFILE_FILE"] = FileManager.default.temporaryDirectory
                .appendingPathComponent("trace-session-child-\(UUID()).profraw").path
            environment["TRACE_SESSION_FILE_CHILD"] = "1"
            child.environment = environment
            let output = Pipe(); child.standardOutput = output; child.standardError = output
            try child.run()
            let deadline = ContinuousClock.now + .seconds(10)
            while child.isRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(child.terminationStatus, 0, "Session-file rejection must be bounded: \(log)")
            XCTAssertTrue(log.contains("Executed 1 test"), "The child must execute the requested regression")
            return
        }
        let root = try directory(), fifo = root.appendingPathComponent("session.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let link = root.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        for file in [fifo, link, root, URL(fileURLWithPath: "/dev/null")] {
            XCTAssertThrowsError(try TraceFileIO.fingerprint(url: file))
            XCTAssertThrowsError(try TraceFileIO.read(url: file, offset: 0, length: 1))
        }
        let source = GeminiSource(root: root)
        let file = DiscoveredSourceFile(agent: .gemini, root: root, url: fifo, format: .geminiJSON)
        do {
            for try await _ in source.records(in: file, from: 0) { }
            XCTFail("Legacy Gemini must reject a FIFO")
        } catch { }
        let database = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        let coordinator = IndexCoordinator(database: database, sources: [source])
        await coordinator.refresh(paths: [fifo.path], scope: .proseOnly)
    }
}
