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
    public enum Kind: String, Sendable {
        case missingRoot
        case unreadable
    }

    public let agent: AgentKind
    public let root: URL
    public let path: String
    public let message: String
    public let kind: Kind

    public init(
        agent: AgentKind, root: URL, path: String, message: String,
        kind: Kind = .unreadable
    ) {
        self.agent = agent
        self.root = root.standardized
        self.path = path
        self.message = message
        self.kind = kind
    }

}

struct NormalizedDiscoveryFailure: Sendable {
    let failure: DiscoveryFailure
    let scanPath: TraceFileIO.CanonicalPath
    let relativeScope: RootRelativeScope

    init(failure: DiscoveryFailure, scope: SourceRootScope) {
        self.failure = failure
        scanPath = scope.scanPath
        relativeScope = scope.relativeScope
    }
}

func normalizedDiscoveryFailures(
    _ failures: [DiscoveryFailure], for root: SourceRoot,
    in capturedContext: SourceRootPathContext? = nil
) -> [NormalizedDiscoveryFailure] {
    let context = capturedContext ?? root.mappingContext
    return deduplicatedNormalizedDiscoveryFailures(failures.compactMap { failure in
        guard let scope = root.scope(
            forRawPath: failure.path, in: context
        ) else { return nil }
        return NormalizedDiscoveryFailure(failure: failure, scope: scope)
    })
}

func deduplicatedNormalizedDiscoveryFailures(
    _ failures: [NormalizedDiscoveryFailure]
) -> [NormalizedDiscoveryFailure] {
    let ordered = failures.sorted { lhs, rhs in
        let left = (
            lhs.relativeScope.comparisonKey,
            lhs.failure.kind == .unreadable ? 0 : 1,
            lhs.failure.message,
            lhs.failure.path,
            lhs.failure.agent.rawValue,
            lhs.failure.root.path
        )
        let right = (
            rhs.relativeScope.comparisonKey,
            rhs.failure.kind == .unreadable ? 0 : 1,
            rhs.failure.message,
            rhs.failure.path,
            rhs.failure.agent.rawValue,
            rhs.failure.root.path
        )
        return left < right
    }
    var seen: Set<RootRelativeScope> = []
    return ordered.filter { seen.insert($0.relativeScope).inserted }
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
            scopes.contains { $0.contains(file.canonicalPath) }
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
        if let failure = result.failures.first(where: { failure in
            if failure.kind != .missingRoot { return true }
            return !roots.contains { $0.url.path == failure.root.path && $0.isDefault }
        }) {
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
            let context = root.mappingContext
            let rootScope = root.rootScope(in: context)
            let starts: [(url: URL, scope: SourceRootScope)]
            if let paths {
                let scopes = paths.compactMap {
                    root.reconciliationScope(forRawPath: $0, in: context)
                }
                if scopes.contains(where: { $0.relativeScope.isRoot }) {
                    starts = [(root.scanURL, rootScope)]
                } else {
                    starts = scopes.map {
                        (URL(fileURLWithPath: $0.scanPath.path), $0)
                    }
                }
            } else {
                starts = [(root.scanURL, rootScope)]
            }

            // Do not touch roots that cannot contribute to this scoped request.
            guard !starts.isEmpty else { continue }

            let rootItemType: FileAttributeType?
            do { rootItemType = try itemTypeIfPresent(for: root.scanURL) }
            catch is CancellationError { throw CancellationError() }
            catch {
                failures.append(.init(
                    agent: agent, root: root.url, path: root.scanURL.path,
                    message: error.localizedDescription
                ))
                continue
            }
            guard let rootItemType else {
                failures.append(.init(
                    agent: agent, root: root.url, path: root.scanURL.path,
                    message: "The configured source root is not currently available",
                    kind: .missingRoot
                ))
                continue
            }
            guard rootItemType == .typeDirectory else {
                failures.append(.init(
                    agent: agent, root: root.url, path: root.scanURL.path,
                    message: "The configured source root is not a directory"
                ))
                continue
            }

            var seenStarts: Set<String> = []
            for start in starts {
                let startPath = TraceFileIO.canonicalPath(start.url.path)
                guard let mappedScope = root.scope(forScanPath: startPath, in: context),
                      mappedScope.relativeScope == start.scope.relativeScope else {
                    failures.append(.init(
                        agent: agent, root: root.url, path: root.scanURL.path,
                        message: "The configured source path changed while Trace was running"
                    ))
                    continue
                }
                let startScope = start.scope
                guard seenStarts.insert(startScope.relativeScope.comparisonKey).inserted else {
                    continue
                }
                let startsAtRoot = startScope.relativeScope.isRoot
                let itemType: FileAttributeType?
                do {
                    itemType = startsAtRoot
                        ? rootItemType
                        : try itemTypeIfPresent(for: start.url)
                }
                catch is CancellationError { throw CancellationError() }
                catch {
                    failures.append(.init(
                        agent: agent, root: root.url, path: start.url.path,
                        message: error.localizedDescription
                    ))
                    continue
                }
                guard let itemType else {
                    // The root preflight above proved the root is available, so a
                    // missing descendant is a successful empty subtree scan.
                    continue
                }
                if itemType != .typeDirectory {
                    if allowedExtensions.contains(start.url.pathExtension.lowercased()),
                       let format = classify(start.url) {
                        files.append(.init(
                            agent: agent, root: root.url, url: start.url, format: format
                        ))
                    }
                    continue
                }
                guard let enumerator = manager.enumerator(
                    at: start.url,
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
                        agent: agent, root: root.url, path: start.url.path,
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
