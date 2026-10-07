import CoreServices
import Darwin
import Foundation
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
