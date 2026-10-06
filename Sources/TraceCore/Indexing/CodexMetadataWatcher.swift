import CoreServices
import Foundation
import os

/// Metadata monitoring has no durable event checkpoint: streams start before a
/// refresh, and every replacement refreshes its affected configured sidecars.
public final class CodexMetadataWatcher: @unchecked Sendable {
    private let directories: [URL]
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.metadata", qos: .utility)
    private let mapping: OSAllocatedUnfairLock<CodexMetadataSidecarMapping>
    private var streams: [String: FSEventsWatcher] = [:]
    private var stopped = false
    private let callback: @Sendable (SourceChanges, [String]) -> Void

    public init(metadataDirectories: [URL], mapping: CodexMetadataSidecarMapping,
                onChange: @escaping @Sendable (SourceChanges, [String]) -> Void) {
        directories = metadataDirectories
        self.mapping = OSAllocatedUnfairLock(initialState: mapping)
        callback = onChange
    }

    public func start() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                replace(mapping.withLock { $0 }, refresh: true)
                continuation.resume()
            }
        }
    }
    public func stop() {
        queue.async { [self] in
            stopped = true
            streams.values.forEach { $0.stop() }
            streams = [:]
        }
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

    private func receive(_ changes: SourceChanges) {
        guard !stopped else { return }
        let previous = mapping.withLock { $0 }
        let paths = changes.paths.union(changes.lexicalPaths).union(changes.structuralPaths)
        var relevant = Self.configuredChanges(changes, mapping: previous)
        let rebuild = paths.contains { previous.linkPaths.contains($0) }
            || changes.structuralPaths.contains {
                previous.isMetadataStructurePath($0) || !previous.configuredRawChangePaths(for: $0).isEmpty
            }
            || !changes.reconciliationPaths.isEmpty
        if rebuild && (previous.topologyHasChanged || !changes.reconciliationPaths.isEmpty) {
            let next = CodexMetadataSidecarMapping(metadataDirectories: directories)
            if previous != next || changes.recoveryReasons.contains(.rootChanged) {
                // Start new streams first; flush old pending batches while replacing.
                // Queued batches are interpreted using both the old and new mappings.
                for path in paths { relevant.paths.formUnion(next.configuredChangePaths(for: path)) }
                relevant.paths.formUnion(previous.configuredSidecarsWithChangedDependencies(comparedTo: next))
                replace(next, refresh: false, restartScopes: changes.recoveryReasons.contains(.rootChanged) ? changes.reconciliationPaths : [])
            }
        }
        relevant.recoveryReasons = changes.recoveryReasons
        if relevant.hasIndexWork { callback(relevant, mapping.withLock { $0.diagnostics }) }
    }

    private func replace(_ next: CodexMetadataSidecarMapping, refresh: Bool, restartScopes: Set<String> = []) {
        guard !stopped else { return }
        let required = Set(next.targetDirectories.map(\.path))
        var warnings = next.diagnostics
        for directory in next.targetDirectories {
            let restart = restartScopes.contains { scope in
                directory.path == scope || directory.path.hasPrefix(scope + "/") || scope.hasPrefix(directory.path + "/")
            }
            guard streams[directory.path] == nil || restart else { continue }
            let watcher = FSEventsWatcher(
                roots: [directory], identifier: "metadata:\(directory.path)",
                eventFilter: { [weak self] path, flags in
                    guard let self else { return false }
                    return self.mapping.withLock { Self.accepts(path: path, flags: flags, mapping: $0) }
                }, tracksWatermarks: false
            ) { [weak self] changes in
                guard let self else { return }
                self.queue.async { self.receive(changes) }
            }
            if watcher.start() {
                let old = streams.updateValue(watcher, forKey: directory.path)
                old?.stop(flushPending: true)
            }
            else { warnings.append("\(directory.path): incomplete Codex metadata monitoring") }
        }
        // Keep the old mapping through stream startup to cover the overlap.
        mapping.withLock { $0 = next }
        for path in Set(streams.keys).subtracting(required) {
            streams.removeValue(forKey: path)?.stop(flushPending: true)
        }
        if refresh || !warnings.isEmpty {
            var changes = SourceChanges()
            if refresh { changes.paths = next.configuredSidecars }
            callback(changes, warnings)
        }
    }
}
