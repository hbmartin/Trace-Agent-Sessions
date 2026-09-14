import CoreServices
import Foundation

public struct SourceChanges: Sendable {
    public var paths: Set<String> = []
    public var requiresReconciliation = false

    public mutating func include(path: String, flags: FSEventStreamEventFlags) {
        let recovery = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        let directory = flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        let structural = flags & UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
        requiresReconciliation = requiresReconciliation || flags & recovery != 0 || (directory && structural)
        if !directory { paths.insert(path) }
    }
}

public final class FSEventsWatcher: @unchecked Sendable {
    private let roots: [String]
    private let latency: CFTimeInterval
    private let callback: @Sendable (SourceChanges) -> Void
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pending = SourceChanges()
    private var flushWorkItem: DispatchWorkItem?

    public convenience init(roots: [URL], latency: CFTimeInterval = 0.02,
                            callback: @escaping @Sendable (Set<String>) -> Void) {
        self.init(roots: roots, latency: latency, onChange: { callback($0.paths) })
    }

    public init(roots: [URL], latency: CFTimeInterval = 0.02,
                onChange: @escaping @Sendable (SourceChanges) -> Void) {
        self.roots = roots.map(\.standardizedFileURL.path)
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
        let eventCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes = SourceChanges()
            for (index, path) in pathArray.prefix(count).enumerated() {
                changes.include(path: path, flags: flags[index])
            }
            watcher.enqueue(changes)
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            eventCallback,
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
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
        pending.paths.formUnion(changes.paths)
        pending.requiresReconciliation = pending.requiresReconciliation || changes.requiresReconciliation
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
        if !paths.paths.isEmpty || paths.requiresReconciliation { callback(paths) }
    }
}
