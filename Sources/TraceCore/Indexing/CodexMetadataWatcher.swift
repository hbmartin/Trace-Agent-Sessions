import CoreServices
import Darwin
import Foundation
import os

/// Namespace watches are nonrecursive. Content streams have no durable checkpoint:
/// activate them before refreshing the metadata loaded through configured paths.
public final class CodexMetadataWatcher: @unchecked Sendable {
    private let directories: [URL]
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.metadata", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let mapping: OSAllocatedUnfairLock<CodexMetadataSidecarMapping>
    private let filterMappings: OSAllocatedUnfairLock<[CodexMetadataSidecarMapping]>
    private var streams: [String: FSEventsWatcher] = [:]
    private var namespaces: [String: NamespaceMonitor] = [:]
    private var namespaceWork: DispatchWorkItem?
    private var retryTimer: DispatchSourceTimer?
    private var invalidatedNamespaces: Set<String> = []
    private var monitoringFailures: [String: String] = [:]
    private var publishedWarnings: [String]?
    private var stopped = false
    private let callback: @Sendable (SourceChanges, [String]) -> Void
    var openNamespaceForTesting: (@Sendable (String) -> Int32)?
    var afterActivationForTesting: (@Sendable () -> Void)?
    var retryIntervalForTesting: TimeInterval = 5

    public init(metadataDirectories: [URL], mapping: CodexMetadataSidecarMapping,
                onChange: @escaping @Sendable (SourceChanges, [String]) -> Void) {
        directories = metadataDirectories
        self.mapping = OSAllocatedUnfairLock(initialState: mapping)
        filterMappings = OSAllocatedUnfairLock(initialState: [mapping])
        callback = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    public func start() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var changes = replace(CodexMetadataSidecarMapping(metadataDirectories: directories), refresh: true)
                afterActivationForTesting?()
                afterActivationForTesting = nil
                let installed = mapping.withLock { $0 }
                if installed.topologyHasChanged {
                    changes.merge(replace(CodexMetadataSidecarMapping(metadataDirectories: directories), refresh: true))
                }
                publish(changes)
                continuation.resume()
            }
        }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { stopOnQueue() }
        else if Thread.isMainThread { queue.async { [self] in stopOnQueue() } }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        stopped = true
        namespaceWork?.cancel(); namespaceWork = nil
        retryTimer?.cancel(); retryTimer = nil
        namespaces.values.forEach { $0.cancel() }; namespaces = [:]
        streams.values.forEach { $0.stop() }; streams = [:]
        invalidatedNamespaces = []
        monitoringFailures = [:]
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
            && flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
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
        var relevant = Self.configuredChanges(changes, mapping: previous)
        relevant.merge(Self.configuredChanges(changes, mapping: observedMapping))
        let paths = changes.paths.union(changes.lexicalPaths).union(changes.structuralPaths)
        let rebuild = paths.contains { previous.linkPaths.contains($0) }
            || changes.structuralPaths.contains {
                previous.isMetadataStructurePath($0) || !previous.configuredRawChangePaths(for: $0).isEmpty
            } || !changes.reconciliationPaths.isEmpty
        if rebuild && (previous.topologyHasChanged || !changes.reconciliationPaths.isEmpty) {
            relevant.merge(replace(CodexMetadataSidecarMapping(metadataDirectories: directories), refresh: false,
                restartScopes: changes.recoveryReasons.contains(.rootChanged) ? changes.reconciliationPaths : []))
        }
        publish(relevant)
    }

    private func namespaceChanged(path: String, invalidated: Bool) {
        guard !stopped else { return }
        if invalidated { invalidatedNamespaces.insert(path) }
        guard namespaceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.namespaceWork = nil
            self.refreshTopology(forceRetry: false)
        }
        namespaceWork = work
        queue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func refreshTopology(forceRetry: Bool) {
        guard !stopped else { return }
        let previous = mapping.withLock { $0 }
        guard forceRetry || !invalidatedNamespaces.isEmpty || previous.topologyHasChanged else { return }
        var changes = replace(CodexMetadataSidecarMapping(metadataDirectories: directories), refresh: false)
        if forceRetry && monitoringFailures.isEmpty { changes.paths.formUnion(mapping.withLock { $0.configuredSidecars }) }
        publish(changes)
    }

    private func replace(_ next: CodexMetadataSidecarMapping, refresh: Bool,
                         restartScopes: Set<String> = []) -> SourceChanges {
        guard !stopped else { return SourceChanges() }
        let previous = mapping.withLock { $0 }
        // Filtering covers both generations until all old streams have drained.
        filterMappings.withLock { $0 = [previous, next] }
        var failures: [String: String] = [:]
        for directory in next.targetDirectories {
            let path = directory.path
            let restart = next.monitorIdentityChanged(at: path, comparedTo: previous)
                || restartScopes.contains { scope in
                    path == scope || path.hasPrefix(scope + "/") || scope.hasPrefix(path + "/")
                }
            guard streams[path] == nil || restart else { continue }
            let watcher = FSEventsWatcher(roots: [directory], identifier: "metadata:\(path)",
                eventFilter: { [weak self] path, flags in
                    self?.filterMappings.withLock { $0.contains { Self.accepts(path: path, flags: flags, mapping: $0) } } ?? false
                }, tracksWatermarks: false) { [weak self] changes in
                    guard let self else { return }
                    // A queued old batch retains its own mapping, not a growing history.
                    self.queue.async { self.receive(changes, observedMapping: next) }
                }
            if watcher.start() { streams.updateValue(watcher, forKey: path)?.stop(flushPending: true) }
            else {
                if restart { streams.removeValue(forKey: path)?.stop(flushPending: true) }
                failures["stream:" + path] = "\(path): incomplete Codex metadata monitoring"
            }
        }
        for directory in next.namespaceDirectories {
            let path = directory.path
            guard namespaces[path] == nil || invalidatedNamespaces.contains(path)
                || next.monitorIdentityChanged(at: path, comparedTo: previous) else { continue }
            namespaces.removeValue(forKey: path)?.cancel()
            let fd = openNamespaceForTesting?(path) ?? open(path, O_EVTONLY | O_CLOEXEC)
            if fd >= 0 {
                let monitor = NamespaceMonitor(fd: fd, queue: queue) { [weak self] invalidated in
                    self?.namespaceChanged(path: path, invalidated: invalidated)
                }
                namespaces.updateValue(monitor, forKey: path)?.cancel()
            } else { failures["namespace:" + path] = "\(path): incomplete Codex metadata monitoring" }
        }
        mapping.withLock { $0 = next }
        for path in Set(streams.keys).subtracting(next.targetDirectories.map(\.path)) {
            streams.removeValue(forKey: path)?.stop(flushPending: true)
        }
        for path in Set(namespaces.keys).subtracting(next.namespaceDirectories.map(\.path)) {
            namespaces.removeValue(forKey: path)?.cancel()
        }
        invalidatedNamespaces = []
        monitoringFailures = failures
        filterMappings.withLock { $0 = [next] }
        if failures.isEmpty { retryTimer?.cancel(); retryTimer = nil }
        else if retryTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + retryIntervalForTesting, repeating: retryIntervalForTesting)
            timer.setEventHandler { [weak self] in self?.refreshTopology(forceRetry: true) }
            retryTimer = timer; timer.activate()
        }
        var changes = SourceChanges()
        changes.paths = refresh ? next.configuredSidecars : previous.configuredSidecarsWithChangedDependencies(comparedTo: next)
        return changes
    }

    private func publish(_ changes: SourceChanges) {
        guard !stopped else { return }
        let warnings = Array(Set(mapping.withLock { $0.diagnostics } + monitoringFailures.values)).sorted()
        if changes.hasIndexWork || warnings != publishedWarnings {
            publishedWarnings = warnings
            callback(changes, warnings)
        }
    }

    var namespaceMonitorCountForTesting: Int {
        queue.sync { namespaces.count }
    }

    var contentDirectoryPathsForTesting: Set<String> {
        queue.sync { Set(streams.keys) }
    }
}

private final class NamespaceMonitor {
    private let source: any DispatchSourceFileSystemObject
    init(fd: Int32, queue: DispatchQueue, changed: @escaping @Sendable (Bool) -> Void) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .revoke, .attrib, .link], queue: queue)
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
