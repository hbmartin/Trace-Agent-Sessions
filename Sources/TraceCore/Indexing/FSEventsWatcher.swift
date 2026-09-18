import CoreServices
import Foundation

public enum FSEventsRecoveryReason: String, Hashable, Sendable {
    case subtreeInvalidated
    case rootChanged
    case eventsDropped
    case eventIDsWrapped
}

public struct SourceChanges: Sendable {
    public var paths: Set<String> = []
    public var reconciliationPaths: Set<String> = []
    public var recoveryReasons: Set<FSEventsRecoveryReason> = []
    public var watermarks: [String: UInt64] = [:]
    public var historyDone = false
    public var requiresReconciliation: Bool { !reconciliationPaths.isEmpty }

    public init() {}

    public mutating func include(
        path: String, flags: FSEventStreamEventFlags, eventID: FSEventStreamEventId = 0,
        streamIdentifier: String = "host", streamRoots: [String] = []
    ) {
        watermarks[streamIdentifier] = max(watermarks[streamIdentifier] ?? 0, eventID)
        if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { historyDone = true }
        let canonical = TraceFileIO.canonicalPath(path).path
        let directory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let structural = flags & UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
        let dropped = flags & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
        let wrapped = flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0
        if dropped || wrapped {
            reconciliationPaths.formUnion(streamRoots)
            recoveryReasons.insert(dropped ? .eventsDropped : .eventIDsWrapped)
        } else if flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
            reconciliationPaths.insert(canonical)
            recoveryReasons.insert(.rootChanged)
        } else if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || (directory && structural) {
            reconciliationPaths.insert(canonical)
            recoveryReasons.insert(.subtreeInvalidated)
        }
        if !directory { paths.insert(canonical) }
    }

    public mutating func merge(_ other: SourceChanges) {
        paths.formUnion(other.paths)
        reconciliationPaths.formUnion(other.reconciliationPaths)
        recoveryReasons.formUnion(other.recoveryReasons)
        historyDone = historyDone || other.historyDone
        for (identifier, eventID) in other.watermarks {
            watermarks[identifier] = max(watermarks[identifier] ?? 0, eventID)
        }
    }
}

public final class FSEventsWatcher: @unchecked Sendable {
    private let roots: [String]
    private let identifier: String
    private let sinceWhen: FSEventStreamEventId
    private let latency: CFTimeInterval
    private let callback: @Sendable (SourceChanges) -> Void
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pending = SourceChanges()
    private var flushWorkItem: DispatchWorkItem?

    public convenience init(roots: [URL], latency: CFTimeInterval = 0.02,
                            callback: @escaping @Sendable (Set<String>) -> Void) {
        self.init(roots: roots, identifier: "host", latency: latency,
                  onChange: { callback($0.paths) })
    }

    public init(roots: [URL], identifier: String = "host",
                sinceWhen: UInt64? = nil, latency: CFTimeInterval = 0.02,
                onChange: @escaping @Sendable (SourceChanges) -> Void) {
        self.roots = roots.map { TraceFileIO.canonicalPath($0.path).path }
        self.identifier = identifier
        self.sinceWhen = sinceWhen ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        self.latency = latency
        self.callback = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, eventIDs in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes = SourceChanges()
            for (index, path) in pathArray.prefix(count).enumerated() {
                changes.include(
                    path: path, flags: flags[index], eventID: eventIDs[index],
                    streamIdentifier: watcher.identifier, streamRoots: watcher.roots
                )
            }
            watcher.enqueue(changes)
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
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        if sinceWhen == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) {
            var initial = SourceChanges()
            initial.watermarks[identifier] = FSEventsGetCurrentEventId()
            enqueue(initial)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        lock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pending = SourceChanges()
        lock.unlock()
    }

    private func enqueue(_ changes: SourceChanges) {
        lock.lock()
        pending.merge(changes)
        guard flushWorkItem == nil else { lock.unlock(); return }
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func flush() {
        lock.lock()
        let paths = pending
        pending = SourceChanges()
        flushWorkItem = nil
        lock.unlock()
        if !paths.paths.isEmpty || paths.requiresReconciliation || !paths.watermarks.isEmpty
            || paths.historyDone { callback(paths) }
    }
}
