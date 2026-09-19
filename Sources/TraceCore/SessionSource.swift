import Foundation

public protocol SessionSource: Sendable {
    var agent: AgentKind { get }
    var roots: [SourceRoot] { get }

    func discover() throws -> [DiscoveredSourceFile]
    /// Discovers files only below the supplied paths. Implementations may fall back to a
    /// full discovery, but built-in sources keep recovery scans constrained to the affected
    /// subtree or root.
    func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile]
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?) -> AsyncThrowingStream<ParsedRecord, Error>
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialSessionID: String?) -> AsyncThrowingStream<ParsedRecord, Error>
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage
}

public enum SessionSourceError: LocalizedError, Sendable {
    case unreadableFile(String)
    case unreadableDirectory(String, String)
    case malformedRecord(String)
    case unsupportedLocator
    case missingRecord(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path): "Unable to read \(path)"
        case .unreadableDirectory(let path, let reason):
            "Unable to enumerate \(path): \(reason)"
        case .malformedRecord(let reason): "Malformed session record: \(reason)"
        case .unsupportedLocator: "The source adapter does not support this message locator"
        case .missingRecord(let key): "The source record \(key) no longer exists"
        }
    }
}

public extension SessionSource {
    func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile] {
        guard !paths.isEmpty else { return [] }
        let scopes = paths.map(TraceFileIO.canonicalPath)
        return try discover().filter { file in
            let candidate = TraceFileIO.canonicalPath(file.url.path)
            return scopes.contains { $0.contains(candidate) }
        }
    }

    func records(in file: DiscoveredSourceFile, from offset: Int64) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: nil)
    }

    func discoverFiles(
        extensions allowedExtensions: Set<String>,
        scopedTo paths: Set<String>? = nil,
        classify: (URL) -> SourceFormat?
    ) throws -> [DiscoveredSourceFile] {
        let manager = FileManager.default
        var files: [DiscoveredSourceFile] = []

        for root in roots where manager.fileExists(atPath: root.url.path) {
            let rootPath = TraceFileIO.canonicalPath(root.url.path)
            let starts: [URL]
            if let paths {
                let scopes = paths.map(TraceFileIO.canonicalPath)
                if scopes.contains(where: { $0.contains(rootPath) }) {
                    starts = [root.url]
                } else {
                    starts = scopes.filter { rootPath.contains($0) }.map { URL(fileURLWithPath: $0.path) }
                }
            } else {
                starts = [root.url]
            }

            var seenStarts: Set<String> = []
            for start in starts where seenStarts.insert(TraceFileIO.canonicalPath(start.path).comparisonKey).inserted {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: start.path, isDirectory: &isDirectory) else { continue }
                if !isDirectory.boolValue {
                    if allowedExtensions.contains(start.pathExtension.lowercased()), let format = classify(start) {
                        files.append(.init(agent: agent, root: root.url, url: start, format: format))
                    }
                    continue
                }
                var enumerationFailure: (url: URL, error: Error)?
                guard let enumerator = manager.enumerator(
                    at: start,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        enumerationFailure = (url, error)
                        return false
                    }
                ) else {
                    throw SessionSourceError.unreadableDirectory(
                        start.path, "the file-system enumerator could not be created"
                    )
                }

                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    guard allowedExtensions.contains(url.pathExtension.lowercased()),
                          let format = classify(url)
                    else { continue }
                    files.append(.init(agent: agent, root: root.url, url: url, format: format))
                }
                if let failure = enumerationFailure {
                    throw SessionSourceError.unreadableDirectory(
                        failure.url.path, failure.error.localizedDescription
                    )
                }
            }
        }

        return files
    }
}
