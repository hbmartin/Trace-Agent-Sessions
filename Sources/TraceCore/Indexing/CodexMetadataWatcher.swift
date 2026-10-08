import CoreServices
import Darwin
import Foundation
import os

/// Namespace watches are nonrecursive. Content streams have no durable checkpoint:
/// activate them before refreshing the metadata loaded through configured paths.
public final class CodexMetadataWatcher: @unchecked Sendable {
    private struct MonitoringFailure {
        let message: String
        let attempt: Int
        let nextRetry: TimeInterval
    }
    private let directories: [URL]
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.metadata", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let mapping: OSAllocatedUnfairLock<CodexMetadataSidecarMapping>
    private let filterMappings: OSAllocatedUnfairLock<[CodexMetadataSidecarMapping]>
    private var streams: [String: FSEventsWatcher] = [:]
    private var namespaces: [String: VnodeMonitor] = [:]
    private var files: [String: VnodeMonitor] = [:]
    private var batchWork: DispatchWorkItem?
    private var batchStartedAt: TimeInterval?
    private var batchGeneration: UInt64 = 0
    private var pendingChanges = SourceChanges()
    private var pendingRawChanges = SourceChanges()
    private var pendingTopologyCheck = false
    private var pendingRestartScopes: Set<String> = []
    private var retryWork: DispatchWorkItem?
    private var retryGeneration: UInt64 = 0
    private var invalidatedNamespaces: Set<String> = []
    private var invalidatedFiles: Set<String> = []
    private var monitoringFailures: [String: MonitoringFailure] = [:]
    private var publishedWarnings: [String]?
    private var stopped = false
    private let callback: @Sendable (SourceChanges, [String]) -> Void
    var openNamespaceForTesting: (@Sendable (String) -> Int32)?
    var openFileForTesting: (@Sendable (String) -> Int32)?
    var afterActivationForTesting: (@Sendable () -> Void)?
    var beforeActivationForTesting: (@Sendable () -> Void)?
    var userHomeForTesting: URL?
    var nowForTesting: (@Sendable () -> TimeInterval)?
    var scheduleForTesting: (@Sendable (TimeInterval, DispatchWorkItem) -> Void)?
    var retryIntervalForTesting: TimeInterval = 5

    public init(metadataDirectories: [URL], mapping: CodexMetadataSidecarMapping,
                onChange: @escaping @Sendable (SourceChanges, [String]) -> Void) {
        directories = metadataDirectories
        self.mapping = OSAllocatedUnfairLock(initialState: mapping)
        filterMappings = OSAllocatedUnfairLock(initialState: [mapping])
        callback = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    private var now: TimeInterval { nowForTesting?() ?? ProcessInfo.processInfo.systemUptime }

    private func makeMapping() -> CodexMetadataSidecarMapping {
        CodexMetadataSidecarMapping(metadataDirectories: directories,
            userHome: userHomeForTesting ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    public func start() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let activation = afterActivationForTesting
                afterActivationForTesting = nil
                publish(installStableMapping(refresh: true, afterActivation: activation))
                continuation.resume()
            }
        }
        if let delay = TraceTestHooks.delayMilliseconds(for: "TRACE_TEST_METADATA_START_DELAY_MS", cappedAt: 30_000,
            marker: .touch(pathKey: "TRACE_TEST_METADATA_START_ENTERED_PATH")) {
            try? await TraceTestHooks.waitForRelease(pathKey: "TRACE_TEST_METADATA_START_RELEASE_PATH", timeoutMilliseconds: delay)
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { stopOnQueue() }
        else if Thread.isMainThread { queue.async { [self] in stopOnQueue() } }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        stopped = true
        batchGeneration &+= 1
        batchWork?.cancel(); batchWork = nil
        retryGeneration &+= 1
        retryWork?.cancel(); retryWork = nil
        namespaces.values.forEach { $0.cancel() }; namespaces = [:]
        files.values.forEach { $0.cancel() }; files = [:]
        streams.values.forEach { $0.stop() }; streams = [:]
        invalidatedNamespaces = []; invalidatedFiles = []
        monitoringFailures = [:]
        pendingChanges = SourceChanges(); pendingRawChanges = SourceChanges()
        filterMappings.withLock { $0 = [] }
    }

    /// Raw-path filtering performs no stat, canonicalization, or actor hop.
    public static func accepts(path: String, flags: FSEventStreamEventFlags,
                               mapping: CodexMetadataSidecarMapping) -> Bool {
        let globalRecovery = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & globalRecovery != 0 { return true }
        let recovery = UInt32(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMustScanSubDirs)
        let directoryStructure = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
            && flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCloned) != 0
        if (flags & recovery != 0 || directoryStructure), !mapping.configuredRecoveryPaths(for: path).isEmpty { return true }
        if flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 && !directoryStructure { return false }
        return !mapping.configuredRawChangePaths(for: path).isEmpty || mapping.isMetadataStructurePath(path)
    }

    public static func configuredChanges(_ changes: SourceChanges, mapping: CodexMetadataSidecarMapping) -> SourceChanges {
        var relevant = SourceChanges()
        for path in changes.paths.union(changes.lexicalPaths).union(changes.structuralPaths) {
            relevant.paths.formUnion(mapping.configuredChangePaths(for: path))
        }
        for scope in changes.reconciliationPaths { relevant.paths.formUnion(mapping.configuredRecoveryPaths(for: scope)) }
        if changes.recoveryReasons.contains(.eventsDropped) || changes.recoveryReasons.contains(.eventIDsWrapped) {
            relevant.paths.formUnion(mapping.configuredSidecars)
        }
        relevant.recoveryReasons = changes.recoveryReasons
        return relevant
    }


    private func receive(_ changes: SourceChanges, observedMapping: CodexMetadataSidecarMapping) {
        guard !stopped else { return }
        let previous = mapping.withLock { $0 }
        pendingChanges.merge(Self.configuredChanges(changes, mapping: previous))
        pendingChanges.merge(Self.configuredChanges(changes, mapping: observedMapping))
        pendingRawChanges.merge(changes)
        if changes.recoveryReasons.contains(.rootChanged) {
            pendingRestartScopes.formUnion(changes.reconciliationPaths)
        }
        scheduleBatch()
    }

    private func namespaceChanged(path: String, invalidated: Bool) {
        guard !stopped else { return }
        if invalidated { invalidatedNamespaces.insert(path) }
        pendingTopologyCheck = true
        scheduleBatch()
    }

    private func fileChanged(path: String, invalidated: Bool) {
        guard !stopped else { return }
        pendingChanges.paths.formUnion(mapping.withLock { $0.configuredChangePaths(for: path) })
        if invalidated {
            invalidatedFiles.insert(path)
            pendingTopologyCheck = true
        }
        scheduleBatch()
    }

    private func scheduleBatch() {
        guard !stopped else { return }
        if batchStartedAt == nil { batchStartedAt = now }
        let deadline = min(now + 0.05, (batchStartedAt ?? now) + 0.1)
        batchGeneration &+= 1
        let generation = batchGeneration
        batchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.batchGeneration == generation else { return }
            self.flushBatch()
        }
        batchWork = work
        schedule(work, after: max(0, deadline - now))
    }

    private func flushBatch(forceRetry: Bool = false) {
        guard !stopped else { return }
        batchGeneration &+= 1
        batchWork?.cancel(); batchWork = nil; batchStartedAt = nil
        var changes = pendingChanges
        let raw = pendingRawChanges
        let checkTopology = pendingTopologyCheck
        let restartScopes = pendingRestartScopes
        pendingChanges = SourceChanges(); pendingRawChanges = SourceChanges()
        pendingTopologyCheck = false; pendingRestartScopes = []
        let previous = mapping.withLock { $0 }
        let paths = raw.paths.union(raw.lexicalPaths).union(raw.structuralPaths)
        let structural = paths.contains { previous.linkPaths.contains($0) }
            || raw.structuralPaths.contains {
                previous.isMetadataStructurePath($0) || !previous.configuredRawChangePaths(for: $0).isEmpty
            }
        if forceRetry || !invalidatedNamespaces.isEmpty || !invalidatedFiles.isEmpty
            || !raw.reconciliationPaths.isEmpty || ((checkTopology || structural) && previous.topologyHasChanged) {
            changes.merge(installStableMapping(refresh: false, restartScopes: restartScopes))
        }
        changes.merge(Self.configuredChanges(raw, mapping: mapping.withLock { $0 }))
        publish(changes)
    }

    private func installStableMapping(refresh: Bool, restartScopes: Set<String> = [],
                                      afterActivation: (@Sendable () -> Void)? = nil) -> SourceChanges {
        var changes = SourceChanges()
        for pass in 0..<3 {
            guard !stopped else { return changes }
            changes.merge(replace(makeMapping(), refresh: refresh,
                restartScopes: pass == 0 ? restartScopes : []))
            if pass == 0 { afterActivation?() }
            if !mapping.withLock({ $0.topologyHasChanged }) { return changes }
        }
        // Continuous external churn must not monopolize the watcher queue.
        pendingTopologyCheck = true
        scheduleBatch()
        return changes
    }

    private func replace(_ next: CodexMetadataSidecarMapping, refresh: Bool,
                         restartScopes: Set<String> = []) -> SourceChanges {
        guard !stopped else { return SourceChanges() }
        beforeActivationForTesting?()
        let previous = mapping.withLock { $0 }
        let oldFailures = monitoringFailures
        filterMappings.withLock { $0 = [previous, next] }
        let desired = Set(next.targetDirectories.map { "stream:" + $0.path })
            .union(next.namespaceDirectories.map { "namespace:" + $0.path })
            .union(next.directContentFiles.map { "file:" + $0.path })
        var failures = oldFailures.filter { desired.contains($0.key) }
        func shouldAttempt(_ key: String, changed: Bool) -> Bool {
            changed || oldFailures[key].map { $0.nextRetry <= now } != false
        }
        func failed(_ key: String, path: String) {
            let attempt = (oldFailures[key]?.attempt ?? 0) + 1
            let delay = min(300, retryIntervalForTesting * pow(2, Double(min(attempt - 1, 6))))
            failures[key] = MonitoringFailure(message: "\(path): incomplete Codex metadata monitoring",
                attempt: attempt, nextRetry: now + delay)
        }
        for directory in next.targetDirectories {
            let path = directory.path
            let key = "stream:" + path
            let restart = next.monitorIdentityChanged(at: path, comparedTo: previous)
                || restartScopes.contains { scope in
                    path == scope || path.hasPrefix(scope + "/") || scope.hasPrefix(path + "/")
                }
            if streams[path] != nil && !restart { failures.removeValue(forKey: key); continue }
            guard shouldAttempt(key, changed: restart) else { continue }
            let watcher = FSEventsWatcher(roots: [directory], identifier: "metadata:\(path)",
                eventFilter: { [weak self] path, flags in
                    self?.filterMappings.withLock { $0.contains { Self.accepts(path: path, flags: flags, mapping: $0) } } ?? false
                }, tracksWatermarks: false, batchingDelay: 0) { [weak self] changes in
                    guard let self else { return }
                    self.queue.async { self.receive(changes, observedMapping: next) }
                }
            if watcher.start() {
                streams.updateValue(watcher, forKey: path)?.stop(flushPending: true)
                failures.removeValue(forKey: key)
            } else {
                if restart { streams.removeValue(forKey: path)?.stop(flushPending: true) }
                failed(key, path: path)
            }
        }
        for directory in next.namespaceDirectories {
            let path = directory.path
            let key = "namespace:" + path
            let restart = invalidatedNamespaces.contains(path) || next.monitorIdentityChanged(at: path, comparedTo: previous)
            if namespaces[path] != nil && !restart { failures.removeValue(forKey: key); continue }
            guard shouldAttempt(key, changed: restart) else { continue }
            namespaces.removeValue(forKey: path)?.cancel()
            let fd = openNamespaceForTesting?(path) ?? open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
            if fd >= 0 {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    close(fd)
                    failed(key, path: path)
                    continue
                }
                namespaces[path] = VnodeMonitor(fd: fd, queue: queue) { [weak self] invalidated in
                    self?.namespaceChanged(path: path, invalidated: invalidated)
                }
                failures.removeValue(forKey: key)
            } else { failed(key, path: path) }
        }
        for file in next.directContentFiles {
            let path = file.path
            let key = "file:" + path
            let restart = invalidatedFiles.contains(path) || next.monitorIdentityChanged(at: path, comparedTo: previous)
            if files[path] != nil && !restart { failures.removeValue(forKey: key); continue }
            guard shouldAttempt(key, changed: restart) else { continue }
            files.removeValue(forKey: path)?.cancel()
            let fd = openFileForTesting?(path) ?? open(path, O_EVTONLY | O_CLOEXEC | O_NONBLOCK)
            let openError = errno
            if fd >= 0 {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    close(fd)
                    failed(key, path: path)
                    continue
                }
                files[path] = VnodeMonitor(fd: fd, queue: queue) { [weak self] invalidated in
                    self?.fileChanged(path: path, invalidated: invalidated)
                }
                failures.removeValue(forKey: key)
            } else if openError == ENOENT && !FileManager.default.fileExists(atPath: path) {
                // Missing targets are watched through their parent namespace.
                failures.removeValue(forKey: key)
            } else { failed(key, path: path) }
        }
        mapping.withLock { $0 = next }
        for path in Set(streams.keys).subtracting(next.targetDirectories.map(\.path)) {
            streams.removeValue(forKey: path)?.stop(flushPending: true)
        }
        for path in Set(namespaces.keys).subtracting(next.namespaceDirectories.map(\.path)) {
            namespaces.removeValue(forKey: path)?.cancel()
        }
        for path in Set(files.keys).subtracting(next.directContentFiles.map(\.path)) {
            files.removeValue(forKey: path)?.cancel()
        }
        invalidatedNamespaces = []; invalidatedFiles = []
        monitoringFailures = failures
        filterMappings.withLock { $0 = [next] }
        scheduleRetry()
        var changes = SourceChanges()
        changes.paths = refresh ? next.configuredSidecars : previous.configuredSidecarsWithChangedDependencies(comparedTo: next)
        for key in Set(oldFailures.keys).subtracting(failures.keys).intersection(desired) {
            let path = String(key.dropFirst(key.firstIndex(of: ":").map { key.distance(from: key.startIndex, to: $0) + 1 } ?? 0))
            changes.paths.formUnion(previous.configuredRecoveryPaths(for: path))
            changes.paths.formUnion(next.configuredRecoveryPaths(for: path))
        }
        return changes
    }

    private func scheduleRetry() {
        retryGeneration &+= 1
        retryWork?.cancel(); retryWork = nil
        guard !stopped, let deadline = monitoringFailures.values.map(\.nextRetry).min() else { return }
        let generation = retryGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.retryGeneration == generation else { return }
            self.flushBatch(forceRetry: true)
        }
        retryWork = work
        schedule(work, after: max(0, deadline - now))
    }

    private func schedule(_ work: DispatchWorkItem, after delay: TimeInterval) {
        if let scheduleForTesting { scheduleForTesting(delay, work) }
        else { queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    private func publish(_ changes: SourceChanges) {
        guard !stopped else { return }
        let warnings = Array(Set(mapping.withLock { $0.diagnostics } + monitoringFailures.values.map(\.message))).sorted()
        if changes.hasIndexWork || warnings != publishedWarnings {
            publishedWarnings = warnings
            callback(changes, warnings)
        }
    }

    var namespaceMonitorCountForTesting: Int { queue.sync { namespaces.count } }
    var contentDirectoryPathsForTesting: Set<String> { queue.sync { Set(streams.keys) } }
    var directContentPathsForTesting: Set<String> { queue.sync { Set(files.keys) } }
    var retryDelaysForTesting: [String: TimeInterval] {
        queue.sync { monitoringFailures.mapValues { $0.nextRetry - now } }
    }
    func refreshTopologyForTesting() {
        queue.sync { pendingTopologyCheck = true; flushBatch() }
    }
    func retryMonitoringForTesting() { queue.sync { flushBatch(forceRetry: true) } }
    func receiveForTesting(_ changes: SourceChanges, namespacePath: String? = nil) {
        queue.sync {
            receive(changes, observedMapping: mapping.withLock { $0 })
            if let namespacePath { namespaceChanged(path: namespacePath, invalidated: false) }
        }
    }
    func performForTesting(_ work: DispatchWorkItem) { queue.sync { work.perform() } }
}

private final class VnodeMonitor {
    private let source: any DispatchSourceFileSystemObject
    init(fd: Int32, queue: DispatchQueue, changed: @escaping @Sendable (Bool) -> Void) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke, .attrib, .link], queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            changed(!self.source.data.intersection([.rename, .delete, .revoke]).isEmpty)
        }
        source.setCancelHandler { close(fd) }
        source.activate()
    }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}
