import Foundation

/// Launch-time hooks used by the isolated UI test process.
public enum TraceTestHooks {
    public enum DelayMarker: Sendable {
        case touch(pathKey: String)
        case line(String, pathKey: String)
    }

    public static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    public static let environment = ProcessInfo.processInfo.environment

    public static func delayMilliseconds(
        for key: String,
        cappedAt maximum: Int? = nil,
        marker: DelayMarker? = nil
    ) -> Int? {
        guard isUITesting, let raw = environment[key], let delay = Int(raw), delay > 0 else {
            return nil
        }
        switch marker {
        case .touch(let pathKey):
            touch(pathKey: pathKey)
        case .line(let line, let pathKey):
            appendLine(line, pathKey: pathKey)
        case nil:
            break
        }
        return maximum.map { min(delay, $0) } ?? delay
    }

    public static func touch(pathKey: String) {
        guard isUITesting, let path = environment[pathKey] else { return }
        try? Data().write(to: URL(fileURLWithPath: path))
    }

    public static func appendLine(_ line: @autoclosure () -> String, pathKey: String) {
        guard isUITesting, let path = environment[pathKey] else { return }
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line() + "\n").utf8))
        try? handle.close()
    }
}
