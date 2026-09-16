import Foundation

/// Launch-time hooks used by the isolated UI test process.
public enum TraceTestHooks {
    public static let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    public static let environment = ProcessInfo.processInfo.environment

    public static func appendLine(_ line: String, pathKey: String) {
        guard isUITesting, let path = environment[pathKey] else { return }
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        try? handle.close()
    }
}
