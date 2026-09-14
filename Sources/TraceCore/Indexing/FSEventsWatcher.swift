import CoreServices
import Foundation

public final class FSEventsWatcher: @unchecked Sendable {
    private let roots: [String]
    private let latency: CFTimeInterval
    private let callback: @Sendable (Set<String>) -> Void
    private let queue = DispatchQueue(label: "me.haroldmartin.Trace.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var pending: Set<String> = []
    private var flushWorkItem: DispatchWorkItem?

    public init(
        roots: [URL],
        latency: CFTimeInterval = 0.02,
        callback: @escaping @Sendable (Set<String>) -> Void
    ) {
        self.roots = roots.map(\.standardizedFileURL.path)
        self.latency = latency
        self.callback = callback
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
        let eventCallback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.enqueue(Set(pathArray.prefix(count)))
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
    }

    private func enqueue(_ paths: Set<String>) {
        lock.lock()
        pending.formUnion(paths)
        flushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush() }
        flushWorkItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    private func flush() {
        lock.lock()
        let paths = pending
        pending.removeAll(keepingCapacity: true)
        flushWorkItem = nil
        lock.unlock()
        if !paths.isEmpty { callback(paths) }
    }
}
