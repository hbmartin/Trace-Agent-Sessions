import Foundation

public protocol SessionSource: Sendable {
    var agent: AgentKind { get }
    var roots: [SourceRoot] { get }

    func discover() throws -> [DiscoveredSourceFile]
    /// Discovers files only below the supplied paths. Implementations may fall back to a
    /// full discovery, but built-in sources keep recovery scans constrained to the affected
    /// subtree or root.
    func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile]
    func discoverResult(scopedTo paths: Set<String>?) throws -> DiscoveryResult
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?) -> AsyncThrowingStream<ParsedRecord, Error>
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialSessionID: String?) -> AsyncThrowingStream<ParsedRecord, Error>
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage
}

public struct DiscoveryFailure: Hashable, Sendable {
    public let agent: AgentKind
    public let root: URL
    public let path: String
    public let message: String

    public init(agent: AgentKind, root: URL, path: String, message: String) {
        self.agent = agent
        self.root = root.standardizedFileURL
        self.path = path
        self.message = message
    }
}

public struct DiscoveryResult: Sendable {
    public var files: [DiscoveredSourceFile]
    public var failures: [DiscoveryFailure]

    public init(files: [DiscoveredSourceFile] = [], failures: [DiscoveryFailure] = []) {
        self.files = files
        self.failures = failures
    }
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
    func discoverResult(scopedTo paths: Set<String>? = nil) throws -> DiscoveryResult {
        .init(files: try paths.map(discover(scopedTo:)) ?? discover())
    }

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
        let result = try discoverFilesResult(
            extensions: allowedExtensions, scopedTo: paths, classify: classify
        )
        if let failure = result.failures.first {
            throw SessionSourceError.unreadableDirectory(failure.path, failure.message)
        }
        return result.files
    }

    func discoverFilesResult(
        extensions allowedExtensions: Set<String>,
        scopedTo paths: Set<String>? = nil,
        classify: (URL) -> SourceFormat?
    ) throws -> DiscoveryResult {
        let manager = FileManager.default
        var files: [DiscoveredSourceFile] = []
        var failures: [DiscoveryFailure] = []

        func itemTypeIfPresent(for url: URL) throws -> FileAttributeType? {
            do {
                return try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            } catch {
                let fileError = error as NSError
                let isMissing = (fileError.domain == NSCocoaErrorDomain
                    && fileError.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
                    || (fileError.domain == NSPOSIXErrorDomain && fileError.code == Int(ENOENT))
                if isMissing { return nil }
                throw SessionSourceError.unreadableDirectory(
                    url.path, fileError.localizedDescription
                )
            }
        }

        for root in roots {
            let rootPath = TraceFileIO.canonicalPath(root.scanURL.path)
            let starts: [URL]
            if let paths {
                let scopes = paths.map(TraceFileIO.canonicalPath)
                if scopes.contains(where: { $0.contains(rootPath) }) {
                    starts = [root.scanURL]
                } else {
                    starts = scopes.filter { rootPath.contains($0) }.map { URL(fileURLWithPath: $0.path) }
                }
            } else {
                starts = [root.scanURL]
            }

            // Do not touch roots that cannot contribute to this scoped request.
            guard !starts.isEmpty else { continue }

            var seenStarts: Set<String> = []
            for start in starts where seenStarts.insert(TraceFileIO.canonicalPath(start.path).comparisonKey).inserted {
                let itemType: FileAttributeType?
                do { itemType = try itemTypeIfPresent(for: URL(fileURLWithPath: start.path)) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    failures.append(.init(
                        agent: agent, root: root.url, path: start.path,
                        message: error.localizedDescription
                    ))
                    continue
                }
                guard let itemType else {
                    if !root.isDefault {
                        failures.append(.init(
                            agent: agent, root: root.url, path: start.path,
                            message: "The configured source root is not currently available"
                        ))
                    }
                    continue
                }
                if itemType != .typeDirectory {
                    if allowedExtensions.contains(start.pathExtension.lowercased()), let format = classify(start) {
                        files.append(.init(agent: agent, root: root.url, url: start, format: format))
                    }
                    continue
                }
                guard let enumerator = manager.enumerator(
                    at: start,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        failures.append(.init(
                            agent: agent, root: root.url, path: url.path,
                            message: error.localizedDescription
                        ))
                        return true
                    }
                ) else {
                    failures.append(.init(
                        agent: agent, root: root.url, path: start.path,
                        message: "the file-system enumerator could not be created"
                    ))
                    continue
                }

                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    guard allowedExtensions.contains(url.pathExtension.lowercased()),
                          let format = classify(url)
                    else { continue }
                    files.append(.init(agent: agent, root: root.url, url: url, format: format))
                }
            }
        }

        return .init(files: files, failures: failures)
    }
}
