import Foundation

public protocol SessionSource: Sendable {
    var agent: AgentKind { get }
    var roots: [SourceRoot] { get }
    /// Opt in only when scoped discovery accepts individual file paths, including
    /// missing files, and reports authoritative empty results or failures for them.
    /// Legacy adapters receive containing-directory requests instead.
    var supportsFileScopedDiscovery: Bool { get }

    func discover() throws -> [DiscoveredSourceFile]
    /// Discovers files only below the supplied paths. Implementations may fall back to a
    /// full discovery, but built-in sources keep recovery scans constrained to the affected
    /// subtree or root.
    func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile]
    func discoverResult(scopedTo paths: Set<String>?) throws -> DiscoveryResult
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?) -> AsyncThrowingStream<ParsedRecord, Error>
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialSessionID: String?) -> AsyncThrowingStream<ParsedRecord, Error>
    /// Reads from a committed boundary using its durable identity and timestamp context.
    /// The compatibility bridge supplies identity only. Adapters and forwarding
    /// wrappers must implement this overload to preserve durable timestamp context.
    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?, initialContext: SourceReadContext) -> AsyncThrowingStream<ParsedRecord, Error>
    func hydrate(fileURL: URL, format: SourceFormat, locator: RecordLocator) throws -> HydratedMessage
}

enum DiscoveryFailureEvidence: Hashable, Sendable {
    case unknown
    case fileLink(target: TraceFileIO.CanonicalPath?, missing: Bool)
}

private func fileLinkEvidence(at path: String) -> DiscoveryFailureEvidence {
    let target = SourceRoot.discoveryLinkTarget(URL(fileURLWithPath: path, isDirectory: false))
    var missing = false
    if let target {
        do { _ = try FileManager.default.attributesOfItem(atPath: target.path) }
        catch {
            let error = error as NSError
            missing = (error.domain == NSCocoaErrorDomain && error.code == CocoaError.Code.fileReadNoSuchFile.rawValue)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
        }
    }
    return .fileLink(target: target, missing: missing)
}

private func revalidatedLinkFailure(_ failure: DiscoveryFailure) -> DiscoveryFailure {
    guard case .fileLink = failure.evidence else { return failure }
    var result = failure
    if failure.evidence != fileLinkEvidence(at: failure.path) { result.evidence = .unknown }
    return result
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
    public let requestedScopePath: String?
    let requestedScope: SourceRootScope?
    var evidence: DiscoveryFailureEvidence = .unknown

    public init(
        agent: AgentKind, root: URL, path: String, message: String,
        kind: Kind = .unreadable, requestedScopePath: String? = nil
    ) {
        self.agent = agent
        self.root = root.standardized
        self.path = path
        self.message = message
        self.kind = kind
        self.requestedScopePath = requestedScopePath
        requestedScope = nil
    }

    init(
        agent: AgentKind, root: URL, path: String, message: String,
        kind: Kind = .unreadable, requestedScope: SourceRootScope
    ) {
        self.agent = agent
        self.root = root.standardized
        self.path = path
        self.message = message
        self.kind = kind
        self.requestedScopePath = requestedScope.scanPath.path
        self.requestedScope = requestedScope
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

struct VerifiedDiscoveryResult: Sendable {
    let files: [DiscoveredSourceFile]
    let failures: [NormalizedDiscoveryFailure]
}

// Immutable scope lookup: one normalization per file and policy, then ancestor
// membership checks independent of the number of requested scopes.
struct DiscoveryScopeMatcher {
    private let sensitive: Set<String>, insensitive: Set<String>
    init(_ scopes: [SourceRootScope]) { self.init(scopes.map(\.scanPath)) }
    init(_ paths: [TraceFileIO.CanonicalPath]) {
        sensitive = Set(paths.filter(\.isCaseSensitive).map { $0.path.precomposedStringWithCanonicalMapping })
        insensitive = Set(paths.filter { !$0.isCaseSensitive }.map { $0.comparisonKey.precomposedStringWithCanonicalMapping })
    }
    private func contains(_ path: String, keys: Set<String>) -> Bool {
        var key = path
        while true {
            if keys.contains(key) { return true }
            guard key != "/", let slash = key.lastIndex(of: "/") else { return false }
            key = slash == key.startIndex ? "/" : String(key[..<slash])
        }
    }
    func contains(_ path: TraceFileIO.CanonicalPath) -> Bool {
        if !sensitive.isEmpty, contains(path.path.precomposedStringWithCanonicalMapping, keys: sensitive) { return true }
        return !insensitive.isEmpty && contains(TraceFileIO.comparisonKey(path.path, caseSensitive: false).precomposedStringWithCanonicalMapping, keys: insensitive)
    }
}

func verifiedDiscoveryResult(
    _ result: DiscoveryResult, agent: AgentKind, root: SourceRoot,
    capturedContext: SourceRootPathContext, currentContext: SourceRootPathContext,
    configuredRoots: [SourceRoot] = [], scopes: [SourceRootScope]
) -> VerifiedDiscoveryResult {
    let scannedScopes = Set(scopes.map(\.relativeScope))
    guard capturedContext == currentContext else {
        return .init(files: [], failures: deduplicatedNormalizedDiscoveryFailures(scopes.map { scope in
            .init(failure: .init(agent: agent, root: root.url, path: scope.scanPath.path,
                message: "The configured source path changed while Trace was running"), scope: scope)
        }))
    }
    let matcher = DiscoveryScopeMatcher(scopes)
    let configuredContexts = Dictionary(configuredRoots.filter { $0.id != root.id }.map { ($0.id, $0.mappingContext) }, uniquingKeysWith: { first, _ in first })
    var aliases: [String: TraceFileIO.CanonicalPath] = [:]
    func canonicalRoot(_ candidate: URL) -> TraceFileIO.CanonicalPath {
        if let cached = aliases[candidate.path] { return cached }
        let value = TraceFileIO.canonicalPath(candidate.path); aliases[candidate.path] = value; return value
    }
    func sameRoot(_ candidate: URL) -> Bool {
        candidate.path == root.url.path || canonicalRoot(candidate) == capturedContext.scanPath
    }
    func acceptsRoot(_ candidate: URL, path: String) -> Bool {
        if sameRoot(candidate) { return true }
        return configuredRoots.contains { configured in
            configured.url.path == candidate.path && configuredContexts[configured.id].flatMap { configured.lexicalDiscoveryScope(path, in: $0) } != nil
        }
    }
    let failures = result.failures.filter { failure in
        guard failure.agent == agent else { return false }
        if sameRoot(failure.root) { return true }
        // Root availability belongs only to the root which was checked. Sharing
        // file read outcomes must not manufacture an outer-root availability error.
        let origin = canonicalRoot(failure.root)
        guard failure.kind != .missingRoot,
              TraceFileIO.canonicalPath(failure.path) != origin else { return false }
        return acceptsRoot(failure.root, path: failure.path)
    }.map { failure in
        var rebased: DiscoveryFailure
        if root.scope(forRawPath: failure.path, in: capturedContext) == nil,
           let lexical = root.lexicalDiscoveryScope(failure.path, in: capturedContext) {
            rebased = DiscoveryFailure(agent: agent, root: root.url, path: failure.path, message: failure.message,
                kind: failure.kind, requestedScope: lexical)
        } else {
            rebased = DiscoveryFailure(agent: agent, root: root.url, path: failure.path, message: failure.message,
                kind: failure.kind, requestedScopePath: failure.requestedScopePath)
        }
        rebased.evidence = failure.evidence
        return revalidatedLinkFailure(rebased)
    }
    var qualifiedFailures = normalizedDiscoveryFailures(failures, for: root, in: capturedContext).filter { failure in
        scannedScopes.contains { $0.intersects(failure.relativeScope) }
    }
    var files: [DiscoveredSourceFile] = []
    for file in result.files {
        if let failure = file.discoveryFailure,
           file.agent == agent, acceptsRoot(file.root, path: file.discoveryPath),
           let lexical = root.lexicalDiscoveryScope(file.discoveryPath, in: capturedContext) {
            if scannedScopes.contains(where: { $0.intersects(lexical.relativeScope) }) {
                qualifiedFailures.append(.init(failure: revalidatedLinkFailure(failure), scope: lexical))
            }
            continue
        }
        let canonicalMember = matcher.contains(file.canonicalPath)
        let lexical = canonicalMember ? nil : root.lexicalDiscoveryScope(file.discoveryPath, in: capturedContext)
        let lexicalMember = lexical.map { matcher.contains($0.scanPath) } ?? false
        guard canonicalMember || lexicalMember else {
            // A whole-root adapter claiming an external target without lexical
            // membership has not proved an authoritative empty result. Larger
            // legacy discoveries remain harmlessly filtered for narrow requests.
            if sameRoot(file.root), scopes.contains(where: { $0.relativeScope.isRoot }) {
                qualifiedFailures += scopes.filter { $0.relativeScope.isRoot }.map {
                    .init(failure: .init(agent: agent, root: root.url, path: file.discoveryPath,
                        message: "Could not verify the discovered source membership"), scope: $0)
                }
            }
            continue
        }
        let identityAccepted = file.agent == agent && acceptsRoot(file.root, path: file.discoveryPath)
        let targetType = canonicalMember ? nil : (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.type]) as? FileAttributeType
        let linkAccepted = canonicalMember || (targetType == .typeRegular && TraceFileIO.canonicalPath(file.discoveryPath) == file.canonicalPath)
        guard identityAccepted && linkAccepted else {
            if let fileScope = lexical ?? root.scope(forScanPath: file.canonicalPath, in: capturedContext) {
                qualifiedFailures.append(.init(failure: .init(agent: agent, root: root.url, path: file.discoveryPath,
                    message: identityAccepted ? "The source link changed during discovery" : "The adapter returned an incompatible source identity"), scope: fileScope))
            } else {
                qualifiedFailures += scopes.map { .init(failure: .init(agent: agent, root: root.url, path: file.discoveryPath,
                    message: "The adapter returned an incompatible source identity"), scope: $0) }
            }
            continue
        }
        files.append(.init(agent: agent, root: root.url, canonicalPath: file.canonicalPath,
            format: file.format, discoveryPath: file.discoveryPath))
    }
    return .init(files: files, failures: deduplicatedNormalizedDiscoveryFailures(qualifiedFailures))
}

func sourceFormat(for url: URL, agent: AgentKind) -> SourceFormat? {
    let pathExtension = url.pathExtension.lowercased()
    switch agent {
    case .claudeCode:
        return pathExtension == "jsonl" ? .claudeJSONL : nil
    case .codex:
        return pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
            ? .codexJSONL : nil
    case .gemini:
        guard url.deletingLastPathComponent().lastPathComponent == "chats",
              url.lastPathComponent.hasPrefix("session-") else { return nil }
        if pathExtension == "jsonl" { return .geminiJSONL }
        return pathExtension == "json" ? .geminiJSON : nil
    }
}

func normalizedDiscoveryFailures(
    _ failures: [DiscoveryFailure], for root: SourceRoot,
    in capturedContext: SourceRootPathContext? = nil
) -> [NormalizedDiscoveryFailure] {
    let context = capturedContext ?? root.mappingContext
    return deduplicatedNormalizedDiscoveryFailures(failures.compactMap { failure in
        let mapped = root.scope(forRawPath: failure.path, in: context)
        let scope: SourceRootScope?
        let requested = failure.requestedScope
            ?? failure.requestedScopePath.flatMap { root.scope(forRawPath: $0, in: context) }
        if let requested,
           let mapped,
           !requested.relativeScope.intersects(mapped.relativeScope) {
            scope = requested
        } else {
            scope = mapped ?? requested
        }
        guard let scope else { return nil }
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

    // Legacy array discovery defers these candidates to individual reads.
    var rejectedFileLinks: [DiscoveredSourceFile] = []
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
    var supportsFileScopedDiscovery: Bool { false }

    func records(in file: DiscoveredSourceFile, from offset: Int64, through boundary: Int64?,
                 initialContext: SourceReadContext) -> AsyncThrowingStream<ParsedRecord, Error> {
        records(in: file, from: offset, through: boundary, initialSessionID: initialContext.sessionID)
    }

    func discoverResult(scopedTo paths: Set<String>? = nil) throws -> DiscoveryResult {
        .init(files: try paths.map(discover(scopedTo:)) ?? discover())
    }

    func discover(scopedTo paths: Set<String>) throws -> [DiscoveredSourceFile] {
        guard !paths.isEmpty else { return [] }
        let matcher = DiscoveryScopeMatcher(paths.map(TraceFileIO.canonicalPath))
        let contexts = roots.map { ($0, $0.mappingContext) }
        var rootIdentities: [String: TraceFileIO.CanonicalPath] = [:]
        return try discover().filter { file in
            if matcher.contains(file.canonicalPath) { return true }
            // Preserve lexical membership until verification proves identity and
            // target type. Resolving the leaf here would discard external links.
            return contexts.contains { root, context in
                if root.lexicalDiscoveryScope(file.discoveryPath, in: context)
                    .map({ matcher.contains($0.scanPath) }) == true { return true }
                // A whole-root result claiming this root must reach verification
                // even when its membership is unproven. Silently dropping it
                // would turn identity failure into authoritative empty discovery.
                guard matcher.contains(context.scanPath) else { return false }
                if file.root.path == root.url.path { return true }
                let identity = rootIdentities[file.root.path] ?? TraceFileIO.canonicalPath(file.root.path)
                rootIdentities[file.root.path] = identity
                return identity == context.scanPath
            }
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
            if case .fileLink = failure.evidence { return false }
            if failure.kind != .missingRoot { return true }
            return !roots.contains { $0.url.path == failure.root.path && $0.isDefault }
        }) {
            throw SessionSourceError.unreadableDirectory(failure.path, failure.message)
        }
        return result.files + result.rejectedFileLinks
    }

    func discoverFilesResult(
        extensions allowedExtensions: Set<String>,
        scopedTo paths: Set<String>? = nil,
        classify: (URL) -> SourceFormat?
    ) throws -> DiscoveryResult {
        let manager = FileManager.default
        var files: [DiscoveredSourceFile] = []
        var rejectedFileLinks: [DiscoveredSourceFile] = []
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
                    message: error.localizedDescription, requestedScope: rootScope
                ))
                continue
            }
            guard let rootItemType else {
                failures.append(.init(
                    agent: agent, root: root.url, path: root.scanURL.path,
                    message: "The configured source root is not currently available",
                    kind: .missingRoot, requestedScope: rootScope
                ))
                continue
            }
            guard rootItemType == .typeDirectory else {
                failures.append(.init(
                    agent: agent, root: root.url, path: root.scanURL.path,
                    message: "The configured source root is not a directory",
                    requestedScope: rootScope
                ))
                continue
            }

            func appendFile(_ url: URL, format: SourceFormat) {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    // Healthy links retain the existing Foundation fast path.
                    // Only unavailable leaves need bounded target qualification.
                    let resolved = url.resolvingSymlinksInPath()
                    let type = (try? manager.attributesOfItem(atPath: resolved.path)[.type]) as? FileAttributeType
                    if type != .typeRegular {
                        let target = SourceRoot.discoveryLinkTarget(url)
                        var missing = false
                        if let target {
                            do { missing = try itemTypeIfPresent(for: URL(fileURLWithPath: target.path, isDirectory: false)) == nil }
                            catch { /* A previously qualified identity stays unpaid. */ }
                        }
                        let scope = root.lexicalDiscoveryScope(url.path, in: context) ?? rootScope
                        var failure = DiscoveryFailure(agent: agent, root: root.url, path: url.path,
                            message: "The source link target is not currently available", requestedScope: scope)
                        failure.evidence = .fileLink(target: target, missing: missing)
                        failures.append(failure)
                        var candidate = DiscoveredSourceFile(agent: agent, root: root.url, url: url, format: format)
                        candidate.discoveryFailure = failure
                        rejectedFileLinks.append(candidate)
                        return
                    }
                }
                files.append(.init(agent: agent, root: root.url, url: url, format: format))
            }
            var seenStarts: Set<String> = []
            for start in starts {
                let startPath = TraceFileIO.canonicalPath(start.url.path)
                guard let mappedScope = root.scope(forScanPath: startPath, in: context),
                      mappedScope.relativeScope == start.scope.relativeScope else {
                    failures.append(.init(
                        agent: agent, root: root.url, path: rootScope.scanPath.path,
                        message: "The configured source path changed while Trace was running",
                        requestedScope: rootScope
                    ))
                    continue
                }
                let startScope = start.scope
                guard seenStarts.insert(startScope.relativeScope.comparisonKey).inserted else {
                    continue
                }
                let startsAtRoot = startScope.relativeScope.isRoot
                // Starting below an excluded ancestor must agree with a full
                // enumeration. The explicitly configured root itself is allowed.
                if !startsAtRoot {
                    var ancestor = start.url.standardizedFileURL
                    var excluded = false
                    // The captured relative depth bounds this walk without
                    // resolving the configured root again for every ancestor.
                    for _ in startScope.relativeScope.components {
                        let properties = try? ancestor.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
                        if ancestor.lastPathComponent.hasPrefix(".") || properties?.isHidden == true || properties?.isPackage == true {
                            excluded = true; break
                        }
                        ancestor = ancestor.deletingLastPathComponent()
                    }
                    if excluded { continue }
                }
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
                        message: error.localizedDescription, requestedScope: startScope
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
                        appendFile(start.url, format: format)
                    }
                    continue
                }
                guard let enumerator = manager.enumerator(
                    at: start.url,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { url, error in
                        failures.append(.init(
                            agent: agent, root: root.url, path: url.path,
                            message: error.localizedDescription, requestedScope: startScope
                        ))
                        return true
                    }
                ) else {
                    failures.append(.init(
                        agent: agent, root: root.url, path: start.url.path,
                        message: "the file-system enumerator could not be created",
                        requestedScope: startScope
                    ))
                    continue
                }

                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    guard allowedExtensions.contains(url.pathExtension.lowercased()),
                          let format = classify(url)
                    else { continue }
                    appendFile(url, format: format)
                }
            }
        }

        var result = DiscoveryResult(files: files, failures: failures)
        result.rejectedFileLinks = rejectedFileLinks
        return result
    }
}
