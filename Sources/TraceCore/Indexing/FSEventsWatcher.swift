import CoreServices
import Foundation

public enum FSEventsRecoveryReason: String, Hashable, Sendable {
    case subtreeInvalidated
    case rootChanged
    case eventsDropped
    case eventIDsWrapped
}

/// Opaque watcher chronology. Equality identifies the same post-wrap epoch;
/// lineage distinguishes delayed pre-wrap batches without comparing event IDs.
public struct IndexEventStreamEpoch: Sendable, Equatable {
    let id: UUID
    let predecessors: Set<UUID>
    init(id: UUID = UUID(), predecessors: Set<UUID> = []) { self.id = id; self.predecessors = predecessors }
    func advanced() -> Self { .init(predecessors: predecessors.union([id])) }
}

public struct SourceChanges: Sendable {
    public var paths: Set<String> = []
    /// Preserve symlink paths so a sidecar link change can be mapped even if
    /// its new target is outside the watcher roots.
    public var lexicalPaths: Set<String> = []
    public var structuralPaths: Set<String> = []
    public var reconciliationPaths: Set<String> = []
    public var recoveryReasons: Set<FSEventsRecoveryReason> = []
    /// Epoch changes belong to individual streams, even when batches are merged.
    public var wrappedStreams: Set<String> = []
    public var streamEpochs: [String: IndexEventStreamEpoch] = [:]
    public var watermarks: [String: UInt64] = [:]
    /// Canonical roots covered by each event stream watermark. This lets the
    /// scheduler hold back only streams whose indexed paths failed.
    public var streamRoots: [String: Set<String>] = [:]
    public var checkpointReservations: [IndexCheckpointReservation] = []
    public var historyDone = false
    public var requiresReconciliation: Bool { !reconciliationPaths.isEmpty }
    public var hasIndexWork: Bool { !paths.isEmpty || requiresReconciliation }

    public init() {}

    public mutating func include(
        path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId = 0,
        streamIdentifier: String = "host", streamRoots: [String] = []
    ) {
        let globalRecovery = includeStreamControl(flags: flags, eventID: eventID,
            streamIdentifier: streamIdentifier, streamRoots: streamRoots)
        let structuralFlags = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagItemCloned)
        if flags & structuralFlags != 0 { structuralPaths.insert(path) }
        let canonical = TraceFileIO.canonicalPath(path).path
        let directory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let structural = flags & UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemCloned) != 0
        if globalRecovery {
            // Global control inclusion already enrolled every stream root.
        } else if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            reconciliationPaths.insert(canonical)
            recoveryReasons.insert(.rootChanged)
        } else if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || (directory && structural) {
            reconciliationPaths.insert(canonical)
            recoveryReasons.insert(.subtreeInvalidated)
        }
        if !directory {
            paths.insert(canonical)
            let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
            if lexical != canonical { lexicalPaths.insert(lexical) }
        }
    }

    /// Stream-wide controls are independent of content-path filtering. This
    /// path performs no filesystem lookup and advances chronology exactly once.
    @discardableResult
    fileprivate mutating func includeStreamControl(flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId,
                                                   streamIdentifier: String, streamRoots: [String]) -> Bool {
        let wrappedID = flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0
        if wrappedID {
            wrappedStreams.insert(streamIdentifier)
            streamEpochs[streamIdentifier] = (streamEpochs[streamIdentifier] ?? .init()).advanced()
        }
        watermarks[streamIdentifier] = wrappedID ? eventID : max(watermarks[streamIdentifier] ?? 0, eventID)
        self.streamRoots[streamIdentifier, default: []].formUnion(streamRoots)
        if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { historyDone = true }
        let dropped = flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
        if dropped || wrappedID {
            reconciliationPaths.formUnion(streamRoots)
            if dropped { recoveryReasons.insert(.eventsDropped) }
            if wrappedID { recoveryReasons.insert(.eventIDsWrapped) }
        }
        return dropped || wrappedID
    }

    public mutating func merge(_ other: SourceChanges) {
        checkpointReservations = IndexCheckpointReservation.coalesced(checkpointReservations + other.checkpointReservations)
        paths.formUnion(other.paths)
        lexicalPaths.formUnion(other.lexicalPaths)
        structuralPaths.formUnion(other.structuralPaths)
        reconciliationPaths.formUnion(other.reconciliationPaths)
        recoveryReasons.formUnion(other.recoveryReasons)
        wrappedStreams.formUnion(other.wrappedStreams)
        historyDone = historyDone || other.historyDone
        for (identifier, eventID) in other.watermarks {
            let existing = streamEpochs[identifier], incoming = other.streamEpochs[identifier]
            if let existing, let incoming, existing.predecessors.contains(incoming.id) { continue }
            let newerEpoch = incoming.map { next in existing.map { next.predecessors.contains($0.id) } ?? false } ?? false
            let sameEpoch = existing != nil && existing == incoming
            let startsInterval = other.wrappedStreams.contains(identifier) && !sameEpoch
            watermarks[identifier] = newerEpoch || startsInterval
                ? eventID : max(watermarks[identifier] ?? 0, eventID)
            if let incoming { streamEpochs[identifier] = incoming }
        }
        for (identifier, roots) in other.streamRoots {
            streamRoots[identifier, default: []].formUnion(roots)
        }
    }
}

public final class FSEventsWatcher: @unchecked Sendable {
    private final class RetiredStream: @unchecked Sendable {
        let stream: FSEventStreamRef
        init(_ stream: FSEventStreamRef) { self.stream = stream }
        func release() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
    private final class StreamContext {
        weak var watcher: FSEventsWatcher?
        init(_ watcher: FSEventsWatcher) { self.watcher = watcher }
    }
    private let roots: [String]
    private let identifier: String
    private let sinceWhen: FSEventStreamEventId
    private let latency: CFTimeInterval
    private let callback: @Sendable (SourceChanges) -> Void
    private let eventFilter: (@Sendable (String, FSEventStreamEventFlags) -> Bool)?
    private let tracksWatermarks: Bool
    private let batchingDelay: TimeInterval
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.fsevents", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pending = SourceChanges()
    private var checkpointEpoch = IndexEventStreamEpoch()
    private var flushWorkItem: DispatchWorkItem?

    public convenience init(roots: [URL], latency: CFTimeInterval = 0.02,
                            callback: @escaping @Sendable (Set<String>) -> Void) {
        self.init(roots: roots, identifier: "host", latency: latency,
                  onChange: { callback($0.paths) })
    }

    public init(roots: [URL], identifier: String = "host",
                sinceWhen: UInt64? = nil, latency: CFTimeInterval = 0.02,
                eventFilter: (@Sendable (String, FSEventStreamEventFlags) -> Bool)? = nil,
                tracksWatermarks: Bool = true,
                batchingDelay: TimeInterval = 0.05,
                onChange: @escaping @Sendable (SourceChanges) -> Void) {
        self.roots = roots.map { TraceFileIO.canonicalPath($0.path).path }
        self.identifier = identifier
        self.sinceWhen = sinceWhen ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        self.latency = latency
        self.callback = onChange
        self.eventFilter = eventFilter
        self.tracksWatermarks = tracksWatermarks
        self.batchingDelay = max(0, batchingDelay)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        if Thread.isMainThread, let stream {
            // The weak stream context cannot call a destroyed watcher. Retain
            // the native stream until previously queued callbacks have returned.
            let retired = RetiredStream(stream)
            queue.async { retired.release() }
        } else { stop() }
    }

    @discardableResult
    public func start() -> Bool {
        if stream != nil { return true }
        guard !roots.isEmpty else { return false }
        if TraceTestHooks.isUITesting,
           let fragment = TraceTestHooks.environment["TRACE_TEST_FAIL_WATCHER_ROOT_CONTAINS"],
           roots.contains(where: { $0.contains(fragment) }) {
            return false
        }
        let owner = StreamContext(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<StreamContext>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                if let info { Unmanaged<StreamContext>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, eventIDs in
            guard let info else { return }
            let owner = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = owner.watcher else { return }
            let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes = SourceChanges()
            changes.streamEpochs[watcher.identifier] = watcher.checkpointEpoch
            for (index, path) in pathArray.prefix(count).enumerated() {
                watcher.includeEvent(path: path, flags: flags[index], eventID: eventIDs[index], in: &changes)
            }
            watcher.finishChanges(&changes)
            if changes.hasIndexWork, TraceTestHooks.isUITesting,
               let fragment = TraceTestHooks.environment["TRACE_TEST_GATE_FILESYSTEM_ROOT_CONTAINS"],
               watcher.roots.contains(where: { $0.contains(fragment) }),
               TraceTestHooks.failOnce(for: "TRACE_TEST_GATE_FILESYSTEM_CALLBACK") {
                TraceTestHooks.touch(pathKey: "TRACE_TEST_FILESYSTEM_CALLBACK_ENTERED_PATH")
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while ContinuousClock.now < deadline,
                      let release = TraceTestHooks.environment["TRACE_TEST_FILESYSTEM_CALLBACK_RELEASE_PATH"],
                      !FileManager.default.fileExists(atPath: release) {
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
            if changes.hasIndexWork || !changes.structuralPaths.isEmpty || !changes.watermarks.isEmpty || changes.historyDone {
                watcher.enqueue(changes)
            }
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            roots as CFArray,
            sinceWhen,
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        )
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        if tracksWatermarks, sinceWhen == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            var initial = SourceChanges()
            initial.watermarks[identifier] = FSEventsGetCurrentEventId()
            initial.streamRoots[identifier] = Set(roots)
            enqueue(initial)
        }
        return true
    }

    public func stop(flushPending: Bool = false) {
        guard let stream else { return }
        if Thread.isMainThread {
            // Preserve the watcher until draining completes without blocking UI.
            queue.async { [self] in stop(flushPending: flushPending) }
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        // Callbacks already queued before invalidation must finish before their
        // context is released and before a replacement drains the pending batch.
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
        FSEventStreamRelease(stream)
        self.stream = nil
        lock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let remaining = pending
        pending = SourceChanges()
        lock.unlock()
        if flushPending, remaining.hasIndexWork || !remaining.structuralPaths.isEmpty { callback(remaining) }
    }

    private func includeEvent(path: String, flags: FSEventStreamEventFlags,
                              eventID: FSEventStreamEventId, in changes: inout SourceChanges) {
        if eventFilter?(path, flags) != false {
            changes.include(path: path, flags: flags, eventID: eventID,
                streamIdentifier: identifier, streamRoots: roots)
        } else {
            let controls = UInt32(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagHistoryDone)
            if flags & controls != 0 {
                changes.includeStreamControl(flags: flags, eventID: eventID, streamIdentifier: identifier, streamRoots: roots)
            }
        }
    }

    private func finishChanges(_ changes: inout SourceChanges) {
        checkpointEpoch = changes.streamEpochs[identifier] ?? checkpointEpoch
        if !tracksWatermarks {
            changes.streamEpochs = [:]
            changes.watermarks = [:]
            changes.streamRoots = [:]
            changes.wrappedStreams = []
        }
    }

    #if DEBUG
    func changesForTesting(_ events: [(path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId)]) -> SourceChanges {
        queue.sync {
            var changes = SourceChanges()
            changes.streamEpochs[identifier] = checkpointEpoch
            for event in events { includeEvent(path: event.path, flags: event.flags, eventID: event.eventID, in: &changes) }
            finishChanges(&changes)
            return changes
        }
    }
    #endif

    private func enqueue(_ changes: SourceChanges) {
        lock.lock()
        pending.merge(changes)
        guard flushWorkItem == nil else { lock.unlock(); return }
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + batchingDelay, execute: item)
    }

    private func flush() {
        lock.lock()
        let paths = pending
        pending = SourceChanges()
        flushWorkItem = nil
        lock.unlock()
        if !paths.paths.isEmpty || !paths.structuralPaths.isEmpty || paths.requiresReconciliation || !paths.watermarks.isEmpty
            || paths.historyDone { callback(paths) }
    }
}
